import Foundation
import YcodeLanguage

/// Editor ▸ Refactor (`specs/ide/reference-ui-4.md` §8.2): the items in the
/// reference order, each mapped to the sourcekit-lsp code action that does
/// the same job (matched by title words and kind) where one exists. Items
/// without a matching action at the cursor are disabled. The mapping is
/// Ycode's own design (§8, evidence "—").
public enum RefactorCatalog {
    public struct Item: Equatable, Sendable {
        public var title: String
        /// Lower-case phrases; an action matches when its title contains one.
        public var phrases: [String]
        /// Required code-action kind prefix, if any.
        public var kind: String?
        public var isMappable: Bool { !phrases.isEmpty }
    }

    /// Groups in menu order (Rename… is first and handled by rename).
    public static let groups: [[Item]] = [
        [
            // reference-ui-5.md §2.7: "Extract to File" precedes "Extract Selection to File".
            Item(title: "Extract to File", phrases: []),
            Item(title: "Extract Selection to File", phrases: []),
            Item(title: "Extract to Function", phrases: ["extract function", "extract to function", "extract method"]),
            Item(title: "Extract to Method", phrases: ["extract method", "extract to method"]),
            Item(title: "Extract to Variable", phrases: ["extract expression", "extract variable", "extract to variable"]),
            Item(title: "Extract All Occurrences", phrases: ["extract repeated", "extract all"]),
        ],
        [
            Item(title: "Add Missing Abstract Class Overrides", phrases: []),
            Item(title: "Add Missing Protocol Requirements", phrases: ["protocol stub", "missing protocol", "protocol requirement"]),
            Item(title: "Add Missing Switch Cases", phrases: ["switch cases", "missing cases", "missing switch"]),
            Item(title: "Convert to Switch", phrases: ["to switch"]),
            Item(title: "Convert to Regex Builder", phrases: ["regex builder"]),
            Item(title: "Expand Default", phrases: ["expand default"]),
            Item(title: "Generate Memberwise Initializer", phrases: ["memberwise"]),
            Item(title: "Generate Missing Function Definitions", phrases: []),
            Item(title: "Wrap in NSLocalizedString", phrases: ["localize string", "nslocalizedstring"]),
        ],
        [
            Item(title: "Convert Function to Async", phrases: ["convert function to async", "function to async"]),
            Item(title: "Change Localized String Key", phrases: []),
            Item(title: "Convert Localized String to Symbol", phrases: []),
            Item(title: "Convert to Localized String Literal", phrases: []),
        ],
    ]

    public static var items: [Item] { groups.flatMap { $0 } }

    /// The index in `actions` of the action for item `index`, or nil.
    public static func actionIndex(forItem index: Int, in actions: [CodeAction]) -> Int? {
        let all = items
        guard all.indices.contains(index) else { return nil }
        let item = all[index]
        guard item.isMappable else { return nil }
        // Extract to Function and Extract to Method share sourcekit's
        // "Extract Method"; prefer an exact title first.
        if let exact = actions.firstIndex(where: { $0.title.caseInsensitiveCompare(item.title) == .orderedSame }) { return exact }
        return actions.firstIndex { a in
            if a.kind?.hasPrefix("quickfix") == true && !item.title.hasPrefix("Add Missing") { return false }
            if let k = item.kind, a.kind?.hasPrefix(k) != true { return false }
            let t = a.title.lowercased()
            return item.phrases.contains { t.contains($0) }
        }
    }

    /// Code actions that match no catalog item (listed after the fixed items).
    public static func unmatched(_ actions: [CodeAction]) -> [Int] {
        let used = Set(items.indices.compactMap { actionIndex(forItem: $0, in: actions) })
        return actions.indices.filter { !used.contains($0) && actions[$0].kind?.hasPrefix("quickfix") != true }
    }

    /// The Refactor submenu as menu data.
    static var menuItems: [MenuItemSpec] {
        var out: [MenuItemSpec] = [.command(.init("Rename…", "", [], "renameSymbol:"))]
        var i = 0
        for g in groups {
            out.append(.separator)
            for item in g {
                out.append(item.isMappable ? .command(.init(item.title, "", [], "performRefactorItem:", tag: i)) : CommandTable.unavailable(item.title))
                i += 1
            }
        }
        return out
    }
}
