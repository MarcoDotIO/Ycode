import AppKit

/// What the File inspector shows about a file beyond its path: the git
/// working copy and the project's targets (`specs/ide/reference-ui-5.md` §7.3).
public struct FileInspectorInfo: Equatable {
    /// The repository's top-level folder, and the file's path inside it;
    /// nil outside git.
    public var workingCopy: String?
    public var relativePath: String?
    /// Every target with whether it includes the file (empty: no targets).
    public var memberships: [TargetMembership]
    public init(workingCopy: String? = nil, relativePath: String? = nil, memberships: [TargetMembership] = []) {
        self.workingCopy = workingCopy
        self.relativePath = relativePath
        self.memberships = memberships
    }
}

/// The right inspector area: a tab bar (File, History, Quick Help for
/// source files) above the selected inspector. See
/// `specs/ide/workspace-window.md` §Inspector area.
@MainActor
public final class InspectorAreaController: NSViewController {
    public static let symbols = ["doc", "clock", "questionmark.circle"]
    /// The standard tabs' tooltips, exactly (reference-ui-5.md §7.1).
    public static let toolTips = ["Show the File inspector", "Show the History inspector", "Show Quick Help inspector"]
    /// File inspector: the working copy and targets of a file (set by the window).
    public var fileInfo: ((URL) -> FileInspectorInfo)?
    /// Target Membership "+" / "−": (file, target ID, member).
    public var onSetMembership: ((URL, String, Bool) -> Void)?
    /// History inspector: the commits that changed a file, newest first.
    /// The file's commits (read from git in the background).
    public var historyProvider: ((URL) async -> [GitRepository.Commit])?
    /// The history read in progress, if any.
    public private(set) var historyLoading: Task<Void, Never>?
    private var loadedHistory: (url: URL, commits: [GitRepository.Commit])?
    private var historyGeneration = 0
    /// A history row was selected: show the commit in Code Review.
    public var onSelectHistoryCommit: ((URL, GitRepository.Commit) -> Void)?
    /// Quick Help ▸ Search Documentation.
    public var onSearchDocumentation: (() -> Void)?
    /// The shown file's info and history (tests).
    public private(set) var shownInfo: FileInspectorInfo?
    public private(set) var historyCommits: [GitRepository.Commit] = []
    /// Target Membership rows selected for "−" (target IDs).
    public private(set) var selectedMemberships: Set<String> = []
    /// The centered placeholder ("Not Applicable", "No History"); empty when none.
    public var centeredText: String { _ = view; return centerLabel.isHidden ? "" : centerLabel.stringValue }
    private let centerLabel = NSTextField(labelWithString: "")
    /// The section headings of the shown inspector, in order (tests).
    public private(set) var sectionTitles: [String] = []
    /// The rows of the shown inspector: (key, value) for text rows (tests).
    public private(set) var rowValues: [(String, String)] = []
    /// The tab buttons' tooltips (tests).
    public var tabToolTips: [String] { buttons.map { $0.toolTip ?? "" } }
    public private(set) var selectedIndex = 0
    private var buttons: [NSButton] = []
    private let bar = NSStackView()
    /// Inspectors added by the focused editor (Interface Builder adds
    /// Identity, Attributes, Size, Connections), after the standard three.
    public private(set) var extraInspectors: [(name: String, symbol: String)] = []
    private var extraProvider: ((Int) -> NSView)?
    /// File inspector: Name was edited (old URL, new name).
    public var onRename: ((URL, String) -> Void)?
    /// File inspector controls (tests).
    public private(set) var nameField: NSTextField?
    public private(set) var fileControls: [String: NSView] = [:]

    /// The titles of every tab, standard ones first.
    public var tabNames: [String] { CommandTable.inspectors + extraInspectors.map(\.name) }

    /// Shows editor-specific inspectors next to File / History / Quick
    /// Help; `provider(i)` builds the view of extra inspector `i`. An empty
    /// list removes them.
    public func setExtraInspectors(_ list: [(name: String, symbol: String)], provider: ((Int) -> NSView)?, select index: Int? = nil) {
        let changed = list.map(\.name) != extraInspectors.map(\.name)
        extraInspectors = list
        extraProvider = provider
        guard isViewLoaded else { return }
        if changed { rebuildButtons() }
        if let index { select(index) } else if selectedIndex >= tabNames.count { select(0) } else { select(selectedIndex) }
    }

    /// Rebuilds the current inspector (after the selection changed).
    public func refresh() { if isViewLoaded { select(selectedIndex) } }

