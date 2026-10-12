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

(Filled in from the agents' reports.)

## 7. Rules for every agent

As `stage4b-contract.md` §9: clean room; edit only your files; builds with
`--scratch-path /tmp/yc-4c-<agent>`; Thor work in
`$YCODE_DATA/work/4c-<agent>/`; runtime root
`$YCODE_DATA/runtimes/iOS-27.1-24A94401/RuntimeRoot`; SSH
keys only, never `.env`, never a password, never sudo; the Thor is shared
(touch only your own directories); scripts in `scratchpad/agent-<X>/`;
do not commit. Report files changed, commands run with real output,
gaps, and contract requests.
