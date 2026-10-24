# Spec: what a new arm64 Darwin process sees at exec

Status: **reference** for stage 3 of `docs/SIMULATOR-LINUX.md` (the
static-image runner). It describes the state that the XNU kernel builds for
a new 64-bit arm64 process before any user code runs: registers, the initial
stack, the address-space layout, and the commpage. It also states the trap
conventions that the VMM must reproduce.

All facts come from Apple's open-source `xnu` (evidence level 1), tag
`xnu-12377.121.6` (commit `ac9718fb1af618d5ce8678d0dc6e8a58f252216f`), read
through the GitHub API on 2026-10-11. This document restates behavior and
values. It contains no xnu code. The companion tables are in
`specs/simulator/darwin-trap-tables.md` and `specs/simulator/data/`.

Terms:

- "slide" is the main executable's ASLR offset. "dyld slide" is the
  independent offset for the dynamic linker.
- The simulator runs on a **macOS** arm64 kernel. Where macOS and iOS
  kernels differ, this spec gives the macOS value first.

---

## 1. Process start at exec (Q1)

### 1.1 Sequence (`execve` / `posix_spawn` of a Mach-O image)

The kernel does the following, in this order. Only steps that affect the
user-visible state are listed.

1. **Save the path.** The path that was passed to `execve`/`posix_spawn`
   is stored, exactly as given (it can be relative), as the first string of
   the string area, with the prefix `executable_path=`. For a `#!` script,
   the interpreter path replaces it.
2. **Copy in argv and envp.** The path string is padded with NUL bytes to
   an 8-byte boundary. Then the argv strings follow, then the envp strings,
   each terminated by one NUL. The combined argv+envp block is padded with
   NUL bytes to an 8-byte boundary. The string space limit is
   `NCARGS + PAGE_SIZE`. The argv+envp part is limited to `NCARGS`
   (`ARG_MAX` = 1 MiB on these platforms).
3. **Load the image** (`load_machfile`):
   - choose the slides (§2.4);
   - map segments;
   - require the hard `__PAGEZERO` (§2.2);
   - process `LC_MAIN` or `LC_UNIXTHREAD` (stack size and location);
   - load the dynamic linker named by `LC_LOAD_DYLINKER`.
   Release kernels accept **only `/usr/lib/dyld`** as the dynamic linker
   name.
4. **Set the initial thread state** (`activate_exec_state`):
   - zero the whole user register file and the NEON state;
   - set FPCR to 0 and PSTATE to the user default (§1.2);
   - apply the dynamic linker's `LC_UNIXTHREAD` thread state from its file
     (flavor `ARM_THREAD_STATE64`). The main executable's thread state is
     discarded when a dynamic linker is loaded;
   - set PC to the entry point. This is the `pc` from dyld's
     `LC_UNIXTHREAD` plus the dyld slide. The kernel never uses
     `LC_MAIN.entryoff`; dyld reads it.
5. **Create the main stack** (§2.3) and record `user_stack` (the top).
6. **Build the `apple[]` strings** (§1.4). They are appended after the
   argv+envp block and padded with NUL bytes to an 8-byte boundary. The
   main thread's port is inserted into the new task here (`th_port=`).
7. **Copy out the strings and pointer arrays** below `user_stack`, then set
   SP to the `argc` slot (§1.3).
8. **Push the main executable's Mach header address.** When a dynamic
   linker is present, SP is lowered by 8 and the (slid) address of the main
   executable's `mach_header_64` is stored at the new SP.

### 1.2 Initial register state of the first thread

