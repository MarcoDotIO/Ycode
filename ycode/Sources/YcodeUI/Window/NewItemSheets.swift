import AppKit
import YcodeProject

/// A template chooser: platform tabs, a filter field, a sectioned list with
/// floating section headers, and Cancel / Previous / Next
/// (`specs/ide/reference-ui-3.md` §5.3, §5.4).
@MainActor
public class TemplateChooserController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public let heading: String
    public let platforms: [String]
    let catalog: (String, String) -> [TemplateSection]
    public private(set) var platform: String
    public private(set) var filter = ""
    public private(set) var sections: [TemplateSection] = []
    /// Flattened rows: a section header (`nil` entry) or an entry.
    private(set) var rows: [(section: String, entry: TemplateEntry?)] = []
    public private(set) var selectedEntry: TemplateEntry?
    public var onCancel: (() -> Void)?
    public var onNext: ((TemplateEntry) -> Void)?
    let table = NSTableView()
    public let platformControl = NSSegmentedControl()
    public let filterField = NSSearchField()
    public let previousButton = NSButton(title: "Previous", target: nil, action: nil)
    public let nextButton = NSButton(title: "Next", target: nil, action: nil)
    /// The area below the heading; subclasses swap it for later steps.
    let body = NSView()
    var chooserView = NSView()

    public init(heading: String, platforms: [String], platform: String, catalog: @escaping (String, String) -> [TemplateSection]) {
        self.heading = heading
        self.platforms = platforms
        self.platform = platform
        self.catalog = catalog
        super.init(nibName: nil, bundle: nil)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public func setPlatform(_ p: String) {
        guard platforms.contains(p) else { return }
        platform = p
        platformControl.selectedSegment = platforms.firstIndex(of: p) ?? 0
        reload()
    }

    public func setFilter(_ f: String) {
        filter = f
        reload()
    }

    /// Selects the first entry titled `title` (after a filter change, the
    /// first entry).
    @discardableResult
    public func select(title: String) -> Bool {
        guard let i = rows.firstIndex(where: { $0.entry?.title == title }) else { return false }
        selectedEntry = rows[i].entry
        if isViewLoaded { table.selectRowIndexes([i], byExtendingSelection: false) }
        updateButtons()
        return true
    }

    func reload() {
        sections = catalog(platform, filter)
        rows = sections.flatMap { s in [(s.title, nil)] + s.entries.map { (s.title, $0) } }
        if let sel = selectedEntry, rows.contains(where: { $0.entry == sel }) {
            if isViewLoaded { table.reloadData(); select(title: sel.title) }
        } else {
            selectedEntry = rows.first { $0.entry != nil }?.entry
            if isViewLoaded {
                table.reloadData()
                if let i = rows.firstIndex(where: { $0.entry == selectedEntry }) { table.selectRowIndexes([i], byExtendingSelection: false) }
            }
        }
        updateButtons()
    }

    func updateButtons() {
        previousButton.isEnabled = false
        nextButton.isEnabled = selectedEntry != nil
    }

    public override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        let title = NSTextField(labelWithString: heading)
        title.font = .boldSystemFont(ofSize: 13)
        platformControl.segmentCount = platforms.count
        for (i, p) in platforms.enumerated() { platformControl.setLabel(p, forSegment: i) }
        platformControl.selectedSegment = platforms.firstIndex(of: platform) ?? 0
        platformControl.target = self
        platformControl.action = #selector(platformChosen(_:))
        filterField.placeholderString = "Filter"
        filterField.target = self
        filterField.action = #selector(filterChanged(_:))
        filterField.sendsSearchStringImmediately = true
        table.addTableColumn(NSTableColumn(identifier: .init("t")))
        table.headerView = nil
        table.rowHeight = 24
        table.floatsGroupRows = true
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let top = NSStackView(views: [platformControl, filterField])
        let chooser = NSStackView(views: [top, scroll])
        chooser.orientation = .vertical
        chooser.alignment = .leading
        scroll.widthAnchor.constraint(equalTo: chooser.widthAnchor).isActive = true
        chooserView = chooser
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        previousButton.target = self
        previousButton.action = #selector(previousClicked)
        nextButton.target = self
        nextButton.action = #selector(nextClicked)
        nextButton.keyEquivalent = "\r"
        for v in [title, body, cancel, previousButton, nextButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            body.bottomAnchor.constraint(equalTo: nextButton.topAnchor, constant: -12),
            nextButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            nextButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            previousButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -8),
            previousButton.bottomAnchor.constraint(equalTo: nextButton.bottomAnchor),
            cancel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            cancel.bottomAnchor.constraint(equalTo: nextButton.bottomAnchor),
        ])
        view = root
        show(initialBody())
        table.reloadData()
        if let i = rows.firstIndex(where: { $0.entry == selectedEntry }) { table.selectRowIndexes([i], byExtendingSelection: false) }
        updateButtons()
    }

    func initialBody() -> NSView { chooserView }

    func show(_ v: NSView) {
        body.subviews.forEach { $0.removeFromSuperview() }
        v.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: body.topAnchor), v.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: body.leadingAnchor), v.trailingAnchor.constraint(equalTo: body.trailingAnchor),
        ])
    }

    @objc func platformChosen(_ c: NSSegmentedControl) { setPlatform(platforms[max(0, c.selectedSegment)]) }
    @objc func filterChanged(_ f: NSSearchField) { setFilter(f.stringValue) }
    @objc public func cancelClicked() {
        onCancel?()
        if presentingViewController != nil { dismiss(nil) }
    }
    @objc public func previousClicked() {}
    @objc public func nextClicked() {
        guard let e = selectedEntry else { return }
        onNext?(e)
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows[row].entry == nil }
    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].entry != nil }
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        guard let e = r.entry else {
            let l = NSTextField(labelWithString: r.section)
            l.font = .boldSystemFont(ofSize: 11)
            return l
        }
        let image = NSImageView(image: NSImage(systemSymbolName: e.symbol, accessibilityDescription: nil) ?? NSImage())
        let label = NSTextField(labelWithString: e.title)
        return NSStackView(views: [image, label])
    }
    public func tableViewSelectionDidChange(_ n: Notification) {
        let r = table.selectedRow
        if r >= 0, let e = rows[r].entry { selectedEntry = e }
        updateButtons()
    }
}

