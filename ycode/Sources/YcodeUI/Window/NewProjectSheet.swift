import AppKit
import YcodeIDECore
import YcodeProject

/// The New Project sheet (`reference-ui-3.md` §5.4, `templates.md` §
/// "Template chooser", § "Options step"): platform tabs, a filter, the
/// sectioned icon grid with sticky headers and the template's summary,
/// then "Choose options for your new project:" built from the template's
/// fields. The same sheet is the Package… chooser. The steps, selection,
/// memory and options live in `NewProjectFlowModel`.
@MainActor
public final class NewProjectSheetController: TemplateChooserController {
    public private(set) var flow: NewProjectFlowModel
    let defaults: UserDefaults
    /// The options step's Next: the template, its options and the team.
    public var onFinish: ((ProjectTemplateDescriptor, TemplateOptionsForm, String) -> Void)?
    /// The template's summary (or why it is unavailable) below the grid.
    public let captionLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var grid: TemplateGridView?
    /// The options step's controls and labels, by option identifier.
    public private(set) var fieldControls: [String: NSView] = [:]
    public private(set) var fieldLabels: [String: NSTextField] = [:]
    private var shownFields: [String] = []

    public init(defaults: UserDefaults, chooser: NewProjectFlowModel.Chooser = .project) {
        self.defaults = defaults
        let flow = NewProjectFlowModel(defaults: defaults, chooser: chooser)
        self.flow = flow
        let catalog = chooser == .project ? ProjectTemplates.projects : ProjectTemplates.packages
        super.init(heading: chooser == .project ? ProjectTemplateCatalog.heading : "Choose a template for your new package:",
                   platforms: catalog.tabs, platform: flow.platform, catalog: { p, f in catalog.sections(platform: p, filter: f) })
        if let s = flow.selected { _ = super.select(title: s.title) }
    }

    /// The steps (index 1 = options), for callers that count them.
    public var steps: TemplateSheetSteps {
        var s = TemplateSheetSteps(count: 2)
        if flow.step == .options { s.next() }
        return s
    }

    /// The options as the iOS App's typed options.
    public var options: ProjectOptions {
        get { ProjectOptions(form: flow.form) }
        set {
            flow.apply(newValue)
            if isViewLoaded, flow.step == .options { loadFieldValues() }
            refreshOptions()
        }
    }

    public var selectedTemplate: ProjectTemplateDescriptor? { flow.selected }

    // MARK: Template step

    public override func setPlatform(_ p: String) {
        flow.setPlatform(p)
        super.setPlatform(p)
        syncSelection()
    }

    public override func setFilter(_ f: String) {
        flow.setFilter(f)
        super.setFilter(f)
        syncSelection()
    }

    @discardableResult
    public override func select(title: String) -> Bool {
        guard flow.select(title) else { return false }
        if flow.platform != platform { super.setPlatform(flow.platform) }
        syncSelection()
        return true
    }

    /// Selects by template identifier ("ios.game").
    @discardableResult
    public func select(templateID: String) -> Bool {
        guard flow.select(templateID) else { return false }
        if flow.platform != platform { super.setPlatform(flow.platform) }
        syncSelection()
        return true
    }

    private func syncSelection() {
        if let s = flow.selected, selectedEntry?.title != s.title { _ = super.select(title: s.title) }
        grid?.highlight(selectedEntry)
        captionLabel.stringValue = flow.templateCaption
        captionLabel.textColor = flow.selected?.isAvailable == false ? .systemOrange : .secondaryLabelColor
        updateButtons()
    }

    override func reload() {
        super.reload()
        grid?.show(sections, selected: selectedEntry)
    }

    override func updateButtons() {
        previousButton.isEnabled = flow.isPreviousEnabled
        nextButton.isEnabled = flow.isNextEnabled
    }

    override func initialBody() -> NSView {
        let body = templateBody()
        return flow.step == .template ? body : optionsView()
    }

