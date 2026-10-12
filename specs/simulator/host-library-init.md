# Spec: initialization, TSD, and errno ABI of the three host libraries

Status: **research result (2026-10-11)**. This spec fills §7 and §8 of
`host-libraries.md`. It describes what `libSystem.B`'s initializer expects
from `libsystem_kernel`, `libsystem_platform`, and `libsystem_pthread`, and
the thread-local-storage (TSD) and errno conventions that other libraries
share with them.

All facts are from Apple's open source (evidence level 1), read through the
GitHub API. The tags are in **Evidence**. This spec restates behavior,
layouts, and constants. It contains no Apple code. Sections marked
**Ycode design** are our own decisions, not Apple behavior.

Inputs: `host-libraries.md`, `host-library-loading.md`,
`host-library-surface.md` (+ `data/host-lib-surface-*.json`),
`darwin-arm64-abi.md`, `darwin-trap-tables.md`, `darwin-process-start.md`,
`dyld-sim-handoff.md`.

Conventions: all offsets are for LP64 arm64 (not arm64e, so no pointer
authentication). "Slot k" means the 8-byte TSD entry with index k.

---

## 1. `libSystem_initializer`: call order and arguments (Q1)

### 1.1 Entry

`libSystem.B`'s initializer is an ordinary image initializer. dyld calls it
first, before every other initializer, with
`(argc, argv, envp, apple, vars)`, where `vars` points to a `ProgramVars`
(§2.7).

### 1.2 Ordered call list

Calls into the three host libraries are **bold**. The others are listed so
that the position of each host call is clear. Before step 1, the initializer
may call `kdebug_trace` (BSD 180), but only when the commpage field
`KDEBUG_ENABLE` (RW page offset 0x100) is non-zero. Ycode fills it with 0, so
this call does not happen. After each step the initializer makes the same
conditional trace call.

| # | Callee (library) | Arguments | Condition |
|---|---|---|---|
| 1 | **`__libkernel_init`** (kernel) | `&libkernel_funcs` (§2.1, version **5**), `envp`, `apple`, `vars` | always |
| 2 | **`__libplatform_init`** (platform) | `NULL` (reserved "future use"), `envp`, `apple`, `vars` | always |
| 3 | **`__pthread_init`** (pthread) | `&libpthread_funcs` (§2.5, version **2**), `envp`, `apple`, `vars` | always |
| 4 | `_libc_initializer` (libsystem_c) | `&libc_funcs` (version 2), `envp`, `apple`, `vars` | always |
| 5 | `_sanitizers_init` | `envp`, `apple` | LP64, not DriverKit |
| 6 | `__malloc_init` (libsystem_malloc) | `apple` | always |
| 7 | `_dyld_initializer` (libdyld) | — | always |
| 8 | **`__pthread_late_init`** (pthread) | `envp`, `apple`, `vars` | macOS **or iOS** builds. The simulator is an iOS build, so this call is expected |
| 9 | `libdispatch_init` | — | always |
| 10 | `_libxpc_initializer` | — | not DriverKit |
| 11 | `_libtrace_init` | — | always |
| 12 | `_libsecinit_initializer` | — | if the build has it |
| 13 | `_container_init` | `apple` | if the build has it |
| 14 | `__libdarwin_init` | — | not DriverKit |
| 15 | `__malloc_late_init` | late-init record (version 2: `dlopen`, `dlsym`, internal-diagnostics flag) | always |
| 16 | **`__libkernel_init_late`** (kernel) | `&config` (§2.4, version 3) | only if system-version compatibility or spawn filtering is enabled. Compatibility is enabled only on macOS and visionOS builds. **Not expected in the simulator** (see Open question 3) |
| 17 | end-of-prewarm check | reads `envp` `ActivePrewarm` with `_simple_getenv`; if present, an XPC message | iOS builds |
| 18 | `errno = 0` | through `__error()` (kernel) | always |

`__libkernel_init_after_boot_tasks` (kernel) is never called by the
initializer. Only launchd calls it, through a separate libSystem entry
point.

### 1.3 What each host entry point must do before it returns

**`__libkernel_init(fns, envp, apple, vars)`** (kernel). Apple's steps, in
order:

1. Store `fns` in a library-private global. If `fns->dlsym` is non-NULL,
   store it in a second private global (used only by the legacy exception
   catcher).
2. Call `mach_init()`. It runs its body once (a static "done" flag):
   1. `mach_task_self_` ← the result of Mach trap −28 (`task_self_trap`).
   2. A private "task reply port" global ← Mach trap −26
      (`mach_reply_port`).
   3. If `vm_kernel_page_shift` is 0: read the byte at commpage RW offset
      **0x037** (`KERNEL_PAGE_SHIFT`, legacy offset). Set
      `vm_kernel_page_shift`, `vm_kernel_page_size` = 1 << shift, and
      `vm_kernel_page_mask` = size − 1.
   4. If `vm_page_shift` is 0: read the byte at commpage RW offset **0x025**
      (`USER_PAGE_SHIFT_64`, legacy offset). Set `vm_page_shift`,
      `vm_page_size`, and `vm_page_mask` the same way.
   5. `_init_cpu_capabilities()`. On arm64 this does nothing.
   6. `_pthread_set_self(NULL)`. In the dylib this is a private no-op. Only
      the static libpthread inside dyld does real work here (§5.4).
3. On arm64, the "PFZ setup": find `apple` key `pfz`. Parse the value as hex
   after a mandatory `0x` (both letter cases). On a bad character, stop and
   change nothing. A non-zero value is stored as the commpage text-page
   base and used to locate a helper routine on that page. **Ycode's
   libraries may skip this**: nothing outside the kernel library reads it.

It does not touch TSD, errno, or `vars`.

**`__libplatform_init(future_use, envp, apple, vars)`** (platform). The
host library is a macOS build, so the non-simulator steps apply:

1. Security configuration: read `apple` key `security_config` (hex). Keep
   only the known bits (hardened heap, TPRO, guard objects, script
   restrictions, …) in a private global. Ycode passes `0x0`.
2. PFZ setup again (a private copy in libplatform): parse `pfz` as above.
   Then **erase the whole `pfz=…` string in `apple[]`** (key included) by
   zero-filling it. This runs after `__libkernel_init`, so the kernel
   library has already read the value.
3. `_simple_asl_init(envp, vars)`:
   1. Get the simple-ASL context through `os_alloc_once` with key **21**
      (`LIBSYSTEM_PLATFORM_ASL`). The first use allocates memory (§7.1). The
      context starts as progname = `"unknown"` and fd = −1.
      **Slot 21 is shared with the simulator's own platform library**
      (`libsystem_sim_platform`), which uses the simulator layout of the
      context (level 1, libplatform `src/simple/asl.c`): the host layout
      is 32 bytes (enabled @0, progname @8, fd @16, @24 unused); the
      simulator layout is 40 bytes and adds `sim_connect_lock` (an
      `os_unfair_lock`) at +32, with `sim_log_path` read from the same
      block. **Ycode (normative):** use the host layout and allocate a
      **48-byte zeroed** block, so the simulator's fields read as NULL and an
      unlocked lock. (On the Mac the 32-byte block happens to be followed by
      a zero word; a smaller block made the lock overlap another slot's data
      and live-lock `launchd_sim`, stage 4c.)
   2. If `envp` `ASL_DISABLE` = `1`, stop.
   3. Mark logging enabled. If `vars` and `vars->__prognamePtr` are
      non-NULL, progname ← `*vars->__prognamePtr`.
4. `__libkernel_platform_init(&string_functions)` (kernel), with the
   version-1 string table (§2.2). The kernel library then uses those
   routines for its own string operations.

**`__pthread_init(funcs, envp, apple, vars)`** (pthread). Returns `int` 0.
`libSystem.B` declares it as `void` and ignores the value. Steps:

1. If `funcs` is non-NULL: `exit` ← `funcs->exit`. If `funcs->version` ≥ 2,
   also take `malloc` and `free`.
2. **Adopt the main thread.** On arm64 the main thread's `pthread_t` is
   computed as **`TPIDRRO_EL0` − 224** (§5.1). The TSD base must therefore
   already be set when `__pthread_init` runs. On macOS the static libpthread
   inside dyld sets it (§5.4). The code checks the result only for NULL,
   which on arm64 cannot catch an unset base. With `TPIDRRO_EL0` = 0 it
   writes to `0xFFFF_FFFF_FFFF_FF20` and faults.
