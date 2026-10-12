# Spec: stage 3a contract (starting `dyld_sim` in the Ycode micro-VM)

Status: **stage 3a built and verified up to the host-library boundary (§12).**
This is the contract for stage 3a of `docs/SIMULATOR-LINUX.md`. It extends
`vm-shim-protocol.md` (stage 2). Every stage-3a component follows this
document exactly. If something needs to change, change it here first.

Inputs, which you must read:

- `specs/simulator/dyld-sim-handoff.md`: the host dyld → `dyld_sim` handoff.
  §7 is the design basis.
- `specs/simulator/darwin-process-start.md`: the kernel's process start and
  the commpage.
- `specs/simulator/darwin-trap-tables.md`, plus the `data/*.json` tables:
  trap numbers.
- `specs/simulator/darwin-arm64-abi.md`, with the corrections in §10 below.

Facts the orchestrator measured on the iOS 27.1 runtime (24A94401), evidence
level 4:

- `usr/lib/dyld_sim` carries `LC_UNIXTHREAD` (`ARM_THREAD_STATE64`) and has
  `__TEXT.vmaddr = 0`. Its `LC_SOURCE_VERSION` is `27062.0`, which is newer
  than the open-source `dyld-1378`.
- The shared cache's mappings start at **`0x1_C000_0000`** and end at
  `0x2_A919_C000` (`ycode dsc`). `dyld_sim` maps them at those addresses.

## 1. Stage 3a exit criterion

On the Thor, the following command:

```
ycode-simd --exec <guest-tests>/hello --runtime-root <RuntimeRoot> --trace
```

must produce all of these:

1. The trace shows `dyld_sim` mapping **all 11** shared-cache mappings, with
   `mmap(MAP_FIXED)` at exactly the addresses in the cache header.
2. A trap is taken whose ELR lies inside a shared-cache image whose install
   path starts with `/usr/lib/system/libsystem_` or is
   `/usr/lib/libSystem.B.dylib`. This shows that libSystem's initializer is
   running. The VMM then prints exactly one line:
   `milestone: libSystem initializer reached (<image> + <offset>)`
3. On the first unimplemented trap, or on any fatal condition, the VMM
   prints a decoded report and exits non-zero. Reaching `main` (the hello
   tool printing its line and exiting 0) is stage 3b. It is welcome but not
   required for 3a.

`hello` is our own C program built for the iOS simulator platform (§9).

## 2. Guest virtual address map (16 KiB pages, 47-bit VA)

| VA range | Contents |
|---|---|
| `< 0x1_0000_0000` | `__PAGEZERO`. Only the stage-2 EL1-only identity regions live here |
| `0x1_0000_0000` + image | Main executable, mapped segment by segment at its preferred `vmaddr` (no slide) |
| `0x1_6F60_0000`–`0x1_6FE0_0000` | Main stack (8 MiB). `user_stack` (top) = **`0x1_6FE0_0000`** |
| `0x1_8000_0000`–`0x3_0000_0000` | Shared-region reservation. **Nothing else may be placed here.** `dyld_sim` maps the cache into it |
| `0x3_0000_0000` + image | `dyld_sim`, mapped as one reservation of its `mappedSize`, with slide = `0x3_0000_0000 − preferred base` |
| `0x3_1000_0000`–`0x3_1001_0000` | **Ycode host page** (§5): code at +0 (EL0 RX, 16 KiB), read-only data at +0x4000 (EL0 RO, 16 KiB), read-write data at +0x8000 (EL0 RW, 32 KiB) |
| `0x3_2000_0000` and up | Anonymous allocations (`vm_allocate` anywhere, `mmap` without `MAP_FIXED`). First fit at or above the hint, never below this base |
| `0xF_FFFF_4000` | Read-only commpage (16 KiB, EL0 RO) |
| `0xF_FFFF_C000` | Commpage (16 KiB, EL0 RO). Filled as in §6 |

## 3. Guest physical memory and KVM memslots

- **Slot 0** is guest RAM, as in stage 2. It moves to GPA `0x4000_0000` with
  size **1 GiB**, and the page-table arena grows to **64 MiB** (GPA
  `0x4020_0000`). Every other stage-2 region keeps its address.
