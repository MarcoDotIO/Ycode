import AppKit
import YcodePlist
import YcodeProject

/// The Info tab's type sections (reference-ui-3.md §1.7): Document Types,
/// Exported and Imported Type Identifiers and URL Types, read from and
/// written to the target's Info.plist file. A target with a generated
/// Info.plist (`GENERATE_INFOPLIST_FILE = YES`, `INFOPLIST_KEY_*`) and no
/// `INFOPLIST_FILE` has no entries; adding the first one creates
/// `<Target>/Info.plist` holding only the type keys, references it from the
/// main group and sets `INFOPLIST_FILE`. The build merges that file with the
/// generated keys (build-pif.md), so generation stays on.
extension ProjectEditorModel {
    public static let infoTypeKeys: [(title: String, key: String)] = [
        ("Document Types", "CFBundleDocumentTypes"), ("Exported Type Identifiers", "UTExportedTypeDeclarations"),
        ("Imported Type Identifiers", "UTImportedTypeDeclarations"), ("URL Types", "CFBundleURLTypes"),
    ]

    /// The key in each entry that names it in its row.
    static let infoTypeNameKeys = [
        "CFBundleDocumentTypes": "CFBundleTypeName", "UTExportedTypeDeclarations": "UTTypeIdentifier",
        "UTImportedTypeDeclarations": "UTTypeIdentifier", "CFBundleURLTypes": "CFBundleURLName",
    ]

    /// A new entry's keys (public Info.plist key reference).
    static func newInfoTypeEntry(_ key: String) -> PropertyListItem {
        switch key {
        case "CFBundleDocumentTypes":
            .dictionary([.init(key: "CFBundleTypeName", value: .string("Untitled")), .init(key: "CFBundleTypeRole", value: .string("Editor")),
                         .init(key: "LSItemContentTypes", value: .array([]))])
        case "CFBundleURLTypes":
            .dictionary([.init(key: "CFBundleURLName", value: .string("")), .init(key: "CFBundleTypeRole", value: .string("Editor")),
                         .init(key: "CFBundleURLSchemes", value: .array([]))])
        default:
            .dictionary([.init(key: "UTTypeIdentifier", value: .string("")), .init(key: "UTTypeDescription", value: .string("")),
                         .init(key: "UTTypeConformsTo", value: .array([]))])
        }
    }

    func infoPlistURL(target: String, configuration: String) -> URL? {
        guard let file = resolve(target: target, configuration: configuration)?.settings["INFOPLIST_FILE"], !file.isEmpty else { return nil }
        return file.hasPrefix("/") ? URL(fileURLWithPath: file) : proj.projectDirectory(xcodeprojURL: xcodeprojURL).appendingPathComponent(file)
    }

    /// The entries of one type section (an Info.plist array key).
    public func infoTypeEntries(_ key: String, target: String, configuration: String) -> [PropertyListItem] {
        if case .array(let a)? = infoDictionary(target: target, configuration: configuration).first(where: { $0.key == key })?.value { return a }
        return []
    }

    /// The row title of an entry: its name key, or "Untitled".
    public static func infoTypeEntryName(_ entry: PropertyListItem, key: String) -> String {
        if case .dictionary(let d) = entry, let n = infoTypeNameKeys[key],
           case .string(let s)? = d.first(where: { $0.key == n })?.value, !s.isEmpty { return s }
        return "Untitled"
    }

    public enum InfoTypeError: Error { case noInfoPlistFile }

    /// The target generates its Info.plist from build settings.
    public func generatesInfoPlist(target: String, configuration: String) -> Bool {
        resolve(target: target, configuration: configuration)?.settings["GENERATE_INFOPLIST_FILE"].uppercased() == "YES"
    }

    /// For a generated Info.plist without a file: creates
    /// `<Target>/Info.plist` (an empty dictionary), references it and sets
    /// `INFOPLIST_FILE` for every configuration of the target.
    mutating func createInfoPlistFile(target: String) throws -> URL {
        let rel = "\(target)/Info.plist"
        let url = proj.projectDirectory(xcodeprojURL: xcodeprojURL).appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try PropertyListDocument(root: .dictionary([])).xml().write(to: url, atomically: true, encoding: .utf8)
            proj.addFileReference(path: rel, to: proj.project?.string("mainGroup") ?? "")
        }
        setSetting("INFOPLIST_FILE", rel, target: target)
        return url
    }

    /// Replaces a section's entries in the Info.plist file; an empty list
    /// removes the key.
    public mutating func setInfoTypeEntries(_ key: String, _ entries: [PropertyListItem], target: String, configuration: String) throws {
        let url: URL
        if let u = infoPlistURL(target: target, configuration: configuration) {
            url = u
        } else if generatesInfoPlist(target: target, configuration: configuration) {
            if entries.isEmpty { return }
            url = try createInfoPlistFile(target: target)
        } else {
            throw InfoTypeError.noInfoPlistFile
        }
        var doc = (try? PropertyListDocument(data: Data(contentsOf: url))) ?? PropertyListDocument(root: .dictionary([]))
        guard case .dictionary(var d) = doc.root else { return }
        if let i = d.firstIndex(where: { $0.key == key }) {
            if entries.isEmpty { d.remove(at: i) } else { d[i].value = .array(entries) }
        } else if !entries.isEmpty {
            d.append(.init(key: key, value: .array(entries)))
        }
        doc.root = .dictionary(d)
        try doc.data().write(to: url, options: .atomic)
    }

    public mutating func addInfoTypeEntry(_ key: String, target: String, configuration: String) throws {
        try setInfoTypeEntries(key, infoTypeEntries(key, target: target, configuration: configuration) + [Self.newInfoTypeEntry(key)],
                               target: target, configuration: configuration)
    }

    public mutating func removeInfoTypeEntry(_ key: String, at index: Int, target: String, configuration: String) throws {
        var e = infoTypeEntries(key, target: target, configuration: configuration)
        guard e.indices.contains(index) else { return }
        e.remove(at: index)
        try setInfoTypeEntries(key, e, target: target, configuration: configuration)
    }
}