    func templateBody() -> NSView {
        let top = NSStackView(views: [platformControl, filterField])
        let g = TemplateGridView(top: top)
        g.onSelect = { [weak self] e in _ = self?.select(templateID: e.templateID) }
        g.onChoose = { [weak self] e in
            guard let self, self.select(templateID: e.templateID) else { return }
            self.nextClicked()
        }
        grid = g
        g.show(sections, selected: selectedEntry)
        captionLabel.font = .systemFont(ofSize: 12)
        captionLabel.stringValue = flow.templateCaption
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        let stack = NSStackView(views: [g, captionLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        g.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        captionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        chooserView = stack
        return stack
    }

    public override func nextClicked() {
        if isViewLoaded, flow.step == .options { readFields() }
        let wasTemplate = flow.step == .template
        let save = flow.next()
        if wasTemplate, flow.step == .options {
            if isViewLoaded { show(optionsView()) }
            updateButtons()
            return
        }
        guard save, let d = flow.selected else { return }
        flow.remember(in: defaults)
        onFinish?(d, flow.form, flow.team)
    }

    public override func previousClicked() {
        guard flow.isPreviousEnabled else { return }
        if isViewLoaded { readFields() }
        flow.previous()
        titleLabel.stringValue = heading
        if isViewLoaded { show(chooserView) }
        syncSelection()
    }

    /// Opens the options step of a template directly (picker rows).
    public func jump(to templateID: String) {
        flow.jump(to: templateID)
        if flow.platform != platform { super.setPlatform(flow.platform) }
        if let s = flow.selected { _ = super.select(title: s.title) }
        if isViewLoaded { show(flow.step == .options ? optionsView() : chooserView) }
        updateButtons()
    }

    // MARK: Options step

    /// Sets an option as the controls do, and refreshes the step.
    public func setOption(_ id: String, _ value: String) {
        flow.setOption(id, value)
        if isViewLoaded { loadFieldValues() }
        refreshOptions()
    }

    /// The label column's width; controls follow it 8 points later.
    public static let labelColumnWidth: CGFloat = 170
    /// Text fields' width.
    public static let fieldWidth: CGFloat = 300
    public static let rowSpacing: CGFloat = 10

    func optionsView() -> NSView {
        fieldControls = [:]
        fieldLabels = [:]
        var rows: [[NSView]] = []
        let fields = flow.form.visibleFields
        shownFields = fields.map(\.id)
        for f in fields {
            let label = NSTextField(labelWithString: f.kind == .checkbox ? "" : f.label + ":")
            label.alignment = .right
            fieldLabels[f.id] = label
            let control: NSView
            switch f.kind {
            case .text:
                let t = NSTextField(string: f.id == TemplateOptionID.team ? flow.team : flow.form.value(f.id))
                t.placeholderString = f.placeholder
                t.delegate = self
                t.target = self
                t.action = #selector(optionChanged(_:))
                t.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
                t.setAccessibilityLabel(f.label)
                control = t
            case .popUp(let choices):
                let p = NSPopUpButton()
                p.autoenablesItems = false
                for c in choices {
                    let item = NSMenuItem(title: c.title, action: nil, keyEquivalent: "")
                    item.representedObject = c.value
                    if let why = c.unavailableReason { item.toolTip = why }
                    p.menu?.addItem(item)
                }
                p.target = self
                p.action = #selector(optionChanged(_:))
                p.setAccessibilityLabel(f.label)
                control = p
            case .checkbox:
                control = NSButton(checkboxWithTitle: f.label, target: self, action: #selector(optionChanged(_:)))
            case .derived:
                let l = NSTextField(labelWithString: flow.form.value(f.id))
                l.lineBreakMode = .byTruncatingMiddle
                l.widthAnchor.constraint(lessThanOrEqualToConstant: Self.fieldWidth).isActive = true
                l.setAccessibilityLabel(f.label)
                control = l
            }
            control.identifier = NSUserInterfaceItemIdentifier(f.id)
            fieldControls[f.id] = control
            rows.append([label, control])
        }
        let g = NSGridView(views: rows)
        g.column(at: 0).xPlacement = .trailing
        g.column(at: 0).width = Self.labelColumnWidth
        g.rowSpacing = Self.rowSpacing
        g.columnSpacing = 8
        for i in 0..<g.numberOfRows { g.row(at: i).yPlacement = .center }
        // The sheet's heading becomes the options step's.
        titleLabel.stringValue = NewProjectFlowModel.optionsHeading
        let stack = NSStackView(views: [g])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 0, bottom: 0, right: 0)
        let wrap = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: wrap.topAnchor), stack.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: wrap.bottomAnchor),
        ])
        loadFieldValues()
        refreshOptions()
        return wrap
    }

    /// Copies the controls' values into the form.
    public func readFields() {
        for id in shownFields {
            guard let v = fieldControls[id] else { continue }
            switch v {
            case let b as NSButton where flow.form.field(id)?.kind == .checkbox: flow.setOption(id, b.state == .on ? "true" : "false")
            case let p as NSPopUpButton:
                if let value = p.selectedItem?.representedObject as? String ?? p.titleOfSelectedItem { flow.setOption(id, value) }
            case let t as NSTextField where t.isEditable: flow.setOption(id, t.stringValue)
            default: break
            }
        }
        loadFieldValues()
        refreshOptions()
    }

    func loadFieldValues() {
        for (id, v) in fieldControls {
            let value = id == TemplateOptionID.team ? flow.team : flow.form.value(id)
            switch v {
            case let b as NSButton where flow.form.field(id)?.kind == .checkbox: b.state = flow.form.bool(id) ? .on : .off
            case let p as NSPopUpButton:
                if let i = p.itemArray.firstIndex(where: { ($0.representedObject as? String) == value }) { p.selectItem(at: i) }
            case let t as NSTextField where t.isEditable: if t.stringValue != value { t.stringValue = value }
            default: break
            }
        }
    }

    /// The derived bundle identifier, enabled states, allowed values and Next.
    func refreshOptions() {
        for (id, v) in fieldControls {
            if flow.form.field(id)?.kind == .derived, let l = v as? NSTextField {
                l.stringValue = flow.form.value(id)
                l.textColor = flow.form.isBundleIdentifierPlaceholder ? .tertiaryLabelColor : .secondaryLabelColor
                continue
            }
            let enabled = id == TemplateOptionID.team || flow.form.isEnabled(id)
            (v as? NSControl)?.isEnabled = enabled
            if let p = v as? NSPopUpButton {
                for item in p.itemArray { item.isEnabled = (item.representedObject as? String).map { flow.form.isAllowed(id, $0) } ?? true }
            }
            fieldLabels[id]?.textColor = enabled ? .labelColor : .disabledControlTextColor
        }
        updateButtons()
    }

    @objc func optionChanged(_ sender: Any?) { readFields() }
}