- Every other guest page is backed by **additional memslots**:
  - **Anonymous pool:** one memslot of 16 GiB at GPA `0x10_0000_0000`,
    backed by a host `mmap(MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE)`.
    Anonymous guest pages are carved out of it at 16 KiB granularity, with a
    free list.
  - **File mappings:** each guest file mapping gets its own memslot. It is
    backed by a host `mmap(PROT_READ | PROT_WRITE, MAP_PRIVATE, fd,
    offset)`, so guest writes are copy-on-write and the file is never
    modified. Its GPA comes from a bump allocator starting at
    `0x20_0000_0000`.
  - Memslot numbers are allocated from 1 upward. At startup the VMM checks
    `KVM_CAP_NR_MEMSLOTS` and reports exhaustion as a fatal error.
- A memslot stays registered after its pages are unmapped, at least until
  stage 3b.

## 4. Address-space model (portable, `YcodeDarwinABI`)

- `PageTableBuilder` gains `unmap(va:size:)`, `protect(va:size:attributes:)`,
  and dirty-table tracking (`drainDirtyTables() -> [(gpa, bytes)]`).
  - Unmapping clears L3 entries. Freeing empty tables is optional.
  - Remapping an already-mapped page is an error unless the caller unmaps it
    first. `GuestAddressSpace` does that unmap itself for `MAP_FIXED`.
- New protocol `PhysicalBacking`, implemented by the hypervisor (and by an
  in-memory fake for tests):

  ```
  allocateAnonymous(size) throws -> gpa              // zeroed; 16 KiB multiple
  mapFile(_ file: GuestFile, offset, size) throws -> gpa
  release(gpa, size)                                 // anonymous pages back to the pool
  readPhysical(gpa, count) throws -> [UInt8]
  writePhysical(gpa, bytes) throws
  ```

- New type `GuestAddressSpace`, which implements both `GuestMemoryAccess`
  and the protocol `GuestVirtualMemory`:

  ```
  mapAnonymous(at: UInt64?, size, protection, hint: UInt64?) throws -> va
  mapFile(_ file: GuestFile, offset, at: UInt64?, size, protection, hint: UInt64?) throws -> va
  unmap(va, size) throws
  protect(va, size, protection) throws
  regions -> [(va, size, protection, backing description)]   // for tracing
  generation: UInt64      // bumps on every page-table change
  ```

  - `at: nil` means "anywhere", found by first-fit search at or above
    `max(hint, 0x3_2000_0000)`, outside the shared-region reservation.
  - `at: va` means `MAP_FIXED`: whatever was mapped there is replaced.
  - Every change writes the dirty tables through `writePhysical` and bumps
    `generation`.
  - `VMProtection` is an OptionSet with read = 1, write = 2, execute = 4.
    For EL0 pages, it maps to AP and UXN as in stage 2, and PXN is always 1.
- **`GuestFile`** (a class) is an open host file. It has a host fd, the
  guest path, a size, and stat data. It is created by the VFS, and its host
  fd stays open as long as any mapping or descriptor references it.

## 5. Ycode host page and the launch sequence

The host page is built from `ycode/SimShim/host_stubs.S` → `host_stubs.bin`,
linked at VA `0x3_1000_0000`. The fixed offsets below are the interface
between the assembly and the Swift side:

| Offset | Size | Contents | Written by |
|---|---|---|---|
| `+0x0000` | ≤ 16 KiB | Code. **`+0x0000` is `_ycode_launch`** (the EL0 entry). It is followed by the 67 helper stubs, a `ret` stub, and the notification stub | assembled |
| `+0x4000` | 544 | **Helpers table**: `version = 18`, then the 67 slot pointers in the order and at the offsets of `dyld-sim-handoff.md` §3.2. Slots 32 and 33 are 0 | assembled |
| `+0x8000` | 8 | errno cell (`int`, 8-byte slot) | stubs |
| `+0x8008` | 8 | `startGlue` cell | `dyld_sim` |
| `+0x8040` | 96 | **Launch block** (12 × u64): `prepareEntry`, `argc`, `argv`, `envp`, `apple`, `mainMH`, `simMH`, `simSlide`, `helpers`, `startGlueAddr`, `stackTop`, reserved | VMM |
| `+0x8100` | 368 | `dyld_all_image_infos` (layout in `dyld-sim-handoff.md` §4.5) | VMM |
| `+0x8300` | 2 KiB | `infoArray` and `uuidArray` storage, and path strings | VMM |
| `+0x9000` | 4 KiB | `sysctlbyname` and scratch space | stubs / VMM |

