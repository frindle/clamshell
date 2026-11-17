using System.IO;
using System.Text;

namespace Clamshell.Auth;

/// <summary>Checks of the saved-Macs store, its file and the connection flow
/// (the client rules R1 to R16 in PROTOCOL.md), with a fake host built from the
/// same handshake library. No sockets, no clock, no real key store.</summary>
public static class FlowTests
{
    private const string Url = "ws://mac.local:5903";

    public static void Run(TestRun t)
    {
        t.Group("known hosts store", () => StoreTests(t));
        t.Group("known hosts: fallback addresses", () => FallbackTests(t));
        t.Group("known hosts file", () => FileTests(t));
        t.Group("flow: opening and challenge", () => OpeningTests(t));
        t.Group("flow: results", () => ResultTests(t));
        t.Group("flow: unverified and changed hosts", () => TrustTests(t));
        t.Group("flow: retries", () => RetryTests(t));
        t.Group("flow: secure session", () => SessionTests(t));
        t.Group("flow: host info and client info", () => InfoTests(t));
    }

    // MARK: A fake host and a flow

    private sealed class Rig : IDisposable
    {
        public TestKey HostKey = TestKey.Random();
        public TestKey DeviceKey = TestKey.Random();
        public HostHandshake Host;
        public ClientAuthFlow Flow;
        public ClientAuthConfig Config;
        public byte[]? Response;
        public SecureSealer? HostSealer;
        public SecureOpener? HostOpener;
        public int Hellos;

        public Rig(KnownHosts? known = null, string url = Url, string deviceName = "My PC", uint caps = 0,
            TestKey? hostKey = null, uint hostCaps = Caps.DeviceApproval, FlowCarry? carry = null)
        {
            if (hostKey is not null) HostKey = hostKey;
            Host = new HostHandshake(HostKey.Public, hostCaps, "Test Mac");
            Config = new ClientAuthConfig
            {
                DeviceKey = DeviceKey.Public,
                Sign = DeviceKey.Signer,
                DeviceName = deviceName,
                Capabilities = caps,
                AppVersion = "1.2.3",
                DialledUrl = url,
            };
            Config.MakeHello = () => { Hellos++; return Wire.Frame(WireType.Hello, new byte[] { 1, 2, 3 }); };
            Flow = new ClientAuthFlow(Config, known ?? new KnownHosts(), carry);
        }

        public void Dispose() { HostKey.Dispose(); DeviceKey.Dispose(); }

        public List<FlowAction> Challenge() => Take(Flow.Received(WireType.AuthChallenge, Host.Challenge.Payload));

        public List<FlowAction> Result(AuthStatus s)
        {
            var response = Response ?? throw new InvalidOperationException("no response yet");
            return Take(Flow.Received(WireType.AuthResult, Host.Result(s, response, HostKey.Signer)));
        }

        public List<FlowAction> Take(List<FlowAction> actions)
        {
            foreach (var a in actions)
            {
                if (a.Kind == FlowActionKind.Send && a.Bytes.Length > 5 && a.Bytes[0] == WireType.AuthResponse)
                {
                    Response = Wire.Slice(a.Bytes, 5, a.Bytes.Length - 5);
                }
            }
            return actions;
        }

        /// <summary>Open, challenge, pending, accepted: the new-device path.</summary>
        public List<FlowAction> Accepted(bool viaPending = true)
        {
            Flow.Opened();
            Challenge();
            if (viaPending) Result(AuthStatus.Pending);
            var actions = Result(AuthStatus.Accepted);
            var device = Host.Verify(Response!);
            var keys = Host.DeriveSessionKeys(device);
            HostSealer = new SecureSealer(keys.HostToClient);
            HostOpener = new SecureOpener(keys.ClientToHost);
            return actions;
        }

        /// <summary>What the client sealed in these actions, opened with the host's keys.</summary>
        public List<(byte Type, byte[] Payload)> Opened(List<FlowAction> actions)
        {
            var output = new List<(byte, byte[])>();
            foreach (var a in actions.Where(x => x.Kind == FlowActionKind.Send))
            {
                output.Add(HostOpener!.Open(Wire.Slice(a.Bytes, 5, a.Bytes.Length - 5)));
            }
            return output;
        }

        public byte[] Sealed(byte type, byte[] payload) => HostSealer!.Seal(Wire.Frame(type, payload));
    }

    private static KnownHosts KnowHost(TestKey hostKey, string address = Url)
    {
        var k = new KnownHosts();
        k.RecordVerified(hostKey.Public, "Test Mac", address, 1000);
        return k;
    }

    private static bool Has(List<FlowAction> a, FlowActionKind k) => a.Any(x => x.Kind == k);
    private static FlowState? Shown(List<FlowAction> a) => a.LastOrDefault(x => x.Kind == FlowActionKind.State)?.State;
    private static FlowEnd? Ended(List<FlowAction> a) => a.FirstOrDefault(x => x.Kind == FlowActionKind.End)?.End;
    private static int Sends(List<FlowAction> a) => a.Count(x => x.Kind == FlowActionKind.Send);
    private static bool IsFailure(List<FlowAction> a) => Ended(a)?.Kind == FlowEndKind.Failure;
    private static FlowAction? Timer(List<FlowAction> a, FlowTimer which) =>
        a.FirstOrDefault(x => x.Kind == FlowActionKind.StartTimer && x.Timer == which);
    private static byte[] Json(string text) => Encoding.UTF8.GetBytes(text);

