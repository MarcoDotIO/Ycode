# Spec: multiple processes (spawn, lifecycle, task ports, cross-task IPC, Unix sockets)

Status: **reference for stage 4b** of `docs/SIMULATOR-LINUX.md` and
`specs/simulator/stage4a-contract.md` ("multiple processes: `posix_spawn`,
task ports, Mach IPC between processes, the host bootstrap port"). Stage 4c
(`launchd_sim` with a minimal job set) depends on it.

It states the user-visible semantics that Ycode's VMM (and Ycode's own
`libsystem_kernel`) must reproduce so that `launchd_sim`, `xpcproxy_sim`,
and the daemons they start can create, watch, signal, and reap each other,
pass Mach rights between processes, and talk over AF_UNIX sockets.

Sources: Apple's open-source xnu only (evidence level 1, see Evidence),
plus the facts already recorded in sibling specs. Ycode's own design
decisions are marked **Ycode** and are not observations.

Related specs (read together):

| Spec | What it supplies here |
|---|---|
| `darwin-process-start.md` | Stack, registers, and `apple[]` at exec (§1.12 refers to it) |
| `mach-ipc.md` | Port, right, message, and notification rules for one space. §4 here gives only the multi-task deltas |
| `threads-and-events.md` | kevent, `EVFILT_PROC` basics, signals, workqueue masks |
| `launchd-sim.md` | Which calls `launchd_sim`/`xpcproxy_sim` use, and the domain model |
| `host-libraries.md` §10 | Ycode-private Mach-routine traps (`x16 = 0x7963_2000 + n`) |
| `darwin-trap-tables.md` + `data/*.json` | Trap numbers |

Conventions: arm64 user space, little-endian. Offsets and sizes in bytes.
`u8/u16/u32/u64` are unsigned, `i32` signed. Errno values are **Darwin**
values (EPERM 1, ENOENT 2, ESRCH 3, EINTR 4, E2BIG 7, ENOEXEC 8, EBADF 9,
ECHILD 10, ENOMEM 12, EACCES 13, EFAULT 14, EINVAL 22, EMFILE 24, EPIPE 32,
ERANGE 34, EAGAIN 35, ENOTSOCK 38, EMSGSIZE 40, EPROTOTYPE 41, ENOTSUP 45,
EAFNOSUPPORT 47, EADDRINUSE 48, ENOBUFS 55, EISCONN 56, ENOTCONN 57,
ECONNREFUSED 61, ENAMETOOLONG 63, EOVERFLOW 84, EBADARCH 86,
EOPNOTSUPP 102). `kern_return_t` values: `KERN_SUCCESS` 0,
`KERN_INVALID_ADDRESS` 1, `KERN_PROTECTION_FAILURE` 2,
`KERN_INVALID_ARGUMENT` 4, `KERN_FAILURE` 5, `KERN_NO_ACCESS` 8,
`KERN_ABORTED` 14, `KERN_INVALID_TASK` 16, `KERN_INVALID_RIGHT` 17,
`KERN_DENIED` 53. Signals: SIGHUP 1, SIGINT 2, SIGABRT 6, SIGKILL 9,
SIGBUS 10, SIGSEGV 11, SIGPIPE 13, SIGTERM 15, SIGSTOP 17, SIGTSTP 18,
SIGCONT 19, SIGCHLD 20, SIGUSR1 30; NSIG 32.

BSD call numbers used below (from `data/bsd-syscalls.json`): exit 1, wait4 7
(nocancel 400), kill 37, getppid 39, execve 59, getpgrp 81, setpgid 82,
socket 97, connect 98 (nocancel 409), bind 104, setsockopt 105, listen 106,
getsockopt 118, sendto 133, shutdown 134, socketpair 135, setsid 147,
csops 169, waitid 173 (nocancel 416), posix_spawn 244, getsid 310,
proc_info 336, `__mac_execve` 380, recvmsg 27 (nocancel 401), sendmsg 28
(nocancel 402), recvfrom 29, accept 30 (nocancel 404), getpeername 31,
getsockname 32, fileport_makeport 430, fileport_makefd 431, pid_suspend 433,
pid_resume 434, memorystatus_control 440, terminate_with_payload 520,
task_inspect_for_pid 538, task_read_for_pid 539, proc_info_extended_id 545.
Mach traps: task_name_for_pid −44, task_for_pid −45, pid_for_task −46.

---

## 0. The library/kernel boundary in Ycode (read first)

Ycode supplies the guest's `libsystem_kernel` (`ycode/SimHostLibs`). Every
`posix_spawnattr_*`, `posix_spawn_file_actions_*`, libproc (`proc_*`), and
`mach_ports_*` function that simulator code imports is therefore Ycode's own
code. Only two things are fixed by the guest:

1. the **public C API** of those functions (signatures, return values,
   errno, and the defaults of §1.14), because simulator binaries call them;
2. the **kernel ABI of real traps** that guest code issues without going
   through these functions. No simulator image imports `___posix_spawn`
   (0 importers in `data/host-lib-surface-kernel.json`), so the BSD 244
   argument block is in practice private to Ycode's library and VMM.

**Ycode (normative):** keep xnu's layout for BSD 244 (§1.2–§1.9) anyway.
It costs nothing, matches `__proc_info` and the other wrappers, and keeps
the door open to running Apple's own libraries. `posix_spawnattr_t` and
`posix_spawn_file_actions_t` are opaque pointers to heap blocks with the
layouts below.

---

## 1. `posix_spawn` (BSD 244)

### 1.1 Call and return

Arguments: `x0` = `pid_t *pid` (may be 0), `x1` = path (C string),
`x2` = pointer to the argument descriptor (§1.2) **or 0**, `x3` = argv
(NULL-terminated pointer array, may be 0), `x4` = envp (same, may be 0).

Results:

- Success, ordinary spawn: carry clear, `x0` = 0. The child's pid is
  written to `*pid` if `pid` ≠ 0 (as one aligned 32-bit store; an
  unaligned pointer is also accepted). A write fault on `*pid` is ignored.
- Success with `POSIX_SPAWN_SETEXEC`: the call does **not return**. The
  calling process continues as the new image (same pid).
- Failure: carry set, `x0` = errno. The library wrapper returns that errno
  as the function result (not −1) and leaves `errno` unchanged.
- After a failed ordinary spawn **no child is visible**: the half-built
  child is exited and reaped by the kernel without SIGCHLD, zombie, or pid
  report.
- After a failed `SETEXEC` before the image is committed, the caller is
  unchanged. A failure after the commit point kills the process with
  SIGKILL (the caller never sees a return).

The library wrapper passes `x2` = 0 when it has no attributes and no file
actions (the attribute pointer argument was NULL **and** there are no file
actions or the file-actions object holds 0 actions). Otherwise it fills a
zeroed descriptor.

### 1.2 Argument descriptor `struct _posix_spawn_args_desc` (144 bytes)

Nine (size, pointer) pairs. A pair with size 0 means "absent". The kernel
copies the whole 144 bytes first.

| Off | Field | Set by the library to |
|---|---|---|
| 0 | `attr_size` (u64) | 248 (= sizeof attribute block, §1.4) when attributes exist |
| 8 | `attrp` | the attribute block |
| 16 | `file_actions_size` | `8 + 1040 × count` (§1.7) when count > 0 |
| 24 | `file_actions` | the file-actions block |
| 32 | `port_actions_size` | `8 + 24 × count` (§1.8) when the attribute has port actions |
| 40 | `port_actions` | the port-actions block |
| 48 | `mac_extensions_size` | `8 + 144 × count` (§1.9) |
| 56 | `mac_extensions` | |
| 64 | `coal_info_size` | 48 (§1.9) |
| 72 | `coal_info` | |
| 80 | `persona_info_size` | 88 (§1.9) |
| 88 | `persona_info` | |
| 96 | `posix_cred_info_size` | 340 (§1.9) |
| 104 | `posix_cred_info` | |
| 112 | `subsystem_root_path_size` | 1024 (`MAXPATHLEN`) |
| 120 | `subsystem_root_path` | a 1024-byte buffer holding a C string |
| 128 | `conclave_id_size` | 128 (`MAXCONCLAVENAME`) |
| 136 | `conclave_id` | a 128-byte buffer holding a C string |

Kernel copy-in rules (each failure aborts the spawn with the errno shown):

| Block | Rule |
|---|---|
| attributes | Only **bytes 0…191** (up to, not including, the pointer fields at 192) are read; the seven pointers inside the attribute block are ignored in favour of the descriptor's pointers. Any nonzero `attr_size` enables attributes |
| file actions | `size` must be ≥ `8 + 1040` and ≤ `8 + 1040 × RLIMIT_NOFILE(current)`, else EINVAL. After copy-in, `size` must equal `8 + 1040 × psfa_act_count`, else EINVAL |
| port actions | `size` must be ≥ `8 + 24` and ≤ the page size (16384), else EINVAL. After copy-in, `size` must equal `8 + 24 × pspa_count`, else EINVAL |
| persona | `size` must be exactly 88, else ERANGE |
| posix cred | `size` must be exactly 340 (ERANGE); caller must be root (EPERM); with the GROUPS flag, `ngroups` ≤ 16 (EINVAL); `pspci_login[255]` is forced to NUL |
| subsystem root | Copied only if 0 < size ≤ 1024 **and** the caller has the entitlement `com.apple.private.spawn-subsystem-root`; otherwise silently ignored. The last byte is forced to NUL |
| coalition | `min(size, 48)` bytes are read |
| conclave | Exclave-capable kernels only; ignored elsewhere. With `SETEXEC` → EINVAL |
| any pointer | Unreadable memory → EFAULT |

The `*_alloc` header fields of the file-action and port-action blocks are
carried but never interpreted.

### 1.3 Spawn modes

| Mode | Selected by | Effect |
|---|---|---|
| **Spawn** | no attributes, or `psa_flags` without `SETEXEC` | A new process (new pid, new task, new address space) is created as a child of the caller and runs the image |
| **Exec with options** | `psa_flags & POSIX_SPAWN_SETEXEC` (0x40) | Like `execve` (59) on the calling process, with all spawn attributes, file actions, and port actions applied to the caller. pid, parent, children, process group, session, and EVFILT_PROC watchers are kept |

`xpcproxy_sim` uses the second mode to become the job program
(`launchd-sim.md` §4.4).

### 1.4 Attribute block `struct _posix_spawnattr` (248 bytes)