extension NewProjectSheetController: NSTextFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        guard let t = obj.object as? NSTextField, let id = t.identifier?.rawValue else { return }
        flow.setOption(id, t.stringValue)
        refreshOptions()
    }
}

/// The save panel's accessory (`templates.md` § Save step): Source Control
/// (Create Git repository), Add to (an open project or workspace), Group,
/// and for a project the new-workspace choice.
@MainActor
public final class NewProjectSaveAccessory: NSObject {
    public let gitBox = NSButton(checkboxWithTitle: "Create Git repository on my Mac", target: nil, action: nil)
    public let addToPopUp = NSPopUpButton()
    public let groupPopUp = NSPopUpButton()
    public let newWorkspaceBox = NSButton(checkboxWithTitle: "Save both projects in a new workspace", target: nil, action: nil)
    /// The open containers offered in Add to.
    public let containers: [URL]
    public private(set) var groups: [NewProjectGroupChoice] = []
    public private(set) lazy var view: NSView = makeView()
    public static let dontAdd = "Don't add to any project or workspace"

    /// - Parameter defaultContainer: the workspace the sheet runs on (Add
    ///   to's default), nil in the empty window of Choose Template….
    public init(containers: [URL], createGitRepository: Bool, defaultContainer: URL? = nil) {
        self.containers = containers.filter { ["xcodeproj", "xcworkspace"].contains($0.pathExtension) }
        super.init()
        gitBox.state = createGitRepository ? .on : .off
        gitBox.toolTip = "A local Git repository is created inside the project folder."
        newWorkspaceBox.state = .on
        _ = view
        if let d = defaultContainer, let i = self.containers.firstIndex(of: d) { chooseContainer(i + 2) }
    }

