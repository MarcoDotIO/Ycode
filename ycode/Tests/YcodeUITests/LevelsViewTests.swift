import AppKit
import Foundation
import Testing
import YcodeProject
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct LevelsViewTests {
    @Test func strippedCopyKeepsOnlyThePlatform() throws {
        let url = ycodeDir.appendingPathComponent("Tests/YcodeProjectTests/Fixtures/Hello.xcodeproj")
        let s = DefaultsLevel.stripped(try PBXProj(contentsOf: url))
        let all = s.objects.values.filter { $0.isa == "XCBuildConfiguration" }.flatMap { $0["buildSettings"]?.dictionary?.keys ?? [] }
        #expect(Set(all).isSubset(of: ["SDKROOT", "SUPPORTED_PLATFORMS"]))
    }

    @Test func defaultsColumnAndProvidingLevel() throws {
        let helper = ycodeDir.appendingPathComponent("Tools/ycode-swb/.build/debug/ycode-swb").path
        guard FileManager.default.isExecutableFile(atPath: helper) else { return }
        setenv("YCODE_SWB", helper, 1)
        defer { unsetenv("YCODE_SWB") }
        _ = NSApplication.shared
        let dir = ycodeDir.appendingPathComponent(".build-ide/levels")
        try? FileManager.default.removeItem(at: dir)
        let proj = dir.appendingPathComponent("Hello.xcodeproj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: ycodeDir.appendingPathComponent("Tests/YcodeProjectTests/Fixtures/Hello.xcodeproj/project.pbxproj"),
                                         to: proj.appendingPathComponent("project.pbxproj"))
        let session = WorkspaceSession(model: try WorkspaceModel(url: proj))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.window?.setContentSize(NSSize(width: 1700, height: 900))
        wc.applyDefaultLayout()
        let pe = try #require(wc.openProjectEditor(proj.path))
        pe.select(tab: .buildSettings)
        pe.settingsView = .levels
        pe.filter = .all
        let bundle = try #require(pe.settingRows.first { $0.name == "PRODUCT_BUNDLE_IDENTIFIER" })
        #expect(bundle.providingLevel == "target")
        // A setting the project never assigns resolves from the defaults.
        let wrapper = try #require(pe.settingRows.first { $0.name == "WRAPPER_EXTENSION" })
        #expect(wrapper.defaults == "app" && wrapper.providingLevel == "defaults" && wrapper.resolved == "app")
        // A project-level assignment shadows the default.
        let sdk = try #require(pe.settingRows.first { $0.name == "SDKROOT" })
        #expect(sdk.project == "macosx" && sdk.providingLevel == "project")
        #expect(pe.settingRows.count > 200)
        pe.search = "PRODUCT_"
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "project-editor-levels.png")
    }
}
