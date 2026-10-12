# Spec: stage 4a contract (threads, workqueues, kevent, in-process Mach IPC)

Status: **contract**. Stage 4 runs `launchd_sim` (see
`docs/SIMULATOR-LINUX.md`). It is split into three parts:

| Part | Scope |
|---|---|
| **4a** (this document) | One Darwin process with real threads, libdispatch, and Mach IPC inside the process |
| 4b | Multiple processes: `posix_spawn`, task ports, Mach IPC between processes, the host bootstrap port |
| 4c | `launchd_sim` boots with a minimal job set |

Normative inputs:

- `specs/simulator/threads-and-events.md`: thread start state, workqueue,
  kevent, ulock, signals.
- `specs/simulator/mach-ipc.md`: ports, messages, notifications, MIG.
- `specs/simulator/vm-shim-protocol.md`, `stage3-contract.md`, and
  `host-libraries.md`: the current machine.

## 1. Exit criterion (4a)

The following programs are in `research/experiments/simulator/stage4-probes/`.
They are built for the iOS simulator by the guest-tests build. On the Thor,
with no debug flags, each one prints its `ok` line and exits 0:

| Probe | Prints |
|---|---|
| `p_threads` | `threads ok counter=…` |
| `p_machmsg` | `machmsg ok …` |
| `p_dispatch` | `dispatch ok sum=…` |
| `p_dispatch_main` | `dispatch_main ok ticks=3` |

In addition:

- `hello` still passes.
- The stage-2 self-test still passes.
- Every test suite passes on macOS, x86-64 Linux, and the Thor.
- `p_bootstrap` belongs to 4b.

## 2. Execution model (orchestrator decision)

- **One Darwin process = one KVM VM. One Darwin thread = one vCPU.** Each
  vCPU is driven by its **own host thread**, which runs that vCPU's
  `KVM_RUN` loop. Guest threads therefore run in parallel on host cores,
  and a blocking Darwin call blocks only its own host thread.
- **vCPU pool.** KVM cannot destroy a single vCPU.
  - A finished thread's vCPU and host thread are **parked** and reused for
    the next new thread.
  - The VMM checks `KVM_CAP_MAX_VCPUS` at startup and reports it.
  - The pool is capped at **min(max_vcpus, 64)** per process. Exhaustion is
    reported as `EAGAIN` from `bsdthread_create` and as a refused workqueue
    request.
- **The kernel's shared state** (port spaces, the thread table, ulock
  queues, workqueues, kevent queues, the VFS, the address space) lives in
  one Swift object per VM.
  - It is protected by **one kernel lock** that is held while a trap is
    handled.
  - A blocking operation waits on a **host condition variable** associated
    with that lock, releasing the lock while it waits.
  - Correctness first: no fine-grained locking in 4a.
- **The address space is shared by every vCPU of the VM.**
  - Page-table changes are made under the kernel lock.
  - The trap that changed them resumes with the TLB-flush flag. The shim's
    flush becomes **`tlbi vmalle1is; dsb ish; isb`** (the inner-shareable
    broadcast). Every vCPU of the VM shares one VMID, so the hardware
    invalidates all of them.
  - Other vCPUs that are running are not stopped. A guest that unmaps
    memory another thread is using is a guest bug, as on Darwin.
- **No interrupts in 4a.** No GIC, no timer interrupts, and no preemption.
  Each vCPU has its own host thread, so a spinning guest thread delays
  nothing else.
- **FP/SIMD state** stays in each vCPU's own registers. KVM preserves it
  across exits, so the shim never saves it.

## 3. Shim changes (`ycode/SimShim/shim.S`)

- **Per-vCPU boot info.** Each vCPU starts at the shim entry with `x0` = the
  address of its **own** boot-info block (the stage-2 §4 layout). The block
  holds TTBR0/TCR/MAIR/SCTLR (the same for every vCPU of a VM), its own
  EL0 entry PC, SP, `TPIDRRO_EL0`/`TPIDR_EL0`, x0–x7, **its own trap-frame
  address, and its own EL1 stack top**.
  - The shim already keeps the boot-info pointer in `TPIDR_EL1`, so the
    vectors find the right frame for each vCPU.
  - The **secondary-vCPU path is the same code**.
  - The MMU may already be on for the address space when a secondary starts.
    Re-running the enable sequence with identical values is fine.
- **TLB flush:** the inner-shareable broadcast, as in §2.
- Everything else is unchanged.

## 4. Guest physical layout for per-vCPU structures

| Region | Size | Contents |
|---|---|---|
| GPA `0x4100_0000` (inside RAM) | 4 MiB | **vCPU slots**, 64 × 64 KiB. Slot *i* at `0x4100_0000 + i·0x1_0000` |

Each 64 KiB slot holds:

| Offset | Size | Contents |
|---|---|---|
| +0x0000 | 16 KiB | Boot info |
| +0x4000 | 16 KiB | Trap frame |
| +0x8000 | 32 KiB | EL1 stack. Top = slot + 0x1_0000 |

- The region is identity-mapped EL1 RW, UXN, PXN, like the stage-2 EL1
  regions.
