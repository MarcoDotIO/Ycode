# Spec: native mode — running Darwin guest processes directly on arm64 Linux

Status: **stage 1 implemented and measured (2026-11-05, agent B3-NATIVE,
§10).** The implementation (`ycnative`, `YCODE_NATIVE=1`) lives on the
long-lived branch `native-mode`, not on the main line: by the owner's
decision (2026-11-05) native mode is developed there in pieces across beta
releases, so no beta waits on it, and pieces move to the main line when
they are ready. §1–§9 are the feasibility
study it started from; §10 records what stage 1 built, the measured costs
in both modes, and what they say about stages 2–5 and the 21.4 s boot
target (`boot-profile.md` §11). No Apple internals are described.

The reference execution model today is the micro-VM of
`specs/simulator/vm-shim-protocol.md`. The Darwin facts used here are in
`specs/simulator/darwin-arm64-abi.md`, `darwin-process-start.md`,
`host-libraries.md`, and `host-library-init.md`. The Arm facts come from the
public Arm Architecture Reference Manual; the Linux facts from public kernel
documentation and uapi headers.

## 1. The question and the motivation

In the micro-VM model each guest process is its own KVM VM, one vCPU per
guest thread, behind an EL1 shim. Guest instructions run natively, but every
Darwin system call and Mach trap is a `KVM_EXIT` into the Swift kernel
personality in the single host process `ycode-simd`, and that personality is
serialized by one global kernel lock. Profiling of the boot
(`docs/SIMULATOR-LINUX.md`, the speed ledger) shows the boot is bound by that
lock: one 661 s boot held it for 370 s across 13.94 M traps, and the cost is
dominated by long serialized holds and the lock-acquisition round trips, not
by the number of traps.

Two separate costs therefore sit on every guest system call:

1. the **boundary crossing** — leaving EL0, the shim, the `KVM_EXIT`, the
   `KVM_RUN` re-entry;
2. the **serialization** — taking the global kernel lock, even for work that
   touches only this process's own state (its memory map, its descriptors,
   its own threads).

Native mode attacks both. If a guest process is a plain Linux process, then:

- a Darwin system call that originates in **our** host libraries
  (`ycode/SimHostLibs`, which already replace `libsystem_kernel`,
  `libsystem_platform`, and `libsystem_pthread`) can become a direct
  **function call** into a process-local kernel-personality runtime — tens
  of nanoseconds, no VM exit;
- process-local state (VM map, descriptors, threads, per-process Mach port
  space) lives in the process and needs no global lock;
- only genuinely cross-process state (Mach ports and messages between
  tasks, the bootstrap/launchd namespace, shared file state) needs a shared
  component and its own synchronization.

The micro-VM stays the correct model where it is needed (an x86-64 host, or
any guest code we cannot mediate). Native mode is an arm64-host optimisation
that rests on the fact that **almost every guest system call already
originates in Ycode code we control**, because we supply the three host
libraries the runtime re-exports.

## 2. Why a plain Linux process is normally a poor fit, and what changes

`docs/SIMULATOR-LINUX.md` §2 lists three reasons a Darwin binary cannot just
run on Linux. Native mode answers each without a VM, by exploiting that our
libraries mediate the ABI.

### 2.1 The trap instruction

Darwin issues `svc #0x80` with the call number in `x16`; Linux ignores the
immediate and dispatches on `x8`, so an un-mediated Darwin `svc` would run a
random Linux call. In native mode there are two populations of `svc`:

- **Inside our libraries.** Every system call our runtime makes is one of a
  known, finite set of `svc #0x80` sites in `libsystem_kernel`,
  `libsystem_platform`, and `libsystem_pthread` (and the private traps of
  `host-libraries.md` §4, §10). These are *our* code. At load time the
  runtime can bind each site to a direct call into the personality instead
  of executing `svc`. This is the fast, common path.
- **Stray `svc` outside our libraries.** `dyld_sim` and a few other images
  contain inline `svc #0x80`. These are not our code and cannot be bound at
  load time without rewriting foreign text. They must be intercepted by the
  kernel: a **seccomp-bpf** filter that allows native Linux syscalls from
  the runtime's own text and traps Darwin `svc` with `SECCOMP_RET_TRAP`,
  delivering `SIGSYS`; the handler reconstructs the Darwin call from the
  signal's register context and dispatches it (§6). This path is rarer and
  costlier than a function call but still avoids a VM.

The design choice of *how* a library `svc` site reaches the personality (a
bound call vs. letting every `svc` fall to the seccomp handler) is an
implementation matter and is deliberately left out of this spec; both reach
the same personality entry.

### 2.2 Thread-local storage: `TPIDRRO_EL0` and `TPIDR_EL0`

This is the hardest obstacle and deserves the most care.

**What Darwin expects.** Darwin reads the current thread's TSD base from
`TPIDRRO_EL0` with an inlined `mrs` (`host-libraries.md` §8: the base points
at TSD slot 0, and `pthread_t = base − 224`). `__thread` accesses and errno
(`__error`, TSD slot 1) depend on it. Separately, Darwin reads a CPU index
from `TPIDR_EL0` (public XNU `_os_cpu_number`, low 12 bits); Ycode's own
`pthread_cpu_number_np` does exactly this (`pthread/thread.c`).

