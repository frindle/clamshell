namespace Clamshell;

// Windows keyboard → the wire's macOS key codes and CGEventFlags, for a PC
// driving a Mac (the reverse of MacKeyMap). Modifier policy mirrors
// MacKeyMap's (Mac Command ⇄ Windows Ctrl, so Ctrl+C on the PC is Cmd+C on
// the Mac):
//   Ctrl → Command (55/54)   Win → Control (59/62)   Alt → Option (58/61)
//   Shift → Shift (56/60)    Caps Lock → 57 (sent as a tap, like the Mac)
// Panic key while controlling the peer: Ctrl+Alt+Shift+L.
internal static class PeerKeys
{
    public const ulong FlagAlphaShift = 0x10000, FlagShift = 0x20000, FlagControl = 0x40000,
        FlagAlternate = 0x80000, FlagCommand = 0x100000, FlagNumericPad = 0x200000;

    public const uint VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_CAPITAL = 0x14, VK_ESCAPE = 0x1B,
        VK_LWIN = 0x5B, VK_RWIN = 0x5C, VK_LSHIFT = 0xA0, VK_RSHIFT = 0xA1, VK_LCONTROL = 0xA2,
        VK_RCONTROL = 0xA3, VK_LMENU = 0xA4, VK_RMENU = 0xA5, VK_RETURN = 0x0D;

    private static readonly Dictionary<uint, ushort> Modifiers = new()
    {
        [VK_LCONTROL] = 55, [VK_RCONTROL] = 54, [VK_CONTROL] = 55,
        [VK_LWIN] = 59, [VK_RWIN] = 62,
        [VK_LMENU] = 58, [VK_RMENU] = 61, [VK_MENU] = 58,
        [VK_LSHIFT] = 56, [VK_RSHIFT] = 60, [VK_SHIFT] = 56,
        [VK_CAPITAL] = 57,
    };

    private static readonly Dictionary<uint, ushort> Plain = BuildPlain();

    private static Dictionary<uint, ushort> BuildPlain()
    {
        var d = new Dictionary<uint, ushort>();
        foreach (var (mac, vk) in MacKeyMap.All)
        {
            if (Modifiers.ContainsKey(vk) || vk is 0x10 or 0x11 or 0x12) continue;
            if (mac == 76) continue; // keypad Enter: VK_RETURN + extended, handled below
            d.TryAdd(vk, mac);
        }
        return d;
    }

    /// Mac key code for a low-level-hook vkCode, or null if unmapped.
    /// <paramref name="extended"/> = LLKHF_EXTENDED (keypad Enter).
    public static ushort? MacCode(uint vk, bool extended)
    {
        if (vk == VK_RETURN && extended) return 76;
        if (Modifiers.TryGetValue(vk, out var m)) return m;
        return Plain.TryGetValue(vk, out var c) ? c : null;
    }

    /// CGEventFlags bit carried while this mac modifier key is down.
    public static ulong ModifierBit(ushort macCode) => macCode switch
    {
        54 or 55 => FlagCommand,
        56 or 60 => FlagShift,
        58 or 61 => FlagAlternate,
        59 or 62 => FlagControl,
        57 => FlagAlphaShift,
        _ => 0,
    };

    public static bool IsModifier(ushort macCode) => ModifierBit(macCode) != 0;

    /// Mac keypad codes carry the numeric-pad flag, as on a real Mac keyboard.
    public static bool IsKeypad(ushort macCode) => macCode is 65 or 67 or 69 or 71 or 75 or 76 or 78 or 81 or (>= 82 and <= 92);

    /// Ctrl+Alt+Shift+L (with the modifier state tracked by the hook).
    public static bool IsPanic(uint vk, ulong flags) =>
        vk == 'L' && (flags & FlagCommand) != 0 && (flags & FlagAlternate) != 0 && (flags & FlagShift) != 0;
}
