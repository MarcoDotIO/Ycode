import Foundation
import Observation
import YcodeIDECore

/// The String Catalog editor of the Linux IDE (`specs/ide/string-catalog.md`
/// §Editor): the languages sidebar with progress, the Key | Default
/// Localization | Comment | <language> | State table, its filter and
/// sort, Add Key, Remove, Mark as Needs Review / Reviewed, Add Language and
/// Refresh from Source. Every edit is written at once; an untouched catalog
/// is never written, so it stays byte for byte. No toolkit types.
@MainActor
@Observable
public final class StringCatalogEditorModel {
    public let path: String
    public private(set) var catalog: StringCatalog
    /// The language whose translations the table shows.
    public private(set) var language: String
    public private(set) var selectedKey: String?
    public private(set) var filter = ""
    public private(set) var sortColumn: Column?
    public private(set) var sortAscending = true
    public private(set) var problem: String?
    /// What the last Refresh from Source changed.
    public private(set) var lastRefresh: StringCatalog.MergeSummary?
    /// Bumped on every write.
    public private(set) var saveCount = 0

    /// The sources Refresh from Source reads (the catalog's targets');
    /// nil or empty: every source file under the catalog's folder.
    @ObservationIgnored public var sourceFiles: (() -> [String])?
    /// Called with a language code the user added (the project's
    /// `knownRegions` gets it).
    @ObservationIgnored public var onAddLanguage: ((String) -> Void)?

    /// The + menu's languages (codes).
    public static let commonLanguages = ["ar", "de", "es", "fr", "hi", "it", "ja", "ko", "nl", "pl", "pt-BR", "ru", "sv", "tr", "uk", "zh-Hans", "zh-Hant"]

    public enum Column: String, CaseIterable, Sendable { case key = "Key", defaultValue = "Default Localization", comment = "Comment", translation = "Translation", state = "State" }

    public init(path: String) throws {
        self.path = path
        let c = try StringCatalog(data: Data(contentsOf: URL(fileURLWithPath: path)))
        catalog = c
        language = c.sourceLanguage
    }

    public var isSourceLanguage: Bool { language == catalog.sourceLanguage }
    public var languages: [String] { catalog.languages }

