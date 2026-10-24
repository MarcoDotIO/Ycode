import AppKit
import YcodeProject

/// The project editor's tab views (reference-ui-3.md §1): General and Info
/// as tables in collapsible sections, Signing & Capabilities with its
/// scope and the capability library, Build Phases with the "+" menu and
/// trash buttons, and the Build Settings table.
extension ProjectEditorController {
    // MARK: Sections

    /// Section key: the title without a trailing " (N…)" count.
    static func sectionKey(_ title: String) -> String {
        if let r = title.range(of: " (", options: .backwards), title.hasSuffix(")") { return String(title[..<r.lowerBound]) }
        return title
    }

    func section(_ title: String, _ body: NSView, accessory: [NSView] = []) -> CollapsibleSection {
        let key = Self.sectionKey(title)
        let s = CollapsibleSection(title: title, body: body, collapsed: collapsedSections.contains(key), accessory: accessory)
        s.onToggle = { [weak self] collapsed in
            if collapsed { self?.collapsedSections.insert(key) } else { self?.collapsedSections.remove(key) }
        }
        sectionViews[key] = s
        return s
    }

    /// Collapses or expands a section of the shown tab.
    public func toggleSection(_ title: String) {
        sectionViews[Self.sectionKey(title)]?.setCollapsed(!(sectionViews[Self.sectionKey(title)]?.isCollapsed ?? false))
    }

    func table(_ key: String, columns: [String], rows: [[NSView]], empty: String? = nil, plus: Selector? = nil, minus: Selector? = nil,
               width: CGFloat = 520) -> NSView {
        let t = StaticTable(columns: columns, rows: rows, emptyText: empty, plusMinus: (plus != nil || minus != nil) || empty != nil ? (self, plus, minus) : nil,
                            width: width)
        tables[key] = t
        return t.container
    }

