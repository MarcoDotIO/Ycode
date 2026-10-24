// SUIProbe anim mode: timing curves, springs, keyframes (pure API values), and
// animations sampled while rendering (an Animatable modifier records the
// interpolated value every time SwiftUI evaluates it), transactions and
// transitions.
import SwiftUI
import QuartzCore

func logCurvesAndSprings() {
    let curves: [(String, UnitCurve)] = [("linear", .linear), ("easeIn", .easeIn), ("easeOut", .easeOut),
        ("easeInOut", .easeInOut), ("circularEaseIn", .circularEaseIn), ("circularEaseOut", .circularEaseOut),
        ("circularEaseInOut", .circularEaseInOut), ("bezier(0.2,0,0,1)", .bezier(startControlPoint: UnitPoint(x: 0.2, y: 0), endControlPoint: UnitPoint(x: 0, y: 1)))]
    for (n, c) in curves {
        let v = stride(from: 0.0, through: 1.0001, by: 0.1).map { f4(c.value(at: $0)) }
        let vel = [0.0, 0.5, 1.0].map { f4(c.velocity(at: $0)) }
        log("curve.\(n)", "value=\(v.joined(separator: ",")) velocity@0,0.5,1=\(vel.joined(separator: ","))")
    }
    let springs: [(String, Spring)] = [("default", Spring()), ("smooth", .smooth), ("snappy", .snappy), ("bouncy", .bouncy),
        ("duration0.5bounce0.3", Spring(duration: 0.5, bounce: 0.3)), ("response0.55damping0.825", Spring(response: 0.55, dampingRatio: 0.825)),
        ("mass1stiffness100damping10", Spring(mass: 1, stiffness: 100, damping: 10)), ("bounceNeg0.3", Spring(duration: 0.5, bounce: -0.3))]
    for (n, s) in springs {
        log("spring.\(n).params", "response=\(f4(s.response)) dampingRatio=\(f4(s.dampingRatio)) duration=\(f4(s.duration)) bounce=\(f4(s.bounce)) mass=\(f4(s.mass)) stiffness=\(f4(s.stiffness)) damping=\(f4(s.damping)) settlingDuration=\(f4(s.settlingDuration))")
        let samples = stride(from: 0.0, through: 1.5001, by: 0.05).map { f4(s.value(target: 1.0, initialVelocity: 0, time: $0)) }
        log("spring.\(n).value", samples.joined(separator: ","))
        log("spring.\(n).velocity@0.1,0.3", "\(f4(s.velocity(target: 1.0, initialVelocity: 0, time: 0.1))),\(f4(s.velocity(target: 1.0, initialVelocity: 0, time: 0.3)))")
    }
    let anims: [(String, Animation)] = [("default", .default), ("linear", .linear), ("easeIn", .easeIn), ("easeOut", .easeOut),
        ("easeInOut", .easeInOut), ("spring", .spring()), ("interactiveSpring", .interactiveSpring()), ("bouncy", .bouncy),
        ("smooth", .smooth), ("snappy", .snappy), ("interpolatingSpring", .interpolatingSpring()),
        ("linearDelayRepeat", .linear(duration: 1).delay(0.5).repeatCount(2, autoreverses: true).speed(2))]
    for (n, a) in anims { log("animation.\(n).description", String(describing: a)) }
    let tl = KeyframeTimeline(initialValue: 0.0) {
        LinearKeyframe(100.0, duration: 1)
        SpringKeyframe(0.0, duration: 1)
        CubicKeyframe(50.0, duration: 0.5)
        MoveKeyframe(10.0)
        CubicKeyframe(20.0, duration: 0.5)
    }
    log("keyframes.duration", f4(tl.duration))
    log("keyframes.values", stride(from: 0.0, through: 3.0001, by: 0.1).map { f2(tl.value(time: $0)) }.joined(separator: ","))
}

