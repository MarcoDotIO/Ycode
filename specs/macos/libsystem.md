# Spec: Ycode's libSystem for macOS programs

Status: **implemented for Milestone A, extended for stage B**
(`ycode/MacUserland/libsystem/`; the libc that the Swift runtime, libc++
and FoundationEssentials need, 1.0.0-beta.3, #87).
Ycode design, clean room. Sources: the C standard and POSIX descriptions of
the functions, the public SDK headers' type layouts and constants (named
in §4), clang's public Block ABI specification, Apple's public libdispatch
documentation, and the existing Ycode specs `host-libraries.md` and
`host-library-init.md`. It is not derived from Apple's Libc, libmalloc or
libdispatch sources.

Context: `macos-apps.md` §5.2 (option 2) and `dyld.md` (the loader).

## 1. Scope

A macOS program links against `/usr/lib/libSystem.B.dylib`. Ycode's
libSystem is a **small, ABI-compatible shim**: enough of libc, malloc, the
Blocks runtime and libdispatch for command-line programs, plus re-exports
of Ycode's three host libraries. It is not a complete libSystem; §11 lists
what is missing. It grows with the programs Ycode runs.

## 2. Composition

| Guest path | What | Source |
|---|---|---|
| `/usr/lib/libSystem.B.dylib` | Ycode's libc subset, malloc, Blocks runtime, dispatch subset, `dlfcn`, the initializer | `MacUserland/libsystem/` |
| `/usr/lib/system/libsystem_kernel.dylib` | System-call wrappers, Mach, errno | `SimHostLibs/kernel` (unchanged code) |
| `/usr/lib/system/libsystem_platform.dylib` | String primitives, atomics, `os_unfair_lock`, setjmp | `SimHostLibs/platform` |
| `/usr/lib/system/libsystem_pthread.dylib` | pthreads | `SimHostLibs/pthread` |
| `/usr/lib/dyld` | Ycode's dynamic linker | `MacUserland/dyld` (`dyld.md`) |
| `/usr/lib/system/libdispatch.dylib`, `libsystem_c`, `libsystem_m`, `libsystem_malloc`, `libsystem_blocks`, `libsystem_info`, `libunwind`, `libcompiler_rt` | Aliases: empty dylibs that re-export libSystem | `build.sh` (`install_sublibrary_aliases`) |

On a Mac, libSystem re-exports a set of sub-libraries, and libraries built
against the SDK sometimes name one of them directly (the Swift Concurrency
runtime binds its dispatch calls to `/usr/lib/system/libdispatch.dylib`).
Ycode's libSystem is one image, so each such name is an alias whose only
content is an `LC_REEXPORT_DYLIB` of libSystem: a two-level bind to the
alias finds the symbol in libSystem (`dyld.md` §6).

libSystem names the three host libraries with `LC_REEXPORT_DYLIB`, so a
program's two-level binds to libSystem find their symbols (`dyld.md` §6).
The host libraries are the same builds the simulator uses, with their
`LC_BUILD_VERSION` platform rewritten to macOS in the macOS userland root
(the images are unsigned, so the rewrite is safe, as for visionOS in
`visionos.md` §7.2).

All of these live in the **macOS userland root**
(`MacUserland/out/root/`), which `ycode-simd --macos` serves read-only at
the guest's `/` (§9).

## 3. Initialization

libSystem has one initializer. Ycode's dyld runs it first (`dyld.md` §7),
with `(argc, argv, envp, apple, vars)`. It:

1. Saves `vars` (the program's argc, argv, environ and progname pointers)
   for `getenv`, `_NSGetArgv` and friends.
2. Calls `__libkernel_init(&kernel_functions, envp, apple, vars)` with a
   version-5 table: `dlsym`, `malloc`, `free`, `realloc`, a
   `_pthread_exit_if_canceled` that does nothing, the reserved members
   NULL, the later members NULL (`host-library-init.md` §2.1 allows this).
3. Calls `__libplatform_init(NULL, envp, apple, vars)`.
4. Calls `__pthread_init(&pthread_functions, envp, apple, vars)` with a
   version-2 table: libSystem's `exit`, `malloc`, `free` (§2.5 of that
   spec).
