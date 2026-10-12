# Spec: API surface of the three host libraries

Status: **measured (2026-10-11)**. This spec lists what Ycode's clean-room
`libsystem_kernel`, `libsystem_platform`, and `libsystem_pthread` must
export so that the iOS 27.1 simulator runtime (24A94401) can bind to them.
It is the input for stage 3a-ii (see `stage3-contract.md` §12). The
machine-readable tables are:

- `data/host-lib-surface-kernel.json`
- `data/host-lib-surface-platform.json`
- `data/host-lib-surface-pthread.json`

This spec gives only names, kinds, counts, and link-level facts. It does not
describe how any function behaves. Behavior comes from public documentation,
Apple open source (xnu `libsyscall`, `libplatform`, `libpthread`), and the
trap tables in `data/bsd-syscalls.json` and `data/mach-traps.json`.

## 1. Method

1. The six images were read from the simulator shared cache
   (`dyld_sim_shared_cache_arm64` and `.01`) with a metadata-only parser
   (formats from `specs/formats/macho-and-dyld-cache.md`). The parser read
   the load commands, the export tries (`LC_DYLD_EXPORTS_TRIE`), the symbol
   tables (`LC_SYMTAB`, `LC_DYSYMTAB`), and the indirect symbol tables.
2. The importers are all **1,819 cache images** and all **3,828 arm64
   Mach-O files** found on disk under RuntimeRoot (cache files excluded).
   The parser took every external undefined symbol and its two-level
   library ordinal (`n_desc` high byte, `N_WEAK_REF` = weak). For on-disk
   files without a symbol table, it used the chained-fixups import table.
   Ordinals 0, `0xFE` and `0xFF` (self, flat lookup, main executable) were
   skipped.
3. Each import was resolved as dyld resolves it: look up the name in the
   ordinal library's export trie. A re-export entry continues in the named
   dependency under the entry's imported name. A missing name continues
   through that library's `LC_REEXPORT_DYLIB` dependencies, in order. An
   import is part of the surface when the resolution ends in one of the
   three link stubs `/usr/lib/system/libsystem_{kernel,platform,pthread}.dylib`.
   The **final** name is recorded. For example, `_memcpy` resolves to
   `__platform_memmove` (see §7).
4. Weak imports that the sim-host shims make (§3) and that the link stubs do
   not export are attributed to the library their ordinal names.
5. Kind (`function` / `data`) and data sizes come from the **host Mac's own
   arm64 libraries** (macOS 27.2, 26B5091g), read with `nm -m -arch arm64`
   and `dyld_info -arch arm64 -segments -exports`. An export in
   `__TEXT,__text` is a function. Any other section means data. Every
   imported symbol exists on the host Mac. The importers' indirect symbol
   tables agree: data symbols are reached only through GOT slots, never
   through stubs.
6. Data sizes are **upper bounds**: the distance to the next symbol (local
   or external) in the same section, or to the section end. The symbol
   tables do not record sizes.

## 2. The six images (question 1)

All six are arm64 dylibs (filetype 6) in the simulator cache, with
`MH_DYLIB_IN_CACHE` set.

| Image | Install name | current / compat | LC_BUILD_VERSION | flags |
|---|---|---|---|---|
| sim kernel host | `/usr/lib/system/libsystem_sim_kernel_host.dylib` | 271.0.0 / 1.0.0 | platform 7 (iOS Simulator), minos 27.1, sdk 27.1 | `0x82000085` |
| sim platform host | `/usr/lib/system/libsystem_sim_platform_host.dylib` | 271.0.0 / 1.0.0 | 7, 27.1, 27.1 | `0x82000085` |
| sim pthread host | `/usr/lib/system/libsystem_sim_pthread_host.dylib` | 271.0.0 / 1.0.0 | 7, 27.1, 27.1 | `0x82000085` |
| kernel link stub | `/usr/lib/system/libsystem_kernel.dylib` | 0.0.0 / 0.0.0 | **7 (iOS Simulator), minos 15.0, sdk 15.0** | `0x80100085` |
| platform link stub | `/usr/lib/system/libsystem_platform.dylib` | 0.0.0 / 0.0.0 | 7, 15.0, 15.0 | `0x80100085` |
| pthread link stub | `/usr/lib/system/libsystem_pthread.dylib` | 0.0.0 / 0.0.0 | 7, 15.0, 15.0 | `0x80100085` |

