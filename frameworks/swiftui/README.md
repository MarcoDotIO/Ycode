# ycode-swiftui ("OpenViews")

A clean-room, Linux-buildable implementation of SwiftUI, written only from
`specs/frameworks/swiftui/` under the protocol in `AGENTS.md`. The spec's
design note (`09-open-design.md`) calls the open library **OpenViews**.

Status: rounds **R1** (value types and math), **R2** (graph runtime, views
and data flow), the core of **R3** (layout), **R4** (text) and **R6**
(animation) of `10-plan.md` §2. Views are kept in a retained graph that
re-evaluates exactly the bodies the spec's measured rules say, and lower onto
the R3 layout engine; text is typeset by our own OVText module with open
fonts; animations run on an injectable clock and are observed through a
presentation of the layout tree. There is no rendering (R5) and no platform
host or display link (R7) yet; tests drive a headless host with a manual
60 Hz clock.

## Modules

| Module (Linux) | Module (Apple hosts) | Content |
|---|---|---|
| `SwiftUICore` | `OpenViewsCore` | Value types, `Layout` and the built-in stacks, the layout engine; `View`, `ViewBuilder`, `ViewModifier`, primitive views, the view graph, state and data flow, environment, preferences, transactions; animation (animations, keyframes, transitions, animator views) |
| `OVText` | `OVText` | Fonts and text layout without view types (R4): OpenType reader, font catalog and matching, shaping, UAX #14 line breaking, UAX #9 bidi, paragraph typesetter; bundles Noto Sans |
| `SwiftUI` | `OpenViews` | Re-exports the core; `GridLayout`, `GridItem`, `Grid`/`GridRow`, lazy grids, `Divider`, `ViewThatFits`, `EquatableView`, `ScenePhase` |

`SwiftUI` and `SwiftUICore` are interop identifiers: on Linux the modules
carry exactly those names so `import SwiftUI` compiles unchanged. On macOS
those names belong to the system frameworks, and a package module of the same
name would shadow them, so `Package.swift` builds the same sources as
`OpenViews` / `OpenViewsCore` and defines `OPENVIEWS_RENAMED`; sources and
tests pick their imports with `#if OPENVIEWS_RENAMED`. The switch follows the
host that evaluates the manifest (cross-compiling from macOS to Linux is not
covered). The split between the two modules follows the SDK's
(`api-inventory.md` lists where each type lives).

Dependencies: none beyond the Swift 6.4 toolchain (Foundation, Dispatch,
Synchronization, Observation, Swift Testing). No third-party code: font
reading, shaping, line breaking and bidi are our own implementations (see
"Text design (R4)"), so the build needs no system libraries and stays fast.

Bundled font data (runtime resources of `OVText`, `Sources/OVText/Resources/Fonts/`):

| Font | Version | Licence | Provenance |
|---|---|---|---|
| Noto Sans Regular and Bold (`NotoSans-Regular.ttf`, `NotoSans-Bold.ttf`) | 2.004 (sha256 `89c3c497…2909d`, `e83493c9…272ac5`) | SIL Open Font License 1.1 (`OFL.txt` next to the files; © 2015 Google LLC) | Upstream Noto fonts (github.com/notofonts), as packaged by Ubuntu `fonts-noto-core` 20201225-2build1; unmodified |

Apple's system fonts are never used or shipped: the font catalog refuses
their family names (`SF …`, `New York`, names starting with `.`) and scans
no system font directory on Apple hosts. On Apple hosts `Combine` is
re-exported for `ObservableObject`/`@Published` (as `import SwiftUI` does);
Linux has no Combine, so the core defines the same names with the subset the
graph needs (`ObservableObject`, `ObservableObjectPublisher`, `@Published`,
`Publisher.sink`, `AnyCancellable`).

## Build and test

    swift build && swift test          # macOS or Linux, from this directory

Regenerate the golden tests after the spec table changes:

    python3 -I Scripts/gen_golden_tests.py

## What is implemented

**R2 views and data flow** (`03-architecture.md`):

- `View` (`@MainActor`), `Never: View`, `ViewBuilder` (`buildBlock` for 0, 1
  and any number of views through parameter packs, `buildIf` → `Optional`,
  `buildEither` → `_ConditionalContent`, `switch`, `buildLimitedAvailability`
  → `AnyView`), `TupleView`, `EmptyView`, `AnyView`, `Group`, `ForEach`
  (key-path IDs, `Identifiable`, constant ranges), `.id(_:)`.
- `ViewModifier`, `ModifiedContent` (as a view and as a modifier, `concat`),
  `EmptyModifier`, `_ViewModifier_Content`; custom modifiers have their own
  state and dependencies.
- Primitive views lowered onto the engine: `Text` (round R4, below),
  `Image` (symbols, `resizable`), `Color`, `Rectangle`, `Circle`, `Ellipse`,
  `Capsule`, `RoundedRectangle`, `Spacer`, `Divider`, `HStack`/`VStack`/
  `ZStack`, any `Layout` through `callAsFunction`, `GeometryReader` +
  `GeometryProxy`, `Grid`/`GridRow`/`gridCellColumns`, `LazyVGrid`,
  `ViewThatFits`; the layout modifiers (frames, padding, `fixedSize`,
  `aspectRatio`, `offset`, `position`, scale/rotation, `clipped`,
  `layoutPriority`, `layoutValue`, `alignmentGuide`, `ignoresSafeArea`,
  `background`/`overlay` with views); render-only `opacity`/`hidden`.
