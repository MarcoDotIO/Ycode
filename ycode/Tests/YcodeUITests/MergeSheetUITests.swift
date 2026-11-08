import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// The merge workflow in the macOS window (`specs/ide/merge-sheet.md`,
/// council round 3 rows 52–61): the branch row menu, the confirmation
/// alert, the sheet's frame, gutter tokens, shading colours, the Choose
/// behaviour and the motion. With `YCODE_MERGE_SHOTS=<folder>` the tests
/// also write light and dark snapshots of each state there.
@MainActor
@Suite(.serialized) struct MergeSheetUITests {
    /// A package repository where `feature` and `main` both change two
    /// lines of Greeting.swift and `feature` alone changes a third.
    struct Repo {
        let folder: URL
        let dir: URL
        var file: String { dir.appendingPathComponent("Sources/Merger/Greeting.swift").path }

        init(_ name: String) throws {
            folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("ycode-merge-ui-\(name)-\(UUID().uuidString.prefix(8))")
            dir = folder.appendingPathComponent("Merger")
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/Merger"), withIntermediateDirectories: true)
            try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Merger\", targets: [.target(name: \"Merger\")])\n"
                .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            try git("init", "-q", "-b", "main")
            for (k, v) in [("user.name", "Capture Test"), ("user.email", "test@ycode.invalid"), ("commit.gpgsign", "false")] { try git("config", k, v) }
            try commit(Self.text(greeting: "Hello", name: "world", last: "done"), "Initial")
            try git("switch", "-q", "-c", "feature")
            try commit(Self.text(greeting: "Hello, there", name: "feature", last: "finished"), "Feature")
            try git("switch", "-q", "main")
            try commit(Self.text(greeting: "Hi", name: "main", last: "done"), "Main")
        }

        static func text(greeting: String, name: String, last: String) -> String {
            """
            // A greeting for the merge sheet's tests, long enough to wrap in the pane when the window is narrow enough to need it.
            import Foundation

            public struct Greeting {
                public var text = "\(greeting)"

                public init() {}

                public func render(for person: String) -> String {
                    let name = "\(name)"
                    return text + ", " + person + " from " + name
                }
            }

            // \(last)

            """
        }

        func cleanUp() { try? FileManager.default.removeItem(at: folder) }
        @discardableResult
        func git(_ args: String...) throws -> String { try GitRepository.run("/usr/bin/git", ["-C", dir.path] + args) }
        func commit(_ text: String, _ message: String) throws {
            try text.write(toFile: file, atomically: true, encoding: .utf8)
            try git("add", "-A")
            try git("commit", "-q", "-m", message)
        }

