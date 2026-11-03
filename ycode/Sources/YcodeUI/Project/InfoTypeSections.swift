import AppKit
import YcodeIDECore
import YcodePlist
import YcodeProject

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
