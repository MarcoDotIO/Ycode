# ycode-swiftui ("OpenViews")

A clean-room, Linux-buildable implementation of SwiftUI, written only from
`specs/frameworks/swiftui/` under the protocol in `AGENTS.md`. The spec's
design note (`09-open-design.md`) calls the open library **OpenViews**.

Status: rounds **R1** (value types and math), **R2** (graph runtime, views
and data flow), the core of **R3** (layout), **R4** (text), **R5**
(rendering v1), **R6** (animation), **R7** (app, scenes and input on
Linux), **R8** (controls, with the text editing core of `docs/PARITY.md`
§5.4 R14), **R9** (containers and presentation, with the split views and
outlines of PARITY §5.4 R12) and **R10** (environment, persistence,
accessibility) of `10-plan.md` §2, and **R11** (commands, menus, toolbars,
context menus, Settings; `docs/PARITY.md` §5.4), and **R13** (the gaps the
Linux IDE shell found, `docs/PARITY.md` §5.8, and what EditorKit needs,
§5.9: custom toolbar content, submenu shortcuts, outline selection,
tooltips, file dialogs, `Table`, `onKeyPress`, a bundled monospace font and
a glyph run cache that scrolls a 10 000-line text surface at 60 fps). Views are kept in a retained graph that
re-evaluates exactly the bodies the spec's measured rules say, and lower onto
the R3 layout engine; text is typeset by our own OVText module with open
fonts; animations run on an injectable clock; the laid-out graph lowers to a
display list that ThorVG rasterises on the CPU and a Vulkan compositor (or
the software compositor) puts on a surface. The platform layer `OVPlatform`
(R7) gives SDL3 windows on X11 and Wayland, a headless back end, the run
loop and display link; the app model (`App`, `WindowGroup`, `Window`, scene
phases), the gesture system, focus and hardware-keyboard text input sit on
it, and windows present through R5's compositors. R8 adds the controls
(buttons and styles, toggles, sliders, steppers, pickers, menus with pop-up
windows, text fields and editors, progress, gauges, labels, links, forms,
compact date pickers) and an editing model in OVText that EditorKit can build
on. R9 adds scroll views, lazy stacks and grids, lists with selection,
outlines and disclosure groups, navigation stacks and split views
(`NavigationSplitView`, `HSplitView`, `VSplitView`), tab views, sheets,
covers, alerts, dialogs and popovers. R10 feeds the environment from the
desktop's settings while the app runs, adds `@AppStorage` and
`@SceneStorage`, and builds an accessibility tree of every window, exported
to Linux screen readers over AT-SPI2 by a D-Bus client and exporter of our
own (OV-ATSPI; "AT-SPI export" below); R11 adds
an in-window menu bar built from `commands`, focused values, the Edit menu on
the text editing core, context menus, window toolbars and the `Settings`
scene. Tests drive headless hosts on a virtual clock and render headlessly to
PNG.

## Modules

