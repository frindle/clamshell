using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Clamshell;

// Who this PC is to its peers and which peers it trusts — the mirror of
// Sources/Clamshell/Peer/PeerIdentity.swift, with identical crypto:
//   identity   one P-256 ECDSA key per install; public key on the wire as
//              65-byte X9.63 (04||X||Y); peer id = SHA-256(public key) hex
//   signature  ECDSA-SHA256 over (nonce || own public key), raw r||s (the
//              IEEE P1363 layout .NET produces by default)
//   PIN proof  HMAC-SHA256 keyed with SHA-256("clamshell-pair:" + PIN) over
//              (the other side's nonce || own public key)
// The key lives in %LOCALAPPDATA%\Clamshell (CLAMSHELL_PEER_DIR overrides),
// next to the log; the trust store is a JSON list beside it.

internal sealed class PeerIdentity
{
    private readonly ECDsa _key;
    public byte[] PublicKey { get; }
    public string Id => PeerId(PublicKey);

    private PeerIdentity(ECDsa key)
    {
        _key = key;
        PublicKey = X963(key.ExportParameters(false));
    }

    /// In-memory only (selftests).
    public static PeerIdentity CreateEphemeral() => new(ECDsa.Create(ECCurve.NamedCurves.nistP256));

    /// From a raw 32-byte private scalar (selftest vectors).
    public static PeerIdentity FromScalar(byte[] d)
    {
        var k = ECDsa.Create();
        k.ImportParameters(new ECParameters { Curve = ECCurve.NamedCurves.nistP256, D = d });
        return new PeerIdentity(k);
    }

    /// Loads the key at <paramref name="path"/>, or creates and saves one.
    public static PeerIdentity LoadOrCreate(string path)
    {
        var k = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        try
        {
            if (File.Exists(path))
            {
                k.ImportECPrivateKey(File.ReadAllBytes(path), out _);
                return new PeerIdentity(k);
            }
        }
        catch (Exception e) { Log.Line($"PEER: identity key unreadable ({e.Message}) — making a new one"); }
        k = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, k.ExportECPrivateKey());
        return new PeerIdentity(k);
    }

    public static string DefaultDirectory =>
        Environment.GetEnvironmentVariable("CLAMSHELL_PEER_DIR") is { Length: > 0 } dir
            ? dir
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Clamshell");

    public static string PeerId(byte[] publicKey) => Convert.ToHexString(SHA256.HashData(publicKey)).ToLowerInvariant();

    private static byte[] X963(ECParameters p)
    {
        var o = new byte[65];
        o[0] = 0x04;
        p.Q.X!.CopyTo(o, 1);
        p.Q.Y!.CopyTo(o, 33);
        return o;
    }

    public byte[] Sign(byte[] nonce) =>
        _key.SignData(Concat(nonce, PublicKey), HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);

    public static bool Verify(byte[] signature, byte[] nonce, byte[] publicKey)
    {
        if (signature.Length != 64 || publicKey.Length != 65 || publicKey[0] != 0x04) return false;
        try
        {
            using var k = ECDsa.Create(new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256,
                Q = new ECPoint { X = publicKey[1..33], Y = publicKey[33..65] },
            });
            return k.VerifyData(Concat(nonce, publicKey), signature, HashAlgorithmName.SHA256,
                DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
        }
        catch (CryptographicException) { return false; }
    }

    // MARK: - PIN proofs

    private static byte[] PinKey(string pin) => SHA256.HashData(Encoding.UTF8.GetBytes("clamshell-pair:" + pin));

    public static byte[] PinProof(string pin, byte[] nonce, byte[] publicKey) =>
        HMACSHA256.HashData(PinKey(pin), Concat(nonce, publicKey));

    public static bool VerifyPinProof(byte[] proof, string pin, byte[] nonce, byte[] publicKey) =>
        CryptographicOperations.FixedTimeEquals(proof, PinProof(pin, nonce, publicKey));

    public static byte[] RandomNonce() => RandomNumberGenerator.GetBytes(PeerLimits.NonceSize);
    public static string RandomPin() => RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6");

    internal static byte[] Concat(byte[] a, byte[] b)
    {
        var o = new byte[a.Length + b.Length];
        a.CopyTo(o, 0); b.CopyTo(o, a.Length);
        return o;
    }
}

internal sealed record PeerInfo(string Id, string Name, byte[] PublicKey, DateTime PairedAt);

/// Persisted list of paired peers; lock-protected, rewritten whole on change.
internal sealed class PeerTrustStore
{
    private readonly object _gate = new();
    private readonly string? _path;
    private List<PeerInfo> _peers = new();

    public PeerTrustStore(string? path)
    {
        _path = path;
        if (path is null || !File.Exists(path)) return;
        try { _peers = JsonSerializer.Deserialize<List<PeerInfo>>(File.ReadAllText(path)) ?? new(); }
        catch (Exception e) { Log.Line($"PEER: trust store unreadable ({e.Message}) — starting empty"); }
    }

    public IReadOnlyList<PeerInfo> Peers { get { lock (_gate) return _peers.ToList(); } }
    public PeerInfo? Peer(string id) { lock (_gate) return _peers.FirstOrDefault(p => p.Id == id); }
    public bool IsTrusted(byte[] publicKey) { lock (_gate) return _peers.Any(p => p.PublicKey.AsSpan().SequenceEqual(publicKey)); }

    public void Trust(byte[] publicKey, string name)
    {
        lock (_gate)
        {
            string id = PeerIdentity.PeerId(publicKey);
            int i = _peers.FindIndex(p => p.Id == id);
            if (i >= 0) _peers[i] = _peers[i] with { Name = name };
            else _peers.Add(new PeerInfo(id, name, publicKey, DateTime.UtcNow));
            SaveLocked();
        }
    }

    public void Forget(string id)
    {
        lock (_gate) { _peers.RemoveAll(p => p.Id == id); SaveLocked(); }
    }

    private void SaveLocked()
    {
        if (_path is null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            File.WriteAllText(_path, JsonSerializer.Serialize(_peers, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception e) { Log.Line($"PEER: could not save trust store: {e.Message}"); }
    }
}
