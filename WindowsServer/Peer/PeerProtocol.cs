using System.Buffers.Binary;
using System.Globalization;
using System.Text;

namespace Clamshell;

// Peer link wire messages (PROTOCOL.md "Peer link") — byte-for-byte the same
// layout as Sources/Clamshell/Peer/PeerProtocol.swift. Framing is the usual
// [type][len BE u32][payload]; strings are u16-BE-length-prefixed UTF-8
// capped at PeerLimits.MaxName bytes. Input while controlling a peer reuses
// the v1 INPUT_* messages (0x20–0x23), text clipboard the v1 CLIPBOARD (0x30).
// PeerSelfTest.cs pins every message against the literal hex vectors the
// Swift selftest also asserts, so neither side can drift alone.

internal static class PeerLimits
{
    public const byte ProtocolVersion = 2;
    public const ushort DefaultPort = 5910;
    public const string ServiceType = "_clamshell-peer._tcp";
    public const int MaxName = 128;
    public const int MaxFileName = 255;
    public const ulong MaxFileSize = 8UL << 30;
    public const int ChunkSize = 128 << 10;
    public const int MaxClipboardBytes = 32 << 20;
    public const int NonceSize = 32;
    public const int PublicKeySize = 65;
    public const int SignatureSize = 64;
    public const int ProofSize = 32;
    /// Largest single message the parser accepts (clipboard + slack).
    public const int MaxMessage = MaxClipboardBytes + 1024;
}

/// Screen edge, from the point of view of the machine whose screen it is.
internal enum PeerEdge : byte { Left = 0, Right = 1, Top = 2, Bottom = 3 }

internal static class PeerEdgeExt
{
    public static PeerEdge Opposite(this PeerEdge e) => e switch
    {
        PeerEdge.Left => PeerEdge.Right,
        PeerEdge.Right => PeerEdge.Left,
        PeerEdge.Top => PeerEdge.Bottom,
        _ => PeerEdge.Top,
    };
    public static string Name(this PeerEdge e) => e.ToString().ToLowerInvariant();
    public static bool IsValid(byte b) => b <= 3;
}

internal enum PeerHelloStatus : byte { Ok = 0, Untrusted = 1, BadPin = 2, BadSignature = 3, Busy = 4, Version = 5 }
internal enum PeerRejectReason : byte { User = 0, Error = 1, TooLarge = 2, Disk = 3, Unsupported = 4, Busy = 5 }

internal sealed record PeerHelloPayload(byte Flags, byte[] PublicKey, byte[] ClientNonce, byte[] Signature,
    byte[]? PinProof, string Name, uint ScreenWidth, uint ScreenHeight);
internal sealed record PeerHelloAckPayload(PeerHelloStatus Status, byte[] PublicKey, byte[] Signature,
    byte[]? PinProof, string Name, uint ScreenWidth, uint ScreenHeight);
internal readonly record struct EdgeEnterPayload(PeerEdge Edge, float X, float Y, bool LeftButtonDown);
internal sealed record HandoffBeginPayload(uint WindowId, PeerEdge Edge, float Position, float GrabX, float GrabY,
    uint Width, uint Height, ushort StreamPort, string Title, string AppName);
internal readonly record struct HandoffReturnPayload(uint WindowId, PeerEdge? Edge, float Position);
internal sealed record FileOfferPayload(uint TransferId, ulong Size, string Name);
internal sealed record FileChunkPayload(uint TransferId, ulong Offset, byte[] Bytes);

/// Big-endian payload builder (mirror of Data.appendBE / appendString).
internal sealed class PayloadWriter
{
    private readonly MemoryStream _ms = new();
    public PayloadWriter U8(byte v) { _ms.WriteByte(v); return this; }
    public PayloadWriter U16(ushort v) { Span<byte> b = stackalloc byte[2]; BinaryPrimitives.WriteUInt16BigEndian(b, v); _ms.Write(b); return this; }
    public PayloadWriter U32(uint v) { Span<byte> b = stackalloc byte[4]; BinaryPrimitives.WriteUInt32BigEndian(b, v); _ms.Write(b); return this; }
    public PayloadWriter U64(ulong v) { Span<byte> b = stackalloc byte[8]; BinaryPrimitives.WriteUInt64BigEndian(b, v); _ms.Write(b); return this; }
    public PayloadWriter F32(float v) => U32((uint)BitConverter.SingleToInt32Bits(v));
    public PayloadWriter Bytes(ReadOnlySpan<byte> b) { _ms.Write(b); return this; }

