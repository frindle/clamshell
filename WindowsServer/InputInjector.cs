using System.Runtime.InteropServices;

namespace Clamshell;

// Injects client input via SendInput. Client coordinates are normalized
// (0..1, origin top-left) in the streamed display's space — the mirror of the
// Mac InputInjector. InputCore decides what to do (drops, caps, key holders,
// text splitting); this class only carries the resulting actions out.
//
// Absolute mouse positioning uses the VIRTUALDESK flag: SendInput's 0..65535
// range spans the whole virtual desktop, so a point in display pixels is mapped
// into virtual-desktop units (ToAbsolute). A relative move is turned into an
// absolute move to the clamped target in that same space; the cursor position
// and the display rectangles come from the same Win32 pixel space the process
// runs in.
//
// Injection and release share one lock, and nothing is injected once ReleaseAll
// has run (session over).
internal sealed class InputInjector
{
    private readonly InputCore _core;
    private readonly object _lock = new();
    private bool _closed;
    private readonly int _vx, _vy, _vw, _vh; // virtual-desktop origin/size (px)

    public InputInjector(DisplayRect bounds)
    {
        _vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
        _vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
        _vw = Math.Max(1, GetSystemMetrics(SM_CXVIRTUALSCREEN));
        _vh = Math.Max(1, GetSystemMetrics(SM_CYVIRTUALSCREEN));
        _core = new InputCore(bounds, CursorPosition, () => DisplayEnum.Active().Select(d => d.Bounds).ToList());
        bool warned = false;
        _core.OnUnmapped = code =>
        {
            if (warned) return;
            warned = true;
            Log.Line($"WARNING — unmapped mac key code {code} (and possibly others); ignoring");
        };
    }

    private static (double X, double Y) CursorPosition() =>
        GetCursorPos(out var pt) ? (pt.x, pt.y) : (0, 0);

    /// <summary>Applies one decoded input message. Nothing after ReleaseAll.</summary>
    public void Handle(InputMessage message)
    {
        lock (_lock)
        {
            if (_closed) return;
            Send(_core.Process(message));
        }
    }

    /// <summary>End of session: releases every button (at the cursor) and key this
    /// client still has down, then injects nothing more.</summary>
    public void ReleaseAll()
    {
        lock (_lock)
        {
            if (_closed) return;
            _closed = true;
            Send(_core.ReleaseAll());
        }
    }

    private (int ax, int ay) ToAbsolute(double px, double py)
    {
        int ax = (int)Math.Round((px - _vx) * 65535.0 / _vw);
        int ay = (int)Math.Round((py - _vy) * 65535.0 / _vh);
        return (Math.Clamp(ax, 0, 65535), Math.Clamp(ay, 0, 65535));
    }

    private void Send(List<InputAction> actions)
    {
        if (actions.Count == 0) return;
        var batch = new List<INPUT>(actions.Count);
        foreach (var a in actions)
        {
            switch (a)
            {
                case InputAction.MoveTo m:
                    var (ax, ay) = ToAbsolute(m.X, m.Y);
                    batch.Add(Mouse(ax, ay, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK, 0));
                    break;
                case InputAction.Button b:
                    batch.Add(ButtonInput(b.Number, b.Down));
                    break;
                case InputAction.Scroll s:
                    if (s.Dy != 0) batch.Add(Mouse(0, 0, MOUSEEVENTF_WHEEL, s.Dy));
                    if (s.Dx != 0) batch.Add(Mouse(0, 0, MOUSEEVENTF_HWHEEL, s.Dx));
                    break;
                case InputAction.Key k:
                    batch.Add(Keyboard(k.Vk, 0, k.Down ? 0u : KEYEVENTF_KEYUP));
                    break;
                case InputAction.UnicodeKey u:
                    batch.Add(Keyboard(0, u.Unit, KEYEVENTF_UNICODE | (u.Down ? 0u : KEYEVENTF_KEYUP)));
                    break;
            }
        }
        // As few SendInput calls as practical; very long text goes in slices.
        const int slice = 4096;
        var all = batch.ToArray();
        for (int i = 0; i < all.Length; i += slice)
        {
            int n = Math.Min(slice, all.Length - i);
            var part = i == 0 && n == all.Length ? all : all.AsSpan(i, n).ToArray();
            SendInput((uint)part.Length, part, Marshal.SizeOf<INPUT>());
        }
    }

    private static INPUT ButtonInput(int number, bool down)
    {
        uint flags;
        int data = 0;
        switch (number)
        {
            case 0: flags = down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP; break;
            case 1: flags = down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP; break;
            case 2: flags = down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP; break;
            default: // 3 = back (X1), 4 = forward (X2)
                flags = down ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP;
                data = number == 3 ? XBUTTON1 : XBUTTON2;
                break;
        }
        return Mouse(0, 0, flags, data);
    }

    private static INPUT Mouse(int dx, int dy, uint flags, int mouseData) => new()
    {
        type = INPUT_MOUSE,
        U = new INPUTUNION { mi = new MOUSEINPUT { dx = dx, dy = dy, mouseData = mouseData, dwFlags = flags } },
    };

    private static INPUT Keyboard(ushort vk, ushort scan, uint flags) => new()
    {
        type = INPUT_KEYBOARD,
        U = new INPUTUNION { ki = new KEYBDINPUT { wVk = vk, wScan = scan, dwFlags = flags } },
    };

    // MARK: - Win32 interop

    private const int SM_XVIRTUALSCREEN = 76, SM_YVIRTUALSCREEN = 77,
        SM_CXVIRTUALSCREEN = 78, SM_CYVIRTUALSCREEN = 79;
    private const int INPUT_MOUSE = 0, INPUT_KEYBOARD = 1;
    private const uint MOUSEEVENTF_MOVE = 0x0001, MOUSEEVENTF_LEFTDOWN = 0x0002,
        MOUSEEVENTF_LEFTUP = 0x0004, MOUSEEVENTF_RIGHTDOWN = 0x0008, MOUSEEVENTF_RIGHTUP = 0x0010,
        MOUSEEVENTF_MIDDLEDOWN = 0x0020, MOUSEEVENTF_MIDDLEUP = 0x0040,
        MOUSEEVENTF_XDOWN = 0x0080, MOUSEEVENTF_XUP = 0x0100,
        MOUSEEVENTF_WHEEL = 0x0800, MOUSEEVENTF_HWHEEL = 0x1000, MOUSEEVENTF_ABSOLUTE = 0x8000,
        MOUSEEVENTF_VIRTUALDESK = 0x4000;
    private const int XBUTTON1 = 1, XBUTTON2 = 2;
    private const uint KEYEVENTF_KEYUP = 0x0002, KEYEVENTF_UNICODE = 0x0004;

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT { public int dx, dy; public int mouseData; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)]
    private struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT { public int type; public INPUTUNION U; }
    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int x, y; }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int nIndex);
    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT lpPoint);
}
