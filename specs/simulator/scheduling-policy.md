# Spec: scheduling policy (process types, darwin-bg, importance, thread QoS)

Status: **implemented** (2026-10-17). The start hold (§4.2) is **on by
default** since 2026-10-19 (§7); thread QoS, lock admission and host
scheduling stay behind switches (§6). This spec answers
the CONTRACT-REQUEST of `service-fidelity.md` §7: the Mac keeps unboosted
Adaptive and Background jobs from running while the system is busy, and
Ycode did not. It also gives guest threads a scheduling class, which the
global kernel lock and the host scheduler use.

Sections 1–3 are facts about Darwin and about the Mac's simulator. Sections
4–6 are Ycode's own design (normative for `ycode/`). Section 7 has the
measurements.

## 1. Inputs

| Input | Where it comes from | Values |
|---|---|---|
| Process type | launchd plist key `ProcessType` (launchd.plist(5); the simulator's plists use `POSIXSpawnType`), passed by launchd_sim as `psa_apptype` (`processes.md` §1.6) | Interactive 0x400, Standard 0x300, Adaptive 0x600, Background 0x500, App 0x100 (non-UI 0x200) |
| QoS clamp | `psa_qos_clamp` @80 | 0 none, 1 utility, 2 background, 3 maintenance |
| Darwin role | `psa_darwin_role` @88 | 6 = darwin-bg |
| Watch ports | spawn port action IMP_WATCHPORTS (type 3, `processes.md` §1.8) | the job's service ports |
| Process darwin-bg | `setpriority(PRIO_DARWIN_PROCESS 4, pid, PRIO_DARWIN_BG 0x1000)`; 0 clears | |
| Thread darwin-bg | `setpriority(PRIO_DARWIN_THREAD 3, 0, PRIO_DARWIN_BG)`; 0 clears | |
| Thread QoS | workqueue request QoS (`threads-and-events.md` §2.4, §2.5); `bsdthread_ctl` SET_SELF with the QOS flag; `bsdthread_create` with `PTHREAD_START_QOSCLASS` | QoS 1…6 |
| QoS overrides | `bsdthread_ctl` QOS_OVERRIDE_START/END (0x40/0x80, keyed by resource), QOS_OVERRIDE_DISPATCH (0x400), QOS_OVERRIDE_RESET (0x200) | |
| Importance | `MACH_SEND_NOIMPORTANCE` (0x40000) send option turns it off for one message | |

The runtime's job plists (iOS 27.1, level 2): LaunchDaemons 248 Adaptive,
48 Interactive, 9 App, 8 Background (among them
`com.apple.Safari.passwordbreachd`, `com.apple.spotlightknowledged`,
`com.apple.logd_reporter`), 1 Standard, 1 AdaptiveUtility, 14 without a type;
LaunchAgents 9 Adaptive.

## 2. Darwin behavior (xnu, level 1)

### 2.1 Importance donors and receivers (at spawn)

| Type | Donor | Receiver |
|---|---|---|
| App, App non-UI | yes (live donor) | no |
| Interactive daemon | yes | no |
| Standard daemon | yes | no |
| Adaptive daemon | no | **yes** |
| Background daemon | no | no |

### 2.2 darwin-bg and the main thread

- An Adaptive daemon is darwin-bg while it is not boosted. A Background
  daemon is always darwin-bg. A QoS clamp of background or maintenance also
  makes a task darwin-bg; so do the darwin-bg role and `PRIO_DARWIN_BG`.
- darwin-bg threads run at priority `MAXPRI_THROTTLE` (4), with throttled
  I/O (default background tier 2) and background sockets.
- The main thread starts at a QoS from the type: App user-interactive;
  Interactive, Standard, Adaptive, App non-UI, driver: legacy (default);
  Background: background. A clamp caps it.

### 2.3 Importance

A Mach message sent by a donor (or by a boosted receiver, through its
voucher) carries importance unless it was sent with
`MACH_SEND_NOIMPORTANCE`. A port counts the importance messages in its queue.
That count boosts the receiver task that the port is bound to. While a
receiver holds at least one boost, it is not darwin-bg. When a message is
received, its importance moves to the receiving thread's voucher. It stays
there until the work for it is done.

At spawn, each IMP_WATCHPORTS port is bound to the new task, but only if
that task is an importance receiver. The port's queued importance boosts
the task at once. So a job that launchd starts because a client already
sent to its service port is boosted from its first instruction. A job
started speculatively (RunAtLoad, KeepAlive) stays darwin-bg until a client
sends to it.

### 2.4 Inheritance

The owner of an unfair lock (`UL_UNFAIR_LOCK`, its owner is named in the
lock word, `threads-and-events.md` §4.1) is promoted to the highest
priority of its waiters while they wait (turnstiles). A synchronous IPC
sender that waits for its reply (send and receive in one call, with a
send-once reply right) pushes its priority onto the thread that serves the
request, until the reply.

### 2.5 The scheduler's classes (`doc/scheduler/sched_clutch_edge.md`)

Threads are grouped by QoS bucket (FG, IN, DF, UT, BG). Buckets are picked
earliest-deadline-first. The deadline is the time the bucket became
runnable plus its worst-case execution latency (WCEL): FG 0, IN 37.5 ms,
DF 75 ms, UT 150 ms, BG 250 ms. A higher bucket can warp ahead within its
warp budget (FG 8 ms, IN 4, DF 2, UT 1, BG 0). A lower bucket that EDF
picks over a runnable higher one gets one quantum (starvation avoidance).

## 3. The Mac's simulator (black box, level 3)

Two boots of a throwaway device (`ycode-test-prio-1`, iPhone Duo,
iOS 27.1 24A94401), sampled with `ps -o pid,ppid,stat,pri,nice,time,command`
every 0.25 s over the children of its `launchd_sim`. A job runs as
`xpcproxy_sim <label>` until it executes the daemon. The time the job spends
there is its *start delay*.

**First boot** (the device used about 5 CPUs for the first 150 s):

| Start delay | Jobs (all started at +0.5 s, priority 4 the whole time, state R, 0.00–0.03 s CPU) |
|---|---|
| 1.5–2.1 s | runningboardd, routined, biomed, accountsd, ids_simd, tccd |
| 4.6–5.4 s | assistantd, peopled, ManagedSettingsAgent, amsaccountsd |
| 10.7–11.2 s | replicatord, mediaremoted |
| 18.9–22.1 s | remindd, axassetsd, appprotectiond, passd |
| **254.7 s, all at the same sample** | healthd, parsecd, fileindexerd, wcd, nanoprefsyncd.2, navd, revisiond, deviceconfigurationd |

Jobs started on demand (a client's lookup and message) ran at priority 46
(state U for at most 0.3 s) and started at once: diagnosticd, logd_helper,
installd, pkd, chronod, linkd, maild and 20 others. Later Adaptive starts
without a client waited at priority 4: eligibilityd 10 s, DeviceConfigurationAgent
24 s, localizationswitcherd 9 s.

**Second boot** (the device used less than 1 CPU after 10 s): the same 22
jobs, again at priority 4, started after 0.8 s. The exceptions were navd
and deviceconfigurationd (33 s). The Background job
`Safari.passwordbreachd` stayed in xpcproxy_sim at priority 3–4 for the
whole 305 s.

**After the start**, an Adaptive daemon's priority switches between 4
(darwin-bg) and 31, 37 or 46 (boosted). For example, replicatord was at
priority 4 in 551 samples and at 46 in 49. Interactive daemons
(backboardd, SpringBoard) never show 4.

`service-fidelity.md` §7.1 had a third boot with start delays of 3.9–172 s
and states U.

Conclusions used by §4:

1. The delay is not a fixed timer. It depends on how busy the host is: 0.8 s
   on a quiet host, up to 255 s on a busy one. The jobs in a long hold were
   all released at the same moment.
2. Only unboosted Adaptive jobs and Background jobs wait. A job that a
   client already sent to does not wait.
3. While it waits, the job uses almost no CPU.

## 4. Ycode design

### 4.1 Per-process state

Each process record keeps: the type (`psa_apptype`; an exec keeps the
process's type unless the exec's attributes name one), the clamp, the role,
the requested darwin-bg, its importance count (`boosts`), and the start of
its hold. darwin-bg and the donor/receiver roles follow §2.1–§2.2.

### 4.2 The start hold (`YCODE_ADAPTIVE_HOLD=1`)

In an ordinary spawn, an Adaptive or Background child is held when its
watch ports carry no importance (boosts = 0 after §4.3 binding), no
message is queued on any of them (**on demand**, below), and the spawn did
not ask for `START_SUSPENDED`. A held child's image is built with
its main thread not started, the same as `START_SUSPENDED`, except that the
process state stays *running* (`ps`, `proc_info` and `wait4` see a running
process, as on the Mac). The hold ends with the first of these events:

| Event | Reason logged |
|---|---|
| its boosts become > 0 (an Adaptive job only; §4.3) | `boost` |
| the system is quiet: over the last `YCODE_ADAPTIVE_HOLD_WINDOW_MS` (default 2000 ms; a full window is needed) the kernel lock was held less than `YCODE_ADAPTIVE_HOLD_BUSY_PERCENT` (default 25 %) of the time, no guest thread had to wait for the kernel lock for `YCODE_ADAPTIVE_HOLD_QUIET_MS` (default 250 ms, the BG bucket's WCEL; with the admission gate of §4.5 only threads of class ≥ df count), and the hold is at least `QUIET_MS` old. All quiet holds are released together. | `quiet` |
| the hold reached `YCODE_ADAPTIVE_HOLD_MAX_S` (default 300 s; the Mac's longest observed delay is 255 s) | `timeout` |
| the process exits or is killed while it is held (its image never runs) | `exit` |

A "hold thread" (a host thread with no guest context) checks the quiet
and bound tests every 50 ms under the kernel lock, and exits when no
process is held. The busy fraction is the growth of the lock's total
held time between the samples that span the window. A boost releases the job at once, in the trap that
queued the message.

**On demand** (`YCODE_ADAPTIVE_HOLD_DEMAND`, default on; added
2026-10-19). A job whose watch ports already hold a message when it is
spawned was started by launchd_sim because a client sent to it, and that
client waits for the answer (§3 conclusion 2: on the Mac such jobs start
at once). It is not held, whether or not the message carries importance;
the log line is `not held (<type>, on demand: N messages queued at
spawn)`. The importance rule alone missed these starts when the sender was
not a donor at that moment: an Adaptive daemon is a donor only while it is
boosted, and iconservicesagent renders the home screen's icons on its own
queues after SpringBoard's request has been answered. Its first shader
compile goes to an XPC service instance, `com.apple.MTLCompilerService.<UUID>`
(Adaptive), and that start was held until the system was quiet: 21.7 s and
33.6 s in two boots, every icon of the home screen waiting behind it
(§7.3, `home-screen.md` §2.1).

The hold is decided when launchd_sim spawns the job's `xpcproxy_sim`
(the spawn carries the type and the watch ports), so, as on the Mac, the
waiting process is `xpcproxy_sim <label>`. The exec of the daemon does
not hold again.

The busy fraction (added after the first runs, which used the
contention test alone) makes "quiet" mean low use of the kernel lock,
not only the absence of a waiter.

The quiet test is Ycode's stand-in for the Mac's mechanism: a darwin-bg
`xpcproxy_sim` gets CPU and I/O only when nothing above it needs them. In
Ycode the scarce resource is the kernel lock.

### 4.3 Importance bookkeeping (either switch)

- At send, a user message carries importance when the sending process is a
  donor (§2.1; an Adaptive daemon only while it is boosted) and the send has
  no `MACH_SEND_NOIMPORTANCE`. Kernel messages (notifications, timer
  expiries, kernel-object replies) carry none.
- A message carries importance only to a port that accepts it (xnu
  `ip_impdonation`): one made by `mach_port_construct` with
  `MPO_IMPORTANCE_RECEIVER` (0x08), `MPO_DENAP_RECEIVER` (0x40) or
  `MPO_TEMPOWNER` (0x04), or given `mach_port_set_attributes` flavor 4
  TEMPOWNER, 5 IMPORTANCE_RECEIVER or 6 DENAP_RECEIVER. TEMPOWNER (both
  ways) also makes the port a *temporary owner* (launchd's service ports).
- Each port keeps `importanceCount`, the number of queued importance
  messages. It also keeps the process it currently credits: the holder of
  the receive right when that holder is an importance receiver, or else the
  receiver the port was bound to as a watch port. Each enqueue and dequeue
  moves the credit to the current target first, then adds or removes one
  boost.
- At spawn, after the child's record exists, each watch port is bound to
  the child (only when the child is a receiver). The importance already
  queued on a watch port that is a temporary owner moves to the child. That is what starts on-demand jobs
  boosted.
- On receive, a thread of a receiver process that takes an importance
  message carries one boost of its own process. The boost ends at the end
  of the *servicing episode*: the thread's next receive, its next return to
  the workqueue (THREAD_RETURN, KEVENT_RETURN, WORKLOOP_RETURN), or its
  exit.
- A port that dies drops its credited boosts. A boost credited to a process
  that ended is lost with the process.

### 4.4 Effective class of a thread (`YCODE_SCHED_QOS=1`)

1. Base QoS: the thread's requested QoS when set. The main thread starts at
   the type's QoS (§2.2). `bsdthread_create` uses `PTHREAD_START_QOSCLASS`,
   or else the creator's base QoS. SET_SELF sets it. For a workqueue thread
   with nothing requested, it is the QoS of its current request. A kqworkq
   bucket counts as its QoS, and the manager bucket counts as legacy. Each
   new request clears the thread's requested QoS and its overrides.
2. Raise it to the highest override (explicit overrides by resource,
   dispatch override).
3. Cap it at the process clamp.
4. Map it to a class: maintenance and background → **bg (0)**;
   utility → **ut (1)**; legacy and unspecified → **df (2)**;
   user-initiated, user-interactive → **ui (3)**.
5. A darwin-bg process or thread → bg.
6. Raise it to the highest inheritance push (§4.6). A push is not capped
   by darwin-bg.

The class is recomputed whenever an input changes: a QoS call, a workqueue
request, a boost that flips darwin-bg (all threads of the process), or a
push. Host threads with no guest context (timer and hold threads) count as
ui.

### 4.5 Kernel lock admission

Every guest trap takes the one kernel lock (`stage4a-contract.md` §2). With
`YCODE_SCHED_QOS=1` and `YCODE_LOCK_ADMISSION=1` (off by default, §7), acquiring it goes
like this:

1. A thread of class c < ui first checks whether a thread of a higher class
   is blocked on the lock. While one is, it waits at the *admission gate*,
   for at most the bound of its class: `YCODE_LOCK_ADMISSION_BOUND_MS`,
   default bg 250, ut 150, df 75 ms (the WCELs of §2.5). When the bound
   ends, it competes anyway (anti-starvation).
2. It tries the lock. If the lock is taken, the thread counts itself as
   *contending* in its class until it gets the lock. A contended
   acquisition by a guest thread of class ≥ df stamps the "last
   contention" time that §4.2's quiet test reads.

There is no handoff and no queue: threads of one class compete as before.
The gate only keeps lower classes from taking the lock while a higher one
is waiting.

Re-acquisition after a `WaitQueue` sleep (the condition variable takes the
mutex back) does not pass the gate. A woken thread gets the lock back
without delay.

**Lock order and progress.** The gate holds no kernel state. A thread
waits at the gate *before* it takes the kernel lock. The thread does not
hold the kernel lock while it waits at the gate. The gate mutex is a leaf:
nothing is taken while it is held. So the gate cannot take part in a
deadlock.

Every gate wait ends by its bound, so no thread starves for longer than
its bound per acquisition.

A wakeup cannot be lost: a waiter adds itself to the gate-waiter count and
then reads the contending count under the gate mutex. A thread that stops
contending lowers the count, then reads the waiter count, and then
broadcasts under the gate mutex. All four operations are sequentially
consistent. Each wait is also cut into slices of at most 1 ms.

### 4.6 Inheritance

- **ulock**: while threads wait on an `UL_UNFAIR_LOCK` with a named owner,
  the owner has a push equal to the highest class of the waiters. The push
  is updated when a waiter starts or stops waiting, and when a wake hands
  the lock to a new owner. The old owner loses the push. Pushes are not
  transitive.
- **Synchronous IPC**: a message sent with a receive in the same call and a
  send-once reply right carries the sender's class. The thread that
  receives it has that push until the end of its servicing episode (§4.3).

### 4.7 Host scheduling (`YCODE_HOST_SCHED`)

A guest thread runs on its own host thread (one vCPU, `stage4a-contract.md`
§5). After each trap, outside the lock, the host thread compares its class
with the class it last applied. If they differ, it applies the new class:

| Backend | bg | ut | df | ui | Needs |
|---|---|---|---|---|---|
| `nice` | 19 | 8 | 3 | 0 | RLIMIT_NICE ≥ 20 or CAP_SYS_NICE. A thread must be able to come back to 0. With RLIMIT_NICE 0 (the Thor), the backend reports that it is unavailable and stays off. |
| `cgroup` | `cpu.idle` 1 | weight 25 | 100 | 400 | A delegated cgroup v2 with the cpu controller. The VMM makes four threaded children `ycode-class0…3` of its own cgroup. Moving a thread is one write of its tid to the child's `cgroup.threads`. Without write access, the VMM first re-executes itself in place with `systemd-run --user --scope -p Delegate=yes`, which keeps the pid. |
| `none` (default) | — | — | — | — | |

### 4.8 What is not modelled

- I/O throttling tiers, background sockets, the jetsam bands.
- Live-donor apps changing with their UI state. Apps are donors.
- Importance carried by vouchers past the end of the servicing episode.
- Transitive pushes.
- The clutch scheduler's warp, quanta and per-cluster runqueues. Only the
  WCEL bounds are used.
- `getpriority` still answers as before.

## 5. Diagnostics

- `ycode-simd: sched: start hold on|off, thread QoS on|off, lock admission
  on|off, host <backend status>` at start.
- `ycode-simd: sched: pid N <label>: start held (<type>, unboosted)` and
  `... start hold released (<reason>) after N ms` for each hold.
- With tracing on: `note: sched: pid N type T clamp C role R boosts B [held]`
  for each spawn.
- `... pid N <label>: not held (<type>, on demand: N messages queued at
  spawn)` for each start the on-demand rule exempts.
- With `YCODE_ADAPTIVE_HOLD_TRACE=1`: `... pid N <label>: not held (<type>,
  B boosts at spawn from pids [...])` for each Adaptive or Background spawn
  that is not held (the pids are the senders of the queued importance
  messages), and once a second while a job is held, `hold inputs: lock
  busy P% over N ms, last contention N ms ago, N held`.
- At exit: `ycode-simd: sched: start holds N (boost, quiet, timeout, exit,
  still held; not held on demand N), ms held; class changes; importance: receiving ports,
  temporary owners, importance messages, donor sends to other ports; lock
  admission: gate waits, ms, at the bound; host scheduling …; moves,
  failures`.

## 6. Switches

| Variable | Default | Effect |
|---|---|---|
| `YCODE_ADAPTIVE_HOLD` | 1 | §4.2 (and §4.3); `0` turns it off |
| `YCODE_ADAPTIVE_HOLD_QUIET_MS` | 250 | §4.2 |
| `YCODE_ADAPTIVE_HOLD_BUSY_PERCENT` | 25 | §4.2 |
| `YCODE_ADAPTIVE_HOLD_WINDOW_MS` | 2000 | §4.2 |
| `YCODE_ADAPTIVE_HOLD_TRACE` | 0 | §5 |
| `YCODE_ADAPTIVE_HOLD_MAX_S` | 300 | §4.2 |
| `YCODE_ADAPTIVE_HOLD_DEMAND` | 1 | §4.2 on-demand starts are not held; `0` holds them |
| `YCODE_SCHED_QOS` | 0 | §4.3–§4.6, and §4.7 when a backend is chosen |
| `YCODE_LOCK_ADMISSION` | 0 | §4.5 (with `YCODE_SCHED_QOS`) |
| `YCODE_LOCK_ADMISSION_BOUND_MS` | `250,150,75` | §4.5 bounds for bg, ut, df |
| `YCODE_HOST_SCHED` | none | `nice`, `cgroup` (§4.7) |
| `YCODE_BOOT_PRIORITY` | 0 | `1`, device runs only: with `YCODE_SCHED_QOS` unset, set it to 1 and `YCODE_HOST_SCHED` (if unset) to `cgroup` before the VMM starts (§7.4) |

## 7. Measurements

### 7.1 Thor, full boot (agent PRIO, 2026-10-19)

SX harness, full boot (`YCODE_LEAN_BOOT` unset), 700 s, device in RAM,
at most two PRIO boots at a time (other agents' boots may have run in the
third slot). Build `d0f1549` (the main line merged); *main* is the main line
`65ef9fe` built the same way. Arms: **main**; **hold**
(`YCODE_ADAPTIVE_HOLD=1`); **hold+QoS** (`YCODE_ADAPTIVE_HOLD=1
YCODE_SCHED_QOS=1 YCODE_HOST_SCHED=cgroup`, lock admission off). Starts are
process images per program in the exit report (`xpcproxy_sim` not counted);
lock % is kernel-lock held time over 700 s.

| Arm (runs) | home_s each | mean ± sd | Guest traps M | Lock % | guest_fatal | Images | pairedsyncd | replicatord | mlhostd | proactiveeventtrackerd | facetimemessagestored | fileindexerd |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| main (m1–m5) | 180, 190, 240, 175, 200 | 197 ± 26 | 9.1–9.2 (m5 12.4) | 19–23 (m5 32) | 18–28 | 1136–1144 (m5 1246) | 65–66 | 2 (1 abort, signal 6) | 49–54 | 64–66 | 64 | 16 |
| hold (h1a, h3–h5) | 160, 200, 175, 175 | 178 ± 17 | 8.7–8.9 | 17–23 | 10–11 | 986–1010 | **1** | **1** | 51–56 | 66–67 | 65 | 9–14 |
| hold+QoS (q8–q11) | 165, 155, 185, 155 | 165 ± 14 | 8.8–8.9 | 19–23 | 8–10 | 997–1008 | **1** | **1** | 52–56 | 65–66 | 65–66 | 12–15 |

parsecd, axassetsd and intelligencetasksd start 1, 1 and 16 times in
every run of every arm.

A confirmation run with the default build (no switches set, the hold on
by default; `dflt1`, paired with main-line run `m6`): home_s 185 against
200, pairedsyncd 1 against 65, replicatord 1 against 2, guest_fatal 11
against 24. Its guest traps (12.2 M) and lock time (34 %) were high, as in
m5 (12.4 M, 32 %), and 22 of its 91 holds ended at the 300 s bound: other
agents' boots shared the Thor during both runs.

Holds per hold run: 92–101, released by boost 26–32, quiet 51–72, timeout
0–7. The jobs released by a boost are the ones a client talks to early
(runningboardd 1–2 s, axassetsd 6–14 s, replicatord 11–25 s, parsecd
26–52 s); the speculative group (peopled, wcd, navd, revisiond,
deviceconfigurationd, nanoprefsyncd, ManagedSettingsAgent, fileindexerd) is
released together, by the quiet test at 212–293 s (h3–h5, q8–q11) or by
the 300 s bound (h1a).

Reading:

- **The hold improves fidelity**: pairedsyncd's restart loop (65–66 starts)
  is gone, replicatord no longer aborts (`service-fidelity.md` §6), the
  number of process images falls by 12 %, guest traps by 3 %, and the fatal
  guest conditions from 18–28 to 10–11 (the replicatord abort and fewer
  fileindexerd crashes; the 16 intelligencetasksd crashes stay, as on the
  Mac).
- **Time does not regress**: 178 ± 17 s against 197 ± 26 s (difference
  −19 s, standard error 15 s: faster within noise).
- **QoS with the cgroup backend** adds 50–51 k thread moves per run and no
  failures. It is 13 s faster than hold alone (standard error 11 s, not
  significant) and changes no start count. It stays behind its switch.
- **Lock admission** (earlier runs q1, q2, with the gate on, on the
  2026-10-17 build): the home screen was not reached in 700 s (1.9 M and
  0.4 M gate waits, 18 600 s and 21 900 s of waiting in all). It stays off.
- The run q5 of 2026-10-18 (hold+QoS, cgroup) ended with a host crash in
  Foundation's `Process.run` (reading `/proc/self/fd`) while starting the
  shader translator, a host race unrelated to this policy.

### 7.2 Against the Mac with the same device state

Method of `parity-ladder.md` §4.5: the throwaway Mac devices
`ycode-test-prio-aged-1` and `-2` (iPhone Duo, iOS 27.1 runtime
24A94401, on macOS 27.2 26B5112a and Xcode 27.1 27A9269, both just
updated) were given, before their first boot, the `DEV/data` of Ycode run
`h5` (the Thor's golden device after one more boot), booted for 700 s,
sampled with `ps`, and deleted. Run 1 was shut down from outside after
354 s (launchd_sim got SIGTERM from outside this tool), so its counts
cover 354 s. Start delay = "xpcproxy_sim spawned" to "INIT" in
`launchd.log`, the same lines in both platforms' logs.

| | Mac 1 (354 s) | Mac 2 (700 s) | Ycode h5 (700 s) |
|---|---|---|---|
| home_s | 35.8 | 22.7 | 175 |
| Programs started | 490 | 631 | 503 |
| pairedsyncd | 1 (speculative, +66 s) | 1 (+41 s) | 1 (+230 s, held 69 s) |
| replicatord | 1, held 13.2 s, no abort | 1, held 8.8 s | 1, held 11.1 s, no abort |
| axassetsd / parsecd delay | 1.9 / 2.5 s | 2.8 / 1.6 s | 6.1 / 26.4 s |
| healthd, passd, appprotectiond delay | 14.5, 12.0, 17.1 s | 9.4, 9.1, — | 23.2, 46.5, 45.4 s |
| peopled, navd, wcd, revisiond, fileindexerd, deviceconfigurationd (released together) | 33.8–38.8 s | 11.2–11.3 s | 226.6–227.4 s |
| mlhostd starts (period) | 30 (10.2 s) | 68 | 56 (first start 124 s against 12–52 s) |
| proactiveeventtrackerd starts (period) | 35 (10.2–10.7 s) | 69 | 66 (10.6 s) |
| facetimemessagestored starts (period) | 34 (10.3–10.8 s) | 68 | 65 |
| Start delay of those restarts | ≤ 0.5 s | ≤ 0.3 s | ≤ 0.7 s |
| Abnormal exits | intelligencetasksd 15 × SIGTRAP | intelligencetasksd 16 × SIGTRAP | intelligencetasksd 16 × SIGTRAP, fileindexerd 14 × SIGTRAP |

- The Mac holds the same jobs as Ycode and releases them in the same
  order; the jobs it holds longest are released together on both. The
  holds scale with each platform's boot (Mac 9–39 s for a 23–36 s boot,
  Ycode 6–227 s for a 175 s boot).
- The three restart loops run on the Mac at launchd's throttle rate
  (about 10.3 s), started by an XPC event and not held (delay under
  0.5 s): 68–69 starts in 700 s. Ycode starts them 56–66 times at the same
  rate, also boosted at spawn (`not held … boosts at spawn from` the
  event's sender: UserEventAgent for proactiveeventtrackerd and
  facetimemessagestored, dasd for mlhostd). The earlier Mac reference of
  28, 42 and 41 starts (`service-fidelity.md` §12.1, 2026-10-17) came from a
  Mac under load before the update, whose restart period was about 14 s.
- fileindexerd's crashes are Ycode's own (`service-fidelity.md` §11); the
  hold lowers them from 16 to 9–14.

### 7.3 On-demand starts and the home screen's icons (agent SIM-INPUT2, 2026-10-19)

Thor, release builds, one boot slot, other agents' boots in parallel. a1
and a2 boot copies of the same device (booted twice before, so its
LaunchServices data is settled); a3 a copy of the pristine device (its
first boot). Frames every 5 s; "icons" is the first frame in which the
Settings icon is drawn (not the grey placeholder), "wallpaper" the first
lit frame (mean brightness over 60; light appearance).

| Run | `YCODE_ADAPTIVE_HOLD_DEMAND` | MTLCompilerService | Wallpaper | Icons | Holds (boost, quiet; on demand not held) | Time held in all |
|---|---|---|---|---|---|---|
| a1 | 0 | held 33.6 s (quiet) | 80 s | 105 s | 69 (25, 43; –) | 2272 s |
| a2 | 1 | not held | 70 s | 60–70 s (with the wallpaper) | 41 (18, 23; 27) | 1415 s |
| a3 (first boot) | 1 | not held | 85 s | 75 s (before the wallpaper) | 44 (18, 25; 49) | 1699 s |
| i2 (earlier build, = a1's rule) | – | held 21.7 s (quiet) | 60 s | 85 s | 87 (25, 62) | 1595 s |

In a1 iconservicesagent's first "Metal Compiling Shader" and its second
were 36.7 s apart, and RenderBox logged "building pipeline … took 24.3
seconds" in i2; in a2 they were 1.0 s apart. With the rule the icons come
with the wallpaper, as on the Mac (where they are there with the home
screen). The jobs it exempts are on-demand launches such as pkd,
mobileassetd, akd, linkd, iconservicesagent itself and the XPC service
instances of MTLCompilerService and BackgroundShortcutRunner. Single boots
on a shared host: the wallpaper times are within the spread of §7.1; only
the icon delay is a clear effect.

### 7.4 Thread QoS with the cgroup backend for device runs (agent BOOT-CP, 2026-10-24)

`boot-profile.md` §8.3: a cold boot of a device booted before at its own
path is CPU-bound on the host (9.2 of 14 cores busy on average to the home
screen, 6.9 threads waiting for a CPU on average), and every host thread
had the same share, so SpringBoard's main thread and diagnosticd's
workloop threads waited for CPUs behind about 190 daemons' loaders.
Timed boots (`SX/bin/timed.sh`, one series, the area's device, the same
build; arms rotated each round):

| Arm | home_s (n = 3) | mean |
|---|---|---|
| main-line behaviour (`YCODE_PORT_SLOT_HANDOFF=0`, no QoS) | 38.3, 32.6, 35.4 | 35.4 |
| slot hand-off (`mach-ipc.md` §2.9) | 34.7, 34.8, 39.5 | 36.4 |
| slot hand-off + `YCODE_SCHED_QOS=1 YCODE_HOST_SCHED=cgroup` | 32.7, 32.4, 32.5 (a profiled fourth: 32.9) | 32.5 |

With QoS and the cgroup backend the boot is 2.9 s (8 %) shorter on
average and its spread falls from 6 s to 0.3 s; every boot reached the
home screen, `guest_fatal` 2–4 in every arm. On the boot's backbone
(`boot-profile.md` §8.6) SpringBoard's host run-queue time falls from 3.9
to 1.4 s and diagnosticd's after its wakeups from 3.8 to 1.9 s; the senders
blocked on diagnosticd's queue wait 196 instead of 257–295 thread-seconds.
The cost moves partly to the kernel lock: SpringBoard's L0 waits on the
backbone grow from 1.5 to about 2.5–3 s (class changes, 48,880 per boot, are
recomputed under L0 when a fast path receives a message, §4.4; a lead for
the lock work).

A second series on the next build (series D, `YCODE_BOOT_PRIORITY=1`, which
sets the same two switches for a device run, against `=0`): on 31.7, 31.7
and **64.9 s**, off 35.0, 32.8, 35.8 s. The 64.9 s boot held the kernel
lock 41.2 s over its run (a normal boot 14.3 s) and its start hold released
20 jobs by the quiet test 2.1 s after their spawn (normal: by boosts). The
likely mechanism: a darwin-bg thread in the idle class (`cpu.idle`) that
takes L0 while the host is busy gets no CPU while it holds it, and every
other thread waits (a priority inversion; xnu's turnstiles push the
waiters' priority onto a lock owner, §2.4; Ycode's L0 is a plain mutex).
Over the seven boots with QoS and the backend the median is 32.5 s against
35.0 s for the nine without, but the outlier rules out a default: it stays
behind `YCODE_BOOT_PRIORITY=1` (or the two switches) until a holder of L0
runs at least at its waiters' class, or class 0 uses a small weight
instead of `cpu.idle`. Early quiet releases also occur without QoS (C-base
1 and 3, C-hand 3: 35.4–39.5 s, against 32.6–34.8 s without them): the
quiet test can pass in the first two seconds of a boot, while only
launchd_sim runs, and then starts the held jobs while the boot's busiest
phase begins.

## Evidence

| Claim | Level |
|---|---|
| On-demand starts held without the rule; icon timings with and without it (§4.2, §7.3) | 3 (Thor runs i2, a1–a3: `sched:` log lines, guest `log stream` of iconservicesagent, frames) |
| ProcessType values (§1) | 1 (launchd.plist(5)); 2 (the runtime's job plists, read as data) |
| Spawn attribute offsets, port action type 3 (§1) | 1 (`processes.md` §1.4, §1.8: xnu `spawn_internal.h`) |
| `MACH_SEND_NOIMPORTANCE` = 0x40000, `PRIO_DARWIN_*` values | 1 (xnu `osfmk/mach/message.h`, `bsd/sys/resource.h`) |
| Donor/receiver per type, darwin-bg rules, primordial QoS, MAXPRI_THROTTLE, bg I/O tier (§2.1, §2.2) | 1 (xnu `osfmk/kern/task_policy.c`: `proc_set_task_spawnpolicy`, `task_compute_main_thread_qos`, `task_policy_update_internal_locked`; fetched 2026-10-17) |
| Watch-port binding only for receivers, boost from the port's importance count (§2.3) | 1 (xnu `task_add_importance_watchport` in `task_policy.c`) |
| Importance into the receiving voucher (§2.3) | 1 (xnu `osfmk/ipc/ipc_importance.c`, as summarised in `service-fidelity.md` §7.2) |
| Turnstile pushes, sync IPC push (§2.4) | 1 (xnu turnstiles and special reply ports; `threads-and-events.md` §1.5, `mach-ipc.md` §4.2) |
| Clutch buckets, WCEL and warp values (§2.5) | 1 (xnu `doc/scheduler/sched_clutch_edge.md`) |
| Start delays, priorities, states, CPU (§3) | 3 (`ps` sampling of a throwaway device, 2026-10-17; deleted afterwards) |
| Thor arms (§7.1) | 3 (SX harness runs m1–m5, h1a, h3–h5, q8–q11; exit reports, guest `launchd.log` of h5) |
| Mac with the same device data (§7.2) | 3 (`ycode-test-prio-aged-1`, `-2`, 2026-10-19: `launchd.log` read as a format, `ps`; deleted afterwards) |
| Unprivileged cgroup v2 delegation and threaded children on the Thor (§4.7) | Linux cgroup-v2 documentation; tried on the Thor |
| Timed boots with and without QoS and the cgroup backend (§7.4) | 3 (Thor, `ide-remote/bootcp` series C: runs `C-base-*`, `C-hand-*`, `C-qos-*`, `C-prof-qos`; series D: `D-dflt-*`, `D-off-*`; exit reports: kernel-lock hold, start-hold releases) |
| Everything in §4–§6 | Ycode design |

No disassembly or decompilation was used (level 5 not used).
