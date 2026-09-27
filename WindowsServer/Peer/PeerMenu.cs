namespace Clamshell;

// "Shared Desk" submenu for the tray icon — the twin of PeerMenu.swift:
// on/off (persisted in shared-desk.json), this PC's pairing PIN, which edge
// the peer sits beyond, pair / connect to discovered machines or by address,
// Send Files, Bring Back handed-off windows, forget paired machines.
internal sealed class PeerMenuController : IDisposable
{
    public PeerManager? Manager { get; private set; }
    public Action OnChange = () => { };

    public void StartIfEnabled()
    {
        if (PeerManager.LoadSettings().Enabled) Start();
    }

    private void Start()
    {
        if (Manager is not null) return;
        try
        {
            var m = PeerManager.MakeDefault(PeerManager.LoadSettings().Edge);
            m.OnChange = () => OnChange();
            m.Start();
            Manager = m;
        }
        catch (Exception e)
        {
            Log.Line($"PEER: could not start shared desk: {e.Message}");
            MessageBox.Show($"Shared Desk could not start:\n{e.Message}\n\nIs another copy of Clamshell already using port {PeerLimits.DefaultPort}?",
                "Clamshell", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        OnChange();
    }

    public void Stop()
    {
        Manager?.Dispose();
        Manager = null;
        OnChange();
    }

    public void Dispose() => Stop();

    public ToolStripMenuItem MakeMenuItem()
    {
        var root = new ToolStripMenuItem("Shared Desk");
        var toggle = new ToolStripMenuItem("Enable Shared Desk") { Checked = Manager is not null };
        toggle.Click += (_, _) =>
        {
            bool on = Manager is null;
            PeerManager.SaveSettings(PeerManager.LoadSettings() with { Enabled = on });
            if (on) Start(); else Stop();
        };
        root.DropDownItems.Add(toggle);

        if (Manager is { } m)
        {
            root.DropDownItems.Add(new ToolStripSeparator());
            root.DropDownItems.Add(Disabled(m.StatusLine));
            root.DropDownItems.Add(Disabled($"This PC's pairing PIN: {m.Link.PairingPin}"));

            var edge = new ToolStripMenuItem("Peer Is Beyond This PC's…");
            foreach (var e in new[] { PeerEdge.Left, PeerEdge.Right, PeerEdge.Top, PeerEdge.Bottom })
            {
                var item = new ToolStripMenuItem(e.ToString()) { Checked = m.Edge.Edge == e };
                item.Click += (_, _) => m.SetEdge(e);
                edge.DropDownItems.Add(item);
            }
            root.DropDownItems.Add(edge);

            root.DropDownItems.Add(new ToolStripSeparator());
            if (m.Discovered.Count == 0) root.DropDownItems.Add(Disabled("No machines found on this network"));
            foreach (var p in m.Discovered)
            {
                bool paired = p.Id is { } id && m.Trust.Peer(id) is not null;
                var item = new ToolStripMenuItem(paired ? $"Connect to {p.Name}" : $"Pair with {p.Name}…");
                item.Click += (_, _) =>
                {
                    if (paired) { m.Connect(p, null); return; }
                    if (Prompt($"Pair with {p.Name}", $"Enter the 6-digit pairing PIN shown on {p.Name} (Shared Desk menu).", "PIN") is { } pin && Digits(pin) is { Length: 6 } d)
                        m.Connect(p, d);
                };
                root.DropDownItems.Add(item);
            }
            var byAddr = new ToolStripMenuItem("Connect by Address…");
            byAddr.Click += (_, _) => ConnectByAddress(m);
            root.DropDownItems.Add(byAddr);
            if (m.State.IsLinked)
            {
                var dis = new ToolStripMenuItem("Disconnect");
                dis.Click += (_, _) => m.Disconnect();
                root.DropDownItems.Add(dis);

                root.DropDownItems.Add(new ToolStripSeparator());
                var send = new ToolStripMenuItem($"Send Files to {m.PeerName ?? "Peer"}…");
                send.Click += (_, _) =>
                {
                    using var dlg = new OpenFileDialog { Multiselect = true, Title = "Files to send (they land in the peer's Downloads)" };
                    if (dlg.ShowDialog() == DialogResult.OK) m.Files.SendPaths(dlg.FileNames);
                };
                root.DropDownItems.Add(send);
                var sendFolder = new ToolStripMenuItem($"Send a Folder to {m.PeerName ?? "Peer"}…");
                sendFolder.Click += (_, _) =>
                {
                    using var dlg = new FolderBrowserDialog { Description = "Folder to send (it goes as a .zip)" };
                    if (dlg.ShowDialog() == DialogResult.OK) m.Files.SendPaths(new[] { dlg.SelectedPath });
                };
                root.DropDownItems.Add(sendFolder);
                if (m.Handoff.OutgoingCount > 0)
                {
                    var back = new ToolStripMenuItem($"Bring Back Handed-off Windows ({m.Handoff.OutgoingCount})");
                    back.Click += (_, _) => m.Handoff.BringBackAll();
                    root.DropDownItems.Add(back);
                }
            }
            if (m.Trust.Peers.Count > 0)
            {
                root.DropDownItems.Add(new ToolStripSeparator());
                var forget = new ToolStripMenuItem("Forget Paired Machines");
                forget.Click += (_, _) =>
                {
                    m.Disconnect();
                    foreach (var p in m.Trust.Peers) m.Trust.Forget(p.Id);
                    OnChange();
                };
                root.DropDownItems.Add(forget);
            }
        }
        return root;
    }

    private static ToolStripMenuItem Disabled(string t) => new(t) { Enabled = false };

    private static string Digits(string s) => new(s.Where(char.IsDigit).ToArray());

    private static void ConnectByAddress(PeerManager m)
    {
        if (Prompt("Connect to a machine by address", $"host or host:port (default port {PeerLimits.DefaultPort})", "192.168.1.20") is not { Length: > 0 } addr) return;
        string pinText = Prompt("Pairing PIN", "The PIN shown on that machine. Leave empty for an already-paired machine.", "") ?? "";
        var (host, port) = ParseHostPort(addr.Trim());
        string d = Digits(pinText);
        m.Connect(host, port, d.Length == 6 ? d : null);
    }

    public static (string Host, ushort Port) ParseHostPort(string s)
    {
        if (s.StartsWith('[') && s.IndexOf(']') is var close and > 0)
        {
            string h = s[1..close];
            return (h, s.Length > close + 2 && ushort.TryParse(s[(close + 2)..], out var bp) ? bp : PeerLimits.DefaultPort);
        }
        int colon = s.LastIndexOf(':');
        if (colon > 0 && s.IndexOf(':') == colon && ushort.TryParse(s[(colon + 1)..], out var p)) return (s[..colon], p);
        return (s, PeerLimits.DefaultPort);
    }

    /// Minimal one-field input dialog (WinForms has none built in).
    public static string? Prompt(string title, string text, string placeholder)
    {
        using var f = new Form
        {
            Text = title, FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterScreen,
            MinimizeBox = false, MaximizeBox = false, ClientSize = new System.Drawing.Size(360, 120), TopMost = true,
        };
        var label = new Label { Text = text, Left = 12, Top = 10, Width = 336, Height = 34 };
        var box = new TextBox { Left = 12, Top = 48, Width = 336, PlaceholderText = placeholder };
        var ok = new Button { Text = "OK", DialogResult = DialogResult.OK, Left = 192, Top = 82, Width = 75 };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Left = 273, Top = 82, Width = 75 };
        f.Controls.AddRange(new Control[] { label, box, ok, cancel });
        f.AcceptButton = ok; f.CancelButton = cancel;
        return f.ShowDialog() == DialogResult.OK ? box.Text : null;
    }
}
