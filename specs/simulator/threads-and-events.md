# Spec: threads, workqueues, kevent, and synchronization (kernel side)

Status: **reference for stage 4** (`docs/SIMULATOR-LINUX.md`). Stage 3 runs
a command-line program on one vCPU. `launchd_sim` and every daemon use
libdispatch, and libdispatch needs real threads, the workqueue, kevent
delivery to workqueue threads, workloops, and blocking synchronization.
This spec gives the kernel-side behavior of those interfaces so that
Ycode's VMM can supply them.

Scope and relation to other specs:

- `host-library-init.md` §6 already covers `bsdthread_register` (§6.1), a
  summary of `bsdthread_create` and the `thread_start` registers (§6.2), and
  a summary of `start_wqthread` (§6.3). This spec **extends** those
  sections. It does not repeat the registration record.
- `host-libraries.md` §10 defines the stage-3b semaphore traps for one vCPU.
  §4.4 below gives their multi-thread behavior.
- `vm-shim-protocol.md` describes one vCPU. §6 below lists the facts that
  matter for more than one guest thread.
- The trap numbers are in `darwin-trap-tables.md` and
  `data/bsd-syscalls.json`.

All facts come from Apple's open-source xnu and libpthread (the kernel
component, `kern/`) at the tags in **Evidence**. libdispatch was read only
to learn **which** kernel interfaces and flags it uses. Nothing here
describes libdispatch internals beyond that. The text restates behavior as
rules and tables. It contains no source.

## 0. Conventions

| Item | Rule |
|---|---|
| BSD call return | Success: carry clear, `x0` = value. Failure: carry set, `x0` = errno (`darwin-process-start.md` §4) |
| `ULF_NO_ERRNO` (ulock calls only) | A failure is returned as **success** with `x0 = −errno` (carry clear) |
| Mach trap return | `x0` = `kern_return_t`. Carry is not used |
| Thread port names | xnu port names always have the **low two bits set** (`name & 3 == 3`). User space uses those two bits as flags in lock words, and the kernel rebuilds the name with `value | 3` (ulock owners, workloop owners) or `value & ~3` (join gate). **Ycode's VMM must give every thread port name `name & 3 == 3`.** Ycode's names (`0x103`, `0x203`, `0x0503`, …) already follow this |
| `thread_selfid` / "tid" | A unique, non-zero 64-bit thread ID, never reused while the process lives |
| Page size | 16 KiB in the guest. All sizes below that depend on the page size are given for 16 KiB |

---

## 1. Threads (Q1)

### 1.1 `bsdthread_create` (BSD 360)

| Reg | Argument | Meaning |
|---|---|---|
| x0 | `func` | Start routine. Passed through to the new thread in `x2` |
| x1 | `func_arg` | Passed through in `x3` |
| x2 | `stack` | Initial `sp` of the new thread. Passed through in `x4` |
| x3 | `pthread` | The `pthread_t` (user-allocated). Passed through in `x0`; the TSD base is derived from it |
| x4 | `flags` | See below |

`flags` layout: bits 31–24 are flags, bits 23–16 the policy, bits 15–0 the
importance.

| Flag | Value | Meaning |
|---|---|---|
| `PTHREAD_START_CUSTOM` | `0x0100_0000` | Required. Without it the call fails with `EINVAL` |
| `PTHREAD_START_SETSCHED` | `0x0200_0000` | Apply policy (bits 23–16: 1 = timeshare `SCHED_OTHER`, else fixed) and importance (bits 15–0, applied as `importance − 31`) |
| (`0x0400_0000`) | — | Old "detached" bit. Not used |
| `PTHREAD_START_QOSCLASS` | `0x0800_0000` | Bits 23–0 are a `pthread_priority_t` (§2.4). The QoS must be set and the relative priority must be in −15…0, else `EINVAL` |
| `PTHREAD_START_TSD_BASE_SET` | `0x1000_0000` | Output only. Added by the kernel when it set the TSD base |
| `PTHREAD_START_SUSPENDED` | `0x2000_0000` | Do not start the thread. The kernel **clears this bit** in the value it passes to the thread |

The kernel **allocates nothing** in user memory for this call. The caller
supplies the stack and the `pthread_t`.

Kernel rules, in order:

1. If `bsdthread_register` has not run in this process, fail with `EINVAL`.
2. Create the thread and make a send right to its thread port in the task's
   port space. If no name can be made, fail with `EMFILE`; if the thread
   cannot be created, fail with `ENOMEM`.
3. Check `PTHREAD_START_CUSTOM` (`EINVAL`).
4. If a TSD offset is registered: TSD base (`TPIDRRO_EL0`) =
   `pthread + tsd_offset` (224); add `TSD_BASE_SET` to the flags.
5. Clear `SUSPENDED` in the flags.
6. Set the register state below. All registers not listed are **zero**:
   x6–x28, fp, lr, all of V0–V31, FPSR, FPCR, `TPIDR_EL0`. PSTATE is EL0
   AArch64 with NZCV = 0.

   | Register | Value |
   |---|---|
   | pc | registered `thread_start` |
   | x0 | `pthread` |
   | x1 | the new thread's port name |
   | x2 | `func` |
   | x3 | `func_arg` |
   | x4 | `stack` |
   | x5 | `flags` (with `TSD_BASE_SET`, without `SUSPENDED`) |
   | sp | `stack` |
   | `TPIDRRO_EL0` | `pthread + 224` |

7. Apply `SETSCHED` or `QOSCLASS` (bad QoS → `EINVAL`).
8. If a mach-thread-self TSD offset is registered: store the port name as a
   64-bit value at `pthread + tsd_offset + mach_thread_self_offset`
   (slot 3). A failed store fails the call with that error.
9. Unless `SUSPENDED` was requested, start the thread.
10. Return `pthread` in `x0`.

On any failure after step 2, the kernel deallocates the port name and
terminates the half-made thread.

### 1.2 `bsdthread_terminate` (BSD 361)

| Reg | Argument | Meaning |
|---|---|---|
| x0 | `stackaddr` | Start of the region to free (0 = none) |
| x1 | `freesize` | Size of the region to free (0 = none) |
| x2 | `port` | The calling thread's port name, to deallocate |
| x3 | `sema_or_ulock` | 0, a Mach semaphore name to signal, **or** a user address of a join gate |

Rules:

1. If the caller is a workqueue thread, first remove it from the
   workqueue's accounting (§2.7). (An AIO workqueue thread gets `ENOTSUP`.)
2. **Join-gate detection.** If `x3 ≠ 0` and `x3 | 3 ≠ x3` (it does not
   look like a port name, because addresses are aligned), then `x3` is a
   join-gate address. The kernel remembers (address, `port`) and treats
   both `port` and the semaphore as 0 for steps 5–6.
3. If both `stackaddr` and `freesize` are non-zero:
   - for the **main thread**: round `freesize − 1` down to a page, mark that
     range reusable, and make it `PROT_NONE` (the range stays reserved);
   - for any other thread: deallocate `[stackaddr, stackaddr + freesize)`.
4. Terminate the calling thread. The call never returns.
5. If a semaphore name was given: signal it (as `semaphore_signal`).
6. If `port ≠ 0`: deallocate one user reference on that name.
7. **Join gate** (only when step 2 applied): after the thread is completely
   gone, the kernel:
   1. stores the 32-bit value `port & ~3` at the gate address;
   2. performs `ulock_wake(UL_UNFAIR_LOCK | ULF_WAKE_ALL |
      ULF_WAKE_ALLOW_NON_OWNER, gate)` (§4.1);
   3. deallocates `port`.

   A joiner waits with `__ulock_wait(UL_UNFAIR_LOCK, gate, port)`, so it
   wakes only after the thread is gone, and it sees the gate value change.

Note for Ycode: Ycode's `libsystem_pthread` decides which form it uses
(semaphore, join gate, or neither). The kernel side must support the form
Ycode's library chooses. The library of the same libpthread tag uses the
semaphore form for custom stacks only, and wakes joiners itself with
`__ulock_wake(UL_UNFAIR_LOCK)` on its `tl_exit_gate` word.

### 1.3 `thread_selfid` (BSD 372)

No arguments. Returns the calling thread's unique 64-bit ID in `x0` (carry
clear). It cannot fail.

### 1.4 Per-thread signal calls

See §5.2 for `__pthread_kill` (328), `__pthread_sigmask` (329), and
`__disable_threadsignal` (331).

### 1.5 `bsdthread_ctl` (BSD 478)

Arguments: `x0` = command, `x1`–`x3` = arguments.

| Cmd | Name | Args | Behavior |
|---|---|---|---|
| `0x10` | `SET_QOS` | — | `ENOTSUP` (removed) |
| `0x20` | `GET_QOS` | — | Not handled: `EINVAL` |
| `0x40` | `QOS_OVERRIDE_START` | thread port, pp, resource | Add an explicit QoS override to that thread |
| `0x80` | `QOS_OVERRIDE_END` | thread port, resource, 0 | Remove it |
| `0x100` | `SET_SELF` | pp, voucher name, flags | See below |
| `0x200` | `QOS_OVERRIDE_RESET` | — | Drop the calling thread's dispatch override |
| `0x400` | `QOS_OVERRIDE_DISPATCH` | thread port, pp, ulock addr | Dispatch override on a thread |
| `0x401`, `0x402` | async override add/reset | — | `ENOTSUP` (removed) |
| `0x800` | `QOS_MAX_PARALLELISM` | qos, flags (1 = logical, 2 = realtime, 4 = cluster-shared), 0 | Returns the CPU count usable at that QoS in `x0` |
| `0x1000` | `WORKQ_ALLOW_KILL` | enable, 0, 0 | Allow `__pthread_kill` to target this workqueue thread |
| `0x2000` | `DISPATCH_APPLY_ATTR` | flags, v1, v2 | Cluster hints. May be accepted and ignored |
| `0x4000` | `WORKQ_ALLOW_SIGMASK` | sigset, 0, 0 | Process-wide: signals in the set stay unmasked on workqueue threads across reuse (§2.7) |
| other | — | — | `EINVAL` |

`SET_SELF` flags: QOS `0x01`, VOUCHER `0x02`, FIXEDPRIORITY `0x04`,
TIMESHARE `0x08`, WQ_KEVENT_UNBIND `0x10`, QOS_OVERRIDE `0x40`.

- `WQ_KEVENT_UNBIND` detaches a workqueue thread from the workqueue kqueue
  bucket it is servicing (§3.8), so that the bucket can get another thread.
  `EINVAL` if the caller is not a workqueue thread, is the event manager, or
  is bound to a workloop; `EALREADY` if it is not bound.
- `QOS` sets the thread's QoS from `pp` (`EINVAL` for a bad value; `EPERM`
  for a non-workqueue thread that opted out of QoS; `EINVAL` for the manager
  thread; for workqueue threads the overcommit/cooperative type may not
  change in a forbidden direction).
- `VOUCHER` adopts the voucher name. For Ycode: accept and record.
- The call returns an error if any requested part failed.

Ycode: with `YCODE_SCHED_QOS=1` the QoS of SET_SELF, the overrides
(0x40, 0x80, 0x200, 0x400) and `PTHREAD_START_QOSCLASS` feed the thread's
scheduling class (`scheduling-policy.md` §4.4). Without the switch they are
accepted and have no effect.

### 1.6 Mach thread and task suspension (agent THREAD-SUSPEND, 2026-10-28)

`thread_suspend`, `thread_resume`, `thread_abort`, `thread_abort_safely`,
`thread_get_state`, `thread_set_state`, `task_suspend` and `task_resume`
are MIG routines of `mach/thread_act.defs` and `mach/task.defs`. Ycode's
`libsystem_kernel` serves them with Ycode-private traps
(`host-libraries.md` §11.7). Before this section they were generated stubs
(KERN_NOT_SUPPORTED), and JavaScriptCore's collector could not stop the
threads whose stacks it scans (`app-launch.md` §3.6).

**Semantics (xnu `osfmk/kern/thread_act.c`, `task.c`; the Mach manual
pages; level 1).**

| Call | Rule |
|---|---|
| `thread_suspend(t)` | The thread's suspend count goes up by one. While the count is above zero the thread executes no user instruction. For another thread the call returns only once the thread has stopped. A thread may suspend itself: the call returns KERN_SUCCESS and the thread stops when it would return to user code, until another thread resumes it |
| `thread_resume(t)` | The count goes down by one; at zero the thread runs again. Count already zero: KERN_FAILURE. A thread made with `PTHREAD_START_SUSPENDED` has count 1 and starts at this call |
| `task_suspend(task)` | The task's suspend count goes up by one; while it is above zero no thread of the task runs user code, including the caller when it is in the task. Waits until every thread but the caller has stopped. A thread made in a suspended task starts suspended |
| `task_resume(task)` | The task's count goes down by one; count zero: KERN_FAILURE. A thread runs only when its own count and its task's are both zero. A process spawned with `POSIX_SPAWN_START_SUSPENDED` has task count 1: `task_resume` (or SIGCONT, which resumes the task once) starts it |
| `thread_get_state(t, flavor)` | The user registers where the thread stopped (below). ARM_THREAD_STATE64 (6, 68 words: x0–x28, fp, lr, sp, pc, cpsr, pad), the unified ARM_THREAD_STATE (1, 70 words: {6, 68} first), ARM_EXCEPTION_STATE64 (7, 4 words: FAR, ESR, exception class) |
| `thread_set_state(t, flavor)` | Flavors 1 and 6 set x0–x30, SP, PC and the condition flags (the mode stays EL0t); flavor 7 is accepted with no effect; exact counts (70, 68, 4) else KERN_INVALID_ARGUMENT. Another thread is held (suspended once) while its state is changed, as xnu does. For a thread inside a kernel call the new registers apply when the call returns, and the call's results (x0, x1, carry) are written over them, as a returning xnu system call writes its results into the saved state |
| `thread_abort(t)`, `thread_abort_safely(t)` | A thread waiting in the kernel returns from its call as interrupted (`MACH_RCV_INTERRUPTED`, `KERN_ABORTED`, `EINTR`; the library restarts what it restarts after a signal). A thread running user code is not affected |
| Errors | A name that is not a send right: MACH_SEND_INVALID_DEST; a right to something other than a thread (task): KERN_INVALID_ARGUMENT; a thread that has ended: KERN_TERMINATED |

`thread_info` (THREAD_BASIC_INFO, THREAD_EXTENDED_INFO) reports the run
state TH_STATE_STOPPED (2) while the thread is suspended and the thread's
own suspend count.

