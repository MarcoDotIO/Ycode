# Spec: launching the runtime's apps (Safari, Settings and the rest)

Status: **partly implemented** (agent APP-LAUNCH, 2026-10-19, 2026-10-20;
agent APP-FIX, 2026-10-20). §3.1–§3.5 are implemented (§3.5 still with
the provisional cache-only image files: Q1 answered against them, but the
root the loader accepts was not found on Ycode, §3.5 last part, Q6); the
poster-app open requests are answered (§2.1, §8.2); §3.6
(`thread_suspend`), §3.7 (a GPU submission that never completes) and §3.8
(one `dasd` fault) are open, with the questions in §8. Launch times: §9. It records, for every
app that the iOS 27.1 runtime (24A94401) can launch (`home-apps.md` §2.3),
what happens when Ycode launches it, why, and what Ycode changed.

Terms as in `launchd-sim.md` and `app-install-launch.md` (RR, DEV, TMP,
ylaunch, one-shot).

## 1. Method

Ycode runs on the Thor, Apple's runtime as a black box (level 3):

- **Cold runs** (`ycode-sim` launcher, no warm boot): a full boot (no lean
  profile), `--launch <bundle id>` (ylaunch `open`, `app-install-launch.md`
  §4), a guest `log stream` one-shot filtered to the app's processes,
  screenshots of the cover display every 120 s.
- **Warm runs** (the launcher with `YCODE_WARM_BOOT=1`, `snapshot.md` §12):
  one cold boot saves the device; every later run restores it (home screen
  in seconds), launches one app, keeps the newest frame 40 s after the
  launch result, and stops (the app is ended, the device saved again).
- **Crash reports**: ycode-simd prints one report per process that ends
  with a fault or `abort()`: the faulting thread's registers, the image and
  offset of the PC, and the libraries' crash annotation strings
  (`service-fidelity.md` §3.2). Since this change the first line names the
  process (`fatal guest condition in <executable name> on thread …`).
- **Guest probes**: small programs of our own, run as one-shots, that call
  public or exported functions and print the results (`bundleprobe`, §3.5).

The reference app set and the reference launch results are `home-apps.md`
§2.3. This spec did not observe the reference.

## 2. Per-app status

"Before" is the line before this change (main line 9195ba1); "after" is this
change. "Launches" means ylaunch's open request completed with a process
(`app-install-launch.md` §3.4) and the process was alive when the frame was
taken.

| App | Bundle id | Reference (`home-apps.md`) | Ycode before | Ycode after |
|---|---|---|---|---|
| Safari | `com.apple.mobilesafari` | launches | **crashes at start** (§3.1): back to the home screen | launches from the home screen (dock tile) and with `ylaunch open`; Start Page; a `data:` URL given with `--app-url` is drawn; WebContent, Networking and GPU processes start once and stay up (§3.5) |
| Settings | `com.apple.Preferences` | launches; Settings list | launches | launches from the home screen and with `ylaunch open`; Settings list (Apple Account, General, Accessibility, …) |
| Web | `com.apple.webapp` | launches | — | launched (warm run t2; one fatal report in another process during the run) |
| Xcode Previews | `com.apple.PreviewShell` | launches | — | launched (t2) |
| VoiceOver | `com.apple.VoiceOverTouch` | launches | — | launched (t2) |
| other `CoreServices` apps, posters | see §2.1 | §2.3 | | |

### 2.1 The other launchable records

Warm run t2 (one restore or cold boot per app; "launched" = the open
request completed with a process; the fatal count is every fatal report of
the run, mostly the daemons of §7):

| Bundle id | Result | Fatal reports in the run |
|---|---|---|
| `com.apple.assistivetouchd`, `com.apple.fullkeyboardaccess`, `com.apple.commandandcontrol`, `com.apple.livetranscriptionui` | launched | 0 |
| `com.apple.CarPlayApp` | launched | 1 |
| `com.apple.ShortcutsActions`, `com.apple.SystemIntents`, `com.apple.EscrowSecurityAlert` | launched | 12, 3, 2 (cold boot or restore daemons) |
| `com.apple.NanoUniverse.AegirProxyApp`, `com.apple.GradientPoster`, `com.apple.EmojiPoster`, `com.apple.Posters.ImagePlaygroundPosterApp`, `com.apple.Posters.KaleidoscopePosterApp`, `com.apple.PridePoster`, `com.apple.Posters.UnityPosterApp`, `com.apple.Posters.WeatherPosterApp` | no answer to the open request within the run (timeout) | 17–32 |

The poster apps are not on the home screen (`home-apps.md` §2.3); whether
the reference answers an open request for them was Q5: it answers each with
`FBSOpenApplicationServiceErrorDomain` 1, reason NotFound, after about 12 s
(§8, §8.2), so Ycode's missing answer is a difference.

**Cause and fix (APP-FIX, 2026-10-20).** The guest did answer: in run t2
SpringBoard answered every open request for a poster app at once with
`FBSOpenApplicationServiceErrorDomain` 4 (InvalidRequest), underlying
`FBSOpenApplicationErrorDomain` 4, reason NotFound ("Application info
provider (FBSApplicationLibrary) returned nil"). It was Ycode's `ylaunch`
that never reported it: it retried every failure every 2 s (a device that
is still booting also fails), and the run ended before its retry limit.
`ylaunch open` now treats an answer whose error, or an underlying error,
has `BSErrorCodeDescription` NotFound as "unknown to FrontBoard": it
retries that answer for 10 s (`YLAUNCH_NOTFOUND_SECONDS`; the reference's
wait for app availability, §8.2) and then exits 1 with
`error open <id> (attempt N, T s, application unknown to FrontBoard): <error>`;
no process is started. Other failures keep the 120 s window. Measured on
a fresh device (run a1, before the window was widened to the full 10 s):
the request was answered after 8.6 s, 5 attempts. With the full window,
after a restore (run c1, `com.apple.GradientPoster`): 6 attempts, `ylaunch`
gave up at 10.1 s, the app step's open request took 13.0 s (reference
≈12.2 s), no process was started, and the device saved at the stop.

Remaining difference: the reference answers with domain code **1**
("denied by service delegate (SBMainWorkspace)") after its own 2 s
retries, because CoreSimulatorBridge's request names the LaunchServices
record (cache GUID and sequence number, §8.2); `ylaunch`'s request names
only the bundle identifier, so Ycode's SpringBoard answers code 4 at once,
as the reference does for an identifier with no record. Making Ycode's
request carry the same record identity needs the bridge's option keys
(Q7).

## 3. Causes and fixes

### 3.1 `mach_port_get_refs` (Safari's crash at start)

**Symptom.** Safari's process ended about one second after its start with a
`BRK` in JavaScriptCore (ISS `0xbb08`, the WebKit crash trap), right after
the line `unimplemented libfunc mach_port_get_refs` from JavaScriptCore.
SpringBoard then showed the home screen again ("Process exited … signal").
The same crash ended every other process that loads JavaScriptCore at start
(one more at boot).

