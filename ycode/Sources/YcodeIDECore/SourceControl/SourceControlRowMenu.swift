import Foundation

/// The Source Control navigator's context menus as data, by row key
/// ("branch:<name>", "remoteBranch:<remote>/<name>", "tag:<name>",
/// "stash:<ref>", "remote:<name>", "group:<Branches|Tags|Remotes>",
/// "repository", "change:<path>"). Ycode's design: the reference's menus
/// were not observed (`specs/ide/source-control.md`, "Ycode
/// implementation"). Both the macOS navigator and the Linux shell build
/// their menus from this.
public enum SourceControlRowMenu {
    public enum Action: Equatable, Sendable {
        case checkout(String)
        case newBranch(from: String?)
        case newTag(at: String?)
        case renameBranch(String)
        case deleteBranch(String)
        case merge(String)
        case rebaseOnto(String)
        case push(branch: String)
        case pull(branch: String)
        case deleteRemoteBranch(remote: String, branch: String)
        case pushTag(String)
        case deleteTag(String)
        case applyStash(String)
        case popStash(String)
        case dropStash(String)
        case fetch(remote: String)
        case addRemote
        case removeRemote(String)
        case resolveConflicts(path: String)
        case markResolved(path: String)
    }

    /// One item; nil `action` is a separator.
    public struct Item: Equatable, Sendable {
        public var title: String
        public var action: Action?
        public var isEnabled: Bool
        public static let separator = Item(title: "", action: nil, isEnabled: false)
        public init(title: String, action: Action?, isEnabled: Bool = true) {
            self.title = title
            self.action = action
            self.isEnabled = isEnabled
        }
    }

    /// What the menus depend on, from the window's snapshot.
    public struct Context: Equatable, Sendable {
        public var currentBranch: String?
        public var remotes: [String] = []
        public var integration: GitRepository.IntegrationState = .none
        public var conflicted: Set<String> = []
        public init(currentBranch: String? = nil, remotes: [String] = [], integration: GitRepository.IntegrationState = .none,
                    conflicted: Set<String> = []) {
            self.currentBranch = currentBranch
            self.remotes = remotes
            self.integration = integration
            self.conflicted = conflicted
        }

        public init(_ s: SourceControlSnapshot) {
            self.init(currentBranch: s.currentBranch, remotes: s.remotes.map(\.name), integration: s.integration,
                      conflicted: Set(s.changes.filter { $0.status == .conflicted }.map(\.path)))
        }
    }

    static func q(_ s: String) -> String { "\u{201C}\(s)\u{201D}" }

    public static func items(forKey key: String, in ctx: Context) -> [Item] {
        let current = ctx.currentBranch ?? "HEAD"
        let idle = !ctx.integration.isInProgress
        func integrate(_ ref: String) -> [Item] {
            [Item(title: "Merge \(q(ref)) into \(q(current))…", action: .merge(ref), isEnabled: idle),
             Item(title: "Rebase \(q(current)) onto \(q(ref))…", action: .rebaseOnto(ref), isEnabled: idle && ctx.currentBranch != nil)]
        }
        let creating = [Item(title: "New Branch…", action: .newBranch(from: nil)), Item(title: "New Tag…", action: .newTag(at: nil))]
        if key == "repository" { return creating + [.separator, Item(title: "Add Remote…", action: .addRemote)] }
        if key == "group:Branches" { return [creating[0]] }
        if key == "group:Tags" { return [creating[1]] }
        if key == "group:Remotes" { return [Item(title: "Add Remote…", action: .addRemote)] }
        if key.hasPrefix("branch:") {
            let b = String(key.dropFirst(7))
            let isCurrent = b == ctx.currentBranch
            var out: [Item] = []
            if !isCurrent { out += [Item(title: "Check Out \(q(b))…", action: .checkout(b), isEnabled: idle), .separator] }
            out += [Item(title: "New Branch from \(q(b))…", action: .newBranch(from: b)),
                    Item(title: "New Tag from \(q(b))…", action: .newTag(at: b))]
            if !isCurrent { out += [.separator] + integrate(b) }
            if !ctx.remotes.isEmpty {
                out += [.separator, Item(title: "Push \(q(b))…", action: .push(branch: b))]
                if isCurrent { out.append(Item(title: "Pull…", action: .pull(branch: b), isEnabled: idle)) }
            }
            out += [.separator, Item(title: "Rename…", action: .renameBranch(b)),
                    Item(title: "Delete…", action: .deleteBranch(b), isEnabled: !isCurrent)]
            return out
        }
        if key.hasPrefix("remoteBranch:") {
            let full = String(key.dropFirst(13))
            guard let slash = full.firstIndex(of: "/") else { return [] }
            let remote = String(full[..<slash]), b = String(full[full.index(after: slash)...])
            return [Item(title: "Check Out \(q(b))…", action: .checkout(full), isEnabled: idle), .separator,
                    Item(title: "New Branch from \(q(full))…", action: .newBranch(from: full)), .separator]
                + integrate(full)
                + [.separator, Item(title: "Delete \(q(b)) from \(q(remote))…", action: .deleteRemoteBranch(remote: remote, branch: b))]
        }
        if key.hasPrefix("tag:") {
            let t = String(key.dropFirst(4))
            var out = [Item(title: "New Branch from \(q(t))…", action: .newBranch(from: t))]
            if !ctx.remotes.isEmpty { out.append(Item(title: "Push \(q(t))…", action: .pushTag(t))) }
            return out + [.separator, Item(title: "Delete…", action: .deleteTag(t))]
        }
        if key.hasPrefix("stash:") {
            let ref = String(key.dropFirst(6))
            return [Item(title: "Apply Stashed Changes", action: .applyStash(ref), isEnabled: idle),
                    Item(title: "Apply and Delete Stash", action: .popStash(ref), isEnabled: idle), .separator,
                    Item(title: "Delete…", action: .dropStash(ref))]
        }
        if key.hasPrefix("remote:") {
            let r = String(key.dropFirst(7))
            return [Item(title: "Fetch \(q(r))", action: .fetch(remote: r)), .separator, Item(title: "Remove \(q(r))…", action: .removeRemote(r))]
        }
        if key.hasPrefix("change:") {
            let p = String(key.dropFirst(7))
            guard ctx.conflicted.contains(p) else { return [] }
            return [Item(title: "Resolve Conflicts…", action: .resolveConflicts(path: p)), Item(title: "Mark as Resolved", action: .markResolved(path: p))]
        }
        return []
    }
}
