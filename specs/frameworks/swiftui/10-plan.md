# SwiftUI 10: implementation rounds and conformance tests

Status: proposal, round 0 (KIT-SWIFTUI, 2026-10-19). Ycode-original plan.
Clean-room agents implement from files 03–09, `golden-layout.md` and
`api-inventory.md` only. They must not open the reference tools (the Xcode
copy, Ghidra, the IPSW), `research/dirty/`, Ghidra projects, or the
OpenSwiftUI/OpenAttributeGraph sources (`09-open-design.md` §5.4).

## 1. Simulator track (Ycode's iOS simulator; owners from the simulator team)

SwiftUI apps use Apple's SwiftUI inside the guest, so these items are
about services and host features, and they are the "easy win": most of
them are already needed for any UIKit app.

| Item | Scope | Exit criterion (from `02-conformance-checklist.md`) |
|---|---|---|
| S-SUI1 Launch and scene lifecycle | FrontBoard scene connection, runningboard assertions, the services of `01` §3.1 | A-1…A-6, A-9, A-10, B-1, B-2 pass under Ycode |
| S-SUI2 Fonts and text | fontservicesd reachable, the runtime's font files, content-size preference + notification | C-1 (all text cases), C-3 exact; L-4 |
| S-SUI3 Rendering and frame pacing | CARenderServer path, 60 Hz display link, Metal and IOSurface host services for materials and coloured symbols | A-3, I-3…I-7, B-5, H-1…H-5, M-1; screenshots of `images` and `modal` visually match |
| S-SUI4 Input | touch (taps, double taps, long press, drags with correct timestamps), back-swipe edge gesture, hardware keyboard keys, hardware-keyboard-attached state | D-3, D-4, E-3, E-5, F-3…F-6, G-1…G-6, J-1…J-6 |
| S-SUI5 Settings and notifications | `simctl ui`-equivalent controls in Ycode (appearance, content size, contrast) that write the device preferences and post the notifications of `01` §3.4; time zone from the host | L-1…L-6, M-3, M-4 |
| S-SUI6 Text input services | demand launch of `kbd`, pasteboard, the other text-input services of `01` §3.2; later the software keyboard | B-4, G-1…G-6; K-3 once measured |
| S-SUI7 URL opening and persistence | SpringBoard open-URL prompt and delivery; cfprefsd; saved-state handling on terminate | A-7, A-8, M-5 |

Recommended order: S-SUI1 → S-SUI3 → S-SUI2 → S-SUI4 → S-SUI5 →
S-SUI6 → S-SUI7. One agent each; every item ends with the probe modes
named above passing on the Thor under Ycode with the logs diffed against
`research/experiments/swiftui/results/`.

## 2. Open implementation track ("OpenViews", `09-open-design.md`)

Library location (proposal): `ycode/Frameworks/SwiftUI/`, SwiftPM,
building on macOS and on the Linux workstation (Swift 6.4). Each round
ends with its tests green on Linux against the headless back end.

