# SwiftUI (iOS) — specification index

Status: **draft, round 0** (agent KIT-SWIFTUI, 2026-10-19); implementation
status below. Reference: Xcode 27.1 (27A9269), iPhoneSimulator 27.1 SDK, iOS
27.1 simulator runtime (24A94401), device type iPhone Duo (466 × 678 pt,
scale 3, 60 Hz; the only iPhone type the 27.1 runtime accepts on this Mac).

Implementation status (2026-10-28): `frameworks/swiftui/` (package
`ycode-swiftui`: library products `SwiftUI` and `SwiftUICore`, built as
`OpenViews` and `OpenViewsCore` on Apple hosts, and `OVText`; test target
`OpenViewsTests`). Rounds R1, R2, the core of R3, R4 and R6 of `10-plan.md`
§2 are done; rendering (R5) and the platform host (R7) are not started. The
package README lists what is done, deferred and not started.

This set serves two goals of `docs/FUTURE.md`:

1. **Simulator parity first.** SwiftUI already works in Apple's iOS
   Simulator, so it is an "easy win": Ycode's simulator runs Apple's own
   SwiftUI from the runtime, and only has to provide the system services,
   daemons and host features SwiftUI depends on. Files 01–02 say what those
   are and how to check them.
2. **An open, Linux-buildable reimplementation** (files 03–10): the
   architecture and behaviour in our own words, measured golden values,
   a design note and an implementation plan.

Clean-room implementers read only this directory, public documentation
and the open-source projects named in `09-open-design.md` (and **not**
OpenSwiftUI, see there).

## Files

| File | Content |
|---|---|
| `01-simulator-parity.md` | What SwiftUI apps need from the simulator, per area: observed behaviour in Apple's simulator and the services, daemons, Darwin notifications and host features it relies on |
| `02-conformance-checklist.md` | The checklist to run on Ycode's simulator: probe mode + driver action + expected observable result |
| `03-architecture.md` | `View` and body evaluation, identity and lifetime, dependency tracking (measured re-evaluation counts), update cycle, environment, preferences, modifier order |
| `04-layout.md` | Proposal/size/placement, primitives, text, stacks, frames, padding, alignment, grids, safe areas, pixel rounding |
| `05-animation.md` | Transactions, curves, springs, animation timing, scoping, retargeting, transitions, keyframes |
| `06-app-and-components.md` | App/Scene lifecycle and scene phases, navigation, tabs, lists and scrolling, controls, keyboard and text input, presentations, gestures, persistence |
| `07-text-images-color.md` | Fonts and Dynamic Type tables, SF Symbols and asset images, colours in light/dark/high contrast |
| `08-environment-accessibility-localization.md` | Environment values, live setting changes, accessibility tree, localization and right-to-left layout, previews |
| `09-open-design.md` | **Ycode-original design note**: module layout, graph runtime, rendering and text back ends with verified licences |
| `10-plan.md` | Implementation rounds (one agent each) and the conformance-test plan |
| `golden-layout.md` | Generated: measured sizes and frames of ~140 composed views at fixed proposals |
| `api-inventory.md` | Generated: name-only inventory of the iOS API surface (types, members with labels, iOS availability), by area |

Probe app (our own code): `research/experiments/swiftui/SUIProbe/`
(`build.sh`, `run.sh`, sources, `svctrace.c` service tracer,
`trace.py`, `mkgolden.py`); inventory scripts:
`research/experiments/swiftui/inventory/`; run logs:
`research/experiments/swiftui/results/`; working notes:
`research/notes/swiftui-observations-2026-10-19.md`. Screenshots stayed
in the git-ignored `research/dirty/swiftui/`.

## Framework layout facts (level 4)

- Two modules: **`SwiftUICore`** (views, layout, environment, animation,
  text, shapes, colours — about 4 000 public names) and **`SwiftUI`**
  (app and scenes, controls, containers, navigation, presentation,
  gestures, UIKit hosting — about 4 800 names), which re-exports
  `SwiftUICore`. Both ship Swift module interfaces; `SwiftUI` also has two
  small headers (`SwiftUI.h`, `SwiftUI_Metal.h`).
- Cross-framework overlays are separate `_<Framework>_SwiftUI` modules
  (MapKit, AVKit, PhotosUI, StoreKit, RealityKit, SwiftData, WebKit and 20
  more in the 27.1 SDK); the view `#Preview` macro is in `SwiftUI`, the shared preview types in `DeveloperToolsSupport`;
  `@Observable` from the toolchain's open-source `Observation` module.
- At run time our app loaded, among others, SwiftUI, SwiftUICore,
  UIKitCore, QuartzCore, CoreText, CoreUI and the attribute-graph and
  rendering support frameworks of the runtime (`01` §2 lists what that
  means for the simulator).

## Evidence summary

Level 1: developer.apple.com pages and WWDC session pages (titles and
descriptions; cited per file), licence files of open-source projects.
Level 3: our probe app on simulators named `ycode-test-swiftui-*`, driven by
`simctl` and the simulator track's HID driver (`research/experiments/
simulator/hid/hidsend.m`); our own service tracer inserted into our own
app only. Level 4: SDK module interfaces, names only (`api-inventory.md`).
Level 5 (disassembly/decompilation) was **not** used. The reference tools
folder, `research/dirty/` of other agents and Ghidra were not opened; no
SDK header or `.swiftinterface` text is reproduced.
