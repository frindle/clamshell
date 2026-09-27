using System.Threading.Channels;

namespace Clamshell;

/// One background thread running posted actions in order — the C# stand-in
/// for a serial DispatchQueue on the Mac side.
internal sealed class SerialQueue
{
    private readonly Channel<Action> _ch = Channel.CreateUnbounded<Action>(new UnboundedChannelOptions { SingleReader = true });
    public SerialQueue(string name)
    {
        var t = new Thread(() =>
        {
            while (true)
            {
                Action a;
                try { a = _ch.Reader.ReadAsync().AsTask().GetAwaiter().GetResult(); }
                catch { return; }
                try { a(); } catch (Exception e) { Log.Line($"{name}: {e}"); }
            }
        }) { IsBackground = true, Name = name };
        t.Start();
    }
    public void Post(Action a) => _ch.Writer.TryWrite(a);
    /// Blocks until everything queued before this call has run.
    public void Drain() { using var done = new ManualResetEventSlim(); Post(done.Set); done.Wait(TimeSpan.FromSeconds(30)); }
}
