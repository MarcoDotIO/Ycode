import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 6, Settings (`specs/ide/settings.md` R6.1–R6.3, checklist
/// rows 149–153): the Foreground row's hue, knob and well; Choose…'s
/// corner radius; the Theme row's raised content; Components' size
/// subtitle and "Last used"; content-sized card rows. Positions are window
/// points from the top-left (the window lays out off the displays at
/// scale 1, so half points round); colours are read from the window drawn
/// at 2x. Nothing is put on screen.
@MainActor
@Suite(.serialized) struct SettingsR6Tests {
    let r5 = SettingsR5Tests()
    var r4: SettingsR4Tests { r5.r4 }

    func rect(_ v: NSView, in w: NSWindow) -> NSRect { r4.rect(v, in: w) }

    /// A label's cap top in window points.
    func capTop(_ l: NSTextField, in w: NSWindow) -> CGFloat {
        let r = rect(l, in: w)
        return r.minY + (r.height - l.baselineOffsetFromBottom) - (l.font?.capHeight ?? 0)
    }

    // MARK: Rows 149–151: Appearance

    @Test func themeRowRaisedAndChooseIsARoundedRectangle() throws {
        let t = TestDefaults("r6-theme-row")
        defer { t.remove() }
        let (wc, w) = try r5.makeWindow(t)
        try r5.select(wc, w, "Appearance")
        let pane = try #require(wc.pane(ThemesSettingsPane.self))
        let theme = try #require(pane.cards[0].rowViews.first as? SettingsPlainRow)
        let row = rect(theme, in: w), cr = rect(theme.control, in: w)
        #expect(abs(row.minY - 305) <= 0.5 && abs(row.height - 39.5) <= 0.5, "theme row \(row)")
        // The button 5.5 under the card's top (310.5–334.5), the label's cap top 317.5.
        #expect(abs(cr.minY - 310.5) <= 0.75 && cr.height == 24, "Choose… \(cr)")
        #expect(abs(capTop(theme.label, in: w) - 317.5) <= 1, "label cap top \(capTop(theme.label, in: w))")
        // The Name row is unchanged: its label centred (cap top 359).
        let name = try #require(pane.cards[0].rowViews.last as? SettingsPlainRow)
        #expect(abs(capTop(name.label, in: w) - 359) <= 1, "name cap top \(capTop(name.label, in: w))")
        // Radius 6: 0.75 under the top edge the fill reaches 3.1 from the
        // end; a capsule's (radius 12) would start 7.8 in.
        #expect(SettingsAppearanceR6.pushButtonRadius == 6)
        let rep = try r4.render(w)
        let fill = SettingsR5Palette.pushButton.light, card = SettingsPaletteHex.card.light
        #expect(r4.close(r4.hex(rep, cr.minX + 5, cr.minY + 0.75), fill, 10), "near the corner \(String(r4.hex(rep, cr.minX + 5, cr.minY + 0.75), radix: 16))")
        #expect(r4.close(r4.hex(rep, cr.minX + 0.25, cr.minY + 0.25), card, 6), "outside the corner")
        #expect(r4.close(r4.hex(rep, cr.midX, cr.minY + 0.25), fill, 10), "top edge")
        w.close()
    }

    @Test func foregroundRowHueKnobAndWell() throws {
        let t = TestDefaults("r6-foreground")
        defer { t.remove() }
        let (wc, w) = try r5.makeWindow(t)
        try r5.select(wc, w, "Appearance")
        let pane = try #require(wc.pane(ThemesSettingsPane.self))
        let fg = try #require(pane.colorRows.first?.view as? ThemeColorRowView)
        // The default theme's text colour is grey: Ycode's hue for the row,
        // at 50 %; never grey.
        #expect(fg.key == "foreground" && ThemeColorRows.isChromatic(fg.slider.base) && fg.slider.value == 0.5)
        let fr = rect(fg, in: w), sr = rect(fg.slider, in: w), wr = rect(fg.well, in: w)
        #expect(abs(sr.minX - 421.5) <= 0.5 && abs(sr.maxX - 624) <= 0.5, "track \(sr)")
        #expect(abs(wr.width - 48) <= 0.5 && abs(wr.height - 28) <= 0.5 && abs(wr.maxX - 680) <= 0.5, "well \(wr)")
        #expect(SettingsAppearanceLayout.sliderKnob == 28)
        let rep = try r4.render(w)
        func hx(_ c: ThemeColorRows.RGB) -> UInt32 {
            UInt32((c.r * 255).rounded()) << 16 | UInt32((c.g * 255).rounded()) << 8 | UInt32((c.b * 255).rounded())
        }
        let full = fg.slider.base, knob = ThemeColorRows.paleTint(full, strength: 0.5), pale = ThemeColorRows.paleTint(full, strength: 0)
        // The track: pale at the left, the full colour at the right (inside its edge).
        let y = fr.midY
        let left = r4.hex(rep, sr.minX + 4, y), right = r4.hex(rep, sr.maxX - 4, y)
        #expect(r4.close(left, hx(pale), 12), "pale end \(String(left, radix: 16)) against \(String(hx(pale), radix: 16))")
        #expect(r4.close(right, hx(full), 12), "full end \(String(right, radix: 16)) against \(String(hx(full), radix: 16))")
        // The darker edge along the track's top at its right end.
        let edge = r4.hex(rep, sr.maxX - 12, y - 7 + 0.25)
        #expect(r4.close(edge, hx(ThemeColorRows.darker(ThemeColorRows.paleTint(full, strength: 0.94), SettingsAppearanceR6.trackEdgeFactor)), 20),
                "edge \(String(edge, radix: 16))")
        // The knob at the middle (x 522.75), its colour the 50 % tint, a white rim.
        let kx = sr.minX + sr.width / 2
        #expect(r4.close(r4.hex(rep, kx, y), hx(knob), 8), "knob \(String(r4.hex(rep, kx, y), radix: 16))")
        #expect(r4.close(r4.hex(rep, kx, y - 12.5), 0xFFFFFF, 8), "knob rim \(String(r4.hex(rep, kx, y - 12.5), radix: 16))")
        // The well: a #DFDFDF rim 3 wide, the knob's colour inside, drawn in
        // full although the built-in theme is read-only.
        #expect(!fg.well.isEnabled)
        #expect(r4.close(r4.hex(rep, wr.midX, wr.minY + 1), 0xDFDFDF, 6), "well rim \(String(r4.hex(rep, wr.midX, wr.minY + 1), radix: 16))")
        #expect(r4.close(r4.hex(rep, wr.midX, wr.midY), hx(knob), 8), "well colour \(String(r4.hex(rep, wr.midX, wr.midY), radix: 16))")
        let inner = r4.hex(rep, wr.midX, wr.minY + 3.25)
        #expect(r4.close(inner, hx(ThemeColorRows.darker(knob, SettingsAppearanceR6.wellEdgeFactor)), 14), "well edge \(String(inner, radix: 16))")
        w.close()
    }

    @Test func strengthRoundTripsThroughTheThemeFile() throws {
        var t = EditorTheme.builtIns[0]
        t.name = "Mine"
        let full = (r: 0.9, g: 0.33, b: 0.56)
        ThemeColorRows.setStrength("keyword", full: full, strength: 0.3, in: &t)
        let hex = try #require(t.tokens["keyword"])
        let c = try #require(ThemeColorRows.components(hex))
        let shown = ThemeColorRows.display("keyword", in: t, resolved: c)
        #expect(abs(shown.strength - 0.3) < 1e-9 && abs(shown.full.r - 0.9) < 0.01 && abs(shown.full.g - 0.33) < 0.01)
        let data = try JSONEncoder().encode(t)
        #expect(try JSONDecoder().decode(EditorTheme.self, from: data).strengths?["keyword"] == 0.3)
        ThemeColorRows.setTyped("keyword", "#3366CC", in: &t)
        #expect(t.strengths == nil && ThemeColorRows.display("keyword", in: t, resolved: (0.2, 0.4, 0.8)).strength == 1)
        // A theme file without strengths still reads.
        let old = #"{"name":"Old","fontName":"","fontSize":13,"tokens":{},"consoleFontName":"","consoleFontSize":11}"#
        #expect(try JSONDecoder().decode(EditorTheme.self, from: Data(old.utf8)).strengths == nil)
    }

    // MARK: Row 152: Components

    @Test func componentsSizeSubtitleInsetAndLastUsedSize() throws {
        let t = TestDefaults("r6-components")
        defer { t.remove() }
        let (wc, w) = try r5.makeWindow(t)
        try r5.select(wc, w, "Components")
        let pane = try #require(wc.pane(ComponentsSettingsPane.self))
        pane.now = { ComponentsPage.date("2026-11-07T10:00:00Z")! }
        pane.rebuild()
        r4.layout(w)
        let mac = pane.rowViews[0], ios = pane.rowViews[1]
        #expect(!mac.row.subtitleIsSize && ios.row.subtitleIsSize)
        // "Built-in" aligned with the title; a size 3.25 right of it.
        #expect(abs(rect(mac.subtitle, in: w).minX - rect(mac.title, in: w).minX) <= 0.01)
        let d = rect(ios.subtitle, in: w).minX - rect(ios.title, in: w).minX
        #expect(abs(d - 3.25) <= 0.75, "size inset \(d)")
        // "Last used" at the subtitle's size, ending at 655.
        let lu = try #require(ios.lastUsed)
        #expect(lu.font?.pointSize == SettingsComponentsLayout.subtitleFontSize)
        #expect(abs(rect(lu, in: w).maxX - 3 - 655.5) <= 1)
        w.close()
    }

    // MARK: Row 153: row heights

    @Test func rowsAreContentSized() throws {
        let t = TestDefaults("r6-rows")
        defer { t.remove() }
        let (wc, w) = try r5.makeWindow(t)
        try r5.select(wc, w, "General")
        let general = try #require(wc.pane(GeneralSettingsPane.self))
        r4.layout(w)
        let card = general.cards[1], cr = rect(card, in: w)
        #expect(abs(cr.minY - 223) <= 1, "card \(cr)")
        let rows = card.rowViews.compactMap { $0 as? SettingsRowView }
        // Four pop-up rows of 37.25 + 1: the fourth separator at 375.
        for r in rows.prefix(4) {
            #expect(r.rowKind == .popUp && abs(rect(r, in: w).height - 37.25) <= 0.75, "\(r.label.stringValue) \(rect(r, in: w))")
            // The label's cap top 13 under the row's top.
            #expect(abs(capTop(r.label, in: w) - rect(r, in: w).minY - 13) <= 1, "\(r.label.stringValue) label")
        }
        #expect(abs(rect(rows[3], in: w).maxY - 375) <= 1, "fourth row ends \(rect(rows[3], in: w).maxY)")
        // The switch with a two-line description: 66 tall, its description's
        // cap top 17.5 under the title's.
        let sw = rows[4], sr = rect(sw, in: w)
        let help = try #require(sw.help)
        #expect(sw.rowKind == .toggle && abs(sr.height - 66) <= 1, "described switch \(sr)")
        // The first line's cap top (a wrapping field's first baseline).
        let helpCap = rect(help, in: w).minY + help.firstBaselineOffsetFromTop - NSFont.systemFont(ofSize: SettingsMetrics.helpFontSize).capHeight
        #expect(abs(helpCap - capTop(sw.label, in: w) - 17.5) <= 1, "description \(helpCap - capTop(sw.label, in: w))")
        #expect(abs(capTop(sw.label, in: w) - sr.minY - 13) <= 1)
        // Switch rows without a description: 36.5.
        for r in rows.dropFirst(5) where r.help == nil && r.rowKind == .toggle {
            #expect(abs(rect(r, in: w).height - 36.5) <= 0.75, "\(r.label.stringValue) \(rect(r, in: w))")
        }
        // Editing: a pop-up row then a switch row (37.25 + 1 + 36.5).
        try r5.select(wc, w, "Editing")
        let editing = try #require(wc.pane(TextEditingSettingsPane.self))
        r4.layout(w)
        let single = rect(editing.cards[1], in: w), pair = rect(editing.cards[2], in: w)
        #expect(abs(single.height - 37.25) <= 0.75, "single \(single)")
        #expect(abs(pair.height - (37.25 + 1 + 36.5)) <= 1, "pair \(pair)")
        w.close()
    }

    @Test func rowMetrics() {
        #expect(SettingsRowMetrics.height(.popUp) == 37.25 && SettingsRowMetrics.height(.toggle) == 36.5)
        // The reference's General card from 223: separators 260.5, 298.5, 337, 375.
        #expect(SettingsRowMetrics.snappedSeparatorTops(cardTop: 223, rows: Array(repeating: 37.25, count: 5)) == [260.5, 298.5, 337, 375])
        let h = SettingsRowMetrics.describedRowHeight(lines: 2, titleCapHeight: 9.2, helpCapHeight: 7.8)
        #expect(abs(h - 66) <= 0.1, "\(h)")
    }
}