    public var addTo: URL? {
        let i = addToPopUp.indexOfSelectedItem - 2
        return containers.indices.contains(i) ? containers[i] : nil
    }

    public var group: String? {
        let i = groupPopUp.indexOfSelectedItem
        return groups.indices.contains(i) ? groups[i].key : nil
    }

    /// Selects an Add to item (0 = "Don't add…", 1 = the separator).
    public func chooseContainer(_ i: Int) {
        addToPopUp.selectItem(at: i)
        reloadGroups()
    }

    func reloadGroups() {
        groupPopUp.removeAllItems()
        groups = addTo.map { NewProjectCreator.groups(in: $0) } ?? []
        for g in groups {
            let item = NSMenuItem(title: g.title, action: nil, keyEquivalent: "")
            item.indentationLevel = min(g.depth, 15)
            item.image = NSImage(systemSymbolName: g.depth == 0 ? "doc" : "folder", accessibilityDescription: nil)
            groupPopUp.menu?.addItem(item)
        }
        groupPopUp.isEnabled = !groups.isEmpty
        newWorkspaceBox.isEnabled = addTo?.pathExtension == "xcodeproj"
    }

    @objc func addToChosen(_ p: NSPopUpButton) { reloadGroups() }

    public var save: (createGitRepository: Bool, addTo: URL?, group: String?, newWorkspace: Bool) {
        (gitBox.state == .on, addTo, group, newWorkspaceBox.state == .on)
    }

    func makeView() -> NSView {
        addToPopUp.removeAllItems()
        addToPopUp.addItem(withTitle: Self.dontAdd)
        addToPopUp.menu?.addItem(.separator())
        for c in containers { addToPopUp.menu?.addItem(NSMenuItem(title: c.lastPathComponent, action: nil, keyEquivalent: "")) }
        addToPopUp.target = self
        addToPopUp.action = #selector(addToChosen(_:))
        reloadGroups()
        let rows: [[NSView]] = [[NSTextField(labelWithString: "Source Control:"), gitBox],
                                [NSTextField(labelWithString: "Add to:"), addToPopUp],
                                [NSTextField(labelWithString: "Group:"), groupPopUp],
                                [NSTextField(labelWithString: ""), newWorkspaceBox]]
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        let wrap = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 132))
        grid.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(grid)
        NSLayoutConstraint.activate([grid.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
                                     grid.centerYAnchor.constraint(equalTo: wrap.centerYAnchor)])
        return wrap
    }
}

/// New Project from a compact-picker row or the full sheet
/// (`templates.md` § "Compact picker rows"). Used by File ▸ New ▸
/// Project… and the Welcome window's pull-down.
@MainActor
enum NewProjectFlow {
    /// The open projects and workspaces, for the save step's Add to.
    static func openContainers() -> [URL] {
        NSApp.windows.compactMap { ($0.windowController as? WorkspaceWindowController)?.session.model }
            .filter { $0.kind != .package }.map(\.url)
    }

    /// The save panel's starting folder: the last one used, else the
    /// user's Developer folder, else the home folder.
    static func startFolder(_ defaults: UserDefaults, fallback: URL) -> URL {
        if let u = defaults.url(forKey: NewProjectFlowModel.saveFolderKey) { return u }
        let dev = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : fallback
    }

