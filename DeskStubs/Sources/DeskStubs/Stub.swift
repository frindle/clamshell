/// Where the rules put an app, as far as stub generation cares (plan 9.2).
public enum StubPolicy: Equatable {
    case local
    case home(String)
    case anywhere
}

/// An app that Desk may host, as read from the Mac that has the real bundle.
public struct HostedApp: Equatable {
    public var bundleId: String
    /// The app's normal name; Spotlight finds the stub by it.
    public var name: String
    public var version: String
    /// Absolute path of the real app's .icns, resolved by the caller. nil means no icon.
    public var iconPath: String?
    public var policy: StubPolicy
    public init(bundleId: String, name: String, version: String = "1.0", iconPath: String? = nil, policy: StubPolicy) {
        self.bundleId = bundleId; self.name = name; self.version = version; self.iconPath = iconPath; self.policy = policy
    }
}

public struct StubOptions: Equatable {
    /// This Mac's name in the rules file.
    public var thisMac: String
    /// Path of the Desk client the stub hands over to.
    public var deskPath: String
    public init(thisMac: String, deskPath: String = "/usr/local/bin/desk") { self.thisMac = thisMac; self.deskPath = deskPath }
}

/// A file in the bundle. `text` files are written as given; `copy` files are copied from `source`.
public struct BundleFile: Equatable {
    public enum Content: Equatable { case text(String), copy(source: String) }
    public var path: String          // relative to the .app directory
    public var content: Content
    public var executable: Bool
}

public struct StubSpec: Equatable {
    public var hostedBundleId: String
    public var stubBundleId: String
    /// Directory name without the `.app` suffix.
    public var dirName: String
    public var digest: String
    public var files: [BundleFile]
}

public enum StubRejection: Error, Equatable {
    case badBundleId(String)
    case emptyName(String)
    case badDeskPath(String)
}

public enum StubFormat {
    /// Bump when the layout or plist keys change; it feeds the digest so old stubs are rewritten.
    public static let version = 1
    public static let hostedKey = "DeskHostedBundleId"
    public static let digestKey = "DeskStubDigest"
    public static let formatKey = "DeskStubFormat"
}

