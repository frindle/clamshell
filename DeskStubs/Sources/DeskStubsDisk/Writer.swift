import Foundation
import DeskStubs

public enum StubWriteError: Error, Equatable {
    case unsafePath(String)
    case iconUnreadable(String)
    /// The destination exists and is not a stub this tool wrote (no `DeskHostedBundleId`, or a different app's).
    case destinationNotOurs(String)
    case planHasRejections
    /// The Desk client path is missing, or it or a folder above it can be changed by someone other than its owner.
    case unsafeClient(String)
    /// `codesign` could not be started, or failed to sign or verify the staged bundle. Nothing visible was changed.
    case signFailed(String)
}

public enum StubWriter {
    public static let defaultCodesign = "/usr/bin/codesign"

    /// Builds `spec` in a hidden sibling directory of `root` and returns its path. Nothing visible changes.
    /// A spec with a signing identity is signed and verified here, before it can be seen, so a stub in place is
    /// always signed; a signing failure leaves nothing behind.
    static func stage(_ spec: StubSpec, in root: URL, codesign: String = defaultCodesign) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let tmp = root.appendingPathComponent(".\(spec.hostedBundleId).\(UUID().uuidString).tmp")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        do {
            for f in spec.files {
                guard !f.path.hasPrefix("/"), !f.path.split(separator: "/").contains("..") else { throw StubWriteError.unsafePath(f.path) }
                let dest = tmp.appendingPathComponent(f.path)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                switch f.content {
                case .text(let t): try t.write(to: dest, atomically: false, encoding: .utf8)
                case .copy(let src):
                    guard fm.isReadableFile(atPath: src) else { throw StubWriteError.iconUnreadable(src) }
                    try fm.copyItem(atPath: src, toPath: dest.path)
                }
                try fm.setAttributes([.posixPermissions: f.executable ? 0o755 : 0o644], ofItemAtPath: dest.path)
            }
            if let identity = spec.signIdentity { try sign(tmp, identity: identity, tool: codesign) }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        return tmp
    }

    /// Signs the bundle at `bundle`, then checks the signature strictly. No timestamp server is contacted.
    static func sign(_ bundle: URL, identity: String, tool: String) throws {
        guard StubGenerator.isSafeSignIdentity(identity) else { throw StubWriteError.signFailed("unsafe identity") }
        try run(tool, ["--force", "--sign", identity, "--timestamp=none", bundle.path])
        try run(tool, ["--verify", "--strict", bundle.path])
    }