**Cause.** `mach_port_get_refs` was a generated stub in Ycode's
`libsystem_kernel` (KERN_NOT_SUPPORTED). JavaScriptCore checks the result of
the call and stops the process when it fails.

**Fix.** `mach_port_get_refs` (and `_kernelrpc_mach_port_get_refs`) is the
MIG routine 3207 of the `mach_port` subsystem on the task port (xnu
`mach_port.defs`, level 1): request NDR, name, right (40 bytes); reply
RetCode and the count (40 bytes), or `mig_reply_error_t` (36 bytes). Ycode's
task-port server already answered it (`MachIPCKernelServer`); only the
client was missing. `mach_port_set_mscount` (3210, also served) got its
client too. Code: `SimHostLibs/kernel/mig.c`.

### 3.2 Large anonymous reservations (WebKit's content process)

**Symptom.** After §3.1, Safari stays up, but every `com.apple.WebKit.WebContent`
process ends at start with the same `BRK`, right after
`guest mapping failed: backing for 0x800000000 bytes (anonymous): anonymous
pool failed … no free run of 34359738368 bytes`.

**Cause.** JavaScriptCore reserves one 32 GiB region of anonymous memory at
start (its cage for JavaScript heap memory) and uses only a small part of
it. Ycode backed every anonymous mapping at once with contiguous guest
physical memory from a 16 GiB pool, so the mapping failed (ENOMEM) and
JavaScriptCore stopped the process. On Darwin an anonymous mapping costs no
memory until it is touched (mmap(2), level 1).

**Fix (Ycode design).** An anonymous mapping of at least 256 MiB
(`GuestAddressSpace.lazyAnonymousThreshold`; `YCODE_LAZY_ANON_MB`, 0 turns it
off) is *lazy*: it is entered in the address space with its protection but
without backing and without page-table entries. A page gets backing the
first time it is touched:

- a guest data or instruction abort from EL0 with a translation fault
  (FSC 0x04–0x07) at an address in a lazy mapping whose protection is not
  `PROT_NONE`: the 256 KiB block around the address (aligned, clipped to
  the mapping) gets zeroed pool memory and page-table entries with the
  mapping's protection, and the instruction runs again
  (`DarwinKernel` → `GuestVirtualMemory.resolveTranslationFault`);
- a VMM read or write of the range (system call arguments): the same, so
  untouched pages read as zeros.

A touched block becomes an ordinary anonymous mapping (released by
`munmap`, saved by a snapshot). `mprotect` on a lazy range changes its
protection only (no entries to change). A fault in a lazy `PROT_NONE` range
stays a fault (SIGSEGV), as on Darwin. `mach_vm_region` reports a lazy range
as private anonymous memory. A snapshot records the untouched part as an
anonymous region with no pages (`SnapshotSupport`). Mappings below the
threshold keep the old behavior.

Result: the content process passes its start (no fatal report in three
runs). Code: `YcodeDarwinABI/AddressSpace.swift`,
`YcodeDarwinKernel/DarwinKernel.swift`; tests
`YcodeDarwinABITests/LazyAnonymousTests`.

### 3.3 A copied device used the original's containers

**Symptom.** Safari's stderr reported "Failed to open cache settings store at
file:///…/<another agent's device>/data/Containers/Data/Application/…".
SpringBoard's SplashBoard purged snapshots in the same foreign path. Every
copy of a booted device (ycode-sim-serve's pristine device, a benchmark's
golden device, `YCODE_DEVICE_TEMPLATE`) handed its apps the containers of
the device it was copied from, so all copies shared Safari's data
container, and the user's device wrote into another directory.

**Cause.** The guest sees host paths. LaunchServices keeps the absolute
paths of every app's bundle and data containers in its store
(`DEV/data/var/db/lsd/com.apple.LaunchServices-<n>-v2.csstore`,
`first-boot.md` §1 item 5); containermanagerd's own records are relative
(no foreign path in `DEV/data/Library/MobileContainerManager`). A search of
a copied device for the original's path found it in the LaunchServices
store, FrontBoard's `applicationState.db` journal, the unified-log files and
a few daemons' databases and preferences (photo library, replicatord,
chronod, Spotlight's embedding cache, ManagedSettings).

**Fix (Ycode design, revised 2026-10-23).** The guest path of a device
directory is a property of its data, not of where the directory lies on
the host. `ycode-simd --device` serves DEV to the guest at DEV's *guest
path*: the path the data was first booted at, recorded in
`DEV/ycode-device-path`. A copy or a move keeps it: the VMM's prefix for
DEV maps that guest path to the copy's own directory, and everything the
guest is told about DEV (the bootstrap plist's job paths, `HOME`,
`CFFIXED_USER_HOME`, `TMPDIR`, `SIMULATOR_HOST_HOME`, `SIMULATOR_LOG_ROOT`,
the shared-resources, capabilities, audio, memory-warning and
extended-display paths, the framebuffer and HID library paths, the memory
directory, one-shot programs and their output files, `ylaunch`'s
arguments) is given at the guest path. The paths LaunchServices and the
other daemons stored then name the copy's own containers, and no store
needs rebuilding. The rule, before each cold boot:

1. The guest path is the record; for data without one (made before the
   record existed), the device path the LaunchServices store names in
   front of `/data/Containers/`; for a DEV without data that
   `YCODE_DEVICE_TEMPLATE` fills, the template's; for new data, DEV's own
   path. The launcher, the viewer and the harness copy the whole device
   directory (`cp -a`), so the record comes with it.
2. A guest path the guest cannot be given at its own place (not a
   normalized absolute path, or overlapping the guest's `/tmp`, `/var`,
   `/etc`, `/private`, `/System`, `/dev`, the runtime root or a job path
   outside DEV) is not used; the device uses its own path and says so.
3. The LaunchServices store files (`*.csstore`) that name a device path
   other than the guest path in front of `/data/Containers/` are removed
   (a byte search of a few MB, milliseconds), and lsd seeds a new store from the device's own containers at
   this boot, as on a first boot ("the LaunchServices store names …, not
   the device's guest path …: removed (N files)"). A store that names no
   device path (the system-only store,
   `SystemDataOnly-com.apple.LaunchServices-<n>-v2.csstore`, which names
   only runtime-root paths) stays. This covers data put together from two
   devices, a record that names the device's own path over a store that
   names another, and a device whose guest path cannot be kept (item 2).
4. The guest path is recorded.

The host side keeps using DEV's host path (file copies, the snapshot's
`device-path`, the memory directory's name, the UDID, which still hashes
the host path, so copies get UDIDs of their own). A warm restore uses the
recorded guest path and never relocates (a snapshot belongs to one device
path, `snapshot.md` §12.2). Two devices with the same guest path can run
at once: each VMM has its own prefix table. Code:
`ycode-simd/DeviceRelocation.swift`, `DeviceLayout.guestPath(_:)`
(`DeviceMode.swift`); tests `YcodeSimdTests/DeviceRelocationTests`.

