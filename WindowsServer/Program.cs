using System.Threading;
using System.Windows.Forms;

namespace Clamshell;

// Clamshell Windows host server. Runs from the system tray (see TrayApp) —
// serves one WebSocket endpoint per display at basePort+index (main display
// = index 0 = base port), speaking the exact wire protocol in PROTOCOL.md so
// the existing iOS clients connect to a Windows host with zero changes.
// Stop/restart/exit are all in the tray icon's context menu.
//
// Usage: ClamshellServer [basePort]   (default 5903)
internal static class Program
{
    // Named mutex, held for the app's whole lifetime. Two jobs:
    //  1. Single-instance enforcement (a second launch exits immediately
    //     instead of running two servers on the same ports).
    //  2. Lets the installer's AppMutex directive (installer.iss) detect a
    //     running instance and close it during an upgrade -- without this,
    //     Inno Setup had no reliable way to know Clamshell was running, so
    //     an update could overwrite files under a live process, leaving the
    //     old instance orphaned (visible in Task Manager, gone from the
    //     tray) after "closing" it. Confirmed live 2026-07-31.
    public const string MutexName = "Global\\ClamshellServer-SingleInstance";

    // WinForms (NotifyIcon, Form) requires the single-threaded apartment
    // model; top-level statements can't carry a method-level attribute, so
    // this needs an explicit Main.
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "selftest") return SelfTest.Run();

        using var mutex = new Mutex(initiallyOwned: true, MutexName, out var createdNew);
        if (!createdNew)
        {
            MessageBox.Show("Clamshell is already running (check the system tray).",
                "Clamshell", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 0;
        }

        ushort basePort = Proto.DefaultPort;
        if (args.Length > 0 && ushort.TryParse(args[0], out var p)) basePort = p;

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new TrayApp(basePort));
        return 0;
    }
}
