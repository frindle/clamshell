using System.IO.Compression;
using System.Security.Cryptography;
using System.Threading.Channels;

namespace Clamshell;

// File transfer over the peer link (PROTOCOL.md "Peer link — files") — the
// mirror of Sources/Clamshell/Peer/FileTransfer.swift:
//   FILE_OFFER → FILE_ACCEPT/REJECT → FILE_CHUNK × n (sequential offsets,
//   ≤ 128 KiB) → FILE_DONE(SHA-256); either side may FILE_CANCEL.
// Receiving auto-accepts from the (paired, authenticated) peer into
// Downloads, via a hidden .part file renamed into place only once size and
// hash check out. Folders are sent as a .zip of the folder.
//
// All state and file I/O run on one serial work queue; the sender keeps at
// most 8 chunks in flight, paced by the transport's send completions.

internal sealed class FileTransfer
{
    private readonly SerialQueue _q = new("peer-files");
    private readonly string _dir;
    /// Transport: message + completion once it's handed to the socket.
    public Action<byte[], Action> Send = (_, done) => done();
    public Action<string>? OnReceived;
    public Action<string>? OnSent;
    public Action<string>? OnFailed;

    private sealed class Outgoing
    {
        public uint Id; public string Name = ""; public ulong Size; public FileStream File = null!;
        public IncrementalHash Hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        public ulong Offset; public int InFlight; public bool Accepted; public string? Cleanup;
    }
    private sealed class Incoming
    {
        public uint Id; public string Name = ""; public ulong Size; public string PartPath = ""; public FileStream File = null!;
        public IncrementalHash Hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        public ulong Written;
    }

    private readonly Queue<(string Path, string Name)> _pending = new();
    private Outgoing? _out;
    private readonly Dictionary<uint, Incoming> _in = new();
    private uint _nextId = (uint)RandomNumberGenerator.GetInt32(1, int.MaxValue);
    private CancellationTokenSource? _acceptTimeout;
    private const int MaxInFlight = 8, MaxIncoming = 4;

    public FileTransfer(string directory) { _dir = directory; }

    public static string DownloadsDirectory
    {
        get
        {
            try { if (SHGetKnownFolderPath(new Guid("374DE290-123F-4565-9164-39C4925E467B"), 0, IntPtr.Zero, out var p) == 0) return p; }
            catch { /* not Windows (selftest on another OS) */ }
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        }
    }

    [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern int SHGetKnownFolderPath([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPStruct)] Guid rfid,
        uint dwFlags, IntPtr hToken, out string pszPath);

    // MARK: - Sending

    public void SendPaths(IEnumerable<string> paths)
    {
        var list = paths.ToList();
        _q.Post(() =>
        {
            foreach (var p in list)
            {
                if (Directory.Exists(p))
                {
                    var zip = Zip(p);
                    if (zip is null) { Report($"could not zip {Path.GetFileName(p)}"); continue; }
                    _pending.Enqueue((zip, Path.GetFileName(p.TrimEnd('\\', '/')) + ".zip"));
                }
                else if (File.Exists(p)) _pending.Enqueue((p, Path.GetFileName(p)));
            }
            StartNext();
        });
    }

    private static string? Zip(string folder)
    {
        string outPath = Path.Combine(Path.GetTempPath(), $"clamshell-{Guid.NewGuid():N}.zip");
        try { ZipFile.CreateFromDirectory(folder, outPath, CompressionLevel.Fastest, includeBaseDirectory: true); return outPath; }
        catch (Exception e) { Log.Line($"PEER: zip failed: {e.Message}"); return null; }
    }

