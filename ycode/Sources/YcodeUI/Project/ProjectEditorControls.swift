import AppKit
import YcodePlist
import YcodeProject

// The project editor's Resource Tags, Build Rules, Project ▸ Info and
// Package Dependencies tabs as real controls (reference-ui-5.md §11.1.3,
// P3; reference-ui-3.md §1.6, §1.10–§1.12): segmented scopes, tables with
// +/−, buttons and pop-ups. Every edit goes through the model and is
// reported with `onChange`.

// MARK: - Model

extension ProjectEditorModel {
    // MARK: Resource tags

    /// The project's resource tags (`KnownAssetTags` in the project's
    /// attributes), in their order.
    public var resourceTags: [String] {
        proj.project?["attributes"]?.dictionary?["KnownAssetTags"]?.array?.compactMap(\.string) ?? []
    }

    mutating func setResourceTags(_ tags: [String]) {
        guard var p = proj.project else { return }
        let had = p["attributes"] != nil
        var attrs = p["attributes"]?.dictionary ?? PlistDictionary()
        attrs["KnownAssetTags"] = tags.isEmpty ? nil : .array(tags.map(PlistValue.string))
        // A project without attributes stays without them.
        p["attributes"] = attrs.isEmpty && !had ? nil : .dictionary(attrs)
        proj[p.id] = p
    }

    /// Adds "New Tag" (made unique with " 2", " 3" …). Returns its name.
    @discardableResult
    public mutating func addResourceTag() -> String {
        let tags = resourceTags
        var name = "New Tag", n = 1
        while tags.contains(name) { n += 1; name = "New Tag \(n)" }
        setResourceTags(tags + [name])
        return name
    }

    /// Renames a tag everywhere: the tag list, build files' `ASSET_TAGS`
    /// and the on-demand settings of every configuration.
    public mutating func renameResourceTag(_ old: String, to new: String) {
        let n = new.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, old != n, !resourceTags.contains(n) else { return }
        setResourceTags(resourceTags.map { $0 == old ? n : $0 })
        rewriteTagUses { $0 == old ? n : $0 }
    }

    /// Removes a tag from the list, from build files and from the
    /// on-demand settings.
    public mutating func removeResourceTag(_ tag: String) {
        setResourceTags(resourceTags.filter { $0 != tag })
        rewriteTagUses { $0 == tag ? nil : $0 }
    }

    static let onDemandSettings = ["ON_DEMAND_RESOURCES_INITIAL_INSTALL_TAGS", "ON_DEMAND_RESOURCES_PREFETCH_ORDER"]

    private mutating func rewriteTagUses(_ map: (String) -> String?) {
        for (id, var o) in proj.objects where o.isa == "PBXBuildFile" {
            guard var settings = o["settings"]?.dictionary, let tags = settings["ASSET_TAGS"]?.array?.compactMap(\.string) else { continue }
            let mapped = tags.compactMap(map)
            guard mapped != tags else { continue }
            settings["ASSET_TAGS"] = mapped.isEmpty ? nil : .array(mapped.map(PlistValue.string))
            o["settings"] = settings.isEmpty ? nil : .dictionary(settings)
            proj[id] = o
        }
        for c in proj.objects.values where c.isa == "XCBuildConfiguration" {
            for s in Self.onDemandSettings {
                guard let v = c["buildSettings"]?.dictionary?[s]?.string else { continue }
                let mapped = v.split(separator: " ").map(String.init).compactMap(map).joined(separator: " ")
                if mapped != v { proj.setBuildSetting(s, mapped.isEmpty ? nil : .string(mapped), configuration: c.id) }
            }
        }
    }

    /// Number of resources (build files) carrying each tag.
    public var resourceTagUses: [String: Int] {
        var out: [String: Int] = [:]
        for o in proj.objects.values where o.isa == "PBXBuildFile" {
            for t in o["settings"]?.dictionary?["ASSET_TAGS"]?.array?.compactMap(\.string) ?? [] { out[t, default: 0] += 1 }
        }
        return out
    }

