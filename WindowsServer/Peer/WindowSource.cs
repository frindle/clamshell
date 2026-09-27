using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Threading.Channels;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using WinRT;

namespace Clamshell;

// Window handoff, source side on Windows — the twin of the Mac's
// StreamServer(source: .window, allowedRemoteHost:) + WindowHider:
//
//   WindowCapture   Windows.Graphics.Capture of ONE top-level window →
//                   BGRA staging texture → NV12 (the encoder's fixed size;
//                   a window that grows is cropped, one that shrinks is
//                   padded with whatever was last there).
//   WindowParker    moves the real window almost entirely off the virtual
//                   screen (WGC keeps capturing it: DWM still renders it)
//                   and puts it back.
//   WindowInput     mouse → PostMessage to the child window under the point
//                   (the window is off-screen, so SendInput can't hit it);
//                   keys → SendInput when the window can be made foreground,
//                   else posted WM_KEYDOWN/WM_CHAR. Honest gaps: title-bar /
//                   frame clicks are ignored, and apps that read raw input or
//                   the async key state (games, some Chromium/UWP surfaces)
//                   may ignore posted mouse input.
//   WindowStreamServer  the v1 window stream (HELLO → HELLO_ACK →
//                   VIDEO_FRAME…, INPUT_* back) on a port from the handoff
//                   range, accepting only the linked peer's address.

internal sealed class WindowCapture : IDisposable
{
    public int Width { get; }
    public int Height { get; }
    /// Called on a capture thread with each converted NV12 frame.
    public Action<byte[]>? OnNv12;
    public long Frames;

    private readonly ID3D11Device _device;
    private readonly ID3D11DeviceContext _context;
    private readonly IDirect3DDevice _winrtDevice;
    private readonly GraphicsCaptureItem _item;
    private readonly Direct3D11CaptureFramePool _pool;
    private readonly GraphicsCaptureSession _session;
    private ID3D11Texture2D? _staging;
    private global::Windows.Graphics.SizeInt32 _poolSize;
    private readonly byte[] _nv12;
    private readonly object _lock = new();
    private bool _disposed;

    /// Must run on a thread with a DispatcherQueue (the UI thread).
    public WindowCapture(IntPtr hwnd)
    {
        WindowCaptureSelfTest.EnsureDispatcherQueue();
        _item = WindowCaptureSelfTest.CreateItemForWindow(hwnd);
        Width = Math.Max(_item.Size.Width & ~1, 64);
        Height = Math.Max(_item.Size.Height & ~1, 64);
        _nv12 = new byte[Width * Height * 3 / 2];
        D3D11.D3D11CreateDevice(null, DriverType.Hardware, DeviceCreationFlags.BgraSupport,
            Array.Empty<FeatureLevel>(), out ID3D11Device device, out ID3D11DeviceContext context).CheckError();
        _device = device; _context = context;
        _winrtDevice = WindowCaptureSelfTest.CreateDirect3DDevice(_device);
        _poolSize = _item.Size;
        _pool = Direct3D11CaptureFramePool.CreateFreeThreaded(_winrtDevice, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, _poolSize);
        _pool.FrameArrived += (p, _) => OnFrame(p);
        _session = _pool.CreateCaptureSession(_item);
        _session.IsCursorCaptureEnabled = false;
        _session.StartCapture();
    }

