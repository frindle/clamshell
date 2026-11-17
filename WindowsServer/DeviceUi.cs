using System.Drawing;
using System.Windows.Forms;

namespace Clamshell;

// The windows that let the person at this PC decide which devices may connect. The wording is
// the Mac host's (Sources/Clamshell/DeviceApprovalUI.swift and DevicesController.swift).
// Nothing in here is ever shown to, or decided by, the device that is asking.

internal static class DeviceText
{
    public static string Quoted(string name) => "“" + name + "”";

    /// <summary>Same buckets as DeviceCommands.ago on the Mac.</summary>
    public static string Ago(double then, double now)
    {
        double s = Math.Max(0, now - then);
        if (s < 60) return "just now";
        if (s < 3600) return $"{(int)(s / 60)} min ago";
        if (s < 86_400) return $"{(int)(s / 3600)} h ago";
        return $"{(int)(s / 86_400)} d ago";
    }

    public static double Now() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;

    public const string Caption = "A new device is asking to see and control this PC. It calls itself:";
    public const string Hint = "Approve it only if the device shows this same fingerprint on its own screen.";

    public static string StateText(DeviceState s) => s switch
    {
        DeviceState.Trusted => "Trusted",
        DeviceState.Denied => "Denied",
        _ => "Waiting for approval",
    };

    /// <summary>The line under the fingerprint in the approval window.</summary>
    public static string Detail(DeviceRecord d, bool connectedNow, bool nameIsTaken, double now)
    {
        string from = d.Address.Length == 0 ? "an unknown address" : d.Address;
        return $"Asked {Ago(d.FirstSeen, now)} from {from}."
            + (connectedNow ? "" : " It is not connected right now.")
            + (nameIsTaken ? " A device you already trust has the same name; this one has a different key." : "");
    }

    public static void CouldNotSave(IWin32Window? owner)
    {
        MessageBox.Show(owner, "Nothing was changed. The reason is in the log file (tray menu, Open Log File).",
            "The device list could not be saved", MessageBoxButtons.OK, MessageBoxIcon.Warning);
    }
}

/// <summary>The window that opens when a device waits. Two buttons, Deny and Approve, and no
/// default button: a stray Enter or Space can decide nothing. Shown without taking the
/// keyboard from what the person is typing into, and both buttons stay off for a moment.</summary>
internal sealed class ApprovalForm : Form
{
    public const int ArmDelayMs = 1500;

    private readonly Label _caption = new() { AutoSize = false, Left = 16, Top = 14, Width = 388, Height = 32 };
    private readonly Label _name = new() { AutoSize = false, Left = 16, Top = 50, Width = 388, Height = 26 };
    private readonly Label _fingerprint = new() { AutoSize = false, Left = 16, Top = 82, Width = 388, Height = 34 };
    private readonly Label _hint = new() { AutoSize = false, Left = 16, Top = 120, Width = 388, Height = 32 };
    private readonly Label _detail = new() { AutoSize = false, Left = 16, Top = 156, Width = 388, Height = 32 };
    private readonly Label _queue = new() { AutoSize = false, Left = 16, Top = 204, Width = 150, Height = 20 };
    private readonly Button _deny = new() { Text = "Deny", Left = 244, Top = 198, Width = 78, Height = 28, TabStop = false };
    private readonly Button _approve = new() { Text = "Approve", Left = 328, Top = 198, Width = 78, Height = 28, TabStop = false };
    private readonly System.Windows.Forms.Timer _arm = new() { Interval = ArmDelayMs };

    private DeviceRecord? _device;

    /// <summary>The id being asked about, or null.</summary>
    public string? AskingId => _device?.Id;

    /// <summary>Called with the device id and true for Approve, false for Deny.</summary>
    public event Action<string, bool>? Decided;

    /// <summary>The person closed the window without deciding.</summary>
    public event Action? LeftUndecided;

    private bool _closingItself;

