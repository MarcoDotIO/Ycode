# Evaluation: open-source Mach-O loaders for arm64 Linux, as a basis for native mode

Status: evaluation, 2026-10-17. This document only evaluates and measures.
No loader, syscall-interception, or rewriting code was written for it, and
nothing under `ycode/` or `specs/` was changed. It answers one question from
`specs/simulator/native-mode.md`: can Ycode adopt or learn from an existing
project that runs Darwin arm64 Mach-O binaries as plain arm64 Linux
processes, instead of building native mode from nothing?

Host for all measurements: the Thor (arm64, Ubuntu 24.04, 6.8.12-tegra,
4 KiB pages, 14 cores). The machine is shared and was heavily loaded during
the run (load average about 22). Timed loops ran pinned to one core
(`taskset -c 2`), and same-run repeats are given. All work was done as the
normal user in a scratch directory under `$YCODE_DATA/work/`. Nothing was
installed system-wide and `sudo` was not used.

## 1. Summary

| | Kakehashi | Darling (arm64 branch) |
|---|---|---|
| Upstream | `github.com/wie-project/kakehashi` | `github.com/darlinghq/darling`, arm64 work in PR #1753 (fork branch `kkHAIKE:arm64-support`), plus about 25 sub-repository PRs |
| License | Apache-2.0 (checked: `LICENSE.txt`, `NOTICE`, `Cargo.toml`) | GPL-3.0 (checked: `LICENSE`). It also contains Apple open source under APSL-2.0 |
| Language | Rust + inline asm. 62 k lines | C/C++/ObjC, 149 git submodules |
| Status | **Unmaintained**: the README now says the author has stopped. The last commit is 2026-09-17 | The arm64 PR is open and **will not be merged as is** (a maintainer comment from 2026-07). A community fork ("VibeDarling", GPL-3.0) says it has merged the work |
| Builds on the Thor | **Yes**, in 65 s with user-local Rust 1.99 (`RUSTFLAGS=-Awarnings` was needed because the repo has `-Dwarnings` and newer rustc deprecates `fetch_update`) | **Not built yet** (§4.1). The owner has since installed the prerequisite packages, but the submodule fetch has not been done. Running needs root: either a setuid-root launcher (impossible on the `nosuid` data volume) or `sudo` for each session. It also needs mount namespaces and overlayfs |
| Runs a trivial macOS arm64 Mach-O | Yes (`printf` hello, argv, exit status) | Not run (gate above). The PR reports hello/bash/perl/python/uname working |
| Runs an iOS-simulator-platform Mach-O | **Yes**: our own `-target arm64-apple-ios27.0-simulator` builds, and two runtime tools (`tab2space` works correctly; `truncate` stops on a missing libSystem symbol) | Not run |
| Runs `dyld_sim` | **No**: SIGSEGV at entry (it treats `dyld_sim` as an executable and provides no dyld-to-`dyld_sim` handoff) | Not run. Darling uses its own dyld build, not `dyld_sim` |
| Runs our `nt_probe` | Loads with our `libsystem_kernel` in its root. **Fails check 10** (TPIDRRO_EL0 is 0) | Not run |
| Uses the Apple dyld shared cache | No (it has its own freestanding libSystem; frameworks are stubs) | No (it rebuilds libSystem and frameworks from open source) |
| Mach IPC | None (`mach_task_self` returns a soft token) | Real XNU Mach code in **one userspace server per prefix** (`darlingserver`), reached by RPC over a Unix socket |

**Recommendation in one line:** adopt neither one. Learn from Kakehashi's
guest/host boundary design, which is permissively licensed and measured
here at about 60 ns per crossing. Use Darling only as a scope and
architecture reference (it is GPL-3.0 and needs root). Neither project
solves the problem that matters most for the iOS runtime: running
*unmodified* Apple-built images that read `TPIDRRO_EL0` inline. §5 and §6
give the reasons and the expected gains.

## 2. Measurements

