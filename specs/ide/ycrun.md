# ycrun: Ycode's simulator command line

`ycrun` is Ycode's front end for **Ycode's own simulators**, modelled on
`xcrun`. `ycrun simctl <verb>` takes simctl's public verbs, argument order,
device selection and JSON on Ycode's simulator; `ycrun remote …` sets up and
checks the simulator hosts those devices run on. It is the tool that scripts,
agents and people reach for (docs/PARITY.md §3.2 and its `simctl` row asked
for "a `ycode simctl` front end with Apple's verbs").

This spec records Ycode's design decisions and the mapping from simctl's
verbs to Ycode's machinery. User documentation: [docs/YCRUN.md](../../docs/YCRUN.md).
Code: `ycode/Sources/YcodeSimControl/`, `ycode/Sources/ycrun/`. Tests:
`ycode/Tests/YcodeSimControlTests/`.

## 1. Scope

- Ycode's devices only. ycrun never runs, reads or changes Apple's
  CoreSimulator devices; for those, `xcrun simctl` stays the tool.
- Every verb is built on what the IDEs already run: the host-side launcher
  (`scripts/ycode-sim.sh`, "the launcher"), the commands of
  `RemoteSimulator` (start, control, erase, screenshot), the IDE's device
  model (`RemoteSimulatorSettings.hubTargets`, created devices), the host
  setup script (`HostSetupScript`) and the runtime copy (`RuntimeTransfer`).
  ycrun adds no second simulator stack.

## 2. Command line

```
ycrun [--local | --remote | --host <name>] simctl <verb> [arguments]
ycrun remote setup | list | status [<name>] | test [<name>] | remove <name>
ycrun --find <tool> | <tool> [arguments] | --install-link [<dir>] | --version | --help
```

- Placement options may come before `simctl` or right after it.
- `ycrun <tool>` runs one of Ycode's tools found next to ycrun (`ycode`,
  `ycodebuild`, `ycode-sim-viewer`, `ycode-simhost`, `ycode-bsp`), as
  `xcrun <tool>` runs a developer tool. `--find` prints its path.
- `--install-link` puts ycrun on the PATH without sudo: a symbolic link in
  `/usr/local/bin` when that folder is writable, else in `~/.local/bin`; in
  a Flatpak a two-line script there that runs `flatpak run --command=ycrun`.

## 3. Where a device runs (the one seam)

### 3.1 The decision

`SimPlacementPolicy.decide` is the only place that decides.

| Machine | Default | Reason shown |
|---|---|---|
| arm64 Linux, `/dev/kvm` readable and writable | this machine | "devices run on this machine" |
| arm64 Linux, `/dev/kvm` denied | the default host | the kvm group fix, for the user to run |
| arm64 Linux, no `/dev/kvm` | the default host | turn on virtualization; Ycode does not change the kernel |
| x86-64 Linux | the default host | needs arm64 Linux |
| macOS | the default host | Ycode's simulator does not run on this Mac yet |

`--host <name>` implies `--remote`. `--local` together with `--remote` or
`--host` is a usage error, and so is `--local` where devices cannot run (with
the reason). `ycrun simctl list` puts the location in every runtime group's
title (`-- iOS 27.1 (on <host>, user@host) --`), and the JSON gives each
device `host` and `placement`.

### 3.2 The Mac (MACHOST)

Ycode's simulator is being ported to Apple-silicon Macs as a separate track.
`SimPlacementPolicy.macOSRunsLocally` is the one switch: when that port lands,
it turns true and an Apple-silicon Mac decides "local" with no other change.
An Intel Mac stays remote. Until then ycrun says plainly that the Mac uses a
remote host.

## 4. Running commands

One shell command runs either `/bin/sh -c <command>` (this machine) or
`ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15
<user@host> <command>` (`SimShell`). ssh logs in with a key only: BatchMode
makes it fail rather than prompt, and ycrun never asks for, stores or passes a
password. Files go with rsync over the same ssh options. In the Flatpak, ssh
and rsync are the package's host-tool wrappers (`HostTool.path`).

