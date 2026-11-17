using System.IO;
using System.Text;
using System.Text.Json;

namespace Clamshell.Auth;

// What a client remembers about the Macs it has met (PROTOCOL.md "Client
// rules"): each host's identity key, the name it last gave, and the addresses
// it has been reached at or has reported. No clock and no storage here: the
// caller passes the time in (seconds, any steady clock) and saves the encoded
// bytes (KnownHostsFile). Ported from Sources/Clamshell/Streaming/KnownHosts.swift.

/// <summary>An address the client dials for one host.</summary>
public sealed class KnownAddress
{
    /// <summary>Lower-cased host:port, no scheme and no path.</summary>
    public string Address { get; set; } = "";
    /// <summary>True once a handshake at this address ended with this host's key verified.</summary>
    public bool Verified { get; set; }
    /// <summary>When this address was last dialled, reported or confirmed. The oldest goes first when a host has too many.</summary>
    public double LastUsed { get; set; }
    /// <summary>The last verified handshake here.</summary>
    public double? LastSuccess { get; set; }

    public KnownAddress Clone() => (KnownAddress)MemberwiseClone();
}

/// <summary>One Mac the app has met.</summary>
public sealed class KnownHost
{
    /// <summary>The 65-byte identity key.</summary>
    public byte[] Key { get; set; } = Array.Empty<byte>();
    /// <summary>The name it last gave, cleaned for display.</summary>
    public string Name { get; set; } = "";
    public List<KnownAddress> Addresses { get; set; } = new();

    public string Id => DeviceIdentity.Id(Key);
    public string Fingerprint => DeviceIdentity.FingerprintOfKey(Key);

    public KnownHost Clone() => new KnownHost
    {
        Key = (byte[])Key.Clone(),
        Name = Name,
        Addresses = Addresses.Select(a => a.Clone()).ToList(),
    };
}

public enum StandingKind
{
    /// <summary>Nothing is known about the address.</summary>
    Unknown,
    /// <summary>Nothing is known about it, and the user allowed an unverified connection here before.</summary>
    UnknownAllowed,
    /// <summary>The address belongs to the host with <see cref="AddressStanding.HostId"/>.</summary>
    Host,
}

public readonly record struct AddressStanding(StandingKind Kind, string HostId)
{
    public static AddressStanding Unknown => new(StandingKind.Unknown, "");
    public static AddressStanding UnknownAllowed => new(StandingKind.UnknownAllowed, "");
    public static AddressStanding OfHost(string id) => new(StandingKind.Host, id);
}

public sealed class KnownHosts
{
    public const int MaxAddressesPerHost = 16;
    public const int MaxHintBytes = 256;
    public const int MaxAllowedAddresses = 64;
    public const int StoreVersion = 1;
    /// <summary>The port of a bare host with none given.</summary>
    public const int DefaultPort = 5903;

    private readonly List<KnownHost> _hosts = new();
    private readonly List<string> _allowed = new();

    public IReadOnlyList<KnownHost> Hosts => _hosts;
    /// <summary>Addresses the user let an unverified connection go to, oldest first.</summary>
    public IReadOnlyList<string> UnverifiedAllowed => _allowed;

    public KnownHosts Clone()
    {
        var copy = new KnownHosts();
        foreach (var h in _hosts) copy._hosts.Add(h.Clone());
        copy._allowed.AddRange(_allowed);
        return copy;
    }

    // MARK: Addresses

    private static bool IsSchemeOk(string scheme) => scheme == "ws" || scheme == "wss";

