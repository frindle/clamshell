using System.Runtime.InteropServices;
using System.Threading;

namespace Clamshell;

// Video + adaptive-bitrate half of StreamServer. Split into its own partial so
// the transport/input/clipboard half stays readable. Capture + MFT encode are
// wired in here; DisplayCapture pushes NV12 frames into VideoEncoder, whose
// AVCC output is framed and sent with backpressure-driven adaptive bitrate.
internal sealed partial class StreamServer
{
    private VideoEncoder? _encoder;
    private DisplayCapture? _capture;
    private AudioEncoder? _audio;
    // Explicit System.Threading.Timer: this project's WinForms + ImplicitUsings
    // combo brings System.Windows.Forms into global scope, so a bare "Timer"
    // is ambiguous with System.Windows.Forms.Timer (CS0104) even though only
    // System.Threading is imported here.
    private System.Threading.Timer? _cursorTimer;
    private (float x, float y)? _lastSentCursor;

    // Adaptive bitrate (PROTOCOL.md "Adaptive bitrate"): reactive, driven by
    // WebSocket send backpressure. _inFlight counts frames handed to Send but
    // not yet completed; at the cap we drop deltas and resync on a keyframe,
    // stepping the live MFT bitrate down. Same bounds/timings as the Mac.
    private int _inFlight;
    private const int MaxInFlight = 8;
    private int _bitrate = VideoEncoder.MaxBitrate;
    private long _lastCongestionTicks;
    private long _lastStepTicks;

    private void StartVideo(StreamCodec requestedCodec)
    {
        try
        {
            _encoder = VideoEncoder.Create(_display.Bounds.Width, _display.Bounds.Height, requestedCodec);
        }
        catch (Exception e)
        {
            Log.Line($"port {_port}: encoder init failed ({e.Message}) — no video this session");
            // Still complete the handshake so input/clipboard work; report the
            // fallback so the client warns.
            SendHelloAck(StreamCodec.H264, EncoderStatus.SoftwareFallback);
            return;
        }

        _inFlight = 0;
        _bitrate = VideoEncoder.MaxBitrate;
        _lastCongestionTicks = _lastStepTicks = 0;

        _encoder.OnFrame = (keyframe, ptsMicros, avcc) => SendFrame(keyframe, ptsMicros, avcc);
        SendHelloAck(_encoder.Codec, _encoder.Status);
        SendStreamStatus(); // initial bitrate for the quality dot

        _capture = new DisplayCapture(_display, _encoder);
        _capture.Start();

        // Only the primary connection carries system audio (mirrors the Mac).
        if (IsPrimary)
        {
            var audio = new AudioEncoder();
            audio.OnPacket = aac => { _ = SendAsync(Proto.AudioFrame(aac)); };
            audio.Start();
            _audio = audio;
        }

        StartCursorReporting();

        Log.Line($"port {_port}: session started — {_encoder.Codec} {_display.Bounds.Width}x{_display.Bounds.Height}" +
                 $"{(_encoder.Status == EncoderStatus.HardwareActive ? "" : " [SOFTWARE ENCODE]")}");
    }

    private void TeardownVideo()
    {
        _cursorTimer?.Dispose();
        _cursorTimer = null;
        _lastSentCursor = null;
        _audio?.Dispose();
        _audio = null;
        _capture?.Dispose();
        _capture = null;
        _encoder?.Dispose();
        _encoder = null;
    }

