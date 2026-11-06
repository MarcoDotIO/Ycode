import Foundation

/// The Source Control navigator's context menus as data, by row key
/// ("branch:<name>", "remoteBranch:<remote>/<name>", "tag:<name>",
/// "stash:<ref>", "remote:<name>", "group:<Branches|Tags|Remotes>",
/// "repository", "change:<path>"). A local branch's menu is the
/// reference's (`specs/ide/merge-sheet.md` §1.1: 12 items in 6 groups);
/// the others are Ycode's design (`specs/ide/source-control.md`, "Ycode
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
        /// Merge the current branch into this one (needs it checked out).
        case mergeInto(String)
        /// Create a repository on a hosting account for this one.
        case newHostedRemote
        /// The branch on its remote's web page.
        case viewOnHost(branch: String)
        /// A stash's changes as a patch file.
        case exportStash(String)
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
        /// The repository's folder name ("New “name” Remote…").
        public var repositoryName = ""
        /// Stash references, newest first.
        public var stashes: [String] = []
        /// The remotes' URLs (View on Host).
        public var remoteURLs: [String] = []
        public init(currentBranch: String? = nil, remotes: [String] = [], integration: GitRepository.IntegrationState = .none,
                    conflicted: Set<String> = [], repositoryName: String = "", stashes: [String] = [], remoteURLs: [String] = []) {
            self.currentBranch = currentBranch
            self.remotes = remotes
            self.integration = integration
            self.conflicted = conflicted
            self.repositoryName = repositoryName
            self.stashes = stashes
            self.remoteURLs = remoteURLs
        }

        public init(_ s: SourceControlSnapshot) {
            self.init(currentBranch: s.currentBranch, remotes: s.remotes.map(\.name), integration: s.integration,
                      conflicted: Set(s.changes.filter { $0.status == .conflicted }.map(\.path)),
                      repositoryName: s.repository?.root.lastPathComponent ?? "",
                      stashes: s.stashes.map { String($0.prefix { $0 != ":" }) }, remoteURLs: s.remotes.map(\.url))
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
        if key.hasPrefix("branch:") { return branchItems(String(key.dropFirst(7)), ctx) }
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

    /// A local branch (`merge-sheet.md` §1.1): Switch, New Branch, Rename,
    /// Tag — the two merges — the two remote items — View on Host — the
    /// two stash items — Delete. On the current branch (Ycode's choice,
    /// open question 7) Switch and Delete are disabled, the merge group is
    /// left out, and Pull and Push join the remote group.
    static func branchItems(_ b: String, _ ctx: Context) -> [Item] {
        let current = ctx.currentBranch ?? "HEAD"
        let idle = !ctx.integration.isInProgress
        let isCurrent = b == ctx.currentBranch
        let stash = ctx.stashes.first
        var out = [Item(title: "Switch to \(q(b))…", action: .checkout(b), isEnabled: idle && !isCurrent),
                   Item(title: "New Branch from \(q(b))…", action: .newBranch(from: b)),
                   Item(title: "Rename \(q(b))…", action: .renameBranch(b)),
                   Item(title: "Tag \(q(b))…", action: .newTag(at: b)), .separator]
        if !isCurrent {
            out += [Item(title: "Merge \(q(b)) into \(q(current))…", action: .merge(b), isEnabled: idle && ctx.currentBranch != nil),
                    Item(title: "Merge \(q(current)) into \(q(b))…", action: .mergeInto(b), isEnabled: false), .separator]
        }
        out += [Item(title: "New \(q(ctx.repositoryName.isEmpty ? "Repository" : ctx.repositoryName)) Remote…", action: .newHostedRemote, isEnabled: false),
                Item(title: "Add Existing Remote…", action: .addRemote, isEnabled: false)]
        if isCurrent, !ctx.remotes.isEmpty {
            out += [Item(title: "Pull…", action: .pull(branch: b), isEnabled: idle), Item(title: "Push \(q(b))…", action: .push(branch: b))]
        }
        out += [.separator, Item(title: "View on Host…", action: .viewOnHost(branch: b), isEnabled: ctx.remoteURLs.contains { webURL(remote: $0) != nil }),
                .separator,
                Item(title: "Apply Stashed Changes…", action: .applyStash(stash ?? "stash@{0}"), isEnabled: stash != nil && idle),
                Item(title: "Export Stashed Changes as Patch File…", action: .exportStash(stash ?? "stash@{0}"), isEnabled: stash != nil),
                .separator, Item(title: "Delete…", action: .deleteBranch(b), isEnabled: !isCurrent)]
        return out
    }

    /// The web page of a remote's repository: an https URL as it is, an
    /// scp-style or ssh URL ("git@host:owner/repo.git") as https; nil for
    /// a local path. ".git" is dropped.
    public static func webURL(remote: String) -> String? {
        var s = remote.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix(".git") { s.removeLast(4) }
        if s.hasPrefix("https://") || s.hasPrefix("http://") {
            guard let u = URLComponents(string: s), let host = u.host, !host.isEmpty else { return nil }
            return "https://\(host)\(u.path)"
        }
        if s.hasPrefix("ssh://") {
            guard let u = URLComponents(string: s), let host = u.host, !host.isEmpty else { return nil }
            return "https://\(host)\(u.path)"
        }
        // user@host:path
        if let at = s.firstIndex(of: "@"), let colon = s[at...].firstIndex(of: ":"), !s.hasPrefix("/") {
            let host = s[s.index(after: at)..<colon], path = s[s.index(after: colon)...]
            guard !host.isEmpty, !path.isEmpty else { return nil }
            return "https://\(host)/\(path.hasPrefix("/") ? String(path.dropFirst()) : String(path))"
        }
        return nil
    }

    /// A branch's page on the first remote with a web address.
    public static func hostURL(branch: String, remoteURLs: [String]) -> URL? {
        guard let base = remoteURLs.lazy.compactMap(webURL(remote:)).first else { return nil }
        return URL(string: base + "/tree/" + (branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch))
    }
}
