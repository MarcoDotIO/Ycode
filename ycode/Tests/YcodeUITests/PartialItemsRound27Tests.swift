import AppKit
import Foundation
import Testing
import YcodeBuild
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
        let base = try ProjectEditorReferenceTests().model()
        let text = ProjectEditorReferenceTests.pbxproj.replacingOccurrences(
            of: "PRODUCT_NAME = App;", with: "PRODUCT_NAME = App; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_CFBundleDisplayName = Hi;")
        try text.write(to: base.xcodeprojURL.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        return (ProjectEditorModel(proj: try PBXProj(parsing: text), xcodeprojURL: base.xcodeprojURL), base.xcodeprojURL.deletingLastPathComponent())
    }

    @Test func generatedInfoPlistTypeSectionsCreateTheFile() throws {
        let (m0, dir) = try generatedProject()
        var m = m0
        #expect(m.generatesInfoPlist(target: "App", configuration: "Debug"))
        #expect(m.infoTypeSections(target: "App", configuration: "Debug").allSatisfy { $0.hasSuffix("(0)") })
        // Removing from an empty generated target writes nothing.
        try m.setInfoTypeEntries("CFBundleURLTypes", [], target: "App", configuration: "Debug")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("App/Info.plist").path))

        try m.addInfoTypeEntry("CFBundleURLTypes", target: "App", configuration: "Debug")
        let file = dir.appendingPathComponent("App/Info.plist")
        let doc = try PropertyListDocument(data: Data(contentsOf: file))
        guard case .dictionary(let d) = doc.root else { Issue.record("not a dictionary"); return }
        #expect(d.map(\.key) == ["CFBundleURLTypes"])
        for c in ["Debug", "Release"] {
            #expect(m.resolve(target: "App", configuration: c)?.settings["INFOPLIST_FILE"] == "App/Info.plist")
        }
        #expect(m.generatesInfoPlist(target: "App", configuration: "Debug"))
        #expect(m.infoTypeEntries("CFBundleURLTypes", target: "App", configuration: "Debug").count == 1)
        // Generated keys still show next to the file's keys.
        #expect(m.infoRows(target: "App", configuration: "Debug").map(\.key).contains("CFBundleDisplayName"))
    }

    @Test func noFileAndNoGenerationStillThrows() throws {
        var m = try ProjectEditorReferenceTests().model()
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

    // (c) Asset catalog set types

    @Test func otherSetTypesCreateReadAndList() throws {
        let dir = try tempDir().appendingPathComponent("A.xcassets")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let c = AssetCatalog(url: dir)
        let data = try c.addSet(.dataSet, named: "Blob")
        let sym = try c.addSet(.symbolSet, named: "Star")
        let atlas = try c.addSet(.spriteAtlas, named: "Sprites")
        _ = try c.addSet(.imageSet, named: "Frame", in: "Sprites.spriteatlas")
        let ns = try c.addFolder(named: "Icons", namespace: true)
        #expect((AssetCatalog.readContents(ns)["properties"] as? [String: Bool])?["provides-namespace"] == true)
        #expect(AssetCatalog.readContents(data.url)["data"] as? [[String: String]] == [["idiom": "universal"]])
        #expect(AssetCatalog.readContents(sym.url)["symbols"] as? [[String: String]] == [["idiom": "universal"]])
        #expect(AssetCatalog.readContents(atlas.url).keys.sorted() == ["info"])
        #expect(c.sets().map { "\($0.group)|\($0.name)|\($0.kind.rawValue)" } ==
                ["|Blob|dataset", "|Sprites|spriteatlas", "Sprites|Frame|imageset", "|Star|symbolset"])

        // A file slot: set, then clear.
        let src = dir.deletingLastPathComponent().appendingPathComponent("payload.json")
        try Data("{}".utf8).write(to: src)
        try AssetCatalog.setImage(src, slot: 0, in: data)
        #expect(AssetCatalog.slots(of: data).first?.filename == "payload.json")
        try AssetCatalog.clearImage(slot: 0, in: data)
        #expect(AssetCatalog.slots(of: data).first?.filename == nil)
        #expect(!FileManager.default.fileExists(atPath: data.url.appendingPathComponent("payload.json").path))
        #expect(AssetCatalog.Kind.dataSet.typeLabel == "Data Set" && AssetCatalog.inspector(for: data).rows.first?.value == "Blob")
        for k in AssetCatalog.Kind.allCases { #expect(!k.typeLabel.isEmpty) }
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

    // (d) Project coverage through ycodebuild

    @Test func swiftBuildPreferenceRunsProjectTestsThroughYcodebuild() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("ycodebuild")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        #expect(TestRunnerSelection.locateYcodebuild(environment: ["PATH": dir.path], executableDirectory: nil) == tool.path)
        #expect(TestRunnerSelection.locateYcodebuild(environment: [:], executableDirectory: dir.path) == tool.path)
        #expect(TestRunnerSelection.locateYcodebuild(environment: ["YCODE_BUILD_TOOL": tool.path], executableDirectory: nil) == tool.path)
        #expect(TestRunnerSelection.locateYcodebuild(environment: [:], executableDirectory: nil) == nil)

        var r = TestRunnerSelection.runner(TestRunner(), preference: .swiftBuild, locate: { tool.path })
        #expect(r.xcodebuild == [tool.path])
        r.coverage = true
        let req = BuildRequest(container: .project(dir.appendingPathComponent("P.xcodeproj").path), scheme: "P", action: .test)
        let cmd = r.command(for: req).args
        #expect(cmd.first == tool.path && cmd.contains("-enableCodeCoverage"))
        #expect(TestRunnerSelection.runner(TestRunner(), preference: .xcodebuild, locate: { tool.path }).xcodebuild == TestRunner().xcodebuild)
        #expect(TestRunnerSelection.runner(TestRunner(), preference: .swiftBuild, locate: { nil }).xcodebuild == TestRunner().xcodebuild)
        var stub = TestRunner()
        stub.xcodebuild = ["/bin/echo"]
        #expect(TestRunnerSelection.runner(stub, preference: .swiftBuild, locate: { tool.path }).xcodebuild == ["/bin/echo"])
    }

    @Test func ycodebuildSummaryFeedsCoveragePage() {
        let json = #"{"targets":[{"name":"App","coveredLines":3,"executableLines":4,"files":[{"path":"/x/A.swift","coveredLines":3,"executableLines":4}]}]}"#
        let items = CoverageModel.parseYcodebuildSummary(Data(json.utf8))
        #expect(items.map(\.name) == ["App"] && items.first?.files.map(\.name) == ["A.swift"])
        #expect(CoverageModel.total(items) == 0.75)
    }
}
