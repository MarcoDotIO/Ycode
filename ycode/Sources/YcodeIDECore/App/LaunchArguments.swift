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
