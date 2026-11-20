using System.Security.Cryptography;
using Renci.SshNet;
using Renci.SshNet.Common;

namespace Clamshell.Auth;

/// <summary>The SSH side of "Unlock disk" on Windows, on SSH.NET (pinned in the csproj). It
/// receives the server's host key and hands its fingerprint to the pin check BEFORE any
/// credential is sent (the key arrives in the key exchange, which comes first). macOS ends the
/// session itself after a good password ("System successfully unlocked."), so a disconnect after
/// the password was sent, without an authentication error, counts as signed in.
/// Password and keyboard-interactive are both offered with the same password, because the
/// pre-boot sshd may use either. Nothing is logged.</summary>
internal sealed class SshNetUnlockTransport : ISshUnlockTransport
{
    public Task<SshAttempt> AttemptAsync(string host, int port, string username, string password, TimeSpan connectTimeout,
        Func<string, bool> acceptHostKey, CancellationToken ct) =>
        Task.Run(() => Attempt(host, port, username, password, connectTimeout, acceptHostKey, ct), ct);

    private static SshAttempt Attempt(string host, int port, string username, string password, TimeSpan connectTimeout,
        Func<string, bool> acceptHostKey, CancellationToken ct)
    {
        var passwordAuth = new PasswordAuthenticationMethod(username, password);
        var interactive = new KeyboardInteractiveAuthenticationMethod(username);
        interactive.AuthenticationPrompt += (_, e) =>
        {
            foreach (var prompt in e.Prompts) prompt.Response = password;
        };
        var info = new ConnectionInfo(host, port, username, passwordAuth, interactive) { Timeout = connectTimeout };
        bool declined = false, keyAccepted = false;
        try
        {
            using var client = new SshClient(info);
            client.HostKeyReceived += (_, e) =>
            {
                bool ok = acceptHostKey(SshFingerprint.Sha256(e.HostKey));
                if (!ok) declined = true; else keyAccepted = true;
                e.CanTrust = ok;
            };
            using var reg = ct.Register(() => { try { client.Disconnect(); } catch { } });
            client.Connect();
            return SshAttempt.Authenticated; // a normal sshd keeps the session: the password worked
        }
        catch (SshAuthenticationException) { return declined ? SshAttempt.HostKeyRefused : SshAttempt.AuthFailed; }
        catch (SshConnectionException) when (declined) { return SshAttempt.HostKeyRefused; }
        catch (SshConnectionException)
        {
            // The pre-boot sshd drops the session right after unlocking: after our password went out,
            // that is success. Before the key was accepted, the connection just failed.
            return keyAccepted ? SshAttempt.Authenticated : SshAttempt.Failed;
        }
        catch (System.Net.Sockets.SocketException) { return SshAttempt.ConnectFailed; }
        catch (SshOperationTimeoutException) { return SshAttempt.ConnectFailed; }
        catch (Exception) { return declined ? SshAttempt.HostKeyRefused : SshAttempt.Failed; }
    }
}

/// <summary>The accepted host keys, kept in the user's app data (a fingerprint is public).</summary>
internal static class SshPinStore
{
    private static string PathFile => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Clamshell", "unlock-hostkeys.txt");

    public static SshHostPins Load()
    {
        var d = new Dictionary<string, string>();
        try
        {
            foreach (var line in System.IO.File.ReadAllLines(PathFile))
            {
                var i = line.IndexOf(' ');
                if (i > 0) d[line[..i]] = line[(i + 1)..];
            }
        }
        catch { /* no file yet */ }
        return new SshHostPins(d);
    }

    public static void Save(SshHostPins pins)
    {
        System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(PathFile)!);
        System.IO.File.WriteAllLines(PathFile, pins.Pins.Select(kv => $"{kv.Key} {kv.Value}"));
    }
}