- Data flow: `DynamicProperty`, `@State`, `@Binding` (member bindings,
  optional/`AnyHashable` conversions, `transaction`/`animation`),
  `@Bindable`, `@Environment(\.key)`, `@Environment(Type.self)` (plain and
  optional), `EnvironmentValues` with the 08 §1 defaults and the
  environment-writing modifiers (`environment`, `transformEnvironment`,
  `font`, `lineLimit`, `disabled`, …), `@StateObject`, `@ObservedObject`,
  `@EnvironmentObject` + `environmentObject(_:)`, `@Namespace`;
  `@Observable` models through the toolchain's `Observation`.
- Lifecycle: `onAppear`, `onDisappear`, `onChange(of:initial:)` (both
  closure forms and the deprecated one), `task`, `task(id:)`,
  `onGeometryChange(for:of:action:)`.
- Preferences: `PreferenceKey`, `preference`, `transformPreference`,
  `onPreferenceChange`, `overlayPreferenceValue`/`backgroundPreferenceValue`.
- Transactions: `Transaction` (animation, `disablesAnimations`,
  `isContinuous`, `tracksVelocity`, `TransactionKey`s, completions),
  `withTransaction`, `withAnimation` (+ completion), `.transaction(_:)`,
  `.transaction(value:_:)`, `.animation(_:value:)`; `Animation` values with
  the parameters of 05 §4 (interpolated since R6, below).

### Graph design (R2)

`Sources/SwiftUICore/Graph/`. The plan's `OVGraph` attribute graph
(`09-open-design.md` §3.1) is realised as a retained tree of `ViewNode`s, one
per identity, with dependency sets per node; a separate module was not
needed for R2 (layout is recomputed per pass, so view-level invalidation is
the only incremental part). Rules:

- **Identity.** A node's children are keyed: tuple position, conditional
  branch, optional presence, `ForEach` element ID (duplicates by
  occurrence), `.id` value, `AnyView`'s wrapped type. Same key and type →
  same node (state kept); otherwise the old node is torn down and a new one
  inserted.
- **Re-evaluation.** A custom view (or custom modifier) re-runs its body when
  a new value from its parent differs field by field
  (`Graph/Comparison.swift`: graph-owned wrappers such as `@State` compare
  equal, bindings by storage identity, class references by identity,
  closures never, `Equatable` values by `==`, other values structurally),
  when it was invalidated (a state location it read, an observed
  `@Observable` property via `withObservationTracking`, an
  `ObservableObject` it holds), or when a key it read changed value in its
  new environment. A node that does not re-run still passes the environment
  and the walk towards invalidated descendants down. Writes equal to the
  current value invalidate nothing.
- **Containers' closures.** `ForEach` content, `GeometryReader` content and
  preference readers evaluate their closures under the same tracking, with
  the container as the dependent: a state read inside a `ForEach` row
  closure re-evaluates the `ForEach`, not its parent's body.
- **Environment.** `EnvironmentValues` gets a fresh global revision on each
  mutation; equal revisions need no checks, and readers compare only the keys
  they read. Environment modifiers reuse their output while their input
  revision and their own value are unchanged.
- **Update pass** (`ViewGraph`, also the headless host): writes coalesce
  into one pass with the transaction of the last write; bodies top-down
  (`onChange` inline); appearances in reverse pre-order, then
  disappearances; layout (window with safe area, or a proposal); geometry
  actions; preferences and `onPreferenceChange`; completions. Actions that
  write state schedule another pass; `update()` runs passes until nothing is
  pending.
- **Lowering.** Each node produces layout nodes for the R3 engine (a modifier
  wraps each node its content produces); `ViewGraph.layoutNode(for:)` is the
  bridge the view-built golden tests use.
- **Threads.** The graph is `@MainActor`. State written elsewhere is applied
  on the main actor in a later pass. The main actor is recognised by a tag on
  the main dispatch queue as well as by the main thread (on Linux, main-actor
  jobs need not run on the main thread).

### Animation design (R6)

`05-animation.md`; sources in `Sources/SwiftUICore/Animation/` and the graph
hooks in `Graph/`.

- **Animations.** `Animation` wraps a `CustomAnimation` (`animate(value:time:context:)`
  returns the part of the change reached, nil when finished;
  `velocity`, `shouldMerge`; `AnimationContext` with `AnimationState`,
  `isLogicallyComplete`, environment). Built in: timing curves (the
  `UnitCurve`s of §2; 0.35 s by default), springs (§3; logically complete at
  the perceptual duration), `delay`, `speed`, `repeatCount`/`repeatForever`,
  `logicallyComplete(after:)`; `Animation(_:)` takes custom animations.
- **Clock and frames.** `ViewGraph` reads time from an `AnimationTimeSource`;
  the headless host uses `ManualAnimationClock` (60 Hz). An update starts
  animations at the current time; `renderFrame()` / `advance(frames:)` render
  one display frame: pending updates, then every active driver is sampled,
  animatable bodies whose presented data changed run again (a frame pass
  with an empty transaction), removal transitions that ended are torn down,
  and layout runs again if bodies changed.
- **Animators.** Each animatable value has an `Animator` (model value,
  presented value, at most one run). A change in an animated transaction
  starts a run from the *presented* value (retargeting, §4.2); a spring
  following a spring inherits the velocity (`shouldMerge`). A change
  without animation shifts the presented value with the model value, so a
  running animation keeps its remaining distance.
- **What animates.** `Animatable` custom views and modifiers (body evaluated
  with the presented data once per frame, §1); the render effects
  `opacity`, `offset`, `scaleEffect`, `rotationEffect` (presented values,
  layout keeps the model values so geometry readers see the model); and
  layout geometry: after every layout pass, each layout node's frame in its
  parent's coordinates is recorded with the view that created it and
  animates per the transaction that reached that view (for views a pass did
  not visit, the transaction is derived through the transaction modifiers
  above them).