**`_ycode_launch`** is entered at EL0. The VMM sets boot-info PC =
`0x3_1000_0000` and SP = the launch block's `stackTop`. It then:

1. Aligns SP down to 16 bytes, leaving room for the 9th argument. It stores
   `startGlueAddr` at `[sp]`.
2. Loads `x0`–`x7` = `argc`, `argv`, `envp`, `apple`, `mainMH`, `simMH`,
   `simSlide`, `helpers`, and `blr`s to `prepareEntry`.
3. With the result in `x0` (`start_sim`), it reloads `x0`–`x3` = `argc`,
   `argv`, `envp`, `apple`. It re-reads `argc` from `argv[-1]`, because
   `dyld_sim` may rewrite block word 0, and `blr`s to the saved result.
4. If that returns, it executes BSD `exit` (x16 = 1) with the returned
   `x0`.

**Stub conventions:**

- **Calling convention:** every stub follows Apple's arm64 convention. For
  `open`, `fcntl`, and `ioctl`, the variadic third argument is read from
  `[sp]` and moved into `x2` before the trap.
- **BSD forwarding stubs** (`dyld-sim-handoff.md` §7.3 table 2) put the
  number in `x16` and execute `svc #0x80`. On carry set, they store `x0`
  (the errno) into the errno cell and return −1. Pointer-returning helpers
  return NULL instead.
- **Mach forwarding stubs** pass `x0` through unchanged.
- **Pure EL0 stubs** behave exactly as in §7.3 table 1. AMFI output = `0xFF`.
- **Ycode-private traps** use `x16` in `0x7963_0000`–`0x7963_FFFF` (ASCII
  "yc"). The dispatcher checks this range **before** decoding the Darwin
  classes. They follow the BSD convention (carry plus errno):

| `x16` | Helper | Arguments → result |
|---|---|---|
| `0x7963_0001` | `vlog`, `vwarn` | `x0` = fmt, `x1` = va_list (pointer to the stack slots) → void. The VMM formats `%s %d %u %x %llx %p %lu %ld %llu %lld %c %%`. Others are printed verbatim |
| `0x7963_0002` | `realpath` | `x0` = path, `x1` = out[1024] → `x0` = out, or NULL with errno |
| `0x7963_0003` | `getcwd` | `x0` = buf, `x1` = size → `x0` = buf, or NULL with errno |
| `0x7963_0004` | `vm_copy` | Mach arguments → kern_return_t |
| `0x7963_0005` | `proc_regionfilename` | `x0` = pid, `x1` = addr, `x2` = buf, `x3` = size → length |
| `0x7963_0006` | `task_info` | Mach arguments → kern_return_t |
| `0x7963_0007` | `thread_info` | Mach arguments → kern_return_t |
| `0x7963_0008` | `mach_msg_destroy` | `x0` = header → void |
| `0x7963_0009` | `sysctlbyname` | `x0` = name, `x1` = old, `x2` = oldlenp, `x3` = new, `x4` = newlen → int |
| `0x7963_0010` | `notifyMonitorOfImageListChanges` | Arguments as slot 55 → void (trace only) |
| `0x7963_0011` | `notifyMonitorOfMainCalled` | → void (trace) |
| `0x7963_0012` | `notifyMonitorOfDyldBeforeInitializers` | → void (trace) |

## 6. Process image the VMM builds before boot

- **Main executable and `dyld_sim`:** mapped as in §2, segment by segment,
  with each segment's `initprot`. Zero-fill (`vmsize > filesize`) is
  anonymous. Ycode applies no fixups.
