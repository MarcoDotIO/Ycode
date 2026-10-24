import AppKit
import YcodePlist
import YcodeProject

// General tab edits (reference-ui-5.md §11.1.6, P6): Supported
// Destinations +/− write the settings named in reference-ui-3.md §1.4.1;
// Minimum Deployments "+" adds a platform row; the Identity rows' "+"
// adds the key to Info and "→" reveals the setting in Build Settings.

extension ProjectEditorModel {
    /// Every destination the "+" menu can offer, in menu order.
    public static let destinationChoices = [
        "iPhone", "iPad", "Mac (Mac Catalyst)", "Mac (Designed for iPad)", "Apple Vision (Designed for iPad)",
        "Mac", "Apple Vision", "Apple TV", "Apple Watch",
    ]

    /// Platform settings per SDK: (`SUPPORTED_PLATFORMS` entries, device
    /// family, deployment-target setting).
    static let sdkPlatforms: [String: (platforms: [String], family: String?, deployment: String)] = [
        "iOS": (["iphoneos", "iphonesimulator"], nil, "IPHONEOS_DEPLOYMENT_TARGET"),
        "macOS": (["macosx"], nil, "MACOSX_DEPLOYMENT_TARGET"),
        "visionOS": (["xros", "xrsimulator"], "7", "XROS_DEPLOYMENT_TARGET"),
        "tvOS": (["appletvos", "appletvsimulator"], "3", "TVOS_DEPLOYMENT_TARGET"),
        "watchOS": (["watchos", "watchsimulator"], "4", "WATCHOS_DEPLOYMENT_TARGET"),
    ]

    /// The destination that stands for an SDK when a platform row is added.
    static let primaryDestination = ["iOS": "iPhone", "macOS": "Mac", "visionOS": "Apple Vision", "tvOS": "Apple TV", "watchOS": "Apple Watch"]

    public static let deploymentVersions = ["27.0", "26.0", "18.0", "17.0"]

    /// Destinations the "+" menu offers: those not present. The iPad-app
    /// variants need iPhone or iPad.
    public func addableDestinations(target: String, configuration: String) -> [String] {
        let present = Set(supportedDestinations(target: target, configuration: configuration).map(\.name))
        let ios = present.contains("iPhone") || present.contains("iPad")
        return Self.destinationChoices.filter { d in
            guard !present.contains(d) else { return false }
            switch d {
            case "Mac (Mac Catalyst)", "Mac (Designed for iPad)": return ios && !present.contains("Mac (Mac Catalyst)") && !present.contains("Mac (Designed for iPad)")
            case "Apple Vision (Designed for iPad)": return ios && !present.contains("Apple Vision")
            default: return true
            }
        }
    }