- **Presentation.** `ViewGraph.presentedLayers()` / `presented(_:)` walk the
  last layout tree with the animated local frames and the presented effect
  values, and report frame and opacity of named nodes (and of views being
  removed). This stands in for the display list until R5.
- **Completion.** `addAnimationCompletion` / `withAnimation(_:completionCriteria:_:completion:)`
  create records that wait for every run their transaction started:
  `.logicallyComplete` when each is logically complete, `.removed` when each
  finished or was replaced; a transaction that starts nothing completes at
  the end of its update.
- **Transitions.** `Transition` (phases `willAppear`/`identity`/`didDisappear`),
  `AnyTransition`, the built-ins (identity, opacity, scale, offset, move,
  slide, push, asymmetric, combined, `.modifier(active:identity:)`,
  `.animation(_:)` on a transition). A view inserted into an existing parent
  in an animated transaction is the root of an insertion; a `.transition`
  on the chain of modifiers and wrappers below it is evaluated at
  `willAppear` and then at `identity` in that transaction; without one the
  view fades (the default). On removal the transition moves to
  `didDisappear`, the view leaves layout but stays rendered where it was
  until its animations end; `onDisappear` and task cancellation run then (§5).
- **Keyframes.** `KeyframeTimeline`, `KeyframeTrack` (key paths), the four
  keyframe types, both builders (keyframes written directly form one track);
  segment rules in `Keyframes.swift`.
- **Animator views.** `PhaseAnimator` (and `.phaseAnimator`): each phase is a
  state change in a transaction with the phase's animation; the next phase
  starts when its animations are logically complete; a trigger runs the
  phases once (back to the first), no trigger cycles from appearance.
  `KeyframeAnimator` (and `.keyframeAnimator`): content evaluated every frame
  with the timeline's value.
- **`matchedGeometryEffect` (first cut).** A matched view inserted in an
  animated transaction starts in the frame of the matched view that is shown
  or removed in the same update (which in turn moves towards the new one); a
  non-source view is rendered in its source's frame. Render-time only.

**R1 value types:** `Axis`, `Edge`, `VerticalEdge`, `HorizontalEdge` (and
their sets), `EdgeInsets` (incl. pixel rounding), `UnitPoint`, `Angle`,
`ProposedViewSize`, `AlignmentID`, `AlignmentKey`, `HorizontalAlignment`,
`VerticalAlignment`, `Alignment`, `ViewDimensions`, `LayoutDirection`,
`ContentMode`; `VectorArithmetic`, `Animatable`, `AnimatablePair`,
`EmptyAnimatableData`; `Color` with `Color.Resolved` (sRGB, linear sRGB and
Display P3 components, opacity, HSB) and the named-colour tables of 07 §4 for
light/dark and increased contrast; `ColorScheme`, `ColorSchemeContrast`,
`DynamicTypeSize`; a minimal keyed `EnvironmentValues` (colour scheme,
contrast, layout direction, display scale, pixel length, Dynamic Type size);
`UnitCurve` (Bézier and circular curves, velocity, inverse) and `Spring`
(parameter conversions, closed-form value/velocity/force/update).

**R3 layout:** the `Layout` protocol with `LayoutSubview(s)`,
`LayoutProperties`, `LayoutValueKey`, `ViewSpacing`; `HStackLayout`,
`VStackLayout`, `ZStackLayout`, `AnyLayout`, `GridLayout` + `GridItem`; and
engine behaviours for colours and shapes, `Circle`, `Spacer`, `Divider`,
`GeometryReader`, `EmptyView`, text and symbol images (through stubs),
fixed and flexible frames, padding, `fixedSize`, `aspectRatio` /
`scaledToFit`/`Fill`, `offset`, `scaleEffect`, `rotationEffect`, `position`,
`overlay`/`background`, `clipped`, `layoutPriority`, `layoutValue`,
`alignmentGuide`, `ignoresSafeArea`, `Grid`/`GridRow`/`gridCellColumns`,
`LazyVGrid`, `ViewThatFits`; safe areas (window layout with insets, expansion
of views that touch them, insets reported to geometry readers);
right-to-left mirroring; pixel-thin dividers from the display scale.

### Engine design (R3)

`Sources/SwiftUICore/Engine/`: a `LayoutNode` has a `NodeBehavior` and
children. Behaviours answer `sizeThatFits` for a proposal, return child
placements, and supply explicit alignment guides, spacing preferences,
priority and layout values (modifiers pass the last four through from their
child). Every `Layout` — built-in or user-written — is driven by one adapter
(`LayoutBehavior`), which records `place(at:anchor:proposal:)` calls.
Answers and dimensions are memoised per proposal (04 §8). `LayoutEngine`
runs a pass (`sizeThatFits`, `layout(_:proposal:)`, `layout(_:window:safeAreaInsets:)`)
and returns frames of named nodes in left-to-right absolute coordinates.
`NodeBuilders.swift` names the constructors after the views and modifiers
they stand for; the views lower to these. All of this is `package` API:
nothing outside the spec's inventory is public.

### Text design (R4)

**OVText** (`Sources/OVText/`, no view types; public API so a renderer and
other packages can use it):

