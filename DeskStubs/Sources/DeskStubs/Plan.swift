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
    public var actions: [StubAction]
    public var rejected: [StubRejection]
}

public enum StubPlanner {
    /// Reconciles what should exist with what does.
    public static func plan(apps: [HostedApp], existing: [ExistingStub], options: StubOptions) -> StubPlan {
        var rejected: [StubRejection] = []
        var specs: [StubSpec] = []
        var usedNames: [String: String] = [:]    // lowercased dir name -> hosted id
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
            let have = ours.first { $0.hostedBundleId == spec.hostedBundleId }
            if let have = have {
                if have.digest != spec.digest || have.dirName != spec.dirName {
                    actions.append(.replace(spec, removing: have.dirName == spec.dirName ? nil : have.dirName))
                }
            } else {
                actions.append(.create(spec))
            }
        }
        for e in ours where !wanted.contains(e.hostedBundleId!) { actions.append(.remove(dirName: e.dirName)) }
        return StubPlan(actions: actions, rejected: rejected)
    }
}
