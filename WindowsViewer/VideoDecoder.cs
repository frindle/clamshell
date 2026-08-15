using System.IO;
using System.Runtime.InteropServices;
using SharpGen.Runtime;
using Vortice.MediaFoundation;

namespace Clamshell;

// Client-side H.264/HEVC decoder via a Media Foundation Transform (MFT) --
// the mirror of WindowsServer/VideoEncoder.cs, same architecture (sync MFT,
// literal GUIDs, no CsWinRT/DXVA). Input is the wire's AVCC NAL data
// (PROTOCOL.md "VIDEO_FRAME payload"); output is NV12, converted to BGRA32
// for WPF's WriteableBitmap.
//
// Deliberately uses the built-in *synchronous* decoder MFT (MFT_ENUM_FLAG_SYNCMFT,
// no MFT_ENUM_FLAG_HARDWARE) rather than negotiating a DXVA/hardware-async
// decoder: the sync H.264 decoder MFT ships with every Windows Media
// Foundation install (no extension package needed, unlike HEVC which
// sometimes requires the optional "HEVC Video Extensions"), and it is what
// makes this provable on a GPU-less CI runner. See the report for what was
// and wasn't verified on real hardware.
//
// ponytail: NV12->BGRA conversion is a scalar CPU loop (BT.601), not a GPU
// color-convert DXVA/DMO stage. Fine for a v1 desktop-window viewer; upgrade
// path is the standard Media Foundation Video Processor MFT
// (MFT_CATEGORY_VIDEO_PROCESSOR) or a D3D11 shader if CPU conversion turns
// out to be the bottleneck at high resolution/frame rate.
internal sealed class VideoDecoder : IDisposable
{
    public Action<int, int, byte[]>? OnFrame; // width, height, BGRA32 bytes (top-down, stride = width*4)

    private readonly StreamCodec _codec;
    private IMFTransform _mft = null!;
    private int _outWidth, _outHeight, _outStride;
    private bool _outputTypeSet;
    private readonly object _lock = new();

    public VideoDecoder(StreamCodec codec)
    {
        _codec = codec;
        MediaFoundationRuntime.EnsureStarted();
        Build();
    }

    private void Build()
    {
        _mft = ActivateDecoder(_codec);

        using (var inType = MediaFactory.MFCreateMediaType())
        {
            inType.Set(MFAttr.MajorType, MFAttr.Video);
            inType.Set(MFAttr.Subtype, _codec == StreamCodec.Hevc ? MFAttr.Hevc : MFAttr.H264);
            _mft.SetInputType(0, inType, 0);
        }

        NegotiateOutputTypeLocked();

        _mft.ProcessMessage((TMessageType)Mf.NotifyBeginStreaming, UIntPtr.Zero);
        _mft.ProcessMessage((TMessageType)Mf.NotifyStartOfStream, UIntPtr.Zero);
    }

    /// <summary>Walk GetOutputAvailableType until an NV12 candidate is found and
    /// set it -- the standard MF decoder negotiation pattern (letting the
    /// decoder propose the type, rather than constructing one blind, is what
    /// picks up the real frame size once the bitstream's SPS has been seen).</summary>
    private void NegotiateOutputTypeLocked()
    {
        for (int i = 0; ; i++)
        {
            IMFMediaType candidate;
            try { candidate = _mft.GetOutputAvailableType(0, i); }
            catch { break; } // MF_E_NO_MORE_TYPES or MF_E_TRANSFORM_TYPE_NOT_SET (too early -- fine pre-SPS)
            using (candidate)
            {
                Guid sub = candidate.GetGUID(MFAttr.Subtype);
                if (sub != MFAttr.Nv12) continue;
                _mft.SetOutputType(0, candidate, 0);
                MediaFactory.MFGetAttributeSize(candidate, MFAttr.FrameSize, out uint w, out uint h);
                _outWidth = (int)w; _outHeight = (int)h;
                _outStride = TryGetStride(candidate, (int)w);
                _outputTypeSet = _outWidth > 0 && _outHeight > 0;
                return;
            }
        }
    }

    private static int TryGetStride(IMFMediaType t, int width)
    {
        try { int s = unchecked((int)t.GetUInt32(MFAttr.DefaultStride)); return s > 0 ? s : width; }
        catch { return width; }
    }

