using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace Clamshell;

// Win32 surface shared by the shared-desk pieces (EdgeController,
// CarryDetector, WindowSource, HandoffManager). Public, documented user32 /
// dwmapi calls only.
internal static class WinNative
{
    // MARK: - Hooks

    public const int WH_KEYBOARD_LL = 13, WH_MOUSE_LL = 14;
    public const int WM_MOUSEMOVE = 0x0200, WM_LBUTTONDOWN = 0x0201, WM_LBUTTONUP = 0x0202,
        WM_RBUTTONDOWN = 0x0204, WM_RBUTTONUP = 0x0205, WM_MBUTTONDOWN = 0x0207, WM_MBUTTONUP = 0x0208,
        WM_MOUSEWHEEL = 0x020A, WM_XBUTTONDOWN = 0x020B, WM_XBUTTONUP = 0x020C, WM_MOUSEHWHEEL = 0x020E,
        WM_KEYDOWN = 0x0100, WM_KEYUP = 0x0101, WM_CHAR = 0x0102, WM_SYSKEYDOWN = 0x0104, WM_SYSKEYUP = 0x0105,
        WM_NCLBUTTONDOWN = 0x00A1, WM_CLOSE = 0x0010;
    public const int HTCAPTION = 2;
    public const uint LLKHF_EXTENDED = 0x01, LLKHF_UP = 0x80;

    public delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData, flags, time; public nuint dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public nuint dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left, Top, Right, Bottom;
        public int Width => Right - Left;
        public int Height => Bottom - Top;
        public Rect ToRect() => new(Left, Top, Width, Height);
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetWindowsHookEx(int idHook, HookProc fn, IntPtr hMod, uint threadId);
    [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] public static extern IntPtr GetModuleHandle(string? name);

    // MARK: - Cursor

    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
    public static bool LeftButtonDown() => (GetAsyncKeyState(0x01) & 0x8000) != 0;
    public static (double X, double Y) Cursor() => GetCursorPos(out var p) ? (p.X, p.Y) : (0, 0);

    /// Monitor rectangles in virtual-screen pixels (per-monitor DPI aware).
    public static List<Rect> Displays() =>
        Screen.AllScreens.Select(s => new Rect(s.Bounds.X, s.Bounds.Y, s.Bounds.Width, s.Bounds.Height)).ToList();

    public static Rect PrimaryDisplay()
    {
        var b = Screen.PrimaryScreen?.Bounds ?? new System.Drawing.Rectangle(0, 0, 1920, 1080);
        return new Rect(b.X, b.Y, b.Width, b.Height);
    }

    public static Rect VirtualScreen()
    {
        var b = SystemInformation.VirtualScreen;
        return new Rect(b.X, b.Y, b.Width, b.Height);
    }

    // MARK: - Windows

    public const uint GA_ROOT = 2;
    public const uint SWP_NOSIZE = 0x0001, SWP_NOZORDER = 0x0004, SWP_NOACTIVATE = 0x0010;
    public const int GWL_EXSTYLE = -20;
    public const uint WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOPMOST = 0x8, WS_EX_LAYERED = 0x80000;

    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern IntPtr ChildWindowFromPointEx(IntPtr parent, POINT p, uint flags);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int index);
    public const uint CWP_SKIPINVISIBLE = 0x1, CWP_SKIPDISABLED = 0x2, CWP_SKIPTRANSPARENT = 0x4;

    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
    private const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;

    /// The visible frame (what Windows.Graphics.Capture captures — no drop
    /// shadow), falling back to GetWindowRect.
    public static RECT? Frame(IntPtr h)
    {
        if (!IsWindow(h)) return null;
        if (DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, out var r, Marshal.SizeOf<RECT>()) == 0 && r.Width > 0) return r;
        return GetWindowRect(h, out r) ? r : null;
    }

    public static string Title(IntPtr h)
    {
        var sb = new StringBuilder(512);
        GetWindowText(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static string ClassName(IntPtr h)
    {
        var sb = new StringBuilder(256);
        GetClassName(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static uint Pid(IntPtr h) { GetWindowThreadProcessId(h, out var pid); return pid; }

    public static string AppName(uint pid)
    {
        try
        {
            using var p = Process.GetProcessById((int)pid);
            try { if (p.MainModule?.FileVersionInfo.FileDescription is { Length: > 0 } d) return d; } catch { }
            return p.ProcessName;
        }
        catch { return "app"; }
    }

    /// Top-level window under a screen point, skipping the desktop and
    /// taskbar (dragging those isn't "carrying a window").
    public static IntPtr RootWindowAt(double x, double y)
    {
        var h = WindowFromPoint(new POINT { X = (int)x, Y = (int)y });
        if (h == IntPtr.Zero) return IntPtr.Zero;
        h = GetAncestor(h, GA_ROOT);
        if (h == IntPtr.Zero) return IntPtr.Zero;
        string cls = ClassName(h);
        if (cls is "Progman" or "WorkerW" or "Shell_TrayWnd" or "Shell_SecondaryTrayWnd") return IntPtr.Zero;
        return h;
    }

    // MARK: - Keyboard

    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);
    [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint threadId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int ToUnicodeEx(uint vk, uint scan, byte[] state, StringBuilder buf, int cap, uint flags, IntPtr hkl);

    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO
    {
        public int cbSize; public uint flags;
        public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
        public RECT rcCaret;
    }
    [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint threadId, ref GUITHREADINFO info);

    public static IntPtr FocusOf(IntPtr root)
    {
        uint tid = GetWindowThreadProcessId(root, out _);
        var gi = new GUITHREADINFO { cbSize = Marshal.SizeOf<GUITHREADINFO>() };
        return GetGUIThreadInfo(tid, ref gi) && gi.hwndFocus != IntPtr.Zero ? gi.hwndFocus : IntPtr.Zero;
    }

    // MARK: - DPI

    [DllImport("user32.dll")] private static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    private static readonly IntPtr PerMonitorAwareV2 = new(-4);

    /// The shared desk works in physical pixels (hook points, SetCursorPos,
    /// window rects all agree only when the process is per-monitor aware).
    public static void EnsurePerMonitorDpi()
    {
        try { SetProcessDpiAwarenessContext(PerMonitorAwareV2); } catch { }
    }
}
