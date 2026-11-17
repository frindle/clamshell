using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Clamshell.Auth;
using Microsoft.Win32;

namespace Clamshell;

// What every listener on this host shares when deciding who may connect: the
// host's identity key, the device list, whether approval is on, and the limits
// on connections that have not got in yet. The limits are counted for the whole
// process, because one host runs a listener per display. Mirrors
// Sources/Clamshell/Auth/HostAuth.swift.

/// <summary>The two settings the gate reads, kept in the current user's registry
/// (HKCU\Software\Clamshell). Anything but a clear 0 leaves approval on.</summary>
internal static class HostSettings
{
    public const string KeyPath = @"Software\Clamshell";
    public const string RequireApprovalValue = "RequireDeviceApproval";
    public const string TrustedProxiesValue = "TrustedProxies";

    /// <summary>Only a REG_DWORD of 0 turns approval off. A missing value, any other number,
    /// and any other type of value leave it on.</summary>
    public static bool ApprovalFromStored(object? value) => !(value is int n && n == 0);

    public static bool ReadRequireApproval()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(KeyPath);
            return ApprovalFromStored(key?.GetValue(RequireApprovalValue));
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return true;
        }
    }

    public static void WriteRequireApproval(bool on)
    {
        using var key = Registry.CurrentUser.CreateSubKey(KeyPath, writable: true);
        key.SetValue(RequireApprovalValue, on ? 1 : 0, RegistryValueKind.DWord);
    }

    /// <summary>The proxies to believe besides this machine itself; empty by default.</summary>
    public static TrustedProxies ReadTrustedProxies()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(KeyPath);
            return key?.GetValue(TrustedProxiesValue) is string[] list ? new TrustedProxies(list) : new TrustedProxies();
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return new TrustedProxies();
        }
    }
}

internal sealed class HostAuth : IDisposable
{
    public const int MaxUnansweredConnections = 32;
    public const int MaxWaitingConnections = 8;
    /// <summary>What one address group may hold of each table (see <see cref="RoomSharing"/>).</summary>
    public const int MaxUnansweredPerGroup = 8;
    public const int MaxWaitingConnectionsPerGroup = 3;

    public HostIdentity Identity { get; }
    public DeviceTrustStore Store { get; }
    public HostDirectory Directory { get; } = new();
    /// <summary>What this host calls itself in the challenge. A label only.</summary>
    public string HostName { get; }

    /// <summary>How long a new connection has to answer the challenge.</summary>
    public TimeSpan ResponseDeadline { get; set; } = TimeSpan.FromSeconds(10);
    /// <summary>How long one connection waits for the user's decision before it is told to come back.</summary>
    public TimeSpan ApprovalTimeout { get; set; } = TimeSpan.FromMinutes(10);
    /// <summary>How often a waiting connection is told that it is still waiting.</summary>
    public TimeSpan PendingRepeat { get; set; } = TimeSpan.FromSeconds(20);

    /// <summary>For self-tests: replaces the registry setting.</summary>
    public TrustedProxies? TrustedProxiesOverride { get; set; }
    public TrustedProxies TrustedProxies => TrustedProxiesOverride ?? HostSettings.ReadTrustedProxies();

    /// <summary>Raised when approval is switched on or off, on whatever thread noticed.</summary>
    public event Action? ApprovalDidChange;

    /// <summary>A connection that was sent the challenge and has not answered yet.</summary>
    public sealed class Unanswered
    {
        internal readonly Action Close;
        internal readonly string Group;
        internal readonly long Seq;
        internal Unanswered(string group, long seq, Action close) { Group = group; Seq = seq; Close = close; }
    }

    /// <summary>A connection that proved its key and is waiting for the user's decision.</summary>
    public sealed class Waiting
    {
        public string DeviceId { get; }
        internal readonly string Group;
        internal readonly long Seq;
        internal readonly Action? Close;
        internal Waiting(string deviceId, string group, long seq, Action? close) { DeviceId = deviceId; Group = group; Seq = seq; Close = close; }
    }

