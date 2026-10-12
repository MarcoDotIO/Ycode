# `launchd_sim`: dynamic observations (2026-10-11)

Dirty-room notes. Method: black-box observation (level 3) and binary
metadata (level 4) only. No disassembly or decompilation was done.

Setup: Xcode 27.1, CoreSimulator 1174.9.2, iOS 27.1 runtime 24A94401,
host macOS Darwin 27.2.0 arm64. A throwaway device "Ycode-Probe-4"
(type `iPhone Duo`, UDID `2CC3F840-…`) was created, booted, probed, then
shut down and deleted. `<RR>` below is the RuntimeRoot
(`…/iOS 27.1.simruntime/Contents/Resources/RuntimeRoot`), `<DEV>` is the
device directory `~/Library/Developer/CoreSimulator/Devices/<UDID>`, and
`<TMP>` is `/private/var/tmp/com.apple.CoreSimulator.SimDevice.<UDID>`.

Tools used: `simctl` (create/boot/spawn/delete), `launchctl print` on the
host and inside the guest (`simctl spawn … launchctl`), `ps -E`, `lsof`,
`lsmp` (non-root), `log show`, `plutil -p`, `otool -L/-l`, `nm -gU/-u`,
`lipo`, and our own probe program `bsprobe` (C, built with the
iphonesimulator SDK; source in the scratchpad, not in the repo). It reports
special ports, registered ports, `bootstrap_look_up`/`bootstrap_check_in`
results, an XPC lookup, its fds, and its environment.

## 1. The process chain that starts `launchd_sim`

- CoreSimulatorService (host XPC service, pid 962) **submits** a job to the
  host `launchd`, in the host domain `user/501`, label
  `com.apple.CoreSimulator.SimDevice.<UDID>`. `launchctl print` on the host
  shows `type = Submitted`, `path = (submitted by com.apple.CoreS[962])`.
- Host job details:
  - program: `/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/simulator-trampoline`
  - arguments (4): `simulator-trampoline`, `<RR>/sbin/launchd_sim_trampoline`,
    `<RR>/sbin/launchd_sim`, `<DEV>/data/var/run/launchd_bootstrap.plist`
  - environment: only `OSLogRateLimit=64` and
    `XPC_SERVICE_NAME=com.apple.CoreSimulator.SimDevice.<UDID>`
  - one endpoint (Mach service in the host domain) with the same name
    `com.apple.CoreSimulator.SimDevice.<UDID>`, `managed = 1`, `reset = 1`.
  - `immediate reason = ipc (mach)`: the job was demand-started by a
    message to that endpoint, not by RunAtLoad.
  - `execs = 3`, `trampolined = 1`, `spawn type = interactive (4)`,
    jetsam priority 40, `properties = legacy timer behavior | launch only once | exponential throttling`.
  - It has its own resource and jetsam coalitions named after the label.
- Exec chain (same pid throughout, 29306): host `xpcproxy` →
  `simulator-trampoline` (host binary in CoreSimulator.framework) →
  `launchd_sim_trampoline` (runtime file, **macOS platform 1**, archs
  arm64/arm64e/arm64e.x1, minos 11.0, links only libSystem and libobjc) →
  `launchd_sim` (runtime file, **iOS-simulator platform 7**, arm64 only,
  minos 27.1).
- In the host log, `simulator-trampoline` (in pid 29306) checks a signature
  (Security framework calls `SecKeyVerifySignature`, trust evaluation) and
  opens an XPC connection to the host service
  `com.apple.CoreSimulator.SimulatorTrampoline`; that service then sets TCC
  "responsible process" for the pid. Which file's signature is checked was
  not determined (candidate: `<RR>/System/Library/xpc/launchd.plist.sig`).
- Final `ps` view: parent pid 1 (host launchd), uid 501 (the user; not
  root), argv = `launchd_sim <DEV>/data/var/run/launchd_bootstrap.plist`
  (argv[0] is the bare name).

### 1.1 Timing (one boot)

