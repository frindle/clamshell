namespace Clamshell;

// ClamshellPeerTests [peerinterop …] — same entry points as
// `ClamshellServer peerselftest` / `peerinterop`, on any OS.
internal static class PeerTestsMain
{
    private static int Main(string[] a) =>
        a.Length > 0 && a[0] == "peerinterop" ? PeerSelfTest.RunInterop(a[1..]) : PeerSelfTest.Run();
}