| Off | Size | Field | Library default (`posix_spawnattr_init`) | Kernel use |
|---|---|---|---|---|
| 0 | 2 | `psa_flags` (i16) | 0 | §1.5 |
| 2 | 2 | padding | 0 | — |
| 4 | 4 | `psa_sigdefault` (sigset u32) | 0 | `SETSIGDEF`: each set bit `1 << (sig−1)` resets that signal to SIG_DFL in the child |
| 8 | 4 | `psa_sigmask` | 0 | `SETSIGMASK`: the child's main-thread mask = this value minus SIGKILL/SIGSTOP |
| 12 | 4 | `psa_pgroup` (pid) | 0 | `SETPGROUP` (§1.10 step 12) |
| 16 | 16 | `psa_binprefs[4]` (cpu_type) | all 0 | Architecture preference (§1.6) |
| 32 | 4 | `psa_pcontrol` | 0 | Resource-starvation action 0–3 (none/throttle/suspend/kill). Reported in `pbi_flags` (§2.11). Ycode: record only |
| 36 | 4 | `psa_apptype` | 0 | Process type (§1.6) |
| 40 | 8 | `psa_cpumonitor_percent` | 0 | CPU monitor (ignorable) |
| 48 | 8 | `psa_cpumonitor_interval` (s) | 0 | ignorable |
| 56 | 8 | `psa_reserved` | **1** | unused |
| 64 | 2 | `psa_jetsam_flags` | 0 | §1.6 |
| 66 | 2 | padding | 0 | — |
| 68 | 4 | `psa_priority` | **−1** | jetsam band |
| 72 | 4 | `psa_memlimit_active` (MiB) | **−1** | jetsam |
| 76 | 4 | `psa_memlimit_inactive` (MiB) | **−1** | jetsam |
| 80 | 8 | `psa_qos_clamp` | 0 | §1.6 |
| 88 | 4 | `psa_darwin_role` | 0 | §1.6 |
| 92 | 4 | `psa_thread_limit` | 0 | > 0 sets a thread cap (ignorable) |
| 96 | 8 | `psa_max_addr` | 0 | ≠ 0 caps the user VA (ignorable) |
| 104 | 1 | `psa_no_smt` (bool) | 0 | ignorable |
| 105 | 1 | `psa_4k` (bool) | 0 | adds `vm_force_4k_pages=1` to `apple[]` on mixed-page macOS only |
| 106 | 1 | `psa_tecs` (bool) | 0 | ignorable |
| 107 | 1 | padding | | |
| 108 | 4 | `psa_platform` | 0 | macOS only: an iOS binary needs platform = iOS here. Ycode: ignore |
| 112 | 16 | `psa_subcpuprefs[4]` (cpu_subtype) | all **0xFFFFFFFF** (`CPU_SUBTYPE_ANY`) | §1.6 |
| 128 | 4 | `psa_options` | 0 | bits: 0x1 disable PAC A-keys for plug-in hosts, 0x2 alternate Rosetta, 0x4 dataless I/O policy valid, 0x8 page-in telemetry. Ycode: ignore except 0x4 bookkeeping |
| 132 | 4 | `psa_port_soft_limit` | 0 | port-space limits (ignorable) |
| 136 | 4 | `psa_port_hard_limit` | 0 | |
| 140 | 4 | `psa_filedesc_soft_limit` | 0 | fd limits (ignorable) |
| 144 | 4 | `psa_filedesc_hard_limit` | 0 | |
| 148 | 4 | `psa_crash_behavior` | 0 | panic-on-crash flags (needs entitlement; ignore) |
| 152 | 4 | `psa_dataless_iopolicy` | 0 | with option 0x4 |
| 156 | 4 | padding | | |
| 160 | 8 | `psa_crash_behavior_deadline` | 0 | ignore |
| 168 | 1 | `psa_launch_type` | 0 | launch-constraint type (ignore) |
| 169 | 1 | padding | | |
| 170 | 2 | `psa_sec_flags` | 0 | memory-tagging security flags (ignore) |
| 172 | 4 | `psa_crash_count` | 0 | stored in the child (ignore) |
| 176 | 4 | `psa_throttle_timeout` | 0 | stored in the child (ignore) |
| 180 | 4 | `psa_kqworkloop_soft_limit` | 0 | ignorable |
| 184 | 4 | `psa_kqworkloop_hard_limit` | 0 | ignorable |
| 188 | 4 | `psa_conclave_mem_limit` | 0 | ignorable |
| 192 | 8 | `psa_ports` → port actions | NULL | (library-side only, §1.2) |
| 200 | 8 | `psa_mac_extensions` | NULL | |
| 208 | 8 | `psa_coalition_info` | NULL | |
| 216 | 8 | `psa_persona_info` | NULL | |
| 224 | 8 | `psa_posix_cred_info` | NULL | |
| 232 | 8 | `psa_subsystem_root_path` | NULL | |
| 240 | 8 | `psa_conclave_id` | NULL | |

### 1.5 `psa_flags`

The kernel does not reject unknown bits; it ignores them.

| Bit | Name | Effect |
|---|---|---|
| 0x0001 | `POSIX_SPAWN_RESETIDS` | Child's effective uid/gid := caller's real uid/gid (before set-id bits of the image apply) |
| 0x0002 | `POSIX_SPAWN_SETPGROUP` | `setpgid(child, psa_pgroup)` after image activation; `psa_pgroup` 0 = new group with id = child pid. Errors as `setpgid` (§2.10) fail the spawn |
| 0x0004 | `POSIX_SPAWN_SETSIGDEF` | Signals in `psa_sigdefault` → SIG_DFL in the child (handler, trampoline, mask, flags cleared) |
| 0x0008 | `POSIX_SPAWN_SETSIGMASK` | Child main-thread mask := `psa_sigmask & ~(SIGKILL|SIGSTOP)` |
| 0x0040 | `POSIX_SPAWN_SETEXEC` | Exec-with-options mode (§1.3) |
| 0x0080 | `POSIX_SPAWN_START_SUSPENDED` | The new image starts **stopped**: process state `SSTOP` (4) and its task suspended once. It runs after `kill(pid, SIGCONT)`, `pid_resume`, or `task_resume` |
| 0x0100 | `_POSIX_SPAWN_DISABLE_ASLR` | No ASLR for the child (and its descendants) |
| 0x0200 | `_POSIX_SPAWN_NANO_ALLOCATOR` | Adds `MallocNanoZone=1` to `apple[]` (`darwin-process-start.md` §1.4 #2) |
| 0x0400 | `POSIX_SPAWN_SETSID` | `setsid()` in the child after image activation; EPERM fails the spawn |
| 0x0800 | `_POSIX_SPAWN_RESLIDE` | Re-slide the shared region (arm64e). Ycode: ignore |
| 0x1000 | `_POSIX_SPAWN_FORCE_4K_PAGES` | As `psa_4k` |
| 0x2000 | `_POSIX_SPAWN_ALLOW_DATA_EXEC` | Ycode: ignore |
| 0x4000 | `POSIX_SPAWN_CLOEXEC_DEFAULT` | Every descriptor not explicitly produced or marked by a file action is closed at exec (§1.7) |
| 0x8000 | `_POSIX_SPAWN_HIGH_BITS_ASLR` | Ycode: ignore |

### 1.6 Value sets

**Architecture preference** (`psa_binprefs`, `psa_subcpuprefs`; set by
`posix_spawnattr_setbinpref_np`/`setarchpref_np`, used by `launchd_sim`
and `xpcproxy_sim` with `BinaryOrderPreference = arm64`):

1. If `binprefs[0]` is 0 there is no preference: normal selection.
2. Otherwise, for a **fat** file, slots are tried in order. A 0 slot ends
   the list with EBADARCH; `CPU_TYPE_ANY` (−1) falls back to normal
   selection; otherwise the first slice matching (cputype, subtype) wins.
   If no slot matches before slot 4, normal selection is used.
3. For a **thin** file, its cputype/subtype must match one slot (with the
   same 0 and −1 rules), else EBADARCH (86).

Ycode only runs arm64 (`CPU_TYPE_ARM64` = 0x0100000C); it must still
reject a non-matching thin file with EBADARCH and pick the arm64 slice of
a fat file.

**Process type** (`psa_apptype & 0xF00`; set by
`posix_spawnattr_setprocesstype_np`): 0x100 app default, 0x200 app non-UI,
0x300 daemon standard, 0x400 daemon interactive, 0x500 daemon background,
0x600 daemon adaptive, 0x700 driver (needs entitlement
`com.apple.private.spawn-driver`, else EPERM). Other values are accepted
and ignored. Ycode: record per process (it only affects scheduling and
`pbi_flags` darwin-bg bits).

**QoS clamp** (`set_qos_clamp_np` rejects ≥ 4 with EINVAL): 0 none,
1 utility, 2 background, 3 maintenance. **Darwin role**
(`set_darwin_role_np`): 0 none, 1 UI focal, 2 UI, 3 non-UI, 4 UI non-focal,
5 TAL launch, 6 darwin-BG, 7 user-init. Ycode: record, no effect.

**Jetsam** (`setjetsam_ext` sets `psa_jetsam_flags |= 0x8000` "set"):
0x01 use effective priority, 0x02 hi-water background (legacy), 0x04
active-limit fatal, 0x08 inactive-limit fatal, 0x10 realtime audio,
0x30 relaunch-behavior mask (0x10 low, 0x20 medium, 0x30 high, from
`set_jetsam_ttr_np`). Ycode: store priority and limits for
`memorystatus_control` queries; never kill for memory.

### 1.7 File actions

Block: `{i32 psfa_act_alloc @0, i32 psfa_act_count @4, actions @8}`; each
action is **1040 bytes**:

| Off | Size | Field |
|---|---|---|
| 0 | 4 | `psfaa_type` (§ table below) |
| 4 | 4 | `psfaa_filedes` (i32) — or `psfaa_fileport` (u32 Mach name) for type 4 |
| 8 | 4 | open: `oflag` (i32) / dup2 and fileport-dup2: `newfiledes` (i32) / chdir: start of `path` |
| 12 | 2 | open: `mode` (u16) |
| 14 | 1024 | open: `path` (NUL-terminated) |
| 8 | 1024 | chdir: `path` (overlays the open fields) |

| Type | Name | Library API | Kernel action (in the child, with the caller's credentials) |
|---|---|---|---|
| 0 | OPEN | `addopen(fd, path, oflag, mode)` | `open(path, oflag, mode & ~umask & 0777, sticky bit dropped)`; if the result ≠ fd, `dup2` it onto fd and close the original |
| 1 | CLOSE | `addclose(fd)` | `close(fd)`; closing a non-open fd is an error (EBADF) |
| 2 | DUP2 | `adddup2(fd, newfd)` | `dup2(fd, newfd)`. The new descriptor has close-on-exec clear |
| 3 | INHERIT | `addinherit_np(fd)` | fd must be open (EBADF); clears its close-on-exec flag; a guarded fd fails |
| 4 | FILEPORT_DUP2 | `add_fileportdup2_np(port, newfd)` | Takes a COPY_SEND of the caller's fileport send right (§4.9; wrong kind or bad name → EINVAL), makes a new fd for it, `dup2` onto newfd, closes the temporary |
| 5 | CHDIR | `addchdir_np(path)` (also `addchdir`) | `chdir(path)` |
| 6 | FCHDIR | `addfchdir_np(fd)` (also `addfchdir`) | `fchdir(fd)` |
| other | | | EINVAL |

Rules:

1. Actions run **in order**, after the child's descriptor table was copied
   from the parent (§1.11) and before the image is activated. The first
   failing action fails the whole spawn with its errno.
2. Because actions run before activation, the **image path is resolved
   relative to the cwd after CHDIR/FCHDIR actions**.
3. `POSIX_SPAWN_CLOEXEC_DEFAULT`: after all actions succeed, these
   descriptors are marked "inherit": the target of OPEN, the `newfd` of
   DUP2 and FILEPORT_DUP2, and the fd of INHERIT. CLOSE, CHDIR, and FCHDIR
   mark nothing. At image activation every descriptor that is not marked
   is closed, in addition to the close-on-exec ones (§1.11). A marked
   descriptor that is close-on-exec is still closed.
4. Library-side validation: `addopen`, `addclose`, `addinherit_np`,
   `addfchdir` need 0 ≤ fd < 10240 (`OPEN_MAX`), else EBADF; `adddup2`
   checks both fds; `add_fileportdup2_np` needs a valid port name and
   newfd in range (EBADF); `addchdir` returns ENAMETOOLONG for a path of
   ≥ 1024 bytes; a NULL object → EINVAL. Growth doubles the allocation
   (initial 2).

### 1.8 Port actions

Block: `{i32 pspa_alloc @0, i32 pspa_count @4, actions @8}`; each action is
**24 bytes**:

| Off | Size | Field |
|---|---|---|
| 0 | 4 | `port_type` (§ table) |
| 4 | 4 | `mask` (exception mask) |
| 8 | 4 | `new_port` (Mach name in the **caller's** space) |
| 12 | 4 | `behavior` (exception behavior) |
| 16 | 4 | `flavor` (thread-state flavor) |
| 20 | 4 | `which` (special-port number) |

| Type | Name | Library API | Effect on the new task | Limit |
|---|---|---|---|---|
| 0 | SPECIAL | `setspecialport_np(port, which)` | `task_set_special_port(child, which, port)` (§3.2). Failure (e.g. `which` = 1 or 2 → `KERN_NO_ACCESS`) → spawn EINVAL | — |
| 1 | EXCEPTION | `setexceptionports_np(mask, port, behavior, flavor)` | `task_set_exception_ports(child, mask, port, behavior, flavor)`, applied late (step 10 of §1.10). Failure → EINVAL | 14 per spawn |
| 2 | AU_SESSION | `setauditsessionport_np(port)` | Child joins that audit session | — |
| 3 | IMP_WATCHPORTS | `set_importancewatch_port_np(count, ports)` (count ≤ 128) | Importance boost bookkeeping. Ycode: accept, drop | 128 |
| 4 | REGISTERED_PORTS | `set_registered_ports_np(ports, count)` (count ≤ 3, else EINVAL) | `mach_ports_register(child, …)` with the ports **in action order**; missing slots become NULL (§3.4) | 3 |
| 5 | PTRAUTH_TASK_PORT | `set_ptrauth_task_port_np(port)` | Development kernels only; else the right is just released | 1 |
| other | | | EINVAL | |

Rules:

1. A first pass counts the types; any limit exceeded or unknown type →
   EINVAL before anything is changed.
2. For each action, a **valid** `new_port` name is copied in from the
   caller's space as **COPY_SEND** (the name must hold a send right; a
   receive-only name or a bad name → EINVAL). The caller keeps its own
   right; the child receives an additional send right. A `new_port` of
   `MACH_PORT_NULL` (0) or `MACH_PORT_DEAD` (0xFFFFFFFF) is passed through
   as the null/dead value without a copy-in.
3. Rights copied in but not consumed (any failure, or the action does not
   keep them) are released when the spawn ends, successful or not.
4. Port actions are applied **after** the inherited special ports were
   copied into the new task (§3.3), so they override inheritance.
5. With `SETEXEC`, IMP_WATCHPORTS while the caller holds watch-port boosts
   → EINVAL.

### 1.9 Other attribute blocks

| Block | Layout | Kernel behavior | Ycode |
|---|---|---|---|
| MAC policy extensions | header `{i32 alloc, i32 count}`, then per entry 144 bytes: `char policyname[128]` @0, `u64 data` (user pointer) @128, `u64 datalen` @136 | Passed to MAC policies (sandbox etc.) | Ignore (accept) |
| Coalition info (48) | 2 entries × 24: `u64 id` @0, `u32 role` @8, `u32` @12, `u64` @16. Index 0 = resource, 1 = jetsam | Spawn into the given coalitions; needs a privileged coalition or the entitlement `com.apple.private.coalition-spawn` (EPERM); unknown id → ESRCH; if any type is given, the resource one is required (EINVAL) | Ignore (accept); one implicit coalition |
| Persona info (88) | `u32 pspi_id` @0, `u32 flags` @4, `uid` @8, `gid` @12, `u32 ngroups` @16, `gid groups[16]` @20, `uid gmuid` @84. Flag bits 0x1 override, 0x2 verify, 0x10000 uid, 0x20000 gid, 0x40000 groups | Child adopts the persona's credentials. With SETEXEC → ENOTSUP | Accept, ignore (all guest processes share one uid, `launchd-sim.md` §4.2) |
| POSIX cred info (340) | `u32 flags` @0, `uid` @4, `gid` @8, `u32 ngroups` @12, `groups[16]` @16, `gmuid` @80, `char login[256]` @84. Flags 0x10000 uid, 0x20000 gid, 0x40000 groups, 0x80000 login | Root only (EPERM). Applied gid → groups → uid; login after setsid. With SETEXEC → ENOTSUP | Return EPERM unless the guest is uid 0 |
| Subsystem root path | C string ≤ 1024 | Only with the entitlement: becomes `apple[]` `subsystem_root_path=<path>` and the process's subsystem root | See open question 3 |
| Conclave id | C string ≤ 128 | Exclaves only | Ignore |

### 1.10 Order of operations (normative)

1. Copy in and validate the descriptor and blocks (§1.2). Validate the
   process type (§1.6).
2. **Spawn:** check coalitions; create the child process: new pid (§2.1),
   new task with an empty port space, its descriptor table copied from the
   parent (§1.11), cwd = the calling thread's cwd if it has one, else the
   process cwd. The child is not yet runnable and cannot receive signals.
   **SETEXEC:** create a shadow process/task for the same pid instead.
3. Record the subsystem root and crash-behavior fields.
4. Apply file actions (§1.7).
5. Apply port actions except exception ports (§1.8).
6. `RESETIDS`, POSIX cred info, persona; ASLR flags.
7. Activate the image (load, `apple[]`, stack — `darwin-process-start.md`).
   Signal reset at exec happens here (§1.11). `START_SUSPENDED` stops the
   process here. Close-on-exec closing happens here.
8. **SETEXEC:** the new task replaces the old one under the same pid
   (§1.11 "exec" column). From here on failure kills the process.
9. `SETPGROUP`, then `SETSID`, then `SETSIGMASK`, then `SETSIGDEF`, then
   the CPU monitor, then the POSIX-cred login name. A failure here fails
   the spawn (SETEXEC: SIGKILL).
10. Process control state (`psa_pcontrol`); task control-port defaults;
    the task's IPC becomes active (from now on `task_for_pid` etc. can
    see it); **exception-port actions** are applied; jetsam settings;
    thread/port/fd limits.
11. Process type, QoS clamp, Darwin role, watch ports, then **registered
    ports** (§3.4).
12. Code-signature evaluation. Then `NOTE_FORK` (data = child pid in the
    hint, not in `data`) is posted to the **parent's** EVFILT_PROC
    watchers (ordinary spawn only), and `NOTE_EXEC` to the process's own
    watchers.
13. Ordinary spawn: copy out the pid; the child's first thread is released
    to run in user space.

### 1.11 What a new image starts with

| Property | Ordinary spawn (child) | SETEXEC / `execve` (same process) |
|---|---|---|
| pid | new | same |
| parent, children, pgrp, session | parent = caller; pgrp and session = caller's (unless SETPGROUP/SETSID) | unchanged |
| uid/gid/groups | caller's (RESETIDS, persona, cred info, set-id image may change) | unchanged (same modifiers) |
| pid version (audit token `val[7]`) | fresh | **changes** on every exec; always differs from the previous value |
| unique id (`p_uniqueid`) | fresh, increasing | unchanged |
| address space, threads | new, one thread | new, one thread; other threads of the old image are gone |
| **Mach port names** | empty space except the self names Ycode installs | **new empty space**: every right of the old image is released as on task termination (§4.6). Only special, registered, and exception ports carry over |
| Task special ports (host, bootstrap, task-access) | send-right copies of the **caller's** | copies of the old task's |
| Registered ports (3 slots) | copies of the caller's | copies of the old task's |
| Exception ports (types 1–13) | copies of the caller's (port, behavior, flavor) | copies of the old task's; dropped if the image is set-id |
| Port actions | applied over the inherited values | same |
| Descriptors | copy of the caller's table, except: kqueues and other "confined" files, descriptors marked close-on-fork | same table |
| …then at activation | close-on-exec descriptors closed; with CLOEXEC_DEFAULT also every unmarked one | same |
| cwd, root, umask | caller thread's cwd (or process cwd), root, umask | unchanged |
| Signal actions | caller's, then: caught signals → SIG_DFL (if the default action is "ignore", the signal becomes ignored, except SIGCONT); ignored stay ignored; then SETSIGDEF | same reset |
| Signal mask (main thread) | the **calling thread's** mask (a workqueue thread's mask if spawned from one: almost everything blocked, `threads-and-events.md` §5.7), then SETSIGMASK | the calling thread's mask, then SETSIGMASK |
| Pending signals | none | kept (process and calling thread pending sets merge) |
| Alternate signal stack | none | disabled |
| Interval timers | cleared | kept |
| EVFILT_PROC watchers on this pid | none | kept (they get `NOTE_EXEC`) |
| `p_comm` / `p_name` | last path component of the image, truncated to 16 / 32 bytes (incl. NUL) | same |
| Resource usage | zero | kept |