**What Linux does.** On a native AArch64 task the kernel writes
`TPIDRRO_EL0 = 0` on every context switch (`tls_thread_switch` in
`arch/arm64/kernel/process.c`), and when the EL0 trampoline vectors are
active (KPTI, or a branch-history mitigation) the `kernel_ventry` entry path
also zeroes it on every exception entry. `TPIDR_EL0` is the thread pointer
Linux gives to user TLS, so glibc (and the Swift runtime, if the runtime
process uses it) already owns it. On the Thor the CPU reports Meltdown and
the Spectre-BHB family as *not affected*, so the trampoline vectors are not
installed and only the context-switch zeroing is in play; this is
host-specific and must not be assumed on other machines.

So native mode has to make Darwin's `mrs x, TPIDRRO_EL0` yield our
per-thread TSD base, while `TPIDR_EL0` is already spoken for by the host
runtime's own TLS, and Darwin *also* wants to read `TPIDR_EL0` as a CPU
number. Three approaches, with trade-offs:

| Approach | How | Pros | Cons |
|---|---|---|---|
| (a) kernel prctl | A small patch gives each thread a preserved `TPIDRRO_EL0`, set via a new `prctl`, restored in `tls_thread_switch` (and, where trampolines are active, on the EL0 return path), reset at `exec`. | Darwin's inline `mrs TPIDRRO_EL0` works unchanged; no foreign-text edits; cheapest at run time. | Needs a custom kernel on every host; the owner installs kernels; portability and maintenance burden. Does not by itself fix the `TPIDR_EL0`-as-CPU-number read. |
| (b) load-time rewrite | At load, rewrite `mrs Xt, TPIDRRO_EL0` in mapped code pages to read our base instead, and `mrs Xt, TPIDR_EL0` (CPU-number reads) to a constant or a runtime call. | Runs on a stock kernel; no VM. | Must edit foreign text (`dyld_sim`, cache images); correctness depends on finding every site and on no code reading the raw register for another purpose; interacts badly with code signing and with any self-checking code. Out of scope to design in detail here. |
| (c) runtime-owned register | Keep `TPIDRRO_EL0` holding the Darwin TSD base and swap the host runtime's own TLS onto `TPIDR_EL0` around personality code, i.e. the runtime never relies on `TPIDRRO_EL0` for itself. | No kernel patch, no foreign-text edits for the RO register. | Requires the host runtime to be built to not use `TPIDRRO_EL0`, and the kernel still zeroes `TPIDRRO_EL0` at every context switch, so the value must be re-established on entry to the thread — which on a stock kernel is only possible from the seccomp/signal path or a per-syscall reload, adding cost. |

The CPU-number read of `TPIDR_EL0` is a second, independent problem that
every approach above must also solve: in native mode `TPIDR_EL0` holds the
host runtime's TLS pointer, so a Darwin `_os_cpu_number` read returns
garbage. The cheapest fix is to treat CPU number as a constant (0) for the
simulator; our own `pthread_cpu_number_np` can be changed directly, and
foreign readers are rare and non-fatal if they see a stable 0.

**Assessment.** (a) is the cleanest to run but needs a non-portable kernel;
(c) is the most portable but pays a per-entry cost on a stock kernel; (b) is
viable but is foreign-text rewriting and is intentionally not elaborated
here. A first prototype can pick whichever lets a single-threaded test
program run and defer the rest; the kernel-patch route is a separate,
later decision for the owner.

### 2.3 Page size

The micro-VM uses a 16 KiB translation granule to match Darwin. The Thor's
host kernel uses 4 KiB pages. This is **not** an obstacle for native mode,
because our libraries mediate: 16 KiB is a multiple of 4 KiB, so Darwin's
16 KiB-aligned segments map with `mmap` at their fixed addresses, and our
`libsystem_kernel`'s `mmap`/`mprotect`/`vm_*` entry points (function calls
into the personality) present 16 KiB granularity and report
`vm_page_size = 16384` and the commpage page-shift fields as 14
(`host-libraries.md` §8.4). Finer host-page `mprotect` is harmless. The one
requirement is that the personality enforce 16 KiB rounding so guest code
never observes a 4 KiB boundary.

## 3. Address space and process-start state

Native mode keeps Darwin's fixed-address layout so that `dyld_sim` and the
runtime see what they expect. A small **static loader** (not elaborated in
this spec) maps the executable and its dependencies at Darwin addresses,
keeps `__PAGEZERO` (`0`–`0x1_0000_0000`) unmapped (stage 1's loader is
in §10.1), places the
shared-cache region and `dyld_sim` where the handoff spec requires
(`specs/simulator/dyld-sim-handoff.md`), fills the commpage at Darwin's fixed
address (`0xF_FFFF_C000`/`0xF_FFFF_4000`, `ProcessImage.swift`
`CommpageBuilder`), and builds the initial stack (argc/argv/envp/apple) and
the main-thread TSD block (`host-libraries.md` §8.3). The ranges Linux might
otherwise hand out must be kept clear of the Darwin ranges; the loader
should reserve the Darwin window and place its own and the host runtime's
allocations elsewhere.

The personality then starts the guest exactly as the micro-VM does after the
`dyld_sim` handoff, except that the first guest instruction runs at EL0 on
the real CPU with no shim beneath it.

## 4. The `x18` platform register

Darwin reserves `x18` (the platform register) and its code assumes it is
preserved across calls. Linux arm64 does not reserve `x18` for user space
and the host toolchain may clobber it. The host runtime must be built so
that the personality and any host code reachable from a guest call does not
rely on `x18`, and the guest's `x18` must be preserved across every
transition into and out of the personality (saved and restored in the call
veneer or the signal frame). This is a requirement, not a blocker.

## 5. Threads, signals, and Mach exceptions

