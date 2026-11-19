using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using Clamshell.Auth;

namespace Clamshell;

// `ClamshellServer selftest-gate`: the real stream server on a loopback port, with
// a throwaway host key and a throwaway device list, talked to by real WebSocket
// clients that use the same handshake code as the viewer. Media is switched off
// (no capture, encoder or input injection): what is checked is who gets in and
// that nothing starts before they do. Made-up names only.
internal static class GateSelfTest
{
    private static int _failures;

    private static void Check(bool ok, string what)
    {
        Console.Error.WriteLine($"gate-selftest: {(ok ? "ok  " : "FAIL")} {what}");
        if (!ok) _failures++;
    }

    /// <summary>A viewer-side connection: speaks the protocol by hand so a test can also
    /// break it.</summary>
    private sealed class Client : IDisposable
    {
        public readonly ClientWebSocket Ws = new();
        public readonly MemoryDeviceKey Key;
        public readonly string Id;
        public ClientHandshake? Handshake;
        public SecureSealer? Sealer;
        public SecureOpener? Opener;

        public Client(MemoryDeviceKey key) { Key = key; Id = DeviceIdentity.Id(key.PublicKey); }

        public async Task ConnectAsync(ushort port, string? headerName = null, string? headerValue = null)
        {
            if (headerName != null) Ws.Options.SetRequestHeader(headerName, headerValue);
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            await Ws.ConnectAsync(new Uri($"ws://127.0.0.1:{port}/"), cts.Token);
        }

        /// <summary>The next whole message, or null if the socket closed or nothing came in time.</summary>
        public async Task<byte[]?> ReadAsync(int timeoutMs = 8000)
        {
            using var cts = new CancellationTokenSource(timeoutMs);
            var buf = new byte[64 * 1024];
            using var ms = new MemoryStream();
            try
            {
                WebSocketReceiveResult r;
                do
                {
                    r = await Ws.ReceiveAsync(buf, cts.Token);
                    if (r.MessageType == WebSocketMessageType.Close) return null;
                    ms.Write(buf, 0, r.Count);
                } while (!r.EndOfMessage);
                return ms.ToArray();
            }
            catch (Exception e) when (e is OperationCanceledException or WebSocketException or ObjectDisposedException)
            {
                return null;
            }
        }

        public Task SendAsync(byte[] data) =>
            Ws.SendAsync(data, WebSocketMessageType.Binary, true, CancellationToken.None);

        /// <summary>Reads the challenge and sends a correct response. Null if no challenge came.</summary>
        public async Task<byte[]?> AnswerChallengeAsync()
        {
            var frame = await ReadAsync();
            if (frame == null || frame.Length < 5 || frame[0] != WireType.AuthChallenge) return null;
            var payload = Wire.Slice(frame, 5, frame.Length - 5);
            Handshake = new ClientHandshake(payload, Key.PublicKey, 0, "Example Phone", Key.Sign);
            await SendAsync(Wire.Frame(WireType.AuthResponse, Handshake.Response));
            return payload;
        }

        /// <summary>The status of the next AUTH_RESULT; null if the socket closed or what came
        /// was something else.</summary>
        public async Task<AuthStatus?> ReadResultAsync(int timeoutMs = 8000)
        {
            var frame = await ReadAsync(timeoutMs);
            if (frame == null || frame.Length < 5 || frame[0] != WireType.AuthResult) return null;
            return Handshake!.StatusOfResult(Wire.Slice(frame, 5, frame.Length - 5));
        }

        /// <summary>Reads results until one that is not Pending. Null if the socket closed first.</summary>
        public async Task<AuthStatus?> ReadFinalResultAsync(int timeoutMs = 15000)
        {
            var until = DateTime.UtcNow.AddMilliseconds(timeoutMs);
            while (DateTime.UtcNow < until)
            {
                var s = await ReadResultAsync(2500);
                if (s == null) { if (Ws.State != WebSocketState.Open) return null; continue; }
                if (s != AuthStatus.Pending) return s;
            }
            return null;
        }