- `OpenTypeFace` reads TrueType/OpenType files and collections from the
  OpenType specification: `head`, `hhea`, `hmtx`, `maxp`, `OS/2` (weight and
  width class, typo metrics when `USE_TYPO_METRICS`, cap and x height),
  `post`, `name`, `cmap` formats 4 and 12, `kern` format 0 and GPOS pair
  adjustment (formats 1 and 2, extension lookups) of the `kern` feature.
  Bounds-checked reads; outlines are not read (R5).
- `FontFace` is the abstraction layout uses: size-dependent line metrics,
  glyphs, advances, kerning, optional tracking per size, and optional
  *measured run widths*. `TableFace` implements it from tables (ratios,
  leading per size, measured runs; advances are estimates) — the test font.
- `FontCatalog` discovers faces (registered faces, the bundled Noto Sans,
  directories scanned lazily reading only the name/OS2/post tables; on Linux
  the XDG and fontconfig directories) and matches requests per CSS Fonts 4
  (family per design — default/rounded → Noto Sans, serif → Noto Serif,
  DejaVu Serif, …, monospaced → Noto Sans Mono, DejaVu Sans Mono, … when
  installed — then width, style, weight). Missing glyphs fall back to any
  catalog face that has them.
- `Shaper`: one glyph per grapheme cluster (first scalar; marks add no
  advance), pair kerning within a run, tracking and kerning attributes. No
  ligatures, contextual forms or mark positioning: complex scripts (Arabic
  joining, Indic) lay out with isolated forms — a HarfBuzz-based shaper can
  replace it behind the same output.
- `LineBreaker`: UAX #14 rules LB4–LB31 (not LB28a; LB25 in pair form) on
  grapheme clusters, classes from explicit tables plus general category and
  block ranges; no dictionary breaking for Thai/Lao/Khmer/Myanmar.
- `BidiParagraph`: UAX #9 P2–P3, W1–W7, N1–N2, I1–I2, L1–L2 (no explicit
  embeddings/isolates, no bracket pairs); lines carry their visual order.
- `Typesetter`: greedy breaking at opportunities, hanging whitespace,
  breaking inside a word when nothing else fits (at least one cluster per
  line), explicit newlines, line caps from a line limit and from the
  proposed height, tail/head/middle truncation with "…", line spacing,
  minimum scale factor (largest factor that avoids truncation) and
  tightening. It reports whether any decision used estimated advances.

**SwiftUICore** (`Sources/SwiftUICore/Text/`):

- `Font`: the 11 text styles with the Dynamic Type point sizes of 07 §1.1
  (`DynamicTypeTable`, all 13 UIKit styles), `system(size:)`, `custom`
  (fixed or scaled relative to a style), weights (with OpenType weight
  classes), widths, designs, italic, monospaced, monospaced digits, small
  caps, `leading`, `pointSize`, `scaled(by:)`; `Font.Context`/`Resolved`,
  `EnvironmentValues.fontResolutionContext`. headline is semibold; Bold Text
  (`legibilityWeight == .bold`) adds two weight steps.
- `Text`: styled segments. `+` concatenates; `font`, `fontWeight`,
  `fontWidth`, `fontDesign`, `bold`, `italic`, `monospaced`,
  `monospacedDigit`, `kerning`, `tracking`, `baselineOffset`, `underline`,
  `strikethrough`, `foregroundColor/Style` style every segment that does not
  set the attribute itself; the same modifiers on any view go into the
  environment below. `textCase`, `lineLimit(_:)`, `lineLimit(_:reservesSpace:)`,
  `lineLimit` with ranges, `lineSpacing`, `multilineTextAlignment`,
  `truncationMode`, `minimumScaleFactor`, `allowsTightening`.
- `LocalizedStringKey` keeps the table key (`%@`, `%lld`, `%lf`) and the
  arguments; lookup at lowering in `<language>.lproj/<table>.strings` of the
  bundle for the environment's locale, numbers formatted for the locale
  (Arabic-Indic digits for `ar`).
- `TypesetTextMeasurer` is what the engine's text leaf calls (it replaces the
  R3 stub): a `TextFontProvider` maps resolved fonts to faces
  (`CatalogFontProvider` by default), OVText lays out, and SwiftUI's rules
  and the pixel grid are applied (rules below). Answers are cached per text
  and proposal. `placedLines(_:size:)` positions lines by
  `multilineTextAlignment` and layout direction for the renderer.
- Text spacing preferences come from the face's metrics: below = 0.86726 ×
  size − descent, above = 1.33056 × size − ascent toward standard views
  (the reference body values 10.643 / 6.433 as baseline distances), 2
  between texts.

**Test font.** Golden values come from Apple's system font, which we must
not use. `Tests/.../Support/ReferenceFont.swift` builds `TableFace`s from
what the spec records: ascent/descent ratios 0.952148 / 0.241211 (they
reproduce every row of 07 §1.2 to 0.01), leading per size (07 §1.2), the
measured single-line widths of every string the golden cases use, the
widths of "Ag" per point size and weight from `font.*` and `dyn.*`
(`GoldenTextRuns.swift`, generated; the 55 entries agree across all rows
that share a size), and the body/caption spacing values of the matrix. Any
answer that depends on unmeasured glyph widths (where a text wraps or is
truncated) is reported approximate and that check is skipped; the probe's
`longText` is a stand-in with the counts the spec implies (43 characters, 8
spaces, width 339). Those cases are checked as relations with Noto Sans in
`TextRelationTests` (T-LAYOUT-T).

## Golden layout tests

