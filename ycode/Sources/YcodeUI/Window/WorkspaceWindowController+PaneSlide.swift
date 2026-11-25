import AppKit
import ObjectiveC
import QuartzCore
import YcodeIDECore

/// The navigator's and the debug area's slides (`parity-inventory.md` P-190,
/// P-191; beta 5's motion layer, `Motion`): the area's divider moves one
/// display frame at a time on the measured curve while the editor resizes
/// live, as the inspector's slide does (`+InspectorSlide.swift`). A show
/// opens the pane with its first moving frame; a hide collapses it with its
/// last. The navigator (`window-layout.md` §6.1): 290 points over 240 ms,
/// ease-in-out, for ⌘0, the toolbar's Navigators half and View ▸
/// Navigators alike. The debug area (§6.2): ≈ 250 ms, linear.
///
/// Only a window on a display slides; off every display (tests, hidden
/// windows) the pane changes at once, unless `PaneSlide.offscreen` asks.
extension WorkspaceWindowController {
    /// The running or last navigator slide.
    var navigatorSlide: PaneSlide { paneSlide(&PaneSlide.navigatorKey) }
    /// The running or last debug-area slide.
    var debugAreaSlide: PaneSlide { paneSlide(&PaneSlide.debugKey) }

    private func paneSlide(_ key: UnsafeRawPointer) -> PaneSlide {
        if let s = objc_getAssociatedObject(self, key) as? PaneSlide { return s }
        let s = PaneSlide()
        objc_setAssociatedObject(self, key, s, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return s
    }

    /// Whether a pane slide runs (tests).
    public var isNavigatorSliding: Bool { navigatorSlide.running }
    public var isDebugAreaSliding: Bool { debugAreaSlide.running }

    /// Whether this window slides its panes (on a display, or asked to off it).
    var slidesPanes: Bool {
        guard let window, window.isVisible else { return false }
        return PaneSlide.offscreen || window.occlusionState.contains(.visible)
    }

    // MARK: Navigator (P-190)

    /// Hides or shows the navigator area with its slide; false when the
    /// window does not slide (the caller collapses the item at once). The
    /// toolbar takes the navigator-hidden arrangement at the start of a hide
    /// and gives it up at the end of a show (`window-layout.md` §6.1): its
    /// items switch, they never travel with the pane. `then` runs after the
    /// last frame.
    @discardableResult
    func slideNavigator(show: Bool, trigger: Motion.NavigatorTrigger = .key, then: (() -> Void)? = nil) -> Bool {
        let split = mainSplit.splitView
        let state = navigatorSlide
        guard slidesPanes, split.subviews.count >= 3 else { return false }
        if state.running { return true }
        guard show == navigatorItem.isCollapsed else { return true }
        let press = CACurrentMediaTime()
        let width = show ? max(navigatorItem.minimumThickness, state.lastSize ?? Self.navigatorWidth) : navigator.view.frame.width
        if !show { state.lastSize = width }
        let open = FlushSidebar.position(forWidth: width, of: navigatorItem)
        state.begin(curve: Motion.navigator(show: show, trigger: trigger), press: press, show: show,
                    from: show ? 0 : open, to: show ? open : 0, item: navigatorItem)
        syncNavigatorToolbarArrangement()
        // The navigator's contents keep their width and leave by the
        // window's leading edge (their own constraints would hold the pane
        // at about 266 points, the selector bar's width).
        let rigid = RigidSlide(root: navigatorItem.viewController.view, width: width)
        state.onFrame = { [weak self] p in self?.paneSlideFrame(state, split: split, divider: 0, progress: p) }
        state.onEnd = { [weak self] in
            rigid.end()
            self?.syncNavigatorToolbarArrangement()
            self?.updateToolbarState()
            then?()
        }
        state.start(on: split)
        return true
    }

    /// What started a navigator slide: a key, a pointer click on a menu's
    /// item, or a click on a control (the toolbar's Navigators half).
    static func navigatorTrigger(_ sender: Any?) -> Motion.NavigatorTrigger {
        if sender is NSControl { return .click }
        return isPointerEvent ? .menu : .key
    }

    /// Whether the event being handled is the pointer's (a menu chosen with
    /// it); a key or no event (scripts, tests) counts as a key.
    static var isPointerEvent: Bool {
        guard let t = NSApp.currentEvent?.type else { return false }
        return [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseUp].contains(t)
    }

    // MARK: Debug area (P-191)

    /// Hides or shows the debug area with its slide; false when the window
    /// does not slide.
    @discardableResult
    func slideDebugArea(show: Bool) -> Bool {
        let split = centerSplit.splitView
        let state = debugAreaSlide
        guard slidesPanes, split.subviews.count >= 2 else { return false }
        if state.running { return true }
        guard show == debugItem.isCollapsed else { return true }
        let press = CACurrentMediaTime()
        if !show { rememberDebugAreaHeight() }
        let height = show ? debugAreaOpeningHeight : debugArea.view.frame.height
        let total = split.bounds.height, divider = split.dividerThickness
        let open = total - height - divider
        let closed = total - divider
        state.begin(curve: Motion.debugArea(show: show), press: press, show: show, from: show ? closed : open, to: show ? open : closed,
                    item: debugItem)
        state.onFrame = { [weak self] p in self?.paneSlideFrame(state, split: split, divider: 0, progress: p) }
        state.onEnd = nil
        state.start(on: split)
        return true
    }

    // MARK: Frames

    private func paneSlideFrame(_ state: PaneSlide, split: NSSplitView, divider: Int, progress: CGFloat) {
        guard state.running else { return }
        if state.show, !state.paneOpened {
            guard progress > 0 else { return }
            state.paneOpened = true
            state.item?.isCollapsed = false
        }
        let x = (state.from + (state.to - state.from) * progress).rounded()
        split.setPosition(x, ofDividerAt: divider)
        guard progress >= 1 else { return }
        state.finish()
    }
}

/// A running pane slide: its divider's travel, the curve's clock and the
/// display link that steps it.
@MainActor
final class PaneSlide: NSObject {
    nonisolated(unsafe) static var navigatorKey = 0
    nonisolated(unsafe) static var debugKey = 0
    /// Slides off every display too (tests that step the frames).
    static var offscreen = false

