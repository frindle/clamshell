using System.Text;

namespace Clamshell;

// Pure decision layer for injected input, the C# counterpart of InputCore.swift.
// Everything here comes from the network, so the rules (what is dropped,
// clamped or split) live here with no Win32 calls: it takes decoded messages
// and returns plain actions, and InputInjector carries them out with SendInput.
// `selftest-input` drives it against tests/vectors/input-v1.json.

internal abstract record InputAction
{
    /// <summary>Move the cursor to this point (pixels, the display-bounds space).</summary>
    public sealed record MoveTo(double X, double Y) : InputAction;
    /// <summary>Press or release a button where the cursor is. 0 left, 1 right,
    /// 2 middle, 3 X1 (back), 4 X2 (forward).</summary>
    public sealed record Button(int Number, bool Down) : InputAction;
    /// <summary>Press or release a Windows virtual key.</summary>
    public sealed record Key(ushort Vk, bool Down) : InputAction;
    /// <summary>One UTF-16 unit typed as a character (KEYEVENTF_UNICODE).</summary>
    public sealed record UnicodeKey(ushort Unit, bool Down) : InputAction;
    /// <summary>Wheel deltas already capped: Dy vertical, Dx horizontal.</summary>
    public sealed record Scroll(int Dx, int Dy) : InputAction;
}

internal sealed class InputCore
{
    public const int MaxButton = 4;
    public const int MaxTextBytes = 16 * 1024;
    public const double MaxDelta = 10_000;
    public const ushort VkReturn = 0x0D, VkTab = 0x09;

    private readonly DisplayRect _bounds;
    private readonly Func<(double X, double Y)> _cursor;
    private readonly Func<IReadOnlyList<DisplayRect>> _displays;

    private readonly List<int> _heldButtons = new();           // press order
    private readonly HashSet<ushort> _heldMac = new();          // mac codes down
    private readonly Dictionary<ushort, int> _holders = new();  // Windows VK -> mac keys holding it
    private readonly List<ushort> _vkOrder = new();              // VKs in the order they went down
    private (double X, double Y) _last;

    /// <summary>Called once per unmapped mac key code (for a log line).</summary>
    public Action<ushort>? OnUnmapped;

    /// <param name="bounds">The streamed display, in the same pixel space as the cursor.</param>
    /// <param name="cursor">Where the cursor is now.</param>
    /// <param name="displays">Every display's rectangle.</param>
    public InputCore(DisplayRect bounds, Func<(double X, double Y)> cursor, Func<IReadOnlyList<DisplayRect>> displays)
    {
        _bounds = bounds;
        _cursor = cursor;
        _displays = displays;
        _last = (bounds.X, bounds.Y);
    }

    public int HeldButtonCount => _heldButtons.Count;
    public int HeldKeyCount => _heldMac.Count;

    public List<InputAction> Process(InputMessage m) => m switch
    {
        InputMessage.MouseMove mv => MouseMove(mv.X, mv.Y),
        InputMessage.MouseButton b => MouseButton(b.Button, b.Down, b.X, b.Y),
        InputMessage.ButtonAtCursor c => ButtonAtCursor(c.Button, c.Down),
        InputMessage.Key k => Key(k.MacKeyCode, k.Down),
        InputMessage.Scroll s => Scroll(s.Dx, s.Dy),
        InputMessage.MouseRelative r => MouseRelative(r.Dx, r.Dy),
        InputMessage.Text t => Text(t.Data),
        _ => new List<InputAction>(),
    };

    // MARK: pointer

    private InputAction.MoveTo Map(float x, float y)
    {
        double cx = Math.Clamp(x, 0f, 1f), cy = Math.Clamp(y, 0f, 1f);
        var p = (X: _bounds.X + cx * _bounds.Width, Y: _bounds.Y + cy * _bounds.Height);
        _last = p;
        return new InputAction.MoveTo(p.X, p.Y);
    }

    public List<InputAction> MouseMove(float x, float y)
    {
        if (!float.IsFinite(x) || !float.IsFinite(y)) return new();
        return new() { Map(x, y) };
    }

    public List<InputAction> MouseButton(byte button, bool down, float x, float y)
    {
        if (!float.IsFinite(x) || !float.IsFinite(y) || button > MaxButton) return new();
        var move = Map(x, y);
        return new() { move, ButtonEvent(button, down) };
    }

    /// <summary>A press or release where the cursor is now: no move.</summary>
    public List<InputAction> ButtonAtCursor(byte button, bool down)
    {
        if (button > MaxButton) return new();
        return new() { ButtonEvent(button, down) };
    }

    private InputAction ButtonEvent(int b, bool down)
    {
        _heldButtons.Remove(b);
        if (down) _heldButtons.Add(b);
        return new InputAction.Button(b, down);
    }

