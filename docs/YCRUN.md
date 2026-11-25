# ycrun

`ycrun` drives **Ycode's own simulators** from a terminal, a script or a coding
agent. It works like `xcrun`: `ycrun simctl <verb>` takes the verbs, argument
order, `booted` device selection and `-j` JSON you know from `xcrun simctl`, but
the devices are Ycode's, not Xcode's. `ycrun remote` sets up the machine those
devices run on.

The design and the full verb mapping are in
[specs/ide/ycrun.md](../specs/ide/ycrun.md).

## Where devices run

| You are on | Devices run |
|---|---|
| arm64 Linux, and your user can open `/dev/kvm` | on this machine |
| arm64 Linux without KVM access | on your simulator host (ycrun says how to get KVM access) |
| x86-64 Linux | on your simulator host |
| macOS | on your simulator host (Ycode's simulator does not run on the Mac yet) |

`--local`, `--remote` and `--host <name>` override the choice, before or right
after `simctl`. `ycrun simctl list` shows where each device lives, and
`ycrun remote list` shows the default and why.

If `/dev/kvm` exists but you cannot open it, add yourself to its group and log
in again. ycrun prints the command; run it yourself, ycrun never uses sudo:

```sh
sudo usermod -aG kvm $USER
```

## Getting ycrun

- **macOS:** it is inside the app, at `Ycode.app/Contents/Helpers/ycrun`. Put it
  on your PATH once:

  ```sh
  /Applications/Ycode.app/Contents/Helpers/ycrun --install-link
  ```

  This makes a link in `/usr/local/bin` when you can write there, else in
  `~/.local/bin` (add that folder to your PATH if it is not there already).
  It never asks for an administrator password.
- **Flatpak:** `flatpak run --command=ycrun io.github.MarcoDotIO.Ycode …`. For a
  plain `ycrun`, run `flatpak run --command=ycrun io.github.MarcoDotIO.Ycode --install-link`
  once: it writes a small `~/.local/bin/ycrun` script that runs the Flatpak's.
- **Tarball or a source build:** `bin/ycrun` (`.build/<config>/ycrun`).

`ycrun --find <tool>` prints the path of one of Ycode's tools (`ycode`,
`ycodebuild`, `ycode-sim-viewer`, `ycode-simhost`, `ycode-bsp`), and
`ycrun <tool> …` runs it.

## Setting up a simulator host

A simulator host is an arm64 Linux machine with KVM (for example an NVIDIA
Jetson or another arm64 server) that you reach with ssh. Set it up from your Mac
or Linux PC:

```sh
ycrun remote setup
```

In a terminal it asks for the host (`user@host`) and the data folder. For
scripts and agents every answer is a flag:

```sh
ycrun remote setup --host <user>@<host> --data '~/ycode-data' \
    --copy-runtime <a RuntimeRoot on this computer> --yes
```

What it does, step by step:

1. **Host**: `--host user@host` (or `--local` for the machine you are on), and
   `--name` for `--host <name>` later (default: the host's name).
2. **ssh with a key.** ycrun logs in with your ssh key and never with a
   password. If the key is not accepted, it prints the command to run yourself
   (`ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@<host>`, and `ssh-keygen -t ed25519`
   first if you have no key) and stops.
3. **Checks**: arm64 Linux, KVM access, packages, Swift, free space in the data
   folder (`--data`, Ycode's `$YCODE_DATA`; `--min-free-gb`, default 40), ports.
   Nothing changes in this step; `--report-only` stops after it.
4. **Install**: the data folders, Ycode's simulator (from Ycode's own aarch64
   release, checked against its SHA-256 sums, or `--sim-tree <a built ycode
   folder>`), the launcher `<data>/bin/ycode-sim` and its `ycode-sim.conf`, and
   the simulator service's `simhost.env` (`--config-dir`, `--tcp-port`,
   `--udp-port`). Steps that need root (the kvm group, packages, firewall ports)
   are printed for you to run; ycrun never runs sudo.
5. **Runtime**: `--copy-runtime <RuntimeRoot>` copies one from this computer
   (resumable; run the same command again after an interruption),
   `--runtime-root <path>` names one already on the host, else the newest one
   in `<data>/runtimes` is used. `ycode runtime` gets a runtime.
6. **Settings**: the host becomes the IDEs' simulator host (Settings ▸
   Components ▸ Simulator Host), so the macOS IDE runs on it and Device Hub
   lists its devices. `--no-default` keeps another host as the IDEs'. ycrun's
   own list of hosts is `~/.config/ycode/ycrun/hosts.json`.
