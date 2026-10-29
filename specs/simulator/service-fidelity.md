# Spec: service fidelity in the full boot

Status: **partly implemented** (agent SVC, 2026-10-17): §3.2 and §4 are implemented; §7 is an observation, not implemented. Agent SVC4 (2026-10-17): §10 implemented; §11 and §12 are findings (no Ycode change: the FSEvents protocol is private; the restart loops follow from the device's state and the start order). Agent SVC-FULL (2026-10-27): §13 (the full boot of the main line, now the IDE default) and the open questions of §11 and §13; no Ycode change. Agent OBS-FSEVENTS (2026-10-27, dirty room): answers to Q11.1–Q11.3 (the protocol is now `fsevents-host.md`), Q13.1 and Q13.2, and new open questions for Ycode in §11 and §13.1. Agent FS-HOST (2026-10-28, clean room): §11 implemented (the data volume's capabilities and the host's `com.apple.FSEvents`; fileindexerd starts once) and the Ycode answer of §13.1. Agent THREAD-SUSPEND (2026-10-28): §14 (amsengagementd and assistantd no longer crash: real Mach thread suspension and a workqueue fix). The lean boot
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
| `RENAME_SWAP` | 0x02 | exchange two existing names | yes (atomic: Linux `renameat2(RENAME_EXCHANGE)`, since 2026-10-27) |
| `RENAME_EXCL` | 0x04 | EEXIST if the target exists | yes (atomic: `renameat2(RENAME_NOREPLACE)`, since 2026-10-27; `file-system-features.md` §6) |
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
source. **Superseded (2026-10-27):** the protocol is now specified from
black-box observation (level 3) in `fsevents-host.md`; see the answers
below.

**Still the case on 2026-10-27 (agent SVC-FULL).** In full boots of the
main line (5f74ef9, `parity-ladder.md` §4.8) fileindexerd crashes 16 times
in 700 s (three runs) (each run lasts 2.6–136 s by `launchd.log`, the first ones the
longest: held at the start, under host load; from the 12th crash the
exponential throttle of §5), with the same fatal error and the
same failed lookup (`launchd.log`: "failed lookup: name =
com.apple.FSEvents, flags = 0x9, requestor = fileindexerd[…], error = 3: No
such process"); 9 times in the first 345 s of a boot. On the Mac with the
same device data it starts once and runs for the whole window. It is the
only one of the full boot's restart loops that is Ycode's own. The fix
needs reference facts that the clean room cannot produce; the questions
for the dirty room:

**Open questions (FSEvents, for a host `com.apple.FSEvents` service)**

- **Q11.1 The wire protocol.** For the FSEvents client library of the
  iOS 27.1 simulator runtime talking to `com.apple.FSEvents`, as a
  message-level interface description (no code): the Mach message ids,
  and the request and reply layouts (header bits, descriptors, body
  fields with sizes and meanings, the reply's return-code field), of the
  calls behind the public API that fileindexerd uses:
  `FSEventsCopyUUIDForDevice`, `FSEventsGetCurrentEventId`,
  `FSEventStreamCreate`/`FSEventStreamCreateRelativeToDevice` followed by
  `FSEventStreamStart` (registering a stream: path list, `sinceWhen`,
  latency, create flags), `FSEventStreamStop`/`Invalidate`, and how events
  reach the client (which port, which message id, the layout of an event
  batch: paths, flags, event ids). Is the connection per process (the
  lookup is per pid, flags 0x9) and does the server hold a send right to
  a client port?
- **Q11.2 The minimum that keeps fileindexerd up.** On the Mac: which of
  these calls fileindexerd makes at its start (a message trace of a
  simulator device's fileindexerd, ids and sizes only), and whether it
  stays up when the stream is accepted but never delivers an event. If
  it does, a host service that answers the UUID and event-id requests
  (a fixed UUID per device directory and a monotonically increasing id)
  and accepts subscriptions without events would give the Mac's
  behaviour (one start, alive) at once; change events from the host file
  system (inotify on Linux) can follow.
- **Q11.3 The UUID.** What `FSEventsCopyUUIDForDevice` returns for the
  device's data volume on the Mac (one UUID per host volume, stable across
  boots?), and whether fileindexerd stores it (a store keyed by the UUID
  would be rebuilt when it changes).

**Answers (agent OBS-FSEVENTS, 2026-10-27, Mac, level 3; method and
details in `fsevents-host.md` §9 and
`research/notes/obs-fsevents-2026-10-27.md`).**

- **Q11.1** The protocol is now specified in `fsevents-host.md` §2–§5:
  one service port (66000 register a stream, 66002 device UUID, 66003
  current id, 66004 last id before a time), one stream port per started
  stream (66001 FlushSync, 66006 Stop), replies with id + 100, and one-way
  event messages 67000 from the service to a client port that the client
  sends in 66000 (offsets, wire flags, ids, path records with optional
  inode and document id). The connection is per process: one look-up
  (`bootstrap_look_up2`, flags 8) on the first call, kept for the
  process's life; the service holds a send right to every stream's
  client port. Create, SetDispatchQueue, SetExclusionPaths,
  GetLatestEventId and FlushAsync send nothing; Invalidate destroys the
  client port.
- **Q11.2** What fileindexerd sends: at its start two 66002 (dev of the
  data volume), one 66003, then 66000 for one stream on the
  `group.com.apple.FileProvider.LocalStorage` group container's
  `File Provider Storage` directory and the container itself (latency
  0.2 s, flags 0x1F1, `sinceWhen` = the current id). It never stops the
  stream. On the Mac it then gets one event (HistoryDone) and nothing
  more in a quiet boot.

  **Nothing from FSEvents is needed to keep fileindexerd alive.** On the Mac,
  with the look-up answered 1102 inside fileindexerd (as in Ycode; our
  recorder, `fsevents-host.md` §9.3), fileindexerd does not crash:
  device `ycode-test-fsevents-1` (fourth boot, state written earlier with
  the real service) and a new device (second boot, the fresh path, with
  `com.apple.FileProvider.sim2host` denied too) both logged "failed to get
  stream UUID for device 16777230", got `false` from
  `FSEventStreamStart`, ran their scan and stayed up (one start each,
  until the shutdown). Neither logged "failed to subscribe to events in
  …" or "Failed to init after preparing dependencies". With a stand-in
  that gives the minimal answers of `fsevents-host.md` §7 (fixed UUID,
  ids from 1000, HistoryDone, never a change event) fileindexerd runs as
  with the Mac's service (stream started, state file written with the
  stand-in's UUID). So a host `com.apple.FSEvents` is worth having (file
  events for seven guest clients), but **Ycode's crash has another cause
  on the subscription path**.

  **Where to look (level 3, the Mac's answers; the Ycode values read
  from its sources).** Before it subscribes, fileindexerd's FileProvider
  change monitor asks the kernel about the watched volume, and the
  FSEvents client asks about the paths. On the Mac, in order:
  `fstatfs` on a descriptor of the root → `apfs`, flags 0x04909080, fsid
  {0x0100000E, 0x1A}, mounted on `/System/Volumes/Data`;
  `getattrlist` of that mount point with `ATTR_CMN_DEVID` and
  `ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES` → dev 0x0100000E, format
  capabilities 0x019B6EDF, interface capabilities 0x01AF6FC7 (valid
  0x07FFFFFF, 0x01FFFFFF); `FSEventsCopyUUIDForDevice(0x0100000E)`; then
  `getattrlist` of each watched path with `ATTR_CMN_RETURNED_ATTRS` and
  `ATTR_CMNEXT_NOFIRMLINKPATH`; then `FSEventStreamCreate` with flags
  0x1F1, which ask for document ids (`kFSEventStreamCreateWithDocID`).
  Ycode answers the capability request with format 0x00024F47 and
  interfaces 0x00004302 (`AttributeList.swift`): among other bits it
  lacks `VOL_CAP_FMT_DOCUMENT_ID` (0x80000), which a stream that asks for
  document ids may require.

  **The cause, reproduced on the Mac (level 3).** In a Mac boot with the
  look-up still answered 1102 inside fileindexerd, our recorder replaced
  only the two capability words of that `getattrlist` reply with Ycode's
  (format 0x00024F47, interfaces 0x00004302). fileindexerd then logged,
  exactly as in Ycode, "failed to subscribe to events in
  <GroupContainers>/…/F{19}e with NSError: POSIX 19 "… Operation not
  supported by device"" (twice: "Failed to subscribe to root …,
  registering it for removal", then again after re-adding the root) and
  stopped with "FileIndexerDaemon.swift:638: Fatal error: Failed to init
  after preparing dependencies: Error Domain=NSPOSIXErrorDomain Code=19"
  (SIGTRAP; launchd: "service has crashed 1 times in a row"). The same
  set-up without the replacement (two runs, a fresh and a loaded state)
  ran normally. **So Ycode's fileindexerd loop comes from the volume
  capabilities Ycode reports for the data volume, not from the missing
  FSEvents service.**

  **The four capabilities it needs (level 3; names: public `sys/attr.h`,
  level 1).** The capability words were then read from a file at every
  fileindexerd start, and launchd's restarts after each crash (or after
  we killed a surviving one) tried 26 combinations in 35 starts in two
  more boots (a value that two starts read gave the same result both
  times). Every refused start called the capability request twice and
  never reached `FSEventStreamCreate`; every accepted one created its
  stream.
  The subscription succeeds, and fileindexerd stays up, only when the
  volume reports all four of:

  | Word | Bit | Name |
  |---|---|---|
  | format | 0x00080000 | `VOL_CAP_FMT_DOCUMENT_ID` |
  | format | 0x00100000 | `VOL_CAP_FMT_WRITE_GENERATION_COUNT` |
  | interfaces | 0x00010000 | `VOL_CAP_INT_CLONE` |
  | interfaces | 0x00080000 | `VOL_CAP_INT_RENAME_EXCL` |

  Ycode's words with these four added (format 0x001A4F47, interfaces
  0x00094302) → up. Each is necessary: the Mac's words without
  WRITE_GENERATION_COUNT, or without CLONE → crash; Ycode's words plus
  the other three but not DOCUMENT_ID → crash; with the Mac's format
  word, Ycode's interfaces plus CLONE (and the Mac's low interface bits)
  crash, and adding RENAME_EXCL, not SNAPSHOT or RENAME_SWAP, makes them
  pass. The other differences do not matter for fileindexerd (journal,
  zero runs, hidden files, compression, shared space, volume groups,
  snapshot, rename swap, the three highest interface bits, Ycode's extra
  `VOL_CAP_FMT_CASE_SENSITIVE`). Every test list:
  `research/notes/obs-fsevents-2026-10-27.md`.

  **For the clean room:** report these four bits for the device's data
  volume (and decide which related calls they promise: document ids and
  write-generation counts in `getattrlist`, `clonefile`, and
  `renameatx_np` with `RENAME_EXCL`, which §4 already covers); with them
  fileindexerd should start once, as on the Mac. The FSEvents host of
  `fsevents-host.md` is independent of this fix.
