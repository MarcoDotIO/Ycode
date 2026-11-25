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

// Beta 5, B5-OPENVIEWS (specs/ide/parity-inventory.md P-217, Linux row
// L-222): a pop-up button's menu opens over the button, its selected row on
// the button and the row's title over the button's title, as macOS pop-up
// buttons do; near the display's edge it is moved, not flipped.

@MainActor
@Suite("B5 pop-up placement (P-217)")
struct PopUpPlacementTests {
    struct Chooser: View {
        @State var choice = 3
        var body: some View {
            VStack {
                Spacer().frame(height: 200)
                Picker("Size", selection: $choice) {
                    ForEach(0..<6, id: \.self) { Text("Choice \($0)").tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Spacer()
            }
        }
    }

    @Test func theSelectedRowOpensOverTheButton() throws {
        let h = CommandsHarness(menuBar: false, desktop: true) { Chooser() }
        let button = try #require(h.textFrame("Choice 3"))
        h.click(CGPoint(x: button.midX, y: button.midY), at: 1)
        let p = try #require(h.popups.last)
        let w = try #require(p.platform as? HeadlessWindow)
        // Row 3's middle on the button's middle; its title over the title.
        let rowMid = w.popupOrigin.y + MenuMetrics.verticalPadding + 3.5 * MenuMetrics.rowHeight
        #expect(abs(rowMid - button.midY) <= 1, "row \(rowMid) button \(button.midY)")
        let row = try #require(h.textFrame("Choice 3", in: p))
        #expect(abs(w.popupOrigin.x + row.minX - button.minX) <= 1, "row \(w.popupOrigin.x + row.minX) button \(button.minX)")
        #expect(abs(w.popupOrigin.y + row.midY - button.midY) <= 1)
    }

    @Test func nearTheTopTheMenuMovesDownInsteadOfFlipping() {
        let o = MenuMetrics.overSelection(CGRect(x: 10, y: 4, width: 80, height: 20), selected: 5, textInset: 0)
        // Wanted: row 5 on the button, which starts above the area; the
        // placement keeps the origin and the window clamps it.
        #expect(o.origin.y < 0)
        let placed = PopupPlacement.origin(o.origin, size: CGSize(width: 120, height: 200), anchor: nil,
                                           area: CGRect(x: 0, y: 0, width: 800, height: 500))
        #expect(placed.y == 0)
    }

    @Test func aPhoneHostKeepsTheMenuBelowTheControl() throws {
        let h = CommandsHarness(menuBar: false, desktop: false) { Chooser() }
        let button = try #require(h.textFrame("Choice 3"))
        h.click(CGPoint(x: button.midX, y: button.midY), at: 1)
        let w = try #require(h.popups.last?.platform as? HeadlessWindow)
        #expect(w.popupOrigin.y > button.maxY)
    }
}

@MainActor
@Suite("B5 pop-up placement, menus of a picker (P-217)")
struct MenuPickerPlacementTests {
    struct MenuChooser: View {
        @State var choice = 2
        var body: some View {
            VStack {
                Spacer().frame(height: 200)
                Menu {
                    Picker(selection: $choice) {
                        ForEach(0..<5, id: \.self) { Text("Option \($0)").tag($0) }
                    } label: { EmptyView() }
                } label: {
                    Text("Option \(choice)")
                }
                Spacer()
            }
        }
    }

    @Test func aMenuOfAPickerOpensOverItsChoice() throws {
        let h = CommandsHarness(menuBar: false, desktop: true) { MenuChooser() }
        let button = try #require(h.textFrame("Option 2"))
        h.click(CGPoint(x: button.midX, y: button.midY), at: 1)
        let p = try #require(h.popups.last)
        let w = try #require(p.platform as? HeadlessWindow)
        let row = try #require(h.textFrame("Option 2", in: p))
        #expect(abs(w.popupOrigin.y + row.midY - button.midY) <= 2, "row \(w.popupOrigin.y + row.midY) button \(button.midY)")
    }

    @Test func anActionMenuStillOpensBelow() throws {
        let h = CommandsHarness(menuBar: false, desktop: true) {
            VStack { Spacer().frame(height: 200); Menu("Actions") { Button("One") {}; Button("Two") {} }; Spacer() }
        }
        let button = try #require(h.textFrame("Actions"))
        h.click(CGPoint(x: button.midX, y: button.midY), at: 1)
        let w = try #require(h.popups.last?.platform as? HeadlessWindow)
        #expect(w.popupOrigin.y > button.maxY)
    }
}

@MainActor
@Suite("B5 requests from B5-NEWPROJECT")
struct NewProjectRequestTests {
    @Test func aMenuOpensAtItsOffsetBelowTheButton() throws {
        let h = CommandsHarness(menuBar: false, desktop: true) {
            VStack { Spacer().frame(height: 200); Menu("Actions") { Button("One") {} }._menuOffset(10); Spacer() }
        }
        let button = try #require(h.textFrame("Actions"))
        h.click(CGPoint(x: button.midX, y: button.midY), at: 1)
        let w = try #require(h.popups.last?.platform as? HeadlessWindow)
        #expect(w.popupOrigin.y > button.maxY + 5)
    }

    final class Log { var gone = false }
    nonisolated(unsafe) static let log = Log()

    @Test func closingAWindowRunsOnDisappear() throws {
        Self.log.gone = false
        let h = DecoratedHarness { Text("Body").onDisappear { NewProjectRequestTests.log.gone = true } }
        h.host.closeWindow(h.main)
        #expect(Self.log.gone)
    }
}
