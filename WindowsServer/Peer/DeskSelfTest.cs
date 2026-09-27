using System.Diagnostics;
using System.Net.WebSockets;
using System.Runtime.InteropServices;

namespace Clamshell;

// `ClamshellServer deskselftest` — the shared-desk pieces that need a real
// Windows desktop session (CI's windows-latest has one): low-level hooks,
// SendInput, Windows.Graphics.Capture, Media Foundation, WinForms. Each
// check runs the real code, not a model of it:
//
//   edge      hooks installed; an UNTAGGED SendInput push past the right
//             edge sends EDGE_ENTER + MOUSE_MOVE; keys are swallowed and
//             forwarded as macOS codes; the panic key returns control with
//             EDGE_LEAVE; a TAGGED (our own) push never crosses
//   carry     a moved window under the press = window carry (Notepad), one
//             of our receivers = receiver carry, our own form = nothing
//   stream    WGC capture of a window, HELLO → HELLO_ACK with its size,
//             a stranger's address refused, posted clicks land on the
//             mapped point even while parked (invisible, click-through),
//             capture continues while parked, restore, typing into Notepad
//   handoff   two HandoffManagers back to back: BEGIN → receiver form →
//             ACCEPT → RETURN restores the window; closing the source
//             window sends WINDOW_CLOSED and closes the receiver
//   video     frames encoded + decoded end to end — WARN (not FAIL) when
//             the runner's software H.264 encoder won't start (known gap)
//
// Moves the real cursor and injects real input: run it on CI or a test VM,
// not on a machine someone is using.
internal static class DeskSelfTest
{
    private static int _fail, _pass, _warn;

    private static void Check(bool ok, string what)
    {
        if (ok) { _pass++; Console.WriteLine($"ok   {what}"); }
        else { _fail++; Console.WriteLine($"FAIL {what}"); }
        Step(what);
    }

    private static void Warn(string what) { _warn++; Console.WriteLine($"WARN {what}"); Step(what); }

    // Watchdog: a hang names the last step instead of eating the CI timeout.
    private static string _step = "start";
    private static long _stepAt = Environment.TickCount64;
    private static void Step(string what) { Volatile.Write(ref _step, what); Interlocked.Exchange(ref _stepAt, Environment.TickCount64); }

    /// On a hang: which windows exist, who is foreground, who is hung.
    private static void DumpWindows()
    {
        try
        {
            IntPtr fg = GetForegroundWindow();
            Console.WriteLine($"  foreground: {Describe(fg)}");
            EnumWindows((h, _) =>
            {
                if (WinNative.IsWindowVisible(h)) Console.WriteLine($"  {Describe(h)}");
                return true;
            }, IntPtr.Zero);
        }
        catch (Exception e) { Console.WriteLine($"  (window dump failed: {e.Message})"); }
    }

    private static string Describe(IntPtr h)
    {
        if (h == IntPtr.Zero) return "(none)";
        uint tid = WinNative.GetWindowThreadProcessId(h, out uint pid);
        string proc = "?";
        try { proc = Process.GetProcessById((int)pid).ProcessName; } catch { }
        return $"0x{h:X} {WinNative.ClassName(h)} \"{WinNative.Title(h)}\" {proc} pid {pid} tid {tid}" +
               $"{(pid == (uint)Environment.ProcessId ? " (us)" : "")}{(IsHungAppWindow(h) ? " HUNG" : "")}";
    }