        public void StartSecure()
        {
            var keys = Handshake!.DeriveSessionKeys();
            Sealer = new SecureSealer(keys.ClientToHost);
            Opener = new SecureOpener(keys.HostToClient);
        }

        /// <summary>The next sealed message from the host, opened. Null if the socket closed.</summary>
        public async Task<(byte Type, byte[] Payload)?> ReadSecureAsync(int timeoutMs = 8000)
        {
            var frame = await ReadAsync(timeoutMs);
            if (frame == null || frame.Length < 5 || frame[0] != WireType.Secure) return null;
            try { return Opener!.Open(Wire.Slice(frame, 5, frame.Length - 5)); }
            catch (AuthException) { return null; }
        }

        public Task SendSecureAsync(byte type, byte[] payload) =>
            SendAsync(Sealer!.SealMessage(Wire.Frame(type, payload)));

        public bool IsClosed => Ws.State != WebSocketState.Open;

        /// <summary>True when the host closes the socket within a few seconds, whatever else it sent first.</summary>
        public async Task<bool> ClosesAsync(int timeoutMs = 6000)
        {
            var until = DateTime.UtcNow.AddMilliseconds(timeoutMs);
            while (DateTime.UtcNow < until)
            {
                var frame = await ReadAsync(Math.Max(100, (int)(until - DateTime.UtcNow).TotalMilliseconds));
                if (frame == null) return true;
            }
            return false;
        }

        public void Dispose() => Ws.Dispose();
    }

