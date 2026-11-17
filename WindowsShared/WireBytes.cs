using System.Buffers.Binary;

namespace Clamshell.Auth;

// Plain C# with no WPF, no sockets and no Windows-only calls, so the Windows
// viewer, the Windows host (later) and the macOS interop test can all compile
// it. Ported one for one from Sources/Clamshell/Streaming/SecureSession.swift;
// tests/vectors/auth-v1.json pins every byte.

/// <summary>Message type bytes of the stream protocol (PROTOCOL.md).</summary>
public static class WireType
{
    public const byte Hello = 0x01;
    public const byte HelloAck = 0x02;
    public const byte ClientDisplays = 0x03;
    public const byte Ping = 0x07;
    public const byte AuthChallenge = 0x08;
    public const byte AuthResponse = 0x09;
    public const byte AuthResult = 0x0A;
    public const byte HostInfo = 0x0B;
    public const byte ClientInfo = 0x0C;
    public const byte Secure = 0x0F;
}

/// <summary>Capability bits (PROTOCOL.md "Capabilities").</summary>
public static class Caps
{
    public const uint ApprovalRequired = 1u << 0;
    public const uint RelativeMouse = 1u << 1;
    public const uint TextInput = 1u << 2;
    public const uint ExtraButtons = 1u << 3;
    public const uint DeviceApproval = 1u << 4;
    public const uint FileTransfer = 1u << 5;
    public const uint Peripherals = 1u << 6;
}

public static class Wire
{
    public static byte[] Concat(params byte[][] parts)
    {
        int total = 0;
        foreach (var p in parts) total += p.Length;
        var result = new byte[total];
        int at = 0;
        foreach (var p in parts)
        {
            Buffer.BlockCopy(p, 0, result, at, p.Length);
            at += p.Length;
        }
        return result;
    }

    public static byte[] U16(ushort v)
    {
        var b = new byte[2];
        BinaryPrimitives.WriteUInt16BigEndian(b, v);
        return b;
    }

    public static byte[] U32(uint v)
    {
        var b = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(b, v);
        return b;
    }

    public static byte[] U64(ulong v)
    {
        var b = new byte[8];
        BinaryPrimitives.WriteUInt64BigEndian(b, v);
        return b;
    }

    public static uint ReadU32(byte[] data, int offset) =>
        BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(offset, 4));

    public static byte[] Slice(byte[] data, int start, int count)
    {
        var r = new byte[count];
        Buffer.BlockCopy(data, start, r, 0, count);
        return r;
    }

    /// <summary>One whole message: type, 4-byte big-endian length, payload.</summary>
    public static byte[] Frame(byte type, byte[] payload) =>
        Concat(new[] { type }, U32((uint)payload.Length), payload);

    public static bool SameBytes(byte[]? a, byte[]? b)
    {
        if (a is null || b is null) return a is null && b is null;
        return a.AsSpan().SequenceEqual(b);
    }
}
