# SwiftUI previews, Ycode's own design

Ycode modules: `YcodePreviews` (discovery, payloads, hosts, plans, the
update planner, the screen layout; builds on Linux too) and `YcodeUI`
(`PreviewRenderer`, `PreviewCanvasController`, `RemotePreviewSession`,
`WorkspaceWindowController` previews). Evidence is limited to Apple's
public `#Preview` / `PreviewProvider` / `@Previewable` documentation, the
open-source swift-syntax macro definitions and public UIKit/AppKit/SwiftUI
API; Xcode's own preview machinery was not studied and is not imitated.

Previews run two ways:

| Platform of the previewed target | Path | Section |
|---|---|---|
| macOS (and packages without a Ycode simulator destination) | load a payload into a long-lived Mac host, render each preview offscreen to PNG | §The macOS host |
| iOS, iPadOS, visionOS | a long-lived preview host on a Ycode simulator; edits load new payloads into it; the canvas shows its live display | §Live previews |

The platform is the product's (`SDKROOT` of the project's first target);
a package previews on iOS when the run destination is a Ycode simulator,
else on the Mac.

## Discovery (lexical)

In the focused Swift file, outside comments and string literals:

- `#Preview` followed by optional parenthesized arguments and a `{ … }`
  body. The first argument, when a string literal, is the name; unnamed
  previews are `Preview`, `Preview 2`, … in file order.
- `traits:` arguments are recorded by name, in order: `.fixedLayout(width:
  W, height: H)` fixes the size; `.sizeThatFitsLayout` sizes the preview to
  its content; `.landscapeLeft`, `.landscapeRight`, `.portraitUpsideDown`
  set its orientation (`PreviewDeclaration.traits`, `.layout`,
  `.orientation`). Other traits are kept but have no effect.
- `struct X: … PreviewProvider …`: one preview named `X`, rendering
  `X.previews`.
- Previews are listed in line order. Each records its line and the line of
  its body's opening brace (diagnostics map back to it).

## Live previews (iOS, iPadOS, visionOS)

### Pieces

- **Preview device.** Every Ycode simulator row (`run.md` §Runtimes and
  device types) has a preview device of its own, the row's device
  directory plus `-previews` (e.g. `<data>/devices/ycode-device-iphone-18-pro-27.0-previews`),
  so previews never touch the device an app runs on. It runs with warm
  boot always on (Ycode decision: it exists to start fast), its display
  server on, and the preview host installed and launched:
  `… ycode-sim --device <dev> --runtime-root <root> [--device-type <id>]
  --install-app <data>/apps/previews-<platform>/YcodePreviewHost.app
  --launch dev.ycode.previewhost --display-server unix:<data>/display/pv-<hash>.sock`.
  The socket's name is short (`pv-` and a 32-bit FNV-1a hash of the device
  directory's name, in hex): the Mac's ssh refuses a forward whose socket
  path is 104 bytes or longer ("Bad local forwarding specification"),
  which `<data>/display/<device directory>-previews.sock` reached on the
  reference host.
  It runs until Ycode quits (SIGINT to the launcher, which saves it).
