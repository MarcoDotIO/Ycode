import Foundation
import Testing
import YcodeIDECore

/// The Interface Builder editor state both IDEs share (`IBEditorSession`,
/// `IBCanvasLayout`), on the sample documents in
/// `Samples/InterfaceBuilderSamples` (written for Ycode): opening never
/// writes, the edits #79 names (add a button, set its title, add a
/// constraint) touch only their lines, and undo gives the original bytes.
/// Runs on macOS and Linux.
@Suite struct IBEditorSessionTests {
    static let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Samples/InterfaceBuilderSamples/Interface")

    /// A copy of a sample in a fresh folder (edits write the file).
    func copy(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ib-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let to = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: Self.samples.appendingPathComponent(name), to: to)
        return to
    }

    func lines(_ d: Data) -> [Substring] { String(decoding: d, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) }

    @Test(arguments: ["Main.storyboard", "Card.xib"])
    func openingNeverWrites(_ name: String) throws {
        let url = try copy(name)
        let before = try Data(contentsOf: url)
        let s = try IBEditorSession(url: url)
        // Looking around changes nothing on disk.
        for r in s.outlineRows { s.select(row: r) }
        for t in IBInspectorTab.allCases { _ = s.inspectorSections(t) }
        s.outlineFilter = "Hello"
        _ = s.outlineRows
        #expect(try Data(contentsOf: url) == before)
        #expect(s.saveCount == 0 && !s.canUndo)
        // A no-op edit (the same value) writes nothing either.
        if let id = s.selectedID, let t = s.document.title(of: id) { s.setTitle(t) }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func addButtonSetTitleAddConstraintThenUndoAll() throws {
        let url = try copy("Main.storyboard")
        let original = try Data(contentsOf: url)
        let s = try IBEditorSession(url: url)
        #expect(s.document.isStoryboard && s.document.isFlippedRuntime)
        #expect(s.selectedID == "Rv1-aa-bb1")   // the first view

        // Add a button to the first scene's view.
        let id = try #require(s.insert(.button))
        #expect(s.selectedID == id)
        let button = try #require(s.document.byID[id])
        #expect(button.element == "button" && button.parent?.id == "Rv1-aa-bb1")
        #expect(s.document.title(of: id) == "Button")

        // Set its title.
        s.setTitle("Continue")
        #expect(s.document.title(of: id) == "Continue")

        // Add constraints: top spacing to the label above it, and a width.
        let suggested = try #require(s.suggestedConstraints)
        #expect(suggested.spacing[.top]?.neighbor == "Label - Hello")
        let ids = s.addConstraints(.init(spacing: [.top: 20], width: 90))
        #expect(ids.count == 2)
        let cs = s.document.constraints(involving: id)
        #expect(cs.contains { $0.firstAttribute == "top" && $0.secondItem == "Lb1-cd-ef1" && $0.constant == "20" })
        #expect(cs.contains { $0.firstAttribute == "width" && $0.constant == "90" })
        #expect(s.saveCount == 3)

        // Written at once; only the new lines and the button's lines differ.
        let saved = try Data(contentsOf: url)
        #expect(saved == Data(s.document.source))
        let before = lines(original), after = lines(saved)
        #expect(after.count > before.count)
        let kept = before.filter { after.contains($0) }
        #expect(kept.count == before.count)

        // The file parses again as the same document, and the outline shows it.
        let reopened = try IBDocument(url: url)
        #expect(reopened.title(of: id) == "Continue")
        #expect(IBEditorSession(document: reopened).outlineTitles().contains("      Continue"))

        // Undo every edit: the original bytes.
        while s.canUndo { s.undo() }
        #expect(try Data(contentsOf: url) == original)
        s.redo()
        #expect(s.document.byID[id] != nil)
    }

    @Test func outlineJumpBarAndSelection() throws {
        let url = Self.samples.appendingPathComponent("Main.storyboard")
        let s = IBEditorSession(document: try IBDocument(url: url), url: url)
        #expect(s.outlineRows.first?.kind == .scene)
        let titles = s.outlineTitles(badges: true)
        #expect(titles.prefix(9) == [
            "GreetingViewController Scene",
            "  GreetingViewController",
            "    View",
            "      Safe Area",
            "      Hello [Label]",
            "      Constraints",
            "        Label - Hello.centerX = View.centerX",
            "        Label - Hello.top = View Layout Guide.top + 141",
            "  First Responder",
        ])
        #expect(titles.contains("  Storyboard Entry Point"))
        s.select(id: "Lb1-cd-ef1")
        #expect(s.jumpBarPath == ["Main.storyboard", "GreetingViewController Scene", "GreetingViewController", "View", "Hello"])
        let constraintRow = try #require(s.outlineRows.first?.children.first?.children.first?.children.first { $0.kind == .constraints }?.children.first)
        s.select(row: constraintRow)
        #expect(s.selectedConstraint == "Cx1-kl-mn1")
        #expect(s.jumpBarPath.suffix(2) == ["Constraints", "Label - Hello.centerX = View.centerX"])
        s.outlineFilter = "hello"
        #expect(s.outlineTitles().contains("      Hello") && !s.outlineTitles().contains("  First Responder"))
    }

    @Test func canvasLayoutHitTestAndDrag() throws {
        let url = try copy("Main.storyboard")
        let s = try IBEditorSession(url: url)
        let l = s.layout
        #expect(l.placements.count == 2)
        #expect(l.placements.map(\.title) == ["GreetingViewController", "View Controller"])
        // Canvas locations are centres; everything starts at the margin.
        #expect(l.contentBounds.minX == IBCanvasLayout.margin && l.contentBounds.minY == IBCanvasLayout.margin)
        #expect(l.placements[1].origin.x - l.placements[0].origin.x == 520)
        #expect(l.segueLines.count == 1 && l.segueLines[0].kind == "show")
        #expect(l.entryPoint?.to.x == l.placements[0].origin.x - 4)
        // The deepest view under a point is the label.
        let label = try #require(s.document.byID["Lb1-cd-ef1"])
        let r = try #require(l.rect(of: label))
        #expect(l.view(at: CGPoint(x: r.midX, y: r.midY))?.id == "Lb1-cd-ef1")
        // Dragging the label's body by (10, 5) moves its stored frame.
        let (hit, drag) = IBCanvasDrag.begin(at: CGPoint(x: r.midX, y: r.midY), selected: s.selectedID, in: l)
        #expect(hit?.id == "Lb1-cd-ef1")
        let d = try #require(drag)
        let to = CGPoint(x: r.midX + 10, y: r.midY + 5)
        #expect(d.preview(at: to) == r.offsetBy(dx: 10, dy: 5))
        s.setRootFrame(try #require(d.result(at: to)), of: d.id)
        #expect(s.document.byID["Lb1-cd-ef1"]?.frame == CGRect(x: 156, y: 205, width: 100, height: 21))
        // A handle of the selected view resizes it.
        s.select(id: "Lb1-cd-ef1")
        let r2 = try #require(s.layout.rect(of: s.document.byID["Lb1-cd-ef1"]!))
        let (_, resize) = IBCanvasDrag.begin(at: CGPoint(x: r2.maxX, y: r2.maxY), selected: s.selectedID, in: s.layout)
        #expect(resize?.handle == .bottomRight)
        // Root views are selected but not dragged.
        let root = try #require(s.layout.rect(of: s.document.byID["Rv1-aa-bb1"]!))
        let (rootHit, rootDrag) = IBCanvasDrag.begin(at: CGPoint(x: root.minX + 2, y: root.maxY - 2), selected: nil, in: s.layout)
        #expect(rootHit?.id == "Rv1-aa-bb1" && rootDrag == nil)
        #expect(s.layout.zoomToFit(CGSize(width: 100_000, height: 100_000)) == 1)
        // Selecting a controller shows its scene's objects in the title bar.
        let first = s.layout.placements[0]
        #expect(s.layout.sceneBarIcons(first, selected: "Lb1-cd-ef1").isEmpty)
        let icons = s.layout.sceneBarIcons(first, selected: "Gr1-vc-mn1")
        #expect(icons.map(\.id) == ["Gr1-vc-mn1", "Fr1-ab-cd2"] && icons.map(\.symbol) == ["square.dashed", "cube"])
        #expect(icons.allSatisfy { s.layout.sceneBar(first).contains($0.rect) })
        #expect(s.layout.sceneBarIcons(s.layout.placements[1], selected: "Gr1-vc-mn1").isEmpty)
        // The overview fits both scenes in its panel, side by side.
        let panel = CGSize(width: 150, height: 96)
        let (k, boxes) = s.layout.overview(in: panel)
        #expect(boxes.count == 2 && k > 0 && boxes[0].maxX < boxes[1].minX)
        #expect(boxes.allSatisfy { CGRect(origin: .zero, size: panel).insetBy(dx: 7.9, dy: 7.9).contains($0) })
        #expect(s.layout.overviewRect(s.layout.placements[0].full, in: panel) == boxes[0])
        #expect(IBCanvasLayout.clampZoom(9) == 4 && IBCanvasLayout.clampZoom(0.01) == 0.1)
    }

    @Test func everyLibraryObjectInsertsEditsAndSaves() throws {
        for name in ["Main.storyboard", "Card.xib"] {
            let url = try copy(name)
            let s = try IBEditorSession(url: url)
            for kind in IBDocument.NewObject.allCases {
                let root = try #require(IBEditorSession.firstView(in: s.document))
                s.select(id: root.id)
                let id = try #require(s.insert(kind), "\(kind) into \(name)")
                // Attributes: every view has the View section; hidden toggles.
                let sections = s.inspectorSections(.attributes)
                #expect(sections.contains { $0.title == "View" })
                s.setHidden(true)
                #expect(s.document.isHidden(id))
                s.setFrameComponent("width", 77, of: id)
                #expect(s.document.byID[id]?.frame?.width == 77)
                if s.controlState?.title != nil { s.setTitle("T \(kind.rawValue)"); #expect(s.document.title(of: id) == "T \(kind.rawValue)") }
                if s.controlState?.placeholder != nil { s.setPlaceholder("P"); #expect(s.document.placeholder(of: id) == "P") }
                s.setAttribute("userLabel", "Mine \(kind.rawValue)", of: id)
                #expect(try IBDocument(url: url).byID[id]?.attribute("userLabel") == "Mine \(kind.rawValue)")
            }
            #expect(IBDocument.NewObject.allCases.allSatisfy { !$0.summary.isEmpty && $0.iconShapes.count > 1 })
        }
        #expect(IBDocument.NewObject.matching("stack") == [.stackView])
    }

    @Test func deleteSelectionRemovesConstraintsAndOutlets() throws {
        let url = try copy("Main.storyboard")
        let s = try IBEditorSession(url: url)
        s.select(id: "Lb1-cd-ef1")
        #expect(s.deleteSelection())
        #expect(s.document.byID["Lb1-cd-ef1"] == nil)
        #expect(s.document.constraintNode("Cx1-kl-mn1") == nil)
        #expect(s.document.byID["Gr1-vc-mn1"]?.connections.contains { $0.kind == .outlet } == false)
        #expect(s.selectedID == "Rv1-aa-bb1")
        // Root views are never deleted.
        #expect(!s.deleteSelection())
    }
}
