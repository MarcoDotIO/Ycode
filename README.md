# Ycode

> [!WARNING]
> **Ycode is extremely experimental.** It is a research project. Nothing here
> is stable, supported, or ready for real use:
> - **Interfaces.** APIs, file layouts and command-line flags change without
>   notice.
> - **The simulator.** The iOS simulator boots to the home screen on arm64
>   Linux and runs apps, with a live display and input. It is still slower
>   than the reference simulator, and parts of it are missing.
> - **The IDE.** A macOS IDE (`Ycode.app`) covers many Xcode workflows. It is
>   incomplete and rough in places. Most of it is tested through automated
>   offscreen tests, not daily use.
>
> Expect breakage. Read the [status](#status) section before you try anything.

Ycode is an independent, **clean-room** reimplementation of the Xcode IDE for
Apple platforms. It matches Xcode's observable behavior and file formats, so
that real projects open, build and save correctly. **Ycode contains no Apple
code.** We study Xcode only to learn *what* it does: its file formats,
protocols and observable behavior. All Ycode code comes from our own
specifications in `specs/`. See [The clean-room protocol](#the-clean-room-protocol).

A second track, the **Ycode simulator**, runs the simulator runtimes that ship
with Xcode on **arm64 Linux**. Each guest process runs in its own KVM
micro-VM. A Darwin kernel personality written in Swift serves the guest's
system calls and Mach traps. Metal rendering is translated to Vulkan.

A third track, **open frameworks** (`frameworks/`), reimplements Apple
frameworks as Swift packages that also build on Linux.

## Status

### The IDE (macOS)

| Area | State |
|---|---|
| Project model (`.pbxproj`, OpenStep plists) | Reads and writes. Round trips of Xcode-written projects are byte-identical on our test corpus. |
| Workspaces and schemes (`.xcworkspace`, `.xcscheme`) | Reads and writes. Byte-identical round trips on our corpus. |
| Build settings (xcconfig, defaults, conditions) | Matches `xcodebuild -showBuildSettings` on our corpus: 111,310 of 111,310 values across 24 projects ([conformance](specs/xcodebuild/conformance.md)). |
| `ycodebuild` | An `xcodebuild`-compatible command line: build, test, archive, export, settings and information queries. 363 of 363 build checks match the reference tool on our corpus ([conformance](specs/xcodebuild/conformance.md)). |
| Building | **Experimental.** A PIF generator drives swift-build for projects, workspaces and packages, with an `xcodebuild` fallback. Swift package dependencies resolve through git and SwiftPM. |
| Workspace window | **Experimental.** Nine navigators, editor tabs and splits, assistant and counterparts, inspectors, Open Quickly, the scheme editor, the project editor, templates, the Library, and Settings with themes and key bindings. The look follows the system's Liquid Glass materials on macOS 26 and falls back on earlier systems ([liquid-glass-ycode.md](specs/ide/liquid-glass-ycode.md)). |
| Editors | **Experimental.** A TextKit 2 source editor (incremental highlighting, folding, find and replace, placeholders, minimap). Property-list, asset-catalog and String Catalog editors. Interface Builder documents (outline, canvas, inspectors, byte-minimal edits). SwiftUI previews, rendered offscreen. |
| Language features | **Experimental.** Through SourceKit-LSP: completion, Quick Help, jump to definition, live issues with fix-its, rename, references, call hierarchy, code actions ([language.md](specs/ide/language.md)). |
| Run and debug | **Experimental.** Runs on My Mac, on the Mac's simulators, and on the Ycode simulator over ssh ([run.md](specs/ide/run.md)). Debugging through lldb-dap: breakpoints, stepping, variables, watchpoints, console input, attach, disassembly. |
| Coding assistant | **Experimental.** Local models (Ollama, llama.cpp), OpenAI (ChatGPT sign-in or API key), and agent CLIs run read-only. The assistant proposes changes; you review and apply them ([coding-assistant.md](specs/ide/coding-assistant.md)). |
| Devices | **Experimental.** A Device Hub-style window and a compact device window. They start, stop and show the Ycode simulator's devices live, with input. Other simulators and physical devices are listed only ([device-hub.md](specs/ide/device-hub.md)). |
| Testing, source control, distribution | **Experimental.** Test navigator and results. Git status, history, commit and comparison. Organizer archives with Copy App export. |

### The simulator (arm64 Linux)

Tested on an NVIDIA Jetson Thor (arm64, Ubuntu 24.04, KVM, Vulkan).

What works:
- **Runtimes.** iOS 27.1 and iOS 27.0. Each device is tied to one runtime
  ([ipad.md](specs/simulator/ipad.md) §9.2).
- **The full service boot.** `launchd_sim` starts every system service; no
  service is switched off. A cold boot of a device that booted before reaches
  the home screen in a median of 30.1 s on an idle host. The reference
  simulator on a Mac takes 21.4 s ([lean-boot.md](specs/simulator/lean-boot.md) §9,
  [parity-ladder.md](specs/simulator/parity-ladder.md) §3.1).
- **Warm boot.** Stopping a device saves a snapshot. The next run restores it
  and shows the home screen in 6.4–11.1 s
  ([snapshot.md](specs/simulator/snapshot.md) §12.3).
- **Display and input.** A live display stream to a viewer on the Mac or to
  the IDE, with touch, keyboard, Home, Lock and volume. Animations run at the
  60 Hz frame clock ([display-stream.md](specs/simulator/display-stream.md),
  [hid-input.md](specs/simulator/hid-input.md),
  [frame-profile.md](specs/simulator/frame-profile.md) §8.4).
- **Graphics.** Metal calls are replayed on Vulkan. Our own translator,
  `ycode-airc`, turns Metal shaders (AIR) into SPIR-V
  ([stage8-contract.md](specs/simulator/stage8-contract.md)).
- **Apps.** Install and launch your own `.app`. The built-in apps launch.
- **Devices.** iPhone 18 Pro, the iPhone Duo foldable with its two displays
  ([foldable.md](specs/simulator/foldable.md)), iPad (A16) and iPad Pro
  13-inch (M5) ([ipad.md](specs/simulator/ipad.md)). visionOS 27.0 boots to
  its room and home view, with open problems
  ([visionos.md](specs/simulator/visionos.md) §10.20).
- **Host services.** Networking ([networking-ycode.md](specs/simulator/networking-ycode.md)),
  audio output ([audio-host.md](specs/simulator/audio-host.md)), an opt-in
  host webcam ([camera.md](specs/simulator/camera.md) §9), file events
  ([fsevents-host.md](specs/simulator/fsevents-host.md)) and volume
  capabilities ([file-system-features.md](specs/simulator/file-system-features.md)).
- **Simulator features.** Appearance, accessibility settings, location, sound
  and environment overrides, set from the IDE, the viewer or the command line
  ([simulator-features.md](specs/simulator/simulator-features.md)).
- **Threads.** Real Mach thread and task suspension
  ([threads-and-events.md](specs/simulator/threads-and-events.md) §1.6).

What doesn't work, or works badly:
- **Speed.** A cold boot takes about 1.4 times as long as the reference
  simulator's. The first boot of a new device, and the first launch of an app
  after a cold boot, are slower still.
- **Service fidelity.** In the same time window, Ycode starts fewer programs
  than the reference simulator (498–506 against 631;
  [parity-ladder.md](specs/simulator/parity-ladder.md) §4.8).
- **Missing pieces.** No audio input or real playback (output is discarded
  unless captured to a file). No Bonjour. The camera picker's viewfinder stays
  grey. One stuck GPU submission stops every client until the host restarts
  ([stage8-contract.md](specs/simulator/stage8-contract.md) §15.8).
- **Hosts.** Only arm64 Linux with KVM runs the simulator. x86-64 Linux would
  need arm64 translation, which is deferred.
- **Host kernel bug.** Linux kernels without upstream commit `fbc7e61195e2`
  ("KVM: arm64: Unconditionally save+flush host FPSIMD/SVE/SME state") can
  corrupt host SVE state after `KVM_RUN`. Ycode works around this, but a fixed
  host kernel is strongly recommended. See
  [docs/postmortem-kvm-sve.md](docs/postmortem-kvm-sve.md).
- **Bring your own runtime.** Ycode does not and will not redistribute any
  Apple software. To run the simulator you need your own copy of the
  simulator runtime from your own Xcode installation, used under Apple's
  license terms.

Design and progress: [docs/SIMULATOR.md](docs/SIMULATOR.md) and
[docs/SIMULATOR-LINUX.md](docs/SIMULATOR-LINUX.md). The specifications are in
[specs/simulator/](specs/simulator/).

### Open frameworks

Seven packages in [frameworks/](frameworks/): Contacts, EventKit, HealthKit,
HomeKit, StoreKit, SwiftUI and WeatherKit. Each builds and tests on macOS and
Linux. Each is partial; its README lists the rounds that are done. ARKit,
MapKit and RealityKit have specifications in
[specs/frameworks/](specs/frameworks/) but no code yet.

## Repository layout

| Path | Contents |
|---|---|
| `ycode/` | The Swift package: the implementation (clean room). |
| `ycode/Sources/Ycode{Plist,Project,Workspace,Settings,MachO}` | Project model, file formats, build settings, Mach-O. |
| `ycode/Sources/Ycode{Build,Language,Debug,Assistant,Subprocess}` | IDE services: build engines and PIF, LSP client, DAP client, coding assistant, subprocess runs. |
| `ycode/Sources/Ycode{UI,DeviceUI,DeviceModel,App}` | The AppKit IDE, the device windows and their model, the app. |
| `ycode/Sources/{YcodeXcodebuild,ycodebuild-cli}`, `ycode/Tools/ycode-swb` | `ycodebuild`, the xcodebuild-compatible tool, and the swift-build helper. |
| `ycode/Sources/Ycode{DarwinABI,DarwinKernel,Hypervisor,XPC,HostServices}`, `ycode/Sources/ycode-simd` | Simulator: the Darwin kernel personality, KVM, XPC, host services, and the VM monitor. |
| `ycode/Sources/Ycode{MetalHost,Vulkan}`, `ycode/Translator/` | Simulator: the Metal host service, the Vulkan back end, the AIR → SPIR-V translator. |
| `ycode/Sources/Ycode{DisplayStream,SimFeatures}`, `ycode/Sources/ycode-sim-viewer` | Simulator: the display stream, the settings features, and the Mac viewer. |
| `ycode/SimShim/`, `ycode/SimHostLibs/`, `ycode/SimGuestFrameworks/`, `ycode/SimGuestAgents/` | Simulator guest side: the EL1 shim, our replacement host libraries, our framebuffer and HID frameworks, our settings and camera agents. |
| `ycode/scripts/` | App packaging, simulator launchers, conformance and profiling scripts, the lint wrapper. |
| `frameworks/` | Open framework packages (clean room). |
| `specs/` | The clean-room boundary: behavior and format specifications. Each one ends with an Evidence section. |
| `docs/` | Architecture, roadmap, design notes and post-mortems. |
| `research/` | Our own probes and experiments, and prose observations (dirty room). |
| `tools/` | Analysis scripts. They record metadata only. |

## Building

The libraries and the `ycode` command-line tool build on macOS and Linux with
Swift 6.4. The IDE app builds on macOS only:

```bash
cd ycode
swift build
swift test
.build/debug/ycode describe path/to/App.xcodeproj
scripts/make-app.sh                 # builds .build-ide/app/Ycode.app
```

More commands, and how to try the simulator from a Mac, are in
[ycode/README.md](ycode/README.md).

To build the simulator (arm64 Linux with KVM and a Vulkan driver), see
[docs/SIMULATOR-LINUX.md](docs/SIMULATOR-LINUX.md).

## The clean-room protocol

Ycode is developed under a two-room protocol. [AGENTS.md](AGENTS.md)
describes it in full. It applies to every contributor, human or AI.

- **Dirty room.** Analysis of Xcode happens only in `research/`. Decompiler
  and disassembler output stays in an untracked local directory.
- **The spec boundary.** Only written specifications in `specs/` go from the
  dirty room to the clean room. They describe behavior and formats, never
  Apple's code.
- **Clean room.** Implementation work in `ycode/` and `frameworks/` reads only
  the specs, public documentation, and suitably licensed open source.
- **Never commit Apple's material.** No Apple code, binaries, resources,
  templates, artwork or runtime files are ever committed.

Read [CONTRIBUTING.md](CONTRIBUTING.md) before you open a pull request.

## Legal

Ycode is an independent project. It is not affiliated with, endorsed by, or
sponsored by Apple Inc. Apple, Xcode, iOS, macOS, Metal and other Apple
product names are trademarks of Apple Inc. They are used here only to
describe what Ycode interoperates with.

## License

Ycode is released under the [MIT License](LICENSE). The vendored Vulkan
headers in `ycode/Sources/CVulkan/vulkan/` are © The Khronos Group Inc.,
licensed under Apache-2.0, as stated in each file. By contributing, you agree
that your contributions are licensed under the MIT License.
