# Design: Apple's simulator runtimes on arm64 Linux

Status: **implemented and in use** (option B in [SIMULATOR.md](SIMULATOR.md)).
Development host: an NVIDIA Jetson Thor (arm64, Ubuntu 24.04, KVM, Vulkan).
What works today is listed in [SIMULATOR.md](SIMULATOR.md) §1.

## 1. What has to be provided

On macOS the simulator is ordinary host processes, rerooted by dyld. On
Linux, Ycode must provide everything that macOS provides for free:

| macOS provides | Ycode on Linux |
|---|---|
| The XNU kernel ABI (`specs/simulator/darwin-arm64-abi.md`) | The **Darwin personality layer** (`YcodeDarwinABI`, `YcodeDarwinKernel`) |
| dyld + `DYLD_ROOT_PATH` → `dyld_sim` | `YcodeMachO` parses images and the shared cache; `dyld_sim` maps itself (stage 3) |
| `libsystem_kernel`, `libsystem_platform`, `libsystem_pthread` | Our own clean-room host libraries (`ycode/SimHostLibs`, `specs/simulator/host-libraries.md`) |
| The commpage | Filled in by the personality layer |
| launchd bootstrap for `launchd_sim` | A bootstrap and Mach-port server in the VMM (`specs/simulator/bootstrap-wire.md`) |
| CoreSimulator host services | Ycode host services: IOSurface, Metal (on Vulkan), audio, camera, HID, FSEvents, SCDynamicStore, power, syslog. No test-manager service yet. |

## 2. Execution model: a micro-VM per process

Three facts make a plain Linux process a poor fit:

1. **The trap instruction.** Darwin code issues `svc #0x80` with the number
   in `x16`. Linux ignores the immediate and reads `x8`, so every Darwin
   system call would run as a random Linux system call. Catching them would
   need seccomp traps, which cost one signal per call.
2. **TLS.** Darwin code reads its thread pointer from `TPIDRRO_EL0`, which a
   Linux process cannot set.
3. **Pages.** The guest is laid out for 16 KB pages, and the host kernel uses
   4 KB pages.

A **KVM micro-VM** removes all three. The guest supports the 16 KB
translation granule, 48-bit VA and PA, and AArch64 at EL0. Pointer
authentication is not exposed, which is fine: the simulator cache is arm64,
not arm64e.

The guest's processes run at **EL0** with 16 KB pages. A small **EL1 shim**
written by Ycode (`ycode/SimShim`, assembly, not Darwin code):

- installs page tables;
- sets `TPIDRRO_EL0` for each guest thread;
- turns every `svc #0x80` into a VM exit that carries the register file;
- handles faults the same way.

The **VMM**, `ycode-simd`, is a Ycode Swift process on the host. It owns
guest memory and implements the Darwin ABI on top of Linux.

```
 guest EL0:  dyld_sim / launchd_sim / apps  (unmodified runtime code)
 guest EL1:  Ycode shim  — page tables, TPIDRRO_EL0, svc → exit, faults
 ─────────────────────────── KVM ───────────────────────────
 host:       ycode-simd (Swift VMM), one host process for the device
               ├─ Mach-O and shared-cache mapping (YcodeMachO)
               ├─ BSD system calls → Linux system calls
               ├─ Mach traps: ports, messages, VM, tasks and threads
               ├─ bootstrap, launchd and XPC routing
               ├─ host services (IOSurface, audio, camera, HID, FSEvents, …)
               ├─ Metal → Vulkan (YcodeMetalHost, YcodeVulkan, ycode-airc)
               └─ display stream and snapshots
```

One host process runs every guest process of a device. Each process image
gets its own KVM VM. Each guest thread gets its own vCPU on its own host
thread. Mach IPC, kevent, workqueues and most BSD calls run outside the
global kernel lock (`specs/simulator/mach-ipc-locking.md`,
`specs/simulator/bsd-locking.md`).

## 3. Stages

Each stage has a contract or spec in `specs/simulator/`.

