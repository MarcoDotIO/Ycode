# Spec: scheduling policy (process types, darwin-bg, importance, thread QoS)

Status: **implemented** (2026-10-17). The start hold (§4.2) is **on by
default** since 2026-10-19 (§7). Thread QoS with the cgroup host backend
is **on by default for device runs** since 2026-10-27 (`YCODE_BOOT_PRIORITY`,
§4.7, §7.5); lock admission stays off, and outside device runs QoS and
host scheduling stay behind switches (§6). This spec answers
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
| the system is quiet: over the last `YCODE_ADAPTIVE_HOLD_WINDOW_MS` (default 2000 ms; a full window is needed) the kernel lock was held less than `YCODE_ADAPTIVE_HOLD_BUSY_PERCENT` (default 25 %) of the time **and the VMM used less than `YCODE_ADAPTIVE_HOLD_CPU_PERCENT` (default 25 %) of the host's online CPUs** (its process CPU time over the window), no guest thread had to wait for the kernel lock for `YCODE_ADAPTIVE_HOLD_QUIET_MS` (default 250 ms, the BG bucket's WCEL; with the admission gate of §4.5 only threads of class ≥ df count), and the hold is at least `QUIET_MS` old. All quiet holds are released together. | `quiet` |
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

The CPU fraction (added 2026-10-27, §7.5) makes it mean an idle host too.
Since most traps left the kernel lock (`bsd-locking.md`,
`mach-ipc-locking.md`), a boot's first seconds hold the lock 10–17 % of
the time while ~190 daemons' loaders keep 8–11 of the Thor's 14 CPUs busy,
so the lock tests alone passed about 2 s into a boot and released the
held jobs into its busiest phase (§7.4). The age of the last contention
is 0 when the contention was stamped after the sample time was read
(before, the wrapping difference made such a contention look ages old,
which also passed the test).

The quiet test is Ycode's stand-in for the Mac's mechanism: a darwin-bg
`xpcproxy_sim` gets CPU and I/O only when nothing above it needs them. In
Ycode the scarce resource is the kernel lock.

**Shell-ready holds** (added 2026-11-01, `visionos.md` §10.26.1). A job
whose label is in the system's shell-ready list stays held through boosts
and the quiet test until the shell is ready; then it starts at once
(reason `shell ready`); the bound (`timeout`) and `exit` still apply, and
later spawns of the job are held as usual. On a visionOS device run the
list is `com.apple.assistantd` (`YCODE_VISIONOS_SHELL_HOLD`: another
comma-separated list, `0` none), and `ycode-simd` marks the shell ready
when RealityLauncher runs or at the room's first lit frame. The release
line names the last boost that the hold outlived.

