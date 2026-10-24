# Spec: the frame profile, and the guest-CPU/IPC side of a frame

Status: **implemented** (agent FPS-PROF, 2026-10-19). §1–§3 are a
diagnostic (off by default). §5 lists three changes; each has a switch and
is on by default. Ycode's own design: nothing here describes Apple
software. Programs (backboardd, SpringBoard, notifyd, …) are named only as
black boxes whose traps, waits and wakeups the VMM observes.

Related: `display-stream.md` §10 (FPS-LATENCY's swap and input timing,
`ycode-display-probe`), `boot-profile.md` (per-image CPU accounting, PC
samples), `mach-ipc-locking.md` and `bsd-locking.md` (the locks named
here), `thread-latency.md` (wakeups).

## 1. The frame profile (`YCODE_FRAME_PROFILE=<path>`)

A trace of everything the VMM sees of a frame, recorded only in windows
that the person opens, so it can stay on for a whole interactive session.

| Variable | Default | Meaning |
|---|---|---|
| `YCODE_FRAME_PROFILE` | unset | the path prefix of the output; unset: nothing below exists |
| `YCODE_FRAME_PROFILE_EVENTS` | 4194304 | events per window (32 bytes each, preallocated: 128 MiB at the default) |

- **Opening a window.** Create `<path>.go`; its content is the window's
  length in seconds (default 10, 0.5–120). A poller looks every 100 ms and
  deletes the file. From a Mac session:
  `ssh <host> "echo 12 > <path>.go"` at the moment the interaction starts
  (the viewer's `--script` can `log` a marker that a wrapper watches for).
- **While a window is open** (and only then) the VMM records, with
  `CLOCK_MONOTONIC` times:
  - every trap of every guest thread: enter (trap number; for `mach_msg2`
    the message id and the low 32 bits of the options, else x0) and exit
    (x0, bit 63 = error), including page faults (trap −1000);
  - every wait-queue sleep of a guest thread (block, unblock);
  - every wakeup: the waker (a guest thread, or a host thread by its Linux
    thread id) and the wakee;
  - every present: the frame record (`simframebuffer.md`) polled every
    1 ms (counter, surface id);
  - every timer firing: the image, Mach timer or `EVFILT_TIMER`, and how
    late it fired after its deadline.
  Cost with no window open: one relaxed atomic load per trap and one nil
  check per wait, wakeup and timer. With a window open: about 0.1–0.3 µs
  per event; a busy device makes 20–90 k events per second.
- **When the window closes** it writes:
  - `<path>.<n>.trace`: the events, binary, 32 bytes each, little-endian:
    u64 time, u64 arg, i32 pid, u32 guest thread id, i32 trap, u8 kind
    (1 trap enter, 2 trap exit, 3 block, 4 unblock, 5 wake, 6 present,
    7 timer fired), u8 thread kind (1 main, 2 pthread, 3 workqueue), u16 0;
  - `<path>.<n>.names`: pid → program; `host <tid> <name>` for each host
    thread that woke a guest thread (a thread that fired timers is named
    `kernel-timers`; others by their Linux thread name, e.g.
    `DispatchWorker`, `display-receive`, or the process name for unnamed
    service threads);
  - `<path>.<n>.summary`: per program over the window: threads, host CPU
    (guest mode, host kernel, VMM user code), run-queue wait, time in
    `KVM_RUN` and in trap handlers, VM exits, scheduler timeslices,
    voluntary and involuntary context switches, minor faults, and CPU and
    run-queue ms per present; the host load average at both ends; the
    shared-arena recycling counters (§5.2). With `YCODE_TRAP_PROFILE` also
    set, three more tables: per trap number over the window, the kernel
    lock L0, the event locks and the port lock (traps, acquisitions, hold
    and wait ms, per present, contended share, wait per acquisition).

## 2. The analysis (`scripts/ycode-frame-profile <path>.<n>`)

Python 3 standard library, run with `python3 -I`. Options:
`--program <name>` (whose `pwrite` of the frame record is the present;
default `backboardd`), `--frames N` and `--chains K` (frames printed in
detail, steps per frame), `--from`/`--to` (seconds into the window).

It prints:

1. Present intervals (p10, p50, p90, max).
2. Threads by guest-code time: per thread, ms in guest code, in trap
   handlers not sleeping, and sleeping.
3. Programs: guest code and trap service ms per present.
4. Traps by service time: per program and trap, count, count per present,
   service time (handler time minus sleeps; this includes kernel-lock
   waits), µs each, and sleep time.
5. Wakeup latency (wake → the woken thread running its trap again: host
   futex wake, host scheduling, re-taking the wait's lock), by waker kind.
6. Timer lateness per program and timer kind.
7. **The critical path of every frame**: from the trap that wrote the
   frame record back to the previous present. Walking backwards on the
   writing thread: guest code and trap service are attributed to their
   program; a sleep ended by a wakeup becomes "wakeup latency" and the walk
   continues on the waker at the moment of the wakeup; a sleep ended by a
   host thread is attributed to that host thread ("host thread: X (woke P
   in trap)": waiting for a host service, the GPU, a timer, input); a sleep
   that timed out is "timed wait". The steps of a frame sum to its
   interval. The mean per frame over all frames closes the report.
8. **Gestures**: for each burst of viewer input (host thread
   `display-receive`, a new burst after 300 ms without input), the time to
   the first present and that present's critical path back to the input,
   with consecutive steps of one program merged.

How the other frame agents use it: FPS-GPU reads the "host thread:
DispatchWorker" and "ycode-simd (woke backboardd in mach_msg2)" steps
(waits for the Metal host service and GPU completion); FPS-LATENCY reads
§8 (input → first present) next to `display-stream.md` §10.

## 3. Method

Device `ide-remote/<agent>/` area through `ycode-sim-try` with a separate
config, viewer `--script` (home-screen swipes: six drags of 340 points in
250 ms, 1.2 s apart), a frame-profile window of 10–12 s opened at the
script's marker; restores of one saved device (`snapshot.md` §12), arms
alternated session by session (paired). Arms differ only in environment
switches, which the warm-boot fingerprint ignores, so every session
restores the same snapshot. The Thor is shared: the host load average
(14 cores) was 9–58 during these runs and is given with each result.

## 4. Where a frame went before the changes (main line 9195ba1)

Restored device, home-screen swipes, load 31–39 (run `r2`; a cold boot's
first minute, `r1`, looked the same with larger numbers). Present
intervals p50 37 ms, p90 330 ms. The critical path of an animation frame
(about 42 ms):

| Step (mean per frame) | ms | Share |
|---|---|---|
| backboardd's `pwrite` of the 96-byte frame record (trap service) | 17.9 | 39 % |
| backboardd's `mach_make_memory_entry_64` (Ycode routine `0x7963200A`), about 21 per frame (new shared Metal buffers) | 14.5 | 32 % |
| a host `DispatchWorker` (the Metal host service's GPU completion) | 3.4 | 7 % |
| backboardd guest code | 2.0 | 4 % |
| wakeup latency | 0.9 | 2 % |

The trap profile (`YCODE_TRAP_PROFILE`, cold boot, load 57) showed why:
L0 was held 53 % of the window; its waits were 1–3 ms per acquisition
(contended 17–43 %). `pwrite` (BSD 154) and `write` (4, 397) were not on a
BSD fast path, so a frame's present waited for L0 (p50 1–5 ms, p90 9–23
ms) and then for the host write. `mach_make_memory_entry_64` held L0 for
5.2 ms per call (1.8 s of 10 s) and `mach_port_deallocate` of the entries
0.36 ms per call under L0 and the port lock G (32 % of all G hold time):
each shared object's creation and release remapped a run of the shared
object arena (`boot-profile.md` §3.5), and every host mapping change in the
arena runs the MMU notifiers of every VM of the process (each one takes
its MMU lock, unmaps the range from stage 2 and flushes TLBs: hundreds of
VMs, milliseconds per change). The kernel timer thread fired every Mach
and `EVFILT_TIMER` timer under L0 (p99 lateness 0.6–15.9 ms, max 59 ms).
diagnosticd made about 700 `proc_info` calls a second
(`PROC_INFO_CALL_DIRTYCONTROL`, two per message it handles), each an L0
acquisition (§7).

## 5. Changes

### 5.1 `write` and `pwrite` of host files without L0

`write` (4, 397) and `pwrite` (154, 415) of a regular host file join the
BSD fast paths (`bsd-locking.md`): one descriptor-table lookup, then the
host write under the description's offset lock, as `read` and `pread`
already did. A guarded descriptor (any guard with `GUARD_WRITE`), an
object (pipe, socket), the console, a device node, a bad descriptor and a
length above `INT_MAX` fall back to the locked path, which reports them
exactly as before. Results, offsets and `O_APPEND` behave as on the locked
path (test `BSDFastPathTests.writesMatchTheLockedPath`). Switch: the
existing `YCODE_BSD_FAST_EXCLUDE=4,397,154,415` turns it off.

### 5.2 The shared object arena reuses freed runs

A freed run of an anonymous shared memory object stays mapped (its pages
kept) in a pool by size, up to `YCODE_ARENA_RECYCLE_MB` (default 256; 0 =
off) and runs of at most 4 MiB; the next object of exactly that size takes
it and zeroes it, so neither the creation nor the release changes a host
mapping and no VM's MMU notifier runs. File views are never pooled (their
runs hold `MAP_SHARED` file pages) and a full pool falls back to the
remap. Isolation is unchanged: a guest reaches arena pages only through
its stage-1 tables, which the VMM changes and flushes when the object is
unmapped; a pooled run is unreachable until it is handed out again,
zero-filled. The frame profile's summary prints `arena recycle: N reused,
M new, R refused, P MiB pooled`; a home-screen session reused 4,349 runs
and made 529 (11 MiB pooled). Test `SharedArenaRecycleTests`.

### 5.3 The timer thread runs under the image's event lock

With the lock split, each image's timer thread now waits on, and fires
timers under, the image's event lock L_P instead of L0: as a fast path
(`KernelLock.withFastPath`), so what needs L0 (starting a workqueue
thread, a kqueue descriptor's observers) is deferred work, run before the
thread sleeps (`mach-ipc-locking.md` §4.5). Mach timers take G inside L_P
as before. Its wait queue is bound to L_P; every waker already held it
(`withEvents`), and arming an `EVFILT_TIMER` on a kevent fast path now
wakes it directly instead of deferring the wakeup to L0. Waiters without a
guest thread are ignored by the snapshot census, so snapshots are
unchanged (one cold boot and 12 sessions restored from and saved again, 6 of them with the change on, all restored). Switch:
`YCODE_TIMER_L0=1` restores the L0 timer thread.

## 6. Measurements (Thor, 2026-10-19)

### 6.1 Mechanism (frame profile, before → after)

| What | Before | After |
|---|---|---|
| backboardd `pwrite` of the frame record | p50 1.1–5.3 ms, p90 9–23 ms | p50 28 µs, p90 34 µs (but see §7 item 1) |
| `mach_make_memory_entry_64` | p50 0.6–0.9 ms (5.2 ms L0 hold at load 57) | p50 about 20 µs |
| Mach timer lateness, SpringBoard, p99 | 0.6–15.9 ms | 65–546 µs (p90 57–69 µs) |
| critical path of an animation frame | 42 ms, 71 % of it the two traps above | the traps are 1.6 % (0.64 ms); what remains is the render server's pacing timer, GPU completion waits and guest code |

### 6.2 Paired sessions (restored device, home-screen swipes)

Guest presents per second over the viewer's `stats-begin`…`stats-end`
span (`ab2`: 9 s, swipes 8 s after the home screen; `ab3`: 16 s, 45 s
after), and present intervals over the 10 s window (which includes the
1.2 s pauses between swipes, so p50 is the animation cadence):

| Pair | Load | Base: fps, interval p50 / p90 | All three changes: fps, interval p50 / p90 |
|---|---|---|---|
| ab2 1 | 41 / 27 | 1.1, 271 / 1213 ms | 3.9, 37.5 / 288 ms |
| ab2 2 | 17 / 14 | 2.0, 104 / 248 ms | 7.6, 16.5 / 63 ms |
| ab2 3 | 11 / 10 | 4.0, 35.5 / 118 ms | 9.9, 16.9 / 44 ms |
| ab3 1 | 9 / 15 | 5.2, 46.5 / 179 ms | 6.9, 22.0 / 134 ms |
| ab3 2 | 39 / 21 | 5.7, 30.7 / 121 ms | 5.4, 19.7 / 120 ms |
| ab3 3 | 13 / 31 | 4.0, 40.7 / 153 ms | 5.9, 17.5 / 150 ms |

The changes won 5 of 6 pairs on presents per second and all 6 on the
interval p50 (animation cadence 16.5–22 ms, i.e. 45–60 fps in bursts,
against 31–271 ms). The gain grows with host load (L0 contention grows
with it): 2.5–3.8× in `ab2`, about 1.2× in `ab3`. Confidence: the
direction is clear; the size is uncertain within a factor of about 2
because the host load changed between paired sessions. A cold boot with
the changes (`c2`, 60 s after its home screen, load 43) reached 14 fps
over the span and a p50 interval of 13.9 ms. The three changes were
measured together; §6.1 attributes the time each one removed.

## 7. Open items and findings for other areas

1. **The frame record lives on the data volume** (`DEV/data/tmp`, ext4 on
   a busy USB disk). Off L0, the render thread's `pwrite` still stalls
   when the file system's journal does: 2 of 93 writes in one window took
   0.58 s, freezing the frame; a probe of 96-byte rewrites on that volume
   from Python saw p99 25 µs and max 332 ms. The same applies to the
   timing logs of `display-stream.md` §10. Owner of the frame record
   (display stream / framebuffer library): put it on a memory file system
   (e.g. a per-device file under `/dev/shm`, the guest path resolving to
   it), or make the library's write not block the render thread.
   This is probably the 280–340 ms outlier per session that
   `display-stream.md` §10.3 sees.
   *Addressed by FPS-2 (§8.1):* the frame record and timing files are in a
   memory directory; the longest backboardd `pwrite` in a 40 s window fell
   from 0.70–0.83 s to 0.1–47 ms.
2. **GPU completion waits** (host `DispatchWorker` waking backboardd's
   dispatch thread) are now the largest non-idle step of an animation
   frame: 2.5–6 ms per frame, 21 ms in one gesture (FPS-GPU).
   *Addressed in part by FPS-GPU (`stage8-contract.md` §14):* IOSurface
   copy-ins skipped while the image holds the surface's pixels, scheduled
   reported at queue submission with CPU surface access waiting for
   pending GPU writes, completion polled every 1 ms. Paired with 391af58
   (4 rounds, load under 4): the GPU completion wait on the critical path
   fell from 4.5–4.8 to 3.8–4.3 ms per frame and the IOSurface bytes per
   present from 32–38 to 11–13 MB; the swipe cadence stayed at the 60 Hz
   frame clock (p50 16–18 ms in both arms).
   *GPU-2 (`stage8-contract.md` §15.3, §15.7):* the render server's
   command buffers were mostly host time, not GPU time: recording took
   about 2 ms (an environment read per draw, a decoder append that copied
   the pass, labels and table loops) and now 0.4 ms (timed A/B, 3
   sessions per arm, ranges without overlap); receive → completion
   handlers fell by 1.5–2 ms at p50 in swipes and 4–7 ms at p90 in the
   Spotlight pull-downs, whose present interval p90 fell from 24–37 to
   19–23 ms. The GPU time of such a command buffer is 1.3–1.5 ms at p50
   without the feedback copies of §15.6 and 1.7–1.9 ms with them (scissor
   copies; 2.2–2.3 ms copying whole levels); the pull-downs' p90 is about
   7 ms with copies, 2 ms without. The copies stay on: they are what
   keeps Safari's boots from hanging the GPU. Removing their cost is
   `stage8-contract.md` §15.8 item 5.
3. **diagnosticd's `proc_info` dirty control** (about 700 a second) still
   takes L0 for a field of the process record; a leaf lock on the dirty
   state would move it off L0. With the changes above its share of L0
   waits is much smaller, so it is not urgent.
   *Addressed by FPS-2 (§8.2):* a process's own DIRTYCONTROL calls are a
   BSD fast path (one atomic word); p99 per call 190–253 µs → 10–12 µs.
4. **A restored device is busy for about a minute**: the poster extensions
   (Mercury, Emoji, Gradient, Rhizome, Aegir) each used 0.3–0.4 cores after
   a restore, and the first swipes after a restore ran at 1–4 fps. Worth a
   look by the snapshot owners (what the extensions redo after a restore).
   *Not reproduced after a restore by FPS-2 (§8.5):* on 786aef0 and on
   FPS-2 the poster extensions use 0.000 cores in the 30 s after a
   restore's home screen; after a cold boot they use about 2–2.5 cores.
5. **The swipe to the Today view** (right from the first page) showed no
   change for 1.5–2.9 s in every session (the viewer's median input
   latency); the critical path shows nothing drawn in that time, not a
   slow frame (FPS-LATENCY / HID).
   *Explained by FPS-2 (§8.5):* the drags that "do not move" start at
   (400, 350) points, on the dock's Safari icon (the dock is the column at
   the right edge of this device type, and it stays in place over the Today
   view); the same drag started elsewhere moves the page. A viewer's
   "input → first frame" counts such an input until the next input's frame,
   which is where the 1.5–2.9 s came from. Measured from the input to the
   first present, the Today swipe takes 141–289 ms (FPS-2) and 153–668 ms
   (786aef0).
6. Per-trap VMM overhead (the trap frame is read, decoded into arrays and
   re-encoded on every trap) and notifyd's work on each touch (tens of ms
   of guest code and `workq_kernreturn` per gesture) are the next items on
   the guest-CPU side.
   *Trap frame addressed by FPS-2 (§8.3);* notifyd still open.
7. Host load from other agents (9–58 on 14 cores) adds run-queue wait to
   every thread (0.05–0.17 cores of run-queue per busy program); parity
   measurements need a quiet host.

## 8. FPS-2: frame record, dirty control, trap frame (2026-10-20)

Three changes for §7 items 1, 3 and 6, each on by default with its own
switch, and findings for items 4 and 5. Main line for the comparison:
786aef0.

### 8.1 The frame record and timing files in a memory directory

Each device has a *memory directory*: guest path `DEV/ycode-memory` (a
writable prefix of its own, so it resolves to whatever host directory the
current run chose), host directory `/dev/shm/ycode-<uid>-<16 hex digits of
the device's UDID>` (`YCODE_MEMORY_DIR=<dir>` picks another memory file
system; an absent or unwritable one, and `YCODE_FRAME_RECORD_MEMORY=0`,
use `DEV/data/tmp/ycode-memory` on the data volume). It holds the frame
record (`ycode-framebuffer.state`, whose guest path the framebuffer library
gets in `YCODE_FRAMEBUFFER_STATE`) and, with `YCODE_DISPLAY_TIMING=1`, the
three timing files of `display-stream.md` §10. The display server,
screenshots and the frame profile read the host path.

