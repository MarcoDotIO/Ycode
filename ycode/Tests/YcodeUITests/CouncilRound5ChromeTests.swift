import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 5, group D, chrome and motion (`specs/ide/fidelity-council.md`
/// rows 134, 137, 138, 140, 141; `editor-area.md` G.4, G.7–G.9).
@MainActor
@Suite(.serialized) struct CouncilRound5ChromeTests {
    func spin(_ seconds: Double, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }

    /// A council window at the capture's size with Long.swift open, off every
    /// display: callers turn on `MergeSheetR5UITests.Offscreen` first, or
    /// AppKit moves the window onto a display when it is ordered in.
    func longWindow(_ tag: String) throws -> (WorkspaceWindowController, URL) {
        let fc = FidelityCouncilTests()
        let dir = try fc.project("r5c-\(tag)")
        let wc = try fc.window(dir)
        wc.window?.isExcludedFromWindowsMenu = true
        wc.window?.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: false)
        wc.window?.orderBack(nil)
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.window?.displayIfNeeded()
        return (wc, dir)
    }

    func frameInWindow(_ v: NSView) -> NSRect {
        let r = v.convert(v.bounds, to: nil)
        let h = v.window?.frame.height ?? 0
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    // MARK: Row 138: the toolbar's issue capsule

    @Test func issueCapsuleGeometryFollowsTheSharedSummary() {
        let cap = IssueCapsuleView()
        #expect(cap.isHidden && cap.capsuleWidth == 0)
        cap.warnings = 1
        cap.layoutSubtreeIfNeeded()
        cap.frame = NSRect(x: 0, y: 0, width: cap.intrinsicContentSize.width, height: 36)
        cap.layoutSubtreeIfNeeded()
        // G.8, H.5: one warning, "1": 61 wide; the symbol 16.5 inside; the
        // count's text 4 after it (its ink 5, round 6).
        #expect(!cap.isHidden && abs(cap.capsuleWidth - 61) <= 1, "\(cap.capsuleWidth) count \(IssueCapsuleView.countWidth("1"))")
        let warn = cap.buttons[IssueSummary.Kind.warning.rawValue]
        #expect(abs(warn.frame.minX - 16.5) < 0.01 && warn.countFrame.minX == 17.5 + 4 - IssuePartButton.labelInset)
        #expect(warn.title == "1" && warn.accessibilityTitle() == "Issues")
        // Errors first, then warnings: 111 wide for one of each (H.5).
        cap.errors = 1
        cap.layoutSubtreeIfNeeded()
        cap.frame.size.width = cap.intrinsicContentSize.width
        cap.layoutSubtreeIfNeeded()
        let err = cap.buttons[IssueSummary.Kind.error.rawValue]
        #expect(cap.parts.map(\.0) == ["xmark.circle.fill", "exclamationmark.triangle.fill"])
        #expect(err.frame.minX < warn.frame.minX && abs(cap.capsuleWidth - 111) <= 1, "\(cap.capsuleWidth)")
        // A narrow window: the most severe kind's glyph alone in a round
        // capsule 39 wide (council round 8, row 198).
        cap.symbolsOnly = true
        cap.layoutSubtreeIfNeeded()
        #expect(warn.isHidden && err.countFrame == .zero && abs(cap.capsuleWidth - 39) < 0.01, "\(cap.capsuleWidth)")
        cap.errors = 0
        cap.warnings = 0
        #expect(cap.isHidden)
    }

    /// The symbols: a white mark on the kind's fill (the triangle #FFE015),
    /// the triangle's ink about 17.5 × 15.5.
    @Test func issueSymbolsAreWhiteMarksOnTheirFill() throws {
        for kind in [IssueSummary.Kind.warning, .error] {
            let image = IssueCapsuleView.symbolImage(kind)
            let scale = 4
            let size = image.size
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            var minX = Int.max, maxX = 0, minY = Int.max, maxY = 0, white = 0, filled = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { continue }
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    if c.redComponent > 0.95 && c.greenComponent > 0.95 && c.blueComponent > 0.95 { white += 1 } else { filled += 1 }
                }
            }
            let w = CGFloat(maxX - minX + 1) / CGFloat(scale), h = CGFloat(maxY - minY + 1) / CGFloat(scale)
            print("R5CHROME symbol \(kind): ink \(w) × \(h), white \(white), fill \(filled)")
            #expect(white > 20 && filled > white * 3, "\(kind): a white mark on the fill")
            if kind == .warning { #expect(abs(w - 17.5) <= 1.5 && abs(h - 15.5) <= 1.5, "\(w) × \(h)") }
        }
    }

    /// In the window: the capsule sits after the scheme capsule (its own
    /// glass shape, a fixed space between them), shows when there are
    /// issues and goes to symbols only with the scheme's glyphs.
    @Test func issueCapsuleSitsAfterTheSchemeCapsule() throws {
        MergeSheetR5UITests.Offscreen.on()
        defer { MergeSheetR5UITests.Offscreen.off() }
        let (wc, _) = try longWindow("issues")
        defer { wc.window?.orderOut(nil) }
        let ids = wc.toolbarDefaultItemIdentifiers(NSToolbar()).map(\.rawValue)
        let scheme = try #require(ids.firstIndex(of: "scheme"))
        #expect(ids[scheme + 1] == NSToolbarItem.Identifier.space.rawValue && ids[scheme + 2] == "issues")
        // G.4: a fixed space before the flexible one, so the scheme and issue
        // capsules do not touch Add Editor's group when the flexible space closes.
        #expect(ids[scheme + 3] == NSToolbarItem.Identifier.space.rawValue && ids[scheme + 4] == NSToolbarItem.Identifier.flexibleSpace.rawValue)
        wc.issueCapsule.warnings = 1
        spin(0.2)
        wc.fitToolbar()
        wc.window?.contentView?.superview?.layoutSubtreeIfNeeded()
        let item = try #require(wc.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "issues" })
        #expect(!item.isHidden && !wc.overflowedToolbarItems.contains("issues"))
        let schemeView = try #require(wc.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "scheme" }?.view)
        let s = frameInWindow(schemeView), i = frameInWindow(wc.issueCapsule)
        print("R5CHROME scheme \(s) issues \(i)")
        // The system's fixed space: 8 (G.8: 7.5).
        #expect(abs(i.minX - s.maxX - 7.5) <= 1, "gap \(i.minX - s.maxX)")
        #expect(abs(i.width - 61) <= 1)
        // At 1100 (G.4): the scheme's glyphs and the issue symbols only.
        wc.window?.setFrame(NSRect(x: -6000, y: -6000, width: 1100, height: 880), display: true)
        wc.fitToolbar()
        #expect(wc.schemeShowsGlyphsOnly == wc.issueCapsule.symbolsOnly)
        wc.window?.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: true)
        wc.fitToolbar()
        #expect(!wc.issueCapsule.symbolsOnly)
    }

    // MARK: Row 141: the activity subtitle

    @Test func activitySubtitleWhileTheLanguageServerStarts() throws {
        MergeSheetR5UITests.Offscreen.on()
        defer { MergeSheetR5UITests.Offscreen.off() }
        let (wc, _) = try longWindow("activity")
        defer { wc.window?.orderOut(nil) }
        #expect(wc.activityView.status == "")
        wc.session.isPreparingEditorServices = true
        #expect(wc.activityView.status == WorkspaceChrome.preparingEditorServicesText)
        #expect(!wc.activityView.status.lowercased().contains("xcode"))
        wc.session.isPreparingEditorServices = false
        #expect(wc.activityView.status == "")
    }

    // MARK: Row 140: the split's latency

    /// The time from Editor Pane On Right's action to the split drawn
    /// (`editor-area.md` G.7: the reference drew it 858 ms after the press).
    @Test func splitIsDrawnPromptly() throws {
        MergeSheetR5UITests.Offscreen.on()
        defer { MergeSheetR5UITests.Offscreen.off() }
        let (wc, _) = try longWindow("split")
        defer { wc.window?.orderOut(nil) }
        let t0 = CACurrentMediaTime()
        wc.splitEditor(nil)
        let t1 = CACurrentMediaTime()
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.window?.displayIfNeeded()
        let t2 = CACurrentMediaTime()
        print("R5CHROME split: action \(Int((t1 - t0) * 1000)) ms, drawn \(Int((t2 - t0) * 1000)) ms")
        #expect(wc.editorArea.allEditors.count == 2)
        // At most the reference's time: about 200 ms on a quiet Mac, but a shared CI
        // runner has taken 539 ms, so a tighter bound only measures the runner.
        #expect(t2 - t0 < 0.858, "\(t2 - t0)")
    }

    /// Where the split's time goes (`R5_PROFILE=1`).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["R5_PROFILE"] != nil))
    func profileSplit() throws {
        MergeSheetR5UITests.Offscreen.on()
        defer { MergeSheetR5UITests.Offscreen.off() }
        let (wc, _) = try longWindow("split-profile")
        defer { wc.window?.orderOut(nil) }
        for round in 0..<3 {
            let current = wc.editor.history.current
            let t0 = CACurrentMediaTime()
            let e = wc.editorArea.split(sideBySide: true)
            let t1 = CACurrentMediaTime()
            if let current { wc.open(path: current, line: nil, in: e) }
            let t2 = CACurrentMediaTime()
            wc.window?.makeFirstResponder(e.textView)
            let t3 = CACurrentMediaTime()
            wc.window?.contentView?.layoutSubtreeIfNeeded()
            let t4 = CACurrentMediaTime()
            wc.window?.displayIfNeeded()
            let t5 = CACurrentMediaTime()
            func ms(_ a: Double, _ b: Double) -> Int { Int((b - a) * 1000) }
            print("R5PROFILE split \(round): area.split \(ms(t0, t1)) open \(ms(t1, t2)) focus \(ms(t2, t3)) layout \(ms(t3, t4)) display \(ms(t4, t5))")
            wc.editorArea.closePane(e)
            spin(0.2)
        }
    }

    // MARK: Row 134: narrowing

    /// The resize call returns without waiting for the toolbar's fit; the
    /// fit follows on the next turn of the run loop.
    @Test func narrowingDoesNotBlockOnTheToolbarFit() throws {
        MergeSheetR5UITests.Offscreen.on()
        defer { MergeSheetR5UITests.Offscreen.off() }
        let (wc, _) = try longWindow("narrow")
        defer { wc.window?.orderOut(nil) }
        let w = try #require(wc.window)
        wc.fitToolbar()
        let runs = wc.toolbarControls.fitRuns
        let t0 = CACurrentMediaTime()
        w.setFrame(NSRect(x: -6000, y: -6000, width: 1100, height: 880), display: true)
        let t1 = CACurrentMediaTime()
        print("R5CHROME resize call \(Int((t1 - t0) * 1000)) ms, fits during it \(wc.toolbarControls.fitRuns - runs)")
        spin(0.3)
        #expect(wc.toolbarControls.fitRuns > runs && wc.toolbarFit.schemeGlyphsOnly)
    }

    // MARK: Shots (YCODE_B5_CHROME_DIR)

    /// The issue capsule at 1400 and 1100 points and the activity subtitle,
    /// in both appearances, drawn off every display by the window server.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YCODE_B5_CHROME_DIR"] != nil))
    func chromeShots() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YCODE_B5_CHROME_DIR"]!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        CrossPlatformParityShotTests.KeyLook.on()
        defer { CrossPlatformParityShotTests.KeyLook.off() }
        for appearance in ["light", "dark"] {
            MergeSheetR5UITests.Offscreen.on()
            defer { MergeSheetR5UITests.Offscreen.off() }
            let (wc, _) = try longWindow("shots-\(appearance)")
            defer { wc.window?.close() }
            let w = try #require(wc.window)
            w.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            func shot(_ name: String) {
                spin(0.5)
                w.contentView?.superview?.layoutSubtreeIfNeeded()
                w.displayIfNeeded()
                CrossPlatformParityShotTests.write(w, name: "mac-\(appearance)-\(name)", to: out)
            }
            wc.issueCapsule.errors = 1
            wc.issueCapsule.warnings = 1
            wc.fitToolbar()
            shot("issues")
            // The narrow window with one warning, as the reference's capture (G.4).
            wc.issueCapsule.errors = 0
            w.setFrame(NSRect(x: -6000, y: -6000, width: 1100, height: 880), display: true)
            wc.fitToolbar()
            shot("issues-narrow")
            w.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: true)
            wc.issueCapsule.errors = 0
            wc.issueCapsule.warnings = 0
            wc.session.isPreparingEditorServices = true
            wc.fitToolbar()
            shot("activity")
            wc.session.isPreparingEditorServices = false
        }
    }
}