| Time | Event |
|---|---|
| 39.157 | CoreSimulatorService activity for the boot request begins |
| 39.733 | CoreSimulatorService has loaded 5 ".simdeviceio" bundles (GPU tools port vendor, audio, stream, legacy HID "Indigo", rendering) with 16 IO ports |
| 39.775 | CoreSimulatorService tries to register host services for the guest; two fail because the host name is not registered (`…gputools.agent.producer.sim`, `…appleconnect.service.sim2host`, error 0x44e) |
| 39.776 | SimLaunchHost-arm64 runs command `startsession` for client 962 and logs that it got a "bind port" from the sim service |
| 39.780 | `xpcproxy` in pid 29306 (host launchd spawning the job) |
| 39.80–39.83 | `simulator-trampoline` signature check, SimulatorTrampoline TCC call |
| 40.120 | first line of `launchd_sim`'s own log file |
| 40.133 | `launchd_sim` "hello" line with its UUID |
| 40.136 | domains `system` and `user/501` created, both in "bootstrap" and "ondemand" mode |
| 40.161 | first spawn: `UserEventAgent-System` (reason "system support") |
| 40.168 | `SpringBoard` spawn (reason "system support") |
| 40.174 | `logd` spawn (system domain, reason "ipc (socket)") |
| 40.180 | `user/501` exits bootstrap mode; 37 deferred jobs spawned in 12 ms |
| 40.193 | `system` exits bootstrap mode; `deviceconfigurationd`, `notifyd` spawned |
| 40.197 | SpringBoard reports running (INIT) |
| 41.0 | 23 jobs running |
| ~68 | `simctl bootstatus -b` returns (whole boot 28 s; 170 successful spawns by then) |

`launchd_sim` prints "bringup time" 56 ms (system) and 43 ms (user/501).

## 2. `launchd_sim`'s argv, environment, and inherited resources

### 2.1 Environment (47 variables)

The environment of `launchd_sim` is exactly the union of:

- all 38 keys of the bootstrap plist's `Bootstrap.Self` dictionary (§3),
  with identical values;
- the host job's `OSLogRateLimit` and `XPC_SERVICE_NAME`;
- host-launchd/login defaults: `XPC_FLAGS=0x0`, `LOGNAME`, `USER`,
  `SHELL`, `__CF_USER_TEXT_ENCODING`;
- two extra keys: `XPC_SIMULATOR_HOLDING_TANK_FD_HACK=5` and
  `XPC_SIMULATOR_HOLDING_TANK_HACK=29307` (a pid that no longer existed when
  checked; its meaning is unknown).

Notable `Self` values: `DYLD_ROOT_PATH`, `DYLD_SHARED_CACHE_DIR`,
`DYLD_FALLBACK_FRAMEWORK_PATH`, `DYLD_FALLBACK_LIBRARY_PATH`,
`IPHONE_SIMULATOR_ROOT`, `SIMULATOR_ROOT` = RuntimeRoot paths;
`HOME` = `CFFIXED_USER_HOME` = `IPHONE_SHARED_RESOURCES_DIRECTORY` =
`SIMULATOR_SHARED_RESOURCES_DIRECTORY` = `<DEV>/data`; `TMPDIR` =
`<DEV>/data/tmp/`; `PATH` = five RuntimeRoot bin directories;
`XPC_SIMULATOR_LAUNCHD_NAME` = the host endpoint name; 24 `SIMULATOR_*`
device descriptors (UDID, name, model identifier `iPhone19,4`, product class,
screen width/height/scale/pitch, capabilities plist path in the device type
bundle, framebuffer framework path and HID framework path in the host
CoreSimulator.framework, audio plist paths, log root
`~/Library/Logs/CoreSimulator/<UDID>`, boot time as Unix seconds, version
info string, runtime version/build, archs `arm64`, host home).

### 2.2 File descriptors (lsof)

| fd | What |
|---|---|
| cwd | `/` |
| 0, 1 | `/dev/null` |
| 2 | a kernel-control socket `com.apple.netsrc` (opened by host libraries) |
| 3 | `/dev/console`, write-only |
| 4 | Unix socket bound at `<TMP>/syslogsock` (listening). The **same socket object** is fd 13 of the guest `logd` |
| 5 | Unix socket connected to fd 4's socket (`XPC_SIMULATOR_HOLDING_TANK_FD_HACK=5`) |
| 6–8 | directory fds of the host Cryptex/dyld volumes (opened by the host dyld; every guest process has these at 9–11) |
| 9 | `<TMP>/launchd.log`, write-only: launchd_sim's own flat-file log |
| 10 | Unix socket `/private/var/tmp/com.apple.launchd.<random>/com.apple.webinspectord_sim.socket` |
| 12, 15 | one Unix socket, `…/com.apple.launchd.<random>/com.apple.testmanagerd.unix-domain.socket` |
| 13, 16 | one Unix socket, `…/com.apple.launchd.<random>/com.apple.testmanagerd.remote-automation.uds` |

