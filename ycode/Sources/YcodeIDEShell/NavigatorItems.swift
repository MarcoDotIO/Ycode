import Foundation
import YcodeBuild
import YcodeIDECore

/// A project navigator row as a value (the SwiftUI outline's element),
/// mirrored from the core's `NavigatorNode`. Files have no children
/// (`children == nil`), so the outline draws no disclosure triangle.
public struct NavigatorItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: NavigatorNode.Kind
    public var path: String?
    public var children: [NavigatorItem]?

    public init(_ node: NavigatorNode) {
        id = node.expansionKey
        name = node.name
        kind = node.kind
        path = node.path
        children = node.kind == .file ? nil : node.children.map(NavigatorItem.init)
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.name == b.name && a.path == b.path && a.children == b.children
    }
    public func hash(into h: inout Hasher) { h.combine(id) }

    public var isFile: Bool { kind == .file }

    /// The row's symbol: the AppKit navigator's (`WorkspaceChrome.symbol`).
    public var symbolName: String { WorkspaceChrome.symbol(kind: kind, name: name, path: path) }

    /// Ids of the rows from the root to the row with `path` (inclusive), or
    /// nil when no row has it.
    public func idPath(to path: String) -> [String]? {
        if self.path == path { return [id] }
        for c in children ?? [] {
            if let rest = c.idPath(to: path) { return [id] + rest }
        }
        return nil
    }

    /// The row with this id.
    public func find(id: String) -> NavigatorItem? {
        if self.id == id { return self }
        for c in children ?? [] { if let f = c.find(id: id) { return f } }
        return nil
    }

    /// Every file row, depth first.
    public var allFiles: [NavigatorItem] {
        isFile ? [self] : (children ?? []).flatMap(\.allFiles)
    }
}

/// Symbol names the shell uses (the system names; on Linux OpenViews draws
/// its own artwork for each).
public enum ShellSymbols {
    public static func file(named name: String) -> String { WorkspaceChrome.fileSymbol(name) }

    public static func severity(_ s: Diagnostic.Severity) -> String {
        switch s {
        case .error: "xmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .note, .remark: "info.circle"
        }
    }
}
