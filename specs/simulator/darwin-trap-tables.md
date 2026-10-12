# Spec: Darwin arm64 trap tables (BSD, Mach, platform)

Status: **reference data**. The machine-readable tables are:

- `specs/simulator/data/bsd-syscalls.json`: 558 BSD system calls
  (x16 = 0…557);
- `specs/simulator/data/mach-traps.json`: 128 Mach trap slots
  (x16 = 0…−127).

The dispatch and return rules are in `specs/simulator/darwin-process-start.md`
§4. They correct one statement in `darwin-arm64-abi.md`: that file counts
669 BSD entries. 669 is the number of *lines* in `syscalls.master`, because
conditional slots appear twice. The table has **558 slots**.

## 1. Source and method

- Source: Apple's open-source `xnu`, tag **`xnu-12377.121.6`**, commit
  `ac9718fb1af618d5ce8678d0dc6e8a58f252216f`. It was the newest tag on
  2026-10-11. The repository's default branch is still at `xnu-12377.1.9`.
- The files were fetched with the GitHub API into a scratch directory
  outside the repository. A small Python script (run with `python3 -I`,
  kept outside the repository) parsed them and wrote only facts: numbers,
  names, argument C types, and return types:
  - `bsd/kern/syscalls.master`: one entry per line, giving the number, the
    audit event, the files column, `{ prototype }`, and an optional
    `{ comment }`;
  - `osfmk/kern/syscall_sw.c`: the `mach_trap_table` rows, each giving the
    handler, the argument count, the 32-bit word count, and the munger;
  - `osfmk/mach/mach_traps.h`, kernel section: the per-trap argument
    structures (`PAD_ARG_(type, name)` fields) and the handler return types;
  - `osfmk/mach/syscall_sw.h`: the user stub names (`kernel_trap(name,
    number, words)`).
- Conditionals: in `syscalls.master`, `#if X / #else / #endif` give two
  definitions of the same slot. The JSON keeps the variant that the
  **macOS arm64 release kernel** builds as the main record, and the other
  variant under `alternate`. The macOS arm64 option set comes from
  `config/MASTER` and `config/MASTER.arm64.MacOSX`:
  - **enabled:** SOCKETS, NFSSERVER, SYSV_SEM/MSG/SHM, CONFIG_EXT_RESOLVER,
    PSYNCH, SENDFILE, CONFIG_MACF, CONFIG_MEMORYSTATUS,
    CONFIG_PROC_UUID_POLICY, CONFIG_COALITIONS, NECP, CONFIG_CSR,
    CONFIG_CODE_DECRYPTION, NETWORKING, CONFIG_TELEMETRY, PGO,
    CONFIG_PERSONAS, SKYWALK;
  - **disabled:** CONFIG_EMBEDDED. CONFIG_VFORK is not defined by any
    config file that was found.

## 2. JSON shape

`bsd-syscalls.json` is an array indexed by number. Each object has these
keys:

| Key | Meaning |
|---|---|
| `number` | x16 value |
| `name` | Kernel entry name (`nosys` or `enosys` for empty slots) |
| `args` | Array of C type strings, as written in `syscalls.master` |
| `arg_names` | The matching parameter names |
| `returns` | C return type |
| `status` | `implemented`, `nosys` (an empty slot with no history), `old` (the comment says "old …"), or `reserved` (slot 0 "indirect syscall", slot 63 "used internally and reserved", slot 213 "Reserved for AppleTalk") |
| `kernel_handler` | `function`, `nosys` (SIGSYS + ENOSYS), or `enosys` (ENOSYS only) |
| `no_syscall_stub` | true when libsystem has no generated stub (`NO_SYSCALL_STUB`, or a name starting with `__`) |
| `comment` | The comment from `syscalls.master`, or null |
| `condition` | null, or the build condition of this variant (`X` or `!X`) |
| `macos_arm64` | true when this variant is the one built for macOS arm64 |
| `alternate` | null, or the other variant (the same keys without `number`) |

`mach-traps.json` is an array for slots 0…127. `number` is the **negative
x16 value** (0, −1, … −127). Each object has these keys:

| Key | Meaning |
|---|---|
| `name` | Kernel handler (`kern_invalid` for empty slots) |
| `user_stub` | The libsystem stub name from `syscall_sw.h`, or null |
| `args`, `arg_names` | The first `arg_count` fields of the kernel argument structure |
| `arg_count` | The number of 64-bit argument registers copied from x0… |
| `returns` | `kern_return_t`, `mach_msg_return_t`, `mach_port_name_t`, `boolean_t`, or `mach_error_t` |
| `status` | `implemented`, or `reserved` (handler `kern_invalid`) |
| `returns_port` | true when the result in x0 is a port name |
| `munge32` | The 32-bit munger name (for information only; not used for arm64 tasks) |

## 3. Counts

| Table | Total | implemented | old | nosys | reserved |
|---|---|---|---|---|---|
| BSD (macOS arm64 variants) | 558 | 453 | 86 | 16 | 3 |
| Mach | 128 | 62 | — | — | 66 (`kern_invalid`) |

- BSD: 111 slots are conditional. Of the 105 empty BSD slots, 92 use
  `nosys` and 13 use `enosys` (slots 8, 11, 17, 19, 21, 22, 275, 276, 391,
  392, 393, 495, 519).
- The largest BSD argument count is 8 (`proc_info_extended_id`, 545), so
  every BSD call fits in x0–x7.