    private readonly object _lock = new();
    private readonly List<Unanswered> _unanswered = new();
    private readonly List<Waiting> _waiting = new();
    private long _nextSeq;
    private readonly Dictionary<string, int> _sessions = new();
    private int _clearSessions;
    private bool? _approvalOverride;
    private bool _lastSeenApproval;
    private System.Threading.Timer? _settingTimer;
    private readonly Func<bool> _readStored;

    /// <summary><paramref name="requireApproval"/> null reads the user's setting; self-tests pass a value.</summary>
    public HostAuth(string? stateFolder = null, HostIdentity? identity = null, bool? requireApproval = null,
        bool watch = true, TimeSpan? settingPollInterval = null, Func<bool>? readStored = null,
        Func<double>? now = null, TimeSpan? lockTimeout = null)
    {
        _readStored = readStored ?? HostSettings.ReadRequireApproval;
        Identity = identity ?? HostIdentity.Open();
        Store = new DeviceTrustStore(stateFolder, watch, now, lockTimeout: lockTimeout);
        _approvalOverride = requireApproval;
        HostName = ComputerName();
        _lastSeenApproval = RequireApproval;
        if (watch)
        {
            var every = settingPollInterval ?? TimeSpan.FromSeconds(5);
            _settingTimer = new System.Threading.Timer(_ => NoteApproval(), null, every, every);
        }
    }

    public void Dispose()
    {
        _settingTimer?.Dispose();
        Store.Dispose();
    }

    // MARK: approval on or off

    /// <summary>True unless the user turned device approval off.</summary>
    public bool RequireApproval
    {
        get
        {
            bool? o;
            lock (_lock) o = _approvalOverride;
            return o ?? _readStored();
        }
    }

    /// <summary>For self-tests: null goes back to the user's setting.</summary>
    public void OverrideRequireApproval(bool? value)
    {
        lock (_lock) _approvalOverride = value;
        NoteApproval();
    }

    /// <summary>Saves the user's choice and tells the listeners.</summary>
    public void SetRequireApproval(bool on)
    {
        HostSettings.WriteRequireApproval(on);
        NoteApproval();
    }

    private void NoteApproval()
    {
        var current = RequireApproval;
        bool changed;
        lock (_lock)
        {
            changed = _lastSeenApproval != current;
            _lastSeenApproval = current;
        }
        if (!changed) return;
        Log.Line($"DEVICES: device approval is now {(current ? "on" : "OFF - any device that reaches this PC can control it")}");
        try { ApprovalDidChange?.Invoke(); }
        catch (Exception e) { Log.Line($"DEVICES: an approval handler failed: {e.Message}"); }
    }

    // MARK: connections that have not got in yet

    /// <summary>Counts a connection that was just sent the challenge. Room is shared out by address
    /// group: a group at its share, or a full table, costs the oldest connection of the group holding
    /// the most. A connection with no group is counted against the whole table only. <paramref name="close"/>
    /// may be called on any thread; it is called for the connection that lost its place, which is the new
    /// one when it is turned away.</summary>
    public Unanswered AddUnanswered(string? group, Action close)
    {
        Unanswered token;
        Unanswered? closing = null;
        lock (_lock)
        {
            _nextSeq++;
            token = new Unanswered(group ?? "", _nextSeq, close);
            var entries = _unanswered.Select(u => new RoomSharing.Entry(u.Group, _nextSeq - u.Seq)).ToList();
            int share = group == null ? MaxUnansweredConnections : MaxUnansweredPerGroup;
            var verdict = RoomSharing.Decide(entries, MaxUnansweredConnections, share, token.Group);
            switch (verdict.Kind)
            {
                case RoomSharing.VerdictKind.Admit:
                    _unanswered.Add(token);
                    break;
                case RoomSharing.VerdictKind.Replace:
                    closing = _unanswered[verdict.Index];
                    _unanswered.RemoveAt(verdict.Index);
                    _unanswered.Add(token);
                    break;
                default:
                    closing = token;
                    break;
            }
        }
        closing?.Close();
        return token;
    }

    public void RemoveUnanswered(Unanswered token)
    {
        lock (_lock) _unanswered.Remove(token);
    }

