# Spec: running native macOS programs and apps with Ycode on Linux

Status: **design and feasibility (round 1, 2026-10-29)**, with Milestone A
implemented (§9.1). Ycode design, written in the clean room: it uses the
existing Ycode specs, public documentation and the license texts of the open
projects it names. No Apple binary was studied for it.

Related: `specs/macos/dyld.md` (Ycode's dynamic linker for macOS
processes), `specs/macos/libsystem.md` (Ycode's libSystem shim),
`specs/simulator/native-mode.md`, `docs/native-loader-evaluation.md`,
`docs/SIMULATOR-LINUX.md`, `docs/FUTURE.md` (macOS is second in the platform
order).

## 1. The goal and how it differs from the simulator

The owner's request: run native macOS apps with Ycode on Linux.

Ycode already runs Apple's iOS, iPadOS and visionOS **simulator runtimes**
on arm64 Linux. Each guest process is a KVM micro-VM; `YcodeDarwinKernel`
implements the Darwin system calls, Mach traps and IOKit; the runtime brings
its own userland (`dyld_sim`, the shared cache with libSystem, the
frameworks, the render server), and Ycode supplies three host libraries and
the host services.

A macOS program is different in one way that decides everything: **nothing
in a simulator runtime is a macOS userland.** A macOS app links against
`/usr/lib/libSystem.B.dylib`, `/usr/lib/libobjc.A.dylib`, Foundation,
AppKit, CoreGraphics, Metal and many more, all from the macOS system volume,
and expects a macOS kernel personality around them (`launchd` as pid 1,
WindowServer reached through SkyLight, IOKit drivers for the display and the
GPU). Ycode has to find that userland somewhere. §5 compares the three
places it can come from; that choice belongs to the owner (§6).

What carries over unchanged from the simulator path:

| Already in Ycode | Use for macOS programs |
|---|---|
| KVM micro-VM per process, EL1 shim, 16 KB pages, `TPIDRRO_EL0` | The same. A macOS arm64 process has the same EL0 view as a simulator process (§3) |
| `YcodeDarwinKernel` (BSD calls, Mach IPC, kevent, workqueue, IOKit registry) | The same kernel. The differences are listed in §4 |
| `YcodeMachO` (Mach-O and shared-cache parsing) | Used by the VMM to map the main executable and the dynamic linker |
| The three host libraries (`ycode/SimHostLibs`) | Reused as macOS's `libsystem_kernel`, `libsystem_platform` and `libsystem_pthread` (§9.1) |
| Metal on Vulkan (`YcodeMetalHost`, `YcodeVulkan`, `ycode-airc`) | The graphics path for macOS apps too (§8) |
| The display stream and the viewer | One way to show macOS windows (§7) |

## 2. What a macOS process expects

From the public process model (`specs/simulator/darwin-process-start.md`,
xnu and dyld headers, Apple's public documentation):

1. The kernel maps the main executable and the dynamic linker named by its
   `LC_LOAD_DYLINKER` (`/usr/lib/dyld`), builds the argument block, and
   starts the dynamic linker with the stack pointer on the Mach-header slot.
2. dyld loads `libSystem.B.dylib` and everything else, normally from the
   **dyld shared cache** of the macOS system volume, applies fixups and runs
   initializers, libSystem's first.
3. libSystem's initializer brings up the kernel, platform and pthread
   libraries, libc, malloc, libdispatch, libxpc and the rest
   (`host-library-init.md` §1.2 lists the order; it is the same on macOS).
4. GUI apps then need the Objective-C runtime, CoreFoundation, Foundation,
   AppKit, and below AppKit the window server connection (SkyLight),
   CoreGraphics, QuartzCore/CoreAnimation, CoreText, ImageIO, Metal and the
   GPU driver stack, IOKit user clients for HID and the display, launchd
   services over XPC (pasteboard, LaunchServices, font services, defaults),
   and code-signing state that the kernel and AMFI enforce.

## 3. Execution model: reuse the micro-VM

**Decision (Ycode design): run macOS processes in the same KVM micro-VM
model as simulator processes, with `YcodeDarwinKernel` as the personality.**
Native mode (`native-mode.md`) stays a later speed option for both.

Why:

- The three per-process problems that made a plain Linux process a poor fit
  for simulator code (`svc #0x80` with the number in `x16`, `TPIDRRO_EL0`,
  16 KB pages; `SIMULATOR-LINUX.md` §2) apply to macOS code word for word.
  Apple-built macOS binaries read `TPIDRRO_EL0` inline exactly as simulator
  binaries do, so any option that ever runs Apple's own macOS libraries (§5
  options 1 and 3) needs the micro-VM or a solved native-mode TLS problem.
- Everything process-wide that a macOS process needs beyond its own image
  (Mach IPC to launchd, a bootstrap server, kevent, the workqueue, IOKit)
  is already in `YcodeDarwinKernel` and is exercised daily by the iOS boot.
- One kernel personality for both platforms keeps one set of fixes; native
  mode would split it (`native-mode.md` §9, "Two code paths").
- The cost is the trap price (about 4 µs per exit, `guest-cpu.md` §7.1).
  For command-line programs and for a first GUI app this is acceptable; the
  iOS boot already lives with it.

Native mode becomes interesting once option 2 (§5) is chosen and every
library in the process is Ycode-built: then no foreign code reads
`TPIDRRO_EL0` inline and the whole TLS problem of native mode disappears
(Ycode's libraries can be compiled to use another thread register, as
Darling does). Record this as a speed path for later (§9, stage F).

How a macOS process starts under Ycode (implemented for Milestone A,
`dyld.md` §3):

1. `ycode-simd --macos <binary>` builds a VM, maps the main executable at
   its preferred address and Ycode's dynamic linker (`/usr/lib/dyld` in the
   macOS userland root) at a fixed base, both by the VMM.