    /// A vertical, top-aligned scrolling page.
    func page(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 24, bottom: 20, right: 24)
        let flipped = FlippedView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: flipped.topAnchor), stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: flipped.trailingAnchor), stack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
        ])
        let scroll = NSScrollView()
        scroll.documentView = flipped
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        return scroll
    }

    func grid(_ rows: [(String, NSView)]) -> NSGridView {
        let g = NSGridView(views: rows.map { [label($0.0), $0.1] })
        g.column(at: 0).xPlacement = .trailing
        g.rowAlignment = .firstBaseline
        g.rowSpacing = 8
        return g
    }

    func settingField(_ key: String, target t: String, placeholder: String? = nil, width: CGFloat = 300) -> NSTextField {
        let f = NSTextField(string: resolved(key, target: t))
        f.identifier = .init(key)
        f.placeholderString = placeholder
        f.delegate = self
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        return f
    }

    // MARK: General

    func generalView(_ t: String) -> NSView {
        var sections: [NSView] = []
        let devices = model.deploymentInfoDevices(target: t, configuration: configuration)
        for title in model.generalSections(target: t, configuration: configuration) {
            let body: NSView
            switch title {
            case "Supported Destinations":
                let dests = model.supportedDestinations(target: t, configuration: configuration)
                let rows = dests.map { [NSTextField.cell($0.name), NSTextField.cell($0.sdk)] as [NSView] }
                body = table(title, columns: ["Destination", "SDK"], rows: rows, plus: #selector(destinationPlusClicked(_:)),
                             minus: #selector(destinationMinusClicked(_:)))
                tables[title]?.itemIDs = dests.map(\.name)
            case "Minimum Deployments":
                body = grid(model.minimumDeployments(target: t, configuration: configuration).map { d in
                    let combo = NSComboBox()
                    combo.addItems(withObjectValues: ProjectEditorModel.deploymentVersions)
                    combo.stringValue = d.value
                    combo.identifier = .init(d.setting)
                    combo.delegate = self
                    combo.widthAnchor.constraint(equalToConstant: 100).isActive = true
                    let plus = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add platform")!, target: self,
                                        action: #selector(deploymentPlusClicked(_:)))
                    plus.isBordered = false
                    plus.identifier = .init("addDeploymentPlatform")
                    plus.isEnabled = !model.addableDeploymentSDKs(target: t, configuration: configuration).isEmpty
                    return (d.sdk, NSStackView(views: [combo, plus]))
                })
            case "Identity":
                body = identityBody(t)
            case "Deployment Info":
                var rows: [(String, NSView)] = []
                for device in devices {
                    let on = model.orientations(device: device, target: t, configuration: configuration)
                    let boxes = ProjectEditorModel.orientations.map { o -> NSView in
                        let b = NSButton(checkboxWithTitle: o.title, target: self, action: #selector(orientationToggled(_:)))
                        b.identifier = .init("\(device):\(o.value)")
                        b.state = on.contains(o.value) ? .on : .off
                        return b
                    }
                    let col = NSStackView(views: boxes)
                    col.orientation = .vertical
                    col.alignment = .leading
                    rows.append(("\(device) Orientation", col))
                }
                let style = NSPopUpButton(frame: .zero, pullsDown: false)
                style.addItems(withTitles: ["Default", "Dark Content", "Light Content"])
                let hide = NSButton(checkboxWithTitle: "Hide during application launch", target: self, action: #selector(statusBarHiddenToggled(_:)))
                hide.state = resolved("INFOPLIST_KEY_UIStatusBarHidden", target: t) == "YES" ? .on : .off
                let scene = NSButton(title: "Scene manifest \u{2192}", target: nil, action: nil)
                scene.isBordered = false
                rows += [("Status Bar Style", NSStackView(views: [style, hide])), ("", scene)]
                body = grid(rows)
            case "App Icons and Launch Screen":
                let source = NSButton(checkboxWithTitle: "Include all app icon assets", target: nil, action: nil)
                source.state = resolved("ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS", target: t) == "YES" ? .on : .off
                let launch = NSComboBox()
                launch.placeholderString = "Storyboard Base Name"
                launch.stringValue = resolved("INFOPLIST_KEY_UILaunchStoryboardName", target: t)
                launch.identifier = .init("INFOPLIST_KEY_UILaunchStoryboardName")
                launch.delegate = self
                launch.widthAnchor.constraint(equalToConstant: 260).isActive = true
                var iconRows: [(String, NSView)] = [("App Icon", settingField("ASSETCATALOG_COMPILER_APPICON_NAME", target: t, width: 260)),
                                                    ("App Icons Source", source)]
                if model.hasIOSDestination(target: t, configuration: configuration) { iconRows.append(("Launch Screen File", launch)) }
                body = grid(iconRows)
            case "Frameworks, Libraries, and Embedded Content":
                let link = model.phaseSections(target: t).first { $0.title == "Link Binary With Libraries" }
                let embedded = model.embeddedAndSigned(target: t)
                let rows = (link?.items ?? []).map { item -> [NSView] in
                    let embed = NSPopUpButton(frame: .zero, pullsDown: false)
                    embed.addItems(withTitles: ["Do Not Embed", "Embed & Sign", "Embed Without Signing"])
                    embed.selectItem(withTitle: embedded.contains(item.name) ? "Embed & Sign" : "Do Not Embed")
                    embed.controlSize = .small
                    return [NSTextField.cell(item.name), embed]
                }
                body = table(title, columns: ["Name", "Embed"], rows: rows, empty: ProjectEditorModel.generalEmptyTexts[title],
                             plus: #selector(noAction), minus: #selector(noAction))
            case "Supported Intents":
                body = table(title, columns: ["Class Name", "Authentication"], rows: [], empty: ProjectEditorModel.generalEmptyTexts[title],
                             plus: #selector(noAction), minus: #selector(noAction))
            default:
                body = table(title, columns: ["Name"], rows: [], empty: ProjectEditorModel.generalEmptyTexts[title],
                             plus: #selector(noAction), minus: #selector(noAction))
            }
            var accessory: [NSView] = []
            if title == "Minimum Deployments" {
                let info = NSButton(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Info")!, target: nil, action: nil)
                info.isBordered = false
                accessory.append(info)
            }
            sections.append(section(title, body, accessory: accessory))
        }
        return page(sections)
    }

    @objc func noAction() {}

    @objc func orientationToggled(_ b: NSButton) {
        let parts = (b.identifier?.rawValue ?? "").split(separator: ":").map(String.init)
        guard parts.count == 2 else { return }
        setOrientation(parts[1], device: parts[0], on: b.state == .on)
    }

    /// Turns an orientation checkbox of iPhone or iPad on or off.
    public func setOrientation(_ value: String, device: String, on: Bool) {
        guard let t = selectedTarget else { return }
        model.setOrientation(value, device: device, on: on, target: t, configuration: configuration)
        onChange?(model.proj)
        showTab()
    }

    @objc func statusBarHiddenToggled(_ b: NSButton) { setSetting("INFOPLIST_KEY_UIStatusBarHidden", b.state == .on ? "YES" : "") }

    // MARK: Info

    public static let infoTypes = ["String", "Number", "Boolean", "Date", "Data", "Array", "Dictionary"]

    func infoView(_ t: String) -> NSView {
        var rows: [[NSView]] = []
        // Containers expand in place; children are indented (P5).
        func add(_ item: ProjectEditorModel.InfoItem, path: String, depth: Int) {
            let indent = String(repeating: "    ", count: depth)
            let keyView: NSView
            if item.isContainer {
                let open = expandedInfoKeys.contains(path)
                let d = NSButton(title: indent + (open ? "\u{25BE} " : "\u{25B8} ") + item.key, target: self, action: #selector(infoKeyDisclosureClicked(_:)))
                d.isBordered = false
                d.alignment = .left
                d.identifier = .init(path)
                d.toolTip = item.rawKey
                keyView = d
            } else {
                let f = NSTextField.cell(indent + item.key)
                f.toolTip = item.rawKey
                keyView = f
            }
            let type = NSPopUpButton(frame: .zero, pullsDown: false)
            type.addItems(withTitles: Self.infoTypes)
            type.selectItem(withTitle: item.type)
            type.controlSize = .small
            type.isBordered = false
            rows.append([keyView, type, NSTextField.cell(item.value)])
            infoRowPaths.append(path)
            if item.isContainer, expandedInfoKeys.contains(path) {
                for c in item.children { add(c, path: path + "/" + c.rawKey, depth: depth + 1) }
            }
        }
        infoRowPaths = []
        for item in model.infoItems(target: t, configuration: configuration) { add(item, path: item.rawKey, depth: 0) }
        let title = model.infoSectionTitle(target: t, configuration: configuration)
        var views: [NSView] = [section(title, table(title, columns: ["Key", "Type", "Value"], rows: rows, width: 640))]
        for (s, (title, key)) in zip(model.infoTypeSections(target: t, configuration: configuration), ProjectEditorModel.infoTypeKeys) {
            views.append(section(s, infoTypeSection(title: title, key: key, target: t)))
        }
        return page(views)
    }

    /// Expands or collapses a container row of the Info table ("Key" or
    /// "Key/Child/…" by raw keys).
    public func toggleInfoKey(_ path: String) {
        if expandedInfoKeys.contains(path) { expandedInfoKeys.remove(path) } else { expandedInfoKeys.insert(path) }
        if tab == .info { showTab() }
    }

    @objc func infoKeyDisclosureClicked(_ b: NSButton) { if let p = b.identifier?.rawValue { toggleInfoKey(p) } }

    // MARK: Signing & Capabilities

    /// The configuration the Signing tab shows: the scope's, or the
    /// editor's for All.
    var signingConfiguration: String { signingScope == "All" ? configuration : signingScope }

    /// Chooses All, Debug or Release; edits then go to that configuration.
    public func setSigningScope(_ scope: String) {
        guard scope == "All" || model.configurations(of: selectedTarget).names.contains(scope) else { return }
        signingScope = scope
        if tab == .signing { showTab() }
    }

    @objc func signingScopeChosen(_ s: NSSegmentedControl) { setSigningScope(s.label(forSegment: s.selectedSegment) ?? "All") }

    func signingResolved(_ name: String, target t: String) -> String {
        model.resolve(target: t, configuration: signingConfiguration)?.settings[name] ?? ""
    }

    func signingView(_ t: String) -> NSView {
        let cfg = signingConfiguration
        let addCap = NSButton(title: "+ Capability", target: self, action: #selector(addCapabilityClicked))
        let scopes = ["All"] + model.configurations(of: t).names
        let scope = NSSegmentedControl(labels: scopes, trackingMode: .selectOne, target: self, action: #selector(signingScopeChosen(_:)))
        scope.selectedSegment = scopes.firstIndex(of: signingScope) ?? 0
        scope.identifier = .init("signingScope")
        let bar = NSStackView(views: [addCap, scope])

        let auto = NSButton(checkboxWithTitle: "Automatically manage signing", target: self, action: #selector(autoSigningToggled(_:)))
        auto.state = signingResolved("CODE_SIGN_STYLE", target: t) != "Manual" ? .on : .off
        let caption = NSTextField(labelWithString: ProjectEditorModel.automaticSigningCaption)
        caption.textColor = .secondaryLabelColor
        caption.font = .systemFont(ofSize: 11)
        let autoStack = NSStackView(views: [auto, caption])
        autoStack.orientation = .vertical
        autoStack.alignment = .leading
        let team = NSComboBox()
        team.addItems(withObjectValues: model.teams)
        team.stringValue = signingResolved("DEVELOPMENT_TEAM", target: t)
        team.placeholderString = "None"
        team.identifier = .init("DEVELOPMENT_TEAM")
        team.delegate = self
        team.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let bundle = NSTextField(string: signingResolved("PRODUCT_BUNDLE_IDENTIFIER", target: t))
        bundle.identifier = .init("PRODUCT_BUNDLE_IDENTIFIER")
        bundle.delegate = self
        bundle.widthAnchor.constraint(equalToConstant: 320).isActive = true
        var signingViews: [NSView] = [grid([("", autoStack), ("Team", team), ("Bundle Identifier", bundle)])]
        for b in model.signingBoxes(target: t, configuration: cfg) {
            let box = NSBox()
            box.title = b.platform
            var rows: [(String, NSView)] = [("Provisioning Profile", NSTextField.cell(b.provisioningProfile)),
                                            ("Signing Certificate", NSTextField.cell(b.certificate))]
            if !b.status.isEmpty {
                let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")!)
                icon.contentTintColor = .systemYellow
                let text = NSTextField(wrappingLabelWithString: b.status.joined(separator: "\n"))
                text.preferredMaxLayoutWidth = 360
                rows.append(("Status", NSStackView(views: [icon, text])))
            }
            let g = grid(rows)
            g.translatesAutoresizingMaskIntoConstraints = false
            box.contentView?.addSubview(g)
            if let cv = box.contentView {
                NSLayoutConstraint.activate([g.topAnchor.constraint(equalTo: cv.topAnchor, constant: 8), g.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 8),
                                             g.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -8), g.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -8)])
            }
            box.identifier = .init("signingBox:" + b.platform)
            signingViews.append(box)
        }
        let signingBody = NSStackView(views: signingViews)
        signingBody.orientation = .vertical
        signingBody.alignment = .leading
        var views: [NSView] = [bar, section("Signing", signingBody)]
        let caps = model.capabilities(target: t, configuration: cfg)
        if caps.isEmpty {
            let empty = NSTextField(labelWithString: ProjectEditorModel.emptyCapabilitiesText)
            empty.textColor = .secondaryLabelColor
            views.append(empty)
        }
        for c in caps {
            let detail = NSTextField(labelWithString: (c.entitlements + c.settings).joined(separator: ", "))
            detail.font = .systemFont(ofSize: 10)
            detail.textColor = .secondaryLabelColor
            let remove = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete capability")!,
                                  target: self, action: #selector(removeCapabilityClicked(_:)))
            remove.isBordered = false
            remove.identifier = .init(c.rawValue)
            views.append(section(c.rawValue, detail, accessory: [remove]))
        }
        return page(views)
    }

    /// The "+ Capability" library panel; shown when the window is visible.
    @discardableResult
    public func capabilityLibrary() -> CapabilityLibraryController {
        let t = selectedTarget
        let present = Set(t.map { model.capabilities(target: $0, configuration: signingConfiguration) } ?? [])
        let lib = CapabilityLibraryController(present: present, error: t.flatMap { model.capabilityLibraryError(target: $0, configuration: signingConfiguration) })
        lib.onAdd = { [weak self] c in
            do { try self?.addCapability(c); return nil } catch { return "\(error)" }
        }
        if let w = view.window, w.isVisible {
            let panel = NSPanel(contentViewController: lib)
            panel.title = ProjectEditorModel.capabilityLibraryTitle
            panel.styleMask = [.titled, .closable, .resizable, .utilityWindow]
            panel.isReleasedWhenClosed = false
            panel.setFrameAutosaveName("")
            w.beginSheet(panel)
        }
        return lib
    }

    // MARK: Build Phases

    /// Build Phases: the "+" menu, then one collapsible section per phase
    /// with its table, +/− and (when removable) a trash button.
    func phasesView(_ t: String) -> NSView {
        let menu = NSPopUpButton(frame: .zero, pullsDown: true)
        menu.addItem(withTitle: "+")
        menu.autoenablesItems = false
        for m in model.addPhaseMenu(target: t) {
            let item = NSMenuItem(title: m.title, action: #selector(addPhaseChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m.isa
            item.isEnabled = m.enabled
            menu.menu?.addItem(item)
            if m.separatorAfter { menu.menu?.addItem(.separator()) }
        }
        menu.identifier = .init("addPhaseMenu")
        let filter = NSSearchField()
        filter.placeholderString = "Filter"
        filter.widthAnchor.constraint(equalToConstant: 180).isActive = true
        var views: [NSView] = [NSStackView(views: [menu, filter])]
        let synced = model.synchronizedPhaseItems(target: t)
        for s in model.phaseSections(target: t) {
            let extra = s.title == "Compile Sources" ? synced.sources : s.title == "Copy Bundle Resources" ? synced.resources : []
            let names = extra + s.items.map(\.name)
            let body: NSView
            if let shell = s.shell {
                let script = NSTextField(wrappingLabelWithString: s.script ?? "")
                script.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                script.preferredMaxLayoutWidth = 500
                let v = NSStackView(views: [NSTextField.cell("Shell: " + shell), script])
                v.orientation = .vertical
                v.alignment = .leading
                body = v
            } else {
                let columns = s.title == "Compile Sources" ? ["Name", "Compiler Flags"] : ["Name"]
                let rows = names.map { n -> [NSView] in columns.count == 2 ? [NSTextField.cell(n), NSTextField(string: "")] : [NSTextField.cell(n)] }
                let key = s.phaseID ?? s.title
                body = table(key, columns: columns, rows: rows, empty: "Add items here",
                             plus: s.phaseID == nil ? nil : #selector(phasePlusClicked(_:)), minus: s.phaseID == nil ? nil : #selector(phaseMinusClicked(_:)))
                if let pid = s.phaseID, let st = tables[key] {
                    st.identifier = pid
                    st.itemIDs = Array(repeating: "", count: extra.count) + s.items.map(\.id)
                }
            }
            var accessory: [NSView] = []
            if let pid = s.phaseID, ProjectEditorModel.phaseIsRemovable(s.title) {
                let trash = PhaseButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete phase")!, target: self,
                                        action: #selector(removePhaseClicked(_:)))
                trash.isBordered = false
                trash.value = pid
                accessory.append(trash)
            }
            views.append(section(ProjectEditorModel.phaseTitle(s.title, count: names.count), body, accessory: accessory))
        }
        return page(views)
    }

    @objc func addPhaseChosen(_ item: NSMenuItem) {
        if let isa = item.representedObject as? String { addBuildPhase(isa: isa) }
    }

    @objc func removePhaseClicked(_ b: PhaseButton) { removeBuildPhase(b.value) }

    func staticTable(of button: NSButton) -> StaticTable? {
        tables.values.first { $0.plusButton === button || $0.minusButton === button }
    }

    @objc func phasePlusClicked(_ b: NSButton) {
        guard let st = staticTable(of: b), let pid = st.identifier else { return }
        let pb = PhaseButton()
        pb.value = pid
        addPhaseItem(pb)
    }

    @objc func phaseMinusClicked(_ b: NSButton) {
        guard let st = staticTable(of: b), st.table.selectedRow >= 0, st.table.selectedRow < st.itemIDs.count else { return }
        let id = st.itemIDs[st.table.selectedRow]
        if !id.isEmpty { removeBuildFile(id) }
    }

    /// Adds an empty phase from the "+" menu. Returns its ID.
    @discardableResult
    public func addBuildPhase(isa: String) -> String? {
        guard let t = selectedTarget, model.addPhaseMenu(target: t).contains(where: { $0.isa == isa && $0.enabled }) else { return nil }
        let id = model.addBuildPhase(isa: isa, target: t)
        onChange?(model.proj)
        if tab == .buildPhases { showTab() }
        return id
    }

    /// The trash button: removes a phase and its build files.
    public func removeBuildPhase(_ id: String) {
        model.removeBuildPhase(id)
        onChange?(model.proj)
        if tab == .buildPhases { showTab() }
    }

    // MARK: Build Settings

    func buildSettingsView() -> NSView {
        let plus = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add setting")!, target: nil, action: nil)
        plus.bezelStyle = .smallSquare
        let filterControl = NSSegmentedControl(labels: ProjectEditorModel.Filter.allCases.map(\.rawValue), trackingMode: .selectOne,
                                               target: self, action: #selector(filterChosen(_:)))
        filterControl.selectedSegment = ProjectEditorModel.Filter.allCases.firstIndex(of: filter) ?? 1
        let viewControl = NSSegmentedControl(labels: ["Combined", "Levels"], trackingMode: .selectOne, target: self, action: #selector(viewChosen(_:)))
        viewControl.selectedSegment = settingsView.rawValue
        let namesControl = NSSegmentedControl(labels: ["Names", "Titles"], trackingMode: .selectOne, target: self, action: #selector(namesChosen(_:)))
        namesControl.selectedSegment = showsTitles ? 1 : 0
        let defsControl = NSSegmentedControl(labels: ["Definitions", "Values"], trackingMode: .selectOne, target: self, action: #selector(definitionsChosen(_:)))
        defsControl.selectedSegment = showsDefinitions ? 0 : 1
        let searchField = NSSearchField()
        searchField.stringValue = search
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let bar = NSStackView(views: [plus, filterControl, viewControl, namesControl, defsControl, searchField])
        bar.spacing = 10
        settingsTable.tableColumns.forEach(settingsTable.removeTableColumn)
        settingsTable.dataSource = self
        settingsTable.delegate = self
        settingsTable.usesAlternatingRowBackgroundColors = true
        settingsTable.rowSizeStyle = .small
        let scroll = NSScrollView()
        scroll.documentView = settingsTable
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        let stack = NSStackView(views: [bar, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        reloadSettings()
        return stack
    }

    @objc func namesChosen(_ s: NSSegmentedControl) { showsTitles = s.selectedSegment == 1 }
    @objc func definitionsChosen(_ s: NSSegmentedControl) { showsDefinitions = s.selectedSegment == 0 }

    /// Display title of a setting (Titles mode), or its name.
    public func displayName(_ name: String) -> String {
        showsTitles ? (ProjectEditorModel.settingTitles[name] ?? name) : name
    }

    /// Sections of the shown filter: Basic's fixed sections (with
    /// User-Defined), or the customized/all settings grouped the same way.
    func settingSections() -> [ProjectEditorModel.SettingSection] {
        let q = search.lowercased()
        func matches(_ n: String) -> Bool {
            q.isEmpty || n.lowercased().contains(q) || (ProjectEditorModel.settingTitles[n]?.lowercased().contains(q) ?? false)
        }
        if filter == .basic {
            return model.basicSettingSections(target: selectedTarget, configuration: configuration)
                .map { .init(title: $0.title, names: $0.names.filter(matches)) }.filter { !$0.names.isEmpty }
        }
        let names = model.settingRows(target: selectedTarget, configuration: configuration, filter: filter).map(\.name).filter(matches)
        var left = Set(names)
        var out: [ProjectEditorModel.SettingSection] = []
        for b in ProjectEditorModel.basicSections {
            let inSection = b.settings.map(\.name).filter(left.contains)
            if !inSection.isEmpty { out.append(.init(title: b.section, names: inSection)); left.subtract(inSection) }
        }
        // reference-ui-3.md §1.8: settings with no section go under User-Defined.
        if !left.isEmpty { out.append(.init(title: "User-Defined", names: left.sorted())) }
        return out
    }

    func reloadSettings() {
        guard isViewLoaded else { return }
        let sections = settingSections()
        let names = sections.flatMap(\.names)
        settingRows = model.settingRows(names: names, target: selectedTarget, configuration: configuration)
        rowByName = Dictionary(settingRows.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        perConfiguration = [:]
        configurationNames = model.configurations(of: selectedTarget).names
        if settingsView == .levels {
            for c in configurationNames {
                perConfiguration[c] = Dictionary(model.settingRows(names: names, target: selectedTarget, configuration: c).map { ($0.name, $0) },
                                                 uniquingKeysWith: { a, _ in a })
            }
        }
        settingsLines = []
        for s in sections {
            settingsLines.append(.section(s.title))
            guard !collapsedSettingSections.contains(s.title) else { continue }
            for n in s.names {
                settingsLines.append(.setting(n))
                if hasMultipleValues(n), expandedSettings.contains(n) {
                    settingsLines += configurationNames.map { .configuration(setting: n, name: $0) }
                }
            }
        }
        configureSettingColumns()
        settingsTable.reloadData()
    }

    /// Levels view: the setting resolves differently per configuration.
    public func hasMultipleValues(_ name: String) -> Bool {
        settingsView == .levels && Set(configurationNames.map { perConfiguration[$0]?[name]?.resolved ?? "" }).count > 1
    }

    func configureSettingColumns() {
        var cols: [(String, String, CGFloat)]
        if settingsView == .combined {
            cols = [("name", "Setting", 300), ("resolved", ProjectEditorModel.levelsColumnTitle(selectedTarget ?? model.projectName), 360)]
        } else {
            let titles = model.levelsColumnTitles(target: selectedTarget)
            cols = [("name", titles[0], 240), ("resolved", titles[1], 140)]
            let anyTargetXC = settingRows.contains { $0.targetXCConfig != nil }, anyProjectXC = settingRows.contains { $0.projectXCConfig != nil }
            if let t = selectedTarget {
                cols.append(("target", t, 120))
                if anyTargetXC { cols.append(("targetXCConfig", "Target xcconfig", 100)) }
            }
            cols.append(("project", model.projectName, 120))
            if anyProjectXC { cols.append(("projectXCConfig", "Project xcconfig", 100)) }
            cols.append(("defaults", titles.last ?? "Defaults", 120))
        }
        levelColumns = cols.map { ($0.0, $0.1) }
        guard settingsTable.tableColumns.map({ $0.identifier.rawValue }) != cols.map(\.0)
                || settingsTable.tableColumns.map(\.title) != cols.map(\.1) else { return }
        settingsTable.tableColumns.forEach(settingsTable.removeTableColumn)
        for (id, title, w) in cols {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = w
            settingsTable.addTableColumn(c)
        }
    }

    /// Whether a setting's row is drawn bold: defined at the shown level.
    public func settingIsBold(_ name: String) -> Bool {
        guard let r = rowByName[name] else { return false }
        return selectedTarget == nil ? (r.project != nil || r.projectXCConfig != nil) : (r.target != nil || r.targetXCConfig != nil)
    }

    /// Text of a settings-table cell (tests and drawing).
    public func settingsCellText(row: Int, column id: String) -> String? {
        switch settingsLines[row] {
        case .section(let t): return id == "name" ? t : nil
        case .setting(let n):
            guard let s = rowByName[n] else { return nil }
            if id == "name" { return displayName(n) }
            if hasMultipleValues(n) && (id == "resolved" || settingsView == .combined) { return ProjectEditorModel.multipleValues }
            return levelText(s, id)
        case .configuration(let n, let c):
            if id == "name" { return c }
            return perConfiguration[c]?[n].flatMap { levelText($0, id) }
        }
    }

    func levelText(_ s: ProjectEditorModel.SettingRow, _ id: String) -> String? {
        switch id {
        case "resolved":
            if showsDefinitions, let level = s.providingLevel { return levelText(s, level) }
            return s.resolved
        case "target": return s.target
        case "targetXCConfig": return s.targetXCConfig
        case "project": return s.project
        case "projectXCConfig": return s.projectXCConfig
        default: return s.defaults
        }
    }

    // MARK: Tables

    public func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === sidebar ? sidebarRowCount : settingsLines.count
    }

    public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if tableView === sidebar { return sidebarIsHeader(row) }
        if case .section = settingsLines[row] { return true }
        return false
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if tableView === sidebar { return !sidebarIsHeader(row) }
        if case .section = settingsLines[row] { return false }
        return true
    }

    public func tableViewSelectionDidChange(_ n: Notification) {
        guard (n.object as? NSTableView) === sidebar, sidebar.selectedRow >= 0 else { return }
        sidebarSelected(sidebar.selectedRow)
    }

    public func tableView(_ tableView: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        if tableView === sidebar { return sidebarCell(row) }
        switch settingsLines[row] {
        case .section(let title):
            let d = SettingDisclosure(title: "", target: self, action: #selector(settingSectionToggled(_:)))
            d.bezelStyle = .disclosure
            d.setButtonType(.pushOnPushOff)
            d.state = collapsedSettingSections.contains(title) ? .off : .on
            d.value = title
            let l = NSTextField(labelWithString: title)
            l.font = .boldSystemFont(ofSize: 11)
            return NSStackView(views: [d, l])
        case .setting(let n):
            guard let s = rowByName[n] else { return nil }
            let id = c?.identifier.rawValue ?? ""
            let text = settingsCellText(row: row, column: id)
            let multiple = hasMultipleValues(n)
            let editable = !multiple && ((settingsView == .combined && id == "resolved") || (id == (selectedTarget == nil ? "project" : "target")))
            let f = cellField(text, editable: editable, identifier: n, id: id)
            let bold = settingIsBold(n)
            if bold && (id == "name" || id == "resolved") { f.font = .boldSystemFont(ofSize: 11) }
            if settingsView == .levels, id == s.providingLevel, !multiple { outline(f) }
            if id == "name", multiple {
                let d = SettingDisclosure(title: "", target: self, action: #selector(settingExpansionToggled(_:)))
                d.bezelStyle = .disclosure
                d.setButtonType(.pushOnPushOff)
                d.state = expandedSettings.contains(n) ? .on : .off
                d.value = n
                return NSStackView(views: [d, f])
            }
            return f
        case .configuration(let n, let cfg):
            let id = c?.identifier.rawValue ?? ""
            let editable = id == (selectedTarget == nil ? "project" : "target")
            let f = cellField(settingsCellText(row: row, column: id), editable: editable, identifier: "cfg:\(cfg):\(n)", id: id)
            if id == "name" { f.stringValue = "      " + cfg }
            if id == perConfiguration[cfg]?[n]?.providingLevel { outline(f) }
            return f
        }
    }

    func cellField(_ text: String?, editable: Bool, identifier: String, id: String) -> NSTextField {
        let f = editable ? NSTextField(string: text ?? "") : NSTextField(labelWithString: text ?? "")
        f.font = id == "name" ? .systemFont(ofSize: 11) : Theme.font
        f.lineBreakMode = .byTruncatingMiddle
        f.cell?.truncatesLastVisibleLine = true
        f.toolTip = (text?.isEmpty ?? true) ? nil : text
        if editable {
            f.isBordered = false
            f.drawsBackground = false
            f.identifier = .init(identifier)
            f.delegate = self
        }
        return f
    }

    /// The cell of the level that supplies the value is outlined.
    func outline(_ f: NSTextField) {
        f.wantsLayer = true
        f.layer?.borderWidth = 1
        f.layer?.borderColor = NSColor.controlAccentColor.cgColor
        f.layer?.cornerRadius = 3
        f.identifier = f.identifier ?? .init("providing")
        f.setAccessibilityHelp("Supplies the resolved value")
    }

    final class SettingDisclosure: NSButton { var value = "" }

    @objc func settingSectionToggled(_ b: SettingDisclosure) {
        if collapsedSettingSections.contains(b.value) { collapsedSettingSections.remove(b.value) } else { collapsedSettingSections.insert(b.value) }
    }

    @objc func settingExpansionToggled(_ b: SettingDisclosure) {
        if expandedSettings.contains(b.value) { expandedSettings.remove(b.value) } else { expandedSettings.insert(b.value) }
    }
}

extension ProjectEditorModel {
    /// The Combined view's value column: the shown level's name.
    static func levelsColumnTitle(_ owner: String) -> String { owner }
}
