using System.Buffers.Binary;

namespace Clamshell;

// Client-side wire format for the Clamshell streaming protocol -- see
// PROTOCOL.md at the repo root. Deliberately duplicated from (not shared
// with) WindowsServer/Protocol.cs: that project is a host (WinExe + WinForms
// + Vortice DXGI/NAudio) and this one is a viewer, so keeping them
// independent avoids pulling encoder-only dependencies into the client for
// zero benefit -- same "one file per platform, bytes match on the wire"
// approach the Mac/Windows host pair already uses.
internal enum MessageType : byte
{
    Hello = 0x01,
    HelloAck = 0x02,
    ClientDisplays = 0x03,
    StreamStatus = 0x04,
    HostLockState = 0x05,
    CursorPos = 0x06,
    VideoFrame = 0x10,
    KeyframeRequest = 0x11,
    AudioFrame = 0x13,
    MouseMove = 0x20,
    MouseButton = 0x21,
    Key = 0x22,
    Scroll = 0x23,
    Clipboard = 0x30,
}

internal enum StreamCodec : byte
{
    H264 = 1,
    Hevc = 2,
}

internal static class Proto
{
    public const byte Version = 1;

    private static byte[] Frame(MessageType type, ReadOnlySpan<byte> payload)
    {
        var buf = new byte[5 + payload.Length];
        buf[0] = (byte)type;
        BinaryPrimitives.WriteUInt32BigEndian(buf.AsSpan(1, 4), (uint)payload.Length);
        payload.CopyTo(buf.AsSpan(5));
        return buf;
    }

    /// <summary>HELLO. Trailing client-display bytes (PROTOCOL.md "Client display
    /// reporting") are skipped -- ponytail: a floating desktop window has no
    /// second-surface concept to report; add if a future feature needs it.</summary>
    public static byte[] Hello(StreamCodec requestedCodec)
    {
        Span<byte> p = stackalloc byte[2];
        p[0] = Version;
        p[1] = (byte)requestedCodec;
        return Frame(MessageType.Hello, p);
    }

    public static byte[] KeyframeRequest() => Frame(MessageType.KeyframeRequest, ReadOnlySpan<byte>.Empty);

    public static byte[] MouseMove(float x, float y)
    {
        Span<byte> p = stackalloc byte[8];
        WriteF32(p, 0, x); WriteF32(p, 4, y);
        return Frame(MessageType.MouseMove, p);
    }

    public static byte[] MouseButton(byte button, bool down, float x, float y)
    {
        Span<byte> p = stackalloc byte[10];
        p[0] = button; p[1] = down ? (byte)1 : (byte)0;
        WriteF32(p, 2, x); WriteF32(p, 6, y);
        return Frame(MessageType.MouseButton, p);
    }

    public static byte[] Key(ushort macKeyCode, bool down, ulong cgEventFlags)
    {
        Span<byte> p = stackalloc byte[11];
        BinaryPrimitives.WriteUInt16BigEndian(p.Slice(0, 2), macKeyCode);
        p[2] = down ? (byte)1 : (byte)0;
        BinaryPrimitives.WriteUInt64BigEndian(p.Slice(3, 8), cgEventFlags);
        return Frame(MessageType.Key, p);
    }

    public static byte[] Scroll(float dx, float dy)
    {
        Span<byte> p = stackalloc byte[8];
        WriteF32(p, 0, dx); WriteF32(p, 4, dy);
        return Frame(MessageType.Scroll, p);
    }

    private static void WriteF32(Span<byte> p, int off, float v) =>
        BinaryPrimitives.WriteInt32BigEndian(p.Slice(off, 4), BitConverter.SingleToInt32Bits(v));
}

internal static class Be
{
    public static ushort U16(ReadOnlySpan<byte> p, int off) => BinaryPrimitives.ReadUInt16BigEndian(p.Slice(off, 2));
    public static uint U32(ReadOnlySpan<byte> p, int off) => BinaryPrimitives.ReadUInt32BigEndian(p.Slice(off, 4));
    public static ulong U64(ReadOnlySpan<byte> p, int off) => BinaryPrimitives.ReadUInt64BigEndian(p.Slice(off, 8));
    public static float F32(ReadOnlySpan<byte> p, int off) =>
        BitConverter.Int32BitsToSingle((int)BinaryPrimitives.ReadUInt32BigEndian(p.Slice(off, 4)));
}
