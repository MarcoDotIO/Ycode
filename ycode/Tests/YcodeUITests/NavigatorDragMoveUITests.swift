import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
import YcodeProject
@testable import YcodeUI

/// B5-FIX-NAV (P-042, `specs/ide/navigators.md` "A drag move and ⌘Z"; the
/// owner's decision of 2026-11-21): after a drag move in the project
/// navigator the moved file opens with the editor focused, and ⌘Z / Edit ▸
/// Undo leave the move in place. Offscreen windows only.
@MainActor
@Suite(.serialized) struct NavigatorDragMoveUITests {
    typealias Ops = ProjectNavigatorOperationsTests

    func row(_ wc: WorkspaceWindowController, id: String) -> OutlineItem? { Ops().row(wc, id: id) }

    /// Ends the run loop's undo group (each user action is its own event).
    func endEvent() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    static let readme = "0B0000000000000000000003"

    @Test func dragMoveOpensTheFileFocusesTheEditorAndIsNotUndone() throws {
        let s = try Ops.Sample()
        defer { s.remove() }
        let wc = try s.window()
        let window = try #require(wc.window)
        Ops().select(wc, ids: [Ops.model])
        wc.open(path: s.path("Nav/Model.swift"), line: nil)
        window.makeFirstResponder(wc.navigator.outlineView)
        endEvent()
        let readme = try #require(row(wc, id: Self.readme))
        let nav = try #require(row(wc, id: Ops.navGroup))
        let edit = try #require(wc.moveNavigatorRows([readme], to: nav, at: 0))
        #expect(edit.actionName == "Move")
        #expect(s.exists("Nav/README.md") && !s.exists("README.md"))
        // The moved file is open, its row selected, the editor focused.
        #expect(wc.editor.fileURL?.standardizedFileURL.path == s.path("Nav/README.md"))
        #expect(wc.navigator.selectedProjectRows.map(\.objectID) == [Self.readme])
        #expect(window.firstResponder === wc.editor.textView)
        // ⌘Z (Edit ▸ Undo through the window's undo manager) changes nothing.
        endEvent()
        let after = s.written
        #expect(window.undoManager?.canUndo == false)
        window.undoManager?.undo()
        #expect(s.written == after && s.exists("Nav/README.md"))
        #expect(wc.lastNavigatorError == nil)
        #expect(wc.editor.fileURL?.standardizedFileURL.path == s.path("Nav/README.md"))
    }

    @Test func earlierEntriesOfTheProjectGoAndOtherMovesKeepTheirUndo() throws {
        let s = try Ops.Sample()
        defer { s.remove() }
        let wc = try s.window()
        let um = try #require(wc.window?.undoManager)
        Ops().select(wc, ids: [Ops.model])
        #expect(wc.newNavigatorGroup(withFolder: true) != nil)
        endEvent()
        #expect(um.canUndo && um.undoActionName == "New Group")
        // The drag makes New Group's undo stale; it goes with no refusal.
        let readme = try #require(row(wc, id: Self.readme))
        let nav = try #require(row(wc, id: Ops.navGroup))
        #expect(wc.moveNavigatorRows([readme], to: nav, at: 0) != nil)
        endEvent()
        #expect(!um.canUndo && !um.canRedo)
        um.undo()
        #expect(wc.lastNavigatorError == nil && s.exists("Nav/README.md") && s.exists("Nav/New Group"))
        // Edit ▸ Paste ▸ Move Item Here keeps its undo (OPEN in the spec).
        Ops().select(wc, ids: [Ops.toolMain])
        wc.cutNavigatorSelection()
        Ops().select(wc, ids: [Ops.support])
        #expect(wc.moveCutItemsHere() != nil)
        endEvent()
        #expect(um.canUndo && um.undoActionName == "Move")
        let moved = s.written
        um.undo()
        #expect(s.written != moved)
    }

    @Test func screenshotsAfterTheDropAndAfterUndo() throws {
        let s = try Ops.Sample()
        defer { s.remove() }
        let wc = try s.window()
        let window = try #require(wc.window)
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: true)
        Ops().select(wc, ids: [Ops.model])
        wc.open(path: s.path("Nav/Model.swift"), line: nil)
        window.makeFirstResponder(wc.navigator.outlineView)
        endEvent()
        shot(wc, "fixnav-1-before.png")
        B5NavigatorTests().shot(wc, "fixnav-nav-1-before.png")   // the navigator alone (its glass does not draw in the window shot)
        let readme = try #require(row(wc, id: Self.readme))
        let nav = try #require(row(wc, id: Ops.navGroup))
        _ = try #require(wc.moveNavigatorRows([readme], to: nav, at: 0))
        endEvent()
        shot(wc, "fixnav-2-after-drop.png")
        B5NavigatorTests().shot(wc, "fixnav-nav-2-after-drop.png")   // the navigator alone (its glass does not draw in the window shot)
        window.undoManager?.undo()
        endEvent()
        shot(wc, "fixnav-3-after-undo.png")
        B5NavigatorTests().shot(wc, "fixnav-nav-3-after-undo.png")   // the navigator alone (its glass does not draw in the window shot)
        #expect(s.exists("Nav/README.md"))
    }

    /// The window's content, on the dark window colour (`.build-ide/b5-shots/`).
    func shot(_ wc: WorkspaceWindowController, _ name: String) {
        let dir = B5NavigatorTests.shots
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let v = wc.window?.contentView else { return }
        v.layoutSubtreeIfNeeded()
        wc.window?.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        let image = NSImage(size: v.bounds.size)
        image.lockFocus()
        NSColor(srgbRed: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x20 / 255.0, alpha: 1).setFill()
        NSRect(origin: .zero, size: v.bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: v.bounds.size))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) else { return }
        try? out.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
    }
}
