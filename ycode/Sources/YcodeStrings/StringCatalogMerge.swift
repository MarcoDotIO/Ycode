import Foundation

/// Merging strings extracted from source into a catalog ("Refresh from
/// source", `ycode strings extract`). See `specs/ide/string-catalog.md`,
/// "Ycode implementation":
///
/// - a key found in code and not in the catalog is added: with no
///   `extractionState` (extracted), or `extracted_with_value` and a
///   source-language unit in state `new` when the code gives a default value;
/// - a key found again that was `stale` (or `migrated`) becomes extracted
///   again;
/// - a key no longer found becomes `stale` when it was extracted;
///   `manual`, `migrated` and `stale` keys are left alone;
/// - the comment follows the code's comment when the code has one;
/// - a default value from code replaces the source unit's value while that
///   unit is in state `new`.
extension StringCatalog {
    public struct MergeSummary: Equatable, Sendable {
        public var added: [String] = []
        public var markedStale: [String] = []
        public var revived: [String] = []
        public var updated: [String] = []
        public var isEmpty: Bool { added.isEmpty && markedStale.isEmpty && revived.isEmpty && updated.isEmpty }
    }

    /// Merges `extracted` (strings of this catalog's table only).
    @discardableResult
    public mutating func merge(extracted: [ExtractedString]) -> MergeSummary {
        var summary = MergeSummary()
        // One record per key: the first default value and comment found.
        var found: [(String, ExtractedString)] = []
        var index: [String: Int] = [:]
        for e in extracted where !e.key.isEmpty {
            if let i = index[e.key] {
                if found[i].1.comment == nil { found[i].1.comment = e.comment }
                if found[i].1.defaultValue == nil { found[i].1.defaultValue = e.defaultValue }
            } else {
                index[e.key] = found.count
                found.append((e.key, e))
            }
        }
        let source = sourceLanguage
        var strings = json["strings"] ?? .object([])
        for (key, e) in found {
            var entry = strings[key] ?? .object([])
            let isNew = strings[key] == nil
            let before = entry
            let state = entry["extractionState"]?.stringValue
            if state == "stale" || state == "migrated" {
                entry["extractionState"] = nil
                if !isNew { summary.revived.append(key) }
            }
            if let c = e.comment, entry["comment"]?.stringValue != c { entry["comment"] = .string(c) }
            if let v = e.defaultValue, entry["extractionState"]?.stringValue != "manual" {
                entry["extractionState"] = .string("extracted_with_value")
                var locs = entry["localizations"] ?? .object([])
                var loc = locs[source] ?? .object([])
                let unit = loc["stringUnit"]
                if unit == nil || unit?["state"]?.stringValue == "new" {
                    if unit?["value"]?.stringValue != v {
                        loc["stringUnit"] = .object([("state", .string("new")), ("value", .string(v))])
                        locs[source] = loc
                        entry["localizations"] = locs
                    }
                }
            }
            strings[key] = entry
            if isNew { summary.added.append(key) } else if entry != before, !summary.revived.contains(key) { summary.updated.append(key) }
        }
        for (key, entry) in strings.objectPairs where index[key] == nil && !key.isEmpty {
            let state = entry["extractionState"]?.stringValue
            guard state == nil || state == "extracted_with_value" else { continue }
            var e = entry
            e["extractionState"] = .string("stale")
            strings[key] = e
            summary.markedStale.append(key)
        }
        json["strings"] = strings
        return summary
    }
}
