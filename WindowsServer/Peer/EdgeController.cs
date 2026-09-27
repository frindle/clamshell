using System.Runtime.InteropServices;

namespace Clamshell;

// The controlling half of the shared-desk KVM on Windows — the twin of
// EdgeController.swift, same wire behaviour (PROTOCOL.md "Peer link — shared
// mouse and keyboard"). Low-level mouse + keyboard hooks (WH_MOUSE_LL /
// WH_KEYBOARD_LL, installed on the UI thread, which pumps messages). When the
// pointer is pushed out through the configured edge, control goes to the
// peer:
//   * the cursor is parked in the middle of the display it left and a tiny
//     near-transparent window with a blank cursor sits under it (Windows has
//     no public "hide the cursor for everyone" call; this is best effort,
//     like the Mac's)
//   * every mouse move is swallowed — the hook still reports where it WOULD
//     have gone, so delta = reported point − parked point
//   * buttons, wheel and keys are swallowed and forwarded as v1 INPUT_*
//     (keys as macOS key codes via PeerKeys; Ctrl ⇄ Command)
// until the virtual cursor leaves the peer through the edge it went in by.
//
// Crossing detection: the pointer on the edge of a display with no display
// beyond it (EdgeGeometry.Exit). Windows clamps the cursor at the edge, so a
// move reported AT the edge with no outward delta also counts as pushing.
//
// Everything this process injects carries dwExtraInfo = InputInjector.Tag
// and is passed straight through, so a peer driving this PC never looks like
// the local user reaching the edge. Panic key while controlling:
// Ctrl+Alt+Shift+L. Secure desktop (UAC, Ctrl+Alt+Del) is out of reach of
// any hook — a Windows rule.
internal sealed class EdgeController : IDisposable
{
    public PeerEdge Edge;
    public Action<byte[]> Send = _ => { };
    /// The linked peer's primary screen, in its units; null when unlinked.
    public Func<(double W, double H)?> PeerSize = () => null;
    public Action<Carry, PeerEdge, double> OnCarryCrossed = (_, _, _) => { };
    public Action<Carry> OnCarryDropped = _ => { };
    public Action<bool> OnControlChange = _ => { };
    public readonly CarryDetector Carry = new();

    private IntPtr _mouseHook, _keyHook;
    private WinNative.HookProc? _mouseProc, _keyProc; // kept alive: the hook holds only a raw pointer
    private RemoteCursor? _remote;
    private Rect _exitDisplay;
    private (int X, int Y) _park;
    private double _scale = 1;
    private Carry? _carry;
    private bool _leftHeld;
    private (double X, double Y)? _last;
    private ulong _flags;
    private readonly HashSet<ushort> _macDown = new();
    private BlankCursorWindow? _blank;
    private SynchronizationContext? _ui;

    public bool IsControllingPeer => _remote is not null;

    public EdgeController(PeerEdge edge) { Edge = edge; Carry.Edge = edge; }

    public bool Start()
    {
        if (_mouseHook != IntPtr.Zero) return true;
        _ui = SynchronizationContext.Current;
        _mouseProc = MouseHook;
        _keyProc = KeyHook;
        IntPtr mod = WinNative.GetModuleHandle(null);
        _mouseHook = WinNative.SetWindowsHookEx(WinNative.WH_MOUSE_LL, _mouseProc, mod, 0);
        _keyHook = WinNative.SetWindowsHookEx(WinNative.WH_KEYBOARD_LL, _keyProc, mod, 0);
        if (_mouseHook == IntPtr.Zero || _keyHook == IntPtr.Zero)
        {
            Log.Line($"PEER: could not install input hooks (error {Marshal.GetLastWin32Error()})");
            Stop();
            return false;
        }
        Log.Line($"PEER: edge hooks on ({Edge.Name()} edge leads to the peer)");
        return true;
    }

    public void Stop()
    {
        if (_remote is not null) ReturnHome(0.5);
        if (_mouseHook != IntPtr.Zero) WinNative.UnhookWindowsHookEx(_mouseHook);
        if (_keyHook != IntPtr.Zero) WinNative.UnhookWindowsHookEx(_keyHook);
        _mouseHook = _keyHook = IntPtr.Zero;
        Carry.MouseUp();
    }

    public void Dispose() { Stop(); Carry.Dispose(); _blank?.Dispose(); }

    public void SetEdge(PeerEdge e) { Edge = e; Carry.Edge = e; }

    /// Link dropped / panic key / peer took over: take control back here.
    public void ReturnHome(double fraction, bool notifyPeer = true)
    {
        if (_remote is null) return;
        if (notifyPeer) Send(PeerMsg.EdgeLeave());
        _remote = null;
        _carry = null;
        ReleaseRemoteModifiers(notifyPeer);
        _blank?.Hide();
        var (x, y) = EdgeGeometry.ReentryPoint(_exitDisplay, Edge, fraction);
        WinNative.SetCursorPos((int)x, (int)y);
        _last = (x, y);
        Log.Line("PEER: control back on this PC");
        OnControlChange(false);
    }