### 1.12 argv, envp, `apple[]`

- argv and envp are copied from the caller's arrays as given; a NULL
  array pointer is an empty list (argc may be 0). No PATH search (that is
  `posix_spawnp` in libc).
- The executable path string stored for `apple[0]` (`executable_path=`) is
  the `path` argument **as passed**, possibly relative.
- Interpreter scripts (`#!`) follow execve rules: interpreter arguments
  first, then the script path replaces argv[0].
- Total string space (path + argv + envp + pointer slots) is limited to
  1 MiB (`NCARGS`); exceeding it → E2BIG.
- `apple[]` content and order: `darwin-process-start.md` §1.4. Spawn
  attributes add `MallocNanoZone=1` (flag 0x200), `subsystem_root_path=`
  (§1.9), and `vm_force_4k_pages=1` (macOS mixed pages only).

### 1.13 Errors

| errno | Cause |
|---|---|
| EINVAL | bad block size or count (§1.2); bad file-action or port-action type; port-action limit; port copy-in failure; special/exception port set failure; registered-port set failure; coalition role set failure |
| ERANGE | persona or cred block of the wrong size |
| EPERM | cred info without root; coalition without privilege; driver type without entitlement; SETSID/SETPGROUP failures (per §2.10) |
| ESRCH | unknown coalition id |
| ENOTSUP | persona or cred info with SETEXEC |
| EBADF / ENOENT / EACCES / … | a file action's own error |
| EBADARCH (86) | no acceptable slice (§1.6) |
| ENOEXEC, EACCES, ENOENT, ENAMETOOLONG, E2BIG, EFAULT, ENOMEM, ETXTBSY, EBADEXEC (85), EBADMACHO (88) | image activation, as `execve` |
| EAGAIN | process limit reached |

### 1.14 Library API rules (Ycode's `libsystem_kernel`)

- `posix_spawnattr_init` allocates 248 bytes and sets the defaults of
  §1.4 (note `psa_reserved` = 1, jetsam −1s, subcpu prefs 0xFFFFFFFF).
  ENOMEM on allocation failure. `destroy` frees the attached blocks.
- Every setter returns EINVAL for a NULL object. `setflags` stores the
  value without validation. `getflags` and friends read back.
- `setbinpref_np(count, prefs, &ocount)` copies up to 4 and fills the
  rest with 0 / `CPU_SUBTYPE_ANY`; `ocount` = number copied.
  `setarchpref_np` does the same with explicit subtypes.
- Port-action setters append one 24-byte action each (registered ports and
  watch ports append one per port, in array order). Initial allocation 2,
  doubling.
- `setjetsam_ext(flags, prio, active, inactive)` stores `flags | 0x8000`.
- `set_subsystem_root_path_np(path)` copies into a 1024-byte buffer
  (ENAMETOOLONG if longer); NULL clears it.
- `setcpumonitor(percent, interval)`, `setdataless_iopolicy_np(policy)`
  (sets option 0x4 and stores `policy | ORIG`), `set_darwin_role_np`,
  `set_qos_clamp_np` store their values.
- `posix_spawnattr_set_use_sanitizers_np` and
  `…_set_use_sec_transition_shims_np` are imported by the runtime's
  `libsystem_sim_kernel_host`. The second sets `psa_sec_flags`; the first
  is not in this xnu tag (open question 6).

---

## 2. Process lifecycle

### 2.1 Process table and identifiers

- **pid allocation:** the next pid is `last + 1`; at 99999 (`PID_MAX`) it
  wraps to **100**. A candidate is skipped while any live process, zombie,
  process group, or session uses that number. 100000 (`NO_PID`) is used as
  "no pid" in tty fields.
- Each process also has a **pid version** (incremented globally per new
  process and per exec, never equal to the previous value on exec) and a
  64-bit **unique id** (incremented per new process, kept across exec).
  Both appear in `proc_uniqidentifierinfo` and the audit token.
- **Ycode:** pid 1 is a VMM-owned pseudo-init that never runs guest code
  (on the Mac, pid 1 is the host's launchd). It adopts orphans (§2.5).
  `launchd_sim` gets an ordinary pid (it is not pid 1 on the Mac either,
  `launchd-sim.md` §1).

### 2.2 Process states (`pbi_status`)

1 `SIDL` (being created), 2 `SRUN`, 3 `SSLEEP`, 4 `SSTOP` (stopped or
start-suspended), 5 `SZOMB` (exited, not yet reaped). **Ycode:** report
SRUN for a running process, SSTOP while stopped, SZOMB for zombies.

### 2.3 Exit status encoding (`p_xstat`)

| Cause | Status word | `p_xhighbits` |
|---|---|---|
| `exit(v)` (BSD 1) | `(v & 0xFF) << 8` (`W_EXITCODE(v, 0)`) | `(v >> 24) & 0xFF` |
| Killed by signal s | `s` (`W_EXITCODE(0, s)`); `| 0x80` (`WCOREFLAG`) if a core was produced | 0 |
| Stopped by signal s (wait reporting) | `(s << 8) | 0x7F` | — |
| Continued | `(SIGCONT << 8) | 0x7F` = 0x137F | — |
| Spawn failed internally | (never reported) | — |

Macros: `WIFEXITED` = low 7 bits 0; `WEXITSTATUS` = bits 8–15;
`WIFSIGNALED` = low 7 bits ∉ {0, 0x7F}; `WTERMSIG` = low 7 bits;
`WIFSTOPPED` = low 7 bits 0x7F and bits 8–15 ≠ 0x13.

Fatal signals produced by the VMM for guest faults (SIGSEGV, SIGBUS,
SIGILL, SIGTRAP, SIGABRT from `abort`, SIGKILL from `terminate_with_payload`)
use the "killed by signal" form. **Ycode:** never set `WCOREFLAG` (no
cores).

### 2.4 Exit sequence (normative order)

When the last thread exits, `exit` is called, or a fatal signal is taken:

1. All other threads of the process are terminated.
2. **Mach teardown:** the task's kernel ports stop working (calls on its
   task/thread ports fail), then its port space is destroyed (§4.6). The
   resulting notifications (dead-name, no-senders, send-once,
   port-destroyed) are queued now.
