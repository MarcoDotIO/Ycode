// Hiccups, measured (specs/simulator/xr-viewer.md §13.1): a stretch without a
// new picture while the headset is tracked, with what happened at each end, on
// the viewer (`XRGapRecorder`) and on the display server (`XRServerGapLog`).
// Counts and times only: no gaze, no pose values.

import Foundation

/// A number with `places` decimals (one argument at a time: see `XRServerGapLog.frameSent`).
public func xrFixed(_ v: Double, _ places: Int = 0) -> String { String(format: "%.\(places)f", v) }

public struct XRGapRecorder: Sendable {
    /// Why the wearer saw nothing new.
    public enum Cause: String, Sendable, CaseIterable {
        /// Nothing was asked of the guest: no camera move, no pinch.
        case idle
        /// The eyes moved and the picture did not: a hover with nothing under it, or a guest late with it.
        case idleGaze = "idle-gaze"
        /// Asked, the guest's presenter went on swapping, and no new picture came.
        case guestNoPicture = "guest-no-picture"
        /// The guest's presenter itself stopped swapping.
        case guestStalled = "guest-stalled"
        /// The picture left the server late, or the way here took the time.
        case stream
        /// Here: received long before it was decoded or uploaded.
        case viewer
        /// The headset loop itself: its own work between two frames.
        case viewerLoop = "viewer-loop"
        /// The headset loop waited for the runtime (xrWaitFrame): the runtime's stall.
        case runtime
    }

    public struct Picture: Sendable, Equatable {
        public var sequence: UInt64, guestFrame: UInt64
        /// Viewer ns, 0 when unknown (stages of the server's clock come with the frame timing).
        public var captureStart: UInt64 = 0, sendEnd: UInt64 = 0, received: UInt64 = 0, decoded: UInt64 = 0, uploaded: UInt64 = 0
        public init(sequence: UInt64, guestFrame: UInt64, captureStart: UInt64 = 0, sendEnd: UInt64 = 0, received: UInt64 = 0, decoded: UInt64 = 0, uploaded: UInt64 = 0) {
            (self.sequence, self.guestFrame, self.captureStart, self.sendEnd) = (sequence, guestFrame, captureStart, sendEnd)
            (self.received, self.decoded, self.uploaded) = (received, decoded, uploaded)
        }
    }

    public struct Gap: Sendable, Equatable {
        public var milliseconds: Double
        public var cause: Cause
        /// The gap's end against the session's start (s).
        public var at: Double
        public var guestFrames: UInt64
        public var captureGap: Double, transit: Double, here: Double
        public var longestFrame: Double, longestWork: Double
        public var headsetFrames: Int
        public var cameraMoves: Int, pinchChanges: Int, saccades: Int
        public var headDegrees: Double, headCentimetres: Double
        public var hiddenMilliseconds: Double
        /// From the first camera move or pinch in the gap to this picture (0: none).
        public var unanswered: Double

        public var description: String {
            "gap \(xrFixed(milliseconds)) ms at \(xrFixed(at, 1)) s: \(cause.rawValue); guest presents +\(guestFrames), capture gap \(xrFixed(captureGap)) ms, way here \(xrFixed(transit)) ms, "
                + "here \(xrFixed(here)) ms; headset frames \(headsetFrames), longest \(xrFixed(longestFrame)) ms (our work \(xrFixed(longestWork)) ms); "
                + "asked: camera moves \(cameraMoves), pinches \(pinchChanges), saccades \(saccades), unanswered for \(xrFixed(unanswered)) ms; "
                + "head moved \(xrFixed(headDegrees, 1))° / \(xrFixed(headCentimetres, 1)) cm; picture under the cache \(xrFixed(hiddenMilliseconds)) ms"
        }
    }

    public var thresholdNanoseconds: UInt64 = 250_000_000
    /// Fewer guest presents per second than this: its presenter has stopped (it swaps at 60 when alive).
    public var stalledPresentRate = 5.0
    public private(set) var gaps: [Gap] = []
    public private(set) var counts: [Cause: (count: Int, milliseconds: Double, longest: Double)] = [:]
    /// Long headset frames whenever they happen (not only inside a gap).
    public private(set) var longFrames = 0, longestFrame = 0.0, runtimeStalls = 0
    public private(set) var hiddenFrames = 0, shownFrames = 0, longestHidden = 0.0
    /// From a camera move or pinch to the next picture (ms).
    public private(set) var answers: [Double] = []

