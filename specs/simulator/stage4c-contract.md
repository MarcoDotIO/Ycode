# Contract: simulator stage 4c — booting `launchd_sim`

Status: **active (2026-10-12)**, phase **4c-i**. Stage 4c of
`docs/SIMULATOR-LINUX.md` (stage 5 "Mach IPC and bootstrap" in its list):
run the runtime's own `launchd_sim` as the guest init and serve it as its
host. Reference: `specs/simulator/launchd-sim.md` (levels 3/4),
`processes.md`, `mach-ipc.md`, `stage4b-contract.md` (current machine).

## 1. Goal and phases

| Phase | Exit criterion |
|---|---|
| **4c-i** harness | `ycode-simd --device <dir> …` builds a device directory and a bootstrap plist, starts `RR/sbin/launchd_sim` per `launchd-sim.md` §2 with a host bootstrap port served by the VMM's **host task**, and logs every message `launchd_sim` sends to it. A `--trace --keep-going` run produces the list of unimplemented traps and library functions on `launchd_sim`'s path. The wire format of the bootstrap/XPC-pipe requests is specified (`bootstrap-wire.md`). |
| **4c-ii** serve | The host answers `launchd_sim`'s check-in of the device launchd name and lookups of host names (1102 for all, at first). With `Bootstrap.Paths` = one empty directory, `launchd_sim` keeps running and `TMP/launchd.log` shows the `system` and `user/501` domains created. |
| **4c-iii** first jobs | The guest's own `launchctl print system` runs as a one-shot (VMM control channel, `launchd-sim.md` §7.2 item 6, or a job plist) and prints the domain. Then `Paths` with only logd and notifyd: both start through `xpcproxy_sim` and stay up. |

This contract pins 4c-i; 4c-ii/iii are added as §8+ when 4c-i reports.

## 2. Device mode (orchestrator decisions)

- `ycode-simd --device <hostdir> --runtime-root <RR> [--udid <UDID>] [--job-path <dir>]… [--exec-args …]`
  boots a device instead of running `--exec`. The root process (pid 100) is
  `launchd_sim`.
- **Paths.** Guest paths equal host paths (as before), so RR's guest path is
  its host path. DEV is `<hostdir>` (created if absent). Ycode creates
  `DEV/data/{tmp,var/run/simulatoraudio,Library/LaunchDaemons,Library/Application Support/Simulator}`,
  `DEV/data/var/run/memory_warning_simulation` (empty), the audio plist
  (`launchd-sim.md` §3), and `DEV/tmp-host/` and `DEV/private-var-tmp/`
  as the host directories behind the guest paths `TMP`'s parent and
  `/private/var/tmp` (and `/var/tmp`), both writable. TMP =
  `/private/var/tmp/com.apple.CoreSimulator.SimDevice.<UDID>` (mode 0700).
  `/tmp` and `/private/tmp` → `DEV/data/tmp` (writable).
- **UDID** default: a fixed UUID derived from the device path (stable
  across runs); upper case with dashes.
- **Bootstrap plist** (`DEV/data/var/run/launchd_bootstrap.plist`, XML),
  every key of `launchd-sim.md` §3 with Ycode's values: device name
  `Ycode`, model `iPhone19,4` / `V68` / `iphone` unless overridden,
  screen 1206×2622 @3 pitch 460, runtime version and build read from
  `RR/System/Library/CoreServices/SystemVersion.plist` (a file format),
  `SIMULATOR_HOST_HOME` = `DEV`, framebuffer/HID framework paths empty,
  `SIMULATOR_CAPABILITIES` empty string, `Paths` = the `--job-path`
  arguments in order (default: one empty directory `DEV/ycode-empty-jobs`).
- **Process start** (`launchd-sim.md` §2): argv `["launchd_sim", <plist>]`,
  environment = `Bootstrap.Self` plus `XPC_SERVICE_NAME`, `XPC_FLAGS=0x0`,
  `OSLogRateLimit=64`, `USER=mobile`… (not the holding-tank variables);
  fds 0 and 1 = `/dev/null`, 2 = the console (Ycode keeps stderr visible),
  3 = `/dev/console` write-only; cwd `/`; the task bootstrap special port
  is a send right to the host bootstrap port (§3).
- The executable path given to the launcher is `RR/sbin/launchd_sim`
  (argv[0] stays `launchd_sim`); `executable_path=` in `apple[]` is the
  real path.

