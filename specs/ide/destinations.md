# Run destinations

Ycode module: `YcodeBuild` (`Destination`, `DestinationCatalog`); shown by
the toolbar's destination pop-up (`specs/ide/workspace-window.md`).

## Sources (read-only)

Ycode only lists destinations. It never boots, shuts down, pairs with or
otherwise operates a simulator or device while listing.

- Simulators: `xcrun simctl list -j devices`. Top-level `devices` maps a
  runtime identifier (`com.apple.CoreSimulator.SimRuntime.<Platform>-<major>-<minor>`)
  to device records with `udid`, `name`, `isAvailable`, `state`. Platform
  tokens: `iOS`, `watchOS`, `tvOS`, `xrOS` (shown as visionOS). Unknown
  runtimes and unavailable devices are skipped.
- Physical devices: `xcrun devicectl list devices --json-output <file> -q`.
  `result.devices[]` records carry `deviceProperties.name`,
  `deviceProperties.osVersionNumber`, `hardwareProperties.platform`,
  `hardwareProperties.udid` and `hardwareProperties.reality`
  (`physical` or `simulated`; simulated records are ignored).

## Specifiers

| Kind | `-destination` |
|---|---|
| My Mac | `platform=macOS` |
| Any Mac | `generic/platform=macOS` |
| Device | `platform=<Platform>,id=<hardware udid>` |
| Any device of a platform | `generic/platform=<Platform>` |
| Simulator | `platform=<Platform> Simulator,id=<udid>` |
| Any simulator of a platform | `generic/platform=<Platform> Simulator` |

## Pop-up grouping

Correction (2026-10-19): superseded by `reference-ui-3.md` §4 (Recent,
Devices, Simulators, Build, then Incompatible ▸ and Manage Devices…) and
the ordering, row titles and Incompatible reasons of `reference-ui-5.md`
§11.4. Ycode's earlier grouping, kept for reference:

Sections in order: "My Mac"; "Build" (Any Mac); then for each platform in
the order iOS, watchOS, tvOS, visionOS: "<Platform> Device" (connected
devices by name, then "Any <Platform> Device (arm64)") and
"<Platform> Simulators" ("Any <Platform> Simulator Device", then simulators
by name). Simulators with the same name get their OS version appended,
e.g. "Phone A (26.4)". Each section has a header; items have neutral
glyphs (never product-shaped symbols).

## Evidence

- Correction 2026-10-19: simulator ordering by runtime then device family then name, "(Designed for iPad, <runtime>)" titles and Incompatible reasons: `reference-ui-5.md` §11.4 (level 3, Product ▸ Destination submenu listing).
- Destination specifier syntax: `man xcodebuild` (level 1).
- simctl and devicectl JSON shapes: black-box runs of the public command-line
  tools on this Mac (level 3).
- Section titles and order (Recent, Devices, Simulators, Build, then
  Incompatible ▸ and Manage Devices…), the filter field and row ordering:
  `specs/ide/reference-ui-3.md` §4 (level 3). Incompatible destinations are
  moved to a submenu, not shown in the main list.
- OPEN QUESTION:
  how it labels duplicate simulator names.
