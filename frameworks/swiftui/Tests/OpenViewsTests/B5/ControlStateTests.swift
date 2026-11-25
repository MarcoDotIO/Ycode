import Foundation
import OVPlatform
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// B5-STATES (Ycode's `specs/ui/control-states.md`): desktop hover, press
// and focus. Plain buttons keep their look while held; push buttons tint;
// no focus rings without Full Keyboard Access; menus open on mouse-down;
// `StatefulButtonStyle` sees hover only while enabled.

@MainActor
@Suite("B5 control states")
struct ControlStateTests {
    /// Records `entry` when a look is built (inside a view builder).
    static func logged(_ log: EventLog, _ entry: String) -> EmptyView {
        log.add(entry)
        return EmptyView()
    }

    @Test func plainButtonIsNotHalfTransparentWhileHeldOnTheDesktop() {
        #expect(DesktopControlStates.plainOpacity(pressed: true, enabled: true, desktop: true) == 1)
        #expect(DesktopControlStates.plainOpacity(pressed: true, enabled: true, desktop: false) == 0.5)
        // Dimmed once when disabled.
        #expect(DesktopControlStates.plainOpacity(pressed: false, enabled: false, desktop: true) == 0.4)
        #expect(DesktopControlStates.plainOpacity(pressed: true, enabled: false, desktop: true) == 0.4)
    }

    @Test func focusRingsOnlyWithFullKeyboardAccessOnTheDesktop() {
        #expect(!DesktopControlStates.showsFocusRing(focused: true, desktop: true, fullKeyboardAccess: false))
        #expect(DesktopControlStates.showsFocusRing(focused: true, desktop: true, fullKeyboardAccess: true))
        #expect(DesktopControlStates.showsFocusRing(focused: true, desktop: false, fullKeyboardAccess: false))
        #expect(!DesktopControlStates.showsFocusRing(focused: false, desktop: false, fullKeyboardAccess: true))
    }

    @Test func pushButtonTintsInsteadOfFading() {
        // Lighter in dark, darker in light, one frame.
        let light = DesktopControlStates.pressedOverlay(dark: false, prominent: true)
        let dark = DesktopControlStates.pressedOverlay(dark: true, prominent: true)
        #expect(light == Color.black.opacity(0.1))
        #expect(dark == Color.white.opacity(0.14))
        #expect(DesktopControlStates.pressedOverlay(dark: true, prominent: false) == Color.white.opacity(0.1))
    }

