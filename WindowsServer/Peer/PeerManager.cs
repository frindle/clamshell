using System.Text.Json;

namespace Clamshell;

// Wires the peer link to the shared-desk features on this PC — the twin of
// PeerManager.swift + PeerFeatures.swift: the edge hooks (this PC controls
// the peer), the input sink (the peer controls this PC), clipboard sync,
// file transfer and window handoff, plus mDNS discovery and auto-reconnect.
//
// Construct and use on the UI thread: PeerLink / discovery callbacks are
// posted back to the SynchronizationContext captured here.
internal sealed class PeerManager : IDisposable
{
    public PeerIdentity Identity { get; }
    public PeerTrustStore Trust { get; }
    public PeerLink Link { get; }
    public EdgeController Edge { get; }
    public RemoteInputSink Sink { get; } = new();
    public PeerClipboard Clipboard { get; } = new();
    public FileTransfer Files { get; }
    public HandoffManager Handoff { get; } = new();
    public PeerDiscovery Discovery { get; } = new();
    public PeerLinkState State { get; private set; } = PeerLinkState.Idle;
    public IReadOnlyList<PeerDiscovery.Found> Discovered { get; private set; } = Array.Empty<PeerDiscovery.Found>();
    public (double W, double H)? PeerScreen { get; private set; }
    public string? PeerHost { get; private set; }
    public string? PeerName { get; private set; }
    public Action OnChange = () => { };

    private readonly SynchronizationContext _ui;
    private readonly string _name;
    private bool _autoConnect = true;
    private System.Windows.Forms.Timer? _reconnect;

    public PeerManager(PeerIdentity identity, PeerTrustStore trust, string name, ushort port, PeerEdge edge, string downloads)
    {
        _ui = WinNative.UiContext();
        Identity = identity; Trust = trust; _name = name;
        Link = new PeerLink(identity, trust, name, port, () =>
        {
            var b = WinNative.PrimaryDisplay();
            return ((uint)Math.Max(b.W, 1), (uint)Math.Max(b.H, 1));
        });
        Edge = new EdgeController(edge);
        Files = new FileTransfer(downloads);
        Wire();
    }

    // MARK: - Settings (edge, enabled) next to the identity key

    public sealed record Settings(bool Enabled = false, PeerEdge Edge = PeerEdge.Right);

    public static string SettingsPath => Path.Combine(PeerIdentity.DefaultDirectory, "shared-desk.json");

    public static Settings LoadSettings()
    {
        try { return JsonSerializer.Deserialize<Settings>(File.ReadAllText(SettingsPath)) ?? new(); }
        catch { return new(); }
    }

    public static void SaveSettings(Settings s)
    {
        try
        {
            Directory.CreateDirectory(PeerIdentity.DefaultDirectory);
            File.WriteAllText(SettingsPath, JsonSerializer.Serialize(s));
        }
        catch (Exception e) { Log.Line($"PEER: could not save settings: {e.Message}"); }
    }

    public static PeerManager MakeDefault(PeerEdge edge, ushort port = PeerLimits.DefaultPort)
    {
        string dir = PeerIdentity.DefaultDirectory;
        var identity = PeerIdentity.LoadOrCreate(Path.Combine(dir, "peer-identity.key"));
        var trust = new PeerTrustStore(Path.Combine(dir, "peer-trust.json"));
        return new PeerManager(identity, trust, Environment.MachineName, port, edge, FileTransfer.DownloadsDirectory);
    }

    // MARK: - Wiring

    private void Ui(Action a) => _ui.Post(_ => { try { a(); } catch (Exception e) { Log.Line($"PEER: {e}"); } }, null);

    private void Wire()
    {
        Link.OnStateChange += s => { string? host = Link.RemoteHost; Ui(() => LinkStateChanged(s, host)); };
        Link.OnMessage += (t, p) => Ui(() => Route(t, p));
        Discovery.OnChange += list => Ui(() => { Discovered = list; MaybeAutoConnect(); OnChange(); });

        Edge.Send = d => Link.Send(d);
        Edge.PeerSize = () => PeerScreen;
        Edge.OnControlChange = _ => OnChange();
        Sink.OnActiveChange = _ => OnChange();

        Clipboard.Send = d => Link.Send(d);
        Files.Send = (d, done) => Link.Send(d, done);
        Files.OnReceived = path => Ui(() =>
        {
            try { System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{path}\""); }
            catch (Exception e) { Log.Line($"PEER: could not reveal {path}: {e.Message}"); }
        });
        Files.OnFailed = msg => Log.Line($"PEER: transfer failed: {msg}");

        Handoff.Send = d => Link.Send(d);
        Handoff.PeerHost = () => PeerHost;
        // The carrying drag: the peer's injected button while it drives this
        // PC, else the physical one.
        Handoff.IsCarryHeld = () => Sink.Active ? Sink.Carrying : WinNative.LeftButtonDown();
        Handoff.OnChange = () => OnChange();
        Edge.Carry.ReceiverLookup = h => Handoff.SourceWindowId(h);
        Sink.Carry.ReceiverLookup = h => Handoff.SourceWindowId(h);