public enum StubGenerator {
    /// Letters, digits, dot, dash, underscore only. The id is placed in a shell script, so nothing else is accepted.
    public static func isSafeBundleId(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 155 else { return false }
        return s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 46 || $0 == 45 || $0 == 95 }
    }

    /// The stub's own identifier. Different from the real app's so macOS treats them as two apps.
    public static func stubBundleId(for hosted: String) -> String { "local.desk.stub." + hosted }

    /// A name safe as a directory: no slash, colon or control characters, no leading dot, at most 100 bytes.
    public static func sanitizeName(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch == "/" || ch == ":" || ch == "\\" || ch.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) { out.append(" ") }
            else { out.append(ch) }
        }
        out = trim(out)
        while out.hasPrefix(".") { out.removeFirst() }
        out = trim(out)
        while out.utf8.count > 100 { out.removeLast() }
        return trim(out)
    }

    /// Whether this Mac gets a stub: not for `local` apps, and not on the app's home Mac (plan 9.2, arrangement 2:
    /// there the real app is pinned in the Dock instead).
    public static func wantsStub(_ app: HostedApp, thisMac: String) -> Bool {
        switch app.policy {
        case .local: return false
        case .home(let mac): return mac != thisMac
        case .anywhere: return true
        }
    }

    public static func xmlEscape(_ s: String) -> String {
        var o = ""
        for c in s {
            switch c {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            default:
                // XML 1.0 forbids most control characters; drop them rather than write a broken plist.
                if let v = c.unicodeScalars.first?.value, v < 32, v != 9, v != 10, v != 13 { continue }
                o.append(c)
            }
        }
        return o
    }

    static func trim(_ s: String) -> String {
        var sub = Substring(s)
        while let f = sub.first, f == " " || f == "\t" || f == "\n" { sub = sub.dropFirst() }
        while let l = sub.last, l == " " || l == "\t" || l == "\n" { sub = sub.dropLast() }
        return String(sub)
    }

    /// 64-bit FNV-1a, hex. Not security: it only tells whether a stub needs rewriting.
    public static func digest(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// Executable name inside the bundle.
    static let executableName = "desk-stub"

    public static func infoPlist(_ app: HostedApp, dirName: String, iconFile: String?, digest: String) -> String {
        var entries: [(String, String)] = [
            ("CFBundleDevelopmentRegion", "en"),
            ("CFBundleExecutable", executableName),
            ("CFBundleIdentifier", stubBundleId(for: app.bundleId)),
            ("CFBundleInfoDictionaryVersion", "6.0"),
            ("CFBundleName", dirName),
            ("CFBundleDisplayName", dirName),
            ("CFBundlePackageType", "APPL"),
            ("CFBundleShortVersionString", app.version),
            ("CFBundleVersion", app.version),
            ("LSMinimumSystemVersion", "13.0"),
            (StubFormat.hostedKey, app.bundleId),
            (StubFormat.formatKey, String(StubFormat.version)),
            (StubFormat.digestKey, digest),
        ]
        if let icon = iconFile { entries.append(("CFBundleIconFile", icon)) }
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        s += "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        s += "<plist version=\"1.0\">\n<dict>\n"
        for (k, v) in entries { s += "\t<key>\(xmlEscape(k))</key>\n\t<string>\(xmlEscape(v))</string>\n" }
        s += "\t<key>NSHighResolutionCapable</key>\n\t<true/>\n</dict>\n</plist>\n"
        return s
    }

    /// A path that is safe inside the double-quoted launcher line: absolute, and no quote, dollar, backtick, backslash or control character.
    public static func isSafeDeskPath(_ p: String) -> Bool {
        guard p.hasPrefix("/"), p.utf8.count <= 1024 else { return false }
        return !p.unicodeScalars.contains { $0.value < 32 || $0.value == 127 || "\"$`\\!".unicodeScalars.contains($0) }
    }

    /// The program the Dock launches. It hands over to the Desk client, which owns the app's remote windows.
    /// Both inputs were validated by `make`.
    public static func launcherScript(hostedBundleId: String, deskPath: String) -> String {
        "#!/bin/sh\n# Generated by desk-stubgen. Edits are overwritten.\nexec \"${DESK_BIN:-" + deskPath + "}\" stub-run --bundle-id " + hostedBundleId + " \"$@\"\n"
    }

    public static func make(_ app: HostedApp, options: StubOptions, dirName: String? = nil) -> Result<StubSpec, StubRejection> {
        guard isSafeBundleId(app.bundleId) else { return .failure(.badBundleId(app.bundleId)) }
        guard isSafeDeskPath(options.deskPath) else { return .failure(.badDeskPath(options.deskPath)) }
        let name = dirName ?? sanitizeName(app.name)
        guard !name.isEmpty else { return .failure(.emptyName(app.bundleId)) }
        let iconFile = app.iconPath == nil ? nil : "AppIcon.icns"
        let script = launcherScript(hostedBundleId: app.bundleId, deskPath: options.deskPath)
        let digest = digest([String(StubFormat.version), app.bundleId, name, app.version, app.iconPath ?? "", options.deskPath].joined(separator: "\u{1F}"))
        var files = [
            BundleFile(path: "Contents/Info.plist", content: .text(infoPlist(app, dirName: name, iconFile: iconFile, digest: digest)), executable: false),
            BundleFile(path: "Contents/MacOS/" + executableName, content: .text(script), executable: true),
        ]
        if let icon = app.iconPath {
            files.append(BundleFile(path: "Contents/Resources/AppIcon.icns", content: .copy(source: icon), executable: false))
        }
        return .success(StubSpec(hostedBundleId: app.bundleId, stubBundleId: stubBundleId(for: app.bundleId), dirName: name, digest: digest, files: files))
    }
}
