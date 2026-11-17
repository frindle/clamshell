using System.IO;
using System.Security.Cryptography;

namespace Clamshell.Auth;

/// <summary>A P-256 key for one connection's key agreement.</summary>
public sealed class EphemeralKey : IDisposable
{
    private readonly ECDiffieHellman _dh;

    /// <summary>0x04 X Y.</summary>
    public byte[] PublicKey { get; }

    private EphemeralKey(ECDiffieHellman dh)
    {
        _dh = dh;
        PublicKey = P256Util.ExportPublic(dh.ExportParameters(false));
    }

    public static EphemeralKey Generate() => new EphemeralKey(ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256));

    /// <summary>For tests with fixed keys (the vectors): the 32-byte private value
    /// and the 65-byte public key that goes with it.</summary>
    public static EphemeralKey FromPrivate(byte[] privateValue, byte[] publicKey)
    {
        var p = P256Util.PublicParameters(publicKey);
        p.D = privateValue;
        return new EphemeralKey(ECDiffieHellman.Create(p));
    }

    /// <summary>The raw shared secret (the X coordinate, 32 bytes).</summary>
    public byte[] DeriveSecret(byte[] peerPublicKey)
    {
        using var peer = ECDiffieHellman.Create(P256Util.PublicParameters(peerPublicKey));
        return _dh.DeriveRawSecretAgreement(peer.PublicKey);
    }

    public void Dispose() => _dh.Dispose();
}

public sealed class SessionKeys
{
    public byte[] HostToClient { get; }
    public byte[] ClientToHost { get; }
    public byte[] TranscriptHash { get; }

    public SessionKeys(byte[] hostToClient, byte[] clientToHost, byte[] transcriptHash)
    {
        HostToClient = hostToClient;
        ClientToHost = clientToHost;
        TranscriptHash = transcriptHash;
    }

    public static SessionKeys Derive(byte[] sharedSecret, byte[] hostNonce, byte[] clientNonce,
        byte[] challenge, byte[] response)
    {
        var th = AuthWire.TranscriptHash(challenge, response);
        var okm = HKDF.DeriveKey(HashAlgorithmName.SHA256, sharedSecret, 64,
            Wire.Concat(hostNonce, clientNonce), Wire.Concat(AuthWire.SessionInfo, th));
        return new SessionKeys(Wire.Slice(okm, 0, 32), Wire.Slice(okm, 32, 32), th);
    }
}

public static class SecureFrame
{
    /// <summary>0x00000000 then the counter as 8 bytes big-endian.</summary>
    public static byte[] Nonce(ulong counter) => Wire.Concat(new byte[4], Wire.U64(counter));

    /// <summary>SECURE and the three AUTH messages never travel inside SECURE.</summary>
    public static bool IsForbiddenInner(byte type) =>
        type == WireType.Secure || type == WireType.AuthChallenge
        || type == WireType.AuthResponse || type == WireType.AuthResult;
}

/// <summary>Encrypts one direction. The counter is not sent, so whoever owns
/// this must put messages on the wire in the order they were sealed.</summary>
public sealed class SecureSealer
{
    private readonly byte[] _key;
    public ulong Counter { get; private set; }

    public SecureSealer(byte[] key, ulong counter = 0)
    {
        _key = key;
        Counter = counter;
    }

    /// <summary>The SECURE payload (ciphertext then tag) for one whole inner message.</summary>
    public byte[] Seal(byte[] inner)
    {
        if (Counter >= AuthWire.CounterLimit) throw new AuthException(AuthError.CounterExhausted);
        if (inner.Length < 5 || (long)Wire.ReadU32(inner, 1) != inner.Length - 5
            || SecureFrame.IsForbiddenInner(inner[0]))
        {
            throw new AuthException(AuthError.ForbiddenInnerMessage);
        }
        var ciphertext = new byte[inner.Length];
        var tag = new byte[AuthWire.TagBytes];
        using (var aes = new AesGcm(_key, AuthWire.TagBytes))
        {
            aes.Encrypt(SecureFrame.Nonce(Counter), inner, ciphertext, tag);
        }
        Counter++;
        return Wire.Concat(ciphertext, tag);
    }

    /// <summary>The same, framed as a SECURE message ready to send.</summary>
    public byte[] SealMessage(byte[] inner) => Wire.Frame(WireType.Secure, Seal(inner));
}

/// <summary>Decrypts the other direction. Any error means the connection is closed.</summary>
public sealed class SecureOpener
{
    private readonly byte[] _key;
    public ulong Counter { get; private set; }

    public SecureOpener(byte[] key, ulong counter = 0)
    {
        _key = key;
        Counter = counter;
    }