3. Descriptors are closed (sockets disconnect, peers see EOF/EPIPE).
4. If the process is a session leader with a controlling terminal, the
   terminal's foreground group gets SIGHUP. (Ycode: no terminals.)
5. Children: zombie children are reaped by the kernel; live children are
   **reparented to pid 1** and marked "parent died" (they will be reaped by
   the kernel when they exit; `getppid()` returns 1 from now on).
6. `NOTE_EXIT` is posted to every EVFILT_PROC watcher of this pid (§2.8),
   with the status word.
7. Parent notification:
   - If the parent **ignores SIGCHLD** (handler SIG_IGN or `SA_NOCLDWAIT`,
     which sets the parent's no-child-wait flag) the process is **reaped
     immediately**: no zombie, no SIGCHLD, `wait4` will not see it. Its
     rusage is still added to the parent's child totals.
   - Otherwise the process becomes a **zombie** (`SZOMB`), the parent's
     last-child info (`si_pid`, `si_status`, `si_code` CLD_EXITED, `si_uid`)
     is recorded, **SIGCHLD** is posted to the parent, and threads waiting
     in `wait4`/`waitid` in the parent are woken.
   - If the parent is pid 1 (orphan), the kernel reaps it immediately.

**Ycode:** make the zombie (step 7) visible **before** posting `NOTE_EXIT`
(step 6) to watchers that are the parent, so a parent that calls
`wait4(pid, WNOHANG)` on receiving `NOTE_EXIT` always finds the zombie.
xnu posts the note first and sets the state immediately after; the
reordering removes a race and is not observable otherwise.

### 2.5 Zombies and reaping

- A zombie keeps: pid, ppid, pgid, status, rusage, comm/name, uid, pid
  version, unique id. It is visible to `proc_listpids` (zombies listed after
  live processes), to `kill` (success, no effect), and to
  `proc_pidinfo` flavors that accept zombies (§2.11).
- Reaping (by `wait4`/`waitid` without `WNOWAIT`, or by the kernel) frees
  the pid. Only then can the number be reused (§2.1).
- Only the parent can reap. A second waiter on the same child blocks until
  the first finishes ("wait collision") and then rescans.

### 2.6 `wait4` (BSD 7; 400 is the non-cancelable form)

Arguments: `pid`, `int *status`, `options`, `struct rusage *` (144 bytes).

| `pid` | Matches children with |
|---|---|
| > 0 | that pid |
| −1 (`WAIT_ANY`) | any |
| 0 | the caller's process group (converted to `−pgid`) |
| < −1 | process group `−pid` |
| `INT_MIN` | → EINVAL |

Options: `WNOHANG` 0x1, `WUNTRACED` 0x2, `WCONTINUED` 0x10. Other bits are
ignored.

For each matching child, in child-list order:

1. Zombie → return its pid; `*status` = `p_xstat & 0xFFFF`; `*rusage` =
   its rusage; reap it. If the caller blocks SIGCHLD and this was the only
   child, a pending SIGCHLD of the calling thread is cleared.
2. Stopped, not yet reported, and (`WUNTRACED` or traced) → return pid,
   `*status` = `(stopsig << 8) | 0x7F`; mark it reported.
3. `WCONTINUED` and it was continued since the last report → return pid,
   `*status` = 0x137F; clear the flag.

No matching child at all → ECHILD. Matching children but none ready:
`WNOHANG` → return 0; otherwise block, interruptibly (a caught signal ends
the wait with EINTR, or restarts it under `SA_RESTART`). A copyout fault →
EFAULT (the child is not reaped).

### 2.7 `waitid` (BSD 173; 416 non-cancelable)

Arguments: `idtype` (`P_ALL` 0, `P_PID` 1, `P_PGID` 2), `id`,
`siginfo_t *`, `options`. Options must be nonzero and within `WNOHANG`
0x1 | `WEXITED` 0x4 | `WSTOPPED` 0x8 | `WCONTINUED` 0x10 | `WNOWAIT` 0x20,
else EINVAL; a negative id with `P_PID`/`P_PGID` → EINVAL.

Results (copied into the 104-byte `siginfo_t`: `si_signo` @0, `si_errno`
@4, `si_code` @8, `si_pid` @12, `si_uid` @16, `si_status` @20, `si_addr`
@24, `si_value` @32, `si_band` @40, pad @48…103):

| Child state | Needs | `si_code` | `si_status` | Consumes |
|---|---|---|---|---|
| Zombie, killed by signal | WEXITED | CLD_KILLED 2 (CLD_DUMPED 3 with core) | the signal | reaps unless WNOWAIT |
| Zombie, exited | WEXITED | CLD_EXITED 1 | `WEXITSTATUS & 0xFFFFFF`, with `p_xhighbits << 24` OR-ed in (so the **full 32-bit exit value** is recovered) | reaps unless WNOWAIT |
| Stopped, not reported | WSTOPPED | CLD_STOPPED 5 | stop signal | marks reported unless WNOWAIT |
| Continued | WCONTINUED | CLD_CONTINUED 6 | `p_xstat`; `si_pid` = the pid that sent SIGCONT | clears unless WNOWAIT |

`si_signo` = SIGCHLD. No match → ECHILD. `WNOHANG` with nothing ready →
return 0 **without touching** the siginfo. Otherwise block as `wait4`.

### 2.8 `EVFILT_PROC` (kevent filter −5)

Supplements `threads-and-events.md` §3.7.5.

- Attach: `ident` = pid. `NOTE_TRACK`/`NOTE_TRACKERR`/`NOTE_CHILD`
  (0x1/0x2/0x4) → error ENOTSUP in the event. No such live process →
  ESRCH. Asking for both `NOTE_EXIT` and `NOTE_EXITSTATUS` requires the
  caller to be the parent, the tracing parent, or allowed to send SIGKILL
  to the target (§2.9), else EACCES. Zombies cannot be watched.
- `EV_CLEAR` is forced. Input `data` is ignored. Only events after the
  attach are reported.
- Events (`fflags` out = events seen since the last delivery, for those
  requested): `NOTE_EXIT` 0x8000_0000, `NOTE_FORK` 0x4000_0000 (the
  watched process created a child; posted at spawn step 12),
  `NOTE_EXEC` 0x2000_0000 (the watched process ran a new image: execve,
  SETEXEC spawn, and also the first image of a just-spawned child, which
  nobody can be watching yet), `NOTE_SIGNAL` 0x0800_0000.
- On `NOTE_EXIT` (and unless `NOTE_REAP` was requested) `EV_EOF |
  EV_ONESHOT` are set.
- `data` on delivery: 0, except after `NOTE_EXIT` with `NOTE_EXITSTATUS`
  0x0400_0000 requested: `data` = status word (`p_xstat & 0xFFFFF`, the
  wait-style status). With `NOTE_EXIT_DETAIL` 0x0200_0000: OR of 0x10000
  decrypt failure, 0x20000 memory (jetsam; plus a reason bit in
  0xFE000000), 0x40000 code-signing kill. **Ycode:** never sets detail
  bits.
- `NOTE_EXIT` is delivered **even if the parent ignores SIGCHLD** (the
  child is then reaped at once, §2.4). launchd-class software relies on
  `NOTE_EXIT | NOTE_EXITSTATUS` for exit status in that case.
- `proc_pidinfo(pid, PROC_PIDNOTEEXIT, flags)` (§2.11) returns the same
  data synchronously, for the parent only, including for zombies.

### 2.9 Signals to other processes

**`kill(pid, sig, posix)` (BSD 37).** `sig` ≥ 32 → EINVAL. `sig` 0 only
checks.

| `pid` | Target |
|---|---|
| > 0 | that process. Not found → if a zombie with that pid exists, success; else ESRCH. Not permitted → EPERM |
| 0 | every member of the caller's process group (except pid 0/1, system processes, zombies) |
| −1 | every process except pid ≤ 1, system processes, and (when `posix` = 0) the caller; zombies count as found |
| < −1 | process group `−pid` (ESRCH if none) |

Group/broadcast result: 0 if at least one target was permitted, else EPERM
(`posix` ≠ 0, which the libc wrapper passes) or ESRCH (`posix` = 0).

**Permission (`cansignal`)**, in order: self → yes; pid 1 → **no** (even
for root); root → yes; SIGCONT within the same session → yes; otherwise
yes iff the sender's real or effective uid equals the target's real or
saved uid. **Ycode:** all guest processes share one uid, so everything
except pid 1 may be signalled.

**`terminate_with_payload(pid, namespace, code, payload, size, string,
flags)` (BSD 520).** pid ≤ 0 → EINVAL; not found → ESRCH; permission as
for SIGKILL (EPERM). Posts SIGKILL with an exit reason (namespace, code,
string). Ycode: deliver SIGKILL; keep the reason for
`PROC_PIDEXITREASON*INFO` (optional).

**`proc_terminate(pid, &sig)`** (proc_info call 7): the caller may not
terminate itself (EPERM). Sends SIGKILL if the target is dirty-tracked and
clean, otherwise SIGTERM, and returns the signal used.

Stopping: SIGSTOP/SIGTSTP stop a process (`SSTOP`), SIGCONT resumes it
(also a `START_SUSPENDED` child). A stop notifies the parent with SIGCHLD
unless the parent set `SA_NOCLDSTOP`.

### 2.10 Process groups and sessions

| Call | Semantics |
|---|---|
| `getppid` (39) | current parent pid (1 after reparenting) |
| `getpgrp` (81) | caller's process group id |
| `getpgid(pid)` | pid 0 = self; unknown → ESRCH |
| `getsid` (310) | session id (= pid of the session leader); pid 0 = self; unknown → ESRCH |
| `setsid` (147) | EPERM if the caller already leads a process group or a group with the caller's pid exists; else new session and new group, both = caller's pid; returns the pid |
| `setpgid(pid, pgid)` (82) | target = caller if pid 0 or own pid; otherwise the target must be a **child** of the caller (ESRCH), in the same session (EPERM), and must not have exec'd since it was created (EACCES). Target is a session leader → EPERM. pgid < 0 → EINVAL. pgid 0 → the target's pid. A pgid ≠ target pid must name an existing group in the caller's session (EPERM) |

Initial values: a spawned child is in its parent's group and session.
**Ycode:** at boot, `launchd_sim` is the leader of its own session and
group (the host starts it that way); daemons call `setsid` themselves
(`xpcproxy_sim` imports it).

### 2.11 `proc_info` (BSD 336) and libproc

Arguments: `x0` callnum, `x1` pid, `x2` flavor, `x3` arg (u64), `x4`
buffer, `x5` buffersize (i32). Result in `x0` on success (carry clear);
errno with carry on failure. `proc_info_extended_id` (545) adds `flags`
and `ext_id`: flag 0x1 (compare pid version) or 0x2 (compare unique id)
makes a mismatch return ESRCH.

Call numbers: 1 LISTPIDS, 2 PIDINFO, 3 PIDFDINFO, 4 KERNMSGBUF,
5 SETCONTROL, 6 PIDFILEPORTINFO, 7 TERMINATE, 8 DIRTYCONTROL, 9 PIDRUSAGE,
10 PIDORIGINATORINFO, 11 LISTCOALITIONS, 12 CANUSEFGHW,
13 PIDDYNKQUEUEINFO, 14 UDATA_INFO, 15 SET_DYLD_IMAGES, 16 TERMINATE_RSR,
17 SIGNAL_AUDITTOKEN, 18 TERMINATE_AUDITTOKEN, 19 DELEGATE_SIGNAL,
20 DELEGATE_TERMINATE. Others → EINVAL.

**LISTPIDS (1):** `pid` holds the type, `flavor` the type argument:
1 all, 2 pgrp, 3 tty, 4 uid, 5 ruid, 6 ppid (children; also traced
children whose original parent matches), 7 kdebug. Buffer NULL → returns
`(nprocs + 20) × 4` (a size hint). buffersize < 4 → ENOMEM. Otherwise
writes up to `min(buffersize/4, nprocs + 20)` pids (live first, then
zombies) and returns **bytes written**. libproc: `proc_listpids` returns
that byte count (0 on error); `proc_listallpids`, `proc_listpgrppids`,
`proc_listchildpids` return the **count** (bytes / 4).

**PIDINFO (2) flavors** (the buffer must be ≥ the size, else ENOMEM;
unknown flavor → EINVAL; result = bytes written):

| Flavor | Name | Size | Zombie allowed | Same-user check |
|---|---|---|---|---|
| 1 | LISTFDS | 8 per fd (`{i32 fd, u32 type}`) | no | yes |
| 2 | TASKALLINFO | 232 (bsdinfo + taskinfo) | no | yes |
| 3 | TBSDINFO | 136 | if `arg` ≠ 0 | yes |
| 4 | TASKINFO | 96 | no | yes |
| 5 | THREADINFO | 112 | no | yes |
| 6 | LISTTHREADS | 8 per thread | no | yes |
| 11 | PATHINFO | buffer (1024 ≤ size ≤ 4096, else ENOMEM/EOVERFLOW) | no | **no** |
| 13 | T_SHORTBSDINFO | 64 | if `arg` ≠ 0 | **no** |
| 15 | THREADID64INFO | 112 | no | yes |
| 17 | UNIQIDENTIFIERINFO | 56 | if `arg` ≠ 0 | **no** |
| 18 | T_BSDINFOWITHUNIQID | 192 | if `arg` ≠ 0 | yes |
| 19 | ARCHINFO | 8 (`{cputype, cpusubtype}`) | no | yes |
| 20 | COALITIONINFO | 40 | no | **no** |
| 21 | NOTEEXIT | 4 | yes (parent only, EACCES otherwise) | — |
| 24/25 | EXITREASONINFO / BASICINFO | | yes | |
| 30 | PLATFORMINFO | 4 | yes | **no** |

pid not found (or a zombie where not allowed) → ESRCH. "Same-user" denials
→ EPERM (Ycode: never denies, one uid). pid 0 is the kernel process: on a
real system it exists; **Ycode:** ESRCH for pid 0 except LISTPIDS
counting.

`struct proc_bsdinfo` (136): `pbi_flags` @0, `pbi_status` @4,
`pbi_xstatus` @8, `pbi_pid` @12, `pbi_ppid` @16, `pbi_uid` @20,
`pbi_gid` @24, `pbi_ruid` @28, `pbi_rgid` @32, `pbi_svuid` @36,
`pbi_svgid` @40, reserved @44, `pbi_comm[16]` @48, `pbi_name[32]` @64,
`pbi_nfiles` @96, `pbi_pgid` @100, `pbi_pjobc` @104, `e_tdev` @108
(0xFFFFFFFF = none), `e_tpgid` @112, `pbi_nice` @116, `pbi_start_tvsec`
(u64) @120, `pbi_start_tvusec` (u64) @128. `pbi_comm` byte 15 and
`pbi_name` byte 31 are forced to NUL.

`struct proc_bsdshortinfo` (64): `pid` @0, `ppid` @4, `pgid` @8,
`status` @12, `comm[16]` @16, `flags` @32, `uid` @36, `gid` @40,
`ruid` @44, `rgid` @48, `svuid` @52, `svgid` @56, reserved @60.

`struct proc_taskinfo` (96): u64 `virtual_size` @0, `resident_size` @8,
`total_user` @16, `total_system` @24, `threads_user` @32,
`threads_system` @40 (times in Mach absolute units); i32 `policy` @48,
`faults` @52, `pageins` @56, `cow_faults` @60, `messages_sent` @64,
`messages_received` @68, `syscalls_mach` @72, `syscalls_unix` @76, `csw`
@80, `threadnum` @84, `numrunning` @88, `priority` @92.

`struct proc_uniqidentifierinfo` (56): `uuid[16]` @0 (main executable's
LC_UUID), u64 `uniqueid` @16, u64 `puniqueid` @24 (parent's), i32
`idversion` @32 (pid version), i32 `orig_ppidversion` @36, reserved u64 ×2.
`T_BSDINFOWITHUNIQID` = bsdinfo (136) followed by this (56) = 192.

`pbi_flags` bits: 0x1 system, 0x2 traced, 0x4 in exit, 0x8 ppwait,
**0x10 LP64** (always set for arm64 guests), 0x20 session leader,
0x40 has controlling tty, 0x80 controlling terminal, 0x100 thread cwd,
0x600 pcontrol mask (0x200 throttle, 0x400 suspend, 0x600 kill),
0x800/0x1000 currently throttled/suspended, 0x2000 set-id since exec,
**0x4000 has exec'd** (set after the first image activation — true for
every spawned process), 0x8000/0x10000 darwin background, plus private
bits ≥ 0x20000. **Ycode:** report 0x10 | 0x4000, plus 0x20 for session
leaders.

**PATHINFO (11):** writes the executable's absolute path (NUL-terminated,
zero-padded to `buffersize`), result 0; libproc `proc_pidpath` returns
`strlen`. `proc_pidpath` itself returns ENOMEM-style 0 for a buffer
< 1024 and EOVERFLOW for > 4096. No executable → ESRCH. **Ycode:** the
guest path of the image (for rooted jobs, the host-style path as given).

