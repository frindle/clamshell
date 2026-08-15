namespace Clamshell;

// The wire protocol always carries macOS virtual key codes (kVK_*) --
// PROTOCOL.md: "Key codes are macOS virtual key codes (client is responsible
// for any translation)". This viewer runs on Windows, so it must translate
// local Win32 virtual-key codes to mac codes before sending INPUT_KEY -- the
// exact inverse direction of WindowsServer/MacKeyMap.cs (which translates
// incoming mac codes to Win32 VKs for a Windows *host* to inject). Kept as
// its own small table rather than sharing code with that project (see
// Protocol.cs's header for why these two projects don't reference each
// other) -- built by hand-inverting that table.
//
// Modifier policy (inverse of the host's): Windows Ctrl -> mac Command (the
// primary shortcut modifier on a Mac), Alt -> Option, Shift -> Shift. Left
// and right variants collapse to the same mac code.
//
// ponytail: standard US-layout key set only, same scope as the host's table.
// Exotic/keypad keys not listed fall through unmapped (silently ignored);
// add rows if a user hits one.
internal static class MacKeyMap
{
    private static readonly Dictionary<ushort, ushort> Map = new()
    {
        // Letters (Win 'A'..'Z' = 0x41..0x5A -> mac kVK_ANSI_*)
        ['A']=0, ['S']=1, ['D']=2, ['F']=3, ['H']=4, ['G']=5, ['Z']=6, ['X']=7, ['C']=8,
        ['V']=9, ['B']=11, ['Q']=12, ['W']=13, ['E']=14, ['R']=15, ['Y']=16, ['T']=17,
        ['O']=31, ['U']=32, ['I']=34, ['P']=35, ['L']=37, ['J']=38, ['K']=40, ['N']=45,
        ['M']=46,
        // Digits (Win '0'..'9' = 0x30..0x39 -> mac)
        ['1']=18, ['2']=19, ['3']=20, ['4']=21, ['6']=22, ['5']=23, ['9']=25, ['7']=26,
        ['8']=28, ['0']=29,
        // Punctuation (Win VK_OEM_*)
        [0xBB]=24, [0xBD]=27, [0xDD]=30, [0xDB]=33, [0xDE]=39,
        [0xBA]=41, [0xDC]=42, [0xBC]=43, [0xBF]=44, [0xBE]=47,
        [0xC0]=50,
        // Whitespace / editing
        [0x0D]=36, [0x09]=48, [0x20]=49, [0x08]=51, [0x1B]=53, [0x2E]=117,
        // Modifiers -- both Win Ctrl AND Alt collapse toward mac Command/Option
        // per the policy above; VK_CONTROL (generic) -> Command.
        [0x11]=55, [0xA2]=55, [0xA3]=55, // VK_CONTROL, VK_LCONTROL, VK_RCONTROL -> Command
        [0x10]=56, [0xA0]=56, [0xA1]=56, // VK_SHIFT, VK_LSHIFT, VK_RSHIFT -> Shift
        [0x12]=58, [0xA4]=58, [0xA5]=58, // VK_MENU, VK_LMENU, VK_RMENU -> Option
        [0x14]=57, // VK_CAPITAL -> CapsLock
        // Arrows / navigation
        [0x25]=123, [0x27]=124, [0x28]=125, [0x26]=126,
        [0x24]=115, [0x23]=119, [0x21]=116, [0x22]=121,
        // Function keys (Win VK_F1=0x70..VK_F12=0x7B)
        [0x70]=122, [0x71]=120, [0x72]=99, [0x73]=118, [0x74]=96, [0x75]=97,
        [0x76]=98, [0x77]=100, [0x78]=101, [0x79]=109, [0x7A]=103, [0x7B]=111,
    };

    /// <summary>Maps a Win32 virtual key to a macOS virtual key code, or null
    /// if unmapped.</summary>
    public static ushort? ToMac(ushort winVk) =>
        Map.TryGetValue(winVk, out var mac) ? mac : null;
}
