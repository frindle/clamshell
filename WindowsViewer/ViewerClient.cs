using System.IO;
using System.Net.WebSockets;
using System.Threading.Channels;
using Clamshell.Auth;

namespace Clamshell;

// Client side of the stream: connects to a Clamshell host's window-stream (or
// display-stream -- same wire protocol either way, see PROTOCOL.md) WebSocket
// endpoint, proves who this PC is and checks who the Mac is (the device-auth
// handshake in WindowsShared/), decodes VIDEO_FRAME via VideoDecoder, and
// forwards INPUT_* back.
//
// Every decision about the connection is ClientAuthFlow's (rules 1 to 16 in
// PROTOCOL.md): this class opens the socket, feeds the flow what happens, and
// does what the flow says. Nothing is sent when the socket opens. After
// "accepted" every message goes out sealed, HELLO first and then CLIENT_INFO.
// Sealing and queueing for the socket happen together under one lock, so the
// counter order is the wire order; one task writes the queue to the socket.
internal sealed class ViewerClient : IDisposable
{
    public Action<StreamCodec, int, int>? OnHelloAck; // codec, widthPx, heightPx (encoded dims from HELLO_ACK)
    public Action<int, int, byte[]>? OnFrame;          // decoded width, height, BGRA32
    public Action<string>? OnDisconnected;
    /// <summary>What the screen should show. Called from a worker thread.</summary>
    public Action<FlowState>? OnState;

    /// <summary>Capability bits the host offers, 0 until accepted is verified.</summary>
    public uint HostCapabilities { get; private set; }

    /// <summary>Answers rule 6 (connect without proof of who answers) with yes,
    /// once, without asking anyone and without saving the answer. Only the
    /// headless --verify mode sets it. It never answers any other question.</summary>
    public bool AllowUnverified { get; set; }

    private readonly IDeviceKey _key;
    private readonly KnownHostsFile _file;
    private readonly CancellationTokenSource _cts = new();
    private readonly object _gate = new();
    private Attempt? _attempt;
    private string _host = "";
    private int _port;
    private StreamCodec _codec;
    private bool _disposed;

    public ViewerClient(IDeviceKey key, KnownHostsFile file)
    {
        _key = key;
        _file = file;
    }

    /// <summary>Opens this PC's key and the saved Macs file in their usual places.
    /// Throws <see cref="DeviceKeyException"/> if the key store refuses.</summary>
    public static ViewerClient OpenDefault()
    {
        var key = CngDeviceKey.OpenOrCreate();
        return new ViewerClient(key, new KnownHostsFile(ViewerPaths.DataFolder));
    }

    public async Task ConnectAsync(string host, int port, StreamCodec requestedCodec)
    {
        _host = host;
        _port = port;
        _codec = requestedCodec;
        await StartAttempt(new FlowCarry());
    }

    public Task SendMouseMove(float x, float y) => SendApp(Proto.MouseMove(x, y));
    public Task SendMouseButton(byte button, bool down, float x, float y) => SendApp(Proto.MouseButton(button, down, x, y));
    public Task SendKey(ushort macKeyCode, bool down, ulong flags) => SendApp(Proto.Key(macKeyCode, down, flags));
    public Task SendScroll(float dx, float dy) => SendApp(Proto.Scroll(dx, dy));
    public Task RequestKeyframe() => SendApp(Proto.KeyframeRequest());

    /// <summary>The user's answer to the question the screen asks.</summary>
    public void Answer(bool yes)
    {
        var attempt = _attempt;
        attempt?.Handle(f => f.Answered(yes));
    }

    /// <summary>Ends the connection and does not connect again. The window stays.</summary>
    public void Stop()
    {
        _disposed = true;
        try { _cts.Cancel(); } catch (ObjectDisposedException) { }
        lock (_gate)
        {
            _attempt?.Dispose();
            _attempt = null;
        }
        HostCapabilities = 0;
        OnDisconnected?.Invoke("stopped");
    }

