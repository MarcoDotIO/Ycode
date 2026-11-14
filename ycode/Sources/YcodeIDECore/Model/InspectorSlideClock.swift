import Foundation

/// The inspector slide's clock (`workspace-window.md` W7.3, council row
/// 190): the curve's time is counted from the press while frames come on
/// time, but a late first frame (the main thread busy after the press)
/// starts the motion there instead of finding the curve already over, and
/// a stalled frame later on advances the curve by one frame's worth at
/// most. So a slide always plays (J.3's hide over 150 ms, the show over
/// 280), however late the window draws, and never jumps to its end.
public struct InspectorSlideClock: Sendable {
    public let show: Bool
    public let press: Double
    /// The curve's time so far (nil before the first frame).
    public private(set) var elapsed: Double?
    private var lastFrame: Double?

    /// The most a frame advances the curve (a 30 Hz frame).
    public static let maximumStep = 1.0 / 30

    public init(show: Bool, press: Double) {
        self.show = show
        self.press = press
    }

    /// The slide's progress (0–1) for a frame drawn at `time`.
    public mutating func progress(at time: Double) -> Double {
        let next: Double
        if let elapsed, let lastFrame {
            next = elapsed + min(max(0, time - lastFrame), Self.maximumStep)
        } else {
            // On time: from the press. Late: the motion starts with this frame.
            next = min(max(0, time - press), EditorMetrics.inspectorSlideDelay(show: show))
        }
        elapsed = next
        lastFrame = time
        return isFinished ? 1 : EditorMetrics.inspectorSlideProgress(elapsed: next, show: show)
    }

    /// Whether the curve has reached its end.
    public var isFinished: Bool { (elapsed ?? 0) >= EditorMetrics.inspectorSlideTotal(show: show) }
}
