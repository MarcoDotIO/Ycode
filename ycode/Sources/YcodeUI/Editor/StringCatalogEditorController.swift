import AppKit

/// The String Catalog editor: a languages sidebar (with progress), and a
/// Key | Default Localization | Comment | <language> | State table. Edits
/// are written to the file at once. See `specs/ide/string-catalog.md`.
@MainActor
public final class StringCatalogEditorController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    public let url: URL
    public private(set) var catalog: StringCatalog
    public private(set) var language: String
    public private(set) var rows: [StringCatalog.Row] = []
    let sidebar = NSTableView()
    let table = NSTableView()
    public let addLanguagePopUp = NSPopUpButton(frame: .zero, pullsDown: true)

    /// Languages offered by + (codes); the menu shows their localized names.
    public static let commonLanguages = ["ar", "de", "es", "fr", "hi", "it", "ja", "ko", "nl", "pl", "pt-BR", "ru", "sv", "tr", "uk", "zh-Hans", "zh-Hant"]

    public init(url: URL) throws {
        self.url = url
        catalog = try StringCatalog(data: Data(contentsOf: url))
        language = catalog.sourceLanguage
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public static func displayName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
    }

    public override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let sc = NSTableColumn(identifier: .init("lang"))
        sidebar.addTableColumn(sc)
        sidebar.headerView = nil
        sidebar.rowHeight = 22
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.style = .plain
        sidebar.backgroundColor = .clear
        for (id, title, w) in [("key", "Key", 150.0), ("default", "Default Localization", 160.0), ("comment", "Comment", 140.0),
                               ("translation", "Translation", 170.0), ("state", "State", 90.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = w
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowSizeStyle = .small
        let sideScroll = NSScrollView(), mainScroll = NSScrollView()
        sideScroll.documentView = sidebar
        mainScroll.documentView = table
        for s in [sideScroll, mainScroll] { s.hasVerticalScroller = true; s.drawsBackground = false }
        addLanguagePopUp.addItem(withTitle: "")
        addLanguagePopUp.item(at: 0)?.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add language")
        for code in Self.commonLanguages {
            addLanguagePopUp.addItem(withTitle: "\(Self.displayName(code)) (\(code))")
            addLanguagePopUp.lastItem?.representedObject = code
        }
        addLanguagePopUp.target = self
        addLanguagePopUp.action = #selector(languageChosen)
        addLanguagePopUp.bezelStyle = .smallSquare
        let addKey = NSButton(title: "Add Key", target: self, action: #selector(addKeyClicked))
        addKey.bezelStyle = .smallSquare
        let sep = NSBox()
        sep.boxType = .separator
        for v in [sideScroll, mainScroll, addLanguagePopUp, addKey, sep] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            sideScroll.topAnchor.constraint(equalTo: root.topAnchor), sideScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sideScroll.widthAnchor.constraint(equalToConstant: 190), sideScroll.bottomAnchor.constraint(equalTo: addLanguagePopUp.topAnchor, constant: -4),
            addLanguagePopUp.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            addLanguagePopUp.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4), addLanguagePopUp.widthAnchor.constraint(equalToConstant: 44),
            sep.topAnchor.constraint(equalTo: root.topAnchor), sep.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sep.leadingAnchor.constraint(equalTo: sideScroll.trailingAnchor),
            mainScroll.topAnchor.constraint(equalTo: root.topAnchor), mainScroll.leadingAnchor.constraint(equalTo: sep.trailingAnchor),
            mainScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), mainScroll.bottomAnchor.constraint(equalTo: addKey.topAnchor, constant: -4),
            addKey.leadingAnchor.constraint(equalTo: sep.trailingAnchor, constant: 6), addKey.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
        ])
        view = root
        reload()
    }

    func reload() {
        rows = catalog.rows(language: language)
        guard isViewLoaded else { return }
        sidebar.reloadData()
        if let i = catalog.languages.firstIndex(of: language) { sidebar.selectRowIndexes([i], byExtendingSelection: false) }
        table.tableColumn(withIdentifier: .init("translation"))?.title = Self.displayName(language)
        table.tableColumn(withIdentifier: .init("translation"))?.isHidden = language == catalog.sourceLanguage
        table.reloadData()
    }

    func save() {
        try? catalog.data().write(to: url, options: .atomic)
    }

    // MARK: Editing API (also used by tests)

    public func select(language code: String) {
        language = code
        reload()
    }

    /// Called when a language is added (the window adds it to the project).
    public var onAddLanguage: ((String) -> Void)?

    public func addLanguage(_ code: String) {
        catalog.addLanguage(code)
        onAddLanguage?(code)
        select(language: code)
    }

    public func setTranslation(_ value: String, key: String) {
        catalog.setTranslation(value, key: key, language: language)
        save()
        reload()
    }

    public func setComment(_ value: String, key: String) {
        catalog.setComment(value, key: key)
        save()
        reload()
    }

    public func markNeedsReview(key: String) {
        catalog.setState(.needsReview, key: key, language: language)
        save()
        reload()
    }

    public func addKey(_ key: String) {
        catalog.addKey(key)
        save()
        reload()
    }

    @objc private func languageChosen() {
        if let code = addLanguagePopUp.selectedItem?.representedObject as? String { addLanguage(code) }
    }

    @objc private func addKeyClicked() {
        var n = 1
        while catalog.keys.contains("New Key \(n)") { n += 1 }
        addKey("New Key \(n)")
    }

    // MARK: Tables

    public func numberOfRows(in t: NSTableView) -> Int { t === sidebar ? catalog.languages.count : rows.count }

    public func tableViewSelectionDidChange(_ n: Notification) {
        guard (n.object as? NSTableView) === sidebar, sidebar.selectedRow >= 0 else { return }
        let code = catalog.languages[sidebar.selectedRow]
        if code != language { select(language: code) }
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

    public func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        if t === sidebar {
            let code = catalog.languages[row]
            let suffix = code == catalog.sourceLanguage ? "  (Source)" : "  \(catalog.progress(language: code))%"
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: Self.displayName(code) + suffix)
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                                         label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        let r = rows[row]
        let id = c?.identifier.rawValue ?? ""
        let text: String = switch id {
        case "key": r.key
        case "default": r.defaultValue
        case "comment": r.comment
        case "translation": r.variations.isEmpty ? r.translation : r.variations.joined(separator: "; ")
        default: Self.stateTitle(r.state)
        }
        let f = NSTextField(string: text)
        f.isBordered = false
        f.drawsBackground = false
        f.lineBreakMode = .byTruncatingTail
        let editable = (id == "comment") || (id == "translation" && r.variations.isEmpty && r.state != .dontTranslate)
        f.isEditable = editable
        f.isSelectable = true
        f.identifier = .init("\(id)#\(row)")
        f.delegate = self
        if id == "state" {
            f.textColor = switch r.state {
            case .translated, .variesByPlural: .systemGreen
            case .needsReview, .stale: .systemOrange
            case .new: .systemRed
            case .dontTranslate: .secondaryLabelColor
            }
        }
        if !r.variations.isEmpty && id == "translation" { f.textColor = .secondaryLabelColor }
        return f
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, let ident = f.identifier?.rawValue,
              let hash = ident.firstIndex(of: "#"), let row = Int(ident[ident.index(after: hash)...]), row < rows.count else { return }
        let key = rows[row].key
        switch ident[..<hash] {
        case "comment" where f.stringValue != rows[row].comment: setComment(f.stringValue, key: key)
        case "translation" where f.stringValue != rows[row].translation: setTranslation(f.stringValue, key: key)
        default: break
        }
    }
}