2. The VMM writes the argument block (`darwin-process-start.md` §1.3), the
   commpage, the main-thread block and `TPIDRRO_EL0` exactly as for a
   simulator process.
3. The main thread starts **at the dynamic linker's entry** with `SP` on the
   Mach-header slot. There is no `dyld_sim` hand-off (no launch block, no
   host-page entry stub): the macOS dyld *is* the first user code, as on a
   Mac.
4. Ycode's dyld loads Ycode's libSystem (and through it the three host
   libraries), runs the initializers and calls `main`.

## 4. Kernel-ABI differences from the simulator path

The simulator path already provides the arm64 Darwin trap ABI, the commpage,
Mach IPC and the BSD surface. A macOS process sees the same kernel, so most
of it applies unchanged. The differences below are the ones a macOS
userland can notice. Items marked **(A)** were needed for Milestone A and
are done; the others are the plan.

| Area | Simulator path today | macOS process | Ycode plan |
|---|---|---|---|
| Executable check | `--exec`/device mode accept only iOS- and visionOS-simulator executables (`EBADARCH` otherwise) | Platform 1 (`PLATFORM_MACOS`) in `LC_BUILD_VERSION` | **(A)** The macOS mode accepts platform 1 and nothing else; simulator modes are unchanged |
| First user code | `dyld_sim`, entered through the host-page stub and the launch block | `/usr/lib/dyld`, entered directly with `SP` on the Mach header | **(A)** New start path (§3) |
| Process platform (`proc_info`, `csops`-adjacent queries) | The runtime's simulator platform | `PLATFORM_MACOS` | **(A)** The kernel's process-platform value is 1 in macOS mode |
| `sysctl` identity (`kern.osproductversion`, `kern.osversion`, `hw.model`, `hw.machine`) | Simulator runtime values; `hw.machine` = `arm64` | A Mac's: product version of the macOS release the userland claims, a Mac model identifier | Make the identity table per platform (stage B). Ycode's own libraries read none of it yet |
| Code signing and AMFI | `csops` reports from the embedded signature; nothing is enforced (simulator binaries are ad hoc or platform-signed) | On a Mac every arm64 executable page must be signed (at least ad hoc); AMFI enforces library validation and entitlements for hardened-runtime apps; `CS_PLATFORM_BINARY` marks system code | Keep **not enforcing** (Ycode is not a security boundary). Report signatures through `csops` as today. Entitlements: read from the signature and answer the queries apps make (`SecTaskCopyValueForEntitlement` path later). No AMFI emulation |
| `task_for_pid` | Implemented for the device's tasks (Mach trap 45) | Restricted on macOS to the same user with debugger entitlement, or root | Allow for the same Ycode device/session, as today; LLDB support for macOS processes uses it (stage D) |
| Sandbox | Simulator apps carry container paths; `sandbox_check` and extensions per `sandbox-extensions.md` | App Sandbox for sandboxed Mac apps: container under `~/Library/Containers/<id>`, extensions from the open/save panel | Do not enforce. Provide the container directory layout and answer `sandbox_check` "allowed". Issue extensions from Ycode's file-dialog service (§7.3) so apps that consume them work |
| Commpage | Legacy offsets that simulator binaries read (`darwin-process-start.md` §3.1) | The same arm64 commpage; macOS binaries of a current SDK may read the newer layout version | Same pages. Open question Q1 (§12): which layout version macOS-SDK binaries read. Ycode's own libraries read only fields Ycode fills |
| Page size, VA layout, `__PAGEZERO` | 16 KB pages, 4 GB `__PAGEZERO`, executables unslid | The same on Apple silicon | Unchanged |
| Pointer authentication (arm64e) | Simulator caches are arm64; PAC not exposed | macOS system binaries are arm64e; third-party apps are arm64 | Ycode's own userland is arm64. Apple's macOS libraries (option 1) are arm64e and would need PAC in the guest (the vCPU would have to expose it) or are unusable: a hard requirement of option 1, §5.1 |
| launchd | `launchd_sim` (the runtime's) under Ycode's bootstrap server | `launchd` as pid 1 with the system domain and `gui/<uid>` | Ycode's bootstrap server is the base. Option 2 needs a Ycode launchd-lite (stage C) |
| IOKit | A minimal registry for the simulator's needs (`iokit-minimal.md`) | Display (`IOMobileFramebuffer`-like and DisplayPort services), HID event system, power, GPU (`AGXAccelerator`), USB | Only through Ycode's own services; no driver emulation for Apple's GPU stack (§8) |
| Exceptions and crash reports | Mach exception ports, crash reports by Ycode | Same mechanism; ReportCrash on a Mac | Same as simulator path |

Interop identifiers named here (`PLATFORM_MACOS` = 1, `LC_BUILD_VERSION`,
`csops`, `task_for_pid`) are public header facts (evidence level 1).

## 5. Where the macOS userland comes from

### 5.1 Option 1: Apple's own macOS system libraries

Take the userland from a Mac: the dyld shared cache of the macOS system
volume (`/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/` on
current releases), the frameworks and the daemons. **Not done in this
round, and no such file was copied or used** (the brief's rule).

**Licensing (for the owner):** the macOS software license agreement allows
macOS to be installed and run only on Apple-branded computers. Copying the
system libraries to a Linux machine and running them there is, on its face,
outside that grant, whether or not Apple hardware is involved elsewhere in
the setup. Whether an interoperability exception or the owner's
jurisdiction changes this is a legal question only the owner can answer.
It also differs from the simulator case: there each user supplies a runtime
from their own Xcode, which is licensed for use with Apple's developer
tools on a Mac. This is not legal advice.

What this option would need, beyond the license:

| Need | Why | Size of the work |
|---|---|---|
| **arm64e guest** | macOS system libraries are arm64e: pointer authentication instructions on every return and indirect call. The guest vCPU must expose PAC (FEAT_PAuth) with Apple's key usage, and the kernel must manage the per-process keys (`darwin-process-start.md` has no arm64e start state yet) | Medium on a host CPU with PAuth (mandatory from Armv8.3, so the Thor qualifies; KVM must be told to expose it); impossible on a host without it |
| Apple's `dyld` and the macOS shared cache | The cache is one mapped file set, laid out for the macOS kernel's shared region | Ycode maps the simulator cache today; the macOS cache is larger (several GB) |
| **WindowServer and SkyLight** | Every AppKit window is a WindowServer window; SkyLight talks to WindowServer over Mach messages and shared memory | WindowServer is a macOS daemon that drives the display hardware through IOKit; it would have to run in the guest with Ycode emulating its display and GPU devices, or Ycode would have to implement the SkyLight server side itself. Either is very large |
| Display and GPU | WindowServer and Metal reach the GPU through the AGX kernel driver's user clients (IOKit) | Emulating Apple's GPU driver interface is far beyond the simulator work; the simulator avoids it because the simulator's Metal goes through a host-service protocol (`metal-sim-protocol.md`) that has no macOS counterpart |
| IOKit drivers | HID event system, power management, USB, audio (CoreAudio's HAL plug-ins), Bluetooth | Many services, each with private user-client methods |
| launchd services | `launchd` itself, then the daemons GUI apps call: pasteboard, LaunchServices (`lsd`), `cfprefsd`, font services, `distnoted`, `coreservicesd`, `tccd` | Each daemon is Apple code that could run in the guest (as the simulator's do) if the kernel surface is enough |
| Code signing and AMFI | System libraries and daemons check their own and their peers' signatures and entitlements | Ycode would have to answer as a Mac kernel does |

Fidelity would be the highest possible: real AppKit, real text rendering,
real Foundation. But the two hardest parts (WindowServer with its display
and GPU, arm64e) have no equivalent in the simulator work, and the license
question blocks it regardless.

### 5.2 Option 2: an open and clean-room userland (the Darling approach)

Build the macOS userland from open-source code and Ycode's own clean-room
code, all compiled for the `arm64-apple-macos` target. Every image in the
process is then something Ycode may redistribute.

Candidate components and their licenses (license read from each project's
license file or published license statement, 2026-10-29; Ycode itself is
MIT):

| Layer | Candidate | License | Fit with Ycode (MIT) |
|---|---|---|---|
| Dynamic linker | Apple `dyld` (open source) | APSL-2.0 | APSL-2.0 is a file-level copyleft: modified APSL files must be published under APSL; it can sit next to MIT code in one distribution as a **separate component built from upstream** with its patches published. Not mixable into Ycode's own files |
| Dynamic linker | **Ycode's own** (`dyld.md`, `ycode/MacUserland/dyld`) | MIT (Ycode) | Done for Milestone A |
| libc | Apple `Libc` | APSL-2.0, with many files under BSD licenses | As above |
| Kernel, platform, pthread libraries | Apple `xnu` (libsyscall), `libplatform`, `libpthread` | APSL-2.0 | As above; **Ycode already has its own** (`ycode/SimHostLibs`, MIT) |
| malloc | Apple `libmalloc` | APSL-2.0 | Ycode's own is small (`libsystem.md` §5) |
| libdispatch | `swift-corelibs-libdispatch` / Apple `libdispatch` | Apache-2.0 | Compatible with MIT (keep NOTICE and license text). Its Darwin build expects the real kevent/workqueue/Mach surface, which `YcodeDarwinKernel` provides; a stage-B task. Milestone A uses Ycode's small dispatch (`libsystem.md` §7) |
| Blocks runtime | LLVM `compiler-rt` BlocksRuntime | Apache-2.0 WITH LLVM-exception | Compatible; Milestone A uses Ycode's own (§7 of `libsystem.md`), written from the public Block ABI specification |
| Objective-C runtime | Apple `objc4` | APSL-2.0 | Separate component built from upstream; or GNUstep's `libobjc2` (MIT) which implements a different ABI and does not run Apple-ABI binaries |
| CoreFoundation | `swift-corelibs-foundation`'s CoreFoundation (CF-Lite lineage) | Apache-2.0 with the Swift Runtime Library Exception | Compatible |
| Foundation | `swift-foundation` (FoundationEssentials, FoundationInternationalization) and `swift-corelibs-foundation` | Apache-2.0 with Runtime Library Exception | Compatible. Built for a Darwin target it would normally *be* Apple's Foundation's role; on Ycode it is the open Foundation (§9, stage B) |
| ICU | `swift-foundation-icu` / ICU | Unicode License v3 (ICU) | Compatible |
| Swift runtime and stdlib | `swift` repository | Apache-2.0 with Runtime Library Exception | Compatible; Milestone A uses Embedded Swift (no runtime library) |
| AppKit | GNUstep `libs-gui` / `libs-base` | LGPL (version 2 or later per the GNUstep file headers; to be re-checked per release before any use) | **Reference only** (no code copied into Ycode). Linking LGPL libraries dynamically is allowed, but GNUstep's ABI is not Apple's: Apple-built app binaries cannot use it |
| AppKit | **Ycode's own AppKit** (clean room, from Apple's public documentation and black-box behavior) | MIT (Ycode) | The recommended long-term path (§6); the `frameworks/` area already does this for SwiftUI and others |
| Whole-system reference | Darling | GPL-3.0 (plus APSL-2.0 parts) | **Design reference only.** No code may be copied: GPL-3.0 is incompatible with releasing Ycode under MIT (`native-loader-evaluation.md` §6) |
| Loader reference | Kakehashi | Apache-2.0 | Reference only; unmaintained; no code used |
| Display (Linux side) | libwayland, libxcb | MIT (both) | Compatible, for the Linux-window path (§7) |

What runs under this option, and what does not:

- **Runs:** programs built from source against the macOS SDK that use only
  what the open userland implements. Command-line tools first (Milestone A
  proves it), then Foundation tools (stage B), then apps written against
  Ycode's AppKit subset (stage D).
- **Does not run, ever, without option 1:** binaries that need private
  Apple frameworks, and anything whose behavior depends on Apple's
  implementation details (exact text layout, private SPI).
- **Third-party app binaries** (downloaded, not rebuilt) run when every
  symbol they import is provided with a compatible ABI. For AppKit apps
  that is a very large surface; this is where most of the effort goes.

### 5.3 Option 3: a hybrid

Ycode's open userland at the bottom (dyld, libSystem, the host libraries,
dispatch, objc, CoreFoundation, Foundation) and **Apple's own frameworks
above it** for the parts that are hard to rewrite (AppKit, CoreText,
CoreGraphics, ImageIO), loaded from a Mac by the user.

It carries the full license problem of option 1 (the frameworks are macOS
system software) plus an ABI problem of its own: Apple's frameworks call
private SPI in the lower layers (libdispatch, objc4, CoreFoundation,
libxpc) and expect exact structure layouts there. Every private call would
have to be found (dirty room) and reimplemented. It also inherits option
1's arm64e requirement, because the frameworks are arm64e. It is the
least attractive option: most of the cost of both, with fidelity limited
by the open bottom layers.

### 5.4 Comparison

| | Option 1: Apple's libraries | Option 2: open + clean room | Option 3: hybrid |
|---|---|---|---|
| Fidelity | Highest: the real AppKit, text, Foundation | Behavior-compatible for what is implemented; visibly different for complex UI | High in the Apple frameworks, limited by the open bottom layers |
| Effort to the first CLI program | Medium (arm64e, the macOS cache) | **Done** (Milestone A) | Same as option 2 |
| Effort to the first GUI window | Very large: WindowServer + SkyLight + display/GPU drivers | Medium: Ycode's own window protocol on the display stream or a Linux surface (§7, stage D) | Very large: SkyLight's server side is needed for Apple's AppKit |
| Effort to "most apps run" | Large but bounded by kernel/driver fidelity | Very large: the AppKit surface | Very large, and fragile |
| Licensing | **Blocked** pending the owner's decision (§5.1) | Clean: MIT plus Apache-2.0 components; APSL-2.0 components only as separate, upstream-built parts with published patches | **Blocked** as option 1 |
| Performance | The KVM trap cost (§3); Apple's code is well optimized | KVM trap cost now; native mode possible later because no foreign code reads `TPIDRRO_EL0` inline (§3) | KVM only |
| What runs first | Any arm64e-capable system tool | Our own CLI programs (done), then Foundation CLIs | Same as option 2 |
| Redistributable by Ycode | No | Yes | No |

## 6. Recommendation and the owner's decisions

**Recommendation: option 2, in stages (§9), with the micro-VM model.**

- It is the only option Ycode can ship and redistribute, and the only one
  that is not blocked today.
- It reuses what exists: the kernel personality, the three host libraries,
  Metal on Vulkan, the display stream, the `frameworks/` effort (open
  SwiftUI and others), and now Ycode's dyld and libSystem.
- It fits the project's direction (`docs/FUTURE.md`: open framework
  reimplementations, AppKit listed as later work).
- It keeps native mode open as a large speed-up later (§3).

Decisions only the owner can make:

1. **Option 1 or 3 at all?** Whether running Apple's macOS system
   libraries on Linux is acceptable under the macOS license in the owner's
   situation (§5.1). Until the owner decides, Ycode does not copy or use
   them. If the answer is ever yes, the first engineering gate is arm64e in
   the guest.
2. **APSL-2.0 components.** Whether Ycode may ship upstream-built APSL-2.0
   components (for example `objc4` for Apple-ABI Objective-C) as separate
   parts with published patches, or must reimplement each one clean-room.
   The recommended default is: Apache-2.0 components yes (libdispatch,
   CoreFoundation and Foundation from swift-corelibs and swift-foundation),
   APSL-2.0 components only after the owner agrees.
3. **The AppKit strategy.** Ycode's own AppKit (recommended; months of
   work for a useful subset) versus limiting macOS support to command-line
   and Foundation programs plus SwiftUI apps on Ycode's open SwiftUI.
