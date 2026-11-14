import Foundation
import Testing
@testable import YcodeIDECore

/// Council round 7 in Settings (`specs/ide/settings.md` R7.1–R7.4, rows
/// 182–185): the Theme list's cards and rows, the colour tracks in light
/// and dark, the accessibility values and the thumbnails' close-up, as both
/// IDEs use them.
@Suite struct SettingsRound7Tests {
    func hx(_ c: ThemeColorRows.RGB) -> UInt32 {
        UInt32((c.r * 255).rounded()) << 16 | UInt32((c.g * 255).rounded()) << 8 | UInt32((c.b * 255).rounded())
    }

    func near(_ a: UInt32, _ b: UInt32, _ tol: Int) -> Bool {
        let d = [16, 8, 0].map { abs(Int((a >> UInt32($0)) & 0xFF) - Int((b >> UInt32($0)) & 0xFF)) }
        return d.allSatisfy { $0 <= tol }
    }

    // MARK: Row 182: the list

    @Test func cardsOrderAndHeights() {
        let cards = SettingsAppearanceR7.cards(customizeAllColors: false)
        #expect(cards.map { $0.map(\.title) } == [
            ["Foreground", "Background", "Background Gradient"], ["Customize All Colors"], ["Plain Text"],
            ["Comments", "Documentation Comments", "Keywords", "Strings", "Numbers", "Preprocessor Statements", "Attributes", "Type Names",
             "Selection", "Current Line"],
        ])
        #expect(cards[0].map(\.height) == [56, 56, 36.5] && cards[2][0].height == 47 && cards[3].allSatisfy { $0.height == 47 })
        #expect(cards[2][0].key == "identifier" && cards[0][1].key == "background")
        // With Customize All Colors on, every colour row has a slider.
        let all = SettingsAppearanceR7.cards(customizeAllColors: true)
        #expect(all.dropFirst(2).joined().allSatisfy { if case .slider = $0 { true } else { false } })
        // The reference's rows from card B at 391.5 (R7.1's table).
        let tops = Dictionary(uniqueKeysWithValues: SettingsAppearanceR7.rowTops(customizeAllColors: false).map { ($0.row.title, $0.top) })
        #expect(tops["Foreground"] == 391.5 && tops["Background"] == 448.5 && tops["Background Gradient"] == 505.5)
        #expect(tops["Customize All Colors"] == 552 && tops["Plain Text"] == 598.5)
        #expect(tops["Comments"] == 655.5 && tops["Documentation Comments"] == 703.5 && tops["Keywords"] == 751.5)
        #expect(SettingsAppearanceR7.colorButtonSize == CGSize(width: 48, height: 24) && SettingsAppearanceR7.sliderFrameHeight == 36)
    }

    @Test func switchesLiveInTheTheme() throws {
        var t = EditorTheme.builtIns[0]
        #expect(SettingsAppearanceR7.isOn(.backgroundGradient, in: t) && !SettingsAppearanceR7.isOn(.customizeAllColors, in: t))
        SettingsAppearanceR7.set(.customizeAllColors, true, in: &t)
        SettingsAppearanceR7.set(.backgroundGradient, false, in: &t)
        #expect(t.customizeAllColors == true && t.backgroundGradient == false)
        let back = try JSONDecoder().decode(EditorTheme.self, from: try JSONEncoder().encode(t))
        #expect(SettingsAppearanceR7.isOn(.customizeAllColors, in: back) && !SettingsAppearanceR7.isOn(.backgroundGradient, in: back))
        // The defaults are stored as absent.
        SettingsAppearanceR7.set(.customizeAllColors, false, in: &t)
        SettingsAppearanceR7.set(.backgroundGradient, true, in: &t)
        #expect(t.customizeAllColors == nil && t.backgroundGradient == nil)
    }

    // MARK: Row 183: the dark Foreground row

    @Test func darkForegroundTrack() {
        let t = EditorTheme.builtIns[0]
        // The default theme's text in dark: a light grey system colour.
        let d = ThemeColorRows.track("foreground", in: t, resolved: (0.9, 0.9, 0.9), dark: true)
        #expect(d.strength == 0.5 && hx(d.knobColor) == 0xFF9EC4)
        #expect(near(hx(d.low), 0xDCAAB9, 6), "muted end \(String(hx(d.low), radix: 16))")
        #expect(near(hx(d.high), 0xFFD4E7, 4), "pale end \(String(hx(d.high), radix: 16))")
        // Between: the reference's #E99EB9/#ED99B9 left of the knob, #FBA7C7–#FFC0D7 right of it.
        #expect(near(hx(d.color(at: 0.3)), 0xEBA2BF, 10) && near(hx(d.color(at: 0.75)), 0xFFB9D4, 10))
        // Light is round 6's track (met): pale tint → the full colour.
        let l = ThemeColorRows.track("foreground", in: t, resolved: (0.15, 0.15, 0.15), dark: false)
        let r6 = ThemeColorRows.display("foreground", in: t, resolved: (0.15, 0.15, 0.15))
        #expect(hx(l.high) == hx(r6.full) && hx(l.knobColor) == hx(ThemeColorRows.paleTint(r6.full, strength: 0.5)))
    }

    @Test func darkSliderRoundTripsThroughTheTheme() {
        var t = EditorTheme.builtIns[0]
        t.name = "Mine"
        let d = ThemeColorRows.track("keyword", in: t, resolved: (0.9, 0.9, 0.9), dark: true)
        for s in [0.2, 0.5, 0.8] {
            ThemeColorRows.setFromSlider("keyword", track: d, strength: s, in: &t)
            let c = ThemeColorRows.components(t.tokens["keyword"]!)!
            let again = ThemeColorRows.track("keyword", in: t, resolved: c, dark: true)
            #expect(again.strength == s && near(hx(again.knobColor), hx(d.color(at: s)), 1))
            #expect(near(hx(again.color(at: 0.5)), hx(d.color(at: 0.5)), 3), "mid at \(s)")
        }
    }

    // MARK: Row 182: the Background row

    @Test func backgroundTrack() {
        let t = EditorTheme.builtIns[0]
        let d = ThemeColorRows.track("background", in: t, resolved: (0.15, 0.15, 0.15), dark: true)
        // The knob at the left in the background colour; blue to the right.
        #expect(d.strength == 0 && hx(d.knobColor) == 0x484748 && hx(d.high) == 0x3B93CE)
        #expect(near(hx(d.color(at: 0.12)), 0x4A5A69, 8) && hx(d.color(at: 0.6)) == 0x5695C4)
        // Light: the editor's background at the knob.
        let l = ThemeColorRows.track("background", in: t, resolved: (1, 1, 1), dark: false)
        #expect(hx(l.knobColor) == 0xFFFFFF && l.strength == 0)
        // A user theme: the slider writes the colour under the knob and keeps the base.
        var mine = t
        mine.name = "Mine"
        ThemeColorRows.setFromSlider("background", track: d, strength: 0.3, in: &mine)
        let c = ThemeColorRows.components(mine.background!)!
        let again = ThemeColorRows.track("background", in: mine, resolved: c, dark: true)
        #expect(again.strength == 0.3 && near(hx(again.low), 0x484748, 2))
    }

    // MARK: Row 184: accessibility values

    @Test func accessibilityValues() {
        #expect(ThemeColorRows.accessibilityValue(ThemeColorRows.rgb(0xFF9EC4)) == "rgb 1 0.619608 0.768627 1")
        #expect(ThemeColorRows.accessibilityValue((0, 0.5, 1)) == "rgb 0 0.5 1 1")
        #expect(ThemeColorRows.percent(0.5) == "50%" && ThemeColorRows.percent(0.004) == "0%")
        #expect(abs(ThemeColorRows.stepped(0.5, up: true) - 0.55) < 1e-9 && ThemeColorRows.stepped(0.02, up: false) == 0)
    }

    // MARK: Row 185: the thumbnails' close-up

    @Test func thumbnailCloseUp() {
        let C = AppearanceThumbnailCloseUp.self
        #expect(C.buttonCenters(system: false).map(\.x) == [28, 38, 48] && C.buttonCenters(system: true).map(\.x) == [17, 27, 37])
        // The buttons at 59 % of the height, the window's top edge at 40 %.
        #expect(abs(C.buttonY / C.size.height - 0.59) < 0.01 && abs(C.windowTop / C.size.height - 0.40) < 0.01)
        #expect(C.buttonDiameter == 6 && C.buttonPitch == 10)
        #expect(C.window(system: false).minX == 17 && C.window(system: true).minX == 6)
        #expect(C.window(system: false).maxX > C.size.width && C.window(system: false).maxY > C.size.height)
        // The panel above the window, the bar along the top.
        #expect(C.panel.maxY < C.windowTop && C.panel.minX == 2 && C.panel.maxX == 39 && C.barHeight < C.panel.minY)
    }
}
