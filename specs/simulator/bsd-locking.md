# Spec: BSD and VM traps off the global kernel lock

Status: **implemented, agent SP-L0, 2026-10-19.** Continues
`mach-ipc-locking.md` (which moved the Mach IPC, kevent and workqueue
traps off L0) for the BSD descriptor, path, ulock and VM traps that still
ran under L0. On by default; `YCODE_BSD_FAST=0` sends every trap of §4
back to L0 (§6's purgeable call follows `YCODE_TASK_LOCAL_TRAPS`).
Measurements: §10. Extended by agent KLOCK (2026-10-23/24): more traps,
the process table, directory cursors and file locks without L0 (§12–§15),
measurements §16, open items §17.

This is Ycode's own design for Ycode's own kernel personality. It names
no Apple internals. The semantics kept are those of the locked paths
(`stage6-contract.md` §5, `processes.md`, `threads-and-events.md` §4.1),
whose level-1 sources are POSIX and the xnu sources (`bsd/kern/kern_descrip.c`,
`bsd/vfs/vfs_syscalls.c`, `bsd/kern/sys_ulock.c`).

## 1. Problem: what still took L0 after the IPC split

Trap profile (`YCODE_TRAP_PROFILE`, main line aa1bf7c, one full boot to
the home screen, 62.7 s profiled, Thor load average below 1 at the start):
L0 45.3 % busy, 2.21 M acquisitions (0.76 per trap), 34.6 % contended,
1,016 s of summed waits (on average 16 threads waiting for L0 at any
moment). Every BSD trap waited about 310 µs for the lock, whatever its
own hold (1–10 µs for most).

| Trap | Count | L0 acquisitions | Summed wait | Mean hold |
|---|---|---|---|---|
| BSD 5 `open` (+ 398, 463 `openat`) | 305,251 | 610,506 | 260 s | 2.1–2.6 µs |
| BSD 202 `sysctl` | 183,254 | 183,254 | 86 s | 4.1 µs |
| BSD 3 `read`, 153 `pread` | 206,495 | 206,495 | 80 s | 5–7 µs |
| BSD 544/516 `ulock_wait2`/`ulock_wake` | 104,027 | 130,287 | 71 s | 4–6 µs |
| BSD 336 `proc_info` | 103,081 | 103,081 | 49 s | 3.5 µs |
| BSD 199 `lseek` | 101,368 | 101,368 | 44 s | 1.7 µs |
| BSD 6/399 `close` | 114,254 | 114,254 | 44 s | 6–9 µs |
| BSD 92 `fcntl` | 74,003 | 74,003 | 32 s | 6.6 µs |
| BSD 33 `access`, 470 `fstatat64` | 39,476 | 78,954 | 29 s | 3–4 µs |
| BSD 339 `fstat64` | 42,783 | 42,783 | 16 s | 7.9 µs |
| BSD 197 `mmap` | 21,185 | 25,629 | 16 s | 121 µs (3.1 s held) |
| BSD 220 `getattrlist` | 42,784 | 42,784 | 14 s | 73 µs (3.1 s held) |
| Mach −11 `vm_purgable_control` | 28,086 | 28,086 | 12 s | 14 µs |
| BSD 381 `__mac_syscall` | 19,992 | 19,992 | 9 s | 4.6 µs |
| BSD 244 `posix_spawn` | 440 | 440 | 0.3 s | 10 ms (4.4 s held, max 308 ms) |

The holder-stack samples (`YCODE_TRAP_PROFILE_STACKS`) put getattrlist's
hold in host path resolution (59 % in `stat`), the protection-class lookup
(13 %) and `realpath` (20 %); mmap's in the host `mmap` (62 %; the host
process's `mmap_lock`) and the address-space bookkeeping. Most of the
calls in the table touch only the calling process's descriptor table, the
host file system (already safe without L0, stage 6 §5.1) and the caller's
guest memory.

## 2. Locks and order

| Level | Lock | Guards |
|---|---|---|
| 0 | L0, the kernel lock | BSD process and system state; L0 wait queues |
| 1 | L_P, one per image ("event lock") | as `mach-ipc-locking.md` §4.1, **and the image's ulock table and ulock wait queues** (§5) |
| 2 | G, the port lock | as before |
| 3 | L1 per address space | as before |
| leaf | the descriptor-table lock of each process (§3); the knote-watch table and the purgeable-state table of each image; the system's POSIX-lock user set and protection-class table; the file-lock table's creation lock; since KLOCK: the process table and each process record (§13), each image's directory cursors (§14) and I/O policies, the time-of-day snapshot publish (§12), the file-lock table (§15) | their tables only |

A thread takes levels 0–3 in strictly increasing order (unchanged). A leaf
lock is taken last: its holder takes no other lock, waits for nothing and
runs no callback. With `YCODE_LOCK_ORDER_CHECK=1` each thread counts the
descriptor-table locks it holds (`LeafLockCheck`), and taking any kernel
lock (L0, L_P, G) while holding one stops the process.

## 3. The descriptor-table lock

Each `DarwinFileSystem` (one per process image) guards its descriptor
table with a recursive leaf mutex (`DescriptorTableLock`). Every read and
write of the table holds it; every table operation (open's install,
close, dup, dup2, the close-on-exec sweep, exit's close-all, the child
copy at spawn, guard changes, F_SETFD) is one critical section, so it is
atomic with respect to every other, with or without L0. The close hook
(`descriptorClosed`: knotes, directory cursors, POSIX locks) and the
release of the closed descriptions run after the lock is let go (the last
close of an object or of a description with OFD/flock locks takes L0).

Open file descriptions stay shared between processes. Their offset has
its own lock (stage 6 §5.2); their status flags and close handlers are
still changed under L0 only (F_SETFL, FIONBIO, flock/OFD locks). A fast
path reads the status flags as one aligned word.

## 4. BSD traps without L0

The VMM's trap entry tries these after the task-local traps and before
the IPC fast paths, under the task-local traps' milestone rule (before
the image's libSystem milestone only for a trap whose return address is
not in a libSystem image). Each runs on the trapping thread with no
kernel lock, using the same functions as the locked path, so results,
errors and carry are the locked path's. A trap falls back to L0, having
changed nothing, in the cases listed; and always when the image traces,
is ending, or the thread is not bound to it.

