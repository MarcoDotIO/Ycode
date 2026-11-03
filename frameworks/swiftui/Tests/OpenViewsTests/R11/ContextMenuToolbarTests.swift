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

// Round R11: context menus (secondary click, long press, Shift+F10, list
// selections) and window toolbars outside navigation containers.

@MainActor
@Suite("R11 context menus and window toolbars")
struct ContextMenuToolbarTests {
    struct Rows: View {
        var body: some View {
            VStack(spacing: 0) {
                Color.red.frame(width: 200, height: 60)
                    .contextMenu {
                        Button("Rename") { CommandLog.shared.add("rename red") }
                        Button("Delete", role: .destructive) { CommandLog.shared.add("delete red") }
                    }
                Button { CommandLog.shared.add("tap blue") } label: { Color.blue.frame(width: 200, height: 60) }
                    .contextMenu { Button("Inspect") { CommandLog.shared.add("inspect blue") } }
                Color.green.frame(width: 200, height: 60)
            }
        }
    }

    func centre(_ h: CommandsHarness, _ c: Color) -> CGPoint? {
        h.frame { ($0 as? Color) == c }.map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    @Test func secondaryClickOpensTheInnermostContextMenuAtThePointer() {
        let h = CommandsHarness(menuBar: false) { Rows() }
        guard let red = centre(h, .red), let green = centre(h, .green) else { Issue.record("frames"); return }
        h.click(green, button: 3, at: 1)
        #expect(h.popups.isEmpty)
        h.click(red, button: 3, at: 1.2)
        #expect(h.popups.count == 1)
        if let pw = h.popups.first?.platform as? HeadlessWindow {
            #expect(abs(pw.popupOrigin.x - red.x) < 0.01 && abs(pw.popupOrigin.y - red.y) < 0.01)
        }
        #expect(h.openItems == ["Rename", "Delete"])
        h.choose("Delete", at: 1.5)
        #expect(CommandLog.shared.entries == ["delete red"])
        #expect(h.main.services.contextMenus.openedCount == 1)
    }

    @Test func longTouchPressOpensItAndTheButtonDoesNotFire() {
        let h = CommandsHarness(menuBar: false) { Rows() }
        guard let blue = centre(h, .blue) else { Issue.record("frame"); return }
        // A short tap runs the button.
        h.click(blue, kind: .touch, at: 1)
        #expect(CommandLog.shared.entries == ["tap blue"])
        // Held 0.7 s: the menu opens at 0.5 s and the release does nothing.
        h.click(blue, kind: .touch, at: 2, duration: 0.7)
        #expect(h.popups.count == 1)
        #expect(CommandLog.shared.entries == ["tap blue"])
        h.choose("Inspect", at: 3)
        #expect(CommandLog.shared.entries == ["tap blue", "inspect blue"])
    }

    @Test func movingDuringTheLongPressCancelsIt() {
        let h = CommandsHarness(menuBar: false) { Rows() }
        guard let red = centre(h, .red) else { Issue.record("frame"); return }
        let w = h.windowID
        h.backend.post(.pointer(PointerEvent(window: w, kind: .touch, phase: .down, location: red, timestamp: 1)), at: 1)
        h.backend.post(.pointer(PointerEvent(window: w, kind: .touch, phase: .moved, location: CGPoint(x: red.x + 30, y: red.y),
                                             timestamp: 1.2)), at: 1.2)
        h.run(until: 1.8)
        #expect(h.popups.isEmpty)
        h.backend.post(.pointer(PointerEvent(window: w, kind: .touch, phase: .up, location: red, isPressed: false,
                                             timestamp: 1.9)), at: 1.9)
        h.run(until: 2)
    }

    @Test func shiftF10OpensTheFocusedViewsMenu() {
        let h = CommandsHarness(menuBar: false) {
            TextField("Name", text: .constant("x"))
                .contextMenu { Button("Clear") { CommandLog.shared.add("clear") } }
        }
        h.key(.tab, at: 1)
        h.key(.function(10), [.shift], at: 1.2)
        #expect(h.popups.count == 1)
        #expect(h.openItems == ["Clear"])
    }

    struct SelectionList: View {
        @State var selection: Set<String> = ["a", "b"]
        var body: some View {
            List(["a", "b", "c"], id: \.self, selection: $selection) { Text($0) }
                .contextMenu(forSelectionType: String.self) { items in
                    Button("Open \(items.sorted().joined(separator: ","))") {
                        CommandLog.shared.add("open \(items.sorted())")
                    }
                }
        }
    }

    @Test func listSelectionMenusGetTheSelectionOrTheRow() {
        let h = CommandsHarness(menuBar: false) { SelectionList() }
        guard let b = h.textFrame("b"), let c = h.textFrame("c") else { Issue.record("rows"); return }
        h.click(CGPoint(x: b.midX, y: b.midY), button: 3, at: 1)
        #expect(h.openItems == ["Open a,b"])
        h.key(.escape, at: 1.2)
        h.click(CGPoint(x: c.midX, y: c.midY), button: 3, at: 1.5)
        #expect(h.openItems == ["Open c"])
        h.choose("Open c", at: 1.7)
        #expect(CommandLog.shared.entries == ["open [\"c\"]"])
    }

    struct ToolbarContentView: View {
        var body: some View {
            Text("Content")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItem(placement: .navigation) { Text("Back") }
                    ToolbarItem(placement: .principal) { Text("Title") }
                    ToolbarItem(placement: .primaryAction) { Button("Compile") { CommandLog.shared.add("compile") } }
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("Run") { CommandLog.shared.add("run") }
                        Button("Stop") {}
                    }
                    ToolbarItem(placement: .bottomBar) { Text("Status") }
                }
        }
    }

    @Test func windowToolbarPlacements() {
        let h = CommandsHarness { ToolbarContentView() }
        guard let back = h.textFrame("Back"), let title = h.textFrame("Title"), let build = h.textFrame("Compile"),
              let run = h.textFrame("Run"), let status = h.textFrame("Status"), let content = h.textFrame("Content")
        else { Issue.record("frames"); return }
        // Under the 26-point menu bar, a 38-point toolbar.
        #expect(back.midY > 26 && back.midY < 64)
        #expect(back.minX < 40)
        #expect(abs(title.midX - 400) < 1)
        #expect(build.maxX < run.minX && run.maxX > 700)
        // Fixed spacer: 12 points plus the bar's spacing between Build and the group.
        #expect(run.minX - build.maxX > 12)
        #expect(status.minY > 450)
        #expect(content.midY > 64 && content.midY < 470)
        h.click(CGPoint(x: run.midX, y: run.midY), at: 1)
        #expect(CommandLog.shared.entries == ["run"])
        // View > Hide Toolbar.
        h.openMenu("View", at: 1.5)
        #expect(h.openItems.contains("Hide Toolbar"))
        h.choose("Hide Toolbar", at: 1.7)
        #expect(h.textFrame("Compile") == nil)
        #expect(h.main.services.toolbar.isVisible == false)
    }

    @Test func toolbarsInsideNavigationStayInTheBar() {
        let h = CommandsHarness(menuBar: false) {
            NavigationStack {
                Text("Page").toolbar { ToolbarItem(placement: .primaryAction) { Text("Item") } }
            }
        }
        #expect(h.main.services.toolbar.hasItems == false)
        #expect(h.textFrame("Item") != nil)
    }
}