| Round | Scope | Spec input | Exit criterion |
|---|---|---|---|
| R1 Value types and math | geometry and alignment types, `EdgeInsets`, `UnitPoint`, `Angle`, `Color` (+ `Resolved`, the semantic colour tables), `UnitCurve`, `Spring`, `KeyframeTimeline` and keyframe types, `Animation` values (durations, springs, delay/speed/repeat) | `05` §2–3, §6; `07` §4 | T-CURVE, T-SPRING, T-KEYFRAME, T-COLOR exact |
| R2 Graph runtime, views and data flow | `OVGraph`; `View`, `ViewBuilder`, `ViewModifier`, primitive views; identity, state storage, `@State`, `@Binding`, `@Observable` integration, `ObservableObject` wrappers, environment, preferences, `onAppear`/`onDisappear`/`onChange`/`task` ordering; headless host with a manual clock | `03` | T-DF (counts and orders of `dataflow`) exact |
| R3 Layout | `Layout` protocol and `ProposedViewSize`, `HStack`/`VStack`/`ZStack` (spacing preferences, distribution, alignment), `Spacer`, `Divider`, frames, padding, `fixedSize`, `layoutPriority`, `aspectRatio`, overlay/background, `position`/`offset`, `GeometryReader`, `Grid`, `LazyVGrid`/`LazyHGrid`, `ViewThatFits`, `AnyLayout`, safe areas, RTL mirroring, pixel rounding | `04`, `golden-layout.md`, `08` §3 | T-LAYOUT-F exact; T-LAYOUT-T relations; T-RTL |
| R4 Text | `OVText`: font discovery, text styles and Dynamic Type sizes (`07` §1), shaping, line breaking, truncation, line limits, baselines, `Text` concatenation and formatting, `LocalizedStringKey` lookup in `.strings`/`.xcstrings` | `04` §3, `07` §1–2, `08` §3 | T-TEXT, T-L10N |
| R5 Rendering v1 | display list, shapes and paths, colours, gradients, images (PNG/asset catalogs), clipping, opacity, transforms, `Canvas`/`GraphicsContext`; software rasteriser (ThorVG) + Vulkan compositor; symbol provider | `09` §3.5, §5.1, `07` §3 | T-IMG (pixel probes within tolerance) |
| R6 Animation | transactions, animatable interpolation, curve/spring/keyframe animations, completion criteria, retargeting, transitions with removal deferral, `PhaseAnimator`, `KeyframeAnimator`, `matchedGeometryEffect` (first cut) | `05` | T-ANIM (manual clock) |
| R7 App, scenes and input on Linux | `App`, `WindowGroup`, `scenePhase`, `@UIApplicationDelegateAdaptor` shim, SDL3 windows, run loop, pointer/touch → `Gesture` system (tap counts, long press, drag with velocity and 0.25 s prediction), focus, hardware-keyboard text input, `onOpenURL` | `06` §1, §5, §7 | T-LIFE, T-GEST |
| R8 Controls | `Button` and styles, `Toggle`, `Slider`, `Stepper`, `Picker` (segmented, menu), `TextField`/`SecureField`, `ProgressView`, `Gauge`, `Link`, `Label`, `LabeledContent`, `Form`, `DatePicker` (compact) — sizes per `golden-layout.md` | `06` §4, golden | T-CTL |
| R9 Containers and presentation | `ScrollView` (offsets, deceleration ≈ 0.998/ms, `ScrollViewReader`, scroll geometry), `List` (row metrics, lazy materialisation), `LazyVStack`, `NavigationStack` (push/pop timing and lifecycle order, back gesture), `NavigationSplitView` collapsed behaviour, `TabView`, sheets with detents, alerts, dialogs, popovers, full-screen covers | `06` §2, §3, §6 | T-NAV, T-LIST, T-MODAL |
| R10 Environment, persistence, accessibility | live environment updates from platform settings, `@AppStorage` on `UserDefaults`, `@SceneStorage`, accessibility tree and AT-SPI export (AccessKit), accessibility modifiers and default labels, reduce-motion etc. | `08`, `06` §8 | T-ENV, T-AX, T-PERSIST |

## 3. Conformance tests

### 3.1 Principle

One test source, two implementations. The probe cases are written
against the public API; on Apple's simulator they produced the reference
logs (`research/experiments/swiftui/results/`). Ported into a SwiftPM test
target (Swift Testing), the same cases run against OpenViews' headless
host and compare. When a reference value is missing, an agent with Mac
access adds a case to `SUIProbe`, runs it on Apple's simulator, commits
the log, and only then implements.

### 3.2 Suites

