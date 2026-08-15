using System.Buffers.Binary;
using System.IO;

namespace Clamshell;

// Clamshell Windows viewer. Connects to a host's window-stream (or
// display-stream) WebSocket endpoint, decodes, renders as a native window.
//
// Usage:
//   ClamshellWindowViewer <host> <port> [codec]      GUI mode (default)
//   ClamshellWindowViewer --verify <host> <port> [codec] [timeoutSec]
//                                                     headless CI verification
//                                                     -- see the report for
//                                                     what this proves and
//                                                     .github/workflows/windows-ci.yml
//   ClamshellWindowViewer decode-file <path> [codec]  decode a real Annex-B
//                                                     elementary stream file
//                                                     directly (no network)
//   ClamshellWindowViewer selftest                    pure protocol-logic checks
internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "selftest") return SelfTest.Run();
        if (args.Length > 0 && args[0] == "--verify") return VerifyMain(args[1..]);
        if (args.Length > 0 && args[0] == "decode-file") return DecodeFileMain(args[1..]);

        if (args.Length < 2)
        {
            Console.Error.WriteLine("Usage: ClamshellWindowViewer <host> <port> [h264|hevc]");
            return 1;
        }
        string host = args[0];
        int port = int.Parse(args[1]);
        StreamCodec codec = args.Length > 2 && args[2].Equals("hevc", StringComparison.OrdinalIgnoreCase)
            ? StreamCodec.Hevc : StreamCodec.H264;

        var app = new System.Windows.Application();
        var window = new MainWindow();
        window.Start(host, port, codec);
        window.Show();
        app.Run(window);
        return 0;
    }

    /// <summary>Headless end-to-end verification: real WebSocket connect, real
    /// HELLO/HELLO_ACK, real VIDEO_FRAME decode via VideoDecoder -- no WPF
    /// window, no Dispatcher, so it runs cleanly in a CI job with no
    /// interactive session pump. Exits 0 only after a decoded frame with
    /// non-degenerate pixel content (not all-black/all-uniform, which would
    /// indicate the decoder silently produced garbage/empty output) is
    /// received, proving real decode -- not just "the connection didn't
    /// throw".</summary>
    private static int VerifyMain(string[] args)
    {
        if (args.Length < 2)
        {
            Console.Error.WriteLine("Usage: ClamshellWindowViewer --verify <host> <port> [h264|hevc] [timeoutSec]");
            return 1;
        }
        string host = args[0];
        int port = int.Parse(args[1]);
        StreamCodec codec = args.Length > 2 && args[2].Equals("hevc", StringComparison.OrdinalIgnoreCase)
            ? StreamCodec.Hevc : StreamCodec.H264;
        int timeoutSec = args.Length > 3 ? int.Parse(args[3]) : 20;

        using var client = new ViewerClient();
        var done = new TaskCompletionSource<bool>();
        int frameCount = 0;
        string failReason = "timed out waiting for a decoded frame";

        client.OnHelloAck = (c, w, h) => Log.Line($"verify: HELLO_ACK codec={c} {w}x{h}");
        client.OnDisconnected = reason => { Log.Line($"verify: disconnected ({reason})"); done.TrySetResult(false); };
        client.OnFrame = (w, h, bgra) =>
        {
            frameCount++;
            if (w <= 0 || h <= 0 || bgra.Length < w * h * 4) return;
            if (frameCount < 3) return; // let a couple of frames warm up past the first keyframe
            if (!IsDegenerate(bgra))
            {
                Log.Line($"verify: decoded real frame #{frameCount}, {w}x{h}, non-uniform pixel content");
                done.TrySetResult(true);
                return;
            }
            failReason = $"frame #{frameCount} decoded but pixel content is uniform (likely garbage/empty)";
        };

        try
        {
            client.ConnectAsync(host, port, codec).GetAwaiter().GetResult();
        }
        catch (Exception e)
        {
            Log.Line($"verify: connect failed: {e.Message}");
            return 1;
        }

        bool ok = Task.WhenAny(done.Task, Task.Delay(TimeSpan.FromSeconds(timeoutSec)))
            .GetAwaiter().GetResult() == done.Task && done.Task.Result;

        if (!ok)
        {
            Log.Line($"verify: FAIL -- {failReason} (frames seen: {frameCount})");
            return 1;
        }
        Log.Line("verify: PASS");
        return 0;
    }

    /// <summary>Decodes a real Annex-B H.264/HEVC elementary stream file
    /// (e.g. one produced by `ffmpeg -f h264 out.h264`, a single-keyframe
    /// clip) directly through VideoDecoder -- no network, no host. This
    /// exists because the *live* --verify path above depends on
    /// WindowsServer's video encoder actually starting, which (see the
    /// report) does not currently succeed on the GitHub Actions
    /// windows-latest runner; this path proves the viewer's own decode
    /// pipeline against a real H.264 stream from an independent, known-good
    /// encoder, independent of that host-side issue. See
    /// .github/workflows/windows-ci.yml for how the test file is
    /// generated.</summary>
    private static int DecodeFileMain(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("Usage: ClamshellWindowViewer decode-file <path.h264> [h264|hevc]");
            return 1;
        }
        string path = args[0];
        StreamCodec codec = args.Length > 1 && args[1].Equals("hevc", StringComparison.OrdinalIgnoreCase)
            ? StreamCodec.Hevc : StreamCodec.H264;

        byte[] annexB;
        try { annexB = File.ReadAllBytes(path); }
        catch (Exception e) { Log.Line($"decode-file: could not read {path}: {e.Message}"); return 1; }

        bool got = false;
        string reason = "no frame decoded";
        using var decoder = new VideoDecoder(codec);
        decoder.OnFrame = (w, h, bgra) =>
        {
            if (w <= 0 || h <= 0 || bgra.Length < w * h * 4) { reason = "decoded frame has bad dimensions"; return; }
            if (IsDegenerate(bgra)) { reason = "decoded frame is uniform (likely garbage/empty)"; return; }
            Log.Line($"decode-file: decoded real frame {w}x{h}, non-uniform pixel content");
            got = true;
        };

        // The whole file is fed as one access unit (SPS+PPS+IDR, all
        // Annex-B start-code delimited) -- the CI job generates a
        // single-frame file specifically so this is valid. Flush() forces
        // out any frame the decoder is holding back for reordering, which
        // a single feed+drain isn't guaranteed to do on its own.
        decoder.FeedAnnexB(annexB, 0);
        decoder.Flush();

        if (!got) { Log.Line($"decode-file: FAIL -- {reason}"); return 1; }
        Log.Line("decode-file: PASS");
        return 0;
    }

    // Cheap heuristic: sample a spread of pixels and check they aren't all
    // identical. A real desktop capture (even a mostly-blank one, per the CI
    // job's "launch Notepad first" step) has window chrome/text/edges, so a
    // successful decode should show variation; a decoder that silently
    // produced a zeroed/garbage buffer would not.
    private static bool IsDegenerate(byte[] bgra)
    {
        if (bgra.Length < 4) return true;
        byte b0 = bgra[0], g0 = bgra[1], r0 = bgra[2];
        int step = Math.Max(4, (bgra.Length / 4 / 200) * 4); // ~200 samples
        for (int i = 4; i + 2 < bgra.Length; i += step)
        {
            if (bgra[i] != b0 || bgra[i + 1] != g0 || bgra[i + 2] != r0) return false;
        }
        return true;
    }
}

