# Postmortem: lost writes in ycode-simd (host KVM SVE bug)

Status: closed 2026-10-13. Root cause: a Linux host-kernel bug in KVM's
handling of the VMM thread's SVE state, fixed upstream by commit
fbc7e61195e2. Ycode carries two mitigations so it also runs correctly on
hosts that lack the fix.

## 1. Summary

ycode-simd, the VMM that runs the iOS simulator runtime in KVM micro-VMs on
the Thor (arm64 Linux, kernel 6.8.12-tegra), crashed in most device runs:
about 4 of 10 release runs and more than 95% of debug runs. The crashes were
in our own Swift code and looked like memory corruption, but nothing was
corrupted in the usual sense. A copy that a thread made into its own memory
sometimes did not happen at all, or happened only in part.

The cause: after a `KVM_RUN` in which the guest did not use FP/SIMD, the
kernel let the VMM thread keep using SVE instructions but stopped saving
its SVE predicate registers. At the next preemption the predicates were
lost (they came back as zero). glibc's SVE `memcpy`/`memmove` use predicated
loads and stores, and a predicated store with an all-false predicate stores
nothing. So a copy of a few dozen bytes could silently do nothing.

## 2. Symptoms

All crash sites were on vCPU host threads, in code that ran after a
`KVM_RUN` returned (the trap handler). One crash was on the main thread,
in data that a vCPU thread had copied earlier.

| Symptom | Example |
|---|---|
| Interval-map element differs from its tree node | element `[0xffabf789e750, 0xaaaacaedffac)`, node `[0x100004c000, 0x1000050000)` |
| Torn element | correct start, end from a different element |
| Absurd sizes and counts | "failed to allocate 281240145878896 bytes" (a stack address used as a count) |
| Collection traps | "Index out of bounds", "count differed in successive traversals" |
| Wild pointers | `swift_retain` on `0x1000faeb88` (a guest physical address) |

The values that appeared were always plausible old data: frame records
(a saved frame pointer and return address) or values from earlier
operations at the same stack depth. In the debugger, the temporary that a
generic getter had to fill still held what an earlier call had left there.
The heap copy of the data was always correct.

## 3. Timeline of hypotheses

Every hypothesis was tested by changing one thing and measuring the crash
rate over several runs. A single run proves little at these rates.

| # | Hypothesis | Experiment | Result | Verdict |
|---|---|---|---|---|
| 1 | Data race in the Darwin-kernel layer (lock not held) | hold the kernel lock for the whole trap (`YCODE_DEBUG_NO_UNLOCK`) | release 6/10 crashed | not it |
| 2 | Foundation path code is not thread-safe | remove Foundation from the path code, then byte-based paths | 2/10, then 1/10 | rate fell (less copying), still crashed |
| 3 | `inout` access across a wait | unoptimized build, exclusivity checks on and off | debug 95%+, exclusivity off 5/5 | not it |
| 4 | Heap use-after-free | never-reuse allocator (bumpmalloc), quarantine with fill check (qmalloc) | 3/3 and 2/3 crashed, 0 reports | not it |
| 5 | Compiler bug | second toolchain, Swift 6.3.3 | 4/5 | not it |
| 6 | Signals (vCPU kicks) interrupt code at a bad point | no kicks at pool end; log every kick in user code; block kicks outside `KVM_RUN` | 3/5; 0 kicks seen in user code; 4/4 | not it |
| 7 | Transparent huge pages, page migration | `PR_SET_THP_DISABLE`; `pgmigrate_success` | 6/6; counter unchanged | not it |
| 8 | Use of freed guest memory after VM close | keep VMs open (`YCODE_DEBUG_NO_VM_CLOSE`) | 5/6 | not it |
| 9 | Generic-metadata problem in unoptimized Swift | non-generic copy of the interval map | 5/5 (torn elements) | not it |
| 10 | A wild write from another thread | hardware watchpoints, read-only element pages; ask whose stack holds the value | heap intact; the value was on the reading thread's own stack | changed the question |
| 11 | Another thread's stack, or a stack clash | `pthread_getattr_np` in the report | own stack, same offset each time | not it |
| 12 | Kernel loses registers across `KVM_RUN` | fpcheck: v0..v31, p0..p15, x1..x30, SP, NZCV, system registers, with kicks and preemption | 0 in 10M to 42M runs each | not it, but a blind spot (see 4) |
| 13 | Lost writes on any thread | C threads write and verify 64 KB of stack and heap (`YCODE_DEBUG_MEMCHECK`) | 0 lost, all 3 runs crashed | not it, and a clue |
| 14 | CPU migration / cache coherence | `taskset` to 1 CPU, 2 CPUs | 3/3, 1/2 | not it |
| 15 | Reader overlaps a writer on a map | reader/writer guard (`YCODE_DEBUG_RW_GUARD`) | 0 traps in 8 runs | not it |
| 16 | SP, FP, LR, x18, NZCV changed by `KVM_RUN` | check them and 4 KiB of caller frames around every `KVM_RUN` | 4/4 crashed, 0 reports | not it |
| 17 | The guest's FP use matters | fpcheck with a guest that never touches FP | 149,873 of 21.3M runs lost predicates | **the bug** |

