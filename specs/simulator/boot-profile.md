# Spec: boot profile, and host memory work off the kernel lock

Status: **implemented 2026-10-17 (agent PROF)**. §1 is a diagnostic
(off by default). §3 lists four changes; each has a switch, and §4 says
which are on by default and why. Measurements are in §2 and §4. §6
(agent PROF3, 2026-10-19) compares the Mac and Ycode process by process
and adds C21. §9 (agent SPAWN, 2026-10-23) measures process creation and
adds SP1–SP4. §12 (agent B3-BOOT, 2026-11-05) measures the log path and the
UI path's CPUs against the reference's logging path (§13), and finds a
10 s that guest networking and the Duo's inner panel added since
2026-10-27. §14 (agent B3-BOOT2, 2026-11-06) finds that networking's share
was apsd reconnecting to the push courier about three times a second
(a missing host-side name; Ycode now registers it) and that the inner
panel's is SpringBoard's own work for a second display. §15 (agent
B3-SIMOBS2, 2026-11-06) observes the reference's identity service and the
guest programs behind Ycode's excess log volume. §18 (agent B3-BOOT4,
2026-11-06) finds LaunchServices sound (its excess is two log categories
and lsd waiting for containermanagerd's start), mobile-asset extraction
failing on decmpfs files, and measures an opt-in hold of failed look-ups
that reproduces dasd's quiet phase (−5.6 s).

This is Ycode's own design. It names no Apple internals. The Linux facts
(KVM memslots, `mremap`, transparent huge pages, `/proc` accounting) come
from the Linux KVM API documentation and the Linux man pages (level 1);
the Arm facts from the Arm Architecture Reference Manual. Lock rules are
those of `stage6-contract.md` §5 and the performance contract (C1–C14 in
`performance-contract.md` §6; this spec adds C15–C18).

## 1. The boot profile (`YCODE_BOOT_PROFILE=<path>`)

A diagnostic that answers "where does the wall time of a boot go". It
changes no guest-visible behaviour. With the variable unset nothing below
runs and no counter is taken.

### 1.1 Per-image table (written to `<path>` when the run ends by itself)

One row per process image (an exec makes a new image under the same pid):

| Column | Meaning |
|---|---|
| `launch_s` | when the VMM started building the image (seconds since the run began) |
| `build_ms`, `first_run_ms` | image build time; time to the first guest instruction |
| `milestone_ms` | time to the libSystem milestone (`host-libraries.md` §8.1): the end of the loader's work (`dyld_sim`) in this process |
| `m_*` | at the milestone: traps made, kernel-lock wait and hold of the image, the main thread's CPU (total, guest mode, host kernel), its wall time inside `KVM_RUN` and inside trap handlers, and the six most frequent trap numbers before the milestone (`m_top_traps`, faults as −1000) |
| `end_s`, `life_s`, `teardown_ms` | end of the image, its life, the time to tear it down |
| `cpu_s`, `user_s`, `sys_s`, `guest_s`, `runqueue_s` | summed over the image's vCPU host threads (read from `/proc/self/task/<tid>/{stat,schedstat}` when each thread returns): CPU time; user time (guest mode included); host-kernel time (KVM exits KVM handles itself, such as stage-2 faults, and the VMM's system calls); guest-mode time; time runnable but waiting for a CPU |
| `kvm_run_s`, `handler_s` | wall time inside `KVM_RUN` and inside the trap handler (lock waits and blocking waits included) |
| `user_exits`, `kvm_exits`, `wfx_exits` | exits to the VMM; all exits as KVM counts them (`KVM_GET_STATS_FD`, statistic `exits`; the difference is exits KVM handled in the kernel); WFI/WFE exits |
| `lock_held_ms`, `lock_wait_ms`, `lock_acq` | kernel-lock hold and wait time on behalf of the image's threads |
| `starts`, `start_wait_ms` | guest thread starts, and the time from the start request to the thread's first instruction (vCPU creation or wakeup) |

A second table sums the rows by program name. The header lines give the
host-memory calls made inside traps (§3: memslot additions, file-window
maps, file copies, discards, zero fills; count, time, bytes), the file
arena's huge-page copies (§3.4), and the process's `Rss` and
`AnonHugePages`.

### 1.2 Samples (`<path>.samples`)

Every `YCODE_BOOT_PROFILE_INTERVAL_MS` (default 500) one line: the whole
process's CPU in the interval split into guest mode, host kernel and VMM
user code (in cores); host threads runnable (R) and in uninterruptible
sleep (D); guest threads in guest code, in a trap handler, and blocked in a
kernel wait; the kernel-lock busy share; live images; the eight images that
used the most CPU in the interval; and any vCPU busy in one trap handler
for 200 ms or more (program, pid, trap number, age).

### 1.3 Guest PC samples (`YCODE_BOOT_PROFILE_PC_HZ=<n>`, `<path>.pcs`)

`n` times a second every vCPU that runs guest code is kicked out of
`KVM_RUN` (the existing diagnostic kick) and its PC is recorded, then
attributed to the main executable, `dyld_sim`, or a shared-cache image by
the cache's image list (others: "other"). The report lists the share of
samples by image, by program and image, and the hottest 4 KiB buckets.
Only offsets and image names are reported; nothing is symbolized.

## 2. Where the time goes (main line 64ced04, Thor, 2026-10-17)

Five profiled full boots (harness, device in RAM, 450 s, two boots at a
time; `SX/PROF/runs/p1–p3`, `SX/PROF/c1/runs/q1`, `SX/PROF/c4/runs/t2`).
"Home" is the harness's criterion: the first frame with the wallpaper.

1. **The boot is a chain of process starts, not a CPU-bound load.** The
   whole host process used 2–3 cores on average (guest mode about 1.5,
   VMM code 0.5, host kernel 0.35) of 14; 3–15 host threads were runnable.
   One or two programs start at a time: launchd_sim alone for the first
   4–5 s, SpringBoard's start, then late in the boot PosterBoard starts
   about 20 poster extensions one after another (each about 5–6 s), and
   the wallpaper follows.
2. **A process start is the loader's phase** (`milestone_ms`): an app
   extension took 5.2–5.9 s from launch to its libSystem initializer,
   SpringBoard 16–21 s, backboardd 3.6–4.6 s, xpcproxy_sim 25–400 ms.
   For an app extension: about 3,850 traps, of them about 1,240 each of
   `stat64` (338), `vm_allocate` (−10) and `vm_deallocate` (−12); the main
   thread's CPU 3.0 s, 2.9 s of it in guest mode; **kernel-lock wait about
   2.0 s** (about 0.5 ms per trap).
3. **Guest CPU: 68 % of all guest-mode samples are in `dyld_sim`**
   (`YCODE_BOOT_PROFILE_PC_HZ=50`, 43,783 samples), in a 20 KiB range of its
   text; then libswiftCore 4.9 %, libobjc 4.4 %, libsystem_malloc 2.8 %,
   CoreFoundation 2.3 %.
4. **Kernel lock**: held 207–229 s of 470 s (44–48 % busy); summed waits
   3,900–4,200 thread-seconds; contended acquisitions 33 %, mean wait
   300–550 µs for every trap kind. Holder samples: running 68 %, blocked
   in the host kernel 32 % (`__synchronize_srcu` 6.8 %: memslot changes;
   `mmap_region`, `vm_mmap_pgoff`, `lock_mm_and_find_vma` 12.7 %: the host
   process's mmap lock; `do_madvise` 5.2 %; page-cache waits 4.1 %).
   Host-memory calls inside traps per boot: about 4,000 file memslots
   (8–10 s), 4,800–5,500 shared-object memslots (9–11 s), 30,000 discards
   (8.6–9.9 s).
5. **The first 4 s of every boot**: launchd_sim's first `fsgetpath` (427)
   walked the runtime volume with a Foundation enumerator and `lstat` of
   every entry, 4.1 s, on the critical path (everything waits for
   launchd_sim). The full shared-cache image index takes 38–650 ms and was
   not the cause.
6. **Not on the critical path**: image builds 1–3 ms (prebuilt VMs); first
   guest instruction about 1 ms after launch; VM teardown off the lock;
   GPU (Metal compiler service late, a few CPU seconds). Thread starts
   waited 105–136 s summed over all threads (vCPU creation, 11 ms on
   average), spread over many processes. In-kernel KVM exits (stage-2
   faults, interrupts) 12.6–16 M per boot, host-kernel CPU 135–155 s.

## 3. Changes

### 3.1 C15: the milestone does not wait for the full cache index

The VMM checks every trap before the libSystem milestone against the
images it is waiting for (the cache's `libsystem_*` images and
`libSystem.B`, and Ycode's host libraries). It now reads a small list of
just those images (a few dozen Mach-O headers) instead of the full list
of every cached image. The full list (used by fault reports and traces) is
built on a background thread at start (`YCODE_CACHE_INDEX_PREWARM=0`: on
first use). The index has three locks (load, small lists, full list), so
the full parse never blocks a milestone check. Behaviour is unchanged: the
milestone is reached at the same trap.

### 3.2 C16: the private file window (`YCODE_PRIVATE_FILE_WINDOW`)

Before: a writable private file mapping larger than 1 MiB (the shared
cache's writable mappings in every process, regions made writable by
`mprotect`) got a host `mmap` of its own and a KVM memslot of its own.
Adding a memslot waits for an SRCU grace period of the VM; under load that
is milliseconds, under the kernel lock.

Now each VM gets one more memslot when its backing is made (off the
kernel lock, in the prebuilt VM; `stage6-contract.md` §5.3): a 64 GiB
inaccessible host reservation at GPA `0x20_0000_0000` (the start of the
file range; per-mapping slots follow it). A mapping is placed in it with
`mmap(MAP_FIXED | MAP_PRIVATE)` of the file (and anonymous zero pages for
the tail), bump-allocated, never reused while the VM lives (as per-mapping
memslots were). Guest-visible behaviour is identical: the same bytes,
private copy-on-write, zeros past the end of the file. KVM follows the
host mapping through its MMU notifier, so no memslot change is needed.
When the window is full a mapping falls back to its own memslot.

Two rules keep the window correct when a mapping reaches the end of its
file (FIXINST, 2026-10-19):

- The file part of a window mapping covers whole **host** pages: the
  bytes of the file's last host page past the end of the file read as
  zeros (host `mmap` semantics), and the anonymous zero tail starts at the
  next host page boundary. A tail placed right after the last file byte
  is not host-page aligned, and `mmap(MAP_FIXED)` refuses it with EINVAL.
  The guest saw that as ENOMEM from `mmap` (dyld: "Library not loaded …
  mmap(size=…) failed with errno=12").
- This path is taken by every read-only file mapping the shared read-only
  arena cannot serve. The arena holds at most `maximumFiles` distinct
  files (by device, inode, size and mtime; spans are never reused). A
  cold boot that installs an app passed the earlier limit of 4096 files
  (the install makes LaunchServices and its clients load many plug-ins and
  rewrite data files, each new version a new span), so from about 120 s
  on every image larger than 1 MiB that ends inside a host page failed
  to load: 70–250 daemons per boot aborted in dyld, SpringBoard and the
  render server's clients crashed in turn, and the home screen was never
  reached. The limit is now 32768 (`YCODE_ARENA_MAX_FILES` overrides it
  for diagnostics); the arena logs once when it first refuses a file, and
  a full arena only costs speed.
- Verified on the Thor (cold boots, `--install-app`/`--launch` of the
  probe app): full boot home 255/255/215 s, launched 255/255/215 s; lean
  boot (`YCODE_LEAN_BOOT=daemons`) home 170/175/200 s, launched
  140/145/200 s; 0 mapping failures; no install: home 145/125/165 s. With
  only the tail fix and the old 4096 limit (arena full at boot) the
  same boot reached home at 220 s and launched the app.
- Diagnostics: the first 40 guest mappings that fail for a host-side
  reason (backing or page tables) are logged with the underlying error
  (`guest mapping failed: …`).

### 3.3 C17: pool memory is dropped after the trap (`YCODE_DEFERRED_DISCARD`)

Before: releasing anonymous pool memory larger than 256 KiB (and flushing
the 4 MiB stale list) called `madvise(MADV_DONTNEED)` under the kernel
lock. That takes the host process's mmap lock and KVM's MMU notifier
(stage-2 unmap and TLB invalidation) and averaged 0.33 ms, with long tails.

Now, when the releasing thread is a vCPU thread of the same VM, the run
stays **allocated** in the pool, and the thread drops it after its trap
handler returned (no kernel lock held), then puts it on a ready list
(a leaf lock). The next allocation in that pool (under the kernel lock)
first frees the ready runs. Invariants:

- A run is never handed out before its pages are dropped (it is allocated
  until then).
- The VM is open while the work runs: only a vCPU thread of the same VM
  queues it, it runs on that thread before it re-enters its run loop, and
  a VM is closed only after all its vCPU threads were joined.
- Releases from any other thread (another process's trap, a service
  thread) drop at once, as before.
- Lock order: kernel lock → ready-list lock (leaf). The work itself holds
  only the leaf lock, briefly.

### 3.4 C18: huge-page copy of the shared cache in the file arena (`YCODE_ARENA_HUGE`)

The file arena (`SharedFileArena`, stage 6) maps each read-only file once
into a reservation that every VM registers as one read-only memslot. Its
pages are page-cache pages, so KVM maps them with 4 KiB stage-2 pages: a
new process takes one stage-2 fault per 4 KiB of the cache it touches, and
a guest TLB entry covers at most 4 KiB of a 16 KiB guest page.

With the switch, a file of at least 256 MiB (the shared cache files) gets
a 2 MiB-aligned span (the arena base is 2 MiB-aligned), and a background
thread:

1. allocates anonymous memory, 2 MiB-aligned, with `MADV_HUGEPAGE`;
2. fills it with the file's bytes (`pread`, four threads) and zeros past
   the end of the file;
3. makes it read-only;
4. moves it over the span with one `mremap(MREMAP_MAYMOVE |
   MREMAP_FIXED)`.

The move replaces the file mapping atomically for every reader (the VMM
and, through the MMU notifier, every VM); both hold the same bytes. Later
stage-2 faults map 2 MiB blocks (KVM maps a block when the host mapping is
a PMD-sized huge page and the memslot offsets agree modulo 2 MiB). The
copy costs the cache's size in host memory (3.3 GiB) once per host
process. A failure at any step leaves the file mapping as it was.

### 3.5 C19: one memslot for every shared memory object (`YCODE_SHARED_WINDOW`)

Shared memory objects (Mach memory entries, POSIX shared memory, shared
file views, IOSurface backing; `SharedMemory.swift`) are host memory that
several VMs map. Before, each VM that mapped an object added a memslot for
it (one SRCU wait under the kernel lock, about 1.6 ms each; 4,700–5,500 per
boot).

With the switch, objects take their host memory from one 128 GiB host
reservation (`SharedObjectArena`, 2 MiB-aligned): a first-fit run, mapped
private anonymous (or, for a file view, `MAP_SHARED` of the file, with
zero pages past its end) with `MAP_FIXED`. Every VM registers the whole
reservation once, when its backing is made, as one memslot at GPA
`0xC0_0000_0000` (above the read-only file window; the per-mapping file
slots stay below that window). Mapping an object into a VM is then
`0xC0_0000_0000 + offset`: no memslot change. The host memory is the same
kind as before (private anonymous), so the GPU's host-pointer imports see
the same memory. Invariants:

- A run is freed only when the object is destroyed, and an object lives
  while any VM that mapped it lives (the backing keeps it), so no VM can
  see a reused run through an old mapping.
- Freeing makes the run inaccessible again (`MAP_FIXED` reservation),
  which drops its pages; KVM's MMU notifier removes every VM's stage-2
  entries for it.
- A VM never maps a part of the arena its address space did not map
  (stage-1 tables only point at objects the process maps), as before.
- When the arena is full or not registered, an object gets its own host
  mapping and memslots as before.

### 3.6 C20: task-local traps without the kernel lock (`YCODE_TASK_LOCAL_TRAPS`)

A process start makes about 3,800 traps before its libSystem initializer
runs; almost all are `stat64` (the loader probes each library path on
disk), `vm_allocate` and `vm_deallocate` (a scratch buffer per library),
about 1,240 of each for an app extension. Each waited about 0.5 ms for the
global kernel lock (§2), about 2 s per process start.

With the switch, these traps run on the trapping thread's host thread
without the kernel lock:

| Trap | Done without the kernel lock |
|---|---|
| BSD 338 `stat64`, 340 `lstat64` | read the path (guest memory), resolve and `stat` it (`DarwinFileSystem`, already safe without the lock, stage 6 §5.1), write the 144-byte result |
| Mach −10 `vm_allocate` with `VM_FLAGS_ANYWHERE` | read the address word, map anonymous memory anywhere (one address-space change), write the address word |
| Mach −12 `vm_deallocate` | unmap the range (one change) |
| Mach −14 `vm_protect` of the current protection | change the protection (one change; a shared read-only file view made writable moves to a private view, as before) |

The answers (results, errors, `kern_return_t` values) are the locked
path's, byte for byte. Rules:

1. A task-local trap touches only its own process's address space (through
   its mutex L1, which every change of the space takes) and the host file
   system through path resolution. It reads or writes no state the kernel
   lock guards and never blocks.
2. Every kernel path that reads the address space and then changes it on
   what it read (`vm_allocate` and `mach_vm_map` at a fixed address
   without `VM_FLAGS_OVERWRITE`: check, then map) holds L1 across both
   steps, so a concurrent task-local allocation cannot slip in between.
3. Fixed-address `vm_allocate`, `vm_protect` with `set_maximum`, traced
   images, an image that is ending, and a thread not bound to the image
   take the locked path.
4. Before the image's libSystem milestone, a trap whose return address is
   in a libSystem image takes the locked path (the milestone is recorded
   there).
5. Lock order is unchanged (L0 → L1 → leaves); task-local traps take no L0.
   No wakeup can be lost: they wake no one and wait for nothing.
6. A changed address space sets the frame's TLB-flush bit as before; the
   shim's flush is inner-shareable, so every vCPU of the VM sees it.

## 4. Measurements (Thor, 2026-10-17/18)

Harness full boots, device in RAM, two at a time; home_s at 5 s
resolution. Machine load from other agents varied (load average 10–23).

### 4.1 Per change (profiled boots)

| Change | Measured effect |
|---|---|
| Object-id walk (readdir + `d_ino`) | launchd_sim's first `fsgetpath` 4.1 s → 0.9 s (warm directory cache) to 3 s (cold, I/O-bound) |
| C15 cache index | full index 38–650 ms on a background thread; milestone checks never wait for it |
| C16 private file window | about 4,000 file memslot additions (8–10 s under the lock) → window maps, 1–2 s; home_s unchanged in one paired run (q1 280, q2 280) |
| C17 deferred discards | 15,500–18,000 of 28,000–31,000 discards (8–12 s) leave the lock |
| C18 huge-page arena | in-kernel exits −33 %, but the copy took 74–82 s (direct compaction of 1,700 huge pages) and slowed host `mmap` calls meanwhile; guest time per process start unchanged. **Stays off** |
| C19 shared object arena | 4,800–5,500 shared-object memslots (9–11 s) → 0 |
| C16+C17+C19 (r2) | lock held 207 → 172 s, summed lock wait 4,100 → 2,860 s; home 265 |
| + C20 task-local traps (t1 against t2, the same build, at the same time) | app-extension start (launch to libSystem initializer, mean of 53–59) 5.86 → 3.30 s, its lock wait 2,159 → 29 ms; SpringBoard 20.7 → 14.7 s; backboardd 4.55 → 1.65 s; PosterBoard 5.1 → 3.7 s; lock held 213 → 174 s; summed lock wait 3,903 → 2,396 s; **home 280 → 235** |

### 4.2 Main line against the new defaults (C15–C17, C19, C20 on; C18 off)

Three paired rounds, main line (`SX/PROF/base`, 64ced04) and the new
build (`SX/PROF/c5`) started together each round:

| Round | Main line | New defaults |
|---|---|---|
| 1 | 265 | 170 |
| 2 | 265 | 210 |
| 3 | 280 | 220 |
| mean | 270 | 200 (−26 %) |

Ablation, the new build with `YCODE_TASK_LOCAL_TRAPS=0` against its
defaults, two paired rounds: 295/250 (mean 272) against 175/215 (mean
195). Most of the gain is C20; C16, C17 and C19 alone are within noise of
the main line (they remove 25–30 s of lock hold, §4.1).

Every boot reached the home screen; no host crash; `guest_fatal` 29–31
(main line) and 17–27 (new defaults). Unit tests: kernel, ABI and simd
suites on the Thor and the full suite on the x86-64 workstation pass.

### 4.3 What remains

The loader's own work is now the largest piece of a process start: 2.9 s
of guest CPU per app extension, 68 % of all guest CPU in `dyld_sim`
(§2 item 3). Ycode cannot change that code; why it costs this much here
(compared with the Mac, where a whole boot uses about 500 CPU seconds for
about 280 programs) needs a separate study of what the loader does per
library (§2 item 2: three traps per library). Next, by size: the
kernel-lock holds of Mach IPC (`mach_msg2`, `workq_kernreturn`,
`kevent_id`: about 55 s), the cold-cache object-id walk at boot (up to 3 s;
a background walk at start would hide it), and thread-start latency
(vCPU creation).

## 5. Where the loader's guest CPU goes (2026-10-18)

### 5.1 Method

- Guest PC samples (§1.3) now also record the return-address chain:
  when the sampled vCPU stops for the kick, its own host thread reads up to
  eight frame-pointer records (16 bytes of guest stack each) through the
  address space; the report `<path>.loader` lists "PC LR RA1 … RA8"
  offsets inside `dyld_sim` with their counts.
- The offsets are named from `dyld_sim`'s own symbol table (`llvm-nm`,
  binary metadata, level 4). No instruction was disassembled or
  decompiled. The meaning of the named functions comes from Apple's open
  source dyld (apple-oss-distributions/dyld, level 1).
- A probe (`SimShim/guest-tests/stageperf/p_cpu.c`, original Ycode code)
  measures guest code speed against the same source built for the host.

### 5.2 Results

One boot at 100 samples per second (`SX/PROF/c8/runs/d2`), 72 % of all
guest samples in `dyld_sim`. Inclusive shares of the `dyld_sim` samples:

| Function (from the symbol table) | Inclusive |
|---|---|
| `dyld4::JustInTimeLoader::loadDependents` (its per-dependent block) | 73 % |
| `dyld4::JustInTimeLoader::matchesPath` | 82 % |
| `mach_o::Image::makeFromDyldMapped` | 59 % |
| `mach_o::Header::forEachSegment` | 50 % |
| `mach_o::Header::installName` / `dylibInfo` | 17 % |
| `mach_o::Header::forEachLoadCommand` | 88 % (31 % self) |
| `dyld4::Loader::getLoader` (path variants) | 27–36 % |

What the open source says these do: for every dependent with an absolute
path, `loadDependents` scans the list of loaded images and calls
`matchesPath` on each until one matches. `matchesPath` compares the path
string and, when the loader's path differs from its image's install name
(`altInstallName`), compares the install name read from the mapped
header; in this build that builds an image object from the header, which
walks its load commands and segments. A shared-cache library's loader
path in a simulator process is the sim root (`DYLD_ROOT_PATH`) plus the
load path, so every cache library has `altInstallName` set, and every
mismatch costs a header walk: O(dependencies × loaded images × load
commands) per process start, about 2.4 s of guest CPU for an app
extension that loads about 1,240 libraries.

### 5.3 What is not the cause

| Hypothesis | Finding |
|---|---|
| Guest code runs slowly | `p_cpu`: integer loop 1.540 ns per iteration in the guest and 1.541–1.574 on the host; pointer chase 10.0 against 7.7–9.3 ns; 1,280-line chase 6.0 against 4.3–4.5 ns (nested translation costs about 1.4× on misses, nothing more); walking one cached header's load commands to `LC_ID_DYLIB` 55 ns |
| Page faults counted as guest time | Stage-2 faults are host-kernel time (`sys_s`); the samples are in load-command loops, not in fault paths |
| A spin on a field Ycode never sets | No: the samples are the header walks above |
| Missing prebuilt loaders | `dyld_sim`'s symbol table has no prebuilt-loader code (only `RuntimeState::inPrebuiltLoader`), so it always uses just-in-time loaders, on the Mac too |
| A failing cache check | The simulator branch of `getLoader` takes the cached copy (one `stat` of the sim-root candidate per library, then the cache), as the open source describes for every simulator process |
| The sim root itself (AMFI bit 1) | With `amfi_check_dyld_policy_self` answering 0xFD (no path variables) `dyld_sim` faults in `strlen` (NULL) right after mapping the cache: it needs the sim root. Not an option; Ycode keeps 0xFF, as the Mac's policy must be (the host dyld refuses a simulator program without a root path) |

The loop is the loader's own algorithm and Ycode runs it at native speed.
The Mac runs the same code (a Mac boot uses about 500 CPU seconds in its
first 120 s for about 280 programs, `parity-ladder.md` §3.1, which fits a
loader cost of this size per start). Ycode-side levers are therefore fewer process starts (the
restart loops of `parity-ladder.md` §3.3), more process starts at once
(§5.4), and not re-running the boot (`snapshot.md`).

### 5.4 Guest CPU count

With the lock waits gone, an app extension's start is CPU-bound on one
thread, and the poster extensions start about two at a time. Telling the
guest it has 8 CPUs (`YCODE_GUEST_CPUS=8`) instead of 1 did not change
home_s: two paired rounds, 190/255 (1 CPU) against 230/225 (8 CPUs),
`guest_fatal` 24–28 in both. The default stays 1.

## 6. Why the Mac does not pay the loader cost on the critical path (2026-10-19)

§5 left a contradiction: an app extension's start costs about 2.4 s of
`dyld_sim` CPU, PosterBoard starts about 20 poster extensions before the
wallpaper appears, and yet the Mac reaches the home screen in about 21 s
(subsequent boot). This section compares the same processes on both
platforms (agent PROF3).

### 6.1 Setup

- Mac: macOS 27.2 (26B5112a), Xcode 27.1 (27A9269), iOS 27.1 simulator
  runtime 24A94401, device type iPhone Duo, throwaway devices
  `ycode-test-prof3-*` (deleted afterwards). The host was shared and heavily
  loaded throughout (load average 200–950, three to four other simulator
  devices booted by other sessions), so Mac wall times are upper bounds and
  CPU times are the comparable figure.
- Ycode: the Thor, branch `prof2` (main line 65ef9fe plus §6.4), harness
  boots of the golden device (subsequent boots, device in RAM).
- The Mac runs the runtime's own prebuilt cache
  (`RR/System/Library/Caches/com.apple.dyld/dyld_sim_shared_cache_arm64`;
  the host keeps locally built caches only for the 26.x runtimes), the same
  file Ycode maps. Its header: `simulator` set, `dylibsExpectedOnDisk`
  clear, `locallyBuiltCache` clear (level 2).
- Probes (original Ycode code, `SimShim/guest-tests/stageperf/`):
  `p_load` (images and time at `main`; `deps <macho>` dlopens a program's
  direct dependencies) and `libp_loadtap.dylib`, inserted with
  `DYLD_INSERT_LIBRARIES` (Mac: `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` with
  `simctl spawn`; Ycode: `--exec <program> --env ...`). The tap's
  initializer runs once the loader has loaded the whole closure, prints the
  image count, the time since the kernel's process start time and the
  process CPU, and ends the process, so the program's own code never runs.
- Timelines: `tools/mac-sim-ext-timeline.py` (Mac process first/last seen,
  CPU, home_s); `launchd.log` "Successfully spawned" lines on both; guest
  `log show` (Mac) and `log stream` one-shots (Ycode) for PosterBoard
  (`category == "DataStore"`) and runningboardd (`category == "job"`).

### 6.2 The same process on both platforms

| Program | Images (Mac / Ycode) | Mac: loader CPU | Ycode: launch to tap (= CPU; guest part) |
|---|---|---|---|
| `p_load` (probe) | 46 / 46 | 0.02 s | — |
| backboardd | 449 / 449 | 0.42–0.45 s | 1.42 s (0.38 s) |
| poster extensions (Gradient, Collections, Calendar, Emoji, Photos, Mercury, GradientBackground) | 868–974 / identical per program | 1.9–2.4 s (light load), 2.7–3.9 s (heavy load) | 3.7–4.1 s (Mercury: 2.7 s) |
| PosterBoard | 1,277 / 1,277 | 1.9–3.1 s | 4.3 s (3.1 s) |
| SpringBoard | 1,474 / 1,474 | 4.9–6.2 s | 8.3 s (7.0 s) |

The image lists are the same, so the loader does the same work: the same
cache, the same simulator branch of the lookup (`dyld-sim-handoff.md` §4.2;
every cache library's loader path is the sim root plus its install name),
and the same O(dependencies × loaded images) path comparisons. The Mac's
loader CPU per extension is about 2 s, not a fraction of Ycode's: guest
code runs at the Mac's speed (§5.3), and Ycode adds about 1 s per process
start on the host side (host kernel 0.6–0.7 s, VMM 0.3–0.5 s). `p_load deps`
of a poster extension (872 images, dlopen, initializers included) takes
4.8–5.6 s of CPU on the Mac. **There is no Mac shortcut in the loader.**
Ycode also loads no extra images.

### 6.3 What differs: when, in what order and how many at a time

Subsequent boots, seconds from SpringBoard's spawn:

| Step | Mac (3 boots) | Ycode (k1–k3) |
|---|---|---|
| PosterBoard spawned (SpringBoard asks for it) | 5.5–7.5 | 65–113 |
| SpringBoard starts *its own* Mercury poster instance (the wallpaper renderer) | 9–11, before PosterBoard has opened its data store | 20–28 s after PosterBoard's batch ends (158–233) |
| home_s (from boot start) | 15–20 | 165–245 |
| PosterBoard publishes the active poster (Mercury) | +8 s after its spawn (0.5 s after opening its store) | +26 s (12.7 s between "init the datastore" and the extension scan) |
| PosterBoard's batch: one launch per poster extension (20) | right after the publish, 20 launches in 3.8 s, mostly after home_s | 33–58 s, one launch every 1.5–3 s, before SpringBoard's Mercury |

- On the Mac only one extension (SpringBoard's Mercury instance) is on the
  home screen's path. PosterBoard's batch (a descriptor check per
  extension, `reloadDescriptors`) starts after the home screen (both boots
  with home_s and a process timeline), and its 20 starts overlap: up to 26 extension processes use
  CPU in the same `ps` polling interval, 45–50 CPU seconds of extensions
  in the first 75 s, spread over 14 cores. A first
  boot runs the batch before the home screen (21 starts within 8 s), still
  in parallel.
- The batch is a loop in PosterBoard that asks runningboardd to launch one
  extension at a time. runningboardd's "Creating and launching job" to
  "reported to RB as running" takes 15–70 ms on the Mac (300 ms under heavy
  load) and the next request follows 5–30 ms later. On Ycode the same
  launch takes 0.6–2 s (launchd_sim's own spawn takes 0.15 s of it), and
  PosterBoard's next request follows 1–2.5 s later (its assertion request
  to runningboardd alone takes 0.9 s). So the loop runs about 100 times
  slower, and with each loaded extension needing one core for 3–4 s, only
  about two load at a time.
- Each step of that loop, and SpringBoard's own start-up up to its
  PosterBoard request, is a chain of Mach IPC round trips between daemons.
  Each round trip is many traps, and on Ycode nearly every trap waits for
  the kernel lock: in a boot the lock is 43–45 % busy, 37–40 % of lock calls
  are contended, and the mean wait is 150–330 µs for every trap kind
  (trap profile, 5.5 M traps, 1,640 s of summed waits).

So the Mac starts the same extensions at the same loader cost, but almost
never on the critical path and never one after another. On Ycode the
order is the guest's own (PosterBoard's batch and SpringBoard's Mercury
request are both late because every IPC round trip is slow), and the
serial batch is paced by trap latency, not by the loader.

### 6.4 C21: `madvise` without the kernel lock (`YCODE_TASK_LOCAL_MADVISE`)

The largest sources of kernel-lock waits in a boot (all programs, one
profiled boot):

| Trap | Count | Summed wait | Mean hold |
|---|---|---|---|
| BSD 375 `kevent_id` | 924,033 | 303 s | 12.9 µs |
| BSD 75 `madvise` | 994,580 | 288 s | 1.5 µs |
| BSD 368 `workq_kernreturn` | 525,389 | 174 s | 27.3 µs |
| Mach −47 `mach_msg2_trap` | 509,433 | 172 s | 31.3 µs |
| BSD 5 `open` | 272,793 | 107 s | 1.8 µs |
| BSD 202 `sysctl` | 316,601 | 58 s | 4.0 µs |

`madvise` waits longest for the least work: Ycode keeps no state for its
hints (advice 0–10 answer 0 and change nothing; `MADV_ZERO`, 11, writes
zeros over the range; other values are EINVAL). With the switch (on by
default; `=0` turns it off) BSD 75 is a task-local trap (§3.6): the same
answers, byte for byte (`x0`, `x1`, carry), computed on the trapping
thread without the kernel lock. It reads only its arguments; `MADV_ZERO`
writes guest memory in single L1 sections, like `stat64`'s result. It
takes no L0, blocks on nothing and wakes no one. Rules 3 and 4 of §3.6
apply (tracing, an ending image, and a libSystem return address before the
milestone take the locked path).

Diagnostic: `YCODE_TRAP_PROFILE_PROGRAM=<name>[,…]` limits the trap profile
(`TrapProfile.swift`) to images whose executable has one of these names;
everything else goes to one "(other processes)" row.

Measurements: §6.5.

### 6.5 Results

Same build (`prof2`, 4b1f546), C21 on (default) against
`YCODE_TASK_LOCAL_MADVISE=0`, started together each round (harness, device
in RAM, Thor load average 10–20):

| Round | C21 on | C21 off |
|---|---|---|
| 1 | 195 | 205 |
| 2 | 220 | 220 |
| 3 | 190 | 195 |
| mean | 202 | 207 |

One more paired round with the trap profile (230 s, not to home):
`madvise` leaves the lock (931,059 calls served task-local), summed lock
waits 1,739 → 1,380 s (−21 %), lock busy unchanged (45 → 47 %; its holds
were 1.9 µs). The mean wait of the remaining traps barely moves
(`kevent_id` 384 → 370 µs, `mach_msg2_trap` 411 → 400 µs,
`workq_kernreturn` 385 → 362 µs): the lock's busy time comes from the long
IPC holds, not from `madvise`. home_s improves by about 5 s (2 %), within
the 5 s resolution and the round-to-round spread. C21 stays on: it is
exact (unit test `madviseMatchesTheLockedPath`; kernel host tests pass) and
removes a fifth of all lock waiting. Every boot reached the home screen;
no host crash; `guest_fatal` 23–27 in both arms.

**What remains.** The serial orchestration loops of §6.3 (PosterBoard →
runningboardd → launchd_sim per extension, SpringBoard's start-up chain)
are paced by the latency of IPC traps (`kevent_id`, `workq_kernreturn`,
`mach_msg2_trap`: 1.8 M traps, 670 s of summed waits, 370–400 µs each, and
12–35 µs holds that keep the lock 45 % busy). The lever is a finer lock
for Mach IPC and kqueue workloops, not the loader.

### 6.6 Notes

- `getrusage(RUSAGE_SELF)` answers zero CPU in a Ycode guest, and
  `clock_gettime(CLOCK_THREAD_CPUTIME_ID)` answers about 6.1 × 10⁹ s (an
  uninitialized value), so guest programs cannot measure their own CPU on
  Ycode (fixed in §7.5). The probes report wall time on Ycode for that reason; the boot
  profile's per-image CPU is the Ycode figure in §6.2.
- Other sessions deleted `ycode-test-*` devices on the Mac while this study
  ran (two devices vanished within a minute of their creation); the Mac
  steps were therefore run as one script per device (create, boot, measure,
  copy the logs, delete).

## 7. Ycode's own share of a process start (2026-10-19, agent SP-SPAWN)

§6 shows that the order and pacing of starts are the guest's (PosterBoard's
loop, one runningboardd request at a time; on the Mac up to 26 extensions
start at once). This section measures what Ycode adds to each start and
where Ycode itself serializes starts.

### 7.1 Instruments

- `YCODE_BOOT_PROFILE_TRAPS=1` (with `YCODE_BOOT_PROFILE`): a table in the
  profile's header, per trap number and phase (before / after the image's
  libSystem milestone): count, wall time in the VMM's trap handler (lock
  waits included), the handling host thread's user and system CPU
  (`getrusage(RUSAGE_THREAD)`) and minor faults. Task-local traps are
  included. Pseudo-trap 100000 is the VM prebuild a spawn or exec trap
  runs on its own thread before it takes the kernel lock (§7.3).