    private Task SendApp(byte[] message)
    {
        // Before accepted (and after the end) the flow returns nothing: the input is dropped.
        _attempt?.Handle(f => f.Send(message));
        return Task.CompletedTask;
    }

    private async Task StartAttempt(FlowCarry carry)
    {
        if (_disposed) return;
        KnownHosts known;
        try
        {
            known = _file.Load();
        }
        catch (KnownHostsFileException e)
        {
            // Nothing has been dialled, and the file is left as it is.
            Log.Line($"saved Macs file: {e.Message}");
            OnState?.Invoke(FlowState.Failed(e.Message));
            OnDisconnected?.Invoke(e.Message);
            return;
        }

        var url = $"ws://{_host}:{_port}/";
        var config = new ClientAuthConfig
        {
            DeviceKey = _key.PublicKey,
            Sign = _key.Sign,
            DeviceName = Environment.MachineName,
            FallbackDeviceName = "PC",
            Capabilities = ClientAuthFlow.DefaultCapabilities,
            AppName = "windows",
            AppVersion = typeof(ViewerClient).Assembly.GetName().Version?.ToString(3) ?? "0",
            DialledUrl = url,
            MakeHello = () => Proto.Hello(_codec),
        };
        var attempt = new Attempt(this, new ClientAuthFlow(config, known, carry));
        lock (_gate)
        {
            _attempt?.Dispose();
            _attempt = attempt;
        }
        await attempt.ConnectAsync(new Uri(url), _cts.Token);
    }

    private async Task ReconnectAfter(double seconds, FlowCarry carry)
    {
        try
        {
            if (seconds > 0) await Task.Delay(TimeSpan.FromSeconds(seconds), _cts.Token);
            await StartAttempt(carry);
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            Log.Line($"reconnect failed: {e.Message}");
            OnDisconnected?.Invoke(e.Message);
        }
    }

    /// <summary>One connection: a socket, a flow, an ordered send queue, the flow's timers.</summary>
    private sealed class Attempt : IDisposable
    {
        private readonly ViewerClient _owner;
        private readonly ClientAuthFlow _flow;
        private readonly ClientWebSocket _ws = new();
        private readonly Channel<byte[]> _outbox = Channel.CreateUnbounded<byte[]>(
            new UnboundedChannelOptions { SingleReader = true });
        private readonly CancellationTokenSource _cts = new();
        private readonly Dictionary<FlowTimer, CancellationTokenSource> _timers = new();
        private readonly object _lock = new();
        private VideoDecoder? _decoder;
        private bool _closedByFlow;
        private bool _answeredByFlag;

        public Attempt(ViewerClient owner, ClientAuthFlow flow)
        {
            _owner = owner;
            _flow = flow;
        }

        public async Task ConnectAsync(Uri uri, CancellationToken outer)
        {
            using var link = CancellationTokenSource.CreateLinkedTokenSource(outer, _cts.Token);
            await _ws.ConnectAsync(uri, link.Token);
            _ = SendLoopAsync();
            _ = ReceiveLoopAsync();
            Handle(f => f.Opened());
        }

        /// <summary>Feeds the flow one event and does what it says, in order.
        /// Messages for the app are handed over after the lock is released.</summary>
        public void Handle(Func<ClientAuthFlow, List<FlowAction>> step)
        {
            List<(byte Type, byte[] Payload)> delivered;
            bool answerYes;
            lock (_lock)
            {
                var actions = step(_flow);
                (delivered, answerYes) = Run(actions);
                if (answerYes)
                {
                    // Rule 6, answered by the verify flag; the allowance is not saved.
                    _answeredByFlag = true;
                    var more = _flow.Answered(true);
                    var (d2, _) = Run(more);
                    delivered.AddRange(d2);
                }
            }
            foreach (var (type, payload) in delivered) Deliver(type, payload);
        }

