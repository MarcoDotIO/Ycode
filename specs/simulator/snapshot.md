# Spec: snapshot and restore of a running simulator

Status: **design + prototype (2026-10-17, agents SNAP and SNAPb).** Phase 1
(this document) inventories the state of a running Ycode simulator, fixes the
snapshot format, the quiesce protocol and the restore order. Phase 2 (the
prototype behind `YCODE_SNAPSHOT_*` and `YCODE_RESTORE_*`, default off)
implements the subset of §9 and measures it (§10): a home-screen device is
snapshotted and restored, with the GPU clients restarted (§8 option 1).
Phase 3 (2026-10-19, agent SP-SNAP), the warm-boot path: the IOSurface,
Metal and SCDynamicStore host services are saved and the Metal objects are
made again on a fresh GPU back end (§8 option 2), so the render server and
SpringBoard keep running and the home screen is back as soon as the restore
ends; page files are mapped lazily (§6.3); host-service requests and start
holds are part of the quiesce (§3.1, §3.2). Measurements in §10.5.
Phase 4 (2026-10-19, agent IDE-WARM): the IDE's default warm boot uses it
(§12; `specs/ide/run.md` §Warm boot). Phase 5 (2026-10-19, agent
SNAP-FIX): restored threads start behind a gate (§7 step 9; the "no vCPU"
restore failures of §12), and the device keeps its state between runs: the
run is saved when it is stopped and the next run restores it in place
(§12.2). Phase 6 (2026-10-19, agent RESTORE-HARDEN): the restore follows
the IPC lock split (restored descriptor knotes and the rebuild had raced
the fast paths and the host services: hung restores and host crashes),
calendar-time timers follow the wall clock, the launcher keeps logs and
symbolized crash reports and checks that a restored guest runs (§12.5).

This is Ycode's own design for Ycode's own VMM and kernel personality. It
describes no Apple internals. Darwin facts it relies on (trap numbers, the
meaning of a Mach port name, `mach_absolute_time`) come from the xnu sources
and headers and are already in `mach-ipc.md`, `processes.md` and
`threads-and-events.md`. KVM facts come from the Linux kernel's public KVM API
documentation. Prior art for the overall shape: Firecracker's microVM
snapshots (versioned per-device state plus a guest-memory file) and CRIU
(per-kernel-object dump records, restart of interrupted system calls).

## 0. Goal and terms

A developer pays the boot once: boot a device to the home screen, write a
snapshot, and later start a new `ycode-simd` process from the snapshot and
reach a running home screen in seconds (a boot of an already-migrated device
takes 500–560 s on the Thor, `specs/simulator/home-screen.md`).

- **Simulator state**: everything one `ycode-simd` host process holds for one
  device: the `DarwinSystem` (process table, the shared Mach state, the one
  kernel lock), one `DarwinKernel` per live process image, one KVM VM per
  image with its memory and vCPUs, the VMM's launcher records, and the host
  services (host task, bootstrap logger, device session, IOSurface, Metal,
  SCDynamicStore).
- **Image**: one `DarwinKernel` + one VM (a process after exec is a new image
  under the same pid).
- **Snapshot**: a directory with a manifest and page files (§6).
- **Quiesced**: no guest instruction runs, no trap handler runs, and every
  guest thread is in one of the restorable states of §3.2.
- **Restart a trap**: on restore, a thread whose trap was blocked in the
  kernel at snapshot time issues the same trap again (from its entry
  registers, possibly rewritten by §4), as Linux restarts an interrupted
  system call with `-ERESTARTSYS`.

Non-goals: live migration between hosts with different CPUs; snapshots of a
simulator whose host services hold state that §8 marks as not restorable
without a process restart; keeping host sockets to the outside world.

## 1. Principles

1. **Same guest-virtual layout, new guest-physical layout.** Guest code sees
   only virtual addresses, page contents and register values. The restore
   replays every mapping of every address space at the same VA with the same
   protection and backing kind, and then writes the saved page contents. The
   page tables are rebuilt by the address space itself, so a GPA never has to
   match (the shim's own regions and the vCPU-slot region are fixed by
   `VMLayout` and come out identical).
2. **Every thread restarts from a trap frame.** At a quiesce point a thread's
   whole user state is a trap frame (x0–x30, SP_EL0, ELR, SPSR, TPIDRRO_EL0,
   TPIDR_EL0; `vm-shim-protocol.md` §5) plus its FP/SIMD registers (V0–V31,
   FPSR, FPCR). The EL1 shim keeps no per-thread state outside the vCPU slot,
   so a restored thread runs on any vCPU slot (§7 step 9).
3. **No in-flight trap is captured.** A trap handler's host stack cannot be
   saved. Either the trap finishes before the snapshot, or the thread is
   blocked in a wait whose trap can be restarted (§4) and the snapshot
   records the kernel state *as if the trap had not started yet*.
4. **Objects are records, references are ids.** Every kernel object becomes
   one record with a snapshot-local id; references between objects (a port
   in a message, a file description in two descriptor tables, a knote's
   kqueue) are ids. Identity that the guest can observe (port names and
   their generations, pids, pid versions, fds, thread ids, workloop ids,
   kevent idents and udata) is restored exactly; identity the guest cannot
   observe (port serials, `ObjectIdentifier`s, host fds, GPAs) is not.
5. **Derived state is rebuilt, never saved.** Closures (observers, hooks,
   `lastCloseHandlers`), caches (regions cache, directory prefix cache,
   shared-cache attribution), statistics and wait queues are rebuilt by the
   restore code from the records.
6. **Refuse rather than guess.** A snapshot that meets an object or thread
   state it cannot restore fails with a list of the offenders (§3.4); the
   simulator keeps running.

## 2. State inventory

Counts in the right-hand columns of §2.1–§2.6 are what one process or one
home-screen boot holds; §10 has the measured numbers.

### 2.1 Guest memory (per image)

The VM's guest-physical space (`vm-shim-protocol.md` §2,
`stage3-contract.md` §3, `stage6-contract.md` §5):

| Memory | What it holds | Capture | Restore |
|---|---|---|---|
| RAM memslot 0 (512 MiB at `0x4000_0000`) | shim image, boot info, stage-2 frame, EL1 stack, page-table arena, vCPU-slot region (boot info, frame and EL1 stack per vCPU) | nothing | rebuilt: shim from `--shim`, boot info by the vCPU pool, page tables by the address space |
| Anonymous pool (16 GiB `MAP_NORESERVE`) | every anonymous mapping, stacks, malloc heaps, copied file mappings ≤ 1 MiB | per region: pages that are resident on the host (`mincore`) and not all zero | replayed mapping, then page writes |
| Private file memslots (`MAP_PRIVATE` of a host file) | writable file mappings > 1 MiB: the shared cache's `__DATA*` mappings, large data files | pages that differ from the file: resident pages whose host page-map entry is anonymous (copy-on-write happened), compared with the file when the page map is unavailable | replayed file mapping, then page writes |
| Read-only file arena (one memslot at `0x80_0000_0000`, shared by every VM) | read-only file views (the shared cache text, executables, frameworks) | nothing (the file is the content) | replayed file mapping; the arena maps the file again |
| Shared memory objects (`SharedMemoryObject`) | Mach memory entries, POSIX shm, IOSurface backing, Metal shared buffers | once per object (by snapshot id): resident non-zero pages | object re-created with the same size, pages written, then mapped by every region that used it |

The address-space map itself (`GuestAddressSpace` regions: VA, size,
protection, backing kind, file guest path, host path and offset, shared
object and offset, `permanent`) is captured as one record per region.
Permanent regions (the Ycode host page, the commpage, the main-thread
block) are created by the normal image build; the restore only rewrites
their content. Workqueue thread allocations (560 KiB each) are ordinary
anonymous regions.

### 2.2 Guest threads and vCPUs

| State | Where it lives | Capture | Restore |
|---|---|---|---|
| x0–x30, SP_EL0, PC/ELR, PSTATE/SPSR, TPIDRRO_EL0, TPIDR_EL0 | the trap frame in the vCPU slot (a thread stopped in or before a trap), or the vCPU (a thread kicked out of guest code) | a 320-byte frame record (§3.2) | the first trap of the new vCPU is replaced by this frame (§7 step 9) |
| V0–V31, FPSR, FPCR | vCPU (the shim never saves them) | `KVM_GET_ONE_REG` (128-bit V registers, 32-bit FPSR/FPCR) | `KVM_SET_ONE_REG` while the new vCPU is stopped in its first trap |
| EL1 system registers (SCTLR, TCR, MAIR, TTBR0, VBAR, CPACR, TPIDR_EL1, SP_EL1, CNTKCTL) | vCPU, set by the shim's boot path from the boot info | nothing: identical for every thread of an image | the shim's boot path on the new vCPU |
| Virtual counter offset (CNTVOFF via `KVM_REG_ARM_TIMER_CNT`) | per VM | the guest counter value at the snapshot (§5) | §5 |
| Virtual timer (CNTV_CTL/CVAL) | vCPU | nothing: the shim and the guest never arm it (time goes through traps) | — |
| The thread ↔ vCPU binding, vCPU count | VCPU pool | nothing | each restored thread gets a vCPU from the pool |
| `ThreadContext` (thread id, port name, kind, pthread address, signal mask, workqueue state, suspended start, `isAlive`) | kernel | one record per thread | rebuilt; `threadsByPort` re-keyed by name |

### 2.3 Kernel personality: system level

| Object | Fields that matter | Notes |
|---|---|---|
| `DarwinSystem` | last pid, next pid version, next unique id, boot salt, boot session UUID (guest-visible: `kern.bootsessionuuid`) | the lock is rebuilt |
| `DarwinProcess` (incl. pid 1 and zombies) | pid, ppid, pgid, sid, unique id, state, wait status, exit high bits, children, executable path, comm, name, has-execed, start time, start/exit abstime, parent unique id, original parent pid version, dirty state, process type/control, pid version, exit reason | `watchers` are rebuilt from EVFILT_PROC knotes; `childWaiters` is a wait queue |
| `MachIPCSystem` | serial, stamp and space counters, audit session id, host and bootstrap kernel objects, IOKit main port and objects, registry paths, host-bootstrap default flag, the host task | — |
| POSIX shm segments, POSIX named semaphores | name → segment (shared memory object) / semaphore value | — |
| File-lock table | per file identity: OFD, flock and POSIX locks with owners | rebuilt keys: host file identity (dev, ino) is stable on the same host |
| Object-path index | object id → path | rebuilt lazily by the file system |

### 2.4 Kernel personality: per process image

