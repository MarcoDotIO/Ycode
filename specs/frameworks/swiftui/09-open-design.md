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

## 4. Platform layer on Linux

- **Windows and input:** SDL3 (zlib) for windows, pointer, touch and
  keyboard, with Wayland and X11 back ends; text input composition (IME)
  through SDL's text-editing events in later rounds.
- **Run loop:** one main thread running the display-tick → transaction
  commit → layout → render cycle, driven by the compositor's frame
  callbacks (60 Hz default, matching the 58–60 Hz we measured).
- **Accessibility:** export the accessibility tree (`08-environment-accessibility-localization.md` §2) to AT-SPI2
  over D-Bus. AccessKit (MIT/Apache-2.0) has an AT-SPI adapter and is the
  candidate; linking the LGPL `libatspi` is not allowed by our licence
  rule, so we speak the D-Bus protocol through AccessKit.
- **Persistence:** `AppStorage` on `UserDefaults` (swift-corelibs; a plist
  per app in `$XDG_CONFIG_HOME`); `SceneStorage` in a per-scene archive
  written when the scene moves to background (`06-app-and-components.md` §8; note that the reference discards it after a user quit).
- **Headless back end:** a deterministic in-memory window used by every
  conformance test: fixed size, scale and font set, and a manual clock.

## 5. Third-party building blocks (licences verified 2026-10-19)

Licences were read from each project's repository licence file (GitHub API
`repos/<owner>/<repo>/license` and the file itself). Only permissive
licences are used; copyleft (GPL, LGPL, MPL) is excluded even when
dual-licensed alternatives exist.

### 5.1 Rendering

| Project | Licence (verified) | Role / notes | Decision |
|---|---|---|---|
| ThorVG (`thorvg/thorvg`) | MIT | Small C++ vector engine: paths, strokes, gradients, clipping, masking, blending; software rasteriser plus GL/WebGPU back ends | **Primary** for shapes and the software reference renderer used by image tests |
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
default provider maps a small set of names to our own drawings and lays
out unknown names as an empty 0 × 0 image (matching the observed "missing
symbol" behaviour, `07-text-images-color.md` §3).

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
| OpenSwiftUI and Tokamak README statements | 1 (project READMEs) |
| `Observation` and swift-corelibs-foundation availability on Linux | 1 (open-source Swift toolchain) |
| Module split `SwiftUICore`/`SwiftUI` | 4 (SDK module layout, names only) |
| Everything else in this file | Ycode-original design (no evidence claim) |
