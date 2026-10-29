# Spec: Mach IPC and kevent delivery off the global kernel lock

Status: **implemented, agent SP-IPC, 2026-10-19.** §3 are hold-time
reductions inside the kernel lock; §4 is the lock split. Both are on by
default (each has a switch); §6 has the measurements: home screen 143 s →
80 s (−44 %) on the Thor. A first version of §4 (a reader-writer gate that
every L0 holder took for writing and every fast path for reading) was
slower than no split: every L0 acquisition drained the fast paths in
flight and stopped new ones (§6.3); the version below has no gate.

This is Ycode's own design for Ycode's own kernel personality. It names no
Apple internals. The Mach semantics it must keep (message order per port,
rights accounting, notifications, port death, queue limits, blocking) are
those of `mach-ipc.md`, `threads-and-events.md` and `processes.md`, whose
level-1 sources are the xnu sources (`osfmk/ipc`, `bsd/kern/kern_event.c`,
`bsd/pthread/pthread_workqueue.c`). Lock rules extend `stage6-contract.md` §5,
`performance-contract.md` §4 and `boot-profile.md` §3.6 (rule numbers C22–C26
continue that list).

## 1. Problem

Every trap of every process ran under one mutex, the kernel lock L0. After
C15–C21 the lock was still 45–48 % busy in a boot, 37–39 % of acquisitions
were contended, and every trap waited 300–400 µs on average for it
(`boot-profile.md` §6.4). The critical path to the home screen is a chain of
Mach IPC round trips between daemons (§6.3 there): each round trip is a
handful of traps (`mach_msg2` send and sync receive, the server's
`workq_kernreturn` and `kevent_id`), and each of them queued for L0.

The trap profile (`YCODE_TRAP_PROFILE`, 250 s of a boot) before this work:

| Trap | Acquisitions | Mean hold | Summed hold | Mean wait |
|---|---|---|---|---|
| `mach_msg2_trap` (−47) | 961,565 | 34 µs | 33.0 s | 400 µs |
| `workq_kernreturn` (368) | 663,234 | 33 µs | 22.1 s | 362 µs |
| `kevent_id` (375) | 1,101,532 | 15 µs | 16.7 s | 370 µs |
| everything else | 3,061,568 | — | 44.8 s | — |

## 2. Where the IPC hold time went

A new diagnostic samples the kernel-lock holder's call stack
(`YCODE_TRAP_PROFILE_STACKS=<µs>` with `YCODE_TRAP_PROFILE`): every interval
the holder's host thread gets SIGPROF, its handler records the return
addresses (`backtrace`), and the sample is kept only when the same hold is
still in progress afterwards. The table `<profile>.stacks` lists each stack
with its count and trap; `<profile>.stacks.maps` holds the process's
mappings so that `llvm-symbolizer` can name Ycode's own frames. Findings
(70,902 samples of one boot):

1. `mach_msg2_trap`: 74 % of its hold samples were in `enqueue`, and 38 % in
   the EVFILT_MACHPORT hook: every queued message scanned every knote of
   every kqueue of the receiving process (hundreds of workloops in a large
   daemon), and each match re-scanned its kqueue.
2. Waking a sleeping thread (`pthread_cond_signal`, a futex system call) was
   done with the lock held: 12–14 % of `kevent_id` and `workq_kernreturn`
   holds. The woken thread's first act is to take the lock, so it only
   blocked again on the mutex.
3. Trace text was built when nothing traced it: the receive path's result
   note (`hx`, string interpolation) and the knote history notes.
4. A non-IPC finding: 11 % of all hold samples were the libSystem milestone
   note of new processes waiting for the shared-cache index's full-list
   lock while a background thread held it to parse every image's
   `__crash_info` sections (seconds). That note runs inside the trap's
   kernel-lock acquisition.

## 3. Hold-time reductions (on by default)

### 3.1 C22: EVFILT_MACHPORT knotes indexed by port name (`YCODE_KNOTE_INDEX`)

Each image keeps `KEventState.machportIndex`: port name → its
EVFILT_MACHPORT knotes, in the order a scan of all kqueues finds them
(`allKQueues` order). The message-queued and receive-right-gone hooks read
it instead of scanning. The index is built on first use and dropped
(set to nil) whenever its content could change:

- an EVFILT_MACHPORT knote is added to a kqueue or removed from one;
- a kqueue is added to or removed from the image's registry while it may
  hold knotes (descriptor kqueues, `kqueue()` objects, the workqueue
  kqueue; a workloop is freed only when it has no knotes, and a new
  workloop has none);
- a snapshot restore rebuilds the kqueues.

The hooks then do exactly what the scan did for the same knotes in the
same order. `YCODE_KNOTE_INDEX=0` scans as before.

### 3.2 C23: wakeups signalled after the lock is released (`YCODE_DEFERRED_WAKE`)

`WaitQueue.Waiter.finish` called by the holder of the waiter's lock records
the result at once (under the lock, as before) but queues the condition
signal on the lock; the lock signals the queued waiters right after it
releases its mutex (at the end of `withLock`, in `yield`, in `unlocked`),
or, before a condition wait (which releases the mutex atomically), just
before sleeping. Why no wakeup is lost: a waiter sleeps only while its
`result` is nil and reads `result` with the lock held; the result is set
under the lock; the queued signal keeps the waiter object (and its
condition variable) alive until it is sent. A waiter that timed out at the
same time sees the result and returns `woken`, as before. A finish by a
thread that does not hold the lock signals at once.

### 3.3 C24: no trace text unless traced

The receive path's note and the knote history text are built only when a
trace or the knote history wants them (`@autoclosure`). The workqueue
operation-name table is built only for traced calls.

### 3.4 The crash-info list has its own lock

`SharedCacheIndex.crashInfoSections` (fault reports only) has its own lock
instead of the full-list lock, so the full image list (read by the
milestone note) never waits for that parse.

## 4. The lock split (C25; on by default, `YCODE_IPC_LOCKS=0` turns it off)

### 4.1 Locks and order

| Level | Lock | Guards |
|---|---|---|
| 0 | L0, the kernel lock | BSD, process and VM bookkeeping state; every L0 wait queue (semaphores, ulocks, pipes, signals; the timer thread only with `YCODE_TIMER_L0=1`) |
| 1 | L_P, one per image ("event lock") | the image's kevent engine (`KEventState`, kqueues, knotes, the timer registry), its workqueue (`WorkqueueState`, `WorkerState`), its thread table `threadsByPort` (for writes) and thread registration; the timer thread's wait queue (`frame-profile.md` §5.3) |
| 2 | G, one per system ("port lock") | every `MachIPC` space (names, special reply ports, task slots), every port, port set and queued message, `MachIPCSystem` counters, mk_timer fields, port importance counts and `DarwinProcess.importanceBoosts` |
| 3 | L1 per address space, then leaf locks | as before |

**Order.** A thread takes locks in strictly increasing level, never two locks
of one level (two images' L_P). Re-entering a held lock is a no-op (nesting
depth), as for L0 before. Blocking waits release every lock (4.4). A debug
check (`YCODE_LOCK_ORDER_CHECK=1`, on in the tests) records each thread's
held locks in thread-local storage, stops the process on an out-of-order
acquisition, and checks that the kevent and workqueue entry points and every
wait-queue wake hold the queue's lock.

### 4.2 Who holds what

Every read and write of level-1 and level-2 state holds that state's lock
(invariant **I1**). Code under L0 that touches such state takes the lock
there (L0 → L_P → G is in order): the kevent and workqueue calls
(`kevent*`, `kqueue`, `kqueue_workloop_ctl`, `workq_open`,
`workq_kernreturn`), descriptor close, signal and process-event delivery to
knotes, readiness observers, the timer thread, thread creation and exit, the
VMM's retry of pending workqueue requests, spawn and exec (task ports,
watch ports, teardown), the mk_timer traps, and every Mach trap on the
locked path (`MachIPC.handleTrap` takes L0, then G). The host task's state
is Mach state: its lock is G.

State that the fast paths read but L0 code owns is limited to:

- whether the image is ending (an atomic flag next to `termination`);
- whether a process is in its start hold (an atomic flag next to `holdStart`);
- the process record of an image (`schedProcess`): its cached reference
  only (without L0 the process table is not read); a process's type and
  clamp fields, which change only at spawn and exec;
- a thread's signal mask, written by its own thread.

