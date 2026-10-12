# Spec: installing and launching an app inside the guest

Status: **reference** for stage 7 of `docs/SIMULATOR-LINUX.md` (research
item 1 of `stage7-contract.md`). Every fact comes from black-box runs on the
reference Mac (iOS 27.1 runtime 24A94401, CoreSimulator 1174.9.2, device type
iPhone Duo, a throwaway device) of `simctl` and of our own programs, and from
binary metadata read at run time by our own program (class and selector
names, ObjC type encodings, exported string constants). No disassembly or
decompilation was used. The spec states paths, interface names, arguments,
results, and observed order of events. It does not describe how Apple's
daemons work inside.

Terms are as in `launchd-sim.md`: **RR** (RuntimeRoot), **DEV** (the device
directory; `DEV/data` is the guest's writable world), **host** (on Linux:
Ycode). In addition:

- **probe app**: `research/experiments/simulator/ProbeApp`, bundle id
  `dev.ycode.probe`. It writes a `== YCODE-PROBE BEGIN … END` report to
  stderr from `application(_:didFinishLaunchingWithOptions:)`.
- **ylaunch**: our guest-side helper,
  `research/experiments/simulator/app-launch/ylaunch.m`. It links only
  Foundation and Security and reaches private classes by name at run time.
- **bridge**: the job `com.apple.CoreSimulator.bridge` (`launchd-sim.md`
  §4.5), a host-supplied program that runs as a guest job.
- **one-shot**: a program started with the host's spawn operation
  (`launchd-sim.md` §6.1; `simctl spawn` on the Mac).

## 1. Summary

An app can be installed and launched with runtime daemons plus one small
program of our own, run as a one-shot. The bridge and the host tools are not
needed. The sequence that works (§4.6):

1. **Install**: `IXAppInstallCoordinator`
   `+installApplication:consumeSource:options:completion:` with the bundle URL,
   `NO`, an `MIInstallOptions` built from `{PackageType = Developer}`, and a
   completion block. The block receives the bundle id on success.
2. **Launch**: `FBSOpenApplicationService` `+serviceWithDefaultShellEndpoint`,
   then `-openApplication:withOptions:completion:` with the bundle id and an
   `FBSOpenApplicationOptions` whose `__DebugOptions` hold the stdout and
   stderr paths, the arguments, and the environment. The calling program must
   carry the entitlement `com.apple.frontboard.debugapplications` in its
   `__TEXT,__entitlements` section.
3. The probe's report appears in the stderr file. Its path is a guest path:
   `/tmp/…` lands in `DEV/data/tmp/…` (§3.4).

`didFinishLaunching` runs **before** the app's scene connects and before
anything is rendered. It does need backboardd's display-services endpoint,
and it waits about 5 s if backboardd's render server cannot be looked up
(§5).

## 2. Install as observed with `simctl install`

### 2.1 Who takes part

`simctl install` → CoreSimulatorService (host) → the bridge (guest job).
The bridge logs that it received the request, with the source URL and the
options `PackageType = Developer`, `SimulatorRootPath = <RR>`, and
`SimulatorUserPath = <DEV/data>`. From there, everything is guest-side:

| Step | Process | Observed action |
|---|---|---|
| 1 | bridge | Calls the InstallCoordination "simple installer" (class `IXAppInstallCoordinator`, category `IXSimpleInstaller`) with options `{IsUserInitiated = 1, PackageType = Developer}`, consume source = NO. Connects to Mach service `com.apple.installcoordinationd`. |
| 2 | bridge (client side) | Registers data promises with installcoordinationd: an app placeholder, icon resources, localizations, install options, and the app asset. **Copies the bundle** into `DEV/data/Containers/Shared/SystemGroup/systemgroup.com.apple.installcoordinationd/Library/InstallCoordination/PromiseStaging/<promise-UUID>/<Name>.app`. |
| 3 | installcoordinationd | Creates a coordinator (intent "Initiating", creator "InstallCoordination Simple SPI"). Asks runningboardd for a termination assertion on processes with that bundle id (none are running on a first install). |
| 4 | installd | Installs a **placeholder** first ("Install (Placeholder)"). |
| 5 | containermanagerd | Creates the bundle container under `DEV/data/Containers/Temp/Bundle/Application/<UUID>` and the data container (staged under `DEV/data/Containers/Staging/`, then live under `Data/Application/<UUID>`). |
| 6 | lsd | Registers the placeholder ("Registering bundles via registrant", "Registered bundle status = success", "bundle unit N"). |
| 7 | SpringBoard | "Placeholder add BEGIN", creates a placeholder icon. |
| 8 | installd | Installs the real app ("Install (New)" on a first install). The bundle container is made live at `DEV/data/Containers/Bundle/Application/<UUID>`. The data container UUID is regenerated. |
| 9 | lsd | Registers the app again, with a new bundle unit. installd tracks the pending registration in `DEV/data/Library/MobileInstallation/LaunchServicesOperations/<UUID>` until LaunchServices saves its database. |
| 10 | installcoordinationd | "Coordinator completed successfully". The client's completion fires. |
| 11 | more than 20 daemons | Log `applicationsDidInstall` for the new app (SpringBoard, runningboardd, homed, passd, dasd, and others). SpringBoard: "Placeholder remove BEGIN", "Application added". |

The daemons log each phase on the `TransactionLog` category, with the bundle
id as a prefix. That log is the most useful trace for Ycode bring-up.

### 2.2 Files the install leaves

Bundle container `DEV/data/Containers/Bundle/Application/<UUID>/`:

| Entry | Content |
|---|---|
| `<Name>.app/` | The bundle as copied. The main executable gets the extended attributes `com.apple.install_uuid` and `com.apple.install_session_uuid` (16 bytes each). The container directory gets `com.apple.containermanager.{identifier,uuid,schema-version,birthtime}`. |
| `.com.apple.mobile_container_manager.metadata.plist` | `MCMMetadataIdentifier` = bundle id, `MCMMetadataContentClass` = 1, `MCMMetadataCreator` = `com.apple.installd`, `MCMMetadataOwnership` (uid 501, gid 20, mode), `MCMMetadataUUID`, `MCMMetadataVersion` = 9, `MCMMetadataInfo` (linked SDK version, content-protection class, static disk usage). |
| `BundleMetadata.plist` | An NSKeyedArchiver archive of class `MIBundleMetadata`: install date, original install date, install build version (the runtime build), install type, and placeholder-failure fields. |
| `SerializedPlaceholder.ipa` | A small zip with `Payload/<Name>.app/Info.plist` (a reduced Info.plist). |

Data container `DEV/data/Containers/Data/Application/<UUID>/`: the same
metadata plist with `MCMMetadataContentClass` = 2 and an
`MCMMetadataUserIdentity` entry, plus `Documents/`, `Library/Caches/`,
`Library/Preferences/`, `SystemData/`, and `tmp/`.

Other files changed during the install: the LaunchServices store
`DEV/data/var/db/lsd/com.apple.LaunchServices-<n>-v2.csstore`,
`DEV/data/Library/FrontBoard/applicationState.db`,
`DEV/data/Library/SpringBoard/IconState.plist`, the lsd icon cache, and the
installcoordinationd `CoordinatorPriority.plist`. All of them are written by
runtime daemons. Ycode does not write any of them.

Both container UUIDs change on every reinstall.

### 2.3 Timing

A warm install of the probe took 0.12–0.19 s (helper completion to
completion). The first install after boot took 3.9–7.9 s. Most of that time
was installd's "Preflight" phase.

## 3. Launch as observed with `simctl launch`

### 3.1 Who takes part

`simctl launch --stdout=P --stderr=Q <dev> <id> ARGS…` → the bridge. The
bridge logs the request options `arguments`, `environment`, `stdout`, and
`stderr`. Then:

