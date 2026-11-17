import Foundation
import Testing
import YcodeEditorKit
import YcodeIDECore
@testable import YcodeIDEShell

/// B4-EDITOR on the Linux IDE's model (headless, on macOS and Linux):
/// P-003 (Find menu items through the editor-action hook), P-064 (pane
/// lanes), P-054 (doc-comment colour), P-083 (Quick Help links).
@MainActor
@Suite struct Beta4EditorShellTests {
    func model(_ pkg: TempPackage) throws -> WorkspaceShellModel {
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        m.recovery = EditorRecovery(directory: pkg.url.path + "/.recovery-test")
        return m
    }

    @Test func findMenuItemsWithAFileOpen() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        #expect(m.editorActionState("performFindPanelAction:", tag: 5)?.enabled == false)
        m.open(pkg.path("Package.swift"))
        for (a, t) in [("performFindPanelAction:", 4), ("performFindPanelAction:", 5), ("performFindPanelAction:", 6), ("replaceAndFindPrevious:", 0),
                       ("useSelectionForReplace:", 0), ("hideFindBar:", 0), ("findSelectedTextInWorkspace:", 0), ("findSelectedWordsInWorkspace:", 0)] {
            #expect(m.editorActionState(a, tag: t)?.enabled == true, "\(a) \(t)")
        }
        // Replace All through the menu: the bar shows its replace row.
        m.perform(.find)
        m.findBar.query = "Package"
        m.findBar.replacement = "Parcel"
        m.findBar.refresh()
        #expect(m.performEditorAction("performFindPanelAction:", tag: 4))
        #expect(m.editor?.buffer.text.contains("Parcel") == true && m.findBar.showsReplace)
        #expect(m.performEditorAction("hideFindBar:") && !m.findBar.isShown)
    }

    @Test func paneBelowStacksInTheFocusedColumn() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        m.open(pkg.path("Package.swift"))
        m.perform(.splitEditor)
        m.perform(.splitEditorBelow)
        #expect(m.panes.panes.map(\.lane) == [0, 1, 1] && m.panes.focused == 2)
        #expect(m.panes.laneGroups.map(\.panes.count) == [1, 2])
        m.closePane(m.panes.panes[2].id)
        #expect(m.panes.panes.map(\.lane) == [0, 1])
        m.closePane(m.panes.panes[0].id)
        #expect(m.panes.panes.map(\.lane) == [0])
    }

    @Test func docCommentsAndQuickHelpLinks() {
        let light = SourcePalette.forAppearance(dark: false)
        #expect(light.tokens[.docComment] == light.tokens[.comment])
        let sdk = QuickHelpDocument(hover: "```swift\nfunc f()\n```\n\nDoes *f*.", file: "/sdk/M.swiftinterface")
        #expect(!sdk.showsFileLink && sdk.showsDocumentationLink && sdk.runs(for: sdk.summary ?? "") == [QuickHelpRun("Does "), QuickHelpRun("f", .emphasis), QuickHelpRun(".")])
    }
}
