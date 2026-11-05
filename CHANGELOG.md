# Changelog

Notable changes to Ycode are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The release workflow takes each release's notes from this file.

## [Unreleased]

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

[Unreleased]: https://github.com/MarcoDotIO/Ycode/compare/v1.0.0-beta.2...HEAD
[1.0.0-beta.2]: https://github.com/MarcoDotIO/Ycode/releases/tag/v1.0.0-beta.2
[1.0.0-beta.1]: https://github.com/MarcoDotIO/Ycode/releases/tag/v1.0.0-beta.1
