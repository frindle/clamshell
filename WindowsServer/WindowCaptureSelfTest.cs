using System.Runtime.InteropServices;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX.Direct3D11;
using WinRT;

namespace Clamshell;

// `ClamshellServer windowcaptureselftest [windowHandle]` -- Windows-host
// counterpart to Sources/Clamshell/WindowHandoff/WindowCaptureSelfTest.swift.
// Proves Windows.Graphics.Capture actually delivers frames from a SINGLE
// window, not just enumerates it (WindowEnum.cs). See PROTOCOL.md "Window
// Handoff (v2, PROPOSED)" > Capture for why WGC and not the existing DXGI
// Desktop Duplication (DisplayCapture.cs) -- that's whole-display only.
//
// windowHandle must be one printed by `ClamshellServer windowlist` in this
// same session (HWNDs aren't stable across relaunches of the target app).
internal static class WindowCaptureSelfTest
{
    public static int Run(IntPtr? windowHandle)
    {
        var target = windowHandle is { } h
            ? WindowEnum.Capturable().FirstOrDefault(w => w.Handle == h)
            : WindowEnum.Capturable().FirstOrDefault();
        if (target is null)
        {
            Console.WriteLine("FAILED: no matching capturable window" + (windowHandle is { } wh ? $" (handle {wh})" : ""));
            return 1;
        }
        Console.WriteLine($"Capturing: {target.AppName} — {target.Title} ({target.Width}x{target.Height})");

        // GraphicsCaptureItem creation needs an active DispatcherQueue on this
        // thread or it fails -- the Windows analog of the Mac's
        // NSApplication.shared/CGS_REQUIRE_INIT fix (see PROTOCOL.md).
        // CreateFreeThreaded below means frame delivery itself doesn't need a
        // pumped message loop, but the capture session's own internal
        // machinery still does.
        var dqOptions = new DispatcherQueueOptions
        {
            dwSize = Marshal.SizeOf<DispatcherQueueOptions>(),
            threadType = DQTYPE_THREAD_CURRENT,
            apartmentType = DQTAT_COM_NONE,
        };
        int dqHr = CreateDispatcherQueueController(dqOptions, out _);
        if (dqHr != 0)
        {
            Console.WriteLine($"FAILED: CreateDispatcherQueueController failed (hr=0x{dqHr:X8})");
            return 1;
        }

        GraphicsCaptureItem item;
        try
        {
            item = CreateItemForWindow(target.Handle);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"FAILED: could not create capture item: {ex}");
            return 1;
        }

        ID3D11Device? d3dDevice = null;
        IDirect3DDevice? winrtDevice = null;
        Direct3D11CaptureFramePool? framePool = null;
        GraphicsCaptureSession? session = null;
        int frameCount = 0;
        (int W, int H)? firstFrameSize = null;
        var lockObj = new object();
        using var done = new SemaphoreSlim(0);
        Exception? failure = null;

        try
        {
            D3D11.D3D11CreateDevice(null, DriverType.Hardware, DeviceCreationFlags.BgraSupport,
                Array.Empty<FeatureLevel>(), out d3dDevice, out _).CheckError();
            winrtDevice = CreateDirect3DDevice(d3dDevice!);

            framePool = Direct3D11CaptureFramePool.CreateFreeThreaded(
                winrtDevice, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2,
                new global::Windows.Graphics.SizeInt32 { Width = target.Width, Height = target.Height });

            framePool.FrameArrived += (pool, _) =>
            {
                using var frame = pool.TryGetNextFrame();
                if (frame is null) return;
                int count;
                lock (lockObj)
                {
                    frameCount++;
                    firstFrameSize ??= (frame.ContentSize.Width, frame.ContentSize.Height);
                    count = frameCount;
                }
                if (count >= 30) done.Release(); // ~1s at 30fps, enough to prove real frames are flowing
            };

            session = framePool.CreateCaptureSession(item);
            session.IsCursorCaptureEnabled = false; // a remoted app window shouldn't carry the source machine's cursor
            session.StartCapture();
        }
        catch (Exception ex)
        {
            failure = ex;
        }