    /// <summary>Counts a connection that starts waiting for approval, sharing the table out by address
    /// group. Null when the connection is turned away. <paramref name="close"/> is called, on any thread,
    /// for a waiting connection that loses its place to this one.</summary>
    public Waiting? AdmitWaitingConnection(string deviceId, string group, Action close)
    {
        Waiting token;
        Waiting? closing = null;
        Waiting? admitted;
        lock (_lock)
        {
            _nextSeq++;
            token = new Waiting(deviceId, group, _nextSeq, close);
            admitted = token;
            var entries = _waiting.Select(w => new RoomSharing.Entry(w.Group, _nextSeq - w.Seq, w.Close != null)).ToList();
            var verdict = RoomSharing.Decide(entries, MaxWaitingConnections, MaxWaitingConnectionsPerGroup, group);
            switch (verdict.Kind)
            {
                case RoomSharing.VerdictKind.Admit:
                    _waiting.Add(token);
                    break;
                case RoomSharing.VerdictKind.Replace:
                    closing = _waiting[verdict.Index];
                    _waiting.RemoveAt(verdict.Index);
                    _waiting.Add(token);
                    break;
                default:
                    admitted = null;
                    break;
            }
        }
        closing?.Close?.Invoke();
        return admitted;
    }

    public void ReleaseWaiting(Waiting token)
    {
        lock (_lock) _waiting.Remove(token);
    }

    public bool HasWaitingConnection(string deviceId)
    {
        lock (_lock) return _waiting.Any(w => w.DeviceId == deviceId);
    }

    // MARK: sessions that are open now

    /// <summary>Counts a session a device was let into, so the host can show who is connected.
    /// <paramref name="deviceId"/> null is a clear session, which has no device.</summary>
    public void SessionOpened(string? deviceId)
    {
        lock (_lock)
        {
            if (deviceId == null) _clearSessions++;
            else _sessions[deviceId] = _sessions.GetValueOrDefault(deviceId) + 1;
        }
    }

    public void SessionClosed(string? deviceId)
    {
        lock (_lock)
        {
            if (deviceId == null) { _clearSessions = Math.Max(0, _clearSessions - 1); return; }
            if (!_sessions.TryGetValue(deviceId, out var n)) return;
            if (n > 1) _sessions[deviceId] = n - 1; else _sessions.Remove(deviceId);
        }
    }

    /// <summary>How many sessions each device has open in this process now, and how many clear
    /// sessions are open besides.</summary>
    public (Dictionary<string, int> Devices, int Clear) OpenSessions()
    {
        lock (_lock) return (new Dictionary<string, int>(_sessions), _clearSessions);
    }

    /// <summary>How many open sessions no approval stands behind: the clear ones, and those of
    /// devices that are not on the trusted list. Only a host with approval off has any.</summary>
    public int UnapprovedSessions()
    {
        var open = OpenSessions();
        if (open.Devices.Count == 0) return open.Clear;
        var trusted = Store.All().Where(r => r.State == DeviceState.Trusted).Select(r => r.Id).ToHashSet();
        return open.Clear + open.Devices.Where(d => !trusted.Contains(d.Key)).Sum(d => d.Value);
    }

    private static string ComputerName()
    {
        var name = AuthWire.CleanName(Environment.MachineName);
        return name.Length > 0 ? name : "Windows PC";
    }
}

/// <summary>Where this host's displays can be reached, as told to the devices it lets in (HOST_INFO),
/// and the addresses those devices say they came in on (CLIENT_INFO). An address here is a hint:
/// whatever a client dials still has to pass the handshake with the host key it saved. Unlike the Mac
/// host, the addresses clients reported are kept for this run only.</summary>
internal sealed class HostDirectory
{
    public sealed record DisplayEntry(int Index, string Name, bool Primary, int Port);

    public const int MaxUrlBytes = 256;
    public const int MaxUrlsPerDisplay = 16;
    public const int MaxDisplays = 8;

    private readonly object _lock = new();
    private List<DisplayEntry> _displays = new();
    private readonly Dictionary<int, List<string>> _reported = new();

