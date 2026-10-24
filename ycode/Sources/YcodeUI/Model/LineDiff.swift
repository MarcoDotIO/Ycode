import Foundation

/// A line diff (longest common subsequence) and its side-by-side layout.
/// See `specs/ide/comparison.md`.
public enum LineDiff {
    public enum Op: Equatable, Sendable {
        case same(String)
        case removed(String)
        case added(String)
    }

    /// Edit script turning `old` into `new`.
    public static func diff(_ old: [String], _ new: [String]) -> [Op] {
        // Trim the common prefix and suffix first; the table covers the rest.
        var start = 0
        while start < old.count, start < new.count, old[start] == new[start] { start += 1 }
        var oEnd = old.count, nEnd = new.count
        while oEnd > start, nEnd > start, old[oEnd - 1] == new[nEnd - 1] { oEnd -= 1; nEnd -= 1 }
        let a = Array(old[start..<oEnd]), b = Array(new[start..<nEnd])
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        if !a.isEmpty && !b.isEmpty {
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var ops: [Op] = old[..<start].map { .same($0) }
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] { ops.append(.same(a[i])); i += 1; j += 1 }
            // Removals before additions, as unified diffs show them.
            else if i < a.count, j == b.count || lcs[i + 1][j] >= lcs[i][j + 1] { ops.append(.removed(a[i])); i += 1 }
            else { ops.append(.added(b[j])); j += 1 }
        }
        ops += old[oEnd...].map { .same($0) }
        return ops
    }

    public static func lines(_ text: String) -> [String] {
        var l = text.components(separatedBy: "\n")
        if l.last == "" { l.removeLast() }
        return l
    }

    /// One row of the side-by-side view. A nil side is a filler row.
    public struct Row: Equatable, Sendable {
        public enum Kind: Sendable { case same, changed, removed, added }
        public var kind: Kind
        public var left: (number: Int, text: String)?
        public var right: (number: Int, text: String)?
        public static func == (a: Row, b: Row) -> Bool {
            a.kind == b.kind && a.left?.number == b.left?.number && a.left?.text == b.left?.text
                && a.right?.number == b.right?.number && a.right?.text == b.right?.text
        }
    }

    /// Pairs removals with following additions as changed rows.
    public static func sideBySide(_ ops: [Op]) -> [Row] {
        var rows: [Row] = []
        var l = 0, r = 0
        var removed: [String] = [], added: [String] = []
        func flush() {
            for k in 0..<max(removed.count, added.count) {
                let left = k < removed.count ? (l + 1 + k, removed[k]) : nil
                let right = k < added.count ? (r + 1 + k, added[k]) : nil
                let kind: Row.Kind = left != nil && right != nil ? .changed : (left != nil ? .removed : .added)
                rows.append(Row(kind: kind, left: left, right: right))
            }
            l += removed.count
            r += added.count
            removed = []
            added = []
        }
        for op in ops {
            switch op {
            case .same(let s):
                flush()
                l += 1
                r += 1
                rows.append(Row(kind: .same, left: (l, s), right: (r, s)))
            case .removed(let s): removed.append(s)
            case .added(let s): added.append(s)
            }
        }
        flush()
        return rows
    }

    /// A unified diff body (`-`/`+`/` ` prefixed lines) with up to
    /// `context` unchanged lines around each change.
    public static func unified(_ ops: [Op], context: Int = 3) -> String {
        let changed = ops.indices.filter { if case .same = ops[$0] { false } else { true } }
        guard !changed.isEmpty else { return "" }
        var keep = Set<Int>()
        for c in changed { for k in max(0, c - context)...min(ops.count - 1, c + context) { keep.insert(k) } }
        var out: [String] = []
        var last = -1
        for k in keep.sorted() {
            if last >= 0, k != last + 1 { out.append("…") }
            switch ops[k] {
            case .same(let s): out.append(" " + s)
            case .removed(let s): out.append("-" + s)
            case .added(let s): out.append("+" + s)
            }
            last = k
        }
        return out.joined(separator: "\n")
    }
}