Cost: none for a copy that keeps its guest path (idle-host benchmark
boots of copies: 60–70 s to the home screen against 100–105 s with the
rebuild, `frame-profile.md` §8.6). The first fix (the
APP-LAUNCH merge, until 2026-10-23) recorded the host path instead and
removed both stores of every copy, and lsd's rebuild cost 45–50 s on every
benchmark boot (`frame-profile.md` §8.6). Keeping the system-only store
and removing only the device store does not make the rebuild cheaper
(benchmark boots of 110 s with only the device store removed against 105 s
with both, §8.6), so the copy keeps its guest path instead.

### 3.4 Library functions apps call at start

Functions that ran as unimplemented stubs during app launches (counts from
runs r1–r2), now implemented (`SimHostLibs/kernel/appsupport.c`, VMM routine
in `YcodeDarwinKernel/ThreadInfo.swift`; layouts from the public
`mach/thread_info.h`, `thread_policy.h`, `host_info.h`, `vm_statistics.h`
and libproc's internal header, level 1):

| Function | Caller seen | Ycode answer |
|---|---|---|
| `thread_info` | PlugInKit (every extension host), CoreAudio, DialogEngine | Private routine `0x7963_2030`. THREAD_BASIC_INFO (10 words), THREAD_IDENTIFIER_INFO (6: thread id, pthread, the libdispatch queue slot), THREAD_EXTENDED_INFO (28), THREAD_SCHED_TIMESHARE_INFO (5). CPU time for the calling thread only (its host thread's time); priority 31 of 63; run state RUNNING or WAITING (blocked in the kernel); other flavors KERN_INVALID_ARGUMENT, a short count MIG_ARRAY_TOO_SMALL |
| `thread_policy_set` | QuartzCore (render thread, time constraint), AnimationKit | Accepted, not applied (the host schedules guest threads, `scheduling-policy.md`); unknown flavor or short count KERN_INVALID_ARGUMENT |
| `thread_policy_get` | Foundation | The default policy, `*get_default` = TRUE |
| `host_statistics`, `host_statistics64` | FrontBoard (SpringBoard, apps) | HOST_LOAD_INFO zeros; HOST_VM_INFO / HOST_VM_INFO64: the 1 GiB guest as ½ free, ¼ active, ⅛ inactive, ⅛ wired, no paging; HOST_CPU_LOAD_INFO: time since boot as idle ticks |
| `proc_set_cpumon_params`, `_defaults`, `_params_fatal`, `proc_disable_cpumon`, `proc_resume_cpumon`, `proc_get_cpumon_params`, the wakeup-monitor equivalents, `proc_setcpu_percentage`, `proc_clear_cpulimits`, `proc_setthread_cpupercent` | mediaanalysisd, QuartzCore | Success with no effect (Ycode has no resource monitors); queries report a disabled monitor |

### 3.5 WebKit's helper processes could not find WebKit's entry points

**Symptom.** With §3.1–§3.2, Safari asks for a page (a `data:` URL given
with `--app-url`, §5): the address bar shows the URL and a progress bar,
but no page is drawn. runningboardd starts `com.apple.WebKit.WebContent`
and `com.apple.WebKit.Networking` (ExtensionKit extensions,
`RR/System/Library/ExtensionKit/Extensions/WebContentExtension.appex` and
others; WebKit has no XPC services in this runtime), and each ends at once:

```
com.apple.WebKit.Networking: Cannot find executable for CFBundle … <RR>/System/Library/Frameworks/WebKit.framework
(WebKit) Exiting: Unable to find entry point in WebKit.framework with name: NetworkServiceInitializer
```

Safari starts new ones again and again (hundreds in a few minutes).

**Cause.** WebKit's service main (open-source WebKit,
`Shared/EntryPointUtilities/Cocoa/XPCService/XPCServiceMain.mm`, level 1)
finds its initializer with `CFBundleGetBundleWithIdentifier("com.apple.WebKit")`
and `CFBundleGetFunctionPointerForName`. CoreFoundation gets a symbol from
a bundle only through a loader handle, and it gets that handle
(`dlopen` with `RTLD_NOLOAD`) only after it has found the bundle's
executable: a file at the path, or a path that
`_dyld_shared_cache_contains_path` accepts (swift-corelibs-foundation
`CFBundle_Executable.c`, `CFBundle_Binary.c`, level 1). In this runtime the
framework directories hold no executables (the images exist only in the
shared cache), and the loader names every cache image of a simulator
process with the runtime-root prefix (open-source dyld: cache images get
"just in time" loaders whose path is the sim root plus the install name;
prebuilt loaders are not built for simulator dyld; level 1). The loader's
`_dyld_shared_cache_contains_path` compares the string with the cache's
paths unchanged, so a prefixed path is never in the cache.

Guest probes (one-shots and `--exec` runs of our own programs, level 3):

| Call in the guest | Result on Ycode before the fix |
|---|---|
| `stat("<RR>/System/Library/Frameworks/UIKit.framework/UIKit")` | ENOENT (no such file in the runtime) |
| `_dyld_shared_cache_contains_path` of the bare path / the `<RR>` path / the `System/Cryptexes/OS` path | 1 / **0** / 1 |
| `_dyld_get_image_name` of WebKit | `<RR>/System/Library/Frameworks/WebKit.framework/WebKit` |
| `CFBundleGetBundleWithIdentifier("com.apple.WebKit")` | the bundle at `<RR>/System/Library/Frameworks/WebKit.framework` (a symbolic link into `System/Cryptexes/OS`) |
| `CFBundleCopyExecutableURL` of it, `-[NSBundle executablePath]` | NULL |
| `CFBundleGetFunctionPointerForName(…, "WebContentServiceInitializer")` | NULL |

With `DYLD_PRINT_APIS`, CoreFoundation asks `_dyld_shared_cache_contains_path`
for `…/WebKit.framework/MacOS/WebKit` and `…/WebKit.framework/WebKit`, both
with the `<RR>` prefix, after a `stat` of each.

**Fix (Ycode design, provisional until Q1; Q1 answered against it, see the reference answer below).** *Cache-only image files*: a
guest `stat`, `lstat`, `access`/`faccessat` or `fstatat` of `<RR> + P`, where
no host file exists and `P` is the path of an image in the runtime's cache
(its image table; with or without the `/System/Cryptexes/OS` prefix,
either as asked or after the path's symbolic links), reports a read-only
regular file (mode 0555, size 0, uid 0, a stable inode, the runtime root's
device). Nothing else changes: `open` of the path is still ENOENT, a
directory listing does not show it, paths below `/usr/lib/system/` are
excluded. `YCODE_CACHE_IMAGE_FILES=0` turns it off.

The loader must not see these files: the 27.1 `dyld_sim` takes a regular
file at the `<RR>` candidate path for a file that overrides the cache,
tries to load it (`dylib-from-disk-to-override-cache`), fails to open it
and only then uses the cache image — one failed attempt per dependency of
every process (613 in a WebKit probe). So a `stat` trap whose PC is in the
host page's code (the loader's `stat` helper, `dyld-sim-handoff.md` §7.3)
sees no cache-only files, on both the locked and the task-local path.

Result: CoreFoundation finds the executable, `dlopen(RTLD_NOLOAD)` returns
the loaded WebKit, `CFBundleGetFunctionPointerForName` returns the
initializer (probe p4); the loader's search is as before (only the three
host libraries override the cache). On a full boot WebContent, Networking
and GPU start once per Safari process and stay up; Safari draws the
`data:` page (runs a1, c0, d1). Code: `YcodeDarwinABI/CacheImageFiles.swift`,
`DarwinFileSystem.stat`, `DarwinKernel.isLoaderHelper` (`TaskLocalTraps.swift`,
`DarwinKernel.handleBSD`); tests `YcodeDarwinABITests/CacheImageFilesTests`,
`YcodeDarwinKernelTests/TaskLocalTrapTests.cacheImageFilesAreHiddenFromTheLoaderHelper`.