4. **Where windows appear** (§7): on the Mac through the display stream
   (fits the IDE), as Linux windows (fits "run Mac apps on Linux"), or both.

## 7. Windowing, input, clipboard and file dialogs

Ycode-design. Applies to option 2 (Ycode's AppKit); option 1 would need
WindowServer instead (§5.1).

### 7.1 Windows

A macOS app has many top-level windows, each with its own size, position,
level, title and shadow, unlike the simulator's single screen. Ycode's
AppKit renders each window's content itself (CoreAnimation-like layer tree,
drawn with Metal on Vulkan, §8) into a **window surface**, and a Ycode
host service, the **window broker**, owns the surfaces:

| Message (guest → broker) | Meaning |
|---|---|
| `create(window id, frame, style, level, title)` | A new top-level window |
| `present(window id, surface, damage rects)` | New pixels for a window; the surface is shared memory (as `iosurface-remote.md` does for IOSurfaces) |
| `set(window id, frame / title / level / visible / key)` | Window attribute changes |
| `destroy(window id)` | The window closed |

The broker shows the windows in one of two places (decision 4, §6):

- **Linux host windows.** Each guest window becomes a Wayland `xdg_toplevel`
  (or an X11 window), with server-side decorations off, because AppKit
  draws its own title bar. Pixels go in as shared-memory buffers first and
  as dmabuf-backed Vulkan images later. Window moves and resizes from the
  Linux side come back to the guest as frame-change events.