**The boost's source** (diagnostic, 2026-11-01): a release by `boost`
logs the sender's pid and name and the message id of the last importance
message queued for the held job (for example `from pid 145 apsd, message
id 473000`; `1999646836` is XPC's message id).

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

**Where the class is recomputed** (`YCODE_SCHED_CLASS_OFF_L0`, default on
since 2026-10-27). A thread's pushes (§4.6) and its stored class have a
leaf lock of their own (nothing is taken under it but the thread's
override table). A recomputation reads every input and stores the class
under that lock. It runs where the input changed: under L0, or on a fast
path (an event lock or the port lock held, L0 not) when the image's
process record is already cached (every image after its spawn policy;
otherwise it is deferred to L0 as before). The process inputs (type,
clamp, role, darwin-bg) change under L0 and are always followed by a
recomputation under L0; the leaf lock orders it after any fast one, so the
stored class reflects the last change. With QoS on, the ulock calls now
stay on their fast path (`bsd-locking.md` §5): their pushes are the
thread's leaf-lock state, not L0 state. Before this, every sync-IPC push
and its end, and every ulock call, took L0 when QoS was on.

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
  The sender's class is that of the trap's own thread (on a fast path, the
  fast path's thread; before 2026-10-27 it was read from L0's current
  holder, which on a fast path is another thread or none).
- **Send push** (`YCODE_SEND_PUSH`, default on with QoS; added
  2026-10-27). In xnu a sender that blocks because the destination's
  queue is full waits on the port's send turnstile, whose inheritor is
  the receiver side (the thread or workloop that services the port), so
  the blocked senders' priority goes to whoever drains the queue. Ycode:
  while a sender of class c waits for room on a port, the image that holds
  the port's receive right (when it blocks) has a *send push* of c: 16-bit
  counts per class on the image, raised before the wait and lowered after
  it, without any kernel lock. The image's host class (§4.7) is the
  highest of its threads' own class and its send push; the push is not a
  class input (§4.4), so it causes no recomputation. Not modelled: xnu
  pushes onto the servicing thread or workloop only, Ycode onto every
  thread of the receiving image (a superset; diagnosticd's threads all
  serve its log port); a push applies from the receiving thread's next
  trap end.

### 4.7 Host scheduling (`YCODE_HOST_SCHED`)

A guest thread runs on its own host thread (one vCPU, `stage4a-contract.md`
§5). After each trap, outside the lock, the host thread compares its *host
class* (its class, raised to its image's send push, §4.6) with the class
it last applied. A higher class is applied at once. A lower one is
applied only when it has lasted `YCODE_HOST_SCHED_DEMOTE_MS` (default
50 ms; checked at the thread's trap ends; 0: at once): classes go up and
down with every serviced request, and a move is not free (§7.5).

| Backend | bg | ut | df | ui | Needs |
|---|---|---|---|---|---|
| `nice` | 19 | 8 | 3 | 0 | RLIMIT_NICE ≥ 20 or CAP_SYS_NICE. A thread must be able to come back to 0. With RLIMIT_NICE 0 (the Thor), the backend reports that it is unavailable and stays off. |
| `cgroup` | weight `YCODE_HOST_SCHED_BG_WEIGHT` (default 5; `idle`: `cpu.idle` 1, as before 2026-10-27) | weight 25 | 100 | 400 | A delegated cgroup v2 with the cpu controller. The VMM makes four threaded children `ycode-class0…3` of its own cgroup. A thread moves itself with one write of `0` to the child's `cgroup.threads` (Linux moves the writer without the global threadgroup lock that a write of a thread id takes; `YCODE_HOST_SCHED_SELF_ZERO=0` writes the id). Without write access, the VMM first re-executes itself in place with `systemd-run --user --scope -p Delegate=yes`, which keeps the pid. |
| `none` | — | — | — | — | |

The default backend is `none` for the VMM in general and `cgroup` for a
device run (§6, `YCODE_BOOT_PRIORITY`).

**Background CPUs** (`YCODE_HOST_SCHED_BG_CPUS=N`, opt-in, added
2026-11-01): with a backend on, a host thread applying class bg also sets
its CPU affinity to the last N online CPUs, and any other class to all of
them, as the Mac runs background work on its efficiency cores (Apple's
public documentation on Apple silicon performance tuning, level 1).
`sched_setaffinity` is looked up at run time (glibc declares it only with
`_GNU_SOURCE`). One visionOS boot with N = 2 (`visionos.md` §10.26.1, `e1`)
did not move assistantd's start-up past the shell's; it stays off by
default.

**Lock holders** (`YCODE_LOCK_HOLDER_PROMOTION`, default on with a
backend; added 2026-10-27). xnu's turnstiles push the waiters' priority
onto the owner of a kernel lock (§2.4). Ycode's kernel locks (L0, the
event locks, the port lock) are host mutexes, and a holder in class bg
could be left without a CPU while it held one: every other thread then
waited (the 64.9 s boot of §7.4). Each lock publishes its holder (host
thread id, applied host class, the class a waiter raised it to, a
generation) in one atomic word at every acquisition, when a backend is on.
A thread that finds the lock taken waits up to
`YCODE_LOCK_PROMOTION_DELAY_US` (default 200 µs; holds are microseconds,
so a holder that keeps the lock this long is one the host does not run;
1000 µs left a wider spread, §7.5).
If it is still waiting and its host class c is above both the holder's
applied class h and any raise already made, it raises the holder
(compare-and-exchange on the word, so a later holder is never raised by
mistake), then waits on:

- `group` (default with the cgroup backend and a weighted class 0): the
  cgroup of class h gets the weight of class c until the holder lets go
  (one `cpu.weight` write, microseconds; counted per class, so the weight
  goes back when no raised holder of that class is left). Every thread of
  class h gains for the moment, not only the holder.
- `thread` (`YCODE_LOCK_HOLDER_PROMOTION=thread`, the `nice` backend, or
  class 0 idle): the holder's host thread is moved to class c. The holder
  keeps c as its applied class when it lets go, and its next trap end
  moves it back (after the demotion delay). A move of another thread by
  id takes Linux's global threadgroup lock: 9 ms on average during a boot
  (§7.5).

A holder lets go by exchanging the word for 0. If it was raised, it waits
for waiters still raising it (a counter around their exchange and write)
before it lowers the weight or records its class, so a raise never
lands after its undo. Holders that applied no class (host service threads,
a guest thread before its first trap returned) and raises to class bg are
skipped. A waiter in a condition wait that takes the mutex back
(`WaitQueue`) does not raise.

### 4.8 What is not modelled

- I/O throttling tiers, background sockets, the jetsam bands.
- Live-donor apps changing with their UI state. Apps are donors.
- Importance carried by vouchers past the end of the servicing episode,
  except a request's, which §4.11 ties to its reply right
  (`YCODE_REPLY_IMPORTANCE`).
- Transitive pushes outside synchronous IPC: a raised ulock owner or lock
  holder does not raise the holder of a lock it waits for, and a send push
  (§4.6) is not passed on. Chains of synchronous requests are modelled
  (§4.10), and with §4.12 a raised thread passes its class on to the
  request it waits on.
- The clutch scheduler's warp, quanta and per-cluster runqueues. Only the
  WCEL bounds are used.
- `getpriority` still answers as before.

### 4.9 The background band (`YCODE_BG_BAND`)

The reference: a darwin-bg thread (priority 4, §2.2) is runnable and gets
no CPU at all while every CPU is busy with higher-priority work; during a
boot dasd's threads waited so 17–113 s (`boot-profile.md` §19.3). The host
weights of §4.7 give a class-bg host thread a small share, never none.

Ycode's model (`BackgroundBand.swift`, a run gate in Ycode itself):

- **Runnable threads.** A guest thread counts as runnable, by its host class
  (class raised to the image's send push), from the end of a trap until it
  blocks in the kernel (`WaitQueue`) or its guest thread ends (the vCPU
  pool's run ends). A thread waiting for a kernel lock or for a host CPU
  counts: on xnu it would be running or on a run queue. Counts are 16-bit
  fields of one atomic word; each host thread changes only its own entry.
- **The gate.** At the end of every trap that resumes the thread (locked
  and fast paths, outside every kernel lock), a class-bg thread leaves its
  place and asks again: it goes on while fewer than `YCODE_BG_BAND_CPUS`
  (default: the host's online CPUs) threads are runnable, else it waits,
  first in, first out. A thread that blocks or changes class gives its place
  to the oldest waiter. A running background thread is thus preempted at
  its trap ends; one in a long stretch of guest code with no trap is not.
- **Background CPUs** (`YCODE_BG_BAND_BG_CPUS=N`, unset: no limit): at
  most N class-bg threads are runnable at once, as Apple silicon runs
  background work on its efficiency cores only (the reference Mac: 4 of
  14, `boot-profile.md` §19.1; Apple's public performance-tuning
  documentation, level 1).
- **Ease window** (`YCODE_BG_BAND_EASE_MS=N`, unset or 0: off; added
  2026-11-07, `boot-profile.md` §22): a free place goes to a class-bg
  thread only once the runnable threads *above* class bg have stayed below
  `YCODE_BG_BAND_CPUS` for N ms. On the reference a priority-4 thread runs
  when the boot's CPU burst eases (`boot-profile.md` §19.3: the host's
  load stays far above its CPU count until about home), not at every
  momentary dip, which Ycode's lower thread count produces often after the
  first 10 s. The burst is stamped whenever a thread above bg is counted
  with the CPUs full, or a background thread finds them full; background
  threads filling the places themselves do not stamp it (a first version
  counted them, and background threads then kept each other out: a boot
  stalled).
- **Leaving early.** A waiter leaves when its host class rises (a boost, a
  ulock or sync-IPC push, a send push: the class recomputation and
  `addSendPush` wake it), when its image ends or its Mach suspension gate
  closes, or after `YCODE_BG_BAND_MAX_MS` (default 60 000; 0 none), the
  starvation guard. Waiters also wake every 100 ms to check these.
- **Lock order.** The gate holds no kernel lock; its mutex is a leaf.

Statistics are part of the `sched:` report (waits, time, longest, how they
ended, runnable counts by class). `YCODE_BG_BAND_TRACE=<program>,…` prints
waits of 100 ms or more of the named programs; `YCODE_BG_BAND_SAMPLE_MS=N`
prints the runnable counts every N ms. Measurements: `boot-profile.md` §20.

### 4.10 The sync-wait push (`YCODE_SYNC_PUSH`)

The reference (xnu, level 1: `osfmk/ipc/ipc_port.c`, `osfmk/kern/turnstile.c`,
`osfmk/kern/task.c`): a synchronous request (a message with a send-once
reply right, sent by a thread that then waits for the reply) pushes the
sender's priority onto whoever will serve it as soon as it is queued. The
sender waits on its reply port's turnstile, which is linked to the
destination port's send turnstile; the send turnstile's inheritor is the
thread or workloop that services the port, or, for a launchd service port
given to a job at spawn as a watch port, the new job's main thread (task
watchports). Turnstiles chain, so the push follows waits on waits (A waits
on B, whose thread waits on C), up to a hop limit per update. §4.6 pushes
only once a thread has received the request; `boot-profile.md` §20.3 and
§20.7 found the missing part on the boot's critical path (a daemon's
background threads held at the band's gate while its client waited;
containermanagerd starting at the default class for lsd's query, where
the reference starts on-demand jobs at priority 46, §3).

Ycode (`SyncWaitPush.swift`; every structure below is guarded by the
port lock G, `mach-ipc-locking.md` §4.1, except the image's counts):

- **The request.** A send with `MACH_RCV_MSG` in the same call and a
  send-once reply right, to a port that is not a kernel object, gets a push
  record with its sender's class: the sender's host class (its class
  raised to its image's pushes, §4.7), so a pushed sender passes its push
  on. The message's §4.6 class is the same value.
- **Queued: the image that will receive it.** While the request is queued
  on a port, its class is credited to the port's *target image*: the image
  of the job the port was bound to as a watch port at spawn (any process
  type), while the receive right is still with the space that held it at
  that spawn (launchd_sim), in transit, or with the job itself; otherwise
  the image that holds the receive right. A port keeps its credited counts
  (16 bits per class) and the image it credited, and moves the credit when
  the target changes: at the next enqueue or dequeue on the port, when a
  spawn binds it as a watch port, and when the credited process execs (the
  image of `xpcproxy_sim` becomes the daemon's). A dying port drops its
  credit. An image's *sync-wait push* is the highest class credited to it.
- **Who it raises.** Every thread of the target image (as the send push
  does, §4.6: xnu pushes only the servicing thread or workloop, or the new
  job's main thread; Ycode does not know which thread will take the
  request, and an on-demand job's start runs on threads it has not made
  yet). The push enters the host class (§4.7) and the band (§4.9): a rise
  above bg wakes the image's waiters at the gate. It is not a class input
  (§4.4).
- **Received.** When a thread takes the request off the queue, the credit
  ends and the thread carries the request's current class as its sync-IPC
  push until the end of its servicing episode (§4.6).
- **The wait ends** with the sender's trap (reply received, or the receive
  failed, timed out or was interrupted), or with the thread's end: a credit
  still in place is removed. A request that stays queued then pushes
  nothing.
- **Chains.** When an image's sync-wait push changes, each request a thread
  of that image waits on is re-evaluated: its class becomes the class it
  was sent with, raised to the sending thread's host class now. A queued
  request moves its credit by the difference (which may change the next
  image's push, and so on); a received one raises the serving thread's
  push (a fall waits for the end of its episode) and, if that thread waits
  on a request of its own, raises that one in turn. A change travels at
  most `YCODE_SYNC_PUSH_DEPTH` hops (default 8); further hops are counted
  and dropped. A cycle (two images waiting on each other's threads) can
  keep a raise until one of the requests is answered.
- **Lock order.** Everything runs under G; a class refresh of a serving
  thread takes its leaf push lock (or is deferred to L0 on a fast path,
  §4.4); the band's mutex is a leaf. No new lock.

**On-demand starts** (`YCODE_DEMAND_START_PUSH=<class>`, with the push
on; unset: off). §3: jobs that launchd starts because a client already
sent to them run at priority 46 (the user-interactive band) while they
start, whatever the client's own class; the push above gives such a job
only the class of the synchronous requests waiting on its port. With the
switch, a watch port that holds a message when a spawn binds it also
credits the given class to the job's image (`ui` models the reference's
46) until the job has served its first request: when a thread of the job
takes the first message off that port, the push leaves the port and stays
on the job's image until that thread's servicing episode ends (§4.3: its
next receive, its return to the workqueue, or its end); it also ends when
the job is gone. Until then it travels with the port's credit (the exec of
`xpcproxy_sim`, the check-in), and it is passed on along chains like a
request. (A first version ended it when the message was taken: a daemon
whose clients ask asynchronously, as lsd asks containermanagerd, then
served the request at its own class, darwin-bg, behind the band's gate;
`boot-profile.md` §21.) **Timed form** (`YCODE_DEMAND_START_MS=N`): the
job's image runs at the class for N ms from the spawn instead (carried
over its exec; a deadline in the image read at each trap end), whatever
its threads do meanwhile: an XPC daemon hands a request from the thread
that receives it to a dispatch queue, so the servicing episode of §4.3
ends before the request is served (xnu carries the importance on the
work item's voucher, which §4.8 does not model).

Switches: `YCODE_SYNC_PUSH=1` (with `YCODE_SCHED_QOS`),
`YCODE_DEMAND_START_PUSH`; `YCODE_SYNC_PUSH_TRACE=<program>,…` prints
each request from or to a listed program when it is queued, its credit
moved, or received (with the time it was queued). Measurements in
`boot-profile.md` §21: the push works as described but gains nothing (the
two waits it was meant for are asynchronous XPC requests, not synchronous
ones), and the on-demand forms make the boot slower (more work before
home); all stay off by default.

### 4.11 Asynchronous requests (`YCODE_REPLY_IMPORTANCE`, `YCODE_ASYNC_QOS`)

The reference (xnu, level 1; behaviour read from the open-source
`osfmk/ipc/ipc_importance.c`, `ipc_kmsg.c`, `ipc_pset.c` and
`osfmk/kern/thread_policy.c`, `task_policy.c`; nothing copied). An XPC
client that sends with a reply handler does not wait in the kernel, so
neither §4.6 nor §4.10 applies (`boot-profile.md` §21.3). Two other
mechanisms carry its priority to the server:

1. **Importance on the voucher.** A message that carries importance
   boosts the receiving task while it is queued (§4.3). A receiver that
   asks for the message's voucher (`MACH_RCV_VOUCHER`; libdispatch does for
   every dispatch_mach channel, so every XPC connection) gets the boost
   moved into a new voucher (`ipc_importance_receive`). The task stays
   boosted while that voucher lives: libdispatch keeps it with the received
   message and with each work item made while it is adopted, so the boost
   outlives the receiving thread's servicing episode and lasts until the
   request has been handled. An unboosted Adaptive daemon is darwin-bg
   (§2.2); xnu lifts a darwin-bg thread of an Adaptive task above that
   clamp only for a synchronous waiter's turnstile push (`thread_policy.c`,
   "promote above task"), never for a QoS override. So importance is what
   lets such a daemon serve an asynchronous request outside the background
   band.
2. **The message's QoS.** At send a message gets a priority (the sending
   work item's, from the voucher's pthread-priority attribute, or the
   `MACH_SEND_OVERRIDE` argument in its encoded `mach_msg_priority_t` form)
   and an override QoS (that priority's QoS, raised to the override
   argument's). Each queued message raises the override of the messages
   ahead of it, so the head carries the queue's highest. An EVFILT_MACHPORT
   knote that receives the message (`MACH_RCV_MSG`) adjusts its event QoS
   to the head's override: the workloop's thread request asks for that
   QoS, and a thread already servicing the workloop is overridden to it,
   until the queue drains. The delivered event carries `(priority << 32) |
   override` in `ext[2]`, and libdispatch runs the handler at that
   priority. Only that workloop or thread is raised, not the receiving
   task's other threads.

Ycode has no voucher objects (`host_create_mach_voucher` answers 0), so
both are modelled without them:

- **Request importance** (`YCODE_REPLY_IMPORTANCE=1`, `ReplyImportance.swift`).
  When a thread of an importance receiver takes a message that carries
  importance and a send-once reply right, the boost (§4.3) is tied to that
  reply right in the receiving space instead of to the thread: it lasts
  until the right leaves that space (the reply is sent with it, it is
  deallocated, moved on in a message, or the space ends), the reply port
  dies, or the process ends. The reply right stands for the voucher's life:
  an XPC server answers through it when the request has been handled, and
  destroys it if it never answers. A message without a send-once reply
  keeps §4.3's rule (the boost ends with the servicing episode). The
  boosts are per right (a port keeps the boosts of the rights to it, each
  with the space that holds it); a right sent on does not take the boost
  with it. Port-lock (G) state, as the rest of §4.3.
- **Message QoS** (`YCODE_ASYNC_QOS=1`, with `YCODE_SCHED_QOS`;
  `AsyncQoS.swift`). The send records the message's priority and override
  as xnu does, with the sending thread's requested QoS (§4.4 step 1) in
  place of the voucher's priority. A port's queue keeps the count of its
  messages per override QoS; its highest is the head's override. A
  workloop's thread request (§4.4 step 1: the bound thread's base QoS)
  takes the highest of its deliverable knotes' QoS and, for machport knotes
  with `MACH_RCV_MSG`, their queues' overrides; a message queued while a
  thread services the workloop raises that thread's *kevent override*
  (§4.4 step 2, cleared with its next request). `ext[2]` of a delivered
  machport event carries the message's priority and the override. Not
  modelled: the kqworkq buckets' overrides (their QoS stays the knote's).
  The special reply port's sync IPC push is §4.12.

