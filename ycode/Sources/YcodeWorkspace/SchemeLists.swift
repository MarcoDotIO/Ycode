import Foundation

/// The scheme editor's Build targets and Test plans tables: adding and
/// removing entries (reference-ui-5.md §11.3, P11). Elements and attributes
/// follow `specs/formats/xcode-xml.md` §Scheme; untouched parts of the
/// document keep their layout.
extension Scheme {
    /// `buildFor<Action>` attributes in the order a `BuildActionEntry`
    /// carries them.
    static let buildForOrder: [Action] = [.testing, .running, .profiling, .archiving, .analyzing]

    /// Appends a `BuildActionEntry` for a target (creating
    /// `BuildActionEntries` when missing). A target already listed is left
    /// as it is.
    public mutating func addBuildEntry(_ ref: BuildableReference, actions: Set<Action>) {
        guard !buildEntries.contains(where: { $0.reference.blueprintIdentifier == ref.blueprintIdentifier }) else { return }
        editAction("BuildAction") { b in
            if b["parallelizeBuildables"] == nil, b.children.isEmpty { b["parallelizeBuildables"] = "YES"; b["buildImplicitDependencies"] = "YES" }
            let entry = XMLNode("BuildActionEntry", attributes: Self.buildForOrder.map { ("buildFor\($0.rawValue)", actions.contains($0) ? "YES" : "NO") },
                                children: [ref.node])
            if let i = b.children.firstIndex(where: { $0.name == "BuildActionEntries" }) {
                b.children[i].children.append(entry)
            } else {
                b.children.insert(XMLNode("BuildActionEntries", children: [entry]), at: 0)
            }
        }
    }

    /// Removes a target's `BuildActionEntry`; the empty container goes too.
    public mutating func removeBuildEntry(blueprintIdentifier: String) {
        editAction("BuildAction") { b in
            guard let i = b.children.firstIndex(where: { $0.name == "BuildActionEntries" }) else { return }
            b.children[i].children.removeAll { $0.name == "BuildActionEntry" && $0.child("BuildableReference")?["BlueprintIdentifier"] == blueprintIdentifier }
            if b.children[i].children.isEmpty { b.children.remove(at: i) }
        }
    }

    /// Adds a `TestPlanReference` (a `container:` path); the first plan
    /// becomes the default.
    public mutating func addTestPlan(reference: String) {
        guard !testPlans.contains(where: { $0.reference == reference }) else { return }
        let first = testPlans.isEmpty
        editAction("TestAction") { t in
            var attrs = [("reference", reference)]
            if first { attrs.append(("default", "YES")) }
            let node = XMLNode("TestPlanReference", attributes: attrs)
            if let i = t.children.firstIndex(where: { $0.name == "TestPlans" }) {
                t.children[i].children.append(node)
            } else {
                // After Testables when present, else first.
                let at = t.children.firstIndex { $0.name == "Testables" }.map { $0 + 1 } ?? 0
                t.children.insert(XMLNode("TestPlans", children: [node]), at: at)
            }
        }
    }

    /// Removes a test plan; when it was the default, the first remaining
    /// one becomes the default. The empty container goes too.
    public mutating func removeTestPlan(reference: String) {
        editAction("TestAction") { t in
            guard let i = t.children.firstIndex(where: { $0.name == "TestPlans" }) else { return }
            let wasDefault = t.children[i].children.contains { $0["reference"] == reference && $0["default"] == "YES" }
            t.children[i].children.removeAll { $0.name == "TestPlanReference" && $0["reference"] == reference }
            if t.children[i].children.isEmpty { t.children.remove(at: i); return }
            if wasDefault, let j = t.children[i].children.firstIndex(where: { $0.name == "TestPlanReference" }) {
                t.children[i].children[j]["default"] = "YES"
            }
        }
    }

    /// Makes one test plan the default.
    public mutating func setDefaultTestPlan(reference: String) {
        editAction("TestAction") { t in
            guard let i = t.children.firstIndex(where: { $0.name == "TestPlans" }) else { return }
            for j in t.children[i].children.indices where t.children[i].children[j].name == "TestPlanReference" {
                t.children[i].children[j]["default"] = t.children[i].children[j]["reference"] == reference ? "YES" : nil
            }
        }
    }
}