**`proc_name(pid, buf, size)`** (library): size < 32 → errno ENOMEM,
returns 0; else TBSDINFO, copies `pbi_name` if nonempty else `pbi_comm`,
returns its length.

**PIDRUSAGE (9):** `flavor` = `RUSAGE_INFO_V0…V6`; the struct is written
to the buffer (no size check by the kernel; V4 296 bytes, V5 304, V6
464). Zombies allowed. **Ycode:** zero-filled except `ri_proc_start_abstime`
and, for zombies, `ri_proc_exit_abstime`; or ENOTSUP until needed.

**DIRTYCONTROL (8)** (`flavor`: 1 TRACK, 2 SET, 3 GET, 4 CLEAR; `arg` =
flags): TRACK allowed for self, the parent, or root (EPERM); SET/CLEAR
need SIGKILL permission; GET returns the state bits in `x0` (0x1 tracked,
0x2 allows idle exit, 0x4 is dirty, 0x8 launch in progress) and works on
zombies. Track flags in: 0x1 track, 0x2 allow idle exit, 0x4 defer,
0x8 launch in progress, 0x10 defer always, 0x20 shutdown on clean.
libproc `proc_get_dirty` returns 0 and stores the bits; `proc_set_dirty`,
`proc_track_dirty`, `proc_clear_dirty` return 0 or the errno. **Ycode:**
keep the per-process bits exactly; `proc_terminate` uses them.

**TERMINATE (7):** §2.9. libproc `proc_terminate(pid, &sig)`.

---

## 3. Task and thread ports across processes

### 3.1 Per-task kernel ports

Each task owns these kernel-object ports (`mach-ipc.md` §1.6):

| Port | Created | Notes |
|---|---|---|
| task control (`TASK_FLAVOR_CONTROL`) | at task creation | `mach_task_self()` names it. For **simulated** processes xnu leaves it movable (no immovable/pinned hardening) |
| task name | at task creation | Only identifies the task (`pid_for_task`, `task_info` subset) |
| task read / inspect | lazily | Reduced-rights flavors |
| thread control, per thread | at thread creation | |

The kernel resolves an incoming request by the port's kernel object, so
any task holding a send right to another task's control port can operate on
that task (§4.3). On exit the ports stop working (§2.4 step 2); they become
dead names in other spaces no later than when the zombie is reaped.
**Ycode:** destroy them at exit (step 2).

### 3.2 Special ports

Numbers (`task_special_port_t`): 1 KERNEL (= control), 2 HOST, 3 NAME,
4 BOOTSTRAP, 5 INSPECT, 6 READ, 9 ACCESS (task-access server for
`task_for_pid`), 10 DEBUG_CONTROL, 11 RESOURCE_NOTIFY. The set of stored
ports per task: host, bootstrap, access, debug-control, resource-notify,
3 registered ports, and 14 exception-port slots.

**`task_get_special_port(task, which, &port)`** returns a **new send
right** (copy):

| which | Returns |
|---|---|
| 1 | the task's control port |
| 3 | the task's name port |
| 5, 6 | the inspect / read port |
| 2 | the stored host port |
| 4 | the stored bootstrap port |
| 9, 10, 11 | the stored access / debug-control / resource-notify port |
| other | `KERN_INVALID_ARGUMENT` |

A slot that holds nothing returns `MACH_PORT_NULL` with `KERN_SUCCESS`; a
stored port that died returns `MACH_PORT_DEAD`. A dead task →
`KERN_FAILURE`.

**`task_set_special_port(task, which, port)`**: the caller's right is
copied in as **COPY_SEND** (the caller keeps it); on success the task's
slot takes the new right and the old one is released.

| which | Result |
|---|---|
| 1, 2 | `KERN_NO_ACCESS` (allowed only with SIP disabled) |
| 4, 10, 11 | replace |
| 9 | set once; if a valid port is already stored → `KERN_NO_ACCESS` |
| 3, 5, 6, other | `KERN_INVALID_ARGUMENT` |
| immovable send right offered | `KERN_INVALID_RIGHT` |

**Ycode change from `host-libraries.md` §10:** private traps n = 5 and 6
must act on **the task named by the `task` argument** (any task control
port the caller holds, normally its own), keep the slots per task, and
follow the tables above. The fixed bootstrap name `0x0503` stays the name
under which the VMM installs the **inherited bootstrap send right** in a
new task (§3.3), not a separate object.

### 3.3 Inheritance and override

At task creation (spawn: parent = the caller's task; exec/SETEXEC: parent
= the old task of the same process):

1. host, bootstrap, and access ports: send-right copies of the parent's.
2. The three registered ports: copies of the parent's.
3. Exception ports (types 1–13): copies of the parent's (port, behavior,
   flavor).
4. debug-control and resource-notify: **not** inherited (start null).
5. Then spawn **port actions** override (§1.8): SPECIAL actions replace
   individual slots (e.g. `TASK_BOOTSTRAP_PORT`), EXCEPTION actions set
   exception slots, REGISTERED_PORTS replaces all three registered slots.
6. A set-id exec drops non-privileged exception ports and the
   debug-control port and makes new task ports.

**Ycode (normative):** when a task's address space is created, the VMM
installs in its new space a send right for each nonnull inherited host and
bootstrap slot (bootstrap under name `0x0503`, `stage4a-contract.md` §6),
so that `task_get_special_port(…, 4, …)` and the `bootstrap_port` global
see the same name. The roots of the tree: the VMM's own bootstrap object
is the bootstrap special port of `launchd_sim` (`launchd-sim.md` §2.4,
§7.1 item 3); `launchd_sim` replaces it for its children with port actions
(`launchd-sim.md` §4.4).

### 3.4 Registered ports (`mach_ports_register` / `mach_ports_lookup`)

- Three slots per task (`TASK_PORT_REGISTER_MAX` = 3).
- `mach_ports_register(task, array, count)`: count > 3 →
  `KERN_INVALID_ARGUMENT`. The library pads the array to three with NULL
  and calls the kernel with three ports (each copied in as COPY_SEND). All
  three slots are replaced; old rights released. An immovable right →
  `KERN_INVALID_RIGHT`. A dead task → `KERN_INVALID_ARGUMENT`.
