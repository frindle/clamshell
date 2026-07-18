namespace Clamshell;

// Mirrors the Mac's clog() — timestamped stderr lines prefixed "STREAM:".
internal static class Log
{
    private static readonly object Gate = new();

    public static void Line(string msg)
    {
        lock (Gate)
            Console.Error.WriteLine($"{DateTime.Now:HH:mm:ss.fff} STREAM: {msg}");
    }
}

// Display rectangle in virtual-desktop pixel coordinates.
internal readonly record struct DisplayRect(int X, int Y, int Width, int Height);
