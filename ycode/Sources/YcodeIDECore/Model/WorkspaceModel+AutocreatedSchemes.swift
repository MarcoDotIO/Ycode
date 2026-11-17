import Foundation
import YcodeProject
import YcodeWorkspace

// Autocreated schemes in the scheme editor and Manage Schemes (parity
// inventory P-108; `specs/ide/schemes.md` §Autocreated schemes). A project
// without scheme files shows one scheme per target; those schemes have no
// file until one of them is changed, so the editor and Manage Schemes get
// them from here, each with the user-scheme URL it would be written to.

extension WorkspaceModel {
    /// The scheme the editor opens for `name`: its file, else the scheme
    /// autocreated for the target of that name.
    public func schemeForEditing(named name: String?) -> Scheme? {
        guard let name else { return nil }
        if let s = loadSchemes().first(where: { $0.name == name }) { return s }
        return autocreatedSchemes().first { $0.name == name }
    }

    /// The schemes Manage Schemes lists: the files, then the autocreated
    /// schemes of containers that have none, by name.
    public func schemesForManaging() -> [Scheme] {
        (loadSchemes() + autocreatedSchemes()).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// One scheme per target of each project that has no scheme files
    /// (as `schemeNames` lists them), not yet on disk: each has the URL of
    /// the current user's scheme file it would be saved to.
    public func autocreatedSchemes(user: String = NSUserName()) -> [Scheme] {
        var out: [Scheme] = []
        for container in schemeContainers where Scheme.discover(in: container, user: user).isEmpty {
            guard let proj = projects[container.path] else { continue }
            for t in proj.targets {
                guard var s = Self.autocreatedScheme(for: t, in: proj, containerName: container.lastPathComponent) else { continue }
                s.url = Scheme.fileURL(container: container, name: s.name, shared: false, user: user)
                out.append(s)
            }
        }
        return out
    }

    /// Writes the autocreated schemes of `scheme`'s container that have no
    /// file yet, once one of them is saved (the others would otherwise stop
    /// being listed, since the container now has a scheme file).
    public func writeAutocreatedSiblings(of scheme: Scheme, user: String = NSUserName()) {
        guard let url = scheme.url else { return }
        for s in autocreatedSchemes(user: user) where s.name != scheme.name
            && s.url?.deletingLastPathComponent() == url.deletingLastPathComponent() {
            _ = try? s.save()
        }
    }

    static func isTestBundle(_ t: PBXObject) -> Bool {
        ["com.apple.product-type.bundle.unit-test", "com.apple.product-type.bundle.ui-testing"].contains(t.string("productType") ?? "")
    }

    static func buildable(_ t: PBXObject, _ proj: PBXProj, _ containerName: String) -> Scheme.BuildableReference {
        let name = t.string("name") ?? ""
        let product = t.string("productReference").flatMap { proj[$0]?.string("path") } ?? name
        return Scheme.BuildableReference(blueprintIdentifier: t.id, buildableName: product, blueprintName: name,
                                         referencedContainer: "container:\(containerName)")
    }

    /// The scheme autocreated for a target (`info-commands.md` §2.1): it
    /// builds the target, tests itself (a test bundle) or the test bundles
    /// it hosts, runs an application or tool, and asks for an automatic
    /// test plan.
    static func autocreatedScheme(for t: PBXObject, in proj: PBXProj, containerName: String) -> Scheme? {
        guard let name = t.string("name"), !name.isEmpty else { return nil }
        let type = t.string("productType") ?? ""
        let hosted = proj.targets.filter { other in
            isTestBundle(other) && proj.project?["attributes"]?.dictionary?["TargetAttributes"]?.dictionary?[other.id]?.dictionary?["TestTargetID"]?.string == t.id
        }
        var s = Scheme.autocreated(for: buildable(t, proj, containerName), isTestBundle: isTestBundle(t),
                                   isRunnable: type.hasSuffix(".application") || type.hasSuffix(".tool"),
                                   hostedTests: hosted.map { buildable($0, proj, containerName) }, autocreateTestPlan: true)
        s.name = name
        return s
    }
}