**What "stopped" means for a thread in the kernel.** As in xnu, a thread
that is blocked in a kernel call (a Mach message, a wait, a sleep) or
running one counts as suspended at once: it executes no user instruction,
and its user registers are those at the entry of its call. When its call
completes while it is suspended, it does not return to user code: it stops
with the call's results in its registers.

**Ycode implementation.**

- *The run gate.* Each thread has a gate (`GuestThreadGate`, in
  `YcodeDarwinABI`), closed while its suspend count or its task's is above
  zero. The counts change under L0; closing a gate also makes the thread's
  vCPU leave guest mode (`ThreadHost.kickThread`: `immediate_exit` and the
  kick signal, `docs/SIMULATOR-LINUX.md`).
- *Where a thread parks.* The vCPU host thread checks the gate (one relaxed
  atomic load) before every guest entry and at the entry of every trap. A
  closed gate parks it on the gate's condition variable, with the thread's
  user registers published: the vCPU's registers when it was kicked out at
  EL0 (`guest`); the slot's trap frame just after a handled trap
  (`afterTrap`; the shim restores it on resume); the arriving frame at a
  trap's entry, before the kernel handles it (`trapEntry`; the trap runs
  after the resume); or the start state before a thread's first
  instruction (`start`). A kick that finds the vCPU at EL1 (the shim,
  entering or leaving a trap) does not park it; the suspender kicks again
  every millisecond until the thread stops at EL0 or at its next trap.
- *Waiting.* `thread_suspend` and `task_suspend` wait with every kernel lock
  released (L0 is the only lock their trap holds; the port lock G is taken
  only to resolve the port name) until each target is parked, inside a trap
  (its entry frame is published, `mach-ipc-locking.md` §4.2), not on a vCPU,
  gone, or its image is ending. A target therefore never waits for a lock
  the suspender holds.
- *State reads.* `thread_get_state` (routine 17, on the IPC fast path,
  `mach-ipc-locking.md` §4.10) reports, in this order: the parked
  registers, the entry frame of the trap in progress, a never-started
  thread's start state. A suspended thread between the end of its trap and
  its gate (microseconds) gets the private answer 0x7963_0000, and the
  library asks again. A thread running user code that is **not** suspended
  still gets KERN_FAILURE: xnu would stop it briefly, but libobjc samples
  every thread before it frees method caches and treats a failure as "in a
  critical section" (unchanged from §11.3 of `host-libraries.md`).
