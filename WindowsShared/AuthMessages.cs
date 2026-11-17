using System.IO;
using System.Text;

namespace Clamshell.Auth;

/// <summary>The fields AUTH_CHALLENGE and AUTH_RESPONSE share, in wire order.</summary>
public sealed class AuthHello
{
    public uint Capabilities { get; }
    public byte[] Nonce { get; }
    public byte[] EphemeralKey { get; }
    public byte[] IdentityKey { get; }
    /// <summary>As sent. Use <see cref="DisplayName"/> wherever a person will read it.</summary>
    public string Name { get; }
    public IReadOnlyList<AuthExtension> Extensions { get; }

    public AuthHello(uint capabilities, byte[] nonce, byte[] ephemeralKey, byte[] identityKey,
        string name, IReadOnlyList<AuthExtension> extensions)
    {
        Capabilities = capabilities;
        Nonce = nonce;
        EphemeralKey = ephemeralKey;
        IdentityKey = identityKey;
        Name = name;
        Extensions = extensions;
    }

    public string DisplayName => AuthWire.CleanName(Name);

    public byte[] Encoded()
    {
        if (Nonce.Length != AuthWire.NonceBytes
            || EphemeralKey.Length != AuthWire.KeyBytes
            || IdentityKey.Length != AuthWire.KeyBytes) throw new AuthException(AuthError.Malformed);
        var nameBytes = Encoding.UTF8.GetBytes(Name);
        if (nameBytes.Length > AuthWire.MaxNameBytes) throw new AuthException(AuthError.Malformed);
        var ext = AuthWire.EncodeExtensions(Extensions);
        return Wire.Concat(
            new[] { AuthWire.Version },
            Wire.U32(Capabilities),
            Nonce,
            EphemeralKey,
            IdentityKey,
            new[] { (byte)nameBytes.Length },
            nameBytes,
            Wire.U16((ushort)ext.Length),
            ext);
    }

    /// <summary>Reads the shared fields and leaves the reader at whatever follows them.</summary>
    public static AuthHello Decode(ByteReader r)
    {
        var version = r.Byte();
        if (version is null) throw new AuthException(AuthError.Malformed);
        if (version.Value != AuthWire.Version) throw new AuthException(AuthError.UnsupportedVersion);
        var caps = r.UInt32();
        var nonce = r.Bytes(AuthWire.NonceBytes);
        var ephemeral = r.Bytes(AuthWire.KeyBytes);
        var identity = r.Bytes(AuthWire.KeyBytes);
        var nameLength = r.Byte();
        if (caps is null || nonce is null || ephemeral is null || identity is null
            || nameLength is null || nameLength.Value > AuthWire.MaxNameBytes)
        {
            throw new AuthException(AuthError.Malformed);
        }
        var nameBytes = r.Bytes(nameLength.Value);
        var extLength = r.UInt16();
        if (nameBytes is null || extLength is null) throw new AuthException(AuthError.Malformed);
        var ext = r.Bytes(extLength.Value);
        if (ext is null) throw new AuthException(AuthError.Malformed);
        return new AuthHello(caps.Value, nonce, ephemeral, identity,
            Encoding.UTF8.GetString(nameBytes), AuthWire.DecodeExtensions(ext));
    }
}

public sealed class AuthChallenge
{
    public AuthHello Hello { get; }
    /// <summary>The payload exactly as it crossed the wire: both signatures cover it.</summary>
    public byte[] Payload { get; }

    public AuthChallenge(AuthHello hello, byte[] payload) { Hello = hello; Payload = payload; }

    public static AuthChallenge Decode(byte[] payload)
    {
        var r = new ByteReader(payload);
        var hello = AuthHello.Decode(r);
        if (!r.AtEnd) throw new AuthException(AuthError.Malformed);
        return new AuthChallenge(hello, payload);
    }
}

public sealed class AuthResponse
{
    public AuthHello Hello { get; }
    /// <summary>The payload without its trailing signature.</summary>
    public byte[] Body { get; }
    public byte[] Signature { get; }
    public byte[] Payload { get; }

    public AuthResponse(AuthHello hello, byte[] body, byte[] signature, byte[] payload)
    {
        Hello = hello;
        Body = body;
        Signature = signature;
        Payload = payload;
    }

    /// <summary>Layout only. Nothing is trusted until the keys and signature are checked.</summary>
    public static AuthResponse Decode(byte[] payload)
    {
        var r = new ByteReader(payload);
        var hello = AuthHello.Decode(r);
        if (r.Remaining != AuthWire.SignatureBytes) throw new AuthException(AuthError.Malformed);
        var signature = r.Bytes(AuthWire.SignatureBytes);
        if (signature is null) throw new AuthException(AuthError.Malformed);
        return new AuthResponse(hello, Wire.Slice(payload, 0, payload.Length - AuthWire.SignatureBytes),
            signature, payload);
    }
}

public sealed class AuthResult
{
    public AuthStatus Status { get; }
    public IReadOnlyList<AuthExtension> Extensions { get; }
    public byte[] Body { get; }
    public byte[] Signature { get; }

    public AuthResult(AuthStatus status, IReadOnlyList<AuthExtension> extensions, byte[] body, byte[] signature)
    {
        Status = status;
        Extensions = extensions;
        Body = body;
        Signature = signature;
    }

    public static byte[] MakeBody(AuthStatus status, IReadOnlyList<AuthExtension>? extensions = null)
    {
        var ext = AuthWire.EncodeExtensions(extensions ?? Array.Empty<AuthExtension>());
        return Wire.Concat(new[] { (byte)status }, Wire.U16((ushort)ext.Length), ext);
    }

    public static AuthResult Decode(byte[] payload)
    {
        var r = new ByteReader(payload);
        var raw = r.Byte();
        if (raw is null || !AuthStatusInfo.IsKnown(raw.Value)) throw new AuthException(AuthError.Malformed);
        var extLength = r.UInt16();
        if (extLength is null) throw new AuthException(AuthError.Malformed);
        var ext = r.Bytes(extLength.Value);
        if (ext is null || r.Remaining != AuthWire.SignatureBytes) throw new AuthException(AuthError.Malformed);
        var signature = r.Bytes(AuthWire.SignatureBytes);
        if (signature is null) throw new AuthException(AuthError.Malformed);
        return new AuthResult((AuthStatus)raw.Value, AuthWire.DecodeExtensions(ext),
            Wire.Slice(payload, 0, payload.Length - AuthWire.SignatureBytes), signature);
    }
}