| Trap | Without L0 | Falls back when |
|---|---|---|
| 5 `open`, 398, 463 `openat`, 464 | path resolution and host open; the install is one table operation | — |
| 6 `close`, 399 | §4.2 | an object other than a device node; a directory; a guarded descriptor; a descriptor that is not open |
| 3 `read`, 396, 153 `pread`, 414 | one table lookup; the transfer under the offset lock | not a regular host file (pipes, sockets, the console, devices); any error of the lookup |
| 4 `write`, 397, 154 `pwrite`, 415 (`frame-profile.md` §5.1) | one table lookup; the host write under the offset lock | not a regular host file; a guarded descriptor; any error of the lookup; a length above `INT_MAX` |
| 199 `lseek` | one table lookup; the offset lock | — |
| 336 `proc_info` (`frame-profile.md` §8.2) | `PROC_INFO_CALL_DIRTYCONTROL` (flavors 1–4) on the caller's own process: one atomic operation on the process record's dirty word (a leaf, reached through the image) | another target, another call or flavor; `YCODE_DIRTY_FAST=0` |
| 339 `fstat64` | one table lookup | an object other than a device node |
| 92 `fcntl`, 406 | F_GETFD, F_SETFD, F_GETFL, F_GETPATH(_NOFIRMLINK), F_DUPFD(_CLOEXEC), the caching hints, F_CHECK_LV, F_ADDFILESIGS_RETURN, F_GETCONFINED | every other command (locks, F_SETFL, protection classes, …); F_DUPFD of a guarded descriptor |
| 41 `dup` | one table operation | a guarded descriptor |
| 33 `access`, 466, 469 `fstatat`, 470 | path resolution, `stat` | — |
| 202 `sysctl`, 274 `sysctlbyname` | the image's sysctl table (written only before the image runs and on restore) | `kern.proc.*` (the process table) |
| 220 `getattrlist`, 228, 476 | §4.4 | — |
| 197 `mmap` | §4.5 | a POSIX shared-memory object |
| 381 `__mac_syscall` | the Sandbox check calls (2, 12) allow; other policies ENOPOLICY | the Sandbox extension calls |
| 327 `issetugid` | constant | — |
| 515, 544 `ulock_wait(2)`, 516 `ulock_wake` | §5 | no lock split; `YCODE_SCHED_QOS` (priority pushes are L0 state) |

### 4.1 Descriptor lifetime

A call that uses a descriptor resolves it once (one table operation) and
holds strong references to the description and the host file for the
rest of the call, as the stage 6 transfers did: a concurrent close, dup2
or exec-time close by another thread does not affect a call in progress
(POSIX resolves the descriptor at the start of the call; xnu holds an I/O
reference). A spawn copies the parent's table in one critical section,
so a descriptor another thread opens or closes at the same moment is
either inherited or not, never half. An exec that races a fast open in
another thread of the old image can leave the new descriptor in the old
table, which is released with it (the open returns EINTR when the image
already ended, as on the locked path).