## 3. The host task (orchestrator decision)

The VMM is the host. It gets a **host task**: a Mach port space with no VM
and no BSD process, owned by Swift code in the VMM, in the same
`MachIPCSystem` as the guest tasks. Host services are Swift threads that
receive on ports of the host task and reply.

- The **host bootstrap port** is a real port whose receive right is in the
  host task. It replaces the 4a/4b bootstrap kernel object for device mode
  (`--exec` mode may keep the kernel object; sends to it keep failing with
  `MACH_SEND_INVALID_DEST`, so 4a/4b behavior is unchanged).
- Messages from guests to host ports are ordinary messages: rights and OOL
  are copied in from the sender, trailers carry the sender's audit token.
- Agent M designs the Swift API (receive with timeout on a port or port
  set, send with port descriptors of any disposition and OOL data, make/
  destroy ports, request notifications) and documents it in this contract
  (§6 table) in its report; it must be usable from a plain host thread that
  holds no kernel lock and is not a guest thread.

## 4. Phase 4c-i work split

| Agent | Work | Owns |
|---|---|---|
| **M** (Mach) | The host task (§3): `MachIPCSystem.makeHostTask()` or equivalent; the Swift message API; `MachIPCSystem.hostBootstrapPort` with its receive right in the host task; a way for P/V to give the root process a send right to it as its bootstrap special port. Unit tests: a guest kernel sends to the host port and gets a reply; port and OOL descriptors both ways; dead-name/no-senders for host ports. | `Sources/YcodeDarwinKernel/MachIPC*.swift`, new `Sources/YcodeDarwinKernel/Host/*.swift` (host-task files only), `Tests/YcodeDarwinKernelTests/MachHost*Tests.swift` |
| **F** (descriptors) | Device nodes: `/dev/null`, `/dev/zero`, `/dev/random`, `/dev/urandom` (reads from host entropy), `/dev/console` openable by path (write → console, read → EOF), `/dev/tty` → ENXIO; `stat` as character devices (`S_IFCHR`, plausible `rdev`); `/dev` as a directory listing these; `open` with O_CLOEXEC etc.; `DarwinFileSystem` API for V to install fds 0/1/3 at start. Path aliases: the VFS treats `/var` → `/private/var`, `/tmp` → `/private/tmp`, `/etc` → `/private/etc` as symlinks in the guest namespace (readlink shows them) when the device mode asks for it. | `DarwinFileSystem.swift`, `DescriptorObject.swift`, `Descriptors/`, its tests |
| **V** (VMM) | Device mode (§2): options, device directory, bootstrap plist (XML via Foundation, works on Linux), process start, fds, VFS prefixes, the host bootstrap port as the root's bootstrap special port (M's API), and a **logging host bootstrap service**: a host thread that receives on the host bootstrap port and prints every message (header, ids, descriptors, body hex, sender pid) to stderr and to `DEV/ycode-host-bootstrap.log`, replying nothing yet. `--exec-args`/`--env` for `--exec` mode too. | `Sources/ycode-simd/*`, `YcodeHypervisor`, `CKVM` |
| **R** (research) | `specs/simulator/bootstrap-wire.md`: the wire format of the guest→bootstrap requests and their replies — `bootstrap_look_up`, `bootstrap_check_in`, `bootstrap_register`/`bootstrap_create_service` if used, XPC-pipe routines (`xpc_pipe_routine`), the XPC object serialization used inside them, and `launchd_sim`'s own messages to its host bootstrap at startup if observable. | `specs/simulator/bootstrap-wire.md`, scratch only |

P (process layer) is not active in 4c-i; if M or V need a change in P's
files (e.g. giving pid 100 its special port at `spawnInitialProcess`), they
write a `// CONTRACT-REQUEST:` and the orchestrator routes it.

## 5. Research rules for R (evidence ladder, `CLAUDE.md` rule 4)

1. Level 1 first: Apple's open-source projects that describe bootstrap
   messages (old `launchd` MIG definitions, xnu headers, libdispatch,
   swift-corelibs) and public documentation.
2. Level 3: black-box capture with **our own programs** on this Mac's iOS
   simulator (`xcrun simctl spawn`): a probe that points its own
   `bootstrap_port` / task bootstrap special port at a port it owns,
   receives the raw request that the runtime's library sends, records the
   bytes, forwards it to the real bootstrap port with its own reply port,
   records the reply, and forwards that back (a man-in-the-middle on its own
   messages). Vary names and calls to separate fixed from variable fields.
