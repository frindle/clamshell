using System.Security.Cryptography;

namespace Clamshell.Auth;

// "Unlock disk": the Windows app SSHes straight to the Mac's pre-boot sshd (port 22) with the
// FileVault user's name and password, which is how macOS 26 and later unlocks the disk before it
// boots. This file holds the part that does not depend on an SSH library, so it is tested
// (DiskUnlockTests) and mirrors Sources/Clamshell/Streaming/DiskUnlock.swift: host-key pinning,
// the overall timeout and the result words. SSH.NET plugs in as an ISshUnlockTransport
// (WindowsViewer/SshNetUnlockTransport.cs).
//
// Rules: the host key is checked before any password is sent; the first key seen for an address
// is shown and pinned only if the user says yes; a different key later is refused; nothing here
// ever logs a user name or password.

public static class SshFingerprint
{
    /// <summary>OpenSSH's form: "SHA256:" and the unpadded base64 of the SHA-256 of the key blob.</summary>
    public static string Sha256(byte[] keyBlob) => "SHA256:" + Convert.ToBase64String(SHA256.HashData(keyBlob)).TrimEnd('=');
}

public enum PinDecision { Trusted, Ask, Mismatch }

/// <summary>The host keys the user accepted, by "host:port".</summary>
public sealed class SshHostPins
{
    private readonly Dictionary<string, string> _pins;
    public SshHostPins(IDictionary<string, string>? pins = null) { _pins = pins is null ? new() : new(pins); }
    public IReadOnlyDictionary<string, string> Pins => _pins;
    public static string Endpoint(string host, int port) => $"{host.ToLowerInvariant()}:{port}";
    public PinDecision Decide(string endpoint, string fingerprint) =>
        !_pins.TryGetValue(endpoint, out var known) ? PinDecision.Ask
        : known == fingerprint ? PinDecision.Trusted : PinDecision.Mismatch;
    public void Pin(string endpoint, string fingerprint) => _pins[endpoint] = fingerprint;
}

public enum DiskUnlockResult { Unlocked, WrongPassword, HostKeyMismatch, HostKeyDeclined, Unreachable, TimedOut, Failed }

public static class DiskUnlockText
{
    public static string Of(DiskUnlockResult r) => r switch
    {
        DiskUnlockResult.Unlocked => "Unlocked. Waiting for the Mac to start...",
        DiskUnlockResult.WrongPassword => "The Mac did not accept that user name and password. The Mac allows only a few tries.",
        DiskUnlockResult.HostKeyMismatch => "The Mac's SSH key is not the one you trusted before. Nothing was sent. If you did not change the Mac, someone may be in the way.",
        DiskUnlockResult.HostKeyDeclined => "Not trusted, so nothing was sent.",
        DiskUnlockResult.Unreachable => "Could not reach the Mac's unlock service. It may still be starting, or Remote Login may be off.",
        DiskUnlockResult.TimedOut => "The Mac did not finish in time.",
        _ => "The unlock did not work.",
    };
}

public enum SshAttempt { Authenticated, AuthFailed, HostKeyRefused, ConnectFailed, Failed }

public interface ISshUnlockTransport
{
    /// <summary>Connects, calls <paramref name="acceptHostKey"/> with the key's fingerprint BEFORE
    /// sending any secret, and signs in only if it returns true. Gives up connecting after
    /// <paramref name="connectTimeout"/>. Honors <paramref name="ct"/>.</summary>
    Task<SshAttempt> AttemptAsync(string host, int port, string username, string password, TimeSpan connectTimeout,
        Func<string, bool> acceptHostKey, CancellationToken ct);
}

public sealed class DiskUnlocker
{
    public static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(10);
    public static readonly TimeSpan OverallTimeout = TimeSpan.FromSeconds(60);

    private readonly ISshUnlockTransport _transport;
    private readonly Func<SshHostPins> _load;
    private readonly Action<SshHostPins> _save;
    private readonly Func<string, string, bool> _askToTrust;
    private readonly Action<string> _log;
    private readonly TimeSpan _overall;

    public DiskUnlocker(ISshUnlockTransport transport, Func<SshHostPins> load, Action<SshHostPins> save,
        Func<string, string, bool> askToTrust, Action<string>? log = null, TimeSpan? overall = null)
    {
        _transport = transport; _load = load; _save = save; _askToTrust = askToTrust;
        _log = log ?? (_ => { }); _overall = overall ?? OverallTimeout;
    }

    public async Task<DiskUnlockResult> UnlockAsync(string host, int port, string username, string password)
    {
        var endpoint = SshHostPins.Endpoint(host, port);
        bool mismatch = false;
        using var cts = new CancellationTokenSource(_overall);
        _log("unlock: connecting");
        DiskUnlockResult result;
        try
        {
            var work = _transport.AttemptAsync(host, port, username, password, ConnectTimeout, fingerprint =>
            {
                var pins = _load();
                switch (pins.Decide(endpoint, fingerprint))
                {
                    case PinDecision.Trusted: return true;
                    case PinDecision.Mismatch:
                        mismatch = true; _log("unlock: host key does not match the pinned one"); return false;
                    default:
                        if (!_askToTrust(endpoint, fingerprint)) return false;
                        pins.Pin(endpoint, fingerprint); _save(pins); _log("unlock: host key pinned"); return true;
                }
            }, cts.Token);
            var done = await Task.WhenAny(work, Task.Delay(_overall, cts.Token)).ConfigureAwait(false);
            if (done != work) { cts.Cancel(); result = DiskUnlockResult.TimedOut; }
            else
                result = work.Result switch
                {
                    SshAttempt.Authenticated => DiskUnlockResult.Unlocked,
                    SshAttempt.AuthFailed => DiskUnlockResult.WrongPassword,
                    SshAttempt.HostKeyRefused => mismatch ? DiskUnlockResult.HostKeyMismatch : DiskUnlockResult.HostKeyDeclined,
                    SshAttempt.ConnectFailed => DiskUnlockResult.Unreachable,
                    _ => DiskUnlockResult.Failed,
                };
        }
        catch (OperationCanceledException) { result = DiskUnlockResult.TimedOut; }
        catch { result = DiskUnlockResult.Failed; }
        _log($"unlock: {result}");
        return result;
    }
}
