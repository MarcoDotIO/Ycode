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

// Beta 4, B4-TOOLKIT (specs/ide/parity-inventory.md P-212, P-214, P-215):
// menus (submenus open when the pointer rests on their row, pop-ups not cut
// at the window's edges, shortcut glyphs), alerts (Return and Escape, the
// desktop look, keys kept inside the innermost presentation) and sheets
// (the window grows to show a sheet larger than it).

@MainActor
@Suite("B4 toolkit parity (P-212, P-214, P-215)")
struct ToolkitParityTests {
    // MARK: Helpers

    func hover(_ h: CommandsHarness, _ p: CGPoint, in w: WindowHost, at t: TimeInterval) {
        h.backend.post(.pointer(PointerEvent(window: w.platform.id, kind: .mouse, phase: .moved, location: p, button: 0,
                                             isPressed: false, timestamp: t)), at: t)
        h.run(until: t + 0.005)
    }

    func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    // MARK: P-212 menus

    @Test func shortcutGlyphsFollowTheMacOSOrder() {
        #expect(KeyboardShortcut("k", modifiers: [.command, .shift]).displayText == "⇧⌘K")
        #expect(KeyboardShortcut("f", modifiers: [.command, .control]).displayText == "⌃⌘F")
        #expect(KeyboardShortcut("a", modifiers: [.command, .option, .control, .shift]).displayText == "⌃⌥⇧⌘A")
        #expect(KeyboardShortcut("1", modifiers: .control).displayText == "⌃1")
        #expect(KeyboardShortcut("1", modifiers: .command).displayText == "⌘1")
        #expect(KeyboardShortcut(.escape, modifiers: []).displayText == "⎋")
        #expect(KeyboardShortcut(.delete, modifiers: .command).displayText == "⌘⌫")
        #expect(KeyboardShortcut(.upArrow, modifiers: [.command, .option]).displayText == "⌥⌘↑")
        #expect(KeyboardShortcut(.tab, modifiers: .control).displayText == "⌃⇥")
    }

    @Test func ctrlPrefersTheCommandShortcutOverTheControlOne() {
        struct Twins: View {
            var body: some View {
                VStack {
                    Button("Control R") { CommandLog.shared.add("control") }.keyboardShortcut("r", modifiers: .control)
                    Button("Command R") { CommandLog.shared.add("command") }.keyboardShortcut("r", modifiers: .command)
                }
            }
        }
        let h = CommandsHarness(menuBar: false) { Twins() }
        h.key(.character("r"), [.control], at: 1)
        #expect(CommandLog.shared.entries == ["command"])
    }

    @Test func controlF2OpensTheMenuBar() {
        let h = CommandsHarness { Text("Body") }
        h.key(.function(2), [.control], at: 1)
        #expect(h.main.services.menuBar?.openIndex == 0)
        h.key(.escape, at: 1.2)
        #expect(h.popups.isEmpty)
    }

    struct Nested: View {
        var body: some View {
            Menu("Top") {
                Menu("Recent") {
                    Button("First") { CommandLog.shared.add("first") }
                }
                Button("Plain") {}
                Menu("Other") {
                    Button("Second") {}
                }
            }
        }
    }

    @Test func submenuOpensWhenThePointerRestsOnItsRow() {
        let h = CommandsHarness(menuBar: false, desktop: true) { Nested() }
        guard let top = h.textFrame("Top") else { Issue.record("Top"); return }
        h.click(center(top), at: 1)
        #expect(h.popups.count == 1)
        guard let menu = h.popups.last, let recent = h.textFrame("Recent", in: menu) else { Issue.record("menu"); return }
        hover(h, center(recent), in: menu, at: 1.2)
        // Not yet: the rest is 0.2 s.
        h.run(until: 1.35)
        #expect(h.popups.count == 1)
        h.run(until: 1.45)
        #expect(h.popups.count == 2)
        #expect(h.openItems == ["First"])
        // The row of the open submenu stays highlighted (expanded).
        // Resting on a plain row closes the submenu.
        guard let plain = h.textFrame("Plain", in: menu) else { Issue.record("Plain"); return }
        hover(h, center(plain), in: menu, at: 1.6)
        h.run(until: 1.7)
        #expect(h.popups.count == 2)
        h.run(until: 1.85)
        #expect(h.popups.count == 1)
        // Resting on another submenu row opens that one instead.
        guard let other = h.textFrame("Other", in: menu) else { Issue.record("Other"); return }
        hover(h, center(other), in: menu, at: 2.0)
        h.run(until: 2.3)
        #expect(h.popups.count == 2)
        #expect(h.openItems == ["Second"])
    }

