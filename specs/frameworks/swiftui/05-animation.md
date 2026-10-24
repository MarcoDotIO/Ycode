# SwiftUI 5: animation, transactions, transitions

Status: draft, round 0 (KIT-SWIFTUI, 2026-10-19). Concepts from public
documentation (level 1); numbers from our probe (level 3, mode `anim`,
`research/experiments/swiftui/results/anim.log`). Pure-API values (curves,
springs, keyframes) are exact and host-independent. Sampled-while-
rendering values were taken on a heavily loaded Mac (load average 300–560)
and are accurate to about one frame (16.7 ms).

## 1. The model

- A **state change** happens inside a **transaction**. A transaction
  carries an optional `Animation` and flags (`disablesAnimations`,
  `isContinuous`, custom `TransactionKey` values, completion handlers).
  `withAnimation(_:_:)` runs a closure in a transaction whose animation is
  the given one; `withTransaction(_:_:)` takes a full transaction.
- After the change, SwiftUI re-evaluates the affected views. For each
  **animatable** value that differs between the old and new view tree
  (`Animatable.animatableData`: geometry from layout, colours, opacity,
  offsets, scale, rotation, custom `Animatable` modifiers and shapes), if
  the transaction that reached that view has an animation, the rendered
  value moves from old to new over time; the model value is the new value
  immediately.
- **Per-view override:** modifiers can rewrite the transaction that
  reaches their subtree: `.animation(_:value:)` sets the animation for its
  subtree whenever `value` changed in this update; `.transaction(_:)`
  edits the transaction for its subtree; `.animation(nil, value:)`
  removes it.
- **Frames:** during an animation, the animatable modifier's `body` is
  evaluated once per display frame. We counted 61 evaluations for a
  1-second linear animation (60 Hz display link; the display link measured
  56–60 Hz on the loaded host).

## 2. Built-in timing curves (`UnitCurve`, exact)

Values of `UnitCurve.value(at:)` for t = 0, 0.1, …, 1:

| Curve | Values | Cubic Bézier control points (derived) |
|---|---|---|
| `linear` | t | (0,0)–(1,1) |
| `easeIn` | 0, 0.0170, 0.0623, 0.1296, 0.2149, 0.3154, 0.4291, 0.5548, 0.6916, 0.8394, 1 | (0.42, 0), (1, 1) |
| `easeOut` | 0, 0.1606, 0.3084, 0.4452, 0.5709, 0.6846, 0.7851, 0.8704, 0.9377, 0.9830, 1 | (0, 0), (0.58, 1) |
| `easeInOut` | 0, 0.0197, 0.0817, 0.1874, 0.3319, 0.5, 0.6681, 0.8126, 0.9183, 0.9803, 1 | (0.42, 0), (0.58, 1) |
| `circularEaseIn` | 0, 0.0050, 0.0202, 0.0461, 0.0835, 0.1340, 0.2000, 0.2859, 0.4000, 0.5641, 1 | 1 − √(1 − t²) |
| `circularEaseOut` | 0, 0.4359, 0.6, 0.7141, 0.8, 0.8660, 0.9165, 0.9539, 0.9798, 0.9950, 1 | √(1 − (1 − t)²) |
| `circularEaseInOut` | 0, 0.0101, 0.0417, 0.1, 0.2, 0.5, 0.8, 0.9, 0.9583, 0.9899, 1 | piecewise of the two above |
| `.bezier(startControlPoint: (0.2, 0), endControlPoint: (0, 1))` | 0, 0.1562, 0.5, 0.6881, 0.8023, 0.8778, 0.9291, 0.9633, 0.9849, 0.9965, 1 | as given |

`velocity(at:)` at t = 0, 0.5, 1: linear 1, 1, 1; easeIn 0, 1.0740, 0;
easeOut 1, 1.0740, 0; easeInOut 0, 1.7241, 0; circular curves have
infinite velocity at their steep ends.

Bézier curves are evaluated in the usual way: solve x(s) = t for the
curve parameter s, return y(s). The control points above reproduce every
listed value (the x and y polynomial coefficients we observed in the
`description` of the animation values match 3·P1, 3·(P2 − 2·P1),
1 − 3·P2 + 3·P1 for these points).

## 3. Springs (`Spring`, exact)

Relations (all observed, consistent with a damped harmonic oscillator of
mass m, stiffness k, damping c):

- `response` = 2π·√(m/k); `dampingRatio` = c / (2·√(k·m));
  `duration` = `response` (perceptual duration); `bounce` = 1 −
  `dampingRatio` for under-damped springs; for `bounce` < 0 the ratio is
  1 / (1 + `bounce`) (bounce −0.3 → ratio 1.4286).
- Mass defaults to 1. `Spring(duration: 0.5, bounce: 0)` → stiffness
  157.9137, damping 25.1327.