The flags decode as follows. `0x82000085` = NOUNDEFS | DYLDLINK | TWOLEVEL |
APP_EXTENSION_SAFE | DYLIB_IN_CACHE. `0x80100085` = NOUNDEFS | DYLDLINK |
TWOLEVEL | NO_REEXPORTED_DYLIBS | DYLIB_IN_CACHE.

**Correction to `stage3-contract.md` §12:** the link stubs are not
macOS-platform images. They are tagged iOS Simulator with minos 15.0.

### Dependencies

- Each sim-host image has three dylib commands, in ordinal order:
  - 1: `LOAD_DYLIB /usr/lib/system/libdyld.dylib` (0.0.0 / 0.0.0)
  - 2: `LOAD_DYLIB /usr/lib/system/libcompiler_rt.dylib` (103.4.0 / 1.0.0)
  - 3: `REEXPORT_DYLIB` of its link-stub path. The recorded versions are
    kernel 10002.1.13 / 1.0.0, platform 306.0.1 / 1.0.0, and pthread
    519.0.0 / 1.0.0.
- So Ycode's replacements must carry compatibility version **≥ 1.0.0**.
  The host Mac's libraries carry 1.0.0. Their current versions are kernel
  13432.40.162, platform 402.40.3, and pthread 553.40.2.
- Each link stub has one `LOAD_DYLIB /usr/lib/libSystem.B.dylib` (1.0.0)
  and no undefined symbols.

### Segments and export tries

| Image | `__TEXT,__text` size | `__DATA,__data` size | Exports | Export kinds |
|---|---|---|---|---|
| sim kernel host | 0 | 0x58 (11 × 8) | 11 | all regular |
| sim platform host | 0 | 0xF0 (30 × 8) | 30 | all regular |
| sim pthread host | 0 | 0x10 (2 × 8) | 2 | all regular |
| kernel link stub | 0x1784 (1505 × 4) | none | 1,505 | all regular |
| platform link stub | 0x28C (163 × 4) | none | 163 | all regular |
| pthread link stub | 0x33C (207 × 4) | none | 207 | all regular |

- No export in any of the six images is weak, re-export, stub-and-resolver,
  absolute, or thread-local. The stubs also have an empty
  `__TEXT,__lldb_no_nlist` section.
- In the link stubs, each export is a separate 4-byte slot in `__text`.
  The stubs are placeholders for linking, not implementations.
- For reference, the host Mac's arm64 libraries export 1,628 / 202 / 223
  symbols. Of these, 133 / 39 / 16 are missing from the stubs. Ten kernel
  stub exports are missing from the host Mac: the `mach_vm_reclaim_*` and
  `mach_vm_deferred_reclamation_*` group, and `pkt_type_assert_fail` /
  `pkt_subtype_assert_fail`.
- On the host Mac, three platform exports are dynamic-resolver
  (stub-and-resolver) exports: `__platform_strcmp`, `__platform_strncmp`,
  and `_OSAtomicDequeue`. Ycode may export them as regular functions.

## 3. Sim-host interposition slots

Each sim-host image exports `___interposition_sim_system_<name>` symbols.
Each one is an **8-byte pointer variable** in that image's `__DATA,__data`:
the export offsets are 8 bytes apart and fill the section exactly. Each
image also has a **weak** undefined import of `_<name>` from its re-exported
host library (ordinal 3). The clients are `libsystem_sim_kernel.dylib`,
`libsystem_sim_platform.dylib`, and `libsystem_sim_pthread.dylib`, one per
library. The kernel and pthread clients import every slot of their sim-host
image. The platform client imports only the 10 non-`_simple` slots; nothing
in the runtime imports the 20 `_simple_*` slots.

