# Spec: `launchd_sim`, the simulator's init, and what its host provides

Status: **reference** for stage 6 of `docs/SIMULATOR-LINUX.md`
("launchd_sim plus the core daemons"). Modern launchd is not open source.
Every fact here comes from black-box observation of the iOS 27.1 runtime
(24A94401) under CoreSimulator 1174.9.2 on macOS, and from binary metadata
(levels 3 and 4). The spec states behavior, file formats, names, and
environment. It does not describe launchd's internal algorithms. §8 is
Ycode's own design guidance.

Terms:

- **RR**: the runtime's RuntimeRoot directory.
- **DEV**: the device directory, `~/Library/Developer/CoreSimulator/Devices/<UDID>`.
  `DEV/data` is the guest's writable world.
- **TMP**: `/private/var/tmp/com.apple.CoreSimulator.SimDevice.<UDID>`, a
  per-device host directory (mode 0700).
- **device launchd name**: `com.apple.CoreSimulator.SimDevice.<UDID>`
  (upper-case UDID with dashes).
- **host**: everything outside the guest. On macOS that is host launchd,
  CoreSimulatorService, its trampolines and helpers. On Linux it is Ycode.

## 1. Role

`launchd_sim` (`RR/sbin/launchd_sim`) is the guest's process 1 in all but
pid: it owns the guest's bootstrap namespace, loads job plists, starts and
supervises every guest daemon and app, and answers bootstrap and XPC
service lookups. It is not the host's launchd. It runs as an ordinary
process of the host user (uid 501 in the observation; never root), and the
host keeps a single control channel to it (§6).

Binary facts:

- Mach-O arm64, platform 7 (iOS simulator), minos 27.1. It is loaded by
  `dyld_sim` like any guest program and uses the three host libraries
  (`libsystem_kernel`, `libsystem_platform`, `libsystem_pthread`) and the
  sim shared cache. It links libSystem, libobjc, and Swift runtime
  libraries.
- It does **not** load `liblaunch_sim.dylib` (§6.2).
- Every job is started through `RR/usr/libexec/xpcproxy_sim` (platform 7).
  `RR/usr/libexec/xpcproxy` is a symlink to it.

## 2. How it is started

### 2.1 Command line

```
argv[0] = "launchd_sim"
argv[1] = <absolute path of the bootstrap plist>
```

The plist path used by CoreSimulator is `DEV/data/var/run/launchd_bootstrap.plist`.
No other arguments.

### 2.2 Environment

`launchd_sim`'s environment is the bootstrap plist's `Bootstrap.Self`
dictionary (§3), verbatim, plus:

| Variable | Value |
|---|---|
| `XPC_SERVICE_NAME` | the device launchd name |
| `XPC_FLAGS` | `0x0` |
| `OSLogRateLimit` | `64` |
| `USER`, `LOGNAME`, `SHELL`, `__CF_USER_TEXT_ENCODING` | the host user's values (ordinary login defaults; not required as far as observed) |
| `XPC_SIMULATOR_HOLDING_TANK_FD_HACK`, `XPC_SIMULATOR_HOLDING_TANK_HACK` | an fd number (5) and a pid; see §9 |

On macOS, two trampoline programs exec in turn before `launchd_sim`
(`simulator-trampoline` from CoreSimulator, then
`RR/sbin/launchd_sim_trampoline`, a macOS-platform binary). The observable
net effect is: same pid, argv as above, environment as above. A host that
starts `launchd_sim` directly with that argv and environment reproduces the
result. The trampolines' other side effects (a code-signature check and a
TCC "responsible process" call) are macOS policy and are not needed by the
guest.

### 2.3 Inherited file descriptors

| fd | Expected content |
|---|---|
| 0, 1 | `/dev/null` |
| 3 | `/dev/console`, write-only (observed; not proven required) |
| 5 | see §9 (a Unix socket connected to the syslog socket) |

`launchd_sim` opens the rest itself: its log file, the syslog socket, and
the secure sockets (§5.4). Its working directory is `/`.

### 2.4 Inherited Mach state

- Its **task bootstrap port** is the host's bootstrap port (the host user
  domain). `launchd_sim` checks in the device launchd name there and
  receives the receive right for its control endpoint (§6.1). The host job
  that starts it advertises that name as a Mach service, so messages sent
  before `launchd_sim` runs are queued, and the first message is what
  demand-starts it on macOS.
- Normal host-kernel special ports (host, task self).

## 3. The bootstrap plist

A property list (CoreSimulator writes XML) with these keys. All are
interop facts: Ycode must write this file.

Top level:

| Key | Type | Value used by CoreSimulator |
|---|---|---|
| `Bootstrap` | dict | see next table |
| `AbortOnUnknownIPC` | bool | true |
| `CrashOnSIGTERMTimeout` | bool | true |
| `ExtensionWatchdog` | integer | 0 |
| `LogServiceLifecycle` | bool | true |
| `LogToFlatFile` | bool | true: `launchd_sim` writes `TMP/launchd.log` |
| `RequireDomainBinding` | bool | true |
| `SIGTERMTimeout` | integer | 3 (seconds) |
| `UseGuardMalloc` | bool | false |

`Bootstrap`:

| Key | Type | Meaning |
|---|---|---|
| `SimulatorRuntimeRoot` | string | RR. Plist program paths are resolved under it (§4.4) |
| `Paths` | array of strings | job directories, scanned in order (§4.1) |
| `Self` | dict string→string | `launchd_sim`'s own environment (§2.2) |
| `Child` | dict string→string | environment given to every job |
| `ChildDefaults` | dict string→string | default environment for jobs (5 keys) |
| `BinaryOrderPreference` | string | `arm64` |
| `CheckedAllocationsPosixSpawnFlagsGlobal` | bool | false |

`Self` = `Child` ∪ `ChildDefaults` (38 keys in the observation).

`ChildDefaults` keys: `CFFIXED_USER_HOME`, `HOME` (both `DEV/data`),
`TMPDIR` (`DEV/data/tmp/`), `DYLD_FALLBACK_FRAMEWORK_PATH`
(`RR/System/Library/Frameworks`), `DYLD_FALLBACK_LIBRARY_PATH`
(`RR/usr/lib`).

`Child` keys (33):

| Key | Value |
|---|---|
| `DYLD_ROOT_PATH`, `IPHONE_SIMULATOR_ROOT`, `SIMULATOR_ROOT` | RR |
| `DYLD_SHARED_CACHE_DIR` | `RR/System/Library/Caches/com.apple.dyld` |
| `PATH` | `RR/usr/bin:RR/bin:RR/usr/sbin:RR/sbin:RR/usr/local/bin` |
| `IPHONE_SHARED_RESOURCES_DIRECTORY`, `SIMULATOR_SHARED_RESOURCES_DIRECTORY` | `DEV/data` |
| `XPC_SIMULATOR_LAUNCHD_NAME` | the device launchd name |
| `LS_ENABLE_BUNDLE_LOCALIZATION_CACHING` | `1` |
| `SIMULATOR_UDID`, `SIMULATOR_DEVICE_NAME` | device identity |
| `SIMULATOR_MODEL_IDENTIFIER`, `SIMULATOR_PRODUCT_CLASS`, `SIMULATOR_LEGACY_ASSET_SUFFIX` | device-type identity (e.g. `iPhone19,4`, `V68`, `iphone`) |
| `SIMULATOR_MAINSCREEN_WIDTH`, `…_HEIGHT`, `…_SCALE`, `…_PITCH` | screen geometry (integers; scale and pitch as `%f` decimals) |
| `SIMULATOR_CAPABILITIES` | path of the device type's `capabilities.plist` |
| `SIMULATOR_RUNTIME_VERSION`, `SIMULATOR_RUNTIME_BUILD_VERSION` | e.g. `27.1`, `24A94401` |
| `SIMULATOR_ARCHS` | `arm64` |
| `SIMULATOR_VERSION_INFO` | one human-readable line (host version, device, runtime, device type) |
| `SIMULATOR_BOOT_TIME` | boot time, Unix seconds |
| `SIMULATOR_HOST_HOME` | host user's home |
| `SIMULATOR_LOG_ROOT` | `~/Library/Logs/CoreSimulator/<UDID>` |
| `SIMULATOR_FRAMEBUFFER_FRAMEWORK`, `SIMULATOR_HID_SYSTEM_MANAGER` | host paths of framebuffer and HID client frameworks |
| `SIMULATOR_AUDIO_DEVICES_PLIST_PATH` | `DEV/data/var/run/com.apple.coresimulator.audio.plist` |
| `SIMULATOR_AUDIO_SETTINGS_PATH` | `DEV/data/var/run/simulatoraudio/audiosettings.plist` |
| `SIMULATOR_MEMORY_WARNINGS` | `DEV/data/var/run/memory_warning_simulation` (an empty file) |
| `SIMULATOR_EXTENDED_DISPLAY_PROPERTIES`, `IPHONE_TVOUT_EXTENDED_PROPERTIES` | `DEV/data/Library/Application Support/Simulator/extended_display.plist` |

