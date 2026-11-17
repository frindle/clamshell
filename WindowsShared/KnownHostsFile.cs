using System.IO;
namespace Clamshell.Auth;

/// <summary>The saved Macs file cannot be used. The message is for the person
/// using the app; the file has not been touched.</summary>
public sealed class KnownHostsFileException : Exception
{
    public KnownHostsFileException(string message) : base(message) { }
}

/// <summary>The saved Macs on disk: JSON with public keys, names and addresses
/// only. The folder is passed in. Every change reads the file again first, so
/// two programs that change it (the viewer and the forget-host command) do not
/// overwrite each other's work, and writes go to a temporary file in the same
/// folder that is then moved into place.
///
/// A file that exists and cannot be read or parsed (or has any entry that
/// cannot be read) is an error: nothing is connected, nothing is written, and
/// the file is never treated as empty. Stricter than the Swift store, which
/// keeps the readable entries and carries on.</summary>
public sealed class KnownHostsFile
{
    public const string FileName = "known-hosts.json";

    private readonly object _gate = new();
    public string FolderPath { get; }
    public string FilePath { get; }

    public KnownHostsFile(string folder)
    {
        FolderPath = folder;
        FilePath = System.IO.Path.Combine(folder, FileName);
    }

    /// <summary>The saved Macs; empty when no file exists yet. Throws
    /// <see cref="KnownHostsFileException"/> for a file that is there but cannot be used.</summary>
    public KnownHosts Load()
    {
        lock (_gate) return LoadUnlocked();
    }

    private KnownHosts LoadUnlocked()
    {
        byte[]? data = null;
        if (Directory.Exists(FilePath))
        {
            throw new KnownHostsFileException($"The saved Macs file ({FilePath}) is a folder. Nothing was changed.");
        }
        if (File.Exists(FilePath))
        {
            try { data = File.ReadAllBytes(FilePath); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                throw new KnownHostsFileException(
                    $"The saved Macs file ({FilePath}) cannot be read: {e.Message} Nothing was changed.");
            }
        }
        var (hosts, damaged) = KnownHosts.Decode(data);
        if (damaged)
        {
            throw new KnownHostsFileException(
                $"The saved Macs file ({FilePath}) is damaged. It was left as it is and nothing was connected. "
                + "Move or delete it yourself if you want to start again.");
        }
        return hosts;
    }

    /// <summary>Applies one change to what is on disk now and saves. Returns the
    /// store after the change.</summary>
    public KnownHosts Apply(KnownHostsChange change, double now)
    {
        lock (_gate)
        {
            var hosts = LoadUnlocked();
            change.Apply(hosts, now);
            Save(hosts);
            return hosts;
        }
    }

    private void Save(KnownHosts hosts)
    {
        var temp = System.IO.Path.Combine(FolderPath, FileName + "." + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            Directory.CreateDirectory(FolderPath);
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                var bytes = hosts.Encoded();
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush(true);
            }
            File.Move(temp, FilePath, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            try { File.Delete(temp); } catch (Exception) { /* nothing more to do */ }
            throw new KnownHostsFileException($"The saved Macs file ({FilePath}) could not be written: {e.Message}");
        }
    }
}