    private void OnFrame(Direct3D11CaptureFramePool pool)
    {
        using var frame = pool.TryGetNextFrame();
        if (frame is null) return;
        lock (_lock)
        {
            if (_disposed) return;
            var size = frame.ContentSize;
            try
            {
                using var tex = new ID3D11Texture2D(TexturePointer(frame.Surface));
                _staging ??= _device.CreateTexture2D(new Texture2DDescription
                {
                    Width = (uint)Width, Height = (uint)Height, MipLevels = 1, ArraySize = 1,
                    Format = Format.B8G8R8A8_UNorm, SampleDescription = new SampleDescription(1, 0),
                    Usage = ResourceUsage.Staging, CPUAccessFlags = CpuAccessFlags.Read,
                });
                int w = Math.Min(Width, size.Width), h = Math.Min(Height, size.Height);
                if (w > 0 && h > 0)
                    _context.CopySubresourceRegion(_staging, 0, 0, 0, 0, tex, 0, new Vortice.Mathematics.Box(0, 0, 0, w, h, 1));
                var map = _context.Map(_staging, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
                try { Bgra.ToNv12(map.DataPointer, (int)map.RowPitch, Width, Height, _nv12); }
                finally { _context.Unmap(_staging, 0); }
                Interlocked.Increment(ref Frames);
            }
            catch (Exception e) { Log.Line($"HANDOFF: capture frame failed: {e.Message}"); return; }
            if (size.Width != _poolSize.Width || size.Height != _poolSize.Height)
            {
                _poolSize = size; // the window was resized: let WGC hand us the new size next time
                try { pool.Recreate(_winrtDevice, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, size); } catch { }
            }
        }
        OnNv12?.Invoke(_nv12);
    }

    public void Dispose()
    {
        lock (_lock)
        {
            if (_disposed) return;
            _disposed = true;
        }
        try { _session.Dispose(); } catch { }
        try { _pool.Dispose(); } catch { }
        _staging?.Dispose();
        _context.Dispose();
        _device.Dispose();
    }

    // IDirect3DDxgiInterfaceAccess::GetInterface (vtable slot 3) on the
    // surface's ABI pointer; raw like CreateItemForWindow, because C#/WinRT
    // objects aren't COM runtime-callable wrappers a [ComImport] cast works on.
    private static readonly Guid IID_IDirect3DDxgiInterfaceAccess = new("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1");

    private static unsafe IntPtr TexturePointer(Windows.Graphics.DirectX.Direct3D11.IDirect3DSurface surface)
    {
        IntPtr unk = WinRT.MarshalInterface<Windows.Graphics.DirectX.Direct3D11.IDirect3DSurface>.FromManaged(surface);
        try
        {
            Guid accessIid = IID_IDirect3DDxgiInterfaceAccess;
            Marshal.ThrowExceptionForHR(Marshal.QueryInterface(unk, ref accessIid, out IntPtr access));
            try
            {
                var getInterface = (delegate* unmanaged[Stdcall]<IntPtr, Guid*, IntPtr*, int>)(*(IntPtr**)access)[3];
                Guid texIid = typeof(ID3D11Texture2D).GUID;
                IntPtr tex;
                Marshal.ThrowExceptionForHR(getInterface(access, &texIid, &tex));
                return tex; // owned by the ID3D11Texture2D wrapper
            }
            finally { Marshal.Release(access); }
        }
        finally { Marshal.Release(unk); }
    }
}

/// Moves a top-level window almost entirely off the virtual screen (so it's
/// out of the way but still composed, which WGC needs) and back.
internal sealed class WindowParker
{
    public IntPtr Handle { get; }
    public WinNative.RECT Original;
    public bool Parked { get; private set; }

    public WindowParker(IntPtr h, Rect? preDragFrame)
    {
        Handle = h;
        WinNative.GetWindowRect(h, out Original);
        if (preDragFrame is { } pre && WinNative.Frame(h) is { } vis)
        {
            // preDragFrame is the visible frame; keep the invisible border offset.
            int ox = Original.Left - vis.Left, oy = Original.Top - vis.Top;
            Original = new WinNative.RECT { Left = (int)pre.X + ox, Top = (int)pre.Y + oy, Right = (int)pre.X + ox + Original.Width, Bottom = (int)pre.Y + oy + Original.Height };
        }
    }

    public bool Park()
    {
        var v = WinNative.VirtualScreen();
        Parked = WinNative.SetWindowPos(Handle, IntPtr.Zero, (int)v.MaxX - 1, (int)v.MaxY - 1, 0, 0,
            WinNative.SWP_NOSIZE | WinNative.SWP_NOZORDER | WinNative.SWP_NOACTIVATE);
        return Parked;
    }

    public void Restore() => MoveTo(Original.Left, Original.Top);

