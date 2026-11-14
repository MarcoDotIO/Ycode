import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 5, Settings (`specs/ide/settings.md` R5.1–R5.5, checklist
/// rows 117–124): the Appearance pane's card, thumbnails, ring and captions,
/// the preview box, the separators and the Theme / Fonts / Editor control,
/// the list's Theme, Name and colour rows; Components' two sections and row
/// anatomy with the simulator host at the end of "Other Components"; the
/// title's size and the selected sidebar label's weight. Positions are
/// window points from the top-left; colours are read from the window drawn
/// at 2x. The window is never put on screen. With `YCODE_B5_SHOTS` set to a
/// folder, the panes are written there as `mac-r5-<appearance>-<page>.png`.
@MainActor
@Suite(.serialized) struct SettingsR5Tests {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["YCODE_B5_SHOTS"]
    let r4 = SettingsR4Tests()

    func rect(_ v: NSView, in w: NSWindow) -> NSRect { r4.rect(v, in: w) }

    /// Within `tol` points on every edge (a window off the displays lays
    /// out at scale 1, so half points round to whole ones).
    func near(_ a: NSRect, _ b: NSRect, _ tol: CGFloat = 0.5) -> Bool {
        abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol && abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }

    /// Theme files go to a folder of the test's own.
    static func themesFolder(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build-ide/settings/r5-\(name)-\(UUID().uuidString)/Themes")
    }

    func makeWindow(_ t: TestDefaults, dark: Bool = false, inventory: ComponentsInventory? = nil) throws -> (SettingsWindowController, NSWindow) {
        _ = NSApplication.shared
        let prefs = Preferences(defaults: t.defaults, themesDirectory: Self.themesFolder("window"))
        let wc = SettingsWindowController(prefs: prefs, components: [], componentsInventory: inventory ?? Self.inventory)
        let w = try #require(wc.window)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        r4.layout(w)
        return (wc, w)
    }

    /// An inventory with a used iOS runtime, a watchOS runtime and the Mac's SDK.
    static let inventory = ComponentsInventory(
        sdks: [.init(canonicalName: "macosx27.1", version: "27.1"), .init(canonicalName: "iphoneos27.1", version: "27.1")],
        runtimes: [SimRuntimeRecord(platform: .iOS, version: "27.1", build: "24A94401", sizeBytes: 15_940_000_000, lastUsed: "2026-11-04T10:00:00Z"),
                   SimRuntimeRecord(platform: .watchOS, version: "27.0", build: "24R100", sizeBytes: 4_120_000_000)])

    func select(_ wc: SettingsWindowController, _ w: NSWindow, _ title: String) throws {
        wc.select(try #require(SettingsWindowController.paneTitles.firstIndex(of: title)))
        r4.layout(w)
    }

    /// The ink box of the pixels in `r` that differ from `background` (window points).
    func ink(_ rep: NSBitmapImageRep, in r: NSRect, background: UInt32, tolerance: Int = 40) -> NSRect? {
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for y in stride(from: r.minY, to: r.maxY, by: 0.5) {
            for x in stride(from: r.minX, to: r.maxX, by: 0.5) where !r4.close(r4.hex(rep, x, y), background, tolerance) {
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x + 0.5); maxY = max(maxY, y + 0.5)
            }
        }
        return minX.isFinite ? NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) : nil
    }

    // MARK: Row 117: the Appearance card

    @Test func appearanceCardThumbnailsRingAndCaptions() throws {
        let t = TestDefaults("r5-appearance-card")
        defer { t.remove() }
        let (wc, w) = try makeWindow(t)
        try select(wc, w, "Appearance")
        let pane = try #require(wc.pane(ThemesSettingsPane.self))
        Preferences(defaults: t.defaults).appearance = .light
        pane.chooseAppearance(.light)
        r4.layout(w)
        let card = rect(try #require(pane.appearanceCard), in: w)
        #expect(near(card, NSRect(x: 200, y: 72, width: 490, height: 88)), "card \(card)")
        // The label's ink at x 210.5, its cap top 85.5.
        let label = try #require(pane.appearanceLabel)
        #expect(label.stringValue == "Appearance")
        let lr = rect(label, in: w)
        let capTop = lr.minY + (lr.height - label.baselineOffsetFromBottom) - label.font!.capHeight
        #expect(abs(capTop - 85.5) <= 1, "label cap top \(capTop)")
        // Three thumbnails 67 × 44 at x 463, 538, 613, y 85.
        #expect(pane.appearanceButtons.map(\.title) == ["System", "Light", "Dark"])
        for (b, x) in zip(pane.appearanceButtons, [463.0, 538.0, 613.0]) {
            let r = rect(b, in: w).insetBy(dx: 4, dy: 4)
            #expect(near(r, NSRect(x: x, y: 85, width: 67, height: 44)), "\(b.title) \(r)")
        }
        #expect(pane.appearanceButtons.map(\.state) == [.off, .on, .off])
        let rep = try r4.render(w)
        // The ring: 3 points of #0088FF, 1 outside the Light thumbnail (x 534–537 at its middle).
        #expect(r4.close(r4.hex(rep, 535.5, 107), 0x0088FF, 8), "ring \(String(r4.hex(rep, 535.5, 107), radix: 16))")
        #expect(r4.close(r4.hex(rep, 536.75, 107), 0x0088FF, 30) && r4.close(r4.hex(rep, 537.5, 107), 0xF7F7F7, 8)
            && r4.close(r4.hex(rep, 533.25, 107), 0xF7F7F7, 8), "ring edges")
        // No ring around System.
        #expect(r4.close(r4.hex(rep, 460.5, 107), 0xF7F7F7, 4))
        // A wallpaper and a window: the Light thumbnail's top-left is blue, its window white.
        let wall = r4.hex(rep, 540, 87)
        #expect((wall & 0xFF) > ((wall >> 16) & 0xFF) + 40, "wallpaper \(String(wall, radix: 16))")
        // (R7.4: a close-up, the window's body below its title area.)
        #expect(r4.close(r4.hex(rep, 560, 125), 0xFFFFFF, 6), "window")
        // System: left half light, right half dark.
        #expect(r4.close(r4.hex(rep, 485, 125), 0xFFFFFF, 6) && r4.close(r4.hex(rep, 515, 125), 0x262626, 8))
        // Captions: cap top 139, the selected bold and #262626, the others #7C7C7C regular.
        for (i, c) in pane.captions.enumerated() {
            let cr = rect(c, in: w)
            let top = cr.minY + (cr.height - c.baselineOffsetFromBottom) - c.font!.capHeight
            #expect(abs(top - 139) <= 1, "\(c.stringValue) cap top \(top)")
            #expect(abs(cr.midX - (rect(pane.appearanceButtons[i], in: w).midX)) <= 0.5)
            let bold = NSFontManager.shared.traits(of: c.font!).contains(.boldFontMask)
            #expect(bold == (i == 1), "\(c.stringValue) bold \(bold)")
        }
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            #expect(SettingsColors.rgb(0x262626) == SettingsColors.rgb(SettingsR5Palette.captionSelected.light))
        }
        #expect(SettingsR5Palette.caption.light == 0x7C7C7C && SettingsR5Palette.ring.light == 0x0088FF)
        // Choosing Dark moves the ring and the bold caption.
        (pane.appearanceButtons[2] as? AppearanceThumbnailButton)?.onChoose?()
        #expect(Preferences(defaults: t.defaults).appearance == .dark && pane.appearanceButtons.map(\.state) == [.off, .off, .on])
        #expect(NSFontManager.shared.traits(of: pane.captions[2].font!).contains(.boldFontMask))
        w.close()
    }

    // MARK: Row 118: the preview

    @Test func previewBoxNumbersAndNoWrap() throws {
        let t = TestDefaults("r5-preview")
        defer { t.remove() }
        let (wc, w) = try makeWindow(t)
        try select(wc, w, "Appearance")
        let pane = try #require(wc.pane(ThemesSettingsPane.self))
        let box = try #require(pane.previewBox as? ThemePreviewBox)
        let br = rect(box, in: w)
        #expect(near(br, NSRect(x: 200, y: 170, width: 490, height: 69.5)), "preview \(br)")
        #expect(pane.preview.string.contains("struct Greeter"))
        // No wrapping: the text container is wider than the box, so the long
        // line stays one line; the box scrolls both ways.
        #expect(pane.preview.textContainer?.widthTracksTextView == false)
        let lm = try #require(pane.preview.layoutManager)
        let glyphs = lm.numberOfGlyphs
        var fragments = 0
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: glyphs)) { _, _, _, _, _ in fragments += 1 }
        #expect(fragments == ThemesSettingsPane.previewCode.components(separatedBy: "\n").count, "\(fragments) line fragments")
        #expect(box.scroll.hasHorizontalScroller && box.scroll.hasVerticalScroller)
        // The 18-point pitch.
        var tops: [CGFloat] = []
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: glyphs)) { r, _, _, _, _ in tops.append(r.minY) }
        #expect(tops.count > 2 && abs(tops[2] - tops[1] - 18) < 0.01, "pitch \(tops)")
        // The code from x 243; line numbers ending at x 228 in #B8B3B4.
        #expect(abs(rect(box.scroll, in: w).minX - 243) < 0.01)
        let rep = try r4.render(w)
        let numbers = try #require(ink(rep, in: NSRect(x: 201, y: 171, width: 41, height: 22), background: r4.hex(rep, 205, 200), tolerance: 20))
        #expect(abs(numbers.maxX - 228) <= 1, "numbers end \(numbers.maxX)")
        // The border: 1 point #E6E6E6 at the box's top edge, away from the corners.
        #expect(r4.close(r4.hex(rep, 400, 170.25), 0xE6E6E6, 6), "border \(String(r4.hex(rep, 400, 170.25), radix: 16))")
        w.close()
    }

    // MARK: Row 119: separators, segments and the list's own scroll

    @Test func segmentsCentredBetweenSeparators() throws {
        let t = TestDefaults("r5-segments")
        defer { t.remove() }
        let (wc, w) = try makeWindow(t)
        try select(wc, w, "Appearance")
        let pane = try #require(wc.pane(ThemesSettingsPane.self))
        let seg = try #require(pane.segments as? SettingsSegmentsControl)
        #expect(near(rect(seg, in: w), NSRect(x: 340, y: 264.5, width: 210, height: 28)))
        #expect(seg.titles == ["Theme", "Fonts", "Editor"] && seg.segmentWidth == 70)
        let s1 = rect(pane.separators[0], in: w), s2 = rect(pane.separators[1], in: w)
        #expect(near(s1, NSRect(x: 180, y: 251.5, width: 530, height: 1)) && near(s2, NSRect(x: 180, y: 304.5, width: 530, height: 1)), "\(s1) \(s2)")
        let rep = try r4.render(w)
        #expect(r4.close(r4.hex(rep, 300, s1.minY + 0.25), 0xE5E5E5, 4), "separator \(String(r4.hex(rep, 300, s1.minY + 0.25), radix: 16))")
        // Theme selected: the accent capsule; a divider only between Fonts and Editor.
        #expect(r4.close(r4.hex(rep, 360, 278.5), 0x0077F9, 6))
        #expect(r4.close(r4.hex(rep, 479.75, 278.5), 0xB5B5B5, 10), "divider \(String(r4.hex(rep, 479.75, 278.5), radix: 16))")
        #expect(r4.close(r4.hex(rep, 410.25, 278.5), 0xECECEC, 6), "no divider next to the selection")
        // The list scrolls on its own, from y 305; the top part stays.
        let scroll = try #require(pane.formScroll)
        #expect(abs(rect(scroll, in: w).minY - 305) <= 0.5)
        #expect(abs((pane.cards.first.map { rect($0, in: w).minY } ?? 0) - 305) <= 0.5)
        // Choosing Fonts rebuilds the list only.
        seg.select(1)
        #expect(pane.segment == .fonts && pane.rowTitles.first == "Plain Text")
        #expect(near(rect(seg, in: w), NSRect(x: 340, y: 264.5, width: 210, height: 28)))
        w.close()
    }

    // MARK: Row 120: Theme, Name and the colour rows

    @Test func listThemeNameAndColourRows() throws {
        let t = TestDefaults("r5-list")
        defer { t.remove() }
        let (wc, w) = try makeWindow(t)
        try select(wc, w, "Appearance")
        let pane = try #require(wc.pane(ThemesSettingsPane.self))
        #expect(Array(pane.rowTitles.prefix(3)) == ["Theme", "Name", "Foreground"])
        // R7.1's rows: Foreground, Background; Plain Text; the syntax rows.
        #expect(pane.colorRows.map(\.key) == SettingsAppearanceR7.cards(customizeAllColors: false).flatMap { $0.compactMap(\.key) })
        let cardA = rect(pane.cards[0], in: w), cardB = rect(pane.cards[1], in: w)
        #expect(abs(cardA.minY - 305) <= 0.5 && abs(cardA.height - (39.5 + 1 + 36)) <= 0.5, "card A \(cardA)")
        #expect(abs(cardB.minY - (cardA.maxY + 10)) <= 0.5 && abs(cardB.minY - 391.5) <= 0.5, "card B \(cardB)")
        // Choose…: a push button, no chevron, 24 tall, 10 inside the card.
        let theme = try #require(pane.cards[0].rowViews.first as? SettingsPlainRow)
        let choose = try #require(theme.control as? SettingsPushButton)
        let cr = rect(choose, in: w)
        #expect(choose.title == "Choose\u{2026}" && cr.height == 24 && cr.maxX == 680 && abs(cr.width - 80.5) <= 1, "Choose… \(cr)")
        // Name: the theme's name right-aligned.
        let name = try #require(pane.cards[0].rowViews.last as? SettingsPlainRow)
        // A label's frame is 2 wider than its alignment rect on each side.
        #expect((name.control as? NSTextField)?.stringValue == "Ycode Default" && abs(rect(name.control, in: w).maxX - 2 - 680) <= 0.5)
        // Foreground: 56 tall, the slider x 421.5–624, the well 48 × 28 ending 10 inside.
        let fg = try #require(pane.colorRows.first?.view as? ThemeColorRowView)
        let fr = rect(fg, in: w)
        #expect(fr.height == 56 && abs(fr.minY - 391.5) <= 0.5)
        let sr = rect(fg.slider, in: w), wr = rect(fg.well, in: w)
        #expect(abs(sr.minX - 421.5) <= 0.5 && abs(sr.maxX - 624) <= 0.5 && abs(sr.midY - fr.midY) <= 0.5, "slider \(sr)")
        #expect(near(wr, NSRect(x: 632, y: fr.midY - 14, width: 48, height: 28)), "well \(wr)")
        let lr = rect(fg.label, in: w)
        let capTop = lr.minY + (lr.height - fg.label.baselineOffsetFromBottom) - fg.label.font!.capHeight
        #expect(abs(capTop - (fr.minY + 13)) <= 1, "label cap top \(capTop - fr.minY)")
        // Built-in: read-only.
        #expect(!fg.slider.isEnabled && !fg.well.isEnabled)
        // A user theme: the slider sets the saturation; the well takes #RRGGBB.
        pane.duplicateClicked()
        let p = pane.prefs
        #expect(p.themeName == "Ycode Default Copy")
        // The syntax rows have sliders with Customize All Colors on (R7.1).
        pane.toggle("Customize All Colors")
        #expect(p.theme.customizeAllColors == true)
        let kw = try #require(pane.colorRows.first { $0.key == "keyword" }?.view as? ThemeColorRowView)
        #expect(kw.slider.isEnabled && kw.well.isEnabled)
        kw.well.commit("#3366CC")
        #expect(p.theme.tokens["keyword"] == "#3366CC" && kw.slider.value == 1)
        // The slider: the colour's strength over white (a quarter at the
        // left end, R6.1), stored with the theme.
        kw.slider.set(0)
        let k = ThemeColorRows.paleStrength
        #expect(p.theme.tokens["keyword"] == ThemeColorRows.hex(1 - 0.8 * k, 1 - 0.6 * k, 1 - 0.2 * k), "\(p.theme.tokens["keyword"] ?? "-")")
        #expect(p.theme.strengths?["keyword"] == 0)
        kw.slider.set(1)
        #expect(p.theme.tokens["keyword"] == "#3366CC")
        kw.well.commit("")
        #expect(p.theme.tokens["keyword"] == nil)
        // Choose… picks a theme.
        pane.chooseTheme("Ycode Dusk")
        #expect(p.themeName == "Ycode Dusk" && ((pane.cards[0].rowViews.last as? SettingsPlainRow)?.control as? NSTextField)?.stringValue == "Ycode Dusk")
        w.close()
    }

    // MARK: Rows 121 and 124: Components and the simulator host's entry

    @Test func componentsSectionsAndRows() throws {
        let t = TestDefaults("r5-components")
        defer { t.remove() }
        let (wc, w) = try makeWindow(t)
        try select(wc, w, "Components")
        let pane = try #require(wc.pane(ComponentsSettingsPane.self))
        pane.now = { ComponentsPage.date("2026-11-07T10:00:00Z")! }
        pane.rebuild()
        r4.layout(w)
        // No row above "Platform Support"; its cap top 59; "Other Components" after it.
        #expect(pane.rowTitles.first == "# Platform Support")
        #expect(pane.headers.map(\.stringValue) == ["Platform Support", "Other Components"])
        let h = pane.headers[0]
        let hr = rect(h, in: w)
        let capTop = hr.minY + (hr.height - h.baselineOffsetFromBottom) - h.font!.capHeight
        #expect(abs(capTop - 59) <= 1, "header cap top \(capTop)")
        let card = rect(pane.cards[0], in: w)
        #expect(abs(card.minY - 82) <= 1 && abs(card.height - (5 * 52.5 - 1)) <= 2.5, "card \(card)")
        let titles = pane.rowViews.map(\.row.title)
        #expect(titles == ["macOS 27.1", "iOS 27.1", "watchOS 27.0", "tvOS", "visionOS", "Predictive Code Completion", "Simulator Host"])
        #expect(pane.rowViews.map(\.row.subtitle) == ["Built-in", "15.94 GB", "4.12 GB", "Not installed", "Not installed", "Off", "Not set up"])
        // The second header 33 under the first card; the simulator host last.
        let h2 = pane.headers[1]
        let h2r = rect(h2, in: w)
        let cap2 = h2r.minY + (h2r.height - h2.baselineOffsetFromBottom) - h2.font!.capHeight
        #expect(abs(cap2 - (card.maxY + 33)) <= 1, "second header \(cap2)")
        #expect(pane.rowViews.last?.row.kind == .simulatorHost)
        // Row anatomy: 51.5 tall, the symbol centred on x 226, the title at
        // x 251 (cap top 13.5 under the row's top), the subtitle's baseline
        // 15 under it, "Last used" ending at 655.5, the info button 13 × 13 at 665.5.
        let ios = pane.rowViews[1]
        let rr = rect(ios, in: w)
        #expect(abs(rr.height - 51.5) <= 0.5)
        #expect(abs(rect(ios.glyph, in: w).midX - 226) <= 0.5 && abs(rect(ios.glyph, in: w).midY - rr.midY) <= 0.5, "glyph \(rect(ios.glyph, in: w))")
        let tr = rect(ios.title, in: w)
        #expect(abs(tr.minX + 3 - 251) <= 0.5, "title \(tr)")
        let tCap = tr.minY + (tr.height - ios.title.baselineOffsetFromBottom) - ios.title.font!.capHeight
        #expect(abs(tCap - rr.minY - 13.5) <= 1, "title cap top \(tCap - rr.minY)")
        let sb = rect(ios.subtitle, in: w)
        #expect(abs((sb.maxY - ios.subtitle.baselineOffsetFromBottom) - (tr.maxY - ios.title.baselineOffsetFromBottom) - 15) <= 0.5)
        #expect(ios.row.lastUsed == "Last used 3 days ago" && pane.rowViews[2].lastUsed == nil)
        let lu = rect(try #require(ios.lastUsed), in: w)
        #expect(abs(lu.maxX - 3 - 655.5) <= 1, "last used ends \(lu.maxX)")
        #expect(near(rect(ios.info, in: w), NSRect(x: 665.5, y: rr.midY - 6.5, width: 13, height: 13)), "info \(rect(ios.info, in: w))")
        // The accent symbol.
        let rep = try r4.render(w)
        let gi = try #require(ink(rep, in: rect(ios.glyph, in: w).insetBy(dx: -2, dy: -2), background: 0xF7F7F7))
        #expect(gi.width >= 15 && gi.height >= 15, "symbol ink \(gi)")
        var accent = false
        for x in stride(from: gi.minX, to: gi.maxX, by: 0.5) where r4.close(r4.hex(rep, x, gi.minY + 0.5), 0x007AFF, 30) { accent = true }
        #expect(accent, "accent symbol")
        // The host's info button opens its page; completion's opens Editing ▸ Completion.
        pane.showInfo(try #require(pane.rowViews.last).row)
        #expect(wc.selectedPane == "Simulators" && wc.titleLabel.stringValue == "Components")
        wc.goBack()
        pane.showInfo(pane.rowViews[5].row)
        #expect(wc.selectedPane == "Editing" && wc.pane(TextEditingSettingsPane.self)?.page == .completion)
        w.close()
    }

    // MARK: Row 124: the simulator host page

    @Test func simulatorHostPage() throws {
        let t = TestDefaults("r5-host")
        defer { t.remove() }
        let (wc, w) = try makeWindow(t)
        wc.show(page: "Simulators")
        r4.layout(w)
        let pane = try #require(wc.pane(SimulatorsSettingsPane.self))
        #expect(pane.headers.map(\.stringValue) == SimulatorHostPage.Section.allCases.map(\.rawValue))
        #expect(pane.rowTitles.contains("Lean boot") && pane.rowTitles.contains("Warm boot from snapshot") && !pane.rowTitles.contains("Camera"))
        // The fields: 220 × 22, 10 inside the card.
        let host = try #require(pane.fields[.host])
        let box = try #require(host.superview)
        let br = rect(box, in: w)
        #expect(br.width == 220 && br.height == 22 && abs(br.maxX - 680) <= 0.5, "field \(br)")
        // Host and Data folder are the wizard's host and the run settings' at once.
        pane.set(.host, " me@sim ")
        pane.set(.dataFolder, "/data/y")
        #expect(RuntimeSetupChoices.load(t.defaults).host.destination == "me@sim" && RemoteSimulatorSettings.load(t.defaults).destination == "me@sim")
        #expect(RuntimeSetupChoices.load(t.defaults).host.dataDirectory == "/data/y" && RemoteSimulatorSettings.load(t.defaults).dataDirectory == "/data/y")
        pane.set(.ports, "47820/47821")
        #expect(RuntimeSetupChoices.load(t.defaults).host.tcpPort == 47820)
        pane.set(.ports, "nonsense")
        #expect(RuntimeSetupChoices.load(t.defaults).host.udpPort == 47821 && host.stringValue == "me@sim")
        #expect(pane.hero?.status.stringValue == "me@sim")
        // Components' host row follows.
        let comps = try #require(wc.pane(ComponentsSettingsPane.self))
        #expect(comps.rows.other.last?.subtitle == "me@sim")
        w.close()
    }

    // MARK: Rows 122 and 123: the title and the selected sidebar label

    @Test func titleSizeAndSelectedLabelWeight() throws {
        let t = TestDefaults("r5-title")
        defer { t.remove() }
        for dark in [false, true] {
            let (wc, w) = try makeWindow(t, dark: dark)
            try select(wc, w, "General")
            let rep = try r4.render(w)
            let bg: UInt32 = dark ? 0x1F1F1F : 0xFFFFFF
            // "General": its ink 54.5 wide and 12 tall (the "l" to the "G"'s
            // overshoot, as the council measured it) from x 273.5.
            let title = try #require(ink(rep, in: NSRect(x: 265, y: 10, width: 120, height: 34), background: bg))
            #expect(abs(title.minX - 273.5) <= 1, "title x \(title.minX)")
            #expect(abs(title.height - 12) <= 0.75, "title ink height \(title.height) (dark \(dark))")
            #expect(abs(title.width - 54.5) <= 1.5, "title width \(title.width)")
            #expect(abs(title.midY - 26) <= 1, "title centre \(title.midY)")
            // The selected row's label is semibold; the others regular.
            let cell = try #require(wc.sidebar.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SettingsSidebarCellView)
            let other = try #require(wc.sidebar.view(atColumn: 0, row: 1, makeIfNecessary: true) as? SettingsSidebarCellView)
            let fm = NSFontManager.shared
            #expect(fm.weight(of: cell.label.font!) == fm.weight(of: .systemFont(ofSize: 13, weight: .semibold)))
            #expect(fm.weight(of: other.label.font!) == fm.weight(of: .systemFont(ofSize: 13)))
            w.close()
        }
    }

    // MARK: Shots

    @Test(.enabled(if: outDir != nil)) func shots() throws {
        let out = URL(fileURLWithPath: try #require(Self.outDir))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [false, true] {
            let t = TestDefaults("r5-shots-\(dark)")
            defer { t.remove() }
            let (wc, w) = try makeWindow(t, dark: dark)
            for page in ["General", "Appearance", "Editing", "Components", "Simulators"] {
                wc.show(page: page)
                if page == "Components" { wc.pane(ComponentsSettingsPane.self)?.now = { ComponentsPage.date("2026-11-07T10:00:00Z")! } }
                wc.pane(ComponentsSettingsPane.self)?.rebuild()
                r4.layout(w)
                let rep = try r4.render(w)
                try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("mac-r5-\(dark ? "dark" : "light")-\(page.lowercased()).png"))
            }
            w.close()
            // The runtime wizard's host step (parity §11), never on screen.
            var choices = RuntimeSetupChoices()
            choices.useHost = true
            choices.save(t.defaults)
            let session = RuntimeSetupSession(defaults: t.defaults)
            let rwc = RuntimeSetupWindowController(session: session)
            rwc.answerConfirmation = { _ in false }
            session.show(.host)
            let rw = try #require(rwc.window)
            rw.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            rwc.assistant.finishTransition()
            r4.layout(rw)
            let rep = try r4.render(rw)
            try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("mac-r5-\(dark ? "dark" : "light")-runtime-host.png"))
            rw.close()
        }
    }

    // MARK: Parity §11: the wizard's host form

    @Test func wizardHostFormFields() throws {
        let t = TestDefaults("r5-wizard")
        defer { t.remove() }
        _ = NSApplication.shared
        var choices = RuntimeSetupChoices()
        choices.useHost = true
        choices.save(t.defaults)
        let session = RuntimeSetupSession(defaults: t.defaults)
        let rwc = RuntimeSetupWindowController(session: session)
        rwc.answerConfirmation = { _ in false }
        session.show(.host)
        let rw = try #require(rwc.window)
        rwc.assistant.finishTransition()
        r4.layout(rw)
        // Fields 320 wide (Ports 120), 22 tall, in the drawn box; no Check Host.
        for (f, w) in [(rwc.hostField, 320.0), (rwc.dataField, 320.0), (rwc.linkField, 320.0), (rwc.portsField, 120.0)] {
            let box = try #require(f.superview as? SetupFieldBox)
            #expect(box.frame.width == w && box.frame.height == 22, "\(f.identifier?.rawValue ?? "") \(box.frame)")
            #expect(!f.isBordered && !f.drawsBackground)
        }
        func buttons(_ v: NSView) -> [String] { ((v as? NSButton).map { [$0.title] } ?? []) + v.subviews.flatMap(buttons) }
        let titles = buttons(try #require(rw.contentView))
        #expect(!titles.contains("Check Host") && titles.contains("Re-check") && titles.contains("Continue"), "\(titles)")
        rw.close()
    }
}