- **Threads.** A Darwin `bsdthread_create` / `pthread_create`
  (`threads-and-events.md` §1) maps to a Linux `clone` that sets up the new
  thread's TSD per §2.2, its sigaltstack (below), and its personality
  per-thread record, then enters the Darwin start routine. The per-thread
  runtime record can be reached from Darwin state through a `pthread_t`
  field our `libsystem_pthread` leaves unused, so the personality can find
  it from the TSD without a register of its own.
- **Signals and the red zone.** Darwin arm64 has a 128-byte red zone and
  Linux signal delivery does not skip one. A signal frame (including the
  seccomp `SIGSYS` frame) pushed onto the *Darwin* stack would corrupt a
  leaf function's red-zone locals. **Every** native-mode signal, the seccomp
  path included, must therefore use `SA_ONSTACK` with a per-thread
  `sigaltstack`. This is a correctness requirement, measured against the
  public AAPCS64/Darwin red-zone rule.
- **Mach exceptions.** Faults that Darwin delivers as Mach exceptions
  (`EXC_BAD_ACCESS`, etc.) arrive on Linux as signals (`SIGSEGV`,
  `SIGBUS`, `SIGILL`, `SIGTRAP`, `SIGFPE`). The personality's signal
  handlers translate the Linux `siginfo`/`ucontext` into the Mach exception
  message the guest expects (`processes.md` §4.8 covers the ports). For the
  first prototypes, forwarding is only needed well enough not to lose a
  crash silently.

## 6. The seccomp interception path (stray `svc`)

For `svc #0x80` outside our libraries, a seccomp-bpf filter classifies by
the trapping instruction's origin: native Linux syscalls from the runtime's
own text range are allowed; a Darwin `svc` traps with `SECCOMP_RET_TRAP` and
delivers `SIGSYS`. On arm64 `RET_TRAP` leaves `x0` rolled back to `orig_x0`
and the PC already past the `svc`, and the `ucontext` carries the full
register file, so the handler reads `x16` and `x0..x8`, dispatches the
Darwin call, writes `x0` and the carry (PSTATE bit 29) back into the
`ucontext`, and returns. The handler runs on the sigaltstack (§5).

Costs (design estimate, not yet measured in Ycode): a `SIGSYS` round trip is
signal-delivery cost, on the order of one to a few microseconds — far
cheaper than a `KVM_EXIT` plus the global lock, but far costlier than the
bound function-call path, which is why library sites should take the direct
path and only genuinely foreign `svc` should reach seccomp. One edge case to
guard: a Darwin `x0` that coincides with a Linux restart errno can trip
syscall restart; the filter and handler must prevent the kernel from
treating the trapped instruction as restartable.

## 7. Cross-process state and the shared component

Process-local state (VM map, descriptors, per-process Mach port space,
threads, timers) stays in the process; this is where native mode wins by
dropping the global lock. State that spans processes must live in a shared
component:

- **Mach IPC between tasks** — ports, rights, messages, port-death
  notifications, sender audit tokens (`processes.md` §3–§4).
- **The bootstrap / launchd namespace** — `launchd_sim`, domains, service
  checkin (`specs/simulator/bootstrap-wire.md`, `launchd-sim.md`).
- **Shared file and device state** — the read-only file window, any device
  services.

Design options for the shared component, in rough order of least to most
work:

1. **A broker process** that owns all cross-task Mach state; processes reach
   it over a Unix-domain socket (the real Linux kernel already passes fds
   with `SCM_RIGHTS`, `processes.md` §5). Simple, but every cross-task
   message is a context switch.
2. **Shared memory for the port tables** with futex-based synchronization,
   and sockets only for wakeups. Faster for high-traffic ports, more
   complex and harder to make crash-safe.
3. **A hybrid**: in-process fast paths for a task's own ports, the broker
   for anything that crosses a task boundary.

The existing in-process Mach engine (`YcodeDarwinKernel/MachIPC*`) is the
starting point for the per-process half; the cross-task half is new work and
is the real scope of native mode, mirroring the micro-VM's stage 4b/4c/5/6
progression but without a VM under each process.

## 8. Measurements

### 8.1 The guest probe (built, not yet run natively)

`ycode/Native/guest/nt_probe.c` is a Darwin arm64 (iOS-simulator platform)
program that links only Ycode's `libsystem_kernel`. It checks the native
process contract — the TSD base and slot 0, errno through TSD slot 1, the
commpage signature and 16 KiB page-shift fields, the CPU-number register,
and both library and raw-`svc` calls — and then times a library `getppid`, a
raw in-binary `svc` `getppid`, and `mach_absolute_time`. It builds on the
Mac with the public toolchain (`xcrun clang -target
arm64-apple-ios27.0-simulator`) against our Linux-built dylib. It is the
exit criterion for a first native prototype. Stage 1 (§10) runs it: every
check passes in both modes, and §10.5 has its timings.

### 8.2 KVM exit cost: MMIO doorbell vs forwarded HVC (measured)

