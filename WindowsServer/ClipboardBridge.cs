using System.Runtime.InteropServices;

namespace Clamshell;

// Plain-text clipboard sync for the primary connection — the mirror of the
// Mac ClipboardBridge. Windows has GetClipboardSequenceNumber (no polling of
// content needed to detect change), so we poll that number every 0.5s and push
// new CF_UNICODETEXT to the client; inbound text is written back and the
// sequence re-baselined so our own write isn't echoed.
//
// ponytail: 0.5s poll, plain text only, matches the Mac side exactly.
internal sealed class ClipboardBridge : IDisposable
{
    private uint _lastSeq;
    private Timer? _timer;
    public Action<string>? OnLocalChange;

    public void Start()
    {
        _lastSeq = GetClipboardSequenceNumber();
        _timer = new Timer(_ => Poll(), null, TimeSpan.FromSeconds(0.5), TimeSpan.FromSeconds(0.5));
    }

    public void Dispose() { _timer?.Dispose(); _timer = null; }

    private void Poll()
    {
        uint c = GetClipboardSequenceNumber();
        if (c == _lastSeq) return;
        _lastSeq = c;
        if (ReadText() is { } s) OnLocalChange?.Invoke(s);
    }

    public void ReceiveFromClient(string text)
    {
        WriteText(text);
        _lastSeq = GetClipboardSequenceNumber(); // don't echo our own write back
    }

    // MARK: - Win32 clipboard interop (CF_UNICODETEXT)

    private const uint CF_UNICODETEXT = 13;
    private const uint GMEM_MOVEABLE = 0x0002;

    private static string? ReadText()
    {
        if (!OpenClipboard(IntPtr.Zero)) return null;
        try
        {
            IntPtr h = GetClipboardData(CF_UNICODETEXT);
            if (h == IntPtr.Zero) return null;
            IntPtr p = GlobalLock(h);
            if (p == IntPtr.Zero) return null;
            try { return Marshal.PtrToStringUni(p); }
            finally { GlobalUnlock(h); }
        }
        finally { CloseClipboard(); }
    }

    private static void WriteText(string text)
    {
        if (!OpenClipboard(IntPtr.Zero)) return;
        try
        {
            EmptyClipboard();
            byte[] bytes = System.Text.Encoding.Unicode.GetBytes(text + '\0');
            IntPtr hg = GlobalAlloc(GMEM_MOVEABLE, (UIntPtr)bytes.Length);
            if (hg == IntPtr.Zero) return;
            IntPtr p = GlobalLock(hg);
            if (p == IntPtr.Zero) { GlobalFree(hg); return; }
            try { Marshal.Copy(bytes, 0, p, bytes.Length); }
            finally { GlobalUnlock(hg); }
            if (SetClipboardData(CF_UNICODETEXT, hg) == IntPtr.Zero) GlobalFree(hg); // on failure we still own it
        }
        finally { CloseClipboard(); }
    }

    [DllImport("user32.dll")] private static extern bool OpenClipboard(IntPtr hWndNewOwner);
    [DllImport("user32.dll")] private static extern bool CloseClipboard();
    [DllImport("user32.dll")] private static extern bool EmptyClipboard();
    [DllImport("user32.dll")] private static extern IntPtr GetClipboardData(uint uFormat);
    [DllImport("user32.dll")] private static extern IntPtr SetClipboardData(uint uFormat, IntPtr hMem);
    [DllImport("user32.dll")] private static extern uint GetClipboardSequenceNumber();
    [DllImport("kernel32.dll")] private static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);
    [DllImport("kernel32.dll")] private static extern IntPtr GlobalFree(IntPtr hMem);
    [DllImport("kernel32.dll")] private static extern IntPtr GlobalLock(IntPtr hMem);
    [DllImport("kernel32.dll")] private static extern bool GlobalUnlock(IntPtr hMem);
}
