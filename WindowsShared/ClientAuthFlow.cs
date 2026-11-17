using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Clamshell.Auth;

// The client's side of one connection, as a state machine with no socket, no
// clock and no storage in it (PROTOCOL.md "Client rules"). The caller feeds it
// events (the socket opened, a message arrived, a timer ran out, the user
// answered, the app wants to send) and does what the returned actions say. One
// value is one connection attempt; the next attempt is a new value. Ported from
// Sources/Clamshell/Streaming/ClientAuthFlow.swift. Not thread-safe: the caller
// feeds it from one place at a time, in order.

public enum FlowTimer
{
    /// <summary>Waiting for AUTH_CHALLENGE after the socket opened (2 s, or 10 s).</summary>
    Challenge,
    /// <summary>Waiting for the first AUTH_RESULT after the response was sent (15 s).</summary>
    Result,
    /// <summary>Waiting for the next AUTH_RESULT while the host says pending (60 s).</summary>
    Pending,
}

/// <summary>What carries over from one attempt to the next.</summary>
public sealed class FlowCarry
{
    /// <summary>Seconds to wait for a challenge: 2, or 10 after a late challenge.</summary>
    public double ChallengeWait { get; set; } = ClientAuthFlow.ChallengeWaitSeconds;
    /// <summary>The wait before the next try after busy (or a second timeout).</summary>
    public double BusyDelay { get; set; } = ClientAuthFlow.BusyFirstDelay;
    /// <summary>True once a timeout was answered with an immediate reconnect.</summary>
    public bool TimeoutRetried { get; set; }

    public FlowCarry Clone() => (FlowCarry)MemberwiseClone();

    public bool SameAs(FlowCarry other) =>
        ChallengeWait == other.ChallengeWait && BusyDelay == other.BusyDelay && TimeoutRetried == other.TimeoutRetried;
}

public enum FlowEndKind
{
    /// <summary>Close and do not connect again unless the user asks.</summary>
    Stop,
    /// <summary>Close; the caller's own backoff decides when to try again.</summary>
    Failure,
    /// <summary>Close and connect again after After seconds, carrying Carry.</summary>
    Reconnect,
}

public sealed class FlowEnd
{
    public FlowEndKind Kind { get; }
    public double After { get; }
    public FlowCarry Carry { get; }

    private FlowEnd(FlowEndKind kind, double after, FlowCarry carry) { Kind = kind; After = after; Carry = carry; }

    public static FlowEnd Stop() => new(FlowEndKind.Stop, 0, new FlowCarry());
    public static FlowEnd Failure() => new(FlowEndKind.Failure, 0, new FlowCarry());
    public static FlowEnd Reconnect(double after, FlowCarry carry) => new(FlowEndKind.Reconnect, after, carry.Clone());

    public override string ToString() => Kind == FlowEndKind.Reconnect ? $"Reconnect({After})" : Kind.ToString();
}

public enum FlowStateKind
{
    Connecting,
    /// <summary>The host said pending: the owner has to approve this device on the Mac.</summary>
    WaitingForApproval,
    /// <summary>Rule 12: the host let this device in without asking.</summary>
    ConfirmHost,
    /// <summary>Rule 4.</summary>
    ChangedIdentity,
    /// <summary>Rule 5.</summary>
    DidNotIdentify,
    /// <summary>Rule 6: asks whether to connect with no proof of who answers.</summary>
    AskUnverified,
    Denied,
    Invalid,
    Busy,
    Connected,
    Failed,
}

/// <summary>What the screen shows. Values only: no key, signature or message content.</summary>
public sealed class FlowState
{
    public FlowStateKind Kind { get; private init; }
    public string HostName { get; private init; } = "";
    public string HostFingerprint { get; private init; } = "";
    public string DeviceName { get; private init; } = "";
    public string DeviceFingerprint { get; private init; } = "";
    public string Address { get; private init; } = "";
    public string SavedFingerprint { get; private init; } = "";
    public string NowFingerprint { get; private init; } = "";
    public int RetryIn { get; private init; }
    public bool Verified { get; private init; }
    public string Message { get; private init; } = "";