`Scripts/gen_golden_tests.py` reads `golden-layout.md` and writes one Swift
Testing test per case, named by its case id
(`Tests/OpenViewsTests/GoldenLayoutTests.swift`), plus one per entry of the
default-spacing matrix (`GoldenSpacingTests.swift`). Probe sources are
translated mechanically into a test DSL that mirrors them
(`Tests/OpenViewsTests/Support/DSL.swift`); the probe itself is modelled as a
background geometry reader, as the spec's frames require (see
`alignmentGuide.explicitLeading`). Text metrics and symbol sizes used as
inputs come from the spec (`Support/Fixtures.swift`, `Support/ReferenceFont.swift`,
generated `Support/GoldenTextRuns.swift`). Tolerance 0.01 pt.

Since R2 the generator also writes `GoldenViewLayoutTests.swift`: every
runnable case once more, built from the probe source itself as SwiftUI views
(only `Text(longText)` is substituted; the grid rows get the `;` the table
leaves out) and lowered by the view graph. The probe is a test-only view
modifier (`Tests/OpenViewsTests/R2/Support.swift`).

Results (macOS and Linux identical):

| | Cases | Result |
|---|---|---|
| Layout cases run | 104 of 138 | all pass: 93 fully, 11 with some checks skipped |
| Checks in those cases | 899 | 857 pass, 42 skipped, 0 fail |
| — of which R4's 32 text cases (`text.*`, `font.*`, `dyn.*`) | 250 | 234 pass, 16 skipped (where `longText` wraps or is truncated) |
| — of which the 72 earlier cases | 649 | 623 pass (614 before R4), 26 skipped (wrapping of unmeasured text: `longText`, grid cells, `hstack.flex`) |
| Cases disabled | 34 | symbol metrics (R5), controls (R8), scroll views, lists, forms, navigation, tabs (R9) |
| Spacing matrix | 64 | 25 pass (every pair of text, caption text, image, colour and padded view); 39 disabled (button, toggle, text field: R8) |
| Same 104 cases built from views | 104 | identical: 857 checks pass, 42 skipped, 0 fail |

R4 tests (`Tests/OpenViewsTests/R4/`, 62 tests, all pass on macOS and Linux):

| Suite | Spec | Checks |
|---|---|---|
| OpenType reader and matching | 09 §5.2 | Noto Sans names, metrics, traits, cmap, advances, GPOS kerning (AV, To), CSS weight matching, refused Apple families, damaged files |
| UAX #14 | Unicode | spaces, hard breaks, CR LF, punctuation and numbers, hyphens, glue/ZW/WJ, ideographs, small kana, closing marks, emoji and flag clusters, combining marks |
| UAX #9 | Unicode | LTR, RTL, mixed, Arabic with digits, paragraph direction |
| Typesetter | 04 §3 | wrapping, hanging spaces, newlines, breaking inside words, pitch and line spacing, line and height caps, tail/head/middle truncation, minimum scale factor, measured runs vs estimates, tracking/kerning, bidi lines, glyph fallback |
| T-TEXT | 07 §1 | point sizes 13 styles × 12 categories; `Font` resolution in every category; weights; fixed and custom sizes; Bold Text; `Font.Resolved`; heights 11 × 12 of 07 §1.3; 07 §1.2 metrics; truncation ends in an ellipsis |
| Text styling | 03 §6, 04 §3 | concatenation precedence, attributes, view-level modifiers, Dynamic Type and legibility at lowering, paragraph settings, line-limit ranges, `textCase`, reserved lines, line spacing, alignment, minimum scale factor |
| T-L10N | 08 §3 | en/fr/ar tables, verbatim text, `%lld` key with locale digits (٣), positional formats, `.strings` syntax |
| T-LAYOUT-T (Noto Sans) | 10 §3.2 | `text.long` wrap relations, zero proposals, `fixedSize.vertical` (35 lines), line limits, height caps, spacing 8 / 2, centring, `hstack.priority`, `hstack.equalTexts`, baselines and baseline alignment, `viewThatFits`, empty text, Dynamic Type |

R2 tests (`Tests/OpenViewsTests/R2/`, 70 tests, all pass on macOS and Linux):

| Suite | Spec | Checks |
|---|---|---|
| Re-evaluation counts (T-DF, K-1) | 03 §4.1, §4.2 | every row of the table: initial render (parent ×2 with the scene becoming active, closure child ×2, others ×1), parent state, `@Observable` a / b / array append / in-place mutation / same value, `@Published` a / b, environment value, ignored field under `.equatable()`, parent state set to its value; coalescing; top-down order |
| Identity and lifetime (K-3) | 03 §2 | state kept across parent updates while the initial-value expression still runs; `if`/`else` branch switch; `.opacity` toggle; `.id` change; `ForEach` reorder / removal / insertion; `AnyView` type change |
| Appearance order (K-2) | 03 §2 | `second, first, parentVStack`; six root siblings last-to-first; nested reverse pre-order; disappearance order |
| Lifecycle | 03 §3, §5 | `onChange` old/new and position in the pass, `initial: true`; `task` start, `task(id:)` cancel-and-restart in one update, cancellation on removal; off-main writes |
| Preferences (K-2) | 03 §7 | `first,second`; one `onPreferenceChange` in the initial update and on change only; nesting, `transformPreference`; `overlayPreferenceValue` |
| Environment | 03 §3, §6, §7; 08 §1 | the defaults table; per-key re-evaluation; inner overrides; `.font` on stack vs child; `@Environment(Type.self)` per property; `@EnvironmentObject`; `disabled` |
| Modifier order | 03 §6 | `.padding().frame(width: 100)` vs 132 wide; background 71 × 52.33 vs 39 × 20.33; render-only modifiers; modifiers on groups; empty children |
| Transactions | 05 §4.1 | the four scoping cases; `Binding.animation`; completion; animation parameters of 05 §4 |
| Views and bindings | 03 §1, §3 | builder result types and lowering; `@Binding` readers; write-through; member bindings; `@Bindable`; custom modifiers (content without body re-run, `concat`); `@StateObject` created once; `@Namespace`; `GeometryReader` rebuilt after layout; `onGeometryChange` |