1. **Format layer.** *(Done.)* Parse Mach-O and the shared cache.
2. **VM bring-up.** *(Done 2026-10-11.)* The shim boots in KVM and an EL0
   self-test makes `svc #0x80` calls and gets results back
   (`vm-shim-protocol.md`). A trap round trip now costs about 4.1 µs, against
   0.09 µs for a native system call (`guest-cpu.md` §7.1).
3. **Static-image runner.** *(Done 2026-10-11.)* A command-line program from
   the runtime runs to completion on our host libraries (`stage3-contract.md`,
   `host-libraries.md`).
4. **Threads, processes, `launchd_sim`.** *(Done 2026-10-12.)* Threads,
   dispatch and in-process Mach IPC (4a); multiple processes, `posix_spawn`,
   signals and cross-task IPC (4b); `launchd_sim` with its `system` and
   `user/501` domains (4c) (`stage4a-contract.md` to `stage4c-contract.md`).
5. **Core daemons, headless.** *(Done 2026-10-12.)* The full job set boots
   (`stage6-contract.md`).
6. **UIKit and the home screen.** *(Done.)* SpringBoard reaches the home
   screen through Metal on Vulkan (`stage7-contract.md`, `stage8-contract.md`,
   `home-screen.md`).
7. **Display, input, apps.** *(Done.)* The display stream and viewer, HID
   input, app install and launch (`display-stream.md`, `hid-input.md`,
   `app-install-launch.md`).
8. **Fidelity and speed.** *(In progress.)* The full service boot
   (`service-fidelity.md`, `parity-ladder.md`), snapshots and warm boot
   (`snapshot.md`), the lock split, guest CPU work (`guest-cpu.md`), frame
   rate (`frame-profile.md`).
9. **More devices and services.** *(In progress.)* iPhone types, the
   foldable, iPads, visionOS; networking, audio, camera, simulator features,
   FSEvents (see [SIMULATOR.md](SIMULATOR.md) §1).

## 4. Risks and open problems

- **Speed.** A cold boot takes about 1.4 times as long as on a Mac
  (`lean-boot.md` §9). A trap costs about 44 times a native system call.
- **One process per device.** Every VM of a device shares one host address
  space and its lock (`boot-profile.md` §9.7).
- **GPU faults.** A stuck GPU submission stops every client
  (`stage8-contract.md` §15.8).
- **x86-64 hosts** need user-mode arm64 translation on top of all this. That
  is deferred. Native mode (`native-mode.md`) is arm64-only; its stage 1, on the
  `native-mode` branch, runs macOS command-line programs without a VM (§10).
  It is developed there across betas and is not the route to the boot
  target. An x86-64 PC can
  run the IDE and a viewer against an arm64 host (`specs/simulator/sim-link.md`).
- **Host kernels** without upstream commit `fbc7e61195e2` can corrupt host
  SVE state; see [postmortem-kvm-sve.md](postmortem-kvm-sve.md).

## 5. Building and running

You need arm64 Linux with `/dev/kvm`, a Vulkan driver, Swift 6.4, LLVM 18 and
SPIRV-Tools, and your own copy of the simulator runtime (`RuntimeRoot`) from
your own Xcode installation. Keep devices, snapshots and run output on a
separate data volume, called `$YCODE_DATA` in specs and scripts.

On the Linux host, from `ycode/`:

```sh
swift build -c release
sh SimShim/build.sh                                   # the EL1 shim
YCODE=$PWD/.build/release/ycode sh SimHostLibs/build.sh   # the host libraries
sh SimGuestFrameworks/build.sh                        # SimFramebuffer, SimHID
sh Translator/build.sh                                # ycode-airc
```

`scripts/ycode-sim-serve build` runs the first four steps. The guest agents
(`SimGuestAgents/build.sh`, `build-camera.sh`) build on macOS only, because
they need the iOS simulator SDK; copy their `out/` into the host's
guest-tools directory.

To boot a device and see it from a Mac or a Linux PC, use `scripts/ycode-sim-try`
([ycode/README.md](../ycode/README.md)). The IDE runs the same launcher,
`scripts/ycode-sim.sh`, over ssh (`specs/ide/run.md`). `ycode-simd --help`
lists the device types, the feature flags (`--ui`, `--accessibility`,
`--location`, `--audio`, `--overrides`, `--camera`) and the app options
(`--install-app`, `--launch`).

