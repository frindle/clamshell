using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace Clamshell;

// Enumerates capturable top-level windows via Win32 (EnumWindows), the
// Windows-host counterpart to Sources/Clamshell/WindowHandoff/WindowList.swift
// on the Mac side. First slice of Window Handoff (PROTOCOL.md "Window Handoff
// (v2, PROPOSED)") — proves window-level enumeration works here before the
// capture/stream/receiver pipeline is built. `ClamshellServer windowlist`.
internal sealed record WindowInfo(IntPtr Handle, string AppName, string Title, int Width, int Height);

internal static class WindowEnum
{
    public static List<WindowInfo> Capturable()
    {
        var result = new List<WindowInfo>();
        int selfPid = Environment.ProcessId;
        EnumWindowsProc cb = (IntPtr hWnd, IntPtr _) =>
        {
            if (!IsWindowVisible(hWnd)) return true;

            int len = GetWindowTextLength(hWnd);
            if (len == 0) return true;
            var sb = new StringBuilder(len + 1);
            GetWindowText(hWnd, sb, sb.Capacity);
            string title = sb.ToString();
            if (string.IsNullOrEmpty(title)) return true;

            GetWindowThreadProcessId(hWnd, out uint pid);
            if (pid == selfPid) return true;

            if (!GetWindowRect(hWnd, out var r)) return true;
            int width = r.right - r.left, height = r.bottom - r.top;
            if (width < 100 || height < 100) return true; // filter out tooltips/menus

            string appName;
            try { appName = Process.GetProcessById((int)pid).ProcessName; }
            catch { return true; } // process exited between enumeration and lookup

            result.Add(new WindowInfo(hWnd, appName, title, width, height));
            return true;
        };
        EnumWindows(cb, IntPtr.Zero);
        return result;
    }

    /// `ClamshellServer windowlist` CLI entry point.
    public static int RunCli()
    {
        var windows = Capturable();
        if (windows.Count == 0)
        {
            Console.WriteLine("No capturable windows found.");
            return 0;
        }
        foreach (var w in windows)
            Console.WriteLine($"{w.Handle.ToInt64()}\t{w.AppName}\t{w.Title}\t{w.Width}x{w.Height}");
        return 0;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int left, top, right, bottom; }

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
}