    /// <summary>The lower-cased host:port a client dials, from a bare host
    /// (default port 5903) or a ws/wss URL (default port 80 or 443). Scheme,
    /// path, user info, query and fragment are dropped, so /ws/a and /ws/b on
    /// one hostname are one address. null when the text is not an address.
    /// Only ASCII host names are accepted.</summary>
    public static string? NormalizeAddress(string text)
    {
        var trimmed = text.Trim(' ', '\t');
        if (trimmed.Length == 0) return null;
        int sep = trimmed.IndexOf("://", StringComparison.Ordinal);
        bool bare = sep < 0;
        string scheme = "ws";
        string rest = trimmed;
        if (!bare)
        {
            scheme = trimmed.Substring(0, sep).ToLowerInvariant();
            rest = trimmed.Substring(sep + 3);
        }
        if (!IsSchemeOk(scheme)) return null;

        int end = rest.IndexOfAny(new[] { '/', '?', '#' });
        string authority = end < 0 ? rest : rest.Substring(0, end);
        int at = authority.LastIndexOf('@');
        if (at >= 0) authority = authority.Substring(at + 1);

        string host;
        string? portText = null;
        if (authority.StartsWith('['))
        {
            int close = authority.IndexOf(']');
            if (close < 0) return null;
            host = authority.Substring(1, close - 1);
            var after = authority.Substring(close + 1);
            if (after.Length > 0)
            {
                if (after[0] != ':') return null;
                portText = after.Substring(1);
            }
            foreach (char c in host)
            {
                if (!(char.IsAsciiLetterOrDigit(c) || c == ':' || c == '.' || c == '%' || c == '-' || c == '_')) return null;
            }
            int zone = host.IndexOf('%');
            if (zone >= 0) host = host.Substring(0, zone);
        }
        else
        {
            int colon = authority.IndexOf(':');
            if (colon >= 0)
            {
                if (authority.IndexOf(':', colon + 1) >= 0) return null;
                host = authority.Substring(0, colon);
                portText = authority.Substring(colon + 1);
            }
            else
            {
                host = authority;
            }
            foreach (char c in host)
            {
                if (!(char.IsAsciiLetterOrDigit(c) || c == '.' || c == '-' || c == '_')) return null;
            }
        }
        if (host.Length == 0) return null;

        int port;
        if (string.IsNullOrEmpty(portText))
        {
            port = bare ? DefaultPort : (scheme == "wss" ? 443 : 80);
        }
        else
        {
            if (portText.Length > 5 || !portText.All(char.IsAsciiDigit)) return null;
            port = int.Parse(portText, System.Globalization.CultureInfo.InvariantCulture);
        }
        if (port < 1 || port > 65535) return null;
        host = host.ToLowerInvariant();
        return (host.Contains(':') ? "[" + host + "]" : host) + ":" + port.ToString(System.Globalization.CultureInfo.InvariantCulture);
    }

    /// <summary>The address of a URL a host reported in HOST_INFO, under the
    /// spec's limits: ws/wss only, at most 256 bytes, no user info, no query, no
    /// fragment. null for anything else.</summary>
    public static string? HintAddress(string url)
    {
        if (Encoding.UTF8.GetByteCount(url) > MaxHintBytes) return null;
        if (url != url.Trim()) return null;
        int sep = url.IndexOf("://", StringComparison.Ordinal);
        if (sep < 0) return null;
        var scheme = url.Substring(0, sep).ToLowerInvariant();
        if (!IsSchemeOk(scheme)) return null;
        var rest = url.Substring(sep + 3);
        if (rest.Contains('?') || rest.Contains('#')) return null;
        int slash = rest.IndexOf('/');
        var authority = slash < 0 ? rest : rest.Substring(0, slash);
        if (authority.Contains('@')) return null;
        return NormalizeAddress(url);
    }

    // MARK: Questions

    public KnownHost? Host(string id) => _hosts.FirstOrDefault(h => h.Id == id);

    public AddressStanding Standing(string address)
    {
        var a = NormalizeAddress(address);
        if (a is null) return AddressStanding.Unknown;
        var h = _hosts.FirstOrDefault(x => x.Addresses.Any(k => k.Address == a));
        if (h is not null) return AddressStanding.OfHost(h.Id);
        return _allowed.Contains(a) ? AddressStanding.UnknownAllowed : AddressStanding.Unknown;
    }

    /// <summary>True when a verified handshake at this address ended with this host's key.</summary>
    public bool IsVerified(string address, string hostId)
    {
        var a = NormalizeAddress(address);
        var h = Host(hostId);
        if (a is null || h is null) return false;
        return h.Addresses.Any(k => k.Address == a && k.Verified);
    }

    /// <summary>The addresses to try for a host: the last successful first,
    /// then the verified ones by recency, then the hints by recency.</summary>
    public List<string> DialOrder(string hostId)
    {
        var h = Host(hostId);
        if (h is null) return new List<string>();
        return h.Addresses
            .Select((a, i) => (a, i))
            .OrderByDescending(x => x.a.LastSuccess ?? double.NegativeInfinity)
            .ThenByDescending(x => x.a.Verified)
            .ThenByDescending(x => x.a.LastUsed)
            .ThenBy(x => x.i)
            .Select(x => x.a.Address)
            .ToList();
    }

    // MARK: Changes