3. Levels 4–5 are not needed and not allowed for this task: do not open
   `.claude/Xcode.app`, any runtime binary, `research/dirty/`, or Ghidra.
4. The spec states formats (field offsets, ids, key names, value types,
   reply codes) and observed behavior, with an Evidence table. No code from
   any binary. Captured raw bytes may be summarized; full dumps stay in the
   scratch directory.

## 6. Interfaces published by agents

### 6.1 Host task (agent M, `Sources/YcodeDarwinKernel/Host/MachHostTask.swift`)

A Mach port space with no VM and no BSD process, in the system's
`MachIPCSystem`. Every method may be called from any host thread that
holds no kernel lock (it takes `system.lock` itself).

| API | Meaning |
|---|---|
| `DarwinSystem.hostTask`, `MachIPCSystem.makeHostTask(lock:log:)` | The one host task (made on first use); its first port is the host bootstrap port |
| `MachIPCSystem.hostBootstrapPort`, `MachHostTask.bootstrapPort` | Host-task name of the host bootstrap receive right |
| `MachIPCSystem.hostBootstrapIsDefault = true` | Device mode, set before `spawnInitialProcess`: every later task starts with a send right to the host bootstrap port as its bootstrap special port, name `0x503`. Default false (`--exec`): the old kernel object (sends fail with `MACH_SEND_INVALID_DEST`) |
| `setSpecialPort(of:which:to:)`, `give(_:disposition:to:)` | Put a host right into a task (special port before it runs; any right as a message would) |
| `receive(on:timeout:)` | Receive on a right or port set; ns timeout, nil = forever, 0 = poll; errors `.timedOut`, `.portChanged`, `.interrupted`, `.invalidName` |
| `MachHostReceivedMessage` | Header fields, `descriptors` (`.port`, `.ool`, `.oolPorts`, `.guardedPort`, names in the host task), `body`, `seqno`, `context`, `sender: MachAuditToken?` (pid, pidVersion, euid…), `isFromKernel`, `wireImage` |
| `send(_:timeout:)`, `reply(to:id:descriptors:body:)`, `discard(_:)` | Ordinary Mach sends (dispositions 16–21, OOL, OOL ports; body a multiple of 4); trailer identity `pid`/`uid`/`gid` (default 0) |
| `makePort`, `makePortSet`, `addMember`, `removeMember`, `insertRight`, `destroyPort`, `deallocate`, `modRefs`, `rights(of:)`, `requestNotification` | Port routines on the host space |
| `shutdown()` | Destroys the host space as at task exit (guests see dead names) |

### 6.2 Device nodes and device-mode descriptors (agent F, `DarwinFileSystem`)

- `servesDevices` (default **true**, all modes): `/dev/{null,zero,random,urandom,console,tty}` as character devices; `/dev` is a read-only listable directory; `/dev/tty` opens with ENXIO.
- `guestSymlinks` (default empty): device mode sets `DarwinFileSystem.darwinRootSymlinks` (`/var`, `/tmp`, `/etc` → `private/…`) and serves its writable prefixes at `/private/…`. A host directory under the host's `/tmp`, `/var`, or `/etc` is then unreachable by its own guest path: DEV must live elsewhere.
- `installDeviceModeStandardDescriptors()`: fd 0 `/dev/null` read-only, fd 1 `/dev/null` write-only, fd 2 the console, fd 3 `/dev/console` write-only.
- `open(_:flags:mode:at:)` (open at a given fd), `readlink` (BSD 58/473).

## 7. Rules for every agent

As `stage4b-contract.md` §9: clean room; edit only your files; builds with
`--scratch-path /tmp/yc-4c-<agent>`; Thor work in
`$YCODE_DATA/work/4c-<agent>/`; runtime root
`$YCODE_DATA/runtimes/iOS-27.1-24A94401/RuntimeRoot`; SSH
keys only, never `.env`, never a password, never sudo; the Thor is shared
(touch only your own directories); scripts in `scratchpad/agent-<X>/`;
do not commit. Report files changed, commands run with real output,
gaps, and contract requests.

## 8. Phase 4c-ii: serve `launchd_sim` (pinned 2026-10-12)