    private var start: UInt64?
    private var last: Picture?
    private var lastFrameAt: UInt64?
    private var lastHead: SpatialPose?
    private var tracked = false
    private var interval = Interval()
    private var hiddenSince: UInt64?

    private struct Interval: Sendable {
        var frames = 0, longestFrame = 0.0, longestWork = 0.0, longestWait = 0.0
        var cameraMoves = 0, pinchChanges = 0, saccades = 0
        var headDegrees = 0.0, headMetres = 0.0, hidden = 0.0
        var trackedThroughout = true
        /// The first camera move or pinch since the last picture, and the first saccade.
        var firstAsk: UInt64?, firstSaccade: UInt64?
    }

    public init() {}

    /// One headset frame: `waited` what xrWaitFrame took (ns), `work` the loop's own time in the last frame (ns).
    public mutating func frame(at now: UInt64, tracked isTracked: Bool, head: SpatialPose?, waited: UInt64 = 0, work: UInt64 = 0,
                               cameraMoved: Bool = false, pinchChanged: Bool = false, saccade: Bool = false, pictureHidden: Bool = false) {
        if start == nil { start = now }
        tracked = isTracked
        if !isTracked { interval.trackedThroughout = false }
        interval.frames += 1
        if let l = lastFrameAt {
            let ms = Double(now &- l) / 1e6
            interval.longestFrame = max(interval.longestFrame, ms)
            longestFrame = max(longestFrame, ms)
            if ms > 50 {
                longFrames += 1
                if Double(waited) / 1e6 > ms / 2 { runtimeStalls += 1 }
            }
            if pictureHidden { interval.hidden += ms }
        }
        interval.longestWork = max(interval.longestWork, Double(work) / 1e6)
        interval.longestWait = max(interval.longestWait, Double(waited) / 1e6)
        lastFrameAt = now
        if cameraMoved { interval.cameraMoves += 1 }
        if pinchChanged { interval.pinchChanges += 1 }
        if saccade { interval.saccades += 1 }
        if cameraMoved || pinchChanged, interval.firstAsk == nil { interval.firstAsk = now }
        if saccade, interval.firstSaccade == nil { interval.firstSaccade = now }
        if let head, let h = lastHead {
            interval.headMetres += (head.position - h.position).length
            let q = (h.rotation.conjugate * head.rotation).normalized
            interval.headDegrees += 2 * acos(min(1, abs(q.w))) * 180 / .pi
        }
        lastHead = head
        if pictureHidden {
            hiddenFrames += 1
            let since = hiddenSince ?? now
            hiddenSince = since
            longestHidden = max(longestHidden, Double(now &- since) / 1e6)
        } else {
            shownFrames += 1
            hiddenSince = nil
        }
    }

