# Notes: public talks on how iOS and the iOS Simulator execute code, and what Ycode's simulator lacks

Dirty-room prose (agent TALKS, 2026-10-17). Research only: nothing here is
a spec, and nothing in `ycode/` or `specs/` was changed.

**Second pass (2026-10-17, after a host restart).**
- Added the topics the first pass had not reached: Mach exceptions and
  thread suspension, memory limits and memory pressure, prewarming,
  workloops, and XPC/launchd on-demand semantics.
- Processed three more media.ccc.de talks (§1.1).
- Re-checked every G-row against the newest simulator line (§2.1). Main
  (`m2-workspace-settings`) has no simulator source changes since the
  first pass. The simulator speed work lives on `speed-int` and on worktree
  branches.
- New gaps: **G13** (Mach exceptions and thread suspension, high for
  compatibility) and **G14** (memory-pressure events, low). New
  parity-verified rows: **P4** (jetsam) and **P5** (prewarm).
- G1–G4 updated with the newer measurements; the order in §3.1 is revised.

**Method and clean-room status.**
- Sources are public: talk pages and their subtitle files (media.ccc.de API
  and c3subtitles mirrors), conference abstracts, Apple session pages and
  transcripts, Apple's public open-source documents (dyld, xnu,
  libdispatch), man pages, and blogs.
- Downloads: five subtitle files in the first pass and one more in the
  second (36C3 Messenger Hacking), about 400 KB in total, in the session
  scratchpads (`talks/subs/`). No video, slide deck or binary was
  downloaded. Nothing downloaded was executed.
- No Apple binary, `.claude/Xcode.app`, `research/dirty/` or Ghidra project
  was opened.
- Several talks show decompiled or disassembled code on their slides.
  None of it was transcribed. These notes record behaviour, mechanisms, and
  interop names only.
- Ycode facts come from reading our own documents and source (paths
  given). Measured Ycode numbers come from
  `specs/simulator/performance-contract.md` and `docs/postmortem-kvm-sve.md`.

**Evidence quality key** (the project's rule-4 levels, plus the kind of
source):
- **L1-doc**: Apple public documentation or man page.
- **L1-src**: Apple open-source document or header.
- **talk**: a conference talk (a secondary source; claims are the
  speaker's).
- **blog**: a third-party write-up.
- **L3**: our own black-box or Ycode measurement.

---

## 1. Sources

### 1.1 Hacker-conference talks (media.ccc.de)

**"Tales of old: untethering iOS 11"**, littlelailo, 36C3 (2019).
<https://media.ccc.de/v/36c3-11034-tales_of_old_untethering_ios_11>.
Read from the English subtitles. Quality: talk.
- At boot, launchd is the first process. It reads its LaunchDaemon job
  list and spawns every job marked to run at load. Daemon configuration
  files are therefore part of the boot critical path.
- **The dyld shared cache is slid once per boot.** That one slide is then
  used in every process, because the cache is shared by all of them. The
  shared region has a hard-coded base and size. The talk's ASLR bypass
  works because the cache's data segment grew larger than the maximum
  slide. This confirms the device model: one cache mapping, prepared once,
  reused by every process at no per-process cost.
- Code signing has two paths. Platform binaries are checked against a
  kernel **trust cache**, a list of hashes. Third-party code is checked by
  a user-space daemon (amfid).
- Sandbox profiles are per-process labels held in the kernel.
- Relevance to Ycode: background for the shared-region gap (§3, G4). The
  rest concerns the device, not the simulator.

**"Jailbreaking iOS — from past to present"**, tihmstar, 35C3 (2018).
<https://media.ccc.de/v/35c3-9618-jailbreaking_ios>. Read from the
subtitles. Quality: talk.
- AMFI is the kernel extension that enforces code signing. amfid is its
  user-space helper. The trust cache holds platform hashes.
- The `get-task-allow` entitlement allows read/write/execute mappings.
  Jailbreaks add it to every process so that hooking works.
- Hardware mitigations covered: KPP/KTRR (read-only kernel regions) and
  PAC.
- Relevance: the simulator runs arm64, not arm64e, and has no AMFI
  enforcement of its own. These facts mostly show that the device
  mitigations are **not** our problem. The one thing to keep is the
  RWX-mapping semantics for JIT (G7).

**"Asahi Linux — Porting Linux to Apple Silicon"**, sven, 39C3 (2025).
<https://media.ccc.de/v/39c3-asahi-linux-porting-linux-to-apple-silicon>.
Read from the subtitles. Quality: talk.
- Asahi studies the hardware without reading disassembly. It runs the real
  OS under a thin hypervisor (m1n1) that traces every MMIO access, which
  the speaker describes as "strace for hardware".
- This is the same black-box idea as our VMM trap tracing. It supports our
  method; it is not a new mechanism.
- Related prior art (Asahi/Fedora documentation, blog, see §1.5): muvm,
  a libkrun micro-VM, runs a 4 K-page guest kernel on a 16 K-page host so
  that FEX can run x86 software. This mirrors Ycode's 16 K-guest-on-4 K-host
  micro-VM choice and supports it.

**"Breathing Life into Legacy: An Open-Source Emulator of Legacy Apple
Devices"**, Martijn de Vos, 37C3 (2023).
<https://media.ccc.de/v/37c3-11871-breathing_life_into_legacy_an_open-source_emulator_of_legacy_apple_devices>.
Quality: talk.
- QEMU-iOS emulates the full system of an iPod touch 1G/2G: bootloader,
  XNU, and peripherals (touch, storage, display).
- Relevance: option A only (full-system emulation), which is superseded.
  It adds nothing for the simulator runtime.

**"Demystify Mach-O"**, Garrigan, CCCamp 2023.
<https://media.ccc.de/v/camp2023-57032-demystify_mach_o>. Quality: talk.
- An introduction to fat headers, load commands, segments and sections,
  and walking ObjC class lists at run time.
- Nothing in it goes beyond `specs/simulator/loader.md` and our
  `YcodeMachO`.

**"Escape the macOS sandbox and TCC"**, Alkemade and Keuper, rC3 (2020), and
the MCH2022 follow-up.
<https://media.ccc.de/v/rc3-10175-escape_the_macos_sandbox_and_tcc>.
Quality: talk (abstract only).
- Covers macOS sandbox and TCC trust boundaries between apps and XPC
  services.
- Relevance: low. Our sandbox extensions are already accept-and-record
  (`specs/simulator/sandbox-extensions.md`).

**"Messenger Hacking: Remotely Compromising an iPhone through iMessage"**,
Samuel Groß, 36C3 (2019).
<https://media.ccc.de/v/36c3-10497-messenger_hacking_remotely_compromising_an_iphone_through_imessage>.
Read from the English subtitles in the second pass. Quality: talk.
- Every system library is prelinked into the one dyld shared cache.
- On a device, the cache is randomized **once per boot**, so every process
  has it at the same virtual address. The talk's ASLR bypass probes in
  cache-sized steps on that basis.
- This independently confirms the 36C3 untether talk: on the device, the
  cache is a once-per-boot, system-wide mapping (G4).
- The rest (ObjC isa/method-table hijack, PAC) is device exploitation and
  does not apply to the simulator.

**"Of Wayland, MicroVMs and more: Running Linux applications on OSX"**,
Drakulix, MRMCD 2026. <https://media.ccc.de/v/2026-638-of-wayland-microvms-and-more-running-linux-applications-on-osx>,
<https://talks.mrmcd.net/2026/talk/N9SNKN/>. Quality: talk (abstract only;
no subtitles yet, and the video was not downloaded).
- This is the reverse of our direction: Linux apps on macOS through
  micro-VMs plus graphics and windowing translation layers. It names the
  same barriers we meet: page size, the graphics API, and integration
  outside the VM.
- It is design prior art only. Watch for subtitles if host-service bridging
  (display, input) needs a second opinion.