    public void MoveTo(int x, int y)
    {
        WinNative.SetWindowPos(Handle, IntPtr.Zero, x, y, 0, 0, WinNative.SWP_NOSIZE | WinNative.SWP_NOZORDER | WinNative.SWP_NOACTIVATE);
        Parked = false;
    }

    public (int W, int H) Size => (Original.Width, Original.Height);
}

/// Replays v1 INPUT_* (normalized to the captured frame) into one window.
internal sealed class WindowInput
{
    private readonly IntPtr _root;
    private IntPtr _captureTarget;
    private bool _left, _right;
    private ulong _flags;
    private readonly InputInjector _keys = new(DisplayRect.Of(WinNative.VirtualScreen()));

    public WindowInput(IntPtr root) { _root = root; }

    private float _lastX = 0.5f, _lastY = 0.5f;

    private (IntPtr Target, WinNative.POINT Client, WinNative.POINT Screen)? Hit(float nx, float ny)
    {
        _lastX = nx; _lastY = ny;
        if (WinNative.Frame(_root) is not { } f) return null;
        var screen = new WinNative.POINT
        {
            X = f.Left + (int)(Math.Clamp(nx, 0, 1) * Math.Max(f.Width - 1, 0)),
            Y = f.Top + (int)(Math.Clamp(ny, 0, 1) * Math.Max(f.Height - 1, 0)),
        };
        IntPtr h = _captureTarget != IntPtr.Zero ? _captureTarget : Descend(screen);
        var c = screen;
        WinNative.ScreenToClient(h, ref c);
        return (h, c, screen);
    }

    private IntPtr Descend(WinNative.POINT screen)
    {
        IntPtr h = _root;
        for (int i = 0; i < 32; i++)
        {
            var c = screen;
            WinNative.ScreenToClient(h, ref c);
            IntPtr child = WinNative.ChildWindowFromPointEx(h, c, WinNative.CWP_SKIPINVISIBLE | WinNative.CWP_SKIPTRANSPARENT);
            if (child == IntPtr.Zero || child == h) break;
            h = child;
        }
        return h;
    }

    private static IntPtr MakeLParam(int x, int y) => (IntPtr)((y << 16) | (x & 0xFFFF));

    private IntPtr Mk()
    {
        int w = (_left ? 1 : 0) | (_right ? 2 : 0) | ((_flags & PeerKeys.FlagShift) != 0 ? 4 : 0) | ((_flags & PeerKeys.FlagCommand) != 0 ? 8 : 0);
        return (IntPtr)w;
    }

    public void Handle(MessageType type, byte[] p)
    {
        switch (type)
        {
            case MessageType.MouseMove when p.Length >= 8:
                if (Hit(Be.F32(p, 0), Be.F32(p, 4)) is { } mv)
                    WinNative.PostMessage(mv.Target, WinNative.WM_MOUSEMOVE, Mk(), MakeLParam(mv.Client.X, mv.Client.Y));
                break;
            case MessageType.MouseButton when p.Length >= 10:
            {
                byte button = p[0]; bool down = p[1] == 1;
                if (down)
                {
                    _captureTarget = IntPtr.Zero;
                    Focus();
                }
                if (Hit(Be.F32(p, 2), Be.F32(p, 6)) is not { } mb) return;
                if (button == 1) _right = down; else _left = down;
                int msg = button == 1 ? (down ? WinNative.WM_RBUTTONDOWN : WinNative.WM_RBUTTONUP)
                                      : (down ? WinNative.WM_LBUTTONDOWN : WinNative.WM_LBUTTONUP);
                WinNative.PostMessage(mb.Target, msg, Mk(), MakeLParam(mb.Client.X, mb.Client.Y));
                // Mimic mouse capture: the rest of a drag goes where it started.
                _captureTarget = (_left || _right) ? mb.Target : IntPtr.Zero;
                break;
            }
            case MessageType.Scroll when p.Length >= 8:
            {
                float dx = Be.F32(p, 0), dy = Be.F32(p, 4);
                if (!float.IsFinite(dx) || !float.IsFinite(dy)) return;
                // The wire's scroll has no position: aim at the last pointer spot.
                if (Hit(_lastX, _lastY) is not { } ms) return;
                int wy = (int)Math.Round(dy * 3), wx = (int)Math.Round(-dx * 3);
                IntPtr target = WinNative.FocusOf(_root) is var f && f != IntPtr.Zero ? f : ms.Target;
                if (wy != 0) WinNative.PostMessage(target, WinNative.WM_MOUSEWHEEL, (IntPtr)((wy << 16) | (int)Mk()), MakeLParam(ms.Screen.X, ms.Screen.Y));
                if (wx != 0) WinNative.PostMessage(target, WinNative.WM_MOUSEHWHEEL, (IntPtr)((wx << 16) | (int)Mk()), MakeLParam(ms.Screen.X, ms.Screen.Y));
                break;
            }
            case MessageType.Key when p.Length >= 11:
                Key(Be.U16(p, 0), p[2] == 1, Be.U64(p, 3));
                break;
        }
    }

