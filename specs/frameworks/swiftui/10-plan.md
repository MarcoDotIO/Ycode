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
| R5 Rendering v1 | display list, shapes and paths, colours, gradients, images (PNG/asset catalogs), clipping, opacity, transforms, `Canvas`/`GraphicsContext`; software rasteriser (ThorVG) + Vulkan compositor; symbol provider | `09` §3.5, §3.6, §5.1, `07` §3 | T-IMG (pixel probes within tolerance) — **done 2026-10-30** (OV-R5): T-IMG passes on macOS, Linux x86-64 (RTX 4060 Ti and lavapipe) and the Thor (Tegra Thor GPU); `ycode preview --render` renders a `#Preview` to PNG through it |
| R6 Animation | transactions, animatable interpolation, curve/spring/keyframe animations, completion criteria, retargeting, transitions with removal deferral, `PhaseAnimator`, `KeyframeAnimator`, `matchedGeometryEffect` (first cut) | `05` | T-ANIM (manual clock) |
| R7 App, scenes and input on Linux | `App`, `WindowGroup`, `scenePhase`, `@UIApplicationDelegateAdaptor` shim, SDL3 windows, run loop, pointer/touch → `Gesture` system (tap counts, long press, drag with velocity and 0.25 s prediction), focus, hardware-keyboard text input, `onOpenURL` | `06` §1, §5, §7 | T-LIFE, T-GEST |
| R8 Controls | `Button` and styles, `Toggle`, `Slider`, `Stepper`, `Picker` (segmented, menu), `TextField`/`SecureField`, `ProgressView`, `Gauge`, `Link`, `Label`, `LabeledContent`, `Form`, `DatePicker` (compact) — sizes per `golden-layout.md` | `06` §4, golden | T-CTL — **done 2026-10-30** (OV-R8): the 21 control rows and the spacing matrix pass exactly with the reference test font, the interaction rules pass on macOS, Linux x86-64 and the Thor; also menus with pop-up windows, `TextEditor` and the text editing core (PARITY §5.4 R14); the `ov-settings` sample runs on X11 (Xvfb, real XTEST input) and Wayland (headless Weston) |
| R9 Containers and presentation | `ScrollView` (offsets, deceleration ≈ 0.998/ms, `ScrollViewReader`, scroll geometry), `List` (row metrics, lazy materialisation), `LazyVStack`, `NavigationStack` (push/pop timing and lifecycle order, back gesture), `NavigationSplitView` collapsed behaviour, `TabView`, sheets with detents, alerts, dialogs, popovers, full-screen covers | `06` §2, §3, §6 | T-NAV, T-LIST, T-MODAL — **done 2026-10-30** (OV-R9): T-LIST, T-NAV and T-MODAL pass on macOS, Linux x86-64 and the Thor, with the golden `scrollView` rows; also lazy stacks and grids, list selection and keyboard, `OutlineGroup`/`List(children:)`/`DisclosureGroup`, `NavigationSplitView` with resizable columns, `HSplitView`/`VSplitView` (PARITY §5.4 R12); the `ov-mini-ide` sample runs on X11 (Xvfb, real XTEST input) and Wayland (headless Weston) |
| R10 Environment, persistence, accessibility | live environment updates from platform settings, `@AppStorage` on `UserDefaults`, `@SceneStorage`, accessibility tree and AT-SPI export (planned through AccessKit; done with our own D-Bus client), accessibility modifiers and default labels, reduce-motion etc. | `08`, `06` §8 | T-ENV, T-AX, T-PERSIST, T-ATSPI — **done 2026-10-30** (OV-R11; the AT-SPI export by OV-ATSPI): T-ENV, T-AX and T-PERSIST pass on macOS, Linux x86-64 and the Thor; settings from environment variables, a watched settings file, the freedesktop settings portal (through `gdbus`) and SDL's theme reach the environment live; the tree has the 08 §2 elements. AccessKit's Rust build was refused, so the export is our own: a D-Bus client and an AT-SPI2 exporter in Swift (09 §4.5); T-ATSPI passes on all three machines, and a libatspi client sees the mini IDE's window, menu bar, outline rows, editor and toolbar buttons with names, roles, states and actions, invokes Build, and receives focus and text events on the x86 workstation (X11) and the Thor (Wayland) |
| R11 Commands and menus (`docs/PARITY.md` §5.4) | an in-window menu bar from `commands` (`CommandMenu`, `CommandGroup`, standard groups), shortcuts routed through focus, focused values, the Edit menu on R8's editing core, context menus, window toolbars with placements, the `Settings` scene | PARITY §5.4 (public API, level 1) | ours — **done 2026-10-30** (OV-R11): the commands, context-menu and toolbar tests pass on all three machines; the `ov-mini-ide` sample has a menu bar, a toolbar with Build and Run, an outline context menu and a Settings window, on X11 (Xvfb, real XTEST input) and Wayland (headless Weston) |
| R13 Shell gaps and editor support (`docs/PARITY.md` §5.8, §5.9) | custom `ToolbarContent`; submenu shortcuts in `commands`; `task(id:)`/`FocusState`; outline row selection IDs and initial expansion; identifiers in list rows; `help` tooltips; `fileImporter`/`fileExporter` (own dialog, `UTType`); `toolbar(removing: .sidebarToggle)`; the shell's symbols; a bundled monospace font; `onKeyPress`; scroll geometry and `Canvas` text for a 10 000-line surface at 60 fps; `Table` (R12 leftover) | public API documentation (level 1); PARITY §5.8 | ours — **done 2026-10-31** (OV-R13): the R13 suites pass on macOS, Linux x86-64 and the Thor; `ov-editor-bench` (release) scrolls 10 000 lines at 6.2 ms per frame on x86-64 and 7.1 ms on the Thor at scale 1 (12.5 and 11.5 ms at scale 2); `ycode-ide` uses the features (submenus, tooltips, File ▸ Open… dialog, no column bar) and passes its tests and its X11 driver runs (Xvfb, real input) |

