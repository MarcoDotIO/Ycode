# Spec: the host-dyld → `dyld_sim` handoff

Status: **reference** for stage 3 of `docs/SIMULATOR-LINUX.md` (the
static-image runner). Every fact in §1–§6 comes from Apple's open-source
`dyld` (evidence level 1), read at tag **`dyld-1378`** (the newest tag on
2026-10-11) and cross-checked against older tags where noted, plus public
`xnu` headers and the public macOS SDK headers. This spec restates behavior,
signatures, and layouts. It contains no Apple source code. §7 is Ycode's own
design.

Terms:

- **host dyld**: the macOS `/usr/lib/dyld` that the kernel starts for a
  simulator process. On Linux, Ycode's loader and VMM take its place.
- **`dyld_sim`**: `<DYLD_ROOT_PATH>/usr/lib/dyld_sim`, the simulator's own
  dynamic linker. It is built from the same `dyld` sources with
  `TARGET_OS_SIMULATOR` set.
- **helpers table**: the `SyscallHelpers` structure of function pointers
  that the host gives `dyld_sim` (§3).

## 1. Detection, location, validation, and mapping (host side)

### 1.1 Detection

1. The host builds its process configuration from the kernel's argument
   block (§4.4). It reads the main executable's platform from
   `LC_BUILD_VERSION`. Simulator platforms include iOS-simulator (7),
   tvOS-simulator (8), and watchOS-simulator (9).
2. `DYLD_ROOT_PATH` is recorded as the "sim root path" **only if** the main
   executable's platform is a simulator platform **and** the host's AMFI
   policy allows path environment variables (§3.4, bit 1). Like every
   `DYLD_*` path variable, it is processed from `envp` only under that
   policy bit.
3. For a simulator platform, the host **does not map the macOS shared
   cache**. It skips cache loading entirely.
4. In `prepare()` (macOS builds only):
   - If the sim root path is set and the main executable is arm64e, the
     host halts with the message that arm64e is not supported for
     simulator programs.
   - If the sim root path is set and the platform is a simulator, the host
     calls `prepareSim(<root>/usr/lib/dyld_sim)`. Its result becomes the
     host's "main" function (§2.5).
   - If the sim root path is set and the platform is not a simulator, the
     host halts ("only allowed with simulator programs").
   - If the platform is a simulator and no root path is set, the host halts
     ("not set for simulator program").

### 1.2 Validation (`prepareSim`)

In order:

1. `open` the file read-only, then `fstat` it, then `mmap` the whole file
   read-only and private (temporary).
2. If the file is universal, pick the best slice for the **main
   executable's graded architecture list**. If it is thin, use it directly.
   Anything else halts with an architecture-mismatch message.
3. Validate the slice as a loadable Mach-O:
   - magic `MH_MAGIC(_64)`;
   - arch compatible with the graded list;
   - filetype in {execute, dylib, bundle, dylinker} (`dyld_sim` is
     `MH_DYLINKER`, 7);
   - load commands well-formed;
   - **platform loadable into the process's platform**;
   - embedded paths and segments valid.
4. Require `LC_CODE_SIGNATURE`. If it is missing, halt.
5. Register the signature with
   `fcntl(fd, F_ADDFILESIGS_FOR_DYLD_SIM (83), fsignatures*)`. The fields
   are `fs_file_start` = slice offset in the file, `fs_blob_start` = code
   signature offset, and `fs_blob_size` = signature size.
   - xnu documents command 83 as accepting only Apple-signed files.
   - On an internal install with the commpage flag `disableProdSimChecks`
     (dyld flags bit 9), the host uses `F_ADDFILESIGS_RETURN` (97) instead.
   - After the call, the returned `fs_file_start` (the end of the signed
     range) must be ≥ the code-signature offset. If it is not, the host
     halts.
6. The build signs `dyld_sim` with the entitlement
   `com.apple.private.dyld_sim = true`
   (`dyld/dyld_sim-entitlements.plist`). The host itself does not check it.

There is **no version check** of `dyld_sim` before the jump. Compatibility
is handled by the helpers table's `version` field, which `dyld_sim` checks
slot by slot (§3).

### 1.3 Mapping

1. `mappedSize` is the span from the lowest to the highest segment
   (`vmaddr + vmsize`), excluding `__PAGEZERO`, rounded as needed.
   `preferredLoadAddress` is the `vmaddr` of `__TEXT`.
2. Reserve `mappedSize` bytes **anywhere** with
   `vm_allocate(…, VM_FLAGS_ANYWHERE)`. The reservation is zero-filled and
   read/write.
3. For each segment with `filesize != 0`, `mmap` exactly `filesize` bytes
   with `MAP_FIXED | MAP_PRIVATE` and the segment's **`initprot`**:
   - address = `vmaddr − preferredLoadAddress + reservationBase`;
   - file offset = slice offset + segment `fileoff`.

   Segments with `filesize == 0` are skipped. Their pages keep the
   zero-filled read/write memory from step 2. Any zero-fill tail beyond the
   file-backed pages of a segment also stays read/write.
4. If a mapping fails or lands outside the reservation, the host halts.
5. Close the fd and unmap the temporary whole-file mapping.
6. **slide** = `reservationBase − preferredLoadAddress`. The host applies
   **no fixups** to `dyld_sim`. `dyld_sim` rebases itself (§4.1).
7. Page size: the host assumes nothing beyond the host's own `mmap`
   granularity. Segment `vmaddr` and `fileoff` must be aligned to the host
   page size: 16 KB on arm64 macOS and 4 KB on x86-64.

### 1.4 Host actions between mapping and the jump

1. Find the entry point (§2.2).
2. Save a pointer to the host's runtime state, used by the callbacks.
3. Add `dyld_sim` (its path and load address) to the host's image list for
   debuggers.
4. Replace the legacy `notification` pointer in the host's
   `dyld_all_image_infos` with a trap function. From then on the host
   issues debugger breakpoint notifications for `dyld_sim`.
5. **Detach the process from the shared region.** The macOS shared cache is
   removed from the address space, so the shared-region range is empty when
   `dyld_sim` starts.
6. Emit kdebug UUID-map trace points if tracing is enabled.
7. Compatibility steps for old runtimes, gated by the epoch from
   `dyld_sim`'s own `LC_BUILD_VERSION`:
   - Epoch ≤ fall 2022: remove the main executable from the host's image
     list.
   - Epoch ≤ fall 2021: record the sim cache's device/inode in
     `all_image_infos`, using the file
     `$DYLD_SHARED_CACHE_DIR/dyld_sim_shared_cache_<arch>`.

   Neither applies to iOS 27.x.
8. Call the entry (§2).

## 2. The `dyld_sim` entry point

### 2.1 Name

- C name **`_dyld_sim_prepare`**. The linker symbol is `__dyld_sim_prepare`.
- The simulator build links `dyld_sim` with `-e __dyld_sim_prepare`,
  exports exactly that symbol (`-exported_symbol`), and passes
  `-dylinker`, `-fixup_chains`, and `-data_const`
  (`configs/dyld.xcconfig`).
- The debugger-support exports of the macOS dyld (`_dyld_all_image_infos`
  and `_lldb_image_notifier`) are **not** exported by `dyld_sim`.

### 2.2 How the host finds it

The host does **not** look the symbol up. It walks the load commands of the
mapped `dyld_sim` and takes the first of these it finds:

| Command | Entry offset |
|---|---|
| `LC_MAIN` (0x80000028) | `entryoff` |
| `LC_UNIXTHREAD` (0x5) | thread-state PC − `preferredLoadAddress` |

- In `LC_UNIXTHREAD`, the flavor is at byte 8 and the register state starts
  at byte 16. The PC is read as follows:

  | CPU | Flavor | PC location in the register state |
  |---|---|---|
  | arm64 | `ARM_THREAD_STATE64` = 6 | 64-bit word index 32 (`__pc`) |
  | x86-64 | `x86_THREAD_STATE64` = 4 | 64-bit word index 16 (`rip`) |

- Entry address = load address of `dyld_sim` + entry offset. The "uses
  CRT" flag that `LC_UNIXTHREAD` implies is ignored for `dyld_sim`.