| Library | `<name>` set (weak imports from the host library) |
|---|---|
| kernel (11) | `csops`, `csops_audittoken`, `dup3`, `fchflagsat`, `fstatfs_ext`, `statfs_ext`, `pipe2`, `posix_spawn_file_actions_addchdir`, `posix_spawn_file_actions_addfchdir`, `posix_spawnattr_set_use_sanitizers_np`, `posix_spawnattr_set_use_sec_transition_shims_np` |
| platform (30) | `os_unfair_lock_lock_with_flags`; `os_sync_wait_on_address` and its `_with_timeout` / `_with_deadline` variants; `os_sync_wake_by_address_any` / `_all`; `os_security_config_get`, `_for_task`, `_for_proc`; `os_script_config_storage` (**data** on the host: `__DATA,__script_config`, 16 KiB); and 20 `_simple_*` routines (`_simple_dprintf`, `_simple_vdprintf`, `_simple_put`, `_simple_putline`, `_simple_salloc`, `_simple_sprintf`, `_simple_vsprintf`, `_simple_esprintf`, `_simple_vesprintf`, `_simple_sappend`, `_simple_esappend`, `_simple_sresize`, `_simple_string`, `_simple_sfree`, `_simple_getenv`, `_simple_asl_msg_new`, `_simple_asl_msg_set`, `_simple_asl_send`, `_simple_asl_log`, `_simple_asl_log_prog`) |
| pthread (2) | `pthread_attr_setworkinterval_np`, `_pthread_workqueue_allow_send_signals` |

Twenty of these 43 names are **not exported by the link stubs**: the 9
kernel names other than `csops` and `csops_audittoken`, the 10 non-`_simple`
platform names, and both pthread names. Because the imports are weak, a
missing symbol leaves the slot NULL. These symbols are optional, but each
one that Ycode exports enables the matching feature in the simulator's own
libraries.

## 4. Surface sizes and categories (questions 2 and 3)

"Surface" means the symbols that at least one image imports. The JSON
tables also contain every link-stub export that nothing imports, with
`importers: 0`.

| Library | Surface | function | data | Stub exports not imported | Importing images (of them on disk) |
|---|---|---|---|---|---|
| kernel | **585** | 574 | 11 | 929 | 1,492 (715) |
| platform | **89** | 88 | 1 | 84 | 3,317 (1,863) |
| pthread | **121** | 120 | 1 | 88 | 627 (233) |

In total, 3,529 images import from at least one of the three libraries.
Weak-only symbols (every import is weak) are the §3 names plus
`_mig_strncpy_zerofill` (kernel, 10 importers).

Categories come from names only. In each cell below, the first number is
the surface count and the number in parentheses counts all symbols in the
JSON table.

**kernel**

