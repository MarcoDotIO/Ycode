# Contract: simulator stage 4b — multiple processes

Status: **active (2026-10-12)**. Stage 4b of `docs/SIMULATOR-LINUX.md`.
Reference semantics: `specs/simulator/processes.md` (level 1, xnu). This
document pins the Ycode design, the interfaces between agents, file
ownership, and the exit criterion. Where this contract and `processes.md`
disagree on Ycode design, this contract wins; on observed Darwin
behavior, `processes.md` wins.

Read with: `processes.md`, `mach-ipc.md`, `threads-and-events.md`,
`stage4a-contract.md` (current machine), `host-libraries.md` §10.

## 1. Exit criterion

New probes in `ycode/SimShim/guest-tests/stage4b/` (our own code, built for
the iOS simulator by `build-stage4b.sh` on macOS, copied to the Thor). Each
probe re-executes **its own path** (`argv[0]`) with a mode argument to make
its child. On the Thor, no debug flags, each prints its `ok` line and the
host process `ycode-simd` exits 0:

| Probe | What it proves | Prints |
|---|---|---|
| `p_spawn_wait` | `posix_spawn` + `waitpid`; child `exit(42)`; parent sees `WIFEXITED`, status 42, `getppid()` in child = parent pid; a second child killed with `kill(SIGTERM)` gives `WIFSIGNALED`/15 | `spawn_wait ok status=42 sig=15` |
| `p_spawn_port` | parent makes a receive right, spawns with `posix_spawnattr_setspecialport_np(…, TASK_BOOTSTRAP_PORT)`; child sends a message to `bootstrap_port`; parent receives it with the child's pid in the audit-token trailer | `spawn_port ok pid_match=1` |
| `p_rights` | parent sends a receive right to the child (via the child's bootstrap port as above), child sends back a message on it, then exits; parent holds a send right with a dead-name request and gets the dead-name / port-deleted behavior per `processes.md` §4.6 | `rights ok` |
| `p_procevent` | `signal(SIGCHLD, SIG_IGN)`; `EVFILT_PROC` `NOTE_EXIT|NOTE_EXITSTATUS` on a child that exits 7 fires with data `7<<8`; `waitpid` then fails with ECHILD (no zombie) | `procevent ok status=0x700` |
| `p_setexec` | parent → child A spawned; A does `posix_spawn` with `POSIX_SPAWN_SETEXEC` into mode B; B checks `getpid()` equals A's pid (passed in argv) and exits 5; parent sees status 5 | `setexec ok` |
| `p_unix` | parent `socket(AF_UNIX, SOCK_STREAM)`, `bind` to `/tmp/…`, `listen`; child connects, sends text, then passes a pipe's read end with `SCM_RIGHTS`; parent reads the text, then reads from the received fd what the child wrote into the pipe | `unix ok` |

Also: all stage-4a probes, `hello`, and the stage-2 self-test still pass;
every test suite passes on macOS, x86-64 Linux, and the Thor.

`p_bootstrap` (lookup through a real bootstrap server) moves to 4c, where
`launchd_sim` is the server.

## 2. Execution model (orchestrator decisions)

1. **One host process, many VMs.** `ycode-simd` runs every guest process of
   a device in one host process: one KVM VM per guest *image*, one vCPU per
   guest thread (as in 4a). The host process exits when the **root
   process** (the `--exec` program, whatever image it currently runs)
   exits, with its status; remaining processes are stopped and listed in
   the summary.
2. **One kernel lock per system.** `DarwinSystem` owns one `KernelLock`;
   every `DarwinKernel` of the system uses it. A trap holds it for its whole
   duration, as in 4a. Cross-process operations (Mach send to another
   task, NOTE_EXIT to a watcher, socket data) are therefore plain shared
   memory under one lock; waits use `WaitQueue`s of that lock.
3. **Per-image kernel, per-pid process.** A `DarwinKernel` (with its
   `MachIPC` space, threads, kevents, VM) is one *image* (one Mach task).
   The *process* record (pid, ppid, pgid, sid, status, pid version, zombie
   state, watchers) lives in `DarwinSystem` and survives exec. Exec makes a
   new kernel + VM with the same pid; the old one ends with
   `Outcome.imageReplaced`.
4. **All guest descriptors that are not host files are VMM objects.** Pipes
   and AF_UNIX sockets are implemented inside the VMM (not on Linux
   sockets): all guest processes share one host process, so passing a
   descriptor is passing an object reference, blocking is a `WaitQueue`
   wait, and Darwin semantics (EADDRINUSE, immediate ECONNREFUSED, 2048-byte
   datagrams, cmsg layout) are exact. A bridge to host sockets is later
   work. (This supersedes the design note `processes.md` §5.8.)
5. **No guest signal handlers yet.** Signals have default actions
   (terminate, ignore, stop/continue) and are recorded as pending when the
   guest installed a handler; `EVFILT_SIGNAL` fires for every signal posted
   (as xnu does, even if ignored). Pushing a signal frame to a guest handler
   is out of scope (4c+ if needed).
6. **Guest paths for executables.** The VMM serves the directory of the
   `--exec` program read-only at the same absolute guest path, so a probe
   can spawn `argv[0]`. Spawn resolves the executable through the guest VFS.
7. **pids.** Pid 1 is a pseudo-init record with no image (orphans are
   reparented to it; it reaps them at once). The root process gets pid
   100 (the 4a default, `VMLayout.guestPID`); later pids increase from 101
   and wrap at 99999 back to 100, skipping live pids and process-group ids.
8. **Exec of a non-simulator image** (wrong platform, not arm64) fails with
   EBADARCH; a non-Mach-O file with ENOEXEC; a missing path with ENOENT.

## 3. Pinned interfaces (already in the tree)

The orchestrator created these seams; they compile. Agents fill them in.
Changing a pinned signature needs the orchestrator.

### 3.1 `DarwinKernel` (owner P)

- `init(fileSystem:pid:system:log:counter:counterFrequency:wallClock:)` —
  `system: DarwinSystem? = nil` (nil = a private one-process system, so
  existing tests are unchanged). `lock` is `system.lock`.
- `public let system: DarwinSystem`, `public internal(set) var pidVersion: UInt32`.
- `Outcome.imageReplaced` (new), `BSDResult.outcome(Outcome)` (new).
- `bsdCall` consults `descriptorCall` (F) then `processCall` (P) before its
  own switch; each returns nil for calls it does not own. They may
  therefore take over calls that `bsdCall` handles today (read, write,
  close, fstat, fcntl, kill, getppid, …) for the cases they own.

### 3.2 `DarwinSystem` (`Process/DarwinSystem.swift`, owner P)

- `lock: KernelLock`, `mach: MachIPCSystem`, `weak var launcher: ProcessLauncher?`
- `func kernel(forPID:) -> DarwinKernel?` — the current image of a live
  (non-zombie) process.
- P adds (pinned names, for V):
  - `func spawnInitialProcess(_ request: ProcessImageRequest, fileSystem: DarwinFileSystem) throws -> DarwinKernel`
    — makes the root process (pid 100, ppid 1), its kernel, and launches it
    through `launcher`.
  - `var processExited: ((_ pid: Int32, _ status: Int32) -> Void)?` —
    called (lock held) when a process exits for good (its wait status,
    `processes.md` §2.3). V uses it to end the host when pid 100 exits.

### 3.3 `ProcessLauncher` (`Process/ProcessLauncher.swift`, implemented by V)

`launch(_ request: ProcessImageRequest, kernel: DarwinKernel) throws -> LaunchedImage`
builds the VM for one image and wires `kernel` (thread host, counter,
frequency, boot counter, log, `allImageInfosAddress`, `mainStackTop`, …),
then starts the main thread unless `startSuspended`. Called with the lock
held; must not call into a kernel. Errors are `DarwinErrnoError`.

The kernel passed in already has: its pid, pid version, its
`DarwinFileSystem` (the child's descriptor table and cwd), and its
`MachIPC` with inherited ports.

### 3.4 `ThreadHost.stopAllThreads()` (implemented by V)

Called by P (lock held) when a process image must stop while some of its
vCPUs may be running guest code (kill, exit from one thread, exec). V
kicks every vCPU of that image out of `KVM_RUN`. Before it re-enters any
vCPU, the VMM checks `kernel.isTerminating` (pinned, a racy read without
the lock is fine) and, when it is set, ends that vCPU without running more
guest code. Once all vCPUs of the image are gone, V destroys the VM.

### 3.5 Descriptor objects (owner F)

- `DarwinDescriptorObject` (YcodeDarwinABI): `fileType`, `lastReferenceClosed()`.
- `KernelDescriptorObject` (YcodeDarwinKernel): read/write readiness and
  readiness observers. P's kevent uses only this protocol for
  `EVFILT_READ`/`EVFILT_WRITE` on pipes and sockets (and on kqueue fds).
- F adds to `DarwinFileSystem` (pinned names, for P and M):
  - an **open file description** type `DarwinOpenFile` (class) shared by
    dup'd and inherited descriptors (offset, status flags, node); objects
    get `lastReferenceClosed()` when the last description reference across
    all tables goes away;
  - `func installObject(_ object: DarwinDescriptorObject, statusFlags: Int32, closeOnExec: Bool) throws -> Int32`;
  - `func object(for fd: Int32) throws -> DarwinDescriptorObject?` (nil for host files/console);
  - `func openFile(for fd: Int32) throws -> DarwinOpenFile` and
    `func install(_ file: DarwinOpenFile, closeOnExec: Bool, at fd: Int32? = nil) throws -> Int32`
    (fileports, SCM_RIGHTS);
  - `func dup(_ fd: Int32, minimum: Int32 = 0) throws -> Int32`, `func dup2(_ from: Int32, _ to: Int32) throws`;
  - `func makeChildCopy() -> DarwinFileSystem` — same prefixes, console,
    cwd, every descriptor sharing its description and keeping its
    close-on-exec flag;
  - `func closeOnExecDescriptors(keepOnly: Set<Int32>? = nil)` — exec: close
    every close-on-exec descriptor; with `keepOnly` (CLOEXEC_DEFAULT), close
    every descriptor not in the set;
  - `func closeAll()` (exit);
  - `func chdir(_ path: String) throws`, `func fchdir(_ fd: Int32) throws`;
  - `func hostPathForExec(_ path: String) throws -> (guestPath: String, hostPath: String)`
    — resolves (cwd-relative, symlinks), EACCES if a directory, ENOENT.

### 3.6 Signals (owner P)

`DarwinKernel.postSignal(_ signal: Int32, thread: ThreadContext? = nil)`
(lock held). F calls it for SIGPIPE.

### 3.7 Mach (owner M)

`MachIPCSystem` (in `DarwinSystem.mach`) holds what all tasks share. M adds
on `MachIPC` (pinned names, for P):

- `func inheritTaskPorts(from parent: MachIPC)` — host, bootstrap,
  task-access, registered ports, exception ports 1–13 (`processes.md`
  §3.3). Used at spawn (parent = spawner) and at exec (parent = old image).
- `func applySpawnPortActions(_ actions: [SpawnPortAction], from caller: MachIPC) throws`
  — `SpawnPortAction` is M's public struct mirroring the 24-byte record
  (`processes.md` §1.8): `kind` (special, exception, audit session, watch,
  registered, ptrauth), `port` (a name in the caller's space), `which`
  (special-port number / exception mask), `behavior`, `flavor`. Rights are
  copied as COPY_SEND from the caller. Throws `DarwinErrnoError`.
- `func terminateTask()` — teardown in `processes.md` §4.6 order (lock held).
- the sender identity for trailers comes from the **sending** kernel's
  `pid`, `pidVersion`, uid/gid (`processes.md` §4.5).
- task-port traps `task_name_for_pid` (−44), `task_for_pid` (−45),
  `pid_for_task` (−46) are handled in `MachIPC.handleTrap`; M looks
  processes up with `system.kernel(forPID:)`.
- Ycode-private Mach routines (`host-libraries.md` §10): **n = 8**
  `mach_ports_register3(task, p0, p1, p2)`, **n = 9**
  `mach_ports_lookup3(task, &p0, &p1, &p2)`; the task argument may name
  another task's control port.
- fileports (BSD 430/431, `processes.md` §4.9) are M's, using F's
  `openFile(for:)`/`install(_:closeOnExec:)`. BSD calls reach M only
  through P's `processCall`, which forwards 430/431 to the pinned
  `MachIPC.fileportCall(_:_:fileSystem:memory:)` (stub in
  `MachIPCSystem.swift`; returns nil for other numbers).

## 4. Process layer (agent P)

Implements `processes.md` §1 (kernel side), §2, §3.5 lookups for M, and the
wiring:

1. `DarwinSystem`: process table, pid allocation (§2 item 7 above), pid 1,
   process groups and sessions, `spawnInitialProcess`, `processExited`.
2. **Shared lock fixes** in `KernelSync.swift`: `blockingObserver` and
   `terminate()` must be per process (a context knows its kernel; P adds
   what it needs to `ThreadContext`). Termination of one process must not
   interrupt another process's waits.
3. `posix_spawn` (244): parse the descriptor, attributes, file actions, and
   port actions (layouts `processes.md` §1.2–§1.8); order of operations
   §1.10; build the child: `fileSystem.makeChildCopy()`, file actions,
   CLOEXEC handling, new `DarwinKernel(system:)` with the new pid,
   `machIPC.inheritTaskPorts(from:)` + `applySpawnPortActions`, signal
   mask/defaults (§1.11), then `system.launcher.launch`. Errors per §1.13;
   a failed spawn leaves no trace.
4. SETEXEC and `execve` (59) / `__mac_execve` (380): same pid, new kernel
   (empty port space + inherited ports), pid version bump, `NOTE_EXEC`,
   close-on-exec, the caller ends with `.outcome(.imageReplaced)`; the old
   image's other threads are stopped (`stopAllThreads`).
5. Exit (§2.4): `machIPC.terminateTask()`, `fileSystem.closeAll()`,
   reparent children to pid 1, `NOTE_EXIT` to watchers (with status for
   NOTE_EXITSTATUS), zombie (or immediate reap with SIGCHLD ignored /
   SA_NOCLDWAIT), SIGCHLD to parent (`EVFILT_SIGNAL`), wake `wait4`
   waiters, `processExited`. A fatal outcome or a default-action signal is
   an exit by signal.
6. `wait4` (7/400), `waitid` (173/416) incl. WNOHANG, WUNTRACED (stopped is
   optional), rusage zeroed.
7. `kill` (37) to any pid/group, `terminate_with_payload` (520), stop/
   continue default actions (optional), `getppid`, `getpgrp`, `setpgid`,
   `getpgid`, `setsid`, `getsid`.
8. kevent (`KEvent.swift`): `EVFILT_PROC` (§2.8), `EVFILT_SIGNAL`,
   `EVFILT_READ`/`EVFILT_WRITE` on `KernelDescriptorObject`s, and `kqueue()`
   (362) as a descriptor object (closes the 4a gap).
9. `proc_info` (336) per §6 item 11 of `processes.md` (LISTPIDS, PIDINFO
   3/4/11/13/17/18/21 as far as it has data, DIRTYCONTROL, TERMINATE).
10. `pid_suspend`/`pid_resume` and START_SUSPENDED: optional.

Owns: `Sources/YcodeDarwinKernel/DarwinKernel.swift`, `ExtendedBSD.swift`,
`KEvent.swift`, `KernelSync.swift`, `Threads.swift`, `Workqueue.swift`,
`ULock.swift`, `Semaphores.swift`, everything in `Process/`, and new tests
`Tests/YcodeDarwinKernelTests/Process*Tests.swift`.

## 5. Mach between tasks (agent M)

Implements `processes.md` §3 and §4:

1. Split the space from the engine: port objects are shared by all spaces
   of a system; each `MachIPC` keeps its own name table and reverse map;
   a port knows which space holds its receive right (if any). Messages,
   wakeups, and `messageQueuedHandler`/`receiveRightGoneHandler` go to the
   space that holds the receive right.
2. One host port and one bootstrap kernel object per system (in
   `MachIPCSystem`); the root task's bootstrap special port is it (as in
   4a: name `0x503`, sends to it still fail with `MACH_SEND_INVALID_DEST`
   until 4c gives it a server).
3. `.task` kernel objects carry the task's identity (the kernel); task
   ports of other tasks work as targets of the private Mach routines where
   `processes.md` §4.3 says so.
4. Cross-task send: copyin in the sender space, copyout in the receiver
   space; OOL memory is a snapshot at send time (§4.4); trailers carry
   the sender's identity (§4.5).
5. Special and registered ports per task, inheritance, port actions
   (§3.2–§3.4); private traps 5/6 per task; n = 8/9 (§3.7).
6. `terminateTask()` (§4.6), exec (§4.7), exception ports stored only
   (§4.8), fileports (§4.9), task-port traps (§3.5).

Owns: `Sources/YcodeDarwinKernel/MachIPC*.swift` (all of them, including
`MachIPCSystem.swift`), and new tests `Tests/YcodeDarwinKernelTests/MachTask*Tests.swift`
(existing `MachIPC*Tests`/`MachRoutineTests` may be updated by M).

## 6. Descriptors (agent F)

Implements `processes.md` §5 plus pipes and dup:

1. `DarwinFileSystem`: open file descriptions shared by dup and inheritance,
   object nodes, the §3.5 API. Existing host-file behavior unchanged.
2. `pipe` (42), `dup` (41), `dup2` (90), `fcntl` `F_DUPFD`/`F_DUPFD_CLOEXEC`,
   `fstat` of objects, `read`/`write`/`readv`/`writev`/`close` on objects,
   O_NONBLOCK (EAGAIN), EOF, EPIPE + `postSignal(SIGPIPE)` unless
   `SO_NOSIGPIPE`/`MSG_NOSIGNAL`-equivalents apply.
3. AF_UNIX `SOCK_STREAM` and `SOCK_DGRAM`: `socket` (97), `socketpair`
   (135), `bind` (104), `listen` (106), `accept` (30/404), `connect`
   (98/409), `sendto`/`recvfrom` (133/29), `sendmsg`/`recvmsg` (28/27, 402/
   401) with `SCM_RIGHTS` (§5.5), `shutdown` (134), `getsockname`/
   `getpeername` (32/31), `setsockopt`/`getsockopt` (105/118) for
   SO_NOSIGPIPE, SO_SNDBUF/RCVBUF, SO_TYPE, SO_ERROR, LOCAL_PEERPID/
   PEERCRED/PEERTOKEN (from the peer kernel's pid and identity at connect
   time). A bound path creates a visible socket node in the guest VFS
   (`stat` shows `S_IFSOCK` is ideal; a placeholder file is acceptable) and
   `unlink` removes the binding. `AF_INET`/`AF_INET6`: EAFNOSUPPORT for now.
   `sendto` keeps 4a's log-the-text behavior only for unconnected
   `AF_UNIX` datagrams to `/var/run/syslog`-like paths that have no binder
   (it must not break `hello`).
4. Blocking operations wait on `WaitQueue`s of the kernel lock and return
   EINTR when interrupted.
5. Readiness observers for P's kevent.

Owns: `Sources/YcodeDarwinABI/DarwinFileSystem.swift`,
`Sources/YcodeDarwinABI/DescriptorObject.swift`, everything in
`Sources/YcodeDarwinKernel/Descriptors/`, and new tests
`Tests/YcodeDarwinKernelTests/Descriptor*Tests.swift`,
`Tests/YcodeDarwinABITests/FileSystem*Tests.swift` (may update the
existing `FileSystemTests`).

## 7. VMM (agent V)

1. Refactor `runExec` into a reusable image builder that implements
   `ProcessLauncher`: any number of images, each its own VM, `VCPUPool`,
   `PoolThreadHost`, image map and trace prefix (`[pid N]` on every trace
   line when more than one process exists).
2. The host process: builds the `DarwinSystem`, sets `launcher`, calls
   `spawnInitialProcess`, and exits when pid 100 exits (`processExited`),
   or on `--timeout-ms`. The summary lists every process (pid, status,
   trap count).
3. VM teardown: `.exit`/`.fatal`/`.imageReplaced` and a terminated kernel
   end the image's vCPUs (all of them, via `stopAllThreads` kicks), join
   or park their host threads, and free the VM, its memslots, and its
   16 GiB pool reservation. `VCPUPool.blockForever` must go: pool threads
   exit. Running 50 short-lived processes in sequence must not leak host
   threads or memory (V adds a check for this, e.g. a debug counter in the
   summary).
4. The directory of the `--exec` program is a read-only VFS prefix at the
   same guest path (§2 item 6).
5. `apple[]` gets `executable_path=<guest path>` and whatever 4a already
   puts there; `ProcessImageRequest.apple` strings are appended.

Owns: `Sources/ycode-simd/*` (may split `main.swift` into several files),
`Sources/YcodeHypervisor/*`, `Sources/CKVM/*`.

## 8. Host library and probes (agent L)

1. `libsystem_kernel` (`ycode/SimHostLibs/kernel/`): `posix_spawn`,
   `posix_spawnp`? (only if the surface lists it), every
   `posix_spawnattr_*`/`posix_spawn_file_actions_*` the surface lists with
   importers, per `processes.md` §1.14 (defaults, validation, the
   descriptor of §1.2); `mach_ports_register`/`lookup` over n = 8/9; libproc
   functions the surface lists (`proc_listpids`, `proc_listchildpids`,
   `proc_name`, `proc_pidpath`, `proc_pidinfo` exists, `proc_terminate`,
   `proc_set_dirty`… as listed); `bootstrap_port` initialization at library
   init from `task_get_special_port(TASK_BOOTSTRAP_PORT)` (and the fork/
   spawn child path, if any); any socket/wait wrappers the generated table
   still lacks.
2. Probes of §1 under `ycode/SimShim/guest-tests/stage4b/` and
   `build-stage4b.sh` (pattern: `build-stage4.sh`).
3. Keep `abi_check` green (DarwinPCS on every build).

Owns: `ycode/SimHostLibs/**`, `ycode/SimShim/guest-tests/stage4b/**`,
`ycode/SimShim/guest-tests/build-stage4b.sh`.

## 9. Rules for every agent

- Clean room: read only `specs/`, public documentation, Apple open source
  (xnu etc.), and this repository's `ycode/`. **Never open
  `.claude/Xcode.app`, `research/dirty/`, Ghidra projects, or any Apple
  binary.** No Apple code in `ycode/`.
- Edit only the files you own. Need something in another agent's file?
  Write it down in your report (or a `// CONTRACT-REQUEST:` note in your
  own file); the orchestrator routes it. Do not edit `Package.swift`
  (orchestrator) — a new source file in an existing target directory needs
  no manifest change.
- Builds on macOS: `swift build --scratch-path /tmp/yc-4b-<agent>`. On the
  Thor: your own checkout `$YCODE_DATA/work/4b-<agent>/`
  (rsync from your Mac tree, excluding `.build`); runtime root
  `$YCODE_DATA/runtimes/iOS-27.1-24A94401/RuntimeRoot`.
- SSH with keys only (`<user>@<arm64-linux-host>`,
  `<user>@<x86-64-linux-host>`). Never read `.env`, never use a password, never
  sudo. The Thor is shared: touch only your own work directory and
  <user>'s files; leave the other USB drives alone.
- Do not commit. Report: files changed, what works (with commands and
  output you actually ran), what does not, contract requests.

## 10. Resolutions

(Filled in by the orchestrator as the stage proceeds.)
