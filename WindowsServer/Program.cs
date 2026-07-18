using Clamshell;

// Clamshell Windows host server. Headless: run it, it serves one WebSocket
// endpoint per display at basePort+index (main display = index 0 = base port),
// speaking the exact wire protocol in PROTOCOL.md so the existing iOS clients
// connect to a Windows host with zero changes. Ctrl-C to stop.
//
// Usage: ClamshellServer [basePort]   (default 5903)

if (args.Length > 0 && args[0] == "selftest") return SelfTest.Run();

ushort basePort = Proto.DefaultPort;
if (args.Length > 0 && ushort.TryParse(args[0], out var p)) basePort = p;

var displays = DisplayEnum.Active();
Log.Line($"found {displays.Count} display(s); base port {basePort}");
foreach (var d in displays)
    Log.Line($"  display {d.Index}{(d.IsPrimary ? " (primary)" : "")}: " +
             $"{d.Bounds.Width}x{d.Bounds.Height} at ({d.Bounds.X},{d.Bounds.Y}) -> ws port {d.Port(basePort)}");

// One probe at startup: is a hardware H.264/HEVC encoder MFT present on this
// system at all? Cached and reused by every per-display encoder so the
// HELLO_ACK warning bit means "hardware failed", not "no passthrough". See
// EncoderProbe / PROTOCOL.md note on the flags byte.
EncoderProbe.Run();

using var cts = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };

var servers = displays
    .Select(d => new StreamServer(d, basePort))
    .ToList();
foreach (var s in servers) s.Start();

Log.Line("serving — press Ctrl-C to stop");
try { await Task.Delay(Timeout.Infinite, cts.Token); }
catch (OperationCanceledException) { }

Log.Line("stopping");
foreach (var s in servers) s.Dispose();
return 0;
