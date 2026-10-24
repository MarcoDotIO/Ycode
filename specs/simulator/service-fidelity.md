# Spec: service fidelity in the full boot

Status: **partly implemented** (agent SVC, 2026-10-17): §3.2 and §4 are implemented; §7 is an observation, not implemented. Agent SVC4 (2026-10-17): §10 implemented; §11 and §12 are findings (no Ycode change: the FSEvents protocol is private; the restart loops follow from the device's state and the start order). The lean boot
(`lean-boot.md`) makes a boot cheaper by not starting 23 services. This spec
is about the **full** boot (`YCODE_LEAN_BOOT` unset). It compares each
service that the lean profile disables, and two more (`replicatord`,
`intelligencetasksd`'s crash loop), with the same service in the Mac's
simulator. When Ycode differs, it gives the cause. When the cause is a
Ycode defect, it gives the fix. A service that crashes or restarts on the
Mac too is **kept that way**: that is parity, not a defect.

Terms are as in `launchd-sim.md` and `lean-boot.md` (RR, DEV, TMP).

## 1. Method

**Mac (black box, level 3).** A throwaway device `ycode-test-svc-*` of the
same runtime (iOS 27.1, 24A94401), same device type (iPhone19,4). The first
boot is ended 90 s after `simctl bootstatus`. The second boot is measured,
as the Ycode benchmark boots a device that was booted once before. Sources:

- `TMP/launchd.log`, read as a file format: spawn reasons, exits, launchd's
  throttle lines, the time from "xpcproxy_sim spawned" to the job's
  `INIT` event.
- `ps -A -o pid,ppid,stat,time,etime,command` every ~10 s for every
  descendant of the device's `launchd_sim` (CPU seconds per process).
- `xcrun simctl spawn <dev> log show` for one process's messages.
- Crash reports in `~/Library/Logs/DiagnosticReports` (name, time and
  device only).

**Ycode (level 3).** Full boots on the Thor with the SX harness
(`bench.sh`, device in RAM), the exit summary (per image: traps, how it
ended), `TMP/launchd.log`, and trace runs (`--trace-name <process>`).

## 2. Process identity

logd attributes a message to a process by the main executable's UUID.
Ycode reported a zero UUID, so `log` showed `00000000-…[pid]` and
`<compose failure>` for every format string in a main executable. Ycode
now reports the main executable's `LC_UUID` in `proc_pidinfo`
(`PROC_PIDUNIQIDENTIFIERINFO`, `PROC_PIDT_BSDINFOWITHUNIQID`),
`proc_pid_rusage` (`ri_uuid`) and `LOCAL_PEERUUID`; a zombie keeps it
(`processes.md`, Evidence table).

## 3. How a crash ends a process, and how Ycode reports it

### 3.1 The signal

A fatal hardware exception ends the process with the signal that the arm64
Darwin kernel gives it (`processes.md` §2.3.1). A Swift runtime trap is a
BRK, so it ends with SIGTRAP. On the Mac, launchd logs it as "exited due
to SIGTRAP | sent by exc handler[pid]" (the crash reporter's exception
handler sends it). Ycode has no exception handler process and logs
"exited due to SIGTRAP". Before 2026-10-17, Ycode ended every such process
with SIGSEGV.

### 3.2 One report per process (Ycode)

The other threads of a dying process stop at their next trap. Before
2026-10-17, each of these threads printed a full "fatal guest condition"
report with the faulting thread's registers, so one crash gave 2 to 7
reports. Now only the first thread that reports prints the report (a
Darwin crash report also names one crashed thread). With `--trace`, each
other thread prints one line: "… ends with the process (fatal condition
already reported)".

The harness metric `guest_fatal` counts report lines. It now counts
crashed processes. Before the change it counted crashed threads (44 in a
full boot for 17 crashed processes).

## 4. `renameatx_np` flags

The flags are from xnu `bsd/sys/stdio.h`. `renameatx_np` refuses any other
bit and the combination EXCL|SWAP with EINVAL (xnu
`bsd/vfs/vfs_syscalls.c`, `renameatx_np`).