/// Records every evaluation of the animated value: (seconds since start, value).
final class Samples {
    static var data: [String: [(Double, Double)]] = [:]
    static var start: [String: Double] = [:]
    static func begin(_ k: String) { data[k] = []; start[k] = CACurrentMediaTime() }
    static func add(_ k: String, _ v: Double) {
        guard let s = start[k] else { return }
        data[k, default: []].append((CACurrentMediaTime() - s, v))
    }
    static func report(_ k: String, from a: Double, to b: Double) {
        let d = data[k] ?? []
        guard !d.isEmpty else { log("anim.\(k)", "no samples"); return }
        let span = b - a
        let norm = d.map { ($0.0, span == 0 ? 0 : ($0.1 - a) / span) }
        let lastChange = norm.last(where: { abs($0.1 - 1) > 1e-6 })?.0 ?? 0
        let firstEnd = norm.first(where: { abs($0.1 - 1) < 1e-4 })?.0 ?? -1
        let maxv = norm.map { $0.1 }.max() ?? 0
        let minv = norm.map { $0.1 }.min() ?? 0
        func at(_ t: Double) -> String {
            guard let i = norm.firstIndex(where: { $0.0 >= t }) else { return "-" }
            if i == 0 { return f4(norm[0].1) }
            let (t1, v1) = norm[i - 1], (t2, v2) = norm[i]
            return f4(v1 + (v2 - v1) * (t - t1) / max(t2 - t1, 1e-9))
        }
        log("anim.\(k)", "frames=\(d.count) lastChangeAt=\(f4(lastChange)) firstAtTarget=\(f4(firstEnd)) max=\(f4(maxv)) min=\(f4(minv)) v@0.1=\(at(0.1)) v@0.25=\(at(0.25)) v@0.5=\(at(0.5)) v@0.75=\(at(0.75)) v@1.0=\(at(1.0))")
        let raw = d.prefix(200).map { "\(f4($0.0)):\(f2($0.1))" }.joined(separator: " ")
        log("anim.\(k).raw", raw)
    }
}

struct Sampler: ViewModifier, Animatable {
    var value: Double
    let key: String
    var animatableData: Double { get { value } set { value = newValue } }
    func body(content: Content) -> some View {
        let _ = Samples.add(key, value)
        return content.offset(x: value)
    }
}

struct TransitionSampler: ViewModifier, Animatable {
    var value: Double
    let key: String
    var animatableData: Double { get { value } set { value = newValue } }
    func body(content: Content) -> some View {
        let _ = Samples.add(key, value)
        return content.opacity(value)
    }
}

struct AnimProbe: View {
    @State var x = 0.0
    @State var a = 0.0
    @State var b = 0.0
    @State var current = "none"
    @State var shown = false
    var body: some View {
        VStack(spacing: 30) {
            Rectangle().frame(width: 20, height: 20).modifier(Sampler(value: x, key: current))
            Rectangle().frame(width: 20, height: 20).modifier(Sampler(value: a, key: current + ".A"))
                .animation(.linear(duration: 1), value: a)
            Rectangle().frame(width: 20, height: 20).modifier(Sampler(value: b, key: current + ".B"))
                .transaction { t in if current == "txOverride" { t.animation = .linear(duration: 0.3) } }
            if shown {
                Text("Transition").lifecycle("anim.transitioned")
                    .transition(.modifier(active: TransitionSampler(value: 0, key: "transition"), identity: TransitionSampler(value: 1, key: "transition")))
            }
        }
        .onAppear { logCurvesAndSprings(); run() }
    }