    private void StartNext()
    {
        if (_out is not null || _pending.Count == 0) return;
        var (path, name) = _pending.Dequeue();
        bool isTemp = path.StartsWith(Path.GetTempPath(), StringComparison.OrdinalIgnoreCase) && Path.GetFileName(path).StartsWith("clamshell-");
        FileStream fs;
        try { fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite); }
        catch { Report($"could not read {name}"); StartNext(); return; }
        ulong size = (ulong)fs.Length;
        if (size > PeerLimits.MaxFileSize) { fs.Dispose(); Report($"{name} is larger than the {PeerLimits.MaxFileSize >> 30} GiB limit"); StartNext(); return; }
        uint id = _nextId++;
        _out = new Outgoing { Id = id, Name = name, Size = size, File = fs, Cleanup = isTemp ? path : null };
        Log.Line($"PEER: offering {name} ({size} bytes) as transfer {id}");
        Send(PeerMsg.FileOffer(id, size, name), () => { });
        _acceptTimeout?.Cancel();
        var cts = _acceptTimeout = new CancellationTokenSource();
        Task.Delay(TimeSpan.FromSeconds(60), cts.Token).ContinueWith(t =>
        {
            if (t.IsCanceled) return;
            _q.Post(() =>
            {
                if (_out is { } o && o.Id == id && !o.Accepted)
                {
                    Send(PeerMsg.FileCancel(id, PeerRejectReason.Error), () => { });
                    FinishOutgoing($"peer did not answer the offer for {name}");
                }
            });
        });
    }

    private void Pump()
    {
        if (_out is not { Accepted: true } o) return;
        while (o.InFlight < MaxInFlight && o.Offset < o.Size)
        {
            int n = (int)Math.Min((ulong)PeerLimits.ChunkSize, o.Size - o.Offset);
            var bytes = new byte[n];
            int got = 0;
            try { while (got < n) { int r = o.File.Read(bytes, got, n - got); if (r == 0) break; got += r; } }
            catch { got = -1; }
            if (got != n)
            {
                Send(PeerMsg.FileCancel(o.Id, PeerRejectReason.Error), () => { });
                FinishOutgoing($"read error in {o.Name}");
                return;
            }
            o.Hasher.AppendData(bytes);
            uint id = o.Id;
            Send(PeerMsg.FileChunk(id, o.Offset, bytes), () => _q.Post(() =>
            {
                if (_out is { } cur && cur.Id == id) { cur.InFlight--; Pump(); }
            }));
            o.Offset += (ulong)n;
            o.InFlight++;
        }
        if (o.Offset == o.Size && o.InFlight == 0)
        {
            Send(PeerMsg.FileDone(o.Id, o.Hasher.GetHashAndReset()), () => { });
            Log.Line($"PEER: sent {o.Name}");
            OnSent?.Invoke(o.Name);
            FinishOutgoing(null);
        }
    }

    private void FinishOutgoing(string? error)
    {
        _acceptTimeout?.Cancel(); _acceptTimeout = null;
        if (_out is { } o)
        {
            o.File.Dispose();
            if (o.Cleanup is { } tmp) { try { File.Delete(tmp); } catch { } }
        }
        _out = null;
        if (error is not null) Report(error);
        StartNext();
    }

    // MARK: - Receiving / control (any thread)

    /// True when <paramref name="type"/> is a file-transfer message.
    public bool Receive(MessageType type, byte[] payload)
    {
        switch (type)
        {
            case MessageType.FileOffer: case MessageType.FileAccept: case MessageType.FileReject:
            case MessageType.FileChunk: case MessageType.FileDone: case MessageType.FileCancel:
                _q.Post(() => Handle(type, payload));
                return true;
            default:
                return false;
        }
    }

    private void Handle(MessageType type, byte[] payload)
    {
        switch (type)
        {
            case MessageType.FileAccept:
                if (PeerParse.WindowId(payload) is { } aid && _out is { } o && o.Id == aid && !o.Accepted)
                {
                    o.Accepted = true;
                    _acceptTimeout?.Cancel();
                    Pump();
                }
                break;
            case MessageType.FileReject:
                if (PeerParse.IdAndReason(payload) is { } rj && _out?.Id == rj.Id)
                    FinishOutgoing($"peer declined {_out.Name} ({rj.Reason})");
                break;
            case MessageType.FileCancel:
                if (PeerParse.IdAndReason(payload) is { } c)
                {
                    if (_out?.Id == c.Id) FinishOutgoing($"peer cancelled {_out.Name}");
                    if (_in.Remove(c.Id, out var inc)) Discard(inc, "sender cancelled");
                }
                break;
            case MessageType.FileOffer:
                if (PeerParse.FileOffer(payload) is { } offer) Accept(offer);
                break;
            case MessageType.FileChunk:
            {
                if (PeerParse.FileChunk(payload) is not { } ch || !_in.TryGetValue(ch.TransferId, out var inc)) break;
                if (ch.Offset != inc.Written || inc.Written + (ulong)ch.Bytes.Length > inc.Size)
                {
                    _in.Remove(ch.TransferId);
                    Send(PeerMsg.FileCancel(ch.TransferId, PeerRejectReason.Error), () => { });
                    Discard(inc, "out-of-order or oversized chunk");
                    break;
                }
                try { inc.File.Write(ch.Bytes); }
                catch (Exception e)
                {
                    _in.Remove(ch.TransferId);
                    Send(PeerMsg.FileCancel(ch.TransferId, PeerRejectReason.Disk), () => { });
                    Discard(inc, $"disk write failed: {e.Message}");
                    break;
                }
                inc.Hasher.AppendData(ch.Bytes);
                inc.Written += (ulong)ch.Bytes.Length;
                break;
            }
            case MessageType.FileDone:
            {
                if (PeerParse.FileDone(payload) is not { } d || !_in.Remove(d.Id, out var inc)) break;
                inc.File.Dispose();
                var digest = inc.Hasher.GetHashAndReset();
                if (inc.Written != inc.Size || !digest.AsSpan().SequenceEqual(d.Sha256))
                {
                    Discard(inc, $"size/hash mismatch ({inc.Written}/{inc.Size} bytes)");
                    break;
                }
                string dest = PeerFileNames.UniquePath(_dir, inc.Name);
                try
                {
                    File.Move(inc.PartPath, dest);
                    try { File.SetAttributes(dest, File.GetAttributes(dest) & ~FileAttributes.Hidden); } catch { }
                    Log.Line($"PEER: received {Path.GetFileName(dest)} ({inc.Size} bytes, sha256 ok)");
                    OnReceived?.Invoke(dest);
                }
                catch (Exception e) { Discard(inc, $"could not move into place: {e.Message}"); }
                break;
            }
        }
    }

    private void Accept(FileOfferPayload offer)
    {
        string name = PeerFileNames.Sanitize(offer.Name);
        if (_in.ContainsKey(offer.TransferId)) return;
        if (_in.Count >= MaxIncoming) { Send(PeerMsg.FileReject(offer.TransferId, PeerRejectReason.Busy), () => { }); return; }
        if (offer.Size > PeerLimits.MaxFileSize) { Send(PeerMsg.FileReject(offer.TransferId, PeerRejectReason.TooLarge), () => { }); return; }
        try { Directory.CreateDirectory(_dir); } catch { }
        try
        {
            var drive = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(_dir))!);
            if (drive.AvailableFreeSpace > 0 && (ulong)drive.AvailableFreeSpace < offer.Size + (256UL << 20))
            { Send(PeerMsg.FileReject(offer.TransferId, PeerRejectReason.Disk), () => { }); return; }
        }
        catch { /* unknown free space: try anyway, a write failure cancels */ }
        string part = Path.Combine(_dir, $".clamshell-{offer.TransferId}-{Guid.NewGuid().ToString("N")[..8]}.part");
        FileStream fs;
        try
        {
            fs = new FileStream(part, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            try { File.SetAttributes(part, FileAttributes.Hidden); } catch { }
        }
        catch { Send(PeerMsg.FileReject(offer.TransferId, PeerRejectReason.Disk), () => { }); return; }
        _in[offer.TransferId] = new Incoming { Id = offer.TransferId, Name = name, Size = offer.Size, PartPath = part, File = fs };
        Log.Line($"PEER: accepting {name} ({offer.Size} bytes)");
        Send(PeerMsg.FileAccept(offer.TransferId), () => { });
    }

    private void Discard(Incoming inc, string why)
    {
        try { inc.File.Dispose(); } catch { }
        try { File.Delete(inc.PartPath); } catch { }
        Report($"dropped incoming {inc.Name}: {why}");
    }

    private void Report(string msg)
    {
        Log.Line($"PEER: file transfer: {msg}");
        OnFailed?.Invoke(msg);
    }

    /// Link dropped: abandon everything, delete partial files.
    public void Reset()
    {
        _q.Post(() =>
        {
            _pending.Clear();
            if (_out is not null) FinishOutgoing("link dropped");
            foreach (var inc in _in.Values) Discard(inc, "link dropped");
            _in.Clear();
        });
    }

    public void Drain() => _q.Drain();
}