Test programs were built on the Mac with the public toolchain
(`xcrun clang -target arm64-apple-macos14.0` and
`-target arm64-apple-ios27.0-simulator`). They were scratch programs and are
not in the repository. `evb` times the same three calls as `nt_probe`
(library `getppid`, a raw in-binary `svc #0x80` `getppid` with `x16 = 39`,
and `mach_absolute_time`), but without `nt_probe`'s contract checks, so
that it can run on loaders that do not meet the contract. `nt_probe` itself
was built unchanged from `ycode/Native/guest/nt_probe.c` against Ycode's
Linux-built `libsystem_kernel.dylib`.

### 2.1 Per-call cost (ns per call, Thor, one pinned core)

| Call | Native Linux (glibc, same host) | Kakehashi, macOS-platform binary (3 runs) | Kakehashi, iOS-sim-platform binary | macOS native (Mac, reference only) |
|---|---|---|---|---|
| library `getppid` | 95.1, 93.1, 93.4 | 151.9, 151.2, 153.3 | 152.9 | 97.5 |
| raw `svc` `getppid` | 90.4, 91.1, 90.7 (`svc #0`) | 1182.5, 1160.4, 1164.3 | 1166.7 | 92.0 |
| `mach_absolute_time` | 68.7 (`clock_gettime`, vDSO) | 123.8, 123.9, 127.4 | 124.1 | 5.0 (commpage) |

Readings:

- **Kakehashi boundary crossing ≈ 58–60 ns.** Its library call is a
  `blr` into a host entry. The entry saves Q0–Q31 and FPCR/FPSR, swaps
  `TPIDR_EL0` from guest TLS to host TLS, switches to a per-thread host
  stack, dispatches in Rust, and returns. The call then makes the real Linux
  `getppid`. 152 − 93 ≈ 59 ns is the cost of the crossing itself.
- **Kakehashi stray-`svc` path ≈ 1.17 µs.** At load time it rewrites every
  `svc` in the instruction sections to `brk #0xF00`. `SIGTRAP` then
  delivers the call to a handler. This is the best stand-in we have for the
  per-call cost of native mode's seccomp `SIGSYS` path (spec §6), which was
  only estimated as "1–few µs". The same signal-delivery mechanism lands
  at the low end of that range.
- **`mach_absolute_time` should not cross at all.** On macOS it is a
  user-space commpage/counter read (5 ns). Kakehashi sends it through the
  hypercall and `clock_gettime` (124 ns). On this host `clock_gettime`
  alone costs 69 ns.
- The iOS-simulator platform tag makes no difference to Kakehashi (it does
  not check `LC_BUILD_VERSION`).

### 2.2 Against Ycode's KVM path

| Path | Cost per call | Source |
|---|---|---|
| Bare KVM MMIO doorbell exit | 2,754–2,767 ns | `native-mode.md` §8.2 |
| Bare KVM forwarded-HVC exit | 2,521–2,532 ns | `native-mode.md` §8.2 |
| Full `ycode-simd` trap (exit + dispatcher + global lock) | ≈ 32 µs at stage 2. In the boot profile, an average of ≈ 26.5 µs of lock hold per trap (370 s / 13.94 M traps) | `docs/SIMULATOR-LINUX.md`, `native-mode.md` §1 |
| In-process boundary (Kakehashi-style) | ≈ 60 ns + the real work | this document |
| Signal-based stray-`svc` (Kakehashi `brk`/`SIGTRAP`) | ≈ 1,170 ns, including a 90 ns Linux syscall | this document |
| Cross-process RPC over a Unix `SOCK_SEQPACKET` pair (a Darling-style or broker-style Mach trap), 64 bytes | 3,376 / 3,803 ns with both processes on one core; 20,741 / 19,870 ns across cores (loaded host, includes wake-up latency) | this document, `rpc_rt` |

Per-syscall gain, if native mode reaches Kakehashi's crossing cost:

- **A process-local call through our libraries:** ≈ 60 ns of boundary
  against a bare 2.5–2.8 µs exit, about **40–45×** on the crossing alone.
  Against the full trap as profiled (≈ 26–32 µs, mostly lock), about
  **150–500×** per call. In practice the gain is bounded by the work the
  call does (for `getppid`, 152 ns in total).
- **A stray `svc` (seccomp or `brk` signal):** ≈ 1.2 µs, only about
  **2×** better than a bare HVC exit, but still more than 20× better than
  the full trap, because the global lock is not involved. These calls must
  stay rare.
