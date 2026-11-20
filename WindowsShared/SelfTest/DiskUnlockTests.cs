namespace Clamshell.Auth;

/// <summary>Host-key pinning (new, match, mismatch), the timeout and log hygiene of "Unlock disk",
/// with a fake SSH transport that behaves like a library: it reports the server's key and signs in
/// (records the password) only if the key was accepted.</summary>
public static class DiskUnlockTests
{
    private const string Secret = "Zebra-Quartz-19-synthetic";

    private sealed class FakeServer : ISshUnlockTransport
    {
        public string Fingerprint = "SHA256:AAAA";
        public bool PasswordOk = true, Reachable = true, Hang;
        public List<string> Received = new();
        public async Task<SshAttempt> AttemptAsync(string host, int port, string username, string password, TimeSpan connectTimeout,
            Func<string, bool> acceptHostKey, CancellationToken ct)
        {
            if (Hang) { try { await Task.Delay(TimeSpan.FromSeconds(5), ct); } catch (OperationCanceledException) { } return SshAttempt.Failed; }
            if (!Reachable) return SshAttempt.ConnectFailed;
            if (!acceptHostKey(Fingerprint)) return SshAttempt.HostKeyRefused;
            Received.Add(password);
            return PasswordOk ? SshAttempt.Authenticated : SshAttempt.AuthFailed;
        }
    }

    private sealed class Env
    {
        public SshHostPins Pins = new();
        public List<string> Asked = new();
        public bool Answer = true;
        public List<string> Lines = new();
    }

    private static DiskUnlocker Make(FakeServer s, Env e, TimeSpan? overall = null) =>
        new(s, () => e.Pins, p => e.Pins = p, (_, fp) => { e.Asked.Add(fp); return e.Answer; }, e.Lines.Add, overall);

    private static DiskUnlockResult Run(DiskUnlocker u, string host = "mac.example.com", string user = "tester") =>
        u.UnlockAsync(host, 22, user, Secret).GetAwaiter().GetResult();

    public static void Run(TestRun t)
    {
        t.Group("unlock disk: host key pinning", () => Pinning(t));
        t.Group("unlock disk: results and timeout", () => Results(t));
        t.Group("unlock disk: no secrets in logs", () => Logs(t));
    }

    private static void Pinning(TestRun t)
    {
        var s = new FakeServer(); var e = new Env(); var u = Make(s, e);
        t.Equal(Run(u), DiskUnlockResult.Unlocked, "a new key is asked about and accepted");
        t.Equal(string.Join(",", e.Asked), "SHA256:AAAA", "the fingerprint was shown once");
        t.Equal(e.Pins.Pins["mac.example.com:22"], "SHA256:AAAA", "and pinned");
        t.Equal(Run(u, "MAC.example.com"), DiskUnlockResult.Unlocked, "the same key matches (host case ignored)");
        t.Equal(e.Asked.Count, 1, "a pinned key is not asked about again");

        s = new FakeServer(); e = new Env { Answer = false };
        t.Equal(Run(Make(s, e)), DiskUnlockResult.HostKeyDeclined, "declining the new key stops");
        t.Equal(s.Received.Count, 0, "nothing was sent to a key the user declined");
        t.Equal(e.Pins.Pins.Count, 0, "and nothing was pinned");

        s = new FakeServer { Fingerprint = "SHA256:BBBB" }; e = new Env();
        e.Pins.Pin("mac.example.com:22", "SHA256:AAAA");
        t.Equal(Run(Make(s, e)), DiskUnlockResult.HostKeyMismatch, "a different key is refused");
        t.Equal(s.Received.Count, 0, "the password was not sent to a key that does not match");
        t.Equal(e.Asked.Count, 0, "a mismatch is not asked about");
        t.Equal(e.Pins.Pins["mac.example.com:22"], "SHA256:AAAA", "the pin is not replaced");
    }

    private static void Results(TestRun t)
    {
        var s = new FakeServer { PasswordOk = false }; var e = new Env();
        t.Equal(Run(Make(s, e)), DiskUnlockResult.WrongPassword, "a refused password");
        s = new FakeServer { Reachable = false };
        t.Equal(Run(Make(s, new Env())), DiskUnlockResult.Unreachable, "an unreachable Mac");
        s = new FakeServer { Hang = true };
        t.Equal(Run(Make(s, new Env(), TimeSpan.FromMilliseconds(200))), DiskUnlockResult.TimedOut, "the overall timeout");
        t.Equal(DiskUnlocker.ConnectTimeout.TotalSeconds, 10.0, "connect timeout is 10 s");
        t.Equal(DiskUnlocker.OverallTimeout.TotalSeconds, 60.0, "overall timeout is 60 s");
    }

    private static void Logs(TestRun t)
    {
        var s = new FakeServer(); var e = new Env(); var u = Make(s, e);
        var texts = new List<string>();
        foreach (var ok in new[] { true, false }) { s.PasswordOk = ok; texts.Add(DiskUnlockText.Of(Run(u, user: "tester-user"))); }
        s.Fingerprint = "SHA256:CCCC";
        texts.Add(DiskUnlockText.Of(Run(u, user: "tester-user")));
        var all = string.Join("\n", e.Lines.Concat(texts));
        t.Check(!all.Contains(Secret), "the password is in no log line or message");
        t.Check(!all.Contains("tester-user"), "the user name is in no log line or message");
        t.Check(e.Lines.Count > 0, "something was logged");
        t.Equal(SshFingerprint.Sha256(Array.Empty<byte>()), "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU", "fingerprint format matches OpenSSH");
    }
}
