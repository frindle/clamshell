using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Clamshell.Auth;

namespace Clamshell;

// The list of devices this host knows: trusted, denied, or waiting for the user
// to decide (PROTOCOL.md "Device authentication and encrypted session"). The
// Mac host's Auth/DeviceTrustStore.swift is the reference for the records, the
// states and the limits.
//
// The list lives in one file, devices.dat, in the host's state folder
// (%LOCALAPPDATA%\Clamshell, or CLAMSHELL_STATE_DIR). The file is the truth:
// the tray app, the command line (`ClamshellServer approve ...`) and the
// self-tests are separate processes, so every change takes a lock file, reads
// the list again, changes it and writes it back in one step, and a running
// host notices a change made elsewhere by watching the folder (and, in case a
// notification is missed, by reading it again every few seconds).
//
// The file is protected with DPAPI for the current user, so a copy of it that
// leaves this account is unreadable. A process running as the same Windows user
// can call DPAPI as well: this is not a defence against that.
//
// Stricter than the Mac host: a file that cannot be read, decrypted or parsed,
// or that holds any entry that is not valid, is not "moved aside and started
// over". It fails closed: nothing is trusted, nothing is written over it, and
// the tray and the command line say so (see ListProblem).
//
// A device is trusted only by a decision of the user. Nothing in here trusts a
// device because of its name or the address it came from.

internal enum DeviceState { Trusted, Denied, Waiting }

internal sealed record DeviceRecord(
    string Id,
    string PublicKey,
    string Name,
    DeviceState State,
    double FirstSeen,
    double LastSeen,
    string Address,
    double? DecidedAt,
    string? DecidedBy)
{
    public string Fingerprint => DeviceIdentity.Fingerprint(Id);
    public string Label => Name.Length == 0 ? "Unnamed device" : Name;
}

/// <summary>Where the host keeps what has to outlive a run.</summary>
internal static class HostState
{
    /// <summary>CLAMSHELL_STATE_DIR if set, else %LOCALAPPDATA%\Clamshell.</summary>
    public static string Directory
    {
        get
        {
            var env = Environment.GetEnvironmentVariable("CLAMSHELL_STATE_DIR");
            if (!string.IsNullOrEmpty(env)) return env;
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Clamshell");
        }
    }
}

/// <summary>DPAPI (crypt32), current-user scope. ProtectedData is not in the
/// shared framework this project builds against, and no new package is added.</summary>
internal static class Dpapi
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("clamshell-devices-v1");
    private const int UiForbidden = 0x1;

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public int cbData;
        public IntPtr pbData;
    }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptProtectData(ref DataBlob dataIn, string? description, ref DataBlob entropy,
        IntPtr reserved, IntPtr prompt, int flags, out DataBlob dataOut);

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptUnprotectData(ref DataBlob dataIn, IntPtr description, ref DataBlob entropy,
        IntPtr reserved, IntPtr prompt, int flags, out DataBlob dataOut);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr mem);

    public static byte[] Protect(byte[] plain) => Run(plain, protect: true);

    /// <summary>Throws <see cref="CryptographicException"/> when the data is not DPAPI data
    /// for this user, or is damaged.</summary>
    public static byte[] Unprotect(byte[] blob) => Run(blob, protect: false);

    private static unsafe byte[] Run(byte[] input, bool protect)
    {
        fixed (byte* pIn = input.Length == 0 ? new byte[1] : input)
        fixed (byte* pEntropy = Entropy)
        {
            var inBlob = new DataBlob { cbData = input.Length, pbData = (IntPtr)pIn };
            var entropy = new DataBlob { cbData = Entropy.Length, pbData = (IntPtr)pEntropy };
            DataBlob outBlob;
            bool ok = protect
                ? CryptProtectData(ref inBlob, null, ref entropy, IntPtr.Zero, IntPtr.Zero, UiForbidden, out outBlob)
                : CryptUnprotectData(ref inBlob, IntPtr.Zero, ref entropy, IntPtr.Zero, IntPtr.Zero, UiForbidden, out outBlob);
            if (!ok)
            {
                int code = Marshal.GetLastWin32Error();
                throw new CryptographicException($"DPAPI {(protect ? "protect" : "unprotect")} failed (Win32 error {code}).");
            }
            try
            {
                var result = new byte[outBlob.cbData];
                Marshal.Copy(outBlob.pbData, result, 0, outBlob.cbData);
                return result;
            }
            finally
            {
                LocalFree(outBlob.pbData);
            }
        }
    }
}