    public ApprovalForm()
    {
        Text = "Clamshell";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(420, 240);

        _name.Font = new Font(Font.FontFamily, 12f, FontStyle.Bold);
        _fingerprint.Font = new Font("Consolas", 16f, FontStyle.Regular);
        _detail.ForeColor = SystemColors.GrayText;
        _queue.ForeColor = SystemColors.GrayText;
        _fingerprint.Cursor = Cursors.IBeam;

        // No AcceptButton and no CancelButton: see the note on the class.
        foreach (Control c in new Control[] { _caption, _name, _fingerprint, _hint, _detail, _queue, _deny, _approve })
            Controls.Add(c);

        _deny.Click += (_, _) => Answer(false);
        _approve.Click += (_, _) => Answer(true);
        _arm.Tick += (_, _) => { _arm.Stop(); SetButtons(true); };
    }

    protected override bool ShowWithoutActivation => true;

    private void SetButtons(bool on) { _deny.Enabled = on; _approve.Enabled = on; }

    private void Answer(bool approve)
    {
        if (_device is not { } d) return;
        _device = null;
        _arm.Stop();
        Decided?.Invoke(d.Id, approve);
    }

    /// <summary>Asks about <paramref name="device"/>; <paramref name="position"/> of
    /// <paramref name="total"/> devices are waiting. Asking about the same device again only
    /// refreshes the small print: it does not restart the wait before a button works.</summary>
    public void Ask(DeviceRecord device, int position, int total, bool connectedNow, bool nameIsTaken, double now)
    {
        bool same = _device?.Id == device.Id;
        _device = device;
        _caption.Text = DeviceText.Caption;
        _name.Text = device.Label;
        _fingerprint.Text = device.Fingerprint;
        _hint.Text = DeviceText.Hint;
        _detail.Text = DeviceText.Detail(device, connectedNow, nameIsTaken, now);
        _queue.Text = total > 1 ? $"{position} of {total} waiting" : "";
        if (!same)
        {
            SetButtons(false);
            _arm.Stop();
            _arm.Start();
        }
        if (!Visible) Show();
    }

    /// <summary>Takes the window away without that counting as the person closing it.</summary>
    public void DismissQuietly()
    {
        _device = null;
        _arm.Stop();
        if (!Visible) return;
        _closingItself = true;
        Hide();
        _closingItself = false;
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (e.CloseReason == CloseReason.UserClosing && !_closingItself)
        {
            // Hide rather than dispose: the controller reuses the window.
            e.Cancel = true;
            bool undecided = _device is not null;
            _device = null;
            _arm.Stop();
            Hide();
            if (undecided) LeftUndecided?.Invoke();
            return;
        }
        base.OnFormClosing(e);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _arm.Dispose();
        base.Dispose(disposing);
    }

    /// <summary>For the screens self-test: every control and its text.</summary>
    public IEnumerable<Control> Parts => new Control[] { _caption, _name, _fingerprint, _hint, _detail, _queue, _deny, _approve };
    public bool ButtonsEnabled => _deny.Enabled && _approve.Enabled;
}

/// <summary>The Devices section of Settings: who is waiting, trusted and denied, with the
/// actions the Mac's Devices menu has, the "ask before a new device can connect" switch and
/// this PC's fingerprint.</summary>
internal sealed class DevicesPanel : UserControl
{
    private readonly HostAuth _auth;
    private readonly ListView _list = new()
    {
        Left = 0, Top = 0, Width = 416, Height = 130, View = View.Details, FullRowSelect = true,
        HideSelection = false, MultiSelect = false, HeaderStyle = ColumnHeaderStyle.Nonclickable,
    };
    private readonly Button _approve = new() { Text = "Approve…", Left = 0, Top = 136, Width = 100 };
    private readonly Button _deny = new() { Text = "Deny", Left = 105, Top = 136, Width = 100 };
    private readonly Button _revoke = new() { Text = "Revoke…", Left = 210, Top = 136, Width = 100 };
    private readonly Button _forget = new() { Text = "Forget…", Left = 315, Top = 136, Width = 100 };
    private readonly CheckBox _ask = new() { Text = "Ask before a new device can connect", Left = 0, Top = 172, Width = 416, AutoSize = false, Height = 22 };
    private readonly Label _unapproved = new() { Left = 0, Top = 196, Width = 416, Height = 18, ForeColor = SystemColors.GrayText };
    private readonly Label _fingerprint = new() { Left = 0, Top = 216, Width = 416, Height = 18 };
    private readonly Label _problems = new() { Left = 0, Top = 236, Width = 416, Height = 34, ForeColor = SystemColors.GrayText };

