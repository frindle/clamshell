using System.Net;
using System.Net.WebSockets;

namespace Clamshell;

// Host side of the stream for ONE display — the C# mirror of the Mac's
// StreamServer. A raw HttpListener WebSocket endpoint (no ASP.NET Core: this is
// a single-purpose headless tool) accepts one client at a time; a new
// connection replaces the old one. Receives input on the same socket and
// injects it. The primary display (index 0) also carries audio and clipboard.
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
    private bool IsPrimary => _display.IsPrimary;

    private readonly HttpListener _listener = new();
    private readonly CancellationTokenSource _life = new();

    // Current client. Guarded by _gate. A new client cancels the previous one.
    private readonly object _gate = new();
    private WebSocket? _ws;
    private CancellationTokenSource? _clientCts;
    private readonly SemaphoreSlim _sendLock = new(1, 1);

    private InputInjector? _injector;
    private ClipboardBridge? _clipboard;

    public StreamServer(DisplayInfo display, ushort basePort)
    {
        _display = display;
        _basePort = basePort;
        _port = display.Port(basePort);
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
            // CF Access headers (Cf-Access-*) ride along on the tunnel; we ignore
            // them, same as the Mac host — validation is the edge's job.
            try
            {
                var wsCtx = await ctx.AcceptWebSocketAsync(subProtocol: null);
                OnClient(wsCtx.WebSocket);
            }
            catch (Exception e) { Log.Line($"port {_port}: ws upgrade failed {e.Message}"); }
        }
    }

    private void OnClient(WebSocket ws)
    {
        CancellationTokenSource cts;
        lock (_gate)
        {
            if (_ws != null)
            {
                Log.Line($"port {_port}: new client replaces existing connection");
                Teardown();
            }
            _ws = ws;
            _clientCts = cts = CancellationTokenSource.CreateLinkedTokenSource(_life.Token);
        }
        _ = ReceiveLoopAsync(ws, cts.Token);
    }

    private async Task ReceiveLoopAsync(WebSocket ws, CancellationToken ct)
    {
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
                        Disconnect(ws);
                        return;
                    }
                    msg.Write(buf, 0, r.Count);
                    if (msg.Length > 64 << 20) { Log.Line($"port {_port}: oversize message — dropping client"); Disconnect(ws); return; }
                } while (!r.EndOfMessage);

                Dispatch(msg.GetBuffer().AsSpan(0, (int)msg.Length));
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { Log.Line($"port {_port}: receive error {e.Message}"); }
        Disconnect(ws);
    }

    // One binary WS message == one protocol message: [type][len BE 4][payload].
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
                RequestKeyframe();
                break;
            case MessageType.MouseMove:
                if (p.Length >= 8) _injector?.MouseMove(Be.F32(p, 0), Be.F32(p, 4));
                break;
            case MessageType.MouseButton:
                if (p.Length >= 10) _injector?.MouseButton(p[0], p[1] == 1, Be.F32(p, 2), Be.F32(p, 6));
                break;
            case MessageType.Key:
                if (p.Length >= 11) _injector?.Key(Be.U16(p, 0), p[2] == 1, Be.U64(p, 3));
                break;
            case MessageType.Scroll:
                if (p.Length >= 8) _injector?.Scroll(Be.F32(p, 0), Be.F32(p, 4));
                break;
            case MessageType.Clipboard:
                _clipboard?.ReceiveFromClient(System.Text.Encoding.UTF8.GetString(p));
                break;
            // ClientDisplays: the host-side auto-collapse is a Mac menu-bar
            // concept with no Windows equivalent, so we accept and ignore it.
            default:
                break;
        }
    }

    private void StartSession(StreamCodec requestedCodec)
    {
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

    // Serialized binary send (WebSocket.SendAsync is not concurrency-safe).
    // Returns false if the send failed (client gone).
    private bool Send(byte[] data) => SendAsync(data).GetAwaiter().GetResult();

    private async Task<bool> SendAsync(byte[] data)
    {
        WebSocket? ws = _ws;
        if (ws is null) return false;
        await _sendLock.WaitAsync();
        try
        {
            if (ws.State != WebSocketState.Open) return false;
            await ws.SendAsync(data, WebSocketMessageType.Binary, true, CancellationToken.None);
            return true;
        }
        catch (Exception e) { Log.Line($"port {_port}: send failed {e.Message}"); Disconnect(ws); return false; }
        finally { _sendLock.Release(); }
    }

    private void Disconnect(WebSocket ws)
    {
        lock (_gate)
        {
            if (_ws != ws) return;
            Teardown();
        }
    }

    // Must hold _gate.
    private void Teardown()
    {
        _clientCts?.Cancel();
        _clientCts = null;
        TeardownVideo();
        _clipboard?.Dispose();
        _clipboard = null;
        _injector = null;
        try { _ws?.Abort(); } catch { }
        try { _ws?.Dispose(); } catch { }
        _ws = null;
    }

    public void Dispose()
    {
        _life.Cancel();
        lock (_gate) Teardown();
        try { _listener.Stop(); } catch { }
        _listener.Close();
    }
}