### 5.1 Getting a runtime and preparing a host

The IDE's runtime wizard (macOS: Settings ▸ Components ▸ Simulator
Runtimes…, the destination menu's Get a Simulator Runtime…, and the first
launch; Linux: Window ▸ Downloads and the first launch) lists the runtimes
you have, copies a RuntimeRoot into Ycode's folder or to a simulator host
(`<data>/runtimes/<token>-<version>-<build>`, resumable), and removes only
the runtimes Ycode copied. On a Mac it adds a runtime image you picked with
`xcrun simctl runtime add` only after you confirm the command. `ycode sim
runtimes check` prints the same checklist.

Its Get a Runtime step (`specs/simulator/runtime-downloads.md` §6) gets one
from Apple only when you ask, after a confirmation that shows the exact
command. On a Mac with Xcode it runs Apple's own tool first
(`xcodebuild -downloadPlatform <platform>`, with `-exportPath <folder>` for a
copy to take to Linux; `ycode runtime xcodebuild <platform> --export <folder>`
does the same from a terminal). Ycode's own download is the second route
(`ycode runtime download <platform> [--build B | --version V]`): it asks
Apple's asset service for the runtime with a truthful description of the
computer (no Mac model fields on Linux), downloads it into
`<runtimes>/.partial` (an interrupted download resumes), checks its size and
SHA-256, decrypts it with the key Apple returns (macOS: the Apple Archive
framework; Linux: python-aea, MIT, which the wizard installs on request into
`<runtimes>/.tools/python-aea`), reads the disk image (macOS: `hdiutil`;
Linux: 7-Zip 23 or later, run as a separate program; the Flatpak ships 7-Zip's
own `7zz`, built without the RAR code, and a build from source uses the
system's `7zz` or `7z`, or `$YCODE_7Z`), puts the RuntimeRoot
in `<runtimes>/<token>-<version>-<build>` with `ycode-runtime.json`, and
removes the archives. `ycode runtime list` shows what is there; `ycode runtime
import <exportedBundle>` adds a bundle exported on a Mac. The runtime folder is
`$YCODE_RUNTIMES_DIR`, else `$YCODE_DATA/runtimes`, else
`~/.local/share/ycode/runtimes`. Ycode never shares, mirrors or keeps a runtime,
key or index for anyone else, and never signs in to an Apple account.

For a host, the wizard sends `ycode-host-setup` over ssh
(`ycode sim runtimes script` prints it): `--report` (the default) changes
nothing; `--apply` runs the steps that need no root as you; `--root`, run
in your own terminal with `sudo`, runs the rest (packages, the `kvm` group,
firewall ports). A second run only reports. Its kernel check runs a short
probe for the KVM SVE bug of [postmortem-kvm-sve.md](postmortem-kvm-sve.md)
on arm64 hosts with SVE (not applicable elsewhere); it never builds or
installs a kernel.

On an aarch64 host without a built tree, Apply installs the simulator service
from Ycode's own release: `Ycode-<version>-aarch64.tar.xz`, checked against the
release's `SHA256SUMS.txt`, unpacked in `<data>/ycode`, with `ycode-simhost`
and `ycode` linked into `<data>/bin` and `YCODE_SIM_TREE` set to its
`lib/ycode-sim`. The tarball's tools are built for the Flatpak runtime
(freedesktop, glibc 2.44 and its OpenSSL). On a plain distribution only
`ycode-simhost` and the simulator tree are used, and they run (checked on
Ubuntu 24.04). The tarball's `ycode` command line may not start there: its
bundled libcurl needs OpenSSL 3.2, and Ubuntu 24.04 has 3.0. So the setup
script and the wizard read the installed version from the release's folder
(`manifest.json`, else `Ycode-<version>-<arch>`) and never run that `ycode`.
A `ycode-simhost` from 1.0.0-beta.1 has no `check` command; the self-test then
checks the configuration's files itself and reports itself as unknown, not
failed.

## 6. Clean-room status

The design uses only:

- level-1 sources (xnu and dyld headers, public documentation);
- level-3/4 observations of the runtime.

The guest runtime itself is an input, copied by each user and never
redistributed.