### 4.2 The fast close

The descriptor is removed in one table operation, which first looks at
its description and declines (changes nothing) for the cases in the table.
The locked close then runs the close hook; the fast close runs it under
L0 only when it is needed:

- **Knotes.** EVFILT_READ, EVFILT_WRITE and EVFILT_VNODE knotes (the ones
  a close drops) are counted per ident in the image's watch table (a
  leaf) **before** `kevent` looks the descriptor up, and uncounted when
  the registration fails or the knote is dropped. The fast close reads the
  table after its removal. If a registration looked the descriptor up
  before the removal, its count was made before that lookup and is seen;
  if after, the lookup fails with EBADF. The count may be too high (a
  kqueue freed with its knotes), never too low.
- **POSIX locks.** A process's record locks are released by any close of
  the file by that process. The system keeps the set of pids that ever
  set or cleared one (sticky, a leaf), added before the fcntl looks its
  descriptor up; the same ordering argument applies.
- **Directory cursors** belong to directory descriptors, which always
  close on the locked path; a cursor also names the description it was
  made for, so a stale one is never used.

The description is released after all of that with no lock held.

### 4.3 What the locked open still does that the fast open does not

`openat` on the locked path clears a directory cursor recorded for the
new number; the fast path leaves it (it names an older description and is
dropped at its next use or at the close).

### 4.4 getattrlist

Path resolution, host `stat`, `realpath`, extended attributes and the
directory entry count are host or lock-free; the object-path index has its
own lock; the protection-class table now has a leaf lock of its own
(written under L0, read with or without it), and the file-lock table is
created under a creation lock instead of lazily under L0.

### 4.5 mmap

