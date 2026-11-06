import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// The Linux IDE's Interface Builder editor (#79): a storyboard opens in
/// it from the workspace, the outline and inspectors read it, and the edit
/// the issue names (add a button, set its title, add a constraint) goes
/// through the editor's model and the Library; the file is written at once
/// and a file only looked at stays byte for byte. Runs on macOS and Linux.
@MainActor
@Suite struct InterfaceBuilderShellTests {
    static let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Samples/InterfaceBuilderSamples")

    /// A copy of the sample package in a fresh folder.
    func samplePackage() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-ib-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.copyItem(at: Self.samples, to: d)
        return d
    }

    @Test func storyboardsAndXibsOpenInTheEditor() throws {
        #expect(StructuredEditor.handles("Main.storyboard") && StructuredEditor.handles("Card.xib"))
        #expect(StructuredEditor.hasSourceView("Main.storyboard"))
        let d = try samplePackage()
        for name in ["Main.storyboard", "Card.xib"] {
            let p = d.appendingPathComponent("Interface/\(name)").path
            guard case .interfaceBuilder(let m)? = StructuredEditor.open(p) else { Issue.record("\(name) did not open"); continue }
            #expect(StructuredEditor.open(p)?.editorKind == .interfaceBuilder)
            #expect(StructuredEditor.open(p)?.title == "Interface Builder")
            #expect(m.inspectorTab == .attributes)
            #expect(!m.visibleRows.isEmpty && m.selected != nil)
        }
        // A file that is not XML opens as text.
        let bad = d.appendingPathComponent("Interface/Broken.storyboard")
        try "not xml".write(to: bad, atomically: true, encoding: .utf8)
        #expect(StructuredEditor.open(bad.path) == nil)
    }

    @Test func lookingAroundNeverWrites() throws {
        let d = try samplePackage()
        let p = d.appendingPathComponent("Interface/Main.storyboard").path
        let before = try Data(contentsOf: URL(fileURLWithPath: p))
        let m = try InterfaceBuilderShellModel(path: p)
        for v in m.visibleRows { m.select(row: v.row) }
        for t in IBInspectorTab.allCases { _ = m.inspectorSections(t) }
        m.zoomIn()
        m.isOutlineShown = false
        m.canvasIsDark = true
        m.device = "iPad Pro 11-inch"
        m.outlineFilter = "hello"
        m.isLibraryShown = true
        m.libraryFilter = "but"
        m.moveLibrarySelection(1)
        m.pointerDown(at: .zero)
        m.pointerUp(at: .zero)
        #expect(try Data(contentsOf: URL(fileURLWithPath: p)) == before)
        #expect(m.saveCount == 0)
    }

    @Test func addButtonTitleAndConstraintFromTheWorkspace() throws {
        let d = try samplePackage()
        let w = try WorkspaceShellModel(url: d, engine: ScriptedEngine(lines: [], issues: []))
        let p = d.appendingPathComponent("Interface/Main.storyboard").path
        let original = try Data(contentsOf: URL(fileURLWithPath: p))
        w.open(p)
        guard case .interfaceBuilder(let m)? = w.structuredEditor else { Issue.record("not in the IB editor"); return }
        #expect(w.editorKind == .interfaceBuilder)
        // Editor menu items follow the editor.
        #expect(w.editorActionState("zoomCanvasIn:")?.enabled == true)
        #expect(w.editorActionState("toggleDocumentOutline:")?.checked == true)
        #expect(w.editorActionState("zoomCanvasToPercent:", tag: 10_000)?.checked == true)
        // View ▸ Show Library, then the Library's Button (double-click inserts).
        #expect(w.performEditorAction("showLibrary:"))
        #expect(m.isLibraryShown)
        // The search rule (library.md §Search): every word in the name or class.
        m.libraryFilter = "UIButton"
        #expect(m.libraryObjects == [.button, .grayButton, .tintedButton, .filledButton, .pullDownButton, .popUpButton])
        #expect(m.librarySelection == .button)   // filtering selects the first match
        #expect(m.libraryDetail.hasPrefix("Button\nUIButton: "))
        m.libraryFilter = "stack view"
        #expect(m.libraryObjects == [.horizontalStackView, .verticalStackView] && m.librarySelection == .horizontalStackView)
        m.libraryIsIconView = true
        m.moveLibrarySelection(1)
        #expect(m.librarySelection == .verticalStackView)
        m.libraryFilter = ""
        #expect(m.libraryObjects.count == 80)
        m.librarySelection = .button
        m.select(id: "Rv1-aa-bb1")
        let id = try #require(m.insertFromLibrary())
        #expect(m.selectedID == id && m.document.byID[id]?.element == "button")
        // Attributes ▸ Control ▸ Title.
        #expect(m.controlState?.title == "Button")
        m.setTitle("Continue")
        #expect(m.controlState?.title == "Continue")
        // Editor ▸ Add New Constraints…: top spacing and centering.
        #expect(w.editorActionState("showAddConstraints:")?.enabled == true)
        #expect(w.performEditorAction("showAddConstraints:"))
        #expect(m.isAddConstraintsShown)
        let ids = m.addConstraints(.init(spacing: [.top: 24], centerX: true))
        #expect(ids.count == 2 && !m.isAddConstraintsShown)
        #expect(m.document.constraints(involving: id).count == 2)
        // Written at once, and the outline shows the new rows.
        let saved = try IBDocument(url: URL(fileURLWithPath: p))
        #expect(saved.title(of: id) == "Continue")
        #expect(saved.constraints(involving: id).contains { $0.firstAttribute == "centerX" })
        #expect(m.visibleRows.contains { $0.row.title == "Continue" && $0.row.badge == "Button" })
        // The Size inspector lists both constraints.
        let size = m.inspectorSections(.size).flatMap(\.rows)
        #expect(size.filter { if case .constraint = $0 { return true } else { return false } }.count == 2)
        // Undo everything: the original bytes.
        while m.canUndo { m.undo() }
        #expect(try Data(contentsOf: URL(fileURLWithPath: p)) == original)
    }

    @Test func canvasPointerMovesAndKeepsOthersUnchanged() throws {
        let d = try samplePackage()
        let p = d.appendingPathComponent("Interface/Main.storyboard").path
        let m = try InterfaceBuilderShellModel(path: p)
        let label = try #require(m.document.byID["Lb1-cd-ef1"])
        let r = try #require(m.layout.rect(of: label))
        m.pointerDown(at: CGPoint(x: r.midX, y: r.midY))
        #expect(m.selectedID == "Lb1-cd-ef1")
        m.pointerDragged(to: CGPoint(x: r.midX - 6, y: r.midY + 4))
        #expect(m.dragPreview == r.offsetBy(dx: -6, dy: 4))
        m.pointerUp(at: CGPoint(x: r.midX - 6, y: r.midY + 4))
        #expect(m.dragPreview == nil)
        #expect(m.document.byID["Lb1-cd-ef1"]?.frame == CGRect(x: 140, y: 204, width: 100, height: 21))
        // Only the label's frame line changed.
        let before = try String(contentsOf: Self.samples.appendingPathComponent("Interface/Main.storyboard"), encoding: .utf8).split(separator: "\n")
        let after = try String(contentsOfFile: p, encoding: .utf8).split(separator: "\n")
        #expect(before.count == after.count)
        #expect(zip(before, after).filter { $0 != $1 }.count == 1)
        // Inspector edits: a frame stepper and a View section choice.
        m.setFrameComponent("height", 30, of: "Lb1-cd-ef1")
        #expect(m.document.byID["Lb1-cd-ef1"]?.frame?.height == 30)
        let mode = try #require(m.inspectorSections(.attributes).flatMap(\.rows).first { $0.label == "Content Mode" })
        m.setChoice(mode, "center")
        #expect(m.document.byID["Lb1-cd-ef1"]?.attribute("contentMode") == "center")
        m.deleteSelection()
        #expect(m.document.byID["Lb1-cd-ef1"] == nil)
    }

    @Test func zoomAndOutlineFolding() throws {
        let d = try samplePackage()
        let m = try InterfaceBuilderShellModel(path: d.appendingPathComponent("Interface/Main.storyboard").path)
        m.zoom = 1
        m.zoomIn()
        #expect(m.zoom == 1.25 && m.zoomText == "125%")
        m.zoom = 99
        #expect(m.zoom == 4)
        m.perform("zoomCanvasToPercent:", tag: 5000)
        #expect(m.zoom == 0.5)
        m.zoomToFit(CGSize(width: 600, height: 400))
        #expect(m.zoom < 0.5 && m.zoom >= 0.1)
        let all = m.visibleRows.count
        let scene = try #require(m.visibleRows.first)
        m.setExpanded(scene.id, false)
        #expect(m.visibleRows.count < all && m.visibleRows.first?.isExpanded == false)
        m.setExpanded(scene.id, true)
        #expect(m.visibleRows.count == all)
        m.select(id: "Lb1-cd-ef1")
        m.moveSelection(1)
        #expect(m.selectedConstraint != nil || m.selectedID != "Lb1-cd-ef1")
    }
}