    private FlowState() { }

    public static FlowState Connecting() => new() { Kind = FlowStateKind.Connecting };
    public static FlowState WaitingForApproval(string hostName, string hostFingerprint, string deviceName, string deviceFingerprint) =>
        new() { Kind = FlowStateKind.WaitingForApproval, HostName = hostName, HostFingerprint = hostFingerprint,
                DeviceName = deviceName, DeviceFingerprint = deviceFingerprint };
    public static FlowState ConfirmHost(string hostName, string fingerprint) =>
        new() { Kind = FlowStateKind.ConfirmHost, HostName = hostName, HostFingerprint = fingerprint };
    public static FlowState ChangedIdentity(string address, string savedFingerprint, string nowFingerprint) =>
        new() { Kind = FlowStateKind.ChangedIdentity, Address = address, SavedFingerprint = savedFingerprint, NowFingerprint = nowFingerprint };
    public static FlowState DidNotIdentify(string hostName) => new() { Kind = FlowStateKind.DidNotIdentify, HostName = hostName };
    public static FlowState AskUnverified(string address) => new() { Kind = FlowStateKind.AskUnverified, Address = address };
    public static FlowState Denied(string hostName) => new() { Kind = FlowStateKind.Denied, HostName = hostName };
    public static FlowState Invalid(string hostName) => new() { Kind = FlowStateKind.Invalid, HostName = hostName };
    public static FlowState Busy(int retryIn) => new() { Kind = FlowStateKind.Busy, RetryIn = retryIn };
    public static FlowState Connected(bool verified, string hostName) =>
        new() { Kind = FlowStateKind.Connected, Verified = verified, HostName = hostName };
    public static FlowState Failed(string message) => new() { Kind = FlowStateKind.Failed, Message = message };

    public override string ToString() => $"{Kind} host={HostName} verified={Verified} retryIn={RetryIn}";
}

public enum FlowActionKind
{
    Send,
    StartTimer,
    CancelTimer,
    State,
    Deliver,
    Change,
    HostCapabilities,
    Close,
    End,
}

public sealed class FlowAction
{
    public FlowActionKind Kind { get; private init; }
    /// <summary>Send: bytes for the socket, already framed.</summary>
    public byte[] Bytes { get; private init; } = Array.Empty<byte>();
    public FlowTimer Timer { get; private init; }
    public double Seconds { get; private init; }
    public FlowState? State { get; private init; }
    /// <summary>Deliver: an inner message for the app (never HOST_INFO, which the flow keeps).</summary>
    public byte MessageType { get; private init; }
    public byte[] Payload { get; private init; } = Array.Empty<byte>();
    public KnownHostsChange? Change { get; private init; }
    /// <summary>HostCapabilities: what the host offers. 0 until accepted is verified and again when the connection ends.</summary>
    public uint Capabilities { get; private init; }
    /// <summary>Close and End: a reason for the log (no secrets in it).</summary>
    public string Reason { get; private init; } = "";
    public FlowEnd? End { get; private init; }

    private FlowAction() { }

    public static FlowAction Send(byte[] bytes) => new() { Kind = FlowActionKind.Send, Bytes = bytes };
    public static FlowAction StartTimer(FlowTimer timer, double seconds) => new() { Kind = FlowActionKind.StartTimer, Timer = timer, Seconds = seconds };
    public static FlowAction CancelTimer(FlowTimer timer) => new() { Kind = FlowActionKind.CancelTimer, Timer = timer };
    public static FlowAction ShowState(FlowState state) => new() { Kind = FlowActionKind.State, State = state };
    public static FlowAction Deliver(byte type, byte[] payload) => new() { Kind = FlowActionKind.Deliver, MessageType = type, Payload = payload };
    public static FlowAction ChangeStore(KnownHostsChange change) => new() { Kind = FlowActionKind.Change, Change = change };
    public static FlowAction HostCaps(uint caps) => new() { Kind = FlowActionKind.HostCapabilities, Capabilities = caps };
    /// <summary>Close the socket now. The flow lives on, waiting for the user's answer (rule 12);
    /// the caller must not report that close back as SocketClosed.</summary>
    public static FlowAction Close(string reason) => new() { Kind = FlowActionKind.Close, Reason = reason };
    /// <summary>The connection is over.</summary>
    public static FlowAction Ended(FlowEnd end, string reason) => new() { Kind = FlowActionKind.End, End = end, Reason = reason };
}

