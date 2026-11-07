import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// The headless back end (09-open-design.md §4): deterministic in-memory
// windows of a fixed size and scale, events posted by tests, and a virtual
// clock that jumps to each deadline the run loop waits for (so a test of
// "0.5 s later" takes no real time and every frame lands on the 60 Hz grid).

/// Clipboard text kept in memory.
@MainActor
public final class MemoryClipboard: PlatformClipboard {
    public var text: String?
    public var hasText: Bool { !(text ?? "").isEmpty }
    public init() {}
}

/// An in-memory window.
@MainActor
public final class HeadlessWindow: PlatformWindow {
    public let id: PlatformWindowID
    public var title: String
    public private(set) var size: CGSize
    public var scale: Double
    public var refreshRate: Double
    public private(set) var isClosed = false
    /// Frames presented so far.
    public private(set) var presentedFrames = 0
    public private(set) var lastFrame: PixelBuffer?
    public private(set) var isTextInputActive = false
    public private(set) var textInputCaret: CGRect?
    public var vulkan: (any PlatformVulkanSurface)? { nil }
    public let popupParent: PlatformWindowID?
    /// Where a pop-up was placed (points from its parent's origin).
    public let popupOrigin: CGPoint
    private weak var backend: HeadlessBackend?

    init(id: PlatformWindowID, configuration: WindowConfiguration, scale: Double, refreshRate: Double,
         backend: HeadlessBackend) {
        self.id = id
        title = configuration.title
        size = configuration.size
        self.scale = scale
        self.refreshRate = refreshRate
        popupParent = configuration.popupParent
        popupOrigin = configuration.popupOrigin
        isDecorated = configuration.decorated
        self.backend = backend
    }

    public var pixelSize: (width: Int, height: Int) {
        (Int((size.width * scale).rounded()), Int((size.height * scale).rounded()))
    }

    public func setSize(_ size: CGSize) {
        self.size = size
        backend?.post(.window(id, .resized(size)))
    }

    public func present(_ frame: PixelBuffer) {
        presentedFrames += 1
        lastFrame = frame
    }

    public func readback() -> PixelBuffer? { lastFrame }

    public func startTextInput(caretRect: CGRect) {
        isTextInputActive = true
        textInputCaret = caretRect
    }

    public func stopTextInput() {
        isTextInputActive = false
        textInputCaret = nil
    }

    public private(set) var activations = 0
    public func activate() { activations += 1 }
    public private(set) var isMinimized = false
    public func minimize() {
        isMinimized = true
        backend?.post(.window(id, .minimized))
    }
    public func close() { isClosed = true }

    // Client-side decorations (B5-OPENVIEWS): recorded for tests.
    public let isDecorated: Bool
    public private(set) var hitTest: (@MainActor (CGPoint) -> WindowHitRegion)?
    public private(set) var isMaximized = false
    public private(set) var isFullscreen = false
}

extension HeadlessWindow: PlatformWindowDecorations {
    public func setHitTest(_ test: (@MainActor (CGPoint) -> WindowHitRegion)?) { hitTest = test }
    public func setMaximized(_ maximized: Bool) { isMaximized = maximized }
    public func setFullscreen(_ fullscreen: Bool) { isFullscreen = fullscreen }
    /// The region the app's hit test gives at a point (tests).
    public func hitRegion(at p: CGPoint) -> WindowHitRegion { hitTest?(p) ?? .normal }
}

/// The test back end.
@MainActor
public final class HeadlessBackend: PlatformBackend {
    public let name = "headless"
    public private(set) var now: TimeInterval
    public let clipboard: any PlatformClipboard = MemoryClipboard()
    /// Scale and refresh rate of new windows.
    public var defaultScale: Double
    public var defaultRefreshRate: Double
    /// URLs handed to the desktop.
    public private(set) var openedURLs: [URL] = []
    /// Number of `waitForEvents` calls that would have slept with no deadline.
    public private(set) var idleWaits = 0
    private var allWindows: [HeadlessWindow] = []
    private var nextID: PlatformWindowID = 1
    /// Pending events with their due times (stable order for equal times).
    private var queue: [(time: TimeInterval, seq: Int, event: PlatformEvent)] = []
    private var seq = 0

    public init(start: TimeInterval = 0, scale: Double = 2, refreshRate: Double = 60) {
        now = start
        defaultScale = scale
        defaultRefreshRate = refreshRate
    }

    public var windows: [any PlatformWindow] { allWindows.filter { !$0.isClosed } }
    public var headlessWindows: [HeadlessWindow] { allWindows.filter { !$0.isClosed } }

    /// When true, pop-up windows are refused (tests of the overlay fallback).
    public var refusesPopups = false

    /// The desktop settings (R10): the reference defaults; a test changes
    /// them like a user changing a desktop setting (`.settingsChanged`).
    public var settings = PlatformSettings() {
        didSet { if settings != oldValue { post(.settingsChanged) } }
    }

    public func makeWindow(_ configuration: WindowConfiguration) throws -> any PlatformWindow {
        if let parent = configuration.popupParent {
            guard !refusesPopups, headlessWindows.contains(where: { $0.id == parent }) else {
                throw PlatformError.windowCreationFailed("pop-up windows refused")
            }
        }
        let w = HeadlessWindow(id: nextID, configuration: configuration, scale: defaultScale,
                               refreshRate: defaultRefreshRate, backend: self)
        nextID += 1
        allWindows.append(w)
        return w
    }

    public func post(_ event: PlatformEvent) { post(event, at: now) }

    /// Queues an event for back-end time `time` (not before now).
    public func post(_ event: PlatformEvent, at time: TimeInterval) {
        seq += 1
        queue.append((max(time, now), seq, event))
        queue.sort { ($0.time, $0.seq) < ($1.time, $1.seq) }
    }

    /// The due time of the earliest queued event.
    public var nextEventTime: TimeInterval? { queue.first?.time }

    public func waitForEvents(until deadline: TimeInterval?) -> [PlatformEvent] {
        if let first = queue.first, first.time <= now + 1e-9 { return takeDue() }
        // Nothing due: the clock jumps to the deadline or the next event.
        var target = deadline
        if let t = queue.first?.time { target = target.map { min($0, t) } ?? t }
        guard let target else {
            idleWaits += 1
            return []
        }
        if target > now { now = target }
        return takeDue()
    }

    private func takeDue() -> [PlatformEvent] {
        var out: [PlatformEvent] = []
        while let first = queue.first, first.time <= now + 1e-9 {
            out.append(first.event)
            queue.removeFirst()
        }
        return out
    }

    /// Moves the clock forward without delivering anything.
    public func advanceClock(by seconds: TimeInterval) { now += max(0, seconds) }

    public func openExternally(_ url: URL) -> Bool {
        openedURLs.append(url)
        return true
    }

    public func shutdown() {
        for w in allWindows { w.close() }
    }
}
