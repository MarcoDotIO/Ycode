import Foundation
import Testing
@testable import YcodeIDECore

/// Council round 6 in Settings (`specs/ide/settings.md` R6.1–R6.3, rows
/// 149–153): the shared numbers and the colour rows' hue and strength, as
/// both IDEs use them.
@Suite struct SettingsRound6Tests {
    @Test func rowMetrics() {
        #expect(SettingsRowMetrics.height(.popUp) == 37.25 && SettingsRowMetrics.height(.toggle) == 36.5)
        #expect(SettingsRowMetrics.labelCapTop == 13 && SettingsRowMetrics.helpCapGap == 17.5)
        // The reference's General card from 223: separators 260.5, 298.5, 337, 375.
        #expect(SettingsRowMetrics.snappedSeparatorTops(cardTop: 223, rows: Array(repeating: 37.25, count: 5)) == [260.5, 298.5, 337, 375])
        // A switch with a two-line description: 66 (a 13-point title, an 11-point description).
        let h = SettingsRowMetrics.describedRowHeight(lines: 2, titleCapHeight: 9.2, helpCapHeight: 7.8)
        #expect(abs(h - 66) <= 0.1, "\(h)")
        #expect(SettingsRowMetrics.helpBottom(.popUp) - SettingsRowMetrics.helpBottom(.toggle) == 3.5)
    }

    @Test func appearanceNumbers() {
        #expect(SettingsAppearanceR6.pushButtonRadius == 6 && SettingsAppearanceR6.themeRowRaise == 2.25)
        #expect(SettingsAppearanceLayout.sliderKnob == 28 && SettingsR5Palette.wellRim.light == 0xDFDFDF)
    }

    @Test func greyRowsTakeAHueAtHalfStrength() {
        let t = EditorTheme.builtIns[0]
        // The default theme's text: a grey system colour.
        let fg = ThemeColorRows.display("foreground", in: t, resolved: (0.15, 0.15, 0.15))
        #expect(ThemeColorRows.isChromatic(fg.full) && fg.strength == 0.5)
        #expect(ThemeColorRows.hex(fg.full.r, fg.full.g, fg.full.b) == "#E35590")
        // A system colour with a hue keeps it, at 50 %.
        let kw = ThemeColorRows.display("keyword", in: t, resolved: (0.6, 0.15, 0.55))
        #expect(kw.full.r == 0.6 && kw.full.g == 0.15 && kw.full.b == 0.55 && kw.strength == 0.5)
        // A theme's own colour with a hue: itself at full strength.
        let paper = EditorTheme.builtIns[1]
        let c = ThemeColorRows.components(paper.tokens["keyword"]!)!
        let own = ThemeColorRows.display("keyword", in: paper, resolved: c)
        #expect(own.strength == 1 && own.full.r == c.r && own.full.g == c.g && own.full.b == c.b)
    }

    @Test func paleTintAndStrengthRoundTrip() {
        let full = (r: 0.9, g: 0.33, b: 0.56)
        let pale = ThemeColorRows.paleTint(full, strength: 0)
        #expect(abs(pale.g - (1 + (0.33 - 1) * ThemeColorRows.paleStrength)) < 1e-9)
        let mid = ThemeColorRows.paleTint(full, strength: 0.5)
        let back = ThemeColorRows.fullColor(of: mid, strength: 0.5)
        #expect(abs(back.r - 0.9) < 1e-9 && abs(back.g - 0.33) < 1e-9 && abs(back.b - 0.56) < 1e-9)
        var t = EditorTheme.builtIns[0]
        ThemeColorRows.setStrength("string", full: full, strength: 0.25, in: &t)
        #expect(t.strengths?["string"] == 0.25 && t.tokens["string"] != nil)
        ThemeColorRows.setTyped("string", nil, in: &t)
        #expect(t.strengths == nil && t.tokens["string"] == nil)
    }

    @Test func componentsSubtitle() {
        func row(_ s: String) -> ComponentsRow {
            ComponentsRow(kind: .platform(.iOS), glyph: .iOS, title: "iOS 27.1", subtitle: s, lastUsed: nil, details: [])
        }
        #expect(row("15.94 GB").subtitleInset == 3.25 && row("Built-in").subtitleInset == 0 && row("Not installed").subtitleInset == 0)
        #expect(SettingsComponentsR6.lastUsedFontSize == SettingsComponentsLayout.subtitleFontSize)
    }
}