Descriptor readiness (pipes, sockets, kqueue descriptors) is L0 state: a
kqueue that holds EVFILT_READ or EVFILT_WRITE knotes is re-evaluated under
L0 (its hook is deferred, 4.5), and the kevent and workqueue fast paths
decline for an image that has such knotes.

**Thread state that other threads read.** Mach routines and BSD calls run
on the locked path (L0, then G) and may act on another thread of the task
while that thread is on a fast path, which holds no L0. A field of a thread
that a fast path writes and another thread reads or writes has a leaf lock
of its own (one mutex per thread and field; nothing is taken under it):

| Field | Written by | Read or changed by others |
|---|---|---|
| The entry frame (user registers at the entry of the trap in progress) | the thread's own host thread, at the start and end of every trap, on both paths | `thread_get_state` (a copy is taken under the lock); the snapshot quiesce |
| The explicit QoS overrides (`bsdthread_ctl` `QOS_OVERRIDE_START`/`END`, by resource) | the thread's workqueue return and the workqueue pump (cleared when a worker takes new work; under L_P only on the fast path) | `bsdthread_ctl` of any thread of the image (under L0); the class refresh (under L0) |

Without the entry frame's lock, `thread_get_state` (libobjc samples every
thread of its task this way before it frees method caches) copied a frame
while its owner replaced it at the end of a fast `mach_msg` and freed the
register array: a use after free that stopped the host process (seen in 2
boots after the split). The routines were already under L0; it was the
writer that held none, so routing routines to L0 cannot fix it. Two
uncontended mutex operations per trap cost nothing measurable: 6 Thor
boots of this build against the main line aa1bf7c, each pair started
together (device in RAM, load average 12–18), reached the home screen in
175/170/165/210/140/140 s (mean 167) against 170/175/165/215/160/135 s
(mean 170), with no host crash (`SX/FIXTGS/runs/fix-tgs-1…6`,
`SX/IDE/runs/fix-tgs-base-1…6`).

Test (`ThreadStateRaceTests`, lock-order check on): threads of one image
take fast `mach_msg` receives as fast as they can while other threads copy
their entry frames under L0 (millions of copies), and while threads of the
same task call `thread_get_state` on them through the routine; every frame
read must be the target's whole trap frame. Without the entry frame's lock
the first test stopped the test process in 5 of 5 runs on the x86-64
workstation (a register array retained after it was freed, or freed
twice); with it, 5 of 5 runs pass, as do the full suite and the kernel
suite (322 tests) with `YCODE_IPC_LOCKS_TESTS=1 YCODE_LOCK_ORDER_CHECK=1`
and with `YCODE_IPC_LOCKS=0`.

The other routines that name a thread or task were checked and need no
change: `thread_get_exception_ports`/`thread_set_exception_ports` (the
exception slots are Mach state, under G); `task_threads` (the thread table
changes only with L0 and L_P both held, so L0 is enough to read it, and a
thread's end flag changes under L0); `thread_self_trap` (the caller's own);
`thread_info` (no flavor is served); the task special ports and
`mach_ports_register`/`lookup` (Mach state, G); the VM routines (the
address-space lock); `semaphore_create`/`destroy` (L0 queues). The integer
scheduling inputs of a thread (requested QoS, dispatch override, IPC push
class) are also written on fast paths and read under L0: each is one word,
and a stale value only delays a class refresh, which runs again under L0
(4.5). The VMM's diagnostic records of a thread's traps are read by other
threads only for reports.

### 4.3 Fast paths

A trap takes a fast path only if it is one of the traps below and none of
its fallback conditions holds; otherwise it runs as before, under L0. The
fast path is entered on the vCPU's own host thread before the trap would
take L0 (like the task-local traps of `boot-profile.md` §3.6), after the
image's libSystem milestone; it decides whether to fall back before it
changes anything. It holds no L0.

