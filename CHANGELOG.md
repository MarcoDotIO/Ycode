# Changelog

Notable changes to Ycode are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The release workflow takes each release's notes from this file.

## [Unreleased]

### Changed

- **Packages:** the Flatpak is built on the freedesktop 26.08 runtime (glibc 2.44), and its tarballs need that runtime or a
  host with that glibc or newer.

### Fixed

- **The Linux IDE:** Chinese, Japanese and Korean text was drawn as nothing on systems whose only CJK fonts are CFF (such as
  Noto Sans CJK).
- **The Linux IDE, input methods:** now tested with real ones, which beta 1 had not done: IBus and Fcitx 5, on X11 and
  Wayland, with Chinese (Cangjie 5, Pinyin) and dead keys (US international), in the source editor and in text fields.
  The candidate window now opens at the caret; before, it stayed where the caret was when the editor or field got focus.
  On X11 the text being composed now shows at the caret as on Wayland, instead of only in the input method's window
  (Fcitx 5 keeps it in its own window unless its XIM "on the spot" option is on). Keys that reach a text field while an
  input method composes no longer edit, submit or leave it.
- **Packages:** after the Linux IDE's window closed, a helper process kept the Flatpak's instance running.

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

[Unreleased]: https://github.com/MarcoDotIO/Ycode/compare/v1.0.0-beta.1...HEAD
[1.0.0-beta.1]: https://github.com/MarcoDotIO/Ycode/releases/tag/v1.0.0-beta.1
