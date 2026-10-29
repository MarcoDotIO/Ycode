# Ycode Simulator: Apple's simulator runtimes on Linux

The Ycode simulator runs the simulator runtimes that ship with Xcode on arm64
Linux. It does not emulate a device and it does not use firmware. This page
explains that choice and lists where the work stands. The design is in
[SIMULATOR-LINUX.md](SIMULATOR-LINUX.md); the specifications are in
[`specs/simulator/`](../specs/simulator/).

## 1. Where the work stands

| Area | State | Spec |
|---|---|---|
| Runtimes | iOS 27.1 and iOS 27.0. A device is tied to the runtime it was created with. | `ipad.md` §9.2, `home-apps.md` §9 |
| Boot | The full service boot is the default. Cold boot to the home screen: median 30.1 s on an idle host; the reference simulator on a Mac: 21.4 s. The first boot of a new device copy takes longer (57–80 s in other timed runs). | `lean-boot.md` §9, `parity-ladder.md` §3.1 and §4.8, `service-fidelity.md` §14 |
| Service fidelity | All 23 services of the old lean profile pass the behaviour test against the Mac in a full boot. Ycode starts 498–506 programs in 700 s; the Mac starts 631. | `parity-ladder.md` §4.8 |
| Warm boot | A stop saves a snapshot; the next run restores it. Home screen in 6.4–11.1 s. | `snapshot.md` §12.3 |
| Display and input | A live display stream (JPEG or zlib) to the Mac viewer or the IDE. Touch, keyboard, Home, Lock, volume. Animations run at the 60 Hz frame clock. | `display-stream.md`, `hid-input.md`, `frame-profile.md` §8.4 |
| Graphics | Metal calls replayed on Vulkan; Metal shaders (AIR) translated to SPIR-V by `ycode-airc`. A stuck GPU submission stops every client. | `stage8-contract.md`, `metal-shaders.md` |
| Apps | Install and launch an `.app`; the built-in apps launch. | `app-install-launch.md`, `app-launch.md`, `home-apps.md` |
| Devices | iPhone 18 Pro; the iPhone Duo foldable with a cover and an inner display; iPad (A16); iPad Pro 13-inch (M5). | `iphone-types.md`, `foldable.md`, `ipad.md` |
| visionOS | visionOS 27.0 boots to its room (LivingRoomDay) and the home view. Parts of the room are sometimes missing; there is no room selection yet. | `visionos.md` §10.20 |
| Networking | Guest sockets are host sockets, with a DNS responder in the VMM. No Bonjour. | `networking-ycode.md` |
| Audio | One 48 kHz stereo output. Output is discarded unless captured to a file; no input device. | `audio-host.md` §13 |
| Camera | Off by default, as in the reference. Opt in to a host webcam (V4L2) or a synthetic source. | `camera.md` §9, `camera-host.md` |
| Simulator features | Appearance, Liquid Glass, color filters, text size, accessibility switches, VoiceOver, location, sound, environment overrides. | `simulator-features.md` |
| File system | File events (FSEvents) from Ycode's own VFS; volume capabilities such as document IDs and `RENAME_SWAP`. | `fsevents-host.md`, `file-system-features.md` |
| Threads | Real Mach thread and task suspension. | `threads-and-events.md` §1.6, `host-libraries.md` §11.7 |
| Hosts | arm64 Linux with KVM only. x86-64 Linux needs arm64 translation, which is deferred. | `SIMULATOR-LINUX.md` §4 |

## 2. Why not boot an IPSW

The first request was: given an `.ipsw` for a device, boot it on a Linux
x86-64 machine and run the app under development. We did not take that path.

Xcode's Simulator does not use IPSWs:

- A *simulator runtime* (`iOS 27.simruntime`) holds iOS frameworks compiled
  for the Mac's CPU, as Mach-O for the iOS-simulator platform. They run as
  ordinary processes on the macOS kernel.
- `CoreSimulator` and `launchd_sim` provide the services. Graphics, audio and
  networking go through the host Mac.
- Nothing is emulated: there is no device kernel and no firmware.

An IPSW is firmware for a physical device. Booting one needs a full-system
emulator that models the SoC well enough to run the real kernel (as
Corellium and the open-source QEMU iOS ports do). The IPSW we had also stores
its system volume as Apple Encrypted Archives. Ycode does not decrypt
firmware, so that path could not produce a bootable iOS.

| | A. Full-system emulation of an IPSW | B. Simulator runtime on a Darwin compatibility layer (chosen) | C. Ycode-native runtime |
|---|---|---|---|
| Input | `.ipsw` | the `.simruntime` from Xcode | the app's source |
| Fidelity | Real iOS kernel and userland | Real iOS userland, our kernel | An imitation, not iOS |
| Hard parts | SoC models, secure monitors, no GPU, code-signing policy, binary translation on x86-64 | Mach-O loading, the XNU system-call and Mach IPC surface, the host services CoreSimulator provides, Metal | Reimplementing UIKit and SwiftUI |
| Prior art | qemu-t8030, Corellium | Darling (macOS userland on Linux) | OpenSwiftUI, Tokamak |

Option B it is. On arm64 Linux the runtime's arm64 code runs natively, so no
translation is needed.

## 3. Owner decisions

- **Building iOS apps on Linux** needs the iOS SDK. Apple licenses the SDK
  only for use on Apple-branded hardware. The owner accepts this risk. The
  usual setup builds on the Mac and runs the `.app` on Linux.
- **No decryption.** Ycode never decrypts encrypted components and never
  redistributes Apple software.
- **Code signing in the guest** may be relaxed to run development builds.

## 4. Clean-room rules for this track

The same protocol applies as everywhere else (see [AGENTS.md](../AGENTS.md)).
The VMM, the shim, the host libraries, the translator and the guest agents
are original code. The runtime is an input that each user copies from their
own Xcode installation. It is never committed or redistributed. Findings about
the runtime's behavior go into `specs/` first.
