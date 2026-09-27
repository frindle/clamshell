namespace Clamshell;

// The controlled half of the shared-desk KVM on Windows — the twin of
// RemoteInputSink.swift. Input a linked peer forwards while its cursor is on
// this PC, injected on the primary display with SendInput (tagged, so our
// own EdgeController ignores it). Honoured only between EDGE_ENTER and
// EDGE_LEAVE.
//
// Carry mode: EDGE_ENTER with leftButtonDown=1 means the peer is dragging
// something across (files or a window). No press is injected — the
// ReceiverForm follows the cursor instead — and the matching left release
// ends the carry without being injected.
//
// Scroll arrives as macOS pixel deltas (vertical: positive = up, horizontal:
// positive = left); Windows wheel units are 120 per notch ≈ 40 px, so ×3.
//
// UI thread only.
internal sealed class RemoteInputSink : IDisposable
{
    private InputInjector? _injector;
    private Rect _bounds;
    public bool Active { get; private set; }
    public PeerEdge EntryEdge { get; private set; } = PeerEdge.Left;
    public bool Carrying { get; private set; }
    private bool _leftDown;
    public readonly CarryDetector Carry = new();
    public Action<bool> OnActiveChange = _ => { };
    public Action OnCarryEnded = () => { };

    public void Enter(EdgeEnterPayload e)
    {
        _bounds = WinNative.PrimaryDisplay();
        _injector = new InputInjector(DisplayRect.Of(_bounds));
        Active = true;
        EntryEdge = e.Edge;
        Carrying = e.LeftButtonDown;
        _leftDown = false;
        // Files dragged from this PC go out through the edge the peer came in by.
        Carry.Edge = e.Edge;
        Carry.OnlyDisplay = _bounds;
        _injector.MouseMove(e.X, e.Y);
        Log.Line($"PEER: peer took control (entered on {e.Edge.Name()}{(Carrying ? ", carrying" : "")})");
        OnActiveChange(true);
    }

    /// The peer's cursor left. Reports what its (injected) left button was
    /// carrying — possibly after a short wait for a file drag's DragEnter on
    /// the drop strip — then releases everything.
    public void Leave(Action<Carry?, double> done)
    {
        if (!Active) { done(null, 0.5); return; }
        var (cx, cy) = WinNative.Cursor();
        double fraction = EntryEdge is PeerEdge.Left or PeerEdge.Right
            ? (_bounds.H > 0 ? (cy - _bounds.Y) / _bounds.H : 0.5)
            : (_bounds.W > 0 ? (cx - _bounds.X) / _bounds.W : 0.5);
        fraction = Math.Clamp(fraction, 0, 1);
        if (!_leftDown) { Finish(null); return; }

        var c = Carry.Evaluate();
        if (c is not null || !Carry.OnStrip(cx, cy)) { Finish(c); return; }
        // On the drop strip with the button down: the drag source may not
        // have reported the files yet. Give it a quarter second.
        int tries = 0;
        var t = new System.Windows.Forms.Timer { Interval = 25 };
        t.Tick += (_, _) =>
        {
            var c2 = Carry.Evaluate();
            if (c2 is null && ++tries < 10) return;
            t.Dispose();
            Finish(c2);
        };
        t.Start();

        void Finish(Carry? carry)
        {
            if (carry is Carry.Files) CarryDetector.CancelLocalDrag(files: true);
            _injector?.ReleaseAll();
            Carry.MouseUp();
            _leftDown = false; Carrying = false; Active = false;
            Log.Line($"PEER: peer released control{(carry is null ? "" : " carrying " + carry.Describe())}");
            OnActiveChange(false);
            done(carry, fraction);
        }
    }

    /// Link dropped while the peer had control.
    public void Reset()
    {
        if (!Active) return;
        _injector?.ReleaseAll();
        Carry.MouseUp();
        Active = false; Carrying = false; _leftDown = false;
        OnActiveChange(false);
    }

    public void Handle(MessageType type, byte[] p)
    {
        if (!Active || _injector is not { } inj) return;
        switch (type)
        {
            case MessageType.MouseMove when p.Length >= 8:
                inj.MouseMove(Be.F32(p, 0), Be.F32(p, 4));
                break;
            case MessageType.MouseButton when p.Length >= 10:
            {
                byte button = p[0]; bool down = p[1] == 1;
                float x = Be.F32(p, 2), y = Be.F32(p, 6);
                if (Carrying && button == 0)
                {
                    if (!down) { Carrying = false; OnCarryEnded(); }
                    return;
                }
                if (button == 0)
                {
                    _leftDown = down;
                    if (down)
                        Carry.MouseDown(_bounds.X + Math.Clamp(x, 0, 1) * _bounds.W, _bounds.Y + Math.Clamp(y, 0, 1) * _bounds.H);
                    else
                        Carry.MouseUp();
                }
                inj.MouseButton(button, down, x, y);
                break;
            }
            case MessageType.Key when p.Length >= 11:
                inj.Key(Be.U16(p, 0), p[2] == 1, Be.U64(p, 3));
                break;
            case MessageType.Scroll when p.Length >= 8:
            {
                float dx = Be.F32(p, 0), dy = Be.F32(p, 4);
                if (!float.IsFinite(dx) || !float.IsFinite(dy)) return;
                inj.Wheel((int)Math.Round(-dx * 3), (int)Math.Round(dy * 3));
                break;
            }
        }
    }

    public void Dispose() { Reset(); Carry.Dispose(); }
}
