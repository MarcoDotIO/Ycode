import AppKit
import ObjectiveC
import YcodeIDECore

/// Narrow workspace windows (`parity-inventory.md` P-024,
/// `window-layout.md` §4.1, §4.2; `NarrowWindowLayout`): the editor keeps
/// at least 300 points. As the window narrows only the editor gives up room
/// until it reaches 300; then, on a live drag, the navigator **collapses**
/// with its slide (it never shrinks first) and stays hidden when the window
/// widens again; then a shown inspector narrows toward 201.5. The window's
/// minimum width follows the inspector: ≈ 503 points with it shown, 410
/// (the toolbar's floor) with it hidden.
extension WorkspaceWindowController {
    private static var narrowKey = 0

    /// The split items' limits and the window's minimum, and the live
    /// resize's observers.
    func installNarrowWindowLayout() {
        guard let window, mainSplit.splitViewItems.count >= 3 else { return }
        let center = mainSplit.splitViewItems[1]
        center.minimumThickness = CGFloat(NarrowWindowLayout.editorMinimum)
        // A divider drag may still narrow the navigator; a window resize
        // never does (the inspector gives way before it, then it collapses).
        navigatorItem.minimumThickness = Self.navigatorDragMinimum
        navigatorItem.canCollapseFromWindowResize = true
        // Both hold above the 260 at which the Coding Assistant's pane asks
        // for the area's width (P-026), so a wide pane never widens the area;
        // the navigator holds above the inspector, so a squeeze reaches the
        // inspector first and the navigator collapses whole.
        navigatorItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 263)
        inspectorItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 262)
        inspectorItem.minimumThickness = CGFloat(NarrowWindowLayout.inspectorMinimum)
        updateMinimumWindowWidth()
        let center2 = NotificationCenter.default
        let resize = center2.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.narrowWindowDidResize() }
        }
        let start = center2.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteLiveResizeStart() }
        }
        // Not inside a layout pass (a collapse from a window resize): the
        // window's minimum changes on the next turn.
        let kvo = inspectorItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateMinimumWindowWidth() } }
        }
        objc_setAssociatedObject(self, &Self.narrowKey, NarrowObserver([resize, start], kvo), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// The narrowest a divider drag makes the navigator.
    static let navigatorDragMinimum: CGFloat = 135

    /// The window's minimum width for the inspector's state (§4.1).
    func updateMinimumWindowWidth() {
        guard let window, let inspectorItem else { return }
        let w = CGFloat(NarrowWindowLayout.minimumWindowWidth(inspectorShown: !inspectorItem.isCollapsed))
        if window.minSize.width != w { window.minSize = NSSize(width: w, height: window.minSize.height) }
    }

    /// The inspector's width as the live resize began: the squeeze is
    /// judged against it, not against the few points the split view takes
    /// from the inspector in the step that crosses the editor's floor.
    private var liveResizeInspectorWidth: CGFloat? {
        get { (objc_getAssociatedObject(self, &Self.inspectorKey) as? NSNumber).map { CGFloat($0.doubleValue) } }
        set { objc_setAssociatedObject(self, &Self.inspectorKey, newValue.map { NSNumber(value: Double($0)) }, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    private static var inspectorKey = 0

    func noteLiveResizeStart() {
        liveResizeInspectorWidth = inspectorItem.isCollapsed ? nil : inspector.view.frame.width
    }

    /// A live resize collapses the navigator, with its slide, once the
    /// editor would go below 300 points beside it (`live`: tests stand in
    /// for the window's own live resize).
    func narrowWindowDidResize(live: Bool? = nil) {
        guard let window, live ?? window.inLiveResize, !navigatorItem.isCollapsed, !isNavigatorSliding else { return }
        let split = mainSplit.splitView
        let inspector = inspectorItem.isCollapsed ? nil : Double(max(inspector.view.frame.width, liveResizeInspectorWidth ?? 0))
        let nav = Double(navigator.view.frame.width)
        guard NarrowWindowLayout.liveResizeHidesNavigator(width: Double(window.frame.width), navigator: nav, inspector: inspector,
                                                          divider: Double(split.dividerThickness)) else { return }
        navigatorSlide.lastSize = navigator.view.frame.width
        // On a display the navigator slides out (§4.2: "it hides with the
        // slide of §6.1"); off every display it collapses at once.
        if slideNavigator(show: false, trigger: .key, then: { [weak self] in self?.restoreInspectorWidth() }) { return }
        navigatorItem.isCollapsed = true
        syncNavigatorToolbarArrangement()
        restoreInspectorWidth()
        updateToolbarState()
    }

    /// After the navigator hid: the inspector gets back what the drag took
    /// from it on the way (up to its 260 points), while the editor keeps
    /// 300.
    func restoreInspectorWidth() {
        guard let window, !inspectorItem.isCollapsed else { return }
        let split = mainSplit.splitView
        split.layoutSubtreeIfNeeded()
        let rest = liveResizeInspectorWidth ?? CGFloat(WorkspaceChrome.inspectorWidth)
        guard inspector.view.frame.width < rest - 0.5 else { return }
        let room = window.frame.width - CGFloat(NarrowWindowLayout.editorMinimum) - split.dividerThickness
        let target = min(rest, max(inspector.view.frame.width, room))
        // Two steps at most: the divider's position and the inspector's
        // width need not differ by exactly the divider.
        for _ in 0..<2 {
            let shown = inspector.view.frame.width
            guard abs(target - shown) > 0.5, split.arrangedSubviews.count >= 3 else { return }
            let position = split.arrangedSubviews[2].frame.minX - split.dividerThickness
            split.setPosition(position - (target - shown), ofDividerAt: 1)
            split.layoutSubtreeIfNeeded()
        }
    }
}

/// Removes the observers with the window controller.
private final class NarrowObserver: NSObject {
    let tokens: [NSObjectProtocol]
    let kvo: NSKeyValueObservation
    init(_ tokens: [NSObjectProtocol], _ kvo: NSKeyValueObservation) {
        self.tokens = tokens
        self.kvo = kvo
    }
    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
        kvo.invalidate()
    }
}