    /// <summary>Remembers a host whose key was verified at an address: adds it
    /// if new, binds the address to it (taking the address from any other host),
    /// and clears the "unverified allowed" mark for that address.</summary>
    public void RecordVerified(byte[] key, string name, string address, double now)
    {
        var a = NormalizeAddress(address);
        if (!DeviceIdentity.IsValidPublicKey(key) || a is null) return;
        var id = DeviceIdentity.Id(key);
        var shown = AuthWire.CleanName(name);
        int i = _hosts.FindIndex(h => h.Id == id);
        if (i >= 0)
        {
            if (shown.Length > 0) _hosts[i].Name = shown;
        }
        else
        {
            _hosts.Add(new KnownHost { Key = (byte[])key.Clone(), Name = shown });
        }
        Bind(a, id, now);
    }

    /// <summary>Binds an address to a host that is already known. Does nothing
    /// for an unknown host.</summary>
    public void Bind(string address, string hostId, double now)
    {
        var a = NormalizeAddress(address);
        int i = _hosts.FindIndex(h => h.Id == hostId);
        if (a is null || i < 0) return;
        for (int j = 0; j < _hosts.Count; j++)
        {
            if (j != i) _hosts[j].Addresses.RemoveAll(k => k.Address == a);
        }
        int k2 = _hosts[i].Addresses.FindIndex(k => k.Address == a);
        if (k2 >= 0)
        {
            var existing = _hosts[i].Addresses[k2];
            existing.Verified = true;
            existing.LastUsed = now;
            existing.LastSuccess = now;
        }
        else
        {
            _hosts[i].Addresses.Add(new KnownAddress { Address = a, Verified = true, LastUsed = now, LastSuccess = now });
        }
        _allowed.RemoveAll(x => x == a);
        Trim(i);
    }

    /// <summary>Adds the addresses a host reported as hints for that host. A URL
    /// that breaks the spec's limits is skipped, and so is an address that
    /// already belongs to another host: a host cannot take over an address.</summary>
    public void AddHints(IEnumerable<string> urls, string hostId, double now)
    {
        int i = _hosts.FindIndex(h => h.Id == hostId);
        if (i < 0) return;
        foreach (var url in urls)
        {
            var a = HintAddress(url);
            if (a is null) continue;
            bool otherHost = false;
            for (int j = 0; j < _hosts.Count; j++)
            {
                if (j != i && _hosts[j].Addresses.Any(k => k.Address == a)) otherHost = true;
            }
            if (otherHost) continue;
            if (_hosts[i].Addresses.Any(k => k.Address == a)) continue;
            _hosts[i].Addresses.Add(new KnownAddress { Address = a, Verified = false, LastUsed = now, LastSuccess = null });
            _allowed.RemoveAll(x => x == a);
            Trim(i);
        }
    }

    /// <summary>Notes that an address of a host was dialled (not that it worked).</summary>
    public void MarkDialled(string address, double now)
    {
        var a = NormalizeAddress(address);
        if (a is null) return;
        foreach (var h in _hosts)
        {
            foreach (var k in h.Addresses)
            {
                if (k.Address == a) k.LastUsed = now;
            }
        }
    }

    /// <summary>The user let an unverified connection go to this address.
    /// Ignored for an address that belongs to a host.</summary>
    public void AllowUnverified(string address)
    {
        var a = NormalizeAddress(address);
        if (a is null) return;
        if (Standing(a).Kind == StandingKind.Host) return;
        if (_allowed.Contains(a)) return;
        _allowed.Add(a);
        if (_allowed.Count > MaxAllowedAddresses) _allowed.RemoveRange(0, _allowed.Count - MaxAllowedAddresses);
    }

    /// <summary>Removes a host's key and every address bound to it.</summary>
    public void Forget(string hostId) => _hosts.RemoveAll(h => h.Id == hostId);

    /// <summary>Keeps at most 16 addresses per host: the one unused longest goes
    /// first, and a hint goes before any verified address.</summary>
    private void Trim(int hostIndex)
    {
        var list = _hosts[hostIndex].Addresses;
        while (list.Count > MaxAddressesPerHost)
        {
            var pool = Enumerable.Range(0, list.Count).Where(x => !list[x].Verified).ToList();
            var candidates = pool.Count == 0 ? Enumerable.Range(0, list.Count).ToList() : pool;
            int drop = candidates[0];
            foreach (var c in candidates)
            {
                if (list[c].LastUsed < list[drop].LastUsed) drop = c;
            }
            list.RemoveAt(drop);
        }
    }