- **Kernel argument block:** built at the top of the main stack, in the
  exact layout of `darwin-process-start.md` Q1:
  - `argv` = `[guest path of the executable]`.
  - `envp`:
    - `DYLD_ROOT_PATH=<RuntimeRoot>`;
    - `SIMULATOR_ROOT=<RuntimeRoot>`;
    - `IPHONE_SIMULATOR_ROOT=<RuntimeRoot>`;
    - `DYLD_SHARED_CACHE_DIR=<RuntimeRoot>/System/Library/Caches/com.apple.dyld`;
    - `HOME=/tmp`, `TMPDIR=/tmp/`;
    - `PATH=<RuntimeRoot>/usr/bin:<RuntimeRoot>/bin`;
    - `XPC_SIMULATOR_LAUNCHD_NAME=dev.ycode.sim`.
  - `apple[]`, in the kernel's order:
    - `executable_path=<path>`;
    - `stack_guard=0x<16 hex>` (random, bits 8–15 zero);
    - `malloc_entropy=0x<hex>,0x<hex>`;
    - `ptr_munge=0x<hex>`;
    - `main_stack=0x<top>,0x<size>,0x<guard top>,0x<guard size>`;
    - `th_port=0x<thread port name>`.

  The launch block's `argc`/`argv`/`envp`/`apple` point into this block.
  `stackTop` = the block's lowest address (the mach_header slot).
- **`dyld_all_image_infos`:** `version` 17; `infoArray` = 1 entry for the
  main executable; `notification` = the host page's `ret` stub;
  `dyldImageLoadAddress` = `simMH`; `initialImageCount` = 1;
  `sharedCacheSlide` = 0. Every other field is 0.
- **Commpage** (`0xF_FFFF_C000`), using the field table in
  `darwin-process-start.md` Q3. Fields not listed are 0.
  - Version: as specified there.
  - Page-shift fields (0x025 user, 0x037 kernel): **14**.
  - Number of CPUs: **1**. Physical and logical CPU counts: 1.
  - **User timebase mode (0x090) = 1** (`CNTVCT_EL0`). The timebase offset
    is 0.
  - Continuous-time and approximate-time fields: 0 (unsupported). The
    gettimeofday block's tick = 0, so the guest falls back to BSD 116.
  - Memory size: 1 GiB.
  - The u64 at +0x160 that `dyld_sim` reads: 0.
- **Timebase.** `mach_absolute_time` ticks are the guest's `CNTVCT_EL0`.
  The VMM reads `CNTFRQ_EL0` (and the counter, for trap −3/−4) through KVM
  ONE_REG. `mach_timebase_info` (trap −89) returns 10⁹/`CNTFRQ`, reduced.
  The stage-2 24 MHz constants stay as the default for the portable
  dispatcher's tests only.
- **Initial vCPU state.**
  - PC = `0x3_1000_0000`, SP_EL0 = `stackTop`.
  - `TPIDRRO_EL0` = 0 and `TPIDR_EL0` = 0.
  - SPSR is still `0x3C0`: no interrupts are delivered in stage 3.

## 7. Shim changes (`ycode/SimShim/shim.S`)

- **TLB flush on resume.** The trap frame's reserved word at **+312**
  becomes **`resumeFlags`**. Bit 0 means "flush the TLB before resume". When
  it is set, the shim runs `tlbi vmalle1; dsb ish; isb` before the restore
  path's `eret`, then clears the flag. The VMM sets it whenever
  `GuestAddressSpace.generation` changed while a trap was handled.
- **EL0 counter access.** At boot the shim sets `CNTKCTL_EL1` with
  EL0VCTEN = 1 and EL0PCTEN = 0, so EL0 can read `CNTVCT_EL0`.
- **Unchanged:** everything else from stage 2.

## 8. Trap coverage required for 3a (`YcodeDarwinKernel`)

The dispatcher decodes `x16` in this order:

1. The private range (§5).
2. `0x80000000`, the platform call. The sub-selector is in `x3`: 2 =
   set the TSD base (frame `tpidrro` = `x0`); 3 = get it (`x0` =
   `tpidrro`). Any other selector is a no-op.
3. Negative values: Mach trap.
4. Otherwise: BSD, numbered by the **low 16 bits**. `x16 = 0` is the
   indirect call: the number is in `x0` and the arguments are shifted by
   one.

BSD failures set carry, with `x0` = errno and `x1` = 0.

**BSD:**

