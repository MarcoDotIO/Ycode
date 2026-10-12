# Spec: stage 3a-ii contract (Ycode's host libraries)

Status: **contract, complete.** §7 and §8 build on
`specs/simulator/host-library-init.md` (level 1).

Inputs:

- `specs/simulator/host-library-loading.md`: dyld's rules (level 1).
- `specs/simulator/host-library-surface.md` and
  `data/host-lib-surface-{kernel,platform,pthread}.json`: the required
  symbols (level 4).
- `specs/simulator/stage3-contract.md` §12: why this stage exists.

## 1. Goal and exit criterion

Ycode supplies clean-room replacements for the three macOS host libraries
that the simulator runtime re-exports:

- `/usr/lib/system/libsystem_kernel.dylib`
- `/usr/lib/system/libsystem_platform.dylib`
- `/usr/lib/system/libsystem_pthread.dylib`

**Exit criterion (3a):** `ycode-simd --exec hello …` on the Thor prints
`milestone: libSystem initializer reached` (stage-3 contract §1). **Stretch
(3b):** `hello` prints its line and exits 0.

## 2. Binary format (from `host-library-loading.md`)

Each library is a single-architecture **arm64** file, CPU subtype 0
(never arm64e), with filetype `MH_DYLIB`. It must have:

- `LC_ID_DYLIB` with the install name **exactly equal to the path** above.
  Current version 1.0.0, compatibility version 1.0.0.
- `LC_UUID`.
- `LC_BUILD_VERSION`: platform **7 (iOS simulator)**, minos 27.0, sdk 27.1.
- **No `LC_CODE_SIGNATURE`.**
- Segments in this order:
  1. `__TEXT` r-x at file offset 0, holding the load commands;
  2. `__DATA_CONST` (rw-, `SG_READ_ONLY`), if present;
  3. `__DATA` rw-;
  4. `__LINKEDIT` r--.
- **16 KiB** segment alignment.
- Fixups as chained fixups (`LC_DYLD_CHAINED_FIXUPS`) and an export trie
  (`LC_DYLD_EXPORTS_TRIE`). Classic `LC_DYLD_INFO_ONLY` is acceptable if
  that is what the linker emits.
- Exports: plain symbols in the library's own trie. No resolvers, no
  re-exports.

Dependencies between the three:

- `libsystem_kernel` links nothing.
- `libsystem_platform` may link `libsystem_kernel`.
- `libsystem_pthread` may link `libsystem_kernel` and
  `libsystem_platform`.
- They must not link `libSystem.B` or anything in the simulator cache, with
  one exception: `libsystem_pthread` may weak-link `libdyld` if the init
  research requires it.

## 3. Build

- **Sources:** `ycode/SimHostLibs/{kernel,platform,pthread}/`, in C11
  (freestanding) and arm64 assembly.
- **Build script:** `ycode/SimHostLibs/build.sh` writes
  `ycode/SimHostLibs/out/libsystem_{kernel,platform,pthread}.dylib`.
- **It must build on Linux** with the swiftly toolchain: `clang`, plus
  `ld64.lld` through `-fuse-ld=lld` or a direct `ld64.lld` call. The flags
  are:

  ```
  -target arm64-apple-ios27.0-simulator -nostdlib -ffreestanding -fno-builtin
  -fno-stack-protector -fno-exceptions -fPIC -O2
  -platform_version ios-simulator 27.0 27.1 -dylib
  -install_name /usr/lib/system/<name>.dylib
  ```

  The exact link flags are the implementer's choice, as long as the result
  passes §2.
- macOS builds with Apple clang/ld are optional.
- **No SDK headers.** The libraries declare their own types, so the build
  never needs the iOS SDK.
- **Self-check.** The build script verifies every output with
  `ycode macho`: platform 7, MH_DYLIB, arm64 subtype 0, the install name,
  no code signature, and 16 KiB-aligned segments. It also checks that
  **every symbol in the matching surface JSON** is exported (from
  `llvm-nm -gU`, or Ycode's export-trie reader if one exists). A missing
  symbol fails the build.

### 3.1 Toolchain deviations (normative, from agent P)

- **CPU baseline.** The default CPU for the `arm64-apple` triple emits
  `ldapr` (FEAT_LRCPC). The Thor has it, and the reference hosts are
  ARMv8.4 or later. Ycode's host libraries require LRCPC.

- **Untagged objects.** Swift 6.4's `ld64.lld` rejects input objects that
  carry a Darwin platform tag.
  - Objects are compiled with the **real Darwin triple**
    `arm64-apple-ios27.0-simulator`, so they get Apple's calling convention
    (DarwinPCS).
  - `common/strip_platform.py` then removes the object's `LC_BUILD_VERSION`.
  - The linker writes the dylib's `LC_BUILD_VERSION` (iOS Simulator
    27.0/27.1) from `-platform_version`.
  - **Never use `arm64-apple-none-macho`.** It produces generic AAPCS64,
    which breaks variadic functions and functions with more than 8
    arguments when Darwin code calls them. `-target-abi darwinpcs` does not
    fix it on this toolchain.
  - Every build starts with `common/abi_check.py`. It compiles, links, and
    disassembles variadic and 10-argument probes, and fails unless both
    the caller and the callee follow DarwinPCS.
