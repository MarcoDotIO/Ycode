import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// The application host (round R7): runs an `App` on a platform back end.
//
// Launch, in the order the reference showed (06 §1):
//   App.init → adaptor delegate didFinishLaunching (application in the
//   background) → App.body (scenePhase .background) → the first scene's
//   window is connected → App and scene phase .inactive (App.body again;
//   willEnterForeground) → the window's root view body, onAppear, task →
//   phase .active, App first, then the views (didBecomeActive) → first frame.
//
// Phases on the Linux desktop (our mapping): the application and its windows
// share one phase. While a window is shown the phase is active; when every
// window is minimised or hidden it goes through inactive to background;
// restoring one goes through inactive to active. Losing keyboard focus does not change the phase (as on
// desktop systems).
// `openURL` events go to the `onOpenURL` handlers without a confirmation
// (the reference's "Open in …?" prompt is SpringBoard's; `openURL(_:
// confirming: true)` reproduces its inactive → URL → active order). Closing
// the last window quits; quitting goes through inactive and background and
// then calls the delegates' willTerminate.
//
// Frames: each window's graph is driven by the run loop's display link; the
// window's root environment carries the scene phase, display scale, the
// window services (focus, shortcuts, text input, clipboard) and the window
// actions.

/// The animation clock of a host: the display link's frame time inside a
/// frame, the back end's clock otherwise.
@MainActor
package final class HostClock: AnimationTimeSource {
    unowned let backend: any PlatformBackend
    var frameTime: TimeInterval?
    init(backend: any PlatformBackend) { self.backend = backend }
    package var now: TimeInterval { frameTime ?? backend.now }
}

/// Evaluates `App.body` as the body of a graph node, so the app's `@State`,
/// `@Environment(\.scenePhase)` and other dynamic properties work as in a
/// view; hands each evaluation's scenes to the host.
struct AppRootView<A: App>: View, PrimitiveView {
    let app: A
    let host: AppHost
    typealias Body = Never

    private func evaluate(_ node: ViewNode, inputsChanged: Bool, _ transaction: Transaction) {
        let app = app, host = host
        node.updateTracked(inputs: app, inputsChanged: inputsChanged, transaction: transaction) {
            host.log?("App.body")
            host.receive(SceneCollector.collect(app.body))
            return EmptyView()
        }
    }

    func _makeChildren(node: ViewNode, old: AppRootView?, transaction: Transaction) {
        evaluate(node, inputsChanged: old == nil, transaction)
    }

    func _refresh(node: ViewNode, environmentChanged: Bool, transaction: Transaction) {
        evaluate(node, inputsChanged: false, transaction)
    }
}

extension AppRootView: GraphInputComparable {
    nonisolated func _isGraphInputEqual(to other: Any) -> Bool { true }
}

/// The root of a window's graph: the scene's content, with the window's
/// chrome (menu bar, toolbar; R11), its commands host, presentations and
/// pop-up overlays.
struct WindowRootView: View, PrimitiveView {
    let content: any View
    /// Pop-ups shown inside the window (when the window system refused a
    /// pop-up window; Popups.swift).
    var overlays: OverlayPopupLayer?
    typealias Body = Never

    /// Sheets, covers, alerts and dialogs (R9, Presentation.swift).
    var presentations: PresentationCenter?
    /// The chrome of a main window (R11); nil for pop-ups.
    var chrome: WindowChromeConfiguration?
    /// The app's commands, evaluated in this window (R11).
    var commands: [any Commands] = []
    /// The window's tooltip (R13).
    var tooltips: TooltipCenter?

    func _makeChildren(node: ViewNode, old: WindowRootView?, transaction: Transaction) {
        var items: [(AnyHashable, any View)] = [(AnyHashable(0), content)]
        if let chrome {
            items.append((AnyHashable("top"), WindowTopChrome(configuration: chrome)))
            items.append((AnyHashable("bottom"), WindowBottomChrome()))
            if chrome.menuBar || !commands.isEmpty {
                items.append((AnyHashable("commands"), CommandsHostView(commands: commands, model: chrome.commands, actions: chrome.actions)))
            }
        }
        if let p = presentations, !p.isEmpty {
            items.append((AnyHashable(2), PresentationLayer(center: p, entries: p.entries)))
        }
        if let overlays { items.append((AnyHashable(1), overlays)) }
        if let tooltips { items.append((AnyHashable("tooltip"), TooltipLayer(center: tooltips))) }
        node.reconcileChildren(items, transaction: transaction)
    }

    func _lower(node: ViewNode) -> [LayoutNode] {
        var base: LayoutNode?
        var top: [LayoutNode] = [], bottom: [LayoutNode] = []
        var layers: [LayoutNode] = []
        for (key, c) in zip(node.childKeys, node.children) {
            switch key {
            case AnyHashable(0):
                let content = c.lower()
                base = content.count == 1 ? content[0] : (content.isEmpty ? .empty() : .vstack(content))
            case AnyHashable("top"): top = c.lower()
            case AnyHashable("bottom"): bottom = c.lower()
            case AnyHashable("commands"): break
            default:
                if let layer = c.lower().first { layers.append(layer) }
            }
        }
        var root = base ?? .empty()
        if !top.isEmpty || !bottom.isEmpty {
            root = .vstack(spacing: 0, top + [root.frame(maxWidth: .infinity, maxHeight: .infinity)] + bottom)
        }
        for l in layers { root = root.overlay(l, alignment: .center) }
        return [root]
    }
}

