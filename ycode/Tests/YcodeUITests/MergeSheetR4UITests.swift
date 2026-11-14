import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 4 on the merge workflow (`specs/ide/merge-sheet.md` §13,
/// checklist rows 97–103): the alert's and the sheet's buttons as
/// accessibility buttons, the window behind drawn disabled with its window
/// buttons above the veil, the content box ending 33 above the window, the
/// dark colours and token rims read back from the window, the Choose menu's
/// place, the jump bar's project and the footers' branch.
@MainActor
@Suite(.serialized) struct MergeSheetR4UITests {
    let base = MergeSheetUITests()
    typealias Repo = MergeSheetUITests.Repo

    /// The elements below `element` in accessibility order (depth first).
    static func walk(_ element: Any, depth: Int = 0, _ visit: (Any, Int) -> Void) {
        visit(element, depth)
        guard depth < 40, let e = element as? NSAccessibilityProtocol, let children = e.accessibilityChildren() else { return }
        for c in children { walk(c, depth: depth + 1, visit) }
    }

    static func role(_ e: Any) -> NSAccessibility.Role? { (e as? NSAccessibilityProtocol)?.accessibilityRole() }
    static func title(_ e: Any) -> String? {
        guard let a = e as? NSAccessibilityProtocol else { return nil }
        return a.accessibilityTitle() ?? a.accessibilityLabel()
    }

    /// Row 98: the alert's accessibility children are its texts and two
    /// buttons; Merge is the default and Cancel the cancel button; pressing
    /// them through accessibility acts as clicking.
    @Test func alertButtonsAreAccessibilityButtons() async throws {
        let r = try Repo("r4-alert-ax")
        defer { r.cleanUp() }
        let wc = try await r.window()
        let scm = wc.sourceControl
        let alert = try #require(scm.presentMergeAlert(branch: "feature"))

        // Walk the window's tree down to the alert (role sheet).
        let frame = try #require(wc.window?.contentView?.superview)
        var sheets: [NSAccessibilityProtocol] = []
        Self.walk(frame) { e, _ in if Self.role(e) == .sheet, let a = e as? NSAccessibilityProtocol { sheets.append(a) } }
        let ax = try #require(sheets.first { ($0 as AnyObject) === alert })
        // Round 7 (merge-sheet.md §16.1, row 195): no description on the sheet.
        #expect(ax.accessibilityLabel() == nil)
        let children = try #require(ax.accessibilityChildren())
        // Round 6 (§15.4, row 168): the reference's order, Merge, Cancel,
        // the message, the icon (an image with a description), the
        // informative text; round 7: an empty image before them.
        #expect(children.map { Self.role($0) } == [.image, .button, .button, .staticText, .image, .staticText], "\(children.map { Self.role($0)?.rawValue ?? "nil" })")
        #expect(children.compactMap { ($0 as? NSTextField)?.stringValue }
                == [MergeSheetText.alertTitle(branch: "feature"), MergeSheetText.alertMessage(branch: "feature", current: "main")])
        #expect((children[0] as? NSAccessibilityProtocol)?.accessibilityLabel() == nil)
        #expect((children[4] as? NSImageView)?.accessibilityLabel() == MergeSheetText.alertIconDescription)
        let buttons = children.compactMap { $0 as? MergeButton }
        #expect(buttons.map { Self.title($0) } == ["Merge", "Cancel"])
        #expect(buttons.allSatisfy { $0.isAccessibilityElement() && $0.isAccessibilityEnabled() })
        #expect((ax.accessibilityDefaultButton() as AnyObject?) === alert.mergeButton)
        #expect((ax.accessibilityCancelButton() as AnyObject?) === alert.cancelButton)
        // Hit-testing a button finds it (the capture's probe found nothing).
        let mid = NSPoint(x: alert.mergeButton.frame.midX, y: alert.mergeButton.frame.midY)
        #expect(alert.hitTest(alert.convert(mid, to: alert.superview)) === alert.mergeButton)

        // Cancel through accessibility closes the alert; Merge opens the sheet.
        #expect(alert.cancelButton.accessibilityPerformPress())
        #expect(scm.mergeOverlay == nil)
        let again = try #require(scm.presentMergeAlert(branch: "feature"))
        #expect(again.mergeButton.accessibilityPerformPress())
        await waitFor("source control") { await scm.idle() }
        let sheet = try #require(scm.mergeSheet)
        await waitFor("the merge sheet") { await sheet.idle() }

        // The sheet: Merge (disabled while a conflict is undecided) is its
        // default button, Cancel its cancel button.
        let sv = sheet.sheetView
        #expect(sv.accessibilityRole() == .sheet)
        #expect((sv.accessibilityDefaultButton() as AnyObject?) === sheet.mergeButton)
        #expect((sv.accessibilityCancelButton() as AnyObject?) === sheet.cancelButton)
        #expect(!sheet.mergeButton.isAccessibilityEnabled() && !sheet.mergeButton.accessibilityPerformPress())
        var sheetButtons: [String] = []
        Self.walk(sv) { e, _ in if [.button, .radioButton].contains(Self.role(e)), let t = Self.title(e) { sheetButtons.append(t) } }
        #expect(sheetButtons.contains("Cancel") && sheetButtons.contains("Merge"))
        // Ycode's drawn controls in the sheet are buttons too.
        #expect(sheetButtons.filter { $0.hasPrefix("Change ") }.count == 3)
        for t in ["Hierarchical", "Flat", "Previous Conflict", "Next Conflict", "Previous Change", "Next Change"] {
            #expect(sheetButtons.contains(t), "\(t) in \(sheetButtons)")
        }
        let flat = try #require(sheet.fileList.segmentElements.last)
        #expect(flat.accessibilityPerformPress() && sheet.isFlat)
        #expect(flat.frameInView == sheet.fileList.segmentFrames.flat)
        let next = try #require(sheet.footer.stepperElements.last)
        #expect(next.accessibilityPerformPress() && sheet.state.stepperText == "2/3")

        // Return merges once every conflict is decided.
        for h in 0..<2 {
            sheet.selectHunk(h)
            sheet.choose(.theirs)
        }
        #expect(sheet.mergeButton.isAccessibilityEnabled())
        sheet.cancelButton.performClick(nil)
        await eventually("the abort") { await scm.idle(); return scm.mergeOverlay == nil }
    }

    /// Row 97: behind the alert the window draws disabled (text at 0.63,
    /// toolbar buttons disabled, close disabled), its window buttons stay
    /// uncovered, and everything comes back once it closes.
    @Test func parentWindowDrawsDisabledUnderTheModal() async throws {
        let r = try Repo("r4-parent")
        defer { r.cleanUp() }
        let wc = try await r.window(dark: true)
        let w = try #require(wc.window)
        let scm = wc.sourceControl
        let close = try #require(w.standardWindowButton(.closeButton)), zoom = try #require(w.standardWindowButton(.zoomButton))
        let mini = try #require(w.standardWindowButton(.miniaturizeButton))
        let segments = (w.toolbar?.items ?? []).compactMap { $0.view as? NSSegmentedControl }
        #expect(!segments.isEmpty && segments.allSatisfy(\.isEnabled))
        #expect(close.isEnabled && w.contentView?.alphaValue == 1)

        scm.presentMergeAlert(branch: "feature")
        let overlay = try #require(scm.mergeOverlay)
        overlay.layoutSubtreeIfNeeded()
        let state = try #require(overlay.parentState)
        #expect(state.isApplied)
        // Only the close button is disabled.
        #expect(!close.isEnabled && mini.isEnabled && zoom.isEnabled)
        // Text at its disabled tone, toolbar buttons at theirs (AppKit's
        // disabled state), before the veil.
        #expect(abs((w.contentView?.alphaValue ?? 1) - 0.63) < 0.001)
        #expect(segments.allSatisfy { !$0.isEnabled })
        #expect(state.fadedViews.contains { $0 === w.contentView })
        // The window buttons are holes in the veil, and clicks reach them.
        #expect(overlay.windowButtonHoles.count == 3)
        let miniCircle = mini.convert(mini.bounds, to: overlay)
        #expect(overlay.windowButtonHoles.contains { $0.contains(NSPoint(x: miniCircle.midX, y: miniCircle.midY)) })
        let frameView = try #require(overlay.superview)
        let hit = frameView.hitTest(mini.convert(NSPoint(x: mini.bounds.midX, y: mini.bounds.midY), to: frameView))
        #expect(hit != nil && hit !== overlay && !(hit?.isDescendant(of: overlay) ?? true))
        // Elsewhere the overlay still takes every click.
        #expect(frameView.hitTest(NSPoint(x: frameView.bounds.midX, y: 300))?.isDescendant(of: overlay) == true)
        // The veil is about 0.70 (dark: black at 30 %).
        #expect(overlay.veil.opacity == Float(MergeSheetPalette.dark.veilOpacity) && MergeSheetPalette.dark.veilOpacity == 0.30)
        base.shot(wc, "r4-dark-alert")

        // Closing restores everything.
        overlay.alert?.cancel(nil)
        #expect(scm.mergeOverlay == nil)
        #expect(close.isEnabled && w.contentView?.alphaValue == 1 && segments.allSatisfy(\.isEnabled))
    }

    /// Row 99: the content box ends 33 above the window's bottom; the button
    /// row then runs past the window.
    @Test func contentBoxEnds33AboveTheWindow() async throws {
        let r = try Repo("r4-height")
        defer { r.cleanUp() }
        let wc = try await r.window()
        let sheet = try await base.openSheet(wc)
        let h = try #require(wc.window?.contentView?.superview?.bounds.height)
        let box = base.windowRect(sheet.sheetView.box, sheet.sheetView.box.bounds, wc)
        #expect(abs(box.maxY - (h - 33)) <= 0.5, "box to \(box.maxY) in a \(h)-point window")
        let sheetRect = base.windowRect(sheet.view, sheet.view.bounds, wc)
        #expect(abs(box.minY - (sheetRect.minY + 11.5)) <= 0.5)
        let merge = base.windowRect(sheet.mergeButton, sheet.mergeButton.bounds, wc)
        #expect(abs(merge.minY - box.maxY - 19) <= 0.5 && merge.maxY > h)
        #expect(sheetRect.maxY > h)
        sheet.cancelButton.performClick(nil)
        await eventually("the abort") { await wc.sourceControl.idle(); return wc.sourceControl.mergeOverlay == nil }
    }

    /// Rows 100, 101 and 103: the dark colours and the token rims read back
    /// from the window; the jump bar starts with the project; both footers
    /// name the current branch; the Choose menu opens 6 points higher.
    @Test func darkColoursTokensJumpBarAndFooters() async throws {
        let r = try Repo("r4-dark")
        defer { r.cleanUp() }
        let wc = try await r.window(dark: true)
        let sheet = try await base.openSheet(wc)
        let p = MergeSheetPalette.dark
        #expect(p.pane == 0x262627 && p.gutter == 0x313131 && p.gutterRule == 0x484848 && p.conflictRow == 0x583436
                && p.conflictWord == 0x9B3A3C && p.selectedRule == 0xDA5559 && p.cleanRow == 0x2F4457 && p.boxBorder == 0x171718
                && p.token == 0x575757 && p.selectedToken == 0x6D2A2D && p.sheet == 0x1D1E1F)
        let s = try base.snapshot(wc)
        let rows = sheet.canvas.rows
        let plain = try #require(rows.firstIndex { $0.kind == .same && $0.left?.number != sheet.canvas.currentLine.left })
        let rp = base.windowRect(sheet.canvas, sheet.canvas.rowRect(plain), wc)
        // A pane's background beyond its text, and the gutter's rules.
        #expect(base.same(s.color(rp.minX + sheet.canvas.leftWidth - 3, rp.midY), p.pane), "pane")
        #expect(base.same(s.color(rp.minX + sheet.canvas.leftWidth + 0.5, rp.midY), p.gutterRule), "gutter rule")
        // The box's dark hairline.
        let box = base.windowRect(sheet.sheetView.box, sheet.sheetView.box.bounds, wc)
        #expect(base.same(s.color(box.minX + 0.5, box.midY), p.boxBorder), "box border")
        // The unselected token: #575757 inside a lighter rim.
        let t1 = base.windowRect(sheet.canvas, try #require(sheet.canvas.tokenRect(forHunk: 1)), wc)
        #expect(base.same(s.color(t1.midX - 9, t1.midY), p.token, tolerance: 0.03), "token fill")
        let rim = try #require(s.color(t1.midX - 9, t1.minY + 0.25))
        #expect(rim.redComponent > CGFloat(MergeSheetPalette.components(p.token).r) + 0.01, "token rim lighter than its fill")
        base.shot(wc, "r4-dark-sheet")

        // The jump bar starts with the project ("Merger"); both footers name "main".
        #expect(sheet.project == MergeSheetProject(name: "Merger", folder: r.dir.path))
        #expect(sheet.state.jumpPath(root: sheet.repository.root.path, project: sheet.project) == ["Merger", "Sources", "Merger", "Greeting"])
        #expect(sheet.state.leftFooter?.branch == "main" && sheet.state.rightFooter?.branch == "main")
        #expect(sheet.state.leftFooter?.isHead == true && sheet.state.rightFooter?.isHead == false)
        #expect(sheet.state.leftFooter?.shortHash != sheet.state.rightFooter?.shortHash)

        // The Choose menu: 6 points higher than before; it tracks the pointer.
        let t0 = try #require(sheet.canvas.tokenRect(forHunk: 0))
        #expect(sheet.chooseMenuOrigin(forHunk: 0) == NSPoint(x: t0.midX, y: t0.maxY - 3))
        sheet.showChooseMenu(forHunk: 0)
        #expect(sheet.lastChooseMenu?.delegate === MergeChooseMenuTracking.shared)
        // When it opens, a mouse-moved event at the pointer is queued, so the
        // item under a resting pointer is highlighted at once.
        let moved = try #require(MergeChooseMenuTracking.pointerMovedEvent())
        #expect(moved.type == .mouseMoved, "\(moved.type)")
        #expect(abs(moved.locationInWindow.x - NSEvent.mouseLocation.x) <= 1 && abs(moved.locationInWindow.y - NSEvent.mouseLocation.y) <= 1,
                "\(moved.locationInWindow) against \(NSEvent.mouseLocation)")
        sheet.cancelButton.performClick(nil)
        await eventually("the abort") { await wc.sourceControl.idle(); return wc.sourceControl.mergeOverlay == nil }
    }

    /// The other drawn controls in Ycode's sheets: the New File sheet's
    /// template tiles are accessibility buttons that choose the template.
    @Test func templateTilesArePressable() {
        _ = NSApplication.shared
        let entry = TemplateEntry("Swift File", defaultName: "File", ext: "swift", symbol: "swift")
        let tile = TemplateTile(entry: entry)
        var chosen: TemplateEntry?
        tile.onClick = { chosen = $0 }
        #expect(tile.isAccessibilityElement() && tile.accessibilityRole() == .button && tile.accessibilityLabel() == entry.title)
        #expect(tile.accessibilityPerformPress() && chosen?.title == entry.title)
    }
}
