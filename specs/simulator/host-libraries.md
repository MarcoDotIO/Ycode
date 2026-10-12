# Spec: stage 3a-ii contract (Ycode's host libraries)

Status: **contract**. §1–§6 are final. §7 and §8 are **pending research**
(`specs/simulator/host-library-init.md`, being written now).

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

## 7. Initialization interfaces — PENDING

This section will specify, from open-source Libsystem, libsyscall,
libplatform, and libpthread (level 1):

- which initializer entry points `libSystem.B`'s initializer calls in these
  three libraries, and in what order;
- the exact layouts and versions of the callback/function structures it
  passes (for example a `_libkernel_functions` /
  `_libpthread_functions`-style struct);
- what each init must set up.

## 8. Thread-local storage and errno ABI — PENDING

This section will specify:

- the TSD slot map at `TPIDRRO_EL0` (self, errno, MIG reply port, Mach
  thread self, QoS, and so on), which other libraries read inline;
- how `__error()` and `cerror` set errno;
- the `pthread_t` fields any client reads directly;
- the stack and thread-start conventions (`thread_start`, `start_wqthread`)
  registered with `bsdthread_register`.

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
