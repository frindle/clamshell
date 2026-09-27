using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace Clamshell;

// Clipboard sync with a linked peer — the mirror of PeerClipboard.swift.
// Text rides the v1 CLIPBOARD message (UTF-8), images CLIPBOARD_DATA kind 1
// (PNG). Copying on Windows: the registered "PNG" format when an app put one
// there (browsers, Office), else the bitmap (CF_DIB) re-encoded as PNG.
// Pasting on Windows: both "PNG" and a bitmap are offered, since many apps
// only paste CF_DIB. Copied files (CF_HDROP) aren't synced — drag them
// across or use Send Files, which move the bytes.
//
// UI thread only (the WinForms Clipboard needs STA): polls the clipboard
// sequence number twice a second; our own writes re-baseline it.
internal sealed class PeerClipboard : IDisposable
{
    private const byte KindPng = 1;
    private uint _lastSeq;
    private System.Windows.Forms.Timer? _timer;
    public Action<byte[]> Send = _ => { };

    /// Starts watching; the current contents are NOT pushed (only new copies).
    public void Start()
    {
        _lastSeq = GetClipboardSequenceNumber();
        _timer?.Dispose();
        _timer = new System.Windows.Forms.Timer { Interval = 500 };
        _timer.Tick += (_, _) => Poll();
        _timer.Start();
    }

    public void Stop() { _timer?.Dispose(); _timer = null; }
    public void Dispose() => Stop();

    public void Poll()
    {
        uint c = GetClipboardSequenceNumber();
        if (c == _lastSeq) return;
        _lastSeq = c;
        try
        {
            if (Clipboard.ContainsText(TextDataFormat.UnicodeText))
            {
                string text = Clipboard.GetText(TextDataFormat.UnicodeText);
                int n = System.Text.Encoding.UTF8.GetByteCount(text);
                if (n > PeerLimits.MaxClipboardBytes) { Log.Line($"PEER: clipboard text too large to sync ({n} bytes)"); return; }
                Send(PeerMsg.ClipboardText(text));
            }
            else if (ReadPng() is { } png)
            {
                if (png.Length > PeerLimits.MaxClipboardBytes) { Log.Line($"PEER: clipboard image too large to sync ({png.Length} bytes)"); return; }
                Send(PeerMsg.ClipboardData(KindPng, png));
            }
        }
        catch (ExternalException e) { Log.Line($"PEER: clipboard busy ({e.Message}) — skipped"); }
    }

    private static byte[]? ReadPng()
    {
        if (Clipboard.GetData("PNG") is MemoryStream ms) return ms.ToArray();
        if (!Clipboard.ContainsImage()) return null;
        using var img = Clipboard.GetImage();
        if (img is null) return null;
        using var outMs = new MemoryStream();
        img.Save(outMs, ImageFormat.Png);
        return outMs.ToArray();
    }

    /// Returns true when the message was a clipboard message.
    public bool Receive(MessageType type, byte[] payload)
    {
        try
        {
            switch (type)
            {
                case MessageType.Clipboard:
                {
                    if (payload.Length > PeerLimits.MaxClipboardBytes) return true;
                    string text;
                    try { text = new System.Text.UTF8Encoding(false, true).GetString(payload); }
                    catch (System.Text.DecoderFallbackException) { return true; }
                    if (text.Length == 0) Clipboard.Clear(); else Clipboard.SetText(text, TextDataFormat.UnicodeText);
                    break;
                }
                case MessageType.ClipboardData:
                {
                    if (PeerParse.ClipboardData(payload) is not { Kind: KindPng } d) return true;
                    Bitmap bmp;
                    try { bmp = new Bitmap(new MemoryStream(d.Bytes)); } // must decode as an image
                    catch (ArgumentException) { return true; }
                    var obj = new DataObject();
                    obj.SetData("PNG", false, new MemoryStream(d.Bytes));
                    obj.SetData(DataFormats.Bitmap, true, bmp);
                    Clipboard.SetDataObject(obj, copy: true);
                    break;
                }
                default:
                    return false;
            }
        }
        catch (ExternalException e) { Log.Line($"PEER: could not write the clipboard ({e.Message})"); }
        _lastSeq = GetClipboardSequenceNumber(); // don't echo our own write back
        return true;
    }

    [DllImport("user32.dll")] private static extern uint GetClipboardSequenceNumber();
}
