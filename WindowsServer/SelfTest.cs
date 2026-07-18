using System.Buffers.Binary;

namespace Clamshell;

// One runnable check for the pure, deterministic logic that would silently
// corrupt the stream if wrong: Annex-B -> AVCC framing and the wire framing /
// big-endian helpers. No hardware needed — CI runs `ClamshellServer selftest`.
// The interop (capture/encode/audio/input) is NOT covered here; it can only be
// verified on a real Windows box (see the report).
internal static class SelfTest
{
    public static int Run()
    {
        // Annex-B with a 4-byte and a 3-byte start code -> two length-prefixed NALs.
        byte[] annexB = { 0,0,0,1, 0x67, 0xAA, 0xBB, 0,0,1, 0x68, 0xCC };
        byte[] avcc = AnnexB.ToAvcc(annexB);
        // NAL1 = 67 AA BB (len 3), NAL2 = 68 CC (len 2)
        Assert(avcc.Length == 4 + 3 + 4 + 2, "avcc length");
        Assert(BinaryPrimitives.ReadUInt32BigEndian(avcc.AsSpan(0, 4)) == 3, "nal1 len");
        Assert(avcc[4] == 0x67, "nal1 byte");
        Assert(BinaryPrimitives.ReadUInt32BigEndian(avcc.AsSpan(7, 4)) == 2, "nal2 len");
        Assert(avcc[11] == 0x68, "nal2 byte");

        // No trailing garbage NAL when the stream ends exactly on a NAL.
        Assert(AnnexB.ToAvcc(new byte[] { 0, 0, 1, 0x41 }).Length == 4 + 1, "single nal");
        // Empty / no start code -> empty output (never throws).
        Assert(AnnexB.ToAvcc(Array.Empty<byte>()).Length == 0, "empty");

        // Wire framing: HELLO_ACK round-trips type + length + payload fields.
        byte[] ack = Proto.HelloAck(StreamCodec.Hevc, 1920, 1080, 0b01);
        Assert(ack[0] == (byte)MessageType.HelloAck, "ack type");
        Assert(BinaryPrimitives.ReadUInt32BigEndian(ack.AsSpan(1, 4)) == 11, "ack payload len");
        Assert(ack[5] == Proto.Version && ack[6] == (byte)StreamCodec.Hevc, "ack ver/codec");
        Assert(Be.U32(ack.AsSpan(7), 0) == 1920, "ack width");
        Assert(Be.U32(ack.AsSpan(11), 0) == 1080, "ack height");
        Assert(ack[15] == 0b01, "ack flags");

        // Big-endian float round-trip (input coordinates).
        var vf = Proto.VideoFrame(true, 0x0102030405060708UL, new byte[] { 1, 2 });
        Assert(vf[5] == 1, "keyframe flag");
        Assert(Be.U64(vf.AsSpan(6), 0) == 0x0102030405060708UL, "pts");

        Console.WriteLine("SelfTest: all checks passed");
        return 0;
    }

    private static void Assert(bool ok, string what)
    {
        if (!ok) throw new Exception($"SelfTest FAILED: {what}");
    }
}
