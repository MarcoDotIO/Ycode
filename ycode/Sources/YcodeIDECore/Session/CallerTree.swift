import Foundation
import YcodeLanguage

/// Find ▸ Find Call Hierarchy's result (`refactoring.md` §Find,
/// `navigators.md` §Call Hierarchy): the function at the caret, its
/// callers, and their callers: `callHierarchy/incomingCalls` two levels
/// deep, a function already on the path not followed again. Both IDEs show
/// it as a tree under "Callers of <name>".
public struct CallerTree: Equatable, Sendable {
    /// Levels of callers below the function (the spec's two).
    public static let depth = 2

    public var name: String
    /// The declaration's file and 1-based line.
    public var path: String
    public var line: Int
    /// Where this function calls its parent (0-based positions in `path`;
    /// none for the root).
    public var sites: [Position]
    public var callers: [CallerTree]

    public init(name: String, path: String, line: Int, sites: [Position] = [], callers: [CallerTree] = []) {
        self.name = name
        self.path = path
        self.line = line
        self.sites = sites
        self.callers = callers
    }

    /// Callers at every level.
    public var callerCount: Int { callers.reduce(callers.count) { $0 + $1.callerCount } }

    /// Builds the tree from `item`: `incoming` gives an item's callers and
    /// the ranges of their calls.
    public static func build(_ item: CallHierarchyItem, depth: Int = depth,
                             incoming: @Sendable (CallHierarchyItem) async -> [(caller: CallHierarchyItem, ranges: [Position])]) async -> CallerTree {
        await node(item, sites: [], level: 0, depth: depth, path: [], incoming: incoming)
    }

    private static func key(_ i: CallHierarchyItem) -> String { "\(i.url.standardizedFileURL.path):\(i.selection.line):\(i.name)" }

    private static func node(_ i: CallHierarchyItem, sites: [Position], level: Int, depth: Int, path: Set<String>,
                             incoming: @Sendable (CallHierarchyItem) async -> [(caller: CallHierarchyItem, ranges: [Position])]) async -> CallerTree {
        var t = CallerTree(name: i.name, path: i.url.standardizedFileURL.path, line: i.selection.line + 1, sites: sites)
        let k = key(i)
        guard level < depth, !path.contains(k) else { return t }
        for (caller, ranges) in await incoming(i) {
            t.callers.append(await node(caller, sites: ranges.isEmpty ? [caller.selection] : ranges, level: level + 1, depth: depth,
                                        path: path.union([k]), incoming: incoming))
        }
        return t
    }
}

extension WorkspaceSession {
    /// Find ▸ Find Call Hierarchy: the tree for the symbol at `p`; nil when
    /// it is not callable or there is no server.
    public func callerTree(_ url: URL, at p: Position, depth: Int = CallerTree.depth) async -> CallerTree? {
        guard let language, let item = (try? await language.client.prepareCallHierarchy(url, at: p))?.first else { return nil }
        let client = language.client
        return await CallerTree.build(item, depth: depth) { i in (try? await client.incomingCalls(i)) ?? [] }
    }
}