- **The display stream to the Mac.** The broker composes all windows onto
  one virtual desktop (a "screen" of a chosen size) and sends it through
  the existing display stream (`display-stream.md`), so the IDE's viewer
  shows it like a simulator screen. A later protocol revision can carry
  windows individually so the Mac viewer shows them as separate macOS
  windows.

The broker is a host service like the others (IOSurface, audio, camera);
the guest reaches it through the bootstrap server under a Ycode service
name, never under an Apple name.

### 7.2 Input

Keyboard, mouse, scroll and trackpad gestures come from the host window
system (Wayland `wl_pointer`/`wl_keyboard`, X11 events) or from the
display-stream viewer's existing HID path (`hid-input.md`), and are
delivered by the broker as **window-relative events** with the window id.
Ycode's AppKit turns them into `NSEvent` objects. Keyboard layout and text
input: the broker sends key codes in the USB HID usage space plus the
produced text, so the guest needs no keyboard-layout database at first;
input methods (composition) come later through a text-input protocol
(Wayland `text-input-v3`).

### 7.3 Clipboard and file dialogs

- **Clipboard:** a broker-side pasteboard service with the general
  pasteboard and named pasteboards. Types are UTIs on the guest side,
  mapped to MIME types on the Linux side (`public.utf8-plain-text` ↔
  `text/plain;charset=utf-8`, `public.png` ↔ `image/png`, file URLs ↔
  `text/uri-list`). The Mac viewer path uses the Mac's pasteboard through
  the viewer.