- `mach_ports_lookup(task, &array, &count)`: the library allocates one
  page-rounded region of 3 × 4 bytes with `vm_allocate` in the **target**
  task (normally self), the kernel returns a new send right (copy) for each
  slot (NULL stays 0, a dead port gives `MACH_PORT_DEAD`), `count` = 3. On
  failure the region is freed.
- Children inherit the slots (§3.3); the port action REGISTERED_PORTS
  replaces them for the new task.
- This answers `launchd-sim.md` open question 5 in part: the send right in
  slot 0 of every guest process is whatever `launchd_sim`/`xpcproxy_sim`
  passed with `set_registered_ports_np`.
- **Ycode:** expose as two private traps (register3, lookup3) with the
  three-port form; the library does the padding and the allocation.

### 3.5 Task ports by pid

| Call | Rules (xnu) | Result on failure |
|---|---|---|
| `task_for_pid(target_tport, pid, &t)` (−45) | `target_tport` must name a task port of the caller (else `KERN_FAILURE`). pid 0 → `KERN_FAILURE`. Not found or zombie → `KERN_FAILURE`. Allowed if: self; or root; or (target's ruid, euid, svuid all equal the caller's euid, target's groups ⊆ caller's, and target not set-id) **and** the MAC policy (AMFI: debugger entitlements / get-task-allow) agrees, **and** the target's task-access server (special port 9, if set and caller not root) approves. Before the child's IPC is active → `KERN_FAILURE` | `*t` = 0; `KERN_FAILURE` (or `KERN_PROTECTION_FAILURE` if the access port is dead) |
| `task_name_for_pid(target_tport, pid, &t)` (−44) | Allowed if not a zombie and (self, or root, or same euid **and** same ruid, or entitlement `com.apple.system-task-ports.name.safe`) | `*t` = 0; `KERN_FAILURE` |
| `task_read_for_pid` (539), `task_inspect_for_pid` (538) | BSD calls returning the read/inspect flavors with similar checks | errno-style |
| `pid_for_task(t, &pid)` (−46) | Accepts any task flavor (control, read, inspect, name). A corpse gives its pid | `*pid` = −1 (always written); `KERN_FAILURE` |

`task_for_pid` and `task_name_for_pid` return a **send right** copied out
into the caller's space (merging with an existing entry for that port).

**Ycode (normative):** `task_name_for_pid` and `pid_for_task` follow the
rules above (all guest processes match on uid). `task_for_pid` on another
process returns `KERN_FAILURE` by default (the simulator's daemons are not
debuggable by each other on the Mac); a VMM debug option may allow it.
Self always succeeds. See open question 2.

### 3.6 Thread ports of other tasks

`task_threads(task)` on another task's control port returns send rights to
its thread ports. Only diagnostic tools (`sample`, `heap`, …) use this; no
boot-path component does. **Ycode:** support for self; `KERN_FAILURE` for
other tasks until needed.

---

## 4. Mach IPC between tasks (deltas from `mach-ipc.md`)

`mach-ipc.md` is written for one space; all of its rules hold per space.
This section lists what is new with several tasks.

### 4.1 Spaces and ports

1. **Ports are global objects; names are per task.** Each task has its own
   name table with its own allocator (`mach-ipc.md` §1.4: Ycode's
   deterministic sequential allocation, per task). The same port usually
   has different names in different tasks.
2. Entry rule §1.2.1 (one name per port per space for send/receive rights)
   applies per space: when a right arrives in a space that already names
   the port (send or receive), it merges under the existing name.
3. A port's "receiver" is (space, name), in transit, or dead. `srights`,
   `mscount`, `sorights`, queue, seqno, requests, and context belong to the
   port, not to a space, and are shared by all tasks.
4. **Ycode design note:** all guest processes' spaces, ports, and process
   records must live in one kernel-state object shared by the VMs (one
   lock, as in `stage4a-contract.md` §2, now global), or in a broker that
   owns them. Message transfer between processes is then a move of kernel
   objects; only OOL memory needs copying between guest address spaces
   (§4.4).

### 4.2 Right transfer

- A message's rights are copied in from the **sender's** space at send time
  and copied out into the **receiver's** space at receive time
  (`mach-ipc.md` §2.4, §2.5). Between those points they are owned by the
  message ("in transit").
- `MOVE_RECEIVE` hands a receive right to whichever task receives the
  message. While in transit the port's queue keeps accepting messages
  (`MACH_SEND_*` behavior unchanged); queued messages travel with it. On
  copyout the port's receiver becomes (receiver's space, new name); a guard
  and context are cleared unless the port is immovable.
