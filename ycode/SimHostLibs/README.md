# SimHostLibs: Ycode's clean-room host libraries

This directory builds Ycode's replacements for the three macOS host libraries
that the iOS simulator runtime re-exports:

| Output (`out/`, git-ignored) | Install name |
|---|---|
| `libsystem_kernel.dylib` | `/usr/lib/system/libsystem_kernel.dylib` |
| `libsystem_platform.dylib` | `/usr/lib/system/libsystem_platform.dylib` |
| `libsystem_pthread.dylib` | `/usr/lib/system/libsystem_pthread.dylib` |

The contract is `specs/simulator/host-libraries.md`. The symbol tables are
`specs/simulator/data/host-lib-surface-{kernel,platform,pthread}.json`. The
init and TSD interfaces are in `specs/simulator/host-library-init.md`. All
code here is original Ycode code. It was written from those specs, public C,
POSIX, and Darwin API documentation, and the Arm Architecture Reference
Manual.

## Layout

| Path | Owner | What it is |
|---|---|---|
| `build.sh` | P | The build, the self-check, and the host tests |
| `common/yc_base.h`, `common/yc_kernel_api.h` | P | Freestanding types, errno and Mach codes, the ulock ABI, and the kernel functions that platform and pthread call |
| `common/gen_stubs.py` | P | The generator for the unimplemented-function layer (contract §4) |
| `common/stub-conventions.txt` | P | Per-name failure conventions that override the category default |
| `common/data-symbols.txt` | P | Data symbols: the minimum size and the initial value (contract §8.4) |
| `common/extra-exports.txt` | all | Allowed exports that are not table rows (empty) |
| `common/fallback/{all,kernel}/` | P | Fallback C files that a library's own sources can replace |
| `common/verify.py`, `common/make_tbd.py` | P | The self-check, and the `.tbd` writer for linking |
| `kernel/` | K, L | Hand-written `libsystem_kernel` sources; `kernel/tests/` the spawn/libproc host tests |
| `platform/` | P | Hand-written `libsystem_platform` sources |
| `platform/tests/` | P | The host unit tests |
| `pthread/` | Q | Hand-written `libsystem_pthread` sources (not present yet) |

## Build

```sh
. ~/.local/share/swiftly/env.sh        # Linux: Thor (arm64) or the x86-64 workstation
(cd .. && swift build --product ycode) # the self-check uses Ycode's `ycode macho`
sh build.sh          # build and self-check the three dylibs
sh build.sh test     # the same, then the platform and pthread host unit tests
sh build.sh hosttest # only the host unit tests: platform, then pthread/tests/run.sh (works on macOS too)
sh build.sh clean
```

The tools come from the Swift toolchain: `clang`, `ld64.lld`, `llvm-nm`, and
`llvm-objdump`, plus `python3` and the host `cc`. You can override each one
with an environment variable: `CLANG`, `LD64`, `NM`, `OBJDUMP`, `PYTHON`,
`HOST_CC`. The other variables are `YCODE` (default
`../.build/debug/ycode`) and `SPEC_DATA` (default
`../../specs/simulator/data`). If you copy only `ycode/` to a machine, also
copy `specs/simulator/data/` to the same relative place or set `SPEC_DATA`.

### Compile and link commands

```
clang -target arm64-apple-ios27.0-simulator -std=c11 -nostdlib -ffreestanding -fno-builtin
      -fno-stack-protector -fno-exceptions -fPIC -O2 -fvisibility=hidden -fno-common
      -fno-strict-aliasing -mno-outline-atomics -Wall -Wextra -Werror -Icommon [-I<lib>] -c ...
python3 -I common/strip_platform.py <object>     # after every compile
ld64.lld -arch arm64 -platform_version ios-simulator 27.0 27.1 -dylib
      -install_name /usr/lib/system/libsystem_<lib>.dylib -current_version 1.0.0
      -compatibility_version 1.0.0 -fixup_chains -no_adhoc_codesign -o out/libsystem_<lib>.dylib
      <objects> [out/libsystem_kernel.tbd] [out/libsystem_platform.tbd]
```

The Swift 6.4 `ld64.lld` has a downstream check that rejects every Mach-O
input that has a Darwin platform load command. The error is "This version
of lld does not support linking for platform …". Because of this:

1. Objects are compiled with the real Darwin triple, then
   `common/strip_platform.py` cuts the `LC_BUILD_VERSION` out of each
   object. The tag is only metadata in an object file. The linker writes
   the dylib's own `LC_BUILD_VERSION` from `-platform_version`.
2. **Never compile for `arm64-apple-none-macho`.** That triple uses generic
   AAPCS64, not Apple's arm64 convention (DarwinPCS). Under DarwinPCS,
   variadic arguments go on the stack and stack arguments are packed at
   their natural size. Code compiled the other way miscompiles variadic
   calls and calls with more than 8 arguments.
   `-Xclang -target-abi -Xclang darwinpcs` fixes only some of this.
3. Every build first runs `common/abi_check.py`. It compiles
   `common/abi_check/{callee,caller}.c` with the library flags, strips the
   objects, links them, and disassembles the result. It requires all of
   the following:
   - the variadic callee does not spill argument registers;
   - the variadic caller puts its anonymous arguments on the stack;
   - a 10-argument call puts its `char` at `[sp]` and its `short` at
     `[sp, #2]`, on both the caller and the callee side.

   A regression fails the build.
4. The other libraries are linked through generated `.tbd` stubs
   (`common/make_tbd.py`), not through the dylibs. The result is the same:
   an `LC_LOAD_DYLIB` of the exact install name, and two-level binds.

`-no_adhoc_codesign` is required. Without it, lld adds an
`LC_CODE_SIGNATURE`.

### What the build does for each library

1. It compiles `<lib>/*.c` and `<lib>/*.S`, and records every global that
   these objects define.
2. It compiles each fallback file, `common/fallback/all/*.c` and
   `common/fallback/<lib>/*.c`. The file is used only if step 1 defines
   none of its globals (see "Suppressing stubs and fallbacks").
3. It generates `out/obj/<lib>/stubs.S`. This file has one stub or data
   variable for each table row that is not yet defined. A manifest
   (`out/libsystem_<lib>.stubs.tsv`) records each one and its convention.
4. It links the dylib.
5. It runs `common/verify.py`, which fails the build on any mismatch:
   - Header: arm64 with CPU subtype 0 and no capability bits, `MH_DYLIB`,
     `MH_DYLDLINK|MH_TWOLEVEL`, and no `MH_DYLIB_IN_CACHE`,
     `MH_WEAK_DEFINES`, or `MH_HAS_TLV_DESCRIPTORS`.
   - Load commands: one `LC_ID_DYLIB` with the exact install name and
     version 1.0.0/1.0.0, a non-zero `LC_UUID`, and one `LC_BUILD_VERSION`
     with platform 7, minos 27.0, and sdk 27.1. There is no
     `LC_CODE_SIGNATURE`, every load command is known, there is an export
     trie, and only the allowed dependencies appear.
   - Segments: the order is `__TEXT`, then optional `__DATA_CONST`, then
     optional `__DATA`, then `__LINKEDIT`. The permissions are r-x, rw-,
     rw-, and r--. `__DATA_CONST` has `SG_READ_ONLY`. Each vmaddr and
     fileoff is 16 KiB aligned. Every filesize except `__LINKEDIT`'s is a
     multiple of 16 KiB. Segments do not overlap, sections lie inside their
     segments, and the load commands fit in `__TEXT`.
   - `ycode macho` and `llvm-objdump --macho --private-headers` are run to
     check the same facts independently.
   - Symbols (from `llvm-nm -gU`): **every row of the JSON table** is
     exported. This includes the link-stub exports that nothing imports,
     because the cache patch table may list them. Function rows must be
     `T`, and data rows must not be. Each data symbol has at least the
     minimum size from `data-symbols.txt` before the next symbol. Any
     export that is not a table row and not in `extra-exports.txt` fails
     the build.
6. It writes `out/libsystem_<lib>.tbd`, which the next library links
   against.

## Unimplemented stubs (contract §4)

Every generated stub loads `x0` with the address of the function's C name
(a `__TEXT,__cstring` string, for example `"close$NOCANCEL"`). It then
branches to a shared tail. The tail does `x16 = 0x7963_0F00; svc #0x80`
and then fails according to its convention:

| Convention | After the trap | Default for |
|---|---|---|
| `errno` | `errno = ENOSYS (78)` through `__ycode_stub_enosys`, then return −1 | BSD syscalls and private wrappers, libproc, work_interval, kpersona, fs_snapshot, os_channel, other kernel names, `sched_*`, ucontext |
| `kern` | return `KERN_NOT_SUPPORTED` (46) | Mach routines and Mach traps |
| `zero` | return 0, NULL, `MACH_PORT_NULL`, or false | Mach traps that return a port or a `boolean_t`, `qos_class_*`, value or pointer getters (in the overrides) |
| `void` | return | void functions (in the overrides) |
| `errret` | return `ENOSYS` (78) as the result | `pthread_*`, `_pthread_*`, `posix_spawn*` (these return error numbers) |
| `noreturn` | `brk #0x7963` | `exit`, `__exit`, `abort_with_*`, `pthread_exit`, `thread_start`, and so on |
| `nop` | no trap; `ret`, and every register is preserved | `___chkstk_darwin`, `thread_chkstk_darwin` |

The default comes from the row's `category`. For BSD syscalls and Mach
traps it is refined by the return types in `bsd-syscalls.json` and
`mach-traps.json`. `common/stub-conventions.txt` overrides it per name. The
generator rejects an override for a name that is not in the table. Data
rows become real variables (in `__TEXT,__const` when the host has them
there, otherwise in `__DATA,__data`). Their size is
max(`data-symbols.txt` minimum, the JSON `sizeUpperBound`), rounded up to
8, and their initial values come from `data-symbols.txt`.

## Suppressing stubs and fallbacks (for K, Q, and later work)

- **A stub disappears automatically.** Define the symbol in a `.c` or `.S`
  file directly in `kernel/`, `platform/`, or `pthread/`, and export it
  (`YC_EXPORT` in C, or `.globl` in assembly). The build collects each
  object's defined globals before it runs the generator. The generator
  emits nothing for a name that is already defined. You do not need to
  edit any list. If you forget `YC_EXPORT`, the symbol stays hidden: no
  stub is generated, and verify fails with "not exported".
- **Fallbacks are replaced one whole file at a time.** If your sources
  define every global of a fallback file, the build drops that file and
  prints "suppressed". If they define only some of its globals, the build
  stops with an error.
  - `fallback/kernel/yc_errno_fallback.c`: `__error`, `cerror`, and
    `cerror_nocancel`, following contract §8.5. `__error` returns TSD slot
    1 when the TSD base and the slot are non-zero. Otherwise it returns the
    exported global `errno`. The cerror functions store to both places and
    return −1 in `x0` and `x1`.
  - `fallback/all/yc_errno_hook.c`: the hidden `__ycode_set_errno(int)` and
    `__ycode_stub_enosys(void)` (errno = ENOSYS, return −1). There is one
    copy in each library. The hook stores through `__error()`, which
    platform and pthread import from `libsystem_kernel`. **Keep these two
    names stable.** K can replace the file in `kernel/`. Platform and
    pthread follow automatically, because they only call `__error()`.
  - `fallback/all/yc_compiler_mem.c`: hidden byte-loop `memcpy`,
    `memmove`, `memset`, and `memcmp`. The compiler may emit calls to these
    for struct copies even in freestanding code.
- **Data symbols** work the same way. If you define `_mach_task_self_`
  yourself, the generated variable is dropped. `verify.py` still checks
  the minimum size from `data-symbols.txt`.
- To export a name that is not in the table, add it to
  `common/extra-exports.txt`.

## What `libsystem_platform` implements (140 of 173 table rows)

- **Strings and memory:** all 21 `_platform_*` routines and `__bzero`.
  They follow the C standard and the man-page semantics. `memmove` copies
  word by word, in both directions. `strlcpy` and `strlcat` return the
  length they tried to create. `memset_pattern*` writes a partial last
  copy. `_platform_memcmp_zero_aligned8(p, n)` returns 0 when the bytes
  are all zero and 1 otherwise.
- **Atomics:** all `OSAtomic*` arithmetic, logic, compare-and-swap, and
  test-and-set/clear functions, with and without the barrier. The
  `OSAtomicEnqueue`/`Dequeue` LIFO is lock-free: an `ldaxp`/`stlxp`
  compare-and-swap over the (head, generation) pair. The `OSAtomicFifo*`
  queues use the third word of the head as a lock. `OSMemoryBarrier` is
  also implemented.