| Number | Call | Behavior |
|---|---|---|
| 1 | `exit` | Exit |
| 3 | `read` | |
| 4 | `write` | |
| 5 | `open` | |
| 6 | `close` | |
| 20 | `getpid` | |
| 24 | `getuid` | 501 |
| 25 | `geteuid` | 501 |
| 43 | `getegid` | 20 |
| 47 | `getgid` | 20 |
| 54 | `ioctl` | ENOTTY |
| 73 | `munmap` | |
| 74 | `mprotect` | |
| 75 | `madvise` | 0 |
| 92 | `fcntl` | `F_GETPATH` 50, `F_ADDFILESIGS_RETURN` 97 (writes back `fs_file_start` = file size), `F_CHECK_LV` 98 → 0, `F_SETFD` 2, `F_GETFD` 1, `F_GETFL` 3. Others: EINVAL |
| 116 | `gettimeofday` | |
| 153 | `pread` | |
| 197 | `mmap` | Darwin flags: `MAP_SHARED` 1, `MAP_PRIVATE` 2, `MAP_FIXED` 0x10, `MAP_ANON` 0x1000. A shared file mapping is treated as private and logged |
| 202 | `sysctl` | The same names as the private `sysctlbyname` |
| 220 | `getattrlist` | ENOTSUP |
| 327 | `issetugid` | 0 |
| 338 | `stat64` | Darwin 144-byte layout, from the research spec |
| 339 | `fstat64` | Darwin 144-byte layout |
| 340 | `lstat64` | Darwin 144-byte layout |
| 347 | `getfsstat64` | 0 |
| 427 | `fsgetpath` | ENOTSUP |
| 461 | `getattrlistbulk` | ENOTSUP |
| 521 | `abort_with_payload` | Fatal, exit 134. The reason string is printed |

**Mach:**

| Number | Call | Behavior |
|---|---|---|
| −3, −4 | clock fast traps | `CNTVCT` |
| −10 | `vm_allocate` | |
| −12 | `vm_deallocate` | |
| −14 | `vm_protect` | `VM_PROT_COPY` masked off |
| −16 | `mach_port_allocate` | |
| −18 | `mach_port_deallocate` | |
| −21 | `mach_port_insert_right` | |
| −24 | `mach_port_construct` | |
| −25 | `mach_port_destruct` | |
| −26 | `mach_reply_port` | |
| −27 | `thread_self` | |
| −28 | `task_self` | |
| −29 | `host_self` | |
| −31 | `mach_msg` | Logs the header, returns `MACH_SEND_INVALID_DEST` (`0x10000003`) |
| −61 | `thread_switch` | 0 |
| −89 | `mach_timebase_info` | |

Port names are managed in a name table:

| Port | Name |
|---|---|
| task | `0x103` |
| thread | `0x203` |
| host | `0x303` |
| others | from `0x1003`, step 0x100 |

**`sysctl` names:**

| Name | Value |
|---|---|
| `hw.optional.arm.caps` | 0 (8 bytes) |
| `kern.grade_cputype` | ENOENT |
| `hw.pagesize` | 16384 |
| `hw.ncpu` | 1 |
| `hw.activecpu` | 1 |
| `kern.osproductversion` | `"27.1"` |
| anything else | ENOENT, logged |

Any other trap logs `unimplemented <class> <number> <name from the JSON
tables>` together with the frame. In `--trace` mode the VMM then exits with
status **72**, so each 3b iteration finds the next missing trap.

**VFS (`DarwinFileSystem`):**

- Guest paths equal host paths. Access is allowed only under the read-only
  prefixes `<RuntimeRoot>` and the executable's directory, plus a read-write
  per-run directory `/tmp` that maps to `<run dir>/tmp` on the host.
- Paths are normalized (`.`, `..`, repeated `/`) before the check. A path
  outside the allowlist returns ENOENT. A write under a read-only prefix
  returns EROFS.
- fds 0, 1, and 2 are the console.
- `open` flags: `O_RDONLY` 0, `O_WRONLY` 1, `O_RDWR` 2, `O_CREAT` 0x200,
  `O_TRUNC` 0x400, `O_EXCL` 0x800, `O_CLOEXEC` 0x1000000,
  `O_DIRECTORY` 0x100000.

### 8.1 VFS Swift API (in `YcodeDarwinABI`, owned by M, used by T)

