# Postmortem: lost writes in ycode-simd on the Thor (host KVM SVE bug)

Status: **resolved 2026-10-12.** The bug was in the Thor's host kernel, not in
Ycode. The fix was a patched host kernel. Ycode also has two mitigations,
both on by default.

## Summary

About one long device boot in three died inside `ycode-simd`, the Swift VMM
that runs every guest process on the Thor (NVIDIA Thor, arm64,
Ubuntu 24.04, L4T R38.2.2, kernel `6.8.12-tegra`). The crashes looked like
heap corruption. Debug builds crashed in almost every run.

The cause: on this kernel, after a `KVM_RUN` in which the guest did not use
FP/SIMD, the host thread could keep running SVE code while the kernel no
longer treated its SVE state as live. At the thread's next preemption the
SVE **predicate registers** were not saved and came back as zero. glibc's
`memcpy`/`memmove` use predicated SVE stores (`whilelo` + `st1b`) for copies
of about 17–96 bytes. With an all-false predicate those stores write
**nothing**, and no fault is raised. A copy that silently does nothing
explains every symptom we saw.

Upstream fixed it in Linux commit `fbc7e61195e2` "KVM: arm64:
Unconditionally save+flush host FPSIMD/SVE/SME state" (Mark Rutland, 2025).
The fix was backported to the 5.15, 6.1, 6.6, 6.12 and 6.13 stable kernels,
but not to 6.8, the kernel NVIDIA ships for the Thor.

## Symptoms

- Swift runtime traps: "Index out of range", "count differed in successive
  traversals", allocations of absurd sizes.
- Pointers made of text: a pointer field holding `0x0065736976646185`, the
  bytes of part of the string "madvise".
- Interval-map elements whose start came from one entry and whose end came
  from another ("torn" elements), while the copy in the heap was correct.
- A function's result read back as stale stack contents, for example a
  frame record `{x29, x30}` left by an earlier call at the same stack depth.
- Always on a **vCPU host thread**, right after a KVM exit.
- Rates: release about 1 in 3 long boots; debug (`-Onone`) about 12 in 13.

## Timeline of hypotheses

Each hypothesis came with an experiment that could rule it out. Rates are
crashed runs out of runs.

| # | Hypothesis | Experiment | Result |
|---|---|---|---|
| 1 | Data race on a lazily filled path cache | TSan; a lock-protected cache | A **real race**, fixed. The crash remained. |
| A | Process exit tears down state while a sibling thread is in unlocked host file I/O | Hold the kernel lock across file I/O (`YCODE_DEBUG_NO_UNLOCK`) | 6/10 crashed. Ruled out. |
| B | A guest-physical address used as a host pointer | Trace every pool pointer to its memslot lookup | All valid. Ruled out. |
| C | `inout` access held across a wait that drops the lock (an optimizer exclusivity assumption) | Audit all 26 wait and lock-drop sites | No such pattern. Ruled out. |
| D | `pthread_kill` kicks sent to exited threads corrupt a recycled TCB | Disable kicks (`YCODE_DEBUG_NO_KICK`) | 3/5 crashed. Ruled out. |
| — | Compiler or runtime bug | Rebuild with Swift 6.3.3 instead of 6.4 | 4/5 crashed. Ruled out. |
| — | KVM writes into freed host memory | Keep freed VM memory as inaccessible pages (`YCODE_DEBUG_QUARANTINE`) | Still crashed. Ruled out. |
| — | glibc reuses a freed block while it is still in use | LD_PRELOAD allocators: a quarantine one and a never-reuse bump one | Still crashed. Ruled out. |
| — | Reader racing a writer on the interval maps | Atomic reader/writer guard (`YCODE_DEBUG_RW_GUARD`) | 0 traps in 8 runs. The guard hid the crash (3/8 with it, 7/8 without). |
| — | Two thread stacks colliding | Check which stack holds the stale frame (`pthread_getattr_np`) | The reading thread's **own** stack. Ruled out. |
| — | SP/FP/LR/flags changed across `KVM_RUN` | In-process check (`YCODE_DEBUG_RUNCHECK`); standalone all-registers test | 0 changes in 42M. Ruled out. |
| ✔ | **Host kernel loses SVE state after `KVM_RUN`** | Standalone `fpcheck` with a guest that never touches FP | **495,518** of 21.6M runs lost predicates; **4,038** glibc copies stored nothing. With an FP-using guest: 0. Without KVM: 0. |