- **Locks:**
  - `os_unfair_lock_*`: lock, trylock, unlock, `_with_options`,
    `_with_flags`, `_no_tsd`, and `assert_*`. The owner is TSD slot 3, or
    0x203 while there is no TSD. Recursion and unlock by a non-owner crash
    with `brk #0x7964`.
  - The recursive lock, including `tryunlock4objc` and
    `unlock_forked_child`.
  - `_os_nospin_lock_*`, `OSSpinLock*`, and `spin_lock*`, as a
    0/1/2 futex lock.
  - `os_lock_*` with the six `_os_lock_type_*` descriptors (32 bytes each,
    in Ycode's own layout).
- **Once:** `_os_once`, `__os_once_reset`, and `_os_alloc_once`. The done
  value is ~0. `_os_alloc_once` uses a bump heap of zero-filled 32 KiB
  blocks from `mmap` (contract init §7.1).
- **Init:** `__libplatform_init(NULL, envp, apple, vars)`. It reads
  `security_config`, erases `pfz=`, sets up the simple-ASL context in
  `os_alloc_once` slot 21, and calls `__libkernel_platform_init` with the
  version-1 string table. It can safely be called twice.
- **setjmp:** `setjmp`, `longjmp`, `_setjmp`, `_longjmp`, `sigsetjmp`,
  and `siglongjmp` save and restore x19–x30, sp, and d8–d15, and the mask
  through `sigprocmask`. The `sigsetjmp` flag is at offset 0xC0.
  `longjmp(env, 0)` returns 1. Pointers are **not munged** with TSD
  slot 7, because both ends are in this library.
- **Other functions:**
  - `ffs`, `ffsl`, `ffsll`, `fls`, `flsl`, and `flsll`.
  - `sys_icache_invalidate`, `sys_dcache_flush`, and `sys_cache_control`.
    These read the line sizes from `CTR_EL0` and use `DC CVAU`/`IC IVAU`
    and `DC CIVAC`. The shim sets UCT and UCI.
  - `os_sync_wait_on_address` and its `_with_timeout`/`_with_deadline`
    variants, and `os_sync_wake_by_address_any`/`_all`, built on
    `__ulock_wait2`/`__ulock_wake`.
  - `_simple_dprintf`/`vdprintf`, the `_simple_s*` string builders (on
    `mmap`), `_simple_put`/`putline`, `_simple_getenv`, and
    `_simple_asl_log`/`_prog`, which write "prog: msg" to fd 2.

**Still stubs (33):**
- the ucontext calls `getcontext`, `setcontext`, `swapcontext`,
  `makecontext`, and `_ctx_done`;
- `_os_semaphore_*`;
- `os_security_config_get*`;
- the `os_log_simple*` group;
- `_simple_esprintf`, `_simple_vesprintf`, and `_simple_esappend`;
- `_simple_asl_msg_*`, `_simple_asl_send`, and `_simple_asl_get_fd`;
- the data symbol `os_script_config_storage`, which is a real 16 KiB zero
  variable.

## Interfaces that agent K must provide

- **ulock**, with these values from `common/yc_kernel_api.h`:
  - operations: `UL_COMPARE_AND_WAIT` = 1, `UL_UNFAIR_LOCK` = 2,
    `_SHARED` = 3, `UL_COMPARE_AND_WAIT64` = 5, `64_SHARED` = 6;
  - flags: `ULF_WAKE_ALL` = 0x100 and `ULF_NO_ERRNO` = 0x0100_0000.

  A wait blocks while the 32-bit (or 64-bit) word at `addr` equals `value`.
  A spurious return is allowed. With `ULF_NO_ERRNO`, an error comes back as
  −errno. A wake with no waiter returns −ENOENT.
- **Unfair-lock word protocol:**
  - 0 = free;
  - owner (bit 0 set) = held;
  - owner & ~1 = held, and there may be waiters.

  A waiter clears bit 0, then calls `__ulock_wait2(UL_UNFAIR_LOCK |
  ULF_NO_ERRNO, word, owner & ~1, 0, 0)`. Unlock swaps the word to 0 and
  calls `__ulock_wake(UL_UNFAIR_LOCK | ULF_NO_ERRNO, word, 0)` if bit 0 was
  clear.
- **Other functions platform imports:** `__error`,
  `__libkernel_platform_init`, `_os_alloc_once_table`, `mmap`, `munmap`,
  `write`, `sigprocmask` (Darwin `sigset_t` = u32, SIG_BLOCK = 1,
  SIG_SETMASK = 3), `mach_absolute_time`, and `mach_timebase_info`.
  pthread currently imports only `__error`.

## Stage 4b: processes in `libsystem_kernel` (agent L)

Contract: `specs/simulator/stage4b-contract.md` section 8, semantics in
`specs/simulator/processes.md`.

- `kernel/spawn.c`: `posix_spawn` builds the 144-byte descriptor (section
  1.2) only when there are attributes or file actions, issues BSD 244
  directly, and returns the error number (errno untouched). The
  attribute block (248 bytes, defaults of section 1.4), the port-action
  block (24-byte records) and the file-action block (1040-byte records)
  are heap blocks from libsystem_c's `malloc` (the `_libkernel_functions`
  table), or from `mmap` before that table exists. Every
  `posix_spawnattr_*`/`posix_spawn_file_actions_*` row with importers is
  implemented, plus the plain getters. `set_use_sanitizers_np` succeeds
  and stores nothing (open question 6).