7. **First device**: one device of the runtime's default type (`--device-type`,
   `--device-name`, `--no-device`).

If something is still missing (KVM access, a runtime), the host is saved and
setup lists what is left. Fix it, then run the setup again: it only does what
is still missing.

Other commands:

```sh
ycrun remote list            # the hosts, and where devices run by default
ycrun remote status [name]   # the host's checks, runtimes and devices
ycrun remote test [name]     # log in, launcher, simulator, runtime, KVM: ok or FAILED
ycrun remote link <name>     # start its simulator service and pair it with this computer
ycrun remote remove <name>   # forget a host (nothing on the host is deleted)
```

### Using the host from the Linux IDE (`--link`)

The Linux IDE runs apps on hosts paired over Ycode's own link. Add `--link` to
the setup (or run `ycrun remote link <name>` later) and ycrun, over the same ssh
login, starts the host's simulator service when nothing serves its port
(`--tcp-port`, `--udp-port`; its pid goes in `<config>/simhost.pid`), then the
host and this computer trust each other's link identity. No pairing code is
needed: ssh already proves who is who. The host's devices then appear in the
Linux IDE's run destinations and its Device Hub. A setup with its own
`--config-dir` keeps the host's link identity in `<config>/sim-link`, apart from
a service the machine already runs.

### Device Hub

Both IDEs' Device Hub list the devices of the host ycrun set up. A device you
booted with `ycrun simctl boot` shows as running there, with its live screen,
and the hub's Shut Down stops it as `ycrun simctl shutdown` does. A device
started from the Linux hub is booted the way ycrun boots it, so
`ycrun simctl shutdown` can stop it too.

## Using devices

```sh
ycrun simctl list                                   # device types, runtimes, devices, pairs
ycrun simctl list -j devices                        # JSON
UDID=$(ycrun simctl create "My Phone" iphone-duo)   # prints the UDID
ycrun simctl boot "$UDID"                            # returns when it is starting; --wait waits
ycrun simctl bootstatus "$UDID"                      # waits until it is booted
ycrun simctl view booted                             # the live screen (Ycode only)
ycrun simctl io booted screenshot shot.png
ycrun simctl ui booted appearance dark
ycrun simctl location booted set 41.15,-81.36
ycrun simctl install booted MyApp.app
ycrun simctl launch booted com.example.MyApp        # prints com.example.MyApp: <pid>
ycrun simctl shutdown booted
ycrun simctl erase "$UDID"
ycrun simctl delete "$UDID"
```

A device is `booted`, its UDID or its name. Device types are Ycode's ids
(`ycrun simctl list devicetypes`); a name (`"iPad (A16)"`) or a simctl-style
identifier (`com.apple.CoreSimulator.SimDeviceType.iPhone-Duo`) works too.
Runtimes are `iOS-27-1`, `iOS 27.1` or `27.1`.

Things that work differently from Apple's simulator:

- **Apps install when they launch.** `install` copies the app to the device's
  host; `launch` starts the device with the app installed and launched. If the
  device is running, it restarts first; with warm boot (the default) it
  resumes in seconds.
- **Shutdown saves.** With warm boot, `shutdown` saves the device and the next
  `boot` resumes it.
- **Devices the IDE started.** ycrun stops only devices it booted. Stop the
  others in Ycode.
- Each runtime has one device per device type of its own ("iPhone Duo
  (Ycode)"). `delete` erases those instead of removing them.
- `SIMCTL_CHILD_<NAME>=value` in your environment reaches the launched app as
  `<NAME>=value`, as with simctl.

## Not supported by Ycode's simulator yet

These answer "… is not supported by Ycode's simulator yet" and exit 69:
`terminate`, `openurl`, `spawn`, `getenv`, `uninstall`, `get_app_container`,
`listapps`, `appinfo`, `privacy`, `push`, `keychain`, `addmedia`, `pbcopy`,
`pbpaste`, `pbsync`, `status_bar`, `clone`, `upgrade`, `diagnose`,
`logverbose`, `icloud_sync`, `runtime`, `io recordVideo` (record from the
viewer instead), `launch --console`, `--console-pty`, `--stdout=`, `--stderr=`,
`-w`, `boot --disabledJob=` and `--enabledJob=` (use the IDE's Lean boot
setting), `io screenshot --type=` other than png, and `--display=external`.

Exit statuses: 0 success, 1 failure (the reason is on standard error), 64 a
usage error, 69 not supported yet.
