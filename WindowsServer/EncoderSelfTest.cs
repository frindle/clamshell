using System.Runtime.InteropServices;
using SharpGen.Runtime;
using Vortice.MediaFoundation;

namespace Clamshell;

// `ClamshellServer selftest-encoder`: builds the video encoder exactly the way a
// session does (VideoEncoder.Create), feeds it synthetic NV12 frames and requires
// real AVCC output with a keyframe first. Needs no display and no client.
//
// If that fails, it then builds the software H.264 MFT directly in a handful of
// variants and prints which step of which variant succeeds or fails and with what
// HRESULT, so a failure in CI says why instead of just failing.
internal static class EncoderSelfTest
{
    public static int Run()
    {
        EncoderProbe.Run();
        var displays = DisplayEnum.Active();
        foreach (var d in displays) Console.Error.WriteLine($"encoder-selftest: display {d.Index} {d.Bounds.Width}x{d.Bounds.Height}");
        int w = displays.Count > 0 ? displays[0].Bounds.Width : 1280;
        int h = displays.Count > 0 ? displays[0].Bounds.Height : 720;

        int rc = 0;
        if (!Session(w, h, "primary display size")) rc = 1;
        if (!Session(1280, 720, "1280x720")) rc = 1;
        if (rc != 0)
        {
            Console.Error.WriteLine("encoder-selftest: FAILED, running the variant matrix for the log");
            Matrix(w, h);
        }
        Console.Error.WriteLine(rc == 0 ? "encoder-selftest: PASS" : "encoder-selftest: FAIL");
        return rc;
    }

