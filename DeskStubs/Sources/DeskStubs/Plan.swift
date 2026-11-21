/// A stub already on disk, read from its Info.plist.
public struct ExistingStub: Equatable {
    public var dirName: String
    /// nil when the Info.plist has no `DeskHostedBundleId`: not ours, never touched.
    public var hostedBundleId: String?
    public var digest: String?
    public init(dirName: String, hostedBundleId: String?, digest: String?) {
        self.dirName = dirName; self.hostedBundleId = hostedBundleId; self.digest = digest
    }
}

public enum StubAction: Equatable {
    case create(StubSpec)
    /// Same hosted app, content changed or the directory name changed. The old directory (if named differently) is removed first.
    case replace(StubSpec, removing: String?)
    case remove(dirName: String)
}

public struct StubPlan: Equatable {
    /// Empty whenever `rejected` is not: one bad entry stops the whole run, so nothing is removed on the strength of a half-read list.
    public var actions: [StubAction]
    public var rejected: [StubRejection]
}

public enum StubPlanner {
    /// Owner marker for directories that are not stubs of ours; never equal to a bundle id.
    static let foreignOwner = "\u{0}foreign"

    /// Reconciles what should exist with what does.
    public static func plan(apps: [HostedApp], existing: [ExistingStub], options: StubOptions) -> StubPlan {
        var rejected: [StubRejection] = []
        var specs: [StubSpec] = []
        // lowercased dir name -> owner. Anything already on disk keeps its name: a directory that is not ours is never
        // overwritten (the new stub gets a suffixed name), and the stub of an app that stays keeps its place.
        var usedNames: [String: String] = [:]
        let wantedIds = Set(apps.filter { StubGenerator.wantsStub($0, thisMac: options.thisMac) }.map { $0.bundleId })
        for e in existing {
            if let h = e.hostedBundleId {
                if wantedIds.contains(h) { usedNames[e.dirName.lowercased()] = h }
            } else {
                usedNames[e.dirName.lowercased()] = foreignOwner
            }
        }
        // Deterministic: sorted by bundle id, so a name clash always resolves the same way.
        for app in apps.sorted(by: { $0.bundleId < $1.bundleId }) where StubGenerator.wantsStub(app, thisMac: options.thisMac) {
            // A name clash with a different app gets a numeric suffix. The macOS filesystem is case-insensitive by default.
            let base = StubGenerator.sanitizeName(app.name)
            var name = base, n = 2
            while !name.isEmpty, let owner = usedNames[name.lowercased()], owner != app.bundleId { name = base + " " + String(n); n += 1 }
            switch StubGenerator.make(app, options: options, dirName: name) {
            case .failure(let r): rejected.append(r)
            case .success(let spec): specs.append(spec); usedNames[name.lowercased()] = app.bundleId
            }
        }
        let ours = existing.filter { $0.hostedBundleId != nil }
        var actions: [StubAction] = []
        let wanted = Set(specs.map { $0.hostedBundleId })
        for spec in specs {
            let copies = ours.filter { $0.hostedBundleId == spec.hostedBundleId }.sorted { $0.dirName < $1.dirName }
            let have = copies.first { $0.dirName == spec.dirName } ?? copies.first
            if let have = have {
                if have.digest != spec.digest || have.dirName != spec.dirName {
                    actions.append(.replace(spec, removing: have.dirName == spec.dirName ? nil : have.dirName))
                }
            } else {
                actions.append(.create(spec))
            }
        }
        for e in ours where !wanted.contains(e.hostedBundleId!) { actions.append(.remove(dirName: e.dirName)) }
        // The same hosted app on disk under more than one name: keep the one the plan wants (or the first by name) and
        // remove the rest, so nothing stays behind that nothing manages.
        for spec in specs {
            let copies = ours.filter { $0.hostedBundleId == spec.hostedBundleId }.sorted { $0.dirName < $1.dirName }
            guard copies.count > 1 else { continue }
            let keep = copies.first { $0.dirName == spec.dirName } ?? copies[0]
            for c in copies where c.dirName != keep.dirName && !actions.contains(.replace(spec, removing: c.dirName)) {
                actions.append(.remove(dirName: c.dirName))
            }
        }
        if !rejected.isEmpty { return StubPlan(actions: [], rejected: rejected) }
        return StubPlan(actions: actions, rejected: rejected)
    }
}