    // MARK: Store

    private static void StoreTests(TestRun t)
    {
        t.Equal(KnownHosts.NormalizeAddress("Mac.Local"), "mac.local:5903", "a bare host gets the default port");
        t.Equal(KnownHosts.NormalizeAddress("ws://Mac.Local:5903/path?x=1#y"), "mac.local:5903", "path, query and fragment are dropped");
        t.Equal(KnownHosts.NormalizeAddress("wss://u:p@mac.local:443/"), "mac.local:443", "user info is dropped");
        t.Check(KnownHosts.NormalizeAddress("http://mac.local") is null, "another scheme is refused");
        t.Check(KnownHosts.NormalizeAddress("") is null, "an empty address is refused");
        t.Check(KnownHosts.NormalizeAddress("ws://mac.local:99999") is null, "a port out of range is refused");

        using var a = TestKey.Random();
        using var b = TestKey.Random();
        var k = new KnownHosts();
        k.RecordVerified(a.Public, "Mac A", "mac-a.local", 1);
        t.Equal(k.Hosts.Count, 1, "one host recorded");
        t.Equal(k.Standing("ws://mac-a.local:5903").HostId, DeviceIdentity.Id(a.Public), "its address belongs to it");
        t.Check(k.IsVerified("mac-a.local", DeviceIdentity.Id(a.Public)), "the address is verified");
        t.Equal(k.Standing("ws://other.local:5903").Kind, StandingKind.Unknown, "another address is unknown");

        k.RecordVerified(b.Public, "Mac B", "mac-a.local", 2);
        t.Equal(k.Standing("mac-a.local").HostId, DeviceIdentity.Id(b.Public), "an address moves to the host that proved it");
        t.Equal(k.Host(DeviceIdentity.Id(a.Public))!.Addresses.Count, 0, "the first host lost it");

        k.AllowUnverified("lan.local");
        t.Equal(k.Standing("lan.local").Kind, StandingKind.UnknownAllowed, "allow-unverified is remembered");
        k.RecordVerified(a.Public, "Mac A", "lan.local", 3);
        t.Equal(k.Standing("lan.local").Kind, StandingKind.Host, "a verified host replaces the allowance");
        t.Equal(k.UnverifiedAllowed.Count, 0, "the allowance is gone");
        k.AllowUnverified("mac-a.local");
        t.Equal(k.Standing("mac-a.local").Kind, StandingKind.Host, "an address with a host cannot be allowed unverified");

        for (int i = 0; i < 70; i++) k.AllowUnverified($"h{i}.local");
        t.Equal(k.UnverifiedAllowed.Count, KnownHosts.MaxAllowedAddresses, "allowed addresses are capped");

        var h = new KnownHosts();
        h.RecordVerified(a.Public, "Mac A", "a.local", 1);
        var id = DeviceIdentity.Id(a.Public);
        h.AddHints(new[] { "ws://hint1.local:5903", "ws://a.local:5903", "http://nope", new string('x', 300) }, id, 5);
        t.Equal(h.Host(id)!.Addresses.Count, 2, "hints add new valid addresses only");
        t.Check(!h.IsVerified("hint1.local", id), "a hint is not verified");
        t.Equal(h.DialOrder(id)[0], "a.local:5903", "the verified address is dialled first");
        h.RecordVerified(b.Public, "Mac B", "b.local", 6);
        h.AddHints(new[] { "ws://b.local:5903" }, id, 7);
        t.Equal(h.Standing("b.local").HostId, DeviceIdentity.Id(b.Public), "a hint cannot take an address from another host");
        for (int i = 0; i < 30; i++) h.AddHints(new[] { $"ws://x{i}.local:5903" }, id, 10 + i);
        t.Check(h.Host(id)!.Addresses.Count <= KnownHosts.MaxAddressesPerHost, "addresses per host are capped");
        t.Check(h.Host(id)!.Addresses.Any(x => x.Verified), "trimming keeps the verified address before hints");

        var copy = h.Clone();
        copy.Forget(id);
        t.Check(h.Host(id) is not null && copy.Host(id) is null, "forget affects the copy only");

        var (round, damaged) = KnownHosts.Decode(h.Encoded());
        t.Check(!damaged, "own output decodes");
        t.Same(round.Encoded(), h.Encoded(), "encode, decode, encode is stable");
        t.Check(KnownHosts.Decode(null).Damaged == false, "no data is an empty store");
        t.Check(KnownHosts.Decode(Json("{not json")).Damaged, "bad JSON is damaged");
        t.Check(KnownHosts.Decode(Json("{\"version\":2,\"hosts\":[],\"unverifiedAllowed\":[]}")).Damaged, "another version is damaged");
        t.Check(KnownHosts.Decode(Json("[]")).Damaged, "a non-object is damaged");
        var broken = Encoding.UTF8.GetString(h.Encoded()).Replace("\"key\":\"", "\"key\":\"AAAA");
        t.Check(KnownHosts.Decode(Json(broken)).Damaged, "an entry with a bad key is damaged");
    }