    /// - Parameters:
    ///   - row: a compact-picker row (nil: the full sheet).
    ///   - interactive: present the sheet in its own window and ask where
    ///     to save; otherwise (tests, headless) create in `location` with
    ///     `headlessSave`'s choices.
    ///   - workspace: the container of the window the sheet runs on (Add
    ///     to's default).
    static func start(row: Int?, defaults: UserDefaults, location: URL, parent: NSWindow?, interactive: Bool,
                      headlessSave: NewProjectSaveOptions? = nil, workspace: URL? = nil,
                      onCreated: @escaping (NewProjectCreator.Created) -> Void, onError: @escaping (String) -> Void) -> NewProjectSheetController {
        if let row { NewProjectPicker.remember(row: row, in: defaults) }
        let sheet = NewProjectSheetController(defaults: defaults, chooser: row == 2 ? .package : .project)
        if let row, let id = NewProjectPicker.templateID(forRow: row) { sheet.jump(to: id) }
        var host: NSWindow?
        var hostController: WorkspaceWindowController?
        sheet.onCancel = { host?.close(); hostController = nil }
        sheet.onFinish = { [weak sheet] d, form, team in
            let done: (NewProjectCreator.Created) -> Void = { created in
                if let w = created.gitWarning { onError(w) }
                let frame = host?.frame
                sheet?.dismiss(nil); host?.close(); hostController = nil
                onCreated(created)
                if let frame, created.addedTo == nil { open(created, frame: frame) }
            }
            guard interactive, let w = host ?? parent, w.isVisible else {
                var save = headlessSave ?? NewProjectSaveOptions(location: location, createGitRepository: false)
                save.location = location
                save.team = team
                do { done(try NewProjectCreator.create(d, form, save: save)) } catch { onError("\(error)") }
                return
            }
            let panel = NSSavePanel()
            panel.prompt = "Create"
            panel.canCreateDirectories = true
            panel.nameFieldLabel = "Save As:"
            panel.nameFieldStringValue = sheet?.flow.defaultSaveName ?? form.productName
            panel.directoryURL = startFolder(defaults, fallback: location)
            let git = defaults.object(forKey: NewProjectFlowModel.gitKey) as? Bool ?? true
            let accessory = NewProjectSaveAccessory(containers: openContainers(), createGitRepository: git, defaultContainer: host == nil ? workspace : nil)
            panel.accessoryView = accessory.view
            panel.beginSheetModal(for: w) { r in
                // Cancel returns to the options step.
                guard r == .OK, let url = panel.url else { return }
                let o = accessory.save
                var save = NewProjectSaveOptions(location: url.deletingLastPathComponent(), saveAs: url.lastPathComponent,
                                                 createGitRepository: o.createGitRepository, addTo: o.addTo, group: o.group)
                save.newWorkspaceForProject = o.newWorkspace
                save.team = team
                defaults.set(save.location, forKey: NewProjectFlowModel.saveFolderKey)
                defaults.set(o.createGitRepository, forKey: NewProjectFlowModel.gitKey)
                // The confirmed save panel may name an existing folder: the
                // user agreed to replace it, so it is moved to the Trash.
                let target = url
                if FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.trashItem(at: target, resultingItemURL: nil) }
                let work = Task.detached { try NewProjectCreator.create(d, form, save: save) }
                Task { @MainActor in
                    do { done(try await work.value) } catch { onError("\(error)") }
                }
            }
        }
        if interactive {
            // A real, empty workspace window behind the sheet (§11.3).
            let wc = emptyWorkspaceWindow()
            hostController = wc
            wc.showWindow(nil)
            host = wc.window
            wc.contentViewController?.presentAsSheet(sheet)
        }
        return sheet
    }

    /// Opens a created project on its initial file, in a window where the
    /// sheet's window was.
    static func open(_ created: NewProjectCreator.Created, frame: NSRect? = nil) {
        NSDocumentController.shared.openDocument(withContentsOf: created.openURL, display: true) { doc, _, _ in
            MainActor.assumeIsolated {
                for wc in doc?.windowControllers ?? [] {
                    if let frame { wc.window?.setFrame(frame, display: true) }
                    if let entry = created.entryFile { (wc as? WorkspaceWindowController)?.open(path: entry.path, line: nil) }
                }
            }
        }
    }

    /// Shows `entry` in the window of the container at `url`, once open.
    static func openEntry(_ entry: URL, of url: URL) {
        let wc = NSApp.windows.compactMap { $0.windowController as? WorkspaceWindowController }
            .first { $0.session.model.url.standardizedFileURL == url.standardizedFileURL }
        wc?.open(path: entry.path, line: nil)
    }
}
