using System.Runtime.InteropServices;
using SharpGen.Runtime;
using Vortice.MediaFoundation;

namespace Clamshell;

// AAC-LC decoder for AUDIO_FRAME (PROTOCOL.md "Audio (AUDIO_FRAME)"): each
// message is one raw access unit of 48 kHz stereo AAC-LC, no ADTS header and no
// magic cookie. The built-in Media Foundation AAC decoder MFT turns it into
// 16-bit 48 kHz stereo PCM. Same shape as VideoDecoder: a synchronous MFT, GUIDs
// written out as literals, no codec install needed on Windows.
//
// Raw access units need the decoder told what they are: payload type 0 (raw)
// and a user-data blob holding the HEAACWAVEINFO fields that follow the
// WAVEFORMATEX, then the AudioSpecificConfig. For AAC-LC 48 kHz stereo that is
// 0x11 0x90 (object type 2, rate index 3, channel configuration 2).
internal sealed class AudioDecoder : IDisposable
{
    public const int SampleRate = 48000;
    public const int Channels = 2;
    /// <summary>Bytes of one PCM frame: 2 channels of 16 bits.</summary>
    public const int BytesPerFrame = 4;
    /// <summary>PCM frames one AAC access unit decodes to.</summary>
    public const int FramesPerUnit = 1024;

    /// <summary>Called with interleaved 16-bit little-endian PCM, 48 kHz stereo.</summary>
    public Action<byte[]>? OnPcm;

    private IMFTransform? _mft;
    private readonly object _lock = new();
    private long _time; // 100 ns units
    private int _errors;
    private readonly RenegotiationCap _cap = new();
    private bool _off;

    public AudioDecoder()
    {
        MediaFoundationRuntime.EnsureStarted();
        Build();
    }

    private void Build()
    {
        var inInfo = new RegisterTypeInfo { GuidMajorType = AudioAttr.Audio, GuidSubtype = AudioAttr.Aac };
        int flags = AudioAttr.EnumFlagSyncMft | AudioAttr.EnumFlagSortAndFilter;
        IMFActivate[] acts = VideoDecoder.Enumerate(AudioAttr.AudioDecoderCategory, flags, inInfo);
        if (acts.Length == 0) throw new InvalidOperationException("no AAC decoder MFT on this system");
        _mft = acts[0].ActivateObject<IMFTransform>();
        foreach (var a in acts) a.Dispose();

        using (var inType = MediaFactory.MFCreateMediaType())
        {
            inType.Set(MFAttr.MajorType, AudioAttr.Audio);
            inType.Set(MFAttr.Subtype, AudioAttr.Aac);
            inType.Set(AudioAttr.SamplesPerSecond, SampleRate);
            inType.Set(AudioAttr.NumChannels, Channels);
            inType.Set(AudioAttr.BitsPerSample, 16);
            inType.Set(AudioAttr.AacPayloadType, 0);        // raw access units, no ADTS
            inType.Set(AudioAttr.AacProfileLevel, 0x29);    // AAC-LC L2
            inType.SetBlob(AudioAttr.UserData, UserData);
            _mft.SetInputType(0, inType, 0);
        }
        NegotiateOutput();

        _mft.ProcessMessage((TMessageType)Mf.NotifyBeginStreaming, UIntPtr.Zero);
        _mft.ProcessMessage((TMessageType)Mf.NotifyStartOfStream, UIntPtr.Zero);
    }

    /// <summary>MF_MT_USER_DATA: the HEAACWAVEINFO fields after the WAVEFORMATEX
    /// (wPayloadType 0, wAudioProfileLevelIndication 0x29, wStructType 0,
    /// wReserved1 0, dwReserved2 0), then the AudioSpecificConfig.</summary>
    internal static readonly byte[] UserData =
    {
        0x00, 0x00,             // wPayloadType: raw
        0x29, 0x00,             // wAudioProfileLevelIndication: AAC-LC L2
        0x00, 0x00,             // wStructType: HEAACWAVEINFO
        0x00, 0x00,             // wReserved1
        0x00, 0x00, 0x00, 0x00, // dwReserved2
        0x11, 0x90,             // AudioSpecificConfig: AAC-LC, 48 kHz, stereo
    };