    private bool _setting;
    private bool _wired;

    public DevicesPanel(HostAuth auth)
    {
        _auth = auth;
        Size = new Size(416, 272);
        _list.Columns.Add("Device", 140);
        _list.Columns.Add("Status", 110);
        _list.Columns.Add("Fingerprint", 150);
        foreach (Control c in new Control[] { _list, _approve, _deny, _revoke, _forget, _ask, _unapproved, _fingerprint, _problems })
            Controls.Add(c);

        _list.SelectedIndexChanged += (_, _) => UpdateButtons();
        _approve.Click += (_, _) => ApproveSelected();
        _deny.Click += (_, _) => DenySelected();
        _revoke.Click += (_, _) => RevokeSelected();
        _forget.Click += (_, _) => ForgetSelected();
        _ask.CheckedChanged += (_, _) => AskChanged();
        Reload();
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        if (_wired) return;
        _wired = true;
        _auth.Store.DidChange += OnChanged;
        _auth.ApprovalDidChange += OnChanged;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing && _wired)
        {
            _auth.Store.DidChange -= OnChanged;
            _auth.ApprovalDidChange -= OnChanged;
        }
        base.Dispose(disposing);
    }

    private void OnChanged()
    {
        try { if (IsHandleCreated && !IsDisposed) BeginInvoke(new Action(Reload)); }
        catch (Exception e) when (e is ObjectDisposedException or InvalidOperationException) { }
    }

    private DeviceRecord? Selected()
    {
        if (_list.SelectedItems.Count == 0) return null;
        return _list.SelectedItems[0].Tag as DeviceRecord;
    }

    /// <summary>Rebuilds the list from the store, keeping the selection.</summary>
    public void Reload()
    {
        string? keep = Selected()?.Id;
        var all = _auth.Store.All();
        double now = DeviceText.Now();
        var open = _auth.OpenSessions();

        _list.BeginUpdate();
        _list.Items.Clear();
        void Add(DeviceRecord d)
        {
            string status = DeviceText.StateText(d.State);
            if (d.State == DeviceState.Trusted)
                status = open.Devices.TryGetValue(d.Id, out var n) && n > 0
                    ? "Trusted, connected now"
                    : "Trusted, seen " + DeviceText.Ago(d.LastSeen, now);
            else if (d.State == DeviceState.Waiting)
                status = "Waiting, asked " + DeviceText.Ago(d.FirstSeen, now);
            var item = new ListViewItem(DeviceText.Quoted(d.Label)) { Tag = d };
            item.SubItems.Add(status);
            item.SubItems.Add(d.Fingerprint);
            if (d.Id == keep) item.Selected = true;
            _list.Items.Add(item);
        }
        foreach (var d in all.Where(r => r.State == DeviceState.Waiting).OrderBy(r => r.FirstSeen)) Add(d);
        foreach (var d in all.Where(r => r.State == DeviceState.Trusted).OrderBy(r => r.Label, StringComparer.CurrentCultureIgnoreCase)) Add(d);
        foreach (var d in all.Where(r => r.State == DeviceState.Denied).OrderByDescending(r => r.DecidedAt ?? 0)) Add(d);
        if (all.Count == 0)
            _list.Items.Add(new ListViewItem("No devices yet") { ForeColor = SystemColors.GrayText });
        _list.EndUpdate();

        _setting = true;
        _ask.Checked = _auth.RequireApproval;
        _setting = false;
        int unapproved = _auth.UnapprovedSessions();
        _unapproved.Text = unapproved > 0
            ? $"{unapproved} {(unapproved == 1 ? "session" : "sessions")} connected without approval"
            : "";
        _fingerprint.Text = "This PC’s fingerprint: " + _auth.Identity.Fingerprint;
        var problems = new List<string>();
        if (!_auth.Identity.IsPersistent) problems.Add("Its key could not be stored and changes when Clamshell restarts.");
        if (!_auth.Store.CanPersist) problems.Add("The device list could not be stored and lasts until Clamshell quits.");
        _problems.Text = string.Join(" ", problems);
        UpdateButtons();
    }

    private void UpdateButtons()
    {
        var d = Selected();
        _approve.Enabled = d is { State: DeviceState.Waiting or DeviceState.Denied };
        _deny.Enabled = d is { State: DeviceState.Waiting };
        _revoke.Enabled = d is { State: DeviceState.Trusted };
        _forget.Enabled = d is { State: DeviceState.Trusted or DeviceState.Denied };
    }

    /// <summary>Escape cancels and the action button is the second one: no stray key does it.</summary>
    private bool Confirm(string title, string text, string action)
    {
        var r = MessageBox.Show(this, text + $"\n\nChoose OK to {action.ToLowerInvariant()}.", title,
            MessageBoxButtons.OKCancel, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2);
        return r == DialogResult.OK;
    }

    private DeviceRecord? Current(string id, DeviceState state)
    {
        var d = _auth.Store.Record(id);
        if (d is not null && d.State == state) return d;
        Reload();
        return null;
    }

    private void ApproveSelected()
    {
        if (Selected() is not { } sel) return;
        if (sel.State == DeviceState.Waiting)
        {
            if (Current(sel.Id, DeviceState.Waiting) is not { } w) return;
            if (!Confirm($"Approve {DeviceText.Quoted(w.Label)}?",
                    $"Fingerprint {w.Fingerprint}.\n\n" + DeviceText.Hint, "Approve")
                || Current(sel.Id, DeviceState.Waiting) is null) return;
            var saved = _auth.Store.Decide(sel.Id, DeviceTrustStore.Decision.Approve, DeviceTrustStore.DecidedOnHost, onlyIfWaiting: true);
            if (saved is not null) Log.Line($"DEVICES: {saved.Fingerprint} ({saved.Name}) was approved in Settings");
            Reload();
            if (saved is null && _auth.Store.StateOf(sel.Id) == DeviceState.Waiting) DeviceText.CouldNotSave(this);
            return;
        }
        if (Current(sel.Id, DeviceState.Denied) is not { } d) return;
        if (!Confirm($"Approve {DeviceText.Quoted(d.Label)}?",
                $"Fingerprint {d.Fingerprint}.\n\nThis device was denied before. Approving it lets it see this PC’s screen "
                + "and control its keyboard and mouse whenever it connects. " + DeviceText.Hint, "Approve")
            || Current(sel.Id, DeviceState.Denied) is null) return;
        var done = _auth.Store.Decide(sel.Id, DeviceTrustStore.Decision.Approve, DeviceTrustStore.DecidedOnHost, onlyIfWaiting: false);
        if (done is not null) Log.Line($"DEVICES: {done.Fingerprint} ({done.Name}) was approved in Settings");
        Reload();
        if (done is null && _auth.Store.StateOf(sel.Id) == DeviceState.Denied) DeviceText.CouldNotSave(this);
    }

    private void DenySelected()
    {
        if (Selected() is not { } sel || Current(sel.Id, DeviceState.Waiting) is not { } d) return;
        var saved = _auth.Store.Decide(d.Id, DeviceTrustStore.Decision.Deny, DeviceTrustStore.DecidedOnHost, onlyIfWaiting: true);
        if (saved is not null) Log.Line($"DEVICES: {saved.Fingerprint} ({saved.Name}) was denied in Settings");
        Reload();
        if (saved is null && _auth.Store.StateOf(d.Id) == DeviceState.Waiting) DeviceText.CouldNotSave(this);
    }

    private void RevokeSelected()
    {
        if (Selected() is not { } sel || Current(sel.Id, DeviceState.Trusted) is not { } d) return;
        if (!Confirm($"Revoke {DeviceText.Quoted(d.Label)}?",
                $"Fingerprint {d.Fingerprint}.\n\nIt is disconnected now and cannot connect again unless you approve it.", "Revoke")
            || Current(sel.Id, DeviceState.Trusted) is null) return;
        var saved = _auth.Store.Revoke(d.Id, DeviceTrustStore.DecidedOnHost);
        if (saved is not null) Log.Line($"DEVICES: {saved.Fingerprint} ({saved.Name}) was revoked in Settings");
        Reload();
        if (saved is null && _auth.Store.StateOf(d.Id) == DeviceState.Trusted) DeviceText.CouldNotSave(this);
    }

    private void ForgetSelected()
    {
        if (Selected() is not { } sel) return;
        var d = _auth.Store.Record(sel.Id);
        if (d is null || d.State == DeviceState.Waiting) { Reload(); return; }
        string what = d.State == DeviceState.Trusted
            ? "It is disconnected now and taken off the list. If it connects again it has to ask for approval like a new device."
            : "It is taken off the list. If it connects again it can ask for approval again.";
        if (!Confirm($"Forget {DeviceText.Quoted(d.Label)}?", $"Fingerprint {d.Fingerprint}.\n\n{what}", "Forget")
            || Current(d.Id, d.State) is null) return;
        var removed = _auth.Store.Forget(d.Id);
        if (removed is not null) Log.Line($"DEVICES: {removed.Fingerprint} ({removed.Name}) was forgotten in Settings");
        Reload();
        if (removed is null && _auth.Store.StateOf(d.Id) is not null) DeviceText.CouldNotSave(this);
    }

    private void AskChanged()
    {
        if (_setting) return;
        bool want = _ask.Checked;
        if (want == _auth.RequireApproval) return;
        if (!want)
        {
            if (!Confirm("Turn off device approval?",
                    "Any device that can reach this PC over the network will be able to see its screen and control its "
                    + "keyboard and mouse without asking. The devices you trust stay on the list.", "Turn off"))
            {
                Reload();
                return;
            }
        }
        else
        {
            int unapproved = _auth.UnapprovedSessions();
            if (unapproved > 0 && !Confirm("Turn on device approval?",
                    $"{unapproved} {(unapproved == 1 ? "session" : "sessions")} connected without approval will be disconnected. "
                    + "After that only devices you approve can connect.", "Turn on"))
            {
                Reload();
                return;
            }
        }
        _auth.SetRequireApproval(want);
        Reload();
    }

    /// <summary>For the screens self-test.</summary>
    public IEnumerable<Control> Parts => new Control[] { _list, _approve, _deny, _revoke, _forget, _ask, _unapproved, _fingerprint, _problems };
    public int Rows => _list.Items.Count;
}