    /// "German (de)" style names: the English name of the code.
    public static func displayName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
    }

    /// The sidebar's line for a language: "(Source)" or its percentage.
    public func sidebarDetail(_ code: String) -> String {
        code == catalog.sourceLanguage ? "Source" : "\(catalog.progress(language: code))%"
    }

    public static func stateTitle(_ s: StringCatalog.State) -> String {
        switch s {
        case .translated: "Translated"
        case .needsReview: "Needs Review"
        case .new: "New"
        case .stale: "Stale"
        case .dontTranslate: "Don't Translate"
        case .variesByPlural: "Varies"
        }
    }

    /// The table's rows: filtered by key, value, comment or translation
    /// (ignoring case), in file order or the header's sort.
    public var rows: [StringCatalog.Row] {
        var rs = catalog.rows(language: language)
        let f = filter.trimmingCharacters(in: .whitespaces)
        if !f.isEmpty {
            rs = rs.filter { r in [r.key, r.defaultValue, r.comment, r.translation].contains { $0.localizedCaseInsensitiveContains(f) } }
        }
        guard let c = sortColumn else { return rs }
        func text(_ r: StringCatalog.Row) -> String {
            switch c {
            case .key: r.key
            case .defaultValue: r.defaultValue
            case .comment: r.comment
            case .translation: r.translation
            case .state: Self.stateTitle(r.state)
            }
        }
        let indexed = Array(rs.enumerated())
        return indexed.sorted { a, b in
            let o = text(a.element).localizedStandardCompare(text(b.element))
            if o == .orderedSame { return a.offset < b.offset }
            return (o == .orderedAscending) == sortAscending
        }.map(\.element)
    }

    /// Counts for the bar under the table.
    public var countText: String {
        let all = catalog.keys.count, shown = rows.count
        let s = all == 1 ? "1 string" : "\(all) strings"
        return shown == all ? s : "\(shown) of \(s)"
    }

    public func select(language code: String) {
        guard catalog.languages.contains(code) else { return }
        language = code
        if sortColumn == .translation && isSourceLanguage { sortColumn = nil }
    }

    public func select(key: String?) { selectedKey = key }

    public func setFilter(_ text: String) { filter = text }

    public func sort(by column: Column) {
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

    /// "+" ▸ a language: adds its column (written once it has a string)
    /// and tells the project.
    public func addLanguage(_ code: String) {
        catalog.addLanguage(code)
        onAddLanguage?(code)
        language = code
    }

    @discardableResult
    public func setTranslation(_ value: String, key: String) -> Bool {
        guard !isSourceLanguage, let row = catalog.rows(language: language).first(where: { $0.key == key }),
              row.variations.isEmpty, row.state != .dontTranslate, row.translation != value else { return false }
        catalog.setTranslation(value, key: key, language: language)
        return save()
    }

    /// The source language's value (the Default Localization column).
    @discardableResult
    public func setDefaultValue(_ value: String, key: String) -> Bool {
        guard let row = catalog.rows(language: catalog.sourceLanguage).first(where: { $0.key == key }),
              row.variations.isEmpty, row.defaultValue != value else { return false }
        catalog.setTranslation(value == key ? "" : value, key: key, language: catalog.sourceLanguage)
        return save()
    }

    @discardableResult
    public func setComment(_ value: String, key: String) -> Bool {
        guard catalog.rows(language: language).first(where: { $0.key == key })?.comment != value else { return false }
        catalog.setComment(value, key: key)
        return save()
    }

    /// Mark for Review / Mark as Reviewed on the selected language.
    @discardableResult
    public func setNeedsReview(_ on: Bool, key: String) -> Bool {
        guard let row = catalog.rows(language: language).first(where: { $0.key == key }),
              on ? row.state == .translated : row.state == .needsReview else { return false }
        catalog.setState(on ? .needsReview : .translated, key: key, language: language)
        return save()
    }

    /// Add Key: "New Key", "New Key 2" … with `extractionState = manual`;
    /// selects it.
    @discardableResult
    public func addKey(_ key: String? = nil) -> String {
        var k = key ?? "New Key"
        if key == nil {
            var n = 2
            while catalog.keys.contains(k) { k = "New Key \(n)"; n += 1 }
        }
        catalog.addKey(k)
        selectedKey = k
        save()
        return k
    }

    /// Removes the selected key and its translations.
    @discardableResult
    public func removeSelectedKey() -> Bool {
        guard let k = selectedKey, catalog.keys.contains(k) else { return false }
        let keys = rows.map(\.key)
        let i = keys.firstIndex(of: k) ?? 0
        catalog.removeKey(k)
        let rest = rows.map(\.key)
        selectedKey = rest.isEmpty ? nil : rest[min(i, rest.count - 1)]
        return save()
    }

    /// Extracts this catalog's table from the sources, merges, and saves
    /// when something changed (`specs/ide/string-catalog.md` C.6).
    @discardableResult
    public func refreshFromSource() -> StringCatalog.MergeSummary {
        var files = sourceFiles?() ?? []
        if files.isEmpty { files = StringsCLI.sourceFiles([URL(fileURLWithPath: path).deletingLastPathComponent().path]) }
        let table = StringCatalog.tableName(forPath: path)
        let found = files.flatMap { StringExtractor.extract(file: $0) }.filter { $0.table == table }
        let summary = catalog.merge(extracted: found)
        if !summary.isEmpty { save() }
        lastRefresh = summary
        return summary
    }

    /// The last refresh in words.
    public var refreshText: String? {
        guard let s = lastRefresh else { return nil }
        if s.isEmpty { return "Up to date with the source code." }
        var parts: [String] = []
        if !s.added.isEmpty { parts.append("\(s.added.count) added") }
        if !s.updated.isEmpty { parts.append("\(s.updated.count) updated") }
        if !s.revived.isEmpty { parts.append("\(s.revived.count) back in use") }
        if !s.markedStale.isEmpty { parts.append("\(s.markedStale.count) stale") }
        return parts.joined(separator: ", ")
    }

    public func clearProblem() { problem = nil }

    /// Rereads the file (after the source view edited it).
    public func reload() throws {
        catalog = try StringCatalog(data: Data(contentsOf: URL(fileURLWithPath: path)))
        if !catalog.languages.contains(language) { language = catalog.sourceLanguage }
    }

    @discardableResult
    private func save() -> Bool {
        do {
            try catalog.data().write(to: URL(fileURLWithPath: path), options: .atomic)
            problem = nil
            saveCount += 1
            return true
        } catch {
            problem = "Could not save “\((path as NSString).lastPathComponent)”: \(error.localizedDescription)"
            return false
        }
    }
}