| Object | Fields | Notes |
|---|---|---|
| `DarwinKernel` scalars | pid, pid version, executable host path, all-image-infos address/size, main stack top, thread registration (`bsdthread_register` offsets), next activity id, next thread id, purgeable states, exit value, death signal, termination | `counter`, `wallClock`, `log`, `entropy`, `sleep` are closures rebuilt by the VMM |
| `sysctl` table | the standard table plus entries a process added (`kern.bootsessionuuid`, set values) | saved as name/MIB/value triples |
| Extended BSD state | process signal mask, pending signals, signal actions, alternate stack, rlimits, umask, directory cursors (open directory fd → entries + position), I/O policies (process and per thread), background policy | select statistics are not saved |
| Mach space (`MachIPC`) | the name table (per slot: generation, in-use, type bits, urefs, port or port set), free list, next fresh index, `isTerminated`, task flavors (control, name, read, inspect), main thread port, clock ports, task special/registered/exception slots, owned kernel ports, special reply ports by thread, thread exception slots | `reverse` is rebuilt from the table; the hooks are rebuilt |
| Ports (`IPCPort`, global) | kernel object kind (+ serial-keyed object), semaphore, special-reply flag, owning task, fileport file, memory entry, mk_timer, active, receiver space, transit holder, srights/sorights, mscount, seqno, qlimit, context, guarded/strict/immovable, no-senders/port-destroyed requests, dead-name and send-possible requests (with armed state), dead-name-notified set, sets, ready stamp, change stamp, the message queue | `waitingReceivers` is 0 after quiesce (§4) |
| Port sets | name, members, active, change stamp | — |
| Messages (`KMessage`) | complex flag, destination and reply rights, their received types, voucher, id, items (port rights, OOL data with copy/volatile flags, OOL port arrays, guarded ports), inline bytes, aux data, from-kernel, timer-expiry, sender identity | rights in messages are references to port records |
| Semaphores, ulocks | semaphore value and destroyed flag; ulock queues (opcode, owner) | waiters are 0 after quiesce |
| mk_timers | port, deadline (host ns → rebased, §5), armed ticks | — |
| Memory entries | shared memory object + offset/size/protection | — |
| Descriptor table (`DarwinFileSystem`) | per fd: open file description, close-on-exec, close-on-fork, guard; cwd; max descriptors; guest symlinks | the prefixes come from the run configuration |
| Open file descriptions | node (console stream, host file, object), offset, status flags, no-SIGPIPE, confined | shared by id across processes, fileports and SCM_RIGHTS messages |
| Host files (`GuestFile`) | guest path, host path, open flags, size and modification time at the capture | reopened by host path. A file renamed while open (an atomic save: "x.tmp" renamed to "x" before it is closed) is recorded under its current name (Linux: the `/proc/self/fd` link), not the name it was opened with. A file unlinked while open keeps its bytes in the record (§2.7). The restore reports files whose size or modification time differ from the capture's |
| Pipes | buffered bytes, reader/writer open, access/modify time, inode number | both ends share one record |
| AF_UNIX sockets | type, state, bound path, peer, listen backlog and pending connections, receive queue (segments/datagrams with SCM_RIGHTS descriptions and credentials), options | the socket namespace (path → socket) is per system |
| kqueues and workloops | kind, legacy format, knotes, buckets (requested, bound worker), workloop id, servicer, owner, requested, request QoS, overcommit, fixed priority, create reference | — |
| Knotes | ident, filter, flags, fflags, data, udata, qos, ext[4], enabled/active/suppressed/delete-pending/synthetic-delete/dropped, bucket, user flags, timer deadline (rebased)/interval/fires, receive-gone, vanish request, proc fired/data/exited, signal count, descriptor object | observer tokens and `syncWaiters` are rebuilt |
| Importance (`scheduling-policy.md` §4.3) | per port: accepts importance, temporary owner, the job it watches for (pid); per message: carries importance, the push class of a waiting sender; per thread: the process whose importance it carries | the counts and credits (`importanceCount`, the credited process, each process's boosts) are rebuilt from the queued messages and the threads. Without them a send to a held job's service port does not release its start hold |
| Workqueue | open, dispatch config, new-SPI offset, manager priority, workers (thread id → worker state: base, phase, first run, QoS, constrained, assignment, bound queue/bucket, kevent run, delivered knotes), idle list, plain pending counts, pending workloops, idle timeout | normalized by §4 for parked workers |
| Code-signing state | per process: csops flags, team id (derived from the executable at spawn) | recomputed from the executable path |

### 2.5 VMM level

| State | Capture | Restore |
|---|---|---|
| Launcher records (serial, pid, executable) | per image | new records (serials restart at 1) |
| Image map (attribution of guest addresses to images, shared-cache delta) | nothing (diagnostics) | rebuilt from the executable and dyld_sim of the image build |
| System counter offset | the guest counter at the snapshot | §5 |
| Shared file arena | nothing | refilled as files are mapped again |
| Trap counters, milestone flags, profiles | nothing | start at 0 |

### 2.6 Host services (device mode)

| Service | State | Policy |
|---|---|---|
| Host task (`MachHostTask`) | its Mach space (ports the VMM's services receive on: host bootstrap port, service ports, port sets), queued messages | captured like a guest task (it is one in the shared Mach state); its receiver threads are restarted |
| Bootstrap logger, device session | the control channel port, the session binding, one-shot bookkeeping | the channel and session-port names are a `device-session` host-service record (§6.1); the restored run adopts the session without a new bind (700) and runs its app steps (§7 step 8). One-shot bookkeeping is not saved |
| SCDynamicStore host service | the open sessions (session port, the notify rights each keeps); the store itself is empty in Ycode | captured (`scdynamicstore` record): without it every request on a restored session port is answered "no store session" |
| IOSurface host service | surfaces (id, memory entry, serial, name, creation properties, planes, layout, seed, values, attachments, lock and use counts, purgeable state, Method-14 ports), connections (client port, references per surface), next serial | captured with the guest quiesced (`iosurface` record, §3.1 step 4); surface memory is a shared memory object behind the host task's memory entry (§2.1), found again by the entry's name |
| Metal host service | per process: connections, event port, ref tables (guest ref → handle, next, free list), objects (kind, ref, rights, heap sizes, GPU address, event value, how the object was made), recipes of released objects that live ones were made from; the contents of textures and buffers that live in GPU memory only | captured with the guest quiesced and no command buffer in flight (`metal-objects` record); the back end's Vulkan objects are made again from the recipes (§8 option 2). The client pids stay in a `metal` record (§8 option 1) |
| HID host service (`hid-input.md` §7) | the guest bundle's registration: a send right in the host task's space | the host-task name is a `hid` record; the restored service takes it back (§12.4) |
| Screen capture, display server | a path and timers | rebuilt from the configuration |
| Framebuffer state file (`DEV/data/tmp/ycode-framebuffer.state`) | a guest file backboardd keeps open | kept by the restore (§12.4); its record names a restored surface |

### 2.7 What cannot be captured

- **Live host GPU state**: Vulkan devices, queues, command buffers in
  flight, device-local memory, compiled pipelines. §8 decides between replay
  and a restart of the owning processes.
- **Host sockets and pipes to the outside world** (a host stream socket in a
  descriptor, `HostStreamSockets.swift`): the peer is not part of the
  snapshot. Refused.
- **The device directory as such.** Its files are host files the guest
  wrote (caches, databases, mapped files), and guest paths contain the
  device directory's *host* path (the writable prefix is served at its own
  path). So the device directory is part of the snapshot: it is copied while
  the guest is paused (`YCODE_SNAPSHOT_COPY_DEVICE=1`; 650 MB, 15 400 files
  at the home screen) and must be put back at the same host path before a
  restore. Files whose size or mtime changed are reported. Two ways back:
  - *in place*: a snapshot taken with `YCODE_SNAPSHOT_EXIT=1` or at a stop
    (`YCODE_SNAPSHOT_STOP_DIR`, §12.2) leaves the device directory exactly
    in the snapshot's state (no guest instruction runs after the capture),
    and one restore can run on it directly. Every snapshot of a device
    records `device-path` and `device-inodes`, so an in-place restore of a
    run that was itself restored from a copy keeps the inode numbers its
    processes saw;
  - *from the copy*: a copy has new inode numbers, and guest code caches
    them (SQLite compares the inode of its open database with the path's
    and fails every write with "readonly database moved", error 1032,
    otherwise). The snapshot therefore records each file's inode number
    (`device-inodes`, §6) and the restore makes `stat`, `fstat` and the
    attribute calls report the recorded number for every file of the copy
    whose host inode differs. A file created after the restore gets a fresh
    host number; a clash with a recorded number is possible in principle and
    not checked.
- **Processes started from the device directory** need nothing extra; the
  runtime root and the shim are read-only and the same for every run.
- **Host files unlinked while open or while mapped** have no path: their
  bytes are saved in the record (up to 256 MiB each) and the restore makes
  an unlinked host copy; a mapping of such a file comes back as anonymous
  memory with its pages, and a shared view of a file that is gone comes back
  as plain shared memory.
- **In-flight traps that are not restartable** (§4.3): the snapshot retries
  until they finish, and fails after its deadline.
- **Host threads inside handlers** of host services: each service is
  stopped at its message-loop boundary (§3.1 step 4) before capture.

## 3. Quiesce protocol

### 3.1 Steps

1. **Arm the gates.** The snapshotter sets a pause flag. Two gates check it,
   both on the vCPU's own host thread and with no lock held:
   - the *trap gate* runs when a doorbell trap arrives, before the kernel
     sees it: the thread parks with state "trap pending" and its frame;
   - the *run gate* runs before every `KVM_RUN`: a thread whose vCPU is at
     EL0 (it was kicked out of guest code) parks with state "resume" and the
     frame read from its vCPU registers. A vCPU stopped at EL1 (inside the
     shim, e.g. at a completed doorbell store) is not parked; it runs on and
     parks at its next trap or kick.
   A parked thread records its FP/SIMD registers itself.
2. **Kick.** Every worker that runs guest code (has a guest thread, is not in
   a handler, is not parked) is sent the vCPU kick signal, so its `KVM_RUN`
   returns and it reaches the run gate. Kicks repeat every 2 ms.
3. **Converge under the kernel lock.** Repeatedly take the kernel lock and
   classify every live thread of every image (§3.2). If every thread is
   restorable, no vCPU creation is pending and no waiter has been woken but
   not yet returned (a woken waiter may have been handed a message, a
   semaphore unit or a workqueue assignment), keep the lock and go on.
   Otherwise release the lock (threads still in a handler finish their trap
   and reach a gate or a wait) and retry after 1 ms. The default deadline is
   5 s.
4. **Host services idle.** Still under the kernel lock: no host service
   holds a message it received and has not finished (a request whose client
   waits for the reply, a hand-shake, a no-senders notification). A service
   receives with *tracking*: the message counts as in hand from the moment
   it leaves the queue, under the kernel lock, until the service has replied
   and updated its tables (`MachHostTask.receive(on:timeout:tracked:)`,
   `finishedMessage()`); the Metal service's queued requests count until
   their queue has run them. The Metal service also has no command buffer
   whose completion event is not sent. Otherwise retry, as in step 3.
   Then the state of the services whose tables mirror guest-visible Mach
   state (IOSurface, Metal) is read; a service lock that is taken (a service
   takes its own lock before the kernel lock) is only tried, and a failed
   try is a retry. The Metal back end is settled (queued uploads submitted,
   device idle) and the contents of GPU-only textures and buffers are read.
   Services whose state is plain data (the device session, SCDynamicStore)
   are read before step 1 with no kernel lock held.
5. **Capture** (§6) with the kernel lock held. Guest memory is read through
   the VMM's host mappings; no vCPU runs.
6. **Release**: either resume (clear the pause flag, wake the gates; the
   simulator continues as if nothing happened) or end the host process
   (`YCODE_SNAPSHOT_EXIT=1`).

Time stands still for the guest while it is paused only if the counter is
also stopped; the prototype does not stop it (a pause of tens of ms looks
to the guest like a scheduling delay).

### 3.2 Thread states at the quiesce point

| State | Meaning | Recorded frame | Restore |
|---|---|---|---|
| `pendingTrap` | parked at the trap gate | the frame as the shim stored it | the new vCPU handles this trap first |
| `resume` | parked at the run gate at EL0 | frame from the vCPU registers | the new vCPU returns to EL0 with this frame |
| `blocked(trap)` | sleeping in a kernel wait (`blockedInKernel`, not woken) | the trap's entry frame (`entryFrame`), rewritten by §4 | as `pendingTrap` |
| `suspended` | created with `PTHREAD_START_SUSPENDED`, never run | none: its start state is kernel state | as before the snapshot (`thread_resume` starts it) |
| `unstarted` | the main thread of an image launched suspended that has not been resumed: a job in its start hold (`scheduling-policy.md` §4.2) or a POSIX_SPAWN_START_SUSPENDED spawn | its start state (pc, sp, x0–x30, TPIDRRO_EL0, TPIDR_EL0) | the image stays suspended with that start state; resuming it (the hold's release, `task_resume`) starts the thread. A held process's hold is recorded (time held so far, label) and held again after the restore, with the time already held counted |

Any other thread (in a handler, waiting for the kernel mutex, inside a
lock-free I/O section, between creation and its first run) is *unsettled*
and makes step 3 retry.

### 3.3 Why no wakeup is lost

The snapshot is taken with the kernel lock held, and every `WaitQueue`
operation needs the lock. A thread counted as `blocked` has a registered
waiter with no result, so no wake has happened for it; any wake after the
capture happens in the live system only, and in the restored system the
thread re-runs its trap and re-checks the condition (a message that arrived,
a semaphore that was signalled) before it sleeps again. A woken-not-returned
waiter is never captured (step 3).

### 3.4 Refusals

A snapshot fails, the simulator continues, and the report lists:
unsettled threads after the deadline (with their trap numbers), threads
blocked in a non-restartable trap (§4.3), and objects of an unsupported kind
(by kind and count: host sockets, unlinked files, Metal processes with live
objects when §8's replay is not enabled, any record kind the running build
cannot encode).

## 4. Restarting blocked traps

The kernel state is recorded as if the blocked trap had not begun; on
restore the thread issues it again. For each blocking trap: which
side effects happen before the thread sleeps, and how the snapshot undoes
them. Trap numbers as in `darwin-trap-tables.md`.

### 4.1 Restartable without changes

| Trap | Pre-wait side effects | Normalization |
|---|---|---|
| `mach_msg`/`mach_msg_overwrite`/`mach_msg2` receive only (−31, −32, −47 with `MACH_RCV_MSG` and no `MACH_SEND_MSG`) | `waitingReceivers` of the port or set | count 0 |
| `semaphore_wait`, `semaphore_timedwait` (−36, −38) | none | — |
| `__ulock_wait`, `__ulock_wait2` (515, 544) | the queue exists | waiters 0, owner kept |
| `mach_wait_until` (−90) | none; the deadline is absolute guest time (§5) | — |
| `thread_switch` with a wait option (−61) | none | — |
| `select`, `pselect`, `poll` and `_nocancel` forms (93, 394, 230, 407, 395, 417) | readiness observers on the watched objects | observers are rebuilt by the restarted call |
| `wait4`, `waitid` and `_nocancel` (7, 173, 400, 416) | none | — |
| `read`, `readv`, `recvmsg`, `recvfrom` and `_nocancel` on pipes and sockets (3, 120, 27, 29, 396, 411, 401, 403) when nothing was transferred | readiness observers | — |
| `flock`, `fcntl(F_SETLKW)`, `sem_wait` (131, 92, 271, 406, 420) | none | — |
| `kevent`, `kevent64`, `kevent_qos`, `kevent_id` (363, 369, 374, 375) waiting for events (a scan wait) | the change list was applied | rewrite `nchanges` (x2) to 0 |
| `workq_kernreturn(WQOPS_THREAD_RETURN)` (368) of a worker parked idle | the worker's binding was dropped, its kevent run ended, it joined the idle list | record the worker as running and not idle; the restarted return parks it again |

### 4.2 Restartable with a rewrite

| Trap | Blocked in | Rewrite of the entry frame |
|---|---|---|
| `mach_msg`/`mach_msg2` with send and receive | the receive phase (the thread is in a port's or set's receive queue, so the send completed) | clear `MACH_SEND_MSG` (bit 0) in the options register (x1) |
| `mach_msg`/`mach_msg2` send blocked on a full queue | the send (the message is copied in; the send loop keeps it on the port while it waits) | the message is queued in the image past the limit, as if the receiver had made room; without a receive part the trap is complete (x0 = `MACH_MSG_SUCCESS`, the thread resumes after it), with one the receive restarts as above |
| `sigsuspend` (111, 410) | the wait (the call saved the process mask on the thread) | none; the image gets the mask from before the call (lowest thread id when several wait) |
| `kevent_id` with an EVFILT_WORKLOOP sync-wait change | the wait (the change made the sync knote) | none; the knote is left out of the image and the restarted call makes it again (the wait is the call's last change) |
| `semaphore_wait_signal`, `semaphore_timedwait_signal` (−37, −39) | the wait (the signal happened first) | the trap number becomes −36 or −38, x0 = the wait semaphore |
| `__semwait_signal` (334, 423) with a mutex semaphore | the wait | the mutex argument becomes 0 |

Timeouts given as a relative interval restart with the full interval. This
is a deviation of at most one interval for a thread that was mid-wait;
Darwin allows spurious delays of that kind.

### 4.3 Not restartable

| Trap | Why |
|---|---|
| `write`/`writev`/`sendmsg` blocked after a partial transfer | the transferred count is on the handler's stack |
| any blocking trap not listed in §4.1 or §4.2 | unknown side effects |

At the home screen (§10.2) the blocked threads were: Mach receive 194,
workqueue idle park 111, `sigsuspend` 77, `semaphore_wait` 13, blocked sends
queued 4, `ulock_wait` 3, `__semwait_signal` 1; none was refused.

The snapshot retries until such threads move on (§3.1 step 3).

## 5. Clock continuity

The guest's `mach_absolute_time` is the guest virtual counter, which is the
host counter minus a system offset (`ImageLauncher.systemClock`): every VM
of a system shares one offset. Kernel deadlines are host monotonic
nanoseconds.

- Capture: `G` = the guest counter at the snapshot, `H` = host monotonic ns
  at the snapshot. `G`, the boot counter and the frequency in the clock
  record are in **counter units** (host counter − system offset, at
  `CNTFRQ_EL0`), not in mach-time units: with the 24 MHz guest timebase
  (`darwin-process-start.md` §5) mach time is the counter scaled
  (`fast-traps.md` §3.2), and the restore sets a counter offset. Mach-time
  values in other records (process start/exit times) are in mach units and
  stay valid, because the scaled clock continues from the scaled `G`.
- Restore: before the first VM is built, the system offset is set to
  `hostCounter() − G`, so the guest counter continues at `G` (it never goes
  backwards; the time the snapshot sat on disk does not exist for the
  guest). Every VM's virtual counter is aligned to it with
  `KVM_REG_ARM_TIMER_CNT` as today.
- Every host-ns deadline `d` in a record (EVFILT_TIMER knotes, mk_timers,
  workqueue idle deadlines) is rebased to `d − H + now`, except a
  calendar-time EVFILT_TIMER (`NOTE_ABSOLUTE` without `NOTE_MACHTIME`: its
  `data` is wall-clock time since 1970, `threads-and-events.md` §3.7.2):
  its deadline is computed again from its `data` and the wall clock at the
  restore, as at its registration, so it fires when the calendar reaches
  its time (at once if the calendar passed it while the snapshot sat on
  disk). libdispatch's wall-clock timers (`dispatch_walltime`) are of
  this kind. (Phase 6, RESTORE-HARDEN, §12.5.)
- Calendar time (`gettimeofday`) is the host's wall clock: it jumps forward
  by the time between snapshot and restore, as after a laptop sleep. The
  commpage wall-clock snapshot (`fast-traps.md` §4) of every restored image
  is taken again before the restored threads start: the restored page
  pairs the capture's mach time with the capture's calendar time, which
  would give the old time for up to one second.
- `kern.boottime` stays the boot's value.

## 6. Format

A snapshot is a directory:

| File | Content |
|---|---|
| `manifest.ysnap` | header, then records |
| `pages-<image>.ypages` | the page file of one image (its private memory) |
| `shm-<id>.ypages` | the pages of one shared memory object |
| `device/` | device mode: the copy of the device directory (§2.7) |
| `device-path` | device mode: the device directory's host path, one line |
| `device-inodes` | device mode: one entry per file of the device directory, `<inode as the guest saw it>` TAB `<path relative to the device directory>` NUL |

### 6.1 Manifest

All integers little-endian.

- Header (32 bytes): magic `"YCSNAP\0\x01"` (8 bytes), format version (u32,
  currently 1), flags (u32), creation wall time (u64 seconds), record count
  (u64).
- Record: kind (u16), record version (u16), reserved (u32), id (u64),
  payload length (u64), payload.
- Payload: a sequence of fields, each a tag (u16), a type (u8) and a
  value. Types: 1 u64, 2 i64, 3 bytes (u32 length + bytes), 4 string (as
  bytes, UTF-8), 5 u64 list (u32 count + values), 6 reference (u64 record
  id, 0 = none), 7 nested payload (u32 length + fields), 8 list of nested
  payloads. A reader skips fields with unknown tags; a record kind it does not
  know makes the restore fail (unless the kind is marked optional by bit 15
  of the kind).
- Record kinds (prototype numbering): 1 system, 2 process, 3 image, 4
  thread, 5 region, 6 shared memory object, 10 Mach space, 11 port, 12 port
  set, 13 message (nested in its port), 14 semaphore, 15 ulock, 16 mk_timer,
  20 open file description, 21 host file, 22 pipe, 23 kqueue, 24 knote,
  25 workqueue, 26 unix socket, 27 POSIX shm segment, 28 POSIX named
  semaphore, 30 clock, `0x801F` host service (optional), `0x8020` census
  (optional).
- System record (kind 1) field 17: the CPU features the snapshot's guests
  were told (16 bytes: the `hw.optional.arm.caps` bits 0–127 as two
  little-endian u64). A restore on a host whose derived feature set lacks
  one of them is refused (`cpu-features.md` §9.4); the warm-boot launcher
  then boots cold. A snapshot without the field restores as before.
- Host-service record fields: 1 the service name (string); for
  `device-session` 2 the control channel and 3 the session port (host-task
  port names, u64); for `metal` 4 the guest pids of the client processes
  (u64 list). Their ids are 9 000 000 + n; the service state is read before
  the quiesce, with no kernel lock held, so a service's own lock never nests
  inside the kernel lock.

Records may refer to any other record (the object graph has cycles: a port
names its receiver space, the space's table names the port). Ids are
assigned in a first pass over the live objects and the records are written
in a second; the restore makes an empty object for every record before it
fills any (§7 step 6), so the order of records does not matter. Region
records (kind 5) carry their image's record id; the image's pages are in
`pages-<image record id>.ypages`.

Host-service records (kind `0x801F`), by service name: `device-session`
(fields 2, 3), `metal` (field 4, the client pids), `scdynamicstore` (field 5:
one nested entry per session, 1 the session port, 2 the notify rights),
`iosurface` and `metal-objects` (field 6: the service's own state, a nested
payload with the service's tags: `IOSurfaceHostService.SnapTag`,
`MetalHostCore.SnapTag`, `MetalRecipe.Tag`).

### 6.2 Page files

- Header (32 bytes): magic `"YCPAGES1"`, page size (u32, 16384), flags
  (u32), extent count (u64), data offset (u64).
- Extents: (va u64, page count u32, flags u32) each; pages of one extent are
  contiguous in the file, in extent order, starting at the data offset
  aligned to 16 KiB (so a future restore can `mmap` them).
- Only resident, non-zero pages are written; zero pages are implied by the
  replayed mapping.

### 6.3 Lazy restore

With `YCODE_RESTORE_LAZY=1` the page files are not read at restore. For each
run of consecutive saved pages that lie in one region and in the anonymous
pool or a private file mapping (the private file window, a file memslot),
the host memory behind the run is replaced by a private, writable mapping of
the page file at the run's file offset (`mmap(MAP_PRIVATE | MAP_FIXED)`;
the data offset and every page are 16 KiB aligned, so every run is a valid
mapping). The host kernel reads a page when the guest (or the VMM) first
touches it, and a write copies it (copy-on-write); the page file is never
written. Pages elsewhere (the read-only file window, which needs a private
copy first) are copied as before. A home-screen snapshot maps about 98 % of
its pages this way, in about 35 000 runs (about 35 000 host mappings; the
host's limit, `vm.max_map_count`, is 1 048 576 on the Thor).

Two rules keep the mapped memory correct:

- **Discard.** Pool memory that the guest frees is normally returned with
  `MADV_DONTNEED`; on a private file mapping that brings the *file's* bytes
  back instead of zeros. A backing with page-file mappings (`hasOverlays`)
  therefore discards by mapping fresh anonymous memory over the range
  (`MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED`).
- **Snapshot of a restored run.** An untouched page of a page-file mapping is
  not anonymous memory and may not be resident, so `mincore` and the page
  map would call it absent or clean. The ranges mapped from page files are
  remembered, and a later snapshot counts their pages as resident and dirty.

`YCODE_RESTORE_PREFETCH=1` adds a background request to the host to read
every page file ahead (`POSIX_FADV_WILLNEED`), so first touches find the
pages in the page cache. The page files must stay unchanged while a run
restored from them is alive.

## 7. Restore order

1. Read and validate the manifest (versions, the runtime root and shim
   paths it names, host file sizes and mtimes).
2. Set the system clock offset (§5).
3. Build the `DarwinSystem`, the `MachIPCSystem` and the host task; restore
   system counters and the boot UUID/salt.
4. For each process in pid order: the `DarwinProcess` record. For each live
   image: a `DarwinKernel` with a fresh file system over the run's prefixes,
   then the image is launched through the normal launcher **suspended**
   (start-suspended request): the VM, the address space with its permanent
   regions, the vCPU pool and the kernel wiring are built as for a new
   process, but no thread runs.
5. Memory: unmap every non-permanent region of the new address space;
   create the shared memory objects; replay every region record in VA order
   (anonymous, file by host path, shared object); write the page files.
6. Kernel objects, bottom-up: host files and open file descriptions; pipes,
   sockets, kqueues; ports and port sets (with fresh serials); messages;
   Mach spaces (the name table exactly, then `reverse`); task and thread
   kernel ports (filled into the instances the space created); semaphores,
   ulocks, timers (rebased deadlines); knotes, re-registered with their
   objects (observers); the workqueue; extended BSD state; descriptor tables.
7. Back-references: receivers, transit holders, EVFILT_PROC watchers, socket
   peers.
8. Host services: their loops start as for a boot (their ports get the
   recorded names, §9); the device directory is not prepared again (TMP,
   the job directory and the plists stay as the snapshot left them; only
   the app to install and the `ylaunch` helper are staged). Before any
   guest thread starts, the services take their records back: the
   SCDynamicStore sessions, the IOSurface tables, the Metal tables with the
   replay of every object (§8 option 2, IOSurface first: textures over
   surfaces resolve the surface by its port); the device session adopts
   the recorded session port and runs `--install-app` / `--launch` as
   after a boot.
9. Threads: for each `pendingTrap`, `blocked` or `resume` thread, start a
   vCPU at an EL0 address that holds an `svc #0x80` (the first one in the
   Ycode host page's code). When that first trap arrives, the restore hook
   writes the thread's FP/SIMD registers into the vCPU, replaces the frame
   with the recorded one, and either resumes it (`resume`) or passes it to
   the kernel as a new trap (`pendingTrap`, `blocked`). Suspended threads
   stay unstarted. **Start gate:** the hook first waits until every
   restored thread has its vCPU and steps 10 and the kills of §8 option 1
   are done; only then does any restored thread run. Otherwise guest code
   running during the starts (a thread restored at its own `exit`, or
   restored threads of other processes that make a process exit) could end
   a process while its other threads were still waiting for their start,
   and those starts would find the process's vCPU pool ended (§12.1). A thread whose process has already ended is not started
   (it is reported); a start that finds no vCPU for a live process fails
   the restore, with the pool's counts. From the start of the restore to
   the end of this step the kernel starts **no new thread** (a workqueue
   request that arrives meanwhile stays pending for step 10; §12.4 item 5).
10. Clear `startSuspended` state of processes that were running; the
   supervisor runs as after a boot. Then, under the kernel lock, every
   process issues the thread requests its restored knotes call for (each
   workq bucket and workloop is re-evaluated as after an activation) and
   hands pending requests to workers: a request issued before the snapshot
   whose worker had not started, or an activation the capture did not see,
   would otherwise wait for the next activation of the same bucket, which
   may never come. The start holds of the snapshot are held again (§3.2).

## 8. GPU-dependent processes

The Vulkan back end's objects cannot be saved. Three options, in order of
effort:

1. **Restart the GPU clients.** Every process with a Metal host-service
   process record is not restored; instead its pid is restored as a zombie
   that exited with SIGKILL, so launchd_sim sees a crash and relaunches the
   job (its KeepAlive policy). For the home screen these are the render
   server (backboardd) and anything that renders with Metal directly
   (SpringBoard's layers are rendered by backboardd). A crash of backboardd
   takes SpringBoard and its clients down with it, so this option costs a
   restart of the UI stack. Its cost is the share of a boot that the UI
   stack's start takes (§10.3).
2. **Replay.** The Metal service keeps, per object, the creation request it
   received (descriptor dictionaries, shader source or library bytes,
   pipeline descriptors) and for buffers and textures that are not backed by
   guest shared memory their contents at snapshot time (read back with a
   blit). The restore re-creates every object in creation order on the new
   back end, maps old handles and GPU addresses to new ones, and refills the
   contents. Command buffers in flight are finished before the snapshot
   (the quiesce waits for `completed` events).
3. **Re-render.** As 2 without contents: only render targets that are
   redrawn every frame (the display's drawables) are safe to drop.

Recommendation: option 1 first (no new GPU code; it proves the rest of the
restore), then option 2 for the render server alone.

**Option 2 as implemented (phase 3).** Every object the Metal service makes
keeps a *recipe*: the message type and record op of its creation request,
the record bytes (descriptors, the function's metallib), the buffer length
and options, the memory entry or IOSurface port it was made over, the
plane, and the handles it named (a view's parent, a pipeline's functions,
with the function refs as they resolved). A released object that a live
recipe names (a pipeline's function the client released) keeps its recipe
until no live recipe names it. Queues, heaps, argument layouts and encoders
have no back-end object and need only their table entries.

At the snapshot (§3.1 step 4) the service's tables and recipes are recorded,
and with the device idle the contents of the objects that live only in GPU
memory are read: textures made by op 1 (`newTexture`) and op 21 (heap
textures), every level and slice, for formats with a plain byte size and one
sample; buffers the back end allocated itself (not over guest memory), from
their host-visible mapping. IOSurface textures, buffers over guest memory and
texture views need nothing: their bytes are guest memory or another
texture's. Multisampled and block-compressed textures, and any texture
whose read-back fails (depth/stencil targets), are not read: they are render
targets that are redrawn, and are counted as "not readable" (2 at the home
screen).
A home screen has 10 Metal client processes with 173 objects and 26 MB of
texture contents.

At the restore the tables come back unchanged (guest refs, handles, the next
handle, the GPU addresses the service chose, event values, heap
accounting), and every recipe is replayed on the new back end under its old
handle, in handle order (a dependency always has a lower handle), followed
by the contents (`replaceRegion` per level and slice, or a copy into the
buffer's mapping); kept recipes of released objects are released again
after the replay. The client processes, backboardd among them, are not
restarted and see no difference, with two exceptions that the restore
counts and reports: a buffer's GPU address that the back end chooses
(Vulkan buffer device addresses differ in a new device) and a sampler's
resource ID. A guest that read such a value (op 38, op 39) and stored it in
GPU-visible memory would see stale values; at the home screen no client had
read a buffer address (the 39 changed addresses were never queried).

## 9. Prototype (phase 2)

Behind environment variables, all default off:

| Variable | Effect |
|---|---|
| `YCODE_SNAPSHOT_DIR=<dir>` | where a snapshot is written |
| `YCODE_SNAPSHOT_AT_MS=<ms>[,<ms>…]` | take a snapshot that many ms after the root process started (several: one subdirectory each) |
| `YCODE_SNAPSHOT_WHEN_FILE=<host path>` | take a snapshot `YCODE_SNAPSHOT_DELAY_MS` (default 300, at most 60 000) after that file appears (a guest test creates it in its `/tmp`; the benchmark harness's home-screen result file) |
| `YCODE_SNAPSHOT_DEADLINE_MS=<ms>` | how long the quiesce loop retries (default 5000) |
| `YCODE_SNAPSHOT_EXIT=1` | end the host process after the snapshot (default: resume) |
| `YCODE_SNAPSHOT_CENSUS=1` | quiesce, count every kind of state and the dirty memory, print the census, resume (no files) |
| `YCODE_SNAPSHOT_COPY_DEVICE=1` | device mode: copy the device directory into `<dir>/device` while paused (§2.7) |
| `YCODE_RESTORE_DIR=<dir>` | `--exec`/`--device`: restore the snapshot instead of spawning the root process |
| `YCODE_RESTORE_MEASURE=1` | restore images, memory and kernel objects, print the timings, start no thread, exit |
| `YCODE_RESTORE_KILL=<name>[,…]` | after a restore, SIGKILL the processes with these executable names (`*text*` matches names containing text; `auto` the Metal clients of the `metal` record): §8 option 1 |
| `YCODE_RESTORE_LENIENT=1` | a host file that is gone since the snapshot does not fail the restore: an open file becomes an empty unlinked file, a shared file view plain shared memory, a file mapping anonymous memory (each is reported) |
| `YCODE_RESTORE_LAZY=1` | page files are mapped as guest memory instead of read (§6.3) |
| `YCODE_RESTORE_PREFETCH=1` | with lazy restore: ask the host to read the page files ahead in the background |
| `YCODE_SNAPSHOT_GPU=0` | do not save the IOSurface and Metal state (default: saved; a restore of such a snapshot must restart the Metal clients, `YCODE_RESTORE_KILL=auto`) |
| `YCODE_RESTORE_GPU=0` | do not restore the IOSurface and Metal state from the snapshot (diagnostics) |
| `YCODE_SNAPSHOT_HOLD_APPS=<s>` | device mode, with `YCODE_SNAPSHOT_WHEN_FILE` and `YCODE_SNAPSHOT_DIR`: the `--install-app` / `--launch` steps wait until that snapshot is written or has failed (at most `s` seconds, or until the run ends), so the snapshot shows the home screen without the app. Without `YCODE_SNAPSHOT_DIR` (with `YCODE_SNAPSHOT_STOP_DIR`): the steps wait until `YCODE_SNAPSHOT_DELAY_MS` after the file appears, and no snapshot is taken then (§12.2). Ignored in a restore |
| `YCODE_SNAPSHOT_STOP_DIR=<dir>` | device mode: SIGTERM, SIGINT or SIGHUP, or the end of `--timeout-ms`, stops the run with a snapshot: the launched app is killed (SIGKILL; it is waited for until reaped, at most 10 s), the device settles `YCODE_SNAPSHOT_STOP_SETTLE_MS` (default 2000), the snapshot is written to `dir` and the host process exits with status 0 without running another guest instruction ("snapshot: exiting after the snapshot"). No snapshot while the app steps still run, or when the quiesce fails: the guest is then shut down as at the end of `--timeout-ms` (§12.2) |
| `YCODE_SNAPSHOT_STOP_CLOSE_FDS=<fd>[,<fd>…]` | with a stop snapshot: these inherited descriptors (the launcher's device lock and boot slot) are closed after the snapshot is written, before the host process exits, so nobody waits for its teardown |
| `YCODE_RESTORE_NO_BARRIER=1` | diagnostics: the restore's start gate is off (§7 step 9: a thread runs as soon as it has a vCPU, and a start that finds its process ended fails the restore), the behavior before phase 5 |

Record kinds implemented: system, clock, process, image, thread, region,
shared memory (anonymous objects with `shm-<id>.ypages`, and shared host-file
views by path), Mach space (including the host task, §7 step 3), port with
messages, port set, semaphore, ulock, open file description, host file
(including unlinked ones), pipe, kqueue with knotes (EVFILT_USER, TIMER,
MACHPORT, READ, WRITE, PROC, SIGNAL, WORKLOOP, VNODE, FS), workqueue, AF_UNIX
socket, POSIX shm segment, POSIX named semaphore, file locks, IOKit objects,
memory entries, host services (`device-session`, `metal` client pids).
Not yet: the SCDynamicStore and IOSurface services' state (§2.6), the GPU
(§8 option 2), host stream sockets.

The host task's space is not rebuilt from scratch: the new run's services
already made their ports in the same order, so their names match the
recorded ones, and the live port and port-set objects stand for the
recorded ones (their wait counts and change stamps are kept, so service
threads blocked on them keep working; they are woken once after the
restore).

## 10. Measurements

All on the Thor (release builds, `performance` governor), 2026-10-17.

### 10.1 Test programs (`--exec`, `SimShim/guest-tests/snapshot/p_snap.c`)

| Case | State at the snapshot | Pause | Snapshot size | Restore (new host process) | Result |
|---|---|---|---|---|---|
| one process | 6 threads: Mach receive, pipe read, `ulock_wait` (condition variable), `mach_wait_until`, a sender blocked on a full queue, an FP spinner kicked out of EL0; 3 queued messages (inline, OOL 40 000 B + port right), a pipe, a semaphore, a memory entry mapped twice, 8 MiB heap | 22–28 ms | 9.4 MB (manifest 70 KiB, 588 pages) | 12–53 ms | correct result, 11 of 11 restores |
| two processes | parent in `mach_wait_until`, child blocked in a Mach receive, 2 replies queued in the parent's port | 14 ms | 2.1 MB | 14–33 ms | correct result (cross-process messages, wait4, exit status), 11 of 11 |

A snapshot that resumes the live run instead of exiting leaves the program
correct as well.

### 10.2 Home screen (`--device`, 600 s into a boot)

| Quantity | Value |
|---|---|
| live images / processes | 268 / 269 |
| threads | 434: 403 blocked (restartable), 29 at the trap gate, 2 kicked out of EL0 |
| Mach | 269 spaces, 28 506 names, 22 641 ports, 311 port sets, 239 queued messages (32 KiB), 812 semaphores, 340 mk_timers |
| BSD | 2 793 descriptors, 2 788 open file descriptions, 1 702 host files, 262 AF_UNIX sockets, 408 file locks |
| kqueues | 5 533 kqueues, 11 526 knotes (7 636 EVFILT_MACHPORT, 1 788 VNODE, 1 056 PROC), 150 workqueue workers |
| shared memory | 662 objects, 190 MB |
| memory | 27 579 regions; 194 856 pages saved = 3.0 GB (137 212 anonymous, 52 915 copy-on-write file pages, shared 17 463); 56.6 M pages of read-only file views not saved |
| largest images | SpringBoard 96 MiB, Unity2025Poster 42, PosterBoard 38, homed 32, backboardd 30 |
| quiesce | 0.7–0.8 s (3–5 attempts) |
| capture | kernel records 0.3 s, memory scan 0.4 s, writing 3.1 GB 3.3 s (page cache) to 44 s (busy disk); manifest 21 MB, 63 546 records |
| restore, measured (`YCODE_RESTORE_MEASURE`) | 268 images rebuilt 1.4–2.2 s, 27 579 regions replayed and 2.97 GB of pages written 4.9–6.4 s (serial, one thread) |

### 10.3 Restarting the UI stack

`launchctl kickstart -k system/com.apple.backboardd` in a booting device
(at 515 s, the boot logo still showing): the display went black and the home
screen appeared 160 s later (frames every 5 s). This is the price of §8
option 1 for the render server today; the poster extensions and the widget
renderer (the other Metal clients at the home screen: 10 processes with
6–52 Metal objects each, backboardd 115) are relaunched on demand.

### 10.4 Home screen: snapshot, restore, time to the home screen

Agent SNAPb, 2026-10-17, one build (merge of the prototype with the lean
boot work; no lean profile, default boot). The Thor was shared: three other
agents' boots and builds ran at the same time (load average 12–15), so
every number below carries that noise. The time to the home screen is the
time to the first frame brighter than 60 (the harness's rule: the boot logo
is about 3, the wallpapered home screen about 133); frames every 5 s for a
cold boot, every 2–5 s after a restore.

Snapshots: a cold boot, then a snapshot 60 s after the harness saw the
home screen (`YCODE_SNAPSHOT_WHEN_FILE` = its result file,
`YCODE_SNAPSHOT_DELAY_MS=60000`, `YCODE_SNAPSHOT_COPY_DEVICE=1`,
`YCODE_SNAPSHOT_EXIT=1`).

| | c1 | c2 |
|---|---|---|
| cold boot to the home screen | 465 s | 570 s |
| images / threads at the snapshot | 262 / 397 | 259 / 394 (378 blocked, 16 parked) |
| quiesce | 973 ms (4 attempts) | 256 ms (1 attempt) |
| kernel records, memory scan | 0.3 s, 0.7 s | 0.3 s, 0.5 s |
| pages written | 2 979 MiB in all with the manifest (20.8 MB, 61 703 records) | 2 992 MiB (manifest 53 MB, 61 470 records) |
| device directory copy | 9.7 s | 19.4 s |
| total pause | 14.7 s | 25.5 s |
| size on disk | 3.6 GB (pages 2.9 GB, device copy 0.65 GB) | 3.6 GB |

Restores (`YCODE_RESTORE_KILL=auto,SpringBoard`, `YCODE_RESTORE_LENIENT=1`):

| Run | Snapshot, device directory | Restore (images, memory, objects) | Home screen after the restore | Wall time to the home screen | Notes |
|---|---|---|---|---|---|
| r1 | c2, in place | 5.8 s (1.7, 3.8, 0.2) | 230 s | 236 s | app install started (`--install-app`): the home screen showed the app's "Installing…" placeholder; not finished after 900 s |
| r2 | c1, in place | 6.4 s (1.5, 4.5, 0.2) | 150 s | 158 s | also killed installcoordinationd and installd; the session's first spawn request (704) was never answered (the send blocked until the run ended) |
| r3 | c2, from the copy | 71.4 s (1.6, 69.4, 0.2) | 160 s | 232 s | 15 381 files kept their recorded inodes; no SQLite errors; 3 guest crashes (a cold boot has 41–44) |
| r4 | c1, from the copy | 55.3 s (1.5, 53.4, 0.2) | 215 s | 271 s | 15 337 files kept their recorded inodes; app install spawned at once, the request reached installcoordinationd, not finished after 990 s (then the shared data disk filled up and the run's output stopped) |
| rest2 (agent SNAP) | an earlier snapshot, a device directory that did not match | 13.2 s | ≤ 80 s (10 s frames) | ≤ 93 s | SQLite "readonly database moved" (error 1032) crash loop in one daemon: the reason for `device-inodes` (§2.7) |

Findings:

- **The restore itself takes 6 s** when the page files are in the host's
  page cache, and 55–71 s when they are read from the shared, busy disk
  (2.9 GB at 40–55 MB/s). Reading the pages is the whole difference: §11
  item 6 (`mmap` of the page files, compression, parallel reads) is the next
  speed step.
- **The UI-stack restart (§8 option 1) dominates the time to the home
  screen**: 150–230 s after the restore on the loaded host, about 80 s in
  the earlier, quieter run. The restored daemons need no restart; the
  render server, SpringBoard and the Metal clients start again as after a
  crash. Wall time to the home screen: 158–236 s from a restore against
  465–570 s for a cold boot (1.7–3.6× faster; with a quiet host and page
  files in memory, about 90 s against about 500 s).
- **What works after a restore**: SpringBoard draws the wallpapered home
  screen with its icons (frames checked); launchd_sim keeps running its
  jobs (crash-looping daemons are relaunched as in a cold boot);
  the device session is adopted and launchd_sim serves its control
  requests (one-shot spawns); the app install reaches installcoordinationd
  and SpringBoard shows the placeholder.
- **What does not work yet**: the app install did not complete in any
  restore run (r1: 900 s, r4: 990 s; a lean cold boot installs the same
  app in about 240 s), so the app launch after a restore is untested;
  one restore (r2) never got an answer to its first control request. The
  cause is not known yet; candidates are restored daemons whose host-side
  partners lost state (the SCDynamicStore and IOSurface services are not
  saved, §2.6) and restored waits in the install path.

### 10.5 Warm boot: restore with the UI kept, lazy page files (phase 3)

Agent SP-SNAP, 2026-10-19, release builds of the main line 34e5bb1 (start
holds on) plus this work, on the shared Thor (load 8–20 from other agents'
boots). Snapshot: a cold boot, then a snapshot 60 s after the home screen,
written to the RAM tmpfs (`/run/user/<uid>`) or copied to the USB data disk.
Every restore runs `--install-app` (the probe app) and `--launch` with
`YCODE_RESTORE_LAZY=1`, no `YCODE_RESTORE_KILL` (the UI processes keep
running), `YCODE_RESTORE_LENIENT=1`. Times are wall seconds from the start
of `ycode-simd`. "Home screen" is the first of two frames in a row brighter
than 60 (frames every 2 s); after a restore the display surface is restored
too, and that the UI is live shows in the frames that follow (the install's
"Installing…" placeholder icon drawn by SpringBoard, rendered by backboardd)
and in the launch.

| Quantity | Value |
|---|---|
| snapshot at the home screen | 247 images, 549 threads (12 unstarted: start holds), 178 496 pages (2.7 GiB) saved, 11 Metal client processes with 168 objects and 36 MiB of texture contents, 7 IOSurfaces, 1 SCDynamicStore session |
| snapshot pause, written to tmpfs | 3.9 s in all (quiesce 0.3 s, records 0.2 s, memory scan 0.6 s, files 2.8 s with the device copy 1.0 s); 3.5 GB in tmpfs |
| snapshot pause, written to the USB disk | 96–108 s (the device copy alone 85–95 s) |

| Run | Snapshot on | Restore (images, memory) | Home screen | App installed | App launched |
|---|---|---|---|---|---|
| t1 | tmpfs, lazy | 6.3 s (1.9, 3.9) | 8.8 s | 41.4 s | 45.4 s |
| t2 | tmpfs, lazy | 6.8 s (2.1, 4.0) | 9.3 s | 48.8 s | 55.1 s |
| t3 | tmpfs, lazy | 6.7 s (2.0, 4.1) | 9.3 s | 45.0 s | 50.0 s |
| d1 | USB disk, page cache dropped, lazy | 14.7 s (4.0, 10.4) | 17.1 s | 81.7 s | 87.7 s |
| d2 | USB disk, page cache dropped, lazy | 14.9 s (4.0, 10.7) | 17.4 s | 81.9 s | 86.9 s |
| e1 | USB disk, page cache dropped, pages read up front | 99.8 s (5.6, 94.0) | 102.2 s | 120.2 s | 124.2 s |
| cold boots (3) | — (no app) | — | 182–207 s | — | — |
| cold boots with the app (3) | — | — | not reached | 93–219 s | 417 s in 1 of 3 (start holds off); never in 2 |

The cold boots with `--install-app` (the install starts as the first
one-shot, before SpringBoard runs) never showed the home screen within
840–900 s: 200–380 guest faults, mostly NSException aborts, in all three
runs, with the start holds on or off. That is a main-line problem of the
cold boot, outside this work; after a restore the same steps take 45–55 s.

Findings:

- **No UI restart.** With the IOSurface and Metal state restored (§8
  option 2) backboardd, SpringBoard and the other Metal clients keep
  running: their 168 objects are made again in 0.2–0.4 s, and the home
  screen is live as soon as the restore ends (against 150–230 s for the
  restart of option 1, §10.4).
- **Lazy page files.** 98 % of the saved pages are mapped from the page
  files (about 37 000 mappings); the restore no longer reads 2.7 GiB. From
  the USB disk with a cold page cache the restore takes 15 s instead of
  100 s; the guest then faults pages in as it touches them, which costs the
  install and launch about 35 s against tmpfs. From tmpfs the restore is
  6.3–6.8 s: image builds 2 s, region replay 1.3 s, mapping the page files
  1.8 s, the shared objects 0.8 s (copied). Restoring the images' memory on
  several threads was slower (6.7 s against 4.0 s): the host mappings
  serialize on the process's memory-map lock.
- **App install and launch after a restore work** (6 of 6 runs). The
  blocker of §10.4 was a lost thread request in Ycode's kevent workqueue
  (`threads-and-events.md` K5): a worker that unbound itself early released
  its delivered knotes at its return without re-evaluating their bucket, so
  a message that had arrived meanwhile (filecoordinationd, servicing lsd for
  installcoordinationd) was never delivered. It was not restore-specific but
  the restored timing made it certain. The restore also reissues every
  thread request its knotes call for (§7 step 10), rebuilds importance
  (§2.4) and keeps the start holds (§3.2).
- **Tmpfs.** The Thor's tmpfs (13 GB, about 7–11 GB free while other agents
  run) holds one home-screen snapshot (3.5 GB with the device copy). It is
  the fast path: both the snapshot pause (4 s) and the restore (7 s).

## 11. Staged plan

1. Census at the home screen (counts, dirty memory per process,
   unsupported kinds). **Done.**
2. Single-process restore (threads, ports, pipe). **Done.**
3. Multi-process restore (Mach messages between processes, spawned
   children, zombies). **Done.**
4. Device-mode records: the host task (**done**), AF_UNIX sockets, the
   remaining knote filters, file locks, POSIX objects, IOKit (**done**); the
   device session (**done**: adopted after a restore); the device directory
   with recorded inode numbers (**done**); SCDynamicStore, IOSurface
   (surfaces, connections; their memory is already shared memory).
5. GPU option 1: restart the Metal clients; measure restore-to-home time.
   **Done** (§10.4); app install after a restore does not complete yet.
6. Faster capture and restore: `mmap` of page files with copy-on-write
   instead of copying (**done**, §6.3); snapshots in tmpfs (**measured**,
   §10.5); parallel page-file I/O (tried: slower, §10.5); compression; memory
   shared by all processes (the shared cache's clean `__DATA` pages)
   deduplicated; the image builds (2 s) and region replay (1.3 s).
7. GPU option 2 (replay) for every Metal client (**done**, §8, §10.5), with
   IOSurface and SCDynamicStore state; app install and launch after a
   restore (**done**). Open: buffer GPU addresses and sampler IDs that the
   back end chooses differ after a replay (counted; no client at the home
   screen had read one); Vulkan capture/replay addresses would keep them.
8. The IDE's warm boot (§12): default restore path (phase 4, **done**);
   restored threads start behind a gate (**done**, §12.1); the device
   keeps its state between runs, saved at each stop and restored in place
   (**done**, §12.2).

## 12. The IDE's warm boot

The IDE's run on the remote simulator restores a snapshot by default
(`specs/ide/run.md` §Warm boot); the policy lives in the host-side
launcher `ycode/scripts/ycode-sim.sh`, and `ycode-simd` provides the
mechanisms (§9: `YCODE_SNAPSHOT_STOP_DIR`, `YCODE_SNAPSHOT_HOLD_APPS`,
`YCODE_RESTORE_*`). Per device, under the launcher's data directory (the
data volume, never the system disk):

| Path | Content |
|---|---|
| `snapshots/<device>/current/` | the snapshot (§6, with `device-path` and `device-inodes`; no device copy) and `ycode-warm.stamp`: line 1 the fingerprint, line 2 the capture time, line 3 the snapshot's id |
| `snapshots/<device>/device-sync` | the id of the snapshot whose state the device directory is in; absent while a run uses the device or after a run that ended without a save |
| `snapshots/<device>/device-ino` | the inode number of the device directory the snapshot belongs to (a different or missing directory: erased or replaced) |
| `snapshots/<device>/.lock` | `flock`: held from the start of a run until its save is in place (the launcher, `ycode-simd` and the save job share it) |
| `runs/<device>/` | the last run's frames; `logs/<time>-<mode>.txt`, the last 10 runs' logs (`log-cold.txt` / `log-restore.txt` link to the latest of each mode); `crashes/`, the last 10 host crash reports with their symbolized copies (§12.5); `ycode-sim.log` |

**Per runtime and device type (IOS27, 2026-10-27).** The IDE gives every
runtime root and device type its own device directory (`specs/ide/run.md`
§Runtimes and device types), so snapshots, saves and erases are per
runtime and type by the device name; the fingerprint also holds the runtime
root, `--device-type` and the runtime's `ProductName` and
`ProductBuildVersion`. `ycode-simd` refuses a device on an older runtime
than the one it last booted (`DEV/ycode-runtime`, `ipad.md` §9.2), so a
snapshot can never be restored onto another runtime's device data. The GPU
caches stay shared between runtimes (content-keyed).

### 12.1 "no vCPU for thread N" (closed)

Two of six restores of good snapshots (IDE-WARM, 2026-10-19) failed with
"pid P: no vCPU for thread N" about 14 s into the restore, and the
launcher booted cold instead (about 100 s more).

**Cause** (from the code, then reproduced below; the logs of the two
IDE-WARM failures were not kept). §7 step 9 started the restored threads
one by one, and each thread ran as soon as its vCPU existed: a prebuilt
VM's precreated vCPUs (C22, `YCODE_VCPU_PREBUILT`) and the creator threads
make that immediate. `VCPUPool.start` returns nil both when the pool is
exhausted and when it has ended, and a process's pool ends as soon as the
process ends. So guest code that ran while the loop was still going could
end a process whose threads came later in the loop — a thread restored at
its own `exit` or a fault, or (the case observed) a process told to exit
by restored threads of other processes — and the next start of that
process failed the whole restore. Whether a snapshot fails depends on
what its capture caught (a process close to exiting), less on the load at
the restore: the failing snapshot below failed 3 of 3 times at load 10. The
other candidates do not fit: a process holds no more live threads than
its pool has vCPUs (each live thread owns one; suspended and unstarted
threads are not started again, and a capture waits for pending vCPU
creations), the precreated vCPU 0 is an idle vCPU like any other, and
creations during the restore only reserve indices below the capacity.
The error text now gives the counts (restored threads of the process,
vCPUs, capacity, parked) and why the pool ended.

**Fix.** The start gate (§7 step 9, `SnapshotRestoreStartGate`): every
restored thread waits at its first trap until all threads have their
vCPU and the restore is complete; a thread whose process ended before it
was started is skipped and reported; only a start that finds no vCPU for
a live process fails. `SnapshotRestoreStartTests` reproduces the failure
deterministically with a model pool (a thread at `exit` that runs before
its siblings are started fails the old loop) and checks the gate. The
restore also logs the threads that restart at a trap that can end their
process (`exit`, `kill`, `__pthread_kill`, `terminate_with_payload`,
`abort_with_payload`). `YCODE_RESTORE_NO_BARRIER=1` brings the old
behavior back for comparison.

**Result.** One snapshot (a stop snapshot of a device that had run the probe
app; 257 images, 376 threads, 2.9 GiB of pages) restored 10 times in a row
from its device copy, each run installing and launching `YcodeProbe.app`
(load 25–37): **10 of 10 restored**, no fallback; restore 5.6–10.3 s
(median 8.8), home screen 8.1–13.0 s, app launched 15.0–47.7 s (median
28.1) after `ycode-simd` started. Through the launcher, every restore of
§12.3 (6 runs, one of them through the IDE) succeeded as well. **Reproduced without the gate** (`YCODE_RESTORE_NO_BARRIER=1`, three
home-screen snapshots taken 60 s after the home screen, three restores
each, load 10–37): one snapshot failed 3 of 3 times with "pid 305: no vCPU
for thread 4: 1 restored threads, pool 2 of 64 vCPUs, 0 parked (pool
ended: terminated 0 guest exited with status 0)"; the other two restored
6 of 6. The process had one restored thread, not yet started, and still
exited with status 0 on a second vCPU: restored threads of processes
started earlier in the loop (launchd_sim among them) had already run and
made it act — a new workqueue thread for a message, or a signal — and it
exited. So the cause is wider than a thread restored at its own `exit`:
any guest code that runs during the start loop can end a process whose
threads come later in the loop. The gate stops all of it: no restored
thread runs, so no guest code runs, until every start is done (the
threads the restore itself asks for in step 10 come after the loop).

### 12.2 Device state across runs

The reference simulator keeps a device's data until the device is
erased: a booted device keeps running between runs, an app's data
container (Documents, Library, its preferences) and keychain items stay
when the app is installed again over itself, and `xcrun simctl erase`
returns the device to a new state (Apple's `simctl` help and Xcode
documentation, level 1; observable, level 3). Until phase 5 every Ycode
restore put the device back to the snapshot's state, so whatever the
previous runs wrote was lost.

**Design: save at the stop, restore in place.** A run of the IDE ends with
Stop (Ycode's SIGINT to the launcher), the end of `--timeout-ms`, or the
ssh channel going away. At that point the launcher has `ycode-simd` end
the launched app (SIGKILL, as the reference IDE's Stop ends the app while
the device keeps running), let the device settle 2 s, and write a
snapshot (`YCODE_SNAPSHOT_STOP_DIR`, staged on the RAM file system); the
host process then exits without running another guest instruction. The
device directory is left exactly as the snapshot saw it, so the next run
restores the snapshot **in place** (§2.7): no copy of the device
directory exists or is needed, and memory and files cannot disagree. The
restored device then installs and launches the new build as after a boot;
the runtime keeps the app's container across that install. A run that ends
any other way leaves the device directory as it is, and the next run boots
it cold, so a cold boot always sees the latest data.

Rules (the launcher):

1. A snapshot is restored only when `device-sync` holds its id (and the
   older checks hold: fingerprint, device directory present with the
   recorded inode number, device path, complete files). Otherwise it is
   discarded and the device boots cold, with its data as it is.
2. Every run removes `device-sync` before `ycode-simd` starts: from then
   on the device directory changes.
3. A stop is saved when `ycode-simd` reports "snapshot: exiting after the
   snapshot" with a complete directory; a background job (holding the
   device lock) moves it into `current/`, writes the stamp and then
   `device-sync`. Without that report (a crash, a quiesce that did not
   settle, a stop while the app steps still run, a restore that failed and
   was killed) nothing is saved.
4. A failed restore (no home screen, app steps not finished) is killed
   with SIGKILL (SIGTERM would save it), the snapshot is discarded and the
   same run boots cold on the device directory as the failed restore left
   it.
5. The device lock (fd 8) is held from the launcher's start until the save
   is in place: `ycode-simd` inherits it and closes it right before it
   exits after a save (`YCODE_SNAPSHOT_STOP_CLOSE_FDS=8,9`, with the boot
   slot), the save job takes the launcher's copy over. A next run of the
   same device, or an erase, waits for it; the 14 s the host process needs
   to tear its VMs down hold nobody up.
6. A cold boot holds the app steps until 60 s after the home screen
   (`YCODE_SNAPSHOT_HOLD_APPS` without `YCODE_SNAPSHOT_DIR`; a cold boot that
   installs the app before SpringBoard runs does not reach the home screen,
   §10.5) and takes no snapshot then: its stop saves it.
7. `ycode-sim --erase --device DEV` (after the lock) discards the snapshot
   and the device directory: the next run boots a new device.

Alternatives considered:

| Design | Why not |
|---|---|
| Keep the home-screen snapshot and carry the device directory forward from the previous run | the restored daemons (cfprefsd, the container manager, installd and the LaunchServices database, securityd, every SQLite store) hold caches, open files, offsets and inode numbers of the data as it was at the capture; files changed under them are corrupt state (§10.4, the SQLite "database moved" loop). Reconciling would need each daemon's internals |
| Snapshot only memory, re-snapshot the home screen when data changed | nearly every run writes app data, so nearly every run would boot cold |
| Save after the app was installed but before it ran | the app's own writes during the run would still be lost |
| Keep the device copy inside every snapshot (as phase 4) | 650 MB and about 1–5 s of pause per save for no use: an in-place restore needs no copy, and a device directory that no longer matches the snapshot must not be replaced by an older copy (that would lose data) |

Trade-off: every stop costs a pause of 3–5 s (2 s settle, then the
quiesce and about 2.6–3.0 GB written to the RAM file system) and a
background move of the save to the data volume (2–5 s, page cache warm);
a Run right after a Stop waits for that move. In exchange the device
behaves like the reference simulator's (data, settings, installed apps,
keychain stay until erased) and restores keep their speed (§12.3). The
save is a snapshot of a device that has run apps, not of a settled home
screen; a stop during the app steps (an install half done) is not saved.

### 12.3 Measurements

Agent SNAP-FIX, 2026-10-19, release builds of a0a71a6 plus this work,
on the Thor (load 11–60 from other agents), through the launcher with
the IDE's remote command (`snapfix-test` harness: Stop = SIGINT to the
remote pid and the end of its output channel), device `snapfix`, the
persistence probe `SnapPersist.app` (`SimShim/guest-tests/snapshot/
snap_persist_app.m`: counts its launches in NSUserDefaults, a file in
Documents and a keychain item, and prints the values it found).

Each row is one run of the launcher; "data" is what the probe found
(defaults / file / keychain, the count of earlier launches whose writes
survived); "stop" is the pause of the save, the time from the stop to the
launcher's end, and the background move to the data volume. Times in
seconds after `ycode-simd` started.

| Run | Path | Home | App launched | Data found | Stop: pause / done / move |
|---|---|---|---|---|---|
| c1 | cold, new device (load 60, first boot) | not seen in 400 s | 579 (apps held 480 s) | 0 / 0 / – | 8.2 / 25.8 / 4 (with a device copy, 4.7 s; before rule 5) |
| w1 | restore in place | 10.3 | 30.1 | 1 / 1 / – | 3.6 / 20.3 / 3 (the host teardown, 14 s, still waited for) |
| w2 | restore in place | – (first bright frames: the app) | 26.2 | 2 / 2 / – | 5.2 / 7.6 / – |
| w3 | cold (new simulator build: fingerprint) | 45.4 | 129.6 (held 110 s) | 3 / 3 / 0 | 3.1 / 5.8 / 5 |
| w4 | restore in place | 8.0 | 27.0 | 4 / 4 / 1 | 3.2 / 5.6 / 2 |
| w5 | cold (device directory replaced by a test) | 130.6 | 292 | 1 / 1 / 0 (the replaced directory's data) | 3.0 / 5.1 / 3 |
| w6 | restore in place | 11.1 | 30.2 | 2 / 2 / 1 | 3.2 / 5.6 / 4 |
| e1 | cold through the IDE (`RemoteRunEndToEndTests`, new build) | 40.4 (46.7 from Run) | 120.4 (120.8 from Run) | 3 / 3 / 2 | 2.6 / 5.1 / 3 |
| e2 | restore through the IDE | 6.5 (9.4 from Run) | 23.3 (23.6 from Run) | (stopped before the app ran its code) | 4.0 / 6.1 / – |
| w8 | restore in place | 6.4 | 26.4 | 4 / 4 / 3 | 3.0 / 5.7 / – |
| w9 | cold after `ycode-sim --erase` (a new device, first boot) | 180.0 | 296 (held 240 s) | 0 / 0 / 0 | 3.6 / 6.1 / – |

("–" for the keychain: the probe had no keychain entitlement yet and every
keychain call returned -34018, errSecMissingEntitlement; with
`application-identifier` and `keychain-access-groups` in its
`__TEXT,__entitlements` section the items persist like the rest.)

Findings:

- **Data survives** every saved run, through the IDE path too, and an app
  installed over itself keeps its data container (the container's
  directory name changes with each install; its contents move along).
  A cold boot — a new simulator build (w3, e1), a device directory that no
  longer matches (w5) — starts from the data as the last run left it.
  `ycode-sim --erase` gives a new device (w9).
- **Restore in place:** 4.7–7.3 s for the restore, home screen 6.4–11.1 s,
  app launched 23–30 s after the start; the same as the home-screen
  snapshots of phase 4 (below). A stop snapshot is a little smaller
  (2.4–3.0 GB in all, 216–257 images) than a home-screen one.
- **Stop:** 2 s settle, then a pause of 2.6–5.2 s (quiesce 0.2–0.3 s, 1
  attempt each time); the launcher is done 5.1–6.1 s after the stop. The
  host process needs about 14 s more to tear its VMs down (measured: the
  snapshot written 7.6 s, the process gone 21.9 s after the stop); with
  rule 5 nobody waits for it. Moving the save to the USB data volume took
  2–5 s.
- **What changes after the capture:** with the size and modification time
  recorded at the capture and renamed open files recorded under their
  current name, an in-place restore reports 3–4 files: the framebuffer
  state file the restore then removed (it is kept since §12.4), and memory-mapped files
  whose modification time moved after the capture with the same size.
  Before those two capture fixes the same check reported every open file
  (860; the time recorded was the open time) and then 21–32 files, of
  which 6–8 had been renamed while open (atomic saves: "functions.list.tmp"
  renamed to "functions.list", biome and locationd temporary files) and
  came back as empty files.
- **The capture triggers cleanly:** every stop quiesced in one attempt,
  the app was reaped 20–29 ms after the kill.

Earlier findings (IDE-WARM, phase 4, home-screen snapshots with a device
copy):

- **Settle time.** A snapshot 10 s after the home screen (249 images, 668
  threads, 15 processes still in a start hold) restored to the home
  screen in 7.3 s, but the app install after it never finished and the
  host process later died with SIGSEGV; snapshots 60 s after the home
  screen restored, installed and launched the app in every run. The stop
  snapshot of phase 5 comes at least 60 s after the home screen (rule 6)
  and after the app steps.
- **Pause and save.** Capture to the RAM file system: pause 3.5–6.1 s with
  the device copy (about 1 s); moving 3.5 GB to the USB data volume 3–13 s.
- **Failed restore cost.** A truncated manifest fails in about 1 s; a
  failure after the images are rebuilt in about 14 s. The cold boot that
  follows is otherwise unchanged.

### 12.4 The viewer's sessions (agent SIM-INPUT2, 2026-10-19)

The Mac viewer's host side (`scripts/ycode-sim-serve`, `display-stream.md`)
runs the same launcher as the IDE (`ycode-sim.sh`, installed next to it as
`ycode-sim`) with `--display-server` and no app options, so a session is
saved when the viewer closes and the next session restores it in place
(rules 1–7 of §12.2). The device lives at `<area>/devices/default`, its
snapshot under `<area>/snapshots/default`. `--cold` (the launcher's
`YCODE_WARM_FORCE_COLD=1`) discards the snapshot and boots the device as
it is; `--erase` runs `ycode-sim --erase` (device and snapshot) before a new
copy of the pristine device. What the viewer needed besides:

1. **Input after a restore.** The HID registration is a host-service
   record (`hid`, §2.6; `hid-input.md` §7 item 6).
2. **Frames after a restore.** The restore used to remove the framebuffer
   state file. backboardd's framebuffer library keeps that file open and
   rewrites it on every swap, so the lenient restore handed it an unlinked
   stand-in ("gone; an empty unlinked file stands for it"), and the
   display server, which reads the path, never saw a frame: the viewer
   stayed at "booting". The file now stays; its record names a surface the
   IOSurface service restores, so the last frame shows at once (viewer
   live 0.8–1.0 s after the restore finished).
3. **Signals.** With `--display-server` the display server used to take
   SIGTERM/SIGINT/SIGHUP itself (session end, no save). With a stop
   snapshot configured it now leaves them to the stop trigger and only
   tells the viewer that the device is stopping (`display-stream.md` §6).
4. **No save before the device has settled** (`YCODE_SNAPSHOT_STOP_REQUIRES`,
   launcher `YCODE_WARM_SAVE_SETTLE_S`, default 30). A viewer can be closed
   at any time. A stop 20 s after the first frame of a cold boot (boot
   logo) was saved; its restore showed no home screen within the
   launcher's 120 s and the host process crashed, and the launcher booted
   cold. The launcher now creates `runs/<device>/settled` 30 s after the
   home screen of a cold boot (at the home screen of a restore), and
   `ycode-simd` writes a stop snapshot only when that file exists;
   otherwise the guest shuts down cleanly and the next run boots the
   device cold with its data.
5. **"no vCPU for thread 1" (a second cause; §12.1 was the first).** Two
   restores of stop snapshots failed with, for example, "pid 263: no vCPU
   for thread 1: 64 restored threads, pool 64 of 64 vCPUs, 0 parked". The
   failure report now lists the vCPUs that hold a thread other than the
   process's restored ones: all 64 held new threads (ids 91–154) that the
   process's kernel had started **during the restore**, before the start
   loop. A message delivered in that window (host services run their
   receive loops from the start and answer requests the snapshot left
   queued) activated a knote; the workqueue, whose restored workers had no
   vCPU yet, started a new worker for the request, the worker waited at
   the start gate, the request stayed unanswered, and every later request
   started another worker until the pool was full. Fix: from the start of
   a restore until the restored threads have their vCPUs (§7 step 9), the
   kernel starts no new thread (`PoolThreadHost.restoring`); a workqueue
   request then stays pending and is handed out at step 10 with the
   others. Both snapshots that failed were stops with Settings (a UIKit
   app) in front.

Measurements (Thor, release builds, Mac viewer through `ycode-sim-try
--script`, other agents' boots in parallel; times from the viewer's start
unless noted):

| Session | Path | Live (first frame) | Home screen | First input → first change |
|---|---|---|---|---|
| e1 | `--erase`, a new device (cold, first boot) | 40 s (17 s after `ycode-simd` started) | 89 s after `ycode-simd` started, with drawn icons | tap on Settings: 3.6 s (Settings launching) |
| w1 | restore of e1's save | 14.2 s (0.9 s after the restore) | 8.8 s after `ycode-simd` started | tap: 3.1 s; Home 1.2 s |
| w2 | restore | 15.2 s (0.8 s) | 9.4 s | tap on Settings 1.4 s; Home 1.0 s |
| c1 | `--cold` (the same device) | 29 s | 88 s | tap 0.5 s; Home 0.7 s |
| w3 | restore of c1's save | 11.2 s (1.0 s) | 7.1 s | tap 0.67 s |
| d1 | restore; Settings ▸ Appearance ▸ Dark, then Home | 0.6 s after the restore | 7.4 s | — |
| c2 | `--cold` | 15.5 s after `ycode-simd` started | (not detected: item 6) | — |
| k1 | cold (no save existed) | 12 s | 55.4 s | tap 0.02 s (Settings drawn after 9.6 s); Home 0.85 s |
| k2 | restore of k1's save | 0.1 s after the restore | 6.6 s | tap 0.13 s; Home 0.6 s |

**Data persists.** Dark appearance chosen in d1 was still set after the
`--cold` boot c2, two more cold boots and the restore k2 (the home screen
and Settings drawn dark): the device's data stays across cold boots and
restores, as in §12.3.

6. **The home-screen watcher in dark appearance.** The launcher's watcher
   took "two frames brighter than 60 (mean)" as the home screen. The dark
   appearance's home screen has a mean of 46, so c2 and the following
   cold boot never "reached the home screen", never settled (item 4) and
   were not saved; a restore of a dark device would have been killed as
   failed after 120 s. The rule is now "less than 90 % of a 70 × 102 grey
   sample darker than 24": the boot logo and a blank screen are about 99 %
   dark, the home screen 0 % (light) or 7 % (dark), dark Settings 47 %.

Restores took 4.0–6.4 s (2.7–3.6 GB of pages, lazy); stops paused the
guest 3.0–4.7 s. A restore session waits first for the previous session's
save to reach the data volume (the device lock, rule 5): 7–9 s back to
back here, nothing when the sessions are minutes apart. Before fix 5, two
of the three restores of settled saves failed and fell back to a cold boot
(about 100 s more); after it, 5 of 5 restored (w1, w2, w3, d1, k2).

### 12.5 Restore hardening (agent RESTORE-HARDEN, 2026-10-19)

One of four IDE restores on the main line (1264ab2) ended with SIGSEGV in
`ycode-simd` about 11–23 s after the restored home screen, before the app
launched; Swift's crash handler then crashed in its own DWARF reader, so
there was no stack, and the next run overwrote the run log.

**Evidence kept (launcher).**

- Every run's log is kept: `runs/<device>/logs/<time>-<mode>.txt`, the
  newest `YCODE_WARM_KEEP_LOGS` (default 10); `log-restore.txt` and
  `log-cold.txt` link to the latest of their mode. The launcher's own
  `ycode-sim.log` starts again past 1 MB.
- Host crashes leave a stack: unless the caller sets `SWIFT_BACKTRACE`,
  the launcher runs `ycode-simd` with `enable=yes, interactive=no,
  symbolicate=off, threads=all, images=all, registers=crashed,
  output-to=runs/<device>/crashes`. With `symbolicate=off` the handler only
  walks the stacks and lists the images (the default, `full`, reads DWARF
  inside the crashing process, which is what crashed). After a run that
  ended by a signal with a new report, the launcher symbolizes it in
  another process (`llvm-symbolizer` per image offset, then
  `swift-demangle`) into `<report>.sym.txt`, says where it is, and copies
  the crashing thread into the run log. A report of the 1 000-thread
  process is about 350 KB and symbolizes in about 11 s. The last
  `YCODE_WARM_KEEP_LOGS` reports are kept. (Core dumps were not used: the
  host's `core_pattern` pipes them to apport, which is not configurable
  without privileges, and a core of the process would be several GB on the
  system disk.) A `kill -SEGV` makes the handler write a report but does
  not end the process (observed), so it also serves as an all-thread stack
  dump of a live run.
- A restore that is about to be killed as failed (below) first gets
  SIGUSR1: `ycode-simd` writes where every guest thread waits (the
  `YCODE_THREAD_REPORT_AT_S` report) into the run log, then the launcher
  kills it 3 s later.
- The thread report names who can still send to a port a thread waits on,
  including notification requests and rights in message bodies, and
  workloops marked as requested that no queue holds, with their last
  request changes. A stop snapshot logs threads that wait for a reply no
  guest holds and such workloops.

**Reproduction.** A loop of IDE-style runs on devices of its own (the
remote command with `--install-app`/`--launch`, Stop = SIGINT to the
launcher 0–17 s after "ylaunch: launched", the next run as soon as the save
is in place), on the Thor while other agents' boots ran (load 8–25):

| Build | App, stop after launch | Restores | Host crashes | Restores that hung |
|---|---|---|---|---|
| main line (1264ab2) | SnapPersist, 3–17 s | 44 | 0 | 1 (a first-boot save, below) |
| main line | YcodeProbe, 0–2 s | 4 | 0 | 2 (one a first-boot save) |
| + clock and liveness changes | YcodeProbe, 0–2 s | 45 | 1 (SIGSEGV 5 min after the restore) | 0 |
| + the rebuild under every fine lock (fix 2 below) | both | about 80 | 1 (SIGBUS in a stop's capture) | 2 (logd; plus first-boot saves) |
| same, `YCODE_LOCK_ORDER_CHECK=1` | YcodeProbe, 0–2 s | 2 | 2 (the checker stopped both: fix 1 below) | – |
| + restored observers under the event lock (fixes 1 and 2) | YcodeProbe, 0–2 s, `YCODE_LOCK_ORDER_CHECK=1` | 56 in a row | 0 | 0 |
| same | SnapPersist, 0–15 s | 34 in a row | 0 | 0 |
| + the clock notification (final build) | YcodeProbe, 0–7 s | 34; 33 in a row after one whose stop was killed at the stop timeout (below) | 0 | 0 |

Every restore counted launched the app. The main-line crash rate was low
in these loops (0 in 48); the IDE's 1 in 4 had a short history; the
heap corruption needs a race to land, so its rate depends on load and
timing — the lock-order checker made the cause deterministic.

**Root cause: two places where the restore did not follow the lock
split.** Since the IPC lock split (`mach-ipc-locking.md` §4) an image's
kqueues, knotes and workqueue are guarded by its event lock L_P and the
Mach state by the port lock G; the kevent and IPC fast paths run under
those alone, without L0. The restore still behaved as under the single
kernel lock:

1. *Restored descriptor knotes changed the kevent state without L_P.* The
   restore registers every EVFILT_READ/EVFILT_WRITE knote with its
   descriptor object (a socket, a pipe) again, and it used its own copy of
   the readiness observer, which marks the knote active and calls the
   activation (thread requests, the workqueue) without the image's event
   lock; the registration's observer takes it. The object calls the
   observer under L0 from the thread that changed its readiness — for
   logd's syslog socket, any process that logs. Every restore therefore
   ran unguarded changes of logd's kqueues and workqueue on other
   processes' threads, racing logd's own kevent fast paths. With
   `YCODE_LOCK_ORDER_CHECK=1` every restore stopped at it at once ("a knote
   touched without event lock (L_P)", from the observer in
   `SnapshotRestore.fillKQueues`, called by `datagramSend`). The effects
   match all three failures seen: a workloop of logd marked as requested
   that no queue held (a lost update of the pending list), so logd served
   nothing, every process that logged waited for it, and the app install
   hung (two restores); a `KEventState` dictionary of logd freed with a bad
   pointer in `DarwinKernel.deinit` when logd ended (the SIGSEGV, symbolized
   from the report); and a garbage object reference read by a later stop's
   capture (a SIGBUS in `KernelSnapshotCapture.capture`).
2. *The rebuild held L0 alone.* `KernelSnapshotRestore.restoreObjects` and
   `makeProcesses` rebuilt ports, spaces (the host task's among them),
   message queues, kqueues, knotes and the workqueue under L0, with the lock
   checks switched off. The host services' threads (Metal, IOSurface,
   SCDynamicStore, HID, the bootstrap service, the device session) run
   during a restore — their receive loops start before it and serve what
   the snapshot left queued (§12.4 item 5) — and use the host task's ports
   and deliver to guest ports under G and L_P only. The capture already
   held every fine lock; the restore did not.

**Fix.** The restore registers the registration's observer
(`readinessObserver(for:)`, which takes the event lock); the rebuild holds
L0 and every fine lock as the capture does (`withAllFineLocks`, deadlock-free
for the same reason: no other thread waits for L0 while holding a fine
lock); the thread requests of §7 step 10 are issued under each image's
event lock, and a workloop marked as requested that no queue holds is
requested again (none was found at a restore; the step only guards the
invariant). Tests (`SnapshotKernelRoundTripTests`):
`restoredReadinessObserverTakesTheEventLock` (the event lock is taken when
a restored pipe becomes readable; fails with the old observer),
`restoreHoldsTheFineLocksWhileItRebuildsObjects`,
`lostWorkloopRequestIsIssuedAgainAfterARestore`.

**The launcher could die at Stop.** In one run bash printed
"interrupt trap: line 2: unexpected EOF while looking for matching `)'" at
the Stop and exited: the SIGINT trap ran while the watch loop was expanding
a `$(…)` (bash 5.2), and a syntax error ends a non-interactive shell.
`ycode-simd` kept running without its launcher (and without a stop), held
the device lock and the boot slot, and ran on unsaved; it is the run that
crashed 5 minutes later. The watch loop and the trap now use no command
substitution (`$EPOCHREALTIME`, `printf -v`, `read`), and `ycode-simd`
started with `YCODE_EXIT_WITH_PARENT=1` asks the kernel for SIGTERM (a
stop) when its parent ends (`prctl(PR_SET_PDEATHSIG)`).

**Restores that hung.** Two kinds were found (neither a crash):

1. *Saves of a device's first boot.* 3 of 3 restores of a save taken
   about 30–60 s after the app launched in the first boot of a new device
   never presented a new frame and never launched the app. The live first
   boot has the same state before any save: in a first boot left running
   150 s after the app launched (no snapshot involved), SpringBoard's main
   thread waited from about 250 s on for a reply from iconservicesagent,
   PosterBoard had six workloops with queued messages, marked as requested,
   no servicer, and its 64-vCPU pool full (62 threads in workloop sync
   waits). The restore faithfully brings the hung guest back. This is a
   first-boot workqueue/pool problem outside the snapshot; the restore
   side now detects it sooner (liveness, below) and reports it.
2. *Lost workloop thread requests* (logd): the race of root cause 1
   above; none in the 124 restores after its fix.

**Read-only files (found on the way).** Spotlight makes its finished
index files mode 0400 while they stay mapped shared and writable. The
restore reopened shared file views and writable descriptions with
`O_RDWR`, which then failed (EACCES); the lenient restore replaced the
views with zero-filled shared memory ("gone; its shared view is plain
shared memory") and the descriptors with empty unlinked files. The restore
now sets the owner's write bit for the open of such a file of this user
and puts the mode back at once (`openWritableAgain`; nothing runs during
the restore, the open description keeps its access as the guest's did).
Test: `fileMadeReadOnlyAfterItsOpenStaysWritableAcrossARestore`.

**The clock after a restore (§5).** The guest's mach time continues at the
captured value, so timers that the guest set on mach time keep the time
they had left; that is intended. But libdispatch's wall-clock timers
(`dispatch_walltime`, kevent `NOTE_ABSOLUTE` without `NOTE_MACHTIME`) are
due by the calendar, and the restore rebased them like mach-time timers:
a timer due at the next minute boundary when the device was saved fired
that much after the restore, whatever the time now. Such timers are now
due by the wall clock at the restore (at once when the calendar passed
them; a restore of the home screen reports about 64), and every image's
commpage wall-clock snapshot is taken again. Test:
`calendarTimersFollowTheWallClockAcrossARestore`.

That was not what kept the status-bar clock: a restore of a save taken at
second 9 of a minute and restored 58 s later showed the save's minute for
at least 47 s on the main line, and the same with the timer change alone
(the clock is redrawn by a timer on mach time, which waits out the 51 s it
had left). After a restore whose calendar moved (the manifest's creation
time against now, at least 1 s) `ycode-simd` therefore posts the Darwin
notification that announces a set clock, `com.apple.system.clock_set`
(libnotify's `kNotifyClockSet`), once the guest answers the liveness
request, with the runtime's `notifyutil -p` as a one-shot. With it the
status bar showed the current minute 4 s after the restore began (the
first frame after the restore, 3.8 s): measured on the same device and
timing, save at 18:48:09, restore at 18:49:06, "10:49" in the frame at
4 s. (For the guest the restore is a set clock: the calendar jumps while
mach time does not. Whether the reference runtime has other observers of a
calendar change that should hear of it — the host calendar notification of
`host_request_notification`, which Ycode accepts and never sends — is an
open question for the dirty room.)

**Liveness.** The restored frame is on the display before any guest
thread runs, so "two lit frames" said nothing about a guest that hangs.

- `ycode-simd`, after a restore, sends launchd_sim a 703 request through
  the adopted session (the `user/<uid>` variable `YCODE_LIVENESS_PROBE`,
  never set) and logs "snapshot: restore: guest live: launchd_sim answered
  N ms after its session was adopted" (0.04–3.1 s); it also logs the first
  frame the guest presents after the restore ("first new frame",
  1.3–18 s after the root started in the runs above, with an app launch).
- The launcher fails a restore whose guest has not answered within
  `YCODE_WARM_LIVE_TIMEOUT_S` (default 60 s), as it fails one without a
  home screen or whose app steps do not finish; the device counts as
  settled (a stop saves it) only once the guest answered, so a hung restore
  is not saved again.
- It also fails a restore whose guest has presented no new frame within
  `YCODE_WARM_FRAME_TIMEOUT_S` (default 90 s; 0 turns the check off): a UI
  that hangs keeps the restored frame. The status bar redraws at least at
  each minute boundary, and at once after a restore whose minute changed
  (the clock notification above), so a live home screen presents a frame
  within about 60 s; with an app launch the first new frame came 0.3–25 s
  after the root started (median 15 s, 90 restores), and without one
  (viewer-like runs, the home screen) 1.6–6.0 s (4 restores).
- Before it kills a failed restore the launcher asks for the thread report
  (SIGUSR1).

**Stops that were not saved (open).** A stop waits at most 15 s for every
guest thread to settle. A thread in `openbyid_np` or `fsgetpath` whose
object is not in the index walks the volume without a lock, and on the
USB data volume under load that took longer than 15 s once in about 50
stops ("1 x running (trap 479)"); the device was not saved and the next run
booted cold. A walk that a quiesce can interrupt and restart is the fix.
Once (about 150 stops, a heavily loaded host: boot slots full) a stop
quiesced and captured but had not written its files 120 s later
(`YCODE_WARM_STOP_TIMEOUT_S`) and was killed; the files are written from
the lazily mapped page files of the restore on the USB data volume and
the device's inode list is walked there. The launcher now has Swift's
handler write every host thread's stack (a `kill -SEGV`, which does not
end the process) before such a kill, so the next one shows where it
stood.

**Timings** (Thor, load 8–25, other agents' boots in parallel; seconds
after `ycode-simd` started; the 90 restores with fixes 1 and 2, two devices,
two apps): the restore itself 4.3–7.3 (median 5.2); the home screen
(the restored frame) 6.7–10.3 (median 7.8); the guest's answer
0.03–3.3 s after the session was adopted (median 1.5); the app running
17.4–32.5 (median 24.4–25.4, p90 28.6). The cold boots of the same
loops reached the home screen in 66–98 s and launched the app at 154–215 s.
The final build's 33 restores in a row: restore 4.4–11.9 s (median 5.6),
home screen 6.9–14.5 (median 8.2), app running 13.2–54.1 (median 23.9);
each posted the clock notification (exit 0).


## Evidence

| Claim | Level | Source |
|---|---|---|
| `KVM_GET_ONE_REG`/`KVM_SET_ONE_REG` register ids for core, FP/SIMD (128-bit V registers, 32-bit FPSR/FPCR) and system registers; `KVM_REG_ARM_TIMER_CNT` sets the VM's counter offset | 1 | Linux `Documentation/virt/kvm/api.rst` (4.68 KVM_SET_ONE_REG, arm64 register ids) |
| An MMIO exit's operation completes only on the next `KVM_RUN`; `immediate_exit` re-enters without running guest code | 1 | Linux `Documentation/virt/kvm/api.rst` (KVM_RUN, `immediate_exit`, KVM_EXIT_MMIO note on completing operations before saving state) |
| A signal makes `KVM_RUN` return `-EINTR` | 1 | the same document |
| `mincore` reports residency of anonymous and file pages; `/proc/self/pagemap` bit 61 (file-page or shared-anon) and bit 63 (present) | 1 | Linux man pages `mincore(2)`, `Documentation/admin-guide/mm/pagemap.rst` |
| Trap numbers, Mach option bits (`MACH_SEND_MSG` = 1, `MACH_RCV_MSG` = 2), `WQOPS_THREAD_RETURN` | 1 | xnu `osfmk/mach/syscall_sw.h`, `bsd/kern/syscalls.master`, `osfmk/mach/message.h`, `bsd/pthread/workqueue_syscalls.h` (already in `darwin-trap-tables.md`, `mach-ipc.md`, `threads-and-events.md`) |
| Restart of interrupted system calls as the model for §4 | 1 | Linux `signal(7)` (SA_RESTART, ERESTARTSYS), CRIU documentation (public) |
| Snapshot shape (per-device state + memory file) | 1 | Firecracker public documentation (snapshot support) |
| Where each piece of Ycode state lives (§2) | — | Ycode's own code (`ycode/Sources`), design, this document |
| Measurements (§10) | 3 | our runs on the Thor |
| SQLite reports a database whose file's inode no longer matches the path as moved (extended result code 1032, `SQLITE_READONLY_DBMOVED`) | 1 | SQLite documentation (result codes); observed in a restore (§10.4, rest2) |
| `mmap(MAP_PRIVATE \| MAP_FIXED)` of a file gives a copy-on-write view read on first touch; `MADV_DONTNEED` on a private file mapping makes later reads return the file's contents again; `POSIX_FADV_WILLNEED` / `POSIX_FADV_DONTNEED` start a read-ahead / drop clean cached pages; `vm.max_map_count` bounds the mappings of a process | 1 | Linux man pages `mmap(2)`, `madvise(2)`, `posix_fadvise(2)`, `Documentation/admin-guide/sysctl/vm.rst` |
| KVM follows host mapping changes inside a memslot (MMU notifiers), so a range of a memslot may be replaced while the VM exists | 1 | Linux `Documentation/virt/kvm/api.rst` (KVM_SET_USER_MEMORY_REGION: changes to the backing memory are reflected into the guest) |
| A Vulkan buffer device address is chosen by the implementation (stable across devices only with the capture/replay feature) | 1 | Vulkan specification, `VK_KHR_buffer_device_address` (`bufferDeviceAddressCaptureReplay`) |
| Measurements and the stall of §10.5 | 3 | our runs on the Thor (thread reports, knote histories) |
| The IDE's warm boot: settle time, "no vCPU" restore failures, pause, save and fallback costs (§12) | 3 | our runs on the Thor, directly and through the IDE (`RemoteRunEndToEndTests`), 2026-10-19 |
| `flock(1)` locks belong to the open file description; `ionice -c3` (idle class) needs no privilege for one's own processes | 1 | util-linux man pages `flock(1)`, `ionice(1)` |
| The restore's start gate and the cause of "no vCPU for thread N" (§7 step 9, §12.1) | — / 3 | Ycode's own code (`VCPUPool.start` returns nil for an ended pool and for an exhausted one); `SnapshotRestoreStartTests` (a model pool); our restores on the Thor (§12.1) |
| The reference simulator keeps a device's data until it is erased; `simctl erase` returns it to a new state; an app's data container and keychain items survive an install over the app | 1 / 3 | `xcrun simctl help erase`; Apple's documentation of app updates (Documents and Library are kept) and of keychain items; observable on the Mac |
| Save at the stop, restore in place, the launcher's rules (§12.2) | — | Ycode's own design |
| `/proc/self/fd/<n>` is a link to the open file's current path, with " (deleted)" appended when it was unlinked | 1 | Linux man page `proc(5)` |
| A flock is released only when every descriptor of its open file description is closed (inherited copies share it); `tee -p` (`--output-error=warn-nopipe`) keeps writing to its files when its output pipe closes; a non-interactive shell cannot trap a signal that was ignored when it started (background commands of a non-interactive shell start with SIGINT ignored) | 1 | Linux man page `flock(2)`; GNU coreutils manual (`tee`); GNU Bash manual (Signals, `trap`). The IDE runs the launcher in the foreground of its ssh command, so Stop's SIGINT is trappable |
| Device state across runs: data found, restore, stop and save times (§12.3) | 3 | our runs on the Thor through the launcher and `RemoteRunEndToEndTests`, 2026-10-19 |
| The viewer's sessions: the frame-record, signal, settle and HID changes, the restore-time worker storm and its fix, timings (§12.4) | — / 3 | Ycode's own code and design; viewer `--script` sessions on the Thor (failure reports with the new vCPU listing), 2026-10-19 |
| Swift's crash handler settings (`SWIFT_BACKTRACE`: `enable`, `interactive`, `symbolicate=off` / `fast` / `full`, `threads`, `images`, `registers`, `timeout`, `output-to`) | 1 | Swift runtime documentation (`docs/Backtracing.rst` in the Swift repository) |
| `llvm-symbolizer --obj --functions=linkage --no-inlines` maps image offsets to functions and lines | 1 | LLVM command guide (`llvm-symbolizer`) |
| `prctl(PR_SET_PDEATHSIG)`: a signal when the parent ends; the kernel's `core_pattern` pipes cores to a helper | 1 | Linux man pages `prctl(2)`, `core(5)` |
| bash: a trap runs after the foreground command; a syntax error ends a non-interactive shell; `$EPOCHREALTIME`, `printf -v`, `printf %(…)T` are builtins | 1 | GNU Bash manual (Signals, Shell Variables, Bash Builtins) |
| A trap during a command substitution made bash 5.2 report "unexpected EOF while looking for matching `)'" and exit, or lost the Stop | 3 | Our launcher runs on the Thor (bash 5.2.21), §12.5 |
| `open(2)` with `O_RDWR` checks the file's mode at the open, not later: a descriptor or mapping opened before a `chmod` keeps its access; the owner may change the mode | 1 | POSIX `open`, `chmod`; Linux man pages `open(2)`, `chmod(2)` |
| A kevent `NOTE_ABSOLUTE` timer without `NOTE_MACHTIME` is a calendar (wall-clock) deadline; libdispatch's wall-clock timers use it | 1 | `threads-and-events.md` §3.7.2 (xnu `bsd/kern/kern_event.c`; libdispatch `src/event/event_kevent.c`) |
| Restore hardening: the two lock-split gaps, their symptoms (lost workloop requests in logd, the heap corruption, the lock-order checker's stop), the fixes, the first-boot hang of the live guest, the clock and liveness measurements, timings (§12.5) | — / 3 | Ycode's own code and design; symbolized crash reports and thread reports of restore loops on the Thor, 2026-10-19 |
