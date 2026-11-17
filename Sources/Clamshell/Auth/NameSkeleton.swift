import Foundation

// Names a device gives itself, for display and for the hint "a device you
// already trust has the same name" (PROTOCOL.md "Approving a device"). The
// hint is never a check: a different device never becomes trusted because of
// its name, and a name that looks the same does not make it the same device.

enum NameSkeleton {
    /// Characters that draw nothing: the default-ignorable code points and the
    /// Hangul and braille blanks that are not marked as such.
    static func drawsNothing(_ u: Unicode.Scalar) -> Bool {
        if u.properties.isDefaultIgnorableCodePoint { return true }
        switch u.value {
        case 0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800: return true
        default: return false
        }
    }

    /// `name` without the characters that draw nothing. Names the host stores
    /// or shows go through this after `AuthWire.cleanName`.
    static func visible(_ name: String) -> String {
        var kept = String.UnicodeScalarView()
        for u in name.unicodeScalars where !drawsNothing(u) { kept.append(u) }
        return String(kept).trimmingCharacters(in: .whitespaces)
    }

    /// Every apostrophe and quote variant, written to `'`.
    private static let quotes: Set<UInt32> = [
        0x0022, 0x0027, 0x0060, 0x00AB, 0x00B4, 0x00BB, 0x02B9, 0x02BB, 0x02BC, 0x02BD, 0x02BE, 0x02BF,
        0x02C8, 0x02CA, 0x02CB, 0x0374, 0x0384, 0x055A, 0x05F3, 0x05F4, 0x1FBD, 0x1FBF, 0x1FEF, 0x1FFD,
        0x2018, 0x2019, 0x201A, 0x201B, 0x201C, 0x201D, 0x201E, 0x201F, 0x2032, 0x2033, 0x2035, 0x2036,
        0x2039, 0x203A, 0xA78C, 0xFF02, 0xFF07, 0xFF40,
    ]

    /// Cyrillic and Greek letters that look like a Latin letter, lowercase.
    private static let lookAlikes: [UInt32: Character] = [
        // Cyrillic
        0x0430: "a", 0x0432: "b", 0x0435: "e", 0x043A: "k", 0x043C: "m", 0x043D: "h",
        0x043E: "o", 0x0440: "p", 0x0441: "c", 0x0442: "t", 0x0443: "y", 0x0445: "x", 0x0455: "s",
        0x0456: "i", 0x0458: "j", 0x04CF: "l", 0x0501: "d", 0x051B: "q", 0x051D: "w", 0x04BB: "h",
        0x0475: "v", 0x0491: "r", 0x0493: "f", 0x04AF: "y", 0x0461: "w",
        // Greek
        0x03B1: "a", 0x03B2: "b", 0x03B3: "y", 0x03B5: "e", 0x03B7: "n", 0x03B9: "i", 0x03BA: "k",
        0x03BC: "u", 0x03BD: "v", 0x03BF: "o", 0x03C1: "p", 0x03C4: "t", 0x03C5: "u", 0x03C7: "x",
        0x03C9: "w", 0x03F2: "c", 0x03F3: "j",
        // Latin letters that are not decomposed
        0x0131: "i", 0x0142: "l", 0x0268: "i", 0x026A: "i", 0x01C0: "l",
    ]

    /// What a name looks like, for comparing two names: NFKD, no combining
    /// marks, nothing that draws nothing, case folded, Cyrillic and Greek
    /// look-alikes written as the Latin letter, every apostrophe and quote as
    /// `'`, `i`, `1`, `|` and dotless i as `l` and `0` as `o`, runs of white
    /// space as one space, no space at either end.
    static func of(_ name: String) -> String {
        // Quotes first: some of them decompose into a space and a mark.
        var quoted = String.UnicodeScalarView()
        for u in name.unicodeScalars { quoted.append(quotes.contains(u.value) ? "'" : u) }
        let decomposed = String(quoted).decomposedStringWithCompatibilityMapping
        let folded = strip(decomposed).folding(options: [.caseInsensitive], locale: nil)
        var out = ""
        for u in strip(folded).unicodeScalars {
            if quotes.contains(u.value) {
                out.append("'")
            } else if let latin = lookAlikes[u.value] {
                out.append(latin)
            } else {
                out.unicodeScalars.append(u)
            }
        }
        var mapped = ""
        for c in out.lowercased() {
            switch c {
            case "i", "1", "|", "\u{131}": mapped.append("l")
            case "0": mapped.append("o")
            default: mapped.append(c)
            }
        }
        return mapped.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// No combining marks, nothing that draws nothing.
    private static func strip(_ s: String) -> String {
        var kept = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: continue
            default: break
            }
            if !drawsNothing(u) { kept.append(u) }
        }
        return String(kept)
    }
}