Two turning points:

1. **The debug build reproduced it almost every time.** A rare bug became
   a reliable one. I had predicted that `-Onone` would crash *less*; it
   crashed more, because unoptimized Swift copies far more values through
   `memcpy`.
2. **Looking at the actual bytes.** The heap data was intact. Only the value
   read was stale. "A write never happened" points at the copy itself, not
   at memory management.

## Why the usual tools missed it

- **ASan:** nothing was out of bounds and nothing was freed early. ASan also
  shifts timing and reuse enough to hide the crash.
- **TSan:** there was no data race. Accesses were ordered by our own lock.
  TSan also cannot run with the NVIDIA driver loaded, because the driver
  creates threads TSan does not register.
- **Quarantine allocators and the stack-write checker:** their own writes
  were plain stores, not predicated SVE stores. The stack checker lost
  nothing in runs that crashed.
- **Our first register test passed** because its guest always used FP,
  which takes the kernel's correct path. The bug shows only when the guest
  does **not** touch FP/SIMD during the run.

## Mechanism

Arm SVE adds scalable vector registers (`z0–z31`), **predicate registers**
(`p0–p15`, per-lane masks) and `FFR`. The kernel saves them lazily. A task
flag, `TIF_SVE`, says whether the task's SVE state is live, and
`CPACR_EL1.ZEN` decides whether user-mode SVE instructions trap.

On the unpatched 6.8 kernel:

1. Entering `KVM_RUN` clears the thread's `TIF_SVE`.
2. If the guest does not use FP/SIMD in that run, the exit path still
   leaves `CPACR_EL1.ZEN` set to "enabled".
3. Back in user space, the thread runs SVE without trapping. glibc's
   `memcpy` sets a predicate with `whilelo` and stores with `st1b`.
4. At the next context switch the kernel sees `TIF_SVE` clear and saves
   only the FPSIMD (`v0–v31`) view. The predicates are not saved, and they
   come back as zero.
5. A predicated store with an all-false predicate stores nothing, so the
   destination keeps its old bytes.

The upstream fix makes KVM save and flush the host FPSIMD/SVE/SME state
eagerly when a vCPU is loaded, so the inconsistent state can no longer
arise.

## Reproducer

`research/experiments/linux-host/kvm-sve/fpcheck.c` (our own code). Each
thread runs a tiny guest that loops on an MMIO store, so each store is one
KVM exit. The thread sets a known pattern before every `KVM_RUN` and checks
it after. `movetest.c` checks the AdvSIMD `memcpy`/`memmove` replacement
for correctness.

```
cc -O2 -o fpcheck fpcheck.c -lpthread
GUEST_NOFP=1 ./fpcheck 28 10 kvm nokick kvmpred   # predicate check, guest never uses FP
```

| Kernel | Guest | Result |
|---|---|---|
| stock 6.8.12-tegra | no FP | 38,108 of 7.7M runs lose predicates (28 threads, 10 s); 495,518 of 21.6M with 48 threads, 30 s |
| stock | uses FP | 0 |
| stock | no `KVM_RUN` (`sched_yield` control) | 0 of 31.6M |
| patched | no FP | **0 of 7.4M and 7.6M** |

## Fixes