    private static bool Session(int w, int h, string label)
    {
        try
        {
            using var enc = VideoEncoder.Create(w, h, StreamCodec.H264);
            int frames = 0, keys = 0;
            bool firstWasKey = false;
            bool paramSetsOnKey = true;
            enc.OnFrame = (key, _, avcc) =>
            {
                if (frames == 0) firstWasKey = key;
                frames++;
                if (key)
                {
                    keys++;
                    // AVCC: first NAL of a keyframe is SPS (type 7) when parameter sets are prepended.
                    if (avcc.Length < 5 || (avcc[4] & 0x1F) != 7) paramSetsOnKey = false;
                }
            };
            int ew = w & ~1, eh = h & ~1;
            var nv12 = new byte[ew * eh * 3 / 2];
            for (int i = 0; i < 90; i++)
            {
                for (int y = 0; y < eh; y++)
                    Array.Fill(nv12, (byte)((y + i * 3) & 0xFF), y * ew, ew);
                Array.Fill(nv12, (byte)128, ew * eh, nv12.Length - ew * eh);
                enc.Feed(nv12, (ulong)i * 16_667UL);
            }
            Console.Error.WriteLine($"encoder-selftest [{label}]: codec {enc.Codec}, status {enc.Status}, {frames} frames, {keys} keyframes");
            if (frames == 0) { Console.Error.WriteLine($"encoder-selftest [{label}]: no frames came out"); return false; }
            if (!firstWasKey) { Console.Error.WriteLine($"encoder-selftest [{label}]: first frame was not a keyframe"); return false; }
            if (!paramSetsOnKey) { Console.Error.WriteLine($"encoder-selftest [{label}]: a keyframe did not start with SPS"); return false; }
            return true;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"encoder-selftest [{label}]: could not build the encoder: {Describe(e)}{Environment.NewLine}{e.StackTrace}");
            return false;
        }
    }

    // MARK: - Variant matrix (diagnostic output only)

    private static void Matrix(int w, int h)
    {
        try
        {
            MediaFoundationRuntime.EnsureStarted();
            var outInfo = new RegisterTypeInfo { GuidMajorType = MFAttr.Video, GuidSubtype = MFAttr.H264 };
            foreach (var (label, flags) in new[] { ("sync", 0x1 | EncoderProbe.MFT_ENUM_FLAG_SORTANDFILTER), ("any", EncoderProbe.MFT_ENUM_FLAG_SORTANDFILTER) })
            {
                var acts = EncoderProbe.Enumerate(EncoderProbe.VideoEncoderCategory, flags, outInfo);
                Console.Error.WriteLine($"encoder-selftest matrix: enumerate {label}: {acts.Length} H.264 encoder MFT(s)");
                foreach (var a in acts)
                {
                    try { Console.Error.WriteLine($"  name: {a.GetString(new Guid("314ffbae-5b41-4c95-9c19-4e7d586face3"))}"); }
                    catch (Exception e) { Console.Error.WriteLine($"  name unavailable: {Describe(e)}"); }
                    a.Dispose();
                }
            }

            int ew = w & ~1, eh = h & ~1;
            foreach (var size in new[] { (ew, eh), (1280, 720), (1024, 768), (640, 480), (1920, 1088) })
            foreach (bool profile in new[] { true, false })
            foreach (bool spacing in new[] { true, false })
            foreach (bool aspect in new[] { true, false })
            foreach (bool inputFirst in new[] { false, true })
                Variant(size.Item1, size.Item2, profile, spacing, aspect, inputFirst);
        }
        catch (Exception e) { Console.Error.WriteLine($"encoder-selftest matrix: aborted: {Describe(e)}"); }
    }

    private static void Variant(int w, int h, bool profile, bool spacing, bool aspect, bool inputFirst)
    {
        string name = $"{w}x{h} profile={profile} spacing={spacing} aspect={aspect} inputFirst={inputFirst}";
        string step = "activate";
        IMFTransform? mft = null;
        try
        {
            var outInfo = new RegisterTypeInfo { GuidMajorType = MFAttr.Video, GuidSubtype = MFAttr.H264 };
            var acts = EncoderProbe.Enumerate(EncoderProbe.VideoEncoderCategory, 0x1 | EncoderProbe.MFT_ENUM_FLAG_SORTANDFILTER, outInfo);
            if (acts.Length == 0) { Console.Error.WriteLine($"  [{name}] no software encoder"); return; }
            mft = acts[0].ActivateObject<IMFTransform>();
            foreach (var a in acts) a.Dispose();

            void Out()
            {
                step = "SetOutputType";
                using var t = MediaFactory.MFCreateMediaType();
                t.Set(MFAttr.MajorType, MFAttr.Video);
                t.Set(MFAttr.Subtype, MFAttr.H264);
                t.Set(MFAttr.AvgBitrate, 2_000_000);
                t.Set(MFAttr.InterlaceMode, 2);
                if (profile) t.Set(MFAttr.Mpeg2Profile, 100);
                if (spacing) t.Set(MFAttr.MaxKeyframeSpacing, 120);
                MediaFactory.MFSetAttributeSize(t, MFAttr.FrameSize, (uint)w, (uint)h);
                MediaFactory.MFSetAttributeRatio(t, MFAttr.FrameRate, 60, 1);
                if (aspect) MediaFactory.MFSetAttributeRatio(t, MFAttr.PixelAspectRatio, 1, 1);
                mft!.SetOutputType(0, t, 0);
            }
            void In()
            {
                step = "SetInputType";
                using var t = MediaFactory.MFCreateMediaType();
                t.Set(MFAttr.MajorType, MFAttr.Video);
                t.Set(MFAttr.Subtype, MFAttr.Nv12);
                t.Set(MFAttr.InterlaceMode, 2);
                MediaFactory.MFSetAttributeSize(t, MFAttr.FrameSize, (uint)w, (uint)h);
                MediaFactory.MFSetAttributeRatio(t, MFAttr.FrameRate, 60, 1);
                if (aspect) MediaFactory.MFSetAttributeRatio(t, MFAttr.PixelAspectRatio, 1, 1);
                mft!.SetInputType(0, t, 0);
            }
            if (inputFirst) { In(); Out(); } else { Out(); In(); }
            step = "BeginStreaming";
            mft.ProcessMessage((TMessageType)Mf.NotifyBeginStreaming, UIntPtr.Zero);
            step = "StartOfStream";
            mft.ProcessMessage((TMessageType)Mf.NotifyStartOfStream, UIntPtr.Zero);
            Console.Error.WriteLine($"  [{name}] OK");
        }
        catch (Exception e) { Console.Error.WriteLine($"  [{name}] FAILED at {step}: {Describe(e)}"); }
        finally { try { mft?.Dispose(); } catch { } }
    }

    private static string Describe(Exception e) =>
        $"{e.GetType().Name} 0x{(uint)e.HResult:X8} {e.Message.Replace('\n', ' ')}";
}