- **`.tbd` link stubs.** Platform and pthread link against generated `.tbd`
  stubs of the libraries below them, not the dylibs. The result has the
  same `LC_LOAD_DYLIB` commands and two-level binds.
- **No signature.** `-no_adhoc_codesign` is required. Without it lld adds a
  code signature.
- **Stub suppression.** Defining and exporting a symbol in any source file
  under `kernel/`, `platform/`, or `pthread/` removes its generated stub
  automatically (see `SimHostLibs/README.md`).

## 4. Unimplemented functions

Every surface symbol must be exported from day one. A function that is not
implemented yet is a generated stub. The stub:

- executes Ycode-private trap **`x16 = 0x7963_0F00`** with `x0` = a pointer
  to the symbol name (a NUL-terminated string in `__TEXT,__cstring`). The
  VMM logs `unimplemented libfunc <name>`. In `--trace` mode the VMM exits
  with status **73**; otherwise it returns;
- then fails in the conventional way for its category:
  - BSD-style calls: `errno = ENOSYS` (78), return −1;
  - Mach routines: return `KERN_NOT_SUPPORTED` (46);
  - pointer-returning calls: return NULL;
  - void calls: return.

The category comes from the surface JSON.

## 5. Placement in the guest (VFS)

The VMM adds three **read-only single-file prefixes** to `DarwinFileSystem`.
Each maps a guest path above to the matching file in the build output
directory. Every other `/usr/lib/system/*` path keeps returning ENOENT.

`stat` and `fstat` must report consistent and unique (dev, ino, mtime)
values for these files, and `F_CHECK_LV` must return 0. Both already hold
for host files.

## 6. VMM diagnostics

- A guest fault (kind 2) whose FAR or ELR is `0xbad4007`, or lies within
  16 bytes of it, is reported as `missing host-library export (cache patch
  placeholder 0xbad4007)`, with the ELR attributed to an image.
- The private trap `0x7963_0F00` is described in §4.

## 7. Initialization interfaces

`host-library-init.md` §1–§2 is normative for call order, arguments, and the
struct layouts:

- `_libkernel_functions` v5 (128 B)
- `_libkernel_string_functions` v1 (136 B)
- `_libkernel_voucher_functions` v3 (48 B)
- `_libpthread_functions` v2 (32 B)
- `ProgramVars` (40 B)
- the bsdthread registration record (56 B)

Ycode's decisions:

1. **Nothing depends on the init functions being called.** It is not
   confirmed that the iOS 27.1 libSystem calls `__libkernel_init`,
   `__libplatform_init`, `__pthread_init`, or `__pthread_late_init` directly,
   because the surface shows 0 importers. So:
   - every data symbol has its correct **static initial value** at load time
     (§8.4);
   - every init function is a **real implementation** that stores what it is
     given and is safe to skip or to call twice;
   - every table member is NULL-checked before use.
2. `__libkernel_init` stores the v5 table and runs Mach init: it sets
   `mach_task_self_` from trap −28 and refreshes the `vm_*page*` variables
   from the commpage page-shift fields.
3. `__libplatform_init` and `__libkernel_platform_init` store the string
   table and consume `security_config=` / `pfz=` if present.
4. `__pthread_init` adopts the main thread from the **VMM-built block**
   (§8.3). It fills slots 2, 3, 4, 7, 8, and 9 from `apple[]`/traps, and calls
   `bsdthread_register` (BSD 366). The VMM answers that call with
   `0x4000_001F`.
5. `host_info(HOST_PRIORITY_INFO)` is answered **inside
   `libsystem_kernel`** for stage 3a: user priority 31, minimum 0, maximum
   79. The other Mach routines follow §4 until they are implemented.

