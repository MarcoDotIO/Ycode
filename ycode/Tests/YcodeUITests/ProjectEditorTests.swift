import AppKit
import Foundation
import Testing
import YcodeProject
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor
@Suite(.serialized) struct ProjectEditorTests {
    func copyHello() throws -> (URL, String) {
        let dir = ycodeDir.appendingPathComponent(".build-ide/project-editor")
        try? FileManager.default.removeItem(at: dir)
        let proj = dir.appendingPathComponent("Hello.xcodeproj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let src = ycodeDir.appendingPathComponent("Tests/YcodeProjectTests/Fixtures/Hello.xcodeproj/project.pbxproj")
        try FileManager.default.copyItem(at: src, to: proj.appendingPathComponent("project.pbxproj"))
        return (proj, try String(contentsOf: src, encoding: .utf8))
    }

    @Test func editorShowsAndEditsTheProject() throws {
        _ = NSApplication.shared
        let (projURL, original) = try copyHello()
        let file = projURL.appendingPathComponent("project.pbxproj")
        let session = WorkspaceSession(model: try WorkspaceModel(url: projURL))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()

        // Selecting the project row opens the project editor.
        wc.open(path: projURL.path, line: nil)
        let pe = try #require(wc.projectEditor)
        #expect(wc.editor.auxiliary != nil && wc.editor.fileURL == nil)
        #expect(pe.selectedTarget == "Hello" && pe.tab == .general)
        #expect(ProjectEditorController.tabs(forTarget: true).map(\.rawValue) ==
                ["General", "Signing & Capabilities", "Resource Tags", "Info", "Build Settings", "Build Phases", "Build Rules"])
        pe.select(tab: .buildSettings)
        // reference-ui-5.md §11.1.1 (P1): the tab opens on Basic.
        #expect(pe.filter == .basic)

        // Settings with their levels.
        let bundle = try #require(pe.settingRows.first { $0.name == "PRODUCT_BUNDLE_IDENTIFIER" })
        #expect(bundle.resolved == "org.example.Hello-World" && bundle.target == "org.example.Hello-World" && bundle.project == nil)
        pe.search = "bundle"
        #expect(pe.settingRows.map(\.name) == ["PRODUCT_BUNDLE_IDENTIFIER"])
        pe.search = ""
        pe.filter = .basic
        #expect(pe.settingRows.map(\.name) == pe.model.basicSettingSections(target: "Hello", configuration: pe.configuration).flatMap(\.names))
        pe.filter = .customized
        pe.settingsView = .levels
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "project-editor-build-settings.png")

        // Editing writes the setting into both configurations, byte-locally.
        pe.setSetting("MARKETING_VERSION", "2.5")
        let edited = try String(contentsOf: file, encoding: .utf8)
        var pool = original.components(separatedBy: "\n")
        let added = edited.components(separatedBy: "\n").filter { l in
            if let i = pool.firstIndex(of: l) { pool.remove(at: i); return false }
            return true
        }
        #expect(added.count == 2 && added.allSatisfy { $0.contains("MARKETING_VERSION = 2.5;") } && pool.isEmpty)
        pe.select(tab: .general)
        pe.setSetting("MARKETING_VERSION", "")
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "project-editor-general.png")

        // Build phases: add a file to Compile Sources and remove it again.
        let sections = pe.model.phaseSections(target: "Hello")
        #expect(sections.first?.title == "Target Dependencies")
        #expect(sections.contains { $0.title == "Compile Sources" } && sections.contains { $0.script != nil })
        let sources = try #require(sections.first { $0.title == "Compile Sources" }?.phaseID)
        let bf = pe.addFile("Extra.swift", toPhase: sources)
        let withFile = try String(contentsOf: file, encoding: .utf8)
        #expect(withFile.contains("/* Extra.swift in Sources */"))
        #expect(session.model.root.allFiles.contains { $0.name == "Extra.swift" })
        pe.select(tab: .buildPhases)
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "project-editor-build-phases.png")
        pe.removeBuildFile(bf)
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("Extra.swift in Sources"))

        // The project's own tabs.
        pe.select(target: nil)
        #expect(pe.tab == .info) // Build Phases is not a project tab: the first tab is shown
        pe.select(tab: .info)
        #expect(pe.model.configurations(of: nil).names == ["Debug", "Release"])
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "project-editor-project-info.png")
    }
}
