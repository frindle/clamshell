using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Channels;

namespace Clamshell;

// The control connection between two paired machines (PROTOCOL.md "Peer
// link") — the mirror of Sources/Clamshell/Peer/PeerLink.swift, same
// handshake, same messages, same rules:
//   server → CHALLENGE(nonce) ; client → HELLO(key, nonce', sig, [PIN proof])
//   server → HELLO_ACK(status, key, sig', [PIN proof]) ; then framed messages.
//
// Transport: one WebSocket on TCP 5910. Both directions do the RFC 6455
// upgrade by hand over a plain TcpListener / TcpClient and then hand the
// stream to WebSocket.CreateFromStream — no HttpListener, so no URL ACL /
// elevation, and the peer's real address is known on both sides (a window
// handoff's stream is dialled there and only accepted from there).
//
// Callbacks (OnStateChange, OnMessage) fire on one background thread, in
// order (state and messages interleaved as they happened). Callers marshal
// to their UI thread as needed.

internal enum PeerLinkPhase { Idle, Connecting, Handshaking, Linked, Failed }

internal sealed record PeerLinkState(PeerLinkPhase Phase, string Label = "", PeerInfo? Peer = null,
                                     uint ScreenWidth = 0, uint ScreenHeight = 0)
{
    public bool IsLinked => Phase == PeerLinkPhase.Linked;
    public static readonly PeerLinkState Idle = new(PeerLinkPhase.Idle);
}

internal sealed class PeerLink : IDisposable
{
    public PeerIdentity Identity { get; }
    public PeerTrustStore Trust { get; }
    public string LocalName { get; }
    public ushort Port { get; }
    private readonly Func<(uint W, uint H)> _screenSize;

    private readonly object _gate = new();
    private TcpListener? _listener;
    private CancellationTokenSource? _life;
    private Conn? _conn;
    private Handshake? _hs;
    private System.Threading.Timer? _hsTimer;
    // State changes and messages leave through one serial queue, so a
    // listener always sees Linked before that link's first message and
    // messages in arrival order.
    private readonly SerialQueue _events = new("peer-link-events");

    public PeerLinkState State { get; private set; } = PeerLinkState.Idle;
    /// Linked peer's address (IPv4 unmapped, no scope) — where a handoff's
    /// window stream is dialled.
    public string? RemoteHost { get; private set; }
    /// Single-use pairing PIN shown on this machine; regenerated after a pairing.
    public string PairingPin { get; private set; } = PeerIdentity.RandomPin();

    public event Action<PeerLinkState>? OnStateChange;
    /// Post-authentication messages only.
    public event Action<MessageType, byte[]>? OnMessage;

    private sealed record Handshake(bool IsServer, byte[] OurNonce, string? Pin, string Label);

    public PeerLink(PeerIdentity identity, PeerTrustStore trust, string localName, ushort port,
                    Func<(uint W, uint H)> screenSize)
    {
        Identity = identity; Trust = trust; LocalName = localName; Port = port; _screenSize = screenSize;
    }

    // MARK: - Listening

    public void StartListening()
    {
        _life = new CancellationTokenSource();
        var l = new TcpListener(IPAddress.IPv6Any, Port);
        l.Server.DualMode = true;
        l.Start();
        _listener = l;
        Log.Line($"PEER: listening on {Port} as \"{LocalName}\" ({Identity.Id[..12]}…)");
        _ = AcceptLoop(l, _life.Token);
    }