public sealed class ClientAuthConfig
{
    /// <summary>The device's 65-byte public key.</summary>
    public byte[] DeviceKey { get; set; } = Array.Empty<byte>();
    public AuthSigner Sign { get; set; } = _ => throw new InvalidOperationException("no signer");
    public string DeviceName { get; set; } = "";
    public string FallbackDeviceName { get; set; } = "PC";
    public uint Capabilities { get; set; } = ClientAuthFlow.DefaultCapabilities;
    public string AppName { get; set; } = "windows";
    public string AppVersion { get; set; } = "";
    /// <summary>The WebSocket URL actually dialled.</summary>
    public string DialledUrl { get; set; } = "";
    /// <summary>A whole HELLO message (framed). Called when HELLO is sent.</summary>
    public Func<byte[]> MakeHello { get; set; } = () => Array.Empty<byte>();
    /// <summary>For tests: response extensions, a fixed ephemeral key and a fixed nonce.
    /// The app sends no extension and uses random values (null).</summary>
    public IReadOnlyList<AuthExtension> Extensions { get; set; } = Array.Empty<AuthExtension>();
    public EphemeralKey? Ephemeral { get; set; }
    public byte[]? Nonce { get; set; }
}

public sealed class ClientAuthFlow
{
    public const double ChallengeWaitSeconds = 2;
    public const double LateChallengeWait = 10;
    public const double ResultWait = 15;
    public const double PendingWait = 60;
    public const double BusyFirstDelay = 15;
    public const double BusyMaxDelay = 120;
    /// <summary>The bits this viewer honours today: none. Bits 4 to 6 stay 0.</summary>
    public const uint DefaultCapabilities = 0;

    private enum Phase
    {
        Idle,
        AwaitingChallenge,
        AskingUnverified,
        /// <summary>HELLO went out in the clear (rule 6).</summary>
        ClearSession,
        AwaitingResult,
        Pending,
        /// <summary>Rule 12: closed, waiting for the user.</summary>
        AskingHost,
        Secure,
        Ended,
    }

    private readonly ClientAuthConfig _config;
    private readonly KnownHosts _known;
    private readonly FlowCarry _carry;
    private readonly string? _address;
    private readonly AddressStanding _standing;

    private Phase _phase = Phase.Idle;
    private ClientHandshake? _handshake;
    private bool _waitingShown;
    private bool _bound;
    private SecureSealer? _sealer;
    private SecureOpener? _opener;
    private bool _capsPublished;

    public ClientAuthFlow(ClientAuthConfig config, KnownHosts known, FlowCarry? carry = null)
    {
        _config = config;
        _known = known.Clone();
        _carry = (carry ?? new FlowCarry()).Clone();
        _address = KnownHosts.NormalizeAddress(config.DialledUrl);
        _standing = _address is null ? AddressStanding.Unknown : _known.Standing(_address);
    }

    public string DeviceName
    {
        get
        {
            var cleaned = AuthWire.CleanName(_config.DeviceName);
            return cleaned.Length == 0 ? _config.FallbackDeviceName : cleaned;
        }
    }

    public string DeviceFingerprint => DeviceIdentity.FingerprintOfKey(_config.DeviceKey);

    /// <summary>True while the connection is up with the host's key verified.</summary>
    public bool IsSecure => _phase == Phase.Secure;
    public bool IsEnded => _phase == Phase.Ended;