- If neither command is present, the host halts ("dyld_sim entry not
  found").
- The exported `__dyld_sim_prepare` symbol in the export trie gives the same
  address and can serve as a cross-check.
- On arm64e hosts the host signs the pointer with a zero discriminator
  before calling it. The simulator slice is plain arm64, so this does not
  apply to Ycode.

### 2.3 Signature

`_dyld_sim_prepare` is an ordinary C function (C calling convention of the
platform) with **9 parameters**. It returns a function pointer.

| # | arm64 location | x86-64 location | Type | Meaning |
|---|---|---|---|---|
| 1 | `x0` | `rdi` | `int` | `argc` |
| 2 | `x1` | `rsi` | `const char**` | `argv`. **Must point into the kernel argument block** (§4.4) |
| 3 | `x2` | `rdx` | `const char**` | `envp` |
| 4 | `x3` | `rcx` | `const char**` | `apple` |
| 5 | `x4` | `r8` | `const mach_header*` | main executable's load address (its mach header) |
| 6 | `x5` | `r9` | `const mach_header*` | `dyld_sim`'s own load address |
| 7 | `x6` | stack | `uintptr_t` | `dyld_sim` slide (load address − preferred address) |
| 8 | `x7` | stack | `const SyscallHelpers*` | helpers table (§3) |
| 9 | stack `[sp+0]` | stack | `uintptr_t*` | out-parameter `startGlue` |

- On arm64, the 9th argument is the first stack argument: an 8-byte slot at
  `[sp]` at the moment of the call, with SP 16-byte aligned.
- On x86-64, the 7th, 8th, and 9th arguments are at `[rsp+8]`, `[rsp+16]`,
  and `[rsp+24]` on entry, above the return address.
- The signature is unchanged in every tag checked: it is the same 9-tuple in
  the `dyld2` host of `dyld-852` and in `dyld-1042.1`, `dyld-1245.1`, and
  `dyld-1378`.

### 2.4 Return value and `startGlue`

- `dyld_sim` stores **1** into `*startGlue`. This means "the result is a
  `main()`-style function, not a crt1 entry".
- It returns the address of its internal function **`start_sim`**. The
  linker symbol of that function is also `start_sim`.
- `start_sim` has the `main` signature `(argc, argv, envp, apple)`. It
  calls the program's real `main` with the same four arguments. When `main`
  returns, it calls the **simulator** libSystem `exit(result)` through
  libdyld's helper object. This keeps `atexit` handlers inside the
  simulator world. `start_sim` does not return in practice.

### 2.5 What the host does with the return value

- The dyld4 host (`dyld-1042.1` and later):
  - passes the address of a local for `startGlue` and **ignores** it;
  - returns the pointer from `prepare()`;
  - calls it from its own `start` as `main(argc, argv, envp, apple)`, with
    its own copies of those four values, on the current stack. No stack
    reset happens.
  - If that call returns, a simulator host calls `_exit(result)`
    directly.
- The legacy `dyld2` host (`dyld-852`) passed `startGlue` through to its
  startup assembly:
  - A nonzero value meant "jump to the returned address as `main`, with
    `argc`/`argv`/`envp`/`apple` in the argument registers and the glue as
    the return address".
  - Zero meant "reset SP to the kernel block and branch to an
    `LC_UNIXTHREAD`-style entry".

  `dyld_sim` always returns 1, so only the first case occurs.

## 3. The helpers table (`dyld::SyscallHelpers`)

### 3.1 Layout and version

- The table is an array of pointer-sized words.
  - Word 0 is `version` (`uintptr_t`).
  - Word *n* (n ≥ 1) is a function pointer at byte offset `8·n` on LP64.
- `dyld-1378` defines **67 function slots**. The structure is 68 words, or
  **544 bytes**.
- The host table in `dyld-1378` has **`version = 18`**.

Version history, from the tags checked:

| Version | First seen in |
|---|---|
| 16 | `dyld-940`, `dyld-955` |
| 17 | `dyld-1042.1` (still current in `dyld-1245.1`) |
| 18 | `dyld-1284.13` and every later tag through `dyld-1378` |

`dyld_sim` reads the table only through a global pointer set first thing in
`_dyld_sim_prepare`. It gates every slot added after version 1 on
`version`, so a lower version never makes `dyld_sim` call a slot that is
missing.

### 3.2 Slots

- "Sig" uses the public macOS SDK prototype of the libc/Mach function
  named. "Ver" is the version that added the slot (from the header
  comments).
- "dyld_sim use" says how the simulator side uses the slot in `dyld-1378`.
  "Gate" is the minimum `version` at which `dyld_sim` calls it.
- Several libc prototypes are **variadic** (`open`, `fcntl`, `ioctl`).
  `dyld_sim` calls them through those variadic types, so the third argument
  is passed as a variadic argument (see §6.1 and §7.3).

| Slot | Off | Ver | Name | Sig (return ← params) | Purpose / dyld_sim use |
|---|---|---|---|---|---|
| 0 | 0x000 | — | `version` | `uintptr_t` | Table version (18) |
| 1 | 0x008 | 1 | `open` | int ← (const char* path, int oflag, …mode) | Opens a file. Also used to emulate `openat`: `dyld_sim` gets the dir path with `fcntl(F_GETPATH)`, appends `/name`, then calls `open` |
| 2 | 0x010 | 1 | `close` | int ← (int fd) | |
| 3 | 0x018 | 1 | `pread` | ssize_t ← (int fd, void* buf, size_t n, off_t off) | Reading headers, cache first page (16 KB) |
| 4 | 0x020 | 1 | `write` | ssize_t ← (int fd, const void* buf, size_t n) | Log output (also used for `fwrite`, which goes to stderr) |
| 5 | 0x028 | 1 | `mmap` | void* ← (void* addr, size_t len, int prot, int flags, int fd, off_t off) | Maps images and the **shared cache** (§4.2) |
| 6 | 0x030 | 1 | `munmap` | int ← (void*, size_t) | |
| 7 | 0x038 | 1 | `madvise` | int ← (void*, size_t, int) | |
| 8 | 0x040 | 1 | `stat` | int ← (const char*, struct stat*) | 64-bit-inode `struct stat` (§6.3) |
| 9 | 0x048 | 1 | `fcntl` | int ← (int fd, int cmd, …arg) | Commands used: `F_GETPATH` 50, `F_ADDFILESIGS_RETURN` 97, `F_CHECK_LV` 98, `F_SETFD` 2 |
| 10 | 0x050 | 1 | `ioctl` | int ← (int, unsigned long, …arg) | |
| 11 | 0x058 | 1 | `issetugid` | int ← (void) | |
| 12 | 0x060 | 1 | `getcwd` | char* ← (char* buf, size_t) | The host version does not allocate |
| 13 | 0x068 | 1 | `realpath` | char* ← (const char*, char* out) | The host version does not allocate. `out` is PATH_MAX (1024) |
| 14 | 0x070 | 1 | `vm_allocate` | kern_return_t ← (vm_map_t, vm_address_t*, vm_size_t, int flags) | Allocator pools (flags `VM_FLAGS_ANYWHERE` = 1, plus a VM tag in the high byte) |
| 15 | 0x078 | 1 | `vm_deallocate` | kern_return_t ← (vm_map_t, vm_address_t, vm_size_t) | |
| 16 | 0x080 | 1 | `vm_protect` | kern_return_t ← (vm_map_t, vm_address_t, vm_size_t, boolean_t set_max, vm_prot_t) | **`dyld_sim` implements `mprotect` on top of this slot.** The protection may include `VM_PROT_COPY` (0x10) |
| 17 | 0x088 | 1 | `vlog` | void ← (const char* fmt, va_list) | `DYLD_PRINT_*` logging. The host forwards to its own logger |
| 18 | 0x090 | 1 | `vwarn` | void ← (const char* fmt, va_list) | The host points this at the same logger as `vlog` |
| 19 | 0x098 | 1 | `pthread_mutex_lock` | int ← (pthread_mutex_t*) | Overrides libc's symbol inside `dyld_sim`. No direct caller found in the dyld sources |
| 20 | 0x0A0 | 1 | `pthread_mutex_unlock` | int ← (pthread_mutex_t*) | Same as slot 19 |
| 21 | 0x0A8 | 1 | `mach_thread_self` | mach_port_t ← (void) | |
| 22 | 0x0B0 | 1 | `mach_port_deallocate` | kern_return_t ← (ipc_space_t, mach_port_name_t) | |
| 23 | 0x0B8 | 1 | `task_self_trap` | mach_port_name_t ← (void) | `dyld_sim`'s own `mach_init` calls this slot once to set `mach_task_self_` |
| 24 | 0x0C0 | 1 | `mach_timebase_info` | kern_return_t ← (mach_timebase_info_t) | |
| 25 | 0x0C8 | 1 | `OSAtomicCompareAndSwapPtrBarrier` | bool ← (void* old, void* new, void* volatile* p) | |
| 26 | 0x0D0 | 1 | `OSMemoryBarrier` | void ← (void) | |
| 27 | 0x0D8 | 1 | `getProcessInfo` | dyld_all_image_infos* ← (void) | **Required at startup** (§4.5). The host returns its own `dyld_all_image_infos` |
| 28 | 0x0E0 | 1 | `errnoAddress` | int* ← (void) | **All of `dyld_sim`'s `errno` reads go through this** (`__error`) |
| 29 | 0x0E8 | 1 | `mach_absolute_time` | uint64_t ← (void) | |
| 30 | 0x0F0 | 2 | `thread_switch` | kern_return_t ← (mach_port_name_t, int option, mach_msg_timeout_t) | Gate 2 (`KERN_FAILURE` if lower) |
| 31 | 0x0F8 | 3 | `opendir` | DIR* ← (const char*) | The host supplies a stub that always returns NULL. `dyld_sim` lists directories with `getattrlistbulk` instead |
| 32 | 0x100 | 3 | `readdir_r` | int ← (DIR*, struct dirent*, struct dirent**) | **NULL in the host table.** Reached only after a non-NULL `opendir` |
| 33 | 0x108 | 3 | `closedir` | int ← (DIR*) | **NULL in the host table** |
| 34 | 0x110 | 4 | `coresymbolication_load_notifier` | void ← (void* conn, uint64_t ts, const char* path, const mach_header*) | The host's version does nothing. No caller in `dyld-1378` |
| 35 | 0x118 | 4 | `coresymbolication_unload_notifier` | same as slot 34 | Same as slot 34 |
| 36 | 0x120 | 5 | `proc_regionfilename` | int ← (int pid, uint64_t addr, void* buf, uint32_t size) | Gate 5 |
| 37 | 0x128 | 5 | `getpid` | pid_t ← (void) | Gate 5. Called during configuration |
| 38 | 0x130 | 5 | `mach_port_insert_right` | kern_return_t ← (ipc_space_t, mach_port_name_t, mach_port_t, mach_msg_type_name_t) | Gate 5 |
| 39 | 0x138 | 5 | `mach_port_allocate` | kern_return_t ← (ipc_space_t, mach_port_right_t, mach_port_name_t*) | Gate 5 |
| 40 | 0x140 | 5 | `mach_msg` | mach_msg_return_t ← (hdr*, option, send_size, rcv_size, rcv_name, timeout, notify) | Gate 5 |
| 41 | 0x148 | 6 | `abort_with_payload` | void ← (uint32_t ns, uint64_t code, void* payload, uint32_t size, const char* reason, uint64_t flags) | `dyld_sim`'s `halt()` calls it with namespace `OS_REASON_DYLD`, then halts anyway |
| 42 | 0x150 | 7 | `task_register_dyld_image_infos` | kern_return_t ← (task_t, dyld_kernel_image_info_array_t, mach_msg_type_number_t) | No caller in `dyld-1378` |
| 43 | 0x158 | 7 | `task_unregister_dyld_image_infos` | same as slot 42 | Same as slot 42 |
| 44 | 0x160 | 7 | `task_get_dyld_image_infos` | kern_return_t ← (task_inspect_t, dyld_kernel_image_info_array_t*, mach_msg_type_number_t*) | Same as slot 42 |
| 45 | 0x168 | 7 | `task_register_dyld_shared_cache_image_info` | kern_return_t ← (task_t, dyld_kernel_image_info_t, boolean_t no_cache, boolean_t private_cache) | Same as slot 42 |
| 46 | 0x170 | 7 | `task_register_dyld_set_dyld_state` | kern_return_t ← (task_t, uint8_t) | Same as slot 42 |
| 47 | 0x178 | 7 | `task_register_dyld_get_process_state` | kern_return_t ← (task_t, dyld_kernel_process_info_t*) | Same as slot 42 |
| 48 | 0x180 | 7 / 8 | `task_info` | kern_return_t ← (task_name_t, task_flavor_t, task_info_t, mach_msg_type_number_t*) | Gate **8**. The header lists slots 48–49 under version 7, but the host table and `dyld_sim`'s check use 8 |
| 49 | 0x188 | 7 / 8 | `thread_info` | kern_return_t ← (thread_inspect_t, thread_flavor_t, thread_info_t, mach_msg_type_number_t*) | **Never called.** `dyld_sim`'s `thread_info` wrapper calls slot 48 (`task_info`) by mistake |
| 50 | 0x190 | 8 | `kdebug_is_enabled` | bool ← (uint32_t code) | Gate 8. Called often around tracing |
| 51 | 0x198 | 8 | `kdebug_trace` | int ← (uint32_t code, uint64_t a1, a2, a3, a4) | Gate 8 |
| 52 | 0x1A0 | 9 | `kdebug_trace_string` | uint64_t ← (uint32_t debugid, uint64_t str_id, const char*) | Gate 9 |
| 53 | 0x1A8 | 10 | `amfi_check_dyld_policy_self` | int ← (uint64_t in_flags, uint64_t* out_flags) | Gate 10. If lower, `dyld_sim` assumes out = 0x3F. **Decides whether `DYLD_*` variables are honored** (§3.4) |
| 54 | 0x1B0 | 11 | `notifyMonitorOfMainCalled` | void ← (void) | **Called only if version ≥ 17**, just before `main` |
| 55 | 0x1B8 | 11 | `notifyMonitorOfImageListChanges` | void ← (bool unloading, unsigned count, const mach_header* addrs[], const char* paths[]) | Gate 11. Called on every image-list change, before the debugger notification |
| 56 | 0x1C0 | 12 | `mach_msg_destroy` | void ← (mach_msg_header_t*) | Gate 12 |
| 57 | 0x1C8 | 12 | `mach_port_construct` | kern_return_t ← (ipc_space_t, mach_port_options_ptr_t, mach_port_context_t, mach_port_name_t*) | Gate 12 |
| 58 | 0x1D0 | 12 | `mach_port_destruct` | kern_return_t ← (ipc_space_t, mach_port_name_t, mach_port_delta_t, mach_port_context_t) | Gate 12 |
| 59 | 0x1D8 | 13 | `fstat` | int ← (int, struct stat*) | Gate 13 (−1 if lower). Used by cache preflight |
| 60 | 0x1E0 | 13 | `vm_copy` | kern_return_t ← (vm_map_t, vm_address_t src, vm_size_t, vm_address_t dst) | Gate 13 |
| 61 | 0x1E8 | 14 | `task_dyld_process_info_notify_get` | kern_return_t ← (mach_port_name_array_t names, natural_t* count) | Used only by the remote-notification code, which simulator builds compile out |
| 62 | 0x1F0 | 15 | `fsgetpath` | ssize_t ← (char* buf, size_t, fsid_t*, uint64_t objid) | Gate 15. Resolves `executable_file` and `dyld_file` (§4.3) |
| 63 | 0x1F8 | 16 | `getattrlistbulk` | int ← (int dirfd, void* attrlist, void* buf, size_t, uint64_t opts) | Gate 16. **The wrapper passes the attribute-list pointer as both the 2nd and the 3rd argument.** The real buffer pointer is lost |
| 64 | 0x200 | 17 | `getattrlist` | int ← (const char*, void* attrlist, void* buf, size_t, unsigned int opts) | Gate 17 |
| 65 | 0x208 | 17 | `getfsstat` | int ← (struct statfs*, int bufsize, int flags) | Gate 17 |
| 66 | 0x210 | 17 | `notifyMonitorOfDyldBeforeInitializers` | void ← (void) | **Called only if version ≥ 17**, just before initializers run |
| 67 | 0x218 | 18 | `sysctlbyname` | int ← (const char*, void* old, size_t* oldlen, void* new, size_t newlen) | Gate 18 (−1 if lower). At startup it is used for `hw.optional.arm.caps` (function-variant flags, arm64). The arch-grading code also queries `kern.grade_cputype` |

Behaviors that depend on `version`:

- **Version ≥ 18:** `dyld_sim` no longer calls the legacy
  `dyld_all_image_infos.notification` pointer itself. With a lower version,
  it calls that pointer on every image-list change.
- **Version ≥ 11:** image-list changes are also reported through slot 55.

### 3.3 Reverse direction

- There is **no table that `dyld_sim` hands back to the host.** The only
  values that come back are the return value (`start_sim`) and
  `*startGlue = 1`.
- State is shared through the host's `dyld_all_image_infos`, which
  `dyld_sim` writes directly (§4.5). The host-side callbacks (slots 54, 55,
  and 66) carry notifications in the other direction.
- `dyld_sim` has a fallback for very old hosts (helpers version < 5 or
  < 12). It finds the host dyld through `all_image_infos.dyldImageLoadAddress`
  and `libsystem_kernel` through `infoArray`, then scans their symbol
  tables. A version-18 table never takes this path.

### 3.4 AMFI policy bits (slot 53)

`dyld_sim` calls slot 53 with input flags = `AMFI_DYLD_INPUT_PROC_IN_SIMULATOR`
(bit 0). A nonzero return value means "no permissions" (output treated as
0). Output bits:

| Bit | Name | Effect in `dyld_sim` |
|---|---|---|
| 0 | `ALLOW_AT_PATH` | `@`-path expansion allowed |
| 1 | `ALLOW_PATH_VARS` | **`DYLD_*` path variables from `envp` are processed, including `DYLD_ROOT_PATH`** |
| 2 | `ALLOW_CUSTOM_SHARED_CACHE` | |
| 3 | `ALLOW_FALLBACK_PATHS` | Classic fallback paths |
| 4 | `ALLOW_PRINT_VARS` | `DYLD_PRINT_*` honored |
| 5 | `ALLOW_FAILED_LIBRARY_INSERTION` | (forced on for simulators) |
| 6 | `ALLOW_LIBRARY_INTERPOSING` | |
| 7 | `ALLOW_EMBEDDED_VARS` | `LC_DYLD_ENVIRONMENT` honored |
| 8 | `ALLOW_DEVELOPMENT_VARS` | |
| 9 | `ALLOW_LIBSYSTEM_OVERRIDE` | |

## 4. What `dyld_sim` does on its own

### 4.1 Startup sequence inside `_dyld_sim_prepare`

1. Store the helpers-table pointer in a global.
2. **Self-rebase:** walk its own chained fixups (`LC_DYLD_CHAINED_FIXUPS`
   is required) and add the slide passed in. It uses no table entries for
   this.
3. **Back-solve the kernel argument block:**
   `KernelArgs* = (uint8_t*)argv − 2·sizeof(void*)`. It then **writes the
   main executable's header pointer into that block's first word.**
   - After this point, `argc`, `argv`, `envp`, and `apple` are taken from
     the block (§4.4), not from the parameters.
   - `envp` is the slot after `argv[argc]`'s NULL. `apple` is the slot after
     `envp`'s NULL.
4. "libc" setup:
   - `mach_init`: slot 23.
   - Allocator setup: `vm_allocate` / `vm_protect`.
   - The stack-protector guard comes from `apple[]` `stack_guard=` (hex). In
     the simulator there is no random fallback, so the guard stays 0 if the
     key is absent.
   - A libc subsystem init that takes `apple[]`. It is in a static library
     not in the dyld repo; see §8.
5. Build the externally viewable state:
   - Call `getProcessInfo` (slot 27).
   - Copy the host's existing `infoArray` and `uuidArray` into its own
     storage.
   - Repoint the host struct's `infoArray`/`uuidArray` at that storage.
   - Set `infoArrayChangeTimestamp` = `mach_absolute_time()`.
6. Build the process configuration (§4.3). This includes loading the
   simulator shared cache (§4.2) and the security, logging, and path
   overrides.
7. Make its own `__DATA_CONST` read-only (slot 16).
8. `prepare()`: load the main executable's dependency closure, bind it, run
   initializers, and return `main` (§5).
9. Set `*startGlue = 1`, remember the real `main`, and return `start_sim`.

### 4.2 Mapping the simulator shared cache

`dyld_sim` maps the cache **itself, privately, through the helpers**. No
special syscall is involved. It does not use `shared_region_check_np`,
`shared_region_map_and_slide_2_np`, or `map_with_linking_np`: in simulator
builds those paths are compiled out, and the host has already detached the
shared region.

1. **Find the directory.** If `DYLD_ROOT_PATH` is set, open
   `$DYLD_ROOT_PATH/System/Library/Caches/com.apple.dyld/` (helper `open`).
   - If `…/dyld_sim_shared_cache_<arch>` exists there (`stat`), use it. This
     is a "prebuilt" cache.
   - Otherwise, open `DYLD_SHARED_CACHE_DIR` if that variable is set.
   - Otherwise, open `/System/Library/Caches/com.apple.dyld/`.

   `<arch>` is `arm64` or `x86_64`. The `.development` variant is used only
   on non-simulator embedded builds.
2. **Opt-out.** `DYLD_SHARED_REGION=avoid` disables the cache, except for
   prebuilt caches, where it is ignored with a warning. On arm64, if the
   main executable intersects `[0x1_8000_0000, +4 GB)`, `dyld_sim` behaves
   as if `avoid` were set.
3. **Preflight each cache file** (main file, then each subcache named
   `<base><suffix>` from the main header's subcache array; at most
   `MAX_SUBCACHES`):
   1. Open the file relative to the directory. This is emulated as
      `F_GETPATH` plus `open`, retried on EAGAIN/EINTR, which `dyld_sim`
      reads through the `errno` cell.
   2. `fstat` the file. `pread` its first **0x4000** bytes.
   3. Check the magic: `"dyld_v1   arm64"` for arm64, `"dyld_v1  x86_64"`
      for x86-64.
   4. Check the platform: the header `platform` (or `altPlatform`) must equal
      the process platform, and the header **`simulator` flag must be
      nonzero**. Very old headers, with `mappingOffset < 0xE0`, are exempt.
   5. Check the mapping table:
      - `1 ≤ mappingCount ≤ MaxMappings`;
      - mapping 0 has file offset 0;
      - `codeSignatureOffset + codeSignatureSize == file size`;
      - the last mapping is read-only;
      - mapping 0's max protection is R-X (or R for a linkedit-only file);
      - mappings are contiguous in the file and do not overlap in VM.
   6. Register the signature: `fcntl(F_ADDFILESIGS_RETURN = 97)` with
      `fs_file_start = 0`, `fs_blob_start = codeSignatureOffset`, and
      `fs_blob_size = codeSignatureSize`. The returned `fs_file_start` must
      be ≥ `codeSignatureOffset`.
   7. `mmap` the first 0x4000 bytes R-X and private, compare them with the
      bytes from `pread`, then `munmap`.
4. **Map.**
   - The simulator **never slides**: slide = 0. The cache builder also emits
     no slide info for simulator caches, so data pointers on disk are final.
   - Each mapping *j* of each file is mapped with `mmap(MAP_FIXED |
     MAP_PRIVATE)` from that file's fd and file offset, with the mapping's
     init protection translated to PROT bits.
   - Target address = **`SHARED_REGION_BASE` + (mapping.address −
     address of the main file's first mapping)**. `SHARED_REGION_BASE` is a
     compile-time constant: `0x1_8000_0000` for arm64 and
     `0x7FF8_0000_0000` for x86-64 in public xnu.
   - The cache's load address is recorded as the main file's first mapping
     address (unslid). This agrees with the target address only if the cache
     was built at `SHARED_REGION_BASE`. See §8.
   - `__DATA_CONST` mappings are mapped writable when read-only data-const is
     off. `__TPRO_CONST` mappings are mapped RW.
   - **No fixups are applied to the cache in the simulator.** The rebase loop
     is compiled out.
5. **Dynamic region.**
   - `mmap(MAP_ANON | MAP_FIXED | MAP_PRIVATE, RW)` one **0x4000-byte**
     page at `sharedRegionStart + dynamicDataOffset` (header fields).
   - Write the magic, the cache path, the file ID, and the function-variant
     flags. The processor flags come from `sysctlbyname("hw.optional.arm.caps")`
     on arm64.
   - Then `mprotect` the page read-only, which goes to `vm_protect`.
6. **Close the fds.** All files stay mapped.
7. Copy the cache info into `all_image_infos` (§4.5):
   - `sharedCacheSlide` = 0;
   - `sharedCacheBaseAddress` = the unslid base;
   - the cache file's `st_dev`/`st_ino`;
   - `processDetachedFromSharedRegion` = 1 (private cache);
   - `sharedCacheUUID`.

### 4.3 Inputs read from `envp`, `apple[]`, and the commpage

**`apple[]` keys** read by `dyld_sim` (`key=value` strings, looked up by
prefix):

| Key | Value format | Use |
|---|---|---|
| `executable_path` | path | Main executable's path. If absent, `argv[0]` is used. A relative path is made absolute with `getcwd` (a leading `./` is dropped). It is the source of `progname` and of the realpath'd executable path |
| `executable_file` | `0x<fsid>,0x<objid>` (hex) | If present, `fsgetpath` gives the canonical executable path |
| `dyld_file` | `0x<fsid>,0x<objid>` | If present, `fsgetpath` gives `dyldPath`. The default is `/usr/lib/dyld` |
| `stack_guard` | hex digits | `__stack_chk_guard` seed |

Keys present in the source but **inert in simulator builds**:

- `dyld_hw_tpro` and `dyld_hw_tpro_pagers`: hard-wired off for the
  simulator;
- `ptrauth_disabled`: arm64e only;
- `dyld_flags`: pid 1 on internal installs only;
- `executable_cdhash` and `executable_boothash`: prebuilt-loader code,
  compiled out of the simulator.

**Not found in the dyld sources:** `ptr_munge`, `main_stack`, `th_port`,
`malloc_entropy`, `pfz`, and similar keys. These are read by libSystem
components (libpthread, libmalloc, libplatform), not by dyld. They need a
separate spec.

**Environment variables** read by `dyld_sim`:

| Variable | Gate | Use |
|---|---|---|
| `DYLD_ROOT_PATH` | read directly for the cache directory and for `dyld_sim`'s own file ID. Used as the path-override root only with AMFI bit 1 | The runtime root (§4.2). It prefixes absolute paths, rpaths, and cache-image paths during dylib lookup. `dyld_sim` also `stat`s `$DYLD_ROOT_PATH/usr/lib/dyld_sim` and uses its `st_dev` as the simulator device ID |
| `DYLD_SHARED_CACHE_DIR` | — | Cache directory fallback (§4.2) |
| `DYLD_SHARED_REGION` | — | `avoid` disables the cache (not for prebuilt caches) |
| `SIMULATOR_ROOT` | — | If `$SIMULATOR_ROOT/AppleInternal` is a directory, the process counts as an "internal OS" (enables `DYLD_OVERLAY_PATH`) |
| `DYLD_LIBRARY_PATH`, `DYLD_FRAMEWORK_PATH`, `DYLD_FALLBACK_LIBRARY_PATH`, `DYLD_FALLBACK_FRAMEWORK_PATH`, `DYLD_VERSIONED_LIBRARY_PATH`, `DYLD_VERSIONED_FRAMEWORK_PATH`, `DYLD_INSERT_LIBRARIES`, `DYLD_IMAGE_SUFFIX` | AMFI bit 1 | Standard dyld path overrides |
| `DYLD_OVERLAY_PATH` | AMFI bit 1 and internal OS | |
| `DYLD_PRINT_SEGMENTS`, `_LIBRARIES`, `_BINDINGS`, `_INITIALIZERS`, `_APIS`, `_NOTIFICATIONS`, `_INTERPOSING`, `_LOADERS`, `_SEARCHING`, `_FUNCTION_VARIANTS`, `_ENV`, `_TO_STDERR`, `_TO_FILE`, `_LINKS_WITH`, `_BAD_ROOTS` | AMFI bit 4 | Diagnostics, output through `vlog`/`write` |
| `DYLD_JUST_BUILD_CLOSURE` | — | Read, but the action is compiled out in the simulator |
| `DYLD_SKIP_MAIN`, `DYLD_AMFI_FAKE`, `DYLD_PAGEIN_LINKING` | internal install only | Never active: `dyld_sim`'s internal-install check is hard-wired to false |

`DYLD_FALLBACK_*` and `HOME` (and the `_DYLD_CLOSURE_HOME` seen on macOS)
have no closure-saving effect in the simulator, because on-disk prebuilt
loaders are compiled out.

**Commpage:**

- `dyld_sim` reads exactly one commpage field directly, with no helper: the
  **64-bit dyld flags word at `_COMM_PAGE_DYLD_FLAGS`**. The address is
  `0x0000_000F_FFFF_C160` on arm64 (commpage base `0xF_FFFF_C000` + 0x160)
  and `0x0000_7FFF_FFE0_0100` on x86-64 (base `0x7FFF_FFE0_0000` + 0x100).
- Bit meanings (from `DyldCommPage`). The low 32 bits come from the
  `dyld_flags` boot-arg:

  | Bit | Meaning |
  |---|---|
  | 0 | forceCustomerCache |
  | 1 | testMode |
  | 2 | forceDevCache |
  | 3 | skipIgnition |
  | 4 | useSystemCache |
  | 5 | useSystemDriverKitCache |
  | 6 | logRoots |
  | 7 | disablePageInLinking |
  | 8 | disableSwiftPrespecData |
  | 9 | disableProdSimChecks |
  | 18 | enableAtlasUsage |
  | 19 | disableAtlasUsage |
  | 20 | forceRODataConst |
  | 21 | forceRWDataConst |
  | 32 | libPlatformRoot |
  | 33 | libPthreadRoot |
  | 34 | libKernelRoot |
  | 35 | bootVolumeWritable |
  | 36 | foundRoot |

  All zeros means "defaults". Bit 9 matters only to the host. `dyld_sim`
  consults bit 8, for Swift prespecialization data.
- No other commpage reads appear in the simulator configuration of the dyld
  sources. The DTrace-enabled byte and the dev-firmware word are read only in
  non-simulator builds.

### 4.4 Process state expected at entry

**Kernel argument block.** `dyld_sim` relies on the layout the kernel
creates for a new process. It writes to the first word of the block and
re-derives `argc`, `envp`, and `apple` from it.

| Offset from block start | Content |
|---|---|
| 0 | main executable's `mach_header*` |
| 8 | `argc` (as a 64-bit word) |
| 16 | `argv[0]` … `argv[argc−1]`, then NULL |
| … | `envp[0]` … , then NULL |
| … | `apple[0]` … , then NULL |
| above | the string area that the pointers point into |

- The `argv` passed in `x1` must equal block + 16. dyld supports at most
  128 pointer slots (`MAX_KERNEL_ARGS`) when it constructs the block itself.
  That limit applies only to dyld's own tools; the kernel-built block has no
  such limit.
- **Stack.** Ordinary C entry: SP 16-byte aligned, with the 9th argument at
  `[sp]` (arm64). On macOS, `dyld_sim` runs on the main thread's stack below
  the host's frames. It needs no other stack setup.
- **Registers.** Only the argument registers are meaningful. The frame
  pointer and return address are the caller's, and `dyld_sim` never returns
  through them in practice.
- **TSD (`TPIDRRO_EL0`).** No dyld source path reads or sets the thread
  pointer before libSystem runs. dyld's locks go through libdyld's helper
  object only after `libdyld` is wired up. The thread pointer is set later by
  libSystem's initializer (libpthread), which is outside the dyld repo. The
  value at entry on macOS is whatever the host process has, because the host
  dyld never initializes libSystem in a simulator process. See §8.
- **Page size.**
  - `dyld_sim` defines `vm_page_size` = 0x1000 and `vm_kernel_page_mask` =
    0xFFF for its static libraries.
  - Its allocator assumes 16 KB granularity (`kPageSize` = 16384).
  - The cache preflight reads 0x4000 bytes.
  - The dynamic region is 0x4000 bytes.
  - Mapping sizes and offsets come from the cache's mapping table, which is
    16 KB-aligned for arm64.

### 4.5 The shared `dyld_all_image_infos`

`dyld_sim` has no `dyld_all_image_infos` of its own. It reads and writes the
struct whose address slot 27 returns. LP64 layout (368 bytes; the simulator
build does not assume 16-byte alignment):

| Off | Field | `dyld_sim` access |
|---|---|---|
| 0 | `version` u32 | not read |
| 4 | `infoArrayCount` u32 | read at start (copy), then written |
| 8 | `infoArray` ptr | read at start, then written. Set to NULL while an update is in progress |
| 16 | `notification` fn ptr | **called only when helpers version < 18** |
| 24 | `processDetachedFromSharedRegion` u8 | written (1) |
| 25 | `libSystemInitialized` u8 | written (1) after libSystem's initializer |
| 32 | `dyldImageLoadAddress` ptr | read only on the pre-v5 fallback path |
| 40–80 | `jitInfo`, `dyldVersion`, `errorMessage`, `terminationFlags`, `coreSymbolicationShmPage`, `systemOrderFlag` | not used by the simulator paths read |
| 88 | `uuidArrayCount` uintptr | read and written |
| 96 | `uuidArray` ptr | read and written |
| 104–144 | `dyldAllImageInfosAddress`, `initialImageCount`, `errorKind`, three error strings | — |
| 152 | `sharedCacheSlide` | written |
| 160 | `sharedCacheUUID[16]` | written |
| 176 | `sharedCacheBaseAddress` | written |
| 184 | `infoArrayChangeTimestamp` u64 | written |
| 192 | `dyldPath` ptr | — |
| 200 | `notifyPorts[8]` u32 | not used by the simulator (Mach-port notifications are compiled out) |
| 232 | `reserved[7]` | — |
| 288 | `sharedCacheFSID` u64 | written |
| 296 | `sharedCacheFSObjID` u64 | written |
| 304 | `compact_dyld_image_info_addr`, 312 `…_size` | not generated by the simulator |
| 320 | `platform` u32 | written (the process platform) |
| 324–367 | AOT (Rosetta) fields | — |

Element layouts: `dyld_image_info` = {`imageLoadAddress`, `imageFilePath`,
`imageFileModDate`} (24 bytes). `dyld_uuid_info` = {`imageLoadAddress`,
`uuid[16]`} (24 bytes).

What the host has in the struct when it calls `dyld_sim` (new runtimes):

- `infoArray` holds the **main executable** (path from the kernel and its
  load address);
- `uuidArray` holds the main executable's UUID, plus the host dyld's UUID
  when the host dyld is not itself in the macOS shared cache;
- `initialImageCount` = 1;
- `notification` = the host's sim trap function.

## 5. Order of operations up to `main`

Steps on the host, at the start of a simulator process:

1. The kernel maps the main executable and the host dyld, builds the block
   (§4.4) at SP, and enters the host's `__dyld_start`.
2. The host's `__dyld_start` passes SP as the `KernelArgs*`, aligns SP to 16
   bytes, and clears the frame pointer and link register (arm64). It then
   calls `start`.
3. `start`:
   - rebases the host dyld;
   - initializes the host's libc pieces;
   - builds the configuration (no macOS cache for simulator processes);
   - calls `prepare()` → `prepareSim()` (§1).
4. The host calls `_dyld_sim_prepare` (§2.3).

Steps in `dyld_sim` (§4.1):

5. Self-rebase, then `KernelArgs` back-solve, then `mach_init`, the
   allocator, and the stack guard. Then copy `all_image_infos`, then the
   configuration, which includes mapping the shared cache (§4.2).
6. `prepare()` in `dyld_sim`:
   - The main executable must have `LC_MAIN`. Pre-`LC_MAIN` support exists
     only in x86-64 macOS builds, so a missing `LC_MAIN` halts.
   - Create the main loader and add it to the image list, notifying the
     debugger.
   - Load `DYLD_INSERT_LIBRARIES` and all dependents. Shared-cache images
     come from the mapped cache; others are mapped from disk under the root.
   - Apply fixups and bind.
   - Find `libdyld.dylib` (halt if missing) and wire it up:
     - store the runtime-API object pointer into libdyld's
       `__TPRO_CONST,__dyld_apis` section;
     - read libdyld's helper object from `__DATA_CONST,__helper`, which
       must report version ≥ 7.
   - Set the program variables (`mh`, `NXArgc`, `NXArgv`, `environ`,
     `__progname`).
   - **Require `libSystem.B.dylib`** (halt if missing).
   - Report the remaining images to the debugger and monitors (slot 55).
7. Initializers:
   - `notifyMonitorOfDyldBeforeInitializers` (slot 66, version ≥ 17);
   - **libSystem's initializer first**, then mark `libSystemInitialized`;
   - ObjC init notification for libSystem;
   - initializers of every image below libSystem;
   - all other images bottom-up, with inserted dylibs first and the main
     executable last.
   - Each initializer is called as `init(argc, argv, envp, apple,
     &ProgramVars)`, where `ProgramVars` = {`mh`, `int* NXArgcPtr`,
     `const char*** NXArgvPtr`, `const char*** environPtr`,
     `const char** __prognamePtr`}.
   - libdyld's own initialization runs inside libSystem's initializer. It
     creates the dlerror pthread key, sets up TLVs, and turns on allocator
     locking "now that TSDs work".
8. `notifyMonitorOfMainCalled` (slot 54, version ≥ 17). Set the process
   state to "program running".
9. Find the main executable's entry (`LC_MAIN.entryoff` + header address).
   Return it from `prepare()`. `_dyld_sim_prepare` returns `start_sim`
   (§2.4).

Steps back on the host:

10. The host `start` calls `start_sim(argc, argv, envp, apple)`.
11. `start_sim` calls the program's `main` with **arm64 `x0`=argc,
    `x1`=argv, `x2`=envp, `x3`=apple** (x86-64: `rdi`, `rsi`, `rdx`,
    `rcx`).
12. When `main` returns, `start_sim` calls the simulator libSystem `exit`.

Where the start glue sits:

- There is no assembly start glue in `dyld_sim`. `dyld_sim` has no
  `__dyld_start` in simulator builds.
- The glue is the C function `start_sim` inside `dyld_sim`, called from the
  host's C `start`.

## 6. arm64 vs x86-64, and version gating

### 6.1 Architecture differences

| Topic | arm64 | x86-64 |
|---|---|---|
| Entry arguments 7–9 (§2.3) | `x6`, `x7`, `[sp]` | `[rsp+8]`, `[rsp+16]`, `[rsp+24]` |
| Variadic helper arguments (`open` mode, `fcntl`/`ioctl` third argument) | **On the stack** (Apple arm64 ABI: variadic arguments always go on the stack, in 8-byte slots) | In registers (System V), with `al` = number of vector registers |
| `va_list` passed to `vlog`/`vwarn` | a plain pointer into the stacked arguments | System V `va_list` (pointer to a 24-byte struct) |
| `LC_UNIXTHREAD` PC | flavor 6, word 32 | flavor 4, word 16 |
| Cache magic / file | `dyld_v1   arm64` / `dyld_sim_shared_cache_arm64` | `dyld_v1  x86_64` / `dyld_sim_shared_cache_x86_64` |
| `SHARED_REGION_BASE` | `0x1_8000_0000` | `0x7FF8_0000_0000` |
| Commpage dyld flags | `0xF_FFFF_C160` | `0x7FFF_FFE0_0100` |
| Cache-overlap "avoid" check | yes (main executable vs `[0x1_8000_0000, +4 GB)`) | no |
| Processor function-variant flags | `sysctlbyname("hw.optional.arm.caps")` | CPU-feature probe (x86 table) |
| Simulator cache size cap (builder) | 4 GB, contiguous layout | discontiguous layout, 1 GB regions |

### 6.2 Version gating that matters for 2025–2026 `dyld`

- Helpers version **18** is current from `dyld-1284.13` through
  `dyld-1378`. Slot 67 (`sysctlbyname`) is called during configuration when
  the version is ≥ 18. A table with version 17 makes it return −1, which
  disables processor function variants.
- At version ≥ 18, `dyld_sim` relies on the host for debugger breakpoint
  notifications and never calls `all_image_infos.notification`.
- Slots 54 and 66 are called only at version ≥ 17, even though slots 54–55
  arrived in version 11.
- Host compatibility steps (§1.4 step 7) apply only to simulator runtimes
  with an epoch ≤ fall 2022.
- `start_sim` and `*startGlue = 1` have been present since at least
  `dyld-1042.1`.

## 7. Implications for Ycode

Ycode has no host dyld. **The Ycode loader plus the VMM play the host
dyld's part, and the kernel's part too.** Everything below is Ycode design
derived from §1–§6.

### 7.1 What the loader must build before the first EL0 instruction

1. **The main executable**, mapped by segment at its preferred address. The
   executable has a 4 GB `__PAGEZERO`, so the usual base is
   `0x1_0000_0000`. This is the kernel's job on macOS. Fixups are left to
   `dyld_sim`.
2. **`dyld_sim`**, mapped exactly as in §1.3:
   - one reservation of `mappedSize`, zero-filled;
   - each file-backed segment at `vmaddr − preferred + base`, with
     `initprot`;
   - zero-fill segments RW;
   - no fixups.

   Choose a base that is clear of the main executable, the region
   `[0x1_8000_0000, +4 GB)`, and the commpage. Compute the entry from
   `LC_UNIXTHREAD` (or `LC_MAIN`) as in §2.2.
3. **The kernel argument block** at the top of a 16 KB-aligned guest stack,
   laid out as in §4.4, with:
   - `envp` containing at least `DYLD_ROOT_PATH`. Optional:
     `DYLD_SHARED_CACHE_DIR`, `SIMULATOR_ROOT`, and the CoreSimulator
     variables from `research/notes/simulator-observations.md`.
   - `apple[]` containing at least `executable_path=<absolute guest path>`
     and `stack_guard=<random hex>`. Leave `executable_file` and `dyld_file`
     out until `fsgetpath` exists. Then dyld falls back to `realpath` and
     `/usr/lib/dyld`.
4. **A Ycode "host page"** (EL0 read-only and executable, plus one EL0 RW
   page) that holds:
   - the 544-byte helpers table, `version = 18`;
   - a 368-byte `dyld_all_image_infos`:
     - `version` 17;
     - `infoArray` = one entry for the main executable;
     - `uuidArray` = one entry for the main executable;
     - `initialImageCount` 1;
     - `notification` = a `ret` stub;
   - an `int` errno cell;
   - a mutex-free implementation of the stubs in §7.3.

   The page must not overlap the cache range or the main executable.
5. **The commpage** at `0xF_FFFF_C000`. Stage 2 already maps it zero-filled.
   `dyld_sim` reads only the u64 at +0x160, and all zeros is correct.
6. **Initial vCPU state** through the stage-2 boot info:
   - PC = `dyld_sim` entry;
   - `x0`–`x7` as in §2.3;
   - SP = 16-byte aligned, below the block, with `[sp]` = the address of an
     8-byte `startGlue` cell;
   - `x30` (LR) = a stub that raises a Ycode-private "dyld_sim returned"
     trap;
   - `TPIDRRO_EL0` = 0 (see §8).

### 7.2 Doing the host's `start` after the return

- When the "returned" trap fires, `x0` holds the `start_sim` pointer. The
  VMM sets PC = `x0` and `x0`–`x3` = `argc`, `argv`, `envp`, `apple`. It
  re-reads `argc` from the block, because `dyld_sim` may have rewritten
  block word 0.
- It sets LR to a stub that traps as "main returned" (treated as
  `_exit(x0)`), and resumes.
- Alternative: put a tiny EL0 trampoline in the host page that calls the
  entry and then calls the result. This needs no VMM round trip.
- In practice the process ends through the simulator libSystem's `exit`.
  That is a raw BSD `exit` (1), which stage 2 already services.

### 7.3 Servicing the helpers: three kinds of EL0 stub

Every helper is an ordinary C-ABI function pointer, so each slot points to a
small EL0 stub in the host page. **A stub must follow the Apple arm64
calling convention:** for `open`, `fcntl`, and `ioctl`, read the third
argument from `[sp]`, not from `x2`.

1. **Pure EL0 stubs** (no trap):

   | Slot | Behavior |
   |---|---|
   | `getProcessInfo` | return the struct's address |
   | `errnoAddress` | return the errno cell |
   | `OSAtomicCompareAndSwapPtrBarrier` | `casal` or an `ldaxr`/`stlxr` loop |
   | `OSMemoryBarrier` | `dmb ish` |
   | `pthread_mutex_lock` / `pthread_mutex_unlock` | return 0 (single thread) |
   | `issetugid` | return 0 |
   | `kdebug_is_enabled` | return 0 |
   | `kdebug_trace`, `kdebug_trace_string` | return 0 |
   | the coresymbolication slots and slots 54, 55, 66 | `ret`. Slot 55 can later trap for logging |
   | `amfi_check_dyld_policy_self` | store the output flags and return 0. Recommended output **0xFF** (bits 0–7); minimum **0x02**. **If bit 1 is missing, `DYLD_ROOT_PATH` is ignored for path lookup** |
   | `opendir` | return NULL |
   | `readdir_r`, `closedir` | NULL slots, as on the macOS host |
   | `task_register_dyld_*`, `task_get_dyld_image_infos`, `task_dyld_process_info_notify_get` | return `KERN_SUCCESS` (0) or `KERN_NOT_SUPPORTED`. Not called by `dyld-1378` |

2. **Forwarding stubs** that issue the matching real Darwin trap, which the
   VMM must implement anyway. For BSD calls, the stub converts the result:
   carry set → store `x0` into the errno cell and return −1 (NULL for
   pointer results). The trap numbers come from public xnu (`syscalls.master`,
   `syscall_sw.c`). Mach traps are negative.

   | Helper | Trap |
   |---|---|
   | `open` | 5 (mode moved from `[sp]` to `x2`) |
   | `close` | 6 |
   | `pread` | 153 |
   | `write` | 4 |
   | `mmap` | 197 |
   | `munmap` | 73 |
   | `madvise` | 75 |
   | `stat` | `stat64` 338 |
   | `fstat` | `fstat64` 339 |
   | `fcntl` | 92 (argument from `[sp]`) |
   | `ioctl` | 54 (argument from `[sp]`) |
   | `getpid` | 20 |
   | `fsgetpath` | 427 |
   | `getattrlist` | 220 |
   | `getattrlistbulk` | 461 |
   | `getfsstat` | `getfsstat64` 347 |
   | `abort_with_payload` | 521 |
   | `mach_absolute_time` | −3 |
   | `task_self_trap` | −28 |
   | `mach_thread_self` | `thread_self_trap` −27 |
   | `mach_port_deallocate` | −18 |
   | `mach_port_allocate` | −16 |
   | `mach_port_insert_right` | −21 |
   | `mach_port_construct` | −24 |
   | `mach_port_destruct` | −25 |
   | `vm_allocate` | −10 |
   | `vm_deallocate` | −12 |
   | `vm_protect` | −14 |
   | `mach_msg` | `mach_msg_trap` −31 |
   | `thread_switch` | −61 |
   | `mach_timebase_info` | −89 |

   Notes on the Mach traps:
   - The `_kernelrpc_*` traps take the target task port first, like the
     helper signatures.
   - Kernel `sysctlbyname` (274) takes an extra `namelen` argument, so its
     stub must compute `strlen`. Alternatively, send it through a private
     trap.
3. **Ycode-private traps** for helpers that have no single Darwin trap or
   need host logic:

   | Helper | Behavior |
   |---|---|
   | `vlog`, `vwarn` | format with the arm64 `va_list` (a stack pointer), or just log the format string at first |
   | `realpath`, `getcwd` | resolved in Ycode's path namespace |
   | `vm_copy` | |
   | `proc_regionfilename` | |
   | `task_info`, `thread_info` | |
   | `mach_msg_destroy` | |

   Use `svc #0x80` with an `x16` value outside every Darwin range, so one
   dispatcher handles both kinds of trap.

### 7.4 VMM behaviors that the helpers imply

- **File-backed `mmap`:**
  - `MAP_FIXED | MAP_PRIVATE` with `PROT_EXEC`, at any 16 KB-aligned
    address and offset;
  - many ranges from the same fd;
  - mappings that stay valid after `close`;
  - `MAP_ANON | MAP_FIXED` for the dynamic region.

  Darwin flag values: `MAP_PRIVATE` 0x2, `MAP_FIXED` 0x10, `MAP_ANON`
  0x1000; `PROT_READ`/`PROT_WRITE`/`PROT_EXEC` = 1/2/4.
- **`fcntl`:**
  - `F_GETPATH` (50): writes the fd's guest path. This is needed because
    `openat` is emulated with it.
  - `F_ADDFILESIGS_RETURN` (97): must succeed and **write back
    `fs_file_start` ≥ the requested `fs_blob_start`**, for example the file
    size. `fsignatures` layout: `fs_file_start` off_t @0, `fs_blob_start`
    ptr @8, `fs_blob_size` size_t @16.
  - `F_CHECK_LV` (98): return 0.
  - `F_SETFD` (2).
- **`vm_protect` and `vm_allocate`:**
  - `vm_protect`: mask off `VM_PROT_COPY` (0x10).
  - `vm_allocate` with `VM_FLAGS_ANYWHERE` (1): ignore the VM-tag byte and
    return zeroed memory. The allocator first hints at addresses ≥ 4 GB.
- **`struct stat`:** fill the 144-byte Darwin `stat64` layout:
  - `st_dev` u32 @0, `st_mode` u16 @4, `st_ino` u64 @8, `st_mtimespec` @48,
    `st_size` @96.
  - `dyld_sim` uses `st_size`, `st_dev`, `st_ino`, and `st_mtime`.
- **errno:** the forwarding stubs write the errno cell. `dyld_sim` checks
  `ENOENT` for a missing cache and `EAGAIN`/`EINTR` for a retried open.
- **Path namespace:** `DYLD_ROOT_PATH` must be a non-empty absolute path in
  whatever namespace the file helpers use. `dyld_sim` concatenates strings
  (`<root>/usr/lib/dyld_sim`, `<root>/System/Library/Caches/com.apple.dyld/`,
  `<root>` + absolute path). The simplest model mirrors macOS: the guest sees
  host-like absolute paths, and `DYLD_ROOT_PATH` names the RuntimeRoot
  directory.

### 7.5 Top five takeaways

1. The entry is
   `_dyld_sim_prepare(argc, argv, envp, apple, mainMH, simMH, simSlide,
   helpers, &startGlue)`, with the 9th argument at `[sp]`. It returns
   `start_sim`, which Ycode then calls as `main`.
2. `argv` must point into a real kernel-format block, because `dyld_sim`
   writes `argv[−2]`.
3. Most helpers are tiny EL0 stubs that forward to Darwin traps the VMM
   already plans to support. `dyld_sim` itself makes no raw syscalls in the
   open-source code; the commpage word is its only direct kernel touch-point.
4. `dyld_sim` maps the cache itself with `mmap(MAP_FIXED)` through the
   helpers, with no slide and no fixups. The VMM's file-backed `mmap` and
   `F_ADDFILESIGS_RETURN` must therefore be solid.
5. The AMFI helper must grant bit 1, or `DYLD_ROOT_PATH` rerooting silently
   turns off.

## 8. Open questions

1. **Shared-cache base.** In `dyld-1378`, the private simulator mapping is
   placed at the compiled-in `SHARED_REGION_BASE` plus offsets, and the
   cache is recorded at mapping 0's address. Public xnu gives
   `0x1_8000_0000` for arm64. `specs/simulator/darwin-arm64-abi.md` §5
   records `0x1_C000_0000` for the iOS 27.1 cache (level 4). Possible
   explanations:
   - the iOS 27.1 `dyld_sim` is newer than `dyld-1378`;
   - the iOS-simulator SDK's `shared_region.h` differs;
   - the earlier observation refers to a different mapping.

   To resolve it, check mapping 0's address and `sharedRegionStart` with
   `ycode dsc`, and trace `dyld_sim`'s first fixed `mmap` in stage 3.
   Whatever the answer, Ycode must honor the exact `MAP_FIXED` address it is
   given.
2. **Raw syscalls from static libraries.** `dyld_sim` links static archives
   from the SDK's `usr/local/lib/dyld/` (libc and others) that are not in the
   dyld repo. They may issue `svc #0x80` directly. Examples are
   `_subsystem_init(apple)` and `_simple_dprintf`. The micro-VM traps these
   anyway. Record them during stage 3 tracing.
3. **TSD at entry.** No dyld path needs `TPIDRRO_EL0` before libSystem's
   initializer. Confirm that 0 is acceptable. Also confirm the platform-call
   selector for `thread_set_cthread_self` (open in
   `darwin-arm64-abi.md`), which libpthread will use.
4. **`dyld_sim`'s entry load command.** Ycode supports both commands. A
   level-4 check of the iOS 27.1 `dyld_sim` with `ycode macho` should record
   which one is present. `-dylinker` output is expected to carry
   `LC_UNIXTHREAD`.
5. **iOS 27.1 `dyld_sim` vs `dyld-1378`.** The runtime is probably built from
   a later dyld. Every slot added after version 1 is version-gated, so a
   version-18 table stays safe even if a newer `dyld_sim` knows about a
   version 19. Check for new required behavior during stage 3.
6. **`apple[]` keys consumed by libSystem** (`ptr_munge`, `main_stack`,
   `malloc_entropy`, `th_port`, …). These are needed before `main`. Spec them
   from the libpthread, libmalloc, Libsystem, and libplatform open source in
   a follow-up.
7. **`F_CHECK_LV` and code-signature expectations** for non-cache images
   that `dyld_sim` loads from disk under the root (`Loader` path). Confirm
   that returning success for every signature `fcntl` is enough.
8. **The `getattrlistbulk` wrapper defect** (§3.2 slot 63) means directory
   enumeration through `dyld_sim` cannot work as written. Confirm that no
   startup path depends on it. It is used for the `DYLD_VERSIONED_*` and
   roots scans.

## Evidence

All facts are level 1 unless noted.

- `apple-oss-distributions/dyld`, tag **`dyld-1378`** (the tarball of the
  tag; `main` HEAD `fd8d0c4d` is the same import):
  - `dyld/dyldSyscallInterface.h`: the `SyscallHelpers` slot list, order,
    and version comments (§3).
  - `dyld/dyldMain.cpp`:
    - the host table `sSysCalls` (version 18, slot values, NULL slots);
    - `prepareSim` (§1.2–§1.4);
    - the detection branches in `prepare()` (§1.1);
    - the entry typedef and call (§2.3);
    - `_dyld_sim_prepare`, `start_sim`, `rebaseSelf`, and
      `lockdownDyldDataConst` (§2.4, §4.1);
    - `initializeLibc`;
    - host `start` calling `appMain` (§2.5, §5);
    - libdyld wiring and the entry lookup at the end of `prepare()` (§5).
  - `dyld/glue.c`:
    - the simulator wrappers and their version gates (§3.2);
    - the `openat` emulation;
    - `mprotect` → `vm_protect`;
    - `__guard_setup` (`stack_guard`);
    - `mach_init`;
    - `vm_page_size` = 0x1000;
    - the `thread_info` and `getattrlistbulk` wrapper defects;
    - the old-host symbol-scan fallback;
    - the AMFI fallback 0x3F.
  - `dyld/DyldProcessConfig.{h,cpp}`:
    - the `KernelArgs` layout and `findArgv`/`findEnvp`/`findApple`;
    - the `Process` constructor;
    - the `apple[]` keys `executable_path`, `executable_file`, `dyld_file`,
      `ptrauth_disabled`, `dyld_hw_tpro*`, and `dyld_flags`;
    - `getDyldSimFileID`;
    - `SIMULATOR_ROOT`;
    - the Security/AMFI bits;
    - `PathOverrides` (`DYLD_ROOT_PATH` gated on simulator platform and AMFI
      bit 1);
    - `CacheFinder` and the `DyldCache` constructor (cache directory, `avoid`
      mode, the arm64 0x180000000 overlap check, `forcePrivate` for the
      simulator, the host skipping the cache);
    - the function-variant evaluation (`hw.optional.arm.caps`);
    - `halt` (`abort_with_payload`);
    - `ProgramVars` and the `Initializer` typedef.
  - `dyld/DyldDelegates.{h,cpp}`:
    - `amfiFlags` (simulator input bit);
    - `internalInstall` false in the simulator;
    - `dyldCommPageFlags` (direct commpage read) and the `DyldCommPage` bit
      layout;
    - the `F_GETPATH` and `F_ADDFILESIGS_RETURN` uses;
    - `forEachInDirectory` via `getattrlistbulk`.
  - `dyld/SharedCacheRuntime.cpp`:
    - `validMagic`, `validPlatform` (the `simulator` header flag);
    - `preflightCacheFile`;
    - `getCachePath`;
    - `mapSplitCachePrivate` (slide 0 for the simulator, `SHARED_REGION_BASE`
      placement, the fixups compiled out);
    - `loadDyldCache`;
    - `deallocateExistingSharedCache`.
  - `dyld/ExternallyViewableState.{h,cpp}`:
    - the simulator constructor (copying the host's `infoArray`/`uuidArray`);
    - `triggerNotifications` (slot 55 gate 11, legacy notifier gate < 18);
    - `notifyMonitorOfMainCalled` and `…BeforeInitializers` (gate 17);
    - `setRuntimeState` (cache fields written);
    - `addDyldSimInfo`, `createMinimalInfo`, `setLibSystemInitialized`;
    - the design-note comment describing the host/`dyld_sim` split.
  - `dyld/DyldAPIs.cpp` (`runAllInitializersForMain` order),
    `dyld/Loader.cpp` (initializer call signature; `DYLD_ROOT_PATH` applied
    to rpaths and cache-image lookups), `dyld/JustInTimeLoader.cpp`
    (simulator root prefix for cache images), `dyld/DyldRuntimeState.cpp`
    (`initialize`: TLV and allocator locking after libSystem).
  - `dyld/dyldStartup.s`: the kernel stack-layout comment and
    `__dyld_start` (non-simulator only).
  - `dyld/dyld_sim-entitlements.plist`, `configs/dyld.xcconfig` (entry name,
    export list, linker flags),
    `build-scripts/configure-dyld-archives.sh` (static archives),
    `build-scripts/generate-cache-config-header.sh`.
  - `mach_o/UnsafeHeader.cpp` (`getEntry`, `entryAddrFromThreadCmd`,
    `preferredLoadAddress`), `common/MachOFile.cpp` (`mappedSize`),
    `common/MachOAnalyzer.cpp` (`validMachOForArchAndPlatform`),
    `mach_o/Policy.cpp` (epoch gates), `common/Defines.h` (feature macros for
    simulator builds; `SUPPPORT_PRE_LC_MAIN` x86-64 macOS only).
  - `common/DyldSharedCache.cpp` (`DynamicRegion::make`/`size` 0x4000).
  - `lsl/Allocator.cpp` (`kPageSize` 16384; `vm_allocate` fallback in the
    simulator; `vm_protect` with `VM_PROT_COPY`).
  - `cache_builder/BuilderConfig.cpp` (simulator caches: no slide info; 4 GB
    arm64 limit).
  - `include/mach-o/dyld_images.h` (`dyld_all_image_infos` fields, notify
    count 8).
  - `include/mach-o/dyld_cache_format.h` (cache directory and base-name
    macros).
- **Same repo, older tags** (version history and signature stability):
  - `dyld-940` and `dyld-955` (version 16);
  - `dyld-1042.1` and `dyld-1245.1` (version 17, same entry signature);
  - `dyld-1284.13`, `dyld-1285.19`, `dyld-1286.10`, `dyld-1323.3`,
    `dyld-1335`, `dyld-1340`, and `dyld-1376.6` (version 18);
  - `dyld-852` `src/dyld2.cpp` (`useSimulatorDyld`, the same 9-parameter
    entry, the `startGlue` contract) and `src/dyldStartup.s` (legacy glue
    branch).
- **`apple-oss-distributions/xnu`**, `main` at `xnu-12377.1.9`
  (`f6217f89`):
  - `osfmk/mach/shared_region.h` (`SHARED_REGION_BASE_ARM64` /
    `_X86_64`);
  - `osfmk/arm/cpu_capabilities.h` (commpage base, `_COMM_PAGE_DYLD_FLAGS`
    +0x160);
  - `osfmk/i386/cpu_capabilities.h` (+0x100);
  - `bsd/sys/fcntl.h` (`F_GETPATH` 50, `F_ADDFILESIGS_FOR_DYLD_SIM` 83,
    `F_ADDFILESIGS_RETURN` 97, `F_CHECK_LV` 98, `fsignatures`);
  - `bsd/kern/syscalls.master` and `osfmk/kern/syscall_sw.c` (trap numbers
    in §7.3).
- **Public macOS SDK headers:** prototypes in §3.2. Offsets of
  `dyld_all_image_infos` and `struct stat`, and the values of `MAP_*`,
  `VM_FLAGS_ANYWHERE`, and `VM_PROT_COPY`, were computed by compiling
  `offsetof` against the public SDK headers for arm64.
- **Public documentation:** Apple, "Writing ARM64 code for Apple platforms"
  (variadic arguments on the stack; §6.1, §7.3). `man dyld` (macOS 27) lists
  `DYLD_SHARED_REGION` and `DYLD_SHARED_CACHE_DIR` but not `DYLD_ROOT_PATH`.
- **Level 4 (cited, not re-measured here):** the `0x1_C000_0000` cache base
  in `specs/simulator/darwin-arm64-abi.md` (§8 open question 1).
- **Not used:** no Apple binary, simulator runtime file, `.claude/Xcode.app`
  content, `research/dirty/`, or Ghidra output was consulted.