/// <summary>Decides when the approval window opens. A device that waits opens it; closing it
/// without deciding keeps it away for 20 s, then 40 s and so on up to 15 min, and the first
/// waiting device in each such period gets a quiet balloon from the tray icon instead.
/// Any decision starts the periods over. Runs on the UI thread only.</summary>
internal sealed class ApprovalController : IDisposable
{
    public static readonly TimeSpan FirstQuiet = TimeSpan.FromSeconds(20);
    public static readonly TimeSpan LongestQuiet = TimeSpan.FromMinutes(15);

    private readonly HostAuth _auth;
    private readonly Control _ui;
    private readonly NotifyIcon? _icon;
    private readonly ApprovalForm _form = new();
    private readonly System.Windows.Forms.Timer _wake = new();
    private TimeSpan _quiet = TimeSpan.Zero;
    private DateTime _quietUntil = DateTime.MinValue;
    private DateTime _notifiedFor = DateTime.MinValue;

    public ApprovalController(HostAuth auth, Control ui, NotifyIcon? icon)
    {
        _auth = auth;
        _ui = ui;
        _icon = icon;
        _form.Decided += OnDecided;
        _form.LeftUndecided += OnLeft;
        _wake.Tick += (_, _) => { _wake.Stop(); Refresh(); };
        if (_icon is not null) _icon.BalloonTipClicked += (_, _) => { _quietUntil = DateTime.MinValue; Refresh(); };
        _auth.Store.DidChange += OnChanged;
    }