    private async Task AcceptLoop(TcpListener l, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await l.AcceptTcpClientAsync(ct); }
            catch { return; }
            _ = Task.Run(async () =>
            {
                try
                {
                    client.NoDelay = true;
                    var stream = client.GetStream();
                    await WsUpgrade.ServerAsync(stream, TimeSpan.FromSeconds(10));
                    var ws = WebSocket.CreateFromStream(stream, new WebSocketCreationOptions
                    { IsServer = true, KeepAliveInterval = TimeSpan.FromSeconds(20) });
                    Accept(new Conn(client, ws));
                }
                catch (Exception e)
                {
                    Log.Line($"PEER: incoming upgrade failed: {e.Message}");
                    client.Dispose();
                }
            });
        }
    }

    private void Accept(Conn c)
    {
        lock (_gate)
        {
            if (_conn is not null)
            {
                Log.Line(State.IsLinked ? "PEER: incoming connection while linked — replacing" : "PEER: incoming connection replaces a pending one");
                DropLocked(null);
            }
            _hs = new Handshake(true, PeerIdentity.RandomNonce(), PairingPin, "incoming");
            AttachLocked(c);
            SetStateLocked(new PeerLinkState(PeerLinkPhase.Handshaking, "incoming"));
            c.Send(PeerMsg.Challenge(_hs.OurNonce));
        }
    }

    // MARK: - Connecting out

    public void Connect(string host, ushort port, string? pin, string? label = null)
    {
        string lbl = label ?? $"{host}:{port}";
        lock (_gate)
        {
            DropLocked(null);
            SetStateLocked(new PeerLinkState(PeerLinkPhase.Connecting, lbl));
        }
        _ = Task.Run(async () =>
        {
            var client = new TcpClient(AddressFamily.InterNetworkV6) { NoDelay = true };
            client.Client.DualMode = true;
            try
            {
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                await client.ConnectAsync(host, port, cts.Token);
                var stream = client.GetStream();
                await WsUpgrade.ClientAsync(stream, host, port, TimeSpan.FromSeconds(10));
                var ws = WebSocket.CreateFromStream(stream, new WebSocketCreationOptions
                { IsServer = false, KeepAliveInterval = TimeSpan.FromSeconds(20) });
                lock (_gate)
                {
                    if (State.Phase != PeerLinkPhase.Connecting || State.Label != lbl) { client.Dispose(); return; }
                    _hs = new Handshake(false, PeerIdentity.RandomNonce(), pin, lbl);
                    AttachLocked(new Conn(client, ws));
                    SetStateLocked(new PeerLinkState(PeerLinkPhase.Handshaking, lbl));
                }
            }
            catch (Exception e)
            {
                client.Dispose();
                lock (_gate)
                {
                    if (State.Phase == PeerLinkPhase.Connecting && State.Label == lbl)
                        SetStateLocked(new PeerLinkState(PeerLinkPhase.Failed, $"connect {lbl}: {e.Message}"));
                }
            }
        });
    }

    public void Disconnect()
    {
        lock (_gate) { DropLocked("disconnected"); SetStateLocked(PeerLinkState.Idle); }
    }

    public void Stop()
    {
        _life?.Cancel();
        try { _listener?.Stop(); } catch { }
        _listener = null;
        lock (_gate) DropLocked(null);
    }

    public void Dispose() => Stop();

    // MARK: - Connection plumbing

    /// Must hold _gate.
    private void AttachLocked(Conn c)
    {
        _conn = c;
        c.Parser.OnMessage = (t, p) => Handle(c, t, p);
        c.OnClosed = why => { lock (_gate) { if (_conn == c) DropLocked(why); } };
        c.Start();
        _hsTimer?.Dispose();
        _hsTimer = new System.Threading.Timer(_ =>
        {
            lock (_gate) { if (_conn == c && _hs is not null) DropLocked("handshake timed out"); }
        }, null, TimeSpan.FromSeconds(15), Timeout.InfiniteTimeSpan);
    }

    /// Must hold _gate.
    private void DropLocked(string? reason)
    {
        _hsTimer?.Dispose(); _hsTimer = null;
        _hs = null;
        var c = _conn;
        _conn = null;
        c?.Close();
        if (reason is not null)
        {
            Log.Line($"PEER: {reason}");
            if (State.Phase != PeerLinkPhase.Idle) SetStateLocked(new PeerLinkState(PeerLinkPhase.Failed, reason));
        }
    }

    /// Must hold _gate. Fires the callback outside the lock's ordering
    /// guarantees but on a pool thread, like the Swift side's queue.
    private void SetStateLocked(PeerLinkState s)
    {
        State = s;
        var cb = OnStateChange;
        if (cb is not null) _events.Post(() => cb(s));
    }

    // MARK: - Handshake

    private void Handle(Conn c, MessageType type, byte[] payload)
    {
        Action? deliver = null;
        lock (_gate)
        {
            if (_conn != c) return;
            switch (type)
            {
                case MessageType.PeerChallenge:
                {
                    if (_hs is not { IsServer: false } h || payload.Length != PeerLimits.NonceSize) { DropLocked("unexpected CHALLENGE"); return; }
                    var (w, hgt) = _screenSize();
                    byte[]? proof = h.Pin is { } pin ? PeerIdentity.PinProof(pin, payload, Identity.PublicKey) : null;
                    c.Send(PeerMsg.Hello(Identity.PublicKey, h.OurNonce, Identity.Sign(payload), proof, LocalName, w, hgt));
                    break;
                }
                case MessageType.PeerHello:
                {
                    if (_hs is not { IsServer: true } h) { DropLocked("unexpected HELLO"); return; }
                    var hello = PeerParse.Hello(payload);
                    if (hello is null) { RefuseLocked(c, PeerHelloStatus.Version, "malformed HELLO"); return; }
                    if (!PeerIdentity.Verify(hello.Signature, h.OurNonce, hello.PublicKey)) { RefuseLocked(c, PeerHelloStatus.BadSignature, "HELLO bad signature"); return; }
                    string? usedPin = null;
                    if (!Trust.IsTrusted(hello.PublicKey))
                    {
                        if (hello.PinProof is null) { RefuseLocked(c, PeerHelloStatus.Untrusted, $"untrusted peer {hello.Name} (no PIN)"); return; }
                        if (h.Pin is null || !PeerIdentity.VerifyPinProof(hello.PinProof, h.Pin, h.OurNonce, hello.PublicKey))
                        { RefuseLocked(c, PeerHelloStatus.BadPin, $"wrong PIN from {hello.Name}"); return; }
                        usedPin = h.Pin;
                        Log.Line($"PEER: paired with {hello.Name} via PIN");
                    }
                    var (w, hgt) = _screenSize();
                    byte[]? proof = usedPin is null ? null : PeerIdentity.PinProof(usedPin, hello.ClientNonce, Identity.PublicKey);
                    c.Send(PeerMsg.HelloAck(PeerHelloStatus.Ok, Identity.PublicKey, Identity.Sign(hello.ClientNonce), proof, LocalName, w, hgt));
                    FinishLocked(c, hello.PublicKey, hello.Name, usedPin is not null, hello.ScreenWidth, hello.ScreenHeight);
                    break;
                }
                case MessageType.PeerHelloAck:
                {
                    if (_hs is not { IsServer: false } h) { DropLocked("unexpected HELLO_ACK"); return; }
                    var ack = PeerParse.HelloAck(payload);
                    if (ack is null) { DropLocked("malformed HELLO_ACK"); return; }
                    if (ack.Status != PeerHelloStatus.Ok) { DropLocked($"peer refused: {Describe(ack.Status)}"); return; }
                    if (!PeerIdentity.Verify(ack.Signature, h.OurNonce, ack.PublicKey)) { DropLocked("HELLO_ACK bad signature"); return; }
                    bool paired = false;
                    if (!Trust.IsTrusted(ack.PublicKey))
                    {
                        if (h.Pin is null || ack.PinProof is null || !PeerIdentity.VerifyPinProof(ack.PinProof, h.Pin, h.OurNonce, ack.PublicKey))
                        { DropLocked($"peer {ack.Name} did not prove the PIN"); return; }
                        paired = true;
                    }
                    FinishLocked(c, ack.PublicKey, ack.Name, paired, ack.ScreenWidth, ack.ScreenHeight);
                    break;
                }
                default:
                    if (_hs is not null || !State.IsLinked) { DropLocked("message before authentication"); return; }
                    var cb = OnMessage;
                    if (cb is not null) deliver = () => cb(type, payload);
                    break;
            }
        }
        if (deliver is not null) _events.Post(deliver); // outside the lock, same queue as state changes (ordered)
    }

    /// Refusal ACK reaches the wire before the socket closes.
    private void RefuseLocked(Conn c, PeerHelloStatus status, string reason)
    {
        _hs = null;
        c.Send(PeerMsg.HelloAck(status), () => { lock (_gate) { if (_conn == c) DropLocked(reason); } });
    }

    private void FinishLocked(Conn c, byte[] publicKey, string name, bool paired, uint sw, uint sh)
    {
        _hsTimer?.Dispose(); _hsTimer = null;
        _hs = null;
        if (paired) PairingPin = PeerIdentity.RandomPin();
        Trust.Trust(publicKey, name);
        RemoteHost = c.RemoteHost;
        var info = new PeerInfo(PeerIdentity.PeerId(publicKey), name, publicKey, DateTime.UtcNow);
        Log.Line($"PEER: linked with {name} ({info.Id[..12]}…) screen {sw}x{sh} at {RemoteHost}");
        SetStateLocked(new PeerLinkState(PeerLinkPhase.Linked, name, info, sw, sh));
    }

    public static string Describe(PeerHelloStatus s) => s switch
    {
        PeerHelloStatus.Ok => "ok",
        PeerHelloStatus.Untrusted => "not paired — enter that machine's pairing PIN",
        PeerHelloStatus.BadPin => "wrong PIN",
        PeerHelloStatus.BadSignature => "signature rejected",
        PeerHelloStatus.Busy => "peer is linked to another machine",
        _ => "protocol version mismatch",
    };

    // MARK: - Sending

    /// Post-auth send; <paramref name="completion"/> runs once the bytes are
    /// handed to the socket (file transfer paces itself on it).
    public void Send(byte[] data, Action? completion = null)
    {
        Conn? c;
        lock (_gate) c = State.IsLinked ? _conn : null;
        if (c is null) { completion?.Invoke(); return; }
        c.Send(data, completion);
    }

    // MARK: - One connection

    private sealed class Conn
    {
        private readonly TcpClient _tcp;
        private readonly WebSocket _ws;
        private readonly CancellationTokenSource _cts = new();
        private readonly Channel<(byte[] Data, Action? Done)> _out = Channel.CreateUnbounded<(byte[], Action?)>();
        public readonly FrameParser Parser = new();
        public Action<string>? OnClosed;
        public string? RemoteHost { get; }
        private int _closed;

        public Conn(TcpClient tcp, WebSocket ws)
        {
            _tcp = tcp; _ws = ws;
            RemoteHost = NormalizeHost(tcp.Client.RemoteEndPoint);
        }

        public static string? NormalizeHost(EndPoint? ep)
        {
            if (ep is not IPEndPoint ip) return null;
            var a = ip.Address.IsIPv4MappedToIPv6 ? ip.Address.MapToIPv4() : ip.Address;
            if (a.AddressFamily == AddressFamily.InterNetworkV6) a.ScopeId = 0;
            return a.ToString();
        }

        public void Start()
        {
            _ = Task.Run(ReceiveLoop);
            _ = Task.Run(SendLoop);
        }

        public void Send(byte[] data, Action? done = null)
        {
            if (!_out.Writer.TryWrite((data, done))) done?.Invoke();
        }

        private async Task SendLoop()
        {
            try
            {
                await foreach (var (data, done) in _out.Reader.ReadAllAsync(_cts.Token))
                {
                    try { await _ws.SendAsync(data, WebSocketMessageType.Binary, true, _cts.Token); }
                    catch (Exception e) { done?.Invoke(); Fail($"send failed ({e.Message})"); return; }
                    done?.Invoke();
                }
            }
            catch (OperationCanceledException) { }
            // Drain completions of anything left so no sender waits forever.
            while (_out.Reader.TryRead(out var left)) left.Done?.Invoke();
        }

        private async Task ReceiveLoop()
        {
            var buf = new byte[64 * 1024];
            try
            {
                while (!_cts.IsCancellationRequested)
                {
                    var r = await _ws.ReceiveAsync(buf, _cts.Token);
                    if (r.MessageType == WebSocketMessageType.Close) { Fail("peer disconnected (close)"); return; }
                    Parser.Feed(buf.AsSpan(0, r.Count));
                    if (Parser.Corrupt) { Fail("corrupt stream"); return; }
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception e) { Fail($"peer disconnected ({e.Message})"); }
        }

        private void Fail(string why)
        {
            if (Interlocked.Exchange(ref _closed, 1) == 1) return;
            OnClosed?.Invoke(why);
            Teardown();
        }

        public void Close()
        {
            if (Interlocked.Exchange(ref _closed, 1) == 1) return;
            Teardown();
        }

        private void Teardown()
        {
            _out.Writer.TryComplete();
            // Let queued sends (a refusal ACK) flush briefly before the abort.
            _ = Task.Run(async () =>
            {
                await Task.Delay(200);
                _cts.Cancel();
                try { _ws.Abort(); } catch { }
                try { _ws.Dispose(); } catch { }
                try { _tcp.Dispose(); } catch { }
            });
        }
    }
}

