using System.IO;
using System.Security.Cryptography;
using Clamshell.Auth;

namespace Clamshell;

/// <summary>The key store could not give this device a signing key. The message
/// is for the person using the app. Nothing is connected without a key, and no
/// other key is used in its place.</summary>
internal sealed class DeviceKeyException : Exception
{
    public DeviceKeyException(string message, Exception? inner = null) : base(message, inner) { }
}

/// <summary>This PC's device key: a P-256 key kept by the Windows key store
/// (the software provider, current user), created once, marked as not
/// exportable, and used only for signing. The private half never reaches this
/// program's memory. A key that exists is opened, never replaced; if it cannot
/// be opened or created the viewer says so and does not connect.</summary>
internal sealed class CngDeviceKey : IDeviceKey, IDisposable
{
    /// <summary>The name of the viewer's key in the store.</summary>
    public const string StoreName = "Clamshell.Viewer.DeviceKey.v1";

    private static readonly CngProvider Provider = CngProvider.MicrosoftSoftwareKeyStorageProvider;

    private readonly CngKey _key;
    private readonly ECDsaCng _ecdsa;
    public string Name { get; }
    public byte[] PublicKey { get; }

    private CngDeviceKey(string name, CngKey key)
    {
        Name = name;
        _key = key;
        try
        {
            _ecdsa = new ECDsaCng(key);
            PublicKey = ReadPublic(key);
            if (!DeviceIdentity.IsValidPublicKey(PublicKey))
            {
                throw new DeviceKeyException("The device key in the Windows key store is not a usable P-256 key.");
            }
        }
        catch
        {
            _ecdsa?.Dispose();
            key.Dispose();
            throw;
        }
    }

    /// <summary>Opens the key with this name, creating it only if there is none.</summary>
    public static CngDeviceKey OpenOrCreate(string name = StoreName)
    {
        try
        {
            if (CngKey.Exists(name, Provider))
            {
                return new CngDeviceKey(name, CngKey.Open(name, Provider));
            }
            var parameters = new CngKeyCreationParameters
            {
                Provider = Provider,
                KeyUsage = CngKeyUsages.Signing,
                ExportPolicy = CngExportPolicies.None,
            };
            return new CngDeviceKey(name, CngKey.Create(CngAlgorithm.ECDsaP256, name, parameters));
        }
        catch (DeviceKeyException)
        {
            throw;
        }
        catch (CryptographicException e)
        {
            // Another copy of the viewer may have created it a moment ago: open that one.
            try
            {
                if (CngKey.Exists(name, Provider)) return new CngDeviceKey(name, CngKey.Open(name, Provider));
            }
            catch (CryptographicException) { /* report the first error below */ }
            throw new DeviceKeyException(
                "The Windows key store would not open or create this PC's device key: " + e.Message, e);
        }
    }

    public byte[] Sign(byte[] input) => AuthSignature.Sign(_ecdsa, input);

    /// <summary>True when the key's private half cannot be exported.</summary>
    public bool PrivateKeyIsNotExportable()
    {
        try
        {
            _ecdsa.ExportPkcs8PrivateKey();
            return false;
        }
        catch (CryptographicException)
        {
            return true;
        }
    }

    /// <summary>Removes the key from the store. Only the self-test uses it, with a throwaway name.</summary>
    public void Delete()
    {
        _key.Delete();
    }

    public void Dispose()
    {
        _ecdsa.Dispose();
        _key.Dispose();
    }

    /// <summary>0x04 X Y from the ECCPUBLIC_BLOB: magic, length, X, Y.</summary>
    private static byte[] ReadPublic(CngKey key)
    {
        var blob = key.Export(CngKeyBlobFormat.EccPublicBlob);
        if (blob.Length != 8 + 64) throw new DeviceKeyException("The device key in the Windows key store is not a P-256 key.");
        return Wire.Concat(new byte[] { 0x04 }, Wire.Slice(blob, 8, 64));
    }
}

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
