# B5-DEVICEHUB: Device Hub usable on macOS and Linux (1.0.0-beta.5)

The owner asked on 2026-11-17 that Device Hub be fully usable on macOS and
Linux, for example to turn a simulator on from the hub. This workstream
pulls the usable part of P-172 to P-175 forward from beta 9. The decisions
are in `specs/ide/device-hub.md` ("Ycode decisions (2026-11-17)") and the
implementation in §I.18 there.

Clean room: only `specs/`, `docs/`, Ycode's code and `xcrun simctl help`
were read. Apple's Xcode, Simulator and Device Hub were not run or watched,
and no Apple simulator was booted. The simctl path is tested with fake
runners.

## macOS

| Item | State |
|---|---|
| Open the hub with and without a workspace | Product ▸ Destination ▸ Manage Devices… (⇧⌘2) and Ycode ▸ Open Developer Tool ▸ Device Hub. Without a workspace, `DevicesController.configureStandalone` lists and operates Ycode's simulators too (before, only the simctl list was shown). There is no Window ▸ Devices and Simulators item, because the reference has none (`devices.md`). |
| Lists Ycode's and simctl's simulators | Yes. Ycode's come from the remote-simulator settings; simctl's from `xcrun simctl list -j`. |
| Start, Shut Down, Restart for both kinds | Ycode's: unchanged (the launcher over ssh). simctl's: `SimctlDeviceControl` runs `simctl boot`, then `open -a Simulator --args -CurrentDeviceUDID <udid>`; `simctl shutdown`; Restart is both. Available from the status view's Start, the row's context menu and More Actions. Erase All Content and Settings… (`simctl erase`) works on a shut-down device, behind the existing confirmation. |
| A running simctl simulator | Its picture with a glass capsule: the name, "Running in the Simulator app", and Show in Simulator. Screenshot goes through `simctl io <udid> screenshot`. The other controls have the tooltip "This simulator's screen is in the Simulator app. Use the Simulator app for this control." The compact-window button shows it in the Simulator app, or starts it. |
| Live screen of a Ycode simulator, controls | Unchanged from earlier rounds (`DeviceLiveSession`). Checked live on the Thor on 2026-11-20 by B5-DEVICES (`docs/beta5/devices.md`). |
| State without reopening; failures | A 2-second poll of `simctl list -j devices`. simctl's last line shows in a banner ("Could not start the simulator: …"). |

## Linux (the x86 IDE)

| Item | State |
|---|---|
| Window, sidebar, canvas, inspector | `DeviceHubWindow.swift`, `DeviceHubCanvas.swift`. The window is 1100 × 800 with the macOS hub's areas: toolbar 52, sidebar 240, inspector 280. |
| Opens from the same menu items | Manage Devices… and Open Developer Tool ▸ Device Hub, with or without a workspace (`showDevices:` in `ShellAppModel+MenuActions.swift`). |
| Lists Ycode's simulators | Every paired host's devices, over Ycode's link (a host on this computer included). Offline hosts are listed as such. |
| Start, Shut Down, Restart | The link's `boot` and `shutdown`, from the canvas's Start, the row's menu and More Actions. A device that stops by itself shows the host log's last error on its picture. |
| Live screen and controls | `DeviceHubScreen` drives `RemoteDeviceSession`, the device window's display client. Each picture is sampled to the canvas's size and drawn with OpenViews' new `Image(rgbaPixels:)`. Pointer touches work. Home, Screenshot (the server's PNG) and Rotate (the stream's rotate; "This device doesn't rotate." when the stream says so) act on the device. Record is disabled with "Record Screen is not in this beta", the device window's existing decision. Settings shows Appearance and the five switches, read and set over the stream's command channel. Info shows the device's rows. |
| Run and the hub | Run still opens its device window (`ycode-sim-viewer`). The stream takes one viewer at a time, so the newer viewer takes the display and the other shows "Another viewer has this device" with Take Back. Open in New Window on Linux opens that same device window. |

## Tests

- `SimctlDeviceControlTests` (YcodeIDECore, macOS and Linux): the exact arguments of each command, and the failure messages.
- `DeviceHubSimctlTests` (YcodeUITests, offscreen): Start from the status view, the status capsule and its button, the controls' tooltips, Screenshot, the row's menu, Restart, Shut Down, Erase, the poll, a failed start, a read-only row without simctl, and the hub without a workspace.
- `DeviceHubShellTests` and `DeviceHubLiveShellTests` (YcodeIDEShell): the menu items without a workspace, the sections, search and collapse, Start, Shut Down and Restart, failures, unexpected stops, the runtime's OS, picture sampling and rotation, and the live screen end to end against the stand-in host (hello, picture, Home, touch, Screenshot, Settings, Shut Down).
- The Linux walk: `YCODE_IDE_DEVICEHUB=<prefix>` (`ShellDriver+DeviceHub.swift`), with `YCODE_IDE_HUB_STANDIN=1` for the in-process stand-in host or the link's paired hosts otherwise.

## Left for beta 9

The hub's own Device and Controls menus; the full More Actions and Add Device lists; Sort and Filter on Linux; zoom and its motion; Physical Size; the narrow window (P-173 to P-175). Also: a Settings inspector for simctl simulators (`simctl ui`); the foldable's poses and the location and sound cards in the Linux hub; Capture Keyboard and Record on Linux; one shared stream session between Run's device window and the Linux hub.