/// The new-file sheet. Next hands the template to the save step.
@MainActor
public final class NewFileSheetController: TemplateChooserController {
    public init(platform: String = "iOS") {
        super.init(heading: FileTemplateCatalog.heading, platforms: FileTemplateCatalog.platforms, platform: platform,
                   catalog: FileTemplateCatalog.sections(platform:filter:))
    }

    /// The icon grid that replaces the base list (reference-ui-3 §5.3).
    private(set) var grid: TemplateGridView?

    override func initialBody() -> NSView {
        let top = NSStackView(views: [platformControl, filterField])
        let g = TemplateGridView(top: top)
        g.onSelect = { [weak self] e in _ = self?.select(title: e.title) }
        g.onChoose = { [weak self] _ in self?.nextClicked() }
        grid = g
        g.show(sections, selected: selectedEntry)
        return g
    }

    override func reload() {
        super.reload()
        grid?.show(sections, selected: selectedEntry)
    }

    @discardableResult
    public override func select(title: String) -> Bool {
        let ok = super.select(title: title)
        grid?.highlight(selectedEntry)
        return ok
    }
}

/// The new-project template sheet, then the options step.
@MainActor
public final class NewProjectSheetController: TemplateChooserController {
    public private(set) var steps = TemplateSheetSteps(count: 2)
    public var options = ProjectOptions()
    /// (platform, template title, options) once the options step's Next.
    public var onFinish: ((String, String, ProjectOptions) -> Void)?
    let defaults: UserDefaults
    public let productNameField = NSTextField(string: "")
    public let organizationField = NSTextField(string: "")
    public let bundleIdentifierLabel = NSTextField(labelWithString: "")
    public let teamPopUp = NSPopUpButton()
    public let interfacePopUp = NSPopUpButton()
    public let languagePopUp = NSPopUpButton()
    public let testingPopUp = NSPopUpButton()
    public let storagePopUp = NSPopUpButton()
    public let cloudKitBox = NSButton(checkboxWithTitle: "Host in CloudKit", target: nil, action: nil)
    let optionsHeading = NSTextField(labelWithString: ProjectOptions.heading)

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        let last = ProjectTemplateCatalog.lastSelection(defaults)
        super.init(heading: ProjectTemplateCatalog.heading, platforms: ProjectTemplateCatalog.platforms, platform: last.platform,
                   catalog: { p, f in
                       let all = ProjectTemplateCatalog.sections(platform: p)
                       guard !f.isEmpty else { return all }
                       return all.compactMap { s in
                           let hits = s.entries.filter { $0.title.localizedCaseInsensitiveContains(f) }
                           return hits.isEmpty ? nil : TemplateSection(title: s.title, entries: hits)
                       }
                   })
        select(title: last.title)
    }

    override func updateButtons() {
        previousButton.isEnabled = steps.isPreviousEnabled
        nextButton.isEnabled = steps.index == 0 ? selectedEntry != nil : options.isNextEnabled
    }

    public override func nextClicked() {
        guard let e = selectedEntry else { return }
        if steps.index == 0 {
            ProjectTemplateCatalog.setLastSelection(platform: platform, title: e.title, defaults)
            steps.next()
            if isViewLoaded { show(optionsView()) }
            updateButtons()
        } else {
            readFields()
            guard options.isNextEnabled else { return }
            onFinish?(platform, e.title, options)
        }
    }

    public override func previousClicked() {
        guard steps.isPreviousEnabled else { return }
        readFields()
        steps.previous()
        if isViewLoaded { show(chooserView) }
        updateButtons()
    }

    /// Copies the option controls into `options` and refreshes the
    /// derived bundle identifier and CloudKit box.
    public func readFields() {
        guard isViewLoaded else { return }
        options.productName = productNameField.stringValue
        options.organizationIdentifier = organizationField.stringValue
        options.interface = ProjectOptions.Interface(rawValue: interfacePopUp.titleOfSelectedItem ?? "") ?? options.interface
        options.testing = ProjectOptions.Testing(rawValue: testingPopUp.titleOfSelectedItem ?? "") ?? options.testing
        options.setStorage(ProjectOptions.Storage(rawValue: storagePopUp.titleOfSelectedItem ?? "") ?? options.storage)
        if options.isCloudKitEnabled { options.hostInCloudKit = cloudKitBox.state == .on }
        refreshDerived()
    }

    func refreshDerived() {
        bundleIdentifierLabel.stringValue = options.bundleIdentifier
        bundleIdentifierLabel.textColor = options.isBundleIdentifierPlaceholder ? .tertiaryLabelColor : .secondaryLabelColor
        cloudKitBox.isEnabled = options.isCloudKitEnabled
        cloudKitBox.state = options.hostInCloudKit ? .on : .off
        updateButtons()
    }

    override func initialBody() -> NSView { steps.index == 0 ? chooserView : optionsView() }

    @objc func optionChanged(_ sender: Any?) { readFields() }

    func optionsView() -> NSView {
        productNameField.stringValue = options.productName
        organizationField.stringValue = options.organizationIdentifier
        for f in [productNameField, organizationField] {
            f.target = self
            f.action = #selector(optionChanged(_:))
            f.delegate = self
            f.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        teamPopUp.removeAllItems(); teamPopUp.addItem(withTitle: options.team)
        languagePopUp.removeAllItems(); languagePopUp.addItem(withTitle: options.language)
        func fill(_ p: NSPopUpButton, _ titles: [String], _ sel: String) {
            p.removeAllItems(); p.addItems(withTitles: titles); p.selectItem(withTitle: sel)
            p.target = self; p.action = #selector(optionChanged(_:))
        }
        fill(interfacePopUp, ProjectOptions.Interface.allCases.map(\.rawValue), options.interface.rawValue)
        fill(testingPopUp, ProjectOptions.Testing.allCases.map(\.rawValue), options.testing.rawValue)
        fill(storagePopUp, ProjectOptions.Storage.allCases.map(\.rawValue), options.storage.rawValue)
        cloudKitBox.target = self
        cloudKitBox.action = #selector(optionChanged(_:))
        let rows: [(String, NSView)] = [("Product Name", productNameField), ("Team", teamPopUp),
                                        ("Organization Identifier", organizationField), ("Bundle Identifier", bundleIdentifierLabel),
                                        ("Interface", interfacePopUp), ("Language", languagePopUp), ("Testing System", testingPopUp),
                                        ("Storage", storagePopUp), ("", cloudKitBox)]
        let grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0.isEmpty ? "" : $0.0 + ":"), $0.1] })
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        optionsHeading.font = .boldSystemFont(ofSize: 13)
        let stack = NSStackView(views: [optionsHeading, grid])
        stack.orientation = .vertical
        stack.alignment = .centerX
        refreshDerived()
        return stack
    }
}

