using System.Buffers.Binary;
using System.IO;

namespace Clamshell;

// Clamshell Windows viewer. Connects to a host's window-stream (or
// display-stream) WebSocket endpoint, decodes, renders as a native window.
//
// Usage:
//   ClamshellWindowViewer <host> <port> [codec]      GUI mode (default)
//   ClamshellWindowViewer --verify <host> <port> [codec] [timeoutSec] [--allow-unverified]
//                                                     headless CI verification
//                                                     -- see the report for
//                                                     what this proves and
//                                                     .github/workflows/windows-ci.yml
//   ClamshellWindowViewer decode-file <path> [codec]  decode a real Annex-B
//                                                     elementary stream file
//                                                     directly (no network)
//   ClamshellWindowViewer decode-audio-file <file.aac> [hz] [seconds]
//                                                     decode an ADTS AAC-LC file
//                                                     through the session's audio
//                                                     decoder and check the PCM
//   ClamshellWindowViewer selftest                    pure protocol-logic checks
//   ClamshellWindowViewer known-hosts                 list saved Macs
//   ClamshellWindowViewer forget-host <addr|fingerprint>
//   ClamshellWindowViewer selftest-screens            build each screen once
internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "selftest") return SelfTest.Run();
        if (args.Length > 0 && args[0] == "selftest-auth") return AuthSelfTestMain(args[1..]);
        if (args.Length > 0 && args[0] == "selftest-keystore") return KeyStoreSelfTest.Run();
        if (args.Length > 0 && args[0] == "selftest-screens") return AuthScreens.SelfTest() == 0 ? 0 : 1;
        if (args.Length > 0 && args[0] == "known-hosts") return KnownHostsMain();
        if (args.Length > 0 && args[0] == "forget-host") return ForgetHostMain(args[1..]);
        if (args.Length > 0 && args[0] == "--verify") return VerifyMain(args[1..]);
        // --allow-unverified belongs to --verify only. Anywhere else it is ignored.
        args = args.Where(a => a != "--allow-unverified").ToArray();
        if (args.Length > 0 && args[0] == "decode-file") return DecodeFileMain(args[1..]);
        if (args.Length > 0 && args[0] == "decode-audio-file") return DecodeAudioFileMain(args[1..]);

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

    /// <summary>Prints one line per saved Mac: address, name, fingerprint. Changes nothing.</summary>
    private static int KnownHostsMain()
    {
        Clamshell.Auth.KnownHosts hosts;
        try { hosts = new Clamshell.Auth.KnownHostsFile(ViewerPaths.DataFolder).Load(); }
        catch (Clamshell.Auth.KnownHostsFileException e) { Console.Error.WriteLine(e.Message); return 1; }
        foreach (var h in hosts.Hosts)
        {
            var addresses = h.Addresses.Count == 0 ? new List<string> { "-" } : h.Addresses.Select(a => a.Address).ToList();
            foreach (var a in addresses) Console.WriteLine($"{a}\t{h.Name}\t{h.Fingerprint}");
        }
        return 0;
    }

    /// <summary>Forgets one saved Mac, named by an address or a fingerprint. The
    /// next connection treats it as a computer never met.</summary>
    private static int ForgetHostMain(string[] args)
    {
        if (args.Length != 1)
        {
            Console.Error.WriteLine("Usage: ClamshellWindowViewer forget-host <address or fingerprint>");
            return 1;
        }
        var file = new Clamshell.Auth.KnownHostsFile(ViewerPaths.DataFolder);
        Clamshell.Auth.KnownHosts hosts;
        try { hosts = file.Load(); }
        catch (Clamshell.Auth.KnownHostsFileException e) { Console.Error.WriteLine(e.Message); return 1; }
        string what = args[0].Trim();
        var matches = hosts.Hosts.Where(h =>
            h.Fingerprint.Equals(what, StringComparison.OrdinalIgnoreCase)
            || h.Addresses.Any(a => a.Address.Equals(what, StringComparison.OrdinalIgnoreCase))).ToList();
        if (matches.Count != 1)
        {
            Console.Error.WriteLine(matches.Count == 0
                ? $"No saved Mac matches {what}. Run known-hosts to list them."
                : $"{matches.Count} saved Macs match {what}. Use the fingerprint.");
            return 1;
        }
        try { file.Apply(Clamshell.Auth.KnownHostsChange.Forget(matches[0].Id), DateTimeOffset.UtcNow.ToUnixTimeSeconds()); }
        catch (Clamshell.Auth.KnownHostsFileException e) { Console.Error.WriteLine(e.Message); return 1; }
        Console.WriteLine($"Forgot {matches[0].Name} ({matches[0].Fingerprint}).");
        return 0;
    }

    /// <summary>Device-auth checks that need no network and no window.</summary>
    private static int AuthSelfTestMain(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("Usage: ClamshellWindowViewer selftest-auth <auth-v1.json>");
            return 1;
        }
        var run = new Clamshell.Auth.TestRun(Log.Line);
        Clamshell.Auth.AuthTests.Run(run, args[0]);
        Log.Line($"selftest-auth: {run.Passed} passed, {run.Failed} failed");
        return run.Failed == 0 ? 0 : 1;
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
        // The one yes that rule 6 asks of a person, for a headless run with no
        // person. It answers that question only and is never saved.
        bool allowUnverified = args.Contains("--allow-unverified");
        args = args.Where(a => a != "--allow-unverified").ToArray();
        if (args.Length < 2)
        {
            Console.Error.WriteLine("Usage: ClamshellWindowViewer --verify <host> <port> [h264|hevc] [timeoutSec] [--allow-unverified]");
            return 1;
        }
        string host = args[0];
        int port = int.Parse(args[1]);
        StreamCodec codec = args.Length > 2 && args[2].Equals("hevc", StringComparison.OrdinalIgnoreCase)
            ? StreamCodec.Hevc : StreamCodec.H264;
        int timeoutSec = args.Length > 3 ? int.Parse(args[3]) : 20;

        ViewerClient client;
        try { client = ViewerClient.OpenDefault(); }
        catch (DeviceKeyException e)
        {
            Log.Line($"verify: FAIL -- {e.Message}");
            return 1;
        }
        using var disposeClient = client;
        client.AllowUnverified = allowUnverified;
        client.OnState = state => Log.Line($"verify: state {state.Kind}");
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

        // Re-encode the file's Annex-B to AVCC and feed it through the exact
        // same Feed() entry point a live VIDEO_FRAME takes (Dispatch -> Feed
        // -> Avcc.ToAnnexB -> decode), not the lower-level FeedAnnexB --
        // this proves the actual wire-payload code path, not just the MFT
        // underneath it. The whole file is fed as one access unit (SPS+PPS+
        // IDR); the CI job generates a single-frame file specifically so
        // that's valid. Flush() forces out any frame the decoder is holding
        // back for reordering, which a single feed+drain isn't guaranteed to
        // do on its own.
        decoder.Feed(AnnexBToAvcc(annexB), 0);
        decoder.Flush();

        if (!got) { Log.Line($"decode-file: FAIL -- {reason}"); return 1; }
        Log.Line("decode-file: PASS");
        return 0;
    }

    /// <summary>Decodes an ADTS AAC-LC file (48 kHz stereo) with the same
    /// AudioDecoder a live session uses: the ADTS headers are dropped, each raw
    /// access unit goes in as an AUDIO_FRAME payload would, and the PCM that comes
    /// out is checked for its length and for a tone at `hz` (default 1000) lasting
    /// `seconds` (default 1). Proves the decoder, not the sound device: nothing
    /// here is played.</summary>
    private static int DecodeAudioFileMain(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("Usage: ClamshellWindowViewer decode-audio-file <file.aac> [hz] [seconds]");
            return 1;
        }
        double hz = args.Length > 1 ? double.Parse(args[1], System.Globalization.CultureInfo.InvariantCulture) : 1000;
        double seconds = args.Length > 2 ? double.Parse(args[2], System.Globalization.CultureInfo.InvariantCulture) : 1;

        byte[] file;
        try { file = File.ReadAllBytes(args[0]); }
        catch (Exception e) { Log.Line($"decode-audio-file: could not read {args[0]}: {e.Message}"); return 1; }

        var units = Adts.Split(file, out string? problem);
        if (problem != null) { Log.Line($"decode-audio-file: FAIL -- {problem}"); return 1; }
        if (units.Count == 0) { Log.Line("decode-audio-file: FAIL -- no AAC frames in the file"); return 1; }

        var pcm = new MemoryStream();
        using (var decoder = new AudioDecoder())
        {
            decoder.OnPcm = b => pcm.Write(b, 0, b.Length);
            foreach (var u in units) decoder.Feed(u);
            decoder.Flush();
        }

        bool ok = AudioCheck.Verify(pcm.ToArray(), units.Count, hz, seconds, out string detail);
        if (!ok) { Log.Line($"decode-audio-file: FAIL -- {detail}"); return 1; }
        Log.Line($"decode-audio-file: {detail}");
        Log.Line("decode-audio-file: PASS");
        return 0;
    }

    // Inverse of VideoDecoder.cs's Avcc.ToAnnexB -- Annex-B (start-code
    // delimited NALs, what ffmpeg's raw h264 muxer produces) -> AVCC
    // (length-prefixed), the wire's actual VIDEO_FRAME payload shape. Exists
    // only so decode-file can exercise the real Feed() entry point instead
    // of a separate Annex-B-only code path. Mirrors WindowsServer/
    // VideoEncoder.cs's AnnexB.ToAvcc (host-side, different project -- see
    // Protocol.cs's header for why these projects don't share code).
    private static byte[] AnnexBToAvcc(ReadOnlySpan<byte> annexB)
    {
        using var outMs = new MemoryStream(annexB.Length + 8);
        int i = 0, n = annexB.Length, nalStart = -1;
        while (i < n)
        {
            int sc = StartCodeLen(annexB, i);
            if (sc > 0)
            {
                if (nalStart >= 0) WriteNal(outMs, annexB.Slice(nalStart, i - nalStart));
                i += sc;
                nalStart = i;
            }
            else i++;
        }
        if (nalStart >= 0 && nalStart < n) WriteNal(outMs, annexB.Slice(nalStart, n - nalStart));
        return outMs.ToArray();
    }

    private static int StartCodeLen(ReadOnlySpan<byte> b, int i)
    {
        if (i + 3 <= b.Length && b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1) return 3;
        if (i + 4 <= b.Length && b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 0 && b[i + 3] == 1) return 4;
        return 0;
    }

    private static void WriteNal(Stream s, ReadOnlySpan<byte> nal)
    {
        if (nal.Length == 0) return;
        Span<byte> len = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(len, (uint)nal.Length);
        s.Write(len);
        s.Write(nal);
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

        AudioChecks();

        Console.WriteLine("SelfTest: all checks passed");
        return 0;
    }

    // The audio parts that need no decoder or sound device: the AAC user-data
    // blob, ADTS splitting, the tone check, and the latency rules.
    private static void AudioChecks()
    {
        // The renegotiation cap: four format changes per unit, then the unit is dropped;
        // three dropped units in a row end the audio; a good unit resets the count.
        var cap = new RenegotiationCap();
        cap.StartFeed();
        for (int i = 0; i < RenegotiationCap.MaxPerFeed; i++) Assert(cap.Allow(), "cap: change within the limit is allowed");
        Assert(!cap.Allow(), "cap: the change past the limit is refused");
        cap.StartFeed();
        Assert(cap.Allow(), "cap: a new unit starts from zero");
        Assert(!cap.DroppedUnit() && !cap.DroppedUnit(), "cap: two dropped units do not give up");
        cap.FeedWorked();
        Assert(!cap.DroppedUnit() && !cap.DroppedUnit(), "cap: a good unit resets the dropped count");
        Assert(cap.DroppedUnit(), "cap: three dropped units in a row give up");

        Assert(AudioDecoder.UserData.Length == 14 && AudioDecoder.UserData[12] == 0x11 && AudioDecoder.UserData[13] == 0x90,
            "AAC user data: 12 HEAACWAVEINFO bytes, then 11 90");
        Assert(AudioDecoder.UserData[0] == 0 && AudioDecoder.UserData[2] == 0x29, "AAC user data: raw payload, AAC-LC L2");

        // Two ADTS frames (AAC-LC, 48 kHz, stereo, no CRC) with 3 and 5 payload bytes.
        byte[] Frame(byte[] payload)
        {
            int len = 7 + payload.Length;
            var f = new List<byte> { 0xFF, 0xF1, 0x4C, (byte)(0x80 | ((len >> 11) & 3)), (byte)((len >> 3) & 0xFF),
                (byte)(((len & 7) << 5) | 0x1F), 0xFC };
            f.AddRange(payload);
            return f.ToArray();
        }
        var file = Frame(new byte[] { 1, 2, 3 }).Concat(Frame(new byte[] { 4, 5, 6, 7, 8 })).ToArray();
        var units = Adts.Split(file, out string? problem);
        Assert(problem == null && units.Count == 2, "ADTS: two frames");
        Assert(units[0].SequenceEqual(new byte[] { 1, 2, 3 }) && units[1].SequenceEqual(new byte[] { 4, 5, 6, 7, 8 }),
            "ADTS: headers dropped, payloads kept");
        Adts.Split(file.Take(file.Length - 1).ToArray(), out string? cut);
        Assert(cut != null, "ADTS: a cut-off last frame is reported");
        Adts.Split(new byte[] { 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE }, out string? noSync);
        Assert(noSync != null, "ADTS: no sync word is reported");
        var mono = Frame(new byte[] { 1 });
        mono[3] = 0x40; // one channel
        Adts.Split(mono, out string? notStereo);
        Assert(notStereo != null, "ADTS: not stereo is reported");

        // A 1 kHz stereo second: right length and tone pass; another pitch, silence and a wrong length fail.
        byte[] Tone(double hz, int frames, double amp)
        {
            var b = new byte[frames * 4];
            for (int i = 0; i < frames; i++)
            {
                short v = (short)(amp * Math.Sin(2 * Math.PI * hz * i / 48000));
                BitConverter.GetBytes(v).CopyTo(b, i * 4);
                BitConverter.GetBytes(v).CopyTo(b, i * 4 + 2);
            }
            return b;
        }
        Assert(AudioCheck.Verify(Tone(1000, 48128, 8000), 47, 1000, 1, out _), "tone check: 1 kHz passes");
        Assert(!AudioCheck.Verify(Tone(440, 48128, 8000), 47, 1000, 1, out _), "tone check: 440 Hz fails as 1 kHz");
        Assert(!AudioCheck.Verify(new byte[48128 * 4], 47, 1000, 1, out _), "tone check: silence fails");
        Assert(!AudioCheck.Verify(Tone(1000, 48128, 8000), 40, 1000, 1, out _), "tone check: wrong length fails");
        Assert(!AudioCheck.Verify(Tone(1000, 24064, 8000), 23, 1000, 1, out _), "tone check: half a second fails");

        // The latency rules.
        var p = new AudioPacing();
        Assert(!p.ShouldStart(79) && p.ShouldStart(80), "pacing: starts at 80 ms");
        Assert(p.Offer(100) == AudioPacing.Verdict.Queue && p.Offer(250) == AudioPacing.Verdict.Queue, "pacing: queues up to 250 ms");
        Assert(p.Offer(251) == AudioPacing.Verdict.Drop, "pacing: drops past 250 ms");
        Assert(p.Offer(150) == AudioPacing.Verdict.Drop, "pacing: keeps dropping until 100 ms");
        Assert(p.Offer(100) == AudioPacing.Verdict.Queue && p.Offer(200) == AudioPacing.Verdict.Queue, "pacing: queues again at 100 ms");
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