Inputs: `bootstrap-wire.md` (R's spec, level 1/3) and the 4c-i harness.
`launchd_sim` currently stops earlier, in `libsystem_malloc` (trap 357);
agent P is on that (§8.4). 4c-ii work proceeds in parallel.

### 8.1 Exit criterion

`ycode-simd --device <dir>` on the Thor, no debug flags: `launchd_sim`
gets its service port (708 → 808), finds its holding-tank child, creates
the `system` and `user/501` domains (`TMP/launchd.log` shows them), and is
still running when the run ends by `--timeout-ms` (then exit 0 for a
timeout in device mode is acceptable — V documents the convention).

### 8.2 Work split

| Agent | Work | Owns |
|---|---|---|
| **X** (new) | `YcodeXPC`: the XPC object model and its serialization (`bootstrap-wire.md` §3: `?cpx`/`@cpx`, version 5, every tag in §3.2, dictionaries/arrays, key order kept but lookups by name, port-bearing objects matched to descriptors in depth-first order, inline vs. one-OOL payload §2.3), plus pipe-routine request/reply helpers (§2, §4: ids `0x40000000\|n`, reply `0x20000000`, one-way `0x10000000`, `error` replies, `{port}` replies). Pure Swift, no Mach dependency: a message is (id, body bytes, [descriptor]) with an abstract descriptor enum. Tests from the captured examples in the spec. | `Sources/YcodeXPC/**`, `Tests/YcodeXPCTests/**` |
| **V** | The host bootstrap **server** in `HostBootstrap.swift`: 708 (size 24) → make a port, keep a send right as the control-channel end, reply per `bootstrap-wire.md` §5.2; pipe routines per §8 of that spec using `YcodeXPC` (207/804 → 1102 / 3, 206/805 → new receive right, others → `{error: 45}`), logging every request decoded. The holding-tank child via P's API (§8.3). Keeps the 4c-i logging (decoded now). | `Sources/ycode-simd/*` |
| **P** | (after §8.4) `DarwinSystem.spawnInitialProcess(_:fileSystem:exitedChildEnvironmentKey:)`: when the key is given, create the root record, then an already-exited, unreaped child of it (no VM; status 0), add `KEY=<child pid>` to the root's environment, then launch. `wait4`/`waitpid` by the root reaps it as usual. | its files |

### 8.3 Pinned

- `spawnInitialProcess(_ request: ProcessImageRequest, fileSystem: DarwinFileSystem, exitedChildEnvironmentKey: String? = nil) throws -> DarwinKernel`.
- The holding-tank key is `XPC_SIMULATOR_HOLDING_TANK_HACK`; `…_FD_HACK` is not set.

### 8.4 The malloc stop (agent P)

`launchd_sim` (also with `--exec`) ends with BRK #1 in `libsystem_malloc`
right after `mach_vm_map(size 0x494000, flags 0x1000001, prot none)` and
`vm_deallocate` of 1 MiB inside it. P investigates from open-source
libmalloc/xnu and our own run state only.

### 8.5 Resolutions (4c-i and 4c-ii, 2026-10-12)

- **4c-ii exit criterion met** (orchestrator, fresh tree on the Thor, no
  debug flags): `ycode-simd --device … --timeout-ms 30000` exits 0;
  `launchd_sim` sends 708 and gets 808, reaps its holding-tank child, and
  `TMP/launchd.log` shows `system` created, "launchd logging initialized",
  "boot-mode committed", and `user/501` created, entering and exiting
  bootstrap and on-demand mode. It is still running at the timeout
  (1,988 traps, 5 threads). Tests: 353 Swift tests and the host-library
  checks pass on the Thor; hello, the 4a and 4b probes, `p_hostboot`, and
  `p_brk` pass in three rounds.
- What it took (all level 1 or level 3):
  - `executable_cdhash`/`executable_boothash` in `apple[]` — xzone malloc
    aborts without the boothash for launchd-class processes (libmalloc).
  - `kern.bootargs`, `hw.ephemeral_storage`; the workloop `SYNC_WAIT` rule
    (last change, not only change).
  - `mkdir`/`rmdir`; guarded descriptors (`guarded_open_np` family).
  - Host libraries: `pthread_once` signature, `___gettimeofday` x2,
    `mach_port_set_attributes` as MIG 3218, `host_get_special_port`, the
    os_alloc_once slot-21 ASL layout (the live-lock), `os_unfair_lock`
    EOWNERDEAD crash.
  - Kernel Mach: the simulator `MQ_CALL` exemption, MIG 3217/3218,
    send-possible notification semantics (delayed vs. immediate).
- **Known, accepted for now:** `launchd_sim` asserts `0x11`
  (`KERN_INVALID_RIGHT`) at `launchd_sim+64312`: it sets `LIMITS_INFO` on
  its task bootstrap port, of which it holds only a send right; it
  continues. Whether the Mac gives it a receive right there is open
  (R's probe can tell). The `system` domain stays in bootstrap mode (as in
  R's Mac run with the minimal host: "in-progress bootstraps = 1").
- `p_stdfds` assumes fd 3 is free, which holds in device mode only; it
  fails under `--exec` (probe issue, to fix).

## 9. Phase 4c-iii: first jobs (pinned 2026-10-12)

### 9.1 Exit criterion

On the Thor, `ycode-simd --device` with no debug flags:

1. A job plist in a `--job-path` directory (Ycode-written, `RunAtLoad`,
   `ProgramArguments` = `/bin/launchctl print system`, `StandardOutPath`
   under `/tmp`) is spawned by `launchd_sim` through `xpcproxy_sim`, runs,
   and its output file holds the printed `system` domain.
2. With `--job-path` pointing at a directory that holds only the runtime's
   logd and notifyd plists (Ycode links or copies them into the device
   directory at run time; nothing from the runtime enters the repository),
   both daemons start through `xpcproxy_sim` and are still running at the
   timeout, and `launchd.log` shows no crash or throttle for them.

### 9.2 Model

This phase is trace-driven debugging across every layer, so one agent
(**I**, integrator) owns all of `ycode/` for its duration; no other agent
edits `ycode/` meanwhile. Each fix stays small, is covered by a unit test
or a probe where practical, and is listed in the report with its evidence
level. Evidence rules are unchanged (levels 1 and 3; reading a runtime
plist as a file format is level 2; no disassembly).

### 9.3 Also in scope

- `p_stdfds`: make it independent of fd 3 (print the ok line to stdout).
- The default `--run-dir` is under the host's `/tmp`; on the Thor that is
  the nearly full system disk. Remove the run directory at exit unless
  `--keep-run-dir` is given (a directory the run created; never anything
  else).

### 9.4 Resolution (4c-iii done, 2026-10-12)

- **Exit criterion met** (orchestrator, fresh tree on the Thor, no debug
  flags, three rounds, 54 of 54 checks): `--oneshot "/bin/launchctl print
  system"` runs through `xpcproxy_sim` (pid 102, exec-replaced) and its
  output holds the `system` domain; with `--runtime-job com.apple.logd
  --runtime-job com.apple.notifyd`, both daemons are spawned ("Successfully
  spawned logd[102] because speculative", notifyd "because ipc (mach)")
  and are alive at the timeout with no crash or throttle in `launchd.log`.
  Every earlier probe passes; 424 Swift tests and the host-library checks
  pass on macOS, the Thor, and x86-64.
- Fixes (integrator I, levels 1–3): `RequireDomainBinding = false` in
  Ycode's bootstrap plist (no session bind yet); kevent `EV_VANISHED` as a
  request flag; `MACH_RCV_SYNC_WAIT` on combined `mach_msg2`; workqueue
  binding at hand-out (two workers on one workloop → EXDEV); repeated
  `SYNC_WAKE` succeeds (`threads-and-events.md` corrected); Mach memory
  entries and cross-VM shared memory (private routines 10/11); POSIX shm
  (`shm_open`, `ftruncate`, shared `mmap`); `kern.bootsessionuuid`;
  `task_info(TASK_AUDIT_TOKEN)`; exit-reason `proc_info` flavors;
  `fgetxattr` family; host-library port-description tables and small Mach
  routines; device-mode options `--oneshot`, `--runtime-job`,
  `--keep-run-dir`, `--debug-plist-bool`; fault reports with
  `__crash_info` annotations.
- Facts recorded: `launchd-sim.md` §9 Q4 (partly) and Q5;
  `host-libraries.md` §11.1.
- Open: the control-channel session bind (`startsession`), the `0x11`
  assertion at `launchd_sim+64312`, `proc_pid_rusage` times (launchd's
  "ran for 0ms" and throttle logic), `host_get_io_master` (no IOKit).