        @MainActor
        func window(dark: Bool = false) async throws -> WorkspaceWindowController {
            _ = NSApplication.shared
            let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)),
                                               loadDestinations: false, startLanguageService: false)
            wc.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            // Pixels read back in the palette's colour space.
            wc.window?.colorSpace = .sRGB
            wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 880), display: false)
            wc.applyDefaultLayout()
            await waitFor("loading the window") { await wc.sourceControl.idle() }
            return wc
        }
    }

    /// Opens the sheet on the conflicted merge.
    func openSheet(_ wc: WorkspaceWindowController) async throws -> MergeSheetController {
        let scm = wc.sourceControl
        scm.merge("feature")
        await waitFor("source control") { await scm.idle() }
        let sheet = try #require(scm.mergeSheet)
        await waitFor("the merge sheet") { await sheet.idle() }
        wc.window?.contentView?.superview?.layoutSubtreeIfNeeded()
        return sheet
    }

    // MARK: Pixels

    struct Snapshot {
        let rep: NSBitmapImageRep
        let height: CGFloat
        let scale: CGFloat
        /// The colour at a point in window coordinates, origin top-left.
        func color(_ x: CGFloat, _ y: CGFloat) -> NSColor? {
            // The rep's raw components (it is in sRGB, `window.colorSpace`);
            // colorAt tags them with a generic space, so no conversion.
            rep.colorAt(x: Int(x * scale), y: Int(y * scale))
        }
    }

    /// The window's pixels, with the merge sheet's own window (§14.1) drawn
    /// over them at its place; the image is tall enough for the part of the
    /// sheet below the window.
    func snapshot(_ wc: WorkspaceWindowController) throws -> Snapshot {
        let win = try #require(wc.window)
        let frame = try #require(win.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        let rep = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / frame.bounds.width
        guard let sw = wc.sourceControl.mergeOverlay?.sheetWindow, let content = sw.contentView else {
            return Snapshot(rep: rep, height: frame.bounds.height, scale: scale)
        }
        content.layoutSubtreeIfNeeded()
        let sheetRep = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: sheetRep)
        // The sheet window's top-left in the parent's top-left space.
        let origin = NSPoint(x: sw.frame.minX - win.frame.minX, y: win.frame.maxY - sw.frame.maxY)
        let height = max(frame.bounds.height, origin.y + content.bounds.height)
        let out = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: Int((height * scale).rounded(.up)),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0)?.retagging(with: .sRGB))
        out.size = NSSize(width: frame.bounds.width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: frame.bounds.width, height: height).fill()
        rep.draw(in: NSRect(x: 0, y: height - frame.bounds.height, width: frame.bounds.width, height: frame.bounds.height))
        sheetRep.draw(in: NSRect(x: origin.x, y: height - origin.y - content.bounds.height, width: content.bounds.width, height: content.bounds.height),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return Snapshot(rep: out, height: height, scale: scale)
    }

    /// A view rectangle in the workspace window's coordinates, origin
    /// top-left (views in the sheet's own window too).
    func windowRect(_ v: NSView, _ r: NSRect, _ wc: WorkspaceWindowController) -> NSRect {
        guard let win = wc.window, let vw = v.window else { return .zero }
        let screen = vw.convertToScreen(v.convert(r, to: nil))
        return NSRect(x: screen.minX - win.frame.minX, y: win.frame.maxY - screen.maxY, width: screen.width, height: screen.height)
    }

    func same(_ c: NSColor?, _ hex: UInt32, tolerance: CGFloat = 0.02) -> Bool {
        guard let c else { return false }
        let e = MergeSheetPalette.components(hex)
        let ok = abs(c.redComponent - CGFloat(e.r)) <= tolerance && abs(c.greenComponent - CGFloat(e.g)) <= tolerance
            && abs(c.blueComponent - CGFloat(e.b)) <= tolerance
        if !ok {
            let got = String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
            print("MergeSheetUITests: got #\(got), want #\(String(format: "%06X", hex))")
        }
        return ok
    }

    /// Writes the window's snapshot when `YCODE_MERGE_SHOTS` names a folder.
    func shot(_ wc: WorkspaceWindowController, _ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["YCODE_MERGE_SHOTS"], let s = try? snapshot(wc),
              let png = s.rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("mac-\(name).png"))
    }

    // MARK: Tests

    /// Row 52: the branch row's menu, then the alert over the veil.
    @Test func branchMenuAndAlert() async throws {
        let r = try Repo("alert")
        defer { r.cleanUp() }
        let wc = try await r.window()
        let scm = wc.sourceControl
        scm.setMode(.repositories)
        wc.navigator.select(1)
        #expect(wc.navigator.selectSourceControlRow(key: "branch:feature"))
        let menu = NSMenu()
        wc.navigator.rebuildRowMenu(menu)
        #expect(menu.items.filter { !$0.isSeparatorItem }.count == 12 && menu.items.filter(\.isSeparatorItem).count == 5)
        let enabled = menu.items.filter { !$0.isSeparatorItem }.map { item in (item.target as? NSMenuItemValidation)?.validateMenuItem(item) ?? item.isEnabled }
        #expect(enabled == [true, true, true, true, true, false, false, false, false, false, false, true])
        let mergeItem = try #require(menu.items.first { $0.title == "Merge \u{201C}feature\u{201D} into \u{201C}main\u{201D}…" })
        #expect(scm.menuState().isEnabled("scmMerge:"))

        // Choosing it: the alert, centred, 420 × 133, Merge the default.
        _ = (mergeItem.target as? NSObject)?.perform(mergeItem.action, with: mergeItem)
        let overlay = try #require(scm.mergeOverlay)
        let alert = try #require(overlay.alert)
        overlay.layoutSubtreeIfNeeded()
        let expected = MergeSheetMetrics.alertFrame(window: (overlay.bounds.width, overlay.bounds.height))
        #expect(alert.frame == NSRect(x: expected.x, y: expected.y, width: 420, height: 133))
        #expect(overlay.bounds.size == wc.window?.contentView?.superview?.bounds.size)
        #expect(alert.titleField.stringValue == "Are you sure you want to merge from \u{201C}feature\u{201D}?")
        #expect(alert.messageField.stringValue == "Changes from \u{201C}feature\u{201D} will be merged into your current branch (\u{201C}main\u{201D}).")
        #expect(alert.cancelButton.frame.size == NSSize(width: 58, height: 20) && alert.mergeButton.frame.size == NSSize(width: 79, height: 20))
        #expect(alert.mergeButton.frame.maxX == 420 - 20.5 && alert.mergeButton.frame.maxY == 133 - 18)
        #expect(alert.mergeButton.frame.minX - alert.cancelButton.frame.maxX == 14.5)
        #expect(alert.iconView.frame == NSRect(x: 28.5, y: 22, width: 55, height: 55))
        // The veil: black at 19.6 % (white becomes #CDCDCD) over 255 ms.
        let veil = try #require(overlay.veil.animation(forKey: "veil") as? CABasicAnimation)
        #expect(veil.duration == 0.255 && overlay.veil.opacity == Float(MergeSheetPalette.light.veilOpacity))
        // Grey during its first frames, the accent once it is up.
        #expect(!alert.mergeButton.isDefaultLook)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(alert.mergeButton.isDefaultLook && alert.mergeButton.colors.fill.isClose(to: NSColor(mergeHex: 0x007AFF)))
        let s = try snapshot(wc)
        // White content behind the veil reads #CDCDCD.
        let white = s.color(windowRect(alert, alert.bounds, wc).minX - 30, s.height - 40)
        #expect(white.map { $0.redComponent < 0.85 } == true)
        shot(wc, "light-alert")

        // Escape cancels; Return merges.
        alert.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                            isARepeat: false, keyCode: 53)))
        #expect(scm.mergeOverlay == nil)
        scm.run(.merge("feature"))
        let again = try #require(scm.mergeOverlay?.alert)
        again.merge(nil)
        await waitFor("source control") { await scm.idle() }
        let sheet = try #require(scm.mergeSheet)
        await waitFor("the merge sheet") { await sheet.idle() }
        #expect(scm.mergeOverlay?.alert == nil)

        // Integrate ▸ Merge…: the alert with a pop-up of the branches.
        sheet.cancelButton.performClick(nil)
        await eventually("the abort") { await scm.idle(); return scm.mergeOverlay == nil }
        wc.scmMerge(nil)
        let chooser = try #require(scm.mergeOverlay?.alert)
        #expect(chooser.chooser?.itemTitles == ["feature"] && chooser.frame.height == 133 + 30)
        chooser.cancel(nil)
        #expect(scm.mergeOverlay == nil)
    }

    /// Rows 53–60: frame, columns, tokens, shading and Choose.
    @Test func sheetFrameTokensShadingAndChoose() async throws {
        for dark in [false, true] {
            let r = try Repo(dark ? "sheet-dark" : "sheet")
            defer { r.cleanUp() }
            let wc = try await r.window(dark: dark)
            let p = MergeSheetPalette.forDark(dark)
            let sheet = try await openSheet(wc)
            let overlay = try #require(wc.sourceControl.mergeOverlay)
            let look = dark ? "dark" : "light"

            // The frame: 24 in, the top at the toolbar's bottom, radius 16
            // (in the sheet's own window, §14.1).
            let f = MergeSheetMetrics.sheetFrame(window: (overlay.bounds.width, overlay.bounds.height), toolbarBottom: Double(overlay.toolbarBottom))
            let sw = try #require(overlay.sheetWindow)
            #expect(sw.sheetFrame(in: try #require(wc.window)) == NSRect(x: 24, y: f.y, width: overlay.bounds.width - 48, height: f.height))
            #expect(sheet.view.frame.size == NSSize(width: f.width, height: f.height))
            #expect(overlay.toolbarBottom > 40 && overlay.toolbarBottom < 60)
            #expect(sheet.view.layer?.cornerRadius == 16)
            // 11.5, rounded to whole pixels at 1x.
            #expect(sheet.sheetView.box.frame.minX == 20 && abs(sheet.sheetView.box.frame.minY - 11.5) <= 0.5)
            #expect(sheet.fileList.frame.width == 198)
            let gutter = sheet.canvas.gutterX
            #expect(sheet.canvas.rightX - gutter - 1 == 46 && sheet.ruler.frame.width == 17)
            #expect(sheet.footer.frame.height == 28 && sheet.jumpBar.frame.height == 37)
            #expect(sheet.mergeButton.frame.width == 84 && sheet.cancelButton.frame.width == 84)
            #expect(sheet.mergeButton.frame.minX - sheet.cancelButton.frame.maxX == 12)
            #expect(abs(sheet.mergeButton.frame.minY - sheet.sheetView.box.frame.maxY - 19) <= 0.5)
            #expect(sheet.mergeButton.frame.maxX == sheet.sheetView.box.frame.maxX)
            #expect(!sheet.mergeButton.isEnabled)

            // Three changes: two conflicts and the clean one.
            let rows = sheet.canvas.rows
            #expect(rows.filter(\.isFirstOfHunk).map(\.kind) == [.conflict, .conflict, .clean])
            #expect(sheet.state.stepperText == "1/3")
            #expect(rows.allSatisfy { $0.left == nil || $0.right == nil || sheet.canvas.rowTops.count == rows.count })
            // Tokens: 38.5 × 14, 3.5 from the gutter's left rule.
            let t0 = try #require(sheet.canvas.tokenRect(forHunk: 0))
            #expect(t0.size == NSSize(width: 38.5, height: 14) && t0.minX == gutter + 3.5)
            #expect(sheet.state.token(forHunk: 0)?.glyph == "?" && sheet.state.token(forHunk: 2)?.glyph == "3")

            // Shading, read back from the window's pixels.
            var s = try snapshot(wc)
            let conflictRow = try #require(rows.firstIndex { $0.kind == .conflict })
            let cleanRow = try #require(rows.firstIndex { $0.kind == .clean })
            let rc = windowRect(sheet.canvas, sheet.canvas.rowRect(conflictRow), wc)
            let rk = windowRect(sheet.canvas, sheet.canvas.rowRect(cleanRow), wc)
            #expect(same(s.color(rc.minX + 4, rc.midY), p.conflictRow), "conflict row \(look)")
            #expect(same(s.color(rc.minX + sheet.canvas.rightX + sheet.canvas.rightWidth - 4, rc.midY), p.conflictRow))
            #expect(same(s.color(rk.minX + 4, rk.midY), p.cleanRow), "clean row \(look)")
            #expect(same(s.color(rk.minX + gutter + 1, rk.midY), p.gutterClean), "clean gutter \(look)")
            // The selected change's rule and its token.
            #expect(same(s.color(rc.minX + 4, rc.minY + 0.25), p.selectedRule), "selected rule \(look)")
            let tw = windowRect(sheet.canvas, t0, wc)
            #expect(same(s.color(tw.minX + 3, tw.midY), p.selectedToken, tolerance: 0.05), "selected token \(look)")
            let t1 = windowRect(sheet.canvas, try #require(sheet.canvas.tokenRect(forHunk: 1)), wc)
            #expect(same(s.color(t1.minX + 3, t1.midY), p.token, tolerance: 0.05), "token \(look)")
            // The changed words.
            if let w = rows[conflictRow].left?.words.first {
                let x = rc.minX + CGFloat(MergeSheetMetrics.codeX) + CGFloat(w.lowerBound) * 8 + 2
                #expect(same(s.color(x, rc.minY + 3), p.conflictWord), "changed word \(look)")
            }
            // The gutter's plain fill.
            let plain = try #require(rows.firstIndex { $0.kind == .same })
            let rp = windowRect(sheet.canvas, sheet.canvas.rowRect(plain), wc)
            #expect(same(s.color(rp.minX + gutter + 20, rp.midY), p.gutter), "gutter \(look)")
            shot(wc, "\(look)-sheet")

            // Choose (§7): the menu's items, then Choose Right rewrites the
            // left pane and the change stays selected.
            // The token's click moves the focus into the panes (§14.3), and
            // the current change's rules follow the focus (§15.2, row 147).
            sheet.canvas.window?.makeFirstResponder(sheet.canvas)
            let menu = sheet.chooseMenu(forHunk: 0)
            #expect(menu.items.map { $0.isSeparatorItem ? "|" : $0.title }
                    == ["Choose Left", "Choose Right", "|", "Choose Left Then Right", "Choose Right Then Left"])
            let right = menu.items[1]
            _ = (right.target as? NSObject)?.perform(right.action, with: right)
            #expect(sheet.state.currentHunk == 0 && sheet.state.stepperText == "1/3")
            #expect(sheet.canvas.rows[conflictRow].left?.text == sheet.canvas.rows[conflictRow].right?.text)
            #expect(sheet.state.token(forHunk: 0)?.glyph == "1" && sheet.state.token(forHunk: 0)?.isDecided == true)
            s = try snapshot(wc)
            #expect(same(s.color(rc.minX + 4, rc.minY + 0.25), p.decidedRule), "bright rules with the panes focused \(look)")
            #expect(same(s.color(rc.minX + 4, rc.midY), p.conflictRow), "shading stays \(look)")
            shot(wc, "\(look)-chose-right")
            // Clicking the second token selects its change.
            sheet.showChooseMenu(forHunk: 1)
            #expect(sheet.state.currentHunk == 1 && sheet.lastChooseMenu?.items.count == 5)
            let left = try #require(sheet.lastChooseMenu?.items.first)
            _ = (left.target as? NSObject)?.perform(left.action, with: left)
            #expect(sheet.mergeButton.isEnabled && sheet.mergeButton.isDefaultLook)
            sheet.nextHunk(nil)
            #expect(sheet.state.stepperText == "3/3")
            shot(wc, "\(look)-all-decided")
            // Flat, then hand editing.
            sheet.setFlat(true)
            sheet.selectHunk(0)
            sheet.beginEditing()
            wc.window?.contentView?.superview?.layoutSubtreeIfNeeded()
            shot(wc, "\(look)-hand-edit")
            sheet.cancelButton.performClick(nil)
            await eventually("the abort") { await wc.sourceControl.idle(); return wc.sourceControl.mergeOverlay == nil }
        }
    }

    /// Row 61: the sheet fades in over 90 ms and slides down 32 points over
    /// about 200 ms; with Reduce Motion it fades only.
    @Test func sheetMotion() async throws {
        let r = try Repo("motion")
        defer { r.cleanUp() }
        let wc = try await r.window()
        let sheet = try await openSheet(wc)
        let layer = try #require(sheet.view.layer)
        let overlay = try #require(wc.sourceControl.mergeOverlay)
        // The animations as the sheet appears (they end after 0.2 s).
        overlay.reduceMotion = false
        overlay.animateSheet(in: true)
        let fade = try #require(layer.animation(forKey: "sheetFade") as? CABasicAnimation)
        let slide = try #require(layer.animation(forKey: "sheetSlide") as? CABasicAnimation)
        #expect(fade.duration == 0.09 && fade.fromValue as? Double == 0 && fade.toValue as? Double == 1)
        #expect(slide.duration == 0.2 && abs(slide.fromValue as? Double ?? 0) == 32 && slide.toValue as? Double == 0)
        var c1: [Float] = [0, 0], c2: [Float] = [0, 0]
        slide.timingFunction?.getControlPoint(at: 1, values: &c1)
        slide.timingFunction?.getControlPoint(at: 2, values: &c2)
        let curve = MergeSheetMotion.slideCurve
        #expect(c1 == [Float(curve.x1), Float(curve.y1)] && c2 == [Float(curve.x2), Float(curve.y2)])
        // The slide starts above the resting place: the sheet window's
        // content is flipped (y grows downward), so the start is −32.
        #expect(sheet.view.superview?.isFlipped == true && slide.fromValue as? Double == -32)

        // Closing reverses it.
        overlay.animateSheet(in: false)
        let out = try #require(layer.animation(forKey: "sheetSlide") as? CABasicAnimation)
        #expect(out.toValue as? Double == slide.fromValue as? Double && (layer.animation(forKey: "sheetFade") as? CABasicAnimation)?.toValue as? Double == 0)
        overlay.animateSheet(in: true)
        // Reduce Motion: no slide.
        overlay.reduceMotion = true
        overlay.animateSheet(in: true)
        #expect(layer.animation(forKey: "sheetSlide") == nil && layer.animation(forKey: "sheetFade") != nil)
        sheet.cancelButton.performClick(nil)
        await eventually("the abort") { await wc.sourceControl.idle(); return wc.sourceControl.mergeOverlay == nil }
    }
}