    // MARK: Fallback addresses

    private static string Joined(IEnumerable<string> urls) => string.Join(" ", urls.OrderBy(x => x, StringComparer.Ordinal));

    private static void FallbackTests(TestRun t)
    {
        using var key = TestKey.Random();
        var id = DeviceIdentity.Id(key.Public);
        var k = new KnownHosts();
        k.RecordVerified(key.Public, "Example Mac", "ws://192.0.2.10:5903", 1);
        k.RecordVerified(key.Public, "Example Mac", "ws://192.0.2.10:5904", 2);
        k.RecordVerified(key.Public, "Example Mac", "ws://198.51.100.7:5903", 3);
        k.RecordVerified(key.Public, "Example Mac", "wss://mac.example.com/ws/a", 4);

        t.Equal(k.Host(id)!.Addresses.First(a => a.Address == "mac.example.com:443").Path, "/ws/a", "the tunnel path is kept");
        t.Check(k.Host(id)!.Addresses.First(a => a.Address == "192.0.2.10:5903").Path is null, "a direct address has no path");
        var (back, damaged) = KnownHosts.Decode(k.Encoded());
        t.Check(!damaged, "a copy with paths decodes");
        t.Same(back.Encoded(), k.Encoded(), "the path survives a save and a load");

        t.Equal(Joined(k.FallbackUrls(id, "ws://192.0.2.10:5903")),
            "ws://198.51.100.7:5903 wss://mac.example.com/ws/a", "display A: same port, tunnel on /ws/a, never port 5904");
        t.Equal(Joined(k.FallbackUrls(id, "ws://192.0.2.10:5904")),
            "wss://mac.example.com/ws/b", "display B: the tunnel is dialled with /ws/b");
        t.Equal(Joined(k.FallbackUrls(id, "wss://mac.example.com/ws/b")),
            "ws://192.0.2.10:5904", "from a tunnel for B: only the B port");
        t.Equal(Joined(k.FallbackUrls(id, "wss://mac.example.com/ws/a")),
            "ws://192.0.2.10:5903 ws://198.51.100.7:5903", "from a tunnel for A: only the A port");

        // A copy saved before paths were kept: still loads, gives no tunnel fallback until the next connection.
        var old = new KnownHosts();
        old.RecordVerified(key.Public, "Example Mac", "192.0.2.10", 1);
        old.RecordVerified(key.Public, "Example Mac", "wss://mac.example.com", 2);
        var oldJson = Encoding.UTF8.GetString(old.Encoded());
        t.Check(!oldJson.Contains("\"path\""), "no path is written when there is none");
        var (loaded, oldDamaged) = KnownHosts.Decode(Json(oldJson));
        t.Check(!oldDamaged, "an old copy still loads");
        t.Equal(Joined(loaded.FallbackUrls(id, "ws://192.0.2.10:5903")), "", "no tunnel fallback without a saved path");
        loaded.Bind("wss://mac.example.com/ws/a", id, 9);
        t.Equal(Joined(loaded.FallbackUrls(id, "ws://192.0.2.10:5903")), "wss://mac.example.com/ws/a", "the next connection saves the path");

        // A hint fills in a missing path and never moves an address.
        var other = TestKey.Random();
        var h = new KnownHosts();
        h.RecordVerified(key.Public, "Example Mac", "192.0.2.10", 1);
        h.RecordVerified(other.Public, "Other Mac", "198.51.100.9", 1);
        h.AddHints(new[] { "wss://mac.example.com/ws/a", "ws://198.51.100.9:5903" }, id, 2);
        t.Equal(h.Host(id)!.Addresses.First(a => a.Address == "mac.example.com:443").Path, "/ws/a", "a hint carries its path");
        t.Equal(h.Standing("198.51.100.9:5903").HostId, DeviceIdentity.Id(other.Public), "a hint cannot take an address");
        other.Dispose();

        t.Equal(KnownHosts.DisplayPath("wss://mac.example.com/tunnel/ws/b"), "/tunnel/ws/b", "a prefix is allowed");
        t.Check(KnownHosts.DisplayPath("wss://mac.example.com") is null, "no path, no display path");
        t.Check(KnownHosts.DisplayPath("wss://mac.example.com/ws/ab") is null, "one letter only");
        t.Check(KnownHosts.DisplayPath("ws://192.0.2.10:5903/ws/a") is null, "only a tunnel keeps a path");
        t.Equal(KnownHosts.DisplayIndex("ws://192.0.2.10:5905"), (int?)2, "port 5905 is display C");
        t.Check(KnownHosts.DisplayIndex("ws://192.0.2.10:8443") is null, "a custom port names no display");
    }

    // MARK: File

