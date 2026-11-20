import Foundation
import DeskStubs

public enum StubWriteError: Error, Equatable {
    case unsafePath(String)
    case iconUnreadable(String)
}

public enum StubWriter {
    /// Writes `spec` as `<root>/<dirName>.app`. The bundle is built in a hidden sibling directory and renamed into
    /// place, so a reader never sees a half-written stub.
    public static func write(_ spec: StubSpec, into root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let final = root.appendingPathComponent(spec.dirName + ".app")
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
            if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
            try fm.moveItem(at: tmp, to: final)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    public static func remove(dirName: String, from root: URL) throws {
        // Only ever a plain directory name inside root.
        guard !dirName.contains("/"), !dirName.hasPrefix(".") else { throw StubWriteError.unsafePath(dirName) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(dirName + ".app"))
    }

    /// Reads the Desk keys out of every `*.app/Contents/Info.plist` under root. Plain text scan of the XML plist
    /// this generator writes; anything it cannot read is reported without the hosted id and so is never touched.
    public static func scan(root: URL) -> [ExistingStub] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var out: [ExistingStub] = []
        for n in names.sorted() where n.hasSuffix(".app") {
            let plist = root.appendingPathComponent(n).appendingPathComponent("Contents/Info.plist")
            let text = (try? String(contentsOf: plist, encoding: .utf8)) ?? ""
            out.append(ExistingStub(dirName: String(n.dropLast(4)), hostedBundleId: value(StubFormat.hostedKey, in: text), digest: value(StubFormat.digestKey, in: text)))
        }
        return out
    }

    static func value(_ key: String, in xml: String) -> String? {
        guard let k = xml.range(of: "<key>\(key)</key>") else { return nil }
        let rest = xml[k.upperBound...]
        guard let a = rest.range(of: "<string>"), let b = rest.range(of: "</string>"), a.upperBound <= b.lowerBound else { return nil }
        return String(rest[a.upperBound..<b.lowerBound])
    }

    /// Applies a plan. Returns the number of actions applied.
    @discardableResult
    public static func apply(_ plan: StubPlan, into root: URL) throws -> Int {
        var n = 0
        for a in plan.actions {
            switch a {
            case .create(let s): try write(s, into: root)
            case .replace(let s, let old):
                try write(s, into: root)
                if let old = old { try? remove(dirName: old, from: root) }
            case .remove(let d): try remove(dirName: d, from: root)
            }
            n += 1
        }
        return n
    }
}