| Spring | response | dampingRatio | bounce | stiffness | damping | settlingDuration |
|---|---|---|---|---|---|---|
| `Spring()` (default), `.smooth` | 0.5 | 1.0 | 0 | 157.9137 | 25.1327 | 0.8 |
| `.snappy` | 0.5 | 0.85 | 0.15 | 157.9137 | 21.3628 | 0.8768 |
| `.bouncy`, `Spring(duration: 0.5, bounce: 0.3)` | 0.5 | 0.7 | 0.3 | 157.9137 | 17.5929 | 1.0447 |
| `Spring(response: 0.55, dampingRatio: 0.825)` | 0.55 | 0.825 | 0.175 | 130.5072 | 18.8496 | 0.9817 |
| `Spring(mass: 1, stiffness: 100, damping: 10)` | 0.6283 | 0.5 | 0.5 | 100 | 10 | 1.7399 |
| `Spring(duration: 0.5, bounce: -0.3)` | 0.5 | 1.4286 | −0.3 | 486.6319 | 35.9039 | 1.4 |

`value(target: 1, initialVelocity: 0, time:)` at t = 0, 0.05, …, 0.5
(full series to 1.5 s in the log):

| Spring | 0.05 | 0.10 | 0.15 | 0.20 | 0.25 | 0.30 | 0.35 | 0.40 | 0.45 | 0.50 |
|---|---|---|---|---|---|---|---|---|---|---|
| smooth | 0.1313 | 0.3577 | 0.5620 | 0.7154 | 0.8210 | 0.8900 | 0.9336 | 0.9605 | 0.9767 | 0.9864 |
| snappy | 0.1382 | 0.3881 | 0.6177 | 0.7864 | 0.8945 | 0.9564 | 0.9880 | 1.0016 | 1.0059 | 1.0060 |
| bouncy | 0.1457 | 0.4233 | 0.6851 | 0.8737 | 0.9841 | 1.0339 | 1.0460 | 1.0393 | 1.0265 | 1.0145 |
| k100/c10 | 0.1044 | 0.3403 | 0.6105 | 0.8494 | 1.0234 | 1.1244 | 1.1616 | 1.1531 | 1.1184 | 1.0746 |

The values match the closed-form solution of m·x″ + c·x′ + k·(x − 1) = 0
with x(0) = 0, x′(0) = 0 (critically damped for ratio 1). An open
implementation must reproduce these to 1e-4.

## 4. `Animation` values and their timing (sampled while rendering)

| Animation | Parameters (observed) | Rendered duration (first frame at target) | Logical completion |
|---|---|---|---|
| `.default` | a spring like `.smooth` (values track the response-0.5 critically damped spring, offset by the first frame) | ≈ 1.03 s; value keeps changing (by < 0.01 %) until 1.28 s | 0.53 s |
| `.linear`, `.easeIn`, `.easeOut`, `.easeInOut` (no duration) | Bézier curve, **0.35 s** | 0.37 s (easeInOut) | 0.37 s |
| `.linear(duration: 1)` | exact ramp (v@0.25 = 0.2465, v@0.5 = 0.4959 after one-frame start latency) | 1.00 s | 1.02 s |
| `.easeInOut(duration: 1)` | curve of §2 (v@0.25 = 0.119, v@0.75 = 0.860) | 1.01 s | 1.03 s |
| `.spring()` | response 0.5, damping fraction 1.0, blend 0 | ≈ 1.01 s | 0.51 s |
| `.bouncy` | response 0.5, damping 0.7; overshoot max 1.0419 | 0.94 s | 0.51 s |
| `.smooth` | response 0.5, damping 1.0 | ≈ 1.02 s | 0.52 s |
| `.snappy` | response 0.5, damping 0.85; overshoot 1.0044 | 0.85 s | 0.51 s |
| `.interactiveSpring()` | response 0.15, damping 0.85, blend 0.25 | 0.26 s | 0.18 s |
| `.interpolatingSpring()` | mass 1, stiffness 157.9137, damping 25.1327, initial velocity 0 | — | — |
| `.linear(duration: 1).delay(0.5)` | no frames are produced during the delay; ramp from 0.5 to 1.5 s | 1.51 s | 1.53 s |
| `.linear(duration: 0.5).repeatCount(2, autoreverses: true)` | 0 → 1 in 0.5 s, back to 0 at 1.0 s, then **jumps to the model value** (1) | 1.04 s (jump) | 1.04 s |
| `.linear(duration: 1).speed(2)` | half the duration | 0.51 s | 0.52 s |
| `nil` (no animation) | value changes in the next frame | 0 | 0.01 s |

Rules derived:

- **Logical completion** (`withAnimation(_:completionCriteria: .logicallyComplete, …)`)
  fires at the animation's nominal duration (springs: their `response`/
  `duration`, 0.5 s here), not when motion stops.
  `.removed` fires when the animation is removed from the view (1.28 s for
  `.spring()`, i.e. after it settled).