/// RFC 6455 opening handshake over a raw stream (both roles). Header bytes
/// are read one at a time so nothing after the blank line is consumed.
internal static class WsUpgrade
{
    private const string Magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

    public static string AcceptFor(string key) =>
        Convert.ToBase64String(SHA1.HashData(Encoding.ASCII.GetBytes(key.Trim() + Magic)));

    private static async Task<List<string>> ReadHeadAsync(Stream s, TimeSpan timeout)
    {
        using var cts = new CancellationTokenSource(timeout);
        var sb = new StringBuilder();
        var one = new byte[1];
        while (true)
        {
            int n = await s.ReadAsync(one, cts.Token);
            if (n == 0) throw new IOException("connection closed during upgrade");
            sb.Append((char)one[0]);
            if (sb.Length > 8192) throw new IOException("upgrade header too large");
            if (sb.Length >= 4 && sb[^1] == '\n' && sb[^2] == '\r' && sb[^3] == '\n' && sb[^4] == '\r') break;
        }
        return sb.ToString().Split("\r\n", StringSplitOptions.RemoveEmptyEntries).ToList();
    }

    private static string? Header(List<string> lines, string name)
    {
        foreach (var l in lines.Skip(1))
        {
            int c = l.IndexOf(':');
            if (c > 0 && l[..c].Trim().Equals(name, StringComparison.OrdinalIgnoreCase)) return l[(c + 1)..].Trim();
        }
        return null;
    }

