import Foundation
import YcodePlist

/// Edits a property list by index path (child positions from the root).
/// See `specs/ide/plist-editor.md`.
public struct PlistTree: Equatable {
    public var root: PropertyListItem

    public init(root: PropertyListItem) { self.root = root }

    public static let types = ["Array", "Dictionary", "Boolean", "Data", "Date", "Number", "String"]

    /// Children of a container as (key or "Item N", value).
    public static func children(of v: PropertyListItem) -> [(key: String, value: PropertyListItem)] {
        switch v {
        case .dictionary(let d): d.map { ($0.key, $0.value) }
        case .array(let a): a.enumerated().map { ("Item \($0.offset)", $0.element) }
        default: []
        }
    }

    public func item(at path: [Int]) -> PropertyListItem? {
        var cur = root
        for i in path {
            let kids = Self.children(of: cur)
            guard kids.indices.contains(i) else { return nil }
            cur = kids[i].value
        }
        return cur
    }

    /// Applies `f` to the container holding `path`'s last element.
    private mutating func modifyParent(of path: [Int], _ f: (inout PropertyListItem, Int) -> Void) {
        guard let last = path.last else { return }
        func walk(_ v: inout PropertyListItem, _ rest: ArraySlice<Int>) {
            if rest.count == 1 { f(&v, rest.first!); return }
            let i = rest.first!
            switch v {
            case .dictionary(var d) where d.indices.contains(i):
                walk(&d[i].value, rest.dropFirst()); v = .dictionary(d)
            case .array(var a) where a.indices.contains(i):
                walk(&a[i], rest.dropFirst()); v = .array(a)
            default: break
            }
        }
        _ = last
        walk(&root, path[...])
    }

    public mutating func setKey(_ key: String, at path: [Int]) {
        modifyParent(of: path) { v, i in
            if case .dictionary(var d) = v, d.indices.contains(i), !d.contains(where: { $0.key == key }) { d[i].key = key; v = .dictionary(d) }
        }
    }

    public mutating func setValue(_ newValue: PropertyListItem, at path: [Int]) {
        if path.isEmpty { root = newValue; return }
        modifyParent(of: path) { v, i in
            switch v {
            case .dictionary(var d) where d.indices.contains(i): d[i].value = newValue; v = .dictionary(d)
            case .array(var a) where a.indices.contains(i): a[i] = newValue; v = .array(a)
            default: break
            }
        }
    }

    /// The Value column's editable text: Data as hex bytes in angle
    /// brackets, other values as their summary.
    public static func editText(_ v: PropertyListItem) -> String {
        if case .data(let d) = v { return "<" + d.map { String(format: "%02x", $0) }.joined() + ">" }
        return v.summary
    }

    /// Parses Value-column text for an item's type; nil if it does not fit.
    public static func parse(_ text: String, as type: String) -> PropertyListItem? {
        let t = text.trimmingCharacters(in: .whitespaces)
        switch type {
        case "String": return .string(text)
        case "Number": return Int(t).map(PropertyListItem.integer) ?? Double(t).map(PropertyListItem.real)
        case "Boolean":
            switch t.uppercased() { case "YES", "TRUE", "1": return .bool(true); case "NO", "FALSE", "0": return .bool(false); default: return nil }
        case "Date": return PropertyListDocument.dateFormatter.date(from: t).map(PropertyListItem.date)
        case "Data":
            let hex = t.filter { !"<> ".contains($0) }
            guard hex.count % 2 == 0 else { return nil }
            var bytes: [UInt8] = []
            var i = hex.startIndex
            while i < hex.endIndex {
                let j = hex.index(i, offsetBy: 2)
                guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
                bytes.append(b)
                i = j
            }
            return .data(Data(bytes))
        default: return nil
        }
    }

    /// Changes an item's type, keeping what converts (text, numbers).
    public mutating func setType(_ type: String, at path: [Int]) {
        guard let old = item(at: path), old.typeName != type else { return }
        let converted: PropertyListItem = switch type {
        case "Array": .array([])
        case "Dictionary": .dictionary([])
        case "Boolean":
            switch old {
            case .integer(let i): .bool(i != 0)
            case .real(let r): .bool(r != 0)
            default: Self.parse(old.summary, as: "Boolean") ?? .bool(false)
            }
        case "Number":
            if case .bool(let b) = old { .integer(b ? 1 : 0) } else { Self.parse(old.summary, as: "Number") ?? .integer(0) }
        case "Date":
            if case .string(let s) = old { Self.parse(s, as: "Date") ?? .date(Date(timeIntervalSince1970: 0)) } else { .date(Date(timeIntervalSince1970: 0)) }
        case "Data":
            if case .string(let s) = old { Self.parse(s, as: "Data") ?? .data(Data()) } else { .data(Data()) }
        default: .string(Self.isContainer(old) ? "" : old.summary)
        }
        setValue(converted, at: path)
    }

    static func isContainer(_ v: PropertyListItem) -> Bool {
        if case .array = v { return true }
        if case .dictionary = v { return true }
        return false
    }

    /// Inserts a new String item after `path` (or as the first child of the
    /// container at `path` when `asChild`). Returns the new item's path.
    @discardableResult
    public mutating func insert(after path: [Int], asChild: Bool = false) -> [Int] {
        let parentPath = asChild ? path : Array(path.dropLast())
        let index = asChild ? 0 : (path.last.map { $0 + 1 } ?? 0)
        guard let parent = item(at: parentPath) else { return path }
        let existing = Set(Self.children(of: parent).map(\.key))
        var key = "New item"
        var n = 2
        while existing.contains(key) { key = "New item - \(n)"; n += 1 }
        let new = PropertyListItem.string("")
        var p = parent
        switch p {
        case .dictionary(var d): d.insert(PropertyListEntry(key: key, value: new), at: min(index, d.count)); p = .dictionary(d)
        case .array(var a): a.insert(new, at: min(index, a.count)); p = .array(a)
        default: return path
        }
        setValue(p, at: parentPath)
        return parentPath + [index]
    }

    public mutating func remove(at path: [Int]) {
        modifyParent(of: path) { v, i in
            switch v {
            case .dictionary(var d) where d.indices.contains(i): d.remove(at: i); v = .dictionary(d)
            case .array(var a) where a.indices.contains(i): a.remove(at: i); v = .array(a)
            default: break
            }
        }
    }
}