| Flag | Value | Effect | Ycode |
|---|---|---|---|
| `RENAME_SECLUDE` | 0x01 | passed to the file system | accepted, no effect |
| `RENAME_SWAP` | 0x02 | exchange two existing names | yes |
| `RENAME_EXCL` | 0x04 | EEXIST if the target exists | yes |
| `RENAME_RESERVED1` | 0x08 | — | EINVAL |
| `RENAME_NOFOLLOW_ANY` | 0x10 | no symbolic link is followed in any component of either name; a link that would be followed → ELOOP (`NAMEI_NOFOLLOW_ANY`) | yes (since 2026-10-17) |
| `RENAME_RESOLVE_BENEATH` | 0x20 | both names must stay below their directory descriptors (ENOTCAPABLE) | **not implemented: EINVAL** (no caller seen) |

The final component of a name is never followed by a rename, with or
without the flag.

**Why it matters (searchd).** searchd saves its index state with
`renameatx_np(… tmp.spotlight.state.tmp, … tmp.spotlight.state,
RENAME_NOFOLLOW_ANY)` in `DEV/data/Library/Spotlight/CoreSpotlight/
index.spotlightV2`. Ycode returned EINVAL. searchd logged
"SpotlightIndex.c:2654: sync index error 3, 2, 22", wrote
`mds64-crash-state-v2`, logged "###_SIReopenCallback: Exiting …" and called
`exit(0)` 15–40 s after its start. launchd started it again on the next
lookup. That was 40–45 searchd processes in each full boot. On the Mac,
one searchd runs for the whole boot.

**What the fix uncovers (open).** With the rename accepted, searchd gets
further, and so do its clients (runs a2, tr4):

- searchd stops after about 190 s (SIGSEGV, a deliberate write to address
  0xbad) after logging "_MDPlistContainer.c:646: failed assertion
  'object.reference.embeddedReference >= collectionBufferOffset'". The
  last message before it is a CoreSpotlight donation (`com.apple.mobilenotes`).
  **Settled (agent SVC4): a Ycode defect**, shared file views that did
  not follow the file's size (§10). Fixed.
- fileindexerd (KeepAlive) now gets past its wait for searchd. It looks up
  `com.apple.FSEvents` (a per-pid lookup), which fails with "Unknown
  service name (1102)". It logs "failed to subscribe to events in
  <GroupContainers>/… with POSIX 19", then stops in a Swift fatal error
  ("Failed to init after preparing dependencies: … Code=19"), and launchd
  starts it again every ~17 s. In the Mac's simulator `com.apple.FSEvents`
  is the host's file-event service, and fileindexerd runs for the whole
  boot. Ycode has no host FSEvents service (the protocol is not public).
  Before the fix fileindexerd waited for searchd for the whole boot,
  so it did not crash. What it needs and why Ycode keeps the name absent:
  §11.

## 5. Crash loops and launchd's throttle (parity)

launchd_sim is guest code and Ycode runs it unchanged, so its restart
policy is the Mac's. Observed on the Mac (`launchd.log`, level 3) and the
same in Ycode:

- A job that ends is not started again sooner than 10 s after its last
  start ("Service only ran for N seconds. Pushing respawn out by 10 − N
  seconds"), or the plist's `ThrottleInterval`.
- A job that crashes logs "service has crashed N times in a row". From
  about the 12th crash in a row the delay doubles each time ("Exponential
  throttling is in effect for 19 … 38 … 76 … 157 … 316 … seconds") up to
  1200 s. The count lasts for the life of launchd_sim, so it starts again
  at every boot.

Jobs that end and are started again at the 10 s rate **on the Mac too**
(TMP/launchd.log of a Mac device that ran for 14 h: 400–550 exits per
95-minute log file, about one every 10.3 s): `proactiveeventtrackerd`
(exit 1), `mlhostd`, `pairedsyncd` ("pairing store path was nil"),
`facetimemessagestored` (exit 0). Ycode: 56–62 of each in 600 s (mlhostd
28–34). This is parity.

### 5.1 intelligencetasksd

intelligencetasksd starts for a `com.apple.bg.system.task` launch event
(dasd's background-task scheduler; its plist asks for a post-install task
with `ScheduleAfter` 300 s and four daily maintenance tasks). It stops
in the XPC Swift overlay. The crash annotation is "PeerRequirement.swift:13:
Fatal error: API Misuse | XPC Peer Requirement isn't implemented on
simulators yet". The task is not done, so the event stays pending, and
launchd starts the job again after each throttle delay.

**The Mac does the same.** In a second boot, the first crash came at +457 s
(when dasd ran the task). Then it crashed every 10 s, 11 times, and then at
18 s, 40 s, … The 14-hour Mac device was at "crashed 56 times in a row",
once every 1200 s. Two other Mac devices showed the same.
In Ycode the dasd task of the benchmark device is already overdue, so the
loop starts at about +235 s: 16 crashes per 600 s, on the same schedule.

Result: **kept as is (parity).** Since 2026-10-17 Ycode's signal is the
Mac's, SIGTRAP, not SIGSEGV (§3.1). One crash costs Ycode about
3,300 traps and one spawn (about 53 k traps per boot, 0.2 % of all traps).

## 6. replicatord: the abort at boot

**Ycode.** In every full boot, the first replicatord (RunAtLoad, KeepAlive,
`POSIXSpawnType` Adaptive) aborts once, about 40 s after its start. The
last message it logs is "CoreAnimation: Unable to query displays from
server (-81182718)". Before that, IDS reports "XPC has informed us that a
fatal error has occured" (the Mac logs that line too). launchd starts it
again ("inefficient"). The second instance runs until the end. Trace
(runs tr1, tr2):

1. replicatord sends request id 40231 to `com.apple.CARenderServer`. The
   port is still held by launchd, so the message waits in its queue.
2. backboardd checks in `com.apple.CARenderServer`. Its server thread
   receives the queued message as seqno 0. It answers with a 36-byte
   error reply.
3. backboardd's own request (seqno 1) and every later client's request
   (seqno 7, 9, 11, …, among them the second replicatord) get a 56-byte
   reply with one descriptor, which is success.

So a request that waits in the queue from before backboardd's check-in is
refused, and replicatord aborts on that refusal. Ycode's message trailer
for the queued message carries the sender's identity from send time
(`processes.md` §4.5), and the second replicatord succeeds with the same
identity. The refusal follows from the order of events, not from what the
message contains.

**Mac.** No replicatord abort (no "exited due to SIGABRT" in any
launchd.log; only the SIGKILL at shutdown). In the second boot,
backboardd reaches `INIT` 0.29 s after its spawn. replicatord reaches it
9.93 s after its spawn (§7). Its query then comes after backboardd's
check-in.

**Cause: the Mac holds Adaptive jobs at the start (§7). Ycode did not.**
Result: **fixed by the start hold** (`scheduling-policy.md` §4.2, on by
default since 2026-10-19). replicatord is held until a client's message
boosts it (11–25 s on the Thor, 9–13 s on the Mac); its query then comes
after backboardd's check-in, it starts once and does not abort, in every
hold run (`scheduling-policy.md` §7).

## 7. The start of Adaptive jobs (implemented: `scheduling-policy.md`)

### 7.1 Observation (Mac, level 3)

The Mac's second boot: the time from "xpcproxy_sim spawned" to `INIT`,
for the jobs that launchd started in the first 0.1 s (speculative, at load,
event publisher), with the plist's `POSIXSpawnType`/`ProcessType`:

| Type | Jobs (delay to INIT) |
|---|---|
| Interactive | backboardd 0.29 s, SpringBoard (App) 0.24, logd 0.30, mobiletimerd 0.25, identityservicesd 0.38, locationd 0.29, sharingd 0.28, sleepd 0.24, notifyd 0.25, configd_sim 0.28, rapportd 0.23, dasd 0.23 |
| Adaptive | runningboardd 3.9 s, routined 5.7, tccd 9.3, biomed 9.3, replicatord 9.9, appprotectiond 10.1, passd 10.7, mediaremoted 11.1, assistantd 11.4, amsaccountsd 19.0, remindd 19.2, axassetsd 31.7, ManagedSettingsAgent 51.4, healthd 136, deviceconfigurationd 167, fileindexerd 169, wcd 169, navd 169, revisiond 170, peopled 170, nanoprefsyncd 171, parsecd 172 |
| Adaptive, started later by a Mach lookup | cfprefsd 0.11 s, lsd 0.02, containermanagerd 0.02, nanoregistryd 0.02, triald 0.44 |

While a job waits, `ps` shows `xpcproxy_sim <label>` in state `U`
(uninterruptible wait) with 0.00–0.02 s of CPU. This lasted 10–170 s even
while the whole simulator used less than 2 s of CPU per 10 s. The same is
seen for later starts of Adaptive jobs (`mlhostd`, `intelligencetasksd`,
`proactiveeventtrackerd`: 24–70 s in `U`).

In Ycode, every one of these jobs reaches `INIT` 0.7–2.4 s after its
spawn, whatever its type.

### 7.2 Interpretation and status

xnu (level 1, `osfmk/kern/task_policy.c`, `osfmk/ipc/ipc_importance.c`):
a task spawned as `POSIX_SPAWN_PROC_TYPE_DAEMON_ADAPTIVE` is background
(`DARWIN_BG`: lowest CPU priority band, throttled I/O) until it is
*boosted*. A boost comes with an importance-carrying Mach message from a
task that donates importance (an interactive or boosted task), and it lasts
while that message's importance is held. At spawn, launchd passes the
job's service ports as importance-watch ports (a spawn port action); the
new adaptive task takes one boost for each of them that already has queued
messages (`task_policy.c`, port watch). So a job that launchd starts because
of a lookup is boosted from its first instruction. A job started speculatively waits
until a client talks to it or the host's throttle lets its I/O run. On the
Mac host the waiting `xpcproxy_sim` is the host process of that job, so the
host kernel's background policy applies to it.

Ycode records the spawn's process type (`processes.md` §1.6) and does not
apply it. All jobs run at once and at the same priority. Effects in the
full boot: replicatord's abort (§6); parsecd, axassetsd, healthd and the
other held jobs run from the first second and compete with the boot for
the kernel lock (parsecd 2.2 M, axassetsd 1.2–1.4 M traps per boot, against
less than 2 s of CPU on the Mac).

A faithful fix needs background policy and importance donation in the
Mach IPC and the scheduler (stage 6 kernel lock, vCPU threads). **Done**
in `scheduling-policy.md` (importance §4.3, the start hold §4.2, on by
default). Measured (§7 there): the Mac and Ycode hold the same jobs and
release them in the same order; parsecd and axassetsd are held on both
(Mac 1.6–2.8 s with this device's data, Ycode 6–52 s, scaled with the
boot).

## 8. Audit of the lean-disabled services (full boot)

Mac: second boot of a throwaway device; CPU in the first ~2 min and over
600 s, whether it is still running. Ycode: full boot, 600–700 s, per run:
processes (images), traps, how they ended (runs b1, b2, c1; 29800d7 and
its parent).

| Service | Mac | Ycode (before) | Cause | Fixed? |
|---|---|---|---|---|
| suggestd | 1 process, ~1.0 s by 2 min, 1.4 s in 600 s, idle | 1 process, 4.1–4.4 M traps (worker loop) | workqueue (other agent) | no (recorded) |
| parsecd | Adaptive, held 172 s; 0.2 s by 2 min, 1.7 s in 600 s | 1, 2.1–2.2 M traps from the start | workqueue loop (other agent); no Adaptive hold (§7) | no |
| parsec-fbf | first boot only, 0.4 s | not started | — | parity |
| searchd | 1 process for the whole boot, 1.4 s by 2 min, 21 s in 15 min | 40–49 processes, each `exit(0)` after 15–40 s | `RENAME_NOFOLLOW_ANY` refused (§4) | **yes** (now 11 processes; a later `_MDPlistContainer` assertion, §4, open) |
| spotlightknowledged | starts late, 0.4 s | 1, 8 k traps | — | parity |
| spotlightknowledged.updater | 0.6–1.8 s | 1, 27–53 k | — | parity |
| axassetsd | Adaptive, held 32 s; 0.4–0.5 s by 2 min | 1, 1.2–1.4 M traps | workqueue loop (other agent); no hold (§7) | no |
| proactiveeventtrackerd | exit(1) every ~10 s | 58–61 processes, exit 1 | runtime behavior, launchd throttle (§5) | parity |
| mlhostd | exit(0) every ~10 s | 28–34, exit 0 | same | parity |
| intelligencetasksd | SIGTRAP loop, 10 s then exponential (§5.1) | 16 crashes (SIGSEGV before 29800d7, SIGTRAP now) | runtime: "XPC Peer Requirement isn't implemented on simulators yet" | parity (signal fixed) |
| intelligenceplatformd | 7.5 s (first boot), ~1 s later | 1, 14–19 k | — | parity |
| knowledgeconstructiond | 0.6 s | 1, 10–19 k | — | parity |
| textunderstandingd | 0.7 s | 1, 9 k | — | parity |
| siriactionsd | 3.1–4.0 s by 2 min | 1, 31–34 k | — | parity |
| siriinferenced | 0.8–0.9 s by 2 min | 1, 27–28 k | — | parity |
| siriknowledged | 0.5–0.9 s | 1, 19–20 k | — | parity |
| mediaanalysisd | starts late, 0.6 s | 1, 10–12 k | — | parity |
| photoanalysisd | 2.0 s by 2 min | 1, 6 k | — | parity |
| sensorkitd | 0.3 s | 1, 151–161 k, still running | not examined | open |
| nanoregistrylaunchd | 0.2–0.7 s | 1, 3 k | — | parity |
| pairedsyncd | exit(0) every ~10 s | 58–62, exit 0 | runtime, throttle (§5) | parity |
| facetimemessagestored | exit(0) every ~10 s | 56–59, exit 0 | same | parity |
| homed | 2.6–3.0 s by 2 min, running | 1, 0.44–0.54 M, running | not examined | open |
| *replicatord* (not on the list) | no crash | SIGABRT once at boot | no Adaptive hold (§6, §7) | no |
| *fileindexerd* (not on the list) | 1 process for the whole boot | before: waits for searchd, no crash; after the searchd fix: 16 SIGTRAP crashes per 700 s | no host `com.apple.FSEvents` (§4) | open |

## 9. Measurements

Thor, SX harness, device in RAM (`BENCH_TMPFS=1`), full boot, 2026-10-17
18:54–20:30, interleaved with other agents' boots. Before: 29800d7. After:
this change (rename flags, one report per process). Traps, processes and
crashes come from the 700 s runs (`BENCH_NOKILL=1 BENCH_SECS=700`).

| | Runs | home_s | Mean | Traps per 700 s (M) | Crashed processes | searchd processes | fileindexerd crashes |
|---|---|---|---|---|---|---|---|
| before | c1, c2, c3, c4 | 525, 470, 500, 440 | 484 | 22.6 (c1), 26.8 (c4) | 17 (16 intelligencetasksd, 1 replicatord) | 45, 49 | 0 |
| after | a1, a2, a3 | 420, 445, 455 | 440 | 25.0 (a3) | 41 (16 intelligencetasksd, 16 fileindexerd, 8 searchd, 1 replicatord) | 11 | 16 |

- The home screen came 44 s sooner on average. That is within the
  run-to-run noise (440–525 s for one unchanged build), so it is not
  established.
- searchd now runs as on the Mac until the assertion of §4. The
  crashes it uncovers (fileindexerd, searchd's own) are listed in §4 and
  §8. They are Ycode gaps that were hidden before, not new defects of
  the change.
- `guest_fatal` (harness): before 38–49 report lines (one per thread);
  after 31–33 (one per crashed process, §3.2), although more processes
  crash.
- Two later runs (c5, a4, 21:00–21:12) are discarded: the data drive was
  full and their logs are empty.

## 10. Shared file mappings follow the file's size (searchd)

**Darwin (level 1: mmap(2), ftruncate(2); xnu `bsd/kern/kern_mman.c`
and the unified buffer cache).** A `MAP_SHARED` mapping of a file is a
view of the file's pages. It may be longer than the file: a page wholly
past the end faults while it stays past the end, and once the file grows
over it (`ftruncate`, a `write` past the end) the page shows the file and
writes through it reach the file. A page that a truncation cuts away
faults again, and its bytes are gone. A `MAP_SHARED`, `PROT_READ` mapping
of a descriptor open read-only is a view too: it sees later writes made
through any other descriptor or mapping of the file.

**Ycode before (`home-screen.md`, coherent mappings).** A view covered the
host file's pages that lay inside the file *when the mapping was made*;
the rest were private zero pages for good. A mapping of a read-only
descriptor, or one starting at or past the end, was a private copy.

**What it broke (level 3: Ycode trace `SVC3/tr4`, runs `base1`, `fx1`).**
SpotlightIndex (searchd) creates index files small and maps them large:
`ftruncate(fd, 0x4000)`, then `mmap(1 MiB, PROT_READ|PROT_WRITE,
MAP_SHARED|MAP_FIXED, fd)`, and grows the files later. It maps others
read-only (`MAP_SHARED|MAP_NOCACHE`, `PROT_READ`, 1 MiB and 64 MiB) while
it writes them through a second descriptor: 45 such mappings per searchd
were private copies. What searchd wrote past the first 16 KiB of a map
file stayed in private pages and never reached the file, and its readers
saw stale copies. searchd logged "db2_add_field_with_cache:14411: … Field
name out of bounds" or "_MDPlistContainer.c:646: failed assertion
'object.reference.embeddedReference >= collectionBufferOffset'" and
crashed (SIGSEGV), 4–10 times per 700 s run; each new searchd read the
broken files again and crashed 8–16 s after its start.

**Data or defect: a defect.** On the Mac, a throwaway device given the
Ycode benchmark device's data (§12.1) ran 4 searchd processes in 700 s,
3 ending with `exit(0)` (idle) and none crashing. With the change below a
Ycode full boot runs **one searchd for the whole boot** (run `sv2`: it
ends at the harness's shutdown after 682 s; no assertion, no "out of
bounds").

**Ycode now.** A shared file view keeps its own host descriptor of the
file and is registered by the file's (device, inode). After every change
of a file's size made through Ycode (a write that may end past the end,
`ftruncate`, `truncate`, an open with `O_TRUNC` of an existing file),
every view of that file follows: pages the file now covers become views
of the file (host `mmap` `MAP_SHARED|MAP_FIXED` over the zero pages; the
KVM memory slot follows through the host's MMU notifiers), and pages past
the new end become zero pages again (Darwin would fault; zeros are the
lenient answer, and a host access cannot raise SIGBUS). A view may start
at or past the end (no file pages yet). A `PROT_READ` `MAP_SHARED`
mapping of a read-only descriptor of a file under a writable prefix is a
view too: the host opens the file again for reading and writing for the
mapping (Linux, `/proc/self/fd`). Files of the read-only runtime keep
private copies. Leniencies that remain: the zero pages past the end
accept writes (Darwin faults), and `mprotect` to writable of a read-only
descriptor's view is not refused (Darwin: EACCES).

Tests: `SharedFileViewTests.viewsFollowTheFileWhenItGrows`,
`viewsFollowTheFileWhenItShrinks`, `readOnlyViewsSeeLaterWrites`.

## 11. fileindexerd and the host's `com.apple.FSEvents`

**What fileindexerd uses (level 3: Ycode trace `SVC3/tr4`, guest log).**
At its start it calls the public FSEvents API of CoreServices (FSEvents.h,
level 1): `FSEventsCopyUUIDForDevice` and `FSEventsGetCurrentEventId`.
Each first connects to the file-event service, a per-pid lookup of
`com.apple.FSEvents` through launchd_sim, which Ycode answers "Unknown
service name (1102)" (guest log: "FSEventsCopyUUIDForDevice: ERROR:
FSEvents_connect() => Unknown service name (1102)"). No system call of
fileindexerd fails after that. It logs "failed to subscribe to events in
<GroupContainers>/… with NSError: POSIX 19 'Operation not supported by
device'" and stops in "FileIndexerDaemon.swift:638: Fatal error: Failed
to init after preparing dependencies: … Code=19" (SIGTRAP). The public
documentation lets `FSEventsCopyUUIDForDevice` return NULL (no UUID for
the device), so ENODEV is fileindexerd's own reading of that answer.
launchd (KeepAlive) starts it again: 16 crashes per 700 s (10 s, then the
exponential throttle of §5).

**The minimal behaviour it would need.** A host service under
`com.apple.FSEvents` that answers the device-UUID and current-event-id
requests and accepts an event-stream subscription for a directory (the
group container), with change events later. On the Mac it is the host's
fseventsd (the guest's paths are host paths there). On the Mac, with the
same device data (§12.1), fileindexerd started once and ran for the
whole 700 s.

**Why Ycode does not provide it.** The messages between the FSEvents
client library and fseventsd are a private MIG protocol. No Apple open
source or public document describes them (xnu publishes only
`/dev/fsevents`, the kernel side that fseventsd reads; searched
2026-10-17), and the replies cannot be observed black-box from the guest
or on the Mac without tracing Apple's processes. A server would mean
guessing reply layouts until the client accepts them; that is not a
specification. **Fallback (kept): the name stays absent.** That is what
the Mac's simulator itself does for a host name with no host service:
the host registration looks each name up in the host's bootstrap and
skips those it lacks (`launchd-sim.md` §6.3), so the guest's lookup fails
with 1102, as on Ycode. It is safe: one crash costs about 5 k traps and
one spawn, the throttle bounds the loop, and no other job changes.
Revisit when the protocol is public or documented by permitted open
source.

## 12. The four restart loops of the parity ladder (`parity-ladder.md` §3.3)

### 12.1 Method: the Mac with the Ycode device's data

The ladder compared Ycode's benchmark device with **new** Mac devices,
booted twice within minutes of their creation. Ycode's device is a copy
of a golden device first booted on 2026-10-13, four days before. To
compare like with like, a throwaway Mac device (`ycode-test-svc4-aged-1`,
iPhone Duo, iOS 27.1, deleted afterwards) got, before its first boot,
the `DEV/data` directory of Ycode run `base1` (the golden device after
one more Ycode boot), was booted for 700 s, and its `TMP/launchd.log`,
crash reports and `log show` output were read (level 3). Its log store
also holds the Ycode run's own guest messages (the guest's logd wrote
them into `DEV/data`), which `log show` on the Mac prints; the Ycode-side
messages below were read that way.

| Starts in 700 s | Mac, new device (`parity-ladder.md` §3.3) | **Mac, Ycode's device data** | Ycode `base1` (before §10) | Ycode `sv2` (after §10) |
|---|---|---|---|---|
| proactiveeventtrackerd (exit 1) | 0, 0 | **42** | 61 | 60 |
| facetimemessagestored (exit 0) | 0, 0 | **41** | 64 | 62 |
| pairedsyncd (exit 0) | 1, 1 | **1** | 64 | 62 |
| searchd | 1, 1 | **4** (3 × exit 0, no crash) | 5 (4 × SIGSEGV) | **1** (whole boot) |
| fileindexerd | — | **1** (whole boot) | 16 (crashes, §11) | 16 |
| mlhostd (exit 0) | 52, 55 | 28 | 41 | 43 |
| intelligencetasksd (crash) | 15, 15 | 15 (15 crash reports) | 16 | 16 |

### 12.2 proactiveeventtrackerd and facetimemessagestored: the device's state (parity)

Both start only for maintenance work (job plists read as data, level 2):
proactiveeventtrackerd for two `com.apple.xpc.activity` jobs (`Interval`
43200 and 86400 s), facetimemessagestored for two
`com.apple.bg.system.task` tasks (`Interval` 86400 s) and an XPC
activity. On a new device none is due within 700 s. On a device whose
last run of them is older than their interval they are due at once; the
process ends without doing them, and launchd starts it again after the
throttle. With Ycode's device data the Mac loops too (42 and 41 starts,
from 13 s after boot). proactiveeventtrackerd ends the same way on both
(guest log: passwd entry not found, "Failed to initialize the tracker",
"Failed to initialize PET service. Exiting..." → `exit(1)`).
**Not a Ycode defect.** The Mac restarted them every ~14 s, Ycode every
~10–11 s. Remeasured on 2026-10-19 (`scheduling-policy.md` §7.2, macOS
27.2, same runtime, a less loaded Mac): the Mac restarts both, and
mlhostd, every 10.2–10.8 s, not held (each restart is boosted by its XPC
event), 68–69 starts in 700 s; Ycode with the hold 56–66. The 42 and 41
above were the loaded Mac's rate, not a hold. Detail: the passwd message differs ("User passwd
entry or home directory is not found" on the Mac, "Failed to get user
passwd entry: [2] No such file or directory" on Ycode: Ycode's
`getpwuid` failure leaves errno ENOENT); recorded, not examined.

### 12.3 pairedsyncd: the order of two starts (Adaptive hold)

pairedsyncd ends by itself on both platforms ("Fatal error: pairing store
path was nil for PSDFileManager." → `exit(0)`). Whether it starts again
depends on a message waiting on its Mach service port:

- **Mac** (Ycode's data): locationd looks up
  `com.apple.pairedsyncd.syncstate` 6 s after boot, while the job is
  still disabled ("failed lookup … error = 3: No such process" in
  `launchd.log`), so no message is sent. nanoregistrylaunchd starts at
  +80 s ("ipc (mach)") and enables pairedsyncd at +146 s; pairedsyncd
  starts once (speculative), exits, and nothing waits for it.
- **Ycode**: nanoregistrylaunchd starts at +20 s and enables pairedsyncd
  at +22 s; locationd's lookup comes at +43 s and succeeds, and its XPC
  connection sends a message to the port. pairedsyncd exits before it
  receives anything, the message stays queued, and launchd starts the job
  again ("launching: ipc (mach)") after every throttle delay: 62–64
  starts.

The guest code behaves the same; the order of two events differs. The
Mac starts nanoregistrylaunchd late (for a lookup by a job that is still
held) and runs locationd's start quickly; Ycode starts every job at once
and runs locationd's start 7 × slower (§7). Ycode's Mach semantics are
right: a message nobody receives stays queued and keeps the demand on the
port. **The remedy is the Adaptive hold of §7**, part of the scheduling
work (agent PRIO); no change here.

**Result (2026-10-19):** with the start hold (`scheduling-policy.md` §4.2,
on by default) pairedsyncd starts **once** in every Ycode hold run (8
runs of 2026-10-19; held 24–69 s, released by the quiet test together
with the companion group that nanoregistrylaunchd enables), as on the Mac
(1 start, not held), against 65–66 without the hold. No client's message
released it (no importance message was queued on its port), and launchd
did not start it again after its exit.

### 12.4 searchd

A Ycode defect, fixed (§10).

## Evidence

| Claim | Level |
|---|---|
| Mac service CPU, process counts, still running (§8) | 3 (`ps` samples of throwaway devices, 2026-10-17) |
| Mac restart and throttle lines, crash counts, spawn-to-INIT delays, `U` state (§5, §7.1) | 3 (`TMP/launchd.log` read as a format; `ps -o stat`) |
| intelligencetasksd launch events and dasd tasks (§5.1) | 2 (RR job plist read as data); 3 (Mac `log show` of dasd, launchd.log) |
| intelligencetasksd crash annotation (§5.1) | 3 (Ycode fault report: the libraries' crash annotation strings) |
| replicatord message sequence (§6) | 3 (Ycode trace runs tr1, tr2: message ids, sizes, seqnos, ports) |
| replicatord on the Mac (§6) | 3 (`log show`, launchd.log) |
| renameatx_np flags and checks, NOFOLLOW_ANY → ELOOP (§4) | 1 (xnu `main` fetched 2026-10-17: `bsd/sys/stdio.h`, `bsd/vfs/vfs_syscalls.c` `renameatx_np`/`renameat_internal`, `bsd/vfs/vfs_lookup.c` `ni_loopcnt = MAXSYMLINKS` for `NAMEI_NOFOLLOW_ANY`) |
| searchd's rename call and exit (§4) | 3 (Ycode trace run tr3) |
| Adaptive daemons are background until boosted (§7.2) | 1 (xnu `osfmk/kern/task_policy.c`, `osfmk/ipc/ipc_importance.c`) |
| replicatord, pairedsyncd and the restart loops with the start hold; the Mac remeasured (§6, §7.2, §12.2, §12.3) | 3 (`scheduling-policy.md` §7: Thor runs, Mac devices `ycode-test-prio-aged-1`, `-2`) |
| launchd process types of the jobs (§7.1) | 2 (RR job plists read as data) |
| One report per process (§3.2), `guest_fatal` meaning | 3 (Ycode logs); Ycode design |
| fileindexerd's FSEvents lookup and fatal error; searchd's assertion (§4) | 3 (Ycode trace run tr4, run a2: log message strings, crash annotations) |
| Boot times, traps, crash counts (§9) | 3 (Ycode boots on the Thor, exit summaries, launchd.log) |
| Darwin shared-mapping semantics past the end and for read-only descriptors (§10) | 1 (mmap(2), ftruncate(2); xnu `bsd/kern/kern_mman.c`) |
| searchd's mapping pattern and failure messages (§10) | 3 (Ycode trace `SVC3/tr4`; guest log read with `log show`) |
| searchd on the Mac with Ycode's device data; Ycode after the change (§10, §12.1) | 3 (Mac device `ycode-test-svc4-aged-1`, its `launchd.log`; Ycode runs `base1`, `fx1`, `sv1`, `sv2`) |
| fileindexerd's FSEvents calls and failure (§11) | 3 (Ycode trace, guest log); 1 (public FSEvents.h API) |
| The FSEvents client protocol is not public (§11) | 1 (Apple open source and documentation searched, 2026-10-17) |
| Restart counts with the same device data on both platforms (§12) | 3 (`launchd.log` on both); 2 (job plists read as data) |
| locationd / nanoregistrylaunchd order (§12.3) | 3 (`launchd.log` and guest log on both platforms) |

No disassembly or decompilation was used (level 5 not used).