        bool signaled = failure is null && done.Wait(TimeSpan.FromSeconds(10));

        try { session?.Dispose(); } catch { /* best-effort teardown */ }
        try { framePool?.Dispose(); } catch { /* best-effort teardown */ }
        d3dDevice?.Dispose();

        if (failure is not null)
        {
            Console.WriteLine($"FAILED: could not start capture: {failure}");
            return 1;
        }

        int finalCount;
        (int W, int H)? finalSize;
        lock (lockObj) { finalCount = frameCount; finalSize = firstFrameSize; }

        if (!signaled || finalCount == 0)
        {
            Console.WriteLine("FAILED: no frames received within 10s (window occluded/minimized/off-screen with no compositor updates?)");
            return 1;
        }
        var (w, h) = finalSize ?? (0, 0);
        Console.WriteLine($"PASS: {finalCount} frames captured, {w}x{h}");
        return 0;
    }

    // --- WGC interop: turning an HWND into a GraphicsCaptureItem isn't part
    // of the standard C#/WinRT projection -- Microsoft's own WGC samples
    // P/Invoke-declare this factory interface directly. See PROTOCOL.md. ---

    [ComImport, Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IGraphicsCaptureItemInterop
    {
        IntPtr CreateForWindow([In] IntPtr window, [In] ref Guid iid);
        IntPtr CreateForMonitor([In] IntPtr monitor, [In] ref Guid iid);
    }

    private static GraphicsCaptureItem CreateItemForWindow(IntPtr hwnd)
    {
        var factory = WinRT.ActivationFactory.Get("Windows.Graphics.Capture.GraphicsCaptureItem");
        var interop = (IGraphicsCaptureItemInterop)factory;
        var iid = typeof(GraphicsCaptureItem).GUID;
        IntPtr itemPtr = interop.CreateForWindow(hwnd, ref iid);
        try
        {
            return GraphicsCaptureItem.FromAbi(itemPtr);
        }
        finally
        {
            Marshal.Release(itemPtr);
        }
    }

    // --- D3D11 device -> WinRT IDirect3DDevice interop, same standard
    // recipe used by every C# WGC sample (Direct3D11Helper). ---

    [DllImport("d3d11.dll", EntryPoint = "CreateDirect3D11DeviceFromDXGIDevice", SetLastError = true)]
    private static extern int CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice, out IntPtr graphicsDevice);

    private static IDirect3DDevice CreateDirect3DDevice(ID3D11Device d3dDevice)
    {
        using var dxgiDevice = d3dDevice.QueryInterface<IDXGIDevice>();
        int hr = CreateDirect3D11DeviceFromDXGIDevice(dxgiDevice.NativePointer, out IntPtr devicePtr);
        Marshal.ThrowExceptionForHR(hr);
        try
        {
            return MarshalInterface<IDirect3DDevice>.FromAbi(devicePtr);
        }
        finally
        {
            Marshal.Release(devicePtr);
        }
    }

    // --- DispatcherQueueController: needed for WGC's internal machinery even
    // when frame delivery itself is free-threaded (CreateFreeThreaded above).
    // Windows analog of the Mac's NSApplication.shared/CGS_REQUIRE_INIT fix. ---

    private const int DQTYPE_THREAD_CURRENT = 2;
    private const int DQTAT_COM_NONE = 0;

    [StructLayout(LayoutKind.Sequential)]
    private struct DispatcherQueueOptions
    {
        public int dwSize;
        public int threadType;
        public int apartmentType;
    }

    [DllImport("CoreMessaging.dll")]
    private static extern int CreateDispatcherQueueController(DispatcherQueueOptions options, out IntPtr dispatcherQueueController);
}
