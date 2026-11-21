using System.IO;
using System.Globalization;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;

namespace Clamshell.Auth;

public enum AuthStatus : byte
{
    Accepted = 0,
    Pending = 1,
    Denied = 2,
    Invalid = 3,
    Busy = 4,
    Timeout = 5,
}

public static class AuthStatusInfo
{
    /// <summary>After any other status the host closes the connection.</summary>
    public static bool KeepsConnection(AuthStatus s) => s == AuthStatus.Accepted || s == AuthStatus.Pending;

    /// <summary>The host may never have seen a response for these, so their
    /// signature always covers an empty one.</summary>
    public static bool SignsEmptyResponse(AuthStatus s) => s == AuthStatus.Busy || s == AuthStatus.Timeout;

    public static bool IsKnown(byte raw) => raw <= (byte)AuthStatus.Timeout;
}

public enum AuthError
{
    Malformed,
    UnsupportedVersion,
    InvalidKey,
    BadSignature,
    CounterExhausted,
    DecryptFailed,
    /// <summary>The decrypted message was itself SECURE or one of the AUTH messages.</summary>
    ForbiddenInnerMessage,
}

public sealed class AuthException : Exception
{
    public AuthError Error { get; }
    public AuthException(AuthError error) : base(error.ToString()) { Error = error; }
}

/// <summary>One <c>type(1) len(2 BE) value</c> record. Version 1 defines none.</summary>
public sealed class AuthExtension
{
    public byte Type { get; }
    public byte[] Value { get; }
    public AuthExtension(byte type, byte[] value) { Type = type; Value = value; }
}

/// <summary>Why a host said busy: extension type 0x02 of AUTH_RESULT, one byte.
/// An unknown type or value is plain busy.</summary>
public enum HostBusyReason : byte
{
    None = 0,
    /// <summary>The Mac needs someone to approve Clamshell's Keychain access.</summary>
    Keychain = 1,
    /// <summary>Remote access is switched off on that Mac.</summary>
    RemoteAccessOff = 2,
}

public static class HostBusyReasons
{
    public const byte ExtensionType = 0x02;

    public static AuthExtension ToExtension(HostBusyReason reason) => new(ExtensionType, new[] { (byte)reason });

    public static HostBusyReason Find(IReadOnlyList<AuthExtension> extensions)
    {
        foreach (var e in extensions)
        {
            if (e.Type != ExtensionType || e.Value.Length != 1) continue;
            return e.Value[0] switch
            {
                (byte)HostBusyReason.Keychain => HostBusyReason.Keychain,
                (byte)HostBusyReason.RemoteAccessOff => HostBusyReason.RemoteAccessOff,
                _ => HostBusyReason.None,
            };
        }
        return HostBusyReason.None;
    }
}

/// <summary>Reads fields off the front of a payload, refusing to run past its end.</summary>
public sealed class ByteReader
{
    private readonly byte[] _data;
    private int _offset;

    public ByteReader(byte[] data) { _data = data; }

    public int Remaining => _data.Length - _offset;
    public bool AtEnd => Remaining == 0;

    public byte? Byte()
    {
        if (Remaining < 1) return null;
        return _data[_offset++];
    }

    public byte[]? Bytes(int count)
    {
        if (count < 0 || Remaining < count) return null;
        var r = new byte[count];
        Buffer.BlockCopy(_data, _offset, r, 0, count);
        _offset += count;
        return r;
    }

    public ushort? UInt16()
    {
        var b = Bytes(2);
        if (b is null) return null;
        return (ushort)((b[0] << 8) | b[1]);
    }

    public uint? UInt32()
    {
        var b = Bytes(4);
        if (b is null) return null;
        return Wire.ReadU32(b, 0);
    }
}

public static class AuthWire
{
    public const byte Version = 1;
    public const int KeyBytes = 65;
    public const int NonceBytes = 32;
    public const int SignatureBytes = 64;
    public const int MaxNameBytes = 64;
    public const int TagBytes = 16;
    /// <summary>The largest AUTH_RESPONSE payload a host reads.</summary>
    public const int MaxResponseBytes = 4096;
    /// <summary>A side closes the connection before its counter could pass this.</summary>
    public const ulong CounterLimit = 1UL << 48;

    public static readonly byte[] ClientContext = Wire.Concat(Encoding.UTF8.GetBytes("clamshell-auth-v1/client"), new byte[] { 0 });
    public static readonly byte[] HostContext = Wire.Concat(Encoding.UTF8.GetBytes("clamshell-auth-v1/host"), new byte[] { 0 });
    public static readonly byte[] SessionInfo = Encoding.UTF8.GetBytes("clamshell-session-v1");