    /// A new picture reached the eyes. Returns the gap it ended, if there was one.
    @discardableResult
    public mutating func picture(_ p: Picture) -> Gap? {
        defer { last = p; interval = Interval() }
        // What was asked since the last picture, answered by this one.
        if let a = interval.firstAsk, p.uploaded > a, answers.count < 100_000 { answers.append(Double(p.uploaded - a) / 1e6) }
        guard let l = last, p.uploaded > l.uploaded else { return nil }
        let span = p.uploaded - l.uploaded
        guard span >= thresholdNanoseconds, interval.trackedThroughout else { return nil }
        let ms = Double(span) / 1e6
        func stage(_ a: UInt64, _ b: UInt64) -> Double { a > 0 && b >= a ? Double(b - a) / 1e6 : 0 }
        let captureGap = stage(l.captureStart, p.captureStart)
        let transit = stage(p.captureStart, p.received)
        let here = stage(p.received, p.uploaded)
        let presents = p.guestFrame >= l.guestFrame ? p.guestFrame - l.guestFrame : 0
        let cause: Cause
        if interval.longestFrame >= ms / 2 {
            cause = interval.longestWait >= interval.longestFrame / 2 ? .runtime : .viewerLoop
        } else if here >= ms / 2 {
            cause = .viewer
        } else if transit >= ms / 2 {
            cause = .stream
        } else if Double(presents) * 1000 / ms < stalledPresentRate {
            cause = .guestStalled
        } else if let a = interval.firstAsk, p.uploaded &- a >= thresholdNanoseconds {
            // Asked, and that long without an answer. (A rest that ends with the head's next move, its
            // first picture about 200 ms later, is no such thing: the asking came only at the end.)
            cause = .guestNoPicture
        } else if let a = interval.firstSaccade, p.uploaded &- a >= thresholdNanoseconds {
            cause = .idleGaze
        } else {
            cause = .idle
        }
        let g = Gap(milliseconds: ms, cause: cause, at: Double(p.uploaded &- (start ?? p.uploaded)) / 1e9, guestFrames: presents,
                    captureGap: captureGap, transit: transit, here: here, longestFrame: interval.longestFrame, longestWork: interval.longestWork,
                    headsetFrames: interval.frames, cameraMoves: interval.cameraMoves, pinchChanges: interval.pinchChanges, saccades: interval.saccades,
                    headDegrees: interval.headDegrees, headCentimetres: interval.headMetres * 100, hiddenMilliseconds: interval.hidden,
                    unanswered: interval.firstAsk.map { Double(p.uploaded &- $0) / 1e6 } ?? 0)
        if gaps.count < 512 { gaps.append(g) }
        var c = counts[cause] ?? (0, 0, 0)
        c.count += 1
        c.milliseconds += ms
        c.longest = max(c.longest, ms)
        counts[cause] = c
        return g
    }

    public var summary: String {
        var parts = Cause.allCases.compactMap { c -> String? in
            guard let v = counts[c] else { return nil }
            return "\(c.rawValue) \(v.count) (\(xrFixed(v.milliseconds / 1000, 1)) s, longest \(xrFixed(v.longest)) ms)"
        }
        if parts.isEmpty { parts = ["none"] }
        let a = answers.sorted()
        let all = hiddenFrames + shownFrames
        return "gaps over \(thresholdNanoseconds / 1_000_000) ms: " + parts.joined(separator: ", ")
            + (a.isEmpty ? "" : String(format: "; a camera move or pinch answered by a picture in p50 %.0f / p90 %.0f / max %.0f ms", a[a.count / 2], a[a.count * 9 / 10], a.last!))
            + String(format: "; headset frames over 50 ms: %d (%d in the runtime's wait), longest %.0f ms; newest picture under the cache in %.1f %% of frames, longest %.0f ms",
                     longFrames, runtimeStalls, longestFrame, all > 0 ? 100 * Double(hiddenFrames) / Double(all) : 0, longestHidden)
    }
}

/// The runtime's stalls the viewer can see: its headset loop keeps time whether
/// or not the headset's data arrives, but the tracker's samples then grow old.
public struct XRStaleTracking: Sendable {
    public var thresholdNanoseconds: Int64 = 250_000_000
    public private(set) var stretches = 0, longest = 0.0
    public private(set) var lastDescription = ""
    private var since: UInt64?

    public init() {}

    /// A sample of this age now; true when a stretch of stale samples just ended (`lastDescription` says how long).
    public mutating func note(age: Int64, at now: UInt64) -> Bool {
        if age >= thresholdNanoseconds {
            if since == nil { since = now }
            return false
        }
        guard let s = since else { return false }
        since = nil
        let ms = Double(now &- s) / 1e6
        stretches += 1
        longest = max(longest, ms)
        lastDescription = "the headset's tracking did not arrive for \(xrFixed(ms)) ms (the runtime or its link)"
        return true
    }

    public var summary: String { "stretches of stale tracking \(stretches), longest \(xrFixed(longest)) ms" }
}

/// The display server's side of the same question: what the guest and the
/// viewer did in a stretch with no frame sent.
public struct XRServerGapLog: Sendable {
    public var thresholdNanoseconds: UInt64 = 250_000_000
    private var lastSent: UInt64?
    private var lastRecord: UInt64 = 0
    private var scans = 0, unchanged = 0, poses = 0, selections = 0, pinchChanges = 0, heldByWindow = 0
    private var lastPinch = false
    private var posesTotal = 0
    private var firstAsk: UInt64?
    private var longestEncode: UInt64 = 0
    public private(set) var gaps = 0, gapMilliseconds = 0.0, longest = 0.0