    /// The Prefetched scope's groups: Initial Install Tags, Prefetched Tag
    /// Order (from the target's on-demand settings) and the rest.
    public func prefetchGroups(target: String, configuration: String) -> [(title: String, tags: [String])] {
        let s = resolve(target: target, configuration: configuration)?.settings
        let initial = (s?["ON_DEMAND_RESOURCES_INITIAL_INSTALL_TAGS"] ?? "").split(separator: " ").map(String.init)
        let order = (s?["ON_DEMAND_RESOURCES_PREFETCH_ORDER"] ?? "").split(separator: " ").map(String.init)
        let rest = resourceTags.filter { !initial.contains($0) && !order.contains($0) }
        return [("Initial Install Tags", initial), ("Prefetched Tag Order", order), ("Download Only On Demand", rest)]
    }

    // MARK: Build rules

    /// Adds a custom script rule to a target (`PBXBuildRule`, file
    /// pattern input). Returns its ID.
    @discardableResult
    public mutating func addBuildRule(target name: String) -> String? {
        // Build rules belong to native targets (aggregate and legacy
        // targets have none).
        guard var t = target(named: name), t.isa == "PBXNativeTarget" else { return nil }
        let id = proj.makeObjectID()
        proj[id] = PBXObject(id: id, attributes: PlistDictionary([
            ("isa", "PBXBuildRule"), ("compilerSpec", "com.apple.compilers.proxy.script"), ("filePatterns", ""),
            ("fileType", "pattern.proxy"), ("inputFiles", .array([])), ("isEditable", "1"), ("outputFiles", .array([])),
            ("script", ""),
        ]))
        t["buildRules"] = .array((t.references("buildRules") + [id]).map(PlistValue.string))
        proj[t.id] = t
        return id
    }

    /// Removes a rule from its target and from the objects.
    public mutating func removeBuildRule(_ id: String) {
        for var t in proj.targets where t.references("buildRules").contains(id) {
            t["buildRules"] = .array(t.references("buildRules").filter { $0 != id }.map(PlistValue.string))
            proj[t.id] = t
        }
        proj[id] = nil
    }

    /// Copies a rule into a target's own rules. Returns the copy's ID.
    @discardableResult
    public mutating func copyBuildRule(_ id: String, toTarget name: String) -> String? {
        guard let rule = proj[id], var t = target(named: name), t.isa == "PBXNativeTarget" else { return nil }
        let copy = proj.makeObjectID()
        proj[copy] = PBXObject(id: copy, attributes: rule.attributes)
        t["buildRules"] = .array((t.references("buildRules") + [copy]).map(PlistValue.string))
        proj[t.id] = t
        return copy
    }

    /// Rule sections with their object IDs, sorted by rule name.
    public func ruleSectionIDs(target name: String) -> [(id: String, section: RuleSection)] {
        guard let t = target(named: name) else { return [] }
        return t.references("buildRules").compactMap { id in proj[id].map { (id, $0) } }.map { id, r in
            let input = r.string("fileType") == "pattern.proxy" ? (r.string("filePatterns") ?? "*") : (r.string("fileType") ?? r.string("filePatterns") ?? "?")
            let tool = r.string("compilerSpec") ?? "com.apple.compilers.proxy.script"
            let title = r.string("name") ?? "Files \(input.isEmpty ? "*" : input) using \(tool == "com.apple.compilers.proxy.script" ? "Script" : tool)"
            return (id, RuleSection(title: title, process: "Process: \(input)", using: "Using: \(tool)"))
        }.sorted { $0.1.title.localizedStandardCompare($1.1.title) == .orderedAscending }
    }

    // MARK: Project ▸ Info

    /// Duplicates a configuration in the project and every target, named
    /// "<name> copy" (made unique). Returns the new name.
    @discardableResult
    public mutating func duplicateConfiguration(_ name: String) -> String? {
        let owners = [proj.rootObject] + proj.targets.map(\.id)
        let existing = Set(configurations(of: nil).names)
        guard existing.contains(name) else { return nil }
        var new = "\(name) copy", n = 1
        while existing.contains(new) { n += 1; new = "\(name) copy \(n)" }
        for owner in owners {
            guard let listID = proj[owner]?.string("buildConfigurationList"), var list = proj[listID] else { continue }
            guard let source = proj.buildConfigurations(listID: listID).first(where: { $0.string("name") == name }) else { continue }
            let id = proj.makeObjectID()
            var attrs = source.attributes
            attrs["name"] = .string(new)
            proj[id] = PBXObject(id: id, attributes: attrs)
            list["buildConfigurations"] = .array((list.references("buildConfigurations") + [id]).map(PlistValue.string))
            proj[listID] = list
        }
        return new
    }

