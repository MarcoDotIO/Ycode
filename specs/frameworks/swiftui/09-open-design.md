# SwiftUI 9: design note for an open, Linux-buildable implementation

Status: proposal, round 0 (KIT-SWIFTUI, 2026-10-19). **This file is a
Ycode-original design note.** It is not a description of Apple's
implementation: nothing here was learned from Apple's binaries, and where it
resembles SwiftUI's internals that is because the public behaviour
(files 03–08) forces the shape. Clean-room implementers may read it.

## 1. Goals and non-goals

Goals, in priority order:

1. **Source compatibility** for the common surface: an app written against
   the names in `api-inventory.md` (areas marked "round 1–6" in `10-plan.md`)
   compiles unchanged with `import SwiftUI` on Linux (Swift 6.4, the
   project's toolchain) and on macOS.
2. **Behavioural parity** where it is observable and testable: layout
   arithmetic (`04-layout.md`, `golden-layout.md`), update and lifetime
   rules (`03-architecture.md`), animation timing (`05-animation.md`),
   lifecycle order (`06-app-and-components.md`).
3. A small, auditable dependency set with **permissive licences only**
   (§5).

Non-goals for the first rounds: pixel-identical rendering (we have no
Apple fonts, materials or symbol artwork, and may not copy them), the
macOS/watchOS/tvOS/visionOS-only API, UIKit/AppKit interop types
(`UIViewRepresentable` etc. exist only as compile-time shims on Linux),
and Liquid Glass materials (approximated).

Relationship with the Ycode simulator: inside Ycode's iOS simulator, guest
apps use **Apple's** SwiftUI from the simulator runtime; the simulator's
job is to provide the services that framework needs (`01-simulator-parity.md`).
The open implementation in this note is a separate product for Linux-native
apps (`docs/FUTURE.md`, "Open frameworks"). The two share only the
conformance suite: the same probe sources run on Apple's simulator, on
Ycode's simulator, and against the open library.

## 2. Package and module layout (proposal)

Location: `ycode/Frameworks/SwiftUI/` (a SwiftPM package that builds on the
Linux workstation and on macOS). Working package name **OpenViews** — any
name works as long as it is not an Apple trademark (AGENTS.md rule 5). The
module names `SwiftUI` and `SwiftUICore` are interop identifiers (needed for
`import SwiftUI`) and are kept; on Apple platforms the package is never
linked into apps that can use the real framework.

| Module | Role |
|---|---|
| `OVGraph` | Incremental dependency-graph runtime (§3.1). No UI knowledge. |
| `SwiftUICore` | Value types (geometry, `Color`, `Font`, `Angle`, `Animation`, `Spring`, `UnitCurve`, keyframes), `View`/`ViewModifier`/`ViewBuilder`, primitive views, `Layout` and the built-in layouts, environment, preferences, transactions, `Text`/`Image` values, shapes and paths, `GraphicsContext`. Mirrors the split we observed in the SDK (`api-inventory.md`: `SwiftUICore` holds the core, `SwiftUI` re-exports it). |
| `SwiftUI` | `App`/`Scene`, controls, containers (`List`, `ScrollView`, navigation, tabs, presentation), gestures, focus, persistence wrappers, accessibility modifiers; re-exports `SwiftUICore`. |
| `OVText` | Font discovery, shaping, line breaking, bidi, truncation, metrics (§5.2). |
| `OVRender` | Display list, damage, compositor, rasteriser back ends (§5.1). |
| `OVPlatform` | Windows, run loop, input events, clipboard, accessibility bridge, preferences storage; Linux (Wayland/X11 via SDL3) and a headless back end for tests. |

`Observation` is used as is: it is part of the open-source Swift toolchain
and available on Linux, so `@Observable` models work unchanged.
`Foundation` is swift-corelibs-foundation (Apache-2.0) on Linux; it supplies
`CGFloat`, `CGPoint`, `CGSize`, `CGRect`, `UserDefaults`, `Locale`,
`Bundle`.

## 3. Core architecture

### 3.1 Graph runtime (`OVGraph`)

Requirements come from the observed update rules (`03-architecture.md` §4):
a change must re-run exactly the bodies that read the changed data, and
nothing else; equal inputs must stop propagation; layout and rendering must
be recomputed lazily and only where inputs changed.

Design: a directed acyclic graph of **attributes** (typed value cells) with
two kinds of nodes — *inputs* (set from outside: state storage, environment
roots, proposals) and *rules* (pure functions of other attributes). Each
attribute keeps its value, a generation number and its list of dependents.
Writing an input marks dependents dirty (transitively, by flag only);
reading a rule attribute recomputes it on demand if dirty; if the new value
compares equal to the old one (Equatable or bitwise for PODs), its own
dependents are cleaned without recomputation. This is the classic
"push-dirty / pull-value" scheme (as in incremental-computation literature
and in reactive UI toolkits generally) and gives the observed behaviour that
an `Equatable` view or an unchanged child struct stops re-evaluation.

Dependency discovery for view bodies: during a body evaluation, the
runtime records every attribute read (state, environment keys, observed
`@Observable` properties via `withObservationTracking`, `ObservableObject`
publishers as a whole-object dependency). The recorded set becomes the body
rule's inputs for the next update.

### 3.2 View graph

- **Identity.** A view's identity is its path in the static type structure
  (structural identity: position inside `ViewBuilder` results, `if`/`else`
  branch, `Optional`) plus explicit identity (`id(_:)`, `ForEach` element
  IDs). State storage is keyed by identity; a new identity means fresh state
  and an `onDisappear`/`onAppear` pair (`03-architecture.md` §2).
- **Body evaluation.** For a custom `View`, the runtime compares the new view
  value with the previous one field by field (bitwise for plain-value
  fields, closures never equal — see the measured counts in `03` §4.1;
  when a custom `==` is consulted is open, `03` §8) and re-runs `body`
  only if they differ or a recorded dependency changed.
- **Modifiers** produce wrapper nodes; their order is the order of the
  wrappers (outer modifier sees the inner result), see `03` §6.
- **Environment** flows down as a persistent map (hash-array-mapped trie)
  with per-key change tracking so that readers of an unchanged key are not
  invalidated.
- **Preferences** flow up through reducer functions in child order.
- **Transactions** travel with each state write; the graph tags dirty
  attributes with the transaction of the write that dirtied them (§3.4).

### 3.3 Layout

Implements `Layout` and the built-in containers with the rules of
`04-layout.md`; one layout pass per frame for dirty subtrees, with
per-node caches keyed by proposal (the same proposal asked twice must not
re-measure). Text measurement goes through `OVText` with a cache keyed by
(string, font, proposal width, line limit, truncation).

### 3.4 Animation

An animatable attribute stores (from, to, animation, start time,
velocity). On each display tick, the animation's value function produces
the presentation value; retargeting mid-flight adds the new delta on top
for springs and restarts timing for curves, matching the "retarget"
sample in `05-animation.md` §4.2. `Animation` values are an open protocol
(`CustomAnimation`) with built-in curve, spring, delay, speed and repeat
wrappers whose numeric behaviour is fixed by the golden values in
`05-animation.md`.

### 3.5 Display list and rendering

Rendering consumes a **display list**: an ordered tree of items (fill
path, stroke path, glyph run, image, colour/opacity/blend/clip/transform
groups, platform-view placeholders) with stable item IDs derived from view
identity. The renderer diffs display lists between frames to compute damage
and to reuse cached rasterisations (text runs, shapes with unchanged
geometry). Compositing happens in a GPU layer tree.

### 3.6 Render/platform boundary (rounds R5 and R7)

Ycode decision (OV-R5 and OV-R7, 2026-10-30). Rendering (`OVRender`, R5)
and the platform host (`OVPlatform`, R7) meet at one interface,
`frameworks/swiftui/Sources/OVRender/Compositor.swift`:

| Side | Owns | Provides |
|---|---|---|
| `OVPlatform` (R7) | windows, the run loop and display tick, input, the Vulkan loader for the window system (SDL3) | a `RenderSurface` per window: pixel size, content scale, and a presentation — `.vulkan(VulkanSurfaceProvider)` (instance extensions the window system needs; creates the `VkSurfaceKHR` for an instance), `.software(SoftwareSurfaceProvider)` (takes finished CPU frames), or `.offscreen` |
| `OVRender` (R5) | the display list, rasteriser, layer tree, swapchain, and the headless back end | `makeCompositor(for:preference:)` → `Compositor`: `render(RenderFrame)` once per tick (display list in points + scale + clear colour), `surfaceDidResize()`, `readback()`, `invalidate()` before the window goes |

Rules: the compositor creates the `VkInstance` (with the provider's
extensions) and the device, asks the provider for the surface once, owns
and destroys it; Vulkan handles cross as raw values (`VkInstance` as an
opaque pointer, `VkSurfaceKHR` as `UInt64`) so neither module imports the
other's C headers. Both load the system Vulkan loader. `render` blocks in
FIFO presentation, which paces the host's run loop at the display rate.
Compositor and surface live on the host's main thread. When no Vulkan device
works, `.automatic` falls back to the CPU compositor and presents through
copies; offscreen surfaces always work (tests, `ycode preview --render`).

**Rendering decisions (R5, Ycode-original; implemented in `OVRender`).**

- *Rasteriser.* ThorVG 1.1.3 (MIT), vendored unmodified as a SwiftPM C++
  target (`CThorVG`: CPU engine, PNG/JPEG loaders, C API; no threads, no
  SIMD, so output is deterministic), driven through its C API. It renders
  every frame's content on the CPU; GPU work is compositing only.
  What ThorVG cannot do, and what we do instead: Porter-Duff blend modes
  (`sourceAtop`, `destinationOut`, `clear`, `copy`, `xor`, …) — composite
  normally; colour-matrix filters (hue, saturation, brightness, contrast,
  grayscale, invert, luminance-to-alpha) — ignored; colour multiplication —
  applied to the paints of shapes and glyphs, not to images; gradient
  transforms are not used, so elliptical gradients are circular; partial
  conic sweeps — mapped onto ThorVG's full-turn conic gradient, the
  uncovered part taking the end colour up to its middle and the start
  colour after it. Drop-shadow direction: ThorVG measures the angle
  clockwise from "up". Blur and shadow use σ = radius / 2.
- *Text.* Glyph runs carry glyph IDs and positions; outlines come from
  OVText (TrueType `glyf`/`loca`) and are filled as one ThorVG shape per
  run (cached per face and glyph). ThorVG's own text engine is not used,
  so layout stays OVText's. CFF outlines are not read.
- *Display list.* Items as in §3.5, IDs from the creating view node and
  item indices; clips and masks are in a group's local coordinates;
  translation-only groups are folded into their children. Damage =
  bounds of changed items (`DisplayListDiff`).
- *Compositor.* Vulkan 1.3 with dynamic rendering, the loader opened at run
  time; layers are RGBA8 premultiplied textures drawn as quads with an
  affine transform and opacity. Top-level `drawingGroup` groups are their
  own layers (move and fade without rasterising); everything else lives in
  full-surface layers redrawn by damage. Lavapipe (CPU) and NVIDIA GPUs
  produce the CPU rasteriser's pixels within ±2 per channel.
- *Symbols.* Apple's SF Symbols cannot ship. Ycode draws its own set
  (`SymbolArtwork`: 73 common system names, plain outlines on a 24 × 24
  grid, MIT like the rest of the repository; no third-party icon set, so no
  extra licence). Layout boxes of the symbols the spec measured are the
  reference's (07 §3, golden); others use 20.67 × 20.67 at body size.
  Names outside the set draw a visible placeholder (a rounded square with a
  question mark) at the default size, so missing artwork is noticed — a
  deliberate deviation from the reference's 0 × 0 for unknown names, which
  remains available (`OpenSymbolProvider(missingSymbolsLayOutEmpty: true)`,
  used by the conformance tests).
- *Other Ycode choices.* Continuous rounded corners: the corner starts 1.28
  radii from the corner with shortened Bézier handles (no reference
  geometry). Hierarchical levels of a custom foreground style: opacities
  1, 0.6, 0.3, 0.18, 0.08 (the first two from the label colours of 07 §4).
  Previews without a layout trait render at 393 × 852 points headlessly.

## 4. Platform layer on Linux

- **Windows and input:** SDL3 (zlib) for windows, pointer, touch and
  keyboard, with Wayland and X11 back ends; text input composition (IME)
  through SDL's text-editing events in later rounds.
- **Run loop:** one main thread running the display-tick → transaction
  commit → layout → render cycle, driven by the compositor's frame
  callbacks (60 Hz default, matching the 58–60 Hz we measured).
- **Accessibility:** export the accessibility tree (`08-environment-accessibility-localization.md` §2) to AT-SPI2
  over D-Bus. AccessKit (MIT/Apache-2.0) was the first candidate; its Rust
  build was not allowed, and linking the LGPL `libatspi` (or `libdbus`) is
  excluded by our licence rule, so OpenViews speaks the D-Bus protocol
  itself: a D-Bus client and an AT-SPI2 exporter of our own (§4.5).
- **Persistence:** `AppStorage` on `UserDefaults` (swift-corelibs; a plist
  per app in `$XDG_CONFIG_HOME`); `SceneStorage` in a per-scene archive
  written when the scene moves to background (`06-app-and-components.md` §8; note that the reference discards it after a user quit).
- **Headless back end:** a deterministic in-memory window used by every
  conformance test: fixed size, scale and font set, and a manual clock.

### 4.1 Platform decisions (round R7, OV-R7, 2026-10-30)

Ycode-original decisions; implementation in `frameworks/swiftui/Sources/
OVPlatform/`, `COVSDL/` and `SwiftUI/App/`.

- **SDL3 integration.** Release 3.4.18 (zlib). Its public headers (the 37
  the bridge includes) are vendored unmodified under `Sources/COVSDL/`, and
  libSDL3 is opened with `dlopen` at run time (`OV_SDL3_LIBRARY`, then the
  loader's search path). The package therefore builds everywhere without
  SDL3, and an app without libSDL3 or a display falls back to the headless
  back end. libSDL3 is built from source in the user's folder on hosts
  without a system package (no root; the package README has the recipe).
- **Window systems.** X11 and Wayland through SDL; on X11 window surfaces use
  SDL's native shared-memory framebuffer (hint
  `SDL_FRAMEBUFFER_ACCELERATION=0`; without it SDL re-created the window
  through an OpenGL renderer, a hide/show at start-up). Points = SDL window
  coordinates × pixel density ÷ display scale; the display scale is
  SwiftUI's `displayScale`.
- **Run loop.** One main thread. It sleeps in the main run loop while a
  dispatch source watches the window system's connection (X11 or Wayland
  descriptor), so it wakes for input and for main-queue work alike; no
  deadline when idle (no frames, no polling). Frames: a display link at the
  display's refresh rate (60 Hz default) on a regular grid of tick times;
  only while something changed or animates. A Vulkan compositor's FIFO
  present (R5) additionally paces the loop (§3.6).
