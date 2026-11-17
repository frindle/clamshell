using System.Runtime.InteropServices;
using System.Text;

namespace Clamshell;

// `ClamshellServer devices | approve | deny | revoke | forget`: the device list from a terminal,
// for a PC that can be reached remotely but not seen. Mirrors Sources/Clamshell/Auth/DeviceCommands.swift:
// the same verbs, the same wording where it fits, the same exit codes (0 done, 1 not done, 64 not
// understood). These touch only the state folder, under the store's lock; a running host notices the
// change by itself (its file watcher), so this works while the tray app is running.
internal static class DeviceCommands
{
    public static readonly string[] Names = { "devices", "approve", "deny", "revoke", "forget" };

    public const string Usage =
        "Usage: ClamshellServer devices\n" +
        "       ClamshellServer approve <fingerprint or id>\n" +
        "       ClamshellServer deny    <fingerprint or id>\n" +
        "       ClamshellServer revoke  <fingerprint or id>\n" +
        "       ClamshellServer forget  <fingerprint or id>";

    public static bool IsCommand(string[] args) => args.Length > 0 && Array.IndexOf(Names, args[0]) >= 0;

    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AttachConsole(int pid);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetConsoleOutputCP(uint cp);

    /// <summary>Entry from Main. The program is a Windows-subsystem executable, so it has no
    /// console of its own: attach to the one it was started from (if any) and write to the
    /// standard output the shell gave it. Note that a shell does not wait for such a program
    /// unless asked to (cmd: start /wait; PowerShell: Start-Process -Wait), so the exit code
    /// is only visible that way.</summary>
    public static int RunFromMain(string[] args)
    {
        const int AttachParentProcess = -1;
        bool attached = AttachConsole(AttachParentProcess);
        if (attached) SetConsoleOutputCP(65001);
        var writer = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true };
        Console.SetOut(writer);
        try
        {
            using var auth = new HostAuth(HostState.Directory, watch: false);
            return Run(args, auth, writer.WriteLine);
        }
        catch (Exception e) when (e is DeviceKeyException or IOException or UnauthorizedAccessException)
        {
            writer.WriteLine($"The host key or the device list could not be opened: {e.Message} See {Log.FilePath}.");
            return 1;
        }
    }

    private static string Quoted(string name) => DeviceText.Quoted(name);

    /// <summary><paramref name="args"/> starts with the command name. Returns the exit code.</summary>
    public static int Run(string[] args, HostAuth auth, Action<string> output)
    {
        if (!IsCommand(args))
        {
            output(Usage);
            return 64;
        }
        string command = args[0];
        var store = auth.Store;
        if (!store.CanPersist)
        {
            output($"The device list in {store.Folder} cannot be used. See {Log.FilePath}.");
            return 1;
        }
        if (command == "devices")
        {
            if (args.Length != 1) { output(Usage); return 64; }
            List(auth, output);
            return 0;
        }
        if (args.Length != 2) { output(Usage); return 64; }

        var match = store.Resolve(args[1]);
        switch (match.Kind)
        {
            case DeviceTrustStore.MatchKind.BadQuery:
                output("Give the device's fingerprint (like AB12-CD34-EF56-7890) or its full 64-character id.");
                return 64;
            case DeviceTrustStore.MatchKind.None:
                output($"No device matches {args[1]}. Run `ClamshellServer devices` to see them.");
                return 1;
            case DeviceTrustStore.MatchKind.Ambiguous:
                output("More than one device matches. Use the full id:");
                foreach (var d in match.Records) output($"  {d.Id}  {Quoted(d.Label)}");
                return 1;
        }
        var device = match.Records[0];
        string who = $"{Quoted(device.Label)} {device.Fingerprint}";

        switch (command)
        {
            case "approve":
                if (device.State == DeviceState.Trusted) { output($"{who} is already trusted."); return 0; }
                if (store.Decide(device.Id, DeviceTrustStore.Decision.Approve, DeviceTrustStore.DecidedOnCommandLine, onlyIfWaiting: false) is null)
                    return NotSaved(output);
                output($"Approved {who}.");
                break;
            case "deny":
                if (device.State == DeviceState.Denied) { output($"{who} is already denied."); return 0; }
                if (device.State == DeviceState.Trusted)
                {
                    output($"{who} is trusted. To take that away use: ClamshellServer revoke {device.Fingerprint}");
                    return 1;
                }
                if (store.Decide(device.Id, DeviceTrustStore.Decision.Deny, DeviceTrustStore.DecidedOnCommandLine, onlyIfWaiting: true) is null)
                    return NotSaved(output);
                output($"Denied {who}.");
                break;
            case "revoke":
                if (device.State != DeviceState.Trusted) { output($"{who} is not trusted, so there is nothing to revoke."); return 0; }
                if (store.Revoke(device.Id, DeviceTrustStore.DecidedOnCommandLine) is null) return NotSaved(output);
                output($"Revoked {who}.");
                break;
            default: // forget
                if (store.Forget(device.Id) is null) return NotSaved(output);
                output($"Forgot {who}. It can ask again.");
                break;
        }
        return 0;
    }

    private static int NotSaved(Action<string> output)
    {
        output("Nothing was changed: the device list changed meanwhile or could not be saved. Run `ClamshellServer devices` and try again.");
        return 1;
    }

    private static void List(HostAuth auth, Action<string> output)
    {
        string key = auth.Identity.IsPersistent ? "" : " (for this run only: the key could not be stored)";
        output($"This PC: {Quoted(Clamshell.Auth.AuthWire.CleanName(auth.HostName))}, fingerprint {auth.Identity.Fingerprint}{key}");
        output(auth.RequireApproval
            ? "Device approval is on."
            : "Device approval is OFF: any device that reaches this PC can control it.");
        var all = auth.Store.All();
        if (all.Count == 0)
        {
            output("");
            output("No devices yet.");
            return;
        }
        double now = DeviceText.Now();
        void Section(string title, DeviceState state, Func<DeviceRecord, string> detail)
        {
            var rows = all.Where(r => r.State == state).OrderBy(r => r.FirstSeen).ToList();
            if (rows.Count == 0) return;
            output("");
            output(title);
            foreach (var d in rows) output($"  {d.Fingerprint}  {Quoted(d.Label)}  {detail(d)}");
        }
        Section("Waiting for approval:", DeviceState.Waiting, d =>
            $"from {(d.Address.Length == 0 ? "an unknown address" : d.Address)}, asked {DeviceText.Ago(d.FirstSeen, now)}");
        Section("Trusted:", DeviceState.Trusted, d =>
            $"last seen {DeviceText.Ago(d.LastSeen, now)}{Decided(d, "approved")}");
        Section("Denied:", DeviceState.Denied, d => Decided(d, "denied").Trim(',', ' '));
        if (all.Any(r => r.State == DeviceState.Waiting))
        {
            output("");
            output("Compare the fingerprint with the one the device shows, then: ClamshellServer approve <fingerprint>");
        }
    }

    /// <summary>", approved on this PC" and the like; empty when nothing is recorded.</summary>
    private static string Decided(DeviceRecord d, string verb)
    {
        if (d.DecidedBy is null) return "";
        return d.DecidedBy switch
        {
            DeviceTrustStore.DecidedOnHost => $", {verb} on this PC",
            DeviceTrustStore.DecidedOnCommandLine => $", {verb} from the command line",
            var by => $", {verb} from device {Clamshell.Auth.DeviceIdentity.Fingerprint(by)}",
        };
    }
}