Address-space changes take L1 as for the task-local traps
(`boot-profile.md` §3.6); file views and shared file windows have their
own locks. The descriptor is looked up through the table lock. A POSIX
shared-memory descriptor declines before anything changes. The VMM's
shared-cache mapping record (dyld_sim's mmaps of the cache files) is made
around the fast call as around the locked one; it takes L0 only for a
cache file.

## 5. ulock under the event lock

With the lock split the image's ulock table and every ulock wait queue are
L_P state: `ulock_wait`, `ulock_wait2` and `ulock_wake` take L_P (inside
L0 on the locked path, alone on the fast path) and wait on L_P, which a
wait releases with every other lock (`mach-ipc-locking.md` §4.4). The
owner lookup of an unfair lock reads the thread table, which L_P guards
for writes. Thread exit's join-gate wake takes L_P inside L0. No wakeup is
lost: waiter and waker both hold L_P (I2 of `mach-ipc-locking.md`).
Signals and image termination reach the waiters through L0's registry of
the fine locks, as for kevent waits; the snapshot census sees them there
and restarts the trap (`snapshot.md`). With `YCODE_SCHED_QOS` the calls
stay on L0 (the inheritance push changes thread classes, L0 state).

## 6. vm_purgable_control as a task-local trap

Mach −11 joins the task-local traps (`boot-profile.md` §3.6): the image's
purgeable-state table has a leaf lock; the state change is one section of
it, with the guest memory read before and written after. Same answers.

## 7. The image build of spawn and exec without L0

`posix_spawn` held L0 for 10 ms on average (4.4 s per boot, up to 0.3 s
at a time; 70 ms on average on a loaded host), almost all of it in the
VMM's image build: loading the executable and `dyld_sim` into the new VM,
the stack and argument block, vCPU 0 and the clock. The process layer now
builds the new kernel under L0 as before (descriptor table copy, file
actions, executable check, inherited ports: steps 2–7 of
`processes.md` §1.10), then releases L0 for the launcher's `prepare`
(`stage4b-contract.md` §3.3), takes it back, and continues: the process
record, scheduling policy, SETPGROUP/SETSID, then `activate` (register the
image, start its main thread unless held), as before.

Why this is safe: during `prepare` the new kernel is reachable from no
other thread (it is not in the process table and its new ports are known
to no one), and `prepare` touches only that kernel, the new VM, and VMM
tables with their own locks. The spawning image may end meanwhile (exit,
a fatal signal, another thread's exec): after taking L0 back the call
checks it, destroys the prepared image and fails with EINTR, as the
stage 6 calls that release L0 do. Exec builds its new image the same way
before its commit point; two execs racing in one image both build, the
first to commit wins and the other gets EINTR. `YCODE_SPAWN_UNLOCKED_BUILD=0`
keeps the whole build under L0.

## 8. Snapshots and deadlock freedom

A spawning thread outside L0 is moving, so the quiesce retries until it
is done. None of the §4 traps blocks except the ulock waits, which are registered
waiters of L_P (§5). A thread inside any other fast trap is neither parked
nor blocked, so the quiesce classifies it as moving and retries
(`snapshot.md` §3); the capture holds L0 and every fine lock while every
thread is parked or blocked, so no table changes during it. Leaf locks are
never held while another lock is taken or a thread waits, so they add no
edge to the waits-for graph; a fast path that needs L0 (the close hook)
takes it holding nothing.

**KLOCK's locks (§12–§15)** are leaves of the same kind: their holders
take no other lock, wait for nothing and run no callback (a removed
process record or a replaced image is released after the lock; file-lock
waiters are woken under L0 after the table lock is let go). They count in
`LeafLockCheck`, so taking any kernel lock while holding one stops the
process with `YCODE_LOCK_ORDER_CHECK=1`. The snapshot capture reads, and
the restore writes, these tables with L0 and every fine lock held, so no
fast path runs then; the restore marks the descriptions whose OFD locks it
re-arms (§15).

## 9. Tests

`BSDFastPathTests` (lock-order check on): fast and locked answers byte for
byte for open, openat, read, pread, lseek, fstat64, fcntl, dup,
access, fstatat64, sysctl, sysctlbyname, getattrlist, fgetattrlist, mmap
(file, anonymous, EBADF, ENODEV), __mac_syscall; the fallbacks (pipes, a
directory's close, kern.proc, POSIX shared memory, tracing); a fast close
that releases another process-visible POSIX lock and drops EVFILT_READ
and EVFILT_VNODE knotes; six threads opening, reading, dup2-ing and
closing on one table on both paths; ulock waits on the fast path woken by
a locked wake, a fast wake and an interrupt under L0; vm_purgable_control
task-local against locked; spawn and exec through a two-step launcher
(prepare without L0, activate with it, the switch). The kernel suite also runs with the VMM's trap
order in every test helper (`YCODE_IPC_LOCKS_TESTS=1` or
`YCODE_BSD_FAST_TESTS=1`, about 4,300 BSD fast traps per run, the fast
paths writing the same trace lines as the locked path).

KLOCK's tests (all with the lock-order check, on both paths where the
suite is run with `YCODE_IPC_LOCKS_TESTS=1`): `BSDFastPathTests`
`smallTrapsMatchTheLockedPath`, `processTableReadsMatchTheLockedPath`,
`processTableReadsRaceSpawnsAndExits`, `directoryReadsMatchTheLockedPath`,
`fileLocksWithoutL0`, the console and fcntl cases of
`answersMatchTheLockedPath`; `MachIPCLockSplitTests`
`portRoutinesOnTheFastPathKeepRightsBalanced`; `ThreadStateRaceTests`
(half of the `thread_get_state` calls on the routine's fast path);
`WorkqueueKEventTests.descriptorKnoteIsDeliveredToAParkedWorker`. The
kernel suite (353 tests) passes on the Mac, the Thor (arm64) and the
x86-64 workstation with `YCODE_LOCK_ORDER_CHECK=1 YCODE_IPC_LOCKS_TESTS=1`
and with `YCODE_IPC_LOCKS=0`; the full suite passes on the Mac and the
workstation.

## 10. Measurements

Thor, harness full boots (device in RAM, `YCODE_LEAN_BOOT` unset), the two
arms started together in each round (order alternating), base = main line
aa1bf7c (`SX/IDE`). Other agents shared the host throughout: load
average 31–80 (14 cores), so a boot took 140–295 s instead of the 75 s
of an idle host.

### 10.1 Locks (profiled pair, `YCODE_TRAP_PROFILE`, 181 s each, load 45–50)

| | base | this change |
|---|---|---|
| L0 busy | 48.7 % | 37.1 % |
| L0 acquisitions (per trap) | 2.78 M (0.76) | 0.72 M (0.23) |
| Summed L0 wait | 2,648 s | 762 s (−71 %) |
| `posix_spawn` L0 hold | 15.4 s (29 ms mean) | 5.8 s (two acquisitions, 5.6 ms mean) |
| BSD traps on a fast path | — | 1.30 M served, 91 k fell back |
| Fast closes that ran the close hook under L0 | — | 0 |
| Port lock G: held / waited | 17.8 s / 71 s | 29.3 s / 117 s |
| Event locks: held / waited | 74 s / 76 s | 101 s / 85 s |
| home_s | 180 | 195 |

L0's remaining holders are the workqueue fallbacks (images with
descriptor knotes), the Mach port traps outside the IPC fast paths,
`proc_info` and the second half of `posix_spawn`. The fine locks are held
longer than before: more threads run at once on a saturated host, and
their holders are preempted more (63 % of hold time in preempted holds).

### 10.2 Time to the home screen (no profiling)

| Series | Rounds | base | this change | paired difference |
|---|---|---|---|---|
| b: §3–§4 without ulock, spawn and the small calls (e8dc7f5) | 4 | 192.5 s | 201.3 s | +8.8 s (0 … +25) |
| d: everything (27f1afa) | 6 | 207.5 s | 212.5 s | +5.0 s (−15 … +25) |
| e: 27f1afa, switches off against on (`YCODE_BSD_FAST=0 YCODE_SPAWN_UNLOCKED_BUILD=0`) | 4 | 206.3 s (off) | 186.3 s (on) | −20 s (−75 … +10) |

**Result: on this loaded host the change does not measurably move the
time to the home screen**, although it removes about 70 % of L0's
acquisitions and waits. The paired differences are within the harness
noise (±15–40 s per pair at this load) and do not agree in sign across
series. Every boot reached the home screen; no host crash; `guest_fatal`
2–14 in both arms. The likely reason is that the host was CPU-saturated
(three to five simultaneous boots): a thread that no longer waits for L0
waits for a CPU instead, and the boot's critical path is IPC latency and
guest CPU (`mach-ipc-locking.md` §6.2, `boot-profile.md` §5). A
measurement on an idle host is still needed before calling it a gain or
a loss.

## 11. Open items (SP-L0; see §17 for what KLOCK left)

- ~~`proc_info`, `csops_audittoken` and `kern.proc` sysctls read the process
  table, which is L0 state~~ (§13).
- ~~fcntl F_SETFL~~ (§12), ~~getdirentries64~~ (§14) and ~~the Mach port
  traps outside the IPC fast paths~~ (`mach-ipc-locking.md` §4.10); the
  ~~non-blocking file-lock commands~~ (§15).
- A close in an image that ever used POSIX locks takes L0 for the hook
  (sticky per pid).

## 12. More traps without L0 (agent KLOCK, 2026-10-23)

The idle-host trap profile of a cold boot of a device at its own path
(§15.1) still showed L0 31 % busy with 170 s of summed waits in 41 s, and
every L0 trap waited 100–500 µs for it. Each change below has a switch;
the answers are the locked path's (the same functions run on both paths).

| Trap | Without L0 | Switch |
|---|---|---|
| BSD 73 `munmap`, 74 `mprotect`; Mach −15 `mach_vm_map` (anonymous memory); Mach −3 `mach_absolute_time`, −4 `mach_continuous_time` | task-local traps (`boot-profile.md` §3.6): one address-space change under L1, as `vm_deallocate`, `vm_protect`, `vm_allocate`; a fixed `mach_vm_map` placement checks and maps as one change; the counter | `YCODE_TASK_LOCAL_MORE=0` |
| BSD 116 `gettimeofday` | the clocks; the commpage time-of-day snapshot is published under a leaf lock (two threads, on and off L0, may refresh it at once) | `YCODE_BSD_FAST_MORE=0` |
| BSD 372 `thread_selfid`, 500 `getentropy` | the caller's thread id; host random bytes | the same |
| BSD 322 `iopolicysys` | the image's I/O policy table, now with a leaf lock of its own (set and get are one section each) | the same |
| BSD 381 `__mac_syscall`, the Sandbox extension calls (issue, consume, release) | stateless: a token made from the path's `stat`, a form check | the same |
| BSD 92 `fcntl` F_SETFL of a description without an object (a host file, the console) | one store of the flags word: F_SETFL replaces every settable bit and keeps the access mode, which never changes, so no update is lost without L0; an object's F_SETFL (its readiness may change) stays on L0 | the same |
| `fcntl` F_SETNOSIGPIPE, F_GETNOSIGPIPE | one word of the description | the same |
| BSD 95 `fsync`, 187 `fdatasync` (Ycode's writes reach the host file before they return: a descriptor check); 136 `mkdir`, 475 `mkdirat` (the host directory; the umask is one word); 58 `readlink`, 473 `readlinkat`; 345 `statfs64`, 346 `fstatfs64` | path resolution, the descriptor table and host calls | `YCODE_BSD_FAST_MORE=0` |
| BSD 361 `bsdthread_terminate`: the unmap (or, for the main thread, the protection) of the thread's stack | released L0 for the address-space change (L1; a host mapping change runs every VM's MMU notifier, 360 µs mean L0 hold before); the thread is still alive and in its table meanwhile; the rest under L0 as before | — |
| Mach −43 `mach_generate_activity_id` | task-local: the image's counter is an atomic | `YCODE_TASK_LOCAL_MORE=0` |
| BSD 4 `write`, 397 of the console | the host's standard output or error (one host `write`, which the host serializes); on L0 a slow host stream (a full pipe to a log reader, a file on a busy disk) held the kernel lock for the whole write | the same |
| Ycode's `vm_copy` (0x7963_0004) | task-local: one read and one write of guest memory | `YCODE_TASK_LOCAL_MORE=0` |
| Ycode's Mach routines `thread_get_state`, `task_threads`, `mach_make_memory_entry_64`, `mach_vm_map` (memory object), `mach_vm_remap`, port context | the event lock and/or G (`mach-ipc-locking.md` §4.10) | `YCODE_PORT_ROUTINES_FAST=0` |
| `fcntl` F_GETPROTECTIONCLASS, F_GETPROTECTIONLEVEL | the protection-class table's leaf lock (§4.4); setting a class stays on L0 | the same |

**Importance flips without QoS.** A send that changes a process's
importance count across zero flips its darwin-bg state; the fast `mach_msg`
deferred a class refresh to L0 for it (`mach-ipc-locking.md` §4.5) even
when `YCODE_SCHED_QOS` is off, where the refresh does nothing. Only a start
hold's release (or QoS) now takes L0 there.

## 13. The process table without L0

`proc_info` reads, `csops`/`csops_audittoken` and `kern.proc.pid` read the
process table and process records (L0 state until now).

- **The table** (`DarwinSystem.processes`) is read and written under a
  leaf lock of its own (`processTableLock`); every writer still holds L0
  as well. A write replaces the dictionary (spawn, exit, reap: rare); a
  record removed from it is released after the lock (its image's deinit
  may take locks).
- **A record's fields** that these calls read (parent, group and session
  ids, state, wait status, image, executable path and names, start and exit
  times, unique ids, pid version, the zombie's UUID, the exiting flag) are
  one struct under a per-record leaf lock; each field access is one
  section, writers hold L0 too, and a reader without L0 takes one
  consistent copy (`DarwinProcess.view()`), so a reply never mixes a
  zombie's state with a running process's status. The other members stay
  L0 state.
- **Fast calls** (BSD fast path): `proc_info` LISTPIDS, PIDINFO (every
  served flavor; TASKINFO reads the target's thread count under the target
  image's event lock, which the trap may take: it holds nothing) and
  PIDRUSAGE; `proc_info_extended_id` (545) with those calls; `csops` (169)
  and `csops_audittoken` (170), whose target image's identity, pid version
  and signature do not change while it runs; `sysctl` `kern.proc.pid.<pid>`
  (other `kern.proc` names fall back). TERMINATE and DIRTYCONTROL of
  another process change state: L0.

Switch: `YCODE_PROC_TABLE_FAST=0` (the locks stay; only the calls go back
to L0). Tests: `BSDFastPathTests.processTableReadsMatchTheLockedPath`
(every call and flavor, a running process, a zombie, pseudo-init, a pid
that does not exist; byte for byte) and
`processTableReadsRaceSpawnsAndExits` (40 spawn–exit–reap cycles under L0
against fast readers).

## 14. Directory cursors without L0

The image's directory cursors (`getdirentries64`, `getattrlistbulk`) are a
table with a leaf lock (`ExtendedBSDState.DirectoryCursorTable`). A call
looks its descriptor up in the descriptor table, makes the cursor when the
descriptor has none or one of another description (listing the directory
with no lock held; another thread's cursor made meanwhile wins), then takes
the records and moves the cursor in one section of the table's lock.
`getdirentries64` (344) is a BSD fast trap, and a directory's close is a
fast close that drops the cursor (§4.2). A `getdirentries64` that looked
the descriptor up before a concurrent close may leave a cursor for the
number; it names the old description and is replaced at the number's next
use (as for the fast open, §4.3). `getattrlistbulk` stays on L0. Listing a directory stats each entry with
one host `lstat` relative to the directory (`DarwinFileSystem.statEntry`)
instead of a full guest-path resolution (one `lstat` per path component;
1–2 ms per listing for SpringBoard, `boot-profile.md` §8.6) when the entry
is plainly inside the directory's prefix; a guest symbolic link, a nested
prefix root, `/dev` and any error take the full resolution (test
`DirectoryEntryStatTests`).
Switch: `YCODE_DIRECTORY_FAST=0`. Test:
`BSDFastPathTests.directoryReadsMatchTheLockedPath` (the records,
positions and end flag of both paths read in pieces; readers racing opens
and closes).

## 15. File locks without L0

The file-lock table (`FileLockTable`: every file's lock list, the waiting
counts, the POSIX deadlock chain, the descriptions with a release handler)
has a leaf lock of its own; every table method takes it. The non-blocking
calls (`fcntl` F_GETLK 7, F_SETLK 8, F_OFD_GETLK 92, F_OFD_SETLK 90) are BSD
fast traps; the waiting forms (F_SETLKW, F_SETLKWTIMEOUT, the OFD ones) and
`flock` stay on L0, because their waiters sleep on an L0 queue per file.

No wakeup is lost: a waiter (holding L0) finds the blocker and counts
itself as waiting in one table section, and holds L0 until it sleeps; a
change (a set or an unlock, on either path, or a release at close or
exit) returns the states of files with waiters, and the caller wakes them
under L0 after the table lock is let go (taking L0 holding nothing on a
fast path). So a waiter either saw the change, or was counted before it and
is woken. An OFD lock's first set on a description goes to L0, which
installs the description's release handler (L0 state); the table records
which descriptions have one, and the fast set requires it. Switch:
`YCODE_FILE_LOCK_FAST=0`. Test: `BSDFastPathTests.fileLocksWithoutL0` (a
fast unlock wakes another process's F_SETLKW waiting on L0; OFD locks;
F_GETLK on both paths), and the `FileLockTests` suite on both paths.

## 16. Measurements (KLOCK)

Thor, idle host for every timed boot (`timed.sh`: the machine to itself, 1-min
load below 4 at the start; each series ran inside one `timed.sh` call with
the arms alternating per round and a wait for load below 4 before each
boot). Arms differ only in switches on one build: *off* =
`YCODE_PORT_ROUTINES_FAST=0 YCODE_TASK_LOCAL_MORE=0 YCODE_BSD_FAST_MORE=0
YCODE_PROC_TABLE_FAST=0 YCODE_DIRECTORY_FAST=0
YCODE_DESCRIPTOR_ESCALATION=0` (and `YCODE_FILE_LOCK_FAST=0` where it
existed), *on* = the defaults. What the switches leave on in *off* (the
process-record and table locks, the fixed importance flip, the stack unmap
of a thread exit without L0) is small.

### 16.1 Locks (profiled cold boots of a device at its own path)

`YCODE_TRAP_PROFILE`, two pairs (series P), tables copied at the home screen:

| | off (2 boots) | on (2 boots) |
|---|---|---|
| time to the home screen (profiled) | 46, 37 s | 35, 44 s |
| L0 busy | 33.0 %, 32.0 % | 14.2 %, 16.1 % |
| L0 acquisitions (per trap) | 451 k, 384 k (0.19) | 80 k, 83 k (0.04) |
| summed L0 waits | 228 s, 162 s | 24 s, 32 s |
| IPC traps that fell back to L0 | 47.7 k, 39.9 k (descriptor knotes 42 k, 35 k) | 9.9 k, 10.3 k (descriptor knotes 0) |
| BSD fast traps that fell back | `proc_info` 33 k, fcntl 29 k (F_OFD_SETLK 25 k), close 19 k + 10 k, `__mac_syscall` 6 k | fcntl 3 k (F_SETCONFINED 1.2 k, F_OFD_SETLKWTIMEOUT 1.0 k), close 0.4 k |
| work deferred to L0 from fast paths | 7.7 k, 8.4 k (descriptor kqueue re-evaluations 5.8 k, 6.8 k) | 3.0 k, 2.9 k (new workqueue threads, payload releases) |
| escalations to L0 for descriptor readiness | — | 1.1 k, 1.0 k |
| port lock G: held, summed waits | 5.9 s, 26 s; 4.8 s, 21 s | 5.3 s, 41 s; 6.9 s, 61 s |
| event locks (all images): held, summed waits | 24.8 s, 23.6 s; 20.7 s, 23.4 s | 28.2 s, 35.1 s; 39.5 s, 36.9 s |

L0 is no longer contended (its waits fell by 85–90 %), but the waits
moved: the port lock's summed waits doubled or tripled and the event locks'
rose by half. The traps that left L0 now meet on G (the port routines,
mach_msg) and on each image's event lock (the kevent and workqueue traps of
images with descriptor knotes, which ran one at a time under L0 before).
P-on-2 also had one 403 ms hold of G by a `mach_msg2` (every other
maximum: under 50 ms).

### 16.2 Time to the home screen (no profiling)

| Series | Device | off | on | paired on − off |
|---|---|---|---|---|
| C (4 rounds) | the same device, booted again at its own path (1 s resolution) | 42, 34, 34, 36 (mean 36.5) | 42, 37, 33, 39 (mean 37.8) | 0, +3, −1, +3 (mean +1.3 s) |
| B (4 rounds, main line 3aeaa9c merged) | `bench.sh` copies of the pristine device in RAM (5 s resolution) | 70, 60, 65, 65 (mean 65) | 75, 70, 70, 75 (mean 72.5) | +5, +10, +5, +10 (mean +7.5 s) |

**Result: removing L0 contention does not make the boot faster.** In
place the difference is within the spread; on copies the changes cost
5–10 s in every pair (the bench harness's 5 s steps; small n). The likely
cause is §16.1: the boot's critical path is a chain of Mach IPC round
trips, and the IPC locks it uses (G, the event locks) are now busier; L0
had serialized the port routines and the descriptor-knote images' kevent
traps away from them. This cause is not confirmed: the ablations that
would test it (§17) were not run.

### 16.3 Home-screen interaction (restored device)

Series J (3 rounds, one warm-up session; restore, 25 s, a 40 s
frame-profile window over home-screen drags outside the dock column, Home,
a drag to the Today view and back, Spotlight; `ycode-display-probe`):

| | off | on |
|---|---|---|
| presents per second over the window | 17.3, 15.0, 15.9 | 15.8, 15.5, 16.6 |
| present interval p50 / p90 (ms) | 9.6/18.0, 9.7/18.4, 10.1/18.0 | 9.5/18.0, 10.6/18.2, 9.0/17.7 |
| swipe frames received p50 / p90 (ms) | 20.6/26.8, 20.6/30.3, 20.6/23.1 | 20.6/22.7, 20.6/25.6, 20.7/23.6 |
| input → first frame: swipes (p50), Today, back, Spotlight (ms) | 91/213/41/212, 100/201/89/246, 92/219/33/258 | 93/212/84/247, 98/188/35/210, 139/204/84/245 |

No difference beyond the session-to-session spread: the frame path no
longer waited for L0 after FPS-PROF and FPS-2.

## 17. Open items (KLOCK)

- The waiting file-lock forms (F_OFD_SETLKWTIMEOUT 93 is sqlite's busy
  wait, about 1,000 a boot) and `flock` stay on L0 (§15).
- The close of an object (pipe end, socket, kqueue) and its I/O stay on L0
  (their buffers and readiness are L0 state): `sendto`, `recvfrom`,
  `write`/`writev` to pipes and sockets. A lock per object would move them
  and descriptor readiness off L0 (then the escalation of
  `mach-ipc-locking.md` §4.11 is not needed).
- F_SETCONFINED (95), `getrlimit` (the limits table), `persona`, `socket`,
  `sigaction`, Ycode's `task_info` (0x7963_0006) and the image-list
  notification (0x7963_0010), `posix_spawn`'s second half, thread
  creation and exit: small or rare, still on L0.
- Tracing turns every fast path off (by design).
- Ablations for §16.2 (not run): turn the fast-path groups back onto L0
  one at a time (the port routines, the descriptor-knote kevent and
  workqueue traps, the file and directory paths) and time each against
  the all-on and all-off trees, to find which move makes the boot
  slower.

## Evidence

| Claim | Level | Source |
|---|---|---|
| A descriptor is resolved once per call; a concurrent close does not affect a call in progress | 1 | POSIX `close(2)`, `read(2)`; xnu `fp_lookup`/`fp_drop` |
| F_SETFL sets the settable status flags and keeps the access mode | 1 | POSIX `fcntl(2)`; xnu `kern_descrip.c` (via §12) |
| `proc_info`, `csops` and `kern.proc` answers kept (§13) | 1 | as the locked path, `processes.md` §2.11 (its evidence there) |
| Any close of a file by a process releases its POSIX record locks | 1 | POSIX `fcntl(2)`; xnu `closef` |
| ulock wait/wake semantics kept | 1 | xnu `bsd/kern/sys_ulock.c` (via `threads-and-events.md` §4.1) |
| Recursive and plain pthread mutexes; Swift `Mutex` | 1 | POSIX, Swift Synchronization documentation |
| L0 profile (§1) and measurements (§10) | 3 | Thor harness boots `SX/SPL0/prof/*`, `SX/{IDE,SPL0}/runs/sp-l0-*` |
| KLOCK's profiles and measurements (§12, §16) | 3 | Thor timed boots and sessions of Ycode's simulator: `ide-remote/klock/runs/{p0-1,P-*,C-*,X-*,F-*,Y-*}`, `ide-remote/klock/out/{J,K}-*`, `SX/KLOCK/runs/{B,G}-*` |
| Pipes and sockets notify readiness observers at every change (§12 stale-candidate rule, `mach-ipc-locking.md` §4.11) | — | Ycode's own `Pipe.swift`, `UnixSocket.swift` |

Level 5 was not used. The reference tools folder, `research/` and Ghidra
were not opened.
