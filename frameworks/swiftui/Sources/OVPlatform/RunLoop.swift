import Foundation

// The run loop and display link (round R7; 09-open-design.md §4 "Run loop").
//
// One thread (the main thread) runs the cycle:
//
//   wait  → events → timers → frame (commit, layout, render) → wait …
//
// - **Wait.** The loop sleeps in the back end until an event arrives, the
//   main queue has work (Swift concurrency's main actor, `DispatchQueue.main`),
//   or the next deadline: the next display frame when the client needs one,
//   otherwise the client's earliest timer. With nothing pending and nothing
//   animating it sleeps without a deadline: an idle application renders no
//   frames and takes no wake-ups beyond the back end's.
// - **Events** are handed to the client in order; they usually write state.
// - **Frames** are paced by a display link at the window's refresh rate
//   (60 Hz when the display does not say): a frame is produced at most once
//   per period, at the first opportunity at or after the next tick, and only
//   while the client needs one (state changed, an animation runs, the window
//   was resized or exposed). Frame times are the tick times, so animations
//   sample on a regular grid; a late frame takes the current time and the grid
//   restarts from there.

/// What the run loop drives (the application host).
@MainActor
public protocol RunLoopClient: AnyObject {
    /// Handles one event (in arrival order).
    func handle(_ event: PlatformEvent)
    /// The earliest time a timer of the client is due (gesture timeouts, …).
    var nextTimerDeadline: TimeInterval? { get }
    /// Runs the timers due at `now`.
    func fireTimers(now: TimeInterval)
    /// True if the next display tick should produce a frame.
    var needsFrame: Bool { get }
    /// Produces one frame for display time `time`.
    func renderFrame(at time: TimeInterval)
    /// True once the application should stop.
    var isFinished: Bool { get }
    /// Called after each wait, before the events are handled (R10: the
    /// host looks for changes nothing announces, such as defaults written
    /// by main-queue work).
    func afterWait()
}

extension RunLoopClient {
    public func afterWait() {}
}

/// Paces frames at a refresh rate.
public struct DisplayLink: Sendable, Equatable {
    public var framesPerSecond: Double
    /// The next tick (back-end time).
    public private(set) var nextTick: TimeInterval
    public var period: TimeInterval { 1 / framesPerSecond }

    public init(framesPerSecond: Double = 60, start: TimeInterval = 0) {
        self.framesPerSecond = framesPerSecond > 0 ? framesPerSecond : 60
        nextTick = start
    }

    /// True if a frame may be produced at `now`.
    public func isDue(at now: TimeInterval) -> Bool { now + 1e-6 >= nextTick }

    /// Consumes the tick due at `now` and returns the frame's display time.
    public mutating func consume(at now: TimeInterval) -> TimeInterval {
        let time: TimeInterval
        if now - nextTick < period {
            time = max(nextTick, 0)
            nextTick += period
        } else {
            // Late (or idle until now): restart the grid at the current time.
            time = now
            nextTick = now + period
        }
        return time
    }
}

/// The main-thread loop of an application.
@MainActor
public final class PlatformRunLoop {
    public let backend: any PlatformBackend
    public var displayLink: DisplayLink
    /// Frames produced so far.
    public private(set) var framesRendered = 0
    /// Waits that had no deadline (idle sleeps).
    public private(set) var idleWaits = 0
    /// Iterations of the loop.
    public private(set) var iterations = 0
    private var stopRequested = false

    public init(backend: any PlatformBackend, framesPerSecond: Double = 60) {
        self.backend = backend
        displayLink = DisplayLink(framesPerSecond: framesPerSecond, start: backend.now)
    }

    /// Asks `run` to return after the current iteration.
    public func stop() { stopRequested = true }

    /// Runs until the client finishes or `stop()` is called.
    public func run(_ client: any RunLoopClient) {
        stopRequested = false
        while !stopRequested && !client.isFinished { runOnce(client) }
    }

    /// Runs until back-end time `deadline` (tests on the headless back end,
    /// whose clock jumps to each deadline while waiting).
    public func run(_ client: any RunLoopClient, until deadline: TimeInterval) {
        stopRequested = false
        while !stopRequested && !client.isFinished && backend.now < deadline - 1e-9 {
            runOnce(client, cap: deadline)
        }
    }

    /// One iteration: wait, events, timers, frame.
    public func runOnce(_ client: any RunLoopClient, cap: TimeInterval? = nil) {
        iterations += 1
        var deadline = client.nextTimerDeadline
        if client.needsFrame {
            let tick = max(displayLink.nextTick, backend.now)
            deadline = deadline.map { min($0, tick) } ?? tick
        }
        if let cap { deadline = deadline.map { min($0, cap) } ?? cap }
        if deadline == nil { idleWaits += 1 }
        let events = backend.waitForEvents(until: deadline)
        client.afterWait()
        for e in events { client.handle(e) }
        let now = backend.now
        if let t = client.nextTimerDeadline, t <= now + 1e-9 { client.fireTimers(now: now) }
        if client.needsFrame && displayLink.isDue(at: now) {
            let time = displayLink.consume(at: now)
            framesRendered += 1
            client.renderFrame(at: time)
        }
    }
}
