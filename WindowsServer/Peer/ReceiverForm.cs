using System.Drawing;
using System.Net.WebSockets;
using System.Runtime.InteropServices;

namespace Clamshell;

// The receiving side of a window handoff on Windows — the twin of
// ReceiverWindow.swift. A borderless window showing the peer's window live
// and forwarding mouse, wheel and keys back (v1 INPUT_*, normalized to the
// video area, keys as macOS key codes with Ctrl → Command). It dials the v1
// window stream the source opened for this handoff (HELLO → HELLO_ACK →
// VIDEO_FRAME…) and decodes with PeerVideoDecoder (Media Foundation,
// H.264 requested — the decoder every Windows install has).
//
// A thin title strip: title, status, and "↩ Send back". Dragging the strip
// moves the window (and across the peer edge, sends it home — CarryDetector
// sees one of our receivers moving). Closing it (Alt+F4, Ctrl+W) sends it home.
//
// UI thread for the form; network + decode on background tasks.
internal sealed class ReceiverForm : Form
{
    public const int StripHeight = 24;
    public uint SourceWindowId { get; }
    public Action OnReturnRequested = () => { };
    private long _framesShown;
    public long FramesShown => Interlocked.Read(ref _framesShown);
    public (uint W, uint H)? AckSize { get; private set; }

    private readonly VideoPanel _video;
    private readonly Label _status;
    private readonly ClientWebSocket _ws = new();
    private readonly CancellationTokenSource _cts = new();
    private readonly SemaphoreSlim _sendLock = new(1, 1);
    private readonly string _host;
    private readonly ushort _port;
    private PeerVideoDecoder? _decoder;
    private bool _closingQuietly;
    private System.Windows.Forms.Timer? _follow;
    private ulong _flags;

    public ReceiverForm(uint sourceWindowId, string title, string app, Size videoSize, string host, ushort port)
    {
        SourceWindowId = sourceWindowId;
        _host = host; _port = port;
        Text = $"{app} — {title}";
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.Black;
        KeyPreview = true;
        ClientSize = new Size(Math.Max(videoSize.Width, 160), Math.Max(videoSize.Height, 60) + StripHeight);
        try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

        var strip = new Panel { Dock = DockStyle.Top, Height = StripHeight, BackColor = SystemColors.Control };
        var back = new Button { Text = "↩ Send back", Dock = DockStyle.Right, Width = 96, FlatStyle = FlatStyle.System, TabStop = false };
        back.Click += (_, _) => OnReturnRequested();
        _status = new Label { Text = "connecting…", Dock = DockStyle.Right, Width = 90, TextAlign = ContentAlignment.MiddleRight, ForeColor = SystemColors.GrayText };
        var label = new Label { Text = $"{app} — {title}  (from peer)", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, AutoEllipsis = true };
        foreach (Control c in new Control[] { strip, label, _status })
            c.MouseDown += (_, e) => { if (e.Button == MouseButtons.Left) DragByStrip(); };
        strip.Controls.Add(label);
        strip.Controls.Add(_status);
        strip.Controls.Add(back);

        _video = new VideoPanel { Dock = DockStyle.Fill };
        _video.Send = Send;
        Controls.Add(_video);
        Controls.Add(strip);

        KeyDown += (_, e) => Key(e, true);
        KeyUp += (_, e) => Key(e, false);
        FormClosing += (_, e) =>
        {
            if (_closingQuietly || e.CloseReason != CloseReason.UserClosing) return;
            e.Cancel = true; // Alt+F4 / taskbar close = send it home
            OnReturnRequested();
        };
    }

    private bool _started;