- **Render boundary (§3.6).** Each window is a `RenderSurface`:
  `.vulkan(VulkanSurfaceProvider)` for windows created for Vulkan (SDL gives
  the instance extensions and creates the `VkSurfaceKHR`; the loader named
  by `YCODE_VULKAN_LIBRARY` is loaded with `SDL_Vulkan_LoadLibrary`), else
  `.software`. The host creates a Vulkan window first and keeps it when
  R5's Vulkan compositor can present to it; otherwise it re-creates the
  window for the software compositor (`OV_RENDERER` overrides the choice).
- **Scene phases on Linux.** One phase for the app and its windows: shown →
  active; every window minimised/hidden → inactive → background; restored →
  inactive → active; focus changes do not change it. Closing the last window
  quits; quitting goes inactive → background → `willTerminate`. URLs (command
  line or desktop activation) go to `onOpenURL` without the reference's
  confirmation prompt.
- **UIKit/AppKit shims.** `UIApplicationDelegate`, `UIApplication`,
  `NSApplicationDelegate`, `NSApplication` exist as shims with the lifecycle
  callbacks; on Linux a delegate class must have a `required` `init()`
  (`final` classes do) because the toolchain's `NSObject.init()` is not
  `required` there.
- **Input defaults.** Text fields do not auto-capitalise on the desktop host
  (the headless host keeps the reference's sentence capitalisation);
  `.command` in a keyboard shortcut means Ctrl (or Super) on Linux; a wheel
  notch scrolls 10 pt.
- **Gesture arbitration** is our own design (package README, "Platform, app
  and input design (R7)"): a session per press over the gestures on the hit
  chain, first to activate or end wins, multi-taps waiting for their next tap
  hold back lower-priority gestures.
- **Test hosts.** Linux CI-style runs need no display hardware: X11 through
  Xvfb (packages unpacked into a user folder with `apt-get download` +
  `dpkg -x`; `xdotool` drives real X input), Wayland through a headless
  Weston (pixman renderer). On the Thor, the system Weston 13's headless
  back end loaded only with libpng, cairo, jpeg, webp, pango and glib
  preloaded (`LD_PRELOAD`), a packaging fault of that host.

### 4.2 Controls, look and text editing (round R8, OV-R8, 2026-10-30)

Ycode-original decisions; implementation in `frameworks/swiftui/Sources/
SwiftUI/Controls/`, `App/Popups.swift` and `Sources/OVText/Editing/`. Sizes
follow `golden-layout.md` (all 21 control rows); the rules that produce them
are in the package README ("Controls design (R8)").

- **Default look on Linux.** Neutral, light and dark. Where 07 §4 records a
  system colour, that value is used: fills (systemFill #78788033 /
  #7878805C) for bordered buttons, stepper, slider and segmented tracks;
  separators (#3C3C431F / #54545880); grouped backgrounds (#F2F2F7 / #000000)
  and rows (#FFFFFF / #1C1C1E); placeholder text and secondary labels. Ycode's
  own: switch off track #E5E5EA / #39393D, thumbs #FFFFFF / #F2F2F7 with a
  12 % / 25 % black hairline and a soft shadow, field and menu backgrounds
  #FFFFFF / #1C1C1E and #FFFFFF / #2C2C2E, outlines (label colour at 30 %),
  raised segment #FFFFFF / #636366, menu highlight black 7 % / white 12 %,
  selection = tint at 28 % / 45 %. The accent is the environment's tint
  (07 §4 accent by default). Shapes: capsules for bordered buttons, switches
  and segmented controls; rounded rectangles of radius 8 for fields, 10 for
  form groups. Focus ring: tint at 55 %, 2.5 points, 3 points outside the
  control. Glass styles are approximated by a translucent fill and a light
  rim (§1).
- **Pop-up windows.** Menus are real pop-up windows of their owner
  (`WindowConfiguration.popupParent`, SDL3 `SDL_CreatePopupWindow` with the
  popup-menu and not-focusable flags), not drawn into the owner, so they can
  extend past its edges; the owner keeps the keyboard and the host routes keys
  to the innermost pop-up. Without a usable pop-up window the content becomes
  an overlay of the owner. Menu rows: 26 points, an 18-point check-mark slot,
  5 points above and below.
- **Keyboard.** Every control is focusable (Tab order = tree order), Space
  and Return activate, arrows adjust; Linux text-editing keys (Ctrl+arrows by
  word, Ctrl+A/C/X/V/Z, Ctrl+Shift+Z and Ctrl+Y).
- **Text editing core.** An editing model independent of views (selection,
  movement units, undo with typing coalescing, marked text) and a geometry
  of OVText layouts (carets, hit testing, selection rectangles) — the base
  of the IDE's EditorKit (`docs/PARITY.md` §5.3–5.4). The caret blinks
  0.53 s on and off and rests after 10 s, so an idle window renders nothing.

### 4.3 Containers and presentation (round R9, OV-R9, 2026-10-30)

Ycode-original decisions; implementation in `frameworks/swiftui/Sources/
SwiftUICore/Layout/LazyStacks.swift`, the graph's suspension and `Sources/
SwiftUI/Containers/`. Measured values come from 06 §2, §3, §6 and the golden
`scrollView` rows; the rest is ours (package README, "Containers and
presentation design (R9)").

- **Suspension instead of removal.** Covered navigation pages, unselected
  tabs and hidden split columns keep their view nodes and state; their
  `onAppear`/`onDisappear` and tasks follow visibility. This reproduces
  06 §2.1's lifecycle order, including the never-shown page of a two-value
  push.
- **Lazy materialisation from layout.** Lazy containers enumerate their
  content without building it, measure per unit, estimate the rest with the
  mean, and re-materialise after each layout pass from the scroll view's
  visible region, without overscan (06 §3's exact counts). A scroll view
  that touches the safe area scrolls content under the inset.
- **Scrolling physics.** Offsets clamp at the edges (no rubber band); flings
  decay by 0.998 per millisecond in closed form and stop below 10 points/s;
  wheel deltas scroll at once; indicators are drawn by the scroll view.
- **Desktop chrome.** On window-system hosts bars are 44 points (82 on the
  headless host, the reference's inset), sheets are centred cards, dialogs
  are centred; sidebar lists use 28-point rows; `NavigationSplitView`
  collapses below 600 points; `HSplitView`/`VSplitView` (the macOS names) have
  1-point dividers with an 8-point drag band.
- **Presentations as window layers.** Sheets, covers, alerts and dialogs are
  modal layers of their window (a dimming layer takes every press; Tab is
  scoped to the innermost); popovers reuse R8's pop-up windows. The reference
  presents them in separate UIKit views; layers behave the same on X11,
  Wayland and the headless host, without depending on how each window
  system treats modal child windows.
- **Removal transitions** keep a removed view only while the animations its
  removal started run (R8's QA: an endless spinner kept a removed row).

### 4.4 Environment, persistence, accessibility, commands (rounds R10 and R11, OV-R11, 2026-10-30)

Ycode-original decisions; implementation in `frameworks/swiftui/Sources/
OVPlatform/Settings.swift`, `Sources/SwiftUI/App/`, `Input/` and
`Accessibility/` (package README, "Environment, persistence and
accessibility design (R10)" and "Commands, menus and toolbars design (R11)").

- **Desktop settings.** The platform reports one settings value (appearance,
  contrast, reduce motion and transparency, differentiate without colour,
  invert colours, bold text, button shapes, a Dynamic Type size, locale) and
  a change event. Sources, strongest first: `OV_*` environment variables; a
  settings file (`$XDG_CONFIG_HOME/openviews/settings.conf`, `key = value`)
  watched with inotify; the freedesktop settings portal through the `gdbus`
  tool (a separate process; nothing linked), read at start and monitored;
  SDL's system theme; the POSIX locale variables; the 08 §1 defaults.
  Desktop text scales map to Dynamic Type sizes by fixed thresholds. The
  host writes only changed keys into every window's root environment, so
  only their readers re-render. A D-Bus client of our own was not written:
  `gdbus` and SDL's theme were cheaper and are optional.
- **Persistence.** `@AppStorage` is `UserDefaults` (swift-corelibs on
  Linux); writes through wrappers update readers at once, other writes are
  found by comparing the readers' keys after each run-loop wake, because
  corelibs posts no change notification. `@SceneStorage` is per window,
  archived at background, discarded on a user's close or quit (06 §8),
  restored at launch when an archive is left (an end without a user quit).
- **Accessibility.** The tree is built on demand from the laid-out graph
  (none is kept while nothing asks, as 08 §2 observed); controls annotate
  their role, value and actions and combine their labels; roles map onto
  AT-SPI's. The export to AT-SPI2 is our own (§4.5, OV-ATSPI); linking the
  LGPL `libatspi` stays excluded.
- **Menus.** Linux desktops have no global menu bar, so each main window
  draws a menu bar (App, File, Edit, View, the app's menus, Window, Help)
  built from the merged `commands` of all scenes; menus are R8 pop-up
  windows; commands are evaluated as graph nodes under an unlaid-out host so
  their shortcuts work with the menus closed; views' shortcuts come before
  menu commands. Exporting menus through the D-Bus menu protocol is left for
  later.
- **Focused values** follow the focus chain (innermost publication wins);
  scene values fill the rest.
- **Context menus** open on a secondary click or a 0.5 s touch press, as
  pop-up menus at the pointer; list selection menus get the selection.
- **Window toolbars** are a bar under the menu bar for toolbar items
  outside navigation containers; `Settings` is a separate, non-resizable
  window at its content's ideal size.

### 4.5 AT-SPI export (round R10, OV-ATSPI, 2026-10-30)

Ycode-original design; implementation in `frameworks/swiftui/Sources/OVDBus/`,
`Sources/OVAccessibilityATSPI/` and `Sources/SwiftUI/Accessibility/ATSPIBridge.swift`
(package README, "AT-SPI export", with the role table). Written from the
D-Bus Specification 0.43 and at-spi2-core's public interface XML; no
third-party code, no Rust, nothing linked.

- **Our own D-Bus client** (`OVDBus`): Unix socket transport (path and
  Linux abstract addresses), SASL EXTERNAL, the full type system and wire
  format in both byte orders, messages, method calls with asynchronous or
  awaited replies, errors, signals and match rules, and exported objects
  with the standard `Peer`, `Introspectable` and `Properties` interfaces.
  Main actor only: data is read when a main-queue dispatch source sees the
  socket readable, so the platform run loop needs no change; an awaited
  call keeps answering incoming calls (the registry calls back during
  `Embed`).
- **A view-independent exporter** (`OVAccessibilityATSPI`) works on
  snapshots of AT-SPI nodes that a provider fills and on requests it hands
  back. The OpenViews provider maps the R10 tree (roles, labels, values,
  hints, traits, frames, actions; ranges of sliders and progress views;
  expanded outline rows) and runs requests on the elements' closures.
- **Accessibility bus**: `AT_SPI_BUS_ADDRESS`, else the bus launcher's
  `org.a11y.Bus.GetAddress` on the session bus; none, no export.
  Registration through `Socket.Embed`; the application root and one object
  per element (Accessible and Component; Action, Text/EditableText, Value,
  Selection as the element needs); the Cache.
- **Cheap without listeners, lazy without clients**: no tree is built until
  a client asks for an object of a window; per-window revisions (pass
  count, size, focus, activity, title) decide what to rebuild; frames
  rebuild only while an AT has registered a listener with the registry,
  and only windows whose revision moved. Changes are sent as the
  difference of two snapshots, filtered by the registered listeners.
- **Events**: focus, state changes, name/description/role/value property
  changes, children added and removed (with the Cache's
  `AddAccessible`/`RemoveAccessible`), text inserted/deleted and caret
  moves, window activate/deactivate/create/destroy.

## 5. Third-party building blocks (licences verified 2026-10-19)

Licences were read from each project's repository licence file (GitHub API
`repos/<owner>/<repo>/license` and the file itself). Only permissive
licences are used; copyleft (GPL, LGPL, MPL) is excluded even when
dual-licensed alternatives exist.

### 5.1 Rendering

| Project | Licence (verified) | Role / notes | Decision |
|---|---|---|---|
| ThorVG (`thorvg/thorvg`) | MIT | Small C++ vector engine: paths, strokes, gradients, clipping, masking, blending; software rasteriser plus GL/WebGPU back ends | **Primary** for shapes and the software reference renderer used by image tests; in use since R5 (1.1.3, vendored, §3.6) |
| Skia (`google/skia`) | BSD-3-Clause | Full 2D stack (Vulkan back end, text) — very large build, heavy dependency chain | Alternative if ThorVG lacks a feature (e.g. advanced blend modes) |
| Blend2D (`blend2d/blend2d`) | Zlib | Fast CPU 2D rasteriser with JIT | Alternative software rasteriser |
| Vello (`linebender/vello`) | Apache-2.0 / MIT (dual, `LICENSE-APACHE`, `LICENSE-MIT`) | GPU compute 2D renderer (Rust) | Not first choice (Rust toolchain in the build) |
| Mesa lavapipe | MIT | CPU Vulkan driver for CI | Used in CI for the Vulkan compositor |
| SDL3 (`libsdl-org/SDL`) | Zlib | Windows, input, Vulkan surface creation | **Primary** platform layer |
| cairo, Pango | LGPL/MPL | — | **Excluded** (licence) |

### 5.2 Text

| Project | Licence (verified) | Role / notes | Decision |
|---|---|---|---|
| HarfBuzz (`harfbuzz/harfbuzz`) | "Old MIT" (`COPYING`) | OpenType shaping | **Primary** shaper |
| FreeType (`freetype/freetype`) | dual: FreeType Licence (BSD-style with credit clause) **or** GPLv2 — we take the FTL | Font loading, glyph outlines, hinting | **Primary** (under FTL; credit notice in our docs) |
| ICU4C (`unicode-org/icu`) | Unicode License v3 | Line breaking (UAX #14), bidi (UAX #9), grapheme segmentation, locale data | **Primary** for segmentation and bidi; swift-corelibs-foundation already depends on ICU on Linux |
| ICU4X (`unicode-org/icu4x`) | Unicode License v3 | Rust successor of ICU | Not used (Rust) |
| SheenBidi (`Tehreer/SheenBidi`) | Apache-2.0 | Small bidi implementation | Fallback if ICU bidi is too heavy |
| libunibreak (`adah1972/libunibreak`) | Zlib | Line and word breaking | Fallback for line breaking |
| fontconfig (`fontconfig/fontconfig`) | MIT-style permission notice (`COPYING`) | Font discovery and fallback on Linux | **Primary** on Linux |
| harfruzz, parley, cosmic-text | MIT; Apache-2.0/MIT; Apache-2.0/MIT | Rust text stacks | Not used (Rust) |
| FriBidi | LGPL-2.1 | — | **Excluded** (licence) |

Fonts: Apple's system fonts and SF Symbols may not be shipped or copied.
The open implementation ships a default UI font under the SIL Open Font
License 1.1 (e.g. Inter or Noto Sans; OFL is a permissive font licence
that forbids selling the font alone — acceptable for bundling, but it is
a font licence, not a software licence, so it is recorded separately).
Consequences for conformance: text-dependent golden values differ; tests
check them as relations (`10-plan.md` §3.3). Symbol images: an
`Image(systemName:)` resolves through a pluggable symbol provider; the
default provider maps a small set of names to our own drawings; unknown
names draw a visible placeholder by default, or lay out as an empty 0 × 0
image in reference-parity mode (the observed "missing symbol" behaviour,
`07-text-images-color.md` §3; decision in §3.6).

### 5.3 Layout helpers

Yoga (MIT) and Taffy (MIT) implement CSS flexbox/grid. Their rules are not
SwiftUI's (no proposal/response negotiation, different flexibility
ordering), so they are **not** used; our layout engine is written from
`04-layout.md`.

### 5.4 Prior open SwiftUI-like projects

| Project | Licence | Provenance | Decision |
|---|---|---|---|
| OpenSwiftUI (`OpenSwiftUIProject/OpenSwiftUI`) and OpenAttributeGraph | MIT | Its README states the goal of matching SwiftUI closely, says it uses hidden API and private frameworks on Apple platforms, and is "for learning and research purposes"; it does not document a clean-room process, and its structure mirrors Apple's private internals | **Not read.** Licence is fine, provenance is not demonstrably clean, so no Ycode agent may open its sources. |
| Tokamak (`TokamakUI/Tokamak`) | Apache-2.0 | SwiftUI-compatible API for WebAssembly/DOM and static HTML, React-style reconciler; repository archived (2026-01-28); credits SwiftWebUI's reverse-engineering notes | Not read for this round; may be consulted for API-shape ideas only after a provenance review. |

## 6. Testing strategy

One test source, two implementations (as in the RealityKit plan): the
probe cases (`research/experiments/swiftui/SUIProbe/`) are written against
the public API. On Apple's simulator they produce the golden logs; ported
to a SwiftPM test target, they run against OpenViews' headless back end and
compare. Details and tolerances: `10-plan.md`.

## Evidence

| Claim | Level |
|---|---|
| Licences of every listed project | 1 (each repository's licence file, read 2026-10-19) |
| SDL 3.4.18 licence (zlib) and the API used by `COVSDL` | 1 (`LICENSE.txt` and the public headers of tag `release-3.4.18`, read 2026-10-30) |
| Vulkan structures and entry points of the surface probe | 1 (Vulkan specification, Khronos registry) |
| X11 connection descriptor (`XConnectionNumber`), Wayland (`wl_display_get_fd`) | 1 (Xlib and libwayland-client public API) |
| R7 platform decisions (§4.1) | Ycode-original design (no evidence claim) |
| R8 look, pop-up and editing decisions (§4.2); the colour values taken from 07 §4 | Ycode-original design; 3 for the 07 §4 values and the golden sizes |
| R9 container and presentation decisions (§4.3) | Ycode-original design; 3 for the 06 §2, §3, §6 values and the golden `scrollView` rows |
| R10/R11 decisions (§4.4) | Ycode-original design; 3 for the 08 §1–2 and 06 §8 values; 1 for the public API names, the freedesktop settings portal interface (`org.freedesktop.portal.Settings`: `ReadAll`, `SettingChanged`; the `org.freedesktop.appearance` keys) and the Linux inotify API |
| AccessKit licence (MIT OR Apache-2.0; `accesskit-c` 0.23.1's `Cargo.toml` and README, read 2026-10-30) | 1 |
| D-Bus wire format, messages, addresses, EXTERNAL authentication, the bus and standard interfaces (§4.5) | 1 (D-Bus Specification 0.43, freedesktop.org, read 2026-10-30; dbus is AFL-2.1 OR GPL-2.0-or-later — read as a specification, no code used) |
| AT-SPI2 interfaces, role and state numbers, Embed, Cache and event signatures (§4.5) | 1 (at-spi2-core `xml/*.xml` on `main`, read 2026-10-30; LGPL-2.1-or-later — interface facts only, no code used) |
| AT-SPI decisions (§4.5) and the role table | Ycode-original design (no evidence claim) |
| SDL3 pop-up windows (`SDL_CreatePopupWindow`, `SDL_WINDOW_POPUP_MENU`, `SDL_WINDOW_NOT_FOCUSABLE`) and Xlib `XSetInputFocus` | 1 (SDL 3.4.18 public headers, zlib; the Xlib API) |
| OpenSwiftUI and Tokamak README statements | 1 (project READMEs) |
| `Observation` and swift-corelibs-foundation availability on Linux | 1 (open-source Swift toolchain) |
| Module split `SwiftUICore`/`SwiftUI` | 4 (SDK module layout, names only) |
| ThorVG 1.1.3 licence (MIT) and API (C API, scene effects, conic gradients, masks) | 1 (the project's `LICENSE` and `inc/thorvg.h`/`thorvg_capi.h`, tag v1.1.3, read 2026-10-30) |
| Vulkan 1.3 behaviour used by the compositor (dynamic rendering, swapchain, layouts, blending) | 1 (the Vulkan specification; Khronos headers 1.3.275, Apache-2.0) |
| PNG, zlib and DEFLATE formats; JPEG frame headers; TrueType `glyf`/`loca` | 1 (W3C PNG specification, RFC 1950, RFC 1951, ITU-T T.81, the OpenType specification) |
| Symbol layout boxes reused for our artwork | 3 (07 §3 and golden-layout.md measurements; names are interop identifiers) |
| Everything else in this file | Ycode-original design (no evidence claim) |