- **Start latency:** the first animated frame is one display frame after
  the state change (≈ 17–33 ms on the loaded host).

### 4.1 Transaction scoping (measured)

| Case | View A: `.animation(.linear(duration: 1), value: a)` | View B: no modifier |
|---|---|---|
| change `a` and `b` without `withAnimation` | animates, 1 s linear | **jumps** |
| `withAnimation(.easeIn(duration: 0.5))` changing both | **1 s linear** (the view's own modifier wins in its subtree) | 0.5 s ease-in (v@0.25 = 0.293) |
| `withAnimation(.linear(duration: 1.2))` with `.transaction { $0.animation = .linear(duration: 0.3) }` on B | — | **0.3 s** (the transaction modifier rewrites what reaches B) |
| `withTransaction` (animation linear 1 s, `disablesAnimations = true`) | 1 s linear (indistinguishable from its own modifier; open question) | **animates 1 s**: `disablesAnimations` does not cancel the transaction's own animation; documented purpose: it disables implicit `.animation` modifiers |

### 4.2 Retargeting

A `.linear(duration: 1)` animation from 0 to 100 was interrupted at 0.5 s
(value 50) by `withAnimation(.spring()) { x = 0 }`. The rendered value did
not jump: it continued from 50 and moved smoothly to 0 (49.2 one frame
later, 0.11 × at 0.75 s, 0.0097 × at 1.0 s), i.e. the new animation
starts from the current presentation value. Spring-to-spring
retargeting additionally carries velocity (public documentation, WWDC23
"Animate with springs").

## 5. Transitions

- `.transition(_:)` applies when a view is **inserted or removed** by a
  state change in an animated transaction. Custom transitions via
  `.modifier(active:identity:)` animate from the active to the identity
  modifier on insertion and back on removal.
- **Insertion:** the view's `onAppear` fires at the start (30 ms after the
  change), the animation runs (our sampler: 0 → 1 over 1 s, 61 frames).
- **Removal:** the view stays in the tree and is rendered until the
  removal animation ends; its `onDisappear` (and the cancellation of its
  `task`) fires **at the end** (1.03 s after the change for a 1 s linear
  animation).
- Without an animation, insertion and removal are immediate.
- The default transition (none specified) is opacity (public
  documentation).

## 6. Keyframes (`KeyframeTimeline`, exact)

Timeline with `LinearKeyframe(100, duration: 1)`, `SpringKeyframe(0,
duration: 1)`, `CubicKeyframe(50, duration: 0.5)`, `MoveKeyframe(10)`,
`CubicKeyframe(20, duration: 0.5)` from initial value 0: duration 3.0;
value every 0.1 s:

0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 67.07, 30.08, 11.69, 4.22,
1.45, 0.49, 0.16, 0.05, 0.02, 0.01, 5.20, 17.60, 32.40, 44.80, 50, 11.04,
13.52, 16.48, 18.96, 20.

Rules: keyframe durations add up; a `MoveKeyframe` jumps without taking
time; a `SpringKeyframe` springs toward its value for its duration (the
default spring — values match the smooth spring of §3 scaled to the
100 → 0 segment); in this timeline both `CubicKeyframe` segments follow
v0 + (v1 − v0)·(3u² − 2u³) exactly (u = segment progress), i.e. a cubic
Hermite segment with zero end slopes (its neighbours are a settled spring,
a move and the end). How slopes are chosen when cubic keyframes follow each
other with non-zero slopes was not measured (open; round R6 must probe it).

## 7. What an implementation needs

- A display-tick driver at the display's rate (60 Hz on the simulator; a
  `CADisplayLink` there reports `maximumFramesPerSecond` = 60).
- Exact curve and spring math (§2–3) — these are testable without
  rendering (`10-plan.md` T-CURVE, T-SPRING, T-KEYFRAME).
- Transaction propagation and override rules (§4.1), completion criteria,
  retargeting (§4.2), removal deferral (§5).

## Evidence

| Claim | Level |
|---|---|
| Transaction/animation/Animatable model, completion criteria, transitions, keyframes as concepts | 1 (developer.apple.com `Animation`, `Transaction`, `Spring`, `UnitCurve`, `KeyframeTimeline`; WWDC23 sessions 10156 "Explore SwiftUI animation", 10157 "Wind your way through advanced animations in SwiftUI", 10158 "Animate with springs") |
| Every number in §2–6 | 3 (`SUIProbe` mode `anim`, iOS 27.1 simulator) |
| Bézier control points and spring formulas | 3 (derived from the measured values; checked against them) |
| Animation parameters (durations, responses) | 3 (printed `description` of our own `Animation` values; only parameter values are used here, not type names) |
