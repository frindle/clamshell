using System.Drawing;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Clamshell;

// Small utility dialog, not a full app window — start-at-sign-in, base port,
// a read-only display/port snapshot, and an on-demand update check.
internal sealed class SettingsForm : Form
{
    // Must match installer.iss's [Registry] entry exactly (same key, value
    // name, and quoted-path format) — this toggles the identical value the
    // installer's "Start Clamshell automatically when you sign in" task
    // writes, so switching it here doesn't fight the installer's setting.
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunValueName = "Clamshell";

    private readonly Action<ushort> _onApplyBasePort;
    private readonly UpdateChecker _updateChecker;

    private readonly CheckBox _startAtSignIn = new() { Text = "Start at sign-in", AutoSize = true, Left = 12, Top = 12 };
    private readonly NumericUpDown _basePort = new() { Minimum = 1024, Maximum = 65000, Left = 100, Top = 44, Width = 80 };
    private readonly Button _apply = new() { Text = "Apply", Left = 190, Top = 42, Width = 70 };
    private readonly ListBox _displays = new() { Left = 12, Top = 80, Width = 296, Height = 110 };
    private readonly Button _checkUpdates = new() { Text = "Check for Updates Now", Left = 12, Top = 200, Width = 296 };

    public SettingsForm(ushort currentBasePort, Action<ushort> onApplyBasePort, UpdateChecker updateChecker)
    {
        _onApplyBasePort = onApplyBasePort;
        _updateChecker = updateChecker;

        Text = "Clamshell Settings";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(320, 240);

        var portLabel = new Label { Text = "Base port:", Left = 12, Top = 46, AutoSize = true };

        Controls.Add(_startAtSignIn);
        Controls.Add(portLabel);
        Controls.Add(_basePort);
        Controls.Add(_apply);
        Controls.Add(_displays);
        Controls.Add(_checkUpdates);

        _startAtSignIn.CheckedChanged += (_, _) => SetStartAtSignIn(_startAtSignIn.Checked);
        _apply.Click += (_, _) => ApplyBasePort();
        _checkUpdates.Click += async (_, _) => await CheckUpdatesNowAsync();

        _basePort.Value = currentBasePort;
        _startAtSignIn.Checked = ReadStartAtSignIn();
        RefreshDisplayList(currentBasePort);
    }

    private void RefreshDisplayList(ushort basePort)
    {
        _displays.Items.Clear();
        foreach (var d in DisplayEnum.Active())
            _displays.Items.Add($"Display {d.Index}{(d.IsPrimary ? " (primary)" : "")}: " +
                                 $"{d.Bounds.Width}x{d.Bounds.Height} -> port {d.Port(basePort)}");
    }

    private void ApplyBasePort()
    {
        var newPort = (ushort)_basePort.Value;
        _onApplyBasePort(newPort);
        RefreshDisplayList(newPort);
    }

    private async Task CheckUpdatesNowAsync()
    {
        _checkUpdates.Enabled = false;
        string? foundTag = null, foundUrl = null;
        await _updateChecker.CheckOnceAsync((tag, url) => { foundTag = tag; foundUrl = url; });
        _checkUpdates.Enabled = true;

        if (foundTag is null)
        {
            MessageBox.Show(this, "You're running the latest version.", "Clamshell",
                MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        var result = MessageBox.Show(this, $"Update {foundTag} is available. Open the release page?", "Clamshell",
            MessageBoxButtons.YesNo, MessageBoxIcon.Information);
        if (result == DialogResult.Yes) TrayApp.ShellOpen(foundUrl!);
    }

    private static bool ReadStartAtSignIn()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
        return key?.GetValue(RunValueName) is not null;
    }

    private static void SetStartAtSignIn(bool enabled)
    {
        // Always succeeds for HKCU\...\Run under the current user's own hive.
        using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true)!;
        if (enabled)
            key.SetValue(RunValueName, $"\"{Application.ExecutablePath}\"");
        else
            key.DeleteValue(RunValueName, throwOnMissingValue: false);
    }
}