| Trap | Locks | Falls back when |
|---|---|---|
| `mach_msg_trap` (−31), `mach_msg_overwrite_trap` (−32), `mach_msg2_trap` (−47) | G only (the blocking observer's workqueue work is deferred to L_P, 4.5); the send bytes are read from guest memory before G is taken and the received message is written after it is released (a failed write still answers `MACH_RCV_INVALID_DATA`) | a send whose destination name holds a kernel-object port (served by kernel code that uses process state) |
| `kevent_id` (375) on a workloop, `kevent_qos` (374) on the workqueue kqueue, `workq_kernreturn` (368: thread returns, thread requests, `SHOULD_NARROW`) | L_P; G inside each Mach receive and importance change; L0 for a scan that could report a descriptor knote (§4.11) | a change names a filter other than EVFILT_MACHPORT, EVFILT_WORKLOOP, EVFILT_USER, EVFILT_TIMER; another `workq_kernreturn` operation (the image-level decline for descriptor knotes is gone, §4.11) |
| the port routine traps (§4.10) | G only | the pid-to-task traps (not fast traps) |
| all of them | | tracing; the image is ending; the thread is not bound to the image; the host thread holds a kernel lock |

Inside a fast path, work that needs L0, or the event lock of another image,
is **deferred** (4.5); the fast trap's own effects (its return registers,
the messages it queued or received, the rights it moved, the events it
delivered) are complete when the trap returns, as on the locked path.

### 4.4 Waiting

Each `WaitQueue` is waited on with the lock that guards its state: port and
port-set queues with G; kqueue, sync-knote and worker park queues with the
image's L_P; every other queue with L0, as before. A wait (any lock X):

1. Take X if the caller does not hold it (a thread under L0 waiting on a
   port queue). Register the waiter (queue storage and X's registry) and run
   the before-sleeping hook and the blocking observer with all locks held.
2. Release every lock the thread holds (remembering which, at which depth,
   for which guest thread), then run the thread's deferred work (4.5).
3. Take X's mutex; while the waiter has no result, sleep on its condition
   (the condition wait releases X atomically).
4. Release X; take back every lock of step 2 in its original order.
5. If the waiter still has no result (its deadline passed), record
   `timedOut` and remove it from the queue (X is held again). Unregister it.

For an L0 queue the thread keeps L0 as the condition's mutex and releases
only the fine locks above it, as before.

**Why no wakeup is lost (I2).** A waker changes the queue's state and sets
the waiter's result while it holds X (L0's `interrupt`, `terminate` and
snapshot census take each fine lock in turn for its registry). The waiter
reads its result only while it holds X (step 3) and sleeps atomically with
releasing X. So either the waker ran before step 3 (the waiter sees the
result and does not sleep) or after the waiter's condition wait began (the
signal reaches it; with C23 the signal goes out when X is released).

### 4.5 Deferred work

A thread never takes a lock of a lower level than one it holds. An effect
that needs such a lock is queued on the thread and runs as soon as the
thread's held locks allow it (when it releases a lock, before it sleeps,
and at the end of the trap, before it returns to the guest).

| Effect | Where it arises | Runs under |
|---|---|---|
| EVFILT_MACHPORT hooks (message queued, receive right or set gone) of the space that receives | `enqueue`, `dropReceive`, port-set changes (G held) | that image's L_P (G inside); the hook re-reads the port, so a late or repeated hook only re-evaluates knotes |
| Starting a new workqueue thread (vCPU, thread record) | `pumpWorkqueue` without L0 | L0 + L_P: `retryPendingWorkqueue` |
| Re-evaluating a kqueue with descriptor knotes | knote activation without L0 | L0 + L_P |
| A dying port's payload: a semaphore (its waiters are L0 queues), a fileport's open file, a memory entry | `portDeath` without L0 | L0: the payload is released there (the port drops it at once) |
| The timer thread's start and wakeup (only with `YCODE_TIMER_L0=1`; by default the timer thread waits on L_P and is woken at once, `frame-profile.md` §5.3), notifying a kqueue descriptor's observers, removing a dropped knote's readiness observer | kevent fast paths | L0 |
| Start-hold release and class refresh after an importance change; a thread's class refresh | `changeImportance`, `refreshSchedClass` without L0 | L0 (re-checked there; `importanceBoosts` itself changes at once, under G) |

Running deferred work can queue more (a hook that starts a thread); the
thread drains it until nothing runnable is left. Other threads may observe
a deferred effect a few microseconds after the trap's own effects, as on a
multiprocessor xnu, where these objects have locks of their own.

### 4.6 Handing work to the holder of an event lock