| Category | Meaning | Count |
|---|---|---|
| `bsd-syscall` | Name matches a BSD syscall in `bsd-syscalls.json` (including `$NOCANCEL` / `$DARWIN_EXTSN` variants) | 235 (364) |
| `bsd-syscall-private` | `__name` / `___name` private wrapper of a BSD syscall (for example `___ulock_wait`, `___open_nocancel`, `___sysctl`, `___fork`, `__exit`) | 41 (200) |
| `mach-trap` | Name matches a Mach trap or user stub in `mach-traps.json` (`mach_wait_until`, `mk_timer_*`, `thread_switch`, `task_for_pid`, `pid_for_task`, `task_name_for_pid`, `thread_get_special_reply_port`, `mach_generate_activity_id`) | 12 (60) |
| `mach-routine` | Mach interface routine by prefix (`mach_port_*`, `mach_vm_*`, `vm_*`, `task_*`, `thread_*`, `host_*`, `semaphore_*`, `mig_*`, `mach_msg*`, `mach_voucher_*`, `mach_eventlink_*`, time functions). Names alone cannot separate MIG RPCs from trap-backed wrappers | 153 (415) |
| `posix-spawn` | `posix_spawn*` | 32 (73) |
| `libproc` | `proc_*` | 25 (59) |
| `work-interval` | `work_interval_*` | 17 (25) |
| `os-channel` | `os_channel_*` and similar skywalk names | 14 (140) |
| `kpersona`, `fs-snapshot` | | 6 (9), 4 (7) |
| `errno` | `___error` (surface); `_cerror` and `_cerror_nocancel` exist only in the stub | 1 (3) |
| `data` | §6 | 11 (29) |
| `other` | For example `abort_with_reason`, `terminate_with_reason`, `clonefile`, `renamex_np`, `openat_authenticated_np`, `futimens`, `utimensat`, `sem_init`, `sem_destroy`, `csr_check`, `kdebug_is_enabled`, `__get_cpu_capabilities`, `___commpage_gettimeofday`, `___libkernel_voucher_init`, `___sandbox_ms`, `mach_ports_lookup`, `mach_ports_register`, `mach_boottime_usec`, `os_proc_available_memory`, `pthread_{get,set}ugid_np`, `setiopolicy_np`, `getiopolicy_np`, `kext_request`, plus the §3 names | 34 (130) |

The kernel surface includes 17 `$NOCANCEL` symbols, 2 `$DARWIN_EXTSN`
symbols (`select`, `pselect`), and 8 more `___*_nocancel` private wrappers.

**platform**

| Category | Count |
|---|---|
| `string-memory` (`_platform_mem*`, `_platform_str*`, `_platform_bzero`) | 21 (21) |
| `simple-printf-asl` (`_simple_*`, weak, §3) | 20 (21) |
| `os-lock` (`os_unfair_lock_*`, `os_unfair_recursive_lock_*`, `_os_nospin_lock_*`) | 15 (21) |
| `atomics-spinlock` (`OSAtomic*`, `OSMemoryBarrier`, `OSSpinLock*`, `spin_lock*`) | 11 (53) |
| `setjmp-longjmp` (`setjmp`, `longjmp`, `_setjmp`, `_longjmp`, `sigsetjmp`, `siglongjmp`) | 6 (6) |
| `os-sync` (`os_sync_*`, weak) | 5 (9) |
| `signal-bitops` (`fls`, `flsl`, `flsll`) | 3 (6) |
| `os-misc` (`os_security_config_*`) | 3 (16) |
| `os-once` (`_os_once`, `_os_alloc_once`) | 2 (3) |
| `cache-control` (`sys_icache_invalidate`, `sys_dcache_flush`) | 2 (3) |
| `ucontext` (`getcontext`, `setcontext`, `makecontext`, `swapcontext`) | 0 (4) |
| `data` | 1 (7) |

**pthread**

| Category | Count |
|---|---|
| `pthread-api` (public `pthread_*`, including `_np` routines) | 90 (131) |
| `pthread-spi` (`_pthread_*`) | 15 (47) |
| `tsd` (`pthread_key_*`, `pthread_{get,set}specific`, `pthread_key_init_np`, `_pthread_setspecific_static`) | 6 (9) |
| `sched-signal` (`sched_yield`, `sched_get_priority_{min,max}`, `sigwait`) | 4 (5) |
| `qos` (`qos_class_self`, `qos_class_main`) | 2 (2) |
| `spawn-qos` (`posix_spawnattr_set_qos_class_np`) | 1 (2) |
| `pthread-private` (`__pthread_workqueue_setkill`) | 1 (3) |
| `stack-probe` (`___chkstk_darwin`) | 1 (1) |
| `thread-entry` (`thread_start`, `start_wqthread`, `thread_chkstk_darwin`) | 0 (3) |
| `data` | 1 (5) |

## 5. Most-imported symbols (count of importing images)

