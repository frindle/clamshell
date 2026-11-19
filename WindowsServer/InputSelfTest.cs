using System.Text;
using System.Text.Json;

namespace Clamshell;

// `selftest-input <path>`: runs the pure input logic (Protocol.cs decode and
// InputCore) against the shared vectors in tests/vectors/input-v1.json. No Win32
// calls. Mirrors tests/ClamshellTests/InputVectorTests.swift. A missing or
// unreadable vector file is a failure, never a pass.
internal static class InputSelfTest
{
    private static int _failures, _passes;

    public static int Run(string? path)
    {
        if (string.IsNullOrEmpty(path))
        {
            Console.Error.WriteLine("FAIL: selftest-input needs the path to input-v1.json");
            return 1;
        }
        JsonElement root;
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            root = doc.RootElement.Clone();
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"FAIL: cannot read vectors at {path}: {e.Message}");
            return 1;
        }

        try
        {
            Constants(root);
            Frames(root);
            Ignored(root);
            Longer(root);
            Scrolls(root);
            Relatives(root);
            KeyFlags(root);
            Texts(root);
            TextSizes(root);
            Extra();
        }
        catch (Exception e)
        {
            Fail("harness", $"exception: {e}");
        }

        Console.WriteLine($"input selftest: {_passes} passed, {_failures} failed");
        return _failures == 0 && _passes > 0 ? 0 : 1;
    }

    // MARK: helpers

    private static void Check(string name, bool ok, string detail = "")
    {
        if (ok) { _passes++; Console.WriteLine($"PASS {name}"); }
        else Fail(name, detail);
    }

    private static void Fail(string name, string detail)
    {
        _failures++;
        Console.WriteLine($"FAIL {name}: {detail}");
    }

    private static IEnumerable<JsonElement> List(JsonElement root, string key) =>
        root.GetProperty(key).EnumerateArray();

    private static string S(JsonElement e, string key) => e.GetProperty(key).GetString()!;
    private static int I(JsonElement e, string key) => e.GetProperty(key).GetInt32();
    private static float F(JsonElement e, string key) => e.GetProperty(key).GetSingle();
    private static bool B(JsonElement e, string key) => e.GetProperty(key).GetBoolean();
    private static bool Flag(JsonElement e, string key) =>
        e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.True;
    private static byte[] Hex(string s) => s.Length == 0 ? Array.Empty<byte>() : Convert.FromHexString(s);

    private static readonly DisplayRect Screen = new(0, 0, 1000, 800);

    private static InputCore MakeCore() =>
        new(Screen, () => (500, 400), () => new[] { Screen });

    // Huge display so a relative move is never clamped: target - cursor == delta.
    private static InputCore HugeCore() =>
        new(new DisplayRect(-100000, -100000, 200000, 200000), () => (500, 400),
            () => new[] { new DisplayRect(-100000, -100000, 200000, 200000) });

    private static MessageType TypeNamed(JsonElement root, string name) =>
        (MessageType)(byte)root.GetProperty("messageTypes").GetProperty(name).GetInt32();

    private static InputMessage? DecodeFrame(byte[] frame) =>
        InputMessage.Decode((MessageType)frame[0], frame.AsSpan(5));

    private static string Describe(InputMessage? m) => m switch
    {
        null => "null",
        InputMessage.Text t => "Text:" + Convert.ToHexString(t.Data),
        _ => m.ToString()!,
    };

    private static string FmtActions(IEnumerable<InputAction> a) => "[" + string.Join(", ", a) + "]";

    private static byte[] Frame(MessageType t, byte[] payload)
    {
        var f = new byte[5 + payload.Length];
        f[0] = (byte)t;
        f[1] = (byte)(payload.Length >> 24);
        f[2] = (byte)(payload.Length >> 16);
        f[3] = (byte)(payload.Length >> 8);
        f[4] = (byte)payload.Length;
        payload.CopyTo(f, 5);
        return f;
    }

    private static InputMessage? Expected(JsonElement v) => S(v, "type") switch
    {
        "INPUT_MOUSE_MOVE" => new InputMessage.MouseMove(F(v, "x"), F(v, "y")),
        "INPUT_MOUSE_BUTTON" => new InputMessage.MouseButton((byte)I(v, "button"), B(v, "down"), F(v, "x"), F(v, "y")),
        "INPUT_KEY" => new InputMessage.Key((ushort)I(v, "macKeyCode"), B(v, "down"), BeU64(Hex(S(v, "flags")))),
        "INPUT_SCROLL" => new InputMessage.Scroll(F(v, "dx"), F(v, "dy")),
        "INPUT_MOUSE_RELATIVE" => new InputMessage.MouseRelative(F(v, "dx"), F(v, "dy")),
        "INPUT_MOUSE_BUTTON_AT_CURSOR" => new InputMessage.ButtonAtCursor((byte)I(v, "button"), B(v, "down")),
        "INPUT_TEXT" => new InputMessage.Text(Encoding.UTF8.GetBytes(S(v, "text"))),
        _ => null,
    };

    private static ulong BeU64(byte[] b)
    {
        ulong n = 0;
        foreach (var x in b) n = (n << 8) | x;
        return n;
    }

    // MARK: sections

    private static void Constants(JsonElement root)
    {
        Check("constants/maxTextBytes", I(root, "maxTextBytes") == InputCore.MaxTextBytes,
            $"{I(root, "maxTextBytes")} vs {InputCore.MaxTextBytes}");
        Check("constants/deltaCap", I(root, "deltaCap") == (int)InputCore.MaxDelta,
            $"{I(root, "deltaCap")} vs {InputCore.MaxDelta}");
        foreach (var p in root.GetProperty("messageTypes").EnumerateObject())
        {
            var expect = p.Name switch
            {
                "INPUT_MOUSE_MOVE" => MessageType.MouseMove,
                "INPUT_MOUSE_BUTTON" => MessageType.MouseButton,
                "INPUT_KEY" => MessageType.Key,
                "INPUT_SCROLL" => MessageType.Scroll,
                "INPUT_MOUSE_RELATIVE" => MessageType.MouseRelative,
                "INPUT_TEXT" => MessageType.Text,
                "INPUT_MOUSE_BUTTON_AT_CURSOR" => MessageType.MouseButtonAtCursor,
                _ => (MessageType)0,
            };
            Check($"messageTypes/{p.Name}", (byte)expect == p.Value.GetInt32(),
                $"{p.Value.GetInt32()} vs {(byte)expect}");
        }
    }

    private static void Frames(JsonElement root)
    {
        foreach (var v in List(root, "frames"))
        {
            var name = "frames/" + S(v, "name");
            var type = TypeNamed(root, S(v, "type"));
            var payload = Hex(S(v, "payload"));
            var frame = Hex(S(v, "frame"));
            Check(name + " frame bytes", Frame(type, payload).AsSpan().SequenceEqual(frame), "frame != type+len+payload");
            Check(name + " type byte", frame[0] == (byte)type, $"{frame[0]} vs {(byte)type}");
            var got = InputMessage.Decode(type, payload);
            var want = Expected(v);
            Check(name + " decode", Describe(got) == Describe(want), $"{Describe(got)} vs {Describe(want)}");
        }
    }

    private static void Ignored(JsonElement root)
    {
        foreach (var v in List(root, "ignored"))
        {
            var name = "ignored/" + S(v, "name");
            var frame = Hex(S(v, "frame"));
            Check(name + " payload vs frame", Hex(S(v, "payload")).AsSpan().SequenceEqual(frame.AsSpan(5)),
                "payload != frame body");
            var m = DecodeFrame(frame);
            if (m is null) { Check(name, true); continue; } // dropped at decode
            var core = MakeCore();
            var acts = core.Process(m);
            Check(name, acts.Count == 0 && core.HeldButtonCount == 0 && core.HeldKeyCount == 0,
                $"actions {FmtActions(acts)} buttons {core.HeldButtonCount} keys {core.HeldKeyCount}");
        }
    }

    private static void Longer(JsonElement root)
    {
        var frames = List(root, "frames").ToList();
        foreach (var v in List(root, "longer"))
        {
            var name = "longer/" + S(v, "name");
            var target = frames.First(f => S(f, "name") == S(v, "decodesAs"));
            var a = DecodeFrame(Hex(S(v, "frame")));
            var b = DecodeFrame(Hex(S(target, "frame")));
            Check(name, a is not null && Describe(a) == Describe(b), $"{Describe(a)} vs {Describe(b)}");
        }
    }

    private static void Scrolls(JsonElement root)
    {
        foreach (var v in List(root, "scroll"))
        {
            var name = "scroll/" + S(v, "name");
            if (DecodeFrame(Hex(S(v, "frame"))) is not InputMessage.Scroll m) { Fail(name, "not a scroll"); continue; }
            var got = MakeCore().Process(m);
            if (Flag(v, "ignored")) { Check(name, got.Count == 0, FmtActions(got)); continue; }
            Check(name, got.Count == 1 && got[0] is InputAction.Scroll s && s.Dx == I(v, "dxUsed") && s.Dy == I(v, "dyUsed"),
                $"{FmtActions(got)} want dx {I(v, "dxUsed")} dy {I(v, "dyUsed")}");
        }
    }

    private static void Relatives(JsonElement root)
    {
        foreach (var v in List(root, "relative"))
        {
            var name = "relative/" + S(v, "name");
            if (DecodeFrame(Hex(S(v, "frame"))) is not InputMessage.MouseRelative m) { Fail(name, "not relative"); continue; }
            var got = HugeCore().Process(m);
            if (Flag(v, "ignored")) { Check(name, got.Count == 0, FmtActions(got)); continue; }
            Check(name, got.Count == 1 && got[0] is InputAction.MoveTo mv
                  && mv.X - 500 == I(v, "dxUsed") && mv.Y - 400 == I(v, "dyUsed"),
                $"{FmtActions(got)} want dx {I(v, "dxUsed")} dy {I(v, "dyUsed")}");
        }
    }

    private static void KeyFlags(JsonElement root)
    {
        // The "keyFlags" vectors give the Mac modifier bits a Mac host applies to a
        // key event. They do not apply on Windows: modifier state comes only from
        // the separate modifier key events (flags are ignored), so there is nothing
        // to check here beyond the vector shape.
        foreach (var v in List(root, "keyFlags"))
        {
            var name = "keyFlags/" + S(v, "name");
            Check(name + " (not applicable on Windows: flags ignored)",
                Hex(S(v, "flags")).Length == 8 && Hex(S(v, "used")).Length == 8, "bad hex");
            // Flags must not change what is injected.
            var a = MakeCore().Process(new InputMessage.Key(0, true, BeU64(Hex(S(v, "flags")))));
            var b = MakeCore().Process(new InputMessage.Key(0, true, 0));
            Check(name + " flags ignored", FmtActions(a) == FmtActions(b), $"{FmtActions(a)} vs {FmtActions(b)}");
        }
        Check("keyFlags/modifierMask shape", Hex(S(root, "modifierMask")).Length == 8, "bad mask");
    }

    private static List<string> Steps(JsonElement root, List<InputAction> acts)
    {
        var names = new Dictionary<ushort, string>();
        foreach (var p in root.GetProperty("textKeys").EnumerateObject())
        {
            var vk = MacKeyMap.ToWindows((ushort)p.Value.GetInt32());
            if (vk is not null) names[vk.Value] = p.Name;
        }
        var outp = new List<string>();
        int i = 0;
        while (i < acts.Count)
        {
            if (acts[i] is InputAction.UnicodeKey { Down: true } d
                && i + 1 < acts.Count && acts[i + 1] is InputAction.UnicodeKey { Down: false } u && u.Unit == d.Unit)
            {
                char c = (char)d.Unit;
                if (outp.Count > 0 && outp[^1].StartsWith("text:")) outp[^1] += c;
                else outp.Add("text:" + c);
                i += 2;
            }
            else if (acts[i] is InputAction.Key { Down: true } k
                && i + 1 < acts.Count && acts[i + 1] is InputAction.Key { Down: false } ku && ku.Vk == k.Vk)
            {
                outp.Add("key:" + (names.TryGetValue(k.Vk, out var n) ? n : $"vk{k.Vk}"));
                i += 2;
            }
            else { outp.Add("other:" + acts[i]); i++; }
        }
        return outp;
    }

    private static void Texts(JsonElement root)
    {
        foreach (var v in List(root, "text"))
        {
            var name = "text/" + S(v, "name");
            var payload = Hex(S(v, "utf8"));
            if (DecodeFrame(Frame(MessageType.Text, payload)) is not InputMessage.Text t) { Fail(name, "decode"); continue; }
            var got = MakeCore().Process(t);
            var steps = v.TryGetProperty("steps", out var st) ? st.EnumerateArray().ToList() : new List<JsonElement>();
            if (Flag(v, "ignored") || steps.Count == 0) { Check(name, got.Count == 0, FmtActions(got)); continue; }
            var want = steps.Select(s => s.TryGetProperty("text", out var tx) ? "text:" + tx.GetString() : "key:" + S(s, "key")).ToList();
            var have = Steps(root, got);
            Check(name, have.SequenceEqual(want), $"[{string.Join(" | ", have)}] vs [{string.Join(" | ", want)}]");
            Check(name + " no lone surrogate split", got.OfType<InputAction.UnicodeKey>().Count() % 2 == 0, "odd unit count");
        }
    }

    private static void TextSizes(JsonElement root)
    {
        foreach (var v in List(root, "textSize"))
        {
            var name = "textSize/" + S(v, "name");
            var payload = Enumerable.Repeat(Hex(S(v, "repeatByte"))[0], I(v, "count")).ToArray();
            var got = MakeCore().Text(payload);
            if (Flag(v, "ignored")) { Check(name, got.Count == 0, $"{got.Count} actions"); continue; }
            int typed = got.Count(a => a is InputAction.UnicodeKey { Down: true });
            Check(name, typed == I(v, "typedLength"), $"{typed} vs {I(v, "typedLength")}");
        }
    }

    // Windows-specific behaviour not covered by the shared vectors.
    private static void Extra()
    {
        // Relative move clamps to the display containing the cursor, edge - 1.
        var r = MakeCore().MouseRelative(10000, 10000);
        Check("extra/relative clamp", r.Count == 1 && r[0] is InputAction.MoveTo { X: 999, Y: 799 }, FmtActions(r));

        // Command and Control both map to VK_CONTROL: it is released only when both are up.
        var core = MakeCore();
        ushort cmd = 55, ctrl = 59;
        var vkCmd = MacKeyMap.ToWindows(cmd);
        var vkCtl = MacKeyMap.ToWindows(ctrl);
        Check("extra/cmd+ctrl share a VK", vkCmd is not null && vkCmd == vkCtl, $"{vkCmd} vs {vkCtl}");
        if (vkCmd is not null && vkCmd == vkCtl)
        {
            core.Key(cmd, true);
            core.Key(ctrl, true);
            var up1 = core.Key(cmd, false);
            var up2 = core.Key(ctrl, false);
            Check("extra/shared VK released once", up1.Count == 0 && up2.Count == 1
                && up2[0] is InputAction.Key { Down: false } && core.HeldKeyCount == 0,
                $"{FmtActions(up1)} then {FmtActions(up2)}");
        }

        // Session end: buttons are released first, then keys, and state is cleared.
        var c2 = MakeCore();
        c2.Key(0, true);       // mac 'A'
        c2.ButtonAtCursor(0, true);
        var rel = c2.ReleaseAll();
        bool order = rel.Count == 2 && rel[0] is InputAction.Button { Down: false } && rel[1] is InputAction.Key { Down: false };
        Check("extra/release order", order, FmtActions(rel));
        Check("extra/release clears", c2.HeldButtonCount == 0 && c2.HeldKeyCount == 0 && c2.ReleaseAll().Count == 0, "state remained");

        // Held modifiers do not alter typed text (units go out as UNICODE keys, not VKs).
        var c3 = MakeCore();
        c3.Key(56, true); // shift
        var typed = c3.Text(Encoding.UTF8.GetBytes("a\U0001F600"));
        Check("extra/text with modifier held", typed.Count == 6 && typed.All(a => a is InputAction.UnicodeKey),
            FmtActions(typed));

        // Invalid UTF-8 is refused whole.
        Check("extra/invalid utf8", MakeCore().Text(new byte[] { 0x61, 0xFF }).Count == 0, "typed something");
    }
}