    /// <summary>Picks the decoder's 16-bit 48 kHz stereo PCM output; builds that
    /// type by hand if the decoder lists none that matches.</summary>
    private void NegotiateOutput()
    {
        for (int i = 0; ; i++)
        {
            IMFMediaType candidate;
            try { candidate = _mft!.GetOutputAvailableType(0, i); }
            catch { break; }
            using (candidate)
            {
                if (candidate.GetGUID(MFAttr.Subtype) != AudioAttr.Pcm) continue;
                if (Number(candidate, AudioAttr.BitsPerSample) != 16) continue;
                if (Number(candidate, AudioAttr.SamplesPerSecond) != SampleRate) continue;
                if (Number(candidate, AudioAttr.NumChannels) != Channels) continue;
                _mft!.SetOutputType(0, candidate, 0);
                return;
            }
        }
        using var t = MediaFactory.MFCreateMediaType();
        t.Set(MFAttr.MajorType, AudioAttr.Audio);
        t.Set(MFAttr.Subtype, AudioAttr.Pcm);
        t.Set(AudioAttr.SamplesPerSecond, SampleRate);
        t.Set(AudioAttr.NumChannels, Channels);
        t.Set(AudioAttr.BitsPerSample, 16);
        t.Set(AudioAttr.BlockAlignment, BytesPerFrame);
        t.Set(AudioAttr.AvgBytesPerSecond, SampleRate * BytesPerFrame);
        _mft!.SetOutputType(0, t, 0);
    }

    private static uint Number(IMFMediaType t, Guid key)
    {
        try { return t.GetUInt32(key); }
        catch { return 0; }
    }

    /// <summary>Decodes one raw AAC access unit. Never throws: a bad unit is
    /// logged (the first few, then now and then) and dropped.</summary>
    public void Feed(ReadOnlySpan<byte> aac)
    {
        if (aac.IsEmpty) return; // an empty AUDIO_FRAME carries nothing to decode
        lock (_lock)
        {
            if (_mft is null || _off) return;
            try
            {
                using var sample = MediaFactory.MFCreateSample();
                using var buffer = MediaFactory.MFCreateMemoryBuffer(aac.Length);
                buffer.Lock(out IntPtr p, out _, out _);
                Marshal.Copy(aac.ToArray(), 0, p, aac.Length);
                buffer.Unlock();
                buffer.CurrentLength = aac.Length;
                sample.AddBuffer(buffer);
                sample.SampleTime = _time;
                _time += 10_000_000L * FramesPerUnit / SampleRate;

                _mft.ProcessInput(0, sample, 0);
                _cap.StartFeed();
                if (DrainLocked()) _cap.FeedWorked();
                else if (_cap.DroppedUnit())
                {
                    _off = true;
                    Log.Line("audio: the decoder keeps changing its output format; audio is off for the rest of this session");
                }
            }
            catch (Exception e)
            {
                _errors++;
                if (_errors <= 5 || _errors % 500 == 0) Log.Line($"audio: AAC decode error #{_errors}: {e.Message}");
            }
        }
    }

    /// <summary>Forces out what the decoder still holds. For a one-shot file
    /// decode only: it ends the stream, so a live session never calls it.</summary>
    public void Flush()
    {
        lock (_lock)
        {
            if (_mft is null) return;
            try
            {
                _mft.ProcessMessage((TMessageType)Mf.CommandDrain, UIntPtr.Zero);
                _cap.StartFeed();
                DrainLocked();
            }
            catch (Exception e) { Log.Line($"audio: decode flush error: {e.Message}"); }
        }
    }

    /// <summary>Takes out what the decoder has. False when it asked for a new
    /// output format more often than <see cref="RenegotiationCap.MaxPerFeed"/>
    /// in one go: the rest of this unit is dropped.</summary>
    private bool DrainLocked()
    {
        var info = _mft!.GetOutputStreamInfo(0);
        bool mftAllocates = ((int)info.Flags & (Mf.ProvidesSamples | Mf.CanProvideSamples)) != 0;

        while (true)
        {
            IMFSample? outSample = null;
            IMFMediaBuffer? outBuffer = null;
            if (!mftAllocates)
            {
                outSample = MediaFactory.MFCreateSample();
                outBuffer = MediaFactory.MFCreateMemoryBuffer(Math.Max((int)info.Size, 16384));
                outSample.AddBuffer(outBuffer);
            }

            var dataBuffer = new OutputDataBuffer { StreamID = 0, Sample = outSample! };
            Result r = _mft.ProcessOutput((ProcessOutputFlags)0, 1, ref dataBuffer, out _);

            if ((uint)r.Code == Mf.NeedMoreInput) { outSample?.Dispose(); outBuffer?.Dispose(); return true; }
            if ((uint)r.Code == Mf.StreamChange)
            {
                outSample?.Dispose(); outBuffer?.Dispose();
                if (!_cap.Allow()) return false;
                NegotiateOutput();
                continue;
            }
            r.CheckError();

            using (var produced = dataBuffer.Sample)
            {
                if (produced != null) EmitLocked(produced);
            }
            outBuffer?.Dispose();
        }
    }