- **Q11.3** The UUID is that of the host's event store for the data
  volume (dev 0x100000e on the Mac, where every guest path lives): the
  same in both boots in which it was read, and not the volume's APFS
  UUID. An unknown device gets the text `NO-UUID-UNKNOWN-DEVICE`,
  which the client turns into NULL. fileindexerd stores it: `streamUUID`
  and `lastEventID` in its JSON state file
  (`DEV/data/Containers/Data/InternalDaemon/<its container>/indexingState`),
  read back at the next start ("successfully loaded state from disk with
  state: IndexingState(streamUUID: …)"), after which it asks the
  service for the UUID again. For Ycode: a fixed UUID per device, kept across boots,
  and ids that never go back (`fsevents-host.md` §7).

**Ycode implementation (agent FS-HOST, clean room, 2026-10-27/28).** Both
of Ycode's volumes now report format 0x001A4F47 and interfaces 0x000D4302:
the four bits above plus `VOL_CAP_INT_RENAME_SWAP`, each backed by the
calls it promises (`file-system-features.md`: document IDs and file flags,
write generation counts, `clonefileat`/`fclonefileat`, atomic
`RENAME_EXCL`/`RENAME_SWAP`). The host's `com.apple.FSEvents` is served
too, with change events from Ycode's VFS (`fsevents-host.md` §10).

Result, 700 s behaviour runs (`parity-ladder.md` §4.8 method: a fresh copy
of the golden device, home screen + 670 s, `launchd.log` counted over the
first 700 s), all on the Linux host on 2026-10-28, under the load of other
agents' boots:

| Run | Tree | fileindexerd | Other differences |
|---|---|---|---|
| base | main line (e3982c6) | 16 starts, 16 × SIGTRAP | — |
| A | capabilities + FSEvents service with events | **1 start, alive at the end** | none |
| A′ | A merged with the main line (fc308f0) | **1 start, alive** | none |
| B | A with `YCODE_DEBUG_NO_FSEVENTS=1` (no service) | **1 start, alive** | none |
| C | A with `YCODE_FSEVENTS_NO_CHANGES=1` (minimal service) | **1 start, alive** | none |

The Mac with the same device data: one start, alive for the whole window
(above). In run A fileindexerd looked up `com.apple.FSEvents`, got the
device UUID and started its stream; its only failed look-ups were
`com.apple.spaceattributiond` and `com.apple.FileProvider.sim2host`
(host endpoints Ycode lacks, `launchd-sim.md` §6.4). B and C confirm the dirty room's
finding: the capability bits alone stop the loop. No new guest crash in
any run: intelligencetasksd (§13.1) in all five, assistantd (one SIGTRAP in
libdispatch) in base and B, amsengagementd (one or two SIGSEGV in
JavaScriptCore, at a different place each time) in B, C and A′ and in
both probe boots — and on 2026-10-28 also in about half of the boots of
other agents' trees that do not have this work (fold, camera and visionOS
runs), so it is not caused by this change. managedappdistributiond ran 42–56 times (exit 0, `xpc
event` relaunched every 10 s from about +250 s) in all five, the base
included: a property of the golden device on this date, not of this work.
**fileindexerd's loop is closed; none of the boot's other restart loops
changes with this work.**