| Suite | Content | Expected | Tolerance |
|---|---|---|---|
| T-CURVE | `UnitCurve.value(at:)`/`velocity(at:)` for 8 curves at 11 points | `05` §2 | 1e-4 |
| T-SPRING | `Spring` parameters of 8 springs and `value(target:initialVelocity:time:)` at 31 times | `05` §3, `results/anim.log` | 1e-4 |
| T-KEYFRAME | the keyframe timeline of `05` §6 | 31 values | 0.01 |
| T-COLOR | `Color.resolve(in:)` light/dark for 32 colours; increased contrast for `blue`/`accentColor` | `07` §4 | exact hex |
| T-DF | the `dataflow` script: body sets per step, appear/disappear order, preference order | `03` §2, §4.1 | exact |
| T-LAYOUT-F | font-independent golden cases: colours, shapes, spacers, dividers, fixed frames, flexible frames on colours, padding on colours, aspect ratios, stacks of fixed-size colours (`hstack.colors`, `hstack.twoColors`, `hstack.threeColors.spacing0`, `vstack.colors`, `hstack.top`, `layoutPriority.vstack`), `zstack` around a fixed colour, `clipped`, `lazyvgrid.*`, `geometryReader`, `circle`, `capsule`, `frame.minmax`, `frame.ideal*` | `golden-layout.md` | 0.01 pt |
| T-LAYOUT-T | text-dependent cases checked as **relations** with our font: wrapped width ≤ proposal and = longest line; height = first line + (n−1) × pitch; zero proposal → 0 × 0; `lineLimit`; stack spacing = 8 horizontally; vertical text spacing derived from metrics; centring offsets = (container − child)/2; priority distribution order (`hstack.priority`: low-priority child gets what remains after the other's answer) | `04` §3–4 | exact relations |
| T-LAYOUT-SF | (macOS only, optional) the same cases with the reference font installed locally from a Mac (never redistributed) must match the golden values exactly | `golden-layout.md` | 0.01 pt |
| T-RTL | `layout-ar` frames as mirrors of `layout` (x' = W − x − w), offsets negated, safe-area leading/trailing swapped | `08` §3 | 0.01 pt |
| T-TEXT | Dynamic Type point-size table for 13 styles × 12 categories; default font metrics ratios; truncation produces an ellipsis | `07` §1 | exact sizes |
| T-L10N | `.strings` lookup, verbatim text, interpolation key `%lld`, locale-specific number/date formats via Foundation, RTL direction from the language | `08` §3 | exact strings |
| T-ANIM | with a manual 60 Hz clock: frames per animation, `v@` samples, completion times, transaction scoping (4 cases), retarget continuity, transition removal deferral | `05` §4–5 | ±1 frame, ±0.01 |
| T-LIFE | scene phase sequences of `06` §1 on the headless host (simulated activate/background) | `06` §1 | order |
| T-GEST | synthetic touch streams: tap, double tap (120 ms), long press 0.5 s, drag (minimum distance 10, `predictedEndTranslation` = translation + 0.25 × velocity), simultaneous gesture | `06` §7 | ±0.5 pt, order |
| T-CTL | control sizes (golden) and interaction rules (slider track tap does nothing; stepper ±1) | `golden-layout.md`, `06` §4 | 0.01 pt / exact |
| T-NAV | push/pop sequences of `nav` with lifecycle order and 0.5 s timing; `[4,5]` multi-push behaviour | `06` §2 | order, ±2 frames |
| T-LIST | materialisation counts for `List`/`LazyVStack`/`VStack` at a 382 × 644 viewport with 52/48-pt rows; `scrollTo` offsets | `06` §3 | exact |
| T-MODAL | sheet frames per detent, dismissal callback order | `06` §6 | exact (geometry is ours to keep) |
| T-ENV | defaults table; live updates when the platform setting changes | `08` §1 | exact |
| T-AX | element list (labels, values, hints, trait set) for the `a11y` screen; decorative/hidden elements omitted; `.combine` joins labels with ", " | `08` §2 | exact |
| T-PERSIST | `@AppStorage` round trip and external-write observation; `@SceneStorage` restoration rules | `06` §8 | exact |

### 3.3 Fonts in tests

The open implementation cannot ship Apple's fonts. Font-independent cases
are exact. Text cases use a bundled OFL font and assert the relations of
T-LAYOUT-T; a developer on a Mac may run T-LAYOUT-SF against the locally
installed system font to check the numeric rules exactly (the font is
read from the local system, never copied into the repository).

## 4. Open questions (next probe round)

1. Software keyboard: frames, animation and keyboard-avoidance insets for
   this device (needs the hardware keyboard detached; S-SUI6 K-3).
2. `.equatable()` semantics for views with non-POD fields (`03` §8).
3. `disablesAnimations` with differing implicit and explicit animations
   (`05` §4.1).
4. Slopes of consecutive cubic keyframes (`05` §6).
5. `@SceneStorage` restoration after a system-initiated termination.
6. Stepper's accessibility element (`08` §2) and identifiers through
   the accessibility API.
7. Vertical text spacing rule in closed form (from font metrics) — needed
   for exact T-LAYOUT-T relations (`04` §4.1).
8. Whether `Image(systemName: "arrow.forward")` artwork mirrors in RTL.
9. Behaviour on an iPad-class device (regular width: split view columns,
   popovers, sheets as form sheets) — blocked by the 27.1 runtime on this
   Mac (`specs/simulator/ipad.md`).

## Evidence

| Claim | Level |
|---|---|
| Expected values referenced by the suites | 3 (reference runs; see the files cited per suite) |
| Plan, rounds, tolerances, fonts policy | Ycode-original (no evidence claim) |