        // Drag-and-drop: files carried across go when the button is released
        // on the peer (this PC drove the drag) or as soon as the peer's
        // cursor leaves (the peer drove a drag that started here). A window
        // is handed off the moment it crosses; a receiver crossing goes home.
        Edge.OnCarryCrossed = (c, edge, f) => Carried(c, edge, f);
        Edge.OnCarryDropped = c => { if (c is Carry.Files files) Files.SendPaths(files.Paths); };
    }

    private void Carried(Carry c, PeerEdge peerEdge, double fraction)
    {
        switch (c)
        {
            case Carry.Window w: Handoff.Begin(w, peerEdge, fraction); break;
            case Carry.Receiver r: Handoff.ReturnReceiver(r.SourceWindowId, peerEdge, fraction); break;
        }
    }

    public void Start()
    {
        Link.StartListening();
        try { Discovery.Start(_name, Identity.Id, Link.Port); }
        catch (Exception e) { Log.Line($"PEER: mDNS unavailable ({e.Message}) — connect by address instead"); }
        if (!Edge.Start()) Log.Line("PEER: edge hooks unavailable — this PC can be controlled but can't control the peer");
        Log.Line($"PEER: pairing PIN for this PC: {Link.PairingPin}");
    }

    public void Dispose()
    {
        _reconnect?.Dispose();
        Edge.Dispose();
        Sink.Dispose();
        Clipboard.Stop();
        Handoff.Reset();
        Files.Reset();
        Discovery.Dispose();
        Link.Stop();
    }

    public void Connect(PeerDiscovery.Found p, string? pin) { _autoConnect = true; Link.Connect(p.Host, p.Port, pin, p.Name); }
    public void Connect(string host, ushort port, string? pin) { _autoConnect = true; Link.Connect(host, port, pin); }
    public void Disconnect() { _autoConnect = false; Link.Disconnect(); }

    public void SetEdge(PeerEdge e)
    {
        Edge.SetEdge(e);
        SaveSettings(LoadSettings() with { Edge = e });
        OnChange();
    }

    // MARK: - Link state

    private void LinkStateChanged(PeerLinkState s, string? host)
    {
        bool wasLinked = State.IsLinked;
        State = s;
        if (s.IsLinked)
        {
            PeerScreen = (s.ScreenWidth, s.ScreenHeight);
            PeerHost = host;
            PeerName = s.Peer?.Name;
            Clipboard.Start();
        }
        else if (wasLinked)
        {
            PeerScreen = null; PeerName = null;
            Edge.ReturnHome(0.5, notifyPeer: false);
            Sink.Reset();
            Clipboard.Stop();
            Files.Reset();
            Handoff.Reset();
            ScheduleReconnect();
        }
        else if (s.Phase == PeerLinkPhase.Failed) ScheduleReconnect();
        OnChange();
    }

    /// Only the side with the smaller peer id dials, so two machines that
    /// both see each other don't knock each other's link down.
    private void MaybeAutoConnect()
    {
        if (!_autoConnect || State.IsLinked || State.Phase is PeerLinkPhase.Connecting or PeerLinkPhase.Handshaking) return;
        foreach (var p in Discovered)
        {
            if (p.Id is not { } id || Trust.Peer(id) is null || string.CompareOrdinal(Identity.Id, id) >= 0) continue;
            Log.Line($"PEER: auto-connecting to trusted {p.Name}");
            Link.Connect(p.Host, p.Port, null, p.Name);
            return;
        }
    }

    private void ScheduleReconnect()
    {
        _reconnect?.Dispose();
        var t = new System.Windows.Forms.Timer { Interval = 3000 };
        t.Tick += (_, _) => { t.Dispose(); if (_reconnect == t) _reconnect = null; MaybeAutoConnect(); };
        _reconnect = t;
        t.Start();
    }

    // MARK: - Routing

    private void Route(MessageType t, byte[] p)
    {
        switch (t)
        {
            case MessageType.EdgeEnter:
                if (PeerParse.EdgeEnter(p) is not { } e) return;
                // Whoever crossed last wins; our own crossing is abandoned.
                Edge.ReturnHome(0.5, notifyPeer: false);
                Sink.Enter(e);
                break;
            case MessageType.EdgeLeave:
            {
                var entry = Sink.EntryEdge;
                Sink.Leave((carry, fraction) =>
                {
                    if (carry is null) return;
                    if (carry is Carry.Files f) Files.SendPaths(f.Paths);
                    Carried(carry, entry.Opposite(), fraction);
                });
                break;
            }
            case MessageType.MouseMove or MessageType.MouseButton or MessageType.Key or MessageType.Scroll:
                Sink.Handle(t, p);
                break;
            default:
                if (Clipboard.Receive(t, p)) return;
                if (Files.Receive(t, p)) return;
                Handoff.Receive(t, p);
                break;
        }
    }

    public string StatusLine => State.Phase switch
    {
        PeerLinkPhase.Idle => "Not linked",
        PeerLinkPhase.Connecting => $"Connecting to {State.Label}…",
        PeerLinkPhase.Handshaking => $"Pairing with {State.Label}…",
        PeerLinkPhase.Linked when Edge.IsControllingPeer => $"Controlling {PeerName}",
        PeerLinkPhase.Linked when Sink.Active => $"{PeerName} is controlling this PC",
        PeerLinkPhase.Linked => $"Linked with {PeerName}",
        _ => $"Link failed: {State.Label}",
    };
}