    // MARK: Events

    /// <summary>The socket opened. Nothing is sent: the host speaks first.</summary>
    public List<FlowAction> Opened()
    {
        if (_phase != Phase.Idle) return new List<FlowAction>();
        if (_address is null) return Fail("the address cannot be used");
        _phase = Phase.AwaitingChallenge;
        return new List<FlowAction>
        {
            FlowAction.ShowState(FlowState.Connecting()),
            FlowAction.StartTimer(FlowTimer.Challenge, _carry.ChallengeWait),
        };
    }

    /// <summary>The socket closed or failed from the other side or the network.</summary>
    public List<FlowAction> SocketClosed()
    {
        if (_phase == Phase.Ended || _phase == Phase.AskingHost) return new List<FlowAction>();
        return Finish(FlowEnd.Failure(), "the connection closed", null);
    }

    public List<FlowAction> TimerFired(FlowTimer timer)
    {
        if (timer == FlowTimer.Challenge && _phase == Phase.AwaitingChallenge) return ChallengeTimedOut();
        if (timer == FlowTimer.Result && _phase == Phase.AwaitingResult) return Fail("the host did not answer");
        if (timer == FlowTimer.Pending && _phase == Phase.Pending)
        {
            return Finish(FlowEnd.Reconnect(0, _carry), "no result for 60 s", FlowState.Connecting());
        }
        return new List<FlowAction>();
    }

    /// <summary>The user answered the question the state asks (AskUnverified or ConfirmHost).</summary>
    public List<FlowAction> Answered(bool yes)
    {
        switch (_phase)
        {
            case Phase.AskingUnverified:
            {
                if (!yes || _address is null) return Finish(FlowEnd.Stop(), "user declined", null);
                _phase = Phase.ClearSession;
                return new List<FlowAction>
                {
                    FlowAction.ChangeStore(KnownHostsChange.AllowUnverified(_address)),
                    FlowAction.Send(_config.MakeHello()),
                    FlowAction.HostCaps(0),
                    FlowAction.ShowState(FlowState.Connected(false, "")),
                };
            }
            case Phase.AskingHost:
            {
                if (!yes || _handshake is null || _address is null) return Finish(FlowEnd.Stop(), "user declined", null);
                var h = _handshake;
                _phase = Phase.Ended;
                return new List<FlowAction>
                {
                    FlowAction.ChangeStore(KnownHostsChange.RecordVerified(h.HostIdentityKey, h.HostName, _config.DialledUrl)),
                    FlowAction.Ended(FlowEnd.Reconnect(0, new FlowCarry()), "host confirmed by the user"),
                };
            }
            default:
                return new List<FlowAction>();
        }
    }

    /// <summary>One message from the host: its type byte and payload.</summary>
    public List<FlowAction> Received(byte type, byte[] payload)
    {
        switch (_phase)
        {
            case Phase.Idle:
            case Phase.Ended:
            case Phase.AskingHost:
                return new List<FlowAction>();
            case Phase.AwaitingChallenge:
            case Phase.AskingUnverified:
                if (type != WireType.AuthChallenge) return Fail("message before the challenge");
                return HandleChallenge(payload);
            case Phase.ClearSession:
                if (type == WireType.AuthChallenge)
                {
                    // A host that does speak auth, only slower than we waited.
                    var next = _carry.Clone();
                    next.ChallengeWait = LateChallengeWait;
                    return Finish(FlowEnd.Reconnect(0, next), "challenge after a clear HELLO", FlowState.Connecting());
                }
                if (type == WireType.AuthResult || type == WireType.Secure || type == WireType.AuthResponse)
                {
                    return Fail("unexpected message in a clear session");
                }
                return new List<FlowAction> { FlowAction.Deliver(type, payload) };
            case Phase.AwaitingResult:
            case Phase.Pending:
                if (type != WireType.AuthResult) return Fail("message before the result");
                return HandleResult(payload);
            case Phase.Secure:
                if (type != WireType.Secure) return Fail("clear message after accepted");
                return HandleSecure(payload);
            default:
                return new List<FlowAction>();
        }
    }