    public static async Task ServerAsync(Stream s, TimeSpan timeout)
    {
        var lines = await ReadHeadAsync(s, timeout);
        string? key = Header(lines, "Sec-WebSocket-Key");
        bool upgrade = Header(lines, "Upgrade")?.Equals("websocket", StringComparison.OrdinalIgnoreCase) == true;
        if (lines.Count == 0 || !lines[0].StartsWith("GET ") || key is null || !upgrade)
        {
            byte[] no = Encoding.ASCII.GetBytes("HTTP/1.1 426 Upgrade Required\r\nConnection: close\r\n\r\n");
            await s.WriteAsync(no);
            throw new IOException("not a WebSocket upgrade");
        }
        string resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                      $"Sec-WebSocket-Accept: {AcceptFor(key)}\r\n\r\n";
        await s.WriteAsync(Encoding.ASCII.GetBytes(resp));
    }

    public static async Task ClientAsync(Stream s, string host, ushort port, TimeSpan timeout)
    {
        string key = Convert.ToBase64String(RandomNumberGenerator.GetBytes(16));
        string h = host.Contains(':') ? $"[{host}]" : host;
        string req = $"GET / HTTP/1.1\r\nHost: {h}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                     $"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n";
        await s.WriteAsync(Encoding.ASCII.GetBytes(req));
        var lines = await ReadHeadAsync(s, timeout);
        if (lines.Count == 0 || !lines[0].Contains(" 101")) throw new IOException($"upgrade refused: {(lines.Count > 0 ? lines[0] : "empty")}");
        if (Header(lines, "Sec-WebSocket-Accept") != AcceptFor(key)) throw new IOException("bad Sec-WebSocket-Accept");
    }
}