Other files the host prepares in `DEV/data/var/run/` before boot:
`com.apple.coresimulator.audio.plist` (keys `sim_input_device_uid`,
`sim_output_device_uid`, `useHostDefaultInputDevice`,
`useHostDefaultOutputDevice`), the empty `memory_warning_simulation`, and
the `simulatoraudio/` directory.

## 4. Job model

### 4.1 Discovery

`launchd_sim` imports every `*.plist` in the `Bootstrap.Paths`
directories. CoreSimulator passes, in order:

1. `RR/System/Library/LaunchDaemons` (329 plists in iOS 27.1)
2. `RR/System/Library/LaunchAngels` (25)
3. `RR/Developer/Library/LaunchDaemons` (1)
4. `DEV/data/Library/LaunchDaemons` (9, written by the host at device
   creation; §4.5)

`RR/System/Library/LaunchAgents` is not passed. 364 plists give 363
distinct labels.

Import rules (observed):

- Unknown keys and values of the wrong type are reported in the log and
  ignored; the job still loads.
- A **feature-flag conditional** may replace any value: a dictionary with
  exactly one of `#IfFeatureFlagEnabled` / `#IfFeatureFlagDisabled` (value
  a `Domain/FlagName` string) and the branches `#Then` and optionally
  `#Else`. Conditionals nest. Seen under `UserName`, `Disabled`,
  `LimitLoadToSessionType`, and individual `MachServices` entries.
- `Disabled = true` jobs are not loaded. Neither are jobs restricted to
  another OS variant or to a session type other than `System` or the
  default.
- A MachServices name declared by two different jobs: the later import
  reports that the endpoint already has an owner, and the first owner keeps
  it. At run time, a process that tries to register an endpoint owned by
  another job is refused.

### 4.2 Domains

| Domain | Session name | Contents |
|---|---|---|
| `system` | `System` | jobs whose `LimitLoadToSessionType` evaluates to `System` (7 in iOS 27.1: logd, logd_helper, diagnosticd, notifyd, deviceconfigurationd, containermanagerd.system, cfprefsd.xpc.daemon.system) |
| `user/<uid>` | `iOSUser` | every other job (350 of the plist jobs), one-shot jobs, app jobs, user-domain XPC services. `<uid>` is `launchd_sim`'s own uid |
| `pid/<pid>` | — | one per guest process that talks to `launchd_sim`; holds that process's private XPC services and dynamic endpoints; removed at exit |

- `UserName`/`GroupName` do not change credentials: every guest process
  runs as `launchd_sim`'s uid.
- Name lookups from `user/<uid>` fall through to `system`.
- Each domain has its own bootstrap port; `launchctl print` names them
  `com.apple.xpc.launchd.domain.system` and
  `com.apple.xpc.launchd.domain.user.<uid>`.
- Each domain may carry an **environment** that is added to its jobs'
  environment (§5.4). Per-label enable/disable overrides are stored in
  `TMP/disabled.plist`: a flat dictionary label → bool, `false` meaning
  enabled.

### 4.3 Plist keys in use

Counts over the 364 iOS 27.1 plists. Ycode does not implement these (the
real `launchd_sim` does); the table sizes what the runtime relies on.

| Key | Count | Values seen |
|---|---|---|
| `Label` | 364 | |
| `MachServices` | 348 | 1,512 names; value `true`, or a dict with `ResetAtClose`, `HideUntilCheckIn`, `_ExperimentalNonLaunching`, or `HostSpecialPort` (an integer) |
| `EnablePressuredExit` | 324 | |
| `UserName` | 307 | mostly `mobile` |
| `EnableTransactions` | 288 | |
| `ProgramArguments` / `Program` | 287 / 105 | guest-absolute paths |
| `LaunchEvents` | 213 | ~30 stream names; most common `com.apple.notifyd.matching`, `com.apple.xpc.activity`, `com.apple.bg.system.task`, `com.apple.distnoted.matching` |
| `POSIXSpawnType` / `ProcessType` | 201 / 157 | Adaptive, Interactive, App, Background, Standard |
| `RunAtLoad` | 78 | 23 true |
| `KeepAlive` | 66 | bool, or dict with `PathState`, `Crashed`, `SuccessfulExit`, `AfterInitialDemand` |
| `EnvironmentVariables` | 65 | |
| `ThrottleInterval` | 40 | |
| `PublishesEvents` | 28 | |
| `_AdditionalProperties` | 27 | `RunningBoard` |
| `Disabled` | 12 | |
| `LimitLoadToSessionType` | 11 | |
| `RootedSimulatorPath` | 9 | true (§4.4) |
| `Sockets` | 3 | §5.4 |

