using System.Runtime.InteropServices;
using SharpGen.Runtime;
using Vortice.MediaFoundation;

namespace Clamshell;

// Host-side H.264/HEVC encoder via a Media Foundation Transform (MFT). The Mac
// mirror is VideoEncoder.swift (VideoToolbox). Output is wire-ready AVCC
// ([4-byte BE NAL length][NAL])*, with in-band parameter sets prepended on
// keyframes — exactly what PROTOCOL.md's VIDEO_FRAME specifies.
//
// Encoder preference, mirroring the Mac's hardware-first / HEVC-first order:
//   1. hardware HEVC, 2. hardware H.264, 3. software H.264.
// Hardware detection (EncoderProbe) drives the HELLO_ACK warning bit, NOT
// whether we start — like the Mac, we always start, software if we must.
//
// KNOWN GAP (documented in the report): only the SYNCHRONOUS MFT model is
// driven here. Modern GPU encoder MFTs are async-only; when one is present but
// only available async, we currently fall back to software and report
// SoftwareFallback (the warning bit). Wiring the async event loop
// (METransformNeedInput/HaveOutput) is the upgrade path to real HW encode.
//
// ponytail: bitrate change and keyframe-on-demand are done by rebuilding the
// MFT (a rebuild yields a fresh IDR). Bounded in frequency by the adaptive-
// bitrate throttles and rare client keyframe requests. Upgrade path: ICodecAPI
// (CODECAPI_AVEncCommonMeanBitRate / AVEncVideoForceKeyFrame) for in-place
// changes without a rebuild hitch.
internal sealed class VideoEncoder : IDisposable
{
    public const int MaxBitrate = 20_000_000;
    public const int MinBitrate = 2_000_000;
    private const int Fps = 60;

    public StreamCodec Codec { get; }
    public EncoderStatus Status { get; }
    public Action<bool, ulong, byte[]>? OnFrame;

    private readonly int _width, _height;
    private readonly bool _hardware;
    private IMFTransform _mft = null!;
    private byte[] _paramSetsAvcc = Array.Empty<byte>(); // SPS/PPS(/VPS), AVCC framed
    private int _bitrate = MaxBitrate;
    private bool _rebuild;          // rebuild before next frame (bitrate/keyframe)
    private bool _firstAfterBuild = true;
    private readonly object _lock = new();

    private VideoEncoder(StreamCodec codec, EncoderStatus status, int width, int height, bool hardware)
    {
        Codec = codec; Status = status; _width = width; _height = height; _hardware = hardware;
        Build();
    }

    /// <summary>Picks codec + hardware/software per the preference order and the
    /// startup hardware probe, then builds the MFT.</summary>
    public static VideoEncoder Create(int width, int height, StreamCodec preferred)
    {
        MediaFoundationRuntime.EnsureStarted();
        // Even dimensions required by NV12/H.264.
        width &= ~1; height &= ~1;

        if (EncoderProbe.HardwareEverAvailable)
        {
            var order = preferred == StreamCodec.H264
                ? new[] { StreamCodec.H264, StreamCodec.Hevc }
                : new[] { StreamCodec.Hevc, StreamCodec.H264 };
            foreach (var c in order)
            {
                try { return new VideoEncoder(c, EncoderStatus.HardwareActive, width, height, hardware: true); }
                catch (Exception e) { Log.Line($"hardware {c} encoder unusable ({e.Message})"); }
            }
            // Hardware was advertised but none could be driven -> real fallback.
            Log.Line("*** hardware encoder present but could not be engaged — SOFTWARE fallback (client will warn) ***");
            return new VideoEncoder(StreamCodec.H264, EncoderStatus.SoftwareFallback, width, height, hardware: false);
        }

        // No hardware at all — expected (e.g. no GPU passthrough). Software, no warning.
        return new VideoEncoder(StreamCodec.H264, EncoderStatus.SoftwareExpected, width, height, hardware: false);
    }

    // MARK: - MFT build / rebuild

