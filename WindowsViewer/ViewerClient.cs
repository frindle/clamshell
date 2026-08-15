using System.IO;
using System.Net.WebSockets;

namespace Clamshell;

// Client side of the stream: connects to a Clamshell host's window-stream (or
// display-stream -- same wire protocol either way, see PROTOCOL.md) WebSocket
// endpoint, does the HELLO/HELLO_ACK handshake, decodes VIDEO_FRAME via
// VideoDecoder, and forwards INPUT_* back. Mirrors the shape of
// WindowsServer/StreamServer.cs's receive loop, reversed (host->client
// instead of client->host).
internal sealed class ViewerClient : IDisposable
{
    public Action<StreamCodec, int, int>? OnHelloAck; // codec, widthPx, heightPx (encoded dims from HELLO_ACK)
    public Action<int, int, byte[]>? OnFrame;          // decoded width, height, BGRA32
    public Action<string>? OnDisconnected;

    private readonly ClientWebSocket _ws = new();
    private VideoDecoder? _decoder;
    private readonly CancellationTokenSource _cts = new();

    public async Task ConnectAsync(string host, int port, StreamCodec requestedCodec)
    {
        var uri = new Uri($"ws://{host}:{port}/");
        await _ws.ConnectAsync(uri, _cts.Token);
        await SendAsync(Proto.Hello(requestedCodec));
        _ = ReceiveLoopAsync();
    }

    public Task SendMouseMove(float x, float y) => SendAsync(Proto.MouseMove(x, y));
    public Task SendMouseButton(byte button, bool down, float x, float y) => SendAsync(Proto.MouseButton(button, down, x, y));
    public Task SendKey(ushort macKeyCode, bool down, ulong flags) => SendAsync(Proto.Key(macKeyCode, down, flags));
    public Task SendScroll(float dx, float dy) => SendAsync(Proto.Scroll(dx, dy));
    public Task RequestKeyframe() => SendAsync(Proto.KeyframeRequest());

    private readonly SemaphoreSlim _sendLock = new(1, 1);
    private async Task SendAsync(byte[] data)
    {
        if (_ws.State != WebSocketState.Open) return;
        await _sendLock.WaitAsync();
        // Explicit ArraySegment<byte> (not a bare byte[]): ClientWebSocket
        // exposes both an ArraySegment<byte> overload (inherited from the
        // abstract WebSocket base) and a Memory<byte> overload of its own --
        // an unqualified byte[] argument is ambiguous between the two.
        try { await _ws.SendAsync(new ArraySegment<byte>(data), WebSocketMessageType.Binary, true, CancellationToken.None); }
        catch (Exception e) { Log.Line($"send failed: {e.Message}"); }
        finally { _sendLock.Release(); }
    }

    private async Task ReceiveLoopAsync()
    {
        var buf = new byte[256 * 1024];
        using var msg = new MemoryStream();
        try
        {
            while (_ws.State == WebSocketState.Open)
            {
                msg.SetLength(0);
                WebSocketReceiveResult r;
                do
                {
                    // Same ambiguity note as SendAsync above -- explicit ArraySegment<byte>.
                    r = await _ws.ReceiveAsync(new ArraySegment<byte>(buf), _cts.Token);
                    if (r.MessageType == WebSocketMessageType.Close)
                    {
                        OnDisconnected?.Invoke("host closed connection");
                        return;
                    }
                    msg.Write(buf, 0, r.Count);
                    if (msg.Length > 32 << 20) { OnDisconnected?.Invoke("oversize message"); return; }
                } while (!r.EndOfMessage);

                Dispatch(msg.GetBuffer().AsSpan(0, (int)msg.Length));
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { OnDisconnected?.Invoke(e.Message); return; }
        OnDisconnected?.Invoke("receive loop ended");
    }

    private void Dispatch(ReadOnlySpan<byte> frame)
    {
        if (frame.Length < 5) return;
        var type = (MessageType)frame[0];
        int len = (int)Be.U32(frame, 1);
        if (frame.Length < 5 + len) return;
        var p = frame.Slice(5, len);

        switch (type)
        {
            case MessageType.HelloAck:
                if (p.Length >= 11)
                {
                    var codec = (StreamCodec)p[1];
                    int w = (int)Be.U32(p, 2), h = (int)Be.U32(p, 6);
                    _decoder = new VideoDecoder(codec);
                    _decoder.OnFrame = (dw, dh, bgra) => OnFrame?.Invoke(dw, dh, bgra);
                    OnHelloAck?.Invoke(codec, w, h);
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
        _cts.Cancel();
        try { _ws.Abort(); } catch { }
        _ws.Dispose();
        _decoder?.Dispose();
    }
}