    // MARK: Storing

    /// <summary>The JSON that is saved: version 1, public keys, names and
    /// addresses only. Keys are written in a fixed order, so equal stores give
    /// equal bytes.</summary>
    public byte[] Encoded()
    {
        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms))
        {
            w.WriteStartObject();
            w.WriteStartArray("hosts");
            foreach (var h in _hosts)
            {
                w.WriteStartObject();
                w.WriteStartArray("addresses");
                foreach (var a in h.Addresses)
                {
                    w.WriteStartObject();
                    w.WriteString("address", a.Address);
                    if (a.LastSuccess is double ls) w.WriteNumber("lastSuccess", ls);
                    w.WriteNumber("lastUsed", a.LastUsed);
                    w.WriteBoolean("verified", a.Verified);
                    w.WriteEndObject();
                }
                w.WriteEndArray();
                w.WriteString("key", Convert.ToBase64String(h.Key));
                w.WriteString("name", h.Name);
                w.WriteEndObject();
            }
            w.WriteEndArray();
            w.WriteStartArray("unverifiedAllowed");
            foreach (var a in _allowed) w.WriteStringValue(a);
            w.WriteEndArray();
            w.WriteNumber("version", StoreVersion);
            w.WriteEndObject();
        }
        return ms.ToArray();
    }

    private static KnownHost? ReadHost(JsonElement e)
    {
        if (e.ValueKind != JsonValueKind.Object) return null;
        if (!e.TryGetProperty("key", out var k) || k.ValueKind != JsonValueKind.String) return null;
        if (!e.TryGetProperty("name", out var n) || n.ValueKind != JsonValueKind.String) return null;
        if (!e.TryGetProperty("addresses", out var list) || list.ValueKind != JsonValueKind.Array) return null;
        byte[] key;
        try { key = Convert.FromBase64String(k.GetString() ?? ""); }
        catch (FormatException) { return null; }
        var host = new KnownHost { Key = key, Name = n.GetString() ?? "" };
        foreach (var item in list.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object) return null;
            if (!item.TryGetProperty("address", out var ad) || ad.ValueKind != JsonValueKind.String) return null;
            if (!item.TryGetProperty("verified", out var ve)
                || (ve.ValueKind != JsonValueKind.True && ve.ValueKind != JsonValueKind.False)) return null;
            if (!item.TryGetProperty("lastUsed", out var lu) || lu.ValueKind != JsonValueKind.Number
                || !lu.TryGetDouble(out var lastUsed)) return null;
            double? lastSuccess = null;
            if (item.TryGetProperty("lastSuccess", out var ls) && ls.ValueKind != JsonValueKind.Null)
            {
                if (ls.ValueKind != JsonValueKind.Number || !ls.TryGetDouble(out var v)) return null;
                lastSuccess = v;
            }
            host.Addresses.Add(new KnownAddress
            {
                Address = ad.GetString() ?? "",
                Verified = ve.GetBoolean(),
                LastUsed = lastUsed,
                LastSuccess = lastSuccess,
            });
        }
        return host;
    }

    /// <summary>Reads a stored copy. null means nothing was stored yet. A copy
    /// that cannot be read gives an empty store and Damaged set; one with some
    /// unreadable entries keeps every entry that could be read and sets Damaged
    /// too. A version other than 1 also counts as damaged. Callers that save
    /// must treat Damaged as an error and leave the file alone
    /// (<see cref="KnownHostsFile"/> does).</summary>
    public static (KnownHosts Hosts, bool Damaged) Decode(byte[]? data)
    {
        if (data is null) return (new KnownHosts(), false);
        JsonDocument doc;
        try { doc = JsonDocument.Parse(data); }
        catch (JsonException) { return (new KnownHosts(), true); }
        using (doc)
        {
            var root = doc.RootElement;
            var output = new KnownHosts();
            if (root.ValueKind != JsonValueKind.Object) return (output, true);
            bool damaged = false;
            if (!root.TryGetProperty("version", out var ver) || ver.ValueKind != JsonValueKind.Number
                || !ver.TryGetInt32(out var versionNumber) || versionNumber != StoreVersion)
            {
                damaged = true;
            }
            if (!root.TryGetProperty("hosts", out var rawHosts) || rawHosts.ValueKind != JsonValueKind.Array)
            {
                return (output, true);
            }
            var claimed = new HashSet<string>();
            foreach (var entry in rawHosts.EnumerateArray())
            {
                var host = ReadHost(entry);
                if (host is null || !DeviceIdentity.IsValidPublicKey(host.Key)) { damaged = true; continue; }
                var addresses = new List<KnownAddress>();
                foreach (var a in host.Addresses)
                {
                    var n = NormalizeAddress(a.Address);
                    if (n is null || n != a.Address || claimed.Contains(n) || addresses.Any(x => x.Address == n))
                    {
                        damaged = true;
                        continue;
                    }
                    addresses.Add(a);
                }
                int i = output._hosts.FindIndex(x => x.Id == host.Id);
                if (i >= 0)
                {
                    // The same key twice: one entry, with the addresses of both.
                    damaged = true;
                    output._hosts[i].Addresses.AddRange(addresses);
                }
                else
                {
                    output._hosts.Add(new KnownHost { Key = host.Key, Name = AuthWire.CleanName(host.Name), Addresses = addresses });
                }
                foreach (var a in addresses) claimed.Add(a.Address);
            }
            for (int i = 0; i < output._hosts.Count; i++) output.Trim(i);
            int allowedCount = 0;
            if (root.TryGetProperty("unverifiedAllowed", out var rawAllowed) && rawAllowed.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in rawAllowed.EnumerateArray())
                {
                    allowedCount++;
                    var text = item.ValueKind == JsonValueKind.String ? item.GetString() : null;
                    var n = text is null ? null : NormalizeAddress(text);
                    if (text is null || n is null || n != text) { damaged = true; continue; }
                    if (!claimed.Contains(n) && !output._allowed.Contains(n)) output._allowed.Add(n);
                }
            }
            else if (root.TryGetProperty("unverifiedAllowed", out _))
            {
                damaged = true;
            }
            if (allowedCount > MaxAllowedAddresses && output._allowed.Count > MaxAllowedAddresses)
            {
                output._allowed.RemoveRange(0, output._allowed.Count - MaxAllowedAddresses);
            }
            return (output, damaged);
        }
    }
}

