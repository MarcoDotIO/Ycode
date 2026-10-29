import AppKit
import Foundation
import Testing
import YcodePlist
import YcodeProject
@testable import YcodeUI

/// reference-ui-5.md §11.1 (R35): the project editor's remaining gaps.
@MainActor
@Suite struct ProjectEditorR35Tests {
    static let pbxproj = """
    // !$*UTF8*$!
    { archiveVersion = 1; classes = {}; objectVersion = 77; objects = {
    P1 = { isa = PBXProject; buildConfigurationList = PL; mainGroup = G1; productRefGroup = G2; targets = (T1, T2); knownRegions = (en, Base, de); developmentRegion = en;
           attributes = { BuildIndependentTargetsInParallel = 1; KnownAssetTags = (Level1, Intro); }; };
    G1 = { isa = PBXGroup; children = (G3, G2); sourceTree = "<group>"; };
    G2 = { isa = PBXGroup; children = (AP, TP); name = Products; sourceTree = "<group>"; };
    G3 = { isa = PBXGroup; children = (); path = App; sourceTree = "<group>"; };
    AP = { isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = App.app; sourceTree = BUILT_PRODUCTS_DIR; };
    TP = { isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = AppTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
    PL = { isa = XCConfigurationList; buildConfigurations = (PD, PR); defaultConfigurationName = Release; };
    PD = { isa = XCBuildConfiguration; name = Debug; buildSettings = { SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 27.0; }; };
    PR = { isa = XCBuildConfiguration; name = Release; buildSettings = { SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 27.0; }; };
    T1 = { isa = PBXNativeTarget; name = App; productName = App; productReference = AP; productType = "com.apple.product-type.application"; buildConfigurationList = TL;
           buildPhases = (S1, F1, R1); buildRules = (BR1); dependencies = (D1); packageProductDependencies = (PR1); };
    T2 = { isa = PBXNativeTarget; name = AppTests; productName = AppTests; productReference = TP; productType = "com.apple.product-type.bundle.unit-test"; buildConfigurationList = TL2;
           buildPhases = (S2); buildRules = (); dependencies = (); };
    D1 = { isa = PBXTargetDependency; productRef = PR1; };
    PR1 = { isa = XCSwiftPackageProductDependency; productName = "plugin:LintPlugin"; };
    S1 = { isa = PBXSourcesBuildPhase; files = (); };
    S2 = { isa = PBXSourcesBuildPhase; files = (); };
    F1 = { isa = PBXFrameworksBuildPhase; files = (); };
    R1 = { isa = PBXResourcesBuildPhase; files = (); };
    BR1 = { isa = PBXBuildRule; name = Alpha; compilerSpec = com.apple.compilers.proxy.script; fileType = pattern.proxy; filePatterns = "*.foo"; isEditable = 1; outputFiles = (); script = "echo hi"; };
    TL = { isa = XCConfigurationList; buildConfigurations = (TD, TR); defaultConfigurationName = Release; };
    TD = { isa = XCBuildConfiguration; name = Debug; buildSettings = { SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; TARGETED_DEVICE_FAMILY = "1,2"; PRODUCT_NAME = App;
           GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES;
           INFOPLIST_KEY_CFBundleDisplayName = "$(PRODUCT_NAME) Pro"; INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
           INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft"; }; };
    TR = { isa = XCBuildConfiguration; name = Release; buildSettings = { SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; TARGETED_DEVICE_FAMILY = "1,2"; PRODUCT_NAME = App;
           GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES;
           INFOPLIST_KEY_CFBundleDisplayName = "$(PRODUCT_NAME) Pro"; INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
           INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft"; }; };
    TL2 = { isa = XCConfigurationList; buildConfigurations = (TD2); defaultConfigurationName = Debug; };
    TD2 = { isa = XCBuildConfiguration; name = Debug; buildSettings = { PRODUCT_NAME = AppTests; }; };
    }; rootObject = P1; }
    """