    /// <summary><c>L(x)</c>: the 4-byte big-endian length of x, then x.</summary>
    public static byte[] Prefixed(byte[] x) => Wire.Concat(Wire.U32((uint)x.Length), x);

    public static byte[] ClientSignatureInput(byte[] challenge, byte[] responseBody) =>
        Wire.Concat(ClientContext, Prefixed(challenge), Prefixed(responseBody));

    public static byte[] HostSignatureInput(byte[] challenge, byte[] response, byte[] resultBody) =>
        Wire.Concat(HostContext, Prefixed(challenge), Prefixed(response), Prefixed(resultBody));

    public static byte[] TranscriptHash(byte[] challenge, byte[] response) =>
        SHA256.HashData(Wire.Concat(Prefixed(challenge), Prefixed(response)));

    public static byte[] RandomBytes(int count) => RandomNumberGenerator.GetBytes(count);

    public static byte[] EncodeExtensions(IReadOnlyList<AuthExtension> list)
    {
        using var ms = new MemoryStream();
        foreach (var e in list)
        {
            if (e.Value.Length > ushort.MaxValue) throw new AuthException(AuthError.Malformed);
            ms.WriteByte(e.Type);
            ms.Write(Wire.U16((ushort)e.Value.Length));
            ms.Write(e.Value);
        }
        if (ms.Length > ushort.MaxValue) throw new AuthException(AuthError.Malformed);
        return ms.ToArray();
    }

    /// <summary>Records fill the block exactly: one that runs past the end makes
    /// the whole message malformed. Unknown types are kept for the caller to skip.</summary>
    public static List<AuthExtension> DecodeExtensions(byte[] block)
    {
        var result = new List<AuthExtension>();
        var r = new ByteReader(block);
        while (!r.AtEnd)
        {
            var type = r.Byte();
            var length = r.UInt16();
            if (type is null || length is null) throw new AuthException(AuthError.Malformed);
            var value = r.Bytes(length.Value);
            if (value is null) throw new AuthException(AuthError.Malformed);
            result.Add(new AuthExtension(type.Value, value));
        }
        return result;
    }

    /// <summary>A name as it is shown: no control characters, no invisible
    /// formatting characters (the bidirectional overrides among them), no space
    /// at either end, and at most 64 bytes of UTF-8 without splitting a character.</summary>
    public static string CleanName(string raw)
    {
        var kept = new List<Rune>();
        foreach (var r in raw.EnumerateRunes())
        {
            switch (Rune.GetUnicodeCategory(r))
            {
                case UnicodeCategory.Control:
                case UnicodeCategory.Format:
                case UnicodeCategory.LineSeparator:
                case UnicodeCategory.ParagraphSeparator:
                case UnicodeCategory.Surrogate:
                case UnicodeCategory.OtherNotAssigned:
                case UnicodeCategory.PrivateUse:
                    continue;
                default:
                    kept.Add(r);
                    break;
            }
        }
        TrimSpaces(kept);
        var limited = new List<Rune>();
        int bytes = 0;
        foreach (var r in kept)
        {
            int n = r.Utf8SequenceLength;
            if (bytes + n > MaxNameBytes) break;
            bytes += n;
            limited.Add(r);
        }
        TrimSpaces(limited);
        var sb = new StringBuilder();
        foreach (var r in limited) sb.Append(r.ToString());
        return sb.ToString();
    }

    private static bool IsTrimmable(Rune r) =>
        r.Value == 0x09 || Rune.GetUnicodeCategory(r) == UnicodeCategory.SpaceSeparator;

    private static void TrimSpaces(List<Rune> runes)
    {
        while (runes.Count > 0 && IsTrimmable(runes[runes.Count - 1])) runes.RemoveAt(runes.Count - 1);
        int lead = 0;
        while (lead < runes.Count && IsTrimmable(runes[lead])) lead++;
        if (lead > 0) runes.RemoveRange(0, lead);
    }
}

public static class Hex
{
    public static string Encode(byte[] bytes) => Convert.ToHexString(bytes).ToLowerInvariant();

    /// <summary>null unless the text is an even number of hex digits and nothing else.</summary>
    public static byte[]? Decode(string text)
    {
        if (text.Length % 2 != 0) return null;
        try { return Convert.FromHexString(text); }
        catch (FormatException) { return null; }
    }
}

