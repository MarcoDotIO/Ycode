# Spec: guest thread start and wakeup latency

Status: **implemented 2026-10-19 (agent SP-THREADS)**. §2 is a diagnostic
(boot profile only). Every change has a switch. **On by default**: the
image's first vCPUs made with the prebuilt VM (§3.1, `YCODE_VCPU_PREBUILT`)
and wakeups after unlock (§4, `YCODE_WAKE_AFTER_UNLOCK`): together about
−8 to −10 % home_s (§6.3). **Off**: 16 precreated vCPUs, batch growth and
warm vCPUs (§3.1, §3.2): they cut the thread-start wait by up to 80 % but
did not bring the home screen sooner. Measurements are in §6.

This is Ycode's own design. The Linux facts (KVM vCPU creation, the arm64
MPIDR table, RCU grace periods) come from the Linux KVM API documentation
and the Linux kernel source (`virt/kvm/kvm_main.c`, `arch/arm64/kvm/arm.c`;
GPL, level 1). Nothing Apple-internal is named. Lock rules are those of
`stage6-contract.md` §5 and `boot-profile.md`.

## 1. Scope

The time from a guest thread start (`bsdthread_create`, a workqueue thread
request, the main thread) to the thread's first guest instruction, and from
a wakeup of a blocked guest thread (`WaitQueue.finish`: ulock, semaphore,
Mach receive, kevent, psynch) to its host thread running with the kernel
lock again. Not here: priorities and QoS (`scheduling-policy.md`), Mach IPC
locking, process start.

## 2. Measuring (diagnostic)

### 2.1 Boot profile header (`YCODE_BOOT_PROFILE`)

One `# latency` line with process-wide distributions (count, mean, p50,
p90, p99, max in µs, sum in ms; buckets a quarter of a power of two wide,
`LatencyHistogram`):

| Name | From → to |
|---|---|
| `start.parked` | start request → host thread takes the pending state; vCPU had run a thread before |
| `start.warm` | the same, vCPU and host thread made ahead (§3.2) |
| `start.claimedWarm` | the same, the start took a creation made ahead that had not finished |
| `start.created` | the same, a new vCPU was created for the start |
| `start.main` | vCPU 0's first thread |
| `creation.queue` | creation handed to a creator thread → it begins |
| `creation.create_vcpu` | `KVM_CREATE_VCPU` |
| `creation.vcpu_init` | `KVM_ARM_VCPU_INIT` + `kvm_run` mapping |
| `creation.pthread` | `pthread_create` of the vCPU's host thread |
| `wake` | `WaitQueue` waiter woken (`finish`) → its thread holds the kernel lock again (woken waits only, not timeouts or interrupts) |

### 2.2 Guest probe `SimShim/guest-tests/stageperf/p_threadlat`

Original Ycode code; times every latency in the guest with
`mach_absolute_time`. Prints `threadlat <name> n= p50= p90= p99= max=` (µs):
`create` (one `pthread_create` at a time, joined: a parked vCPU),
`burst.fresh` (12 threads started back to back and kept alive in a fresh
process, six processes: new vCPUs), `burst.parked` (the same again in that
process), `dispatch` (`dispatch_async_f` to a global queue → block runs;
back to back and after 30 ms idle), `sem` (`semaphore_signal` → the waiter
returns), `cond` (`pthread_cond_signal` → the waiter holds the mutex).
Run with `ycode-simd --exec p_threadlat`.

## 3. Thread start

### 3.1 Create the vCPUs before the VM runs (`YCODE_VCPU_PRECREATE`, `YCODE_VCPU_PREBUILT`, `YCODE_VCPU_BATCH_GROW`)

Finding (§6.1): a new vCPU for a running process cost 50–150 ms, almost
all of it waiting. Cause, from the Linux source (level 1): on arm64 KVM
keeps a VM-wide MPIDR → vCPU table (`kvm->arch.mpidr_data`). It is built
at a vCPU's first `KVM_RUN` once the VM has more than one vCPU, and every
`KVM_CREATE_VCPU` discards it with `synchronize_rcu()` before freeing it
(the Thor's 6.8.12-tegra kernel headers carry `struct kvm_mpidr_data` and
`kvm->arch.mpidr_data`).
A creation after a second vCPU first ran therefore waits for a full RCU
grace period (25–60 ms on the loaded Thor), and a burst of thread starts
queues behind those waits on the two creator threads
(`creation.queue`). Before any vCPU ran there is no table, and a
creation takes microseconds.

Rules:

- `YCODE_VCPU_PRECREATE=<n>` (1…64; default `YCODE_VCPU_BATCH + 1` = 4,
  the earlier behaviour): the batch made with vCPU 0 (`VirtualMachine.makeVCPU`
  when the VM has no vCPU yet) creates `n` vCPUs.