    /// u16-prefixed UTF-8, truncated to MaxName bytes on a whole-character
    /// (grapheme) boundary — same rule as the Swift side.
    public PayloadWriter Str(string s)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(s);
        if (bytes.Length > PeerLimits.MaxName)
        {
            var sb = new StringBuilder();
            int used = 0;
            var e = StringInfo.GetTextElementEnumerator(s);
            while (e.MoveNext())
            {
                string el = e.GetTextElement();
                int n = Encoding.UTF8.GetByteCount(el);
                if (used + n > PeerLimits.MaxName) break;
                sb.Append(el); used += n;
            }
            bytes = Encoding.UTF8.GetBytes(sb.ToString());
        }
        U16((ushort)bytes.Length);
        return Bytes(bytes);
    }

    public byte[] Frame(MessageType t) => Proto.Frame(t, _ms.ToArray());
}

internal static class PeerMsg
{
    public static byte[] Challenge(byte[] nonce) => Proto.Frame(MessageType.PeerChallenge, nonce);

    public static byte[] Hello(byte[] publicKey, byte[] clientNonce, byte[] signature, byte[]? pinProof,
                               string name, uint screenWidth, uint screenHeight)
    {
        var w = new PayloadWriter().U8(PeerLimits.ProtocolVersion).U8((byte)(pinProof is null ? 0 : 1))
            .Bytes(publicKey).Bytes(clientNonce).Bytes(signature);
        if (pinProof is not null) w.Bytes(pinProof);
        return w.Str(name).U32(screenWidth).U32(screenHeight).Frame(MessageType.PeerHello);
    }

    public static byte[] HelloAck(PeerHelloStatus status, byte[]? publicKey = null, byte[]? signature = null,
                                  byte[]? pinProof = null, string name = "", uint screenWidth = 0, uint screenHeight = 0)
    {
        var w = new PayloadWriter().U8(PeerLimits.ProtocolVersion).U8((byte)status);
        if (status == PeerHelloStatus.Ok)
        {
            w.Bytes(publicKey ?? Array.Empty<byte>()).Bytes(signature ?? Array.Empty<byte>())
             .U8((byte)(pinProof is null ? 0 : 1));
            if (pinProof is not null) w.Bytes(pinProof);
            w.Str(name).U32(screenWidth).U32(screenHeight);
        }
        return w.Frame(MessageType.PeerHelloAck);
    }

    public static byte[] EdgeEnter(PeerEdge edge, float x, float y, bool leftButtonDown) =>
        new PayloadWriter().U8((byte)edge).F32(x).F32(y).U8((byte)(leftButtonDown ? 1 : 0)).Frame(MessageType.EdgeEnter);

    public static byte[] EdgeLeave() => Proto.Frame(MessageType.EdgeLeave, ReadOnlySpan<byte>.Empty);

    public static byte[] ClipboardText(string text) => Proto.Frame(MessageType.Clipboard, Encoding.UTF8.GetBytes(text));

    /// kind 1 = PNG image.
    public static byte[] ClipboardData(byte kind, ReadOnlySpan<byte> bytes) =>
        new PayloadWriter().U8(kind).Bytes(bytes).Frame(MessageType.ClipboardData);

    public static byte[] HandoffBegin(HandoffBeginPayload h) =>
        new PayloadWriter().U32(h.WindowId).U8((byte)h.Edge).F32(h.Position).F32(h.GrabX).F32(h.GrabY)
            .U32(h.Width).U32(h.Height).U16(h.StreamPort).Str(h.Title).Str(h.AppName).Frame(MessageType.HandoffBegin);

    public static byte[] HandoffAccept(uint windowId) => new PayloadWriter().U32(windowId).Frame(MessageType.HandoffAccept);
    public static byte[] HandoffReject(uint windowId, PeerRejectReason r) =>
        new PayloadWriter().U32(windowId).U8((byte)r).Frame(MessageType.HandoffReject);
    public static byte[] HandoffReturn(uint windowId, PeerEdge? edge, float position) =>
        new PayloadWriter().U32(windowId).U8(edge is { } e ? (byte)e : (byte)0xFF).F32(position).Frame(MessageType.HandoffReturn);
    public static byte[] WindowClosed(uint windowId) => new PayloadWriter().U32(windowId).Frame(MessageType.WindowClosed);