- **Open and save panels:** Ycode's AppKit asks the broker; the broker
  shows a native dialog on the host side (the XDG desktop portal
  `FileChooser` on Linux, an `NSOpenPanel` in the viewer on the Mac) and
  returns the chosen path, mapped into the guest's file system. The broker
  also issues the sandbox extension for that path (§4, Sandbox), which is
  how a sandboxed app is allowed to open it.

## 8. Graphics: Metal on Vulkan

Ycode already translates the simulator's Metal to Vulkan: Metal Shading
Language through AIR to SPIR-V (`ycode-airc`), and the Metal API calls
through the host-service protocol `metal-sim-protocol.md` to `YcodeMetalHost`
and `YcodeVulkan`. For macOS:

- Under option 2, Ycode's macOS `Metal.framework` is a guest library that
  speaks the same Ycode protocol to the same host service. The protocol is
  platform-neutral; macOS-only API (for example managed storage mode,
  `MTLStorageModeManaged`, and discrete-GPU queries) needs additions to it.
- Window presentation: `CAMetalLayer` drawables become window surfaces of
  §7.1 instead of the simulator framebuffer.
- Shaders compiled for the macOS GPU family come as AIR in a `.metallib`
  exactly like the simulator's, so `ycode-airc` handles them; macOS-only
  MSL features (for example some texture formats) are added as found.