/// <summary>P-256 point handling that behaves the same on every platform.</summary>
public static class P256Util
{
    private static readonly BigInteger Prime = BigInteger.Parse(
        "0" + "FFFFFFFF" + "00000001" + "00000000" + "00000000" + "00000000" + "FFFFFFFF" + "FFFFFFFF" + "FFFFFFFF",
        NumberStyles.HexNumber, CultureInfo.InvariantCulture);

    private static readonly BigInteger CurveB = BigInteger.Parse(
        "0" + "5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B",
        NumberStyles.HexNumber, CultureInfo.InvariantCulture);

    private static BigInteger Mod(BigInteger v)
    {
        var r = BigInteger.Remainder(v, Prime);
        return r.Sign < 0 ? r + Prime : r;
    }

    /// <summary>A 65-byte uncompressed point (0x04 X Y) that is on the curve.</summary>
    public static bool IsOnCurve(byte[] key)
    {
        if (key.Length != AuthWire.KeyBytes || key[0] != 0x04) return false;
        var x = new BigInteger(key.AsSpan(1, 32), isUnsigned: true, isBigEndian: true);
        var y = new BigInteger(key.AsSpan(33, 32), isUnsigned: true, isBigEndian: true);
        if (x >= Prime || y >= Prime) return false;
        var lhs = Mod(y * y);
        var rhs = Mod(x * x * x - 3 * x + CurveB);
        return lhs == rhs;
    }

    public static ECParameters PublicParameters(byte[] key)
    {
        return new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            Q = new ECPoint { X = Wire.Slice(key, 1, 32), Y = Wire.Slice(key, 33, 32) },
        };
    }

    private static byte[] Pad32(byte[]? v)
    {
        if (v is null || v.Length > 32) throw new CryptographicException("bad coordinate");
        var r = new byte[32];
        Buffer.BlockCopy(v, 0, r, 32 - v.Length, v.Length);
        return r;
    }

    /// <summary>0x04 X Y, each coordinate left-padded to 32 bytes.</summary>
    public static byte[] ExportPublic(ECParameters p) =>
        Wire.Concat(new byte[] { 0x04 }, Pad32(p.Q.X), Pad32(p.Q.Y));
}

public static class DeviceIdentity
{
    /// <summary>Lowercase hex SHA-256 of the 65-byte public key.</summary>
    public static string Id(byte[] publicKey) => Hex.Encode(SHA256.HashData(publicKey));

    /// <summary>True for text that has the shape of a device id: 64 lowercase hex digits.</summary>
    public static bool IsWellFormedId(string text)
    {
        if (text.Length != 64) return false;
        foreach (var c in text)
        {
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
        }
        return true;
    }

    /// <summary><c>AB12-CD34-EF56-7890</c>: the first 16 characters of an id,
    /// upper case, in fours. This is what people compare.</summary>
    public static string Fingerprint(string id)
    {
        var head = id.ToUpperInvariant();
        if (head.Length > 16) head = head.Substring(0, 16);
        var parts = new List<string>();
        for (int i = 0; i < head.Length; i += 4)
        {
            parts.Add(head.Substring(i, Math.Min(4, head.Length - i)));
        }
        return string.Join("-", parts);
    }

    public static string FingerprintOfKey(byte[] publicKey) => Fingerprint(Id(publicKey));

    /// <summary>A 65-byte uncompressed point (0x04 X Y) that is on the curve.</summary>
    public static bool IsValidPublicKey(byte[] key)
    {
        if (key.Length != AuthWire.KeyBytes || key[0] != 0x04) return false;
        if (!P256Util.IsOnCurve(key)) return false;
        try
        {
            using var e = ECDsa.Create(P256Util.PublicParameters(key));
            return true;
        }
        catch (CryptographicException) { return false; }
        catch (ArgumentException) { return false; }
    }
}

/// <summary>Signs with a long-term key: 64 raw bytes r then s, ECDSA over
/// SHA-256 of the input.</summary>
public delegate byte[] AuthSigner(byte[] input);

public static class AuthSignature
{
    public static bool Verify(byte[] signature, byte[] input, byte[] publicKey)
    {
        if (signature.Length != AuthWire.SignatureBytes || !DeviceIdentity.IsValidPublicKey(publicKey)) return false;
        try
        {
            using var key = ECDsa.Create(P256Util.PublicParameters(publicKey));
            return key.VerifyData(input, signature, HashAlgorithmName.SHA256,
                DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
        }
        catch (CryptographicException) { return false; }
    }

    public static byte[] Sign(ECDsa key, byte[] input) =>
        key.SignData(input, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);

    public static AuthSigner Signer(ECDsa key) => input => Sign(key, input);
}