    public static byte[] FileOffer(uint id, ulong size, string name) =>
        new PayloadWriter().U32(id).U64(size).Str(name).Frame(MessageType.FileOffer);
    public static byte[] FileAccept(uint id) => new PayloadWriter().U32(id).Frame(MessageType.FileAccept);
    public static byte[] FileReject(uint id, PeerRejectReason r) => new PayloadWriter().U32(id).U8((byte)r).Frame(MessageType.FileReject);
    public static byte[] FileChunk(uint id, ulong offset, ReadOnlySpan<byte> bytes) =>
        new PayloadWriter().U32(id).U64(offset).Bytes(bytes).Frame(MessageType.FileChunk);
    public static byte[] FileDone(uint id, byte[] sha256) => new PayloadWriter().U32(id).Bytes(sha256).Frame(MessageType.FileDone);
    public static byte[] FileCancel(uint id, PeerRejectReason r) => new PayloadWriter().U32(id).U8((byte)r).Frame(MessageType.FileCancel);

    // v1 input messages (sent by a Windows controller / receiver window).
    public static byte[] MouseMove(float x, float y) => new PayloadWriter().F32(x).F32(y).Frame(MessageType.MouseMove);
    public static byte[] MouseButton(byte button, bool down, float x, float y) =>
        new PayloadWriter().U8(button).U8((byte)(down ? 1 : 0)).F32(x).F32(y).Frame(MessageType.MouseButton);
    public static byte[] Key(ushort macKeyCode, bool down, ulong flags) =>
        new PayloadWriter().U16(macKeyCode).U8((byte)(down ? 1 : 0)).U64(flags).Frame(MessageType.Key);
    public static byte[] Scroll(float dx, float dy) => new PayloadWriter().F32(dx).F32(dy).Frame(MessageType.Scroll);

    /// v1 HELLO (a receiver window dialling a handoff's window stream).
    public static byte[] StreamHello(StreamCodec codec) =>
        Proto.Frame(MessageType.Hello, new byte[] { Proto.Version, (byte)codec });
    public static byte[] KeyframeRequest() => Proto.Frame(MessageType.KeyframeRequest, ReadOnlySpan<byte>.Empty);
}

/// Bounds-checked cursor over a payload. Every read returns false/null
/// instead of throwing when the payload is short.
internal sealed class PeerReader
{
    private readonly byte[] _d;
    private int _o;
    public PeerReader(byte[] d) { _d = d; }
    public PeerReader(ReadOnlySpan<byte> d) { _d = d.ToArray(); }
    public int Remaining => _d.Length - _o;

    public bool U8(out byte v) { v = 0; if (Remaining < 1) return false; v = _d[_o++]; return true; }
    public bool U16(out ushort v) { v = 0; if (Remaining < 2) return false; v = BinaryPrimitives.ReadUInt16BigEndian(_d.AsSpan(_o, 2)); _o += 2; return true; }
    public bool U32(out uint v) { v = 0; if (Remaining < 4) return false; v = BinaryPrimitives.ReadUInt32BigEndian(_d.AsSpan(_o, 4)); _o += 4; return true; }
    public bool U64(out ulong v) { v = 0; if (Remaining < 8) return false; v = BinaryPrimitives.ReadUInt64BigEndian(_d.AsSpan(_o, 8)); _o += 8; return true; }
    public bool F32(out float v)
    {
        v = 0;
        if (!U32(out var bits)) return false;
        v = BitConverter.Int32BitsToSingle((int)bits);
        return float.IsFinite(v);
    }
    public byte[]? Bytes(int n)
    {
        if (n < 0 || Remaining < n) return null;
        var b = _d.AsSpan(_o, n).ToArray(); _o += n; return b;
    }
    public byte[] Rest() => Bytes(Remaining) ?? Array.Empty<byte>();

    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    /// u16-prefixed UTF-8 capped at MaxName; invalid UTF-8 or control
    /// characters (U+0000–U+001F, U+007F) reject the whole message.
    public string? Str()
    {
        if (!U16(out var n) || n > PeerLimits.MaxName) return null;
        var b = Bytes(n);
        if (b is null) return null;
        string s;
        try { s = StrictUtf8.GetString(b); } catch (DecoderFallbackException) { return null; }
        foreach (var r in s.EnumerateRunes())
            if (r.Value < 0x20 || r.Value == 0x7F) return null;
        return s;
    }
}

