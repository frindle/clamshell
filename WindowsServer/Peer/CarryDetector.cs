namespace Clamshell;

// What, if anything, the left button is carrying when the cursor reaches the
// peer edge — the Windows twin of CarryDetector.swift:
//   * files: an OLE drag carrying CF_HDROP. Windows has no global "drag
//     pasteboard" to peek at, so while the button is held a 2-px, nearly
//     transparent, topmost drop target (DropStrip) lines the peer edge; the
//     drag's DragEnter on it hands us the paths.
//   * a window: the top-level window under the press has since moved (its
//     title bar is being dragged).
//   * one of our ReceiverForms being dragged home.
// Used by EdgeController (the physical mouse) and RemoteInputSink (a peer's
// injected mouse). UI thread only.

internal abstract record Carry
{
    internal sealed record Files(string[] Paths) : Carry;
    /// A real window of another app. Grab = where the cursor holds it, 0…1 in its frame.
    internal sealed record Window(IntPtr Handle, uint Pid, Rect Frame, string Title, string App,
                                  double GrabX, double GrabY, Rect PreDragFrame) : Carry;
    internal sealed record Receiver(uint SourceWindowId) : Carry;

    public string Describe() => this switch
    {
        Files f => $"{f.Paths.Length} file(s)",
        Window w => $"window \"{w.App} — {w.Title}\"",
        Receiver r => $"handed-off window {r.SourceWindowId} (return)",
        _ => "?",
    };
}

internal sealed class CarryDetector : IDisposable
{
    private (IntPtr H, Rect Frame, double X, double Y)? _pressed;
    private readonly List<DropStrip> _strips = new();
    private string[]? _files;
    /// Maps one of our own top-level windows to the source window id it shows.
    public Func<IntPtr, uint?> ReceiverLookup = _ => null;
    /// Edge of this machine's screen that leads to the peer (strip placement).
    public PeerEdge Edge = PeerEdge.Right;
    public bool DropStripsEnabled = true;
    /// Controlled side: the peer's cursor lives on this one display only, so
    /// the strip goes on its edge whatever lies beyond it.
    public Rect? OnlyDisplay;

    public Rect? PressedFrame => _pressed?.Frame;
    public bool HasFiles => _files is { Length: > 0 };

    public void MouseDown(double x, double y)
    {
        _files = null;
        var h = WinNative.RootWindowAt(x, y);
        _pressed = h != IntPtr.Zero && WinNative.Frame(h) is { } f ? (h, f.ToRect(), x, y) : null;
        if (DropStripsEnabled) ShowStrips();
    }

    public void MouseUp()
    {
        _pressed = null;
        HideStrips();
        _files = null;
    }

    /// Called at the edge while the left button is still down.
    public Carry? Evaluate()
    {
        if (_files is { Length: > 0 } files) return new Carry.Files(files);
        if (_pressed is not { } p || WinNative.Frame(p.H) is not { } nowR) return null;
        var now = nowR.ToRect();
        if (Math.Abs(now.X - p.Frame.X) <= 2 && Math.Abs(now.Y - p.Frame.Y) <= 2) return null;
        if (ReceiverLookup(p.H) is { } src) return new Carry.Receiver(src);
        if (WinNative.Pid(p.H) == (uint)Environment.ProcessId) return null; // our own dialogs stay here
        double gx = Math.Clamp((p.X - p.Frame.X) / Math.Max(p.Frame.W, 1), 0, 1);
        double gy = Math.Clamp((p.Y - p.Frame.Y) / Math.Max(p.Frame.H, 1), 0, 1);
        uint pid = WinNative.Pid(p.H);
        return new Carry.Window(p.H, pid, now, WinNative.Title(p.H), WinNative.AppName(pid), gx, gy, p.Frame);
    }