    public ApprovalForm Form => _form;

    private void OnChanged()
    {
        try { if (_ui.IsHandleCreated && !_ui.IsDisposed) _ui.BeginInvoke(new Action(Refresh)); }
        catch (Exception e) when (e is ObjectDisposedException or InvalidOperationException) { }
    }

    private void OnLeft()
    {
        _quiet = _quiet == TimeSpan.Zero ? FirstQuiet : TimeSpan.FromTicks(Math.Min(_quiet.Ticks * 2, LongestQuiet.Ticks));
        _quietUntil = DateTime.UtcNow + _quiet;
        Refresh();
    }

    private void OnDecided(string id, bool approve)
    {
        _quiet = TimeSpan.Zero;
        _quietUntil = DateTime.MinValue;
        var saved = _auth.Store.Decide(id, approve ? DeviceTrustStore.Decision.Approve : DeviceTrustStore.Decision.Deny,
            DeviceTrustStore.DecidedOnHost, onlyIfWaiting: true);
        if (saved is not null)
            Log.Line($"DEVICES: {saved.Fingerprint} ({saved.Name}) was {(approve ? "approved" : "denied")} in the approval window");
        else if (_auth.Store.StateOf(id) == DeviceState.Waiting)
            DeviceText.CouldNotSave(null);
        Refresh();
    }

