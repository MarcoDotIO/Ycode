import Foundation
import Observation
import YcodeIDECore
import YcodePlist

/// The property list editor of the Linux IDE (`specs/ide/plist-editor.md`):
/// the Key | Type | Value outline under a Root row, + and −, reordering,
/// type changes, readable or raw key names, and the column headers' sort.
/// Every edit is written to the file at once, in the file's own format
/// (XML, binary or OpenStep); a file that is only looked at is never
/// written, so it stays byte for byte as it was. No toolkit types: tested
/// headless on macOS and Linux.
@MainActor
@Observable
public final class PlistEditorModel {
    public let path: String
    public private(set) var document: PropertyListDocument
    public private(set) var tree: PlistTree
    /// Expanded containers by index path (the root is always shown open).
    public private(set) var expanded: Set<[Int]>
    /// The selected row's index path ([] = Root).
    public var selection: [Int]?
    /// Editor ▸ Raw Keys and Values: raw key names instead of readable ones.
    public var showsRawKeys = false
    /// The header the view is sorted by (nil: file order).
    public private(set) var sortColumn: PlistTree.SortColumn?
    public private(set) var sortAscending = true
    /// Why the last edit was refused or could not be written.
    public private(set) var problem: String?
    /// Bumped on every write (views and drivers wait on it).
    public private(set) var saveCount = 0

    /// Reads `path`; throws when it is not a property list.
    public init(path: String) throws {
        self.path = path
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let d = try PropertyListDocument(data: data)
        document = d
        tree = PlistTree(root: d.root)
        expanded = Self.initiallyExpanded(d.root)
    }

    /// The root and its first level of containers are open at first.
    static func initiallyExpanded(_ root: PropertyListItem) -> Set<[Int]> {
        var out: Set<[Int]> = [[]]
        for (i, kid) in PlistTree.children(of: root).enumerated() where PlistTree.isContainer(kid.value) && PlistTree.children(of: kid.value).count <= 12 {
            out.insert([i])
        }
        return out
    }

    public var formatName: String {
        switch document.format {
        case .xml: "XML Property List"
        case .binary: "Binary Property List"
        case .openStep: "OpenStep Property List"
        }
    }

    // MARK: Rows

    /// One outline row.
    public struct Row: Identifiable, Equatable, Sendable {
        public var path: [Int]
        public var depth: Int
        /// The Key column: "Root", a dictionary key (readable or raw) or "Item N".
        public var key: String
        /// The raw key (dictionary children), else nil.
        public var rawKey: String?
        public var type: String
        /// The Value column: a container's "(N items)", else its editable text.
        public var value: String
        public var isContainer: Bool
        public var isExpanded: Bool
        public var hasChildren: Bool
        public var isKeyEditable: Bool { rawKey != nil }
        public var isValueEditable: Bool { !isContainer }
        public var id: String { path.isEmpty ? "root" : path.map(String.init).joined(separator: ".") }
    }

    /// The rows shown: Root, then the open containers' children in the
    /// view's order.
    public var rows: [Row] {
        var out: [Row] = []
        func add(_ v: PropertyListItem, path: [Int], depth: Int, key: String, rawKey: String?) {
            let container = PlistTree.isContainer(v)
            let open = container && expanded.contains(path)
            out.append(Row(path: path, depth: depth, key: key, rawKey: rawKey, type: v.typeName,
                           value: container ? v.summary : PlistTree.editText(v), isContainer: container, isExpanded: open,
                           hasChildren: container && !PlistTree.children(of: v).isEmpty))
            guard open else { return }
            let kids = PlistTree.children(of: v)
            let isDictionary: Bool = { if case .dictionary = v { return true } else { return false } }()
            for i in PlistTree.displayOrder(of: v, by: sortColumn, ascending: sortAscending) {
                let k = kids[i].key
                add(kids[i].value, path: path + [i], depth: depth + 1, key: isDictionary ? displayedKey(k) : k, rawKey: isDictionary ? k : nil)
            }
        }
        add(tree.root, path: [], depth: 0, key: "Root", rawKey: nil)
        return out
    }

    /// The Key column's text for a raw key.
    public func displayedKey(_ key: String) -> String { showsRawKeys ? key : ProjectEditorModel.readableKey(key) }

    /// The raw key a Key-column text stands for (a readable name maps back).
    public func rawKey(forDisplayed text: String, current: String) -> String {
        if text == displayedKey(current) { return current }
        return ProjectEditorModel.readableInfoKeys.first { $0.value == text }?.key ?? text
    }

    public func isExpanded(_ path: [Int]) -> Bool { expanded.contains(path) }

    public func setExpanded(_ path: [Int], _ on: Bool) {
        if on { expanded.insert(path) } else { expanded = expanded.filter { !$0.starts(with: path) || $0.count < path.count } }
    }

    /// A header click: sorts by the column, or flips the order when it is
    /// the column already; a third click goes back to file order.
    public func sort(by column: PlistTree.SortColumn) {
        if sortColumn != column {
            sortColumn = column
            sortAscending = true
        } else if sortAscending {
            sortAscending = false
        } else {
            sortColumn = nil
            sortAscending = true
        }
    }

    // MARK: Edits

    /// Renames a dictionary key (Key-column text, readable names map back).
    /// A key already used in the same dictionary is refused.
    @discardableResult
    public func setKey(_ text: String, at path: [Int]) -> Bool {
        guard let last = path.last, let parent = tree.item(at: Array(path.dropLast())), case .dictionary(let entries) = parent,
              entries.indices.contains(last) else { return false }
        let current = entries[last].key
        let key = rawKey(forDisplayed: text.trimmingCharacters(in: .whitespaces), current: current)
        guard key != current else { return true }
        guard !key.isEmpty else { return refuse("A key can't be empty.") }
        guard !entries.contains(where: { $0.key == key }) else { return refuse("The key “\(key)” is already in this dictionary.") }
        tree.setKey(key, at: path)
        return commit()
    }

