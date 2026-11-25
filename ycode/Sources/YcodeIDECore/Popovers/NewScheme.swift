import Foundation
import YcodeProject
import YcodeWorkspace

/// The New Scheme sheet's model (`specs/ide/popovers.md` §3, P-112),
/// shared by both IDEs: the Target pop-up lists the workspace's targets
/// (each with its project), the Name field starts as the target's name,
/// OK writes a scheme for the target as `schemes.md` (Writing) describes.
public struct NewSchemeModel: Equatable, Sendable {
    public struct Target: Equatable, Sendable {
        public var name: String
        /// The project the target is in (its container for the scheme file).
        public var container: URL
        public var productType: String
    }

    public var targets: [Target]
    public var selected: Int
    public var name: String

    public static let title = "New Scheme"
    public static let targetLabel = "Target"
    public static let nameLabel = "Name"

    /// The workspace's targets, the first one chosen (or the active
    /// scheme's target when it has one of that name).
    public init(model: WorkspaceModel, preferring scheme: String? = nil) {
        var list: [Target] = []
        for path in model.projects.keys.sorted() {
            guard let proj = model.projects[path] else { continue }
            for t in proj.targets {
                guard let n = t.string("name"), !n.isEmpty else { continue }
                list.append(Target(name: n, container: URL(fileURLWithPath: path), productType: t.string("productType") ?? ""))
            }
        }
        targets = list
        selected = list.firstIndex { $0.name == scheme } ?? 0
        name = list.indices.contains(selected) ? list[selected].name : ""
    }

    /// Choosing another target renames the scheme after it while the name
    /// still is the previous target's.
    public mutating func select(_ i: Int) {
        guard targets.indices.contains(i) else { return }
        if targets.indices.contains(selected), name == targets[selected].name { name = targets[i].name }
        selected = i
    }

    /// OK is enabled with a target and a name that is not blank.
    public var canCreate: Bool { targets.indices.contains(selected) && !name.trimmingCharacters(in: .whitespaces).isEmpty }

    public enum Failure: Error, Equatable {
        case noTarget, emptyName, exists(String)
    }

    /// Writes the scheme: shared (`xcshareddata/xcschemes`) in the
    /// target's project, built as the scheme Ycode autocreates for that
    /// target. The project's autocreated schemes are written first, so
    /// they stay listed once it has a scheme file. Returns the scheme.
    @discardableResult
    public func create(in model: WorkspaceModel, user: String = NSUserName()) throws -> Scheme {
        guard targets.indices.contains(selected) else { throw Failure.noTarget }
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { throw Failure.emptyName }
        guard !model.schemeNames.contains(n) && !model.loadSchemes().contains(where: { $0.name == n }) else { throw Failure.exists(n) }
        let t = targets[selected]
        guard let proj = model.projects[t.container.path],
              let obj = proj.targets.first(where: { $0.string("name") == t.name }),
              var scheme = WorkspaceModel.autocreatedScheme(for: obj, in: proj, containerName: t.container.lastPathComponent) else {
            throw Failure.noTarget
        }
        let siblings = model.autocreatedSchemes(user: user).filter { $0.url?.path.hasPrefix(t.container.path + "/") == true }
        for s in siblings { _ = try? s.save() }
        scheme.name = n
        scheme.isShared = true
        scheme.url = Scheme.fileURL(container: t.container, name: n, shared: true, user: user)
        try scheme.save()
        return scheme
    }
}