    /// <summary>Brings the window in line with the list. Safe to call at any time.</summary>
    public void Refresh()
    {
        var waiting = _auth.Store.Waiting();
        if (waiting.Count == 0)
        {
            _form.DismissQuietly();
            return;
        }
        var now = DateTime.UtcNow;
        if (now < _quietUntil && !_form.Visible)
        {
            _wake.Stop();
            _wake.Interval = (int)Math.Clamp((_quietUntil - now).TotalMilliseconds + 50, 50, int.MaxValue);
            _wake.Start();
            Announce(waiting[0]);
            return;
        }
        var all = _auth.Store.All();
        var first = _form.AskingId is { } asking ? waiting.FirstOrDefault(w => w.Id == asking) ?? waiting[0] : waiting[0];
        bool taken = all.Any(r => r.State == DeviceState.Trusted && r.Id != first.Id
            && string.Equals(r.Name, first.Name, StringComparison.OrdinalIgnoreCase));
        _form.Ask(first, waiting.FindIndex(w => w.Id == first.Id) + 1, waiting.Count,
            _auth.HasWaitingConnection(first.Id), taken, DeviceText.Now());
    }

    private void Announce(DeviceRecord first)
    {
        if (_icon is null || _notifiedFor == _quietUntil) return;
        _notifiedFor = _quietUntil;
        _icon.ShowBalloonTip(10_000, "A device is asking to connect",
            $"{DeviceText.Quoted(first.Label)} {first.Fingerprint} is waiting for approval. Click to answer.", ToolTipIcon.Info);
    }

    public void Dispose()
    {
        _auth.Store.DidChange -= OnChanged;
        _wake.Dispose();
        _form.Dispose();
    }
}