    /// <summary>The app wants to send one whole framed message. Returns the
    /// action holding the bytes for the socket. Before accepted is verified
    /// nothing the app sends goes out: it is dropped, never queued. In an
    /// unverified clear session it goes as it is. Sealing happens here, in call
    /// order, so the caller must put the returned bytes on the wire in call order.</summary>
    public List<FlowAction> Send(byte[] message)
    {
        switch (_phase)
        {
            case Phase.ClearSession:
                return new List<FlowAction> { FlowAction.Send(message) };
            case Phase.Secure:
                if (_sealer is null) return new List<FlowAction>();
                try
                {
                    return new List<FlowAction> { FlowAction.Send(_sealer.SealMessage(message)) };
                }
                catch (Exception e) when (e is AuthException or CryptographicException)
                {
                    return Fail("could not seal a message");
                }
            default:
                return new List<FlowAction>();
        }
    }

    // MARK: Challenge

    private List<FlowAction> ChallengeTimedOut()
    {
        if (_standing.Kind == StandingKind.Host)
        {
            var name = _known.Host(_standing.HostId)?.Name ?? "";
            return Finish(FlowEnd.Stop(), "a saved host did not identify itself", FlowState.DidNotIdentify(name));
        }
        if (_address is null) return Fail("the address cannot be used");
        if (_standing.Kind == StandingKind.UnknownAllowed)
        {
            _phase = Phase.ClearSession;
            return new List<FlowAction>
            {
                FlowAction.Send(_config.MakeHello()),
                FlowAction.HostCaps(0),
                FlowAction.ShowState(FlowState.Connected(false, "")),
            };
        }
        _phase = Phase.AskingUnverified;
        return new List<FlowAction> { FlowAction.ShowState(FlowState.AskUnverified(_address)) };
    }

    private List<FlowAction> HandleChallenge(byte[] payload)
    {
        AuthChallenge challenge;
        try { challenge = AuthChallenge.Decode(payload); }
        catch (AuthException) { return Fail("the challenge is not valid"); }
        if (!DeviceIdentity.IsValidPublicKey(challenge.Hello.IdentityKey)) return Fail("the challenge is not valid");

        var id = DeviceIdentity.Id(challenge.Hello.IdentityKey);
        if (_standing.Kind == StandingKind.Host && _standing.HostId != id)
        {
            var saved = DeviceIdentity.Fingerprint(_standing.HostId);
            return Finish(FlowEnd.Stop(), "identity changed", FlowState.ChangedIdentity(
                _address ?? "", saved, DeviceIdentity.Fingerprint(id)));
        }
        ClientHandshake h;
        try
        {
            h = new ClientHandshake(payload, _config.DeviceKey, _config.Capabilities, DeviceName, _config.Sign,
                _config.Extensions, _config.Ephemeral, _config.Nonce);
        }
        catch (Exception)
        {
            return Fail("could not answer the challenge");
        }
        _handshake = h;
        _phase = Phase.AwaitingResult;
        return new List<FlowAction>
        {
            FlowAction.CancelTimer(FlowTimer.Challenge),
            FlowAction.Send(Wire.Frame(WireType.AuthResponse, h.Response)),
            FlowAction.StartTimer(FlowTimer.Result, ResultWait),
            FlowAction.ShowState(FlowState.Connecting()),
        };
    }

    // MARK: Result

