import Foundation

// The update cycle (03-architecture.md §5) and the headless host used by the
// conformance tests (10-plan.md R2: "headless host with a manual clock").
//
// One update pass:
//  1. Transaction: the writes since the last pass, coalesced (§4.2 rule 5),
//     with the transaction of the last write.
//  2. Bodies: invalidated nodes re-evaluate top-down; `onChange` actions run
//     inline, when the modifier sees its new value (before its content).
//  3. Lifecycle: queued `onAppear`s (and `task` starts) run in reverse
//     pre-order — children before parents, later siblings first (03 §2);
//     then the queued `onDisappear`s (and task cancellations), so a new
//     identity appears before the old one disappears.
//  4. Layout (when the host has a window or a proposal): the tree is lowered
//     to layout nodes and laid out by the R3 engine; geometry readers whose
//     size changed are invalidated.
//  5. Geometry and preferences: `onGeometryChange` actions, then the
//     preference values are reduced up the tree and `onPreferenceChange`
//     actions run.
// Writes made by actions schedule another pass; `update()` runs passes until
// nothing is pending (bounded). The transaction's completion handlers are
// sealed at the end of the pass (they fire when the animations the pass
// started complete, or at once when it started none; 05 §4).
//
// Animation (R6, 05-animation.md): an update starts animations at the time
// source's current time. `renderFrame()` is one display frame: pending
// updates run first, then every active animation is sampled; animatable
// bodies whose presented data changed are evaluated again (a "frame pass"
// with an empty transaction), removal transitions that ended tear their
// views down (`onDisappear` then), and layout runs again when bodies
// changed. After a layout pass, each layout node's frame (in its parent's
// coordinates) is recorded with the node's view; a change in an animated
// transaction animates it (`presentedLayers()`).

/// How the host lays out its root.
package struct HostLayout {
    package enum Mode {
        /// The root is the content of a window with safe-area insets
        /// (layout-direction terms; 04 §7).
        case window(CGSize, safeAreaInsets: EdgeInsets)
        /// The root is placed at the origin with this proposal.
        case proposal(ProposedViewSize)
    }
    package var mode: Mode
    package var textMeasurer: any TextMeasurer
    package var symbols: any SymbolProvider

    package init(_ mode: Mode, textMeasurer: any TextMeasurer = TypesetTextMeasurer.shared,
                 symbols: any SymbolProvider = StubSymbolProvider()) {
        self.mode = mode
        self.textMeasurer = textMeasurer
        self.symbols = symbols
    }
}