    private static void FileTests(TestRun t)
    {
        var dir = Path.Combine(Path.GetTempPath(), "clamshell-kh-" + Guid.NewGuid().ToString("N"));
        try
        {
            using var key = TestKey.Random();
            var file = new KnownHostsFile(dir);
            t.Equal(file.Load().Hosts.Count, 0, "a missing file is an empty store");
            var change = KnownHostsChange.RecordVerified(key.Public, "Mac", "ws://mac.local:5903");
            file.Apply(change, 10);
            t.Check(File.Exists(file.FilePath), "the file is written");
            t.Equal(new KnownHostsFile(dir).Load().Hosts.Count, 1, "a second reader sees it");
            t.Equal(Directory.GetFiles(dir, "*.tmp").Length, 0, "no temporary file is left");

            // Another writer's change survives: every change reads the file first.
            using var key2 = TestKey.Random();
            new KnownHostsFile(dir).Apply(KnownHostsChange.RecordVerified(key2.Public, "Mac 2", "two.local"), 11);
            file.Apply(KnownHostsChange.AllowUnverified("lan.local"), 12);
            var now = file.Load();
            t.Check(now.Hosts.Count == 2 && now.UnverifiedAllowed.Count == 1, "changes from two writers both stay");
            file.Apply(KnownHostsChange.Forget(DeviceIdentity.Id(key.Public)), 13);
            t.Equal(file.Load().Hosts.Count, 1, "forget removes the host");

            var junk = Json("{ this is not the store");
            File.WriteAllBytes(file.FilePath, junk);
            Throws<KnownHostsFileException>(t, () => file.Load(), "a damaged file refuses to load");
            Throws<KnownHostsFileException>(t, () => file.Apply(KnownHostsChange.AllowUnverified("a.local"), 1), "a damaged file refuses a change");
            t.Same(File.ReadAllBytes(file.FilePath), junk, "a damaged file is left as it was");

            File.Delete(file.FilePath);
            Directory.CreateDirectory(file.FilePath);
            Throws<KnownHostsFileException>(t, () => file.Load(), "a folder at the path refuses to load");
            Throws<KnownHostsFileException>(t, () => file.Apply(KnownHostsChange.AllowUnverified("a.local"), 1), "a folder at the path refuses a change");
            t.Check(Directory.Exists(file.FilePath), "the folder is left alone");
        }
        finally
        {
            try { Directory.Delete(dir, true); } catch (Exception) { /* temp folder */ }
        }
    }

    private static void Throws<T>(TestRun t, Action action, string name) where T : Exception
    {
        try { action(); t.Check(false, name); }
        catch (T) { t.Check(true, name); }
        catch (Exception e) { t.Check(false, name + " (threw " + e.GetType().Name + ")"); }
    }

    // MARK: Opening

    private static void OpeningTests(TestRun t)
    {
        using var r = new Rig();
        var open = r.Flow.Opened();
        t.Equal(Sends(open), 0, "R1: nothing is sent when the socket opens");
        t.Equal(Timer(open, FlowTimer.Challenge)?.Seconds, 2.0, "R2: the challenge is awaited for 2 s");
        t.Equal(Sends(r.Flow.Send(Wire.Frame(WireType.Hello, Array.Empty<byte>()))), 0, "R1: app messages before accepted are dropped");

        var ch = r.Challenge();
        t.Equal(Sends(ch), 1, "the challenge is answered with one message");
        t.Check(r.Response is { Length: > 0 }, "that message is an AUTH_RESPONSE");
        t.Check(Has(ch, FlowActionKind.CancelTimer), "the challenge timer is cancelled");
        t.Equal(Timer(ch, FlowTimer.Result)?.Seconds, 15.0, "the result is awaited for 15 s");
        var device = r.Host.Verify(r.Response!);
        t.Equal(device.Name, "My PC", "the host learns the device name");
        t.Equal(device.Capabilities, 0u, "no capability bits are claimed");
        t.Equal(Sends(r.Flow.Send(Wire.Frame(WireType.Hello, Array.Empty<byte>()))), 0, "app messages are dropped before accepted");

        using var caps = new Rig(caps: Caps.RelativeMouse);
        caps.Flow.Opened(); caps.Challenge();
        t.Equal(caps.Host.Verify(caps.Response!).Capabilities, Caps.RelativeMouse, "configured capability bits reach the host");

        using var empty = new Rig(deviceName: "  \u0001 ");
        empty.Flow.Opened(); empty.Challenge();
        t.Equal(empty.Host.Verify(empty.Response!).Name, "PC", "an empty name falls back to PC");

        using var bad = new Rig();
        bad.Flow.Opened();
        var evil = (byte[])bad.Host.Challenge.Payload.Clone();
        evil[0] = 2;
        t.Check(IsFailure(bad.Flow.Received(WireType.AuthChallenge, evil)), "a challenge of another version fails");
        using var bad3 = new Rig();
        bad3.Flow.Opened();
        t.Check(IsFailure(bad3.Flow.Received(WireType.AuthChallenge, new byte[20])), "a short challenge fails");
        using var bad4 = new Rig();
        bad4.Flow.Opened();
        t.Check(IsFailure(bad4.Flow.Received(WireType.HelloAck, new byte[4])), "a message before the challenge fails");
        using var bad5 = new Rig(url: "ftp://nope");
        t.Check(IsFailure(bad5.Flow.Opened()), "an address that cannot be used fails at once");
    }