internal sealed class DeviceTrustStore : IDisposable
{
    public const string FileName = "devices.dat";
    public const string LockName = "devices.lock";
    public const int MaxWaiting = 16;
    public const int MaxNewPerMinute = 10;
    /// <summary>What one address group may hold of the waiting list, and add in a minute.</summary>
    public const int MaxWaitingPerGroup = 4;
    public const int MaxNewPerMinutePerGroup = 3;
    /// <summary>A waiting device seen this recently (seconds) is not replaced by a newcomer.</summary>
    public const double RecentlySeen = 5 * 60;
    public const double WaitingLifetime = 24 * 60 * 60;
    public const int MaxFileBytes = 1 << 20;
    /// <summary>The list format this build reads and writes.</summary>
    public const int FileVersion = 1;
    public const string DecidedOnHost = "host";
    public const string DecidedOnCommandLine = "cli";

    public enum Answer { Trusted, Denied, Waiting, Busy }
    public enum Decision { Approve, Deny }
    public enum MatchKind { One, None, Ambiguous, BadQuery }
    public readonly record struct Match(MatchKind Kind, IReadOnlyList<DeviceRecord> Records);

    /// <summary>Why the list cannot be used, or why the last change was not made.</summary>
    public enum Problem
    {
        None,
        /// <summary>The lock file could not be taken in time.</summary>
        LockNotTaken,
        /// <summary>The list was written by a newer Clamshell and is left alone.</summary>
        NewerVersion,
        /// <summary>The list is there but cannot be decrypted or parsed, or an entry is not valid.</summary>
        Damaged,
        /// <summary>The list is there but could not be read right now.</summary>
        Unreadable,
        /// <summary>The list could not be written.</summary>
        NotSaved,
    }

    public string Folder { get; }
    public string FilePath { get; }
    /// <summary>False when the folder cannot be used: the list then lives in memory
    /// for this run, and other processes cannot see or change it.</summary>
    public bool CanPersist { get; }

    private readonly object _gate = new();
    private readonly Func<double> _now;
    private readonly TimeSpan _lockTimeout;
    private readonly TimeSpan _reloadInterval;
    private List<DeviceRecord> _records = new();
    private readonly List<(double Time, string? Group)> _recentAdds = new();
    private bool _dryRun;
    private FileSystemWatcher? _watcher;
    private System.Threading.Timer? _fallback;
    private System.Threading.Timer? _debounce;
    private bool _loggedProblem;

    /// <summary>Raised after the list (or the problem with it) changes for any reason,
    /// on whatever thread made or noticed the change.</summary>
    public event Action? DidChange;

    /// <summary>What is wrong with the list on disk right now: None, NewerVersion,
    /// Damaged or Unreadable. While it is not None, nobody is trusted and nothing is
    /// written.</summary>
    public Problem ListProblem { get; private set; }
    private string _listDetail = "";

    /// <summary>Why the last change was not made, if it was not: for the command line
    /// and the tray to say.</summary>
    public Problem LastProblem { get; private set; }

    /// <summary>A sentence for the tray and the command line when <see cref="ListProblem"/> is not
    /// None or the folder cannot be used; otherwise null.</summary>
    public string? ProblemMessage
    {
        get
        {
            if (!CanPersist)
                return $"The device list folder ({Folder}) cannot be used, so the list lasts for this run only and the command line cannot see it.";
            return ListProblem switch
            {
                Problem.NewerVersion => $"The device list ({FilePath}) was written by a newer Clamshell. This one leaves it alone, "
                    + "trusts nobody and cannot show or change it. Update Clamshell on this PC.",
                Problem.Damaged => $"The device list ({FilePath}) is damaged ({_listDetail}). It was left as it is and nobody is "
                    + "trusted. Move or delete the file yourself to start again.",
                Problem.Unreadable => $"The device list ({FilePath}) cannot be read right now ({_listDetail}). Nobody is trusted until it can.",
                _ => null,
            };
        }
    }