    private List<FlowAction> HandleResult(byte[] payload)
    {
        AuthStatus status;
        var h = _handshake;
        if (h is null) return Fail("a result did not verify");
        try { status = h.StatusOfResult(payload); }
        catch (AuthException) { return Fail("a result did not verify"); }

        var actions = new List<FlowAction>
        {
            FlowAction.CancelTimer(FlowTimer.Result),
            FlowAction.CancelTimer(FlowTimer.Pending),
        };
        bool hostKnown = _known.Host(h.HostId) is not null;
        // A verified result proves the host holds the key in the challenge.
        if (hostKnown && !_bound && _address is not null)
        {
            _bound = true;
            if (!(_standing.Kind == StandingKind.Host && _standing.HostId == h.HostId))
            {
                // The dialled URL, not the bare address: a tunnel's display path
                // is kept with the address so a later fallback reaches the same display.
                actions.Add(FlowAction.ChangeStore(KnownHostsChange.Bind(h.HostId, _config.DialledUrl)));
            }
        }
        var name = h.HostName;
        switch (status)
        {
            case AuthStatus.Pending:
                _phase = Phase.Pending;
                _waitingShown = true;
                actions.Add(FlowAction.StartTimer(FlowTimer.Pending, PendingWait));
                actions.Add(FlowAction.ShowState(FlowState.WaitingForApproval(
                    name, h.HostFingerprint, DeviceName, DeviceFingerprint)));
                return actions;
            case AuthStatus.Accepted:
                if (_waitingShown || hostKnown)
                {
                    if (_address is null) return Fail("the address cannot be used");
                    actions.Add(FlowAction.ChangeStore(KnownHostsChange.RecordVerified(h.HostIdentityKey, name, _config.DialledUrl)));
                    actions.AddRange(StartSession(h));
                    return actions;
                }
                // Rule 12: let in without being asked, by a host not met before.
                _phase = Phase.AskingHost;
                actions.Add(FlowAction.Close("a host not met before let this device in; asking the user"));
                actions.Add(FlowAction.ShowState(FlowState.ConfirmHost(name, h.HostFingerprint)));
                return actions;
            case AuthStatus.Denied:
                actions.AddRange(Finish(FlowEnd.Stop(), "denied", FlowState.Denied(name)));
                return actions;
            case AuthStatus.Invalid:
                actions.AddRange(Finish(FlowEnd.Stop(), "invalid", FlowState.Invalid(name)));
                return actions;
            case AuthStatus.Busy:
                actions.AddRange(RetryActions(afterBusy: true));
                return actions;
            case AuthStatus.Timeout:
                if (!_carry.TimeoutRetried)
                {
                    var next = _carry.Clone();
                    next.TimeoutRetried = true;
                    actions.AddRange(Finish(FlowEnd.Reconnect(0, next), "timeout", FlowState.Connecting()));
                    return actions;
                }
                actions.AddRange(RetryActions(afterBusy: false));
                return actions;
            default:
                return Fail("a result did not verify");
        }
    }

    private List<FlowAction> RetryActions(bool afterBusy)
    {
        var next = _carry.Clone();
        var delay = _carry.BusyDelay;
        next.BusyDelay = Math.Min(delay * 2, BusyMaxDelay);
        return Finish(FlowEnd.Reconnect(delay, next), afterBusy ? "busy" : "timeout again", FlowState.Busy((int)delay));
    }

    // MARK: Session

    private List<FlowAction> StartSession(ClientHandshake h)
    {
        try
        {
            var keys = h.DeriveSessionKeys();
            var sealer = new SecureSealer(keys.ClientToHost);
            _opener = new SecureOpener(keys.HostToClient);
            var hello = sealer.SealMessage(_config.MakeHello());
            var info = sealer.SealMessage(Wire.Frame(WireType.ClientInfo, ClientInfoJson()));
            _sealer = sealer;
            _phase = Phase.Secure;
            _capsPublished = true;
            return new List<FlowAction>
            {
                FlowAction.HostCaps(h.HostCapabilities),
                FlowAction.ShowState(FlowState.Connected(true, h.HostName)),
                FlowAction.Send(hello),
                FlowAction.Send(info),
            };
        }
        catch (Exception e) when (e is AuthException or CryptographicException)
        {
            return Fail("could not start the encrypted session");
        }
    }