`research/experiments/linux-host/exitbench.c` (Ycode's own code) runs a tiny
hand-assembled guest loop and times, per iteration, a bare guest→host→guest
round trip two ways:

- **mmio** — the guest stores to an unbacked GPA; KVM returns
  `KVM_EXIT_MMIO` and advances the guest PC itself. This is Ycode's doorbell
  exit (`vm-shim-protocol.md` §5).
- **hvc** — the guest issues `HVC` with a vendor SMCCC function id, and an
  SMCCC filter range with action `FWD_TO_USER` makes KVM return
  `KVM_EXIT_HYPERCALL` (PC already past the `HVC`).

On the Thor (6.8.12-tegra, one core, `taskset -c 2`), three runs of 500 000
iterations each:

| Exit | ns per round trip |
|---|---|
| MMIO doorbell | 2767, 2754, 2757 |
| forwarded HVC | 2532, 2521, 2528 |

The forwarded HVC is about **8.4 % (≈ 230 ns) cheaper** than the MMIO
doorbell, consistently. Both are bare exits with no Swift dispatcher and no
lock; the full `ycode-simd` trap round trip is far larger (the project's own
earlier figures put the complete EL0→personality→back path in the single- to
low-tens-of-microseconds range, dominated by the dispatcher and the global
lock, not by the exit itself).

**Reading of this result.** Switching the micro-VM's doorbell from MMIO to a
forwarded HVC would shave ≈ 230 ns off each of ~14 M traps — on the order of
~3 s off a ~660 s boot: real but small, and it does nothing about the global
lock, which is where the time goes. The much larger prize is removing the
exit *and* the lock for process-local calls, which is what native mode does.

### 8.3 Native-mode target (projected)

A library system call in native mode is a function call into the
personality: a few nanoseconds to low tens of nanoseconds including
register save/restore, versus ≈ 2.7 µs for the bare KVM exit alone and more
for the full trap. A stray-`svc` call via seccomp is signal-delivery cost
(≈ 1–few µs, design estimate). The dominant structural gain is not the
per-call latency but the removal of the single global lock for all
process-local work.

## 9. Feasibility assessment and staged plan

**Verdict: feasible for arm64 hosts, and the right long-term direction for
speed, but the cross-process (Mach/launchd) half is the bulk of the work,
exactly as in the micro-VM track.** The per-process obstacles (trap
instruction, TLS, page size, `x18`, signals, red zone) are all solvable with
known techniques; none is a blocker. The TLS register is the sharpest
per-process problem and its cleanest solution wants a kernel patch, which is
a portability decision for the owner; a stock-kernel path exists at some
run-time cost.

Staged plan (each stage behind a flag, no change to the micro-VM default):

1. **Single-threaded native runner.** *(Done 2026-11-05, §10; it also
   starts threads.)* Static loader + personality enough to
   run `nt_probe.c` to its "checks ok" line and its timing line on the Thor.
   Pick one TLS approach; CPU-number read handled as a constant. Exit
   criterion: `nt_probe` prints its checks-ok and timing lines and exits 0,
   and the native per-call numbers are recorded against the micro-VM.
2. **Threads and in-process Mach.** `pthread_create` via `clone` with TSD +
   sigaltstack; the in-process Mach engine and kevent/workqueue, all
   process-local, no global lock. Mirror micro-VM stage 4a.
3. **Stray-`svc` via seccomp.** Add the `SIGSYS` path for `dyld_sim` and
   friends; measure its cost in Ycode (fills the gap left by §6/§8.3).
4. **Multiple processes + the shared component.** `posix_spawn`/`exec`,
   lifecycle, and the cross-task Mach broker (§7, option 1 first). Mirror
   micro-VM stage 4b.
5. **`launchd_sim` and the core daemons, natively.** Mirror stages 4c/6.
6. **Host services (display, Metal→Vulkan, HID).** Unchanged from the
   micro-VM track; they already sit on the host side of a socket.

**Expected speedup.** The structural change removes the per-call VM exit and
the global lock for process-local work, which the profile says is where the
boot spends its time. The remaining serialization is confined to genuinely
cross-process IPC and the real work the daemons do. A precise figure cannot
be claimed before stage 1 measures a native call and stage 4 measures
cross-process traffic; the direction is a large reduction, not a few percent.

**Risks.**

- **TLS on a stock kernel.** Without the kernel patch, re-establishing
  `TPIDRRO_EL0` after the kernel zeroes it at each context switch is awkward
  and may cost per-entry work; getting it wrong corrupts errno and TSD for
  every thread. Highest-risk item.
- **Foreign `svc` coverage.** If any guest `svc` escapes both the library
  binding and the seccomp net, it runs a random Linux syscall. The seccomp
  filter must be default-deny for Darwin `svc` from non-runtime text.
- **Red zone and signals.** A missed `SA_ONSTACK` corrupts guest stacks
  intermittently and is hard to debug (compare the KVM-SVE postmortem).
- **Shared-component correctness.** Cross-process Mach semantics (rights
  transfer, port-death, audit tokens) must match the micro-VM's, or
  `launchd_sim` and XPC break; this is the same hard surface as the micro-VM
  track and the same reference specs apply.
- **Portability.** Native mode is arm64-host only; x86-64 hosts keep the
  micro-VM (and would need user-mode arm64 translation regardless).
- **Two code paths.** Running both models means the personality must work
  both behind a VM and in-process; keeping them from diverging is an ongoing
  cost. Sharing `YcodeDarwinKernel` as the single personality mitigates it.

## 10. Stage 1: implementation and measurements (2026-11-05, agent B3-NATIVE)

Issue #44 set the cold-boot target at 1.0 × the reference (home_s ≤ 21.4 s
on a quiet Thor; `boot-profile.md` §11). This section builds stage 1 of §9
and measures what the route can deliver before anyone commits to stages
2–5.

### 10.1 What was built, and the switch