- Mach: six traps return a port name (−26 `mach_reply_port`, −27
  `thread_self_trap`, −28 `task_self_trap`, −29 `host_self_trap`, −50
  `thread_get_special_reply_port`, −91 `mk_timer_create_trap`).

## 4. Platform call (x16 = `0x8000_0000`)

The dispatcher checks this value before the Mach and BSD paths.
**The sub-selector is in x3** (its low 32 bits).

| x3 | Name | Arguments | Result |
|---|---|---|---|
| 0 | I-cache flush | — | **Removed**: does nothing |
| 1 | D-cache flush | — | **Removed**: does nothing |
| 2 | `thread_set_cthread_self` (set the TSD base) | x0 = the new TSD base | The thread's `cthread_self` and **TPIDRRO_EL0** are set to x0. If x0 is above the map's maximum address, the value 0 is stored instead. x0 is **not** modified (it still holds the argument). Carry is untouched |
| 3 | `thread_get_cthread_self` | — | x0 = the current TSD base |
| other | — | — | Does nothing |

The call always returns to the instruction after the `svc`. libsystem's
`_thread_set_tsd_base` sets x3 = 2 and x16 = `0x8000_0000`, then executes
`svc #0x80`.

## 5. Notes on tricky entries

- **BSD 0 (indirect).** With x16 = 0, the real number is taken from x0 and
  the arguments from x1–x8 (`syscall(2)`).
- **BSD number width.** Only the low 16 bits of x16 select the BSD call.
  Numbers ≥ 558 run slot 63 (`nosys`: SIGSYS + ENOSYS).
- **BSD 63** is the kernel's `SYS_invalid` target.
- **BSD 66 `vfork`** is `nosys` ("old vfork") unless CONFIG_VFORK is
  defined. No config file found defines it.
- **BSD 435 `pid_hibernate`** exists only on embedded (CONFIG_EMBEDDED)
  kernels. On macOS it is `nosys`.
- **BSD 501 and 522** have a stray `}` in `syscalls.master`. The parser
  tolerates it.
- **Return-value width:** see `darwin-process-start.md` §4.
  - `int` returns use both x0 and x1 (for example the two-value returns of
    `fork` and `pipe`).
  - Calls that return `user_ssize_t`, `user_addr_t`, `off_t`, or `uint64_t`
    return a 64-bit x0 and set x1 to 0.
  - `exit` (1) and `abort_with_payload` (521) return `void` and normally do
    not return.
- **Mach −31 `mach_msg_trap` and −32 `mach_msg_overwrite_trap`** share one
  argument structure. −31 copies 7 registers and −32 copies 8.
  `syscall_sw.h` declares 9 words for the user stub, and its comment notes
  that the ninth is unused.
- **Mach −47 `mach_msg2_trap`** takes 8 packed 64-bit arguments, for
  example `msgh_bits_and_send_size`. Modern libsystem uses it for most
  message traffic.
- **Mach −59 `swtch_pri`** is declared with one argument in its structure
  and in the user stub, but the table's `arg_count` is 0, so the kernel
  ignores the argument.
- **Mach −76 `_kernelrpc_mach_port_type_trap`** has `arg_count` 3. Its
  32-bit munger handles 4 words, and its second field is declared as
  `mach_port_right_t name` (that is how it appears in the source).
- **Mach −58 `pfz_exit`** has no user stub. Only the commpage text (PFZ)
  code calls it, to take a delayed preemption.
- **Mach −100 `iokit_user_client_trap`** has 8 arguments. Its stub is not
  in `syscall_sw.h`.
- **Mach −108.** The user header lists `thread_set_x86_64_compat`, but on
  this tag the kernel slot is `kern_invalid`.
- **Mach slots 0–9** are reserved: −3 and −4 never reach the table (they are
  fast traps), and the other slots are `kern_invalid`.
- **Invalid Mach trap** (a `kern_invalid` slot, or a number ≤ −128): the
  kernel raises `EXC_SYSCALL`. It does not return `KERN_INVALID_ARGUMENT`.
  `kern_invalid` would return `KERN_INVALID_ARGUMENT`, but the dispatcher
  checks for it first.

## Evidence

All entries are level 1 (Apple open source, `apple-oss-distributions/xnu`,
tag `xnu-12377.121.6`).

- Tables: `bsd/kern/syscalls.master`, `osfmk/kern/syscall_sw.c`,
  `osfmk/kern/syscall_sw.h` (`MACH_TRAP_TABLE_COUNT` = 128),
  `osfmk/mach/mach_traps.h`, `osfmk/mach/syscall_sw.h`.
- Slot semantics: `bsd/kern/makesyscalls.sh` (return-type mapping,
  `SYS_invalid` = 63), `bsd/kern/subr_xxx.c` (`nosys`, `enosys`),
  `bsd/sys/signalvar.h` (`send_sigsys` = 1 on release kernels).
- Dispatch: `bsd/dev/arm/systemcalls.c`, `osfmk/arm64/bsd_arm64.c`,
  `osfmk/arm64/sleh.c`.
- Platform call: `osfmk/arm64/machine_routines.c` (`platform_syscall`),
  `osfmk/arm/machdep_call.c`, `osfmk/arm64/pcb.c`
  (`machine_thread_set_tsd_base`), `libsyscall/custom/custom.s`.
- Build options: `config/MASTER`, `config/MASTER.arm64.MacOSX`.