    public init() {}

    public mutating func scanned(changed: Bool) { scans += 1; if !changed { unchanged += 1 } }
    public mutating func poseDelivered(at now: UInt64) { poses += 1; if firstAsk == nil { firstAsk = now } }
    /// The poses given to the guest so far (the difference since the last frame counts).
    public mutating func poses(total: Int, at now: UInt64) {
        if total > posesTotal {
            poses += total - posesTotal
            if firstAsk == nil { firstAsk = now }
        }
        posesTotal = total
    }
    public var isPinching: Bool { lastPinch }
    public mutating func selection(pinching: Bool, at now: UInt64 = 0) {
        selections += 1
        if pinching != lastPinch {
            pinchChanges += 1
            lastPinch = pinching
            if firstAsk == nil { firstAsk = now }
        }
    }
    public mutating func heldBack() { heldByWindow += 1 }
    public mutating func encode(took: UInt64) { longestEncode = max(longestEncode, took) }

    /// A frame went out at `now`, of the guest's present `record`. A line when it ended a gap; `load` is asked only then.
    public mutating func frameSent(at now: UInt64, record: UInt64, load: () -> String) -> String? {
        defer {
            lastSent = now
            lastRecord = record
            (scans, unchanged, poses, selections, pinchChanges, heldByWindow) = (0, 0, 0, 0, 0, 0)
            firstAsk = nil
            longestEncode = 0
        }
        guard let l = lastSent, now &- l >= thresholdNanoseconds else { return nil }
        let ms = Double(now &- l) / 1e6
        gaps += 1
        gapMilliseconds += ms
        longest = max(longest, ms)
        let presents = record >= lastRecord ? record - lastRecord : 0
        let kind: String
        if Double(presents) * 1000 / ms < 5 { kind = "the guest's presenter stopped" }
        else if heldByWindow > 0 { kind = "the viewer's window was full" }
        else if let a = firstAsk, now &- a >= thresholdNanoseconds { kind = "asked, and the guest's picture did not change" }
        else if selections > 0 { kind = "only the gaze moved" }
        else { kind = "nothing asked" }
        // Interpolated: Swift's variadic format on arm64 Linux crashed on this many arguments (a %@ past the registers).
        return "gap \(xrFixed(ms)) ms: \(kind); presents +\(presents), scans \(scans) (\(unchanged) unchanged), poses \(poses), selections \(selections), pinch changes \(pinchChanges), "
            + "unanswered \(xrFixed(firstAsk.map { Double(now &- $0) / 1e6 } ?? 0)) ms, held by the window \(heldByWindow), longest encode \(xrFixed(Double(longestEncode) / 1e6, 1)) ms, load \(load())"
    }
}

/// Hover target changes, from what the guest draws: with the camera still and
/// no pinch, a small changed area is a hover highlight or an animation in one
/// place; a new burst somewhere else is a new target. This is what the server
/// can see of the guest's hit test (the guest does not report its target).
public struct XRHoverCounter: Sendable {
    /// A burst ends after this long without a change; a burst elsewhere is a new target.
    public var quietNanoseconds: UInt64 = 150_000_000
    public var movedFraction = 0.03
    /// Larger than this share of the picture is not a hover.
    public var largestFraction = 0.25
    public private(set) var bursts = 0, targetChanges = 0
    private var lastAt: UInt64?
    private var place: (x: Double, y: Double)?

    public init() {}

    /// A picture changed in this rectangle (fractions of the picture's size), the camera at rest.
    public mutating func damage(x: Double, y: Double, width: Double, height: Double, at now: UInt64) {
        guard width * height <= largestFraction else { return }
        let c = (x: x + width / 2, y: y + height / 2)
        let newBurst = lastAt.map { now &- $0 >= quietNanoseconds } ?? true
        lastAt = now
        guard newBurst else { return }
        bursts += 1
        if let p = place, ((p.x - c.x) * (p.x - c.x) + (p.y - c.y) * (p.y - c.y)).squareRoot() > movedFraction { targetChanges += 1 }
        place = c
    }
}
