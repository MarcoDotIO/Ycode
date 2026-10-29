# Ycode architecture and roadmap

## 1. What Xcode 27.1 is made of

The figures come from `tools/inventory.py` → `research/inventory/bundles.json`.
They are metadata only.

The app has 406 Mach-O bundles: 978 MB of code, 297 of them link Swift,
there are about 15,600 Objective-C classes, and about 45,000 Swift nominal
types. 34 bundles (244 MB) are Apple open-source projects.

| Subsystem | Bundles | MB | ObjC classes | Swift types |
|---|---:|---:|---:|---:|
| Debugger (LLDB + DebuggerKit/UI) | 11 | 195 | 536 | 1090 |
| Misc. (codegen, notarization, services…) | 87 | 141 | 1284 | 8822 |
| IDE feature plug-ins (other `IDE*`) | 64 | 73 | 1809 | 2986 |
| AI assistant (`IDEIntelligence*`) | 10 | 64 | 119 | 5003 |
| Testing (XCTest, swift-testing, results UI) | 20 | 50 | 525 | 2834 |
| Swift toolchain libraries (swift-syntax…) | 14 | 50 | 5 | 4427 |
| DVT foundation and UI kit | 38 | 50 | 1565 | 2954 |
| Xcode Cloud | 8 | 48 | 256 | 4852 |
| Interface Builder | 12 | 38 | 2384 | 422 |
| IDE shell (`IDEKit`) | 1 | 36 | 1344 | 1344 |
| SwiftUI Previews | 15 | 33 | 29 | 2512 |
| GPU and Metal tools | 28 | 33 | 1592 | 705 |
| IDE model (`IDEFoundation`) | 1 | 28 | 1225 | 1234 |
| Source editor | 9 | 28 | 286 | 1902 |
| Core ML and Create ML | 28 | 21 | 287 | 1517 |
| Instruments integration | 4 | 15 | 417 | 399 |
| Devices and simulators | 10 | 15 | 121 | 255 |
| Legacy project model (`DevToolsCore`, `Xcode3Core`) | 4 | 14 | 619 | 334 |
| Source control | 3 | 12 | 387 | 617 |
| Language services (SourceKit, completion, index) | 12 | 10 | 19 | 361 |
| Packages (SwiftPM) | 2 | 7 | 134 | 436 |
| Asset catalogs | 11 | 7 | 475 | 31 |
| Build-system clients | 4 | 4 | 17 | 110 |

Lineage: NeXT Project Builder became Project Builder X (the `PBX` classes, the
OpenStep plist project file). That became Xcode 1–3 (`DevToolsCore`,
`Xcode3Core`). Xcode 4 rewrote the product on the `IDEFoundation`/`IDEKit`
plug-in architecture, built on the `DVT*` frameworks. Newer subsystems
(source editor, previews, AI, Xcode Cloud) are mostly Swift. The ObjC core is
still the frame that holds everything together.

## 2. Strategy: reuse what is open, rebuild what is not

| Xcode piece | Ycode approach |
|---|---|
| Build engine (Swift Build, llbuild) | **Reuse** swiftlang/swift-build as a library or service. It reads its own PIF format, so Ycode converts its project model into PIF. |
| Compilers, linker, LLDB | **Reuse** the installed toolchain (`xcrun`). Debug through `lldb-dap` (DAP) or the LLDB SB API. |
| Code intelligence | **Reuse** sourcekit-lsp, clangd, and indexstore-db through LSP. |
| Packages | **Reuse** SwiftPM (libSwiftPM or the `swift package` CLI). |
| Syntax highlighting and formatting | **Reuse** swift-syntax and tree-sitter grammars. |
| Testing | **Reuse** xctest and swift-testing runners. Parse results through `xcresulttool` or our own reader. |
| Simulators and devices | **Shell out** to `simctl` and `devicectl` for the Mac's simulators and physical devices. Apple ships both with documented CLIs. The Ycode simulator on arm64 Linux is our own (`docs/SIMULATOR-LINUX.md`); the IDE drives it over ssh (`specs/ide/run.md`). |
| Project model and pbxproj I/O | **Rebuild** (`YcodeProject`). Started. |
| Workspaces, schemes, xcconfig, build-setting resolution | **Rebuild** from format specs. Swift Build's open xcspecs document the settings. |
| IDE shell: windows, navigators, editors, inspectors, plug-ins | **Rebuild** in AppKit (Swift plus ObjC where needed). |
| Source editor | **Rebuild** on TextKit 2. |
| Interface Builder, asset catalog editor | **Rebuild.** Basic editors exist (see M4). |
| Apple frameworks for apps on Linux | **Rebuild** as open packages in `frameworks/` (see `docs/FUTURE.md`). |
| Coding assistant | **Rebuild** (`YcodeAssistant` + `YcodeUI`): local models (Ollama, llama.cpp), OpenAI (ChatGPT sign-in or API key) and agent CLIs run read-only; changes are proposed and reviewed (`specs/ide/coding-assistant.md`). |
| Instruments UI, Xcode Cloud | Later. These are separate products in their own right. |

## 3. Module plan (`ycode/`)

