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

### 5.2 Regular-file transfers and renames without the kernel lock (speed round 2)

Host file-system stalls held the kernel lock for up to 1.2 s (`rename`,
`read`, `pread`, `write`; the device copy lives on a USB drive). These calls
now follow the §5.1 pattern for regular host files:

- **Checks under L0.** The descriptor is looked up once, with the lock:
  EBADF (closed, or not open for reading/writing), EISDIR (a read of a
  directory), the write guard (EXC_GUARD → EPERM). The call keeps strong
  references to the open file description and to the host file. Errors and
  their order are those of the plain calls.
- **Transfer.** `pread`/`pwrite` run at their explicit offset. `read` and
  `write` use the description's offset under the description's **offset
  lock** (an L2 leaf, `DarwinOpenFile.ioLock`, not recursive), held for the whole
  transfer: the transfer and the offset update are atomic with respect to
  every other user of the offset (another transfer, `lseek`, a dup'd or
  inherited descriptor). O_APPEND is sampled at the check and moves the
  offset to the end of file inside the transfer.
- **Reads try the page cache first, with the lock held** (Linux `preadv2`
  with `RWF_NOWAIT`; a short result counts only when it reaches the end of
  file). tmpfs refuses `RWF_NOWAIT` with `EOPNOTSUPP`; a file on a memory
  file system (tmpfs or ramfs, by `fstatfs` magic, asked once per host
  file) is then read with a plain `pread` under the lock, because its pages
  never wait for a device. A device directory in RAM (the bench harness's
  tmpfs mode) otherwise released L0 for every read. Only a read that would wait for the device releases L0, because
  re-taking L0 costs a contended acquisition (≈1 ms under boot load).
  Writes, renames and the path operations below always release L0 for
  the host call.
- **Revalidation after L0 is taken again.** The descriptor is not looked
  up again, and the call does not fail when the guest closed or replaced
  it meanwhile. The transfer belongs to the open file description it
  started on (POSIX resolves the descriptor once, at the start of the call;
  xnu holds an I/O reference on the file for the whole call), so a
  concurrent `close`, `dup2` or exec-time close does not affect it. The
  call holds strong references to the description and to the host file;
  the host descriptor closes only when its last holder lets go, so its
  number can never be reused by another open during the transfer. Only
  the image is checked: when it ended meanwhile (exit, exec, a fatal
  signal), a read fails with EINTR and copies nothing into guest memory.
  Read data is copied into guest memory, and write data was copied out of
  it, with L0 held; the guest-memory layer checks the addresses then, as
  for any call.
- **Offsets.** `pread`/`pwrite` never touch the offset. For `read` and
  `write` the offset is read, used and advanced under the offset lock in
  one step. A short transfer advances the offset by the bytes
  transferred; a failed one leaves it unchanged. `lseek` is a
  read-modify-write of the offset under the offset lock, so it never loses
  a concurrent transfer's update. A thread holding L0 never waits for the
  offset lock: the cached read and `lseek` first try it without waiting;
  when a transfer holds it, the read takes the unlocked path and `lseek`
  waits for it with L0 released.
- **Other host-only calls.** `ftruncate` of a regular host file, and
  `guarded_write_np`/`guarded_pwrite_np` of a regular host file (the guard
  is checked under L0), run the host call without L0, like `write`.
- **Renames and other path operations.** Path resolution and the
  socket-name table are safe to read without L0. A rename or unlink whose
  name is a socket file changes the guest's own name table, so it runs
  again under L0. Every other rename and unlink, and every `mkdir`,
  `rmdir` and `truncate(path)`, is a host operation alone and runs without
  L0. The umask is read before L0 is released. Known difference: a `bind`
  that creates a socket name at the same moment as a `mkdir` of that name,
  or inside a directory that an `rmdir` is removing, is not ordered
  against it (Darwin serializes both on the directory vnode).
- Lock order stays L0 → L1 → L2. The offset lock is never held while
  another lock is taken, and no thread waits for it while holding L0.