- Under option 1, Apple's Metal driver stack (AGX user clients) has no
  Ycode equivalent; that is part of why option 1 is so large.

## 9. Staged plan

Each stage has a done-criterion that can be checked on the Thor.

| Stage | Content | Done when |
|---|---|---|
| **A** | Our own macOS arm64 command-line programs on Ycode's dyld, Ycode's libSystem and the three host libraries, started by `ycode-simd --macos` | The five samples (§9.1) print the expected output and exit with the expected status |
| **B** | Foundation CLIs: Apache-2.0 libdispatch, CoreFoundation and Foundation (`swift-foundation`, `swift-corelibs-foundation`) built for `arm64-apple-macos` against Ycode's libSystem; a Swift runtime (`libswiftCore`) built for Darwin from the open Swift repository; the sysctl identity per platform | A Swift CLI that uses `Foundation` (`Date`, `JSONEncoder`, `FileManager`, `URLSession` to localhost) runs with correct output |
| **C** | Process model: `posix_spawn`/`exec` of macOS binaries from macOS binaries, a Ycode launchd-lite for the `system` and `gui/<uid>` domains on Ycode's bootstrap server, XPC to Ycode services, `cfprefsd`-equivalent defaults | A shell (built from source) runs pipelines of our CLIs; `defaults read/write` round-trips |
| **D** | Windowing prototype then Ycode's AppKit subset: the window broker (§7.1) on one Linux display and on the display stream; `NSApplication`, `NSWindow`, `NSView`, events, text drawing | A test program shows one window with text, takes keyboard input and closes cleanly; then a small document-based app |
| **E** | Graphics: Ycode's macOS `Metal.framework` on the existing protocol; `CAMetalLayer` windows | A Metal triangle sample renders in a window |
| **F** | Speed: native mode for all-Ycode processes (no foreign `TPIDRRO_EL0` readers); x86-64 support decisions (§10) | Measured per-call cost against the micro-VM |

