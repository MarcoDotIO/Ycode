# Contract: simulator stage 6 — headless boot with the runtime's job set

Status: **active (2026-10-12)**. Stage 6 of `docs/SIMULATOR-LINUX.md`
("launchd_sim plus the core daemons; a headless boot"). Stage 5 (Mach IPC
and bootstrap) was absorbed by stages 4b and 4c. Reference:
`launchd-sim.md` (§4.1 discovery, §4.6 boot sequence, §6.3 host-side
services, §7.2), `bootstrap-wire.md`, `stage4c-contract.md` §9.4.

## 1. Exit criterion

On the Thor, `ycode-simd --device <dir> --runtime-paths` (new option: the
four `Paths` CoreSimulator uses, `launchd-sim.md` §4.1, with DEV's own
`Library/LaunchDaemons` empty or Ycode-written) and `--timeout-ms 180000`,
no debug flags:

1. `launchd_sim` imports the full job set and stays up for the whole run.
2. A `launchctl list` one-shot near the end shows at least the **core set**
   running: logd, notifyd, cfprefsd (system and user), configd-class
   (whatever the runtime uses), containermanagerd (system and user),
   deviceconfigurationd, UserEventAgent, mobileassetd or its equivalent
   if demanded, and lsd/`runningboardd` if started on demand.
   The integrator lists exactly which are up and why the others are not.
3. No **crash loop**: no job in the core set exits more than twice, and
   `launchd.log` contains no "crashed" or "throttled" line for it.
4. Everything else that crashes or throttles is listed with the abort
   message (fault report) and a one-line cause: Ycode gap (to fix later),
   missing host service (`launchd-sim.md` §6.3, expected), or display/GPU
   dependency (stage 8, expected). SpringBoard and backboardd are expected
   to fail without a display; that is acceptable here.
5. Every earlier check still passes (the 4c-iii verify suite).

## 2. Model

As 4c-iii (`stage4c-contract.md` §9.2): one integrator agent owns all of
`ycode/`; small tested fixes; evidence levels 1–3 only (Apple open source,
files read as formats, our own runs and probes); no disassembly, no
`.claude/Xcode.app`, no `research/dirty/`, no Ghidra. Questions that
levels 1–3 cannot answer are reported, not guessed.

## 3. Also in scope (if they block)

- `proc_pid_rusage` start/exit times (launchd's run-time and throttle
  logic).
- The `0x11` assertion at `launchd_sim+64312` (a level-3 probe on the Mac
  can show whether `launchd_sim` holds the receive right of its task
  bootstrap port there).
- Host-side names (`launchd-sim.md` §6.3): Ycode registers none yet; if a
  core daemon needs one to start, report which.
- Performance: if the boot is too slow to reach steady state in 180 s,
  measure where time goes (trap counts per process, vCPU counts) before
  optimizing.

## 4. Decisions and findings (checkpoint 1, 2026-10-12)

- **Release builds for device runs.** Under the debug build the global
  kernel lock is 88–95 % busy (address-space operations linear in chunk
  count; a KVM memslot per shared-cache `mmap` per process). Release cuts
  it to ~70 % with ~8× throughput. Performance work is split out (§5).
- **`/System` in device mode** is served from `RR/System`, read-only: the
  runtime opens some bundles at their unrooted `/System/…` path (level 3);
  on the Mac that path reaches the host's own copy. Orchestrator decision:
  keep it (the guest sees its own runtime's bundles).
- `/` and every directory above a served prefix stat as read-only
  directories (opening them gives EACCES).
- TBI0 is on (vm-shim-protocol.md updated); private routines 12–15 are in
  `host-libraries.md` §11.2; `proc_pid_rusage` carries start/exit times.
- **configd_sim** asserts without the host's configd service
  (`launchd-sim.md` §6.3 `com.apple.SystemConfiguration.configd`). This is
  a missing host service; it is listed, not required, for the exit
  criterion until a host-side SCDynamicStore is specified (Apple's
  open-source configd is the level-1 source when that work starts).

## 5. Performance track (separate agent, parallel)

Owner **Q** (new): `Sources/YcodeDarwinABI/AddressSpace.swift`,
`Sources/YcodeHypervisor/PhysicalBacking.swift` and `KVM.swift`, and new
files they need. Goals, measured on a full boot with the release build:
address-space operations O(log n) in the number of mappings; one host
mapping and memslot of each shared-cache file reused by every VM instead
of per-process registration; then a design proposal (not code) for taking
per-process VM operations out of the global kernel lock. The integrator
does not edit Q's files during this time (route requests through the
orchestrator).

### 5.1 Performance results and lock design (agent Q, 2026-10-12)

- Address-space operations are O(log n) (interval treap, in-place page
  tables with dirty tracking): `vm_allocate`/`vm_protect`/`vm_deallocate`
  ~12–19 µs independent of mapping count (were 130–660 µs and growing).
