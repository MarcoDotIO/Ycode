import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// B4-POLISH (1.0.0-beta.4, council round 11) on the Linux IDE's model, as
/// the macOS IDE's `B4PolishTests`: the selection band across navigator
/// switches (P-035), the canvas beside editors that can't preview, and the
/// title area while paused. The find bar (P-003), ⌘0 (P-026) and the
/// Settings window's width (P-139) are views of the ycode-ide target,
/// checked by the `YCODE_IDE_B4POLISH` walk.
@MainActor
@Suite(.serialized) struct B4PolishShellTests {
    /// P-035: the open file's row keeps its band after ⌘2–⌘5 and ⌘1.
    @Test func projectSelectionSurvivesNavigatorSwitches() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        let file = pkg.path("Sources/DemoCore/Greeting.swift")
        let ids = try #require(m.root.idPath(to: file))
        m.selection = ids.last
        m.open(file)
        #expect(m.projectSelection == ids.last)
        for c in [ShellCommand.showSourceControlNavigator, .showSymbolNavigator, .showFindNavigator, .showIssueNavigator] {
            m.perform(c)
            #expect(m.isNavigatorShown && m.navigator != .project)
        }
        m.perform(.showProjectNavigator)
        #expect(m.navigator == .project && m.projectSelection == ids.last && m.selection == ids.last)
    }

    /// The canvas goes for an editor that can't preview and comes back
    /// with the next file that has previews; canvas mode stays on.
    @Test func canvasLeavesForEditorsThatCannotPreview() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let file = pkg.path("Sources/DemoCore/Card.swift")
        try PreviewCanvasShellTests.card.write(toFile: file, atomically: true, encoding: .utf8)
        let plist = pkg.path("Sources/DemoCore/Info.plist")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Name</key><string>Card</string></dict></plist>
        """.write(toFile: plist, atomically: true, encoding: .utf8)
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        m.previewCanvas.makeEngine = { FakePreviewEngine() }
        m.open(file)
        #expect(m.previewCanvas.isShown)
        m.open(plist)
        #expect(m.structuredEditor != nil && !m.previewCanvas.isShown && m.previewCanvas.isModeOn)
        m.open(file)
        #expect(m.previewCanvas.isShown)
    }

    /// While paused the title area is static: the mark, not the ring.
    @Test func pausedTitleAreaShowsTheMark() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        #expect(m.titleAreaIcon == .mark)
        m.session.noteToolActivity(.running("Running Demo"))
        #expect(m.titleAreaIcon == .ring && !m.isActivityPaused)
        m.session.noteToolActivity(.paused("Paused Demo"))
        #expect(m.titleAreaIcon == .mark && m.isActivityPaused && m.isBusy && m.activityText == "Paused Demo")
        m.session.noteToolActivity(.running("Running Demo"))
        #expect(m.titleAreaIcon == .ring)
        m.session.noteToolActivity(.finished("Finished running Demo"))
        #expect(m.titleAreaIcon == .mark)
        #expect(TitleAreaIcon.shown(busy: true, paused: true) == .mark && TitleAreaIcon.shown(busy: true, paused: false) == .ring)
    }
}