### 9.1 Milestone A (implemented this round)

The programs are Ycode's own (`ycode/MacUserland/samples/`), built on the
Mac with `-target arm64-apple-macos14.0` against the macOS SDK (the SDK's
`.tbd` link stubs only; no Apple code ends up in them). The Swift sample is
Embedded Swift built by the open Swift toolchain on Linux (the Mac's Xcode
toolchain has no Embedded standard library for macOS; `libsystem.md` §10).

| Sample | What it exercises |
|---|---|
| `hello` | `printf` formatting, `argv`, the environment, `snprintf`, the exit status (3 with `fail`) |
| `fileio` | `fopen`/`fprintf`/`fgets`/`fclose`, `stat`, `open`/`write`/`lseek`/`pread`, `errno`, `strerror`, `unlink` |
| `threads` | `pthread_create`/`join`, a mutex, a condition variable, thread-specific data |
| `dispatch` | Serial and global queues, groups, `dispatch_sync`, `dispatch_apply_f`, semaphores, `dispatch_once`, `dispatch_after` on the main queue, `dispatch_main`, blocks with `__block` variables |
| `hello-swift` | Embedded Swift: structs, a class, arrays, a dictionary, string interpolation, `print` |

The run command (from `ycode/`, after `sh MacUserland/build.sh`):

```sh
.build/release/ycode-simd --macos <sample> [--env K=V]... [--exec-args <arg>...]
```

Results: §9.2.

### 9.2 Milestone A results (2026-10-29, the Thor)

`sh MacUserland/run-samples.sh .build/release/ycode-simd <samples>`:

| Sample | Result |
|---|---|
| `hello a b` (with `--env YCODE_SAMPLE=…`) | Expected output, exit 0 |
| `hello fail` | Expected output, exit 3 |
| `fileio` | Expected output (`size 790`, 100 lines, `pread` of the appended tail, `ENOENT` text), exit 0 |
| `threads` | 8 threads × 10,000 locked increments = 80,000, join sum 308, exit 0 (3 of 3 runs) |
| `dispatch` | All five lines, exit 0 (8 of 8 repeated runs, 174–272 traps each) |
| `hello-swift` (Embedded Swift) | Expected output, exit 0 |

What it proves: the VMM maps a macOS executable and Ycode's dyld; the dyld
loads Ycode's libSystem and the three host libraries through the guest VFS,
applies chained fixups, resolves two-level binds through re-exports, runs
libSystem's initializer (which brings up the kernel, platform and pthread
libraries exactly as on the simulator path) and `main`; system calls,
threads (`bsdthread_create`), ulock waits and timed waits work for a
platform-1 process. A trivial program costs about 60 traps.

Failure paths checked: a missing libSystem prints
`dyld[100]: Library not loaded: /usr/lib/libSystem.B.dylib` and the
process ends with status 134; `DYLD_PRINT_LIBRARIES=1` lists the five images.
The platform gate holds both ways: `--macos` on an iOS-simulator executable
and `--exec` on a macOS executable both fail with `EBADARCH` (86), and the
simulator path is unchanged (`--exec` of the iOS 27.1 runtime's `df` runs
as before).

Problems found and fixed on the way: `dispatch_sync` callers could occupy
every worker while the queue's drain task waited for one (fixed: whoever
owns a serial queue keeps draining it, `libsystem.md` §7.2); a 128-bit
division needed a compiler-runtime helper (removed); Embedded Swift cannot
print an `Array` directly (the sample prints the elements).

### 9.3 Milestone B status

- **Foundation CLI: not yet, for a structural reason.** Every open
  Foundation (swift-corelibs-foundation, swift-foundation) needs the
  non-embedded Swift runtime (`libswiftCore`) and the Swift standard
  library built for a Darwin target. The open toolchains ship those for
  Linux only, and on Darwin targets the Swift runtime is built with
  Objective-C interoperability, which needs an Objective-C runtime (Apple's
  `objc4`, APSL-2.0: owner decision 2, §6, or a clean-room one). The
  CoreFoundation part also needs much more of libc (locales, `stat`
  families, `readdir`, `pthread` keys, ICU) and the full libdispatch.
  The plan is stage B (§9): build the Apache-2.0 libdispatch for
  `arm64-apple-macos` against Ycode's libSystem first, then a Swift runtime
  for Darwin without Objective-C interop (a non-standard configuration of
  the open Swift build that must be tried), then swift-foundation's
  FoundationEssentials, which has fewer dependencies than
  swift-corelibs-foundation.
