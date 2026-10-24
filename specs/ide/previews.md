# SwiftUI previews (macOS), Ycode's own design

Ycode module: `YcodeUI` (`PreviewDiscovery`, `PreviewRenderer`,
`PreviewCanvasController`, `WorkspaceWindowController`). Evidence is
limited to Apple's public `#Preview` / `PreviewProvider` documentation and
the open-source swift-syntax macro definitions; Xcode's own preview
machinery was not studied and is not imitated.

## Discovery (lexical)

In the focused Swift file, outside comments and string literals:

- `#Preview` followed by optional parenthesized arguments and a `{ … }`
  body. The first argument, when a string literal, is the name; unnamed
  previews are `Preview`, `Preview 2`, … in file order. A
  `traits: .fixedLayout(width: W, height: H)` argument fixes the render
  size; any other traits are ignored (fitting size).
- `struct X: … PreviewProvider …`: one preview named `X`, rendering
  `X.previews`.
- Previews are listed in line order.

## The preview host

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
  then an eye icon. Clicking a tab selects that preview (§10.3).
- Content: the selected preview in a device frame drawn by Ycode.
- Bottom bar: left Live (selected by default), Selectable, Grid, Variants
  (Variants shows light and dark side by side); centre the zoom pop-up
  (Fit, 25–200 %); right Capture, Device and Canvas Settings (§10.5,
  §17.2). "Live" is a selection state only (see the open question below).
- Device menu: "Automatic – <device>" (checked), Recent, the generic
  classes with grey secondary text, Devices, More ▸ (§17.3). Canvas
  settings: switches Display, Color Scheme, Contrast, Control Borders,
  Orientation, Dynamic Type, all off by default; Color Scheme selects dark
  rendering (§17.4).
- Errors: an error card ("Preview build failed" and the first
  diagnostic); "No Previews" for files without any.
- After resume, every save of the focused file (after 0.8 s without
  another save) rebuilds and re-renders. A newer refresh
  supersedes an older one.

## Evidence

- `#Preview` forms and traits, `PreviewProvider`, `@Previewable`: Apple's
  public SwiftUI documentation (level 1); macro declaration shapes:
  open-source swift-syntax (level 1).
- Offscreen rendering and appearances: public AppKit / SwiftUI API
  (level 1).
- Timings: measured by `PreviewDepthTests` (level 3, Ycode itself).
- OPEN QUESTION: live (interactive) previews, other traits (orientation,
  size classes), preview variants beyond color scheme, project targets
  with package dependencies, `private` declarations in linked mode, and
  why swift-build edits rebuild slower than SwiftPM (the PIF is
  regenerated each time).