    /// Removes a configuration from the project and every target. The last
    /// configuration can't be removed; a list whose default it was falls
    /// back to its first remaining one.
    public mutating func removeConfiguration(_ name: String) {
        guard configurations(of: nil).names.count > 1 else { return }
        for owner in [proj.rootObject] + proj.targets.map(\.id) {
            guard let listID = proj[owner]?.string("buildConfigurationList"), var list = proj[listID] else { continue }
            let configs = proj.buildConfigurations(listID: listID)
            guard configs.count > 1, let gone = configs.first(where: { $0.string("name") == name }) else { continue }
            list["buildConfigurations"] = .array(list.references("buildConfigurations").filter { $0 != gone.id }.map(PlistValue.string))
            if list.string("defaultConfigurationName") == name {
                list["defaultConfigurationName"] = configs.first { $0.id != gone.id }?.string("name").map(PlistValue.string)
            }
            proj[listID] = list
            proj[gone.id] = nil
        }
    }

    /// "Use [<config>] for command-line builds": the project list's
    /// `defaultConfigurationName`.
    public mutating func setCommandLineConfiguration(_ name: String) {
        guard let listID = proj.project?.string("buildConfigurationList"), var list = proj[listID],
              configurations(of: nil).names.contains(name) else { return }
        list["defaultConfigurationName"] = .string(name)
        proj[listID] = list
    }

    /// The Parallelize checkbox: `BuildIndependentTargetsInParallel`.
    public mutating func setParallelizeCommandLine(_ on: Bool) {
        guard var p = proj.project else { return }
        var attrs = p["attributes"]?.dictionary ?? PlistDictionary()
        attrs["BuildIndependentTargetsInParallel"] = .string(on ? "1" : "0")
        p["attributes"] = .dictionary(attrs)
        proj[p.id] = p
    }

    var knownRegions: [String] { proj.project?["knownRegions"]?.array?.compactMap(\.string) ?? [] }

    mutating func setKnownRegions(_ regions: [String]) {
        guard var p = proj.project else { return }
        p["knownRegions"] = .array(regions.map(PlistValue.string))
        proj[p.id] = p
    }

    /// Localizations rows: (region code, display name, is development
    /// region, files localized), without Base.
    public var localizationRows: [(code: String, name: String, isDefault: Bool, files: Int)] {
        let dev = proj.project?.string("developmentRegion") ?? "en"
        let names = Locale(identifier: "en")
        var counts: [String: Int] = [:]
        for g in proj.objects.values where g.isa == "PBXVariantGroup" {
            for c in g.references("children") { if let n = proj[c]?.string("name") { counts[n, default: 0] += 1 } }
        }
        return knownRegions.filter { $0 != "Base" }.map { r in
            (r, (names.localizedString(forIdentifier: r) ?? r) + (r == dev ? " (Development Language)" : ""), r == dev, counts[r] ?? 0)
        }
    }

    public static func filesLocalizedText(_ n: Int) -> String { "\(n) File\(n == 1 ? "" : "s") Localized" }

    /// Languages the Localizations "+" menu offers (ISO codes).
    public static let addableLocalizations = ["ar", "ca", "zh-Hans", "zh-Hant", "hr", "cs", "da", "nl", "en-GB", "fi", "fr", "de", "el",
                                              "he", "hi", "hu", "id", "it", "ja", "ko", "ms", "nb", "pl", "pt-BR", "pt-PT", "ro", "ru",
                                              "sk", "es", "es-419", "sv", "th", "tr", "uk", "vi"]

    public mutating func addLocalization(_ code: String) {
        guard !knownRegions.contains(code) else { return }
        setKnownRegions(knownRegions + [code])
    }

    /// Removes a localization; the development language stays.
    public mutating func removeLocalization(_ code: String) {
        guard code != (proj.project?.string("developmentRegion") ?? "en") else { return }
        setKnownRegions(knownRegions.filter { $0 != code })
    }

