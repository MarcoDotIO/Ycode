// How the host paces input into the guest (specs/simulator/uikit-feel-ycode.md
// §4.0; hid-input.md §7 item 4, §14.3). Portable decisions, so they are
// tested on every platform; ycode-simd's input bridge applies them on its
// sender thread.
//
// - Every input is stamped when the display server receives it and sent in
//   order from one thread with its age, so the guest's event timestamps keep
//   the spacing of the viewer's samples even when the guest's input queue
//   holds a delivery up (UIKit measures velocities and its 150 / 350 / 500 ms
//   gesture times against those timestamps).
// - Moves are kept up to 120 per second (a digitizer's rate); a move that a
//   newer one replaces within 8 ms is dropped.
// - While a finger rests, a digitizer keeps reporting it. Mice and scripts
//   send nothing while still, so the host repeats a resting contact every
//   frame; UIKit then sees the finger stop, and a drag that is held before
//   it is released does not fling.

public enum TouchPacing {
    /// Moves closer together than this are coalesced (the newer one wins).
    public static let minimumMoveInterval: UInt64 = 8_000_000
    /// While a contact rests, it is reported this often (60 Hz).
    public static let restInterval: UInt64 = 16_666_667
    /// Ages above this are clamped (a guest stalled longer than this sees the input as new).
    public static let maximumAgeMicroseconds: UInt32 = 5_000_000

    /// Whether a queued move-only message is superseded by the next queued
    /// one: also move-only, and received within `minimumMoveInterval`.
    public static func isSuperseded(moveOnly: Bool, received: UInt64, next: (moveOnly: Bool, received: UInt64)?) -> Bool {
        guard moveOnly, let next, next.moveOnly, next.received >= received else { return false }
        return next.received - received < minimumMoveInterval
    }

    /// Microseconds from `received` to `now` (monotonic ns), clamped.
    public static func ageMicroseconds(received: UInt64, now: UInt64) -> UInt32 {
        guard now > received else { return 0 }
        return UInt32(min(UInt64(maximumAgeMicroseconds), (now - received) / 1000))
    }

    /// Whether a resting contact is due to be reported again: some contact
    /// is down, and no touch message went out for `restInterval`.
    public static func restReportDue(anyDown: Bool, lastTouchSent: UInt64, now: UInt64) -> Bool {
        anyDown && now >= lastTouchSent && now - lastTouchSent >= restInterval
    }

    /// The position a resting contact is reported at: a digitizer's reports
    /// of a still finger differ by its noise, and the guest drops a report
    /// at exactly the same device pixel, so alternate reports move by one
    /// device pixel towards the screen's centre and back (`count` counts
    /// the reports of this rest). Normalized coordinates in 0…1.
    public static func restPosition(x: Double, y: Double, count: Int, pixelWidth: Double) -> (x: Double, y: Double) {
        guard count % 2 == 1, pixelWidth > 0 else { return (x, y) }
        let step = 1 / pixelWidth
        return (x < 0.5 ? x + step : x - step, y)
    }
}