// Pure, deterministic logic checks -- no network/decoder hardware needed.
// Mirrors WindowsServer/SelfTest.cs's shape and coverage on the client side:
// wire framing plus the AVCC<->Annex-B round trip this project owns.
internal static class SelfTest
{
    public static int Run()
    {
        byte[] annexB = { 0, 0, 0, 1, 0x67, 0xAA, 0xBB, 0, 0, 1, 0x68, 0xCC };
        byte[] avcc = BuildTestAvcc(annexB);
        byte[] roundTripped = Avcc.ToAnnexB(avcc);
        // A 4-byte length prefix becomes a 4-byte start code -- length-for-length,
        // so roundTripped is always exactly avcc.Length (not annexB.Length, which
        // had a 3-byte start code that ToAnnexB always normalizes to 4).
        Assert(roundTripped.Length == avcc.Length, "annexb round-trip length");
        Assert(roundTripped[4] == 0x67 && roundTripped[roundTripped.Length - 2] == 0x68, "annexb round-trip content");

        Assert(Avcc.ToAnnexB(Array.Empty<byte>()).Length == 0, "empty avcc");
        Assert(Avcc.ToAnnexB(new byte[] { 0, 0, 0 }).Length == 0, "truncated length prefix -- no throw");

        byte[] hello = Proto.Hello(StreamCodec.Hevc);
        Assert(hello[0] == (byte)MessageType.Hello, "hello type");
        Assert(BinaryPrimitives.ReadUInt32BigEndian(hello.AsSpan(1, 4)) == 2, "hello payload len");
        Assert(hello[5] == Proto.Version && hello[6] == (byte)StreamCodec.Hevc, "hello ver/codec");

        byte[] move = Proto.MouseMove(0.25f, 0.75f);
        Assert(Be.F32(move.AsSpan(5), 0) == 0.25f && Be.F32(move.AsSpan(5), 4) == 0.75f, "mousemove coords");

        Console.WriteLine("SelfTest: all checks passed");
        return 0;
    }

    // Builds an AVCC blob for the round-trip test without depending on the
    // host's AnnexB.ToAvcc (different project) -- hand-encoded to match this
    // test's fixed input.
    private static byte[] BuildTestAvcc(byte[] annexB)
    {
        // annexB above is exactly: [4-byte SC][67 AA BB][3-byte SC][68 CC]
        var ms = new MemoryStream();
        Span<byte> len = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(len, 3); ms.Write(len); ms.Write(new byte[] { 0x67, 0xAA, 0xBB });
        BinaryPrimitives.WriteUInt32BigEndian(len, 2); ms.Write(len); ms.Write(new byte[] { 0x68, 0xCC });
        return ms.ToArray();
    }

    private static void Assert(bool ok, string what)
    {
        if (!ok) throw new Exception($"SelfTest FAILED: {what}");
    }
}
