using NAudio.Wave;

namespace Clamshell;

// Plays the AUDIO_FRAME stream: AAC-LC access units in, through AudioDecoder,
// into a BufferedWaveProvider that a WaveOutEvent plays. The iOS player
// (AudioPlayer.swift) schedules every packet as it comes; this one also keeps
// the delay down, because a film's sound that lags the picture by seconds is
// useless:
//   - playback starts once about 80 ms is queued;
//   - when more than 250 ms has queued, new audio is dropped until the queue
//     is down to 100 ms again.
// Audio never stops video: if the decoder or the sound device cannot be set up,
// TryCreate logs it once and returns null, and the session goes on without sound.
internal sealed class AudioPlayer : IDisposable
{
    private readonly AudioDecoder _decoder;
    private readonly BufferedWaveProvider _queue;
    private readonly WaveOutEvent _out;
    private readonly AudioPacing _pacing = new();
    private bool _playing;
    private volatile bool _disposed;
    private int _dropped;

    /// <summary>A player, or null (after one log line) when sound cannot start.</summary>
    public static AudioPlayer? TryCreate()
    {
        try { return new AudioPlayer(); }
        catch (Exception e)
        {
            Log.Line($"audio: cannot start ({e.Message}); this session has no sound");
            return null;
        }
    }

    private AudioPlayer()
    {
        _decoder = new AudioDecoder();
        try
        {
            _queue = new BufferedWaveProvider(new WaveFormat(AudioDecoder.SampleRate, 16, AudioDecoder.Channels))
            {
                BufferDuration = TimeSpan.FromMilliseconds(1000),
                DiscardOnBufferOverflow = true,
            };
            _out = new WaveOutEvent { DesiredLatency = 100 };
            _out.Init(_queue);
        }
        catch
        {
            _decoder.Dispose();
            throw;
        }
        _decoder.OnPcm = OnPcm;
        Log.Line("audio: ready (AAC-LC 48 kHz stereo -> WaveOutEvent)");
    }

    /// <summary>One AUDIO_FRAME payload (a raw AAC access unit).</summary>
    public void Play(ReadOnlySpan<byte> aac)
    {
        if (_disposed) return;
        _decoder.Feed(aac);
    }

    private void OnPcm(byte[] pcm)
    {
        if (_disposed) return;
        double queuedMs = _queue.BufferedDuration.TotalMilliseconds;
        if (_pacing.Offer(queuedMs) == AudioPacing.Verdict.Drop)
        {
            _dropped++;
            if (_dropped == 1 || _dropped % 200 == 0)
                Log.Line($"audio: {queuedMs:F0} ms queued, dropping audio to catch up (#{_dropped})");
            return;
        }
        _queue.AddSamples(pcm, 0, pcm.Length);
        if (!_playing && _pacing.ShouldStart(_queue.BufferedDuration.TotalMilliseconds))
        {
            try { _out.Play(); _playing = true; }
            catch (Exception e) { Log.Line($"audio: play failed ({e.Message})"); _disposed = true; }
        }
    }

    public void Dispose()
    {
        _disposed = true;
        try { _out.Stop(); } catch { }
        try { _out.Dispose(); } catch { }
        _decoder.Dispose();
    }
}

/// <summary>The latency rules, apart from any sound device so a self-test can
/// check them.</summary>
internal sealed class AudioPacing
{
    public const double StartMs = 80;
    public const double CatchUpMs = 250;
    public const double ResumeMs = 100;

    public enum Verdict { Queue, Drop }

    private bool _dropping;

    /// <summary>What to do with a packet that arrives when `queuedMs` of audio is
    /// already waiting.</summary>
    public Verdict Offer(double queuedMs)
    {
        if (_dropping) { if (queuedMs <= ResumeMs) _dropping = false; }
        else if (queuedMs > CatchUpMs) _dropping = true;
        return _dropping ? Verdict.Drop : Verdict.Queue;
    }

    /// <summary>True once enough is queued to start playing.</summary>
    public bool ShouldStart(double queuedMs) => queuedMs >= StartMs;
}