- **Preview host** (`PreviewHost`): one small UIKit app, the same for every
  project, built once per platform and deployment target on the Mac
  (`xcrun --sdk iphonesimulator swiftc`, a scene-based app,
  `dev.ycode.previewhost`, display name "Previews", with an icon of
  Ycode's own drawn at build time: `AppIcon60x60@2x/@3x.png`, RGB PNGs
  with stored deflate blocks). It polls `/tmp/ycode-previews/plan.json` every
  25 ms (the device's `/tmp` is `DEV/data/tmp` on the simulator host,
  `specs/simulator/app-install-launch.md` §3.4). A new plan names a payload;
  the host `dlopen`s it (once per path), calls `ycode_preview_make(i)` for
  each region and shows the view controllers. It appends its reports to
  `/tmp/ycode-previews/host.log`: `YCODE-PREVIEW started`, `YCODE-PREVIEW
  ready <generation> <ms>` (views built and committed), `YCODE-PREVIEW
  error <generation> <message>` (the payload did not load, a preview index
  is missing). The IDE follows that file with `tail -F` over ssh (an app's
  standard output does not reach the launcher's output).
- **Payload** (`PreviewPayloadGenerator`, `PreviewCompiler`): a dynamic
  library with the previewed module's code and one factory per preview.
  Its sources are copies of the module's Swift files with every `#Preview`
  block and every entry-point attribute (`@main`, `@UIApplicationMain`,
  `@NSApplicationMain`) replaced by spaces (lines kept); the previewed
  file's copy gets the wrappers appended (so they see its `fileprivate`
  declarations); a generated support file holds the `__ycodeHost`
  overloads and the two C entry points `ycode_preview_count` and
  `ycode_preview_make` (a retained `UIViewController`, or
  `NSViewController` on the Mac). A body of SwiftUI content resolves to
  the `@ViewBuilder` overload (wrapped in a hosting controller); a body
  that returns a `UIViewController` or a `UIView` resolves to the UIKit
  overloads, which are `@_disfavoredOverload` so content never does (the
  shapes of the `#Preview` macro's public declarations). A body with
  `@Previewable` lines becomes a wrapper view whose stored properties they
  are. Compile: one whole-module `-Onone` frontend job, `-emit-library`,
  `-target arm64-apple-ios<runtime version>-simulator`, `-D DEBUG -D
  YCODE_PREVIEW`, Swift 5 mode, a warm module cache under
  `~/Library/Developer/Ycode/DerivedData/Previews/ModuleCache` (an absolute,
  normalized path: a `..` in it made clang see two caches), each
  generation's own install name `@rpath/payload-<n>.dylib`.
- **Plan** (`PreviewPlan`): `{generation, payload, regions[]}`; a region
  is a preview index, a rectangle of the device's screen in points, a
  scale, and its traits (`style` light/dark, `dynamicType` as a
  `DynamicTypeSize` name, `orientation`, `fits`). The host lays the
  preview out at `width/scale × height/scale`, scales it into the region,
  and applies the traits through `overrideUserInterfaceStyle` and
  `traitOverrides` (content size category; vertical size class compact
  for landscape). The IDE writes the payload and then the plan, each by
  rename (`previewDeliverCommand`), in one ssh call over a shared
  connection (`ControlMaster`), keeping the newest 40 payloads.
- **Screen layout** (`PreviewScreenLayout`): every tile of the canvas
  gets one region; all tiles share one scale (at most 1), chosen by trying
  every column count and keeping the largest scale (ties to more columns),
  and the grid is centred. One device-sized tile fills the screen at scale
  1; two sit side by side at 0.5 on a phone; six variants form 3 × 2 at
  1/3. A fixed-layout tile keeps its size; a landscape tile is the screen
  turned.

### Fast updates (Ycode design)

Goal: under 2 s from a save to new pixels for a body change in a small
file, without an app rebuild or relaunch.

**Mechanism: one long-lived host per preview device; each edit compiles a
new payload and the host loads it next to the old ones.** The whole
module is recompiled into the payload (not just the edited file), and the
host rebuilds every shown view from the new image's factories. Why:

- *Rebuild and relaunch the app* (what the macOS path does): seconds of
  build plus an app launch on a simulator that takes 2–3 s just to open an
  app on the reference host, and the launch costs a SpringBoard round trip.
- *Dynamic replacement* (`@_dynamicReplacement` of `body` in a new image,
  with the module built `-enable-implicit-dynamic`): keeps state, but only
  bodies of existing declarations can change; added properties, types or
  stored state need the fallback anyway, and the original build must be
  made with the dynamic flag. More moving parts for a narrow case.
- *Only the edited file in the payload*: the file's types are used by the
  other files and vice versa; a library of the other files would need the
  edited file's interface fixed. A small module compiles whole in under a
  second, so the whole module is the simpler unit.
- A new image per edit gives a clean slate: type metadata, conformances,
  statics of the new code; the old images stay loaded (unloading an image
  whose types SwiftUI may still hold is unsafe). Objective-C class names
  of the user's `NSObject` subclasses repeat across images; Swift code
  reaches its own image's classes directly, so only name lookups
  (`NSClassFromString`, storyboards) are ambiguous. View state resets on
  every update, as after a relaunch.

**Decisions** (`PreviewUpdatePlanner.decide`, from the previous and the
current inputs: destination, module, linked or not, hashes of the
module's Swift files and of its resources, a hash of the exported
previews, the regions; and the host's state):

| Change | Update |
|---|---|
| nothing | none |
| only the canvas layout (selection, Grid, variants, settings, zoom of tiles) | **relayout**: a new plan for the loaded payload, no compile |
| Swift sources or the previews | **reload payload**: compile, upload, host loads it |
| no host, host failed or exited, another device | **relaunch host** (and compile when needed) |
| the host has loaded 40 payloads | relaunch host (the old images are released with the process) |
| resources changed; the target is linked from a package (dependencies or resources) | **rebuild** (the fallback; on the simulator path it is reported as "cannot run on the simulator yet", see Open questions) |

A live canvas waits 0.15 s after a save (not 0.8 s as the macOS path) and
a newer update supersedes an older one (the older one's result is dropped).
While an update runs the tabs show a spinner and the status reads
"Updating…"; the last picture stays. A failed compile keeps the last
picture and shows the banner (§Canvas).

### Live canvas

- The canvas shows **tiles**: each the region of the preview device's
  stream (`display-stream.md`, the same connection the device window uses,
  `RemoteDisplayLink`) cut out of the picture, shown at the preview's own
  size times the zoom, captioned with the preview's tab title and the
  variant. Tiles keep the device's arrangement: rows as on the screen.
  Fit (the default zoom) shows every tile, at most 100 %.
- **Which tiles** (Ycode decision): Grid → every preview of the file;
  Variants → the selected preview in each variant of the chosen kind
  (Color Scheme: light, dark; Orientation: portrait, landscape left;
  Dynamic Type: xSmall, large, xxxLarge, accessibility1, accessibility3,
  accessibility5); otherwise the selected preview (after a pinned one).
  Canvas settings switches set the base variant: Color Scheme → dark,
  Orientation → landscape left, Dynamic Type → accessibility1.
- **Live** (the default): the mouse is a finger on the tile: down, drag
  and up become touches at the matching device points (`display-stream.md`
  §5.1), so the preview reacts as on the device. **Selectable**: clicks do
  not reach the device; a click selects the tile's preview and reveals its
  `#Preview` line in the editor (Ycode decision: the reference's
  selectable mode is not specified beyond its button). On a visionOS
  preview device (the stream's hello says `spatial`) the mouse is the gaze
  and a right-hand pinch instead (Option: both hands, Shift: depth;
  `visionos.md` §5.5.8 item 7).
- **Pin** (a pin button left of the header tabs, Ycode decision): pins the
  selected preview; while pinned, the pinned preview stays on the canvas
  next to the focused file's selected preview, also when another file of
  the same module is focused (the payload exports the focused file's
  previews, then the pinned one). Clicking the pin again unpins.
- **Device** (the bottom-left pop-up): "Automatic – <device>" is the run
  destination when it is a Ycode simulator, else the first phone of
  Settings ▸ Simulators. The Devices section lists every Ycode simulator
  row and, after them, every other device type a configured runtime boots
  (Ycode decision: previews look at sizes the run destinations leave out;
  `run.md` offers one iPhone per runtime, so "iPhone 18 Pro (Ycode) 27.1"
  is a preview device only), titled "<type> (Ycode) <runtime version>",
  device directory `<device name>-<type>-<version>` plus `-previews`.
  Choosing one moves the previews to its preview device.
- **Errors**: compile errors show a red banner over the last picture
  ("Compiling the preview failed"), one line per error (up to three),
  `File.swift:line: message`; a line with a position is a link that opens
  the file at that line (mapped back through the copies' line maps,
  including errors inside a `#Preview` body). A host failure shows "The
  preview host failed" with its message. With no picture yet, the error
  card replaces the canvas as before.
- **Capture** copies the selected tile's pixels to the pasteboard.
- **Starting** shows the spinner and the launcher's phase: "Booting the
  preview device", "Restoring the preview device", "Launching the preview
  host".

### Measurements

Reference hosts (2026-10-29): the Mac (M-series, Swift 6.4, Xcode 27.1
SDK; load average 300–600 from other agents' jobs during these runs) and
the simulator host on the same LAN, iPhone 18 Pro on iOS 27.0 (load 20–100
from other agents' boots). `LivePreviewEndToEndTests` prints these; times
in seconds.

Live previews, iPhone 18 Pro (Ycode) on the 27.1 runtime, through the IDE
(`LivePreviewEndToEndTests`, sample iOS app, two `#Preview`s, a body edit
per save):

| Step | Time |
|---|---|
| Save → host `ready` (body edit, 7 edits) | 0.57–0.68 s (median 0.63) |
| … of which: payload compile | 0.51–0.62 s (0.50–1.26 s in a run at Mac load ≈ 500) |
| … upload (payload + plan, one ssh call on the shared connection) | 0.02 s |
| … host loads the payload and builds the views (`load`) | 0.02–0.05 s (host's own figure 16–450 ms) |
| Save → first new picture in the canvas | 0.59–0.70 s by the stream's first frame after `ready`; 0.78–0.99 s (median 0.84) by a changed tile picture as the test sees it |
| Tap on the Live tile → changed tile | within 0.1 s of the release in the test's polling |
| First preview, device restored from its save (resume → picture) | 15.8 s: device start 11.5 s (restore to home 11.4 s), host compile 3.2 s (warm module cache), load 0.25 s |
| First preview while every boot slot was taken by other jobs | 424–446 s (slot waits of 210–411 s, then restore or cold boot) |
| Cold boot of the preview device (snapshot discarded) | home 125.7 s, host running 208 s after `ycode-simd` started |
| First boot of a new preview device | home 345.5 s, host running 438.7 s (host load 100–145) |
| Stop → device saved | 8.6–21 s |

The target (under 2 s from save to new pixels for a body change in a
small file) holds with margin; the compile is most of it.

macOS (`MacPayloadPreviewTests`, one-file package module, three previews,
light and dark):

| Path | First preview | Refresh after an edit |
|---|---|---|
| SwiftPM host (before) | 16.1 s | 5.6 s |
| Payload in the Mac host | 15.4–15.9 s (cold module cache and host build) | 0.60–1.20 s (compile 0.51–1.10 s, render 0.08–0.10 s) |

## The macOS host

Generated under `~/Library/Developer/Ycode/DerivedData/Previews/<module>/`
(never in the user's project) as a SwiftPM package with one executable
target `YcodePreviewHost` (macOS 14). The folder is kept between
refreshes: files are rewritten only when their text changed (stale ones
are removed), so the build directory stays warm and rebuilds are
incremental.

Two ways to reach the module:

- **Sources** (package targets without dependencies or resources;
  project application/framework/library targets): the module's Swift
  sources are copied in (as `<n>_<File>.swift`), with every `#Preview`
  block replaced by spaces (line numbers kept) and files containing
  `@main` left out. The preview wrapper views are appended to the copy of
  the previewed file, so they see its `fileprivate` declarations.
- **Linked** (package targets with dependencies or resources): the host
  depends on the user's package (`.package(path:)`) through a library
  product that contains the target, and imports the previewed file's
  imports plus `@testable import <Target>`; the build enables
  testability (`-enable-testing`, `ENABLE_TESTABILITY = YES`).
  `Bundle.module` works because the target is built normally with its
  resource bundle. Without such a product: "Unsupported target kind: …
  no library product contains it". Previews cannot use the file's
  `private`/`fileprivate` declarations in this mode.

Generated code:

- One wrapper view per preview: `struct __YcodePreview<i>: View`. For a
  macro, lines of the body that start with `@Previewable ` become stored
  properties (without the attribute) and the rest is `body` (per Apple's
  documentation of `@Previewable`); a provider's `body` is `X.previews`.
- The entry point renders each wrapper in an `NSHostingView` inside a
  borderless window that is never ordered on screen (activation policy
  `prohibited`), for each requested color scheme (`light`, `dark`: the
  hosting view and window get the matching appearance and the view
  `.environment(\.colorScheme, …)`), sized to the fixed size or the
  fitting size (320×240 when that is empty or larger than 4000), and
  writes `<index>-<scheme>.png` into the folder given as the first
  argument. The second argument lists the schemes (`light,dark`).

Module resolution:

- Packages: the target folder `Sources/<Target>/` holding the file, read
  with `swift package dump-package`. Executable targets: "Unsupported
  target kind: … is an executable target".
- Projects: the first application, framework or library target whose
  sources phase or synchronized folders contain the file. Otherwise
  "Unsupported target kind: no application or framework target compiles
  <file>".

Build engine (decided from the timings below): package previews always
use SwiftPM (`swift build --product YcodePreviewHost`), for the first
build and every refresh, because its incremental rebuilds are 3–4×
faster; project targets use the swift-build engine (`ycode-swb`'s
`swbuild`) when it is installed, falling back to SwiftPM when it is not
or when it fails without a source diagnostic. A failure reports the first error with
a location, mapped back to the user's file name (`Badge.swift:6: cannot
find 'nope' in scope`). The built host runs once per refresh and exits.

Measured on the reference Mac (M-series, Swift 6.4, one-file module,
three previews), build plus run:

| Engine | First preview | Refresh after an edit | Refresh, nothing changed |
|---|---|---|---|
| swift-build | 18.2 s | 15.3 s | 3.8 s |
| SwiftPM | 16.1 s | 5.6 s | — |

**Payloads on the Mac (since 2026-10-29).** Sources modules no longer
build the SwiftPM host per refresh: the payload generator (platform
`.macOS`, wrappers returning `NSViewController`s) and `PreviewCompiler`
make a payload (deployment target: the macOS SDK's version), and a
long-lived Mac host process (`PreviewMacHost`, built once under
`hosts/macOS-<target>-v<n>/`) reads one JSON request per line on standard
input (`generation`, `payload`, `output`, `schemes`, `items` with fixed
sizes or 0 × 0), `dlopen`s the payload, renders each item's controller in
an offscreen borderless window per scheme (appearance aqua / darkAqua;
size as before) to `<index>-<scheme>.png`, and answers `YCODE-PREVIEW
ready|error <generation> …`. One host per work directory; it is restarted
after 40 payloads or when it exits. Linked modules keep the SwiftPM host.
`YCODE_PREVIEWS_BUILT_HOST=1` (or `useBuiltPreviewHost`) restores the old
path.

**Host lifetime (Ycode design, 2026-10-30).** A preview host never
outlives its parent (Ycode, or the test process), and no wait on a preview
child is unbounded. A full Mac test run once hung for 86 minutes on a Mac
host that never answered and never exited, so these rules hold:

- The Mac host ends at the end of its standard input, at SIGTERM (it
  restores the default action after AppKit starts), and when its parent
  goes away: it remembers its parent's pid at start (ending at once if that
  is already launchd, pid 1) and checks once a second whether it was
  reparented.
- Ycode waits at most `requestTimeout` (120 s) for an answer to one request.
  A host that does not answer in time, or whose output ends, is stopped and
  the refresh fails with "The preview host ended or did not answer in 120 s".
  A write to a host that is gone fails with EPIPE (the pipe is set to
  `F_SETNOSIGPIPE`), never with a SIGPIPE that would end Ycode.
- Stopping a host closes its input, then sends SIGTERM, then SIGKILL, each
  after a short grace (2 s); the host registry's lock is not held meanwhile.
  Ycode stops every host at exit.
- The SwiftPM host path bounds each child too: a build or a run of the built
  host that takes longer than its limit (600 s for a build, the request
  timeout for a run) gets SIGINT, SIGTERM, then SIGKILL, and fails with
  "… did not finish in N s and was stopped".
- Tests: every preview suite has a time limit, and the heavy ones carry a
  check that fails a test when any child named `YcodePreview…` is still
  running after it (the child is then killed).

## Canvas

- View ▸ Editor ▸ Canvas (⌥⌘↩, reference-ui.md §1; also the toolbar's
  Canvas segment) toggles a canvas pane right of the editors of the
  current tab.
- Placement: beside the editor, or below it when the editor area is
  narrower than 760 points; it moves again when the width changes
  (`reference-ui-4.md` §10.1, §17.1; the 760-point threshold is Ycode's
  choice).
- Until the first build the canvas shows a "Canvas paused" capsule with a
  resume button; nothing builds before resume (`reference-ui-4.md` §10.2).
- Header: one tab per preview, titled with the `#Preview("name")` name,
  else the view type at the start of the body; a spinner while building,
  then an eye icon. Clicking a tab selects that preview (§10.3). Live
  canvases have the pin button left of the tabs.
- Content: the selected preview in a device frame drawn by Ycode (macOS
  path), or the live tiles (§Live canvas).
- Bottom bar: left the device pop-up, Live (selected by default),
  Selectable, Grid, Variants (macOS path: light and dark side by side;
  live: cycles Color Scheme → Orientation → Dynamic Type → off); centre the
  zoom pop-up (Fit, 25–200 %); right Capture, Device and Canvas Settings
  (§10.5, §17.2).
- Device menu: "Automatic – <device>" (checked), Recent, the generic
  classes with grey secondary text, Devices, More ▸ (§17.3). Canvas
  settings: switches Display, Color Scheme, Contrast, Control Borders,
  Orientation, Dynamic Type, all off by default (§17.4); Color Scheme,
  Orientation and Dynamic Type change the live tiles' traits.
- Errors (macOS path, or before the first live picture): an error card
  ("Preview build failed" and the first diagnostic); "No Previews" for
  files without any.
- After resume, every save of the focused file refreshes (macOS: after
  0.8 s without another save; live: 0.15 s). A newer refresh supersedes
  an older one.

## Linux

`frameworks/swiftui` (OpenViews) renders views since round R5: its
headless back end lays a view out, lowers it to a display list and
rasterises it with ThorVG on the CPU, without a window or a GPU.

`ycode preview --list <file.swift>` prints the file's previews (line, name,
kind, traits) on any platform. `ycode preview --render <out.png>
<file.swift> [--name N]` renders one `#Preview` (Ycode design,
`YcodePreviews/PreviewRenderHost.swift`):

- It writes a small package to `$XDG_CACHE_HOME/ycode/preview-render`
  (default `~/.cache/…`): the file with every `#Preview` blanked (lines
  kept, so build errors point at the file's lines) and `@main` removed, a
  `main.swift` that evaluates the preview's body as a view builder, and a
  manifest that depends on the port by path (`$YCODE_OPENVIEWS`, else
  `frameworks/swiftui` found above the working directory, the `ycode`
  executable or the file). On macOS the file's `import SwiftUI` is
  rewritten to the port's renamed module, `OpenViews`.
- It builds that package (`swift build`; unchanged files keep their dates,
  so later renders rebuild only the file) and runs it; the program writes
  `ImageRenderer.pngData` (scale 2, opaque) to the output path, which
  `ycode` prints.
- Size: `.fixedLayout(width:height:)` → that size; `.sizeThatFitsLayout` →
  the view's ideal size; otherwise 393 × 852 points.
- Status: 0 on success, 1 when the preview does not build or render, 3
  when it cannot (a `PreviewProvider` preview, or no port found).
  Measured on the x86-64 workstation: about 11 s for the first render
  (building the port), about 3 s after an edit.

## Open questions

- The reference's live and selectable modes beyond their buttons, the
  pin's placement, and the variants menu's exact items (Ycode decisions
  above).
- Previews of package targets with dependencies on the simulator path:
  the dependencies would have to be built for the simulator SDK and linked
  into the payload (the macOS path links the package instead).
- Resources (asset catalogs, bundled files) on the simulator path: the
  host has none of the app's resources; images by name do not load.
- watchOS previews follow the watchOS simulator rounds.
- A poster's GPU hang (`WeatherPoster`, iOS 27.0 and 27.1) can stop
  the simulator's screen after a boot (`specs/simulator/app-launch.md`
  §3.9, open). The earlier 27.0 freeze at a new app's launch is fixed
  there (the vCPU pool, agents ICON-FREEZE and ICON-FREEZE2).

## Evidence

- `#Preview` forms and traits, `PreviewProvider`, `@Previewable`: Apple's
  public SwiftUI documentation (level 1); macro declaration shapes
  (content, `UIViewController` and `UIView` bodies): open-source
  swift-syntax and the public interface (level 1).
- Offscreen rendering and appearances, trait overrides, `dlopen`: public
  AppKit / UIKit / SwiftUI / POSIX API (level 1).
- `/tmp` of the device on the simulator host, launching an app:
  `specs/simulator/app-install-launch.md` (Ycode's own spec).
- Timings: measured by `PreviewDepthTests` and `LivePreviewEndToEndTests`
  (level 3, Ycode itself).
- Every live-preview design choice (payloads, plan, host, planner, screen
  and canvas layout, pin, selectable reveal, banners, preview devices):
  Ycode decisions, tested by `YcodePreviewsTests`, `LivePreviewCanvasTests`
  and `PreviewPayloadCompileTests` (payloads and hosts for iOS and visionOS
  compile with the installed SDKs; errors map to the `#Preview` line).
- The iOS 27.0 freeze and its fix: Ycode's own thread reports and
  display-stream screenshots on the simulator host (level 3, Ycode
  itself; `specs/simulator/app-launch.md` §3.9).
- Host lifetime (parent watch, request timeout, stop escalation, bounded
  SwiftPM children): Ycode decisions on public POSIX API (`getppid`,
  `poll`, `kill`, `F_SETNOSIGPIPE`; level 1), tested by
  `MacPreviewHostLifetimeTests` and the `.previewHostCheck` trait.