/// <summary>`ClamshellServer selftest-commands`: the command line against a throwaway device list,
/// in process. Made-up devices only.</summary>
internal static class CommandsSelfTest
{
    private static int _failures;

    private static void Check(bool ok, string what)
    {
        Console.Error.WriteLine($"commands-selftest: {(ok ? "ok  " : "FAIL")} {what}");
        if (!ok) _failures++;
    }

    private static (int Code, string Text) Run(HostAuth auth, params string[] args)
    {
        var lines = new List<string>();
        int code = DeviceCommands.Run(args, auth, lines.Add);
        return (code, string.Join("\n", lines));
    }

    public static int Run()
    {
        var folder = Path.Combine(Path.GetTempPath(), "clamshell-commands-selftest-" + Guid.NewGuid().ToString("N"));
        var keyName = "Clamshell.Host.CommandsSelfTest." + Guid.NewGuid().ToString("N");
        HostIdentity? identity = null;
        HostAuth? auth = null;
        try
        {
            identity = HostIdentity.Open(keyName);
            auth = new HostAuth(folder, identity, requireApproval: true, watch: false);
            using var phone = new MemoryDeviceKey();
            using var tablet = new MemoryDeviceKey();
            string phoneId = Clamshell.Auth.DeviceIdentity.Id(phone.PublicKey);
            string phoneFp = Clamshell.Auth.DeviceIdentity.Fingerprint(phoneId);
            auth.Store.Ask(phone.PublicKey, "Example Phone", "203.0.113.7", null, _ => true);
            auth.Store.Ask(tablet.PublicKey, "Example Tablet", "198.51.100.4", null, _ => true);
            string tabletFp = Clamshell.Auth.DeviceIdentity.Fingerprint(Clamshell.Auth.DeviceIdentity.Id(tablet.PublicKey));

            var list = Run(auth, "devices");
            Check(list.Code == 0, "devices exits 0");
            Check(list.Text.Contains(auth.Identity.Fingerprint), "devices shows this PC's fingerprint");
            Check(list.Text.Contains("Waiting for approval:") && list.Text.Contains(phoneFp) && list.Text.Contains("Example Phone"),
                "devices lists a waiting device with its fingerprint and name");
            Check(list.Text.Contains("203.0.113.7"), "devices shows where it asked from");

            Check(Run(auth).Code == 64, "no command: usage, 64");
            Check(Run(auth, "nonsense").Code == 64, "unknown command: usage, 64");
            Check(Run(auth, "devices", "extra").Code == 64, "devices with an argument: 64");
            Check(Run(auth, "approve").Code == 64, "approve without a device: 64");
            Check(Run(auth, "approve", "zzz").Code == 64, "approve with a bad query: 64");
            Check(Run(auth, "approve", "0000-0000-0000-0000").Code == 1, "approve of an unknown device: 1");

            var approve = Run(auth, "approve", phoneFp);
            Check(approve.Code == 0 && approve.Text.StartsWith("Approved"), "approve of a waiting device: 0");
            Check(auth.Store.StateOf(phoneId) == DeviceState.Trusted, "the device is trusted afterwards");
            Check(auth.Store.Record(phoneId)?.DecidedBy == DeviceTrustStore.DecidedOnCommandLine, "it records that the command line decided");
            Check(Run(auth, "approve", phoneFp).Text.Contains("already trusted"), "approving a trusted device says so, exit 0");
            Check(Run(auth, "deny", phoneFp).Code == 1, "deny of a trusted device: 1 and points to revoke");

            var revoke = Run(auth, "revoke", phoneFp);
            Check(revoke.Code == 0 && auth.Store.StateOf(phoneId) == DeviceState.Denied, "revoke makes a trusted device denied");
            Check(Run(auth, "revoke", phoneFp).Code == 0, "revoking again says there is nothing to revoke, exit 0");

            var deny = Run(auth, "deny", tabletFp);
            Check(deny.Code == 0 && deny.Text.StartsWith("Denied"), "deny of a waiting device: 0");
            Check(Run(auth, "deny", tabletFp).Text.Contains("already denied"), "denying again says so");

            var forget = Run(auth, "forget", phoneFp);
            Check(forget.Code == 0 && auth.Store.StateOf(phoneId) is null, "forget removes the device");
            Check(Run(auth, "forget", phoneFp).Code == 1, "forgetting an unknown device: 1");
        }
        catch (Exception e)
        {
            Check(false, "unexpected exception: " + e);
        }
        finally
        {
            try { auth?.Dispose(); } catch (Exception) { }
            try { identity?.DeleteFromStore(); } catch (Exception) { }
            identity?.Dispose();
            try { Directory.Delete(folder, true); } catch (Exception) { }
        }
        Console.Error.WriteLine($"commands-selftest: {(_failures == 0 ? "all checks passed" : _failures + " failed")}");
        return _failures == 0 ? 0 : 1;
    }
}
