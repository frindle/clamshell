using System.Security.Cryptography;
using Clamshell.Auth;

namespace Clamshell;

/// <summary>The key store could not give this program a signing key. The message
/// is for the person using the app. Nothing is connected without a key, and no
/// other key is used in its place.</summary>
internal sealed class DeviceKeyException : Exception
{
    public DeviceKeyException(string message, Exception? inner = null) : base(message, inner) { }
}

/// <summary>A P-256 key kept by the Windows key store (the software provider,
/// current user), created once, marked as not exportable, and used only for
/// signing. The private half never reaches this program's memory. A key that
/// exists is opened, never replaced; if it cannot be opened or created the
/// program says so and does not connect or accept.
///
/// Shared by the viewer (its device key) and the server (the host's identity
/// key); each uses a name of its own.</summary>
internal sealed class CngDeviceKey : IDeviceKey, IDisposable
{
    /// <summary>The name of the viewer's key in the store.</summary>
    public const string StoreName = "Clamshell.Viewer.DeviceKey.v1";

    /// <summary>The name of the server's identity key in the store. Not the viewer's.</summary>
    public const string HostStoreName = "Clamshell.Host.IdentityKey.v1";

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
                throw new DeviceKeyException("The key in the Windows key store is not a usable P-256 key.");
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
            // Another copy of the program may have created it a moment ago: open that one.
            try
            {
                if (CngKey.Exists(name, Provider)) return new CngDeviceKey(name, CngKey.Open(name, Provider));
            }
            catch (CryptographicException) { /* report the first error below */ }
            throw new DeviceKeyException(
                "The Windows key store would not open or create this PC's key: " + e.Message, e);
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

    /// <summary>Removes the key from the store. Only the self-tests use it, with a throwaway name.</summary>
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
        if (blob.Length != 8 + 64) throw new DeviceKeyException("The key in the Windows key store is not a P-256 key.");
        return Wire.Concat(new byte[] { 0x04 }, Wire.Slice(blob, 8, 64));
    }
}
