using System.Buffers.Binary;

namespace Clamshell;

// Wire format for the Clamshell streaming protocol — see PROTOCOL.md at the
// repo root. This is a C# port of the Mac's StreamProtocol.swift; the bytes on
// the wire are byte-for-byte identical so the existing iOS clients connect to a
// Windows host with zero changes.

internal enum MessageType : byte
{
    Hello = 0x01,
    HelloAck = 0x02,
    ClientDisplays = 0x03,
    StreamStatus = 0x04,
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
    public const ushort DefaultPort = 5903;

    // MARK: - Message construction (big-endian, matches Data.appendBE in Swift)

    private static byte[] Frame(MessageType type, ReadOnlySpan<byte> payload)
    {
        var buf = new byte[5 + payload.Length];
        buf[0] = (byte)type;
        BinaryPrimitives.WriteUInt32BigEndian(buf.AsSpan(1, 4), (uint)payload.Length);
        payload.CopyTo(buf.AsSpan(5));
        return buf;
    }

    /// <summary>HELLO_ACK. <paramref name="flags"/> bit 0 = "no software-encoding
    /// warning" (set for genuine hardware AND for the expected no-hardware-present
    /// case; cleared only on a real hardware fallback). See EncoderStatus.</summary>
    public static byte[] HelloAck(StreamCodec codec, uint width, uint height, byte flags)
    {
        var p = new byte[9];
        p[0] = Version;
        p[1] = (byte)codec;
        BinaryPrimitives.WriteUInt32BigEndian(p.AsSpan(2, 4), width);
        BinaryPrimitives.WriteUInt32BigEndian(p.AsSpan(6, 4), height);
        p[8] = flags;
        return Frame(MessageType.HelloAck, p);
    }

    /// <summary>VIDEO_FRAME. flags bit 0 = keyframe. nalData is AVCC
    /// ([4-byte BE length][NAL])*.</summary>
    public static byte[] VideoFrame(bool keyframe, ulong ptsMicros, ReadOnlySpan<byte> nalData)
    {
        var p = new byte[9 + nalData.Length];
        p[0] = keyframe ? (byte)1 : (byte)0;
        BinaryPrimitives.WriteUInt64BigEndian(p.AsSpan(1, 8), ptsMicros);
        nalData.CopyTo(p.AsSpan(9));
        return Frame(MessageType.VideoFrame, p);
    }

    public static byte[] AudioFrame(ReadOnlySpan<byte> aac) => Frame(MessageType.AudioFrame, aac);

    /// <summary>STREAM_STATUS: current encoder target in kbps.</summary>
    public static byte[] StreamStatus(ushort bitrateKbps)
    {
        Span<byte> p = stackalloc byte[2];
        BinaryPrimitives.WriteUInt16BigEndian(p, bitrateKbps);
        return Frame(MessageType.StreamStatus, p);
    }

    public static byte[] Clipboard(string text) =>
        Frame(MessageType.Clipboard, System.Text.Encoding.UTF8.GetBytes(text));
}

// MARK: - Big-endian readers over a payload span (mirrors Data.beUInt* helpers)

internal static class Be
{
    public static ushort U16(ReadOnlySpan<byte> p, int off) => BinaryPrimitives.ReadUInt16BigEndian(p.Slice(off, 2));
    public static uint U32(ReadOnlySpan<byte> p, int off) => BinaryPrimitives.ReadUInt32BigEndian(p.Slice(off, 4));
    public static ulong U64(ReadOnlySpan<byte> p, int off) => BinaryPrimitives.ReadUInt64BigEndian(p.Slice(off, 8));
    public static float F32(ReadOnlySpan<byte> p, int off) =>
        BitConverter.Int32BitsToSingle((int)BinaryPrimitives.ReadUInt32BigEndian(p.Slice(off, 4)));
}