    /// Sets a value from Value-column text; refused when it does not parse
    /// for the item's type.
    @discardableResult
    public func setValueText(_ text: String, at path: [Int]) -> Bool {
        guard let item = tree.item(at: path), !PlistTree.isContainer(item) else { return false }
        if PlistTree.editText(item) == text { return true }
        guard let v = PlistTree.parse(text, as: item.typeName) else {
            return refuse("“\(text)” is not a valid \(item.typeName == "Number" ? "number" : item.typeName.lowercased()) value.")
        }
        guard v != item else { return true }
        tree.setValue(v, at: path)
        return commit()
    }

    /// The Type pop-up (and Editor ▸ Value Type): converts what it can.
    @discardableResult
    public func setType(_ type: String, at path: [Int]) -> Bool {
        guard let item = tree.item(at: path), item.typeName != type, PlistTree.types.contains(type) else { return false }
        tree.setType(type, at: path)
        if PlistTree.isContainer(tree.item(at: path) ?? item) { expanded.insert(path) }
        return commit()
    }

    /// "+" and Editor ▸ Add Item: a new String item after the selected
    /// row, or as the first child of a selected open container (the root
    /// with no selection). Selects and returns the new item's path.
    @discardableResult
    public func addItem() -> [Int] {
        let sel = selection ?? []
        let asChild: Bool
        if let v = tree.item(at: sel), PlistTree.isContainer(v), sel.isEmpty || expanded.contains(sel) || PlistTree.children(of: v).isEmpty {
            asChild = true
        } else {
            asChild = false
        }
        let p = tree.insert(after: sel, asChild: asChild)
        if asChild { expanded.insert(sel) }
        // The rows after the new one in the same container moved down.
        shiftExpanded(inserting: p)
        selection = p
        commit()
        return p
    }

    /// "−" (and the Delete key): removes the selected row. The root stays.
    @discardableResult
    public func removeSelected() -> Bool {
        guard let sel = selection, !sel.isEmpty, tree.item(at: sel) != nil else { return false }
        tree.remove(at: sel)
        shiftExpanded(removing: sel)
        let parent = Array(sel.dropLast())
        let count = tree.item(at: parent).map { PlistTree.children(of: $0).count } ?? 0
        selection = count == 0 ? parent : parent + [min(sel.last!, count - 1)]
        return commit()
    }

    /// Moves the selected item up (-1) or down (+1) among its siblings.
    @discardableResult
    public func moveSelected(by offset: Int) -> Bool {
        guard let sel = selection, let to = tree.move(at: sel, by: offset) else { return false }
        // Open state follows the two swapped subtrees.
        let fromOpen = expanded.filter { $0.starts(with: sel) }
        expanded.subtract(fromOpen)
        let between = sel.last! < to.last! ? (sel.last! + 1)...to.last! : to.last!...(sel.last! - 1)
        let step = sel.last! < to.last! ? -1 : 1
        let parent = Array(sel.dropLast())
        let shifted = expanded.filter { $0.count > parent.count && $0.starts(with: parent) && between.contains($0[parent.count]) }
        expanded.subtract(shifted)
        for p in shifted { var q = p; q[parent.count] += step; expanded.insert(q) }
        for p in fromOpen { expanded.insert(to + p.dropFirst(sel.count)) }
        selection = to
        return commit()
    }

    /// Editor ▸ Value Type ▸ <type> on the selection.
    @discardableResult
    public func setTypeOfSelection(_ type: String) -> Bool {
        guard let sel = selection else { return false }
        return setType(type, at: sel)
    }

    public var selectedTypeName: String? { selection.flatMap { tree.item(at: $0)?.typeName } }

    /// Can the selection be removed or moved.
    public var canRemove: Bool { (selection.map { !$0.isEmpty }) ?? false }

    public func clearProblem() { problem = nil }

    /// Rereads the file (after the source view edited it).
    public func reload() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        document = try PropertyListDocument(data: data)
        tree = PlistTree(root: document.root)
        if let s = selection, tree.item(at: s) == nil { selection = nil }
        problem = nil
    }

    private func shiftExpanded(inserting p: [Int]) {
        let parent = Array(p.dropLast()), at = p.last!
        expanded = Set(expanded.map { e in
            guard e.count > parent.count, e.starts(with: parent), e[parent.count] >= at else { return e }
            var q = e
            q[parent.count] += 1
            return q
        })
    }

    private func shiftExpanded(removing p: [Int]) {
        let parent = Array(p.dropLast()), at = p.last!
        expanded = Set(expanded.compactMap { e in
            guard e.count > parent.count, e.starts(with: parent) else { return e }
            if e[parent.count] == at { return nil }
            guard e[parent.count] > at else { return e }
            var q = e
            q[parent.count] -= 1
            return q
        })
    }

    @discardableResult
    private func refuse(_ why: String) -> Bool {
        problem = why
        return false
    }

    /// Writes the tree in the file's format.
    @discardableResult
    private func commit() -> Bool {
        document.root = tree.root
        do {
            try document.data().write(to: URL(fileURLWithPath: path), options: .atomic)
            problem = nil
            saveCount += 1
            return true
        } catch {
            problem = "Could not save “\((path as NSString).lastPathComponent)”: \(error.localizedDescription)"
            return false
        }
    }
}
