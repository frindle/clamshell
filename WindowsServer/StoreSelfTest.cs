using System.IO;
using System.Text;
using Clamshell.Auth;

namespace Clamshell;

// `ClamshellServer selftest-store`: exercises the device list against the real
// Windows data protection (DPAPI) and the real file system, in a throwaway
// folder. Made-up names and addresses only.
internal static class StoreSelfTest
{
    private static int _failures;

    private static void Check(bool ok, string what)
    {
        Console.Error.WriteLine($"store-selftest: {(ok ? "ok  " : "FAIL")} {what}");
        if (!ok) _failures++;
    }

    private static byte[] NewKey()
    {
        using var k = new MemoryDeviceKey();
        return k.PublicKey;
    }

    private static bool NoConnection(string _) => false;

    public static int Run()
    {
        var folder = Path.Combine(Path.GetTempPath(), "clamshell-store-selftest-" + Guid.NewGuid().ToString("N"));
        try
        {
            RoundTrip(folder);
            Damaged(folder + "-damaged");
            Newer(folder + "-newer");
            TwoInstances(folder + "-two");
            Limits(folder + "-limits");
            Dpapi(folder + "-dpapi");
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"store-selftest: FAIL unexpected {e.GetType().Name}: {e.Message}{Environment.NewLine}{e.StackTrace}");
            _failures++;
        }
        finally
        {
            foreach (var suffix in new[] { "", "-damaged", "-newer", "-two", "-limits", "-dpapi" })
            {
                try { Directory.Delete(folder + suffix, true); } catch (Exception) { /* may not exist */ }
            }
        }
        Console.Error.WriteLine(_failures == 0 ? "store-selftest: PASS" : $"store-selftest: FAIL ({_failures})");
        return _failures == 0 ? 0 : 1;
    }

    private static void RoundTrip(string folder)
    {
        var key = NewKey();
        var id = DeviceIdentity.Id(key);
        using (var s = new DeviceTrustStore(folder, watch: false))
        {
            Check(s.ListProblem == DeviceTrustStore.Problem.None && s.CanPersist, "a new folder starts empty and usable");
            var a = s.Ask(key, "Example Phone", "192.0.2.10", AddressGroup.Of("192.0.2.10"), NoConnection);
            Check(a == DeviceTrustStore.Answer.Waiting, "an unknown device is put on the waiting list");
            Check(s.Waiting().Count == 1, "it shows in the waiting list");
            var d = s.Decide(id, DeviceTrustStore.Decision.Approve, DeviceTrustStore.DecidedOnCommandLine, onlyIfWaiting: true);
            Check(d?.State == DeviceState.Trusted && d.DecidedBy == "cli", "approving makes it trusted, decided on the command line");
        }
        using (var s = new DeviceTrustStore(folder, watch: false))
        {
            Check(s.IsTrusted(id), "a new store reads the trusted device back from disk");
            Check(s.Record(id)?.Name == "Example Phone" && s.Record(id)?.Address == "192.0.2.10", "name and address survive");
            Check(s.Ask(key, "Example Phone", "192.0.2.10", null, NoConnection) == DeviceTrustStore.Answer.Trusted, "a trusted device is answered Trusted");
            Check(s.Revoke(id, DeviceTrustStore.DecidedOnHost)?.State == DeviceState.Denied, "revoking makes it denied");
            Check(s.Ask(key, "Example Phone", "192.0.2.10", null, NoConnection) == DeviceTrustStore.Answer.Denied, "a denied device is answered Denied");
            Check(s.Forget(id) != null && s.Record(id) == null, "forgetting removes it");
            Check(s.Resolve(DeviceIdentity.Fingerprint(id)).Kind == DeviceTrustStore.MatchKind.None, "it is no longer found");
            Check(s.Resolve("xyz").Kind == DeviceTrustStore.MatchKind.BadQuery, "a bad query is not guessed at");
        }
        // The file on disk is not plain text.
        var bytes = File.ReadAllBytes(Path.Combine(folder, DeviceTrustStore.FileName));
        Check(bytes.Length > 0 && Encoding.UTF8.GetString(bytes).IndexOf("publicKey", StringComparison.Ordinal) < 0,
            "the file on disk does not contain the plain list");
    }

    private static void Damaged(string folder)
    {
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, DeviceTrustStore.FileName);
        var garbage = Encoding.UTF8.GetBytes("{\"version\":1,\"devices\":[]}");
        File.WriteAllBytes(path, garbage); // plain text, not DPAPI data
        using var s = new DeviceTrustStore(folder, watch: false);
        Check(s.ListProblem == DeviceTrustStore.Problem.Damaged, "a file that is not DPAPI data is reported damaged");
        Check(s.ProblemMessage != null, "and there is a message for it");
        var key = NewKey();
        var a = s.Ask(key, "Example Phone", "192.0.2.11", null, NoConnection);
        Check(a != DeviceTrustStore.Answer.Trusted, "nobody is trusted while it is damaged");
        Check(s.Decide(DeviceIdentity.Id(key), DeviceTrustStore.Decision.Approve, "cli", false) == null, "nothing can be decided");
        Check(File.ReadAllBytes(path).AsSpan().SequenceEqual(garbage), "the file is left byte for byte as it was");
        Check(Directory.GetFiles(folder).Select(Path.GetFileName).All(n => n == DeviceTrustStore.FileName || n == DeviceTrustStore.LockName),
            "no copy was moved aside");
    }

    private static void Newer(string folder)
    {
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, DeviceTrustStore.FileName);
        var blob = global::Clamshell.Dpapi.Protect(Encoding.UTF8.GetBytes("{\"version\":99,\"devices\":[]}"));
        File.WriteAllBytes(path, blob);
        using var s = new DeviceTrustStore(folder, watch: false);
        Check(s.ListProblem == DeviceTrustStore.Problem.NewerVersion, "a newer version is reported as such");
        s.Ask(NewKey(), "Example Phone", "192.0.2.12", null, NoConnection);
        Check(File.ReadAllBytes(path).AsSpan().SequenceEqual(blob), "a newer file is left alone");

        // An entry whose id is not the hash of its key makes the whole list damaged.
        var key = NewKey();
        var bad = "{\"version\":1,\"devices\":[{\"id\":\"" + new string('a', 64) + "\",\"publicKey\":\"" + Hex.Encode(key)
            + "\",\"name\":\"x\",\"state\":\"trusted\",\"firstSeen\":1,\"lastSeen\":1,\"address\":\"\"}]}";
        File.WriteAllBytes(path, global::Clamshell.Dpapi.Protect(Encoding.UTF8.GetBytes(bad)));
        s.Reload();
        Check(s.ListProblem == DeviceTrustStore.Problem.Damaged && s.All().Count == 0, "an entry with someone else's id fails the whole list closed");
    }

    private static void TwoInstances(string folder)
    {
        var key = NewKey();
        var id = DeviceIdentity.Id(key);
        using var host = new DeviceTrustStore(folder, watch: true, reloadInterval: TimeSpan.FromSeconds(1));
        using var cli = new DeviceTrustStore(folder, watch: false);
        int changes = 0;
        host.DidChange += () => Interlocked.Increment(ref changes);
        host.Ask(key, "Example Phone", "192.0.2.13", null, NoConnection);
        Check(cli.Waiting().Count == 0, "a second instance does not see it until it reads");
        cli.Reload();
        Check(cli.Waiting().Count == 1, "a second instance sees it after reading the file");
        cli.Decide(id, DeviceTrustStore.Decision.Approve, DeviceTrustStore.DecidedOnCommandLine, true);
        bool seen = Poll(() => host.IsTrusted(id), 10);
        Check(seen, "the running host notices an approval made by another instance");
        Check(Volatile.Read(ref changes) > 0, "and tells its observers");
        cli.Revoke(id, DeviceTrustStore.DecidedOnCommandLine);
        Check(Poll(() => host.StateOf(id) == DeviceState.Denied, 10), "the running host notices a revoke");
    }

    private static bool Poll(Func<bool> done, int seconds)
    {
        var end = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < end)
        {
            if (done()) return true;
            Thread.Sleep(100);
        }
        return done();
    }

    private static void Limits(string folder)
    {
        double now = 1_000_000;
        using var s = new DeviceTrustStore(folder, watch: false, now: () => now);
        int busy = 0, waiting = 0;
        // Different groups, so only the list's own limits apply: 10 new devices a minute.
        for (int i = 0; i < 12; i++)
        {
            var a = s.Ask(NewKey(), $"Example {i}", $"198.51.100.{i + 1}", AddressGroup.Of($"198.51.100.{i + 1}"), NoConnection);
            if (a == DeviceTrustStore.Answer.Busy) busy++; else waiting++;
        }
        Check(waiting == 10 && busy == 2, $"10 new devices a minute are listed, the rest turned away (listed {waiting}, busy {busy})");

        // One group: 3 a minute.
        s.ForgetRecentAdds();
        int fromOne = 0;
        for (int i = 0; i < 6; i++)
        {
            if (s.Ask(NewKey(), "Same Place", "203.0.113.5", AddressGroup.Of("203.0.113.5"), NoConnection) == DeviceTrustStore.Answer.Waiting) fromOne++;
        }
        Check(fromOne == 3, $"one address group lists at most 3 a minute (listed {fromOne})");

        // Waiting devices expire after 24 hours.
        int before = s.Waiting().Count;
        now += DeviceTrustStore.WaitingLifetime + 10;
        Check(before > 0 && s.Waiting().Count == 0, "waiting devices expire after 24 hours");
    }

    private static void Dpapi(string folder)
    {
        Directory.CreateDirectory(folder);
        var plain = Encoding.UTF8.GetBytes("example");
        var blob = global::Clamshell.Dpapi.Protect(plain);
        Check(!blob.AsSpan().SequenceEqual(plain), "DPAPI output differs from the input");
        Check(global::Clamshell.Dpapi.Unprotect(blob).AsSpan().SequenceEqual(plain), "DPAPI round trip");
        blob[blob.Length / 2] ^= 0x55;
        bool threw = false;
        try { global::Clamshell.Dpapi.Unprotect(blob); }
        catch (System.Security.Cryptography.CryptographicException) { threw = true; }
        Check(threw, "a damaged blob is refused");
    }
}