Status (2026-10-30): R1, R2, R3 (core), R4, R5 and R6 done; **R7 done**
(OV-R7): `OVPlatform` with SDL3 X11/Wayland and
headless back ends, run loop and display link, the app model and scene
phases, the gesture system, focus, hardware-keyboard text input with IME
composition, keyboard shortcuts, `onOpenURL`; T-LIFE and T-GEST pass on the
headless host on macOS, Linux x86-64 and the Thor; the sample app runs on
X11 (Xvfb, real input through XTEST; presented by R5's Vulkan compositor on
the workstation's GPU) and Wayland (headless Weston; software compositor).
**R8 done** (OV-R8): the controls of the row above with their styles,
keyboard focus between controls, `Menu` and pop-up menu windows through
`OVPlatform`, `TextEditor`, and the text editing core in OVText (selection,
word and line movement, undo, IME marked text) that EditorKit will build on.
**R9 done** (OV-R9): scroll views with drag deceleration, wheel input,
indicators and scroll geometry; lazy containers that materialise only the
visible rows; lists with styles, sections, selection and keyboard; outlines
and disclosure groups; navigation stacks with the reference's lifecycle
order and back swipe; split views; tab views; sheets, covers, alerts,
dialogs, popovers and inspectors; covered pages keep their state
(suspension).
**R10 done** (OV-R11; its AT-SPI export by OV-ATSPI) and **R11 done** (OV-R11): desktop
settings reach the environment while the app runs; `@AppStorage` sees
writes made through `UserDefaults` directly; `@SceneStorage` per window with
the 06 §8 discard-after-quit rule; the accessibility tree with modifiers,
control annotations and actions, exported to AT-SPI2 by our own D-Bus
client and exporter (OV-ATSPI); the menu bar, focused values, context
menus, window toolbars and Settings of R11. **R13 done** (OV-R13,
2026-10-31): the gaps the Linux IDE shell found and the toolkit pieces
EditorKit (L2) needs, listed in the row above. Details,
rules we chose and open questions: `frameworks/swiftui/README.md`.

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
| T-IMG | Headless renders at scale 2 on white (black in dark mode), sampled at points: colours fill exact frames (07 §4 values, light and dark); shapes, strokes (centred, inside, dashed), `trim`; linear/radial/angular gradients; colour and modifier opacity, `hidden`, multiply blending, background/overlay order, `border`; `clipShape`, `clipped`, `cornerRadius`, `mask`; `offset`, `rotationEffect`, `scaleEffect`; shadow and blur; `colorMultiply`; PNG/JPEG, template and named images; text ink and colour; symbols (box, tint, missing-name placeholder and the reference's 0 × 0 mode); `Canvas`; `ImageRenderer`; right-to-left. Golden scenes `img.shapes`, `img.gradients`, `img.composite`(`.dark`); the Vulkan compositor's read-back against the CPU rasteriser | Ycode-original scenes; colours `07` §4; symbol boxes `07` §3 | ±2 per channel (gradients ±3–8, JPEG ±12, angular ±30); goldens ±3 per channel with ≤ 0.2 % of values beyond; Vulkan vs CPU ±2 |
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
| T-ATSPI | D-Bus marshalling against the specification's examples and round trips of every type; the OpenViews → AT-SPI role and state table; the exporter over a private bus (registration, laziness, objects, actions, events); an AT-SPI client check of the mini IDE | D-Bus Specification; at-spi2-core `xml/` | exact |
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
10. (R7) Gesture thresholds the `gesture` probe did not measure: tap
    movement tolerance, multi-tap interval and distance, button release
    slop, the drag velocity estimator; whether `LongPressGesture` reports
    `true` to `updating`/`onChanged` at touch-down and whether `onChanged`
    receives the final value; a `SequenceGesture`'s value when its second
    gesture fails; nested hover order.

11. (R8) Control metrics outside the golden table (segmented title font
    and padding, the plain secure field's 21-point height, the rounded
    field's inset split, form rows outside UIKit hosting) and the
    reference's text-editing details (word rules, undo grouping, caret
    blink).

12. (R9) Container details the probes did not measure: the push and
    sheet animation curves; the list's first-row offset (06 §3's
    `scrollTo` offset implies 13.33, the informative golden `list.two`
    shows 35); the detent heights other than `.medium`/`.large` and the
    rule behind 356 points; when `onScrollGeometryChange` first fires;
    lazy-stack overscan on other devices; scroll indicator timing; the
    back swipe's completion threshold; split-view column widths in a
    regular width (blocked with question 9).

13. (R10, R11) Desktop behaviour without any reference measurement: how
    the reference maps desktop text scales to Dynamic Type sizes and which
    settings it follows on a desktop; which accessibility modifier wins when
    two set one attribute; the default accessibility labels of symbols other
    than "star.fill"; the menu layout, default commands and shortcut
    precedence of a desktop SwiftUI app (a macOS probe would settle these;
    the iOS device has no menu bar).

## Evidence

| Claim | Level |
|---|---|
| Expected values referenced by the suites | 3 (reference runs; see the files cited per suite) |
| R11 API names (commands, menus, toolbars, focused values, context menus, `Settings`) | 1 (public API documentation; `docs/PARITY.md` §5.4) |
| Plan, rounds, tolerances, fonts policy | Ycode-original (no evidence claim) |
