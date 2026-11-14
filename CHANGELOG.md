# Changelog

Notable changes to Ycode are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The release workflow takes each release's notes from this file.

## [Unreleased]

## [1.0.0-beta.3] - 2026-11-14

The Linux IDE gains the Organizer, Interface Builder documents, SwiftUI previews and debugging on a simulator, and both IDEs
went through more rounds of UI fidelity review against Xcode 27.1. Simulators boot faster and are easier to set up and run
from the IDE. Ycode also has its own Objective-C runtime, the groundwork for running macOS programs on Linux.

### Added

- **The Linux IDE, Organizer (#77), Settings ▸ Accounts (#74) and conflict editor (#75):** Window ▸ Organizer lists archives
  and their details. Accounts is in Settings. A merge conflict opens the macOS IDE's merge alert and merge sheet; both IDEs
  also have Integrate ▸ Merge… and a branch row menu.
- **The Linux IDE, Interface Builder documents (#79) and SwiftUI previews (#78):** storyboards and xibs open in the Interface
  Builder editor, and SwiftUI previews show in the canvas. The Library has the full UIKit set (80 storyboard and 79 xib object
  kinds) with an Attributes inspector for each, in both IDEs (#84). UIKit previews run on a paired simulator host; the macOS
  IDE asks for a simulator instead of failing.
- **The Linux IDE, debugging on a simulator (#76):** Run on a simulator host on the same computer runs under the debugger, and
  Stop works during the build and the run. Run destinations are grouped by My Computer and each simulator host.
- **Simulators, setup and use (#80):** the setup windows are a paged assistant on macOS and Linux, with a checklist for
  what a first run needs. The device window has floating control capsules and inspector cards, shows boot progress and tells
  you when it restarts a running device. The aarch64 release's simulator tree now runs on a plain Ubuntu 24.04 host.
- **Simulators, UIKit look and feel (#83):** input keeps its timing, still screens are lossless, and a window at 1:1 scale is
  pixel-exact on macOS and Linux. 167 of 211 measured values match; the others are explained in the specification.
- **An Objective-C runtime of our own (#86):** written in Rust, with `objc_msgSend` and the method cache in arm64 assembly. It
  is faster than or tied with upstream objc4 on every benchmark in our suite. The Swift runtime, Concurrency and
  FoundationEssentials already run under `ycode-simd --macos`: groundwork for macOS programs on Linux (#87, beta 4), not yet
  a feature you can use.
- **File icons:** the project navigator, jump bar, merge sheet and Open Quickly show each language's official logo as a
  single-colour vector glyph, tinted per file type as Xcode tints its own glyphs and white on a focused selected row. The
  logos come from the MIT-licensed [devicon](https://github.com/devicons/devicon) set (see
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)); Swift shows its bird alone and Python its outline. Markdown, JSON,
  images and folders use Ycode's own glyphs. The project row and the toolbar's title area show a small Ycode mark, which
  becomes a progress ring that fills with the build's progress.
- **The Linux IDE, Open Quickly** (⇧⌘O), with the macOS IDE's layout.

### Changed

- **UI fidelity (#81):** a council of three independent judges scored the IDEs against Xcode 27.1 in rounds 3 to 10. Round 10
  scored 8.3, 9.0 and 8.9 (mean 8.73; round 8: 8.80, round 9: 8.43 with its new steps), and round 10's rows 236–252 were
  fixed afterwards. The rounds covered the merge sheet, Settings (the full Theme list, grouped cards, a 710 × 452 window),
  the device window (Zoom to Fit for every device, the iPad's tablet outline, an "iPadOS" subtitle, the Apple Watch drawn at
  its real case size with its crown and side button), the editor (scroll momentum and edge stretch, text wrapping, the
  minimap, the caret kept per file, symbol highlighting only in code), the issue capsule, the coding assistant button, Open
  Quickly, the jump bar, the inspector slide (the editor keeps its top line) and restoring panes, splits, expansion and the
  scroll position when you reopen a workspace.
- **The Linux IDE's chrome** is drawn as on macOS: a hidden title bar with the window's buttons, the menu bar on demand, and
  matching toolbar, debug area, Welcome window, Settings and wizard. The inspector slides with the macOS timing (see Known
  limitations for its frame rate).
- **Simulator boot (#44):** device runs now spin briefly on fine locks and raise host threads at fast traps. The home screen
  comes up in about 23.3 s (median) on our reference arm64 Linux host, 1.09 times Xcode's simulator, or about 18.6 s once
  adjusted for per-core speed. A stuck GPU submission no longer stops other clients, and the system UI never loses GPU access.
- **Linux builds:** `ycode build` builds Swift packages with SwiftPM, in the Flatpak too (#73), and
  `-showBuildSettings` works for package schemes (#72).

### Fixed

- **Previews:** they no longer crash after a project folder moves. The module cache is tied to the folder's real path, is
  emptied after a compiler crash, and the build is retried once.
- **Child processes:** every helper process Ycode starts uses close-on-exec pipes and no blocked signals, and a cancel or
  timeout stops the helper's whole process group. This fixes a Stop that left a child running and an assistant hang.
- **Asset compiler:** an app icon set without images warns instead of stopping `ycode`.
- **Markdown and JSON files** are no longer sent to the Swift language service, so opening one no longer shows a line-1 error
  and an error count. The File inspector shows their type ("Default - Markdown", "Default - JSON") and, for resource files,
  the Tags and Localization sections.
- **The Linux IDE, closing a window:** closing a second window (for example the runtime wizard) no longer crashes the
  windows still open with NVIDIA's driver on Wayland; all windows now share one Vulkan instance.

### Known limitations

- On Linux, the inspector slide and file selection draw fewer frames than on macOS, because the OpenViews window is rebuilt
  every frame: the slide shows two or three positions and selection takes about 0.3 s.
- Ycode shows no live warning on an unbuilt project where Xcode shows one, so the jump bars in a split editor shorten
  later than Xcode's.
- Scroll flicks: Xcode's overscroll and momentum differ between a Retina and a standard display for the same input, so
  Ycode's are not yet tuned to both; this is studied in beta 4.
- Selecting a file takes about 0.4 s to show it on a busy Mac, against about 0.2 s in Xcode. Markdown files open as text;
  Xcode renders them.
- On macOS the gap before the toolbar's overflow button is wider than Xcode's (Ycode keeps the system's overflow item and
  its animation). On Linux the Welcome window opens where the compositor puts it.
- Moved to the 1.0.0-beta.4 milestone: #90 Borrow xtool's iOS signing and device-install functions; #89 macOS apps on Linux,
  stage D (windows and Ycode's AppKit subset); #88 stage C (the process model); #87 stage B (Foundation command-line
  programs); #85 Simulator display stream over Wi-Fi; #64 and #63 hover, press and focus states; #58 and #57 Liquid Glass
  materials and scroll-edge effects; #54 OpenViews: the next milestones for the Linux IDE; #50 Remote simulator: debugging
  and an embedded device view from an x86-64 Linux PC; #43 Signing, distribution and physical devices.
- Simulators are still slower than Apple's on a Mac, and parts are missing: see [docs/SIMULATOR.md](docs/SIMULATOR.md).

## [1.0.0-beta.2] - 2026-11-05

The Linux IDE catches up with most of the macOS one: debugging, source control, tests, language features, the structured
editors, Settings and the coding assistant. Simulator runtimes can now be fetched and set up from the IDE, and the macOS
IDE looks closer to Xcode 27.1.

### Added

- **The Linux IDE, debugging:** Swift packages debug through `lldb-dap`: breakpoints in the gutter, the Debug and Breakpoint
  navigators, the variables view, the `(lldb)` console, the debug bar and the Debug menu (F6, F7 and F8 step). The
  breakpoint editor sets conditions, ignore counts, actions and automatic continue. There are also symbolic, Swift error and
  exception breakpoints, watch expressions, Edit Value, View Memory, and disassembly for frames without source.
- **The Linux IDE, source control:** the Source Control navigator, the commit editor and Integrate ▸ Commit…, branches,
  tags, stashes, history, push and pull, status letters in the project navigator and change bars in the gutter.
- **The Linux IDE, tests:** the Test navigator; running all tests, a suite or one test from the navigator or the gutter's
  diamonds; failures shown at their lines; and the Report navigator with each run's results. Works for Swift packages with
  XCTest or Swift Testing.
- **The Linux IDE, language features:** Quick Help (Alt-click, as a popover and in the inspector), Jump to Definition,
  rename, references, a two-level call hierarchy, the Symbol navigator, and the file's declarations in the jump bar, all
  through SourceKit-LSP.
- **The Linux IDE, editors and Settings:** the property list editor (XML, binary and OpenStep), the asset catalog and
  String Catalog editors, and the rest of Settings: General, Appearance with theme editing, Behaviors, Navigation,
  Notifications, Editing, Shortcuts, Source Control and Locations.
- **The Linux IDE, coding assistant:** the Coding Assistant pane, with the macOS IDE's conversations, providers and
  proposal review. An accepted change goes into the editor and stays unsaved until you save it.
- **Simulator runtimes:** a wizard lists the runtimes you have, gets one, copies it to a simulator host and prepares that
  host (macOS: Settings ▸ Components, the run destination menu and the first launch; Linux: Window ▸ Downloads and the first
  launch). It gets a runtime only when you ask, after showing the exact command: on a Mac with Xcode through
  `xcodebuild -downloadPlatform`, otherwise by downloading it from Apple itself, or from a copy exported on a Mac. The same
  from a terminal: `ycode runtime list|available|download|import|xcodebuild` and `ycode sim runtimes check|script`. See
  [docs/SIMULATOR-LINUX.md](docs/SIMULATOR-LINUX.md) §5.1.
- **Breakpoints, both IDEs:** actions that `lldb-dap` does not run itself (debugger commands, sounds, log messages with
  `%B` or `%H`, automatic continue) are now run by Ycode at the stop.
- **Packages:** Ycode is on [FlatPark](https://flatpark.org/apps/io.github.MarcoDotIO.Ycode/). Installed from there,
  `flatpak update` brings new releases.
- **Packages:** the Flatpak includes 7-Zip (`7zz`, built without its RAR code), which getting a runtime directly from
  Apple uses to read the runtime's disk image.
- **Project infrastructure:** a release checklist ([docs/RELEASING.md](docs/RELEASING.md)) with a check that the changelog
  and the Flatpak metadata agree, and a layout probe that measures the macOS IDE's spacing on any Mac
  ([docs/LAYOUT-PROBE.md](docs/LAYOUT-PROBE.md)).

### Changed

- **Packages:** the Flatpak is built on the freedesktop 26.08 runtime (glibc 2.44), and its tarballs need that runtime or a
  host with that glibc or newer.
- **The macOS IDE's look**, after side-by-side reviews against Xcode 27.1: the editor runs under the toolbar with blurred
  bars over the text, the default light theme takes measured colours (dark is unchanged), the navigator has Xcode's
  selection band and folder icons, the inspector is 260 points wide and slides with Xcode's timing, and the File
  inspector, the minimap (one bar per token), the Welcome window and the toolbar's overflow order follow Xcode's. The text
  springs back at the top, and a mouse wheel that scrolls by lines moves the text by the wheel's own distance. Stop, Go
  Back and Go Forward are disabled while they cannot act.
- **The macOS IDE, opening files:** a workspace gets one window, a file opened from elsewhere opens in its workspace's window
  with its navigator row selected, and images open in an image viewer with their own File inspector.
- **Asset catalogs:** removing a set or folder moves it to the trash instead of deleting it.
- **Language features:** after you change a project's or workspace's scheme or run destination, SourceKit-LSP restarts for
  it, so completion and live issues follow what you build.
- **The Linux IDE:** Ctrl+Y is Debug ▸ Deactivate Breakpoints, as ⌘Y is on macOS; Redo stays Ctrl+Shift+Z. Settings uses
  the macOS IDE's two-column layout, and a light or dark appearance chosen there covers the menu bar and pop-ups too.
  Pop-up menus stay inside the window, and Copy buttons and items (Quick Help, console rows, the runtime wizard) put their
  text on the system clipboard.

### Fixed

- **The Linux IDE:** Chinese, Japanese and Korean text was drawn as nothing on systems whose only CJK fonts are CFF (such as
  Noto Sans CJK).
- **The Linux IDE, input methods:** now tested with real ones, which beta 1 had not done: IBus and Fcitx 5, on X11 and
  Wayland, with Chinese (Cangjie 5, Pinyin) and dead keys (US international), in the source editor and in text fields.
  The candidate window now opens at the caret; before, it stayed where the caret was when the editor or field got focus.
  On X11 the text being composed now shows at the caret as on Wayland, instead of only in the input method's window.
  Keys that reach a text field while an input method composes no longer edit, submit or leave it.
- **The macOS IDE on other macOS versions:** on macOS 26 the navigator no longer floats as a panel inside the window; on
  macOS 15 the inspector is 260 points wide and the variables bar's controls sit inside it; on macOS 27.0 the toolbar's
  activity icon and the navigator filter's toggles are where they are on 27.2.
- **The macOS IDE:** a file opened while its workspace was still opening now waits for that workspace's window; a minimap
  without line wrapping no longer overflows; box-drawing, block and braille characters from a fallback font take one
  column each.
- **Both IDEs:** a module name after `import` is no longer coloured as a type; `.editorconfig` settings are found for files
  opened through a symbolic link; running one test of a Swift package no longer also runs tests whose names start with
  its name (`testAdd` ran `testAddsMore`); the console's Copy Row items no longer take output whose lines end in CRLF
  (a program run in a pseudo-terminal) as one row.
- **Packages:** after the Linux IDE's window closed, a helper process kept the Flatpak's instance running. The Flatpak ran
  none of the host's tools (Swift, git, SourceKit-LSP) when `~/.profile` had a line only bash can read, as swiftly's
  installer adds on systems where `sh` is dash; it now runs your own login shell. In the aarch64 package, `ycode-airc`
  (the simulator's Metal shader translator) could not load its bundled LLVM.
- **`ycodebuild` on Linux:** `-showBuildSettings` for a macOS or iOS project stopped with "Could not initialize build
  system" when Swift came from swiftly or ran through the Flatpak. It now prints the project's settings and warns that
  those that come from an SDK that is not installed (`ARCHS`, `SDK_*`, `PLATFORM_*`, the bundle layout) are left out.

### Known limitations

- The Linux IDE builds, runs, tests and debugs Swift packages only. It has no Interface Builder documents, SwiftUI
  previews, Organizer, Settings ▸ Accounts or source-control conflict editor yet, and it cannot debug on a simulator.
- Input methods on Linux: on X11, Fcitx 5 keeps the text being composed in its own window unless its XIM "on the spot"
  option is on, and an input method's own shortcuts come first (IBus Pinyin and Fcitx 5 take Ctrl+Shift+F, Find in
  Workspace).
- The macOS IDE's spacing is measured on macOS 27.2, 27.0, 26.6 and 15.6 and matches its specification, except that
  Device Hub's Hide Sidebar button on macOS 26 ends 5 points before the sidebar's edge instead of 7.
- Physical devices are listed only, and signing and distribution are partial (on Linux, not there yet).
- Simulators are slower than Apple's on a Mac, and parts are missing: see [docs/SIMULATOR.md](docs/SIMULATOR.md).

## [1.0.0-beta.1] - 2026-11-04

The first public beta, and the first release with installable packages. Everything below is new to users, since there were
no earlier releases. [The README](https://github.com/MarcoDotIO/Ycode#what-works-today) says how mature each part is.

### Added

- **Packages:** a macOS disk image, and Flatpak bundles for x86-64 and arm64 Linux.
- **Project files:** reading and writing `.pbxproj`, `.xcworkspace`, `.xcscheme` and `.xcconfig`, with byte-identical round
  trips on our test corpus, and build-setting resolution that matches `xcodebuild -showBuildSettings` on that corpus.
- **Command-line tools:** `ycode`, `ycodebuild` (an `xcodebuild`-compatible command line), asset catalog and String Catalog
  compilers, `ycode mcp` for coding agents, and Gauge (`ycode profile`).
- **The macOS IDE:** workspace window, navigators, source editor, build, run and debug, language features through
  SourceKit-LSP, plist, asset and String Catalog editors, Interface Builder documents, SwiftUI previews, tests, source control,
  a coding assistant and Settings. All experimental.
- **The Linux IDE:** the workspace window on OpenViews, our SwiftUI implementation. It can open projects, workspaces and
  packages, browse and search them, edit and save files (undo, find and replace, crash recovery), and build and run
  Swift packages, with build errors and SourceKit-LSP's live issues shown in the editor and code completion on
  request (Ctrl+Space). All experimental.
- **Simulators (experimental):** iOS, iPadOS and watchOS devices, and a partial visionOS, on arm64 Linux with KVM, with viewers
  for macOS and x86-64 Linux. You supply the simulator runtime; none of Apple's software is included.
- **Open frameworks (partial):** Contacts, EventKit, HealthKit, HomeKit, StoreKit, WeatherKit and SwiftUI as Swift packages
  that build on Linux, plus a USD library, and `ycode-scene`, the Scene Composer's command-line core.
- **Project infrastructure:** CI, a release workflow, a public-content scan, and community documents.

### Known limitations

- The Linux IDE has a Settings window, live issues and code completion from SourceKit-LSP, but no hover, Jump to
  Definition, source control or debugger interface yet. Input methods are wired up but untested with a real one.
- Spacing and control positions are tuned on macOS 27.2; earlier versions of macOS lay out some controls differently.
- Physical devices are listed only, and signing and distribution are partial.
- Simulators are slower than Apple's on a Mac, and parts are missing: see [docs/SIMULATOR.md](docs/SIMULATOR.md).

[Unreleased]: https://github.com/MarcoDotIO/Ycode/compare/v1.0.0-beta.3...HEAD
[1.0.0-beta.3]: https://github.com/MarcoDotIO/Ycode/releases/tag/v1.0.0-beta.3
[1.0.0-beta.2]: https://github.com/MarcoDotIO/Ycode/releases/tag/v1.0.0-beta.2
[1.0.0-beta.1]: https://github.com/MarcoDotIO/Ycode/releases/tag/v1.0.0-beta.1
