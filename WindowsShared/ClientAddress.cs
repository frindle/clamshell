using System.Net;
using System.Net.Sockets;

namespace Clamshell.Auth;

// Where a connection really came from when it arrives through a proxy: a web
// relay or a tunnel (cloudflared) that usually runs on this machine, so it
// reaches the stream server from 127.0.0.1. Without this every tunnel client
// would share one room-sharing group. Mirrors
// Sources/Clamshell/Auth/ClientAddress.swift.
//
// The result is used for the address groups and the log lines, nothing else.
// An address is never a reason to trust a device.

/// <summary>The proxies whose headers are believed: loopback always, plus the
/// addresses and CIDR ranges the user lists in the trusted proxies setting.</summary>
public sealed class TrustedProxies
{
    private readonly List<(byte[] Bytes, int Bits)> _ranges = new();

    /// <summary>Entries are "192.0.2.7", "198.51.100.0/24", "2001:db8::/32". An entry that
    /// cannot be read is ignored (a proxy not listed is not trusted).</summary>
    public TrustedProxies(IEnumerable<string>? entries = null)
    {
        if (entries == null) return;
        foreach (var entry in entries)
        {
            var parts = entry.Trim().Split('/', 2);
            var bytes = ClientAddress.Packed(parts[0]);
            if (bytes == null) continue;
            int bits = bytes.Length * 8;
            if (parts.Length == 2)
            {
                if (!int.TryParse(parts[1], System.Globalization.NumberStyles.None,
                        System.Globalization.CultureInfo.InvariantCulture, out int given) || given > bits) continue;
                bits = given;
            }
            _ranges.Add((bytes, bits));
        }
    }

    public bool Contains(string address)
    {
        var bytes = ClientAddress.Packed(address);
        if (bytes == null) return false;
        if (bytes.Length == 4 && bytes[0] == 127) return true;
        if (bytes.Length == 16 && bytes[15] == 1)
        {
            bool zeros = true;
            for (int i = 0; i < 15; i++) if (bytes[i] != 0) zeros = false;
            if (zeros) return true;
        }
        foreach (var (rb, bits) in _ranges)
        {
            if (rb.Length == bytes.Length && PrefixMatches(bytes, rb, bits)) return true;
        }
        return false;
    }

    private static bool PrefixMatches(byte[] a, byte[] b, int bits)
    {
        int whole = bits / 8;
        for (int i = 0; i < whole; i++) if (a[i] != b[i]) return false;
        int rest = bits % 8;
        if (rest == 0) return true;
        int mask = (0xFF << (8 - rest)) & 0xFF;
        return (a[whole] & mask) == (b[whole] & mask);
    }
}

public static class ClientAddress
{
    /// <summary>The address to group a connection by.
    /// - The TCP peer is not a trusted proxy: the peer, and headers are ignored.
    /// - CF-Connecting-IP when it holds an address.
    /// - Otherwise the right-most X-Forwarded-For entry that is not itself a trusted proxy,
    ///   when it holds an address.
    /// - Otherwise the peer.
    /// Header names are matched without regard to case.</summary>
    public static string Resolve(string peer, IReadOnlyList<(string Name, string Value)> headers, TrustedProxies trusted)
    {
        if (!trusted.Contains(peer)) return peer;
        IEnumerable<string> Values(string name) =>
            headers.Where(h => string.Equals(h.Name, name, StringComparison.OrdinalIgnoreCase)).Select(h => h.Value);
        var cf = Values("cf-connecting-ip").FirstOrDefault();
        if (cf != null)
        {
            var address = Clean(cf);
            if (address != null) return address;
        }
        var forwarded = Values("x-forwarded-for").SelectMany(v => v.Split(',')).ToList();
        for (int i = forwarded.Count - 1; i >= 0; i--)
        {
            var text = forwarded[i].Trim();
            var address = Clean(text);
            if (address != null && trusted.Contains(address)) continue;
            // The first entry from the right that is not a trusted proxy is the client;
            // if it cannot be read, nothing is believed.
            return address ?? peer;
        }
        return peer;
    }

    /// <summary>An address as plain text, or null when the text is not one. Accepts a bracketed
    /// IPv6 address, an IPv4 address with a port, and a scope.</summary>
    public static string? Clean(string raw)
    {
        var text = raw.Trim();
        if (text.StartsWith('['))
        {
            int close = text.IndexOf(']');
            if (close < 0) return null;
            text = text.Substring(1, close - 1);
        }
        else if (text.Count(c => c == ':') == 1)
        {
            text = text.Substring(0, text.IndexOf(':'));
        }
        int scope = text.IndexOf('%');
        if (scope >= 0) text = text.Substring(0, scope);
        return Packed(text) == null ? null : text;
    }

    /// <summary>4 bytes for an IPv4 address, 16 for an IPv6 one (an IPv4-mapped one as its 4
    /// IPv4 bytes), null for anything else.</summary>
    public static byte[]? Packed(string text)
    {
        if (text.Contains(':'))
        {
            if (!IPAddress.TryParse(text, out var ip) || ip.AddressFamily != AddressFamily.InterNetworkV6) return null;
            var bytes = ip.GetAddressBytes();
            bool mapped = bytes[10] == 0xff && bytes[11] == 0xff;
            for (int i = 0; i < 10 && mapped; i++) if (bytes[i] != 0) mapped = false;
            if (mapped) return new[] { bytes[12], bytes[13], bytes[14], bytes[15] };
            return bytes;
        }
        var parts = text.Split('.');
        if (parts.Length != 4) return null;
        var v4 = new byte[4];
        for (int i = 0; i < 4; i++)
        {
            var p = parts[i];
            if (p.Length == 0 || p.Length > 3) return null;
            foreach (var c in p) if (c < '0' || c > '9') return null;
            int n = int.Parse(p, System.Globalization.CultureInfo.InvariantCulture);
            if (n > 255) return null;
            v4[i] = (byte)n;
        }
        return v4;
    }
}
