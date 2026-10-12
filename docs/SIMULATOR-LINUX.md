# Design: running the iOS simulator runtime on arm64 Linux

Status: **design, agreed direction (option B in `docs/SIMULATOR.md`)**.
First host: the Thor (Neoverse V3-class, Ubuntu 24.04, KVM available to
`<user>`).

## 1. What has to be provided

On macOS the simulator is ordinary host processes, rerooted by dyld
(`research/notes/simulator-observations.md`). On Linux, Ycode must provide
everything that macOS provides for free:

| macOS provides | Ycode on Linux |
|---|---|
| The XNU kernel ABI (`specs/simulator/darwin-arm64-abi.md`) | **Darwin personality layer** (§3) |
| dyld + `DYLD_ROOT_PATH` → `dyld_sim` | **Loader**: `YcodeMachO` for parsing (done); mapping and fixups to come |
| The commpage | Filled in by the personality layer |
| launchd bootstrap for `launchd_sim` | Bootstrap and Mach-port server in the personality layer |
| CoreSimulator host services (render, Metal, audio, stream, syslog, test manager) | Ycode host services, added in stages |

## 2. Execution model: why a micro-VM

Three facts make a plain Linux process a poor fit:

1. **The trap instruction.** Darwin code issues `svc #0x80` with the number
   in `x16`. Linux ignores the immediate and reads `x8`, so every Darwin
   system call would run as a random Linux system call. Catching them would
   need seccomp traps, which cost one signal per call.
2. **TLS.** Darwin code reads its thread pointer from `TPIDRRO_EL0`, which a
   Linux process cannot set. The alternative is rewriting every
   `mrs …, TPIDRRO_EL0` in a 4 GB cache and swapping `TPIDR_EL0` around
   host code.
3. **Pages.** The guest is laid out for 16 KB pages, and the Thor's host
   kernel uses 4 KB pages.

A **KVM micro-VM** removes all three. The probe
`research/experiments/linux-host/kvm_probe.py` confirmed on the Thor that:

- `/dev/kvm` is usable by `<user>` (through an ACL);
- the **16 KB translation granule** is supported in a guest;
- the guest has 48-bit VA and 48-bit PA, and AArch64 only at EL0;
- pointer authentication is not exposed to the guest by default. That is
  fine, because the simulator cache is arm64, not arm64e.

The guest's processes run at **EL0** with 16 KB pages. A small **EL1 shim**
written by Ycode (a few hundred lines of assembly and C, not Darwin code)
does four things:

- installs page tables;
- sets `TPIDRRO_EL0` for each guest thread;
- turns every `svc #0x80` into a VM exit (an `hvc`) that carries the
  register file;
- handles faults the same way.

The **VMM** is a Ycode Swift process on the host. It owns guest memory and
implements the Darwin ABI on top of Linux.

```
 guest EL0:  dyld_sim / launchd_sim / app  (unmodified runtime code)
 guest EL1:  Ycode shim  — page tables, TPIDRRO_EL0, svc→hvc, faults
 ─────────────────────────── KVM ───────────────────────────
 host:       ycode-simd (Swift VMM)
               ├─ Mach-O/cache mapper (YcodeMachO)
               ├─ BSD syscall emulation → Linux syscalls
               ├─ Mach traps: ports, messages, VM, tasks/threads
               ├─ bootstrap/launchd and XPC routing
               └─ host services (syslog, later render/Metal/audio)
```

Each guest process is an address space in the VM. Each guest thread is a
vCPU, or vCPUs are multiplexed when the thread count grows.

## 3. Stages and exit criteria

1. **Format layer.** *(Done.)* Parse Mach-O and the shared cache. The
   dependency closure of `launchd_sim` is 57 cache images, all present.
2. **VM bring-up.** The shim boots in KVM, maps a 16 KB-page EL0 address
   space, and runs a hand-assembled EL0 test that makes `svc #0x80` calls
   and gets results back. Exit criterion: a round trip for `getpid` (BSD
   20) and `mach_absolute_time` (−3). *(Done 2026-10-11.)*
   - The EL0 self-test passes every check: TPIDRRO_EL0, getpid,
     mach_absolute_time ×2, ENOSYS with carry, write, a read across the
     16 KB page split, and exit(0).
   - One trap round trip (EL0 → shim → KVM exit → Swift dispatcher → back)
     measured about 32 µs, which is a baseline to improve later.
   - The work was built by three parallel agents against
     `specs/simulator/vm-shim-protocol.md`.
3. **Static-image runner.** Map an executable plus the shared cache at
   `0x1C0000000`, apply chained fixups, provide the commpage and the
   initial stack (argc/argv/envp/apple), and start `dyld_sim`. Exit
   criterion: a command-line guest tool reaches `main` and writes to
   stdout through `write` (BSD 4).
4. **Syscall coverage driven by traces.** Run guest tools and log every
   unimplemented trap. Implement the most frequent first.
5. **Mach IPC and bootstrap.** Ports, rights, `mach_msg`, and bootstrap
   lookup, enough to run `launchd_sim` with no daemons.
6. **launchd_sim plus the core daemons.** `cfprefsd`, `notifyd`,
   `logd`-equivalents. A headless boot.
7. **UIKit app, headless.** The probe app (`research/experiments/simulator/ProbeApp`)
   prints its report.
8. **Display, input, GPU.** A render service, Metal → Vulkan (the Thor's
   GPU), and HID.

## 4. Risks

- **Scale of the Mach/XPC surface.** This is the bulk of the work. Darling
  is a reference point for scope, not for code.
- **Undocumented runtime expectations:** commpage fields, host-service
  sockets, and `launchd_sim`'s bootstrap protocol. These will be learned by
  black-box tracing on the Mac and recorded as specs.
- **x86-64 hosts** need user-mode arm64 translation on top of all this. That
  is deferred.

## 5. Clean-room status

The design uses only:

- level-1 sources (xnu and dyld headers, public documentation);
- level-3/4 observations of the runtime.

The guest runtime itself is an input, copied by the owner and never
redistributed.
