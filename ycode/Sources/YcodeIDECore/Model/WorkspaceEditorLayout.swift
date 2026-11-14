import Foundation

/// The workspace window's editors and inspector as they were when it
/// closed, kept in the per-workspace user data (`WorkspaceUserState`) so
/// that reopening the workspace brings them back whatever the system's
/// window restoration does (`workspace-window.md` W7.1, council row 186):
/// each pane's document, its first visible line and its selection, the
/// split's direction and proportions, the active pane, and the inspector's
/// visibility and tab. Both IDEs write and read the same values.
public struct WorkspaceEditorLayout: Codable, Equatable, Sendable {
    /// One editor pane.
    public struct Pane: Codable, Equatable, Sendable {
        /// The file it shows (absolute path); nil for an empty pane.
        public var path: String?
        /// The first visible logical line, 1-based.
        public var topLine: Int
        /// The selection's start and length in UTF-16 code units (an
        /// insertion point has length 0).
        public var selectionStart: Int
        public var selectionLength: Int

        public init(path: String?, topLine: Int = 1, selectionStart: Int = 0, selectionLength: Int = 0) {
            self.path = path
            self.topLine = topLine
            self.selectionStart = selectionStart
            self.selectionLength = selectionLength
        }

        /// The selection, clamped to a text of `length` UTF-16 units.
        public func selection(clampedTo length: Int) -> NSRange {
            let start = min(max(0, selectionStart), length)
            return NSRange(location: start, length: min(max(0, selectionLength), length - start))
        }
    }

    public var panes: [Pane]
    /// Side by side (true) or one below the other.
    public var sideBySide: Bool
    /// Each pane's share of the split along its direction (they sum to 1).
    public var fractions: [Double]
    /// The active pane's index.
    public var focused: Int

    public init(panes: [Pane], sideBySide: Bool = true, fractions: [Double]? = nil, focused: Int = 0) {
        self.panes = panes
        self.sideBySide = sideBySide
        self.fractions = fractions ?? Self.equalFractions(panes.count)
        self.focused = focused
    }

    /// n equal shares.
    public static func equalFractions(_ n: Int) -> [Double] { n > 0 ? Array(repeating: 1 / Double(n), count: n) : [] }

    /// Shares from the panes' sizes along the split (equal shares when the
    /// sizes are unknown).
    public static func fractions(sizes: [Double]) -> [Double] {
        let total = sizes.reduce(0, +)
        guard total > 0, sizes.allSatisfy({ $0 >= 0 }) else { return equalFractions(sizes.count) }
        return sizes.map { $0 / total }
    }

    /// The layout to restore: a pane whose file is gone shows nothing, at
    /// least one pane remains, the shares match the panes and sum to 1, and
    /// the active pane is one of them.
    public func restorable(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> WorkspaceEditorLayout {
        var out = self
        if out.panes.isEmpty { out.panes = [Pane(path: nil)] }
        for i in out.panes.indices {
            if let p = out.panes[i].path, !fileExists(p) { out.panes[i] = Pane(path: nil) }
            out.panes[i].topLine = max(1, out.panes[i].topLine)
        }
        if out.fractions.count != out.panes.count || out.fractions.contains(where: { !($0 > 0) }) {
            out.fractions = Self.equalFractions(out.panes.count)
        } else {
            out.fractions = Self.fractions(sizes: out.fractions)
        }
        out.focused = min(max(0, out.focused), out.panes.count - 1)
        return out
    }

    /// The divider positions (from the split's leading or top edge) for a
    /// split `total` long whose dividers are `divider` thick.
    public func dividerPositions(total: Double, divider: Double) -> [Double] {
        let n = fractions.count
        guard n > 1 else { return [] }
        let usable = max(0, total - divider * Double(n - 1))
        var out: [Double] = []
        var at = 0.0
        for i in 0..<(n - 1) {
            at += usable * fractions[i]
            out.append((at + divider * Double(i)).rounded())
        }
        return out
    }
}

/// The inspector as it was when the window closed (W7.1).
public struct WorkspaceInspectorState: Codable, Equatable, Sendable {
    public var isShown: Bool
    /// The tab: 0 File, 1 History, 2 Quick Help.
    public var tab: Int

    public init(isShown: Bool, tab: Int) {
        self.isShown = isShown
        self.tab = tab
    }

    /// The tab, clamped to the inspector's tabs.
    public func tab(clampedTo count: Int) -> Int { min(max(0, tab), max(0, count - 1)) }
}

extension NavigatorTree {
    /// The expansion to restore when a workspace reopens (`navigators.md`
    /// round 7 §4, council row 187): the saved state of the top row (the
    /// project row stands for the main group) and of its direct children;
    /// rows deeper than that open collapsed. Keys not in the tree (other
    /// sections) are kept.
    public static func reopenedExpansion(_ saved: [String], root: NavigatorNode, keptDepth: Int = 1) -> [String] {
        var deep = Set<String>()
        func walk(_ n: NavigatorNode, _ depth: Int) {
            if depth > keptDepth, n.isExpandable { deep.insert(n.expansionKey) }
            for c in n.children { walk(c, depth + 1) }
        }
        walk(root, 0)
        return saved.filter { !deep.contains($0) }
    }
}