| Register | Value at the first instruction |
|---|---|
| PC | Entry of the dynamic linker: the `pc` in dyld's `LC_UNIXTHREAD` (`ARM_THREAD_STATE64`) plus the dyld slide |
| SP (`SP_EL0`) | Address of the Mach-header slot (§1.3). **Not rounded to 16 bytes**; see the note below |
| x0–x28, fp (x29), lr (x30) | 0, unless dyld's `LC_UNIXTHREAD` state supplies nonzero values. The kernel puts **no arguments in registers**. Everything is passed on the stack |
| PSTATE (SPSR) | `PSR64_USER64_DEFAULT`: EL0t (M = 0b0000, AArch64), DAIF = 0 (interrupts unmasked), NZCV = 0 (or the NZCV bits from the file's thread state). The SSBS bit (bit 12) is also set when the kernel is built with `HAS_ARM_FEAT_SSBS2` |
| FPCR | 0 (`FPCR_DEFAULT`) |
| FPSR, V0–V31 | 0 |
| TPIDRRO_EL0 | **0**. A new thread's `cthread_self` is 0, and exec runs on a new thread. User code sets it with the platform call (§4 of `darwin-trap-tables.md`) |
| TPIDR_EL0 | Owned by the kernel: bits 0–11 = the current CPU number, bits 12–19 = its cluster ID, bit 48 = the "preserve x18" flag (0 for ordinary tasks). It is rewritten on every context switch |

**Note on SP alignment.** The kernel aligns every piece of the string area
and the pointer arrays to 8 bytes. It does not round the final SP to 16
bytes. The final SP is `user_stack − string_size − 8 × (argc + envc +
applec + 3) − 8 − 8`. `SCTLR_EL1.SA0` (the EL0 SP alignment check) is set in
xnu's default `SCTLR_EL1`. The start code of the dynamic linker must
therefore realign SP before it uses SP as a base register.

### 1.3 Initial stack layout (top to bottom)

`user_stack` is the stack top (§2.3). It is 16 KiB-aligned. Addresses
decrease downward in this table. The string area starts **exactly** at
`user_stack`: the xnu comment draws a "16b" area above the string area, but
the code reserves no such gap.

| Region (high → low) | Size | Contents |
|---|---|---|
| String area | `string_size` (a multiple of 8) | The strings, laid out **from low to high address**: (1) `executable_path=<path>` NUL, then NUL padding to 8; (2) argv[0..argc−1] strings, each NUL-terminated; (3) envp[0..envc−1] strings, each NUL-terminated, then NUL padding to 8; (4) the `apple[1..applec−1]` strings in the order of §1.4, each NUL-terminated, then NUL padding to 8. The last byte of the padding is at `user_stack − 1` |
| `apple[]` pointer array | 8 × (applec + 1) | apple[0] → the start of the `executable_path=` string (the key is included), apple[1..applec−1] → the remaining apple strings, then a NULL (8 zero bytes) |
| `envp[]` pointer array | 8 × (envc + 1) | Pointers to the env strings, then NULL |
| `argv[]` pointer array | 8 × (argc + 1) | Pointers to the arg strings, then NULL |
| `argc` | 8 | argc as a 64-bit value |
| Mach-header slot | 8 | The address of the main executable's `mach_header_64`, slid. Present only when a dynamic linker was loaded, which is always the case for normal executables. **SP points here** |

The pointer arrays are contiguous, in this order going **up** from `argc`:
argv, NULL, envp, NULL, apple, NULL. Every pointer is an absolute user
virtual address inside the string area.

As a list from SP upward: `[SP+0]` mach_header, `[SP+8]` argc,
`[SP+16]` argv[0] …, NULL, envp[0] …, NULL, apple[0] …, NULL, then the
strings.

The kernel records `p_argslen` = `user_stack − start of string area` and
`p_argc`. `sysctl(KERN_PROCARGS2)` returns these.

### 1.4 `apple[]` strings that the kernel provides

The table lists them in exact order. Rows that are marked conditional are
omitted when their condition is false. Later entries move up to fill the
gap. Unless the table says otherwise, a hex value is printed as `0x`
followed by lowercase hex digits with no zero padding.

| # | String | Condition | Value format and meaning |
|---|---|---|---|
| 0 | `executable_path=<path>` | always | The path as passed to exec (it can be relative). It is the first string of the string area. apple[0] points here |
| 1 | `pfz=0x<hex>` | always | User VA of the commpage **text** page (§3.4). The 64-bit format is `%llx` |
| 2 | `MallocNanoZone=1` | posix_spawn attribute flag `_POSIX_SPAWN_NANO_ALLOCATOR` | Literal |
| 3 | `stack_guard=0x<hex>` | always | One random 64-bit value. **Bits 8–15 are forced to 0**, so the guard contains a NUL byte |
| 4 | `malloc_entropy=0x<hex>,0x<hex>` | always | Two random 64-bit values |
| 5 | `ptr_munge=0x<hex>` | always | One random 64-bit value. It is the pointer-obfuscation key used by libplatform and libpthread |
| 6 | `main_stack=0x<top>,0x<size>,0x<alloc>,0x<allocsize>` | the image is a "unixproc", that is, it had `LC_MAIN` or `LC_UNIXTHREAD` (normally always) | `user_stack` (the top), the usable stack size (excluding the guard), the base of the allocation, and the allocation size (§2.3) |
| 7 | `executable_file=0x<fsid>,0x<fileid>` | the vnode attributes are available | The file system ID and the file ID (inode) of the executable |
| 8 | `dyld_file=0x<fsid>,0x<fileid>` | the dyld fsid or fileid is nonzero | The same for the dynamic linker file |
| 9 | `executable_cdhash=<40 hex>` | the executable has a code-signature CDHash | The 20-byte CDHash as 40 lowercase hex digits, with no `0x` prefix |
| 10 | `executable_boothash=<40 hex>` | same as #9 | The first 20 bytes of SHA-256 over (a 32-bit boot salt, the 37-byte boot-session UUID string including its NUL, and the 20-byte CDHash), as 40 lowercase hex digits |
| 11 | `dyld_flags=0x<hex>` | DEVELOPMENT or DEBUG kernels only, and the flags are nonzero | Kernel boot-arg flags for dyld |
| 12 | `subsystem_root_path=<path>` | posix_spawn set a subsystem root path | Literal path |
| 13 | `ptrauth_disabled=1` | arm64e kernel, and an arm64e binary is running as arm64 | Literal |
| 14 | `th_port=0x<hex>` | always (exec creates a new thread) | The main thread's Mach port **name** in the new task, as 32-bit hex. It carries one send-right reference that libpthread consumes |
| 15 | `vm_force_4k_pages=1` | macOS with mixed page sizes, and a posix_spawn attribute that forces 4K | Literal |
| 16 | `MallocExperiment=0x<hex>` | the global experiment factor is nonzero | 64-bit flags |
| 17 | `security_config=0x<hex>` | always | The task security configuration (32-bit). It is pushed even when it is 0 |
| 18 | `has_sec_transition=1` then `sec_transition_policy=0x<hex>` | MTE-capable kernels, and the task has security transitions | Literal, then 32-bit policy flags |
| 19 | `HardenedRuntime=0x<hex>` | the load result has hardened-browser or hardened-runtime flags | 32-bit flags |

Not provided by the kernel (searched in `kern_exec.c`, **not found**):
`arm64e_abi`. Any other key that dyld or libSystem reads is added by user
space, not by the kernel.

---

## 2. Default arm64 user address space (Q2)

### 2.1 Page size

| Item | Value |
|---|---|
| User page size, 64-bit arm64 processes | **16 KiB** (shift 14). This is the commpage `USER_PAGE_SHIFT_64` value |
| User page size, 32-bit processes | 16 KiB (`page_shift_user32 = PAGE_MAX_SHIFT = 14`) |
| Kernel page size on Apple silicon | 16 KiB (`KERNEL_PAGE_SHIFT`) |
| `PAGE_MIN_SIZE` / `PAGE_MAX_SIZE` constants | 4 KiB / 16 KiB |
| 4 KiB user maps | Only on macOS with mixed page sizes (`vm_force_4k_pages`, Rosetta). Not used for arm64 simulator code |

### 2.2 `__PAGEZERO`

- A segment at vmaddr 0 with file size 0, nonzero vmsize, and `initprot`
  and `maxprot` both `VM_PROT_NONE` is treated as page zero. It is **not
  mapped**. Instead, the map's minimum address is raised to the end of the
  segment. For PIE executables page zero is *extended* by the slide, not
  moved.
- Every address space must have at least a 4 KiB hard page zero. The only
  exception on arm64 is legacy 32-bit, non-PIE 4K binaries.
- **64-bit arm64 executables must have a hard page zero of at least 4 GiB**
  (`0x1_0000_0000`), or exec fails with `LOAD_BADMACHO`. The exception is a
  macOS task that is entitled to x86-64-style compatibility (soft page
  zero).

### 2.3 Main stack

| Item | Value |
|---|---|
| Default top (`USRSTACK64`) | `0x0000_0001_6FE0_0000` |
| Actual top (`user_stack`) | `USRSTACK64 − slide`, truncated to a page boundary (the stack slides down with the main executable) |
| Allocation size without `LC_MAIN.stacksize` | `MAXSSIZ` = **64 MiB** on macOS (1 MiB on iOS-family kernels) |
| Allocation size with `LC_MAIN.stacksize = S` | S + one page. The usable size is S, and one page is the guard |
| Allocation | `[user_stack − allocsize, user_stack)`, tagged `VM_MEMORY_STACK`. If that range is unavailable, the kernel allocates anywhere and the top moves |
| Usable size (default stack) | `RLIMIT_STACK` current value. The default is `DFLSSIZ` = 8 MiB − 16 KiB = `0x7FC000` on macOS (1 MiB − 16 KiB on iOS-family kernels) |
| Guard | The lowest `allocsize − usable size` bytes (default stack) or the lowest page (custom stack) are set to `VM_PROT_NONE` |

Example (macOS, slide 0, no `LC_MAIN.stacksize`):
`main_stack=0x16fe00000,0x7fc000,0x16be00000,0x4000000`.

### 2.4 ASLR slides (arm64, 16 KiB maps)

| Slide | Range |
|---|---|
| Main executable | `(r1 mod 3) × 32 MiB` + `((r2 mod 1023) + 1) × 16 KiB`. The page part is at most 16 MiB. 32 MiB is the L2 ("twig") block size |
| Dynamic linker | `((r3 mod 255) + 1) × 16 KiB`, at most 4 MiB, independent of the main slide |
| Disabled (`_POSIX_SPAWN_DISABLE_ASLR`) | Both are 0 |

### 2.5 Fixed regions

| Region | Address / size |
|---|---|
| `MACH_VM_MAX_ADDRESS` (user VA limit) | macOS: `0x0000_7FFF_FE00_0000`. iOS-family: `0x0000_000F_C000_0000` (`0x7FFF_FE00_0000` with extended user VA) |
| `VM_MAX_ADDRESS` (`vm_address_t` legacy limit) | `0xF000_0000` |
| Shared region, arm64 | base `0x1_8000_0000`, size `0x1_8000_0000` (it ends at `0x3_0000_0000`). Nesting uses the same base and size |
| Commpage nesting reservation | `[0xF_C000_0000, 0x10_0000_0000)` (1 GiB), reserved in every user map |
| Commpage RW-data page (user read-only) | `0x0000_000F_FFFF_C000` (`_COMM_PAGE64_BASE_ADDRESS`) |
| Commpage RO-data page (user read-only) | `0x0000_000F_FFFF_4000` (`_COMM_PAGE64_RO_ADDRESS`) |
| Commpage text page (user read+execute) | Random page-aligned VA in the same L3 table (32 MiB block `0xF_FE00_0000`–`0xF_FFFF_FFFF`) as the data page, never equal to either data page. On macOS with mixed page sizes it is limited to the 2 MiB block `0xF_FFE0_0000`–`0xF_FFFF_FFFF`. Its address is passed in `pfz=` |
| GPU carve-out constants | `0x10_0000_0000`–`0x70_0000_0000` |

User-visible protections: both data pages are mapped read-only and
non-executable at EL0. The text page is mapped read-only and executable at
EL0, and non-executable at EL1.

---

## 3. The arm64 commpage (Q3)

### 3.1 Layout version: simulator binaries read the *legacy* offsets

`cpu_capabilities.h` defines `_COMM_PAGE_LAYOUT_VERSION`. The kernel uses
1. Device user space uses 1. **Simulator builds (`TARGET_OS_SIMULATOR`) use
0**, because simulator platform libraries must run on older host kernels.
At version 0, the four fields that have RO-page copies (`USER_PAGE_SHIFT_32`,
`USER_PAGE_SHIFT_64`, `KERNEL_PAGE_SHIFT`, `DEV_FIRM`) are read from their
**legacy RW-page** offsets. The kernel fills both copies. Ycode should fill
both.

### 3.2 RW-data page, base `0xF_FFFF_C000` (user read-only)

"Init" is the value the kernel writes in `commpage_populate`. "Updated"
means that the kernel rewrites the field while the system runs. Reader
markings come from libsyscall in xnu (`libsyscall/…`). "startup" means
`mach_init`/`__libkernel_init`, which run during libSystem initialization in
every process.

| Off | Name (`_COMM_PAGE_…`) | Size | Meaning | Kernel fill | Known libsyscall reader |
|---|---|---|---|---|---|
| 0x000 | `SIGNATURE` | 16 | Signature | ASCII `commpage 64-bit` (15 bytes), byte 0x00F = 0 | — |
| 0x010 | `CPU_CAPABILITIES64` | 8 | 64-bit capability bitmask (§3.5) | Init | `_get_cpu_capabilities` |
| 0x018 | `UNUSED` | 6 | unused | 0 | — |
| 0x01E | `VERSION` | 2 | Commpage format version | **3** | (x86 only, for page shift) |
| 0x020 | `CPU_CAPABILITIES` | 4 | Low 32 bits of the capabilities | Init | 32-bit `_get_cpu_capabilities` |
| 0x022 | `NCPUS` | 1 | Configured CPUs. This is byte 2 of 0x020 (the `kNumCPUs` field, bits 16–23) | via 0x020 | — |
| 0x024 | `USER_PAGE_SHIFT_32_LEGACY` | 1 | Page shift for 32-bit tasks | 14 | startup (32-bit only) |
| 0x025 | `USER_PAGE_SHIFT_64_LEGACY` | 1 | Page shift for 64-bit tasks | **14** | **startup**: `mach_init` sets `vm_page_size` from it |
| 0x026 | `CACHE_LINESIZE` | 2 | Cache line size in bytes | 32, 64, or 128 from the capability bits, else 0 | — |
| 0x028 | `UNUSED4` | 4 | formerly the scheduler generation | 0 | — |
| 0x02C | `UNUSED3` | 3 | formerly the spin count | 0 | — |
| 0x02F | `CPU_CLUSTERS` | 1 | Number of CPU clusters | Init | — |
| 0x030 | `MEMORY_PRESSURE` | 4 | Copy of the VM memory pressure | Updated periodically | — |
| 0x034 | `ACTIVE_CPUS` | 1 | Active CPUs (`hw.activecpu`) | Updated when a CPU goes online or offline | — |
| 0x035 | `PHYSICAL_CPUS` | 1 | `hw.physicalcpu_max` | Init | — |
| 0x036 | `LOGICAL_CPUS` | 1 | `hw.logicalcpu_max` | Init | — |
| 0x037 | `KERNEL_PAGE_SHIFT_LEGACY` | 1 | Kernel VM page shift | **14** on Apple silicon | **startup**: `mach_init` sets `vm_kernel_page_size` from it |
| 0x038 | `MEMORY_SIZE` | 8 | Maximum memory size in bytes | Init (`max_mem`) | — |
| 0x040 | `TIMEOFDAY_DATA` | 40 (reserved to 0x07F) | Legacy gettimeofday block (old layout) | **not written on arm**. It stays 0 | — |
| 0x080 | `CPUFAMILY` | 4 | CPU family ID (`CPUFAMILY_*` from `mach/machine.h`). The `memcpy` resolver uses it | Init | — |
| 0x084 | `DEV_FIRM_LEGACY` | 4 | Debugger allowed (`PE_i_can_has_debugger`) | Init | — |
| 0x088 | `TIMEBASE_OFFSET` | 8 | Added to the counter to form `mach_absolute_time` | Init; **updated** after sleep/wake | `mach_absolute_time` (user path) |
| 0x090 | `USER_TIMEBASE` | 1 | User timebase mode: 0 NONE, 1 SPEC (`CNTVCT_EL0` after `isb`), 2 NOSPEC (`CNTVCTSS_EL0`), 3 NOSPEC_APPLE (`ACNTVCT_EL0` = `S3_4_C15_C10_6`) | Init: 3 on Apple cores with `ACNTVCT`, otherwise by architecture | `mach_absolute_time`, `mach_continuous_time` |
| 0x091 | `CONT_HWCLOCK` | 1 | 1 if EL0 may read a continuous (always-on) hardware counter | Init | `mach_continuous_time` |
| 0x092 | `DTRACE_DOF_ENABLED` | 1 | User DOF enabled | Updated by DTrace | — |
| 0x093 | `UNUSED0` | 5 | unused | 0 | — |
| 0x098 | `CONT_TIMEBASE` | 8 | Total sleep time (abs units). continuous = absolute + this | Init 0; updated on wake | `mach_continuous_time`, `mach_continuous_approximate_time`, kdebug |
| 0x0A0 | `BOOTTIME_USEC` | 8 | Boot time, µs since the epoch | Init; updated when the clock is set | `mach_boottime_usec` |
| 0x0A8 | `CONT_HW_TIMEBASE` | 8 | continuous = counter + this (when `CONT_HWCLOCK` = 1) | Updated | `mach_continuous_time` |
| 0x0B0 | — | 16 | unnamed | 0 | — |
| 0x0C0 | `APPROX_TIME` | 8 | Last known `mach_absolute_time` (monotonic, updated by the scheduler) | Init 0; updated | `mach_approximate_time` |
| 0x0C8 | `APPROX_TIME_SUPPORTED` | 1 | 1 if 0x0C0 is maintained | 1 when `CONFIG_MACH_APPROXIMATE_TIME` (set on arm64) | `mach_approximate_time` |
| 0x0C9 | — | 16 | unnamed | 0 | — |
| 0x0D9 | `UNUSED1` | 39 | padding to the next cache line | 0 | — |
| 0x100 | `KDEBUG_ENABLE` | 4 | kdebug state bits (tracing on, typefilter, continuous-time timestamps) | Updated | `kdebug_trace*` |
| 0x104 | `ATM_DIAGNOSTIC_CONFIG` | 4 | `atm_diagnostic_config` | Init/updated | `host_get_atm_diagnostic_flag` |
| 0x108 | `MULTIUSER_CONFIG` | 4 | bit 31 multi-user device, bit 30 has secondary users, bits 0–29 current user UID | Updated | `host_get_multiuser_config_flags` |
| 0x10C | — | 20 | unnamed | 0 | — |
| 0x120 | `NEWTIMEOFDAY_DATA` | 40 | gettimeofday block: five u64 at +0 `TimeStamp_tick`, +8 `TimeStamp_sec`, +16 `TimeStamp_frac`, +24 `Ticks_scale`, +32 `Ticks_per_sec` | Init all 0; updated when the calendar clock changes (§3.6) | `__commpage_gettimeofday` |
| 0x148 | `REMOTETIME_PARAMS` | 24 | `bt_params`: +0 `rate` (double), +8 `base_local_ts`, +16 `base_remote_ts` | Init: the first 8 bytes = `0xFFFF_FFFF_FFFF_FFFC` (reset sentinel) | `mach_bridge_remote_time` |
| 0x160 | `DYLD_FLAGS` | 8 | `kern.dyld_system_flags` | Updated by sysctl | (dyld, outside xnu) |
| 0x168 | — | 24 | unnamed | 0 | — |
| 0x180 | `CPU_QUIESCENT_COUNTER` | 8 (128 reserved) | Kernel quiescent-state counter | Kernel-maintained | — |
| 0x200 | `CPU_TO_CLUSTER` | 256 | One byte per logical CPU ID: the cluster ID | Init | — |
| 0x300 | — | 32 | unnamed | 0 | — |
| 0x320 | `ASB_TARGET_VALUE` | 8 | Security-bounty canary value | Random choice from a fixed list | — |
| 0x328 | `ASB_TARGET_ADDRESS` | 8 | Canary address above the user VA limit | Random | — |
| 0x330 | `ASB_TARGET_KERN_VALUE` | 8 | Kernel canary value | Random | — |
| 0x338 | `ASB_TARGET_KERN_ADDRESS` | 8 | Kernel canary address | Random | — |
| 0x340 | `APT_MSG_POLICY` | 1 | APT message policy | Init | — |
| 0x341 | `APT_ACTIVE` | 1 | APT active | Updated | — |
| 0x342 | `SECURITY_RESEARCH_DEVICE_ERM_ACTIVE` | 1 | Extended Research Mode active | Init (boot only) | — |
| 0x343–0xFFF | — | — | unused (`_COMM_PAGE_END` = 0xFFF) | 0 | — |

Counts: **47 named fields** on the RW page (including the `UNUSED*` names
and `NCPUS`), 4 fields on the RO page, and 3 text-page offsets.

### 3.3 RO-data page, base `0xF_FFFF_4000` (user read-only)

These are the same offsets as their legacy twins. They are read by
layout-version-1 (non-simulator) binaries.

| Off | Name | Size | Value |
|---|---|---|---|
| 0x024 | `USER_PAGE_SHIFT_32` | 1 | 14 |
| 0x025 | `USER_PAGE_SHIFT_64` | 1 | 14 |
| 0x037 | `KERNEL_PAGE_SHIFT` | 1 | 14 |
| 0x084 | `DEV_FIRM` | 4 | debugger allowed |

### 3.4 Text page (preemption-free zone, "PFZ")

The text page holds a jump table at its start. libsystem_kernel finds the
page through `apple[]` `pfz=` at startup (`__libkernel_init`). The page
contains Apple code, so Ycode must write its own code with the same
behavior.

| Offset | Entry | Behavior |
|---|---|---|
| 0x0 | `TEXT_ATOMIC_ENQUEUE` | `OSAtomicFifoEnqueue`: enqueue on a FIFO list head {first, last, spinlock (int)} |
| 0x4 | `TEXT_ATOMIC_DEQUEUE` | `OSAtomicFifoDequeue` |
| 0x8 | `TEXT_ATOMIC_TPIDR_EL0` | Atomically update `TPIDR_EL0` (libsystem stores this address as `update_tpidr`) |

The kernel fills the rest of the page with the `brk #666` encoding
(`0xD4205340`). If an asynchronous interrupt arrives while the PC is in the
PFZ half, the kernel does not preempt the thread. It marks `x15` instead,
and the code later enters the kernel through Mach trap −58 `pfz_exit` to
take the delayed preemption. A single-vCPU VMM without asynchronous
preemption can implement these entry points as plain (non-preemptible)
routines.

### 3.5 Capability bits (`CPU_CAPABILITIES64`)

| Bit(s) | Name | Set when |
|---|---|---|
| 0x8 | `kHasFeatFP16` | AdvSIMD has FP16 (ID_AA64PFR0) |
| 0x10 / 0x20 / 0x40 | `kCache32` / `kCache64` / `kCache128` | Cache line size |
| 0x80 | `kFastThreadLocalStorage` | **always** (TLS is in TPIDRRO_EL0) |
| 0x100 | `kHasAdvSIMD` | AdvSIMD present |
| 0x200 | `kHasAdvSIMD_HPFPCvt` | AdvSIMD half-precision conversion |
| 0x400 | `kHasVfp` | **always** |
| 0x800 | `kHasUCNormalMemory` | `HAS_UCNORMAL_MEM` |
| 0x1000 | `kHasEvent` | **always** |
| 0x2000 | `kHasFMA` | **always** on arm64 |
| 0x4000 | `kHasFeatFHM` | FEAT_FHM |
| 0x8000 | `kUP` | exactly one CPU |
| 0x00FF_0000 | `kNumCPUs` | CPU count (max 255), shift 16 |
| 0x0100_0000 | `kHasARMv8Crypto` | crypto extensions (AES, SHA1, SHA256, PMULL) |
| 0x0200_0000 | `kHasFeatLSE` | FEAT_LSE atomics |
| 0x0400_0000 | `kHasARMv8Crc32` | CRC32 |
| 0x8000_0000 | `kHasFeatSHA512` | SHA512 |
| 1<<32 | `kHasFeatSHA3` | SHA3 |
| 1<<33 | `kHasFeatFCMA` | FCMA |
| 1<<34 | `kHasFeatAFP` | AFP |
| 1<<40 | `kHasFEATFlagM` | FlagM |
| 1<<41 | `kHasFEATFlagM2` | FlagM2 |
| 1<<42 | `kHasFeatDotProd` | DotProd |
| 1<<43 | `kHasFeatRDM` | RDM |
| 1<<44 | `kHasFeatSPECRES` | SPECRES (and `SCTLR.EnRCTX`) |
| 1<<45 | `kHasFeatSB` | SB |
| 1<<46 | `kHasFeatFRINTTS` | FRINTTS |
| 1<<47 | `kHasArmv8GPI` | GPI (implementation-defined PAC) |
| 1<<48 | `kHasFeatLRCPC` | LRCPC |
| 1<<49 | `kHasFeatLRCPC2` | LRCPC2 |
| 1<<50 | `kHasFeatJSCVT` | JSCVT |
| 1<<51 | `kHasFeatPAuth` | PAuth |
| 1<<52 | `kHasFeatDPB` | DPB |
| 1<<53 | `kHasFeatDPB2` | DPB2 |
| 1<<54 | `kHasFeatLSE2` | LSE2 (ID_AA64MMFR2.AT) |
| 1<<55 | `kHasFeatCSV2` | CSV2 |
| 1<<56 | `kHasFeatCSV3` | CSV3 |
| 1<<57 | `kHasFeatDIT` | DIT |
| 1<<58 | `kHasFP_SyncExceptions` | all six FPCR trap-enable bits can be set |
| 1<<59 / 1<<60 / 1<<61 | `kHasFeatSME` / `SME2` / `SME2p1` | SME version |

The kernel derives every optional bit from the ID registers
`ID_AA64ISAR0/1`, `MMFR1/2`, `PFR0/1`, and from an FPCR probe. The bits
that are always set are listed in the table.

### 3.6 Timekeeping fields and their invariants

- **`mach_absolute_time`** (user path, when `USER_TIMEBASE` ≠ 0) = counter
  (the register selected by 0x090) + `TIMEBASE_OFFSET` (0x088). The
  offset is read before and after the counter read, and the read is retried
  if the two values differ. When `USER_TIMEBASE` = 0, libsyscall makes
  trap −3 instead.
- **`mach_continuous_time`**:
  - if `CONT_HWCLOCK` = 1, the result is counter + `CONT_HW_TIMEBASE`
    (0x0A8);
  - otherwise it is `mach_absolute_time()` + `CONT_TIMEBASE` (0x098), with
    a retry loop on 0x098.
- **`mach_approximate_time`**: `APPROX_TIME` (0x0C0) if
  `APPROX_TIME_SUPPORTED` (0x0C8) is set, otherwise `mach_absolute_time()`.
- **gettimeofday fast path** (`NEWTIMEOFDAY_DATA`, 0x120):
  - `TimeStamp_tick` is the abs time of the snapshot. 0 means "invalid",
    and the caller falls back to the `gettimeofday` system call (BSD 116).
  - `TimeStamp_sec` and `TimeStamp_frac` are the calendar time at the
    snapshot (frac = a 64-bit binary fraction of a second).
  - `Ticks_per_sec` is the timebase frequency.
  - `Ticks_scale` = ⌊2^63 / Ticks_per_sec⌋ × 2 (2^64 / frequency, with no
    NTP adjustment).
  - The reader uses the snapshot only if `now − TimeStamp_tick <
    Ticks_per_sec`. Otherwise it makes the system call.
  - The writer stores `TimeStamp_tick` = 0, then a barrier, then the other
    four fields, then a barrier, then the real `TimeStamp_tick`. The reader
    retries if `TimeStamp_tick` changed during its reads.
- **`BOOTTIME_USEC`** (0x0A0) = boot time in microseconds since the Unix
  epoch.

---

## 4. Trap-number decoding and return conventions (Q4 summary, Q5)

The full tables are in `darwin-trap-tables.md` and the JSON files. The
following rules matter for the dispatcher:

- The trap number is the **low 32 bits of x16, read as a signed int**.
- **`0x8000_0000`** is the platform call (sub-selector in **x3**, see
  `darwin-trap-tables.md` §4). It is checked before anything else.
- **−3 / −4** are the fast traps (below). They are checked before the Mach
  table.
- **Other negative numbers** index the Mach trap table at −x16.
  - An index ≥ 128, or a slot whose handler is `kern_invalid`, raises the
    Mach exception **`EXC_SYSCALL`** with code = the trap index. It does not
    return an error. Without a handler, that becomes **SIGSYS**.
  - Arguments are copied from x0… in `arg_count` 64-bit slots.
  - The result (`kern_return_t`, or a port name for the port-returning
    traps) goes in **x0**. Carry is not touched.
- **Positive numbers or 0** are BSD calls.
  - The call number is the **low 16 bits** of x16.
  - **x16 = 0 is the indirect call** (`syscall(2)`): the number comes from
    x0, and the arguments start at x1.
  - Numbers ≥ `nsysent` (558) are treated as slot 63 (`nosys`).
  - Up to 8 arguments are taken from x0–x7 (x1–x8 for an indirect call).
  - Carry (PSTATE.C, SPSR bit 29) is cleared before the call.
  - **Success:** the result is written by return type:
    - `int`: x0 = rval[0], x1 = rval[1];
    - `u_int`, `uint32_t`, `mach_port_name_t`: x0 and x1 are zero-extended
      32-bit values;
    - `user_addr_t`, `user_size_t`, `user_ssize_t`, `off_t`, `uint64_t`:
      x0 = the 64-bit value, x1 = 0;
    - `void`: no change.
  - **Error:** x0 = errno, x1 = 0, carry set.
  - **`ERESTART`:** PC is moved back 4 bytes (the `svc` is re-executed).
  - **`EJUSTRETURN`:** registers are left as the handler set them.
  - A `nosys` slot sends **SIGSYS** to the thread and returns `ENOSYS`.
    An `enosys` slot only returns `ENOSYS`.

**Fast traps.**

| x16 | Result | Other effects |
|---|---|---|
| −3 (`MACH_ARM_TRAP_ABSTIME`) | x0 = `mach_absolute_time()` = hardware counter + per-CPU base offset (the same value that the user path produces from the commpage) | None. Only x0 is written. Carry and x1–x30 are unchanged |
| −4 (`MACH_ARM_TRAP_CONTTIME`) | x0 = `mach_continuous_time()` (= absolute + accumulated sleep time) | Same |

`mach_timebase_info` is **Mach trap −89** (`mach_timebase_info_trap`, 1
argument: a user pointer). It copies out `{u32 numer, u32 denom}` and
returns `KERN_SUCCESS`. libsyscall caches the result on first use.

**Apple-silicon values.** The kernel computes numer/denom from the device's
timebase frequency F (and a divisor d of 1–4) as `numer = d × 10^9`,
`denom = F`, reduced by their GCD. The frequency itself comes from the
device tree. **The value "24 MHz" is not stated in the xnu source (not
found).** For F = 24 000 000 and d = 1 the formula gives **125/3**, which
matches the stage-2 VMM's choice.

---

## 5. Implications for Ycode (stage 3)

What the VMM must build for each new guest process. This is Ycode's design.
The Darwin facts it relies on are above.

**Address space.**

1. Map the executable's segments at their vmaddr plus a slide. The slide
   may be 0, or chosen by the rules in §2.4. Do not map `__PAGEZERO`. Keep
   `[0, 4 GiB + slide)` unmapped, and fail the launch if the image has no
   4 GiB hard page zero. The EL1 shim's identity-mapped region (below 4 GiB)
   stays inside page zero, as the stage-2 contract already requires.
2. Map the stack: allocate `[top − 64 MiB, top)` with `top = 0x1_6FE0_0000 −
   slide`. Leave the low `64 MiB − 0x7FC000` unmapped or inaccessible as
   the guard. If `LC_MAIN.stacksize` is S, allocate S + 16 KiB instead,
   with a 16 KiB guard.
3. Map three commpage pages, each 16 KiB:
   - RW-data page at `0xF_FFFF_C000`, EL0 read-only, XN;
   - RO-data page at `0xF_FFFF_4000`, EL0 read-only, XN;
   - a text page (Ycode's own PFZ routines, §3.4) at a fixed Ycode-chosen
     VA inside `0xF_FFE0_0000`–`0xF_FFFF_FFFF` that is not one of the two
     data pages, EL0 read+execute.
   Keep `[0xF_C000_0000, 0x10_0000_0000)` free of other mappings.
4. The shared cache goes in the shared region (`0x1_8000_0000`–
   `0x3_0000_0000`). The iOS 27.1 simulator cache prefers `0x1_C000_0000`,
   which is inside that range.

**Initial stack bytes.** Build them exactly as §1.3 describes. Starting at
`top`:

1. Lay out the string area as one buffer: `executable_path=<guest path>`
   NUL, pad to 8; the argv strings; the envp strings, pad to 8; the apple
   strings, pad to 8. Place it so that it ends at `top`.
2. Below it, write the apple pointer array plus NULL, then the envp
   pointers plus NULL, then the argv pointers plus NULL. These are placed
   in reverse order so that argv is lowest.
3. Write argc (u64).
4. Write the main executable's slid `mach_header_64` address (u64).
5. Set SP to that last slot. Do not round it.

The minimum apple set to provide, in this order:

| String | Ycode value |
|---|---|
| `executable_path=` | The guest path |
| `pfz=` | The text page VA |
| `stack_guard=` | Random, with bits 8–15 cleared |
| `malloc_entropy=` | 2 random values |
| `ptr_munge=` | Random |
| `main_stack=` | top, usable size, alloc base, alloc size |
| `executable_file=` | Optional. Any stable fsid,fileid |
| `executable_cdhash=` / `executable_boothash=` | Only if a CDHash is known. Omit otherwise |
| `th_port=` | The guest name of the main-thread port. Ycode's Mach layer must create this name with one send right |
| `security_config=` | `0x0` |

**Registers.**

- PC = the entry of the program that Ycode starts first;
- SP = the value from step 5 above;
- x0–x30 = 0;
- SPSR = `0x0` (EL0t, DAIF clear). This is **different from the stage-2
  value `0x3C0`**, which masks DAIF. Keep `0x3C0` only while the shim has
  no interrupt handling;
- FPCR = 0;
- TPIDRRO_EL0 = 0. The guest sets it with platform call 2;
- TPIDR_EL0 = the vCPU number (cluster 0).

**Commpage fill.** The simulator reads the legacy RW offsets (§3.1). Fill
both copies of each duplicated field.

| Field | Value for Ycode |
|---|---|
| 0x000 signature | `commpage 64-bit` |
| 0x01E version | 3 |
| 0x010 / 0x020 capabilities | `kFastThreadLocalStorage` \| `kHasVfp` \| `kHasEvent` \| `kHasFMA` \| (nCPU << 16) \| (`kUP` if one vCPU) \| the cache-line bit, plus **only** the optional bits the guest vCPU really has. Derive them from the guest's ID registers, which KVM exposes. Never set PAuth, SME, or MTE bits unless they are exposed |
| 0x022 (via 0x020) | nCPU |
| 0x024, 0x025, 0x037 (and RO 0x024, 0x025, 0x037) | 14, 14, 14 |
| 0x026 | Cache line size (for example 64) |
| 0x02F, 0x034, 0x035, 0x036 | 1 cluster, nCPU, nCPU, nCPU |
| 0x038 | Guest RAM size |
| 0x080 | `CPUFAMILY_UNKNOWN` (0), unless a specific family is needed (open question) |
| 0x084 (and RO 0x084) | 0 |
| 0x088 / 0x090 / 0x091 | Choose one timebase mode (below) |
| 0x098, 0x0A8 | 0 (no sleep) |
| 0x0A0 | Host boot time in µs, or VMM start time |
| 0x0C0 / 0x0C8 | 0 / 0. `mach_approximate_time` then falls back to `mach_absolute_time` |
| 0x100, 0x104, 0x108, 0x160 | 0 |
| 0x120 block | All 0 at first. `gettimeofday` then uses BSD 116. Later, fill it as in §3.6 to avoid traps |
| 0x148 | first 8 bytes `0xFFFF_FFFF_FFFF_FFFC` |
| 0x200 | One 0 byte per vCPU |
| others | 0 |

**Guest CPU count (nCPU; speed work 2026-10-17).** The guest is told one
CPU count, N, everywhere it can read one, so that every consumer sizes its
thread pools alike. N is the launcher setting `YCODE_GUEST_CPUS` (1…64)
when set, otherwise **1** (measured default, below). N does not depend on how many
vCPUs an image has (Ycode gives every guest thread its own vCPU). With N:

- commpage: `NCPUS` (0x022, the `kNumCPUs` field of the capabilities),
  `ACTIVE_CPUS`, `PHYSICAL_CPUS`, `LOGICAL_CPUS` = N; `kUP` only when N = 1;
  `CPU_CLUSTERS` = 1; `cpu_to_cluster` = N zero bytes;
- sysctl: `hw.ncpu`, `hw.activecpu`, `hw.availcpu`, `hw.logicalcpu`,
  `hw.logicalcpu_max`, `hw.physicalcpu`, `hw.physicalcpu_max` = N;
  `hw.nperflevels` = 1 and `hw.perflevel0.logicalcpu`,
  `hw.perflevel0.logicalcpu_max`, `hw.perflevel0.physicalcpu`,
  `hw.perflevel0.physicalcpu_max` = N;
- workqueue: the constrained parallelism per QoS, the cooperative pool
  width (`threads-and-events.md` §2.5) and the `QOS_MAX_PARALLELISM` answer
  (`bsdthread_ctl` 0x800) = N;
- CPU numbers: a thread's TPIDR_EL0 (its CPU number) is its vCPU index
  modulo N, so it is always below N.

Why: until 2026-10-17 the commpage and the sysctls said 1 CPU (with `kUP`)
while the workqueue admitted 8 constrained threads per QoS and
`QOS_MAX_PARALLELISM` answered 8. libdispatch reads its CPU counts from the
commpage and from these sysctls, and sizes the cooperative pool that Swift
concurrency runs on to one thread per CPU, so every guest process had a
single Swift-concurrency thread.

Why the default is 1 (measured 2026-10-17, full boots on the Thor, SX
harness, device in tmpfs, 700 s, interleaved with other agents' boots):
with the cooperative pool and the 8 → N change, N = 14 (the Thor's online
CPUs) reached the home screen at 415/405/430/390 s, N = 1 at 355/385/320 s;
with the 24 MHz guest timebase (below) N = 14 and N = 1 were alike
(300 s and 310 s, one run each; the remaining runs were stopped when the
data drive filled). In those builds N = 14 also made fileindexerd fail its
start in a loop ("Failed to init after preparing dependencies",
NSPOSIXErrorDomain 19; 15–47 crashes per boot) while at N = 1 it still
waited for searchd. That crash is not caused by N: once searchd runs (the
renameatx_np fix) fileindexerd crashes the same way at N = 1, because Ycode
has no host `com.apple.FSEvents` service (`service-fidelity.md`).
On the integrated build (speed-int fb1a4d6 with fast traps, the HVC
doorbell and the 24 MHz timebase; two boots at a time) N = 1 reached the
home screen at 240/285/270 s with the kernel lock busy 23–29 % of the run,
N = 14 at 245/295/285 s with 30–35 %. More admitted workers did not shorten
the boot: Ycode's kernel lock serializes the traps they make. Larger N stays
available through `YCODE_GUEST_CPUS` for experiments.

Evidence: level 1. The commpage fields are from xnu
(`osfmk/arm/cpu_capabilities.h`, `osfmk/arm/commpage/commpage.c`); the
sysctl names from xnu (`bsd/kern/kern_mib.c`); libdispatch's use of them
from libdispatch (`src/shims/hw_config.h`: `_dispatch_hw_get_config`, which
reads the commpage CPU counts and `hw.activecpu`/`hw.logicalcpu_max`/
`hw.physicalcpu`); the cooperative width from libdispatch's cooperative root
queues and xnu `bsd/pthread/workqueue_internal.h`. The value of N is Ycode's
choice. The default N = 1 is level 3: the boot times and crash counts
above (Ycode boots on the Thor, exit summaries).

**Timebase mode.** The value 3 (`ACNTVCT_EL0`) must **not** be used: that
register is Apple-specific and is UNDEFINED on the Thor. Choose one of:

- **Mode A (trap-based, simplest, consistent with stage 2):**
  `USER_TIMEBASE` = 0, `CONT_HWCLOCK` = 0. `mach_absolute_time` always makes
  trap −3, which returns 24 MHz ticks, and trap −89 must return 125/3. The
  cost is one VM exit per time read (about 32 µs measured in stage 2).
- **Mode B (fast):** `USER_TIMEBASE` = 1 (`CNTVCT_EL0` after `isb`).
  - The shim must allow EL0 counter reads (`CNTKCTL_EL1.EL0VCTEN`).
  - `TIMEBASE_OFFSET` is set so that counter + offset gives the desired
    epoch.
  - Trap −3 must return the same counter + offset.
  - Trap −89 must return `10^9 / CNTFRQ_EL0`, reduced. On Armv8.6+ cores
    the frequency is 1 GHz, so this is 1/1.
  - The value 2 (`CNTVCTSS_EL0`) is allowed only if the guest has
    FEAT_ECV.

**Guest timebase (Ycode's choice since 2026-10-17): Mode A semantics, 24
MHz.** The guest's mach time runs at Apple's arm64 timebase, 24 MHz
(`mach_timebase_info` = 125/3), whatever the host counter's frequency:

- traps −3 and −4 return the VM's aligned host counter scaled to 24 MHz
  with the fixed-point clock scale of `fast-traps.md` §3.2 (≈ counter ×
  24 000 000 / `CNTFRQ_EL0`; on the Thor, 1 GHz: ≈ × 3/125); with the fast
  traps on (the default) Ycode's library computes the same value at EL0
  from `CNTVCT_EL0` and the scale the commpage publishes;
- trap −89 returns 125/3;
- the commpage says `USER_TIMEBASE` = 0 (no user timebase), so code that
  reads the commpage (libsyscall's `mach_absolute_time.s`,
  `kdebug_trace.c`) takes the trap instead of reading `CNTVCT_EL0`, which
  stays at the host frequency; Ycode's own `libsystem_kernel` traps, or
  (fast traps) reads the counter only through the scale;
- every mach-tick value the kernel takes or gives (mach_wait_until,
  mk_timer, `NOTE_MACHTIME` and absolute kevent timers, ulock deadlines,
  process start/exit times, the `gettimeofday` mach-time out-parameter, the
  commpage wall-clock snapshot) uses the same 24 MHz ticks, because the kernel converts with its one
  counter and frequency.

The launcher setting `YCODE_GUEST_TIMEBASE=host` restores Mode B (the host
counter as is, 10⁹/`CNTFRQ_EL0`, `USER_TIMEBASE` = 1).

Why: Swift Concurrency on Apple arm64 does not ask for the timebase. It
converts a task deadline from nanoseconds to mach ticks with the fixed
ratio 3/125 (its source states that Apple arm platforms use a fixed
125/3 timebase), then hands the tick value to `dispatch_after` or a dispatch timer
with the monotonic (continuous) flag; libdispatch compares it with
`mach_continuous_time`. On a 1 GHz guest counter the deadline is about
1/42 of the current tick count, always in the past, so every
`Task.sleep(for:)` and `Task.sleep(until:)` fires at once. A Swift task that
sleeps in a loop then spins: each round reads the continuous clock, enqueues
its job on the cooperative root queue (`QUEUE_REQTHREADS2`), and the worker
returns (`THREAD_RETURN`). That is the suggestd/parsecd/axassetsd pattern
(about 1000 rounds a second per thread; `threads-and-events.md` §2.5).
libdispatch's own `dispatch_time` converts with `mach_timebase_info` and is
correct with either timebase.

**Traps.** Follow §4 exactly:

- the carry rules, the x1 rules, and `ERESTART`;
- the indirect call through x16 = 0;
- the 16-bit BSD number;
- SIGSYS for `nosys` slots;
- `EXC_SYSCALL` for invalid Mach traps (until signals exist, treat it as a
  fatal guest error, not a return of 1);
- the platform call sub-selectors in x3.

---

## 6. Open questions

1. **Which program runs first.** The kernel always starts `/usr/lib/dyld`,
   the host dyld, which is not part of the simulator runtime. On macOS the
   host dyld loads `dyld_sim` from the runtime. Ycode must either start
   `dyld_sim` directly, with whatever interface the host dyld gives it, or
   provide a minimal loader of its own. That interface is not in xnu. It
   needs a separate spec (dyld open source, level 1).
2. **SP alignment at entry.** xnu does not align SP to 16 bytes (§1.2).
   Confirm from dyld's open-source start code that it realigns before using
   SP. If it does not, Ycode should add padding.
3. **Extra `apple[]` keys** that the host dyld adds before it calls
   `dyld_sim` (for example the simulator-specific keys). Not in xnu.
4. **Commpage fields the iOS 27.1 runtime reads.** libsyscall's startup
   reads are known (0x025, 0x037, the `pfz=` key, and the time fields on
   demand). Reads by other runtime libraries (libplatform, libpthread,
   libmalloc, dyld's `DYLD_FLAGS`, the `memcpy` resolver's `CPUFAMILY`) are
   not in xnu. Black-box tracing (level 3) would find them.
5. The `update_tpidr` default when `pfz=` is absent, and whether simulator
   libsystem_kernel calls the PFZ text at all. Not determinable from xnu.
6. The capability bits and `CPUFAMILY` that `memcpy`/`memset` resolvers in
   the simulator libsystem need to choose safe code paths on a non-Apple
   core.

---

## Evidence

All entries are level 1 (Apple open source). Tag `xnu-12377.121.6`, commit
`ac9718fb1af618d5ce8678d0dc6e8a58f252216f`, fetched with the GitHub API from
`apple-oss-distributions/xnu` on 2026-10-11 into a scratch directory outside
the repository.

| Claim | Source |
|---|---|
| Exec sequence, string area, pointer arrays, argc slot, mach_header push, `apple[]` keys and order, entropy formats, stack creation and guard | `bsd/kern/kern_exec.c` (`exec_save_path`, `exec_extract_strings`, `exec_add_apple_strings`, `exec_add_entropy_key`, `exec_copyout_strings`, `exec_mach_imgact`, `activate_exec_state`, `create_unix_stack`) |
| Dyld path restriction, dyld thread state replaces the app's, `LC_MAIN`/`LC_UNIXTHREAD` stack handling, page-zero rules, slides | `bsd/kern/mach_loader.c` (`load_machfile`, `parse_machfile`, `load_segment`, `load_main`, `load_unixthread`, `load_threadstate`, `load_dylinker`) |
| Register initialization, PSTATE default, SP/PC setters | `osfmk/arm64/status.c` (`machine_thread_state_initialize`, `thread_setuserstack`, `thread_adjuserstack`, `thread_setentrypoint`, `thread_userstack`), `osfmk/arm64/proc_reg.h` (`PSR64_*`, `FPCR_DEFAULT`, `SCTLR_EL1_DEFAULT` incl. SA0) |
| TPIDRRO_EL0 = 0 at thread creation; TSD base setter; TPIDR_EL0 contents | `osfmk/arm64/pcb.c` (`machine_thread_create`, `machine_thread_set_tsd_base`, `machine_switch_cpu_data`), `osfmk/arm64/machine_machdep.h`, `osfmk/arm/machdep_call.c` |
| `USRSTACK64`, `MAXSSIZ`, `DFLSSIZ` | `bsd/arm/vmparam.h` |
| VM limits, page sizes, GPU carve-out, `SWI_SYSCALL` = 0x80 | `osfmk/mach/arm/vm_param.h` |
| ASLR ranges | `osfmk/vm/vm_map.c` (`vm_map_get_max_aslr_slide_pages`, `…_loader_…`, `…_section`) |
| Shared region base/size | `osfmk/mach/shared_region.h` |
| Commpage offsets, layout versions, capability bits | `osfmk/arm/cpu_capabilities.h`, `osfmk/arm/cpu_capabilities_public.h`, `bsd/sys/commpage_private.h` |
| Commpage fill values and update paths | `osfmk/arm/commpage/commpage.c`, `osfmk/arm/arm_init.c` (`page_shift_user32`), `osfmk/arm64/machine_routines.c` (`user_timebase_type`, `user_cont_hwclock_allowed`, `ml_map_cpus_to_clusters`, `ml_get_timebase`), `osfmk/kern/clock.c` (tick scale), `osfmk/kern/remote_time.h`, `libsyscall/wrappers/mach_bridge_remote_time.c` (sentinel) |
| Commpage page placement, text-page randomization, PTE permissions | `osfmk/arm/pmap/pmap.c` (`pmap_create_commpages`) |
| PFZ text entries | `osfmk/arm/cpu_capabilities.h`, `osfmk/arm/commpage/commpage_asm.s` (header comment only), `libsyscall/wrappers/_libkernel_init.c` (`pfz=` parsing) |
| Commpage readers | `libsyscall/wrappers/mach_absolute_time.s`, `mach_continuous_time.c`, `mach_approximate_time.c`, `mach_boottime.c`, `__commpage_gettimeofday.c`, `__get_cpu_capabilities.s`, `kdebug_trace.c`, `libsyscall/mach/mach_init.c`, `libsyscall/mach/host.c`, `libsyscall/os/tsd.h` |
| Trap dispatch, fast traps, platform call | `osfmk/arm64/sleh.c` (`handle_svc`), `osfmk/arm64/machine_routines.c` (`platform_syscall`), `osfmk/mach/arm/traps.h`, `osfmk/arm64/proc_reg.h` (`PLATFORM_SYSCALL_TRAP_NO`), `osfmk/mach/arm/thread_status.h` (`get_saved_state_svc_number`) |
| BSD return convention, indirect call, 16-bit number | `bsd/dev/arm/systemcalls.c` |
| Mach trap dispatch and invalid-trap exception | `osfmk/arm64/bsd_arm64.c` (`mach_syscall`), `bsd/uxkern/ux_exception.c`, `bsd/sys/signalvar.h` |
| `nosys` → SIGSYS, `enosys` | `bsd/kern/subr_xxx.c` |
| Timebase numer/denom formula, `mach_timebase_info` trap | `osfmk/arm/rtclock.c` (`timebase_callback`, `clock_timebase_info`), `libsyscall/wrappers/mach_timebase_info.c`, `osfmk/kern/syscall_sw.c` |
| Guest timebase: Swift's fixed 125/3 conversion of task deadlines on Apple arm64 | swift `stdlib/public/Concurrency/DispatchGlobalExecutor.cpp` (`platform_time`, `clock_and_value_to_time`, `swift_dispatchEnqueueWithDeadline`), swiftlang/swift `main`, fetched 2026-10-17 |
| libdispatch converts with `mach_timebase_info` | libdispatch `src/shims/time.h` (`_dispatch_time_nano2mach`), `src/time.c` (`_dispatch_host_time_init`), apple-oss-distributions/libdispatch `main`, fetched 2026-10-17 |
| The Thor's counter is 1 GHz | level 3: `ycode-simd` reports `CNTFRQ_EL0 = 1000000000 Hz`; the host kernel log says `arch_timer: cp15 timer(s) running at 1000.00MHz` |
| `CPUFAMILY_*` constants | `osfmk/mach/machine.h` |
| macOS arm64 kernel options | `config/MASTER`, `config/MASTER.arm64.MacOSX` |