    private delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] private static extern bool IsHungAppWindow(IntPtr h);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();

    private static void StartWatchdog()
    {
        new Thread(() =>
        {
            while (true)
            {
                Thread.Sleep(1000);
                if (Environment.TickCount64 - Interlocked.Read(ref _stepAt) > 45000)
                {
                    Console.WriteLine($"FAIL HANG: no progress for 45 s after \"{Volatile.Read(ref _step)}\"");
                    DumpWindows();
                    Console.Out.Flush();
                    Environment.Exit(3);
                }
            }
        }) { IsBackground = true }.Start();
    }

    /// Pumps the UI thread until `cond` or the timeout.
    private static bool Pump(Func<bool> cond, int ms)
    {
        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < ms)
        {
            Application.DoEvents();
            if (cond()) return true;
            Thread.Sleep(10);
        }
        Application.DoEvents();
        return cond();
    }

    private static void PumpFor(int ms) => Pump(() => false, ms);

    public static int Run()
    {
        WinNative.EnsurePerMonitorDpi();
        Application.EnableVisualStyles();
        SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());
        StartWatchdog();
        WindowInput.Trace = true;
        try { Edge(); } catch (Exception e) { Check(false, $"edge: threw {e}"); }
        try { CarryChecks(); } catch (Exception e) { Check(false, $"carry: threw {e}"); }
        try { Stream(); } catch (Exception e) { Check(false, $"stream: threw {e}"); }
        try { ParkProbe(); } catch (Exception e) { Warn($"park probe: threw {e.Message}"); }
        try { Handoff(); } catch (Exception e) { Check(false, $"handoff: threw {e}"); }
        Console.WriteLine(_fail == 0 ? $"PASS ({_pass} checks, {_warn} warnings)" : $"FAILED: {_fail} of {_pass + _fail} checks");
        return _fail == 0 ? 0 : 1;
    }

    // MARK: - edge

    private static void Edge()
    {
        var sent = new List<(MessageType T, byte[] P)>();
        var ec = new EdgeController(PeerEdge.Right)
        {
            PeerSize = () => (1440, 900),
            Send = d => { lock (sent) sent.Add(((MessageType)d[0], d[5..])); },
        };
        Check(ec.Start(), "edge: low-level mouse + keyboard hooks installed");
        var displays = WinNative.Displays();
        // The display whose right edge nothing continues past.
        var d = displays.First(r => !displays.Any(o => o.Contains(r.MaxX + 1, r.Y + r.H / 2)));
        int y = (int)(d.Y + d.H / 2);

        int Count(MessageType t) { lock (sent) return sent.Count(m => m.T == t); }

        // A tagged push (what we inject for a peer) must never cross.
        WinNative.SetCursorPos((int)d.MaxX - 1, y);
        PumpFor(100);
        Inject.Move(40, 0, tagged: true);
        PumpFor(300);
        Check(!ec.IsControllingPeer && Count(MessageType.EdgeEnter) == 0, "edge: our own tagged injected push at the edge does not cross");

        // A user push crosses.
        WinNative.SetCursorPos((int)d.MaxX - 1, y);
        PumpFor(100);
        Inject.Move(40, 0, tagged: false);
        Pump(() => ec.IsControllingPeer, 2000);
        Check(ec.IsControllingPeer, "edge: an untagged push past the right edge gives control to the peer");
        byte[]? enter; lock (sent) enter = sent.FirstOrDefault(m => m.T == MessageType.EdgeEnter).P;
        var e = enter is null ? null : PeerParse.EdgeEnter(enter);
        Check(e is { Edge: PeerEdge.Left, X: 0, LeftButtonDown: false } && Math.Abs(e.Value.Y - 0.5f) < 0.05f,
              $"edge: EDGE_ENTER(left edge of the peer, x=0, y≈0.5, no carry) — got {e}");

        // Moves go out as normalized MOUSE_MOVE and never move the local cursor off the park point.
        int moves = Count(MessageType.MouseMove);
        Inject.Move(30, 10, tagged: false);
        Pump(() => Count(MessageType.MouseMove) > moves, 1500);
        byte[]? mv; lock (sent) mv = sent.LastOrDefault(m => m.T == MessageType.MouseMove).P;
        Check(mv is not null && Be.F32(mv, 0) > 0, "edge: mouse moves while controlling are forwarded (x grew from the left edge)");
        var (cx, cy) = WinNative.Cursor();
        Check(Math.Abs(cx - (d.X + d.W / 2)) <= 2 && Math.Abs(cy - (d.Y + d.H / 2)) <= 2, $"edge: local cursor stays parked mid-display ({cx},{cy})");

        // Keys: swallowed here, forwarded as macOS codes ('A' = kVK_ANSI_A = 0).
        int keys = Count(MessageType.Key);
        Inject.Key(0x41, true, tagged: false); Inject.Key(0x41, false, tagged: false);
        Pump(() => Count(MessageType.Key) >= keys + 2, 1500);
        List<byte[]> ks; lock (sent) ks = sent.Where(m => m.T == MessageType.Key).Select(m => m.P).ToList();
        Check(ks.Count >= 2 && Be.U16(ks[^2], 0) == 0 && ks[^2][2] == 1 && ks[^1][2] == 0, "edge: 'A' forwarded as mac key 0 down/up");

        // Ctrl → Command flag.
        Inject.Key(0xA2, true, tagged: false); Inject.Key(0x43, true, tagged: false);
        Inject.Key(0x43, false, tagged: false); Inject.Key(0xA2, false, tagged: false);
        Pump(() => Count(MessageType.Key) >= keys + 6, 1500);
        lock (sent) ks = sent.Where(m => m.T == MessageType.Key).Select(m => m.P).ToList();
        var cDown = ks.FirstOrDefault(k => Be.U16(k, 0) == 8 && k[2] == 1);
        Check(ks.Any(k => Be.U16(k, 0) == 55 && k[2] == 1) && cDown is not null && (Be.U64(cDown, 3) & PeerKeys.FlagCommand) != 0,
              "edge: Ctrl+C forwarded as Command(55) + 'c'(8) with the Command flag");

        // Panic: Ctrl+Alt+Shift+L.
        foreach (ushort vk in new ushort[] { 0xA2, 0xA4, 0xA0 }) Inject.Key(vk, true, tagged: false);
        Inject.Key(0x4C, true, tagged: false); Inject.Key(0x4C, false, tagged: false);
        foreach (ushort vk in new ushort[] { 0xA0, 0xA4, 0xA2 }) Inject.Key(vk, false, tagged: false);
        Pump(() => !ec.IsControllingPeer, 2000);
        Check(!ec.IsControllingPeer && Count(MessageType.EdgeLeave) == 1, "edge: panic key takes control back and sends EDGE_LEAVE");
        (cx, _) = WinNative.Cursor();
        Check(cx >= d.MaxX - 10 && cx < d.MaxX, $"edge: cursor re-enters just inside the right edge (x={cx})");

        // Cross again and come back by moving out through the peer's left edge.
        WinNative.SetCursorPos((int)d.MaxX - 1, y);
        PumpFor(100);
        Inject.Move(40, 0, tagged: false);
        Pump(() => ec.IsControllingPeer, 2000);
        for (int i = 0; i < 20 && ec.IsControllingPeer; i++) { Inject.Move(-200, 0, tagged: false); PumpFor(40); }
        Check(!ec.IsControllingPeer && Count(MessageType.EdgeLeave) == 2, "edge: moving back out through the peer's entry edge returns control");
        ec.Dispose();
        PumpFor(100);
    }

    // MARK: - carry

    private static Process? StartNotepad()
    {
        try
        {
            var p = Process.Start("notepad.exe");
            for (int i = 0; i < 100 && p.MainWindowHandle == IntPtr.Zero; i++) { Thread.Sleep(100); p.Refresh(); }
            return p.MainWindowHandle == IntPtr.Zero ? null : p;
        }
        catch { return null; }
    }

    private static void CarryChecks()
    {
        using var own = TestForm("carry test");
        own.Show();
        own.Activate();
        PumpFor(300);
        var cd = new CarryDetector { DropStripsEnabled = false };
        var f = WinNative.Frame(own.Handle)!.Value;
        double px = f.Left + f.Width / 2.0, py = f.Top + f.Height / 2.0;
        var under = WinNative.RootWindowAt(px, py);
        if (under != own.Handle) Log.Line($"deskselftest: press point resolves to {WinNative.ClassName(under)} \"{WinNative.Title(under)}\", not the test form");
        cd.MouseDown(px, py);
        own.Location = new System.Drawing.Point(own.Location.X + 60, own.Location.Y + 30);
        PumpFor(100);
        Check(cd.Evaluate() is null, "carry: moving our own (non-receiver) form carries nothing");
        cd.ReceiverLookup = h => h == own.Handle ? 7u : null;
        Check(cd.Evaluate() is Carry.Receiver { SourceWindowId: 7 }, "carry: moving one of our receivers = receiver carry");
        cd.MouseUp();

        var np = StartNotepad();
        if (np is null) { Warn("carry: notepad unavailable — external-window carry not checked"); return; }
        try
        {
            IntPtr h = np.MainWindowHandle;
            WinNative.SetWindowPos(h, new IntPtr(-1), 100, 100, 500, 350, WinNative.SWP_NOACTIVATE);
            PumpFor(300);
            var nf = WinNative.Frame(h)!.Value;
            var cd2 = new CarryDetector { DropStripsEnabled = false };
            cd2.MouseDown(nf.Left + 100, nf.Top + 12);
            Check(cd2.Evaluate() is null, "carry: a press that hasn't moved anything carries nothing");
            WinNative.SetWindowPos(h, IntPtr.Zero, 180, 140, 0, 0, WinNative.SWP_NOSIZE | WinNative.SWP_NOZORDER | WinNative.SWP_NOACTIVATE);
            PumpFor(200);
            var c = cd2.Evaluate();
            Check(c is Carry.Window w && w.Handle == h && Math.Abs(w.GrabX - 100.0 / nf.Width) < 0.02 && w.PreDragFrame.X == nf.Left,
                  $"carry: dragging Notepad = window carry with its grab point and pre-drag frame ({c?.Describe()})");
        }
        finally { try { np.Kill(); } catch { } }
    }

    // MARK: - stream

    private sealed class TestWindow : Form
    {
        public (int X, int Y)? LastClick;
        public int Clicks;
        private readonly System.Windows.Forms.Timer _anim = new() { Interval = 30 };
        private int _t;

        public TestWindow(string title)
        {
            Text = title;
            StartPosition = FormStartPosition.Manual;
            Location = new System.Drawing.Point(80, 80);
            TopMost = true; // a console-launched form may open behind other windows
            ClientSize = new System.Drawing.Size(480, 320);
            _anim.Tick += (_, _) => { _t++; BackColor = System.Drawing.Color.FromArgb(_t * 7 % 256, 90, 200); };
            _anim.Start();
            MouseDown += (_, e) => { LastClick = (e.X, e.Y); Clicks++; };
        }

        protected override void Dispose(bool disposing) { if (disposing) _anim.Dispose(); base.Dispose(disposing); }
    }

    private static TestWindow TestForm(string title) => new(title);

    private static async Task<(ClientWebSocket Ws, List<(MessageType, byte[])> Got)> Dial(ushort port)
    {
        var ws = new ClientWebSocket();
        await ws.ConnectAsync(new Uri($"ws://127.0.0.1:{port}/"), CancellationToken.None);
        var got = new List<(MessageType, byte[])>();
        var parser = new FrameParser { OnMessage = (t, p) => { lock (got) got.Add((t, p)); } };
        _ = Task.Run(async () =>
        {
            var buf = new byte[1 << 20];
            try
            {
                while (ws.State == WebSocketState.Open)
                {
                    var r = await ws.ReceiveAsync(buf, CancellationToken.None);
                    if (r.MessageType == WebSocketMessageType.Close) break;
                    parser.Feed(buf.AsSpan(0, r.Count));
                }
            }
            catch { }
        });
        return (ws, got);
    }

    private static void Post(ClientWebSocket ws, byte[] d) =>
        ws.SendAsync(d, WebSocketMessageType.Binary, true, CancellationToken.None).GetAwaiter().GetResult();

    private static void Stream()
    {
        using var form = TestForm("Clamshell stream test");
        form.Show();
        PumpFor(400);
        const ushort port = 5933;
        using var server = new WindowStreamServer(form.Handle, port, "127.0.0.1");
        Check(true, $"stream: WGC capture + listener up on {port} ({server.Size.W}x{server.Size.H})");
        var frame = WinNative.Frame(form.Handle)!.Value;
        Check(Math.Abs(server.Size.W - frame.Width) <= 2 && Math.Abs(server.Size.H - frame.Height) <= 2,
              $"stream: capture size matches the window's visible frame ({frame.Width}x{frame.Height})");

        // Stranger refused.
        using (var other = new WindowStreamServer(form.Handle, (ushort)(port + 1), "10.255.255.1"))
        {
            bool refused;
            try
            {
                using var ws = new ClientWebSocket();
                var t = ws.ConnectAsync(new Uri($"ws://127.0.0.1:{port + 1}/"), CancellationToken.None);
                refused = !Pump(() => t.IsCompleted, 3000) || t.IsFaulted;
            }
            catch { refused = true; }
            Check(refused, "stream: a connection from an address other than the peer's is refused");
        }

        var dial = Dial(port);
        Pump(() => dial.IsCompleted, 5000);
        var (client, got) = dial.Result;
        Post(client, PeerMsg.StreamHello(StreamCodec.H264));
        bool Has(MessageType t) { lock (got) return got.Any(m => m.Item1 == t); }
        Pump(() => Has(MessageType.HelloAck), 5000);
        byte[]? ack; lock (got) ack = got.FirstOrDefault(m => m.Item1 == MessageType.HelloAck).Item2;
        Check(ack is not null && Be.U32(ack, 2) == server.Size.W && Be.U32(ack, 6) == server.Size.H,
              "stream: HELLO → HELLO_ACK carries the captured window's size");

        long before = WindowCaptureFrames(server);
        Pump(() => WindowCaptureFrames(server) > before + 5, 3000);
        Check(WindowCaptureFrames(server) > before + 5, "stream: WGC delivers frames of the (animating) window");

        // Posted click lands at the mapped point.
        void ClickAt(float nx, float ny)
        {
            Post(client, PeerMsg.MouseMove(nx, ny));
            Post(client, PeerMsg.MouseButton(0, true, nx, ny));
            Post(client, PeerMsg.MouseButton(0, false, nx, ny));
        }
        (int X, int Y) Expected(float nx, float ny)
        {
            var fr = WinNative.Frame(form.Handle)!.Value;
            var p = new WinNative.POINT { X = fr.Left + (int)(nx * (fr.Width - 1)), Y = fr.Top + (int)(ny * (fr.Height - 1)) };
            WinNative.ScreenToClient(form.Handle, ref p);
            return (p.X, p.Y);
        }
        int clicks = form.Clicks;
        ClickAt(0.5f, 0.6f);
        Pump(() => form.Clicks > clicks, 2000);
        var exp = Expected(0.5f, 0.6f);
        Check(form.LastClick is { } lc && Math.Abs(lc.X - exp.X) <= 2 && Math.Abs(lc.Y - exp.Y) <= 2,
              $"stream: posted click lands on the mapped point ({form.LastClick} vs {exp})");

        // Park: invisible + click-through in place, still captured, still
        // clickable; restore puts it back.
        var parker = new WindowParker(form.Handle, null);
        var origin = form.Location;
        parker.Park();
        PumpFor(200);
        Check(IsGhost(form.Handle) && form.Location == origin, $"stream: parked = invisible (alpha 0) and click-through, in place");
        long parkedFrom = WindowCaptureFrames(server);
        Pump(() => WindowCaptureFrames(server) > parkedFrom + 5, 3000);
        Check(WindowCaptureFrames(server) > parkedFrom + 5, "stream: capture keeps delivering live frames while parked");
        clicks = form.Clicks;
        ClickAt(0.3f, 0.7f);
        Pump(() => form.Clicks > clicks, 2000);
        exp = Expected(0.3f, 0.7f);
        Check(form.LastClick is { } lc2 && Math.Abs(lc2.X - exp.X) <= 2 && Math.Abs(lc2.Y - exp.Y) <= 2,
              $"stream: posted click still lands while parked ({form.LastClick} vs {exp})");
        parker.Restore();
        PumpFor(100);
        Check(form.Location == origin && !IsGhost(form.Handle) && (WinNative.GetWindowLong(form.Handle, -20) & 0x80000) == 0,
              $"stream: restore makes the window visible and clickable again ({form.Location} vs {origin})");

        // Video end to end.
        Pump(() => Has(MessageType.VideoFrame), 4000);
        List<byte[]> frames; lock (got) frames = got.Where(m => m.Item1 == MessageType.VideoFrame).Select(m => m.Item2).ToList();
        if (frames.Count == 0)
            Warn("video: no VIDEO_FRAME — the runner's software H.264 encoder did not start (known CI gap); capture + input proven above");
        else
        {
            int decoded = 0;
            using var dec = new PeerVideoDecoder((StreamCodec)ack![1]);
            dec.OnFrame = (w, h, _) => { if (w > 0 && h > 0) decoded++; };
            foreach (var f in frames) { try { dec.Feed(f.AsSpan(9), Be.U64(f, 1)); } catch { } }
            Check(decoded > 0, $"video: {frames.Count} frame(s) encoded from the window, {decoded} decoded");
        }

        // Typing into another app's window (posted WM_CHAR or SendInput when foreground).
        var np = StartNotepad();
        if (np is null) Warn("stream: notepad unavailable — typing not checked");
        else
        {
            try
            {
                Console.WriteLine($"info notepad: {Describe(np.MainWindowHandle)}, edit 0x{FindWindowEx(np.MainWindowHandle, IntPtr.Zero, "Edit", null):X}");
                using var ns = new WindowStreamServer(np.MainWindowHandle, (ushort)(port + 2), "127.0.0.1");
                var nd = Dial((ushort)(port + 2));
                Pump(() => nd.IsCompleted, 5000);
                var (nc, _) = nd.Result;
                Post(nc, PeerMsg.StreamHello(StreamCodec.H264));
                Post(nc, PeerMsg.MouseButton(0, true, 0.5f, 0.6f));
                Post(nc, PeerMsg.MouseButton(0, false, 0.5f, 0.6f));
                PumpFor(300);
                foreach (ushort mac in new ushort[] { 4, 34 }) // 'h', 'i'
                {
                    Post(nc, PeerMsg.Key(mac, true, 0));
                    Post(nc, PeerMsg.Key(mac, false, 0));
                }
                string text = "";
                Pump(() => (text = EditText(np.MainWindowHandle)).Contains("hi"), 3000);
                Check(text.Contains("hi"), $"stream: keys from the stream type into Notepad (\"{text}\")");
                nc.Dispose();
            }
            finally { try { np.Kill(); } catch { } }
        }
        client.Dispose();
    }

    private static long WindowCaptureFrames(WindowStreamServer s) => s.CaptureFrames;

    private static bool IsGhost(IntPtr h)
    {
        int ex = WinNative.GetWindowLong(h, -20);
        if ((ex & 0x80000) == 0 || (ex & 0x20) == 0) return false;
        return WinNative.GetLayeredWindowAttributes(h, out _, out byte alpha, out uint flags) && (flags & 2) != 0 && alpha == 0;
    }

    private static string EditText(IntPtr root)
    {
        var sb = new System.Text.StringBuilder(1024);
        foreach (string cls in new[] { "Edit", "RichEditD2DPT" })
        {
            IntPtr h = FindWindowEx(root, IntPtr.Zero, cls, null);
            if (h == IntPtr.Zero) continue;
            SendMessage(h, 0x000D /* WM_GETTEXT */, (IntPtr)sb.Capacity, sb);
            return sb.ToString();
        }
        IntPtr f = WinNative.FocusOf(root);
        if (f != IntPtr.Zero) SendMessage(f, 0x000D, (IntPtr)sb.Capacity, sb);
        return sb.ToString();
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string? title);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, System.Text.StringBuilder l);

    // MARK: - park probe (measurement, never fails)
    //
    // Does WGC keep delivering fresh frames for a window parked off-screen,
    // or for one left on-screen but made (almost) fully transparent and
    // click-through? Prints frames/2 s and the mean luma of the centre row so
    // a transparent capture (black) is told apart from real content.

    private static void ParkProbe()
    {
        using var form = TestForm("Clamshell park probe");
        form.Show();
        PumpFor(300);
        using var cap = new WindowCapture(form.Handle);
        int lumaNow = -1;
        cap.OnNv12 = nv12 =>
        {
            int row = cap.Height / 2 * cap.Width, sum = 0;
            for (int x = 0; x < cap.Width; x++) sum += nv12[row + x];
            Volatile.Write(ref lumaNow, sum / Math.Max(cap.Width, 1));
        };
        (long Frames, int Luma) Measure()
        {
            long f0 = Interlocked.Read(ref cap.Frames);
            PumpFor(2000);
            return (Interlocked.Read(ref cap.Frames) - f0, Volatile.Read(ref lumaNow));
        }
        var on = Measure();
        var parker = new WindowParker(form.Handle, null);
        parker.ParkOffScreen();
        var off = Measure();
        parker.Restore();
        PumpFor(200);
        parker.Park();
        var ghost = Measure();
        parker.Restore();
        PumpFor(200);
        var back = Measure();
        Console.WriteLine($"info park probe: frames/2s (centre-row luma) on-screen {on.Frames} ({on.Luma}), moved off-screen {off.Frames} ({off.Luma}), " +
                          $"ghost park {ghost.Frames} ({ghost.Luma}), restored {back.Frames} ({back.Luma})");
        Step("park probe");
    }

    // MARK: - handoff

    private static void Handoff()
    {
        var ui = SynchronizationContext.Current!;
        var a = new HandoffManager { AllowOwnProcessWindows = true };
        var b = new HandoffManager();
        var aSent = new List<MessageType>();
        var bSent = new List<MessageType>();
        a.PeerHost = () => "127.0.0.1";
        b.PeerHost = () => "127.0.0.1";
        a.Send = d => { aSent.Add((MessageType)d[0]); ui.Post(_ => b.Receive((MessageType)d[0], d[5..]), null); };
        b.Send = d => { bSent.Add((MessageType)d[0]); ui.Post(_ => a.Receive((MessageType)d[0], d[5..]), null); };

        using var form = TestForm("Clamshell handoff test");
        form.Show();
        PumpFor(400);
        var origin = form.Location;
        var fr = WinNative.Frame(form.Handle)!.Value.ToRect();
        var carry = new Carry.Window(form.Handle, (uint)Environment.ProcessId, fr, form.Text, "ClamshellServer", 0.3, 0.05, fr);
        Check(a.Begin(carry, PeerEdge.Left, 0.5), "handoff: begin serves the window and sends HANDOFF_BEGIN");
        Pump(() => b.ReceiverCount == 1 && bSent.Contains(MessageType.HandoffAccept), 3000);
        Check(b.ReceiverCount == 1, "handoff: receiver form opened on the other side");
        Check(bSent.Contains(MessageType.HandoffAccept), "handoff: receiver answered HANDOFF_ACCEPT");
        uint id = 1;
        var rf = b.Receiver(id);
        Pump(() => rf?.AckSize is not null, 5000);
        Check(rf?.AckSize is { } sz && sz.W > 0, $"handoff: receiver form dialled the window stream and got HELLO_ACK {rf?.AckSize}");
        if (rf is not null && Pump(() => rf.FramesShown > 0, 3000)) Check(true, $"handoff: receiver form is showing decoded frames ({rf.FramesShown})");
        else Warn("handoff: receiver form shows no frames — the runner's encoder gap (see video)");
        Check(IsGhost(form.Handle), "handoff: source window parked (invisible, click-through)");

        Step("handoff: sending the receiver back");
        b.ReturnReceiver(id, null, 0);
        Step("handoff: receiver closed, source ending the handoff");
        Pump(() => a.OutgoingCount == 0, 3000);
        PumpFor(100);
        Check(a.OutgoingCount == 0 && b.ReceiverCount == 0, "handoff: HANDOFF_RETURN closes the receiver and ends the handoff");
        Check(form.Location == origin && !IsGhost(form.Handle), $"handoff: the window is back, visible, where it was ({form.Location} vs {origin})");

        // The source window closing ends it from the other side.
        var form2 = TestForm("Clamshell handoff close test");
        form2.Show();
        PumpFor(300);
        var fr2 = WinNative.Frame(form2.Handle)!.Value.ToRect();
        a.Begin(new Carry.Window(form2.Handle, (uint)Environment.ProcessId, fr2, form2.Text, "ClamshellServer", 0.5, 0.05, fr2), PeerEdge.Left, 0.5);
        Pump(() => b.ReceiverCount == 1, 3000);
        Step("handoff: closing the source window");
        form2.Close(); form2.Dispose();
        Pump(() => b.ReceiverCount == 0, 4000);
        Check(aSent.Contains(MessageType.WindowClosed) && b.ReceiverCount == 0, "handoff: closing the source window sends WINDOW_CLOSED and closes the receiver");
        Step("handoff: disposing");
        a.Dispose(); b.Dispose();
        PumpFor(200);
    }

    // MARK: - raw SendInput (tagged or not), for driving the hooks like a user

    private static class Inject
    {
        [StructLayout(LayoutKind.Explicit, Size = 40)]
        private struct INPUT
        {
            [FieldOffset(0)] public uint type;
            [FieldOffset(8)] public int dx;
            [FieldOffset(12)] public int dy;
            [FieldOffset(16)] public uint mouseData;
            [FieldOffset(20)] public uint mflags;
            [FieldOffset(32)] public nuint mextra;
            [FieldOffset(8)] public ushort wVk;
            [FieldOffset(10)] public ushort wScan;
            [FieldOffset(12)] public uint kflags;
            [FieldOffset(24)] public nuint kextra;
        }

        [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint n, INPUT[] inputs, int size);

        // From a worker thread: the hooks live on this (UI) thread, which
        // must be free to pump while the input is delivered.
        private static void Send(INPUT i)
        {
            var t = Task.Run(() => SendInput(1, new[] { i }, Marshal.SizeOf<INPUT>()));
            Pump(() => t.IsCompleted, 2000);
        }

        public static void Move(int dx, int dy, bool tagged) =>
            Send(new INPUT { type = 0, dx = dx, dy = dy, mflags = 0x0001, mextra = tagged ? InputInjector.Tag : 0 });

        public static void Key(ushort vk, bool down, bool tagged)
        {
            Send(new INPUT { type = 1, wVk = vk, kflags = down ? 0u : 2u, kextra = tagged ? InputInjector.Tag : 0 });
            PumpFor(15);
        }
    }
}