5. Initializes malloc, the stack-protector guard (from `getentropy`), and
   the three standard streams.
6. Calls `__pthread_late_init(envp, apple, vars)`.
7. Initializes dispatch (the main queue).
8. Sets `errno` to 0.

`_libc_initializer`, `__malloc_init`, `libdispatch_init` and the other
steps of `host-library-init.md` §1.2 are internal to Ycode's libSystem.

## 4. ABI facts this library depends on

These are public layouts that SDK headers compile into programs. Ycode's
definitions must match them exactly.

| Fact | Value | Why it matters |
|---|---|---|
| `FILE` | 152 bytes; `_p` at 0, `_r` at 8, `_w` at 12, `_flags` (short) at 16, `_file` (short) at 18; `__SEOF` 0x20, `__SERR` 0x40 | The SDK's `getc`/`putc`/`feof`/`ferror`/`fileno` macros read these fields inline. Ycode keeps `_r` and `_w` at 0 so the macros always call `__srget`/`__swbuf`; the rest of the structure is Ycode's own |
| Standard streams | `__stdinp`, `__stdoutp`, `__stderrp` are exported `FILE *` variables | `stdout` is `__stdoutp` in the SDK |
| `errno` | `*__error()` (from libsystem_kernel) | |
| `pthread_mutex_t` / `pthread_cond_t` | 64 / 48 bytes: a `long` signature then opaque bytes; static initializer signatures `0x32AAABA7` / `0x3CB0B1BB` | Static initializers in programs (provided by `libsystem_pthread`) |
| `pthread_key_t` | `unsigned long` | |
| `dispatch_once_t` | `long`; done = `~0` | The SDK's inline `dispatch_once` skips the call when the predicate is `~0`, so the function must leave it `~0` when done |
| The main queue | `dispatch_get_main_queue()` is the address of the exported data symbol `_dispatch_main_q` | Ycode exports that symbol as its main-queue object |
| `dispatch_time_t` | `uint64_t`; `DISPATCH_TIME_NOW` 0, `DISPATCH_TIME_FOREVER` `~0` | Values are otherwise opaque; Ycode's are nanoseconds of the monotonic clock |
| Global queue identifiers | priorities high 2, default 0, low −2, background −32768; QoS classes 0x21, 0x19, 0x15, 0x11, 0x09 | `dispatch_get_global_queue` arguments |
| Block literal | `isa`, `int flags`, `int reserved`, `invoke`, `descriptor`, captures; descriptor `reserved`, `size`, then `copy` and `dispose` when flag `1<<25` | clang's public Block ABI |
| Block flags | refcount mask 0xFFFE, needs-free `1<<24`, has-copy-dispose `1<<25`, is-global `1<<28` | |
| `__block` variables | `isa`, `forwarding`, `int flags`, `int size`, then `keep`/`destroy` helpers when flag `1<<25`, then the variable | The copy helper calls `_Block_object_assign` with field kind 8 |
| `_Block_object_assign` kinds | object 3, block 7, byref 8, weak 16, caller 128 | |
| Stack protector | `__stack_chk_guard` is an exported `long`; `__stack_chk_fail` never returns | Programs built with `-fstack-protector` read it |
| Stack probe | `__chkstk_darwin` (compiler-rt on a Mac, re-exported by libSystem): frame size in `x9`, only `x9` and the flags change | clang calls it in every function whose frame exceeds a page; Ycode's libSystem forwards it to libsystem_pthread's probe (`compiler_rt.c`) |
| `ProgramVars` | five pointers (`dyld.md` §7.1) | |

## 5. malloc

- Small sizes (up to 1 KB) are rounded to 16 bytes, medium sizes (up to
  64 KB) to a power of two; each class has a free list. Memory comes from
  1 MB anonymous mappings. Each block has a 16-byte header holding its
  class, so `free`, `realloc` and `malloc_size` need no lookup.