- `YCODE_FS_LOCKED_IO=1` keeps these calls under L0 (diagnostics).
- **No host access-time updates.** Host opens use `O_NOATIME` where the
  host allows it (files the host user owns), for every access mode. A
  device copy keeps old access times, so with `relatime` the first read of
  each file would otherwise write the inode through the journal. The
  holder samples showed reads waiting in `do_get_write_access`, among them
  `pread` on files opened read-write (databases), whose page-cache read
  runs with L0 held. As a result, the guest's access times do not move on
  reads (a known difference from Darwin).
- Evidence: level 1. Shared offsets of dup'd descriptors and atomic
  offset updates follow POSIX `read(2)`/`write(2)`/`lseek(2)`/`dup(2)`.
  The I/O reference that keeps a file usable across a concurrent `close`
  follows xnu's `fp_lookup`/`fp_drop` (Apple open source).

### 5.3 New-image VMs built before the kernel lock (speed round 2)

An image build (spawn, exec) runs under L0. Its first step, creating the
KVM VM and adding its memslots, took about 19 ms per image in a profiled
boot (951 builds, 18 s of L0 hold). The VM is empty at that point and
belongs to no process, so it is built earlier: a thread that is about to
make a `posix_spawn`, `execve` or `__mac_execve` trap first builds one
empty VM with no lock held and leaves it ready; the image build takes a
ready VM when there is one and builds its own otherwise. At most two VMs
wait; a spawn that fails before its image is built leaves its VM to the
next build. Traced images always build their own. `YCODE_VM_PREBUILD=0`
turns this off. No guest-visible behavior changes.

Host-side cost model (measured on the Thor, a standalone program): creating
a KVM VM registers an MMU notifier on the host process, which takes the
process's memory-map lock for writing and locks every mapping. Its cost
grows with the number of host mappings (2.7 ms at 17 mappings, 5.5 ms at
10 k, 14 ms at 40 k), and while it runs, every first touch of guest memory
in every VM of the process waits (with VMs created back to back, 6 µs per
touched page became 37 µs at 40 k mappings). Building the VM off L0 does
not remove that cost; fewer host mappings or fewer VM creations would.

Evidence: level 3 (our own measurements; Linux KVM and mmu_notifier
behavior as documented in the kernel sources). The rest is Ycode's own
design.

### 5.4 vCPUs created in batches (speed round 2)

Every guest thread runs on its own vCPU, and a new thread beyond the
image's existing vCPUs waits for one to be created (off L0, on a creator
thread; §5 of the stage-4 pool design). Measured on the Thor (Linux 6.8,
arm64, standalone program): once a VM has run with more than one vCPU,
each `KVM_CREATE_VCPU` that follows another vCPU's first `KVM_RUN` waits
for an RCU grace period, 25–60 ms (35 ms mean). Creations with no first
run in between, and all creations before the VM's second vCPU runs, take
microseconds. Profiled boots averaged 30 ms per new vCPU over ~2,700
creations.

Rule: when a vCPU must be created, the VM creates the next `n` free ids
too, back to back (`n` = 3 by default; `YCODE_VCPU_BATCH=<n>`, 0 = one at a
time), bounded by the pool's capacity. They wait unused; a later thread
start that reaches one of those ids takes it with no ioctl. A request for
an id whose batch is still being created waits for that batch. The batch
made together with vCPU 0 at image build costs no grace period, so an
image's first four threads never wait for one, and each later batch of
four waits for at most one. Unused vCPUs are closed with the VM. Guest-
visible behavior does not change (the guest's CPU count comes from
`sysctl`, not from the number of KVM vCPUs).

Evidence: level 3 (our own measurements). The rest is Ycode's own design. `RWF_NOWAIT`
  follows the Linux `preadv2(2)` manual page. tmpfs refusing it with
  `EOPNOTSUPP` (and ext4 accepting it) is level 3: a probe on the Thor
  (kernel 6.8, `/run/user` tmpfs) and the x86-64 workstation (kernel 7.0,
  `/tmp` tmpfs), where `HostFileIOTests` failed before the fallback. The
  tmpfs and ramfs magic numbers are those of Linux `statfs(2)`. The rest is
  Ycode's own locking design.

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