    @Test func passingOverASubmenuRowOpensNothing() {
        let h = CommandsHarness(menuBar: false, desktop: true) { Nested() }
        guard let top = h.textFrame("Top") else { Issue.record("Top"); return }
        h.click(center(top), at: 1)
        guard let menu = h.popups.last, let recent = h.textFrame("Recent", in: menu),
              let plain = h.textFrame("Plain", in: menu) else { Issue.record("menu"); return }
        hover(h, center(recent), in: menu, at: 1.2)
        hover(h, center(plain), in: menu, at: 1.3)
        h.run(until: 1.6)
        #expect(h.popups.count == 1)
    }

    @Test func menusMayExtendPastTheWindowIntoTheDisplay() {
        struct Long: View {
            var body: some View {
                VStack {
                    Spacer()
                    Menu("Long") {
                        ForEach(0..<30, id: \.self) { i in Button("Item number \(i) with a long title") {} }
                    }
                }
            }
        }
        let h = CommandsHarness(menuBar: false, desktop: true) { Long() }
        // The window is 800 × 500 on a display whose usable area runs from
        // 100 above to 1400 below its top-left corner.
        (h.main.platform as? HeadlessWindow)?.popupArea = CGRect(x: -50, y: -100, width: 1900, height: 1500)
        guard let long = h.textFrame("Long") else { Issue.record("Long"); return }
        h.click(center(long), at: 1)
        guard let p = h.popups.last, let w = p.platform as? HeadlessWindow else { Issue.record("pop-up"); return }
        // 30 rows of 26 points do not fit in the window: the pop-up opens
        // below its button, past the window's bottom edge, uncut.
        #expect(p.size.height > 500)
        #expect(w.popupOrigin.y > long.maxY)
        #expect(w.popupOrigin.y + p.size.height <= 1400 + 0.5)
    }

    @Test func withoutADisplayAreaMenusStayInTheWindow() {
        let h = CommandsHarness(menuBar: false, desktop: true) { Nested() }
        guard let top = h.textFrame("Top") else { Issue.record("Top"); return }
        h.click(center(top), at: 1)
        guard let p = h.popups.last, let w = p.platform as? HeadlessWindow else { Issue.record("pop-up"); return }
        #expect(w.popupOrigin.y + p.size.height <= 500 + 0.5)
    }

    // MARK: P-214 alerts

    final class AlertModel {
        var log: [String] = []
    }

    struct AlertProbe: View {
        let model: AlertModel
        @State var shown = false
        @State var text = "under"
        var body: some View {
            VStack {
                TextField("Under", text: $text)
                Button("Show") { shown = true }.keyboardShortcut("s", modifiers: .command)
                Button("Behind") { model.log.append("behind") }.keyboardShortcut(.defaultAction)
            }
            .alert("Merge “feature”?", isPresented: $shown) {
                Button("Merge") { model.log.append("merge") }
                Button("Cancel", role: .cancel) { model.log.append("cancel") }
            } message: {
                Text("Changes will be merged into your current branch.")
            }
        }
    }

    @Test func returnChoosesTheDefaultButtonAndDismisses() {
        let model = AlertModel()
        let h = CommandsHarness(menuBar: false, desktop: true) { AlertProbe(model: model) }
        // A field under the alert has the keyboard.
        h.key(.tab, at: 1)
        #expect(h.main.services.focus.focusedClient != nil)
        h.key(.character("s"), [.control], at: 1.1)
        h.run(until: 1.6)
        #expect(!h.main.services.presentations.isEmpty)
        // The field under the alert lost the keyboard.
        #expect(h.main.services.focus.focusedClient == nil)
        h.key(.return, at: 1.7)
        h.run(until: 2.4)
        // The alert's default button ran, not the window's.
        #expect(model.log == ["merge"])
        #expect(h.main.services.presentations.isEmpty)
        // The field got the keyboard back.
        #expect(h.main.services.focus.focusedClient != nil)
    }