    /// <summary>The inner message of one SECURE payload: its type byte and its payload.</summary>
    public (byte Type, byte[] Payload) Open(byte[] payload)
    {
        if (Counter >= AuthWire.CounterLimit) throw new AuthException(AuthError.CounterExhausted);
        if (payload.Length < AuthWire.TagBytes) throw new AuthException(AuthError.DecryptFailed);
        int split = payload.Length - AuthWire.TagBytes;
        var ciphertext = Wire.Slice(payload, 0, split);
        var tag = Wire.Slice(payload, split, AuthWire.TagBytes);
        var inner = new byte[split];
        try
        {
            using var aes = new AesGcm(_key, AuthWire.TagBytes);
            aes.Decrypt(SecureFrame.Nonce(Counter), ciphertext, tag, inner);
        }
        catch (CryptographicException)
        {
            throw new AuthException(AuthError.DecryptFailed);
        }
        Counter++;
        if (inner.Length < 5 || (long)Wire.ReadU32(inner, 1) != inner.Length - 5)
        {
            throw new AuthException(AuthError.Malformed);
        }
        var type = inner[0];
        if (SecureFrame.IsForbiddenInner(type)) throw new AuthException(AuthError.ForbiddenInnerMessage);
        return (type, Wire.Slice(inner, 5, inner.Length - 5));
    }
}

/// <summary>A device whose response passed every check. That proves it holds
/// the key it showed; whether the key is trusted is the caller's question.</summary>
public sealed class VerifiedDevice
{
    public string Id { get; }
    public byte[] PublicKey { get; }
    /// <summary>Cleaned for display.</summary>
    public string Name { get; }
    public uint Capabilities { get; }
    public IReadOnlyList<AuthExtension> Extensions { get; }
    /// <summary>The whole AUTH_RESPONSE payload as received.</summary>
    public byte[] Response { get; }
    internal byte[] Nonce { get; }
    internal byte[] EphemeralPublicKey { get; }

    internal VerifiedDevice(string id, byte[] publicKey, string name, uint capabilities,
        IReadOnlyList<AuthExtension> extensions, byte[] response, byte[] nonce, byte[] ephemeralPublicKey)
    {
        Id = id;
        PublicKey = publicKey;
        Name = name;
        Capabilities = capabilities;
        Extensions = extensions;
        Response = response;
        Nonce = nonce;
        EphemeralPublicKey = ephemeralPublicKey;
    }

    public string Fingerprint => DeviceIdentity.Fingerprint(Id);
}

/// <summary>The host's half of one connection's handshake.</summary>
public sealed class HostHandshake
{
    public AuthChallenge Challenge { get; }
    private readonly EphemeralKey _ephemeral;

    public HostHandshake(byte[] identityKey, uint capabilities, string name,
        IReadOnlyList<AuthExtension>? extensions = null, EphemeralKey? ephemeral = null, byte[]? nonce = null)
    {
        if (!DeviceIdentity.IsValidPublicKey(identityKey)) throw new AuthException(AuthError.InvalidKey);
        _ephemeral = ephemeral ?? EphemeralKey.Generate();
        var hello = new AuthHello(capabilities, nonce ?? AuthWire.RandomBytes(AuthWire.NonceBytes),
            _ephemeral.PublicKey, identityKey, AuthWire.CleanName(name),
            extensions ?? Array.Empty<AuthExtension>());
        Challenge = new AuthChallenge(hello, hello.Encoded());
    }

    /// <summary>The version, then that both client keys are valid curve points,
    /// then the signature.</summary>
    public VerifiedDevice Verify(byte[] responsePayload)
    {
        if (responsePayload.Length > AuthWire.MaxResponseBytes) throw new AuthException(AuthError.Malformed);
        var response = AuthResponse.Decode(responsePayload);
        if (!DeviceIdentity.IsValidPublicKey(response.Hello.IdentityKey)
            || response.Hello.EphemeralKey.Length != AuthWire.KeyBytes
            || response.Hello.EphemeralKey[0] != 0x04
            || !P256Util.IsOnCurve(response.Hello.EphemeralKey))
        {
            throw new AuthException(AuthError.InvalidKey);
        }
        var input = AuthWire.ClientSignatureInput(Challenge.Payload, response.Body);
        if (!AuthSignature.Verify(response.Signature, input, response.Hello.IdentityKey))
        {
            throw new AuthException(AuthError.BadSignature);
        }
        return new VerifiedDevice(DeviceIdentity.Id(response.Hello.IdentityKey), response.Hello.IdentityKey,
            response.Hello.DisplayName, response.Hello.Capabilities, response.Hello.Extensions,
            responsePayload, response.Hello.Nonce, response.Hello.EphemeralKey);
    }