The three `com.apple.launchd.<random>` sockets are **created by launchd_sim
itself** for guest jobs whose plist has `Sockets` with
`SecureSocketWithKey` (§4.4). No host process other than launchd_sim and
the guest webinspectord holds them. Directories are mode 0700, sockets 0666.

Mapped images (lsof `txt`): `launchd_sim`, `dyld_sim`, host `/usr/lib/dyld`,
the host `libsystem_kernel`, `libsystem_platform`, `libsystem_pthread`, and
two sim shared-cache files. Nothing else: **launchd_sim does not load
`liblaunch_sim.dylib`**.

### 2.3 Mach ports (lsmp, non-root)

2,441 port names: 1,751 send, 472 receive+send, 185 send-once, 10
receive-only. The system-domain port and the `user/501` domain port are
receive rights (names 0xc03 and 0x1c03, the latter with 277 send rights
outstanding). The 27 host-side endpoints (§5.2) appear as plain send rights
with dead-name requests armed, at low names (0x1003–0x2d03), consistent
with being received early in the process's life. Host special ports
visible: HOST, CLOCK, VOUCHER, own task control/name.

### 2.4 Link-level metadata (`launchd_sim`)

- Links libSystem, libobjc, and Swift runtime libraries (`libswiftCore`,
  `libswiftDarwin`, `libswiftDispatch`, `libswift_DarwinFoundation1`, weak
  `libswiftObjectiveC`, weak `libswift_Builtin_float`). It is partly
  written in Swift.
- 529 undefined symbols. Groups relevant to Ycode: the libxpc object API
  and pipe server (`_xpc_pipe_handle_mig`, `_xpc_receive_mach_msg`,
  `xpc_pipe_routine_reply`, `_xpc_pipe_create_reply_from_port`,
  `xpc_dictionary_create_reply`, `xpc_create_from_plist`,
  `xpc_bundle_*`), Mach port management (`mach_port_construct`,
  `mach_port_insert_right`, `mach_port_extract_right`,
  `mach_port_request_notification`, `mach_port_guard`,
  `task_set_special_port`, `task_get_special_port`, `mach_ports_register`,
  `task_name_for_pid`), spawning (`posix_spawnp`,
  `posix_spawnattr_set_registered_ports_np`,
  `posix_spawnattr_set_importancewatch_port_np`,
  `posix_spawnattr_setarchpref_np`, `…setprocesstype_np`,
  `…set_darwin_role_np`), process inspection (`proc_pidinfo`,
  `proc_listchildpids`, `proc_pid_rusage`, `proc_terminate`,
  `proc_get_dirty`, `memorystatus_control`, `csops`, `csops_audittoken`),
  BSD sockets (`socket`, `bind`, `listen`, `accept`, `connect`),
  `sysctlbyname`, `os_variant_*`, `os_parse_boot_arg_from_buffer_string`.
- One exported symbol.

## 3. The bootstrap plist (`<DEV>/data/var/run/launchd_bootstrap.plist`)

Written by CoreSimulatorService at boot (14 KB, XML). Its path is
`launchd_sim`'s only argument. Structure:

| Key | Type | Value / content |
|---|---|---|
| `AbortOnUnknownIPC` | bool | true |
| `Bootstrap` | dict | see below |
| `CrashOnSIGTERMTimeout` | bool | true |
| `ExtensionWatchdog` | int | 0 |
| `LogServiceLifecycle` | bool | true |
| `LogToFlatFile` | bool | true (explains `<TMP>/launchd.log`) |
| `RequireDomainBinding` | bool | true |
| `SIGTERMTimeout` | int | 3 |
| `UseGuardMalloc` | bool | false |

`Bootstrap` dictionary:

| Key | Type | Content |
|---|---|---|
| `BinaryOrderPreference` | string | `arm64` |
| `CheckedAllocationsPosixSpawnFlagsGlobal` | bool | false |
| `Child` | dict, 33 strings | environment for every job (DYLD_ROOT_PATH, DYLD_SHARED_CACHE_DIR, IPHONE_*, SIMULATOR_*, PATH, LS_ENABLE_BUNDLE_LOCALIZATION_CACHING, XPC_SIMULATOR_LAUNCHD_NAME) |
| `ChildDefaults` | dict, 5 strings | `CFFIXED_USER_HOME`, `DYLD_FALLBACK_FRAMEWORK_PATH`, `DYLD_FALLBACK_LIBRARY_PATH`, `HOME`, `TMPDIR` |
| `Paths` | array, 4 strings | job directories (§4.1) |
| `Self` | dict, 38 strings | `Child` ∪ `ChildDefaults` — launchd_sim's own environment |
| `SimulatorRuntimeRoot` | string | RuntimeRoot |

Other files CoreSimulatorService writes in `<DEV>/data/var/run/`:
`com.apple.coresimulator.audio.plist` (4 keys: input/output device UIDs and
two "use host default" flags), `memory_warning_simulation` (empty),
`simulatoraudio/`, and `syslog.pid` (written later by the guest syslogd).

## 4. Job model

### 4.1 Discovery

`Bootstrap.Paths` lists, in order:

1. `<RR>/System/Library/LaunchDaemons` — 329 plists
2. `<RR>/System/Library/LaunchAngels` — 25 plists
3. `<RR>/Developer/Library/LaunchDaemons` — 1 plist (testmanagerd)
4. `<DEV>/data/Library/LaunchDaemons` — 9 plists **written by
   CoreSimulator** at device creation (CoreSimulatorBridge and 8
   `com.apple.coredevice.dt*` daemons)

`<RR>/System/Library/LaunchAgents` (9 plists) is **not** on the list.
The runtime also ships `<RR>/System/Library/xpc/launchd.plist` (a 1.5 MB
binary plist with top-level keys `AppExtensions` (500), `LaunchDaemons`
(381, keyed by device-style paths), `AppRemovalServices` (12),
`SystemLibraryTreeState` (2,643), `Symlinks` (1), `VersionNumber` (7)) plus
a `.sig` file, `extensions.plist` (117 extension points), and
`foreground_user_endpoints.plist` (12 service names → true). Whether
launchd_sim reads `launchd.plist` was not determined; its own log names the
on-disk RuntimeRoot plist paths when an import fails, which shows that the
`Paths` directories are scanned.

Import is lenient: unknown keys and wrong value types are logged ("Unknown
key for plist importer", invalid `StartInterval` double, invalid
LaunchEvents stream type, `ThrottleInterval` 0 ignored, …) and the job is
still loaded. 53 such key warnings at boot. One plist fails as "cannot be
loaded on current os variant" (`_LimitLoadToVariant`).

Job plists may contain **feature-flag conditionals**: a dictionary with
`#IfFeatureFlagEnabled` or `#IfFeatureFlagDisabled` (value `Domain/Flag`)
and `#Then`/`#Else` branches, in place of a plain value. Seen in
`UserName`, `Disabled`, `LimitLoadToSessionType`, and MachServices values;
nesting occurs.

### 4.2 Key usage (364 plists, 363 distinct labels)