- **kernel:** `___error` 724, `getpid` 507, `close` 485,
  `mach_absolute_time` 396, `open` 391, `mach_timebase_info` 346,
  `mach_task_self_` 301 (data), `fstat` 265, `stat` 265, `mmap` 249,
  `munmap` 245, `write` 198, `read` 189, `fcntl` 188, `unlink` 183,
  `getuid` 182, `kdebug_trace` 164, `geteuid` 148, `mach_continuous_time`
  145, `mach_port_deallocate` 137.
- **platform:** `_platform_memmove` 2806, `_platform_bzero` 2171,
  `os_unfair_lock_unlock` 1399, `os_unfair_lock_lock` 1367,
  `_platform_strlen` 1066, `_platform_memcmp` 738, `_platform_strcmp` 598,
  `_platform_memset` 533, `_platform_strcpy` 337, `_platform_strncmp` 312.
- **pthread:** `pthread_mutex_lock` 295, `pthread_mutex_unlock` 294,
  `pthread_mutex_init` 195, `pthread_self` 191, `qos_class_self` 175,
  `pthread_mutex_destroy` 165, `pthread_setspecific` 140,
  `pthread_getspecific` 132, `pthread_key_create` 120, `pthread_create` 104.

## 6. Data symbols (question 4)

These must be **real variables** in Ycode's libraries, not functions.
Sections and size bounds come from the host Mac's arm64 libraries.

| Symbol | Lib | Importers | Host section | Size ≤ (bytes) |
|---|---|---|---|---|
| `_mach_task_self_` | kernel | 301 | `__DATA_DIRTY,__common` | 8 (holds a 4-byte port name) |
| `_vm_page_size` | kernel | 121 | `__DATA_DIRTY,__common` | 12 (gap before next symbol; `vm_size_t`, 8) |
| `_bootstrap_port` | kernel | 65 | `__DATA_DIRTY,__common` | 4 |
| `_NDR_record` | kernel | 56 | `__DATA,__data` | 8 (initialized constant record) |
| `_vm_page_mask` | kernel | 27 | `__DATA_DIRTY,__common` | 8 |
| `__os_alloc_once_table` | kernel | 9 | `__DATA_DIRTY,__common` | 1600 |
| `_vm_kernel_page_size` | kernel | 8 | `__DATA_DIRTY,__common` | 8 |
| `_vm_page_shift` | kernel | 5 | `__DATA_DIRTY,__common` | 4 |
| `_vm_kernel_page_mask` | kernel | 4 | `__DATA_DIRTY,__common` | 12 (gap) |
| `___syscall_logger` | kernel | 3 | `__DATA,__common` | 8 (pointer) |
| `_vm_kernel_page_shift` | kernel | 1 | `__DATA_DIRTY,__common` | 8 |
| `_os_script_config_storage` | platform | 1 (weak) | `__DATA,__script_config` | 16384 |
| `___unix_conforming` | pthread | 1 | `__TEXT,__const` (read-only) | ≤ 32 |

Data symbols in the stubs or on the host that nothing imports:

- kernel: `____kernelVersionNumber`, `____kernelVersionString`,
  `__cpu_capabilities`, `__cpu_has_altivec`, `__current_pid`,
  `__mach_errors` (≤ 2560), `__os_xbs_chrooted`, `_errno`,
  `_mach_error_full_diag`, `_port_obj_table`, `_port_obj_table_size`,
  `_system_version_compat_mode`, `_vprintf_stderr_func`,
  `_internal_catch_exc_subsystem`, and `_{denap,important,non,normal}_boost_assertion_token`.
- platform: `__os_lock_type_{spin,eliding,transactional,handoff,nospin,unfair}`,
  each 32 bytes in `__DATA_CONST,__const`. Three of the names share one
  address.
- pthread: `___is_threaded`, `__pthread_tsd_shared_cache_first`,
  `__pthread_tsd_shared_cache_last`, and `_pthread_layout_offsets`.