    @Test func desktopMenuOpensOnMouseDown() {
        #expect(DesktopControlStates.menuTrigger(desktop: true, hasPrimaryAction: false) == .mouseDown)
        #expect(DesktopControlStates.menuTrigger(desktop: true, hasPrimaryAction: true) == .mouseUp)
        #expect(DesktopControlStates.menuTrigger(desktop: false, hasPrimaryAction: false) == .mouseUp)
        let h = Harness(size: CGSize(width: 300, height: 300)) {
            Menu("Actions") { Button("One") {} }
                .environment(\._desktopChrome, true)
                .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        guard let m = h.frame(where: { $0 is Menu<Text, Button<Text>> }) else { Issue.record("menu"); return }
        h.pointer(.down, m.center, at: 1.0, kind: .mouse)
        h.run(until: 1.1)
        // Open while the button is still down.
        #expect(h.host.windows.contains { $0.isPopup } || !h.window.overlayPopups.isEmpty)
        h.pointer(.up, m.center, at: 1.2, kind: .mouse)
        h.run(until: 1.3)
        // The release does not close it again.
        #expect(h.host.windows.contains { $0.isPopup } || !h.window.overlayPopups.isEmpty)
    }

    @Test func statefulStyleSeesHoverPressAndActsOnRelease() {
        let log = EventLog()
        let h = Harness(size: CGSize(width: 300, height: 200)) {
            Button("Go") { log.add("action") }
                .buttonStyle(StatefulButtonStyle { label, s in
                    ZStack {
                        Self.logged(log, "h\(s.isHovered ? 1 : 0) p\(s.isPressed ? 1 : 0)")
                        label.padding(8)
                    }
                })
                .environment(\._desktopChrome, true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        guard let b = h.frame(where: { $0 is Button<Text> }) else { Issue.record("button"); return }
        log.clear()
        h.hover(b.center, at: 1.0)
        h.run(until: 1.1)
        #expect(log.entries.last == "h1 p0")
        h.hover(CGPoint(x: 2, y: 2), at: 1.2)
        h.run(until: 1.3)
        #expect(log.entries.last == "h0 p0")
        h.pointer(.down, b.center, at: 1.4, kind: .mouse)
        h.run(until: 1.5)
        #expect(log.entries.last?.hasSuffix("p1") == true)
        #expect(!log.contains("action"))
        h.pointer(.up, b.center, at: 1.6, kind: .mouse)
        h.run(until: 1.7)
        #expect(log.contains("action"))
    }

    @Test func statefulStyleOnMouseDownActsAtThePress() {
        let log = EventLog()
        let h = Harness(size: CGSize(width: 300, height: 200)) {
            Button("Row") { log.add("action") }
                .buttonStyle(StatefulButtonStyle(trigger: .mouseDown, tracksHover: false) { label, s in
                    ZStack {
                        Self.logged(log, "h\(s.isHovered ? 1 : 0)")
                        label.padding(8)
                    }
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        guard let b = h.frame(where: { $0 is Button<Text> }) else { Issue.record("button"); return }
        h.hover(b.center, at: 1.0)
        h.run(until: 1.1)
        #expect(!log.contains("h1"))
        h.pointer(.down, b.center, at: 1.2, kind: .mouse)
        h.run(until: 1.3)
        #expect(log.count("action") == 1)
        h.pointer(.up, b.center, at: 1.4, kind: .mouse)
        h.run(until: 1.5)
        #expect(log.count("action") == 1)
    }

    /// B5-FOLLOWUP (Ycode's Run button): `.menuStyle(.button)` under a
    /// `.buttonStyle(…)` draws the menu's button with that style, as in
    /// SwiftUI, so a menu with a primary action gets the style's hover and
    /// held look; a click still runs the primary action.
    @Test func buttonStyledMenuTakesTheStyleAndKeepsItsPrimaryAction() {
        let log = EventLog()
        let h = Harness(size: CGSize(width: 300, height: 200)) {
            Menu {
                Button("Test") {}
            } label: {
                Text("Run")
            } primaryAction: {
                log.add("run")
            }
            .menuStyle(.button)
            .buttonStyle(StatefulButtonStyle { label, s in
                ZStack {
                    Self.logged(log, "h\(s.isHovered ? 1 : 0) p\(s.isPressed ? 1 : 0)")
                    label.padding(8)
                }
            })
            .environment(\._desktopChrome, true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        guard let m = h.frame(where: { $0 is Menu<Text, Button<Text>> }) else { Issue.record("menu"); return }
        log.clear()
        h.hover(m.center, at: 1.0)
        h.run(until: 1.1)
        #expect(log.entries.last == "h1 p0")
        h.pointer(.down, m.center, at: 1.2, kind: .mouse)
        h.run(until: 1.3)
        #expect(log.entries.last?.hasSuffix("p1") == true)
        h.pointer(.up, m.center, at: 1.4, kind: .mouse)
        h.run(until: 1.5)
        #expect(log.count("run") == 1)
    }

    @Test func disabledStatefulControlHasNoHover() {
        let log = EventLog()
        let h = Harness(size: CGSize(width: 300, height: 200)) {
            Button("Off") { log.add("action") }
                .buttonStyle(StatefulButtonStyle { label, s in
                    ZStack {
                        Self.logged(log, "h\(s.isHovered ? 1 : 0) e\(s.isEnabled ? 1 : 0)")
                        label.padding(8)
                    }
                })
                .disabled(true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        guard let b = h.frame(where: { $0 is Button<Text> }) else { Issue.record("button"); return }
        h.hover(b.center, at: 1.0)
        h.run(until: 1.1)
        #expect(!log.contains("h1 e0"))
        #expect(log.contains("h0 e0"))
    }

    @Test func desktopButtonsAreNoTabStopsWithoutFullKeyboardAccess() {
        #expect(!DesktopControlStates.isTabStop(desktop: true, fullKeyboardAccess: false))
        #expect(DesktopControlStates.isTabStop(desktop: true, fullKeyboardAccess: true))
        #expect(DesktopControlStates.isTabStop(desktop: false, fullKeyboardAccess: false))
        let log = EventLog()
        let h = Harness(size: CGSize(width: 300, height: 200)) {
            VStack {
                Button("A") { log.add("a") }
                Button("B") { log.add("b") }
            }
            .environment(\._desktopChrome, true)
        }
        h.key(.tab, at: 1.0)
        h.key(.space, at: 1.1)
        #expect(log.entries.isEmpty)
    }

    @Test func desktopPopUpPickerOpensOnMouseDown() {
        struct P: View {
            @State var v = 0
            var body: some View {
                Picker("Size", selection: $v) { Text("Small").tag(0); Text("Large").tag(1) }
                    .pickerStyle(.menu).labelsHidden()
                    .environment(\._desktopChrome, true)
                    .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        let h = Harness(size: CGSize(width: 300, height: 300)) { P() }
        guard let b = h.frame(where: { $0 is MenuPickerButton }) else { Issue.record("pop-up"); return }
        h.pointer(.down, b.center, at: 1.0, kind: .mouse)
        h.run(until: 1.1)
        #expect(h.host.windows.contains { $0.isPopup } || !h.window.overlayPopups.isEmpty)
        h.pointer(.up, b.center, at: 1.2, kind: .mouse)
        h.run(until: 1.3)
    }

    @Test func heldSegmentDimsItsLabelBySpec() {
        let s = 0xC4 as Double / 0xE8
        #expect(abs(DesktopControlStates.pressedSegmentLabel - s) < 0.01)
    }
}
