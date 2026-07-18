namespace Clamshell;

// Mirrors the Mac's clog() — timestamped lines prefixed "STREAM:", written to
// both stderr (still useful under `dotnet run`/CI, which redirect it) and a
// log file. As a tray app (no console window) stderr alone goes nowhere when
// launched by double-click or "start at sign-in" — the file is the only way
// to see these lines outside a terminal.
internal static class Log
{
    private static readonly object Gate = new();

    public static readonly string FilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Clamshell", "clamshell.log");

    static Log()
    {
        try { Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!); }
        catch { /* best-effort — file sink is a bonus, not load-bearing */ }
    }

    public static void Line(string msg)
    {
        var line = $"{DateTime.Now:HH:mm:ss.fff} STREAM: {msg}";
        lock (Gate)
        {
            Console.Error.WriteLine(line);
            // A locked file or full disk shouldn't take down a remote-desktop
            // server that's otherwise working fine.
            try { File.AppendAllText(FilePath, line + Environment.NewLine); }
            catch { }
        }
    }
}

// Display rectangle in virtual-desktop pixel coordinates.
internal readonly record struct DisplayRect(int X, int Y, int Width, int Height);
