# Ycode

> [!WARNING]
> **Ycode is extremely experimental.** It is a research project in an early
> stage. Nothing here is stable, supported, or ready for real use:
> - **Interfaces.** APIs, file layouts and command-line flags change without
>   notice.
> - **The simulator.** The iOS simulator boots on Linux, but it is slow,
>   headless (no live display or input yet) and crash-prone.
> - **The IDE.** There is no IDE user interface yet.
>
> Expect breakage. Read the [status](#status) section before you try anything.

Ycode is an independent, **clean-room** reimplementation of the Xcode IDE for
Apple platforms. The goal is to match Xcode's observable behavior and file
formats, so that real projects open, build and save correctly. **Ycode
contains no Apple code.** Xcode is studied only to learn *what* it does: its
file formats, protocols and observable behavior. All Ycode code is written
from our own specifications (`specs/`). See [The clean-room
protocol](#the-clean-room-protocol).

A second track, the **Ycode iOS simulator**, runs the iOS simulator runtime
that ships with Xcode on **arm64 Linux**. Each guest process gets its own KVM
micro-VM. A Darwin kernel personality written in Swift serves the guest's
system calls and Mach traps, and Metal rendering is translated to Vulkan.

## Status

| Area | State |
|---|---|
| Project model (`.pbxproj`, OpenStep plists) | Reads and writes. Round trips of Xcode-written projects are byte-identical on our test corpus. |
| Workspaces and schemes (`.xcworkspace`, `.xcscheme`) | Reads and writes. Byte-identical round trips on our corpus. |
| Build-setting resolution (xcconfig, defaults, conditions) | Matches `xcodebuild -showBuildSettings` on our corpus: 8,788 of 8,788 settings across 27 projects. |
| Mach-O and dyld shared-cache reading | Basic support (`ycode macho`, `ycode dsc`). |
| Building, editing, debugging, IDE user interface | **Not started.** The plan is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). |
| iOS simulator on arm64 Linux | **Extremely experimental.** See below. |

### The iOS simulator on Linux: what works and what doesn't

Tested on an NVIDIA Jetson Thor (arm64, Ubuntu 24.04, KVM, Vulkan) with the
iOS 27.1 simulator runtime.

What works:
- `launchd_sim` and the system daemons start under Ycode's own Darwin kernel
  personality. Each process runs in its own KVM micro-VM, with one vCPU per
  thread.
- Mach IPC, XPC, `posix_spawn`, kqueue/workqueues and memory entries all work.
- First-boot data migration runs, and LaunchServices is seeded.
- SpringBoard reaches the **home screen**, with icons and wallpaper. It renders
  through Metal, and the Metal calls are translated to Vulkan: AIR shaders are
  translated to SPIR-V by our own `ycode-airc` translator.
- A test app can be installed and launched.

What doesn't work, or works badly:
- **Speed.** A first boot takes about 10–15 minutes and a later boot about 7–8
  minutes; on a Mac this takes seconds. Most of the gap comes from a single
  global kernel lock. Work on this is in progress.
- **No live display or input yet.** Output is screenshots only. Touch and
  keyboard input are planned next.
- **Missing pieces.** Many calls are unimplemented, and several daemons crash
  and respawn (for example, `configd_sim` has no host configuration store
  yet).
- **Host kernel bug.** Linux kernels without upstream commit `fbc7e61195e2`
  ("KVM: arm64: Unconditionally save+flush host FPSIMD/SVE/SME state") can
  corrupt host SVE state after `KVM_RUN`. Ycode works around this, but a fixed
  host kernel is strongly recommended. See
  [docs/postmortem-kvm-sve.md](docs/postmortem-kvm-sve.md).
- **Bring your own runtime.** Ycode does not and will not redistribute any
  Apple software. To run the simulator you need your own copy of the iOS
  simulator runtime from your own Xcode installation, used under Apple's
  license terms.

Design and progress: [docs/SIMULATOR.md](docs/SIMULATOR.md) and
[docs/SIMULATOR-LINUX.md](docs/SIMULATOR-LINUX.md). The specifications are in
[specs/simulator/](specs/simulator/).

## Repository layout

| Path | Contents |
|---|---|
| `ycode/` | The Swift package: the implementation (clean room). |
| `ycode/Sources/Ycode{Plist,Project,Workspace,Settings,MachO}` | Project model, file formats, build settings, Mach-O. |
| `ycode/Sources/Ycode{DarwinABI,DarwinKernel,Hypervisor,XPC,HostServices}` | Simulator: Darwin kernel personality, KVM, XPC, host services. |
| `ycode/Sources/Ycode{MetalHost,Vulkan}`, `ycode/Translator/` | Simulator: the Metal host service, the Vulkan back end, the AIR → SPIR-V translator. |
| `ycode/SimShim/`, `ycode/SimHostLibs/`, `ycode/SimGuestFrameworks/` | Simulator: the guest EL1 shim, our replacement host libraries, our headless framebuffer framework. |
| `specs/` | The clean-room boundary: behavior and format specifications. Each one ends with an Evidence section. |
| `docs/` | Architecture, roadmap, design notes and post-mortems. |
| `research/` | Our own probes and experiments, and prose observations. |
| `tools/` | Analysis scripts. They record metadata only. |

## Building

The IDE-side libraries and the `ycode` command-line tool build on macOS and
Linux with Swift 6.4:

```bash
cd ycode
swift build
swift test
.build/debug/ycode describe path/to/App.xcodeproj
```

More commands are listed in [ycode/README.md](ycode/README.md).

To build the simulator (arm64 Linux with KVM and a Vulkan driver), see
[docs/SIMULATOR-LINUX.md](docs/SIMULATOR-LINUX.md) and the `build.sh` script
in each of `ycode/SimShim`, `ycode/SimHostLibs`, `ycode/SimGuestFrameworks`
and `ycode/Translator`. Expect to read code: running the simulator is not
documented as a polished workflow yet.

## The clean-room protocol

Ycode is developed under a two-room protocol. It is described in full in
[CLAUDE.md](CLAUDE.md), and it applies to every contributor, human or AI.

- **Dirty room.** Analysis of Xcode happens only in `research/`. Decompiler
  and disassembler output never leaves an untracked local directory.
- **The spec boundary.** Only written specifications in `specs/` cross from
  the dirty room to the clean room. They describe behavior and formats, never
  Apple's code.
- **Clean room.** Implementation work in `ycode/` reads only the specs, public
  documentation, and suitably licensed open source.
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