    @Test func escapeChoosesCancel() {
        let model = AlertModel()
        let h = CommandsHarness(menuBar: false, desktop: true) { AlertProbe(model: model) }
        h.key(.character("s"), [.control], at: 1)
        h.run(until: 1.5)
        h.key(.escape, at: 1.6)
        h.run(until: 2.3)
        #expect(model.log == ["cancel"])
        #expect(h.main.services.presentations.isEmpty)
    }

    @Test func aSingleButtonAlertTakesReturnAndEscape() {
        struct One: View {
            @State var shown = true
            var body: some View {
                Color.white.alert("Cannot Open", isPresented: $shown) {
                    Button("OK") { CommandLog.shared.add("ok") }
                }
            }
        }
        let h = CommandsHarness(menuBar: false, desktop: true) { One() }
        h.run(until: 1.2)
        h.key(.escape, at: 1.3)
        h.run(until: 2)
        // Escape dismisses it.
        #expect(h.main.services.presentations.isEmpty)
        let h2 = CommandsHarness(menuBar: false, desktop: true) { One() }
        h2.run(until: 1.2)
        h2.key(.return, at: 1.3)
        h2.run(until: 2)
        #expect(CommandLog.shared.entries == ["ok"])
        #expect(h2.main.services.presentations.isEmpty)
    }

    @Test func anExplicitDefaultButtonWins() {
        struct Three: View {
            @State var shown = true
            var body: some View {
                Color.white.alert("Save changes?", isPresented: $shown) {
                    Button("Don’t Save", role: .destructive) { CommandLog.shared.add("discard") }
                    Button("Save") { CommandLog.shared.add("save") }.keyboardShortcut(.defaultAction)
                    Button("Cancel", role: .cancel) { CommandLog.shared.add("cancel") }
                }
            }
        }
        let h = CommandsHarness(menuBar: false, desktop: true) { Three() }
        h.run(until: 1.2)
        h.key(.return, at: 1.3)
        h.run(until: 2)
        #expect(CommandLog.shared.entries == ["save"])
    }

    @Test func desktopAlertLook() {
        let model = AlertModel()
        let h = CommandsHarness(menuBar: false, desktop: true) {
            AlertProbe(model: model)._alertIcon(Color.purple)
        }
        h.key(.character("s"), [.control], at: 1)
        h.run(until: 1.6)
        guard let card = h.frame(where: { $0 is AlertCard }), let title = h.textFrame("Merge “feature”?"),
              let merge = h.textFrame("Merge"), let cancel = h.textFrame("Cancel"),
              let icon = h.frame(where: { ($0 as? Color) == .purple }) else {
            Issue.record("alert parts")
            return
        }
        // 260 wide, centred; the icon at the top left, the title left-aligned
        // 20 in, below the icon.
        #expect(abs(card.width - 260) < 0.5)
        #expect(abs(card.midX - 400) < 1)
        #expect(abs(icon.width - 64) < 0.5 && abs(icon.minY - card.minY - 20) < 0.5)
        #expect(abs(title.minX - card.minX - 20) < 1.5)
        #expect(title.minY > icon.maxY)
        // Cancel leading, the default (Merge) trailing, side by side.
        #expect(cancel.midX < merge.midX)
        #expect(abs(cancel.midY - merge.midY) < 0.5)
    }

    @Test func returnInAFieldChoosesTheSheetsDefaultButton() {
        struct Clone: View {
            @State var shown = true
            @State var url = ""
            var body: some View {
                Color.white.sheet(isPresented: $shown) {
                    VStack {
                        TextField("URL", text: $url)
                        Button("Clone") { CommandLog.shared.add("clone \(url)") }.keyboardShortcut(.defaultAction)
                    }
                    .frame(width: 400, height: 150)
                }
            }
        }
        let h = CommandsHarness(menuBar: false, desktop: true) { Clone() }
        h.run(until: 1.2)
        h.key(.tab, at: 1.3)
        #expect(h.main.services.focus.focusedClient != nil)
        h.type("x", at: 1.4)
        h.key(.return, at: 1.6)
        #expect(CommandLog.shared.entries == ["clone x"])
    }

    // MARK: P-215 sheets