    /// Is the cursor on a drop strip right now (a file drag may be about to
    /// report itself — worth waiting a beat before deciding "nothing")?
    public bool OnStrip(double x, double y) => _strips.Any(s => s.Visible && s.Bounds.Contains((int)x, (int)y));

    private void ShowStrips()
    {
        HideStrips();
        var displays = OnlyDisplay is { } only ? new List<Rect> { only } : WinNative.Displays();
        foreach (var d in displays)
        {
            // Only edges no other display continues past (same rule as EdgeGeometry.Exit).
            System.Drawing.Rectangle r;
            double mx = d.X + d.W / 2, my = d.Y + d.H / 2;
            (double bx, double by) = Edge switch
            {
                PeerEdge.Left => (d.MinX - 2, my),
                PeerEdge.Right => (d.MaxX + 1, my),
                PeerEdge.Top => (mx, d.MinY - 2),
                _ => (mx, d.MaxY + 1),
            };
            if (displays.Any(o => o.Contains(bx, by))) continue;
            const int t = 2;
            r = Edge switch
            {
                PeerEdge.Left => new((int)d.X, (int)d.Y, t, (int)d.H),
                PeerEdge.Right => new((int)d.MaxX - t, (int)d.Y, t, (int)d.H),
                PeerEdge.Top => new((int)d.X, (int)d.Y, (int)d.W, t),
                _ => new((int)d.X, (int)d.MaxY - t, (int)d.W, t),
            };
            var s = new DropStrip(r);
            s.OnFiles = paths => _files = paths;
            s.ShowStrip();
            _strips.Add(s);
        }
    }

    private void HideStrips()
    {
        foreach (var s in _strips) { try { s.Close(); s.Dispose(); } catch { } }
        _strips.Clear();
    }

    public void Dispose() => HideStrips();

    /// Ends a drag this PC is still running locally after the cursor went
    /// to the peer: Esc cancels an OLE file drag (nothing gets dropped at
    /// the edge), then the button is released so a window move loop ends
    /// too. Tagged, so our own hooks let it through.
    public static void CancelLocalDrag(bool files)
    {
        var inj = new InputInjector(DisplayRect.Of(WinNative.VirtualScreen()));
        if (files)
        {
            inj.VirtualKey((ushort)PeerKeys.VK_ESCAPE, true);
            inj.VirtualKey((ushort)PeerKeys.VK_ESCAPE, false);
        }
        inj.ReleaseLeftRaw();
    }
}

/// Thin topmost drop target along the peer edge, shown only while the left
/// button is held. Nearly transparent (alpha 2/255 still hit-tests), never
/// activates, not in the taskbar or Alt-Tab.
internal sealed class DropStrip : Form
{
    public Action<string[]>? OnFiles;

    public DropStrip(System.Drawing.Rectangle bounds)
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        AllowDrop = true;
        Opacity = 0.01;
        BackColor = System.Drawing.Color.Black;
        Bounds = bounds;
        DragEnter += (_, e) =>
        {
            if (e.Data?.GetData(DataFormats.FileDrop) is string[] { Length: > 0 } paths)
            {
                OnFiles?.Invoke(paths);
                e.Effect = DragDropEffects.Copy;
            }
            else e.Effect = DragDropEffects.None;
        };
        DragOver += (_, e) => e.Effect = e.Data?.GetDataPresent(DataFormats.FileDrop) == true ? DragDropEffects.Copy : DragDropEffects.None;
        // An actual drop here (released at the edge without crossing) does nothing.
    }

    public void ShowStrip()
    {
        var b = Bounds;
        Show();
        // Re-apply exactly (WinForms may clamp a form this thin) and pin on top.
        WinNative.SetWindowPos(Handle, new IntPtr(-1), b.X, b.Y, b.Width, b.Height, WinNative.SWP_NOACTIVATE);
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= (int)(WinNative.WS_EX_TOOLWINDOW | WinNative.WS_EX_NOACTIVATE | WinNative.WS_EX_TOPMOST);
            return cp;
        }
    }
}
