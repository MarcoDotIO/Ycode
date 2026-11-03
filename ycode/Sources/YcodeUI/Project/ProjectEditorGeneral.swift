import AppKit
import YcodeIDECore
import YcodePlist
import YcodeProject

extension ProjectEditorController {
    /// The Identity grid with each row's "+" or "→".
    func identityBody(_ t: String) -> NSView {
        func accessory(_ row: ProjectEditorModel.IdentityRow) -> NSButton {
            let inInfo = model.identityRowInInfo(row, target: t, configuration: configuration)
            let b = NSButton(image: NSImage(systemSymbolName: inInfo ? "arrow.right.circle" : "plus.circle",
                                            accessibilityDescription: inInfo ? "Show in Build Settings" : "Add to Info")!,
                             target: self, action: #selector(identityAccessoryClicked(_:)))
            b.isBordered = false
            b.identifier = .init((inInfo ? "reveal:" : "add:") + row.setting)
            b.toolTip = inInfo ? "Show \(row.setting) in Build Settings" : "Add \(row.infoKey) to Info"
            return b
        }
        var rows: [(String, NSView)] = []
        for row in ProjectEditorModel.identityRows {
            let control: NSView
            switch row.title {
            case "App Category":
                let category = NSPopUpButton(frame: .zero, pullsDown: false)
                category.addItem(withTitle: "None")
                category.menu?.addItem(.separator())
                for c in ProjectEditorModel.appCategories {
                    category.addItem(withTitle: c.title)
                    category.lastItem?.representedObject = c.value
                }
                let current = resolved(row.setting, target: t)
                if let c = ProjectEditorModel.appCategories.first(where: { $0.value == current }) { category.selectItem(withTitle: c.title) }
                else if !current.isEmpty { category.addItem(withTitle: current); category.selectItem(withTitle: current) }
                category.target = self
                category.action = #selector(appCategoryChosen(_:))
                category.identifier = .init(row.setting)
                control = category
            case "Display Name": control = settingField(row.setting, target: t, placeholder: "Display Name")
            case "Bundle Identifier": control = settingField(row.setting, target: t)
            default: control = settingField(row.setting, target: t, width: 120)
            }
            rows.append((row.title, NSStackView(views: [control, accessory(row)])))
        }
        return grid(rows)
    }

    @objc func appCategoryChosen(_ p: NSPopUpButton) {
        setSetting("INFOPLIST_KEY_LSApplicationCategoryType", p.selectedItem?.representedObject as? String ?? "")
        showTab()
    }

    @objc func identityAccessoryClicked(_ b: NSButton) {
        let id = b.identifier?.rawValue ?? ""
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let row = ProjectEditorModel.identityRows.first(where: { $0.setting == parts[1] }) else { return }
        if parts[0] == "reveal" { revealSetting(row.setting) } else { addIdentityKeyToInfo(row) }
    }

    /// "+" of an Identity row.
    public func addIdentityKeyToInfo(_ row: ProjectEditorModel.IdentityRow) {
        guard let t = selectedTarget else { return }
        try? model.addIdentityKeyToInfo(row, target: t, configuration: configuration)
        onChange?(model.proj)
        showTab()
    }

    /// "→": Build Settings, All, filtered to the setting, its row selected.
    public func revealSetting(_ name: String) {
        filter = .all
        search = name
        select(tab: .buildSettings)
        if let row = settingsLines.firstIndex(of: .setting(name)) {
            settingsTable.selectRowIndexes([row], byExtendingSelection: false)
            settingsTable.scrollRowToVisible(row)
        }
    }

    // MARK: Supported Destinations and Minimum Deployments

    @objc func destinationPlusClicked(_ b: NSButton) {
        guard let t = selectedTarget, let w = view.window, w.isVisible else { return }
        let menu = NSMenu()
        for d in model.addableDestinations(target: t, configuration: configuration) {
            let item = NSMenuItem(title: d, action: #selector(destinationChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = d
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }

    @objc func destinationChosen(_ i: NSMenuItem) { if let d = i.representedObject as? String { addDestination(d) } }

    @objc func destinationMinusClicked(_ b: NSButton) {
        guard let st = tables["Supported Destinations"] else { return }
        let r = st.table.selectedRow
        if r >= 0, r < st.itemIDs.count { removeDestination(st.itemIDs[r]) }
    }

    public func addDestination(_ name: String) {
        guard let t = selectedTarget else { return }
        model.addDestination(name, target: t, configuration: configuration)
        onChange?(model.proj)
        showTab()
    }

    public func removeDestination(_ name: String) {
        guard let t = selectedTarget else { return }
        model.removeDestination(name, target: t, configuration: configuration)
        onChange?(model.proj)
        showTab()
    }

    @objc func deploymentPlusClicked(_ b: NSButton) {
        guard let t = selectedTarget, let w = view.window, w.isVisible else { return }
        let menu = NSMenu()
        for sdk in model.addableDeploymentSDKs(target: t, configuration: configuration) {
            let item = NSMenuItem(title: sdk, action: #selector(deploymentPlatformChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = sdk
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }

    @objc func deploymentPlatformChosen(_ i: NSMenuItem) { if let s = i.representedObject as? String { addDeploymentPlatform(s) } }

    public func addDeploymentPlatform(_ sdk: String) {
        guard let t = selectedTarget else { return }
        model.addDeploymentPlatform(sdk, target: t, configuration: configuration)
        onChange?(model.proj)
        showTab()
    }
}