    private void Build()
    {
        _mft = ActivateEncoder(Codec, _hardware);

        // Encoders: output type MUST be set before input type.
        using (var outType = MediaFactory.MFCreateMediaType())
        {
            outType.Set(MFAttr.MajorType, MFAttr.Video);
            outType.Set(MFAttr.Subtype, Codec == StreamCodec.Hevc ? MFAttr.Hevc : MFAttr.H264);
            outType.Set(MFAttr.AvgBitrate, _bitrate);
            outType.Set(MFAttr.InterlaceMode, 2 /* Progressive */);
            if (Codec == StreamCodec.H264) outType.Set(MFAttr.Mpeg2Profile, 100 /* High */);
            outType.Set(MFAttr.MaxKeyframeSpacing, 120);
            MediaFactory.MFSetAttributeSize(outType, MFAttr.FrameSize, (uint)_width, (uint)_height);
            MediaFactory.MFSetAttributeRatio(outType, MFAttr.FrameRate, Fps, 1);
            MediaFactory.MFSetAttributeRatio(outType, MFAttr.PixelAspectRatio, 1, 1);
            _mft.SetOutputType(0, outType, 0);

            // Cache the codec-private sequence header (SPS/PPS[/VPS]) as AVCC to
            // prepend on keyframes. It comes back as an Annex-B blob.
            _paramSetsAvcc = TryGetSequenceHeaderAvcc(outType);
        }

        using (var inType = MediaFactory.MFCreateMediaType())
        {
            inType.Set(MFAttr.MajorType, MFAttr.Video);
            inType.Set(MFAttr.Subtype, MFAttr.Nv12);
            inType.Set(MFAttr.InterlaceMode, 2);
            MediaFactory.MFSetAttributeSize(inType, MFAttr.FrameSize, (uint)_width, (uint)_height);
            MediaFactory.MFSetAttributeRatio(inType, MFAttr.FrameRate, Fps, 1);
            MediaFactory.MFSetAttributeRatio(inType, MFAttr.PixelAspectRatio, 1, 1);
            _mft.SetInputType(0, inType, 0);
        }

        _mft.ProcessMessage((TMessageType)Mf.NotifyBeginStreaming, UIntPtr.Zero);
        _mft.ProcessMessage((TMessageType)Mf.NotifyStartOfStream, UIntPtr.Zero);
        _firstAfterBuild = true;
    }

    private static IMFTransform ActivateEncoder(StreamCodec codec, bool hardware)
    {
        Guid subtype = codec == StreamCodec.Hevc ? MFAttr.Hevc : MFAttr.H264;
        var outInfo = new RegisterTypeInfo { GuidMajorType = MFAttr.Video, GuidSubtype = subtype };
        int flags = (hardware ? EncoderProbe.MFT_ENUM_FLAG_HARDWARE : MFT_ENUM_FLAG_SYNCMFT)
                    | EncoderProbe.MFT_ENUM_FLAG_SORTANDFILTER;
        IMFActivate[] acts = EncoderProbe.Enumerate(EncoderProbe.VideoEncoderCategory, flags, outInfo);
        if (acts.Length == 0) throw new InvalidOperationException($"no {(hardware ? "hardware" : "software")} {codec} encoder MFT");
        // Async-only hardware MFTs (the common GPU case) will fail SetInputType/
        // ProcessInput below and be caught by Create() -> software fallback. We
        // don't drive the async model yet (see the class header's KNOWN GAP).
        IMFTransform mft = acts[0].ActivateObject<IMFTransform>();
        for (int i = 0; i < acts.Length; i++) acts[i].Dispose();
        return mft;
    }

    private const int MFT_ENUM_FLAG_SYNCMFT = 0x00000001;

    // MARK: - Encode

    /// <summary>Feed one NV12 frame (system memory). Drains all resulting AVCC
    /// frames to OnFrame. ptsMicros is the capture timestamp.</summary>
    public void Feed(byte[] nv12, ulong ptsMicros)
    {
        lock (_lock)
        {
            try
            {
                if (_rebuild)
                {
                    _rebuild = false;
                    RebuildLocked();
                }

                using var sample = MediaFactory.MFCreateSample();
                using var buffer = MediaFactory.MFCreateMemoryBuffer(nv12.Length);
                buffer.Lock(out IntPtr p, out _, out _);
                Marshal.Copy(nv12, 0, p, nv12.Length);
                buffer.Unlock();
                buffer.CurrentLength = nv12.Length;
                sample.AddBuffer(buffer);
                sample.SampleTime = (long)ptsMicros * 10;      // 100ns units
                sample.SampleDuration = 10_000_000 / Fps;

                _mft.ProcessInput(0, sample, 0);
                DrainLocked(ptsMicros);
            }
            catch (Exception e) { Log.Line($"encode error: {e.Message}"); }
        }
    }