    static func model() throws -> ProjectEditorModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-pe-r35-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("App"), withIntermediateDirectories: true)
        let proj = dir.appendingPathComponent("App.xcodeproj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        return ProjectEditorModel(proj: try PBXProj(parsing: Self.pbxproj), xcodeprojURL: proj)
    }

    static func controller() throws -> ProjectEditorController {
        _ = NSApplication.shared
        let pe = ProjectEditorController(model: try model())
        _ = pe.view
        return pe
    }

    func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }

    // MARK: P1

    @Test func buildSettingsOpensOnBasic() throws {
        let pe = try Self.controller()
        pe.select(tab: .buildSettings)
        #expect(pe.filter == .basic)
        let seg = all(pe.content).compactMap { $0 as? NSSegmentedControl }.first { $0.label(forSegment: 0) == "Basic" }
        #expect(seg?.selectedSegment == 0)
    }

    // MARK: P4

    @Test func buildPhasesPluginRowAndNoConfigurationPopUp() throws {
        let pe = try Self.controller()
        let titles = pe.model.phaseSections(target: "App").map(\.title)
        #expect(Array(titles.prefix(3)) == ["Target Dependencies", "Run Build Tool Plug-ins", "Compile Sources"])
        #expect(pe.model.phaseSections(target: "App")[1].items.map(\.name) == ["LintPlugin"])
        // A plug-in dependency is not a target dependency.
        #expect(pe.model.phaseSections(target: "App")[0].items.isEmpty)
        // Present even when empty.
        #expect(pe.model.phaseSections(target: "AppTests").map(\.title).prefix(2) == ["Target Dependencies", "Run Build Tool Plug-ins"])
        pe.select(tab: .buildPhases)
        #expect(pe.configPopUp.isHidden)
        #expect(pe.sectionViews["Run Build Tool Plug-ins"] != nil)
        pe.select(tab: .buildSettings)
        #expect(!pe.configPopUp.isHidden)
    }

    // MARK: P5

    @Test func infoShowsGeneratedKeysReadablyWithDefinitions() throws {
        let m = try Self.model()
        let items = m.infoItems(target: "App", configuration: "Debug")
        let keys = items.map(\.key)
        #expect(Array(keys.prefix(8)) == ["Bundle name", "Bundle identifier", "InfoDictionary version", "Bundle version string (short)",
                                          "Bundle version", "Executable file", "Application requires iPhone environment", "Application Scene Manifest"])
        #expect(keys.contains("Bundle display name") && keys.contains("Launch Screen") && keys.contains("Supported interface orientations (iPhone)"))
        #expect(!keys.contains { $0.contains("INFOPLIST_KEY") || $0.hasSuffix("_Generation") })
        func item(_ raw: String) -> ProjectEditorModel.InfoItem? { items.first { $0.rawKey == raw } }
        // Values from build settings stay as $(…).
        #expect(item("CFBundleIdentifier")?.value == "$(PRODUCT_BUNDLE_IDENTIFIER)")
        #expect(item("CFBundleDisplayName")?.value == "$(PRODUCT_NAME) Pro")
        #expect(item("UIApplicationSupportsIndirectInputEvents")?.type == "Boolean")
        let orient = try #require(item("UISupportedInterfaceOrientations~iphone"))
        #expect(orient.type == "Array" && orient.value == "(2 items)" && orient.children.map(\.key) == ["Item 0", "Item 1"])
        #expect(item("UIApplicationSceneManifest")?.type == "Dictionary")
        #expect(item("UIApplicationSceneManifest")?.children.first?.key == "Enable Multiple Windows")
    }

    @Test func infoContainersExpand() throws {
        let pe = try Self.controller()
        pe.select(tab: .info)
        let table = try #require(pe.tables["Custom iOS Target Properties"])
        let before = table.rows.count
        #expect(!pe.infoRowPaths.contains("UIApplicationSceneManifest/UIApplicationSupportsMultipleScenes"))
        pe.toggleInfoKey("UIApplicationSceneManifest")
        let after = try #require(pe.tables["Custom iOS Target Properties"])
        #expect(after.rows.count == before + 1)
        #expect(pe.infoRowPaths.contains("UIApplicationSceneManifest/UIApplicationSupportsMultipleScenes"))
        let i = try #require(pe.infoRowPaths.firstIndex(of: "UIApplicationSceneManifest/UIApplicationSupportsMultipleScenes"))
        #expect(after.texts[i][0].trimmingCharacters(in: .whitespaces) == "Enable Multiple Windows")
        pe.toggleInfoKey("UIApplicationSceneManifest")
        #expect(pe.tables["Custom iOS Target Properties"]?.rows.count == before)
    }

    // MARK: P3

    /// The written project parses and round-trips through the writer.
    func reparsed(_ proj: PBXProj) throws -> PBXProj {
        let text = PBXProjWriter.write(proj, projectName: "App")
        let back = try PBXProj(parsing: text)
        #expect(PBXProjWriter.write(back, projectName: "App") == text)
        return back
    }

    @Test func resourceTagsControls() throws {
        let pe = try Self.controller()
        var written: PBXProj?
        pe.onChange = { written = $0 }
        pe.select(tab: .resourceTags)
        let scope = try #require(all(pe.content).compactMap { $0 as? NSSegmentedControl }.first { $0.identifier?.rawValue == "resourceTagScope" })
        #expect(scope.segmentCount == 2 && scope.label(forSegment: 1) == "Prefetched")
        #expect(all(pe.content).contains { ($0 as? NSSearchField)?.placeholderString == "Filter" })
        #expect(pe.tables["Resource Tags"]?.texts == [["Level1", "0 Resources"], ["Intro", "0 Resources"]])
        let added = pe.addResourceTag()
        #expect(added == "New Tag" && pe.model.resourceTags == ["Level1", "Intro", "New Tag"])
        let w1 = try #require(written)
        #expect(try reparsed(w1).project?["attributes"]?.dictionary?["KnownAssetTags"]?.array?.count == 3)
        pe.renameResourceTag("New Tag", to: "Outro")
        #expect(pe.model.resourceTags == ["Level1", "Intro", "Outro"])
        pe.tabFilters["resourceTags"] = "intro"
        pe.select(tab: .resourceTags)
        #expect(pe.tables["Resource Tags"]?.texts.map(\.[0]) == ["Intro"])
        pe.tabFilters = [:]
        pe.removeResourceTag("Intro")
        #expect(pe.model.resourceTags == ["Level1", "Outro"])
        // Prefetched groups the tags.
        pe.model.setSetting("ON_DEMAND_RESOURCES_INITIAL_INSTALL_TAGS", "Level1", target: "App")
        pe.setResourceTagScope("Prefetched")
        #expect(pe.tables["Initial Install Tags"]?.texts == [["Level1"]])
        #expect(pe.tables["Download Only On Demand"]?.texts == [["Outro"]])
        // Removing a tag also drops it from the on-demand settings.
        pe.removeResourceTag("Level1")
        #expect(pe.model.resolve(target: "App", configuration: "Debug")?.settings["ON_DEMAND_RESOURCES_INITIAL_INSTALL_TAGS"] == "")
        // No tags: the empty text.
        pe.removeResourceTag("Outro")
        pe.setResourceTagScope("All")
        #expect(all(pe.content).contains { ($0 as? NSTextField)?.stringValue == ProjectEditorModel.resourceTagsEmptyText })
        #expect(written?.project?["attributes"]?.dictionary?["KnownAssetTags"] == nil)
    }

    @Test func buildRulesControls() throws {
        let pe = try Self.controller()
        var written: PBXProj?
        pe.onChange = { written = $0 }
        pe.select(tab: .buildRules)
        let scope = try #require(all(pe.content).compactMap { $0 as? NSSegmentedControl }.first { $0.identifier?.rawValue == "buildRuleScope" })
        #expect((0..<scope.segmentCount).map { scope.label(forSegment: $0) } == ["All", "Custom"])
        #expect(pe.sectionViews["Alpha"] != nil)
        #expect(all(pe.content).contains { ($0 as? NSButton)?.title == "Copy to Target" })
        let id = try #require(pe.addBuildRule())
        let w1 = try #require(written)
        let rule = try #require(try reparsed(w1)[id])
        #expect(rule.isa == "PBXBuildRule" && rule.string("compilerSpec") == "com.apple.compilers.proxy.script" && rule.string("fileType") == "pattern.proxy")
        #expect(pe.model.target(named: "App")?.references("buildRules").last == id)
        #expect(pe.model.ruleSections(target: "App").count == 2)
        let copy = try #require(pe.copyBuildRule("BR1"))
        #expect(pe.model.proj[copy]?.string("script") == "echo hi" && pe.model.ruleSections(target: "App").count == 3)
        pe.removeBuildRule(id)
        pe.removeBuildRule(copy)
        #expect(pe.model.ruleSections(target: "App").map(\.title) == ["Alpha"] && pe.model.proj[id] == nil)
        pe.tabFilters["buildRules"] = "zzz"
        pe.select(tab: .buildRules)
        #expect(pe.sectionViews["Alpha"] == nil)
    }

    @Test func projectInfoControls() throws {
        let pe = try Self.controller()
        var written: PBXProj?
        pe.onChange = { written = $0 }
        pe.select(target: nil, tab: .info)
        let configs = try #require(pe.tables["Configurations"])
        #expect(configs.columns == ["Name", "Based on Configuration File"])
        #expect(configs.texts.map { $0[1] } == ["No Configurations Set", "No Configurations Set"])
        #expect(configs.plusButton?.isEnabled == true && configs.minusButton?.isEnabled == true)
        pe.toggleConfiguration("Debug")
        #expect(pe.tables["Configurations"]?.texts.map { $0[0].trimmingCharacters(in: .whitespaces) }.prefix(4) == ["\u{25BE} Debug", "App", "App", "AppTests"])
        // Command-line configuration and parallelize.
        let popup = try #require(all(pe.content).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "commandLineConfiguration" })
        #expect(popup.titleOfSelectedItem == "Release")
        pe.setCommandLineConfiguration("Debug")
        #expect(written.flatMap { $0[$0.project?.string("buildConfigurationList") ?? ""]?.string("defaultConfigurationName") } == "Debug")
        pe.setParallelizeCommandLine(false)
        #expect(written?.project?["attributes"]?.dictionary?["BuildIndependentTargetsInParallel"]?.string == "0")
        // Duplicate and remove a configuration across project and targets.
        let new = try #require(pe.duplicateConfiguration("Release"))
        #expect(new == "Release copy")
        #expect(pe.model.configurations(of: nil).names == ["Debug", "Release", "Release copy"])
        #expect(pe.model.configurations(of: "App").names == ["Debug", "Release", "Release copy"])
        #expect(pe.model.configurations(of: "AppTests").names == ["Debug"]) // no Release to copy
        let w2 = try #require(written)
        _ = try reparsed(w2)
        pe.removeConfiguration("Release copy")
        #expect(pe.model.configurations(of: "App").names == ["Debug", "Release"])
        // Localizations.
        let locs = try #require(pe.tables["Localizations"])
        #expect(locs.columns == ["Localization", "Default", "Resources"])
        #expect(locs.texts == [["English (Development Language)", "Default", "0 Files Localized"], ["German", "", "0 Files Localized"]])
        pe.addLocalization("fr")
        #expect(pe.model.localizationRows.map(\.code) == ["en", "de", "fr"])
        pe.setDevelopmentRegion("de")
        #expect(written?.project?.string("developmentRegion") == "de")
        pe.removeLocalization("de") // the development language stays
        #expect(pe.model.localizationRows.map(\.code) == ["en", "de", "fr"])
        pe.removeLocalization("fr")
        pe.setUsesBaseInternationalization(false)
        #expect(written?.project?["knownRegions"]?.array?.compactMap(\.string) == ["en", "de"])
        let base = all(pe.content).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "useBaseInternationalization" }
        #expect(base?.state == .off)
        #expect(all(pe.content).contains { ($0 as? NSButton)?.title == "Set Default" })
    }

    @Test func packageDependenciesTable() throws {
        let pe = try Self.controller()
        pe.select(target: nil, tab: .packageDependencies)
        let t = try #require(pe.tables["Packages"])
        #expect(t.columns == ["Name", "Location", "Dependency Rule"])
        #expect(t.emptyLabel?.stringValue == "Add packages here" && t.plusButton != nil && t.minusButton != nil)
        #expect(pe.sectionViews["Packages"]?.title == "Packages (0 items)")
        var added = false
        pe.onAddPackage = { added = true }
        t.plusButton?.performClick(nil)
        #expect(added)
    }

    // MARK: P6

    @Test func supportedDestinationsAddAndRemove() throws {
        let pe = try Self.controller()
        var written: PBXProj?
        pe.onChange = { written = $0 }
        func names() -> [String] { pe.model.supportedDestinations(target: "App", configuration: "Debug").map(\.name) }
        func setting(_ n: String) -> String { pe.model.resolve(target: "App", configuration: "Release")?.settings[n] ?? "" }
        #expect(names() == ["iPhone", "iPad"])
        #expect(pe.tables["Supported Destinations"]?.itemIDs == ["iPhone", "iPad"])
        #expect(pe.model.addableDestinations(target: "App", configuration: "Debug") ==
                ["Mac (Mac Catalyst)", "Mac (Designed for iPad)", "Apple Vision (Designed for iPad)", "Mac", "Apple Vision", "Apple TV", "Apple Watch"])
        pe.addDestination("Mac (Designed for iPad)")
        #expect(setting("SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD") == "YES" && names().contains("Mac (Designed for iPad)"))
        #expect(!pe.model.addableDestinations(target: "App", configuration: "Debug").contains("Mac (Mac Catalyst)"))
        pe.addDestination("Apple Vision")
        #expect(setting("SUPPORTED_PLATFORMS") == "iphoneos iphonesimulator xros xrsimulator" && setting("TARGETED_DEVICE_FAMILY") == "1,2,7")
        #expect(names().last == "Apple Vision")
        pe.removeDestination("iPhone")
        #expect(setting("TARGETED_DEVICE_FAMILY") == "2,7" && names().first == "iPad")
        pe.removeDestination("iPad")
        #expect(setting("SUPPORTED_PLATFORMS") == "xros xrsimulator" && setting("TARGETED_DEVICE_FAMILY") == "7")
        #expect(setting("SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD") == "NO" && names() == ["Apple Vision"])
        pe.removeDestination("Apple Vision") // the last one stays
        #expect(names() == ["Apple Vision"])
        // Written at target level in every configuration.
        let w = try #require(written)
        let tl = try #require(w["TL"])
        for c in w.buildConfigurations(listID: tl.id) {
            #expect(c["buildSettings"]?.dictionary?["SUPPORTED_PLATFORMS"]?.string == "xros xrsimulator")
        }
    }

    @Test func minimumDeploymentsAddsPlatformRow() throws {
        let pe = try Self.controller()
        #expect(pe.model.minimumDeployments(target: "App", configuration: "Debug").map(\.sdk) == ["iOS"])
        #expect(pe.model.addableDeploymentSDKs(target: "App", configuration: "Debug") == ["macOS", "visionOS", "tvOS", "watchOS"])
        let plus = all(pe.content).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "addDeploymentPlatform" }
        #expect(plus?.isEnabled == true)
        pe.addDeploymentPlatform("macOS")
        let rows = pe.model.minimumDeployments(target: "App", configuration: "Debug")
        #expect(rows.map(\.sdk) == ["iOS", "macOS"] && rows[1].value == "27.0" && rows[1].setting == "MACOSX_DEPLOYMENT_TARGET")
    }

    @Test func identityRowsAddToInfoOrReveal() throws {
        let pe = try Self.controller()
        var written: PBXProj?
        pe.onChange = { written = $0 }
        func button(_ id: String) -> NSButton? { all(pe.content).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id } }
        // Generated Info has the bundle id and version keys: "→".
        #expect(button("reveal:PRODUCT_BUNDLE_IDENTIFIER") != nil && button("reveal:MARKETING_VERSION") != nil)
        #expect(button("reveal:INFOPLIST_KEY_CFBundleDisplayName") != nil)
        #expect(button("add:INFOPLIST_KEY_LSApplicationCategoryType") != nil)
        // "+" adds the key to Info.
        let category = try #require(ProjectEditorModel.identityRows.first { $0.title == "App Category" })
        pe.addIdentityKeyToInfo(category)
        #expect(written != nil)
        #expect(pe.model.infoItems(target: "App", configuration: "Debug").contains { $0.rawKey == "LSApplicationCategoryType" })
        #expect(button("reveal:INFOPLIST_KEY_LSApplicationCategoryType") != nil)
        let popup = all(pe.content).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "INFOPLIST_KEY_LSApplicationCategoryType" }
        #expect(popup?.titleOfSelectedItem == "Business")
        // "→" reveals the setting in Build Settings.
        pe.revealSetting("INFOPLIST_KEY_LSApplicationCategoryType")
        #expect(pe.tab == .buildSettings && pe.filter == .all && pe.search == "INFOPLIST_KEY_LSApplicationCategoryType")
        let row = pe.settingsTable.selectedRow
        #expect(row >= 0 && pe.settingsLines[row] == .setting("INFOPLIST_KEY_LSApplicationCategoryType"))
    }

    @Test func identityPlusWritesInfoPlistFile() throws {
        var m = try Self.model()
        let dir = m.proj.projectDirectory(xcodeprojURL: m.xcodeprojURL)
        let plist = dir.appendingPathComponent("App/Info.plist")
        try PropertyListDocument(root: .dictionary([.init(key: "Zeta", value: .string("z"))])).data().write(to: plist)
        m.setSetting("INFOPLIST_FILE", "App/Info.plist", target: "App")
        m.setSetting("GENERATE_INFOPLIST_FILE", "NO", target: "App")
        let version = try #require(ProjectEditorModel.identityRows.first { $0.title == "Version" })
        #expect(!m.identityRowInInfo(version, target: "App", configuration: "Debug"))
        try m.addIdentityKeyToInfo(version, target: "App", configuration: "Debug")
        guard case .dictionary(let d) = try PropertyListDocument(data: Data(contentsOf: plist)).root else { Issue.record("not a dict"); return }
        #expect(d.map(\.key) == ["Zeta", "CFBundleShortVersionString"] && d[1].value == .string("$(MARKETING_VERSION)"))
        #expect(m.identityRowInInfo(version, target: "App", configuration: "Debug"))
    }

    // MARK: P2

    @Test func targetListFooterCollapseAndFilter() throws {
        let pe = try Self.controller()
        let footer = all(pe.view).compactMap { $0 as? NSButton }
        #expect(footer.contains { $0.toolTip == "Add a target" } && footer.contains { $0.toolTip == "Delete the selected target" })
        #expect(all(pe.view).contains { ($0 as? NSSearchField)?.placeholderString == "Filter" && $0.superview === pe.sidebarFooter })
        #expect(pe.removeTargetButton.isEnabled)
        pe.select(target: nil, tab: .info)
        #expect(!pe.removeTargetButton.isEnabled) // the project can't be deleted
        pe.setSidebarFilter("tests")
        #expect(pe.sidebarRows.filter { $0.target != nil }.map(\.title) == ["AppTests"])
        #expect(pe.sidebarRows.map(\.title).prefix(3) == ["PROJECT", "App", "TARGETS"]) // the project row stays
        pe.setSidebarFilter("")
        #expect(pe.sidebarRows.filter { $0.target != nil }.map(\.title) == ["App", "AppTests"])
        pe.setSidebarCollapsed(true)
        #expect(pe.isSidebarCollapsed && pe.sidebarWidth.constant == 0 && pe.sidebarFooter.isHidden && !pe.collapseButton.isHidden)
        pe.setSidebarCollapsed(false)
        #expect(pe.sidebarWidth.constant == ProjectEditorController.sidebarWidth)
    }

    @Test func addTargetFromTemplateSheet() throws {
        let pe = try Self.controller()
        var written: PBXProj?
        pe.onChange = { written = $0 }
        let sheet = pe.newTargetSheet()
        _ = sheet.view
        #expect(sheet.heading == "Choose a template for your new target:")
        #expect(sheet.sections.map(\.title) == ["Application", "Test", "Framework & Library"])
        #expect(sheet.select(title: "Unit Testing Bundle"))
        sheet.nextClicked()
        #expect(sheet.steps.index == 1 && !sheet.nextButton.isEnabled && sheet.nextButton.title == "Finish")
        #expect(sheet.hostPopUp.titleOfSelectedItem == "App")
        sheet.productNameField.stringValue = "App"
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        sheet.nextClicked() // duplicate name
        #expect(sheet.errorLabel.stringValue.contains("already exists"))
        sheet.productNameField.stringValue = "LogicTests"
        sheet.nextClicked()
        #expect(pe.selectedTarget == "LogicTests" && pe.sidebarRows.contains { $0.target == "LogicTests" })
        let w = try #require(written)
        let t = try #require(w.targets.first { $0.string("name") == "LogicTests" })
        #expect(t.string("productType") == "com.apple.product-type.bundle.unit-test")
        let settings = w.buildConfigurations(listID: t.string("buildConfigurationList")).first?["buildSettings"]?.dictionary
        #expect(settings?["TEST_HOST"]?.string == "$(BUILT_PRODUCTS_DIR)/App.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/App")
        #expect(settings?["BUNDLE_LOADER"]?.string == "$(TEST_HOST)")
        // A synchronized folder with a starter test file on disk.
        let dir = pe.model.proj.projectDirectory(xcodeprojURL: pe.model.xcodeprojURL)
        let file = dir.appendingPathComponent("LogicTests/LogicTests.swift")
        #expect((try? String(contentsOf: file, encoding: .utf8))?.contains("@Test func example()") == true)
        #expect(t.references("fileSystemSynchronizedGroups").count == 1)
        // The written project round-trips.
        _ = try reparsed(w)
    }

    /// Build rules belong to native targets only.
    @Test func noBuildRulesOnAggregateTargets() throws {
        var m = try Self.model()
        var t = try #require(m.target(named: "AppTests"))
        t["isa"] = "PBXAggregateTarget"
        m.proj[t.id] = t
        #expect(m.addBuildRule(target: "AppTests") == nil && m.copyBuildRule("BR1", toTarget: "AppTests") == nil)
        #expect(m.proj[t.id]?.references("buildRules") == [])
    }

    /// An older project (object version 46): the new target's sources go in
    /// a group with its file in Compile Sources.
    @Test func addTargetToOlderProject() throws {
        var m = try Self.model()
        m.proj.objectVersion = "46"
        try m.addTarget(template: "Framework", platform: "iOS", name: "Kit", hostTarget: nil)
        let t = try #require(m.target(named: "Kit"))
        #expect(t["fileSystemSynchronizedGroups"] == nil)
        let group = try #require(m.proj.objects.values.first { $0.isa == "PBXGroup" && $0.string("path") == "Kit" })
        let ref = try #require(group.references("children").first.flatMap { m.proj[$0] })
        #expect(ref.string("path") == "Kit.swift")
        let sources = m.proj.buildPhases(ofTarget: t.id).first { $0.isa == "PBXSourcesBuildPhase" }
        #expect(sources?.references("files").compactMap { m.proj.fileReference(ofBuildFile: $0)?.id } == [ref.id])
    }

    @Test func deleteTarget() throws {
        let pe = try Self.controller()
        var written: PBXProj?
        pe.onChange = { written = $0 }
        #expect(ProjectEditorController.deleteTargetMessage("App").0 == "Delete the target \u{201C}App\u{201D}?")
        try pe.addTarget(template: "UI Testing Bundle", platform: "iOS", name: "AppUITests", hostTarget: "App")
        #expect(pe.model.targets.count == 3)
        pe.deleteTarget("AppUITests")
        #expect(pe.model.targets.compactMap { $0.string("name") } == ["App", "AppTests"])
        #expect(pe.selectedTarget == "App")
        pe.deleteTarget("App")
        let w = try #require(written)
        #expect(w.targets.compactMap { $0.string("name") } == ["AppTests"])
        // The plug-in dependency and its product dependency went with App.
        #expect(w["D1"] == nil && w["PR1"] == nil && w["AP"] == nil)
        _ = try reparsed(w)
    }
}

