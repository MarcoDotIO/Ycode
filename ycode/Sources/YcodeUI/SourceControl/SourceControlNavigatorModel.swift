import AppKit

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
    public static func changesTree(repository: String, branch: String?, changes: [GitRepository.Change], root: URL) -> [OutlineItem] {
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
        top.detail = h.detail
        top.scmKey = "repository"
        return [top]
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
            return i
        }
        let groups = [("Branches", branchRows), ("Recents", recentRows), ("Tags", tagRows), ("Stashes", stashRows), ("Remotes", remoteRows)]
            .map { OutlineItem(title: $0.0, symbol: "folder", children: $0.1) }
        let h = header(repository: repository, branch: branch)
        let top = OutlineItem(title: h.title, symbol: "externaldrive", children: groups)
        top.detail = h.detail
        top.scmKey = "repository"
        return [top]
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
                if n == current { i.detail = "(current)" }
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

/// Integrate menu (`reference-ui-4.md` §3): which items apply.
public struct IntegrateMenuState: Equatable, Sendable {
    public var hasRepository = false
    public var hasRemote = false
    public var hasUnstaged = false
    public var hasStaged = false
    /// Status of the file selected in a navigator, if it has one.
    public var selectedStatus: GitRepository.FileStatus?
    public var selectedIsStaged = false
    public var selectedFileExists = false
    public var selectedCommit: String?

    public init() {}

    public var hasChanges: Bool { hasUnstaged || hasStaged }

    /// Whether the item with this action applies.
    public func isEnabled(_ action: String) -> Bool {
        switch action {
        case "showCommitSheet:": hasRepository && hasChanges
        case "scmPush:", "scmPull:", "scmFetch:": hasRepository && hasRemote
        case "refreshFileStatus:": hasRepository
        case "scmStageAll:": hasRepository && hasUnstaged
        case "scmUnstageAll:": hasRepository && hasStaged
        case "scmStageSelected:": hasRepository && selectedStatus != nil && selectedStatus != .untracked
        case "scmUnstageSelected:": hasRepository && selectedIsStaged
        case "scmMarkResolved:": hasRepository && selectedStatus == .conflicted
        case "scmAddSelected:": hasRepository && selectedStatus == .untracked
        case "scmCherryPick:": hasRepository && selectedCommit != nil
        case "scmStash:", "scmDiscardAll:": hasRepository && hasChanges
        case "scmTrashSelected:": selectedFileExists
        case "scmClone:": true
        case "scmNewRepository:": !hasRepository
        default: true
        }
    }

    public static let actions = ["showCommitSheet:", "scmPush:", "scmPull:", "scmFetch:", "refreshFileStatus:", "scmStageAll:",
                                 "scmStageSelected:", "scmUnstageAll:", "scmUnstageSelected:", "scmMarkResolved:", "scmAddSelected:",
                                 "scmCherryPick:", "scmStash:", "scmDiscardAll:", "scmTrashSelected:", "scmClone:", "scmNewRepository:"]
}