    /// Dials the window stream. Called by HandoffManager right after Show()
    /// (not from the Shown event, which deskselftest never saw fire).
    public void Connect()
    {
        if (_started) return;
        _started = true;
        // The network loop never touches the UI thread's context: under
        // deskselftest's pump an awaited ConnectAsync resumed there never ran
        // and tearing the socket down on it hung. UI updates go via BeginInvoke.
        _ = Task.Run(RunAsync);
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ClassStyle |= 0x20000; // CS_DROPSHADOW
            return cp;
        }
    }

    private void DragByStrip()
    {
        // Native move loop, exactly like dragging a title bar — so the
        // window-carry detection on the edge sees it move.
        WinNative.ReleaseCapture();
        WinNative.SendMessage(Handle, WinNative.WM_NCLBUTTONDOWN, (IntPtr)WinNative.HTCAPTION, IntPtr.Zero);
    }

    /// Keeps `grab` (0…1 in the video area) under the cursor while `isHeld`.
    public void Follow(double grabX, double grabY, Func<bool> isHeld)
    {
        _follow?.Dispose();
        void Move()
        {
            var (cx, cy) = WinNative.Cursor();
            Location = new Point((int)(cx - grabX * _video.Width), (int)(cy - StripHeight - grabY * _video.Height));
        }
        Move();
        _follow = new System.Windows.Forms.Timer { Interval = 16 };
        _follow.Tick += (_, _) =>
        {
            Move();
            if (!isHeld()) { _follow?.Dispose(); _follow = null; Activate(); }
        };
        _follow.Start();
    }

    /// Initial spot when nothing is being carried: against `edge` of the
    /// primary work area at `position` along it.
    public void Place(PeerEdge edge, double position)
    {
        var wa = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 1280, 720);
        int w = Width, h = Height;
        int x = edge switch
        {
            PeerEdge.Left => wa.Left,
            PeerEdge.Right => wa.Right - w,
            _ => wa.Left + (int)(position * wa.Width) - w / 2,
        };
        int y = edge switch
        {
            PeerEdge.Top => wa.Top,
            PeerEdge.Bottom => wa.Bottom - h,
            _ => wa.Top + (int)(position * wa.Height) - h / 2,
        };
        Location = new Point(Math.Clamp(x, wa.Left, Math.Max(wa.Right - w, wa.Left)), Math.Clamp(y, wa.Top, Math.Max(wa.Bottom - h, wa.Top)));
    }

    public void CloseQuietly()
    {
        _closingQuietly = true;
        _follow?.Dispose();
        if (!IsDisposed) Close();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) ShutDownStream();
        base.Dispose(disposing);
    }

    /// Socket teardown off the UI thread (it can block on a connect or
    /// receive in flight). The receive loop disposes the decoder it owns.
    private void ShutDownStream()
    {
        // Cancel() runs the in-flight receive's cancellation callbacks inline
        // (they abort the socket), so it goes off the UI thread too.
        var ws = _ws; var cts = _cts;
        _ = Task.Run(() =>
        {
            try { cts.Cancel(); } catch { }
            try { ws.Abort(); } catch { }
            try { ws.Dispose(); } catch { }
        });
    }

    // MARK: - Stream

    private void Status(string s)
    {
        try { if (!IsDisposed && IsHandleCreated) BeginInvoke(() => _status.Text = s); }
        catch (InvalidOperationException) { } // closed meanwhile
    }

    private async Task RunAsync()
    {
        string h = _host.Contains(':') ? $"[{_host}]" : _host;
        try
        {
            Log.Line($"HANDOFF: receiver dialling {h}:{_port}");
            await _ws.ConnectAsync(new Uri($"ws://{h}:{_port}/"), _cts.Token).ConfigureAwait(false);
            Log.Line($"HANDOFF: receiver connected to {h}:{_port}");
            Status("live");
            Send(PeerMsg.StreamHello(StreamCodec.H264));
            var parser = new FrameParser { OnMessage = OnStreamMessage };
            var buf = new byte[256 * 1024];
            while (!_cts.IsCancellationRequested)
            {
                var r = await _ws.ReceiveAsync(buf, _cts.Token).ConfigureAwait(false);
                if (r.MessageType == WebSocketMessageType.Close) break;
                parser.Feed(buf.AsSpan(0, r.Count));
                if (parser.Corrupt) break;
            }
            Status("stream ended");
        }
        catch (Exception) when (_cts.IsCancellationRequested) { }
        catch (Exception e) { Status("lost"); Log.Line($"HANDOFF: receiver stream {_host}:{_port} failed: {e.Message}"); }
        finally { _decoder?.Dispose(); _decoder = null; }
    }

    private bool _askedKeyframe;

    private void OnStreamMessage(MessageType t, byte[] p)
    {
        switch (t)
        {
            case MessageType.HelloAck when p.Length >= 10:
                AckSize = (Be.U32(p, 2), Be.U32(p, 6));
                Log.Line($"HANDOFF: receiver got HELLO_ACK {AckSize} codec {p[1]}");
                _decoder?.Dispose();
                try
                {
                    _decoder = new PeerVideoDecoder((StreamCodec)p[1]);
                    _decoder.OnFrame = (w, h, bgra) => _video.Present(w, h, bgra, () => Interlocked.Increment(ref _framesShown));
                }
                catch (Exception e) { Status("no decoder"); Log.Line($"HANDOFF: decoder init failed: {e.Message}"); }
                break;
            case MessageType.VideoFrame when p.Length >= 9 && _decoder is { } d:
                try { d.Feed(p.AsSpan(9), Be.U64(p, 1)); }
                catch (Exception e)
                {
                    // Joined mid-GOP or a decode hiccup: ask for a fresh keyframe once.
                    if (!_askedKeyframe) { _askedKeyframe = true; Send(PeerMsg.KeyframeRequest()); }
                    Log.Line($"HANDOFF: decode error {e.Message}");
                }
                break;
        }
    }

    private void Send(byte[] data)
    {
        if (_ws.State != WebSocketState.Open) return;
        _ = Task.Run(async () =>
        {
            await _sendLock.WaitAsync();
            try { await _ws.SendAsync(data, WebSocketMessageType.Binary, true, _cts.Token); }
            catch { }
            finally { _sendLock.Release(); }
        });
    }

    // MARK: - Keys

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        // Ctrl+W = send home (⌘W on the Mac receiver). Everything else —
        // Tab, arrows, Alt combos — goes to the remote app, not our form.
        if (keyData == (Keys.Control | Keys.W)) { OnReturnRequested(); return true; }
        return false;
    }

    protected override bool ProcessDialogKey(Keys keyData) => false;

    private void Key(KeyEventArgs e, bool down)
    {
        e.Handled = true; e.SuppressKeyPress = true;
        uint vk = (uint)e.KeyCode;
        bool extended = false;
        // KeyEventArgs folds left/right: ask which one is actually down.
        if (vk == PeerKeys.VK_CONTROL) vk = Side(PeerKeys.VK_RCONTROL, PeerKeys.VK_LCONTROL, down);
        else if (vk == PeerKeys.VK_MENU) vk = Side(PeerKeys.VK_RMENU, PeerKeys.VK_LMENU, down);
        else if (vk == PeerKeys.VK_SHIFT) vk = Side(PeerKeys.VK_RSHIFT, PeerKeys.VK_LSHIFT, down);
        if (PeerKeys.MacCode(vk, extended) is not { } mac) return;
        if (PeerKeys.IsModifier(mac))
        {
            if (mac == 57)
            {
                if (!down) return;
                _flags ^= PeerKeys.FlagAlphaShift;
                Send(PeerMsg.Key(mac, true, _flags)); Send(PeerMsg.Key(mac, false, _flags));
                return;
            }
            ulong bit = PeerKeys.ModifierBit(mac);
            if (down) _flags |= bit; else _flags &= ~bit;
            Send(PeerMsg.Key(mac, down, _flags));
            return;
        }
        Send(PeerMsg.Key(mac, down, _flags | (PeerKeys.IsKeypad(mac) ? PeerKeys.FlagNumericPad : 0)));
    }

    private static uint Side(uint right, uint left, bool down)
    {
        bool r = (GetKeyState((int)right) & 0x8000) != 0, l = (GetKeyState((int)left) & 0x8000) != 0;
        if (down) return r && !l ? right : left;
        return !r && l ? right : left; // released: the one no longer down
    }

    [DllImport("user32.dll")] private static extern short GetKeyState(int vk);

    protected override void OnDeactivate(EventArgs e)
    {
        // Focus left with modifiers held: release them on the peer.
        foreach (ushort mac in new ushort[] { 55, 54, 56, 60, 58, 61, 59, 62 })
            if ((_flags & PeerKeys.ModifierBit(mac)) != 0) Send(PeerMsg.Key(mac, false, 0));
        _flags &= PeerKeys.FlagAlphaShift;
        base.OnDeactivate(e);
    }
}

