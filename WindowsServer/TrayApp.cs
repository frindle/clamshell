using System.Diagnostics;
using System.Windows.Forms;

namespace Clamshell;

// ApplicationContext instead of a Form: no visible window at all, just the
// tray icon — this is what replaces the console window the exe used to open,
// mirroring the Mac app's menu-bar-only presence (Sources/Clamshell/StatusBarApp.swift).
internal sealed class TrayApp : ApplicationContext
{
    private ushort _basePort;
    private List<StreamServer> _servers = new();
    private bool _encoderProbed;

    private readonly NotifyIcon? _icon;
    private SettingsForm? _settingsForm;

    private readonly UpdateChecker _updateChecker = new();
    private readonly System.Windows.Forms.Timer _updateTimer;
    private (string Tag, string Url)? _updateAvailable;

    public ushort BasePort => _basePort;
    public bool IsServing => _servers.Count > 0;

    public TrayApp(ushort basePort)
    {
        _basePort = basePort;

        try
        {
            _icon = new NotifyIcon
            {
                Icon = System.Drawing.SystemIcons.Application,
                Text = "Clamshell",
                Visible = true,
            };
            _icon.DoubleClick += (_, _) => OpenSettings();
        }
        catch (Exception e)
        {
            // windows-ci.yml's smoke test runs this exe on a runner that may
            // have no interactive shell/notification area behind it — a
            // missing tray shouldn't take the whole server down with it.
            Log.Line($"tray icon unavailable ({e.Message}) — running headless");
        }

        StartServing();
        RebuildMenu();

        // Same 6h cadence as the Mac app's checkForUpdate() timer.
        _updateTimer = new System.Windows.Forms.Timer { Interval = (int)TimeSpan.FromHours(6).TotalMilliseconds };
        _updateTimer.Tick += async (_, _) => await CheckForUpdateAsync();
        _updateTimer.Start();
        _ = CheckForUpdateAsync();
    }

    private void StartServing()
    {
        var displays = DisplayEnum.Active();
        Log.Line($"found {displays.Count} display(s); base port {_basePort}");
        foreach (var d in displays)
            Log.Line($"  display {d.Index}{(d.IsPrimary ? " (primary)" : "")}: " +
                     $"{d.Bounds.Width}x{d.Bounds.Height} at ({d.Bounds.X},{d.Bounds.Y}) -> ws port {d.Port(_basePort)}");

        // The probe answer doesn't change while the process is alive, so a
        // Settings port-change restart shouldn't re-run (or re-log) it.
        if (!_encoderProbed)
        {
            EncoderProbe.Run();
            _encoderProbed = true;
        }

        _servers = displays.Select(d => new StreamServer(d, _basePort)).ToList();
        foreach (var s in _servers) s.Start();
        Log.Line("serving — use the tray icon to stop or exit");
    }

    private void StopServing()
    {
        foreach (var s in _servers) s.Dispose();
        _servers.Clear();
        Log.Line("stopped");
    }

    /// <summary>Called by SettingsForm's Apply button. StreamServer's
    /// HttpListener can't be restarted once stopped, so this always tears
    /// down and rebuilds from a fresh DisplayEnum.Active() snapshot.</summary>
    public void RestartWithPort(ushort newBasePort)
    {
        StopServing();
        _basePort = newBasePort;
        StartServing();
        RebuildMenu();
    }

    private void RebuildMenu()
    {
        if (_icon is null) return;

        var menu = new ContextMenuStrip();
        menu.Items.Add(new ToolStripMenuItem(IsServing ? $"Serving on port {_basePort}" : "Stopped") { Enabled = false });

        var toggle = new ToolStripMenuItem(IsServing ? "Stop Serving" : "Start Serving");
        toggle.Click += (_, _) =>
        {
            if (IsServing) StopServing(); else StartServing();
            RebuildMenu();
        };
        menu.Items.Add(toggle);

        menu.Items.Add(new ToolStripSeparator());

        var settings = new ToolStripMenuItem("Settings…");
        settings.Click += (_, _) => OpenSettings();
        menu.Items.Add(settings);

        if (_updateAvailable is { } u)
        {
            var update = new ToolStripMenuItem($"⬆ Update available: {u.Tag}");
            update.Click += (_, _) => ShellOpen(u.Url);
            menu.Items.Add(update);
        }

        menu.Items.Add(new ToolStripSeparator());

        var openLog = new ToolStripMenuItem("Open Log File");
        openLog.Click += (_, _) => ShellOpen(Log.FilePath);
        menu.Items.Add(openLog);

        var exit = new ToolStripMenuItem("Exit");
        exit.Click += (_, _) => ExitApp();
        menu.Items.Add(exit);

        _icon.ContextMenuStrip = menu;
    }

    private void OpenSettings()
    {
        if (_settingsForm is { IsDisposed: false })
        {
            _settingsForm.Activate();
            return;
        }
        _settingsForm = new SettingsForm(_basePort, RestartWithPort, _updateChecker);
        _settingsForm.Show();
    }

    private async Task CheckForUpdateAsync()
    {
        await _updateChecker.CheckOnceAsync((tag, url) =>
        {
            _updateAvailable = (tag, url);
            RebuildMenu();
            if (_icon is not null)
            {
                try { _icon.ShowBalloonTip(10000, "Clamshell update available", $"{tag} is ready to download.", ToolTipIcon.Info); }
                catch { /* balloon tips are a courtesy, not required for the menu item to work */ }
            }
        });
    }

    /// <summary>Opens a URL or a local file path via the shell's default
    /// handler — used for both the release page and the log file.</summary>
    internal static void ShellOpen(string target)
    {
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); }
        catch (Exception e) { Log.Line($"couldn't open '{target}': {e.Message}"); }
    }

    private void ExitApp()
    {
        Log.Line("exiting");
        StopServing();
        _updateTimer.Stop();
        if (_icon is not null) _icon.Visible = false;
        ExitThread();
    }
}
