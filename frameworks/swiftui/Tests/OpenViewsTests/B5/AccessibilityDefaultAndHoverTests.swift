import Foundation
import OVPlatform
import OVAccessibilityATSPI
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// B5-OPENVIEWS, open from round 4 (`fidelity-council.md` rows 98, 102, 130):
// the default and cancel buttons in the accessibility tree (and AT-SPI's
// `is-default` state), and the item under the pointer hovered from a pop-up's
// first frame.

@MainActor
final class HoverLog {
    static var events: [Bool] = []
}

@MainActor
@Suite("B5 default buttons and first-frame hover")
struct AccessibilityDefaultAndHoverTests {
    struct Buttons: View {
        var body: some View {
            HStack {
                Button("Cancel", role: .cancel) {}
                Button("Stop") {}.keyboardShortcut(.cancelAction)
                Button("Merge") {}.keyboardShortcut(.defaultAction)
                Button("Other") {}
            }
        }
    }

    @Test func defaultAndCancelButtonsAreMarked() throws {
        let h = CommandsHarness(menuBar: false) { Buttons() }
        let tree = h.main.accessibilityTree().flattened
        func el(_ l: String) throws -> AccessibilityElement { try #require(tree.first { $0.label == l && $0.role == .button }) }
        #expect(try el("Merge").isDefaultButton && !el("Merge").isCancelButton)
        #expect(try el("Cancel").isCancelButton && !el("Cancel").isDefaultButton)
        #expect(try el("Stop").isCancelButton)
        #expect(try !el("Other").isDefaultButton && !el("Other").isCancelButton)
        #expect(try el("Merge").description.hasSuffix("default"))
        // AT-SPI: the default button carries the is-default state.
        let merge = try el("Merge")
        #expect(ATSPIMapping.states(merge, focused: false, showing: true).contains(.isDefault))
        #expect(!ATSPIMapping.states(try el("Other"), focused: false, showing: true).contains(.isDefault))
    }

    struct Probe: View {
        var body: some View {
            VStack(spacing: 0) {
                Text("Item one").frame(width: 160, height: 24).contentShape(Rectangle())
                    .onHover { HoverLog.events.append($0) }
                Text("Item two").frame(width: 160, height: 24)
            }
        }
    }

    @Test func popupHoversTheItemUnderThePointerFromItsFirstFrame() throws {
        let h = CommandsHarness(menuBar: false) { Color.clear.frame(width: 400, height: 300) }
        HoverLog.events = []
        // The pointer rests at (110, 112); a pop-up opens with its first
        // item under it, without any pointer motion afterwards.
        h.hover(CGPoint(x: 110, y: 112), at: 1)
        let handle = h.main.services.popups?.presentPopup(content: AnyView(Probe()), origin: CGPoint(x: 100, y: 100),
                                                         anchor: nil, minWidth: 160, chrome: .plain,
                                                         fallbackKeys: nil, onDismiss: {})
        #expect(handle != nil)
        #expect(h.popups.count == 1)
        #expect(HoverLog.events == [true])
        handle?.dismiss()
        // Pointer outside the new pop-up: nothing is hovered.
        HoverLog.events = []
        h.hover(CGPoint(x: 10, y: 10), at: 2)
        _ = h.main.services.popups?.presentPopup(content: AnyView(Probe()), origin: CGPoint(x: 100, y: 100), anchor: nil,
                                                 minWidth: 160, chrome: .plain, fallbackKeys: nil, onDismiss: {})
        #expect(HoverLog.events.isEmpty)
    }
}
