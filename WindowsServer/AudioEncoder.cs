using System.Runtime.InteropServices;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using SharpGen.Runtime;
using Vortice.MediaFoundation;

namespace Clamshell;

// System-audio capture (WASAPI loopback via NAudio) -> AAC-LC 48 kHz stereo raw
// access units (Media Foundation AAC encoder MFT) -> one AUDIO_FRAME per packet.
// The Mac mirror is AudioEncoder.swift. Format is fixed on both ends, so no
// magic cookie / ADTS crosses the wire (payload type = raw AAC). Primary
// display only.
//
// ponytail: fixed 48 kHz stereo, matching the protocol and the iOS decoder.
// NAudio resamples whatever the loopback mix format is up to that.
internal sealed class AudioEncoder : IDisposable
{
    public Action<byte[]>? OnPacket;

    private readonly WasapiLoopbackCapture _cap = new();
    private readonly BufferedWaveProvider _buffer;
    private readonly IWaveProvider _pcm48kStereo16;
    private readonly byte[] _readChunk = new byte[4096]; // 1024 frames * 2ch * 2 bytes
    private IMFTransform _aac = null!;
    private readonly object _lock = new();

    public AudioEncoder()
    {
        MediaFoundationRuntime.EnsureStarted();
        _buffer = new BufferedWaveProvider(_cap.WaveFormat)
        {
            DiscardOnBufferOverflow = true,
            BufferDuration = TimeSpan.FromSeconds(2),
        };
        // Force 48 kHz / stereo / 16-bit PCM regardless of the mix format.
        ISampleProvider sp = _buffer.ToSampleProvider();
        if (sp.WaveFormat.Channels == 1) sp = new MonoToStereoSampleProvider(sp);
        if (sp.WaveFormat.SampleRate != 48000) sp = new WdlResamplingSampleProvider(sp, 48000);
        _pcm48kStereo16 = new SampleToWaveProvider16(sp);

        BuildAacMft();
        _cap.DataAvailable += OnData;
    }

    public void Start()
    {
        try { _cap.StartRecording(); }
        catch (Exception e) { Log.Line($"audio: loopback capture failed to start ({e.Message}) — no audio"); }
    }

    private void OnData(object? sender, WaveInEventArgs e)
    {
        _buffer.AddSamples(e.Buffer, 0, e.BytesRecorded);
        int read;
        while ((read = _pcm48kStereo16.Read(_readChunk, 0, _readChunk.Length)) > 0)
        {
            FeedPcm(_readChunk, read);
            if (read < _readChunk.Length) break; // drained what's buffered
        }
    }

    private void FeedPcm(byte[] pcm, int len)
    {
        lock (_lock)
        {
            try
            {
                using var sample = MediaFactory.MFCreateSample();
                using var buffer = MediaFactory.MFCreateMemoryBuffer(len);
                buffer.Lock(out IntPtr p, out _, out _);
                Marshal.Copy(pcm, 0, p, len);
                buffer.Unlock();
                buffer.CurrentLength = len;
                sample.AddBuffer(buffer);
                _aac.ProcessInput(0, sample, 0);
                Drain();
            }
            catch (Exception ex) { Log.Line($"audio encode error: {ex.Message}"); }
        }
    }

    private void Drain()
    {
        var info = _aac.GetOutputStreamInfo(0);
        bool mftAllocates = ((int)info.Flags & (Mf.ProvidesSamples | Mf.CanProvideSamples)) != 0;
        while (true)
        {
            IMFSample? outSample = null;
            IMFMediaBuffer? outBuffer = null;
            if (!mftAllocates)
            {
                outSample = MediaFactory.MFCreateSample();
                outBuffer = MediaFactory.MFCreateMemoryBuffer(Math.Max((int)info.Size, 4096));
                outSample.AddBuffer(outBuffer);
            }
            var db = new OutputDataBuffer { StreamID = 0, Sample = outSample! };
            Result r = _aac.ProcessOutput((ProcessOutputFlags)0, 1, ref db, out _);
            if ((uint)r.Code == Mf.NeedMoreInput) { outSample?.Dispose(); outBuffer?.Dispose(); break; }
            r.CheckError();

            using (var produced = db.Sample)
            using (var contiguous = produced!.ConvertToContiguousBuffer())
            {
                contiguous.Lock(out IntPtr pp, out _, out int cl);
                var packet = new byte[cl];
                Marshal.Copy(pp, packet, 0, cl);
                contiguous.Unlock();
                if (cl > 0) OnPacket?.Invoke(packet);
            }
            outBuffer?.Dispose();
        }
    }

    private void BuildAacMft()
    {
        Guid audioEncoderCategory = new("91c64bd0-f91e-4d8c-9276-db248279d975");
        var outInfo = new RegisterTypeInfo { GuidMajorType = MFAttr.Audio, GuidSubtype = MFAttr.Aac };
        IMFActivate[] acts = EncoderProbe.Enumerate(audioEncoderCategory,
            EncoderProbe.MFT_ENUM_FLAG_SORTANDFILTER, outInfo);
        if (acts.Length == 0) throw new InvalidOperationException("no AAC encoder MFT");
        _aac = acts[0].ActivateObject<IMFTransform>();
        foreach (var a in acts) a.Dispose();

        using (var outType = MediaFactory.MFCreateMediaType())
        {
            outType.Set(MFAttr.MajorType, MFAttr.Audio);
            outType.Set(MFAttr.Subtype, MFAttr.Aac);
            outType.Set(MFAttr.AudioSamplesPerSecond, 48000);
            outType.Set(MFAttr.AudioNumChannels, 2);
            outType.Set(MFAttr.AudioBitsPerSample, 16);
            outType.Set(MFAttr.AudioAvgBytesPerSecond, 16000); // 128 kbps
            outType.Set(MFAttr.AacPayloadType, 0);             // raw AAC, no ADTS
            outType.Set(MFAttr.AacProfileLevel, 0x29);         // AAC-LC L2
            _aac.SetOutputType(0, outType, 0);
        }
        using (var inType = MediaFactory.MFCreateMediaType())
        {
            inType.Set(MFAttr.MajorType, MFAttr.Audio);
            inType.Set(MFAttr.Subtype, MFAttr.Pcm);
            inType.Set(MFAttr.AudioSamplesPerSecond, 48000);
            inType.Set(MFAttr.AudioNumChannels, 2);
            inType.Set(MFAttr.AudioBitsPerSample, 16);
            inType.Set(MFAttr.AudioBlockAlignment, 4);
            inType.Set(MFAttr.AudioAvgBytesPerSecond, 48000 * 4);
            _aac.SetInputType(0, inType, 0);
        }
        _aac.ProcessMessage((TMessageType)Mf.NotifyBeginStreaming, UIntPtr.Zero);
        _aac.ProcessMessage((TMessageType)Mf.NotifyStartOfStream, UIntPtr.Zero);
    }

    public void Dispose()
    {
        try { _cap.StopRecording(); } catch { }
        try { _cap.Dispose(); } catch { }
        lock (_lock) { try { _aac?.Dispose(); } catch { } _aac = null!; }
    }
}