    public DeviceTrustStore(string? folder = null, bool watch = true, Func<double>? now = null,
        TimeSpan? reloadInterval = null, TimeSpan? lockTimeout = null)
    {
        Folder = folder ?? HostState.Directory;
        FilePath = Path.Combine(Folder, FileName);
        _now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0);
        _reloadInterval = reloadInterval ?? TimeSpan.FromSeconds(5);
        _lockTimeout = lockTimeout ?? TimeSpan.FromSeconds(2);
        try
        {
            Directory.CreateDirectory(Folder);
            SweepTemporaryFiles();
            CanPersist = true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            CanPersist = false;
            Log.Line($"DEVICES: cannot keep the device list in {Folder} ({e.Message}) - it will last for this run only");
        }
        if (CanPersist)
        {
            var read = ReadDisk();
            SetListProblem(read);
            _records = read.List ?? new();
            if (watch) StartWatching();
        }
    }

    public void Dispose()
    {
        _watcher?.Dispose();
        _fallback?.Dispose();
        _debounce?.Dispose();
    }

    // MARK: reading

    /// <summary>Every device, without waiting devices whose 24 hours have run out.</summary>
    public List<DeviceRecord> All()
    {
        lock (_gate)
        {
            double t = _now();
            return _records.Where(r => !IsExpired(r, t)).ToList();
        }
    }

    public DeviceRecord? Record(string id) => All().FirstOrDefault(r => r.Id == id);
    public DeviceState? StateOf(string id) => Record(id)?.State;
    public bool IsTrusted(string id) => StateOf(id) == DeviceState.Trusted;

    /// <summary>Oldest first.</summary>
    public List<DeviceRecord> Waiting() =>
        All().Where(r => r.State == DeviceState.Waiting).OrderBy(r => r.FirstSeen).ToList();

    /// <summary>Finds a device by its full id or its 16-digit fingerprint; dashes, spaces
    /// and case do not matter. More than one hit is never guessed at.</summary>
    public Match Resolve(string query)
    {
        var sb = new StringBuilder();
        foreach (var c in query.ToLowerInvariant()) if (c != '-' && c != ' ') sb.Append(c);
        var q = sb.ToString();
        if (q.Length != 16 && q.Length != 64) return new Match(MatchKind.BadQuery, Array.Empty<DeviceRecord>());
        foreach (var c in q)
        {
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
                return new Match(MatchKind.BadQuery, Array.Empty<DeviceRecord>());
        }
        var hits = All().Where(r => r.Id.StartsWith(q, StringComparison.Ordinal)).ToList();
        return hits.Count switch
        {
            0 => new Match(MatchKind.None, hits),
            1 => new Match(MatchKind.One, hits),
            _ => new Match(MatchKind.Ambiguous, hits),
        };
    }

    // MARK: a device asking

    /// <summary>A device that proved it holds <paramref name="publicKey"/> is asking to connect
    /// while approval is on. Unknown devices join the waiting list, within its limits.
    /// <paramref name="hasOpenConnection"/> says whether a waiting device still has a connection
    /// open: only one without is ever replaced. It is called with the store locked, so it must
    /// not call the store.
    ///
    /// <paramref name="group"/> is the asker's address group (<see cref="AddressGroup.Of"/>). With one,
    /// room on the list is shared out by group (<see cref="RoomSharing"/>): a group holds at most
    /// <see cref="MaxWaitingPerGroup"/> waiting devices and lists at most
    /// <see cref="MaxNewPerMinutePerGroup"/> a minute, and a waiting device seen in the last
    /// <see cref="RecentlySeen"/> seconds is never replaced. Without one only the limits for the
    /// whole list apply.</summary>
    public Answer Ask(byte[] publicKey, string name, string address, string? group, Func<string, bool> hasOpenConnection)
    {
        if (!DeviceIdentity.IsValidPublicKey(publicKey)) return Answer.Denied;
        var id = DeviceIdentity.Id(publicKey);
        name = StoredName(name);
        address = AuthWire.CleanName(address);
        return Mutate((list, t) =>
        {
            int i = list.FindIndex(r => r.Id == id);
            if (i >= 0)
            {
                // A known device gets the same answer whether or not the note of this visit could be saved.
                switch (list[i].State)
                {
                    case DeviceState.Denied:
                        // Nothing is recorded, so a denied device cannot make the host write
                        // to disk by reconnecting.
                        return (Answer.Denied, Answer.Denied);
                    case DeviceState.Trusted:
                        list[i] = Refreshed(list[i], name, address, t, atMostEvery: 60, soonerIfChanged: true, keepName: false);
                        return (Answer.Trusted, Answer.Trusted);
                    default:
                        // It keeps the name it was first listed with until it is approved, so a
                        // name cannot be swapped under the user's eyes while the question is open.
                        list[i] = Refreshed(list[i], name, address, t, atMostEvery: 10, soonerIfChanged: false, keepName: true);
                        return (Answer.Waiting, Answer.Waiting);
                }
            }
            _recentAdds.RemoveAll(a => t - a.Time >= 60 || t < a.Time);
            if (_recentAdds.Count >= MaxNewPerMinute) return (Answer.Busy, Answer.Busy);
            if (group != null && _recentAdds.Count(a => a.Group == group) >= MaxNewPerMinutePerGroup)
                return (Answer.Busy, Answer.Busy);
            var waiting = list.Where(r => r.State == DeviceState.Waiting).OrderBy(r => r.FirstSeen).ToList();
            if (group != null)
            {
                var entries = waiting.Select(r => new RoomSharing.Entry(
                    AddressGroup.Of(r.Address), t - r.LastSeen,
                    Removable: !hasOpenConnection(r.Id) && t - r.LastSeen >= RecentlySeen)).ToList();
                var verdict = RoomSharing.Decide(entries, MaxWaiting, MaxWaitingPerGroup, group);
                switch (verdict.Kind)
                {
                    case RoomSharing.VerdictKind.Admit: break;
                    case RoomSharing.VerdictKind.Replace:
                        var gone = waiting[verdict.Index].Id;
                        list.RemoveAll(r => r.Id == gone);
                        break;
                    default: return (Answer.Busy, Answer.Busy);
                }
            }
            else if (waiting.Count >= MaxWaiting)
            {
                var stale = waiting.FirstOrDefault(r => !hasOpenConnection(r.Id));
                if (stale == null) return (Answer.Busy, Answer.Busy);
                list.RemoveAll(r => r.Id == stale.Id);
            }
            if (!_dryRun) _recentAdds.Add((t, group));
            list.Add(new DeviceRecord(id, Hex.Encode(publicKey), name, DeviceState.Waiting, t, t, address, null, null));
            // A device that could not be listed cannot be approved either.
            return (Answer.Waiting, Answer.Busy);
        });
    }

    /// <summary>For self-tests that list more new devices from one address in a minute than the
    /// host allows: forgets the new devices counted so far.</summary>
    public void ForgetRecentAdds()
    {
        lock (_gate) _recentAdds.Clear();
    }

    /// <summary>A device connected to a host that is not asking for approval: keeps a trusted
    /// device's name, address and last-seen time fresh. Adds nothing.</summary>
    public void NoteConnected(string id, string name, string address)
    {
        name = StoredName(name);
        address = AuthWire.CleanName(address);
        Mutate<bool>((list, t) =>
        {
            int i = list.FindIndex(r => r.Id == id);
            if (i < 0 || list[i].State != DeviceState.Trusted) return (false, false);
            list[i] = Refreshed(list[i], name, address, t, atMostEvery: 60, soonerIfChanged: true, keepName: false);
            return (true, true);
        });
    }

    // MARK: decisions

    /// <summary>Approves or denies a device. <paramref name="by"/> says where the decision was made.
    /// Returns the record as it now stands, or null if nothing changed.</summary>
    public DeviceRecord? Decide(string id, Decision decision, string by, bool onlyIfWaiting)
    {
        return Mutate<DeviceRecord?>((list, t) =>
        {
            int i = list.FindIndex(r => r.Id == id);
            if (i < 0) return (null, null);
            if (onlyIfWaiting && list[i].State != DeviceState.Waiting) return (null, null);
            DeviceState target;
            if (decision == Decision.Approve && (list[i].State == DeviceState.Waiting || list[i].State == DeviceState.Denied))
                target = DeviceState.Trusted;
            else if (decision == Decision.Deny && list[i].State == DeviceState.Waiting)
                target = DeviceState.Denied;
            else return (null, null);
            list[i] = list[i] with { State = target, DecidedAt = t, DecidedBy = by };
            return (list[i], null);
        });
    }

    /// <summary>Takes trust away from a device: it becomes denied.</summary>
    public DeviceRecord? Revoke(string id, string by)
    {
        return Mutate<DeviceRecord?>((list, t) =>
        {
            int i = list.FindIndex(r => r.Id == id);
            if (i < 0 || list[i].State != DeviceState.Trusted) return (null, null);
            list[i] = list[i] with { State = DeviceState.Denied, DecidedAt = t, DecidedBy = by };
            return (list[i], null);
        });
    }

    /// <summary>Removes a device whatever its state, so it may ask again.</summary>
    public DeviceRecord? Forget(string id)
    {
        return Mutate<DeviceRecord?>((list, _) =>
        {
            int i = list.FindIndex(r => r.Id == id);
            if (i < 0) return (null, null);
            var gone = list[i];
            list.RemoveAt(i);
            return (gone, null);
        });
    }

    // MARK: the file

    /// <summary>Runs <paramref name="body"/> on the freshest list under the lock file, saves what it
    /// changed and tells observers. <paramref name="body"/> returns its answer, and the answer to give
    /// instead when the change could not be saved; in that case the list stays as it was on disk.
    ///
    /// If the lock cannot be taken, nothing is changed or written: the answer is the one for an
    /// unsaved change, worked out on an empty list so that nobody is let in on the strength of a
    /// list that may be out of date. If the list on disk cannot be used (see
    /// <see cref="ListProblem"/>) nothing is written either.</summary>
    private T Mutate<T>(Func<List<DeviceRecord>, double, (T Saved, T Unsaved)> body)
    {
        List<DeviceRecord> before;
        List<DeviceRecord> after;
        Problem problemBefore;
        T result;
        lock (_gate)
        {
            before = _records;
            problemBefore = ListProblem;
            LastProblem = Problem.None;
            double t = _now();
            FileStream? fileLock = null;
            try
            {
                if (CanPersist)
                {
                    fileLock = TakeLock();
                    if (fileLock == null)
                    {
                        Log.Line($"DEVICES: the device list's lock could not be taken within {(int)_lockTimeout.TotalSeconds} s - nothing was changed");
                        LastProblem = Problem.LockNotTaken;
                        var none = new List<DeviceRecord>();
                        _dryRun = true;
                        try { return body(none, t).Unsaved; }
                        finally { _dryRun = false; }
                    }
                }
                // null: there is a list on disk and it cannot be used right now.
                List<DeviceRecord>? disk;
                if (CanPersist)
                {
                    var read = ReadDisk();
                    SetListProblem(read);
                    disk = read.List;
                }
                else disk = _records;
                var start = disk ?? new List<DeviceRecord>();
                var list = start.Where(r => !IsExpired(r, t)).ToList();
                var answer = body(list, t);
                result = answer.Saved;
                if (CanPersist && !list.SequenceEqual(start))
                {
                    bool saved = false;
                    if (disk == null)
                    {
                        LastProblem = ListProblem;
                        if (ListProblem == Problem.Damaged || ListProblem == Problem.Unreadable)
                            Log.Line("DEVICES: the device list cannot be used, so nothing was changed");
                    }
                    else
                    {
                        try
                        {
                            Write(list);
                            saved = true;
                        }
                        catch (Exception e) when (e is IOException or UnauthorizedAccessException or CryptographicException)
                        {
                            LastProblem = Problem.NotSaved;
                            Log.Line($"DEVICES: could not save the device list ({e.Message}) - nothing was changed");
                        }
                    }
                    if (!saved)
                    {
                        list = start;
                        result = answer.Unsaved;
                    }
                }
                _records = list;
                after = list;
            }
            finally
            {
                fileLock?.Dispose();
            }
        }
        if (!after.SequenceEqual(before) || ListProblem != problemBefore) RaiseDidChange();
        return result;
    }

    /// <summary>Reads the list again after another process changed it.</summary>
    public void Reload()
    {
        if (!CanPersist) return;
        bool changed;
        lock (_gate)
        {
            var before = _records;
            var problemBefore = ListProblem;
            var read = ReadDisk();
            // A save by another process can replace the file at the moment it is opened.
            for (int tries = 0; tries < 3 && read.Problem == Problem.Unreadable; tries++)
            {
                Thread.Sleep(30);
                read = ReadDisk();
            }
            SetListProblem(read);
            _records = read.List ?? new List<DeviceRecord>();
            changed = !_records.SequenceEqual(before) || ListProblem != problemBefore;
        }
        if (changed) RaiseDidChange();
    }

    private void RaiseDidChange()
    {
        try { DidChange?.Invoke(); }
        catch (Exception e) { Log.Line($"DEVICES: a change handler failed: {e.Message}"); }
    }

    private void SetListProblem((List<DeviceRecord>? List, Problem Problem, string Detail) read)
    {
        ListProblem = read.Problem;
        _listDetail = read.Detail;
        if (read.Problem == Problem.None) { _loggedProblem = false; return; }
        if (_loggedProblem) return;
        _loggedProblem = true;
        Log.Line($"DEVICES: {ProblemMessage}");
    }

    /// <summary>An exclusive lock on a file next to the list, held for one read-modify-write.
    /// The file is never deleted: removing it while another program waits on it would let two
    /// programs hold "the" lock. Null when it could not be taken in time.</summary>
    private FileStream? TakeLock()
    {
        var path = Path.Combine(Folder, LockName);
        var deadline = DateTime.UtcNow + _lockTimeout;
        while (true)
        {
            try
            {
                Directory.CreateDirectory(Folder);
                return new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                if (DateTime.UtcNow >= deadline) return null;
                Thread.Sleep(10);
            }
        }
    }

    /// <summary>The list on disk. No file means no devices. A file that cannot be used gives a null
    /// list and the reason: the caller then trusts nobody and leaves the file alone.</summary>
    private (List<DeviceRecord>? List, Problem Problem, string Detail) ReadDisk()
    {
        byte[] data;
        try
        {
            if (Directory.Exists(FilePath)) return (null, Problem.Damaged, "it is a folder");
            if (!File.Exists(FilePath)) return (new List<DeviceRecord>(), Problem.None, "");
            using var fs = new FileStream(FilePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (fs.Length > MaxFileBytes) return (null, Problem.Damaged, "it is larger than expected");
            data = new byte[fs.Length];
            fs.ReadExactly(data);
        }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException)
        {
            return (new List<DeviceRecord>(), Problem.None, "");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return (null, Problem.Unreadable, e.Message);
        }
        byte[] plain;
        try { plain = Dpapi.Unprotect(data); }
        catch (CryptographicException) { return (null, Problem.Damaged, "it cannot be decrypted, or it was written by another user"); }
        return Parse(plain);
    }

    private static (List<DeviceRecord>? List, Problem Problem, string Detail) Parse(byte[] plain)
    {
        try
        {
            using var doc = JsonDocument.Parse(plain);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("version", out var v)
                || v.ValueKind != JsonValueKind.Number || !v.TryGetInt32(out int version))
                return (null, Problem.Damaged, "it has no version");
            if (version > FileVersion) return (null, Problem.NewerVersion, $"list version {version}");
            if (version != FileVersion) return (null, Problem.Damaged, $"it is not a version {FileVersion} list");
            if (!root.TryGetProperty("devices", out var devices) || devices.ValueKind != JsonValueKind.Array)
                return (null, Problem.Damaged, "it has no devices list");
            var list = new List<DeviceRecord>();
            var seen = new HashSet<string>();
            foreach (var d in devices.EnumerateArray())
            {
                var record = ParseRecord(d);
                if (record == null) return (null, Problem.Damaged, "an entry is not valid");
                if (!seen.Add(record.Id)) return (null, Problem.Damaged, "an id appears twice");
                list.Add(record);
            }
            if (list.Count(r => r.State == DeviceState.Waiting) > MaxWaiting)
                return (null, Problem.Damaged, "it holds more waiting devices than the host allows");
            return (list, Problem.None, "");
        }
        catch (JsonException) { return (null, Problem.Damaged, "it is not a device list"); }
        catch (InvalidOperationException) { return (null, Problem.Damaged, "it is not a device list"); }
    }

    private static string? Str(JsonElement o, string name) =>
        o.TryGetProperty(name, out var p) && p.ValueKind == JsonValueKind.String ? p.GetString() : null;

    private static double? Num(JsonElement o, string name) =>
        o.TryGetProperty(name, out var p) && p.ValueKind == JsonValueKind.Number && p.TryGetDouble(out var d)
        && double.IsFinite(d) ? d : null;

    /// <summary>A record that holds a real key whose hash is its id, a known state and finite
    /// times; null for anything else, so an edited file cannot give one device another's id.</summary>
    private static DeviceRecord? ParseRecord(JsonElement d)
    {
        if (d.ValueKind != JsonValueKind.Object) return null;
        var id = Str(d, "id");
        var keyHex = Str(d, "publicKey");
        var name = Str(d, "name");
        var state = Str(d, "state");
        var address = Str(d, "address");
        var first = Num(d, "firstSeen");
        var last = Num(d, "lastSeen");
        if (id == null || keyHex == null || name == null || state == null || address == null || first == null || last == null)
            return null;
        var key = Hex.Decode(keyHex);
        if (key == null || !DeviceIdentity.IsValidPublicKey(key) || DeviceIdentity.Id(key) != id) return null;
        DeviceState s;
        switch (state)
        {
            case "trusted": s = DeviceState.Trusted; break;
            case "denied": s = DeviceState.Denied; break;
            case "waiting": s = DeviceState.Waiting; break;
            default: return null;
        }
        double? decidedAt = null;
        if (d.TryGetProperty("decidedAt", out var da) && da.ValueKind != JsonValueKind.Null)
        {
            decidedAt = Num(d, "decidedAt");
            if (decidedAt == null) return null;
        }
        string? decidedBy = null;
        if (d.TryGetProperty("decidedBy", out var db) && db.ValueKind != JsonValueKind.Null)
        {
            decidedBy = Str(d, "decidedBy");
            if (decidedBy == null) return null;
            if (decidedBy != DecidedOnHost && decidedBy != DecidedOnCommandLine && !DeviceIdentity.IsWellFormedId(decidedBy))
                return null;
        }
        return new DeviceRecord(id, Hex.Encode(key), StoredName(name), s, first.Value, last.Value,
            AuthWire.CleanName(address), decidedAt, decidedBy);
    }

    private static string Serialize(List<DeviceRecord> list)
    {
        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms, new JsonWriterOptions { Indented = true }))
        {
            w.WriteStartObject();
            w.WriteNumber("version", FileVersion);
            w.WriteStartArray("devices");
            foreach (var r in list)
            {
                w.WriteStartObject();
                w.WriteString("id", r.Id);
                w.WriteString("publicKey", r.PublicKey);
                w.WriteString("name", r.Name);
                w.WriteString("state", r.State switch
                {
                    DeviceState.Trusted => "trusted",
                    DeviceState.Denied => "denied",
                    _ => "waiting",
                });
                w.WriteNumber("firstSeen", r.FirstSeen);
                w.WriteNumber("lastSeen", r.LastSeen);
                w.WriteString("address", r.Address);
                if (r.DecidedAt != null) w.WriteNumber("decidedAt", r.DecidedAt.Value);
                if (r.DecidedBy != null) w.WriteString("decidedBy", r.DecidedBy);
                w.WriteEndObject();
            }
            w.WriteEndArray();
            w.WriteEndObject();
        }
        return Encoding.UTF8.GetString(ms.ToArray());
    }

    private void Write(List<DeviceRecord> list)
    {
        var blob = Dpapi.Protect(Encoding.UTF8.GetBytes(Serialize(list)));
        var temp = Path.Combine(Folder, TempPrefix + Guid.NewGuid().ToString("N"));
        try
        {
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(blob, 0, blob.Length);
                stream.Flush(true);
            }
            File.Move(temp, FilePath, overwrite: true);
        }
        catch
        {
            try { File.Delete(temp); } catch (Exception) { /* nothing more to do */ }
            throw;
        }
    }

    private const string TempPrefix = ".clamshell-tmp-";

    /// <summary>Temporary files a crashed run left behind, once they are an hour old.</summary>
    private void SweepTemporaryFiles()
    {
        try
        {
            var cutoff = DateTime.UtcNow.AddHours(-1);
            foreach (var path in Directory.EnumerateFiles(Folder, TempPrefix + "*"))
            {
                try { if (File.GetLastWriteTimeUtc(path) < cutoff) File.Delete(path); }
                catch (Exception) { /* best effort */ }
            }
        }
        catch (Exception) { /* best effort */ }
    }

    private static bool IsExpired(DeviceRecord r, double now) =>
        r.State == DeviceState.Waiting && now - r.FirstSeen > WaitingLifetime;

    /// <summary>A name as the host stores and shows it: cleaned the way every name is, and without
    /// the characters that draw nothing.</summary>
    public static string StoredName(string raw) => NameSkeleton.Visible(AuthWire.CleanName(raw));

    /// <summary>Notes a visit by a known device: its name, address and the time. A visit is written down
    /// at most every <paramref name="atMostEvery"/> seconds, or at once when the name or address changed
    /// and <paramref name="soonerIfChanged"/> allows it. A waiting device is not allowed that, so it
    /// cannot make the host write to disk as fast as it can reconnect.</summary>
    private static DeviceRecord Refreshed(DeviceRecord r, string name, string address, double now,
        double atMostEvery, bool soonerIfChanged, bool keepName)
    {
        bool due = now - r.LastSeen >= atMostEvery || now < r.LastSeen;
        bool changed = (!keepName && name.Length > 0 && name != r.Name) || address != r.Address;
        if (!(due || (soonerIfChanged && changed))) return r;
        return r with
        {
            Name = name.Length > 0 && !keepName ? name : r.Name,
            Address = address,
            LastSeen = now,
        };
    }

    // MARK: noticing other processes

    private void StartWatching()
    {
        try
        {
            _watcher = new FileSystemWatcher(Folder, FileName)
            {
                NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size | NotifyFilters.CreationTime,
                IncludeSubdirectories = false,
            };
            FileSystemEventHandler changed = (_, _) => ScheduleReload();
            _watcher.Changed += changed;
            _watcher.Created += changed;
            _watcher.Deleted += changed;
            _watcher.Renamed += (_, _) => ScheduleReload();
            _watcher.EnableRaisingEvents = true;
        }
        catch (Exception e)
        {
            Log.Line($"DEVICES: cannot watch {Folder} for changes ({e.Message}) - reading the device list again every {(int)_reloadInterval.TotalSeconds} s");
        }
        // Always on, not only when the watcher fails: a notification can be missed (a full
        // buffer, a network folder), and a revoke made by another process must not go unnoticed.
        _fallback = new System.Threading.Timer(_ => Reload(), null, _reloadInterval, _reloadInterval);
    }

    /// <summary>A save shows up as several events; one reload shortly after covers them.</summary>
    private void ScheduleReload()
    {
        _debounce ??= new System.Threading.Timer(_ => Reload());
        _debounce.Change(50, Timeout.Infinite);
    }
}