    // MARK: - Cursor-follow auto-pan
    //
    // Mirrors the Mac's CGEvent-based cursor poll: 20 Hz, skipped when the
    // cursor hasn't moved (beyond a small epsilon) since the last send, so an
    // idle mouse costs nothing. GetCursorPos returns virtual-desktop screen
    // pixels (same top-left-origin space InputInjector maps into via
    // _display.Bounds), so normalizing against this display's bounds is a
    // direct mirror of the Mac's CGDisplayBounds math.
    private void StartCursorReporting()
    {
        _cursorTimer = new System.Threading.Timer(_ =>
        {
            if (_ws is null) return;
            if (!GetCursorPos(out var pt)) return;
            var b = _display.Bounds;
            if (b.Width <= 0 || b.Height <= 0) return;
            float nx = (pt.X - b.X) / (float)b.Width;
            float ny = (pt.Y - b.Y) / (float)b.Height;
            if (_lastSentCursor is { } last &&
                Math.Abs(last.x - nx) < 0.001f && Math.Abs(last.y - ny) < 0.001f) return;
            _lastSentCursor = (nx, ny);
            _ = SendAsync(Proto.CursorPos(nx, ny));
        }, null, TimeSpan.Zero, TimeSpan.FromMilliseconds(50)); // 20 Hz
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X, Y; }

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT lpPoint);

    private void RequestKeyframe() => _encoder?.RequestKeyframe();

    // MARK: - HELLO_ACK flags — the hardware-vs-software warning distinction.
    //
    // The wire has ONE meaningful bit today (bit 0). Its real job is "should the
    // client show the software-encoding warning banner?". All three encoder
    // states collapse cleanly onto that one question:
    //   HardwareActive    -> don't warn  (bit 0 = 1)
    //   SoftwareExpected  -> don't warn  (bit 0 = 1)  <- the refined requirement:
    //                        no hardware present at all is EXPECTED, not alarming
    //   SoftwareFallback  -> warn        (bit 0 = 0)  <- hardware existed but failed
    // So no breaking wire change is needed for the behavior that matters.
    //
    // bit 1 is a PROPOSED, backward-compatible extension (old clients mask only
    // bit 0, so they're unaffected): "genuinely hardware", for an accurate Nerd
    // Mode hw/sw label in the SoftwareExpected case. The Mac/iOS sides do not
    // read it yet — see the report and PROTOCOL.md note. Setting it here is free.
    private static byte HelloAckFlags(EncoderStatus s) => s switch
    {
        EncoderStatus.HardwareActive   => 0b11, // don't warn + genuinely hardware
        EncoderStatus.SoftwareExpected => 0b01, // don't warn (expected software)
        EncoderStatus.SoftwareFallback => 0b00, // warn
        _ => 0b00,
    };

    private void SendHelloAck(StreamCodec codec, EncoderStatus status) =>
        Send(Proto.HelloAck(codec, (uint)_display.Bounds.Width, (uint)_display.Bounds.Height, HelloAckFlags(status)));

    // MARK: - Frame send + adaptive bitrate

    private void SendFrame(bool keyframe, ulong ptsMicros, byte[] avcc)
    {
        if (_ws is null) return;
        if (_inFlight >= MaxInFlight && !keyframe)
        {
            _encoder?.RequestKeyframe();
            StepBitrateDown();
            return;
        }
        MaybeStepBitrateUp();
        Interlocked.Increment(ref _inFlight);
        _ = SendAsync(Proto.VideoFrame(keyframe, ptsMicros, avcc))
            .ContinueWith(_ => Interlocked.Decrement(ref _inFlight));
    }

    private void SendStreamStatus()
    {
        if (_ws is null) return;
        Send(Proto.StreamStatus((ushort)Math.Min(_bitrate / 1000, ushort.MaxValue)));
    }

    private void StepBitrateDown()
    {
        long now = Environment.TickCount64;
        _lastCongestionTicks = now;
        if (_bitrate <= VideoEncoder.MinBitrate || now - _lastStepTicks < 1000) return;
        _bitrate = Math.Max(_bitrate / 2, VideoEncoder.MinBitrate);
        _lastStepTicks = now;
        _encoder?.SetBitrate(_bitrate);
        SendStreamStatus();
        Log.Line($"port {_port}: congestion — bitrate down to {_bitrate / 1_000_000} Mbps");
    }

    private void MaybeStepBitrateUp()
    {
        if (_bitrate >= VideoEncoder.MaxBitrate) return;
        long now = Environment.TickCount64;
        if (now - _lastCongestionTicks < 5000 || now - _lastStepTicks < 5000) return;
        _bitrate = Math.Min(_bitrate * 5 / 4, VideoEncoder.MaxBitrate);
        _lastStepTicks = now;
        _encoder?.SetBitrate(_bitrate);
        SendStreamStatus();
        Log.Line($"port {_port}: healthy 5s — bitrate up to {_bitrate / 1_000_000} Mbps");
    }
}