- **Shared read-only file window:** one host reservation per `ycode-simd`
  process (64 GiB, `PROT_NONE`); each file (dev, ino, size, mtime) is mapped
  once `MAP_SHARED`/`PROT_READ`; every VM registers the window once as one
  `KVM_MEM_READONLY` memslot at **GPA `0x80_0000_0000`**. Read-only file
  maps cost no host mmap and no ioctl; small writable file maps are copied
  into pool memory. File-backed RSS of a boot fell from 4.7 to 2.4 GB.
- Full boot, 90 s, release: 100 → 130–140 successful spawns; kernel-lock
  time per spawn −36 %. The lock is now dominated by host file-system
  syscalls (`stat`, `open`, `getdirentries64`, image loading in
  `posix_spawn`), ~35–40 % of lock time, versus ~8–10 % for VM traps.
- **Lock design (adopted direction):** L0 = the global kernel lock (all
  shared state: processes, Mach, kevent, descriptor tables, wait queues,
  cross-task memory); L1 = a per-address-space recursive mutex (in place);
  L2 = leaf locks (VM slots, the file window, shared objects). Order
  L0 → L1 → L2; never take L0 holding L1; never wait holding L1; never hold
  two spaces (cross-task copies go through a host buffer). **First step:**
  drop L0 around host file-system I/O (resolve under L0, do the I/O
  unlocked, install the result under L0). Second step: a fast path for
  self-targeted VM traps under L1 only.
- VM teardown: `discardAll()` under the lock, `vm.close()` outside it
  (KVM teardown takes 2–70 ms).

## 6. Resolution (stage 6 done, 2026-10-12)

**Exit criterion met** (orchestrator, fresh tree on the Thor, release
build, `--runtime-paths`, 180 s, no debug flags): `launchd_sim` stays up;
the core set — logd, notifyd, cfprefsd (user), containermanagerd (system and
user), deviceconfigurationd, UserEventAgent-System, mobileassetd, lsd,
runningboardd — each spawns once and is alive at the timeout; the only
crash/throttle lines are `configd_sim` (missing host service, §4). 119
user-domain jobs have a pid in `launchctl list`, including SpringBoard and
backboardd (headless). The 54-check verify suite passes; 448 Swift tests
pass on macOS, the Thor, and x86-64.

Decisions (Ycode, recorded here):

- **Sandbox:** `__mac_syscall` returns ENOPOLICY except the Sandbox check
  call (2), which returns 0 ("allowed"): every simulator daemon on the Mac
  observes `sandbox_check` = 0 (level 3). With it, CFPreferences uses
  cfprefsd instead of direct file access.
- **Data protection:** classes are stored per file (file default 3,
  directory default 0, new files inherit the directory class, class 4
  stored as 3, files refuse 6 and 7 with EPERM, `F_GETPROTECTIONLEVEL` 5);
  `open_dprotected_np` dpflags 1 read-only, 2 EPERM, 4 EINVAL (level 3:
  our probe on the Mac's simulator).
- **csops:** xnu `csops_internal` rules (level 1); status words as observed
  on the Mac's simulator: platform binaries `0x26004201`, other signed
  images `0x22000201` plus linker-signed (level 3).
- **Durability:** `fsync`/`fdatasync` are no-ops on files (ENOTSUP on other
  descriptors); the host's page cache is trusted.
- **Extended attributes** persist as host xattrs named `user.ycode.<name>`.
- **chown** cannot change the owner; group may be −1, the current group, or
  20. **chflags** is accepted and not stored.
- **rlimits:** NOFILE (256, unlimited), NPROC (6000, 9000) (level 3).
- **IOKit:** the minimal registry of `iokit-minimal.md`.
- **Locking:** the global lock is released around host file-system I/O for
  `stat`-family, `access`, `open`/`openat`, and directory listings
  (`KernelLock.unlocked`); §5.1 step one is done. Lock busy 58 → 51 % at
  90 s.
- `--repeat` leak verdict: threads, fds, VMs flat; RSS may grow ≤ 8 MiB.

Open after stage 6: a host-side SCDynamicStore for `configd_sim`; the
intermittent `searchd` fault (write to `0xbad` in SpotlightIndex);
`posix_spawn` image loading outside the lock; still-unimplemented calls
seen in the boot (`thread_get_state`, `kpersona_*`, `posix_madvise`,
`quotactl`, `memorystatus_control`, `setattrlist`).

### 6.1 Follow-ups after the stage (2026-10-12, integrators I2/I3)

The stage-6 leftovers are implemented (`host-libraries.md` §11.3). A
180 s release boot: every core job spawned once and alive at the timeout,
118 jobs with a pid (same as stage 6), unimplemented library-function
lines 24,811 → 105; only `configd_sim` crashes. The `searchd` 0xbad fault
was SpotlightIndex's deliberate crash on a missing
`thread_get_exception_ports` (level 3, fault-report trap ring); fixed.
searchd now exits 0 after 10–37 s and is relaunched on demand (throttle
delays, not crashes; cause not investigated). Still unimplemented in the
boot: `accessx_np` (82), `thread_info` (8), `mach_port_extract_right` (7,
from `launchd_sim`), `vm_copy` (3), `thread_suspend`/`thread_resume`,
`task_create_identity_token`.