/// The menu bar and the window toolbar (they lower to nothing when hidden).
struct WindowTopChrome: View {
    let configuration: WindowChromeConfiguration
    @Environment(\._windowServices) private var services
    var body: some View {
        if configuration.menuBar {
            MenuBarView(model: configuration.commands, actions: configuration.actions)
        }
        if let toolbar = services?.toolbar {
            WindowToolbarView(model: toolbar)
        }
    }
}

/// The bottom bar (`ToolbarItemPlacement.bottomBar` outside navigation).
struct WindowBottomChrome: View {
    @Environment(\._windowServices) private var services
    var body: some View {
        if let toolbar = services?.toolbar {
            WindowToolbarView(model: toolbar, bottom: true)
        }
    }
}

/// One window of the application: its graph, input routing and frames.
@MainActor
package final class WindowHost {
    package let platform: any PlatformWindow
    package let graph: ViewGraph
    package let gestures: GestureEngine
    package let services: WindowServices
    package let sceneIndex: Int
    package let sceneID: String?
    package private(set) var phase: ScenePhase = .background
    /// Minimised or hidden by the window system.
    package var isMinimized = false
    package var presenter: (any FramePresenter)?
    /// Frames presented so far.
    package private(set) var presentedFrames = 0
    private var needsDisplay = true
    private var pressedPointers: Set<Int> = []
    private var baseEnvironment: EnvironmentValues
    private var content: any View
    // Pop-ups (R8, Popups.swift).
    package internal(set) var isPopup = false
    package internal(set) weak var popupOwner: WindowHost?
    /// Where the pop-up was placed (points of its owner; R11 screenshots).
    package internal(set) var popupOrigin = CGPoint.zero
    var popupHandle: PopupHandle?
    var popupOnDismiss: (() -> Void)?
    package internal(set) var overlayPopups: [OverlayPopup] = [] { didSet { refreshRoot() } }
    /// Menu bar and toolbar (R11); nil for pop-ups.
    var chrome: WindowChromeConfiguration? { didSet { refreshRoot() } }
    /// The app's commands evaluated in this window (R11).
    var commands: [any Commands] = []
    /// The window's focused values (R11).
    package let focusedValues: FocusedValuesCenter
    /// The scene storage of the window (R10).
    package let sceneStorage: SceneStorageStore

    init(platform: any PlatformWindow, sceneIndex: Int, sceneID: String?, content: any View,
         environment: EnvironmentValues, clock: HostClock, presenter: (any FramePresenter)?,
         chrome: WindowChromeConfiguration? = nil, commands: [any Commands] = [],
         sceneStorage: SceneStorageStore? = nil) {
        self.platform = platform
        self.sceneIndex = sceneIndex
        self.sceneID = sceneID
        services = WindowServices()
        baseEnvironment = environment
        self.content = content
        self.chrome = chrome
        self.commands = commands
        let focused = environment._focusedValues ?? FocusedValuesCenter()
        focusedValues = focused
        self.sceneStorage = sceneStorage ?? environment._sceneStorage ?? SceneStorageStore()
        var env = environment
        env._windowServices = services
        env._focusedValues = focused
        env._sceneStorage = self.sceneStorage
        env.displayScale = platform.scale
        env.scenePhase = .background
        var symbols = OpenSymbolProvider()
        symbols.displayScale = platform.scale
        graph = ViewGraph(rootView: WindowRootView(content: content, presentations: services.presentations, chrome: chrome,
                                                   commands: commands, tooltips: services.tooltips), environment: env,
                          layout: HostLayout(.window(platform.size, safeAreaInsets: EdgeInsets()), symbols: symbols),
                          timeSource: clock)
        gestures = GestureEngine(graph: graph)
        self.presenter = presenter
        services.presentations.onChange = { [weak self] in self?.refreshRoot() }
        services.focus.onTextClientChanged = { [weak self] client in
            guard let self else { return }
            if let client { self.platform.startTextInput(caretRect: client.caretRect) } else { self.platform.stopTextInput() }
        }
    }

    package var size: CGSize { platform.size }

    private func rootView() -> WindowRootView {
        WindowRootView(content: content, overlays: overlayPopups.isEmpty ? nil
                       : OverlayPopupLayer(items: overlayPopups, windowSize: platform.size),
                       presentations: services.presentations, chrome: chrome, commands: commands,
                       tooltips: isPopup ? nil : services.tooltips)
    }

    private func refreshRoot() { graph.setRootView(rootView()) }

    func setContent(_ content: any View, environment: EnvironmentValues, commands: [any Commands]? = nil) {
        self.content = content
        if let commands { self.commands = commands }
        graph.setRootView(rootView())
        baseEnvironment = environment
        graph.updateEnvironment { env in
            let phase = env.scenePhase, scale = env.displayScale
            env = environment
            env._windowServices = self.services
            env._focusedValues = self.focusedValues
            env._sceneStorage = self.sceneStorage
            env.scenePhase = phase
            env.displayScale = scale
        }
    }

    /// Applies new desktop settings to the window's environment (R10).
    func applySettings(_ apply: @escaping (inout EnvironmentValues) -> Void) {
        apply(&baseEnvironment)
        graph.updateEnvironment(apply)
    }

    func setPhase(_ p: ScenePhase) {
        guard p != phase else { return }
        phase = p
        graph.updateEnvironment { $0.scenePhase = p }
    }

    /// Runs pending updates (bodies, layout) and applies focus changes.
    package func update() {
        graph.update()
        services.focus.sync()
        if !isPopup { focusedValues.recompute(focused: services.focus.focusedNode) }
        if graph.needsUpdate {
            graph.update()
            services.focus.sync()
            if !isPopup { focusedValues.recompute(focused: services.focus.focusedNode) }
        }
    }

    var needsFrame: Bool { graph.needsUpdate || graph.isAnimating || needsDisplay }
    var timerDeadline: TimeInterval? {
        [gestures.deadline, services.nextTimerDeadline].compactMap { $0 }.min()
    }

    func renderFrame() {
        let passes = graph.passCount
        // An animation frame changes presented values without a pass (render
        // effects, layout geometry): it must be presented too (QA B1). The
        // frame in which the last animation ends is presented as well.
        let animating = graph.isAnimating
        graph.renderFrame()
        services.focus.sync()
        if !isPopup { focusedValues.recompute(focused: services.focus.focusedNode) }
        if graph.needsUpdate { update() }
        if animating || passes != graph.passCount || needsDisplay {
            needsDisplay = false
            presentedFrames += 1
            presenter?.present(self)
        }
    }

    func teardown() {
        gestures.cancel()
        graph.setRootView(EmptyView())
        graph.update()
        presenter?.invalidate()
    }

    // MARK: Input

    private func sample(_ p: PointerEvent) -> PointerSample {
        let phase: PointerSample.Phase
        switch p.phase {
        case .down: phase = .down
        case .moved: phase = .moved
        case .up: phase = .up
        case .cancelled: phase = .cancelled
        }
        return PointerSample(pointer: p.pointer, phase: phase, location: p.location, time: p.timestamp,
                             isTouch: p.kind == .touch)
    }

    func handlePointer(_ p: PointerEvent) {
        // R11: a secondary click opens a context menu.
        if p.kind == .mouse && p.button == 3 && p.phase == .down {
            services.pointerModifiers = p.modifiers
            gestures.pointer(sample(PointerEvent(window: p.window, phase: .moved, location: p.location, button: 0,
                                                 isPressed: false, timestamp: p.timestamp)), isPressed: false)
            openContextMenu(at: p.location)
            return
        }
        // Only the primary button (and touches) drive gestures; other
        // buttons still move the hover.
        if p.kind == .mouse && p.button > 1 && p.phase != .moved {
            if pressedPointers.isEmpty {
                gestures.pointer(sample(PointerEvent(window: p.window, phase: .moved, location: p.location, button: 0,
                                                     isPressed: false, timestamp: p.timestamp)), isPressed: false)
            }
            return
        }
        trackContextPress(p)
        services.pointerModifiers = p.modifiers
        services.lastEventTime = p.timestamp
        if p.phase == .down { services.tooltips.dismiss() }
        // Layout must be current before hit testing a press.
        if p.phase == .down && graph.needsUpdate { update() }
        switch p.phase {
        case .down: pressedPointers.insert(p.pointer)
        case .up, .cancelled: pressedPointers.remove(p.pointer)
        case .moved: break
        }
        gestures.pointer(sample(p), isPressed: !pressedPointers.isEmpty)
    }

    /// Keys of a pop-up window: Escape (and Left in a submenu) closes it,
    /// Up and Down move between items.
    var onPopupKey: ((KeyEvent) -> Bool)?
    /// Keys of a pop-up that its items did not use (the menu bar's Left and
    /// Right, R11).
    var onPopupFallbackKey: ((KeyEvent) -> Bool)?

    /// The text event that follows a key press an `onKeyPress` handler
    /// used is dropped (R13).
    private var suppressNextText = false

    func handleKey(_ k: KeyEvent) {
        services.lastEventTime = k.timestamp
        if k.isDown { suppressNextText = false }
        // R13: `onKeyPress` handlers around the focused view come first.
        if KeyPressDispatch.deliver(k, focused: services.focus.focusedNode) {
            if k.isDown, case .character = k.key, !k.modifiers.contains(.control), !k.modifiers.contains(.command) {
                suppressNextText = true
            } else if k.isDown, k.key == .space {
                suppressNextText = true
            }
            return
        }
        guard k.isDown else { return }
        services.tooltips.dismiss()
        if let client = services.focus.focusedClient, client.handleKey(k) { return }
        if let h = onPopupKey, h(k) { return }
        if let handler = services.focus.focusedKeyHandler, handler(k) { return }
        if let h = onPopupFallbackKey, h(k) { return }
        // R11: F10 opens the menu bar, Shift+F10 the focused view's context
        // menu.
        if k.key == .function(10) {
            if k.modifiers.contains(.shift) {
                if openContextMenuForFocus() { return }
            } else if let bar = services.menuBar, !k.modifiers.contains(.control), !k.modifiers.contains(.command) {
                // (Alt is ignored: some X keymaps deliver F10 with it.)
                bar.openFirst()
                return
            }
        }
        if services.shortcuts.perform(key: k.key, modifiers: k.modifiers) { return }
        if k.key == .tab {
            services.focus.focusNext(in: graph.root, reverse: k.modifiers.contains(.shift))
        } else if k.key == .escape, services.focus.focusedNode != nil {
            services.focus.focus(nil)
        }
    }

    func handleText(_ t: TextInputEvent) {
        if suppressNextText {
            suppressNextText = false
            return
        }
        services.focus.focusedClient?.insertText(t.text)
    }

    func handleEditing(_ e: TextEditingEvent) {
        services.focus.focusedClient?.setMarkedText(e.text, cursor: e.cursor)
    }

    func handleScroll(_ s: ScrollEvent) {
        if graph.needsUpdate { update() }
        gestures.scroll(delta: s.delta, at: s.location)
    }

    /// Safe-area insets of the window's content (none on desktop windows;
    /// tests set the reference phone's).
    package var safeAreaInsets = EdgeInsets() {
        didSet { resized(to: platform.size) }
    }

    func resized(to size: CGSize) {
        graph.layout = HostLayout(.window(size, safeAreaInsets: safeAreaInsets), symbols: graph.layout?.symbols ?? StubSymbolProvider())
        presenter?.surfaceDidResize()
        needsDisplay = true
    }

    func scaleChanged(_ s: Double) {
        graph.updateEnvironment { $0.displayScale = s }
        presenter?.surfaceDidResize()
        needsDisplay = true
    }

    func exposed() { needsDisplay = true }
    func pointerLeft() { gestures.pointerLeft() }

    /// Delivers a URL to the window's `onOpenURL` handlers; false if none.
    func deliver(_ url: URL) -> Bool {
        let handlers = services.urlHandlers
        for h in handlers { h.action(url) }
        return !handlers.isEmpty
    }
}