    private byte[] ClientInfoJson()
    {
        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms))
        {
            w.WriteStartObject();
            w.WriteString("app", _config.AppName);
            var url = CleanUrl(_config.DialledUrl);
            if (url is not null) w.WriteString("url", url);
            w.WriteString("version", _config.AppVersion);
            w.WriteEndObject();
        }
        return ms.ToArray();
    }

    /// <summary>The URL without user info, query or fragment, as the spec wants it.</summary>
    public static string? CleanUrl(string text)
    {
        var s = text;
        int hash = s.IndexOf('#');
        if (hash >= 0) s = s.Substring(0, hash);
        int query = s.IndexOf('?');
        if (query >= 0) s = s.Substring(0, query);
        int sep = s.IndexOf("://", StringComparison.Ordinal);
        if (sep < 0) return s.Length == 0 ? null : s;
        string scheme = s.Substring(0, sep + 3);
        string rest = s.Substring(sep + 3);
        int slash = rest.IndexOf('/');
        string authority = slash < 0 ? rest : rest.Substring(0, slash);
        string path = slash < 0 ? "" : rest.Substring(slash);
        int at = authority.LastIndexOf('@');
        if (at >= 0) authority = authority.Substring(at + 1);
        return scheme + authority + path;
    }

    private List<FlowAction> HandleSecure(byte[] payload)
    {
        if (_opener is null) return Fail("no session");
        (byte Type, byte[] Payload) inner;
        try { inner = _opener.Open(payload); }
        catch (Exception e) when (e is AuthException or CryptographicException)
        {
            return Fail("a SECURE message did not open");
        }
        if (inner.Type == WireType.HostInfo)
        {
            if (_handshake is null) return new List<FlowAction>();
            var urls = HostInfoUrls(inner.Payload);
            return urls.Count == 0
                ? new List<FlowAction>()
                : new List<FlowAction> { FlowAction.ChangeStore(KnownHostsChange.Hints(_handshake.HostId, urls)) };
        }
        return new List<FlowAction> { FlowAction.Deliver(inner.Type, inner.Payload) };
    }

    /// <summary>Every URL HOST_INFO lists, with sane caps on how much is read.
    /// The store applies the spec's per-URL limits.</summary>
    public static List<string> HostInfoUrls(byte[] payload)
    {
        var output = new List<string>();
        if (payload.Length > 64 * 1024) return output;
        try
        {
            using var doc = JsonDocument.Parse(payload);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return output;
            if (!doc.RootElement.TryGetProperty("displays", out var displays) || displays.ValueKind != JsonValueKind.Array) return output;
            int shown = 0;
            foreach (var d in displays.EnumerateArray())
            {
                if (shown++ >= 8) break;
                if (d.ValueKind != JsonValueKind.Object) continue;
                if (!d.TryGetProperty("urls", out var urls) || urls.ValueKind != JsonValueKind.Array) continue;
                int count = 0;
                foreach (var u in urls.EnumerateArray())
                {
                    if (count++ >= 32) break;
                    if (u.ValueKind == JsonValueKind.String && u.GetString() is { } s) output.Add(s);
                }
            }
        }
        catch (JsonException)
        {
            return new List<string>();
        }
        return output;
    }

    // MARK: Ending

    private List<FlowAction> Fail(string reason) =>
        Finish(FlowEnd.Failure(), reason, FlowState.Failed(reason));

    private List<FlowAction> Finish(FlowEnd end, string reason, FlowState? shown)
    {
        _phase = Phase.Ended;
        var actions = new List<FlowAction>
        {
            FlowAction.CancelTimer(FlowTimer.Challenge),
            FlowAction.CancelTimer(FlowTimer.Result),
            FlowAction.CancelTimer(FlowTimer.Pending),
        };
        if (_capsPublished)
        {
            _capsPublished = false;
            actions.Add(FlowAction.HostCaps(0));
        }
        if (shown is not null) actions.Add(FlowAction.ShowState(shown));
        actions.Add(FlowAction.Ended(end, reason));
        return actions;
    }
}