1. **Patched host kernel.** Stock 6.8.12-tegra plus the 6.6.y stable
   backport of the fix series (8 patches), plus two local patches:
   - one marks `kvm_hyp_handle_mops` inline;
   - one keeps two now-unused `struct kvm_vcpu_arch` fields so that module
     CRCs do not change.

   It was built with NVIDIA's own toolchain from the R38.2.1 public sources.
   An unpatched build of the same tree reproduces the shipped
   `Module.symvers` byte for byte. It is installed as an extra extlinux
   entry (`svefix`); the stock kernel stays available as `primary`. Build,
   script and rollback steps: `$YCODE_DATA/work/kernel-svefix/`.
   An `apt upgrade` of `nvidia-l4t-kernel` may revert it.
2. **Ycode mitigations**, on by default, for hosts without the fix:
   - `ycode/Sources/CKVM/hostcopy.c`: AdvSIMD-only `memcpy`/`memmove`
     exported by `ycode-simd`, so they replace glibc's for the whole
     process. 0 lost in 6.7B copies; 0 failures in 169,764 size and overlap
     cases. Disable with `YCODE_LIBC_MEMCPY=1`.
   - **Shim FP touch**: the EL1 shim reads `FPCR` on every resume
     (`resumeFlags` bit 1, `specs/simulator/stage3-contract.md` §7). This
     forces KVM's lazy FP switch, so the correct save path is taken.
     Predicate losses drop to 1 in 21.5M; the residual is runs that exit
     before the guest reaches the read. Cost ≈ 0.22 µs per bare `KVM_RUN`.
     Disable with `YCODE_SHIM_FP_TOUCH=0`.

## Results after the fix

| Kernel | Build | Mitigations | Crashed |
|---|---|---|---|
| stock | debug | none | 3/3 (7/8 earlier the same day) |
| stock | debug | hostcopy only | 0/6 |
| stock | debug | FP touch only | 0/4 |
| stock | debug | both | 0/4 |
| patched | debug | none | 0/5 |
| patched | release | none | 0/13 |
| patched | release | both | 0/3 |

## Lessons

- **Measure rates, not single runs.** A 1-in-3 bug needs batches of 5–10
  runs per variant, and the variants run interleaved.
- **Write each hypothesis next to the experiment that could kill it.**
  Ten hypotheses died this way, and each death narrowed the search.
- **Ask what each tool cannot see.** ASan, TSan, quarantine allocators and
  plain-store checkers were all blind here, because the failing operation
  was a *predicated vector store* that legitimately wrote nothing.
- **Make it reproducible before attacking it.** The debug build turned a
  1-in-3 crash into an every-time crash.
- **Look at the bytes.** Classifying each corrupt value (host or guest,
  stack, heap or text) changed the direction of the hunt twice.
- **Suspect the platform last, but do suspect it.** Once every in-process
  explanation was ruled out, a 100-line standalone C program settled the
  question.

## Diagnostics kept (all off by default)

`YCODE_DEBUG_RUNCHECK`, `YCODE_DEBUG_SIGLOG`, `YCODE_KICK_ONLY_IN_RUN`,
`YCODE_DEBUG_STACK_GUARD_MB`, `YCODE_DEBUG_NO_KICK`,
`YCODE_DEBUG_NO_FILE_ARENA` / `NO_STALE` / `NO_FILE_COPY`,
`YCODE_DEBUG_QUARANTINE`, `YCODE_DEBUG_RW_GUARD`, `YCODE_DEBUG_WATCH_MAPS`,
`YCODE_DEBUG_HWWATCH`, `YCODE_DEBUG_MEMCHECK`. Each costs one flag check
when off.

## References

- Upstream commit `fbc7e61195e2`, "KVM: arm64: Unconditionally save+flush
  host FPSIMD/SVE/SME state".
- Stable backports by Mark Brown, March–April 2025: 6.13, 6.12, 6.6, 6.1
  and 5.15 series on LKML.
- Commits in this repository: `8008a16` (hostcopy and diagnostics),
  `5d1bd35` (shim FP touch), `711aab5` (release-build fix).