Hypothesis 12 had passed because every fpcheck guest used FP registers
(fmov) on every run. That forced the kernel onto its correct path. The
ycode-simd guest exits to the VMM through the shim's doorbell store, often
without any FP access in that run. As soon as the test guest stopped using
FP, the failure rate went from 0 to about 0.7% of runs.

Hypothesis 13 was the clue that was easy to miss: plain C code on threads
that never call `KVM_RUN` and never use SVE lost nothing.

## 4. Why the usual tools missed it

| Tool | What it sees | Why it was blind here |
|---|---|---|
| AddressSanitizer | accesses to invalid or freed memory | every address was valid; the bad store was a store that did not happen, inside glibc |
| ThreadSanitizer | unsynchronized accesses from two threads | one thread lost its own write; there was no second thread |
| Quarantine allocators (qmalloc, bumpmalloc) | writes to freed blocks | nothing was freed |
| Hardware watchpoints, read-only pages | writes to a watched address | the failure was a missing write |
| Lock and exclusivity checks | overlapping accesses | there was no overlap |
| Register tests across `KVM_RUN` | registers changed by the system call | the predicates were lost later, at a preemption, and only after a run without guest FP |

Each tool answers one question. When all of them say "no", the failure is
outside what they can observe: here, the CPU state that the kernel restores
for user mode.

## 5. Mechanism

Arm SVE adds predicate registers (p0..p15) that select which vector lanes an
instruction uses. glibc on SVE hosts selects `__memcpy_sve` and
`__memmove_sve` by IFUNC. For small copies they build a predicate with
`whilelo` and then use a predicated load and store (`ld1b`/`st1b`). If the
predicate is all false, the store writes nothing, and no fault occurs.

Linux tracks a thread's FP state with the `TIF_SVE` flag (the thread's SVE
state is live and must be saved in full) and controls user access to SVE
with `CPACR_EL1.ZEN`. The invariant is: SVE enabled for user mode only when
`TIF_SVE` is set. While SVE is disabled, the first SVE instruction traps,
and the kernel sets `TIF_SVE`.

In the affected kernels the sequence on a VMM thread was:

1. The thread uses SVE (for example, glibc `memcpy`), so `TIF_SVE` is set.
2. It calls `KVM_RUN`. On vCPU load, KVM converts the thread's state to
   FPSIMD-only and clears `TIF_SVE`.
3. The guest does not touch FP/SIMD during this run, so KVM never takes over
   the FP registers. On vCPU put, KVM restores `CPACR_EL1.ZEN` to the value
   it saw on entry: SVE enabled.
4. Back in user mode, the thread runs SVE code without a trap, but
   `TIF_SVE` is clear.
5. At the next context switch the kernel saves only the FPSIMD state.
   The predicates are not saved; after the switch they read as zero.
6. A `memcpy` that was between its `whilelo` and its `st1b` stores nothing.

With a 128-bit vector length (the Thor), the Z registers are the same as the
V registers, which the kernel does save. That is why only predicate-based
code failed, and why every V-register test passed.

Upstream fix: commit fbc7e61195e2, "KVM: arm64: Unconditionally save+flush
host FPSIMD/SVE/SME state" (Mark Rutland, 2025). Its message names "host SVE
being discarded unexpectedly due to inconsistent configuration of TIF_SVE
and CPACR_ELx.ZEN" and cites QEMU crashing in an SVE `memmove`. It was
backported to the 5.15, 6.1, 6.6, 6.12 and 6.13 stable series, not to 6.8.

## 6. Reproducer

Source: `research/experiments/linux-host/kvm-sve/fpcheck.c` (our own code;
the working copy is `qtest/` under `$YCODE_DATA/work/7-I3`
on the Thor).

```
cc -O2 -march=armv8.2-a+sve -o fpcheck fpcheck.c -lpthread
GUEST_NOFP=1 ./fpcheck 48 30 kvm kick kvmpred   # predicates
GUEST_NOFP=1 ./fpcheck 48 30 kvm kick memcpy    # glibc copies
```