    // MARK: Results

    private static void ResultTests(TestRun t)
    {
        using (var r = new Rig())
        {
            r.Flow.Opened(); r.Challenge();
            var pending = r.Result(AuthStatus.Pending);
            var s = Shown(pending);
            t.Equal(s?.Kind, FlowStateKind.WaitingForApproval, "R7: pending shows the waiting screen");
            t.Equal(s?.HostFingerprint, DeviceIdentity.FingerprintOfKey(r.HostKey.Public), "the waiting screen shows the Mac's fingerprint");
            t.Equal(s?.DeviceFingerprint, DeviceIdentity.FingerprintOfKey(r.DeviceKey.Public), "the waiting screen shows this PC's fingerprint");
            t.Equal(Timer(pending, FlowTimer.Pending)?.Seconds, 60.0, "pending is awaited for 60 s");
            var again = r.Result(AuthStatus.Pending);
            t.Equal(Shown(again)?.Kind, FlowStateKind.WaitingForApproval, "a repeated pending stays on the waiting screen");
            var acc = r.Result(AuthStatus.Accepted);
            t.Equal(Shown(acc)?.Kind, FlowStateKind.Connected, "then accepted connects");
            t.Check(Shown(acc)!.Verified, "and the host counts as verified");
            t.Check(acc.Any(a => a.Kind == FlowActionKind.Change && a.Change!.Kind == ChangeKind.RecordVerified), "the host is saved");
            t.Equal(acc.First(a => a.Kind == FlowActionKind.HostCapabilities).Capabilities, Caps.DeviceApproval, "the host's capabilities are published");
        }
        using (var r = new Rig())
        {
            var acc = r.Accepted(viaPending: false);
            t.Equal(Shown(acc)?.Kind, FlowStateKind.ConfirmHost, "R12: accepted at once from an unknown host asks first");
            t.Check(Has(acc, FlowActionKind.Close), "R12: the socket is closed while asking");
            t.Equal(Sends(acc), 0, "R12: nothing is sent while asking");
            t.Check(!acc.Any(a => a.Kind == FlowActionKind.Change), "R12: nothing is saved before the answer");
            var no = r.Flow.Answered(false);
            t.Equal(Ended(no)?.Kind, FlowEndKind.Stop, "R12: no stops");
        }
        using (var r = new Rig())
        {
            r.Accepted(viaPending: false);
            var yes = r.Flow.Answered(true);
            t.Check(yes.Any(a => a.Kind == FlowActionKind.Change && a.Change!.Kind == ChangeKind.RecordVerified), "R12: yes saves the host");
            t.Equal(Ended(yes)?.Kind, FlowEndKind.Reconnect, "R12: yes connects again");
            t.Equal(Ended(yes)?.After, 0.0, "R12: at once");
        }
        using (var r = new Rig())
        {
            r.Flow.Opened(); r.Challenge();
            var bad = r.Flow.Received(WireType.AuthResult, new byte[70]);
            t.Check(IsFailure(bad), "a result with a bad signature fails");
        }
        using (var r = new Rig())
        {
            r.Flow.Opened(); r.Challenge();
            using var other = TestKey.Random();
            var forged = r.Host.Result(AuthStatus.Accepted, r.Response!, other.Signer);
            t.Check(IsFailure(r.Flow.Received(WireType.AuthResult, forged)), "a result signed by another key fails");
        }
        foreach (var (status, kind) in new[] { (AuthStatus.Denied, FlowStateKind.Denied), (AuthStatus.Invalid, FlowStateKind.Invalid) })
        {
            using var r = new Rig();
            r.Flow.Opened(); r.Challenge();
            var a = r.Result(status);
            t.Equal(Shown(a)?.Kind, kind, $"{status} shows its screen");
            t.Equal(Ended(a)?.Kind, FlowEndKind.Stop, $"{status} does not reconnect");
        }
        using (var r = new Rig())
        {
            r.Flow.Opened(); r.Challenge();
            var res = r.Flow.Received(WireType.Hello, new byte[0]);
            t.Check(IsFailure(res), "R3: anything but a result while awaiting one fails");
        }
        using (var r = new Rig())
        {
            r.Flow.Opened(); r.Challenge();
            t.Check(IsFailure(r.Flow.TimerFired(FlowTimer.Result)), "no result in 15 s fails");
        }
        using (var r = new Rig())
        {
            r.Flow.Opened(); r.Challenge(); r.Result(AuthStatus.Pending);
            var end = r.Flow.TimerFired(FlowTimer.Pending);
            t.Equal(Ended(end)?.Kind, FlowEndKind.Reconnect, "no result in 60 s reconnects");
            t.Equal(Ended(end)?.After, 0.0, "at once");
        }
    }

    // MARK: Trust