- Larger blocks are separate anonymous mappings, unmapped on `free`.
- One `os_unfair_lock` protects the allocator (adequate for the samples;
  per-thread caches are a later speed task).
- `posix_memalign` and `aligned_alloc` over-allocate and keep a marker
  header in front of the aligned block that points back to the real one.
- Exported: `malloc`, `calloc`, `realloc`, `reallocf`, `free`, `valloc`,
  `posix_memalign`, `aligned_alloc`, `malloc_size`, `malloc_good_size`.

## 6. libc subset

- **Strings and memory:** the C standard functions a program needs most
  (`mem*`, `str*`, `strl*`, `strdup`, `strndup`, `strerror`,
  `strerror_r`) and the fortified `__*_chk` forms the SDK emits.
- **stdio:** buffered streams with the standard full, line and no
  buffering rules (stdout line-buffered on a terminal, stderr
  unbuffered); `fopen`, `fdopen`, `fclose`, `fread`, `fwrite`, `fgets`,
  `getline`, character I/O, `fseek`/`ftell`, `setvbuf`, the `printf`
  family including `asprintf` and `dprintf`, `perror`, `remove`.
- **Formatting:** flags, width, precision, `*`, the length modifiers
  `hh h l ll q j z t L`, conversions `d i u o x X p c s f F e E g G a A n %`.
  Floating point is printed by a simple digit generator that rounds to
  nearest (an exact tie such as 3.25 to one place goes to the even digit,
  as the default round-to-nearest-even mode gives); it is not correctly rounded for
  every value, and `%a` prints decimal exponent form (known gaps).
- **stdlib:** `getenv`, `setenv`, `unsetenv`, the `ato*` and `strto*`
  integer conversions, `strtod` (simple), `abs`/`labs`/`llabs`, `qsort`,
  `bsearch`, `rand`/`srand`, the `arc4random` family (from `getentropy`),
  `exit`, `atexit`, `__cxa_atexit`, `abort`, `getprogname`,
  `_NSGetArgc`, `_NSGetArgv`, `_NSGetEnviron`, `_NSGetProgname`,
  `_NSGetExecutablePath`, `_NSGetMachExecuteHeader`.
- **Time and sleep:** `nanosleep`, `usleep`, `sleep`, `clock_gettime`
  (`CLOCK_REALTIME`, `CLOCK_MONOTONIC`), `time`.
- `exit` runs the `atexit`/`__cxa_atexit` handlers in reverse order,
  flushes every stream, and ends the process with the `exit` system call.
  `abort` sends `SIGABRT` to the process and, if it survives, exits with
  status 134.

## 7. Blocks and dispatch

### 7.1 Blocks runtime

`_Block_copy`, `_Block_release`, `_Block_object_assign`,
`_Block_object_dispose` and the class symbols `_NSConcreteStackBlock`,
`_NSConcreteGlobalBlock`, `_NSConcreteMallocBlock`, following the layouts
of §4. Copying a stack block allocates a heap copy, runs its copy helper
(which moves `__block` variables to the heap through
`_Block_object_assign`), and sets its reference count to 1. Global blocks
are never copied. Without Objective-C, captured objects are plain pointers
(no retain).

### 7.2 Dispatch subset

Ycode's own small implementation on pthreads. It stands where the
Apache-2.0 libdispatch would; why that is not built yet is in
`macos-apps.md` §9.4.

- **Objects** have a reference count (`dispatch_retain`/`release`,
  `os_retain`/`os_release`).
- **Global concurrent queues** (one per priority, all served by one worker
  pool): work items go on a shared run list; up to 16 worker threads are
  created on demand and wait for work.
- **Serial queues** (`dispatch_queue_create` with a NULL or serial
  attribute) keep a FIFO; when the first item arrives, a drain task is put
  on the worker pool; the drain runs items in order until the FIFO is
  empty. Concurrent attributes give a concurrent queue that forwards to the
  pool.
- **`dispatch_sync`** to a serial queue: if the queue is idle, the caller
  takes it and runs the work on its own thread; otherwise it queues a
  marker and waits until the drain reaches the marker and hands the queue
  over. FIFO order is kept, and a blocked caller never occupies a worker
  that the queue needs. `dispatch_sync` to a concurrent queue runs the work
  on the caller.
