// Interop check: the C# client flow (WindowsShared/) against the real Mac host.
//
//   dotnet run --project tests/WindowsViewerInterop -c Release -- <path to the Clamshell binary> <port>
//
// Starts `Clamshell auth-interop-host <port>` (loopback only, device approval
// on, nothing captured or typed) with a temporary state directory, then drives
// the same ClientAuthFlow the Windows viewer uses, over a plain ClientWebSocket
// and an in-memory device key:
//   1. connects and reaches "waiting for approval" with a verified pending;
//   2. runs `Clamshell approve <fingerprint>` and reaches "connected, verified"
//      on the same connection, and the Mac is saved in a temporary saved-Macs file;
//   3. the sealed first message (a PING in place of HELLO, so no capture starts)
//      is answered by a sealed PING: the sealed session works both ways;
//   4. runs `Clamshell revoke <fingerprint>` and sees the host close the connection;
//   5. connects again with the same key and reaches "turned away" (denied).
// The host and the directories are removed at the end, also on failure. Exit 0
// only if every step passed. There is no HELLO_ACK: this host has no video.
using System.Diagnostics;
using System.Net.WebSockets;
using Clamshell.Auth;

class Failure : Exception { public Failure(string m) : base(m) { } }

static class Interop
{
    static void Check(bool ok, string what) { if (!ok) throw new Failure($"expected that {what}"); }

    /// <summary>One connection driven by one flow. Everything the flow says is recorded.</summary>
    sealed class Run : IDisposable
    {
        readonly ClientWebSocket _ws = new();
        readonly ClientAuthFlow _flow;
        readonly KnownHostsFile _file;
        readonly object _lock = new();
        readonly List<FlowState> _states = new();
        readonly List<byte> _delivered = new();
        readonly Dictionary<FlowTimer, CancellationTokenSource> _timers = new();
        readonly CancellationTokenSource _cts = new();
        public bool SocketEnded;
        public string EndedWhy = "";
        public FlowEnd? End;

        public Run(IDeviceKey key, KnownHostsFile file, string url)
        {
            _file = file;
            var config = new ClientAuthConfig
            {
                DeviceKey = key.PublicKey,
                Sign = key.Sign,
                DeviceName = "Interop test PC",
                AppName = "windows",
                AppVersion = "0",
                DialledUrl = url,
                // A PING in place of HELLO: this host has no video, and a HELLO would start capture.
                MakeHello = () => Wire.Frame(WireType.Ping, Array.Empty<byte>()),
            };
            // The first challenge from a freshly started host can take longer than the
            // product's 2 s wait (it makes its identity on first use); give the test 20 s.
            _flow = new ClientAuthFlow(config, file.Load(), new FlowCarry { ChallengeWait = 20 });
        }

        public async Task Start(string url)
        {
            await _ws.ConnectAsync(new Uri(url), _cts.Token);
            _ = ReceiveLoop();
            Step(f => f.Opened());
        }

        void Step(Func<ClientAuthFlow, List<FlowAction>> go)
        {
            lock (_lock)
            {
                foreach (var a in go(_flow)) Do(a);
            }
        }

        void Do(FlowAction a)
        {
            switch (a.Kind)
            {
                case FlowActionKind.Send:
                    _ = _ws.SendAsync(new ArraySegment<byte>(a.Bytes), WebSocketMessageType.Binary, true, CancellationToken.None);
                    break;
                case FlowActionKind.StartTimer:
                    {
                        if (_timers.Remove(a.Timer, out var old)) old.Cancel();
                        var src = new CancellationTokenSource();
                        _timers[a.Timer] = src;
                        var timer = a.Timer;
                        _ = Task.Run(async () =>
                        {
                            try { await Task.Delay(TimeSpan.FromSeconds(a.Seconds), src.Token); }
                            catch (OperationCanceledException) { return; }
                            Step(f => f.TimerFired(timer));
                        });
                        break;
                    }
                case FlowActionKind.CancelTimer:
                    if (_timers.Remove(a.Timer, out var t)) t.Cancel();
                    break;
                case FlowActionKind.State:
                    _states.Add(a.State!);
                    Console.WriteLine($"  state: {a.State} message={a.State!.Message}");
                    break;
                case FlowActionKind.Deliver:
                    _delivered.Add(a.MessageType);
                    break;
                case FlowActionKind.Change:
                    _file.Apply(a.Change!, DateTimeOffset.UtcNow.ToUnixTimeSeconds());
                    break;
                case FlowActionKind.Close:
                    Console.WriteLine($"  close: {a.Reason}");
                    try { _ws.Abort(); } catch { }
                    break;
                case FlowActionKind.End:
                    End = a.End;
                    Console.WriteLine($"  end: {a.End} reason={a.Reason}");
                    break;
            }
        }

