using System.Net;
using System.Net.Sockets;

namespace Clamshell;

// Window handoff over the peer link on Windows — the twin of
// HandoffManager.swift, same messages and timings:
//
// Source — a window was dragged across the peer edge (or picked from the
// tray menu): serve it on a fresh v1 window-stream port (5921-5940) only the
// peer's address may connect to, park it off-screen, send HANDOFF_BEGIN.
// HANDOFF_RETURN puts it back (under the cursor when dragged home, where it
// came from otherwise). No HANDOFF_ACCEPT within 15 s → it comes back. The
// window closing here sends WINDOW_CLOSED (checked every second).
//
// Receiver — HANDOFF_BEGIN opens a ReceiverForm on that stream (following
// the cursor while the carrying drag is held) and answers HANDOFF_ACCEPT.
// ↩ / close / dragging it back across the edge sends HANDOFF_RETURN.
//
// UI thread only.
internal sealed class HandoffManager : IDisposable
{
    public Action<byte[]> Send = _ => { };
    public Func<string?> PeerHost = () => null;
    /// Is the drag that carried a window here still held?
    public Func<bool> IsCarryHeld = () => false;
    public Action OnChange = () => { };
    /// deskselftest hands off its own test windows.
    public bool AllowOwnProcessWindows;
    public const ushort FirstPort = 5921, LastPort = 5940;

    private sealed class Outgoing
    {
        public required uint Id;
        public required WindowStreamServer Server;
        public required WindowParker Parker;
        public required double GrabX, GrabY;
        public bool Accepted;
    }

    private readonly Dictionary<uint, Outgoing> _outgoing = new();
    private readonly Dictionary<uint, ReceiverForm> _receivers = new();
    private readonly Dictionary<uint, IntPtr> _ids = new();
    private System.Windows.Forms.Timer? _watch, _followTimer;
    private uint _nextId = 1;

    public int OutgoingCount => _outgoing.Count;
    public int ReceiverCount => _receivers.Count;
    public ReceiverForm? Receiver(uint id) => _receivers.GetValueOrDefault(id);

    /// CarryDetector hook: which source window one of our forms shows.
    public uint? SourceWindowId(IntPtr hwnd) =>
        _receivers.FirstOrDefault(kv => !kv.Value.IsDisposed && kv.Value.Handle == hwnd) is { Value: not null } kv ? kv.Key : null;

    // MARK: - Source

    public bool Begin(Carry.Window w, PeerEdge peerEdge, double position)
    {
        if (_outgoing.Values.Any(o => o.Server.Window == w.Handle)) return false;
        if (w.Pid == (uint)Environment.ProcessId && !AllowOwnProcessWindows) { Log.Line("HANDOFF: not handing off Clamshell's own window"); return false; }
        if (PeerHost() is not { } host) { Log.Line("HANDOFF: no peer address"); return false; }
        uint id = _nextId++;
        WindowStreamServer? server = null;
        for (ushort port = FirstPort; port <= LastPort && server is null; port++)
        {
            if (_outgoing.Values.Any(o => o.Server.Port == port)) continue;
            try { server = new WindowStreamServer(w.Handle, port, host); }
            catch (SocketException e) when (e.SocketErrorCode == SocketError.AddressAlreadyInUse) { }
            catch (Exception e) { Log.Line($"HANDOFF: cannot capture \"{w.Title}\": {e.Message}"); return false; }
        }
        if (server is null) { Log.Line($"HANDOFF: no free window-stream port in {FirstPort}-{LastPort}"); return false; }
        var parker = new WindowParker(w.Handle, w.PreDragFrame);
        bool parked = parker.Park();
        _outgoing[id] = new Outgoing { Id = id, Server = server, Parker = parker, GrabX = w.GrabX, GrabY = w.GrabY };
        _ids[id] = w.Handle;
        var (sw, sh) = server.Size;
        Send(PeerMsg.HandoffBegin(new HandoffBeginPayload(id, peerEdge, (float)position, (float)w.GrabX, (float)w.GrabY,
            (uint)Math.Max(w.Frame.W, 1), (uint)Math.Max(w.Frame.H, 1), server.Port, w.Title, w.App)));
        Log.Line($"HANDOFF: \"{w.App} — {w.Title}\" → peer on port {server.Port} ({sw}x{sh}){(parked ? (parker.Ghosted ? ", hidden in place" : ", parked off-screen") : "")}");
        StartWatching();
        var timeout = new System.Windows.Forms.Timer { Interval = 15000 };
        timeout.Tick += (_, _) =>
        {
            timeout.Dispose();
            if (_outgoing.TryGetValue(id, out var o) && !o.Accepted)
            {
                Log.Line($"HANDOFF: peer never accepted window {id} — putting it back");
                FinishOutgoing(id, underCursor: false);
            }
        };
        timeout.Start();
        OnChange();
        return true;
    }

    /// Tray menu: take every handed-off window back from the peer.
    public void BringBackAll()
    {
        foreach (var id in _outgoing.Keys.ToList())
        {
            Send(PeerMsg.WindowClosed(id));
            FinishOutgoing(id, underCursor: false);
        }
    }