This choice is not reference behavior: on the reference the same
CoreFoundation and loader binaries must get a yes from one of the two
checks, and which one (a file on the reference's runtime volume, or
something else) is Q1. If the reference answers differently, this design
is replaced by that answer.

**Reference answer (Q1/Q4, §8.1).** The reference gets the yes from the
loader query, not from a file. In a reference simulator process every
`stat`, `lstat`, `access` and `open` of a cache-only executable is ENOENT
under every spelling, and `_dyld_shared_cache_contains_path` returns 1 for
the `<RR>`-prefixed spelling. So the cache-only image files above are **not
reference behavior** and contradict it in one observable point (a guest
`stat` succeeds on Ycode, fails on the reference). The reference reproduces
Ycode's original failure exactly when the root spelling in the process
environment differs from the root's symbolic-link-free spelling (§8.1,
last table), which points at the cause on Ycode: the rooted spelling that
the loader accepts must be the same string as the one it puts in the
image names.

**Ycode-side search for the accepted root (2026-10-20, not finished).**
With the cache-only image files off (`YCODE_CACHE_IMAGE_FILES=0`), an
`--exec` run of `bundleprobe` with `--trace` (level 3) shows that every
root string the guest loader can get from Ycode is the same, symbolic-link
free spelling `<RR>` (the Thor's runtime root has no symbolic link in it):

| Input to the loader | What Ycode gives |
|---|---|
| `DYLD_ROOT_PATH`, `IPHONE_SIMULATOR_ROOT`, `SIMULATOR_ROOT` | `<RR>` |
| `DYLD_SHARED_CACHE_DIR` | `<RR>/System/Library/Caches/com.apple.dyld` |
| `F_GETPATH` of the cache directory it opens (`<RR>/…/com.apple.dyld/`) | `<RR>/System/Library/Caches/com.apple.dyld` |
| `fsgetpath` of the cache file's id (twice, at startup) | `<RR>/System/Library/Caches/com.apple.dyld/dyld_sim_shared_cache_arm64` (length with the NUL) |
| `F_GETPATH` of the main executable | its own path |
| image names (`_dyld_get_image_name`) | `<RR>` + install name |

The query makes no trap when it is called (no `realpath` helper call, no
file call), so it compares against state built at startup. Still, the
query accepts no rooted spelling on Ycode: with `<RR>`, the cache
directory, the cache file, `<RR>/usr/lib`, `<RR>/System/Cryptexes/OS`, the
executable's directory or `/` as the prefix, WebKit and UIKit answer 0; the plain and the plain cryptex
spellings answer 1. Adding `dyld_sim` (path `<RR>/usr/lib/dyld_sim`) to the
host image list (`dyld-sim-handoff.md` §1.4 step 3; Ycode's list holds only
the main executable, §4.5) did not change any answer, and was not kept. So
the accepted root on Ycode is not one of the strings above; the input the
27.1 loader takes it from is not yet known (Q6). Until it is, the
cache-only image files stay (design as above), with their one known
difference from the reference (`stat` succeeds).

### 3.6 `thread_suspend` / `thread_resume` (open)

JavaScriptCore's garbage collector suspends each other thread that ran
JavaScript, reads its registers (`thread_get_state`) and scans its stack.
Both are stubs (KERN_NOT_SUPPORTED); Safari called them more than 1,200
times in four minutes. JavaScriptCore treats a failed suspend as "thread
gone" and skips that thread's stack, so objects that only it references can
be collected. This has not caused a visible failure yet. Design for the
fix (not implemented; it touches the vCPU run loop and the kernel lock,
which other agents change now): a per-thread suspend count; the target's
vCPU is kicked and parks at its next exit to the VMM in EL0 (or at the end
of its trap), publishing its registers; `thread_get_state` of a suspended
thread waits (without the kernel lock) until it is parked or blocked in the
kernel; `thread_resume` at count 0 releases it.

### 3.7 A GPU submission that never completes (explained; fixed in this agent's boots, `stage8-contract.md` §15.6)

In two of 14 display-server sessions (runs c0, c1: full boots whose app
step opened Safari with a `data:` URL)
one Vulkan submission of a WebKit process (`xpcproxy_sim` exec'd into a
WebKit extension; 4–7 draws, the shaders `Vfx…+BclrXc…`, `Vfx…+Xc…` and the
buffer-to-image blit) is still running after 10 s and never finishes
("serial N still running after 770 s"). From then on no new frame is
presented (c1: every measurement after Safari's first frame saw no frame),
and the stop cannot be saved ("3 Metal command buffers in flight"). The
runs without a display server (a1, b1) and the other twelve sessions
(full boots and restores, Safari with and without a URL) did not show it. Not investigated further here (the Metal backend is
another agent's area; FPS-GPU measured on the same GPU at the time).

GPU-2 (2026-10-23) reproduced it in three of seven such boots and named
the work with hang reports and the device-loss checkpoint markers
(`stage8-contract.md` §15.2, §15.6): WebKit's command buffer for its
layer surface, stuck in Core Animation's uber-shader draw (`VfxXg+Xgc`),
which samples the render target it draws into (a destination read; on
Apple's GPUs ordered by a render-target memory barrier). In Vulkan that
is an undefined feedback loop, and on the Thor it stalled the GPU; when
another simulator needs the GPU the driver then kills the context
(Xid 109), the device loss of other runs. Not the cause: the pipeline
library linking, the out-of-line helpers, the text draws' buffer reads
(replayed offline with the captured bytes). Two of the seven captured
hangs had no such draw in the stuck command buffer; their stuck draw is
unknown. The back end now gives a draw that samples its own target a copy
of the target made just before it: 0 of 10 boots hung with it (6 copying
the whole target, 4 only the draw's scissor rectangle, the default),
against 6 of 16 without (§15.6 there).

### 3.8 One `dasd` fault (open)

Run b1: `dasd` stopped with a write translation fault in
`libsystem_malloc` at an address in no region (0x352d243800). Seen once
in 13 boots; not reproduced.

## 4. Networking in the guest

Ycode's guest has **no IP networking**: `socket(AF_INET/AF_INET6, …)` fails
with EAFNOSUPPORT (only AF_UNIX exists, `stage4b-contract.md` §6). Name
lookups fail: Safari's App Store bag fetches end with `NSURLErrorDomain`
−1003 (host not found). A page from the network cannot load; a `data:` URL
needs no network but is blocked by §3.5. Giving the guest networking means
host-backed AF_INET/AF_INET6 sockets in the kernel (connect, poll/kqueue,
socket options), the DNS path the runtime uses (its resolver daemon talks
to a host service on the Mac), and the network-path services that
CFNetwork consults before it connects; it is not part of this change.

## 5. Tools

- `ycode-simd --app-url <url>` (and the launcher, which passes it like the
  other app options): with `--launch`, the open request carries the URL as
  its payload, as a link opened from another app would
  (`FBSOpenApplicationOptionKeyPayloadURL`, read from FrontBoardServices at
  run time; ylaunch `open --url`).
- The process name in fatal reports (§1).
- `ycode-simd` prints "app launch: open request took N ms" for the
  `--launch` step (ylaunch's spawn to its exit).
- `ylaunch open … --relaunch` kills the running instance (SIGKILL) and
  starts a new process; `ylaunch kill <id>` kills the processes whose
  executables lie in the app's bundle (libproc); `ylaunch wait <s>` spaces
  one-shots; after "launched … pid N" ylaunch prints "open took N ms" (the
  first open request to its completion with a process).
- Launch timing harness (in the agent's area on the host, not in the
  repository): a display-stream client (`scripts/ycode-display-probe`'s
  `Probe`) taps an icon or the home button, or waits for the app step's
  log line, and times the frames that follow (§9).
- The warm-run triage loop used for §2 (in the agent's area on the host;
  not in the repository): restore, launch one app, wait, keep the frame and
  the app's stderr, stop.

## 6. `home-apps.md` §6 checks

| # | Check | Ycode |
|---|---|---|
| 1 | Home screen app set | Settings on page 1, Safari in the dock (`IconState.plist`); no app added |
| 2 | Today view | `IconState.plist` `today`: Batteries (`small`) and Screen Time (`large`) — as the reference |
| 3 | `DesiredIconState.plist` | Equal to `DefaultIconState-466w-678h~iphone.plist` apart from `metadata` and a `dockUtilities` key (empty) that SpringBoard adds, **as on the reference** (Q3, §8); not the generic `~iphone` file, so the screen-size answer is right. `listUniqueIdentifiers` are the default file's (rechecked 2026-10-20 on 13 Ycode devices first-booted 10-13 to 10-20: `buttonBar`, `iconLists`, `ignored`, `listUniqueIdentifiers` and `today` equal the default file's; only `metadata` and `dockUtilities` differ). The earlier note that the list identifiers differ was not reproduced; `IconState.plist` (one page) has one list identifier, the default file's first, so a comparison with that file would show a difference. No Ycode change was needed |
| 5 | Settings and Safari first screens | §2 |
| 6 | Poster apps | §2.1 |
| 8 | Cover display orientation | sideways as the reference: status column at the top right, Safari on a dock tile at the right edge about two thirds down, the search button at the bottom right |

## 7. Daemons that crash in the same runs

Seen in every full boot, not caused by the apps (and not changed here):
`intelligencetasksd` and `AppIntentsLiveEntityService` ("XPC Peer
Requirement isn't implemented on simulators yet", the Swift XPC overlay's
own message), `fileindexerd` (FSEvents, `service-fidelity.md` §11),
`replicatord` and `chronod` (`abort()`; `service-fidelity.md` §6).

## 8. Open questions (for a reference observation)

All five were answered by a reference observation on 2026-10-20 (Apple's
Simulator on the Mac, Xcode 27.1, iOS 27.1 runtime 24A94401, a new iPhone Duo
device; our probes `research/experiments/qa/`). `<RR>` below is the
runtime root as the reference spells it: the runtime disk image mounted
under `/Library/Developer/CoreSimulator/Volumes/<volume>/…/RuntimeRoot`, a
path with no symbolic links in it.

- **Q1 — answered (level 3).** `stat` of `<RR>/System/Library/Frameworks/UIKit.framework/UIKit`
  fails (ENOENT). `_dyld_shared_cache_contains_path` returns 1 for that path
  and 1 for the path without `<RR>`. `CFBundleCopyExecutableURL` of the
  WebKit bundle and `[NSBundle bundleWithIdentifier:@"com.apple.WebKit"].executablePath`
  both return `<RR>/System/Library/Frameworks/WebKit.framework/WebKit` (a
  path where no file exists). `<RR>/System/Library/Frameworks/WebKit.framework`
  is a symbolic link (mode 0120755, target
  `../../../System/Cryptexes/OS/System/Library/Frameworks/WebKit.framework`),
  as on Ycode. Details: §8.1.
- **Q2 — answered (level 3), with a limit.** The reference simulator could
  not be cut off from the network (it shares the Mac's network; no sudo),
  so "no network" was not reproduced. What was observed: a WKWebView in our
  probe app loads a `data:text/html,…` URL, the navigation finishes in under
  1 s and the page is drawn (yellow page, heading text read back with
  `document.body.innerText`). Safari itself cannot be given a `data:` URL
  through any public path on the reference: `simctl openurl` with a `data:`
  URL fails with `LSApplicationWorkspaceErrorDomain` 115 (no app claims the
  scheme), `openURL:` from an app returns NO, and a URL passed as a launch
  argument (`simctl launch com.apple.mobilesafari <url>`) is ignored (Safari
  shows its start page). Ycode's `--app-url` open request with a payload URL
  therefore has no `simctl` equivalent; that the page renders without
  network on Ycode (§3.5) does not conflict with anything observed.
- **Q3 — answered (level 2).** Yes. The reference's `DesiredIconState.plist`
  on a new iPhone Duo device has `dockUtilities` = empty array. Its keys:
  `buttonBar`, `dockUtilities`, `iconLists`, `ignored`,
  `listUniqueIdentifiers`, `metadata`, `today`. Compared with the runtime's
  `DefaultIconState-466w-678h~iphone.plist` (which has no `dockUtilities`):
  `buttonBar`, `iconLists`, `ignored`, `today` **and `listUniqueIdentifiers`**
  are equal; only `metadata` (`creationDate`) and `dockUtilities` are added.
  So Ycode's file matches the reference; the difference in list
  identifiers that §6 check 3 once noted was not reproduced (§6).
  `IconState.plist` on the reference has no `dockUtilities` key on the iPhone
  (keys `buttonBar`, `defaultDisplayName`, `displayName`, `iconLists`,
  `listUniqueIdentifiers`, `today`, `uniqueIdentifier`).
- **Q4 — answered (level 3).** No. On the reference `stat`, `lstat`,
  `access(F_OK)`, `access(X_OK)` and `open(O_RDONLY)` of a cache-only
  framework executable all fail with ENOENT (errno 2), for WebKit,
  JavaScriptCore, UIKit and Foundation, under all four spellings of §8.1.
  There is no mode, size or st_dev to report. (For comparison, existing
  directories of the runtime report st_dev of the runtime volume, the same
  value for `<RR>`, `<RR>/System/Library` and the WebKit bundle directory.)
  This contradicts §3.5's cache-only image files.
- **Q5 — answered (level 3).** The reference answers each open request for
  the poster apps with an error after about 12 s. `simctl launch` of
  `com.apple.GradientPoster`, `com.apple.EmojiPoster`,
  `com.apple.Posters.ImagePlaygroundPosterApp`,
  `com.apple.Posters.KaleidoscopePosterApp`, `com.apple.PridePoster`,
  `com.apple.Posters.UnityPosterApp`, `com.apple.Posters.WeatherPosterApp`
  and `com.apple.NanoUniverse.AegirProxyApp` each returned exit status 1
  after 12–13 s with `FBSOpenApplicationServiceErrorDomain` code 1, "The
  request was denied by service delegate (SBMainWorkspace) for reason:
  NotFound ("Application "<id>" is unknown to FrontBoard")". No process
  is started. For comparison: Settings launched in 0.46 s; an identifier with
  no app record (`com.example.ycode.nonexistent`) failed at once (0.16 s,
  same domain, code 4). §8.2 has the sequence in SpringBoard's log.

- **Q6 — open (for a reference observation).** Where does the 27.1
  simulator loader take the root that `_dyld_shared_cache_contains_path`
  strips? Ycode gives the loader `<RR>` in every input listed in §3.5 (the
  root variables, `F_GETPATH` of the cache directory, `fsgetpath` of the
  cache file) and the query still rejects `<RR>`. Useful observations, all
  black-box: (a) the reference loader's own startup file calls in a
  simulator process (`fs_usage`/`dtruss`-style listing of the paths it
  opens, stats and asks `F_GETPATH`/`fsgetpath` for, in order), especially
  any open of `<RR>` itself or of a path outside the cache directory; (b)
  the `apple[]` strings of a reference simulator process (key names only);
  (c) whether the host's image list (`dyld_all_image_infos.infoArray`, as
  a debugger reads it) holds an entry for `dyld_sim` and its path; (d) the
  query's answer for `<RR>` with its last character removed + plain (to
  rule out an off-by-one in a length; the double slash is already 0,
  §8.1).

- **Q7 — open (for a reference observation).** Which keys of the open
  request (`FBSOpenApplicationOptions` dictionary, names only) carry the
  LaunchServices record identity that CoreSimulatorBridge sends with
  `simctl launch` (§8.2: "found, with a cache GUID and sequence number"),
  and what value types they have? With them, `ylaunch` could send the same
  request and get the reference's answer (code 1 after the retries).

### 8.1 Cache-only images on the reference (Q1, Q4)

Probe `cacheprobe` run with `simctl spawn` in the new iPhone Duo device
(level 3). "plain" = `/System/Library/Frameworks/F.framework/F`; "rooted" =
`<RR>` + plain; "cryptex" = `/System/Cryptexes/OS` + plain; "rooted
cryptex" = `<RR>` + cryptex.

| Spelling | `stat`/`lstat`/`access`/`open` | `_dyld_shared_cache_contains_path` WebKit, JavaScriptCore | UIKit, Foundation |
|---|---|---|---|
| plain | ENOENT (Foundation: `lstat` finds a dangling symbolic link `Versions/Current/Foundation`, mode 0120755; the others ENOENT) | 1 | 1 |
| rooted | ENOENT | **1** | **1** |
| cryptex | ENOENT | 1 | 0 |
| rooted cryptex | ENOENT | 1 | 0 |

Other answers of the same query: `<RR>/usr/lib/libSystem.B.dylib` 1 (and
`stat` ENOENT); `<RR>/System/Library/Frameworks/WebKit.framework/MacOS/WebKit`
0; the bundle directory, `<RR>/System/Library` and `<RR>` itself 0. The
cryptex spellings are accepted only for images that live in the OS cryptex
(WebKit, JavaScriptCore; the runtime's `System/Cryptexes/OS/System/Library/Frameworks`
holds `AuthenticationServices`, `BrowserKit`, `JavaScriptCore`,
`SafariServices`, `WebKit` and two `_…_SwiftUI` frameworks).

The rooted spelling is matched as an exact string: `<RR>//System/…` (double
slash), `<RR>/System/Library/Frameworks/WebKit.framework/../WebKit.framework/WebKit`,
another root such as `/foo/System/…`, and the same root reached through a
symbolic link that points at `<RR>` all return 0.

CFBundle on the reference, with `DYLD_PRINT_APIS`: CoreFoundation asks
`_dyld_shared_cache_contains_path` for `<RR>/…/WebKit.framework/MacOS/WebKit`
(answer 0) and then `<RR>/…/WebKit.framework/WebKit` (answer **1**), the same
two queries Ycode's probe saw (§3.5). It then reports the executable URL as
that rooted path, `CFBundleIsExecutableLoaded` is 1, and
`CFBundleGetFunctionPointerForName` returns non-NULL for both
`WebContentServiceInitializer` and `NetworkServiceInitializer`. The same
two queries and the same answers appear for JavaScriptCore and UIKit.

Image names (`_dyld_get_image_name`, 595 images in the probe): the main
executable has its own path; every cache image has `<RR>` + its install
name, for example `<RR>/System/Library/Frameworks/Foundation.framework/Foundation`,
`<RR>/usr/lib/libSystem.B.dylib`,
`<RR>/System/Library/Frameworks/WebKit.framework/WebKit` (not the cryptex
path), `<RR>/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore`.
`dladdr` of a WebKit symbol gives the same rooted WebKit path.

Environment of a reference simulator process (root-related entries):
`DYLD_ROOT_PATH`, `IPHONE_SIMULATOR_ROOT` and `SIMULATOR_ROOT` = `<RR>`;
`DYLD_SHARED_CACHE_DIR` = `<RR>/System/Library/Caches/com.apple.dyld`
(files `dyld_sim_shared_cache_arm64`, `.01`, `.atlas`, `.map`);
`DYLD_FALLBACK_FRAMEWORK_PATH` = `<RR>/System/Library/Frameworks`;
`DYLD_FALLBACK_LIBRARY_PATH` = `<RR>/usr/lib`.

Which root does the loader accept? The probe re-ran itself (`posix_spawn`)
with root variables replaced by `L`, a symbolic link to `<RR>`:

| Changed in the child's environment | Image names start with | query of `<RR>`+WebKit | query of `L`+WebKit | CFBundle executable URL, initializer lookup |
|---|---|---|---|---|
| nothing | `<RR>` | 1 | 0 | rooted path, non-NULL |
| `DYLD_ROOT_PATH` = `L` | **`L`** | 1 | **0** | **NULL, NULL** (`executablePath` nil) |
| `IPHONE_SIMULATOR_ROOT` = `L` | — | 1 | 0 | — |
| `SIMULATOR_ROOT` = `L` | — | 1 | 0 | — |
| `DYLD_SHARED_CACHE_DIR` = `L/System/Library/Caches/com.apple.dyld` | — | 1 | 0 | — |
| all six root variables = `L` spellings | — | 1 | 0 | — |

So on the reference the image names follow `DYLD_ROOT_PATH` as written,
while the rooted spelling that `_dyld_shared_cache_contains_path` accepts
is the root's real (symbolic-link-free) spelling and does not follow any of
these variables. When the two differ, the reference fails exactly as Ycode
did before §3.5's fix (CFBundle finds no executable, no initializer).
Where the accepted spelling comes from was not determined at levels 1–4:
the open-source dyld (main branch, `DyldAPIs.cpp`, `DyldProcessConfig.cpp`,
`DyldSharedCache.cpp`) does no prefix handling in this query, so the 27.1
simulator loader differs from that source here. Two candidates fit every
row above: the root after its symbolic links are resolved, and the
directory of the cache file as the kernel reports the open file's path.
For Ycode this means: if the guest's runtime-root string (in
`DYLD_ROOT_PATH`) contains a symbolic link, or if the guest's path
resolution or open-file path for the cache returns another spelling, the
query fails as observed. The reference-conforming fix is to make the
rooted query succeed (consistent root spelling), not to add files.

### 8.2 The poster-app open request on the reference (Q5)

SpringBoard's log for one request (`com.apple.GradientPoster`, level 3):
CoreSimulatorBridge looks up the LaunchServices record (found, with a cache
GUID and sequence number) and sends the open request; SpringBoard's
FrontBoard system service gets nil from its application library, logs that
it "will wait 10.00s for app availability, with retry every 2.00s", and
retries six times at 2 s intervals, each failing with reason
`LaunchServicesDataMismatch` (its own LaunchServices state has no GUID and
sequence 0). It then makes a "final launch request", which fails with
reason `NotFound`, logs "Exhausted retry attempts", and answers the request
with the error. Total ≈ 12.2 s. On Ycode the request was not answered
within the run (§2.1, several minutes): the 2 s retries, the 10 s limit or
the final answer does not happen there. Since APP-FIX (§2.1): Ycode's
SpringBoard answers at once (code 4, NotFound, no wait, because the
request names no LaunchServices record); `ylaunch` repeats the request
every 2 s for 10 s and then answers NotFound, ≈13 s in all.

## 9. Launch times (Ycode, the Thor, iOS 27.1, 1 guest CPU)

Measured with the timing harness (§5): `--display-server`, a full boot or
a restore of the warm-boot device (`snapshot.md` §12), one boot at a time
while another agent used the same GPU. *Trigger* is a tap on the icon
(Settings on page 1, Safari's dock tile) or the start of the app step's
open request (`--launch`, with `--app-url` a `data:` page for Safari).
*First frame*: the first presented frame after the trigger. *Settled*: the
last frame before 2 s without a new frame (the launch animation done and
the app's first screen drawn; for Safari with a URL, the page drawn).
"Cold" means no process of the app existed; "warm" means it existed
(suspended in the background, or restored with the snapshot).

| App | Case | Trigger | First frame (s) | Settled (s) | Runs |
|---|---|---|---|---|---|
| Safari | cold, first launch after a full boot | tap | 0.93 | 2.17 | d0 |
| Safari | cold, first launch after a full boot, `--url` | open request | 0.61, 0.61 | 2.34, 2.35 | c0, c1 |
| Safari | cold, after a restore, `--url` | open request | 1.77, 0.18 | 4.14, 2.67 | g1, g2 |
| Safari | warm (backgrounded in the same boot) | tap | 0.02, 0.04 | 2.12, 2.09 | c0, d1 |
| Safari | warm, restored with the snapshot | tap | 0.73, 0.02 | 2.36, 2.08 | d1, g4 |
| Settings | cold, first launch after a full boot | tap | 1.74, 0.35 | 2.19, 2.07 | d0, c0 |
| Settings | cold, after a restore | tap | 0.03 | 2.16 | g1 |
| Settings | cold, after a restore | open request | 0.21 | 2.71 | g4 |
| Settings | warm (backgrounded in the same boot) | tap | 0.03, 0.05 | 2.74, 2.32 | c0, s1 |
| Settings | warm, restored with the snapshot | tap | 0.03, 0.02 | 3.22, 3.25 | d1, g2 |
| Settings | warm, restored with the snapshot | open request | 0.16 | 3.31 | g3 |

The open request itself (ylaunch's spawn to its exit, "app launch: open
request took") took 4.1 s and 2.2 s for Safari after a restore (g1, g2)
and 2.0 s and 1.4 s for Settings (g3, g4); FrontBoard's completion with a
process ("open took", from the request) came 43–228 ms after the request
in a full boot (b1, c0). A relaunch (`--relaunch`: SIGKILL, 2 s, open)
got its process in 89 ms (Settings) and 123 ms (Safari) and drew its
first screen (b1 screenshots: the Settings list; Safari with `data:` page
3). Home-button presses settled in 1.7–3.1 s.

A full boot reached the home screen in 40–97 s (FPS-GPU's measurements ran
at the same time); a restore showed it in about 7 s and answered the
liveness request about 0.4 s after the session was adopted.

Crashes in these runs: none of Safari, Settings or WebKit's processes. The
fatal reports were the daemons of §7 (`fileindexerd`, `intelligencetasksd`)
on full boots, none on the restores g1–g4, and once `dasd` (§3.8).

## Evidence

| Claim | Level | Source |
|---|---|---|
| Safari's crash, the `mach_port_get_refs` stub before it (§3.1) | 3 | Ycode run r1 (crash report, unimplemented-function line); SpringBoard log lines from the guest `log stream` |
| MIG routine 3207/3210 layouts (§3.1) | 1 | xnu `osfmk/mach/mach_port.defs`, MIG conventions in `mach-ipc.md` §5 |
| WebContent's 32 GiB mapping failure (§3.2) | 3 | Ycode run r2 (mapping-failure line, crash report) |
| Darwin anonymous memory is committed on touch (§3.2) | 1 | mmap(2) |
| Lazy mapping behavior (§3.2) | — | Ycode design; unit tests; runs r3, r4 (no WebContent crash) |
| Foreign container paths in a copied device (§3.3) | 3 | Safari's stderr and SpringBoard log in run r1; byte search of the copied device's files |
| LaunchServices reseeds a missing store (§3.3) | 3 | `first-boot.md` §1 item 5; run r2 (store removed, home screen and Safari launch afterwards) |
| A copy that keeps its guest path needs no store rebuild; its apps use its own containers (§3.3) | 3 | Ycode boots of copies of the pristine device (2026-10-23, runs func-settings-1, func-safari-2): "keeps its guest path" line, both stores unchanged, Settings and Safari (a `data:` page) launched and drawn, Safari's stderr without foreign paths, 52 new files in the copy's data containers and none in the original's directory |
| A store naming another device path is rebuilt; lsd rewrites the system-only store too, and keeping it does not shorten the rebuild (§3.3) | 3 | run func-reloc-safari-2 (own path recorded over the copied store: one store removed, both rewritten, the new one names the device's path, Safari launched); `frame-profile.md` §8.6 runs e1-2, base-2 |
| The store check takes milliseconds (§3.3) | 3 | both stores of the pristine device (14 MB) searched in 4 ms by a release build of the routine |
| Library functions and their callers (§3.4) | 3 | unimplemented-function lines in runs r1, r2; absent after the change (r4) |
| Structure layouts and flavors (§3.4) | 1 | public `mach/thread_info.h`, `mach/thread_policy.h`, `mach/host_info.h`, `mach/vm_statistics.h`, libproc's `libproc_internal.h` |
| WebKit helper exits, CFBundle and dyld answers (§3.5) | 3 | guest `log stream` in runs r3, r4; probe one-shots r5–r10, `--exec` probes p1–p4 (`DYLD_PRINT_APIS`, `DYLD_PRINT_SEARCHING`) |
| CFBundle's executable rule (§3.5) | 1 | swift-corelibs-foundation `CFBundle_Executable.c` (Apache 2.0) |
| WebKit's extension bundles and empty `XPCServices` (§3.5) | 4 | directory listing of the runtime on the Thor |
| WebKit's service main looks up its initializer through CFBundle (§3.5) | 1 | WebKit `XPCServiceMain.mm` |
| CFBundle needs an executable path before it takes a loader handle (§3.5) | 1 | swift-corelibs-foundation `CFBundle_Binary.c`, `CFBundle.c` |
| Simulator loader: rooted image names, no prebuilt loaders, `_dyld_shared_cache_contains_path` compares unchanged (§3.5) | 1 | open-source dyld `JustInTimeLoader.cpp`, `Defines.h`, `DyldAPIs.cpp`, `DyldProcessConfig.cpp` |
| The 27.1 loader takes a rooted regular file for a cache override (§3.5) | 3 | `DYLD_PRINT_SEARCHING` in probe p3 (613 `dylib-from-disk-to-override-cache`), p4 after the helper exclusion (3, the host libraries) |
| Helper processes stay up, the page is drawn (§3.5) | 3 | runs a1 (guest `log stream`: one WebContent, Networking, GPU; "reset WebContent crash count"), d1 (thread report), screenshots |
| GPU submission that never completes (§3.7), `dasd` fault (§3.8) | 3 | runs c0, c1, b1 |
| §3.7's cause: the stuck draw and its feedback read | 3 | GPU-2 runs `SX/GPU2/runs/sa*`, `sd*`, `se*`, `sg*`, `sh*`, `sj*` (hang reports, checkpoint markers, captures of our own translations and their reflection), host kernel log (Xid 109), `scripts/gpu-probes/rprobe.c` |
| Launch times (§9) | 3 | runs listed in §9 |
| `thread_suspend` calls from JavaScriptCore (§3.6) | 3 | unimplemented-function counts in runs r2–r4 |
| No AF_INET in the guest; −1003 (§4) | 3 | Ycode source (`SocketCalls.swift`); Safari's log lines in run r2 |
| `home-apps.md` §6 checks (§6) | 2, 3 | the device's `IconState.plist`/`DesiredIconState.plist` read with `plistlib`; compared with the runtime's SpringBoard default files; Ycode screenshots |
| Per-app results (§2) | 3 | Ycode warm runs t1 (frames, launch results, crash reports) |
| Q1, Q4: no file at any spelling, rooted query 1, cryptex spelling only for cryptex images, exact string match, CFBundle answers, image names (§8, §8.1) | 3 | reference simulator, our probe `cacheprobe` (`simctl spawn`, `DYLD_PRINT_APIS`, re-spawn with changed environment), new iPhone Duo device on 27.1, 2026-10-20 |
| WebKit bundle is a symbolic link into the OS cryptex; cryptex framework list (§8.1) | 4 | `lstat`/`readlink` in the probe; directory listing of the runtime |
| Open-source dyld does no prefix handling in the query (§8.1) | 1 | apple-oss-distributions/dyld main: `DyldAPIs.cpp`, `DyldProcessConfig.cpp`, `DyldSharedCache.cpp` |
| Q2: `data:` in WKWebView renders; Safari gets no `data:` URL from `openurl`, `openURL:` or launch arguments (§8) | 3 | our probe app `webprobe`; `simctl openurl`, `simctl launch`; screenshots (scratch only) |
| Q3: `dockUtilities` and the other keys of the reference's icon state files (§8) | 2 | `DesiredIconState.plist`, `IconState.plist` of the new device and the runtime's default files, read with `plistlib` |
| Q5: NotFound after ≈12 s, retry sequence (§8, §8.2) | 3 | `simctl launch` with timings; the device's `log show` |
| Ycode's loader inputs all spell the root `<RR>`; the query accepts no rooted prefix on Ycode; a `dyld_sim` image-list entry changes nothing (§3.5, last part) | 3 | `--exec` runs of our `bundleprobe` with `--trace` and with chosen prefixes, `YCODE_CACHE_IMAGE_FILES=0` (APP-FIX runs x1, x2 and prefix runs), 2026-10-20 |
| Ycode's SpringBoard answers poster opens at once with code 4 NotFound; `ylaunch` retried it (§2.1) | 3 | ylaunch output in run t2; APP-FIX runs a1, c1 |
| Ycode's `DesiredIconState.plist` keeps the default list identifiers (§6) | 2 | 13 Ycode devices compared with the runtime's default file (`plistlib`) |

Level 5 was not used. The reference tools, `research/` and Ghidra were not
opened. Sections §1–§7 and §9: the reference simulator was not run or
observed. §8 (dirty side, 2026-10-20): the reference simulator was observed
black-box with our own public-API probes; no decompiling or disassembly; no
IPSW was opened. APP-FIX (2026-10-20, clean side) ran only Ycode's own
simulator on the Thor and our probes in it, and read open-source dyld
(main branch, `DyldAPIs.cpp`, `DyldProcessConfig.cpp`; level 1: the query
looks the string up in the cache image table, with a `realpath` retry on
macOS builds only), consistent with §8.1.