        async Task ReceiveLoop()
        {
            var buf = new byte[64 * 1024];
            try
            {
                while (_ws.State == WebSocketState.Open)
                {
                    using var ms = new MemoryStream();
                    WebSocketReceiveResult r;
                    do
                    {
                        r = await _ws.ReceiveAsync(new ArraySegment<byte>(buf), _cts.Token);
                        if (r.MessageType == WebSocketMessageType.Close) { Ended("host closed the connection"); return; }
                        ms.Write(buf, 0, r.Count);
                    } while (!r.EndOfMessage);
                    var frame = ms.ToArray();
                    Check(frame.Length >= 5, "a message is framed");
                    var payload = new byte[frame.Length - 5];
                    Array.Copy(frame, 5, payload, 0, payload.Length);
                    var type = frame[0];
                    Console.WriteLine($"  received type 0x{type:x2}, {payload.Length} bytes");
                    Step(f => f.Received(type, payload));
                }
            }
            catch (Exception e) { Ended(e.Message); return; }
            Ended("socket not open");
        }

        void Ended(string why)
        {
            lock (_lock)
            {
                SocketEnded = true;
                EndedWhy = why;
            }
            Step(f => f.SocketClosed());
        }

        public async Task<FlowState> WaitState(FlowStateKind kind, int ms = 15000)
        {
            var until = DateTime.UtcNow.AddMilliseconds(ms);
            while (DateTime.UtcNow < until)
            {
                lock (_lock)
                {
                    var hit = _states.FirstOrDefault(s => s.Kind == kind);
                    if (hit != null) return hit;
                }
                await Task.Delay(50);
            }
            string seen;
            lock (_lock) seen = string.Join(", ", _states.Select(s => s.Kind));
            throw new Failure($"state {kind} did not arrive in {ms} ms (seen: {seen}; socket: {EndedWhy})");
        }

        public async Task WaitDelivered(byte type, int ms = 15000)
        {
            var until = DateTime.UtcNow.AddMilliseconds(ms);
            while (DateTime.UtcNow < until)
            {
                lock (_lock) if (_delivered.Contains(type)) return;
                await Task.Delay(50);
            }
            throw new Failure($"message type {type} was not delivered in {ms} ms");
        }

        public async Task WaitSocketEnded(int ms)
        {
            var until = DateTime.UtcNow.AddMilliseconds(ms);
            while (DateTime.UtcNow < until)
            {
                lock (_lock) if (SocketEnded) return;
                await Task.Delay(50);
            }
            throw new Failure($"the host did not close the connection within {ms} ms");
        }

        public void Dispose()
        {
            foreach (var t in _timers.Values) t.Cancel();
            _cts.Cancel();
            try { _ws.Abort(); } catch { }
            _ws.Dispose();
        }
    }

    static (int Code, string Out) Cli(string binary, string stateDir, params string[] args)
    {
        var psi = new ProcessStartInfo(binary) { RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var a in args) psi.ArgumentList.Add(a);
        psi.Environment["CLAMSHELL_STATE_DIR"] = stateDir;
        using var p = Process.Start(psi)!;
        var text = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
        p.WaitForExit();
        return (p.ExitCode, text.Trim());
    }