| Module (Linux) | Module (Apple hosts) | Content |
|---|---|---|
| `SwiftUICore` | `OpenViewsCore` | Value types, `Layout` and the built-in stacks, the layout engine; `View`, `ViewBuilder`, `ViewModifier`, primitive views, the view graph, state and data flow, environment, preferences, transactions; animation (animations, keyframes, transitions, animator views); since R9 lazy containers (`LazyVStack`, `LazyHStack`, the item enumeration lists build on), `ScrollGeometry`, `ScrollTarget`, subtree suspension |
| `OVText` | `OVText` | Fonts and text layout without view types (R4): OpenType reader, font catalog and matching, shaping, UAX #14 line breaking, UAX #9 bidi, paragraph typesetter; bundles Noto Sans; since R8 the text editing core (`Editing/TextEditing.swift`) |
| `SwiftUI` | `OpenViews` | Re-exports the core; `GridLayout`, `GridItem`, `Grid`/`GridRow`, lazy grids, `Divider`, `ViewThatFits`, `EquatableView`, `ScenePhase`; since R7 the app model, the application host, `DragGesture`/`LongPressGesture`/`SpatialTapGesture`/`SequenceGesture`, `@GestureState`, hover, `@FocusState`, keyboard shortcuts; since R8 the controls (`Controls/`) and pop-up windows (`App/Popups.swift`); since R9 the containers and presentations (`Containers/`); since R10 the live environment (`App/PlatformEnvironment.swift`), `@AppStorage`/`@SceneStorage` (`App/Persistence.swift`) and accessibility (`Accessibility/`); since R11 commands and the menu bar (`App/Commands.swift`, `App/MenuBar.swift`), focused values and context menus (`Input/`), window toolbars (`Containers/Toolbar.swift`), `Settings` (`App/Settings.swift`); `OpenViewsAutomation` (`App/Automation.swift`, not SwiftUI API): public hooks so apps in other packages can be driven and photographed (texts and identified views with frames, screenshots with pop-ups, synthetic input, pointer moves, quit), used by Ycode's `ycode-ide`; since R13 tooltips (`Input/Help.swift`), key presses (`Input/KeyPress.swift`), file dialogs and `UTType` (`Containers/FileDialog.swift`), `Table` (`Containers/Table.swift`) |
| `OVRender` | `OVRender` | No view types (R5): the display list, its diffing (damage), the ThorVG rasteriser, PNG output, the compositor surface interface (`Compositor.swift`, the boundary with R7's `OVPlatform`), the software and Vulkan compositors, Ycode's symbol artwork |
| `CThorVG` | `CThorVG` | ThorVG 1.1.3 (MIT), vendored: CPU engine, PNG/JPEG loaders, C API |
| `COVVulkan` | `COVVulkan` | The Vulkan compositor's C side; loads `libvulkan` at run time; Khronos headers 1.3.275 (Apache-2.0) |
| `OVPlatform` | `OVPlatform` | (R7) Windows, input events, run loop and display link, clipboard, the Vulkan surface interface; SDL3 and headless back ends; (R10) desktop settings (`Settings.swift`: environment variables, a watched settings file, the settings portal, SDL's system theme) |
| `OVDBus` | `OVDBus` | (OV-ATSPI) A D-Bus client written from the D-Bus Specification: Unix socket transport, SASL EXTERNAL, the wire format of every type (both byte orders), messages, method calls, replies, errors and signals, exported objects with `Peer`, `Introspectable` and `Properties`; Foundation and POSIX only |
| `OVAccessibilityATSPI` | `OVAccessibilityATSPI` | (OV-ATSPI) The AT-SPI2 exporter on `OVDBus`: the accessibility bus, registration with the registry, one object per accessible node with the interfaces its role needs, the Cache, events; works on a view-independent model a provider fills (`ATSPINode`, `ATSPIProvider`) |
| `COVSDL` | `COVSDL` | (R7) C bridge: the vendored SDL3 public headers and a loader that opens libSDL3 at run time |
| `ov-sample` (executable `OVSampleApp`) | same | (R7) The sample app: a button, a draggable box and a text field |
| `ov-settings` (executable `OVSettingsSample`) | same | (R8) A settings form with every control; `OV_SAMPLE_SCRIPT=1` drives it, `OV_SCREENSHOT_PREFIX` writes light, dark, menu and spinner screenshots, `OV_PRINT_TARGETS=1` prints control frames for external drivers (header of `SettingsSample.swift`) |
| `ov-editor-bench` (executable `OVEditorBench`) | same | (R13) The scrolling benchmark of an EditorKit-style text surface: 10 000 lines drawn as `Canvas` text runs, headless, with the window's real presenter; prints milliseconds per frame (header of `EditorBench.swift`) |
| `ov-mini-ide` (executable `OVMiniIDE`) | same | (R9, R11) A mini IDE: a `NavigationSplitView` with a file outline, a text editor over a scrolling console in a `VSplitView`, a sheet and an alert; since R11 a menu bar (File, Edit, View, Project, Window, Help) with shortcuts, a window toolbar with Build and Run, a context menu on the outline rows and a Settings window (`@AppStorage`); the same switches (`OV_SAMPLE_SCRIPT`, `OV_SCREENSHOT_PREFIX`, `OV_PRINT_TARGETS`, `OV_QUIT_AFTER`; header of `MiniIDE.swift`) |

`SwiftUI` and `SwiftUICore` are interop identifiers: on Linux the modules
carry exactly those names so `import SwiftUI` compiles unchanged. On macOS
those names belong to the system frameworks, and a package module of the same
name would shadow them, so `Package.swift` builds the same sources as
`OpenViews` / `OpenViewsCore` and defines `OPENVIEWS_RENAMED`; sources and
tests pick their imports with `#if OPENVIEWS_RENAMED`. The switch follows the
host that evaluates the manifest (cross-compiling from macOS to Linux is not
covered). The split between the two modules follows the SDK's
(`api-inventory.md` lists where each type lives).

Dependencies: the Swift 6.4 toolchain (Foundation, Dispatch,
Synchronization, Observation, Swift Testing) and vendored, permissively
licensed sources built by SwiftPM (no system libraries are needed to build):

| Code | Version | Licence | Provenance | Use |
|---|---|---|---|---|
| ThorVG (`Sources/CThorVG/thorvg/`) | 1.1.3 (tag `v1.1.3`, commit `589bc412…`, released 2026-10-15) | MIT (`thorvg/LICENSE`, © 2020–2026 ThorVG Project; notices kept in every file) | `git clone --branch v1.1.3 https://github.com/thorvg/thorvg` on 2026-10-30; subset copied unmodified: `inc/thorvg.h`, `src/common`, `src/renderer` and `cpu_engine`, loaders `raw`, `png` (its bundled lodepng) and `jpg` (its bundled jpgd), `bindings/capi`; our `config/config.h` replaces meson's | the rasteriser (`SoftwareRasterizer`), PNG/JPEG decoding |
| Khronos Vulkan headers (`Sources/COVVulkan/vulkan/`) | 1.3.275 | Apache-2.0 (SPDX line in each file) | the copy already in `ycode/Sources/CVulkan/vulkan/` (Ubuntu `libvulkan-dev`) | types and constants for the compositor; Vulkan itself is loaded at run time |
| SDL3 (`libsdl-org/SDL`) public headers, 37 of them (`Sources/COVSDL/include/SDL3/`) | 3.4.18 (tag `release-3.4.18`, commit `829a65d7`) | zlib (`Sources/COVSDL/SDL3-LICENSE.txt`, read 2026-10-30) | `git clone --depth 1 --branch release-3.4.18 https://github.com/libsdl-org/SDL` on 2026-10-30; only the headers `ov_sdl.h` includes, unmodified | (R7) types for the run-time SDL function table |
| libSDL3 (the library) | 3.4.18 | zlib | **not vendored and not linked**: opened with `dlopen` at run time (`OV_SDL3_LIBRARY`, the loader's search path, `~/.local/lib`, Homebrew) | (R7) windows and input; without it the package builds and the app host runs headless |

Run-time tools, not linked or shipped: on Linux the settings portal is read
through the `gdbus` program when it is installed (GLib, LGPL-2.1-or-later;
run as a separate process, its text output parsed; R10). The test-only
stand-in portal `Scripts/fake_portal.py` (ours) uses the system's PyGObject
(LGPL-2.1-or-later) when run; it is not part of the package. AccessKit was
not used (see "Environment, persistence and accessibility design (R10)");
the AT-SPI export is our own code on our own D-Bus client (see "AT-SPI
export"), and `libatspi`/`libdbus` are not linked. The AT-SPI client check
`Scripts/atspi_client.py` (ours) uses the system's libatspi through its
GObject bindings (at-spi2-core and PyGObject, LGPL-2.1-or-later) as a
separate process; the D-Bus tests run the system's `dbus-daemon`
(AFL-2.1 OR GPL-2.0-or-later) as a separate program when it is installed.

Font reading, shaping, line breaking and bidi are our own implementations
(see "Text design (R4)"); so are glyph outlines (`glyf`/`loca`), PNG
encoding (DEFLATE) and the symbol artwork. ThorVG compiles in about 20 s
(once; C++14, no exceptions needed); the Vulkan loader is optional at run
time, so macOS and machines without Vulkan build and render through the
CPU.

Building libSDL3 without root (what the x86 workstation and the Thor use;
neither has an SDL3 package): clone the tag into a user folder and

    cmake -S SDL -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PREFIX \
          -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF -DSDL_AUDIO=OFF -DSDL_CAMERA=OFF \
          -DSDL_JOYSTICK=OFF -DSDL_HAPTIC=OFF -DSDL_HIDAPI=OFF -DSDL_SENSOR=OFF -DSDL_GPU=OFF \
          -DSDL_DIALOG=OFF -DSDL_TRAY=OFF -DSDL_X11_XTEST=OFF -DSDL_VULKAN=ON
    cmake --build build && cmake --install build      # → $PREFIX/lib/libSDL3.so.0

SDL loads its X11 and Wayland client libraries at run time, so it needs only
their development headers when it is built. Where those are missing (the
x86 workstation lacked the XInput2, XRandR, Xcursor and XFixes headers, and
Wayland's), `apt-get download <pkg>-dev` and `dpkg -x` into a user folder
supply them without root (pass that folder's `usr/include` in `CFLAGS` and
`CMAKE_PREFIX_PATH`). The workstation's build has X11 only (no Wayland
headers); the Thor's has X11, Wayland (with libdecor) and KMS/DRM.

Bundled font data (runtime resources of `OVText`, `Sources/OVText/Resources/Fonts/`):

| Font | Version | Licence | Provenance |
|---|---|---|---|
| Noto Sans Regular and Bold (`NotoSans-Regular.ttf`, `NotoSans-Bold.ttf`) | 2.004 (sha256 `89c3c497…2909d`, `e83493c9…272ac5`) | SIL Open Font License 1.1 (`OFL.txt` next to the files; © 2015 Google LLC) | Upstream Noto fonts (github.com/notofonts), as packaged by Ubuntu `fonts-noto-core` 20201225-2build1; unmodified |
| (R13) Noto Sans Mono Regular and Bold (`NotoSansMono-Regular.ttf`, `NotoSansMono-Bold.ttf`) | 2.006 (sha256 `6b692c4b…af7e29f`, `b22563d5…88e21e`) | SIL Open Font License 1.1 (the same `OFL.txt`; © 2015 Google LLC) | Upstream Noto fonts, as packaged by Ubuntu `fonts-noto-mono` 20201225-2build1 (copied from the x86 workstation's `/usr/share/fonts/truetype/noto/`); unmodified. Used for `Font.Design.monospaced` and `.monospaced()` (the catalog's first monospaced family) |

Symbol artwork: Ycode's own drawings (`Sources/OVRender/SymbolArtwork.swift`,
the repository's MIT licence, no third-party artwork); Apple's SF Symbols are
never used or shipped. See "Rendering design (R5)".

Apple's system fonts are never used or shipped: the font catalog refuses
their family names (`SF …`, `New York`, names starting with `.`) and scans
no system font directory on Apple hosts. On Apple hosts `Combine` is
re-exported for `ObservableObject`/`@Published` (as `import SwiftUI` does);
Linux has no Combine, so the core defines the same names with the subset the
graph needs (`ObservableObject`, `ObservableObjectPublisher`, `@Published`,
`Publisher.sink`, `AnyCancellable`).

## Build and test

    swift build && swift test          # macOS or Linux, from this directory

Run the sample on a Linux desktop (X11 or Wayland; `SDL_VIDEO_DRIVER=x11`
or `wayland` forces one):

    OV_SDL3_LIBRARY=$PREFIX/lib/libSDL3.so.0 swift run ov-sample

`OV_SAMPLE_SCRIPT=1` drives it with synthetic events through SDL's queue and
`OV_SCREENSHOT=<file.png>` writes the window surface read back at the end;
the other switches are listed in `Sources/OVSampleApp/SampleApp.swift`.
`OV_TEST_SDL=1 swift test` adds the SDL back-end test (needs a display).
macOS: the package builds and tests there; the host runs headless (the SDL
back end compiles and would load a Homebrew libSDL3, but windows on the
shared Mac are not exercised).

Regenerate the golden tests after the spec table changes:

    python3 -I Scripts/gen_golden_tests.py

Rendering tests (T-IMG, `Tests/OpenViewsTests/R5/`): `OV_RENDER_OUT=<dir>`
keeps every rendered PNG; `OV_UPDATE_GOLDENS=1` rewrites the golden PNGs
(`R5/Goldens/`); `OV_REQUIRE_VULKAN=1` makes a missing Vulkan device a
failure instead of a skip; `OV_VULKAN_DEVICE=llvmpipe` (or `cpu`, `gpu`, any
part of a device name) picks the device, e.g. lavapipe for CI. The
compositor's shaders are GLSL in `Shaders/`; after editing them compile with
`glslc` and run `python3 -I Scripts/gen_shaders.py`.

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

### Platform, app and input design (R7)

`06-app-and-components.md` §1, §5, §7 and `09-open-design.md` §3.6, §4;
sources in `Sources/OVPlatform/`, `Sources/COVSDL/`,
`Sources/SwiftUICore/Input/` and `Sources/SwiftUI/{App,Input,Controls}/`.

- **Back ends.** `PlatformBackend` makes windows and delivers
  `PlatformEvent`s (pointer, touch, wheel, keys, committed text,
  input-method composition, window changes, URLs, quit). `SDLBackend` uses
  SDL3 through `COVSDL` (X11 or Wayland as SDL picks; on X11 the window
  surface uses SDL's native shared-memory framebuffer). Window coordinates
  are converted to points with SDL's pixel density and display scale (HiDPI:
  a window of 420 × 320 pt at scale 2 has an 840 × 640 back buffer).
  Synthetic mouse and key events are pushed through SDL's own queue and come
  back through the same translation as real ones. `HeadlessBackend` keeps
  windows in memory and has a virtual clock that jumps to each deadline.
- **Run loop and display link** (`PlatformRunLoop`): wait → events → timers
  → frame. The SDL back end sleeps in the main run loop with a dispatch
  source on the X11/Wayland connection's descriptor, so it wakes for
  window-system input *and* for main-queue work (main-actor tasks); with
  nothing to do it sleeps without a deadline (an idle app renders no frame).
  Frames are paced by a `DisplayLink` at the display's refresh rate (60 Hz
  when unknown), on a grid of tick times that restarts after an idle gap;
  a frame is produced only while the host needs one (state changed, an
  animation runs, the window was resized or exposed). Frame time is the
  animation clock inside a frame (`HostClock`).
- **Presentation** (`Presenter.swift`): each window is an OVRender
  `RenderSurface` (`.vulkan` for windows created for Vulkan — the platform's
  `PlatformVulkanSurface` gives the instance extensions and creates the
  `VkSurfaceKHR` — otherwise `.software`). Per frame the host renders the
  graph's display list (R5) with the compositor `makeCompositor` made for the
  window. With `OV_RENDERER=auto` (default) the host first creates a Vulkan
  window and asks for R5's Vulkan compositor; if no device can present to it
  (e.g. the NVIDIA Thor under a pixman-rendering headless Weston), the window
  is re-created for the software compositor, whose CPU frames go to the
  window surface. `OV_RENDERER=software` or `vulkan` forces one. Readback
  goes through the compositor (the GPU image for Vulkan windows).
- **App host** (`AppHost`): `App.main()` creates the default back end and
  runs `App.init`, the delegate adaptors' `didFinishLaunching` (application
  in the background), `App.body` (evaluated as a graph node, so the app's
  `@State`/`@Environment` work), connects the first scene's window, then
  phases inactive and active in the reference's order (App first, then the
  views, then `didBecomeActive`). Scenes are flattened from `App.body`
  (`WindowGroup`, `Window`, tuples, optionals, `_ModifiedScene` with
  `defaultSize`, `windowResizability`, `environment`, scene `onChange`).
  Each window has its own view graph whose root environment carries the
  scene phase, display scale, `openWindow`/`dismissWindow`, `openURL` and
  the window services.
- **Gestures** (`GestureRuntime.swift`, `Recognizers.swift`): recognizers
  are state machines fed with pointer samples and timer ticks; they call no
  user code until the arbiter lets them flush. A press starts a session with
  the gestures on the hit chain (hit testing walks the view tree topmost
  first: later siblings, overlays above content, backgrounds below; a
  primitive that draws, or a `contentShape`, is hit; `allowsHitTesting(false)`
  removes a subtree; disabled views' gestures do not take part). Order:
  inner before outer, the first-applied modifier first on one view,
  `highPriorityGesture` ahead of its subtree, `simultaneousGesture` apart;
  `GestureMask` prunes. The first exclusive gesture to become active or end
  wins (ties by order) unless a higher one is a multi-tap waiting for its next
  tap; the winner cancels the others (`@GestureState` resets). Values are
  carried untyped inside the runtime and retyped at the callbacks.
- **Focus and text** (`Focus.swift`, `ButtonAndTextField.swift`):
  `@FocusState` with `focused(_:)`/`focused(_:equals:)`; focusable views
  register with their window's `FocusSystem`, which applies programmatic
  focus after each update and writes the bindings on user focus changes
  (tap, Tab/Shift-Tab, Return, Escape). The focused `TextField` is the text
  client: committed text is inserted at the caret (auto-capitalised per
  `textInputAutocapitalization`), input-method composition is shown as
  marked text, Backspace/Delete/arrows/Home/End edit, Ctrl+V/C/X use the
  clipboard, Return runs `onSubmit` and removes focus; the platform window's
  text input (and the IME's area) follows the focused field.
- **Keyboard shortcuts**: `keyboardShortcut` gives controls below it a
  shortcut; buttons register theirs with the window; a key press that the
  focused field does not use is matched (`.command` = Ctrl or Super on
  Linux).

### Controls design (R8)

`06-app-and-components.md` §4, `golden-layout.md`, `07` §4; sources in
`Sources/SwiftUI/Controls/` and `App/Popups.swift`.

- **Structure.** Controls are views with bodies built from the primitives
  (stacks, shapes, text, gestures, `Layout`s); the few that need the graph
  are primitives (`TextField`'s editable text, `Picker`, `Form`, `Section`).
  Each control's look comes from a style in the environment; the style
  protocols and configurations are the public ones (`ButtonStyle`,
  `PrimitiveButtonStyle`, `ToggleStyle`, `LabelStyle`, `ProgressViewStyle`,
  `GaugeStyle`, `LabeledContentStyle`); `PickerStyle`, `TextFieldStyle`,
  `MenuStyle`, `DatePickerStyle` and `FormStyle` expose no requirement in the
  reference API and are identified by a Ycode-internal kind.
- **Sizes** (all 21 golden rows reproduced): borderless, plain and automatic
  buttons are their label; bordered, prominent and glass add 12 × 7 (20 × 15
  at `.large`; mini 7 × 2, small 10 × 4, extra large 24 × 18 are ours);
  `ControlRowLayout` (toggle, stepper, compact date picker, a menu picker in a
  form row): ideal = label + 8 + control, a proposed width is taken but never
  less than label minimum + 8 + control, height = the larger; switch 61 × 28,
  stepper 94 × 32; `FillWidthLayout`: slider 0 × 31, linear progress 0 × 4;
  spinner 20 × 20; segmented picker: equal segments of the widest title
  (subheadline) + 8 + 8, 31 high, titles on the pixel grid; text fields: the
  content's width (placeholder or text) unproposed, one line pitch high
  (ascent + descent + leading on the pixel grid), text centred with its top
  rounded up, `.roundedBorder` insets 14 and 6, plain secure field a point
  lower (21, measured); gauge: label over a 16-point bar row with the default
  spacing; label: icon + 8 + title on the first text baseline; link: the
  title in the tint. Controls are standard views for spacing (the matrix's
  button row equals text, toggle and text field rows equal a colour).
- **Interaction.** Buttons, toggles, stepper halves and menu rows use the
  press recognizer (action on release inside, 10-point slop); a slider moves
  only when the press starts on its thumb (a track tap does nothing, 06 §4);
  text selection and thumbs use `PointerTrackRecognizer` (active from the
  press, events in local coordinates). Every control registers with the
  window's focus system: Tab and Shift-Tab move in tree order, Space and
  Return activate buttons, toggles and rows, arrows change sliders,
  steppers and segmented pickers, a menu picker opens on Space, Return or the
  arrows. Disabled controls take no gestures and no focus. A focused control
  shows Ycode's focus ring (2.5 pt tint outline, 3 pt outside). Decorative
  strokes and outlines take no hits (QA B2).
- **Pickers.** The options are the content's views with a `tag(_:)` whose
  type matches the selection (or the IDs of a `ForEach`); the content stays
  in the graph, unlaid-out, and each style draws the option views. Automatic
  = menu; in a `Form` a menu picker is a row with its label; `.wheel` shows
  inline.
- **Menus and pop-up windows.** `Menu` and menu pickers open their content
  in a pop-up window: `WindowConfiguration.popupParent`/`popupOrigin` in
  OVPlatform, `SDL_CreatePopupWindow` (popup menu, not focusable) on X11 and
  Wayland, kept in memory by the headless back end. The host measures the
  content at its ideal size (at least the control's width), runs it in a
  window graph of its own with the owner's bindings, and routes keys to the
  innermost pop-up of the window that has the keyboard: Up/Down move between
  items, Space/Return choose, Escape (and Left in a submenu) close. A menu
  item closes the whole chain; a press in another window closes pop-ups not
  on its chain and is not delivered; closing gives the owner the keyboard
  back (`XSetInputFocus` through SDL's libX11 on X11, where without a window
  manager the focus fell to the root). Nested `Menu`s open submenus at the
  row's trailing edge. When the window system refuses a pop-up window, the
  content is shown as an overlay of the window with the same rules.
- **Forms.** `Form` lowers its sections into a grouped layout: grouped
  background, sections as rounded groups (radius 10) inset 20, rows inset 20
  more and at least `defaultMinListRowHeight` high (52), hairline separators,
  footnote headers and footers, 35 points to the first row, 20 between
  sections. Loose rows form sections of their own. Rows are the layout nodes
  a section's content produces, so `ForEach`, groups and conditionals
  flatten. No scrolling yet (R9).
- **Look** (Ycode's palette, `09-open-design.md` §4.2): the spec's system
  colours where 07 §4 has them (fills, separators, grouped backgrounds,
  placeholder and secondary label), neutral choices elsewhere, light and
  dark; the accent is the environment's tint.
- **Compact date picker.** A bordered-look button with the date in the
  environment's locale, calendar and time zone (medium style; short time
  style for `.hourAndMinute`); its pop-up is a month calendar (or steppers
  for the time). `.graphical` shows the calendar inline.

### Text editing core (R8; PARITY §5.4 R14)

`Sources/OVText/Editing/TextEditing.swift` (no view types) and the view side
in `Controls/TextInput.swift`.

- **`TextEditingModel`**: characters (grapheme clusters, OVText's unit), a
  selection with anchor and head, marked (input-method) text shown at the
  selection without being committed, movements by character, word, visual
  line, paragraph and document (extending or not; arrows collapse a
  selection to its edge), vertical movement with a goal column through a
  `TextEditingLayout`, deletions by the same units, copy/cut/paste
  (single-line models turn newlines into spaces), undo and redo with
  coalesced typing and deletions, `setText` for changes from outside (keeps
  the caret where it fits, clears the history).
- **`TextLayoutGeometry`**: caret positions, hit testing, selection
  rectangles and visual-line boundaries of an OVText `TextLayout` (soft-wrap
  carets belong to the next line; a trailing newline opens an empty line;
  right-to-left runs follow visual order without split carets). It is the
  `TextEditingLayout` of the views and can serve EditorKit per line.
- **Views.** `TextField`, `SecureField` (bullets, no copy or cut) and
  `TextEditor` (wrapping, Return inserts a newline, Tab a tab, vertical
  scrolling to the caret) share one primitive: the field's state is the
  focus system's text client and draws selection, text or placeholder, the
  marked-text underline and a caret that blinks 0.53 s on / 0.53 s off on the
  window's service timer and rests (shown) after 10 s without activity; a
  single-line field scrolls horizontally to keep the caret visible. Pointer:
  click places the caret, double click selects a word, triple click the
  paragraph (all of a field), shift-click and drags extend (by words after a
  double click). Keys (Linux conventions): arrows, Ctrl+arrows by word,
  Home/End (line in editors), Ctrl+Home/End, Shift to extend, Backspace and
  Delete (Ctrl: by word), Ctrl+A/C/X/V, Ctrl+Z, Ctrl+Shift+Z and Ctrl+Y
  (Ctrl+Y only when no shortcut of the window takes it: an app's ⌘Y, such
  as the Linux IDE's Deactivate Breakpoints, comes first).
  Keyboard focus selects all; a click does not.

### QA fixes (R8, desktop QA report of 2026-10-30)

B1 animation frames are presented (`WindowHost.renderFrame` presented only
after a layout pass or a redraw request; render-effect animations now
present every frame: 59–60 frames/s on X11 with Vulkan or software, 57 on the
loaded Thor under Weston); B2 strokes and borders take no hits without a
content shape; B3 `background(Color…)`, `Color.opacity` in it, a trailing
closure `onLongPressGesture` and `\(x, specifier:)` compile as in the
reference API; B4 duplicate SDL clicks (two pairs within 4 ms at the same
place) and touch-synthesised mouse events are dropped (`MouseButtonFilter`);
B5 new windows are fitted to the display's usable bounds; B6 a resize is
reported once. Also: `foregroundStyle(.secondary)` resolves against the
outer foreground (it recursed without end), and SDL is left up at exit when
Vulkan is loaded (NVIDIA's GLX exit handler aborted after `SDL_Quit`).

### Containers and presentation design (R9; PARITY §5.4 R12)

`06-app-and-components.md` §2, §3, §6, `golden-layout.md` (`scrollView`,
`scrollView.horizontal`); sources in `Sources/SwiftUICore/Layout/LazyStacks.swift`,
`ScrollGeometry.swift`, the graph's suspension (`Graph/ViewNode.swift`) and
`Sources/SwiftUI/Containers/`.

- **Suspension.** A covered navigation page, an unselected tab and a hidden
  split column keep their view nodes and state but are *suspended*
  (`ViewNode.setSuspended`): their appearance actions run `onDisappear`
  (tasks are cancelled), they are not laid out, hit tested or focused, and
  resuming runs `onAppear` again. A view that already disappeared that way
  does not disappear again when it is removed (06 §2.1).
- **Lazy containers.** Content is enumerated, not built: tuples, groups,
  conditionals, `AnyView`, sections and outlines are walked, and a `ForEach`
  contributes a collection whose element views are made only for the
  materialised indices. Items keep their view nodes (and state) while they
  stay materialised, keyed by structural path and element ID. Units (one
  item for stacks, a row of cells for grids) remember their measured extents;
  the others use the mean, so equal rows give the exact content size at once
  (06 §3: 47 992). After each layout pass a container compares the visible
  region of its scroll view with what it materialised and asks for another
  update when they differ: no overscan, so the counts are the reference's
  (13 `List` rows, 15 `LazyVStack` rows). Outside a scroll view everything is
  materialised. Lazy stacks space items 8 points unless told otherwise.
  Lazy grids (`LazyVGrid`, and `LazyHGrid` with the axes swapped) are lazy
  by rows (columns) of cells inside scroll views: the materialised rows are
  laid out by the grid layout at the first row's start; outside a scroll
  view they create every cell, as before (golden `lazyvgrid.*`).
- **ScrollView.** Golden sizing: along a scroll axis the proposal (the
  content's length when unspecified), across it the content's answer to the
  cross proposal; the content gets an unspecified length along the axes, sits
  top-leading (centred across a single axis) and moves by the offset; the
  scroll view clips it and hit testing stops at its frame. Offsets run from 0
  to content − viewport. A scroll view whose frame touches the safe area
  scrolls its content under that inset (06 §3: a 34-point bottom content
  inset, 678 visible points). Drags (10 points to start) move the content
  with the finger; a release continues at the release velocity, decaying by
  0.998 per millisecond (closed form, 06 §3's ≈ 0.967 per frame) until
  slower than 10 points/s or at an edge (no rubber band). Wheel and trackpad
  deltas (R7, 10 points a notch) scroll at once; a single-axis scroll view
  takes the other axis's deltas too; nested scroll views pass a delta on at
  their edges. Indicators: 3-point capsules 3 points inside the edges, at
  least 36 long, while scrolling and 1 s after (then a 0.25 s fade).
  `onScrollGeometryChange` reports the first value and every change (once per
  frame while scrolling), `scrollPosition(id:)` follows the first item at
  least half visible and scrolls to a new ID, `scrollTargetBehavior(.paging)`
  / `.viewAligned` choose where a fling rests (then a 0.4 s spring),
  `defaultScrollAnchor`, `scrollIndicators`, `scrollDisabled`.
  `ScrollViewReader.scrollTo(id, anchor:)` finds a materialised view with that
  ID or a lazy item (unmaterialised ones by their estimated frame); without an
  anchor it scrolls the least distance; inside `withAnimation` it animates.
- **List.** A vertical scroll view over a lazy container of rows. Rows are at
  least `defaultMinListRowHeight` high (52, 06 §3). Inset-grouped (the
  automatic style): sections in rounded groups (radius 10) 20 points from the
  edges, row content 20 more (x = 40, 06 §2.1), the first row 13.33 below
  the top (06 §3's `scrollTo` offset 500 × 52 + 13.33), separators inset like
  the content, footnote headers, 20 points between sections; plain: rows inset
  20 (golden `list.plain`); grouped: full-width groups; sidebar (Ycode's
  desktop navigator): 28-point rows, 16 points per outline level, a rounded
  selection. Selection (Ycode's desktop rules): a click selects and focuses
  the list; with a multiple selection Ctrl/Super toggles and Shift extends
  from the last clicked row; Up/Down (Shift extends), Home/End, Right/Left
  expand, collapse, go to the first child or the parent; the row is scrolled
  into view. A row's selection value is its `tag`, else its `ForEach` ID.
  `listRowInsets`, `listRowBackground`, `listRowSeparator`,
  `scrollContentBackground(.hidden)`.
- **Outlines.** `OutlineGroup`, `List(_:children:)` and `DisclosureGroup`
  flatten into rows inside lazy containers (an element with a children array,
  even an empty one, has a disclosure triangle; expansion is kept per row key,
  collapsed by default, or by a disclosure group's binding); outside them
  they are nested disclosure groups (chevron, label, content 18 points in).
- **NavigationStack.** One view node per page (root, path values, destination
  links). Push: the destination appears at once, slides in over 0.5 s
  (ease-in-out) while the page below moves to −30 %, and the covered page is
  suspended at the end; pop: the page below resumes at the start, the popped
  page is removed at the end; pages under the top that were never shown are
  not suspended (the [4, 5] case). Path changes animate unless the
  transaction disables animations. The back swipe starts within 20 points of
  a page's leading edge (a high-priority gesture that only activates on a
  10-point horizontal move, so taps and vertical scrolling still work) and
  pops when released past half the width or faster than 500 points/s.
  Each page draws its bar (back button with the previous title, title,
  toolbar items): 82 points on the headless host (06 §2.1), 44 on desktop
  hosts. Titles, bar options and toolbars register with an observable page
  context, so changing them re-renders only the bar.
  `navigationDestination(for:)`, `(isPresented:)`, `(item:)`, `NavigationLink`
  (value and destination forms), `NavigationPath`, `dismiss`.
- **Split views.** Panes with 1-point dividers dragged within an 8-point
  band; pane limits are the answers to zero and infinite proposals; first
  lengths are the ideal length for panes with a finite maximum, the rest
  share; the last flexible pane absorbs container changes (`HSplitView`,
  `VSplitView`). `NavigationSplitView`: below 600 points it collapses to a
  navigation stack (06 §2.2: sidebar first; a sidebar list selection pushes
  the next column; clearing it, or going back, pops and clears); otherwise
  columns are panes (sidebar 180–400, 240 at first; content 200–500, 280;
  detail ≥ 300; `navigationSplitViewColumnWidth`), each the root of its own
  stack, with `columnVisibility` (hidden columns are suspended) and a sidebar
  button in the first shown column's bar.
- **Presentations.** Sheets, covers, alerts and dialogs are layers of their
  window (below its pop-up overlays) with a dimming layer that takes every
  press; Tab stays in the innermost one. `onAppear` when presenting starts;
  dismissal runs 0.5 s, then `onDismiss`, then the content's `onDisappear`
  (06 §6). Phone host geometry (the reference's window): `.large` (8, 8,
  W − 8, H − 8) in the safe area W × H; other detents end 8 points above the
  safe bottom, `.medium` = half the window height + 17 (356 at 678);
  detent bindings resize. Desktop hosts: a centred card at the content's
  ideal size (360 × 200 up to the window less 40). Covers fill the window
  (content in the safe area). Alerts: 270 points wide (300 on desktop),
  centred; dialogs are action sheets at the bottom of the phone host and
  centred cards on desktop hosts; a button runs its action and dismisses.
  Popovers are R8 pop-up windows (with a plain chrome) below the anchor;
  `inspector` is a 270-point trailing column.
- **TabView.** Only the selected tab is built; selecting another builds it
  (its `onAppear` before the old one's `onDisappear`, 06 §2.3); tabs keep
  their state while suspended; a floating capsule tab bar 8 points above the
  bottom does not change the content's frame. `Tab` and `tabItem` + `tag`.
- **Graph fix.** A new root value set during a pass (a window's presentation
  layer appearing) is applied in the next pass (the flag was cleared after the
  pass that set it).

### Environment, persistence and accessibility design (R10)

`08-environment-accessibility-localization.md` §1–2, `06-app-and-components.md`
§8; sources in `Sources/OVPlatform/Settings.swift`,
`Sources/SwiftUI/App/{PlatformEnvironment,Persistence}.swift` and
`Sources/SwiftUI/Accessibility/`.

- **Desktop settings.** A back end reports `PlatformSettings` (appearance,
  increased contrast, reduce motion and transparency, differentiate without
  colour, invert colours, bold text, button shapes, a Dynamic Type size,
  locale, time zone) and a `.settingsChanged` event. Sources on the SDL back
  end, strongest first: environment variables fixed for the process
  (`OV_COLOR_SCHEME`, `OV_CONTRAST`, `OV_REDUCE_MOTION`,
  `OV_REDUCE_TRANSPARENCY`, `OV_DIFFERENTIATE_WITHOUT_COLOR`,
  `OV_INVERT_COLORS`, `OV_BOLD_TEXT`, `OV_BUTTON_SHAPES`, `OV_CONTENT_SIZE`,
  `OV_TEXT_SCALE`, `OV_LOCALE`); a settings file watched without polling
  (inotify on Linux, a vnode source on macOS): `$OV_SETTINGS_FILE`, else
  `$XDG_CONFIG_HOME/openviews/settings.conf` (`~/.config/…`), lines
  `key = value` with `color-scheme`, `contrast`, `reduce-motion`,
  `reduce-transparency`, `differentiate-without-color`, `invert-colors`,
  `bold-text`, `button-shapes`, `content-size`, `text-scale`, `locale`;
  the freedesktop settings portal over the session bus through the `gdbus`
  tool (`ReadAll` of `org.freedesktop.appearance`,
  `org.gnome.desktop.interface` and `org.gnome.desktop.a11y.interface` at
  start, then `gdbus monitor` for `SettingChanged`: colour scheme, contrast,
  `text-scaling-factor`, `enable-animations`, `high-contrast`;
  `OV_SETTINGS_PORTAL=0` turns it off); SDL's system theme and its
  theme-changed event; `LC_ALL`/`LC_MESSAGES`/`LANG` for the locale; the
  08 §1 defaults. Desktop text scales map to Dynamic Type sizes (< 0.85
  xSmall … 1.0 large … ≥ 2.3 accessibility5; `Settings.swift`). The headless
  back end keeps the 08 §1 defaults; tests change its `settings` like a user
  changing a desktop setting.
- **Live environment.** The host writes the settings into the root
  environment of the app and of every window (`colorScheme`,
  `colorSchemeContrast`, `dynamicTypeSize`, `legibilityWeight`, the
  accessibility flags, `locale` with its calendar, `layoutDirection` from the
  locale's language, `timeZone`, and `defaultMinListRowHeight` 52 → 59 from
  accessibility2 up, 06 §3) and again on every change; only keys that changed
  are written, so only their readers re-render (08 §1.1: no relaunch).
- **`@AppStorage`.** A value of `UserDefaults` (the standard defaults, the
  `store:` argument or `defaultAppStorage`), for `Bool`, `Int`, `Double`,
  `String`, `URL`, `Data`, `Date`, `RawRepresentable` with `Int` or `String`
  raw values and the optional forms. Readers depend on their key: a write
  through a wrapper invalidates every reader of the key at once; writes made
  through `UserDefaults` directly are seen through
  `UserDefaults.didChangeNotification` and, because swift-corelibs-foundation
  posts none for `set(_:forKey:)` (checked on the x86 workstation), by
  comparing the readers' keys after every wake of the run loop (before the
  frame), so a write from an event handler, a timer or a main-actor task shows
  in the same frame (06 §8: within 6 ms).
- **`@SceneStorage`.** A value per window: views of one window share a key,
  values outlive the view (navigation, tabs, conditionals), each window of a
  group has its own. On window-system hosts the values are archived when the
  app goes to the background (property lists in
  `$XDG_STATE_HOME/openviews/<app>/scenes/`), discarded when the user closes
  the window or quits (06 §8: not restored after a user quit), and restored
  at the next launch when an archive exists — that is, after the process
  ended without a user quit (session end, a signal). The headless host keeps
  scene storage in memory.
- **Accessibility tree.** Built on demand from the laid-out view graph, as
  the reference built none without an assistive technology (08 §2): the
  window is the root (role window, labelled with its title); texts are static
  text elements; images are image elements labelled by `accessibilityLabel`,
  their own label (`Image(_:bundle:label:)`), the symbol's default label
  (08 §2: "star.fill" → "Favorite"; Ycode's words for the rest of its symbol
  set) or the asset name; decorative images and `accessibilityHidden(true)`
  subtrees are left out, as are suspended subtrees and views that are not
  laid out. Controls annotate themselves and combine the elements of their
  labels: `Button` (button), `Toggle` (button + toggle, value 1/0), `Slider`
  (adjustable, the value as a percentage of the range), `Stepper`
  (adjustable), `Link` (link), text fields (value = the text, no label;
  secure fields no value), `ProgressView` (the percentage, updates
  frequently), `Label` (its title), lists (a container of rows, the selected
  ones with the selected trait), the menu bar and its titles, the window
  toolbar. `accessibilityElement(children:)` `.ignore`/`.combine` (labels and
  values joined with ", ", traits united)/`.contain`; the
  label/value/hint/identifier/traits modifiers; `accessibilityAction`
  (default, named), `accessibilityAdjustableAction`,
  `accessibilitySortPriority`, `accessibilityHeading`;
  `AccessibilityTree.perform` runs an element's action (what an assistive
  technology's request would do). Frames are window points; the window's
  reading order is menu bar, toolbar, content, bottom bar, presentations.
- **AT-SPI export: done (OV-ATSPI).** The plan's route was AccessKit (MIT
  OR Apache-2.0, Rust); building its crates was refused, and the owner chose
  an exporter of our own in Swift, with no third-party code. See "AT-SPI
  export" below.

### AT-SPI export (R10, OV-ATSPI)

OpenViews windows are exported to Linux assistive technologies (Orca,
Accerciser, any libatspi client) over AT-SPI2. Sources:
`Sources/OVDBus/` (the D-Bus client), `Sources/OVAccessibilityATSPI/` (the
exporter) and `Sources/SwiftUI/Accessibility/ATSPIBridge.swift` (the
mapping of the R10 tree onto it). Everything is written from public
specifications; no D-Bus or AT-SPI library code is used or linked.

Specifications read (interoperability facts only: names, signatures,
enumeration values, the wire format; no code):

| Document | Version | Licence | Use |
|---|---|---|---|
| D-Bus Specification (`dbus.freedesktop.org/doc/dbus-specification.html`) | 0.43 (2024-10-29), read 2026-10-30 | part of the dbus project: AFL-2.1 OR GPL-2.0-or-later (its `COPYING`) | type system and signatures, marshalling, message format and header fields, names, addresses and the Unix transport, the authentication protocol (EXTERNAL), the bus's `Hello`/`AddMatch`/`RequestName`, `Peer`, `Introspectable`, `Properties`, the introspection format |
| at-spi2-core interface descriptions (`gitlab.gnome.org/GNOME/at-spi2-core`, `xml/Accessible.xml`, `Action.xml`, `Application.xml`, `Cache.xml`, `Component.xml`, `EditableText.xml`, `Event.xml`, `Registry.xml`, `Selection.xml`, `Socket.xml`, `Text.xml`, `Value.xml`) | `main`, read 2026-10-30 | LGPL-2.1-or-later (the repository's `COPYING`) | interface, method, property and signal names and signatures; the role and state numbers (`GetRole`, `GetState` documentation); coordinate types, layers, text granularities and boundaries; the Embed handshake; the Cache item layout; the event body `(siiva{sv})` |
| The bus launcher's `org.a11y.Bus.GetAddress` on `/org/a11y/bus` | at-spi2-core | as above | finding the accessibility bus |

The **D-Bus client** (`OVDBus`, Foundation and POSIX sockets):

- `DBusType`/`DBusValue`: every type (`y b n q i u x t d s o g h a ( ) { } v`)
  with signature validation (at most 255 bytes, 32 nested arrays and 32
  nested structs, dict entries only in arrays with a basic key);
  `DBusEncoder`/`DBusDecoder` in either byte order with the natural
  alignment counted from the message start, nul padding checked on read,
  64 MiB arrays and 128 MiB messages at most; strings checked for UTF-8 and
  nul bytes, object paths for their grammar.
- `DBusMessage`: the `yyyyuua(yv)` header with fields 1–9 (unknown codes
  ignored), required fields per message type checked, little- or
  big-endian decoding, little-endian encoding.
- `DBusSocket`: `unix:path=` and (Linux) `unix:abstract=` addresses with
  `%xx` unescaping, address lists tried in order; the credentials nul byte,
  `AUTH EXTERNAL <hex of the decimal uid>`, `OK <guid>`, `BEGIN`.
- `DBusConnection` (main actor): `Hello`; method calls answered
  asynchronously (a handler per serial) or awaited (`call(_:timeout:)`,
  which keeps answering incoming calls while it waits, so a peer may call
  back first); signals and `AddMatch`; exported objects through a
  `DBusObjectTree` with `Peer.Ping`/`GetMachineId`, `Introspect` from
  interface descriptions, `Properties.Get`/`GetAll`/`Set`, the standard
  errors (`UnknownObject`, `UnknownInterface`, `UnknownMethod`,
  `UnknownProperty`, `PropertyReadOnly`, `InvalidArgs`). Data is read when
  the socket is readable — a dispatch source on the main queue, which the
  SDL back end's run loop serves — or by `pump` (tests).

The **exporter** (`OVAccessibilityATSPI`):

- **Bus.** `AT_SPI_BUS_ADDRESS`, else `org.a11y.Bus.GetAddress` on the
  session bus (which activates the bus launcher, as for any toolkit). No
  session bus and no address: no export, nothing else happens.
- **Registration.** `Socket.Embed((so))` on the registry
  (`org.a11y.atspi.Registry`, `/org/a11y/atspi/accessible/root`) with our
  unique name and `/org/a11y/atspi/accessible/root`; the reply (the
  desktop) arrives asynchronously, so the registry's `Properties.Set` of
  `Application.Id` during the call is answered. Listener tracking:
  `Registry.GetRegisteredEvents`, then `EventListenerRegistered`/
  `Deregistered` and `NameOwnerChanged` (an AT that leaves stops counting).
- **Objects.** The application root (role application, Accessible and
  Application: `ToolkitName` "OpenViews", `AtspiVersion` "2.1", `Id`
  read/write, `GetLocale`, an empty `GetApplicationBusAddress`) whose
  children are the windows; one object per element at
  `/org/a11y/atspi/accessible/<key>` (a window `w<n>`, an element
  `w<n>_<id>`), each with Accessible (name, description = hint, parent,
  children, index, role and role name, the two-word state set, attributes:
  `toolkit`, `id`, heading `level`; an empty relation set) and Component
  (extents in screen, window or parent coordinates, `Contains`,
  `GetAccessibleAtPoint` to the deepest element, layer, `GrabFocus`; moves
  and resizes are refused); Action when the element has actions; Text for
  text inputs and static texts, EditableText for enabled text inputs;
  Value for sliders and progress views; Selection for lists. The Cache at
  `/org/a11y/atspi/cache`: `GetItems` (`a((so)(so)(so)iiassusau)`, the root
  and every element), `AddAccessible`/`RemoveAccessible` when elements come
  and go. Introspection lists exactly what each object answers.
- **Laziness and incremental updates.** No window's tree is built until a
  client asks for one of its objects (08 §2: the reference built none
  without an assistive technology). Each window has a cheap revision (its
  graph's pass count, size, focused node, active state and title); a
  snapshot is rebuilt only when the revision moved, only for that window,
  and only when a client asks or — while some AT has registered a listener
  — after a frame (and after a window-focus change, which renders nothing).
  The new snapshot is compared with the old one by element key, and the
  difference is sent: `RemoveAccessible`/`AddAccessible` and
  `children-changed:remove`/`add` for the topmost removed or added
  elements; `property-change:accessible-name`, `accessible-description`,
  `accessible-role`, `accessible-value`; `state-changed:<state>` per
  changed state (focus losses before focus gains); `Event.Focus.Focus` with
  `state-changed:focused`; `text-changed:delete`/`insert` from the common
  prefix and suffix of the old and new text, `text-caret-moved`;
  `window:activate`/`deactivate`, and `window:create`/`destroy` with the
  root's `children-changed` when windows open and close. Only events a
  registered listener covers are sent (prefix match of `class:major:minor`,
  case and dashes ignored); when the registry does not answer, all are.
- **Requests.** `DoAction`, `GrabFocus` (the first focus target inside the
  element; the window itself is raised), `SetTextContents`, `InsertText`,
  `DeleteText`, `CutText`/`CopyText`/`PasteText` (the window's clipboard),
  `SetCaretOffset`, `SetSelection`/`AddSelection`/`RemoveSelection`, the
  Value's `CurrentValue`, `Selection.SelectChild` (the row's own action)
  run on the element's closures, as `AccessibilityTree.perform` does, then
  the window updates and draws a frame. Text offsets are Unicode scalars
  (AT-SPI's characters), converted to and from the editing model's
  grapheme offsets. Character extents divide the element's box evenly (no
  glyph geometry is exported yet).

Starting: `App.main()` starts the export on window-system back ends;
`OV_ATSPI=0` turns it off, `OV_ATSPI=1` turns it on for the headless back
end too, `OV_ATSPI_TRACE=1` (or `OV_TRACE`) traces it on stderr.

Role mapping (Ycode's table; `ATSPIMapping` in `ATSPIBridge.swift`):

| OpenViews role (traits) | AT-SPI role (number) | States and interfaces beyond the common ones |
|---|---|---|
| application root | application (75) | Accessible, Application |
| `window` (main window) | frame (23) | active (the window system's key window; the first main window until it reports focus), resizable |
| `window` (pop-up window) | window (69) | active |
| `group` | panel (39) | |
| `staticText` | label (29) | Text (read-only) |
| `staticText` (header trait) | heading (83) | attribute `level` from `accessibilityHeading` |
| `image` | image (27) | |
| `button` | push button (43) | focusable; action `click` |
| `toggle` | toggle button (62) | focusable, checkable, checked when the value is 1; `click` |
| `slider` | slider (51) | focusable, horizontal; Value (range and step, settable); `increment`, `decrement` |
| `stepper` | spin button (52) | focusable; `increment`, `decrement` |
| `link` | link (88) | focusable; `click` |
| `textField` (one line) | entry (79) | focusable, editable, single-line, selectable-text; Text, EditableText |
| `textField` (`TextEditor`, vertical fields) | text (61) | as entry, multi-line |
| `secureTextField` | password text (40) | as entry; the text is bullets |
| `progressIndicator` | progress bar (42) | animated; Value 0–100 (read-only) |
| `picker` | combo box (11) | focusable, has-popup |
| `menuButton` | push button (43) | focusable, has-popup |
| `list` | list (31); tree (65) when a row expands | focusable; Selection |
| `row` | list item (32); tree item (91) in a tree | focusable, selectable, selected (selected trait), expandable with expanded/collapsed (outline rows with children); actions `activate`, `expand or collapse` |
| `menuBar` | menu bar (34) | |
| `menuBarItem`, `menu` | menu (33) | focusable, has-popup; `click` |
| `menuItem` | menu item (35); check menu item (8) with the toggle trait | focusable; `click` |
| `toolbar` | tool bar (63) | |
| `dialog` / `alert` | dialog (16) / alert (2) | modal (modal trait) |
| `tabList` / `tab` | page tab list (38) / page tab (37) | the tab focusable; `click` |
| `scrollView` | scroll pane (49) | |
| `splitter` | separator (50) | |

Every element is visible; showing when its frame is non-empty and meets the
window; enabled and sensitive unless disabled; focused only for the
innermost element that contains the focused view (the R10 tree marks the
ancestors too). The default action is `click` for the clickable roles and
`activate` otherwise, with the element's hint as its description. Two
changes to the R10 tree came with the export: the window's commands host
(controls kept for shortcuts, not laid out) is left out, and an outline
row's disclosure chevron is hidden (the row's expanded state and action
stand for it); sliders and progress views publish their range, and outline
rows their expanded state and an `expand or collapse` action. SDL windows
remember their title, and report their screen position (`SDL_GetWindowPosition`;
X11) for screen coordinates.

Tests: `Tests/OpenViewsTests/ATSPI/` — `DBusMarshallingTests` (the
specification's examples byte for byte: the strings "foo", "+", "bar"
little-endian, an array of one INT64 and a variant of a UINT64
big-endian, the EXTERNAL line for uid 1000; every type round-tripped in
both byte orders, alone and in sequence, with the AT-SPI shapes; padding
and alignment, empty arrays, dict entries; malformed input; signatures;
names; headers; addresses), `ATSPIMappingTests` (the role and state table
on a probe screen, the requests, revisions, the state words, text
segments) and `DBusLiveTests` (against a private `dbus-daemon` when one is
installed — Linux hosts and a Mac with one: calls, replies, errors,
signals, a 320 KB message, introspection and properties between two of
our connections; then the exporter with a stand-in registry and a stand-in
assistive technology: Embed and the Id, laziness (no tree built while
nobody asks or listens), the tree walked over the bus, interfaces,
states, extents, the Cache, `DoAction`, focus, text, state, value,
children and window events, and no event nobody asked for).

The **client check** (2026-10-30): `Scripts/atspi_check.sh` runs the mini
IDE in a private session bus (the system's bus launcher and registry,
at-spi2-core 2.60.4 on the x86 workstation, 2.52.0 on the Thor) and
`Scripts/atspi_client.py` against it, a libatspi client through the
GObject bindings. On the x86 workstation (Xvfb, SDL X11) and the Thor
(headless Weston, SDL Wayland) it found the application (toolkit
OpenViews) and its frame named with the window title, active; the menu bar
with the application's, File, Edit, View, Project, Window and Help menus;
the toolbar's Build and Run buttons (action `click`, extents); the outline
as a tree of tree items with an expandable folder; activated a file row
(selected, the editor appeared: a multi-line editable text with the
file's 130 characters); invoked Build (the app counted the build and the
toolbar's status label read "Build 1 succeeded"); moved the focus with
`GrabFocus` to the editor and back to the outline and received
`object:state-changed:focused` (the old element 0, the new 1) and `focus:`
each time; inserted text through EditableText and received
`object:text-changed:insert`. On X11, real clicks (XTEST through
`xdotool`) on the outline and the editor sent the same focus events.

### Commands, menus and toolbars design (R11; PARITY §5.4)

Public API names (level 1); sources in `Sources/SwiftUI/App/{Commands,MenuBar,
WindowChrome,Settings}.swift`, `Sources/SwiftUI/Input/{FocusedValues,
ContextMenu}.swift` and `Containers/Toolbar.swift`. All of it is Ycode's
design; nothing of the reference's menus was measured (the reference is an
iOS device).

- **Menu bar.** Linux desktops have no global menu bar, so every main window
  draws one, 26 points high, above its toolbar (the Settings window and
  pop-ups have none). The commands of every scene are merged into one menu
  model for the app. Menus in order: the application menu (titled with the
  app's name: `OV_APP_NAME`, the bundle name, else the process name), File,
  Edit, View, the app's `CommandMenu`s (after View, where the public
  documentation puts them; a `CommandMenu` with a standard title joins that
  menu), Window, Help; menus with no items are not shown. Each standard menu
  is a list of standard groups (`CommandGroupPlacement`): a group shows its
  default items or a `CommandGroup(replacing:)`'s, with `before:`/`after:`
  items around them, and non-empty groups are separated by a line. Default
  items and their Linux shortcuts: About <App>; Settings… Ctrl+, (with a
  `Settings` scene); Quit <App> Ctrl+Q; New Window Ctrl+N (with a
  `WindowGroup`); Close Window Ctrl+W; Undo Ctrl+Z, Redo Ctrl+Shift+Z, Cut
  Ctrl+X, Copy Ctrl+C, Paste Ctrl+V, Delete, Select All Ctrl+A (enabled when
  the focused text view can perform them; they act on R8's editing model);
  Show/Hide Toolbar Ctrl+Alt+T (when the window has a toolbar); Show/Hide
  Sidebar Ctrl+Alt+S (`SidebarCommands`, toggling the window's
  `NavigationSplitView`); Minimize Ctrl+M, the open windows (the current one
  checked), the app's `Window` scenes; <App> Help (disabled: no help book).
  `commandsRemoved()` drops the scene's own items (New Window, its window
  entry). Shortcut text reads "Ctrl+Shift+Z" (`.command` is Ctrl).
- **Interaction.** A press on a title opens its menu as an R8 pop-up window;
  while a menu is open, moving over another title opens that one; Left and
  Right move between menus, Up and Down between items, Return or Space
  chooses, Escape closes; F10 opens the first menu (with or without Alt:
  some X keymaps deliver F10 with it). Items run on release.
- **Commands in the graph.** Each window evaluates the merged commands under
  an unlaid-out host: a custom `Commands` type is a graph node like a view
  (`@FocusedValue`, `@State`, `@Environment` and observed models work; its
  body runs again when they change), and the item views of menus and groups
  are built there, as are the standard items, so their buttons' shortcuts
  are registered while every menu is closed.
- **Shortcut routing.** A key goes to the focused text view, then to the
  innermost pop-up, then the focused control, then the window's shortcuts:
  the window's own views first (in tree order), menu commands after them;
  disabled items and items in suspended subtrees do not run.
- **Focused values.** `focusedValue(_:_:)` publishes for the focused view and
  its ancestors: after every update the window takes, per key, the innermost
  publication on the chain from the focused view to the root;
  `focusedSceneValue` fills keys the chain does not publish, wherever the
  focus is; with nothing focused only scene values remain. `@FocusedValue`
  (key path or `Observable` type), `@FocusedBinding`, `focusedObject` /
  `@FocusedObject`. Readers depend through Observation on the set of
  publications they see (publisher, key, value generation), so commands
  re-evaluate only when it changes. Pop-ups read their owner's values.
- **Context menus.** A secondary click opens the items of the innermost view
  under the pointer with a `contextMenu`, as a pop-up menu at the pointer; a
  touch held 0.5 s within 10 points does the same and cancels the press (its
  buttons do not fire); Shift+F10 opens the focused view's menu.
  `contextMenu(forSelectionType:)` on a list gives each row the selection
  when the row is in it, else the row alone (the selection is not changed);
  the list's empty area gets an empty set. The preview of
  `contextMenu(menuItems:preview:)` is not shown.
- **Window toolbars.** `toolbar { }` outside navigation containers goes to a
  38-point bar under the menu bar: leading placements (`navigation`,
  `topBarLeading`, `cancellationAction`) at the start, `principal` and
  `status` centred in the window, the others at the end in declaration order,
  `bottomBar` items in a bar at the bottom; `ToolbarItemGroup`;
  `ToolbarSpacer` flexible (pushes what follows to the end of its side) or
  fixed (12 points; also in navigation bars); `toolbar(id:)` without
  customisation; `toolbar(.hidden, for: .windowToolbar)` and View > Hide
  Toolbar. Inside navigation containers items stay in the page's bar (R9).
- **Settings.** A `Settings` scene does not open at launch; Settings…
  (Ctrl+,), `openSettings()` and `SettingsLink` open it, or raise it when
  open. The window is titled "Settings", takes its content's ideal size (at
  least 360 × 200; `defaultSize` overrides) and is not resizable.
- **Windows.** `Window` scenes are unique (a second open raises the first);
  `dismissWindow()` without an ID closes the window it is called from.

### QA leftover of R8: the overlapping "Syncing…" row (fixed in R9)

In R8's dark screenshot on the Thor the Status section's "Sync" row showed a
second text, "Syncing…", over its label. Neither `ProgressView`'s label nor
its `currentValueLabel` was at fault: the script had shown `HStack {
ProgressView(); Text("Syncing…") }` and then replaced it (without animation)
by `ProgressView("Sync", value:total:)`. The removed row became a *removal
ghost* because a removal waited for every active animation in the removed
subtree — and the spinner's rotation repeats forever, so the ghost was drawn
for ever. Now a removed view stays only while the removal animations started
by that removal run (a transition or the default fade); without them it is
torn down at once (`ContainerInteractionTests.removedSpinnerRowDoesNotStayOnScreen`
reproduces the case: it fails with the old rule and passes now).

### Shell gaps and editor support design (R13; PARITY §5.8, §5.9)

The Linux IDE shell (`ycode/Sources/ycode-ide`, milestone L1) listed what
OpenViews lacked; R13 closes those gaps and adds what EditorKit (L2) needs.
Behaviour follows Apple's public SwiftUI documentation; the rest is Ycode's
design, stated here.

- **Custom toolbar content.** `ToolbarContent` has a `body`
  (`@ToolbarContentBuilder`), like `View`; the built-in items are primitive
  (`Body == Never`), and `CustomizableToolbarContent` is accepted (no
  customisation). Builders take `if` without `else` (an existential
  `buildOptional`; also in `CommandsBuilder`). In the window toolbar a
  `Label` shows its icon only and keeps its title as the accessibility
  label (desktop toolbars), and `help` gives the button a tooltip.
- **Submenus in `commands`.** In the window's commands host (never laid
  out) a `Menu` builds its items as well as its row, so the keyboard
  shortcuts of a submenu's buttons (at any depth) work before the menu has
  been opened; disabled items stay disabled.
- **`task(id:)` and focus.** `task(id:)` already ran on a view that appears
  in the update that changes the ID; what failed in the shell was the task
  setting a `@FocusState`: a write that no body had read scheduled no
  update, so the focus system never applied it. A `FocusState` write now
  schedules an update.
- **Outline rows.** In a list, a `ForEach` whose rows are a
  `DisclosureGroup` or a leaf view gives its element ID to the first row
  the element produces (the leaf, or the group's label), so leaves and
  folders are selectable without tags and are `scrollTo` targets; a
  section's ID is not passed on. `outlineInitialExpansion(_:)` (OpenViews'
  own API; SwiftUI has none) names the outline rows (`OutlineGroup`,
  `List(children:)`, binding-less `DisclosureGroup`s in a `ForEach`) that
  start expanded, by element ID; the user's later choice wins.
- **Identifiers in list rows.** A combined accessibility element (a list
  row, a button) takes the first identifier set inside it, so
  `accessibilityIdentifier` on a row's content names the row in the tree
  and in the AT-SPI export.
- **Tooltips** (`help(_:)`): the text is the view's accessibility hint and,
  after the pointer rests 0.8 s on the view, a small box under the pointer
  (kept inside the window, above the pointer when there is no room below),
  drawn in the window over everything and taking no input. Leaving hides
  it, and a tip shows at once on the next view with help within 0.5 s;
  pressing a button or a key hides it.
- **Split views without the toggle.** `toolbar(removing: .sidebarToggle)`
  (`ToolbarDefaultItemKind`) leaves out the split view's sidebar button. A
  column of a desktop split view whose bar would be empty (no title, items
  or back button) shows no bar, so the window toolbar is the only bar, as on
  desktop systems. (The page decides nothing from its toolbar: the bar view
  does, so that a toolbar registration cannot re-evaluate the page that
  registered it.)
- **File dialogs.** `fileImporter` (one or several files, `onCancellation`)
  and `fileExporter` (a `FileDocument`, `defaultFilename`) present
  OpenViews' own dialog as a sheet: Back to the enclosing folder, the
  folder's path, the entries by name (hidden files left out; entries that
  are not allowed dimmed), a "Go to" field that takes a path (a folder
  opens, an allowed file is chosen), Cancel (Escape) and the confirm button
  (Return). Double-clicking a folder opens it; a folder whose extension is
  one of the allowed types (a package type, such as a project bundle) is
  chosen like a file; with `.folder` allowed, confirming with nothing
  selected chooses the shown folder. The exporter has a name field (the
  type's extension added) and asks before replacing a file.
  `fileDialogDefaultDirectory`, `fileDialogMessage` and
  `fileDialogConfirmationLabel` are honoured. `UTType` is OpenViews' own
  registry of the public types (identifiers, extensions, conformance) plus
  dynamic types for other extensions and `exportedAs`/`importedAs`
  declarations; corelibs Foundation has no `FileWrapper`, so OpenViews
  defines one on Linux (regular files and folders). The XDG Desktop Portal's
  file chooser is not used (deferred).
- **Symbols.** `chevron.left.forwardslash.chevron.right`,
  `folder.badge.gearshape`, `square.stack.3d.up(.fill)`, `sidebar.right`
  (and `.leading`/`.trailing`), `gearshape.2(.fill)`,
  `list.bullet.rectangle`, `list.bullet`, `tablecells`: Ycode's drawings.
- **`hammer` redrawn** (for the build bezel's 80–120-point glyph): a claw
  hammer outline — a striking face, a head, a claw curving to a point and a
  tapered handle with a rounded end — turned 45° (the handle to the lower
  left), stroked, and filled for `hammer.fill`; Ycode's own geometry.
- **Monospace.** Noto Sans Mono (bundled) is the monospaced design's face.
- **`onKeyPress`** (key, key set, characters, any key; phases down, repeat
  and up): handlers get the window's keys while their view or a view inside
  it has focus, from the focused view outwards (its own modifier chain
  first), before the focused control, menu shortcuts and Tab; `.handled`
  ends delivery and drops the text event a handled character key would have
  typed. Ctrl reads as `.command` (OpenViews' shortcut rule), Ctrl+Super as
  `[.command, .control]`, Alt as `.option`; `characters` has Shift applied.
- **Scroll geometry and text drawing for EditorKit.**
  `onScrollGeometryChange` (R9) reports the visible rectangle every frame;
  `GraphicsContext.draw(_ text:)` draws resolved text runs. The default
  `.foreground` shading of a resolved text recursed forever; it now keeps
  the environment's style. A viewport-sized `Canvas` at the scroll offset,
  drawing only the visible lines, is the pattern `ov-editor-bench` measures.
- **Glyph run cache** (`SoftwareRasterizer`). A glyph run in a solid colour
  under a translation and uniform scale that the rasteriser has seen in an
  earlier frame is drawn once into an image (the same outlines under the
  same device transform, moved by whole pixels, so the coverage is the
  same) and then placed as a ThorVG picture at whole pixels; images are
  keyed by the run's glyphs, relative positions (1/64 pixel), size,
  colour, shear and sub-pixel phase, and the least recently used go past
  48 MB. First sightings are drawn as shapes (a page jump shows only new
  lines). The images match the shape rendering exactly at scale 2 and to
  within a few edge pixels at scale 1 (`EditorSupportTests`). Clearing the
  frame fills 32-bit words.
- **Measured** (`ov-editor-bench`, release, 10 000 unique lines in a
  1400 × 900-point window, a 37-point wheel step per 60 Hz frame, headless
  back end with the window's software presenter): x86-64 workstation 6.2 ms
  per frame at scale 1 (p95 8.0) and 12.5 ms at scale 2 (p95 16.9), against
  24.4 and 50.9 ms before the cache; jumping three screens a frame (only new
  lines) costs 31 and 64 ms. The Thor's numbers are in `docs/PARITY.md`
  §5.8.
- **`Table`** with `TableColumn`s (title and `value:` key path, or custom
  cells; sortable when the column has a `KeyPathComparator`), `width(_:)`
  and `width(min:ideal:max:)`, single or multiple selection and a
  `sortOrder` binding. As documented, the table does not sort its data: a
  header click puts that column's comparator first (or reverses it when it
  is first already) and the app sorts. Ycode's look: a 28-point header with
  the first sort column's chevron and dividers, 24-point rows with
  alternating backgrounds; fixed widths are kept and the other columns
  share the rest within their limits (minimum 40); dragging a header
  divider resizes the column on its left, and the last flexible column
  takes up the difference. Rows are a `List`'s, so selection, keyboard and
  lazy materialisation are the list's.
- **Two fixes found on the way.** The split view's sidebar toggle held a new
  closure each time, so its toolbar registered again on every pass and
  re-evaluated the column's bar until the 64-pass limit (2048 passes in 31
  frames on desktop hosts); it now holds the split view's controller. A
  multi-tap gesture waiting for its next press (a list row's double click)
  swallowed a press on other views (a button clicked at once after a row);
  such a press now ends the waiting gesture.

### Desktop polish (Ycode beta 2)

What the Linux IDE's polish pass needed (`Tests/OpenViewsTests/R13/DesktopPolishTests.swift`):

- **Clipboard for views.** `OpenViewsClipboard` (OpenViews only, not
  SwiftUI API; `App/Clipboard.swift`): `string`, `hasString` and
  `copy(_:)` on the running app's back end clipboard, the one text fields
  use (SDL's on a desktop). With no app running it keeps the text in
  memory.
- **Ctrl+Y.** A text field redoes on Ctrl+Y only when no enabled shortcut of
  the window takes the keystroke (`ShortcutRegistry.hasEnabledShortcut`):
  an app that maps ⌘Y to a command gets it. Ctrl+Shift+Z always redoes.
- **Pop-ups inside the window.** A pop-up (menu, picker list, context menu,
  popover) is placed in its main window's bounds (`PopupPlacement`): below
  its button when it fits, otherwise above it (the same gap away), otherwise
  as far up as it must go; a submenu that does not fit on its row's
  trailing side opens on the leading side; never past the left or top edge.
  `PopupPresenting` takes the opening view's frame (`anchor`).
- **`preferredColorScheme(_:)`.** A preference the window applies to its
  root environment: the in-window menu bar, the toolbar, presentations and
  the pop-ups the window opens follow it; nil returns to the desktop's
  scheme, and desktop changes keep a requested scheme.
- **`.columns` forms.** `formStyle(.columns)` is the desktop settings form
  (the macOS IDE's Settings panes, `specs/ide/metrics.md` §8): no groups;
  20 points from the top and bottom, 28 from the sides; bold 12-point
  headings; rows 10 apart; a control's label right-aligned in a 200-point
  column (wrapping inside it), the control 8 points after it; a checkbox
  after the empty column with its title; a menu picker as a pop-up button
  (the choice and up/down chevrons on a filled bezel); a stepper as the
  desktop's small one (up over down, 15 × 22); footers in 11-point
  secondary text. `.grouped` (and `.automatic`) keep the grouped look.
- **Symbol.** `list.bullet.indent`: a type's badge with two members under
  a tree line (the Linux IDE's Symbol navigator).

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
  Bounds-checked reads. Since R5 also TrueType outlines (`glyf`/`loca`).
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

### Rendering design (R5)

`09-open-design.md` §3.5–§3.6; sources in `Sources/OVRender/` and
`Sources/SwiftUICore/Render/`.

- **Display list** (`OVRender/DisplayList.swift`): an ordered tree of items
  — fill and stroke of a path (paint: colour, linear, radial or conic
  gradient), glyph run (glyph IDs and positions of one face and size,
  outlines supplied by a `GlyphOutlineSource`), image (PNG, JPEG or pixels
  in a rectangle, with interpolation and opacity), group (transform,
  opacity, blend mode, clips — paths, inverse paths or stroke outlines —,
  an alpha-mask list, effects: blur and shadow, and a layer hint), and
  placeholders for host views. Items carry `DisplayItemID`s: the view-graph
  node that created the layout node (stable while the view lives), the
  node's creator index, the item's index in the node's drawing.
  `DisplayListDiff` matches items by ID and returns damage (added, removed,
  moved or changed items; groups whose own attributes changed as a whole).
- **Lowering** (`SwiftUICore/Render/DisplayListBuilder.swift`): after
  layout, `ViewGraph.displayList()` walks the tree like
  `presentedLayers()` (presented frames and effect values of R6, removed
  views still transitioning out). A layout node draws itself first
  (`LayoutNode.draw`: shapes, colours, text, images, canvases), then its
  children (a background before its base); render effects
  (`LayoutNode.renderEffects`, `OpacityBehavior`, `ClipBehavior`, child
  transforms) wrap the result in a group; groups that would only translate
  are dissolved, so lists stay flat. Right-to-left layouts are drawn
  mirrored at the root, and text, images, symbols and canvases are flipped
  back about their own centre (positions mirror, glyphs do not).
- **Shapes and styles**: `Path` (all building, arc and transform members,
  `trimmedPath`, `contains`, `boundingRect`), `Shape` (requirements
  `nonisolated`, so user shapes need no annotations), the built-in shapes
  (continuous corners are Ycode's own curve, see 09 §3.6), `InsettableShape`,
  `fill`/`stroke`/`strokeBorder`/`trim`/`offset`/`scale`/`rotation`/
  `transform`, `AnyShape`; `ShapeStyle` (colours, `Color.Resolved`, the four
  gradients, `.foreground`, the hierarchical levels, `.tint`, `.background`,
  `opacity`), `foregroundStyle`/`foregroundColor`/`tint` in the environment;
  `CGAffineTransform`, `CGLineCap` and `CGLineJoin` are defined on Linux (not
  in swift-corelibs-foundation).
- **Modifiers**: `clipShape`, `clipped`, `cornerRadius`, `mask`,
  `blendMode`, `compositingGroup`, `drawingGroup` (a compositor layer),
  `shadow`, `blur`, `colorMultiply` (applied to the paints of shapes and
  text), `hidden`, `background`/`overlay` with a style (and `in:` a shape),
  `border`; `opacity`, `offset`, `scaleEffect`, `rotationEffect` from R6.
- **Text**: OVText now reads TrueType outlines (`glyf`/`loca`, simple and
  composite glyphs, `Outlines.swift`); a text draws one glyph run per
  stretch of clusters that share face, size, baseline offset and colour,
  at the positions of `TypesetTextMeasurer.placedLayout`, with the
  ellipsis glyph where lines were truncated. Run colours come from
  `Text.foregroundColor`, otherwise the foreground style; italic without an
  italic face is sheared by 0.2.
- **Images**: `Image(_:bundle:)` looks up registered images, then
  `name.png`/`@2x`/`@3x` and JPEG files in the bundle's resources, then asset
  catalogs (`*.xcassets/**/name.imageset/Contents.json`, the scale closest to
  the display scale, larger preferred); natural size = pixels / scale.
  `resizable`, `interpolation`, `renderingMode(.template)` (the image's alpha
  filled with the foreground style). PNG and JPEG pixels are decoded by
  ThorVG's loaders, once per image.
- **Symbols** (`Image(systemName:)`): `OpenSymbolProvider` with Ycode's own
  artwork (`SymbolArtwork.all`: 73 names, geometric outlines on a 24 × 24
  grid, filled variants with knock-outs). Each symbol has a body-size box;
  sizes scale with the point size and weight, `imageScale` factors and the
  natural (resizable) size come from the star.fill measurements of 07 §3.
  Boxes of the measured symbols (star, heart, trash, gear,
  person.crop.circle, square.and.arrow.up, iphone, cloud.sun.rain.fill,
  rectangle.portrait.and.arrow.right) are the reference's; the rest use
  20.67 × 20.67. Unknown names draw a visible placeholder (a rounded square
  with a question mark) in the default box; `missingSymbolsLayOutEmpty`
  gives the reference's 0 × 0 instead (the golden tests use it).
- **Canvas** and **GraphicsContext**: fill, stroke, images, text (resolved
  or not), clip (also inverse), transforms, opacity, blend mode, filters
  (blur, shadow, colour multiply; the others are accepted and ignored),
  `drawLayer`; recorded as display items.
- **Rasteriser** (`SoftwareRasterizer`): display list → ThorVG scene graph
  (shapes, gradients with stops and spread, pictures loaded from decoded
  pixels, scenes with transform, opacity, clips, masks, blend methods and
  scene effects) → premultiplied RGBA8, optionally limited to a damage
  rectangle (viewport). ThorVG runs without worker threads, so output is
  deterministic.
- **Headless back end**: `HeadlessRenderer.render(view, size:scale:)` (a
  window-layout graph rasterised on the CPU) and the public
  `ImageRenderer` (`pngData`, a Ycode addition since Linux has no
  `CGImage`; `render(rasterizationScale:renderer:)` draws into a
  `GraphicsContext`). `PNGCodec` encodes PNG (our DEFLATE: fixed Huffman
  codes, hash-chain LZ77, per-row filter choice).
- **Compositors** (`OVRender/MakeCompositor.swift`, `COVVulkan`): the
  surface interface (`RenderSurface`, `SurfacePresentation`,
  `VulkanSurfaceProvider`, `SoftwareSurfaceProvider`) and
  `makeCompositor(for:preference:)`. The software compositor keeps one
  image and redraws only the damage. The Vulkan compositor (Vulkan 1.3,
  dynamic rendering, `libvulkan` loaded at run time) keeps a layer tree:
  top-level `drawingGroup` layers are rasterised once in their own
  coordinates and composited with their transform and opacity; the runs of
  items between them are full-surface layers redrawn and re-uploaded only
  where damaged. Targets: a FIFO swapchain on the host's `VkSurfaceKHR`, or
  an offscreen image; both read back. Frames complete synchronously.

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
| Layout cases run | 108 of 138 | all pass: 97 fully, 11 with some checks skipped |
| Checks in those cases | 927 | 885 pass, 42 skipped, 0 fail |
| — of which R4's 32 text cases (`text.*`, `font.*`, `dyn.*`) | 250 | 234 pass, 16 skipped (where `longText` wraps or is truncated) |
| — of which R5's 4 symbol cases (`image.symbol`, `.scaleSmall`, `.scaleLarge`, `.wide`) | 28 | 28 pass (Ycode's symbol provider) |
| — of which the 72 earlier cases | 649 | 623 pass, 26 skipped (wrapping of unmeasured text: `longText`, grid cells, `hstack.flex`) |
| Cases disabled | 30 | `image.symbol.largeTitle` (R5, see open questions), the 21 control rows (R8: built from views only, below), scroll views, lists, forms, navigation, tabs (R9) |
| Spacing matrix | 64 | all pass (R8: pairs with a button, toggle or text field are built from views) |
| Same 108 cases built from views | 108 | identical: 885 checks pass, 42 skipped, 0 fail |
| R8 control rows built from views (T-CTL sizes) | 21 | all pass: 151 checks, 0 skipped (`label`, the seven `button.*`, `toggle`, `toggle.labelsHidden`, `slider`, `stepper`, `progress.spinner`, `progress.linear`, `picker.segmented` with baselines, `textfield.plain`/`.rounded` with baselines, `secureField`, `datePicker.compact`, `gauge` with baselines, `link`) |

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

R10 and R11 tests (`Tests/OpenViewsTests/R10/`, `R11/`, 38 tests; all
pass on macOS, Linux x86-64 and the Thor):

| Suite | Spec | Checks |
|---|---|---|
| T-ENV | 08 §1, §1.1 | the defaults table at the root of a fresh environment and of the headless host; dark mode re-renders only the views that read `colorScheme`; accessibility-large (AX2) gives `.accessibility2`, list rows of 59 and larger text; increased contrast, reduce motion; an Arabic locale lays out right to left; back to the defaults; adaptive colours re-rendered; settings-file text, environment variables, text-scale mapping, POSIX locales; the portal's `ReadAll` reply and `SettingChanged` signal text; a settings file written twice is seen twice without polling |
| T-AX | 08 §2 | the `a11y` screen: Heading (header + static text), Save (button, hint), Favorite (image, the symbol's label), Delete (image), the decorative image absent, Wi-Fi (button + toggle, value 1), the slider (30 %, adjustable), the stepper, "Combined, children" (static text), the hidden text absent, Identified (identifier), Link (link), the text field (value "typed"), the progress view (40 %, updates frequently); roles, frames and actions (default, increment); `.ignore` with label and value, `.contain` with sort priorities, labels read by their title, default symbol labels, named actions; list rows with the selected trait; the menu bar and toolbar as elements, a menu opened through its element; announcements |
| T-ATSPI (OV-ATSPI) | D-Bus Specification 0.43; at-spi2-core `xml/` | the D-Bus wire format against the specification's examples and in round trips of every type in both byte orders; signatures, names, messages, addresses, the EXTERNAL line; the role and state table and the requests on a probe screen; over a private bus: our client's calls, replies, errors, signals, introspection and properties, the exporter's registration, laziness, tree, Cache, actions and events (focus, text, state, value, children, window) |
| T-PERSIST | 06 §8 | an `@AppStorage` launch counter round trip; writes through `UserDefaults` directly update the view and fire `onChange`; `RawRepresentable` and optional values, removal; the change notification alone; `@SceneStorage` shared in a window, kept across removal and re-insertion, separate per window; an archive restored after an end without a quit and discarded after a user quit |
| Commands | ours | menu titles in order and the content below the 26-point bar; File's groups and shortcut texts, `CommandGroup(after:)`, a replaced Help group; the app menu; Ctrl+B disabled until a focused value is published, Ctrl+R reading a scene value; submenus of command menus; F10, Left/Right, Down + Return; hover switching between open menus; a view's shortcut before a command's; Edit Copy, Undo, Select All, Cut, Paste on a focused field; Settings once, its size and title; New Window, the Window menu, a `Window` scene, Close Window, Minimize; Quit; Show/Hide Sidebar on a split view; shortcut texts; a host without a menu bar keeps command shortcuts |
| Context menus and toolbars | ours | a secondary click opens the innermost view's menu at the pointer; a long touch press opens it and the button under it does not fire; moving cancels; Shift+F10; list selection menus (the selection, or the row alone); window toolbar placements (leading, centred principal, trailing group after a fixed spacer, bottom bar), a toolbar button, View > Hide Toolbar; toolbars inside navigation stay in the page bar |

R9 tests (`Tests/OpenViewsTests/R9/`, 29 tests, plus the golden
`scrollView` and `scrollView.horizontal` rows built from views; all pass on
macOS, Linux x86-64 and the Thor):

| Suite | Spec | Checks |
|---|---|---|
| T-LIST | 06 §3 | in the reference's window (466 × 678, safe area 382 × 644): a `LazyVStack` of 1 000 rows (40 + 8) creates rows 0–14 and reports content 382 × 47 992, container 382 × 644, bottom inset 34 at once; a `VStack` in a scroll view creates all 300 rows; a `List` of 1 000 rows creates rows 0–12, `scrollTo(500, anchor: .top)` jumps (no animation) to 26 013.33, creating rows 500–513 and removing 0–12; a lazy grid of three columns creates 15 rows of cells, a `LazyHGrid` 8 columns; a 305-point fling in 160 ms decelerates by 0.967 ± 0.006 per frame and rests after 1.5–3 s; wheel notches |
| T-NAV | 06 §2.1 | the `nav` sequence: push [1], [1, 2], [1, 2, 3] (destination `onAppear` at once, the covered page's `onDisappear` after 0.5 s, nothing at 0.45 s), pop to [1, 2] and to [] (page below at the start, popped page at the end, covered pages silent), push [4, 5] (both appear) and pop ([4] at once, 5 at the end); the root at −30 % × progress mid-push, the bar's 82 points; back swipe (page below appears at the start, the top page follows the finger, a release past half pops and writes the path); `NavigationLink(value:)` and the back button |
| T-MODAL | 06 §6 | sheet frames (8, 280, 374, 356) at `.medium` and (8, 8, 374, 636) after the detent binding changes; `onAppear` at the start, `onDismiss` then `onDisappear` 0.5 s after `isPresented = false`; idle afterwards; `dismiss` inside the sheet; a full-screen cover's content frame (0, 0, 382, 644); alert width 270, a button runs and dismisses; presses below a presentation are not delivered; a popover opens and closes a pop-up window with its binding; presentations take the presenter's colour scheme |
| Containers | ours; 06 §2.2–2.3 | list click, Shift-click range, Ctrl-click toggle, Down/Shift-Down/Home, End scrolls the row into view; outline chevron, Right (expand, first child), Left (parent, collapse); `DisclosureGroup` outside a list; tabs built on selection, `onAppear` of the new tab before `onDisappear` of the old, content under the floating bar; a compact `NavigationSplitView` collapses (sidebar first, selection pushes the detail — detail `onAppear` at once, sidebar `onDisappear` at the end —, nil pops, back clears the selection); a regular one has 240/280-point columns and a draggable divider; `HSplitView` limits; the R8 QA case (removed spinner row) |

R8 tests (`Tests/OpenViewsTests/R8/`, 35 tests, plus the 21 control rows and
39 spacing pairs of the generated golden suites; all pass on macOS, Linux
x86-64 and the Thor):

| Suite | Spec | Checks |
|---|---|---|
| T-CTL sizes | golden-layout.md | the 21 control rows at all 7 proposals (with baselines where measured), built from views with the reference test font; the spacing matrix with buttons, toggles and text fields |
| T-CTL interaction | 06 §4 | toggle tap on the switch flips and animates, a label tap does not; slider track taps do nothing, a thumb drag moves by steps; stepper "+" adds 1 within bounds; segmented picker; buttons act on release inside only, disabled ones never; a custom `ButtonStyle` sees `isPressed`; Tab order, Space/Return/arrows |
| Pop-ups | ours | a menu picker opens a pop-up window placed below it, a row chooses and closes it; Escape, a press outside (not delivered), keyboard choice; a submenu chain closes as a whole; refused pop-up windows become overlays |
| Text editing | ours | click, Ctrl+Shift+Left, typing over a selection, undo/redo, double-click word, cut/paste; drag and shift-click selection; caret blink and rest; secure fields; editor Return, Up/Down, Tab |
| Editing model | ours | insertion, collapse and extension, word movement and ranges, paragraph and vertical moves, deletions, undo coalescing, paste filtering, marked text, external changes, layout geometry (carets, hit testing, selection rectangles, soft wraps, trailing newline) |
| Forms, overloads, QA | 06 §4; QA B1–B4 | row insets; `background(Color)` picks the shape-style form; source compatibility of B3; 60 presented frames/s for a running animation; borders and strokes let taps through; duplicate clicks dropped |

R7 tests (`Tests/OpenViewsTests/R7/`, 39 tests, all pass on macOS, Linux
x86-64 and the Thor — the SDL test on Linux only; headless hosts on the
virtual clock unless noted):

| Suite | Spec | Checks |
|---|---|---|
| T-GEST | 06 §7 | tap on touch-up, not on movement; double tap 120 ms apart fires only the double-tap action, a single tap fires after the double tap gives up; long press: pressing true at touch-down, action at 0.5 s while down, pressing false at touch-up, early release; drag: first `onChanged` at the minimum distance, `startLocation`, velocity 360 pt/s for a 60 Hz stream, `predictedEndTranslation` = translation + 0.25 × velocity, minimum distance 0; tap + simultaneous drag: the drag ends, the tap does not fire; inner over outer, `highPriorityGesture`; `@GestureState` updates and reset; long press sequenced before drag; exclusive gestures; masks, `allowsHitTesting`, disabled views, `contentShape`; `Button` acts on release inside only; hover enter/positions/exit; scroll wheel |
| T-LIFE | 06 §1 | launch order (App.init → didFinishLaunching in the background → App.body ×2 → willEnterForeground → root body, child and root `onAppear` → App, then view → didBecomeActive); inactive/background/foreground sequences with delegate callbacks; minimise/restore; `openURL` with the reference's confirmation order and without; quit; `openWindow`/`dismissWindow`, `Window` uniqueness, closing the last window quits; resize relayout; AppKit-style adaptor |
| Focus and keyboard | 06 §5 | programmatic focus and platform text input on; tap, type "hi" → "Hi" (reference capitalisation), Return → `onSubmit` then focus nil; desktop `.never`; editing keys, Tab/Shift-Tab, Escape; paste/copy; IME marked text and commit; shortcuts (Ctrl+S, disabled button, plain "s" typed into a field); shortcut matching table |
| Platform | 09 §4 | idle app renders no frames and wakes once per wait; a 0.5 s animation renders at 60 Hz; display-link grid and restart; headless event timing; PNG writer; frames presented through R5's renderer (pixel probes, readback); SDL back end (`OV_TEST_SDL=1`, under Xvfb and a headless Wayland compositor): window, present + readback, synthetic mouse and key events through SDL's queue, clipboard (X11) |

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

R5 tests (`Tests/OpenViewsTests/R5/`, 37 tests; T-IMG of `10-plan.md`
§3.2). Rendered headlessly at scale 2; colours are the 07 §4 values;
tolerance ±2 per channel unless stated:

| Suite | Spec | Checks |
|---|---|---|
| Colours and shapes | 04 §2, 07 §4 | a colour fills exactly its frame (pixel-exact edges; light and dark values); circle, rounded rectangle, capsule, triangle (a user shape), circle in a non-square frame; a bare shape fills with the foreground style; centred strokes, `strokeBorder`, dashes; `trim` |
| Gradients | — | linear ends, middle and quarter (sRGB interpolation, ±3); radial centre, outside and halfway (±8); angular sweep clockwise from +x (±30, hue positions) |
| Compositing, clipping, transforms | 04 §5 | colour opacity and `.opacity` over white; `hidden`; multiply blending; background below and overlay above; `border`; `clipShape`, `clipped` (and unclipped overflow), `cornerRadius`; `mask` (shape and half-transparent); `offset`, `rotationEffect` 90°, `scaleEffect` 2; shadow below, blur spreading; `colorMultiply` |
| Images, text, symbols, canvas | 07 §3 | PNG natural size and nearest-neighbour stretch (exact colours), JPEG (±12), template rendering, a registered named image at scale 0.5; text ink inside its frame only, in its colour; symbol ink within the body box, the missing-symbol placeholder and the reference-parity 0 × 0, symbol tint; symbol sizes (body, natural, wide, heart; imageScale factors); `Canvas` fills, transforms, strokes, clips and layers; `ImageRenderer.pngData` size and colour; right-to-left positions mirror, glyphs do not |
| Golden scenes | — | `img.shapes`, `img.gradients`, `img.composite` (shapes, gradients, an image, text and clipping) and `img.composite.dark` against `R5/Goldens/*.png` (±3 per channel, ≤ 0.2 % of values beyond) |
| Display list and compositors | 09 §3.5–§3.6 | stable IDs across updates and one damaged rectangle for a colour change; damage of moved, added, removed and faded items; software compositor: damage-only redraws equal full renders; Vulkan compositor offscreen: the composite scene equals the CPU rasteriser (no channel off by more than 2) and the golden, a `drawingGroup` layer moved and faded without re-rasterising, target resize |

Results per machine (2026-10-30):

| Machine | `swift build && swift test` | Vulkan |
|---|---|---|
| macOS 27.2, arm64 | 604 tests: 535 pass, 69 disabled, 0 fail | no loader: the 3 Vulkan cases return early (CPU paths are tested) |
| Linux x86-64 (Ubuntu 26.04) | same | NVIDIA GeForce RTX 4060 Ti and lavapipe (`OV_VULKAN_DEVICE=llvmpipe`, llvmpipe LLVM 21.1.8): all pass with `OV_REQUIRE_VULKAN=1` |
| Linux arm64 (the Thor, Ubuntu 24.04) | same | NVIDIA Tegra Thor: all pass with `OV_REQUIRE_VULKAN=1` |

The golden PNGs were written on macOS and pass unchanged on both Linux
machines (CPU rasteriser and Vulkan read-back).

Whole package after OV-ATSPI: **787 tests, 0 failures on macOS (arm64),
Linux x86-64 and the Thor (arm64)**, with the same 3 known issues (the
D-Bus live tests ran on all three: the Mac has a `dbus-daemon` too).
Whole package after R10 and R11: **765 tests, 0 failures on macOS (arm64),
Linux x86-64 and the Thor (arm64)**, with the 3 known issues of
`settlingDuration`. After R9: 727 tests;
the SDL back-end test passes with `OV_TEST_SDL=1` under Xvfb (x86). After R8:
699 tests; before R8: 643 tests, 0 failures on all three machines each time.
Disabled tests are later rounds' golden rows (lists, forms, navigation and
tabs are informative only), the rows checked built from views, and
machine-dependent R5 cases; the SDL back-end test runs on Linux with
`OV_TEST_SDL=1` and a display.

The R11 sample (`ov-mini-ide` with the menu bar, toolbar, context menu
and Settings window) on the done-criterion hosts (2026-10-30):

- x86-64 under Xvfb (SDL X11, Vulkan compositor on the RTX 4060 Ti): the
  script (SDL's queue) in light and dark — R9's steps, then File > New File…
  with the pointer, Ctrl+B, Ctrl+Shift+N, the toolbar's Run, Ctrl+S refused
  without and run with the editor focused (a focused value), Edit > Select
  All and Copy (the clipboard holds the file), F10 → Right → Right (Edit
  open), a secondary click on an outline row and its Open item, Ctrl+, (a
  440 × 300 Settings window) and its line-number switch (`@AppStorage`
  written, the editor follows), then R9's sheet and alert; and with real X11
  input from `xdotool` in light and dark: the same menu, shortcut, toolbar,
  keyboard-menu, context-menu and Settings steps; final state `builds=1
  runs=1 saves=1 newFiles=2`, App.swift opened from the context menu, the
  Settings window found by its title.
- R10 live settings on X11: a settings file switched to dark while the app
  ran (inotify; the window re-rendered dark); on a private session bus with a
  stand-in portal (`Scripts/fake_portal.py`, run under `dbus-run-session`):
  `ReadAll` at start, then `SettingChanged` to dark and a 1.3 text scale
  (xxLarge) arrived live. The workstation's own desktop portal did not answer
  from the SSH session; on the Thor the session's portal answered `ReadAll`
  (settings sources `posix-locale`, `portal`; read only, nothing changed).
- The Thor under a headless Weston (SDL Wayland, software compositor): the
  script in light and dark, every step as on x86 except the clipboard, which
  stays empty under the headless compositor (no seat; SDL's Wayland
  clipboard needs one).

Screenshots `.claude/worktrees/ov-r11-*.png` of the repository checkout (not
committed): menus, the keyboard-opened Edit menu, the context menu, the
Settings window, the sheet, the alert, light and dark, from both machines,
and the live-settings pairs.

The R9 sample (`ov-mini-ide`) on the done-criterion hosts (2026-10-30):
x86-64 under Xvfb (SDL X11, presented by the Vulkan compositor on the RTX
4060 Ti), driven once by its own script (SDL's queue) and twice with real X11
input from `xdotool` (light and dark: expand two folders with their chevrons,
select a file, Up/Left/Left/Right/Right/Down in the outline, ten wheel
notches over the console (offset 100), a drag fling (to 964), the
editor/console divider dragged up 100 points (318/318 → 218/418), the sheet
opened with "Build…" and closed with "Done", the alert opened with "Delete"
and confirmed); the Thor under a headless Weston (SDL Wayland, software
compositor), driven by the script in light and dark. Every step's state
matched; screenshots `.claude/worktrees/ov-r9-*.png` of the repository
checkout (not committed).

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

### R7

- **Thresholds.** A tap fails when the press moves more than 10 pt; taps of
  a multi-tap follow within 0.35 s and 40 pt of the first; a button press
  fails when the pointer leaves its frame by more than 10 pt; drag velocity
  is measured over the last 0.1 s of samples (06 §7 gives magnitudes only;
  the 120 ms double tap and the 10 pt drag minimum are the spec's).
- **Arbitration.** First to activate or end wins; only a multi-tap waiting for
  its next tap holds back lower-priority gestures (that is what makes a
  single tap wait for a double tap on the same view, 06 §7).
- **Provisional values.** A long press reports "pressing" (its `updating` /
  `onChanged` value `true`) from touch-down, before it is recognized;
  `onChanged` is not called with the final value (`onEnded` gets it).
- **Sequences.** The second gesture starts where the pointer is when the
  first ends; if it then fails, the sequence ends with `.second(first, nil)`.
- **Focus.** Programmatic focus applies in the next update (the reference
  took 0.5 s); Return submits before focus is removed (`focused` is still
  true inside `onSubmit`); Escape removes focus.
- **Capitalisation.** The headless host capitalises sentences, as the
  reference device did; the Linux desktop host does not (desktop fields).
- **Linux scene phases.** Application and windows share one phase: shown →
  active; all windows minimised or hidden → inactive → background; restored →
  inactive → active; keyboard focus does not change it. Closing the last
  window quits; quitting goes through inactive and background, then
  `willTerminate`. URLs arrive without a confirmation prompt
  (`openURL(_:confirming: true)` reproduces the reference's order).
- **Keyboard shortcuts on Linux.** `.command` matches Ctrl or Super;
  `.control` matches Ctrl only.
- **Delegate classes on Linux** need `init()` to be `required` (be `final`),
  because swift-corelibs-foundation's `NSObject.init()` is not.
- **Wheel steps** scroll 10 pt per notch.

### R10

- **Settings precedence**: environment variables over the settings file over
  the portal and SDL's theme over the defaults; the locale from the POSIX
  variables; text scales to Dynamic Type sizes by fixed thresholds.
- **List rows** are 59 points from accessibility2 up (the measured AX2
  value), 52 below.
- **External defaults writes** are noticed after every wake of the run loop
  (corelibs posts no change notification).
- **Scene storage** is archived at background, discarded on a user's close or
  quit, restored when an archive exists at launch.
- **Accessibility**: the modifier nearest the view wins; attributes of a
  modifier that is not an element apply to the elements its content makes;
  `.combine` joins labels and values with ", " (08 §2) and unites traits;
  controls are combined elements with their own role; a stepper is an
  adjustable element (08 §2 found none); a text field has no label; Ycode's
  default labels for its symbols except "star.fill" (the reference's
  "Favorite").

### R11

- **Menu order**: App, File, Edit, View, custom menus, Window, Help; empty
  menus hidden; groups separated by lines.
- **Shortcuts**: views before menu commands; `.command` shown and matched as
  Ctrl; F10 opens the menu bar, Shift+F10 the focused view's context menu.
- **Focused values**: the innermost publication on the focus chain, scene
  values for the rest.
- **Context menus**: secondary click or a 0.5 s touch press within 10 points;
  list menus get the selection when the clicked row is in it.
- **Window toolbars** under the menu bar; principal items centred in the
  window.
- **Settings** at its content's ideal size, not resizable, one window.

### R13

- **Tooltips** after 0.8 s of rest, 0.5 s grace to the next view, under the
  pointer and inside the window.
- **Key presses** from the focused view outwards, before controls and menu
  shortcuts; handled characters are not typed.
- **Outline rows** take their `ForEach` element's ID; folders included.
- **Empty column bars** are not shown in desktop split views.
- **Tables** do not sort; header clicks write the sort order.
- **File dialogs** are sheets in the window; packages of an allowed type are
  chosen like files.

### R9

- **No overscan.** Lazy containers materialise exactly the units that
  overlap the visible region by more than 0.01 point: 13 list rows and 15
  lazy-stack rows in the reference's window (06 §3).
- **Visible region.** A scroll view that touches the safe area shows its
  content under that inset: 678 visible points for a 644-point container
  with a 34-point bottom inset (the 15-row count needs it).
- **List top offset.** The first row of an inset-grouped list sits 13.33
  points down: 06 §3's `scrollTo` offset (26 013.33 = 500 × 52 + 13.33) is
  the row's position, and 13 rows at launch / 14 after `scrollTo` follow.
- **Deceleration.** v(t) = v₀ · 0.998^t(ms), integrated in closed form; a
  fling ends below 10 points/s (≈ 2.4 s from 1 300 points/s, 06 §3's
  ≈ 2.5 s).
- **Covered pages are suspended, not removed**, and pages under the top that
  were never shown keep their appearance (the only rule that gives both
  [4, 5] observations of 06 §2.1).
- **Sheet geometry.** `.large` = (8, 8, W − 8, H − 8) of the safe area;
  `.medium` = half the window height + 17, ending 8 points above the safe
  bottom — the two measured frames, no general rule.
- **Collapsed split view.** A selection in a sidebar list pushes the next
  column; clearing it pops; going back clears it (06 §2.2's three steps).
- **Tabs.** The new tab's `onAppear` runs before the old tab's `onDisappear`
  in the same update (06 §2.3) because suspension queues disappearances
  after appearances, as removals do (03 §2).

### R8

- **Control rows** (inferred from the golden rows): label + 8 + control; the
  label widths the tests use as inputs (`Fixtures.swift`) are the ones these
  rules imply (`On` 22.33, `S` 10.67, `D` 12, …).
- **Segmented titles** use the subheadline style and sit on the pixel grid
  (top rounded down), which gives the measured first baseline 20.67.
- **Text field line box**: pitch = ascent + descent + leading rounded up to
  the pixel grid (22 at body); the text's top is rounded up (baseline
  17.33); a plain secure field is 1 point lower (the measured 21 has no
  rule we could find).
- **Gauge**: a 16-point bar row under the label (46.98 = 20.33 + 10.64 + 16).
- **Label**: icon and title on the first text baseline (20.99 high for star
  and body text).
- **Disfavoured overloads**: the view forms of `background(_:alignment:)` /
  `overlay(_:alignment:)` and the deprecated long-press overload lose to the
  current API, as in the reference.

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
27. (R5) Symbol box sizes per text style: the reference's star.fill at
    `.largeTitle` is 44 × 41.67, the linear rule gives 44 × 41.33 (an
    optical-size step); and the sizes of symbols the spec did not measure.
28. (R5) Whether a missing symbol name should lay out 0 × 0 (the
    reference) or show a placeholder (Ycode's default, see 09 §3.6).
29. (R5) The shadow radius → blur σ mapping (we use σ = radius / 2) and
    `blur(radius:)` (σ = radius / 2): no pixel measurements in the spec.
30. (R5) The geometry of continuous rounded corners and the default
    hierarchical opacities for custom foreground styles (Ycode's choices).
31. (R7) The tap movement tolerance, multi-tap interval and distance, and the
    button's release slop (06 §7 measured a 120 ms double tap only).
32. (R7) Whether `LongPressGesture`'s `onChanged`/`updating` see `true` at
    touch-down, and whether `onChanged` is called with a gesture's final value.
33. (R7) The value of a `SequenceGesture` whose second gesture fails, and where
    the second gesture's start location is.
34. (R7) The order of nested hover handlers, and hover during a press.
35. (R7) The reference's velocity estimator (06 §7: 580–690 pt/s during the
    drag, 437.63 at the end of the same drag).
36. (R8) Control metrics the golden table does not give: the segmented
    title font and its padding, the plain secure field's 21-point height,
    the rounded field's inset split (we use 14 + 14), the gauge's bar row,
    small/mini/extra-large padding, form row and header metrics outside a
    UIKit-hosted list, the menu-picker look in and out of forms.
37. (R8) Text editing behaviour on the reference: double-click word rules,
    selection on focus, undo grouping, caret blink timing.

38. (R9) Container values the probes did not measure (`10-plan.md` §4 q12):
    the push, pop and sheet curves (we use ease-in-out 0.5 s; sheets present
    in 0.35 s); the inset-grouped list's first-row offset (13.33 from 06 §3,
    35 in the informative `list.two`); detent heights other than the two
    measured; whether `onScrollGeometryChange` reports its first value; the
    scroll indicators' look and timing; the back swipe's completion
    threshold; rubber-banding at the edges (we clamp).
39. (R9) Desktop metrics with no reference at all (Ycode's): 44-point bars,
    sidebar rows of 28 points, split-view column widths and the 600-point
    collapse width, desktop sheet and alert cards.

40. (R10) Desktop settings with no reference: the text-scale → Dynamic Type
    thresholds, which portal keys stand for reduce motion and increased
    contrast, and whether `locale` follows `LC_MESSAGES` or `LC_ALL`.
41. (R10) `@SceneStorage` restoration after a system-initiated termination
    (`10-plan.md` §4 q5): we restore after any end that was not a user quit.
42. (R10) Which accessibility modifier wins when two set the same attribute
    on one view; whether attributes of a non-element container reach every
    element inside; default labels of symbols other than "star.fill"; the
    stepper's element (`10-plan.md` §4 q6); a text field's label from its
    title or prompt (08 §2 shows none).
43. (R11) Menus and commands were not measured at all (the reference is an
    iOS device): the position of `CommandMenu`s among the standard menus, the
    default items and shortcuts of a desktop app, which shortcut wins between
    a view and a menu command, menu enablement timing, the context menu's
    long-press duration and movement tolerance, toolbar placements on a
    desktop window.

44. (R13) Desktop behaviour with no reference measurement: the tooltip delay
    and placement, which key presses `onKeyPress` sees before a focused
    text field and whether `KeyPress.key` is the shifted character, a
    table's default column widths and header height, the file dialog's
    layout and how it treats packages and hidden files.

## Deferred

R13: the XDG Desktop Portal file chooser (over `OVDBus`, when a portal
runs); `fileMover`, `fileExporter` for `Transferable` items and several
documents; `Table`'s `rows:` form, `TableRow`/`DisclosureTableRow`,
column customisation (`TableColumnCustomization`), horizontal scrolling of
wide tables, `contextMenu(forSelectionType:)` on tables; `TextRenderer` and
`Text.Layout`; tooltips outside the window's bounds (a pop-up window);
glyph run images for gradient-filled or rotated text.

R11: the D-Bus menu protocol (a global menu bar where the desktop has one);
mnemonics (Alt+letter) in the menu bar; customisable toolbars
(`toolbar(id:)` shows its items without customisation); toolbar overflow
menus; context-menu previews; `openWindow(value:)` routing by value;
`DocumentGroup`; full-screen windows; the About panel (logged only); bar
heights that grow with Dynamic Type (the 26- and 38-point bars are fixed, so
accessibility text sizes overflow them).

R10: (the AT-SPI export is done, OV-ATSPI) pickers' and menus' own
AT-SPI roles (pickers are not annotated yet); glyph-level text extents and
text attributes over AT-SPI; relations (labelled-by); the D-Bus menu
export; accessibility of pickers, menu
items, date pickers and gauges beyond their texts;
`accessibilityRepresentation`, `accessibilityChildren`, rotors, custom
content; text ranges for EditorKit (PARITY §5.3); `UserDefaults` changes made
by other processes on Linux (corelibs defaults are per process); reduce
motion changing the system animations (pushes, sheets); the time zone from
the desktop.

R9: pinned section headers and footers; `onDelete`/`onMove`, swipe actions,
edit mode and drag reordering in lists; `refreshable`; searchable;
`Table` (PARITY §5.4 R12); `NavigationPath` codable representation;
page-style tab views (accepted, shown as tabs); scroll bounce
(edges clamp); interactive sheet dismissal and detent dragging; the
inspector's resizing; `ScrollPosition` (iOS 18 struct; `scrollPosition(id:)`
works); keyboard scrolling of plain scroll views (lists move their
selection); horizontal-list and lazy-grid pinning; accessibility of the
containers (R10).

R8: scrolling forms and pickers (R9); `ControlGroup`, `ShareLink`,
`PasteButton`, `RenameButton`, `MultiDatePicker`, slider ticks and neutral
values, `Stepper` value formats, `LabeledContent(value:format:)`,
`TextField(value:format:)`, `submitLabel`, `keyboardType`, `TextSelection`
bindings for `TextEditor`, `menuIndicator`, `menuOrder`, button repeat,
custom `PickerStyle`/`TextFieldStyle`/`MenuStyle` implementations; bidi
carets (split carets in mixed runs), rich text editing; pop-up shadows and
rounded corners (the window system's).

R7: multi-touch gestures (`MagnifyGesture`, `RotateGesture`,
`SpatialEventGesture`) and several presses in one window at once; named
coordinate spaces in gestures; `onKeyPress`/`KeyPress`; the software
keyboard and keyboard avoidance; cursor shapes, drag and drop;
`DocumentGroup`; `openWindow(value:)` routing by value; window minimum
sizes for `.contentSize` resizability (secondary-click context menus,
`Settings`, menus and `commands`: R11; `@SceneStorage`/`@AppStorage`: R10;
the accessibility export: OV-ATSPI); compositor layers for
individual views (R7 renders whole windows through R5's compositors).

R5: elliptical gradients are drawn as circular ones (the display list has
no gradient transform); `ShapeStyle.image`, materials, `.shadow` and
`.blendMode` on styles; Porter-Duff blend modes (`sourceAtop`,
`destinationOut`, …, and `GraphicsContext`'s `clear`/`copy`/`xor`), which
ThorVG lacks and which composite normally; the colour-matrix filters of
`GraphicsContext` (hue, saturation, brightness, contrast, grayscale,
invert, luminance-to-alpha), accepted and ignored; `colorMultiply` does not
tint raster images; `Image` cap insets and tiling; symbol rendering modes
(hierarchical, palette, multicolor), variable values and symbol effects;
CFF (`OTTO`) glyph outlines; underline and strikethrough drawing; synthetic
bold; `Canvas` symbols; `GeometryEffect`/`ProjectionTransform`;
compositor layers below the top level of a list, GPU blend modes and GPU
effects (layers with a blend mode render inline), several frames in flight.

R6: `GeometryEffect` and `ProjectionTransform` (`CGAffineTransform` exists
since R5), `TimelineView` and
timeline schedules, `ContentTransition`, `blurReplace`, symbol effects,
`scrollTransition`, `navigationTransition`/`matchedTransitionSource`,
`geometryGroup`, the `animation(_:body:)`/`transaction(_:body:)` forms,
`AnimatableValues`, `Animatable` static subscripts, spring blend durations,
a real display link (R7).

R2: `anchorPreference`/`Anchor` and named coordinate spaces;
`ForEach` over bindings and `DynamicViewContent`; the `@Entry` macro (needs a
macro plugin); `@AppStorage`,
`@SceneStorage`, `@FocusState`, `@GestureState` (R7–R10); `App`/`Scene` and
live platform environment (R7, R10). `DynamicProperty.update()` is called
on a copy (a custom property's own stored changes are not kept).

R4: complex-script shaping (GSUB/GPOS marks; a HarfBuzz back end), OpenType
features for `monospacedDigit`/`smallCaps`, synthetic bold/italic, variable
fonts, explicit bidi embeddings and isolates, dictionary line breaking, hyphenation,
`.stringsdict`/`.xcstrings` plural rules, `Text(_:format:)`/date styles,
`Text.Layout`/`TextRenderer`, the language-dependent line height of 08 §3.

Earlier rounds: `containerRelativeFrame`, `safeAreaInset`/`safeAreaPadding`, named
coordinate spaces, `layoutDirectionBehavior`, grid column alignment and
cell anchors, spanning cells widening columns.