    private static ushort FreePort()
    {
        var l = new TcpListener(IPAddress.Loopback, 0);
        l.Start();
        var port = (ushort)((IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return port;
    }

    private static byte[] HelloFrame() => Wire.Frame(WireType.Hello, new byte[] { 1, (byte)StreamCodec.H264 });

    public static int Run() => RunAsync().GetAwaiter().GetResult();

    private static async Task<int> RunAsync()
    {
        var folder = Path.Combine(Path.GetTempPath(), "clamshell-gate-selftest-" + Guid.NewGuid().ToString("N"));
        var keyName = "Clamshell.Host.GateSelfTest." + Guid.NewGuid().ToString("N");
        HostIdentity? identity = null;
        HostAuth? auth = null;
        StreamServer? server = null;
        try
        {
            identity = HostIdentity.Open(keyName);
            auth = new HostAuth(folder, identity, requireApproval: true, watch: true,
                settingPollInterval: TimeSpan.FromHours(1));
            auth.PendingRepeat = TimeSpan.FromSeconds(1);
            auth.ResponseDeadline = TimeSpan.FromSeconds(3);
            auth.TrustedProxiesOverride = new TrustedProxies();
            var display = new DisplayInfo(0, "SELFTEST", new DisplayRect(0, 0, 1024, 768), true);
            auth.Directory.SetDisplays(new[] { new HostDirectory.DisplayEntry(0, "Display 1", true, 0) });
            ushort port = FreePort();
            server = new StreamServer(display, port, auth, media: false);
            server.Start();
            Check(server.IsListening, "the server is listening on a loopback port");
            if (!server.IsListening) return 1;

            using var phoneKey = new MemoryDeviceKey();
            using var tabletKey = new MemoryDeviceKey();
            using var strangerKey = new MemoryDeviceKey();
            using var proxiedKey = new MemoryDeviceKey();
            byte[] firstResponse = Array.Empty<byte>();

            // An unknown device waits; nothing starts; approving it lets it in.
            using (var phone = new Client(phoneKey))
            {
                await phone.ConnectAsync(port);
                var challenge = await phone.AnswerChallengeAsync();
                Check(challenge != null, "a new connection is sent a challenge first");
                var first = await phone.ReadResultAsync();
                Check(first == AuthStatus.Pending, "an unknown device is told it is pending");
                firstResponse = phone.Handshake?.Response ?? Array.Empty<byte>();
                var again = await phone.ReadResultAsync(5000);
                Check(again == AuthStatus.Pending, "a waiting device is told again that it is still pending");

                await phone.SendAsync(HelloFrame());
                await Task.Delay(500);
                Check(server.SessionsStarted == 0, "nothing started while the device was waiting");
                Check(auth.Store.StateOf(phone.Id) == DeviceState.Waiting, "the device is on the list as waiting");
                var listed = auth.Store.Record(phone.Id);
                Check(listed != null && listed.Address.StartsWith("127.0.0.1", StringComparison.Ordinal),
                    "the listed address is the TCP peer");
                Check(listed != null && listed.ReportedAddress == null,
                    "a connection with no proxy headers has no reported address");
                Check(listed != null && DeviceText.From(listed).Contains("through a local proxy", StringComparison.Ordinal)
                      && !DeviceText.From(listed).Contains("reported", StringComparison.Ordinal),
                    "a loopback peer is shown as coming through a local proxy, with no reported claim");
                Check(DeviceText.From("127.0.0.1", "198.51.100.7")
                      == "127.0.0.1, through a local proxy (the proxy reported 198.51.100.7; not verified)",
                    "a reported address is shown only as an unverified claim next to the peer");
                Check(DeviceTrustStore.StoredReported("203.0.113.5", "203.0.113.5") == null,
                    "a reported address equal to the peer is not stored");

                auth.Store.Decide(phone.Id, DeviceTrustStore.Decision.Approve, DeviceTrustStore.DecidedOnHost, onlyIfWaiting: true);
                var final = await phone.ReadFinalResultAsync();
                Check(final == AuthStatus.Accepted, "approving on the host lets the waiting device in");
                if (final == AuthStatus.Accepted)
                {
                    phone.StartSecure();
                    var info = await phone.ReadSecureAsync();
                    Check(info is { Type: WireType.HostInfo }, "the first sealed message is HOST_INFO");
                    var json = info is { } i ? Encoding.UTF8.GetString(i.Payload) : "";
                    Check(json.Contains("\"kind\":\"windows\""), "HOST_INFO says this host is a Windows PC");
                    Check(json.Contains(auth.Identity.Id), "HOST_INFO carries the host id");
                    Check(server.SessionsStarted == 0, "being accepted does not start a session by itself");

                    await phone.SendSecureAsync(WireType.Hello, new byte[] { 1, (byte)StreamCodec.H264 });
                    var ack = await phone.ReadSecureAsync();
                    Check(ack is { Type: WireType.HelloAck }, "a sealed HELLO is answered with a sealed HELLO_ACK");
                    Check(server.SessionsStarted == 1, "the session started once, after acceptance");
                }
            }
            await Task.Delay(300);

            // A loopback client behind a local proxy: the proxy header is a claim, kept apart
            // from the TCP peer, and the address group follows the claim (group = reported ?? peer).
            using (var proxied = new Client(proxiedKey))
            {
                await proxied.ConnectAsync(port, "CF-Connecting-IP", "198.51.100.7");
                await proxied.AnswerChallengeAsync();
                var st = await proxied.ReadResultAsync();
                Check(st == AuthStatus.Pending, "a device that came with a proxy header is told it is pending");
                var rec = auth.Store.Record(proxied.Id);
                Check(rec != null && rec.Address.StartsWith("127.0.0.1", StringComparison.Ordinal),
                    "behind a proxy header, the device's address is still the TCP peer");
                Check(rec != null && rec.ReportedAddress == "198.51.100.7",
                    "and the address the local proxy reported is kept apart");
                Check(rec != null && DeviceText.From(rec)
                      == "127.0.0.1, through a local proxy (the proxy reported 198.51.100.7; not verified)",
                    "the label says a local proxy reported it, and that it is not verified");
                Check(rec != null && AddressGroup.Of(rec.ReportedAddress ?? rec.Address) == "198.51.100.7",
                    "its address group is the reported address");
                auth.Store.Forget(proxied.Id);
            }
            await Task.Delay(300);

            // A device that was approved gets straight in next time.
            using (var phone = new Client(phoneKey))
            {
                await phone.ConnectAsync(port);
                await phone.AnswerChallengeAsync();
                var s = await phone.ReadResultAsync();
                Check(s == AuthStatus.Accepted, "a trusted device is accepted at once");
                if (s == AuthStatus.Accepted)
                {
                    phone.StartSecure();
                    await phone.ReadSecureAsync(); // HOST_INFO

                    // A sealed frame with one byte changed ends the connection.
                    var good = phone.Sealer!.SealMessage(Wire.Frame(WireType.Ping, Array.Empty<byte>()));
                    good[^1] ^= 0x01;
                    int before = server.SessionsStarted;
                    await phone.SendAsync(good);
                    Check(await phone.ClosesAsync(), "a SECURE frame that was tampered with closes the connection");
                    Check(server.SessionsStarted == before, "and starts nothing");
                }
            }
            await Task.Delay(300);

            // A recorded AUTH_RESPONSE does not work on a new connection (its challenge differs).
            using (var replay = new Client(phoneKey))
            {
                await replay.ConnectAsync(port);
                var frame = await replay.ReadAsync();
                Check(frame != null && frame[0] == WireType.AuthChallenge, "the replay target sends a challenge");
                await replay.SendAsync(Wire.Frame(WireType.AuthResponse, firstResponse));
                bool accepted = false;
                var until = DateTime.UtcNow.AddSeconds(6);
                while (DateTime.UtcNow < until)
                {
                    var f = await replay.ReadAsync(1500);
                    if (f == null) break;
                    if (f.Length >= 5 && f[0] == WireType.AuthResult
                        && AuthResult.Decode(Wire.Slice(f, 5, f.Length - 5)).Status == AuthStatus.Accepted) accepted = true;
                }
                Check(!accepted, "a replayed AUTH_RESPONSE is not accepted");
                Check(replay.IsClosed || await replay.ClosesAsync(), "and the connection is closed");
            }

            // Skipping the handshake gets nothing.
            using (var skip = new Client(tabletKey))
            {
                await skip.ConnectAsync(port);
                var frame = await skip.ReadAsync();
                Check(frame != null && frame[0] == WireType.AuthChallenge, "a client that skips the handshake still gets the challenge");
                int before = server.SessionsStarted;
                await skip.SendAsync(HelloFrame());
                bool gotAck = false;
                var until = DateTime.UtcNow.AddSeconds(4);
                while (DateTime.UtcNow < until)
                {
                    var f = await skip.ReadAsync(1000);
                    if (f == null) break;
                    if (f.Length >= 5 && f[0] == WireType.HelloAck) gotAck = true;
                }
                Check(!gotAck && server.SessionsStarted == before, "HELLO without the handshake gets no answer and starts nothing");
                Check(skip.IsClosed, "and the connection is closed");
            }

            // A response over 4 KB is not read.
            using (var big = new Client(tabletKey))
            {
                await big.ConnectAsync(port);
                await big.ReadAsync();
                await big.SendAsync(Wire.Frame(WireType.AuthResponse, new byte[5000]));
                Check(await big.ClosesAsync(), "an AUTH_RESPONSE over 4 KB closes the connection");
            }

            // A connection that never answers is dropped after the deadline.
            using (var quiet = new Client(tabletKey))
            {
                await quiet.ConnectAsync(port);
                await quiet.ReadAsync();
                Check(await quiet.ClosesAsync(8000), "a connection that never answers the challenge is closed");
            }

            // Deny: the waiting device is told, and told again when it comes back.
            using (var tablet = new Client(tabletKey))
            {
                await tablet.ConnectAsync(port);
                await tablet.AnswerChallengeAsync();
                Check(await tablet.ReadResultAsync() == AuthStatus.Pending, "a second unknown device is pending too");
                auth.Store.Decide(tablet.Id, DeviceTrustStore.Decision.Deny, DeviceTrustStore.DecidedOnHost, onlyIfWaiting: true);
                Check(await tablet.ReadFinalResultAsync() == AuthStatus.Denied, "denying on the host tells the waiting device it is denied");
                Check(await tablet.ClosesAsync(), "and closes its connection");
            }
            using (var tablet = new Client(tabletKey))
            {
                await tablet.ConnectAsync(port);
                await tablet.AnswerChallengeAsync();
                Check(await tablet.ReadResultAsync() == AuthStatus.Denied, "a denied device is denied at once when it comes back");
            }

            // Revoking an accepted device ends its connection.
            using (var phone = new Client(phoneKey))
            {
                await phone.ConnectAsync(port);
                await phone.AnswerChallengeAsync();
                Check(await phone.ReadResultAsync() == AuthStatus.Accepted, "the trusted device connects again");
                phone.StartSecure();
                await phone.ReadSecureAsync();
                auth.Store.Revoke(phone.Id, DeviceTrustStore.DecidedOnHost);
                bool denied = false;
                var until = DateTime.UtcNow.AddSeconds(6);
                while (DateTime.UtcNow < until)
                {
                    var f = await phone.ReadAsync(1500);
                    if (f == null) break;
                    if (f.Length >= 5 && f[0] == WireType.AuthResult
                        && phone.Handshake!.StatusOfResult(Wire.Slice(f, 5, f.Length - 5)) == AuthStatus.Denied) denied = true;
                }
                Check(denied, "revoking an accepted device sends it a signed denial");
                Check(phone.IsClosed, "and closes its connection");
            }

            // An unknown stranger, then the host forgets it while it waits. (The limit on new
            // devices per minute is tested in selftest-store, so it is reset here.)
            auth.Store.ForgetRecentAdds();
            using (var stranger = new Client(strangerKey))
            {
                await stranger.ConnectAsync(port);
                await stranger.AnswerChallengeAsync();
                Check(await stranger.ReadResultAsync() == AuthStatus.Pending, "a stranger waits");
                auth.Store.Forget(stranger.Id);
                var s = await stranger.ReadFinalResultAsync();
                Check(s == AuthStatus.Timeout, "a waiting device removed from the list is told to try again later");
            }

            // With approval off, the old way in works; turning it on closes it.
            auth.OverrideRequireApproval(false);
            using (var legacy = new Client(strangerKey))
            {
                await legacy.ConnectAsync(port);
                await legacy.ReadAsync(); // challenge
                int before = server.SessionsStarted;
                await legacy.SendAsync(HelloFrame());
                var ack = await legacy.ReadAsync();
                Check(ack != null && ack.Length >= 5 && ack[0] == WireType.HelloAck, "with approval off a plain HELLO is answered");
                Check(server.SessionsStarted == before + 1, "and starts a session");
                auth.OverrideRequireApproval(true);
                Check(await legacy.ClosesAsync(), "turning approval on closes a connection that has no device behind it");
            }
            using (var skip = new Client(strangerKey))
            {
                await skip.ConnectAsync(port);
                await skip.ReadAsync();
                int before = server.SessionsStarted;
                await skip.SendAsync(HelloFrame());
                await Task.Delay(500);
                Check(server.SessionsStarted == before, "with approval back on a plain HELLO starts nothing again");
            }
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"gate-selftest: FAIL unexpected {e.GetType().Name}: {e.Message}");
            _failures++;
        }
        finally
        {
            try { server?.Dispose(); } catch (Exception) { }
            try { auth?.Dispose(); } catch (Exception) { }
            try { identity?.DeleteFromStore(); } catch (Exception) { }
            identity?.Dispose();
            try { Directory.Delete(folder, true); } catch (Exception) { }
        }
        Console.Error.WriteLine($"gate-selftest: {(_failures == 0 ? "all checks passed" : _failures + " failed")}");
        return _failures == 0 ? 0 : 1;
    }
}
