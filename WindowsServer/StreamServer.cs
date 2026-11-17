using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using Clamshell.Auth;

namespace Clamshell;

// Host side of the stream for ONE display — the C# mirror of the Mac's
// StreamServer and StreamLink. A raw HttpListener WebSocket endpoint (no ASP.NET
// Core: this is a single-purpose headless tool). Receives input on the same
// socket and injects it. The primary display (index 0) also carries audio and
// clipboard.
//
// Who may connect (mirrors Sources/Clamshell/Auth, docs PROTOCOL.md):
//  - Every connection is sent a signed challenge the moment it is accepted.
//  - Until it answers, the only thing read is an AUTH_RESPONSE of at most 4 KB.
//    Nothing starts: no video, no input, no clipboard.
//  - A device that proves its key is looked up in the device list (DeviceTrustStore).
//    Trusted: accepted. Denied: told so and closed. Unknown: it waits, and is told so
//    every 20 s, until someone approves or denies it on this PC, or 10 minutes pass.
//  - Once accepted, every message in both directions is a SECURE frame; one that does
//    not decrypt, or that is anything else, closes the connection.
//  - Only an accepted connection replaces the one in use. A new client that has not
//    been accepted never disturbs a session.
//  - With device approval switched off on this PC a client that skips the handshake and
//    sends HELLO is let in as before, unencrypted. It is the only way in without a key.
//
// Bind note: the prefix is http://+:PORT/ so LAN/Tailscale clients reach it.
// That needs either an elevated process or a one-time `netsh http add urlacl`.
// A dedicated server VM runs elevated, so this is left as-is (the Mac's
// NWListener binds all interfaces with no such ceremony).
internal sealed partial class StreamServer : IDisposable
{
    private readonly DisplayInfo _display;
    private readonly ushort _basePort;
    private readonly ushort _port;
    private readonly HostAuth _auth;
    private readonly bool _media;
    private bool IsPrimary => _display.IsPrimary;

    private readonly HttpListener _listener = new();
    private readonly CancellationTokenSource _life = new();

    // The session: the one accepted (or clear) link that owns input, video and clipboard.
    // Guarded by _gate. Accepting a new one ends the old one.
    private readonly object _gate = new();
    private Link? _session;
    private WebSocket? _ws; // _session's socket; Video tests it for null

    // Every link that is open on this listener, whatever its phase. Guarded by _linksLock.
    private readonly object _linksLock = new();
    private readonly List<Link> _links = new();

    private InputInjector? _injector;
    private ClipboardBridge? _clipboard;

    /// <summary>How many times a session was started (HELLO handled). Self-tests read it to show
    /// that nothing starts before a device is accepted.</summary>
    public int SessionsStarted => Volatile.Read(ref _sessionsStarted);
    private int _sessionsStarted;

    public ushort Port => _port;

    /// <param name="media">False for self-tests: a session sends HELLO_ACK and nothing else (no
    /// input injection, capture, encoder or audio).</param>
    public StreamServer(DisplayInfo display, ushort basePort, HostAuth auth, bool media = true)
    {
        _display = display;
        _basePort = basePort;
        _port = display.Port(basePort);
        _auth = auth;
        _media = media;
        _auth.Store.DidChange += Reconcile;
        _auth.ApprovalDidChange += Reconcile;
    }

    public void Start()
    {
        _listener.Prefixes.Add($"http://+:{_port}/");
        try { _listener.Start(); }
        catch (HttpListenerException e)
        {
            Log.Line($"port {_port}: cannot bind ({e.Message}). Run elevated or add a urlacl: " +
                     $"netsh http add urlacl url=http://+:{_port}/ user=Everyone");
            return;
        }
        Log.Line($"listening on ws port {_port} for display {_display.Index}{(IsPrimary ? " (primary)" : "")}");
        _ = AcceptLoopAsync();
    }

    /// <summary>For self-tests: false when the port could not be bound.</summary>
    public bool IsListening => _listener.IsListening;

    // MARK: one connection

    private enum Phase { AwaitingResponse, Pending, Accepted, Open, Closed }