extension NewProjectSheetController: NSTextFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) { readFields() }
}

/// File ▸ New ▸ Project…'s compact picker: "+ New Project" and five rows.
@MainActor
public final class NewProjectPickerController: NSViewController {
    public var onChoose: ((Int) -> Void)?
    /// Vertical gap between the rows.
    public static let rowSpacing: CGFloat = 8
    public private(set) var rowViews: [NSView] = []
    public private(set) var cancelButton: NSButton?

    public override func loadView() {
        let header = NSTextField(labelWithString: "+ " + NewProjectPicker.header)
        header.font = .boldSystemFont(ofSize: 13)
        var views: [NSView] = [header]
        for (i, r) in NewProjectPicker.rows.enumerated() {
            let b = NSButton(title: r.title, target: self, action: #selector(rowClicked(_:)))
            b.tag = i
            b.isBordered = false
            b.font = .systemFont(ofSize: 13, weight: .medium)
            b.setContentHuggingPriority(.required, for: .vertical)
            let sub = NSTextField(labelWithString: r.subtitle)
            sub.textColor = .secondaryLabelColor
            sub.font = .systemFont(ofSize: 11)
            let cell = NSStackView(views: [b, sub])
            cell.orientation = .vertical
            cell.alignment = .leading
            cell.spacing = 1
            cell.setHuggingPriority(.required, for: .vertical)
            views.append(cell)
        }
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPicker))
        cancel.keyEquivalent = "\u{1b}"
        cancelButton = cancel
        rowViews = Array(views.dropFirst())
        // Rows pack at the top; Cancel sits at the bottom.
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.rowSpacing
        for v in views { stack.addView(v, in: .top) }
        stack.addView(cancel, in: .top)
        stack.setCustomSpacing(Self.rowSpacing * 2, after: views.last!)
        // The panel takes the stack's fitting height, so no extra space
        // is handed to any row.
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 340, height: 10))
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        // The panel starts at the stack's fitting height; a taller panel
        // leaves the extra space below the rows.
        stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor).isActive = true
        root.setFrameSize(NSSize(width: 340, height: stack.fittingSize.height))
        preferredContentSize = root.frame.size
        view = root
    }

    @objc func cancelPicker() { if presentingViewController != nil { dismiss(nil) } }
    @objc func rowClicked(_ b: NSButton) { choose(b.tag) }
    public func choose(_ i: Int) {
        if presentingViewController != nil { dismiss(nil) }
        onChoose?(i)
    }
}