| When | What happens to the directory |
|---|---|
| cold boot | created (mode 0700) and emptied |
| while the device runs, timing on | a symbolic link of each timing file's name in `DEV/data/tmp` points into it (the analysis tools read them there) |
| snapshot (warm-boot save), all guest threads parked | its files are copied, with their modification times, to `DEV/ycode-memory.saved` (written as `.partial`, then renamed) |
| restore | emptied, then refilled from `DEV/ycode-memory.saved` before any guest thread runs (the snapshot reopens the frame record by guest path, and the times match the snapshot's records) |
| the run's end | the timing files are copied to `DEV/data/tmp`; the directory is removed (not the data-volume fallback) |
| any start | `.owner` (the process id; never saved) is written; this user's other memory directories whose `.owner` names no live process, or that have none and are over a day old, are removed (runs that were killed, e.g. by a benchmark's SIGTERM without a save, and tests) |

A restored device keeps working across a change of the switch: the guest
path does not change, only the host directory behind it. The warm-boot
fingerprint covers the simulator build, so a snapshot of an older build
(frame record in `DEV/data/tmp`) is never restored by this one. Test
`DeviceMemoryFilesTests`.

### 8.2 `proc_info` dirty control without L0

A process record's dirty bits (tracked, allows idle exit, dirty, launch in
progress) are one atomic word. `PROC_INFO_CALL_DIRTYCONTROL` (callnum 8)
with flavors 1–4 (track, set, get, clear) on the caller's *own* pid is a
BSD fast path (`bsd-locking.md` table): a running image's process is
neither a zombie nor pseudo-init and may always signal itself, so the
locked path's checks pass, and the change is one compare-and-swap, `or`,
`and` or load. Each image reaches its record's word through a small leaf
lock set when the record takes the image. Every other target, call or
flavor (including an invalid flavor's `EINVAL`) stays on the locked path,
which changes the same word. Switch: `YCODE_DIRTY_FAST=0`. The frame
profile's summary line `BSD fast paths: … proc_info dirty control without
L0: N` counts them. Test `BSDFastPathTests.dirtyControlOfItself`.

### 8.3 The trap frame read and written in place

The VMM read the 320-byte trap frame from guest memory into a byte array,
decoded it into a second array, and on resume encoded and wrote a third.
It now decodes from, and encodes into, the guest page directly (one slot
lookup each way; the lookup is repeated on resume because the handler may
have changed the VM's memory slots). The bytes written are the same
(`TrapFramePointerTests`). Switch: `YCODE_TRAP_FRAME_COPY=1` restores the
copies.

### 8.4 Measurements (Thor, paired, load average under 4 at each start)

Method: two device homes, one per arm (the branch at 687b133 and the main
line 786aef0, separate trees, the same translator and a copy of the same
GPU cache), each restoring its own snapshot; per round one session per arm,
arm order alternating, each started only with no other simulator running
and load under 4, boot slots 2–4 held. A session: restore, 25 s, then a
40 s frame-profile window over a probe (four home-screen drags alternating
left and right, Home, a drag to the Today view, a drag back, Spotlight,
Home), verification screenshots outside the window, stop (save).
"First present" is the first frame record write after an input's touch
began (frame-profile trace, the display trace's input times).

| Round (load at the probe: FPS-2 / main) | backboardd `pwrite` p99 / max | `proc_info` per call mean / p99 | VMM µs per exit | swipe interval p50 / p90 ms | first present after the drag to Today | after the drag from page 1 rightwards |
|---|---|---|---|---|---|---|
| R1 (3.0 / 3.2) | 42 µs / 46.5 ms vs 128 µs / 811 ms | 3 / 12 µs vs 16 / 242 µs | 10.72 vs 11.05 | 16.0 / 23.4 vs 15.8 / 21.8 | 141 vs 668 ms | 509 vs 755 ms |
| R2 (4.4 / 3.8) | 50 µs / 2.2 ms vs 112 µs / 830 ms | 2 / 11 µs vs 12 / 190 µs | 10.87 vs 11.74 | 9.6 / 18.1 vs 15.9 / 17.3 | 141 vs 153 ms | 262 vs 686 ms |
| R3 (4.1 / 5.0) | 37 µs / 0.1 ms vs 2982 µs / 700 ms | 5 / 10 µs vs 12 / 210 µs | 10.82 vs 11.44 | 11.8 / 17.8 vs 9.4 / 18.5 | 289 vs 326 ms | 407 vs 285 ms |
| R4 (4.3 / 3.6) | 34 µs / 0.9 ms vs 69 µs / 742 ms | 2 / 10 µs vs 17 / 253 µs | 11.13 vs 11.40 | 13.3 / 18.1 vs 15.9 / 28.0 | 169 vs 410 ms | 281 vs 286 ms |

(`pwrite` counts both the frame record and, with timing on, the swap
timing ring; 9,700–10,150 per window. `proc_info`: 34,000–57,000 per
window, about 1,000–1,400 a second, nearly all diagnosticd's dirty
control; FPS-2 served 38,800–79,900 per session without L0.)

1. **Frame stalls are gone**: in every main-line session one write of the
   frame record took 0.70–0.83 s (the frame and everything behind it on
   backboardd's render thread waited); on FPS-2 the longest took 0.1–47
   ms, p99 34–50 µs. This is change 8.1.
2. **Dirty control** is 4–6× faster on average and 17–25× at p99 (change
   8.2); it no longer queues behind L0.
3. **VMM time per exit** is 1–7 % lower in every round (all changes
   together; the switch A/B for change 8.3 alone is below).
4. **Swipe cadence** is the 60 Hz frame clock in both arms (p50 9–16 ms,
   p90 17–28 ms); no change expected or seen.
5. **Input to first present** is shorter on FPS-2 in 7 of 8 paired
   gesture measurements (the Today drag and the rightward drag; one is
   281 against 286 ms), most where the main line had a long one (668, 686,
   755 ms); the frame stalls of point 1 are the likely cause. Few samples;
   direction only.

Change 8.3 alone (one device home, FPS-2's build, arms differ only in
`YCODE_TRAP_FRAME_COPY=1`; four rounds, load 2.6–4.3 at the probe): VMM
time per exit 10.95 / 11.06 / 10.26 / 11.49 µs in place against 11.22 /
11.10 / 11.52 / 11.80 µs with the copies, lower in all four rounds (by
0.04–1.26 µs, about 3 % on average). Nothing else in the session moved
outside its spread (swipe interval p50 11–17 ms in both arms, first present
after the Today drag 146–355 ms in both arms). A small, consistent saving of VMM time; not visible in a
frame.

### 8.5 Findings for §7 items 4 and 5

**Poster extensions after a restore (item 4).** A 30 s frame-profile
window opened at the home screen, with no input (sessions `X1`–`X3`):

| Session | Boot | Poster programs running | Their CPU | All programs |
|---|---|---|---|---|
| FPS-2 `X1` | restore (8.2 s to home) | — (none in the per-program table) | 0 | 0.055 cores |
| 786aef0 `X3` | restore (6.1 s) | 19 | 0.000 cores | 0.075 cores |
| 786aef0 `X1` | cold (79 s) | 21 | 2.55 cores (PosterBoard 0.27, each extension 0.12–0.14) | 3.16 cores |
| 786aef0 `X2` | cold (45 s) | 21 | 1.93 cores | 2.98 cores |

After a restore the posters are idle on both trees; the windows 25 s after
the home screen in every A/B session show 0.000 cores for them as well.
The busy minute is now a cold-boot phenomenon (about 2–2.5 cores for the
first 30 s after the home screen; what they do then was not examined). Item 4 as written (after a restore) is not
reproduced on 786aef0; the cold-boot cost is a lead for boot work, not for
the frame path.

**Drags that do not move (item 5, and `stage8-contract.md` §14.6 item
4).** The probes' leftward drag starts at (400, 350) points. On this
device type (1398 × 2034 pixels, 466 × 678 points) that is the Safari
icon in the dock, the column at the right edge that stays in place over
the home pages and the Today view. A drag that starts there moves nothing
on the main line and on FPS-2 alike: in a probe with screenshots after
each step (sessions `X1`), from the home page and from the Today view, the
drag from (400, 350) left the screen byte-identical, while drags from
(300, 500) and (300, 120) moved the page (the latter back from Today to
the home page). Whether the reference also ignores a page drag that
starts on a dock icon is a question for the reference (Q1 below); Ycode's
input path delivers such a drag like any other (`HIDInputBridge`, no edge
mark that far from an edge). Consequences for measurements:
- the "input → first frame" of `ycode-display-probe` charges such an input
  with the time to the next input's frame (1.08–1.56 s in these sessions:
  the next drag 1.05 s later); this is the 1.5–2.9 s "Today stall" of item
  5 and FPS-GPU's R4 outlier, not a slow frame;
- home-screen probes should start leftward drags outside the dock column
  (x below about 370 points) or measure per input to the first present.

Questions for the reference (black-box, for the dirty room):
1. On an iPhone simulator of this device type, does a horizontal drag that
   begins on a dock icon page the home screen (or leave the Today view)?

### 8.6 Cold boot to the home screen (idle host)

The bench harness (`bench.sh`: a copy of the pristine device in RAM, home
by screenshot brightness every 5 s), one boot at a time, load under 4 at
each start, slots 2–4 held:

| Tree | home_s |
|---|---|
| FPS-2 (687b133) | 105, 110 |
| main line 786aef0 | 110, 115, 120, 115 |
| 2081188 | 120, 120 |
| 897bf3e (after the APP-LAUNCH merge) | 110, 125 |
| bc29655 (before it) | 75, 70 |
| 391af58 (FPS-GPU's base, its own build and GPU cache) | 75, 70, 75, 80 |
| 786aef0 with 391af58's GPU cache | 120, 110 |
| 786aef0, `YCODE_CACHE_IMAGE_FILES=0` | 125, 130 |
| 786aef0, `YCODE_LAZY_ANON_MB=0` | 110, 110 |
| 786aef0, the copy's `ycode-device-path` set to its own path before the boot | 75, 70 |
| 786aef0, the same harness without that (paired) | 120, 125 |

FPS-2 does not change cold boot. The main line's 110–125 s against the
65–80 s of earlier measurements is the relocated-device rule of
`app-launch.md` §3.3 (merged with APP-LAUNCH): the harness boots a copy of
the pristine device at a new path every time, so every boot removes the
LaunchServices store and lsd rebuilds it, about 45–50 s on the boot's
critical path. A device booted again at its own path does not pay it (a
cold boot of an already-booted device in place took 45 s). Not load, not
the GPU cache, not the cache-only image files or lazy anonymous memory.
Benchmarks that compare with numbers from between the APP-LAUNCH merge
and the change below must account for it.

**Resolved (2026-10-23, BENCH-LS).** A copy keeps the guest path its data
was first booted at, and the VMM serves that path from the copy
(`app-launch.md` §3.3), so a copy's stores stay valid and nothing is
rebuilt. Idle-host boots of the same harness, a RAM copy of the pristine
device per boot (5 s frame resolution), each started with no other
ycode-simd and load under 4 while holding the machine (`timed.sh`; the last
seven in one held series, which took boot slot 1 itself):

| Tree | Rule at the boot | home_s |
|---|---|---|
| main line f028dd5 (IDE build) | both stores removed, lsd rebuilds | 100, 105, 105, 100 |
| f028dd5 + the guest path (BENCH-LS) | the copy keeps its guest path, no store removed | 70, 60, 65, 60 |
| the same, the copy's record set to its own path over the copied store | the device store removed (the system-only store kept), lsd rebuilds | 95 |

Before the series, under more load (other agents' boots between runs):
f028dd5 220 (first boot after the data drive was remounted: cold page
cache) and 105; with the IDE build and only the device store removed (the
system-only store kept, the record set by hand) 110, against 105 for both
stores removed. lsd rewrites the system-only store as well when it
rebuilds (both files had new sizes and times after such a boot), so keeping
it saves nothing; the cost is the reseed itself. The guest path makes a
benchmark copy 35–45 s faster and brings it back to the 60–75 s of the
measurements before the APP-LAUNCH merge. Functional boots of copies with
the change (Settings; Safari with a `data:` page) launched and drew the
app; Safari wrote into the copy's own data container and nothing was
written under the original's directory.

## 9. Boot windows and critical paths across process starts (2026-10-23, agent BOOT-CP)

Used by `boot-profile.md` §8. With the variables unset nothing changes;
with `YCODE_FRAME_PROFILE` set and no window open, the new events cost what
the old ones do (one load and a nil check).

| Variable | Default | Meaning |
|---|---|---|
| `YCODE_FRAME_PROFILE_BOOT` | unset | open window 1 before the root process is spawned, for at most this many seconds (≤ 900) |
| `YCODE_FRAME_PROFILE_BOOT_TAIL` | 3 | close the boot window this many seconds after the home screen is first seen |
| `YCODE_FRAME_PROFILE_SCHED_MS` | 200 | while a window is open, sample every vCPU host thread's scheduler counters this often (0: off) |
| `YCODE_HOME_WATCH` | unset | `1`: log the first home-screen frame (no trace; works without `YCODE_FRAME_PROFILE`) |

Event kinds added to §1's list (same 32-byte record):

| Kind | Name | pid / tid | arg | trap |
|---|---|---|---|---|
| 8 | start request | the requester (pid 0: a host thread, tid its Linux tid) | the new thread: pid << 32 \| trace id | 1 for an image's main thread |
| 9 | image launch | the requester | pid << 32 \| 1 when launched suspended | the image's serial |
| 10 | lock wait | the waiter (pid 0: a host thread) | ns waited (contended acquisitions only) | 0 L0, 1 event lock, 2 port lock |
| 11 | surface check | 0 / the surface id | dark samples (‰) << 32 \| mean brightness × 100 | the frame counter |
| 12 | scheduler sample | the image / the host thread's Linux tid | run-queue ns (cumulative) | CPU µs (cumulative, mod 2³²) |
| 13 | bind | the guest thread | the Linux tid of the host thread it now traps on | 0 |

Guest thread ids in the trace are *trace ids*: the guest thread id in the
low 24 bits and an image tag in the high 8 (the image serial's low byte,
set when the image's main thread is started inside a window; its other
threads take the main thread's tag). An exec keeps the pid and starts a new
main thread with id 1; without the tag the old and the new main thread were
one thread to the analysis, and the old one's exit work (wakeups on its
host thread) looked like wakeups by a thread that was asleep.

`<path>.<n>.names` also lists `image <pid> <serial> <time ns> <program>` for
every image launched in the window (an exec gives a pid a new program) and
`start <window open ns> <process start ns> <home ns>`; host threads are
named when they are first seen (a service thread may have ended by the
window's end).

Analysis (`scripts/ycode-frame-profile`; the options are listed in its
header): `--boot`, `--launch P`, `--backbone P:main`, `--thread P[:kind]`
with `--long-ms`, `--anchor P`, `--edges N`, `--stop-at S`. Rules of the
walk beyond §2 item 7: a wait woken by the thread itself (a deferred wakeup
it ran as it released the lock to sleep) is the thread's own trap time; a
wakeup recorded after the time being walked is treated as a timed wait;
a thread started by a host thread (a timer, a service) continues on the
same process's last trap before the start ("timer: P (thread start)").

## Evidence

| Claim | Level | Source |
|---|---|---|
| The trace, its format and the analysis (§1, §2) | — | Ycode design |
| Which traps, waits and wakeups make up a frame (§4, §6) | 3 | frame-profile windows of Ycode's simulator on the Thor (black-box observation of the guest programs' traps); runs `r1`–`r3`, `c1`, `c2`, `ab2`, `ab3` |
| `PROC_INFO_CALL_DIRTYCONTROL` = 8, `mach_msg2` argument packing | 1 | xnu `bsd/sys/proc_info.h`, `osfmk/mach/mach_traps.h` (open source) |
| KVM runs every VM's MMU notifier on a change of the host mapping it registered; ext4 writes can wait for a journal commit | 1 | Linux KVM and ext4 documentation and source |
| The shared arena, BSD fast paths, lock split, timer thread (§5) | — | Ycode design (`boot-profile.md`, `bsd-locking.md`, `mach-ipc-locking.md`) |
| The memory directory, dirty-control fast path, in-place trap frame (§8.1–§8.3) | — | Ycode design |
| `PROC_INFO_CALL_DIRTYCONTROL` flavors 1–4 (track, set, get, clear) and their checks | — | as Ycode's locked path, `processes.md` §2.11 (its evidence there) |
| Frame-record write stalls, dirty-control latency, VMM time per exit, first-present latencies (§8.4) | 3 | paired sessions `ide-remote/fps2{,-base}/out/R1–R4`, `T1–T4` (Ycode's simulator on the Thor) |
| Boot windows, event formats and walk rules (§9) | — | Ycode design |
| Cold boot times and the relocated-device rebuild (§8.6) | 3 | `bench.sh` boots of the trees named there, `SX/FPS2*/runs/` (Ycode's simulator on the Thor) |
| Cold boots with the guest path, the baseline and the rebuild cases, keeping the system-only store (§8.6) | 3 | harness boots `SX/IDE/runs/bench-ls-base-*`, `bench-ls-e1-*`, `SX/BENCHLS/runs/t1`–`t4`, `reloc-t1`, functional runs `func-settings-1`, `func-safari-2`, `func-reloc-safari-2` (Ycode's simulator on the Thor, 2026-10-23/24) |
| Drags from the dock do not move the page in Ycode; poster CPU after boots and restores (§8.5) | 3 | sessions `X1`–`X3` with screenshots (Ycode's simulator) |
| Recording, GPU and feedback-copy costs of the render server after GPU-2 (§7 item 2) | 3 | timed A/B series `ide-remote/gpu2/out/R1a`–`R3c`, `S1a`–`S3c` (Ycode's simulator on the Thor, frame trace with GPU segments); method in `stage8-contract.md` §15.7 |
| GPU completion wait and bytes per present after FPS-GPU (§7 item 2) | 3 | paired frame-profile sessions `ide-remote/fpsgpu{,-base}/out/R1–R4` (Ycode's simulator on the Thor); method in `stage8-contract.md` §14.5 |

No Apple binary, Apple source other than the open-source xnu headers
named above, or `research/` material was used (levels 2, 4 and 5 not
used).
