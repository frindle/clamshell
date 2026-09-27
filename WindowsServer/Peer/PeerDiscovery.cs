using System.Net;
using System.Net.Sockets;
using Makaretu.Dns;
using Message = Makaretu.Dns.Message;

namespace Clamshell;

// mDNS/DNS-SD for the peer link — the Windows side of the Mac's Bonjour
// advertise + browse (PeerLink.swift startListening / startBrowsing):
// service type _clamshell-peer._tcp, TXT id=<peer id> name=<name> v=2.
// Browsing collects PTR → SRV/TXT → A/AAAA records (asking for whatever a
// responder didn't volunteer) and reports every other Clamshell it can
// resolve to an address. Events fire on network threads.
internal sealed class PeerDiscovery : IDisposable
{
    internal sealed record Found(string Name, string? Id, string Host, ushort Port);

    private sealed class Entry
    {
        public DomainName Instance = null!;
        public DomainName? Target;
        public ushort Port;
        public string? Id, Name;
        public DateTime Seen = DateTime.UtcNow;
    }

    private static readonly DomainName ServiceFqdn = new(PeerLimits.ServiceType + ".local");
    private readonly object _gate = new();
    private readonly Dictionary<string, Entry> _entries = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, List<IPAddress>> _addresses = new(StringComparer.OrdinalIgnoreCase);
    private MulticastService? _mdns;
    private ServiceDiscovery? _sd;
    private ServiceProfile? _profile;
    private System.Threading.Timer? _requery;
    private string _ownId = "";
    private IReadOnlyList<Found> _last = Array.Empty<Found>();

    public event Action<IReadOnlyList<Found>>? OnChange;
    public IReadOnlyList<Found> Current { get { lock (_gate) return _last; } }

    public void Start(string localName, string ownId, ushort port, bool advertise = true)
    {
        _ownId = ownId;
        _mdns = new MulticastService();
        _sd = new ServiceDiscovery(_mdns);
        _mdns.AnswerReceived += (_, e) => OnAnswer(e.Message);
        _mdns.Start();
        if (advertise)
        {
            _profile = new ServiceProfile(new DomainName(SafeLabel(localName)), new DomainName(PeerLimits.ServiceType), port);
            _profile.AddProperty("id", ownId);
            _profile.AddProperty("name", localName);
            _profile.AddProperty("v", PeerLimits.ProtocolVersion.ToString());
            _sd.Advertise(_profile);
            try { _sd.Announce(_profile); } catch (Exception e) { Log.Line($"PEER: mDNS announce failed: {e.Message}"); }
        }
        // Browse now and every 15 s (answers carry TTLs; stale entries age out).
        _requery = new System.Threading.Timer(_ => Query(), null, TimeSpan.Zero, TimeSpan.FromSeconds(15));
        Log.Line($"PEER: mDNS {(advertise ? "advertising and " : "")}browsing {PeerLimits.ServiceType}");
    }

    private static string SafeLabel(string s)
    {
        // A DNS label is ≤ 63 bytes; dots would split it into two labels.
        string t = s.Replace('.', '-');
        while (System.Text.Encoding.UTF8.GetByteCount(t) > 63) t = t[..^1];
        return t.Length == 0 ? "Clamshell" : t;
    }

    private void Query()
    {
        try { _sd?.QueryServiceInstances(new DomainName(PeerLimits.ServiceType)); }
        catch (Exception e) { Log.Line($"PEER: mDNS query failed: {e.Message}"); }
        lock (_gate)
        {
            var cutoff = DateTime.UtcNow.AddSeconds(-75);
            foreach (var k in _entries.Where(kv => kv.Value.Seen < cutoff).Select(kv => kv.Key).ToList()) _entries.Remove(k);
        }
        Publish();
    }

    private void OnAnswer(Message m)
    {
        var ask = new List<(DomainName, DnsType)>();
        lock (_gate)
        {
            foreach (var rr in m.Answers.Concat(m.AdditionalRecords))
            {
                switch (rr)
                {
                    case PTRRecord ptr when ptr.Name == ServiceFqdn:
                    {
                        string key = ptr.DomainName.ToString();
                        if (ptr.TTL == TimeSpan.Zero) { _entries.Remove(key); break; } // goodbye
                        if (!_entries.TryGetValue(key, out var e)) _entries[key] = e = new Entry { Instance = ptr.DomainName };
                        e.Seen = DateTime.UtcNow;
                        break;
                    }
                    case SRVRecord srv:
                    {
                        if (!_entries.TryGetValue(srv.Name.ToString(), out var e)) break;
                        e.Target = srv.Target; e.Port = srv.Port; e.Seen = DateTime.UtcNow;
                        break;
                    }
                    case TXTRecord txt:
                    {
                        if (!_entries.TryGetValue(txt.Name.ToString(), out var e)) break;
                        foreach (var s in txt.Strings)
                        {
                            int eq = s.IndexOf('=');
                            if (eq <= 0) continue;
                            string k = s[..eq], v = s[(eq + 1)..];
                            if (k == "id") e.Id = v; else if (k == "name") e.Name = v;
                        }
                        break;
                    }
                    case AddressRecord a:
                    {
                        string host = a.Name.ToString();
                        if (!_addresses.TryGetValue(host, out var list)) _addresses[host] = list = new();
                        if (!list.Contains(a.Address)) list.Add(a.Address);
                        break;
                    }
                }
            }
            foreach (var e in _entries.Values)
            {
                if (e.Target is null) { ask.Add((e.Instance, DnsType.SRV)); ask.Add((e.Instance, DnsType.TXT)); }
                else if (!_addresses.ContainsKey(e.Target.ToString())) { ask.Add((e.Target, DnsType.A)); ask.Add((e.Target, DnsType.AAAA)); }
            }
        }
        foreach (var (name, type) in ask.Distinct())
        {
            try { _mdns?.SendQuery(name, type: type); } catch { }
        }
        Publish();
    }

    private void Publish()
    {
        List<Found> now;
        lock (_gate)
        {
            now = new();
            foreach (var e in _entries.Values)
            {
                if (e.Target is null || e.Port == 0 || e.Id is null || e.Id == _ownId) continue; // every Clamshell advertises an id; wait for its TXT
                if (!_addresses.TryGetValue(e.Target.ToString(), out var addrs) || addrs.Count == 0) continue;
                // Prefer IPv4, then a global IPv6; skip link-local v6 (needs a scope id).
                var ip = addrs.FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork)
                         ?? addrs.FirstOrDefault(a => !a.IsIPv6LinkLocal);
                if (ip is null) continue;
                string name = e.Name ?? e.Instance.Labels.FirstOrDefault() ?? "peer";
                now.Add(new Found(name, e.Id, ip.ToString(), e.Port));
            }
            now.Sort((a, b) => string.CompareOrdinal(a.Name, b.Name));
            if (now.SequenceEqual(_last)) return;
            _last = now;
        }
        OnChange?.Invoke(now);
    }

    public void Dispose()
    {
        _requery?.Dispose(); _requery = null;
        try { if (_profile is not null) _sd?.Unadvertise(_profile); } catch { }
        try { _sd?.Dispose(); } catch { }
        try { _mdns?.Stop(); } catch { }
        _sd = null; _mdns = null;
    }
}
