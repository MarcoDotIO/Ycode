# Devices and Simulators window (read-only)

Ycode module: `YcodeUI` (`DevicesList`, `DevicesController`).

Correction (2026-10-19): the reference has no Window ▸ Devices and
Simulators item. The window opens from Product ▸ Destination ▸ Manage
Devices… (⇧⌘2) and from the destination menu's "Manage Devices…"
(`reference-ui-4.md` §14.3, `reference-ui-5.md` §2.9). What that command
opens in the reference (a window or the "Device Hub" tool listed in Xcode ▸
Open Developer Tool) is still to observe. Ycode's window: a Devices /
Simulators switch, a list, and the selected entry's details. Ycode never boots, pairs,
installs on, or otherwise operates a device or simulator.

## Sources

- Simulators: `xcrun simctl list -j`. `devices` maps runtime identifiers
  (`com.apple.CoreSimulator.SimRuntime.<Platform>-<major>-<minor>`) to
  device objects (`name`, `udid`, `state`, `isAvailable`,
  `deviceTypeIdentifier`). Runtime versions come from `runtimes[]`
  (`identifier`, `version`), else from the identifier; model names from
  `devicetypes[]` (`identifier`, `name`), else the identifier's last
  component. Platforms: iOS, watchOS, tvOS, visionOS (`xrOS`); others are
  skipped. Sorted by platform, name, version.
- Devices: `xcrun devicectl list devices --json-output <file> -q`.
  `result.devices[]`: `identifier`, `deviceProperties` (`name`,
  `osVersionNumber`), `hardwareProperties` (`platform`, `reality` —
  only `physical` entries are listed —, `marketingName`, `productType`),
  `connectionProperties` (`pairingState`, `tunnelState`). Sorted by name.

## Details

Name, Model, OS Version (`<platform> <version>`), State (simulators) or
Connection (`<pairingState>, <tunnelState>`), Identifier, Available.
Empty lists show "No Devices Connected" / "No Simulators".

## Evidence

- Correction 2026-10-19: no Window-menu item; Product ▸ Destination ▸ Manage Devices… ⇧⌘2 (`reference-ui-5.md` §2.9, level 3, menu bar read through the accessibility API).
- Command lines and JSON keys: the tools' JSON output studied as a format
  (level 2/3), the same keys `YcodeBuild.DestinationCatalog` reads.
  Tests use synthetic JSON only.
- Window layout: Apple's public documentation for the Devices and
  Simulators window (level 1).
- OPEN QUESTION: the reference's grouping (connected / discovered),
  device screenshots and logs, and runtime management.