The host libraries import several of these from each other, for example
`_mach_task_self_`, `_vm_page_size`, `__os_alloc_once_table`,
`__os_xbs_chrooted`, and `___syscall_logger` (see §8).

## 7. Re-export aliases that end in the host libraries

The simulator's `libsystem_c` export trie re-exports standard names under
the platform library's names, through `libsystem_sim_platform` →
`libsystem_sim_platform_host` → `libsystem_platform`. So Ycode's platform
library is reached under the `_platform_*` name:

| Imported name | Bound name |
|---|---|
| `memcpy`, `memmove` | `_platform_memmove` |
| `bcmp`, `memcmp` | `_platform_memcmp` |
| `index`, `strchr` | `_platform_strchr` |
| `bzero`, `memccpy`, `memchr`, `memset`, `memset_pattern{4,8,16}`, `strcmp`, `strcpy`, `strlcat`, `strlcpy`, `strlen`, `strncmp`, `strncpy`, `strnlen`, `strstr` | `_platform_<same name>` |

Similarly, `libSystem.B` re-exports `___chkstk_darwin` as pthread's
`____chkstk_darwin`.

## 8. Notable SPI

- **libdispatch → pthread** (`_pthread_*` SPI): `_pthread_workqueue_supported`,
  `_pthread_workqueue_addthreads`, `_pthread_workqueue_add_cooperativethreads`,
  `_pthread_workqueue_set_event_manager_priority`,
  `_pthread_workqueue_override_start_direct` (and `_check_owner`),
  `_pthread_workqueue_override_reset`, `_pthread_workloop_create`,
  `_pthread_workloop_destroy`, `_pthread_qos_class_encode` / `_decode`,
  `_pthread_qos_override_start_direct` / `_end_direct`,
  `_pthread_set_properties_self`, `_pthread_setspecific_static`,
  `pthread_key_init_np`, and `qos_class_main`.
- **libsystem_c → pthread:** `__pthread_workqueue_setkill`.
- **libdispatch → kernel** (90 symbols), notably: `___ulock_wait`,
  `___ulock_wake`, `_kevent_qos`, `_kevent_id`, `_mach_msg2_internal`,
  `_mach_msg_priority_encode`, the `mach_eventlink_*` routines,
  `mig_get_special_reply_port`, `thread_get_special_reply_port`,
  `thread_destruct_special_reply_port`, `___libkernel_voucher_init`,
  `guarded_open_np`, `guarded_close_np`, the whole `work_interval_*`
  family, and the `mach_voucher_*` routines.
- **libdyld → kernel/platform/pthread:** 11, 13, and 6 symbols. The kernel
  ones are `___error`, `close`, `fstat`, `geteuid`, `mach_task_self_`,
  `mmap`, `munmap`, `open`, `vm_allocate`, `vm_deallocate`, and
  `vm_page_size`.
- **Host-internal dependencies.** These are not part of the simulator's
  surface, but Ycode's three libraries must satisfy each other in the same
  way:
  - The host `libsystem_platform` imports from kernel: the
    `___ulock_wait`/`wait2`/`wake` group, `___sigaction`, `___sigaltstack`,
    `___sigreturn`, `___libkernel_platform_init`, `___sendto`,
    `__os_alloc_once_table`, `__os_xbs_chrooted`, the `semaphore_*`
    routines, `mach_vm_map`, and others. It also weak-imports
    `_dyld_call_with_writable_tpro_memory` from libdyld.
  - The host `libsystem_pthread` imports from kernel: `___bsdthread_*`,
    `___workq_kernreturn`, `___workq_open`, `___kqueue_workloop_ctl`, the
    `___psynch_*` group, `___ulock_*`, `___pthread_kill`/`markcancel`/
    `canceled`/`sigmask`/`chdir`/`fchdir`, `___thread_selfid`,
    `__thread_set_tsd_base`, and `___disable_threadsignal`. It imports
    from platform: `_os_once`, `_os_alloc_once`, `_os_semaphore_*`, the
    `os_unfair_lock_*` group, `_platform_*`, and `_simple_*`. From libdyld
    it imports `_dyld_register_for_bulk_image_loads` and (weak)
    `_dyld_thread_local_free`. From libmacho (an upward link) it imports
    `getsectiondata`.

