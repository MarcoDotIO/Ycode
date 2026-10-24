import Foundation
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// The sampler of the probe's `anim` mode, rebuilt on the headless host: an
// animatable modifier whose body records its animatable data with the time
// of the frame (05 §1: the body runs once per display frame while the value
// animates). The manual clock runs at 60 Hz; the state change happens at
// t = 0, between frames.

let frame = 1.0 / 60

@MainActor
final class Samples {
    weak var graph: ViewGraph?
    private(set) var entries: [(time: Double, value: Double)] = []

    func record(_ v: Double) { entries.append((graph?.currentTime ?? -1, v)) }
    func clear() { entries = [] }

    /// Body evaluations (the probe's `frames=`).
    var count: Int { entries.count }
    var last: Double? { entries.last?.value }
    var maximum: Double { entries.map(\.value).max() ?? 0 }

    /// The value presented at time `t` (the last sample at or before it).
    func value(at t: Double) -> Double? { entries.last { $0.time <= t + 1e-9 }?.value }

    /// True if `expected` is within `tolerance` of the presented value
    /// somewhere within ±`frames` display frames of `t` (T-ANIM: ±1 frame,
    /// ±0.01; the reference sampled on a loaded host).
    func matches(_ expected: Double, at t: Double, tolerance: Double = 0.01, frames: Int = 1) -> Bool {
        let window = Double(frames) * frame + 1e-9
        var lo = Double.infinity, hi = -Double.infinity
        for k in -frames...frames {
            guard let v = value(at: t + Double(k) * frame) else { continue }
            lo = min(lo, v)
            hi = max(hi, v)
        }
        _ = window
        return expected >= lo - tolerance && expected <= hi + tolerance
    }

    /// The first sample time at which the value is within `epsilon` of
    /// `target` (the probe's "rendered duration": the first frame printing
    /// the target to 4 decimals).
    func firstTime(at target: Double, epsilon: Double = 5e-5) -> Double? {
        entries.first { abs($0.value - target) < epsilon && $0.time > 0 }?.time
    }

    /// Times of samples whose value differs from the one before.
    var changeTimes: [Double] {
        var out: [Double] = []
        var prev: Double?
        for e in entries {
            if let p = prev, p != e.value { out.append(e.time) }
            prev = e.value
        }
        return out
    }
}

/// Records its animatable data whenever its body runs.
struct Recorder: ViewModifier, Animatable {
    var animatableData: Double
    let samples: Samples

    func body(content: Content) -> some View {
        let _ = samples.record(animatableData)
        content
    }
}

extension View {
    func recording(_ value: Double, _ samples: Samples) -> some View {
        modifier(Recorder(animatableData: value, samples: samples))
    }
}

/// One animated value, written through `control`.
struct AnimProbe: View {
    let samples: Samples
    let control: Controls<Double>
    @State var x = 0.0

    var body: some View {
        let _ = { control.binding = $x }()
        Color.red.recording(x, samples)
    }
}

/// A probe run: the graph, the samples, and the time of completion
/// handlers.
@MainActor
struct AnimRun {
    let graph: ViewGraph
    let samples: Samples
    let control: Controls<Double>

    init(start: Double = 0) {
        samples = Samples()
        control = Controls<Double>()
        graph = ViewGraph(rootView: AnimProbe(samples: samples, control: control))
        samples.graph = graph
        graph.update()
        if start != 0 {
            control.value = start
            graph.update()
        }
        samples.clear()
    }

    /// Changes the value to `target` in `animation` at the current time and
    /// renders until nothing animates. Returns the completion times.
    @discardableResult
    func animate(_ animation: Animation?, to target: Double = 1, settle: Bool = true)
        -> (logical: Double?, removed: Double?) {
        var logical: Double?, removed: Double?
        let g = graph
        var t = Transaction(animation: animation)
        t.addAnimationCompletion(criteria: .logicallyComplete) { logical = g.currentTime }
        t.addAnimationCompletion(criteria: .removed) { removed = g.currentTime }
        withTransaction(t) { control.value = target }
        graph.update()
        if settle { graph.settle() }
        return (logical, removed)
    }
}

/// True if `a` and `b` differ by at most `frames` display frames.
func withinFrames(_ a: Double?, _ b: Double, _ frames: Int = 1) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= Double(frames) * frame + 1e-9
}
