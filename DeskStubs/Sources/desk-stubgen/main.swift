import Foundation
import DeskStubs
import DeskStubsDisk

// desk-stubgen --out DIR --mac NAME --desk PATH [--sign IDENTITY | --no-sign] [--dry-run] apps.json
//
// apps.json: [{"bundleId": "...", "name": "...", "version": "1.0", "icon": "/path/AppIcon.icns",
//              "mode": "local" | "anywhere" | "home", "home": "<mac>"}]
// Creates, replaces and removes stubs under DIR so it matches the file.
// Signing: on macOS every bundle is signed ad hoc ("-") by default before it is put in place; --sign takes a
// certificate name or hash instead, --no-sign leaves bundles unsigned. Elsewhere bundles are unsigned and --sign fails.

struct Entry: Decodable {
    var bundleId: String
    var name: String
    var version: String?
    var icon: String?
    var mode: String
    var home: String?
}

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(2) }

var out: String?, mac: String?, desk: String?, file: String?, dry = false
#if os(macOS)
var signIdentity: String? = "-"
#else
var signIdentity: String? = nil
#endif
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--out": out = it.next()
    case "--mac": mac = it.next()
    case "--desk": desk = it.next()
    case "--dry-run": dry = true
    case "--sign":
        guard let id = it.next() else { fail("--sign needs an identity (\"-\" for ad hoc)") }
        #if os(macOS)
        signIdentity = id
        #else
        _ = id
        fail("--sign needs macOS (codesign)")
        #endif
    case "--no-sign": signIdentity = nil
    default: file = a
    }
}
guard let out = out, let mac = mac, let desk = desk, let file = file else { fail("usage: desk-stubgen --out DIR --mac NAME --desk PATH [--sign IDENTITY | --no-sign] [--dry-run] apps.json") }
if let id = signIdentity, !StubGenerator.isSafeSignIdentity(id) { fail("unsafe signing identity: \(id)") }
do { try StubWriter.checkClient(desk) } catch { fail("unsafe client path: \(error)") }
guard let data = FileManager.default.contents(atPath: file), let entries = try? JSONDecoder().decode([Entry].self, from: data) else { fail("cannot read \(file)") }

var apps: [HostedApp] = []
for e in entries {
    let policy: StubPolicy
    switch e.mode {
    case "local": policy = .local
    case "anywhere": policy = .anywhere
    case "home":
        guard let h = e.home, !h.isEmpty else { fail("\(e.bundleId): mode home needs \"home\"") }
        policy = .home(h)
    default: fail("\(e.bundleId): unknown mode \(e.mode)")
    }
    var iconDigest: String?
    if let icon = e.icon {
        guard let d = FileManager.default.contents(atPath: icon) else { fail("\(e.bundleId): cannot read icon \(icon)") }
        iconDigest = StubGenerator.digest(bytes: Array(d))
    }
    apps.append(HostedApp(bundleId: e.bundleId, name: e.name, version: e.version ?? "1.0", iconPath: e.icon, iconDigest: iconDigest, policy: policy))
}
let root = URL(fileURLWithPath: out)
let plan = StubPlanner.plan(apps: apps, existing: StubWriter.scan(root: root), options: StubOptions(thisMac: mac, deskPath: desk, signIdentity: signIdentity))
for r in plan.rejected { FileHandle.standardError.write(Data("rejected: \(r)\n".utf8)) }
if !plan.rejected.isEmpty { fail("nothing changed: \(plan.rejected.count) entries rejected") }
for a in plan.actions { print(a) }
if !dry { do { print("applied \(try StubWriter.apply(plan, into: root))") } catch { fail("write failed: \(error)") } }
