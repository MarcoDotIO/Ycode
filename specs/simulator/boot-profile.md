# Spec: boot profile, and host memory work off the kernel lock

Status: **implemented 2026-10-17 (agent PROF)**. §1 is a diagnostic
(off by default). §3 lists four changes; each has a switch, and §4 says
which are on by default and why. Measurements are in §2 and §4. §6
(agent PROF3, 2026-10-19) compares the Mac and Ycode process by process
and adds C21.

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
| Device runs with thread QoS and the cgroup host backend: the UI path gets the host CPUs first (items 2–3 of §8.3) | `YCODE_BOOT_PRIORITY=1` (default off; or `YCODE_SCHED_QOS=1 YCODE_HOST_SCHED=cgroup`) | backbone run queue: SpringBoard 3.9 → 1.4 s, diagnosticd after wakeups 3.8 → 1.9 s; blocked log sends 196 thread-s | series C 35.4 → 32.5 s (−8 %); series D 34.5 → 31.7, 31.7 and one 64.9 s boot (kernel lock held 41 s: an idle-class holder, `scheduling-policy.md` §7.4), so not on by default |

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
- BOOT-CP (next): run a holder of L0 at its waiters' class (or give class 0
  a small weight instead of `cpu.idle`), then make `YCODE_BOOT_PRIORITY`
  the default; keep the start hold's quiet test from passing in a boot's
  first seconds (`scheduling-policy.md` §7.4). diagnosticd's own CPU
  priority (an Interactive daemon: class df) — xnu pushes the priority of senders blocked on a full queue onto
  the receiver (send turnstiles); Ycode models ulock and sync-IPC pushes
  only (`scheduling-policy.md` §4.6), not this one.

**Questions for the reference** (black-box, for the dirty room):

1. The queue limit of `com.apple.diagnosticd`'s service port in a booted
   simulator device, and whether log senders ever block on it during a boot
   (Ycode: limit as launchd_sim sets it; senders block for 196–295
   thread-seconds in a 33 s boot).
2. Messages per second from processes to diagnosticd during the first 30 s
   of a subsequent boot (Ycode: about 3,600).

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
| `thread_selfusage` returns mach absolute time; `CLOCK_THREAD_CPUTIME_ID` and `CLOCK_PROCESS_CPUTIME_ID` use it and `getrusage` (§7.5) | 1 | apple-oss-distributions/Libc `gen/clock_gettime.c`; xnu `bsd/kern/kern_resource.c` (getrusage fills `ru_utime`/`ru_stime`) |

Level 5 was not used. `.claude/Xcode.app`, `research/dirty/` and Ghidra
were not opened.
