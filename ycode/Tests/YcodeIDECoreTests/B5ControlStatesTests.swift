import Foundation
import Testing
import YcodeIDECore

/// B5-STATES (P-198, #58, #64): the control-state model and the glass and
/// scroll-edge values both IDEs draw from (`specs/ui/control-states.md`,
/// `specs/ui/glass-materials.md`). Runs on macOS and Linux.
@Suite struct B5ControlStatesTests {
    @Test func hoverOnlyWhereTheReferenceHasIt() {
        // §1 rule 2: toolbar glass, Settings pop-ups and editor tabs.
        let hover = Set(ControlStates.hoverKinds)
        #expect(hover == [.toolbarSegment, .toolbarSelectedSegment, .toolbarCircle, .toolbarChooserHalf, .issueCapsule,
                          .settingsPopUp, .editorTab, .editorTabClose])
        for kind in [ControlKind.navigatorTab, .inspectorTab, .segment, .sheetDefaultButton, .sheetCancelButton, .settingsSwitch,
                     .settingsSidebarRow, .filterToggle, .filterOptions, .bottomBarGlyph, .disclosure, .targetTab, .jumpBarSegment] {
            for dark in [true, false] {
                let s = ControlStates.style(kind, dark: dark)
                #expect(!s.hasHover, "\(kind)")
                #expect(s.resolve(hovered: true, pressed: false, enabled: true) == .rest, "\(kind)")
                #expect(s.fill(.hover) == s.fill(.rest), "\(kind)")
            }
        }
    }

    @Test func hoverIsOneFrameExceptTheTabClose() {
        #expect(ControlStates.hoverDuration == 0)
        for kind in ControlKind.allCases where kind != .editorTabClose {
            #expect(ControlStates.style(kind, dark: true).hoverFadeOut == 0, "\(kind)")
        }
        #expect(ControlStates.style(.editorTabClose, dark: true).hoverFadeOut == 0.15)
        #expect(EditorTabStates.closeBezelOpacity(afterLeave: 0) == 1)
        #expect(abs(EditorTabStates.closeBezelOpacity(afterLeave: 0.075) - 0.5) < 1e-9)
        #expect(EditorTabStates.closeBezelOpacity(afterLeave: 0.2) == 0)
    }

    @Test func measuredToolbarValues() {
        let run = ControlStates.style(.toolbarSegment, dark: true)
        #expect(run.restFill == StateColor(0x444446) && run.hoverFill == StateColor(0x58585A) && run.pressedFill == StateColor(0x6E6E71))
        #expect(ControlStates.style(.toolbarSegment, dark: false).hoverFill == StateColor(0xE7E7E7))
        #expect(run.hoverBezel == .init(width: 34, height: 28))
        let half = ControlStates.style(.toolbarChooserHalf, dark: false)
        #expect(half.restFill == StateColor(0xFAFAFA) && half.hoverFill == StateColor(0xEDEDED) && half.trigger == .mouseDown)
        // Grow 1–2 points per side, never the first pass's 4–6.
        for kind in [ControlKind.toolbarSegment, .toolbarSelectedSegment, .toolbarCircle] {
            let g = ControlStates.style(kind, dark: true).grow
            #expect(g >= 1 && g <= 2, "\(kind)")
        }
        #expect(abs(ControlStates.pressedScale(size: 36, grow: 1.5) - 39.0 / 36) < 1e-9)
        #expect(ControlStates.disabledToolbarGlyph(dark: true) == StateColor(0x7A7A7B))
        #expect(ControlStates.disabledToolbarGlyph(dark: false) == StateColor(0xA5A6A7))
    }

    @Test func pressTimingFitsTheMeasuredWindow() {
        // 90 % at 100–145 ms; settled 120–320 ms after release.
        let t90 = stride(from: 0.0, through: 0.3, by: 0.001).first { ControlStates.pressProgress(elapsed: $0) >= 0.9 }!
        #expect(t90 >= 0.06 && t90 <= 0.145)
        #expect(ControlStates.pressProgress(elapsed: 0) == 0)
        #expect(ControlStates.pressProgress(elapsed: 1) == 1)
        #expect(ControlStates.settle >= 0.12 && ControlStates.settle <= 0.32)
        #expect(ControlStates.settleProgress(elapsed: 0) == 1)
        #expect(ControlStates.settleProgress(elapsed: ControlStates.settle) == 0)
        #expect(ControlStates.flatPress == 0)
    }

    @Test func flatControls() {
        let seg = ControlStates.style(.segment, dark: true)
        #expect(seg.pressedFill == StateColor(0xA0A0A0) && seg.grow == 0)
        #expect(seg.label(.pressed) == StateColor(0xC4C4C4) && seg.label(.rest) == StateColor(0xE8E8E8))
        #expect(ControlStates.style(.segment, dark: false).pressedFill == StateColor(0x787878))
        // The default button lightens in dark and darkens in light.
        let ok = ControlStates.style(.sheetDefaultButton, dark: true), okLight = ControlStates.style(.sheetDefaultButton, dark: false)
        #expect(ok.restFill == StateColor(0x0078FE) && okLight.restFill == StateColor(0x0078FE))
        #expect(ok.pressedFill!.blue > ok.restFill!.blue || ok.pressedFill!.red > ok.restFill!.red)
        #expect(okLight.pressedFill!.blue < okLight.restFill!.blue)
        #expect(ControlStates.style(.sheetCancelButton, dark: false).pressedFill == StateColor(0xD3D3D3))
        #expect(ControlStates.style(.targetTab, dark: true).pressedFill == nil)
        let glyph = ControlStates.style(.bottomBarGlyph, dark: true)
        #expect(glyph.label(.pressed)!.red > glyph.label(.rest)!.red)
        let glyphLight = ControlStates.style(.bottomBarGlyph, dark: false)
        #expect(glyphLight.label(.pressed)!.red < glyphLight.label(.rest)!.red)
    }

    @Test func triggers() {
        for kind in [ControlKind.toolbarChooserHalf, .settingsPopUp, .settingsSidebarRow, .filterOptions] {
            #expect(ControlStates.style(kind, dark: true).trigger == .mouseDown, "\(kind)")
        }
        #expect(ControlStates.style(.navigatorTab, dark: true).trigger == .release)
        #expect(ControlStates.style(.inspectorTab, dark: true).trigger == .release)
        #expect(ControlStates.style(.sheetDefaultButton, dark: true).trigger == .mouseUp)
    }

    @Test func disabledHasNoHoverOrPress() {
        for kind in ControlKind.allCases {
            let s = ControlStates.style(kind, dark: false)
            #expect(s.resolve(hovered: true, pressed: true, enabled: false) == .disabled)
            #expect(s.fill(.disabled) == s.restFill)
        }
    }

    @Test func noFocusRingsWithoutFullKeyboardAccess() {
        #expect(!ControlStates.showsFocusRing(fullKeyboardAccess: false))
        #expect(ControlStates.showsFocusRing(fullKeyboardAccess: true))
        #expect(ControlStates.fieldCaret(dark: true) == StateColor(0x2360A5))
    }

    @Test func lensFollowsThePointerAndSelectsOnRelease() {
        var lens = GlassTabLens(bar: .navigator, tabCount: 9, selected: 0)
        #expect(!lens.isHeld && lens.lensSize == (42, 42))
        lens.press(2)
        #expect(lens.isHeld && lens.origin == 0 && lens.lensTab == 2)
        // The selection does not change while held.
        #expect(lens.selected == 0)
        lens.drag(3)
        lens.drag(4)
        lens.drag(nil)   // off the bar: stays on the last tab crossed
        #expect(lens.lensTab == 4)
        #expect(lens.release() == 4)
        #expect(lens.selected == 4 && !lens.isHeld && lens.origin == nil)
        #expect(lens.release() == nil)
        let inspector = GlassTabLens(bar: .inspector, tabCount: 3, selected: 1)
        #expect(inspector.lensSize == (98, 40))
        #expect(inspector.tint(dark: true, held: true) == StateColor(0x49494B))
        #expect(GlassTabLens.tab(atX: 85, leading: 3, tabWidth: 82, count: 3) == 1)
        #expect(GlassTabLens.tab(atX: 1, leading: 3, tabWidth: 82, count: 3) == nil)
        #expect(GlassTabLens.tab(atX: 300, leading: 3, tabWidth: 82, count: 3) == nil)
    }

    @Test func noProgressiveScrollEdge() {
        #expect(!GlassMaterials.workspaceHasProgressiveScrollEdge)
        #expect(GlassMaterials.jumpBarDividerHeight == EditorMetrics.jumpBarSeparator)
        let dark = GlassMaterials.jumpBarDivider(dark: true)
        #expect(dark.top == StateColor(0x3D3D3C) && dark.bottom == StateColor(0x363636))
        #expect(GlassMaterials.jumpBarDivider(dark: false).bottom == StateColor(0xE5E5E5))
        #expect(GlassMaterials.stickySeparator(dark: true).top == StateColor(0x3C3A3C))
        // The band at y 85 under a band ending at 84: it covers the
        // divider's second row.
        #expect(GlassMaterials.stickyBandTop(belowJumpBarBand: 84) == 85)
        #expect(GlassMaterials.stickyBandHeight == EditorMetrics.stickyHeaderHeight(rows: 1, lineHeight: 18))
    }

    @Test func stickyLineOfTheEnclosingDeclaration() {
        let text = (1...40).map { $0 == 21 ? "struct Box0<Value>: Sendable {" : $0 == 40 ? "}" : "    let v\($0) = \($0)" }
        let regions = [FoldRegion(startLine: 21, endLine: 40, depth: 0)]
        func lines(top: Int) -> [Int] {
            GlassMaterials.stickyLines(regions: regions, firstVisibleLine: { top + Int($0 / 18) }, lineHeight: 18) { text[$0 - 1] }
        }
        #expect(lines(top: 10).isEmpty)
        #expect(lines(top: 21).isEmpty)   // the declaration's own line shows
        #expect(lines(top: 25) == [21])
    }

    @Test func partBRolesAndMaterials() {
        #expect(GlassMaterials.material(for: .contentArea) == .opaque)
        #expect(GlassMaterials.material(for: .decision) == .opaqueSheet)
        #expect(GlassMaterials.radius(.paletteGlass, height: 55) == 27.5)
        #expect(GlassMaterials.radius(.popover, height: 200) == 17)
        #expect(!GlassMaterials.workspaceStaysActive(behind: .decision))
        #expect(GlassMaterials.workspaceStaysActive(behind: .chooser))
        #expect(!GlassMaterials.usesGlass(reduceTransparency: true, increaseContrast: false))
        #expect(GlassMaterials.usesGlass(reduceTransparency: false, increaseContrast: false))
    }
}