    private func rebuildButtons() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        let all = zip(CommandTable.inspectors, Self.symbols).map { ($0, $1) } + extraInspectors.map { ($0.name, $0.symbol) }
        for (i, (name, symbol)) in all.enumerated() {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: "\(name) inspector") ?? NSImage(),
                             target: self, action: #selector(tabClicked(_:)))
            b.isBordered = false
            b.tag = i
            b.toolTip = i < Self.toolTips.count ? Self.toolTips[i] : "Show the \(name) inspector"
            buttons.append(b)
            bar.addArrangedSubview(b)
        }
    }
    private let content = NSStackView()
    private var file: URL?
    /// The Quick Help inspector's text (from the language server).
    public private(set) var quickHelp: String?

    /// The defining file of the Quick Help symbol (the file link).
    public var quickHelpFile: String?

    public func showQuickHelp(_ text: String?, file: String? = nil) {
        quickHelp = text
        quickHelpFile = file
        if selectedIndex == 2 { select(2) }
    }

    public override func loadView() {
        let root = NSView()
        bar.orientation = .horizontal
        // §7.1: the tabs fill the bar's width as equal segments.
        bar.distribution = .fillEqually
        bar.spacing = 0
        rebuildButtons()
        let sep = NSBox.hairline()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        centerLabel.textColor = .secondaryLabelColor
        centerLabel.alignment = .center
        centerLabel.font = .systemFont(ofSize: 13)
        centerLabel.isHidden = true
        for v in [bar, sep, content, centerLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            bar.heightAnchor.constraint(equalToConstant: 26),
            centerLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            centerLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            sep.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 2),
            sep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: sep.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
        select(0)
    }

    public func show(file: URL?) {
        if file != self.file { selectedMemberships = [] }
        self.file = file
        select(selectedIndex)
    }

    public func select(_ index: Int) {
        selectedIndex = index
        for b in buttons { b.contentTintColor = b.tag == index ? .controlAccentColor : .secondaryLabelColor }
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        centerLabel.isHidden = true
        sectionTitles = []
        rowValues = []
        if index >= CommandTable.inspectors.count, let provider = extraProvider {
            let v = provider(index - CommandTable.inspectors.count)
            content.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -24).isActive = true
            return
        }
        switch index {
        case 0: fileInspector()
        case 1: historyInspector()
        default:
            if let q = quickHelp {
                content.addArrangedSubview(QuickHelpView.make(QuickHelpDocument(hover: q, file: quickHelpFile)))
            } else {
                // §7.5: the caret is not on a symbol.
                content.addArrangedSubview(heading("Quick Help"))
                content.addArrangedSubview(note("No Quick Help"))
                let search = NSButton(title: "Search Documentation", target: self, action: #selector(searchDocumentationClicked))
                search.controlSize = .small
                search.font = .systemFont(ofSize: 11)
                fileControls["Search Documentation"] = search
                content.addArrangedSubview(search)
            }
        }
    }

    @objc private func searchDocumentationClicked() { onSearchDocumentation?() }

    private func showCentered(_ text: String) {
        centerLabel.stringValue = text
        centerLabel.isHidden = false
    }

    // MARK: History inspector (§7.4)

    /// Waits for the history read (tests).
    public func historyIdle() async {
        while let t = historyLoading { await t.value }
    }

    private func historyInspector() {
        // The commits are read in the background; the inspector fills in
        // when they arrive (if it still shows this file's history).
        historyGeneration += 1
        if let loaded = loadedHistory, loaded.url == file {
            loadedHistory = nil
            historyLoading = nil
            historyCommits = loaded.commits
        } else if let file, let provider = historyProvider {
            loadedHistory = nil
            historyCommits = []
            let generation = historyGeneration
            historyLoading = Task { [weak self] in
                let commits = await provider(file)
                guard let self, generation == self.historyGeneration else { return }
                self.historyLoading = nil
                guard self.selectedIndex == 1, self.file == file else { return }
                self.loadedHistory = (file, commits)
                self.select(1)
            }
            return
        } else {
            historyCommits = []
        }
        guard !historyCommits.isEmpty else { showCentered("No History"); return }
        for (i, c) in historyCommits.enumerated() {
            let author = NSTextField(labelWithString: c.authorName)
            author.font = .boldSystemFont(ofSize: 11)
            author.lineBreakMode = .byTruncatingTail
            let date = NSTextField(labelWithString: GitDates.relativeDay(c.date))
            date.font = .systemFont(ofSize: 10)
            date.textColor = .secondaryLabelColor
            date.setContentHuggingPriority(.required, for: .horizontal)
            date.setContentCompressionResistancePriority(.required, for: .horizontal)
            let top = NSStackView(views: [author, NSView(), date])
            let subject = NSTextField(labelWithString: c.subject)
            subject.font = .systemFont(ofSize: 11)
            subject.textColor = .secondaryLabelColor
            subject.lineBreakMode = .byTruncatingTail
            let rowView = NSStackView(views: [top, subject])
            rowView.orientation = .vertical
            rowView.alignment = .leading
            rowView.spacing = 1
            let button = NSButton(title: "", target: self, action: #selector(historyRowClicked(_:)))
            button.isBordered = false
            button.isTransparent = true
            button.tag = i
            button.setAccessibilityLabel("\(c.authorName), \(c.subject)")
            button.translatesAutoresizingMaskIntoConstraints = false
            rowView.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: rowView.leadingAnchor), button.trailingAnchor.constraint(equalTo: rowView.trailingAnchor),
                button.topAnchor.constraint(equalTo: rowView.topAnchor), button.bottomAnchor.constraint(equalTo: rowView.bottomAnchor),
            ])
            content.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -24).isActive = true
            top.widthAnchor.constraint(equalTo: rowView.widthAnchor).isActive = true
            rowValues.append((c.authorName, c.subject))
        }
    }

    /// The history rows: author, subject, relative day (tests).
    public var historyRows: [(author: String, subject: String, date: String)] {
        historyCommits.map { ($0.authorName, $0.subject, GitDates.relativeDay($0.date)) }
    }

    @objc private func historyRowClicked(_ b: NSButton) { selectHistoryRow(b.tag) }

    /// Selects a history row: the commit shows in Code Review.
    public func selectHistoryRow(_ i: Int) {
        guard let file, i >= 0, i < historyCommits.count else { return }
        onSelectHistoryCommit?(file, historyCommits[i])
    }

    private func fileInspector() {
        guard let file else {
            showCentered("Not Applicable")   // §7.2
            return
        }
        // reference-ui.md §6.
        fileControls = [:]
        content.addArrangedSubview(heading("Identity and Type"))
        let name = NSTextField(string: file.lastPathComponent)
        name.font = .systemFont(ofSize: 11)
        name.target = self
        name.action = #selector(nameCommitted(_:))
        name.widthAnchor.constraint(equalToConstant: 160).isActive = true
        nameField = name
        content.addArrangedSubview(row("Name", name))
        content.addArrangedSubview(row("Type", popUp("Type", ["Default - " + Self.typeName(for: file)])))
        let choose = NSButton(image: NSImage(systemSymbolName: "folder", accessibilityDescription: "Choose location")!, target: nil, action: nil)
        choose.isBordered = false
        choose.isEnabled = false
        let isProject = file.pathExtension == "xcodeproj"
        let location = popUp("Location", [isProject ? "Absolute" : "Relative to Group"])
        location.isEnabled = !isProject
        content.addArrangedSubview(row("Location", NSStackView(views: [location, choose])))
        if isProject { content.addArrangedSubview(row("", note("Containing directory"))) }
        let fileName = NSTextField(labelWithString: file.lastPathComponent)
        fileName.font = .systemFont(ofSize: 11)
        content.addArrangedSubview(row("", fileName))
        let path = NSTextField(wrappingLabelWithString: file.path)
        path.font = .systemFont(ofSize: 11)
        path.preferredMaxLayoutWidth = 140
        let reveal = NSButton(image: NSImage(systemSymbolName: "arrow.right.circle.fill", accessibilityDescription: "Show in Finder")!,
                              target: self, action: #selector(revealClicked))
        reveal.isBordered = false
        fileControls["Reveal"] = reveal
        content.addArrangedSubview(row("Full Path", NSStackView(views: [path, reveal])))
        rowValues.append(("Full Path", file.path))
        let info = fileInfo?(file) ?? FileInspectorInfo()
        shownInfo = info
        if let wc = info.workingCopy, let rel = info.relativePath {
            for (k, v) in [("Working Copy", wc), ("Relative Path", rel)] {
                content.addArrangedSubview(row(k, v))
                rowValues.append((k, v))
            }
        }
        if isProject {
            // reference-ui-3.md §1.13.
            let rows = ProjectDocumentInspector.rows(for: file, controls: &fileControls)
            if !rows.isEmpty {
                content.addArrangedSubview(heading("Project Document"))
                for (k, v) in rows { content.addArrangedSubview(row(k, v)) }
            }
        }
        if !isProject {
            onDemandResourceTags()
            targetMembership(file, info)
        }
        content.addArrangedSubview(heading("Text Settings"))
        content.addArrangedSubview(row("Text Encoding", popUp("Text Encoding", ["No Explicit Encoding", "Unicode (UTF-8)"])))
        content.addArrangedSubview(row("Line Endings", popUp("Line Endings", ["No Explicit Line Endings", "macOS / Unix (LF)"])))
        let p = Preferences.shared
        content.addArrangedSubview(row("Indent Using", popUp("Indent Using", p.indentWithTabs ? ["Tabs", "Spaces"] : ["Spaces", "Tabs"])))
        content.addArrangedSubview(row("Widths", NSStackView(views: [stepper("Tab", p.tabWidth), stepper("Indent", p.indentWidth)])))
    }

    private func popUp(_ key: String, _ items: [String]) -> NSPopUpButton {
        let b = NSPopUpButton(frame: .zero, pullsDown: false)
        b.addItems(withTitles: items)
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        fileControls[key] = b
        return b
    }

    /// A value with a stepper and its label under them.
    private func stepper(_ label: String, _ value: Int) -> NSView {
        let field = NSTextField(labelWithString: "\(value)")
        field.font = .systemFont(ofSize: 11)
        let s = NSStepper()
        s.minValue = 1
        s.maxValue = 16
        s.integerValue = value
        s.controlSize = .small
        s.target = self
        s.action = #selector(stepped(_:))
        s.identifier = .init(label)
        fileControls[label] = s
        fileControls[label + " Value"] = field
        let l = NSTextField(labelWithString: label)
        l.font = .systemFont(ofSize: 9)
        l.textColor = .secondaryLabelColor
        let col = NSStackView(views: [NSStackView(views: [field, s]), l])
        col.orientation = .vertical
        col.spacing = 1
        return col
    }

    @objc private func stepped(_ s: NSStepper) {
        let key = s.identifier?.rawValue ?? ""
        (fileControls[key + " Value"] as? NSTextField)?.stringValue = "\(s.integerValue)"
        if key == "Tab" { Preferences.shared.tabWidth = s.integerValue } else { Preferences.shared.indentWidth = s.integerValue }
    }

    @objc private func nameCommitted(_ f: NSTextField) {
        guard let file, !f.stringValue.isEmpty, f.stringValue != file.lastPathComponent else { return }
        onRename?(file, f.stringValue)
    }

    @objc private func revealClicked() {
        guard let file, view.window?.isVisible == true else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    /// A human-readable file type, from the extension.
    static func typeName(for url: URL) -> String {
        switch url.pathExtension {
        case "swift": "Swift Source"
        case "m": "Objective-C Source"
        case "h": "C Header"
        case "c": "C Source"
        case "plist": "Property List"
        case "xcconfig": "Configuration Settings File"
        default: "Default"
        }
    }

    // MARK: On Demand Resource Tags, Target Membership (§7.3)

    private func onDemandResourceTags() {
        content.addArrangedSubview(heading("On Demand Resource Tags"))
        let tags = NSTokenField()
        tags.placeholderString = "Only resources are taggable"
        tags.isEnabled = false
        tags.controlSize = .small
        tags.font = .systemFont(ofSize: 11)
        fileControls["On Demand Resource Tags"] = tags
        content.addArrangedSubview(tags)
        tags.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -24).isActive = true
    }

    private func targetMembership(_ file: URL, _ info: FileInspectorInfo) {
        guard !info.memberships.isEmpty else { return }
        content.addArrangedSubview(heading("Target Membership"))
        let members = info.memberships.filter(\.isMember)
        selectedMemberships.formIntersection(members.map(\.targetID))
        for m in members {
            let name = NSTextField(labelWithString: m.name)
            name.font = .systemFont(ofSize: 11)
            let kind = NSTextField(labelWithString: m.kind)
            kind.font = .systemFont(ofSize: 10)
            kind.textColor = .secondaryLabelColor
            let text = NSStackView(views: [name, kind])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 0
            let icon = NSImageView(image: NSImage(systemSymbolName: "app.dashed", accessibilityDescription: "Target") ?? NSImage())
            icon.contentTintColor = .secondaryLabelColor
            let r = NSStackView(views: [icon, text])
            r.wantsLayer = true
            r.layer?.cornerRadius = 4
            r.layer?.backgroundColor = selectedMemberships.contains(m.targetID) ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor : nil
            let pick = NSButton(title: "", target: self, action: #selector(membershipRowClicked(_:)))
            pick.isBordered = false
            pick.isTransparent = true
            pick.identifier = .init(m.targetID)
            pick.setAccessibilityLabel(m.name)
            pick.translatesAutoresizingMaskIntoConstraints = false
            r.addSubview(pick)
            NSLayoutConstraint.activate([
                pick.leadingAnchor.constraint(equalTo: r.leadingAnchor), pick.trailingAnchor.constraint(equalTo: r.trailingAnchor),
                pick.topAnchor.constraint(equalTo: r.topAnchor), pick.bottomAnchor.constraint(equalTo: r.bottomAnchor),
            ])
            content.addArrangedSubview(r)
            rowValues.append(("Target", m.name))
        }
        func small(_ symbol: String, _ tip: String, _ sel: Selector?) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: self, action: sel)
            b.isBordered = false
            b.toolTip = tip
            b.isEnabled = sel != nil
            return b
        }
        let add = small("plus", "Choose which targets include this file", #selector(addMembershipClicked(_:)))
        add.isEnabled = info.memberships.contains { !$0.isMember && $0.isEditable }
        let remove = small("minus", "Remove this file from selected targets", #selector(removeMembershipClicked))
        remove.isEnabled = info.memberships.contains { selectedMemberships.contains($0.targetID) && $0.isEditable }
        let edit = small("pencil", "Edit target membership options", nil)
        fileControls["Add Target"] = add
        fileControls["Remove Target"] = remove
        fileControls["Edit Target Membership"] = edit
        content.addArrangedSubview(NSStackView(views: [add, remove, edit]))
    }

    @objc private func membershipRowClicked(_ b: NSButton) {
        guard let id = b.identifier?.rawValue else { return }
        toggleMembershipSelection(id)
    }

    /// Selects or deselects a Target Membership row (by target ID).
    public func toggleMembershipSelection(_ targetID: String) {
        if !selectedMemberships.insert(targetID).inserted { selectedMemberships.remove(targetID) }
        refresh()
    }

    /// The "+" menu: the targets that do not include the file.
    public func addMembershipMenu() -> NSMenu {
        let menu = NSMenu(title: "Targets")
        for m in shownInfo?.memberships ?? [] where !m.isMember {
            let item = NSMenuItem(title: m.name, action: m.isEditable ? #selector(addMembershipChosen(_:)) : nil, keyEquivalent: "")
            item.target = self
            item.representedObject = m.targetID
            item.isEnabled = m.isEditable
            menu.addItem(item)
        }
        return menu
    }

    @objc private func addMembershipClicked(_ b: NSButton) {
        let menu = addMembershipMenu()
        guard b.window?.isVisible == true else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height), in: b)
    }

    @objc private func addMembershipChosen(_ item: NSMenuItem) {
        guard let file, let id = item.representedObject as? String else { return }
        onSetMembership?(file, id, true)
        refresh()
    }

    /// "−": removes the file from the selected targets.
    @objc public func removeMembershipClicked() {
        guard let file else { return }
        for id in selectedMemberships.sorted() { onSetMembership?(file, id, false) }
        selectedMemberships = []
        refresh()
    }

    private func heading(_ s: String) -> NSTextField {
        sectionTitles.append(s)
        let l = NSTextField(labelWithString: s)
        l.font = .boldSystemFont(ofSize: 11)
        return l
    }

    private func note(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func row(_ key: String, _ control: NSView) -> NSView {
        let k = NSTextField(labelWithString: key)
        k.font = .systemFont(ofSize: 11)
        k.textColor = .secondaryLabelColor
        k.alignment = .right
        k.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let s = NSStackView(views: [k, control])
        s.alignment = .centerY
        return s
    }

    private func row(_ key: String, _ value: String) -> NSView {
        let k = NSTextField(labelWithString: key)
        k.font = .systemFont(ofSize: 11)
        k.textColor = .secondaryLabelColor
        k.alignment = .right
        k.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let v = NSTextField(wrappingLabelWithString: value)
        v.font = .systemFont(ofSize: 11)
        v.preferredMaxLayoutWidth = 160
        let s = NSStackView(views: [k, v])
        s.alignment = .firstBaseline
        return s
    }

    @objc private func tabClicked(_ b: NSButton) { select(b.tag) }
}