**Also checked, with no execution-side content for us:** 24C3 "Inside the
Mac OS X Kernel" (2007, a Mach/BSD/IOKit overview, superseded by
our specs), 36C3 "KTRW"
(Azad, kernel debugging on a device), 37C3 "Operation Triangulation"
(device exploit chain and hardware registers), 34C3 "iOS kernel
exploitation archaeology", and 33C3 "Downgrading iOS".

### 1.2 Other security conferences and researcher blogs

**"Behind the Scenes with iOS Security"**, Ivan Krstić (Apple), Black Hat
USA 2016. Slides:
<https://blackhat.com/docs/us-16/materials/us-16-Krstic.pdf>. Quality:
talk by Apple (primary but high-level).
- JIT is allowed only for processes with the dynamic-codesigning
  entitlement.
- iOS 9 used a single 32 MB RWX JIT region. iOS 10 hardened the WebKit
  JIT mapping.
- Relevance: JavaScriptCore is the main JIT client in simulator processes
  (WebKit and JSContext users) (G7).

**"APRR"** (blog), Siguza. <https://blog.siguza.net/APRR/>. Quality: blog
(a careful researcher).
- On Apple chips, per-thread W^X switching of the JIT region works through
  an EL0-writable implementation-defined system register.
- The permitted register values come from fixed commpage fields that the
  kernel fills in. User code re-checks them after each switch.
- This is what `pthread_jit_write_protect_np` relies on on Apple silicon.
  An emulator without that register cannot offer the per-thread toggle and
  must report it as unsupported (G7).

**"A Year Fuzzing XNU Mach IPC"**, STAR Labs, Hexacon 2023.
<https://starlabs.sg/publications/a-year-fuzzing-xnu-mach-ipc/>.
Quality: talk (abstract only; the slides are on their GitHub and were not
needed).
- It confirms that Mach IPC is a large, edge-case-heavy surface. Nothing
  new beyond `specs/simulator/mach-ipc.md`.

**"MacDirtyCOW"**, Ian Beer, OffensiveCon 2023.
<https://citation.thinkst.com/talk/84538>. Quality: talk (abstract only).
- Copy-on-write bugs in the XNU VM. Relevant only in that our Mach-VM
  emulation (memory entries, COW) has no known open issue that this
  informs.