Two jobs request `HostSpecialPort` values 30 and 34 for one of their
MachServices.

### 4.4 Spawning a job

- The executable path is `SimulatorRuntimeRoot` + the plist's guest path,
  unless the plist has `RootedSimulatorPath = true`, in which case the path
  is used as is (a host path). For rooted jobs, argv[0] still appears as a
  guest-style path.
- `launchd_sim` spawns `xpcproxy_sim`, which prepares the process and
  becomes the job's program in the same pid. All guest processes are direct
  children of `launchd_sim`.
- stdin, stdout, and stderr are `/dev/null` for daemons.
- Each process's task bootstrap port is set at spawn to a send right for
  its domain's bootstrap port (observed for a `user/<uid>` one-shot job;
  assumed the same for `system` jobs). Guest code reads it as the bootstrap
  task special port; the `bootstrap_port` global holds the same name.
- **Job environment** = `Child` ∪ `ChildDefaults` ∪ the domain's
  environment ∪ `IOS_SIMULATOR_SYSLOG_SOCKET` ∪ `XPC_SERVICE_NAME=<label>`
  ∪ `XPC_FLAGS=0x0` ∪ the plist's `EnvironmentVariables`. Jobs in `system`
  do not get the `user/<uid>` domain environment.
- One-shot jobs (created by the host's spawn operation, §6.1) are labelled
  `com.apple.xpc.launchd.oneshot.0x<8 hex digits>.<program name>` and live
  in `user/<uid>`. The caller's stdio file descriptors are passed through.

### 4.5 Jobs the host contributes

The host writes nine plists into `DEV/data/Library/LaunchDaemons` when it
creates the device. All have `RootedSimulatorPath = true` and point at host
programs: the CoreSimulator bridge (`com.apple.CoreSimulator.bridge`,
KeepAlive, MachServices including `com.apple.CoreSimulator.host_support`
and `com.apple.CoreSimulator.SimPasteboardInterface`) and eight CoreDevice
helpers (`com.apple.coredevice.dt*`). These programs are simulator-platform
binaries shipped with the host tools. Ycode may omit them or supply its own.

### 4.6 Boot sequence

1. `launchd_sim` creates `system`, then `user/<uid>`. Both start in a
   "bootstrap" phase and an "on-demand only" phase.
2. It imports the plists (≈ 45 ms for 364 plists).
3. During the bootstrap phase it starts only (a) jobs it treats as system
   support (here `UserEventAgent-System` and `SpringBoard`) and (b) jobs
   whose socket receives a connection (`logd`, through the syslog socket).
   KeepAlive and RunAtLoad jobs are held.
4. `user/<uid>` leaves both phases first and releases its held jobs at once
   (37 spawns in 12 ms). Then `system` leaves them (`deviceconfigurationd`,
   `notifyd`).
5. From then on, jobs start on demand: Mach lookup or message, XPC event
   streams, events published by other jobs, semaphores. Launch-reason mix
   over 10 minutes (490 launches): Mach IPC 18 %, explicit job demand 14 %,
   XPC event 10 %, speculative (held KeepAlive/RunAtLoad) 5 %, event
   publisher 2 %, sockets, semaphores, one-shots.
6. Observed rate: 23 jobs running after 1 s, 170 after 28 s (when the
   host's boot-status check completes), 486 after 10 minutes.

## 5. The guest-side bootstrap interface (observable facts)

### 5.1 Lookup

- `bootstrap_look_up(bootstrap_port, name)` returns `KERN_SUCCESS` and a
  send right for any advertised name in the caller's domain chain,
  including host-side names (§6.3). If the name's job is not running, the
  lookup still succeeds and the job is started on the first message.
- An unknown name returns **1102** (`BOOTSTRAP_UNKNOWN_SERVICE`, 0x44e). A
  job that is loaded but does not advertise the name also gives 1102.
- XPC (`xpc_connection_create_mach_service`) to an unknown name ends with
  the "connection invalid" error promptly.
- `launchd_sim` distinguishes legacy bootstrap lookups from XPC lookups (it
  logs them with and without a flags value of 1).

### 5.2 Check-in and dynamic registration

- `bootstrap_check_in` of a name the caller's job advertises returns its
  receive right.
- `bootstrap_check_in` of an **unknown** name by an ordinary guest process
  also succeeds: `launchd_sim` creates the name and returns a new receive
  right; later lookups of that name succeed.

### 5.3 Per-process domains and XPC services

- On a process's first message, `launchd_sim` creates `pid/<pid>`.
- Bundled XPC services (`XPCServices` directories of frameworks the
  process loads) are bootstrapped into that domain. They are created as
  stubs and become real endpoints on first lookup. Bundles without a valid
  `XPCService` dictionary or executable are rejected and logged.

### 5.4 Sockets that `launchd_sim` creates

- **System log socket.** For the job whose `Sockets` entry has
  `SystemLoggingSocket = true` (logd), `launchd_sim` creates a Unix-domain
  listening socket at `TMP/syslogsock` and hands the descriptor to that
  job. The path is exported to every job as `IOS_SIMULATOR_SYSLOG_SOCKET`.
- **Secure sockets.** For each `Sockets` entry with `SockFamily = Unix` and
  `SecureSocketWithKey = <VAR>`, `launchd_sim` creates a Unix listening
  socket at `/private/var/tmp/com.apple.launchd.<10 random alphanumerics>/<entry name>`
  (directory 0700, socket 0666), and sets `<VAR>` to that path in the
  domain environment. iOS 27.1 defines `RWI_LISTEN_SOCKET` (webinspectord),
  `TESTMANAGERD_SIM_SOCK` and `TESTMANAGERD_REMOTE_AUTOMATION_SIM_SOCK`
  (testmanagerd). Host tools connect to these paths.

### 5.5 `launchctl` inside the guest

`RR`'s `launchctl`, run as a guest process, talks to `launchd_sim` and
supports `print system`, `print user/<uid>`, `print pid/<pid>`,
`print <domain>/<label>`, and `list`. This is the simplest end-to-end test
of a running `launchd_sim`.

### 5.6 Log file

With `LogToFlatFile`, `launchd_sim` appends to `TMP/launchd.log` lines of
the form `YYYY-MM-DD HH:MM:SS.ffffff (<domain>[/<label>] [<pid>]) <Level>: <text>`.
Per-job lifecycle lines record state changes, spawn reasons, exits, and
failed lookups. This is the main debugging aid when bringing
`launchd_sim` up under Ycode.

## 6. The host side on macOS (what Ycode replaces)

### 6.1 Control channel

- The only host-visible name is the device launchd name, a Mach service in
  the host user domain whose receive right `launchd_sim` holds.
- CoreSimulator does not message it directly. Its helper service
  SimLaunchHost loads the runtime's `liblaunch_sim.dylib` and performs
  these operations for it (operation names as logged by SimLaunchHost):

  | Operation | Purpose (from names and timing) |
  |---|---|
  | `startsession` | at boot, binds the host session to the device: receives the "bind port" from the sim |
  | `findendpoint` | host looks up a guest service by name (e.g. the bridge's host-support service) |
  | `getenv` | host reads a variable from the guest launchd's environment |
  | `spawn` | host starts a guest program as a one-shot job (`simctl spawn`), then reports its exit status |
  | `loadliblaunch` / `unloadliblaunch` | load/unload a runtime's `liblaunch_sim` instance |

- Host services are registered into the guest before `launchd_sim` starts
  serving (§6.3).

### 6.2 `liblaunch_sim.dylib`

- `RR/usr/lib/system/host/liblaunch_sim.dylib`: a **macOS-platform**
  library (platform 1; arm64, arm64e) that runs in host processes and
  depends only on libSystem. Install name
  `@iphonesimulator27.1-3298.2.1/usr/lib/system/host/liblaunch_sim.dylib`,
  version 3298.2.1.
- Exported interface (names are interop facts): `launch_sim_bind_session_to_port`,
  `launch_sim_find_endpoint`, `launch_sim_getenv`,
  `launch_sim_register_endpoint`, `launch_sim_unregister_endpoint`,
  `launch_sim_set_death_handler`, `launch_sim_spawn`,
  `launch_sim_waitpid`, plus spawn-attribute and binary-preference
  serialization helpers (`xpc_binprefs_*`, `_xpc_spawnattr_*`).
- It is the host's client library for the control channel. Its wire format
  is private to the pair (`liblaunch_sim` ↔ `launchd_sim`, same project
  version 3298.2.1). No guest process loads it, and
  `/usr/lib/system/host/` does not exist on the host.

### 6.3 Host-side endpoints

The host registers send rights for host services into the guest's
`user/<uid>` domain. They appear as dynamic endpoints of an unmanaged
pseudo-process named `com.apple.xpc.launchd.simhost`, flagged
"host-side". The registration first looks the name up in the host's own
bootstrap; a name with no host service is skipped. iOS 27.1 boot
registered 27 names:

| Group | Names |
|---|---|
| CoreSimulator | `com.apple.CoreSimulator.host.bootstrap_port` (the host bootstrap port itself), `com.apple.CoreSimulator.SimFramebufferServer`, `com.apple.CoreSimulator.SimCaptureService`, `com.apple.CoreSimulator.SimIdentityService`, `com.apple.CoreSimulator.NearbyInteraction`, `IndigoHIDRegistrationPort` |
| GPU | `com.apple.metal.simulator`, and one shared port under `com.apple.metal.simulator.SpringBoard`, `.SBRendererService`, `.backboardd`, `.PineBoard`, `.HeadBoard`, `.Carousel`; `com.apple.IOSurface.Remote`; `com.apple.gputools.service.simulator` |
| Audio | `com.apple.audio.coreaudiod`, `com.apple.audio.audiohald` |
| System | `com.apple.SystemConfiguration.configd` and `com.apple.SystemConfiguration.configd_host` (one port), `com.apple.SystemConfiguration.PPPController`, `com.apple.PowerManagement.control`, `com.apple.FSEvents` |
| Other | `com.apple.FileProvider.sim2host`, `com.apple.storekitservice.sim2host`, `com.apple.modelmanager.simulator`, `com.apple.coreservices.lsuseractivity.simulatorsupport`, `com.apple.fpsd.sim` |

Two more names were attempted and skipped (`com.apple.gputools.agent.producer.sim`,
`com.apple.ist.ds.appleconnect.service.sim2host`). Several of these are
the host ends of the CoreSimulator I/O bundles (framebuffer, HID, audio,
GPU).

## 7. What the host must provide (requirements for Ycode)

### 7.1 For `launchd_sim` to start and serve (no daemons)

1. **Files.** The bootstrap plist (§3); `TMP` existing and writable (for
   `launchd.log`, `syslogsock`, `disabled.plist`); `/private/var/tmp`
   writable (secure sockets); `DEV/data` with `tmp/`, `var/run/`,
   `Library/LaunchDaemons/`; `/dev/null`, `/dev/console`.
2. **Process start.** argv and environment per §2; fds 0/1 = `/dev/null`;
   cwd `/`.
3. **A host bootstrap port** as `launchd_sim`'s task bootstrap special
   port. It must accept `bootstrap_check_in` of the device launchd name
   and return a receive right (the control endpoint). It should answer
   `bootstrap_look_up` for the names in §6.3 that Ycode chooses to provide,
   and 1102 for others.
4. **Kernel personality.** Beyond what stage 3 provides: Mach port
   construction, insert/extract right, guards, contexts, dead-name and
   port-destroyed notifications, port sets and `mach_msg` with receive
   timeouts; `task_set_special_port`/`task_get_special_port`;
   `mach_ports_register`; `posix_spawn` with the Apple extensions
   (registered ports, special ports, process type, arch preference,
   importance port, Darwin role) or an equivalent that `xpcproxy_sim`
   accepts; `proc_pidinfo`, `proc_listchildpids`, `proc_pid_rusage`,
   `proc_terminate`, `proc_get_dirty`; `memorystatus_control`; `csops` /
   `csops_audittoken` answering "valid, platform"; `sysctlbyname`;
   AF_UNIX sockets (bind/listen/accept/connect) and listening-socket
   descriptors inherited across spawn; kqueue with
   process-exit and Mach-port filters (libdispatch); `task_name_for_pid`.
   This list comes from `launchd_sim`'s imports; which calls are on the
   boot-critical path is not yet known.

### 7.2 For the core daemons and SpringBoard

5. **Host-side services** (§6.3), each either emulated or deliberately
   absent. Absent names cost failed lookups (1102), which the runtime
   mostly tolerates; the display, HID, GPU, and audio names are needed for
   a visible UI. Priority for a headless boot: none. For a visible
   SpringBoard: `SimFramebufferServer`, `IndigoHIDRegistrationPort`,
   `com.apple.metal.simulator*`, `com.apple.IOSurface.Remote`.
6. **A control channel** equivalent to §6.1 for Ycode's own tools: at
   least "spawn a one-shot program with my stdio" and "look up a guest
   endpoint". Ycode can implement this inside its VMM instead of through
   `liblaunch_sim`.
7. **Bridge jobs** (§4.5): optional.

## 8. Ycode design notes (not observations)

- Ycode should not try to run `launchd_sim_trampoline` or
  `liblaunch_sim.dylib`: both are macOS-platform binaries. Ycode's VMM
  performs the trampoline's job (§2) and owns the host end of the control
  endpoint.
- The simplest bring-up path: (1) start `launchd_sim` with a bootstrap
  plist whose `Paths` points at an empty directory, and check
  `TMP/launchd.log` for domain creation; (2) run the guest `launchctl print
  system` as a one-shot; (3) add `Paths` entries for logd and notifyd only;
  (4) then the full RR directories.
- Because Ycode is the host, the device launchd name only has to be
  unique within one Ycode VM; Ycode may keep CoreSimulator's naming for
  familiarity.

### 8.1 Simulator log forwarding through diagnosticd (observed, 2026-10-13)

These observations come from Ycode boots of iOS 27.1 (level 3: traces,
Mach traffic counters, diagnosticd's own log file `DEV/data/var/db/
diagnostics/diagnosticd.0.log`). File contents were read as formats (level 2).

1. When diagnosticd starts, it removes
   `DEV/data/Library/Preferences/Logging/com.apple.diagnosticd.filter.plist`.
   It then starts a **system-mode stream client for itself** ("System mode
   client started - diagnosticd (pid) - mode: 0x9, filter: <empty>") and
   writes the filter plist again. The new plist has `global` = 0x9_0007_0000.
   A `log stream` one-shot adds its own client with a `process` filter
   ({name: level}).
2. Every process reads the filter plist when its logging starts. While the
   filter is global, the process sends **every** log message to
   `com.apple.diagnosticd` as an XPC message (Mach id 0x10000000, about
   1 KB). In a 600 s boot, diagnosticd received about 300 000 such
   messages. These were most of the system's Mach messages. diagnosticd made
   about 1000 `kevent_id` calls per second: EVFILT_MACHPORT receives and
   `dispatch_sync` workloop waits. Every one of those waits ended with a real
   `NOTE_WL_SYNC_WAKE`. None of the wakeups was empty.
3. diagnosticd forwards the stream to the host. It connects an AF_UNIX
   stream socket to `/private/var/run/.sim_diagnosticd_socket`. This is a
   host path. On the Mac, CoreSimulator provides it. In Ycode the path does
   not exist, so the connect fails with ENOENT. diagnosticd then logs
   "assertion failed: … diagnosticd + 3176 … 0x2" and tries again later
   (about 1100 failed attempts in 150 s).

Consequences for Ycode:

- The per-message XPC traffic is the guest's own forwarding design, so
  Ycode does not suppress it. It costs much more under Ycode's global kernel
  lock than on the Mac. Cheaper Mach messaging is the lever.
- **Host end of `.sim_diagnosticd_socket` (implemented,
  `Descriptors/HostStreamSockets.swift`).** A guest `connect` of an AF_UNIX
  stream socket to `/private/var/run/.sim_diagnosticd_socket` succeeds at
  once, with no guest listener. The host end consumes and discards what is
  sent, and never sends anything back. Observed use: diagnosticd connects
  once per boot and keeps the connection open. It then makes one `write`
  per forwarded log entry. Each write is a JSON object about 1.1–1.6 KB long:
  `{"action":{"_type":"u","action":6},"entryData":{"_type":"d","entryData":"<base64>"}}`
  (`_type` "u" is an unsigned integer and "d" is data). The base64 payload is
  diagnosticd's binary entry, which is not studied. With the host end in
  place, the reconnect-and-assert loop stops.
- **The host end is off by default (2026-10-16).** While the connection is
  up, diagnosticd encodes and writes every forwarded entry for the whole
  boot. In paired 900 s boots of the integration branch, diagnosticd made
  3–4 times as many traps with the host end (6.8–10.9 M against
  1.9–3.2 M), the busiest log senders (`suggestd`, `parsecd`, `axassetsd`)
  rose with it, and kernel-lock acquisitions grew by 30–90 %. Without the
  host end the connect fails with ENOENT. diagnosticd then logs the
  assertion and retries for about 100 s (about 250 attempts), and then stops
  trying. That costs far less than the stream. Switches:
  `YCODE_SIM_DIAGNOSTICD_SOCKET=1` turns the host end on;
  `YCODE_SIM_DIAGNOSTICD_LOG=1` turns it on and prints the stream's strings;
  `YCODE_DEBUG_NO_HOST_SOCKETS=1` forces it off.

## 9. Open questions

1. The two `XPC_SIMULATOR_HOLDING_TANK_*` variables: fd 5 is a Unix socket
   connected to the syslog socket, and the pid did not exist at the time of
   the check. Is either needed? Test: start without them under Ycode.
2. **Answered:** the guest bootstrap port is `bootstrap-wire.md`; the control channel is `launch-sim-control.md` (MIG base 700).
   Original question: message formats on the control channel (bind/register/find/spawn) and on
   the guest bootstrap port are not visible from metadata. The guest side
   uses the libxpc pipe and MIG-compatible bootstrap messages (import
   names). Ycode's host end must speak the control-channel format; the
   source of that information is still to be chosen (level 1 if Apple's
   open-source libxpc/launchd headers describe it, otherwise targeted
   level-3 capture with a Mach-message tracer on our own probe).
3. Whether `launchd_sim` reads `RR/System/Library/xpc/launchd.plist` (a
   pre-built job cache with a `.sig` file) in addition to scanning `Paths`.
   Needs file-access tracing (root) or a Ycode experiment.
4. What `RequireDomainBinding`, `AbortOnUnknownIPC`, and the
   "bind session" step require of the host. Hypothesis: `launchd_sim`
   refuses guest requests until the host binds the session; test under
   Ycode by omitting the bind. **Partly answered (level 3, stage 4c-iii):**
   with `RequireDomainBinding = true` and no bind, `launchd_sim` defers the
   spawn of `system`-domain jobs indefinitely (`user/<uid>` jobs are not
   affected). Ycode writes `false` until the bind is specified. **Answered (stage 7):** control-channel operation 700 binds the session (`launch-sim-control.md` §3.1); after it `system` leaves bootstrap mode, so Ycode can write `true` once its host binds.
5. ~~The send right in slot 0 of `mach_ports_lookup`~~ **Answered
   (level 3, Ycode runs, stage 4c-iii):** `launchd_sim` registers its
   service port (the receive right it got from the host's 708 reply) in
   registered-port slot 0 and sets its own bootstrap special port to NULL,
   so slot 0 in every child is a send right to `launchd_sim`'s service
   port. `xpcproxy_sim` sends pipe routine 700 (`0x400002BC`) there
   (special reply port, `MACH_RCV_SYNC_WAIT`, one combined `mach_msg2`),
   then `posix_spawn`s the job with `SETEXEC`.
6. Which of the §7.1 kernel calls are on the boot-critical path.
7. How `HostSpecialPort` MachServices are honored without a real host port
   table.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Host job (label, program, args, env, endpoint, demand reason, exec count) §2, §6.1 | 3 | host `launchctl print user/501/<label>` |
| argv, environment of `launchd_sim` §2.1–2.2 | 3 | `ps -E`, compared key by key with the bootstrap plist |
| fds and sockets §2.3, §5.4 | 3 | `lsof`, `ls -la` of the socket directories |
| Port-right summary §2.4 | 3 | `lsmp` (non-root) |
| Bootstrap plist structure §3 | 2 | the plist file read as a format (`plutil -p`) |
| Binary platform, archs, install names, linkage, exports and imports §1, §6.2, §7.1 | 4 | `otool -L/-l`, `lipo -archs`, `nm -gU/-u`, `file` |
| Job directories and counts, plist key statistics, feature-flag conditionals §4.1, §4.3 | 2 | the job plists read as a format (script over `plistlib`) |
| Import tolerance, domain creation, boot order, timings, launch reasons, log format §4.1, §4.6, §5.6 | 3 | `TMP/launchd.log` |
| Domains, session names, services, endpoints, domain environment, disabled overrides, simhost endpoints §4.2, §6.3 | 3 | guest `launchctl print system`, `print user/501`, `print pid/N`, `print <svc>`; `TMP/disabled.plist` |
| Job environment and spawn via xpcproxy_sim §4.4 | 3 | `ps -E` of notifyd, CoreSimulatorBridge, and our probe; launchd.log |
| Bootstrap port, lookups, check-in, XPC lookup §5.1–5.3 | 3 | our probe program `bsprobe` (our own code) run with `simctl spawn` |
| SimLaunchHost operations, liblaunch_sim loading, host registrations §6.1–6.3 | 3 | host `log show` for CoreSimulatorService and SimLaunchHost; `lsof` of SimLaunchHost |
| Requirements and design §7–§8 | — | derived from the above; Ycode design |
| Simulator log forwarding: filter file, system-mode client, per-message XPC sends, host socket path and the JSON entry stream on it §8.1 | 2, 3 | plists and diagnosticd.0.log read as formats; Ycode boot traces (`--trace-name`) and Mach traffic counters (`YCODE_DEBUG_MACH_STATS=1`) |
| Cost of the host end, the retry-then-stop behavior without it, and the default-off choice §8.1 | 3 | paired Ycode boots on the Thor (2026-10-16): per-process trap counts from the exit summary, kernel-lock totals, `diagnosticd.0.log` read as a format |

No disassembly or decompilation was used (level 5 not used). Dirty-room
notes: `research/notes/launchd-sim-observations.md`.