    private void Focus()
    {
        if (GetForegroundWindow() == _root) return;
        if (!WinNative.SetForegroundWindow(_root))
        {
            // Foreground lock: the process that sent the last input may take
            // the foreground; a tagged Alt tap makes that us.
            _keys.VirtualKey(0x12, true); _keys.VirtualKey(0x12, false);
            WinNative.SetForegroundWindow(_root);
        }
    }

    private void Key(ushort mac, bool down, ulong flags)
    {
        _flags = flags;
        if (GetForegroundWindow() == _root)
        {
            // Real keyboard input: shortcuts and key-state checks work.
            _keys.Key(mac, down, flags);
            return;
        }
        // Fallback: posted messages to the focused control (no Ctrl shortcuts).
        if (MacKeyMap.ToWindows(mac) is not { } vk) return;
        IntPtr target = WinNative.FocusOf(_root);
        if (target == IntPtr.Zero) target = _root;
        uint scan = WinNative.MapVirtualKey(vk, 0);
        IntPtr l = (IntPtr)(1 | (scan << 16) | (down ? 0 : (3u << 30)));
        WinNative.PostMessage(target, down ? WinNative.WM_KEYDOWN : WinNative.WM_KEYUP, (IntPtr)vk, l);
        if (!down || PeerKeys.IsModifier(mac)) return;
        var state = new byte[256];
        if ((flags & PeerKeys.FlagShift) != 0) state[0x10] = 0x80;
        if ((flags & PeerKeys.FlagAlphaShift) != 0) state[0x14] = 0x01;
        if ((flags & (PeerKeys.FlagCommand | PeerKeys.FlagControl)) != 0) return; // shortcuts: not typeable text
        var sb = new System.Text.StringBuilder(8);
        int n = WinNative.ToUnicodeEx(vk, scan, state, sb, sb.Capacity, 4 /* don't change keyboard state */, WinNative.GetKeyboardLayout(0));
        for (int i = 0; i < n; i++) WinNative.PostMessage(target, WinNative.WM_CHAR, (IntPtr)sb[i], l);
    }

    public void ReleaseAll() { _keys.ReleaseAll(); _captureTarget = IntPtr.Zero; _left = _right = false; }

    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
}

internal sealed class WindowStreamServer : IDisposable
{
    public ushort Port { get; }
    public IntPtr Window { get; }
    private readonly string? _allowedHost;
    private readonly TcpListener _listener;
    private readonly CancellationTokenSource _life = new();
    private readonly WindowCapture _capture;
    private readonly WindowInput _input;
    private readonly object _gate = new();
    private Client? _client;
    private VideoEncoder? _encoder;
    private byte[]? _lastNv12;
    private long _lastFeedTicks;
    private readonly long _start = Environment.TickCount64;
    private System.Threading.Timer? _idle;
    public long FramesSent;