    private static void TrustTests(TestRun t)
    {
        using (var r = new Rig())
        {
            var known = KnowHost(r.HostKey);
            using var r2 = new Rig(known, hostKey: r.HostKey);
            r2.Flow.Opened(); r2.Challenge();
            var acc = r2.Result(AuthStatus.Accepted);
            t.Equal(Shown(acc)?.Kind, FlowStateKind.Connected, "a known host accepting at once connects silently");
            t.Check(!Has(acc, FlowActionKind.Close), "and the socket stays open");
        }
        using (var saved = TestKey.Random())
        using (var r = new Rig(KnowHost(saved)))
        {
            r.Flow.Opened();
            var a = r.Challenge();
            t.Equal(Shown(a)?.Kind, FlowStateKind.ChangedIdentity, "R4: a different key at a saved address is a changed identity");
            t.Equal(Ended(a)?.Kind, FlowEndKind.Stop, "R4: there is no way forward");
            t.Equal(Sends(a), 0, "R4: nothing is sent");
            t.Equal(Shown(a)?.SavedFingerprint, DeviceIdentity.FingerprintOfKey(saved.Public), "R4: the saved fingerprint is shown");
            t.Equal(Shown(a)?.NowFingerprint, DeviceIdentity.FingerprintOfKey(r.HostKey.Public), "R4: the new fingerprint is shown");
        }
        using (var saved = TestKey.Random())
        using (var r = new Rig(KnowHost(saved)))
        {
            r.Flow.Opened();
            var a = r.Flow.TimerFired(FlowTimer.Challenge);
            t.Equal(Shown(a)?.Kind, FlowStateKind.DidNotIdentify, "R5: a saved host that stays silent is an error");
            t.Equal(Ended(a)?.Kind, FlowEndKind.Stop, "R5: no HELLO, no way forward");
            t.Equal(r.Hellos, 0, "R5: no HELLO is made");
        }
        using (var r = new Rig())
        {
            r.Flow.Opened();
            var a = r.Flow.TimerFired(FlowTimer.Challenge);
            t.Equal(Shown(a)?.Kind, FlowStateKind.AskUnverified, "R6: an unknown silent host asks");
            t.Equal(Sends(a), 0, "R6: nothing is sent while asking");
            var yes = r.Flow.Answered(true);
            t.Equal(Sends(yes), 1, "R6: yes sends a clear HELLO");
            t.Equal(r.Hellos, 1, "R6: one HELLO is made");
            t.Check(yes.Any(x => x.Kind == FlowActionKind.Change && x.Change!.Kind == ChangeKind.AllowUnverified), "R6: the allowance is saved");
            t.Equal(Shown(yes)?.Verified, false, "R6: the session is not verified");
            t.Equal(Sends(r.Flow.Send(Wire.Frame(WireType.Ping, Array.Empty<byte>()))), 1, "R6: later messages go in the clear");
            t.Equal(yes.First(x => x.Kind == FlowActionKind.HostCapabilities).Capabilities, 0u, "R6: no host capabilities are trusted");
            var late = r.Flow.Received(WireType.AuthChallenge, r.Host.Challenge.Payload);
            t.Equal(Ended(late)?.Kind, FlowEndKind.Reconnect, "a challenge after a clear HELLO reconnects");
            t.Equal(Ended(late)?.Carry.ChallengeWait, 10.0, "with a 10 s wait");
        }
        using (var r = new Rig())
        {
            r.Flow.Opened();
            r.Flow.TimerFired(FlowTimer.Challenge);
            var no = r.Flow.Answered(false);
            t.Equal(Ended(no)?.Kind, FlowEndKind.Stop, "R6: no stops");
            t.Equal(r.Hellos, 0, "R6: and nothing was sent");
        }
        {
            var allowed = new KnownHosts();
            allowed.AllowUnverified(Url);
            using var r = new Rig(allowed);
            r.Flow.Opened();
            var a = r.Flow.TimerFired(FlowTimer.Challenge);
            t.Equal(Sends(a), 1, "an already-allowed address connects without asking");
            t.Equal(Shown(a)?.Kind, FlowStateKind.Connected, "and shows connected");
        }
        using (var r = new Rig())
        {
            // A known key reached at a new address: the address is bound after the result verifies.
            var known = KnowHost(r.HostKey, "ws://old.local:5903");
            using var r2 = new Rig(known, url: "ws://new.local:5903", hostKey: r.HostKey);
            r2.Flow.Opened();
            var ch = r2.Challenge();
            t.Equal(Shown(ch)?.Kind, FlowStateKind.Connecting, "R9: a known key at a new address carries on");
            t.Check(!ch.Any(x => x.Kind == FlowActionKind.Change), "R9: nothing is bound before a result verifies");
            var res = r2.Result(AuthStatus.Accepted);
            t.Check(res.Any(x => x.Kind == FlowActionKind.Change && x.Change!.Kind == ChangeKind.Bind), "R9: the address is bound once a result verifies");
            t.Equal(Shown(res)?.Kind, FlowStateKind.Connected, "R9: and it connects");
        }
        using (var first = new Rig())
        using (var other = TestKey.Random())
        {
            // Two saved Macs; the address of the first now reaches the second.
            var known = KnowHost(first.HostKey);
            known.RecordVerified(other.Public, "Other Mac", "ws://192.0.2.21:5903", 1001);
            using var r = new Rig(known, hostKey: other);
            r.Flow.Opened();
            r.Challenge();
            var res = r.Result(AuthStatus.Accepted);
            t.Equal(Ended(res)?.Kind, FlowEndKind.NextAddress, "a different saved Mac at this address is not a success");
            t.Equal(Shown(res)?.Message, "This address now reaches Other Mac", "and says which Mac it reaches now");
            t.Check(res.Any(x => x.Kind == FlowActionKind.Change && x.Change!.Kind == ChangeKind.Bind
                && x.Change.HostId == DeviceIdentity.Id(other.Public)), "the address moves to the Mac that answered");
            t.Equal(Sends(res), 0, "no HELLO and no session");
            t.Check(!r.Flow.IsSecure && r.Flow.IsEnded, "the attempt is over");
        }
        using (var first = new Rig())
        using (var other = TestKey.Random())
        {
            // The caller says which Mac it picked; that holds for an address no saved Mac owns yet.
            var known = KnowHost(first.HostKey, "ws://192.0.2.20:5903");
            known.RecordVerified(other.Public, "Other Mac", "ws://192.0.2.21:5903", 1001);
            using var r = new Rig(known, url: "ws://192.0.2.99:5903", hostKey: first.HostKey);
            r.Config.ExpectedHostId = DeviceIdentity.Id(other.Public);
            r.Flow = new ClientAuthFlow(r.Config, known);
            r.Flow.Opened();
            r.Challenge();
            var res = r.Result(AuthStatus.Accepted);
            t.Equal(Ended(res)?.Kind, FlowEndKind.NextAddress, "the Mac the caller picked is the one that must answer");
            t.Equal(Shown(res)?.Message, "This address now reaches Test Mac", "and the saved name of the Mac that answered is shown");
        }
    }