`ycode/Native/runtime/` (C and assembly, about 2,300 lines, original Ycode
code) builds `ycnative` on arm64 Linux (`sh build.sh`; `sh build.sh test`
also runs the host test of §10.4). It runs one Darwin arm64 program as
the calling Linux process, built the way `ycode-simd --macos` builds a
micro-VM process (`specs/macos/macos-apps.md` §3): the program's segments
at their addresses, Ycode's dyld from the macOS userland root at
`0x3_0000_0000` (its `LC_MAIN` entry, `SP` on the Mach-header slot), the
two commpage pages with the micro-VM's default fast-path flags
(`DIRECT_CLOCK | CRED_BLOCK | LOCAL_CALLS | SYSCTL_CACHE`, the 24 MHz clock
scale; `fast-traps.md`), the 8 MiB main stack with the argument block and
`apple[]` strings of `darwin-process-start.md` §1.3–§1.4, and the
main-thread block of `host-libraries.md` §8 item 3. The guest's `/` is the
userland root (read-only), `/tmp` a per-run directory, the program's
directory is at its own path; all Darwin mappings stay below 2^47.

**The switch.** `YCODE_NATIVE=1` makes `ycode-simd --macos …` hand the run
to `ycnative` with the same arguments (`MacOSMode.execNativeIfRequested`,
`YCODE_NATIVE_RUNNER=<path>` names the runner). Unset or `0` (the
default), nothing changes: the micro-VM path is untouched. `ycnative` takes
`ycode-simd`'s `--macos`, `--macos-root`, `--env`, `--exec-args` and
`--timeout-ms`, so `MacUserland/run-samples.sh` drives either.

### 10.2 The choices §2 left open