@MainActor
package final class ViewGraph {
    private var rootView: any View
    private var rootViewChanged = true
    package private(set) var root: ViewNode?

    /// The environment at the root (platform values; `08` §1).
    package var environment: EnvironmentValues {
        didSet { if environment.revision != oldValue.revision { needsUpdate = true } }
    }

    package var layout: HostLayout? { didSet { needsUpdate = true } }
    package private(set) var layoutResult: LayoutResult?

    /// The root's reduced preference values after the last pass.
    package private(set) var rootPreferences = PreferenceValues()

    package private(set) var needsUpdate = true
    private var pendingTransaction: Transaction?
    /// Passes run so far.
    package private(set) var passCount = 0
    /// Bound on passes per `update()` (actions that keep writing).
    package var maxPassesPerUpdate = 16

    // Animation (R6).
    package let timeSource: any AnimationTimeSource
    /// The time of the current pass or frame.
    package private(set) var currentTime: TimeInterval = 0
    /// The transaction of the current pass (empty for frame passes).
    package private(set) var passTransaction = Transaction()
    /// Incremented by every lowering of the tree (stable creator indices).
    package private(set) var lowerGeneration = 0
    /// Display frames rendered so far.
    package private(set) var frameCount = 0
    private var drivers: [any AnimationDriver] = []
    private var driverIDs: Set<ObjectIdentifier> = []
    private var completionQueue: [() -> Void] = []
    private var passRecords: [AnimationCompletionRecord] = []
    private var passRecordIDs: Set<ObjectIdentifier> = []
    /// Removed views still rendered while their removal transition runs.
    package private(set) var ghosts: [Ghost] = []
    /// Views with `matchedGeometryEffect`.
    private var matched: [MatchedGeometryState] = []

    private var appearQueue: [() -> Void] = []
    private var disappearQueue: [() -> Void] = []
    private var geometryActions: [() -> Void] = []
    private var preferenceActions: [() -> Void] = []

    /// Optional observer of body evaluations (tests).
    package var onBodyEvaluation: ((ViewNode) -> Void)?

    package init<V: View>(rootView: V, environment: EnvironmentValues = EnvironmentValues(), layout: HostLayout? = nil,
                          timeSource: (any AnimationTimeSource)? = nil) {
        self.rootView = rootView
        self.environment = environment
        self.layout = layout
        self.timeSource = timeSource ?? ManualAnimationClock()
    }

    /// The manual clock, when the graph runs on one (headless host).
    package var clock: ManualAnimationClock? { timeSource as? ManualAnimationClock }

    // MARK: Driving

    package func setRootView<V: View>(_ view: V) {
        rootView = view
        rootViewChanged = true
        needsUpdate = true
    }

    package func updateEnvironment(_ body: (inout EnvironmentValues) -> Void) {
        body(&environment)
    }

    /// Runs update passes until nothing is pending.
    package func update() {
        var passes = 0
        while needsUpdate && passes < maxPassesPerUpdate {
            runPass()
            passes += 1
        }
    }

    /// Runs exactly one pass if one is pending.
    package func step() {
        if needsUpdate { runPass() }
    }

    package func scheduleUpdate(transaction: Transaction) {
        needsUpdate = true
        if pendingTransaction == nil || !transaction.isEmpty {
            var t = transaction
            if let completions = pendingTransaction?.completions, !completions.isEmpty {
                t.completions = completions + t.completions
            }
            pendingTransaction = t
        }
    }

    package func noteBodyEvaluation(_ node: ViewNode) { onBodyEvaluation?(node) }

    // MARK: Animation drivers and completions (R6)

    package func activate(_ driver: any AnimationDriver) {
        if driverIDs.insert(ObjectIdentifier(driver)).inserted { drivers.append(driver) }
    }

    /// True if anything is animating (an active driver or a removal
    /// transition in progress).
    package var isAnimating: Bool { drivers.contains { $0.isActive } || !ghosts.isEmpty }

    /// True if a driver of a node in `node`'s subtree is active.
    package func hasActiveDrivers(in node: ViewNode) -> Bool {
        drivers.contains { d in d.isActive && (d.owner.map { $0.isDescendant(of: node) } ?? false) }
    }

    /// Completion records of transactions seen in this pass (sealed at its end).
    package func noteCompletions(_ records: [AnimationCompletionRecord]) {
        for r in records where passRecordIDs.insert(ObjectIdentifier(r)).inserted { passRecords.append(r) }
    }

    package func queueCompletion(_ action: @escaping () -> Void) { completionQueue.append(action) }

    private func runCompletions() {
        while !completionQueue.isEmpty {
            let q = completionQueue
            completionQueue = []
            for c in q { c() }
        }
    }

    // MARK: Frames (R6)

    /// Renders one display frame at the time source's current time.
    package func renderFrame() {
        frameCount += 1
        update()
        currentTime = timeSource.now
        var changed: [() -> Void] = []
        var kept: [any AnimationDriver] = []
        for d in drivers {
            if let o = d.owner, !o.isAlive {
                d.cancel()
            } else if d.sample(at: currentTime), let f = d.onChange {
                changed.append(f)
            }
            if d.isActive { kept.append(d) } else { driverIDs.remove(ObjectIdentifier(d)) }
        }
        drivers = kept
        let ended = ghosts.filter { g in !(g.parent?.isAlive ?? false) || !hasActiveDrivers(in: g.node) }
        if !changed.isEmpty || !ended.isEmpty {
            passCount += 1
            passTransaction = Transaction()
            for f in changed { f() }
            ghosts.removeAll { g in ended.contains { $0.node === g.node } }
            for g in ended { g.node.teardown() }
            finishPass(animatedGeometry: false)
        } else {
            runCompletions()
        }
        update()
    }

    /// Advances the manual clock by `frames` display frames, rendering each.
    package func advance(frames: Int = 1) {
        guard let clock else { return }
        for _ in 0..<frames {
            clock.advance()
            renderFrame()
        }
    }

    /// Advances the manual clock by about `seconds` (whole frames).
    package func advance(seconds: TimeInterval) {
        guard let clock else { return }
        advance(frames: Int((seconds * clock.framesPerSecond).rounded()))
    }

    /// Renders frames until nothing animates (bounded).
    package func settle(maxFrames: Int = 3600) {
        var n = 0
        while isAnimating && n < maxFrames {
            advance()
            n += 1
        }
    }

    // MARK: Removal transitions (R6)

    /// A removed view that stays rendered until its removal transition ends.
    package struct Ghost {
        package let node: ViewNode
        package weak var parent: ViewNode?
        /// Where its layout nodes were last placed (parent transform in root
        /// coordinates, local origin, size, proposal).
        package let placements: [(parent: AffineTransform2D, origin: CGPoint, size: CGSize, proposal: ProposedViewSize)]
    }

    package func registerMatched(_ state: MatchedGeometryState) { matched.append(state) }

    package func matchedStates() -> [MatchedGeometryState] {
        matched.removeAll { !($0.node?.isAlive ?? false) }
        return matched
    }

    package func addGhost(_ node: ViewNode) {
        var placements: [(AffineTransform2D, CGPoint, CGSize, ProposedViewSize)] = []
        for n in node.lastLowered {
            guard let t = n.placedTransform, let o = n.placedLocalOrigin, let s = n.placedSize,
                  let p = n.placedProposal else { continue }
            placements.append((t.concatenating(.translation(-o.x, -o.y)), o, s, p))
        }
        ghosts.append(Ghost(node: node, parent: node.parent, placements: placements))
    }

    // MARK: Lifecycle queues

    package func queueAppear(_ action: @escaping () -> Void) { appearQueue.append(action) }
    package func queueDisappear(_ action: @escaping () -> Void) { disappearQueue.append(action) }
    package func queueGeometryAction(_ action: @escaping () -> Void) { geometryActions.append(action) }
    package func queuePreferenceAction(_ action: @escaping () -> Void) { preferenceActions.append(action) }

    // MARK: The pass

    private func runPass() {
        needsUpdate = false
        passCount += 1
        currentTime = timeSource.now
        let transaction = pendingTransaction ?? Transaction()
        pendingTransaction = nil
        passTransaction = transaction
        noteCompletions(transaction.completions)

        // 2. Bodies.
        if let root {
            root.update(rootViewChanged ? rootView : nil, environment: environment, transaction: transaction)
        } else {
            let r = ViewNode(graph: self, parent: nil, view: rootView)
            root = r
            r.update(rootView, environment: environment, transaction: transaction)
        }
        rootViewChanged = false
        // Removed views still transitioning out receive the update walk too.
        for g in ghosts where g.node.isAlive {
            g.node.update(nil, environment: g.node.environment, transaction: transaction)
        }
        finishPass(animatedGeometry: true)
    }

    private func finishPass(animatedGeometry: Bool) {
        // 3. Lifecycle.
        let appear = appearQueue
        appearQueue = []
        for a in appear.reversed() { a() }
        let disappear = disappearQueue
        disappearQueue = []
        for d in disappear.reversed() { d() }

        // 4. Layout.
        if let layout { performLayout(layout, animated: animatedGeometry) }

        // 5. Geometry and preferences.
        let geo = geometryActions
        geometryActions = []
        for g in geo { g() }
        rootPreferences = root?.preferenceValues() ?? PreferenceValues()
        let prefs = preferenceActions
        preferenceActions = []
        for p in prefs { p() }

        // Completions: the pass's transactions are complete; handlers whose
        // animations are done (or that started none) run now.
        let records = passRecords
        passRecords = []
        passRecordIDs = []
        for r in records { r.seal(graph: self) }
        runCompletions()
    }

    // MARK: Layout

    /// The root's layout node (several root views are stacked vertically).
    /// Starts a lowering (creator indices restart in every node).
    package func beginLowering() { lowerGeneration += 1 }

    package func rootLayoutNode() -> LayoutNode {
        beginLowering()
        let nodes = root?.lower() ?? []
        if nodes.count == 1 { return nodes[0] }
        if nodes.isEmpty { return .empty() }
        return .vstack(nodes)
    }

    private func performLayout(_ layout: HostLayout, animated: Bool) {
        let node = rootLayoutNode()
        let engine = LayoutEngine(environment: environment, textMeasurer: layout.textMeasurer, symbols: layout.symbols)
        let result: LayoutResult
        switch layout.mode {
        case .window(let size, let insets): result = engine.layout(node, window: size, safeAreaInsets: insets)
        case .proposal(let p): result = engine.layout(node, proposal: p)
        }
        layoutResult = result
        node.forEachNode { n in
            guard let owner = n.owner as? ViewNode, owner.isAlive, let frame = result.frame(of: n) else { return }
            let g = NodeGeometry(size: n.placedSize ?? frame.size, frame: frame, safeAreaInsets: result.safeAreaInsets(of: n))
            if let observer = owner.primitiveState as? GeometryObserving {
                observer.geometryChanged(g, node: owner)
            }
            owner.geometry = g
        }
        // Layout geometry of every created node, animated per the
        // transaction that reached its view (R6).
        node.forEachNode { n in
            guard let creator = n.creator as? ViewNode, creator.isAlive, let o = n.placedLocalOrigin,
                  let s = n.placedSize else { return }
            let r = CGRect(origin: o, size: s)
            guard r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite else { return }
            creator.recordFrame(index: n.creatorIndex, r,
                                transaction: animated ? creator.transactionForSelf() : Transaction())
        }
        if !matched.isEmpty { updateMatchedGeometry(animated: animated) }
    }

    /// Frames of named layout nodes from the last layout pass.
    package func frame(named name: String) -> CGRect? { layoutResult?.namedFrames[name] }

    // MARK: One-shot lowering

    /// Builds the view once (bodies only) and returns its layout node: the
    /// bridge from views to the R3 engine used by the view-built golden
    /// layout tests.
    package static func layoutNode<V: View>(for view: V, environment: EnvironmentValues = EnvironmentValues()) -> LayoutNode {
        let g = ViewGraph(rootView: view, environment: environment)
        g.update()
        return g.rootLayoutNode()
    }
}

/// Primitive state that wants to hear about layout geometry.
@MainActor
package protocol GeometryObserving: AnyObject {
    func geometryChanged(_ geometry: NodeGeometry, node: ViewNode)
}
