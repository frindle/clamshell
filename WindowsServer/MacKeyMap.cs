namespace Clamshell;

// The wire protocol carries macOS virtual key codes (kVK_*) — the iOS client
// sends whatever it would send to a Mac host, unchanged. A Windows host must
// translate them to Win32 virtual-key codes (VK_*) before SendInput.
//
// Modifier policy: mac Command is the primary shortcut modifier; on Windows the
// equivalent is Ctrl, so BOTH mac Command and mac Control map to VK_CONTROL
// (Cmd+C -> Ctrl+C "just works"). Option -> Alt, Shift -> Shift.
//
// ponytail: covers the standard US-layout key set. Exotic/keypad keys not in
// the table fall through unmapped (logged once); add rows if a user hits one.
internal static class MacKeyMap
{
    // Win32 VK_* constants used below.
    private const ushort VK_BACK = 0x08, VK_TAB = 0x09, VK_RETURN = 0x0D, VK_SHIFT = 0x10,
        VK_CONTROL = 0x11, VK_MENU = 0x12, VK_CAPITAL = 0x14, VK_ESCAPE = 0x1B, VK_SPACE = 0x20,
        VK_PRIOR = 0x21, VK_NEXT = 0x22, VK_END = 0x23, VK_HOME = 0x24, VK_LEFT = 0x25,
        VK_UP = 0x26, VK_RIGHT = 0x27, VK_DOWN = 0x28, VK_DELETE = 0x2E, VK_LWIN = 0x5B,
        VK_OEM_1 = 0xBA, VK_OEM_PLUS = 0xBB, VK_OEM_COMMA = 0xBC, VK_OEM_MINUS = 0xBD,
        VK_OEM_PERIOD = 0xBE, VK_OEM_2 = 0xBF, VK_OEM_3 = 0xC0, VK_OEM_4 = 0xDB,
        VK_OEM_5 = 0xDC, VK_OEM_6 = 0xDD, VK_OEM_7 = 0xDE;

    private static readonly Dictionary<ushort, ushort> Map = new()
    {
        // Letters (mac kVK_ANSI_* -> Win 'A'..'Z' = 0x41..0x5A)
        [0]='A', [1]='S', [2]='D', [3]='F', [4]='H', [5]='G', [6]='Z', [7]='X', [8]='C',
        [9]='V', [11]='B', [12]='Q', [13]='W', [14]='E', [15]='R', [16]='Y', [17]='T',
        [31]='O', [32]='U', [34]='I', [35]='P', [37]='L', [38]='J', [40]='K', [45]='N',
        [46]='M',
        // Digits (mac -> Win '0'..'9' = 0x30..0x39)
        [18]='1', [19]='2', [20]='3', [21]='4', [22]='6', [23]='5', [25]='9', [26]='7',
        [28]='8', [29]='0',
        // Punctuation
        [24]=VK_OEM_PLUS, [27]=VK_OEM_MINUS, [30]=VK_OEM_6, [33]=VK_OEM_4, [39]=VK_OEM_7,
        [41]=VK_OEM_1, [42]=VK_OEM_5, [43]=VK_OEM_COMMA, [44]=VK_OEM_2, [47]=VK_OEM_PERIOD,
        [50]=VK_OEM_3,
        // Whitespace / editing
        [36]=VK_RETURN, [48]=VK_TAB, [49]=VK_SPACE, [51]=VK_BACK, [53]=VK_ESCAPE,
        [117]=VK_DELETE,
        // Modifiers (Command AND Control both -> Ctrl; see policy above)
        [55]=VK_CONTROL, [59]=VK_CONTROL, [54]=VK_CONTROL, [62]=VK_CONTROL,
        [56]=VK_SHIFT, [60]=VK_SHIFT, [58]=VK_MENU, [61]=VK_MENU, [57]=VK_CAPITAL,
        // Arrows / navigation
        [123]=VK_LEFT, [124]=VK_RIGHT, [125]=VK_DOWN, [126]=VK_UP,
        [115]=VK_HOME, [119]=VK_END, [116]=VK_PRIOR, [121]=VK_NEXT,
        // Function keys F1..F12 (Win VK_F1=0x70..VK_F12=0x7B)
        [122]=0x70, [120]=0x71, [99]=0x72, [118]=0x73, [96]=0x74, [97]=0x75,
        [98]=0x76, [100]=0x77, [101]=0x78, [109]=0x79, [103]=0x7A, [111]=0x7B,
    };

    /// <summary>Maps a macOS virtual key code to a Win32 VK, or null if unmapped.</summary>
    public static ushort? ToWindows(ushort macKeyCode) =>
        Map.TryGetValue(macKeyCode, out var vk) ? vk : null;
}