        private (List<(byte, byte[])> Delivered, bool AnswerYes) Run(List<FlowAction> actions)
        {
            var delivered = new List<(byte, byte[])>();
            bool answerYes = false;
            foreach (var a in actions)
            {
                switch (a.Kind)
                {
                    case FlowActionKind.Send:
                        _outbox.Writer.TryWrite(a.Bytes);
                        break;
                    case FlowActionKind.StartTimer:
                        StartTimer(a.Timer, a.Seconds);
                        break;
                    case FlowActionKind.CancelTimer:
                        CancelTimer(a.Timer);
                        break;
                    case FlowActionKind.State:
                        Log.Line($"state: {a.State}");
                        _owner.OnState?.Invoke(a.State!);
                        if (a.State!.Kind == FlowStateKind.AskUnverified && _owner.AllowUnverified && !_answeredByFlag)
                        {
                            answerYes = true;
                        }
                        break;
                    case FlowActionKind.Deliver:
                        delivered.Add((a.MessageType, a.Payload));
                        break;
                    case FlowActionKind.Change:
                        if (_answeredByFlag && a.Change!.Kind == ChangeKind.AllowUnverified) break;
                        if (!Persist(a.Change!)) return (delivered, false);
                        break;
                    case FlowActionKind.HostCapabilities:
                        _owner.HostCapabilities = a.Capabilities;
                        break;
                    case FlowActionKind.Close:
                        Log.Line($"closing the socket: {a.Reason}");
                        _closedByFlow = true;
                        AbortSocket();
                        break;
                    case FlowActionKind.End:
                        Ended(a.End!, a.Reason);
                        break;
                }
            }
            return (delivered, answerYes);
        }

        /// <summary>Saves one change to the saved Macs file. A file that cannot be
        /// used ends the connection with the file's message.</summary>
        private bool Persist(KnownHostsChange change)
        {
            try
            {
                _owner._file.Apply(change, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0);
                return true;
            }
            catch (KnownHostsFileException e)
            {
                Log.Line($"saved Macs file: {e.Message}");
                _closedByFlow = true;
                CancelAllTimers();
                AbortSocket();
                _owner.OnState?.Invoke(FlowState.Failed(e.Message));
                _owner.OnDisconnected?.Invoke(e.Message);
                return false;
            }
        }

        private void Ended(FlowEnd end, string reason)
        {
            Log.Line($"connection ended: {end} ({reason})");
            _closedByFlow = true;
            CancelAllTimers();
            AbortSocket();
            _owner.HostCapabilities = 0;
            if (end.Kind == FlowEndKind.Reconnect)
            {
                _ = _owner.ReconnectAfter(end.After, end.Carry);
                return;
            }
            _owner.OnDisconnected?.Invoke(reason);
        }

        // MARK: Timers

        private void StartTimer(FlowTimer timer, double seconds)
        {
            CancelTimer(timer);
            var source = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token);
            _timers[timer] = source;
            _ = Task.Run(async () =>
            {
                try { await Task.Delay(TimeSpan.FromSeconds(seconds), source.Token); }
                catch (OperationCanceledException) { return; }
                lock (_lock)
                {
                    // A timer that was cancelled while it was firing does nothing.
                    if (source.IsCancellationRequested) return;
                    if (_timers.TryGetValue(timer, out var current) && current == source) _timers.Remove(timer);
                }
                Handle(f => f.TimerFired(timer));
            });
        }

        private void CancelTimer(FlowTimer timer)
        {
            if (_timers.Remove(timer, out var source))
            {
                try { source.Cancel(); } catch (ObjectDisposedException) { }
            }
        }

        private void CancelAllTimers()
        {
            foreach (var timer in _timers.Keys.ToList()) CancelTimer(timer);
        }

        // MARK: Socket

        private void AbortSocket()
        {
            _outbox.Writer.TryComplete();
            try { _ws.Abort(); } catch { }
        }