| Key | Count | Notes |
|---|---|---|
| `Label` | 364 | |
| `MachServices` | 348 | 1,512 names. Values: 1,403 `true`; 47 dicts with `_ExperimentalNonLaunching`; 25 `ResetAtClose`; 15 empty dicts; 4 `HideUntilCheckIn`; 2 `HostSpecialPort` (30 for `com.apple.FileCoordination.kernel.ipc`, 34 for `com.apple.applicensedeliveryd`); 15 feature-flag conditionals; 1 string |
| `EnablePressuredExit` | 324 | |
| `UserName` | 307 | 298 `mobile`, 8 `_xxx` role users, 1 `root`, 2 conditionals |
| `EnableTransactions` | 288 | |
| `ProgramArguments` | 287 | |
| `LaunchEvents` | 213 | streams: notifyd.matching 132, xpc.activity 70, bg.system.task 66, distnoted.matching 42, distnoted.matching.trusted 28, rapport.matching 16, accounts.changes 11, biome.compute.publisher 11, nsurlsessiond-events 10, alarm 10, … (~30 stream names) |
| `POSIXSpawnType` | 201 | Adaptive 139, Interactive 46, App 13, Background 2, AdaptiveUtility 1 |
| `ProcessType` | 157 | Adaptive 112, App 26, Interactive 12, Background 6, Standard 1 |
| `Program` | 105 | |
| `RunAtLoad` | 78 | true 23, false 55 |
| `KeepAlive` | 66 | true 15, false 21, dict 30 (`PathState` 21, `Crashed` 5, `SuccessfulExit` 3, `AfterInitialDemand`+`SuccessfulExit` 1) |
| `EnvironmentVariables` | 65 | |
| `ThrottleInterval` | 40 | |
| `PublishesEvents` | 28 | |
| `_AdditionalProperties` | 27 | all `RunningBoard` |
| `GroupName` | 17 | |
| `Disabled` | 12 | 3 true, 2 false, 7 conditionals |
| `JetsamProperties` | 12 | |
| `LimitLoadToSessionType` | 11 | `System` 7, conditional `System` 3, `Aqua`/`LoginWindow` 1 |
| `RootedSimulatorPath` | 9 | all 9 device-dir plists; program is a host path |
| `Sockets` | 3 | logd (`BSDSystemLogger` with `SystemLoggingSocket`), webinspectord, testmanagerd (Unix, `SecureSocketWithKey`) |
| others | ≤ 7 each | `Umask`, `_ExponentialThrottling`, `_ManagedBy`, `StartInterval`, `WorkingDirectory`, resource limits, `WatchPaths`, `QueueDirectories`, `StartCalendarInterval`, `MultipleInstances`, `ExitTimeOut`, `Nice`, … |

Program paths in plists are guest-absolute (`/System/…` 221, `/usr/…` 114,
`/Applications/…` 20); the 9 `RootedSimulatorPath` jobs use host paths
under `/Library/Developer/PrivateFrameworks/CoreSimulator.framework/…`.

### 4.3 Domains

`launchctl print` inside the guest (served by launchd_sim) shows:

| Domain | Type | Session | Services | Endpoints |
|---|---|---|---|---|
| `system` | system | `System`, session uid -101 | 7 | 18 Mach |
| `user/501` | user | `iOSUser`, session uid 501 | 400 (172 active) | 1,585: 745 Mach active, 810 Mach demand, 27 host-side (`H`), 2 `U`, 1 `N` |
| `pid/<pid>` | pid | — | per-process XPC services | dynamic/pid-local |

- Both domains report `creator = launchd_sim[29306]`, creator euid 501.
  The system domain lists `user/501` and every `pid/N` as subdomains.
- **Domain assignment:** the 7 system-domain jobs are exactly the plists
  whose `LimitLoadToSessionType` is `System` (logd, logd_helper,
  diagnosticd, notifyd, deviceconfigurationd, containermanagerd.system,
  cfprefsd.xpc.daemon.system). Every other job, including those with
  `UserName = root`, goes into `user/501`. All jobs run as uid 501;
  `UserName` does not change the uid.
- 6 labels are not loaded at all (Disabled, os-variant, Aqua session).
- 51 `user/501` services do not come from plists: XPC services from
  framework bundles bootstrapped into the user domain, the 17 "nano"/pairing
  services that a guest helper (`nanoregistrylaunchd`) bootstrapped at
  +3 min, `UIKitApplication:<bundle-id>[xxxx][rb-legacy]` jobs, and one-shot
  jobs.
- Each domain shows its bootstrap port under "task-special ports" with
  names `com.apple.xpc.launchd.domain.system` and
  `com.apple.xpc.launchd.domain.user.501`.
- **Domain environment:** `user/501` has an `environment` with the three
  secure-socket variables (`RWI_LISTEN_SOCKET`, `TESTMANAGERD_SIM_SOCK`,
  `TESTMANAGERD_REMOTE_AUTOMATION_SIM_SOCK`), set from the `Sockets`
  entries of webinspectord and testmanagerd. Every service also shows a
  `global environment` with `IOS_SIMULATOR_SYSLOG_SOCKET = <TMP>/syslogsock`.
- **Disabled overrides:** both domains list 17 labels as "enabled". The
  store is `<TMP>/disabled.plist`, a flat dict label → bool (false =
  enabled), created at +3 min when the guest `nanoregistrylaunchd` enabled
  those services. It is not in the device data directory.

### 4.4 Spawning