/// Runs an `App`.
@MainActor
package final class AppHost: RunLoopClient {
    package let backend: any PlatformBackend
    package let runLoop: PlatformRunLoop
    package let clock: HostClock
    package private(set) var appGraph: ViewGraph?
    package private(set) var windows: [WindowHost] = []
    package private(set) var scenes: [SceneDescription] = []
    package private(set) var appPhase: ScenePhase = .background
    /// Tracing of host events (tests, samples).
    package var log: ((String) -> Void)?
    /// Default window size when a scene sets none.
    package var defaultWindowSize = CGSize(width: 800, height: 600)
    /// Desktop text input (no auto-capitalisation) — true on window-system
    /// back ends, false on the headless one (which mirrors the reference).
    package var desktopTextInput: Bool
    /// Makes each window's frame presenter (nil: frames are not drawn).
    package var makePresenter: (any PlatformWindow) -> (any FramePresenter)? = { CompositorPresenter(window: $0) }
    /// Whether windows are created for Vulkan: `OV_RENDERER=vulkan`,
    /// `software`, or `auto` (the default: Vulkan when a Vulkan compositor
    /// can present to the window, else the software compositor).
    package var renderer = ProcessInfo.processInfo.environment["OV_RENDERER"]?.lowercased() ?? "auto"
    package private(set) var isFinished = false
    /// Main windows show a menu bar (R11): on window-system back ends by
    /// default, not on the headless one (whose windows keep the reference
    /// phone's geometry); `OV_MENU_BAR=0|1` overrides. Set before `launch()`.
    package var showsMenuBar: Bool
    /// The application's name (menu titles): `OV_APP_NAME`, the bundle name,
    /// else the process name. Read when first used (after the `App` value is
    /// made), so an app's initializer can set `OV_APP_NAME` for itself.
    package lazy var appName: String = {
        let env = ProcessInfo.processInfo.environment
        if let n = env["OV_APP_NAME"], !n.isEmpty { return n }
        if let n = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, !n.isEmpty { return n }
        return ProcessInfo.processInfo.processName
    }()
    /// Ends with a user quit (R10: scene storage is discarded then).
    package private(set) var quitByUser = false
    /// Scene storage archives (R10, SceneStorage.swift).
    package var sceneArchive: SceneStorageArchive?
    /// The window that has keyboard focus, as the window system last said.
    package private(set) var activeWindowID: PlatformWindowID?
    /// True once the window system reported a focus change.
    package private(set) var windowFocusKnown = false
    /// The AT-SPI export (R10; ATSPIBridge.swift), when an accessibility
    /// bus exists.
    package var accessibilityExport: AccessibilityExport?

    private var delegates: [any AppDelegateAdaptorProtocol] = []
    private var makeRoot: ((AppHost) -> any View)?
    private var previousObserverValues: [String: Any] = [:]
    private var pendingURLs: [URL] = []
    private var launched = false

    package init<A: App>(_ type: A.Type, backend: any PlatformBackend, urls: [URL] = []) {
        self.backend = backend
        clock = HostClock(backend: backend)
        runLoop = PlatformRunLoop(backend: backend)
        desktopTextInput = !(backend is HeadlessBackend)
        let menuBarSetting = ProcessInfo.processInfo.environment["OV_MENU_BAR"]
        showsMenuBar = menuBarSetting.map { $0 != "0" } ?? !(backend is HeadlessBackend)
        pendingURLs = urls
        makeRoot = { host in
            host.log?("App.init")
            let app = A()
            host.delegates = Mirror(reflecting: app).children.compactMap { $0.value as? any AppDelegateAdaptorProtocol }
            return AppRootView(app: app, host: host)
        }
    }

    /// `App.main()`: the default back end, URLs from the command line, run
    /// until quit.
    /// The host `App.main()` created (samples and tools find it here).
    package private(set) static weak var current: AppHost?

    package static func runMain<A: App>(_ type: A.Type) {
        let backend = Platform.makeDefaultBackend()
        let urls = CommandLine.arguments.dropFirst().compactMap { a -> URL? in
            guard a.contains("://"), let u = URL(string: a) else { return nil }
            return u
        }
        let host = AppHost(type, backend: backend, urls: urls)
        current = host
        if ProcessInfo.processInfo.environment["OV_TRACE"] != nil {
            host.log = { FileHandle.standardError.write(Data("[ov] \($0)\n".utf8)) }
        }
        if !(backend is HeadlessBackend) { host.sceneArchive = SceneStorageArchive.forCurrentProcess() }
        host.launch()
        host.accessibilityExport = AccessibilityExport.start(host: host)
        if backend is HeadlessBackend && ProcessInfo.processInfo.environment["OV_PLATFORM"] != "headless" {
            FileHandle.standardError.write(Data("OpenViews: no display back end (libSDL3 or a display); ran headless\n".utf8))
            host.terminate()
        } else {
            host.run()
        }
        backend.shutdown()
    }

    // MARK: Launch and phases

    private func environment(for sceneIndex: Int?) -> EnvironmentValues {
        var env = EnvironmentValues()
        env.scenePhase = appPhase
        env._defaultAutocapitalization = desktopTextInput ? .never : .sentences
        env._desktopChrome = desktopTextInput
        env._desktopTextStyles = desktopTextInput
        env.openWindow = OpenWindowAction { [weak self] id in self?.openWindow(id: id) }
        env.openSettings = OpenSettingsAction { [weak self] in self?.openSettings() }
        PlatformEnvironment.apply(backend.settings, to: &env)
        if let i = sceneIndex, scenes.indices.contains(i) {
            for t in scenes[i].environment { t(&env) }
        }
        return env
    }

    private func deliver(_ event: AppLifecycleEvent) {
        if case .openURLs = event {} else { log?("delegate \(event)") }
        for d in delegates { d._deliver(event) }
    }

    /// Creates the app and connects its first scene (06 §1 order).
    package func launch() {
        guard !launched, let makeRoot else { return }
        launched = true
        OpenURLAction.systemOpener = { [weak self] url in self?.backend.openExternally(url) ?? false }
        UIApplication.shared.applicationState = .background
        let root = makeRoot(self)
        deliver(.didFinishLaunching)
        let graph = ViewGraph(rootView: root, environment: environment(for: nil))
        appGraph = graph
        graph.update()
        // The first scene that is not a Settings scene opens at launch.
        if let first = scenes.indices.first(where: { scenes[$0].kind != .settings }) { openWindow(sceneIndex: first) }
        setAppPhase(.inactive)
        setAppPhase(.active)
        let urls = pendingURLs
        pendingURLs = []
        for u in urls { openURL(u) }
    }

    /// Moves the application (and every window that is not in the
    /// background on its own) to `phase`, App first.
    package func setAppPhase(_ phase: ScenePhase) {
        guard phase != appPhase else { return }
        let old = appPhase
        if old == .active { deliver(.willResignActive) }
        appPhase = phase
        UIApplication.shared.applicationState = UIApplication.State(phase)
        log?("App scenePhase \(phase)")
        appGraph?.updateEnvironment { $0.scenePhase = phase }
        appGraph?.update()
        // 06 §1: App.body, the App's phase, willEnterForeground, then the
        // scene's views.
        if old == .background { deliver(.willEnterForeground) }
        for w in windows {
            w.setPhase(phase)
            w.update()
        }
        if phase == .background {
            // R10: scene storage is archived when the app goes to the
            // background (09-open-design.md §4).
            for w in windows where !w.isPopup { sceneArchive?.save(w.sceneStorage) }
            deliver(.didEnterBackground)
        }
        if phase == .active { deliver(.didBecomeActive) }
    }

    /// Receives the scenes of an App.body evaluation.
    func receive(_ new: [SceneDescription]) {
        scenes = new
        let commands = allCommands
        for w in windows where !w.isPopup && scenes.indices.contains(w.sceneIndex) {
            w.setContent(scenes[w.sceneIndex].content(), environment: windowEnvironment(w.sceneIndex, window: w),
                         commands: commands)
        }
        // Scene-level onChange(of:).
        for (i, s) in scenes.enumerated() {
            for (j, o) in s.changeObservers.enumerated() {
                let key = "\(i).\(j)"
                if let old = previousObserverValues[key] {
                    if !o.equal(old, o.value) { o.action(old, o.value) }
                } else if o.initial {
                    o.action(o.value, o.value)
                }
                previousObserverValues[key] = o.value
            }
        }
    }

    private func windowEnvironment(_ sceneIndex: Int, window: WindowHost? = nil, box: WeakWindowBox? = nil) -> EnvironmentValues {
        var env = environment(for: sceneIndex)
        let b = box ?? WeakWindowBox()
        if let window { b.window = window }
        env.dismissWindow = DismissWindowAction { [weak self] id in
            guard let self else { return }
            if id == nil, let w = b.window { self.closeWindow(w) } else { self.dismissWindow(id: id) }
        }
        if let window { env._appCommands = window.chrome?.actions }
        return env
    }

    /// The commands of every scene (R11: one menu bar for the application).
    package var allCommands: [any Commands] { scenes.flatMap(\.commands) }

    /// The standard menu items' actions for the window in `box`.
    private func commandActions(_ box: WeakWindowBox) -> AppCommandActions {
        let a = AppCommandActions()
        a.appName = appName
        a.quit = { [weak self] in self?.quit() }
        let removed = { (s: SceneDescription) in s.commands.contains { $0 is RemoveDefaultCommands } }
        if let g = scenes.firstIndex(where: { $0.kind == .windowGroup && !removed($0) }) {
            a.newWindow = { [weak self] in self?.openWindow(sceneIndex: g, activate: true) }
        }
        a.closeWindow = { [weak self] in if let w = box.window { self?.closeWindow(w) } }
        if scenes.contains(where: { $0.kind == .settings }) { a.openSettings = { [weak self] in self?.openSettings() } }
        a.minimize = { box.window?.platform.minimize() }
        a.about = { [weak self] in self?.log?("about \(self?.appName ?? "")") }
        a.windows = { [weak self] in
            guard let self else { return [] }
            return self.windows.filter { !$0.isPopup }.map { w in
                (title: self.scenes.indices.contains(w.sceneIndex) ? self.scenes[w.sceneIndex].title : "",
                 isCurrent: w === box.window, activate: { @MainActor in w.platform.activate() })
            }
        }
        a.singleWindows = scenes.enumerated().filter { $0.element.kind == .window && !removed($0.element) }.map { i, s in
            (title: s.title.isEmpty ? (s.id ?? "Window") : s.title,
             open: { @MainActor [weak self] in self?.openWindow(sceneIndex: i, activate: true) })
        }
        return a
    }

    // MARK: Windows

    /// Opens a window for the scene with `id` (nil: the first window group).
    package func openWindow(id: String?) {
        let index = id.flatMap { i in scenes.firstIndex { $0.id == i } } ?? scenes.firstIndex { $0.kind == .windowGroup }
        guard let index else { return }
        if scenes[index].kind != .windowGroup, windows.contains(where: { $0.sceneIndex == index && !$0.isPopup }) { return }
        openWindow(sceneIndex: index)
        windows.last?.setPhase(appPhase)
        windows.last?.update()
    }

    /// Opens a window of a scene; with `activate` from a menu item (the new
    /// window joins the app's phase).
    @discardableResult
    package func openWindow(sceneIndex: Int, activate: Bool) -> WindowHost? {
        let scene = scenes[sceneIndex]
        if scene.kind != .windowGroup, let existing = windows.first(where: { !$0.isPopup && $0.sceneIndex == sceneIndex }) {
            existing.platform.activate()
            return existing
        }
        let w = openWindow(sceneIndex: sceneIndex)
        if activate {
            w?.setPhase(appPhase)
            w?.update()
        }
        return w
    }

    @discardableResult
    package func openWindow(sceneIndex: Int) -> WindowHost? {
        let scene = scenes[sceneIndex]
        let box = WeakWindowBox()
        let isSettings = scene.kind == .settings
        var env = windowEnvironment(sceneIndex, box: box)
        let actions = commandActions(box)
        env._appCommands = actions
        var size = scene.defaultSize ?? defaultWindowSize
        if isSettings && scene.defaultSize == nil {
            // Settings windows take their content's ideal size (Ycode's rule).
            size = idealSize(of: scene.content(), environment: env, minimum: CGSize(width: 360, height: 200))
        }
        var config = WindowConfiguration(title: isSettings && scene.title.isEmpty ? "Settings" : scene.title, size: size,
                                         resizable: isSettings ? false : scene.resizable)
        guard let (pw, presenter) = makeWindow(&config) else {
            log?("window creation failed")
            return nil
        }
        log?("scene connect \(scene.id ?? "#\(sceneIndex)")")
        // R11: main windows get the menu bar; the settings window does not
        // (its commands are the app's, reachable from the main windows).
        let chrome = WindowChromeConfiguration(menuBar: showsMenuBar && !isSettings, commands: CommandsModel(), actions: actions)
        let storageKey = "\(scene.id ?? "#\(sceneIndex)").\(windows.filter { $0.sceneIndex == sceneIndex && !$0.isPopup }.count)"
        let storage = sceneArchive?.restore(key: storageKey) ?? SceneStorageStore()
        storage.archiveKey = storageKey
        env._focusedValues = nil
        let w = WindowHost(platform: pw, sceneIndex: sceneIndex, sceneID: scene.id, content: scene.content(),
                           environment: env, clock: clock, presenter: presenter, chrome: chrome,
                           commands: isSettings ? [] : allCommands, sceneStorage: storage)
        box.window = w
        w.services.clipboard = backend.clipboard
        w.services.popups = WindowPopupPresenter(host: self, window: w)
        windows.append(w)
        return w
    }

    /// The ideal size of a scene's content (Settings windows).
    private func idealSize(of content: any View, environment env: EnvironmentValues, minimum: CGSize) -> CGSize {
        var e = env
        e._windowServices = nil
        let measure = ViewGraph(rootView: AnyView(_fromValue: content) ?? AnyView(EmptyView()), environment: e,
                                layout: HostLayout(.proposal(.unspecified), symbols: StubSymbolProvider()))
        measure.update()
        let s = measure.layoutResult?.size ?? minimum
        measure.setRootView(EmptyView())
        measure.update()
        func ok(_ v: CGFloat, _ m: CGFloat) -> CGFloat { v.isFinite && v > 0 ? max(m, v.rounded(.up)) : m }
        return CGSize(width: min(ok(s.width, minimum.width), 1200), height: min(ok(s.height, minimum.height), 900))
    }

    /// Opens (or raises) the Settings window (R11).
    package func openSettings() {
        guard let i = scenes.firstIndex(where: { $0.kind == .settings }) else { return }
        openWindow(sceneIndex: i, activate: true)
    }

    /// Quit from a menu or a shortcut: a user quit.
    package func quit() {
        quitByUser = true
        terminate()
    }

    /// A platform window and its presenter: a Vulkan window when the renderer
    /// allows it and a Vulkan compositor works for it, else a software one.
    private func makeWindow(_ config: inout WindowConfiguration)
        -> (any PlatformWindow, (any FramePresenter)?)? {
        if renderer != "software" && !(backend is HeadlessBackend) {
            config.vulkan = true
            if let pw = try? backend.makeWindow(config) {
                let p = makePresenter(pw)
                if let cp = p as? CompositorPresenter, cp.compositor == nil {
                    log?("Vulkan compositor unavailable (\(cp.compositorError ?? "?")); using a software window")
                    pw.close()
                } else {
                    return (pw, p)
                }
            }
            config.vulkan = false
        }
        guard let pw = try? backend.makeWindow(config) else { return nil }
        return (pw, makePresenter(pw))
    }

    package func dismissWindow(id: String?) {
        let targets = id.map { i in windows.filter { $0.sceneID == i } } ?? Array(windows.suffix(1))
        for w in targets { closeWindow(w) }
    }

    package func closeWindow(_ w: WindowHost) {
        if w.isPopup {
            closePopup(w)
            return
        }
        guard let i = windows.firstIndex(where: { $0 === w }) else { return }
        log?("window close \(w.sceneID ?? "#\(w.sceneIndex)")")
        for p in windows where p.isPopup && p.popupOwner === w { closePopup(p) }
        w.setPhase(.background)
        // R10: closing a window is the user's choice: its scene storage goes.
        sceneArchive?.discard(key: w.sceneStorage.archiveKey)
        w.teardown()
        w.platform.close()
        windows.removeAll { $0 === w }
        _ = i
        if !windows.contains(where: { !$0.isPopup }) {
            quitByUser = true
            terminate()
        }
    }

    /// Removes a pop-up window from the host (Popups.swift closes it).
    func removeWindow(_ w: WindowHost) { windows.removeAll { $0 === w } }

    func addWindow(_ w: WindowHost) { windows.append(w) }

    package func window(for id: PlatformWindowID) -> WindowHost? { windows.first { $0.platform.id == id } }

    // MARK: URLs and quitting

    /// Hands a URL to the `onOpenURL` handlers (the key window's first).
    /// With `confirming`, the app goes inactive around the delivery, as with
    /// the reference's confirmation prompt (06 §1).
    package func openURL(_ url: URL, confirming: Bool = false) {
        log?("openURL \(url.absoluteString)")
        let wasActive = appPhase == .active
        if confirming && wasActive { setAppPhase(.inactive) }
        deliver(.openURLs([url]))
        for w in windows.reversed() {
            w.update()
            if w.deliver(url) { break }
        }
        if confirming && wasActive { setAppPhase(.active) }
    }

    /// Quits: inactive, background, willTerminate; the run loop then stops.
    package func terminate() {
        guard !isFinished else { return }
        if appPhase == .active { setAppPhase(.inactive) }
        if appPhase == .inactive { setAppPhase(.background) }
        // R10 (06 §8): a user's quit discards the scene storage, as the
        // reference did after a user-initiated termination.
        if quitByUser { sceneArchive?.discardAll() }
        deliver(.willTerminate)
        isFinished = true
        runLoop.stop()
    }

    // MARK: Running

    package func run() { runLoop.run(self) }

    /// Runs until back-end time `deadline` (headless tests).
    package func run(until deadline: TimeInterval) { runLoop.run(self, until: deadline) }

    /// Runs for `seconds` of back-end time.
    package func run(for seconds: TimeInterval) { run(until: backend.now + seconds) }

    package func handle(_ event: PlatformEvent) {
        switch event {
        case .pointer(let p):
            if p.phase == .down, closePopups(outside: p.window, at: p.location) { return }
            window(for: p.window)?.handlePointer(p)
        case .scroll(let s): window(for: s.window)?.handleScroll(s)
        case .key(let k):
            if k.isDown { log?("key \(k.key) \(k.modifiers.rawValue) window \(k.window)") }
            // Keys go to the innermost pop-up open over the window.
            guard var target = window(for: k.window) else { return }
            while let p = windows.last(where: { $0.isPopup && $0.popupOwner === target }) { target = p }
            target.handleKey(k)
        case .textInput(let t): window(for: t.window)?.handleText(t)
        case .textEditing(let e): window(for: e.window)?.handleEditing(e)
        case .openURL(let u): openURL(u)
        case .quit:
            quitByUser = true
            terminate()
        case .settingsChanged: applySettings()
        case .window(let id, let kind):
            guard let w = window(for: id) else { return }
            handleWindowEvent(w, kind)
        }
    }

    private func handleWindowEvent(_ w: WindowHost, _ kind: WindowEventKind) {
        log?("window \(w.platform.id) \(kind)")
        if w.isPopup {
            switch kind {
            case .resized(let s): w.resized(to: s)
            case .scaleChanged(let s): w.scaleChanged(s)
            case .closeRequested, .hidden, .minimized: closePopup(w)
            case .pointerLeft: w.pointerLeft()
            default: w.exposed()
            }
            return
        }
        switch kind {
        case .resized(let s): w.resized(to: s)
        case .scaleChanged(let s): w.scaleChanged(s)
        case .exposed: w.exposed()
        case .closeRequested: closeWindow(w)
        case .pointerLeft: w.pointerLeft()
        case .minimized, .hidden:
            w.isMinimized = true
            for p in windows where p.isPopup && p.popupOwner === w { closePopup(p) }
            if windows.filter({ !$0.isPopup }).allSatisfy(\.isMinimized) {
                // As when the reference switched away: active → inactive → background.
                if appPhase == .active { setAppPhase(.inactive) }
                setAppPhase(.background)
            }
        case .restored, .shown:
            guard w.isMinimized else {
                w.exposed()
                return
            }
            w.isMinimized = false
            w.exposed()
            if appPhase == .background { setAppPhase(.inactive) }
            setAppPhase(.active)
        case .focusGained:
            windowFocusKnown = true
            activeWindowID = w.platform.id
            // No frame follows a change of the active window by itself.
            accessibilityExport?.afterFrame()
        case .focusLost:
            windowFocusKnown = true
            if activeWindowID == w.platform.id { activeWindowID = nil }
            accessibilityExport?.afterFrame()
        }
    }

    /// New desktop settings (R10): every graph's environment follows.
    package func applySettings() {
        let settings = backend.settings
        log?("settings changed")
        let apply: (inout EnvironmentValues) -> Void = { PlatformEnvironment.apply(settings, to: &$0) }
        appGraph?.updateEnvironment(apply)
        for w in windows { w.applySettings(apply) }
    }

    package var nextTimerDeadline: TimeInterval? { windows.compactMap(\.timerDeadline).min() }

    /// R10: `UserDefaults` writes made outside the wrappers (swift-corelibs-
    /// foundation posts no change notification) are noticed after each wake
    /// of the run loop, before the frame.
    package func afterWait() { AppStorageCenter.shared.refreshIfObserved() }

    package func fireTimers(now: TimeInterval) {
        for w in windows {
            w.gestures.tick(now)
            w.services.fireTimers(now: now)
        }
    }

    package var needsFrame: Bool { (appGraph?.needsUpdate ?? false) || windows.contains { $0.needsFrame } }

    package func renderFrame(at time: TimeInterval) {
        clock.frameTime = time
        defer { clock.frameTime = nil }
        appGraph?.update()
        for w in windows { w.renderFrame() }
        accessibilityExport?.afterFrame()
    }
}
