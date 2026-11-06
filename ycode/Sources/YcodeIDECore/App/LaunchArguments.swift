import Foundation
import YcodeLanguage

/// What launching does (`reference-ui-5.md` §3.1, L1).
public enum LaunchAction: Equatable {
    /// Open these paths.
    case open([String])
    /// No document to open: the Welcome window, never an Open panel.
    case welcome
    /// Documents are already open (state restoration): nothing more.
    case none

    public static func decide(arguments: [String], openDocumentCount: Int) -> LaunchAction {
        let paths = LaunchArguments.documentPaths(arguments)
        if !paths.isEmpty { return .open(paths) }
        return openDocumentCount == 0 ? .welcome : .none
    }
}
/// Whether launching shows the Welcome window (`reference-ui-6.md`
/// §1.2.1, W2): only when, after launch, state restoration and the opens
/// requested while launching, no document is open. The decision is made
/// once; later opens never bring the Welcome window up.
public struct WelcomeLaunchGate: Equatable, Sendable {
    /// Opens requested and not finished.
    public private(set) var pending = 0
    /// The launch check ran (after restoration).
    public private(set) var launchChecked = false
    /// The Welcome decision was made.
    public private(set) var decided = false

    public init() {}

    public mutating func openRequested() { pending += 1 }

    /// An open finished (or failed). True: show the Welcome window now
    /// (the launch check was waiting for it and nothing is open).
    public mutating func openFinished(openDocuments: Int) -> Bool {
        pending = max(0, pending - 1)
        return decide(openDocuments: openDocuments)
    }

    /// After launch and restoration. True: show the Welcome window now.
    public mutating func launchCheck(openDocuments: Int) -> Bool {
        launchChecked = true
        return decide(openDocuments: openDocuments)
    }

    private mutating func decide(openDocuments: Int) -> Bool {
        guard launchChecked, !decided, pending == 0 else { return false }
        decided = true
        return openDocuments == 0
    }
}
/// Launch arguments: document paths and NSArgumentDomain pairs.
public enum LaunchArguments {
    /// The paths to open. A `-Key value` pair (NSArgumentDomain style,
    /// e.g. `-ApplePersistenceIgnoreState YES`) is skipped as a whole;
    /// `--` ends option parsing.
    public static func documentPaths(_ args: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--" { out += args[(i + 1)...]; break }
            if a.hasPrefix("-") && a.count > 1 {
                // The value, when one follows (not another flag).
                if i + 1 < args.count, !args[i + 1].hasPrefix("-") { i += 1 }
            } else {
                out.append(a)
            }
            i += 1
        }
        return out
    }
}

/// Open requests (Finder, `open`, state restoration) for one file are
/// the same request when their paths name the same file.
public enum OpenRequestKey {
    /// The path with `.`/`..` and symbolic links resolved.
    public static func path(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

extension NavigatorNode {
    /// Whether an open-document request for `file` belongs to this
    /// workspace (`specs/ide/editor-area.md` §C.6, #71): a file row of the
    /// tree, or a file inside one of its folders (a synchronized folder
    /// lists what is on disk, so a file added since still belongs), or
    /// inside a package's folder.
    public func containsForOpening(_ file: URL) -> Bool {
        let target = OpenRequestKey.path(file)
        func resolved(_ p: String) -> String { OpenRequestKey.path(URL(fileURLWithPath: p)) }
        func walk(_ n: NavigatorNode) -> Bool {
            if let p = n.path {
                switch n.kind {
                case .file: if resolved(p) == target { return true }
                case .folder: if target.hasPrefix(resolved(p) + "/") { return true }
                case .container: if NavigatorTree.isPackageRoot(n), target.hasPrefix(resolved(p) + "/") { return true }
                case .group: break
                }
            }
            return n.children.contains(where: walk)
        }
        return walk(self)
    }

    /// The workspace's own path for a file named by an open-document
    /// request (`editor-area.md` E.4, checklist row 73): the request may
    /// name it through a symbolic link resolved (`/private/tmp/…` for the
    /// project's `/tmp/…`); the project keeps its own spelling, so the
    /// inspector's Full Path and the jump bar's groups stay. nil when the
    /// workspace does not hold the file.
    public func projectPath(forOpening file: URL) -> String? {
        let target = OpenRequestKey.path(file)
        func resolved(_ p: String) -> String { OpenRequestKey.path(URL(fileURLWithPath: p)) }
        var inFolder: String?
        func walk(_ n: NavigatorNode) -> String? {
            if let p = n.path {
                switch n.kind {
                case .file: if resolved(p) == target { return p }
                case .folder, .container:
                    let r = resolved(p)
                    if inFolder == nil, n.kind == .folder || NavigatorTree.isPackageRoot(n), target.hasPrefix(r + "/") {
                        inFolder = (p as NSString).appendingPathComponent(String(target.dropFirst(r.count + 1)))
                    }
                case .group: break
                }
            }
            for c in n.children { if let hit = walk(c) { return hit } }
            return nil
        }
        // A file row wins over a folder that holds it.
        return walk(self) ?? inFolder
    }
}
