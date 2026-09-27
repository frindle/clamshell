namespace Clamshell;

// Pure geometry for the shared-desk KVM — the mirror of
// Sources/Clamshell/Peer/EdgeGeometry.swift, same rules, same selftest cases
// (PeerSelfTest.cs "edge"). Coordinates are virtual-screen pixels, top-left
// origin (what GetCursorPos / the low-level mouse hook report once the
// process is per-monitor DPI aware).

/// CGRect semantics: contains [X, X+W) × [Y, Y+H).
internal readonly record struct Rect(double X, double Y, double W, double H)
{
    public double MinX => X; public double MinY => Y;
    public double MaxX => X + W; public double MaxY => Y + H;
    public bool Contains(double px, double py) => px >= X && px < X + W && py >= Y && py < Y + H;
}

internal static class EdgeGeometry
{
    /// If (px,py) sits on <paramref name="edge"/> of the display containing
    /// it, no other display continues past that edge there, and the pointer
    /// is being pushed outward, returns the display and the 0…1 position
    /// along that edge. Otherwise null.
    public static (Rect Display, double Fraction)? Exit(double px, double py, double dx, double dy, PeerEdge edge, IReadOnlyList<Rect> displays)
    {
        Rect? found = null;
        foreach (var r in displays) if (r.Contains(px, py)) { found = r; break; }
        found ??= Nearest(px, py, displays);
        if (found is not { } d) return null;
        const double slack = 1;
        bool atEdge, pushing; double bx, by, fraction;
        switch (edge)
        {
            case PeerEdge.Left:
                atEdge = px <= d.MinX + slack; pushing = dx < 0; bx = d.MinX - 2; by = py; fraction = (py - d.MinY) / d.H; break;
            case PeerEdge.Right:
                atEdge = px >= d.MaxX - 1 - slack; pushing = dx > 0; bx = d.MaxX + 1; by = py; fraction = (py - d.MinY) / d.H; break;
            case PeerEdge.Top:
                atEdge = py <= d.MinY + slack; pushing = dy < 0; bx = px; by = d.MinY - 2; fraction = (px - d.MinX) / d.W; break;
            default:
                atEdge = py >= d.MaxY - 1 - slack; pushing = dy > 0; bx = px; by = d.MaxY + 1; fraction = (px - d.MinX) / d.W; break;
        }
        if (!atEdge || !pushing) return null;
        foreach (var r in displays) if (r.Contains(bx, by)) return null;
        return (d, Math.Clamp(fraction, 0, 1));
    }

    /// Where the local cursor reappears when control comes back through
    /// <paramref name="edge"/>, inset so the next move doesn't cross again.
    public static (double X, double Y) ReentryPoint(Rect d, PeerEdge edge, double fraction)
    {
        const double inset = 3;
        double f = Math.Clamp(fraction, 0, 1);
        return edge switch
        {
            PeerEdge.Left => (d.MinX + inset, d.MinY + f * (d.H - 1)),
            PeerEdge.Right => (d.MaxX - 1 - inset, d.MinY + f * (d.H - 1)),
            PeerEdge.Top => (d.MinX + f * (d.W - 1), d.MinY + inset),
            _ => (d.MinX + f * (d.W - 1), d.MaxY - 1 - inset),
        };
    }

    private static Rect? Nearest(double px, double py, IReadOnlyList<Rect> displays)
    {
        Rect? best = null; double bestD = double.MaxValue;
        foreach (var r in displays)
        {
            double ddx = Math.Max(Math.Max(r.MinX - px, 0), px - r.MaxX), ddy = Math.Max(Math.Max(r.MinY - py, 0), py - r.MaxY);
            double dist = ddx * ddx + ddy * ddy;
            if (dist < bestD) { bestD = dist; best = r; }
        }
        return best;
    }

    public static double SpeedScale(double localWidth, double peerWidth) =>
        localWidth > 0 && peerWidth > 0 ? Math.Clamp(peerWidth / localWidth, 0.5, 3) : 1;
}

/// The controller's virtual cursor on the peer's screen, in the peer's units.
internal sealed class RemoteCursor
{
    public double Width { get; }
    public double Height { get; }
    public PeerEdge EntryEdge { get; }
    public double X { get; private set; }
    public double Y { get; private set; }

    public RemoteCursor(PeerEdge entryEdge, double fraction, double peerWidth, double peerHeight)
    {
        Width = Math.Max(peerWidth, 1); Height = Math.Max(peerHeight, 1);
        EntryEdge = entryEdge;
        double f = Math.Clamp(fraction, 0, 1), w = Width - 1, h = Height - 1;
        (X, Y) = entryEdge switch
        {
            PeerEdge.Left => (0, f * h),
            PeerEdge.Right => (w, f * h),
            PeerEdge.Top => (f * w, 0),
            _ => (f * w, h),
        };
    }

    /// Applies a delta; returns the 0…1 along-edge position when the cursor
    /// leaves through the entry edge (control goes home), else null.
    public double? Move(double dx, double dy)
    {
        double px = X + dx, py = Y + dy, w = Width - 1, h = Height - 1;
        bool out_ = EntryEdge switch
        {
            PeerEdge.Left => px < 0,
            PeerEdge.Right => px > w,
            PeerEdge.Top => py < 0,
            _ => py > h,
        };
        X = Math.Clamp(px, 0, w); Y = Math.Clamp(py, 0, h);
        if (!out_) return null;
        return EntryEdge is PeerEdge.Left or PeerEdge.Right ? (h > 0 ? Y / h : 0) : (w > 0 ? X / w : 0);
    }

    public (float X, float Y) Normalized => ((float)(X / Math.Max(Width - 1, 1)), (float)(Y / Math.Max(Height - 1, 1)));
}