/// Paints the newest decoded frame, letterboxed, and turns mouse input into
/// v1 INPUT_* normalized to the picture.
internal sealed class VideoPanel : Control
{
    public Action<byte[]> Send = _ => { };
    private Bitmap? _frame;
    private readonly object _lock = new();

    public VideoPanel()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.Selectable, true);
        BackColor = Color.Black;
        TabStop = true;
    }

    protected override bool IsInputKey(Keys keyData) => true;

    /// Called on the decoder thread.
    public void Present(int w, int h, byte[] bgra, Action counted)
    {
        var bmp = new Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format32bppRgb);
        var data = bmp.LockBits(new Rectangle(0, 0, w, h), System.Drawing.Imaging.ImageLockMode.WriteOnly, bmp.PixelFormat);
        try
        {
            for (int y = 0; y < h; y++) Marshal.Copy(bgra, y * w * 4, data.Scan0 + y * data.Stride, w * 4);
        }
        finally { bmp.UnlockBits(data); }
        counted();
        if (IsDisposed || !IsHandleCreated) { bmp.Dispose(); return; }
        try
        {
            BeginInvoke(() =>
            {
                Bitmap? old;
                lock (_lock) { old = _frame; _frame = bmp; }
                old?.Dispose();
                Invalidate();
            });
        }
        catch (Exception e) when (e is InvalidOperationException or ObjectDisposedException) { bmp.Dispose(); }
    }

    private Rectangle Picture()
    {
        Bitmap? f;
        lock (_lock) f = _frame;
        if (f is null || f.Width == 0 || f.Height == 0) return ClientRectangle;
        double s = Math.Min(ClientSize.Width / (double)f.Width, ClientSize.Height / (double)f.Height);
        int w = (int)(f.Width * s), h = (int)(f.Height * s);
        return new Rectangle((ClientSize.Width - w) / 2, (ClientSize.Height - h) / 2, w, h);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.Clear(Color.Black);
        lock (_lock)
        {
            if (_frame is null) return;
            e.Graphics.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.Bilinear;
            e.Graphics.DrawImage(_frame, Picture());
        }
    }

    private (float, float) Norm(Point p)
    {
        var r = Picture();
        return ((float)Math.Clamp((p.X - r.X) / (double)Math.Max(r.Width, 1), 0, 1),
                (float)Math.Clamp((p.Y - r.Y) / (double)Math.Max(r.Height, 1), 0, 1));
    }

    protected override void OnMouseMove(MouseEventArgs e) { var (x, y) = Norm(e.Location); Send(PeerMsg.MouseMove(x, y)); }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        Focus();
        if (e.Button is not (MouseButtons.Left or MouseButtons.Right)) return;
        var (x, y) = Norm(e.Location);
        Send(PeerMsg.MouseButton((byte)(e.Button == MouseButtons.Right ? 1 : 0), true, x, y));
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        if (e.Button is not (MouseButtons.Left or MouseButtons.Right)) return;
        var (x, y) = Norm(e.Location);
        Send(PeerMsg.MouseButton((byte)(e.Button == MouseButtons.Right ? 1 : 0), false, x, y));
    }

    protected override void OnMouseWheel(MouseEventArgs e)
    {
        if (e.Delta != 0) Send(PeerMsg.Scroll(0, e.Delta / 3f));
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WinNative.WM_MOUSEHWHEEL)
        {
            short d = (short)((long)m.WParam >> 16);
            if (d != 0) Send(PeerMsg.Scroll(-d / 3f, 0));
            m.Result = IntPtr.Zero;
            return;
        }
        base.WndProc(ref m);
    }
}