- *State writes.* A parked thread takes the new registers when it is
  resumed (the vCPU's registers, or the slot frame). A thread inside a trap
  gets a replacement that the vCPU applies when the trap ends (the trap's
  x0, x1 and carry kept). A thread parked at a trap's entry is inside its
  trap: the same rule.
- *Ending.* A process that ends while a thread is parked releases its
  gates: the thread continues and sees the end. A suspender whose own image
  ends stops waiting.
- *Cost.* A thread that is never suspended pays one relaxed load per guest
  entry and per trap; no lock, no system call. Timed boots are unchanged
  (`service-fidelity.md` §14). A suspension of a spinning thread takes
  70–200 µs on the Linux host under load (mean over 2000
  suspend/get_state/resume rounds of the guest probe `p_tsus`), of a
  thread blocked in `semaphore_wait` about 100 µs.
- *Results.* `p_tsus` (spinning, self-suspending and blocked threads,
  counts, state reads and writes, `thread_info`, `task_suspend`/`resume`
  of a child, a start-suspended child resumed by SIGCONT) passes; the
  JavaScriptCore stress `p_jsgc` crashes on the main line and passes with
  this work; amsengagementd's collector crashes are gone
  (`app-launch.md` §3.6).
- *Not done.* Suspend counts are not saved in snapshots, and a thread
  parked at its gate is not a settled thread for the snapshot quiesce
  (`snapshot.md` §3): a snapshot retries until it is resumed. `thread_get_state`
  and `thread_info` still serve only threads of the caller's task;
  `thread_suspend`/`resume`/`set_state` take a thread of any task. No
  NEON or debug-state flavors. `task_suspend2`/`task_resume2` (suspension
  tokens) and `pid_suspend`/`pid_resume` remain stubs.

---

## 2. Workqueues (Q2)

### 2.1 Model

Each process has at most one **workqueue**: a kernel-managed pool of threads
plus a queue of **thread requests**. A thread request names a QoS, a count,
and a type:

| Type | Source | Admission (§2.5) |
|---|---|---|
| constrained (non-overcommit) | `REQTHREADS` without the overcommit flag; workloops without it | Limited by CPU parallelism and a pool cap |
| overcommit | `REQTHREADS` with `_PTHREAD_PRIORITY_OVERCOMMIT_FLAG`; every kqworkq QoS bucket | Always admitted (up to 512 threads in total) |
| cooperative | `REQTHREADS2` | At most one thread per CPU |
| event manager | the kqworkq manager bucket (§3.8) | At most one manager thread at a time |
| kevent | a kqworkq bucket with active events | Delivered with an event list |
| workloop | a workloop with active events (§2.9) | Delivered with an event list and the workloop ID |

A worker thread runs one request, returns to the kernel with a `*_RETURN`
operation, and then takes the next request or parks. Each new piece of work
**restarts the thread at `start_wqthread`** with fresh registers. Nothing on
its stack survives.

### 2.2 `workq_open` (BSD 367)

No arguments. `EINVAL` if `bsdthread_register` has not run. Otherwise it
creates the process workqueue if there is none, and returns 0. It is
idempotent. The event-manager priority starts at the task's default manager
QoS.

### 2.3 `workq_kernreturn` (BSD 368)

Registers: `x0` = op, `x1` = `item` (pointer), `x2` = `arg2` (int, named
"affinity" in the syscall table), `x3` = `arg3` (int, "prio"). Every op fails
with `EINVAL` if `bsdthread_register` has not run. Unknown ops: `EINVAL`.

| Op | Name | Arguments | Behavior and result |
|---|---|---|---|
| `0x004` | `THREAD_RETURN` | — | Plain worker is done. Parks or takes the next request (§2.7). Does not return to the caller on success |
| `0x010` | `QUEUE_NEWSPISUPP` | arg2 = queue serial-number offset; arg3 bit 0 = kevent support | Legacy. Records the offset. Returns 0 |
| `0x020` | `QUEUE_REQTHREADS` | arg2 = count; arg3 = `pthread_priority_t` | Adds a thread request. `EINVAL` if no workqueue, count ≤ 0 or > 65535, or the QoS is unspecified. The overcommit flag in arg3 selects the overcommit type. Returns 0 |
| `0x030` | `QUEUE_REQTHREADS2` | as above | Cooperative request. `ENOTSUP` if count > 1. `EINVAL` if arg3 also has the overcommit flag |
| `0x040` | `THREAD_KEVENT_RETURN` | item = change list (`kevent_qos_s[]`), arg2 = count | kevent worker is done; apply its pending changes, then redeliver or park (§2.7) |
| `0x080` | `SET_EVENT_MANAGER_PRIORITY` | arg2 = `pthread_priority_t` | `EINVAL` if no workqueue. With `SCHED_PRI_FLAG`: keep `flag | sched-pri` (bits 15–0). Otherwise the QoS must be set and relpri in −15…0 (`EINVAL`), and flags are stripped. The stored manager priority becomes the **maximum** of old and new. Returns 0 |
| `0x100` | `THREAD_WORKLOOP_RETURN` | item = change list, arg2 = count | Workloop worker is done; as `0x040` for its workloop |
| `0x200` | `SHOULD_NARROW` | arg2 = `pthread_priority_t` | Only from a constrained workqueue thread (`EINVAL` from other threads, overcommit threads, or dying threads; `EINVAL` for unspecified QoS). Returns `x0 = 1` if the constrained pool has no room for this thread at that QoS (it should park), else 0 |
| `0x400` | `SETUP_DISPATCH` | item = config record, arg2 = its size | Copies min(24, size) bytes of the record below. `ENOTSUP` if `flags ≠ 0` or `version < 1`. Stores the offsets. Works before `workq_open`. Returns 0 |

`SETUP_DISPATCH` record (packed, 4-byte aligned, 24 bytes):

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | version (current: 2) |
| 4 | 4 | flags (must be 0) |
| 8 | 8 | serial-number offset in a dispatch queue (version ≥ 1) |
| 16 | 8 | label offset in a dispatch queue (version ≥ 2) |

The offsets are used only for diagnostics (naming threads after the queue
they run). Ycode can store and ignore them.

### 2.4 Priority encoding

**Thread QoS** (the kernel's small integers):

| Value | QoS | Public `qos_class_t` |
|---|---|---|
| 0 | unspecified | `0x00` |
| 1 | maintenance | `0x05` |
| 2 | background | `0x09` |
| 3 | utility | `0x11` |
| 4 | legacy (default) | `0x15` |
| 5 | user-initiated | `0x19` |
| 6 | user-interactive | `0x21` |
| 7 | (above UI; "last") | — |
| 8 | workqueue event manager (kernel-internal bucket) | — |

**`pthread_priority_t`** (32 significant bits):

| Bits | Meaning |
|---|---|
| 7–0 | relative priority − 1, as a byte (relpri 0 → `0xFF`, −1 → `0xFE`, …, −15 → `0xF0`) |
| 13–8 | requested QoS as **one-hot**: bit `8 + qos − 1` |
| 21–14 | override QoS, one-hot (only with `OVERRIDE_QOS_FLAG`, input only) |
| 15–0 | instead, a scheduler priority when `SCHED_PRI_FLAG` is set |
| 31–24 | flags (below), plus bit 23 |

| Flag | Value | Meaning |
|---|---|---|
| `OVERCOMMIT` | `0x8000_0000` | Overcommit thread or request |
| `INHERIT` | `0x4000_0000` | libdispatch only |
| `ROOTQUEUE` / `SCHED_PRI` | `0x2000_0000` | libdispatch: root queue. Kernel: the low 16 bits are a scheduler priority |
| `ENFORCE` | `0x1000_0000` | libdispatch only |
| `COOPERATIVE` | `0x0800_0000` | Cooperative pool |
| `FALLBACK` (`DEFAULTQUEUE`) | `0x0400_0000` | Use only if an event has no QoS |
| `EVENT_MANAGER` | `0x0200_0000` | Event-manager thread or knote |
| `NEEDS_UNBIND` | `0x0100_0000` | Output to libdispatch: this thread is bound to a kqueue |
| `OVERRIDE_QOS` | `0x0080_0000` | Bits 21–14 hold an override QoS (input only) |

Decoding rules:

- "Has QoS" ⇔ neither `SCHED_PRI` nor `EVENT_MANAGER` is set **and** bits
  13–8 are non-zero. QoS = 1 + index of the lowest set bit in bits 13–8.
  Relpri = `(int8)(pp & 0xFF) + 1`.
- Examples with relpri 0: maintenance `0x1FF`, background `0x2FF`, utility
  `0x4FF`, legacy `0x8FF`, user-initiated `0x10FF`, user-interactive
  `0x20FF`. `pthread_priority_t` values are numerically ordered by
  effective priority.

### 2.5 When the kernel creates or wakes worker threads

1. A thread request is satisfied by an **idle** worker if one exists,
   otherwise by creating a new worker (until 512 threads exist).
2. **Overcommit** requests are always admitted.
3. **Constrained** requests are admitted only while both hold:
   - (threads running at this QoS or higher) + (threads that blocked within
     the last ~200 µs) < the CPU parallelism for that QoS (about the
     logical CPU count);
   - constrained threads scheduled < max(64, 5 × CPU count).
   A running worker that **blocks in the kernel** stops counting as
   running, so a blocked worker frees a slot and another worker may start.
   When the "recently blocked" window prevents admission, the kernel retries
   on a timer.
4. **Manager** requests are admitted when no manager thread is running.
5. **Cooperative** requests are limited to one thread per CPU.
6. Among admissible requests, the highest QoS wins.
7. For a request with count > 1, idle threads up to count − 1 may be woken
   at once; the rest go through the normal path.
8. Idle threads above a small threshold exit after about 5 s idle (longer
   when few are idle). Exiting uses the exit entry of §2.6.

Note for Ycode: rules 3, 7, and 8 are scheduling policy. They change
performance, not correctness, **except** that libdispatch relies on rule 3's
"a blocked worker frees a slot" to avoid deadlock when work items block.
Any Ycode policy must start another constrained worker when every
admitted constrained worker is blocked and requests are pending.

Ycode's cooperative pool (rule 5; speed work 2026-10-17): `QUEUE_REQTHREADS2`
queues one cooperative request at its QoS. It is admitted while fewer
cooperative workers are running than the guest has CPUs (N, the guest CPU
count of `darwin-process-start.md`), or while no cooperative worker runs at its QoS (each QoS gets one
thread, so a lower QoS cannot starve a higher one). A cooperative worker
counts until it returns, **blocked or not**: the cooperative pool does not
grow when its threads block (unlike rule 3). The thread starts with
`COOPERATIVE` in `x4` (§2.6), is not constrained (`SHOULD_NARROW` is
`EINVAL`), and its `THREAD_RETURN` takes the next admissible request, as
for any worker. Before this, Ycode refused the op with `ENOTSUP`, and
`libsystem_pthread` turned every cooperative request into a constrained
one (up to 8 threads per QoS; `host-libraries.md` §11.6). Swift-concurrency
daemons then ran their request–return cycle on several threads at once,
more than 1000 times a second each.

The pool alone did not stop that cycle (measured 2026-10-17, full boots,
700 s): suggestd, parsecd and axassetsd made 4.2 / 2.3 / 1.6 M traps
without the pool and 5.3–6.4 / 3.7–6.2 / 2.5–5.2 M with it, at N = 1 or
N = 14. The cycle's cause was the guest timebase, not the workqueue: Swift
Concurrency converts task deadlines to mach ticks at a fixed 24 MHz, so on
a 1 GHz guest counter every `Task.sleep` fired at once and sleeping tasks
spun through the cooperative queue (`darwin-process-start.md` §5, "Guest
timebase"). With the 24 MHz guest timebase the three daemons and homed make
0.01–0.07 M traps each per boot.

### 2.6 Worker stack and the `start_wqthread` entry state

The kernel allocates each worker's memory once, when it creates the thread.
With 16 KiB pages and `PTHREAD_SIZE` = 16384:

| Region (from the allocation base B) | Size | Use |
|---|---|---|
| `[B, B + 16 KiB)` | 1 page | Guard, `PROT_NONE` |
| `[B + 16 KiB, B + 528 KiB)` | 512 KiB | Stack |
| `[B + 528 KiB, B + 560 KiB)` | round_page(16 KiB + 12 KiB) = 32 KiB | Stack top area, then the `pthread_t` |

- The allocation is 560 KiB, tagged `VM_MEMORY_STACK` (30), placed anywhere
  at or above the stack-address hint (`host-library-init.md` §6.1).
- **`self`** (the `pthread_t`) = B + 16 KiB + 512 KiB + 12 KiB = **B + 540
  KiB**. The 16 KiB `pthread_t` ends at B + 556 KiB.
- **Stack bottom** = B + 16 KiB.
- The worker's thread port name is made on first use and kept for the
  thread's lifetime.
- On **first use only**, the kernel sets the TSD base = `self + 224` and
  adds `WQ_FLAG_THREAD_TSD_BASE_SET`.

**Event area** (only when the upcall has `WQ_FLAG_THREAD_KEVENT`):

| Item | Address |
|---|---|
| Event list (16 × `kevent_qos_s`, 72 bytes each = 1152 bytes) | `L = self − 1152` |
| Data area (32 KiB) | `[L − 32768, L)` |
| Workloop ID (`uint64`, workloop upcalls only) | `L − 8` (taken from the top of the data area) |
| Received Mach messages (§3.7.3) | carved **downward** from the top of the remaining data area |

The kernel fills the list by an immediate event scan of the bound kqueue
(flags `STACK_DATA | IMMEDIATE`). Then:

- `sp` = (data-area bottom + bytes of the data area still unused) rounded
  down to 16. That is, the stack starts just below the lowest byte the
  kernel wrote.
- Without the kevent flag, `sp` = `self` rounded down to 16 (= `self`).
- If the scan fails, `x3` = 0 and `x5` = 0.

**Entry registers.** All other GPRs and V0–V31/FPSR/FPCR are zero:

| Register | Value |
|---|---|
| pc | registered `start_wqthread` |
| x0 | `self` |
| x1 | the thread's port name |
| x2 | stack bottom (B + 16 KiB) |
| x3 | event list `L`, or 0 when the upcall has no kevent flag |
| x4 | upcall flags (below) |
| x5 | number of events (0…16), or **−1** = "exit this thread" |
| sp | as above |
| `TPIDRRO_EL0` | `self + 224` (set on first use, kept after) |

**Upcall flags** (`x4`):

| Bit | Value | Meaning |
|---|---|---|
| `PRIO_MASK` | `0x0000_0FFF` | With `PRIO_QOS`: the **thread QoS number** (§2.4 table, 1–6, or 8 for the manager). With `PRIO_SCHED`: a scheduler priority |
| `PRIO_QOS` | `0x0000_4000` | Low bits are a QoS |
| `PRIO_SCHED` | `0x0000_8000` | Low bits are a scheduler priority |
| `OVERCOMMIT` | `0x0001_0000` | Overcommit request |
| `REUSE` | `0x0002_0000` | Not the first run of this thread (its `pthread_t` is already set up) |
| `NEWSPI` | `0x0004_0000` | Always set |
| `KEVENT` | `0x0008_0000` | `x3`/`x5` carry events |
| `EVENT_MANAGER` | `0x0010_0000` | This is the event-manager thread |
| `TSD_BASE_SET` | `0x0020_0000` | Kernel set the TSD base (first use) |
| `WORKLOOP` | `0x0040_0000` | Workloop upcall; the workloop ID is at `x3 − 8` |
| `OUTSIDEQOS` | `0x0080_0000` | Thread runs at a fixed priority; no QoS bits |
| `COOPERATIVE` | `0x0100_0000` | Cooperative pool |

Flag combinations the kernel produces:

| Case | `x4` |
|---|---|
| Plain request | `NEWSPI` · `PRIO_QOS` · qos · (`OVERCOMMIT` or `COOPERATIVE` by type) |
| kqworkq QoS bucket | `NEWSPI` · `KEVENT` · `OVERCOMMIT` · `PRIO_QOS` · qos |
| kqworkq manager | `NEWSPI` · `KEVENT` · `EVENT_MANAGER` · `PRIO_QOS` · 8 |
| Workloop | `NEWSPI` · `KEVENT` · `WORKLOOP` · (`OVERCOMMIT` if the workloop is overcommit) · either `PRIO_QOS` · qos, or `OUTSIDEQOS` for a fixed-priority workloop |
| Exit | `NEWSPI` · `PRIO_QOS` · min(qos, 4); `x3` = 0, `x5` = −1 |
| Any case, not the first run | add `REUSE` |
| Any case, first run | add `TSD_BASE_SET` (when a TSD offset is registered) |

The user-side contract that Ycode's `libsystem_pthread` must meet (from
libpthread's workqueue header; level 1): `pthread_workqueue_setup` takes
three callbacks: `workq_cb(pthread_priority_t)`, `kevent_cb(void **events,
int *nevents)`, and `workloop_cb(uint64_t *workloop_id, void **events, int
*nevents)`. The `pthread_priority_t` passed on is built from `x4`: the QoS
from the low bits, `OVERCOMMIT`, `NEEDS_UNBIND` when `KEVENT` is set, or
just `EVENT_MANAGER` for the manager; `COOPERATIVE` is added for cooperative
threads. After a kevent or workloop callback, the thread returns with op
`0x040` or `0x100`, passing back the (possibly rewritten) event pointer and
count as its change list.

### 2.7 Return, reuse, park, and exit

1. `THREAD_RETURN`/`*_RETURN` from a thread that is not a workqueue thread,
   or that is dying: `EINVAL`. A non-empty change list from a thread that is
   not bound to a kqueue request: `EINVAL`.
2. The thread's signal mask is reset: every signal is blocked **except**
   SIGILL, SIGTRAP, SIGEMT, SIGFPE, SIGBUS, SIGSEGV, SIGSYS, SIGPIPE,
   SIGKILL, SIGSTOP, SIGPROF, and the signals the process allowed with
   `WORKQ_ALLOW_SIGMASK`. (SIGABRT stays blocked.)
3. **kevent/workloop return** (`0x040`/`0x100`): the kernel applies the
   change list to the bound kqueue (flags `STACK_DATA | IMMEDIATE |
   PARKING`) and scans it again into the same event area.
   - If events are found, the thread is restarted at `start_wqthread` with
     `REUSE | KEVENT` (and `WORKLOOP` / `EVENT_MANAGER` / `OVERCOMMIT` /
     `PRIO_QOS`·qos as before) and the new count. The call does not return.
   - If none are found, the thread is unbound from the kqueue and goes to
     step 4. Delivered events stay **suppressed** until this return
     (§3.8, rule K4).
   - Every change is applied. A change that fails does **not** fail the
     call: it is copied out as an `EV_ERROR` event (data = errno) into the
     thread's event area, ahead of the events the scan finds, and the
     thread is restarted with them as above (libpthread's kernel side
     applies the list with `STACK_DATA | IMMEDIATE | PARKING` and no
     `ERROR_EVENTS`, so errors are output events; level 1). Only an error
     of the kevent call itself is returned to the caller. (Ycode until
     2026-10-28: the first failure stopped the list and was returned as
     the errno; the changes after it were lost, and libdispatch later
     aborted with "BUG IN LIBDISPATCH: Invalid wlh state": assistantd in
     about half of the main line's full boots, amsengagementd once its
     collector no longer crashed, `app-launch.md` §3.6.)
4. **Next work:** if the workqueue has an admissible request (§2.5), the
   thread takes it and restarts at `start_wqthread` with `REUSE`.
   Otherwise it parks on the idle list. A parked thread is woken for a later
   request or for exit.
5. **Exit:** an idle thread chosen to die is restarted at `start_wqthread`
   with `x5 = −1` and a QoS no higher than legacy. Its library then exits the
   thread with `bsdthread_terminate`, which takes the workqueue thread out
   of the pool (§1.2 rule 1).

### 2.8 libdispatch's requirements on the feature mask

`host-library-init.md` §6.4 proposed starting with mask `0x4000_001F`. The
libdispatch source shows that this is **not enough** for libdispatch:

- It needs `WORKQ_FEATURE_MAINTENANCE` (`0x10`), or it crashes.
- It needs `WORKQ_FEATURE_WORKLOOP` (`0x80`) or `WORKQ_FEATURE_KEVENT`
  (`0x40`). With neither, it crashes ("Missing Kevent WORKQ support").
- Its kevent-workqueue mode is on in release builds. In that mode **every
  serial queue that targets a root queue becomes a workloop**, and
  libdispatch calls `kevent_id` and expects workloop upcalls, whatever the
  `WORKLOOP` bit says. With `KEVENT` but not `WORKLOOP`, no workloop callback
  is registered, so the first workloop upcall would fail.

**Conclusion:** before `launchd_sim` runs, the VMM must return a mask with
`KEVENT | WORKLOOP` (`0x40 | 0x80`) and implement workloops (§2.9, §3.7.4).
`COOPERATIVE_WORKQ` (`0x100`) is optional; see Open question 3.

### 2.9 Workloops

A **workloop** is a kqueue with a 64-bit ID (libdispatch uses the address of
the serial queue), serviced by at most one worker thread at a time.

**Creation and lookup:**

- `kevent_id` (§3.1) finds the workloop by ID and creates it if it does not
  exist, unless `KEVENT_FLAG_DYNAMIC_KQ_MUST_EXIST` (`ENOENT`) or
  `…MUST_NOT_EXIST` (`EEXIST` if it exists) is given. IDs 0 and −1 are
  invalid (`EINVAL`).
- `kqueue_workloop_ctl` (BSD 530): `x0` = cmd (1 = CREATE, 2 = DESTROY),
  `x1` = options (unused), `x2` = params, `x3` = size. CREATE makes a
  workloop that has fixed scheduling parameters (`EEXIST` if the ID exists,
  `EINVAL` if no parameter flag is given or a value is out of range).
  DESTROY drops the reference that CREATE took. Params (packed, 36 bytes):

  | Offset | Field |
  |---|---|
  | 0 | `int32` version |
  | 4 | `int32` flags: SCHED_PRI 1, SCHED_POL 2, CPU_PERCENT 4, WORK_INTERVAL 8, WITH_BOUND_THREAD 0x10 |
  | 8 | `uint64` workloop ID |
  | 16 | `int32` sched_pri (1…63) |
  | 20 | `int32` sched_pol |
  | 24 | `int32` cpu_percent (1…100) |
  | 28 | `int32` cpu_refillms (1…0xFFFFFF) |
  | 32 | `uint32` work-interval port |

  libdispatch uses it only for workloops created with scheduler
  attributes. A workloop with a fixed priority is serviced with
  `OUTSIDEQOS` upcalls.
- A workloop is freed when nothing refers to it any more (no knotes, no
  servicer, no CREATE reference).

**Servicing rules:**

1. When any knote of the workloop becomes active, and the workloop has no
   servicer and **no owner** (rule 3), the workloop issues one thread
   request at the highest QoS of its active knotes. The request is
   overcommit if any knote was registered with the overcommit flag in its
   `qos`.
2. The worker bound to that request gets a `WORKLOOP | KEVENT` upcall. Its
   event list holds the workloop's active knotes, and `x3 − 8` holds the
   workloop ID. While bound, that worker is the workloop's **servicer**.
3. The **owner** is a thread that user space says is draining the queue
   right now (`NOTE_WL_DISCOVER_OWNER`, §3.7.4). While an owner is set, the
   thread-request knote is not delivered (it stays active and pending).
4. Only the servicer may ask a workloop for events through `kevent_id`;
   any other thread that asks for events gets `EXDEV`. Any thread may
   register changes with `KEVENT_FLAG_ERROR_EVENTS`.
5. The servicer ends with `WORKLOOP_RETURN` (§2.7 step 3). If the workloop
   gained events meanwhile and has no owner, it is redelivered; otherwise
   the worker unbinds and the workloop may issue a new request later.

---

## 3. kevent (Q3)

### 3.1 System calls

| # | Call | Registers |
|---|---|---|
| 362 | `kqueue()` | Returns a new kqueue fd |
| 443 | `guarded_kqueue_np(guard *, guardflags)` | As `kqueue`, with an fd guard |
| 363 | `kevent(fd, changes, nchanges, events, nevents, timeout)` | `struct kevent` (32 bytes); `timeout` = `struct timespec *` (NULL = wait forever) |
| 369 | `kevent64(fd, changes, nchanges, events, nevents, flags, timeout)` | `struct kevent64_s` (48 bytes); `flags` = `KEVENT_FLAG_*`; `timeout` as above |
| 374 | `kevent_qos(fd, changes, nchanges, events, nevents, data_out, data_available, flags)` | `struct kevent_qos_s` (72 bytes). **No timeout argument**: it waits forever unless `KEVENT_FLAG_IMMEDIATE` |
| 375 | `kevent_id(id, changes, nchanges, events, nevents, data_out, data_available, flags)` | As `kevent_qos`, on the workloop `id` |

- `data_out` / `data_available`: an output buffer and a pointer to its size
  (`size_t`, in/out). Used for Mach messages received by `EVFILT_MACHPORT`.
  When the call used part of the buffer, the remaining size is written
  back. Either pointer 0 means "no buffer".
- Return: number of events written (≥ 0), or −1/errno. A signal ends a wait
  with `EINTR` (the call is not restarted).
- Only the `KEVENT_FLAG_*` bits in the "user" set (§3.3) are honored; others
  are dropped.
- `kevent`, `kevent64`: any of `WORKLOOP`, `DYNAMIC_KQ_MUST_EXIST`,
  `…MUST_NOT_EXIST` → `EINVAL`. An invalid timespec → `EINVAL`.
- `kevent_qos`: the same three flags → `EINVAL`. With `KEVENT_FLAG_WORKQ`
  the call acts on the process's **workqueue kqueue** (§3.8; created on
  first use, `fd` ignored) and asking it for events (`nevents > 0` without
  `ERROR_EVENTS`) → `EINVAL`. Otherwise `fd` must be a kqueue (`EBADF`).
- `kevent_id`: flags must contain `WORKLOOP` and not `WORKQ` (`EINVAL`).
  See §2.9 for creation, `EXDEV`, `ENOENT`, `EEXIST`.
- A kqueue fd takes its event format from its first use. Using a kqueue
  with `kevent` after `kevent64`/`kevent_qos`, or the other way round, is
  `EINVAL`. `kevent64` and `kevent_qos` may be mixed.

### 3.2 Structure layouts (arm64, little-endian)

`struct kevent` (4-byte packed, 32 bytes):

| Off | Size | Field |
|---|---|---|
| 0 | 8 | `ident` |
| 8 | 2 | `filter` (int16) |
| 10 | 2 | `flags` |
| 12 | 4 | `fflags` |
| 16 | 8 | `data` (intptr) |
| 24 | 8 | `udata` |

`struct kevent64_s` (48 bytes):

| Off | Size | Field |
|---|---|---|
| 0 | 8 | `ident` |
| 8 | 2 | `filter` |
| 10 | 2 | `flags` |
| 12 | 4 | `fflags` |
| 16 | 8 | `data` (int64) |
| 24 | 8 | `udata` |
| 32 | 16 | `ext[2]` |

`struct kevent_qos_s` (72 bytes):

| Off | Size | Field |
|---|---|---|
| 0 | 8 | `ident` |
| 8 | 2 | `filter` |
| 10 | 2 | `flags` |
| 12 | 4 | `qos` (int32, a `pthread_priority_t`) |
| 16 | 8 | `udata` |
| 24 | 4 | `fflags` |
| 28 | 4 | `xflags` (always 0 on output) |
| 32 | 8 | `data` (int64) |
| 40 | 32 | `ext[4]` |

Input rules: the kernel clears the system flag bits `0xF000` of `flags` in
every change. `kevent64` changes carry only `ext[0]`, `ext[1]`; `kevent`
changes carry no `ext`.

### 3.3 `KEVENT_FLAG_*`

| Flag | Value | Meaning |
|---|---|---|
| `IMMEDIATE` | `0x000001` | Never wait |
| `ERROR_EVENTS` | `0x000002` | Output only errors of the change list; never scan for events |
| `STACK_DATA` | `0x000008` | Carve `data_out` from the top downward (stack-like) instead of upward |
| `WORKQ` | `0x000020` | Act on the process workqueue kqueue |
| `WORKQ_MANAGER` | `0x000200` | Obsolete |
| `WORKLOOP` | `0x000400` | Act on a workloop (`kevent_id` only) |
| `PARKING` | `0x000800` | Kernel-internal (worker returning to park) |
| `WORKLOOP_SERVICER_ATTACH`/`DETACH` | `0x008000`/`0x010000` | Obsolete |
| `DYNAMIC_KQ_MUST_EXIST` | `0x020000` | `kevent_id`: fail with `ENOENT` instead of creating |
| `DYNAMIC_KQ_MUST_NOT_EXIST` | `0x040000` | `kevent_id`: fail with `EEXIST` if it exists |
| `WORKLOOP_NO_WQ_THREAD` | `0x080000` | Obsolete |

The "user" set (kept, others dropped): `IMMEDIATE`, `ERROR_EVENTS`,
`STACK_DATA`, `WORKQ`, `WORKLOOP`, `DYNAMIC_KQ_MUST_EXIST`,
`DYNAMIC_KQ_MUST_NOT_EXIST`.

### 3.4 Processing rules for one call

1. Apply the changes in order. For each change:
   - Find the knote by (`ident`, `filter`) in this kqueue; with
     `EV_UDATA_SPECIFIC`, the `udata` must also match (and only knotes that
     were added with `EV_UDATA_SPECIFIC` match). Filters on fds look up by
     fd; others by ident.
   - Unknown filter number → error `EINVAL`.
   - The result is an error code or success.
2. If the change has an error **or** has `EV_RECEIPT`, and output space is
   left, copy the change to the output list with `EV_ERROR` set and `data`
   = the errno (0 for a successful receipt). This counts as an output event.
3. If a change fails and there is no output space, the call stops and
   returns −1 with that errno.
4. If `ERROR_EVENTS` is not set, `nevents > 0`, no output was written in
   step 2, and no error occurred: **scan** for triggered events (§3.6). If
   none are ready, wait (unless `IMMEDIATE`) until an event fires, the
   timeout expires (return 0), or a signal arrives (`EINTR`).
5. Return the number of output events.

### 3.5 `EV_*` flags

| Flag | Value | Meaning |
|---|---|---|
| `EV_ADD` | `0x0001` | Add the knote, or modify it if it exists. Implies enable |
| `EV_DELETE` | `0x0002` | Remove it. Overrides `EV_ADD`. Missing knote → `ENOENT` (except workloops: `EV_ADD|EV_DELETE` is a "soft" delete that ignores `ENOENT`) |
| `EV_ENABLE` | `0x0004` | Re-enable a disabled knote |
| `EV_DISABLE` | `0x0008` | Disable (do not report). Overrides `EV_ENABLE`. A knote added with `EV_DISABLE` starts disabled |
| `EV_ONESHOT` | `0x0010` | Remove after the first delivery (see `EV_DISPATCH2`) |
| `EV_CLEAR` | `0x0020` | Reset the state after delivery (edge-triggered) |
| `EV_RECEIPT` | `0x0040` | Always report the change result as an event (§3.4) |
| `EV_DISPATCH` | `0x0080` | Disable automatically after each delivery |
| `EV_UDATA_SPECIFIC` | `0x0100` | `udata` is part of the knote's identity |
| `EV_DISPATCH2` | `0x0180` | `EV_DISPATCH | EV_UDATA_SPECIFIC` |
| `EV_VANISHED` | `0x0200` | Input: ask to be told when the source vanishes. Only valid with `EV_ADD | EV_DISPATCH2` (else `EINVAL`). Output: the source vanished |
| `EV_FLAG0` (`EV_POLL`) | `0x1000` | Filter-specific (READ: poll semantics) |
| `EV_FLAG1` (`EV_OOBAND`) | `0x2000` | Filter-specific (READ: out-of-band data) |
| `EV_ERROR` | `0x4000` | Output: `data` holds an errno |
| `EV_EOF` | `0x8000` | Output: end of file / source gone |

After a knote fires and is delivered:

- `EV_ONESHOT`: drop it. With `EV_DISPATCH2`, it is not dropped; it becomes
  disabled and "delete-pending" (the user then deletes it).
- else `EV_DISPATCH`: disable it.
- else `EV_CLEAR`: leave it inactive until the source fires again.
- else (level-triggered): keep it active, so it is reported again while the
  condition holds.

**Deferred delete:** `EV_DELETE` (without `EV_ENABLE`) of a disabled
`EV_DISPATCH2` knote returns `EINPROGRESS` and marks it delete-pending. A
later enable of it delivers one synthetic event with flags `EV_DELETE |
EV_DISPATCH2 | EV_ONESHOT`, and the knote is then dropped. `EV_DELETE |
EV_ENABLE` together drops it at once. A knote whose source vanished, and
which asked for `EV_VANISHED`, delivers one synthetic event with flags
`EV_VANISHED | EV_DISPATCH2 | EV_ONESHOT`.

**QoS of knotes:** for a plain kqueue fd the `qos` field is ignored. On the
workqueue kqueue, an unspecified QoS means the **manager** bucket. On a
workloop, every enabled knote must have a QoS (`ERANGE` otherwise). The
output `qos` field is the knote's QoS combined with any override.

### 3.6 Scan

A scan takes active, enabled knotes, asks the filter whether each is
still triggered, and copies out the event. Each knote is reported at most
once per scan. On a workqueue kqueue or a workloop, delivered knotes stay
**suppressed** (not redelivered to another thread) until the receiving
worker returns to the kernel (§3.8 rule K4). On a kqueue fd, they are
released at the end of the scan.

### 3.7 Filters

libdispatch uses these filters. The order follows what `launchd_sim` and
libdispatch need first.

#### 3.7.1 `EVFILT_USER` (−10)

| Field | Meaning |
|---|---|
| `ident` | Any number chosen by user space |
| `fflags` in | Bits 23–0 user flags; bits 31–30 control: `NOTE_FFNOP` 0, `NOTE_FFAND` `0x4000_0000`, `NOTE_FFOR` `0x8000_0000`, `NOTE_FFCOPY` `0xC000_0000`; `NOTE_TRIGGER` `0x0100_0000` fires the knote |
| `data` in | Stored and returned as is |
| out | `fflags` = stored user flags, `data` = stored data |

Rules: the add fires only if `NOTE_TRIGGER` is set. A modify applies the
fflags operation, stores `data`, and fires if `NOTE_TRIGGER` is set. With
`EV_CLEAR`, delivery resets the triggered state. libdispatch registers ident
1 with `EV_ADD|EV_CLEAR` and `qos = EVENT_MANAGER` on the workqueue kqueue,
and triggers it to wake the manager thread.

#### 3.7.2 `EVFILT_TIMER` (−7)

Units (`fflags`): `NOTE_SECONDS` `0x01`, `NOTE_USECONDS` `0x02`,
`NOTE_NSECONDS` `0x04`, `NOTE_MACHTIME` `0x100` (Mach absolute-time ticks);
none = milliseconds; more than one → `EINVAL`. Other flags: `NOTE_ABSOLUTE`
`0x08`, `NOTE_LEEWAY` `0x10` (`ext[1]` = leeway, same units),
`NOTE_CRITICAL` `0x20`, `NOTE_BACKGROUND` `0x40` (coalescing hints),
`NOTE_MACH_CONTINUOUS_TIME` `0x80`.

| Form | Deadline |
|---|---|
| interval (no `NOTE_ABSOLUTE`) | now + `data` (in units). Repeats every `data` unless `EV_ONESHOT`. `data < 0` fires once immediately |
| absolute + `NOTE_MACHTIME` | `data` is a `mach_absolute_time` value (or `mach_continuous_time` with `NOTE_MACH_CONTINUOUS_TIME`) |
| absolute, other units | `data` is wall-clock time since 1970 in the given units, converted once to a deadline (past → fire at once) |

Rules: the filter always sets `EV_CLEAR`. `NOTE_ABSOLUTE` forces
`EV_ONESHOT`. Changing `NOTE_ABSOLUTE` on modify → `EINVAL`. Overflow →
`ERANGE`. A modify re-arms the timer. Output: `data` = number of intervals
that expired (1 for one-shot), `ext[0]` = 0.

libdispatch uses one-shot absolute timers: `EV_ONESHOT`, `fflags` =
`NOTE_ABSOLUTE | NOTE_LEEWAY | clock`, with clock = `NOTE_MACHTIME`
(uptime), `NOTE_MACHTIME | NOTE_MACH_CONTINUOUS_TIME` (monotonic), or
`NOTE_NSECONDS | NOTE_MACH_CONTINUOUS_TIME` (wall), plus `NOTE_CRITICAL` or
`NOTE_BACKGROUND`; `ident` = `~0 << 8 | index`; `ext[1]` = leeway.

#### 3.7.3 `EVFILT_MACHPORT` (−8)

| Field | Meaning |
|---|---|
| `ident` | A receive-right name or a port-set name (`ENOENT` if not valid; `ENOTSUP` if neither, or a special reply port) |
| `fflags` in | Optional receive options: `MACH_RCV_MSG`, `MACH_RCV_LARGE`, `MACH_RCV_LARGE_IDENTITY`, trailer options, `MACH_RCV_VOUCHER`. Changing `MACH_RCV_MSG` (or `MACH_RCV_SYNC_PEEK`) on modify → `EINVAL` |
| `ext[0]`, `ext[1]` in | Receive buffer address and size. Size 0 = carve from the call's data area |

Fires when the port (or any member of the set) has a message.

Delivery **without** `MACH_RCV_MSG`: no message is received. `data` = the
name of the port that has the message.

Delivery **with** `MACH_RCV_MSG`: the kernel receives the first message
directly into the buffer, never waiting (as if `MACH_RCV_TIMEOUT` with 0):

| Out field | Value |
|---|---|
| `fflags` | the `mach_msg` return code (`MACH_MSG_SUCCESS`, `MACH_RCV_TOO_LARGE`, …) |
| `ext[0]` | buffer address (when carved: the address chosen in the data area) |
| `ext[1]` | message size + trailer size (for `TOO_LARGE`: the size needed) |
| `ext[2]` | on success: (message priority << 32) | `pthread_priority_t` of the override QoS |
| `ext[3]` | size of auxiliary data placed after the message |
| `data` | the port name for `TOO_LARGE` with `MACH_RCV_LARGE_IDENTITY`, else 0 |

Carving from the data area: with `STACK_DATA`, from the top downward; else
from the bottom upward. When carving, `MACH_RCV_LARGE |
MACH_RCV_LARGE_IDENTITY` are forced, and the remaining size shrinks by
(message + trailer + aux). Destroying the port delivers `EV_EOF` (or
`EV_VANISHED`, §3.5).

libdispatch's receive options: `MACH_RCV_MSG | MACH_RCV_LARGE |
MACH_RCV_LARGE_IDENTITY | MACH_RCV_TRAILER_TYPE(0) |
MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AV) | MACH_RCV_VOUCHER`, with
`ext[1]` = 0, on workloops and on the workqueue kqueue. This filter needs
Ycode's Mach IPC (stage 5).

#### 3.7.4 `EVFILT_WORKLOOP` (−17)

Only on workloops (else `ENOTSUP`). Commands are in `fflags`:

| Bit | Value | Meaning |
|---|---|---|
| `NOTE_WL_THREAD_REQUEST` | `0x01` | The knote that asks for a servicer. `ident` must be the workloop ID (`EINVAL`); only one per workloop (`EALREADY`); needs a QoS (`ERANGE`) |
| `NOTE_WL_SYNC_WAIT` | `0x04` | A thread waits to become owner. `ident` = a per-waiter ID (libdispatch: its thread ID), must not be the workloop ID |
| `NOTE_WL_SYNC_WAKE` | `0x08` | Mark the waiter as allowed to proceed |
| `NOTE_WL_SYNC_IPC` | `0x8000_0000` | Sync-IPC push knote (port name in `ident`) |
| `NOTE_WL_UPDATE_QOS` | `0x10` | Thread request only: take the new QoS from `qos` |
| `NOTE_WL_END_OWNERSHIP` | `0x20` | If the caller is the owner, clear the owner |
| `NOTE_WL_DISCOVER_OWNER` | `0x80` | Learn the owner from the loaded value (below) |
| `NOTE_WL_IGNORE_ESTALE` | `0x100` | Turn `ESTALE` into silent success (the change is then **not** applied) |

`ext[]` for this filter: `ext[0]` lane, `ext[1]` debounce **address**,
`ext[2]` debounce **mask**, `ext[3]` debounce **value**.

Rules:

1. **Debounce.** If `ext[1] ≠ 0`, the kernel atomically loads the `uint64`
   at that address. If `(loaded & mask) ≠ (ext[3] & mask)`, the change fails
   with `ESTALE`. The loaded value is written back to `ext[3]`.
2. **Discover owner.** The loaded value's low 32 bits, with the low two
   bits cleared and then `| 3`, name a thread port (0 = no owner). That
   thread becomes the owner. A name that is not a thread of this task →
   `EOWNERDEAD`.
3. A `THREAD_REQUEST` knote is always `EV_CLEAR` and fires on every add or
   modify; deleting it cancels the request. On delivery, its `fflags` are its
   stored command bits and `data` = 0. If an owner is set, it is not
   delivered (§2.9 rule 3).
4. `SYNC_WAIT`/`SYNC_WAKE`/`SYNC_IPC` knotes must be added with
   `EV_DISABLE` (`EINVAL` otherwise). `SYNC_WAIT` may not carry
   `END_OWNERSHIP`.
5. **Sync wait.** Adding a `SYNC_WAIT` knote that has not been woken
   **blocks the calling thread inside `kevent_id`**. Requirements: it is the
   **last** change of the call (earlier changes, such as a thread-request
   change, are applied first; corrected 2026-10-12 from xnu
   `kevent_internal`), `ERROR_EVENTS` and `WORKLOOP` are set, and there is room for
   one output event (otherwise the change fails with `ENOTSUP`). The wait
   ends when another thread modifies the same knote with `SYNC_WAKE`, or
   deletes it (deleting an un-woken waiter wakes it), or on a signal
   (`EINTR` in the output event). While waiting, the waiter's QoS pushes on
   the owner or the servicer.
6. Modifying a sync knote: `EV_ENABLE` without `EV_DELETE` → `EINVAL`;
   the existing knote must be a sync knote (`EINVAL`). Setting `SYNC_WAKE`
   on a knote that is already woken **succeeds** (corrected 2026-10-12
   from xnu `filt_wlupdate`: `EALREADY` belongs only to a second
   thread-request attach, not to a repeated wake).

libdispatch's patterns (for testing): thread request = `EV_ADD|EV_ENABLE`,
`THREAD_REQUEST | IGNORE_ESTALE | UPDATE_QOS` (± `DISCOVER_OWNER`), debounce
on the queue's state word; leave = `EV_ADD|EV_DELETE|EV_ENABLE`; sync wait =
`EV_ADD|EV_DISABLE`, `SYNC_WAIT`; sync wake = `EV_ADD|EV_DISABLE`,
`SYNC_WAKE | DISCOVER_OWNER`; sync end = `EV_DELETE|EV_ENABLE`, `SYNC_WAKE |
END_OWNERSHIP`.

#### 3.7.5 `EVFILT_PROC` (−5)

`ident` = pid (`ESRCH` if none). `fflags` in = events wanted: `NOTE_EXIT`
`0x8000_0000`, `NOTE_FORK` `0x4000_0000`, `NOTE_EXEC` `0x2000_0000`,
`NOTE_REAP` `0x1000_0000` (deprecated), `NOTE_SIGNAL` `0x0800_0000`,
`NOTE_EXITSTATUS` `0x0400_0000`, `NOTE_EXIT_DETAIL` `0x0200_0000`. Output
`fflags` = the events that happened. On exit: `EV_EOF | EV_ONESHOT` are set
(unless `NOTE_REAP` was asked); with `NOTE_EXITSTATUS`, `data` = the
wait-style status (low 20 bits). launchd uses this for child exits.

#### 3.7.6 `EVFILT_SIGNAL` (−6)

`ident` = signal number. Only for the caller's own process. The filter sets
`EV_CLEAR`. It counts each **process-directed** posting of that signal,
**even if the signal is ignored or blocked** (the count is taken before the
ignore check). Thread-directed signals (`__pthread_kill`) do not count.
Output `data` = the count since the last delivery.

#### 3.7.7 Descriptors: `EVFILT_READ` (−1), `EVFILT_WRITE` (−2), `EVFILT_VNODE` (−4)

- READ: `ident` = fd. Fires when data can be read; `data` = bytes
  available (for a regular file: size − offset). `EV_EOF` when the writer
  side is closed. `NOTE_LOWAT` (`0x01`) uses `data` as the threshold.
- WRITE: fires when data can be written; `data` = space available. `EV_EOF`
  when the reader side is closed.
- VNODE: `ident` = fd. `fflags` in/out: `NOTE_DELETE` 1, `NOTE_WRITE` 2,
  `NOTE_EXTEND` 4, `NOTE_ATTRIB` 8, `NOTE_LINK` 0x10, `NOTE_RENAME` 0x20,
  `NOTE_REVOKE` 0x40, `NOTE_NONE` 0x80, `NOTE_FUNLOCK` 0x100. Which change
  posts which note, and Ycode's implementation: §3.10.

#### 3.7.8 Others libdispatch can register

`EVFILT_FS` (−9), `EVFILT_MEMORYSTATUS` (−14; memory-pressure source at
startup), `EVFILT_EXCEPT` (−15), `EVFILT_SOCK` (−13; implemented for IP
and local sockets since NET-IMPL, `networking-ycode.md` §2.5), `EVFILT_NW_CHANNEL`
(−16), `EVFILT_EXCLAVES_NOTIFICATION` (−18). Ycode may refuse them with an
`EV_ERROR` event (`EINVAL`/`ENOTSUP`) until a client needs them; see Open
question 4 for `EVFILT_MEMORYSTATUS`.

### 3.8 Delivery to workqueue threads (the workqueue kqueue)

The process's **workqueue kqueue** (kqworkq) is used through
`kevent_qos(…, KEVENT_FLAG_WORKQ)` and is serviced only by workqueue
threads.

- **K1. Buckets.** It has one bucket per thread QoS (1–6) plus a
  **manager** bucket. A knote goes to the bucket of its `qos`; a knote
  with no QoS (or with `EVENT_MANAGER`) goes to the manager bucket.
- **K2. Requests.** When a bucket has an active knote and no thread is
  requested or bound for it, it issues one thread request: overcommit
  `KEVENT` at that QoS, or a manager request for the manager bucket.
- **K3. Upcall.** The worker that takes the request is bound to that
  bucket and starts with `KEVENT` (and `EVENT_MANAGER` for the manager
  bucket) and up to 16 events from that bucket in its event area (§2.6).
- **K4. Suppression.** Delivered knotes stay suppressed (not given to
  another thread) until the worker returns with `THREAD_KEVENT_RETURN`.
  Then they are released; any still active are delivered again (to the same
  worker if its return finds events, §2.7 step 3).
- **K5. Unbinding.** `bsdthread_ctl(SET_SELF, WQ_KEVENT_UNBIND)` releases a
  non-manager worker from its bucket early. If the bucket still has active
  knotes, it issues a new request. The knotes delivered to that worker stay
  suppressed until its `THREAD_KEVENT_RETURN` (K4); when they are released
  then, a knote that became active meanwhile (a Mach message arrived while it
  was suppressed) makes its bucket issue a new request at that moment, since
  no bound worker will scan the bucket again. (Ycode missed this request
  until 2026-10-19: the reply then sat in the queue until the next message
  to the same bucket, found by agent SP-SNAP as the stall of an app install
  after a snapshot restore, `snapshot.md` §10.5.)
- **K6.** A user thread cannot read events from the workqueue kqueue
  directly (§3.1). Registering changes on it is allowed from any thread.

Workloops follow the same pattern with one request per workloop (§2.9).

### 3.9 The calls libdispatch actually makes

| Purpose | Call |
|---|---|
| Register on the workqueue kqueue | `kevent_qos(-1, changes, n, out, n_out, NULL/buf, NULL/&size, KEVENT_FLAG_WORKQ | IMMEDIATE | ERROR_EVENTS)` |
| Register or poll a workloop | `kevent_id(wlh, changes, n, out, n_out, buf, &size, WORKLOOP | IMMEDIATE | ERROR_EVENTS)`; when polling for events (no `ERROR_EVENTS`): plus `DYNAMIC_KQ_MUST_EXIST`, with a 32 KiB `data_out` buffer |
| Sync wait on a workloop | `kevent_id(wlh, &one_change, 1, &out, 1, …, WORKLOOP | ERROR_EVENTS)` — blocks (§3.7.4 rule 5) |
| Fallback if kevent workqueues are off (debug builds only) | `kqueue()` and plain `kevent_qos(kqfd, …)` with a manager thread |

libdispatch treats `ENOMEM` and `EINTR` from kevent as "retry", `EBADF` as
a client bug, `ENOENT` as fine only for `ERROR_EVENTS | MUST_EXIST`, and any
other errno as a crash. Per-change errors come back as `EV_ERROR` events;
libdispatch accepts `ENOENT`, `ESTALE`, `EINTR`, `EINPROGRESS`, `EOWNERDEAD`
only in specific cases.

### 3.10 `EVFILT_VNODE`: notes and Ycode's implementation (agent VNODE-EVENTS, 2026-10-28)

**Semantics (xnu).** A knote watches the vnode its descriptor names, not the
name: it follows renames and outlives an unlink while the descriptor is
open. Each file-system operation posts notes to the vnodes it changed
(`kpi_vfs.c`, the `post_event_if_success` calls after each `VNOP_*`); a
knote keeps the posted notes that its `fflags` (the interest mask, replaced
by each `EV_ADD`/touch) asks for, ORed together, until it is delivered
(`filt_vnode_common`: `kn_fflags |= hint` when `kn_sfflags & hint`). The
event's `fflags` are those notes, `data` 0. With `EV_CLEAR` delivery
forgets them; without it the knote stays active and is reported again at
every scan with the same notes (so clients use `EV_CLEAR`; libdispatch's
vnode sources do). `EV_ONESHOT` and `EV_DISPATCH` apply as for any filter
(§3.5). `NOTE_REVOKE` (revoke(2), a forced unmount) ends the knote: the
event carries `EV_EOF | EV_ONESHOT`, and `NOTE_REVOKE` in `fflags` when it
was asked for.

| Operation | Notes to the object | Notes to its directory (and the target's, for a move) |
|---|---|---|
| `write`, `pwrite`, `writev` (n > 0) | `NOTE_WRITE`; `NOTE_EXTEND` when the end passed the old size | — |
| `truncate`, `ftruncate`, `open(O_TRUNC)` of a non-empty file (VNOP_SETATTR) | `NOTE_ATTRIB`; `NOTE_EXTEND` when it grew | — |
| `chmod`, `fchmod`, `chown`, `utimes`, `futimes`, `chflags`, `setattrlist`, `setxattr`, `removexattr` | `NOTE_ATTRIB` | — |
| create (`open(O_CREAT)` of a new name), `clonefile` of a file | — | `NOTE_WRITE` |
| `mkdir`, `clonefile` of a directory | — | `NOTE_WRITE \| NOTE_LINK` |
| `unlink` | `NOTE_DELETE \| NOTE_LINK` | `NOTE_WRITE` |
| `rmdir` | `NOTE_DELETE \| NOTE_LINK` | `NOTE_WRITE \| NOTE_LINK` |
| `rename` | moved object `NOTE_RENAME`; a replaced target `NOTE_DELETE` | each directory `NOTE_WRITE`; `\| NOTE_LINK` when a directory moved to another directory without replacing one, or replaced one in the same directory |
| `renameatx_np(RENAME_SWAP)` | both `NOTE_RENAME` | each directory `NOTE_WRITE` (**Ycode decision**: `\| NOTE_LINK` when a directory and a non-directory swap between two directories) |
| `flock(LOCK_UN)` of a held lock | `NOTE_FUNLOCK` | — |

`NOTE_EXTEND` for writes and size changes follows kqueue(2)'s meaning
("the file was extended"); xnu's VNOP_WRITE itself posts only `NOTE_WRITE`
and leaves `NOTE_EXTEND` to the file system (**Ycode decision**: posted
whenever the size grew). Ycode has no hard links (`link`), no revoke(2) and
no unmount, so `NOTE_LINK` on a file comes only with its delete and
`NOTE_REVOKE` only from a post of the host (nothing posts it today).

**The registry** (`ycode/Sources/YcodeDarwinABI/VnodeNotes.swift`). Knotes
are registered by the watched object's host key (host `st_dev`, `st_ino`:
the host keeps an open file's inode, renames and unlinks included), in one
table for all processes of the host process, so a change made by any guest
process (or by the host, below) reaches every kqueue watching that object.
`EV_ADD` on a descriptor of a host file or directory registers the knote
(`fstat` of the host descriptor, once per open file); a descriptor that is
not one (the console, a pipe, a socket, a device) is registered as before
and never fires (xnu answers EINVAL there; **Ycode decision**: kept, so no
client sees a new error). The knote's drop (EV_DELETE, delivery of a
oneshot, the descriptor's close, the kqueue's close, the image's end)
removes the registration. After a snapshot restore each vnode knote is
registered again on the object its restored descriptor names; notes pending
at the save are not kept.

**Cost.** While no object is watched every VFS hook is one atomic load
(`VnodeNotes.isActive`) and makes no system call. A full iOS boot watches
objects from its first seconds on (UserEventAgent, PosterBoard, every
process's `memory_warning_simulation` watch), so in practice the second
case is the boot's. While some are, a path
operation `lstat`s its object and directory once before it changes them
(an unlinked or replaced object has no name afterwards), a write or size
change looks its file's key up in the table (an `fstat` for the old size
only when that file is watched), and a post takes the table's mutex once.
A post reaches a knote's image (its event lock) only when the knote asks
for one of the notes (each registration keeps its interest mask in an
atomic) or for a revoke. Counted in a full boot (`YCODE_DEBUG_VNODE=1`, run
`vnode/p2`, 200 s): about 6,000 path-operation captures, 12,900 write
checks and 6,200 posts to watched objects, of which about 55 were asked
for. A host micro-benchmark (x86-64 Linux, debug build, 1,000 objects
watched) put the hooks at about 20 µs on a create + write + rename +
unlink cycle of 145 µs, so the boot's captures cost well under 0.1 s of
CPU in all.

**Boot time** (`timed.sh`, `bench.sh` on copies of the pristine device,
time to the home screen with `YCODE_HOME_WATCH=1`; main line = FS-HOST's
tree, the branch merged as ecde653; three ABBA sets,
2026-10-28, other agents' work kept the load at 2–30): main line 71.8,
72.6, 73.2, 74.7, 74.9, 75.6 s (median 73.9 s); with vnode events 72.9,
73.7, 73.8, 74.1, 74.4, 81.0 s (median 73.9 s; the 81.0 s boot's
SpringBoard reached the audio service at the usual time, 37 s). Unchanged
within the machine's noise. A fourth set without the home watch (5 s
frames) gave 75, 75 s against 80, 80 s, the coarse steps of the same
spread.

**Locks.** The table's mutex is a leaf; a post copies the watchers out and
lets it go before it fires them. Firing a knote takes its image's event
lock (L0 without the lock split): the VFS posts after its leaf locks (the
offset lock of a write, the descriptor table's) are let go, from a trap
that holds L0 or no kernel lock; a thread that holds another image's event
lock defers the work until its locks allow it (`KernelLock.deferIfFast`).
Activation then wakes the kqueue's scanners or issues its thread request
(workqueue kqueue, workloops) as any other filter does.

**Host writes into the data tree.** `HostDataWrites` (same file) is the one
hook for files that ycode-simd itself writes into a running device's data
tree: `replace` (written to `.<name>.ycode-<pid>-<random>` in the same
directory, then renamed over the name, as audio-host.md §12 asks), `remove`
and `makeDirectories`. Each posts the notes of the table above (replace:
the old file `NOTE_DELETE`, the directory `NOTE_WRITE`, the new file
`NOTE_RENAME`; a new directory: its parent `NOTE_WRITE | NOTE_LINK`) and
feeds the file-event service the same changes a guest process would make,
with pid 0 (`fsevents-host.md` §10). The settings controller's files go
through it: the audio settings files, the preference files written for a
stopped device, the per-app Environment Overrides
(`ycode-simd/SimSettings.swift`, `DeviceSettingsFiles`). Ycode has no
privacy (TCC) database writer today; one added later uses the same hook.

**Writes by other host processes** (a user editing a device's files, a
copy into DEV while the device runs) are not seen. **Ycode decision**: no
inotify watch. The only writer of a running device's data tree besides the
guest is ycode-simd, whose writes go through the hook; an inotify watch per
watched object would cost a host watch per registration (a full boot keeps
about 1,000 registrations at once and makes about 3,900 in 330 s, runs
`vnode/p1`, `v1`) and a reader thread, and inotify reports
names, not the objects a rename replaced, so its notes would be less exact
than the hook's. Revisit if a host tool that changes a running device's
files is added outside ycode-simd.

**Tests.** `VnodeEventsTests` (each note type on a file, directories,
accumulation and the interest mask, EV_CLEAR, EV_ONESHOT, EV_DISPATCH,
another process's write and the host-write hook including its FSEvents
feed, NOTE_REVOKE and NOTE_FUNLOCK, registrations ending with their
knotes, a write on the BSD fast path and a post from a host thread with
the lock split, the no-registration path); guest probe
`SimShim/guest-tests/vnode/p_vnode.c` (`build-vnode.sh`).

**Checked on the Linux host (iOS 27.1, full boots, 2026-10-28).** The
probe passes all 38 checks (run `vnode/v1`): each note of the table above
for a file and a directory, accumulation in one scan, a child process's
write, EV_ONESHOT, a knote without EV_CLEAR firing at every scan, and a
dispatch vnode source (libdispatch's workloop path). In the same boot,
FeatureProbe's audio session watches `var/run/simulatoraudio` with a
dispatch vnode source (`NOTE_WRITE`) and follows each volume change
(`simulator-features.md` I.9; runs `v1`, `v2`). A host write reaches a
guest watcher quickly: with `p_vnode watch` on `var/run/simulatoraudio`, each
of five `ycode-simd --audio volume N` commands was printed by the guest
process 10 ms after the command process started (run `vnode/l1`; the
command process itself takes about 15 ms). In a whole boot the system's own watchers
get about 55 vnode events (UserEventAgent, weatherd, routined, locationd,
geod, parsecd, assistantd, navd and others; run `vnode/p1`).

---

## 4. Synchronization (Q4)

### 4.1 `__ulock_wait` (515), `__ulock_wait2` (544), `__ulock_wake` (516)

| Call | Registers |
|---|---|
| `__ulock_wait` | x0 = operation, x1 = addr, x2 = value (u64), x3 = timeout (u32, **microseconds**, 0 = forever) |
| `__ulock_wait2` | x0 = operation, x1 = addr, x2 = value, x3 = timeout (u64, **nanoseconds**, 0 = forever; with `ULF_DEADLINE`: an absolute `mach_absolute_time` deadline), x4 = value2 (**ignored**) |
| `__ulock_wake` | x0 = operation, x1 = addr, x2 = wake_value (thread port name for `ULF_WAKE_THREAD`, else ignored) |

Operation = opcode (bits 7–0) | flags.

| Opcode | Value | Word | Notes |
|---|---|---|---|
| `UL_COMPARE_AND_WAIT` | 1 | 32-bit | Futex-like, private to the process |
| `UL_UNFAIR_LOCK` | 2 | 32-bit | The word holds the **owner's thread port name**, low two bits used as flags |
| `UL_COMPARE_AND_WAIT_SHARED` | 3 | 32-bit | Keyed by memory object + offset (cross-process) |
| `UL_UNFAIR_LOCK64_SHARED` | 4 | — | Not accepted by wait or wake (`EINVAL`) |
| `UL_COMPARE_AND_WAIT64` | 5 | 64-bit | |
| `UL_COMPARE_AND_WAIT64_SHARED` | 6 | 64-bit | Cross-process |
| 253–255 | debug | — | Only in debug kernels |

| Flag | Value | Valid for |
|---|---|---|
| `ULF_WAKE_ALL` | `0x0000_0100` | wake |
| `ULF_WAKE_THREAD` | `0x0000_0200` | wake |
| `ULF_WAKE_ALLOW_NON_OWNER` | `0x0000_0400` | wake (`UL_UNFAIR_LOCK` only) |
| `ULF_WAIT_WORKQ_DATA_CONTENTION` | `0x0001_0000` | wait (hint: do not start new workers to cover this wait) |
| `ULF_WAIT_CANCEL_POINT` | `0x0002_0000` | wait (pthread cancellation point) |
| `ULF_WAIT_ADAPTIVE_SPIN` | `0x0004_0000` | wait (spin first while the owner runs) |
| `ULF_NO_ERRNO` | `0x0100_0000` | both |
| `ULF_DEADLINE` | `0x0200_0000` | wait (`__ulock_wait2` timeout is a deadline) |

Wait rules:

1. A flag outside the wait set → `EINVAL`. Unknown opcode → `EINVAL`.
   `addr` = 0 or not aligned to the word size → `EINVAL`.
2. The wait queue key is (process, address), or (memory object, offset) for
   `_SHARED`.
3. All waiters on one key must use the same opcode. A different opcode →
   `EDOM`.
4. Under the key's lock, read the word (32 or 64 bits). A fault → `EFAULT`
   (user space then touches the page and retries). A 32-bit word is
   zero-extended and compared with the full 64-bit `value`.
5. If the word ≠ `value`: return at once with **success**.
6. `UL_UNFAIR_LOCK`: resolve `value | 3` to a thread of this task, other
   than the caller. If it is not a thread port: `EOWNERDEAD`, except
   when `value | 3` is `MACH_PORT_DEAD` (`0xFFFF_FFFF`), which is treated as
   "no owner" and the wait goes on. The resolved thread is recorded as the lock **owner**
   and receives the waiters' priority push.
7. Sleep until woken, timed out (`ETIMEDOUT`), or interrupted (`EINTR`).
   Steps 4–7 must be atomic with respect to wakes on the same key: a wake
   after the compare must not be lost.
8. **Return value on success: the number of threads still waiting on the
   key after this thread leaves** (0 if none). libdispatch and libplatform
   use "> 0" to keep the "has waiters" bit set in the lock word.
9. With `ULF_NO_ERRNO`, an error E is returned as success with `x0 = −E`.
   Without it, carry set and `x0 = E`.

Wake rules:

1. A flag outside the wake set → `EINVAL`. `ULF_WAKE_THREAD` together with
   `ULF_WAKE_ALL` or with `UL_UNFAIR_LOCK` → `EINVAL`.
   `ULF_WAKE_ALLOW_NON_OWNER` without `UL_UNFAIR_LOCK` → `EINVAL`. addr 0 →
   `EINVAL`.
2. `ULF_WAKE_THREAD`: `wake_value` must name a thread of this task other
   than the caller (`ESRCH`).
3. No waiter on the key → `ENOENT`. Opcode differs from the waiters' →
   `EDOM`.
4. `UL_UNFAIR_LOCK` without `ALLOW_NON_OWNER`: if the caller is not the
   recorded owner, return 0 **without waking anyone** (the real owner will
   wake later). Otherwise wake the highest-priority waiter and record it as
   the new owner.
5. `ULF_WAKE_ALL`: wake all waiters. `ULF_WAKE_THREAD`: wake that thread
   (`EALREADY` if it is not waiting on the key). Else wake one waiter.
6. Return 0, with the `ULF_NO_ERRNO` rule as for wait.

Note for Ycode: waking more threads than needed is always safe for these
users, because every caller re-checks its word after a wake. A simple VMM
may wake one waiter in rule 4 even when the caller is not the recorded
owner. It must not wake **fewer**.

Users in the simulator runtime:

| User | Opcodes and flags |
|---|---|
| libdispatch (Apple binary) | `UL_UNFAIR_LOCK` and `UL_COMPARE_AND_WAIT` via `__ulock_wait` (µs timeouts) and `__ulock_wake` (`ULF_WAKE_ALL`, `ULF_WAKE_ALLOW_NON_OWNER`), always `ULF_NO_ERRNO`; lock word = owner port name with flag bits `0x1` (waiters) and `0x2` (failed trylock). It crashes on `EOWNERDEAD` and on any unexpected errno, and reads `rc > 0` as "more waiters" |
| Ycode `libsystem_platform` (`os_unfair_lock`, once, sync) | `UL_UNFAIR_LOCK`, `UL_COMPARE_AND_WAIT`, `ULF_WAKE_ALL`, `ULF_NO_ERRNO` |
| Ycode `libsystem_pthread` | `UL_COMPARE_AND_WAIT` with `__ulock_wait2` (ns timeouts) |

### 4.2 `psynch` (BSD 297–312)

These calls are the slow path of Apple's libpthread mutexes, condition
variables, and rwlocks. **Ycode's `libsystem_pthread` does not use them**:
its mutexes and condition variables are built on ulock. They matter only if
another runtime image calls the `__psynch_*` stubs directly; see Open
question 5. The summary below lets Ycode implement them if a trace shows a
caller.

| # | Call | Arguments |
|---|---|---|
| 301 | `psynch_mutexwait` | mutex addr, mgen (L word), ugen (U word), tid (owner hint: 0 = unknown, ~0 = being released), flags → returns the new L word |
| 302 | `psynch_mutexdrop` | mutex, mgen, ugen, tid, flags → returns update bits |
| 303 | `psynch_cvbroad` | cv, cvlsgen = (S << 32) | L, cvudgen = (U << 32) | diff, flags, mutex, mugen, tid |
| 304 | `psynch_cvsignal` | cv, cvlsgen, cvugen, thread_port (0 = any waiter), mutex, mugen, tid, flags |
| 305 | `psynch_cvwait` | cv, cvlsgen, cvugen, mutex (0 = none; else it is dropped first, as `mutexdrop`), mugen = (ugen << 32) | mgen, flags, sec (i64), nsec (u32) → `ETIMEDOUT`, `EINTR` |
| 312 | `psynch_cvclrprepost` | cv, cvgen, cvugen, cvsgen, prepocnt, preposeq, flags — clear stale preposts |
| 306 / 307 / 308 | `rw_rdlock` / `rw_wrlock` / `rw_unlock` | rwlock, lgenval, ugenval, rw_wc (S word), flags |
| 297, 298 | `rw_longrdlock`, `rw_yieldwrlock` | as above (legacy) |
| 299, 300 | `rw_downgrade`, `rw_upgrade` | return 0 without doing anything |
| 309 | `rw_unlock2` | `ENOTSUP` |

Sequence-word model:

- Each word is 32 bits. Bits 31–8 are a sequence counter that advances by
  `0x100` per operation; bits 7–0 are flags. Comparisons are modulo 2^24
  (half-range rule).
- L (lock) word flags: K `0x01` (granted by the kernel), E `0x02` (held
  exclusively), W/P `0x04` (waiters or prepost in the kernel), `0x20`
  (condition-variable mutex wait), U `0x40` (unlocked, rwlock), I `0x80`
  (reset).
- S (sequence) word flags: `0x01` (CV: kernel cleared all state), `0x02`
  (CV: only preposts remain), `0x04` (saved W bit).
- `flags` argument: process-shared `0x10` (key by memory object + offset),
  policy fair-share `0x40` / first-fit `0x80` (mask `0x1C0`), CV notify
  `0x1000`, "is a mutex" `0x2000`.
- The kernel keeps, per address, a queue of waiters ordered by their lock
  sequence, a **prepost** record (count and sequence) for wakes that arrive
  before their waiter, the last unlock sequence, and the owner.
- **Mutex, fair-share:** a drop with `ugen` grants the lock to the waiter
  whose sequence is `ugen + 0x100`. If that waiter has not arrived, the
  grant is preposted; a later wait with that sequence consumes it and
  returns at once. **First-fit:** a drop wakes the first waiter or adds to
  the prepost count; a wait consumes any prepost.
- **Condition variable:** waiters are identified by their L sequence.
  Signal wakes one waiter up to the signalled sequence (or the named
  thread); broadcast wakes all up to L. A signal with no matching waiter
  leaves a prepost entry. The returned bits tell user space whether the
  kernel cleared its state.

### 4.3 Mach semaphores with several threads

This replaces the one-vCPU behavior of `host-libraries.md` §10 once threads
exist. A semaphore has a count; waiters exist only while count < 0
(count = permits − waiters).

| Trap | Behavior |
|---|---|
| −33 `semaphore_signal(s)` | If a thread waits, wake one; else count += 1. Returns `KERN_SUCCESS` |
| −34 `semaphore_signal_all(s)` | Wake all waiters (count becomes 0). With no waiter, nothing changes. `KERN_SUCCESS` |
| −35 `semaphore_signal_thread(s, thread)` | thread ≠ 0: wake that thread if it waits on `s`, else `KERN_NOT_WAITING` (24); a bad thread name → `KERN_INVALID_ARGUMENT`. thread = 0: wake one waiter, else `KERN_NOT_WAITING` (the count does not change) |
| −36 `semaphore_wait(s)` | If count > 0, count −= 1 and return. Else block. Interrupted → `KERN_ABORTED` (14) |
| −37 `semaphore_wait_signal(w, s)` | Atomically: start waiting on `w`, then signal `s` (as −33) |
| −38 `semaphore_timedwait(s, sec, nsec)` | As −36 with a relative timeout; 0 timeout = poll. Timeout → `KERN_OPERATION_TIMED_OUT` (49) |
| −39 `semaphore_timedwait_signal(w, s, sec, nsec)` | −37 with a timeout |

A destroyed semaphore → `KERN_TERMINATED` (37) for waiters and callers.
libdispatch's `dispatch_semaphore` and `dispatch_group` use −33, −36, −38
and Mach `semaphore_create`/`semaphore_destroy`.

---

## 5. Signals (Q5, for a later stage)

### 5.1 `sigaction` (BSD 46)

`x0` = signo, `x1` = new action (`struct __sigaction`, 24 bytes), `x2` = old
action (`struct sigaction`, 16 bytes).

| `__sigaction` off | Field | `sigaction` off |
|---|---|---|
| 0 | handler (8) | 0 |
| 8 | `sa_tramp` (8): the trampoline for this signal | — |
| 16 | `sa_mask` (u32) | 8 |
| 20 | `sa_flags` (i32) | 12 |

Rules: signo ≤ 0, ≥ 32, SIGKILL (9), or SIGSTOP (17) → `EINVAL`. The kernel
keeps per signal: handler, trampoline, mask (without SIGKILL/SIGSTOP), and
the flags `SA_ONSTACK` 1, `SA_RESTART` 2, `SA_RESETHAND` 4, `SA_NOCLDSTOP` 8,
`SA_NODEFER` 0x10, `SA_NOCLDWAIT` 0x20, `SA_SIGINFO` 0x40. Bit `0x400`
(`SA_VALIDATE_SIGRETURN_FROM_SIGTRAMP`) on the **first** `sigaction` call of
the process that has a new action decides, for the life of the process,
whether `sigreturn` checks its token (§5.5). SIG_IGN (or SIG_DFL for a
signal whose default is "ignore") discards pending instances.

### 5.2 Masks and directed signals

- Each thread has its own 32-bit signal mask (`sigset_t` = u32, bit
  `signo − 1`). SIGKILL and SIGSTOP can never be blocked.
- `sigprocmask` (48) and `__pthread_sigmask` (329): `x0` = how (1 BLOCK,
  2 UNBLOCK, 3 SETMASK; else `EINVAL`), `x1` = new set pointer (0 = only
  read), `x2` = old set pointer. Both act on the **calling thread**. The old
  mask is written even when the new pointer is 0.
- `__pthread_kill` (328): `x0` = thread port, `x1` = signo. `ESRCH` if the
  name is not a thread or the thread disabled signals; `EINVAL` if signo ≥
  32; `ENOTSUP` for a workqueue thread unless `WORKQ_ALLOW_KILL` or
  `WORKQ_ALLOW_SIGMASK` allowed it. signo 0 only checks. Otherwise the
  signal is posted to that thread only.
- `__disable_threadsignal` (331): the argument is ignored. The calling
  thread will never take a signal again and becomes non-cancelable. Returns
  0. Libpthread calls it while a thread exits.
- **Process-directed** signals (`kill`, timer expiry) go to a thread that
  does not block them, trying non-workqueue threads first; if all block
  it, the signal stays pending on the process.

### 5.3 Delivery and the arm64 signal frame

A pending, unblocked signal is delivered when the target thread next returns
to user mode (for Ycode: at the thread's next trap return, or after a kick).

1. Mask during the handler = old mask | `sa_mask` | the signal itself
   (unless `SA_NODEFER`). `SA_RESETHAND` resets the action to SIG_DFL
   (except for SIGILL and SIGTRAP).
2. **Stack:** if the thread has an enabled alternate stack, is not already
   on it, and the action has `SA_ONSTACK`, use `top = ss_sp + ss_size` and
   mark the thread on-stack. Otherwise `top` = the thread's current `sp`.
3. Frame address `F = (top − 976 − 128) & ~15` (976 = frame size, 128 =
   red zone).
4. The kernel writes the frame at F:

| F + | Size | Content |
|---|---|---|
| 0 | 104 | `siginfo`: signo (i32) @0, errno @4, code @8, pid @12, uid @16, status @20, addr (u64) @24 = pc at the signal, value @32, band @40, pad[7] @48 with pad[0] = `sp` at the signal |
| 104 | 56 | `ucontext64`: `uc_onstack` (i32) @+0 = was the thread already on the alt stack; `uc_sigmask` (u32) @+4 = the mask **before** delivery; `uc_stack` {`ss_sp` @+8 = **F**, `ss_size` @+16 = alt-stack size if this delivery switched to the alternate stack, else 0, `ss_flags` (i32) @+24 = `SS_ONSTACK` (1) when `uc_onstack` is set}; `uc_link` @+32 = 0; `uc_mcsize` @+40 = **816**; `uc_mcontext` @+48 = F + 160 |
| 160 | 816 | `mcontext64` (below) |

`mcontext64` (816 bytes):

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | exception state: `far` |
| 8 | 4 | `esr` |
| 12 | 4 | `exception` |
| 16 | 232 | `x0`…`x28` |
| 248 | 8 | `fp` |
| 256 | 8 | `lr` |
| 264 | 8 | `sp` |
| 272 | 8 | `pc` |
| 280 | 4 | `cpsr` |
| 284 | 4 | flags/pad (0 for arm64 without pointer authentication) |
| 288 | 512 | `v0`…`v31` (16 bytes each) |
| 800 | 4 | `fpsr` |
| 804 | 4 | `fpcr` |
| 808 | 8 | padding (16-byte alignment) |

5. Registers at the trampoline. Registers not listed keep their
   interrupted values (x6–x30 and all FP/SIMD state):

| Register | Value |
|---|---|
| pc | the `sa_tramp` registered for this signal |
| x0 | the handler |
| x1 | infostyle: **30** (`UC_FLAVOR`) if `SA_SIGINFO`, else **1** (`UC_TRAD`) |
| x2 | signo |
| x3 | F (siginfo) |
| x4 | F + 104 (ucontext) |
| x5 | token = (F + 104) XOR a per-thread secret (new secret when no `sigreturn` is pending) |
| sp | F |
| cpsr | EL0 AArch64, NZCV = 0 |

The trampoline (Ycode's `libsystem_platform` `_sigtramp`) calls the handler
and then `__sigreturn(uctx, infostyle, token)`.

### 5.4 `sigreturn` (BSD 184)

`x0` = ucontext pointer, `x1` = infostyle, `x2` = token.

1. infostyle `0x4000_0000` (`UC_SET_ALT_STACK`): mark the thread on-stack;
   return 0. `0x8000_0000` (`UC_RESET_ALT_STACK`): clear it; return 0. The
   ucontext is not read.
2. Copy in the 56-byte ucontext. `uc_mcsize` must be 816 (else `EINVAL`).
   Copy in the 816-byte mcontext from `uc_mcontext`.
3. On-stack := `uc_onstack & 1`. Mask := `uc_sigmask` without SIGKILL and
   SIGSTOP.
4. If token validation is on (§5.1) and `token ≠ (x0 XOR secret)` →
   `EINVAL`.
5. Restore x0–x28, fp, lr, sp, pc, cpsr (mode bits forced to EL0 AArch64)
   and v0–v31, fpsr, fpcr. The exception-state words are ignored.
6. Return "just return": the restored registers are the result; the call
   does **not** write `x0` or carry.

Note for Ycode: the trampoline, the `sigaction` wrapper, and the VMM are all
Ycode's, so the token can be any value the two sides agree on. The **frame
layout** must match exactly, because handlers in app code read
`uc_mcontext`.

### 5.5 `sigaltstack` (BSD 53)

`x0` = new (`{ss_sp u64 @0, ss_size u64 @8, ss_flags i32 @16}`, 24 bytes),
`x1` = old. Rules: flags other than `SS_DISABLE` (4) → `EINVAL`; disabling
while on the stack → `EINVAL`; changing while on the stack → `EPERM`; size
< 8 KiB → `ENOMEM`. Per thread. The old value reports `SS_DISABLE` when no
stack is set and `SS_ONSTACK` (1) while on it.

### 5.6 Timers: `setitimer` (BSD 83), `getitimer` (86)

`x0` = which (0 `ITIMER_REAL`, 1 `ITIMER_VIRTUAL`, 2 `ITIMER_PROF`; else
`EINVAL`), `x1` = new `itimerval`, `x2` = old. `itimerval` = {interval,
value}, each a 16-byte `timeval` {`tv_sec` i64, `tv_usec` i32, pad}. A value
of zero disarms; a non-zero interval re-arms after each expiry; an invalid
timeval → `EINVAL`. `ITIMER_REAL` expiry posts **SIGALRM** to the process
(process-directed, so `EVFILT_SIGNAL` sees it). VIRTUAL and PROF post
SIGVTALRM and SIGPROF.

### 5.7 Signals and workqueue threads

Workqueue threads run with almost every signal blocked (§2.7 step 2), and
process-directed signals prefer other threads (§5.2). libdispatch signal
sources use `EVFILT_SIGNAL` and normally set the signal to SIG_IGN, so
minimal support for daemons is: `sigaction` bookkeeping, masks,
`EVFILT_SIGNAL` counting, and SIGALRM/SIGTERM/SIGCHLD posting. Handler
delivery (§5.3) can come later.

---

## 6. Design note: guest threads and vCPUs (facts only)

These are facts the orchestrator needs in order to choose a model. Sources:
the Linux KVM API documentation and the Arm Architecture Reference Manual.

**KVM facts**

1. `KVM_RUN` runs one vCPU on the **calling host thread** and blocks that
   thread while the guest runs. Concurrent guest execution needs one host
   thread per running vCPU.
2. vCPU ioctls should come from the thread that created the vCPU. Other
   threads work, with a performance cost on the first call after a switch.
3. The number of vCPUs is limited: `KVM_CHECK_EXTENSION(KVM_CAP_NR_VCPUS)`
   gives the recommended limit and `KVM_CAP_MAX_VCPUS` the hard limit. Both
   depend on the host and must be read at run time.
4. The KVM API has **no call to destroy one vCPU**. vCPUs are freed when
   the VM is closed. A design that makes a vCPU per guest thread must pool
   and reuse vCPUs.
5. To force a running vCPU out of the guest from another host thread,
   signal its host thread. `KVM_RUN` then returns `-EINTR`. The
   `immediate_exit` field of `kvm_run` (`KVM_CAP_IMMEDIATE_EXIT`) closes the
   race between the check and the entry.
6. All registers needed to save and restore a user thread are reachable with
   `KVM_GET_ONE_REG`/`KVM_SET_ONE_REG`: x0–x30, PC, PSTATE, SP_EL0, ELR_EL1,
   SPSR_EL1, V0–V31, FPSR, FPCR, `TPIDRRO_EL0`, `TPIDR_EL0`. (While the
   shim handles a trap, the guest thread's PC and PSTATE are in ELR_EL1 and
   SPSR_EL1.)
7. If Ycode adds an in-kernel GIC later (for example, to deliver
   virtual-timer interrupts), it must be initialized **after all vCPUs are
   created**. vCPUs cannot be added after that.

**Arm and shim facts**

8. Guest RAM is coherent across vCPUs. Exclusive (`LDXR`/`STXR`) and LSE
   atomics work between vCPUs, so user-space locks work unchanged.
9. All guest threads of one process share one set of stage-1 tables. After
   the VMM removes or changes a mapping, stale TLB entries can remain on
   other vCPUs. A broadcast invalidate (a `TLBI …IS` instruction followed by
   `DSB ISH`) executed by the shim on any one vCPU invalidates all of them.
   The VMM cannot invalidate guest TLBs directly.
10. The shim's trap frame (`vm-shim-protocol.md` §5) holds x0–x30, SP_EL0,
    ELR, SPSR, ESR, FAR, `TPIDRRO_EL0`, `TPIDR_EL0`. It does **not** hold
    V0–V31/FPSR/FPCR. Switching a vCPU between guest threads therefore needs
    those registers saved some other way (ONE_REG, or a shim extension).
11. The shim finds its frame through `TPIDR_EL1` (the boot-info address).
    Each vCPU needs its own frame, EL1 stack, and boot-info block. The
    doorbell write carries the frame address, so the VMM can tell vCPUs
    apart (and each vCPU exits on its own fd anyway).
12. Darwin user threads need no guest kernel scheduler. A thread that
    blocks in a system call can be modeled by not calling `KVM_RUN` again
    for it until the call completes.

**The two models**

| | One vCPU per runnable guest thread (1:1) | Guest threads multiplexed on N vCPUs (M:N) |
|---|---|---|
| Blocking calls | The host thread blocks on a host primitive (fact 12) | The VMM saves the thread (facts 6, 10) and runs another on that vCPU |
| Preemption | The host kernel schedules the host threads | Needs a kick (fact 5) or a guest timer interrupt (fact 7) |
| FP/SIMD state | Stays in the vCPU | Saved and restored on every switch |
| Thread count | Limited by fact 3; vCPUs are pooled (fact 4) | Unlimited guest threads; N ≤ host CPUs |
| Ordering | Real parallelism; VMM state must be thread-safe | Can be deterministic with N = 1 |
| Idle workers | One parked host thread each | Cost only memory |

Either way the VMM's kernel state (ports, ulock queues, kqueues, the
workqueue, memory map) is shared by all threads and must be protected
against concurrent traps.

---

## 7. Implementation checklist for Ycode

Ordered by what `launchd_sim` and libdispatch need first. Each step depends
on the steps above it.

1. **Thread infrastructure in the VMM.** A guest-thread object (tid,
   thread port name with `& 3 == 3`, TSD base, `TPIDR_EL0`, signal mask,
   state); the vCPU model chosen from §6; per-vCPU shim blocks; locking for
   all shared kernel state; broadcast TLB invalidation after unmaps.
2. **`bsdthread_create` / `bsdthread_terminate` / `thread_selfid`** (§1.1–§1.3),
   with the slot-3 store, the TSD base, and the join form chosen by Ycode's
   `libsystem_pthread`. `mach_thread_self` and `thread_self_trap` (−27)
   return the calling thread's port name.
3. **ulock** (§4.1): all four private opcodes, `ULF_NO_ERRNO`, µs/ns
   timeouts and `ULF_DEADLINE`, the owner rule, `WAKE_ALL`/`WAKE_THREAD`/
   `ALLOW_NON_OWNER`, the "remaining waiters" return value, and
   `ULF_WAIT_CANCEL_POINT` accepted.
4. **Blocking Mach semaphores** (§4.3), `thread_switch` (−61) and
   `swtch_pri` (−59) as real yields, and any sleep call the libraries use
   (for example `__semwait_signal`, BSD 334) sleeping only the caller.
5. **Feature mask** with `KEVENT | WORKLOOP` (§2.8): for example
   `0x4000_00DF` (`0x4000_01DF` if the cooperative pool is supported).
6. **Workqueue core:** `workq_open`; `workq_kernreturn` ops `0x400`,
   `0x020`, `0x004`, `0x080`, `0x200` (§2.3); worker creation with the §2.6
   stack layout and entry registers; parking and reuse; the "blocked worker
   frees a slot" rule (§2.5); worker exit with `x5 = −1`; the §2.7 signal
   mask.
7. **kqueue engine** (§3.1–§3.6): `kevent_qos` on the workqueue kqueue
   with `ERROR_EVENTS`; knote identity with `EV_UDATA_SPECIFIC`; all `EV_*`
   semantics including `EV_DISPATCH2` deferred delete and `EV_VANISHED`;
   suppression; `EVFILT_USER` (§3.7.1) and `EVFILT_TIMER` in the libdispatch
   forms (§3.7.2).
8. **kevent upcalls** (§3.8): buckets, the manager bucket, `KEVENT`
   upcalls with the stack event area, `THREAD_KEVENT_RETURN` with
   redelivery, and `SET_SELF` with `WQ_KEVENT_UNBIND` (§1.5).
9. **Workloops** (§2.9, §3.7.4): `kevent_id` with create/lookup and
   `EXDEV`; the thread-request knote with debounce, `UPDATE_QOS`, owner
   discovery and end; `WORKLOOP` upcalls with the ID at `x3 − 8`;
   `THREAD_WORKLOOP_RETURN`; blocking `SYNC_WAIT` and `SYNC_WAKE`.
10. **`EVFILT_MACHPORT`** (§3.7.3) with direct receive into the data area.
    Needs stage-5 Mach IPC (`mach_msg`, port sets, special reply ports).
11. **`EVFILT_PROC`, `EVFILT_SIGNAL`, descriptor filters** (§3.7.5–§3.7.7);
    `kqueue()`, `kevent`, `kevent64` on kqueue fds.
12. **Signals** (§5): `sigaction`/masks/`__pthread_kill` bookkeeping first,
    then `setitimer`, then handler delivery and `sigreturn` with the exact
    frame.
13. Remaining `bsdthread_ctl` commands (§1.5) as bookkeeping;
    `kqueue_workloop_ctl`; `QUEUE_REQTHREADS2` if `COOPERATIVE_WORKQ` is
    advertised.
14. **psynch** (§4.2), only if a trace shows a caller.

Tests that need no Ycode library change: a guest program that creates
threads and joins them; one that uses `dispatch_async` to a global queue
and `dispatch_semaphore_wait`; one that uses a serial queue (workloop path)
with `dispatch_sync` from two threads (sync wait/wake); one with
`dispatch_after` (timer); then `launchd_sim`.

---

## Open questions

1. **Which libdispatch version is in the iOS 27.1 runtime.** The newest
   open-source tag is libdispatch-1542.100.32. The workloop requirement
   (§2.8) should be confirmed for the shipped binary by a black-box run with
   `WORKLOOP` cleared in the mask (level 3).
2. **Kernel component version.** The `bsdthread_*` and workqueue-stack code
   lives in libpthread's `kern/` (tag 539.100.4), which is older than the
   xnu tag. The register states agree with `host-library-init.md` §6, which
   came from the same sources. A black-box check on the Mac (a thread that
   prints its entry registers) would confirm them (level 3).
3. **Cooperative pool.** libdispatch requests cooperative threads (op
   `0x030`) for Swift-concurrency root queues. Whether the runtime's
   libdispatch checks `COOPERATIVE_WORKQ` (`0x100`) before using them is not
   visible in the open source. If not, Ycode's `libsystem_pthread` can map
   cooperative requests onto constrained ones. Resolved for Ycode: the runtime's libraries
   request cooperative threads whatever the mask says (Ycode traces), and
   the kernel now runs the cooperative pool of §2.5 (rule 5 note).
4. **`EVFILT_MEMORYSTATUS`.** libdispatch registers a memory-pressure source
   at initialization. Whether an `EV_ERROR` reply is tolerated there, or must
   be accepted silently, should be checked by trace.
5. **psynch callers.** Does any image in the runtime (other than Apple's
   libpthread, which Ycode replaces) call `__psynch_*`? A trace of
   `launchd_sim` and its daemons answers this.
6. **Idle-thread policy.** The 5-second reaping and the 200 µs "recently
   blocked" window are policy. Ycode may use simpler values; the observable
   effect is only thread counts and latency.
7. **vCPU model.** §6 lists the facts; the orchestrator decides between
   1:1 and M:N (or a pooled hybrid).

## Evidence

| Claim | Source | Level |
|---|---|---|
| Syscall numbers and argument lists (§1–§5) | xnu `bsd/kern/syscalls.master`; `specs/simulator/data/bsd-syscalls.json` | 1 |
| `bsdthread_create`/`terminate`/`register`, `thread_selfid`, worker stack, `start_wqthread` registers (§1.1–§1.3, §2.6) | libpthread `kern/kern_support.c`, `kern/kern_internal.h`; xnu `bsd/pthread/pthread_shims.c`, `bsd/kern/kern_fork.c` (join wake), `osfmk/kern/thread.c` (join gate store) | 1 |
| Port-name low bits (§0) | xnu `osfmk/ipc/ipc_entry.h`, `bsd/sys/ulock.h` | 1 |
| `bsdthread_ctl` (§1.5) | xnu `bsd/pthread/bsdthread_private.h`, `bsd/pthread/pthread_workqueue.c`, `bsd/pthread/workqueue_internal.h` | 1 |
| Workqueue ops, flags, admission, reuse, park, exit (§2) | xnu `bsd/pthread/workqueue_syscalls.h`, `bsd/pthread/pthread_workqueue.c`, `bsd/pthread/workqueue_internal.h` | 1 |
| Priority encoding (§2.4) | xnu `bsd/pthread/priority_private.h` | 1 |
| User-side callback contract (§2.6), feature bits (§2.8) | libpthread `private/pthread/workqueue_private.h`, `src/pthread.c` | 1 |
| libdispatch needs (§2.8, §3.7, §3.9, §4.1) | libdispatch `src/queue.c`, `src/event/event_kevent.c`, `src/event/event_config.h`, `src/shims/lock.c`, `src/shims/lock.h` — read only for interface usage | 1 |
| kevent calls, structures, flags, processing, filters, workloops, kqworkq (§3) | xnu `bsd/sys/event.h`, `bsd/sys/event_private.h`, `bsd/kern/kern_event.c`; `osfmk/ipc/ipc_pset.c` (`EVFILT_MACHPORT`); `bsd/kern/kern_sig.c` (`EVFILT_SIGNAL`) | 1 |
| ulock (§4.1) | xnu `bsd/sys/ulock.h`, `bsd/kern/sys_ulock.c` | 1 |
| psynch (§4.2) | libpthread `kern/kern_synch.c`, `kern/synch_internal.h`; xnu `bsd/pthread/pthread_shims.c` | 1 |
| Mach semaphores (§4.3) | xnu `osfmk/kern/sync_sema.c` | 1 |
| Signals, frame layout (§5) | xnu `bsd/kern/kern_sig.c`, `bsd/dev/arm/unix_signal.c`, `bsd/sys/signal.h`, `bsd/sys/ucontext.h`, `bsd/arm/_mcontext.h`, `osfmk/mach/arm/_structs.h`, `osfmk/mach/arm/thread_status.h`, `bsd/kern/kern_time.c` | 1 |
| KVM facts (§6, facts 1–7) | Linux `Documentation/virt/kvm/api.rst` (sections on ioctl classes, `KVM_CREATE_VCPU` limits, `kvm_run.immediate_exit`, `KVM_SET_ONE_REG`), `Documentation/virt/kvm/devices/arm-vgic-v3.rst` (`CTRL_INIT` after all vCPUs) | 1 |
| Arm facts (§6, facts 8–9) | Arm Architecture Reference Manual for A-profile (exclusives, broadcast TLB maintenance) | 1 |
| Shim facts (§6, facts 10–11) | `specs/simulator/vm-shim-protocol.md` §5, §9 | Ycode design |
| Cooperative pool trap counts and the timebase cause (§2.5 note) | Ycode boots on the Thor (SX harness, `IA2/si2`, `IA2/x`, `IA2/tb`, exit summaries); swift `DispatchGlobalExecutor.cpp` (`platform_time`) | 3; 1 |
| EVFILT_VNODE notes per operation, accumulation, EV_CLEAR behaviour, NOTE_REVOKE (§3.10) | xnu `bsd/vfs/kpi_vfs.c` (VNOP_* posts), `bsd/vfs/vfs_subr.c` (`filt_vnode_common`, `filt_vntouch`), `bsd/sys/event.h`; kqueue(2) manual | 1 |
| Ycode's vnode registry, host-write hook, the inotify decision (§3.10) | Ycode design; `VnodeEventsTests`; guest probe `p_vnode` on the Linux host | Ycode design; 3 |
| Suspension semantics: counts, KERN_FAILURE at zero, self-suspend, a thread in the kernel counts as stopped, task counts, start-suspended threads and tasks, thread_set_state hold/stop/release, flavors and counts, thread_abort (§1.6) | xnu `osfmk/kern/thread_act.c`, `osfmk/kern/task.c`, `osfmk/arm64/status.c`, `osfmk/mach/thread_act.defs`, `osfmk/mach/task.defs`, `osfmk/mach/arm/thread_status.h`, `bsd/kern/kern_exec.c` (START_SUSPENDED), `bsd/kern/kern_sig.c` (SIGCONT); the Mach `thread_suspend`/`task_suspend` manual pages | 1 |
| What JavaScriptCore's collector needs: suspend returns only when the thread is stopped; registers including SP/FP/LR from ARM_THREAD_STATE64; a failed suspend skips the thread's stack; a failed `thread_get_state` after a successful suspend is fatal (§1.6) | WebKit `Source/WTF/wtf/posix/ThreadingPOSIX.cpp` (`Thread::suspend`, `getRegisters`), `Source/JavaScriptCore/heap/MachineStackMarker.cpp` | 1 |
| Ycode's run gate, park points, kicks, waits (§1.6) | Ycode design; `ThreadSuspendTests`; guest probes `p_tsus`, `p_jsgc` on the Linux host (runs `tsus/p2`, `p3`, `pb1`, `pb2`) | Ycode design; 3 |
| A returning kevent/workloop worker's failed changes are output events, and the call succeeds (§2.7 step 3) | libpthread `kern/kern_support.c` (`workq_handle_stack_events`, `workq_kevent`); xnu `bsd/pthread/pthread_workqueue.c` (`workq_thread_return`) | 1 |

Source tags (fetched with the GitHub API on 2026-10-11, kept outside the
repository):

- `apple-oss-distributions/xnu` tag **`xnu-12377.121.6`**, commit
  `ac9718fb1af618d5ce8678d0dc6e8a58f252216f` (the newest tag; the same as
  `darwin-trap-tables.md`).
- `apple-oss-distributions/libpthread` tag **`libpthread-539.100.4`**, commit
  `1f4f5265b319111142f1bf3a27d4484ef5a98314` (the newest tag; its `kern/`
  directory is the kernel component that xnu calls through
  `pthread_shims.c`).
- `apple-oss-distributions/libdispatch` tag **`libdispatch-1542.100.32`**,
  commit `701f4d1a24ae9c6863901bbbb22624b7d1b87321` (newest tag; interface
  usage only).
- `torvalds/linux` `Documentation/virt/kvm/` at commit
  `7bb6284aa7b3c369b41e7f33fcbe193161f008e7`.

No Apple binary, `.claude/Xcode.app`, `research/dirty/`, or Ghidra project
was opened for this spec.


## Addendum (orchestrator, 2026-10-12): workqueue setup and workloop records

Level 1: xnu `bsd/pthread/workqueue_syscalls.h`, libpthread
`private/pthread/workqueue_private.h`, and libpthread `src/pthread.c`.

### User-side `struct pthread_workqueue_config`

libdispatch passes this to `pthread_workqueue_setup(cfg, cfg_size)`. It is
48 bytes:

| Offset | Type | Field |
|---|---|---|
| 0 | u32 | `flags` (supported flags: 0) |
| 4 | u32 | `version` (current 2, minimum 1) |
| 8 | ptr | **`kevent_cb`** |
| 16 | ptr | **`workloop_cb`** |
| 24 | ptr | **`workq_cb`** |
| 32 | u64 | `queue_serialno_offs` |
| 40 | u64 | `queue_label_offs` |

**Callback order is kevent, workloop, workq.** `flags` comes before
`version`.

### Kernel-side `struct workq_dispatch_config`

This is the record for `workq_kernreturn(SETUP_DISPATCH)`. It is 24 bytes,
packed and 4-byte aligned:

| Offset | Type | Field |
|---|---|---|
| 0 | u32 | `wdc_version` (2) |
| 4 | u32 | `wdc_flags` (0) |
| 8 | u64 | `wdc_queue_serialno_offs` |
| 16 | u64 | `wdc_queue_label_offs` |

### `struct kqueue_workloop_params`

This is the record for `__kqueue_workloop_ctl(cmd, options, addr, sz)`.
Commands are CREATE (1) and DESTROY (2). It is 36 bytes, packed:

| Offset | Type | Field |
|---|---|---|
| 0 | i32 | `kqwlp_version` = **sizeof(the struct) = 36** |
| 4 | i32 | `kqwlp_flags`: SCHED_PRI 0x01, SCHED_POL 0x02, CPU_PERCENT 0x04, WORK_INTERVAL 0x08, WITH_BOUND_THREAD 0x10 |
| 8 | u64 | `kqwlp_id` |
| 16 | i32 | `sched_pri` |
| 20 | i32 | `sched_pol` |
| 24 | i32 | `cpu_percent` |
| 28 | i32 | `cpu_refillms` |
| 32 | u32 | `kqwl_wi_port` |

### Other constants

- `WQ_KEVENT_LIST_LEN` = 16 and `WQ_KEVENT_DATA_SIZE` = 32 KiB.
- The workqueue thread flags `WQ_FLAG_THREAD_TSD_BASE_SET` (0x0020_0000),
  `_WORKLOOP` (0x0040_0000), `_OUTSIDEQOS` (0x0080_0000), and
  `_COOPERATIVE` (0x0100_0000).

## Addendum: Ycode workqueue rule (stage 7, 2026-10-12)

A workqueue upcall delivers kevents (disabling `EV_DISPATCH` knotes and
receiving Mach messages into the new thread's stack), so the VMM must
**not run an upcall unless a vCPU is free for it**; otherwise the request
stays pending, and a vCPU becoming free (a thread ending) pumps pending
requests again. Delivering first and failing to start the thread lost
events and stalled `launchd_sim`'s bootstrap port for good (level 3).
