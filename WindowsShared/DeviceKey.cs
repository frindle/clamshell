using System.IO;
using System.Security.Cryptography;

namespace Clamshell.Auth;

/// <summary>This device's signing key, as the handshake sees it: a public key
/// and a way to sign. The private half never leaves wherever it is kept.</summary>
public interface IDeviceKey
{
    /// <summary>The 65-byte uncompressed P-256 public key.</summary>
    byte[] PublicKey { get; }
    /// <summary>A 64-byte r||s signature over the input.</summary>
    byte[] Sign(byte[] input);
}

/// <summary>A key held in memory: for tests and for the interop test, never for
/// the viewer, which keeps its key in the Windows key store.</summary>
public sealed class MemoryDeviceKey : IDeviceKey, IDisposable
{
    private readonly ECDsa _key;
    public byte[] PublicKey { get; }

    public MemoryDeviceKey()
    {
        _key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        PublicKey = P256Util.ExportPublic(_key.ExportParameters(false));
    }

    public byte[] Sign(byte[] input) => AuthSignature.Sign(_key, input);

    public void Dispose() => _key.Dispose();
}