## 8. Thread-local storage and errno ABI

`host-library-init.md` §3–§5 is normative. The essentials:

1. **TSD.** `TPIDRRO_EL0` points exactly at slot 0. Slots are a flat array of
   768 × 8 bytes:

   | Slot | Contents |
   |---|---|
   | 0 | self (`pthread_t`) |
   | 1 | errno pointer |
   | 2 | MIG reply port |
   | 3 | Mach thread port (also the `os_unfair_lock` owner) |
   | 4 | QoS |
   | 5 | return-to-kernel |
   | 7 | pointer-munge token |
   | 8 | special reply port |
   | 9 | semaphore cache |
   | 123 | Mach message aux |

   Other reserved ranges are as in the research spec. `__thread` accesses
   read `TPIDRRO_EL0` inline.
2. **`pthread_t` = TSD base − 224.** The fields read inline are:

   | Offset from TSD base | Field |
   |---|---|
   | −52 | `err_no` |
   | −48 | `stackaddr` |
   | −40 | `stackbottom` |
   | −8 | `thread_id` |
   | +8 | `__cleanup_stack` |

3. **The main thread is built by the VMM before boot.** This is the host
   dyld's job on macOS.
   - A zeroed block of 8 KiB, 16-byte aligned, in an anonymous EL0 RW
     region.
   - At +216: `thread_id` = 1.
   - At +224 (slot 0): the block address.
   - At +232 (slot 1): block + 172, the address of `err_no`.
   - At +248 (slot 3): the thread port name `0x203`.
   - At −48/−40 from the TSD base: `stackaddr` = `user_stack` top and
     `stackbottom` = top − 8 MiB.
   - The initial **`TPIDRRO_EL0` = block + 224**, set through boot info.
4. **Static data values:**

   | Symbol | Value |
   |---|---|
   | `vm_page_size` | 16384 |
   | `vm_page_mask` | 16383 |
   | `vm_page_shift` | 14 |
   | `vm_kernel_page_*` | the same |
   | `mach_task_self_` | `0x103` |
   | `bootstrap_port` | 0 |
   | `NDR_record` | bytes `00 00 00 00 01 00 00 00` |
   | `_os_alloc_once_table` | 1600 bytes, zero |
   | `__unix_conforming` | 1 |

   Port names agreed with the VMM: task `0x103`, thread `0x203`, host
   `0x303`. Thread port names have bit 0 set.
5. **errno.**
   - `__error()` returns slot 1 if it is non-NULL, otherwise a global
     `errno` in `libsystem_kernel`. A TSD base of 0 is treated as "no slot".
   - `cerror` (cancellation is a no-op in 3a) and `cerror_nocancel` store
     into both locations and return −1 in `x0` and `x1`.
   - P's `__ycode_set_errno` hook is implemented by K on top of these.
6. **`apple[]` additions the VMM must supply.** In addition to stage-3 §6:
   `ptr_munge=` (**non-zero**), `security_config=0x0`, and
   `th_port=0x203`.

## 8.1 Revised stage-3a milestone

Stage-3 contract §1 item 2 is widened. The milestone fires on the **first
trap whose ELR lies in any of these**:

- a shared-cache image under `/usr/lib/system/libsystem_*`;
- the shared-cache `libSystem.B`;
- one of Ycode's three host libraries.

`dyld_sim` never calls the host libraries itself, so a trap from them means
the libSystem initialization chain is running. The milestone line names
the image and offset, and the LR's image too.

## 8.2 Stage 3a result and decisions (2026-10-11)

**Milestone reached on the Thor**, reproduced by the orchestrator:

```
milestone: libSystem initializer reached (/usr/lib/system/libsystem_kernel.dylib [ycode] + 0x7e8; LR 0x25a9f20b0 = /usr/lib/libSystem.B.dylib + 0x10b0)
```

- 280 traps.
- All 11 cache mappings were made at their header addresses.
- The three Ycode libraries were loaded from the VFS (stat, open, fstat,
  `F_CHECK_LV`, mmap).
- **libSystem.B calls the host `__libkernel_init` directly.** This settles
  `host-library-init.md` open question 1.

**Order of the first library functions hit** (stubs returning): `__libkernel_init`,
`__sysctl`, `pthread_mutex_lock`, `writev$NOCANCEL`, `pthread_mutex_unlock`,
`mmap`. libc's locks run before any `__pthread_init`.

**Decisions:**

1. **`bsdthread_register` write-back:** `mutex_default_policy` = 0,
   `main_qos` = `0x8FF`, `stack_addr_hint` = the main stack top rounded down
   to a page.