extension ProjectEditorController {
    /// One type section's body: a Key | Type | Value table with one
    /// disclosure row per entry; an expanded entry lists its keys.
    func infoTypeSection(title: String, key: String, target t: String) -> NSView {
        let entries = model.infoTypeEntries(key, target: t, configuration: configuration)
        var rows: [[NSView]] = []
        var ids: [String] = []
        for (i, e) in entries.enumerated() {
            let id = "\(key)#\(i)"
            let open = expandedInfoEntries.contains(id)
            let disclosure = NSButton(title: (open ? "\u{25BE} " : "\u{25B8} ") + ProjectEditorModel.infoTypeEntryName(e, key: key),
                                      target: self, action: #selector(infoEntryDisclosureClicked(_:)))
            disclosure.isBordered = false
            disclosure.identifier = .init(id)
            rows.append([disclosure, NSTextField.cell(e.typeName), NSTextField.cell(e.summary)])
            ids.append(String(i))
            if open, case .dictionary(let d) = e {
                for c in d {
                    rows.append([NSTextField.cell("    " + ProjectEditorModel.readableKey(c.key)), NSTextField.cell(c.value.typeName),
                                 NSTextField.cell(c.value.summary)])
                    ids.append(String(i))
                }
            }
        }
        let body = table(title, columns: ["Key", "Type", "Value"], rows: rows, empty: "No \(title)",
                         plus: #selector(infoTypePlusClicked(_:)), minus: #selector(infoTypeMinusClicked(_:)), width: 640)
        tables[title]?.identifier = key
        tables[title]?.itemIDs = ids
        tables[title]?.plusButton?.identifier = .init(key)
        tables[title]?.minusButton?.identifier = .init(key)
        return body
    }

    /// Expands or collapses one entry row of a type section.
    public func toggleInfoEntry(_ key: String, index: Int) {
        let id = "\(key)#\(index)"
        if expandedInfoEntries.contains(id) { expandedInfoEntries.remove(id) } else { expandedInfoEntries.insert(id) }
        showTab()
    }

    /// "+": adds an entry to a type section.
    public func addInfoTypeEntry(_ key: String) {
        guard let t = selectedTarget else { return }
        try? model.addInfoTypeEntry(key, target: t, configuration: configuration)
        onChange?(model.proj)
        showTab()
    }

    /// "−": removes an entry (the selected one, else the last).
    public func removeInfoTypeEntry(_ key: String, at index: Int? = nil) {
        guard let t = selectedTarget else { return }
        let n = model.infoTypeEntries(key, target: t, configuration: configuration).count
        guard let i = index ?? (n > 0 ? n - 1 : nil) else { return }
        expandedInfoEntries = expandedInfoEntries.filter { !$0.hasPrefix(key + "#") }
        try? model.removeInfoTypeEntry(key, at: i, target: t, configuration: configuration)
        onChange?(model.proj)
        showTab()
    }

    @objc func infoEntryDisclosureClicked(_ b: NSButton) {
        let parts = (b.identifier?.rawValue ?? "").split(separator: "#").map(String.init)
        guard parts.count == 2, let i = Int(parts[1]) else { return }
        toggleInfoEntry(parts[0], index: i)
    }

    @objc func infoTypePlusClicked(_ b: NSButton) { if let k = b.identifier?.rawValue { addInfoTypeEntry(k) } }

    @objc func infoTypeMinusClicked(_ b: NSButton) {
        guard let k = b.identifier?.rawValue,
              let t = tables.values.first(where: { $0.identifier == k }) else { return }
        let row = t.table.selectedRow
        removeInfoTypeEntry(k, at: row >= 0 && row < t.itemIDs.count ? Int(t.itemIDs[row]) : nil)
    }
}
