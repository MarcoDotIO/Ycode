# Ycode Simulator: running iOS apps from an IPSW on x86-64 Linux

Goal (from the project owner): with an `.ipsw` for a device on a Linux x86-64
machine, Ycode can boot it and run the app under development.

## 1. Why this is not a port of Xcode's Simulator

Xcode's Simulator does not use IPSWs.

- A *simulator runtime* (`iOS 27.simruntime`) contains iOS frameworks
  compiled for the **Mac's** CPU, as Mach-O for the iOS-simulator platform.
  They run as ordinary processes on the **macOS kernel**.
- `CoreSimulator`/`launchd_sim` provide the services. Graphics, audio, and
  networking go through the host Mac.
- Nothing is emulated, so there is no device kernel and no firmware.

An IPSW is the opposite case. It contains firmware for a physical device:
an ARM64 kernelcache built for one SoC, iBoot, device trees, SEP/SPTM/TXM
monitors, and the APFS system volume with the arm64e dyld shared cache.

To run it, you must emulate the device: a full-system emulator that
models the SoC well enough to boot the real kernel. On x86-64 this also means
translating ARM64 to x86-64. So "Ycode Simulator on Linux + IPSW" is a
**full-system emulator project** in the same class as Corellium and the
open-source QEMU iOS ports. It is not a reimplementation of Xcode's
Simulator. That is the honest scope of the request.

## 2. Options

| | A. Full-system emulation of the IPSW | B. Simulator runtime on a Darwin compatibility layer | C. Ycode-native runtime |
|---|---|---|---|
| Input | `.ipsw` (as requested) | the `.simruntime` from Xcode, not an IPSW | the app's source |
| Fidelity | Real iOS kernel and userland | Real iOS userland, our kernel shim | An imitation, not iOS |
| Hard parts | SoC models (interrupt controller, timers, UART, NVMe/ANS, display), SPTM/TXM/exclaves on A15+-class chips, GPU (none, so software rendering), AMFI/code-signing policy, binary translation | Mach-O loader, XNU syscall and Mach IPC emulation (as Darling does), host services that CoreSimulator normally provides, Metal; iOS 27 runtimes are probably arm64-only, so translation is needed on x86 | Reimplementing UIKit/SwiftUI |
| Prior art | alephsecurity qemu-t8030 (iPhone 11 / iOS 14 to a shell), ChefKiss Inferno, Corellium (commercial) | Darling (macOS userland on Linux) | OpenSwiftUI, Tokamak, UIKit-cross-platform |
| Size | Very large, open-ended research | Very large | Large, and does not meet the goal |

**Recommendation:** use A. It is the only option that meets "IPSW on Linux".
Run it as a staged research track beside the IDE. Each stage produces
something useful on its own:

1. **IPSW toolkit (now).** IPSW (zip) → `BuildManifest.plist` → IMG4/IM4P
   containers (DER) → LZFSE/LZSS decompression → kernelcache Mach-O (fileset
   entries), device tree, APFS system volume, and the dyld shared cache. This
   is file-format work, and it runs on Linux.
2. **Feasibility audit (after we have the actual IPSW).** Find out which
   components are present, which are encrypted, which SoC it targets, and
   which monitors (SPTM, TXM, exclaves) the kernel expects. This decides
   whether 24A446 for an A-series chip of that generation can be booted at
   all with current techniques. The A13/iOS 14 path is proven. Newest-SoC
   firmware has never been publicly booted in QEMU.
3. **Boot to kernel log.** A QEMU machine model plus a boot shim that hands
   the kernel a device tree and boot arguments.
4. **Userland to a shell.** Then launchd and the system daemons.
5. **Display and input.** Framebuffer, software rendering, and touch through
   a virtual HID device. SpringBoard.
6. **App install and launch from Ycode.** Build → package → install into the
   guest → launch → console and LLDB over a virtual transport.

If stage 2 shows that iPhone 18 Pro firmware is out of reach, the fallback is
an older, proven device/IPSW pair for the emulator, while the toolkit and the
Ycode integration stay the same.

## 3. Constraints to decide on (owner)

- **Building iOS apps on Linux** needs the iOS SDK (headers and `.tbd`
  stubs). Apple licenses the SDK only for use on Apple-branded hardware. The
  practical setup: build on the Mac, copy the `.app` to Linux, and run it
  there. Or the owner decides to accept that license term's risk.
- **Firmware and encryption.** Ycode reads firmware from a copy the owner
  supplies. It never redistributes firmware and never decrypts encrypted
  components. Precedent: *Apple v. Corellium* (S.D. Fla. 2020, aff'd 11th
  Cir. 2023) found iOS virtualization for security research to be fair
  use. The DMCA §1201 circumvention questions are separate, and they are why
  Ycode does not decrypt.
- **Code signing in the guest.** To run a development build, the emulated
  device's signature policy must be relaxed (as test devices and jailbreak
  research do). The owner should confirm that this is acceptable for their
  use.

## 4. Clean-room rules for this track

The same protocol applies. Ycode's emulator and toolkit are original code.
QEMU (GPL-2.0) is a separate component that we would extend, with its
license respected. IPSW contents are inputs and are never committed.
Findings about formats and hardware behavior go into `specs/`.