R6 tests (`Tests/OpenViewsTests/R6/`, 75 tests / 124 cases, all pass on
macOS and Linux; manual 60 Hz clock, the change at t = 0):

| Suite | Spec | Checks |
|---|---|---|
| T-KEYFRAME | 05 §6 | the measured timeline: duration 3.0 and all 31 values (±0.01); spring velocity hand-over, cubic Hermite, Catmull-Rom joints, explicit velocities, timing curves, moves, key-path tracks, builder |
| Model and frames | 05 §1, §4; I-3 | 61 body evaluations for a 1 s linear, 31 with `speed(2)`, ≈ 77 (±3) for `.default`, 1 without animation; model value new at once; first change one frame after the state change |
| Samples | 05 §4; I-4 | `v@` samples of linear and easeInOut (±1 frame, ±0.01); rendered durations (first frame at the target to 4 decimals) of curves, delay, speed, repeat and six springs (±3 frames); delay produces no frames; repeat-count jump; spring tracking (1e-4); overshoot of bouncy/snappy; `interpolatingSpring`; `repeatForever` |
| Completion | 05 §4; I-6 | logical completion of 12 animations, `.removed` of `.spring()` at 1.28 s and of curves at their end (±3 frames); nil animation; `logicallyComplete(after:)` |
| Transaction scoping | 05 §4.1; I-5 | the four measured cases with real interpolation (implicit only, explicit ease-in vs own modifier, transaction override 0.3 s, `disablesAnimations`), plus the inferred `disablesAnimations` rule |
| Retargeting | 05 §4.2 | linear interrupted by `.spring()` at 0.5 s: no jump, 49.2 one frame later, 0.11 × at 0.75 s, 0.0097 × at 1.0 s; spring → spring keeps velocity; curve → curve; unanimated change shifts |
| Transitions | 05 §5; I-7 | onAppear at the start, opacity 0 → 1 in 61 frames; removal deferred, view rendered until 1.0 s, onDisappear then; leaves layout at once; immediate without animation; scale, offset, move, slide, push, asymmetric, combined, modifier, transition animation, identity; `.removed` completion; re-insertion during removal |
| Animated views | 05 §1 | layout geometry and sibling positions; implicit scope; opacity/offset/scale/rotation; `Animatable` views; PhaseAnimator (trigger, continuous); KeyframeAnimator (trigger, repeating); custom animations; `matchedGeometryEffect` |

Whole package: 563 tests — 490 pass (one of them with the 3 known issues
of the open `settlingDuration` rule), 73 disabled (later rounds), 0 fail;
identical on macOS (arm64) and Linux (x86-64).

Other tests: R1 value types (T-COLOR named colours light/dark and increased
contrast, T-CURVE all 8 curves at 11 points, T-SPRING parameters of 8 springs
and the value series of 4), and layout rules from the spec prose
(right-to-left mirroring, safe areas, pixel rounding, custom `Layout`
implementations, `LayoutValueKey`, `AnyLayout`, stack details).

## Rules inferred (not stated in the spec)

- **Stack tie-break.** When two children are equally flexible (both
  infinitely), the one with the larger minimum goes first
  (`hstack.threeColors.spacing0`: 75 / 150 / 75).
- **Flexible frame, one bound.** With only a minimum: max(min, min(child,
  proposal)); with only a maximum: min(max, max(child, proposal)) — not just
  "the child clamped" (`frame.maxInf` answers 300 for a 39-wide text).
- **Merging explicit guides.** Containers merge their children's explicit
  values: first baseline = smallest, last baseline = largest, other guides =
  mean (the mean is our choice; no case distinguishes it).
- **Probe frames.** The probe is a background, so it is aligned to the
  probed view's (possibly explicit) centre guides.
- **Vertical spacing model.** Text and image edges are baseline-relative;
  values per font come from the spacing matrix (10.643 / 6.433 body,
  chosen within the ranges the matrix and the grid cases allow).
- **Lazy grid edge cases.** An adaptive item in a zero width yields no
  columns (0 × 0); an infinite width yields an empty grid; an unspecified
  width gives each column its cells' ideal width.
- **Spring, over-damped.** stiffness = (2π/response)²·(2ζ² − 1) reproduces
  the reported parameters for bounce −0.3.
- **UnitCurve end velocities.** Where both derivatives vanish (a control
  point on an end point), the velocity is 1 at the start and 0 at the end.

### R2

- **Appearance order beyond the measured cases.** The measured `onAppear`
  orders (children before parent, later siblings first) are exactly the
  reverse of a pre-order walk; we use that rule for any tree, and the same
  order for `onDisappear` (not measured).
- **`onChange` timing.** The action runs when the modifier receives its new
  value — after the parent's body, before the content is updated — matching
  the log order "state change → `onChange` → body logs".
- **Preference reduction.** Only subtrees that produce a value take part; the
  first value starts the reduction (the key's default is used only where a
  reader needs a value and none was produced). `preference(key:value:)`
  replaces values from inside the view.
