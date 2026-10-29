# Spec: guest execution efficiency (2026-10-24, agents GUEST-CPU and GUEST-CPU-2)

How fast does plain guest code run in a Ycode micro-VM compared with the
same code on the host, why, and what Ycode changed. Context: the boot's
critical path (`boot-profile.md` §8.3) has SpringBoard's main thread running
guest code for 14.1 s; a Mac runs SpringBoard's whole loader in 5–6 s of
CPU (§6.2 there).

## 1. Instruments

- **`p_gcpu`** (`SimShim/guest-tests/stageperf/p_gcpu.c`, original Ycode
  code): one source built as a guest program (`build-stageperf.sh`, iOS
  simulator platform, `-mcpu=apple-m1` by the target's default) and as a
  native Linux program (`clang -O2 -mcpu=apple-m1 -pthread`), so both run
  the same instructions. Phases: `alu` (dependent integer chain), `chase`
  (random pointer chases over 16 KiB, 1 MiB, 8 MiB, 512 MiB), `tlb16k_N` and
  `tlb4k_N` (one cache line per 16 KiB or 4 KiB page over N pages: cached
  data, uncached translations), `hash` (64 MiB open-addressing table),
  `copy` (libc `memcpy` 8 KiB/512 KiB/128 MiB, an own copy loop, `memset`,
  `bzero`), `touch` (map 64 MiB, touch every 4 KiB, unmap: fresh-memory
  cost), `branch` (binary search, random switch dispatch), `str` (linear
  path-string scans with libc `strcmp` and an own loop: a loader comparing
  install names), `files` (stat, open+mmap+munmap+close, and touching each
  16 KiB of 600 files of 64 KiB–1 MiB), `file` (first touch of each 4 KiB of
  512 MiB of the simulator shared-cache file, then random 16 KiB touches),
  `atomic` (uncontended add and CAS, uncontended mutex, two threads on one
  counter, a two-thread ping-pong), `timer` (`CNTVCT_EL0` reads, the clock
  call), `trap` (`getppid`, a VM exit in the guest), `churn` (a 2,048-page
  chase while another thread maps and unmaps 16 KiB in a loop), `switch` (a
  2,048-page chase in slices with another thread of the process running in
  between). The native build takes `GCPU_NO_THP=1` (prctl
  `PR_SET_THP_DISABLE`) so its anonymous memory is 4 KiB pages.
- **`pmustat`** (`SimShim/guest-tests/stageperf/pmustat.c`, original Ycode
  code, Linux host tool): counts Arm PMUv3 common events of a command and all
  its threads with `perf_event_open` (inherit, user mode only, which
  `perf_event_paranoid` = 2 allows for one's own processes). `-g` counts only
  while a vCPU runs guest code (`exclude_host`; guest EL0 only, since EL1 —
  the shim — is excluded by `exclude_kernel`). Events: cycles, instructions,
  L1 I/D TLB refills, I/D TLB walks, L2 TLB refills, L1/L2 data cache
  refills, front-end and back-end stalls, mispredicted branches, L1 I-cache
  refills, exceptions taken. It also prints the command's user and system
  CPU time.

## 2. Native against guest (Thor, quiet host, 2026-10-26)

Main line 5de53eb (`SX/GCPU`). Each column: median of 3 processes (each
process the median of 5 repeats), spread of the 3 in parentheses; run with
`SX/bin/timed.sh` (load 2.4–3.9 at the start). Native THP: the native
program's anonymous memory in 2 MiB pages (the host default); native 4K: THP
off for the process. Guest: `ycode-simd --exec` (one micro-VM, 16 KiB
stage 1 on 4 KiB stage 2). Ratio: guest / native 4K (time; for GB/s the
inverse).

| Workload | Unit | Native THP | Native 4K | Guest | Ratio |
|---|---|---|---|---|---|
| alu (dependent integer chain) | ns/it | 1.16 | 1.15 | 1.16 | 1.00 |
| chase 16 KiB (L1) | ns/hop | 1.54 | 1.54 | 1.54 | 1.00 |
| chase 8 MiB | ns/hop | 6.92 | 7.32 | 8.19 | 1.12 |
| chase 512 MiB (DRAM) | ns/hop | 212 | 256 | 241 | 0.94 |
| tlb16k 512 pages | ns/hop | 2.15 | 3.85 | 5.03 | 1.31 |
| tlb16k 2,048 pages | ns/hop | 3.27 | 5.35 | 5.69 | 1.06 |
| tlb16k 8,192 pages | ns/hop | 4.65 | 14.7 (14.3–14.9) | 19.9 (19.5–20.0) | 1.35 |
| tlb16k 32,768 pages | ns/hop | 8.78 | 13.9 (13.9–14.6) | 20.4 (20.1–20.8) | 1.46 |
| tlb4k 8,192 pages | ns/hop | 4.72 | 12.4 | 19.5 | 1.57 |
| tlb4k 32,768 pages | ns/hop | 6.72 | 9.69 | 12.2 | 1.26 |
| hash insert / lookup 64 MiB | ns/op | 21.4 / 35.9 | 22.2 / 38.7 | 23.1 / 39.4 | 1.04 / 1.02 |
| branch: binary search 1 MiB | ns/op | 59.3 | 57.8 | 49.6 | 0.86 |
| branch: random switch dispatch | ns/op | 6.00 | 5.99 | 6.35 | 1.06 |
| atomic add / CAS, uncontended | ns/op | 5.05 / 8.08 | 5.06 / 8.08 | 5.05 / 8.08 | 1.00 |
| two threads on one counter | ns/op | 8.5 | 7.5 (6.7–8.2) | 8.8 | 1.17 |
| ping-pong round trip | ns | 509 | 542 (472–544) | 483 | 0.89 |
| `CNTVCT_EL0` read | ns | 54.4 | 54.4 | 54.4 | 1.00 |
| clock call (vDSO / `mach_absolute_time`) | ns | 69.2 | 69.2 | 69.2 | 1.00 |
| libc `memcpy` 8 KiB aligned / 128 MiB | GB/s | 82.8 / 16.9 | 82.8 / 16.5 | 81.8 / 16.4 | 1.01 / 1.01 |
| own copy loop 128 MiB | GB/s | 16.9 | 16.6 | 16.5 | 1.01 |
| libc `memcpy` 8 KiB, source off by 3 | GB/s | 79.2 | 79.2 | 65.5 | 1.21 |
| libc `memcpy` 100 B, unaligned | GB/s | 19.3 | 19.3 | 15.3 | 1.26 |
| libc `memset` 100 B / 128 MiB | GB/s | 24.7 / 48.2 | 24.7 / 47.9 | 15.3 / 47.3 | 1.61 / 1.01 |
| libc `bzero` 128 MiB | GB/s | 95.8 | 94.9 | 79.1 | 1.20 |
| libc `strcmp`, path strings | ns/cmp | 3.66 | 3.66 | 12.7 | 3.46 |
| own byte-loop compare | ns/cmp | 11.4 | 11.5 | 12.5 | 1.09 |
| `pthread_mutex` lock+unlock, uncontended | ns | 5.82 | 5.80 | 19.3 | 3.32 |
| fresh memory: map, touch each 4 KiB, unmap | µs/16 KiB | 0.29 | 5.7 | 11.4 | 2.00 |
| the same pages touched again | ns/16 KiB | 31.7 | 58.6 | 101 | 1.73 |
| file, first touch of each 4 KiB (page cache warm) | ns/4 KiB | 294 | 294 | 1,970 | 6.7 |
| file, random 16 KiB touches, warm | ns/16 KiB | 9.85 | 19.5 (11.7–19.7) | 23.4 (14.8–24.3) | 1.20 |
| `stat` of a file | µs | 0.99 | 1.13 | 12.5 | 11 |
| open + mmap + munmap + close | µs | 20.9 | 21.4 | 85.4 | 4.0 (see note) |
| `getppid` (a trap; in the guest a VM exit) | µs | 0.094 | 0.093 | 4.41 | 47 |
| 2,048-page chase, quiet | ns/hop | 3.28 | 5.35 | 5.48 | 1.02 |
| the same while another thread maps and unmaps 16 KiB in a loop | ns/hop | 3.31 | 5.36 | 30.9 | 5.8 |

Guest-mode PMU counts (`pmustat -g`, minus a `null` run) against the native
4K program (`pmustat`), same instructions: `alu` 1,500 M instructions in
900 M cycles on both (IPC 1.67); `chase` 982 M instructions on both, 24 M
guest DTLB walks against 29 M native (16 KiB guest pages, 2 MiB stage-2
blocks for fresh pool memory, see §3.2) ; `churn` 15.1 M guest DTLB walks
against 0.5 M native and 0.23 M guest ITLB walks against 0; `str` 2,038 M
guest instructions against 1,361 M (the library `strcmp`, §3.4).

Note (GUEST-CPU-2): the program times with `clock_gettime(CLOCK_MONOTONIC)`.
In the guest, Darwin's libc answers that clock from `kern.boottime`
through `sysctlbyname`, two `sysctl` traps per call (10.7 µs) until the
library kept those answers (§6.2). Rows that read the clock per file (the
`files` rows: open + mmap + munmap + close, and the per-16 KiB touch of each
file, 700 ns, which is one clock call per file spread over its pages)
therefore overstate the guest's cost; §7 has the values with §6.2.

## 3. Where the remaining difference comes from

### 3.1 Two-stage translation

A guest TLB miss walks the guest's stage-1 tables (16 KiB granule, T0SZ
17: three levels, `vm-shim-protocol.md` §3), and every table address and
the final address are guest-physical, so each is translated through KVM's
stage-2 tables (4 KiB granule, 40-bit IPA: two levels to a 2 MiB block,
three to a 4 KiB page). A native miss walks one four-level 4 KiB table. The
walk caches hide most of the extra steps when the tables are cached, so
the cost shows only when the working set's translations exceed the TLB:
`tlb16k` 8,192 pages 19.9 against 14.7 ns (native 4K), 32,768 pages 20.4
against 13.9 ns; PMU: 36.1 M guest DTLB walks against 29.1 M native for
the same `tlb16k` phase (+24 %), with 5 % more cycles.

A combined TLB entry covers the smaller of the stage-1 page and the
stage-2 mapping. So a 16 KiB guest page gets one 16 KiB entry only where
stage 2 maps a 2 MiB block; where stage 2 maps 4 KiB pages it gets four
entries, one per 4 KiB actually touched.

### 3.2 Which guest memory gets 2 MiB stage-2 blocks

KVM maps a 2 MiB block when the host backs the whole 2 MiB with one
PMD-mapped page and the memslot's host address and GPA agree modulo 2 MiB
(Linux `arch/arm64/kvm/mmu.c`, `transparent_hugepage_adjust`,
`fault_supports_stage2_huge_mapping`). On the Thor (THP `enabled =
always`, `defrag = madvise`, `shmem_enabled = never`, ext4 page cache
without large folios, no `CONFIG_READ_ONLY_THP_FOR_FS`):

| Guest memory | Host backing | Stage-2 mapping |
|---|---|---|
| Anonymous pool (heap, stacks, images' writable copies, page tables' pages): `KVMPhysicalBacking` | 16 GiB private anonymous mapping per VM; its host address is 2 MiB-aligned (Linux 6.8 aligns large anonymous mappings) like its GPA | 2 MiB blocks where the host page is still a transparent huge page; 4 KiB once part of it was dropped (§3.3) |
| Shared file arena (shared cache, every read-only file mapping) | page-cache pages of the data volume (ext4), mapped once per host process | 4 KiB (SPAWN's `YCODE_ARENA_HUGE=hot`, `boot-profile.md` §9.5, copies the shared cache's hot chunks into huge pages; off by default) |
| Private file window (writable file mappings over 1 MiB, mostly the shared cache's data) | private file mapping: page cache until written, then 4 KiB anonymous copies | 4 KiB |
| Shared object arena (Mach memory entries, POSIX shared memory) | shared memory (`shmem_enabled = never`) | 4 KiB |
| Per-VM RAM slot (shim, frames, EL1 stack, the guest's page tables) | 1 GiB private anonymous | 2 MiB blocks (never dropped) |

Measured at the home screen of a boot (`/proc/<ycode-simd>/smaps` summed
by mapping kind, census-2 §6): the pools held 1,190 MiB, 718 MiB of it
(60 %) in huge pages.

### 3.3 Dropping part of a huge page splits it

The pool returns freed runs to the host with `MADV_DONTNEED`: runs over
256 KiB at once (after the trap, C17), runs up to 256 KiB once more than
4 MiB of them wait (`staleLimit`), and a reused run with more than 64 KiB
of old data before it is handed out again. Each such call on part of a
2 MiB huge page splits the page (Linux zaps the range from a PTE-mapped
copy of the huge page), and the MMU notifier makes KVM drop the stage-2
block. From then on the rest of that 2 MiB is mapped again 4 KiB at a time
(one stage-2 fault each, a 4 KiB TLB reach), and the dropped part, when
reused, takes a host page fault and a stage-2 fault per 4 KiB. The
`touch` phase shows it: mapping 64 MiB, touching every 4 KiB and unmapping,
repeated, costs 11.3 µs per 16 KiB in the guest against 0.29 µs native with
THP (5.7 µs native 4K), and asking for huge pages (`YCODE_POOL_HUGE=1`,
§4.5) does not change it. §4.6 is the change.

### 3.4 Guest stage-1 settings and VMIDs

- The guest keeps 16 KiB pages and T0SZ 17 (three levels): Darwin
  processes use addresses up to 47 bits (`vm-shim-protocol.md` §3), so the
  walk cannot start lower. The guest tables use no block descriptors and no
  contiguous hint (§8).
- VMIDs: KVM gives each VM a VMID from a 16-bit space and keeps it while
  the VM lives; with VM reuse (SPAWN, `boot-profile.md` §9.5) about 300 VMs
  are made per boot, far below a rollover. A VM's TLB entries are flushed
  on the local CPU when another vCPU of the same VM last ran there (KVM's
  `last_vcpu_ran`), which a multithreaded process meets when its threads
  move between host CPUs; Ycode does not pin vCPU threads.

### 3.5 What it means for a boot

Whole-boot guest PMU counts (`pmustat -g -s 1` around `ycode-simd`, the
area's device at its own path, about 47 s each, 2026-10-27, tlb1 series):

| Pool backing | Boots | Guest cycles | Instructions | CPI | DTLB walks / 1,000 instr. | ITLB walks / 1,000 instr. |
|---|---|---|---|---|---|---|
| default (huge pages until split) | 2 | 707 G, 678 G | 1.80 T, 1.73 T | 0.392, 0.392 | 0.087, 0.087 | 0.043, 0.043 |
| `YCODE_POOL_KEEP_THP=1` (§4.6) | 2 | 691 G, 734 G | 1.77 T, 1.87 T | 0.391, 0.392 | 0.083, 0.083 | 0.043, 0.043 |
| `YCODE_POOL_HUGE=never` (no huge pages at all) | 2 | 676 G, 757 G | 1.72 T, 1.90 T | 0.392, 0.399 | 0.092, 0.097 | 0.046, 0.045 |

About 0.13 page walks per 1,000 guest instructions, whatever the pool's
backing: taking the pool's huge pages away entirely changes the walks by
5–10 % and the guest's CPI by under 2 %. The boot's guest code is not
bound by translation (the earlier TLB maintenance, §4.1–§4.3, was: 211 M
DTLB walks per boot before, 137 M after). The cost of 4 KiB stage-2
mappings in a boot is on the host side: the stage-2 faults themselves
(kernel exits that `ycode-simd`'s user exits do not count; 5.6 M per boot
in `p-GCPU-a`, about half of all exits) and the host page faults behind
them, each taking the host process's address-space lock (`boot-profile.md`
§9.4).

## 4. Changes

### 4.1–4.3 TLB maintenance (agent GUEST-CPU, 2026-10-24)

`vm-shim-protocol.md` §5.2 has the contract. A trap that only filled
invalid descriptors resumes without a TLB flush (a translation that faults
is never cached, Arm ARM); a change of valid descriptors in one span of up
to 256 pages invalidates those pages by VA (`tlbi vale1is`) instead of the
whole VM's TLB; on a host whose CTR_EL0.DIC is 1 (the Thor) the flush no
longer broadcasts an I-cache invalidation. Switches: `YCODE_TLB_FLUSH_ADDS=1`,
`YCODE_TLB_BY_VA=0`, `YCODE_TLB_FLUSH_ICACHE=1` restore the old behavior.
Measured (ab1, 3 processes each, old = all three switches back): the
`churn` chase (another thread maps and unmaps in a loop) 27.7 → 5.9 ns per
hop; flushing resumes in the probe 99,926 → 12,545 (12,509 by VA); in a
boot about 420,000 flushing resumes, 97 % by VA. Boots (h1, 2026-10-26,
one `timed.sh`, 4 rounds rotating, the area's device): main line 5de53eb
32.6, 35.2, 36.4, 37.3 s to the home screen; with §4.1–§4.4 31.4, 31.6,
32.1, 32.0 s; the same with `YCODE_POOL_HUGE=1` 31.5–32.0 s; whole-boot
guest DTLB walks 211 M → 137 M (pmu1).

### 4.4 String and memory routines (agent GUEST-CPU)

`libsystem_platform` (Ycode's host library) got vector `strcmp`,
`memset`/`bzero` and short `memcpy` paths: library `strcmp` on path
strings 12.7 → 5.8 ns, `memset` 100 B 15.3 → 28.8 GB/s, unaligned 100 B
`memcpy` 15.3 → 31.2 GB/s, `bzero` 128 MiB 79 → 92 GB/s (ab1).

### 4.5 `YCODE_POOL_HUGE` (diagnostics)

`1`: the pool's host mapping 2 MiB-aligned with `MADV_HUGEPAGE`; `align`:
aligned only; `never` (GUEST-CPU-2): aligned with `MADV_NOHUGEPAGE`, for
§3.5's comparison. With THP `always` the default mapping already gets huge
pages (§3.2), so `1` changed nothing measurable (ab1, h1).

### 4.6 `YCODE_POOL_KEEP_THP`: return pool memory only in whole huge pages (GUEST-CPU-2)

With the switch, the pool never drops part of a host huge page:

- A released run over 256 KiB drops (after the trap, as before) only the
  whole 2 MiB host pages inside it; the parts before and after them become
  stale pool memory (free, holding old data), as runs up to 256 KiB
  already did.
- A run handed out again is zero-filled where it holds stale data; only
  when more than 4 MiB of it are stale are the whole huge pages among them
  dropped (and refaulted) instead of zeroed.
- When more than 64 MiB of the pool are stale, the whole huge pages inside
  stale runs (adjacent runs merged) are dropped and the rest stays stale;
  the next drop happens at twice what is left (so a pool whose stale parts
  are all partial pages is not rescanned on every release).

So a VM's RAM keeps its huge pages and its 2 MiB stage-2 blocks, and
memory a process frees and allocates again is neither faulted in by the
host nor mapped again by KVM: it is zeroed in place. The price is host
memory: freed partial huge pages stay resident until the process ends
(a reused VM's pool is dropped whole, `boot-profile.md` §9.5) or the
64 MiB mark is passed (§7 has the RSS).

## 5. What a trap costs

### 5.1 Instruments

- **`exitcost`** (`SimShim/guest-tests/stageperf/exitcost.c`, original
  Ycode code, a Linux host tool): its own one-vCPU VM running a few
  instructions at EL1, timing one round trip per mode: an HVC that KVM
  answers itself (PSCI_VERSION, no return to user space), an HVC forwarded
  to user space (Ycode's doorbell, `vm-shim-protocol.md` §5.1) with an
  empty VMM loop, the same with the guest touching FP/SIMD after each exit,
  with `KVM_SET_SIGNAL_MASK`, in a VM with an in-kernel vGICv3, an MMIO
  store, and, without a guest, a cheap `ioctl` and a `getppid` system call.
- **`YCODE_TRAP_PEEL=<1…4>`** (diagnostics, `TrapFrame.peelLevel`): the
  trap `YCODE_TRAP_PEEL_NUMBER` (default 39, `getppid`) is answered (x0 =
  1, carry clear) at one point of `ycode-simd`'s path instead of being
  handled: 1 right after the exit (no decode), 2 after the frame is
  decoded, 3 at the start of the image's trap handler, 4 inside the kernel
  lock. `p_gcpu trap` (a `getppid` loop) then times the path up to that
  point.
- **`YCODE_HOST_PROFILE=<path>`** (diagnostics, `ckvm_hostprof_thread_start`):
  every vCPU host thread samples its own PC and frame-pointer chain on a
  CPU-time timer (`YCODE_HOST_PROFILE_US`, default 200 µs; the kernel checks
  CPU timers at its tick, so about one sample per 4 ms of CPU); the samples
  and the host's code mappings are written at exit for offline
  symbolization (`llvm-symbolizer`, `swift-demangle`).

### 5.2 Breakdown of a `getppid` (Thor, `timed.sh`, peel1, 3 processes × 7 repeats per row)

| Layer | µs | How measured |
|---|---|---|
| guest exception to the host kernel and back, KVM answering (no return to user space) | 0.72 | `exitcost kern` (pinned, n = 7: 0.718–0.746) |
| returning to user space and calling `KVM_RUN` again (vCPU state put and loaded, the system call) | 1.77 | `exitcost user` 2.49 − `kern` |
| the lazy FP/SIMD switch after each return (the shim touches FP on every resume, `YCODE_SHIM_FP_TOUCH`) | 0.17 | `user-fp` − `user`; `p_gcpu` with the touch off: −0.16 |
| guest side (EL0 `svc`, the shim's 320-byte save, `dsb`, `hvc`, restore, `eret`) and `ycode-simd`'s run loop | 0.36 | peel 1 (3.025) − `user-fp` (2.667) |
| frame decode and encode, the run loop's bookkeeping | 0.20 | peel 2 − peel 1 |
| the pool's handler call | 0.06 | peel 3 − peel 2 |
| the image's trap prologue, fast-path checks, the kernel lock's acquisition | 0.75 | peel 4 − peel 3 |
| `getppid` itself, the lock's release, the epilogue | 0.42 | full (4.451) − peel 4 |
| **total** | **4.45** | |

So 2.66 µs (60 %) is the host kernel's exit and entry, which a user-space
VMM cannot shorten; for comparison a plain `getppid` system call on the
host is 0.095 µs and an `ioctl` 0.104 µs. Of the kernel part, KVM's
in-kernel round trip is 0.72 µs and the return to user space 1.77 µs.
An in-kernel vGICv3 makes the user-space round trip 0.13–0.17 µs cheaper
(2.35–2.37 against 2.49 µs), but KVM refuses new vCPUs once a vGIC is
initialized (at the first `KVM_RUN`), and Ycode creates vCPUs as guest
threads start, so it is not used. `KVM_SET_SIGNAL_MASK` costs nothing
measurable (2.50 against 2.49 µs).

Host profile of the `getppid` loop (`YCODE_HOST_PROFILE`, build 2, 2,055
samples, 71 % inside `KVM_RUN`): of `ycode-simd`'s own time, the clock
reads of the kernel lock's hold accounting (two `clock_gettime` per
acquisition, 55–70 ns each on the Thor, whose counter register alone costs
55 ns) were 17 %, Swift reference counting 28 % (mostly the slow side-table
paths), dictionary lookups 7 %, argument arrays 5 %, exclusivity checks 5 %.

### 5.3 Changes to the path (GUEST-CPU-2, default on; no switch, the answers are unchanged)

- `TrapFrame.x` is `TrapRegisters`, 31 registers stored inline instead of
  an array: no heap buffer per decoded frame and no copy-on-write copy
  when a saved copy of the frame (the image's `arrivedFrame`, the kernel's
  `entryFrame`) shares it with the frame the handler edits.
- `ThreadContext.trapInProgress` keeps the registers inline instead of an
  8-element array; argument arrays are built directly from the registers
  (`TrapRegisters.prefixArray`).
- The run loop reads the clock once per exit, `CLOCK_MONOTONIC_COARSE`
  (8 ns instead of 69 ns), for its two millisecond diagnostics stamps
  (last exit, handler start).
- The image's trap prologue no longer builds the thread's trace tag string
  on every trap of a non-main thread.

Result (peel2, the same method, GCPU against GCPUB = before):

| Point | Before (µs) | After (µs) |
|---|---|---|
| peel 1 | 3.03 | 2.95 |
| peel 2 | 3.23 | 3.01 |
| peel 3 | 3.28 | 3.07 |
| peel 4 | 4.03 | 3.66 |
| full `getppid` | 4.42 (4.40–4.45) | 4.14 (4.13–4.15) |
| full, FP touch off | 4.26 | 3.96 |

−0.28 µs (−6 %) per trap. What remains in `ycode-simd` is about 1.2 µs
per trap, spread over the kernel lock (with its two clock reads), Swift
reference counting and the general dispatch.

## 6. Which traps a boot makes

### 6.1 The census

`YCODE_BOOT_PROFILE_TRAPS=1` counts every trap that reaches the image's
trap handler (fast paths included) by number and, since GUEST-CPU-2,
splits chosen traps by argument (`# arg` lines: the sysctl MIB or name,
the `proc_info` call and flavor, the `madvise` advice, the
`mach_vm_protect` protection, the `fcntl` command). Three boots, the
area's device at its own path, each to 20 s after the home screen:
census-1 (GCPUB, before §6.2; home 43.2 s, started under load), census-2
(`madvise`/`issetugid` answered in the library; home 36.7 s), census-3
(all of §6.2; home 38.4 s):

| Trap | census-1 | % | census-2 | census-3 | Note |
|---|---|---|---|---|---|
| all traps | 5,196,000 | 100 | 4,197,000 | 3,931,000 | |
| 75 `madvise` | 659,225 | 12.7 | — | — | advice 7/8 (libmalloc's reusable pairs); §6.2 |
| 375 `kevent_id` | 551,728 | 10.6 | 422,233 | 406,610 | |
| 368 `workq_kernreturn` | 448,318 | 8.6 | 348,897 | 326,956 | |
| −47 `mach_msg2` | 402,393 | 7.7 | 336,075 | 332,138 | |
| 336 `proc_info` | 290,494 | 5.6 | 259,681 | 250,393 | 196,809–216,757 of them DIRTYCONTROL SET on the caller (XPC transactions); §8 |
| −14 `mach_vm_protect` | 283,009 | 5.4 | 270,662 | 280,886 | read-only / read-write toggles (about 140,000 each) |
| 202 `sysctl` | 247,653 | 4.8 | 218,622 | 8,313 | name-to-OID (109,428 in census-2) and `kern.boottime` (105,493): libc's `sysctlbyname`, also behind `clock_gettime(CLOCK_MONOTONIC)`; §6.2 |
| 338 `stat64` | 219,957 | 4.2 | 208,693 | 216,084 | 81–83 % before the libSystem milestone (the loader) |
| 5 `open` | 214,457 | 4.1 | 202,364 | 205,490 | |
| −10 / −12 `mach_vm_allocate` / `deallocate` | 374,965 | 7.2 | 379,034 | 395,767 | mostly before the milestone |
| 3 `read` | 153,933 | 3.0 | 140,067 | 140,843 | |
| 92 `fcntl` | 129,111 | 2.5 | 106,436 | 87,561 | `F_OFD_SETLK` (90) 39,000–57,000, `F_GETPATH` (50) 32,000 |
| 327 `issetugid` | (tail) | | 23,374 | — | §6.2 |

The counts depend on how long each boot ran and on the load; the rows
that §6.2 removes are the ones that went to zero.

### 6.2 Calls answered in the library (GUEST-CPU-2; `fast-traps.md` §5a)

- `madvise` advice 0…10 and invalid advice, and `issetugid`: the kernel's
  answer is fixed, so the library gives it (`YCODE_LOCAL_CALLS`, default
  on). 3 ns instead of 3.4 µs.
- `sysctl` name-to-OID and `kern.boottime`: the library keeps the first
  answer (`YCODE_SYSCTL_CACHE`, default on). `sysctlbyname("kern.boottime")`
  30 ns instead of 10.7 µs; with it the guest's
  `clock_gettime(CLOCK_MONOTONIC)` no longer traps.

Together about 0.9 M traps per boot (17 % of census-1's).

## 7. Results (Thor, 2026-10-27, `timed.sh`)

### 7.1 Benchmarks: native against guest, before and after

`p_gcpu` (bench4: 3 processes per arm, each the median of 5 repeats;
spread of the 3 in parentheses where it matters). Before = branch state
after GUEST-CPU (GCPUB); after = with this agent's defaults (GCPU); keep =
after plus `YCODE_POOL_KEEP_THP=1`. Native from §2. Ratio: guest / native
4K.

| Workload | Unit | Native THP | Native 4K | Guest before | Guest after | Guest keep | Ratio before → keep |
|---|---|---|---|---|---|---|---|
| alu | ns/it | 1.16 | 1.15 | 1.155 | 1.154 | 1.155 | 1.00 → 1.00 |
| tlb16k 512 pages | ns/hop | 2.15 | 3.85 | 5.03 | 4.46 | 3.85 | 1.31 → 1.00 |
| tlb16k 8,192 pages | ns/hop | 4.65 | 14.7 | 19.8 (19.6–19.8) | 19.7 | 16.4 (16.2–16.6) | 1.35 → 1.11 |
| tlb16k 32,768 pages | ns/hop | 8.78 | 13.9 | 20.6 | 20.0 | 12.7 (12.7–12.8) | 1.48 → 0.91 |
| tlb4k 8,192 pages | ns/hop | 4.72 | 12.4 | 19.5 | 19.5 | 6.67 | 1.57 → 0.54 |
| hash lookup 64 MiB | ns/op | 35.9 | 38.7 | 39.9 | 40.8 | 38.0 | 1.03 → 0.98 |
| `memcpy` 512 KiB | GB/s | — | — | 33.9 | 31.4 | 58.5 | |
| fresh memory: map, touch each 4 KiB, unmap | µs/16 KiB | 0.29 | 5.7 | 11.3 | 11.3 | **0.357** | 2.0 → 0.06 |
| the same pages touched again | ns/16 KiB | 31.7 | 58.6 | 103 | 96 | 44.9 | 1.75 → 0.77 |
| library `strcmp` (§4.4) | ns/cmp | 3.66 | 3.66 | 5.79 | 5.79 | 5.78 | 1.58 |
| `getppid` (a trap) | µs | 0.094 | 0.093 | 4.42 (4.42–4.43) | 4.15 (4.15–4.16) | 4.14 | 47 → 44 |
| `sysctlbyname("kern.boottime")` | µs | — | — | 10.7 | 0.030 | | |
| `madvise(MADV_FREE_REUSABLE)` | µs | — | — | 3.4 | 0.003 | | |
| open + mmap + munmap + close (timing includes one clock call) | µs | 20.9 | 21.4 | 91.5 | 46.9 | 46.8 | |
| touch each 16 KiB of 600 files (one clock call per file) | ns/16 KiB | — | — | 702 | 69 | 69 | |
| file, first touch of each 4 KiB (stage-2 fault) | ns/4 KiB | 294 | 294 | 1,977 | 1,977 | 1,962 | 6.7 |
| `stat` of a file | µs | 0.99 | 1.13 | 12.4 | 12.3 | 12.3 | 11 |
| churn: 2,048-page chase while another thread maps and unmaps | ns/hop | 3.31 | 5.36 | 5.73 | 5.78 | 5.66 | 1.07 |
| uncontended `pthread_mutex` lock+unlock | ns | 5.82 | 5.80 | 19.3 | 19.3 | 19.3 | 3.3 |

The last two `files` rows changed because the guest's clock call no
longer traps (§6.2), not because files got cheaper; the per-file work is
the same. Unchanged by design: plain code (ALU, caches, branches, atomics,
clock reads) was already at native speed (§2).

### 7.2 Boots to the home screen and the first Settings launch

The area's device (`ide-remote/gcpu/dev`, booted before at its own path),
cold boots with `YCODE_HOME_WATCH` (b4: 4 rounds, b5: 4 rounds, l5: 3
rounds with `ylaunch open com.apple.Preferences` 20 s after the home
screen; arms rotating each round; each series under one `timed.sh`; load
when a series started below 4, during it 11–29 from the boots themselves):

| Arm | Boots | home_s median (range), mean | ycode-simd CPU at home, s, median (range) | Settings open request, ms (l5) |
|---|---|---|---|---|
| before (GCPUB) | 11 | 32.54 (31.31–40.23), 33.72 | 302 (286–331) | 2,730, 1,016, 671 |
| after (GCPU defaults) | 11 | 32.45 (31.47–37.38), 33.51 | 302 (284–335) | 3,435, 615, 1,756 |
| after, §6.2 switches off (`YCODE_LOCAL_CALLS=0 YCODE_SYSCTL_CACHE=0`) | 4 | 31.79 (31.61–35.03), 32.55 | 293 (282–307) | |
| after + `YCODE_POOL_KEEP_THP=1` | 11 | 32.33 (31.45–35.17), 32.80 | 293 (287–312) | 2,391, 829, 1,214 |

No arm changes the time to the home screen beyond the boots' own spread
(31.3–40 s, partly bimodal: about 32 or about 35 s). The boot's critical
path is SpringBoard's own guest code and kernel-lock waits
(`boot-profile.md` §8.3), and its guest code is not bound by translation
(§3.5); the 0.9 M traps fewer and 0.28 µs less per remaining trap are
about 5 s of host CPU of the 290–300 s a boot spends, inside the CPU
measurement's spread. `YCODE_POOL_KEEP_THP` has the lowest CPU median and
the narrowest home range of the arms; the open request of the first
Settings launch (ylaunch's spawn to FrontBoard's answer) varies 0.6–3.4 s
within every arm.

Host memory (mem1, `smapwatch.sh` at the home screen, 2 boots each): the
anonymous pools held 981 MiB (612 MiB in huge pages) by default and
1,625–1,697 MiB (99 % in huge pages) with `YCODE_POOL_KEEP_THP=1`:
+650–720 MiB at the home screen, the price of §4.6.

### 7.3 Defaults

- §5.3 (allocation-free trap frames and the rest): on, no switch (the
  answers are unchanged).
- §6.2 `YCODE_LOCAL_CALLS`, `YCODE_SYSCTL_CACHE`: on (`=0` off); they
  answer exactly as the kernel does (`fast-traps.md` §5a).
- `YCODE_POOL_KEEP_THP`: off. It makes recycled guest memory 30× cheaper
  and TLB-heavy access 1.2–3× faster, costs about 0.7 GiB of host memory
  per booted device and does not shorten a boot measurably; the owner
  decides whether to trade the memory.

## 8. Open items

- **The kernel's exit and entry (2.5–2.7 µs of 4.1 µs per trap)** cannot
  be shortened from user space. 1.8 µs of it is the return to user space
  (KVM's vCPU put and load around each `KVM_RUN`), which only a kernel
  change or fewer exits removes. The shim's FP/SIMD touch adds 0.16 µs per
  trap; it exists for hosts without the arm64 KVM SVE fix, which the Thor
  now has (`YCODE_SHIM_FP_TOUCH=0` is safe there; the default is the
  owner's call).
- **More traps the library could answer.** `proc_info` DIRTYCONTROL SET
  on the caller (217,000 a boot, XPC transactions): the dirty word would
  have to live in memory the guest library and the kernel share (a
  Ycode-private EL0-writable page registered once per image, read and
  updated atomically by the kernel for GET, TRACK and CLEAR from other
  processes, captured by snapshots). `proc_pidpath` of the caller (20,000)
  is fixed per image. `lseek` (95,000) and the `mach_vm_protect` toggles
  (270,000; read-only ↔ read-write, mostly after the milestone) are real
  kernel work but cheap in the handler (1.4 and 12 µs): their cost is the
  exit.
- **What remains in `ycode-simd` per trap (about 1.2 µs)**: the kernel
  lock's two clock reads for its hold accounting (the start hold's busy
  fraction needs them while processes are held, which is most of a boot),
  Swift reference counting on objects with side tables, exclusivity
  checks, dictionary lookups in the BSD dispatch.
- **Stage 2 for file memory**: the arena and the private window stay 4 KiB
  (page cache; `CONFIG_READ_ONLY_THP_FOR_FS` off, ext4 without large
  folios, `shmem_enabled = never`). A hugetlbfs pool or `shmem_enabled =
  advise` (both need the owner, sysctl/sysfs as root) would let a copy of
  the shared cache be block-mapped without THP's compaction; SPAWN's hot
  chunk copy (`YCODE_ARENA_HUGE=hot`) is the user-space way and measured
  no gain (`boot-profile.md` §9.3). §3.5 says why: the boot's guest code
  is not bound by translation.
- **Guest stage-1 blocks or the contiguous hint** (16 KiB granule: 128
  entries = 2 MiB) for large GPA-contiguous runs would widen TLB entries
  where stage 2 is a block too; not done, for the same reason.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Benchmark method (§1) | 3 | Ycode's own programs on the Thor, native and under `ycode-simd --exec` |
| Two-stage walk, combined TLB entry size, faults not cached, TLBI by VA (§3.1, §4.1) | 1 | Arm Architecture Reference Manual (VMSA, TLB maintenance) |
| Stage-2 block conditions, THP split on partial `MADV_DONTNEED`, MMU notifier, vGIC and vCPU creation, `last_vcpu_ran` (§3.2–§3.4, §5.2) | 1 | Linux 6.8 source (`arch/arm64/kvm/mmu.c`, `arch/arm64/kvm/arm.c`, `mm/huge_memory.c`, `mm/madvise.c`) and the KVM API documentation |
| Host settings (THP, defrag, shmem, kernel) | 3 | `/sys/kernel/mm/transparent_hugepage/*`, `uname` on the Thor |
| §3.5 whole-boot PMU counts | 3 | `pmustat -g -s 1` around `ycode-simd` boots (tlb1) |
| §5 exit costs, peel breakdown, host profile | 3 | `exitcost`, `YCODE_TRAP_PEEL`, `YCODE_HOST_PROFILE` on the Thor (peel1, peel2) |
| §6 census | 3 | `YCODE_BOOT_PROFILE_TRAPS=1` boots census-1/-2/-3 |
| §7 results | 3 | bench4, b4, b5, l5, mem1 on the Thor (`ide-remote/gcpu`) |
| Darwin call semantics (`sysctl` name-to-OID, `kern.boottime`, `proc_info` callnums and flavors, `fcntl` commands, `madvise` advice) | 1 | xnu open source (`bsd/kern/kern_sysctl.c`, `bsd/sys/proc_info.h`, `bsd/sys/fcntl.h`, `bsd/sys/mman.h`) |
| The guest's `clock_gettime(CLOCK_MONOTONIC)` asks `sysctl` for `kern.boottime` (§2 note, §6.2) | 3 | `p_gcpu files` with and without `YCODE_SYSCTL_CACHE` (690 → 69 ns per 16 KiB, `map_unmap` 90 → 47 µs: one clock call per file) and the census's 105,000 `kern.boottime` reads |

Level 5 was not used. The reference tools, `research/` and Ghidra were not
opened; Apple's Xcode and Simulator were not run.