## 9. JSON schema

Each table is an array sorted by `importers` (descending), then by name.
Every row has these fields:

- `name`: the mangled C symbol, with its leading underscore.
- `kind`: `function`, `data`, or `unknown`.
- `importers`: the number of distinct images.
- `weakOnly`: true when every import is weak.
- `category`: see §4.
- `examples`: up to 3 importer install paths. On-disk files are given
  relative to RuntimeRoot.
- `inLinkStub`: whether the simulator cache's link stub exports the name.
- `inHostMac`: whether the host Mac's arm64 library exports the name.

Data rows also have `section` (on the host) and `sizeUpperBound`. The three
dynamic-resolver exports (§2) have `hostExportFlags`.

## 10. Open questions

1. **How `dyld_sim` binds simulator-cache clients to the host libraries.**
   The cache was built against the link stubs: their slots are placeholders
   and their export tries have no resolvers. So `dyld_sim` must redirect
   every cached use to the real libraries at run time. The likely
   mechanism is the cache patch table (`dyld_cache_patch_info` in Apple's
   open-source `dyld_cache_format.h`), which is used when a cached dylib
   is overridden. If so, Ycode's libraries must export every patched name,
   and the patch-table format needs its own spec. This has not been
   verified. It is a level-1 research item.
2. **Where `dyld_sim` looks for the host libraries.** The stage-3a abort
   (`Library not loaded: /usr/lib/system/libsystem_platform.dylib`)
   suggests that it looks outside `DYLD_ROOT_PATH` and outside the
   simulator cache. Which path and which loader checks it applies
   (platform, minos, install name, compatibility version) are not yet
   known.
3. **Which platform tag Ycode's libraries need.** The host Mac's libraries
   are `zippered(macOS/Catalyst)`. The stubs are iOS Simulator 15.0.
4. **Real sizes of the data variables.** §6 gives upper bounds only.
   `_mach_task_self_`, `_bootstrap_port`, and `_vm_page_shift` are 4-byte
   variables in Apple's public headers. `_vm_page_size` and
   `_vm_page_mask` are pointer-sized.
5. **Exports that nothing imports.** The stubs export 929 kernel, 84
   platform, and 88 pthread symbols that no simulator image imports. They
   are not needed for binding, but `dlsym` callers could reach them. A
   `dlsym` survey is outside this metadata pass.
6. **Thread entry points.** `thread_start` and `start_wqthread` have no
   importers. The pthread library registers them with the kernel itself,
   so Ycode's pthread and kernel personality must agree on them. The
   stage-3b spec should cover this.

## Evidence

- Level 4 (binary metadata) for everything above:
  - Load commands, export tries, symbol tables, indirect symbol tables,
    and chained-fixups import tables of the simulator cache and on-disk
    RuntimeRoot binaries. These were read with a throwaway metadata parser
    in the dirty-room scratchpad and cross-checked against
    `ycode dsc --image`.
  - The host Mac's arm64 `libsystem_{kernel,platform,pthread}` (macOS 27.2,
    26B5091g), read with `nm -m -arch arm64`,
    `dyld_info -arch arm64 -segments -exports`, and `otool -L`.
- No instruction was disassembled or decompiled. The statement that each
  stub export is a 4-byte slot comes from section size divided by export
  count.
- Level 1: Mach-O and dyld-cache layouts (`specs/formats/macho-and-dyld-cache.md`),
  the export-trie and nlist formats (Apple's open-source `dyld` and `xnu`
  headers), and the syscall and trap tables (`data/*.json`).
- The categories are Ycode's own name-based classification.