- **Cross-process Mach traffic through a broker:** 3.4 µs (same core) to
  about 20 µs (cross core, with wake-up). This is **no faster than a KVM
  exit, and can be slower.** The win from native mode comes from (a)
  turning process-local calls into function calls and (b) removing the
  single global lock. It does not come from cross-task IPC. A shared-memory
  port table with futex wake-ups (`native-mode.md` §7, option 2) is
  the only way to make cross-task messages cheaper than an exit.

## 3. Kakehashi in detail

What it is: a single host binary, `kh`. It parses and maps a Mach-O
executable and its dylibs, binds symbols against its **own freestanding
`libSystem.B.dylib`** (built with `aarch64-apple-darwin` Rust on a Mac and
shipped prebuilt in the repo, 400 KB), and jumps to `LC_MAIN`. Guest code
runs natively. The runtime runs only at its hypercall, at thread
create/exit, and at faults. There is no JIT, no VM, no kernel module, no
seccomp, and no ptrace. It verifies 7-Zip, curl, Apple git, and Apple clang
from the macOS command-line tools. The author's own updated figure for
multi-file 7-Zip is about **1.24×** native Linux. The often-quoted 5.2×
was an old allocator problem, and the README now says it was fixed. We did
not reproduce either figure, because both need Apple-built tools in its
root.

How it handles each native-mode blocker:

| Blocker (`native-mode.md`) | Kakehashi |
|---|---|
| `TPIDRRO_EL0` zeroed by Linux | **Not handled.** Measured: guest `mrs TPIDRRO_EL0` reads 0. It does not need the register, because its libSystem is its own and keeps TSD elsewhere. Any Apple-built image that inlines the read would fail |
| `TPIDR_EL0` | Guest TLS lives here: a block holding magic, errno, `pthread_self`, the saved host TPIDR, and the alt-stack top. The entry swaps in the host TPIDR before any Rust/glibc code runs, and swaps it back on return. A Darwin CPU-number read returns a pointer (measured 0x0000ffff…), not a small index |
| Stray `svc #0x80` | **Load-time rewrite** of every `svc` in instruction sections to `brk`, then a `SIGTRAP` handler (≈ 1.17 µs per call). The guest may not install its own `SIGTRAP` handler (EPERM) |
| 16 KiB guest on a 4 KiB host | Maps at host-page multiples with 16 KiB guest alignment (`--guest-page-size` 4096/16384). Works on the Thor |
| Fixed Darwin layout | Only partly. The main image goes to its preferred 0x1_0000_0000 and `__PAGEZERO` is never materialised. Dylibs, `dyld_sim`, and stacks land at high Linux VAs (0xffff_…), above 2^47. There is **no commpage**: a read of 0xF_FFFF_C000 faults |
| `x18` | Saved and restored around its thin syscall veneer. `setjmp` saves it |
| Red zone / signals | The hypercall dispatches on a per-thread host alt stack. Fault and trap handlers use `SA_ONSTACK` |
| dyld / shared cache | Its own loader replaces dyld. There is no shared cache. Symbols that live in the macOS cache are aliased to its libSystem |
| Threads | 1:1 host threads (`bsdthread_create` → `std::thread`). Its architecture notes list hard-won invariants: exit workers with raw `SYS_exit`, not `pthread_exit` (glibc's unwinder walks the guest `x29`); never run host code under guest TPIDR; save NEON fully before any host `bl` |
| Mach IPC / launchd | **None.** It has no ports, messages, or bootstrap. The iOS runtime's `notifyutil` printed nothing; `defaults` stops at `objc_alloc_init`; `log` stops at `sandbox_check` |
| Processes | One `kh` host process per guest process; `fork`/`execve`/`wait4` are implemented. A guest `execve` re-enters `kh` |
| Signals → Mach exceptions | Not modelled. Faults print diagnostics and exit with 128+signo |

Gaps for iOS-simulator processes: no Mach IPC, no bootstrap, no
`dyld_sim` handoff, no shared cache, no commpage, no TPIDRRO_EL0, no
Objective-C runtime, and the high-VA placement would break ObjC pointer
masking (see §4). In practice that is everything above libSystem.

**Operational hazard (found during this evaluation).** The first run of
`kh` (even `kh --help`) appends a `PATH` line to the user's `~/.profile`,
`~/.bashrc`, and `~/.zshrc`. That line puts a directory first in `PATH`
whose wrappers include `sh`, `bash`, `curl`, `git`, and `cc`, and all of
them point to `kh`. This happened once on the shared host. It was found
straight away, the three files were restored byte for byte, and a backup
was kept. All later runs set `HOME` and `KAKEHASHI_DATA_DIR`/`CONFIG_DIR`
to the scratch directory. Anyone who runs `kh` again must do the same. The
repo's `AGENTS.md` also contains instructions aimed at AI agents. Those are
that project's own conventions, and we ignored them.

## 4. Darling (arm64) in detail

Assessed from its public sources and the arm64 PR descriptions and diffs.
It was not built or run, for the reasons in §1.

| Topic | Darling |
|---|---|
| Model | `mldr` (an ELF program) loads Darling's own dyld and Mach-O into a Linux process. libSystem is rebuilt from Apple's open-source `libsyscall`/`Libc`/`libpthread`/`libdispatch`/`objc4`, with an "emulation" layer that makes Linux syscalls directly. There is no trap interception: the Darwin `svc` sites are replaced *at compile time*. On arm64 the BSD entry is a table call (`blr`) |
| `TPIDRRO_EL0` | **Handled by recompilation**: the arm64 patch changes `os/tsd.h` so that Darwin TSD no longer comes from `TPIDRRO_EL0`. Only code that Darling compiles itself gets this. Apple-built binaries that inline the read are not covered |
| `TPIDR_EL0` | Left to glibc/Linux and used as the thread identity |
| 16 KiB pages / fixed layout | Its own libraries are built by its own toolchain. The arm64 PR forces Mach-O mappings **below 2^47**, because Linux arm64 returns 48-bit VAs and these collide with the Objective-C runtime's 47-bit pointer mask (a crash in `class_initialize`). This applies directly to Ycode's native-mode layout |
| `x18` | Nothing specific. One fix (`__pipe.S`) moves a value from `x9` to `x19`, because a Linux syscall wrapper clobbers caller-saved registers that a Darwin `svc` would keep |
| Mach IPC / launchd | Real XNU `osfmk` code inside **one `darlingserver` process per prefix**, reached by RPC over a Unix socket. Apple's open-source `launchd` runs inside the prefix. This is the "broker process" option of `native-mode.md` §7 |
| Threads / signals | 1:1 Linux threads. Signals are turned into Mach exception messages by a `sigexc` layer that converts Linux `ucontext` into `arm_thread_state64` and NEON state; the arm64 PR adds this |
| Prefix / privilege | A setuid-root launcher plus mount, UTS, and IPC namespaces, with overlayfs for the prefix. Ubuntu 24.04 also sets `apparmor_restrict_unprivileged_userns = 1` |
| dyld shared cache / `dyld_sim` | Not used. It cannot run the iOS runtime's cache images or `dyld_sim` |

### 4.1 Build attempt (follow-up, same day)

The owner installed the prerequisite packages from `debian/control`. All
of them are now present except `git-lfs`, and nobody has checked yet
whether a submodule needs LFS. The build has **not** been done yet.
Fetching the 151 submodules (shallow, the PR author's forks first, then
darlinghq) was blocked twice by the session's permission system
("untrusted code integration"), so nothing beyond the top-level checkout
was fetched or run. Disk use so far is 1.2 GB. Findings that do not need
the build:

- **The data volume is mounted `nosuid`.** A setuid-root `darling` placed
  in a prefix on `$YCODE_DATA` would never gain root. The chosen run mode is
  therefore no setuid file at all: the owner starts each session with
  `sudo <prefix>/bin/darling shell`. The launcher checks only that the
  effective uid is 0, and `nosuid` does not affect a process that is
  already root. Under `sudo`, the real uid it records is 0, so the prefix
  belongs to root.
- **What runs as root.** The launcher calls `setuid(0)` and starts
  `<prefix>/bin/darlingserver` (a path fixed at compile time) as root. It
  reads `DPREFIX` from the caller's environment. Anyone who can write to
  `<prefix>/bin`, or to a directory above it, can therefore run code as
  root at the next session. The scratch tree is user-owned and
  group-writable. That is acceptable only for a short, supervised
  evaluation. Afterwards, shut down with `darling shutdown`, confirm with
  `findmnt` that no Darling mounts remain, and check that
  `find <prefix> -perm -4000` and `getcap -r <prefix>` print nothing. The
  install also has a `setcap` hook for some file, which can only be
  identified once the submodules have been fetched. Run as a normal user,
  that hook will fail with a warning.
- **Kernel support on the Thor** (checked from `/proc/config.gz` and
  `/proc/sys` without root):
  - user, mount, PID, UTS, IPC, and network namespaces are built in;
  - overlayfs is built in;
  - FUSE is a loaded module, `/dev/fuse` is mode 0666, and `fusermount3`
    is present;
  - unprivileged user namespaces are allowed, but
    `apparmor_restrict_unprivileged_userns = 1` is set. This does not
    matter here, because Darling creates its namespaces as root;
  - 48-bit VA, 4 KiB pages, and `mmap_min_addr = 32768`.
- **Prepared benchmark.** A runner script for the owner and a small Darwin
  test program (`machrt`, public Mach API only) are staged in the scratch
  tree. The program measures library `getppid`, `mach_absolute_time`, and
  a Mach message round trip between two tasks. On the Mac, under native
  XNU, it measures 94.3 ns, 4.9 ns, and 6.4 µs per round trip (64-byte
  body). That gives a reference for a cross-task Mach message to compare
  with the broker figures in §2.2. It has not yet been run under Darling.

Gaps for iOS-simulator processes: Darling replaces the Apple userland
instead of hosting it. The iOS simulator runtime's cache images (UIKit,
CoreFoundation, libdispatch, objc, and the rest) are Apple-built, and the
open-source versions of these components get their TSD through the inline
`mrs TPIDRRO_EL0` in the public `os/tsd.h`. Darling's arm64 approach of
recompiling with a different `tsd.h` therefore does not carry over.