/// The new-target sheet (the project editor's "+" under the target
/// list): the template chooser, then "Choose options for your new
/// target:" with Product Name and, for test bundles, Target to be Tested.
@MainActor
public final class NewTargetSheetController: TemplateChooserController, NSTextFieldDelegate {
    public private(set) var steps = TemplateSheetSteps(count: 2)
    /// The project's targets, offered as the target to be tested.
    public let hostTargets: [String]
    public let productNameField = NSTextField(string: "")
    public let hostPopUp = NSPopUpButton()
    public let errorLabel = NSTextField(labelWithString: "")
    /// (platform, template, product name, target to be tested) → error text or nil.
    public var onFinish: ((String, String, String, String?) -> String?)?

    public init(platform: String, hostTargets: [String]) {
        self.hostTargets = hostTargets
        super.init(heading: TargetTemplateCatalog.heading, platforms: TargetTemplateCatalog.platforms,
                   platform: TargetTemplateCatalog.platforms.contains(platform) ? platform : "iOS",
                   catalog: TargetTemplateCatalog.sections(platform:filter:))
    }

    override func updateButtons() {
        previousButton.isEnabled = steps.isPreviousEnabled
        nextButton.title = steps.isLast ? "Finish" : "Next"
        nextButton.isEnabled = steps.index == 0 ? selectedEntry != nil
            : !productNameField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var hostTarget: String? {
        guard let e = selectedEntry, TargetTemplateCatalog.isTest(e.title) else { return nil }
        return hostPopUp.titleOfSelectedItem.flatMap { hostTargets.contains($0) ? $0 : nil }
    }

    public override func nextClicked() {
        guard let e = selectedEntry else { return }
        if steps.index == 0 {
            steps.next()
            if isViewLoaded { show(optionsView()) }
            updateButtons()
            return
        }
        if let error = onFinish?(platform, e.title, productNameField.stringValue, hostTarget) {
            errorLabel.stringValue = error
            return
        }
        if presentingViewController != nil { dismiss(nil) }
    }

    public override func previousClicked() {
        guard steps.isPreviousEnabled else { return }
        steps.previous()
        if isViewLoaded { show(chooserView) }
        updateButtons()
    }

    override func initialBody() -> NSView { steps.index == 0 ? chooserView : optionsView() }

    func optionsView() -> NSView {
        let heading = NSTextField(labelWithString: TargetTemplateCatalog.optionsHeading)
        heading.font = .boldSystemFont(ofSize: 13)
        productNameField.delegate = self
        productNameField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        hostPopUp.removeAllItems()
        hostPopUp.addItems(withTitles: hostTargets.isEmpty ? ["None"] : hostTargets)
        var rows: [[NSView]] = [[NSTextField(labelWithString: "Product Name:"), productNameField]]
        if let e = selectedEntry, TargetTemplateCatalog.isTest(e.title) {
            rows.append([NSTextField(labelWithString: "Target to be Tested:"), hostPopUp])
        }
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        errorLabel.textColor = .systemRed
        let stack = NSStackView(views: [heading, grid, errorLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        return stack
    }

    public func controlTextDidChange(_ obj: Notification) { updateButtons() }
}

/// The new-file save step's accessory (reference-ui-3.md §5.3; P10): a
/// Group pop-up listing the project's groups (indented by depth) and a
/// Targets checkbox list with the target of the selected file checked.
@MainActor
public final class SaveStepAccessory: NSObject {
    public struct GroupItem: Equatable, Sendable {
        public var title: String
        public var depth: Int
        public var directory: URL
    }

    public let groups: [GroupItem]
    public let targets: [String]
    public private(set) var checkedTargets: [String]
    public private(set) var selectedGroup: Int
    public let groupPopUp = NSPopUpButton()
    public private(set) var targetBoxes: [NSButton] = []
    /// The Group pop-up changed: the folder new files go to.
    public var onGroupChange: ((URL) -> Void)?
    public private(set) lazy var view: NSView = makeView()

    public init(proj: PBXProj?, xcodeprojURL: URL?, selectedFile: URL?, directory: URL) {
        var groups: [GroupItem] = []
        if let proj, let xcodeprojURL {
            let projectDir = proj.projectDirectory(xcodeprojURL: xcodeprojURL)
            let parents = proj.parentMap()
            let products = proj.project?.string("productRefGroup")
            func walk(_ id: String, _ depth: Int) {
                guard let g = proj[id], let path = proj.resolvedPath(of: id, projectDirectory: projectDir, parents: parents) else { return }
                let title = depth == 0 ? xcodeprojURL.deletingPathExtension().lastPathComponent
                    : g.string("name") ?? g.string("path").map { ($0 as NSString).lastPathComponent } ?? "Group"
                groups.append(GroupItem(title: title, depth: depth, directory: URL(fileURLWithPath: path)))
                for c in g.references("children") where c != products {
                    if let child = proj[c], child.isa == "PBXGroup" || child.isa == "PBXFileSystemSynchronizedRootGroup" { walk(c, depth + 1) }
                }
            }
            if let main = proj.project?.string("mainGroup") { walk(main, 0) }
        } else {
            groups = [GroupItem(title: directory.lastPathComponent, depth: 0, directory: directory)]
        }
        self.groups = groups
        let dir = directory.standardizedFileURL.path
        selectedGroup = groups.lastIndex { $0.directory.standardizedFileURL.path == dir } ?? 0
        targets = proj?.targets.compactMap { $0.string("name") } ?? []
        let owning = proj.flatMap { p in xcodeprojURL.map { Self.targets(of: selectedFile, proj: p, xcodeprojURL: $0) } } ?? []
        checkedTargets = owning.isEmpty ? Array(targets.prefix(1)) : owning
        super.init()
    }

    /// Targets whose build phases hold the file, or whose synchronized
    /// folders contain it.
    public static func targets(of file: URL?, proj: PBXProj, xcodeprojURL: URL) -> [String] {
        guard let file else { return [] }
        let path = file.standardizedFileURL.path
        let projectDir = proj.projectDirectory(xcodeprojURL: xcodeprojURL)
        let parents = proj.parentMap()
        return proj.targets.filter { t in
            let inPhase = proj.buildPhases(ofTarget: t.id).contains { phase in
                phase.references("files").contains { bf in
                    guard let ref = proj[bf]?.string("fileRef") else { return false }
                    return proj.resolvedPath(of: ref, projectDirectory: projectDir, parents: parents) == path
                }
            }
            let inFolder = t.references("fileSystemSynchronizedGroups").contains { g in
                guard let dir = proj.resolvedPath(of: g, projectDirectory: projectDir, parents: parents) else { return false }
                return path.hasPrefix(dir + "/")
            }
            return inPhase || inFolder
        }.compactMap { $0.string("name") }
    }

    /// The folder of the chosen group.
    public var selectedDirectory: URL { groups.indices.contains(selectedGroup) ? groups[selectedGroup].directory : URL(fileURLWithPath: "/") }

    public func selectGroup(_ i: Int) {
        guard groups.indices.contains(i) else { return }
        selectedGroup = i
        groupPopUp.selectItem(at: i)
        onGroupChange?(groups[i].directory)
    }

    public func setTarget(_ name: String, checked: Bool) {
        if checked { if !checkedTargets.contains(name) { checkedTargets.append(name) } } else { checkedTargets.removeAll { $0 == name } }
        checkedTargets.sort { (targets.firstIndex(of: $0) ?? 0) < (targets.firstIndex(of: $1) ?? 0) }
        for b in targetBoxes { b.state = checkedTargets.contains(b.title) ? .on : .off }
    }

    @objc func groupChosen(_ p: NSPopUpButton) { selectGroup(p.indexOfSelectedItem) }
    @objc func targetToggled(_ b: NSButton) { setTarget(b.title, checked: b.state == .on) }

    func makeView() -> NSView {
        groupPopUp.removeAllItems()
        for g in groups {
            // Menu items directly: group names repeat (project and folder).
            let item = NSMenuItem(title: g.title, action: nil, keyEquivalent: "")
            item.indentationLevel = min(g.depth, 15)
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            groupPopUp.menu?.addItem(item)
        }
        groupPopUp.selectItem(at: selectedGroup)
        groupPopUp.target = self
        groupPopUp.action = #selector(groupChosen(_:))
        var rows: [[NSView]] = [[NSTextField(labelWithString: "Group:"), groupPopUp]]
        targetBoxes = targets.map { t in
            let b = NSButton(checkboxWithTitle: t, target: self, action: #selector(targetToggled(_:)))
            b.state = checkedTargets.contains(t) ? .on : .off
            return b
        }
        for (i, b) in targetBoxes.enumerated() { rows.append([NSTextField(labelWithString: i == 0 ? "Targets:" : ""), b]) }
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(x: 0, y: 0, width: 360, height: CGFloat(rows.count) * 26 + 12)
        return grid
    }
}