Results on the Thor, 48 threads on 14 CPUs, 30 s:

| Kernel | Test | Guest | Result |
|---|---|---|---|
| 6.8.12-tegra | predicates | no FP | 149,873 of 21.3M runs (495,518 of 21.6M in a second run) |
| 6.8.12-tegra | predicates | FP every run | 0 of 21.6M |
| 6.8.12-tegra | predicates, `sched_yield` instead of `KVM_RUN` | none | 0 of 31.6M |
| 6.8.12-tegra | glibc memcpy/memmove, 17..96 bytes | no FP | 4,038 copies stored nothing |
| 6.8.12-tegra | glibc memcpy/memmove | FP every run | 0 |
| patched | predicates | no FP | 0 of 21.7M |
| patched | glibc memcpy/memmove | no FP | 0 of 4.8G copies |

## 7. Mitigations in Ycode

Both are on by default and cost little, so Ycode stays correct on hosts
without the kernel fix.

1. **No SVE in `memcpy`/`memmove`** (`ycode/Sources/CKVM/hostcopy.c`).
   ycode-simd defines AdvSIMD-only `memcpy` and `memmove`. The executable
   exports them, so the dynamic linker binds them ahead of glibc's for the
   whole process, Swift runtime included. glibc's only SVE routines on this
   CPU are those two; libswiftCore contains no SVE instructions.
   `movetest.c` checks 169,764 size and overlap cases. With hostcopy linked
   into fpcheck: 0 lost copies in 6.7G. `YCODE_LIBC_MEMCPY=1` switches back
   to glibc for tests.
2. **The shim touches FP on every resume** (`SimShim/shim.S`, resumeFlags
   bit 1, `VCPUPool.shimFPTouch`). Before it returns to the guest, the EL1
   shim reads FPCR. That is an FP access that changes no state, so KVM
   loads the FP registers for the vCPU in that run and takes its correct
   path. This also protects SVE code other than `memcpy` (drivers, other
   libraries) that runs on vCPU threads. Cost: 0.22 µs per `KVM_RUN`
   (2.75 to 2.97 µs for a bare MMIO round trip); a ycode-simd trap round
   trip takes tens of µs. Residual: 1 in 21.5M runs, from runs that return
   before the guest reaches the FP access (a kick or an immediate exit).
   `YCODE_SHIM_FP_TOUCH=0` turns it off. The flag is documented in
   `specs/simulator/stage3-contract.md` section 7.

## 8. Results

Install and launch device runs, `--debug-no-metal --skip-first-boot-migration`:

| Kernel | Build | Mitigations | Runs crashed |
|---|---|---|---|
| 6.8.12-tegra | debug | none | 3/3 (7/8 earlier the same day) |
| 6.8.12-tegra | debug | hostcopy | 0/6 |
| 6.8.12-tegra | debug | FP touch | 0/4 |
| 6.8.12-tegra | debug | both | 0/4 |
| patched | debug | none | 0/5 |
| patched | release | none | 0/13 |
| patched | release | both | 0/3 |

The owner installed a kernel with the upstream fix series on 2026-10-12
(`uname -v`: "#1 SMP PREEMPT Mon Oct 12 22:00:00 EDT 2026"). The kernel fix
alone removes the crash.

## 9. Lessons

- **Measure rates, not single runs.** At 40% to 95% failure, one passing run
  means nothing. Each change was judged over 3 to 10 runs against a control
  run of the same binary on the same day.
- **Make each hypothesis falsifiable.** Each row in section 3 names an
  experiment that could disprove it. Most did, and that narrowed the search.
- **Know what each tool cannot see.** The sanitizers and watchpoints look
  for bad accesses. A write that does not happen is invisible to all of
  them.
- **Question the test's assumptions.** The register test was correct but
  its guest always used FP. The difference between the test and the real
  workload was the bug.
- **Move the failure out of the big system.** Once a 400-line C program
  failed in seconds, the cause was certain and the fix could be measured
  directly, not through crash rates.
- **Look at what the bad values are.** "A frame record from an earlier call
  at the same depth" meant old data that should have been overwritten, not
  random corruption. That pointed to a lost store.
- **The platform can be wrong.** Kernel, firmware and C library are code
  too. When every check of our own code passes, test the layer below.

## Evidence

All claims come from our own experiments on the Thor (level 3, black-box
behavior of the Linux host) and from public Linux and glibc behavior and the
public upstream commit (level 1). No Apple code or binary was involved.
