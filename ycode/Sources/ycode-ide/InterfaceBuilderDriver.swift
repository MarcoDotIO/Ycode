import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_IB=<shot prefix>: a walk through the Interface Builder editor
// on OpenViews (#79). The workspace must hold Interface/Main.storyboard and
// Interface/Card.xib (Samples/InterfaceBuilderSamples). With the pointer and
// keyboard: select the label on the canvas, each inspector tab, the
// Library's Button (+ in the canvas bar, then Return), its title in the
// Attributes inspector, Add New Constraints (top spacing, centered), undo
// and redo; then the xib. Each step prints "ib <step>: ..." and writes
// <prefix>-<step>.png; at the end the storyboard is copied to
// <prefix>-result.storyboard for the macOS check. Run it once with
// OV_COLOR_SCHEME=dark for the dark shots.

#if os(Linux)
@MainActor
enum InterfaceBuilderDriver {
    static func say(_ s: String) { ShellDriver.say("ib " + s) }

    static func run(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("no workspace"); return }
        func shot(_ name: String) async {
            await ShellDriver.pause(0.7)
            say("shot \(name): " + OpenViewsAutomation.screenshot(to: "\(prefix)-\(name).png"))
        }
        func path(_ name: String) -> String? { w.root.allFiles.first { $0.name == name }?.path }
        func click(_ target: String, dx: CGFloat? = nil) async { await ShellDriver.click(target, dx: dx) }
        guard let p = path("Main.storyboard") else { say("no Main.storyboard"); return }
        let original = (try? Data(contentsOf: URL(fileURLWithPath: p))) ?? Data()
        w.isInspectorShown = true
        w.open(p)
        await ShellDriver.pause(1.0)
        guard case .interfaceBuilder(let m)? = w.structuredEditor else { say("not in the Interface Builder editor"); return }
        say("opened: editor=\(w.editorKind.rawValue) rows=\(m.visibleRows.count) zoom=\(m.zoomText) selected=\(m.selectedID ?? "-")")
        await shot("open")

        // A point on the canvas, in window points (the canvas starts
        // scrolled to its origin).
        func canvasPoint(_ c: CGPoint) -> CGPoint? {
            // The canvas's own frame, else its corner: right of the outline
            // (the bar's first button is 8 points in), under the jump bar strip.
            var origin = ShellDriver.frame("ib canvas content")?.origin
            if origin == nil, let bar = ShellDriver.frame("ib bar Hide Document Outline"), let strip = ShellDriver.frame("ib editor") {
                origin = CGPoint(x: bar.minX - 8, y: strip.maxY + 1)
            }
            guard let o = origin else { return nil }
            return CGPoint(x: o.x + c.x * m.zoom, y: o.y + c.y * m.zoom)
        }
        func clickCanvas(_ c: CGPoint) async {
            guard let at = canvasPoint(c) else { say("no canvas"); return }
            await OpenViewsAutomation.click(at: at)
            await ShellDriver.pause(0.4)
        }

        // The label, with the pointer: selection, handles and guides.
        if let label = m.document.byID["Lb1-cd-ef1"], let r = m.layout.rect(of: label) {
            await clickCanvas(CGPoint(x: r.midX, y: r.midY))
            say("canvas click label: selected=\(m.selectedID ?? "-") jump=\(m.jumpBarPath.joined(separator: " > "))")
            await shot("select-label")
        }
        for (i, t) in IBInspectorTab.allCases.enumerated() where t != .attributes {
            await click("inspector tab \(3 + i)")
            say("inspector \(t.title): shown=\(m.inspectorTab?.title ?? "none") sections=\(m.inspectorSections(t).map(\.title))")
            await shot("inspector-\(t.title.lowercased())")
        }
        await click("inspector tab 4")

        // The controller: its scene's objects in the title bar.
        await click("ib row GreetingViewController", dx: 70)
        say("outline click controller: selected=\(m.selectedID ?? "-") attributes=\(m.inspectorSections(.attributes).map(\.title))")
        await shot("select-controller")

        // The root view, then the Library's Button with Return.
        if let root = m.document.byID["Rv1-aa-bb1"], let r = m.layout.rect(of: root) {
            await clickCanvas(CGPoint(x: r.minX + 20, y: r.minY + 40))
            say("canvas click root: selected=\(m.selectedID ?? "-")")
        }
        await click("ib bar Library")
        say("library: shown=\(m.isLibraryShown) objects=\(m.libraryObjects.map(\.rawValue))")
        await shot("library")
        await click("ib library Button")
        // A single click is told from a double click after a short wait.
        await ShellDriver.pause(0.5)
        OpenViewsAutomation.press(.return)
        await ShellDriver.pause(0.6)
        let button = m.selectedID ?? ""
        say("library insert: selected=\(button) element=\(m.selected?.element ?? "-") title=\(m.controlState?.title ?? "-") saves=\(m.saveCount)")
        await click("ib bar Library")
        await shot("inserted")

