import AppKit
import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 8, group A, on the macOS IDE (`specs/ide/fidelity-council.md`
/// rows 197–203): the navigator's selection and the current-line band
/// across an appearance change, the narrow toolbar's own issue capsule,
/// the scheme capsule's icons, file icons in the jump bar and the merge
/// sheet, the reopen subtitle, the restored scroll offset and the plain
/// folder's glyph. Windows stay off every display. With
/// `YCODE_B8_SHOTS=<dir>` the tests save pictures of their states.
@MainActor
@Suite(.serialized) struct CouncilRound8ChromeTests {
    let r5 = CouncilRound5ChromeTests()

    static func shot(_ w: NSWindow?, _ name: String) {
        guard let w, let dir = ProcessInfo.processInfo.environment["YCODE_B8_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        UISpacingProbeTests.shot(w, URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    /// The colour at `p` (in `v`'s coordinates) of a picture of the
    /// window's content, as 0xRRGGBB.
    static func pixel(_ p: NSPoint, in v: NSView) -> UInt32 {
        guard let cv = v.window?.contentView, let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds)?.retagging(with: .sRGB) else { return 0xFFFF_FFFF }
        v.window?.displayIfNeeded()
        cv.cacheDisplay(in: cv.bounds, to: rep)
        let k = CGFloat(rep.pixelsWide) / cv.bounds.width
        let q = v.convert(p, to: cv)
        let y = cv.isFlipped ? q.y : cv.bounds.height - q.y
        guard let c = rep.colorAt(x: Int(q.x * k), y: Int(y * k)), c.numberOfComponents >= 3 else { return 0xFFFF_FFFF }
        return UInt32((c.redComponent * 255).rounded()) << 16 | UInt32((c.greenComponent * 255).rounded()) << 8 | UInt32((c.blueComponent * 255).rounded())
    }

    // MARK: Row 197: selection and band across an appearance change

    /// I04: the open file's row selected in the project navigator and the
    /// insertion point on a line; Settings ▸ General ▸ Appearance goes from
    /// Dark to Light and back. The row stays selected and the band stays on
    /// the caret's line (#353535 in dark, #EEEEEE on white in light).
    @Test func selectionAndBandSurviveAnAppearanceChange() throws {
        let prefs = IsolatedPreferences("r8-appearance")
        defer { prefs.restore() }
        let (wc, dir) = try r5.longWindow("r8-appearance")
        defer { wc.window?.orderOut(nil) }
        Preferences.shared.appearance = .dark
        let long = dir.appendingPathComponent("GlassScroll/Long.swift").path
        wc.navigator.selectOpenFileRow(long)
        let tv = wc.editor.textView
        tv.setSelectedRange(NSRange(location: 200, length: 0))
        r5.spin(0.2)
        let row = wc.navigator.outlineView.selectedRow
        let line = try #require(tv.caretLine)
        #expect(row >= 0 && (wc.navigator.outlineView.item(atRow: row) as? OutlineItem)?.path == long)
        let rect = try #require(tv.lineRect(line))
        let inBand = NSPoint(x: rect.minX + 300, y: rect.midY), below = NSPoint(x: rect.minX + 300, y: rect.midY + 40)
        func check(_ mode: Preferences.Appearance, band: UInt32, background: UInt32) {
            Preferences.shared.appearance = mode
            r5.spin(0.3)
            #expect(wc.navigator.outlineView.selectedRow == row, "\(mode): selected row \(wc.navigator.outlineView.selectedRow)")
            #expect(tv.caretLine == line)
            let b = Self.pixel(inBand, in: tv), bg = Self.pixel(below, in: tv)
            #expect(b == band && bg == background, "\(mode): band \(String(b, radix: 16)) on \(String(bg, radix: 16))")
            Self.shot(wc.window, "mac-r8-197-\(mode.rawValue.lowercased()).png")
        }
        check(.dark, band: 0x353535, background: 0x262626)
        check(.light, band: 0xEEEEEE, background: 0xFFFFFF)
        check(.dark, band: 0x353535, background: 0x262626)
        // The rebuild opened nothing and kept the editor's file.
        #expect(wc.editor.fileURL?.path == long)
    }

    // MARK: Row 198: the narrow toolbar's own issue capsule

    /// The glass shapes in the toolbar, left to right (macOS 26 groups
    /// adjacent bordered items into one shape; each shape is a platter).
    static func glassShapes(_ w: NSWindow, _ r5: CouncilRound5ChromeTests) -> [(rect: NSRect, views: [NSView])] {
        guard let toolbarView = w.standardWindowButton(.closeButton)?.superview else { return [] }
        var out: [(NSRect, [NSView])] = []
        func walk(_ v: NSView) {
            if String(describing: type(of: v)).contains("PlatterView") {
                var views: [NSView] = []
                func collect(_ n: NSView) { views.append(n); n.subviews.forEach(collect) }
                collect(v)
                out.append((r5.frameInWindow(v), views))
                return
            }
            v.subviews.forEach(walk)
        }
        walk(toolbarView)
        return out.sorted { $0.0.minX < $1.0.minX }
    }

    /// N02: at 1100 points with an error and a warning, the issues collapse
    /// to the error's octagon in a round capsule of its own (about 39
    /// wide) between the scheme capsule and Add Editor's, not one long
    /// capsule with them.
    @Test func narrowIssuesHaveTheirOwnRoundCapsule() throws {
        let (wc, _) = try r5.longWindow("r8-narrow-issues")
        defer { wc.window?.orderOut(nil) }
        let w = try #require(wc.window)
        wc.issueCapsule.errors = 1
        wc.issueCapsule.warnings = 1
        w.appearance = NSAppearance(named: .aqua)
        w.setFrame(NSRect(x: -6000, y: -6000, width: 1100, height: 880), display: true)
        r5.spin(0.3)
        wc.fitToolbar()
        w.contentView?.superview?.layoutSubtreeIfNeeded()
        r5.spin(0.2)
        #expect(wc.issueCapsule.symbolsOnly && wc.issueCapsule.shownKinds == [.error])
        #expect(abs(wc.issueCapsule.capsuleWidth - 39) < 0.01)
        let shapes = Self.glassShapes(w, r5)
        func shape(holding v: NSView) -> NSRect? { shapes.first { $0.views.contains { $0 === v } }?.rect }
        let schemeView = try #require(w.toolbar?.items.first { $0.itemIdentifier.rawValue == "scheme" }?.view)
        let issues = try #require(shape(holding: wc.issueCapsule)), scheme = try #require(shape(holding: schemeView))
        // Its own shape: nothing else in it, round (39 × 36).
        let holders = shapes.first { $0.views.contains { $0 === wc.issueCapsule } }?.views.filter { $0 === schemeView } ?? []
        #expect(holders.isEmpty && abs(issues.width - 39) <= 1.5 && abs(issues.height - 36) <= 0.5, "issues \(issues)")
        // After the scheme capsule (7.5–8 apart) and before Add Editor's.
        #expect(issues.minX - scheme.maxX >= 7 && issues.minX - scheme.maxX <= 9, "gap \(issues.minX - scheme.maxX)")
        let addEditor = try #require(shapes.first { $0.rect.minX > issues.maxX })
        #expect(addEditor.rect.minX - issues.maxX >= 7, "gap to Add Editor \(addEditor.rect.minX - issues.maxX)")
        // The error's octagon, centred; the warning's triangle hidden.
        let err = wc.issueCapsule.buttons[IssueSummary.Kind.error.rawValue]
        #expect(!err.isHidden && wc.issueCapsule.buttons[IssueSummary.Kind.warning.rawValue].isHidden)
        #expect(abs(err.frame.minX - CGFloat(IssueSummary.Capsule.collapsedSymbolX())) < 0.01)
        #expect(IssueSummary.Kind.error.collapsedSymbol == "xmark.octagon.fill" && err.toolTip == "1 Errors, 1 Issues")
        Self.shot(w, "mac-r8-198-narrow-issues-light.png")
        w.appearance = NSAppearance(named: .darkAqua)
        Self.shot(w, "mac-r8-198-narrow-issues-dark.png")
        print("R8A row 198: scheme \(scheme), issues \(issues), add editor \(addEditor.rect)")
        // Wide again: both kinds with their counts.
        w.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: true)
        r5.spin(0.3)
        wc.fitToolbar()
        #expect(!wc.issueCapsule.symbolsOnly && wc.issueCapsule.shownKinds == [.error, .warning])
    }

    // MARK: Row 203: the plain group's folder glyph

    /// The Plain group's grey folder in dark: #B0B0B4 (Ycode drew about
    /// #6A6A6C, the sidebar's vibrancy darkening #999999); light keeps
    /// round 2's #7B7B80. The icon is drawn without vibrancy, so the
    /// colour on screen is the colour given.
    @Test func plainGroupFolderGlyphColour() throws {
        let (wc, _) = try r5.longWindow("r8-plain-folder")
        defer { wc.window?.orderOut(nil) }
        wc.navigator.setProjectTree(CouncilRound6ChromeTests.councilTree())
        let o = wc.navigator.outlineView
        o.expandItem(nil, expandChildren: true)
        let row = try #require((0..<o.numberOfRows).first { (o.item(atRow: $0) as? OutlineItem)?.title == "Plain" })
        o.scrollRowToVisible(row)
        let cell = try #require(o.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
        let icon = try #require(cell.imageView)
        #expect(icon is NavigatorFlatIconView && !icon.allowsVibrancy)
        let tint = try #require(icon.contentTintColor)
        func hex(_ c: NSColor, _ name: NSAppearance.Name) -> UInt32 {
            var v: UInt32 = 0
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let s = c.usingColorSpace(.sRGB)!
                v = UInt32((s.redComponent * 255).rounded()) << 16 | UInt32((s.greenComponent * 255).rounded()) << 8 | UInt32((s.blueComponent * 255).rounded())
            }
            return v
        }
        // Round 9 (row 213) re-measured it: #B6B7BC in dark.
        #expect(hex(tint, .darkAqua) == 0xB6B7BC && hex(tint, .aqua) == 0x7B7B80)
        // Since round 9 every file glyph is drawn without vibrancy too (rows 208–213).
        let other = try #require((0..<o.numberOfRows).first { (o.item(atRow: $0) as? OutlineItem)?.title == "Models" })
        let otherIcon = (o.view(atColumn: 0, row: other, makeIfNecessary: true) as? NSTableCellView)?.imageView
        #expect(otherIcon.map { $0 is NavigatorFlatIconView } == true)
        wc.window?.appearance = NSAppearance(named: .darkAqua)
        Self.shot(wc.window, "mac-r8-203-plain-folder-dark.png")
    }

    // MARK: Row 200: the navigator's file icon in the jump bar and the merge sheet

    /// A Swift file's jump-bar component and the merge sheet's file list
    /// show the project navigator's glyph (since round 9 the single-colour
    /// line-art logo in the type's tint, `CouncilRound9GlyphUITests`), not a
    /// generic code glyph; a file without one keeps its symbol.
    @Test func jumpBarAndMergeSheetShowTheNavigatorsFileIcon() throws {
        let (wc, _) = try r5.longWindow("r8-jump-logo")
        defer { wc.window?.orderOut(nil) }
        let bar = wc.editor.jumpBar
        let file = try #require(bar.pathState.parts.last?.icon)
        #expect(file.isGlyph && file.image?.accessibilityDescription == "swift")
        // Drawn at the file's 11.5 of ink, centred in its 12.5 slot.
        #expect(abs(file.inkWidth - 11.5) < 0.01 && abs(file.slotWidth - 12.5) < 0.01)
        Self.shot(wc.window, "mac-r8-200-jump-bar-swift.png")
        // The merge sheet's icon: the glyph, all in the colour given.
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: 16, height: 16)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        MergeDraw.fileIcon("Merger.swift", in: NSRect(x: 0, y: 0, width: 16, height: 16), color: .systemPink, pointSize: 10,
                           box: FileGlyphs.navigatorBox(.logo("swift")))
        NSGraphicsContext.restoreGraphicsState()
        var pink = 0, other = 0
        for y in 0..<32 {
            for x in 0..<32 {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.9 else { continue }
                let (r, g, b) = (c.redComponent, c.greenComponent, c.blueComponent)
                if r > 0.85, g < 0.4, b > 0.25 { pink += 1 } else { other += 1 }
            }
        }
        #expect(pink > 150 && other == 0, "pink \(pink), other \(other)")
    }

    // MARK: Row 202: the restored pane's scroll offset

    /// R01: the left pane reopens at its saved first line, and stays there
    /// through what follows the restore: a pane put back at its top in the
    /// first seconds (the window's first layout on screen, a recolouring)
    /// goes to its saved line again; after that the user's scrolling is
    /// left alone.
    @Test func reopenedPaneKeepsItsSavedFirstLine() throws {
        let dir = try FidelityCouncilTests().project("r8-reopen-scroll")
        let state = dir.appendingPathComponent("ycode-ui-state.json")
        let long = dir.appendingPathComponent("GlassScroll/Long.swift").path
        let model01 = dir.appendingPathComponent("GlassScroll/Models/Model01.swift").path
        var saved = WorkspaceUserState()
        saved.inspector = WorkspaceInspectorState(isShown: true, tab: 0)
        saved.editorLayout = WorkspaceEditorLayout(panes: [.init(path: long, topLine: 60, selectionStart: 0, selectionLength: 0), .init(path: model01)],
                                                   sideBySide: true, fractions: [0.5, 0.5], focused: 1)
        saved.save(to: state)
        _ = NSApplication.shared
        let model = try WorkspaceModel(url: dir.appendingPathComponent("GlassScroll.xcodeproj"))
        // As the app makes it: the window, then the default layout.
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: model), loadDestinations: false, startLanguageService: false,
                                           openFirstFile: false, userStateURL: state)
        defer { wc.window?.orderOut(nil); wc.close() }
        wc.window?.isExcludedFromWindowsMenu = true
        wc.window?.appearance = NSAppearance(named: .darkAqua)
        wc.window?.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        wc.applyDefaultLayout()
        wc.window?.orderBack(nil)
        r5.spin(0.3)
        let left = wc.editorArea.tab.editors[0]
        #expect(left.fileURL?.path == long && left.firstVisibleLine == 60, "first line \(left.firstVisibleLine)")
        #expect(wc.editorArea.restoreBox.isGuarding)
        // Something puts the pane back at its top: it returns to line 60.
        let clip = left.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: -left.scrollView.contentInsets.top))
        left.scrollView.reflectScrolledClipView(clip)
        r5.spin(0.2)
        #expect(left.firstVisibleLine == 60, "after a reset: \(left.firstVisibleLine)")
        Self.shot(wc.window, "mac-r8-202-reopened-left-pane.png")
        // A scroll elsewhere stays; once the guard ends, the top stays too.
        left.scroll(toTopLine: 20)
        r5.spin(0.1)
        #expect(left.firstVisibleLine == 20)
        wc.editorArea.restoreBox.stopGuard()
        left.scroll(toTopLine: 1)
        r5.spin(0.1)
        #expect(left.firstVisibleLine == 1)
    }

    // MARK: Row 199: the scheme capsule's icons

    /// The scheme shows its target's app icon (the asset catalog's
    /// picture) or Ycode's plain app tile, never an empty dashed square;
    /// the destination for this computer follows its form (a laptop glyph
    /// tinted blue on a laptop, a desktop otherwise).
    @Test func schemeCapsuleShowsTheAppIconAndTheHostsForm() throws {
        let (wc, dir) = try r5.longWindow("r8-scheme-icons")
        defer { wc.window?.orderOut(nil) }
        // No asset catalog: Ycode's tile.
        SchemeCapsuleIcons.forget()
        #expect(SchemeCapsuleIcons.appIconURL(scheme: "GlassScroll", model: wc.session.model) == nil)
        let tile = SchemeCapsuleImages.schemeImage(appIcon: nil)
        #expect(!tile.isTemplate && tile.size == NSSize(width: 16, height: 16) && tile.accessibilityDescription == "App")
        // An AppIcon set with a 1024 picture: that picture.
        let set = dir.appendingPathComponent("GlassScroll/Assets.xcassets/AppIcon.appiconset")
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 0.1, green: 0.7, blue: 0.3, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        NSGraphicsContext.restoreGraphicsState()
        try #require(rep.representation(using: .png, properties: [:])).write(to: set.appendingPathComponent("Icon.png"))
        try #"{"images":[{"filename":"Icon.png","idiom":"universal","platform":"ios","size":"1024x1024"},{"appearances":[{"appearance":"luminosity","value":"dark"}],"idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}"#
            .write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
        SchemeCapsuleIcons.forget()
        let icon = SchemeCapsuleIcons.appIconURL(scheme: "GlassScroll", model: wc.session.model)
        #expect(icon?.lastPathComponent == "Icon.png")
        wc.setDestinationGroups(wc.session.model.destinationGroups)
        let schemeItem = try #require(wc.schemePopUp.itemArray.first)
        #expect(schemeItem.image?.accessibilityDescription == "App Icon" && schemeItem.image?.isTemplate == false)
        // The host: a laptop by its model name or a battery, else a desktop.
        #expect(SchemeCapsuleIcons.hostForm(modelIdentifier: "MacBookPro18,3", hasInternalBattery: false) == .laptop)
        #expect(SchemeCapsuleIcons.hostForm(modelIdentifier: "Mac14,13", hasInternalBattery: false) == .desktop)
        #expect(SchemeCapsuleIcons.hostForm(modelIdentifier: "Mac15,10", hasInternalBattery: true) == .laptop)
        #expect(SchemeCapsuleIcons.HostForm.laptop.symbol == "laptopcomputer" && SchemeCapsuleIcons.hostGlyphTint(.laptop, dark: true) == 0x0091FF)
        #expect(SchemeCapsuleIcons.hostGlyphTint(.desktop, dark: true) == nil)
        let mac = Destination(name: "My Mac", specifier: "platform=macOS", platform: "macOS", kind: .mac)
        #expect(WorkspaceWindowController.symbol(for: mac) == SchemeCapsuleIcons.currentHostForm.symbol)
        let laptop = try #require(SchemeCapsuleImages.hostImage(.laptop))
        #expect(!laptop.isTemplate)
        wc.window?.appearance = NSAppearance(named: .darkAqua)
        // Drawn in colour in the toolbar: the icon's green and the laptop's blue.
        func colours(_ v: NSView) -> (green: Int, blue: Int) {
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)?.retagging(with: .sRGB) else { return (0, 0) }
            v.cacheDisplay(in: v.bounds, to: rep)
            if let dir = ProcessInfo.processInfo.environment["YCODE_B8_SHOTS"] {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("mac-r8-199-\(v === wc.schemePopUp ? "scheme" : "destination")-popup.png"))
            }
            var g = 0, b = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
                    if c.greenComponent > 0.55, c.redComponent < 0.3, c.blueComponent < 0.45 { g += 1 }
                    if c.blueComponent > 0.8, c.redComponent < 0.3, c.greenComponent > 0.4, c.greenComponent < 0.7 { b += 1 }
                }
            }
            return (g, b)
        }
        wc.schemePopUp.selectItem(at: 0)
        wc.schemePopUp.layoutSubtreeIfNeeded()
        // The picture itself: the icon's green, clipped round.
        let bmp = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bmp.size = NSSize(width: 16, height: 16)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bmp)
        schemeItem.image?.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        NSGraphicsContext.restoreGraphicsState()
        let mid = bmp.colorAt(x: 16, y: 16)
        #expect((mid?.greenComponent ?? 0) > 0.5 && (mid?.redComponent ?? 1) < 0.3)
        #expect(colours(wc.schemePopUp).green > 20, "scheme \(colours(wc.schemePopUp))")
        if SchemeCapsuleIcons.currentHostForm == .laptop, let i = wc.destinationPopUp.itemArray.firstIndex(where: { $0.title == "My Mac" }) {
            wc.destinationPopUp.selectItem(at: i)
            wc.destinationPopUp.layoutSubtreeIfNeeded()
            #expect(colours(wc.destinationPopUp).blue > 10, "destination \(colours(wc.destinationPopUp))")
        }
        wc.fitToolbar()
        wc.window?.contentView?.superview?.layoutSubtreeIfNeeded()
        r5.spin(0.3)
        for b in [wc.schemePopUp, wc.destinationPopUp] {
            let g = (b as? SchemePopUpButton)?.glyph ?? (b as? DestinationPopUpButton)?.glyph
            print("R8A 199 popup \(b.frame) title \(b.titleOfSelectedItem ?? "") position \(b.imagePosition.rawValue) glyph \(g.map { "\($0.frame) hidden \($0.isHidden) image \($0.image != nil)" } ?? "none") window \(b.window != nil)")
        }
        Self.shot(wc.window, "mac-r8-199-scheme-capsule-dark.png")
        wc.setSchemeGlyphsOnly(true)
        wc.window?.contentView?.superview?.layoutSubtreeIfNeeded()
        Self.shot(wc.window, "mac-r8-199-scheme-capsule-glyphs-dark.png")
        wc.setSchemeGlyphsOnly(false)
        print("R8A row 199: host form \(SchemeCapsuleIcons.currentHostForm)")
    }
}