Event-lock work from a thread that does not hold the lock (an
EVFILT_MACHPORT hook of another image, the blocking observer's workqueue
pump) does not wait for it: `runOrPost` runs it at once when the lock is
free, else appends it to the lock's posted list (a leaf mutex) and tries
the lock once more; every release of the lock runs the posted work it finds
after unlocking (it takes the lock again with a try-lock). So posted work
runs before the holder's next release or by the poster itself, never later
than the next release (none is left behind: a poster either finds the lock
free after posting, or the lock is held and its holder's release sees the
work). The hooks re-read the port's state, so running one a few
microseconds later only delays an activation that the holder would have
evaluated anyway.

Fine locks are glibc adaptive mutexes (`PTHREAD_MUTEX_ADAPTIVE_NP`; a
contender spins briefly before it sleeps); `YCODE_FINE_LOCK_SPIN=0` makes
them plain.

### 4.7 Snapshots

Fast paths do not take L0, so the snapshot quiesce (`snapshot.md` §3)
holds every fine lock as well (`KernelLock.withAllFineLocks`: the event
locks in a fixed order, then the port lock) while it classifies the
threads and captures the state. A fast-path thread that wakes meanwhile
(a timeout) blocks when it takes its fine lock back, so it is still a
registered, unwoken waiter and is captured as blocked in its trap (it
restarts the trap on restore). This caller is the only one that holds
more than one event lock; every other thread holds at most one and never
waits for L0 while holding one, so the snapshotter cannot deadlock.

The restore holds them too, the same way (`snapshot.md` §12.5): no guest
thread runs while it rebuilds processes, ports, spaces and kqueues, but
the host services do, and they use the host task's ports and deliver to
guest ports under the port lock and the event locks, not under L0. The
thread requests of the restore's step 10 are issued under each image's
event lock. The descriptor knotes it registers again use the same
readiness observer as a registration, which takes the image's event lock
(the observer runs under L0, on the thread that changed the descriptor's
readiness). Until 2026-10-19 the rebuild held L0 alone and the restored
observers took no event lock; the second raced logd's kevent fast paths
on every restore (lost thread requests, a corrupted heap).

### 4.8 Deadlock freedom

Every thread takes locks in strictly increasing level, at most one per
level (4.1; the snapshotter of 4.7 is the one exception and takes the
event locks in a fixed order while no other thread can wait for it); a
thread blocked on a lock holds only locks of lower level, so the waits-for
graph has no cycle. Condition waits hold no lock (4.4). Deferred work runs
only when its locks can be taken in order; posted work is run by the
holder after it unlocks, under a try-lock. A fast path starts with no lock
held and never takes L0.

### 4.10 The port routine traps under the port lock (agent KLOCK, 2026-10-23)

The Mach port routine traps ran on the locked path: L0, then G. Their
state is Mach state only (spaces, ports, port sets, requests: G), and the
L0 holder waited for G while holding L0 (12.7 % of L0 holder samples were
in a futex wait on G). They are now IPC fast traps (§4.3) that run the
locked path's handler under G alone:

| Trap | |
|---|---|
| Ycode's `thread_get_state` (0x7963_2011), `task_threads` (0x7963_200D) | the caller's event lock (the thread table changes only with L0 and it held), then G; a target's entry frame under its own lock (§4.2) |
| Ycode's `mach_make_memory_entry_64` (0x7963_200A), `mach_vm_map` with a memory object (0x7963_200B), `mach_vm_remap` (0x7963_200C), `mach_port_get_context`/`set_context` (0x7963_200E/F) | G; the memory-entry and VM-map routines do their address-space and shared-object work with G released, as before (§4.2), so they now hold no lock for it (on L0 a profiled boot held L0 0.5–2.5 ms per memory entry, mostly in the host `mmap`) |
| −16 `mach_port_allocate`, −18 `deallocate`, −19 `mod_refs`, −20 `move_member`, −21 `insert_right`, −22 `insert_member`, −23 `extract_member`, −24 `construct`, −25 `destruct`, −26 `mach_reply_port`, −27 `thread_self`, −28 `task_self`, −29 `host_self`, −40 `get_attributes`, −41 `guard`, −42 `unguard`, −50 `thread_get_special_reply_port`, −70 `host_create_mach_voucher`, −72 `mach_voucher_extract_attr_recipe`, −76 `mach_port_type`, −77 `request_notification` | G only |