    private void FinishOutgoing(uint id, bool underCursor)
    {
        if (!_outgoing.Remove(id, out var o)) return;
        _ids.Remove(id);
        Log.Line($"HANDOFF: ending window {id}'s stream");
        o.Server.Dispose();
        if (WinNative.IsWindow(o.Parker.Handle))
        {
            if (underCursor) FollowCursor(o.Parker, o.GrabX, o.GrabY);
            else o.Parker.Restore();
            WinNative.SetForegroundWindow(o.Parker.Handle);
        }
        Log.Line($"HANDOFF: window {id} back on this PC");
        if (_outgoing.Count == 0) { _watch?.Dispose(); _watch = null; }
        OnChange();
    }

    /// A returned window follows the cursor (grab point under it) while the
    /// drag that brought it home is still held.
    private void FollowCursor(WindowParker p, double gx, double gy)
    {
        _followTimer?.Dispose();
        var (w, h) = p.Size;
        void Move()
        {
            var (cx, cy) = WinNative.Cursor();
            p.MoveTo((int)(cx - gx * w), (int)(cy - gy * h));
        }
        Move();
        var t = new System.Windows.Forms.Timer { Interval = 33 };
        t.Tick += (_, _) => { if (!IsCarryHeld()) { t.Dispose(); return; } Move(); };
        _followTimer = t;
        t.Start();
    }

    private void StartWatching()
    {
        if (_watch is not null) return;
        _watch = new System.Windows.Forms.Timer { Interval = 1000 };
        _watch.Tick += (_, _) =>
        {
            foreach (var id in _outgoing.Keys.ToList())
            {
                if (WinNative.IsWindow(_outgoing[id].Parker.Handle)) continue;
                Log.Line($"HANDOFF: window {id} closed on this PC");
                Send(PeerMsg.WindowClosed(id));
                _outgoing[id].Server.Dispose();
                _outgoing.Remove(id);
                _ids.Remove(id);
                OnChange();
            }
            if (_outgoing.Count == 0) { _watch?.Dispose(); _watch = null; }
        };
        _watch.Start();
    }

    // MARK: - Receiver

    public void ReturnReceiver(uint sourceWindowId, PeerEdge? edge, double position)
    {
        if (!_receivers.Remove(sourceWindowId, out var f)) return;
        Log.Line($"HANDOFF: sending window {sourceWindowId} back to the peer");
        var sw = System.Diagnostics.Stopwatch.StartNew();
        f.CloseQuietly();
        if (sw.ElapsedMilliseconds > 500) Log.Line($"HANDOFF: closing the receiver took {sw.ElapsedMilliseconds} ms");
        Send(PeerMsg.HandoffReturn(sourceWindowId, edge, (float)position));
        OnChange();
    }

    private void OpenReceiver(HandoffBeginPayload b)
    {
        if (PeerHost() is not { } host) { Send(PeerMsg.HandoffReject(b.WindowId, PeerRejectReason.Error)); return; }
        if (_receivers.Remove(b.WindowId, out var old)) old.CloseQuietly();
        var wa = Screen.PrimaryScreen?.WorkingArea ?? new System.Drawing.Rectangle(0, 0, 1280, 720);
        double fit = Math.Min(1, Math.Min(wa.Width * 0.9 / Math.Max(b.Width, 1), (wa.Height * 0.9 - ReceiverForm.StripHeight) / Math.Max(b.Height, 1)));
        var size = new System.Drawing.Size((int)(b.Width * fit), (int)(b.Height * fit));
        var f = new ReceiverForm(b.WindowId, b.Title, b.AppName, size, host, b.StreamPort);
        f.OnReturnRequested = () => ReturnReceiver(b.WindowId, null, 0);
        _receivers[b.WindowId] = f;
        f.Place(b.Edge, b.Position);
        f.Show();
        f.Connect();
        if (IsCarryHeld()) f.Follow(b.GrabX, b.GrabY, IsCarryHeld);
        f.Activate();
        Send(PeerMsg.HandoffAccept(b.WindowId));
        Log.Line($"HANDOFF: showing \"{b.AppName} — {b.Title}\" from the peer ({b.Width}x{b.Height}, port {b.StreamPort})");
        OnChange();
    }

    // MARK: - Messages

    /// Returns true when the message was a handoff message.
    public bool Receive(MessageType type, byte[] p)
    {
        switch (type)
        {
            case MessageType.HandoffBegin:
                if (PeerParse.HandoffBegin(p) is { } b) OpenReceiver(b);
                break;
            case MessageType.HandoffAccept:
                if (PeerParse.WindowId(p) is { } id && _outgoing.TryGetValue(id, out var o)) o.Accepted = true;
                break;
            case MessageType.HandoffReject:
                if (PeerParse.IdAndReason(p) is { } r)
                {
                    Log.Line($"HANDOFF: peer declined window {r.Id} ({r.Reason})");
                    FinishOutgoing(r.Id, underCursor: false);
                }
                break;
            case MessageType.HandoffReturn:
                if (PeerParse.HandoffReturn(p) is { } ret) FinishOutgoing(ret.WindowId, underCursor: ret.Edge is not null);
                break;
            case MessageType.WindowClosed:
                if (PeerParse.WindowId(p) is { } wid && _receivers.Remove(wid, out var f)) { f.CloseQuietly(); OnChange(); }
                break;
            default:
                return false;
        }
        return true;
    }

    /// Link dropped: everything comes home, every receiver closes.
    public void Reset()
    {
        foreach (var id in _outgoing.Keys.ToList()) FinishOutgoing(id, underCursor: false);
        foreach (var f in _receivers.Values) f.CloseQuietly();
        _receivers.Clear();
        OnChange();
    }

    public void Dispose() => Reset();
}