| Step | Process | Observed action |
|---|---|---|
| 1 | bridge | Waits until LaunchServices knows the bundle (logs the bundle proxy's sequence number and cache GUID). Retry limits are logged as user defaults of domain `com.apple.CoreSimulatorBridge`: `LaunchRetryTimeout` 120 s, `BootRetryTimeout` 300 s, `BootLeeway` 120 s. |
| 2 | bridge → SpringBoard | `FBSSystemService` sends an open request. SpringBoard's `FBSystemService` logs "Received request to open", "Trusting entitled client", and "Received trusted open application request". |
| 3 | SpringBoard | Runs a workspace transition `OpenApplication(sceneID:<id>-default)`, creates the process identity `app<id>`, and bootstraps it with intent `foreground-interactive`. |
| 4 | runningboardd | Takes an assertion, builds a launchd job description (§3.2), and submits and starts it in `launchd_sim`'s `user/<uid>` domain. |
| 5 | launchd_sim | Spawns `xpcproxy_sim`, which opens the stdio files and becomes the app (`launchd-sim.md` §4.4). |
| 6 | app | Connects to runningboardd, cfprefsd, backboardd, and SpringBoard's FrontBoard workspace. It runs `didFinishLaunching`, then receives its scene. |
| 7 | SpringBoard → bridge | The open request completes with a process handle. The bridge reports the pid to the host. |

The request to the end of `didFinishLaunching` took about 1.1 s.

### 3.2 The job runningboardd submits

Keys observed in the logged job description for the app (`launchd_sim`'s
plist importer rejects `_ResourceCoalition` as unknown and continues):

| Key | Value |
|---|---|
| `Label` | `UIKitApplication:<bundle-id>[<4 hex digits>][rb-legacy]` |
| `Program`, `ProgramArguments` | Host path of the installed executable; argv[0] is the same path, followed by the request's arguments |
| `RootedSimulatorPath` | true |
| `UserName` | `mobile` |
| `ProcessType` | `App` |
| `StandardOutPath`, `StandardErrorPath` | The request's paths, **unchanged** (guest paths) |
| `EnvironmentVariables` | `HOME`, `CFFIXED_USER_HOME`, `TMPDIR` (`<data container>/tmp`), `_DYLD_CLOSURE_HOME`, plus the request's environment |
| `SandboxContainer` | Data container path |
| `MachServices` | empty |
| `InitialTaskRole` 1, `ExitTimeOut` 1, `ThrottleInterval` 2147483647, `EnableTransactions` false, `EnablePressuredExit` false, `MaterializeDatalessFiles` true, `_LaunchType` 3, `_ManagedBy` `com.apple.runningboard` | as listed |
| `_AdditionalProperties.RunningBoard` | `Managed` true, `RunningBoardLaunched` true, identity `{TYPE = 2, EAI = <bundle-id>}` |

The app's final environment is the job environment of `launchd-sim.md` §4.4,
plus the keys above. `XPC_SERVICE_NAME` equals the label.

### 3.3 After launch

runningboardd logs several `memorystatus_control` and role calls that fail
with EPERM ("Memorystatus failed", "Error setting Darwin GPU", "Carplay
mode"). The launch is not affected. Ycode's kernel layer can return the same
errors.

### 3.4 Where stdio paths land

`xpcproxy_sim` opens `StandardOutPath` and `StandardErrorPath`. It creates
missing parent directories, and it rewrites some prefixes (tested with ylaunch
and `simctl launch`):

| Requested path | File opened |
|---|---|
| `/tmp/x/a.err`, `/private/tmp/x/a.err` | `DEV/data/tmp/x/a.err` |
| `/var/tmp/a.err` | `DEV/data/var/tmp/a.err` |
| `DEV/data/tmp/a.err` (already a full path) | used as is |
| `/private/tmp/<long>/a.err` | `DEV/data/tmp/<long>/a.err`, directories created |
| `/Users/<user>/a.err` (another host path) | used as is |
| `/Library/a.err`, `/nonexist/a.err` | not rewritten. The directory cannot be created (read-only host root), so the spawn fails. |

When the stdio file cannot be opened, `launchd.log` reports "Service could
not initialize: Unable to create stderr directory (…)", `xpcproxy_sim` exits
with 78, and the job is removed. The open request then completes with
**no process and no error**. A launcher must treat "no process" as a failure.

### 3.5 Order inside the app

For a scene-based app (the probe declares `UIApplicationSceneManifest`), the
following order was observed:

1. The process starts (`xpcproxy_sim` has already opened the stdio files).
2. UIKit's startup connects to backboardd display services, cfprefsd,
   runningboardd, and the CoreAnimation render server, then handshakes with
   SpringBoard's FrontBoard workspace (`com.apple.frontboard.systemappservices`).
3. `didFinishLaunching` runs. The report was written 0.52 s after the stdio
   file was created.
4. About 0.25 s later, the `UIWindowScene` is created, then the scene
   delegate's window, then HID and keyboard connections.

A launch with `__ActivateSuspended` (background, scene `BG-Active`) also runs
`didFinishLaunching` and writes the report.

## 4. Guest-side helper (ylaunch): interfaces tested

All calls run inside a one-shot started from `/tmp` (spawning a binary from
the repository volume was reported to hang; this was not retested). Private classes were found with
`objc_getClass`, and selectors were checked with `respondsToSelector:` before
use. Argument types come from the run-time ObjC type encodings. All of the
following were present in iOS 27.1: `LSApplicationWorkspace`,
`LSApplicationProxy`, `FBSOpenApplicationService`,
`FBSOpenApplicationOptions`, `FBSSystemService`, `IXAppInstallCoordinator`,
and `MIInstallOptions`. These C functions were absent: the
`MobileInstallationInstall`, `…InstallForLaunchServices`, `…Lookup`, and
`…Uninstall` family.

### 4.1 Install

| Interface | Arguments | Result |
|---|---|---|
| `LSApplicationWorkspace` `+defaultWorkspace`, `-installApplication:withOptions:error:` | file URL of the `.app`; `{CFBundleIdentifier}` | **Refused**: returns NO with `NSOSStatusErrorDomain` −4. Nothing is installed. |
| `IXAppInstallCoordinator` `+installApplication:consumeSource:options:completion:` with options as a plain dictionary | URL, NO, `{PackageType = Developer}`, block | The client **crashes**: the options object must answer `installTargetType` (an unrecognized selector on a dictionary). |
| same, options = `MIInstallOptions` `-initWithLegacyOptionsDictionary:` `{PackageType = Developer}` | URL (`NSURL`), consume source (`BOOL`, NO), options, completion block | **Works.** The block is called once with (bundle id `NSString`, nil) on success. This is the same path and the same logged options as the bridge (§2.1), without `IsUserInitiated`. |

- The other class methods present on `IXAppInstallCoordinator` (names only):
  `installApplication:options:completion:`,
  `installApplication:consumeSource:options:legacyProgressBlock:completion:`,
  `installApplication:forPersonaUniqueString:consumeSource:options:completion:`,
  `installApplication:toTargetDirectory:…` and `…toURL:…` variants.
  `MIInstallOptions` also has `setDeveloperInstall:` and
  `setUserInitiated:`. These were not tested.
- The client process itself copies the bundle into installcoordinationd's
  `PromiseStaging` directory (§2.1, step 2). It needs read access to the
  source and write access to that directory.
- No entitlement was needed to install. A bundle with no
  `_CodeSignature/` directory, whose executable has only the linker's ad-hoc
  signature, installed and launched normally.
- Installing again over an installed app works. It gives a new bundle
  container and a renamed data container.

### 4.2 Uninstall

| Interface | Result |
|---|---|
| `LSApplicationWorkspace` `-uninstallApplication:withOptions:` | Returns YES but **does nothing**. The client logs that it uses an LSApplicationWorkspace uninstall interface, which is not supported, and that it should use InstallCoordination. |
| `IXAppInstallCoordinator` `+uninstallAppWithBundleID:error:` (`NSString`, `NSError **` → `BOOL`) | **Works** (0.07–0.15 s). It terminates a running instance, removes both containers, and unregisters the app from LaunchServices. |

### 4.3 Lookup

`LSApplicationProxy` `+applicationProxyForIdentifier:` returns a proxy for any
id. `-isInstalled` (`BOOL`), `-bundleURL`, and `-dataContainerURL` give the
installed state and the host paths of both containers. After an uninstall,
the proxy reports not installed with nil URLs.

### 4.4 Launch

| Interface | Caller's entitlements | Result |
|---|---|---|
| `LSApplicationWorkspace` `-openApplicationWithBundleID:` | none | **Works**, returns YES. lsd logs "pid N requests to open application", then sends its own FrontBoard open request. SpringBoard trusts lsd. The app's stdin, stdout, and stderr are `/dev/null`, so the report cannot be seen. There is no way to pass arguments or environment. |
| `FBSOpenApplicationService` `+serviceWithDefaultShellEndpoint`, `-openApplication:withOptions:completion:` | none | **Refused.** Without debug options, SpringBoard logs "Un-trusted clients may not open applications without a valid user activity". With debug options, it logs "Missing entitlement required to launch applications for debugging". The client receives `FBSOpenApplicationServiceErrorDomain` 4 with underlying `FBSOpenApplicationErrorDomain` 3 ("Request is not trusted"). |
| same | `com.apple.frontboard.launchapplications` | Works without debug options. Refused when debug options are present. |
| same | `com.apple.frontboard.debugapplications` | **Works**, with or without debug options. |
| same | both of the above | Works. |

`-openApplication:withOptions:completion:` takes a bundle id (`NSString`), an
`FBSOpenApplicationOptions` (made with `+optionsWithDictionary:`), and a block
that receives (process handle, `NSError`). On success, the handle is a
`BSProcessHandle` that answers `pid`. The completion arrived 0.02–0.03 s after
the call (1.2 s on the first launch after boot).

Option keys. The values were read at run time from exported string constants
of FrontBoardServices:

| Constant | Value | Use |
|---|---|---|
| `FBSOpenApplicationOptionKeyDebuggingOptions` | `__DebugOptions` | dictionary of the keys below |
| `FBSDebugOptionKeyStandardOutPath` | `__StandardOutPath` | guest path (§3.4) |
| `FBSDebugOptionKeyStandardErrorPath` | `__StandardErrorPath` | guest path (§3.4) |
| `FBSDebugOptionKeyArguments` | `__Arguments` | array, appended after argv[0] |
| `FBSDebugOptionKeyEnvironment` | `__Environment` | dictionary, added to the app's environment |
| `FBSDebugOptionKeyWaitForDebugger` | `__WaitForDebugger` | not tested |
| `FBSDebugOptionKeyDisableASLR` | `__DisableASLR` | not tested |
| `FBSOpenApplicationOptionKeyUnlockDevice` | `__UnlockDevice` | not required (the launch worked without it) |
| `FBSOpenApplicationOptionKeyActivateSuspended` | `__ActivateSuspended` | launches into the background (§3.5) |
| `FBSOpenApplicationOptionKeyPromptUnlockDevice`, `…LaunchOrigin`, `…PayloadURL` | `__PromptUnlockDevice`, `__LaunchOrigin`, `__PayloadURL` | not tested |

The bridge uses the older `FBSSystemService` interface (`+sharedService`,
`-openApplication:options:clientPort:withResult:`), which is also present.
ylaunch did not need it.

### 4.5 How simulator entitlements are carried and read

- The simulator does **not** take entitlements from the code signature. A
  helper ad-hoc signed with an entitlements plist could not be spawned at all
  (the host reported `SimXPCErrorDomain` 163, "Process spawn via launchd
  failed"). This is a macOS host rule.
- Entitlements placed in a Mach-O section `__TEXT,__entitlements` (an XML
  plist, linked with `-sectcreate`) are honored. This is the form Xcode uses
  for simulator builds.
- When our helper asked `SecTaskCopyValueForEntitlement` about itself by
  audit token, an interposer of our own recorded this sequence:
  `csops_audittoken` status (op 0); `proc_pidpath(pid)`; `open` of that
  executable; `csops_audittoken` op 7 (entitlements blob), first with an
  8-byte buffer (fails, size probe), then with the full size (succeeds, 489
  bytes). 489 bytes is the section's 481-byte plist plus an 8-byte blob
  header. Op 11 (identity) follows with the same size probe. The
  `proc_pidpath` and `open` calls happen inside the op-7 call, so the simulator's user-space
  library serves the entitlements blob by reading the section from the
  executable file. The host kernel does not.
- When SpringBoard checks a client, it therefore needs (inferred, same
  mechanism by audit token): `proc_pidpath` of the **client's** pid to return
  a readable path, and the file at that path to contain the section.

### 4.6 The minimal working sequence

Run as one-shots in the booted guest (`run-sequence.sh` does exactly this):

1. Optional: `uninstall-ix <id>` (`IXAppInstallCoordinator`
   `+uninstallAppWithBundleID:error:`).
2. `install-ix <path>.app` (§4.1, the row that works). Wait for the
   completion block.
3. Make sure the stdio directory exists (for example `DEV/data/tmp/ycode/`).
   A missing directory is created only if its parent is writable (§3.4).
4. `open-fbs <id> --err /tmp/ycode/probe.err --out /tmp/ycode/probe.out
   --arg … --env K=V`: `FBSOpenApplicationService` with `__DebugOptions`, from
   a binary that carries `com.apple.frontboard.debugapplications` in
   `__TEXT,__entitlements`. Treat a completion with no process as a failure.
5. Read the report from `DEV/data/tmp/ycode/probe.err`. Observed: the full
   report, with argv[1] = the `--arg` value, the `--env` variable in the
   environment, `HOME` = the new data container, and `XPC_SERVICE_NAME =
   UIKitApplication:dev.ycode.probe[…][rb-legacy]`.

Total for steps 1–5 with a warm device: about 4.7 s, most of it the fixed
waits in the script.

### 4.7 Fallback: running the app executable as a plain one-shot

Spawning the installed executable directly as a one-shot (no SpringBoard
request) also runs `didFinishLaunching`. The report goes to the one-shot's
stdio. Differences from a real launch:

- `HOME` and `TMPDIR` are `DEV/data` and `DEV/data/tmp`, not the data
  container.
- runningboardd resolves the identity as `anon<YcodeProbe>`.
- The FrontBoard handshake is sent, but no scene is ever created, so no
  window is made. The process stays alive until killed.

This path needs no install and no SpringBoard open request. It is a
diagnostic and bring-up tool, not a launch: scene-based code and container
paths do not behave as in a real launch.

## 5. What the launch needs from SpringBoard, backboardd, and the display

Experiment: an interposer of our own (`lookuptrace.c`) was loaded into the
probe through `__Environment` (`DYLD_INSERT_LIBRARIES`). It logs Mach lookups
into the same stderr as the report, and it can make chosen lookups fail with
1102 (unknown service).

Lookups before `didFinishLaunching`, in order:
`com.apple.backboard.display.services`, `com.apple.cfprefsd.daemon` (XPC),
`com.apple.runningboard` (XPC), `com.apple.CARenderServer`. After the report:
`com.apple.lsd.mapdb`, `com.apple.fontservicesd`,
`com.apple.uiintelligencesupport.agent`, `com.apple.backboard.hid.services`.
The FrontBoard workspace connection (SpringBoard) is made before the report
through BoardServices, by a path these two hooks do not see (the app's log
shows it).

Job plists (read as a file format): `com.apple.backboard.display.services`
and `com.apple.CARenderServer` are MachServices of `com.apple.backboardd`;
`com.apple.frontboard.systemappservices` is a MachService of
`com.apple.SpringBoard`; `com.apple.runningboard` belongs to runningboardd;
`com.apple.lsd.open` and `com.apple.lsd.mapdb` belong to lsd;
`com.apple.installcoordinationd`, `com.apple.mobile.installd`, and
`com.apple.containermanagerd` belong to the daemons of the same names.

| Denied name | Launch path | Result |
|---|---|---|
| none | FrontBoard | report, scene, window |
| `com.apple.backboard.display.services` | FrontBoard and one-shot | **No report.** The app dies from a breakpoint trap in UIKit's `UIApplicationMain` preparation (crash backtrace: `BKSDisplayServicesStart` ← `_UIApplicationMainPreparations` ← `UIApplicationMain`), 0.23 s after start. |
| `com.apple.CARenderServer` | FrontBoard | 11 lookup attempts, 0.5 s apart (about 5 s), then **report written**. Then the scene connects, and the app aborts with "Failed to create remote render context". |
| `com.apple.CARenderServer` | one-shot | Same 5 s of retries, then the report. No scene, so there is no abort. |

Conclusions:

1. `didFinishLaunching` runs before any rendering and before the scene
   connects. No frame needs to be composited before the report.
2. backboardd must answer the display-services endpoint, or UIKit stops
   before `didFinishLaunching`. Reachability alone is not shown to be
   enough: on the Mac the lookup reached a live backboardd that has a host
   framebuffer behind it.
3. backboardd's render server should be lookup-able. Without it, the report
   is still produced (after about 5 s), but a scene-based app aborts when its
   first window is created. Stage 7's goal (the report) does not need the
   render server to work. Keeping a launched app alive does.
4. SpringBoard is needed for a real launch (it handles the open request and
   owns the scene). It is not needed for the one-shot fallback (§4.7).

## 6. Requirements for Ycode (derived)

1. **No bridge.** The bridge and the CoreDevice jobs (`launchd-sim.md` §4.5)
   are not needed for install or launch. Ycode supplies its own guest helper
   instead.
2. **Guest helper.** Ycode ships a small simulator-platform program, written
   clean-room from this spec, that implements install (§4.1), uninstall
   (§4.2), lookup (§4.3), and launch with debug options (§4.4). It must carry
   `com.apple.frontboard.debugapplications` in `__TEXT,__entitlements`. Ycode
   runs it with its own one-shot spawn operation (`launchd-sim.md` §7.2 item
   6) and reads its stdout for results: install done, bundle and data paths,
   pid, or an error.
3. **Readiness.** Before launching, wait until SpringBoard serves FrontBoard
   open requests. The bridge retries for up to 120 s (300 s near boot). The
   Ycode helper should retry "not ready" failures in the same way.
4. **Bundle placement.** The source `.app` must be readable at a path that
   the helper process can open, and the helper must be able to write
   installcoordinationd's `PromiseStaging` directory under `DEV/data`.
   Ycode copies the built app anywhere the guest can read, for example
   `DEV/data/tmp/ycode/`. Ycode never writes the containers, metadata plists,
   or LaunchServices store itself (§2.2).
5. **Signing.** A linker ad-hoc signature on the executable was enough. No
   bundle-level signature was needed. Whether a completely unsigned
   executable installs cannot be tested on the Mac (the host refuses to run
   it). See §7.
6. **Stdio.** Pass guest paths under `/tmp/…` and read
   `DEV/data/tmp/…` from the host. Create the directory first, or rely on
   `xpcproxy_sim` creating it inside `DEV/data`.
7. **Kernel personality** needed on these paths, beyond stage 6:
   - `proc_pidpath` must work for **other** processes' pids (SpringBoard
     checks its client), and the returned path must be openable.
   - `csops_audittoken` status must succeed (the simulator library then
     serves the entitlements itself, §4.5).
   - The daemons' container and staging work needs file `rename`, directory
     creation and removal, and extended attributes (`setxattr`/`getxattr` for
     the `com.apple.containermanager.*` and `com.apple.install_*` attributes)
     under `DEV/data`.
   - `memorystatus_control` and the role calls may keep failing with EPERM
     (§3.3).
8. **backboardd.** Before stage 8 (display), Ycode must check on Linux
   whether headless backboardd serves `com.apple.backboard.display.services`.
   If it does not, the stage-7 goal is blocked before `didFinishLaunching`.
   The render server can be missing for the stage-7 goal. It costs about 5 s
   per launch, and the app aborts afterwards.
9. **App templates.** Apps must adopt the scene lifecycle
   (`simulator-observations.md`). Apps that are launched only for a report
   can still use the one-shot fallback (§4.7) during bring-up.

## 7. Open questions

1. **Headless backboardd on Linux.** Does it register and answer
   `com.apple.backboard.display.services` and `com.apple.CARenderServer`
   without `SimFramebufferServer` and the other host display services? Test:
   run the probe as a one-shot (§4.7) on Thor, then use the FrontBoard path.
2. **SpringBoard without a display.** Does SpringBoard's open-request
   service start and accept requests headless? Stage 6 shows SpringBoard
   running, but not whether its workspace is ready.
3. **Install without SpringBoard and the icon pipeline.** SpringBoard and
   the lsd icon cache take part in the install (placeholder icons). Is any of
   that on the critical path? This was not testable on the Mac.
4. **Unsigned executables.** On Linux, Ycode can run binaries with no
   signature at all. Does installd's verification step (0.00–0.01 s on the
   Mac) accept them, or must Ycode ad-hoc sign the executable (for example
   with an open-source signer)?
5. **How SpringBoard reads a peer's entitlements.** §4.5 is shown for a
   self-check. That a peer check uses the same `proc_pidpath` + file read
   path is inferred, not observed.
6. **Completion block shape.** The install completion was observed with two
   arguments (bundle id, error). The block's declared signature cannot be read
   from metadata. The error-path arguments were not observed.
7. **Untested options:** `__WaitForDebugger` (for a future debugger stage),
   `PackageType` values other than `Developer`, and `IsUserInitiated`.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Install chain, daemons, phases, log lines §2.1 | 3 | guest `log stream`/`log show` (`simctl spawn … log`) during `simctl install`; bridge messages read in JSON form |
| Files, metadata keys, xattrs, changed files §2.2 | 2, 3 | file-system diff before and after install; metadata plists read as a format (`plutil -p`); `xattr -l`; `unzip -l` |
| Install timings §2.3, §4.1 | 3 | installd completion logs; ylaunch timings |
| Launch chain, retry defaults §3.1 | 3 | guest logs during `simctl launch` |
| Job description keys §3.2, plist-importer warning | 3 | runningboardd log of the constructed job; `launchd.log` |
| EPERM calls in runningboardd §3.3 | 3 | runningboardd log |
| Stdio path rewriting and failure mode §3.4 | 3 | ylaunch launches with varied paths; `lsof` of the app; `launchd.log` |
| Order inside the app §3.5 | 3 | stderr file birth and modification times against the app's log; suspended launch |
| Classes, selectors, type encodings, absent C functions §4 | 4 | our program's run-time introspection (`objc_getClass`, `class_copyMethodList`, `method_getTypeEncoding`, `dlsym`) |
| Option-key string values §4.4 | 4 | our program reading exported constants with `dlsym` |
| Behavior of each interface, errors, entitlement matrix §4.1–§4.4 | 3 | ylaunch runs and the SpringBoard, lsd, installd, and InstallCoordination log lines they caused |
| Entitlements from section vs signature; csops/proc_pidpath sequence §4.5 | 3 | entitled helper variants; `enttrace.c` interposer on our own process; csops operation numbers from XNU open source (level 1) |
| Minimal sequence §4.6 | 3 | `run-sequence.sh` end to end on a throwaway device |
| One-shot fallback §4.7 | 3 | `simctl spawn` of the installed executable; app log |
| Service lookups, deny experiments, crash frames §5 | 3 | `lookuptrace.c` interposer in our probe; launchd.log; our probe's crash report |
| Service-to-job mapping §5 | 2 | RR LaunchDaemons plists read with `plistlib` |
| Requirements and open questions §6–§7 | — | derived from the above |

No disassembly or decompilation was used (level 5 not used). Our sources are
in `research/experiments/simulator/app-launch/`: `ylaunch.m`,
`ylaunch.entitlements`, `lookuptrace.c`, `enttrace.c`, `build.sh`, and
`run-sequence.sh`. The raw logs stayed in the session scratch directory and
are not committed.
