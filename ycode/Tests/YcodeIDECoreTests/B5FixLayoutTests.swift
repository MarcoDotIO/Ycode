import Foundation
import Testing
@testable import YcodeIDECore

/// B5-FIX-LAYOUT's shared values (council round 12,
/// `specs/ide/window-layout.md` §4.1, §4.2, §6): both IDEs read them.
@Suite struct B5FixLayoutTests {
    /// §4.1: the larger of the content floor and the toolbar's floor.
    @Test func minimumWidth() {
        #expect(NarrowWindowLayout.minimumWindowWidth(inspectorShown: true) == 503)
        #expect(NarrowWindowLayout.minimumWindowWidth(inspectorShown: false) == 410)
        #expect(abs(NarrowWindowLayout.contentFloor(inspectorShown: true) - 502.5) < 1e-9)
        #expect(NarrowWindowLayout.contentFloor(inspectorShown: false) == 300)
    }

    /// §4.2: the navigator collapses where the editor would go below 300:
    /// W ≈ 590 with the inspector hidden, ≈ 850 with it shown.
    @Test func collapsePoint() {
        #expect(abs(NarrowWindowLayout.navigatorCollapseWidth(inspector: nil) - 591) < 1e-9)
        #expect(abs(NarrowWindowLayout.navigatorCollapseWidth(inspector: 260) - 852) < 1e-9)
        let p = NarrowWindowLayout.panes(width: 590, navigator: 290, inspector: nil)
        #expect(p.navigator == nil && p.editor == 590)
        let q = NarrowWindowLayout.panes(width: 600, navigator: 290, inspector: nil)
        #expect(q.navigator == 290 && q.editor == 309)
        // Below the minimum the panes are the minimum's.
        let m = NarrowWindowLayout.panes(width: 300, navigator: 290, inspector: nil)
        #expect(m.navigator == nil && m.editor == 410)
    }

    /// §6.1, §6.2, §6.5: the navigator 240 ms ease-in-out for every
    /// trigger, starting within ≈ 80 ms of a key and ≈ 150 ms of a click;
    /// the debug area ≈ 250 ms linear; the swaps one frame.
    @Test func panelMotion() {
        for show in [false, true] {
            for t in [Motion.NavigatorTrigger.key, .click, .menu] {
                let c = Motion.navigator(show: show, trigger: t)
                #expect(abs(c.duration - 0.24) < 1e-9)
                #expect(c.start <= (t == .click ? 0.172 : 0.083))
                // Ease-in-out: slow at both ends.
                #expect(c.bezier.progress(0.1) < 0.1 && c.bezier.progress(0.9) > 0.9)
            }
        }
        #expect(Motion.navigator(show: true, trigger: .click).start >= 0.146)
        for show in [false, true] {
            let c = Motion.debugArea(show: show)
            #expect(c.bezier == .linear && c.duration >= 0.25 - 1e-9 && c.duration <= 0.27 + 1e-9 && c.start <= 0.08)
        }
        #expect(Motion.assistantPaneSwap == 0 && Motion.editorSplitAdded == 0)
    }
}