public enum ChangeKind { RecordVerified, Bind, Hints, AllowUnverified, Forget }

/// <summary>One change to the store. The connection flow reports these
/// instead of a whole store, so two connections that run side by side cannot
/// overwrite each other's changes: the caller applies each one to the one
/// shared store (KnownHostsFile.Apply).</summary>
public sealed class KnownHostsChange
{
    public ChangeKind Kind { get; }
    public byte[] Key { get; } = Array.Empty<byte>();
    public string Name { get; } = "";
    public string Address { get; } = "";
    public string HostId { get; } = "";
    public IReadOnlyList<string> Urls { get; } = Array.Empty<string>();

    private KnownHostsChange(ChangeKind kind, byte[]? key = null, string? name = null, string? address = null,
        string? hostId = null, IReadOnlyList<string>? urls = null)
    {
        Kind = kind;
        Key = key ?? Array.Empty<byte>();
        Name = name ?? "";
        Address = address ?? "";
        HostId = hostId ?? "";
        Urls = urls ?? Array.Empty<string>();
    }

    public static KnownHostsChange RecordVerified(byte[] key, string name, string address) =>
        new(ChangeKind.RecordVerified, key: key, name: name, address: address);
    public static KnownHostsChange Bind(string hostId, string address) =>
        new(ChangeKind.Bind, hostId: hostId, address: address);
    public static KnownHostsChange Hints(string hostId, IReadOnlyList<string> urls) =>
        new(ChangeKind.Hints, hostId: hostId, urls: urls);
    public static KnownHostsChange AllowUnverified(string address) =>
        new(ChangeKind.AllowUnverified, address: address);
    public static KnownHostsChange Forget(string hostId) =>
        new(ChangeKind.Forget, hostId: hostId);

    public void Apply(KnownHosts hosts, double now)
    {
        switch (Kind)
        {
            case ChangeKind.RecordVerified: hosts.RecordVerified(Key, Name, Address, now); break;
            case ChangeKind.Bind: hosts.Bind(Address, HostId, now); break;
            case ChangeKind.Hints: hosts.AddHints(Urls, HostId, now); break;
            case ChangeKind.AllowUnverified: hosts.AllowUnverified(Address); break;
            case ChangeKind.Forget: hosts.Forget(HostId); break;
        }
    }

    public override string ToString() => $"{Kind} {HostId} {Address}";
}