        private async Task SendLoopAsync()
        {
            try
            {
                await foreach (var data in _outbox.Reader.ReadAllAsync(_cts.Token))
                {
                    if (_ws.State != WebSocketState.Open) return;
                    // Explicit ArraySegment<byte> (not a bare byte[]): ClientWebSocket
                    // exposes both an ArraySegment<byte> overload (inherited from the
                    // abstract WebSocket base) and a Memory<byte> overload of its own --
                    // an unqualified byte[] argument is ambiguous between the two.
                    await _ws.SendAsync(new ArraySegment<byte>(data), WebSocketMessageType.Binary, true, CancellationToken.None);
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception e) { Log.Line($"send failed: {e.Message}"); }
        }

        private async Task ReceiveLoopAsync()
        {
            var buf = new byte[256 * 1024];
            using var msg = new MemoryStream();
            string reason = "receive loop ended";
            try
            {
                while (_ws.State == WebSocketState.Open)
                {
                    msg.SetLength(0);
                    WebSocketReceiveResult r;
                    do
                    {
                        // Same ambiguity note as the send loop -- explicit ArraySegment<byte>.
                        r = await _ws.ReceiveAsync(new ArraySegment<byte>(buf), _cts.Token);
                        if (r.MessageType == WebSocketMessageType.Close)
                        {
                            Closed("host closed connection");
                            return;
                        }
                        msg.Write(buf, 0, r.Count);
                        if (msg.Length > 32 << 20) { Closed("oversize message"); return; }
                    } while (!r.EndOfMessage);

                    // No Span here: this is an async method.
                    var frame = msg.ToArray();
                    if (frame.Length < 5) { Closed("message too short"); return; }
                    byte type = frame[0];
                    long len = ((long)frame[1] << 24) | ((long)frame[2] << 16) | ((long)frame[3] << 8) | frame[4];
                    if (frame.Length != 5 + len) { Closed("message length does not match"); return; }
                    var payload = new byte[len];
                    Array.Copy(frame, 5, payload, 0, (int)len);
                    Handle(f => f.Received(type, payload));
                }
            }
            catch (OperationCanceledException) { return; }
            catch (Exception e) { reason = e.Message; }
            Closed(reason);
        }

        /// <summary>The socket ended from the other side or the network. Not
        /// reported when the flow closed it itself.</summary>
        private void Closed(string reason)
        {
            if (_closedByFlow) return;
            Log.Line($"socket closed: {reason}");
            Handle(f => f.SocketClosed());
        }

        // MARK: Messages for the app

        private void Deliver(byte type, byte[] payload)
        {
            ReadOnlySpan<byte> p = payload;
            switch ((MessageType)type)
            {
                case MessageType.HelloAck:
                    if (p.Length >= 11)
                    {
                        var codec = (StreamCodec)p[1];
                        int w = (int)Be.U32(p, 2), h = (int)Be.U32(p, 6);
                        _decoder?.Dispose();
                        _decoder = new VideoDecoder(codec);
                        _decoder.OnFrame = (dw, dh, bgra) => _owner.OnFrame?.Invoke(dw, dh, bgra);
                        _owner.OnHelloAck?.Invoke(codec, w, h);
                    }
                    break;
                case MessageType.VideoFrame:
                    if (p.Length >= 9)
                    {
                        ulong pts = Be.U64(p, 1);
                        _decoder?.Feed(p.Slice(9), pts);
                    }
                    break;
                // StreamStatus, HostLockState, CursorPos, AudioFrame, Clipboard: not
                // needed for v1 of this viewer -- see report/README for what's skipped.
                default:
                    break;
            }
        }

        public void Dispose()
        {
            lock (_lock) CancelAllTimers();
            _outbox.Writer.TryComplete();
            try { _cts.Cancel(); } catch (ObjectDisposedException) { }
            try { _ws.Abort(); } catch { }
            _ws.Dispose();
            _decoder?.Dispose();
        }
    }

    public void Dispose()
    {
        _disposed = true;
        try { _cts.Cancel(); } catch (ObjectDisposedException) { }
        lock (_gate)
        {
            _attempt?.Dispose();
            _attempt = null;
        }
        (_key as IDisposable)?.Dispose();
    }
}