- vCPU 0 (the main thread) **moves to slot 0**. The stage-2 single-frame
  addresses remain only for the stage-2 self-test mode.

## 5. Threads (`YcodeDarwinKernel` + hypervisor)

Following `threads-and-events.md` §1–§2:

- **`bsdthread_register` (366)** now answers the feature mask
  **`0x4000_00DF`**, which includes KEVENT (0x40) and WORKLOOP (0x80).
  Keep everything else stage 3 recorded.
- **`bsdthread_create` (360):**
  - Requires `PTHREAD_START_CUSTOM`.
  - Takes a pooled vCPU and assigns a thread port name. Names have
    `name & 3 == 3`, allocated from the port space (§7).
  - Stores the name in TSD slot 3 of the new pthread.
  - Starts the vCPU with the exact register state of the spec: pc =
    `thread_start`, x0 = pthread, x1 = port, x2 = func, x3 = arg, x4 =
    stack, x5 = flags, sp = stack, `TPIDRRO_EL0` = pthread + 224, all other
    GPRs zero.
  - Returns the pthread address. Its host thread enters the run loop.
- **`bsdthread_terminate` (361):**
  - Releases the stack (`munmap`) if asked.
  - Performs the **join-gate protocol** exactly as specified: store
    `port & ~3`, then wake through `UL_UNFAIR_LOCK | WAKE_ALL |
    ALLOW_NON_OWNER`.
  - Frees the port, then parks the vCPU (no return to EL0).
- **`thread_selfid` (372):** a unique 64-bit id per thread (main = 1).
  `__pthread_kill`: self-signal as in stage 3 (no cross-thread delivery in
  4a; log it).
- **ulock (515/516/544)** gets full multi-thread semantics: wait queues
  keyed by guest address, the timeout units of the spec, and a wait that
  returns the count of remaining waiters.
  - Wake modes are wake-one, wake-all, and wake-thread.
  - An unfair-lock wake from a thread that is not the owner is a no-op.
  - Prefer waking extra threads to waking too few.
  - The single-thread `DEADLOCK` heuristic from stage 3 is removed: a wait
    now really blocks.
- **Mach semaphores (−33…−39):** multi-thread semantics, as in the spec.
- **Workqueue (`workq_kernreturn` 368).** Implements NEWSPISUPP,
  REQTHREADS, THREAD_RETURN, KEVENT_RETURN, WORKLOOP_RETURN,
  SET_EVENT_MANAGER_PRIORITY, SHOULD_NARROW (always "no"), and
  SETUP_DISPATCH. REQTHREADS2 returns ENOTSUP.
  - Worker threads use the spec's memory layout: 560 KiB per thread with
    16 KiB pages, self at base + 540 KiB, the event list at self − 1152.
  - Workers enter `start_wqthread` with the spec's registers: x0 = self,
    x1 = port, x2 = stack bottom, x3 = event list or 0, x4 = upcall flags
    (QoS number in the low 12 bits), x5 = event count or −1.
  - **Admission rule.** A worker that blocks in the kernel (ulock, kevent,
    `mach_msg` receive, semaphore) frees its slot, so another worker may
    start. The parallelism limit is 8 per QoS bucket.
  - Idle workers are parked after 5 s with no work. Parked workers are
    reused before new ones are created.
- **kevent** (`kevent_qos` 374, `kevent_id` 375; `kevent` 363 and
  `kevent64` 369 too). Supported filters in 4a:
  - **EVFILT_USER**, including `NOTE_TRIGGER` (the manager wakeup).
  - **EVFILT_TIMER** (one-shot and repeating; mach-time, continuous, and
    wall-clock nanoseconds; leeway accepted and ignored).
  - **EVFILT_WORKLOOP** at the level `threads-and-events.md` §3 lists for
    libdispatch: thread request, value check (ESTALE), owner, and sync
    wait/wake.
  - **EVFILT_PROC / EVFILT_SIGNAL / EVFILT_READ / EVFILT_WRITE /
    EVFILT_VNODE**: accepted and registered, never fire. Each logs once.
  - **EVFILT_MACHPORT**: accepted and registered. It fires when a message
    is queued on the port. Delivering the message into the event (`ext[]`)
    is required in 4a only if `p_dispatch*` needs it; otherwise 4b.
  - **EVFILT_MEMORYSTATUS**: return an error. The spec says libdispatch
    tolerates that; confirm with the probes.
  - Struct layouts are as in the spec (`kevent_qos_s` is 72 bytes).
  - Events are delivered to workqueue threads through per-QoS buckets plus
    the manager bucket, following the spec. A delivered event is suppressed
    until the worker returns it.

## 6. Mach IPC inside one process (`YcodeDarwinKernel`)

Following `mach-ipc.md` §1–§5:

- **Port space.** Names are `(index << 8) | generation`, with the low 2
  bits = 3, allocated sequentially with last-freed-first reuse. The
  well-known names (task `0x103`, thread `0x203`, host `0x303`, bootstrap
  `0x0503`) keep their values: they are entries of the same space. Rights
  have user-reference counts with exactly the spec's rules. Port sets are
  supported.
