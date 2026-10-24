# SwiftUI observations (KIT-SWIFTUI, 2026-10-19)

Working notes for `specs/frameworks/swiftui/`. Prose only; no Apple code.
All observations are of our own app (`SUIProbe`) on Apple's iOS 27.1
simulator, of SDK module interfaces (names only), and of the runtime's
launchd property lists (as a file format).

## Sources used

- SDK `.swiftinterface` files of `SwiftUICore` and `SwiftUI`
  (iPhoneSimulator 27.1), read by `research/experiments/swiftui/inventory/
  inv.py`, which keeps declaration kinds, names, argument labels,
  conformance names and iOS availability, and drops everything else
  (types, bodies, attributes, comments). `mkinv.py` renders
  `api-inventory.md`. Module selectors (`Module::Name`) appear in the 27.1
  interfaces and are stripped first.
- `grep -l`/`grep -c`/`grep -o` on SDK interfaces for module membership of
  `#Preview`, `PreviewProvider` and the `DeveloperToolsSupport` type names.
- The runtime's `System/Library/LaunchDaemons/*.plist` (`MachServices`,
  `Label`, `Program`) to map service names to daemons.
- developer.apple.com pages (Layout, ProposedViewSize, Animation, Spring,
  UnitCurve, Transaction, ScenePhase, navigation and presentation APIs,
  AppStorage/SceneStorage, accessibility modifiers) and WWDC session pages:
  WWDC20 10037, WWDC21 10022, WWDC22 10056, WWDC23 10149, 10156, 10157,
  10158, 10160 (titles and descriptions).
- GitHub licence files (API `repos/<o>/<r>/license` and the files) for the
  libraries in `09-open-design.md` §5; the OpenSwiftUI and Tokamak READMEs
  (licence and provenance statements only — **no source file of either
  project was opened**).
- The simulator track's HID driver (`research/experiments/simulator/hid/
  hidsend.m`), built unchanged into our scratch directory.

## Run log

| Batch | Modes | Notes |
|---|---|---|
| runs1 | layout, lifecycle, nav, split, tabs, list, controls, keyboard | `layout` and `lifecycle` good. The `lifecycle` open-URL step left SpringBoard's "Open in …?" prompt on screen, which made the app inactive and swallowed input for every later run of the batch; those runs were discarded. Driver marks appended to the console log were overwritten by the console writer (moved to `.driver` files). |
| runs2 | nav (good: tap and edge swipe), list, controls | Batch stopped: editing `run.sh` while `sh` was executing it broke the running instance. From then on batches run a frozen copy of the script. `list` stage switching stalled the main thread for 19 s under load; stages were split into separate launches (`-stage`). Toggle tap missed (ratio computed from the window, not the content width); targets now come from the app with an anchor. |
| runs3 | controls, keyboard, modal, anim, gesture, dataflow, env, a11y, images, services, split, tabs, layout, list0–2, l10n-en/fr/ar, layout-ar, lifecycle | All good except `gesture`: a bare `wait` in the double-tap step waited for the console process too; fixed with `wait $P`. `layout` identical to runs1 (determinism). |
| runs4 | gesture, persist1–3, a11y with application accessibility enabled | All good. The accessibility preference was deleted again afterwards. |

The device `ycode-test-swiftui-1` was created once, booted once, and
deleted at the end; no other simulator was touched. The host's load
average was 250–560 throughout (other agents).

## Findings worth a second look

- The tracer cannot see FrontBoard's scene connection (endpoint passed in
  at launch) — consistent with the simulator track's earlier note in
  `specs/simulator/app-install-launch.md` §5.
- `defaultMinListRowHeight` is 52 in iOS 27.1 (rows were 44 in older
  releases); navigation-bar top inset 82 for inline and large titles alike
  on this device type.
- In an Arabic UI language, Latin text lines are 22.33 tall instead of
  20.33 (the line height follows the UI language).
- Popovers on this compact-width iPhone type were presented as popovers,
  not adapted to sheets.
- `.equatable()` did not stop a body re-evaluation when only an ignored
  plain field changed (open question in `03` §8).
- `@SceneStorage` was never restored after `simctl terminate`, even after
  backgrounding first; the per-session archive existed briefly and was
  discarded on the next launch.
- `NavigationSplitView` made UIKit write its column state into the app's
  standard `UserDefaults`.
- `Animation` values' `description` strings expose their parameters; we
  used only the numbers (durations, response, damping), not the type
  names.
- `simctl openurl` produces a SpringBoard confirmation prompt that must be
  answered (or dismissed: "Cancel" at ratio 0.315, 0.528) before input
  reaches any app again — worth knowing for every simulator test script.
