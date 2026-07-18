using System.Runtime.InteropServices;

namespace Clamshell;

// Injects client input via SendInput. Client coordinates are normalized
// (0..1, origin top-left) in the streamed display's space — the mirror of the
// Mac InputInjector, which maps into CGDisplayBounds and posts CGEvents.
//
// Absolute mouse positioning uses the VIRTUALDESK flag: SendInput's 0..65535
// range spans the whole virtual desktop, so we map the normalized point into
// the target display's rectangle first, then into virtual-desktop units.
internal sealed class InputInjector
{
    private readonly DisplayRect _bounds;
    private readonly int _vx, _vy, _vw, _vh; // virtual-desktop origin/size (px)
    private bool _warnedUnmapped;

    public InputInjector(DisplayRect bounds)
    {
        _bounds = bounds;
        _vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
        _vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
        _vw = Math.Max(1, GetSystemMetrics(SM_CXVIRTUALSCREEN));
        _vh = Math.Max(1, GetSystemMetrics(SM_CYVIRTUALSCREEN));
    }

    private (int ax, int ay) ToAbsolute(float nx, float ny)
    {
        float cx = Math.Clamp(nx, 0f, 1f), cy = Math.Clamp(ny, 0f, 1f);
        double px = _bounds.X + cx * _bounds.Width;
        double py = _bounds.Y + cy * _bounds.Height;
        int ax = (int)Math.Round((px - _vx) * 65535.0 / _vw);
        int ay = (int)Math.Round((py - _vy) * 65535.0 / _vh);
        return (Math.Clamp(ax, 0, 65535), Math.Clamp(ay, 0, 65535));
    }

    public void MouseMove(float x, float y)
    {
        var (ax, ay) = ToAbsolute(x, y);
        SendMouse(ax, ay, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK, 0);
    }

    public void MouseButton(byte button, bool down, float x, float y)
    {
        var (ax, ay) = ToAbsolute(x, y);
        uint flags = button == 1
            ? (down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP)
            : (down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP);
        SendMouse(ax, ay, MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK | flags, 0);
    }

    public void Scroll(float dx, float dy)
    {
        // Mac sends pixel wheel deltas; Win32 wheel is signed with WHEEL_DELTA=120
        // per notch. Forward the pixel delta directly (approximate), clamped.
        static int Sane(float v) => float.IsFinite(v) ? (int)Math.Clamp(v, -10000f, 10000f) : 0;
        int wy = Sane(dy), wx = Sane(dx);
        if (wy != 0) SendMouse(0, 0, MOUSEEVENTF_WHEEL, wy);
        if (wx != 0) SendMouse(0, 0, MOUSEEVENTF_HWHEEL, wx);
    }

    public void Key(ushort macKeyCode, bool down, ulong _macFlags)
    {
        // We rely on the client sending explicit modifier key up/down events, so
        // the mac cgEventFlags bitmask is ignored (mapping it too would
        // double-apply modifiers). Translate the key code and inject.
        var vk = MacKeyMap.ToWindows(macKeyCode);
        if (vk is null)
        {
            if (!_warnedUnmapped)
            {
                _warnedUnmapped = true;
                Log.Line($"WARNING — unmapped mac key code {macKeyCode} (and possibly others); ignoring");
            }
            return;
        }
        var inp = new INPUT
        {
            type = INPUT_KEYBOARD,
            U = new INPUTUNION
            {
                ki = new KEYBDINPUT
                {
                    wVk = vk.Value,
                    dwFlags = down ? 0u : KEYEVENTF_KEYUP,
                }
            }
        };
        SendOne(inp);
    }

    private void SendMouse(int dx, int dy, uint flags, int mouseData)
    {
        var inp = new INPUT
        {
            type = INPUT_MOUSE,
            U = new INPUTUNION
            {
                mi = new MOUSEINPUT { dx = dx, dy = dy, mouseData = mouseData, dwFlags = flags }
            }
        };
        SendOne(inp);
    }

    private static void SendOne(INPUT inp)
    {
        var arr = new[] { inp };
        SendInput(1, arr, Marshal.SizeOf<INPUT>());
    }

    // MARK: - Win32 interop

    private const int SM_XVIRTUALSCREEN = 76, SM_YVIRTUALSCREEN = 77,
        SM_CXVIRTUALSCREEN = 78, SM_CYVIRTUALSCREEN = 79;
    private const int INPUT_MOUSE = 0, INPUT_KEYBOARD = 1;
    private const uint MOUSEEVENTF_MOVE = 0x0001, MOUSEEVENTF_LEFTDOWN = 0x0002,
        MOUSEEVENTF_LEFTUP = 0x0004, MOUSEEVENTF_RIGHTDOWN = 0x0008, MOUSEEVENTF_RIGHTUP = 0x0010,
        MOUSEEVENTF_WHEEL = 0x0800, MOUSEEVENTF_HWHEEL = 0x1000, MOUSEEVENTF_ABSOLUTE = 0x8000,
        MOUSEEVENTF_VIRTUALDESK = 0x4000;
    private const uint KEYEVENTF_KEYUP = 0x0002;

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT { public int dx, dy; public int mouseData; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)]
    private struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT { public int type; public INPUTUNION U; }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int nIndex);
}
