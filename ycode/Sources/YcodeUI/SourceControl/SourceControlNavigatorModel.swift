import AppKit
import YcodeIDECore

/// What the Source Control navigator shows (`reference-ui-4.md` §2): the
/// Changes and Repositories trees, as outline items. Rows carry an
/// `scmKey` ("change:<path>", "branch:<name>", "remoteBranch:<name>",
/// "tag:<name>", "stash:<ref>", "repository") so selection can route.
public enum SourceControlNavigatorModel {
    public enum Mode: Int, Sendable { case changes, repositories }
    public static let modeTitles = ["Changes", "Repositories"]

    /// Header text: "<repository> <branch>" (the branch is secondary).
    public static func header(repository: String, branch: String?) -> (title: String, detail: String) {
        (repository, branch ?? "HEAD")
    }

    /// Changes: the repository header and "Uncommitted Changes" with its count.
    public static func changesTree(repository: String, branch: String?, changes: [GitRepository.Change], root: URL,
                                   integration: GitRepository.IntegrationState = .none) -> [OutlineItem] {
        let rows = changes.map { c -> OutlineItem in
            let name = URL(fileURLWithPath: c.path).deletingPathExtension().lastPathComponent
            let item = OutlineItem(title: name, symbol: symbol(for: c.path))
            item.badge = c.status.rawValue
            item.scmKey = "change:" + c.path
            return item
        }
        let group = OutlineItem(title: "Uncommitted Changes", symbol: "square.and.pencil", children: rows)
        group.detail = String(changes.count)
        let h = header(repository: repository, branch: branch)
        let top = OutlineItem(title: h.title, symbol: "externaldrive", children: [group])
        top.detail = h.detail + integrationSuffix(integration)
        top.scmKey = "repository"
        return [top]
    }

    /// " (Merging “feature”)" and the like while an operation is stopped.
    static func integrationSuffix(_ state: GitRepository.IntegrationState) -> String {
        switch state {
        case .none: ""
        case .merging(let b): " (Merging \u{201C}\(b)\u{201D})"
        case .rebasing(let b, let onto, let step, let total):
            " (Rebasing \u{201C}\(b)\u{201D} onto \(onto)" + (total > 0 ? ", \(step) of \(total))" : ")")
        case .cherryPicking(let c): " (Cherry-picking \(c.prefix(7)))"
        case .reverting(let c): " (Reverting \(c.prefix(7)))"
        }
    }

    /// Repositories: Branches, Recents, Tags, Stashes, Remotes. A name
    /// with `/` sits in a folder per prefix component.
    public static func repositoriesTree(repository: String, branch: String?, branches: [GitRepository.Ref], recents: [String],
                                        tags: [GitRepository.Ref], stashes: [String], remotes: [GitRepository.Remote],
                                        remoteBranches: [GitRepository.Ref]) -> [OutlineItem] {
        let branchRows = foldered(branches.map(\.name), current: branch, prefixKey: "branch:", symbol: "arrow.triangle.branch")
        let recentRows = recents.map { name -> OutlineItem in
            let i = OutlineItem(title: name, symbol: "clock.arrow.circlepath")
            i.scmKey = "branch:" + name
            return i
        }
        let tagRows = foldered(tags.map(\.name), current: nil, prefixKey: "tag:", symbol: "tag")
        let stashRows = stashes.map { s -> OutlineItem in
            let ref = s.components(separatedBy: ": ").first ?? s
            let i = OutlineItem(title: String(s.dropFirst(ref.count + 2)).isEmpty ? ref : String(s.dropFirst(ref.count + 2)), symbol: "tray")
            i.scmKey = "stash:" + ref
            return i
        }
        let remoteRows = remotes.map { r -> OutlineItem in
            let names = remoteBranches.filter { $0.name.hasPrefix(r.name + "/") }.map { String($0.name.dropFirst(r.name.count + 1)) }
            let kids = foldered(names, current: nil, prefixKey: "remoteBranch:\(r.name)/", symbol: "arrow.triangle.branch")
            let i = OutlineItem(title: r.name, symbol: "cloud", children: kids)
            i.detail = r.url
            i.scmKey = "remote:" + r.name
            return i
        }
        // navigators.md round 3 §2: each group its own grey filled symbol,
        // a disclosure triangle even when empty.
        let groups = [("Branches", branchRows), ("Recents", recentRows), ("Tags", tagRows), ("Stashes", stashRows), ("Remotes", remoteRows)]
            .map { g -> OutlineItem in
                let i = OutlineItem(title: g.0, symbol: groupSymbols[g.0] ?? "folder.fill", tint: groupTint, children: g.1)
                i.alwaysExpandable = true
                // Context menus only (New Branch…, New Tag…, Add Remote…).
                i.scmKey = "group:" + g.0
                return i
            }
        let h = header(repository: repository, branch: branch)
        let top = OutlineItem(title: h.title, symbol: repositorySymbol, tint: groupTint, children: groups)
        top.detail = h.detail
        top.scmKey = "repository"
        return [top]
    }

    /// The Repositories view's group symbols (navigators.md round 3 §2: a
    /// stacked drive, a clock in a filled circle, a tag in a filled square,
    /// a tray, a globe), all grey.
    static let groupSymbols = RepositoriesViewStyle.groupSymbols
    /// The repository row: a grey filled square.
    static let repositorySymbol = RepositoriesViewStyle.repositorySymbol
    static var groupTint: NSColor? { OutlineItem.color(.grey) }

    /// Which Repositories rows are expanded at first: the repository and
    /// Branches (with its folders); Recents, Tags, Stashes and Remotes stay
    /// collapsed.
    public static func expandsInitially(_ item: OutlineItem) -> Bool {
        guard let key = item.scmKey else { return !item.children.isEmpty }
        return key == "repository" || (key.hasPrefix("group:") && !RepositoriesViewStyle.initiallyCollapsed.contains(key))
    }

    /// Names split on `/` into folders ("feature/observe" → feature ▸ observe).
    static func foldered(_ names: [String], current: String?, prefixKey: String, symbol: String) -> [OutlineItem] {
        var leaves: [OutlineItem] = []
        var folders: [String: [String]] = [:]
        var order: [String] = []
        for n in names.sorted() {
            if let slash = n.firstIndex(of: "/") {
                let head = String(n[..<slash])
                if folders[head] == nil { order.append(head) }
                folders[head, default: []].append(String(n[n.index(after: slash)...]))
            } else {
                let i = OutlineItem(title: n, symbol: symbol)
                i.scmKey = prefixKey + n
                // No "(current)": the repository row names the current
                // branch (navigators.md round 3 §2).
                leaves.append(i)
            }
        }
        let folderItems = order.map { head -> OutlineItem in
            let sub = current.flatMap { $0.hasPrefix(head + "/") ? String($0.dropFirst(head.count + 1)) : nil }
            return OutlineItem(title: head, symbol: "folder", children: foldered(folders[head]!, current: sub, prefixKey: prefixKey + head + "/", symbol: symbol))
        }
        return folderItems + leaves
    }

    static func relative(_ path: String, root: URL) -> String {
        path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : path
    }

    static func symbol(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension {
        case "swift": "swift"
        case "xcodeproj", "xcworkspace": "hammer"
        case "plist", "json", "xcscheme": "doc.text"
        case "": "folder"
        default: "doc"
        }
    }
}