- **Container closures.** State read in a `ForEach` row closure (or a
  geometry reader's content) is a dependency of that container, not of the
  view whose body created it.
- **Coalesced transaction.** Writes in one turn share one update and the
  transaction of the last non-empty write.
- **`EquatableView`.** Field-by-field when the content is a plain-value
  (bitwise-copyable) type — the measured case — and `==` otherwise.
- **`disablesAnimations`.** Disables `.animation(_:value:)` modifiers; the
  transaction's own animation reaches the subtree.
- **Several root views** are stacked like a `VStack` by the host.
- **`onGeometryChange`** reports the first value too.
- **`@Environment` defaults** (08 §1) are the reference device's; `timeZone`
  is the host's.

### R6

- **Retargeting restarts from the presented value.** A new animation on a
  value that is animating starts at its presented value (§4.2 measured
  linear → spring: the additive composition of the two would go negative at
  0.75 s); only spring → spring carries velocity. A change without animation
  shifts the running animation.
- **Spring end.** A spring animation finishes at the first frame where both
  the distance to the target and speed/ω₀ are within 2 × 10⁻⁶ of the
  change (fitted to `.spring()` removed ≈ 1.28 s / ≈ 77 frames).
- **"Rendered duration"** in 05 §4 is the first frame whose value prints as
  the target to 4 decimals (|v − 1| < 5 × 10⁻⁵) — for oscillating springs
  this can be a zero crossing (bouncy 0.95 s vs measured 0.94).
- **Repeat.** The end of the last traversal is shown for one frame before the
  jump to the model value (measured: back to 0 at 1.0 s, jump at 1.04 s).
- **Start time.** Animations start at the update that applies the state
  change; the first changed frame is the next display frame (§4 latency).
- **Default `.spring()`** is the duration/bounce form (damping 1, as
  measured); the response/damping-fraction overload is disfavoured.
- **Layout geometry** animates in the parent's coordinates (a child moves
  with its animating parent) per the transaction that reached the view that
  created the layout node.
- **Transition root.** Transitions apply at the root of an insertion and the
  chain of modifiers/wrappers below it, not inside inserted containers.
  `.move(edge:)`, `.slide` and `.push` move by the view's own size; `.scale`
  scales from 0; a transition's own animation is used even when the
  transaction has none.
- **Keyframes.** Cubic slopes as described in `Keyframes.swift`; a
  `SpringKeyframe` without a duration lasts the spring's settling duration.
- **Animator views.** Phases advance on logical completion; a triggered
  `KeyframeAnimator` stays at the timeline's final value.
- **Interrupted completion.** The completion records of a run replaced by a
  retarget count it as removed (both criteria) at the interruption.

### R4

- **Line height and baselines.** One line = ascent + descent rounded *up* to
  the pixel grid; baselines = ascent (+ k × pitch) rounded to the *nearest*
  pixel (07 §1.2: 16.19 → 16.33, 32.37 → 32.33, 26.66 → 26.67); pitch =
  ascent + descent + leading (body 22). These reproduce all 132 heights of
  07 §1.3 and every baseline of the golden rows.
- **Proposed height limits lines.** A concrete proposed height caps the
  number of lines (as many as fit, at least one) and truncates the last one
  (`hstack.equalTexts` fit[100×100] = 86.33 = 4 lines, `hstack.priority`
  fit[300×500] = 22 lines of the 24 the spec counts, `frame.tooSmall`
  one line in 20 pt). 04 §3's "proposed height is ignored" holds only while
  the lines fit.
- **Width when a word is broken.** A text that had to break inside a word
  answers the proposed width (`hstack.priority`: 17 when offered 17; 0 at
  width 0; `padding.negative` fit[0×0]); otherwise the widest line, never
  more than the proposal.
- **Zero width.** Width 0 with a non-zero or unspecified height: one
  non-space character per line, width 0 (`fixedSize.vertical` fit[0×0] =
  35 lines); a 0 × 0 proposal: 0 × 0 with the first line's baselines.
- **Stack extent contains the alignment line.** Needed for
  `hstack.baseline` fit[0×0] = 8 × 32.33 (two 0 × 0 texts aligned on first
  baselines 32.33 and 11.33); no other case changes (`Stacks.swift`).
- **Empty text** keeps 14/17 and 11/17 of the size for its height and
  baseline (measured at body only).
- **Truncation** cuts at grapheme clusters, strips trailing spaces before
  the ellipsis; a line cut by a limit holds the rest of its paragraph.
- **Hanging whitespace** at soft line ends is not part of a line's width.
- **Font widths** (`Font.Width` values) and `Font.Leading` (±0.07 × size)
  are ours; Bold Text = two weight steps.

## Open spec questions

1. `Spring.settlingDuration`: the rule behind 0.8 / 0.8768 / 1.0447 /
   0.9817 / 1.7399 / 1.4 is not in the spec (ours is the last time 0.1 %
   away from the target; marked as a known issue in the tests). R6 checked
   threshold rules on the closed-form motion — |x|, |v|, |v|/ω₀, |v|/ω₀²,
   |acceleration|, |x| + |v|, hypot and max combinations, energy — as well as
   envelope bounds (displacement and velocity amplitude, L1/L2) and
   discrete integrators (explicit and semi-implicit Euler at 60–1000 Hz):
   no single epsilon reproduces all six values (best metric spreads × 5). The
   ζ ≥ 1 values are round multiples of the response (1.6 and 2.8 ×); the
   under-damped ones lie within 2 % of ln(10⁴)/(ζω₀) except k100/c10
   (−5.5 %). A probe of `settlingDuration(target:initialVelocity:epsilon:)`
   over epsilons and of springs with other responses would settle it.
