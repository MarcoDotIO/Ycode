# iOS Simulator: dynamic observations (2026-10-11)

Method: black-box observation on the reference Mac (evidence level 3).
Xcode 27.1, iOS 27.1 runtime 24A94401, a throwaway device "Ycode-Probe"
(type `iPhone Duo`, the only type the 27.1 runtime accepts). The probe app
source is in `research/experiments/simulator/ProbeApp`. It is our own code
and reports what a launched app can see.

## Runtime bundle

- `iOS 27.1.simruntime` is mounted from a disk image at
  `/Library/Developer/CoreSimulator/Volumes/iOS_<build>/…`. The
  `Contents/Resources/RuntimeRoot` directory is a 16 GB iOS userland tree:
  - 297 public and 2,472 private frameworks;
  - 329 LaunchDaemons and 243 Applications;
  - the system binaries `sbin/launchd_sim`, `usr/lib/dyld_sim`, and
    `usr/sbin/*`.
- All installed runtimes report `supportedArchitectures = ["arm64"]`.
  There are no x86-64 slices.
- The binaries are arm64 Mach-O with `LC_BUILD_VERSION` platform 7
  (iOS simulator), minos/sdk 27.1.
- `usr/lib` holds only 47 files. libSystem, libobjc, Foundation, UIKit, and
  the rest live in `System/Library/Caches/com.apple.dyld/dyld_sim_shared_cache_arm64*`.

## Boot

- `simctl boot` (with `bootstatus -b`) took 38 s on first boot. The boot
  status reported "Data Migration Failed", which did not stop the boot.
- The host's `launchd` starts **`launchd_sim`** as an ordinary user
  process: same uid, not root. This is the guest's init. 193 guest
  processes become its children: SpringBoard-class services, poster and
  widget extensions, `cfprefsd`, `assetsd`, `CoreSimulatorBridge`, and so
  on.
- In host `ps`, some guest processes appear with guest-relative paths such
  as `/usr/libexec/pkd`.
- **Host-side services** start alongside the guest. They are XPC services
  inside CoreSimulator's `simdeviceio` rendering bundle, children of the
  host `launchd`:
  - `SimRenderServer`: display composition;
  - `SimMetalHost` ×3: the guest's GPU work goes to the host GPU;
  - `SimAudioProcessorService`;
  - `SimStreamProcessorService`: screen frames for viewers.
- `CoreSimulatorService` (a host XPC service) owns device state:
  `simctl` → CoreSimulatorService → launchd_sim.

## App install and launch

- `simctl install` copies the bundle to
  `<device>/data/Containers/Bundle/Application/<UUID>/` and creates a data
  container at `<device>/data/Containers/Data/Application/<UUID>/`. The
  UUIDs change on every reinstall.
- **An app that does not adopt the UIScene lifecycle is terminated at
  launch on iOS 27.** UIKit raises a runtime-issue failure ("…NoSceneLifecycleAdoption").
  Ycode's app templates must include `UIApplicationSceneManifest`.
- The app process is a child of `launchd_sim`, running as the user. Its
  launchd label is `XPC_SERVICE_NAME=UIKitApplication:<bundle-id>[…]`.
- `simctl launch --console-pty` connects the app's stdout and stderr to the
  caller. Extra arguments are passed through as argv.

## How the guest is isolated (it mostly is not)

There is no VM, no emulated kernel, and no chroot. The guest is host
processes plus **dyld rerooting**, through environment variables that every
guest process gets:

| Variable | Value / role |
|---|---|
| `DYLD_ROOT_PATH` | RuntimeRoot. The host dyld hands off to `dyld_sim` and resolves libraries under this root |
| `DYLD_SHARED_CACHE_DIR` | The runtime's `com.apple.dyld` cache directory |
| `DYLD_FALLBACK_FRAMEWORK_PATH`, `DYLD_FALLBACK_LIBRARY_PATH` | RuntimeRoot's Frameworks and usr/lib |
| `IPHONE_SIMULATOR_ROOT` | RuntimeRoot |
| `IPHONE_SHARED_RESOURCES_DIRECTORY` | The device's `data` directory (the guest's "/var/mobile" world) |
| `HOME`, `TMPDIR`, `_DYLD_CLOSURE_HOME` | The app's data container (a real host path) |
| `XPC_SIMULATOR_LAUNCHD_NAME` | `com.apple.CoreSimulator.SimDevice.<UDID>`: the launchd domain that guest XPC lookups resolve in |
| `IOS_SIMULATOR_SYSLOG_SOCKET` | A host Unix socket for logging |
| `TESTMANAGERD_SIM_SOCK`, `TESTMANAGERD_REMOTE_AUTOMATION_SIM_SOCK`, `RWI_LISTEN_SOCKET` | Host Unix sockets for XCTest and the Web Inspector |
| `PATH` | RuntimeRoot's bin directories |

- `uname` inside the app reports the **host** kernel (`release=27.2.0`,
  `machine=arm64`), while UIKit reports `iPhone / iOS 27.1`.
- A minimal UIKit app loads **506 images**, almost all from the sim shared
  cache.

## Device directory

`~/Library/Developer/CoreSimulator/Devices/<UDID>/` contains `device.plist`
(type, runtime, name, state, UDID) and `data/`. `data/` holds `Containers`,
`Documents`, `Downloads`, `Library`, `Media`, `Root`, `System`, `private`,
`tmp`, and `var`.

## Display

- `simctl io <udid> screenshot` works with Simulator.app closed. It
  returned a 2007×2853 image that was entirely black. **Open question:** is
  the display not composited without a viewer, or is this device type's
  screen off at boot? Next step: compare with Simulator.app open, and with
  another device type on an older runtime.

## What this means for Ycode on Linux

The simulator runtime expects four things from its host:

1. **A Darwin kernel ABI:** XNU BSD syscalls, Mach traps, Mach ports and
   IPC, kqueue, and so on. On macOS this is the real kernel.
2. **dyld behavior:** a Mach-O loader that honors `DYLD_ROOT_PATH` and
   hands control to `dyld_sim`, or that can map the sim shared cache
   itself.
3. **A launchd bootstrap domain** for `launchd_sim`, plus the CoreSimulator
   host services: render, Metal, audio, stream, syslog, and test manager.
4. **arm64 execution.**

On x86-64 Linux, none of the four exists. The work is:

- a Mach-O and shared-cache loader;
- a Darwin syscall and Mach IPC layer (Darling is prior art);
- re-implemented host services, including Metal → Vulkan translation;
- arm64 → x86-64 user-mode translation.

On arm64 Linux the last item goes away, which makes that the far more
realistic first Linux target. This is option B in `docs/SIMULATOR.md`.
