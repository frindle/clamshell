import Foundation
import DeskStubs
import DeskStubsDisk

// desk-stubgen --out DIR --mac NAME [--desk PATH] [--dry-run] apps.json
//
// apps.json: [{"bundleId": "...", "name": "...", "version": "1.0", "icon": "/path/AppIcon.icns",
//              "mode": "local" | "anywhere" | "home", "home": "<mac>"}]
// Creates, replaces and removes stubs under DIR so it matches the file. Bundles are not signed here.

struct Entry: Decodable {
    var bundleId: String
    var name: String
    var version: String?
    var icon: String?
    var mode: String
    var home: String?
}

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(2) }

var out: String?, mac: String?, desk = "/usr/local/bin/desk", file: String?, dry = false
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--out": out = it.next()
    case "--mac": mac = it.next()
    case "--desk": desk = it.next() ?? desk
    case "--dry-run": dry = true
    default: file = a
    }
}
guard let out = out, let mac = mac, let file = file else { fail("usage: desk-stubgen --out DIR --mac NAME [--desk PATH] [--dry-run] apps.json") }
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
    apps.append(HostedApp(bundleId: e.bundleId, name: e.name, version: e.version ?? "1.0", iconPath: e.icon, policy: policy))
}
let root = URL(fileURLWithPath: out)
let plan = StubPlanner.plan(apps: apps, existing: StubWriter.scan(root: root), options: StubOptions(thisMac: mac, deskPath: desk))
for r in plan.rejected { FileHandle.standardError.write(Data("rejected: \(r)\n".utf8)) }
for a in plan.actions { print(a) }
if !dry { do { print("applied \(try StubWriter.apply(plan, into: root))") } catch { fail("write failed: \(error)") } }