    private static IMFTransform ActivateDecoder(StreamCodec codec)
    {
        Guid subtype = codec == StreamCodec.Hevc ? MFAttr.Hevc : MFAttr.H264;
        var inInfo = new RegisterTypeInfo { GuidMajorType = MFAttr.Video, GuidSubtype = subtype };
        // Sync, non-hardware: guaranteed present (H.264) without DXVA/GPU --
        // see class header.
        int flags = MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER;
        IMFActivate[] acts = Enumerate(VideoDecoderCategory, flags, inInfo);
        if (acts.Length == 0) throw new InvalidOperationException($"no software {codec} decoder MFT on this system");
        IMFTransform mft = acts[0].ActivateObject<IMFTransform>();
        foreach (var a in acts) a.Dispose();
        return mft;
    }

    // MFT_CATEGORY_VIDEO_DECODER
    private static readonly Guid VideoDecoderCategory = new("d6c02d4b-6833-45b4-971a-05a4b04bab91");
    private const int MFT_ENUM_FLAG_SYNCMFT = 0x00000001;
    private const int MFT_ENUM_FLAG_SORTANDFILTER = 0x00000040;

    private static IMFActivate[] Enumerate(Guid category, int flags, RegisterTypeInfo? inputType)
    {
        MediaFactory.MFTEnumEx(category, (uint)flags, inputType, null, out nint pActs, out uint count);
        var result = new IMFActivate[count];
        for (int i = 0; i < count; i++)
            result[i] = new IMFActivate(Marshal.ReadIntPtr(pActs, i * IntPtr.Size));
        if (pActs != IntPtr.Zero) Marshal.FreeCoTaskMem(pActs);
        return result;
    }

    /// <summary>Feed one VIDEO_FRAME's AVCC NAL payload (already includes
    /// in-band SPS/PPS on keyframes, per PROTOCOL.md). Converted to Annex-B,
    /// the byte stream the built-in decoder MFT expects.</summary>
    public void Feed(ReadOnlySpan<byte> avccNal, ulong ptsMicros) => FeedAnnexB(Avcc.ToAnnexB(avccNal), ptsMicros);

    /// <summary>Feed one already-Annex-B access unit directly -- used by the
    /// `decode-file` CI verification path (see Program.cs), which decodes a
    /// real file produced by an independent, known-good encoder (ffmpeg)
    /// rather than one that came off the wire. Same underlying decode path
    /// as <see cref="Feed"/>, just skipping the AVCC-&gt;Annex-B step because
    /// the input is already Annex-B.</summary>
    public void FeedAnnexB(ReadOnlySpan<byte> annexB, ulong ptsMicros)
    {
        lock (_lock)
        {
            try
            {
                if (annexB.Length == 0) return;

                using var sample = MediaFactory.MFCreateSample();
                using var buffer = MediaFactory.MFCreateMemoryBuffer(annexB.Length);
                buffer.Lock(out IntPtr p, out _, out _);
                Marshal.Copy(annexB.ToArray(), 0, p, annexB.Length);
                buffer.Unlock();
                buffer.CurrentLength = annexB.Length;
                sample.AddBuffer(buffer);
                sample.SampleTime = (long)ptsMicros * 10;

                _mft.ProcessInput(0, sample, 0);
                DrainLocked();
            }
            catch (Exception e) { Log.Line($"decode error: {e.Message}"); }
        }
    }