    var link: CADisplayLink?
    var running = false
    var clock: MotionClock?
    var from: CGFloat = 0
    var to: CGFloat = 0
    var show = false
    var paneOpened = true
    /// The pane's width or height when it was last shown.
    var lastSize: CGFloat?
    weak var item: NSSplitViewItem?
    private var minimum: CGFloat = 0
    private var canCollapse = true
    var onFrame: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    /// Each frame's time and progress (tests and the motion probe).
    private(set) var frames: [(time: Double, progress: Double)] = []

    func begin(curve: Motion.Curve, press: Double, show: Bool, from: CGFloat, to: CGFloat, item: NSSplitViewItem) {
        running = true
        clock = MotionClock(curve: curve, press: press)
        self.show = show
        self.from = from
        self.to = to
        self.item = item
        frames = []
        minimum = item.minimumThickness
        canCollapse = item.canCollapse
        // The pane may be narrower than its minimum while it slides, and
        // must not collapse before the last frame.
        item.minimumThickness = 1
        item.canCollapse = false
        paneOpened = !show
        EditorBlurMotion.begin()
        EditorScrollView.quietScrollersUntil = .infinity
    }

    /// Starts the display link (off every display the test steps it).
    func start(on view: NSView) {
        link?.invalidate()
        guard view.window?.screen != nil, view.window?.occlusionState.contains(.visible) == true else { return }
        let l = view.displayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc func step(_ link: CADisplayLink) { advance(to: link.targetTimestamp) }

    /// One frame at `time` (display-link time).
    func advance(to time: Double) {
        guard var c = clock else { return }
        let p = c.progress(at: time)
        clock = c
        frames.append((time - c.press, p))
        onFrame?(CGFloat(p))
    }

    /// The last frame: the pane at its size, or collapsed.
    func finish() {
        guard running else { return }
        link?.invalidate()
        link = nil
        running = false
        item?.canCollapse = canCollapse
        if !show { item?.isCollapsed = true }
        item?.minimumThickness = minimum
        EditorBlurMotion.end()
        EditorScrollView.quietScrollersUntil = CACurrentMediaTime() + EditorScrollView.quietAfterSlide
        onEnd?()
    }
}

extension WorkspaceWindowController {
    /// Whether `sender` is a menu item clicked in its menu (not its key
    /// equivalent): the reference's menu path starts sooner (P-190).
    static func isMenuClick(_ sender: Any?) -> Bool {
        guard sender is NSMenuItem else { return false }
        return NSApp.currentEvent?.type != .keyDown
    }
}

/// A pane's contents held at their width, pinned to the pane's trailing
/// edge, while the pane narrows or widens under them: the constraints that
/// tie the contents to the pane's leading edge are set aside and each such
/// view keeps its width; `end` puts them back.
@MainActor
final class RigidSlide {
    private var released: [NSLayoutConstraint] = []
    private var held: [NSLayoutConstraint] = []

    init(root: NSView, width: CGFloat) {
        root.layoutSubtreeIfNeeded()
        func isRoot(_ item: AnyObject?) -> Bool { item === root || (item as? NSLayoutGuide)?.owningView === root }
        func isLeading(_ a: NSLayoutConstraint.Attribute) -> Bool { a == .leading || a == .left }
        var views: [NSView] = []
        for c in root.constraints where c.isActive {
            if isRoot(c.firstItem), isLeading(c.firstAttribute), let v = c.secondItem as? NSView, v !== root {
                released.append(c)
                views.append(v)
            } else if isRoot(c.secondItem), isLeading(c.secondAttribute), let v = c.firstItem as? NSView, v !== root {
                released.append(c)
                views.append(v)
            }
        }
        NSLayoutConstraint.deactivate(released)
        var seen = Set<ObjectIdentifier>()
        for v in views where seen.insert(ObjectIdentifier(v)).inserted {
            // A shown pane's views at their width; a hidden pane's at the
            // pane's width.
            let shown = root.frame.width > 1 && v.frame.width > 1
            let w = shown ? v.frame.width : width
            held.append(v.widthAnchor.constraint(equalToConstant: w))
        }
        NSLayoutConstraint.activate(held)
    }

    func end() {
        NSLayoutConstraint.deactivate(held)
        NSLayoutConstraint.activate(released)
        held = []
        released = []
    }
}
