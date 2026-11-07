import AppKit
import YcodeIDECore

/// A control Ycode draws inside one of its views (the merge sheet's
/// "Hierarchical | Flat" segments, the conflict navigator's and the
/// stepper's chevrons, the gutter's tokens), exposed to accessibility as a
/// button (or radio button) with its label and a press action
/// (`merge-sheet.md` §13.2: what a pointer can press, an assistive
/// technology can press too).
@MainActor
final class DrawnControlElement: NSAccessibilityElement {
    private weak var view: NSView?
    private let rect: @MainActor () -> NSRect
    private let press: @MainActor () -> Void
    private let enabled: @MainActor () -> Bool
    private let selected: (@MainActor () -> Bool)?
    private let label: @MainActor () -> String

    /// `rect` is in `view`'s coordinates; `selected` makes it a radio button.
    init(in view: NSView, label: @escaping @MainActor () -> String, rect: @escaping @MainActor () -> NSRect,
         enabled: @escaping @MainActor () -> Bool = { true }, selected: (@MainActor () -> Bool)? = nil,
         press: @escaping @MainActor () -> Void) {
        self.view = view
        self.rect = rect
        self.press = press
        self.enabled = enabled
        self.selected = selected
        self.label = label
        super.init()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { selected == nil ? .button : .radioButton }
    override func accessibilityLabel() -> String? { label() }
    override func accessibilityTitle() -> String? { label() }
    override func accessibilityValue() -> Any? { selected.map { NSNumber(value: $0() ? 1 : 0) } }
    override func isAccessibilityElement() -> Bool { true }
    override func isAccessibilityEnabled() -> Bool { enabled() }
    override func accessibilityParent() -> Any? { view }

    override func accessibilityFrame() -> NSRect {
        guard let view, let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(rect(), to: nil))
    }

    /// The element's rectangle in its view (tests).
    var frameInView: NSRect { rect() }

    override func accessibilityPerformPress() -> Bool {
        guard enabled() else { return false }
        press()
        return true
    }
}

/// The Choose menu's pointer tracking (`merge-sheet.md` §13.6): AppKit
/// highlights a menu item only once the pointer moves, so a menu that opens
/// under a resting pointer would show no highlight until then. When the
/// menu opens, a mouse-moved event at the pointer's place is queued, so the
/// item under it is highlighted from the menu's first frame.
@MainActor
final class MergeChooseMenuTracking: NSObject, NSMenuDelegate {
    static let shared = MergeChooseMenuTracking()
    /// Round 4 measured Ycode's menu this much lower than the reference's
    /// (Choose Right's bar at y 315 against 309, §13.6): it opens this much
    /// higher.
    static let menuTopOffset: CGFloat = 6
    /// The last event queued (tests).
    private(set) var lastPosted: NSEvent?

    func menuWillOpen(_ menu: NSMenu) {
        guard let e = Self.pointerMovedEvent() else { return }
        lastPosted = e
        NSApp.postEvent(e, atStart: false)
    }

    /// A mouse-moved event where the pointer is now (screen coordinates).
    static func pointerMovedEvent() -> NSEvent? {
        NSEvent.mouseEvent(with: .mouseMoved, location: NSEvent.mouseLocation, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
    }
}
