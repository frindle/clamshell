using System.Runtime.InteropServices;
using SharpGen.Runtime;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace Clamshell;

// DXGI Desktop Duplication capture of one display -> NV12 -> VideoEncoder.
// The Mac mirror is the ScreenCaptureKit half of StreamServer.swift.
//
// Deliberately generic: DuplicateOutput works identically for a VM's virtual
// display adapter (no GPU passthrough) and a real/passed-through GPU — there is
// no VM-vs-physical detection, and none is needed. We just match the DXGI
// output whose desktop rectangle equals the display we were told to serve.
//
// ponytail: BGRA->NV12 is a straight CPU convert per frame (O(pixels)). Fine to
// prove the pipeline; at native res/60fps it's the obvious bottleneck. Upgrade
// path: keep frames on the GPU (Video Processor MFT / shader) and feed the
// encoder a D3D texture via an IMFDXGIDeviceManager instead of system memory.
internal sealed class DisplayCapture : IDisposable
{
    private readonly DisplayInfo _display;
    private readonly VideoEncoder _encoder;
    private readonly int _w, _h;
    private readonly byte[] _nv12;
    private Thread? _thread;
    private volatile bool _run;

    public DisplayCapture(DisplayInfo display, VideoEncoder encoder)
    {
        _display = display;
        _encoder = encoder;
        _w = display.Bounds.Width & ~1;
        _h = display.Bounds.Height & ~1;
        _nv12 = new byte[_w * _h * 3 / 2];
    }

    public void Start()
    {
        _run = true;
        _thread = new Thread(Loop) { IsBackground = true, Name = $"capture-{_display.Index}" };
        _thread.Start();
    }

    public void Dispose()
    {
        _run = false;
        _thread?.Join(2000);
        _thread = null;
    }

    private void Loop()
    {
        ID3D11Device? device = null;
        ID3D11DeviceContext? context = null;
        IDXGIOutputDuplication? dup = null;
        ID3D11Texture2D? staging = null;
        try
        {
            (device, context, dup) = SetUp();
            var startTicks = Environment.TickCount64;

            while (_run)
            {
                IDXGIResource? res = null;
                try
                {
                    Result r = dup.AcquireNextFrame(200, out var _, out res);
                    if ((uint)r.Code == 0x887A0027) continue; // DXGI_ERROR_WAIT_TIMEOUT: screen idle
                    r.CheckError();

                    using var tex = res!.QueryInterface<ID3D11Texture2D>();
                    staging ??= CreateStaging(device!, tex.Description);
                    context!.CopyResource(staging, tex);

                    var map = context.Map(staging, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
                    try { Bgra.ToNv12(map.DataPointer, (int)map.RowPitch, _w, _h, _nv12); }
                    finally { context.Unmap(staging, 0); }

                    ulong ptsMicros = (ulong)(Environment.TickCount64 - startTicks) * 1000UL;
                    _encoder.Feed(_nv12, ptsMicros);
                }
                catch (SharpGenException e) when ((uint)e.HResult == 0x887A0026 /* DXGI_ERROR_ACCESS_LOST */)
                {
                    // Desktop switch (UAC/lock/resolution change) — rebuild duplication.
                    Log.Line($"capture {_display.Index}: access lost, re-acquiring");
                    dup?.Dispose(); staging?.Dispose(); staging = null;
                    (device, context, dup) = ReSetUp(device, context);
                }
                finally
                {
                    res?.Dispose();
                    try { dup?.ReleaseFrame(); } catch { }
                }
            }
        }
        catch (Exception e) { Log.Line($"capture {_display.Index}: fatal {e.Message}"); }
        finally
        {
            staging?.Dispose(); dup?.Dispose(); context?.Dispose(); device?.Dispose();
        }
    }

    private (ID3D11Device, ID3D11DeviceContext, IDXGIOutputDuplication) SetUp()
    {
        using var factory = DXGI.CreateDXGIFactory1<IDXGIFactory1>();
        for (uint ai = 0; factory.EnumAdapters1(ai, out IDXGIAdapter1 adapter).Success; ai++)
        {
            using (adapter)
            {
                for (uint oi = 0; adapter.EnumOutputs(oi, out IDXGIOutput output).Success; oi++)
                {
                    using (output)
                    {
                        var d = output.Description.DesktopCoordinates;
                        bool match = d.Left == _display.Bounds.X && d.Top == _display.Bounds.Y;
                        if (!match) continue;

                        D3D11.D3D11CreateDevice(adapter, DriverType.Unknown, DeviceCreationFlags.BgraSupport,
                            null, out ID3D11Device device, out ID3D11DeviceContext context).CheckError();
                        using var output1 = output.QueryInterface<IDXGIOutput1>();
                        var dup = output1.DuplicateOutput(device);
                        Log.Line($"capture {_display.Index}: duplicating output at ({d.Left},{d.Top})");
                        return (device, context, dup);
                    }
                }
            }
        }
        throw new InvalidOperationException($"no DXGI output matches display {_display.Index} at ({_display.Bounds.X},{_display.Bounds.Y})");
    }

    private (ID3D11Device, ID3D11DeviceContext, IDXGIOutputDuplication) ReSetUp(ID3D11Device? d, ID3D11DeviceContext? c)
    {
        c?.Dispose(); d?.Dispose();
        return SetUp();
    }

    private static ID3D11Texture2D CreateStaging(ID3D11Device device, Texture2DDescription src)
    {
        var desc = src;
        desc.Usage = ResourceUsage.Staging;
        desc.BindFlags = BindFlags.None;
        desc.CPUAccessFlags = CpuAccessFlags.Read;
        desc.MiscFlags = ResourceOptionFlags.None;
        return device.CreateTexture2D(desc);
    }
}

// BGRA (8:8:8:8) -> NV12 (BT.601 studio range), CPU. Deterministic; SelfTest
// checks a solid color round-trips to plausible Y/U/V.
internal static class Bgra
{
    public static void ToNv12(IntPtr src, int rowPitch, int w, int h, byte[] dst)
    {
        int yPlane = w * h;
        unsafe
        {
            byte* b0 = (byte*)src;
            for (int y = 0; y < h; y++)
            {
                byte* row = b0 + (long)y * rowPitch;
                int yOff = y * w;
                for (int x = 0; x < w; x++)
                {
                    byte* px = row + x * 4;
                    dst[yOff + x] = Clip((66 * px[2] + 129 * px[1] + 25 * px[0] + 128 >> 8) + 16);
                }
            }
            // Chroma: one U/V per 2x2 block, sampling the block's top-left pixel.
            int uvOff = yPlane;
            for (int y = 0; y < h; y += 2)
            {
                byte* row = b0 + (long)y * rowPitch;
                for (int x = 0; x < w; x += 2)
                {
                    byte* px = row + x * 4;
                    int B = px[0], G = px[1], R = px[2];
                    dst[uvOff++] = Clip((-38 * R - 74 * G + 112 * B + 128 >> 8) + 128); // U
                    dst[uvOff++] = Clip((112 * R - 94 * G - 18 * B + 128 >> 8) + 128);  // V
                }
            }
        }
    }

    private static byte Clip(int v) => (byte)(v < 0 ? 0 : v > 255 ? 255 : v);
}