    // MARK: Retries

    private static void RetryTests(TestRun t)
    {
        var carry = new FlowCarry();
        var delays = new List<double>();
        for (int i = 0; i < 5; i++)
        {
            using var r = new Rig(carry: carry);
            r.Flow.Opened(); r.Challenge();
            var a = r.Result(AuthStatus.Busy);
            var end = Ended(a)!;
            t.Equal(end.Kind, FlowEndKind.Reconnect, $"busy {i + 1} reconnects");
            t.Equal(Shown(a)?.Kind, FlowStateKind.Busy, $"busy {i + 1} shows the busy screen");
            delays.Add(end.After);
            carry = end.Carry;
        }
        t.Check(delays.SequenceEqual(new[] { 15.0, 30.0, 60.0, 120.0, 120.0 }), "busy backs off 15, 30, 60, 120, 120");

        carry = new FlowCarry();
        var seen = new List<double>();
        for (int i = 0; i < 3; i++)
        {
            using var r = new Rig(carry: carry);
            r.Flow.Opened(); r.Challenge();
            var end = Ended(r.Result(AuthStatus.Timeout))!;
            seen.Add(end.After);
            carry = end.Carry;
        }
        t.Check(seen.SequenceEqual(new[] { 0.0, 15.0, 30.0 }), "timeout reconnects at once, then backs off 15, 30");

        using var late = new Rig(carry: new FlowCarry { ChallengeWait = 10 });
        t.Equal(Timer(late.Flow.Opened(), FlowTimer.Challenge)?.Seconds, 10.0, "a carried wait of 10 s is used");
    }

    // MARK: Session