    /// <summary>One WebSocket connection and where it is in the handshake. Fields that change
    /// are guarded by the link's own lock.</summary>
    private sealed class Link
    {
        public readonly WebSocket Ws;
        public readonly string Address;
        public readonly string Group;
        public readonly CancellationTokenSource Cts;
        public readonly SemaphoreSlim SendLock = new(1, 1);
        public Phase Phase = Phase.AwaitingResponse;
        public HostHandshake? Handshake;
        public byte[] Response = Array.Empty<byte>();
        public VerifiedDevice? Device;
        public SecureSealer? Sealer;
        public SecureOpener? Opener;
        public HostAuth.Unanswered? UnansweredToken;
        public HostAuth.Waiting? WaitingToken;
        public byte[]? PendingFrame;
        public bool Counted; // SessionOpened was called
        public bool LoggedClientInfo;
        public bool Finishing; // a last word is being sent
        public long PendingBytes;

        public Link(WebSocket ws, string address, string group, CancellationToken life)
        {
            Ws = ws;
            Address = address;
            Group = group;
            Cts = CancellationTokenSource.CreateLinkedTokenSource(life);
        }

        public string Label => Device != null ? $"{Device.Name} ({Device.Fingerprint})" : Address;
    }

    private async Task AcceptLoopAsync()
    {
        while (!_life.IsCancellationRequested)
        {
            HttpListenerContext ctx;
            try { ctx = await _listener.GetContextAsync(); }
            catch (Exception) when (_life.IsCancellationRequested) { return; }
            catch (Exception e) { Log.Line($"port {_port}: accept error {e.Message}"); return; }

            if (!ctx.Request.IsWebSocketRequest)
            {
                ctx.Response.StatusCode = 426; // Upgrade Required
                ctx.Response.Close();
                continue;
            }
            // Where it came from, for the address groups and the log. Only a trusted proxy's
            // headers are believed, and the result is never a reason to trust anyone.
            string address = AddressOf(ctx);
            try
            {
                var wsCtx = await ctx.AcceptWebSocketAsync(subProtocol: null);
                _ = RunLinkAsync(wsCtx.WebSocket, address);
            }
            catch (Exception e) { Log.Line($"port {_port}: ws upgrade failed {e.Message}"); }
        }
    }

    private string AddressOf(HttpListenerContext ctx)
    {
        var ep = ctx.Request.RemoteEndPoint;
        var peer = ep?.Address;
        if (peer == null) return AddressGroup.Unknown;
        if (peer.IsIPv4MappedToIPv6) peer = peer.MapToIPv4();
        var headers = new List<(string, string)>();
        var h = ctx.Request.Headers;
        foreach (var name in h.AllKeys)
        {
            if (name == null) continue;
            var values = h.GetValues(name);
            if (values == null) continue;
            foreach (var v in values) headers.Add((name, v));
        }
        return ClientAddress.Resolve(peer.ToString(), headers, _auth.TrustedProxies);
    }

    private uint HostCapabilities() =>
        Caps.RelativeMouse | Caps.TextInput | Caps.ExtraButtons | (_auth.RequireApproval ? Caps.ApprovalRequired : 0u);

    private async Task RunLinkAsync(WebSocket ws, string address)
    {
        var link = new Link(ws, address, AddressGroup.Of(address), _life.Token);
        lock (_linksLock) _links.Add(link);
        try
        {
            link.UnansweredToken = _auth.AddUnanswered(link.Group, () => CloseLink(link));
            if (link.Cts.IsCancellationRequested) return; // turned away
            link.Handshake = new HostHandshake(_auth.Identity.PublicKey, HostCapabilities(), _auth.HostName);
            if (!await SendRawAsync(link, Wire.Frame(WireType.AuthChallenge, link.Handshake.Challenge.Payload))) return;
            _ = ResponseDeadlineAsync(link);
            await ReceiveLoopAsync(link);
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            Log.Line($"port {_port}: connection from {address} failed ({e.GetType().Name}: {e.Message})");
        }
        finally
        {
            CloseLink(link);
            lock (_linksLock) _links.Remove(link);
        }
    }