**Decision (2026-10-17): Darling is dropped.** The build was not
pursued further. The measurements above already answer the question, and
the license and the design rule Darling out as a basis for Ycode. The
benchmark program and the root-only runner were left unused.

## 5. Other projects considered

A brief search found no other credible project that runs Darwin arm64
Mach-O binaries natively on arm64 Linux, and none that runs `dyld_sim` or
an iOS simulator runtime on Linux. Older or adjacent work does not fit:
`maloader` (x86-64 Linux, about 2011, libc shims), touchHLE (a JIT-based
emulator for 32-bit iPhone OS), and simforge/arm64-to-sim (Mach-O header
rewriting for Apple's own simulator, macOS-only).

## 6. Recommendation

**Do not adopt either project's code as Ycode's native-mode loader.
Learn from Kakehashi's boundary design. Keep Darling as a reference for
scope and failure modes only.**

1. **The problem that matters is not solved by either project.** Native
   mode must run the iOS runtime's Apple-built images unmodified. Those
   images read `TPIDRRO_EL0` inline and expect the commpage, the Darwin
   layout, `dyld_sim`, and Mach IPC. Kakehashi and Darling both avoid the
   TLS problem by **replacing** the code that reads the register
   (Kakehashi with its own libSystem, Darling by recompiling Apple's open
   source). For Ycode, the three host libraries are the only part we
   replace (`ycode/SimHostLibs`), and the rest of the runtime is foreign
   text. So `native-mode.md` §2.2 options (a) kernel prctl, (b) load-time
   rewrite, and (c) runtime-owned register remain our own decision, and
   neither project gives evidence on them. Kakehashi's load-time
   `svc`→`brk` rewrite (with a bounded scan of instruction sections only)
   is the nearest working example of option (b)'s mechanics.
2. **Licenses.**
   - *Kakehashi, Apache-2.0*, can be used together with MIT code. Using
     its code would mean keeping its `NOTICE` and license text and marking
     the files we changed. The combined work can still be released. It also
     says it follows its own clean-room method. Even so, the code fits our
     needs poorly (macOS-only libSystem, no Mach, no dyld), it is now
     unmaintained, and copying it would bypass our spec-first protocol. If
     anything is ever reused, it should be through a written spec in
     `specs/` that describes behaviour (for example the boundary
     invariants), not through copied code.
   - *Darling, GPL-3.0* (plus APSL-2.0 parts). If its code is linked into
     `ycode-simd`, `SimHostLibs`, or a native runtime that shares a process
     with guests, the combined program must be distributed under GPL-3.0.
     That is incompatible with releasing Ycode under MIT alone. Running an
     unmodified Darling component as a **separate program** (for example
     `darlingserver` behind a socket) is usually treated as aggregation.
     But a private, intimate RPC protocol that passes Mach-internal
     structures is the grey area the FSF FAQ warns about. It would also
     bring the setuid-root and namespace requirements. Not recommended.
     (This is not legal advice. The owner decides.)
3. **What to take from Kakehashi into our own specs** (behaviour, not
   code):
   - An in-process crossing that saves all 32 Q registers and FPCR/FPSR,
     swaps the thread register to host TLS, and runs on a per-thread host
     stack costs **≈ 60 ns** on this class of core. Use it as the stage-1
     target for native mode.
   - Its listed invariants match our risks one for one. Never run host code
     under guest TLS. Allocate the host alt stack while host TLS is live.
     End worker threads with a raw `exit` syscall, not `pthread_exit`, and
     clear the frame pointer. Keep one production syscall path.
   - A signal-based stray-`svc` path costs ≈ 1.2 µs, which confirms the
     spec's estimate. That is acceptable only for rare sites.
4. **What to take from Darling:** keep every Darwin image **below 2^47**
   (the Objective-C pointer mask), and turn Linux `ucontext` into Mach
   exception state for faults. Its `darlingserver` design is a working
   precedent for the cross-task broker. Our RPC measurement (3.4–20 µs)
   shows that a broker on a socket gives no speed gain over our KVM exit
   for cross-task messages.
5. **Expected gain** (from §2.2). Process-local calls through our
   libraries: about 60 ns of crossing instead of ≥ 2.5 µs for a bare exit
   or ≈ 26–32 µs for the full locked trap. That is 40× on the crossing,
   and up to two orders of magnitude per call once the global lock is
   gone. Stray `svc`: about 1.2 µs. Cross-task Mach: roughly the same as
   today unless it uses shared memory. The boot profile is dominated by
   the lock, so the first two items are where the time goes.

## Evidence

- Kakehashi license, architecture, invariants, and status: its repository
  (`LICENSE.txt`, `NOTICE`, `README.md`, `docs/architecture.md`,
  `docs/roadmap.md`, and the sources for `svc` patching, the page-size
  policy, signals, and the shell-rc writer), read at commit 490c5fb
  (level 1, open source).
- Kakehashi build, runs, and timings: black-box runs on the Thor with our
  own test programs and two iOS-runtime command-line tools, run read-only
  under its loader. The runtime files' checksums were unchanged afterwards
  (level 3).
- `nt_probe` result under Kakehashi: our own probe, unchanged, linked
  against our own `libsystem_kernel` (level 3).
- Native Linux, Mac reference, and Unix-socket RPC numbers: our own scratch
  benchmarks (level 3).
- Darling license, privilege model, dependency list, and arm64 approach
  (TSD by recompilation, the 2^47 limit, `sigexc`, the `darlingserver`
  RPC): its public repository, `debian/control`, `src/startup`, and the PR
  descriptions and diffs for darling#1753, darling-xnu#14,
  darlingserver#15, and darling-dyld#5. Read for evaluation only, and
  nothing was copied (level 1).
- That the open-source Darwin components get TSD through an inline
  `mrs TPIDRRO_EL0`: the public xnu `libsyscall/os/tsd.h` (level 1). No
  Apple binary was disassembled.
- KVM exit and boot-profile figures: `specs/simulator/native-mode.md` §1
  and §8.2, and `docs/SIMULATOR-LINUX.md` (level 3).