Boot time is unchanged: timed boots of the golden device with the machine
to itself (`timed.sh`; the home screen detected on 5 s screenshots), main
line fc308f0 against this work merged on it, in both orders: base 75 s and
80 s, this work 80 s and 75 s.

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

## 13. The full boot on the 2026-10-27 main line (agent SVC-FULL)

IDE runs boot every service since 2026-10-27 (`lean-boot.md` §9). Full
boots of the main line (5f74ef9) were checked for crashes and loops that
are Ycode's own: three 700 s behaviour runs on copies of the golden device
(`parity-ladder.md` §4.8), a 345 s boot, twelve timed boots and the app
and warm-boot checks of §4.8 there. The guest's fatal conditions were
fileindexerd (§11) and intelligencetasksd (§5.1) in every boot, and
nothing else, except as below.

### 13.1 intelligencetasksd starts fewer times than on 2026-10-19

intelligencetasksd crashed 3, 4 and 5 times in the three 700 s runs (all
SIGTRAP, "XPC Peer Requirement isn't implemented on simulators yet",
§5.1), against 16 in run h5 of 2026-10-19 on the same golden device and 15–16
on the Mac with that device's data (`parity-ladder.md` §4.7). The crash and
launchd's throttle are unchanged: after the 3rd crash launchd simply gets
no new launch event. Its launches are `xpc event`s for background system
tasks (the job's `LaunchEvents`, read as data, level 2: four
`com.apple.bg.system.task` tasks with `RepeatingTask` interval 86400 s,
three of which require network connectivity and two external power, and
one post-install task scheduled 300–3600 s after the install), which the
guest's task scheduler fires when it judges them due. Whether they are due
depends on the device's stored history and on the wall clock, and the
golden device is eight days older than on 2026-10-19 (boots of other
devices on 2026-10-27 crashed it 4–14 times, in runs of various lengths). So the count is not
comparable with a Mac reference measured on another day; the behaviour
(the crash, the exit kind, the throttle) matches. **Open question
(Q13.1, Mac, black box):** the Mac's intelligencetasksd starts in 700 s
with a copy of the same golden device's data booted on the same day as a
Ycode run, and which of the five tasks each start runs (the guest log of
the task scheduler names the task it launches), to tell whether the
scheduler's conditions (network, external power: what the simulator
reports for both) differ between the platforms.

