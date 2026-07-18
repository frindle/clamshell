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
    // WinForms (NotifyIcon, Form) requires the single-threaded apartment
    // model; top-level statements can't carry a method-level attribute, so
    // this needs an explicit Main.
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "selftest") return SelfTest.Run();

        ushort basePort = Proto.DefaultPort;
        if (args.Length > 0 && ushort.TryParse(args[0], out var p)) basePort = p;

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new TrayApp(basePort));
        return 0;
    }
}