3. Store this as the main thread and give it a signature (§5.2) with the
   current, still zero, munge token.
4. `host_info(mach_host_self(), HOST_PRIORITY_INFO)`. A failure crashes.
   Keep `user_priority` (31 on xnu), `minimum_priority` (0), and
   `maximum_priority` (79). Then `mach_port_deallocate` the host port.
   `sched_get_priority_min/max` later return user_priority ∓ 16.
5. Main stack: parse `apple` `main_stack=<top>,<size>,<alloc>,<allocsize>`
   (four hex values with `0x`, separated by commas). **Zero the value
   bytes** after parsing. If the key is missing or top/size is 0, use
   `sysctl {CTL_KERN, KERN_USRSTACK}` for the top (falling back to the
   default 64-bit user stack constant), size = 8 MiB (`DFLSSIZ`), and
   alloc = allocsize = 0.
6. Munge token: parse `apple` `ptr_munge=` (hex) and zero the value bytes.
   If that gives 0, use `envp` `PTHREAD_PTR_MUNGE_TOKEN` (hex). **If it is
   still 0, crash** ("Token from the kernel is 0"). Store the token and
   re-sign the main thread.
7. Initialize the main `pthread_t` from the default attributes (§5.3): set
   slots 0, 1, 4, and 7, the lock, and the stack fields (stackaddr = top,
   stackbottom = top − size, freeaddr = alloc, freesize = allocsize,
   guardsize = one VM page). Policy and inheritance come from the defaults,
   cancel state = enabled + deferred, joinable = true.
8. Main thread port: parse `apple` `th_port=` (hex) and zero the value
   bytes.
9. Main-thread common init (this is also re-run in a fork child):
   1. Empty the global thread list and initialize its lock and the
      thread's lock.
   2. Clear the cleanup stack, join context, and exit gate.
   3. Slot 3 ← the `th_port` name, or `mach_thread_self()` if it was
      absent.
   4. Slot 2 ← a new reply port from `mach_port_construct` (Mach trap −24)
      with flag `MPO_REPLY_PORT`.
   5. Slots 8 and 9 ← 0.
   6. Insert the thread into the list. Thread count = 1. Run the
      introspection "thread start" hook if one is installed.
10. Kernel registration (§6.1): fill the registration record and call
    `__bsdthread_register`. If the result is > 0, it **must** contain all
    of FINEPRIO, BSDTHREADCTL, SETSELF, QOS_MAINTENANCE, and QOS_DEFAULT,
    or the library crashes. It is then stored as the "supported features".
    If the returned `main_qos` is not "unspecified", it becomes the main
    QoS and slot 4. A non-zero `stack_addr_hint` replaces the thread-stack
    placement hint.
11. Read the environment switches `PTHREAD_KEY_LEGACY_DESTRUCTOR_ORDER`,
    `PTHREAD_KEY_LEGACY_DESTRUCTOR_ORDER_LOG`, the mutex policy
    (from the registration record and `envp`), JIT write-protect setup
    (macOS arm64 configuration), and `PTHREAD_YIELD_TO_ZERO`.

Note: `__pthread_init` **does not** set `TPIDRRO_EL0` and does not set the
`thread_id` field. Both are expected from the bootstrap step in §5.4.

**`__pthread_late_init(envp, apple, vars)`** (pthread). Only finishes JIT
write-protect setup. Ycode: no-op.

**`__libkernel_init_late(config)`** (kernel). For `config->version` ≥ 1, it
may enable the macOS or iOS "system version compatibility" shims for
`open`, or (version ≥ 3) spawn filtering. Ycode: accept and ignore.

### 1.4 Entry points called later by other libraries

| Entry point | Library | Caller | Arguments | Must do |
|---|---|---|---|---|
| `__libkernel_voucher_init` | kernel | libdispatch (2 importers) | `&voucher_funcs` (§2.3, version 3) | Store the table pointer. Return `KERN_SUCCESS` (0) |
| `__libkernel_platform_init` | kernel | platform (step 2.4) | `&string_funcs` | Store it. Return 0 |

---

## 2. Callback and data structures (Q2)

All structures are passed by pointer to **read-only** memory. Each
"version" field is an `unsigned long` (8 bytes). Rule for every versioned
table: **later versions only append members.** A callee must accept any
version ≥ 1 and read only the members that its version covers. Unset
members are NULL.

### 2.1 `_libkernel_functions` (libSystem → kernel). Latest version: **5**

| Offset | Member | Signature | Added in | Meaning |
|---|---|---|---|---|
| 0 | `version` | unsigned long | 1 | 5 from current Libsystem |
| 8 | `dlsym` | `void *(void *handle, const char *name)` | 1 | Absent on DriverKit |
| 16 | `malloc` | `void *(size_t)` | 1 | Used by the kernel library's private `malloc` |
| 24 | `free` | `void (void *)` | 1 | |
| 32 | `realloc` | `void *(void *, size_t)` | 1 | |
| 40 | `_pthread_exit_if_canceled` | `void (int error)` | 1 | Called from `cerror` (§4.2). **Called without a NULL check** |
| 48–87 | `reserved1`…`reserved5` | 5 pointers | 2 | Removed functions. Always NULL now |
| 88 | `pthread_clear_qos_tsd` | `void (mach_port_t thread)` | 3 | pthread's `_pthread_clear_qos_tsd` (weak in libSystem, may be NULL). Clears the QoS slot of the given thread (`MACH_PORT_NULL` = the current thread) |
| 96 | `pthread_current_stack_contains_np` | `int (const void *addr, size_t len)` | 4 | 1 if the range is on the current thread's stack, 0 if not, negative errno on error |
| 104 | `malloc_type_malloc` | `void *(size_t, malloc_type_id_t)` | 5 | `malloc_type_id_t` = unsigned 64-bit. LP64 only |
| 112 | `malloc_type_free` | `void (void *, malloc_type_id_t)` | 5 | |
| 120 | `malloc_type_realloc` | `void *(void *, size_t, malloc_type_id_t)` | 5 | |

Size at version 5: **128 bytes**. Consumers check `version` before reading
members from versions 3–5. If a member is missing, they fall back to
`malloc`/`free`/`realloc`, or return 0.

### 2.2 `_libkernel_string_functions` (platform → kernel). Latest version: **1**

| Offset | Member | Offset | Member |
|---|---|---|---|
| 0 | `version` (1) | 72 | `strcpy` |
| 8 | `bzero` | 80 | `strlcat` |
| 16 | `memchr` | 88 | `strlcpy` |
| 24 | `memcmp` | 96 | `strlen` |
| 32 | `memmove` | 104 | `strncmp` |
| 40 | `memccpy` | 112 | `strncpy` |
| 48 | `memset` | 120 | `strnlen` |
| 56 | `strchr` | 128 | `strstr` |
| 64 | `strcmp` | | |

Size: 136 bytes. The signatures are the standard C ones. Before this call,
the kernel library uses its own simple fallbacks: `bzero`, `memmove`,
`memset`, `strchr`, `strcmp`, `strcpy`, `strlcpy`, `strlen`.

### 2.3 `_libkernel_voucher_functions` (libdispatch → kernel). Latest version: **3**

| Offset | Member | Signature | Added in |
|---|---|---|---|
| 0 | `version` | unsigned long | 1 |
| 8 | `voucher_mach_msg_set` | `boolean_t (mach_msg_header_t *)` | 1 |
| 16 | `voucher_mach_msg_clear` | `void (mach_msg_header_t *)` | 1 |
| 24 | `voucher_mach_msg_adopt` | `voucher_mach_msg_state_t (mach_msg_header_t *)` | 1 |
| 32 | `voucher_mach_msg_revert` | `void (voucher_mach_msg_state_t)` | 1 |
| 40 | `voucher_mach_msg_fill_aux` | `mach_msg_size_t (mach_msg_aux_header_t *, mach_msg_size_t)` | 3 (version 2 was skipped) |

Size at version 3: 48 bytes. The kernel library's public `voucher_mach_msg_*`
functions forward to these. Without a table, `set` returns FALSE, `adopt`
returns "state unchanged", the others do nothing, `fill_aux` returns 0, and
`voucher_mach_msg_fill_aux_supported` returns FALSE.