- **System calls (§2.1).** At load time every `svc #0x80` in an
  instruction section of a Ycode-built image (the userland root: dyld,
  libSystem, the three host libraries) is replaced by `b veneer`; the
  per-site veneer, in a page mapped within branch range, steps over the
  128-byte red zone, saves x17 and x30, and calls the runtime's entry,
  which saves x0–x17 and x30, calls the personality, and sets carry from
  its answer. Any other `svc #0x80` (the program's own text) traps through
  a seccomp filter that allows every system call from above 2^47 (the
  runtime and libc) and answers every call from below with
  `SECCOMP_RET_TRAP`; the `SIGSYS` handler runs on a per-thread
  `sigaltstack` (§5) and puts the PC back after the `svc` when the kernel's
  restart logic rewound it (§6). `YCN_BIND=none|ycode|all` (default
  `ycode`) chooses which images are bound; `all` also binds the program's
  own sites.
- **TLS (§2.2): option (b), and it is one word for one word.** In every
  instruction section of every image (the program, dyld, and each file
  mapping made with `PROT_EXEC`) the loader rewrites `mrs Xt,
  TPIDR_EL0` (Darwin's CPU-number read) to `movz Xt, #0`, then `mrs Xt,
  TPIDRRO_EL0` to `mrs Xt, TPIDR_EL0`. The two `mrs` encodings differ only
  in `op2` (bit 5), so the rewrite keeps every instruction's size,
  position and destination register; the guest's TSD base then lives in
  `TPIDR_EL0`, which EL0 can write (the platform call `thread_set_tsd_base`
  becomes an `msr`), `clone(CLONE_SETTLS)` sets for a new thread, and Linux
  preserves across context switches. Run-time cost: zero. The CPU number
  reads as a constant 0. No kernel patch (option a) is needed, and option
  (c) is not possible on a stock kernel at all: EL0 cannot write
  `TPIDRRO_EL0`, and no system call or signal return sets it for an
  AArch64 task.
- **The personality runs without TLS or FP.** `ycn_sys.c` and
  `ycn_bind.c` are built with `-ffreestanding -mgeneral-regs-only
  -ffixed-x18 -fno-stack-protector -mno-outline-atomics`, call no libc
  function and read no thread-local variable; `build.sh` checks the
  objects for outside symbols and for any FP/SIMD register or x18. That is
  why the light entry saves only x0–x17 and x30 and never switches
  `TPIDR_EL0`. The **heavy entry** (`YCN_HEAVY=1`, measurement only) also
  saves Q0–Q31, FPCR and FPSR and switches `TPIDR_EL0` to the runtime's
  value and back: the crossing a personality with its own TLS and FP use
  (Swift, `YcodeDarwinKernel`) would need.
- **Page size (§2.3).** The personality rounds every mapping to 16 KiB and
  places mappings without `MAP_FIXED` itself (first free 16 KiB-aligned
  range from `0x3_2000_0000`, with `MAP_FIXED_NOREPLACE`).
- **Threads (§5, part of stage 2).** `bsdthread_register` and
  `bsdthread_create` (`PTHREAD_START_CUSTOM`) follow
  `threads-and-events.md` §1 as Ycode's kernel does: a `clone` with the
  new thread's TSD base as its TLS, the thread port in TSD slot 3,
  `thread_start` with x0–x5 as the micro-VM passes them, a runtime-owned
  area per thread for its signal stack and its exit. `bsdthread_terminate`
  switches to that area before it unmaps a detached thread's stack or
  writes the join gate (`port & ~3`) and wakes the joiners, so nothing
  touches guest memory the joiner may free. `__ulock_wait`,
  `__ulock_wait2` and `__ulock_wake` are futexes (64-bit compares
  checked first; shared variants without `FUTEX_PRIVATE`).

### 10.3 The personality's surface

What the userland root's dyld and libSystem and the Milestone A samples
call (counted from `ycode-simd --macos --trace` runs of each sample):
BSD `exit`, `read`, `write`, `open`, `openat`, `close`, `unlink`, `rmdir`,
`mkdir`, `access`, `stat64`, `lstat64`, `fstat64`, `fstatat64`, `pread`,
`pwrite`, `lseek`, `fcntl` (dup, fd and status flags), `ioctl` (terminal
query only), `mmap`, `munmap`, `mprotect`, `madvise`, `getpid`, `getppid`,
the four credential calls, `issetugid`, `getentropy`, `gettimeofday`,
`kill` of itself, `sigaction` and the signal masks (accepted, not
modelled), `proc_info` (ENOTSUP, as Ycode's kernel answers most of it),
the thread calls above, `abort_with_payload`; Mach traps −3/−4 (time), −10,
−12, −14 (`mach_vm_allocate`/`deallocate`/`protect`), −16, −18…−20 (port
names and rights, without a port table), −26…−29 (reply, thread, task and
host ports), −59/−61 (yield), −89 (`mach_timebase_info`); the platform
call (§4 of `darwin-trap-tables.md`); Ycode's private traps `0x7963_0F00`
(unimplemented library function, logged) and `0x7963_2005`
(`task_get_special_port`). `mach_msg`/`mach_msg2` answer
`MACH_SEND_INVALID_DEST`: there is no Mach IPC, no signal delivery, no
`fork`/`exec`/`posix_spawn` and no second process in stage 1. Every call
is a function of this process: there is no kernel lock.

### 10.4 Correctness

| Check | Result (Thor) |
|---|---|
| `nt_probe` (§8.1), all checks: TSD base and slot 0, CPU-number read, commpage, library and raw calls, errno through TSD slot 1, time, a raw `svc` and an unknown call (carry, ENOSYS) | **checks ok, exit 0** natively, in every binding mode and with the heavy entry; also in the micro-VM (`--exec` with the iOS 27.1 runtime). Check 13 compared the wrong bytes of the commpage signature (`commpage 64-bit` has a space at byte 8) and failed in both modes; fixed in the probe |
| Milestone A (`run-samples.sh`: `hello`, `hello fail`, `fileio`, `threads`, `dispatch`, `hello-swift`) | **6 of 6 pass** natively, directly, with the heavy entry, and through `YCODE_NATIVE=1 ycode-simd`; 6 of 6 in the micro-VM |
| Repeats: `threads`, `dispatch`, `hello-swift`, `fileio`, 20 each | 80 of 80 |
| Call counts: `hello` makes 62 calls natively, the micro-VM 62 traps | identical sequence |
| `bind_test` (host test): bound `svc` result, carry and errno, x9/x15/x17, the red zone below SP, `d16` (heavy and light), `TPIDRRO_EL0` → `TPIDR_EL0`, CPU number → 0 | 18 of 18 |

In the five images of a `hello` run the loader rewrote 56 TLS reads and
bound 752 `svc` sites (dyld and four libraries).

### 10.5 Per-call costs, both modes

Thor, one series (`s2`) under the boot-timing lock: 7 rounds, arms
alternated each round, every run pinned to the same four cores
(`taskset -c 8-11`), the same binaries in both modes, 1-minute load 13.8
falling to 4.2 over the series (other agents' work; no boot ran). Medians
of 7 runs, range in parentheses. *VM* is `ycode-simd --macos` (`nt_probe`:
`--exec`), *native* is `ycnative` with the light entry, *heavy* with the
heavy entry. `nt_bench` is `ycode/Native/guest/nt_bench.c` (macOS
platform, public POSIX and Mach API; its header says what each row does).

| Measure | VM | Native | Heavy | VM ÷ native |
|---|---|---|---|---|
| `getppid` through the library, ns (`nt_bench bsd`) | 4,315 (4,291–4,349) | 136 (135–137) | 155 (150–161) | 31.7 |
| a Mach trap with no work (`mach_thread_self` + `mach_port_deallocate`, per trap), ns | 4,246 (4,222–4,266) | 14.7 (14.6–14.7) | 30.3 (30.0–30.5) | 289 |
| file: `open`, `fstat`, `pread` 4 KiB, `close` of a root file, per call, ns | 6,882 (6,858–6,904) | 553 (547–562) | 560 (555–584) | 12.5 |
| first write to a fresh 16 KiB page, ns | 319 (316–328) | 274 (266–284) | 268 (267–279) | 1.2 |
| writing a whole fresh 16 KiB page, ns | 897 (890–915) | 698 (684–716) | 692 (683–703) | 1.3 |
| `mmap` + `munmap` of 64 KiB, per call, ns | 6,822 (6,788–6,834) | 1,167 (1,038–1,316) | 1,168 (966–1,220) | 5.8 |
| thread hand-off (mutex/condition ping-pong, half a round trip), ns | 10,408 (10,351–10,599) | 4,620 (2,626–4,767) | 4,776 (2,725–4,956) | 2.3 |
| `pthread_create` + `pthread_join`, µs | 88.4 (87.4–100.3) | 35.9 (35.5–36.8) | 36.4 (36.0–36.7) | 2.5 |
| `nt_probe` library `getppid`, ns | 4,305 (4,299–4,323) | 140 (139–140) | 149 (149–150) | 30.8 |
| `nt_probe` raw `svc` `getppid` from the program's text, ns | 4,281 (4,274–4,302) | 957 (949–1,116) (seccomp) | 954 (952–1,108) | 4.5 |
| the same with `YCN_BIND=all` (the program's site bound too), ns | — | 137 (136–139) | — | 31.2 |
| `mach_absolute_time` (commpage clock, no call in either mode), ns | 69.2 | 69.1 | 69.2 | 1.0 |

On the same cores a host `getppid` costs 95 ns and a bare forwarded-HVC
KVM exit 2.47–2.56 µs (`exitcost syscall`, `exitcost user`, 5 runs).
So:

- **The bound crossing costs about 41 ns** (136 − 95) with the light
  entry, about 15 ns when the call does no system call of its own (the
  Mach row), and **16–19 ns more with the heavy entry** (the TLS switch and
  the 32 Q registers). A Swift personality would pay about 60 ns per call
  before its own work; the earlier design target from Kakehashi was 60 ns
  (`docs/native-loader-evaluation.md` §2.1).
- **The seccomp path costs about 0.86 µs** above the host call: 7 × a
  bound call, 5 × less than a micro-VM trap. Binding a site by rewriting
  works on any text, not only Ycode's (`YCN_BIND=all`).
- **A micro-VM trap costs 4.2–4.3 µs whatever the call does**, 2.5 µs of
  it the bare exit; `guest-cpu.md` §5.2 has the rest of the breakdown.
- **Faults barely differ** (1.2–1.3 ×): fresh guest memory in the micro-VM
  comes from pools whose host pages are already present, so its first
  touch is a stage-1 entry, not a host fault.
- **Thread hand-offs and creation gain 2.3–2.5 ×, not 30 ×**: most of
  their cost is the host scheduler's wakeup, which both modes pay.

### 10.6 Whole programs, both modes

The same series, wall time from the runner's start to its exit (process
creation, loading, the program, teardown), ms, median of 7:

| Program | VM | Native | VM ÷ native |
|---|---|---|---|
| `hello` (62 calls) | 77.3 (64.2–95.8) | 4.9 (4.5–5.4) | 15.7 |
| `threads` (8 threads, about 300 calls) | 153.2 (83.8–182.7) | 17.7 (16.0–19.3) | 8.7 |
| `dispatch` (17 threads) | 270.0 (210.2–494.0) | 26.6 (26.1–26.9) | 10.2 |
| `hello-swift` | 79.3 (65.4–93.1) | 4.6 (4.5–5.0) | 17.2 |

Most of the micro-VM's start-up here is building the VM and its vCPUs, the
part `boot-profile.md` §7 and §9 measured for every daemon of a boot.

**The boot itself.** Stage 1 cannot run any part of it: a simulator
process needs `dyld_sim` with the shared cache (stage 3), Mach IPC and the
bootstrap port (stages 2 and 4) and `launchd_sim` (stage 5). No boot was
timed natively.

### 10.7 What stages 2–5 could save on the 21.4 s path

The quiet-host critical path (`boot-profile.md` §8.3, `r3q`, 33.07 s) item
by item, with what native mode changes, from the measurements above. The
saving is for the boot's path, not host CPU in general.

| Item (§8.3 number) | On the path, s | Native saving, s | Why |
|---|---|---|---|
| L0 waits in SpringBoard's own traps (6) | 1.52 | 1.2–1.5 | process-local calls take no global lock |
| SpringBoard's file and memory traps (9, 10) | 1.02 | 0.7–0.9 | file calls 12.5 ×, `mmap` 5.8 × cheaper (§10.5) |
| Mach IPC trap service (8) | 0.67 | 0–0.3 | cross-process: a broker costs 3.4–20 µs a message (`native-loader-evaluation.md` §2.2), no better than a trap |
| The log path: back-pressure, event-lock and port-lock waits (4, 5, 11) | 3.30 | 0–1.5 | cross-process too; more than 0 only with shared-memory port tables (§7 option 2) |
| Host CPU oversubscription (2, 3) | 7.68 | 0.2–1.0 | a boot makes about 3.9 M traps (`guest-cpu.md` §6.1); at 4.2 µs → 0.14 µs that is about 16 s of the 290–300 s of host CPU a boot spends (5 %); 5 s less CPU did not move home_s (`guest-cpu.md` §7.2) |
| Spawns and device preparation (12–14) | 0.79 | 0.2–0.5 | no VM or vCPU to build (§10.6) |
| Mercury's launch to the home frame, kernel part (7) | 0.33 | 0.1–0.25 | |
| SpringBoard's wakeups (15) | 0.20 | 0–0.1 | hand-offs 2.3 × cheaper |
| SpringBoard's guest code (1) | 14.10 | −1.0 to +1.0 | no stage-2 translation, but 4 KiB host pages instead of 16 KiB guest pages: `guest-cpu.md` §2 has TLB-bound rows going both ways |
| **Total** | 29.61 | **1.4–7.1, central about 4** | |

Of that, the log-path and CPU-wait shares (0.2–2.5 s) overlap with ranks 1
and 2 of `boot-profile.md` §11.2, which attack the same items in the
micro-VM. What only native mode removes is the trap service and the global
lock of process-local calls, spawns, and wakeups: **2.2–3.6 s**. Item 6 is
lock contention that the micro-VM's own lock work (C20, task-local traps;
KLOCK) also attacks. Even the high end of the whole range (7.1 s) is
below the 8.7 s the target needs, so native mode cannot reach 21.4 s
alone.

### 10.8 Risks, as stage 1 found them

- **The guest reading `TPIDRRO_EL0`.** Solved for loaded text at zero run
  time cost (§10.2). Left: code that is written at run time (a JIT, such as
  JavaScriptCore's in the runtime's WebKit; copied trampolines) is never
  rewritten and would read the old register (0 on Linux). A hook exists:
  such code must call `sys_icache_invalidate`, which is in Ycode's
  `libsystem_platform` and could rescan the range. A data word in an
  instruction section that equals one of the two encodings would be
  corrupted; none was seen, and only sections flagged as instructions are
  scanned. The CPU number is always 0.
- **Foreign code in the same process.** Apple's images, the runtime and
  libc share one address space: a wild write in guest code can corrupt the
  runtime, which the micro-VM never allows. Keeping all Darwin mappings
  below 2^47 (the Objective-C pointer mask) and the runtime above it only
  separates them by address. The personality must also stay without TLS
  and FP (or pay the heavy entry, about 60 ns a call), which rules out
  running `YcodeDarwinKernel` (Swift) unchanged on raw-cloned guest
  threads: they have no libc TLS block.
- **Signal handling.** Not in stage 1. Guest handlers need Darwin's
  `ucontext`/`mcontext` layout built from Linux's, Mach exception
  messages for faults (§5), and signals that arrive while a thread is in
  the personality must be deferred (spin locks are held there); with a
  Swift personality, blocking signals around each call would cost two
  more system calls per call (about 190 ns). The seccomp handler already
  runs on the alternate stack (the red zone).
- **The second code path.** Stage 1's personality is a second
  implementation of 40-odd calls. The micro-VM's kernel is 57,000 lines
  of Swift; carrying its semantics into a freestanding in-process
  personality, or making it run in-process, is the bulk of stages 2–5.

### 10.9 The next stage's size

Stage 2 (§9) is half done: threads, ulocks and thread exit run. What is
left: in-process Mach IPC (port spaces, rights, messages, MIG routines),
`kevent`/kqueue with workloops, the workqueue, signals, `posix_spawn`. In
`YcodeDarwinKernel` those are about 7,700 lines (`MachIPC*`, `KEvent`,
`Workqueue`) plus 2,000 for threads, ulocks and semaphores. Either port
them to the freestanding personality or make the Swift kernel callable
in-process (heavy entry, threads made by the runtime with libc TLS, a
memory accessor that is the identity): an estimated **2–3 agent-weeks**
for stage 2. Stages 3–5 (`dyld_sim` and the shared cache natively, the
cross-process broker or shared port tables, `launchd_sim` and the 190
daemons) are months, with the risks of §10.8 and §9.

### 10.10 Verdict

Per call, native mode is what the study promised: a process-local system
call costs 30 × less, a Mach trap with no work 290 × less, file calls 12 ×
less, and small programs start 9–17 × sooner. For the boot it is not:
the path is dominated by SpringBoard's own code and by cross-process
traffic, and the part only native mode removes is 2.2–3.6 s of the
8.7 s needed, after months of high-risk work. **Recommendation: do not
continue native mode toward the 21.4 s target**; spend the effort on
`boot-profile.md` §11.2 ranks 1, 2 and 4 and on the micro-VM's
process-local lock work (item 6). Stage 1 stays in the tree behind its
switch, off by default, as the measured base should the route be needed
later (for example if ranks 1, 2 and 4 stop short).

## Evidence

- The boundary-cost and global-lock characterisation of the boot: the
  project's boot profiling recorded in `docs/SIMULATOR-LINUX.md` and the
  speed ledger (level 3, black-box timing of our own system).
- `TPIDRRO_EL0` / `TPIDR_EL0` kernel behaviour (`tls_thread_switch`, the
  `kernel_ventry` zeroing, trampoline-vector gating): read in the public
  Linux 6.8 arm64 source (`arch/arm64/kernel/process.c`, `entry.S`);
  the Thor's mitigation status from `/sys/devices/system/cpu/vulnerabilities`
  (level 1 / level 3).
- Darwin TSD base, `pthread_t = base − 224`, errno slot, commpage
  page-shift, CPU-number read: `host-libraries.md`, `host-library-init.md`,
  `darwin-process-start.md`, and Ycode's own `SimHostLibs` code (level 1
  specs over public Darwin API; level 4 for layout facts).
- The red zone and `x18` reservation: the public AAPCS64 / Apple arm64
  calling-convention documentation (level 1).
- seccomp `SECCOMP_RET_TRAP` / `SIGSYS` arm64 semantics: public Linux
  kernel documentation and uapi (level 1); the Ycode cost figure is a
  design estimate, not yet measured (noted as such in §6/§8.3).
- The SMCCC filter and `KVM_EXIT_HYPERCALL`: the public KVM API docs
  (`Documentation/virt/kvm/api.rst`, `devices/vm.rst`) and uapi
  (`arch/arm64/include/uapi/asm/kvm.h`) (level 1).
- The MMIO-vs-HVC numbers: `research/experiments/linux-host/exitbench.c`,
  our own code, run on the Thor, 2026-10-17 (level 3). The bare-MMIO figure
  agrees with the ≈ 2.75–2.97 µs recorded in `docs/postmortem-kvm-sve.md`.
- Stage 1 (§10): `ycnative` and its host test (`ycode/Native/runtime`),
  `nt_probe` and `nt_bench` (`ycode/Native/guest`), all our own code, run
  on the Thor 2026-11-05 against the micro-VM with the same binaries
  (level 3). The A64 encodings of the rewritten instructions: the Arm
  Architecture Reference Manual (level 1). That EL0 cannot write
  `TPIDRRO_EL0` and that `clone(CLONE_SETTLS)` sets `TPIDR_EL0`: the Arm
  ARM and the public Linux arm64 sources (`process.c` `copy_thread`,
  `tls_thread_switch`) (level 1). seccomp's `instruction_pointer` and
  `si_call_addr`: public Linux documentation (`seccomp_filter.rst`) and
  uapi (level 1). The personality's call surface: `ycode-simd --trace`
  runs of Ycode's own samples (level 3). Level 5 was not used; `research/`,
  the reference tools, Ghidra and the IPSW were not opened.