    private void DrainLocked(ulong ptsMicros)
    {
        var info = _mft.GetOutputStreamInfo(0);
        bool mftAllocates = ((int)info.Flags & (Mf.ProvidesSamples | Mf.CanProvideSamples)) != 0;

        while (true)
        {
            IMFSample? outSample = null;
            IMFMediaBuffer? outBuffer = null;
            if (!mftAllocates)
            {
                outSample = MediaFactory.MFCreateSample();
                outBuffer = MediaFactory.MFCreateMemoryBuffer(Math.Max((int)info.Size, _width * _height * 2));
                outSample.AddBuffer(outBuffer);
            }

            var dataBuffer = new OutputDataBuffer { StreamID = 0, Sample = outSample! };
            Result r = _mft.ProcessOutput((ProcessOutputFlags)0, 1, ref dataBuffer, out _);

            if ((uint)r.Code == Mf.NeedMoreInput) { outSample?.Dispose(); outBuffer?.Dispose(); break; }
            if ((uint)r.Code == Mf.StreamChange)
            {
                outSample?.Dispose(); outBuffer?.Dispose();
                ReapplyOutputTypeLocked(); // full rebuild (new IDR)
                continue;
            }
            r.CheckError();

            using (var produced = dataBuffer.Sample)
            {
                if (produced != null) EmitLocked(produced, ptsMicros);
            }
            outBuffer?.Dispose();
        }
    }

    private void EmitLocked(IMFSample sample, ulong ptsMicros)
    {
        uint clean = 0;
        try { clean = sample.GetUInt32(MFAttr.CleanPoint); } catch { /* attribute absent */ }
        bool keyframe = _firstAfterBuild || clean != 0;
        _firstAfterBuild = false;

        using var contiguous = sample.ConvertToContiguousBuffer();
        contiguous.Lock(out IntPtr p, out _, out int len);
        byte[] annexB = new byte[len];
        Marshal.Copy(p, annexB, 0, len);
        contiguous.Unlock();

        byte[] avcc = AnnexB.ToAvcc(annexB);
        if (keyframe && _paramSetsAvcc.Length > 0)
        {
            var withParams = new byte[_paramSetsAvcc.Length + avcc.Length];
            Buffer.BlockCopy(_paramSetsAvcc, 0, withParams, 0, _paramSetsAvcc.Length);
            Buffer.BlockCopy(avcc, 0, withParams, _paramSetsAvcc.Length, avcc.Length);
            avcc = withParams;
        }
        OnFrame?.Invoke(keyframe, ptsMicros, avcc);
    }

    private byte[] TryGetSequenceHeaderAvcc(IMFMediaType outType)
    {
        try
        {
            byte[] blob = outType.GetBlob(MFAttr.MpegSequenceHeader);
            return blob.Length == 0 ? Array.Empty<byte>() : AnnexB.ToAvcc(blob);
        }
        catch { return Array.Empty<byte>(); }
    }

    private void ReapplyOutputTypeLocked()
    {
        // Rare; simplest correct handling is a full rebuild (new IDR).
        RebuildLocked();
    }

    private void RebuildLocked()
    {
        try { _mft.ProcessMessage((TMessageType)Mf.NotifyEndOfStream, UIntPtr.Zero); } catch { }
        try { _mft.Dispose(); } catch { }
        Build();
    }

    public void RequestKeyframe() { lock (_lock) _rebuild = true; }

    public void SetBitrate(int bps)
    {
        bps = Math.Clamp(bps, MinBitrate, MaxBitrate);
        lock (_lock) { if (bps != _bitrate) { _bitrate = bps; _rebuild = true; } }
    }

    public void Dispose()
    {
        lock (_lock)
        {
            try { _mft?.ProcessMessage((TMessageType)Mf.NotifyEndOfStream, UIntPtr.Zero); } catch { }
            try { _mft?.Dispose(); } catch { }
            _mft = null!;
        }
    }
}