    struct BigSheet: View {
        @State var shown = false
        var body: some View {
            Button("Open") { shown = true }
                .sheet(isPresented: $shown) {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button("Next") { shown = false }.keyboardShortcut(.defaultAction)
                        }
                    }
                    .frame(width: 900, height: 600)
                }
        }
    }

    @Test func aSheetLargerThanItsWindowGrowsTheWindow() {
        let h = CommandsHarness(menuBar: false, desktop: true) { BigSheet() }
        #expect(h.main.size == CGSize(width: 800, height: 500))
        guard let open = h.textFrame("Open") else { Issue.record("Open"); return }
        h.click(center(open), at: 1)
        h.run(until: 1.6)
        // The window grew so that the sheet fits with its margin; Next is
        // inside the window.
        #expect(h.main.size == CGSize(width: 940, height: 640))
        guard let next = h.textFrame("Next") else { Issue.record("Next"); return }
        #expect(next.maxX <= h.main.size.width && next.maxY <= h.main.size.height, "Next at \(next) in \(h.main.size)")
        // Closing the sheet gives the window its size back.
        h.key(.return, at: 1.7)
        h.run(until: 2.6)
        #expect(h.main.services.presentations.isEmpty)
        #expect(h.main.size == CGSize(width: 800, height: 500))
    }

    @Test func growthStopsAtTheDisplaysUsableSize() {
        let h = CommandsHarness(menuBar: false, desktop: true) { BigSheet() }
        (h.main.platform as? HeadlessWindow)?.usableDisplaySize = CGSize(width: 1000, height: 560)
        guard let open = h.textFrame("Open") else { Issue.record("Open"); return }
        h.click(center(open), at: 1)
        h.run(until: 1.6)
        #expect(h.main.size == CGSize(width: 940, height: 560))
    }

    // MARK: P-139 / L-072 the Settings window

    func openSettings(_ h: CommandsHarness, at t: TimeInterval) -> WindowHost? {
        h.key(.character(","), [.control], at: t)
        let windows = h.host.windows.filter { !$0.isPopup }
        return windows.count == 2 ? windows.last : nil
    }

    @Test func settingsResizesFromItsContentSize() {
        let h = CommandsHarness { Text("Body") }
        guard let s = openSettings(h, at: 1), let pw = s.platform as? HeadlessWindow else {
            Issue.record("settings")
            return
        }
        #expect(pw.isResizable)
        #expect(pw.minimumSize == CGSize(width: 400, height: 250))
        #expect(pw.maximumSize?.width == .infinity && pw.maximumSize?.height == .infinity)
    }

    @Test func commandWAndEscapeCloseTheSettingsWindow() {
        let h = CommandsHarness { Text("Body") }
        guard let s = openSettings(h, at: 1) else { Issue.record("settings"); return }
        h.key(.character("w"), [.control], window: s.platform.id, at: 1.5)
        #expect(h.host.windows.filter { !$0.isPopup }.count == 1)
        guard let s2 = openSettings(h, at: 2) else { Issue.record("settings again"); return }
        h.key(.escape, window: s2.platform.id, at: 2.5)
        #expect(h.host.windows.filter { !$0.isPopup }.count == 1)
        // Ctrl+Shift+W and Ctrl+Alt+W do not close it.
        guard let s3 = openSettings(h, at: 3) else { Issue.record("settings 3"); return }
        h.key(.character("w"), [.control, .shift], window: s3.platform.id, at: 3.5)
        h.key(.character("w"), [.control, .option], window: s3.platform.id, at: 3.6)
        #expect(h.host.windows.filter { !$0.isPopup }.count == 2)
    }

    @Test func mainWindowsDoNotCloseOnEscape() {
        let h = CommandsHarness { Text("Body") }
        h.key(.escape, at: 1)
        #expect(h.host.windows.filter { !$0.isPopup }.count == 1)
    }

    @Test func aSheetThatFitsLeavesTheWindowAlone() {
        struct Small: View {
            @State var shown = true
            var body: some View {
                Color.white.sheet(isPresented: $shown) { Text("Small").frame(width: 400, height: 200) }
            }
        }
        let h = CommandsHarness(menuBar: false, desktop: true) { Small() }
        h.run(until: 1.5)
        #expect(h.main.size == CGSize(width: 800, height: 500))
    }
}