- **Main queue:** `dispatch_main` makes the main thread serve the main
  queue forever; work for the main queue before that is kept.
- **Timers:** one timer thread with a deadline-ordered list serves
  `dispatch_after` and timer sources.
- **Groups, semaphores, `dispatch_once(_f)`, `dispatch_apply(_f)`**
  (iterations run on the caller's thread, in order; allowed, because
  `dispatch_apply` does not promise concurrency), `dispatch_time`,
  `dispatch_walltime`.

### 7.3 Additions for Swift Concurrency (stage B)

- **Times.** A `dispatch_time_t` is monotonic nanoseconds, `~0` (forever),
  or a wall-clock time: bit 63 set and nanoseconds since 1970 below it;
  `DISPATCH_WALLTIME_NOW` (`~1`, the SDK's constant) means the wall clock
  now. `dispatch_walltime` and `dispatch_time` on a wall-clock base give
  wall-clock times; every wait converts its deadline to monotonic time
  when it starts waiting.
- **Sources** (`dispatch_source_create`): the timer type and the custom
  data types (`DATA_ADD`, `DATA_OR`, `DATA_REPLACE`). The type objects are
  exported data symbols (`_dispatch_source_type_timer` and others; the
  SDK's `DISPATCH_SOURCE_TYPE_*` macros take their addresses). A source is
  created inactive; `dispatch_activate` or `dispatch_resume` starts it,
  `dispatch_suspend` stops deliveries. Event, cancel and registration
  handlers (functions or blocks) run on the source's queue, one delivery
  at a time, with `dispatch_source_get_data` reporting what accumulated
  (a timer's fire count). A repeating timer re-arms from the time it
  fired; leeway is ignored. File-descriptor, signal, process and memory
  pressure sources are not implemented.
- **Queue identity.** The queue whose work a thread runs is kept in a
  pthread key; `dispatch_assert_queue` (exported also as
  `dispatch_assert_queue$V2`, the name the SDK binds) and
  `dispatch_assert_queue_not` check it, printing
  `BUG IN CLIENT OF LIBDISPATCH: ...` and aborting on failure. The main
  thread outside any queue counts as being on the main queue.
- **Accepted, no effect:** target queues (`dispatch_set_target_queue`,
  `dispatch_queue_create_with_target`), QoS and autorelease attributes.
- **Vouchers:** Ycode has none; `voucher_copy` returns NULL and
  `voucher_adopt` releases its argument and returns NULL.

## 8. `dlfcn` and image queries

`dlopen`, `dlsym`, `dlclose`, `dlerror`, `dladdr`, `_dyld_image_count`,
`_dyld_get_image_header`, `_dyld_get_image_name`,
`_dyld_get_image_vmaddr_slide`, `_dyld_register_func_for_add_image` and
`_NSGetExecutablePath` call through the dyld's table (`dyld.md` §7.2),
found in libSystem's exported variable `_ycode_dyld_api`.

## 9. Build

`MacUserland/build.sh` (Linux or macOS, with the Swift toolchain's
`clang`, `ld64.lld` and LLVM tools, as `SimHostLibs/build.sh`):

1. Needs `SimHostLibs/out/` built first (the three host libraries and
   their `.tbd` link stubs).
2. Compiles the dyld and libSystem for `arm64-apple-macos14.0`,
   freestanding, `-fno-builtin`, no stack protector, and strips the
   objects' platform tags.
3. Links libSystem as `/usr/lib/libSystem.B.dylib` with chained fixups,
   re-exporting the three host libraries (through `.tbd` stubs retargeted
   to macOS), and writes its own `.tbd` for linking programs on Linux.
4. Lays out `out/root/` (§2) with the host libraries retagged to macOS.
5. Builds the Embedded Swift sample (§10) when `swiftc` is present.
6. Runs the host unit tests (`MacUserland/tests/`).

## 10. The Embedded Swift sample

The Mac's Xcode toolchain ships no Embedded Swift standard library for
macOS. The open Swift toolchain (Swift 6.4 on Linux) ships one for
`arm64-apple-ios` (minimum iOS 18), whose code uses the same Darwin arm64
calling convention. The build compiles the sample for `arm64-apple-ios18.0`
with Embedded Swift, strips the platform tags of the object and of the
toolchain's `libswiftUnicodeDataTables.a` members (needed for `String`
comparison), and links them as a **macOS** executable against Ycode's
libSystem `.tbd`. The result imports only `putchar`, `posix_memalign`,
`free`, `memcmp`, `bzero`, `arc4random_buf`, `exit` and the stack
protector. License of the linked Swift code: Apache-2.0 with the Runtime
Library Exception.

## 11. Not supported yet

Locales other than C/POSIX and UTF-8 (`setlocale` accepts any `*.UTF-8`
name and behaves as the C locale), correct floating-point *printing*
(parsing is LLVM libc's, §13), `fork`, signals beyond what the kernel
library provides, `syslog`, `os_log` storage, XPC, time zones with
daylight-saving rules (`TZ` may name UTC or a fixed offset; §12),
dispatch file-descriptor, signal and process sources, dispatch I/O and
data objects, `malloc` zone introspection, directory services beyond the
one user and the `wheel`/`staff` groups (§12), `iconv`, regular
expressions, `glob`, `popen`, `system`, `getaddrinfo` and the resolver.

## 12. libc for the Swift runtime, libc++ and Foundation (stage B)

Added from the C standard, POSIX and Apple's public man pages; every
structure the SDK's headers expose has the headers' layout.

| Area | Functions | Notes |
|---|---|---|
| Character classes | `_DefaultRuneLocale`, `_CurrentRuneLocale`, `___runetype`, `__maskrune`, `___tolower`/`___toupper`, `is*`/`to*`, wide `isw*`/`tow*`, `wctype`, the `_l` forms | The SDK's inline `<ctype.h>` functions read `_DefaultRuneLocale.__runetype[c]` directly, so the table (public `_RuneLocale` layout) is filled at initialization with the C locale's classes |
| Locales | `setlocale`, `localeconv(_l)`, `newlocale`, `duplocale`, `freelocale`, `uselocale`, `querylocale`, `nl_langinfo(_l)`, `___mb_cur_max(_l)`, `strcoll(_l)`, `strxfrm(_l)`, `strto*_l`, `*printf_l`, `sscanf_l` | One set of data: C with UTF-8 multibyte text |
| Wide characters | `wcs*`, `wmem*`, `mbrtowc`, `wcrtomb`, `mbsrtowcs`, `wcsrtombs` and the `n`/`_l` forms, `wcsto*`, `swprintf`, `fputwc`/`fgetwc`/`ungetwc` | UTF-8; `ungetwc` takes back ASCII only (one pushback byte) |
| Formatted input | `sscanf`, `vsscanf`, `fscanf`, `scanf` | All C conversions, `%[`, `*`, widths, length modifiers |
| Stream locks | `flockfile`, `ftrylockfile`, `funlockfile` | **Recursive** (owner and depth in the `FILE`'s Ycode-private bytes): the Swift standard library's `print` holds the lock while it writes |
| Images | `getsectiondata`, `getsegmentdata`, `getsectbynamefromheader_64`, `_dyld_find_unwind_sections`, `_dyld_get_image_header_containing_address`, `_dyld_register_func_for_remove_image` (never called: no unloading) | From the loaded Mach-O headers |
| Backtraces and assertions | `backtrace` (frame-pointer walk within the thread's stack), `backtrace_symbols(_fd)`, `__assert_rtn`, `asl_log` (accepts and drops) | |
| Version checks | `_availability_version_check`, `os_system_version_get_current_version` | Ycode's macOS userland reports **macOS 27.0** |
| Directories | `opendir`, `fdopendir`, `readdir(_r)`, `closedir`, `rewinddir`, `telldir`, `seekdir`, `dirfd`, `scandir`, `alphasort` | From the kernel's `getdirentries64`; `DIR` in the public layout (the SDK's `dirfd` macro reads its first field) |
| Traversal and removal | `fts_open`/`fts_read`/`fts_children`/`fts_set`/`fts_close` (the pre-macOS 28 `<fts_compat.h>` layout), `removefile` with its state, callbacks and cancellation | Ycode's fts never changes directory (`FTS_NOCHDIR` behavior) |
| Paths | `getcwd` (`F_GETPATH` on "."), `realpath` (also as `realpath$DARWIN_EXTSN`), `statvfs`, `fstatvfs`, `mkstemp(s)`, `mkdtemp`, `mktemp`, `confstr` (`_CS_PATH`, `_CS_DARWIN_USER_{DIR,TEMP_DIR,CACHE_DIR}` under `TMPDIR`), `sysdir_*_search_path_enumeration` (the documented Mac layout; user paths start with `~`) | |
| Files | `copyfile`, `fcopyfile` (data and mode; no ACLs or extended attributes), `copyfile_state_*` | |
| System | `sysctl`, `sysctlbyname`, `sysctlnametomib` (the kernel's name-to-OID query), `uname`, `gethostname`, `memset_s`, `waitpid`, `wait`, `clock_getres`, `clock_gettime_nsec_np` | |
| Users and groups | `getpwuid(_r)`, `getpwnam(_r)`, `getlogin(_r)`, `getgrgid(_r)`, `getgrnam(_r)` | One user from the environment (`USER`, `HOME`, `SHELL`; uid from the kernel, gid 20), plus `root`; groups `wheel` (0) and `staff` (20) |
| Calendar time | `gmtime(_r)`, `localtime(_r)`, `mktime`, `timegm`, `tzset`, `tzname`, `timezone`, `daylight`, `strftime(_l)` (all conversions), `asctime(_r)`, `ctime(_r)`, `difftime` | Civil-date arithmetic over the proleptic Gregorian calendar. `TZ`: UTC, or a fixed offset written POSIX style (`EST5`, `<+03>-3`); anything else is UTC |
| UUIDs | `uuid_generate(_random,_time)` (version 4, random), `uuid_parse`, `uuid_unparse(_lower,_upper)`, `uuid_compare`, `uuid_copy`, `uuid_clear`, `uuid_is_null` | |
| Allocation | `malloc_default_zone`, `malloc_zone_from_ptr`, `malloc_create_zone` and the `malloc_zone_*` calls (every zone is the default zone, public `malloc_zone_t` layout), `malloc_type_*` (the type identifier is ignored) | |
| Message catalogs | `catopen` (fails), `catgets` (returns the default text), `catclose` | |
| Strings | `strncasecmp_l`, the `kOSThermalNotificationPressureLevelName` constant | |
| `atexit` | 64 handlers | Unchanged; the Swift libraries register few |

`tools/check_imports.py ROOT IMAGE...` lists every import of the given
images that the userland root does not export, by two-level ordinal and
following re-exports, so a gap shows up before a run instead of as a
"Symbol not found" at load.

## 13. Code from LLVM in libSystem

libSystem is still built freestanding on Linux or a Mac (§9). Three LLVM
projects (Apache-2.0 WITH LLVM-exception) are compiled into it from the
`swiftlang/llvm-project` checkout that `sources.sh` fetches
(`LLVM_PROJECT` overrides):

| Part | What | How |
|---|---|---|
| LLVM libc | The math library (`sin` ... `tgamma`, float forms, `sincos`, `__sincos_stret` and `__exp10`, which clang emits on Darwin) and `strtod`/`strtof`/`strtold`(`_l`), `atof` | `libsystem/llvm_libc.cpp` gives LLVM's functions (in their own C++ namespace) their C names. Built in LLVM libc's full-build mode with `-U__APPLE__` (its generic floating-point environment code), errno through `__error()`, and **no errno from math functions** (Darwin's `math_errhandling` is `MATH_ERREXCEPT`). Every LLVM libc function the wrapper calls is compiled from `libc/src/{math/generic,stdlib}/<name>.cpp` |
| Ycode, on LLVM libc | `sinh`, `cosh`, `tanh`, `asinh`, `acosh`, `atanh`, `erf`, `erfc`, `lgamma(_r)`, `tgamma`, the Bessel functions `j0` ... `yn` | This LLVM libc lacks the double forms; written in `llvm_libc.cpp` from their identities, series and asymptotic expansions: accurate to a few ulps (the Bessel functions to about 1e-10), not correctly rounded |
| compiler-rt builtins | 128-bit division, shifts, multiplication with overflow, conversions (`__divti3`, `__udivti3`, `__modti3`, `__umodti3`, `__muloti4`, `__floattidf`, ...) | Compiled from `compiler-rt/lib/builtins/<name>.c` |
| libunwind | `_Unwind_*` (the Itanium unwinding interface) and `unw_*` | Compiled from `libunwind/src` against Ycode's minimal headers (`libsystem/include/`); finds each image's `__unwind_info` and `__eh_frame` through `_dyld_find_unwind_sections` (§12) |

The licence of each project travels with the userland (`out/root/usr/share/licenses`).

## 14. Thread-local variables

C `__thread` and C++ `thread_local` variables (libc++abi's exception
globals use one). From the public Mach-O facts: an image's
`S_THREAD_LOCAL_VARIABLES` section holds one descriptor per variable,
`{ thunk, key, offset }`; the linker binds every thunk to libSystem's
`_tlv_bootstrap`; the `S_THREAD_LOCAL_REGULAR` and
`S_THREAD_LOCAL_ZEROFILL` sections are the initial thread-local block, and
`offset` is the variable's place in it. Compiled code calls
`thunk(descriptor)` and expects the variable's address in `x0`, with
`x1`-`x28`, the frame pointer and every SIMD register unchanged.

Ycode's design (`libsystem/tlv.c`), which needs nothing from the dyld:

1. `_tlv_bootstrap` runs on the first access to any variable of an image.
   Under a lock it finds the image (by the descriptor's address), measures
   its thread-local block, creates one pthread key for it, and rewrites
   every descriptor of the image: `key` = that key, `thunk` =
   `_ycl_tlv_get_addr` (stored last, with release order).
2. `_ycl_tlv_get_addr`'s fast path reads the key's slot at
   `TPIDRRO_EL0 + 8 × key` (the TSD layout of `libsystem_pthread`); a
   non-NULL block plus `offset` is the answer. A key of 0 (a descriptor
   another thread is still rewriting) takes the slow path.
3. The slow path (also the end of `_tlv_bootstrap`) saves `x1`-`x15` and
   `q0`-`q31`, allocates the thread's block, copies the initial values,
   zeroes the rest, and stores it in the key.
4. `_tlv_atexit(fn, object)` (C++ `thread_local` destructors) keeps a
   per-thread list; the thread's exit runs it last in, first out, and the
   key destructors free the blocks.

## Evidence

| Claim | Level |
|---|---|
| §4 layouts and constants | 1 (the macOS SDK's public headers: `stdio.h`, `pthread.h`, `dispatch/*.h`, `crt_externs.h`; clang's Block ABI document) |
| §3 initializer sequence and tables | `host-library-init.md` (its own evidence) |
| Function behavior | C standard, POSIX, Apple's public man pages and libdispatch documentation |
| §12 layouts and constants (`_RuneLocale`, `DIR`, `struct dirent`, `FTS`/`FTSENT`, `struct statfs`/`statvfs`, `struct passwd`/`group`, `malloc_zone_t`, removefile and sysdir constants, `dispatch_assert_queue$V2`, `realpath$DARWIN_EXTSN`) | 1 (macOS SDK public headers) |
| §13 LLVM code | 1 (LLVM sources, Apache-2.0 WITH LLVM-exception) |
| §14 thread-local variable sections and descriptors | 1 (public `<mach-o/loader.h>`); the calling convention of the thunk: 1 (open LLVM's AArch64 Darwin TLS call lowering) |
| Everything else | Ycode design |
