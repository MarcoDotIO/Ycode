import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 4, Settings (`specs/ide/settings.md` R4.1–R4.3, checklist
/// rows 89–96): the Editing pane's cards and navigation rows with their
/// icons, the pop-ups' values and wells, the switch, the twelve-row
/// sidebar with Simulators under Components, the selection, the title and
/// the dark palette. Positions are window points from the top-left; colours
/// are read from the window drawn at 2x in the dark appearance. With
/// `YCODE_SETTINGS_SHOTS` set to a folder, `shots` writes
/// `mac-r4-<appearance>-<page>.png`.
@MainActor
@Suite(.serialized) struct SettingsR4Tests {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["YCODE_SETTINGS_SHOTS"]

    func rect(_ v: NSView, in window: NSWindow) -> NSRect {
        let r = v.convert(v.bounds, to: nil)
        return NSRect(x: r.minX, y: window.frame.height - r.maxY, width: r.width, height: r.height)
    }

    func makeWindow(_ t: TestDefaults, dark: Bool = true) throws -> (SettingsWindowController, NSWindow) {
        _ = NSApplication.shared
        let wc = SettingsWindowController(prefs: Preferences(defaults: t.defaults), components: [])
        let w = try #require(wc.window)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView?.superview?.layoutSubtreeIfNeeded()
        return (wc, w)
    }

    func layout(_ w: NSWindow) {
        w.contentView?.superview?.layoutSubtreeIfNeeded()
        w.contentView?.superview?.layoutSubtreeIfNeeded()
    }

    /// The window drawn at 2x (as the council's Retina stills).
    func render(_ w: NSWindow) throws -> NSBitmapImageRep {
        let frameView = try #require(w.contentView?.superview)
        layout(w)
        let size = frameView.bounds.size
        let base = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        // Tagged sRGB, so the pixels are the sRGB values drawn.
        let rep = try #require(base.retagging(with: .sRGB))
        rep.size = size
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        return rep
    }

    /// The sRGB hex of the pixel at a window point (top-left origin).
    func hex(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> UInt32 {
        guard let c = rep.colorAt(x: Int(x * 2), y: Int(y * 2)) else { return 0 }
        func b(_ v: CGFloat) -> UInt32 { UInt32((v * 255).rounded()) }
        return b(c.redComponent) << 16 | b(c.greenComponent) << 8 | b(c.blueComponent)
    }

    func close(_ a: UInt32, _ b: UInt32, _ tolerance: Int = 6) -> Bool {
        for shift in [16, 8, 0] where abs(Int((a >> UInt32(shift)) & 0xFF) - Int((b >> UInt32(shift)) & 0xFF)) > tolerance { return false }
        return true
    }

    func dark(_ c: NSColor) -> UInt32 {
        var out: UInt32 = 0
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            if let s = c.usingColorSpace(.sRGB) {
                out = UInt32((s.redComponent * 255).rounded()) << 16 | UInt32((s.greenComponent * 255).rounded()) << 8 | UInt32((s.blueComponent * 255).rounded())
            }
        }
        return out
    }

    func editing(_ wc: SettingsWindowController, _ w: NSWindow) throws -> TextEditingSettingsPane {
        wc.select(try #require(SettingsWindowController.paneTitles.firstIndex(of: "Editing")))
        let pane = try #require(wc.pane(TextEditingSettingsPane.self))
        pane.page = .main
        layout(w)
        return pane
    }

    // MARK: Row 89: the Editing pane's cards

    @Test func editingPaneCards() throws {
        let t = TestDefaults("r4-editing-cards")
        defer { t.remove() }
        let (wc, w) = try makeWindow(t)
        let pane = try editing(wc, w)
        // No "Files" header: When Editing and Localized Strings only.
        #expect(pane.headers.map(\.stringValue) == ["When Editing", "Localized Strings"])
        #expect(pane.cards.count >= 4)
        let ys = pane.cards.prefix(4).map { rect($0, in: w) }
        // Card 1 y 72–206 (three 44-point rows and two separators).
        #expect(abs(ys[0].minY - 72) <= 0.5 && abs(ys[0].maxY - 206) <= 0.5, "card 1 \(ys[0])")
        // Card 2 216–253.5: text encoding alone.
        #expect(abs(ys[1].minY - 216) <= 0.5 && abs(ys[1].maxY - 253.5) <= 0.5, "card 2 \(ys[1])")
        #expect(pane.cards[1].rowViews.compactMap { ($0 as? SettingsRowView)?.label.stringValue } == ["Default text encoding"])
        // Card 3 from 263.5: line endings and the convert switch (37 + 1 + 36.5 measured).
        #expect(abs(ys[2].minY - 263.5) <= 0.5 && abs(ys[2].maxY - 338) <= 1.5, "card 3 \(ys[2])")
        #expect(pane.cards[2].rowViews.compactMap { ($0 as? SettingsRowView)?.label.stringValue }
            == ["Default line endings", "Convert existing files on save"])
        // Cards 10 apart; When Editing's card at 394.
        #expect(abs(ys[1].minY - ys[0].maxY - 10) <= 0.5 && abs(ys[2].minY - ys[1].maxY - 10) <= 0.5)
        #expect(abs(ys[3].minY - 394) <= 1.5, "When Editing card \(ys[3])")
        // The header's ink 33 below card 3 (cap top) and 10.5 above card 4.
        let h = pane.headers[0]
        let hr = rect(h, in: w)
        let capTop = hr.minY + (hr.height - h.baselineOffsetFromBottom) - h.font!.capHeight
        #expect(abs(capTop - (ys[2].maxY + 33)) <= 1, "When Editing cap top \(capTop)")
        // The pop-ups are card pop-ups (value and well).
        for title in ["Default text encoding", "Default line endings"] {
            let p = try #require(pane.control(NSPopUpButton.self, inRow: title))
            #expect(p.cell is SettingsCardPopUpCell && p.titleOfSelectedItem?.isEmpty == false)
        }
        w.close()
    }

    // MARK: Row 90: navigation rows and icons

    @Test func navigationRowsAndIcons() throws {
        let t = TestDefaults("r4-navigation-rows")
        defer { t.remove() }
        let (wc, w) = try makeWindow(t)
        let pane = try editing(wc, w)
        let rows = pane.cards[0].rowViews.compactMap { $0 as? SettingsRowView }
        #expect(rows.map(\.label.stringValue) == ["Display", "Completion", "Indentation"])
        let rep = try render(w)
        let expected: [SettingsRowIcon] = [.display, .completion, .indentation]
        for (i, r) in rows.enumerated() {
            let rr = rect(r, in: w)
            #expect(abs(rr.height - 44) <= 0.01, "\(r.label.stringValue) row \(rr.height)")
            let icon = try #require(r.iconView as? SettingsRowIconView)
            #expect(icon.icon == expected[i])
            let ir = rect(icon, in: w)
            #expect(ir.minX == 210 && ir.width == 24 && ir.height == 24, "\(r.label.stringValue) icon \(ir)")
            #expect(abs(ir.midY - rr.midY) <= 0.01, "icon centred")
            // Label ink at x 245 (the frame 3 before its ink).
            #expect(abs(rect(r.label, in: w).minX + 3 - 245) <= 0.51, "\(r.label.stringValue) label at \(rect(r.label, in: w).minX + 3)")
            // The disclosure: 5 × 9 ending 11 inside the card (x 679).
            let d = try #require(r.controls.first as? SettingsDisclosureView)
            let dr = rect(d, in: w)
            #expect(abs(dr.minX - 674) <= 0.01 && abs(dr.minX + 5 - 679) <= 0.01, "chevron \(dr)")
            // The gradient: the top lighter than the bottom, near the spec's ends.
            let g = expected[i].gradient
            let top = hex(rep, ir.midX, ir.minY + 0.5), bottom = hex(rep, ir.midX, ir.maxY - 0.5)
            #expect(close(top, g.top, 12) && close(bottom, g.bottom, 12), "\(r.label.stringValue) gradient \(String(top, radix: 16)) → \(String(bottom, radix: 16))")
            // A white symbol at the centre region.
            var white = false
            for dx in stride(from: CGFloat(-6), through: 6, by: 0.5) {
                for dy in stride(from: CGFloat(-4), through: 4, by: 0.5) where hex(rep, ir.midX + dx, ir.midY + dy) == 0xFFFFFF { white = true }
            }
            #expect(white, "\(r.label.stringValue) symbol")
            // An accessible button that opens its page.
            #expect(r.accessibilityRole() == .button && r.accessibilityLabel() == r.label.stringValue)
        }
        // Separators x 210–680.
        let sep = try #require(pane.cards[0].rows.arrangedSubviews.first { $0 is SettingsSeparatorView })
        let sr = rect(sep, in: w)
        #expect(sr.minX == 200 && sr.maxX == 690 && sr.height == 1)
        #expect(close(hex(rep, 212, sr.minY + 0.25), 0x303030, 3) && close(hex(rep, 205, sr.minY + 0.25), 0x262626, 3), "separator inset 10")
        // The chevron's colour.
        #expect(dark(SettingsColors.disclosure) == 0x5C5C5C)
        // Pressing a row opens its page.
        _ = rows[2].accessibilityPerformPress()
        #expect(pane.page == .indentation)
        pane.page = .main
        w.close()
    }

    // MARK: Row 91: pop-up values in every pane

    /// The gap between a pop-up's value ink and its well, and the well's fill.
    func popUpGap(_ p: NSPopUpButton, _ rep: NSBitmapImageRep, _ w: NSWindow, card: UInt32) -> (gap: CGFloat, well: UInt32)? {
        let r = rect(p, in: w)
        let wellMinX = r.maxX - (SettingsMetrics.popUpCircleInset - SettingsMetrics.controlInset) - SettingsMetrics.popUpCircle
        // The rightmost column with text ink left of the well.
        var x = wellMinX - 0.5
        while x > r.minX {
            for y in stride(from: r.minY, through: r.maxY, by: 0.5) where !close(hex(rep, x, y), card, 24) {
                return (wellMinX - (x + 0.5), hex(rep, wellMinX + 3, r.midY))
            }
            x -= 0.5
        }
        return nil
    }

    @Test func popUpValuesEndBeforeTheWell() throws {
        let t = TestDefaults("r4-popups")
        defer { t.remove() }
        let (wc, w) = try makeWindow(t)
        var checked = 0
        for (i, title) in SettingsWindowController.paneTitles.enumerated() {
            wc.select(i)
            guard let pane = wc.tabs.tabViewItems[i].viewController as? SettingsPane else { continue }
            layout(w)
            let rep = try render(w)
            for card in pane.cards {
                for row in card.rowViews.compactMap({ $0 as? SettingsRowView }) {
                    guard let p = row.controls.first as? NSPopUpButton, p.cell is SettingsCardPopUpCell else { continue }
                    let r = rect(p, in: w)
                    guard r.minY > SettingsMetrics.titleAreaHeight, r.maxY < SettingsMetrics.windowSize.height - 4 else { continue }
                    let m = try #require(popUpGap(p, rep, w, card: 0x262626), "\(title) \(row.label.stringValue)")
                    #expect(m.gap >= 12 && m.gap <= 13.5, "gap \(m.gap) \(title) \(row.label.stringValue): value ends \(m.gap) before the well")
                    #expect(close(m.well, 0x363636, 4), "\(title) well \(String(m.well, radix: 16))")
                    checked += 1
                }
            }
        }
        #expect(checked >= 4)
        // The value in the label colour.
        #expect(dark(SettingsColors.label) == 0xDEDEDE && dark(SettingsColors.popUpCircle) == 0x363636)
        w.close()
    }

    // MARK: Row 92: the switch

    @Test func switchSizeKnobAndColours() throws {
        let t = TestDefaults("r4-switch")
        defer { t.remove() }
        let (wc, w) = try makeWindow(t)
        let pane = try editing(wc, w)
        let off = try #require(pane.control(NSSwitch.self, inRow: "Convert existing files on save"))
        let on = try #require(pane.control(NSSwitch.self, inRow: "Automatically trim trailing whitespace"))
        #expect(off.state == .off && on.state == .on)
        let rep = try render(w)
        for s in [off, on] {
            let r = rect(s, in: w)
            #expect(r.width == 36 && r.height == 16 && r.maxX == 680, "switch \(r)")
        }
        let ro = rect(off, in: w), rn = rect(on, in: w)
        // Off: #3B3B3B at the trailing end, the white knob at the leading end.
        #expect(close(hex(rep, ro.maxX - 4, ro.midY), 0x3B3B3B, 3), "off \(String(hex(rep, ro.maxX - 4, ro.midY), radix: 16))")
        #expect(hex(rep, ro.minX + 10, ro.midY) == 0xFFFFFF)
        // On: the accent at the leading end, the knob at the trailing end.
        #expect(close(hex(rep, rn.minX + 4, rn.midY), 0x0679F7, 3), "on \(String(hex(rep, rn.minX + 4, rn.midY), radix: 16))")
        #expect(hex(rep, rn.maxX - 10, rn.midY) == 0xFFFFFF)
        // The knob about 21 × 12: white for 21 points along the middle.
        var run: CGFloat = 0
        for x in stride(from: ro.minX, to: ro.maxX, by: 0.5) where hex(rep, x, ro.midY) == 0xFFFFFF { run += 0.5 }
        #expect(run >= 19 && run <= 21.5, "knob width \(run)")
        // A click flips it and saves.
        off.mouseDown(with: try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                            windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        #expect(off.state == .on && Preferences(defaults: t.defaults).convertExistingFilesOnSave)
        // Still a switch to accessibility; pressing flips it back.
        #expect(off.accessibilityRole() == .checkBox && off.accessibilitySubrole() == .switch)
        #expect(off.accessibilityPerformPress() && off.state == .off)
        #expect(SettingsMetrics.switchKnobSize == CGSize(width: 21, height: 12))
        w.close()
    }

    // MARK: Rows 93 and 94: the sidebar

    @Test func sidebarFitsTwelveRowsWithSimulatorsUnderComponents() throws {
        let t = TestDefaults("r4-sidebar")
        defer { t.remove() }
        let (wc, w) = try makeWindow(t)
        #expect(wc.sidebar.numberOfRows == 12)
        let scroll = try #require(wc.sidebar.enclosingScrollView)
        #expect(!scroll.hasVerticalScroller && scroll.verticalScroller?.isHidden ?? true)
        let last = rect(try #require(wc.sidebar.rowView(atRow: 11, makeIfNecessary: true)), in: w)
        #expect(last.maxY == 436, "last row ends \(last.maxY)")
        // The selection: x 10–170, 32 tall, #007AFF.
        let rep = try render(w)
        #expect(close(hex(rep, 11, 68), 0x007AFF, 3) && close(hex(rep, 169.5, 68), 0x007AFF, 3), "band \(String(hex(rep, 169.5, 68), radix: 16))")
        #expect(!close(hex(rep, 170.5, 68), 0x007AFF, 30) && !close(hex(rep, 9.5, 68), 0x007AFF, 30))
        // Simulators: the Simulator Host row at the end of Components'
        // "Other Components" opens it (R5.5), with Components selected in
        // the sidebar and as the title; its way back returns.
        let components = try #require(SettingsWindowController.paneTitles.firstIndex(of: "Components"))
        wc.select(components)
        let pane = try #require(wc.pane(ComponentsSettingsPane.self))
        layout(w)
        let row = try #require(pane.rows.other.last)
        #expect(row.title == SimulatorHostPage.title && row.kind == .simulatorHost)
        pane.showInfo(row)
        #expect(wc.selectedPane == "Simulators" && wc.sidebar.selectedRow == components && wc.titleLabel.stringValue == "Components")
        let sims = try #require(wc.pane(SimulatorsSettingsPane.self))
        #expect(sims.rowTitles.contains("Lean boot"))
        wc.goBack()
        #expect(wc.selectedPane == "Components")
        wc.show(page: "Simulators")
        #expect(wc.selectedPane == "Simulators" && wc.sidebar.selectedRow == components)
        w.close()
    }

    // MARK: Row 95: the title; row 96: the dark palette

    @Test func titleAndDarkPalette() throws {
        let t = TestDefaults("r4-title")
        defer { t.remove() }
        let (wc, w) = try makeWindow(t)
        let font = try #require(wc.titleLabel.font)
        // 15 points since round 5 (R5.3), the same weight.
        #expect(font.pointSize == 15)
        #expect(NSFontManager.shared.weight(of: font) == NSFontManager.shared.weight(of: .systemFont(ofSize: 15, weight: .semibold)))
        #expect(dark(SettingsColors.title) == 0xE8E8E8)
        // R4.3.
        #expect(dark(SettingsColors.detail) == 0x1F1F1F && dark(SettingsColors.card) == 0x262626)
        #expect(dark(SettingsColors.separator) == 0x303030 && dark(SettingsColors.sidebar) == 0x262627)
        #expect(dark(SettingsColors.divider) == 0x414142 && dark(SettingsColors.selection) == 0x007AFF)
        #expect(dark(SettingsColors.header) == 0xDDDDDD && dark(SettingsColors.label) == 0xDEDEDE)
        // Drawn: the sidebar, its divider at x 179.5, the detail and a card.
        let rep = try render(w)
        #expect(close(hex(rep, 90, 445), 0x262627, 2) && close(hex(rep, 179.75, 445), 0x414142, 2))
        #expect(close(hex(rep, 195, 300), 0x1F1F1F, 2) && close(hex(rep, 400, 130), 0x262626, 2))
        w.close()
    }

    @Test(.enabled(if: outDir != nil)) func shots() throws {
        _ = NSApplication.shared
        let out = URL(fileURLWithPath: try #require(Self.outDir))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let t = TestDefaults("r4-shots")
        defer { t.remove() }
        for appearance in ["light", "dark"] {
            let (wc, w) = try makeWindow(t, dark: appearance == "dark")
            for page in ["General", "Editing", "Components", "Simulators"] {
                wc.show(page: page)
                try #require(render(w).representation(using: .png, properties: [:]))
                    .write(to: out.appendingPathComponent("mac-r4-\(appearance)-\(page.lowercased()).png"))
            }
            w.close()
        }
    }
}
