# Spec: native mode — running Darwin guest processes directly on arm64 Linux

Status: **feasibility study (design).** This is a proposal, not an
implemented stage. It evaluates whether a Darwin guest process can run as an
ordinary arm64 Linux process, with its system calls becoming function calls
into a Ycode runtime in the same process, instead of running inside a
per-process KVM micro-VM (`docs/SIMULATOR-LINUX.md` §2). It records what
such a mode would require, the trade-offs of each approach, one measured
microbenchmark, and a staged plan. No Apple internals are described.

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
keeps `__PAGEZERO` (`0`–`0x1_0000_0000`) unmapped (no loader is
implemented; native mode is paused at this study), places the
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
exit criterion for a first native prototype. No loader or personality
runtime exists (native mode is paused at this study, 2026-10-17), so the
probe has not been run natively; §8.3 gives the projected target.

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

1. **Single-threaded native runner.** Static loader + personality enough to
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
