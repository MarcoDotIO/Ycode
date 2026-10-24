import AppKit
import Foundation
import Testing
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A macOS storyboard written for this test in the documented XML layout.
let sampleStoryboard = """
<?xml version="1.0" encoding="UTF-8"?>
<document type="com.apple.InterfaceBuilder3.Cocoa.Storyboard.XIB" version="3.0" toolsVersion="1" targetRuntime="MacOSX.Cocoa" propertyAccessControl="none" useAutolayout="YES" initialViewController="vc1">
    <dependencies>
        <plugIn identifier="com.apple.InterfaceBuilder.CocoaPlugin" version="1"/>
    </dependencies>
    <scenes>
        <scene sceneID="s1">
            <objects>
                <viewController id="vc1" customClass="ViewController" customModule="Demo" customModuleProvider="target" sceneMemberID="viewController">
                    <view key="view" id="root">
                        <rect key="frame" x="0.0" y="0.0" width="400" height="300"/>
                        <autoresizingMask key="autoresizingMask" flexibleMaxX="YES" flexibleMinY="YES"/>
                        <subviews>
                            <button verticalHuggingPriority="750" translatesAutoresizingMaskIntoConstraints="NO" id="btn">
                                <rect key="frame" x="150" y="20" width="100" height="32"/>
                                <buttonCell key="cell" type="push" title="Press" bezelStyle="rounded" alignment="center" id="btnCell">
                                    <font key="font" metaFont="system"/>
                                </buttonCell>
                                <connections>
                                    <action selector="press:" target="vc1" id="act1"/>
                                </connections>
                            </button>
                            <textField translatesAutoresizingMaskIntoConstraints="NO" id="lbl">
                                <rect key="frame" x="20" y="250" width="200" height="30"/>
                                <textFieldCell key="cell" title="Hello" id="lblCell"/>
                            </textField>
                        </subviews>
                        <constraints>
                            <constraint firstItem="btn" firstAttribute="centerX" secondItem="root" secondAttribute="centerX" id="c1"/>
                            <constraint firstAttribute="bottom" secondItem="btn" secondAttribute="bottom" constant="20" id="c2"/>
                        </constraints>
                    </view>
                    <connections>
                        <outlet property="label" destination="lbl" id="out1"/>
                    </connections>
                </viewController>
                <customObject id="fr1" userLabel="First Responder" customClass="NSResponder" sceneMemberID="firstResponder"/>
            </objects>
            <point key="canvasLocation" x="100" y="200"/>
        </scene>
    </scenes>
</document>
"""

/// An iOS xib (top-left coordinates).
let sampleXib = """
<?xml version="1.0" encoding="UTF-8"?>
<document type="com.apple.InterfaceBuilder3.CocoaTouch.XIB" version="3.0" toolsVersion="1" targetRuntime="iOS.CocoaTouch" useAutolayout="YES">
    <objects>
        <placeholder placeholderIdentifier="IBFilesOwner" id="-1" userLabel="File's Owner"/>
        <view contentMode="scaleToFill" id="top">
            <rect key="frame" x="0.0" y="0.0" width="320" height="200"/>
            <subviews>
                <view id="box">
                    <rect key="frame" x="10" y="20" width="100" height="80"/>
                    <subviews>
                        <label text="Inner" id="inner">
                            <rect key="frame" x="5" y="6" width="50" height="20"/>
                        </label>
                    </subviews>
                    <color key="backgroundColor" systemColor="systemBlueColor"/>
                </view>
            </subviews>
        </view>
    </objects>
</document>
"""