- **Circularity:** sending a receive right inside a message whose
  destination is that port, or a port whose receive right is (directly or
  through other in-transit receive rights) inside that port's queue, makes
  the message unreachable. xnu destroys such a message and the send
  succeeds (already normative in `mach-ipc.md` addendum, "Port
  destruction").
- If a receive right is in transit when its message is destroyed (e.g.
  the destination dies), the port is destroyed (or diverted by a
  port-destroyed request).
- `msgh_local_port` on receipt is the receiver's name for the destination
  port (`mach-ipc.md` §2.5); since only the receive-right holder can
  receive, it is always valid.
- **Send-once rights** as reply ports work across tasks unchanged: the
  replying task receives a send-once name that it consumes when it sends
  the reply.

### 4.3 Operations on another task's space

MIG routines on `mach_port_*` take a `task` argument. When that names
another task's control port, the routine operates on **that** task's
space (`mach_port_insert_right`, `extract_right`, `allocate`,
`deallocate`, `mod_refs`, `request_notification`, …). Copy-ins of the
`poly` argument (insert_right) still come from the caller's own space;
`extract_right` results are copied out into the caller.

**Ycode (normative):** the real port traps (`mach-ipc.md` §1.8) keep
returning `MACH_SEND_INVALID_DEST` when `target` is not the caller's own
task (Apple's library falls back to MIG; Ycode's library must then call a
private trap with the target). The VMM resolves `target` as a task control
port held by the caller; a name port, a dead task, or a non-task right →
`KERN_INVALID_TASK` (16) / `MACH_SEND_INVALID_DEST`. Which of these
routines the boot path uses on other tasks is open question 4.

### 4.4 Out-of-line memory between tasks

- The receiver must see a **snapshot taken at send time**; later writes by
  the sender are invisible, and the receiver's writes are invisible to the
  sender. `copy` = `MACH_MSG_PHYSICAL_COPY` (0) or `VIRTUAL_COPY` (1) both
  give this result; the kernel may copy eagerly (small regions, or
  physical copy without deallocate: the data is captured before the send
  call returns) or copy-on-write.
- `deallocate` = 1 removes **every page overlapping** `[address, address +
  size)` from the sender as part of the send.
- On receipt the data appears at a new address chosen in the receiver.
  The region occupies whole pages; the returned address may keep the
  source's offset within its page. The received descriptor's
  `deallocate` = 1 for VIRTUAL_COPY, else 0. The receiver frees the region
  with `vm_deallocate(address, size)` (whole pages).
- OOL **port** arrays: the names are copied in from the sender's space and
  out into the receiver's; the receiver gets a fresh `count × 4`-byte
  region (§2.5 of `mach-ipc.md`).
- **Ycode:** each process is its own KVM VM, so the VMM copies the bytes
  from the sender's guest memory into kernel-held buffers at send time
  (or snapshots host pages with copy-on-write mappings, for large
  regions), and maps fresh anonymous pages in the receiver at copyout. The
  4a in-process rule (copy into a fresh mapping) generalizes unchanged.

### 4.5 Trailers: sender identity

The trailer's sender fields come from the **sending task** at send time
(`mach-ipc.md` §2.6):

| Field | Value |
|---|---|
| `msgh_sender` (8) | `{euid, egid}` |
| `msgh_audit.val[0]` | audit user id (auid) |
| `val[1]`, `val[2]` | euid, egid |
| `val[3]`, `val[4]` | ruid, rgid |
| `val[5]` | **pid** |
| `val[6]` | audit session id |
| `val[7]` | **pid version** (changes at every exec, §1.11) |

The same eight words are returned by `task_info(TASK_AUDIT_TOKEN = 15)`,
by `LOCAL_PEERTOKEN` on Unix sockets (§5.6), and are what
`csops_audittoken`, `proc_pidpath_audittoken`, and libxpc's peer checks
compare. Kernel-originated messages carry `{0, 1}` and an all-zero token
(already in `mach-ipc.md`).

**Ycode (normative):** auid = the guest uid, asid = one fixed session id
per simulator instance (see open question 5 for the Mac's real values).
A message sent before an exec and received after it carries the **old**
pid version; consumers detect stale tokens that way.

### 4.6 Task termination (normative order, xnu)

When a task dies (§2.4 step 2):

1. Its kernel ports stop resolving to the task (MIG calls through them
   fail).
2. Its port space is destroyed: **first** every entry holding a receive
   right, in index order, then every other entry:
   - receive right → the port dies (`mach-ipc.md` §1.5) unless a
     port-destroyed request diverts it, in which case the receive right is
     sent in a port-destroyed notification (§3.4 there) and the port lives
     on in the notified task. Port death wakes blocked senders and
     receivers in **other** tasks, fires their dead-name requests, and
     turns their send/send-once rights into dead names lazily;
   - send rights → released. If that was the last send right to a port
     owned by another task with an armed no-senders request, the
     no-senders notification fires;
   - send-once rights → destroyed; each produces a **send-once
     notification** to its port (this is how a client that died before
     replying fails the server's reply wait gracefully, and how a dying
     server's pending replies reach clients as `MACH_NOTIFY_SEND_ONCE`);
   - a dead-name request armed on one of the dying task's entries is
     cancelled and its send-once right receives a **port-deleted**
     notification (`mach-ipc.md` §3.1). The notify port is usually in the
     dying task and already dead, so nothing arrives; if it is elsewhere,
     the notification is delivered;
   - port sets are destroyed.
3. Its special ports (host, bootstrap, access, registered, exception)
   are released — which can trigger no-senders on the bootstrap or
   registered ports held by `launchd_sim`.
4. Only then does BSD exit continue (NOTE_EXIT, SIGCHLD, §2.4 steps 3–7).
   So by the time `launchd_sim` sees a child's `NOTE_EXIT`, the child's
   ports are already dead and the related notifications are already
   queued.

Messages still queued on a destroyed port are destroyed with their
rights, recursively, as in `mach-ipc.md` §1.5.

### 4.7 IPC across exec

`execve` and `posix_spawn(SETEXEC)` give the process a **new task with an
empty space** (§1.11). The old task's space is terminated exactly as in
§4.6 (receive rights die, peers see dead names / send-once notifications),
except that the special/registered/exception ports carry over to the new
task. Therefore `xpcproxy_sim` must transfer every right the job needs via
port actions (`setspecialport_np`, `set_registered_ports_np`) or by having
the job look them up again through its bootstrap port. The new image's
`mach_task_self()` is a new port; holders of the old task port see a dead
name. **Ycode:** `task_for_pid`-style holders must not survive exec.

### 4.8 Exception ports (enough to ignore them safely)

- Types: 1 BAD_ACCESS, 2 BAD_INSTRUCTION, 3 ARITHMETIC, 4 EMULATION,
  5 SOFTWARE, 6 BREAKPOINT, 7 SYSCALL, 8 MACH_SYSCALL, 9 RPC_ALERT,
  10 CRASH, 11 RESOURCE, 12 GUARD, 13 CORPSE_NOTIFY. 14 slots including
  the unused 0. Masks are `1 << type`; valid mask = bits 1–13 (0x3FFE).
- Behaviors: 1 DEFAULT, 2 STATE, 3 STATE_IDENTITY, 4 IDENTITY_PROTECTED,
  5 STATE_IDENTITY_PROTECTED, optionally OR-ed with 0x8000_0000
  (`MACH_EXCEPTION_CODES`), 0x4000_0000 (errors), 0x2000_0000 (backtrace
  preferred).
- There are task, thread, and host levels; tasks inherit task-level slots
  (§3.3).
- **Ycode (normative):** store and return exception ports faithfully per
  task and thread (`task_set/get/swap_exception_ports`,
  `thread_set/get_exception_ports`; `host_get_exception_ports` returns
  none), validate masks (`KERN_INVALID_ARGUMENT` outside 0x3FFE) and
  behaviors, and hold the send rights (they keep ports alive and count for
  no-senders). **Never deliver** an exception message: guest faults become
  BSD signals directly (`threads-and-events.md` §5), fatal ones end the
  process with "killed by signal" status, and no EXC_CRASH /
  EXC_CORPSE_NOTIFY / EXC_RESOURCE / EXC_GUARD messages are sent. Code
  that waits for its own exceptions (open question 7) would then see a
  signal instead.

### 4.9 Fileports

A fileport is a kernel-object Mach port that holds a reference to an open
file description; libxpc uses it to send descriptors in Mach messages, and
`xpcproxy_sim` uses it in spawn file actions.

| Call | Semantics |
|---|---|
| `fileport_makeport(fd, &name)` (430) | fd must be open (EBADF) and sendable: vnode, socket, pipe, POSIX shm (kqueues and other confined files → EINVAL). Creates a **new** port every call, returns a send right name in the caller's space |
| `fileport_makefd(name)` (431) | name must hold a send right to a fileport (else EINVAL). Returns a **new fd with close-on-exec set**, sharing the file description (offset, flags) |
| spawn FILEPORT_DUP2 | §1.7 type 4; the resulting fd has close-on-exec clear |

The port lives while send rights exist (in any task or in transit); when
the last one goes, the file reference is dropped. **Ycode:** a VMM kernel
object kind `fileport` holding a host file-description reference.

---

## 5. AF_UNIX sockets and descriptor passing

### 5.1 Darwin ABI facts (they differ from Linux)

| Item | Darwin (guest) | Note for a Linux host |
|---|---|---|
| `struct sockaddr_un` | `u8 sun_len` @0, `u8 sun_family` @1 (= 1 `AF_UNIX`), `char sun_path[104]` @2; size 106 | Linux: `u16 family`, `path[108]` |
| `struct msghdr` (48) | `msg_name` @0 (8), `msg_namelen` u32 @8, `msg_iov` @16, `msg_iovlen` **i32** @24, `msg_control` @32, `msg_controllen` **u32** @40, `msg_flags` i32 @44 | Linux uses `size_t` for iovlen/controllen |
| `struct cmsghdr` (12) | `cmsg_len` u32 @0, `cmsg_level` i32 @4, `cmsg_type` i32 @8; data at +12; alignment **4** (`CMSG_LEN(4)` = `CMSG_SPACE(4)` = 16, `CMSG_SPACE(8)` = 20) | Linux: 16-byte header, 8-byte alignment |
| `SOL_SOCKET` | 0xFFFF | Linux 1 |
| `SCM_RIGHTS` / `SCM_CREDS` / `SCM_TIMESTAMP` | 1 / 3 / 2 | |
| `SOL_LOCAL` (level for `LOCAL_*`) | 0 | |
| `LOCAL_PEERCRED`/`PEERPID`/`PEEREPID`/`PEERUUID`/`PEEREUUID`/`PEERTOKEN` | 1 / 2 / 3 / 4 / 5 / 6 | Linux: `SO_PEERCRED` |
| socket types | STREAM 1, DGRAM 2, SEQPACKET 5 | |
| `MSG_*` | PEEK 0x2, EOR 0x8, TRUNC 0x10, CTRUNC 0x20, WAITALL 0x40, DONTWAIT 0x80, NOSIGNAL 0x80000 | different bit values on Linux |
| `SO_*` | REUSEADDR 0x4, KEEPALIVE 0x8, LINGER 0x80, SNDBUF 0x1001, RCVBUF 0x1002, ERROR 0x1007, TYPE 0x1008, NREAD 0x1020, NOSIGPIPE 0x1022, NWRITE 0x1024 | |
| `SOMAXCONN` | 128 | |
| `struct xucred` (`LOCAL_PEERCRED`) | 76 bytes: `u32 cr_version` (0) @0, `uid cr_uid` @4, `i16 cr_ngroups` @8, `gid cr_groups[16]` @12 | |

**Ycode:** translate every one of these at the trap boundary; never pass a
guest `msghdr`/`cmsghdr`/`sockaddr_un` to Linux unchanged.

### 5.2 `socket` (97) and `socketpair` (135)

- `socket(AF_UNIX, type, 0)` for STREAM and DGRAM. The new fd has
  close-on-exec clear.
- `socketpair(AF_UNIX, type, 0, int sv[2])` creates two connected
  sockets; both ends get peer credentials (`LOCAL_PEERCRED`) of the
  creator. Returns 0 and writes `sv`.
- A socket is a descriptor like any other: inherited across spawn/exec
  unless close-on-exec (§1.11), passable with SCM_RIGHTS (§5.5) and
  fileports (§4.9).

### 5.3 Naming and connection

The kernel sets `sun_len` from the `namelen` argument (the user's
`sun_len` byte is overwritten). The path is the bytes after the 2-byte
header up to `namelen`, cut at the first NUL. Path length ≤ 0 or ≥ 255 →
EINVAL. A family other than 0 or `AF_UNIX` → EAFNOSUPPORT.

| Call | Semantics |
|---|---|
| `bind` (104) | Already bound or fully shut down → EINVAL. Creates a socket file at the path with mode `0777 & ~umask`; an existing file → **EADDRINUSE** (no reuse; callers `unlink` first). Missing directory, permissions → the lookup error. The file stays after close |
| `listen` (106) | Unbound socket → EINVAL. backlog ≤ 0 or > 128 → 128. Connections are refused once more than `3 × backlog / 2` are pending |
| `connect` (98) | Path lookup errors (ENOENT, EACCES…); not a socket file → ECONNREFUSED; type mismatch → EPROTOTYPE; STREAM: no listener, or backlog full → **ECONNREFUSED immediately** (Darwin never blocks or returns EAGAIN here); already connected → EISCONN. On success both sides record peer credentials (the connector's on the new server socket, the listener's on the client) |
| `accept` (30) | Blocks for a pending connection (EAGAIN if non-blocking). The returned address is the peer's bound address or, if unbound, a 16-byte `sockaddr` with `sa_len` 16, family 1, zero data |
| `getsockname` / `getpeername` | Bound address, or the 16-byte unnamed form |
| DGRAM `connect` | Sets the default destination; may connect a socket to itself |

### 5.4 Data transfer

- STREAM: byte stream. Default buffers: 8192 send / 8192 receive
  (`net.local.stream.*space`). Writing after the peer closed → **EPIPE and
  SIGPIPE** to the writing thread, unless `SO_NOSIGPIPE` is set on the
  socket or `MSG_NOSIGNAL` is passed. Reading after the peer closed → 0
  (EOF).
- DGRAM: record boundaries kept. Default maximum datagram **2048 bytes**
  (`net.local.dgram.maxdgram`; larger → EMSGSIZE), receive buffer 4096.
  `sendto` with an address on a connected socket → EISCONN; without one on
  an unconnected socket → ENOTCONN. The receiver's `from` address is the
  sender's bound address or the unnamed form.
- `MSG_OOB` → EOPNOTSUPP. `shutdown` as usual.
- `recvmsg` sets `MSG_TRUNC` when a datagram was cut and `MSG_CTRUNC` when
  control data did not fit.

### 5.5 `SCM_RIGHTS`

Send side (`sendmsg` with `msg_control`):

1. The control buffer must hold **exactly one** `SOL_SOCKET`/`SCM_RIGHTS`
   message whose `cmsg_len` equals `msg_controllen`; otherwise EINVAL.
2. Each fd must be open (EBADF) and sendable (vnode, socket, pipe, POSIX
   shm; kqueues and other confined files → EINVAL). A guarded fd fails.
3. The file descriptions are captured at send time (closing the fds after
   `sendmsg` returns does not affect the message). Up to 512 descriptors
   per message are accepted.

Receive side (first `recvmsg` that takes the data the rights were sent
with; not with `MSG_PEEK`, which returns the cmsg with zeroed fd slots):

1. All the descriptors are installed in the receiver's table **before**
   the control data is copied out, as new fds with close-on-exec clear
   (lowest free numbers). If the table cannot take them all, none are
   installed, they are discarded, and `recvmsg` fails with EMSGSIZE.
2. The cmsg is then copied out with the new fd numbers. If `msg_control`
   is too short, the copy is truncated and `MSG_CTRUNC` is set — **the
   installed descriptors that did not fit stay open** in the receiver
   (xnu does not close them). If `msg_control` is NULL, the descriptors are
   still installed and silently stay open.
3. Discarded or never-received rights (socket closed with the message
   queued) drop their file references; a garbage collector resolves
   cycles of sockets passed inside each other.

**Ycode:** reproduce rules 1–2 exactly for the normal case; for the
truncation/NULL cases, closing the excess descriptors instead is
acceptable (it only changes fd-number consumption) — record the choice in
the implementation.

### 5.6 Peer identity options (`getsockopt`, level `SOL_LOCAL` = 0)

| Option | Value | Errors |
|---|---|---|
| `LOCAL_PEERCRED` (1) | `struct xucred` of the peer as recorded at connect/socketpair time | not yet recorded: ENOTCONN (STREAM) / EINVAL (DGRAM) |
| `LOCAL_PEERPID` (2) | pid (i32) of the **last process that used** the peer socket | not connected: ENOTCONN |
| `LOCAL_PEEREPID` (3) | as above, or the delegated pid | ENOTCONN |
| `LOCAL_PEERUUID` (4) / `LOCAL_PEEREUUID` (5) | 16-byte executable UUID of that process | ENOTCONN |
| `LOCAL_PEERTOKEN` (6) | the 32-byte audit token (§4.5) of the process in `LOCAL_PEERPID` | not connected ENOTCONN; that process gone → EINVAL |
| any other `SOL_LOCAL` option, or any set | EOPNOTSUPP | |

"Last process that used" is updated by socket operations; for a socket
passed between processes it follows the latest user. **Ycode:** track the
pid of the last process that performed a send/receive/connect/accept on
each socket.

### 5.7 What launchd-class software does with sockets

From `launchd-sim.md` §5.4 and the surface data: `launchd_sim` creates
listening STREAM sockets at known paths (the syslog socket, the secure
sockets) and gives the **listening descriptor** to the job, so the job
`accept`s; descriptors reach the job through spawn inheritance (the
descriptor is left open across `xpcproxy_sim`'s exec, typically via
`addinherit_np` with `CLOEXEC_DEFAULT`) or via fileports in XPC messages.
Clients `connect` to the path; host tools connect from outside the guest.

### 5.8 Ycode implementation note (design, not observation)

Map guest AF_UNIX sockets onto real Linux AF_UNIX sockets owned by the VMM
host process, with guest paths translated through the guest VFS to host
paths (keeping each host path within Linux's 108-byte limit, e.g. by
binding in a short per-device host directory). Then:

- host tools can connect to the secure sockets directly;
- SCM_RIGHTS between guest processes becomes Linux SCM_RIGHTS of the
  underlying host fds (the VMM receives new host fds and installs them in
  the receiving guest's table), which also works between guest processes
  hosted by different VMM host processes;
- Darwin-only behavior must be emulated on top: EADDRINUSE without
  reuse, immediate ECONNREFUSED on a full backlog (Linux blocks), the
  2048-byte datagram limit, `SO_NOSIGPIPE`, `LOCAL_PEER*` (from Linux
  `SO_PEERCRED` plus the VMM's own pid table, since Linux reports host
  pids), and the cmsg/msghdr layouts.

---

## 6. Implementation checklist for Ycode

Ordered by what `launchd_sim` and `xpcproxy_sim` need first.

1. **Global kernel state** (§4.1.4): process table (pid, ppid, pgid, sid,
   state, status, pid version, unique id, comm/name, path, uid set,
   dirty bits, pcontrol, process type), per-task port spaces sharing one
   port object table, one lock.
2. **pid allocation** (§2.1) with the pid-1 pseudo-init.
3. **`posix_spawn` (BSD 244), spawn mode:** parse §1.2–§1.8; new VM, new
   task, copied fd table, cwd, signal state (§1.11), argv/envp/apple
   (§1.12); file actions OPEN/CLOSE/DUP2/INHERIT/FILEPORT_DUP2/CHDIR/
   FCHDIR; `CLOEXEC_DEFAULT`; flags SETSIGMASK, SETSIGDEF, SETPGROUP,
   SETSID, START_SUSPENDED, NANO_ALLOCATOR; binpref selection; return the
   pid; errors (§1.13). Library side: all setters of §1.14 that the
   surface lists with importers.
4. **Special and registered ports per task** (§3.2–§3.4): inheritance at
   task creation, port actions SPECIAL and REGISTERED_PORTS (COPY_SEND from
   the caller), private traps n = 5/6 made per-task, register3/lookup3.
5. **Cross-task `mach_msg`** (§4.1–§4.5): per-space copyin/copyout,
   receive rights moving between tasks, OOL copy between VMs, audit
   token per sender.
6. **`posix_spawn` SETEXEC and `execve`** (§1.3, §1.11, §4.7): same pid,
   new task and empty space, carried special/registered/exception ports,
   pid version bump, `NOTE_EXEC`, kept watchers and pending signals.
7. **Exit path** (§2.4, §4.6): Mach teardown order, fd close, reparent to
   pid 1, `NOTE_EXIT` with status, zombie or immediate reap
   (`SA_NOCLDWAIT`/SIG_IGN), SIGCHLD.
8. **`EVFILT_PROC`** (§2.8): NOTE_EXIT/EXITSTATUS/FORK/EXEC, EV_EOF|ONESHOT.
9. **`wait4`/`waitid`** (§2.6, §2.7).
10. **`kill`/`terminate_with_payload`/`proc_terminate`**, stop/continue
    (§2.9); `getppid`/`getpgrp`/`setsid`/`setpgid`/`getsid` (§2.10).
11. **`proc_info`** (§2.11): LISTPIDS (all, ppid → `proc_listchildpids`),
    PIDINFO 3/4/11/13/17/18/21, DIRTYCONTROL, TERMINATE, PIDRUSAGE.
12. **AF_UNIX** (§5): socket/bind/listen/accept/connect, socketpair,
    sendmsg/recvmsg with SCM_RIGHTS, `SO_NOSIGPIPE`, `LOCAL_PEERPID`/
    `PEERCRED`/`PEERTOKEN`; listening fds inherited across spawn and exec.
13. **Fileports** (§4.9) and spawn FILEPORT_DUP2.
14. **`task_name_for_pid`, `pid_for_task`**; `task_for_pid` self-only
    (§3.5).
15. **Exception ports** stored, never delivered (§4.8); spawn EXCEPTION
    port actions applied late.
16. Accept-and-ignore: coalitions, persona, MAC extensions, jetsam fields
    (stored for `memorystatus_control`), CPU monitor, QoS clamp, role,
    watch ports, limits, sec flags, conclave.
17. Later: `waitid` WNOWAIT/WCONTINUED paths, `task_threads` on other
    tasks, `PROC_PIDLISTFDS`, `PROC_PIDTASKINFO` real counters, rusage
    contents, `task_for_pid` debug option.

Probes to add under `research/experiments/simulator/stage4-probes/` (our
own code): spawn + `wait4` status round trip; spawn with
`setspecialport_np(TASK_BOOTSTRAP_PORT)` and the child reading it back;
receive-right handoff parent → child and child death → dead-name
notification in the parent; `EVFILT_PROC` NOTE_EXIT|NOTE_EXITSTATUS with
SIGCHLD ignored; SETEXEC chain (parent → proxy → program) keeping the pid;
AF_UNIX listen in parent, connect in child, SCM_RIGHTS of a pipe.

---

## 7. Open questions

1. **Audit-token values on the Mac.** auid and audit session id (`val[0]`,
   `val[6]`) of simulator processes under CoreSimulator. Test (level 3): a
   probe spawned with `simctl spawn` prints `task_info(TASK_AUDIT_TOKEN)`
   and `getaudit_addr`.
2. **`task_for_pid` between simulator processes.** Does it succeed on the
   Mac for same-user simulator daemons (AMFI on simulator binaries)? Test
   with a probe against `launchd_sim`'s child; until then Ycode returns
   `KERN_FAILURE` for others.
3. **Subsystem root path.** `xpcproxy_sim` imports
   `posix_spawnattr_set_subsystem_root_path_np`. Whether the job then sees
   `subsystem_root_path=` in `apple[]` depends on an entitlement the
   simulator's proxy may not have. Test: dump `apple[]` of a simulator
   daemon (level 3). Default: ignore the attribute.
4. **Which `mach_port_*` routines `launchd_sim` applies to other tasks**
   (§4.3), e.g. inserting rights into a child's space. Needs a trace of
   private-trap targets under Ycode.
5. **pid and session of `launchd_sim`, and pid-1 behavior.** On the Mac,
   orphans of the simulator go to the host's launchd. Confirm no guest
   component calls `getppid()` expecting a specific value, or signals
   pid 1.
6. **`posix_spawnattr_set_use_sanitizers_np`** is imported by the runtime
   (`libsystem_sim_kernel_host`) but is not in xnu-12377.121.6's
   `posix_spawn.c`. Ycode: return 0 and store nothing until its effect is
   specified from a newer source.
7. **Mach exception delivery.** Whether any boot-path component (e.g. a
   JIT or crash-reporting helper) depends on receiving exception messages
   instead of signals (§4.8).
8. **OOL in-page offset.** Whether any simulator code depends on the
   received OOL address keeping the sender's in-page offset (§4.4). Ycode
   may page-align; a probe can show what the Mac does for small vs. large
   regions.
9. **Stream SCM_RIGHTS boundaries.** Exactly which `recvmsg` call on a
   STREAM socket delivers rights attached to data that the receiver reads
   in pieces, and whether data after a rights-carrying record is merged
   into the same read. Test with a probe on the Mac (level 3).
10. **`NOTE_EXIT` vs. zombie ordering** (§2.4 Ycode note) — confirm no
    component expects `wait4(WNOHANG)` to return 0 right after `NOTE_EXIT`.

---

## Evidence

All source claims are level 1 (Apple open source). Tag
**`xnu-12377.121.6`**, commit `ac9718fb1af618d5ce8678d0dc6e8a58f252216f`,
fetched with the GitHub API from `apple-oss-distributions/xnu` on
2026-10-12 into a scratch directory outside the repository. Struct offsets
were computed by compiling our own `offsetof` probe against those headers
(spawn structures) and against the public macOS SDK headers (`proc_info`,
socket, `siginfo`, `msghdr`, `cmsghdr`, `xucred`) for arm64. No Xcode,
simulator-runtime binary, `research/dirty/`, or Ghidra project was opened;
level 5 was not used.

| Claim | Level | Source |
|---|---|---|
| Descriptor, attribute, file-action, port-action, MAC, coalition, persona, cred layouts; enum values; jetsam, process-type, clamp, option, sec-flag constants | 1 | `bsd/sys/spawn_internal.h`, `bsd/sys/spawn.h`, `osfmk/mach/coalition.h`, `osfmk/mach/mach_param.h` |
| Library defaults, setter validation, descriptor filling, return convention | 1 | `libsyscall/wrappers/spawn/posix_spawn.c`, `spawn_private.h`, `spawn.h` |
| Kernel copy-in limits, order of operations, flags, file actions, port actions, CLOEXEC_DEFAULT marking, failure reaping, NOTE_FORK/NOTE_EXEC, binpref grading, START_SUSPENDED, set-id port reset, pid version on exec, `set_proc_name`, argv/envp extraction, entitlement names | 1 | `bsd/kern/kern_exec.c` (`posix_spawn`, `exec_handle_file_actions`, `exec_handle_port_actions`, `exec_handle_exception_port_actions`, `exec_handle_spawnattr_policy`, `spawn_posix_cred_adopt`, `exec_fat_imgact`, `exec_mach_imgact`, `exec_handle_sugid`, `proc_exec_switch_task`, `exec_extract_strings`, `set_proc_name`) |
| fd inheritance at fork/exec, close-on-exec, confined files, fileports, `fg_sendable` | 1 | `bsd/kern/kern_descrip.c` (`fdt_fork`, `fdt_exec`, `sys_fileport_makeport`, `fileport_makefd`, `sys_fileport_makefd`) |
| pid allocation, pid version, unique id, inherited proc flags, child signal mask | 1 | `bsd/kern/kern_fork.c`, `bsd/sys/proc_internal.h` (`PID_MAX`, `NO_PID`) |
| Exit order, reparenting, NOCLDWAIT, zombie, SIGCHLD, NOTE_EXIT hint, wait4, waitid, exit status encoding | 1 | `bsd/kern/kern_exit.c` (`exit`, `exit_with_reason`, `proc_exit`, `wait4_nocancel`, `waitid_nocancel`), `bsd/sys/wait.h`, `bsd/sys/signal.h` |
| Signal reset at exec, workqueue/thread masks, kill, killpg, cansignal, terminate_with_payload, SIGCHLD flags | 1 | `bsd/kern/kern_sig.c` (`execsigs`, `kill`, `killpg1`, `cansignal_nomac`, `terminate_with_payload_internal`, `setsigvec`), `bsd/sys/signal.h` |
| EVFILT_PROC | 1 | `bsd/kern/kern_event.c` (`filt_procattach`, `filt_procevent`, `filt_procprocess`), `bsd/sys/event.h`, `bsd/sys/event_private.h` |
| getppid, getpgrp, getpgid, getsid, setsid, setpgid, audit-token assembly | 1 | `bsd/kern/kern_prot.c` |
| proc_info calls, flavors, sizes, zombie and permission rules, bsdinfo fields, listpids, pathinfo, dirtycontrol, terminate, rusage, noteexit | 1 | `bsd/kern/proc_info.c`, `bsd/sys/proc_info.h`, `bsd/sys/proc_info_private.h`, `bsd/sys/proc.h`, `libsyscall/wrappers/libproc/libproc.c` |
| task_for_pid, task_name_for_pid, pid_for_task | 1 | `bsd/kern/kern_proc.c` |
| Task IPC init/inheritance, enable/disable/terminate, special port get/set, registered ports, control-port defaults for simulated tasks | 1 | `osfmk/kern/ipc_tt.c` (`ipc_task_init`, `ipc_task_enable`, `ipc_task_disable`, `ipc_task_terminate`, `ipc_task_reset`, `task_get_special_port_internal`, `task_set_special_port*`, `_kernelrpc_mach_ports_register3`, `_kernelrpc_mach_ports_lookup3`), `osfmk/kern/task.c` (`task_set_ctrl_port_default`, `task_create_internal`, termination order), `osfmk/mach/task_special_ports.h`, `libsyscall/mach/task.c` |
| COPY_SEND semantics of spawn/fileport port copy-in | 1 | `osfmk/kern/ipc_kobject.c` (`ipc_typed_port_copyin_send`) |
| Space termination order, per-entry teardown (no-senders, port-deleted on cancelled requests) | 1 | `osfmk/ipc/ipc_space.c` (`ipc_space_terminate`), `osfmk/ipc/ipc_right.c` (`ipc_right_terminate`) |
| OOL copy semantics, sender tokens in trailers | 1 | `osfmk/ipc/ipc_kmsg.c` |
| Exception types, behaviors, masks, slot count | 1 | `osfmk/mach/exception_types.h`, `osfmk/mach/arm/exception.h` |
| AF_UNIX bind/connect/listen/accept/peer options/buffers, SCM_RIGHTS internalize/externalize, control truncation, backlog | 1 | `bsd/kern/uipc_usrreq.c`, `bsd/kern/uipc_socket.c` (`solisten`, `soreceive_ctl`), `bsd/kern/uipc_socket2.c` (`sonewconn`), `bsd/kern/uipc_syscalls.c` (control copyout), `bsd/sys/un.h`, `bsd/sys/socket.h` |
| Struct offsets for `proc_bsdinfo`, `proc_bsdshortinfo`, `proc_taskinfo`, `siginfo_t`, `msghdr`, `cmsghdr`, `sockaddr_un`, `xucred`; socket/MSG/SO constants; errno and kern_return values | 1 | public macOS SDK headers (`sys/proc_info.h`, `sys/socket.h`, `sys/un.h`, `sys/ucred.h`, `signal.h`, `errno.h`, `mach/kern_return.h`), measured with our own probe |
| Which spawn/libproc/socket functions simulator images import, and by whom | 4 | `specs/simulator/data/host-lib-surface-kernel.json` (existing repository data) |
| launchd_sim spawn model, domains, sockets | 3 | `specs/simulator/launchd-sim.md` |
| Ycode decisions (marked **Ycode**) | — | design, this document |