What they do beyond Mach state is what a fast `mach_msg` already does
(moving or destroying rights): a dying port's payload (a semaphore, a
fileport's file, a memory entry) is released under L0 and the
EVFILT_MACHPORT hooks run under the receiving image's event lock, both as
deferred work (§4.5); importance counts change under G. The pid-to-task
traps (−44 … −46) read the process table and stay on L0. A traced image
uses the locked path (its trace lines). Switch:
`YCODE_PORT_ROUTINES_FAST=0`. Test:
`MachIPCLockSplitTests.portRoutinesOnTheFastPathKeepRightsBalanced` (four
threads make, arm, use and destroy ports with the routines, fast or locked
at random, while they send to a server on the fast path; every
no-senders notification is delivered and destroyed with its port; no name,
right or message is left over).

### 4.11 Descriptor readiness: the scan takes L0 (agent KLOCK, 2026-10-23)

The kevent and workqueue fast paths declined for any image that had an
EVFILT_READ or EVFILT_WRITE knote (§4.3), because a descriptor's readiness
is L0 state. In a cold boot that sent 41,000 traps to L0 (most of
`workq_kernreturn`'s and `kevent_id`'s 20 s of L0 waits). Now:

- Only a descriptor knote that a scan could report needs its readiness:
  active, enabled (or a synthetic delete), neither suppressed nor dropped
  (a *candidate*). Its flags are event-lock state, and a descriptor knote
  becomes active only under L0 and the event lock (its readiness
  observer). Any other descriptor knote is not deliverable whatever its
  descriptor's state, and is never read.
