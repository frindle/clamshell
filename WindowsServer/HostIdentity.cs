using Clamshell.Auth;

namespace Clamshell;

/// <summary>The host's long-term identity: the P-256 key whose fingerprint a
/// device shows its user before they approve the host (PROTOCOL.md "Device
/// authentication"). It lives in the Windows key store for the current user,
/// not exportable, under a name of its own. The Mac host's HostAuth.identity is
/// the reference.
///
/// If the key store will not give out a key, the host still runs, with a key
/// for this run only, and says so (<see cref="IsPersistent"/>): devices would
/// see a changed identity next time, which is the safe way for this to fail.</summary>
internal sealed class HostIdentity : IDisposable
{
    private readonly IDeviceKey _key;
    private readonly IDisposable? _owned;

    public byte[] PublicKey => _key.PublicKey;
    public string Id { get; }
    /// <summary><c>AB12-CD34-EF56-7890</c>, what people compare.</summary>
    public string Fingerprint { get; }
    /// <summary>False when the key is held in memory for this run only.</summary>
    public bool IsPersistent { get; }
    /// <summary>Why the key is not persistent, for the tray and the log; empty when it is.</summary>
    public string Problem { get; }

    private HostIdentity(IDeviceKey key, IDisposable owned, bool persistent, string problem)
    {
        _key = key;
        _owned = owned;
        IsPersistent = persistent;
        Problem = problem;
        Id = DeviceIdentity.Id(key.PublicKey);
        Fingerprint = DeviceIdentity.Fingerprint(Id);
    }

    public byte[] Sign(byte[] input) => _key.Sign(input);

    /// <summary>The signer the handshake wants.</summary>
    public AuthSigner Signer => Sign;

    /// <summary>Opens the host key, creating it on first run.</summary>
    public static HostIdentity Open(string name = CngDeviceKey.HostStoreName)
    {
        try
        {
            var key = CngDeviceKey.OpenOrCreate(name);
            return new HostIdentity(key, key, persistent: true, problem: "");
        }
        catch (DeviceKeyException e)
        {
            Log.Line($"host key: {e.Message} Using a key for this run only.");
            var key = new MemoryDeviceKey();
            return new HostIdentity(key, key, persistent: false, problem: e.Message);
        }
    }

    /// <summary>Removes the key from the key store. Only the self-test uses it.</summary>
    public void DeleteFromStore()
    {
        if (_owned is CngDeviceKey cng) cng.Delete();
    }

    public void Dispose() => _owned?.Dispose();
}

/// <summary>`ClamshellServer selftest-hostkey`: the host key in the real Windows
/// key store, with a throwaway name. Run by Windows CI; deletes its key.</summary>
internal static class HostKeySelfTest
{
    public static int Run()
    {
        var t = new TestRun(Log.Line);
        var name = "Clamshell.Host.SelfTest." + Guid.NewGuid().ToString("N");
        var provider = System.Security.Cryptography.CngProvider.MicrosoftSoftwareKeyStorageProvider;
        t.Group("host identity key", () =>
        {
            HostIdentity? first = null;
            try
            {
                t.Check(CngDeviceKey.HostStoreName != CngDeviceKey.StoreName, "the host key's name is not the viewer's");
                t.Check(!System.Security.Cryptography.CngKey.Exists(name, provider), "the throwaway key does not exist yet");
                first = HostIdentity.Open(name);
                t.Check(first.IsPersistent, "the key is kept in the key store");
                t.Check(System.Security.Cryptography.CngKey.Exists(name, provider), "it exists after the first call");
                t.Check(DeviceIdentity.IsValidPublicKey(first.PublicKey), "its public key is a valid P-256 point");
                t.Equal(first.Id, DeviceIdentity.Id(first.PublicKey), "its id is the SHA-256 of its public key");
                t.Equal(first.Fingerprint, DeviceIdentity.FingerprintOfKey(first.PublicKey), "its fingerprint is computed as the clients compute it");

                var input = new byte[] { 9, 8, 7, 6 };
                var signature = first.Sign(input);
                t.Equal(signature.Length, 64, "a signature is 64 bytes (r then s)");
                t.Check(AuthSignature.Verify(signature, input, first.PublicKey), "the signature verifies with the public key");

                using var again = HostIdentity.Open(name);
                t.Equal(again.Fingerprint, first.Fingerprint, "a second open gives the same key, not a new one");
            }
            finally
            {
                try { first?.DeleteFromStore(); } catch (Exception e) { Log.Line($"cleanup: {e.Message}"); }
                first?.Dispose();
            }
            t.Check(!System.Security.Cryptography.CngKey.Exists(name, provider), "the throwaway key is deleted at the end");
        });
        Log.Line($"selftest-hostkey: {t.Passed} passed, {t.Failed} failed");
        return t.Failed == 0 ? 0 : 1;
    }
}