        // Attributes ▸ Button ▸ Title, typed.
        await click("ib field @title")
        OpenViewsAutomation.press(.character("a"), modifiers: [.control])
        OpenViewsAutomation.type("Continue")
        OpenViewsAutomation.press(.return)
        await ShellDriver.pause(0.6)
        say("title typed: \(m.document.title(of: button) ?? "-") saves=\(m.saveCount)")
        await shot("title")

        // Add New Constraints: top spacing to the label, centered horizontally.
        await click("ib bar Add New Constraints")
        say("pin panel: shown=\(m.isAddConstraintsShown)")
        await shot("pin")
        await click("ib pin top")
        await click("ib pin center x")
        await click("ib pin add")
        await ShellDriver.pause(0.6)
        let cs = m.document.constraints(involving: button)
        say("constraints: \(cs.map { $0.text(m.document.name) }) panel=\(m.isAddConstraintsShown) saves=\(m.saveCount)")
        await shot("constraints")

        // Size inspector for the button: frame and its constraints.
        await click("inspector tab 5")
        await shot("size-button")
        await click("inspector tab 4")

        // Outline filter, then clear it.
        await click("ib outline filter")
        OpenViewsAutomation.type("cont")
        OpenViewsAutomation.press(.return)
        await ShellDriver.pause(0.5)
        say("outline filter: rows=\(m.visibleRows.map(\.row.title))")
        await shot("outline-filter")
        await click("ib outline filter")
        OpenViewsAutomation.press(.character("a"), modifiers: [.control])
        OpenViewsAutomation.press(.backspace)
        OpenViewsAutomation.press(.return)
        await ShellDriver.pause(0.4)

        // Zoom with the bar, and the dark canvas toggle.
        await click("ib bar Zoom In")
        say("zoom in: \(m.zoomText)")
        await click("ib bar Appearance")
        await shot("canvas-dark")
        await click("ib bar Appearance")

        // Undo and redo on the canvas (Ctrl+Z, Ctrl+Shift+Z).
        let edited = (try? Data(contentsOf: URL(fileURLWithPath: p))) ?? Data()
        if let label = m.document.byID["Lb1-cd-ef1"], let r = m.layout.rect(of: label) { await clickCanvas(CGPoint(x: r.midX, y: r.midY)) }
        OpenViewsAutomation.press(.character("z"), modifiers: [.control])
        await ShellDriver.pause(0.5)
        say("undo: constraints=\(m.document.constraints(involving: button).count)")
        OpenViewsAutomation.press(.character("z"), modifiers: [.control, .shift])
        await ShellDriver.pause(0.5)
        let redone = (try? Data(contentsOf: URL(fileURLWithPath: p))) ?? Data()
        say("redo: constraints=\(m.document.constraints(involving: button).count) bytes=\(redone == edited ? "as edited" : "DIFFERENT")")

        // The saved file: what the macOS IDE opens.
        let saved = try? IBDocument(url: URL(fileURLWithPath: p))
        say("saved: changed=\(original != redone) button=\(saved?.byID[button]?.element ?? "-") title=\(saved?.title(of: button) ?? "-") "
            + "constraints=\(saved?.constraints(involving: button).count ?? 0)")
        try? FileManager.default.removeItem(atPath: "\(prefix)-result.storyboard")
        try? FileManager.default.copyItem(atPath: p, toPath: "\(prefix)-result.storyboard")

        // The Library's UIKit objects and their inspectors (#84).
        await InterfaceBuilderLibraryDriver.run(m, prefix: prefix) {
            if let root = m.document.byID["Rv1-aa-bb1"], let r = m.layout.rect(of: root) { await clickCanvas(CGPoint(x: r.minX + 20, y: r.minY + 40)) }
        }
        try? FileManager.default.removeItem(atPath: "\(prefix)-library.storyboard")
        try? FileManager.default.copyItem(atPath: p, toPath: "\(prefix)-library.storyboard")

        // The xib: opened and left, never written.
        if let x = path("Card.xib") {
            let before = (try? Data(contentsOf: URL(fileURLWithPath: x))) ?? Data()
            w.open(x)
            await ShellDriver.pause(1.0)
            if case .interfaceBuilder(let xm)? = w.structuredEditor {
                say("xib: rows=\(xm.visibleRows.map(\.row.title))")
            }
            await shot("xib")
            say("xib round trip: \((try? Data(contentsOf: URL(fileURLWithPath: x))) == before ? "unchanged" : "CHANGED")")
        }
        say("done")
    }
}
#else
@MainActor
enum InterfaceBuilderDriver {
    static func run(_ app: ShellAppModel, prefix: String) async {}
}
#endif