    /// <summary>A signed AUTH_RESULT payload. <paramref name="response"/> is the
    /// AUTH_RESPONSE payload this answers, exactly as received; it is left out of
    /// the signature for busy and timeout.</summary>
    public byte[] Result(AuthStatus status, byte[] response, AuthSigner sign,
        IReadOnlyList<AuthExtension>? extensions = null)
    {
        var body = AuthResult.MakeBody(status, extensions);
        var covered = AuthStatusInfo.SignsEmptyResponse(status) ? Array.Empty<byte>() : response;
        var signature = sign(AuthWire.HostSignatureInput(Challenge.Payload, covered, body));
        if (signature.Length != AuthWire.SignatureBytes) throw new AuthException(AuthError.BadSignature);
        return Wire.Concat(body, signature);
    }

    public SessionKeys DeriveSessionKeys(VerifiedDevice device)
    {
        var shared = _ephemeral.DeriveSecret(device.EphemeralPublicKey);
        return SessionKeys.Derive(shared, Challenge.Hello.Nonce, device.Nonce,
            Challenge.Payload, device.Response);
    }
}

/// <summary>The client's half: reads the challenge, builds the signed response,
/// checks each result against the host key the challenge named.</summary>
public sealed class ClientHandshake
{
    public AuthChallenge Challenge { get; }
    /// <summary>The AUTH_RESPONSE payload to send.</summary>
    public byte[] Response { get; }
    private readonly byte[] _nonce;
    private readonly EphemeralKey _ephemeral;

    public byte[] HostIdentityKey => Challenge.Hello.IdentityKey;
    public string HostId => DeviceIdentity.Id(Challenge.Hello.IdentityKey);
    public string HostFingerprint => DeviceIdentity.Fingerprint(HostId);
    public string HostName => Challenge.Hello.DisplayName;
    public uint HostCapabilities => Challenge.Hello.Capabilities;

    /// <summary>Throws for a challenge of another version or with a key that is
    /// not a valid curve point: either is a failed connection.</summary>
    public ClientHandshake(byte[] challengePayload, byte[] deviceKey, uint capabilities, string name,
        AuthSigner sign, IReadOnlyList<AuthExtension>? extensions = null,
        EphemeralKey? ephemeral = null, byte[]? nonce = null)
    {
        var challenge = AuthChallenge.Decode(challengePayload);
        if (!DeviceIdentity.IsValidPublicKey(challenge.Hello.IdentityKey)
            || challenge.Hello.EphemeralKey.Length != AuthWire.KeyBytes
            || challenge.Hello.EphemeralKey[0] != 0x04
            || !P256Util.IsOnCurve(challenge.Hello.EphemeralKey)
            || !DeviceIdentity.IsValidPublicKey(deviceKey))
        {
            throw new AuthException(AuthError.InvalidKey);
        }
        var eph = ephemeral ?? EphemeralKey.Generate();
        var n = nonce ?? AuthWire.RandomBytes(AuthWire.NonceBytes);
        var hello = new AuthHello(capabilities, n, eph.PublicKey, deviceKey, AuthWire.CleanName(name),
            extensions ?? Array.Empty<AuthExtension>());
        var body = hello.Encoded();
        var signature = sign(AuthWire.ClientSignatureInput(challengePayload, body));
        if (signature.Length != AuthWire.SignatureBytes) throw new AuthException(AuthError.BadSignature);
        Challenge = challenge;
        Response = Wire.Concat(body, signature);
        _nonce = n;
        _ephemeral = eph;
    }

    /// <summary>The status of an AUTH_RESULT whose signature verifies against the
    /// challenge's host key. One that does not verify is a failed connection,
    /// whatever its status says.</summary>
    public AuthStatus StatusOfResult(byte[] payload)
    {
        var result = AuthResult.Decode(payload);
        var covered = AuthStatusInfo.SignsEmptyResponse(result.Status) ? Array.Empty<byte>() : Response;
        var input = AuthWire.HostSignatureInput(Challenge.Payload, covered, result.Body);
        if (!AuthSignature.Verify(result.Signature, input, HostIdentityKey))
        {
            throw new AuthException(AuthError.BadSignature);
        }
        return result.Status;
    }

    public SessionKeys DeriveSessionKeys()
    {
        var shared = _ephemeral.DeriveSecret(Challenge.Hello.EphemeralKey);
        return SessionKeys.Derive(shared, Challenge.Hello.Nonce, _nonce,
            Challenge.Payload, Response);
    }
}