    /// Runs `tool` with `args` (no shell) and turns a failure into `signFailed` with the start of its error output.
    static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { throw StubWriteError.signFailed("\(tool): \(error)") }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let text = String(decoding: data.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw StubWriteError.signFailed("\(args.first ?? tool) exited \(p.terminationStatus): \(text)")
        }
    }

    /// Puts a staged bundle at its final place. An existing stub of ours is swapped (see `swapDirectories`); anything else there is an error.
    static func install(_ tmp: URL, spec: StubSpec, into root: URL, replacing extra: Set<String> = []) throws {
        let fm = FileManager.default
        let final = root.appendingPathComponent(spec.dirName + ".app")
        if fm.fileExists(atPath: final.path) {
            // `extra`: directory names the plan removes anyway; a new stub may take such a name in one step.
            guard hostedId(of: final) == spec.hostedBundleId || (extra.contains(spec.dirName) && hostedId(of: final) != nil) else { throw StubWriteError.destinationNotOurs(spec.dirName) }
            try swapDirectories(new: tmp, over: final)
        } else {
            try fm.moveItem(at: tmp, to: final)
        }
    }

    /// Replaces the directory `final` with `new`. On macOS one atomic exchange (`renamex_np`), so there is no moment
    /// without a bundle. Elsewhere (Linux CI; Foundation's `replaceItemAt` fails on directories there) the old bundle is
    /// renamed aside, the new one moved in, and the old one put back if that fails.
    static func swapDirectories(new: URL, over final: URL) throws {
        let fm = FileManager.default
        #if canImport(Darwin)
        if renamex_np(new.path, final.path, UInt32(RENAME_SWAP)) == 0 {
            try? fm.removeItem(at: new) // `new` now holds the old bundle
            return
        }
        #endif
        let aside = final.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).old")
        try fm.moveItem(at: final, to: aside)
        do { try fm.moveItem(at: new, to: final) }
        catch { try? fm.moveItem(at: aside, to: final); throw error }
        try? fm.removeItem(at: aside)
    }

    /// Writes `spec` as `<root>/<dirName>.app`; a reader never sees a half-written stub.
    public static func write(_ spec: StubSpec, into root: URL, codesign: String = defaultCodesign) throws {
        let tmp = try stage(spec, in: root, codesign: codesign)
        do { try install(tmp, spec: spec, into: root) } catch { try? FileManager.default.removeItem(at: tmp); throw error }
    }

    public static func remove(dirName: String, from root: URL) throws {
        // Only ever a plain directory name inside root.
        guard !dirName.contains("/"), !dirName.hasPrefix(".") else { throw StubWriteError.unsafePath(dirName) }
        let target = root.appendingPathComponent(dirName + ".app")
        guard hostedId(of: target) != nil else { throw StubWriteError.destinationNotOurs(dirName) }
        try FileManager.default.removeItem(at: target)
    }

    /// The hosted bundle id of a bundle this tool wrote, nil otherwise.
    static func hostedId(of app: URL) -> String? {
        let text = (try? String(contentsOf: app.appendingPathComponent("Contents/Info.plist"), encoding: .utf8)) ?? ""
        return ownedHostedId(in: text)
    }

    /// "Ours" means more than one key being present: the hosted id, the format key, and a bundle identifier that is the
    /// stub identifier derived from that hosted id. Each value must directly follow its key as a `<string>`.
    static func ownedHostedId(in xml: String) -> String? {
        guard let hosted = value(StubFormat.hostedKey, in: xml), StubGenerator.isSafeBundleId(hosted),
              value(StubFormat.formatKey, in: xml) != nil,
              value("CFBundleIdentifier", in: xml) == StubGenerator.stubBundleId(for: hosted) else { return nil }
        return hosted
    }

    /// Reads the Desk keys out of every `*.app/Contents/Info.plist` under root. Anything that is not clearly ours is
    /// reported without a hosted id and so is never touched.
    public static func scan(root: URL) -> [ExistingStub] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var out: [ExistingStub] = []
        for n in names.sorted() where n.lowercased().hasSuffix(".app") {
            let plist = root.appendingPathComponent(n).appendingPathComponent("Contents/Info.plist")
            let text = (try? String(contentsOf: plist, encoding: .utf8)) ?? ""
            let owned = ownedHostedId(in: text)
            out.append(ExistingStub(dirName: String(n.dropLast(4)), hostedBundleId: owned, digest: owned == nil ? nil : value(StubFormat.digestKey, in: text)))
        }
        return out
    }

    /// The `<string>` that directly follows `<key>key</key>` (whitespace between is allowed, nothing else).
    static func value(_ key: String, in xml: String) -> String? {
        guard let k = xml.range(of: "<key>\(key)</key>") else { return nil }
        var rest = xml[k.upperBound...]
        while let f = rest.first, f == " " || f == "\t" || f == "\n" || f == "\r" { rest = rest.dropFirst() }
        guard rest.hasPrefix("<string>") else { return nil }
        rest = rest.dropFirst("<string>".count)
        guard let b = rest.range(of: "</string>") else { return nil }
        return String(rest[rest.startIndex..<b.lowerBound])
    }

    /// The Desk client must exist, and neither it nor any folder above it may be writable by group or others, nor owned
    /// by someone other than the current user or root. Symlinks are resolved first.
    public static func checkClient(_ path: String) throws {
        let fm = FileManager.default
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard fm.isExecutableFile(atPath: real) else { throw StubWriteError.unsafeClient(path + ": not an executable file") }
        var cur = real
        let me = NSNumber(value: getuid())
        while true {
            guard let a = try? fm.attributesOfItem(atPath: cur), let perm = (a[.posixPermissions] as? NSNumber)?.intValue,
                  let owner = a[.ownerAccountID] as? NSNumber else { throw StubWriteError.unsafeClient(cur + ": cannot read its permissions") }
            // A sticky folder (like /tmp) lets others add files but not rename or delete ours.
            let sticky = perm & 0o1000 != 0 && cur != real
            if perm & 0o022 != 0 && !sticky { throw StubWriteError.unsafeClient(cur + ": writable by group or others") }
            if owner != me && owner.intValue != 0 { throw StubWriteError.unsafeClient(cur + ": owned by another user") }
            let parent = (cur as NSString).deletingLastPathComponent
            if parent == cur || parent.isEmpty { break }
            cur = parent
        }
    }

    /// Applies a plan and returns the number of actions applied. Order: check everything, build (and sign) every new
    /// bundle in hidden directories, install them, and only then remove old ones. A failure before the install step changes
    /// nothing visible; during installs, nothing has been deleted yet.
    @discardableResult
    public static func apply(_ plan: StubPlan, into root: URL, codesign: String = defaultCodesign) throws -> Int {
        guard plan.rejected.isEmpty else { throw StubWriteError.planHasRejections }
        let fm = FileManager.default
        var removals: [String] = []
        var specs: [StubSpec] = []
        for a in plan.actions {
            switch a {
            case .remove(let d): removals.append(d)
            case .replace(let s, let old): specs.append(s); if let old = old { removals.append(old) }
            case .create(let s): specs.append(s)
            }
        }
        for d in removals {
            guard !d.contains("/"), !d.hasPrefix("."), hostedId(of: root.appendingPathComponent(d + ".app")) != nil else { throw StubWriteError.destinationNotOurs(d) }
        }
        var staged: [(StubSpec, URL)] = []
        do { for s in specs { staged.append((s, try stage(s, in: root, codesign: codesign))) } }
        catch { for (_, t) in staged { try? fm.removeItem(at: t) }; throw error }
        var installed = 0
        do {
            for (s, t) in staged { try install(t, spec: s, into: root, replacing: Set(removals)); installed += 1 }
        } catch {
            for (_, t) in staged[installed...] { try? fm.removeItem(at: t) }
            throw error
        }
        for d in removals where fm.fileExists(atPath: root.appendingPathComponent(d + ".app").path) && !specs.contains(where: { $0.dirName == d }) {
            try remove(dirName: d, from: root)
        }
        return plan.actions.count
    }
}
