import AppKit
import Foundation
import Testing
import YcodeProject
@testable import YcodeUI

/// Drives the project editor's AppKit views (reference-ui-3.md §1) and
/// checks that the controls and labels exist. No window is shown and no
/// defaults are written.
@MainActor
@Suite struct ProjectEditorUITests {
    func controller() throws -> ProjectEditorController {
        _ = NSApplication.shared
        let pe = ProjectEditorController(model: try ProjectEditorReferenceTests().model())
        _ = pe.view
        return pe
    }

    func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
    func labels(_ pe: ProjectEditorController) -> [String] {
        all(pe.content).compactMap { ($0 as? NSTextField)?.stringValue } + all(pe.content).compactMap { ($0 as? NSButton)?.title }
    }

    @Test func generalTablesCheckboxesAndSections() throws {
        let pe = try controller()
        #expect(pe.selectedTarget == "App" && pe.tab == .general)
        #expect(ProjectEditorModel.generalSectionTitles.allSatisfy { pe.sectionViews[$0] != nil })
        let dest = try #require(pe.tables["Supported Destinations"])
        #expect(dest.columns == ["Destination", "SDK"])
        #expect(dest.texts.map(\.[0]) == ["iPhone", "iPad", "Mac (Designed for iPad)", "Apple Vision (Designed for iPad)"])
        #expect(dest.plusButton != nil && dest.minusButton != nil)
        #expect(pe.tables["Supported Intents"]?.columns == ["Class Name", "Authentication"])
        #expect(pe.tables["Supported Intents"]?.emptyLabel?.stringValue == "Add intents eligible for in-app handling here")
        let l = labels(pe)
        for s in ["Display Name", "Bundle Identifier", "iPhone Orientation", "iPad Orientation", "Hide during application launch", "Landscape Left"] {
            #expect(l.contains(s), "\(s)")
        }
        // An orientation checkbox writes the setting.
        var written: PBXProj?
        pe.onChange = { written = $0 }
        pe.setOrientation("UIInterfaceOrientationPortrait", device: "iPhone", on: true)
        #expect(written != nil)
        #expect(pe.model.orientations(device: "iPhone", target: "App", configuration: "Debug") == ["UIInterfaceOrientationPortrait"])
        let box = all(pe.content).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "iPhone:UIInterfaceOrientationPortrait" }
        #expect(box?.state == .on)
        // Collapsing survives a reload.
        pe.toggleSection("Identity")
        #expect(pe.sectionViews["Identity"]?.isCollapsed == true)
        pe.select(tab: .general)
        #expect(pe.sectionViews["Identity"]?.isCollapsed == true && pe.collapsedSections.contains("Identity"))
    }

    @Test func infoTableAndCollapsedTypeSections() throws {
        let pe = try controller()
        pe.select(tab: .info)
        let t = try #require(pe.tables["Custom iOS Target Properties"])
        #expect(t.columns == ["Key", "Type", "Value"])
        for key in ["Document Types", "Exported Type Identifiers", "Imported Type Identifiers", "URL Types"] {
            #expect(pe.sectionViews[key]?.isCollapsed == true)
        }
        #expect(pe.sectionViews["Custom iOS Target Properties"]?.isCollapsed == false)
        #expect(labels(pe).contains("Document Types (0)"))
    }

    @Test func buildSettingsBasicLevelsAndMultipleValues() throws {
        let pe = try controller()
        pe.select(tab: .buildSettings)
        pe.filter = .basic
        let sections = pe.settingsLines.compactMap { if case .section(let s) = $0 { s } else { nil } }
        #expect(sections.first == "Deployment" && sections.contains("Swift Compiler - Language") && sections.last == "User-Defined")
        #expect(pe.settingRows.contains { $0.name == "MY_FLAG" })
        // Titles by default; the customized PRODUCT_NAME is bold, an inherited one is not.
        let row = try #require(pe.settingsLines.firstIndex(of: .setting("PRODUCT_NAME")))
        #expect(pe.settingsCellText(row: row, column: "name") == "Product Name")
        #expect(pe.settingIsBold("PRODUCT_NAME") && !pe.settingIsBold("INSTALL_PATH"))
        let cell = pe.tableView(pe.settingsTable, viewFor: pe.settingsTable.tableColumns[0], row: row) as? NSTextField
        #expect(cell?.font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        pe.showsTitles = false
        #expect(pe.settingsCellText(row: row, column: "name") == "PRODUCT_NAME")
        // Collapsing a section hides its settings.
        pe.collapsedSettingSections = ["Packaging"]
        #expect(!pe.settingsLines.contains(.setting("PRODUCT_NAME")))
        pe.collapsedSettingSections = []

        // Levels: Setting | Resolved | target | project | platform default.
        pe.filter = .all
        pe.search = "SWIFT_OPTIMIZATION_LEVEL"
        pe.settingsView = .levels
        #expect(pe.settingsTable.tableColumns.map(\.title) == ["Setting", "Resolved", "App", "App", "iOS Default"])
        let opt = try #require(pe.settingsLines.firstIndex(of: .setting("SWIFT_OPTIMIZATION_LEVEL")))
        #expect(pe.hasMultipleValues("SWIFT_OPTIMIZATION_LEVEL"))
        #expect(pe.settingsCellText(row: opt, column: "resolved") == ProjectEditorModel.multipleValues)
        pe.expandedSettings = ["SWIFT_OPTIMIZATION_LEVEL"]
        #expect(pe.settingsLines.contains(.configuration(setting: "SWIFT_OPTIMIZATION_LEVEL", name: "Debug")))
        let dbg = try #require(pe.settingsLines.firstIndex(of: .configuration(setting: "SWIFT_OPTIMIZATION_LEVEL", name: "Release")))
        #expect(pe.settingsCellText(row: dbg, column: "resolved") == "-O")
        // The providing level's cell is outlined.
        let projectCol = try #require(pe.settingsTable.tableColumns.first { $0.identifier.rawValue == "project" })
        let outlined = pe.tableView(pe.settingsTable, viewFor: projectCol, row: dbg) as? NSTextField
        #expect(outlined?.layer?.borderWidth == 1)
    }

    @Test func signingScopeWritesOneConfiguration() throws {
        let pe = try controller()
        pe.select(tab: .signing)
        let l = labels(pe)
        #expect(l.contains("+ Capability") && l.contains(ProjectEditorModel.automaticSigningCaption) && l.contains(ProjectEditorModel.emptyCapabilitiesText))
        #expect(l.contains { $0.contains("requires a development team") })
        let scope = all(pe.content).compactMap { $0 as? NSSegmentedControl }.first { $0.identifier?.rawValue == "signingScope" }
        #expect(scope.map { (0..<$0.segmentCount).map($0.label(forSegment:)) } == ["All", "Debug", "Release"])
        pe.setSigningScope("Release")
        #expect(pe.signingScope == "Release")
        pe.setSetting("DEVELOPMENT_TEAM", "TEAM123456")
        #expect(pe.model.resolve(target: "App", configuration: "Release")?.settings["DEVELOPMENT_TEAM"] == "TEAM123456")
        #expect(pe.model.resolve(target: "App", configuration: "Debug")?.settings["DEVELOPMENT_TEAM"] == "")
        #expect(!labels(pe).contains { $0.contains("requires a development team") })
        pe.setSigningScope("Debug")
        #expect(labels(pe).contains { $0.contains("requires a development team") })
        pe.setSigningScope("All")
        pe.setSetting("DEVELOPMENT_TEAM", "TEAM123456")
        #expect(pe.model.resolve(target: "App", configuration: "Debug")?.settings["DEVELOPMENT_TEAM"] == "TEAM123456")
    }

    @Test func capabilityLibraryPanel() throws {
        let pe = try controller()
        pe.select(tab: .signing)
        let lib = pe.capabilityLibrary()
        _ = lib.view
        #expect(lib.title == "Capabilities")
        #expect(lib.items.map(\.rawValue) == lib.items.map(\.rawValue).sorted())
        #expect(lib.error?.first == "Error Loading Capabilities" && !lib.footer.isHidden)
        lib.filter = "connections"
        #expect(lib.items == [.incomingNetwork, .outgoingNetwork])
        lib.select(.outgoingNetwork)
        #expect(lib.detailName.stringValue == "Outgoing Connections (Client)" && !lib.detailText.stringValue.isEmpty && lib.detailIcon.image != nil)
        lib.setLayout(.grid)
        #expect(lib.layout == .grid && !lib.grid.isHidden)
    }

    @Test func buildPhaseMenuAndTrash() throws {
        let pe = try controller()
        pe.select(tab: .buildPhases)
        let menu = try #require(all(pe.content).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "addPhaseMenu" })
        let titles = menu.itemArray.map(\.title)
        #expect(titles.contains("New Run Script Phase") && titles.contains("New Copy Files Phase"))
        #expect(menu.item(withTitle: "New Compile Sources Phase")?.isEnabled == false)
        #expect(pe.sectionViews["Compile Sources"] != nil && pe.tables["S1"]?.columns == ["Name", "Compiler Flags"])
        // The menu item adds a phase; its trash button removes it.
        let item = try #require(menu.item(withTitle: "New Run Script Phase"))
        _ = item.target?.perform(item.action, with: item)
        let script = try #require(pe.model.phaseSections(target: "App").first { $0.title == "Run Script" }?.phaseID)
        #expect(pe.sectionViews["Run Script"] != nil)
        let trash = all(pe.content).compactMap { $0 as? ProjectEditorController.PhaseButton }.first { $0.value == script }
        #expect(trash != nil)
        trash.map { _ = $0.target?.perform($0.action, with: $0) }
        #expect(!pe.model.phaseSections(target: "App").contains { $0.title == "Run Script" })
        #expect(pe.model.proj[script] == nil)
        // Target Dependencies has no trash button.
        #expect(pe.sectionViews["Target Dependencies"]?.arrangedSubviews.first.map { all($0).contains { $0 is ProjectEditorController.PhaseButton } } == false)
    }

    @Test func projectFileInspectorProjectDocument() throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-pe-insp-\(UUID().uuidString)")
        let proj = dir.appendingPathComponent("App.xcodeproj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try ProjectEditorReferenceTests.pbxproj.write(to: proj.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        let insp = InspectorAreaController()
        _ = insp.view
        insp.show(file: proj)
        #expect((insp.fileControls["Compatibility"] as? NSPopUpButton)?.titleOfSelectedItem == "Xcode 16.0")
        #expect((insp.fileControls["Encoding"] as? NSButton)?.state == .on)
        #expect((insp.fileControls["Decoding"] as? NSButton)?.title == "Strictly Validate")
        #expect((insp.fileControls["Organization"] as? NSTextField)?.stringValue == "Acme")
        let location = insp.fileControls["Location"] as? NSPopUpButton
        #expect(location?.titleOfSelectedItem == "Absolute" && location?.isEnabled == false)
    }
}