    /// Throws when the port can't be bound or the window can't be captured.
    /// Call on the UI thread (WGC needs its DispatcherQueue).
    public WindowStreamServer(IntPtr hwnd, ushort port, string? allowedHost)
    {
        Window = hwnd; Port = port; _allowedHost = Normalize(allowedHost);
        _capture = new WindowCapture(hwnd);
        _input = new WindowInput(hwnd);
        _listener = new TcpListener(IPAddress.IPv6Any, port);
        _listener.Server.DualMode = true;
        try { _listener.Start(); }
        catch { _capture.Dispose(); throw; }
        _capture.OnNv12 = Feed;
        _ = AcceptLoop();
        // A static window produces no new frames: re-feed the last one now
        // and then so a (re)joining receiver still gets a picture.
        _idle = new System.Threading.Timer(_ =>
        {
            if (Environment.TickCount64 - Interlocked.Read(ref _lastFeedTicks) > 700 && _lastNv12 is { } last) Feed(last);
        }, null, 1000, 1000);
    }

    public (int W, int H) Size => (_capture.Width, _capture.Height);
    public long CaptureFrames => Interlocked.Read(ref _capture.Frames);

    private static string? Normalize(string? host)
    {
        if (host is null || !IPAddress.TryParse(host.Split('%')[0], out var a)) return host;
        if (a.IsIPv4MappedToIPv6) a = a.MapToIPv4();
        if (a.AddressFamily == AddressFamily.InterNetworkV6) a.ScopeId = 0;
        return a.ToString();
    }

    private async Task AcceptLoop()
    {
        while (!_life.IsCancellationRequested)
        {
            TcpClient tcp;
            try { tcp = await _listener.AcceptTcpClientAsync(_life.Token); }
            catch { return; }
            string? remote = tcp.Client.RemoteEndPoint is IPEndPoint ep ? Normalize(ep.Address.ToString()) : null;
            if (_allowedHost is not null && remote != _allowedHost)
            {
                Log.Line($"HANDOFF: refusing window-stream connection from {remote} on {Port} (only the peer may connect)");
                tcp.Dispose();
                continue;
            }
            _ = Task.Run(async () =>
            {
                try
                {
                    tcp.NoDelay = true;
                    var s = tcp.GetStream();
                    await WsUpgrade.ServerAsync(s, TimeSpan.FromSeconds(10));
                    var ws = WebSocket.CreateFromStream(s, new WebSocketCreationOptions { IsServer = true, KeepAliveInterval = TimeSpan.FromSeconds(20) });
                    var c = new Client(this, tcp, ws);
                    lock (_gate)
                    {
                        _client?.Close();
                        _client = c;
                    }
                    c.Start();
                }
                catch (Exception e) { Log.Line($"HANDOFF: window-stream upgrade failed: {e.Message}"); tcp.Dispose(); }
            });
        }
    }

    private void Feed(byte[] nv12)
    {
        _lastNv12 = nv12;
        Interlocked.Exchange(ref _lastFeedTicks, Environment.TickCount64);
        VideoEncoder? enc;
        lock (_gate) enc = _encoder;
        if (enc is null) return;
        try { lock (enc) enc.Feed(nv12, (ulong)(Environment.TickCount64 - _start) * 1000UL); }
        catch (Exception e) { Log.Line($"HANDOFF: encode failed: {e.Message}"); }
    }

    private void OnMessage(Client c, MessageType t, byte[] p)
    {
        switch (t)
        {
            case MessageType.Hello when p.Length >= 2:
                StartEncoder(c, (StreamCodec)p[1]);
                break;
            case MessageType.KeyframeRequest:
                _encoder?.RequestKeyframe();
                if (_lastNv12 is { } last) Feed(last);
                break;
            case MessageType.MouseMove or MessageType.MouseButton or MessageType.Key or MessageType.Scroll:
                // Posted/injected input belongs on the UI thread with the rest of our Win32 calls.
                _ui?.Post(_ => _input.Handle(t, p), null);
                if (_ui is null) _input.Handle(t, p);
                break;
        }
    }

    private readonly SynchronizationContext? _ui = SynchronizationContext.Current;