@MainActor
@Suite(.serialized) struct InterfaceBuilderTests {
    @Test func storyboardModel() throws {
        let doc = try IBDocument(data: Data(sampleStoryboard.utf8))
        #expect(doc.isStoryboard && doc.targetRuntime == "MacOSX.Cocoa" && doc.initialViewController == "vc1")
        let c = InterfaceBuilderController(document: doc)
        #expect(c.outlineTitles == [
            "ViewController Scene",
            "  ViewController",
            "    View",
            "      Press",
            "        Button Cell - Press",
            "      Hello",
            "        Text Field Cell - Hello",
            "      Constraints",
            "        Button - Press.centerX = View.centerX",
            "        View.bottom = Button - Press.bottom + 20",
            "  First Responder",
            "  Storyboard Entry Point",
        ])
        // Bottom-left frames become top-left in the root view.
        let btn = try #require(doc.byID["btn"]), lbl = try #require(doc.byID["lbl"])
        #expect(doc.frameInRoot(btn) == CGRect(x: 150, y: 248, width: 100, height: 32))
        #expect(doc.frameInRoot(lbl) == CGRect(x: 20, y: 20, width: 200, height: 30))
        #expect(doc.byID["s1"]?.canvasLocation == CGPoint(x: 100, y: 200))

        c.select(id: "btn")
        let attrs = c.inspectorRows(.attributes)
        #expect(attrs.contains { $0 == ("translatesAutoresizingMaskIntoConstraints", "NO") })
        #expect(attrs.contains { $0 == ("title", "Press") } && attrs.contains { $0 == ("Button Cell (cell)", "") })
        let size = c.inspectorRows(.size)
        #expect(size.contains { $0 == ("Width", "100") } && size.contains { $0 == ("", "Button - Press.centerX = View.centerX") })
        #expect(c.inspectorRows(.connections).contains { $0 == ("press:", "→ ViewController") })
        c.select(id: "vc1")
        let conns = c.inspectorRows(.connections)
        #expect(conns.contains { $0 == ("label", "→ Text Field - Hello") })
        #expect(conns.contains { $0 == ("press:", "← Button - Press") })
        c.select(id: "root")
        #expect(c.inspectorRows(.size).contains { $0 == ("Autoresizing", "flexibleMaxX, flexibleMinY") })
    }

    @Test func xibModelAndCanvasHit() throws {
        let doc = try IBDocument(data: Data(sampleXib.utf8))
        #expect(!doc.isStoryboard && doc.isFlippedRuntime)
        #expect(doc.roots.map(\.displayName) == ["File's Owner", "View"])
        let inner = try #require(doc.byID["inner"])
        #expect(doc.frameInRoot(inner) == CGRect(x: 15, y: 26, width: 50, height: 20))
        #expect(inner.displayName == "Label - Inner")
        let canvas = IBCanvasView(document: doc)
        #expect(canvas.placements.count == 1)
        let origin = canvas.placements[0].origin
        #expect(canvas.view(at: CGPoint(x: origin.x + 20, y: origin.y + 30))?.id == "inner")
        #expect(canvas.view(at: CGPoint(x: origin.x + 12, y: origin.y + 90))?.id == "box")
        #expect(canvas.view(at: CGPoint(x: origin.x + 300, y: origin.y + 190))?.id == "top")
        #expect(throws: (any Error).self) { try IBDocument(data: Data("<plist/>".utf8)) }
    }

    @Test func opensInWindow() throws {
        _ = NSApplication.shared
        let dir = ycodeDir.appendingPathComponent(".build-ide/ib")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/D"), withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"D\", targets: [.target(name: \"D\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let file = dir.appendingPathComponent("Main.storyboard")
        try sampleStoryboard.write(to: file, atomically: true, encoding: .utf8)
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)), loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        wc.open(path: file.path, line: nil)
        let ib = try #require(wc.interfaceEditor)
        #expect(ib.selected?.id == "root")
        ib.select(id: "btn")
        // The IB inspectors are in the window's inspector area.
        #expect(wc.inspector.tabNames == ["File", "History", "Quick Help", "Identity", "Attributes", "Size", "Connections"])
        #expect(wc.inspector.selectedIndex == 4)
        wc.inspector.select(5)
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "interface-builder.png")
        // Opening alone never writes the file.
        #expect(try String(contentsOf: file, encoding: .utf8) == sampleStoryboard)

        // Library Objects tab inserts into the selected view, written at once.
        let lib = wc.showLibrary(nil)
        _ = lib.view
        #expect(lib.objectsAvailable)
        lib.select(tab: .objects)
        #expect(lib.objects.map(\.rawValue) == ["Label", "Button", "Text Field", "Image View", "View", "Stack View"])
        ib.select(id: "root")
        #expect(lib.insert(row: 0))
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written.contains("title=\"Label\"") && written != sampleStoryboard)
        let drag = lib.tableView(lib.table, pasteboardWriterForRow: 1) as? NSPasteboardItem
        #expect(drag?.string(forType: IBCanvasView.objectType) == "Button")
        ib.undo()
        #expect(try String(contentsOf: file, encoding: .utf8) == sampleStoryboard)
        _ = try WindowSnapshotTests().render(lib.view, to: "library-objects.png")

        // Leaving the document removes its inspectors and the Objects tab.
        wc.open(path: dir.appendingPathComponent("Package.swift").path, line: nil)
        #expect(wc.inspector.tabNames.count == 3 && !lib.objectsAvailable)
    }

    func lines(_ s: String) -> [String] { s.components(separatedBy: "\n") }

    /// Lines of `b` not in `a`, and of `a` not in `b` (positional diff of
    /// equal-length files, or added lines otherwise).
    func changed(_ a: String, _ b: String) -> [String] {
        let x = lines(a), y = lines(b)
        if x.count == y.count { return zip(x, y).filter { $0 != $1 }.map(\.1) }
        var pool = x
        return y.filter { l in if let i = pool.firstIndex(of: l) { pool.remove(at: i); return false }; return true }
    }

    @Test func byteMinimalEditsAndUndo() throws {
        let doc = try IBDocument(data: Data(sampleStoryboard.utf8))
        let c = InterfaceBuilderController(document: doc)
        _ = c.view
        func text() -> String { String(decoding: c.document.source, as: UTF8.self) }
        c.select(id: "btn")
        c.setFrame(CGRect(x: 160, y: 24.5, width: 120, height: 32))
        #expect(changed(sampleStoryboard, text()) == ["                                <rect key=\"frame\" x=\"160\" y=\"24.5\" width=\"120\" height=\"32\"/>"])
        c.setTitle("Go & \"Run\"")
        #expect(changed(sampleStoryboard, text()).count == 2)
        #expect(text().contains("title=\"Go &amp; &quot;Run&quot;\" bezelStyle"))
        #expect(c.document.title(of: "btn") == "Go & \"Run\"")
        c.setHidden(true)
        #expect(text().contains("<button verticalHuggingPriority=\"750\" translatesAutoresizingMaskIntoConstraints=\"NO\" id=\"btn\" hidden=\"YES\">"))
        c.setEnabled(false)
        #expect(c.document.isEnabled("btn") == false && text().contains("id=\"btnCell\" enabled=\"NO\">"))
        c.setAlignment("left")
        #expect(c.document.alignment(of: "btn") == "left")
        c.select(id: "lbl")
        c.setPlaceholder("Name")
        #expect(text().contains("<textFieldCell key=\"cell\" title=\"Hello\" id=\"lblCell\" placeholderString=\"Name\"/>"))
        // Turning flags back to their defaults removes the attributes.
        c.select(id: "btn")
        c.setHidden(false)
        c.setEnabled(true)
        #expect(!text().contains("hidden=") && !text().contains("enabled="))
        // Undo everything: the original bytes.
        while c.canUndo { c.undo() }
        #expect(text() == sampleStoryboard)
        c.redo()
        #expect(changed(sampleStoryboard, text()).count == 1)
    }

    @Test func insertingKeepsTheRestOfTheFile() throws {
        let c = InterfaceBuilderController(document: try IBDocument(data: Data(sampleXib.utf8)))
        _ = c.view
        c.select(id: "inner")
        // A view without subviews gets a subviews element.
        c.select(id: "box")
        let id = try #require(c.insert(.button))
        #expect(id.range(of: "^[A-Za-z0-9]{3}-[A-Za-z0-9]{2}-[A-Za-z0-9]{3}$", options: .regularExpression) != nil)
        let t = String(decoding: c.document.source, as: UTF8.self)
        #expect(changed(sampleXib, t).count == 4)
        #expect(t.contains("""
                            <button opaque="NO" contentMode="scaleToFill" contentHorizontalAlignment="center" contentVerticalAlignment="center" buttonType="system" translatesAutoresizingMaskIntoConstraints="NO" id="\(id)">
                                <rect key="frame" x="5" y="24" width="90" height="32"/>
                                <state key="normal" title="Button"/>
                            </button>
                        </subviews>
    """))
        #expect(c.document.byID[id]?.parent?.id == "box" && c.selected?.id == id)
        c.select(id: "inner")
        let id2 = try #require(c.insert(.label))
        let t2 = String(decoding: c.document.source, as: UTF8.self)
        #expect(t2.contains("""
                                <rect key="frame" x="5" y="6" width="50" height="20"/>
                                <subviews>
                                    <label opaque="NO"
    """))
        #expect(c.document.byID[id2]?.parent?.id == "inner")
        c.undo(); c.undo()
        #expect(String(decoding: c.document.source, as: UTF8.self) == sampleXib)
    }

    @Test func canvasDragResizeZoomAndPlacement() throws {
        let c = InterfaceBuilderController(document: try IBDocument(data: Data(sampleStoryboard.utf8)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = c
        let canvas = c.canvas
        // The scene is centered on its canvas location.
        let box = try #require(canvas.sceneBox(c.document.roots[0]))
        #expect(box.size == CGSize(width: 400, height: 300) && box.minX == IBCanvasView.margin)
        #expect(canvas.entryPoint != nil)
        // Move the button 10 right and 5 down (bottom-left storage: y − 5).
        let btn = try #require(canvas.rect(of: c.document.byID["btn"]!))
        canvas.beginDrag(at: CGPoint(x: btn.midX, y: btn.midY))
        #expect(c.selected?.id == "btn")
        canvas.continueDrag(to: CGPoint(x: btn.midX + 10, y: btn.midY + 5))
        canvas.endDrag(at: CGPoint(x: btn.midX + 10, y: btn.midY + 5))
        #expect(c.document.byID["btn"]?.frame == CGRect(x: 160, y: 15, width: 100, height: 32))
        // Resize from the bottom-right handle.
        let r = try #require(canvas.rect(of: c.document.byID["btn"]!))
        canvas.beginDrag(at: CGPoint(x: r.maxX, y: r.maxY))
        canvas.endDrag(at: CGPoint(x: r.maxX + 20, y: r.maxY + 8))
        #expect(c.document.byID["btn"]?.frame == CGRect(x: 160, y: 7, width: 120, height: 40))
        c.setZoom(1)
        c.zoomIn()
        #expect(abs(c.zoom - 1.25) < 0.001)
        c.zoomOut()
        c.zoomToFit()
        #expect(c.zoom <= 1)
    }

    @Test func deleteMoveAndConstraints() throws {
        let c = InterfaceBuilderController(document: try IBDocument(data: Data(sampleStoryboard.utf8)))
        _ = c.view
        func text() -> String { String(decoding: c.document.source, as: UTF8.self) }

        // Deleting the button removes it, its constraints, and the action;
        // nothing else changes.
        c.select(id: "btn")
        c.deleteSelection()
        let t = text()
        #expect(c.document.byID["btn"] == nil && c.selected?.id == "root")
        #expect(!t.contains("btn") && !t.contains("<constraints>"))
        #expect(changed(t, sampleStoryboard).count == 13)
        #expect(t.contains("<outlet property=\"label\" destination=\"lbl\" id=\"out1\"/>"))
        c.undo()
        #expect(text() == sampleStoryboard)

        // Deleting a constraint (selected in the outline).
        c.selectConstraint("c2")
        c.deleteSelection()
        #expect(!text().contains("id=\"c2\"") && text().contains("id=\"c1\""))
        #expect(changed(text(), sampleStoryboard) == ["                            <constraint firstAttribute=\"bottom\" secondItem=\"btn\" secondAttribute=\"bottom\" constant=\"20\" id=\"c2\"/>"])
        c.undo()

        // Editing a constant.
        c.setConstant(24, ofConstraint: "c2")
        #expect(text().contains("secondAttribute=\"bottom\" constant=\"24\" id=\"c2\""))
        c.setConstant(0, ofConstraint: "c2")
        #expect(text().contains("secondAttribute=\"bottom\" id=\"c2\""))
        c.undo(); c.undo()
        #expect(text() == sampleStoryboard)

        // Re-parent the label into a new box, keeping its canvas position.
        c.select(id: "root")
        let box = try #require(c.insert(.view))
        let before = try #require(c.canvas.rect(of: c.document.byID["lbl"]!))
        #expect(c.move("lbl", into: box))
        #expect(c.document.byID["lbl"]?.parent?.id == box)
        #expect(c.canvas.rect(of: c.document.byID["lbl"]!) == before)
        #expect(!c.move(box, into: "lbl"))
        // The moved element keeps its own lines (re-indented one level).
        #expect(text().contains("""
                                        <textField translatesAutoresizingMaskIntoConstraints="NO" id="lbl">
        """))
        while c.canUndo { c.undo() }
        #expect(text() == sampleStoryboard)

        // Add New Constraints: nearest neighbors, size, centering.
        c.select(id: "lbl")
        #expect(c.document.nearestNeighbor(of: "lbl", edge: .top)?.id == "root")
        #expect(c.document.nearestNeighbor(of: "lbl", edge: .top)?.spacing == 20)
        #expect(c.document.nearestNeighbor(of: "lbl", edge: .leading)?.spacing == 20)
        #expect(c.document.nearestNeighbor(of: "btn", edge: .top)?.id == "lbl")
        let pop = try #require(c.showAddConstraints())
        _ = pop.view
        pop.edgeChecks[.top]?.state = .on
        pop.edgeChecks[.leading]?.state = .on
        pop.edgeChecks[.trailing]?.state = .on
        pop.widthCheck.state = .on
        pop.centerYCheck.state = .on
        #expect(pop.spec == .init(spacing: [.top: 20, .leading: 20, .trailing: 180], width: 200, centerY: true))
        pop.addClicked()
        let added = changed(sampleStoryboard, text())
        #expect(added.count == 7)
        #expect(added.contains { $0.contains("<constraint firstItem=\"lbl\" firstAttribute=\"top\" secondItem=\"root\" secondAttribute=\"top\" constant=\"20\" id=") })
        #expect(added.contains { $0.contains("<constraint firstAttribute=\"trailing\" secondItem=\"lbl\" secondAttribute=\"trailing\" constant=\"180\" id=") })
        #expect(added.contains { $0.contains("<constraint firstItem=\"lbl\" firstAttribute=\"centerY\" secondItem=\"root\" secondAttribute=\"centerY\" id=") })
        let ls = lines(text()).map { $0.trimmingCharacters(in: .whitespaces) }
        let at = try #require(ls.firstIndex(of: #"<rect key="frame" x="20" y="250" width="200" height="30"/>"#))
        #expect(ls[at + 1] == "<constraints>" && ls[at + 2].hasPrefix(#"<constraint firstAttribute="width" constant="200" id="#) && ls[at + 3] == "</constraints>")
        #expect(c.document.constraints(involving: "lbl").count == 5)
        c.undo()
        #expect(text() == sampleStoryboard)
    }

    @Test func windowsSeguesAndScenes() throws {
        let sb = """
        <?xml version="1.0" encoding="UTF-8"?>
        <document type="com.apple.InterfaceBuilder3.Cocoa.Storyboard.XIB" version="3.0" toolsVersion="1" targetRuntime="MacOSX.Cocoa" initialViewController="wc1">
            <scenes>
                <scene sceneID="sA">
                    <objects>
                        <windowController id="wc1" sceneMemberID="viewController">
                            <window key="window" title="Main" id="win">
                                <rect key="contentRect" x="196" y="240" width="480" height="270"/>
                                <view key="contentView" id="cv">
                                    <rect key="frame" x="0.0" y="0.0" width="480" height="270"/>
                                </view>
                            </window>
                            <connections>
                                <segue destination="vc2" kind="relationship" relationship="window.shadowedContentViewController" id="sg1"/>
                            </connections>
                        </windowController>
                    </objects>
                    <point key="canvasLocation" x="0" y="0"/>
                </scene>
                <scene sceneID="sB">
                    <objects>
                        <viewController id="vc2" sceneMemberID="viewController">
                            <view key="view" id="v2">
                                <rect key="frame" x="0.0" y="0.0" width="300" height="200"/>
                            </view>
                        </viewController>
                    </objects>
                    <point key="canvasLocation" x="700" y="0"/>
                </scene>
            </scenes>
        </document>
        """
        let c = InterfaceBuilderController(document: try IBDocument(data: Data(sb.utf8)))
        c.view.appearance = NSAppearance(named: .aqua)
        let canvas = c.canvas
        #expect(c.document.byID["win"]?.contentRect == CGRect(x: 196, y: 240, width: 480, height: 270))
        let a = try #require(canvas.sceneBox(c.document.roots[0])), b = try #require(canvas.sceneBox(c.document.roots[1]))
        #expect(a.height == 270 + 28 && b.midX - a.midX == 700 && abs(b.midY - a.midY) < 0.01)
        #expect(canvas.segueLines.count == 1 && canvas.segueLines[0].from.x == a.maxX && canvas.segueLines[0].to.x == b.minX)
        #expect(canvas.entryPoint?.to.x == a.minX - 4)
        c.select(id: "cv")
        #expect(c.inspectorRows(.identity).contains { $0 == ("Object ID", "cv") })
        c.view.setFrameSize(NSSize(width: 1100, height: 600))
        c.view.layoutSubtreeIfNeeded()
        c.zoomToFit()
        _ = try WindowSnapshotTests().render(canvas, to: "interface-builder-scenes.png")
    }
}
