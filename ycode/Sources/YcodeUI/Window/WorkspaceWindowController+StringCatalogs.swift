import AppKit
import YcodeIDECore

/// Edit ▸ Convert ▸ To String Catalogs…: a sheet lists the project's
/// `.strings`/`.stringsdict` tables with a checkbox each (all on); Convert
/// turns the checked ones into String Catalogs (undoable). See
/// `specs/ide/string-catalog.md`, "Ycode implementation".
extension WorkspaceWindowController {
    /// The project the command works on: the navigator selection's, else the first.
    var stringCatalogConversionProject: String? { navigatorSelectionItems?.project ?? defaultNavigatorProject }

    /// The tables the command offers.
    public func legacyStringTables() -> [LegacyStringTable] {
        navigatorOperations(stringCatalogConversionProject)?.legacyStringTables() ?? []
    }

    @objc public func convertToStringCatalogs(_ sender: Any?) {
        let tables = legacyStringTables()
        let sheet = StringCatalogConversionController(tables: tables, projectDirectory: navigatorOperations(stringCatalogConversionProject)?.rootDirectory.path ?? "")
        sheet.onConvert = { [weak self] chosen in _ = self?.convertToStringCatalogs(tables: chosen) }
        pendingStringCatalogConversion = sheet
        guard let window, window.isVisible else { return }
        let panel = NSWindow(contentViewController: sheet)
        panel.title = "Convert to String Catalogs"
        sheet.onClose = { [weak window, weak panel] in if let panel { window?.endSheet(panel) } }
        window.beginSheet(panel)
    }

    /// Converts `tables` of the command's project; nil when it fails (the
    /// error is reported).
    @discardableResult
    public func convertToStringCatalogs(tables: [LegacyStringTable]) -> ProjectEdit? {
        pendingStringCatalogConversion = nil
        return performNavigatorEdit(stringCatalogConversionProject) { try $0.convertToStringCatalogs(tables) }
    }

    /// The sheet the last Convert to String Catalogs… opened (also when the
    /// window is not on screen, as in tests).
    public internal(set) var pendingStringCatalogConversion: StringCatalogConversionController? {
        get { objc_getAssociatedObject(self, &StringCatalogConversionController.key) as? StringCatalogConversionController }
        set { objc_setAssociatedObject(self, &StringCatalogConversionController.key, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// The sources "Refresh from source" reads for a catalog: those of the
    /// targets that hold it (empty: the editor reads its folder).
    func stringCatalogSourceFiles(forCatalogAt path: String) -> [String] {
        let paths = session.model.projects.keys.sorted()
        guard let project = paths.first(where: { path.hasPrefix(URL(fileURLWithPath: $0).deletingLastPathComponent().path + "/") }),
              let proj = session.model.projects[project] else { return [] }
        return proj.localizableSourceFiles(forResourceAt: path, projectDirectory: proj.projectDirectory(xcodeprojURL: URL(fileURLWithPath: project)))
    }

    /// Enablement: a project with at least one table.
    func validateStringCatalogConversion(_ item: NSMenuItem) -> Bool? {
        guard item.action == #selector(convertToStringCatalogs(_:)) else { return nil }
        return session.model.kind != .package && !legacyStringTables().isEmpty
    }
}

/// The Convert to String Catalogs sheet: one row per table (checkbox,
/// name, folder, languages, targets), Cancel and Convert.
@MainActor
public final class StringCatalogConversionController: NSViewController {
    nonisolated(unsafe) static var key: UInt8 = 0

    public let tables: [LegacyStringTable]
    let projectDirectory: String
    /// The tables checked (their IDs); all at first.
    public var checked: Set<String>
    var onConvert: (([LegacyStringTable]) -> Void)?
    var onClose: (() -> Void)?
    public private(set) var checkboxes: [NSButton] = []
    public private(set) var convertButton: NSButton?

    init(tables: [LegacyStringTable], projectDirectory: String) {
        self.tables = tables
        self.projectDirectory = projectDirectory
        checked = Set(tables.map(\.id))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A row's title: `Localizable` in `App/` (de, en) — targets.
    public func title(_ t: LegacyStringTable) -> String {
        var folder = t.directory
        if folder.hasPrefix(projectDirectory + "/") { folder = String(folder.dropFirst(projectDirectory.count + 1)) } else if folder == projectDirectory { folder = "" }
        let place = folder.isEmpty ? "" : " in \(folder)"
        return "\(t.name)\(place) (\(t.languages.joined(separator: ", ")))" + (t.targetNames.isEmpty ? "" : " — \(t.targetNames.joined(separator: ", "))")
    }

    public override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        let heading = NSTextField(labelWithString: tables.isEmpty ? "This project has no .strings or .stringsdict tables."
                                                                  : "Choose the string tables to convert to String Catalogs.")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        stack.addArrangedSubview(heading)
        let note = NSTextField(wrappingLabelWithString: "Each table becomes one .xcstrings file in the same targets. The .strings and .stringsdict files move to the Trash.")
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 460
        stack.addArrangedSubview(note)
        checkboxes = tables.enumerated().map { i, t in
            let b = NSButton(checkboxWithTitle: title(t), target: self, action: #selector(toggled(_:)))
            b.tag = i
            b.state = checked.contains(t.id) ? .on : .off
            stack.addArrangedSubview(b)
            return b
        }
        let buttons = NSStackView()
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let convert = NSButton(title: "Convert", target: self, action: #selector(convertClicked))
        convert.keyEquivalent = "\r"
        convertButton = convert
        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(convert)
        stack.addArrangedSubview(buttons)
        stack.setFrameSize(NSSize(width: 500, height: 160 + 24 * tables.count))
        view = stack
        updateButtons()
    }

    func updateButtons() { convertButton?.isEnabled = !checked.isEmpty }

    @objc func toggled(_ sender: NSButton) {
        let id = tables[sender.tag].id
        if sender.state == .on { checked.insert(id) } else { checked.remove(id) }
        updateButtons()
    }

    /// Unchecks or checks a table (tests and the checkboxes).
    public func setChecked(_ on: Bool, table id: String) {
        if on { checked.insert(id) } else { checked.remove(id) }
        if let i = tables.firstIndex(where: { $0.id == id }), i < checkboxes.count { checkboxes[i].state = on ? .on : .off }
        updateButtons()
    }

    @objc func cancelClicked() { onClose?() }

    /// Converts the checked tables and closes the sheet.
    @objc public func convertClicked() {
        let chosen = tables.filter { checked.contains($0.id) }
        onClose?()
        guard !chosen.isEmpty else { return }
        onConvert?(chosen)
    }
}