    private void StartEncoder(Client c, StreamCodec requested)
    {
        VideoEncoder enc;
        try { enc = VideoEncoder.Create(_capture.Width, _capture.Height, requested); }
        catch (Exception e)
        {
            Log.Line($"HANDOFF: encoder init failed ({e.Message}) — window stream has no video");
            c.Send(Proto.HelloAck(StreamCodec.H264, (uint)_capture.Width, (uint)_capture.Height, 0));
            return;
        }
        int inFlight = 0;
        enc.OnFrame = (key, pts, avcc) =>
        {
            if (Volatile.Read(ref inFlight) >= 8 && !key) { enc.RequestKeyframe(); return; }
            Interlocked.Increment(ref inFlight);
            Interlocked.Increment(ref FramesSent);
            c.Send(Proto.VideoFrame(key, pts, avcc), () => Interlocked.Decrement(ref inFlight));
        };
        byte flags = enc.Status switch { EncoderStatus.HardwareActive => 0b11, EncoderStatus.SoftwareExpected => 0b01, _ => 0 };
        c.Send(Proto.HelloAck(enc.Codec, (uint)_capture.Width, (uint)_capture.Height, flags));
        VideoEncoder? old;
        lock (_gate) { old = _encoder; _encoder = enc; }
        old?.Dispose();
        Log.Line($"HANDOFF: window stream on {Port}: {enc.Codec} {_capture.Width}x{_capture.Height}");
        if (_lastNv12 is { } last) Feed(last);
    }

    private void Dropped(Client c)
    {
        VideoEncoder? enc = null;
        lock (_gate)
        {
            if (_client != c) return;
            _client = null;
            enc = _encoder; _encoder = null;
        }
        enc?.Dispose();
        _ui?.Post(_ => _input.ReleaseAll(), null);
    }

    public void Dispose()
    {
        _life.Cancel();
        _idle?.Dispose(); _idle = null;
        try { _listener.Stop(); } catch { }
        Client? c; VideoEncoder? enc;
        lock (_gate) { c = _client; _client = null; enc = _encoder; _encoder = null; }
        c?.Close();
        _capture.Dispose();
        enc?.Dispose();
        _input.ReleaseAll();
    }

    private sealed class Client
    {
        private readonly WindowStreamServer _owner;
        private readonly TcpClient _tcp;
        private readonly WebSocket _ws;
        private readonly CancellationTokenSource _cts = new();
        private readonly Channel<(byte[], Action?)> _out = Channel.CreateUnbounded<(byte[], Action?)>();
        private readonly FrameParser _parser = new();
        private int _closed;

        public Client(WindowStreamServer owner, TcpClient tcp, WebSocket ws)
        {
            _owner = owner; _tcp = tcp; _ws = ws;
            _parser.OnMessage = (t, p) => _owner.OnMessage(this, t, p);
        }

        public void Start() { _ = Task.Run(Receive); _ = Task.Run(SendLoop); }

        public void Send(byte[] d, Action? done = null) { if (!_out.Writer.TryWrite((d, done))) done?.Invoke(); }

        private async Task SendLoop()
        {
            try
            {
                await foreach (var (d, done) in _out.Reader.ReadAllAsync(_cts.Token))
                {
                    try { await _ws.SendAsync(d, WebSocketMessageType.Binary, true, _cts.Token); }
                    catch { done?.Invoke(); Close(); return; }
                    done?.Invoke();
                }
            }
            catch (OperationCanceledException) { }
            while (_out.Reader.TryRead(out var left)) left.Item2?.Invoke();
        }

        private async Task Receive()
        {
            var buf = new byte[64 * 1024];
            try
            {
                while (!_cts.IsCancellationRequested)
                {
                    var r = await _ws.ReceiveAsync(buf, _cts.Token);
                    if (r.MessageType == WebSocketMessageType.Close) break;
                    _parser.Feed(buf.AsSpan(0, r.Count));
                    if (_parser.Corrupt) break;
                }
            }
            catch { }
            Close();
        }

        public void Close()
        {
            if (Interlocked.Exchange(ref _closed, 1) == 1) return;
            _owner.Dropped(this);
            _out.Writer.TryComplete();
            _cts.Cancel();
            try { _ws.Abort(); } catch { }
            try { _ws.Dispose(); } catch { }
            try { _tcp.Dispose(); } catch { }
        }
    }
}
