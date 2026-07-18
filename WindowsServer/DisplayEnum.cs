using System.Runtime.InteropServices;

namespace Clamshell;

// Enumerates active displays via Win32 (EnumDisplayMonitors). Deliberately NOT
// DXGI: this is the reliable, GPU-agnostic display list that drives port
// assignment and input mapping. The capture module (DXGI Desktop Duplication)
// matches its outputs back to these by desktop coordinates.
//
// This is agnostic to VM vs physical: a VM's virtual video adapter and a
// passed-through physical GPU both present monitors here identically — there is
// no special-casing, and none is wanted (see the task's capture design point).
internal sealed record DisplayInfo(int Index, string DeviceName, DisplayRect Bounds, bool IsPrimary)
{
    public ushort Port(ushort basePort) => (ushort)(basePort + Index);
}

internal static class DisplayEnum
{
    public static List<DisplayInfo> Active()
    {
        var mons = new List<(DisplayRect rect, bool primary)>();
        MonitorEnumProc cb = (IntPtr hMon, IntPtr _, ref RECT r, IntPtr _) =>
        {
            var mi = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
            if (GetMonitorInfo(hMon, ref mi))
            {
                bool primary = (mi.dwFlags & MONITORINFOF_PRIMARY) != 0;
                var rc = mi.rcMonitor;
                mons.Add((new DisplayRect(rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top), primary));
            }
            return true;
        };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, cb, IntPtr.Zero);

        // Primary first (index 0 = base port = the audio/clipboard connection),
        // matching the Mac fleet's main-display-first ordering.
        mons.Sort((a, b) => b.primary.CompareTo(a.primary));
        var list = new List<DisplayInfo>();
        for (int i = 0; i < mons.Count; i++)
            list.Add(new DisplayInfo(i, $"display{i}", mons[i].rect, mons[i].primary));
        if (list.Count == 0)
            Log.Line("WARNING — no active displays found");
        return list;
    }

    private const uint MONITORINFOF_PRIMARY = 1;

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)]
    private struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public uint dwFlags; }

    private delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT lprc, IntPtr data);

    [DllImport("user32.dll")]
    private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc cb, IntPtr data);
    [DllImport("user32.dll")]
    private static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO mi);
}