**Answer (agent OBS-FSEVENTS, 2026-10-27, Mac, level 3).** No copy of a
Ycode run's `DEV/data` was available on the Mac, so new devices were
used (`ycode-test-fsevents-1` … `-4`, called `-1` … `-4` below; iPhone
Duo, iOS 27.1, macOS 27.2; the Mac was heavily loaded by other agents, load 90–1000, swap nearly full, so times stretch). dasd's
log and `launchd.log`:

- **Only one of the five tasks runs in these windows: the post-install
  task** `com.apple.intelligencetasksd.spotlight-verification-post-install`
  (Utility, priority 30). dasd submits it at every boot, 34–82 s after
  launchd_sim starts, with the window [submission + 300 s,
  submission + 3600 s]. The four interval tasks (`sets.maintenance.A`,
  `.B`, `.C`, `spotlight-verification-nightly`, interval 86400 s, two of
  them "CPU Intensive, Require Device Inactivity") were submitted with
  windows starting the next morning, so no condition on network or power
  was evaluated for them in these runs.
- **One dasd launch gives a long launchd loop.** dasd initiates the task
  (an XPC event to launchd), intelligencetasksd starts and stops at once
  with SIGTRAP ("XPC Peer Requirement isn't implemented on simulators
  yet"), and launchd starts it again for the same event: every 10 s
  ("Pushing respawn out by 10 seconds"), from the 12th crash with the
  exponential throttle of §5. dasd gives up after 61 s ("BGST client
  (PID 0) did not acknowledge launch within 61s … Canceling … reason 3")
  and resubmits the task at a fixed time one hour later. **launchd keeps
  relaunching after dasd's cancel**: on device `-4` one initiation
  (+442 s after the boot's start) gave 19 starts in 61 minutes (10 at the
  10 s rate, then at growing intervals: the exponential throttle, its gaps
  stretched by the load); on device `-1` (third boot) one
  initiation at +357 s gave 5 starts until the shutdown at +467 s, one of
  them after the cancel; device `-3` showed the same timeline as `-4`.
- Starts in the first 700 s therefore depend on when dasd fires the
  task: 0 (device `-2`, second boot: not fired by 700 s; device `-1`,
  fourth boot: the task was due only one hour after the third boot's
  cancel), 0 (device `-4`: launched at +442 s, but under the load the
  process was spawned only at +803 s), 5 (device `-1`, third boot, cut by
  the shutdown), and 15–16 in the Mac references of §5.1 and §12.1 (first crash at +457 s).

**Reading.** The exit kind and the throttle match Ycode. The count does
not: Ycode's three 700 s runs (3, 4, 5 crashes) stopped getting launch
events after a few crashes ("after the 3rd crash launchd simply gets no new
launch event", above), while the Mac's launchd keeps the event and
relaunches at the 10 s rate for minutes after dasd's cancel. Whether
Ycode's runs fired the task late (shortly before 700 s) or the event is
dropped in Ycode is not visible from the counts. **Open question (Ycode,
for the clean room):** in a Ycode `launchd.log`, the time of the first
"launching: xpc event" of `com.apple.intelligencetasksd` and whether
"launching: xpc event" lines continue after dasd's "did not acknowledge
launch within 61s" (guest log); on the Mac they do, every 10 s.

**Ycode answer (agent FS-HOST, 2026-10-28, run A of §11's table; the base
run is the same).** The first "launching: xpc event" of
`com.apple.intelligencetasksd` came 48 s after `launchd.log`'s first line;
the job crashed (SIGTRAP, as above) and launchd relaunched it for the same
event at once, then every 9–10 s ("Pushing respawn out by … seconds"),
with longer gaps (73 s, 81 s, 210 s) after the starts that exited in a
dirty state ("service exceeded successive crash limit. launch will be
throttled"). "launching: xpc event" lines continued through the whole
window: 13 starts in 700 s (12–14 in the other runs of the day),
against 15–16 on the Mac. So Ycode does not drop the event: the
relaunches go on as on the Mac, and the 3–5 crashes of 2026-10-27 came
from when the task was fired, not from a lost event. dasd's "did not
acknowledge launch within 61s" is in the guest's unified log, which these
runs did not capture.

### 13.2 PosterBoard: "Invalid condition not satisfying: versionsURL"

**Observation (level 3).** In 3 of 479 Ycode boot logs on the Thor
(2026-10-19 to 2026-10-27, iPhone and iPad devices, full boots), and in
the boot reported in `visionos.md` §10.14.5, PosterBoard ends with SIGTRAP from a
PosterFoundation assertion: "Invalid condition not satisfying:
versionsURL". It did not occur in the boots of this check. The last
system calls of the crashing thread (the fatal report's trap ring, which
records numbers, first arguments and results, not path contents) are,
in two of the reports: `fstatat64` → 0, `mkdirat` → 0 (both on one path
buffer), then `chmod(…, 0777)` → ENOENT and six `getattrlist` → ENOENT,
then the assertion.

**What the same code does normally (trace run `f700t`,
`--trace-name PosterBoard`, full boot, no crash).** PosterBoard keeps
poster descriptors and configurations under
`DEV/data/Library/Application Support/PRBPosterExtensionDataStore/<n>/Extensions/<extension>/{descriptors,configurations}/<UUID>/versions/<k>/{contents,scratch,supplements/<j>}`.
It creates a version's directories with `mkdirat` of the leaf (ENOENT
while the parent is missing), `mkdirat` of the parent, `fstatat64`,
`mkdirat` of the leaf, then `chmod(…, 0777)` of the parent and of the
leaf, in that order. On other threads it removes whole descriptor trees
(`unlink` of each name, EPERM for a directory as on Darwin, then
`rmdir`). So the crashing sequence is the normal creation with the
parent gone between its `mkdirat` of the leaf and its `chmod` of the
parent: the tree was removed in between, which a concurrent removal by
PosterBoard itself explains. No Ycode call in the sequence returned a
wrong answer in the traced run (`mkdirat`, `chmod`, `unlink` and `rmdir`
results match Darwin's documented semantics).

**Reading: most likely a race inside PosterBoard (parity), not
established.** The Mac's simulator also writes PosterBoard crash reports
now and then (`parity-ladder.md` §3.1), but their reason was not
recorded. **Open question (Q13.2, Mac, black box):** the exception
message (`crash annotation` / `abort cause` field) of the Mac's
PosterBoard `.ips` reports of a simulator device, and whether any of them
is "Invalid condition not satisfying: versionsURL". If it is, this is
parity; if the Mac never shows it in many boots, look for a Ycode
difference in the order of PosterBoard's work (Ycode starts the poster
extensions' work in a different order and at a different speed than the
Mac, `scheduling-policy.md`).

**Answer (agent OBS-FSEVENTS, 2026-10-27, Mac, level 3 and 4): the Mac
has the same crash; parity.** The Mac's crash-report folder held five
PosterBoard reports of iOS simulator devices (other agents' devices,
2026-10-20 to 2026-10-27; four devices; the three newest checked to be
the iOS 27.1 24A94401 runtime by their shared-cache identity, the two
oldest rotated out of the folder before that check; none in the eight
boots of this agent's devices). All five are the same crash: SIGTRAP
(`EXC_BREAKPOINT`) 16–69 s after PosterBoard's launch, on the queue
`PBFPosterDescriptorStoreCoordinator-accessQueue_<UUID>`, in the assertion
branch of PosterFoundation's
`+[NSURL(PosterFoundation) pf_posterPathInstanceURLForVersionsURL:version:]`,
called while a new descriptor version is set up
(`-[PBFPosterModelStoreCoordinator addNewVersionWithContents:error:]` →
`_accessQueue_setupNewVersionWithOptions:contents:error:` →
`_accessQueue_configureFileSystemForNewContents:atPath:error:`) during the
reload of an extension's descriptors
(`-[PBFPosterExtensionDataStore _stateLock_ingestReloadedDescriptorsForExtensionBundleIdentifier:…]`).
The simulator's reports carry no assertion text (no application-specific
information), so the message itself cannot be read from them; the
faulting routine is the one whose versions-URL argument the Ycode message
names, on the same path (new version → its directories). No other thread
of the five reports was inside a file removal at the moment of the crash,
so the Mac reports neither confirm nor rule out the concurrent-removal
reading above; they show that the crash is PosterBoard's own and happens
on the Mac at about the same rate (a handful in a week of many boots).
**Kept as is (parity).** (Symbol names are binary metadata from the crash
reports, level 4; `research/notes/obs-fsevents-2026-10-27.md`.)

## 14. amsengagementd and assistantd (agent THREAD-SUSPEND, 2026-10-28)

**Before.** On the main line (bfa4c1a) amsengagementd crashed in every
full boot of the day, in JavaScriptCore (a data abort at a bad address
almost every time), and assistantd ended once in most boots with
"BUG IN LIBDISPATCH: Invalid wlh state". Neither crashes on the Mac
(`app-launch.md` §3.6; assistantd's SIGTRAP was listed as a Ycode
difference in §11). Causes: JavaScriptCore's collector could not suspend
the threads whose stacks it scans (`thread_suspend` was a stub), and a
returning workqueue worker lost the changes after a failed one
(`threads-and-events.md` §1.6, §2.7 step 3).

**Method.** 700 s behaviour runs as in §11 (`parity-ladder.md` §4.8: a
fresh copy of the golden device, home screen + 670 s, `launchd.log` over
the first 700 s), on the Linux host on 2026-10-28, under other agents'
load. Each pair (main line, this work) was started together on two
copies of the same device; the order of start alternated. Area
`ide-remote/tsus`: `ab.sh`, runs `A-*` (suspension alone, tree TSUS) and
`B-*` (suspension and the workqueue fix, tree TSUS2), against the main
line (tree TSUSB).

| Runs | Boots | home_s | amsengagementd crashes (boots) | assistantd crashes | Other abnormal exits | Programs started in 700 s |
|---|---|---|---|---|---|---|
| main line `A-b1`, `A-b2`, `B-b1`…`B-b8` | 10 | 120–321 | 11 (10): 8 data aborts and 2 BRK in JavaScriptCore, 1 jump to 0 | 8 | none | 474–490 |
| suspension alone `A-n1`, `A-n2` | 2 | 145, 320 | 3 (2): all "Invalid wlh state" | 2 | none | — |
| this work `B-n1`…`B-n8` | 8 | 127–167 | **0** | **0** | none | 473–487 |

The restart loops of §12 (managedappdistributiond, fitcore, datamigrator)
and intelligencetasksd's crashes (§13.1) are the same in both columns. In
the work's runs amsengagementd runs once for the whole window (one start,
alive at the end; killed at the shutdown). A visionOS 27.0 boot of the
work reaches the room (runs `tsus/vruns/v1`, `v2`), with no
amsengagementd or assistantd crash.

**Boot time unchanged:** timed boots with the machine to itself
(`timed.sh`), main line against this work, both orders: main line 80 s
and 80 s, this work 80 s and 75 s (`SX/TSUSB/runs/t1-base`, `t2-base`,
`SX/TSUS2/runs/t1-tsus`, `t2-tsus`).
These four boots compare this work with its base only (two each); the
full-boot median of 30.1 s, measured on a copy of the golden device that
had already booted once at its own path, with the home screen from the
home watch, is in `lean-boot.md` §9, and times from different series are
not comparable.

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
| fileindexerd still crashes in full boots of 2026-10-27 (§11) | 3 (Thor runs `svcfull/f700a`, `f700b`, `f700q`, `warm1`: `launchd.log`, fatal reports) |
| FSEvents API names (§11 questions) | 1 (public FSEvents.h documentation) |
| intelligencetasksd's starts and launch events (§13.1) | 3 (`launchd.log` of runs `f700a`, `f700b`, `f700q`, PRIO `h5`, other 2026-10-27 runs); 2 (the job plist's `LaunchEvents`, read as data) |
| PosterBoard's assertion, trap rings, and its normal file operations (§13.2) | 3 (Ycode boot logs on the Thor; trace run `svcfull/f700t`) |
| unlink of a directory → EPERM (§13.2) | 1 (unlink(2) on Darwin) |
| FSEvents protocol, UUID semantics, fileindexerd's calls (§11 answers) | 3 (recorder and probe of ours on Mac throwaway devices `ycode-test-fsevents-*`, 2026-10-27; `fsevents-host.md`) |
| fileindexerd survives without `com.apple.FSEvents` on the Mac; runs with the minimal stand-in (§11 Q11.2) | 3 (look-up answered 1102 or by our in-process stand-in, two device states; guest log, `launchd.log`, state file read as data) |
| fileindexerd's `fstatfs`/`getattrlist` requests and the Mac's answers before subscribing (§11) | 3 (recorder); the capability bit names 1 (public `sys/attr.h` of the macOS SDK); Ycode's values read from its sources |
| Ycode's capability words reproduce Ycode's fileindexerd crash on the Mac; the four required bits (§11 Q11.2) | 3 (fault injection by our recorder into fileindexerd's `getattrlist` replies, 36 starts in three boots, guest log and `launchd.log`) |
| intelligencetasksd: dasd's tasks, windows, the 61 s cancel, launchd's relaunches (§13.1) | 3 (dasd and launchd logs of four Mac devices, crash reports; 2026-10-27) |
| PosterBoard's Mac crash reports (§13.2) | 3 (`.ips` reports: queue, signal, times, shared-cache identity); 4 (the symbol names in their frames) |
| Ycode's fileindexerd with the new capability words: one start, alive; no new crash (§11, Ycode implementation) | 3 (Thor runs `fsh/f700a`, `f700b`, `f700c`, `f700n`, `f700m` of 2026-10-28; other agents' boot logs of 2026-10-27/28 for amsengagementd: `launchd.log`, fatal reports, the service's log); the implementation is Ycode design (`file-system-features.md`) |
| Boot time unchanged (§11, Ycode implementation) | 3 (Thor `timed.sh` runs `FSHBASE/t1-base`, `t2-base`, `FSH/t1-fsh`, `t2-fsh`) |
| intelligencetasksd's relaunches in Ycode continue through the window (§13.1, Ycode answer) | 3 (`launchd.log` of the same five runs) |

| amsengagementd and assistantd before and after real thread suspension and the workqueue fix; programs started; restart loops (§14) | 3 (Thor runs `ide-remote/tsus/runs/A-*`, `B-*`: `launchd.log`, `beh.txt`, fatal reports with trap rings and crash annotations; visionOS runs `tsus/vruns/v1`, `v2`) |
| Boot time unchanged (§14) | 3 (Thor `timed.sh` runs `TSUSB/t1-base`, `t2-base`, `TSUS2/t1-tsus`, `t2-tsus`) |

No disassembly or decompilation was used (level 5 not used).