**"Finding and exploiting an old XNU logic bug"**, Synacktiv, Hexacon
(slides:
<https://synacktiv.com/sites/default/files/2024-11/finding_and_exploiting_an_old_xnu_logic_bug.pdf>).
Quality: talk. VFS/vnode logic; no execution-side gap for us.

**"What is the minimum number of libraries to run a hello world on iOS
Simulator"** (blog).
<https://threedots.ovh/blog/2021/10/what-is-the-minimum-number-of-libraries-to-run-a-hello-world-on-ios-simulator/>.
Quality: blog.
- `dyld_sim` is found through `DYLD_ROOT_PATH`. Without it, a simulator
  binary aborts at once.
- There is no chroot or namespace; the simulator shares the host's
  file-system view.
- About 40 Mach-O files are enough for hello world.
- This matches `specs/simulator/dyld-sim-handoff.md` and
  `docs/SIMULATOR.md` §5.

**Frida 17.4.0 release notes**
(<https://frida.re/news/2025/10/12/frida-17-4-0-released/>). Quality:
blog/release notes.
- On recent iOS 18 simulators, `dyld_sim` is **hidden** from
  `_dyld_image_count` and from `TASK_DYLD_ALL_IMAGE_INFO_64`. This broke
  sysroot detection in tools.
- Relevance: debugger and instrumentation interop on our Linux simulator
  (G11).

**LLDB commit on telling dyld from dyld_sim**
(<https://repo.hca.bsc.es/gitlab/rferrer/llvm-epi/-/commit/fddafa110d8628851a48939fe956864b318e8e53>).
Quality: open source.
- A simulator process has two dynamic linkers. LLDB tells them apart by
  the target triple. Relevant to lldb-dap attach on the Linux simulator
  (G11).

**"Hacking native ARM64 binaries to run on the iOS Simulator"** (Bogo
Giertler; tool arm64-to-sim). Quality: blog.
- Device and simulator Mach-O differ only in the platform (2 vs 7 in
  `LC_BUILD_VERSION`) and in what they link against.
- Relevance: low. It confirms that the platform check is a load-time gate,
  as `host-library-loading.md` §2 already says.

### 1.3 Apple WWDC sessions (public talks by Apple engineers)

**"Link fast: Improve build and launch times"**, WWDC22 session 110362.
<https://developer.apple.com/videos/play/wwdc2022/110362/>. Quality:
L1-doc (Apple, transcript).
- Launch steps: map the main executable and its dependencies recursively,
  bind, apply fixups (rebases and binds), run initializers bottom-up.
- The unchanging part is cached on first launch.
- **Chained fixups**: LINKEDIT holds only the first fixup of each page;
  the chain is threaded through the DATA pointers themselves.
- **Page-in linking**: the kernel applies a DATA page's fixups when the
  page is first faulted in. This applies at launch only (`dlopen` uses the
  old path). DATA_CONST pages stay clean.
- The OS cache dylibs have used this lazy scheme "for over a decade".
- `dyld_usage` measured TextEdit at 15 ms total launch, 1 ms of it in
  fixups.
- Relevance: our spec records that page-in linking is compiled out of
  `dyld_sim` and that simulator caches are unslid (`dyld-sim-handoff.md`
  §4.2, `host-library-loading.md` §3.1). On the device, Apple avoids the
  per-process cost of preparing the cache. On the Mac simulator, private
  `mmap` faults lazily in the host kernel. Ycode builds page tables
  eagerly (G4).

**"App Startup Time: Past, Present, and Future"**, WWDC17 session 413
(notes:
<https://wwdcnotes.com/documentation/wwdc17-413-app-startup-time-past-present-and-future/>).
Quality: L1-doc via community notes.
- dyld3 launch closures are computed out of process. System apps' closures
  are built into the shared cache; third-party closures are built at
  install time.
- The shared cache saves 0.5–1 GB of RAM on a typical iOS system.

**"Optimizing App Launch"**, WWDC19 session 423.
<https://developer.apple.com/videos/play/wwdc2019/423/>. Quality: L1-doc.
- Launch phases: dyld, libSystem init, static runtime init (ObjC/Swift,
  `+load`), UIKit init, application init, first frame, extended phase.
- Target: first frame within 400 ms; iOS's own share is about 100 ms.
- iOS 13 extended dyld3 caching to apps and made scheduler changes for
  faster launches. The speaker says these "make preserving QoS across
  threads more important".
- Relevance: launch speed on Apple platforms depends on the scheduler
  honouring QoS (G1).

**"Swift concurrency: Behind the scenes"**, WWDC21 session 10254.
<https://developer.apple.com/videos/play/wwdc2021/10254/>. Quality:
L1-doc.
- The cooperative thread pool creates **only as many threads as there are
  CPU cores** and does not grow when work blocks.
- Moving onto and off the main actor costs a context switch.
- Semaphores and condition variables break the forward-progress contract.
- Relevance: a guest told "1 CPU" gets a one-thread Swift executor per
  process (G2).

**"Modernizing Grand Central Dispatch Usage"**, WWDC17 session 706.
<https://developer.apple.com/videos/play/wwdc2017/706/>. Quality: L1-doc.
- QoS classes are UI, IN, UT, BG.
- Since iOS 11/macOS 10.13, every dispatch queue has a kernel counterpart
  (unified queue identity). Thread requests carry priority. The kernel
  raises them when higher-QoS work arrives, and a synchronous waiter can
  hand the CPU straight to the owner.
- Only single-owner primitives (serial queues, `os_unfair_lock`) get
  inversion resolution; semaphores and groups do not.
- Fair locks cause a "staircase" of context switches; unfair locks avoid
  it.
- Relevance: our kernel lock L0 and every wait queue are FIFO and know
  nothing of priority (G1, G8).

**"Efficient Design with XPC"**, WWDC13 session 702 (notes:
<https://wwdcnotes.com/documentation/wwdc13-702-efficient-design-with-xpc/>).
Quality: L1-doc via notes.
- XPC services start in the background by default.
- **Importance boosting** gives a service full resources while it works
  for an app. The `ProcessType` key selects Standard, Adaptive,
  Background, or Interactive.

**"Improve app size and runtime performance"**, WWDC22 session 110363
(<https://developer.apple.com/videos/play/wwdc2022/110363/>). Quality:
L1-doc.
- On iOS 16, Swift protocol-conformance results are precomputed in the
  dyld closure at install time. On real apps the runtime scan had cost up
  to half of launch time.
- Relevance: `dyld_sim` has no prebuilt loaders (`host-library-loading.md`
  §3.5). Apple's simulator pays the same scan, so this is parity-neutral
  and not a gap (row P2 of the table).

**"Why is my app getting killed?"**, WWDC20 session 10078 (notes:
<https://wwdcnotes.com/documentation/wwdc20-10078-why-is-my-app-getting-killed/>).
Quality: L1-doc via notes.
- Six termination causes: crash, CPU resource limit, watchdog (code
  `0x8badf00d`) on launch and resume transitions, memory limit, memory
  pressure, and background task timeout (RunningBoard).
- Relevance: wall-clock watchdogs on a slow emulated boot (G12).

### 1.4 Apple open-source documents and man pages

**`launchd.plist(5)`** (mirror:
<https://keith.github.io/xcode-man-pages/launchd.plist.5.html>). Quality:
L1-doc.
- `ProcessType`:
  - **Background**: resource limits so the job does not disturb the user.
  - **Standard** (the default): light CPU and I/O throttling.
  - **Adaptive**: switches between Background and Interactive with XPC
    activity.
  - **Interactive**: app-level, no limits.
- `LowPriorityIO` and `LowPriorityBackgroundIO` lower filesystem I/O
  priority; `Nice` sets a nice value.
- `RunAtLoad` is discouraged because speculative launches hurt boot
  performance.
- `ThrottleInterval` defaults to 10 s.
- Also documented: `EnableTransactions`, `EnablePressuredExit`, and
  `LegacyTimers` (timers are coalesced by default).

**xnu `doc/scheduler/sched_clutch_edge.md`**
(<https://github.com/apple-oss-distributions/xnu/blob/main/doc/scheduler/sched_clutch_edge.md>).
Quality: L1-src.
- The Clutch scheduler has root buckets per QoS, ordered earliest deadline
  first. Worst-case execution latency is FG 0, IN 37.5 ms, DF 75 ms, UT
  150 ms, BG 250 ms.
- Warp allowances are FG 8 ms down to BG 0. Per-bucket quanta are FG 10 ms
  down to BG 2 ms.
- Thread groups get an interactivity score that favours apps over
  daemons.
- The Edge scheduler adds per-QoS cluster placement on asymmetric P/E
  systems.
- Relevance: on Apple's simulator every guest thread is a macOS thread, so
  this policy decides who runs during boot. Ycode has no equivalent (G1).

**xnu `osfmk/kern/turnstile.h`** (mirror:
<https://opensource.apple.com/source/xnu/xnu-6153.41.3/osfmk/kern/turnstile.h.auto.html>),
plus Apple patent 10901920 "Turnstile API for runtime priority boosting".
Quality: L1-src (the patent is a public document).
- Turnstiles carry priority inheritance for ulocks (the inheritor is the
  owner thread) and for sync IPC (the inheritor is the destination port's
  turnstile or the workloop). A special reply port pushes on the servicing
  thread until it replies (G8).

**dyld `doc/dyld4.md` and `doc/PrebuiltLoaderSet_Policy.md`** (mirror:
<https://cs.iossec.tech/dyld/latest/source/doc/dyld4.md>). Quality:
L1-src.
- The loader kinds are PrebuiltLoader (read-only, may be mapped from
  disk) and JustInTimeLoader.
- The cache holds a PrebuiltLoader per cache dylib, plus a set for each OS
  executable, found through a trie.
- If roots are installed, the cache's prebuilt loaders are invalid.
- Per-app sets are saved to disk and invalidated on reboot. They are not
  used when DYLD_INSERT_LIBRARIES or DYLD_*_PATH is set, or when
  interposing is in effect.
- Relevance: confirms that `dyld_sim` (no prebuilt support, and the
  simulator always sets DYLD_ROOT_PATH and friends) runs everything
  just-in-time. Apple's simulator does the same, so this is parity-neutral
  (row P1 of the table).

**libdispatch `src/shims/hw_config.h`**
(<https://github.com/apple-oss-distributions/libdispatch/blob/main/src/shims/hw_config.h>).
Quality: L1-src.
- On Darwin, libdispatch reads the logical, physical and **active CPU
  counts straight from one-byte commpage fields** when the commpage
  constants exist. The fallback is the sysctls `hw.logicalcpu_max`,
  `hw.physicalcpu_max` and `hw.activecpu`.
- These counts set the width of the global queues and of
  `dispatch_apply` (G2).

**Apple "Determining instruction set characteristics"** (sysctl
`hw.optional.*`), Apple developer documentation. Quality: L1-doc (the page
body could not be fetched; the key names are also used by third-party
code).
- Code is expected to probe CPU features at run time through
  `hw.optional.arm.FEAT_*` and `hw.optional.armv8_*`. libaom and the Go
  runtime do exactly this (seen in their sources during the search) (G6).

### 1.5 Prior-art projects

**Darling** (docs: <https://docs.darlinghq.org/internals/darlingserver/index.html>,
<https://docs.darlinghq.org/internals/basics/system-call-emulation.html>).
Quality: open-source project docs.
- Darling replaces the syscall macro in its own `libsystem_kernel`. BSD
  calls become direct Linux syscalls in-process (with errno translation).
  Mach traps go over RPC to a user-space server, darlingserver.
- The earlier kernel-module design "was typically faster" but too
  unstable.
- darlingserver runs managed threads as **user-space microthreads** to
  save threads and memory.
- Relevance:
  - Darling keeps BSD calls out of any server round trip.
  - Ycode sends every trap through a VM exit, the Swift VMM and one global
    lock (G3, C14).
  - Microthreads are an answer to the "300–400 blocked guest threads, each
    with a host thread" state measured in `performance-contract.md` §3.3.

**muvm / Fedora Asahi x86 support**
(<https://docs.fedoraproject.org/ca/fedora-asahi-remix/x86-support/>,
<https://alyssarosenzweig.ca/blog/aaa-gaming-on-m1.html>). Quality:
project docs.
- A micro-VM with its own guest kernel solves a page-size mismatch for a
  user-mode translator (FEX).
- For Ycode's deferred x86-64 track, this is the analogous structure: a
  translator plus a page-size-correct guest.

**fbidb / FBSimulatorControl** (<https://fbidb.io/docs/fbsimulatorcontrol>,
the page body did not load; the search summary was used). Quality:
project docs.
- CoreSimulator is an XPC service.
- Each booted device has one `launchd_sim`, the root of the guest, which
  sees only its own processes.

---

### 1.6 Second-pass sources (topics the first pass had not reached)

**Mach exceptions and thread suspension.**
- **WebKit `Source/WTF/wtf/posix/ThreadingPOSIX.cpp`**
  (<https://github.com/WebKit/WebKit/blob/main/Source/WTF/wtf/posix/ThreadingPOSIX.cpp>).
  Quality: open source (WebKit, BSD/LGPL; read as behaviour only).
  - **On Darwin**, WTF's thread suspend and resume call Mach
    `thread_suspend`/`thread_resume`, and register capture calls
    `thread_get_state`. This is the path JavaScriptCore's conservative GC
    scan of other threads uses.
  - On Darwin arm64, the instruction-cache barrier used when JIT code is
    published **calls `thread_get_state` on other threads** to force a
    context-synchronizing round trip.
  - Signals (SIGUSR1 plus `sigsuspend`) are used only on non-Darwin
    platforms.
- **WebKit `Source/JavaScriptCore/runtime/OptionsList.h`.** Quality: open
  source.
  - `useMachForExceptions` defaults to **true** on Mach platforms. JSC then
    handles faults (including the WebAssembly fault handler, also on by
    default) and passes thread messages through **Mach exception ports**,
    not signals.
  - A related WebKit change log (2023) records crashes when `Signal::Usr`
    went through the Mach path, which shows how load-bearing this path is.
- **Crash reporters** (PLCrashReporter series:
  <https://bignerdranch.com/blog/own-your-crash-logs-with-plcrashreporter-part-2>;
  a KSCrash walkthrough: <https://cloud.tencent.com/developer/article/1370201>;
  the xnu man page `task_set_exception_ports`:
  <https://cs.iossec.tech/xnu/latest/source/osfmk/man/task_set_exception_ports.html>).
  Quality: blog plus L1-src man page.
  - Third-party crash SDKs embedded in many apps install a **task-level
    Mach exception port** (`EXC_MASK_BAD_ACCESS` and others, behaviour
    `EXCEPTION_STATE_IDENTITY`). Dedicated handler threads block in
    `mach_msg`.
  - Mach exceptions are preferred because a signal handler on a crashed
    thread's overflowed stack cannot run.
  - On Darwin, the kernel raises the Mach exception first and reflects it
    into a POSIX signal only if no handler claims it.
- Relevance: G13.

**Memory limits and pressure.**
- **Apple `os_proc_available_memory`**
  (<https://developer.apple.com/documentation/os/os_proc_available_memory>)
  and xnu `libsyscall/os/proc.h`. Quality: L1-doc, L1-src.
  - The value is the dirty-memory limit minus the current footprint
    (equivalent to `TASK_VM_INFO.limit_bytes_remaining`).
  - It is **0 when the caller is not an app or is already over its
    limit**.
- **WebKit bmalloc `AvailableMemory.cpp`** (Apple open source). Quality:
  open source. bmalloc reads the jetsam limit through a private
  memorystatus call and falls back to a fixed 840 MB when that fails. A
  WebKit bug thread notes that the minimal simulator build lacks the
  entitlement for that call.
- Relevance: P4 and G14.

**Prewarming.**
- **Apple DTS answers on the Developer Forums**
  (<https://developer.apple.com/forums/thread/802755>,
  <https://developer.apple.com/forums/thread/763739>). Quality: Apple
  engineer statements (between L1-doc and blog).
  - The documented rule: prewarming runs the launch sequence up to, but
    not including, `UIApplicationMain`.
  - **Since late iOS 15**, the prewarm launch assertion ends **early in the
    initialization of the first library dyld loads (libsystem)**, so a
    prewarmed process never runs app code.
  - The `ActivePrewarm` environment variable is unreliable on iOS 16+.
- Relevance: matches `host-library-init.md` §1.2 item 17 (the
  end-of-prewarm check in libSystem's initializer, iOS builds). Ycode
  already sits at the right place (P5).

**Workloops.**
- **libdispatch `dispatch/workloop.h`**
  (<https://github.com/apple-oss-distributions/libdispatch/blob/main/dispatch/workloop.h>).
  Quality: L1-src.
  - A workloop is an exclusion context that runs submitted items **in QoS
    priority order**. Between items, it checks for higher-priority work
    submitted to it or to queues targeting it.
  - Serial queues that target it keep FIFO order among themselves.
  - `dispatch_sync` on a workloop is not allowed (`dispatch_async_and_wait`
    instead).
  - It can bind an `os_workgroup`.
- Relevance: priority ordering is user-space work in libdispatch. The
  kernel's part is the priority of the workloop's thread request, which
  Ycode does not use (G1, G8).

**XPC and launchd on demand.**
- **"Explainer: XPC"**, The Eclectic Light Company, 2026
  (<https://eclecticlight.co/2026/02/07/explainer-xpc/>). Quality: blog.
  - Services are started by launchd from a plist, or on demand when a
    client connects.
  - On Apple silicon, background XPC work is placed on E-cores, and the
    activity scheduler (DAS/CTS) runs hundreds of maintenance activities
    this way.
- Relevance: G1. On Apple's simulator this background work is cheap
  because the host schedules it on E-cores at background QoS.

**Simulator specifics.** No new public talk was found on CoreSimulator or
`launchd_sim` internals beyond fbidb and the threedots blog (§1.2, §1.5).
Our level-3 specs (`launchd-sim.md`, `launch-sim-control.md`,
`bootstrap-wire.md`) remain the best source.

## 2. Ycode facts checked for the gap analysis

| Fact | Where |
|---|---|
| **The commpage says one CPU.** `CommpageBuilder.cpuCount` defaults to 1 and the launcher builds it with defaults, so `NCPUS`, `ACTIVE_CPUS` (0x034), `PHYSICAL_CPUS` and `LOGICAL_CPUS` are all 1 and the capability word has `kUP` (0x8000) set. `optionalCapabilities` is 0 | `ycode/Sources/YcodeDarwinKernel/ProcessImage.swift` (CommpageBuilder); `ycode/Sources/ycode-simd/ImageLauncher.swift` (`let commpage = CommpageBuilder()`) |
| **The sysctls say one CPU** (`hw.ncpu`, `hw.activecpu`, `hw.availcpu`, `hw.logicalcpu(_max)`, `hw.physicalcpu(_max)`). All `hw.optional.*` read 0, `hw.optional.arm.caps` is 0, and `hw.cpufamily` is 0 | `ycode/Sources/YcodeDarwinKernel/SysctlTable.swift` |
| **The kernel side assumes 8 CPUs**: workqueue constrained parallelism 8, and `bsdthread_ctl(QOS_MAX_PARALLELISM)` returns 8 | `ycode/Sources/YcodeDarwinKernel/Workqueue.swift` (`parallelism = 8`), `Threads.swift` (case 0x800) |
| Our spec says to derive the optional capability bits from the guest's ID registers. The code does not | `specs/simulator/darwin-process-start.md` §5 (row 0x010/0x020) |
| `dyld_sim` writes function-variant processor flags from `hw.optional.arm.caps` into the cache's dynamic region | `specs/simulator/dyld-sim-handoff.md` §4.2 step 5 |
| No scheduler priorities: `setpriority` (incl. `PRIO_DARWIN_*`) succeeds and does nothing. No host thread priority is set anywhere in the VMM | `ycode/Sources/YcodeDarwinKernel/ExtendedBSD.swift` (case 96) |
| The spawn attributes `psa_apptype`, `psa_qos_clamp`, `psa_darwin_role` and the jetsam fields are stored or ignored | `specs/simulator/processes.md` §1.6, item 16 of the normative list |
| Vouchers are always 0. `MACH_MSGH_BITS_RAISEIMP` is ignored | `bootstrap-wire.md` §2, `iosurface-remote.md` §2 |
| Time: `mach_absolute_time` and `mach_continuous_time` always trap, the approximate variants call them, and the commpage `gettimeofday` path reports "unavailable". The commpage counter path (C5) exists only in the prototype patch | `ycode/SimHostLibs/kernel/mach.c`, `misc.c`; `performance-contract.md` §6 C5, §8 |
| A trap round trip takes "tens of µs". A bare KVM MMIO round trip on the Thor takes 2.75–2.97 µs | `docs/postmortem-kvm-sve.md` §7; `docs/SIMULATOR-LINUX.md` stage 2 (≈32 µs) |
| Page tables are built eagerly per mapping ("O(pages changed)"). File mappings without write access use a shared read-only host view | `ycode/Sources/YcodeDarwinABI/AddressSpace.swift` (GuestAddressSpace doc comment) |
| The JIT toggle is reported as unsupported, and `pthread_jit_write_protect_np` does nothing. There is no MAP_JIT-specific handling in the kernel | `ycode/SimHostLibs/pthread/thread.c`; grep of `ycode/Sources/YcodeDarwinKernel` |
| The `ulock` owner is already recorded for `UL_UNFAIR_LOCK` | `ycode/Sources/YcodeDarwinKernel/ULock.swift` (`ULockQueue.owner`) |
| Reference: Apple's simulator took 38 s for its first boot (193 guest processes). Ycode under the harness made 325 images in 330 s and did not reach the home screen | `research/notes/simulator-observations.md` "Boot"; `performance-contract.md` §3.3 |

---

### 2.1 Re-check against the newest simulator line (second pass)

Main (`m2-workspace-settings`, HEAD `83a6ca7`) has had **no simulator
source changes** since the first pass. Its only simulator commit is
`specs/simulator/native-mode.md`, a paused feasibility study. That study
also measured, on the Thor:
- a bare MMIO doorbell exit at about 2.76 µs and a forwarded HVC at about
  2.53 µs;
- one 661 s boot that held the kernel lock 370 s over 13.94 M traps.

The simulator speed work lives on branch **`speed-int`** and on worktree
branches on top of it. The newest is `worktree-agent-a3b866d9d5e9d55e7`
(tip `6b2a6bc`). On that line:

| Item | Status on the speed line | Effect on the G-table |
|---|---|---|
| C2/C9: one lock per trap, trace text only when tracing | Landed (`3da0d02`) | Perf-contract context only |
| C1: VM off the kernel lock | Landed as a "prebuilt VM" built by the spawning thread before it takes the lock (`4a519ce`). The standby-VM trial (`dcd942b`) was reverted. KVM_CREATE_VM cost grows with the host mapping count (2.7 ms at 17 mappings, 14 ms at 40 k) and stalls first touches in every VM | G4: host mapping count is a second per-image cost |
| C3: vCPUs | Landed as batches of four (`99f303b`): a KVM_CREATE_VCPU after another vCPU's first run waits one RCU grace period (25–60 ms) | — |
| C4: `select` | Landed (`Select.swift`) | — |
| C6: file I/O off the lock | Landed (`bdd800a`, `877fc5d`, O_NOATIME `b7414c5`/`b20efbd`) | G5 is still open (no I/O priority) |
| C5: clock in place | **Not integrated.** `5ba106d` (commpage flag 0xF8, VMM counter alignment) is only on `worktree-agent-a12ede8c666ca228a`. The lock-free clock and `gettimeofday` trial (`6cf3726`: 4.5 M such traps held the lock 20 s and waited 2,860 thread-seconds) was **reverted** (`5d32f6c`). On the speed line, `mach.c` still traps on every clock read, and the approximate clocks call the precise ones | **G3 stands**, and it is the cheapest large win |
| Lock fairness | Trial `b75211f` (FIFO hand-off after N µs) was **reverted** (`c8b49b4`). Its message records single kernel-lock waits of **1.5–2.5 s** under the unfair pthread mutex | **G1 is strengthened**: starvation is measured, and plain FIFO was not the answer; class-aware hand-off is untried |
| Cooperative pool | Landed (`6b2a6bc`) with `cooperativeWidth = 1`, "the guest sees one CPU". Before it, Swift-concurrency daemons (suggestd, parsecd, axassetsd) had their cooperative requests turned into up to 8 constrained threads each | **G2 stands**. The width is now tied to the one-CPU guest, so raising N in G2 must raise it too |
| Commpage CPU count, `hw.*cpu*`, `hw.optional.*`, `QOS_MAX_PARALLELISM` = 8, `setpriority` ignored, eager page tables | Unchanged on the speed line (`ProcessImage.swift` `cpuCount = 1`; `SysctlTable.swift`; `Threads.swift` case 0x800; `ExtendedBSD.swift` case 96; `AddressSpace.swift` "O(pages changed)") | G1, G2, G4, G6 stand |
| Snapshot/restore prototype | `7ba86a7`, `f0b29e7` on `worktree-agent-a480795f594593949`, default off. It captures processes, Mach state, kqueues and memory, and restores a one-process guest in 23 ms | A Ycode-only route to a "warm" boot; there is no Apple counterpart (Apple's simulator always boots). See §3.1 |
| Mach exceptions, thread suspension | Exception ports are stored but **no exception message is ever delivered** (`processes.md` §4.8). `thread_get_state` answers only for threads stopped in a trap (KERN_FAILURE while running). **No `thread_suspend`/`thread_resume`** in `SimHostLibs` or the kernel | New **G13** |
| Memory status | `memorystatus_control` is EPERM for every command, which **matches the Mac** (`app-install-launch.md` §3.3). `os_proc_available_memory` returns the private trap's value or 0. `EVFILT_MEMORYSTATUS` is refused with ENOTSUP (`KEvent.swift`) | New **P4** (parity) and **G14** |
| TPIDR_EL0 CPU number | Saved and restored per guest thread by the shim (`SimShim/shim.S`), so `pthread_cpu_number_np` and `_os_cpu_number` see the guest's value (0 in practice) | A caveat for G2: per-CPU caches (libmalloc) all use slot 0 unless the shim also gives each vCPU a CPU index below N |

## 3. Gap analysis

Ranked by expected impact on **time to the home screen** first, then on
compatibility. **PERF** marks gaps that bear on boot-time parity.

Gaps the performance contract already lists (C1 VM creation off L0, C2 one
lock acquisition per trap, C3 spare vCPUs, C4 `select`, C6 file I/O off L0,
C8 exec reuses the VM, C14 per-task locks) are **not repeated** as new
gaps. The talks support them (Darling's kernel-module vs server
experience; device iOS preparing the cache once per boot). G3 and G4
below add to them.

| # | Mechanism | What the sources say iOS / Apple's simulator does | What Ycode does now | Impact | Suggested next step | Evidence |
|---|---|---|---|---|---|---|
| **G1** | **PERF.** QoS and process type → CPU scheduling; priority-aware waiting | On Apple's simulator, every guest thread is a host macOS thread scheduled by Clutch/Edge. FG work has zero latency budget and an 8 ms warp; BG has a 250 ms budget, a 2 ms quantum, and goes to E-cores. `ProcessType` Background and Standard daemons get CPU and I/O throttling; Adaptive ones are throttled unless boosted by XPC importance. iOS 13's launch work explicitly depends on QoS being preserved. The kernel resolves inversions only for single-owner primitives | Every guest thread is an equal Linux thread on a vCPU. `setpriority` and `PRIO_DARWIN_BG` are ignored. Spawn apptype, clamp and role are ignored. Every trap queues FIFO on the one kernel lock L0 (busy 75–91 %, 18–28 waiters under the harness). SpringBoard's main thread waits behind suggestd (12 M traps), axassetsd, diagnosticd and the rest. *Second pass:* single lock waits of 1.5–2.5 s were measured under the unfair mutex. A FIFO hand-off trial was reverted. A 661 s boot still held the lock 370 s | **Very high** for T_again/T_first once C1–C3 lower the lock busy fraction, and possibly before. The home screen's critical path is a few UI/IN threads among hundreds | (1) Keep an effective QoS per guest thread: the workqueue upcall QoS, `bsdthread_ctl SET_SELF`, the main thread's default, and the process apptype/darwin-bg/role. (2) Map it to the vCPU host thread: Linux nice for UI/IN/DF/UT, `SCHED_IDLE` or a high nice for BG and darwin-bg. (3) Make L0 hand-off priority-aware (two classes, UI+IN before the rest, with an anti-starvation bound). (4) Measure T_again with and without each part. Requires G8 to avoid inversions | L1-doc (launchd.plist, WWDC17 706, WWDC19 423, WWDC13 702), L1-src (sched_clutch_edge.md), L3 (perf contract) |
| **G2** | **PERF + compatibility.** Guest CPU topology | The guest sees the host Mac's core counts. libdispatch reads the commpage `ACTIVE/PHYSICAL/LOGICAL_CPUS` bytes to size its pools and `dispatch_apply`. The Swift cooperative pool is "as many threads as CPU cores". `QOS_MAX_PARALLELISM` agrees with the commpage | The commpage and sysctls say **1 CPU** and set `kUP`, while the kernel admits 8 constrained workers and `QOS_MAX_PARALLELISM` returns 8. Effect: each guest process gets one Swift concurrency thread and one-wide global concurrent queues. `ProcessInfo.activeProcessorCount` is 1, and so on. *Second pass:* the new cooperative pool (`6b2a6bc`) deliberately uses width 1 to match | **High.** Per-process parallelism is capped at 1, apps that size thread pools from the CPU count see 1, and the topology is inconsistent. The gain is limited while L0 serializes traps, but most guest work (Swift and ObjC runtime start-up, layout, decoding) runs **in guest code without traps** | Make the guest CPU count N a launcher setting (default min(host online CPUs, 16)). Write the same N to commpage 0x022/0x034/0x035/0x036 and the capability word (no `kUP` when N > 1), to every `hw.*cpu*` sysctl and `hw.perflevel0.*`, to workqueue `parallelism`, `cooperativeWidth` and `QOS_MAX_PARALLELISM`. Have the shim give each running vCPU a CPU index below N in TPIDR_EL0's CPU-number bits (per-CPU caches). Check that our own `libsystem_platform` lock spinning behaves with N > 1. Add a probe that compares the three views | L1-src (libdispatch hw_config.h), L1-doc (WWDC21 10254), L3 (our source) |
| **G3** | **PERF.** Avoiding kernel crossings on hot paths | Darwin keeps hot operations out of the kernel: commpage time (counter + offset; `NEWTIMEOFDAY` data for `gettimeofday`; `APPROX_TIME`), TSD, `os_unfair_lock` fast paths, `mach_msg2` combining send and receive, workloop return delivering the next events. On macOS a trap costs well under a microsecond | One trap is a VM exit plus the Swift VMM plus L0: **tens of µs**, against a ~3 µs KVM floor. −3/−4 are the most frequent traps (C5 is only in the prototype). `gettimeofday` (116) traps on every call, and the approximate clocks trap too. Fixed-answer traps (`getpid`, `getuid`/`geteuid`, `thread_selfid`, `task_self_trap`, `thread_self_trap`, `host_self_trap`) still make a full round trip. *Second pass:* clock-in-place exists (`5ba106d`) but is not on the speed line. The lock-free clock trial was reverted. 4.5 M clock and `gettimeofday` traps in one boot held the lock 20 s and waited 2,860 thread-seconds | **High** (it multiplies every trap; parsecd: 56 % of its traps are −4) | (1) Integrate `5ba106d` (C5), then extend it to the commpage `gettimeofday` block (0x120) and `APPROX_TIME` (0x0C0, supported flag 0x0C8), or compute them in our own `libsystem_kernel` from the counter. (2) Cache fixed answers in the guest library, or answer them in the EL1 shim from a per-thread page without a VM exit. (3) Profile the VMM's own per-trap path (decode, ARC, trace text: C9) toward the ~3 µs floor | L1-src (xnu commpage, our `darwin-process-start.md` §3), L3 (postmortem, perf contract) |
| **G4** | **PERF.** Per-process cost of mapping the shared cache | Device: the cache is mapped and slid once per boot and shared (shared-region nesting). Cache dylibs have used lazy page-in fixups for over a decade, and the OS executables have prebuilt loaders in the cache. Mac simulator: private `mmap` of the unslid cache, populated lazily by host page faults | Each exec builds stage-1 page tables **eagerly** for the whole multi-GB cache (O(pages): hundreds of thousands of 16 KiB entries per process), plus KVM stage-2 faults. Two images per daemon start (spawn + exec). "Page-table growth" is in the remaining 25 % of lock-held samples. *Second pass:* KVM_CREATE_VM's cost grows with the host mapping count (14 ms at 40 k mappings) and stalls first touches in every VM. Each mapped file costs about three host mappings, so the cache's per-process footprint is a host cost too | **Medium–high** (paid about 160–325 times per boot; size not yet measured) | (1) Measure the time and page-table bytes of the cache mapping per exec. (2) Share a prebuilt stage-1 subtree for the read-only cache range across address spaces (an analogue of nesting; needs the shared read-only view at the same GPA in every VM). Alternatively, populate the cache range lazily from a guest translation fault in the shim, or use 32 MiB L2 block entries where file offset and VA alignment allow. (3) Keep `__DATA_CONST` patch pages as a lazy private view | talk (36C3 untether), L1-doc (WWDC22 110362), L1-src (dyld4.md), L3 (our source) |
| **G5** | **PERF.** I/O priority of background daemons | `LowPriorityIO`/`LowPriorityBackgroundIO`, darwin-bg I/O throttling, and `setiopolicy_np` keep daemon disk traffic away from the foreground | Host file I/O of every process is equal (and partly under L0, C6). Under the harness, metadata calls take 7–300 ms | **Medium** (on the shared USB disk) | Together with C6: tag each descriptor's I/O with the caller's effective class from G1. Run BG and throttled I/O on a separate low-priority host I/O worker (Linux `ioprio_set` IDLE/BE class) | L1-doc (launchd.plist), L3 (perf contract §3.3) |
| **G6** | **PERF + compatibility.** Advertising CPU features | Code chooses fast paths by `hw.optional.arm.FEAT_*`/`armv8_*` and the commpage capability bits. `dyld_sim` writes function-variant flags from `hw.optional.arm.caps` into the cache. Apple's simulator sees the host Apple CPU's features | Every `hw.optional.*` is 0, `arm.caps` is 0, commpage optional bits are 0, `cpufamily` is 0. The guest picks **baseline variants everywhere** (CRC32, AES/SHA, LSE atomics, dot-product paths, and so on). This differs from our own spec (`darwin-process-start.md` §5) | **Medium** (CPU-bound work: decompression, crypto, hashing, image decoding). Also a compatibility risk if code assumes the features that every Apple arm64 CPU has | Read the vCPU ID registers (KVM one-reg ID_AA64ISAR0/1/2, PFR0/1, MMFR) once. Map them to the `FEAT_*` sysctls, `arm.caps` and commpage bits, advertising **only** features both present and allowed (never PAuth, SME, MTE or SVE: Apple doesn't expose SVE). Verify on the Mac (level 3) which keys the reference simulator reports | L1-doc (Apple sysctl doc), L1-src, L3 (our source and spec) |
| **G7** | Compatibility. JIT memory | JIT needs the dynamic-codesigning entitlement (`get-task-allow` relaxes RWX). On Apple silicon, per-thread W^X switching goes through an EL0 system register and commpage permission values, behind `pthread_jit_write_protect_np` | The toggle is reported unsupported (consistent: no such register on the Thor). There is no special MAP_JIT handling. Whether the guest gets RWX EL0 mappings and correct I-cache maintenance has not been probed | **Medium** for WebKit, JSContext and WKWebView apps; none for boot | Add a probe: JSContext evaluating a hot loop (JIT tiers). Check MAP_JIT RWX mapping, `sys_icache_invalidate` (cache maintenance on the Thor), and `pthread_jit_write_protect_supported_np` = 0 together with JavaScriptCore's fallback path. Document the policy in a spec | talk (BH2016 Krstić, 35C3), blog (Siguza APRR), L3 |
| **G8** | Correctness once G1 lands. Priority inheritance (turnstiles) | ulocks push on the owner. Sync IPC on a special reply port pushes on the servicing thread or workloop until the reply. Dispatch QoS overrides (`bsdthread_ctl` 0x40/0x400) boost a thread. Importance (`RAISEIMP`, vouchers) boosts Adaptive daemons | With no priorities, inheritance is not needed today. The `ulock` owner is already tracked. Overrides and `RAISEIMP` are accepted and ignored | **None now; high after G1.** A SpringBoard UI thread blocked on a BG daemon's reply under `SCHED_IDLE` would starve | With G1, add: (a) a `ulock` owner boost to the max waiter class; (b) a boost of the receiving thread (or the next workloop servicer) of a message with a send-once reply right, held until the reply is sent or the right dies; (c) honour QoS override start/end; (d) treat `RAISEIMP` as a process-level boost for Adaptive jobs | L1-src (turnstile.h, patent), L1-doc (WWDC17 706, WWDC13 702) |
| **G9** | Compatibility (low). Vouchers and importance attributes | Vouchers carry importance, bank/persona and activity IDs across processes. libdispatch adopts them per message | Always 0. `host_create_mach_voucher` is a private Ycode routine | **Low** today (servers accept voucher 0, as observed). Needed for G8(d) | Keep voucher 0 until G1/G8. Then carry a minimal importance token through `msgh_voucher_port` only for messages with `RAISEIMP` | L1-doc (WWDC13), patent; L3 (bootstrap-wire, iosurface-remote) |
| **G10** | **PERF.** Host threads per guest thread | Darling runs managed threads as user-space microthreads to save resources. Apple's simulator has real kernel threads but a scheduler that parks blocked ones at no cost | One vCPU plus one host thread per guest thread: 300–400 blocked threads, and vCPU creation is expensive (C3) | **Low–medium** (memory and creation cost; complements C3) | Only after C1–C3: consider detaching a vCPU from a guest thread that is blocked for a long time (its register file saved in the VMM) and reusing it, so the vCPU count tracks runnable threads | open-source docs (Darling), L3 |
| **G11** | Compatibility (tools). How dyld and dyld_sim appear to debuggers | A simulator process has two dynamic linkers. LLDB tells them apart by triple. Recent simulators hide `dyld_sim` from `_dyld_image_count` and `TASK_DYLD_ALL_IMAGE_INFO_64` | `DyldAllImageInfos` v17 with `dyld_sim` as `dyldImageLoadAddress`. Not checked against what the current runtime reports | **Low–medium** (lldb-dap attach on Linux; Frida-style tools) | Black-box on the Mac (level 3): compare `TASK_DYLD_INFO` / all-image-infos of a 27.1 simulator process with ours (image count, whether dyld_sim is listed, the `platform` field). Align. Add an lldb attach test on the Thor | blog (Frida notes), open source (LLDB) |
| **G12** | Compatibility while boot is slow. Wall-clock watchdogs | Watchdogs (`0x8badf00d`) time launch and resume transitions. RunningBoard kills on background-task timeouts. FrontBoard retries render-server lookups for about 5 s (`app-install-launch.md` §5) | Guest time runs in real time while emulated work is 10× slower or worse, so timeouts tuned for real hardware can fire | **Medium** until boot parity. Risk of flaky launches | Find out on the Mac (level 3) whether the reference simulator enforces launch watchdogs (a probe app blocking `didFinishLaunching` for 30 s). If it does, record which processes kill and why. Ycode can only change speed, not policy | L1-doc (WWDC20 10078), L3 |
| **G13** | **Compatibility (high for JS, WebKit and crash SDKs).** Mach exception delivery and thread suspension | Faults raise a Mach exception first. Task- or thread-level exception ports receive `exception_raise` messages (with state for the STATE behaviours), and only unclaimed exceptions become signals. JavaScriptCore on Darwin uses Mach exceptions for faults (Wasm fault handler) and thread messages (`useMachForExceptions` true), and `thread_suspend`, `thread_resume` and `thread_get_state` for the conservative GC scan and the arm64 JIT instruction-cache barrier. Crash SDKs (PLCrashReporter, KSCrash, and those built on them) install task exception ports with dedicated handler threads | Ports are stored and returned, but **no exception message is ever sent**: faults go straight to signals. `thread_get_state` fails with KERN_FAILURE for a thread running guest code. **`thread_suspend`/`thread_resume` do not exist.** Expected effects: a JSContext GC or JIT publication fails or crashes, Wasm bounds-check faults kill the process, and crash SDKs never see crashes (their handler threads wait forever) | **High** for any app or system process using JavaScriptCore (WKWebView content, JSContext, Wasm) or a crash SDK; none for the boot itself | (1) Implement `thread_suspend`/`thread_resume` (a suspend count; the target's vCPU is kicked out of guest code and parked at the next exit) and `thread_get_state`/`thread_set_state` for a suspended thread, whose registers are then in the VMM. (2) Deliver EXC_BAD_ACCESS, EXC_BAD_INSTRUCTION, EXC_ARITHMETIC and EXC_BREAKPOINT to a registered thread or task port, behaviours DEFAULT, STATE and STATE_IDENTITY with `MACH_EXCEPTION_CODES`, before falling back to the signal; honour the reply (KERN_SUCCESS resumes with the possibly modified state). (3) Add a probe: a JSContext GC stress test, a Wasm out-of-bounds trap, and a KSCrash-style handler. Spec first (`processes.md` §4.8 replaces "never deliver") | open source (WebKit ThreadingPOSIX.cpp, OptionsList.h), L1-src (xnu task_set_exception_ports), blog (PLCrashReporter, KSCrash), L3 (our source) |
| **G14** | Compatibility (low). Memory-pressure notifications | Apple's simulator processes run on the macOS kernel, so dispatch memory-pressure sources (`EVFILT_MEMORYSTATUS`) can fire under host pressure. UIKit's memory warnings follow from them | `EVFILT_MEMORYSTATUS` is refused (ENOTSUP), so the guest never sees pressure, and a source that cannot register may log or fall back | **Low** (the Thor has 122 GB; mostly cache-trimming behaviour) | Accept the registration and never fire, unless the VMM's host memory use crosses a configured limit; then deliver WARN/CRITICAL to the largest guests. Check on the Mac (level 3) whether simulator processes ever get these events | L1-src (xnu event.h), L3 (`KEvent.swift`) |
| P4 | Parity-verified. Jetsam and memory limits | Devices enforce per-process limits (WWDC20 10078). `os_proc_available_memory` is 0 for non-apps or when over the limit. On the Mac simulator, `memorystatus_control` fails with EPERM (`app-install-launch.md` §3.3, level 3) | `memorystatus_control` returns EPERM for every command; `os_proc_available_memory` returns the trap's value or 0 | none | No action. Do not emulate device memory limits; Apple's simulator does not either | L1-doc, L3 |
| P5 | Parity-neutral. Prewarming | iOS prewarms some app launches. Since late iOS 15 the prewarm assertion ends in libsystem's initialization, before any app code | No prewarm. The libSystem end-of-prewarm check runs as on the Mac (`host-library-init.md` §1.2 item 17) | none | No action. Ycode's own counterpart is the snapshot/restore prototype (§2.1), which is not an Apple behaviour | Apple DTS (forums), L3 |
| P1 | Parity-neutral. dyld closures and PrebuiltLoaders | Device: closures for system apps in the cache, for third-party apps at install time. `dyld_sim`: none | None (identical to Apple's simulator) | none | No action. Do not count it as a gap when comparing boot times with a device | L1-src (dyld4.md, policy) |
| P2 | Parity-neutral. Swift conformance precompute, page-in linking for apps | Device only (iOS 16+) | Not in `dyld_sim` (compiled out) | none | No action | L1-doc (WWDC22 110362, 110363) |
| P3 | Parity-neutral. AMFI, trust cache, sandbox enforcement, exclaves, PAC | Device only. The simulator is arm64 with relaxed signing | Accept and record | none | No action | talk (35C3, 36C3) |

### 3.1 Suggested order (performance first)

Revised in the second pass. C1–C4, C6 and C9 have landed on the speed
line (§2.1), but the boot is still lock-bound: 370 s of lock hold in a
661 s boot.

1. **G3.** Integrate the existing clock-in-place commit `5ba106d` (C5).
   Then move `gettimeofday` and the approximate clocks to the commpage, and
   answer fixed-answer traps without a VM exit. This takes the largest
   single trap class off the lock (4.5 M traps, 20 s of hold, 2,860
   thread-seconds of waiting in one boot), and the code largely exists.
2. **G1 with G8.** Make the kernel lock's hand-off class-aware (UI/IN
   waiters first, with a starvation bound). Plain FIFO was tried and
   reverted; measured waits reach 1.5–2.5 s. Map QoS and darwin-bg to host
   thread priority, with minimal inheritance (`ulock` owner, sync-IPC
   reply). This is the only item that changes **who** the saturated lock
   serves, which is what time to the home screen depends on.
3. **G2.** One CPU count N everywhere: commpage, sysctls,
   `QOS_MAX_PARALLELISM`, workqueue `parallelism` and `cooperativeWidth`,
   plus per-vCPU CPU numbers. Cheap and consistent. Measure it after G1,
   because more parallel workers raise lock contention until the lock is
   split (C14, or native mode).
4. **G4.** Measure the per-exec page-table cost and host mapping count
   first.
5. **G6**, then **G5**.
6. Compatibility: **G13** first (any WebKit, JSContext or crash-SDK app
   depends on it), then G7 (best done together with G13, since JSC's JIT
   publication uses `thread_get_state`), G11, G12 and G14.
7. Separately, and Ycode-only: the snapshot/restore prototype could make
   T_again a restore instead of a boot. It has no Apple counterpart, so
   measure it beside, not instead of, boot-time parity.

### 3.2 What the talks did *not* change

These areas are already specified in more depth than any talk found:
- the syscall/Mach trap ABI (`darwin-arm64-abi.md`,
  `darwin-trap-tables.md`);
- TSD slots (`host-library-init.md` §3);
- the libSystem init order;
- launchd_sim bootstrap and XPC wire format (`bootstrap-wire.md`,
  `launch-sim-control.md`);
- workqueue upcall layout and flags (`threads-and-events.md` §2.6);
- `ulock` flags;
- the `dyld_sim` handoff.

Exclaves, SPTM/TXM, PPL and PAC appear in the device talks only and do not
apply to the simulator.

## Evidence summary

| Claim | Level / kind |
|---|---|
| Shared cache slid once per boot and shared by all processes (device) | talk (36C3 untether) |
| Page-in linking: cache dylibs for over a decade, apps from iOS 16; DATA pages only, at launch only | L1-doc (WWDC22 110362) |
| Closures/PrebuiltLoaders in the cache and at install; invalid with roots or DYLD_* paths | L1-src (dyld4.md, PrebuiltLoaderSet_Policy.md), L1-doc (WWDC17 413) |
| Swift cooperative pool width = core count | L1-doc (WWDC21 10254) |
| libdispatch reads the CPU counts from the commpage | L1-src (libdispatch hw_config.h) |
| QoS classes, kernel queue identity, ownership-based inversion handling | L1-doc (WWDC17 706) |
| Clutch latency budgets, warps and quanta | L1-src (xnu sched_clutch_edge.md) |
| ProcessType semantics; RunAtLoad hurts boot | L1-doc (launchd.plist(5)) |
| Importance boosting and Adaptive XPC services | L1-doc (WWDC13 702 notes) |
| Turnstile inheritance for ulocks and sync IPC | L1-src (turnstile.h), patent 10901920 |
| JIT entitlement and RWX JIT region | talk (BH2016, Apple speaker) |
| Per-thread JIT W^X register and commpage values | blog (Siguza) |
| dyld_sim hidden from image lists on recent simulators | blog (Frida 17.4.0 notes) |
| Darling routes BSD calls in-process and Mach through a server; its kernel module was faster; it uses microthreads | open-source project docs |
| Shared cache randomized once per boot, same VA in every process | talk (36C3 Messenger Hacking, second pass) |
| JSC on Darwin uses `thread_suspend`/`thread_resume`/`thread_get_state` for GC and the arm64 JIT I-cache barrier; `useMachForExceptions` defaults to true | open source (WebKit ThreadingPOSIX.cpp, OptionsList.h) |
| Crash SDKs use task-level Mach exception ports with dedicated handler threads | blog (PLCrashReporter series, KSCrash walkthrough), L1-src (xnu man page) |
| `os_proc_available_memory` semantics; bmalloc's jetsam-limit fallback | L1-doc, L1-src, open source (bmalloc) |
| Prewarm assertion ends in libsystem init since late iOS 15 | Apple DTS forum answers |
| Workloops run items in QoS priority order | L1-src (libdispatch workloop.h) |
| Background XPC work runs on E-cores under DAS/CTS | blog (Eclectic Light) |
| Speed-line status: landed and reverted trials, 1.5–2.5 s lock waits, clock-trap cost, KVM_CREATE_VM and vCPU creation costs | L3 (commit messages and `stage6-contract.md` §5.2–§5.4 on `speed-int` and its worktrees) |
| Every Ycode fact in §2 | L3 (our source, specs and measurements) |

## Addendum: "Wayland, microVMs and more — running Linux applications on macOS" (Victoria / Drakulix, 2026 talk; transcript supplied by the owner)

This is the opposite direction to Ycode: Linux GUI apps in a libkrun
microVM on macOS, shown on the Mac through a Wayland compositor (Smithay)
that draws with Cocoa. It has no Apple internals. What matters to us:

- **Graphics path:** virtio-gpu with Venus (Vulkan) and virglrenderer.
  rutabaga "cross-domain" contexts proxy Wayland through virtio-gpu.
  Guest file descriptors become virtio-gpu **resource IDs**, and the host
  turns an ID back into its object. The final design keeps the renderer and
  the compositor **in one process**, so presenting is just a lookup by
  resource ID, with no fd or IOSurface passing. Ycode's live display
  (stage 8) can do the same: the Vulkan renderer and the display window in
  `ycode-simd`, with IOSurface ID → VkImage lookups and no export.
- **Unified memory is what makes zero-copy work:** mapping host-visible
  device memory straight into the VM succeeds only because CPU and GPU
  memory are the same. The Thor (Jetson, integrated GPU) is unified memory
  too. Ycode already relies on this (`metal-sim-protocol.md` §9 item 5,
  `VK_EXT_external_memory_host` over the guest's own pages). Note that the
  reference simulator still reports `hasUnifiedMemory` false.
- **Page sizes:** the talk's 4 KiB Linux guest had to align Vulkan buffers
  to 16 KiB for Metal on the host. Our case is the reverse: a 16 KiB guest
  on a 4 KiB host. That is harmless for importing host pointers, as long as
  `minImportedHostPointerAlignment` divides 16 KiB.
- **Synchronization** was the speaker's remaining bug class (DMA fences
  with no Metal counterpart). Ycode already maps GPU completion to Vulkan
  timeline semaphores (CVulkan `yvk_timeline_*`).
- **Display on a Linux host:** when Ycode later shows the simulator in a
  window on the Thor, Wayland's linux-dmabuf can show exported Vulkan
  images with zero copies. Showing it in the Mac IDE needs streaming
  (encoded frames) instead. The talk does not cover that.
- Nothing in the talk changes the CPU-side gap analysis (G1–G14).

### The talk's code (Wayvian, MIT, read at the owner's request)

`.claude/wayvian` holds the speaker's repository: a Rust workspace with
the compositor (`wayvian`, on Smithay), a per-app display process
(`proxy-client`), a Mach-port IPC crate, `xkbgen`, and patches. The
submodules (libkrun, virglrenderer, mesa, MoltenVK) are not checked out.
Useful ideas:

- **The viewer drives frame pacing.** The display process sends
  `RequestFrame(surface)` when it can show a frame, and only then does
  the compositor complete the client's frame callbacks. A client that
  nobody displays gets no frame callbacks. For Ycode, completing
  SimFramebuffer swaps at a viewer-driven rate, and slowly or not at all
  with no viewer, could cut render work during a headless boot. That is a
  hypothesis: first measure swaps per second during our boot, and how the
  reference simulator behaves with no Simulator.app window.
- **Damage tracking** (Smithay's DamageBag with commit counters) gives
  "damage since commit N". A remote viewer, such as the Mac IDE showing a
  simulator on the Thor, needs to send only the damaged rectangles.
- **Zero-copy across processes on macOS:** one IOSurface per buffer,
  passed to the per-app process as a Mach send right
  (`IOSurfaceCreateMachPort`). This would apply if the Mac IDE ever hosts a
  simulator view in a helper process.
- **`xkbgen`:** tables that map Apple virtual keycodes to evdev codes, and
  a live macOS layout (`UCKeyTranslate`/`uchr`) to XKB generator. For
  Ycode's input stage, the Mac IDE needs Apple keycode → USB HID usage
  (page 7) for the guest's HID events. The keycode facts are public
  interop data. If we take any table from this MIT code, keep its notice.
- Patch `0001-virtio-vulkan-force-16k-alignment…` (Sergio Lopez) confirms
  the 4 KiB guest / 16 KiB host alignment issue noted above.