- Every job is started through **`xpcproxy_sim`** (`<RR>/usr/libexec/xpcproxy_sim`,
  platform 7; `<RR>/usr/libexec/xpcproxy` is a symlink to it). The log line
  per spawn is "xpcproxy_sim spawned with pid N"; the service state goes
  `spawn scheduled → spawning → xpcproxy → running`; the process then shows
  the real program (`execs = 1`, `trampolined = 1`). All guest processes are
  direct children of launchd_sim (283 at the time of the count).
- The `program` shown for a normal job is `<RR>` + the plist path ("inferred
  program"). For `RootedSimulatorPath` jobs the program is the host path,
  but argv[0] shows the guest-style path (e.g. `/usr/libexec/CoreSimulatorBridge`).
- stdio of daemons: `/dev/null` for 0–2.
- **Job environment** = `Child` ∪ `ChildDefaults` ∪ domain environment ∪
  `IOS_SIMULATOR_SYSLOG_SOCKET` ∪ `XPC_SERVICE_NAME=<label>` ∪
  `XPC_FLAGS` ∪ the plist's `EnvironmentVariables`. System-domain jobs do
  not get the `user/501` domain environment. Verified for notifyd,
  CoreSimulatorBridge, and our probe (exact set comparison).
- Launch reasons counted over 10 minutes (490 launches): `ipc (mach)` 90,
  `launch job demand` 68, `xpc event` 49, `speculative` 25, `event
  publisher` 12, `system support` 2, `ipc (socket)` 2, `semaphore` 1,
  `incomplete work` 1, `one-shot` (probes).
- Boot order: during bootstrap mode, only "system support" jobs
  (UserEventAgent-System, SpringBoard) and socket-activated logd start;
  KeepAlive/RunAtLoad jobs are held ("pending spawn, domain in
  on-demand-only mode"). When a domain leaves bootstrap mode the held jobs
  start together: user/501 first (37 jobs, "speculative" or "event
  publisher"), then system (deviceconfigurationd, notifyd).
- First 40 spawns in order: UserEventAgent-System, SpringBoard, logd,
  assistantd, runningboardd, peopled, replicatord, accountsd, mediaremoted,
  routined, axassetsd, healthd, ids_simd, tccd, parsecd, biomed,
  fileindexerd, mobiletimerd, identityservicesd, syslogd, appprotectiond,
  wcd, backboardd, sharingd, ManagedSettingsAgent, locationd,
  nanoprefsyncd.2, dasd, sleepd, distnoted.xpc.daemon, passd,
  CoreSimulator.bridge, navd, remindd, revisiond, rapportd, amsaccountsd,
  configd_sim, deviceconfigurationd, notifyd.
- 170 successful spawns by the end of `bootstatus` (28 s), 486 after
  10 minutes.

### 4.5 Sockets

- `logd`'s `BSDSystemLogger`/`SystemLoggingSocket` socket is created by
  launchd_sim at `<TMP>/syslogsock` (not at `/var/run/syslog`) and handed to
  logd. Its path is exported to every job as `IOS_SIMULATOR_SYSLOG_SOCKET`.
- `SecureSocketWithKey` sockets are created under
  `/private/var/tmp/com.apple.launchd.<10 random chars>/<socket key name>`
  (host `/private/var/tmp`, not the device tmp), and the path goes into the
  domain environment under the key's name.

### 4.6 launchd_sim's log file

`<TMP>/launchd.log` (enabled by `LogToFlatFile`): lines are
`YYYY-MM-DD HH:MM:SS.uuuuuu (<domain>/<label> [pid]) <Level>: message`.
2.8 MB after 10 minutes. Message classes seen (counts after 10 min):
service state 2,412, internal event 2,327 (`WILL_SPAWN`, `SPAWNED`,
`SOURCE_ATTACH`, `INIT`, `EXITED`, `PETRIFIED`), failed lookup 325, "Failed
to bootstrap path" 3,096 (XPC-service bundle bootstrapping of framework
`XPCServices` directories, mostly "not a bundle" / "executable did not
ship"), "Service stub initialized" 102 and "initialized endpoint after
lookup" 150 (per-process XPC services created lazily on first lookup),
"Mismatched binprefs" 204. Also a harmless startup assertion line and
repeated "launchd has not fixed mobile/tmp".

## 5. How the host talks to `launchd_sim`

### 5.1 The control channel

- The host-domain endpoint `com.apple.CoreSimulator.SimDevice.<UDID>` is the
  only host-visible name. launchd_sim holds its receive right (checked in as
  the job's MachService). `XPC_SIMULATOR_LAUNCHD_NAME` carries that name to
  the guest.
- Host clients do not speak to it directly. CoreSimulatorService asks the
  host XPC service **SimLaunchHost-arm64**
  (`CoreSimulator.framework/…/XPCServices/SimLaunchHost.arm64.xpc`, a
  `user/501` XPCService; an x86 variant exists and was idle) to act for it.
  SimLaunchHost `dlopen`s the runtime's
  `<RR>/usr/lib/system/host/liblaunch_sim.dylib` (one "liblaunch instance"
  per runtime, identified by a UUID; it had all 17 installed runtimes'
  copies mapped) and runs commands.
- SimLaunchHost command names logged over the boot and probes:
  `startsession` (1, at boot, "got bind port … from sim service"),
  `findendpoint` (27), `getenv` (8), `spawn` (12, from `simctl spawn`),
  `loadliblaunch` (75), `unloadliblaunch` (3). After a `spawn`, it logs the
  child's exit status ("pid exited with status 0").
- `simctl spawn` creates a one-shot job
  `com.apple.xpc.launchd.oneshot.0x1000000N.<name>` in `user/501` (launch
  reason `one-shot`). The process is a child of launchd_sim, and the caller's
  stdout/stderr fds are passed through (the probe's fd 1/2 were the host
  files `simctl` was redirected to; fd 0 was an unnamed Unix socket).

### 5.2 `liblaunch_sim.dylib` (metadata)

- Path `<RR>/usr/lib/system/host/liblaunch_sim.dylib`; universal arm64,
  arm64e, arm64e.x1; **platform 1 (macOS)**, minos 11.0, sdk 14.0; install
  name `@iphonesimulator27.1-3298.2.1/usr/lib/system/host/liblaunch_sim.dylib`;
  current version 3298.2.1; depends only on `/usr/lib/libSystem.B.dylib`.
- 31 exports: 8 `launch_sim_*` functions
  (`bind_session_to_port`, `find_endpoint`, `getenv`, `register_endpoint`,
  `unregister_endpoint`, `set_death_handler`, `spawn`, `waitpid`), plus
  `xpc_binprefs_*` (11), `_xpc_spawnattr_*` pack/unpack helpers (10), and
  `xpc_create_from_ce_der[_with_key]` (2).
- Loaded by: SimLaunchHost only. Not loaded by launchd_sim, the
  trampoline, or any guest process checked (all 283 launchd_sim children).
  `/usr/lib/system/host/` does not exist on the host. (The dyld allow-list
  entry for that path, see `specs/simulator/host-library-loading.md`, was
  not exercised in this run.)
- The command names in §5.1 map one-to-one onto these exports
  (startsession ↔ bind_session_to_port, findendpoint ↔ find_endpoint, …).
  This is an inference from names.

### 5.3 Host services injected into the guest namespace

`launchctl print user/501` inside the guest shows an **unmanaged process**
named `com.apple.xpc.launchd.simhost` with 27 "dynamic endpoints", each
`host-side = 1`, `managed = 0`. They are listed in the domain's endpoints
with kind `H`. Names (27):

`com.apple.CoreSimulator.host.bootstrap_port`,
`com.apple.CoreSimulator.SimFramebufferServer`,
`com.apple.CoreSimulator.SimCaptureService`,
`com.apple.CoreSimulator.SimIdentityService`,
`com.apple.CoreSimulator.NearbyInteraction`, `IndigoHIDRegistrationPort`,
`com.apple.metal.simulator` and `.SpringBoard`, `.SBRendererService`,
`.backboardd`, `.PineBoard`, `.HeadBoard`, `.Carousel` (the five
per-client names share one port), `com.apple.audio.coreaudiod`,
`com.apple.audio.audiohald`, `com.apple.IOSurface.Remote`, `com.apple.FSEvents`,
`com.apple.SystemConfiguration.configd` and `.configd_host` (one port),
`com.apple.SystemConfiguration.PPPController`,
`com.apple.PowerManagement.control`, `com.apple.FileProvider.sim2host`,
`com.apple.storekitservice.sim2host`, `com.apple.modelmanager.simulator`,
`com.apple.coreservices.lsuseractivity.simulatorsupport`,
`com.apple.fpsd.sim`, `com.apple.gputools.service.simulator`.

From the host log, CoreSimulatorService registers these just before
`startsession`; for each name it first looks the name up in the host
bootstrap, and logs "Could not register service X: Failed to lookup X:
0x44e" when the host has no such service (2 names this boot). So the
mechanism is: host looks up the real host service, then registers the
send right into launchd_sim under the same (or a sim-specific) name.
Guest lookups of these names succeed and return ordinary send rights.

## 6. What a guest process sees (probe `bsprobe`)

Run with `simctl spawn` (one-shot job, parent launchd_sim, uid/euid 501,
gid 20):

- `task_get_special_port(TASK_BOOTSTRAP_PORT)` succeeds and returns the same
  name as the `bootstrap_port` global: a send right. launchd_sim's view of
  the pid domain lists that port as the task's bootstrap special port and
  it is the `user/501` domain port (name 0x1c03 in launchd_sim's space).
  So the bootstrap port is a task special port set at spawn, not looked up.
- `mach_ports_lookup`: 3 slots; slot 0 holds a send right, slots 1–2 empty.
  The identity of slot 0 was not determined.
- Other task special ports: host (2), name (3), bootstrap (4), access (9)
  are send rights; debug-control (10) is receive+send; id 11 fails
  (KERN_INVALID_ARGUMENT). Apart from the bootstrap port these come from
  the host kernel and are not launchd_sim's concern.
- `bootstrap_look_up` results:

  | Name | Result |
  |---|---|
  | `com.apple.system.notification_center` (system domain) | success, send right |
  | `com.apple.logd` (system) | success |
  | `com.apple.cfprefsd.daemon` (user) | success |
  | `com.apple.cfprefsd.daemon.system` (system, demand) | success |
  | `com.apple.runningboard` | success |
  | `com.apple.CoreSimulator.host.bootstrap_port` (host-side) | success |
  | `com.apple.CoreSimulator.SimFramebufferServer` (host-side) | success |
  | `IndigoHIDRegistrationPort` (host-side) | success |
  | `com.apple.coredevice.dticond` (job loaded, name not advertised) | 1102 (0x44e, BOOTSTRAP_UNKNOWN_SERVICE) |
  | `com.apple.ycode.does-not-exist` | 1102 |

  A lookup from `user/501` finds system-domain names: lookups fall through
  from the user domain to the system domain.
- launchd_sim logs each failed lookup as "failed lookup: name = …, flags =
  0x1, requestor = <proc>[pid], error = 3: No such process" for the legacy
  MIG-style `bootstrap_look_up`; the same failure through XPC is logged
  without the `flags` field.
- `bootstrap_check_in` of an unknown name **succeeds** and returns a
  receive right; a later `bootstrap_look_up` of that name then succeeds
  (dynamic registration is allowed for unprivileged guest processes).
- XPC: `xpc_connection_create_mach_service` to an unregistered name gets
  "Connection invalid" promptly. To a name the same process had just
  checked in, a synchronous send blocks forever (the message goes to our
  own unserviced receive right) — a probe artefact, not a launchd effect.
- Environment of a one-shot job: the 38 `Child`/`ChildDefaults` variables,
  the 3 domain secure-socket variables, `IOS_SIMULATOR_SYSLOG_SOCKET`,
  `XPC_SERVICE_NAME=com.apple.xpc.launchd.oneshot.0x1000000N.bsprobe`,
  `XPC_FLAGS=0x0`. Nothing else (no `USER`, `SHELL`, `OSLogRateLimit`).
- launchd_sim creates a `pid/<pid>` domain for the process at its first
  bootstrap message ("uncorking exec source upfront", "created"); its
  `originator` is the executable's directory. The pid domain is removed at
  exit ("shutting down", "cleaning up", "removing child").

## 7. Not done / skipped

- `launchctl procinfo` needs root: skipped. `lsmp` without root gives no
  cross-task port identities.
- `fs_usage`/`dtruss` (needs root/SIP changes): skipped, so the exact files
  launchd_sim opens at startup (e.g. whether it reads `xpc/launchd.plist`)
  were not observed.
- No message traffic was captured; no MIG subsystem numbers or XPC pipe
  routine numbers are visible in logs or metadata. Only the libxpc pipe
  import names (`_xpc_pipe_handle_mig`, …) indicate that launchd_sim serves
  both MIG-style bootstrap messages and XPC-pipe routines.