/// Over the local corpus (see README; the manifest of `PBXProjCorpusTests`):
/// project-editor edits that are undone restore every project byte for byte.
@Suite struct ProjectEditorR35CorpusTests {
    static let entries: [String] = {
        let manifest = ProcessInfo.processInfo.environment["YCODE_PBXPROJ_CORPUS"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("research/dirty/pbxproj-corpus.txt")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { $0.count > 2 }
    }()

    /// The checked-in fixture always runs.
    @Test func undoneEditsRestoreFixtureBytes() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("YcodeProjectTests/Fixtures/Hello.xcodeproj")
        try undoneEditsRestoreBytes("= " + fixture.path)
        // And the fixture's text itself is what the writer produces.
        let (file, name) = PBXProj.locate(fixture.path)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(try PBXProj(parsing: text).serialized(projectName: name) == text)
    }

    @Test(.enabled(if: !entries.isEmpty, "no local corpus manifest"), arguments: entries)
    func undoneEditsRestoreBytes(_ entry: String) throws {
        let (file, name) = PBXProj.locate(String(entry.dropFirst(2)))
        let original = try PBXProj(parsing: try String(contentsOf: file, encoding: .utf8))
        let before = original.serialized(projectName: name)
        var m = ProjectEditorModel(proj: original, xcodeprojURL: file.deletingLastPathComponent())
        if let cfg = m.configurations(of: nil).names.first, let copy = m.duplicateConfiguration(cfg) {
            m.removeConfiguration(copy)
        }
        let tag = m.addResourceTag()
        m.removeResourceTag(tag)
        if let t = m.targets.first?.string("name"), let rule = m.addBuildRule(target: t) { m.removeBuildRule(rule) }
        let after = m.proj.serialized(projectName: name)
        #expect(after == before, "\(file.path): \(firstDifference(before, after))")
    }
}

/// The first line where two texts differ (test messages).
func firstDifference(_ a: String, _ b: String) -> String {
    let x = a.components(separatedBy: "\n"), y = b.components(separatedBy: "\n")
    for i in 0..<max(x.count, y.count) where (i < x.count ? x[i] : nil) != (i < y.count ? y[i] : nil) {
        return "line \(i + 1): \(i < x.count ? x[i] : "<end>") | \(i < y.count ? y[i] : "<end>")"
    }
    return "same"
}