IDE and project model:

    YcodePlist        OpenStep, XML and binary plist I/O                   [done]
    YcodeProject      pbxproj object graph, typed model, mutations          [done: I/O + views]
    YcodeWorkspace    .xcworkspace, .xcscheme (Xcode-exact XML I/O)         [done: M2]
    YcodeSettings     xcconfig, macro language, levels, derived rules       [done: M2]
    YcodeMachO        Mach-O + dyld shared cache reader (read-only)         [done: read]
    YcodeSubprocess   subprocess runs, the debug-build main-thread guard
    YcodeBuild        PIF generation → swift-build, xcodebuild fallback,    [experimental: M3]
                      diagnostics stream, package resolution, destinations
    YcodeXcodebuild   xcodebuild-compatible engine behind `ycodebuild`      [experimental]
    YcodeLanguage     LSP client (sourcekit-lsp): completion, hover,        [experimental: M5]
                      definition, rename, references, call hierarchy, code actions
    YcodeDebug        DAP client to lldb-dap                                [experimental: M6]
    YcodeAssistant    coding assistant: model providers (Ollama, llama.cpp, [experimental]
                      OpenAI, agent CLIs), OpenAI sign-in, prompts, proposals
    YcodeDeviceModel  device windows' model: frames, zoom, the hub sidebar  [experimental]
    YcodeDeviceUI     the compact device window and the live session (macOS)
    YcodeUI           AppKit IDE: workspace window, navigators, editors,     [experimental: M4]
                      inspectors, Interface Builder, previews, Device Hub, settings
    YcodeApp          Ycode.app entry point (macOS)
    ycode             CLI: describe, schemes, settings, roundtrip, macho, dsc, deps, build, pif
    ycodebuild        `ycodebuild-cli`: the xcodebuild-compatible command line
    Tools/ycode-swb   swift-build helper (`swbuild`, pinned release/6.4.x)

Simulator (`docs/SIMULATOR-LINUX.md`):

    YcodeDarwinABI     guest memory, address spaces, the file system, trap numbers
    YcodeDarwinKernel  the Darwin kernel personality: BSD calls, Mach IPC, processes,
                       threads, kevent, workqueues, snapshots
    YcodeHypervisor    KVM VMs and vCPUs (arm64 Linux only), with CKVM
    YcodeXPC           bootstrap and the XPC wire format
    YcodeHostServices  host services: IOSurface, audio, camera, HID, FSEvents,
                       SCDynamicStore, power
    YcodeMetalHost     the Metal host service and its command decoding
    YcodeVulkan        the Vulkan back end, with CVulkan
    YcodeDisplayStream the display-stream protocol between ycode-simd and its viewers
    YcodeSimFeatures   simulator settings features, shared by ycode-simd, the viewer and the IDE
    ycode-simd         the VM monitor (arm64 Linux)
    ycode-sim-viewer   the viewer (macOS)

Mac simulator and device lists come from `simctl` / `devicectl` JSON inside
`YcodeBuild` (destinations) and `YcodeUI` (Device Hub).

Everything except `YcodeUI`, `YcodeDeviceUI`, `YcodeApp` and
`ycode-sim-viewer` builds and passes its tests on macOS (arm64) and Linux
(x86-64 and arm64, Swift 6.4). `ycode-simd` and `YcodeHypervisor` do real work
only on arm64 Linux. The x86-64 Linux workstation is the CI target for
portability; the arm64 Linux host is the only one that compiles the KVM paths.

## 4. Milestones

1. **M1: Project I/O.** Read and write pbxproj byte for byte, and provide a
   typed model and a CLI. *(This milestone is done for I/O. Typed mutations
   are next.)*
2. **M2: Workspace and schemes.** Parse `.xcworkspacedata`, `.xcscheme`, and
   `.xcconfig`. Resolve build settings the way `xcodebuild -showBuildSettings`
   does, and verify by diffing against it (black-box). *(Done. See
   `specs/build-settings.md` and `research/notes/m2-status.md`. Still open:
   the spec-defaults level.)*
3. **M3: Build.** Generate PIF, drive swift-build, and stream diagnostics.
   `ycode build` must produce the same products as `xcodebuild` for the
   corpus. *(Experimental, working: a shared PIF generator drives
   swift-build for projects, workspaces and packages, with an xcodebuild
   fallback; `ycodebuild` mirrors xcodebuild's command line including
   test, archive and export. Product equivalence is checked on a small
   corpus, not proven in general.)*
4. **M4: Shell.** An AppKit workspace window with the project navigator, a
   TextKit 2 editor with highlighting, a build button, and an issue
   navigator. *(Experimental, working, and well beyond the original scope:
   tabs and splits, assistant, inspectors, project/scheme editors,
   plist/asset/String Catalog editors, Interface Builder documents,
   SwiftUI previews, Library, Organizer, Settings.)*
5. **M5: Language features.** Completion, jump-to-definition, and live
   issues through sourcekit-lsp. *(Experimental, working; also Quick Help,
   rename, references, call hierarchy, code actions and fix-its.)*
6. **M6: Run and debug.** Schemes to launch, lldb-dap breakpoints, the
   variables view, and the console. *(Experimental, working; also
   watchpoints, console input, attach, disassembly.)*
7. **M7: Tests and devices.** The test navigator, results, simulators, and
   devices. *(Partly: the test navigator and results work. Runs go to My Mac,
   the Mac's simulators, and the Ycode simulator. The Device Hub starts,
   stops and shows Ycode's simulators; other simulators and physical devices
   are listed only.)*

**Simulator track (parallel):** run Xcode's simulator runtimes on arm64
Linux, on a Darwin compatibility layer in KVM micro-VMs. See
`docs/SIMULATOR.md` for why and where it stands, and
`docs/SIMULATOR-LINUX.md` for the design.

**Open frameworks (parallel):** clean-room packages for Apple frameworks in
`frameworks/`. See `frameworks/README.md`.

## 5. Research queue (dirty room)

Done and in specs: the `.xcscheme` and `.xcworkspacedata` grammars
(`specs/formats/xcode-xml.md`) and the build-setting resolution order
(`specs/build-settings.md`). Still open:

- Write the IDE extension-point architecture into a spec from the plug-in
  `Info.plist`/`.ideplugin` metadata (level 4). This decides how the Ycode
  shell is divided into modules.
- Collect real samples of the `PBXFileSystemSynchronized*` exception-set
  variants.
