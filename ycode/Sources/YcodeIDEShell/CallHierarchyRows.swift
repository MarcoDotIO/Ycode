import Foundation
import Observation
import YcodeIDECore

/// One row of the call hierarchy in the Linux Find navigator: a function,
/// indented by its level (0: the function at the caret, 1: its callers, 2:
/// their callers), with its file and line as detail.
public struct CallHierarchyRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var level: Int
    public var name: String
    /// "main.swift:3", and how many calls it makes to its parent when more
    /// than one.
    public var detail: String
    public var path: String
    public var line: Int
    public var isExpandable: Bool
    public var isExpanded: Bool
}

/// Find ▸ Find Call Hierarchy in the Linux Find navigator
/// (`refactoring.md` §Find): `CallerTree` two levels deep, as a tree under
/// "Callers of <name>". A row opens the function's declaration, as the
/// macOS IDE's tree does.
@MainActor
@Observable
public final class CallHierarchyModel {
    /// The tree shown (nil: the navigator shows search results).
    public private(set) var tree: CallerTree?
    public var collapsed: Set<String> = []
    public var selection: String? {
        didSet { if selection != oldValue, let id = selection, let r = rows.first(where: { $0.id == id }) { onOpen?(r.path, r.line) } }
    }
    @ObservationIgnored var onOpen: ((String, Int) -> Void)?

    public init() {}

    func show(_ t: CallerTree?) {
        tree = t
        collapsed = []
        selection = nil
    }

    public func setExpanded(_ id: String, _ on: Bool) {
        if on { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    /// The visible rows, depth first.
    public var rows: [CallHierarchyRow] { tree.map { Self.rows($0, collapsed: collapsed) } ?? [] }

    public static func rows(_ root: CallerTree, collapsed: Set<String>) -> [CallHierarchyRow] {
        var out: [CallHierarchyRow] = []
        func walk(_ t: CallerTree, _ id: String, _ level: Int) {
            let open = !collapsed.contains(id)
            var detail = "\((t.path as NSString).lastPathComponent):\(t.line)"
            if t.sites.count > 1 { detail += "  (\(t.sites.count) calls)" }
            out.append(CallHierarchyRow(id: id, level: level, name: t.name, detail: detail, path: t.path, line: t.line,
                                        isExpandable: !t.callers.isEmpty, isExpanded: open && !t.callers.isEmpty))
            guard open else { return }
            for (i, c) in t.callers.enumerated() { walk(c, "\(id)/\(i)", level + 1) }
        }
        walk(root, "callers", 0)
        return out
    }
}