// Media Foundation attribute/format GUIDs and enum values, as literals so we do
// not depend on Vortice's constant naming. Values are the stable Win32 GUIDs.
internal static class MFAttr
{
    public static readonly Guid MajorType = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    public static readonly Guid Subtype = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    public static readonly Guid AvgBitrate = new("20332624-fb0d-4d9e-bd0d-cbf6786c102e");
    public static readonly Guid FrameSize = new("1652c33d-d6b2-4012-b834-72030849a37d");
    public static readonly Guid FrameRate = new("c459a2e8-3d2c-4e44-b132-fee5156c7bb0");
    public static readonly Guid PixelAspectRatio = new("c6376a1e-8d0a-4027-be45-6d9a0ad39bb6");
    public static readonly Guid InterlaceMode = new("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
    public static readonly Guid Mpeg2Profile = new("ad76a80b-2d5c-4e0b-b375-64e520137036");
    public static readonly Guid MaxKeyframeSpacing = new("c16eb52b-73a1-476f-8d62-839d6a020652");
    public static readonly Guid MpegSequenceHeader = new("3c036de7-3ad0-4c9e-9216-ee6d6ac21cb3");
    public static readonly Guid CleanPoint = new("9cdf01d8-a0f0-43ba-b077-eaa06cbd728a");
    public static readonly Guid TransformAsync = new("f81a699a-649a-497d-8c73-29f8fed6ad7a");

    public static readonly Guid Video = new("73646976-0000-0010-8000-00aa00389b71");
    public static readonly Guid H264 = new("34363248-0000-0010-8000-00aa00389b71");
    public static readonly Guid Hevc = new("43564548-0000-0010-8000-00aa00389b71");
    public static readonly Guid Nv12 = new("3231564e-0000-0010-8000-00aa00389b71");

    // Audio (AAC-LC 48 kHz stereo, raw access units).
    public static readonly Guid Audio = new("73647561-0000-0010-8000-00aa00389b71");
    public static readonly Guid Aac = new("00001610-0000-0010-8000-00aa00389b71");
    public static readonly Guid Pcm = new("00000001-0000-0010-8000-00aa00389b71");
    public static readonly Guid AudioSamplesPerSecond = new("5faeeae7-0290-4c31-9e8a-c534f68d9dba");
    public static readonly Guid AudioNumChannels = new("37e48bf5-645e-4c5b-89de-ada9e29b696a");
    public static readonly Guid AudioBitsPerSample = new("f2deb57f-40fa-4764-aa33-ed4f2d1ff669");
    public static readonly Guid AudioAvgBytesPerSecond = new("1aab75c8-cfef-451c-ab95-ac034b8e1731");
    public static readonly Guid AudioBlockAlignment = new("322de230-9eeb-43bd-ab7a-ff412251541d");
    public static readonly Guid AacPayloadType = new("bfbabe79-7434-4d1c-94f0-72a3b9e17188");
    public static readonly Guid AacProfileLevel = new("7632f0e6-9538-4d61-acda-ea29c8c14456");
}

// Media Foundation numeric constants (MFT messages, non-fatal HRESULTs, output
// stream-info flags) as literals — avoids depending on Vortice enum member names.
internal static class Mf
{
    // MFT_MESSAGE_TYPE
    public const int NotifyBeginStreaming = 0x10000000;
    public const int NotifyEndStreaming = 0x10000001;
    public const int NotifyEndOfStream = 0x10000002;
    public const int NotifyStartOfStream = 0x10000003;
    // Non-fatal ProcessOutput HRESULTs
    public const uint NeedMoreInput = 0xC00D6D72;
    public const uint StreamChange = 0xC00D6D61;
    // MFT_OUTPUT_STREAM_INFO flags
    public const int ProvidesSamples = 0x100;
    public const int CanProvideSamples = 0x200;
}

// Splits an Annex-B byte stream (start-code separated NALs) into AVCC framing
// ([4-byte BE length][NAL])*. Deterministic and testable — see SelfTest.
internal static class AnnexB
{
    public static byte[] ToAvcc(ReadOnlySpan<byte> annexB)
    {
        using var outMs = new MemoryStream(annexB.Length + 8);
        int i = 0, n = annexB.Length;
        int nalStart = -1;
        while (i < n)
        {
            int sc = StartCodeLen(annexB, i);
            if (sc > 0)
            {
                if (nalStart >= 0) WriteNal(outMs, annexB.Slice(nalStart, i - nalStart));
                i += sc;
                nalStart = i;
            }
            else i++;
        }
        if (nalStart >= 0 && nalStart < n) WriteNal(outMs, annexB.Slice(nalStart, n - nalStart));
        return outMs.ToArray();
    }

    // Returns 3 or 4 if a start code (00 00 01 / 00 00 00 01) begins at i, else 0.
    private static int StartCodeLen(ReadOnlySpan<byte> b, int i)
    {
        if (i + 3 <= b.Length && b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1) return 3;
        if (i + 4 <= b.Length && b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 0 && b[i + 3] == 1) return 4;
        return 0;
    }

    private static void WriteNal(Stream s, ReadOnlySpan<byte> nal)
    {
        if (nal.Length == 0) return;
        Span<byte> len = stackalloc byte[4];
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(len, (uint)nal.Length);
        s.Write(len);
        s.Write(nal);
    }
}