```swift
public struct DarwinErrnoError: Error, Equatable { public var errno: Int32 }   // thrown for every BSD-style failure

public final class GuestFile {                 // §4
    public let guestPath: String
    public let hostFD: Int32
    public let size: UInt64
    public let stat: DarwinStat
}

public struct DarwinStat: Equatable {
    // dev, mode, nlink, ino, uid, gid, rdev, atime/mtime/ctime/birthtime (sec, nsec), size, blocks, blksize, flags, gen
    public func encodedStat64() -> [UInt8]     // exactly 144 bytes, Darwin arm64 layout
}

public final class DarwinFileSystem {
    public struct Prefix { public var guestPath: String; public var hostPath: String; public var writable: Bool }
    public init(prefixes: [Prefix], console: @escaping (Int32, [UInt8]) -> Void)   // fd 1/2 output sink
    public func normalize(_ guestPath: String, cwd: String) -> String
    public func open(_ path: String, flags: Int32, mode: UInt16) throws -> Int32   // returns fd
    public func close(_ fd: Int32) throws
    public func read(_ fd: Int32, count: Int) throws -> [UInt8]
    public func pread(_ fd: Int32, count: Int, offset: UInt64) throws -> [UInt8]
    public func write(_ fd: Int32, _ bytes: [UInt8]) throws -> Int
    public func stat(_ path: String, followSymlinks: Bool) throws -> DarwinStat
    public func fstat(_ fd: Int32) throws -> DarwinStat
    public func file(for fd: Int32) throws -> GuestFile    // for mmap
    public func path(for fd: Int32) throws -> String       // F_GETPATH
    public func realpath(_ path: String) throws -> String
    public var cwd: String { get set }                     // default "/"
    public func setCloseOnExec(_ fd: Int32, _ on: Bool) throws
}
```

Errno values (Darwin):

| Name | Value |
|---|---|
| ENOENT | 2 |
| EBADF | 9 |
| ENOMEM | 12 |
| EACCES | 13 |
| EFAULT | 14 |
| EEXIST | 17 |
| ENOTDIR | 20 |
| EISDIR | 21 |
| EINVAL | 22 |
| EMFILE | 24 |
| ENOTTY | 25 |
| EROFS | 30 |
| ERANGE | 34 |
| ENOSYS | 78 |
| ENOTSUP | 45 |
| ENAMETOOLONG | 63 |

## 9. Guest test program

`ycode/SimShim/guest-tests/hello.c` is our own code. Its `main` writes
`hello from the iOS simulator runtime on Linux\n` to fd 1 with `write()` and
returns 0.

It is built on macOS by `ycode/SimShim/guest-tests/build.sh` with:

```
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -O2
```

The output is `out/hello`. The script then checks with `ycode macho` that
the binary is platform 7. The artifact is copied to the Thor.

## 10. Corrections to `darwin-arm64-abi.md` (from the xnu research)

- BSD numbers use the **low 16 bits** of `x16`. There are 558 slots (0–557),
  not 669 entries. `x16 = 0` is the indirect call.
- An empty Mach slot raises `EXC_SYSCALL`; it does not return an error.
- The platform call's sub-selector is in **`x3`**: 2 = set the TSD base,
  3 = get it.
- On error, BSD calls also set `x1 = 0`.

## 12. Results and resolutions (normative, 2026-10-11)

### What a run of `hello` on the Thor did (orchestrator reproduction)

- 245 traps were serviced. `dyld_sim` set itself up, preflighted both cache
  files (`pread`, `F_ADDFILESIGS_RETURN`, a trial `mmap`), and mapped
  **all 11 cache mappings with `MAP_FIXED` at their header addresses**.
  It also mapped its dynamic-region page at `0x2_A919_C000`.
- It resolved the dependency closure from the cache and reported 39 images
  through private trap `0x7963_0010`.
- It then aborted with `Library not loaded:
  /usr/lib/system/libsystem_platform.dylib`. Exit criterion 1 is met, 3 is
  met, and **2 is blocked**.

### Root cause: the runtime needs three *host* (macOS) libraries

- `libsystem_sim_{kernel,platform,pthread}_host.dylib` (in the simulator
  cache) re-export `/usr/lib/system/libsystem_{kernel,platform,pthread}.dylib`.
- On macOS those are the Mac's own libraries, which come from the Mac's
  shared cache. The Mac's cache occupies `0x1_8000_0000`, and that is why
  the simulator cache sits at `0x1_C000_0000`. The "detach" in
  `dyld-sim-handoff.md` §1.4 therefore does not unmap the host cache.