### 2.4 `_libkernel_late_init_config` and `_libkernel_init_after_boot_tasks_config`

| Struct | Offset | Member | Type | Version |
|---|---|---|---|---|
| late init (latest **3**) | 0 | `version` | unsigned long | — |
| | 8 | `enable_system_version_compat` | bool | 1 |
| | 9 | `enable_ios_version_compat` | bool | 2 |
| | 10 | `enable_posix_spawn_filtering` | bool | 3 |
| after boot tasks (latest **1**) | 0 | `version` | unsigned long | — |
| | 8 | `enable_posix_spawn_filtering` | bool | 1 |

Both structs are 16 bytes with padding.

### 2.5 `_libpthread_functions` (libSystem → pthread). Latest version: **2**

| Offset | Member | Signature | Added in |
|---|---|---|---|
| 0 | `version` | unsigned long | — |
| 8 | `exit` | `void (int)` | 1 |
| 16 | `malloc` | `void *(size_t)` | 2 |
| 24 | `free` | `void (void *)` | 2 |

Size: 32 bytes. libSystem passes libc's `exit`, `malloc`, and `free`. Until
`exit` is set, pthread uses the raw `__exit` system call.

### 2.6 No libplatform table

`__libplatform_init` receives no function table. Its first argument is
reserved and is always NULL.

### 2.7 `struct ProgramVars` (dyld → every initializer)