- `kernel/libproc.c`: `proc_listpids`/`listallpids`/`listpgrppids`/
  `listchildpids`, `proc_pidinfo`, `proc_pidfdinfo`, `proc_name`,
  `proc_pidpath`, `proc_pidpath_audittoken` (BSD 545 with the
  pid-version check), `proc_pid_rusage`, the dirty-tracking calls and
  `proc_terminate` (section 2.11). The CPU/wakeup-monitor, footprint and
  region calls stay stubs: no spec covers them yet.
- `kernel/mach.c`: `mach_ports_register`/`mach_ports_lookup` over the
  private routines n = 8/9 (padding to three; lookup returns a
  `vm_allocate`d array in the caller's task).
- `kernel/init.c`: `mach_init` sets `bootstrap_port` from
  `task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT)`.

## Stage 4c fixes (launchd_sim)

- `pthread_once` ignores the signature word, as Darwin's libpthread does:
  libsystem_c's stdio `__sdidinit` is a zero-filled `pthread_once_t`.
  Mutexes, conditions and rwlocks still reject an unknown signature
  (EINVAL), as on Darwin.
- `__gettimeofday` is hand-written: it passes 0 as BSD 116's third
  argument (the `mach_absolute_time` out-pointer).
- `kernel/mig.c`: `mach_port_set_attributes` (and its `_kernelrpc_` name)
  is a MIG RPC, id 3218, to the task port, which the VMM serves.
  `host_get_special_port` returns `KERN_INVALID_ARGUMENT` without a call:
  guest tasks hold only the unprivileged host port.
- The simple-ASL context (os_alloc_once slot 21) has libplatform's layout
  and is 48 bytes, because the simulator's `libsystem_sim_platform` uses
  the same slot with its own, larger layout: a `sim_connect_lock` at +32
  (see `platform/simple.c`).
- `os_unfair_lock`: a `__ulock_wait2` result of EOWNERDEAD (the word names
  no thread) crashes with `brk #0x7964`, x0 = a message, x1 = the lock, and
  LR = the client's return address, instead of retrying forever.

## Host tests

`platform/tests/test_main.c` compiles the platform sources for the host
with `-DYC_HOST_TEST`. In that mode `YC_FN(x)` becomes `yc_test_x` and
kernel calls become `yc_testk_x`, so nothing collides with the host libc.
The test file supplies fake kernel functions.

The tests compare the string and memory functions with the host libc,
using random overlaps and alignments. They check the atomics and both
queues, all the lock types, once, and alloc_once. A 4-thread stress test
covers the unfair, nospin, and recursive locks, the lock-free LIFO, and
`os_once`. They also cover `ffs`/`fls`, cache control, `os_sync`
argument handling, the `_simple` formatter, and `__libplatform_init`. On
arm64 hosts they also check that `setjmp`/`longjmp` restore every
callee-saved register.

`kernel/tests/run.sh` (run by `build.sh test` and `hosttest`) builds
`kernel/spawn.c` and `kernel/libproc.c` for the host with fake kernel
calls and checks the block layouts and defaults, the descriptor
`posix_spawn` passes, the validation errors, and the libproc result
conventions. It runs on arm64 hosts only and is skipped elsewhere.

On a macOS host, the cache instructions are skipped, because macOS traps
EL0 reads of `CTR_EL0`.
