using System.IO;
using System.Security.Cryptography;
using Clamshell.Auth;

namespace Clamshell;

// CngDeviceKey and DeviceKeyException live in WindowsCommon/CngDeviceKey.cs,
// shared with the server. This file keeps what is the viewer's alone.

/// <summary>Where the viewer keeps its saved Macs.</summary>
internal static class ViewerPaths
{
    /// <summary>%APPDATA%\Clamshell</summary>
    public static string DataFolder =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Clamshell");
}

/// <summary>A check of the real Windows key store with a throwaway key name.
/// Run by Windows CI only; it deletes its key at the end.</summary>
internal static class KeyStoreSelfTest
{
    public static int Run()
    {
        var t = new TestRun(Log.Line);
        var name = "Clamshell.Viewer.SelfTest." + Guid.NewGuid().ToString("N");
        t.Group("windows key store", () =>
        {
            CngDeviceKey? first = null;
            try
            {
                t.Check(!CngKey.Exists(name, CngProvider.MicrosoftSoftwareKeyStorageProvider), "the throwaway key does not exist yet");
                first = CngDeviceKey.OpenOrCreate(name);
                t.Check(CngKey.Exists(name, CngProvider.MicrosoftSoftwareKeyStorageProvider), "it exists after the first call");
                t.Check(DeviceIdentity.IsValidPublicKey(first.PublicKey), "its public key is a valid P-256 point");
                t.Check(first.PrivateKeyIsNotExportable(), "its private key cannot be exported");

                var input = new byte[] { 1, 2, 3, 4, 5 };
                var signature = first.Sign(input);
                t.Equal(signature.Length, 64, "a signature is 64 bytes (r then s)");
                t.Check(AuthSignature.Verify(signature, input, first.PublicKey), "the signature verifies with the public key");
                var other = (byte[])input.Clone();
                other[0] ^= 1;
                t.Check(!AuthSignature.Verify(signature, other, first.PublicKey), "it does not verify for other input");

                using var again = CngDeviceKey.OpenOrCreate(name);
                t.Same(again.PublicKey, first.PublicKey, "a second open gives the same key, not a new one");
                t.Check(AuthSignature.Verify(again.Sign(input), input, first.PublicKey), "the second handle signs for the same key");
            }
            finally
            {
                try { first?.Delete(); } catch (Exception e) { Log.Line($"cleanup: {e.Message}"); }
                first?.Dispose();
            }
            t.Check(!CngKey.Exists(name, CngProvider.MicrosoftSoftwareKeyStorageProvider), "the throwaway key is deleted at the end");
        });
        Log.Line($"selftest-keystore: {t.Passed} passed, {t.Failed} failed");
        return t.Failed == 0 ? 0 : 1;
    }
}