    public List<InputAction> MouseRelative(float dx, float dy)
    {
        if (!float.IsFinite(dx) || !float.IsFinite(dy)) return new();
        double ddx = Math.Clamp((double)dx, -MaxDelta, MaxDelta);
        double ddy = Math.Clamp((double)dy, -MaxDelta, MaxDelta);
        var cur = _cursor();
        double px = cur.X + ddx, py = cur.Y + ddy;
        var displays = _displays().Where(d => d.Width > 0 && d.Height > 0).ToList();
        if (!displays.Any(d => Contains(d, px, py)))
        {
            // The display the cursor is on, else the first, else the streamed one.
            DisplayRect home = _bounds;
            int at = displays.FindIndex(d => Contains(d, cur.X, cur.Y));
            if (at >= 0) home = displays[at];
            else if (displays.Count > 0) home = displays[0];
            if (home.Width > 0 && home.Height > 0)
            {
                // Stay strictly inside (the far edge is exclusive).
                px = Math.Clamp(px, home.X, home.X + home.Width - 1);
                py = Math.Clamp(py, home.Y, home.Y + home.Height - 1);
            }
            else { px = cur.X; py = cur.Y; }
        }
        _last = (px, py);
        return new() { new InputAction.MoveTo(px, py) };
    }

    private static bool Contains(DisplayRect r, double x, double y) =>
        x >= r.X && x < r.X + r.Width && y >= r.Y && y < r.Y + r.Height;

    // MARK: wheel

    /// <summary>A non-finite delta counts as 0, each is capped at ±10 000; nothing
    /// when both come out 0.</summary>
    public List<InputAction> Scroll(float dx, float dy)
    {
        static int Sane(float v) => float.IsFinite(v) ? (int)Math.Clamp(v, -(float)MaxDelta, (float)MaxDelta) : 0;
        int x = Sane(dx), y = Sane(dy);
        var result = new List<InputAction>();
        if (x != 0 || y != 0) result.Add(new InputAction.Scroll(x, y));
        return result;
    }

    // MARK: keyboard

    // cgEventFlags are ignored on Windows: the client sends each modifier as its
    // own key event (PROTOCOL.md "Modifier keys are also sent as keys").
    public List<InputAction> Key(ushort macKeyCode, bool down)
    {
        if (macKeyCode > 0xFF) return new();
        var mapped = MacKeyMap.ToWindows(macKeyCode);
        if (mapped is null) { OnUnmapped?.Invoke(macKeyCode); return new(); }
        ushort vk = mapped.Value;

        // Command and Control share VK_CONTROL: count the mac keys holding a
        // Windows key and release it only when the last holder lets go.
        if (down)
        {
            if (_heldMac.Add(macKeyCode))
            {
                _holders[vk] = _holders.GetValueOrDefault(vk) + 1;
                if (!_vkOrder.Contains(vk)) _vkOrder.Add(vk);
            }
            return new() { new InputAction.Key(vk, true) };
        }
        if (_heldMac.Remove(macKeyCode))
        {
            int left = _holders.GetValueOrDefault(vk) - 1;
            if (left > 0) { _holders[vk] = left; return new(); }
            _holders.Remove(vk);
            _vkOrder.Remove(vk);
            return new() { new InputAction.Key(vk, false) };
        }
        // An up for a key this client never pressed: pass it on unless another
        // mac key still holds the same Windows key.
        var stray = new List<InputAction>();
        if (_holders.GetValueOrDefault(vk) == 0) stray.Add(new InputAction.Key(vk, false));
        return stray;
    }

    // MARK: text

    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    /// <summary>Unicode text -> typing actions. Nothing for oversize or invalid
    /// UTF-8. LF, CR and CR LF are one Return press, tab one Tab press, other
    /// control characters (U+0000-001F, U+007F-009F) are left out; every other
    /// UTF-16 unit is one down and one up as a character.</summary>
    public List<InputAction> Text(byte[] payload)
    {
        var actions = new List<InputAction>();
        if (payload.Length > MaxTextBytes) return actions;
        string s;
        try { s = StrictUtf8.GetString(payload); }
        catch (ArgumentException) { return actions; }

        void Press(ushort vk)
        {
            actions.Add(new InputAction.Key(vk, true));
            actions.Add(new InputAction.Key(vk, false));
        }
        for (int i = 0; i < s.Length; i++)
        {
            char c = s[i];
            switch (c)
            {
                case '\r':
                    if (i + 1 < s.Length && s[i + 1] == '\n') i++;
                    Press(VkReturn);
                    break;
                case '\n': Press(VkReturn); break;
                case '\t': Press(VkTab); break;
                default:
                    if (c < 0x20 || c == 0x7F || (c >= 0x80 && c < 0xA0)) break;
                    actions.Add(new InputAction.UnicodeKey(c, true));
                    actions.Add(new InputAction.UnicodeKey(c, false));
                    break;
            }
        }
        return actions;
    }

    // MARK: release

    /// <summary>Ups for everything this client still has down: buttons first (at
    /// the cursor), then keys, newest first. Clears the held state.</summary>
    public List<InputAction> ReleaseAll()
    {
        var actions = new List<InputAction>();
        for (int i = _heldButtons.Count - 1; i >= 0; i--)
            actions.Add(new InputAction.Button(_heldButtons[i], false));
        for (int i = _vkOrder.Count - 1; i >= 0; i--)
            actions.Add(new InputAction.Key(_vkOrder[i], false));
        _heldButtons.Clear();
        _heldMac.Clear();
        _holders.Clear();
        _vkOrder.Clear();
        return actions;
    }
}