2. Text proposed width 0 with a non-zero height, and baselines of a 0 × 0
   text (`hstack.baseline` fit[0×0] = 8 × 32.33): R4 answers with the
   rules above (one character per line; first-line baselines; stack extent
   includes the alignment line) — a probe of `HStack(alignment:
   .firstTextBaseline)` with 0 × 0 children would confirm the last one.
3. `combineExplicit` for non-baseline guides, and a `VStack`'s first
   baseline when its first child has none.
4. Where a stack puts its children when its bounds are larger than its
   answer across the axis (we use the guide's unit position).
5. Increased-contrast values for colours other than blue/accent; UIKit
   semantic colours (`label`, `systemBackground`, …) are not SwiftUI API and
   are not included.
6. Whether `ignoresSafeArea` re-proposes a fixed frame inside it.
7. Unplaced `Layout` subviews: we centre them in the bounds.
8. (R2) `onAppear` order: 03 §2 measures children before parents, but 06 §1
   and checklist A-1 list `root.onAppear` before `lc.text.onAppear`. We follow
   03 §2 (the explicit rule); the lifecycle probe's structure (lazy or
   UIKit-hosted content created later?) would settle it.
9. (R2) `.equatable()` with non-plain fields (03 §8): when is `==`
   consulted? (Our reading above.)
10. (R2) The order of `onDisappear` actions within one removed subtree, and
    relative to `task` cancellation, was not measured.
11. (R2) Whether a state read inside a `ForEach` closure re-runs the
    enclosing body or only the `ForEach` (not observable in the measured
    counts).
12. (R2) Several writes in one turn with different transactions (e.g. one
    animated, one not): which transaction reaches which view.
13. (R2) Whether `onPreferenceChange` and `onGeometryChange` actions run in
    the same pass or a following one relative to `onAppear` writes.

14. (R6) The spring removal rule (one measured point), and whether removal
    differs for bouncy springs.
15. (R6) Retargeting between two curve animations and between a spring and
    a following curve (measured only linear → spring); whether a
    non-merging animation is additive.
16. (R6) Slopes of consecutive cubic keyframes (`10-plan.md` §4 q4) and the
    default duration of a `SpringKeyframe`.
17. (R6) `.move(edge:)` distance (own size vs container edge), `.scale`'s
    default scale, transitions nested inside an inserted container.
18. (R6) `disablesAnimations` with differing implicit and explicit
    animations (`10-plan.md` §4 q3); spring `blendDuration` (carried, not
    applied).
19. (R6) What a triggered `KeyframeAnimator` shows after its timeline, and
    whether a phase advances on logical or full completion.
20. (R6) `matchedGeometryEffect`: not measured at all (layout of non-source
    views, properties and anchors).
21. (R4) The probe's `longText` content: with it (and per-string widths of
    its wrapped lines) the 16 skipped `text.long*` checks and the
    `hstack.equalTexts`/`hstack.priority`/`fixedSize.vertical` wrap checks
    could be exact. 04 §3 says the squeezed text "became 24 lines"; the
    golden frame shows 22 (482.33) — the height cap explains both.
22. (R4) Vertical text spacing in closed form (`10-plan.md` §4 q7): body
    (10.643 / 6.433) and caption (7.53 / 4.56) do not share one linear rule
    in the font's metrics to 0.01 pt; other sizes use our formula.
23. (R4) Whether a final newline adds an empty last line (we add none), and
    whether trailing spaces at the end of a paragraph count in its width
    (we count them).
24. (R4) What truncation does with head/middle modes on multi-line text
    (we apply them to the last shown line), and the ellipsis glyph's font
    in mixed runs.
25. (R4) Line height for non-Latin UI languages (08 §3: Arabic 22.33 for
    body) — needs the language-specific line-height rule.
26. (R4) Effects of `Font.Width`, `Font.Leading`, `monospacedDigit`,
    `smallCaps` and `allowsTightening` were not measured.

## Deferred

R6: `GeometryEffect` and `ProjectionTransform` (need the transform types of
R5; `CGAffineTransform` is not in Linux Foundation), `TimelineView` and
timeline schedules, `ContentTransition`, `blurReplace`, symbol effects,
`scrollTransition`, `navigationTransition`/`matchedTransitionSource`,
`geometryGroup`, the `animation(_:body:)`/`transaction(_:body:)` forms,
`AnimatableValues`, `Animatable` static subscripts, spring blend durations,
a real display link (R7).

R2: `anchorPreference`/`Anchor` and named coordinate spaces;
`ForEach` over bindings and `DynamicViewContent`; the `@Entry` macro (needs a
macro plugin); `Shape`/`Path` (shapes are plain views until R5);
`ShapeStyle` overloads of `background`/`overlay`; `@AppStorage`,
`@SceneStorage`, `@FocusState`, `@GestureState` (R7–R10); `App`/`Scene` and
live platform environment (R7, R10). `DynamicProperty.update()` is called
on a copy (a custom property's own stored changes are not kept).

R4: complex-script shaping (GSUB/GPOS marks; a HarfBuzz back end), OpenType
features for `monospacedDigit`/`smallCaps`, synthetic bold/italic, variable
fonts, explicit bidi embeddings and isolates, dictionary line breaking, hyphenation,
`.stringsdict`/`.xcstrings` plural rules, `Text(_:format:)`/date styles,
`Text.Layout`/`TextRenderer`, the language-dependent line height of 08 §3,
symbol metrics per font (R5).

Earlier rounds: `LazyHGrid`, `LazyVStack`/`LazyHStack`,
`containerRelativeFrame`, `safeAreaInset`/`safeAreaPadding`, named
coordinate spaces, `layoutDirectionBehavior`, grid column alignment and
cell anchors, spanning cells widening columns.
