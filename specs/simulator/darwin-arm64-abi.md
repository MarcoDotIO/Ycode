# Spec: the Darwin arm64 user/kernel boundary (as seen by simulator code)

Status: reference for the Ycode Linux simulator host (`docs/SIMULATOR-LINUX.md`).
Facts are from Apple's open-source `xnu` (level 1), read through the GitHub
API on 2026-10-11. This spec restates them; it does not copy code.

## 1. Trap instruction and dispatch

- User code enters the kernel with **`svc #0x80`**. The trap number is in
  **`x16`**. Arguments are in `x0`–`x7`, with more on the stack following
  the C calling convention of the call.
- The kernel dispatches on the trap number, signed 32-bit:

| x16 | Class | Notes |
|---|---|---|
| `0x80000000` | **platform call** | Machine-dependent calls, including `thread_set_cthread_self` (sets the thread's TSD base, see §3) |
| −3 | `mach_absolute_time` fast trap | Returns the time in `x0` |
| −4 | `mach_continuous_time` fast trap | |
| other negative | **Mach trap** −N | The Mach trap table: port, message, VM, task, and thread primitives |
| positive | **BSD system call** N | Numbered as in `bsd/kern/syscalls.master` (669 entries, including reserved/nosys slots) |

## 2. Return convention

- **BSD calls:** on success, carry (PSTATE.C) is clear and `x0` (plus `x1`
  for two-value returns) holds the result. On error, carry is **set** and
  `x0` holds the errno. libsystem's wrappers branch on carry.
- **Mach traps:** they return a `kern_return_t` in `x0` and do not use
  carry.

## 3. Thread-local storage

- Each thread's TSD/TLS base is held in **`TPIDRRO_EL0`**. User code can
  read this register but not write it. It is set with the platform call
  `thread_set_cthread_self`, which xnu implements as
  `machine_thread_set_tsd_base`.
- Darwin code reads the base directly with `mrs xN, TPIDRRO_EL0`. Linux
  keeps that register for its own use and gives user space no way to set
  it. That is the main reason Ycode runs guest code in a VM (see the design
  doc).

## 4. Commpage

- The kernel maps a shared page at **`0x0000000FFFFFC000`** (64-bit
  processes, in the TTBR0/user range) and a read-only area at
  **`0x0000000FFFFF4000`**. libsystem reads time bases, CPU capabilities,
  and similar values from fixed offsets in it.
- The offset map is in `osfmk/arm/cpu_capabilities.h`. Ycode's host must
  provide the commpage with the fields the runtime reads, so that table is
  the next thing to write into this spec.

## 5. Address-space facts relevant to hosting

- Darwin arm64 uses **16 KB pages**. The simulator binaries' segments are
  aligned to 16 KB, and executables reserve a 4 GB `__PAGEZERO`.
- The simulator shared cache is mapped at its preferred base
  (`0x1C0000000` for the iOS 27.1 runtime) unless it is slid. Slide info is
  per mapping (see `specs/formats/macho-and-dyld-cache.md`).
- The simulator cache is **arm64 (not arm64e)**: no pointer authentication
  is required.

## Evidence

- Level 1: `xnu` `osfmk/arm64/sleh.c` (svc dispatch),
  `osfmk/mach/arm/traps.h`, `osfmk/arm64/proc_reg.h` (platform trap
  number), `osfmk/arm/machdep_call.{c,h}`, `bsd/dev/arm/systemcalls.c`
  (carry convention), `osfmk/arm/cpu_capabilities.h` (commpage addresses),
  and `bsd/kern/syscalls.master`.
- Level 4: page alignment and the shared-cache base, read from the iOS 27.1
  runtime with `ycode macho`/`ycode dsc`.

## Open questions

- The platform call's sub-selector for `thread_set_cthread_self`. The
  dispatch routine is not in the files read so far.
- Which commpage fields the iOS 27.1 runtime reads at startup.