| Offset | Member | Type |
|---|---|---|
| 0 | `mh` | `const void *` (the main executable's Mach-O header) |
| 8 | `NXArgcPtr` | `int *` |
| 16 | `NXArgvPtr` | `const char ***` |
| 24 | `environPtr` | `const char ***` |
| 32 | `__prognamePtr` | `const char **` |

Size: 40 bytes. Same as `dyld-sim-handoff.md` §4.

### 2.8 For reference: `_libc_functions` (libSystem → libsystem_c)

This is not passed to Ycode's libraries. Version 2. Members: `version`, the
v1 `atfork_prepare/parent/child` (unused now), `dirhelper`, and the v2
`atfork_prepare_v2/parent_v2/child_v2(unsigned flags, …)`.

---

## 3. TSD ABI (Q3)

### 3.1 The base register

- The TSD array of the current thread starts **exactly at
  `TPIDRRO_EL0`**. Slot k is the 8-byte word at `TPIDRRO_EL0 + 8·k`.
  arm64 has **no bias and no tag bits** in this register. (On 32-bit ARM
  the low 2 bits held the CPU number and were masked off. That does not
  apply here.)
- The base is set only by the platform call (x16 = `0x8000_0000`, x3 = 2,
  x0 = base), which libsyscall exposes as `_thread_set_tsd_base` (exported,
  0 importers), or by the kernel when it starts a pthread or workqueue
  thread (§6).
- `TPIDR_EL0` (the read-write register) is **not** TSD. On Darwin the
  kernel keeps the CPU number in bits 0–11 and the cluster ID in bits 12–19.
  `_os_cpu_number()` reads it. The Ycode VMM sets it per vCPU
  (`darwin-process-start.md` §5).
- Inline readers do `mrs` of `TPIDRRO_EL0` and then a load at `8·k`. So the
  TSD must be **one flat array of 8-byte slots, indexed by key, for every
  valid key**. `pthread_getspecific(k)` must equal the word at
  `base + 8k`.

### 3.2 Slot count

| Build | "External" keys | "Internal" keys | Total slots |
|---|---|---|---|
| macOS (and so the host library under the simulator) | 512 | 256 | **768** |
| iOS device | 256 | 256 | 512 |

libpthread does not support simulator builds at all (its build fails for
the simulator target). The host library is always the macOS build.
**Ycode uses 768 slots.**

Key ranges in the host library:

| Range | Use |
|---|---|
| 0–9 | Reserved for libsyscall/libplatform (§3.3) |
| 10–255 | **Static keys.** `pthread_key_init_np(key, dtor)` accepts 10 ≤ key < 256. `_pthread_setspecific_static` accepts key < 256 |
| 125–209 | Inside the static range: keys that the shared-cache builder assigns to `__thread` variables of cache dylibs. Exported as the 32-bit constants `_pthread_tsd_shared_cache_first` = 125 and `_pthread_tsd_shared_cache_last` = 209 |
| 256–767 | **Dynamic keys** from `pthread_key_create`, which hands out the lowest free key ≥ 256 |

`pthread_setspecific` accepts 10 ≤ key < 768, but only for a created key or
a static key. `pthread_getspecific` performs **no range check**. It returns
the slot at the given index.

### 3.3 The reserved and well-known slots

| Slot | Name (`__TSD_*` / `_PTHREAD_TSD_SLOT_*`) | Content (8-byte slot) | Set by | Read inline by |
|---|---|---|---|---|
| 0 | `THREAD_SELF` / `PTHREAD_SELF` | the `pthread_t` | pthread (thread init) | x86 `pthread_self`. arm64 non-simulator code computes `TPIDRRO_EL0 − 224` instead (§5.1). Simulator builds call `pthread_getspecific(0)` |
| 1 | `ERRNO` | `int *` to this thread's errno | pthread | `__error`, `cerror` (kernel) |
| 2 | `MIG_REPLY` | MIG reply port name (zero-extended) | pthread (main), `mig_get_reply_port` (lazily) | kernel MIG helpers, libdispatch |
| 3 | `MACH_THREAD_SELF` | the thread's own Mach port name | pthread (main), **kernel** (new pthreads, §6.2), pthread (workqueue threads) | **`os_unfair_lock` owner value** (platform), libdispatch thread identity |
| 4 | `THREAD_QOS_CLASS` | `pthread_priority_t` | pthread | `qos_class_self`, libdispatch priority |
| 5 | `RETURN_TO_KERNEL` | uintptr | kernel (offset registered, §6.1) | libdispatch |
| 6 | reserved (Win64/Wine compatibility) | unused | — | — |
| 7 | `PTR_MUNGE` | the pointer-munge token | pthread | setjmp/longjmp and ucontext (platform), any code using the "munge" helpers. **The helpers are not gated for the simulator** |
| 8 | `MACH_SPECIAL_REPLY` | special reply port name | libsyscall/libdispatch | |
| 9 | `SEMAPHORE_CACHE` | cached `semaphore_t` | libplatform/libdispatch | |
| 10 | `__PTK_LIBC_LOCALE_KEY` | libc locale | libsystem_c | |
| 11 | reserved (Win64) | unused | — | |
| 12–16 | libc: localtime, gmtime, gdtoa bigint, parsefloat, ttyname | | libsystem_c | |
| 18 | dyld: `_Unwind_SjLj` key | | dyld/libunwind | |
| 20–29 | libdispatch keys 0–9. 20 = current queue, 21 = frame, 22 = cache, 23 = context, 24 = root-queue observer hooks, 25 = base priority, 26 = introspection/bcounter, 27 = workloop handle, **28 = voucher**, 29 = deferred items | | libdispatch | |
| 30–39 | graphics frameworks (30 = OpenGL) | | | |
| 40–49 | Objective-C runtime | | libobjc | |
| 50–59 | CoreFoundation | | | |
| 60–69 | Foundation | | | |
| 70–79 | QuartzCore | | | |
| 80–89 | CoreData | | | |
| 90–94 | JavaScriptCore | | | |
| 95 | CoreText | | | |
| 100–109 | Swift runtime | | | |
| 110–114 | libmalloc | | | |
| 115–119 | libdispatch workgroups (115 = join token, 116 = workgroup) | | | |
| 120–124 | libdispatch keys 10–14: 120 = quantum (kernel writes it, §6.1), 121 = dsc, 122 = enqueue, **123 = Mach message aux (`__TSD_MACH_MSG_AUX`)**, 124 = thread name | | | |
| 125–209 | shared-cache `__thread` keys (§3.2) | | | |
| 210–216, 217–229 | Simulator libSystem keys for runtimes older than iOS 15.4 (210 locale, 212–216 = libc keys + 200) | | | |
| 230 | objc_trace / perf utilities | | | |
| 231–232 | libsanitizers | | | |

### 3.4 How clients reach the TSD

- **`_os_tsd_get_direct(k)` / `_os_tsd_set_direct(k, v)`** (libsyscall's
  `os/tsd.h`): on arm64 they read `TPIDRRO_EL0` and load or store word k.
  The register read is marked "const", so the compiler may reuse one read
  within a function. **These helpers are not disabled for simulator
  builds.**
- **`_pthread_getspecific_direct(k)` / `_pthread_setspecific_direct(k, v)`**
  (libpthread's `tsd_private.h`):
  - non-simulator builds: the same inline access as above;
  - **simulator builds: a call to `pthread_getspecific(k)`, and a call to
    `_pthread_setspecific_static(k, v)`**. `_pthread_has_direct_tsd()` is 0
    in simulator builds. libdispatch, libobjc, and other simulator images
    therefore reach the TSD through Ycode's exported functions. That is why
    `pthread_getspecific` (132 importers), `_pthread_setspecific_static`,
    and `pthread_key_init_np` are on the surface.
- **libdyld's thread-local-variable getter** (`__tlv_get_addr`, in the
  simulator cache's `libdyld`): it loads the key from the TLV descriptor
  (32-bit at descriptor +8), reads `TPIDRRO_EL0`, and loads `base[key]`.
  If that is 0, it takes the slow path to allocate. This path is **not**
  gated for the simulator, so every `__thread`/`thread_local` access in
  simulator code reads the TSD inline. This is the strongest reason the
  §3.1 flat-array rule is mandatory.
- `pthread_cpu_number_np` reads the low 12 bits of `TPIDR_EL0` (simulator
  libdispatch calls it instead of reading the register inline).

---

## 4. errno (Q4)

### 4.1 Storage

- The kernel library defines an exported global `int errno` (data symbol
  `_errno`, 0 importers).
- Each thread's errno is a field of its `pthread_t` (`err_no`, offset 172,
  §5.1). Slot 1 points to it. For the main thread, `__pthread_init` sets
  slot 1 = &main.`err_no` (§1.3 step 7).
- **`__error()`** (kernel, 724 importers): if slot 1 is non-NULL, return
  it. Otherwise return &`errno` (the global). `libsystem_c`'s `errno` macro
  is `*__error()`, so every simulator image goes through this function.

### 4.2 `cerror` and `cerror_nocancel`

System-call wrappers (arm64, all BSD calls, including the indirect one):

1. x16 = BSD number, `svc #0x80`.
2. If carry is clear: return (x0, and x1 for two-value calls, are the
   result).
3. If carry is set: x0 holds the errno. Set up a frame and call `cerror`
   (cancelable calls) or `cerror_nocancel` (`$NOCANCEL` variants, `getpid`,
   and others), then return its result.

`cerror(err)`:

1. Call `_libkernel_functions->_pthread_exit_if_canceled(err)`. In
   libpthread this does something only when the low byte of `err` is
   `EINTR` (4). It then asks the kernel with `__pthread_canceled(0)` (BSD
   333), and if that returns 0 (a cancellation is pending), it records the
   error and exits the thread with `PTHREAD_CANCELED`. There is **no NULL
   check** of the table or the member. A failing system
   call before `__libkernel_init` therefore faults in Apple's library.
   **Ycode must check for NULL.**
2. Continue as `cerror_nocancel(err)`.

`cerror_nocancel(err)`:

1. Global `errno` ← err.
2. If slot 1 is non-NULL, `*slot1` ← err. Both copies are written.
3. Return −1 as a **128-bit** value: x0 = −1 and x1 = −1, so that two-value
   calls also see −1.

Mach traps do not use carry and never touch errno.

### 4.3 Before pthread init, and on the indirect path

- **Before `__pthread_init`.** On macOS the static libpthread inside dyld
  has already set slot 1 = &main.`err_no` (§5.4), so errno is per-thread
  from the very first instruction. If the base were set but slot 1 were 0,
  errno would fall back to the global. **If `TPIDRRO_EL0` = 0**, the read
  of slot 1 loads from address 8 and faults. Ycode must prevent that (§9).
- **The indirect system call** (`syscall(number, …)`, the kernel library's
  `___syscall`): the number is in x0. The variadic arguments are on the
  stack (arm64 Darwin passes every variadic argument on the stack). The
  wrapper loads 7 stack words into x1–x7, sets x16 = 0 (the indirect
  number), traps, and on carry calls `cerror` as in §4.2. The kernel takes
  the real number from x0 (`darwin-trap-tables.md` §5).
- **`ULF_NO_ERRNO`** (flag `0x0100_0000` on `__ulock_wait`/`wait2`/`wake`):
  the kernel turns an error into a **successful** return of −errno (carry
  clear). errno is not touched. libplatform relies on this for
  `os_unfair_lock` and `os_sync_*`.
- `getpid` uses `cerror_nocancel` and caches the pid in a private
  `__current_pid` global (0 = not cached).
- `libSystem_initializer` ends by setting errno to 0 through `__error()`.

---

## 5. `pthread_t` layout and the main thread (Q5)

### 5.1 `struct pthread_s` (host = macOS build, 768 TSD slots)

The tsd offset (224) is fixed by an assertion in libpthread and by
third-party software that hard-codes it. TSD-relative offsets are
`field offset − 224`.

| Offset | TSD-rel. | Field | Type / size | External meaning |
|---|---|---|---|---|
| 0 | −224 | `sig` | long | Signature = (pthread_t XOR munge token) (§5.2). Same position as the public opaque `__sig` |
| 8 | −216 | `__cleanup_stack` | pointer | **Read and written inline by client code** through the public `pthread_cleanup_push/pop` macros |
| 16 | | thread-list link (next, prev) | 2 pointers | internal |
| 32 | | join context | pointer | internal |
| 40 | | exit value | pointer | internal |
| 48 | | policy | u8 | internal |
| 49 | | joinable (bit 0), joiner-cleans-up (bit 1), custom stack (bit 2) | u8 bitfield | **bit 392 = 8·49 is registered with the kernel** (`joinable_offset_bits`, §6.1) |
| 50 | | introspection state | u16 | internal |
| 52 | | exit gate | u32 | internal (ulock address) |
| 56 | | sched param | 8 bytes | internal |
| 64 | | unused padding | pointer | |
| 72 | | per-thread lock | `os_unfair_lock` (u32) | internal |
| 76 | | max TSD key used | u16 | internal |
| 78 | | flags: inherit (8 bits), kernel-allocated, sched-set, workqueue thread, workqueue kill-set | u16 | internal |
| 80 | | thread name | char[64] | internal |
| 144 | | start routine | pointer | internal |
| 152 | | start argument | pointer | internal |
| 160 | | wq event count | int | internal |
| 164 | | wq outside-QoS | bool | internal |
| 165 | | canceled | u8 | internal |
| 166 | | cancel state | u16 | internal |
| 168 | | cancel error | int | internal |
| 172 | −52 | `err_no` | int | slot 1 points here |
| 176 | **−48** | `stackaddr` | pointer | stack **top** (highest address). **Read TSD-relatively by `___chkstk_darwin`** |
| 184 | **−40** | `stackbottom` | pointer | stackaddr − stacksize. Read by `___chkstk_darwin` |
| 192 | | freeaddr | pointer | allocation base |
| 200 | | freesize | size_t | allocation size |
| 208 | | guardsize | size_t | |
| 216 | **−8** | `thread_id` | u64 (8-aligned) | 64-bit thread ID (`thread_selfid`). Read TSD-relatively by `_pthread_threadid_self_np_direct` in non-simulator builds |
| 224 | 0 | `tsd[768]` | 768 × 8 (16-aligned) | **TPIDRRO_EL0 points here** |
| 6368 | | end | | `sizeof` = 6368 bytes |

Derived facts:

- `pthread_self()` on arm64 = `TPIDRRO_EL0 − 224`. It then validates the
  signature (§5.2). Slot 0 holds the same value.
- The public opaque type reserves 8176 + 16 bytes, but libpthread never
  lets clients allocate a `pthread_t`. Clients see only the first 16 bytes
  (`__sig`, `__cleanup_stack`).
- `PTHREAD_SIZE` = `sizeof` rounded up to the VM page = **16 KiB** with
  16 KiB pages. It is passed to `bsdthread_register` and must be ≤ 64 KiB.
- `pthread_layout_offsets` (exported data, CoreSymbolication SPI, 0
  importers) = {version 1, tsd base offset 224, tsd-pointer offset 0, entry
  size 8}, as four u16 values.
- `___chkstk_darwin` (exported by pthread as `____chkstk_darwin`, re-exported
  by libSystem; 2 importers): the size is in x9. It saves and restores x10
  and x11 below SP without moving SP, and clobbers x9 and the flags. If SP
  lies within [stackbottom, stackaddr] of the current thread, and SP − size
  falls below stackbottom, it faults deliberately in the guard page.
  Otherwise it probes every 4 KiB from SP down to SP − size.

### 5.2 Signature and munge

- The signature is `sig` = pthread_t XOR munge token (on arm64e also
  signed, which does not apply here). `pthread_self()` and every API that
  takes a `pthread_t` check it and abort with reason code 4 ("pthread_t was
  corrupted") on mismatch.
- The munge token is the `ptr_munge=` value (§1.3 step 6). It is also
  stored in slot 7 of every thread.

### 5.3 Default attributes and constants that clients embed

| Item | Value |
|---|---|
| default QoS in slot 4 for the main thread and default threads | `0x8FF` = (1 << (8 + LEGACY − 1)) with relpri byte 0xFF. Thread QoS: 0 unspecified, 1 maintenance, 2 background, 3 utility, 4 legacy/default, 5 user-initiated, 6 user-interactive |
| default stack size | 512 KiB (`0x80000`). `pthread_t` is placed 12 KiB above the top of a library-allocated stack (`PTHREAD_T_OFFSET`) |
| static initializer signatures (clients compile these into their data) | mutex `0x32AAABA7`; error-check mutex `0x32AAABA1`; recursive mutex `0x32AAABA2`; first-fit mutex `0x32AAABA3`; cond `0x3CB0B1BB`; once `0x30B1BCBA`; rwlock `0x2DA8B3B4` (each in the first `long`, the rest zero) |
| initialized-object signatures | attr `'THDA'` `0x54484441`, thread `'THRD'`, mutex `'MUTX'` `0x4D555458` (fast `'MUTZ'`), mutexattr `'MTXA'`, cond pristine `'COND'`, condattr `'CNDA'`, once `'ONCE'`, rwlock `'RWLK'`, rwlockattr `'RWLA'` |
| opaque sizes (LP64, after the 8-byte `__sig`) | pthread 8176, attr 56, mutex 56, mutexattr 8, cond 40, condattr 8, once 8, rwlock 192, rwlockattr 16 |
| `os_unfair_lock` | u32. 0 = unlocked. Locked value = owner's thread port name (slot 3). Bit 0 cleared = "has waiters" |
| `os_once_t` | long. 0 = not started. **~0 = done**. The inline client fast path tests for ~0 |

### 5.4 Where the main thread lives and who sets its TSD base

On macOS (and so in the real simulator):

1. dyld links a **static** libpthread variant. That variant owns a
   statically allocated, 64-byte-aligned `struct pthread_s` for the main
   thread in dyld's own data.
2. dyld's early `mach_init` calls that variant's `_pthread_set_self(NULL)`,
   which:
   1. sets the main struct's `thread_id` ← BSD 372 (`thread_selfid`), and
      crashes if that returns −1;
   2. sets slot 0 ← the struct and slot 1 ← &struct.`err_no` ("the bare
      minimum TSD that dyld needs");
   3. sets `TPIDRRO_EL0` ← &struct.`tsd[0]` with the platform call.
3. In a simulator process the **host** dyld does this before it loads
   `dyld_sim`. `dyld_sim` itself never sets the base (`dyld-sim-handoff.md`
   §8). The simulator's `libSystem` then reaches the host `__pthread_init`,
   which adopts that struct (§1.3 step 2) and finishes it.
4. The main stack comes from `apple` `main_stack=` (§1.3 step 5), and the
   main thread port from `th_port=`. The kernel creates both at exec
   (`darwin-process-start.md` §1.4).

**Consequence for Ycode:** there is no host dyld. `TPIDRRO_EL0` is 0 when
`dyld_sim` starts. Something in Ycode must do step 2 before the first TSD
access (§9.1).

---

## 6. Threads and the workqueue (Q6)

This is documentation for later stages. The first milestone needs only the
registration call (§6.1).

### 6.1 `bsdthread_register` (BSD 366)

Called once by `__pthread_init`:

| Register | Value |
|---|---|
| x0 | address of `thread_start` (exported by pthread) |
| x1 | address of `start_wqthread` (exported by pthread) |
| x2 | `PTHREAD_SIZE` (16384), as int |
| x3 | pointer to the registration record (below) |
| x4 | size of the record = **56** |
| x5 | dispatch-queue offset = 20 · 8 = **160** (also in the record) |

The registration record is **packed**, and its `version` is its size:

| Offset | Field | Dir. | Size | libpthread's value |
|---|---|---|---|---|
| 0 | `version` | in/out | 8 | 56 |
| 8 | `dispatch_queue_offset` | in | 8 | 160 (slot 20) |
| 16 | `main_qos` | out | 8 | — |
| 24 | `tsd_offset` | in | 4 | **224** |
| 28 | `return_to_kernel_offset` | in | 4 | 40 (slot 5) |
| 32 | `mach_thread_self_offset` | in | 4 | 24 (slot 3) |
| 36 | `stack_addr_hint` | out | 8 (unaligned) | — |
| 44 | `mutex_default_policy` | out | 4 | — |
| 48 | `joinable_offset_bits` | in | 4 | 392 |
| 52 | `wq_quantum_expiry_offset` | in | 4 | 960 (slot 120) |

Kernel behavior:

1. Reject a size above 64 KiB (`EINVAL`). If x3 ≠ 0, require x4 ≥ 8, copy
   in min(56, x4) bytes, and require `version` = x4 (else `EINVAL`).
2. Compute the stack-placement hint. On arm64 64-bit it is the main stack
   top, truncated to a page.
3. A second registration in the same process fails with `EINVAL` (fork
   resets this).
4. Store `thread_start`, `start_wqthread`, the size, and the offsets. Each
   offset that is not below `size − 8 − tsd_offset` is reset to 0 (off).
5. If x3 ≠ 0, write back: `version` = 56, `main_qos` = the main thread's QoS
   encoded as a priority. The kernel sets the main thread to LEGACY if it
   had no QoS, giving `0x8FF`-style values; otherwise "unspecified" = 0.
   Also write `stack_addr_hint` and `mutex_default_policy`.
6. Return (carry clear) the **feature mask**. xnu returns
   DISPATCHFUNC 0x01 | FINEPRIO 0x02 | BSDTHREADCTL 0x04 | SETSELF 0x08 |
   QOS_MAINTENANCE 0x10 | KEVENT 0x40 | WORKLOOP 0x80 | COOPERATIVE_WORKQ
   0x100 | QOS_DEFAULT 0x4000_0000 = **`0x4000_01DF`**, plus JIT bits 0x200,
   0x800, 0x1000 by entitlement.

libpthread requires 0x02 | 0x04 | 0x08 | 0x10 | 0x4000_0000 =
`0x4000_001E` in any positive result. `_pthread_workqueue_supported()`
crashes later if the stored mask is 0, and libdispatch calls it when it
first creates root queues.

### 6.2 `bsdthread_create` (BSD 360) and the `thread_start` register state

`pthread_create` allocates stack + guard + `pthread_t` with `mach_vm_map`
(tag `VM_MEMORY_STACK`, near the stack hint), initializes the struct, and
calls `bsdthread_create(func, arg, stack, pthread, flags)`. `stack` =
`pthread` for library-allocated stacks. `flags` always includes
`PTHREAD_START_CUSTOM` 0x0100_0000, plus SETSCHED 0x0200_0000 (with
policy << 16 and importance in the low 16 bits) or QOSCLASS 0x0800_0000
(with the QoS in the low 24 bits), and SUSPENDED 0x2000_0000. The kernel:

1. creates a thread and copies out its port name (`EMFILE` if that fails);
2. requires `PTHREAD_START_CUSTOM` (`EINVAL` otherwise);
3. if a TSD offset is registered: sets the new thread's TSD base =
   `pthread + tsd_offset` and adds `PTHREAD_START_TSD_BASE_SET`
   0x1000_0000 to the flags;
4. clears `PTHREAD_START_SUSPENDED` in the flags it passes on;
5. sets the user register state (everything else zero):

   | Register | Value |
   |---|---|
   | pc | registered `thread_start` |
   | x0 | pthread |
   | x1 | the new thread's port name |
   | x2 | func |
   | x3 | arg |
   | x4 | stack |
   | x5 | flags (with TSD_BASE_SET) |
   | sp | stack |
   | TPIDRRO_EL0 | pthread + 224 |

6. applies the sched or QoS policy;
7. if a mach-thread-self offset is registered: **writes the port name
   into the new thread's slot 3** (8-byte store) before the thread runs;
8. resumes the thread unless SUSPENDED was requested;
9. returns `pthread` in x0.

`thread_start` pushes a zero frame record (a sentinel for backtracers) and
calls the C start routine with x0–x5 unchanged. That routine crashes unless
TSD_BASE_SET is present, then runs `func(arg)` and exits the thread.

`bsdthread_terminate` (BSD 361): (stackaddr, freesize, port, semaphore or
ulock address) frees the stack, deallocates the port, signals the joiner,
and never returns.

### 6.3 Workqueue threads and `start_wqthread`

The kernel allocates each workqueue thread's stack:

- guard = 1 page at the bottom;
- 512 KiB stack;
- `self` = stackaddr + 512 KiB + guard + 12 KiB;
- the stack top is `self` rounded down to 16 bytes, or, if it delivers
  kevents, below a 16-entry kevent list and up to 32 KiB of kevent data
  placed under `self`.

On first use, it sets the TSD base = `self + tsd_offset` and adds
`WQ_FLAG_THREAD_TSD_BASE_SET` 0x0020_0000. Register state:

| Register | Value |
|---|---|
| pc | registered `start_wqthread` |
| x0 | self (`pthread_t`) |
| x1 | the thread's port name |
| x2 | stack bottom (stackaddr + guard) |
| x3 | kevent list, or 0 |
| x4 | upcall flags: PRIO_SCHED 0x8000 / PRIO_QOS 0x4000 with the priority in bits 0–11, OVERCOMMIT 0x1_0000, REUSE 0x2_0000, NEWSPI 0x4_0000, KEVENT 0x8_0000, EVENT_MANAGER 0x10_0000, TSD_BASE_SET 0x20_0000, WORKLOOP 0x40_0000, OUTSIDEQOS 0x80_0000, COOPERATIVE 0x100_0000 |
| x5 | kevent count, or −1 = "exit this thread" |
| sp | stack top |

`start_wqthread` pushes a sentinel frame and calls the C routine, which
never returns (a `brk #1` follows). Without REUSE the routine initializes
the `pthread_t` in place, sets slot 3 = x1 itself, and adds the thread to
the list. It then sets slot 4 from the flags, calls the libdispatch worker,
kevent, or workloop callback, and parks with `workq_kernreturn` (BSD 368)
op THREAD_RETURN 0x004, KEVENT_RETURN 0x040, or WORKLOOP_RETURN 0x100.

### 6.4 What Ycode's VMM must emulate later (stage 3b and beyond)

- **3a:** `bsdthread_register`: record the entries and offsets, write back
  the record, and return a positive mask that includes `0x4000_001E`
  (**Ycode design:** start with `0x4000_001F` and add KEVENT, WORKLOOP,
  and COOPERATIVE only when those paths exist). `thread_selfid` (BSD 372)
  must return a unique, non-zero, non-(−1) 64-bit ID.
- **Threads:** `bsdthread_create` with the §6.2 register state, the TSD
  base, and the slot-3 store; `bsdthread_terminate`; `__ulock_wait`,
  `__ulock_wait2`, and `__ulock_wake` (BSD 515, 544, 516) with
  `UL_UNFAIR_LOCK` = 2 and `UL_COMPARE_AND_WAIT` = 1 and the `ULF_NO_ERRNO`
  rule; `__psynch_*` for contended pthread mutexes and condition variables;
  `bsdthread_ctl` (BSD 478) for QoS (SET_SELF 0x100, …); `thread_switch`
  (Mach −61) and `swtch_pri` (−59) for `sched_yield`.
- **Workqueue:** `workq_open` (BSD 367); `workq_kernreturn` (BSD 368) with
  ops SETUP_DISPATCH 0x400 (`pthread_workqueue_setup` — libdispatch's
  config, version 2), REQTHREADS 0x020 / 0x030, SHOULD_NARROW 0x200,
  SET_EVENT_MANAGER_PRIORITY 0x080, and the *_RETURN ops; kevent delivery;
  `kqueue_workloop_ctl` (BSD 530). This requires a real thread pool in the
  VMM, with the §6.3 stack layout and register state.

---

## 7. Other first-boot dependencies (Q7)

### 7.1 Data that other images read directly

These values must be correct before any simulator image uses them.
**Ycode design:** give each of them a static initial value at load time
where the value is known, so that correctness does not depend on whether or
when an init function runs (see Open question 1).

| Symbol | Lib | Type / size | Value / rule |
|---|---|---|---|
| `mach_task_self_` | kernel | `mach_port_t` (u32) | the task self port name (Mach −28). Read directly by 301 images through the `mach_task_self()` macro |
| `vm_page_size`, `vm_page_mask` | kernel | `vm_size_t` (8) | 16384, 0x3FFF (from commpage 0x025 = 14) |
| `vm_page_shift` | kernel | int | 14 |
| `vm_kernel_page_size`, `_mask` / `_shift` | kernel | 8 / int | 16384, 0x3FFF, 14 (from commpage 0x037) |
| `bootstrap_port` | kernel | u32 | starts as 0 (`MACH_PORT_NULL`). Not set by any of the three init functions. It is set later from the bootstrap special port (open question 4) |
| `NDR_record` | kernel | 8 bytes | bytes `00 00 00 00 01 00 00 00` (mig_vers 0, if_vers 0, reserved 0, mig_encoding 0 = NDR 2.0, int_rep 1 = little-endian, char_rep 0 = ASCII, float_rep 0 = IEEE, reserved 0) |
| `_os_alloc_once_table` | kernel | 100 × {long once, pointer ptr} = **1600 bytes** | zero at load. Clients inline: if `once` == ~0, use `ptr`. Otherwise call `_os_alloc_once` (platform) |
| `errno` | kernel | int | 0 |
| `__syscall_logger` | kernel | pointer | NULL (a malloc stack-logging hook) |
| `__is_threaded` | pthread | int | 0. Set to 1 by the first `pthread_create` or the workqueue setup |
| `__unix_conforming` | pthread | const int | 1 |
| `_pthread_tsd_shared_cache_first/last` | pthread | const u32 | 125 / 209 |

`os_alloc_once` keys (Libsystem): 0 notify, 1 libxpc, 2 libsystem_c, 3
info, 4 network, 5 libcache, 6 CommonCrypto, 7 libdispatch, 8 libdyld, 9
keymgr, 10 liblaunch, 11 libmacho, 12 os_trace, 13 blocks, 14 malloc, 15
platform, 16 pthread, 17 stats, 18 libsecinit, 19 coreservices, 20 symptoms,
21 platform ASL, 22 feature flags. Keys 90–99 are reserved for the system.
`_os_alloc_once(slot, size, init)` runs once per slot (an `os_once` gate). It
takes size rounded up to 16 bytes from a private bump heap, made of 2-page
(32 KiB) blocks from `mach_vm_map(ANYWHERE, tag VM_MEMORY_OS_ALLOC_ONCE)`.
The memory is zero-filled. It then stores the pointer, calls `init(ptr)` if
`init` is non-NULL, and marks the slot done (~0).

### 7.2 Locks and once

- `os_unfair_lock_lock` fast path: compare-and-swap 0 → **slot 3** with
  acquire. The slow path (only under contention) uses `__ulock_wait2`. A
  recursive lock by the owner aborts. Unlock: compare-and-swap owner → 0;
  under contention, `__ulock_wake`.
- **Requirement on Mach port names:** the lock uses bit 0 of the owner name
  as the "no waiters" bit. It assumes that **every thread port name has bit
  0 set** and is not 0. Ycode's Mach name allocator must keep this
  property: xnu-style names (index << 8 | generation) whose low byte is odd,
  such as `0x103`.
- `os_once`/`_os_once`: 0 → in progress (owner = slot 3) → ~0 done. Waiters
  use ulock. The optional "quiescent counter" mode reads commpage
  `CPU_QUIESCENT_COUNTER` (RW 0x180). Ycode may always store ~0 directly.

### 7.3 Commpage reads on the init path

`KDEBUG_ENABLE` (0x100, libSystem), `USER_PAGE_SHIFT_64` (0x025), and
`KERNEL_PAGE_SHIFT` (0x037) in `mach_init`. Later: the timebase fields for
`mach_absolute_time`, and `CPU_QUIESCENT_COUNTER`. See
`darwin-process-start.md` §3 and §5 for values.

### 7.4 `_simple_*` and `apple[]` keys

- `_simple_getenv(vector, key)`: scan a NULL-terminated string vector. Match
  when the string starts with `key` immediately followed by `=`. Return the
  pointer just after `=`, or NULL. It is used on both `envp` and `apple`.
- `apple[]` keys consumed by the three libraries: `pfz` (kernel, platform;
  platform erases it), `security_config` (platform), `main_stack`,
  `ptr_munge`, and `th_port` (pthread; **values zeroed after parsing**).
  Others in the init path: `stack_guard` (libc), `malloc_entropy`
  (libmalloc), `executable_path` (dyld, libc), and `subsystem_root_path`
  (libc).
- `_simple_dprintf`/`_simple_asl_log` and friends are used for diagnostics
  and crash messages. They must work without `malloc` (writing straight to
  a file descriptor with `write`).

### 7.5 Traps exercised by the three init functions

| Trap | Where |
|---|---|
| Mach −28 `task_self_trap`, −26 `mach_reply_port` | `mach_init` |
| Mach −15 `mach_vm_map` (or −10 `mach_vm_allocate`) | first `os_alloc_once` (platform step 3) |
| Mach −29 `host_self_trap`; a `host_info` call (an RPC on the host port in Apple's library); Mach −18 `mach_port_deallocate` | pthread step 4 |
| Mach −27 `thread_self_trap` | only if `th_port=` is missing |
| Mach −24 `mach_port_construct` (MPO_REPLY_PORT) | pthread step 9 |
| BSD 202 `sysctl` | only if `main_stack=` is missing |
| BSD 366 `bsdthread_register` | pthread step 10 |
| BSD 372 `thread_selfid` | main-thread bootstrap (§5.4) |
| platform call x3 = 2 | TSD base (§5.4 / §9.1) |

---

## 8. Answers for `host-libraries.md` §7 and §8 (summary)

- **Init entry points and order:** `__libkernel_init` → `__libplatform_init`
  → `__pthread_init`, then (after libc, malloc, and dyld)
  `__pthread_late_init`. `__libkernel_init_late` is conditional and not
  expected in the simulator. `__libkernel_voucher_init` comes later, from
  libdispatch.
- **Structures:** `_libkernel_functions` v5 (128 bytes),
  `_libkernel_string_functions` v1 (136), `_libkernel_voucher_functions` v3
  (48), `_libpthread_functions` v2 (32), `ProgramVars` (40), and the
  bsdthread registration record (56, packed).
- **TSD:** a flat 768-slot array at `TPIDRRO_EL0` with no bias. `pthread_t`
  = base − 224. Reserved slots are in §3.3.
- **errno:** slot 1 → the thread's `err_no`, with a global fallback.
  `cerror` writes both copies and returns a 128-bit −1.

---

## 9. Implementation checklist for the first boot (stage 3a)

Goal: a single-threaded `hello` gets through `libSystem_initializer`.
Everything in §9 is **Ycode design** built on the facts above.

### 9.1 Main-thread bootstrap (choose one; A is recommended)

- **A. The VMM plays the host dyld.** Before entering `dyld_sim`, the VMM
  allocates a zeroed, EL0-RW, 16-byte-aligned block of ≥ 6368 bytes (one
  16 KiB page, outside the shared-region reservation, for example right
  after the Ycode host page). It writes:
  - +216 (`thread_id`) = the VMM's thread ID;
  - +224 (slot 0) = the block address;
  - +232 (slot 1) = block + 172.

  It then sets `TPIDRRO_EL0` = block + 224. This reproduces the state that
  §5.4 step 2 leaves on macOS. `__pthread_init` can then follow Apple's
  order exactly, and TSD, errno, and TLV reads are valid from the first
  instruction.
- **B. The libraries bootstrap themselves.** The kernel library keeps a
  static 6368-byte block. In `__libkernel_init`/`mach_init`, if
  `TPIDRRO_EL0` = 0, it does the three writes above and makes the platform
  call. This depends on `__libkernel_init` actually being called (Open
  question 1).

With either choice, Ycode's `__error()` and `cerror` should also treat a
zero base as "no TSD" and use the global `errno` (defense in depth). Apple
would fault there.

### 9.2 `libsystem_kernel`

- [ ] Data symbols with the §7.1 values. Keep `mach_task_self_` correct
      even if `__libkernel_init` is never called: either initialize it
      statically to a task port name fixed by the VMM, or have the VMM and
      the library agree on that value.
- [ ] `__libkernel_init`: accept `fns` with any version ≥ 1 and keep the
      pointer. Run `mach_init` once (§1.3). Do not require TSD.
- [ ] `__libkernel_platform_init`, `__libkernel_voucher_init`: store the
      pointer and return 0. `__libkernel_init_late` and
      `__libkernel_init_after_boot_tasks`: accept and ignore.
- [ ] `___error`, `_cerror`, `_cerror_nocancel` exactly as §4.
      `_pthread_exit_if_canceled` is called only through a non-NULL table
      member.
- [ ] System-call wrappers: x16 = number, `svc #0x80`, branch on carry to
      `cerror`. The indirect `___syscall` as §4.3.
- [ ] `_thread_set_tsd_base` (platform call x3 = 2), `___thread_selfid`
      (BSD 372), `___bsdthread_register` (BSD 366), `_mach_thread_self`
      (−27), `_mach_reply_port` (−26), `_task_self_trap` (−28),
      `_host_self_trap`/`_mach_host_self` (−29), `_mach_port_construct`
      (−24), `_mach_port_deallocate` (−18), `_mach_vm_map` (−15),
      `_mach_vm_allocate` (−10), `_vm_allocate`, `_vm_deallocate` (−12),
      `_mach_vm_protect` (−14).
- [ ] `_host_info` for `HOST_PRIORITY_INFO` (flavor 5): return
      kernel 80, system 80, server 64, user 31, depress 0, idle 0,
      minimum 0, maximum 79. **Ycode design:** answer this flavor inside
      the library without a Mach message for 3a.
- [ ] `_mig_get_reply_port` (slot 2, constructing a reply port lazily),
      `_mig_dealloc_reply_port`, `_mig_put_reply_port` (no-op).
- [ ] Unimplemented-stub layer (`host-libraries.md` §4) for the rest.

### 9.3 `libsystem_platform`

- [ ] `__libplatform_init` per §1.3: parse `security_config`, optionally
      erase `pfz`, initialize the simple-ASL context, and call
      `__libkernel_platform_init`.
- [ ] `_os_once`, `_os_alloc_once` per §7.1 and §7.2 (done = ~0).
- [ ] `os_unfair_lock_lock/unlock/trylock`, `_with_options`, `_no_tsd`
      variants, `os_unfair_lock_assert_*` (owner = slot 3; recursion
      aborts).
- [ ] `_platform_memmove`, `_platform_bzero`, `_platform_memset`,
      `_platform_strlen`, `_platform_memcmp`, `_platform_strcmp`, and the
      rest of the `string-memory` group (very heavily imported).
- [ ] `_simple_getenv`, `_simple_dprintf`, `_simple_vdprintf`, the
      `_simple_s*` string builders, and `_simple_asl_log` (it may just
      write to fd 2).

### 9.4 `libsystem_pthread`

- [ ] `__pthread_init` per §1.3. With bootstrap A, adopt `TPIDRRO_EL0` −
      224. Fill slots 0, 1, 2, 3, 4, 7, 8, 9, the stack fields, the munge
      token, the list, and the signature. Register with the kernel. **A
      zero `ptr_munge` must not be fatal in Ycode**, though the VMM
      always supplies one.
- [ ] `__pthread_late_init`: no-op.
- [ ] `pthread_self`, `pthread_getspecific` (no range check),
      `pthread_setspecific`, `_pthread_setspecific_static` (key < 256),
      `pthread_key_init_np` (10 ≤ key < 256), and `pthread_key_create`
      (from 256, below 768).
- [ ] `qos_class_self`, `qos_class_main`, `pthread_main_np`,
      `pthread_mach_thread_np`, `pthread_threadid_np`,
      `pthread_get_stackaddr_np`/`_stacksize_np`,
      `pthread_current_stack_contains_np`, `_pthread_clear_qos_tsd`, and
      `pthread_atfork`.
- [ ] Mutex, cond, once, and rwlock functions that accept the §5.3 static
      initializers. Single-threaded contention is never expected, so the
      first version may abort if a lock is already held.
- [ ] `thread_start`, `start_wqthread` (registered, not yet run), and
      `____chkstk_darwin` (§5.1).
- [ ] `_pthread_workqueue_supported` returns the stored mask (non-zero
      after registration).

### 9.5 VMM

- [ ] Bootstrap A (§9.1), `TPIDR_EL0` = vCPU number.
- [ ] `apple[]` with `ptr_munge` (non-zero), `main_stack`, `th_port` (a
      real name with bit 0 set and one send right), `security_config=0x0`,
      `stack_guard`, `malloc_entropy`, and `pfz` (`darwin-process-start.md`
      §5).
- [ ] The §7.5 traps, with Mach port names that keep bit 0 set.
- [ ] Commpage `KDEBUG_ENABLE` = 0, and offsets 0x025/0x037 = 14.

---

## Open questions

1. **Who calls the host init functions in the iOS 27.1 runtime?** The
   surface tables (`host-library-surface.md`, level 4) list
   `___libkernel_init`, `___libplatform_init`, `___pthread_init`,
   `___pthread_late_init`, `___libkernel_init_late`, `_mach_init`, and
   `___libkernel_platform_init` with **0 importers**. Libsystem's
   `requiredlibs` shows that the simulator's `libSystem` links
   `libsystem_sim_{kernel,platform,pthread}` in place of the plain
   libraries. libplatform's source shows that a simulator build of
   `__libplatform_init` exists ("we just provide `_simple` for dyld"). So
   the simulator's libSystem probably calls `libsystem_sim_*` entry points,
   and these reach the host functions by a path that the import scan skips
   (an ordinal of 0/0xFE/0xFF, or `dlsym`). How to find out:
   - (a) a level-4 check of the undefined and exported `*init*` symbols of
     `libSystem.B`, `libsystem_sim_*`, and `libsystem_sim_*_host` (all
     ordinals);
   - (b) the 3a run itself. While these functions are unimplemented stubs,
     the VMM logs `unimplemented libfunc <name>` for each one that is
     called.

   §9.1 A and the static values in §7.1 make Ycode work either way.
2. **Version skew.** The newest tags read are Libsystem-1356,
   xnu-12377.121.6, libpthread-539.100.4, and libplatform-375.120.2 (the
   macOS 26 era). The iOS 27.1 runtime may pass newer struct versions (for
   example `_libkernel_functions` v6). The append-only rule in §2 covers
   this: accept version ≥ the known one.
3. **`__libkernel_init_late` in the simulator.** It depends on
   `POSIX_SPAWN_FILTERING_ENABLED`, a build setting that is not visible in
   the source. Export it in tolerant form.
4. **`bootstrap_port`.** Not set by the three libraries. It is probably set
   by libxpc or liblaunch through `task_get_special_port(TASK_BOOTSTRAP_PORT)`.
   That needs a VMM answer before `_libxpc_initializer` (step 10) works.
5. **Milestone attribution.** Stage-3 criterion 2 expects a trap whose ELR
   lies in a *shared-cache* `libsystem_*` or `libSystem.B` image. With
   Ycode's libraries, the initializer's first traps come from Ycode's own
   `libsystem_kernel`, which is not in the cache. The criterion should also
   accept an ELR in the three Ycode libraries, or use the LR or the stub
   trap's caller. This is for the orchestrator to decide.
6. **Inline TSD readers in simulator images.** Confirmed: libdyld's TLV
   getter. Simulator builds of libdispatch and libobjc use the API. Other
   images (Swift runtime, libmalloc) may read slots inline through the
   ungated `os/tsd.h` helpers. The flat-array rule (§3.1) covers all of
   them. Only the slot meanings (§3.3) matter.
7. **The host_info RPC.** If Ycode later implements `host_info` as a real
   MIG message, the VMM needs a host-port server (subsystem `mach_host`,
   routine 200). For 3a the library answers it locally (§9.2).

## Evidence

All level 1 (Apple open source, `github.com/apple-oss-distributions`, read
with `gh api` on 2026-10-11; newest tag of each repository):

| Repo @ tag | Files | Used for |
|---|---|---|
| `Libsystem` @ `Libsystem-1356` | `init.c`, `alloc_once_private.h`, `requiredlibs` | §1.1–1.2 call order and arguments, the struct versions passed, `os_alloc_once` keys, simulator link list |
| `xnu` @ `xnu-12377.121.6` | `libsyscall/wrappers/_libkernel_init.{h,c}`, `libsyscall/wrappers/_libc_funcptr.c`, `libsyscall/mach/mach_init.c`, `libsyscall/mach/mig_reply_port.c`, `libsyscall/custom/{errno.c,custom.s,SYS.h,__syscall.s,__getpid.s}`, `libsyscall/os/{tsd.h,alloc_once.c}`, `libsyscall/wrappers/init_cpu_capabilities.c`, `bsd/pthread/{pthread_shims.c,workqueue_syscalls.h,bsdthread_private.h,priority_private.h}`, `bsd/kern/sys_ulock.c`, `bsd/sys/ulock.h`, `osfmk/kern/{host.c,sched.h}`, `osfmk/mach/ndr.h`, `osfmk/mach/arm/ndr_def.h` | §1.3 kernel steps, §2.1–2.4, §3.1, §3.3 slots 0–9 and 123, §4, §6.1 argument names, ulock flags, host priority values, `NDR_record` |
| `libpthread` @ `libpthread-539.100.4` | `src/{pthread.c,pthread_tsd.c,pthread_asm.s,types_internal.h,inline_internal.h,offsets_internal.h,internal.h,qos.c}`, `private/pthread/{tsd_private.h,private.h}`, `include/pthread/pthread.h`, `include/sys/_pthread/_pthread_types.h`, `kern/{kern_support.c,kern_internal.h}` | §1.3 pthread steps, §2.5, §3.2–3.4, §5, §6 |
| `libplatform` @ `libplatform-375.120.2` | `src/init.c`, `src/atomics/init.c`, `src/os/{alloc_once.c,lock.c,security_config.c}`, `src/simple/{asl.c,getenv.c}`, `private/os/{alloc_once_impl.h,once_private.h}`, `xcodeconfig/libplatform.xcconfig` | §1.3 platform steps, §2.2, §7.1–7.4, simulator build variant |
| `Libc` @ `Libc-1752.120.2` | `sys/_libc_init.c`, `darwin/_libc_init.h` | §1.2 step 4, §2.8 |
| `libdispatch` @ `libdispatch-1542.100.32` | `src/shims/tsd.h`, `os/voucher_private.h`, `src/queue.c` (`libdispatch_init`) | §3.3 libdispatch slots, simulator TSD path, which pthread SPI `libdispatch_init` calls |
| `dyld` @ `dyld-1378` | `libdyld/threadLocalHelpers.s` | §3.4 inline TLV read of `TPIDRRO_EL0` |

- Struct offsets were computed from the field types in the headers listed.
  The `pthread_s` and registration-record offsets were cross-checked by
  compiling Ycode's own declarations with the same field types (scratch
  only). They match libpthread's assertions (tsd at 224, stackaddr −48,
  stackbottom −40, thread_id −8).
- Level 4 (from existing specs): importer counts and data-symbol sizes
  (`host-library-surface.md`).
- Sources were kept only in the session scratchpad. No Apple binary was
  opened, disassembled, or decompiled.