    static async Task Main2(string binary, int port)
    {
        var stateDir = Path.Combine(Path.GetTempPath(), "clamshell-cs-interop-" + Guid.NewGuid().ToString("N"));
        var savedDir = Path.Combine(Path.GetTempPath(), "clamshell-cs-saved-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(stateDir);
        Directory.CreateDirectory(savedDir);
        Process? host = null;
        var runs = new List<Run>();
        try
        {
            var psi = new ProcessStartInfo(binary) { RedirectStandardOutput = true, RedirectStandardError = true };
            psi.ArgumentList.Add("auth-interop-host");
            psi.ArgumentList.Add(port.ToString());
            psi.Environment["CLAMSHELL_STATE_DIR"] = stateDir;
            host = Process.Start(psi)!;
            var hostOut = new System.Text.StringBuilder();
            host.OutputDataReceived += (_, e) => { if (e.Data != null) lock (hostOut) hostOut.AppendLine(e.Data); };
            host.ErrorDataReceived += (_, _) => { };
            host.BeginOutputReadLine();
            host.BeginErrorReadLine();
            var started = DateTime.UtcNow;
            while (true)
            {
                string so; lock (hostOut) so = hostOut.ToString();
                if (so.Contains("listening")) break;
                Check(!host.HasExited, $"the host stayed up (it said: {so.Trim()})");
                Check((DateTime.UtcNow - started).TotalSeconds < 30, "the host started within 30 s");
                await Task.Delay(100);
            }

            var url = $"ws://127.0.0.1:{port}/";
            using var key = new MemoryDeviceKey();
            var fingerprint = DeviceIdentity.FingerprintOfKey(key.PublicKey);
            var file = new KnownHostsFile(savedDir);

            // 1: connect; the host asks for approval and says pending.
            var one = new Run(key, file, url);
            runs.Add(one);
            await one.Start(url);
            var waiting = await one.WaitState(FlowStateKind.WaitingForApproval);
            Check(waiting.DeviceFingerprint == fingerprint, "the waiting screen shows this PC's fingerprint");
            Check(waiting.HostFingerprint.Length > 0, "the waiting screen shows the Mac's fingerprint");
            Console.WriteLine($"ok 1: verified pending for {fingerprint}");

            // 2: approve on the host; the same connection is accepted and verified.
            var approve = Cli(binary, stateDir, "approve", fingerprint);
            Check(approve.Code == 0, $"approve exits 0 ({approve.Out})");
            var connected = await one.WaitState(FlowStateKind.Connected);
            Check(connected.Verified, "the session is verified");
            var saved = file.Load();
            Check(saved.Hosts.Count == 1, "the Mac was saved after the verified accept");
            Console.WriteLine("ok 2: approved on the host, accepted and verified on the same connection");

            // 3: the sealed session works both ways.
            await one.WaitDelivered(WireType.Ping);
            Console.WriteLine("ok 3: sealed message sent, sealed PING came back");

            // 4: revoke on the host; it closes the connection.
            var revoke = Cli(binary, stateDir, "revoke", fingerprint);
            Check(revoke.Code == 0, $"revoke exits 0 ({revoke.Out})");
            await one.WaitSocketEnded(5000);
            Console.WriteLine("ok 4: host closed the connection after revoke");

            // 5: the same key again is turned away.
            var two = new Run(key, file, url);
            runs.Add(two);
            await two.Start(url);
            await two.WaitState(FlowStateKind.Denied);
            Console.WriteLine("ok 5: a revoked device is turned away, verified");
        }
        finally
        {
            foreach (var r in runs) r.Dispose();
            if (host != null && !host.HasExited)
            {
                try { host.Kill(); host.WaitForExit(6000); } catch { }
            }
            try { Directory.Delete(stateDir, true); } catch { }
            try { Directory.Delete(savedDir, true); } catch { }
        }
    }

    static async Task<int> Main(string[] args)
    {
        try
        {
            Check(args.Length == 2 && int.TryParse(args[1], out var p) && p >= 1024, "the binary path and a port were given");
            await Main2(args[0], int.Parse(args[1]));
            Console.WriteLine("PASS: the C# client flow and the Mac host agree");
            return 0;
        }
        catch (Exception e)
        {
            Console.WriteLine($"FAIL: {e.Message}");
            return 1;
        }
    }
}