- **Traps and routines:**
  - every `_kernelrpc_mach_port_*` trap in the trap table;
  - `mach_reply_port` (−26);
  - `thread_get_special_reply_port` (−50);
  - **`mach_msg_trap` (−31) and `mach_msg2_trap` (−47)**, with the exact
    header, descriptor (port, OOL memory, OOL ports, guarded port), and
    trailer layouts, every disposition, send then receive, timeouts,
    `MACH_RCV_LARGE`, pseudo-receive on send failure, the queue limit
    (default 5), and all the return codes of the spec;
  - notifications: dead-name, no-senders, send-once, and port-destroyed.
- **OOL memory within one task:** copy the pages into a fresh anonymous
  mapping in the receiver, which is the same address space in 4a. Honor
  `deallocate`.
- **Voucher stub:** `host_create_mach_voucher` and related routines succeed
  with voucher name 0.
- **The stage-3 `MachPortTable` is replaced** by this space. The stage-3
  §10 private traps keep working and allocate their names in it.

## 7. Library changes

- **libsystem_pthread (`SimHostLibs/pthread/`).** Real
  `pthread_create`, `_from_mach_thread`, `_suspended_np`, and the
  workgroup variant, plus `_pthread_start`/`thread_start`,
  `start_wqthread`/`_pthread_wqthread`, `pthread_join`/`detach` over the
  join gate, `pthread_exit`, `_pthread_workqueue_addthreads`,
  `_pthread_workloop_create`/`destroy`, and the workqueue setup with the
  real kernel. Remove the single-thread crash heuristics: waits now block
  in the kernel.
- **libsystem_kernel (`SimHostLibs/kernel/`).** Real wrappers for any
  stage-4a trap that is still a stub. `host_create_mach_voucher` and any
  voucher MIG routine libdispatch calls become private trap `0x7963_2007`
  (`host_create_mach_voucher(host, recipes, size, *voucher)` → success,
  `*voucher = 0`).

## 8. Ownership (stage 4a)

| Agent | Files |
|---|---|
| **S2** (shim) | `ycode/SimShim/shim.S`, `SimShim/README.md` (§3) |
| **V** (hypervisor) | `ycode/Sources/CKVM/`, `ycode/Sources/YcodeHypervisor/`, `ycode/Sources/ycode-simd/main.swift`, and new `ycode/SimShim/guest-tests/` build entries for the stage-4 probes (copy the probe sources into `guest-tests/stage4/`; the originals stay in research). Covers §2, §4, and the vCPU pool and run loops, integration, and the probe runs |
| **T2** (threads and events) | In `YcodeDarwinKernel`: new `Threads.swift`, `Workqueue.swift`, `KEvent.swift`, `ULock.swift`, `Semaphores.swift`, plus `DarwinKernel.swift` dispatch and `ExtendedBSD.swift` (§5). Tests in `Tests/YcodeDarwinKernelTests/` (new files) |
| **I** (Mach IPC) | In `YcodeDarwinKernel`: new `MachIPC*.swift`, replacing `MachPortTable.swift` (§6). Tests in new test files |
| **Q2** (pthread) | `ycode/SimHostLibs/pthread/` (§7) |
| **K2** (kernel library) | `ycode/SimHostLibs/kernel/` (§7) |

**The kernel lock and the blocking primitive are defined by T2** in a new
`KernelSync.swift`:

```
final class KernelLock { func withLock<T>(_ body: () throws -> T) rethrows -> T }
struct WaitQueue { func wait(on lock: KernelLock, deadline: UInt64?) -> WaitResult; func wake(count: Int) -> Int }
```

T2 publishes these first, as early as possible; I and V use them.

**Routing between T2 and I.**

- I owns a type `MachIPC` (one per VM), with this entry point:

  ```
  func handleTrap(x16: Int64, frame: inout TrapFrame, context: ThreadContext, memory: any GuestVirtualMemory) -> TrapOutcome?
  ```

  It returns nil for traps it does not own.
- **I owns all negative (Mach) traps**, except −3/−4 (clock), −10/−12/−14
  (VM), −33…−39 (semaphores, owned by T2), and −61 (`thread_switch`,
  owned by T2). **I also owns the stage-3 private range
  `0x7963_2000`–`0x7963_20FF`**: the §10 routines and the new voucher
  trap. They move out of `DarwinKernel.swift` into I's files.
- T2's `DarwinKernel` dispatch calls `machIPC.handleTrap` first for those
  ranges.
- I exposes what T2 needs:
  - `allocateThreadPort() -> UInt32`;
  - `deallocate(name:)`;
  - `messageQueued(on port) -> Bool`;
  - a hook that tells kevent's EVFILT_MACHPORT a message arrived. `DarwinKernel.handle` is
called from many host threads with a per-thread context: `ThreadContext`,
which holds the thread id, port name, and vCPU index.

The orchestrator owns `Package.swift`, the specs, and the commits.

## Evidence

- `threads-and-events.md` and `mach-ipc.md` (level 1, xnu-12377.121.6).
- `launchd-sim.md` (levels 3–4).
- The execution model is Ycode design, using the KVM facts in
  `threads-and-events.md` §6.