2. **Milestone line:** it may carry the `; LR … = …` suffix. The prefix
   stays fixed.
3. **Build order on a fresh checkout:** first `swift build`, then
   `sh SimShim/build.sh`, then `sh SimHostLibs/build.sh`. The last of these
   uses `.build/debug/ycode` and `../../specs/simulator/data`.
4. **`pfz=`** is not supplied. There is no commpage text page, so nothing
   needs it yet.
5. **Main-thread block placement:** a 16 KiB EL0 RW page at `0x3_1001_0000`,
   directly after the host page. `TPIDRRO_EL0` = `0x3_1001_00E0`.

## 10. Stage 3b: Ycode-private Mach-routine ABI (normative)

On Darwin, MIG routines (`host_get_clock_service`, `semaphore_create`, …)
are RPC messages to the kernel. Ycode owns both ends, its
`libsystem_kernel` and its VMM, so instead of emulating MIG messaging it
uses **private traps**:

- **Encoding:** `x16 = 0x7963_2000 + n`. The arguments are the routine's C
  arguments in `x0`…`x7`. **`x0` returns a `kern_return_t`, and carry is
  not used.**
- **Out-parameters:** the VMM writes them into guest memory.
- **Failure:** an out-parameter pointer that is unwritable returns
  `KERN_INVALID_ADDRESS` (1).

| n | Routine | VMM behavior (single vCPU) |
|---|---|---|
| 1 | `host_get_clock_service(host, clock_id, clock_serv_t *out)` | clock ids 0 (`SYSTEM_CLOCK`) and 1 (`CALENDAR_CLOCK`) → a new clock port name (kind `clock`, records the id). Others → `KERN_INVALID_ARGUMENT` (4) |
| 2 | `clock_get_time(clock_serv, mach_timespec_t *out)` | System clock: uptime since VM start. Calendar clock: host wall time. `mach_timespec_t` is `{u32 tv_sec; i32 tv_nsec}` |
| 3 | `semaphore_create(task, semaphore_t *out, int policy, int value)` | New semaphore port name (kind `semaphore`, count = value). `value < 0` → `KERN_INVALID_ARGUMENT` |
| 4 | `semaphore_destroy(task, semaphore)` | Remove it. An unknown name → `KERN_INVALID_NAME` (15) |
| 5 | `task_get_special_port(task, int which, mach_port_t *out)` | Stage 3b: `which` = 4 → the bootstrap port `0x0503`, others → `MACH_PORT_NULL`. **Superseded in stage 4b** by the per-task rules of `processes.md` §3.2 (control/name/read/inspect ports, bootstrap, host, task-access, debug-control, resource-notify; unknown `which` → `KERN_INVALID_ARGUMENT`) |
| 6 | `task_set_special_port(task, int which, mach_port_t port)` | Stage 3b: record it. **Stage 4b:** `processes.md` §3.2 (1 and 2 → `KERN_NO_ACCESS`, 9 settable once); `task` may name another task's control port |
| 7 | `mach_port_get_attributes`-style fallbacks | Reserved |
| 8 | `mach_ports_register3(task, p0, p1, p2)` (stage 4b) | Replaces all three registered-port slots of `task` (`processes.md` §3.4); each port copied in as COPY_SEND. `task` must be a task control port the caller holds: no right or a dead name → `MACH_SEND_INVALID_DEST`, another kind of right → `KERN_INVALID_ARGUMENT`; a bad port → `MACH_SEND_INVALID_RIGHT` |
| 9 | `mach_ports_lookup3(task, &p0, &p1, &p2)` (stage 4b) | A new send right (copy) for each slot; NULL stays 0, a dead port gives `MACH_PORT_DEAD`. Same `task` rules; an unwritable out-pointer → `KERN_INVALID_ADDRESS`. The library pads/allocates (`mach_ports_register`/`mach_ports_lookup`) |

**Semaphore traps** (real Mach traps; the VMM implements them on the
semaphore objects above):

| Trap | Behavior |
|---|---|
| −33 `semaphore_signal` | count += 1 |
| −34 `semaphore_signal_all` | count = max(count, 0) |
| −35 `semaphore_signal_thread` | Same as signal |
| −36 `semaphore_wait` | If count > 0, decrement and return `KERN_SUCCESS`; otherwise log `DEADLOCK` and return `KERN_ABORTED` (14) |
| −37 `semaphore_wait_signal(wait, signal)` | Signal first, then wait |
| −38 `semaphore_timedwait(sem, sec, nsec)` | If count > 0, decrement; otherwise sleep for the timeout and return `KERN_OPERATION_TIMED_OUT` (49) |
| −39 `semaphore_timedwait_signal` | Signal first, then timed wait |

