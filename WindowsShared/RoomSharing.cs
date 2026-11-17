using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace Clamshell.Auth;

// How a host shares out the room in its three small tables (connections that
// have not answered the challenge, connections waiting for approval, devices on
// the waiting list) so that one source cannot fill them all (PROTOCOL.md "Host
// rules"). The group is used for nothing else: an address is never a reason to
// trust a device. Mirrors Sources/Clamshell/Auth/RoomSharing.swift.

/// <summary>An address reduced to the group that shares one slice of each table.</summary>
public static class AddressGroup
{
    public const string Unknown = "unknown";

    /// <summary>An IPv4 address as it is; an IPv4-mapped IPv6 address as its IPv4
    /// address; any other IPv6 address as its first 64 bits ("2001:db8:0:0/64").
    /// Port and scope are dropped. Anything else, empty or unusable, is "unknown".</summary>
    public static string Of(string address)
    {
        var text = address.Trim();
        if (text.StartsWith('['))
        {
            // "[2001:db8::1]:443"
            int close = text.IndexOf(']');
            if (close < 0) return Unknown;
            text = text.Substring(1, close - 1);
        }
        else if (CountOf(text, ':') == 1)
        {
            // "192.0.2.1:443"
            text = text.Substring(0, text.IndexOf(':'));
        }
        int scope = text.IndexOf('%');
        if (scope >= 0) text = text.Substring(0, scope);
        if (text.Length == 0) return Unknown;

        if (text.Contains(':'))
        {
            if (!IPAddress.TryParse(text, out var ip) || ip.AddressFamily != AddressFamily.InterNetworkV6) return Unknown;
            var bytes = ip.GetAddressBytes();
            bool mapped = true;
            for (int i = 0; i < 10; i++) if (bytes[i] != 0) mapped = false;
            if (mapped && bytes[10] == 0xff && bytes[11] == 0xff) return Dotted(bytes, 12);
            var groups = new string[4];
            for (int i = 0; i < 4; i++)
                groups[i] = ((bytes[2 * i] << 8) | bytes[2 * i + 1]).ToString("x", CultureInfo.InvariantCulture);
            return string.Join(":", groups) + "/64";
        }
        var parts = text.Split('.');
        if (parts.Length != 4) return Unknown;
        var v4 = new byte[4];
        for (int i = 0; i < 4; i++)
        {
            var p = parts[i];
            if (p.Length == 0 || p.Length > 3) return Unknown;
            foreach (var c in p) if (c < '0' || c > '9') return Unknown;
            int n = int.Parse(p, CultureInfo.InvariantCulture);
            if (n > 255) return Unknown;
            v4[i] = (byte)n;
        }
        return Dotted(v4, 0);
    }

    private static int CountOf(string s, char c)
    {
        int n = 0;
        foreach (var x in s) if (x == c) n++;
        return n;
    }

    private static string Dotted(byte[] b, int offset) =>
        string.Join(".", b[offset], b[offset + 1], b[offset + 2], b[offset + 3]);
}

/// <summary>One pure decision, used by all three tables: no clock, no sockets.</summary>
public static class RoomSharing
{
    public sealed record Entry(string Group, double Age, bool Removable = true);

    public enum VerdictKind { Admit, Replace, TurnAway }

    /// <summary>Index is the entry that is replaced, for <see cref="VerdictKind.Replace"/>.</summary>
    public readonly record struct Verdict(VerdictKind Kind, int Index = -1)
    {
        public static Verdict Admit => new(VerdictKind.Admit);
        public static Verdict TurnAway => new(VerdictKind.TurnAway);
        public static Verdict Replace(int i) => new(VerdictKind.Replace, i);
    }

    /// <summary>
    /// - There is room and the arrival's group is under its share: admit.
    /// - The arrival's group is at its share: it takes the place of that group's
    ///   first removable entry, or is turned away if it has none.
    /// - The table is full: the group holding the most entries is picked (the one
    ///   whose first entry comes first, on a tie). If the arrival's group holds
    ///   fewer, the arrival takes the place of the picked group's first removable
    ///   entry, or is turned away if it has none. Otherwise it is turned away.
    /// </summary>
    public static Verdict Decide(IReadOnlyList<Entry> entries, int size, int share, string group)
    {
        int? FirstRemovable(string g)
        {
            int? best = null;
            for (int i = 0; i < entries.Count; i++)
            {
                if (entries[i].Group != g || !entries[i].Removable) continue;
                if (best == null || entries[i].Age > entries[best.Value].Age) best = i;
            }
            return best;
        }

        int own = 0;
        foreach (var e in entries) if (e.Group == group) own++;
        if (own >= share)
        {
            var r = FirstRemovable(group);
            return r == null ? Verdict.TurnAway : Verdict.Replace(r.Value);
        }
        if (entries.Count < size) return Verdict.Admit;

        var counts = new Dictionary<string, int>();
        var order = new List<string>();
        foreach (var e in entries)
        {
            if (!counts.ContainsKey(e.Group)) { order.Add(e.Group); counts[e.Group] = 0; }
            counts[e.Group]++;
        }
        string? heaviest = null;
        foreach (var g in order)
        {
            if (heaviest == null || counts[g] > counts[heaviest]) heaviest = g;
        }
        if (heaviest == null || own >= counts[heaviest]) return Verdict.TurnAway;
        var pick = FirstRemovable(heaviest);
        return pick == null ? Verdict.TurnAway : Verdict.Replace(pick.Value);
    }
}

/// <summary>Names a device gives itself, for display. Mirrors the first half of
/// Sources/Clamshell/Auth/NameSkeleton.swift.</summary>
public static class NameSkeleton
{
    /// <summary>Characters that draw nothing: the default-ignorable code points and
    /// the Hangul and braille blanks that are not marked as such.</summary>
    public static bool DrawsNothing(Rune r)
    {
        int v = r.Value;
        if (Rune.GetUnicodeCategory(r) == UnicodeCategory.Format) return true;
        return v == 0x00AD || v == 0x034F || v == 0x061C || v == 0x115F || v == 0x1160
            || v == 0x17B4 || v == 0x17B5 || (v >= 0x180B && v <= 0x180F)
            || v == 0x3164 || (v >= 0xFE00 && v <= 0xFE0F) || v == 0xFFA0
            || (v >= 0xFFF0 && v <= 0xFFF8) || (v >= 0xE0000 && v <= 0xE0FFF) || v == 0x2800;
    }

    /// <summary>The name without the characters that draw nothing. Names the host
    /// stores or shows go through this after <see cref="AuthWire.CleanName"/>.</summary>
    public static string Visible(string name)
    {
        var sb = new StringBuilder();
        foreach (var r in name.EnumerateRunes())
        {
            if (!DrawsNothing(r)) sb.Append(r.ToString());
        }
        return sb.ToString().Trim(' ', '\t');
    }
}