internal static class PeerParse
{
    public static PeerHelloPayload? Hello(byte[] p)
    {
        var r = new PeerReader(p);
        if (!r.U8(out var ver) || ver != PeerLimits.ProtocolVersion || !r.U8(out var flags)) return null;
        var key = r.Bytes(PeerLimits.PublicKeySize);
        if (key is null || key[0] != 0x04) return null;
        var nonce = r.Bytes(PeerLimits.NonceSize);
        var sig = r.Bytes(PeerLimits.SignatureSize);
        if (nonce is null || sig is null) return null;
        byte[]? proof = null;
        if ((flags & 1) == 1) { proof = r.Bytes(PeerLimits.ProofSize); if (proof is null) return null; }
        var name = r.Str();
        if (name is null || !r.U32(out var w) || !r.U32(out var h)) return null;
        return new PeerHelloPayload(flags, key, nonce, sig, proof, name, w, h);
    }

    public static PeerHelloAckPayload? HelloAck(byte[] p)
    {
        var r = new PeerReader(p);
        if (!r.U8(out var ver) || ver != PeerLimits.ProtocolVersion || !r.U8(out var s) || s > 5) return null;
        var status = (PeerHelloStatus)s;
        if (status != PeerHelloStatus.Ok)
            return new PeerHelloAckPayload(status, Array.Empty<byte>(), Array.Empty<byte>(), null, "", 0, 0);
        var key = r.Bytes(PeerLimits.PublicKeySize);
        if (key is null || key[0] != 0x04) return null;
        var sig = r.Bytes(PeerLimits.SignatureSize);
        if (sig is null || !r.U8(out var hasProof)) return null;
        byte[]? proof = null;
        if (hasProof == 1) { proof = r.Bytes(PeerLimits.ProofSize); if (proof is null) return null; }
        var name = r.Str();
        if (name is null || !r.U32(out var w) || !r.U32(out var h)) return null;
        return new PeerHelloAckPayload(status, key, sig, proof, name, w, h);
    }

    public static EdgeEnterPayload? EdgeEnter(byte[] p)
    {
        var r = new PeerReader(p);
        if (!r.U8(out var e) || !PeerEdgeExt.IsValid(e) || !r.F32(out var x) || !r.F32(out var y) || !r.U8(out var down)) return null;
        return new EdgeEnterPayload((PeerEdge)e, x, y, down == 1);
    }

    public static (byte Kind, byte[] Bytes)? ClipboardData(byte[] p)
    {
        var r = new PeerReader(p);
        if (!r.U8(out var kind) || r.Remaining > PeerLimits.MaxClipboardBytes) return null;
        return (kind, r.Rest());
    }

    public static HandoffBeginPayload? HandoffBegin(byte[] p)
    {
        var r = new PeerReader(p);
        if (!r.U32(out var id) || !r.U8(out var e) || !PeerEdgeExt.IsValid(e)) return null;
        if (!r.F32(out var pos) || !r.F32(out var gx) || !r.F32(out var gy)) return null;
        if (!r.U32(out var w) || !r.U32(out var h) || w < 1 || h < 1 || w > 16384 || h > 16384) return null;
        if (!r.U16(out var port) || port == 0) return null;
        var title = r.Str(); if (title is null) return null;
        var app = r.Str(); if (app is null) return null;
        return new HandoffBeginPayload(id, (PeerEdge)e, Math.Clamp(pos, 0, 1), Math.Clamp(gx, 0, 1), Math.Clamp(gy, 0, 1),
            w, h, port, title, app);
    }

    public static uint? WindowId(byte[] p) { var r = new PeerReader(p); return r.U32(out var v) ? v : null; }

    public static (uint Id, PeerRejectReason Reason)? IdAndReason(byte[] p)
    {
        var r = new PeerReader(p);
        if (!r.U32(out var id) || !r.U8(out var b)) return null;
        return (id, b <= 5 ? (PeerRejectReason)b : PeerRejectReason.Error);
    }

    public static HandoffReturnPayload? HandoffReturn(byte[] p)
    {
        var r = new PeerReader(p);
        if (!r.U32(out var id) || !r.U8(out var e) || !r.F32(out var pos)) return null;
        if (e != 0xFF && !PeerEdgeExt.IsValid(e)) return null;
        return new HandoffReturnPayload(id, e == 0xFF ? null : (PeerEdge)e, Math.Clamp(pos, 0, 1));
    }

    public static FileOfferPayload? FileOffer(byte[] p)
    {
        var r = new PeerReader(p);
        if (!r.U32(out var id) || !r.U64(out var size)) return null;
        var name = r.Str();
        return name is null ? null : new FileOfferPayload(id, size, name);
    }

