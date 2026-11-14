import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 7, Settings (`specs/ide/settings.md` R7.1–R7.4, checklist
/// rows 182–185): the Theme list's cards, rows and controls below the first
/// screen, the dark Foreground row, the slider's accessibility element and
/// the thumbnails' close-up. Positions are window points from the top-left
/// with the list unscrolled (the window lays out off the displays at scale
/// 1, so half points round); colours are read from the window drawn at 2x.
/// Nothing is put on screen. With `YCODE_B7_SHOTS` set to a folder, the
/// pane is written there unscrolled and scrolled 360 points (X13), light
/// and dark, as `mac-r7-<appearance>-appearance[-scrolled].png`.
@MainActor
@Suite(.serialized) struct SettingsR7Tests {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["YCODE_B7_SHOTS"]
    let r5 = SettingsR5Tests()
    var r4: SettingsR4Tests { r5.r4 }

    func rect(_ v: NSView, in w: NSWindow) -> NSRect { r4.rect(v, in: w) }

    func capTop(_ l: NSTextField, in w: NSWindow) -> CGFloat {
        let r = rect(l, in: w)
        return r.minY + (r.height - l.baselineOffsetFromBottom) - (l.font?.capHeight ?? 0)
    }

    func hx(_ c: ThemeColorRows.RGB) -> UInt32 {
        UInt32((c.r * 255).rounded()) << 16 | UInt32((c.g * 255).rounded()) << 8 | UInt32((c.b * 255).rounded())
    }

    func pane(dark: Bool, _ name: String) throws -> (SettingsWindowController, NSWindow, ThemesSettingsPane, TestDefaults) {
        let t = TestDefaults("r7-\(name)")
        let (wc, w) = try r5.makeWindow(t, dark: dark)
        try r5.select(wc, w, "Appearance")
        return (wc, w, try #require(wc.pane(ThemesSettingsPane.self)), t)
    }

    func row(_ pane: ThemesSettingsPane, _ key: String) throws -> ThemeColorRowView {
        try #require(pane.colorRows.first { $0.key == key }?.view as? ThemeColorRowView)
    }

    /// Scrolls the list `y` points down.
    func scroll(_ pane: ThemesSettingsPane, _ w: NSWindow, to y: CGFloat) {
        guard let scroll = pane.formScroll else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        r4.layout(w)
    }

    // MARK: Row 182: cards, rows and controls

    @Test func listCardsRowsAndControls() throws {
        let (_, w, pane, t) = try pane(dark: true, "list")
        defer { t.remove(); w.close() }
        // The cards: A (Theme, Name), B, C, D, E from 391.5, 10 apart.
        let cards = pane.cards.map { rect($0, in: w) }
        #expect(cards.count >= 5)
        for (top, card) in zip([305, 391.5, 552, 598.5, 655.5] as [CGFloat], cards) {
            #expect(abs(card.minY - top) <= 0.5, "card \(card) against \(top)")
        }
        #expect(abs(cards[1].height - (56 + 1 + 56 + 1 + 36.5)) <= 0.5 && abs(cards[2].height - 36.5) <= 0.5 && abs(cards[3].height - 47) <= 0.5)
        // Every row against R7.1's table.
        for (r, top) in SettingsAppearanceR7.rowTops(customizeAllColors: false) {
            let view: NSView
            if let key = r.key { view = try row(pane, key) } else { view = try #require(pane.rowView(r.title)) }
            let vr = rect(view, in: w)
            #expect(abs(vr.minY - top) <= 0.75 && abs(vr.height - r.height) <= 0.5, "\(r.title) \(vr) against \(top)")
            let label = (view as? ThemeColorRowView)?.label ?? (view as? SettingsRowView)?.label
            if let label { #expect(abs(capTop(label, in: w) - vr.minY - 13) <= 1, "\(r.title) label") }
        }
        // Foreground and Background: sliders x 421.5–624 and 48 × 28 buttons.
        for key in ["foreground", "background"] {
            let v = try row(pane, key), vr = rect(v, in: w)
            #expect(v.style == .slider && v.slider.superview === v)
            let sr = rect(v.slider, in: w), br = rect(v.well, in: w)
            #expect(r5.near(sr, NSRect(x: 421.5, y: vr.midY - 18, width: 202.5, height: 36)), "\(key) slider \(sr)")
            #expect(r5.near(br, NSRect(x: 632, y: vr.midY - 14, width: 48, height: 28)), "\(key) button \(br)")
        }
        // The colour-only rows: a 48 × 24 button centred, 11.5 from the edges.
        for key in ["identifier", "comment", "docComment", "keyword"] {
            let v = try row(pane, key), vr = rect(v, in: w), br = rect(v.well, in: w)
            #expect(v.style == .colorOnly && v.slider.superview == nil)
            #expect(r5.near(br, NSRect(x: 632, y: vr.minY + 11.5, width: 48, height: 24)), "\(key) button \(br)")
        }
        // The switches: 36 × 16 at x 644–680; Background Gradient on, Customize All Colors off.
        let gradient = try #require(pane.control(NSSwitch.self, inRow: "Background Gradient"))
        let custom = try #require(pane.control(NSSwitch.self, inRow: "Customize All Colors"))
        #expect(gradient.state == .on && custom.state == .off)
        let gr = rect(gradient, in: w), gRow = rect(try #require(pane.rowView("Background Gradient")), in: w)
        // (Scale 1 rounds the row's 505.5 to 505: the switch 10.5 under its top.)
        #expect(abs(gr.maxX - 680) <= 0.5 && gr.width == 36 && gr.height == 16 && abs(gr.minY - gRow.minY - 10.5) <= 0.75, "switch \(gr) row \(gRow)")
        // Ycode's rows after Keywords; the note and the theme file last.
        let titles = pane.rowTitles
        #expect(Array(titles.drop { $0 != "Keywords" }.prefix(8)) == ["Keywords", "Strings", "Numbers", "Preprocessor Statements", "Attributes",
                                                                         "Type Names", "Selection", "Current Line"])
        #expect(titles.suffix(2) == ["# Theme File", "Duplicate"])
        // A built-in theme's switch is read-only, drawn in full.
        #expect(gradient.isEnabled && (gradient as? ClosureSwitch)?.readOnly == true)
        pane.toggle("Customize All Colors")
        #expect(pane.prefs.theme.customizeAllColors == nil && custom.state == .off)
    }

    @Test func customizeAllColorsGivesEveryRowASlider() throws {
        let (_, w, pane, t) = try pane(dark: false, "customize")
        defer { t.remove(); w.close() }
        pane.duplicateClicked()
        r4.layout(w)
        #expect(try row(pane, "keyword").style == .colorOnly)
        pane.toggle("Customize All Colors")
        r4.layout(w)
        #expect(pane.prefs.theme.customizeAllColors == true)
        let kw = try row(pane, "keyword")
        #expect(kw.style == .slider && abs(rect(kw, in: w).height - 56) <= 0.5)
        #expect(pane.colorRows.allSatisfy { ($0.view as? ThemeColorRowView)?.style == .slider })
        pane.toggle("Background Gradient")
        #expect(pane.prefs.theme.backgroundGradient == false)
    }

    // MARK: Row 183: the dark Foreground row

    @Test func darkForegroundColours() throws {
        let (_, w, pane, t) = try pane(dark: true, "dark-fg")
        defer { t.remove(); w.close() }
        let fg = try row(pane, "foreground")
        #expect(hx(fg.slider.track.knobColor) == 0xFF9EC4 && fg.slider.value == 0.5)
        let rep = try r4.render(w)
        let sr = rect(fg.slider, in: w), br = rect(fg.well, in: w), y = sr.midY
        // The track from a muted tone to a pale tint; the knob and the button #FF9EC4.
        let left = r4.hex(rep, sr.minX + 4, y), right = r4.hex(rep, sr.maxX - 4, y)
        #expect(r4.close(left, 0xDCAAB9, 12), "muted end \(String(left, radix: 16))")
        #expect(r4.close(right, 0xFFD4E7, 12), "pale end \(String(right, radix: 16))")
        #expect(r4.close(r4.hex(rep, sr.midX, y), 0xFF9EC4, 6), "knob \(String(r4.hex(rep, sr.midX, y), radix: 16))")
        #expect(r4.close(r4.hex(rep, br.midX, br.midY), 0xFF9EC4, 6), "button \(String(r4.hex(rep, br.midX, br.midY), radix: 16))")
        // Light is unchanged (round 6, met): the deep end at the right.
        w.appearance = NSAppearance(named: .aqua)
        r4.layout(w)
        #expect(hx(fg.slider.track.high) == 0xE35590)
    }

    @Test func darkBackgroundRow() throws {
        let (_, w, pane, t) = try pane(dark: true, "dark-bg")
        defer { t.remove(); w.close() }
        let bg = try row(pane, "background")
        #expect(bg.slider.value == 0 && hx(bg.slider.color) == 0x484748)
        // The row is below the window's bottom: scroll the list 120 points.
        scroll(pane, w, to: 120)
        let rep = try r4.render(w)
        let sr = rect(bg.slider, in: w), br = rect(bg.well, in: w), y = sr.midY
        // The knob at the left (centre about x 436) in the background colour, a white rim.
        #expect(r4.close(r4.hex(rep, sr.minX + 14, y), 0x484748, 6), "knob \(String(r4.hex(rep, sr.minX + 14, y), radix: 16)) slider \(sr) track \(bg.slider.track.stops.map { String(hx($0.color), radix: 16) })")
        #expect(r4.close(r4.hex(rep, sr.minX + 14, y - 12.5), 0xFFFFFF, 10), "knob rim")
        // To its right a blue gradient to #3B93CE.
        #expect(r4.close(r4.hex(rep, sr.maxX - 4, y), 0x3B93CE, 12), "blue end \(String(r4.hex(rep, sr.maxX - 4, y), radix: 16))")
        #expect(r4.close(r4.hex(rep, br.midX, br.midY), 0x484748, 6), "button \(String(r4.hex(rep, br.midX, br.midY), radix: 16))")
    }

    // MARK: Row 184: accessibility

    @Test func sliderAndButtonAccessibility() throws {
        let (_, w, pane, t) = try pane(dark: true, "ax")
        defer { t.remove(); w.close() }
        let fg = try row(pane, "foreground")
        // The slider's element: 202.5 × 36 at x 421.5, y 401.5, between the label and the button.
        #expect(r5.near(rect(fg.slider, in: w), NSRect(x: 421.5, y: 401.5, width: 202.5, height: 36)), "\(rect(fg.slider, in: w))")
        #expect(fg.slider.isAccessibilityElement() && fg.slider.accessibilityRole() == .slider)
        #expect(fg.slider.accessibilityLabel() == "Foreground")
        #expect((fg.slider.accessibilityValue() as? NSNumber)?.intValue == 50 && fg.slider.accessibilityValueDescription() == "50%")
        let order = [fg.label, fg.slider, fg.well].map { v in fg.subviews.firstIndex { $0 === v } ?? -1 }
        #expect(order == [0, 1, 2] && fg.well.isAccessibilityElement(), "order \(order)")
        // The colour control: a button whose value is the colour.
        #expect(fg.well.accessibilityRole() == .button && fg.well.accessibilityLabel() == "Foreground")
        #expect(fg.well.accessibilityValue() as? String == "rgb 1 0.619608 0.768627 1")
        let bg = try row(pane, "background")
        #expect(bg.slider.accessibilityRole() == .slider && bg.well.accessibilityValue() as? String == "rgb 0.282353 0.278431 0.282353 1")
        // The switches as switches.
        let gradient = try #require(pane.control(NSSwitch.self, inRow: "Background Gradient"))
        #expect(gradient.accessibilityRole() == .checkBox && gradient.accessibilitySubrole() == .switch)
        // Built-in: the slider does not move; a user theme's does, by 5 %.
        #expect(!fg.slider.accessibilityPerformIncrement() && fg.slider.value == 0.5)
        pane.duplicateClicked()
        r4.layout(w)
        let mine = try row(pane, "foreground")
        #expect(mine.slider.accessibilityPerformIncrement() && abs(mine.slider.value - 0.55) < 1e-9)
        #expect(pane.prefs.theme.strengths?["foreground"].map { abs($0 - 0.55) < 1e-9 } == true)
        #expect(mine.slider.accessibilityPerformDecrement() && abs(mine.slider.value - 0.5) < 1e-9)
    }

    // MARK: Row 185: the thumbnails

    @Test func thumbnailsAreACloseUp() throws {
        let (_, w, pane, t) = try pane(dark: false, "thumbs")
        defer { t.remove(); w.close() }
        let rep = try r4.render(w)
        let xs = SettingsAppearanceLayout.thumbnailXs, top = SettingsAppearanceLayout.thumbnailTop
        let C = AppearanceThumbnailCloseUp.self
        // Light: the three buttons at x 28, 38, 48 and 59 % down, 6 across.
        for (c, color) in zip(C.buttonCenters(system: false), C.buttonColors) {
            let p = r4.hex(rep, xs[1] + c.x, top + c.y)
            #expect(r4.close(p, color, 24), "button \(String(p, radix: 16)) at \(c)")
        }
        // The window's body below its title area: white; the wallpaper left of the window.
        #expect(r4.close(r4.hex(rep, xs[1] + 50, top + 42), 0xFFFFFF, 8))
        #expect(!r4.close(r4.hex(rep, xs[1] + 10, top + 30), 0xFFFFFF, 30), "wallpaper left of the window")
        // Dark: a near-black window under the buttons.
        #expect(r4.close(r4.hex(rep, xs[2] + 50, top + 42), AppearanceThumbnailArt.dark.window, 8))
        // System: its window further left (the first button at x 17).
        #expect(r4.close(r4.hex(rep, xs[0] + 17, top + C.buttonY), C.buttonColors[0], 24))
        _ = pane
    }

    // MARK: Shots

    @Test(.enabled(if: outDir != nil)) func shots() throws {
        let out = URL(fileURLWithPath: try #require(Self.outDir))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [false, true] {
            let (_, w, pane, t) = try pane(dark: dark, "shots-\(dark)")
            defer { t.remove(); w.close() }
            let name = "mac-r7-\(dark ? "dark" : "light")-appearance"
            try r4.render(w).representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
            // X13: the list scrolled 360 points.
            scroll(pane, w, to: 360)
            try r4.render(w).representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name)-scrolled.png"))
            // Further down: the rows after Keywords; then the theme file.
            scroll(pane, w, to: 450)
            try r4.render(w).representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name)-rows.png"))
            scroll(pane, w, to: 900)
            try r4.render(w).representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name)-end.png"))
        }
    }
}