- A delivery scan (`scanForDelivery`: a kevent's scan, a worker's upcall
  and its return) on a fast path that finds a candidate in its kqueue
  **escalates**: the thread gives up the event lock (its only lock), takes
  L0, takes the event lock back (in order), scans under both, then gives L0
  up and keeps the event lock (`KernelLock.escalateToKernelLock`). The
  event lock is not held for a moment, as in a wait. The scan reads the
  kqueue afresh; what another thread changed in that moment is a change it
  could have made just before the scan (a worker's bucket or workloop stays
  bound to it; a kevent's own changes were applied before).
- A request re-evaluation off L0 defers to L0 only when the kqueue holds a
  candidate (before: any descriptor knote).
- A pipe's or socket's knote found not ready under L0 stops being active.
  Both notify their observers at every change, and the observer makes the
  knote active again when the descriptor becomes ready; without this a
  level-triggered knote stayed active after its data was read, and every
  scan of its kqueue took L0 (a profiled boot: 20,000 escalations and
  31,600 deferred re-evaluations before it). Device nodes (always ready) and
  kqueue descriptors keep the flag.
- So the image-level decline is gone. Registering, enabling or deleting a
  descriptor knote is still a change with another filter: L0.

Without the escalation a worker parked on a fast path, handed a bucket
whose only event is a ready pipe, could not deliver it off L0 and would be
woken again by the deferred re-evaluation, forever. Switch:
`YCODE_DESCRIPTOR_ESCALATION=0` (the old decline). Test:
`WorkqueueKEventTests.descriptorKnoteIsDeliveredToAParkedWorker` (a pipe's
EVFILT_READ|EV_DISPATCH knote on the workqueue kqueue, three rounds of
park, write, delivery, read and EV_ENABLE; with the split on, the scans
escalated).

## 5. Tests

- `MachIPCLockSplitTests` (lock-order check on): a request/reply storm
  between 3 server and 4 client images (3 threads each, 150 rounds, every
  trap on the fast or the locked path at random), with replies checked and
  rights counts balanced at the end; a server woken through an
  EVFILT_MACHPORT knote of a descriptor kqueue while clients send on the
  fast path and block for the answer (the deferred hook must run before
  the client sleeps); a one-message queue with 8 blocked senders on both
  traps (−31, −47), every message received once and in order per sender;
  receivers blocked on the fast path when the receive right dies, the
  dead-name notification; `interrupt` and the snapshot census reaching
  fine-lock waiters; deferred wakeups racing timeouts; posted event-lock
  work never left behind; the held-lock record; a fast round trip while
  another thread holds L0.
- The whole kernel suite also runs with the split in every test system and
  the test helpers trying the fast paths first, as the VMM does
  (`YCODE_IPC_LOCKS_TESTS=1`, about 6,000 fast traps per run), with
  `YCODE_LOCK_ORDER_CHECK=1`: 315 tests pass on the Thor (arm64) and the
  x86-64 workstation, as do the full suite with the default settings and
  the kernel suite with `YCODE_IPC_LOCKS=0`.

## 6. Measurements

Thor, harness full boots (device in RAM, `YCODE_LEAN_BOOT` unset), one boot
at a time, the three arms alternating in each round; base = main line
34e5bb1; "hold time" = this branch with `YCODE_IPC_LOCKS=0` (§3 only);
"split" = this branch's defaults.

### 6.1 Time to the home screen (no profiling; load average 8–14)

| Round | base | hold time | split |
|---|---|---|---|
| 1 | 130 | 110 | 70 |
| 2 | 150 | 110 | 85 |
| 3 | 150 | 125 | 85 |
| mean | 143 | 115 (−20 %) | 80 (−44 %) |

`guest_fatal` 5–9 (base), 6–7, 5–6. An earlier set of three profiled rounds
(trap profile on, load 8–19) gave 188 / 155 / 103 s.

Against main line 74981d5 (after merging SP-SPAWN, SP-SNAP, SP-THREADS,
SP-GPU; load 9–12): base 170/160/130 (mean 153) against split 70/85/75
(mean 77, −50 %); PosterBoard spawned 72–75 s → 39–52 s after SpringBoard;
poster batch median gap 0.99–1.64 s → 0.39–0.60 s. With the merged main
line also checked: a snapshot at the home screen settles (with every fine
lock held) and its restore reaches the home screen in 5.9 s; a cold boot
with the probe app installs it at 58 s and launches it at 79 s.

### 6.2 The critical path (launchd.log of the same runs)

| Metric | base | hold time | split |
|---|---|---|---|
| PosterBoard spawned, after SpringBoard | 55–68 s | 49–59 s | 37–42 s |
| Poster extension batch: median gap between launches | 1.24–2.04 s | 0.81–1.31 s | 0.48–0.73 s |
| Batch span (20 launches) | 27–39 s | 18–23 s | 10–18 s |

### 6.3 Locks (profiled boots, `YCODE_TRAP_PROFILE`)

| | base | hold time | split (gate, first version) | split |
|---|---|---|---|---|
| L0 busy | 46.5 % | 44.2 % | — | 45 % (of a shorter boot) |
| L0 acquisitions per trap | 1.37 | 1.39 | 0.84 | 0.76 |
| `mach_msg2` L0 hold per acquisition | 35 µs | 15 µs | — | (L0 only on fallback) |
| Lock wait per `mach_msg2` trap | 417 µs | 300 µs | — | 85 µs (G 44 µs, L0 fallbacks the rest) |
| Lock wait per `kevent_id` trap | 389 µs | 284 µs | — | 94 µs |
| Lock wait per `workq_kernreturn` trap | 392 µs | 293 µs | — | 202 µs (L0 fallbacks: images with descriptor knotes) |
| IPC traps on a fast path | — | — | 1.43 M | 1.28 M of 1.35 M |
| Port lock G | — | — | — | 12 % busy, 9 µs mean `mach_msg2` hold |
| home_s | 230 | 155 | not reached in 300 s | 105 |

The gated first version: 1.32 M of 2.34 M gate read acquisitions waited
(1,348 s in all), L0 waits rose to 1–3 ms: L0 holders (BSD traps, about
half of all acquisitions) each drained the fast paths. Without the gate,
L0 is as busy as before over a shorter boot (its work is now BSD and VM
traps: `mmap`, `getattrlist`, `posix_spawn`, `close`, `sysctl`, `open`), and
the BSD traps wait longer for it (open 200 → 530 µs) because that work is
now packed into less time.

### 6.4 KLOCK (2026-10-24): §4.10 and §4.11

Measured with the BSD changes of `bsd-locking.md` §12–§15, arms switched on
one build (`bsd-locking.md` §16). In profiled cold boots the IPC traps that
fell back to L0 went from 40–48 k to 10 k (the descriptor-knote declines
from 35–42 k to 0; 1.0–1.1 k scans escalated to L0), and the port routine
traps (78–80 k a boot) left L0. The IPC locks took the load: G's summed
waits rose from 21–26 s to 41–61 s, the event locks' from 23–24 s to
35–37 s. Time to the home screen did not improve (`bsd-locking.md` §16.2).
Ablation in place (series X, 4 rounds, `YCODE_PORT_ROUTINES_FAST=0` against
the defaults): 39, 39, 36, 40 s against 35, 42, 34, 42 s (paired −4, +3,
−2, +2): no effect.

BOOT-CP's ranking of the boot's critical path (`boot-profile.md` §8.3)
puts the kernel locks at about 5.5 s of 33 s (L0 waits in SpringBoard's own
traps 1.5 s: `mach_port_deallocate`, `fcntl`, `munmap`, `thread_get_state`,
`proc_info`, all now without L0; diagnosticd's event-lock waits and wakeup
latency 2.9 s), behind host-CPU oversubscription and guest code.

## 7. Open items

- ~~The kevent and workqueue fast paths decline for an image with
  EVFILT_READ/EVFILT_WRITE knotes~~ (§4.11). Descriptor readiness under a
  lock per object (pipes, sockets) would remove the escalation too.
- The port lock is one per system and is now the busiest IPC lock (41–61 s
  of summed waits per boot, §6.4); the port stripes of §4.9 were measured
  neutral when G's other users still ran under L0. With the routines off L0
  (§4.10) a re-measurement of the stripes is due.
- The event lock is one per image; diagnosticd's (every log message passes
  through it, `boot-profile.md` §8.5) is on the boot's critical path: its
  workloop threads' hand-offs are event-lock waits and wakeup latency on an
  oversubscribed host. Shorter holds in `workq_kernreturn` (33–53 µs mean,
  scans with Mach receives and thread binding inside) and a lock per
  workloop are the candidates.
