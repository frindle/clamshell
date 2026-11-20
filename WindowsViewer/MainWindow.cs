using System.Windows;
using Clamshell.Auth;
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
    private readonly Grid _root = new();
    private readonly ContentControl _screen = new();
    private readonly UIElement _badge = AuthScreens.BuildNotVerifiedBadge();

    // Unlock disk: when the Mac does not answer, offer to unlock its disk over SSH (port 22, the
    // pre-boot sshd), then try to connect again every few seconds until it is up. The account is
    // typed here, or read from Credential Manager when the user chose "Save on this device".
    private System.Windows.Threading.DispatcherTimer? _retryTimer;
    private bool _retryBusy, _unlockShown, _unlocked;
    private string _host = ""; private int _port; private StreamCodec _codec;

    public MainWindow()
    {
        Title = "Clamshell";
        _badge.Visibility = Visibility.Collapsed;
        _screen.Visibility = Visibility.Collapsed;
        _root.Children.Add(_image);
        _root.Children.Add(_badge);
        _root.Children.Add(_screen);
        Content = _root;
        Background = System.Windows.Media.Brushes.Black;
        Width = 800; Height = 600;

        _image.MouseMove += OnMouseMove;
        _image.MouseDown += OnMouseButton;
        _image.MouseUp += OnMouseButton;
        _image.MouseWheel += OnMouseWheel;
        KeyDown += OnKey;
        KeyUp += OnKey;
        KeyDown += (_, e) => { if (e.Key == Key.F9 && Keyboard.Modifiers == ModifierKeys.Control) ShowRestart(); };
        Closed += (_, _) => { _retryTimer?.Stop(); _client?.Dispose(); };
    }

    public async void Start(string host, int port, StreamCodec requestedCodec)
    {
        ViewerClient client;
        try { client = ViewerClient.OpenDefault(); }
        catch (DeviceKeyException e)
        {
            // No key, no connection: nothing else is used in its place.
            Title = "Clamshell -- cannot start";
            Log.Line(e.Message);
            return;
        }
        _client = client;
        _host = host; _port = port; _codec = requestedCodec;
        client.OnRestartResult = code => Dispatcher.BeginInvoke(() => ShowRestartResult(code));
        // BeginInvoke, never Invoke, for everything the receive thread raises: it
        // holds the decoder lock while a frame comes out, and closing the window
        // (or StopAndClose) takes that lock on the UI thread, so waiting for the
        // UI there would be a deadlock. The posts keep their order.
        client.OnHelloAck = (codec, w, h) => Dispatcher.BeginInvoke(() => OnHelloAck(codec, w, h));
        client.OnFrame = PostFrame;
        // The client also calls these while it holds its own lock, and the UI
        // thread takes that lock to send input.
        client.OnState = state => Dispatcher.BeginInvoke(() => OnState(state));
        client.OnDisconnected = reason => Dispatcher.BeginInvoke(() => OnDisconnected(reason));

        Title = $"Clamshell -- connecting to {host}:{port}...";
        try { await client.ConnectAsync(host, port, requestedCodec); }
        // Same reason every other cross-thread touch in this class goes
        // through the Dispatcher (BeginInvoke for client callbacks, a
        // one-frame slot for video, Invoke here): a failed ConnectAsync's continuation
        // isn't guaranteed to resume on the UI thread (caught live in CI --
        // this exact line threw System.InvalidOperationException "The
        // calling thread cannot access this object because a different
        // thread owns it" when setting Title directly here).
        catch (Exception e) { Dispatcher.Invoke(() => { Title = $"Clamshell -- connect failed ({e.Message})"; OfferUnlock(); }); }
    }

    /// <summary>What is on screen over the stream (null when none). For the self-test.</summary>
    internal UIElement? ScreenForTest => _screen.Content as UIElement;

    /// <summary>Stop on one of the screens. The viewer has no start screen to go
    /// back to, so a stopped connection would leave an empty window: the app
    /// closes instead, as the window's own close button does.</summary>
    private void StopAndClose()
    {
        _client?.Stop();
        Close();
    }

    internal void OnState(FlowState state)
    {
        Title = $"Clamshell -- {AuthScreens.Title(state)}";
        // While a session runs without proof of who answers, say so.
        _badge.Visibility = state.Kind == FlowStateKind.Connected && !state.Verified
            ? Visibility.Visible : Visibility.Collapsed;
        if (AuthScreens.IsScreen(state))
        {
            _screen.Content = AuthScreens.Build(state, yes => _client?.Answer(yes), StopAndClose);
            _screen.Visibility = Visibility.Visible;
        }
        else
        {
            _screen.Content = null;
            _screen.Visibility = Visibility.Collapsed;
        }
    }

    private void OnDisconnected(string reason)
    {
        Title = $"Clamshell -- disconnected ({reason})";
        OfferUnlock();
    }

    // MARK: - Unlock disk

    /// The Mac stopped answering: show the unlock form once (the Mac may be waiting at its disk
    /// unlock), or, after an unlock, keep trying to connect.
    private void OfferUnlock()
    {
        if (_client is null) return;
        if (!_unlockShown && !_unlocked) ShowUnlock();
        StartRetry();
    }

    private void StartRetry()
    {
        if (_retryTimer is not null) return;
        _retryTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
        _retryTimer.Tick += async (_, _) => await RetryTick();
        _retryTimer.Start();
    }

    private async Task RetryTick()
    {
        if (_retryBusy || _client is null) return;
        _retryBusy = true;
        try { await _client.ConnectAsync(_host, _port, _codec); }
        catch { /* not up yet: try again on the next tick */ }
        finally { _retryBusy = false; }
    }

    /// <summary>Connected again: stop retrying and drop the form.</summary>
    private void Reconnected()
    {
        _retryTimer?.Stop(); _retryTimer = null; _unlocked = false; _unlockShown = false;
        _screen.Content = null; _screen.Visibility = Visibility.Collapsed;
    }

    private void ShowUnlock()
    {
        _unlockShown = true;
        TextBlock? note = null;
        var form = UnlockScreens.Build("Unlock disk",
            "If the Mac restarted, it waits for its disk to be unlocked. Enter an account that can unlock it. This signs in over SSH, then connects again.",
            "Unlock", true, UnlockCredentialStore.Load(),
            async (user, pass, keep) =>
            {
                note!.Text = "Connecting...";
                if (keep) { try { UnlockCredentialStore.Save(user, pass); } catch (Exception e) { Log.Line($"save failed: {e.GetType().Name}"); } }
                else UnlockCredentialStore.Forget();
                var unlocker = new DiskUnlocker(new SshNetUnlockTransport(), SshPinStore.Load, SshPinStore.Save,
                    (_, fingerprint) => Dispatcher.Invoke<bool>(() => MessageBox.Show(this,
                        $"First time unlocking this Mac. Check that its SSH key fingerprint is:\n\n{fingerprint}\n\nIt is remembered, and a different key later is refused.",
                        "Trust this Mac?", MessageBoxButton.OKCancel, MessageBoxImage.Question) == MessageBoxResult.OK),
                    Log.Line);
                var result = await unlocker.UnlockAsync(_host, 22, user, pass);
                note.Text = DiskUnlockText.Of(result);
                if (result == DiskUnlockResult.Unlocked) { _unlocked = true; _unlockShown = false; }
            },
            () => { _screen.Content = null; _screen.Visibility = Visibility.Collapsed; _unlocked = true; },
            out var n);
        note = n;
        _screen.Content = form;
        _screen.Visibility = Visibility.Visible;
    }

    // MARK: - Restart (Ctrl+F9): fdesetup authrestart on the Mac, so the disk does not ask once

    private TextBlock? _restartNote;

    private void ShowRestart()
    {
        if (_client is null || !_client.HostOffersRestart) { Title = "Clamshell -- this Mac does not offer Restart"; return; }
        var form = UnlockScreens.Build("Restart the Mac",
            "Restarts now and skips the disk unlock screen once. Nothing is saved.",
            "Restart", false, null,
            (user, pass, _keep) => { _restartNote!.Text = "Sent. Waiting for the Mac to answer..."; _ = _client.SendRestart(user, pass); },
            () => { _screen.Content = null; _screen.Visibility = Visibility.Collapsed; },
            out var n);
        _restartNote = n;
        _screen.Content = form;
        _screen.Visibility = Visibility.Visible;
    }

    private void ShowRestartResult(byte code)
    {
        string text = code switch
        {
            0 => "Restarting. The disk will not ask to be unlocked this time.",
            1 => "The Mac did not accept that user name and password. Nothing was restarted.",
            2 => "This Mac cannot do an authenticated restart.",
            _ => "Could not start the restart.",
        };
        if (_restartNote is not null) _restartNote.Text = text;
    }

    private void OnHelloAck(StreamCodec codec, int w, int h)
    {
        Reconnected();
        _srcW = w; _srcH = h;
        Title = $"Clamshell -- {codec} {w}x{h}";

        var area = SystemParameters.WorkArea;
        double scale = Math.Min(1.0, Math.Min(area.Width / w, area.Height / h));
        Width = Math.Max(200, w * scale);
        Height = Math.Max(150, h * scale);

        _bitmap = new WriteableBitmap(w, h, 96, 96, PixelFormats.Bgra32, null);
        _image.Source = _bitmap;
    }

    // At most one frame waits for the UI: a newer one replaces it. The decoder
    // hands over a fresh array for every frame, so nothing is reused under it.
    private readonly object _frameGate = new();
    private (int W, int H, byte[] Bgra)? _waitingFrame;
    private bool _frameDeliveryPosted;

    private void PostFrame(int w, int h, byte[] bgra)
    {
        bool post;
        lock (_frameGate)
        {
            _waitingFrame = (w, h, bgra);
            post = !_frameDeliveryPosted;
            _frameDeliveryPosted = true;
        }
        if (post) Dispatcher.BeginInvoke(() => DeliverFrame());
    }

    private void DeliverFrame()
    {
        (int W, int H, byte[] Bgra)? frame;
        lock (_frameGate)
        {
            frame = _waitingFrame;
            _waitingFrame = null;
            _frameDeliveryPosted = false;
        }
        if (frame is { } f) OnFrame(f.W, f.H, f.Bgra);
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
