using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Clamshell;

// The viewer window itself. Built entirely in code (no .xaml) -- same
// code-first UI style WindowsServer already uses for its WinForms
// TrayApp/SettingsForm, just WPF instead of WinForms (WPF gets an easy
// borderless/native-feeling resizable window and a GPU-backed Image/
// WriteableBitmap path, which is why this project picked WPF over WinForms
// for the viewer specifically -- see the report).
//
// Sized to match the source (HELLO_ACK's widthPx/heightPx, clamped to the
// local screen's work area) so a single streamed macOS window shows up as
// its own native-sized window here, not a fullscreen remote-desktop view --
// the whole point of Window Handoff.
internal sealed class MainWindow : Window
{
    private readonly Image _image = new() { Stretch = Stretch.Uniform };
    private WriteableBitmap? _bitmap;
    private ViewerClient? _client;
    private int _srcW, _srcH;

    public MainWindow()
    {
        Title = "Clamshell";
        Content = _image;
        Background = System.Windows.Media.Brushes.Black;
        Width = 800; Height = 600;

        _image.MouseMove += OnMouseMove;
        _image.MouseDown += OnMouseButton;
        _image.MouseUp += OnMouseButton;
        _image.MouseWheel += OnMouseWheel;
        KeyDown += OnKey;
        KeyUp += OnKey;
        Closed += (_, _) => _client?.Dispose();
    }

    public async void Start(string host, int port, StreamCodec requestedCodec)
    {
        var client = new ViewerClient();
        _client = client;
        client.OnHelloAck = (codec, w, h) => Dispatcher.Invoke(() => OnHelloAck(codec, w, h));
        client.OnFrame = (w, h, bgra) => Dispatcher.Invoke(() => OnFrame(w, h, bgra));
        client.OnDisconnected = reason => Dispatcher.Invoke(() => Title = $"Clamshell -- disconnected ({reason})");

        Title = $"Clamshell -- connecting to {host}:{port}...";
        try { await client.ConnectAsync(host, port, requestedCodec); }
        catch (Exception e) { Title = $"Clamshell -- connect failed ({e.Message})"; }
    }

    private void OnHelloAck(StreamCodec codec, int w, int h)
    {
        _srcW = w; _srcH = h;
        Title = $"Clamshell -- {codec} {w}x{h}";

        var area = SystemParameters.WorkArea;
        double scale = Math.Min(1.0, Math.Min(area.Width / w, area.Height / h));
        Width = Math.Max(200, w * scale);
        Height = Math.Max(150, h * scale);

        _bitmap = new WriteableBitmap(w, h, 96, 96, PixelFormats.Bgra32, null);
        _image.Source = _bitmap;
    }

    private void OnFrame(int w, int h, byte[] bgra)
    {
        if (_bitmap is null || w != _bitmap.PixelWidth || h != _bitmap.PixelHeight) return;
        _bitmap.WritePixels(new Int32Rect(0, 0, w, h), bgra, w * 4, 0);
    }

    // MARK: - Input forwarding (PROTOCOL.md "Input mapping": normalized 0..1
    // within the streamed content, origin top-left).

    private (float x, float y)? Normalize(System.Windows.Point p)
    {
        if (_srcW <= 0 || _srcH <= 0 || _image.ActualWidth <= 0 || _image.ActualHeight <= 0) return null;
        // Stretch=Uniform letterboxes -- map the click point back into the
        // actual rendered image rect, not the whole control.
        double scale = Math.Min(_image.ActualWidth / _srcW, _image.ActualHeight / _srcH);
        double renderedW = _srcW * scale, renderedH = _srcH * scale;
        double offX = (_image.ActualWidth - renderedW) / 2, offY = (_image.ActualHeight - renderedH) / 2;
        double nx = (p.X - offX) / renderedW, ny = (p.Y - offY) / renderedH;
        if (nx < 0 || nx > 1 || ny < 0 || ny > 1) return null; // in the letterbox bars
        return ((float)nx, (float)ny);
    }

    private void OnMouseMove(object sender, MouseEventArgs e)
    {
        if (_client is null) return;
        if (Normalize(e.GetPosition(_image)) is { } n) _ = _client.SendMouseMove(n.x, n.y);
    }

    private void OnMouseButton(object sender, MouseButtonEventArgs e)
    {
        if (_client is null || e.ChangedButton is not (MouseButton.Left or MouseButton.Right)) return;
        if (Normalize(e.GetPosition(_image)) is not { } n) return;
        byte button = e.ChangedButton == MouseButton.Left ? (byte)0 : (byte)1;
        bool down = e.ButtonState == MouseButtonState.Pressed;
        _ = _client.SendMouseButton(button, down, n.x, n.y);
    }

    private void OnMouseWheel(object sender, MouseWheelEventArgs e)
    {
        // PROTOCOL.md: pixel wheel deltas, not normalized.
        _ = _client?.SendScroll(0, e.Delta);
    }

    private void OnKey(object sender, KeyEventArgs e)
    {
        if (_client is null) return;
        int vk = System.Windows.Input.KeyInterop.VirtualKeyFromKey(e.Key);
        if (MacKeyMap.ToMac((ushort)vk) is not { } macCode) return;
        // ponytail: cgEventFlags (modifier bitmask) is always sent as 0 --
        // v1 relies on separate Key down/up events for modifier keys
        // themselves (Shift/Cmd/Option are in the map above) rather than a
        // combined flags word. Upgrade path: track WPF's Keyboard.Modifiers
        // and pack the equivalent CGEventFlags bits if an app needs the
        // combined-flags form specifically.
        _ = _client.SendKey((ushort)macCode, e.IsDown, 0);
        e.Handled = true;
    }
}