- L0's remaining users (`bsd-locking.md` §17) no longer contend much
  (14–16 % busy, 11–13 % of acquisitions contended).

## Evidence

| Claim | Level | Source |
|---|---|---|
| Mach and kevent semantics kept (ordering, rights, notifications) | 1 | `mach-ipc.md`, `threads-and-events.md` (xnu `osfmk/ipc`, `bsd/kern/kern_event.c`) |
| Reader-writer lock with writer preference (the first version) | 1 | glibc `pthread_rwlockattr_setkind_np(3)` |
| Adaptive mutexes (`PTHREAD_MUTEX_ADAPTIVE_NP`) | 1 | glibc `pthread_mutexattr_settype` |
| A condition wait releases its mutex atomically | 1 | POSIX `pthread_cond_wait` |
| `thread_get_state` reports a thread's user registers; libobjc samples every thread of its task before freeing caches | 1 | xnu `osfmk/arm64/status.c`, objc4 `objc-cache.mm` (`_collecting_in_critical`), as in `Threads.swift` |
| The `thread_get_state` host crash and its cause (§4.2): an entry frame copied while its owner freed it on a fast path | 3 | Host backtraces of Thor boots (`SX/IDE/runs/sp-port-base-1`, `SX/SPASTC/runs/sp-astc-0`), `ThreadStateRaceTests` before and after |
| The per-thread locks cost no boot time (§4.2) | 3 | Paired Thor boots `SX/FIXTGS/runs/fix-tgs-*`, `SX/IDE/runs/fix-tgs-base-*` |
| The restore's rebuild under L0 alone and its observers without the event lock (§4.7) | 3 | Host backtraces of restored runs (a dictionary of `KEventState` freed with a bad pointer in `DarwinKernel.deinit`; a bad reference in a capture), the lock-order checker's stop in every restore before the fix, `SnapshotKernelRoundTripTests` (`snapshot.md` §12.5) |
| Where hold time went (§1, §2) | 3 | Trap profiles and holder stacks of Thor boots (`SX/SPIPC/runs/s1`, `a1`) |
| Measurements (§6) | 3 | Thor harness boots `SX/SPIPC/{base/,}runs/f*`, `m*`, `x1`, `y5` |
| §4.10, §4.11 and §6.4: port routines under G, descriptor-readiness escalation, their measurements | — / 3 | Ycode design; Thor timed boots of Ycode's simulator (`ide-remote/klock/runs/{P,X}-*`), kernel tests |
| Level-triggered EVFILT_READ/WRITE readiness, EV_DISPATCH re-enable | 1 | xnu `bsd/kern/kern_event.c` (via `threads-and-events.md`) |

Level 5 was not used. The reference tools folder, `research/` and Ghidra
were not opened.