    private void EmitLocked(IMFSample sample)
    {
        using var contiguous = sample.ConvertToContiguousBuffer();
        contiguous.Lock(out IntPtr p, out _, out int len);
        try
        {
            if (len <= 0) return;
            var pcm = new byte[len];
            Marshal.Copy(p, pcm, 0, len);
            OnPcm?.Invoke(pcm);
        }
        finally { contiguous.Unlock(); }
    }

    public void Dispose()
    {
        lock (_lock)
        {
            try { _mft?.ProcessMessage((TMessageType)Mf.NotifyEndOfStream, UIntPtr.Zero); } catch { }
            try { _mft?.Dispose(); } catch { }
            _mft = null;
        }
    }
}

/// <summary>A decoder that asks for a new output format again and again would
/// keep one Feed in its loop for good. Counts the asks inside one Feed and how
/// many units in a row were dropped for it. Used by the audio and video decoders;
/// it holds no Media Foundation state, so the self-test can drive it.</summary>
internal sealed class RenegotiationCap
{
    /// <summary>Format changes accepted while draining one unit.</summary>
    public const int MaxPerFeed = 4;
    /// <summary>Units dropped in a row before a decoder gives up.</summary>
    public const int DroppedUnitsBeforeGivingUp = 3;

    private int _inThisFeed;
    private int _droppedInARow;

    public void StartFeed() => _inThisFeed = 0;

    /// <summary>True if one more change may be negotiated for this unit.</summary>
    public bool Allow() => ++_inThisFeed <= MaxPerFeed;

    /// <summary>A unit was dropped. True once that has happened often enough in a row to give up.</summary>
    public bool DroppedUnit() => ++_droppedInARow >= DroppedUnitsBeforeGivingUp;

    /// <summary>A unit drained without hitting the cap.</summary>
    public void FeedWorked() => _droppedInARow = 0;
}

// Media Foundation audio GUIDs, as literals like the video ones in VideoDecoder.cs.
internal static class AudioAttr
{
    public static readonly Guid Audio = new("73647561-0000-0010-8000-00aa00389b71");
    public static readonly Guid Aac = new("00001610-0000-0010-8000-00aa00389b71");
    public static readonly Guid Pcm = new("00000001-0000-0010-8000-00aa00389b71");
    public static readonly Guid SamplesPerSecond = new("5faeeae7-0290-4c31-9e8a-c534f68d9dba");
    public static readonly Guid NumChannels = new("37e48bf5-645e-4c5b-89de-ada9e29b696a");
    public static readonly Guid BitsPerSample = new("f2deb57f-40fa-4764-aa33-ed4f2d1ff669");
    public static readonly Guid AvgBytesPerSecond = new("1aab75c8-cfef-451c-ab95-ac034b8e1731");
    public static readonly Guid BlockAlignment = new("322de230-9eeb-43bd-ab7a-ff412251541d");
    public static readonly Guid AacPayloadType = new("bfbabe79-7434-4d1c-94f0-72a3b9e17188");
    public static readonly Guid AacProfileLevel = new("7632f0e6-9538-4d61-acda-ea29c8c14456");
    public static readonly Guid UserData = new("b6bc765f-4c3b-40a4-bd51-2535b66fe09d");

    // MFT_CATEGORY_AUDIO_DECODER
    public static readonly Guid AudioDecoderCategory = new("9ea73fb4-ef7a-4559-8d5d-719d8f0426c7");
    public const int EnumFlagSyncMft = 0x00000001;
    public const int EnumFlagSortAndFilter = 0x00000040;
}