    // MARK: - Mouse

    private IntPtr MouseHook(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var m = Marshal.PtrToStructure<WinNative.MSLLHOOKSTRUCT>(lParam);
            if (m.dwExtraInfo != InputInjector.Tag)
            {
                bool swallow;
                try { swallow = _remote is null ? Local((int)wParam, m) : Remote((int)wParam, m); }
                catch (Exception e) { Log.Line($"PEER: edge hook error {e.Message}"); swallow = false; }
                if (swallow) return new IntPtr(1);
            }
        }
        return WinNative.CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
    }

    private bool Local(int msg, WinNative.MSLLHOOKSTRUCT m)
    {
        double px = m.pt.X, py = m.pt.Y;
        switch (msg)
        {
            case WinNative.WM_LBUTTONDOWN:
                _leftHeld = true;
                Carry.MouseDown(px, py);
                break;
            case WinNative.WM_LBUTTONUP:
                _leftHeld = false;
                Carry.MouseUp();
                break;
            case WinNative.WM_MOUSEMOVE:
            {
                var last = _last ?? (px, py);
                _last = (px, py);
                if (PeerSize() is not { } peer) return false;
                double dx = px - last.X, dy = py - last.Y;
                var displays = WinNative.Displays();
                // Clamped at the edge: Windows reports the same point again.
                (dx, dy) = Edge switch
                {
                    PeerEdge.Left when dx == 0 => (-1, dy),
                    PeerEdge.Right when dx == 0 => (1, dy),
                    PeerEdge.Top when dy == 0 => (dx, -1),
                    PeerEdge.Bottom when dy == 0 => (dx, 1),
                    _ => (dx, dy),
                };
                if (EdgeGeometry.Exit(px, py, dx, dy, Edge, displays) is not { } exit) return false;
                Carry? carried = null;
                if (_leftHeld)
                {
                    // Only a real carry crosses with the button down: a text
                    // selection or a slider drag stays on this machine.
                    carried = Carry.Evaluate();
                    if (carried is null) return false;
                }
                CrossToPeer(exit.Display, exit.Fraction, carried, peer);
                return true;
            }
        }
        return false;
    }

    private void CrossToPeer(Rect display, double fraction, Carry? carry, (double W, double H) peer)
    {
        var peerEdge = Edge.Opposite();
        var cursor = new RemoteCursor(peerEdge, fraction, peer.W, peer.H);
        _remote = cursor;
        _exitDisplay = display;
        _scale = EdgeGeometry.SpeedScale(display.W, peer.W);
        _carry = carry;
        _flags = 0;
        _macDown.Clear();
        var (nx, ny) = cursor.Normalized;
        Send(PeerMsg.EdgeEnter(peerEdge, nx, ny, carry is not null));
        Send(PeerMsg.MouseMove(nx, ny));
        _park = ((int)(display.X + display.W / 2), (int)(display.Y + display.H / 2));
        WinNative.SetCursorPos(_park.X, _park.Y);
        Log.Line($"PEER: control → peer ({peerEdge.Name()} edge at {fraction:0.00}{(carry is null ? "" : " carrying " + carry.Describe())})");
        // Out of the hook callback (it must return fast, and injecting from
        // inside it is asking for trouble).
        Later(() =>
        {
            if (_remote is null) return;
            _blank ??= new BlankCursorWindow();
            _blank.ShowAt(_park.X, _park.Y);
            OnControlChange(true);
            if (carry is not null)
            {
                CarryDetector.CancelLocalDrag(files: carry is Carry.Files);
                Carry.MouseUp();
                OnCarryCrossed(carry, peerEdge, fraction);
            }
        });
    }

    private void Later(Action a)
    {
        if (_ui is not null) _ui.Post(_ => a(), null); else a();
    }

    private bool Remote(int msg, WinNative.MSLLHOOKSTRUCT m)
    {
        if (_remote is not { } cursor) return false;
        switch (msg)
        {
            case WinNative.WM_MOUSEMOVE:
            {
                double dx = (m.pt.X - _park.X) * _scale, dy = (m.pt.Y - _park.Y) * _scale;
                if (dx == 0 && dy == 0) return true;
                if (cursor.Move(dx, dy) is { } back) { ReturnHome(back); return true; } // SetCursorPos only; cheap
                var (nx, ny) = cursor.Normalized;
                Send(PeerMsg.MouseMove(nx, ny));
                return true;
            }
            case WinNative.WM_LBUTTONDOWN or WinNative.WM_LBUTTONUP or WinNative.WM_RBUTTONDOWN or WinNative.WM_RBUTTONUP:
            {
                bool down = msg is WinNative.WM_LBUTTONDOWN or WinNative.WM_RBUTTONDOWN;
                byte button = (byte)(msg is WinNative.WM_RBUTTONDOWN or WinNative.WM_RBUTTONUP ? 1 : 0);
                if (button == 0) _leftHeld = down;
                var (nx, ny) = cursor.Normalized;
                Send(PeerMsg.MouseButton(button, down, nx, ny));
                if (button == 0 && !down && _carry is { } c) { _carry = null; OnCarryDropped(c); }
                return true;
            }
            case WinNative.WM_MOUSEWHEEL:
            {
                // WHEEL_DELTA 120 per notch → 40 px, the Mac's line-scroll feel.
                short d = (short)(m.mouseData >> 16);
                if (d != 0) Send(PeerMsg.Scroll(0, d / 3f));
                return true;
            }
            case WinNative.WM_MOUSEHWHEEL:
            {
                // Windows: positive = right; macOS horizontal axis: positive = left.
                short d = (short)(m.mouseData >> 16);
                if (d != 0) Send(PeerMsg.Scroll(-d / 3f, 0));
                return true;
            }
            default:
                return true; // middle / X buttons: swallowed, the wire has left/right only
        }
    }

    // MARK: - Keyboard

    private IntPtr KeyHook(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && _remote is not null)
        {
            var k = Marshal.PtrToStructure<WinNative.KBDLLHOOKSTRUCT>(lParam);
            if (k.dwExtraInfo != InputInjector.Tag)
            {
                try { ForwardKey(k); }
                catch (Exception e) { Log.Line($"PEER: key hook error {e.Message}"); }
                return new IntPtr(1);
            }
        }
        return WinNative.CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
    }

    private void ForwardKey(WinNative.KBDLLHOOKSTRUCT k)
    {
        bool down = (k.flags & WinNative.LLKHF_UP) == 0;
        bool extended = (k.flags & WinNative.LLKHF_EXTENDED) != 0;
        uint vk = k.vkCode;
        // Right Ctrl / right Alt arrive as VK_CONTROL/VK_MENU + extended on some layouts.
        if (vk == PeerKeys.VK_CONTROL) vk = extended ? PeerKeys.VK_RCONTROL : PeerKeys.VK_LCONTROL;
        if (vk == PeerKeys.VK_MENU) vk = extended ? PeerKeys.VK_RMENU : PeerKeys.VK_LMENU;
        if (vk == PeerKeys.VK_SHIFT) vk = k.scanCode == 0x36 ? PeerKeys.VK_RSHIFT : PeerKeys.VK_LSHIFT;
        if (PeerKeys.MacCode(vk, extended) is not { } mac) return;

        if (PeerKeys.IsModifier(mac))
        {
            ulong bit = PeerKeys.ModifierBit(mac);
            if (mac == 57)
            {
                // Caps Lock: a tap on key down, like a Mac keyboard reports it.
                if (!down) return;
                _flags ^= PeerKeys.FlagAlphaShift;
                Send(PeerMsg.Key(mac, true, _flags));
                Send(PeerMsg.Key(mac, false, _flags));
                return;
            }
            if (down) { if (!_macDown.Add(mac)) return; _flags |= bit; }
            else
            {
                _macDown.Remove(mac);
                // Keep the bit while the other side's twin is still held.
                if (!_macDown.Any(c => PeerKeys.ModifierBit(c) == bit)) _flags &= ~bit;
            }
            Send(PeerMsg.Key(mac, down, _flags));
            return;
        }
        if (down && PeerKeys.IsPanic(vk, _flags))
        {
            Later(() => ReturnHome(0.5));
            return;
        }
        ulong flags = _flags | (PeerKeys.IsKeypad(mac) ? PeerKeys.FlagNumericPad : 0);
        if (down) _macDown.Add(mac); else _macDown.Remove(mac);
        Send(PeerMsg.Key(mac, down, flags));
    }

    /// Lets go of anything still held on the peer when control comes back.
    private void ReleaseRemoteModifiers(bool send)
    {
        if (send)
            foreach (var mac in _macDown) Send(PeerMsg.Key(mac, false, 0));
        _macDown.Clear();
        _flags &= PeerKeys.FlagAlphaShift;
    }
}

/// A 32×32 topmost window with a blank cursor, parked under the frozen
/// pointer while the peer has control, so the arrow disappears.
internal sealed class BlankCursorWindow : Form
{
    private static readonly Cursor Blank = MakeBlank();

    public BlankCursorWindow()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        Opacity = 0.01;
        Size = new System.Drawing.Size(32, 32);
        Cursor = Blank;
    }

    private static Cursor MakeBlank()
    {
        using var bmp = new System.Drawing.Bitmap(32, 32, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        return new Cursor(bmp.GetHicon());
    }

    public void ShowAt(int x, int y)
    {
        if (!Visible) Show();
        WinNative.SetWindowPos(Handle, new IntPtr(-1), x - 16, y - 16, 32, 32, WinNative.SWP_NOACTIVATE);
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