    private func platformSettings(target: String, configuration: String) -> (platforms: [String], families: [String]) {
        let s = resolve(target: target, configuration: configuration)?.settings
        var p = (s?["SUPPORTED_PLATFORMS"] ?? "").split(separator: " ").map(String.init)
        if p.isEmpty, let root = s?["SDKROOT"], !root.isEmpty {
            p = Self.sdkPlatforms.values.first { $0.platforms.first == root }?.platforms ?? [root]
        }
        let f = (s?["TARGETED_DEVICE_FAMILY"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return (p, f)
    }

    private mutating func writePlatforms(_ p: [String], _ f: [String], target: String) {
        setSetting("SUPPORTED_PLATFORMS", p.joined(separator: " "), target: target)
        let families = Set(f).sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        setSetting("TARGETED_DEVICE_FAMILY", families.joined(separator: ","), target: target)
    }

    /// Adds a destination by writing the platform settings at target level.
    public mutating func addDestination(_ name: String, target: String, configuration: String) {
        var (p, f) = platformSettings(target: target, configuration: configuration)
        func add(_ sdk: String) {
            for x in Self.sdkPlatforms[sdk]?.platforms ?? [] where !p.contains(x) { p.append(x) }
            if let fam = Self.sdkPlatforms[sdk]?.family, !f.contains(fam) { f.append(fam) }
        }
        switch name {
        case "iPhone": add("iOS"); if !f.contains("1") { f.append("1") }
        case "iPad": add("iOS"); if !f.contains("2") { f.append("2") }
        case "Mac (Mac Catalyst)":
            setSetting("SUPPORTS_MACCATALYST", "YES", target: target)
            setSetting("SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD", "NO", target: target)
            return
        case "Mac (Designed for iPad)":
            setSetting("SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD", "YES", target: target)
            return
        case "Apple Vision (Designed for iPad)":
            setSetting("SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD", "YES", target: target)
            return
        case "Mac": add("macOS")
        case "Apple Vision": add("visionOS")
        case "Apple TV": add("tvOS")
        case "Apple Watch": add("watchOS")
        default: return
        }
        writePlatforms(p, f, target: target)
    }

    /// Removes a destination; removing the last iOS device also turns off
    /// the iPad-app variants. The last destination stays.
    public mutating func removeDestination(_ name: String, target: String, configuration: String) {
        let present = supportedDestinations(target: target, configuration: configuration).map(\.name)
        guard present.contains(name), present.count > 1 else { return }
        var (p, f) = platformSettings(target: target, configuration: configuration)
        func drop(_ sdk: String) {
            p.removeAll { (Self.sdkPlatforms[sdk]?.platforms ?? []).contains($0) }
            if let fam = Self.sdkPlatforms[sdk]?.family { f.removeAll { $0 == fam } }
        }
        switch name {
        case "iPhone", "iPad":
            f.removeAll { $0 == (name == "iPhone" ? "1" : "2") }
            if !f.contains("1") && !f.contains("2") {
                drop("iOS")
                for s in ["SUPPORTS_MACCATALYST", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD", "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD"] {
                    setSetting(s, "NO", target: target)
                }
            }
        case "Mac (Mac Catalyst)": setSetting("SUPPORTS_MACCATALYST", "NO", target: target); return
        case "Mac (Designed for iPad)": setSetting("SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD", "NO", target: target); return
        case "Apple Vision (Designed for iPad)": setSetting("SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD", "NO", target: target); return
        case "Mac": drop("macOS")
        case "Apple Vision": drop("visionOS")
        case "Apple TV": drop("tvOS")
        case "Apple Watch": drop("watchOS")
        default: return
        }
        writePlatforms(p, f, target: target)
    }

    /// SDKs the Minimum Deployments "+" can add (those without a row).
    public func addableDeploymentSDKs(target: String, configuration: String) -> [String] {
        let have = Set(minimumDeployments(target: target, configuration: configuration).map(\.sdk))
        return ["iOS", "macOS", "visionOS", "tvOS", "watchOS"].filter { !have.contains($0) }
    }

    /// Adds a platform row: the SDK's primary destination and its
    /// deployment target (the newest version offered).
    public mutating func addDeploymentPlatform(_ sdk: String, target: String, configuration: String) {
        guard let d = Self.primaryDestination[sdk], let setting = Self.sdkPlatforms[sdk]?.deployment else { return }
        addDestination(d, target: target, configuration: configuration)
        if resolve(target: target, configuration: configuration)?.settings[setting].isEmpty ?? true {
            setSetting(setting, Self.deploymentVersions[0], target: target)
        }
    }

    // MARK: Identity

    /// An Identity row: its title, the build setting it edits, and the
    /// Info.plist key it stands for.
    public struct IdentityRow: Equatable, Sendable {
        public var title: String
        public var setting: String
        public var infoKey: String
        /// The value Info gets when "+" adds the key.
        public var infoValue: String
    }

    public static let identityRows: [IdentityRow] = [
        .init(title: "App Category", setting: "INFOPLIST_KEY_LSApplicationCategoryType", infoKey: "LSApplicationCategoryType", infoValue: ""),
        .init(title: "Display Name", setting: "INFOPLIST_KEY_CFBundleDisplayName", infoKey: "CFBundleDisplayName", infoValue: "$(PRODUCT_NAME)"),
        .init(title: "Bundle Identifier", setting: "PRODUCT_BUNDLE_IDENTIFIER", infoKey: "CFBundleIdentifier", infoValue: "$(PRODUCT_BUNDLE_IDENTIFIER)"),
        .init(title: "Version", setting: "MARKETING_VERSION", infoKey: "CFBundleShortVersionString", infoValue: "$(MARKETING_VERSION)"),
        .init(title: "Build", setting: "CURRENT_PROJECT_VERSION", infoKey: "CFBundleVersion", infoValue: "$(CURRENT_PROJECT_VERSION)"),
    ]

    /// App categories (`LSApplicationCategoryType`, public values).
    public static let appCategories: [(title: String, value: String)] = [
        ("Business", "business"), ("Developer Tools", "developer-tools"), ("Education", "education"), ("Entertainment", "entertainment"),
        ("Finance", "finance"), ("Games", "games"), ("Graphics & Design", "graphics-design"), ("Healthcare & Fitness", "healthcare-fitness"),
        ("Lifestyle", "lifestyle"), ("Medical", "medical"), ("Music", "music"), ("News", "news"), ("Photography", "photography"),
        ("Productivity", "productivity"), ("Reference", "reference"), ("Social Networking", "social-networking"), ("Sports", "sports"),
        ("Travel", "travel"), ("Utilities", "utilities"), ("Video", "video"), ("Weather", "weather"),
    ].map { ($0.0, "public.app-category." + $0.1) }

    /// Whether the row's key is in the target's Info: then the row shows
    /// "→" (reveal the setting), else "+" (add the key).
    public func identityRowInInfo(_ row: IdentityRow, target: String, configuration: String) -> Bool {
        infoItems(target: target, configuration: configuration).contains { $0.rawKey == row.infoKey }
    }

    /// "+": adds the row's key to Info — as an `INFOPLIST_KEY_*` setting
    /// for a generated Info.plist without a file, else to the file.
    public mutating func addIdentityKeyToInfo(_ row: IdentityRow, target: String, configuration: String) throws {
        if let url = infoPlistURL(target: target, configuration: configuration) {
            var doc = (try? PropertyListDocument(data: Data(contentsOf: url))) ?? PropertyListDocument(root: .dictionary([]))
            guard case .dictionary(var d) = doc.root, !d.contains(where: { $0.key == row.infoKey }) else { return }
            d.append(.init(key: row.infoKey, value: .string(row.infoValue)))
            doc.root = .dictionary(d)
            try doc.data().write(to: url, options: .atomic)
        } else if generatesInfoPlist(target: target, configuration: configuration) {
            let value = row.infoValue.isEmpty ? (row.setting.hasSuffix("LSApplicationCategoryType") ? Self.appCategories[0].value : "") : row.infoValue
            if row.setting.hasPrefix("INFOPLIST_KEY_") { setSetting(row.setting, value, target: target) }
        } else {
            throw InfoTypeError.noInfoPlistFile
        }
    }
}

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