    private void DrainLocked()
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
                outBuffer = MediaFactory.MFCreateMemoryBuffer(Math.Max((int)info.Size, _outWidth * _outHeight * 3 / 2 + 4096));
                outSample.AddBuffer(outBuffer);
            }

            var dataBuffer = new OutputDataBuffer { StreamID = 0, Sample = outSample! };
            Result r = _mft.ProcessOutput((ProcessOutputFlags)0, 1, ref dataBuffer, out _);

            if ((uint)r.Code == Mf.NeedMoreInput) { outSample?.Dispose(); outBuffer?.Dispose(); break; }
            if ((uint)r.Code == Mf.StreamChange)
            {
                outSample?.Dispose(); outBuffer?.Dispose();
                NegotiateOutputTypeLocked();
                continue;
            }
            r.CheckError();

            using (var produced = dataBuffer.Sample)
            {
                if (produced != null && _outputTypeSet) EmitLocked(produced);
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
            byte[] bgra = Nv12ToBgra(p, len, _outWidth, _outHeight, _outStride);
            OnFrame?.Invoke(_outWidth, _outHeight, bgra);
        }
        finally { contiguous.Unlock(); }
    }

    private static unsafe byte[] Nv12ToBgra(IntPtr nv12, int len, int width, int height, int stride)
    {
        var bgra = new byte[width * height * 4];
        byte* y = (byte*)nv12;
        byte* uv = y + (long)stride * height;
        long uvSize = len - (long)stride * height;
        if (uvSize < stride * (height / 2) || width <= 0 || height <= 0) return bgra; // truncated buffer -- skip, leave black

        fixed (byte* outP = bgra)
        {
            for (int row = 0; row < height; row++)
            {
                byte* yRow = y + (long)row * stride;
                byte* uvRow = uv + (long)(row / 2) * stride;
                byte* outRow = outP + (long)row * width * 4;
                for (int col = 0; col < width; col++)
                {
                    int Y = yRow[col];
                    int U = uvRow[(col / 2) * 2];
                    int V = uvRow[(col / 2) * 2 + 1];
                    int c = Y - 16, d = U - 128, e = V - 128;
                    int R = (298 * c + 409 * e + 128) >> 8;
                    int G = (298 * c - 100 * d - 208 * e + 128) >> 8;
                    int B = (298 * c + 516 * d + 128) >> 8;
                    byte* px = outRow + col * 4;
                    px[0] = Clamp(B); px[1] = Clamp(G); px[2] = Clamp(R); px[3] = 255;
                }
            }
        }
        return bgra;
    }

    private static byte Clamp(int v) => (byte)(v < 0 ? 0 : v > 255 ? 255 : v);

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

// Media Foundation GUIDs/constants shared with the encoder side, duplicated
// here (not referenced cross-project) for the same independence reason as
// Protocol.cs -- see that file's header.
internal static class MFAttr
{
    public static readonly Guid MajorType = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    public static readonly Guid Subtype = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    public static readonly Guid FrameSize = new("1652c33d-d6b2-4012-b834-72030849a37d");
    public static readonly Guid DefaultStride = new("644b4e48-1e02-4516-b0eb-c01ca9d49ac6");

    public static readonly Guid Video = new("73646976-0000-0010-8000-00aa00389b71");
    public static readonly Guid H264 = new("34363248-0000-0010-8000-00aa00389b71");
    public static readonly Guid Hevc = new("43564548-0000-0010-8000-00aa00389b71");
    public static readonly Guid Nv12 = new("3231564e-0000-0010-8000-00aa00389b71");
}

internal static class Mf
{
    public const int NotifyBeginStreaming = 0x10000000;
    public const int NotifyEndOfStream = 0x10000002;
    public const int NotifyStartOfStream = 0x10000003;
    public const uint NeedMoreInput = 0xC00D6D72;
    public const uint StreamChange = 0xC00D6D61;
    // MFT_OUTPUT_STREAM_INFO flags
    public const int ProvidesSamples = 0x100;
    public const int CanProvideSamples = 0x200;
}

// Inverse of WindowsServer/VideoEncoder.cs's AnnexB.ToAvcc: length-prefixed
// AVCC NALs -> a single Annex-B byte stream (4-byte start codes), what the
// built-in decoder MFT expects on its input samples.
internal static class Avcc
{
    public static byte[] ToAnnexB(ReadOnlySpan<byte> avcc)
    {
        using var outMs = new MemoryStream(avcc.Length + 16);
        int i = 0, n = avcc.Length;
        Span<byte> startCode = stackalloc byte[4] { 0, 0, 0, 1 };
        while (i + 4 <= n)
        {
            uint nalLen = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(avcc.Slice(i, 4));
            i += 4;
            if (nalLen == 0 || i + nalLen > n) break; // malformed -- stop rather than throw
            outMs.Write(startCode);
            outMs.Write(avcc.Slice(i, (int)nalLen));
            i += (int)nalLen;
        }
        return outMs.ToArray();
    }
}

// One-time Media Foundation startup for the process -- mirrors
// WindowsServer/EncoderProbe.cs's MediaFoundationRuntime.
internal static class MediaFoundationRuntime
{
    private static bool _started;
    private static readonly object Gate = new();

    public static void EnsureStarted()
    {
        lock (Gate)
        {
            if (_started) return;
            MediaFactory.MFStartup();
            _started = true;
        }
    }
}
