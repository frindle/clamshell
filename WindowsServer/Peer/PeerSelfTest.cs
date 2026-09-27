using System.Security.Cryptography;
using System.Text;

namespace Clamshell;

// `ClamshellServer peerselftest` — the Windows half of the shared-desk
// cross-check. Every wire message is pinned to the SAME literal hex the Swift
// selftest (Sources/Clamshell/Peer/PeerProtocolSelfTest.swift) asserts, and
// the crypto is pinned to Swift-made vectors (a CryptoKit signature must
// verify here, the PIN proof must match byte for byte), so a Mac and a PC can
// only disagree if both selftests are changed together.
// Then real loopback: two PeerLinks pair over TCP/WebSocket with a PIN, and
// two FileTransfers move a file and a folder across that link.
// No UI, no input injection, no capture — CI runs it on windows-latest.
internal static class PeerSelfTest
{
    private static int _failures;
    private static void Check(bool ok, string what)
    {
        if (!ok) _failures++;
        Console.WriteLine((ok ? "ok   " : "FAIL: ") + what);
    }

    private static bool Wait(Func<bool> cond, double seconds = 10)
    {
        var end = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < end) { if (cond()) return true; Thread.Sleep(20); }
        return cond();
    }

    public static string Hex(byte[] b) => Convert.ToHexString(b).ToLowerInvariant();
    private static byte[] Fill(byte v, int n) => Enumerable.Repeat(v, n).ToArray();
    private static byte[] Payload(byte[] frame) => frame[5..];

    public static int Run(bool includeLoopback = true)
    {
        _failures = 0;
        Golden();
        RoundTrips();
        Rejections();
        Framing();
        Crypto();
        FileNames();
        Edge();
        Keys();
        if (includeLoopback)
        {
            Loopback();
        }
        Console.WriteLine(_failures == 0 ? "PASS: peer selftest" : $"FAIL: {_failures} check(s) failed");
        return _failures == 0 ? 0 : 1;
    }

    // MARK: - Golden vectors (identical table in PeerProtocolSelfTest.swift)

    internal static readonly (string Name, string Hex)[] GoldenHex =
    {
        ("challenge", "40000000201111111111111111111111111111111111111111111111111111111111111111"),
        ("hello", "41000000d7020104" + string.Concat(Enumerable.Repeat("ab", 64)) + string.Concat(Enumerable.Repeat("11", 32))
                  + string.Concat(Enumerable.Repeat("22", 64)) + string.Concat(Enumerable.Repeat("33", 32)) + "000a4d61632053747564696f00001400000005a0"),
        ("helloNoPin", "41000000ae020004" + string.Concat(Enumerable.Repeat("ab", 64)) + string.Concat(Enumerable.Repeat("11", 32))
                       + string.Concat(Enumerable.Repeat("22", 64)) + "0001780000000100000001"),
        ("helloAck", "42000000b4020004" + string.Concat(Enumerable.Repeat("ab", 64)) + string.Concat(Enumerable.Repeat("22", 64))
                     + "01" + string.Concat(Enumerable.Repeat("33", 32)) + "000657696e20504300000a00000005a0"),
        ("helloAckRefused", "42000000020202"),
        ("edgeEnter", "440000000a00000000003e80000001"),
        ("edgeLeave", "4500000000"),
        ("clipboardText", "300000000a68c3a96c6c6f20e29c93"),
        ("clipboardPng", "46000000050189504e47"),
        ("handoffBegin", "480000003101020304013f0000003dcccccd3f66666600000500000002d01721000d446f6320e2809420506167657300055061676573"),
        ("handoffAccept", "490000000400000007"),
        ("handoffReject", "4a000000050000000705"),
        ("handoffReturnEdge", "4b0000000900000009023f400000"),
        ("handoffReturnHome", "4b0000000900000009ff00000000"),
        ("windowClosed", "4c000000040000002a"),
        ("fileOffer", "500000001500000003000000020000000000076120622e7a6970"),
        ("fileAccept", "510000000400000003"),
        ("fileReject", "52000000050000000303"),
        ("fileChunk", "530000000f000000030000000000020000010203"),
        ("fileDone", "540000002400000003" + string.Concat(Enumerable.Repeat("5a", 32))),
        ("fileCancel", "55000000050000000302"),
        ("mouseMove", "20000000083f0000003e800000"),
        ("mouseButton", "210000000a01013dcccccd3e4ccccd"),
        ("key", "220000000b0025010000000000140000"),
        ("scroll", "230000000800000000c2200000"),
    };

    internal static Dictionary<string, byte[]> GoldenMessages()
    {
        var key = new byte[] { 0x04 }.Concat(Fill(0xAB, 64)).ToArray();
        var nonce = Fill(0x11, 32);
        var sig = Fill(0x22, 64);
        var proof = Fill(0x33, 32);
        return new()
        {
            ["challenge"] = PeerMsg.Challenge(nonce),
            ["hello"] = PeerMsg.Hello(key, nonce, sig, proof, "Mac Studio", 5120, 1440),
            ["helloNoPin"] = PeerMsg.Hello(key, nonce, sig, null, "x", 1, 1),
            ["helloAck"] = PeerMsg.HelloAck(PeerHelloStatus.Ok, key, sig, proof, "Win PC", 2560, 1440),
            ["helloAckRefused"] = PeerMsg.HelloAck(PeerHelloStatus.BadPin),
            ["edgeEnter"] = PeerMsg.EdgeEnter(PeerEdge.Left, 0, 0.25f, true),
            ["edgeLeave"] = PeerMsg.EdgeLeave(),
            ["clipboardText"] = PeerMsg.ClipboardText("héllo ✓"),
            ["clipboardPng"] = PeerMsg.ClipboardData(1, new byte[] { 0x89, 0x50, 0x4E, 0x47 }),
            ["handoffBegin"] = PeerMsg.HandoffBegin(new HandoffBeginPayload(0x01020304, PeerEdge.Right, 0.5f, 0.1f, 0.9f,
                1280, 720, 5921, "Doc — Pages", "Pages")),
            ["handoffAccept"] = PeerMsg.HandoffAccept(7),
            ["handoffReject"] = PeerMsg.HandoffReject(7, PeerRejectReason.Busy),
            ["handoffReturnEdge"] = PeerMsg.HandoffReturn(9, PeerEdge.Top, 0.75f),
            ["handoffReturnHome"] = PeerMsg.HandoffReturn(9, null, 0),
            ["windowClosed"] = PeerMsg.WindowClosed(42),
            ["fileOffer"] = PeerMsg.FileOffer(3, 1UL << 33, "a b.zip"),
            ["fileAccept"] = PeerMsg.FileAccept(3),
            ["fileReject"] = PeerMsg.FileReject(3, PeerRejectReason.Disk),
            ["fileChunk"] = PeerMsg.FileChunk(3, 131072, new byte[] { 1, 2, 3 }),
            ["fileDone"] = PeerMsg.FileDone(3, Fill(0x5A, 32)),
            ["fileCancel"] = PeerMsg.FileCancel(3, PeerRejectReason.TooLarge),
            ["mouseMove"] = PeerMsg.MouseMove(0.5f, 0.25f),
            ["mouseButton"] = PeerMsg.MouseButton(1, true, 0.1f, 0.2f),
            ["key"] = PeerMsg.Key(0x25, true, 0x140000),
            ["scroll"] = PeerMsg.Scroll(0, -40),
        };
    }

    private static void Golden()
    {
        var msgs = GoldenMessages();
        bool print = Environment.GetEnvironmentVariable("CLAMSHELL_PRINT_GOLDEN") == "1";
        Check(msgs.Count == GoldenHex.Length, "every golden message has a vector");
        foreach (var (name, hex) in GoldenHex)
        {
            if (print) Console.WriteLine($"golden {name} {Hex(msgs[name])}");
            Check(msgs.TryGetValue(name, out var b) && Hex(b) == hex, $"golden vector {name}");
        }
    }

    // MARK: - Parse round trips

    private static void RoundTrips()
    {
        var m = GoldenMessages();
        var h = PeerParse.Hello(Payload(m["hello"]));
        Check(h is not null && h.Name == "Mac Studio" && h.ScreenWidth == 5120 && h.ScreenHeight == 1440
              && h.PinProof is { Length: 32 } && h.PublicKey[0] == 4, "hello parses");
        Check(PeerParse.Hello(Payload(m["helloNoPin"])) is { PinProof: null, Name: "x" }, "hello without PIN proof parses");
        var a = PeerParse.HelloAck(Payload(m["helloAck"]));
        Check(a is { Status: PeerHelloStatus.Ok, Name: "Win PC", ScreenWidth: 2560 } && a.PinProof is { Length: 32 }, "ack parses");
        Check(PeerParse.HelloAck(Payload(m["helloAckRefused"]))?.Status == PeerHelloStatus.BadPin, "refusal ack parses");
        var e = PeerParse.EdgeEnter(Payload(m["edgeEnter"]));
        Check(e is { Edge: PeerEdge.Left, X: 0, Y: 0.25f, LeftButtonDown: true }, "edge enter parses");
        var hb = PeerParse.HandoffBegin(Payload(m["handoffBegin"]));
        Check(hb is { WindowId: 0x01020304, Edge: PeerEdge.Right, Width: 1280, Height: 720, StreamPort: 5921, Title: "Doc — Pages", AppName: "Pages" }
              && Math.Abs(hb.GrabY - 0.9f) < 1e-6, "handoff begin parses");
        Check(PeerParse.HandoffReturn(Payload(m["handoffReturnHome"])) is { WindowId: 9, Edge: null }, "handoff return home parses");
        Check(PeerParse.HandoffReturn(Payload(m["handoffReturnEdge"])) is { Edge: PeerEdge.Top, Position: 0.75f }, "handoff return edge parses");
        Check(PeerParse.IdAndReason(Payload(m["handoffReject"])) is { Id: 7, Reason: PeerRejectReason.Busy }, "reject parses");
        Check(PeerParse.FileOffer(Payload(m["fileOffer"])) is { TransferId: 3, Size: 1UL << 33, Name: "a b.zip" }, "file offer parses");
        var ch = PeerParse.FileChunk(Payload(m["fileChunk"]));
        Check(ch is { TransferId: 3, Offset: 131072 } && ch.Bytes.SequenceEqual(new byte[] { 1, 2, 3 }), "file chunk parses");
        Check(PeerParse.FileDone(Payload(m["fileDone"])) is { Id: 3 } d && d.Sha256.Length == 32, "file done parses");
        Check(PeerParse.ClipboardData(Payload(m["clipboardPng"])) is { Kind: 1 } c && c.Bytes.Length == 4, "clipboard data parses");

        // Names longer than the cap are cut on a character boundary: 60 × "—"
        // (3 bytes each) → 42 whole characters, never a broken scalar.
        var dashes = new PayloadWriter().Str(string.Concat(Enumerable.Repeat("—", 60))).Frame(MessageType.Clipboard);
        var r = new PeerReader(Payload(dashes));
        Check(r.Str() == string.Concat(Enumerable.Repeat("—", 42)), "multibyte name truncated to 42 whole characters");
        // An emoji with a skin-tone modifier is one grapheme: kept or dropped whole.
        string family = string.Concat(Enumerable.Repeat("👍🏽", 20)); // 8 bytes each
        var fr = new PeerReader(Payload(new PayloadWriter().Str(family).Frame(MessageType.Clipboard))).Str();
        Check(fr == string.Concat(Enumerable.Repeat("👍🏽", 16)), "grapheme clusters truncated whole");
    }

    // MARK: - Hostile input

    private static void Rejections()
    {
        var key = new byte[] { 0x04 }.Concat(Fill(0xAB, 64)).ToArray();
        var hello = Payload(PeerMsg.Hello(key, Fill(0x11, 32), Fill(0x22, 64), null, "n", 1, 1));
        bool allRejected = true;
        for (int n = 0; n < hello.Length; n++) if (PeerParse.Hello(hello[..n]) is not null) allRejected = false;
        Check(allRejected, $"every truncation of HELLO (0..{hello.Length - 1} bytes) rejected");
        var badVer = (byte[])hello.Clone(); badVer[0] = 1;
        Check(PeerParse.Hello(badVer) is null, "hello wrong version");
        var badKey = (byte[])hello.Clone(); badKey[2] = 0x02;
        Check(PeerParse.Hello(badKey) is null, "hello non-X9.63 key");
        var pinFlag = (byte[])hello.Clone(); pinFlag[1] = 1;
        Check(PeerParse.Hello(pinFlag) is null, "hello PIN flag without proof");

        var over = new PayloadWriter().U16(PeerLimits.MaxName + 1).Bytes(Fill(0x41, PeerLimits.MaxName + 1)).Frame(MessageType.Clipboard);
        Check(new PeerReader(Payload(over)).Str() is null, "name over cap rejected");
        var shortName = new PayloadWriter().U16(50).U8(0x41).Frame(MessageType.Clipboard);
        Check(new PeerReader(Payload(shortName)).Str() is null, "name overrunning payload rejected");
        var ctrl = new PayloadWriter().Str("a\u0007b").Frame(MessageType.Clipboard);
        Check(new PeerReader(Payload(ctrl)).Str() is null, "control char in name rejected");
        var del = new PayloadWriter().Str("a\u007Fb").Frame(MessageType.Clipboard);
        Check(new PeerReader(Payload(del)).Str() is null, "DEL in name rejected");
        var badUtf = new PayloadWriter().U16(2).U8(0xC3).U8(0x28).Frame(MessageType.Clipboard);
        Check(new PeerReader(Payload(badUtf)).Str() is null, "invalid UTF-8 rejected");

        Check(PeerParse.EdgeEnter(new byte[] { 9, 0, 0, 0, 0, 0, 0, 0, 0, 0 }) is null, "unknown edge rejected");
        Check(PeerParse.EdgeEnter(new byte[] { 0, 0x7F, 0xC0, 0, 0, 0, 0, 0, 0, 0 }) is null, "NaN coordinate rejected");
        Check(PeerParse.HandoffReturn(new byte[] { 0, 0, 0, 1, 7, 0, 0, 0, 0 }) is null, "handoff return bad edge");
        var huge = new PayloadWriter().U32(1).U8(0).F32(0).F32(0).F32(0).U32(100_000).U32(10).U16(1).Str("").Str("").Frame(MessageType.HandoffBegin);
        Check(PeerParse.HandoffBegin(Payload(huge)) is null, "handoff begin absurd size rejected");
        var port0 = new PayloadWriter().U32(1).U8(0).F32(0).F32(0).F32(0).U32(10).U32(10).U16(0).Str("").Str("").Frame(MessageType.HandoffBegin);
        Check(PeerParse.HandoffBegin(Payload(port0)) is null, "handoff begin port 0 rejected");
        var oversized = new PayloadWriter().U32(1).U64(0).Bytes(new byte[PeerLimits.ChunkSize + 1]).Frame(MessageType.FileChunk);
        Check(PeerParse.FileChunk(Payload(oversized)) is null, "oversized chunk rejected");
        Check(PeerParse.HelloAck(new byte[] { 2, 9 }) is null, "unknown ack status rejected");
    }

    private static void Framing()
    {
        var got = new List<(MessageType, int)>();
        var p = new FrameParser { OnMessage = (t, b) => got.Add((t, b.Length)) };
        var two = PeerMsg.HandoffAccept(1).Concat(PeerMsg.EdgeLeave()).ToArray();
        foreach (var b in two) p.Feed(new[] { b }); // one byte at a time
        Check(got.Count == 2 && got[0] == (MessageType.HandoffAccept, 4) && got[1] == (MessageType.EdgeLeave, 0),
              "frame parser: byte-at-a-time, two frames");
        got.Clear();
        p.Feed(two.Concat(two).ToArray());
        Check(got.Count == 4, "frame parser: several frames in one feed");
        var bad = new FrameParser();
        bad.Feed(new byte[] { 0x46, 0xFF, 0xFF, 0xFF, 0xFF });
        Check(bad.Corrupt, "frame parser: absurd length marks the stream corrupt");
    }

    // MARK: - Crypto against Swift-made vectors

    private static void Crypto()
    {
        var scalar = Enumerable.Range(1, 32).Select(i => (byte)i).ToArray();
        var fixedId = PeerIdentity.FromScalar(scalar);
        Check(Hex(fixedId.PublicKey) == "04515c3d6eb9e396b904d3feca7f54fdcd0cc1e997bf375dca515ad0a6c3b4035f4536be3a50f318fbf9a5475902a221502bef0d57e08c53b2cc0a56f17d9f9354",
              "fixed public key (same as CryptoKit)");
        Check(fixedId.Id == "4269889431e3131966fcaf6a457141943ed2c35b5b917ae62cb339546f523551", "fixed peer id (same as Swift)");
        var nonce = Fill(0x02, 32);
        var swiftSig = Convert.FromHexString("8d7c8838f0c897ef1f01724ab9968ef27416a4e381277aacb5cfdcaf95c732303f58a8d113ae080d694ed0c5674abcb68a8fb40aac77e079c4be9739fb1cf8df");
        Check(PeerIdentity.Verify(swiftSig, nonce, fixedId.PublicKey), "a CryptoKit signature verifies here");
        var tampered = (byte[])swiftSig.Clone(); tampered[10] ^= 1;
        Check(!PeerIdentity.Verify(tampered, nonce, fixedId.PublicKey), "tampered signature rejected");
        Check(!PeerIdentity.Verify(swiftSig, Fill(0x03, 32), fixedId.PublicKey), "signature over another nonce rejected");
        var own = fixedId.Sign(nonce);
        Check(own.Length == 64 && PeerIdentity.Verify(own, nonce, fixedId.PublicKey), "own signature is raw r||s and verifies");

        var proofKey = new byte[] { 0x04 }.Concat(Fill(0x01, 64)).ToArray();
        var proof = PeerIdentity.PinProof("000000", nonce, proofKey);
        Check(Hex(proof) == "a6f4272b2275bc4ada594f129c3b2fe53bff85d3e8db0515b14219807066a8d1", "PIN proof vector (same as Swift)");
        Check(PeerIdentity.VerifyPinProof(proof, "000000", nonce, proofKey) && !PeerIdentity.VerifyPinProof(proof, "000001", nonce, proofKey),
              "PIN proof verifies only with the right PIN");
        var pin = PeerIdentity.RandomPin();
        Check(pin.Length == 6 && pin.All(char.IsAsciiDigit), "PIN is 6 digits");

        string dir = Path.Combine(Path.GetTempPath(), $"clamshell-peer-selftest-{Environment.ProcessId}");
        try
        {
            var a = PeerIdentity.CreateEphemeral();
            var b = PeerIdentity.CreateEphemeral();
            var store = new PeerTrustStore(Path.Combine(dir, "peers.json"));
            store.Trust(a.PublicKey, "A");
            var reloaded = new PeerTrustStore(Path.Combine(dir, "peers.json"));
            Check(reloaded.IsTrusted(a.PublicKey) && !reloaded.IsTrusted(b.PublicKey) && reloaded.Peer(a.Id)?.Name == "A", "trust store persists");
            reloaded.Forget(a.Id);
            Check(!new PeerTrustStore(Path.Combine(dir, "peers.json")).IsTrusted(a.PublicKey), "forget persists");
            var i1 = PeerIdentity.LoadOrCreate(Path.Combine(dir, "id.key"));
            var i2 = PeerIdentity.LoadOrCreate(Path.Combine(dir, "id.key"));
            Check(i1.Id == i2.Id, "identity persists");
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

    // MARK: - File names (identical table in PeerProtocolSelfTest.swift)

    private static void FileNames()
    {
        (string Raw, string Want)[] cases =
        {
            ("../../etc/passwd", "passwd"),
            ("..\\..\\Windows\\win.ini", "win.ini"),
            ("/", "clamshell-transfer"),
            ("", "clamshell-transfer"),
            ("..", "clamshell-transfer"),
            (".hidden", "hidden"),
            ("...secret.txt", "secret.txt"),
            ("CON", "_CON"),
            ("con.txt", "_con.txt"),
            ("report:final?.pdf", "report_final_.pdf"),
            ("nul\0byte.txt", "nul_byte.txt"),
            ("trailing. ", "trailing"),
            ("ok name.tar.gz", "ok name.tar.gz"),
        };
        foreach (var (raw, want) in cases)
        {
            string got = PeerFileNames.Sanitize(raw);
            Check(got == want, $"sanitize({raw.Replace("\0", "\\0")}) == {want}, got {got}");
        }
        string lng = PeerFileNames.Sanitize(new string('x', 400) + ".jpeg");
        Check(Encoding.UTF8.GetByteCount(lng) <= PeerLimits.MaxFileName && lng.EndsWith(".jpeg"), "long name capped, extension kept");

        string dir = Path.Combine(Path.GetTempPath(), $"clamshell-peer-names-{Environment.ProcessId}");
        try
        {
            Directory.CreateDirectory(dir);
            File.WriteAllText(Path.Combine(dir, "a.txt"), "x");
            Check(Path.GetFileName(PeerFileNames.UniquePath(dir, "a.txt")) == "a (2).txt", "unique path adds (2)");
            string escaped = PeerFileNames.UniquePath(dir, PeerFileNames.Sanitize("../a.txt"));
            Check(Path.GetFullPath(Path.GetDirectoryName(escaped)!) == Path.GetFullPath(dir), "sanitized name stays inside dir");
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

    // MARK: - Edge geometry (same cases as EdgeSelfTest.swift)

    private static bool Near(double a, double b, double eps = 0.01) => Math.Abs(a - b) <= eps;

    private static void Edge()
    {
        var single = new[] { new Rect(0, 0, 1440, 900) };
        var e = EdgeGeometry.Exit(1439, 450, 4, 0, PeerEdge.Right, single);
        Check(e is { } x && Near(x.Fraction, 0.5), "right edge exit at mid-height");
        Check(EdgeGeometry.Exit(1439, 450, -4, 0, PeerEdge.Right, single) is null, "moving away from the edge doesn't cross");
        Check(EdgeGeometry.Exit(1200, 450, 4, 0, PeerEdge.Right, single) is null, "not at the edge doesn't cross");
        Check(EdgeGeometry.Exit(0, 225, -3, 0, PeerEdge.Left, single) is { } l && Near(l.Fraction, 0.25), "left edge exit at a quarter");
        Check(EdgeGeometry.Exit(-5, 225, -3, 0, PeerEdge.Left, single) is { } lb && Near(lb.Fraction, 0.25), "hook point past the edge still exits");
        Check(EdgeGeometry.Exit(360, 0, 0, -2, PeerEdge.Top, single) is { } t && Near(t.Fraction, 0.25), "top edge exit");
        Check(EdgeGeometry.Exit(1080, 899, 0, 2, PeerEdge.Bottom, single) is { } b && Near(b.Fraction, 0.75), "bottom edge exit");
        var dual = new[] { new Rect(0, 0, 1440, 900), new Rect(1440, -90, 1920, 1080) };
        Check(EdgeGeometry.Exit(1439, 450, 5, 0, PeerEdge.Right, dual) is null, "seam between two local displays is not an exit");
        Check(EdgeGeometry.Exit(3359, 450, 5, 0, PeerEdge.Right, dual) is { } far && far.Display == dual[1] && Near(far.Fraction, 0.5),
              "outer edge of the second display exits");
        var stacked = new[] { new Rect(0, 0, 1000, 800), new Rect(500, -600, 1000, 600) };
        Check(EdgeGeometry.Exit(200, 0, 0, -3, PeerEdge.Top, stacked) is not null, "uncovered stretch of a top edge exits");
        Check(EdgeGeometry.Exit(700, 0, 0, -3, PeerEdge.Top, stacked) is null, "covered stretch of a top edge does not");
        var r = EdgeGeometry.ReentryPoint(single[0], PeerEdge.Right, 0.5);
        Check(Near(r.X, 1436) && Near(r.Y, 449.5), "re-entry point is inset from the edge");
        Check(Near(EdgeGeometry.SpeedScale(1440, 2880), 2) && Near(EdgeGeometry.SpeedScale(1440, 100), 0.5)
              && Near(EdgeGeometry.SpeedScale(1000, 9000), 3), "speed scale clamps to 0.5…3");

        var c = new RemoteCursor(PeerEdge.Left, 0.5, 1921, 1081);
        Check(Near(c.X, 0) && Near(c.Y, 540), "enters on the peer's left edge");
        Check(c.Move(100, 0) is null && Near(c.Normalized.X, 100.0 / 1920), "moves inward");
        Check(c.Move(0, 5000) is null && Near(c.Y, 1080), "clamped at the bottom");
        var back = c.Move(-150, 0);
        Check(back is { } bk && Near(bk, 1.0), "leaving through the entry edge returns the along-edge position");
        var tc = new RemoteCursor(PeerEdge.Top, 0.25, 1001, 501);
        Check(Near(tc.X, 250) && Near(tc.Y, 0), "enters on the top edge");
        Check(tc.Move(0, 10) is null && tc.Move(0, -11) is not null, "top entry leaves upward");
        Check(new RemoteCursor(PeerEdge.Right, 0, 101, 101).Move(1000, 0) is not null, "right entry leaves rightward");
    }

    private static void Keys()
    {
        Check(PeerKeys.MacCode(PeerKeys.VK_LCONTROL, false) == 55 && PeerKeys.MacCode(PeerKeys.VK_RCONTROL, true) == 54, "Ctrl → Command");
        Check(PeerKeys.MacCode(PeerKeys.VK_LWIN, true) == 59 && PeerKeys.MacCode(PeerKeys.VK_LMENU, false) == 58
              && PeerKeys.MacCode(PeerKeys.VK_RSHIFT, false) == 60, "Win → Control, Alt → Option, right Shift");
        Check(PeerKeys.MacCode('C', false) == 8 && PeerKeys.MacCode('A', false) == 0 && PeerKeys.MacCode('1', false) == 18, "letters and digits");
        Check(PeerKeys.MacCode(PeerKeys.VK_RETURN, false) == 36 && PeerKeys.MacCode(PeerKeys.VK_RETURN, true) == 76, "Return vs keypad Enter");
        Check(PeerKeys.MacCode(0x60, false) == 82 && PeerKeys.MacCode(0x2D, true) == 114 && PeerKeys.MacCode(0x7C, false) == 105, "keypad 0, Insert → Help, F13");
        Check(PeerKeys.MacCode(0x25, true) == 123 && PeerKeys.MacCode(0x2E, true) == 117, "arrows, forward delete");
        Check(PeerKeys.MacCode(0xFF, false) is null, "unmapped VK → null");
        // Every Mac→Windows row that isn't a modifier round-trips.
        bool round = MacKeyMap.All.Where(r => !PeerKeys.IsModifier(r.Mac) && r.Vk is not (0x10 or 0x11 or 0x12))
            .All(r => MacKeyMap.ToWindows(PeerKeys.MacCode(r.Vk, r.Mac == 76) ?? 0xFFFF) == r.Vk);
        Check(round, "VK → mac → VK round-trips for every mapped key");
        Check(PeerKeys.ModifierBit(55) == PeerKeys.FlagCommand && PeerKeys.ModifierBit(59) == PeerKeys.FlagControl
              && PeerKeys.ModifierBit(0) == 0, "modifier flag bits (CGEventFlags)");
        Check(PeerKeys.IsPanic('L', PeerKeys.FlagCommand | PeerKeys.FlagAlternate | PeerKeys.FlagShift)
              && !PeerKeys.IsPanic('L', PeerKeys.FlagCommand | PeerKeys.FlagAlternate), "panic key Ctrl+Alt+Shift+L");
    }

    // MARK: - Loopback link + file transfer

    private static void Loopback()
    {
        const ushort portA = 5994, portB = 5995;
        var a = new PeerLink(PeerIdentity.CreateEphemeral(), new PeerTrustStore(null), "A", portA, () => (800, 600));
        var b = new PeerLink(PeerIdentity.CreateEphemeral(), new PeerTrustStore(null), "B", portB, () => (1920, 1080));
        var aStates = new List<PeerLinkState>();
        var bMsgs = new List<(MessageType T, byte[] P)>();
        var aMsgs = new List<(MessageType T, byte[] P)>();
        a.OnStateChange += s => { lock (aStates) aStates.Add(s); };
        string root = Path.Combine(Path.GetTempPath(), $"clamshell-peer-loop-{Environment.ProcessId}");
        var inA = Path.Combine(root, "inA"); var inB = Path.Combine(root, "inB"); var src = Path.Combine(root, "src");
        var fa = new FileTransfer(inA); var fb = new FileTransfer(inB);
        fa.Send = (d, done) => a.Send(d, done);
        fb.Send = (d, done) => b.Send(d, done);
        var received = new List<string>();
        fb.OnReceived = p => { lock (received) received.Add(p); };
        a.OnMessage += (t, p) => { if (!fa.Receive(t, p)) lock (aMsgs) aMsgs.Add((t, p)); };
        b.OnMessage += (t, p) => { if (!fb.Receive(t, p)) lock (bMsgs) bMsgs.Add((t, p)); };
        try
        {
            a.StartListening(); b.StartListening();

            a.Connect("127.0.0.1", portB, "999999" == b.PairingPin ? "999998" : "999999");
            Check(Wait(() => a.State.Phase == PeerLinkPhase.Failed), $"wrong PIN refused ({a.State.Label})");
            Check(a.State.Label.Contains("wrong PIN"), "refusal ACK reaches the client before the drop");

            a.Connect("127.0.0.1", portB, null);
            Check(Wait(() => a.State.Phase == PeerLinkPhase.Failed && a.State.Label.Contains("not paired")), "unpaired, no PIN → untrusted");

            string pin = b.PairingPin;
            a.Connect("127.0.0.1", portB, pin);
            Check(Wait(() => a.State.IsLinked && b.State.IsLinked), "pairs with the right PIN");
            Check(a.State.Peer?.Id == b.Identity.Id && b.State.Peer?.Id == a.Identity.Id, "each side authenticated the other's key");
            Check(a.State.ScreenWidth == 1920 && b.State.ScreenHeight == 600, "screen sizes exchanged");
            Check(b.RemoteHost == "127.0.0.1" && a.RemoteHost == "127.0.0.1", $"peer address known on both sides ({a.RemoteHost}/{b.RemoteHost})");
            Check(b.PairingPin != pin, "PIN is single-use");

            for (int i = 0; i < 50; i++) a.Send(PeerMsg.HandoffAccept((uint)i));
            b.Send(PeerMsg.EdgeEnter(PeerEdge.Right, 0, 0.5f, false));
            Check(Wait(() => { lock (bMsgs) return bMsgs.Count == 50; }), "50 messages A→B");
            lock (bMsgs) Check(bMsgs.Select((m, i) => PeerParse.WindowId(m.P) == (uint)i).All(x => x), "…in order");
            Check(Wait(() => { lock (aMsgs) return aMsgs.Count == 1 && aMsgs[0].T == MessageType.EdgeEnter; }), "B→A message");

            a.Disconnect();
            Check(Wait(() => !b.State.IsLinked), "B notices A disconnect");
            a.Connect("127.0.0.1", portB, null);
            Check(Wait(() => a.State.IsLinked && b.State.IsLinked), "reconnects without a PIN once trusted");

            var stranger = new PeerLink(PeerIdentity.CreateEphemeral(), new PeerTrustStore(null), "S", 5996, () => (1, 1));
            stranger.Connect("127.0.0.1", portB, "123456" == b.PairingPin ? "654321" : "123456");
            Check(Wait(() => stranger.State.Phase == PeerLinkPhase.Failed), "stranger with a guessed PIN refused");
            stranger.Stop();
            if (!b.State.IsLinked) { a.Connect("127.0.0.1", portB, null); Wait(() => a.State.IsLinked && b.State.IsLinked); }
            // Note: like the Mac side, an incoming handshake replaces the
            // current link — a refused stranger costs one reconnect.
            Check(a.State.IsLinked && b.State.IsLinked, "link up for the file transfer");

            // Files: one 1 MiB+ random file (several chunks, not a multiple of
            // the chunk size) and a folder (sent as a zip).
            Directory.CreateDirectory(src);
            var big = RandomNumberGenerator.GetBytes(PeerLimits.ChunkSize * 9 + 1234);
            File.WriteAllBytes(Path.Combine(src, "big file.bin"), big);
            Directory.CreateDirectory(Path.Combine(src, "folder", "sub"));
            File.WriteAllText(Path.Combine(src, "folder", "sub", "x.txt"), "hello");
            fa.SendPaths(new[] { Path.Combine(src, "big file.bin"), Path.Combine(src, "folder") });
            Check(Wait(() => { lock (received) return received.Count == 2; }, 30), "file and folder arrive");
            string got = Path.Combine(inB, "big file.bin");
            Check(File.Exists(got) && File.ReadAllBytes(got).SequenceEqual(big), "file content identical");
            string zip = Path.Combine(inB, "folder.zip");
            if (File.Exists(zip))
            {
                using var z = System.IO.Compression.ZipFile.OpenRead(zip);
                Check(z.Entries.Any(e => e.FullName.Replace('\\', '/') == "folder/sub/x.txt"), "folder zipped with its base directory");
            }
            else Check(false, "folder.zip received");
            Check(!Directory.GetFiles(inB, "*.part", SearchOption.AllDirectories).Any(), "no .part files left");

            fa.SendPaths(new[] { Path.Combine(src, "big file.bin") });
            Check(Wait(() => { lock (received) return received.Count == 3; }, 30) && File.Exists(Path.Combine(inB, "big file (2).bin")),
                  "a second copy gets a unique name");

            // A peer that lies about the hash: FILE_DONE with a wrong digest.
            received.Clear();
            fb.Receive(MessageType.FileOffer, Payload(PeerMsg.FileOffer(77, 3, "liar.txt")));
            fb.Receive(MessageType.FileChunk, Payload(PeerMsg.FileChunk(77, 0, new byte[] { 1, 2, 3 })));
            fb.Receive(MessageType.FileDone, Payload(PeerMsg.FileDone(77, Fill(0, 32))));
            fb.Drain();
            Check(!File.Exists(Path.Combine(inB, "liar.txt")) && received.Count == 0, "hash mismatch discards the file");
            fb.Receive(MessageType.FileOffer, Payload(PeerMsg.FileOffer(78, 3, "gap.txt")));
            fb.Receive(MessageType.FileChunk, Payload(PeerMsg.FileChunk(78, 1, new byte[] { 2, 3 })));
            fb.Receive(MessageType.FileDone, Payload(PeerMsg.FileDone(78, SHA256.HashData(new byte[] { 1, 2, 3 }))));
            fb.Drain();
            Check(!File.Exists(Path.Combine(inB, "gap.txt")), "out-of-order chunk discards the file");
            fb.Receive(MessageType.FileOffer, Payload(PeerMsg.FileOffer(79, PeerLimits.MaxFileSize + 1, "huge.bin")));
            fb.Drain();
            Check(Directory.GetFiles(inB, "*.part", SearchOption.AllDirectories).Length == 0, "oversized offer refused, nothing written");
        }
        finally
        {
            a.Stop(); b.Stop();
            fa.Reset(); fb.Reset(); fa.Drain(); fb.Drain();
            try { Directory.Delete(root, true); } catch { }
        }
    }

    // MARK: - Interop with the Mac (`peerinterop`, twin of `clamshell peer-interop`)

    internal static readonly int InteropFileSize = PeerLimits.ChunkSize * 7 + 4321;
    internal static byte[] InteropPattern()
    {
        var d = new byte[InteropFileSize];
        for (int i = 0; i < d.Length; i++) d[i] = unchecked((byte)(i * 31 + 7));
        return d;
    }

    /// Golden messages legal on a linked connection and not consumed by the
    /// file-transfer engine — same filter as PeerInteropTest.swift.
    internal static List<(string Name, byte[] Bytes)> InteropMessages()
    {
        var m = GoldenMessages();
        return GoldenHex.Select(g => (g.Name, m[g.Name]))
            .Where(x => x.Item2[0] is not (>= 0x40 and <= 0x42) and not (>= 0x50 and <= 0x55)).ToList();
    }

    /// peerinterop listen <port> <dir> | connect <host> <port> <pin> <dir>
    public static int RunInterop(string[] args)
    {
        if (args.Length == 4 && args[0] == "mdns" && ushort.TryParse(args[2], out var mport) && double.TryParse(args[3], out var secs))
        {
            // Advertise + browse like the Mac's Bonjour, print what's found.
            var id = PeerIdentity.CreateEphemeral().Id;
            using var d = new PeerDiscovery();
            var seen = new HashSet<string>();
            d.OnChange += list =>
            {
                lock (seen)
                    foreach (var f in list)
                        if (seen.Add(f.Name + f.Id)) Console.WriteLine($"found {f.Name} id={f.Id ?? "-"} at {f.Host}:{f.Port}");
            };
            d.Start(args[1], id, mport);
            Console.WriteLine($"advertising {args[1]} id={id}");
            Thread.Sleep(TimeSpan.FromSeconds(secs));
            return 0;
        }
        const string usage = "usage: peerinterop listen <port> <dir> | connect <host> <port> <pin> <dir> | mdns <name> <port> <seconds>";
        bool listen = args.Length > 0 && args[0] == "listen";
        if (!((listen && args.Length == 3) || (args.Length == 5 && args[0] == "connect"))
            || !ushort.TryParse(args[listen ? 1 : 2], out var port)) { Console.WriteLine(usage); return 2; }
        string dir = args[^1];
        Directory.CreateDirectory(dir);

        var link = new PeerLink(PeerIdentity.CreateEphemeral(), new PeerTrustStore(null), "windows-interop",
                                listen ? port : (ushort)0, () => (3333, 4444));
        var files = new FileTransfer(dir);
        var gate = new object();
        var got = new List<byte[]>();
        var received = new List<string>();
        var failures = new List<string>();
        bool sent = false;
        using var linked = new ManualResetEventSlim();
        files.Send = (d, done) => link.Send(d, done);
        files.OnReceived = p => { lock (gate) received.Add(p); };
        files.OnSent = _ => { lock (gate) sent = true; };
        files.OnFailed = m => { lock (gate) failures.Add(m); };
        link.OnMessage += (t, p) => { if (!files.Receive(t, p)) lock (gate) got.Add(Proto.Frame(t, p)); };
        link.OnStateChange += s =>
        {
            if (s.IsLinked) { Console.WriteLine($"linked with {s.Label} {s.ScreenWidth}x{s.ScreenHeight} id {s.Peer?.Id[..12]}"); linked.Set(); }
            if (s.Phase == PeerLinkPhase.Failed) Console.WriteLine($"link: {s.Label}");
        };
        string src = Path.Combine(Path.GetTempPath(), $"interop-from-windows-{Environment.ProcessId}.bin");
        File.WriteAllBytes(src, InteropPattern());
        try
        {
            if (listen) { link.StartListening(); Console.WriteLine($"PIN {link.PairingPin}"); Console.Out.Flush(); }
            else link.Connect(args[1], port, args[3]);
            if (!linked.Wait(TimeSpan.FromSeconds(30))) { Console.WriteLine("FAIL: never linked"); return 1; }

            var expected = InteropMessages();
            foreach (var (_, b) in expected) link.Send(b);
            files.SendPaths(new[] { src });
            Wait(() => { lock (gate) return got.Count >= expected.Count && received.Count >= 1 && sent; }, 30);
            Thread.Sleep(1000); // let our last bytes reach the peer before closing

            int bad = 0;
            lock (gate)
            {
                for (int i = 0; i < expected.Count; i++)
                {
                    if (i >= got.Count) { Console.WriteLine($"FAIL: missing {expected[i].Name}"); bad++; continue; }
                    if (!got[i].AsSpan().SequenceEqual(expected[i].Bytes)) { Console.WriteLine($"FAIL: {expected[i].Name} differs: {Hex(got[i])}"); bad++; }
                }
                if (got.Count > expected.Count) { Console.WriteLine($"FAIL: {got.Count - expected.Count} unexpected extra message(s)"); bad++; }
                if (received.FirstOrDefault() is { } r)
                {
                    bool ok = File.ReadAllBytes(r).AsSpan().SequenceEqual(InteropPattern());
                    Console.WriteLine(ok ? $"ok   received {Path.GetFileName(r)} intact" : "FAIL: received file differs");
                    if (!ok) bad++;
                }
                else { Console.WriteLine("FAIL: no file received"); bad++; }
                if (!sent) { Console.WriteLine("FAIL: our file was not sent"); bad++; }
                foreach (var f in failures) { Console.WriteLine($"FAIL: transfer: {f}"); bad++; }
            }
            if (bad == 0) Console.WriteLine($"ok   {expected.Count} golden messages received byte-identical");
            Console.WriteLine(bad == 0 ? "PASS" : $"FAIL: {bad} problem(s)");
            return bad == 0 ? 0 : 1;
        }
        finally
        {
            link.Stop();
            try { File.Delete(src); } catch { }
        }
    }
}
