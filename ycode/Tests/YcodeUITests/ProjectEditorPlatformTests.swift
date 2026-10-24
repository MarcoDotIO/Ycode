import AppKit
import Foundation
import Testing
import YcodePlist
import YcodeProject
@testable import YcodeUI

/// General sections per platform, the Project Document inspector writes,
/// the Info type sections and User-Defined grouping (reference-ui-3.md §1).
/// Projects are written only in temporary directories.
@MainActor
@Suite struct ProjectEditorPlatformTests {
    func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }

    /// A project in a temp directory; `settings` replaces the target's
    /// platform settings, `info` is written as App/Info.plist.
    func project(settings: String? = nil, info: String? = nil) throws -> (ProjectEditorModel, URL) {
        let base = try ProjectEditorReferenceTests().model()
        var text = ProjectEditorReferenceTests.pbxproj
        if let settings {
            text = text.replacingOccurrences(of: """
            SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; TARGETED_DEVICE_FAMILY = "1,2";
                   SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = YES; SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD = YES;
            """, with: settings)
        }
        let dir = base.xcodeprojURL.deletingLastPathComponent()
        if let info {
            text = text.replacingOccurrences(of: "PRODUCT_NAME = App;", with: "PRODUCT_NAME = App; INFOPLIST_FILE = App/Info.plist;")
            try Data(info.utf8).write(to: dir.appendingPathComponent("App/Info.plist"))
        }
        try text.write(to: base.xcodeprojURL.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        return (ProjectEditorModel(proj: try PBXProj(parsing: text), xcodeprojURL: base.xcodeprojURL), dir)
    }

    func controller(_ m: ProjectEditorModel) -> ProjectEditorController {
        _ = NSApplication.shared
        let pe = ProjectEditorController(model: m)
        _ = pe.view
        return pe
    }

    @Test func macOSTargetHasNoDeviceRows() throws {
        let (m, _) = try project(settings: "SDKROOT = macosx; SUPPORTED_PLATFORMS = macosx;")
        #expect(m.supportedDestinations(target: "App", configuration: "Debug").map(\.name) == ["Mac"])
        #expect(!m.generalSections(target: "App", configuration: "Debug").contains("Deployment Info"))
        let pe = controller(m)
        let l = all(pe.content).compactMap { ($0 as? NSTextField)?.stringValue } + all(pe.content).compactMap { ($0 as? NSButton)?.title }
        for s in ["iPhone Orientation", "iPad Orientation", "Status Bar Style", "Hide during application launch", "Launch Screen File"] {
            #expect(!l.contains(s), "\(s)")
        }
        #expect(pe.sectionViews["Deployment Info"] == nil && pe.sectionViews["Identity"] != nil)
    }

    @Test func iPhoneOnlyTargetHasOnlyIPhoneOrientation() throws {
        let (m, _) = try project(settings: "SUPPORTED_PLATFORMS = \"iphoneos iphonesimulator\"; TARGETED_DEVICE_FAMILY = 1;")
        #expect(m.deploymentInfoDevices(target: "App", configuration: "Debug") == ["iPhone"])
        let l = all(controller(m).content).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(l.contains("iPhone Orientation") && !l.contains("iPad Orientation") && l.contains("Status Bar Style"))
    }

    @Test func projectDocumentWritesRoundTrip() throws {
        let (m, _) = try project()
        let url = m.xcodeprojURL
        try ProjectDocumentInspector.edit(url) { $0.setCompatibility("Xcode 14.0"); $0.setMinimizeProjectReferences(false) }
        var p = try PBXProj(contentsOf: url)
        #expect(p.objectVersion == "56" && p.project?.string("compatibilityVersion") == "Xcode 14.0")
        #expect(p.project?["minimizedProjectReferenceProxies"] == nil && p.project?["preferredProjectObjectVersion"] == nil)
        var s = try #require(ProjectDocumentInspector.section(for: url))
        #expect(s.compatibility == "Xcode 14.0" && !s.minimizeProjectReferences)

        try ProjectDocumentInspector.edit(url) { $0.setCompatibility("Xcode 16.0"); $0.setMinimizeProjectReferences(true) }
        p = try PBXProj(contentsOf: url)
        #expect(p.objectVersion == "77" && p.project?["compatibilityVersion"] == nil)
        #expect(p.project?.string("preferredProjectObjectVersion") == "77" && p.project?.string("minimizedProjectReferenceProxies") == "1")
        s = try #require(ProjectDocumentInspector.section(for: url))
        #expect(s.compatibility == "Xcode 16.0" && s.minimizeProjectReferences)

        // The controls write too.
        var controls: [String: NSView] = [:]
        _ = ProjectDocumentInspector.rows(for: url, controls: &controls)
        let popUp = try #require(controls["Compatibility"] as? NSPopUpButton)
        popUp.selectItem(withTitle: "Xcode 15.3")
        _ = popUp.target?.perform(popUp.action, with: popUp)
        #expect(try PBXProj(contentsOf: url).project?.string("compatibilityVersion") == "Xcode 15.3")
        // Untouched keys survive.
        #expect(try PBXProj(contentsOf: url).project?["attributes"]?.dictionary?["ORGANIZATIONNAME"]?.string == "Acme")
    }

    /// The table in specs/formats/pbxproj.md (Project format).
    @Test func compatibilityTableMatchesSpec() {
        let spec: [(String, Int)] = [("Xcode 16.0", 77), ("Xcode 15.3", 63), ("Xcode 15.0", 60), ("Xcode 14.0", 56),
            ("Xcode 13.0", 55), ("Xcode 12.0", 54), ("Xcode 11.4", 53), ("Xcode 11.0", 52), ("Xcode 10.0", 51),
            ("Xcode 9.3", 50), ("Xcode 8.0", 48), ("Xcode 6.3", 47), ("Xcode 3.2", 46), ("Xcode 3.1", 45)]
        #expect(ProjectEditorModel.compatibilityVersions.map(\.title) == spec.map(\.0))
        #expect(ProjectEditorModel.compatibilityVersions.map(\.objectVersion) == spec.map(\.1))
        #expect(ProjectEditorModel.compatibility(objectVersion: "110") == "Xcode 16.0")
        #expect(ProjectEditorModel.compatibility(objectVersion: "45") == "Xcode 3.1")
    }

    static let info = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>CFBundleDocumentTypes</key>
    \t<array>
    \t\t<dict><key>CFBundleTypeName</key><string>Sketch</string><key>LSHandlerRank</key><string>Owner</string></dict>
    \t</array>
    \t<key>CFBundleURLTypes</key>
    \t<array>
    \t\t<dict><key>CFBundleURLName</key><string>com.acme.app</string></dict>
    \t\t<dict><key>CFBundleURLName</key><string>com.acme.alt</string></dict>
    \t</array>
    </dict>
    </plist>
    """

    @Test func infoTypeSectionsListExpandAddRemove() throws {
        let (m, dir) = try project(info: Self.info)
        #expect(m.infoTypeSections(target: "App", configuration: "Debug") ==
                ["Document Types (1)", "Exported Type Identifiers (0)", "Imported Type Identifiers (0)", "URL Types (2)"])
        let pe = controller(m)
        pe.select(tab: .info)
        #expect(pe.tables["URL Types"]?.texts.map(\.[0]) == ["\u{25B8} com.acme.app", "\u{25B8} com.acme.alt"])
        #expect(pe.tables["Document Types"]?.texts.first == ["\u{25B8} Sketch", "Dictionary", "(2 items)"])
        pe.toggleInfoEntry("CFBundleDocumentTypes", index: 0)
        #expect(pe.tables["Document Types"]?.texts.map(\.[0]) == ["\u{25BE} Sketch", "    CFBundleTypeName", "    LSHandlerRank"])

        pe.addInfoTypeEntry("UTExportedTypeDeclarations")
        pe.removeInfoTypeEntry("CFBundleURLTypes", at: 0)
        let doc = try PropertyListDocument(data: Data(contentsOf: dir.appendingPathComponent("App/Info.plist")))
        guard case .dictionary(let d) = doc.root else { Issue.record("not a dictionary"); return }
        #expect(d.map(\.key) == ["CFBundleDocumentTypes", "CFBundleURLTypes", "UTExportedTypeDeclarations"])
        #expect(pe.tables["URL Types"]?.texts.map(\.[0]) == ["\u{25B8} com.acme.alt"])
        #expect(pe.tables["Exported Type Identifiers"]?.texts.count == 1)
        pe.removeInfoTypeEntry("CFBundleURLTypes")
        #expect(pe.model.infoTypeEntries("CFBundleURLTypes", target: "App", configuration: "Debug").isEmpty)
    }

    @Test func unmatchedCustomizedSettingsAreUserDefined() throws {
        let (m, _) = try project()
        let pe = controller(m)
        pe.select(tab: .buildSettings)
        pe.filter = .customized
        let titles = pe.settingSections().map(\.title)
        #expect(!titles.contains("Other Settings"))
        #expect(pe.settingSections().first { $0.title == "User-Defined" }?.names.contains("MY_FLAG") == true)
    }
}