    func run() {
        let cases: [(String, Animation?)] = [("default", .default), ("linear1", .linear(duration: 1)), ("easeInOut", .easeInOut),
            ("easeInOut1", .easeInOut(duration: 1)), ("spring", .spring()), ("bouncy", .bouncy), ("smooth", .smooth),
            ("snappy", .snappy), ("interactiveSpring", .interactiveSpring()), ("linear1delay0.5", .linear(duration: 1).delay(0.5)),
            ("linear0.5repeat2auto", .linear(duration: 0.5).repeatCount(2, autoreverses: true)), ("linear1speed2", .linear(duration: 1).speed(2)),
            ("none", nil)]
        var t = 0.5
        for (n, anim) in cases {
            let target = x == 0 ? 100.0 : 0.0
            _ = target
            after(t) {
                current = n
                Samples.begin(n)
                let from = x, to = x == 0 ? 100.0 : 0.0
                logt("anim.start", n)
                withAnimation(anim, completionCriteria: .logicallyComplete) { x = to } completion: { logt("anim.\(n).completion.logical", String(format: "%.4f", CACurrentMediaTime() - (Samples.start[n] ?? 0))) }
                after(2.4) { Samples.report(n, from: from, to: to) }
            }
            t += 2.6
        }
        // completion criteria .removed for a spring
        after(t) {
            current = "springRemoved"; Samples.begin("springRemoved")
            let from = x, to = x == 0 ? 100.0 : 0.0
            withAnimation(.spring(), completionCriteria: .removed) { x = to } completion: { logt("anim.springRemoved.completion.removed", String(format: "%.4f", CACurrentMediaTime() - (Samples.start["springRemoved"] ?? 0))) }
            after(2.4) { Samples.report("springRemoved", from: from, to: to) }
        }
        t += 2.6
        // transaction scoping: A has .animation(.linear(1), value:), B has none.
        after(t) {
            current = "implicitOnly"; Samples.begin("implicitOnly.A"); Samples.begin("implicitOnly.B")
            a = 100; b = 100   // no withAnimation
            after(1.4) { Samples.report("implicitOnly.A", from: 0, to: 100); Samples.report("implicitOnly.B", from: 0, to: 100) }
        }
        t += 1.6
        after(t) {
            current = "explicitEaseIn0.5"; Samples.begin("explicitEaseIn0.5.A"); Samples.begin("explicitEaseIn0.5.B")
            withAnimation(.easeIn(duration: 0.5)) { a = 0; b = 0 }
            after(1.4) { Samples.report("explicitEaseIn0.5.A", from: 100, to: 0); Samples.report("explicitEaseIn0.5.B", from: 100, to: 0) }
        }
        t += 1.6
        after(t) {
            current = "txOverride"; Samples.begin("txOverride.B")
            withAnimation(.linear(duration: 1.2)) { b = 100 }
            after(1.6) { Samples.report("txOverride.B", from: 0, to: 100) }
        }
        t += 1.8
        after(t) {
            current = "disables"; Samples.begin("disables.A"); Samples.begin("disables.B")
            var tx = Transaction(animation: .linear(duration: 1)); tx.disablesAnimations = true
            withTransaction(tx) { a = 100; b = 0 }
            after(1.4) { Samples.report("disables.A", from: 0, to: 100); Samples.report("disables.B", from: 100, to: 0) }
        }
        t += 1.6
        // retargeting: start linear 1s to 100, at 0.5s retarget to 0 with a spring
        after(t) {
            current = "retarget"; Samples.begin("retarget")
            x = 0
            after(0.1) {
                Samples.begin("retarget")
                withAnimation(.linear(duration: 1)) { x = 100 }
                after(0.5) { withAnimation(.spring()) { x = 0 } }
                after(2.2) { Samples.report("retarget", from: 0, to: 100) }
            }
        }
        t += 2.6
        // transitions
        after(t) {
            Samples.begin("transition"); logt("anim.transition.insert")
            withAnimation(.linear(duration: 1)) { shown = true }
            after(1.5) { Samples.report("transition", from: 0, to: 1); Samples.begin("transition"); logt("anim.transition.remove"); withAnimation(.linear(duration: 1)) { shown = false } }
            after(3.0) { Samples.report("transition", from: 1, to: 0) }
        }
        t += 3.5
        after(t) { finish() }
    }
}