- `YCODE_VCPU_PREBUILT` (default on; `=0` off): the prebuilt VM (`PrebuiltVMs`,
  built off the kernel lock before a spawn or exec trap) makes those `n`
  vCPUs as spares (`makeSpareVCPUs`), so the image build under the kernel
  lock only takes them (vCPU 0's creation was about 3.2 ms of the 8.5 ms a
  spawn holds the kernel lock, measured by agent SP-SPAWN). With the
  default count (4) the vCPUs are the same as before, only made earlier.
- `YCODE_VCPU_BATCH_GROW=1` (default off): a later batch creates as many
  vCPUs as the VM already has (at least `YCODE_VCPU_BATCH + 1`), so a
  process growing to `m` threads pays about log2(m / n) grace periods.
- `YCODE_VCPU_CREATORS=<k>` (existing, default 2): more creator threads let
  the grace periods of different VMs overlap.
 The extra vCPUs are
spares: `KVM_CREATE_VCPU`, `KVM_ARM_VCPU_INIT` and the `kvm_run` mapping
are done; the host thread is made at the thread start (off the kernel
lock, `VCPUCreator`). Later batches are unchanged (`YCODE_VCPU_BATCH`).
Invariants: as `boot-profile.md`/`stage4a-contract.md` — ids below the
pool capacity, a spare is handed out once, `close` closes unused spares.

Cost with `n` = 16: about 10 µs per vCPU (under the kernel lock at image
build unless `YCODE_VCPU_PREBUILT=1`); kernel memory per vCPU (the vCPU
structure and its `kvm_run` page); about 17 vCPUs per image instead of 7
(10,000 instead of 4,300 `KVM_CREATE_VCPU` calls per boot).

### 3.2 Warm vCPUs (`YCODE_VCPU_WARM=<n>`, default 0)

Each pool keeps up to `n` vCPUs with their host threads created ahead and
parked (beyond the running threads). A start takes a parked one (a
condition signal), else claims a creation made ahead that is still
running (`claimedWarm`; the creator threads take claimed creations first),
else creates as before. After every start, and when vCPU 0 is made, the
pool queues creations to bring idle + unclaimed creations back to `n`
(never beyond the capacity). Accounting: an unclaimed creation counts as a
live host thread (the pool cannot finish before it ends) but not as an
active thread; a claim adds the active thread. A failed unclaimed creation
is dropped without ending the pool; a failed claimed one ends it, as
before. A finished unclaimed creation calls `onParked` (workqueue retry).

## 4. Wakeup after unlock (`YCODE_WAKE_AFTER_UNLOCK`, default on; `=0` off)

`WaitQueue.finish` with the kernel lock held by the waking thread records
the waiter on the lock instead of signalling it; the lock signals the
recorded waiters right after its mutex is released (`withLock`, `yield`,
`unlocked`), or under the mutex before a waiting thread sleeps (`sleep`).
The list keeps each waiter (and its condition variable) alive. The woken
thread then finds the mutex free instead of waking, blocking on the
mutex the waker still holds, and waking again. No wakeup is lost: the
result is set under the lock, and the waiter only sleeps while its result
is unset.

## 5. Not changed, and owner actions

- Kicks: blocked guest threads wait in the VMM (a condition variable), not
  in the guest; no signal is involved in a wakeup. Halt polling does not
  apply (the guest never waits in WFI/WFE).
- vCPU host-thread placement: left to the host scheduler and the
  scheduling policy's host backend (`scheduling-policy.md` §4.7: priority
  per class after a trap); no CPU affinity is set. A reused or warm host
  thread keeps its last class until the new thread's first trap, as a
  parked vCPU did before.
- Owner actions (root only, not done): `rcupdate.rcu_expedited=1` (or
  `rcu_normal=0` with expedited grace periods) would shorten the creation
  grace period left for processes with more than 16 threads; a lower
  `cpuidle` exit latency (e.g. `/dev/cpu_dma_latency` held at a small value
  by a privileged helper) would shorten wakeups of idle host CPUs
  (`dispatch` after 30 ms idle: p50 about 80 µs against 16 µs back to back).

## 6. Measurements (Thor, 2026-10-19)

Harness full boots (`YCODE_LEAN_BOOT` unset, device in RAM, one boot at a
time, arms interleaved per round; `SX/SPTHR/runs`); home_s at 5 s
resolution. Host load average 7–25 (other agents).

### 6.1 Probe (`p_threadlat`, idle host unless noted; µs)

| Measure | Default | `PRECREATE=16` | `PRECREATE=16 WARM=4` |
|---|---|---|---|
| `create` (parked vCPU) p50/p99 | 54 / 86–144 | 54 / 88 | 53 / 260 |
| `burst.fresh` p50 (six processes) | 36,000–154,000 | 200–475 | 68,000–146,000 (`WARM` alone) |
| `burst.parked` p50 | 110–200 | — | 110–350 |
| `dispatch` p50 (back to back / after 30 ms idle) | 15–16 / 78–217 | | |
| `sem` / `cond` p50 | 13–19 / 15–26 | | |

