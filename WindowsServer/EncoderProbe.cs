using System.Runtime.InteropServices;
using Vortice.MediaFoundation;

namespace Clamshell;

// Where a display's encoder ended up, which drives the HELLO_ACK warning bit.
// See PROTOCOL.md's note on the flags byte and the report: the single wire bit
// means "should the client warn?", NOT "is it literally hardware".
internal enum EncoderStatus
{
    HardwareActive,    // a hardware encoder MFT is doing the work — no warning
    SoftwareExpected,  // no hardware encoder present on this system at all
                       // (e.g. no GPU passthrough) — EXPECTED, no warning
    SoftwareFallback,  // hardware WAS available but failed to instantiate/drive
                       // — a real problem, SET the warning bit
}

internal static class EncoderProbe
{
    /// <summary>True if any hardware video-encoder MFT exists on this system.
    /// Probed once at startup and cached (the answer doesn't change while
    /// running). Distinguishes SoftwareExpected from SoftwareFallback.</summary>
    public static bool HardwareEverAvailable { get; private set; }

    // MFT_CATEGORY_VIDEO_ENCODER — defined as a literal so we don't depend on
    // Vortice's constant naming.
    public static readonly Guid VideoEncoderCategory = new("f79eac7d-e545-4387-bdee-d647d7bde42a");

    // _MFT_ENUM_FLAG
    public const int MFT_ENUM_FLAG_HARDWARE = 0x00000004;
    public const int MFT_ENUM_FLAG_SORTANDFILTER = 0x00000040;

    public static void Run()
    {
        MediaFoundationRuntime.EnsureStarted();
        try
        {
            HardwareEverAvailable = HardwareEncoderCount() > 0;
            Log.Line(HardwareEverAvailable
                ? "hardware video encoder MFT detected — will prefer it"
                : "no hardware video encoder MFT present (expected without GPU passthrough) — software encode, no client warning");
        }
        catch (Exception e)
        {
            HardwareEverAvailable = false;
            Log.Line($"hardware encoder probe failed ({e.Message}) — assuming software-only");
        }
    }

    /// <summary>Count of hardware video-encoder MFTs (any subtype). A non-zero
    /// count is our proxy for "hardware encode is possible on this box".</summary>
    private static int HardwareEncoderCount()
    {
        // Null input/output type filters -> all hardware video encoders.
        IMFActivate[] activates = Enumerate(VideoEncoderCategory,
            MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER, null);
        int n = activates.Length;
        foreach (var a in activates) a.Dispose();
        return n;
    }

    /// <summary>MFTEnumEx wrapper. Vortice surfaces the raw (IMFActivate** ,
    /// count) out-params, so we marshal the COM pointer array ourselves and free
    /// the outer array with CoTaskMemFree (per MSDN).</summary>
    public static IMFActivate[] Enumerate(Guid category, int flags, RegisterTypeInfo? outputType)
    {
        MediaFactory.MFTEnumEx(category, (uint)flags, null, outputType, out nint pActs, out uint count);
        var result = new IMFActivate[count];
        for (int i = 0; i < count; i++)
            result[i] = new IMFActivate(Marshal.ReadIntPtr(pActs, i * IntPtr.Size));
        if (pActs != IntPtr.Zero) Marshal.FreeCoTaskMem(pActs);
        return result;
    }
}

// One-time Media Foundation startup for the process.
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