- **Windowing prototype: design only this round** (§7). The display
  stream today reads the simulator's frame record and IOSurfaces from the
  IOSurface host service, which only device mode starts; a macOS process
  has neither. The smallest working path is the window broker of §7.1 with
  shared-memory surfaces, served by the same display-stream server.

## 10. x86-64 macOS apps

Apple silicon Macs run x86-64 apps through Rosetta 2, which translates
x86-64 code to arm64 ahead of time and at run time inside the process. It is
Apple software, licensed for Macs, and has no Linux equivalent that runs
Mach-O x86-64 binaries. Options:

| Option | How | Cost | License |
|---|---|---|---|
| Not supported (default) | `ycode-simd --macos` refuses non-arm64 executables (`EBADARCH`), as today | None | — |
| User-mode translator in the guest | An x86-64 → arm64 translator runs inside the micro-VM as the process's first image, translates the x86-64 Mach-O and its x86-64 libraries, and maps x86-64 Darwin system calls onto Ycode's arm64 personality. FEX-Emu (MIT) and Box64 (MIT) are open translators for **Linux ELF**; either would need a Mach-O loader, the Darwin x86-64 syscall and TLS (`gs`-based) conventions, and x86-64 builds of the whole userland (option 2's libraries, built for x86-64) | Very large: a second architecture for every userland library, plus translator work | MIT translators fit |
| Full-system x86-64 emulation | Run x86-64 guests in QEMU TCG with an x86-64 Darwin personality | Very slow; Ycode's kernel personality would need an x86-64 trap ABI | QEMU is GPL-2.0: only as a separate program |

Recommendation: not supported until arm64 macOS apps run well (after
stage E). The x86-64 Linux host case is separate (`SIMULATOR-LINUX.md` §4:
user-mode arm64 translation on an x86-64 host, deferred).

## 11. Risks

- **The AppKit surface is huge.** Option 2's value depends on how much of
  AppKit Ycode reimplements. Mitigation: target apps built from source
  first, and SwiftUI apps on Ycode's open SwiftUI.
- **ABI drift.** Third-party binaries embed SDK structure layouts and
  inline functions (for example `FILE` macros, `dispatch_once`'s inline
  fast path, `os_unfair_lock`'s size). Ycode's libraries must match those
  public layouts exactly (`libsystem.md` §4 lists the ones Milestone A
  relies on).
- **Two loaders.** The simulator path uses the runtime's `dyld_sim`; macOS
  uses Ycode's dyld. Kernel changes must keep both working. Mitigation:
  the macOS start path shares everything except the first PC.
- **APSL components.** If the owner rejects APSL-2.0 parts, `objc4` must
  be reimplemented clean-room before any Apple-ABI Objective-C runs, which
  gates Foundation-on-Darwin and AppKit.
- **Performance.** Every system call is a VM exit; GUI apps with many
  small calls may be slow until native mode exists (§3).
- **Owner decisions pending** (§6): the license question for options 1
  and 3 blocks those options entirely.

## 12. Open questions

- **Q1.** Which commpage layout version do binaries built with a current
  macOS SDK read? Ycode's libraries do not depend on it; Apple-built code
  (option 1) and inlined SDK code might. To be answered by a dirty-room
  observation of the public commpage header's version field use.
- **Q2.** Which `apple[]` strings does the macOS kernel pass that a macOS
  userland reads (beyond `executable_path`)? Ycode's dyld needs only
  `executable_path`; option 1 would need the full set.
- **Q3.** The exact `sysctl` identity values a Mac reports for the release
  Ycode claims (stage B).

## Evidence

| Claim | Level (AGENTS.md rule 4) |
|---|---|
| Process start (dyld entry, argument block, Mach header on the stack), `LC_BUILD_VERSION`, `PLATFORM_MACOS` = 1, chained fixups | 1 (public xnu/dyld/Mach-O headers; `darwin-process-start.md`) |
| libSystem initializer order and host-library interfaces | Existing Ycode spec `host-library-init.md` (its own evidence) |
| arm64e in macOS system binaries; shared cache location | 1 (Apple's public documentation and developer talks on arm64e and the cryptex-based system volume) |
| macOS license terms (Apple-branded computers) | Public license text |
| Component licenses (§5.2) | Each project's published license file or statement; GNUstep's to be re-checked |
| Darling and Kakehashi properties | `docs/native-loader-evaluation.md` |
| Rosetta 2 behavior | 1 (Apple's public documentation) |
| Everything marked "Ycode plan" or "Ycode-design" | Ycode design, no Apple evidence needed |