- The simulator cache contains only tiny macOS-platform link stubs at those
  paths, and `dyld_sim` does not accept them.
- **Ycode must supply its own clean-room implementations of these three
  libraries.** This is stage 3a-ii, whose contract is in
  `specs/simulator/host-libraries.md`. Every system call the runtime makes
  then goes through Ycode's own `libsystem_kernel`.

### Resolutions made during the build

- **Host page** (agent S):
  - The `ret` stub is at **`+0x0F00`**, and the VMM checks that it is there.
  - `mmap` failure returns −1 (`MAP_FAILED`). NULL is returned only by
    `getcwd`, `realpath`, and `opendir`.
  - Private traps that return a `kern_return_t` or void ignore carry.
  - Every non-NULL slot has its own stub.
  - Slots 54, 55, and 66 use the private trace traps.
  - The TLB flush also executes `ic iallu`.
  - The 9th-argument slot is 16 bytes below `stackTop`.
- **Process image** (agent T):
  - `main_stack=` follows xnu's order: stack top, stack size, allocation
    base, allocation size. §6's wording was wrong.
  - Commpage capabilities are the always-on bits plus the CPU count.
  - `sysctlbyname` (BSD 274) is also implemented.
  - The Mach-style private traps clear carry.
  - Empty `kern_invalid` Mach slots are reported as unimplemented.
- **Memory** (agent M):
  - Mappings must be 16 KiB-aligned.
  - Guest user VA is limited to `[4 GiB, 0xF_C000_0000)`.
  - The commpage and host page are permanent regions.
  - `PROT_NONE` maps to AP `10`.
  - The VFS resolves symlinks inside the guest namespace (ELOOP after 32).
  - stat reports uid 501 and gid 20.
- **Hypervisor** (agent H):
  - File slots are private copy-on-write with a **zero tail past EOF**.
  - `KVM_CAP_NR_MEMSLOTS` = 32767 on the Thor.
  - `CNTFRQ_EL0` is not exposed through ONE_REG on 6.8-tegra. The host value
    (1 GHz) is used, so the timebase is 1/1.
  - A segment's partial last page beyond `filesize` is zeroed.
  - The milestone is printed to stderr in order with the trace.

## 11. Component ownership (stage 3a)

| Owner | Files |
|---|---|
| Agent **S** (assembly) | `ycode/SimShim/shim.S` (§7), new `host_stubs.S` (§5), `build.sh` additions, `guest-tests/` (§9), `SimShim/README.md` |
| Agent **M** (memory and VFS, portable) | In `YcodeDarwinABI`: `PageTables.swift`, `VMLayout.swift`, new `AddressSpace.swift` (§4), new `DarwinFileSystem.swift` (§8 VFS, `GuestFile`, Darwin `stat64` encoding), and matching tests in `Tests/YcodeDarwinABITests/` |
| Agent **T** (kernel personality, portable) | New target `YcodeDarwinKernel`: the dispatcher (§8), Mach port table, `sysctl` table, the `vlog` formatter, and the process-image builders (§6: argument block, apple strings, commpage, `dyld_all_image_infos`, launch block). Also `TrapFrame.swift` (`resumeFlags`), and tests in `Tests/YcodeDarwinKernelTests/`. The old `DarwinTrapDispatcher.swift` in `YcodeDarwinABI` stays for the stage-2 self-test |
| Agent **H** (hypervisor and integration, Linux arm64) | `CKVM/`, `YcodeHypervisor/` (memslot `PhysicalBacking`, file-backed slots, ONE_REG for `CNTFRQ`/`CNTVCT`, TLB-flush flag), and `ycode-simd/main.swift`: `--exec` mode, which loads the main executable and `dyld_sim` with `YcodeMachO`, writes §6, boots, runs the loop, prints the milestone, and attributes each ELR to an image |

The orchestrator owns `Package.swift` and every spec.

## Evidence

- `dyld-sim-handoff.md` and `darwin-process-start.md` (level 1, Apple open
  source).
- Orchestrator measurements on the iOS 27.1 runtime with `otool -l` and
  `ycode dsc` (level 4).
- The remainder is Ycode design.
