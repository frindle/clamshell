namespace Clamshell;

// Mirrors WindowsServer/Log.cs -- timestamped lines to stderr (visible under
// `dotnet run`/CI) and a log file (visible when launched by double-click,
// which has no console).
internal static class Log
{
    private static readonly object Gate = new();

    public static readonly string FilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Clamshell", "clamshell-viewer.log");

    static Log()
    {
        try { Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!); }
        catch { }
    }

    public static void Line(string msg)
    {
        var line = $"{DateTime.Now:HH:mm:ss.fff} VIEWER: {msg}";
        lock (Gate)
        {
            Console.Error.WriteLine(line);
            try { File.AppendAllText(FilePath, line + Environment.NewLine); }
            catch { }
        }
    }
}