Neither lifts a darwin-bg thread by itself (§2.2): the first ends darwin-bg
by boosting the process, the second only raises QoS within the classes the
process may use, as in xnu.

Diagnostics: `YCODE_IMPORTANCE_TRACE=<program>,…` prints each user message
to a listed program (sender, donor or not, importance, the port accepting
it or not, the reply), each request boost tied to a reply right and its end
(answered or the right gone, after N ms), and each change of a listed
program between boosted and darwin-bg. The `sched:` report adds `request
boosts N (answered N, dropped N, held N; mean N ms, longest N ms)`.

### 4.12 The reply push (`YCODE_REPLY_PUSH`)

The reference (xnu, level 1; behaviour read from the open-source
`osfmk/ipc/ipc_port.c` special reply port linkage, `osfmk/kern/turnstile.c`
and `osfmk/kern/thread_policy.c`, and libdispatch's synchronous send in
`src/mach.c`; nothing copied). A thread that sends a request and waits for its
reply pushes its priority onto whoever holds the request for as long as it
waits. libdispatch does a synchronous send (every
`xpc_connection_send_message_with_reply_sync`) in two calls: a send whose
reply is a send-once right to the thread's special reply port
(`thread_get_special_reply_port`), then a receive on that port with
`MACH_RCV_SYNC_WAIT` naming the destination. The kernel links the special
reply port's turnstile to the destination's send turnstile while the request
is queued, and, once a thread or a workloop has received it, to that
receiver, until the reply goes back through the send-once right or the right
is destroyed. A turnstile push lifts a darwin-bg or background-QoS thread
above its throttle ("promote above task", §4.11). §4.6 and §4.10 cover only
the one-call form (`MACH_RCV_MSG` in the sending call), and only until the
receiving thread's servicing episode ends; an XPC daemon hands the request
to a queue and serves it after that episode. `boot-profile.md` §24.1:
SpringBoard's main thread waits in the two-call form on runningboardd, whose
serving thread runs at class bg (its work's QoS, not darwin-bg) and waits at
the band's gate (§4.9) for most of the wait.

Ycode (`ReplyPush.swift`, under the port lock G):

- **The two-call form.** A send without `MACH_RCV_MSG` whose reply right is
  a send-once right to the sending thread's own special reply port gets a
  push record as a one-call request does (§4.10: the sender's host class).
  The thread keeps it until a receive with `MACH_RCV_SYNC_WAIT` on that port
  returns (the reply came, or the receive failed or timed out), its next
  such send, or its end.
- **Queued**: the record credits the image that will receive the request
  (§4.10), for both forms (§4.10's queued credit is made for every request
  when either switch is on).
- **Held until the reply.** When a thread takes the request (either form),
  besides §4.6's push on that thread for its episode, the record is tied to
  the send-once reply right in the receiving space until the right leaves
  that space (it is sent as the reply's destination or deallocated; the
  space ends), the reply port dies, or the sender's wait ends, whichever
  comes first. While held it pushes, as xnu's turnstile does, **the workloop
  the request came through**: a thread that took it while servicing a
  workloop (a kevent delivery, the workloop's event lock held) puts it on
  that workloop, and whichever thread services the workloop carries it (it
  is part of the thread's pushes, §4.4 step 6, from its bind to its unbind),
  so the handler that libdispatch runs later on the workloop is pushed and
  the image's other threads are not. A request taken otherwise (a plain
  receive) pushes the thread that took it until the reply.
  `YCODE_REPLY_PUSH=image` pushes the whole receiving image instead (§4.10's
  image credit); `boot-profile.md` §24.4: that form brings unrelated work
  forward and slows the boot.
- **Moved on.** A reply right moved on as the reply right of another message
  (libdispatch's resend of a pseudo-received request) takes the push with
  it: queued with that message, held again where it is received. A right
  moved in a message body ends it.
- **Chains** (§4.10): a change of the sender's class moves a held push both
  ways; a serving thread that sends a request of its own passes its class,
  held pushes included, on. **A change of a waiting thread's own class** (a
  ulock push, a boost, a QoS change, a held push) re-evaluates the request it
  waits on (xnu's turnstile chain through a lock owner into its request);
  before, only a change of an image's push did (§4.8).
- **Lock order**: G only, as §4.10; the band's mutex is a leaf.

Diagnostics: the `sched:` report adds `reply pushes: special-reply requests
N, held N (on workloops N) (answered N, right gone N, wait ended N, moved on
N; mean N ms, longest N ms)`; with `YCODE_SYNC_PUSH_TRACE` each hold (and
what it pushes) and its release. Measurements: `boot-profile.md` §24.

### 4.13 Ports in transit and watch ports (`YCODE_TRANSIT_PUSH`, `YCODE_WATCH_PUSH`)

The reference (xnu, level 1; behaviour read from the open-source
`osfmk/ipc/ipc_port.c`, the send turnstile's inheritor and the importance
delta of a port, and `osfmk/ipc/ipc_importance.c`; nothing copied). While
the receive right of a port travels inside a message queued on another port,
the first port is *in transit* and the second is its destination. A
synchronous request queued on a port in transit pushes the destination's send
turnstile, so whoever will receive the carrying message is pushed; the
importance of the messages queued on it goes down the same chain of
destinations to the task that holds (or, as a watch port, is bound to) the
last one. An XPC client opens a connection by sending a new port's receive
right in its first message to the service's listener and sends its requests
to that port at once: until the server takes the first message, every
request waits on a port in transit. A launchd service port given to a job at
spawn (task watchports, §2.3) pushes the job's main thread.

Ycode before (`boot-profile.md` §25.2): a port in transit had no target
(§4.10's target and §4.3's credit look at the space holding the receive
right), so such a request pushed nobody and its importance boosted nobody;
and with the reply push alone (the device default, `YCODE_SYNC_PUSH` off) no
spawn bound the job's watch ports for the queued credit, so a request queued
on a service port before the job checked in pushed launchd_sim.

- **Transit** (`YCODE_TRANSIT_PUSH=1`, `TransitPush.swift`, under the port
  lock G). A port whose receive right is in transit (the port whose queue
  holds the carrying message is known) and that is no job's watch port takes
  the target of that port, following such ports at most
  `YCODE_SYNC_PUSH_DEPTH` hops: for the sync-wait credit (§4.10, §4.12's
  queued credit: the receiving image) and for importance (§4.3). The credit
  moves when the right goes into transit (the carrying message is queued),
  when it lands in a space (copied out), and when a spawn binds the carrying
  port as a watch port. Not modelled: other changes of the carrying port's
  own target (its receive right moving) reach the ports in transit in its
  queue only at their next enqueue, dequeue or copy-out.
- **Watch ports** (`YCODE_WATCH_PUSH=1`). With the reply push on, a spawn
  binds the job's watch ports for the queued credit and an exec moves the
  old image's credits to the new one, as with `YCODE_SYNC_PUSH` (§4.10).

Diagnostics: the `sched:` report adds `transit credits N` (credits moved to a
target through a port in transit); with `YCODE_SYNC_PUSH_TRACE` a request
queued on a port in transit says so (`the port in transit to <program>`).
Measurements: `boot-profile.md` §25.

### 4.14 The hand-off push (`YCODE_HANDOFF_PUSH`)

The reference (libdispatch, level 1; behaviour read from the open-source
`src/queue.c`, `src/inline_internal.h`, `src/event/event_kevent.c`,
`src/voucher.c`; nothing copied). `dispatch_async` captures with the work
item the dispatching thread's priority (for an XPC handler, the request's
priority from its kevent, §4.11) and its voucher (the request's importance).
Pushing the item onto a queue that a workloop drains pokes that workloop with
a thread request at the item's QoS (`EVFILT_WORKLOOP`,
`NOTE_WL_THREAD_REQUEST`); the thread bound to the workloop runs the item at
that priority with the voucher adopted, so its task stays boosted. A request
taken on one workloop and handed to a queue of another is therefore served
at the class its sender pushed. Ycode has no vouchers and no work items: a
thread's turnstile pushes (§4.6, §4.12) are not part of the QoS its process
asks for, so a handler running under a held push hands its work to a thread
request at its own QoS, and the thread that runs it waits at the band's gate
while the sender waits (`boot-profile.md` §24.6, `tr-rpe5`).

Ycode (`HandoffPush.swift`, under the image's event lock; the thread's push
lock is a leaf):

- When a thread that carries a push (§4.6's sync-IPC push, §4.12's held
  pushes, its own or its workloop's, or a hand-off push of its own) makes a
  workloop thread request (new, or with its QoS updated) on a workloop of its
  image other than the one it services, the workloop keeps the highest such
  class above bg as its *hand-off push*.
- The thread that next services that workloop carries it from its bind to its
  unbind (the item's drain), and so does the one servicing it at that moment,
  if any. It is one of the thread's pushes (§4.4 step 6), above darwin-bg like
  the push it came from.
- `YCODE_HANDOFF_PUSH=held` carries only held reply pushes (§4.12), not a
  sync-IPC push or a hand-off push of the dispatching thread's own, so
  hand-offs do not chain.
- Not modelled: hand-offs through the workqueue's own buckets
  (`workq_kernreturn` thread requests, dispatch overrides), and a hand-off
  that outlives the drain.

Diagnostics: `hand-off pushes N (taken N)` in the `sched:` report; with
`YCODE_SYNC_PUSH_TRACE` a line for each hand-off and each servicer that takes
one. Measurements: `boot-profile.md` §25 (slower at the band default in both forms).

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
  still held; not held on demand N), ms held; class changes (recomputations
  without L0); importance: receiving ports, temporary owners, importance
  messages, donor sends to other ports; send pushes; lock admission: gate
  waits, ms, at the bound; host scheduling …; moves, failures, ms moving
  (moves of another thread, ms), demotions put off; lock holders promoted
  (waits past the delay, let go raised; class weight writes, ms)`; with
  §4.10 on, `send pushes N; sync-wait pushes N (moved N, chain updates N,
  depth stops N, ended queued N)` (requests that pushed, credits moved to a
  new target, requests re-evaluated along chains, changes stopped at the
  bound, waits that ended with the request still queued).
- With `YCODE_HOME_WATCH=1`, after the home line: `ycode-simd: home watch:
  at home: kernel lock held N ms (N acquisitions); sched: …` (the exit
  report's counters at the home screen; the A/B instrument of §7.5).

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
| `YCODE_ADAPTIVE_HOLD_CPU_PERCENT` | 25 | §4.2: the VMM's CPU use over the window, in % of the host's online CPUs; `0` drops the test |
| `YCODE_SCHED_QOS` | 0 | §4.3–§4.6, and §4.7 when a backend is chosen |
| `YCODE_SCHED_CLASS_OFF_L0` | 1 | §4.4 recomputation on fast paths, ulock calls on their fast path with QoS; `0` as before |
| `YCODE_SEND_PUSH` | 1 | §4.6 send push (with QoS); `0` off |
| `YCODE_LOCK_ADMISSION` | 0 | §4.5 (with `YCODE_SCHED_QOS`) |
| `YCODE_LOCK_ADMISSION_BOUND_MS` | `250,150,75` | §4.5 bounds for bg, ut, df |
| `YCODE_HOST_SCHED` | none | `nice`, `cgroup` (§4.7) |
| `YCODE_HOST_SCHED_BG_WEIGHT` | 5 | class 0's `cpu.weight` (1–10000), or `idle` for `cpu.idle` (§4.7) |
| `YCODE_HOST_SCHED_DEMOTE_MS` | 50 | §4.7 demotion delay; `0` at once |
| `YCODE_HOST_SCHED_BG_CPUS` | unset | §4.7: class bg host threads on the last N online CPUs |
| `YCODE_VISIONOS_SHELL_HOLD` | `com.apple.assistantd` (visionOS device runs) | §4.2 shell-ready holds; a comma-separated list, `0` none |
| `YCODE_HOST_SCHED_SELF_ZERO` | 1 | §4.7: a thread moves itself by writing `0`; `0` writes its id |
| `YCODE_LOCK_HOLDER_PROMOTION` | `group` | §4.7 lock holders: `group`, `thread`, `0` (off) |
| `YCODE_LOCK_PROMOTION_DELAY_US` | 200 | §4.7: a waiter raises the holder after waiting this long |
| `YCODE_LOCK_WITHDRAW_AFTER_UNLOCK` | 1 | §4.7: a raised holder waits for the waiters still raising it, and lowers its class weight, after it releases the mutex (`boot-profile.md` §12.3); `0` as before (waits while it still holds the lock) |
| `YCODE_FAST_TRAP_HOST_CLASS` | 0 | §4.7 host class at the end of fast traps (IPC, BSD descriptor, task-local): `1` the whole class, `push` only a raise to the image's send push; off by default (`boot-profile.md` §12.3) |
| `YCODE_HOST_SCHED_UI_CPUS` | unset | host threads of the UI-path programs run on every online CPU, every other guest thread's host thread on all but the last N (`boot-profile.md` §12.3) |
| `YCODE_HOST_SCHED_UI_PROGRAMS` | `SpringBoard,backboardd` | the UI-path programs (executable names) for `YCODE_HOST_SCHED_UI_CPUS` |
| `YCODE_BG_BAND` | 1 for `--device` runs (since 2026-11-07), else 0 | §4.9 the background band (with `YCODE_SCHED_QOS`) |
| `YCODE_BG_BAND_CPUS` | online CPUs | §4.9 runnable threads before a background thread waits |
| `YCODE_BG_BAND_BG_CPUS` | unset | §4.9 the most class-bg threads runnable at once |
| `YCODE_BG_BAND_EASE_MS` | unset | §4.9 a free place goes to a background thread only after the threads above bg stayed below the CPU count this long |
| `YCODE_BG_BAND_MAX_MS` | 60000 | §4.9 the longest one wait; 0 none |
| `YCODE_BG_BAND_TRACE`, `YCODE_BG_BAND_SAMPLE_MS` | unset | §4.9 diagnostics |
| `YCODE_SYNC_PUSH` | 0 | §4.10 the sync-wait push (with `YCODE_SCHED_QOS`); `1` on |
| `YCODE_SYNC_PUSH_DEPTH` | 8 | §4.10 the most hops a change travels along a chain |
| `YCODE_DEMAND_START_PUSH` | unset | §4.10 on-demand starts pushed at this class (`bg`, `ut`, `df`, `ui`) until their first request is served |
| `YCODE_DEMAND_START_MS` | unset | §4.10 the timed form of the on-demand start push: N ms from the spawn |
| `YCODE_SYNC_PUSH_TRACE` | unset | §4.10 trace lines for the listed programs |
| `YCODE_REPLY_IMPORTANCE` | 0 | §4.11 a request's importance lasts until its reply right leaves the receiving space; `1` on |
| `YCODE_ASYNC_QOS` | 0 | §4.11 a queued message's QoS overrides the workloop that drains its port, and its event's `ext[2]` carries it (with `YCODE_SCHED_QOS`); `1` on |
| `YCODE_IMPORTANCE_TRACE` | unset | §4.11 trace lines for the listed programs |
| `YCODE_REPLY_PUSH` | 1 for `--device` runs (since 2026-11-07), else 0 | §4.12 a waiting sender's request pushes whoever holds it until the reply (queued: the receiving image; received: the workloop it came through, else the thread that took it), in both the one-call and libdispatch's two-call form (with `YCODE_SCHED_QOS`); `1` on, `image` on with the whole receiving image pushed |
| `YCODE_TRANSIT_PUSH` | 1 for `--device` runs (since 2026-11-07), else 0 | §4.13 a request or importance queued on a port in transit credits the target of the port that carries it; `1` on |
| `YCODE_WATCH_PUSH` | 1 for `--device` runs (since 2026-11-07), else 0 | §4.13 with the reply push alone, spawns bind watch ports for the queued credit (and execs move it); `1` on |
| `YCODE_HANDOFF_PUSH` | 0 | §4.14 a pushed thread's workloop thread request carries its push to the workloop's next servicer for its drain (with `YCODE_SCHED_QOS`); `1` on, `held` only held reply pushes |
| `YCODE_HOST_SCHED_UI_PUSHED` | unset | with `YCODE_HOST_SCHED_UI_CPUS`: an image whose send push (§4.6) is at least this class also runs on the UI path's CPUs while it lasts |
| `YCODE_BOOT_PRIORITY` | 1 for device runs (since 2026-10-27; was 0) | device runs (`--device`) only: with `YCODE_SCHED_QOS` unset, set it to 1 and `YCODE_HOST_SCHED` (if unset) to `cgroup` before the VMM starts (§7.4, §7.5); `0` turns it off. The cgroup backend re-executes the VMM in a delegated user scope only when the user's service manager is reachable (`$XDG_RUNTIME_DIR/systemd/private`); otherwise it reports itself unavailable and the run goes on without host scheduling |

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
phase begins. Both are addressed in §4.2, §4.7 and measured in §7.5.

### 7.5 Holder promotion, the quiet test's CPU condition, defaults (agent PRIO-3, 2026-10-27)

Thor, `SX/bin/timed.sh` around each series (no other ycode-simd, load
under 4 at the start), unprofiled cold boots of one device copy booted
before at its own path (`ide-remote/prio3`, `YCODE_HOME_WATCH`), arms
rotated each round, 5 s held after home. *main* is the main line 229b8b2
with the one-line link fix of this branch (the main line did not link on
arm64 Linux), default switches. *off* is this branch with
`YCODE_BOOT_PRIORITY=0` (the start hold's new quiet test, no QoS); *new*
is this branch's defaults (boot priority on: QoS, cgroup backend, class 0
weight 5, holder promotion by class weight after 200 µs, send push,
classes off L0). Kernel lock: L0's hold over the whole run (home + 5 s +
stop), from the exit summary; "at home" from the home-watch line (§5).

**Final series D** (the default build against the main line, n = 9 each):

| Arm | median home_s | range | worst | boots > 33 s | L0 held, median / max | L0 at home |
|---|---|---|---|---|---|---|
| main | 35.42 | 31.45–41.10 | 41.10 | 6 | 6.13 / 7.91 s | — |
| off (`YCODE_BOOT_PRIORITY=0`) | 31.21 | 30.41–34.73 | 34.73 | 2 | 5.92 / 6.32 s | 4.2–5.0 s |
| **new (defaults)** | **30.14** | **29.62–33.01** | **33.01** | 1 (33.01) | 6.91 / 7.72 s | 5.1–6.0 s |

**All series pooled** (A–D; the arms that ran the same configuration):

| Configuration | n | median | range | > 33 s | L0 held median / p90 / max |
|---|---|---|---|---|---|
| main | 27 | 34.24 | 29.77–47.05 | 17 | 6.09 / 7.22 / **22.50** s |
| main + `YCODE_BOOT_PRIORITY=1` (QoS before this change: class 0 `cpu.idle`, no promotion, ulock on L0; series C) | 9 | 32.65 | 30.44–37.02 | 4 | 9.61 / 10.53 / 12.17 s |
| off | 32 | 30.95 | 29.77–34.73 | 8 | 5.89 / 6.31 / 6.39 s |
| new, promotion after 1000 µs (A, B) | 14 | 30.91 | 29.61–32.60 | 0 | 7.30 / 7.77 / 8.22 s |
| **new, promotion after 200 µs (B, C, D; the default)** | 23 | **30.44** | 29.27–33.01 | 1 | 7.09 / 7.60 / 8.22 s |
| new with class 0 weight 25 (B) | 5 | 32.66 | 29.52–36.62 | 2 | 7.22 / – / 8.36 s |

Reading:

- **The outlier class is gone.** The main line's slow boots have two
  causes, both visible in its logs. (1) The quiet test released 14–24
  held jobs before the home screen in 10 of its 18 boots of series C and
  D, in two of them 3.2 and 5.1 s after their spawn (homes 39.5 and
  37.3 s); those 10 boots took 34.5–41.1 s, the other 8 30.3–33.6 s (the
  two over 33 s with eligibilityd's boost, below). (2) One boot of series
  A (47.05 s, no QoS) held L0 for 22.5 s. With the CPU condition no boot
  of this branch released a held job by the quiet test before the home
  screen (0 of 78, series A–D and four trial boots), and L0's hold stayed
  within 5.3–8.4 s in every boot of series A–D (QoS or not). The
  QoS-specific outlier of §7.4 (an idle-class holder) did not recur in 42
  boots with QoS and promotion; the old QoS
  arm held L0 9.0–12.2 s per run (380–450 k acquisitions: with QoS every
  ulock call and every push change took L0) against 6.6–8.2 s
  (120–180 k) now.
- **Boot priority helps a little and narrows the tail**: 30.44 s median
  pooled against 30.95 s off (−0.5 s), 1 boot of 23 over 33 s against 8 of
  32. The remaining slow mode in both arms is eligibilityd, released by a
  boost 15–18 s into the boot (it then runs its start-up in the busy
  phase): every boot over 32.7 s in series D of either arm had it, and
  only those. Against the main line the change is −5.3 s median in series
  D (−3.8 s pooled), mostly the quiet test.
- **The cost of QoS moved**: L0 is held 1.2 s more per run than off, not
  analysed further (likely: the darwin-bg flips of §4.3 recompute every
  thread of the image under L0, and a holder in a low class that is
  preempted before a waiter raises it adds that time to the hold).
  Promotion after 200 µs: 1,700–2,400 holders raised by the home screen
  (about 23 k waits past 200 µs and 2,150 raises per run), 4,000
  `cpu.weight` writes per run, 150–170 ms in all. Class changes 46–50 k per run, 200–210 k recomputations on fast
  paths without L0; 28 k blocked sends pushed onto their receiver.
- **Host moves**: the old backend made 9,110 moves in a run (C-oldprio-1).
  Now about 2,900 per run (the demotion delay puts off 1,500–2,300), 2.6 s
  in all. Moving another thread by id averaged 8.7 ms during a boot (774
  holder moves, 6.7 s, in a test run with `YCODE_LOCK_HOLDER_PROMOTION=thread`):
  Linux takes its global threadgroup lock for it. A thread moving itself
  (writing `0`) costs about 1 ms during a boot and 4 µs on an idle host;
  a `cpu.weight` write about 40 µs during a boot. Hence promotion by class
  weight.
- Class 0 weight 25 instead of 5 was slower (5 boots, 32.66 s median).

Debug suites with `YCODE_LOCK_ORDER_CHECK=1 YCODE_IPC_LOCKS_TESTS=1` on
the Thor: kernel 370 tests, simd 43, ABI 154, all passed; full `swift
build && swift test` on the x86-64 workstation passed.

Functional checks with the defaults (QoS and the cgroup backend on): six
cold boots that launched Settings (3) and Safari (3) through ylaunch 20 s
after home, all launched (open request 0.7–2.5 s), on a host that other
agents' boots loaded to 40–170 (homes 36–119 s); and, in `timed.sh`, a cold
boot (home 34.5 s) with a snapshot at 75 s, then two lazy restores of it
(home 6.2 and 5.3 s) that launched Safari and Settings (open requests
2.0 s each; Settings drawn in the last frame). No host crash, no
lock-order report; the guest's fatal conditions were the known
fileindexerd and intelligencetasksd crashes (`service-fidelity.md` §11,
§7.2 above).

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
| Boots of §7.5: home times, kernel-lock holds, quiet releases, eligibilityd's boost, promotion and move counters | 3 (Thor, `ide-remote/prio3` series A–D: `ab-*.txt`, run logs' home-watch and exit lines) |
| Cost of cgroup moves by thread id, by `0`, and of `cpu.weight` writes (§4.7, §7.5) | Linux cgroup-v2 documentation and kernel source (the `cgroup.threads` write path skips the threadgroup lock for the writer itself); timed on the Thor (`prio3/probes/cgcost.py`, idle host) and in boots (exit counters) |
| Send turnstile: blocked senders push onto the receiver side (§4.6) | 1 (xnu `osfmk/ipc/ipc_port.c` send turnstile and its inheritor, `osfmk/kern/turnstile.c`) |
| Timed boots with and without QoS and the cgroup backend (§7.4) | 3 (Thor, `ide-remote/bootcp` series C: runs `C-base-*`, `C-hand-*`, `C-qos-*`, `C-prof-qos`; series D: `D-dflt-*`, `D-off-*`; exit reports: kernel-lock hold, start-hold releases) |
| Sync requests push their destination's servicer from the moment they are queued, through the reply port's link to the send turnstile; watch ports push the spawned job's main thread; turnstile chains are bounded per update (§4.10) | 1 (xnu `osfmk/ipc/ipc_port.c`: send turnstile inheritor, special reply port linkage, watchport elements; `osfmk/kern/turnstile.c`; `osfmk/kern/task.c`, as open source) |
| Everything in §4–§6 | Ycode design |
| Shell-ready holds; the boost's source; background CPUs (§4.2, §4.7) | Ycode design; `SchedPolicyTests.shellReadyHoldWaitsForTheShell`; Thor boots of `visionos.md` §10.26 |
| Importance moved into the receiving voucher with `MACH_RCV_VOUCHER`, dropped otherwise; a darwin-bg Adaptive thread lifted only by a turnstile promotion (§4.11) | 1 (xnu `osfmk/ipc/ipc_importance.c` `ipc_importance_receive`; `osfmk/kern/thread_policy.c` "promote above task", `task_policy.c` adaptive darwin-bg) |
| A message's priority and override at send, the override raised towards the queue's head, the machport knote's event QoS and `ext[2]` (§4.11) | 1 (xnu `osfmk/ipc/ipc_kmsg.c` `ipc_kmsg_set_qos`, `ipc_kmsg_enqueue`; `osfmk/ipc/ipc_pset.c` `filt_machport_adjust_qos`, `filt_machportprocess`; `osfmk/mach/message.h` `mach_msg_priority_t`) |
| Request importance, message QoS and the ease window in boots (§4.9, §4.11) | 3 (Thor, `boot-profile.md` §22: series X1, X2, trace boots `tr1-*`, profiles) |
| libdispatch's synchronous send in two calls (special reply port, then `MACH_RCV_SYNC_WAIT`); the special reply port's turnstile linked to the destination while queued and to the receiving thread or workloop until the reply; a turnstile push promoting a throttled thread (§4.12) | 1 (xnu `osfmk/ipc/ipc_port.c` special reply port linkage, `osfmk/kern/turnstile.c`, `osfmk/kern/thread_policy.c`; libdispatch `src/mach.c`, as open source) and 3 (the options of SpringBoard's sends and receives in Ycode's own frame profiles, `boot-profile.md` §24.1) |
| The reply push in boots: the edge list, series Z1, Z3, Z4 (§4.12) | 3 (Thor, `boot-profile.md` §24) |

No disassembly or decompilation was used (level 5 not used).
