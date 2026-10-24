# Spec: BSD and VM traps off the global kernel lock

Status: **implemented, agent SP-L0, 2026-10-19.** Continues
`mach-ipc-locking.md` (which moved the Mach IPC, kevent and workqueue
traps off L0) for the BSD descriptor, path, ulock and VM traps that still
ran under L0. On by default; `YCODE_BSD_FAST=0` sends every trap of §4
back to L0 (§6's purgeable call follows `YCODE_TASK_LOCAL_TRAPS`).
Measurements: §10.

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
| leaf | the descriptor-table lock of each process (§3); the knote-watch table and the purgeable-state table of each image; the system's POSIX-lock user set and protection-class table; the file-lock table's creation lock | their tables only |

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

## 11. Open items

- `proc_info` (103 k calls, 49 s of summed waits per boot), `csops_audittoken`
  and `kern.proc` sysctls read the process table, which is L0 state; a
  read-mostly process-table lock would take them off L0.
- fcntl F_SETFL and the file-lock commands, getdirentries64 (directory
  cursors) and the Mach port traps outside the IPC fast paths still use L0.
- A close in an image that ever used POSIX locks takes L0 for the hook
  (sticky per pid).

## Evidence

| Claim | Level | Source |
|---|---|---|
| A descriptor is resolved once per call; a concurrent close does not affect a call in progress | 1 | POSIX `close(2)`, `read(2)`; xnu `fp_lookup`/`fp_drop` |
| Any close of a file by a process releases its POSIX record locks | 1 | POSIX `fcntl(2)`; xnu `closef` |
| ulock wait/wake semantics kept | 1 | xnu `bsd/kern/sys_ulock.c` (via `threads-and-events.md` §4.1) |
| Recursive and plain pthread mutexes; Swift `Mutex` | 1 | POSIX, Swift Synchronization documentation |
| L0 profile (§1) and measurements (§10) | 3 | Thor harness boots `SX/SPL0/prof/*`, `SX/{IDE,SPL0}/runs/sp-l0-*` |

Level 5 was not used. The reference tools folder, `research/` and Ghidra
were not opened.