    /// "Set Default": the development region.
    public mutating func setDevelopmentRegion(_ code: String) {
        guard var p = proj.project, knownRegions.contains(code) else { return }
        p["developmentRegion"] = .string(code)
        proj[p.id] = p
    }

    /// "Use Base Internationalization": Base in `knownRegions`.
    public mutating func setUsesBaseInternationalization(_ on: Bool) {
        let r = knownRegions.filter { $0 != "Base" }
        setKnownRegions(on ? r + ["Base"] : r)
    }

    /// Per configuration, the project's and each target's base
    /// configuration file name ("None" when unset).
    public func configurationFiles(_ name: String) -> [(owner: String, file: String)] {
        ([(projectName, proj.rootObject)] + proj.targets.map { ($0.string("name") ?? "", $0.id) }).map { owner, id in
            let c = proj.buildConfigurations(listID: proj[id]?.string("buildConfigurationList")).first { $0.string("name") == name }
            let f = c?.string("baseConfigurationReference").flatMap { proj[$0] }
                .flatMap { $0.string("name") ?? $0.string("path").map { ($0 as NSString).lastPathComponent } }
            return (owner, f ?? "None")
        }
    }
}

// MARK: - Views

extension ProjectEditorController {
    func filterField(_ key: String, value: String) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = "Filter"
        f.stringValue = value
        f.identifier = .init(key)
        f.target = self
        f.action = #selector(tabFilterChanged(_:))
        f.sendsSearchStringImmediately = true
        f.widthAnchor.constraint(equalToConstant: 180).isActive = true
        return f
    }

    @objc func tabFilterChanged(_ f: NSSearchField) {
        tabFilters[f.identifier?.rawValue ?? ""] = f.stringValue
        showTab()
    }

    func matchesFilter(_ key: String, _ s: String) -> Bool {
        let q = tabFilters[key] ?? ""
        return q.isEmpty || s.localizedCaseInsensitiveContains(q)
    }

    func symbolButton(_ symbol: String, _ label: String, _ action: Selector, id: String = "") -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        b.bezelStyle = .smallSquare
        b.toolTip = label
        b.identifier = .init(id)
        return b
    }

    // MARK: Resource Tags

    func resourceTagsView(_ t: String) -> NSView {
        let plus = symbolButton("plus", "Add resource tag", #selector(addResourceTagClicked), id: "addResourceTag")
        let scope = NSSegmentedControl(labels: ProjectEditorModel.resourceTagScopes, trackingMode: .selectOne, target: self,
                                       action: #selector(resourceTagScopeChosen(_:)))
        scope.selectedSegment = ProjectEditorModel.resourceTagScopes.firstIndex(of: resourceTagScope) ?? 0
        scope.identifier = .init("resourceTagScope")
        let bar = NSStackView(views: [plus, scope, filterField("resourceTags", value: tabFilters["resourceTags"] ?? "")])
        bar.spacing = 10
        var views: [NSView] = [bar]
        let tags = model.resourceTags.filter { matchesFilter("resourceTags", $0) }
        if model.resourceTags.isEmpty {
            let empty = NSTextField(labelWithString: ProjectEditorModel.resourceTagsEmptyText)
            empty.textColor = .secondaryLabelColor
            empty.identifier = .init("resourceTagsEmpty")
            views.append(empty)
        } else if resourceTagScope == "All" {
            let uses = model.resourceTagUses
            let rows = tags.map { tag -> [NSView] in
                let name = NSTextField(string: tag)
                name.isBordered = false
                name.drawsBackground = false
                name.identifier = .init("tag:" + tag)
                name.delegate = self
                return [name, NSTextField.cell(ProjectEditorModel.resourceCountText(uses[tag] ?? 0))]
            }
            views.append(table("Resource Tags", columns: ["Tag", "Resources"], rows: rows, plus: #selector(addResourceTagClicked),
                               minus: #selector(removeResourceTagClicked(_:))))
            tables["Resource Tags"]?.itemIDs = tags
        } else {
            for g in model.prefetchGroups(target: t, configuration: configuration) {
                let rows = g.tags.filter { matchesFilter("resourceTags", $0) }.map { [NSTextField.cell($0)] as [NSView] }
                views.append(section(g.title, table(g.title, columns: ["Tag"], rows: rows, empty: "No Tags")))
            }
        }
        return page(views)
    }

    @objc func resourceTagScopeChosen(_ s: NSSegmentedControl) { setResourceTagScope(ProjectEditorModel.resourceTagScopes[max(0, s.selectedSegment)]) }

    public func setResourceTagScope(_ s: String) {
        guard ProjectEditorModel.resourceTagScopes.contains(s) else { return }
        resourceTagScope = s
        if tab == .resourceTags { showTab() }
    }

    @objc func addResourceTagClicked() { addResourceTag() }

    @discardableResult
    public func addResourceTag() -> String {
        let n = model.addResourceTag()
        onChange?(model.proj)
        showTab()
        return n
    }

    public func removeResourceTag(_ tag: String) {
        model.removeResourceTag(tag)
        onChange?(model.proj)
        showTab()
    }

    public func renameResourceTag(_ old: String, to new: String) {
        model.renameResourceTag(old, to: new)
        onChange?(model.proj)
        showTab()
    }

    @objc func removeResourceTagClicked(_ b: NSButton) {
        guard let st = tables["Resource Tags"] else { return }
        let r = st.table.selectedRow
        if r >= 0, r < st.itemIDs.count { removeResourceTag(st.itemIDs[r]) }
    }

    // MARK: Build Rules

    func buildRulesView(_ t: String) -> NSView {
        let plus = symbolButton("plus", "Add build rule", #selector(addBuildRuleClicked), id: "addBuildRule")
        let scope = NSSegmentedControl(labels: ProjectEditorModel.buildRuleScopes, trackingMode: .selectOne, target: self,
                                       action: #selector(buildRuleScopeChosen(_:)))
        scope.selectedSegment = ProjectEditorModel.buildRuleScopes.firstIndex(of: buildRuleScope) ?? 0
        scope.identifier = .init("buildRuleScope")
        let bar = NSStackView(views: [plus, scope, filterField("buildRules", value: tabFilters["buildRules"] ?? "")])
        bar.spacing = 10
        var views: [NSView] = [bar]
        for (id, r) in model.ruleSectionIDs(target: t) where matchesFilter("buildRules", r.title) {
            let process = NSTextField(labelWithString: r.process)
            let using = NSTextField(labelWithString: r.using)
            using.textColor = .secondaryLabelColor
            let copy = NSButton(title: "Copy to Target", target: self, action: #selector(copyRuleClicked(_:)))
            copy.identifier = .init("copy:" + id)
            copy.controlSize = .small
            let body = NSStackView(views: [process, using, copy])
            body.orientation = .vertical
            body.alignment = .leading
            let trash = symbolButton("trash", "Delete build rule", #selector(removeRuleClicked(_:)), id: "remove:" + id)
            trash.isBordered = false
            views.append(section(r.title, body, accessory: [trash]))
        }
        return page(views)
    }

    @objc func buildRuleScopeChosen(_ s: NSSegmentedControl) {
        buildRuleScope = ProjectEditorModel.buildRuleScopes[max(0, s.selectedSegment)]
        if tab == .buildRules { showTab() }
    }

    @objc func addBuildRuleClicked() { addBuildRule() }

    @discardableResult
    public func addBuildRule() -> String? {
        guard let t = selectedTarget else { return nil }
        let id = model.addBuildRule(target: t)
        onChange?(model.proj)
        showTab()
        return id
    }

    public func removeBuildRule(_ id: String) {
        model.removeBuildRule(id)
        onChange?(model.proj)
        showTab()
    }

    @discardableResult
    public func copyBuildRule(_ id: String) -> String? {
        guard let t = selectedTarget else { return nil }
        let copy = model.copyBuildRule(id, toTarget: t)
        onChange?(model.proj)
        showTab()
        return copy
    }

    @objc func copyRuleClicked(_ b: NSButton) { if let id = b.identifier?.rawValue.dropFirst("copy:".count) { copyBuildRule(String(id)) } }
    @objc func removeRuleClicked(_ b: NSButton) { if let id = b.identifier?.rawValue.dropFirst("remove:".count) { removeBuildRule(String(id)) } }

    // MARK: Project ▸ Info

    func projectInfoView() -> NSView {
        let info = model.projectInfo
        var configRows: [[NSView]] = []
        var configIDs: [String] = []
        for name in info.configurations {
            let open = expandedConfigurations.contains(name)
            let d = NSButton(title: (open ? "\u{25BE} " : "\u{25B8} ") + name, target: self, action: #selector(configurationDisclosureClicked(_:)))
            d.isBordered = false
            d.alignment = .left
            d.identifier = .init("config:" + name)
            let files = model.configurationFiles(name)
            let summary = Set(files.map(\.file)) == ["None"] ? ProjectEditorModel.noConfigurationsText
                : "\(files.filter { $0.file != "None" }.count) Configuration\(files.filter { $0.file != "None" }.count == 1 ? "" : "s") Set"
            configRows.append([d, NSTextField.cell(summary)])
            configIDs.append(name)
            if open {
                for f in files {
                    configRows.append([NSTextField.cell("    " + f.owner), NSTextField.cell(f.file)])
                    configIDs.append(name)
                }
            }
        }
        let configs = table("Configurations", columns: ["Name", "Based on Configuration File"], rows: configRows,
                            plus: #selector(duplicateConfigurationClicked(_:)), minus: #selector(removeConfigurationClicked(_:)))
        tables["Configurations"]?.itemIDs = configIDs

        let cmd = NSPopUpButton(frame: .zero, pullsDown: false)
        cmd.addItems(withTitles: info.configurations)
        if let c = info.commandLineConfiguration { cmd.selectItem(withTitle: c) }
        cmd.target = self
        cmd.action = #selector(commandLineConfigurationChosen(_:))
        cmd.identifier = .init("commandLineConfiguration")
        let cmdRow = NSStackView(views: [NSTextField(labelWithString: "Use"), cmd, NSTextField(labelWithString: "for command-line builds")])
        let parallel = NSButton(checkboxWithTitle: ProjectEditorModel.parallelizeTitle, target: self, action: #selector(parallelizeToggled(_:)))
        parallel.state = info.parallelizeCommandLine ? .on : .off
        parallel.identifier = .init("parallelize")

        let locRows = model.localizationRows.map { r -> [NSView] in
            [NSTextField.cell(r.name), NSTextField.cell(r.isDefault ? "Default" : ""), NSTextField.cell(ProjectEditorModel.filesLocalizedText(r.files))]
        }
        let locs = table("Localizations", columns: ["Localization", "Default", "Resources"], rows: locRows,
                         plus: #selector(addLocalizationClicked(_:)), minus: #selector(removeLocalizationClicked(_:)))
        tables["Localizations"]?.itemIDs = model.localizationRows.map(\.code)
        let setDefault = NSButton(title: "Set Default", target: self, action: #selector(setDefaultLocalizationClicked(_:)))
        setDefault.identifier = .init("setDefaultLocalization")
        setDefault.controlSize = .small
        let base = NSButton(checkboxWithTitle: "Use Base Internationalization", target: self, action: #selector(baseInternationalizationToggled(_:)))
        base.state = info.usesBaseInternationalization ? .on : .off
        base.identifier = .init("useBaseInternationalization")
        let configBody = NSStackView(views: [configs, cmdRow, parallel])
        configBody.orientation = .vertical
        configBody.alignment = .leading
        let locBody = NSStackView(views: [locs, setDefault, base])
        locBody.orientation = .vertical
        locBody.alignment = .leading
        return page([section("Configurations", configBody), section("Localizations", locBody)])
    }

    public func toggleConfiguration(_ name: String) {
        if expandedConfigurations.contains(name) { expandedConfigurations.remove(name) } else { expandedConfigurations.insert(name) }
        showTab()
    }

    @objc func configurationDisclosureClicked(_ b: NSButton) {
        if let n = b.identifier?.rawValue.dropFirst("config:".count) { toggleConfiguration(String(n)) }
    }

    func selectedItemID(_ table: String) -> String? {
        guard let st = tables[table] else { return nil }
        let r = st.table.selectedRow
        return r >= 0 && r < st.itemIDs.count ? st.itemIDs[r] : nil
    }

    @objc func duplicateConfigurationClicked(_ b: NSButton) {
        guard let w = view.window, w.isVisible else { return }
        let menu = NSMenu()
        for c in model.projectInfo.configurations {
            let item = NSMenuItem(title: "Duplicate \u{201C}\(c)\u{201D} Configuration", action: #selector(duplicateConfigurationChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = c
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }

    @objc func duplicateConfigurationChosen(_ i: NSMenuItem) { if let c = i.representedObject as? String { duplicateConfiguration(c) } }

    @discardableResult
    public func duplicateConfiguration(_ name: String) -> String? {
        let n = model.duplicateConfiguration(name)
        onChange?(model.proj)
        select(target: selectedTarget, tab: tab)
        return n
    }

    @objc func removeConfigurationClicked(_ b: NSButton) {
        guard let name = selectedItemID("Configurations") else { return }
        removeConfiguration(name)
    }

    public func removeConfiguration(_ name: String) {
        model.removeConfiguration(name)
        expandedConfigurations.remove(name)
        onChange?(model.proj)
        select(target: selectedTarget, tab: tab)
    }

    @objc func commandLineConfigurationChosen(_ p: NSPopUpButton) { if let c = p.titleOfSelectedItem { setCommandLineConfiguration(c) } }

    public func setCommandLineConfiguration(_ name: String) {
        model.setCommandLineConfiguration(name)
        onChange?(model.proj)
        showTab()
    }

    @objc func parallelizeToggled(_ b: NSButton) { setParallelizeCommandLine(b.state == .on) }

    public func setParallelizeCommandLine(_ on: Bool) {
        model.setParallelizeCommandLine(on)
        onChange?(model.proj)
        showTab()
    }

    @objc func addLocalizationClicked(_ b: NSButton) {
        guard let w = view.window, w.isVisible else { return }
        let menu = NSMenu()
        let names = Locale(identifier: "en")
        let have = Set(model.localizationRows.map(\.code))
        for code in ProjectEditorModel.addableLocalizations where !have.contains(code) {
            let item = NSMenuItem(title: "\(names.localizedString(forIdentifier: code) ?? code) (\(code))", action: #selector(addLocalizationChosen(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = code
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }

    @objc func addLocalizationChosen(_ i: NSMenuItem) { if let c = i.representedObject as? String { addLocalization(c) } }

    public func addLocalization(_ code: String) {
        model.addLocalization(code)
        onChange?(model.proj)
        showTab()
    }

    @objc func removeLocalizationClicked(_ b: NSButton) { if let c = selectedItemID("Localizations") { removeLocalization(c) } }

    public func removeLocalization(_ code: String) {
        model.removeLocalization(code)
        onChange?(model.proj)
        showTab()
    }

    @objc func setDefaultLocalizationClicked(_ b: NSButton) { if let c = selectedItemID("Localizations") { setDevelopmentRegion(c) } }

    public func setDevelopmentRegion(_ code: String) {
        model.setDevelopmentRegion(code)
        onChange?(model.proj)
        showTab()
    }

    @objc func baseInternationalizationToggled(_ b: NSButton) { setUsesBaseInternationalization(b.state == .on) }

    public func setUsesBaseInternationalization(_ on: Bool) {
        model.setUsesBaseInternationalization(on)
        onChange?(model.proj)
        showTab()
    }

    // MARK: Package Dependencies

    func packageDependenciesView() -> NSView {
        let rows = packageRows
        let cells = rows.map { r -> [NSView] in [NSTextField.cell(r.name), NSTextField.cell(r.location), NSTextField.cell(r.rule)] }
        let body = table("Packages", columns: ["Name", "Location", "Dependency Rule"], rows: cells, empty: ProjectEditorModel.packagesEmptyText,
                         plus: #selector(addPackageButtonClicked), minus: #selector(removePackageClicked(_:)), width: 640)
        tables["Packages"]?.itemIDs = rows.map(\.id)
        return page([section(ProjectEditorModel.packagesHeader(count: rows.count), body)])
    }

    @objc func addPackageButtonClicked() { onAddPackage?() }

    @objc func removePackageClicked(_ b: NSButton) { if let id = selectedItemID("Packages") { removePackage(id) } }
}

extension ProjectEditorModel {
    public static func resourceCountText(_ n: Int) -> String { "\(n) Resource\(n == 1 ? "" : "s")" }
}