    public void SetDisplays(IEnumerable<DisplayEntry> list)
    {
        lock (_lock) _displays = list.ToList();
    }

    /// <summary>Keeps an address a trusted device says it connected to. The caller has checked that the
    /// device is trusted.</summary>
    public void Report(string raw, int display)
    {
        if (display < 0 || display >= MaxDisplays) return;
        var url = CleanUrl(raw);
        if (url == null) return;
        lock (_lock)
        {
            if (!_reported.TryGetValue(display, out var list)) _reported[display] = list = new List<string>();
            list.Remove(url);
            list.Add(url);
            if (list.Count > MaxUrlsPerDisplay) list.RemoveRange(0, list.Count - MaxUrlsPerDisplay);
        }
    }

    public List<string> ReportedUrls(int display)
    {
        lock (_lock) return _reported.TryGetValue(display, out var l) ? new List<string>(l) : new List<string>();
    }

    /// <summary>A reported address as the host will keep it, or null: ws:// or wss://, at most 256
    /// bytes, no user info, query or fragment.</summary>
    public static string? CleanUrl(string raw)
    {
        if (raw.Length == 0 || Encoding.UTF8.GetByteCount(raw) > MaxUrlBytes) return null;
        foreach (var c in raw)
        {
            bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || "-._~:/[]%".IndexOf(c) >= 0;
            if (!ok) return null;
        }
        if (!Uri.TryCreate(raw, UriKind.Absolute, out var uri)) return null;
        if (uri.Scheme != "ws" && uri.Scheme != "wss") return null;
        if (uri.Host.Length == 0 || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0) return null;
        return raw;
    }

    /// <summary>HOST_INFO. <paramref name="display"/> is the index the asking connection serves. Addresses
    /// reported by clients are included only for a trusted device.</summary>
    public byte[] HostInfo(string name, string hostId, int? display, bool includeReported)
    {
        List<DisplayEntry> displays;
        Dictionary<int, List<string>> reported;
        lock (_lock)
        {
            displays = _displays.ToList();
            reported = _reported.ToDictionary(p => p.Key, p => new List<string>(p.Value));
        }
        var hosts = OwnHosts();
        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms))
        {
            w.WriteStartObject();
            if (display != null) w.WriteNumber("display", display.Value);
            w.WriteStartArray("displays");
            foreach (var d in displays)
            {
                var urls = hosts.Select(h => $"ws://{h}:{d.Port}").ToList();
                if (includeReported && reported.TryGetValue(d.Index, out var rep))
                {
                    // Most recently used first.
                    for (int i = rep.Count - 1; i >= 0; i--) if (!urls.Contains(rep[i])) urls.Add(rep[i]);
                }
                w.WriteStartObject();
                w.WriteNumber("index", d.Index);
                w.WriteString("name", d.Name);
                w.WriteBoolean("primary", d.Primary);
                w.WriteStartArray("urls");
                foreach (var u in urls) w.WriteStringValue(u);
                w.WriteEndArray();
                w.WriteEndObject();
            }
            w.WriteEndArray();
            w.WriteString("hostId", hostId);
            w.WriteString("kind", "windows");
            w.WriteString("name", AuthWire.CleanName(name));
            w.WriteString("version", Version);
            w.WriteEndObject();
        }
        return ms.ToArray();
    }

    public static string Version =>
        System.Reflection.Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "dev";

    /// <summary>The IPv4 address of each interface that is up, except loopback and self-assigned ones.</summary>
    public static List<string> OwnHosts()
    {
        var hosts = new List<string>();
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up || nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                foreach (var ua in nic.GetIPProperties().UnicastAddresses)
                {
                    if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                    var text = ua.Address.ToString();
                    if (text.StartsWith("169.254.", StringComparison.Ordinal) || hosts.Contains(text)) continue;
                    hosts.Add(text);
                }
            }
        }
        catch (Exception e) when (e is NetworkInformationException or System.ComponentModel.Win32Exception)
        {
            Log.Line($"host info: could not list this PC's addresses ({e.Message})");
        }
        return hosts;
    }
}