Phase split of a new vCPU (default): `creation.queue` mean 42 ms (p90 84
ms), `create_vcpu` p50 5 µs but p90 29 ms (the grace period), `vcpu_init`
6 µs, `pthread` 33 µs. With 16 made first: queue 23 µs, `create_vcpu` 4
µs. `YCODE_WAKE_AFTER_UNLOCK=1` in the probe (no lock contention): `sem`
p50 13–25 → 32–33 µs, no gain.

### 6.2 Boot profile (one profiled boot each, latency sums are thread-seconds)

| Arm | starts | start wait sum | `start.created` p50 / p90 | `creation.queue` p90 | wake n / p50 / mean / sum | home_s |
|---|---|---|---|---|---|---|
| default | 7,494 | 145.7 s | 1.6 / 168 ms | 134 ms | 1.05 M / 197 µs / 708 µs / 744 s | 160 |
| `PRECREATE=16` | 6,919 | 53.4 s | 0.39 / 101 ms | 84 ms | 0.97 M / 328 µs / 948 µs / 917 s | 270 |
| `PRECREATE=16 WARM=2` | 7,109 | 49.2 s (warm starts p50 20 µs) | — | 84 ms | 1.01 M / 328 µs / 862 µs / 866 s | 230 |
| `PRECREATE=16 BATCH_GROW=1 CREATORS=4` | 7,028 | 30.5 s | 0.33 / 50 ms | 34 ms | 0.98 M / 328 µs / 796 µs / 782 s | 240 |
| default (prof4) | 6,782 | 159.2 s | 3.1 / 268 ms | 268 ms | 1.00 M / 262 µs / 730 µs / 727 s | 225 |
| `WAKE_AFTER_UNLOCK=1` (prof4) | 7,626 | 113.9 s | 0.9 / 134 ms | 101 ms | 1.08 M / 197 µs / 553 µs / 599 s | 190 |

About 21–30 images per boot have more than 16 threads (healthd, dasd,
PosterBoard and SpringBoard up to the 64-vCPU capacity); they carry most of
the remaining start wait. In the boot, a wakeup is not the probe's 4 µs:
the woken thread must take the global kernel lock again (p50 200–330 µs),
so `wake` measures lock contention more than the wakeup itself.

### 6.3 Home screen (unprofiled, paired)

| Series | Arms (home_s per round) | Means |
|---|---|---|
| A (3 rounds) | default 210, 230, 195 · `PRECREATE=16` 225, 240, 230 · `+WARM=2` 240, 235, 195 | 212 · 232 · 223 |
| B (3 rounds) | default 175, 175, 195 · `PRECREATE=16 PREBUILT BATCH_GROW CREATORS=4` 215, 165, 200 | 182 · 193 |
| C (3 rounds) | default 160, 165, 185 · `WAKE_AFTER_UNLOCK=1` 185, 135, 140 · `PREBUILT=1` (4 vCPUs) 200, 140, 125 | 170 · 153 · 155 |
| D (4 rounds) | default 205, 185, 140, 175 · `WAKE_AFTER_UNLOCK=1 PREBUILT=1` 150, 180, 130, 190 | 176 · 162.5 |

Thread starts are off the boot's critical path: cutting their summed wait
by 80 % (146 → 30 s) did not bring the home screen sooner (the critical
path is the chain of process starts, `boot-profile.md` §2, §5). The
precreate arms were 10–20 s slower on average, within the noise but never
ahead, so they stay off.

Wakeups after unlock and the prebuilt first vCPUs both shorten kernel-lock
work on the critical path: wake after unlock won 6 of 8 pairs (C, D, prof4;
mean −8 to −16 %), prebuilt vCPUs 2 of 3 alone and 3 of 4 together with it.
The gain is near the run-to-run noise (±25 s), so both are on by default
as small wins that change no guest-visible behaviour. Every boot reached
the home screen; no host crash; `guest_fatal` 7–13 in every arm.

## Evidence

| Claim | Level | Source |
|---|---|---|
| `KVM_CREATE_VCPU` discards the arm64 MPIDR table with `synchronize_rcu()`; the table is built at a vCPU's first run when the VM has more than one vCPU | 1 | Linux `arch/arm64/kvm/arm.c` (`kvm_arch_vcpu_create`, `kvm_init_mpidr_data`, `kvm_destroy_mpidr_data`) |
| Creation cost before and after the first run, phase split | 3 | `p_threadlat` and boot profiles on the Thor (§6) |
| Guest latencies | 3 | `p_threadlat` (original Ycode code) |

Levels 2, 4 and 5 were not used. `.claude/Xcode.app`, the reference tools,
`research/` and Ghidra were not opened.