Any other name → `KERN_INVALID_NAME`.

**Library side (K):**

- `host_get_clock_service`, `clock_get_time`, `semaphore_create`,
  `semaphore_destroy`, `task_get_special_port`, and `task_set_special_port`
  call the private traps above.
- The semaphore functions call the real traps.
- `__commpage_gettimeofday` is a real function that returns non-zero ("not
  available"), so callers take the BSD 116 path without a log line.
- `proc_pidinfo` is a real libproc wrapper over `__proc_info` (BSD 336).
  The VMM answers ENOTSUP for now.
- The `bootstrap_port` variable keeps its static value 0. libxpc sets it
  through `task_get_special_port`.

**VMM side (H2):**

- The private traps and semaphore traps above.
- The **bootstrap port** is name `0x0503`. `mach_msg` to it keeps returning
  `MACH_SEND_INVALID_DEST` until stage 4, which brings launchd and the
  bootstrap server.
- Optional, from Q: seed TSD slot 4 = `0x8FF` and slot 7 = the munge token
  in the main-thread block, so inline readers before `__pthread_init`
  see sane values.

**Exit criterion (3b) — MET 2026-10-11** (orchestrator reproduction: exit 0, 740 traps,
0 unimplemented under `--trace`): `ycode-simd --exec hello …` with **no debug flags**
prints `hello from the iOS simulator runtime on Linux` and exits 0, and the
`--trace` run shows no unimplemented library function or trap on the path.

## 9. Ownership

| Owner | Scope |
|---|---|
| Agent **P** (now) | `ycode/SimHostLibs/build.sh`, `SimHostLibs/README.md`, `SimHostLibs/common/` (shared headers, the stub generator), `SimHostLibs/platform/`, plus the generated unimplemented-stub layer for *all three* libraries, so every library links and passes the export check from the start |
| Agent **K** (after §7–§8) | `SimHostLibs/kernel/` |
| Agent **Q** (after §7–§8) | `SimHostLibs/pthread/` |
| Agent **H2** (after §7–§8) | VMM integration (§5, §6) in `YcodeHypervisor` and `ycode-simd`. The private trap `0x7963_0F00` goes in `YcodeDarwinKernel` |

The orchestrator owns `Package.swift`, every spec, and the commits.

## Evidence

- §2 and §5: `host-library-loading.md` (level 1).
- §3 and §4: Ycode design. The symbol lists come from
  `host-library-surface.md` (level 4).

## 11. Stage 4c decisions (2026-10-12)

- `pthread_once` ignores the signature word: a zero-filled
  `pthread_once_t` (as in Libc's static `__sdidinit`) runs its routine
  once. Mutexes, conditions, and rwlocks still return EINVAL for signature
  0, as Darwin's libpthread does (level 1: Libc `stdio/FreeBSD/findfp.c`,
  libpthread `pthread.c`).
- `___gettimeofday` zeroes `x2` (the `mach_time` out-pointer) before BSD
  116 (level 1: xnu `libsyscall/custom/__gettimeofday.s`).
- `host_get_special_port` returns `KERN_INVALID_ARGUMENT` without writing
  `*port`: guests only hold the unprivileged host port (level 1: xnu
  `osfmk/kern/host.c`, `host_get_special_port_from_user`).
- `mach_port_set_attributes` is a MIG client call (id 3218 to the task
  port, reply 3318), served by the VMM's kernel server; the VMM accepts the
  simulator's `MQ_CALL` option for it (`mach-ipc.md` §2.7 rule 3).
- `os_unfair_lock` crashes (`brk #0x7964`, x0 = message, x1 = lock) when
  the kernel reports `EOWNERDEAD`, as libplatform does, instead of
  retrying.
- The simple-ASL context in `os_alloc_once` slot 21: see
  `host-library-init.md` §1 step 3.

### 11.1 Private Mach routines added in stage 4c-iii

| n | Routine | VMM behavior |
|---|---|---|
| 10 | `mach_make_memory_entry_64(task, &size, offset, permission, &handle, parent)` | Named entries (`MAP_MEM_NAMED_CREATE`, `MAP_MEM_VM_COPY`, `MAP_MEM_VM_SHARE`, sub-entries of a parent, `MAP_MEM_ONLY`) as xnu `vm_memory_entry.c`; the entry object dies with its last send right |
| 11 | `mach_vm_map` with a memory object `(task, &addr, size, mask, flags, &{object, offset, copy, cur, max, inherit})` | Maps the entry's shared host memory (shared across VMs as KVM memslots) or a copy |

Private trap `0x7963_0006` (`task_info`) also serves flavor 15
(`TASK_AUDIT_TOKEN`). `mach_vm_map`/`vm_map` without an object keep the
real trap (−15). Library additions: `mach_make_memory_entry(_64)`,
`task_info`, `host_set_atm_diagnostic_flag` (`KERN_NO_ACCESS`),
`host_request_notification` (accepted, never fires),
`setiopolicy_np`/`getiopolicy_np`, and the
`mach_{host,task,thread}_special_port_{description,for_id}` label tables
(the labels and macro names are public interop identifiers from xnu
`port_descriptions.h`; `launchctl print` shows them).

### 11.2 Private Mach routines added in stage 6

| n | Routine | VMM behavior |
|---|---|---|
| 12 | `vm_remap` / `vm_remap_new` within the caller's own task | Share or copy a range (xnu `vm_user.c`); libobjc's trampolines use it |
| 13 | `task_threads(task, &list, &count)` | Send rights to the task's thread ports (self only) |
| 14 | `mach_port_get_context(task, name, &context)` | xnu `mach_port.c` |
| 15 | `mach_port_set_context(task, name, context)` | xnu `mach_port.c` |

Real traps added: mk_timer −91…−95 (xnu `mk_timer.c`). `gettid` (BSD 286)
returns ESRCH (no per-thread credentials, xnu `kern_prot.c`).
| 16 | `host_get_io_main(host, &port)` / `host_get_io_master` | Returns a send right to the VMM's minimal IOKit main port (`iokit-minimal.md`) |

Stage 6 also added (VMM only, no new routine numbers): `vm_purgable_control`
(trap −11; states kept, never purged), POSIX named semaphores (BSD
268–273, 420), advisory locks (`F_GETLK`/`F_SETLK`/`F_SETLKW`/
`F_SETLKWTIMEOUT`, `F_OFD_*`, `flock` 131), `getattrlist` (220, 228, 476),
data-protection classes and `open_dprotected_np` (216, 218), csops per xnu
`csops_internal`, and the rename/chmod/chown/utimes/truncate family.

### 11.3 Stage 6 follow-ups (2026-10-12)

| n | Routine | VMM behavior |
|---|---|---|
| 17 | `thread_get_state(thread, flavor, state, &count)` | Flavors 1 (unified, 70 words), 6 (68), 7 (4); threads of the caller's task only; the state is the registers at the entry of the thread's current trap. A thread running guest code gives `KERN_FAILURE` (libobjc then keeps its old method caches) |
| 18 | `thread_get_exception_ports` | xnu `ipc_tt.c`: entries grouped by identical (port, behavior, flavor); none set → 0 entries |
| 19 | `thread_set_exception_ports` | Stored per thread, released with the thread or task; never delivered |

`thread_swap_exception_ports` is a get followed by a set in the library
(not atomic). Library additions: `posix_madvise`, `csr_check`,
`csr_get_active_config`, `kpersona_*`, `mach_error_string` (the
"(os/kern)" table only).

BSD additions: `setattrlist`/`fsetattrlist`/`setattrlistat` (221/229/524;
Finder info stored as the xattr `com.apple.FinderInfo`, volume attributes
EROFS); `madvise` advice 0–11 (11 = `MADV_ZERO` zeroes the range, xnu);
`statfs` with the host volume's real sizes, `f_fsid` = {dev, 0x1A},
`MNT_ROOTFS` for `/`, `MNT_DOVOLFS | MNT_JOURNALED`, `f_fssubtype` 1.

**Ycode decisions (not yet backed by a probe):** `memorystatus_control`
EPERM except commands 18/19/24 → EINVAL (EPERM itself is level 3,
`app-install-launch.md` §3.3); `quotactl` ENOTSUP; `csrctl` op 0 EPERM, op
1 config 0; `__persona`: no personas exist (ESRCH; alloc/dealloc EPERM;
FIND returns 0). A level-3 probe on the Mac's simulator can confirm them.

csops entitlement blobs: for simulator builds the `__TEXT,__entitlements`
section is served as blob magic `0xFADE7171` (8-byte header + plist), for
signed images only.