    private static void SessionTests(TestRun t)
    {
        using (var r = new Rig())
        {
            var acc = r.Accepted();
            t.Equal(Sends(acc), 2, "after accepted two sealed messages go out");
            t.Check(acc.Where(a => a.Kind == FlowActionKind.Send).All(a => a.Bytes[0] == WireType.Secure), "both are SECURE");
            var opened = r.Opened(acc);
            t.Equal(opened[0].Type, WireType.Hello, "HELLO is first");
            t.Equal(opened[1].Type, WireType.ClientInfo, "CLIENT_INFO is second");
            t.Check(r.Flow.IsSecure, "the flow is secure");

            var sent = r.Flow.Send(Wire.Frame(WireType.Ping, new byte[] { 9 }));
            var inner = r.Opened(sent)[0];
            t.Equal(inner.Type, WireType.Ping, "app messages are sealed in order");
            t.Same(inner.Payload, new byte[] { 9 }, "and arrive intact");

            var back = r.Flow.Received(WireType.Secure, r.Sealed(WireType.HelloAck, new byte[] { 7 }));
            var d = back.First(a => a.Kind == FlowActionKind.Deliver);
            t.Equal(d.MessageType, WireType.HelloAck, "a sealed message from the host is delivered");

            t.Check(IsFailure(r.Flow.Received(WireType.HelloAck, new byte[] { 7 })), "a clear message after accepted fails");
            var end = r.Flow.SocketClosed();
            t.Check(end.Count == 0, "a close after the flow ended is ignored");
        }
        using (var r = new Rig())
        {
            r.Accepted();
            var good = r.Sealed(WireType.HelloAck, new byte[] { 1 });
            var bad = (byte[])good.Clone();
            bad[0] ^= 1;
            var f = r.Flow.Received(WireType.Secure, bad);
            t.Check(IsFailure(f), "a SECURE message that does not open fails");
            t.Equal(f.Last().Kind, FlowActionKind.End, "the end comes last");
            t.Equal(f.First(a => a.Kind == FlowActionKind.HostCapabilities).Capabilities, 0u, "host capabilities are cleared when the connection ends");
        }
        using (var r = new Rig())
        {
            r.Accepted();
            var first = r.Sealed(WireType.HelloAck, new byte[] { 1 });
            var second = r.Sealed(WireType.HelloAck, new byte[] { 2 });
            t.Check(IsFailure(r.Flow.Received(WireType.Secure, second)), "a reordered SECURE message fails");
        }
        using (var r = new Rig())
        {
            r.Accepted();
            var first = r.Sealed(WireType.HelloAck, new byte[] { 1 });
            t.Check(!IsFailure(r.Flow.Received(WireType.Secure, first)), "the first SECURE message opens");
            t.Check(IsFailure(r.Flow.Received(WireType.Secure, first)), "a replayed SECURE message fails");
        }
        using (var r = new Rig())
        {
            r.Accepted();
            // A forbidden inner type, sealed by hand with the right key and counter.
            var forbidden = r.HostSealer!;
            Throws<AuthException>(t, () => forbidden.Seal(Wire.Frame(WireType.AuthResult, new byte[2])), "a forbidden inner type cannot be sealed");
        }
        using (var r = new Rig())
        {
            r.Flow.Opened(); r.Challenge();
            t.Check(IsFailure(r.Flow.Received(WireType.Secure, new byte[40])), "R3: SECURE before accepted fails");
        }
        using (var r = new Rig())
        {
            r.Flow.Opened(); r.Challenge();
            t.Check(IsFailure(r.Flow.Received(WireType.AuthChallenge, r.Host.Challenge.Payload)), "a second challenge fails");
        }
        using (var r = new Rig())
        {
            r.Flow.Opened();
            var ch = r.Challenge();
            t.Check(!Has(ch, FlowActionKind.HostCapabilities), "no host capabilities before accepted");
        }
    }

    // MARK: Host and client info

    private static void InfoTests(TestRun t)
    {
        using (var r = new Rig(url: "ws://user:pw@mac.local:5903/x?token=1#f"))
        {
            var acc = r.Accepted();
            var info = r.Opened(acc)[1];
            var text = Encoding.UTF8.GetString(info.Payload);
            t.Equal(text, "{\"app\":\"windows\",\"url\":\"ws://mac.local:5903/x\",\"version\":\"1.2.3\"}", "CLIENT_INFO has app, url, version with the URL cleaned");
        }
        t.Equal(ClientAuthFlow.CleanUrl("ws://a:b@h:1/p?q#f"), "ws://h:1/p", "CleanUrl drops user info, query and fragment");
        t.Check(ClientAuthFlow.CleanUrl("") is null, "CleanUrl of nothing is nothing");

        using (var r = new Rig())
        {
            r.Accepted();
            var json = Json("{\"displays\":[{\"urls\":[\"ws://hint.local:5903\",\"ws://hint2.local:5903\"]}],\"name\":\"Mac\"}");
            var a = r.Flow.Received(WireType.Secure, r.Sealed(WireType.HostInfo, json));
            var change = a.FirstOrDefault(x => x.Kind == FlowActionKind.Change);
            t.Equal(change?.Change?.Kind, ChangeKind.Hints, "HOST_INFO becomes address hints");
            t.Equal(change?.Change?.Urls.Count, 2, "both URLs are offered to the store");
            t.Check(!Has(a, FlowActionKind.Deliver), "HOST_INFO is kept by the flow, not delivered");
            var none = r.Flow.Received(WireType.Secure, r.Sealed(WireType.HostInfo, Json("not json")));
            t.Check(!none.Any(x => x.Kind == FlowActionKind.Change) && !IsFailure(none), "a broken HOST_INFO is ignored");
        }
        t.Equal(ClientAuthFlow.HostInfoUrls(new byte[64 * 1024 + 1]).Count, 0, "an oversized HOST_INFO is ignored");
        var many = new StringBuilder("{\"displays\":[");
        for (int d = 0; d < 10; d++)
        {
            if (d > 0) many.Append(',');
            many.Append("{\"urls\":[");
            for (int u = 0; u < 40; u++)
            {
                if (u > 0) many.Append(',');
                many.Append($"\"ws://h{d}-{u}.local\"");
            }
            many.Append("]}");
        }
        many.Append("]}");
        t.Equal(ClientAuthFlow.HostInfoUrls(Json(many.ToString())).Count, 8 * 32, "at most 8 displays and 32 URLs each are read");
    }
}
