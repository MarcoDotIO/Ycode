import Foundation
import YcodePlist

// Reordering and the view's sort for the property list editor
// (`specs/ide/plist-editor.md`): items move within their container; the
// Key, Type and Value column headers sort what is shown, never the file.

extension PlistTree {
    /// Moves the item at `path` by `offset` places within its container
    /// (clamped to the container's ends). Returns its new path, or nil when
    /// nothing moved (the root, a bad path, already at that end).
    @discardableResult
    public mutating func move(at path: [Int], by offset: Int) -> [Int]? {
        guard let last = path.last, offset != 0 else { return nil }
        let parentPath = Array(path.dropLast())
        guard let parent = item(at: parentPath) else { return nil }
        let count = Self.children(of: parent).count
        guard (0..<count).contains(last) else { return nil }
        let target = min(max(last + offset, 0), count - 1)
        guard target != last else { return nil }
        let moved: PropertyListItem
        switch parent {
        case .dictionary(var d):
            let e = d.remove(at: last)
            d.insert(e, at: target)
            moved = .dictionary(d)
        case .array(var a):
            let e = a.remove(at: last)
            a.insert(e, at: target)
            moved = .array(a)
        default: return nil
        }
        setValue(moved, at: parentPath)
        return parentPath + [target]
    }

    /// The column a header click sorts by.
    public enum SortColumn: String, Sendable, CaseIterable { case key = "Key", type = "Type", value = "Value" }

    /// The order to show a container's children in: file order without a
    /// column, else sorted by that column's text (case-insensitive, numbers
    /// in numeric order), ties in file order. Array items keep file order
    /// when sorting by key ("Item N").
    public static func displayOrder(of container: PropertyListItem, by column: SortColumn?, ascending: Bool = true) -> [Int] {
        let kids = children(of: container)
        let indices = Array(kids.indices)
        guard let column else { return indices }
        if column == .key, case .array = container { return ascending ? indices : indices.reversed() }
        func text(_ i: Int) -> String {
            switch column {
            case .key: kids[i].key
            case .type: kids[i].value.typeName
            case .value: kids[i].value.summary
            }
        }
        let sorted = indices.sorted { a, b in
            let order = text(a).localizedStandardCompare(text(b))
            if order == .orderedSame { return a < b }
            return (order == .orderedAscending) == ascending
        }
        return sorted
    }
}
