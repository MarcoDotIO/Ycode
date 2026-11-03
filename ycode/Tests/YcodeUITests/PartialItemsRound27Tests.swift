import AppKit
import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
import YcodePlist
import YcodeProject
@testable import YcodeUI

/// Generated Info.plist type sections, the Organizer app picker, more
/// asset catalog set types, and project coverage through ycodebuild.
/// Everything is written in temporary directories.
@MainActor
@Suite struct PartialItemsRound27Tests {
    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-r27-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // (a) Generated Info.plist

    func generatedProject() throws -> (ProjectEditorModel, URL) {
        let base = try ProjectEditorFixture().model()
        let text = ProjectEditorFixture.pbxproj.replacingOccurrences(
            of: "PRODUCT_NAME = App;", with: "PRODUCT_NAME = App; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_CFBundleDisplayName = Hi;")
        try text.write(to: base.xcodeprojURL.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        return (ProjectEditorModel(proj: try PBXProj(parsing: text), xcodeprojURL: base.xcodeprojURL), base.xcodeprojURL.deletingLastPathComponent())
    }

    @Test func noFileAndNoGenerationStillThrows() throws {
        var m = try ProjectEditorFixture().model()
        guard !m.generatesInfoPlist(target: "App", configuration: "Debug"),
              m.infoPlistURL(target: "App", configuration: "Debug") == nil else { return }
        #expect(throws: ProjectEditorModel.InfoTypeError.self) {
            try m.addInfoTypeEntry("CFBundleURLTypes", target: "App", configuration: "Debug")
        }
    }

    // (b) Organizer app picker

    @Test func organizerAppPicker() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let o = OrganizerController(archivesDirectory: dir)
        _ = o.view
        #expect(o.appPicker.itemTitles == ["No App"] && !o.appPicker.isEnabled)
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try makeArchive(in: dir, name: "Beta 1", app: "Beta", version: "2.0", build: "5", created: t0)
        let a = try makeArchive(in: dir, name: "Alpha 1", app: "Alpha", version: "1.0", build: "1", created: t0)
        o.reload()
        #expect(o.appPicker.itemTitles == ["Alpha", "Beta"] && o.appPicker.isEnabled)
        #expect(o.selectedApp == "Alpha")
        #expect(o.rows.map(\.title) == ["Alpha", "Alpha 1"])
        o.chooseApp("Beta")
        #expect(o.rows.map(\.title) == ["Beta", "Beta 1"] && o.appPicker.titleOfSelectedItem == "Beta")
        o.chooseApp("Missing")
        #expect(o.selectedApp == "Beta")
        o.select(archiveAt: a)
        #expect(o.selectedApp == "Alpha" && o.selected?.name == "Alpha 1")
    }

    @Test func editorPlusMenuCreatesOtherTypes() throws {
        let dir = try tempDir().appendingPathComponent("B.xcassets")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let e = AssetCatalogEditorController(url: dir)
        _ = e.view
        // Every titled set type in otherSetTitles is wired to the menu.
        for t in AssetCatalog.otherSetTitles { #expect(AssetCatalogEditorController.creatable[t.title] != nil) }
        let tag = AssetCatalogEditorController.creatable["Symbol Image Set"]!
        let s = try e.addSet(kind: tag)
        #expect(s.kind == .symbolSet && s.name == "Symbol" && e.selected?.name == "Symbol")
        let s2 = try e.addSet(kind: tag)
        #expect(s2.name == "Symbol 1")
        let f = try e.addFolder(namespace: false)
        #expect(f.lastPathComponent == "Folder")
        #expect(AssetCatalogEditorController.creatable["Folder with Namespace"] != nil)
    }
}