## 5. Hosts and settings

- **The default remote host is the IDEs' host.** Its settings are the IDE's
  own defaults: `Ycode.remote.*` (`RemoteSimulatorSettings`: destination,
  data folder, runtime roots and their versions and platforms, launcher,
  device name, created devices) and the setup wizard's host
  (`Ycode.runtimeSetup.choices`: destination, data folder, configuration
  folder, link ports). They live in the IDE's defaults domain:
  `io.github.MarcoDotIO.Ycode` on macOS, `ycode-ide` on Linux
  (`~/.config/ycode-ide.plist`; inside the Flatpak, the app's own
  configuration folder, which ycrun shares when it runs there), or
  `$YCODE_DEFAULTS_DOMAIN`. So a host set up with ycrun is the macOS IDE's
  run destination, Settings ▸ Components ▸ Simulator Host shows it on both
  IDEs, and the devices ycrun creates are Device Hub's created devices.
- **More hosts** and this machine's settings are in
  `$YCRUN_CONFIG_DIR/hosts.json` (default `~/.config/ycode/ycrun/hosts.json`),
  one entry per host: name, destination (empty for this machine), data
  folder, runtime roots, launcher, device name, created devices.
- **This machine** without an entry uses `$YCODE_DATA` (else
  `~/.local/share/ycode`), the launcher `$YCODE_SIM_LAUNCHER` (else
  `<data>/bin/ycode-sim`) and the runtime `$YCODE_SIM_RUNTIME` (else the
  newest iOS runtime Ycode copied into `<data>/runtimes`).

## 6. Devices, runtimes, device types

- **Devices** are the IDE's: for every runtime root, the device types that
  run on it (`hubTargets`), then the created devices. Each is a directory
  under `<data>/devices`.
- **UDID**: ycode-simd's own, derived from the device directory's absolute
  path (two FNV-1a 64-bit hashes, version-8 style UUID), so the device
  reports the same UDID ycrun prints.
- **Names**: a runtime's own devices are "<type> (Ycode)"; created devices
  have the name given to `create`.
- **State**: `Booted` when the device's control socket answers
  (`<launcher> --device D --control state` exits 0), `Booting` while a
  launcher ycrun started runs but the socket does not answer yet, else
  `Shutdown`. One command on the host asks for every device.
- **Device selection**: `booted` (the first booted device), a UDID (any
  case), a name, or a device directory's name.
- **Device types**: ycode-simd's (`YcodeSimulatorDeviceType`). Identifier:
  the ycode-simd id (`iphone-duo`). A type argument may also be its name or
  a simctl-style identifier (`com.apple.CoreSimulator.SimDeviceType.iPhone-Duo`);
  both compare by letters and digits.
