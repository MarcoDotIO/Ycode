import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Council round 3, Settings (`specs/ide/settings.md` R3.1–R3.3, checklist
/// rows 62–64): the window's size, buttons, capsule and title; the
/// sidebar's width, rows, symbols and labels; the General pane's cards,
/// rows, separators, help text and controls. Positions are in window
/// points from the top-left corner. With `YCODE_SETTINGS_SHOTS` set to a
/// folder, `shots` writes `mac-<appearance>-<pane>.png` for General,
/// Appearance and Accounts (drawn with `cacheDisplay`; nothing goes on
/// screen).
@MainActor
@Suite(.serialized) struct SettingsWindowR3Tests {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["YCODE_SETTINGS_SHOTS"]

    /// A view's frame in window coordinates from the top-left.
    func rect(_ v: NSView, in window: NSWindow) -> NSRect {
        let r = v.convert(v.bounds, to: nil)
        return NSRect(x: r.minX, y: window.frame.height - r.maxY, width: r.width, height: r.height)
    }

    /// One device pixel: layout rounds half points on a 1x backing store.
    func px(_ w: NSWindow) -> CGFloat { 1 / max(1, w.backingScaleFactor) + 0.01 }

    func near(_ a: NSRect, _ b: NSRect, _ tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    func makeWindow(_ t: TestDefaults) throws -> (SettingsWindowController, NSWindow) {
        _ = NSApplication.shared
        let wc = SettingsWindowController(prefs: Preferences(defaults: t.defaults), components: [])
        let w = try #require(wc.window)
        w.appearance = NSAppearance(named: .aqua)
        w.contentView?.superview?.layoutSubtreeIfNeeded()
        return (wc, w)
    }

    @Test func windowSizeButtonsCapsuleAndTitle() throws {
        let t = TestDefaults("r3-window")
        defer { t.remove() }
        let (wc, w) = try makeWindow(t)
        #expect(w.frame.size == SettingsMetrics.windowSize)
        #expect(w.contentView?.frame.size == SettingsMetrics.windowSize)
        // Window buttons: 14-point circles at x 19, 42, 65 on y 26, all enabled.
        for (k, x) in [(NSWindow.ButtonType.closeButton, 19.0), (.miniaturizeButton, 42.0), (.zoomButton, 65.0)] {
            let b = try #require(w.standardWindowButton(k))
            let r = rect(b, in: w)
            #expect(abs(r.minX - x) <= 1 && abs(r.midY - 26) <= 1, "\(k.rawValue) at \(r)")
            #expect(b.isEnabled, "\(k.rawValue) enabled")
        }
        // One capsule, x 187.5–261, y 8.5–43, with a chevron in each half.
        let cap = rect(wc.capsule, in: w)
        #expect(near(cap, SettingsMetrics.capsuleFrame, px(w)), "capsule at \(cap)")
        #expect(wc.backButton.superview === wc.capsule && wc.forwardButton.superview === wc.capsule)
        #expect(!wc.backButton.isEnabled && !wc.forwardButton.isEnabled)
        // The title: semibold 17 points (R4.2), #4D4D4D, its text 12.5 after the capsule, centred on y 26.
        let title = rect(wc.titleLabel, in: w)
        #expect(abs(title.minX + 3.5 - SettingsMetrics.titleX) <= px(w) && abs(title.midY - 26) <= 1, "title at \(title)")
        #expect(wc.titleLabel.font?.pointSize == 17)
        #expect(NSFontManager.shared.weight(of: wc.titleLabel.font!) == NSFontManager.shared.weight(of: .systemFont(ofSize: 17, weight: .semibold)))
        var light: NSColor?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { light = wc.titleLabel.textColor?.usingColorSpace(.sRGB) }
        #expect(light.map { Int(($0.redComponent * 255).rounded()) } == 0x4D)
        #expect(wc.titleLabel.stringValue == "General")
        wc.select(1)
        #expect(wc.titleLabel.stringValue == "Appearance" && wc.backButton.isEnabled)
        w.close()
    }

    @Test func sidebarMetricsAndOrder() throws {
        let t = TestDefaults("r3-sidebar")
        defer { t.remove() }
        let (wc, w) = try makeWindow(t)
        // The reference's twelve panes in order (Simulators is a page of Components, R4.2).
        #expect(SettingsWindowController.paneTitles == ["General", "Appearance", "Accounts", "Coding Assistant", "Behaviors", "Navigation",
                                                        "Notifications", "Editing", "Shortcuts", "Source Control", "Components",
                                                        "Locations"])
        // Flush: from the top edge to the bottom, 179.5 wide, then the divider.
        let side = try #require(wc.sidebar.enclosingScrollView?.superview)
        let s = rect(side, in: w)
        #expect(s.minX == 0 && s.minY == 0 && abs(s.width - 179.5) <= px(w) && s.height == 452, "sidebar \(s)")
        let detail = rect(wc.tabs.view, in: w)
        #expect(abs(detail.minX - 180) <= px(w) && detail.maxX == 710, "detail \(detail)")
        // 32-point rows; the first band y 52–84.
        for row in 0..<wc.sidebar.numberOfRows {
            let rv = try #require(wc.sidebar.rowView(atRow: row, makeIfNecessary: true))
            let r = rect(rv, in: w)
            #expect(r.height == 32 && r.minY == 52 + CGFloat(row) * 32, "row \(row) at \(r)")
            let cell = try #require(wc.sidebar.view(atColumn: 0, row: row, makeIfNecessary: true) as? SettingsSidebarCellView)
            cell.layoutSubtreeIfNeeded()
            // The symbol centred on x 29, tinted with the accent; labels aligned at x 47.
            let sym = rect(cell.symbol, in: w)
            #expect(abs(sym.midX - 29) <= px(w) + 0.5, "\(cell.label.stringValue) symbol at \(sym)")
            // A label's ink starts 3 points into its frame.
            #expect(abs(rect(cell.label, in: w).minX + 3 - 47) <= px(w), "\(cell.label.stringValue) label")
            #expect(cell.symbol.image != nil, "\(cell.label.stringValue) symbol")
        }
        // The selected row: white on the band; the others accent-tinted.
        let first = try #require(wc.sidebar.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SettingsSidebarCellView)
        let second = try #require(wc.sidebar.view(atColumn: 0, row: 1, makeIfNecessary: true) as? SettingsSidebarCellView)
        #expect(first.symbol.contentTintColor == .white && second.symbol.contentTintColor == .controlAccentColor)
        w.close()
    }

    @Test func generalPaneCards() throws {
        let t = TestDefaults("r3-general")
        defer { t.remove() }
        let (wc, w) = try makeWindow(t)
        let pane = try #require(wc.pane(GeneralSettingsPane.self))
        pane.view.layoutSubtreeIfNeeded()
        w.contentView?.superview?.layoutSubtreeIfNeeded()
        #expect(pane.headers.map(\.stringValue) == ["Starting Points", "Navigation and Files", "Issues", "Test Parallelization", "Report Navigator",
                                                   "Settings Import & Export", "Reset Ycode"])
        #expect(pane.cards.count == 7)
        for c in pane.cards {
            let r = rect(c, in: w)
            #expect(r.minX == 200 && r.maxX == 690, "card at \(r)")
        }
        // The first card at y 98; its header's cap top 22.5 above it.
        let first = rect(pane.cards[0], in: w)
        #expect(abs(first.minY - 98) <= 1, "first card at \(first)")
        #expect(abs(rect(pane.cards[1], in: w).minY - 223) <= 1.5, "second card at \(rect(pane.cards[1], in: w))")
        // Rows: 37.5 for one line; separators 1 point inset 10.
        let navigation = pane.cards[1]
        let rows = navigation.rowViews.compactMap { $0 as? SettingsRowView }
        #expect(rows.map(\.label.stringValue) == ["Navigator size", "Bookmark navigator detail", "Find navigator detail", "Issue navigator detail",
                                                  "Window tabs have independent sidebar widths", "Automatically unlock files", "File extensions"])
        for r in rows where r.help == nil { #expect(abs(r.frame.height - 37.5) <= px(w), "\(r.label.stringValue) \(r.frame.height)") }
        let separators = navigation.rows.arrangedSubviews.compactMap { $0 as? SettingsSeparatorView }
        #expect(separators.count == rows.count - 1 && separators.allSatisfy { $0.frame.height == 1 })
        // Labels left at card + 10 (text), no colons; pop-ups' circles 13.5 inside, switches 10.
        for r in rows {
            #expect(!r.label.stringValue.hasSuffix(":"))
            #expect(abs(rect(r.label, in: w).minX + 3 - 211) <= px(w), "\(r.label.stringValue) label ink")
            let c = try #require(r.controls.first)
            let cr = rect(c, in: w)
            #expect(abs(cr.maxX - 680) <= 0.5, "\(r.label.stringValue) control ends at \(cr.maxX)")
            #expect(abs(cr.midY - rect(r.label, in: w).midY) <= 1, "\(r.label.stringValue) control centred on the label")
            if c is NSPopUpButton { #expect((c as? NSPopUpButton)?.cell is SettingsCardPopUpCell) }
        }
        #expect(rows[4].controls.first is NSSwitch && rows[5].controls.first is NSSwitch && rows[0].controls.first is NSPopUpButton)
        // Help text: secondary colour, 11 points on a 14-point pitch, the
        // first baseline 19 under the label's, at most 416 wide.
        let restore = try #require(pane.cards[0].rowViews.first as? SettingsRowView)
        let help = try #require(restore.help)
        #expect(help.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .secondaryLabelColor)
        let style = help.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.minimumLineHeight == 14 && style?.maximumLineHeight == 14)
        #expect(help.frame.width <= 416.5)
        let gap = (help.frame.minY + help.firstBaselineOffsetFromTop) - (restore.label.frame.minY + restore.label.firstBaselineOffsetFromTop)
        #expect(abs(gap - 19) <= 0.5, "help baseline gap \(gap)")
        #expect(rows[4].help != nil)
        // The card's colour and radius.
        var fill: NSColor?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { fill = SettingsColors.card.usingColorSpace(.sRGB) }
        #expect(fill.map { Int(($0.redComponent * 255).rounded()) } == 0xF7 && SettingsMetrics.cardRadius == 12)
        // A card's bottom 33 above the next header's cap top (within a point).
        let h2 = rect(pane.headers[1], in: w)
        let capTop2 = h2.minY + (h2.height - pane.headers[1].baselineOffsetFromBottom) - pane.headers[1].font!.capHeight
        #expect(abs(capTop2 - (first.maxY + 33)) <= 1.5, "second header cap top \(capTop2), first card ends \(first.maxY)")
        w.close()
    }

    @Test func everyPaneUsesCards() throws {
        let t = TestDefaults("r3-panes")
        defer { t.remove() }
        let (wc, w) = try makeWindow(t)
        for (i, title) in SettingsWindowController.paneTitles.enumerated() {
            wc.select(i)
            guard let pane = wc.tabs.tabViewItems[i].viewController as? SettingsPane else {
                // Locations: one card.
                let loc = try #require(wc.tabs.tabViewItems[i].viewController as? SettingsController)
                _ = loc.view
                #expect(loc.card != nil && title == "Locations")
                continue
            }
            pane.view.layoutSubtreeIfNeeded()
            #expect(!pane.cards.isEmpty, "\(title) has cards")
            for c in pane.cards {
                let r = rect(c, in: w)
                #expect(r.minX == 200 && r.maxX == 690, "\(title) card at \(r)")
                for row in c.rowViews.compactMap({ $0 as? SettingsRowView }) where !row.isContent && !row.label.stringValue.isEmpty {
                    #expect(!row.label.stringValue.hasSuffix(":"), "\(title): \(row.label.stringValue)")
                }
            }
        }
        #expect(w.frame.size == SettingsMetrics.windowSize)
        w.close()
    }

    @Test(.enabled(if: outDir != nil)) func shots() throws {
        _ = NSApplication.shared
        let out = URL(fileURLWithPath: try #require(Self.outDir))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let t = TestDefaults("r3-shots")
        defer { t.remove() }
        for appearance in ["light", "dark"] {
            let wc = SettingsWindowController(prefs: Preferences(defaults: t.defaults), components: [])
            let w = try #require(wc.window)
            w.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            for pane in ["General", "Appearance", "Accounts", "Navigation", "Editing", "Shortcuts", "Locations"] {
                wc.select(try #require(SettingsWindowController.paneTitles.firstIndex(of: pane)))
                let frameView = try #require(w.contentView?.superview)
                frameView.layoutSubtreeIfNeeded()
                // Drawn at 2x, as the council's Retina stills.
                let size = frameView.bounds.size
                let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                rep.size = size
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                try #require(rep.representation(using: .png, properties: [:]))
                    .write(to: out.appendingPathComponent("mac-\(appearance)-\(pane.lowercased()).png"))
            }
            w.close()
        }
    }
}