- `YCODE_DEBUG_OBJECT_WALKS=1`: one line per volume walk of `fsgetpath`
  (volume, object, time, path found).
- Starts in progress: images between launch and libSystem milestone, from
  the per-image table (`launch_s`, `milestone_ms`).

### 7.2 Concurrency of starts

Main line before the start hold (`SX/PROF2/runs/k4`, home 165 s): on average
2.2 images were in their start phase before home (0: 18 % of the time),
up to 27 at once in the first 10 s (launchd_sim's demand-launched burst);
the poster extensions start one every 1.5–2.5 s and each needs 2.6–3 s
of one core, so about two load at a time. With the start hold on
(`scheduling-policy.md`, main line 34e5bb1) the start phase includes held
time and this count is not comparable. Per start (poster extension,
launch to milestone 2.9 s), Ycode's part is small: lock wait 20–60 ms,
time in trap handlers about 110 ms, host-kernel CPU 0.06 s; 2.55 s is guest
code (§5). Ycode serializes no start against another: image builds run
1–3 ms under the kernel lock, the first guest instruction follows within
about 2 ms, and no single host thread builds address spaces or loads
images for every process. Two Ycode costs sit on the start path instead:

### 7.3 Finding 1: every spawn and exec builds a VM inline (about 47 ms)

A daemon start is two traps of the same kind: launchd_sim's
`posix_spawn` (an `xpcproxy_sim` image) and `xpcproxy_sim`'s
`posix_spawn` with SETEXEC (the daemon image). With trap costs on
(`SX/SPSPAWN/runs/p3`, 453 spawn traps in 190 s) each took **62.5 ms**:

| Part | Per trap |
|---|---|
| Prebuild on the trapping thread (`PrebuiltVMs.prepare`: KVM_CREATE_VM, memslots, EL1 tables; off the kernel lock) | 47.1 ms (CPU 1.3 user, 7.4 system; the rest waits on the host process's mmap lock and KVM) |
| Kernel-lock wait and the rest | about 7 ms |
| Image build under the lock (load 4.4, vCPU 0 3.2, setup 0.4, VM 0.4 ms) | 8.5 ms |

The prebuild keeps one VM "ahead", but it is built by the thread that is
about to spawn, so the requester pays it every time: launchd_sim's spawns
and `xpcproxy_sim`'s exec run one after another on each spawning thread,
and every runningboardd launch request waits about 2 × 60 ms in these two
traps (PROF3 measured launchd_sim's spawn at about 0.15 s of the 0.6–2 s
request).

**C22 (`YCODE_VM_PREBUILD_ASYNC`, default on, `=0` off)**: one background thread keeps
`YCODE_VM_PREBUILD_READY` (default 4) VMs ready; a spawn or exec trap takes
one. A trap that finds none ready builds its own as before. Lock rules:
the ready list's lock is a leaf (L2), never held across KVM calls; the
builder takes no other lock. Measured (p4): spawn traps **18.1 ms**
(−71 %), no inline build in 485 spawn traps.

### 7.4 Finding 2: a volume walk for the shared cache's object id

Every process's loader asks `fsgetpath` (BSD 427) for the path of the
shared-cache file by its object id, twice. Ycode answers from its object
index; the first miss walks the volume (`ObjectPaths.swift`). In a lone
start (`--exec`) that walk is the whole of Ycode's overhead:

| Lone start (`--exec`, Thor) | launch → milestone | 427 handler | host-kernel CPU |
|---|---|---|---|
| backboardd, walk | 1.39–1.42 s | 0.97–0.99 s | 0.62–0.65 s |
| backboardd, seeded | 0.43–0.44 s | 0 | 0.02–0.03 s |
| MercuryPosterExtension, walk | 3.76–3.84 s | 1.07–1.11 s | 0.63–0.67 s |
| MercuryPosterExtension, seeded | 2.74–2.81 s | 0 | 0.07–0.08 s |

This is the "about 1 s per start" of §6.2: in a boot only the first
process pays it (launchd_sim, 0.5–1 s warm, up to 4 s cold, while
nothing else can start) and later misses walk again at most once per
30 s (two walks in a 240 s boot).

**C23 (`YCODE_OBJECT_INDEX_PREWARM`, default on, `=0` off)**: at start the
VMM notes in the index the files of the runtime's
`System/Library/Caches/com.apple.dyld` and `usr/lib/dyld_sim` under each
served prefix (first prefix wins, as in the walk): a few `stat` calls.
A full background walk was tried first and rejected: it took 2–4 s, longer
than the walk it replaces. The answers are unchanged (the index is checked
with `stat` before use; unit test `seededCacheFileResolvesWithoutAWalk`).
In a boot, launchd_sim's first 427 no longer walks; about 50 images run at
0.75 s instead of 1–2.

### 7.5 Per-process CPU accounting

`getrusage(RUSAGE_SELF)` answered zero and `thread_selfusage` (BSD 482,
which `clock_gettime(CLOCK_THREAD_CPUTIME_ID)` uses; Libc converts its
result with the mach timebase) was not implemented. Now: getrusage reports
the image's host threads' CPU (guest code and the VMM's work for it),
split into user and system by their tick counts; RUSAGE_CHILDREN reports
zero; other `who` values EINVAL. `thread_selfusage` reports the calling
thread's host-thread CPU since the guest thread started there, in guest
counter ticks.

### 7.6 Results

Six paired rounds on the same build (34e5bb1 + this section), one boot
slot, the two arms back to back with the order alternating, harness boots
with the device in RAM, Thor load average 12–22. Base: main-line behaviour
(`YCODE_OBJECT_INDEX_PREWARM=0`, inline prebuild); new: C22 + C23.

| Round | Base home_s | New home_s |
|---|---|---|
| 1 | 225 | 210 |
| 2 | 200 | 225 |
| 3 | 240 | 165 |
| 4 | 200 | 170 |
| 5 | 170 | 160 |
| 6 | 175 | 200 |
| mean | 202 | 188 (−7 %) |

Four of six rounds favour the new arm; the paired difference (−13 s,
spread ±37 s) is inside the harness noise, as expected for a change worth
about 2 × 45 ms per daemon start plus 0.5–1 s once at boot start. The
mechanism is measured directly: spawn and exec traps 62.5 → 18.1 ms, no
volume walk at the start of the boot, lone starts 1.0 s shorter. Every
boot reached the home screen; no host crash; `guest_fatal` 9–13 (base) and
8–13 (new). C22 and C23 are on by default (`=0` turns each off). Unit
tests: kernel and ABI suites on the Thor, the full suite on the x86-64
workstation, the new tests on the Mac.

### 7.7 What remains in Ycode's share of a start

- About 8.5 ms per spawn or exec still runs under the kernel lock (loading
  the executable and `dyld_sim` 4.4 ms, creating vCPU 0 3.2 ms). A
  prebuilt VM could also carry its vCPU 0 (agent SP-THREADS owns vCPU
  creation), and the load could move before the lock (C7). The whole image build has since moved
  off the lock (`bsd-locking.md` §7).
- Two VMs per daemon start (`xpcproxy_sim`, then the daemon) remain; C8
  (exec reuses the VM) would halve VM creations.
- The pacing of PosterBoard's batch and SpringBoard's start-up chain is
  IPC latency (§6.5, agent SP-IPC), not process starts.

## 8. The critical path of a cold boot and of a first app launch (2026-10-23, agent BOOT-CP)

The case: a device that was booted before **at its own path** (no
LaunchServices rebuild, `app-launch.md` §4) boots cold. Reference: the Mac
boots a device again to its home screen in about 21 s; Ycode took 45 s
before this section (frame-profile.md §8.6).

### 8.1 Instrument

The frame profile (frame-profile.md §1–§2) gained a boot window and the
events a critical path across process starts needs (frame-profile.md §9 has
the formats):

- `YCODE_FRAME_PROFILE_BOOT=<max s>` opens window 1 before the root
  process is spawned (0.3 s after ycode-simd started, the device's
  preparation before) and closes it `YCODE_FRAME_PROFILE_BOOT_TAIL` s
  (default 3) after the **home screen** is first seen. Home: two checks of
  the presented surface in a row in which fewer than 90 % of 70 × 102
  samples are darker than 24 (the IDE launcher's test, `ycode-sim.sh`);
  a present is checked at most every 50 ms, so the time is exact to about
  50 ms instead of the harness's 5 s.
- New events: thread start requests (who asked: a guest thread in a trap,
  or a host thread), image launches (spawn, exec, launched suspended),
  contended kernel-lock acquisitions (L0, event lock, port lock: the waiter
  and the wait), surface checks, the scheduler counters of every vCPU host
  thread every 200 ms (`YCODE_FRAME_PROFILE_SCHED_MS`: CPU and run-queue
  time) and the host thread a guest thread runs on. A thread's trace id
  carries its image's tag, so a main thread after an exec (same pid, same
  thread id) is a thread of its own.
- `YCODE_HOME_WATCH=1`: only the home-screen check, logged as `home watch:
  home screen seen N s after ycode-simd started`; the timing instrument
  for A/B boots (no trace).
- `scripts/ycode-frame-profile <window> --boot` walks back from the
  frame-record write of the first home-screen frame to the window's start;
  `--launch <program>` from a launch to the frame in which the app shows
  (the first lasting change of the screen's mean brightness by more than
  30 after the launch) and to the settled frame. The walk (frame-profile.md
  §2 item 7) also crosses thread and process starts (a start continues on
  the thread that asked for it at that moment; a main thread started by a
  host thread after a start hold is charged "start hold" back to the
  image's launch), splits trap time into lock waits and service, and splits
  guest-code and wakeup time into running and waiting for a host CPU (the
  sampled run-queue share of the host thread). `--backbone P:main` keeps
  the path on one thread and replaces each of its waits by the waker's
  critical path back to the wait's start; `--thread`, `--long-ms`,
  `--anchor`, `--edges` show one thread's time, its long waits, walks from
  an image launch and the path's hand-offs.

**Why the backbone.** The plain walk from the home frame follows the last
wakeup of every thread. During a boot most threads that the path reaches
(SpringBoard's main run loop, runningboardd, backboardd) are woken many
times by unrelated messages (notifyd notifications, log messages), so the
walk drifts into whichever busy daemon sent the last one (siriinferenced,
intelligencetasksd, mobileassetd in three boots). The order of the
milestones, by contrast, is the same in every boot and matches the Mac's
(§6.3): SpringBoard asks for PosterBoard, then starts its own Mercury
poster instance, whose first frame is the lit home screen. SpringBoard's
main thread is therefore the boot's backbone up to Mercury's launch, and
the plain walk is used for the last step (Mercury's launch to the frame).

### 8.2 Method

Device `ide-remote/bootcp/dev` (a copy of the pristine device, booted once
at its path to rebuild its LaunchServices store), cold boots at that path
on the data volume, profiled (`--profile` of the area's driver: the boot
window, trace in a memory directory) and unprofiled (home watch only), each
started with `SX/bin/timed.sh` (no other ycode-simd, load under 4, the
other boot and build slots held). Build: main line f97a84f plus this
section.

| Boot | Profiled | home_s | ycode-simd CPU at home |
|---|---|---|---|
| r1 (machine shared, load 4→17) | yes | 42.3 | — |
| r2q | yes | 32.7 | — |
| r3q | yes | 33.1 | 305 s (9.2 of 14 cores on average) |

Milestones of r3q (s after ycode-simd started; the Mac's from §6.3, counted
from SpringBoard's spawn):

| Milestone | Ycode | Mac |
|---|---|---|
| launchd_sim spawns SpringBoard and backboardd | 0.58 | — |
| SpringBoard asks for PosterBoard (its launch) | 25.75 | SpringBoard + 5.5–7.5 |
| SpringBoard's Mercury poster instance launched | 31.36 | SpringBoard + 9–11 |
| first home-screen frame | 33.07 | 15–20 after boot start |

### 8.3 Ranked: the boot critical path (r3q, 33.07 s)

Path: 0.58 s to SpringBoard's launch; SpringBoard's main thread as the
backbone to Mercury's launch (30.78 s); the walk from Mercury's launch to
the home frame (1.71 s). Owners: KLOCK (kernel locks), SPAWN (process and VM
creation), GPU-2 (GPU, shaders, Metal host), CPUFEAT (CPU features: guest
code on generic paths), BOOT-CP (this agent).

| # | Item | s on the path | Owner |
|---|---|---|---|
| 1 | SpringBoard's main thread running guest code (its own start-up: loader and initialization; the Mac's loader alone is 4.9–6.2 s CPU, §6.2) | 14.10 | CPUFEAT (guest code on generic paths) / inherent |
| 2 | Host CPU oversubscribed: SpringBoard's own threads runnable but waiting for a host CPU | 3.86 | BOOT-CP (start order and host priority) |
| 3 | Host CPU oversubscribed: diagnosticd's threads runnable after their wakeups, while SpringBoard waited for runningboardd and cfprefsd, which waited for diagnosticd (item 4) | 3.82 | BOOT-CP |
| 4 | **Log backpressure**: runningboardd, cfprefsd and SpringBoard block in `mach_msg2` sends of log messages (id 0x10000000, send only) on diagnosticd's full queue; diagnosticd's workloop threads hand each message on with wakeups (`launchd-sim.md` §8.1). Its wakeup latency (futex wake, re-taking the event lock) | 1.68 | KLOCK |
| 5 | the same: diagnosticd's event-lock waits in `kevent_id` | 1.24 | KLOCK |
| 6 | L0 waits in SpringBoard's own traps (`mach_port_deallocate` 0.20, `fcntl` 0.20, `munmap` 0.16, `thread_get_state` 0.14, `proc_info` 0.12, …) | 1.52 | KLOCK |
| 7 | Mercury's launch to the home frame (walk: guest code of SpringBoard, iconservicesagent and others 0.81, kernel 0.33, the render server's pacing timer 0.11, GPU completion 0.04) | 1.71 | mixed (GPU-2 0.04) |
| 8 | Mach IPC trap service (diagnosticd `kevent_id` 0.43, SpringBoard `mach_msg2` 0.18) | 0.67 | KLOCK |
| 9 | SpringBoard's file traps (`open`, `openat`, `getdirentries64`, `stat64`, `getattrlist`) | 0.55 | BOOT-CP (data volume, runtime volume) |
| 10 | SpringBoard's memory traps (`mmap` 0.31, `vm_allocate` 0.11, …) | 0.47 | SPAWN (file window, arena) |
| 11 | Port-lock and other event-lock waits | 0.38 | KLOCK |
| 12 | ycode-simd before the root spawn (device preparation) | 0.31 | BOOT-CP / SPAWN |
| 13 | launchd_sim's start to SpringBoard's spawn (launchd_sim's worker threads) | 0.27 | SPAWN / inherent |
| 14 | `posix_spawn` in launchd_sim inside the waits | 0.21 | SPAWN |
| 15 | SpringBoard's own wakeup latency (its threads handing work to each other) | 0.20 | KLOCK |

Items 2–5, 8 and 11 have one cause on the boot's path: **the boot is
CPU-bound on the host.** About 190 daemons start in the first 30 s, each
spending 2–4 s of guest CPU in the loader and its initialization (§5, §6),
so the host runs 9.2 cores of ycode-simd on average to the home screen,
with 6.9 threads runnable and waiting for a CPU on average (sum of the
live images' run-queue time over the window). Every guest thread gets an
equal share of the host: SpringBoard's main thread runs at about 60 % of a
core, and diagnosticd, which every process's log messages pass through,
falls behind until its senders block. On the Mac the scheduler runs
SpringBoard (UI QoS) and boosted daemons ahead of the darwin-bg ones
(scheduling-policy.md §2–§3).

### 8.4 Ranked: the first launch of Settings and Safari

`--launch com.apple.Preferences` and `--launch com.apple.mobilesafari`
(ylaunch `open`, `app-launch.md` §9) 20 s after the home screen of a cold
boot (runs `l1-settings`, `l1-safari`, each started with `timed.sh`; home
36.2 and 36.9 s); a 30 s frame-profile window opened at the trigger. "App
visible": the first frame whose mean brightness differs from the previous
check by more than 30 and stays (Settings: the light list, 123.8 → 253.0;
Safari: its dark launch frame, 128.5 → 0.1).

| | Settings | Safari |
|---|---|---|
| ylaunch's open request (spawn to "launched … pid") | 1.92 s | 1.07 s |
| trigger → app visible | about 3.0 s (2.60 s from the app's `xpcproxy_sim`; the Settings run's window opened 0.4 s after ylaunch started) | 1.89 s (from ylaunch's start) |

The plain walk (§8.1) is used: a launch is short and has no single
backbone thread. Its drift into busy daemons is smaller here (healthappd,
healthd and fitnessintelligenced, 0.2–0.6 s, are runs of the last-wakeup
rule through daemons that happen to message SpringBoard and backboardd at
that moment and are not counted as items). Items, in seconds on the path:

| # | Item | Settings | Safari | Owner |
|---|---|---|---|---|
| 1 | A **new `MTLCompilerService` instance** started for the launch, then backboardd's shader compiles through it (its loader and start-up are guest code; the compiles are requests from backboardd) | 0.76 | 0.13 (+ the spawn below) | GPU-2 (shaders) / SPAWN (the start) |
| 2 | **splashboardd** started on demand for the launch image, its loader and work | 0.25 | 0.52 | SPAWN (start) / guest |
| 3 | The app's own `xpcproxy_sim` → exec → first frame (process start, loader) | 0.05 (+ in item 6) | 0.09 | SPAWN |
| 4 | Thread starts (vCPU creation) of the new processes' workqueue threads | 0.04 | 0.14 | SPAWN |
| 5 | Host CPU run queue (the boot's daemons still busy 20 s after home) | 0.19 | 0.07 | BOOT-CP |
| 6 | Kernel-lock waits and IPC trap service (L0 `fcntl`, event locks) | 0.51 | 0.23 | KLOCK |
| 7 | File traps (`pwrite`, `open`, `stat64`, `rename`) of the services on the path | 0.28 | 0.21 | BOOT-CP |
| 8 | GPU completion (host `DispatchWorker` waking backboardd) | 0.06 | 0.02 | GPU-2 |

A first launch is dominated by **processes started on demand for it**
(the app, splashboardd, a Metal compiler service instance) and their loader
cost, i.e. by process start (SPAWN) and the shader compiles of the first
frames (GPU-2); Ycode's own scheduling and I/O are under 0.5 s of either
launch.


### 8.5 The log backpressure in numbers (r3q, the 36 s window)

- 129,380 log messages (`mach_msg2`, id 0x10000000, send only) from 127
  programs, about 3,600 a second; their senders spent **295 thread-seconds
  blocked** in those sends because diagnosticd's queue was full
  (runningboardd 27.8 s of the 36 s, cloudd 24.3, healthd 23.2, assistantd
  21.3, tccd 12.5, mobileassetd 11.5, cfprefsd 4.4). runningboardd and
  cfprefsd answer SpringBoard during its start-up, which is how the stream
  reaches the backbone (§8.3 items 3–5).
- 37,186 of 281,407 wakeups of guest threads woke a thread that went back
  to sleep in the same trap without returning; nearly all in `mach_msg2`
  of the blocked log senders (healthd 5,260, cloudd 4,773, runningboardd
  4,381, …): every receive from a full queue woke every blocked sender, and
  all but one of them slept again (`mach-ipc.md` §2.9 asks for one).
- diagnosticd itself did little guest work: during SpringBoard's waits its
  path was 3.8 s waiting for a host CPU after wakeups, 1.7 s other wakeup
  latency, 1.2 s event-lock waits and 0.16 s guest code. Its throughput is
  set by the hand-offs between its workloop threads (`launchd-sim.md` §8.1:
  every message ends a `dispatch_sync` wait) on a host whose CPUs are all
  busy.

`scripts/ycode-frame-profile <window> --wake-stats --blocked-sends
0x10000000` counts both from a frame-profile trace.

### 8.6 Changes (BOOT-CP's items)

Each behind a switch; timed boots in `scheduling-policy.md` §7.4.

| Change | Switch | Mechanism, measured | Boot (timed, n = 3) |
|---|---|---|---|
| A receive from a full queue wakes only the oldest blocked sender and gives it the slot (`mach-ipc.md` §2.9; was: every blocked sender woke and all but one slept again) | `YCODE_PORT_SLOT_HANDOFF` (default on, `=0` off) | spurious wakeups in a boot 37,186 → 1,400 (profiled r3q → r4q-hand); thread-seconds blocked in log sends 295 → 257 | 35.4 → 36.4 s: no effect on home_s beyond the spread (diagnosticd's throughput, not the wakeups, limits the senders) |
| Device runs with thread QoS and the cgroup host backend: the UI path gets the host CPUs first (items 2–3 of §8.3) | `YCODE_BOOT_PRIORITY=1` (default off; or `YCODE_SCHED_QOS=1 YCODE_HOST_SCHED=cgroup`) | backbone run queue: SpringBoard 3.9 → 1.4 s, diagnosticd after wakeups 3.8 → 1.9 s; blocked log sends 196 thread-s | series C 35.4 → 32.5 s (−8 %); series D 34.5 → 31.7, 31.7 and one 64.9 s boot (kernel lock held 41 s: an idle-class holder, `scheduling-policy.md` §7.4), so not on by default then. **On by default for device runs since 2026-10-27** (PRIO-3: lock holders raised to their waiters' class, class 0 weighted, the quiet test's CPU condition; `scheduling-policy.md` §7.5) |

With the final defaults (slot hand-off on, boot priority off) a warm-boot
cycle through the IDE launcher (`ycode-sim.sh`: cold boot, stop with save,
restore, stop with save) worked: home 40.4 s cold (a copied device), 6.6 s
restored, both saves written.

Backbone of the QoS boot (`C-prof-qos`, home 32.9 s, SpringBoard's launch
0.75 s to its Mercury request 31.30 s): SpringBoard guest code 14.3 s,
host run queue 4.1 s in all (was 8.3–9.7), kernel locks 9.4 s (L0 waits
in SpringBoard's own `fcntl` 1.0, `mach_msg2` 0.5, `ulock_wake` 0.5,
`kevent_id` 0.3; diagnosticd's event lock 0.7), diagnosticd's wakeup
latency 0.9 s.

**Open, by owner.**

- KLOCK: diagnosticd's hand-offs (event-lock waits, wakeup latency of its
  workloop threads, §8.5) set the log throughput that 120–160 programs
  wait for; L0 waits in SpringBoard's traps (`fcntl`, `mach_port_deallocate`,
  `munmap`, `thread_get_state`, `proc_info`); with QoS on, class
  recomputation deferred to L0 from the IPC fast paths.
  `getdirentries64` stats every entry by full guest-path resolution (one
  host `lstat` per path component and entry: 1–2 ms per listing for
  SpringBoard, locationd, routined); a stat relative to the open
  directory's host path would cut it (KLOCK has reworked that file).
- CPUFEAT: SpringBoard's main thread runs 14 s of guest code before it asks
  for Mercury (the Mac's whole SpringBoard loader is 5–6 s of CPU, §6.2).
- SPAWN: processes started on demand for a launch (splashboardd, a new
  `MTLCompilerService` instance, the app) are the largest part of a first
  launch (§8.4); `posix_spawn` and memory traps on the backbone 0.2–0.5 s.
- GPU-2: the first frames of a launched app wait for shader compiles in a
  freshly started `MTLCompilerService` (Settings 0.76 s on the path).
- BOOT-CP (next): done by PRIO-3 (2026-10-27, `scheduling-policy.md`
  §4.2, §4.4, §4.6, §4.7, §7.5): kernel-lock holders are raised to their
  waiters' class, class 0 has a small weight, the quiet test needs an idle
  host CPU, senders blocked on a full queue push onto the receiving image
  (send push), classes are recomputed off L0, and `YCODE_BOOT_PRIORITY`
  is the default for device runs.

**Questions for the reference** (black-box, for the dirty room; answered
in §13):

1. The queue limit of `com.apple.diagnosticd`'s service port in a booted
   simulator device, and whether log senders ever block on it during a boot
   (Ycode: limit as launchd_sim sets it; senders block for 196–295
   thread-seconds in a 33 s boot).
2. Messages per second from processes to diagnosticd during the first 30 s
   of a subsequent boot (Ycode: about 3,600).

## 9. Process creation and the host address-space lock (2026-10-23, agent SPAWN)

Main line f97a84f on the Thor. The question: what does creating a guest
process cost, from the parent's spawn trap to the child's libSystem
milestone, and which part of it is Ycode's.

### 9.1 Instruments

- Per-image table (§1.1), new columns: `req_to_launch_ms` (the parent's
  spawn or exec trap to the start of the image build), `vm_ms` (the
  executable check and taking the VM), `load_ms` (the shim, the executable
  and `dyld_sim`), `vcpu0_ms` (stack, argument block, host page, commpage,
  thread block, vCPU pool and vCPU 0), `activate_ms` (build start to the
  image's registration under the kernel lock), `prebuilt` (0 built by the
  trap, 1 a prebuilt new VM, 2 a reused VM, §9.4), and at the milestone the
  main vCPU's exits as KVM counts them (`m_kvm_exits`: the difference to
  `m_user_exits` is exits KVM handled itself, stage-2 faults and
  interrupts), its WFx exits and the host thread's minor faults.
- Header: the prebuilt-VM counters (taken, ready at take, built inline,
  built by the background builder, reused, refused), the time of
  `ProcessBuilder`, of the spare vCPUs, of `KVM_CREATE_VM` and of VM
  closes, and the host process's mapping count (`/proc/self/maps` lines;
  also every tenth line of `<path>.samples`).
- Outside the repository (agent area on the host): an `LD_PRELOAD` counter
  of the host process's `mmap`, `munmap`, `mprotect`, `mremap` and
  `madvise` calls (count and wall time by size class), and a boot harness
  that boots a RAM copy of the pristine device whose `ycode-device-path`
  names the copy (no LaunchServices rebuild, `app-launch.md` §3.3),
  screenshots every second, and opens Settings as a one-shot 100 s after the
  bind (`ylaunch open com.apple.Preferences`).

### 9.2 The per-process timeline

Three profiled boots of the main line (home at 62–70 s); the 516–531 images
launched before the home screen (means; p50 in brackets):

| Step | Time |
|---|---|
| parent's spawn or exec trap → image build starts | 1.5–2.5 ms (0.4) |
| executable check, VM taken (prebuilt: 99 % ready at take) | 3.3–4.2 ms (0.4–0.7) |
| load: shim, executable, `dyld_sim` | 22.3–23.5 ms (14.4–15.7; p90 53–57) |
| stack, host page, commpage, vCPU pool, vCPU 0 | 3.9 ms (1.0–1.2) |
| whole build (to registration) | 29.5–30.9 ms (17.8–20.1; p90 70–76) |
| registration → first guest instruction (starts not held) | p50 0.5–0.6 ms, p90 4.5–5.9 ms |
| first instruction → libSystem milestone | p50 480–500 ms, mean 3.5–4.2 s; guest CPU 0.52 s mean |
| trap handlers before the milestone | 77–86 ms (39–52), of it kernel-lock wait 23–26 ms |
| host-kernel CPU before the milestone | 10 ms |

The same program started alone (`--exec backboardd --repeat 6`, the last
start, warm host): build 2.2 ms, milestone 393–395 ms, handlers 25 ms,
host-kernel CPU 10–30 ms. So the build is 10× slower inside a boot than
alone, and so are the trap handlers per trap (14 µs alone, 60–70 µs in the
boot). Settings opened after the boot: `xpcproxy_sim` built in 16–18 ms,
Settings in 22 ms, then 3.4 s of guest CPU to its libSystem milestone.

### 9.3 Stage-2 faults are not the cost

- Lone starts with the shared cache in 2 MiB host pages (§9.5, SP4; every
  hot chunk promoted before the measured start): in-kernel exits before
  the milestone 3,386 → 2,614 (−770, about half of all in-kernel exits),
  milestone 393–395 ms → 393–404 ms, guest CPU unchanged. A stage-2 fault on
  a page the host has mapped costs microseconds, and the guest TLB reach
  (4 KiB host pages under 16 KiB guest pages) does not show in the
  loader's guest time.
- In a boot (`p-hot-1` against `p-base-1/2/3`): in-kernel exits −15 %, home
  69 s (base 62–70), image builds and file copies slower (the promoter's
  1,805 `mremap`s run during the boot, §9.4). SP4 stays off.
- `KVM_PRE_FAULT_MEMORY` (`KVM_CAP_PRE_FAULT_MEMORY`) is not offered by the
  Thor's kernel (6.8.12-tegra: the capability check answers 0), and the
  kernel has no read-only file huge pages (`CONFIG_READ_ONLY_THP_FOR_FS` is
  off) and `shmem_enabled = never`, so the only way to block-map the cache
  is the anonymous copy of SP4.

### 9.4 Finding: every host mapping change waits 1.5–2.5 ms

All VMs live in one host process, so they share one address space and
its lock (`mmap_lock`). On arm64 Linux 6.8 every stage-2 fault looks up
the faulting address's mapping with that lock held for reading, and every
`mmap`, `munmap`, `mprotect`, `mremap` takes it for writing; `madvise
(MADV_DONTNEED)` for reading. A waiting writer holds new readers back.
In the first 60 s of a boot the VMM made about 19,600 writing calls
(`mmap` and `munmap` of every size class), each waiting 1.2–2.5 ms on
average (maximum 0.54 s), and 13,400 `MADV_DONTNEED` calls waited 0.45–0.86
ms. The boot samples show 11–17 host threads in uninterruptible sleep on
average before the home screen and up to 79 in the launchd burst: vCPU
threads in `KVM_RUN` waiting for the lock in their stage-2 faults.

The heaviest single writer is VM creation: `KVM_CREATE_VM` registers the
VM's MMU notifier on the host address space, which in Linux takes the
address-space lock for writing and then the lock of every mapping of the
process (`mm_take_all_locks`); with 9,000–20,000 mappings in the host
process it took 10.7 ms per VM (730 VMs per boot), during which no fault
of any VM proceeds. A VM's close (its memslots' host memory, the vCPU run
areas, the MMU notifier's removal) took 45 ms on the supervisor thread.
Per image build the VMM also mapped and unmapped the executable twice and
`dyld_sim` once (whole-file `Data(contentsOf:, .alwaysMapped)`), mapped a
zero tail after each new file in the arena, and created 4+ vCPUs (one
run-area mapping each).

### 9.5 Changes

**SP1: VM reuse (`YCODE_VM_REUSE`, default on; `=0` off).**
When an image ends, its VM is reset and kept for a later spawn or exec
instead of being destroyed. Under the kernel lock (`GuestImageInstance
.destroy`) the image's address space is discarded as before and its
physical backing is *retired*: from then on every operation of the old
backing refuses (allocations and mappings throw, releases do nothing,
physical reads and writes throw), so a late call through the old image's
objects never reaches memory that a later image owns. A VM qualifies
when its backing registered no memslot after its start (no per-mapping
file slot, no per-object shared slot) and no restore overlay is mapped,
and the image was not traced. The background builder (§7.3) then, with no
lock held:

1. returns the pool's host memory (`MADV_DONTNEED`: zeros again) and the
   used part of the private file window (below);
2. resets every vCPU with `KVM_ARM_VCPU_INIT` (KVM allows it after a vCPU
   ran; the vCPU returns to its reset state, its exit counters restart)
   and makes it a spare under its id; returns guest RAM (zeros);
3. builds a new backing over the same memslots (fresh allocators) and new
   EL1 tables, and puts the VM in the ready list.

The memslots, the VM-wide counter offset and the HVC doorbell filter stay
(KVM refuses to change the latter two after a vCPU ran; setting the same
offset again is skipped). Stage-2 entries of the shared arenas that the
old image used may stay: they map the same host pages at the same GPAs in
every VM, and the new image reaches them only through stage-1 tables the
VMM builds for it. Translations the old image's vCPUs left in the TLBs
of other physical CPUs (same VMID) are dropped twice: KVM invalidates the
VM's TLB entries when its MMU notifier unmaps the returned RAM and pool
pages, and a vCPU's boot now invalidates on every PE (`tlbi vmalle1is`,
`ic ialluis`; `vm-shim-protocol.md` §4 step 6; before, `tlbi vmalle1` on
the booting PE only).
At most `YCODE_VM_REUSE_KEEP` (default 64) VMs wait, ready or being reset;
more are destroyed as before. A reused VM brings its vCPUs: a new image
gets as many spares as the old one had, so its thread starts create no
vCPU until it outgrows them.

*Private window inheritance* (`YCODE_VM_REUSE_WINDOW`, default on with
SP1): the window's mappings (writable file mappings over 1 MiB: mostly the
shared cache's data mappings, 84 MiB on average) are not removed; step 1
returns them with `MADV_DONTNEED`, which on a private file mapping drops
the copy-on-write pages and shows the file's bytes again. The next image's
mapping of the same file range (device, inode, size, modification time,
offset, length) gets the same window range back with no host call.

**SP2: executable headers without a mapping (default on;
`YCODE_EXEC_HEADER_MAP=1` maps whole files as before).** The executable
check, the executable's load and `dyld_sim`'s load read the fat header,
the slice's Mach-O header and its load commands with `pread` (all they
use), cached by device, inode, size and modification time. The answers
(ENOENT, EACCES, ENOEXEC, EBADARCH, the segments, the entry point) are
unchanged.

**SP3: a readable arena reservation (default on;
`YCODE_ARENA_ZERO_TAILS=0` off).** The shared file arena's reservation is
readable anonymous memory, so the rest of a file's last 16 KiB granule
reads as zeros without a zero mapping of its own (one `mmap` less per new
file). A guest access to an unused arena range now reads zeros instead of
failing; the VMM maps only file views there.

**SP4: hot-chunk huge pages for the shared cache (`YCODE_ARENA_HUGE=hot`,
off).** A background thread promotes each 2 MiB chunk of a huge arena
span that has a page in the host page cache (`mincore`) into its own
anonymous 2 MiB-aligned memory (a transparent huge page when one is free:
the Thor's THP mode is `always`, so no `MADV_HUGEPAGE` and no direct
compaction, `YCODE_ARENA_HUGE_MADVISE`) and moves it over the arena chunk
with `mremap`. It copies only the hot set from the page cache (1,734 chunks,
3.4 GiB, in 2.2–2.7 s with a warm page cache). §3.4's whole-file copy also
no longer asks for `MADV_HUGEPAGE` under THP `always` and fills with
`YCODE_ARENA_HUGE_THREADS` (default 8) threads. With a cold page cache it
still reads the part of the cache no process touched from the data drive
(in a lone start it had not finished after 40 s), which SP4 avoids.

### 9.6 Results

Profiled boots (§9.1 harness, one at a time under `timed.sh`), images
launched before the home screen:

| | main line (3 boots) | SP1 alone (old binary) | SP1+SP2+SP3 |
|---|---|---|---|
| images before home | 516–531 | 526 | 561 |
| build, mean (p50; p90) | 29.5–30.9 ms (17.8–20.1; 70–76) | 26.7 ms (11.8; 77) | 13.8 ms (6.8; 37) |
| of it load | 22.3–23.5 ms (14.4–15.7) | 20.7 ms (9.2) | 10.7 ms (4.0) |
| registration → first instruction, p50 (p90) | 0.5–0.6 ms (4.5–5.9) | 0.7 ms (5.2) | 0.8 ms (6.2) |
| first instruction p50 (from build start) | 23–26 ms | 18 ms | 13 ms |
| libSystem milestone p50 (from build start) | 505–526 ms | 413 ms | 397 ms |
| host threads in D before 60 s, mean | 13.9–15.6 | 11.1 | 9.7 |
| `KVM_CREATE_VM` / VM closes per boot | 730 / 726 | 299 / 291 | 297 / 265 (437 reused) |
| writing address-space calls in the first 60–65 s | 19,649 | 16,617 | 11,000 |
| `munmap` calls | 3,450 | 1,570 | 2 |

Time to the home screen and the Settings launch (the main line merged with
3aeaa9c; harness boots, device in RAM at its guest path, 1 s frames; four
pairs under one `timed.sh` each or back to back, the order alternating;
base = `YCODE_VM_REUSE=0 YCODE_EXEC_HEADER_MAP=1 YCODE_ARENA_ZERO_TAILS=0`,
new = SP1+SP2+SP3):

| Round | base home_s | new home_s | base Settings frame / open request (s) | new |
|---|---|---|---|---|
| 1 | 62 | 61 | 1.3 / 1.0 | 2.5 / 1.2 |
| 2 | 61 | 59 | 2.4 / 1.2 | 1.3 / 1.0 |
| 3 | 66 | 59 | 2.4 / 1.2 | 1.3 / 1.0 |
| 4 | 65 | 62 | 1.6 / 1.2 | 2.3 / 1.0 |
| mean | 63.5 | 60.3 (−3.3 s, −5 %; every pair −1…−7 s) | 1.9 / 1.15 | 1.85 / 1.05 |

The Settings columns: the first frame of the Settings list after the
one-shot `ylaunch open` was spawned (1 s frames, so ±1 s), and the open
request (ylaunch's spawn to its exit after FrontBoard reports the launch).
The app launch is not measurably shorter at this resolution: its cost is
the app's own loader work (§9.2, 3.4 s of guest CPU to Settings' libSystem
milestone; the list is drawn before it finishes loading everything). Every
boot reached the home screen; no host crash; `guest_fatal` 6–15 (base) and
5–10 (new). SP1, SP2 and SP3 are on by default.


### 9.7 Open items

- About 11,000 writing address-space calls remain in the first minute,
  each still waiting about 1.2–1.7 ms: shared memory objects made and freed
  in the shared object arena (`SharedMemory.swift`: one `MAP_FIXED` each
  way; 5,800 per minute; its run pool recycles only some), new vCPUs' run
  areas (2,500: thread starts beyond a VM's spares), the private window's
  first mappings in new VMs, and new VMs (about 270 per boot even with
  SP1: the keep limit is reached in bursts of exits). Each is a candidate
  for the same treatment (reuse instead of map and unmap). Owners: the
  shared object arena (C19, `SharedMemory.swift`) is outside this agent's
  area.
- One host process for all VMs is the root cause: every VM's stage-2 faults
  share one address-space lock with every VMM mapping change. Several host
  processes (VM groups) would split the lock but not the kernel lock or the
  shared arenas; not attempted.
- The loader's guest CPU is unchanged (§5): it is most of a start (p50 about
  400 ms of 400–520 ms) and of an app launch (Settings: 3.4 s of guest CPU
  to its libSystem milestone).
- Stop snapshots at `--timeout-ms` in the first minutes after a cold boot
  did not settle (2–10 images "ending" for 5–15 s) on the main line
  (`SX/IDE` tree) and on this branch with SP1 on or off alike; snapshots
  were checked with `YCODE_SNAPSHOT_AT_MS` instead: with SP1 on, a
  snapshot 90 s into a cold boot (265 images, quiesced in 396 ms, 3.1 GiB)
  restored lazily to the home screen in 10 s; the only guest faults after
  the restore were the known `fileindexerd` and `intelligencetasksd`
  crashes (`app-launch.md` §7), as in the cold boot.

## 10. Cold boot on the 2026-11-05 main line: measurements and candidates (agent B3-GPU)

Issue #44 asks for the cold boot within an agreed factor of the reference
(median 30.1 s against 21.4 s, `lean-boot.md` §9), measured as
`parity-ladder.md` sets: full boot, every service, a device booted before
at its own path, home from the home watch.

### 10.1 Conditions

Thor, release builds of the main line at `2d8f51ac` (*base*) and of this
branch (*tree*: the GPU isolation of `metal-sim-protocol.md` §8.8), one
copy of the golden device in the agent's own folder, booted three times at
that path before the series, default switches (start hold, boot
priority), `YCODE_HOME_WATCH`, 5 s held after home, no save. Each boot
started only when no other `ycode-simd` ran and the 1-minute load was under
6, up to 10 minutes of waiting; arms rotated each round. The Thor was
shared with other agents' builds and Flatpak work all afternoon: the
1-minute load at each boot's start was 4.2–6.0 (2.2 once) and 10–20 at the
home screen, so the timed condition of `lean-boot.md` §9 (load under 4) was
never met, and these medians are not comparable with its 30.1 s; compare
arms within a series.

### 10.2 Series

| Series, arm | n | median home_s | mean ± sd | range | kernel lock held at home, median |
|---|---|---|---|---|---|
| S1 base | 5 | 48.51 | 46.19 ± 4.28 | 40.34–50.43 | 9.6 s |
| S1 tree | 5 | 40.02 | 40.79 ± 4.46 | 35.66–47.93 | 8.1 s |
| S1 tree, `YCODE_HOST_SCHED_BG_CPUS=4` | 5 | 41.12 | 43.13 ± 4.91 | 40.15–51.77 | 8.8 s |
| S1 tree, `YCODE_HOST_SCHED_BG_WEIGHT=idle` | 5 | 42.32 | 43.68 ± 2.98 | 40.71–48.02 | 13.0 s |
| S1 tree, `YCODE_LOCK_ADMISSION=1` | 5 | 40.30 | 40.86 ± 2.72 | 37.50–44.96 | 7.5 s |
| S2 base, the tree's pipeline cache copied in | 5 | 40.34 | 40.77 ± 1.30 | 39.40–42.86 | 8.1 s |
| S2 tree | 5 | 41.25 | 41.27 ± 1.65 | 38.82–43.46 | 8.1 s |
| S2 tree, empty GPU cache every boot | 5 | 41.78 | 41.47 ± 1.17 | 39.88–42.91 | 8.7 s |

- **The branch does not change the boot**: S2 base 40.34 against tree 41.25
  (inside one standard deviation). S1's base arm was the series' first
  boots after the base's caches were made; its pipeline cache still grew
  by 25 KB a boot, the tree's not; with the tree's cache (S2) the base is as
  fast as the tree.
- **The GPU is not on the path, cold or warm** (as `stage8-contract.md`
  §13.1 found at 240 s boots): with an empty GPU cache at every boot the
  first frames translated 112 functions (1.8 s) and compiled 110 pipelines
  (0.25 s, the driver's own cache warm), and home came at 41.78 s against
  41.25 s. In the profiled boot below the GPU's share of the critical path
  was 9 ms.
- **None of the three scheduling candidates helps.** Background threads on
  4 CPUs and class 0 as `cpu.idle` are slower (the latter holds the
  kernel lock 13 s by home: idle-class holders); lock admission holds the
  lock 7.5 s instead of 8.1 s and has the narrowest range, but its median is
  the tree's. None is made a default.

### 10.3 Where the time goes now (profiled boot `prof1`, home 40.71 s)

`YCODE_FRAME_PROFILE_BOOT=120`, then `scripts/ycode-frame-profile p1.1
--boot --backbone SpringBoard:main` (§8.1). Load 13–16 during the boot. By
category on the critical path:

| # | Item | s | §8.3 (r3q, 33.1 s) |
|---|---|---|---|
| 1 | SpringBoard's own guest code | 17.6 | 14.1 |
| 2 | diagnosticd (the log path): waiting for a host CPU after wakeups 6.2, wakeup latency 3.3, event-lock waits in `kevent_id` 2.7, its `kevent_id` service 0.9, its run queue 0.5, other 0.8 | 14.4 | 6.7 |
| 3 | SpringBoard waiting for a host CPU | 3.8 (+0.3 after wakeups) | 3.9 |
| 4 | SpringBoard's port-lock waits and `mach_msg2` service | 1.5 | 0.7 |
| 5 | Workqueue thread starts in SpringBoard | 0.5 | — |
| 6 | SpringBoard's file and memory traps | 0.7 | 1.0 |
| 7 | GPU | 0.01 | 0.04 |

The path's shape is §8.3's. What grew is the log path: item 2 doubled, and
items 2 and 3 are host CPU contention, which the shared host made worse.

### 10.4 The hardware

`scripts/host-probes/cpubench.c` (our C, one thread, `-O2`, best of three):
the Mac of the reference measurements (Apple M3 Max) against one Thor core
(pinned, load 13–20 from other work):

| Part | Mac | Thor | Thor ÷ Mac |
|---|---|---|---|
| sort 200,000 path strings with `strcmp`, 5 times | 331 ms | 309 ms | 0.93 |
| hash inserts, 20 M | 273 ms | 357 ms | 1.31 |
| pointer chase in 1 MiB, 100 M hops | 743 ms | 1,353 ms | 1.82 |
| unpredictable branches, 400 M | 1,007 ms | 924 ms | 0.92 |
| all | 2,354 ms | 2,943 ms | 1.25 |

Guest code runs at the Thor's native speed (`guest-cpu.md` §2), so
SpringBoard's 17.6 s of guest code costs the Mac less in proportion to how
much of it waits on memory: between 0.92 and 1.82 times less. The Mac runs
its boot on more and faster cores as well (CPU-bound boots, §8.3).

### 10.5 Agreed factor (proposal) and the next candidates

The boot is CPU-bound on the host; Ycode's own overheads that BOOT-CP,
SPAWN, KLOCK, PRIO-3 and GUEST-CPU measured have been cut, and the GPU is
off the path. A factor that leaves Ycode's remaining overhead visible but
does not ask the Thor to be a faster computer: **home_s ≤ 1.5 × the Mac's
21.4 s = 32 s**, measured on a quiet Thor (load under 4 at the start, no
other boot, `lean-boot.md` §9's method, n ≥ 5). The main line met it on
2026-10-27 (30.1 s, 1.41 ×). The orchestrator or the owner decides.

Candidates by size on today's path, for the owners named in §8.3:

1. **The log path (KLOCK, scheduling): 6.7–14.4 s.** Every log message is a
   Mach send to diagnosticd (`launchd-sim.md` §8.1), about 3,600 a second
   in a boot, and runningboardd and cfprefsd, which SpringBoard waits for,
   block on its full queue. diagnosticd is an Interactive daemon (its
   plist's `POSIXSpawnType`), so its threads are not darwin-bg; they wait
   for host CPUs and for each other. Measuring the reference's queue
   limit and message rate (§8.6 questions 1–2) decides whether Ycode's
   backpressure is the reference's.
2. **Host CPU for SpringBoard (scheduling): 4 s.** Boot priority already
   applies; the three switches of §10.2 did not shorten it.
3. **SpringBoard's own guest code: 14–18 s.** Native speed; the loader's
   algorithm (§5). Not Ycode's to shorten.

## 11. Plan: a cold boot as fast as the reference (1.0 ×) (agent B3-GPU, 2026-11-05)

The owner set the target: **home_s ≤ 21.4 s** on a quiet Thor under
`parity-ladder.md`'s conditions (full boot, device booted before at its
path, load under 4 at the start, no other boot, n ≥ 5, median). The last
quiet measurement is 30.1 s (`lean-boot.md` §9), so **8.7 s (29 %)** must go.
This section is a plan only; nothing in it is implemented.

### 11.1 The budget

The critical path measured twice, with the same tool (`--backbone
SpringBoard:main`, §8.1): BOOT-CP's `r3q` on a quiet host (33.1 s, §8.3) and
`prof1` on today's shared host (40.7 s, §10.3).

| Item | quiet (r3q) | shared (prof1) |
|---|---|---|
| SpringBoard's own guest code | 14.1 s | 17.6 s |
| The log path through diagnosticd (CPU waits after wakeups, wakeup latency, event-lock waits, `kevent_id`) | 6.7 s | 14.4 s |
| SpringBoard waiting for a host CPU | 3.9 s | 3.8 s |
| Kernel-lock and port-lock waits, IPC service in SpringBoard | 2.4 s | 1.5 s |
| Everything else (spawns, file and memory traps, thread starts, GPU) | 6.0 s | 3.1 s |

The quiet column is the one the target is measured against; the shared
column shows which items grow under contention (the log path doubles).

### 11.2 Candidates

Savings are estimates for a quiet-host boot, from the profile; each needs
an A/B series (n ≥ 5 per arm, arms alternated, quiet Thor) before it
counts.

| Rank | Candidate | Expected saving | Risk | What to measure |
|---|---|---|---|---|
| 1 | **The log path.** Every `os_log` message is a send-only Mach message to diagnosticd (about 3,600 a second in a boot); runningboardd and cfprefsd, which SpringBoard waits for, block on its full queue (§8.5). Options, cheapest first: (a) a send-only message to a port whose receiver waits in a workloop hands off without the event lock and without a full wakeup round trip (the KLOCK items of §8.6); (b) diagnosticd's receive threads get a host CPU first while senders are blocked on its queue (send push exists; extend it to the host class of the receiving workloop thread); (c) if the reference's queue limit is larger than the one launchd_sim sets in Ycode (§8.6 question 1), match it | 3–6 s (most of 6.7 s; the queue limit alone is unknown) | Medium: IPC ordering and wakeups (lost wakeup, message order per port), lock order | `--blocked-sends 0x10000000` thread-seconds (196–295 s today), the log path's share of the backbone, home_s; message rate and queue limit on the reference (dirty room, §8.6 questions 1–2) |
| 2 | **SpringBoard's CPU wait.** Its threads wait 3.9 s for a host CPU while about 190 daemons start. Reserve host CPUs for the UI class while the boot runs (a cpuset for the UI path, the rest for the others), or hold more of the non-UI starts until home. `YCODE_HOST_SCHED_BG_CPUS=4` and `cpu.idle` for class 0 did not help (§10.2), so the next try is the reverse: give SpringBoard, backboardd and their direct servers dedicated CPUs | 1–3 s | Low–medium: starving the daemons SpringBoard waits for (runningboardd, cfprefsd, diagnosticd) moves the time instead of removing it | the backbone's run-queue items, home_s, the hold's release reasons |
| 3 | **Native mode** (`native-mode.md`): guest processes as Linux processes, system calls as function calls, no global lock for process-local work. **Stage 1 measured (§11.5, `native-mode.md` §10)**: a process-local call 30 × cheaper, but on the path it removes only trap service, process-local lock waits, spawns and wakeups | 1.4–7.1 s (central about 4), of which 2.2–3.6 s no other rank reaches; only once stages 2–5 exist | High: months of work, foreign code in the runtime's process, signal emulation, cross-process Mach semantics, a second code path | done: stage 1's per-call costs against the micro-VM (§11.5) |
| 4 | **SpringBoard's guest code** (14.1 s): dyld_sim's loader and SpringBoard's own start-up at native speed (§5, `guest-cpu.md` §2). Ycode's share is memory translation: file-backed memory is 4 KiB at stage 2; a hugetlbfs pool or `shmem_enabled = advise` (root on the Thor) would let the shared cache be block-mapped (`guest-cpu.md` §8) | 0.5–1.5 s | Low (needs the owner for root) | DTLB walks and cycles of SpringBoard to its Mercury request (`pmustat -g`), home_s |
| 5 | **The Thor's core gap** (§10.4): one Thor core is 1.25 × slower than the Mac's on loader-like work overall (0.92 × on branches and string sorting, 1.82 × on memory latency). Not closable in software; it sets a floor | — | — | the same `cpubench` on any new host |

### 11.3 What 1.0 × requires

Ranks 1, 2 and 4 together give about 4.5–10.5 s; the middle of that range
reaches 21.4 s only if the log path gives most of its 6.7 s. The core gap
weighs on the 14 s of guest code: at the Mac's speed for memory-bound work
it would be about 10 s, so with the same work as the Mac and today's
overheads the Thor cannot reach 1.0 ×; Ycode has to remove overheads the
Mac also has a little of (the log back-pressure, CPU contention) to make up
for it. Native mode (rank 3) is the only candidate whose saving grows with
the number of traps and processes, so it is the long-term route if ranks
1, 2 and 4 stop short.

### 11.4 The next wave

1. **The log path, measured and cut** (rank 1): a frame-profile series on a
   quiet Thor with `--blocked-sends` and the backbone, then option (a) behind
   a switch, A/B n ≥ 5; in parallel the dirty room answers §8.6's two
   questions about the reference (queue limit, message rate), which decide
   option (c).
2. **Native mode stage 1** (rank 3): the single-threaded native runner of
   `native-mode.md` §9, with its per-call numbers against the micro-VM, so
   that the size of the long-term route is measured before anyone commits to
   stages 2–5. *Done (B3-NATIVE, §11.5): not continued toward 21.4 s.*

Both need a reserved Thor for their timed series (no other agents' boots
or builds): today's shared host adds 10 s to a boot (§10.1) and makes a
2 s gain invisible.

### 11.5 Native mode, measured (agent B3-NATIVE, 2026-11-05)

The stage-1 implementation is on the long-lived `native-mode` branch, not
on the main line (owner's decision, 2026-11-05: iterate on it across
betas). The measurements below were made from that branch.

Stage 1 of `native-mode.md` §9 exists (`native-mode.md` §10): `ycnative`
runs Ycode's macOS userland programs as plain Linux processes, behind
`YCODE_NATIVE=1` for `ycode-simd --macos` (off by default; the micro-VM
path is unchanged). The guest's `svc` sites in Ycode's images become
function calls, the program's own go through seccomp, and the TLS reads are
rewritten at load time (`TPIDRRO_EL0` → `TPIDR_EL0`, one word each, no run
time cost, no kernel patch). All six Milestone A samples and `nt_probe`
pass in both modes.

Medians of 7 runs, the same binaries in both modes, the same four Thor
cores, under the boot-timing lock (`native-mode.md` §10.5–§10.6):

| | micro-VM | native | ratio |
|---|---|---|---|
| `getppid` (a BSD call that does some work) | 4.31 µs | 136 ns | 31.7 |
| a Mach trap with no work | 4.25 µs | 15 ns | 289 |
| file call (`open`/`fstat`/`pread`/`close`) | 6.88 µs | 553 ns | 12.5 |
| stray `svc` (seccomp) | 4.28 µs | 957 ns | 4.5 |
| first write to a fresh 16 KiB page | 319 ns | 274 ns | 1.2 |
| thread hand-off | 10.4 µs | 4.6 µs | 2.3 |
| `hello` start to exit | 77 ms | 4.9 ms | 15.7 |

A Swift personality would add 16–19 ns per call (the heavy entry: the TLS
switch and the FP registers).

Applied item by item to the quiet critical path of §8.3, stages 2–5 would
save **1.4–7.1 s (central about 4 s)**; 2.2–3.6 s of it is what no other
rank reaches (trap service and the global lock of process-local calls,
spawns, wakeups), the rest overlaps ranks 1 and 2 (`native-mode.md`
§10.7). That does not make 8.7 s on its own, and it costs months of
high-risk work (§10.8–§10.9: stage 2 alone about 2–3 agent-weeks).
**Recommendation: do not continue native mode toward 21.4 s.** Ranks 1, 2
and 4, and the micro-VM's own lock work on the process-local traps of
§8.3 item 6, are cheaper ways to the same items. Stage 1 stays behind its
switch as the measured base.

## 12. The log path and the UI path's CPUs, measured (agent B3-BOOT, 2026-11-05)

§11's ranks 1 and 2, with the reference's answers of §13 (rate 2 900
messages/s, per-connection queues of 6 that fill, senders blocked 1–4 % of
the time, diagnosticd at the default priority). Every timed number below
is from series that follow `parity-ladder.md`'s conditions.

### 12.1 Conditions

- Thor; one copy of the golden device in the agent's own folder, booted
  three times at that path before the first series; full boot, default
  switches (start hold, boot priority), `YCODE_HOME_WATCH`, stopped 5 s
  after home, no save.
- Every timed series ran under the shared boot-timing lock (one holder at
  a time, no other `ycode-simd`); each boot started only when no other
  `ycode-simd` ran and the 1-minute load was under 4 (it was 1.0–3.99;
  10–28 at the home screen, the boot's own load); arms rotated each round,
  n = 5 per arm.
- Builds: the main line `a906b5f6` (series S1) and the same merged with
  `m2-workspace-settings` of 2026-11-05 evening plus this section's changes
  (S2, S3, the profiles after). Arms of one series are one binary with
  switches.
- Profiles: `YCODE_FRAME_PROFILE_BOOT=120` (boot window), analysed with
  `scripts/ycode-frame-profile --boot --backbone SpringBoard:main` and
  `--blocked-sends 0x10000000`; one trap profile per build with lock-holder
  stacks (`YCODE_TRAP_PROFILE_STACKS=300`). Profiled boots are not timed
  boots (the profile slows them, and some started at load 10–20).

### 12.2 Profile before (`b1`, home 40.95 s)

- **Backbone** (SpringBoard's main thread to the home frame): SpringBoard's
  guest code 18.5 s; SpringBoard waiting for a host CPU 5.3 s (+0.4 after
  wakeups); **the log path 11.4 s**: diagnosticd's threads runnable after
  their wakeups 4.7 s, their wakeup latency 2.6 s, event-lock waits in
  `kevent_id` 2.5 s, `kevent_id` service 0.7 s, its run queue 0.4 s,
  `workq_kernreturn` event-lock waits 0.4 s; port-lock waits in
  SpringBoard's `mach_msg2` 1.0 s.
- **Blocked log sends**: 185 684 sends of id 0x10000000 in the window,
  392 thread-seconds blocked by 184 programs; runningboardd 34.3 s
  (5 057 of 14 909 sends blocked: 79 % of the window as thread-seconds,
  against 1–4 % of a thread's time on the reference, §13.4), SpringBoard
  27.7 s, apsd 76.9 s, cfprefsd 4.9 s.
- **Queue limits** (`YCODE_DEBUG_FULL_QUEUES=1`, the first blocked send on
  each port): every blocked log send waited on a per-connection receive
  right of diagnosticd with `qlimit` **6**, the reference's value (§13.4);
  54 448 blocked sends to diagnosticd by home. So §11.2 option (c) has
  nothing to match: Ycode's port code keeps the guest's limit.
- **diagnosticd itself** (frame-profile summary): 0.40 cores of host CPU,
  of it 0.06 guest code, 0.24 VMM code and 0.10 host kernel; 0.79 cores'
  worth of its threads runnable and waiting for a CPU; 598 000 timeslices
  and 571 000 voluntary switches for about 130 000 messages. A trace slice
  (8 ms at 15.5 s) shows the guest's own design: per message one thread
  receives it in a `workq_kernreturn` return (and wakes the blocked
  sender), its handler hands work to another of diagnosticd's threads
  through a workloop sync wait and wake (`kevent_id`), about 1.5 thread
  hand-offs and 3–4 traps per message, each trap 10–30 µs, each hand-off
  10–20 µs when CPUs are free. At 3 600 messages a second the per-message
  cost of Mach IPC itself is small (a 1 KB send 2.9 µs, its EVFILT_MACHPORT
  receive 1.6 µs on the Mac, release build); the time is in the hand-offs:
  a woken thread waits for a host CPU, and the chain stalls whenever one
  of its locks is held by a thread the host does not run.
- **Lock stalls** (contended acquisitions of the window): port lock G
  294 792, 64.8 s summed, p50 14 µs but p99 5.1 ms, 7 670 waits of 2 ms or
  more (42.5 s summed), and at least one waiter of 2 ms or more during
  14.3 s of the 41 s; L0 and the event locks the same shape (7.9 s and
  10.9 s of such stalls). One stall seen in diagnosticd at 12.0 s: a
  thread waited 8.3 ms for G inside `workq_kernreturn` while holding
  diagnosticd's event lock, and two more of its threads waited 8–9 ms for
  that event lock.
- **What the port-lock holder does** (holder stacks, 4 475 samples):
  10.4 % in `sched_yield` from the lock-holder promotion's withdrawal
  (`KernelLock.withdrawHolder`: a raised holder waited, still holding the
  mutex, for the waiters still raising it, i.e. for their cgroup weight
  writes); 10.3 % in futex waits: the EVFILT_MACHPORT receive's write into
  the guest's buffer under G (`writeReceived`, which takes the receiving
  task's address-space lock), glibc malloc and free (arena locks), and
  port routines' out-parameter writes; the rest Swift and malloc work of
  `take`, `copyoutReceived` and `deliver`.

### 12.3 Changes

| Change | Switch | Default | Test |
|---|---|---|---|
| An EVFILT_MACHPORT receive writes the message after the port lock (`mach-ipc-locking.md` §4.3) | `YCODE_KEVENT_WRITE_AFTER_PORT_LOCK` | **on** | `keventReceiveWritesAfterThePortLock` |
| A raised lock holder finishes its withdrawal (waits for promoters, lowers the class weight) after it releases the mutex (`scheduling-policy.md` §4.7) | `YCODE_LOCK_WITHDRAW_AFTER_UNLOCK` | **on** | the promotion tests of `SchedPolicyTests` |
| The host class is also applied at the end of fast traps (IPC, BSD descriptor, task-local): `1` the whole class, `push` a raise to the send push only | `YCODE_FAST_TRAP_HOST_CLASS` | off | `fastTrapEndsApplyTheSendPush` |
| Host CPUs kept for the UI path: SpringBoard and backboardd (`YCODE_HOST_SCHED_UI_PROGRAMS`) on every CPU, every other guest thread on all but the last N | `YCODE_HOST_SCHED_UI_CPUS=N` | off | `masksKeepTheLastCPUsForTheUIPath`, `placementChangesOnlyWhenTheSideChanges` |
| With the above: an image pushed by blocked senders of class ≥ c (diagnosticd during the boot) also runs on those CPUs while the push lasts | `YCODE_HOST_SCHED_UI_PUSHED=c` | off | `fastTrapEndsApplyTheSendPush` |
| Diagnostic: the first blocked send per port (receiver, `qlimit`, queued) and blocked sends per receiver at home | `YCODE_DEBUG_FULL_QUEUES=1` | off | — |

Tried and removed: a guest thread of a pushed image spinning up to 200 µs
before it sleeps on a fine lock's queue (the hand-off without a wakeup).
In one profiled boot 112 599 waits spun and only 4 903 (4 %) were woken
while spinning; 23.8 s of CPU went into spinning and blocked log sends
rose (392 → 612 thread-s): diagnosticd's waits are not microseconds long,
because its wakers are themselves waiting for CPUs and locks.

`YCODE_FAST_TRAP_HOST_CLASS=1` in one profiled boot: diagnosticd's run
queue after wakeups 4.7 → 3.3 s on the backbone, but cgroup moves rose
from 3 927 to 12 385 at 1.8 ms each (22 s of moving), so it stays off.
A larger glibc arena count (`GLIBC_TUNABLES=glibc.malloc.arena_max=1024`,
against the malloc waits under G) was 3.2 s slower in S2 and is not used.

### 12.4 Timed series

| Series | Arm | n | median home_s | mean ± sd | range | kernel lock held at home, median | guest fatal |
|---|---|---|---|---|---|---|---|
| S1 (`a906b5f6`) | main line | 5 | **42.52** | 42.61 ± 2.01 | 40.25–45.74 | 8.8 s | 1–4 |
| S1 | `UI_CPUS=3` | 5 | 43.77 | 44.31 ± 2.54 | 41.33–48.16 | 9.4 s | 1–5 |
| S1 | `UI_CPUS=3`, `UI_PUSHED=2` | 5 | 42.18 | 42.12 ± 0.64 | 41.12–42.88 | 10.7 s | 1–2 |
| S2 (merged) | both port-lock changes off | 5 | **39.82** | 39.31 ± 1.59 | 36.91–41.12 | 8.5 s | 1–3 |
| S2 | new defaults (both on) | 5 | **38.39** | 39.32 ± 2.01 | 37.44–41.93 | 7.1 s | 1–4 |
| S2 | new defaults, `arena_max=1024` | 5 | 43.00 | 43.18 ± 1.29 | 41.80–45.32 | 8.0 s | 1–5 |
| S3 | new defaults | 5 | **39.44** | 40.37 ± 1.65 | 38.68–42.19 | 7.8 s | 1–3 |
| S3 | new defaults, `UI_CPUS=3`, `UI_PUSHED=2` | 5 | 42.80 | 42.51 ± 1.74 | 40.81–45.11 | 9.9 s | 1–4 |
| SVC | the 2026-10-27 build (`5f74ef9`, `lean-boot.md` §9) | 2 | **30.79** | 30.79 ± 0.34 | 30.55–31.03 | 5.6 s | 1–3 |
| SVC | new defaults | 2 | 41.36 | 41.36 ± 0.69 | 40.87–41.84 | 8.0 s | 1 |

- The two port-lock changes: −1.4 s by the median, the same mean, the
  kernel lock held 1.4 s less by home; inside the spread. They are exact
  and remove two kinds of multi-millisecond port-lock holds, so they stay
  on.
- **Removing the log back-pressure does not shorten the boot.** With
  diagnosticd on the UI path's CPUs while it is pushed (`onp`), blocked log
  sends fell 500 → 120 thread-seconds and runningboardd's 43.9 → 7.4 s
  (15 % of the window), the log path left the backbone (11.4 → 2.5 s), and
  SpringBoard's run queue fell 4.0 → 2.3 s, yet home came 3.4 s later
  (S3) and SpringBoard's own guest code on the backbone grew 17.7 → 23.0 s.
  The back-pressure throttles the other 180 programs; without it they take
  the CPUs and memory bandwidth that SpringBoard's loader-bound start-up
  needs (§10.4: the Thor's memory latency). The UI path's CPUs alone
  (`ui3`) and with the push (`ui3p`, S1) are within noise.
- **The main line got 9–10 s slower since 2026-10-27, and two features
  that the reference also has account for it** (§12.5).

### 12.5 Where the 10 s since 2026-10-27 went: networking and the inner panel

The build that measured 30.1 s on 2026-10-27 (`lean-boot.md` §9, main line
`5f74ef9`) boots the same device copy in **30.8 s** today under the same
conditions (series SVC above), against 41.4 s for today's code. A bisection
over the 232 first-parent commits `5f74ef9..a906b5f6` (each step a release
build, one untimed boot, two timed boots under the lock):

| First-parent commit | home_s (2 boots) | |
|---|---|---|
| `63071fcc` (OBS-FOLD2 merge, 2026-10-27 evening) | 30.46, 32.38 | good |
| `8c04d20f` NET-IMPL: host passthrough networking | 36.49, 36.25 | **+5 s** |
| `41859581` (two specification merges later) | 34.25, 38.52 | as NET-IMPL |
| `33ee30f4` FOLD-IMPL2: the iPhone Duo unfolds (inner panel on by default for foldables) | 40.72, 38.08 | **+3 s** |
| `fc308f06`, `63c2d4f6`, `fe82203c`, `117eee37` (later) | 39.46–42.18 | as FOLD-IMPL2 |

Today's code with each feature switched off (series S4, n = 3 per arm,
same conditions):

| Arm | median home_s | mean ± sd | range | kernel lock held at home |
|---|---|---|---|---|
| new defaults | 39.93 | 40.56 ± 1.25 | 39.74–42.00 | 8.1 s |
| `YCODE_NO_NETWORK=1` | 33.91 | 34.07 ± 1.29 | 32.86–35.43 | 6.0 s |
| `YCODE_FOLD_DISPLAYS=0` (cover panel only) | 36.04 | 35.97 ± 0.98 | 34.96–36.91 | 6.9 s |
| both off | **31.58** | 32.45 ± 2.04 | 30.98–34.78 | 6.1 s |

So the boot did not regress by accident: guest networking (about 6 s) and
the Duo's second panel (about 4 s) were added for parity, and the
reference has both (its simulator shares the host's network, and §13's
and `parity-ladder.md`'s reference boots are iPhone Duo boots). The
comparison with 21.4 s is therefore with both on; 30.1 s (2026-10-27) was
a boot without them. What each costs on Ycode beyond what it costs the
reference is the next question (§12.8).

### 12.6 The whole boot is throughput-bound

Summed over all programs in the boot window (frame-profile summary,
profiles `b1` and `off2`): 9.6–9.7 cores of host CPU on average out of 14
(guest code 7.2, VMM code 1.3, host kernel 0.9), and 10.5–11.9 cores'
worth of guest threads runnable and waiting for a CPU. About 420 CPU
seconds are spent before home; at 14 fully used cores that alone is 30 s.
So the boot cannot reach 21.4 s by moving waits between threads (every
measured attempt moved them: §12.4, §10.2); it needs less work before the
home screen.

### 12.7 Service fidelity

`scripts/ycode-launchd-spawns` over 700 s of a full boot (as
`service-fidelity.md` §15 counts), the main-line binary (`a906b5f6`)
against the new defaults, one boot each on the same device copy, one
after the other:

| | main line | new defaults |
|---|---|---|
| all starts | 511 (238 labels) | 508 (235 labels) |
| restart loops (facetimemessagestored, managedappdistributiond, mlhostd, proactiveeventtrackerd, intelligencetasksd, fileindexerd) | 67, 66, 63, 68, 9, 1 | 67, 66, 64, 68, 8, 1 |
| other daemons and agents | 176 | 174 |
| per-process domains | 58 | 57 |
| apps | 3 | 3 |

The labels that differ differ by one start each (feedbackd,
intelligenceplatformd, stickersd, nanoappregistryd, a widget extension:
on-demand starts late in the window). Fidelity is unchanged. A first
count of the main line right after the 2026-10-27 build had booted the
device gave 569: PosterBoard's descriptor batch ran again (each poster
extension 3–4 times instead of once) and 20 Metal compiler instances
started; a boot by a different build changes the device's own caches, so
counts compare only boots that follow a boot of the same build.

### 12.8 How far from 21.4 s, and the next step

- Today's quiet median with the new defaults is **38.4–39.9 s** (S2, S3,
  S4): 1.8–1.9 × the reference's 21.4 s. §11's ranks 1 and 2 gave about
  1 s (the port-lock changes, inside the spread); removing the log
  back-pressure made the boot slower (§12.4). The reference's senders do
  block on diagnosticd's queues of 6 too (§13.4); Ycode's block for longer
  because every hand-off waits for a host CPU on a saturated host, and
  with the CPUs given to diagnosticd the other programs take them instead.
- Without networking and the Duo's inner panel the same code boots in
  31.6 s (§12.5); 1.5 × the reference.
- The work before home is about 420 CPU seconds on 14 cores (§12.6): the
  floor is about 30 s even with every core busy, so 1.0 × needs less work
  before home, not other waits.

Next, in order of size:

1. **What networking costs before home** (about 6 s): which daemons do
   network work during the boot, and how much of it is Ycode's socket
   path (`sendto`, `recvfrom`, `ioctl` and the readiness scans run under
   L0: 15 414, 12 496 and 54 518 calls by home in the trap profile `t1`)
   against the guest's own work. A profile with `YCODE_NO_NETWORK=1`
   against the default, process by process (§1.1's per-program CPU), and
   on the reference the same daemons' CPU in the first 30 s.
2. **What the inner panel costs before home** (about 4 s): SpringBoard,
   backboardd and the render path drawing two panels; their CPU and the
   GPU host's work with `YCODE_FOLD_DISPLAYS=0` against the default.
3. Then the log path again: with less CPU contention its hand-offs get
   cheaper by themselves (§12.4's profiles show its cost is CPU waits).
## 13. Reference logging path (agent B3-SIMOBS, 2026-11-05)

Black-box answers to the questions of §8.6 and §11.2 item 1 about the
reference: how fast the guest's processes log during a boot, where the
messages queue in diagnosticd, what happens when the queues fill, and how
long the boot takes on this Mac.

### 13.1 Conditions

| Item | Value |
|---|---|
| Host | arm64 Mac, 14 cores, 36 GB, macOS 27.2 (26B5112a), Xcode 27.1 (27A9269) |
| Runtime and device | iOS 27.1 (24A94401), iPhone Duo: the runtime and device type of Ycode's golden device and of `parity-ladder.md` §2 |
| Devices | a new device per run (`ycode-test-simobs-boot-1` … `-5`), first boot to the home screen, `simctl shutdown`, 3 s, then the measured **second (subsequent) boot**, all headless (`simctl bootstatus -b`); a sixth, untimed probe boot (§13.4) on another throwaway device |
| End point | `home_s` of `parity-ladder.md` §1 (first primary-display screenshot with mean brightness > 60, polled about once a second). In 4 of 5 boots the Settings icon and the wallpaper appeared in the same screenshot; in run 3 the icons came 3.9 s earlier (23.9 s) |
| Counters | diagnosticd's own Mach receive counter (`top -stats msgrecv`, every 1–3 s; the host was too loaded for 1 s), its port space (`lsmp`, about 8 samples a second: `qlimit` and `msgcount` of every receive right), its thread priorities (`ps -M`, every 0.5 s); the device's log store read afterwards with `simctl spawn … log show --info --debug` (every event with its process and timestamp) |
| Host load | **Very high**: 1-minute load average 463–690 at the boot starts (other agents' builds, an Android emulator, VMs); no other simulator device booted. The times are therefore slower than `parity-ladder.md` §3.1's (load 4–10); the rates per second are counts and less sensitive |

### 13.2 Time to the home screen

| Run | home_s | bootstatus_s | diagnosticd running at | load (1 min) at start |
|---|---|---|---|---|
| 1 | 25.7 | 14.2 | 1.8 s | 576 |
| 2 | 29.0 | 13.8 | 1.7 s | 547 |
| 3 | 27.8 | 12.8 | 1.2 s | 690 |
| 4 | 30.0 | 10.9 | 2.3 s | 573 |
| 5 | 24.7 | 8.4 | 1.7 s | 463 |
| **median** | **27.8** (mean 27.4 ± 2.2) | 12.8 | 1.7 s | — |

`parity-ladder.md` §3.1 measured 21.4 ± 2.3 s for the same boot on a much
less loaded host; both are reference figures, and 21.4 s stays the one to
compare Ycode's 30 s with (`lean-boot.md` §9), because the host load here
was 50–100 times higher.

### 13.3 Message rate

diagnosticd receives **one Mach message per log event**: its receive
counter tracks the number of events the log store holds for the same
interval (activity-creation events included) to within 0.2–2 k messages
(1–7 %), a constant offset made by the events logged before diagnosticd
was running. So the reference's processes forward every message to
diagnosticd during the boot, as in Ycode (`launchd-sim.md` §8.1). The
log filter it writes is the same as in Ycode:
`DEV/data/Library/Preferences/Logging/com.apple.diagnosticd.filter.plist`,
`global` = 0x9_0007_0000 (38 655 164 416), and its own log records the
same system-mode client of itself (mode 0x9, empty filter).

| Measure (second boot) | Runs 1–5 | Median |
|---|---|---|
| Events in the first 30 s | 77 510, 80 872, 90 602, 87 128, 99 396 | 87 128 |
| **Mean rate, first 30 s (messages/s)** | 2 584, 2 696, 3 020, 2 904, 3 313 | **2 904** |
| Median of the 1-s counts, boot start to home | 2 720, 2 768, 2 961, 2 769, 3 348 | 2 769 |
| **Peak 1-s count** (in the first 10–15 s) | 6 041, 6 152, 7 705, 5 459, 9 492 | **6 152** |
| diagnosticd's receive counter at home | 83 224 … 89 861 | about 89 000 |
| Programs that logged before home | 129, 150, 162, 161, 160 | 160 |
| After home (30–60 s) | 50–400 a second, falling | — |

Ycode's 3 600 a second (§8.5) is within the reference's range; the
message volume is not the difference.

By process (boot start to home; medians over the 5 runs):

| Process | Messages | Share | Mean/s | Peak 1-s | Median 1-s |
|---|---|---|---|---|---|
| runningboardd | 12 404 | 14.0 % | 418 | 1 513 | 299 |
| SpringBoard | 11 525 | 13.4 % | 400 | 2 391 | 109 |
| PosterBoard | 4 110 | 4.6 % | 147 | 1 183 | 0 |
| launchd_sim | 4 107 | 4.6 % | 138 | 575 | 95 |
| locationd | 3 379 | 3.9 % | 122 | 1 130 | 25 |
| cfprefsd | 2 962 | 3.5 % | 103 | 274 | 100 |
| sharingd | 2 368 | 2.7 % | 85 | 1 263 | 0 |
| apsd | 1 843 | 2.3 % | 71 | 540 | 18 |
| chronod | 1 784 | 2.3 % | 72 | 601 | 3 |
| mobileassetd | 1 804 | 2.2 % | 62 | 773 | 0 |
| callservicesd | 1 703 | 2.0 % | 61 | 880 | 0 |
| UserEventAgent | 1 580 | 1.9 % | 60 | 356 | 2 |

Most senders log in short bursts (median 1-s count 0); runningboardd,
SpringBoard, cfprefsd and launchd_sim log steadily through the boot.

### 13.4 Where the messages queue, and the queue limit

diagnosticd's port space during a boot (`lsmp`, all 5 runs and the probe
boot):

| Receive right | Count | `qlimit` | Held as a send right by |
|---|---|---|---|
| The service port (`com.apple.diagnosticd`; flags guarded, strict, importance) | 1 | **16** | 156 of the device's 177 processes |
| **One receive right per client connection** (importance flag) | 134–166 (one per connected process; grows with the boot) | **6** | exactly one process each |
| Others (notifyd's, diagnosticd's own, 4 unused) | 6 | 5 or 16 | 0–1 |

- The log messages queue on the **per-connection** receive rights, not on
  the service port: every receive right seen full had exactly one sender
  process holding a send right to it (28 of 28 in the probe boot), and the
  service port's queue held at most one message in any sample.
- **The per-connection queues fill.** In 23–29 % of the samples from boot
  start to home at least one connection queue held 6 of 6 messages
  (msgcount = qlimit); per run 56–83 full-queue observations. The messages
  queued in all of diagnosticd's ports together: median 1–2, maximum
  23–51. The connections seen full in the probe boot belonged to
  runningboardd (9 observations), SpringBoard (7), chronod (4), locationd,
  sharingd (3 each), and 23 other processes (1–2 each); cfprefsd's was full
  once.
- **Senders block; nothing is dropped.** No message is lost: the receive
  counter equals the store's event count (§13.3), the store shows no loss
  events, and neither diagnosticd's nor logd's own log
  (`DEV/data/var/db/diagnostics/{diagnosticd,logd}.0.log`) reports a drop,
  quarantine or throttle. Call-stack samples (`sample`, 1 ms, 2 s) of
  senders during the boot show the send in the kernel's message send
  under the log-streaming path (`_os_log_impl_stream` →
  `_xpc_send_serializer` → `mach_msg2_trap`), i.e. a blocking send:
  runningboardd at 4 s: 15 of about 1 500 samples of its busiest thread
  (1 %); at 19 s: 67 (about 4 %); cfprefsd at 9 s: 1 of 1 758. So the
  reference's senders do wait on diagnosticd, but briefly: a few percent of
  a thread's time, against runningboardd's 27.8 s of 36 s in Ycode (§8.5).
- SpringBoard at 14 s spent 402 of its home-screen queue's 1 045 samples in
  the log-streaming path, only 17 of them in the send: the stream costs the
  sender CPU (formatting and encoding each message), not waiting.
- **The limit itself is the guest's**: per-connection queues of 6 and a
  service port of 16 on the reference. Ycode's guest software is the same,
  so a per-connection queue limit in Ycode that differs from 6 would be
  Ycode's port code, not launchd_sim's setting; compare with the
  `MACH_PORT_LIMITS_INFO` of the same rights in a Ycode boot.

### 13.5 diagnosticd's threads and the host end

- **No elevated priority.** `ps -M` over the boot (about 45 samples per
  run, up to 34 threads): 31 in 87–96 % of thread samples, 28–30 otherwise
  (timeshare decay), and 36, 37, 46 or 47 in 1–5 thread samples per run
  (short overrides while a higher-priority sender waits). 31 is the
  default QoS priority; no thread runs at user-interactive (47) or
  user-initiated (37) priority for more than a sample.
- The receiving threads are dispatch workloop threads, as in Ycode
  (`launchd-sim.md` §8.1): idle samples of diagnosticd show its message
  handler waiting in `dispatch_sync` for its own queue (`kevent_id`).
- **The host end exists on the Mac.** `/private/var/run/.sim_diagnosticd_socket`
  (owner root:daemon) is a socket of the host's `com.apple.diagnosticd`
  launchd job (`launchctl print system/com.apple.diagnosticd`: `sockets`,
  path as above). The host's diagnosticd (root) starts on demand about 1 s
  after the simulator's diagnosticd starts and connects; during the first
  boot of the exploratory device it used 38 s of CPU in 2.5 min, the
  simulator's diagnosticd 50 s. So on the Mac the simulator's whole log
  stream is forwarded and consumed on the host during the boot (Ycode
  leaves its host end off by default, `launchd-sim.md` §8.1).
- The device also runs its own `logd` (store in
  `DEV/data/var/db/diagnostics/`, with `logdata.statistics.0.jsonl`, logd's
  byte counts per process at each file rotation).

### 13.6 Consequences for Ycode

1. The message rate is the same (2 900/s reference, 3 600/s Ycode); Ycode
   must not reduce it, it must carry it.
2. The reference's senders block on full 6-message per-connection queues
   too, but for 1–4 % of a sender thread's time; in Ycode runningboardd
   blocked 77 % of the boot (§8.5). The difference is diagnosticd's
   drain rate per connection, i.e. the cost of one receive and wake-up in
   Ycode (§11.2 item 1, options a and b), not the queue limit.
3. Option (c) of §11.2 item 1 (match the queue limit) has nothing to match
   if Ycode's per-connection rights also have `qlimit` 6; check that first.
4. Priority: the reference gives diagnosticd's threads no standing boost;
   (b) of §11.2 item 1 is a Ycode-specific remedy, not parity.

## 14. Guest networking and the inner panel, measured (agent B3-BOOT2, 2026-11-06)

§12.8's next steps 1–3: what guest networking (about 6 s) and the iPhone
Duo's inner panel (about 4 s) cost before home, with both kept on, and the
log path after that. Target: home_s ≤ 21.4 s, full boot, every service on.

### 14.1 Conditions

- Thor; a copy of the golden device in the agent's own folder (the
  `parity-ladder.md` device type, iPhone Duo, iOS 27.1), booted at that
  path four times before the first series; full boot, default switches,
  `YCODE_HOME_WATCH`, stopped 5 s after home, no save.
- Timed series under the shared boot-timing lock; each boot started only
  when no other `ycode-simd` ran and the 1-minute load was under 4 (it was
  0.4–3.99); arms rotated each round, n = 5 per arm.
- Builds: *base* = the main line `17c71c17` (§12's changes included);
  *tree* = this section's change on top. Arms of one series are one binary
  with switches.
- Profiles: `YCODE_FRAME_PROFILE_BOOT=120` and `YCODE_TRAP_PROFILE` in the
  same boot (no holder sampler), analysed with `scripts/ycode-frame-profile`
  (`--boot --backbone SpringBoard:main`, `--blocked-sends 0x10000000`,
  `--thread`) and two small readers of the window's trace (log sends and
  traps per program up to a given time). Profiled boots are not timed.
  Guest log lines come from a `log stream` one-shot in separate, untimed
  boots.

### 14.2 Networking: apsd's reconnect storm, not Ycode's socket path

Profiles `p-on` (home 42.1 s) and `p-nonet` (`YCODE_NO_NETWORK=1`, 33.8 s):

| | p-on | p-nonet |
|---|---|---|
| traps by the trap profile's end (56 s, 49 s) | 3.32 M | 2.63 M |
| `socket` (97) / `ioctl` (54) / `sendto` (133) / `recvfrom` (29) in the boot window | 5 631 / 39 607 / 6 625 / 6 079 | 639 / 784 / 5 309 / 4 745 |
| of them apsd's | 4 548 / 35 057 / 261 / 185 | 0 / 0 / 0 / 0 |
| L0 held by those four traps (trap profile) | 0.81 s of 10.0 s (L0 17.8 % busy) | 0.48 s of 8.4 s |
| log messages (id 0x10000000) in the window | 180 776 | 130 953 |
| of them apsd's | 19 303 | none |

Ycode's own socket path is cheap: the four socket traps hold L0 0.8 s in
a 56 s profile (an `ioctl` 3 µs, a `socket` 9 µs, a `sendto` 16 µs), the
host socket poller does not show, and almost all of the IP socket and
interface `ioctl` calls are apsd's. The extra 0.7 M traps
and 50 000 log messages come from **apsd**: in a log stream of the same
boot apsd opened its courier stream to `courier.sandbox.push.apple.com`
171 times in 60 s (2.9 a second): resolve, TCP, a TLS 1.3 handshake (187
completed, 208 trust evaluations by trustd), then

1. "activating connection … name=com.apple.CoreSimulator.SimIdentityService",
   "failed to do a bootstrap look-up: xpc_error=[3: No such process]"
   (once; every later certificate request fails at once);
2. "Could not get certificate from simulator with error … Code=100
   "Connection invalid" … Aborting…", "Refreshing cert/nonce/sig failed,
   not sending a presence";
3. "_disconnectStream … with reason: 14", "Connection closed", and at once
   "attempting to _connectStream … consecutiveFailures 0": a disconnect
   for this reason does not count as a failure, so there is no back-off.

Each round also tells apsd's clients ("Dispatching xpc to client", about 25
a round), which wake and log ("Delivering connectionStatusChange from
apsd: NO" in mobileassetd and others). The reference's apsd logs 1 843 messages
before home (§13.3), Ycode's 19 303: the storm is Ycode's, caused by the
host-side name `com.apple.CoreSimulator.SimIdentityService`, which the
reference's host registers (`launchd-sim.md` §6.3) and Ycode did not.

The boot is throughput-bound (§12.6), so the storm costs home time through
the CPU and the log path it takes from everything else: in the first 30 s
of each profile the whole guest made 2.45–2.51 M traps and 101 000–111 000
log sends whatever the arm, but SpringBoard got 68 543 of the traps and
5 703 of the log sends in `p-on` against 155 253 and 17 008 in `p-nonet`.

Timed (series T1, base binary): apsd alone off (`YCODE_LEAN_BOOT=1` with
every default label kept and only `com.apple.apsd` disabled, a diagnostic
arm) is as fast as no networking at all: the whole networking cost is the
storm.

### 14.3 The change: a host-side simulator identity service

`SimIdentityHostService` (`ycode/Sources/YcodeHostServices/`) registers
`com.apple.CoreSimulator.SimIdentityService` with the other host-side
names (queued with the late ones, `DeviceSession.lateHostServices`). It
speaks the XPC connection protocol Ycode's Metal host already serves
(hand-shake 0x77303074: the connection port and the client's send right;
requests 0x10000000 with one `!CPX` dictionary). A Linux host has no
Apple-issued simulator identity to give, so the service **keeps each
request's reply right and never answers**; the rights go when the
connection ends (no-senders). apsd's request (keys `operation`, `version`,
logged once by name) then never completes, apsd does not abort and does
not reconnect: in a log stream of the tree's boot apsd opened one courier
connection ("Connected to courier …"), sent its presence request to the
service and logged 2 053 lines in the whole run, against 49 728 before;
"Could not get certificate" did not appear. Push notifications do not work
either way (no identity), as before.

| | |
|---|---|
| Switch | `YCODE_SIM_IDENTITY_SERVICE=0`: not registered (the behaviour before) |
| Default | on |
| Snapshot | a `sim-identity` host-service record (connection ports, client rights, held reply rights); the restored service keeps them unanswered |
| Tests | `SimIdentityHostServiceTests` (no reply and no dead reply right while the connection lives, released at its end, one log line per key set; a restored service keeps its connections and held requests; other messages on the service port are dropped) |

This is not the reference's answer: the reference gives apsd a
certificate. What the service is asked and answers on the reference
(the request and reply keys and values, and whether apsd stays connected)
is a dirty-room question (§14.8).

### 14.4 The inner panel: SpringBoard's own work, not Ycode's display path

- **Frames.** The frame records at home: the cover 87–114 frames, the inner
  panel 35–55 (it is dark while closed; the guest draws it only when its
  content changes, `simframebuffer.md` §5.1). The guest's swaps cost Ycode
  one 96-byte `pwrite` of the record each.
- **No viewer, no encoding.** The display server encodes and sends frames
  only inside a viewer session (`DisplayServer.swift`), and then only the
  panel shown; the timed boots run without a display server. Nothing in
  the host watches or copies the inner panel's frames.
- **Where the time goes.** Two pairs of profiles, before and after the
  change of §14.3, with and without the inner panel
  (`YCODE_FOLD_DISPLAYS=0`):

  | | `p-on` / `p-nofold` (base) | `p-tree` / `p-tree-nofold` (tree) |
  |---|---|---|
  | windows (home) | 44.8 s (42.1) / 42.0 s (39.3) | 36.8 s (34.2) / 36.6 s (33.9) |
  | all guest programs' CPU in the window | 430 / 386 s | 317 / 315 s |
  | SpringBoard: CPU (guest code) | 23.7 (17.9) / 20.6 (15.5) s | 22.9 (17.4) / 20.8 (15.3) s |
  | backboardd: CPU | 2.4 / 1.8 s | 2.4 / 1.9 s |
  | AegirPoster (draws the panels' poster): minor faults | 3 725 / 313 | — |

  SpringBoard does 2.1–2.4 s more guest code with the second display, and
  its main thread is the boot's backbone; backboardd and PosterBoard add
  about half a second each. That is the guest's own work for a second
  display (its scenes, layout and poster), which the reference does too
  (§13's reference boots are iPhone Duo boots).

No change: the inner panel's cost is the guest's code at native speed;
Ycode adds nothing per frame that could be skipped. The GPU host's share
(35–55 frames of 2007 × 2853) was not measured separately and is not
changed here.

### 14.5 The log path, after the storm

Profile `p-tree` (the tree, home 34.2 s) against `p-on` (§14.2):

| | p-on | p-tree |
|---|---|---|
| CPU of all guest programs in the boot window (window) | 430 s (44.8 s) | 317 s (36.8 s) |
| log messages in the window | 180 776 | 139 378 (3 800 a second) |
| apsd's / mobileassetd's | 19 303 / 8 682 | 1 921 / 8 423 |
| thread-seconds blocked in log sends | 530 | 300 |
| diagnosticd's CPU: all / guest / VMM | 20.8 / 3.0 / 12.8 s | 14.4 / 2.1 / 8.9 s |
| diagnosticd's share of the boot's critical path (`--boot`, by program) | 18.9 of 41.8 s | 10.4 of 33.8 s |

- apsd now logs as much as the reference's (1 921 against 1 843, §13.3);
  mobileassetd still logs 4–5 times the reference's 1 804, most of it
  Biome storage errors ("Failed to move temporary segment … Replace
  failed", "Failed to instantiate framestore") for its asset-delivery
  stream: a candidate fidelity bug in the file calls biomed makes for
  Biome's segment replacement (§14.8).
- **diagnosticd is latency-bound, not CPU-bound.** Its 45 threads spent,
  from 5 to 30 s, 56 % of their time waiting for another diagnosticd
  thread (the workloop sync waits and wakes of §12.2), 35 % waiting for a
  message or a timer, 3.7 % in lock waits, and 0.2 % in guest code. Each
  message costs about 100 µs of host CPU (64 µs VMM, 15 µs guest, the rest
  host kernel), so its CPU is not the limit; the hand-offs, each a futex
  wake that waits for a host CPU on a saturated host, are. On xnu the same
  hand-off is a direct switch to the woken thread.
- With the storm gone, diagnosticd's share of the critical path fell from
  18.9 to 10.4 s (`p-nonet`: 10.9 s); it is still the largest item on the
  path. The rest of the path is other daemons' guest code and run-queue
  waits, a different set in every profile (the host is saturated: 10–12
  cores busy and as many threads runnable).

### 14.6 Timed series

| Series | Arm | n | median home_s | mean ± sd | range | kernel lock held at home, median | guest fatal |
|---|---|---|---|---|---|---|---|
| T1 (base) | default | 5 | **37.17** | 37.43 ± 2.98 | 34.97–42.42 | 7.2 s | 3–4 |
| T1 | apsd disabled (diagnostic) | 5 | **32.18** | 31.92 ± 0.64 | 31.10–32.68 | 6.0 s | 3–5 |
| T1 | `YCODE_NO_NETWORK=1` | 5 | 31.81 | 31.89 ± 0.74 | 31.00–33.06 | 6.0 s | 4–6 |
| T2 (tree) | default (identity service on) | 5 | **33.93** | 33.74 ± 0.75 | 32.43–34.33 | 6.6 s | 4–5 |
| T2 | `YCODE_SIM_IDENTITY_SERVICE=0` | 5 | 35.95 | 35.78 ± 0.67 | 35.03–36.68 | 6.8 s | 3–4 |
| T2 | `YCODE_FOLD_DISPLAYS=0` | 5 | 32.35 | 32.26 ± 0.60 | 31.35–32.97 | 6.6 s | 3–6 |

B3-BOOT2 also ran a series T3, but it was stopped before writing T3 into
this table; §16's U1 and U2 series supersede it.

- **The identity service: −2.0 s by the median** (T2: 33.93 against 35.95,
  ranges apart), every service on, networking and the inner panel on.
- **Networking costs nothing beyond apsd's storm** (T1: apsd alone off
  32.18, networking off 31.81; base 37.17).
- **The inner panel costs 1.6 s** with the storm gone (T2: 32.35 without
  it), against 3.9 s in §12.5's S4.
- The storm's cost varied from series to series (T1's default arm
  34.97–42.42, its first boot the slowest; T2's `idoff` 35.03–36.68),
  probably with how fast the courier answered (each round is a TLS
  handshake with it).

### 14.7 Service fidelity

`scripts/ycode-launchd-spawns` over 700 s of a full boot (as §12.7), the
base binary against the tree, each after a boot of the same build, on the
same device copy:

| | base | tree |
|---|---|---|
| all starts | 620 (218 labels) | 623 (217 labels) |
| restart loops (facetimemessagestored, managedappdistributiond, mlhostd, proactiveeventtrackerd, intelligencetasksd, fileindexerd) | 67, 66, 64, 68, 5, 1 | 67, 67, 64, 68, 7, 1 |
| other daemons and agents | 309 | 309 |
| per-process domains | 37 | 37 |
| apps | 3 | 3 |
| starts by reason (xpc event, demand, Mach IPC, speculative) | 316, 150, 106, 32 | 318, 151, 106, 32 |

The labels that differ differ by one or two starts each
(intelligencetasksd +2, PosterBoard, managedappdistributiond,
imageplaygroundd and a key-sync agent +1; backgroundassets.user, fitcore,
intelligenceplatformd −1: on-demand starts and the throttle loop's
phase). Fidelity is unchanged. (§12.7's 508–511 were counted on another
device copy, whose state differs: counts compare only boots of one
device.)

### 14.8 How far from 21.4 s, and the next steps

- With every service on, guest networking on and the inner panel on, the
  quiet median is now **33.9 s** (T2): **1.59 ×** the reference's 21.4 s,
  12.5 s short. Before this change it was 36.0–37.2 s (T1, T2).
- The boot is still throughput-bound: 366–373 CPU seconds before home at
  about 11 busy cores (`cpu_s_at_home` of the tree's profiled and fidelity
  boots, home at 34.2 and 33.7 s). At 14 fully busy cores the same work takes 26 s, so
  1.0 × on the Thor needs about a third less work before home, not other
  waits.
- Ycode's own share of that work is about a quarter (VMM 46 s and host
  kernel 31 s of 317 s in `p-tree`'s window); the rest is guest code at
  native speed (§10.4: one Thor core is 0.9–1.8 × slower than the Mac's).
  Removing all of Ycode's overhead would not reach 21.4 s by itself.

Next, in order of size:

1. **Guest work the reference does not do.** Before home, Ycode's guest
   sends 129 500 log messages (`p-tree`), the reference about 89 000
   (§13.3). The programs with the largest excess against §13.3's table are
   leads like apsd's: SpringBoard 21 800 (reference 11 500), mobileassetd
   8 400 (1 800; Biome's "Replace failed", §14.5), dasd 7 200 (under 1 600;
   mostly "com.apple.coreduetd.context … lookup error 3", a name no launchd
   plist in the runtime publishes, so the reference may fail the same way
   and why it logs less there is open) and biomed 4 300 (under 1 600). Each
   needs a log stream and, where a Ycode call fails, a fix of that call.
2. **The log path's hand-offs** (10.4 s of the critical path, §14.5):
   diagnosticd's threads wait for each other 56 % of the time; a direct
   hand-off for a workloop sync wake (the woken thread gets the waker's
   host CPU) would make each hand-off cheap as on xnu. §12.4's lesson
   applies: measure the whole boot, since a faster log path also lets the
   other daemons take more CPU.
3. **Ycode's per-trap CPU** (about 100 µs of host CPU per log message in
   diagnosticd, 64 µs of it VMM code; event-lock holds of 43 µs in
   `workq_kernreturn` and 24 µs in `kevent_id` on average): less work under
   the event lock and per trap.
4. **For the orchestrator, a dirty-room question:** what
   `com.apple.CoreSimulator.SimIdentityService` is asked and answers on the
   reference (request and reply keys and value types; whether apsd then
   stays connected to the courier, and how often it reconnects), so that
   Ycode's service can answer as the reference does where an identity
   exists, or confirm that leaving the request unanswered is the closest
   behaviour on a host without one.

## 15. Reference: guest log sources and the identity service (agent B3-SIMOBS2, 2026-11-06)

Black-box answers to §14.8 item 4 (what `com.apple.CoreSimulator.SimIdentityService`
is asked and answers on the reference, and what apsd does afterwards) and to
§14.8 item 1 (whether the reference logs the patterns behind Ycode's excess
in SpringBoard, mobileassetd, dasd and biomed).

### 15.1 Conditions

| Item | Value |
|---|---|
| Host | as §13.1 (arm64 Mac, macOS 27.2, Xcode 27.1) |
| Runtime and device | iOS 27.1 (24A94401), iPhone Duo |
| Boots | 5 new devices (`ycode-test-simobs2-1` … `-5`): first boot (to the home-screen icons, then 60 s), `simctl shutdown`, 3 s, then the measured **second boot**, headless, with §13's end point and screenshot polling; deleted afterwards. A sixth device (`ycode-test-simobs2-probe`) for untimed probe boots |
| Window | 125 s from the second boot's start |
| Guest | `simctl spawn … log show --info --debug --style ndjson` of the whole window. The simulator's log system already runs with private data shown (`log config --status`: `INFO STREAM_LIVE PRIVATE_DATA`), so nothing more is visible with a changed mode |
| Host | `log stream --info --debug` of `com.apple.CoreSimulator.CoreSimulatorService` and `mobileactivationd` during the second boot; the persisted host log afterwards |
| Counted boots | no sampler attached to a guest process; `sample` and `lsmp` of apsd only in the probe boots |
| Host load | very high, as in §13: 1-minute load 435–550 at the second boots' starts. home_s 25.8 s median (24.2–39.2) |
| Ycode, for comparison | §14.8's counts (profile `p-tree`, before home, all levels) and B3-BOOT2's guest `log stream` one-shots `diag-tree-sb` (SpringBoard, biomed, mobileassetd) and `diag-tree-busy` (dasd), level Info, counted over the first 30 s of the stream |
| §13's boots | re-read with the same counters (their log windows end at 64–92 s) as a second set of five |

Counts in §15.5–§15.7 cover the first 30 s from boot start (all levels,
Debug included) unless a row says otherwise. The Ycode streams carry no
Debug messages; for the four programs the reference's Debug share in the
first 30 s is under 0.1 % except mobileassetd (about 5 %).

### 15.2 Who connects to the identity service

- **Only apsd**, one XPC connection per boot, in all ten second boots
  (these five and §13's five): its "activating connection … name=
  com.apple.CoreSimulator.SimIdentityService" is the only one any process
  logs, and launchd_sim logs no failed look-up of the name.
- **When:** 5–21 ms after apsd's "Connected to courier" and its "Sending
  presence message" (courier connected at 5.0–6.7 s, median 5.8 s).
- **First boots:** in the first boot of a new device apsd does not enable
  its couriers within the observed 100–110 s ("we have not yet enabled
  couriers") and does not contact the service; one probe device's first
  boot contacted it about 130 s after the boot started.
- **The host end** is `com.apple.CoreSimulator.CoreSimulatorService` (the
  per-user host service): the name resolves to an anonymous XPC listener in
  it, which logs a peer connection named after apsd's pid within 1 ms of
  apsd's activation. `lsmp` cannot see that process's ports without root,
  and apsd cancels its connection after the exchange, so no port of the
  service was observed.

### 15.3 What crosses the connection

Request and reply keys are not visible on the reference: neither apsd nor
the host service logs them, the message bodies do not appear in any log,
and `sample` of apsd at 1 ms (15 s from its start, probe boot) caught none
of the 10–15 ms exchange. What the logs on both sides show:

| t (s, median of 5) | Guest (apsd) | Host |
|---|---|---|
| 0 | activates the connection (presence pending) | accepts the peer connection |
| +0.53 (0.52–0.66) | — | asks the host's activation daemon (`mobileactivationd`) for a client certificate, because the device has none yet (§15.4) |
| +1.44 (1.30–3.69) | — | issuance done (0.77–3.03 s: a new SEP-held P-256 key, attested by the system key, certified by an Apple server over HTTPS); the host then reads its monotonic clock and RTC reset count from the same daemon |
| +1.48 (1.33–3.78) | "Generating nonce with timestamp T", "Signature input is 17 bytes" | — |
| nonce + 5–6 ms | — | signs with the device's SEP key: ECDSA, X9.62 encoding, SHA-256 |
| nonce + 6–13 ms | "APSSimulatorSupport generate nonce and sig success? YES" | — |
| success + 50–150 ms | "Connected response ok for user courier token? YES" | — |

- **Two exchanges.** The nonce is generated only after the host's
  certificate work finishes, and the host signs 5–6 ms after the nonce
  exists. So apsd first asks for the identity (certificate) and waits for
  it, then sends the bytes to sign and gets the signature. When the device
  already has an identity (probe boots of one device), the whole exchange
  takes 12–19 ms and the host only signs.
- **The bytes signed** (from apsd's own log line): 17 bytes, byte 0 = 0x00,
  bytes 1–8 = T as a big-endian count of milliseconds since 1970, a whole
  second (the value in "Generating nonce with timestamp"), bytes 9–16 = 8
  further bytes that differ every time (the nonce).
- **The identity** (host log): a leaf certificate for the new key issued by
  "Basic Attestation User Sub CA1", returned with that intermediate
  (chained to "Basic Attestation User Root CA"), valid from one day before
  issuance for about 350 days, plus a server timestamp. The leaf's subject
  is an identifier, not recorded here.
- So the reply to the first request most likely carries a certificate
  chain (and possibly the clock values); the reply to the second, a
  signature over the 17 bytes. Key names and value types remain unobserved.
- Ycode's own service logged the first request's keys `operation` and
  `version` (§14.3); nothing on the reference contradicts or confirms them.

### 15.4 Lifetime of the identity

- **One key and certificate per device.** Each of the five devices got a new
  key (a different key id) and a new certificate at its first request.
  The probe device's later boots reused its key (same key id), and the
  host asked for no certificate.
- The issuance needs the host's SEP, its activation identity and a
  connection to an Apple server. A host without these has no identity to
  give; this Mac could not be made into one with the tools allowed here.

### 15.5 apsd and the push courier, 0–125 s

| Run | courier connected (s) | connections | identity: activation to success | "Could not get certificate" | disconnects after connecting | apsd messages, 30 s |
|---|---|---|---|---|---|---|
| 1 | 6.60 | 1 | 1.33 s | 0 | 0 | 1 725 |
| 2 | 5.24 | 1 | 1.40 s | 0 | 0 | 1 870 |
| 3 | 6.73 | 1 | 1.58 s | 0 | 0 | 1 895 |
| 4 | 5.83 | 1 | 3.78 s | 0 | 0 | 1 995 |
| 5 | 5.03 | 1 | 1.49 s | 0 | 0 | 1 690 |

- apsd connects to the courier **once and stays connected**: no disconnect,
  no reconnect and no certificate failure in 125 s in any run (§13's five
  boots agree over their 64–92 s windows). The two disconnects each boot
  logs (reason 2, at 3–4 s) come before the first connection.
- apsd's volume matches Ycode's after the change of §14.3 (1 921 before
  home, §14.5): reference 1 870 (1 690–1 995) in 30 s.

**Ycode's unanswered requests against the reference.** The reference
answers both requests (1.3–3.8 s for a new device, about 15 ms afterwards)
because this host has an identity; a host without one could not be observed
(§15.9). Leaving requests unanswered reproduces what the reference shows
during a boot: one courier connection, no reconnects, apsd at its
reference volume. It differs in what never completes: in B3-BOOT2's stream of
such a boot apsd generates no nonce, logs no "Connected response ok" and
gets no push token. A
reply that reports an error is not a safer choice on present evidence: a
failed certificate request (the missing name, §14.2) made apsd abort and
reconnect at once without back-off.

### 15.6 Log volume of the four programs

| Program | Reference, first 30 s: median (range), n = 5 | §13's boots, same count | Reference, boot start to home | Ycode, before home (§14.8) | Ycode stream, first 30 s (Info) |
|---|---|---|---|---|---|
| SpringBoard | **10 528** (9 333–12 021) | 11 525 (10 980–12 287) | 10 744 (8 944–12 059) | 21 800 | 16 737 |
| mobileassetd | **1 343** (1 257–1 845) | 1 804 (1 535–1 965) | 1 343 (1 249–1 571) | 8 400 | 8 054 |
| dasd | **287** (250–290) | 294 (277–312) | 287 (250–290) | 7 200 | 7 201 |
| biomed | **743** (736–769) | 726 (706–897) | 716 (713–760) | 4 300 | 4 148 |
| all programs | 76 687 (67 072–91 954) | 87 128 (77 510–99 396) | — | 129 500 | — |

### 15.7 Message patterns, reference against Ycode

Top 5 patterns of the reference (first 30 s, median per boot and range),
then the patterns of Ycode's stream that the reference does not log in its
first 30 s. "Absent" means no message of that pattern from any process in
the whole 125 s window of all five boots.

**SpringBoard.** Reference: RunningBoard monitor "Received state update
for … (…)" 363 (229–380); "Update skipped for …" 352 (0–648);
"observedProcessStatesDidChange" 306 (176–310); XPC "activating
connection … name=…" 218 (194–223); UIKit backlight environment "Updated
traitOverrides: …" 163.

| Ycode pattern (subsystem: category) | Ycode, 30 s | Reference |
|---|---|---|
| "constructing bundle record for file:…" (launchservices: privacy) | 1 599 | **absent** |
| "application record search init. Node: …" (launchservices: datasep) | 590 | **absent** |
| "Display Content Mode Transition Resolution for participant …" (SpringBoard: ZStack) | 144 | **absent** |
| "elapsedCPUTimeForFrontBoard task_info failed with …" (runningboard: process) | 64 | **absent** |
| "No data found at …" / "Saving file at … with N items" (UserNotifications: DataStore) | 381 / 115 | 0 in 30 s; 405 / 150 per boot at 70–107 s, in 3 of 5 boots |
| "kExcludedFromBackupXattrName set on path: …" (FileURL) | 112 | 5 in 30 s; 125–129 per boot in 3 of 5 boots (5 in the other two) |
| "Calcualate [sic] topics because user notification settings …" (UserNotifications) | 54 | 0 in 30 s; 54 after 30 s, in 3 of 5 boots |

The reference's own top patterns appear in Ycode's stream too, less often
(observedProcessStatesDidChange 130 against 306).

**mobileassetd.** Reference: network TLS "… handshake state: …" 48
(48–64); network "[C…] event: …" 36 (36–49); XPC "activating connection"
33 (31–37); "{flushPersistedStateCacheAndSetCachingBehaviour} | Flushing
persisted state …" 31; "assetType: … client: …, command: …" 26 (25–32).
**The reference does not log Biome's "Replace failed"**: "Failed to move
temporary segment … into segment list" is absent, as is the rest of the
chain Ycode logs about 99–151 times each in 30 s:

| Ycode pattern (Biome storage, in mobileassetd) | Ycode, 30 s | Reference |
|---|---|---|
| "Successfully mapped file: … address: … size: …" | 302 | 2 in 30 s, 2–4 per boot |
| "Attempted to open … for writing but the file is already full, and has an EOF" | 151 | **absent** |
| "Failed to instantiate framestore with path: …" | 151 | **absent** |
| "lastFrameStoreOrCreateWithTimestamp: Attempting to create new frame store" / "… to acquire lockfile" / "Unable to … and creation also failed" | 99 each | **absent** |
| "Failed to move temporary segment … into segment list with error" | 99 | **absent** |
| "Failed to assign a frameStore for: …", "Error saving biome store event" | 99 each | **absent** |
| "Activity for state dumps" | 113 | **absent** in mobileassetd |
| "[PallasNonce:…] Params details for SetElement …" (mobileassetd: Download) | 109 | 27 in 30 s; 126–323 per boot in 3 of 5 boots |

**biomed.** Reference: XPC "activating connection … name=com.apple.biome.
access…" 83 (81–92); "-fileHandleForFileAtPath:flags:protection:reply:
called with subpath: …" 76 (71–84); "Incoming connection from …(pid)" 61
(59–71); XPC "invalidated because the client process … cancelled the
connection or exited" 52 (45–62); "Wrote new active subscription marker
with success: …" 43 (43–45).

| Ycode pattern (Biome) | Ycode, 30 s | Reference |
|---|---|---|
| "Found log with eventBootUUID: …, at eventDate: …" | 500 | **absent** |
| "fclonefileat() failed: [2: No such file or directory]" | 129 | **absent** |
| "bm_replace_file() failed" | 129 | **absent** |
| "-temporaryFileHandleWithProtection:reply: called" | 129 | 4 in 30 s; 4–37 per boot |
| "-replaceFileAtPath:withFileHandle:protection:flags:reply: called …" | 100 | 4 in 30 s; 4–37 per boot, none failing |
| "-fileHandleForFileAtPath:… called" | 332 | 76 |

The reference's clients ask biomed for the same temporary-file-and-replace
operation (4 times in 30 s) and it never fails; in Ycode biomed's
`fclonefileat` fails with ENOENT on every replace, and each failure sets off the
client-side retry chain of the mobileassetd table (about ten lines per
failure). `fclonefileat` is the public clone call (`clonefile(2)`).

**dasd.** Reference: XPC "activating connection" 27 (25–28); "CoreDuet:
ClientContext objectForContextualKeyPath:" 12 (12–13); coreduet: context
"error getting value for …" (its error names `com.apple.coreduetd.context`
and look-up error 3) 11 (11–12); triald "Namespace resolver file not
present: …" 9; "Loaded immediate runtime config for …" 9.

- **The reference logs the same look-up failure.** launchd_sim logs one
  failed look-up of `com.apple.coreduetd.context` per requesting process
  (dasd, sleepd), and dasd logs the error for each context key path it
  reads: 19–20 times in the first 30 s (all of them in the first 10 s),
  and **139–3 244 per boot in the 125 s window** (median 1 083), mostly for
  `/device/keybag/isLocked`, then `/device/system/isPluggedIn` and
  `/device/system/batterySaver`. Ycode's mix of key paths is the same.
- **When.** On the reference dasd logs 250–290 messages in its first 10 s,
  then **nothing from 10 to 30 s in all five boots**, and resumes at 32–49 s
  (median 41 s; 7–17 s after home) with "Running activities", activations
  of `com.apple.bg.system.task` and context reads, at a rate that grows to
  up to 3 700 messages in 10 s by 110–120 s. Ycode's dasd has no quiet
  phase: its context reads come in bursts at 5–10 s, 25–30 s and 40–45 s of
  the stream, 1 466 failures in the first 30 s, before home.
- The late wave is strong in three boots (1, 4, 5: 1 083–3 244 context
  errors in dasd, SpringBoard's data-store lines of the table above) and
  weak in two (2, 3: 139 and 334 context errors, no data-store lines)
  within the 125 s window.
- Ycode-only in dasd: "Failed to read file …" (duetactivityscheduler: plist),
  21 in 30 s, absent on the reference.

### 15.8 Ycode-caused failures against reference behaviour

| Lead | Same as the reference? | Ycode's excess in 30 s |
|---|---|---|
| Biome replace: `fclonefileat` ENOENT in biomed, "Replace failed" chain in mobileassetd and other clients | **No: Ycode only.** The reference performs the same replaces without failure | about 1 500 in mobileassetd, 500 in biomed |
| LaunchServices bundle-record construction and record searches in SpringBoard | **No: Ycode only** (absent in 125 s) | about 2 200 |
| RunningBoard `task_info` failure, ZStack transitions (SpringBoard), activity-scheduler plist read (dasd) | **No: Ycode only** | about 230 |
| "Found log with eventBootUUID" (biomed) | Absent on the reference, but may depend on the device's history (§15.9) | 500 |
| dasd's `com.apple.coreduetd.context` look-up errors and activity runs | **Yes, the reference fails the same way**; it does this work only after home (from 32–49 s), Ycode within its first 30 s | about 4 400 |
| SpringBoard's UserNotifications data-store work, backup-exclusion xattrs, topic recalculation | **Yes**, at 70–107 s on the reference; within the first 30 s in Ycode | about 650 |

So two kinds of excess: failures of calls Ycode serves differently (the
first three rows, about 4 400 messages in 30 s across the four programs,
`fclonefileat` the clearest), and reference work that Ycode runs before
home instead of after it (the last two rows). The second kind is not a
failure to fix in a call; it is a question of what lets dasd and
SpringBoard start that work early (§15.9).

### 15.9 Open questions

1. **A host without an identity.** What the reference's host service
   answers when it cannot issue a certificate (no network to the issuing
   server, no SEP): an error reply, no reply, or a closed connection, and
   what apsd then does. Needs a reference host without an identity (for
   example a macOS virtual machine with Xcode and the iOS 27.1 runtime),
   which was not available here.
2. **The request and reply dictionaries.** Keys and value types were not
   visible at levels 3 and 4; the timing gives two exchanges (certificate,
   then a signature over 17 bytes).
3. **Why dasd and SpringBoard start their post-home work early in Ycode.**
   The reference's dasd is quiet from 10 to about 40 s; the trigger that
   ends the quiet phase was not identified. One candidate is the device's
   history: Ycode's golden device has been booted many times, the
   reference devices here were new (second boot), so overdue background
   activities or stored notification state could explain an immediate
   start. A reference boot of an aged device (or a Ycode boot of a new
   device) would separate the two.
4. **"Found log with eventBootUUID"** in Ycode's biomed: absent on new
   reference devices; the same device-history question as item 3.
5. LaunchServices "constructing bundle record" in Ycode's SpringBoard: the
   reference never takes that path; why Ycode's LaunchServices client does
   (its database or registration state) is for the clean side.

## 16. Excess guest work and the log path's hand-offs (agent B3-BOOT3, 2026-11-06)

§14.8's steps 1 and 2, with §15's reference patterns: the guest work Ycode
causes and the reference does not do, and a direct hand-off for the log
path. Target: home_s ≤ 21.4 s, full boot, every service on (networking and
the Duo's inner panel included).

### 16.1 Conditions

- Thor; a copy of the golden device in the agent's own folder (iPhone Duo,
  iOS 27.1), booted three times at that path before the first series; full
  boot, default switches, `YCODE_HOME_WATCH`, stopped 5 s after home, no
  save.
- Timed series under the shared boot-timing lock, every boot started only
  when no other `ycode-simd` ran and the 1-minute load was under 4 (it was
  3.50–3.97), arms rotated each round, n = 5 per arm.
- Builds: *base* = `016506aa` (§14's change included); *tree* = base with
  §16.2 and §16.5; *tree2* = this branch with §16.2–§16.5 and §15 merged.
  Arms of one build differ only by switches.
- Guest log lines from `log stream` one-shots and Ycode's trap traces
  (`--trace-name`) in separate, untimed boots; log messages per program
  from frame-profile windows (`YCODE_FRAME_PROFILE_BOOT=120`, send-only
  `mach_msg2` of id 0x10000000 up to the profile's own home); started
  programs with `scripts/ycode-launchd-spawns` over 700 s (§12.7).

### 16.2 Biome's "Replace failed": `fclonefileat` of an unlinked file

biomed hands its clients (mobileassetd, SpringBoard, dasd and others) a
temporary file for a Biome segment: it creates
`Library/Biome/tmp/.tmp.<random>` with `O_CREAT|O_EXCL`, **unlinks it at
once**, and sends the descriptor as a file port. The client fills it and
sends it back with `replaceFileAtPath:withFileHandle:`, and biomed clones
the descriptor into place with `fclonefileat(fd, AT_FDCWD, "<dir>/.tmp.<new>", …)`
and renames the clone over the segment. Ycode's `fclonefileat` copied the
source by its **host path** (`HostClone.cloneTree(from: hostPath …)`), which
no longer existed: ENOENT on every replace (152 in a boot), "Failed to move
temporary segment … Replace failed" in the client and §15.7's retry chain
(about ten lines a failure, 1 200 of mobileassetd's lines).

clonefile(2) clones the open file, not a name. The change: for a regular
file `fclonefileat` copies from the descriptor (contents with explicit
offsets, so the descriptor's offset does not move; the guest's extended
attributes, flags and times from the descriptor). Test
`fdClonesCopyTheOpenFileNotItsName` (an unlinked and a renamed source; the
offset unchanged). In a log stream of the tree, "fclonefileat() failed",
"bm_replace_file() failed" and "Replace failed" no longer appear.

### 16.3 mobileassetd's downloads: the `/.nofollow/` path prefix

mobileassetd's other excess is network work: its asset downloads (Pallas
catalog requests, then the assets themselves through nsurlsessiond's
background sessions, 3–57 MB each) all failed in every boot — "Task finished
with error … MADownloadNetworkingError", underlying "SZExtractorErrorDomain
Code=3 extractionPath was nil" and NSURLErrorDomain −1 — and were retried at
the next boot. nsurlsessiond names its download folders as
`/.nofollow/<data>/Library/Caches/com.apple.nsurlsessiond/Downloads/<client>/`
("Couldn't create directory at file:///.nofollow/… NSCocoaErrorDomain
Code=4", "__NSCFLocalDownloadFile: error 2 creating temp file", 128 such
paths in one boot). On xnu a path that starts with `/.nofollow/` is the rest
of the path looked up with NAMEI_NOFOLLOW_ANY; Ycode treated `.nofollow` as
a directory name, so every such call was ENOENT.

The change: `DarwinFileSystem.resolve` strips the prefix and looks the rest
up with no-follow-any (a symbolic link in any component is ELOOP). Test
`noFollowPrefixLooksUpWithoutLinks`.

### 16.4 SpringBoard, dasd, biomed: the other leads of §15.8

- **`task_info`** (SpringBoard, §15.7): FrontBoard's
  `elapsedCPUTimeForFrontBoard` asks for **TASK_THREAD_TIMES_INFO (3)** and
  **TASK_BASIC_INFO_64_2 (18)** of the processes it watches (a trap trace of
  SpringBoard: 50 calls of each by home, all KERN_INVALID_ARGUMENT). The
  private task_info trap answered only TASK_DYLD_INFO and TASK_AUDIT_TOKEN.
  It now answers the CPU-time flavors of `osfmk/mach/task_info.h` (1, 2, 3, 5,
  18, 20, 21, 26) for any live task, from the target process's host CPU
  (as getrusage); counters Ycode does not keep are zero. Tests
  `TaskInfoFlavorTests`.
- **LaunchServices in SpringBoard** ("constructing bundle record" 1 682,
  "application record search init" 1 327 in one boot; absent on the
  reference): not fixed. What was seen (a log stream of lsd and a trap
  trace of lsd): lsd opens and maps its store
  (`var/db/lsd/com.apple.LaunchServices-33554481-v2.csstore`, 7 MB) and copies
  it, then logs "Cleaning new database object", registers CoreTypes, the
  extension points, canonical names and framework strings and starts
  `com.apple.lsd.rebuild`; SpringBoard's records are built from bundle
  URLs meanwhile (the lines above, 2.6 s of lsd on the critical path of the
  tree's profile). The store on the golden device was written by its first
  boot (2026-10-13) and **never again**, also not after a 700 s boot that
  ended with launchd_sim's clean teardown (lsd exited with 0). Whether lsd
  rejects the stored database (device state written by an old build) or
  never gets to save it is open. A fresh device (§16.6) behaves the same:
  its first boot by today's build wrote the store 40 s into the boot, its
  copies' boots leave it untouched, and their SpringBoard logs as much, so
  the golden device's age is not the cause.
- **dasd**: §15.7 found the reference fails the same
  `com.apple.coreduetd.context` look-up, so nothing was changed. Its
  "Failed to read file /System/Library/DuetActivityScheduler/Scheduler/
  Resources/com.apple.dasd.features.plist" (and `….config.plist`,
  `….allowlist.activities.plist`, 21 in all): the runtime has no such
  folder; the path is absolute and not under the runtime root, so on the
  Mac it is read from the host's own `/System` (macOS has the folder). Ycode
  cannot supply Apple's file; left as is.
- **"Display Content Mode Transition Resolution"** (SpringBoard ZStack,
  144): not investigated.
- **biomed's "Found log with eventBootUUID"** (500): device history (§15.9);
  the fresh device's biomed logs more before home, not less (§16.7).

### 16.5 The log path: a direct hand-off for workloop wakes

`YCODE_SYNC_HANDOFF` (`SyncHandoff.swift`, off by default; Linux): when a
thread wakes another through a workloop sync wake (`=1`), or gives a parked
workqueue thread of its own image work (`=2`), the waker restricts the woken
host thread to the CPU it runs on before it signals; the woken thread gets
its CPUs back (the process's mask) as soon as its wait returns. The host
then queues the woken thread behind the waker instead of anywhere, and its
wake-up preemption decides between them, the nearest Linux gets to xnu's
hand-off of the processor. A state word orders the two sides (pin, then
mark; a waiter that already returned is restored by the waker). Tests
`SyncHandoffTests` (every pin undone, no wake lost, plain wakes never pin).

In a boot about 105 000 hand-offs are made (`=2`), 26–36 of them after the
waiter had returned, 0.4–0.5 s of pinning calls in all. In the profiled
boots diagnosticd's share of the boot's critical path (`--boot`, by
program) fell from 9.3 s (tree) to 1.5 s (`=2`); the path then runs
through other programs' guest code and run-queue waits (icloudmailagent,
assistantd, dmd), the throughput-bound picture of §12.6.

### 16.6 Timed series

| Series | Arm | n | median home_s | mean ± sd | range | kernel lock held at home, median | CPU s at home, median | guest fatal |
|---|---|---|---|---|---|---|---|---|
| U1 | base (`016506aa`) | 5 | **36.48** | 37.05 ± 2.63 | 33.70–40.48 | 7.1 s | 427 | 2–4 |
| U1 | tree (§16.2) | 5 | **36.10** | 35.97 ± 0.88 | 35.00–36.85 | 6.9 s | 421 | 1–3 |
| U1 | tree, `YCODE_SYNC_HANDOFF=1` | 5 | 35.81 | 35.78 ± 0.64 | 34.97–36.44 | 6.9 s | 418 | 1–4 |
| U1 | tree, `YCODE_SYNC_HANDOFF=2` | 5 | **35.09** | 35.03 ± 0.38 | 34.52–35.40 | 6.7 s | 410 | 1–4 |
| U2 | tree2 (§16.2–§16.4) | 5 | **36.37** | 36.24 ± 2.00 | 33.08–38.08 | 7.7 s | 445 | 1–5 |
| U2 | tree2, a fresh device (each boot a copy's second boot) | 5 | 42.42 | 41.25 ± 2.33 | 37.77–43.26 | 8.0 s | 447 | 3 |
| U2 | tree | 5 | 38.38 | 37.97 ± 2.20 | 34.36–40.40 | 7.6 s | 445 | 1–3 |
| U2 | tree2, `YCODE_SYNC_HANDOFF=2` | 5 | 36.53 | 36.64 ± 1.72 | 34.26–38.87 | 7.1 s | 428 | 1–4 |

- **The fixes of §16.2–§16.4 together: −2.0 s by the median** in U2
  (tree2 36.37 against tree 38.38; means 36.24 against 37.97, sd 2.0–2.2,
  so inside about one standard deviation). The fclonefileat fix alone
  (U1, tree against base) is −0.4 s by the median and narrows the spread
  (sd 0.88 against 2.63).
- **The hand-off: −1.0 s in U1** (`=2` 35.09 against 36.10, the narrowest
  range of all eight arms, 0.9 s; CPU at home 410 against 421 s) **and
  nothing in U2** (36.53 against 36.37). It moves diagnosticd off the
  critical path (§16.5) but, as §12.4 found for the log back-pressure, the
  time comes back as other programs' work on a saturated host. It stays
  off by default.
- **A fresh device is not faster: +6 s** (42.42 against 36.37). Its second
  boot still does first-boot follow-up work (the fresh profile: 166 000
  log messages before home against 140 000; runningboardd, biomed and
  modelcatalogd more, dasd and mobileassetd less). The golden device's age
  is not what keeps Ycode from 21.4 s; §15.9's question of the reference's
  aged devices stays open.
- U2's medians are about 2 s above U1's for the same binary (tree 38.38
  against 36.10): the host got noisier through the evening (other users'
  load between boots; every boot still started under load 4). Compare arms
  within a series.

### 16.7 Log messages per program and service fidelity

Log messages (send-only `mach_msg2`, id 0x10000000) from the boot's start
to its home screen, one profiled boot each, against the reference's
boot-start-to-home counts (§15.6, §13.3):

| Program | base | tree | tree2 | tree2 fresh | tree, `=2` | Reference |
|---|---|---|---|---|---|---|
| home_s of the profiled boot | 40.3 | 38.6 | 37.8 | 42.9 | 35.3 | 21.4 |
| SpringBoard | 22 344 | 22 538 | 21 647 | 22 365 | 21 676 | 10 744 |
| runningboardd | 12 328 | 11 876 | 10 690 | 13 179 | 10 910 | 12 404 |
| dasd | 9 600 | 9 452 | 7 153 | 5 829 | 9 464 | 287 |
| mobileassetd | 7 959 | 6 976 | **4 503** | 3 874 | 6 721 | 1 343 |
| biomed | 3 979 | 3 536 | **3 038** | 4 815 | 3 001 | 716 |
| nsurlsessiond | about 2 000 | about 2 000 | 3 543 | — | — | — |
| all programs | 142 636 | 137 556 | 139 510 | 165 991 | 128 543 | about 89 000 |

- mobileassetd fell by 43 % (7 959 → 4 503) and biomed by 24 %: the Biome
  retry chain is gone (§16.2) and the downloads now complete (§16.3: in a
  log stream of tree2, 7 "MADownloadSuccessful" and no "Couldn't create
  directory"); nsurlsessiond now does those downloads during the boot
  (3 543 messages, against about 2 000 when each failed at once), so the
  total barely moves. Whether the assets stay installed across boots, so
  that later boots skip the downloads as the reference's second boot does,
  needs a boot of the same device after a longer hold.
- SpringBoard is unchanged (about 22 000 against 10 700): the
  LaunchServices record construction of §16.4 (about 3 000 lines) and
  §15.8's early UserNotifications work remain; the `task_info` failures
  (122 lines) are gone.
- dasd's excess is §15.7's timing difference (its context reads before
  home), not a Ycode call.

Started programs (`scripts/ycode-launchd-spawns`, 700 s):

| | base | tree | tree2 |
|---|---|---|---|
| all starts | 511 (236 labels) | 506 (234 labels) | 510 (237 labels) |
| restart loops (facetimemessagestored, managedappdistributiond, mlhostd, proactiveeventtrackerd, intelligencetasksd, fileindexerd) | 67, 67, 64, 68, 9, 1 | 67, 66, 63, 68, 8, 1 | 67, 67, 64, 68, 7, 1 |
| other daemons and agents | 174 | 172 | 174 |
| per-process domains | 58 | 58 | 59 |
| apps | 3 | 3 | 3 |

Each boot followed a boot of the same build (§12.7: a boot by another
build changes the device's caches; a first count of base right after tree
boots gave 592 starts, PosterBoard's extensions and 20 Metal compiler
instances again). base against tree2 differ by one or two starts per label:
intelligencetasksd −2 (the throttle loop's phase), parsec-fbf −1,
imageplaygroundd +1, and **`STExtractionService` +1**, the streaming-zip
extraction of a download that now completes (§16.3). Fidelity is
unchanged.

### 16.8 How far from 21.4 s, and the next steps

- With every service on, guest networking and the inner panel on, the
  quiet median is **35.1–36.4 s** for this branch (U1 `=2` and tree,
  U2 tree2): **1.64–1.70 ×** the reference's 21.4 s, about 14 s short.
  §14's 33.9 s (1.59 ×) was measured on a quieter evening; within one
  series the fixes here are worth about 2 s (U2) and the hand-off 0–1 s.
- The boot is still throughput-bound: 410–447 CPU seconds before home
  (`cpu_s_at_home` above) at 11–12 busy cores. Removing guest work the
  reference does not do is the lever that works (§14: 2 s; §16: 2 s), but
  the measured excess is now mostly *timing* (dasd, SpringBoard's
  notifications, §15.8) and LaunchServices, not failing calls.
- Next, in order of size:
  1. **LaunchServices in SpringBoard** (about 3 000 lines, lsd 2.6 s on
     the critical path): find why SpringBoard builds records from bundle
     URLs (`application record search init`, "constructing bundle record")
     where the reference reads them from lsd's database; the database
     handle (`com.apple.lsd.mapdb`) and what SpringBoard does with lsd's
     reply are the next thing to trace. The dirty room could say whether
     the reference's lsd rewrites its store at boot (Ycode's never does
     after the first boot).
  2. **What starts dasd's and SpringBoard's post-home work before home**
     (§15.9 item 3): about 4 400 dasd messages and 650 SpringBoard lines
     in the first 30 s. A trigger Ycode delivers early (a timer, a
     notification, a keybag or power state) is the candidate; the fresh
     device shows it is not only the device's age.
  3. **The log path's per-trap CPU** (§14.8 item 3), not attempted here.

## 17. Reference: LaunchServices at boot and the post-home work (agent B3-SIMOBS3, 2026-11-06)

Black-box answers to §16.8 items 1 and 2: whether the reference's lsd
rewrites its store at boot, what lsd and SpringBoard log about
LaunchServices, what tells lsd its store is current, and what starts
dasd's and SpringBoard's post-home work (§15.9 item 3).

### 17.1 Conditions

| Item | Value |
|---|---|
| Host | as §13.1 (arm64 Mac, macOS 27.2, Xcode 27.1); 1-minute load 90–660 at the boot starts (other agents' builds), so times are rough; counts and order are the result |
| Runtime and device | iOS 27.1 (24A94401), iPhone Duo |
| Devices | `ycode-test-simobs3-a`: boots 1–3 as created (first, second, third boot), then boots 4–7 each after one change to `DEV/data/var/db/lsd` (§17.5); `ycode-test-simobs3-b`: boots 1–3 as created. All headless (`simctl bootstatus -b`), deleted afterwards |
| Per boot | a listing of the whole `DEV/data` folder (path, size, modification time, inode) before the boot, at the end of the window (still booted) and after `simctl shutdown`; `DEV/data/var/db/lsd` polled every 0.25 s; `lsof` of lsd at 20 s and at the end; `simctl spawn … log show --info --debug` of the window (150 s; 265 s and 424 s in two boots); the device's `launchd.log` |
| Probes | `sample` of dasd at 20 s (boots a5, a6, a7, b2, b3) and 45 s (a6), of SpringBoard at 60 s (b3); `ps -M` of dasd every second (b1–b3); `lsmp` of dasd and launchd_sim (b3). The other boots carry no sampler |
| Also re-read | the ten second boots of §13 and §15 (`log show` and `launchd.log`, no file listings) |
| Times | seconds from the `simctl boot` call; home_s as §13 |

"Clean boot" below means a second or later boot of a device whose previous
shutdown was normal and whose `var/db/lsd` was not touched: a2, a3, b2, b3
and the ten boots of §13/§15.

### 17.2 What lsd writes, first boot and later boots

A new device's data folder holds 86 entries and no `var/db/lsd`. Files
under the device's data folder that LaunchServices writes:

| File (under `DEV/data/`) | Size | First boot: written at (a1 / b1) | Clean boots |
|---|---|---|---|
| `var/db/lsd/com.apple.LaunchServices-33554481-v2.csstore` (the store; 33554481 is the schema version lsd logs) | 7 831 552 | 28.7 / 19.7 s | not written: same inode and modification time as the first boot's, at the end of the window and after shutdown |
| `var/db/lsd/SystemDataOnly-com.apple.LaunchServices-33554481-v2.csstore` | 7 674 332 | 28.7 / 19.7 s | not written |
| `var/db/lsd/com.apple.LaunchServices.unregisteredtypes-501.db` | 12 288 | 28.8 / 19.9 s | not written |
| `var/db/lsd/com.apple.LaunchServicesAppProtectionStore.plist` | 264 | 8.6 / 5.8 s | not written |
| `var/db/lsd/com.apple.LaunchServices.error` (empty marker, §17.5) | 0 | present 6.4–11.5 / 3.9–8.2 s, then removed | created when lsd starts loading and removed 50–80 ms later (lsd's own lines; the 0.25 s poller caught it once, a3) |
| `tmp/ls-<16 random characters>` (lsd's working copy while it builds the store; mapped by lsd) | 4.6 MB at 20 s | during the build only | none: lsd maps the store file itself (`lsof`: the `.csstore` and the `.db`, nothing in `tmp/`) |
| `Library/MobileInstallation/LaunchServicesOperations` (folder, installd) | — | 14.5 / 8.3 s | not written |

- **Writes happen once, at the end of the build**, both `.csstore` files
  within 20 ms, then the `.db`; the whole `tmp/` folder is emptied at
  shutdown. A normal shutdown writes nothing under `var/db/lsd` (the
  listings at the window's end and after shutdown are equal in all clean
  boots).
- **Only the first boot builds.** lsd logs `_CSStoreCreateWithURL failed`
  (no such file), registers CoreTypes and the extension points in memory,
  starts its services, then "#LSDatabaseBuilder Seeding database",
  enumerates the system content and writes the store. lsd's own statistics
  line: `numApplications = 162`, `numPlugins = 456`,
  `rebuildReasonFlags = 9`, `migration = 1`, `totalRebuildTime` 11.6–17.5 s
  (scan of the system content 11.5–17.3 s, save 0.1 s), followed by
  "posting LSNotificationDatabaseSeedingComplete".
- **Every boot, including clean ones, re-registers a small fixed set in
  memory**, without writing the file: after loading the store lsd logs
  "Cleaning new database object", "Registering CoreTypes bundle",
  "Registering extension points" … "Done reregistering extension points"
  (about 20 ms), "Registering canonical names", "Registering framework
  bundle localized strings", "No persisted cache on this platform", removes
  its `.error` marker and logs "Starting services". From "lsd starting" to
  "Starting services" takes 0.28–0.52 s in clean boots (n = 14). Apps and
  plug-ins are not re-registered.
- So the reference's lsd does not rewrite its store at boot, as Ycode's
  (§16.4). The store being stale in Ycode is not the difference.

### 17.3 Log volume, first 30 s

| Program, lines | First boot (a1, b1) | Clean boots (n = 14) | Rebuild boots (a4, a7) |
|---|---|---|---|
| lsd, all lines | 17 120, 14 816 | median 207 (133–224) | 14 304, 14 293 |
| SpringBoard, subsystem `com.apple.launchservices` | 8, 5 | 10–17 | 13, 13 |
| SpringBoard, "constructing bundle record for file:…" | 0 | 0 | 0 |
| SpringBoard, "application record search init. Node: …" | 0 | 0 | 0 |

The two Ycode patterns are absent from every reference boot of this
section and of §13/§15 (19 boots, whole windows, first boots and rebuilds
included).

**lsd's lines in a clean boot**, by pattern (a2, a3, b2, b3): XPC
connection activations 43–104 (mostly incoming client connections, `peer=true`,
and its 8 listeners); "LSInstallProgress: adding observer …" 17–24;
"Sending journalled notifications to newly connecting observer …" 9–12;
container look-ups of its own containers about 10; "Failed to read LS
preferences (secure? …) from …" 3; the 14 `com.apple.launchservices:db`
start-up lines of §17.2; `xpc_activity` registrations of two analytics
activities 6–9. A first boot adds per-bundle registration lines (the
`appinstallation:TransactionLog` pattern 2 960, container queries about
6 000, icon cache evictions 619, …).

**SpringBoard's lines in a clean boot** (subsystem `com.apple.launchservices`,
17 in b3): "registering for distributed notification … in this process" 8
(application state, install-progress controls, plug-ins registered and
unregistered); "LSApplicationWorkspace: adding observer …" 3–5;
"Establishing xpc connection to lsd" 1; "Received LSWorkspaceObserverPing,
xpc connection established" 1; "LaunchServices database schema version:
33554481" 1 (logged by the client side once it has the database);
"reloading all DMF policies for N identifiers" 1. Besides these, 2 lines
"No LSApplicationRecord found for bundleId: …" per boot.

### 17.4 Who connects to lsd, and in what order

| t (s), clean boot a3 | Event |
|---|---|
| 2.46 | runningboardd connects to `com.apple.lsd.mapdb`; launchd_sim spawns lsd for it ("launching: ipc (mach)"): lsd is started on demand by its first client |
| 2.70 | lsd: "lsd starting with schema version 33554481" |
| 2.93 | mobiletimerd connects to `com.apple.lsd.xpc` (still before lsd's listeners) |
| 3.01–3.07 | lsd: store loaded, "Cleaning new database object", the in-memory registrations, `.error` removed |
| 3.07–3.17 | lsd: "Starting services"; listeners in this order: `com.apple.lsd.mapdb`, `.modifydb`, `.open`, `.advertisingidentifiers`, `.icons`, `.rebuild`, `.appprotection`, then `com.apple.lsd.xpc` |
| 6.8 (5.5–7.6 over n = 14) | SpringBoard connects to `com.apple.lsd.mapdb` 0.08–0.15 s after its first log line, then to `com.apple.lsd.xpc` 20–100 ms later, then logs the schema-version line and "Received LSWorkspaceObserverPing" |

- **SpringBoard connects to lsd 3.1–4.3 s after lsd finished starting**
  (n = 14), with exactly two client connections: `com.apple.lsd.mapdb`
  first, `com.apple.lsd.xpc` second. In a clean boot 71–101 client
  connections reach `mapdb`, 19–29 `lsd.xpc`, one `lsd.icons`
  (fileproviderd), 0–2 `lsd.advertisingidentifiers`; the other listeners
  get no client.
- **While lsd is building the store** (first boots, a4, a7), "Starting
  services" comes only after the in-memory registrations (5–7 s after
  "lsd starting") and the build runs after it. SpringBoard's `mapdb`
  request, sent earlier, is answered within 5 ms of "Starting services";
  SpringBoard logs "Database was seeding; client will retry and block …"
  and waits until lsd's
  "LSNotificationDatabaseSeedingComplete" (17.5 s in a1, 11.8 s in b1,
  10.7 s in a4, 9.9 s in a7); then it logs the schema-version line and
  "LaunchServices observer: databaseWasRebuilt". Even then it constructs no
  bundle records itself.

### 17.5 What tells lsd its store is current (experiments on device a)

| Boot | Change made before the boot | What lsd did | Store files |
|---|---|---|---|
| a4 | empty `var/db/lsd/com.apple.LaunchServices.error` created | "_LSCreateStoreWithFileContents found a recovery file, so creating a new empty store"; full build, `rebuildReasonFlags = 5`, `migration = 0`, 10.7 s | both `.csstore` rewritten at 19.3 s: written as `<name>(<8 hex digits>~).csstore`, then renamed over the old file (new inode, same size) |
| a5 | empty `com.apple.LaunchServices.syncInterrupted` created | "Previous sync was interrupted …"; no build; instead "Syncing with MobileInstallation once in-flight installation activity is quiesced", asks installd to enumerate the installed apps ("Enumerate installed apps requested by lsd") and checks each one ("Checking if … needs to be registered", "Skipping …"). `.error` exists during the sync | not written in 150 s; the sync had not finished at shutdown: shutdown left a new `.syncInterrupted` and an empty `…(<hex>~).csstore` |
| a6 | both `.csstore` modification times set to 2000-01-01 (and a5's leftovers present) | loaded the store without a build (the old time made no difference); a5's `.syncInterrupted` made it sync again | after the sync finished (about 354 s, during the log read-out), the main `.csstore` was rewritten (new inode, same size) and `.error` removed |
| a7 | main `com.apple.LaunchServices-33554481-v2.csstore` deleted, `SystemDataOnly-…` kept | `_CSStoreCreateWithURL failed` (no file); full build (`rebuildReasonFlags = 9`, 9.9 s); `SystemDataOnly-…` was not used to avoid it | both rewritten at 19.8 s |

- **lsd's notion of "current"**: the store file with the schema version in
  its name exists and opens, and no `.error` marker is present.
  `.error` is lsd's own "load in progress" marker: created before the
  store is loaded, removed when the in-memory registrations are done (and,
  during a sync, kept until the sync is saved). A leftover `.error` means
  the previous load did not complete, and the next boot discards the store
  and rebuilds it. `.syncInterrupted` means a sync with installd did not
  complete; it triggers a sync, not a rebuild, and clears `.error`.
- No timestamp comparison was seen (a6), and lsd logs no build or system
  version check; the only version it logs is the schema version, which is
  also in the file names. The build check that exists belongs to installd:
  its `Library/MobileInstallation/LastBuildInfo.plist` (399 bytes, written
  on the first boot) and the line "Current build version (24A94401 / …)
  equal to last version recorded …; skipping upgrade" in the sync boot. It
  could not be exercised (the runtime build cannot be changed).
- A clean shutdown leaves neither marker; every clean boot of this section
  found none.

### 17.6 dasd's quiet phase and what ends it

| Boot | home_s | dasd silent from → to (s) | First dasd line after the silence |
|---|---|---|---|
| a2 | 51.0 | 8.2 → 76.5 | activity scoring ("WARNING NO POLICIES APPLY TO Activity …") |
| a3 | 26.3 | 7.6 → none (silent until the window's end, 265 s) | — |
| b2 | 28.3 | 7.0 → 39.6 | "error getting value for /device/system/isPluggedIn : … com.apple.coreduetd.context … lookup with error 3" |
| b3 | 32.9 | 13.8 → 44.2 | the same error for `/device/system/batterySaver` |
| §13/§15 (10) | 24.2–39.2 | 6.2–8.1 → 26.8–76.8 | the same error in 9 of 10; activity scoring in 1 |
| first and changed boots (a1, b1, a4–a7) | 35.8–57.0 | 4.9–13.1 → 19.6–78.0 | the same error in 2; a new client connection or "Running activities" in the others |

- **The silence is not idle time and not a wait for a signal.** The
  samples (a5, a6, a7, b2, b3 at 20 s; a6 at 45 s) show the same state each
  time: one dasd thread, serving a request, reads a CoreDuet context key
  (`-[_CDClientContext objectForContextualKeyPath:synchronous:…]`) and waits
  in a synchronous XPC send for the reply from `com.apple.coreduetd.context`,
  a name that is not registered in the simulator (launchd_sim logs one
  "failed lookup … error = 3" for dasd at 2.7 s). Meanwhile dasd's listener
  thread waits for a lock, every client-connection thread waits for one
  serial queue, and dasd's own submissions (`-[BGSystemTaskScheduler
  submitTaskRequest:error:]` and `-[_DASScheduler submitActivity:inGroup:error:]`,
  the latter from the XPC event publisher's subscription callback) wait for
  synchronous replies from dasd's own scheduler service. In a5 two
  background threads were also busy: activity evaluation (date
  formatting) and the battery-temperature recorder, which logs the host's
  power-source dictionary (about 24 KB) as "Unable to get valid battery
  temperature: {…}".
- `ps -M` (b2): during the silence dasd has 8–9 threads, all sleeping
  except 1–2 runnable threads at priority 4 (background); no thread above
  priority 37.
- **The end:** in 13 of the 19 silences that ended the first line afterwards is that
  read's failure, "error getting value for /device/system/isPluggedIn" (or
  `batterySaver`) "… Connection init failed at lookup with error 3 - No
  such process", on the thread whose last line started the read ("Fetching
  uncached value for …" or "CoreDuet: ClientContext
  objectForContextualKeyPath:"). Within the next 0.1 s dasd accepts the
  queued client connections ("Creating restricted client for connection …
  from pid …", many `duetactivityscheduler.peer[pid]` activations at the
  same millisecond) and logs the queued "SUBMITTED …" lines, then scoring,
  "Running activities" and the context reads of §15.7. In the three boots
  checked, launchd_sim logs nothing about dasd, a look-up or its domain's
  state in the second before the end.
- **How long a read waits varies**: the median read fails in 0.1–94 ms
  (per boot, four boots), but 1–16 reads per boot wait 1 s or longer, and the one that starts the silence waits 20–71 s (a2 68.4 s,
  b2 34.8 s, b3 30.5 s; §13/§15 26–71 s). The wait is not a constant, so
  not a fixed timeout; whether it depends on the host's load (all boots
  here ran at load 90–660, dasd's runnable threads at background priority)
  is open (§17.9).
- Relative to home: in clean boots the silence ends between 1 s before and
  48 s after home (median 11 s after, n = 13); in the first and changed
  boots it ended 0–26 s *before* home. It does not wait for home.
- No timer, notification name, keybag or power state change, first
  unlock or "boot complete" line precedes the end in dasd's or in
  launchd_sim's log.

### 17.7 SpringBoard's notification work waits for dasd

| Boot | home_s | dasd "SUBMITTED com.apple.usernotificationsd.BundleLibrarianVacuumBackgroundSystemTaskHandler.Recurring:…" | SpringBoard "notificationSourcesDidInstall: N sources, initialLoad=1" |
|---|---|---|---|
| a4, a5, a6, a7 | 35.8–52.1 | 90.4, 85.2, 68.6, 57.9 | 91.6, 87.1, 72.3, 58.3 |
| b1, b2, b3 | 28.3–57.0 | 132.3, 118.5, 132.5 | 133.4, 119.2, 139.2 |
| §15 runs 1, 4, 5 | 24.2–32.0 | 94.4, 104.1, 62.6 | 106.4, 106.6, 70.2 |
| a1, a2, a3, §15 runs 2, 3, §13's five | 24.2–51.0 | not within the window (125–424 s; §13's 64–92 s) | not within the window |

- SpringBoard's sample at 60 s (b3) shows why: the thread running
  `UNSUserNotificationServerRun` is inside `-[UNSUserNotificationServer init]`,
  which submits that background system task through `-[BGSystemTaskScheduler
  submitTaskRequest:error:]` and waits for dasd's synchronous reply. The
  notification server finishes initialising only after dasd has accepted
  the task: in all 10 boots with both events, dasd's "SUBMITTED" line comes
  0.4–12 s before SpringBoard's "initialLoad=1", and in the 10 boots
  without the first, the second is absent too.
- After "initialLoad=1" SpringBoard runs the work §15.7 lists:
  "Application installed using default data provider" for each source (89
  sources), "No data found at …" (372–411 per boot), "Saving file at …"
  (113–143), "kExcludedFromBackupXattrName set on path" (111–122),
  "Calcualate [sic] topics …" (53–54).
- So **the event before SpringBoard's notification work is dasd's reply to
  SpringBoard's task submission**, and dasd's ability to reply depends on
  its queue being free (§17.6). The reply comes 31–98 s after dasd's
  silence ends, while dasd works through its backlog (with further context
  reads of 1–8 s each in b2).

### 17.8 Consequences for Ycode

1. **lsd's store is not the lead.** The reference's lsd also never writes
   its store after the first boot; every boot re-registers CoreTypes,
   extension points, canonical names and framework strings in memory only
   (about 50 ms), from "lsd starting" to "Starting services" in 0.28–0.52 s.
   Ycode's lsd spending 2.6 s there (§16.4) is worth a look, but the
   rewrite is not missing.
2. **What to compare in Ycode's SpringBoard**: on the reference,
   SpringBoard's first two lsd connections are `com.apple.lsd.mapdb` then
   `com.apple.lsd.xpc`, 0.08–0.15 s after its first line; it then logs "LaunchServices
   database schema version: 33554481" (the client has the database) and
   never constructs bundle records or runs application-record searches,
   not even while lsd is building the store (then it blocks until the
   build ends). A Ycode SpringBoard that logs "constructing bundle record"
   has not got usable records from `mapdb`'s reply: check that the reply
   arrives, that the schema-version line appears, and that the client can
   map what the reply hands it.
3. **Markers**: Ycode should leave `var/db/lsd` as the reference does after
   a clean shutdown (no `com.apple.LaunchServices.error`, no
   `com.apple.LaunchServices.syncInterrupted`, no `(…~).csstore`). A
   leftover `.error` makes every boot rebuild (about 14 300 lsd lines and
   a 10–17 s build with SpringBoard blocked); a leftover `.syncInterrupted`
   makes every boot sync with installd, and a sync that does not finish
   before shutdown leaves the store untouched and the marker in place
   again (a5): an untouched store, as on Ycode's golden device since
   2026-10-13 (§16.4), is consistent with such a loop. Check the folder's
   listing after a Ycode boot and look for lsd's "Previous sync was
   interrupted" and "Syncing with MobileInstallation" lines. Also compare
   the working copy: the reference's lsd maps the store file in place and
   writes a copy under `tmp/` only while it builds.
4. **dasd and SpringBoard's notification server**: on the reference both
   are held back by dasd's synchronous read of `com.apple.coreduetd.context`
   (an unregistered name) that takes 20–71 s to fail on this host, and
   SpringBoard's notification server waits for dasd's reply to its task
   submission. Ycode's dasd gets the same look-up failure (§15.7) but
   logs 1 466 failed reads in its first 30 s, so its reads are not held
   back this way, and dasd's backlog and SpringBoard's notification
   initial load run before home. The behaviour to reproduce is not
   a timer: it is the latency of a synchronous request on a connection
   whose name look-up failed. Until it is known whether that latency is
   the reference's own or this host's load (§17.9 item 1), do not delay
   Ycode's replies artificially; measure first.

### 17.9 Open questions

1. **What makes the reference's failed context read wait 20–71 s.** The
   look-up failure is logged by launchd_sim at 2.7 s, yet one later read
   waits tens of seconds; no launchd_sim line marks its end. Repeating
   b2/b3 on a quiet host (load under 4, as `parity-ladder.md` §3.1) would
   show whether the wait is load (dasd's runnable threads sit at
   priority 4) or a property of the look-up path. `lsmp` without root
   cannot name the holder of the reply right (one probe at 58 s in b3,
   after the silence: launchd_sim held 115 send-once rights, one of them
   to a dasd receive right).
2. **Why some boots never accept SpringBoard's task within 125–265 s**
   (a2, a3, §15 runs 2 and 3, §13): dasd's backlog order and further
   blocked reads; a longer window would tell whether it always comes.
3. **lsd's 0.28–0.52 s against Ycode's 2.6 s** (§16.4) on the critical
   path: a per-phase comparison needs the same lines from Ycode's lsd.
4. installd's build check (`LastBuildInfo.plist`) was not exercised; what
   it triggers on a build change is unknown.

## 18. LaunchServices, mobile assets and dasd's hold (agent B3-BOOT4, 2026-11-06)

§16.8's step 1 and §17.8's items with Ycode's own simulator, and the
experiment §17.8 item 4 asks for. Target: home_s ≤ 21.4 s, full boot,
every service on (networking and the Duo's inner panel included).

### 18.1 Conditions

- Thor; one copy of the golden device in the agent's own folder (iPhone
  Duo, iOS 27.1), booted at that path nine times before the first series
  (two plain boots, seven diagnostic boots); full boot, default switches,
  `YCODE_HOME_WATCH`, stopped 5 s after home (diagnostic boots 10–420 s),
  no save.
- Builds: *base* = `7a8685dc` (§16 merged); *tree* = this branch (§18.4's
  switch, off by default, and a trace text). With the switch off the two
  are the same program.
- Guest log lines from `log stream` one-shots (info or debug level) in
  separate, untimed boots; trap traces (`--trace-name`); frame-profile
  windows (`YCODE_FRAME_PROFILE_BOOT=120`); `var/db/lsd` listed before and
  after every boot. A stream changes what the guest logs (§18.2), so counts
  come from profiles and traces, not from streams.

### 18.2 LaunchServices

**Markers.** The golden device's `var/db/lsd` holds the two stores, the
unregistered-types database and the app-protection plist, and no
`com.apple.LaunchServices.error`, `.syncInterrupted` or `(…~).csstore`.
After each of this section's eleven boots the listing was the same four
files (only the `.db` rewritten); lsd creates `.error` when it loads the
store and removes it when its in-memory registrations end, as §17.5
describes. There is no marker loop. One of §16's diagnostic boots
(`diag-ls`) started with a `.syncInterrupted` left by the boot before it;
lsd removed it at once ("Successfully removed recovery file"). Ycode's
stop at home + 5 s ends every guest process with a signal (lsd: status
137 or 143), not with launchd_sim's shutdown, so a stop during an
installd sync can leave the marker; the timed series never showed one.

**SpringBoard has the database.** In a trap trace of SpringBoard its
`com.apple.lsd.mapdb` request is answered with one memory object of
0x704000 bytes (the store's size, 7 356 416 bytes), which it maps, copies
into its own allocation and makes read-only; a debug-level stream then
shows "LS DB needs to be mapped into process … (existing DB @ 0x0)",
"Loaded LS database with sequence number 652", the schema-version line,
and "Will enumerate 163 candidate bundle identifiers/units". The record
construction that follows is the application-record enumerator of that
database (42 enumerations by home): for each candidate,
"BindingEvaluator::CreateWithBundleInfo(ID=…)", "Truncating a list of
bindings …" twice, then "constructing bundle record for file://…/X.app/".
The order of the apps is the database's, and the first enumeration takes
1.3 s. Nothing here falls back to bundle URLs: it is the normal path.

**What differs is the logging.** The runtime's
`System/Library/Preferences/Logging/Subsystems/com.apple.launchservices.plist`
(read as a property list) sets `DEFAULT-OPTIONS` to `Enable: Info` and two
categories to `Enable: Default`: `privacy` and `datasep`. Those are exactly
the two categories of §15.7's absent patterns ("constructing bundle
record" is `privacy`, "application record search init" is `datasep`).
SpringBoard reads the plist (two `openat` + `pread` of its 291 bytes),
yet in a boot without a stream it still sends both kinds: 1 670 and 1 299
log messages by home in §16's trace, of about 22 000 (debug-level lines,
such as the `binding` category's, are not sent). On the reference, diagnosticd's
receive counter matches the store to within 1–7 % (§13.3), so its
SpringBoard does not send them. Both systems write the same
diagnosticd filter (`global` = 0x9_0007_0000, §13.3), so the global
stream does not explain it: in Ycode's guest, a category's `Enable:
Default` does not keep its info messages from being sent; on the
reference it does. Why is open (§18.8). The cost is small: about 3 000
messages in SpringBoard and about 1 300 in other programs, under 0.5 s of
diagnosticd's CPU (§14.5: about 100 µs each).

**lsd's start-up.** From "lsd starting" to "Starting services" took 6.3 s
in an info stream and 9.6 s in a debug stream, against 0.28–0.52 s on the
reference (§17.2):

| Phase (info stream, §16's `diag-ls`; debug stream, `diag-ls-debug`) | Ycode | |
|---|---|---|
| start → the `class 10` container query sent | 0.2 s | 0.3 s |
| query → result (containermanagerd) | **4.8 s** | **4.9 s** |
| store load, "Cleaning new database object" | 0.2 s | 0.4 s |
| extension points | 0.2 s | 2.9 s (debug lines) |
| canonical names, framework strings, `.error` removed | 0.8 s | 1.0 s |

The query waits for **containermanagerd's start**: the per-user
`com.apple.containermanagerd` is launched on demand by this query
(launchd.log: "launching: ipc (mach)" 2.3 s after lsd), logs its first
line about 3 s after the query and answers 1.8 s later. In §16's profile
lsd's main thread waited 4.3 s for it, and the waker's path back is host
run-queue time (sharingd 1.9 s, containermanagerd 0.75 s) and guest code
(sharingd 1.1 s, containermanagerd 0.14 s): the saturated host of §12.6,
not a Ycode call. SpringBoard's `mapdb` request waited for lsd's
"Starting services" (1.4 s in the debug boot). Whether the reference's
containermanagerd is already running when lsd queries it is a dirty-room
question (§18.8).

### 18.3 Mobile-asset downloads fail in extraction: decmpfs

Every boot of the aged device downloads mobile assets (Siri understanding
and dialog, text-to-speech voices: 3–57 MB each) and every extraction
fails, so the next boot downloads them again. What it costs before home
varies with how far an extraction gets: in §16's profile `p-tree2` the
extractor, `STExtractionService`, used 0.36 cores over the 40 s window
(14.6 CPU s, the second-largest program after SpringBoard); in this
section's profiles it stopped at its first compressed file (0.4 CPU s),
and mobileassetd (7–8 CPU s) and nsurlsessiond (1 CPU s) did the rest of
the asset work. A trap trace of `STExtractionService` shows why it fails:

- AppleArchive writes **compressed files** (decmpfs, xnu
  `bsd/sys/decmpfs.h`): `fsetxattr("com.apple.decmpfs")` with a header of
  type **13** (LZBITMAP, payload in the attribute; uncompressed size
  1 005), `ftruncate(0)`, `fchflags(UF_COMPRESSED)`; for a larger file
  type 14 (LZBITMAP, payload in the resource fork) with
  `fsetxattr("com.apple.ResourceFork", 4 674 bytes, position 12)`.
- Ycode keeps `com.apple.decmpfs` as an ordinary attribute and ignores
  UF_COMPRESSED (`file-system-features.md` §3), so the first file is left
  empty; the resource-fork write is EINVAL (Ycode allows only position 0,
  and the host's ext4 refuses attribute values over about 4 KB: ENOSPC at
  4 674 bytes). The extractor logs "Invalid argument: fsetxattr resource
  fork", the download "Task finished with error", and mobileassetd retries
  at the next boot (120 such lines in a 420 s boot).
- Tried: answering ENOTSUP for both attribute names (a volume without
  compression). AppleArchive does not fall back to plain files ("Operation
  not supported: fsetxattr decmpfs", same abort); reverted.

On the reference's APFS these files read back decompressed, so its
downloads install once. A fix needs decmpfs on Ycode's volume: resource
forks of any size and position (a side file, not a host attribute), and
decompression of types 13 and 14 when UF_COMPRESSED is set. LZBITMAP has
no permissively licensed reference implementation (LZFSE and LZVN have),
so its format needs a dirty-room specification first (§18.8). Until then
every boot pays the asset work, and so did every series since §16.3 made
the downloads reach extraction.

### 18.4 dasd's hold: failed look-ups answered late (experiment)

§17.6: on the reference, dasd's first blocking read of a CoreDuet context
key fails 20–71 s after it starts, and dasd accepts nothing meanwhile; its
backlog and SpringBoard's notification server run after home. In Ycode
the same read fails at once and that work runs before home (§15.7).

What Ycode's code decides here: a guest's look-up goes to launchd_sim
(the guest's own), which answers an unknown name itself with
`{error: 3}` (`bootstrap-wire.md` §4.2); it never asks Ycode's host
bootstrap (the host log holds only the 708 start-up request). Nothing in
Ycode delays or answers it, and launchd_sim on the reference logs the
failure at once too (§17.6). So the reference's wait is not launchd_sim
holding the reply for a name it might still publish; either its host's
load (1-minute load 90–660, dasd's threads at background priority) or
something after the look-up. That is still open (§17.9 item 1).

`YCODE_LOOKUP_HOLD` reproduces the observable behaviour for an
experiment, without touching launchd_sim: the kernel notes a look-up
request (pipe routine 207 or 804) that names a listed service, and holds
the failure reply sent to its reply port until a release time
(`YCODE_LOOKUP_HOLD_UNTIL`, seconds after the start, default 40); a reply
that grants the name, or comes later, passes at once.

| | |
|---|---|
| Switch | `YCODE_LOOKUP_HOLD=com.apple.coreduetd.context` (names, comma-separated), `YCODE_LOOKUP_HOLD_UNTIL=<s>` |
| Default | off |
| Code | `LookupHold.swift` (hook in `MachIPC.deliver`), one stderr line per held reply |
| Tests | `LookupHoldTests` (held until the release time, then delivered; other names, granted look-ups and replies after the release pass at once) |
| Snapshot | held replies are not captured |

Smoke boot (40 s, with a dasd stream): 8 failure replies held, the first
for 38.4 s; dasd logged 9 lines before them and 4 701 in the ten seconds
after the release; home at 27.7 s.

### 18.5 Timed series

Series T1 and T2, one binary (*tree*), three arms rotated, n = 5 each,
the aged device copy, every boot started with no other `ycode-simd` and a
1-minute load of 3.39–3.99 (`parity-ladder.md` §3.1's conditions); T1
21:30–21:59, T2 22:26–22:55 (after the fidelity and profiled boots):

| Arm | n | median home_s | mean ± sd | range | kernel lock held at home, median | CPU s at home, median | guest fatal |
|---|---|---|---|---|---|---|---|
| default (hold off) | 5 | **33.18** | 33.02 ± 0.62 | 32.08–33.72 | 6.3 s | 357 | 4–6 |
| hold until 40 s | 5 | **27.59** | 27.68 ± 0.22 | 27.48–28.04 | 4.2 s | 278 | 2 |
| hold until 30 s | 5 | 27.84 | 27.83 ± 0.31 | 27.38–28.13 | 4.3 s | 293 | 2–3 |
| T2: default | 5 | **33.57** | 33.42 ± 0.59 | 32.62–34.18 | 6.2 s | 362 | 3–6 |
| T2: hold until 40 s | 5 | **27.90** | 28.03 ± 0.28 | 27.79–28.45 | 4.2 s | 279 | 2 |
| T2: hold until 40 s, `YCODE_SYNC_HANDOFF=2` | 5 | 27.78 | 27.92 ± 0.42 | 27.58–28.63 | 4.4 s | 289 | 2 |

- **The hold: −5.6 s by the median in T1 and −5.7 s in T2** (ranges 4 s
  apart in both), and 79–83 CPU s (22 %) less work before home. Releasing at 30 s or 40 s makes no
  difference: home comes before either, so the release only decides when
  the held work runs after home.
- The sync hand-off (§16.5) on top of the hold: −0.1 s, inside the
  spread; it stays off.
- The guest fatals that go are intelligencetasksd's (its restart loop,
  started by dasd, §12.7): with the hold it starts after home.
- The default arm (33.2 s) is 3 s faster than §16's U1/U2 (36.1–36.4 s)
  with no change of Ycode's own: a quieter evening and this device copy.
  Compare arms within the series.

### 18.6 Log messages and CPU per program

One profiled boot of each arm (`p-tree` home 33.7 s, `p-hold40` home
27.5 s; the second started at load 13, so its CPU figures are a little
high), log messages (send-only `mach_msg2`, id 0x10000000) from the start
to home, against the reference's start-to-home counts (§13.3, §15.6):

| Program | default | hold until 40 s | Reference |
|---|---|---|---|
| SpringBoard | 21 309 | **12 199** | 10 744 (11 525 in §13) |
| runningboardd | 8 796 | 6 688 | 12 404 |
| dasd | 7 073 | **10** | 287 |
| mobileassetd | 4 203 | 3 697 | 1 343 |
| locationd | 4 043 | 3 616 | 3 379 |
| biomed | 3 580 | 3 402 | 716 |
| cfprefsd | 3 443 | 2 748 | 2 962 |
| sleepd | 551 | 13 | — |
| usernotificationsd | 543 | 281 | — |
| **all programs** | 130 282 | **89 808** | about 89 000 |

- With the hold, the log volume before home is the reference's: the total
  matches (89 800 against about 89 000), and SpringBoard's comes within
  14 % of it (the remaining excess there is mostly §18.2's two
  LaunchServices categories, about 3 000).
- CPU of all guest programs in the window: 313 s (default) against 257 s
  (hold). The largest differences: SpringBoard −4.7 s (its notification
  server's initial load, §17.7, now after home), diagnosticd −4.3 s, and
  about 20 programs that dasd's activities start and that now start after
  home (ScreenTimeAgent, ShortcutsTopHitsExtension, SafariLinkExtension,
  photoanalysisd, mediaanalysisd, the speech-synthesis units, voicebankingd:
  0.8–3.6 s each).
- dasd's 10 messages are its start-up before the first context read; the
  reference's 287 include about 20 read failures in its first 10 s
  (§15.7), which the hold delays as well (it holds every failed look-up of
  the name until the release, not only the one the reference's silence
  starts with).

### 18.7 Service fidelity

`scripts/ycode-launchd-spawns` over 700 s, one boot each after a boot of
the same build, on the same device copy:

| | default | hold until 40 s |
|---|---|---|
| all starts | 667 (217 labels) | 620 (220 labels) |
| restart loops (facetimemessagestored, managedappdistributiond, mlhostd, proactiveeventtrackerd, intelligencetasksd, fileindexerd) | 67, 66, 64, 68, 6, 1 | 67, 63, 61, 68, 7, 1 |
| other daemons and agents | 354 | 312 |
| per-process domains | 38 | 38 |
| apps | 3 | 3 |
| starts by reason (xpc event, demand, Mach IPC, speculative) | 315, 151, 152, 32 | 316, 151, 105, 32 |

The labels that differ by more than three: **pairedsyncd, 47 → 1**. In
the default boot something starts it by Mach IPC every 10 s from 226 s
on (each run exits 0 after 0.4 s; `lean-boot.md` §2 found "pairing store
path was nil"); with the hold it starts once, as on the Mac (1 and 1 in
700 s, `parity-ladder.md` §3.3, where it is one of Ycode's four own
restart loops). The other labels differ by one to three starts
(managedappdistributiond and mlhostd −3, the throttle loops' phase;
imageplaygroundd, nanoappregistryd, parsec-fbf, stickersd, eligibilityd,
intelligencetasksd +1; a key-sync agent −1). Fidelity is unchanged, and
closer to the Mac for pairedsyncd. (This device copy's counts are above
§16's: PosterBoard started 135 times in both boots, its extensions
repeatedly, §12.7.)

### 18.8 How far from 21.4 s, and what is left

- Default switches, every service on: **33.2–33.6 s** (T1, T2), 1.55–1.57 ×
  the reference. With the look-up hold: **27.6–27.9 s**, **1.29–1.30 ×**,
  6.2–6.5 s short; 278–279 CPU s before home against 357–362 (medians).
- **Recommendation on the hold (the owner decides; it stays off).** It
  reproduces what §17.6–§17.7 observed on the reference: dasd silent from
  its first context read until well after home, SpringBoard's notification
  server waiting for dasd, and with it Ycode's log volume before home
  becomes the reference's (§18.6) while service fidelity is unchanged
  (§18.7). Against it: §17's reference boots all ran at a 1-minute load of
  90–690, and whether a quiet reference host shows the same 20–71 s wait
  is not known (§17.9 item 1); if it does not, the hold makes Ycode faster
  than the reference by deferring work the reference does before home.
  The dirty-room boot that decides it: §17.6's dasd read on the reference
  at a load under 4 (`parity-ladder.md` §3.1). If the wait is there, turn
  the hold on by default with the reference's release time; if it is not,
  remove the switch.
- With the hold, the boot's critical path (profile `p-hold40`, 27.1 s) is
  38.6 % guest code (liveactivitiesd 3.4 s of guest code with no trap on
  its main thread at 16.1–19.8 s, SpringBoard 2.5 s, dataaccessd 1.0 s),
  25 % host run-queue waits (diagnosticd's wakeups 1.7 s, dataaccessd
  1.3 s), 12.6 % thread and process starts, 11.7 % kernel-lock and
  hand-off costs (diagnosticd's event lock and wakeups 1.4 s).

Next, in order of size:

1. **liveactivitiesd's start** (3.4 s of uninterrupted guest code on the
   path with the hold; 3.6–4.0 CPU s in both arms): what it computes, and
   whether the reference's takes as long (its CPU in the first 30 s).
2. **Mobile-asset extraction** (§18.3): a dirty-room specification of
   LZBITMAP (decmpfs types 13 and 14), then decmpfs on Ycode's volume
   (resource forks in a side file, decompression at UF_COMPRESSED). Until
   then every boot downloads and fails again.
3. **LaunchServices' two log categories** (§18.2, about 3 000 messages in
   SpringBoard and 1 300 elsewhere): a dirty-room check of how the
   reference keeps `privacy` and `datasep` info messages from being sent
   while diagnosticd's filter is the same (a `log config --status
   --subsystem com.apple.launchservices` in the device, and whether a
   stream-less boot's store holds any of them).
4. **lsd behind containermanagerd** (§18.2, 4.8 s): whether the reference's
   per-user containermanagerd is running before lsd's first query, and how
   long its query takes.
5. The log path (§16.5): with the hold, diagnosticd's wakeups are again
   the largest wait on the path (the profile above), but the sync hand-off
   on top of the hold gains nothing measurable (T2: −0.1 s); the per-trap
   cost of §14.8 item 3 is the remaining lever there.

## 19. Reference on a quiet host: dasd's wait and other §18 questions (agent B3-SIMOBS4, 2026-11-07)

Dirty-room answers to §17.9 item 1 and §18.8 items 1, 3 and 4: is the
reference's 20–71 s wait in dasd's failing context read (§17.6) an effect
of the host's load, and therefore should Ycode keep `YCODE_LOOKUP_HOLD`
(§18.4)? Also: how the reference keeps LaunchServices' `privacy` and
`datasep` info messages out of the log, whether containermanagerd runs
before lsd queries it, and how long liveactivitiesd takes to start.

### 19.1 Conditions

| Item | Value |
|---|---|
| Host | as §13.1: Apple M3 Max, 14 CPUs (10 performance, 4 efficiency, `hw.perflevel0/1`), macOS 27.2, Xcode 27.1; swap 39.6 of 40 GB in use |
| The host's idle floor | 1-minute load 7.75–9 with no simulator booted: two macOS test VMs (two processes each, about 4 CPUs together, all the time) and Spotlight indexing. A load under 4 cannot be reached on this Mac without stopping other people's VMs, which this observer did not do |
| Rule before each boot | wait until the 1-minute load is under 4, or, after at least 180 s, within 1.0 of the lowest load seen in any wait (7.75), or 20 minutes at most |
| Runtime and device | iOS 27.1 (24A94401), iPhone Duo; all boots headless (`simctl bootstatus -b`) |
| Boots | device `ycode-test-simobs4-a`: boot 1 as created (fresh), boots 2–4 (aged); devices `-b` to `-g`: one fresh boot each; `-ls`: one fresh boot, then one untimed boot with a log stream (§19.5). All deleted afterwards |
| Per boot (window 200 s) | the 1-minute load every second; every CPU's busy fraction every 0.5 s (`host_processor_info`, no root); `ps -M` of dasd, liveactivitiesd, containermanagerd, lsd and SpringBoard about every second (2–60 s apart while the host was saturated); home_s as §13; `log config --status` in the device at the window's end; `log show --info --debug` of the window; the device's `launchd.log` |
| Times | seconds from the `simctl boot` call |

"Quiet" below means the boot started at the floor (load 7.9–12.0); "busy"
means other programs (Swift builds) were running and the 20-minute
limit started the boot at load 135–267. The system volume filled up (other
programs) during g1: its CPU samples end at 139 s and its `ps` samples at
about 150 s.

**The boot is its own load.** In every quiet boot the 1-minute load went
from about 8 to a peak of 108–411 within 24–100 s, and all 14 CPUs were
busy (mean busy fraction ≥ 0.97) from about 1.5 s until the boot's burst
eased: 23.8–31.2 s in the aged boots, that is about home, and 53.9–61.4 s
in the fresh ones. CPUs 0–3 (a cluster of four, taken to be the
efficiency cluster) stayed fully busy for the whole 60 s after the boot
started in every boot with CPU samples, including the time after home. So "a quiet host" can only mean a quiet host at the boot's
start: during the boot, any Mac of this size is saturated by the boot itself
(the reference's second boot uses about 500 device CPU seconds in its first
120 s, `parity-ladder.md` §3.1). §17's loads of 90–690 were measured the
same way and included the boot's own load.

### 19.2 dasd's failing read on a quiet and on a busy host

"Wait" is the longest read: from dasd's "Fetching uncached value for
/device/system/isPluggedIn" (or "CoreDuet: ClientContext
objectForContextualKeyPath:") to "error getting value for …isPluggedIn
… Connection init failed at lookup with error 3" on the same thread. In
every boot it is an `isPluggedIn` or `batterySaver` read and starts
dasd's silence (§17.6); in f1 and g1 two such reads followed each
other. launchd_sim logs the look-up failure for dasd at 1.8–9.2 s (one line per boot), and dasd's first read fails at once (its
failure line follows within 10 ms in every boot).

| Boot | Load at start | Load in the wait (median / max) | home_s | Wait: start → end (s) | Wait | End − home | Other reads ≥ 1 s |
|---|---|---|---|---|---|---|---|
| a1 fresh, quiet | 8.3 | 199 / 372 | 53.1 | 8.8 → 64.0 | **55.2** | +10.9 | 9 (to 4.3 s) |
| d1 fresh, quiet | 12.0 | 130 / 300 | 91.5 | 6.5 → 60.7 | **54.2** | −30.8 | 11 (to 18.1 s) |
| f1 fresh, quiet | 8.7 | 199 / 330 | 40.6 | 5.3 → 21.4 (`isPluggedIn`), then 23.0 → 61.1 (`batterySaver`) | **16.0 + 38.1** | +20.5 | 7 (to 1.4 s) |
| g1 fresh, quiet | 8.6 | 172 / 282 | 41.7 | 6.4 → 16.3 (`batterySaver`), then 20.6 → 57.8 (`batterySaver`) | **10.0 + 37.2** | +16.1 | 11 (to 20.9 s); two `batterySaver` reads from 144.4 and 149.5 s had not ended at the read-out |
| a2 aged, quiet | 8.7 | 60 / 98 | 30.7 | 13.4 → 30.1 | **16.7** | −0.6 | 4 (to 5.1 s) |
| a3 aged, quiet | 8.5 | 97 / 166 | 30.8 | 7.7 → 32.6 | **25.0** | +1.8 | 1 (2.5 s) |
| a4 aged, quiet | 7.9 | 71 / 146 | 23.5 | 4.0 → 24.4 | **20.4** | +0.9 | 1 (1.6 s) |
| b1 fresh, busy | 134.6 | 374 / 736 | 73.3 | 12.6 → 107.8 | **95.1** | +34.5 | 2 (to 36.8 s); a new `isPluggedIn` read from 249.6 s had not ended at the read-out |
| c1 fresh, busy | 266.5 | 386 / 583 | 151.2 | 8.2 → 77.1 | **68.9** | −74.1 | 1; a new `isPluggedIn` read from 78.2 s had not ended at 200 s |
| e1 fresh, busy | 217.2 | 337 / 526 | 77.9 | 8.6 → 121.7 | **113.0** | +43.8 | 6 (to 36.9 s); a `batterySaver` read from 265.1 s had not ended at the read-out |

- **Aged device, quiet start: 16.7–25.0 s, median 20.4 s (n = 3), ending
  0.6 s before to 1.8 s after home (median +0.9 s).** Fresh device, quiet
  start (n = 4): the longest read 37.2–55.2 s (median 46.2 s), and dasd
  blocked from 5–9 s until 57.8–64.0 s in a1, d1, f1 and g1 alike; the end
  falls 30.8 s before to 20.5 s after home, because a first boot keeps the
  CPUs saturated after home. Busy start: 68.9–113.0 s (n = 3), and in
  two of them a further read was still waiting at the end of the window.
- The wait is never "at once" and never a fixed length: it ranges over a
  factor of 7 and grows with the load the host carries during it.

### 19.3 What ends the wait: dasd's threads get no CPU

`ps -M` of dasd, sampled during each wait (9 boots with samples; d1's
sampler stalled from 5 to 62 s):

| Boot | Samples in the wait | dasd threads runnable (`R`) at priority 4 | Runnable above 4 | dasd CPU accrued during the wait |
|---|---|---|---|---|
| a1 | 26 | 2–3 | 0 | 0.00 s |
| a2 | 6 | 1–2 | 0 | 0.00 s |
| a3 | 8 | 1 | 0 | 0.00 s |
| a4 | 3 | 3 | 0 | 0.00 s |
| b1 | 42 | 1–4 | 0–1 | 0.00 s |
| c1 | 24 | 1 | 0 | 0.00 s |
| e1 | 53 | 1–3 | 0 | 0.01 s |
| f1 (second read) | 17 | 1 | 0 | 0.00 s |
| g1 (second read) | 16 | 1 | 0 | 0.00 s |

- **During the whole wait dasd is not blocked; it is not running.** One to
  four of its threads are runnable at priority 4 (the background band;
  §17.6 saw the same states) and none of them gets CPU: dasd's total CPU
  time does not move (resolution 10 ms) for 17–113 s, and resumes within
  a second of the failure line. The look-up's failure reply is not being
  held by anyone; the thread that would take it, or the one the reading
  thread waits for, simply does not run.
- **When it gets to run.** Saturated stretches below are runs of 0.5 s
  samples in which the 14 CPUs' mean busy fraction is at least 0.97, for
  2 s or more. In the three aged quiet boots the read ended −0.2, +1.4
  and +0.6 s from the end of the boot's long saturated stretch (30.3, 31.2,
  23.8 s), that is when the boot's CPU burst eased, which is also about
  when the home screen appears. In the fresh quiet boots: f1's two reads
  ended 0.1 s after the CPUs first had a spare moment (21.3 s) and 0.35 s
  before the end of the next stretch (61.4 s); d1's ended 6.8 s after a
  stretch ended (53.9 s); g1's ended inside a stretch (16.3 s) and 3.3 s
  after one ended (54.4 s). In the busy boots the read ended inside a
  stretch (b1, c1) or 3.6 s after one ended (e1): with the CPUs busy
  throughout, the starved thread gets a slice at an unpredictable time.
- **No other trigger.** As in §17.6, no timer, notification or service
  start precedes the end, and launchd_sim logs nothing about dasd or
  CoreDuet's names in the second before it (10 boots); the end does not
  follow home (it came before home in three boots). It follows the availability of
  CPU to a background-priority thread.

**Answer to the main question.** The reference's read fails neither at
once nor after a fixed wait. It fails when dasd's background-priority
threads next get CPU, so its length is set by how long the host's CPUs stay
saturated: on this Mac, from a quiet start, an aged device's boot saturates
every CPU until about home and the read fails 16.7–25.0 s after it started
(median 20.4 s), 0.9 s after home (median; −0.6 to +1.8 s); a fresh
device's longer first boot, which keeps the CPUs saturated past home,
holds it 37–55 s per read and until 58–64 s in all; a host that is
already busy holds it 69–113 s, with no relation to home. It is a load
effect, but the load that matters on a quiet host is the boot's own, so
the effect is part of the reference's normal behaviour on this class of
Mac, not an artefact of §17's busy host.

### 19.4 SpringBoard's notification server

| Boot | home_s | dasd "SUBMITTED …BundleLibrarianVacuum…" | SpringBoard "notificationSourcesDidInstall … initialLoad=1" |
|---|---|---|---|
| a2, a3, a4 (aged, quiet) | 30.7, 30.8, 23.5 | 39.3, 38.0, 33.2 (home + 8.6, + 7.2, + 9.7) | 39.7, 38.4, 33.7 (home + 9.0, + 7.6, + 10.2) |
| a1, d1 (fresh, quiet) | 53.1, 91.5 | 93.8, 125.0 (home + 40.7, + 33.5) | 106.8, 133.0 (home + 53.7, + 41.5) |
| f1 (fresh, quiet) | 40.6 | 87.3 (home + 46.7) | 90.3 (home + 49.7) |
| g1 (fresh, quiet) | 41.7 | not within 200 s | not within 200 s |
| b1, c1, e1 (fresh, busy) | 73.3, 151.2, 77.9 | not within 200 s (e1: 261.9, during the read-out) | not within 200 s |

- On an aged device from a quiet start, dasd accepts SpringBoard's task
  **7–10 s after home** (median 8.6 s), 5.3–9.2 s after its read failed,
  and SpringBoard's initial load follows 0.4–0.5 s later. The order of
  §17.7 holds in every boot.

### 19.5 LaunchServices' `privacy` and `datasep` categories

- **The configuration.** The runtime's
  `System/Library/Preferences/Logging/Subsystems/com.apple.launchservices.plist`
  (§18.2: `DEFAULT-OPTIONS` `Level`/`Enable` = `Info`; `privacy` and
  `datasep` `Level`/`Enable` = `Default`, `Persist` = `Default`) is the only
  logging preference involved. The runtime has no `Library/Preferences/Logging`;
  its `System/Library/Preferences/Logging/Processes` holds two unrelated
  process files; a new device's `data/Library/Preferences/Logging` is an
  empty folder (checked before its first boot).
- **The guest honours it.** `log config --status` in the booted device
  (every boot, at the window's end): system mode `INFO STREAM_LIVE
  PRIVATE_DATA`; subsystem `com.apple.launchservices` `INFO
  PERSIST_DEFAULT`; categories `privacy` and `datasep` `DEFAULT
  PERSIST_DEFAULT`; category `binding` (not in the plist) `INFO`. So the
  per-category level overrides both the subsystem's and the system's
  `INFO`.
- **From the first second.** `log show --info --debug` of each 200 s
  window (12 boots, fresh and aged, from t = 0): **no** message of either
  category from any process, while the same subsystem's other categories
  log at info level (an aged boot: `default` 55 info messages, `db` 51,
  `dmfsupport` 2). The two Ycode patterns of §15.7 are absent as in §17.3.
- **A live info stream makes them appear.** Untimed experiment (device
  `-ls`, second boot): `log stream --info --debug` with the predicate
  `subsystem == "com.apple.launchservices"` started 0.86 s after the boot
  call and ran 90 s. The stream received 4 378 `privacy` and 1 245
  `datasep` info messages ("constructing bundle record for …" 4 378,
  "application record search init. …" 1 225, "bundle record search with
  …" 20), from 2.9 s on: PosterBoard 3 142, SpringBoard 1 153 (978 of them
  by 30 s), linkd 294, WidgetRenderer 216, runningboardd 212, and others.
  `log show --info --debug` of the same window, read afterwards, holds
  **none** of them (355 LaunchServices messages, none of either category),
  and the system mode read during and after the stream was the same
  (`INFO STREAM_LIVE PRIVATE_DATA`).
- So the reference's clients send a `privacy` or `datasep` info message
  only while a live stream asks for info (or debug) messages, and then only
  to that stream: such messages are neither kept in memory nor stored.
  Without that stream they are not sent at all, from process start. The
  `STREAM_LIVE` flag alone (present in every boot, with no stream of ours)
  does not make them be sent.
- For Ycode (§18.2): a stream-less Ycode boot behaves like a reference
  boot with an info-level live stream attached (the same two patterns, in
  the same programs, about 3 000 in SpringBoard by home). The expected
  behaviour: with no live stream asking for info, a client drops an info
  message in a category whose configured level is `Default` before it is
  sent, even though the system mode reads `INFO` and `STREAM_LIVE`; with
  such a stream it sends it to the stream only. What in Ycode's guest
  looks like an info-level live stream is the thing to find (§19.9).

### 19.6 containermanagerd and lsd's first query

| Boot | lsd's class 10 "Query" → "Query result" (s) | Duration | per-user containermanagerd "launching: ipc (mach)" | its first log line |
|---|---|---|---|---|
| a1 | 3.337 → 3.614 | 277 ms | 3.337 | 3.570 |
| a2 | 3.874 → 4.414 | 541 ms | 3.874 | 4.376 |
| a3 | 3.755 → 4.036 | 281 ms | 3.755 | 3.997 |
| a4 | 2.165 → 2.415 | 250 ms | 2.165 | 2.382 |
| d1 | 4.504 → 4.798 | 295 ms | 4.504 | 4.759 |
| b1, c1, e1 (busy) | 9.359 → 9.642, 5.732 → 6.003, 6.390 → 6.764 | 283, 271, 375 ms | 9.359, 5.733, 6.390 | 9.598, 5.960, 6.701 |
| f1 | 3.711 → 5.155 | 1 444 ms | 3.712 | 5.115 |
| g1 | 3.782 → 4.447 | 665 ms | 3.782 | 4.411 |

- **containermanagerd is not running when lsd first queries it.** In every
  boot launchd_sim launches the per-user `com.apple.containermanagerd`
  ("launching: ipc (mach)") in the same millisecond as lsd's class 10
  query: the query starts it, as in Ycode (§18.2). (Earlier, lsd's class
  12 look-up of its own system container is answered by the system
  instance, `com.apple.containermanagerd.system`, launched on demand
  0.3–0.7 s before.)
- **The query takes 250–1 444 ms, median 289 ms (n = 10)**, of which
  0.22–0.50 s is containermanagerd's start to its first line, against
  Ycode's 4.8 s (§18.2), with the host saturated in both.

### 19.7 liveactivitiesd's start

| Boot | Spawned (launchd_sim) | First log line | End of its start-up burst (last line before ≥ 5 s of silence) | Spawn → end | CPU at the first sample after spawn | CPU at 60 s |
|---|---|---|---|---|---|---|
| a1–a4 | 3.88, 4.35, 4.05, 2.37 | 6.32, 6.75, 6.41, 4.40 | 8.66, 9.69, 11.27, 7.73 | 4.8, 5.3, 7.2, 5.4 s | — (sampler times not exact) | 2.08, 2.05, 2.15, 1.93 s |
| b1, c1, d1, e1 | 9.70, 6.14, 4.86, 6.84 | 11.94, 8.67, 7.09, 9.09 | 14.36, 11.17, 9.86, 11.58 | 4.7, 5.0, 5.0, 4.7 s | 1.92 s at 11.78; 2.22 s at 9.11; —; 2.19 s at 10.38 | 2.07, 2.41, 2.09 (at 62.6), 2.21 s |
| f1 | 4.94 | 7.18 | 10.69 | 5.8 s | 0.88 s at 6.06 | 2.04 s |
| g1 | 4.22 | 6.32 | 8.96 | 4.7 s | 1.23 s at 5.57 | 2.00 s |

- **From start to idle: 4.7–7.2 s wall (median 5.0 s, n = 10), and about
  2.0 CPU s in all (1.93–2.41, median 2.08).** The idle state is the
  first silence of 5 s or more; liveactivitiesd then stays quiet until other processes
  call it (16.6 s in a4).
- **Most of the CPU comes before its first log line.** In the boots with
  exact sampler times, 0.88 CPU s were spent 1.1 s after the spawn (f1),
  1.23 s after 1.35 s (g1), and 1.9–2.2 CPU s after 2.1–3.5 s (b1, c1, e1); the first line ("MallocStackLogging: could not tag …",
  then its own greeting) appears 2.0–2.5 s after the spawn, and the
  2.5–5 s of logging that follow cost little CPU. So the reference's
  liveactivitiesd also does about two seconds of computation in one
  stretch at its start, before or at the top of `main`, without log output.
- Against Ycode (§18.8: 3.4 s of guest code without a trap on its main
  thread; 3.6–4.0 CPU s in all): with the Thor's core 1.25 × slower than
  the Mac's on loader-like work (§10.4), the reference's 2.1 CPU s would
  be about 2.6 s on the Thor, so Ycode spends about 1.0–1.5 CPU s (about
  40–55 %) more. The phase is real on the reference; the excess, not the
  phase, is what to look for.

### 19.8 Recommendation for `YCODE_LOOKUP_HOLD`

**Keep the behaviour; change the release.** The reference does hold
dasd's failing read from a quiet start (§19.2), so a Ycode boot without
the hold does work before home that the reference does after it. But the
reference's release is not a time: it is the moment dasd's
background-priority threads get CPU, which on a quiet Mac is when the
boot's CPU burst ends, about home.

1. Preferred (general, no service names): **model the background band.**
   A guest thread at priority 4 or below does not run while every host CPU
   available to the simulator is busy with guest threads of higher
   priority; it runs as soon as one is free. That is what the reference
   shows (§19.3); in Ycode it would give dasd's wait without a timer or a
   service name, and delay any other background-band work the same way.
2. Until then, keep `YCODE_LOOKUP_HOLD=com.apple.coreduetd.context` on by
   default, but **release the held failure replies when the home screen is
   first shown, plus 1 s** (reference: release 0.6 s before to 1.8 s after
   home, median 0.9 s after, n = 3), not at a fixed 40 s. With Ycode's
   home at 27.6–27.9 s (§18.5) a 40 s release is 12 s later than the
   reference's; §18.5 found 30 s and 40 s equal for home_s, so the
   home-relative release should keep the −5.6 s while matching the
   reference's order after home: dasd's backlog starts at about home + 1
   s and accepts SpringBoard's notification task about 7–9 s later
   (§19.4). If the kernel cannot see home, the next best fixed value is
   the reference's median end on an aged device, **about 30 s** after
   the boot starts (24.4, 30.1, 32.6 s).
3. Do not reproduce the busy-host values (69–113 s) or the fresh-device
   values (37–55 s) as defaults: they measure the host, not the boot of an
   aged device that `parity-ladder.md` benchmarks.

### 19.9 Open questions

1. **Which thread is starved.** Without root, `sample` and `ps -M` cannot
   show whether the runnable priority-4 thread is the reading thread
   itself (waiting for its reply's delivery) or a queue it waits for; the
   observable rule (no CPU for the background band while the host is
   saturated) does not depend on it.
2. **A Mac without the VMs.** This host's floor (load 7.75) comes from
   about 4 CPUs of VMs; on an idle Mac of the same size the boot's burst,
   and so dasd's wait, may end a little earlier. A repeat of the aged
   boots on a Mac with nothing else running would refine the 30 s
   fallback.
3. **liveactivitiesd's two seconds**: what it computes before its first
   log line is not visible from outside (no log output in that stretch);
   a `sample` of it 0.5–2 s after the spawn would name the frames.
4. The system mode `STREAM_LIVE` in every boot (no stream of ours
   running at the time): which host client keeps that live stream open and
   at what level; on the reference it does not make `Default`-level
   categories send info messages (§19.5), so in Ycode check what level the
   guest's clients believe the live stream asks for.

## 20. The background band, LaunchServices' categories, containermanagerd, liveactivitiesd, decmpfs (agent B3-BOOT5, 2026-11-07)

§19.8's recommendation (model the background band) and §19.5–§19.7's
questions, with Ycode's own simulator; and the LZBITMAP asset files of
§18.3 with `lzbitmap.md`. Target: home_s ≤ 21.4 s, full boot, every service
on (networking and the Duo's inner panel included).

### 20.1 Conditions

- Thor; one copy of the golden device in the agent's own folder (iPhone
  Duo, iOS 27.1), booted three times at that path before series V1 (two
  plain boots, one smoke boot of the band) and two more after the rebuild
  before V2; full boot, default switches, `YCODE_HOME_WATCH`, stopped 5 s
  after home (diagnostic boots 10–700 s), no save.
- Builds: *tree* = `e6555da0` plus this section's changes, every new switch
  off by default, so the default arm is the main line's program. V1 ran the
  build of `1e443870` without decmpfs; V2 the build with §20.6 (decmpfs) and
  `YCODE_BG_BAND_BG_CPUS`.
- Timed series under the shared boot-timing lock, every boot started with
  no other `ycode-simd` and a 1-minute load under 4 (3.38–3.99), arms
  rotated each round, n = 5 per arm (V1 02:59–03:39, V2 03:55–04:35).
- Profiles (`YCODE_FRAME_PROFILE_BOOT=120`) `p-tree` and `p-band`, started
  right after another boot (load about 20): their CPU and wall figures are
  high, their shapes are what is used.

### 20.2 The background band (`YCODE_BG_BAND`, `scheduling-policy.md` §4.9)

A run gate in Ycode's kernel: guest threads are counted as runnable by
host class from a trap's end until they block in the kernel or end; at the
end of each trap a class-bg thread goes on only while fewer than the host's
online CPUs (14) threads are runnable, else it waits, oldest first, until
one blocks, its class rises (boost, ulock or sync-IPC push, send push), its
image ends or its gate closes, or 60 s pass. It replaces no timer and names
no service: dasd's context read waits because dasd's threads are class bg
(an unboosted Adaptive daemon is darwin-bg, §2.2) while the boot keeps
more than 14 higher-class threads runnable.

What it does in a boot (smoke boot, `YCODE_BG_BAND_SAMPLE_MS=500`): runnable
non-bg threads 30–41 in the first 10 s (up to 146 bg threads waiting), then
6–14 from about 10 s to home, with bg threads filling the rest (2–10
runnable, 10–40 waiting); after home 0–5. dasd's threads waited 3–4 s at a
time until 10.2 s and then ran (`YCODE_BG_BAND_TRACE=dasd`): by Ycode's own
count the boot saturates the CPUs with higher-class work for its first
10 s, not until home as on the reference (§19.3). About 350 000–500 000 gate
waits a boot, 1 000 of them ended by a class rise, none by the bound.

### 20.3 Timed series

| Series | Arm | n | median home_s | mean ± sd | range | kernel lock held at home, median | CPU s at home, median | guest fatal |
|---|---|---|---|---|---|---|---|---|
| V1 | default | 5 | **38.62** | 38.71 ± 1.55 | 36.66–40.74 | 8.2 s | 456 | 1–5 |
| V1 | band (`YCODE_BG_BAND=1`) | 5 | **30.77** | 30.85 ± 1.06 | 29.43–32.40 | 4.1 s | 379 | 1–2 |
| V1 | band, 10 CPUs (`YCODE_BG_BAND_CPUS=10`) | 5 | 35.96 | 35.11 ± 3.02 | 31.03–38.28 | 3.9 s | 347 | 1–3 |
| V1 | look-up hold until 40 s (§18.4) | 5 | **28.14** | 28.03 ± 0.60 | 27.17–28.64 | 4.5 s | 354 | 0 |
| V2 | default | 5 | **36.83** | 36.38 ± 1.24 | 34.47–37.63 | 6.9 s | 426 | 1–5 |
| V2 | band | 5 | **29.95** | 30.39 ± 1.93 | 28.61–33.63 | 4.2 s | 361 | 2 |
| V2 | band, background on 4 CPUs (`YCODE_BG_BAND_BG_CPUS=4`) | 5 | 33.16 | 32.86 ± 1.33 | 30.77–34.38 | 3.6 s | 314 | 1–2 |
| V2 | look-up hold until 40 s | 5 | **28.22** | 28.30 ± 0.49 | 27.94–29.15 | 4.2 s | 340 | 0 |

- **The band: −7.9 s (V1) and −6.9 s (V2) by the median**, ranges apart
  from the default's in both series, 65–77 CPU s less before home and the
  kernel lock held half as long. It gives 75–80 % of the hold's gain
  (−10.5 s, −8.6 s) without naming a service and without a release time.
- **The hold is still 1.7–2.6 s faster than the band.** With the band dasd
  runs from about 10 s (§20.2), so part of its backlog and the work it
  starts still come before home: in the profiles, dasd sent 5 529 log
  messages in the first 29 s with the band against 9 561 by default and 10
  with the hold (§18.6); SpringBoard 20 480 (home inside the window) against
  14 595.
- **A stricter band is slower, not faster.** Fewer CPUs for the count (10)
  or at most 4 background threads at once (the reference Mac's efficiency
  cores) keep more background work back, and home comes 3–5 s later than
  with the plain band. The critical path of `p-band` shows why: from 5.7 to
  18.0 s it runs through siriinferenced, whose threads (class bg) spent
  most of that time at the gate (3.1 s of it in `thread_selfid`, the first
  trap of new workqueue threads, which is where the gate catches them)
  while biomed and then the home path waited for it. On the reference such
  a dependency would push the waited-for thread (turnstiles, importance);
  Ycode's pushes cover ulock owners, synchronous IPC receivers once they
  receive, and full queues (`scheduling-policy.md` §4.6), not a server
  thread that has not received yet, nor transitive chains (§4.8). The
  stricter the gate, the more such unpushed waits land on the path.
- The default arm is 3–5 s slower than §18.5's (33.2–33.6 s) with the same
  code: this device copy was booted 3–5 times before the series, against 9
  in §18 (§16.6: a copy's early boots do follow-up work); compare arms
  within a series. V2's default is 1.8 s faster than V1's and uses 30 CPU s
  less; the program differs only by §20.6, whose first boot installed the
  mobile assets (no extraction ran in any V2 boot, one ran in every V1
  boot), so part of that is likely §20.6, inside the spread.

### 20.4 Does the band replace the hold?

Not yet. The band reproduces the mechanism §19.3 found (a background
thread gets no CPU while every CPU is taken by higher work) and wins most
of the hold's time, but in Ycode the higher-class demand falls below the
CPU count about 10 s into the boot, so dasd's read fails at about 10 s
instead of at about home (the reference's 0.9 s after home, §19.2).
Making the gate stricter to keep dasd back longer slows the boot (§20.3),
because Ycode then also starves background work the reference pushes.

Recommendation, adopted 2026-11-07 (`ycode-simd` sets `YCODE_BG_BAND=1`
for `--device` runs unless the variable is set; the owner may reverse it): **turn the band on by default for
device runs** (`YCODE_BG_BAND=1` with `YCODE_BOOT_PRIORITY`): it is the
reference's mechanism, −7 to −8 s, fidelity unchanged except
pairedsyncd's known loop (§20.9); and **keep
`YCODE_LOOKUP_HOLD` off by default** as a service-specific experiment. If
the extra 2 s matter before the push model is extended, §19.8's fallback
(the hold released at home + 1 s, or at 30 s) remains, but with the band
on it would also hold a read the band already delays. The next step that
should close the band's gap to the hold is the missing push: a sync-IPC
request queued on a port pushes the thread (or workloop) that will receive
it, before it receives (xnu's send turnstile), transitively. Not done here.

### 20.5 LaunchServices' `privacy` and `datasep` categories (§19.5)

- **The guest's configuration is the reference's.** One-shots in a Ycode
  boot (20 s after the bind): `log config --status` → `System mode = INFO
  STREAM_LIVE PRIVATE_DATA`; `com.apple.launchservices` → `INFO
  PERSIST_DEFAULT …`; its `privacy` category → `DEFAULT PERSIST_DEFAULT …`;
  `binding` → `INFO …`: the same words as §19.5's, in every field.
- **The store is the reference's.** `log show --info --debug --last 3m` 45 s
  into a boot: 0 messages of `privacy` and `datasep` (176 of the
  subsystem's `default` category), as on the reference. Ycode's logd keeps
  them out exactly as the reference's does.
- **So the difference is only on the wire, and the reference's wire is
  not measured.** §19.5 concluded the reference's clients do not send them
  from the store alone. The reference's diagnosticd receive counter
  (§13.3) exceeds its store by 0.2–2 k messages (1–7 %), and Ycode with the
  hold matched the reference's total exactly (89 808 against about 89 000,
  §18.6) while still sending about 4 300 such messages: both say the
  reference's clients may send them too and diagnosticd drop them.
  Nothing in Ycode's log path tells the guest that an info stream is
  attached (the system mode, the filter plist and the levels are the
  reference's), and no Ycode change is indicated. The dirty-room check that
  decides it: SpringBoard's sends to diagnosticd (its connection's receive
  count, or `sample` stacks in `_os_log_impl_stream` while it logs
  "constructing bundle record") on the reference without a stream. The cost
  if it is Ycode's: under 0.5 s of diagnosticd CPU (§18.2).

### 20.6 Mobile-asset files: decmpfs on Ycode's volume (`lzbitmap.md`)

`LZBitmap.swift` decodes LZBITMAP streams and decmpfs payloads (types 13
and 14), written from `lzbitmap.md` §2–§3; `DecmpfsVolume.swift` makes the
writer's calls work (`file-system-features.md` §3.1): resource forks are
position-addressed and held by the volume (any size), and
`fchflags(UF_COMPRESSED)` with a valid header decompresses the file into
its data and removes the two attributes. Tests: `LZBitmapTests` (the
spec's worked example, stored chunks, the end chunk, copies across chunks,
both container types and their faults), `DecmpfsVolumeTests` (the writer's
call order for both types, a fork written at position 12 then 0, an
invalid header).

In the first boot of the new build 118 compressed files were decompressed
(`ycode-simd: decmpfs:` at exit) and the Siri text-to-speech,
understanding and dialog assets were installed under
`private/var/MobileAsset/AssetsV2`; in the 25 boots after it no extraction
ran (`STExtractionService` started in every default boot of V1 and in none since), so
the per-boot download-and-fail loop of §18.3 is gone. `lzbitmap.md` §5
question 1 (why the extractor compresses at all) was not traced: on this
device the extractor no longer runs; a fresh copy's first boot would show
it.

### 20.7 containermanagerd (§19.6)

A `log stream` boot with the device's `launchd.log` (seconds after lsd's
query, which is the reference's "same millisecond" event):

| Step | Ycode | Reference (§19.6) |
|---|---|---|
| lsd's query → launchd_sim "launching: ipc (mach)" | 0.03 s | 0.000 s |
| → xpcproxy_sim spawned, the daemon executed | 0.06, 0.19 s | — |
| → containermanagerd's first log line | 2.27 s | 0.22–0.50 s |
| → it starts on the query | 4.18 s | — |
| → lsd's "Query result" | 4.70 s | 0.25–1.44 s (median 0.29) |

- In this boot the launch followed the query by 0.03 s, as prompt as on
  the reference (in §18.2's boot it came 2.1 s after the query). The 4.5 s after it are containermanagerd
  starting and initialising on a saturated host: alone on a quiet Thor
  (`--exec`, the simulator's environment variables) the same program uses
  0.37 CPU s from start to idle (0.25 s of guest code). In `p-tree` the
  waker's path behind lsd's 3.6 s wait is launchd_sim's `posix_spawn`
  (0.59 s) and host run-queue time behind other programs (routined 0.44 s,
  followupd 0.27 s, biomed 0.18 s, launchd_sim 0.16 s): containermanagerd
  waits for CPUs.
- **Ycode's part is its priority.** On the reference an on-demand start runs
  at priority 46 while it starts (`scheduling-policy.md` §3, above the
  default 31 of the daemons it competes with), the likely result of the
  waiting client's push (SpringBoard → lsd → containermanagerd: xnu
  turnstiles are transitive). In Ycode containermanagerd runs at class df
  like the ~30 other df threads, and lsd's push reaches it only once it
  receives the query. The same missing push as §20.4; with the band on,
  the boot's first 10 s have fewer competitors.

### 20.8 liveactivitiesd (§19.7)

| Run | CPU s from start to idle | of it guest code |
|---|---|---|
| Ycode in a boot (`p-tree`, §18's `p-tree`) | 4.0 | 3.6 |
| Ycode alone, quiet Thor (`--exec`, simulator environment) | 3.15 | 2.86 |
| Reference (Mac) | 2.08 median | — |
| Reference scaled to the Thor's core (× 1.25, §10.4) | about 2.6 | — |

Alone, liveactivitiesd is idle 3.5 s after its start, having used 3.15 CPU
s: 2.86 s of guest code (dyld's loading and initialisers, then its own
start; without `SIMULATOR_SHARED_RESOURCES_DIRECTORY` it stops in an
initializer after 2.67 s of guest code) and 0.29 s of host kernel and VMM
time. So Ycode's own share is about 0.3 s of host time and 0.3 s of guest
code beyond the scaled reference (the 1.25 factor is the loader's ratio;
it may be larger for this code). The other 0.8 s in a boot is the
saturated host: the same guest code runs slower while every core and the
memory system are busy, which the reference's priority bands spare it no
more than Ycode's (it is an on-demand daemon at default priority on both).

### 20.9 Service fidelity

`scripts/ycode-launchd-spawns` over 700 s, one boot each (V2's build), each
after a boot of the same build, on the same device copy:

| | default | band |
|---|---|---|
| home_s of the boot | 36.05 | 30.49 |
| all starts | 516 (239 labels) | 555 (236 labels) |
| restart loops (facetimemessagestored, managedappdistributiond, mlhostd, proactiveeventtrackerd, intelligencetasksd, fileindexerd) | 67, 66, 64, 68, 12, 1 | 67, 65, 63, 68, 12, 1 |
| other daemons and agents | 178 | 219 |
| per-process domains | 57 | 57 |
| apps | 3 | 3 |
| starts by reason (xpc event, Mach IPC, demand, speculative) | 329, 102, 37, 32 | 322, 148, 37, 32 |

The one label that differs by more than one start is **pairedsyncd, 1 →
45**: the Mach-IPC restart every 10 s that §18.7 saw in its *default* boot
(47) and not with the hold (1), one of Ycode's own restart loops
(`parity-ladder.md` §3.3; on the Mac it starts once). Its trigger depends on
the order of the post-home work, which both the hold and the band move; it
is not the band's (§18.7's default boot had it). Every other label differs
by one start (geocorrectiond, mapssyncd, idcredd, parsec-fbf,
agentstored, cksharingmanagementd −1; fitcore, backgroundassets.user, a
key-syncing agent +1; the throttle loops' phase). Fidelity is otherwise
unchanged.

### 20.10 How far from 21.4 s, and what is left

- Default switches: **36.8–38.6 s** on this device copy tonight (V1, V2).
  With the band: **30.0–30.8 s, 1.40–1.44 ×** the reference, 8.6–9.4 s short.
  With the look-up hold (for comparison): 28.1–28.2 s.
- The band's remaining gap to the hold is dasd's backlog before home
  (§20.3). The step that should close it, and help containermanagerd
  (§20.7): a push from a waiting synchronous sender onto the thread or
  workloop that will receive its message, before it receives, and through
  chains.
- Then, in order of size: the critical path of `p-band` after 18 s runs
  through diagnosticd's hand-offs (2.2 s, §16.5), PosterBoard's
  `getattrlist` (0.6 s), searchd's timer and DockFolderViewService's guest
  code (3.4 s at the end, the home screen's dock); LaunchServices' messages
  wait for the dirty-room check of §20.5.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Per-thread CPU, guest time, run-queue wait in `/proc/<pid>/task/<tid>/{stat,schedstat}` | 1 | proc(5), Linux scheduler statistics documentation |
| KVM binary statistics (`KVM_GET_STATS_FD`, `exits`, `wfi_exit_stat`, `wfe_exit_stat`) | 1 | Linux KVM API documentation §4.133 |
| Memslot changes wait for an SRCU grace period; KVM follows host mappings through MMU notifiers | 1, 3 | Linux KVM API documentation (KVM_SET_USER_MEMORY_REGION); holder samples `D __synchronize_srcu` in our trap profile |
| `mremap` with `MREMAP_FIXED` replaces the target range | 1 | mremap(2) |
| Stage-2 block mappings for THP-backed memory | 1 | Linux KVM arm64 documentation; Arm ARM (stage-2 block descriptors) |
| What `loadDependents`, `matchesPath`, `getLoader` and the mach_o image and header classes do (§5.2) | 1 | apple-oss-distributions/dyld (`dyld/JustInTimeLoader.cpp`, `dyld/Loader.cpp`, `mach_o/Image.cpp`) |
| Function names at the sampled `dyld_sim` offsets (§5.2) | 4 | `dyld_sim`'s symbol table (`llvm-nm`); no disassembly |
| Guest speed, AMFI 0xFD experiment (§5.3) | 3 | `p_cpu` in the guest and on the host; one `--exec` run with an experimental host-stub build |
| Timings and counts in §2 and §4 | 3 | Boot profiles of harness boots on the Thor (`SX/PROF/runs`, `SX/PROF/c*/runs`) |
| Mac image counts, loader CPU, process timelines, PosterBoard and runningboardd log lines (§6.2, §6.3) | 3 | `p_load`/`libp_loadtap.dylib` with `simctl spawn`; `ps` polling; `launchd.log`; `simctl spawn … log show` on throwaway devices |
| The Mac's simulator cache is the runtime's own prebuilt file; its header flags (§6.1) | 2 | Directory listing of the runtime and `/Library/Developer/CoreSimulator/Caches/dyld`; header field at 0xDC (`macho-and-dyld-cache.md`) |
| Ycode timelines and trap profiles (§6.3–§6.5) | 3 | Harness boots `SX/PROF2/runs/k1–k9`, `m1–m3`, `o1–o3`; guest `log stream` one-shots |
| Same lookup branch on both platforms (§6.2) | 1 | apple-oss-distributions/dyld `dyld-1378`: `Loader::getLoader` (simulator branch), `JustInTimeLoader::makeJustInTimeLoaderDyldCache`, `JustInTimeLoader::matchesPath` |
| Spawn-trap costs, starts in progress, lone-start splits, object walks (§7) | 3 | Boot profiles with `YCODE_BOOT_PROFILE_TRAPS` (`SX/SPSPAWN/runs/p1–p4`, `SX/PROF2/runs/k4`), `--exec` runs (`SX/SPSPAWN/probes`) |
| Boot critical path, milestones, backbone attribution, CPU and run-queue totals (§8) | 3 | profiled cold boots `ide-remote/bootcp/runs/r1`, `r2q`, `r3q` of Ycode's simulator on the Thor (frame-profile windows, black-box observation of the guest's traps and wakeups) |
| Changes and their timed boots (§8.6) | 3 | `ide-remote/bootcp` series C and D (`timed.sh`), profiled `r4q-hand`, `C-prof-qos` (Ycode's simulator on the Thor) |
| xnu hands a freed queue slot to one woken sender; send turnstiles push blocked senders' priority onto the receiver (§8.6) | 1 | xnu `osfmk/ipc/ipc_mqueue.c`, `ipc_port.c` (open source) |
| The log messages' Mach id 0x10000000 and the blocked sends to diagnosticd (§8.3 item 4) | 3 | the same traces (`mach_msg2` arguments: id, send-only options); `launchd-sim.md` §8.1 |
| Per-image creation timeline, address-space call counts, VM counts and reuse (§9) | 3 | Profiled boots `SX/SPAWN/runs/p-base-1…3`, `p-hot-1`, `p-reuse-1`, `p-new-1` with the `LD_PRELOAD` counter; lone starts `SX/SPAWN/probes` |
| arm64 KVM looks up the faulting address's mapping under the address-space lock (read) in a stage-2 fault; `KVM_CREATE_VM` registers an MMU notifier, whose registration takes the address-space lock for writing and every mapping's lock (`mm_take_all_locks`) | 1 | Linux 6.8 sources (`arch/arm64/kvm/mmu.c` `user_mem_abort`, `mm/mmu_notifier.c`), Linux KVM API documentation |
| `KVM_ARM_VCPU_INIT` may be called again after a vCPU ran and resets it; `KVM_ARM_SET_COUNTER_OFFSET` and the SMCCC filter cannot change once a vCPU ran | 1 | Linux KVM API documentation (4.82, 4.141, `KVM_ARM_VM_SMCCC_FILTER`) |
| `MADV_DONTNEED` on a private file mapping drops the copy-on-write pages and shows the file's bytes again; on anonymous memory, zeros | 1 | madvise(2) |
| `tlbi vmalle1is` invalidates the stage-1 entries of the current VMID on every PE of the inner shareable domain | 1 | Arm Architecture Reference Manual (TLBI VMALLE1IS) |
| No `KVM_CAP_PRE_FAULT_MEMORY` on the Thor; THP `always`, `shmem_enabled = never`, no `CONFIG_READ_ONLY_THP_FOR_FS` | 3 | `KVM_CHECK_EXTENSION` on `/dev/kvm`, `/sys/kernel/mm/transparent_hugepage/*`, `/proc/config.gz` |
| `thread_selfusage` returns mach absolute time; `CLOCK_THREAD_CPUTIME_ID` and `CLOCK_PROCESS_CPUTIME_ID` use it and `getrusage` (§7.5) | 1 | apple-oss-distributions/Libc `gen/clock_gettime.c`; xnu `bsd/kern/kern_resource.c` (getrusage fills `ru_utime`/`ru_stime`) |
| Series S1, S2, profiled boot `prof1`, pipeline-cache growth (§10.1–§10.3) | 3 | B3-GPU's Thor runs (`ab-S1`, `ab-S2`, `prof1`: home-watch lines, exit summaries, `YCODE_METAL_STATS` lines, `scripts/ycode-frame-profile`) |
| diagnosticd's `POSIXSpawnType` is Interactive (§10.5) | 2 | its launchd plist in the runtime, read as a property list |
| Single-thread speed of the Mac and the Thor (§10.4) | 3 | `scripts/host-probes/cpubench.c` on both machines |
| Reference home_s, bootstatus_s, load (§13.2) | 3 | `research/dirty/simobs` boot runs: `simctl bootstatus -b`, `simctl io … screenshot --display=primary` brightness, host load average |
| Message rate, per process, one message per event (§13.3) | 3 | diagnosticd's `msgrecv` (`top`), `simctl spawn … log show --info --debug --style ndjson` event timestamps; the filter plist read as a property list (2) |
| Receive rights, `qlimit` 16 and 6, full queues, owners (§13.4) | 3 | `lsmp` of diagnosticd and of every device process (send rights matched by object id) |
| Blocking sends on the log-streaming path (§13.4) | 4 | `sample` call stacks of runningboardd, cfprefsd and SpringBoard (public function names only) |
| No loss, no quarantine (§13.4) | 3 | counter against store; event types in the store; `diagnosticd.0.log`, `logd.0.log` |
| Thread priorities (§13.5) | 3 | `ps -M` |
| Host end of `.sim_diagnosticd_socket` (§13.5) | 3 | `launchctl print system/com.apple.diagnosticd`, `ps`, `ls -l` |
| Profiles, lock stalls, holder stacks, queue limits, timed series S1–S3 and SVC, service counts (§12) | 3 | B3-BOOT's Thor runs (`fp/b1`, `off2`, `on2`, `onp2`, `t1`, `s200` and trap profiles `tp/t1`, `tp/t2` with `YCODE_TRAP_PROFILE_STACKS`; `ab-S1`, `ab-S2`, `ab-S3`, `ab-SVC`; `scripts/ycode-frame-profile`, `scripts/ycode-launchd-spawns`, `llvm-symbolizer` on Ycode's own binary) |
| Bisection of `5f74ef9..a906b5f6` and the switch-off series S4 (§12.5) | 3 | B3-BOOT's Thor runs (`bisect.txt`, `ab-B<commit>`, `ab-S4`): release builds of each commit's `ycode/`, `specs/` and `frameworks/` (no `research/`) |
| The reference's simulator uses the host's network (§12.5) | 1 | Apple's public Simulator documentation |
| Per-message send and EVFILT_MACHPORT receive cost (§12.2) | 3 | a release-build micro-benchmark of Ycode's kernel on the Mac (SplitWorld, 20 000 messages of 1 KB) |
| Native mode stage 1, per-call costs and whole-program times in both modes (§11.5) | 3 | B3-NATIVE's series `s2` on the Thor (`ycnative`, `nt_bench`, `nt_probe`, Milestone A samples; `native-mode.md` §10) |
| Networking's cost is apsd's reconnect storm; Ycode's socket traps and their L0 time; log sends, traps and socket calls per program; the inner panel's frames and SpringBoard's extra guest code; diagnosticd's thread time (§14.2, §14.4, §14.5) | 3 | B3-BOOT2's Thor runs: profiles `fp/p-on`, `p-nonet`, `p-nofold`, `p-tree`, `p-tree-nofold` with trap profiles `tp/…` (`scripts/ycode-frame-profile`, two trace readers of our own), frame records at home |
| apsd's log lines: the failed look-up of `com.apple.CoreSimulator.SimIdentityService`, "Could not get certificate", disconnect reason 14, reconnects with "consecutiveFailures 0"; one connection with the identity service (§14.2, §14.3) | 3 | guest `log stream` one-shots of Ycode's own simulator (runs `diag-apsd`, `diag-tree-apsd`, `diag-tree-busy`) |
| The reference's host registers `com.apple.CoreSimulator.SimIdentityService`; apsd is its guest user (§14.2) | 3 | `launchd-sim.md` §6.3, §6.4 (OBS-FSEVENTS's recorder) |
| XPC connection hand-shake and request framing of the identity service (§14.3) | 3 | as Ycode's Metal host (`metal-sim-protocol.md` §2.1); the request's key names from Ycode's own log of the guest's request |
| Timed series T1, T2, T3 and service counts (§14.6, §14.7) | 3 | B3-BOOT2's Thor runs (`ab-T1`, `ab-T2`, `ab-T3`, `runs/fid-base`, `runs/fid-tree`; `scripts/ycode-launchd-spawns`) |
| The identity service's only guest client, its timing, apsd's courier connections, the 17 bytes signed, "Connected response ok" (§15.2, §15.3, §15.5) | 3 | `research/dirty/simobs2` boots: `simctl spawn … log show --info --debug --style ndjson` of apsd and every process, 10 second boots (5 new, §13's 5 re-read) |
| The host end in CoreSimulatorService, certificate issuance through `mobileactivationd`, the SEP key and ECDSA signing, the certificate chain's issuer names and validity, one key per device (§15.2–§15.4) | 3 | host `log stream --info --debug` of `com.apple.CoreSimulator.CoreSimulatorService` and `mobileactivationd` during the boots; the persisted host log |
| No key names visible; no port of the host end visible; no sample of the exchange (§15.3) | 4 | `lsmp` of apsd and the device's processes (the host service refuses `task_for_pid` without root), `sample` of apsd at 1 ms |
| Message counts and patterns of SpringBoard, mobileassetd, dasd, biomed; onset times; the absent patterns (§15.6, §15.7) | 3 | the same `log show` output, patterns from format strings and normalised message text |
| Ycode's counts and patterns (§15.6–§15.8) | 3 | §14.8; B3-BOOT2's guest `log stream` one-shots `diag-tree-sb`, `diag-tree-busy` of Ycode's own simulator |
| `fclonefileat` is the public clone call (§15.7) | 1 | clonefile(2) |
| biomed's temporary files: create, unlink, file port, `fclonefileat` ENOENT; nsurlsessiond's `/.nofollow/` folder paths; FrontBoard's task_info flavors 3 and 18; lsd's store reads and recovery files (§16.2–§16.4) | 3 | Thor runs of Ycode's own simulator: trap traces (`--trace-name biomed` from B3-BOOT2's `diag-biomed`; `SpringBoard`, `lsd` from B3-BOOT3), guest `log stream` one-shots (`diag-tree-biome`, `diag-nsurl`, `diag-ls`, `diag-tree2`) |
| clonefile(2) clones the open file; a `/.nofollow/` prefix means NAMEI_NOFOLLOW_ANY; task_info structure layouts (§16.2–§16.4) | 1 | clonefile(2); apple-oss-distributions/xnu `bsd/vfs/vfs_lookup.c` (`namei`), `osfmk/mach/task_info.h` |
| dasd's plist paths are absent from the runtime (§16.4) | 2 | directory listing of the runtime copy |
| Hand-off counts, critical path by program, log messages per program, timed series U1 and U2, service counts (§16.5–§16.7) | 3 | B3-BOOT3's Thor runs (`ab-U1`, `ab-U2`, profiles `fp/p-base`, `p-tree`, `p-hand2`, `p-tree2`, `p-fresh`; `runs/fid-*`; `scripts/ycode-frame-profile`, `scripts/ycode-launchd-spawns`) |
| Files lsd writes under the device's data folder, sizes, times, inodes; no writes in clean boots or at shutdown (§17.2, §17.5) | 3 | `research/dirty/simobs3` boots: listings of `DEV/data` before, at the window's end and after shutdown; a 0.25 s poller of `var/db/lsd`; `lsof` of lsd |
| lsd's start-up, build and recovery-marker lines, rebuild statistics, sync with installd; installd's build-version line (§17.2, §17.5) | 3 | `simctl spawn … log show --info --debug` of each boot; experiments a4–a7 on the observer's own device (marker files created, modification times changed, one store file deleted) |
| Log counts and patterns of lsd and SpringBoard; the two Ycode patterns absent (§17.3) | 3 | the same `log show` output, 9 boots here and the 10 boots of §13/§15 re-read |
| lsd started on demand by its first client; client connections and their order (§17.4) | 3 | the device's `launchd.log`; XPC connection lines in `log show` |
| dasd's and SpringBoard's blocked threads: the context read, the self-submissions, `UNSUserNotificationServer init` waiting in `submitTaskRequest:error:` (§17.6, §17.7) | 4 | `sample` of dasd (6 samples) and SpringBoard (1 sample); public symbol names only |
| dasd's thread states and priorities; port rights (§17.6, §17.9) | 3 | `ps -M` every second; `lsmp` of dasd and launchd_sim (no root) |
| dasd's silences, the read that ends them, read latencies; dasd's acceptance of SpringBoard's task against SpringBoard's initial load (§17.6, §17.7) | 3 | `log show` timestamps and thread ids, 19 boots |

| lsd's store files and markers before and after each boot; lsd's and SpringBoard's LaunchServices lines; the `mapdb` reply's memory object; the enumerator's lines; containermanagerd's on-demand launch (§18.2) | 3 | B3-BOOT4's Thor runs of Ycode's own simulator: `var/db/lsd` listings, guest `log stream` one-shots (`diag-ls-debug`, `diag-cm`), the device's `launchd.log`; §16's trap traces and stream (`diag-sb-trace`, `diag-ls`) re-read |
| The runtime's `com.apple.launchservices` logging configuration (categories `privacy`, `datasep`: `Enable: Default`) (§18.2) | 2 | the runtime's `System/Library/Preferences/Logging/Subsystems/com.apple.launchservices.plist`, read as a property list |
| decmpfs header layout and the UF_COMPRESSED flag (§18.3) | 1 | xnu `bsd/sys/decmpfs.h`, `bsd/sys/stat.h`, setxattr(2) |
| AppleArchive's compressed-file writes (types 13/14, resource fork at position 12), the extraction errors, the asset downloads retried (§18.3) | 3 | trap traces of `STExtractionService` (`trace-stx`, `trace-stx2`, the latter with the trace text of commit `725c2dc6`), guest streams `diag-assets`, `diag-assets2`; the host's ext4 attribute limit by a probe of our own |
| Look-ups of unknown names answered by launchd_sim, not the host bootstrap (§18.4) | 3 | the device's `ycode-host-bootstrap.log` (only the 708 request) |
| Series T1 (and T2), profiles `p-tree` and `p-hold40`, log messages and CPU per program, critical paths, fidelity counts (§18.5–§18.8) | 3 | B3-BOOT4's Thor runs (`ab-T1.txt`, `ab-T2.txt`, `fp/`, `runs/fid-tree`, `runs/fid-hold40`; `scripts/ycode-frame-profile`, `scripts/ycode-launchd-spawns`, §16's `logcount.py`) |
| Host load, per-CPU busy fractions, the host's idle floor and what holds it (§19.1, §19.3) | 3 | `research/dirty/simobs4` boots: `os.getloadavg` every second; `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` every 0.5 s (public Mach call, no root); `top`; `hw.perflevel0/1` |
| dasd's long reads, their start and end, launchd_sim's failed look-up, dasd's silences, home_s (§19.2) | 3 | `simctl spawn … log show --info --debug` of each 200 s window (thread ids and timestamps); the device's `launchd.log`; screenshots as §13 |
| dasd's threads runnable at priority 4 with no CPU during the wait (§19.3) | 3 | `ps -M` of dasd about every second (state, priority, user and system time per thread) |
| dasd's acceptance of SpringBoard's task and SpringBoard's initial load (§19.4) | 3 | the same `log show` output |
| The background band's runnable counts, gate waits and dasd's waits; series V1 and V2; the profiles `p-tree`, `p-band` (critical paths, log messages per program) (§20.2–§20.4) | 3 | B3-BOOT5's Thor runs of Ycode's own simulator (`ab-V1.txt`, `ab-V2.txt`, `runs/smoke-band`, `fp/p-tree.1`, `fp/p-band.1`; `scripts/ycode-frame-profile`, `bin/logcount.py`) |
| The guest's logging configuration and the store's LaunchServices messages (§20.5) | 3 | one-shots `log config --status` and `log show` in Ycode boots (`runs/diag-logcfg`, `runs/diag-logshow`) |
| LZBITMAP and decmpfs formats (§20.6) | 1 (via `lzbitmap.md`) | `lzbitmap.md` §2–§4; the worked example of its §2.10 as a test vector |
| Files decompressed, assets installed, extractor starts per boot (§20.6) | 3 | `ycode-simd: decmpfs:` exit line; the device's `AssetsV2` listing; image lines of every run log |
| containermanagerd's and lsd's timeline; standalone starts of containermanagerd and liveactivitiesd (§20.7, §20.8) | 3 | `runs/diag-cm` (`log stream`, the device's `launchd.log`); `--exec` runs with the VMM's `/proc` CPU times (`runs/exec-cm`, `runs/exec-liveact`, `runs/exec-liveact2`) |
| The LaunchServices logging preference and the runtime's and device's logging folders (§19.5) | 2 | the runtime's `System/Library/Preferences/Logging/Subsystems/com.apple.launchservices.plist` read as a property list; directory listings of the runtime and the device's data folder |
| The guest's effective levels, the absence of `privacy` and `datasep` messages, the stream experiment (§19.5) | 3 | `simctl spawn … log config --status` (system, subsystem, three categories) in each booted device; `log show` counts by subsystem, category and level; the untimed `log stream --info --debug` boot against `log show` of the same window |
| containermanagerd launched by lsd's class 10 query; the query's duration (§19.6) | 3 | `launchd.log` ("launching: ipc (mach)") against lsd's `com.apple.containermanager` lines in `log show` |
| liveactivitiesd's spawn, first line, start-up burst and CPU (§19.7) | 3 | `launchd.log`; `log show`; `ps -M` per-thread times |

Level 5 was not used. `.claude/Xcode.app`, `research/dirty/` and Ghidra
were not opened.
§13 is a dirty-room observation (agent B3-SIMOBS): Apple's simulator ran
only as a black box through `simctl`, `top`, `lsmp`, `ps`, `log` and
`sample` on devices named `ycode-test-simobs-*`, which were deleted
afterwards; no binary was disassembled or decompiled. Its raw data stays in
the git-ignored `research/dirty/simobs/`.
§14 (agent B3-BOOT2) is clean-room work: only Ycode's own simulator ran
(on the Thor, with the runtime copy as a black box), and only `specs/`,
Ycode's code and the runtime's launchd plists (read as property lists)
were read.
§15 is a dirty-room observation (agent B3-SIMOBS2): Apple's simulator ran
headless and only through `simctl`, `log`, `lsmp` and `sample` on devices
named `ycode-test-simobs2-*`, deleted afterwards; the host's own log was
read with `log`. No binary was disassembled or decompiled, Ghidra was not
opened, and the Simulator app's window and Xcode's GUI were not used. Its
raw data stays in the git-ignored `research/dirty/simobs2/`.
§16 (agent B3-BOOT3) is clean-room work: only Ycode's own simulator ran
(on the Thor, with the runtime copy as a black box), and only `specs/`,
Ycode's code, public xnu interfaces (as cited) and the runtime's directory listing were
read.
§17 is a dirty-room observation (agent B3-SIMOBS3): Apple's simulator ran
headless and only through `simctl`, `log`, `lsof`, `ps`, `lsmp` and
`sample` on devices named `ycode-test-simobs3-*`, deleted afterwards; files
in those devices' data folders were listed, and in four boots one lsd file
was created, re-dated or deleted beforehand. No binary was disassembled or
decompiled, Ghidra was not opened, and the Simulator app's window and
Xcode's GUI were not used. Its raw data stays in the git-ignored
`research/dirty/simobs3/`.
§18 (agent B3-BOOT4) is clean-room work: only Ycode's own simulator ran
(on the Thor, with the runtime copy as a black box), and only `specs/`,
Ycode's code, public xnu headers and man pages (as cited) and one of the
runtime's logging property lists were read.
§19 is a dirty-room observation (agent B3-SIMOBS4): Apple's simulator ran
headless and only through `simctl`, `log` and `ps` on devices named
`ycode-test-simobs4-*`, deleted afterwards; the host was observed with
`uptime`/`getloadavg`, `top` and `host_processor_info`; one runtime
property list was read and the runtime's and devices' folders were listed.
No binary was disassembled or decompiled, Ghidra was not opened, `sample`
was not used, and the Simulator app's window and Xcode's GUI were not used.
Its raw data stays in the git-ignored `research/dirty/simobs4/`.
§20 (agent B3-BOOT5) is clean-room work: only Ycode's own simulator ran
(on the Thor, with the runtime copy as a black box), and only `specs/`,
Ycode's code, and Apple's public performance documentation (efficiency
cores) were read.