    public static FileChunkPayload? FileChunk(byte[] p)
    {
        var r = new PeerReader(p);
        if (!r.U32(out var id) || !r.U64(out var off) || r.Remaining > PeerLimits.ChunkSize) return null;
        return new FileChunkPayload(id, off, r.Rest());
    }

    public static (uint Id, byte[] Sha256)? FileDone(byte[] p)
    {
        var r = new PeerReader(p);
        if (!r.U32(out var id)) return null;
        var hash = r.Bytes(32);
        return hash is null ? null : (id, hash);
    }
}

/// Incremental [type][len][payload] splitter — WebSocket messages normally
/// carry exactly one frame, but nothing relies on it.
internal sealed class FrameParser
{
    private readonly MemoryStream _buf = new();
    public bool Corrupt { get; private set; }
    public Action<MessageType, byte[]>? OnMessage;

    public void Feed(ReadOnlySpan<byte> data)
    {
        if (Corrupt) return;
        _buf.Write(data);
        while (true)
        {
            var all = _buf.GetBuffer().AsSpan(0, (int)_buf.Length);
            if (all.Length < 5) return;
            uint len = BinaryPrimitives.ReadUInt32BigEndian(all.Slice(1, 4));
            if (len > PeerLimits.MaxMessage) { Corrupt = true; return; }
            if (all.Length < 5 + (int)len) return;
            var type = (MessageType)all[0];
            var payload = all.Slice(5, (int)len).ToArray();
            var rest = all.Slice(5 + (int)len).ToArray();
            _buf.SetLength(0);
            _buf.Write(rest);
            OnMessage?.Invoke(type, payload);
        }
    }
}

/// Receiver-side file name sanitization — same rules and results as
/// PeerFileNames in Swift (both selftests run the same table).
internal static class PeerFileNames
{
    private static readonly HashSet<string> Reserved = new(StringComparer.Ordinal)
    {
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    public static string Sanitize(string raw)
    {
        string name = raw;
        int slash = name.LastIndexOfAny(new[] { '/', '\\' });
        if (slash >= 0) name = name[(slash + 1)..];
        var sb = new StringBuilder();
        foreach (var r in name.EnumerateRunes())
        {
            int v = r.Value;
            if (v < 0x20 || v == 0x7F || v == ':' || v == '*' || v == '?' || v == '"' || v == '<' || v == '>' || v == '|')
                sb.Append('_');
            else sb.Append(r.ToString());
        }
        name = TrimSpaces(sb.ToString());
        name = name.TrimStart('.');
        name = name.TrimEnd('.', ' ');
        int dot = name.IndexOf('.');
        string stem = (dot >= 0 ? name[..dot] : name).ToUpperInvariant();
        if (Reserved.Contains(stem)) name = "_" + name;
        if (Encoding.UTF8.GetByteCount(name) > PeerLimits.MaxFileName)
        {
            string ext = Path.GetExtension(name).TrimStart('.');
            string stemPart = ext.Length == 0 ? name : name[..^(ext.Length + 1)];
            int room = PeerLimits.MaxFileName - (ext.Length == 0 ? 0 : Encoding.UTF8.GetByteCount(ext) + 1);
            var e = StringInfo.GetTextElementEnumerator(stemPart);
            var keep = new StringBuilder();
            int used = 0;
            while (e.MoveNext())
            {
                string el = e.GetTextElement();
                int n = Encoding.UTF8.GetByteCount(el);
                if (used + n > Math.Max(room, 1)) break;
                keep.Append(el); used += n;
            }
            name = ext.Length == 0 ? keep.ToString() : keep + "." + ext;
        }
        if (name.Length == 0) name = "clamshell-transfer";
        return name;
    }

    // Swift's .whitespaces: Unicode space separators (Zs) and tab.
    private static bool IsSpace(char c) => c == '\t' || char.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;
    private static string TrimSpaces(string s)
    {
        int a = 0, b = s.Length;
        while (a < b && IsSpace(s[a])) a++;
        while (b > a && IsSpace(s[b - 1])) b--;
        return s[a..b];
    }

    /// "name.ext" → "name (2).ext" … until nothing exists at that path.
    public static string UniquePath(string dir, string name)
    {
        string candidate = Path.Combine(dir, name);
        string ext = Path.GetExtension(name);
        string stem = ext.Length == 0 ? name : name[..^ext.Length];
        for (int n = 2; File.Exists(candidate) || Directory.Exists(candidate); n++)
            candidate = Path.Combine(dir, $"{stem} ({n}){ext}");
        return candidate;
    }
}