    private async Task ResponseDeadlineAsync(Link link)
    {
        try { await Task.Delay(_auth.ResponseDeadline, link.Cts.Token); }
        catch (OperationCanceledException) { return; }
        bool late;
        lock (link) late = link.Phase == Phase.AwaitingResponse;
        if (late)
        {
            Log.Line($"port {_port}: {link.Address} did not answer the challenge in time");
            CloseLink(link);
        }
    }

    // MARK: reading

    private const int MaxHandshakeBytes = AuthWire.MaxResponseBytes + 5;
    private const int MaxSessionBytes = 4 << 20;
    private const long MaxPendingBytes = 64 << 10;
    private const int MaxClientInfoBytes = 2048;

    private async Task ReceiveLoopAsync(Link link)
    {
        var ws = link.Ws;
        var ct = link.Cts.Token;
        var buf = new byte[64 * 1024];
        using var msg = new MemoryStream();
        try
        {
            while (!ct.IsCancellationRequested && ws.State == WebSocketState.Open)
            {
                msg.SetLength(0);
                WebSocketReceiveResult r;
                do
                {
                    r = await ws.ReceiveAsync(buf, ct);
                    if (r.MessageType == WebSocketMessageType.Close)
                    {
                        Log.Line($"port {_port}: client closed");
                        return;
                    }
                    if (r.MessageType != WebSocketMessageType.Binary)
                    {
                        Log.Line($"port {_port}: {link.Address} sent a text message — closing");
                        return;
                    }
                    msg.Write(buf, 0, r.Count);
                    Phase phase;
                    lock (link) phase = link.Phase;
                    long limit = phase switch
                    {
                        Phase.AwaitingResponse => MaxHandshakeBytes,
                        Phase.Pending => MaxPendingBytes,
                        _ => MaxSessionBytes,
                    };
                    if (phase == Phase.Pending)
                    {
                        // A waiting connection is read for nothing but its size.
                        link.PendingBytes += r.Count;
                        if (link.PendingBytes > limit)
                        {
                            Log.Line($"port {_port}: {link.Label} sent too much while waiting — closing");
                            return;
                        }
                    }
                    else if (msg.Length > limit)
                    {
                        Log.Line($"port {_port}: {link.Label} sent an oversize message — closing");
                        return;
                    }
                } while (!r.EndOfMessage);

                if (!await HandleMessageAsync(link, msg.ToArray())) return;
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception e) when (e is WebSocketException or IOException or ObjectDisposedException)
        {
            Log.Line($"port {_port}: receive error {e.Message}");
        }
    }

    /// <summary>False closes the connection.</summary>
    private async Task<bool> HandleMessageAsync(Link link, byte[] frame)
    {
        Phase phase;
        lock (link) phase = link.Phase;
        switch (phase)
        {
            case Phase.AwaitingResponse:
                return await HandleFirstMessageAsync(link, frame);
            case Phase.Pending:
                return true; // counted by the reader, otherwise ignored
            case Phase.Accepted:
                return HandleSecure(link, frame);
            case Phase.Open:
                if (_session == link) Dispatch(frame);
                return true;
            default:
                return false;
        }
    }

    private static bool WellFramed(byte[] frame) =>
        frame.Length >= 5 && (long)Wire.ReadU32(frame, 1) == frame.Length - 5;

    private async Task<bool> HandleFirstMessageAsync(Link link, byte[] frame)
    {
        if (!WellFramed(frame)) return false;
        if (frame[0] == (byte)MessageType.Hello && !_auth.RequireApproval)
        {
            // Approval is off: the old, unauthenticated way in.
            return OpenClear(link, frame);
        }
        if (frame[0] != WireType.AuthResponse) return false;
        var payload = Wire.Slice(frame, 5, frame.Length - 5);
        link.Response = payload;
        VerifiedDevice device;
        try { device = link.Handshake!.Verify(payload); }
        catch (AuthException e)
        {
            Log.Line($"port {_port}: {link.Address} sent a response that failed ({e.Error})");
            await FinishAsync(link, AuthStatus.Invalid);
            return false;
        }
        link.Device = device;
        if (link.UnansweredToken != null) _auth.RemoveUnanswered(link.UnansweredToken);
        link.UnansweredToken = null;

        if (!_auth.RequireApproval)
        {
            _auth.Store.NoteConnected(device.Id, device.Name, link.Address);
            return await AdmitAsync(link);
        }
        var answer = _auth.Store.Ask(device.PublicKey, device.Name, link.Address, link.Group,
            id => _auth.HasWaitingConnection(id));
        switch (answer)
        {
            case DeviceTrustStore.Answer.Trusted:
                return await AdmitAsync(link);
            case DeviceTrustStore.Answer.Denied:
                Log.Line($"DEVICES: {link.Label} is denied; turned away");
                await FinishAsync(link, AuthStatus.Denied);
                return false;
            case DeviceTrustStore.Answer.Busy:
                Log.Line($"DEVICES: too many new devices; {link.Label} turned away");
                await FinishAsync(link, AuthStatus.Busy);
                return false;
            default:
                return await StartWaitingAsync(link);
        }
    }

    private bool OpenClear(Link link, byte[] frame)
    {
        lock (link) { if (link.Phase != Phase.AwaitingResponse) return false; link.Phase = Phase.Open; }
        if (link.UnansweredToken != null) _auth.RemoveUnanswered(link.UnansweredToken);
        link.UnansweredToken = null;
        BecomeSession(link, deviceId: null);
        Log.Line($"port {_port}: {link.Address} connected without a device key (approval is off)");
        Dispatch(frame);
        return true;
    }

    private bool HandleSecure(Link link, byte[] frame)
    {
        if (!WellFramed(frame) || frame[0] != WireType.Secure)
        {
            Log.Line($"port {_port}: {link.Label} sent something that is not a SECURE message — closing");
            return false;
        }
        byte type;
        byte[] payload;
        try { (type, payload) = link.Opener!.Open(Wire.Slice(frame, 5, frame.Length - 5)); }
        catch (AuthException e)
        {
            Log.Line($"port {_port}: {link.Label} sent a message that did not decrypt ({e.Error}) — closing");
            return false;
        }
        if (_session != link) return false;
        if (type == WireType.ClientInfo) return HandleClientInfo(link, payload);
        if (type == WireType.Ping) return true;
        Dispatch(Wire.Frame(type, payload));
        return true;
    }

    private bool HandleClientInfo(Link link, byte[] payload)
    {
        if (payload.Length > MaxClientInfoBytes) return false;
        try
        {
            using var doc = JsonDocument.Parse(payload);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return true;
            string? Text(string name) =>
                doc.RootElement.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
            if (!link.LoggedClientInfo)
            {
                link.LoggedClientInfo = true;
                var app = AuthWire.CleanName(Text("app") ?? "");
                var version = AuthWire.CleanName(Text("version") ?? "");
                if (app.Length > 0) Log.Line($"port {_port}: {link.Label} is {app} {version}".TrimEnd());
            }
            var url = Text("url");
            if (url != null && link.Device != null && _auth.Store.IsTrusted(link.Device.Id))
                _auth.Directory.Report(url, _display.Index);
        }
        catch (JsonException) { }
        return true;
    }

    // MARK: waiting, accepting, finishing

    private async Task<bool> StartWaitingAsync(Link link)
    {
        var device = link.Device!;
        // An earlier waiting connection from the same device gives way to this one.
        List<Link> earlier;
        lock (_linksLock)
            earlier = _links.Where(l => l != link && l.Device?.Id == device.Id).ToList();
        foreach (var l in earlier)
        {
            bool pending;
            lock (l) pending = l.Phase == Phase.Pending;
            if (pending) _ = FinishAsync(l, AuthStatus.Busy);
        }
        var token = _auth.AdmitWaitingConnection(device.Id, link.Group, () => { _ = FinishAsync(link, AuthStatus.Busy); });
        if (token == null)
        {
            Log.Line($"DEVICES: too many devices waiting; {link.Label} turned away");
            await FinishAsync(link, AuthStatus.Busy);
            return false;
        }
        lock (link)
        {
            if (link.Phase != Phase.AwaitingResponse) { _auth.ReleaseWaiting(token); return false; }
            link.Phase = Phase.Pending;
            link.WaitingToken = token;
        }
        var pendingResult = link.Handshake!.Result(AuthStatus.Pending, link.Response, _auth.Identity.Signer);
        link.PendingFrame = Wire.Frame(WireType.AuthResult, pendingResult);
        Log.Line($"DEVICES: {link.Label} is waiting for approval");
        if (!await SendRawAsync(link, link.PendingFrame)) return false;
        _ = PendingLoopAsync(link);
        Reconcile(); // a decision may have landed while this was being set up
        return true;
    }

    private async Task PendingLoopAsync(Link link)
    {
        var started = DateTime.UtcNow;
        try
        {
            while (true)
            {
                var left = _auth.ApprovalTimeout - (DateTime.UtcNow - started);
                if (left <= TimeSpan.Zero)
                {
                    Log.Line($"DEVICES: {link.Label} waited too long; told to try again");
                    await FinishAsync(link, AuthStatus.Timeout);
                    return;
                }
                await Task.Delay(left < _auth.PendingRepeat ? left : _auth.PendingRepeat, link.Cts.Token);
                lock (link) if (link.Phase != Phase.Pending) return;
                if (_auth.ApprovalTimeout - (DateTime.UtcNow - started) <= TimeSpan.Zero) continue;
                // The same signed bytes again: the client learns the link is alive.
                if (!await SendRawAsync(link, link.PendingFrame!)) return;
            }
        }
        catch (OperationCanceledException) { }
    }

    /// <summary>Accepts the device on this link: the signed result, then everything sealed.
    /// False closes the connection.</summary>
    private async Task<bool> AdmitAsync(Link link)
    {
        var device = link.Device!;
        lock (link)
        {
            if (link.Phase != Phase.AwaitingResponse && link.Phase != Phase.Pending) return false;
            link.Phase = Phase.Accepted;
        }
        if (link.WaitingToken != null) _auth.ReleaseWaiting(link.WaitingToken);
        link.WaitingToken = null;

        SessionKeys keys;
        try { keys = link.Handshake!.DeriveSessionKeys(device); }
        catch (AuthException e)
        {
            Log.Line($"port {_port}: could not derive session keys for {link.Label} ({e.Error})");
            return false;
        }
        var result = Wire.Frame(WireType.AuthResult,
            link.Handshake.Result(AuthStatus.Accepted, link.Response, _auth.Identity.Signer));
        link.Opener = new SecureOpener(keys.ClientToHost);
        // The result goes out in the clear, and everything after it sealed. Both under the
        // send lock, so no sealed message can overtake the result.
        await link.SendLock.WaitAsync();
        try
        {
            if (link.Ws.State != WebSocketState.Open) return false;
            await link.Ws.SendAsync(result, WebSocketMessageType.Binary, true, CancellationToken.None);
            link.Sealer = new SecureSealer(keys.HostToClient);
        }
        catch (Exception e) when (e is WebSocketException or IOException or ObjectDisposedException)
        {
            return false;
        }
        finally { link.SendLock.Release(); }

        Log.Line($"DEVICES: {link.Label} connected on port {_port}");
        BecomeSession(link, device.Id);
        var info = _auth.Directory.HostInfo(_auth.HostName, _auth.Identity.Id, _display.Index,
            includeReported: _auth.Store.IsTrusted(device.Id));
        return await SendAsync(link, Wire.Frame(WireType.HostInfo, info));
    }

    /// <summary>Makes <paramref name="link"/> the session, ending the one before it.</summary>
    private void BecomeSession(Link link, string? deviceId)
    {
        lock (_gate)
        {
            if (_session != null && _session != link)
            {
                Log.Line($"port {_port}: new client replaces existing connection");
                Teardown();
            }
            _session = link;
            _ws = link.Ws;
        }
        _auth.SessionOpened(deviceId);
        lock (link) link.Counted = true;
    }

    /// <summary>The signed last word for a link, then the end of it. Used for a decision against
    /// the device and for a connection that is to be told to come back later.</summary>
    private async Task FinishAsync(Link link, AuthStatus status)
    {
        lock (link)
        {
            if (link.Phase == Phase.Closed || link.Finishing) return;
            link.Finishing = true;
        }
        try
        {
            if (link.Handshake != null)
            {
                var result = link.Handshake.Result(status, link.Response, _auth.Identity.Signer);
                await SendRawAsync(link, Wire.Frame(WireType.AuthResult, result));
            }
        }
        catch (AuthException) { }
        CloseLink(link, graceful: true);
    }

    /// <summary>Ends a link for good. Safe to call more than once and from any thread.</summary>
    private void CloseLink(Link link, bool graceful = false)
    {
        bool counted;
        lock (link)
        {
            if (link.Phase == Phase.Closed) return;
            link.Phase = Phase.Closed;
            counted = link.Counted;
        }
        if (link.UnansweredToken != null) _auth.RemoveUnanswered(link.UnansweredToken);
        if (link.WaitingToken != null) _auth.ReleaseWaiting(link.WaitingToken);
        link.UnansweredToken = null;
        link.WaitingToken = null;
        lock (_gate)
        {
            if (_session == link) Teardown();
        }
        if (counted) _auth.SessionClosed(link.Device?.Id);
        link.Cts.Cancel();
        _ = CloseSocketAsync(link.Ws, graceful);
    }

    private static async Task CloseSocketAsync(WebSocket ws, bool graceful)
    {
        try
        {
            if (graceful && ws.State == WebSocketState.Open)
            {
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(1));
                await ws.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, null, cts.Token);
            }
        }
        catch (Exception) { }
        try { ws.Abort(); } catch (Exception) { }
        try { ws.Dispose(); } catch (Exception) { }
    }

    // MARK: following the device list and the setting

    /// <summary>The list or the approval setting changed: waiting links are let in or turned away,
    /// links whose device is no longer trusted are closed.</summary>
    private void Reconcile()
    {
        List<Link> snapshot;
        lock (_linksLock) snapshot = _links.ToList();
        bool approval = _auth.RequireApproval;
        foreach (var link in snapshot)
        {
            Phase phase;
            VerifiedDevice? device;
            lock (link) { phase = link.Phase; device = link.Device; }
            switch (phase)
            {
                case Phase.Pending when device != null:
                    switch (_auth.Store.StateOf(device.Id))
                    {
                        case DeviceState.Trusted: _ = AdmitInBackground(link); break;
                        case DeviceState.Denied: _ = FinishAsync(link, AuthStatus.Denied); break;
                        case null: _ = FinishAsync(link, AuthStatus.Timeout); break;
                    }
                    break;
                case Phase.Accepted when device != null && approval && !_auth.Store.IsTrusted(device.Id):
                    Log.Line($"DEVICES: {link.Label} is no longer trusted; disconnected");
                    _ = FinishAsync(link, AuthStatus.Denied);
                    break;
                case Phase.Open when approval:
                    Log.Line($"port {_port}: device approval was turned on; disconnecting {link.Address}");
                    CloseLink(link);
                    break;
            }
        }
    }

    private async Task AdmitInBackground(Link link)
    {
        if (!await AdmitAsync(link)) CloseLink(link);
    }

    // MARK: sending

    /// <summary>One frame as it goes on the wire for this link: sealed once the link is accepted.
    /// Sealing and writing happen under one lock, so the counter order is the wire order.</summary>
    private async Task<bool> SendAsync(Link link, byte[] frame)
    {
        await link.SendLock.WaitAsync();
        try
        {
            if (link.Ws.State != WebSocketState.Open) return false;
            var data = link.Sealer != null ? link.Sealer.SealMessage(frame) : frame;
            await link.Ws.SendAsync(data, WebSocketMessageType.Binary, true, CancellationToken.None);
            return true;
        }
        catch (Exception e) when (e is WebSocketException or IOException or ObjectDisposedException or AuthException)
        {
            Log.Line($"port {_port}: send failed {e.Message}");
            CloseLink(link);
            return false;
        }
        finally { link.SendLock.Release(); }
    }

    /// <summary>A frame in the clear: the challenge and the results.</summary>
    private async Task<bool> SendRawAsync(Link link, byte[] frame)
    {
        await link.SendLock.WaitAsync();
        try
        {
            if (link.Ws.State != WebSocketState.Open) return false;
            await link.Ws.SendAsync(frame, WebSocketMessageType.Binary, true, CancellationToken.None);
            return true;
        }
        catch (Exception e) when (e is WebSocketException or IOException or ObjectDisposedException)
        {
            return false;
        }
        finally { link.SendLock.Release(); }
    }

    // Serialized send to the session (WebSocket.SendAsync is not concurrency-safe).
    // Returns false if the send failed (client gone).
    private bool Send(byte[] data) => SendAsync(data).GetAwaiter().GetResult();

    private Task<bool> SendAsync(byte[] data)
    {
        var link = _session;
        return link is null ? Task.FromResult(false) : SendAsync(link, data);
    }

    // MARK: the session

    // One protocol message: [type][len BE 4][payload]. Only reached for a session.
    private void Dispatch(ReadOnlySpan<byte> frame)
    {
        if (frame.Length < 5) return;
        var type = (MessageType)frame[0];
        int len = (int)Be.U32(frame, 1);
        if (frame.Length < 5 + len) return;
        var p = frame.Slice(5, len);

        switch (type)
        {
            case MessageType.Hello:
                if (p.Length >= 2)
                    StartSession((StreamCodec)p[1]);
                break;
            case MessageType.KeyframeRequest:
                if (_media) RequestKeyframe();
                break;
            case MessageType.MouseMove:
            case MessageType.MouseButton:
            case MessageType.Key:
            case MessageType.Scroll:
            case MessageType.MouseRelative:
            case MessageType.Text:
            case MessageType.MouseButtonAtCursor:
                {
                    var m = InputMessage.Decode(type, p);
                    if (m is not null) _injector?.Handle(m);
                }
                break;
            case MessageType.Clipboard:
                _clipboard?.ReceiveFromClient(Encoding.UTF8.GetString(p));
                break;
            // ClientDisplays: the host-side auto-collapse is a Mac menu-bar
            // concept with no Windows equivalent, so we accept and ignore it.
            default:
                break;
        }
    }

    private void StartSession(StreamCodec requestedCodec)
    {
        Interlocked.Increment(ref _sessionsStarted);
        if (!_media)
        {
            SendHelloAck(requestedCodec, EncoderStatus.SoftwareFallback);
            return;
        }
        _injector?.ReleaseAll(); // a repeated HELLO must not strand held keys
        _injector = new InputInjector(_display.Bounds);
        if (IsPrimary)
        {
            var cb = new ClipboardBridge();
            cb.OnLocalChange = text => { Send(Proto.Clipboard(text)); };
            cb.Start();
            _clipboard = cb;
        }
        StartVideo(requestedCodec); // implemented in the video partial; sends HELLO_ACK
    }

    // Must hold _gate. Ends the session's work; the link's own socket is closed by CloseLink,
    // or here when this ends a session that CloseLink is not already closing.
    private void Teardown()
    {
        var link = _session;
        _session = null;
        _ws = null;
        TeardownVideo();
        _clipboard?.Dispose();
        _clipboard = null;
        // Release anything this client still holds down before the session goes.
        _injector?.ReleaseAll();
        _injector = null;
        if (link != null) CloseLink(link);
    }

    public void Dispose()
    {
        _auth.Store.DidChange -= Reconcile;
        _auth.ApprovalDidChange -= Reconcile;
        _life.Cancel();
        List<Link> snapshot;
        lock (_linksLock) snapshot = _links.ToList();
        foreach (var l in snapshot) CloseLink(l);
        lock (_gate) Teardown();
        try { _listener.Stop(); } catch { }
        _listener.Close();
    }
}