- **Runtimes**: the host's configured runtime roots. Identifier
  `<platform>-<version with dashes>` (`iOS-27-1`, Ycode decision: simctl's
  shape without its vendor prefix). A runtime argument may be the
  identifier (with or without simctl's prefix), the name (`iOS 27.1`), the
  version or the root.

## 7. The simctl verbs

### 7.1 Mapping

| Verb | Ycode | Notes |
|---|---|---|
| `list [-j] [devices\|devicetypes\|runtimes\|pairs] [<search>\|available]` | device model, `listRuntimes` on the host, `<launcher> list-pairs --json` | `--all-hosts` lists this machine and every host |
| `create <name> <type> [<runtime>]` | a created device (`RemoteCreatedDevice`), saved where the host's settings are | prints the UDID; the runtime defaults to the first that runs the type |
| `delete <device>… \| unavailable \| all` | `<launcher> --erase`, then the created device is dropped | a runtime's own device is erased and stays listed; a booted device is refused |
| `rename <device> <name>` | the created device's name | runtime devices cannot be renamed |
| `boot <device> [--arch=arm64] [--wait]` | the IDE's Start command, detached (§7.3) | a booted device is refused |
| `bootstatus <device> [-b]` | waits for `Booted` | `-b` boots first |
| `shutdown <device> \| all` | SIGTERM to the launcher ycrun started (§7.3) | a device another program booted is reported, not stopped |
| `reboot <device>` | shutdown, then boot | |
| `erase <device> \| all` | `<launcher> --erase --device D` | booted devices are refused |
| `install <device> <App.app>` | rsync to `<data>/apps/<App>.app`; recorded in `<data>/ycrun/<device>.apps` | the app is installed when it is launched (§7.3) |
| `launch <device> <id> [<argv>…]` | boot with `--install-app`, `--launch`, `--environment-overrides`, `--app-arg` | a running device restarts first; prints `<id>: <pid>` |
| `io <device> screenshot [--type=png] [--display=…] <file\|->` | the control socket's `screenshot` (`RemoteSimulator.screenshotCommand`) | `--display=internal` (default) is the shown display; `LCD`, `LCD-1` name a foldable's; `external` is unsupported |
| `location <device> …` | `<launcher> --device D --location …` | the same words as simctl: `set`, `clear`, `list`, `run`, `start` |
| `ui <device> …` | `<launcher> --device D --ui …` | `appearance`, `content_size`, `increase_contrast`; a query prints its value |
| `pair <watch> <phone>`, `unpair <pair>`, `pair_activate <pair>` | `<launcher> pair\|unpair\|pair-activate` with `YCODE_SIM_DEVICE_SET` | prints the pair UUID |
| `view <device> [viewer options]` (Ycode only) | `ycode-sim-viewer --connect unix:<display socket>`; on a host through `ssh -N -L` | the forward ends with the window |

### 7.2 Output

- Text: `== Device Types ==` with `<name> (<identifier>)`; `== Runtimes ==`
  with `<name> (<version> - <build>) - <identifier> (<location>)`;
  `== Devices ==` with `-- <runtime> (<location>) --` and
  `    <name> (<UDID>) (<state>)`; `== Device Pairs ==`.
- JSON (`-j`, `--json`): `devicetypes` (identifier, name, productFamily,
  minRuntimeVersionString, platform), `runtimes` (identifier, name,
  platform, version, buildversion, isAvailable, runtimeRoot,
  supportedDeviceTypes, supportedArchitectures, host, placement),
  `devices` keyed by runtime identifier (udid, name, state, isAvailable,
  deviceTypeIdentifier, dataPath, logPath, runtimeRoot, isCreated, host,
  placement), `pairs` as the launcher prints them.
- `create` prints the UDID; `launch` prints `<id>: <pid>`; a screenshot
  says `Wrote screenshot to: <file>` on standard error.

### 7.3 Boots, stops and apps (Ycode decisions)

- **Boot** runs the IDE's Start command (`RemoteSimulator.startCommand`:
  the launcher with the device, runtime, device type, display server and
  the IDE's boot options) under `nohup setsid sh -c`, so it outlives the
  ssh session, with its output in `<data>/ycrun/<device>.log` and its pid
  in `<data>/ycrun/<device>.pid`. `boot` returns once the launcher is
  running (it checks after 3 s and shows the log's end if it stopped).
- **Shutdown** sends SIGTERM to that pid (not SIGINT, which a background job of a non-interactive shell ignores and cannot trap) (the launcher saves the device
  with warm boot, as at the IDE's Stop), waits up to 150 s, then kills the
  session. A device the IDE booted has no pid file: ycrun says so.
- **Apps**: Ycode's simulator installs and launches an app as the device
  starts (`--install-app`, `--launch`). So `install` copies the app to the
  host and records it; `launch` restarts a running device (warm boot
  resumes it in seconds), boots it with the app, and reads the app's pid
  from the launcher's "launched … pid N" line (the IDE's own reading,
  `RemoteSimulator.phase`).

### 7.4 Not supported yet, and exit statuses

Unsupported verbs and options say "<verb> is not supported by Ycode's
simulator yet" with the reason or the alternative, and exit **69**
(EX_UNAVAILABLE): `terminate`, `openurl`, `spawn`, `getenv`, `uninstall`,
`get_app_container`, `listapps`, `appinfo`, `privacy`, `push`, `keychain`,
`addmedia`, `pbcopy`, `pbpaste`, `pbsync`, `status_bar`, `clone`,
`upgrade`, `diagnose`, `logverbose`, `icloud_sync`, `runtime`,
`io recordVideo`, `launch --console|--console-pty|--stdout=|--stderr=|-w`,
`io screenshot --type=` other than png, `--display=external`.

Other exits: 0 success, 1 failure (with the reason on standard error),
64 usage (EX_USAGE).

## 8. `ycrun remote`

### 8.1 setup

Interactive in a terminal (it asks for what is missing); every step is a
flag for scripts and agents (`--yes` asks nothing).

1. **Host**: `--host user@host` or `--local` (this machine), `--name`.
2. **Key login**: `ssh -o BatchMode=yes … printf ycrun-ok`. On failure it
   prints `ssh-copy-id -i <key>.pub user@host` (and `ssh-keygen -t ed25519`
   when this computer has no key) or the `authorized_keys` alternative,
   for the user to run, and stops. It never runs them.
3. **Checks**: the setup script in report mode, over ssh from standard
   input (nothing is left on the host): architecture (arm64 Linux is
   required), KVM access, packages, Swift, the data folder (`--data`,
   `$YCODE_DATA`; `~/` is the host's home) and its free space
   (`--min-free-gb`), the service, ports, firewall.
4. **Install**: the script's apply mode, the steps that need no root:
   the data folders, the simulator tree (`--sim-tree` for a built tree, else
   Ycode's own aarch64 release, `--ycode-version`, checked against its
   SHA256SUMS), the launcher link `<data>/bin/ycode-sim`, `simhost.env`
   (`--config-dir`, `--tcp-port`, `--udp-port`). Then ycrun writes the
   launcher's own configuration `<data>/bin/ycode-sim.conf`
   (`YCODE_SIM_TREE`, `YCODE_SIM_DATA`) when it is missing. Steps that need
   root (the kvm group, packages, firewall ports) are printed for the user
   to run in their own terminal; ycrun never runs sudo.
5. **Runtime**: `--runtime-root` on the host, or `--copy-runtime` from this
   computer (the wizard's `RuntimeTransfer`: rsync into `.incoming`, the
   marker, a rename; resumable), else the newest the host has. Its version
   and platform are read from its `SystemVersion.plist`; the host's other
   runtimes become other runtime roots.
6. **Settings** (§5): the IDEs' defaults when the IDEs name no host or the
   same one, or with `--default` (`--no-default` keeps them), and
   `hosts.json`.
7. **First device**: a created device of the runtime's default type
   (`--device-type`, `--device-name`, `--no-device`).

A host that still needs something (KVM access, a runtime, a tree) is saved
anyway, and setup lists what is left and exits 1.

### 8.2 list, status, test, remove

- `list`: this machine (when devices can run here), the IDEs' host first,
  the others, which is the default, and why.
- `status [<name>]`: the setup script's report, the runtimes, the devices
  and their states.
- `test [<name>]`: key login, architecture, launcher, `ycode-sim.conf`,
  `ycode-simd --version` from the tree, the runtime's `launchd_sim`,
  `/dev/kvm`; exit 1 when one fails.
- `remove <name>`: forgets the host (and clears the IDEs' Simulator Host
  when it was theirs). Nothing on the host changes.
- `link <name> [--tcp-port N --udp-port N]`: §8.3.

### 8.3 link

`ycrun remote link [<name>]`, and `ycrun remote setup … --link` as the
setup's last step, make a host set up with ycrun a host of Ycode's own link
(`specs/simulator/sim-link.md`), so the Linux IDE lists its devices as run
destinations and its Device Hub shows them under the host's link name.
Everything goes over the same key-only ssh as the setup:

1. **The service.** When nothing listens on the host's control port
   (`--tcp-port`, else the link's default), `<data>/bin/ycode-simhost serve
   --config <config>/simhost.env` is started detached, its pid in
   `<config>/simhost.pid` and its output in `<config>/simhost.log`. A port
   that is already served (a systemd unit the user enabled, an earlier
   link) is left alone. ycrun does not enable units or open ports; those
   stay the user's steps (§8.1 step 4).
2. **Trust, both ways, with pairing files** (sim-link.md §4.2). The host's
   `ycode-simhost identity --name <name> --address <host>:<port>` is
   trusted on this computer as a host (`ycode sim remote hosts` lists it),
   and this computer's identity is given to `ycode-simhost trust` on the
   host. Pairing files hold only public keys, and ssh carries them with
   integrity, so no one-time code is needed.
3. **Separate identities for separate folders.** A setup with its own
   configuration folder (`--config-dir`, not `~/.config/ycode`) keeps the
   host's link identity and trusted clients in `<config>/sim-link`
   (`YCODE_SIM_LINK_HOME`), apart from a service the machine already runs.

## 9. Packaging

- macOS: `Ycode.app/Contents/Helpers/ycrun` (`make-app.sh`), checked by
  `verify-dmg.sh` (`--version`, `--find ycode-sim-viewer`). On the PATH
  with `ycrun --install-link`.
- Linux: `/app/bin/ycrun` in the Flatpak and the tarball
  (`build-ycode.sh`); `flatpak run --command=ycrun io.github.MarcoDotIO.Ycode`,
  or `ycrun --install-link` from inside it for a `ycrun` script on the PATH.

## 10. Device Hub (both IDEs)

Device Hub uses ycrun's pieces rather than its own copies:

- **Placement.** The Linux hub lists this machine's devices only where
  `SimPlacementPolicy.localSupport` says devices run here (arm64 Linux with
  a usable `/dev/kvm`; a Mac once `macOSRunsLocally` turns true), and only
  when the launcher is in place. Remote hosts follow `SimHostStore`.
- **Settings.** The Linux hub reads the hosts ycrun writes: the IDE's host
  in the `ycode-ide` defaults domain (the same domain the Linux IDE's
  Settings ▸ Components ▸ Simulator Host page uses) and ycrun's other hosts
  in `hosts.json`. The macOS hub reads the app's own domain, which is
  ycrun's IDE domain on macOS.
- **Devices ycrun booted.** A device is booted by ycrun while
  `<data>/ycrun/<device>.pid` names a live process (`YcrunDeviceFiles`).
  Both hubs list it as running, show its live screen (the same display
  socket, `<data>/display/<device>.sock`, that a hub start serves), and stop
  it as `ycrun simctl shutdown` does: SIGTERM to that pid, up to the stop
  grace for the save, then the session is killed and the pid file removed.
  The macOS hub asks the host every 4 seconds while it shows; a host that
  does not answer keeps the last answer.
- **Starts from the Linux hub** boot as `ycrun simctl boot` does (detached,
  with the pid file), so ycrun sees them booted and can shut them down.
- **Names.** A ycrun host whose name a paired link host already has is
  listed as "<name> (ssh)".

## Evidence

| Claim | Level |
|---|---|
| simctl's verb names, argument order, `booted`, `-j`/`--json`, `list` sections and JSON keys, `create` printing the UDID, `launch` printing `<id>: <pid>`, `io screenshot` options, `location`/`ui`/`pair` words | 1 (public `xcrun simctl help` and its per-verb help) |
| `xcrun`'s `--find` and running a tool by name | 1 (public `xcrun` documentation) |
| Exit 69 for unsupported, 64 for usage | Ycode decision (sysexits.h names) |
| Placement rules, the MACHOST switch, hosts.json, the IDE defaults domain, runtime identifiers, UDID derivation, detached boots, install-at-launch, `view`, `--install-link`, `link` (§8.3), Device Hub's use of the pid files and placement (§10) | Ycode decisions, built on Ycode's own code (`RemoteSimulator`, `HostSetupScript`, `RuntimeTransfer`, ycode-simd) |
