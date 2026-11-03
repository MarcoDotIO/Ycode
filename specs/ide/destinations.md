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

## Ycode's watches and phones with a paired watch (PAIR-IDE, 2026-10-30)

From `specs/simulator/device-pairing.md` §11.4 and P-9 (§13 has Ycode's
results). Ycode's remote simulator rows (`run.md` §Runtimes and device
types) now include:

- **Each Ycode watch** (the watch types of a watchOS runtime root, and the
  watches created in Device Hub): name "<watch type> (Ycode)" (or the given
  name), platform watchOS, specifier `generic/platform=watchOS Simulator`
  (builds use the `watchsimulator` SDK, `watchos.md` §8), the runtime's
  version.
- **Each Ycode iPhone with an active paired watch** (the reference lists
  every iPhone simulator with an active paired watch for a watch scheme,
  §11.4): name "<phone> with <watch>" (**Ycode decision**: the reference's
  title was not observed; `device-pairing.md` §13 Q14), platform watchOS,
  the watchOS simulator's specifier, the **watch's** runtime version (so a
  phone whose watch is older than the watch app's deployment target is
  listed under Incompatible with "OS version lower than deployment target",
  as §11.4's phones with a 26.5 watch), identifier
  `ycode-remote-simulator:paired:<phone directory>`. The watch is the
  phone's active one when the run starts.

Both kinds are rows of the Simulators section and are filtered by the
scheme's platform like the others: an iOS app's scheme lists them under
Incompatible ("mismatched platform"), a watch app's scheme lists them and
puts the iPhone rows under Incompatible. **The scheme decides the
platform** when its target is not the project's first target (the watch
app beside its iOS app): its `SUPPORTED_PLATFORMS` (else `SDKROOT`) and its
deployment target, for the menu and for the default destination
(`WorkspaceWindowController.schemeTargetPlatform`). The pairs come from
`ycode-sim list-pairs --json`, read when a workspace window lists its
destinations and whenever Device Hub changes them; every window relists
its destinations when they change.

## Evidence

- Correction 2026-10-19: simulator ordering by runtime then device family then name, "(Designed for iPad, <runtime>)" titles and Incompatible reasons: `reference-ui-5.md` §11.4 (level 3, Product ▸ Destination submenu listing).
- Destination specifier syntax: `man xcodebuild` (level 1).
- simctl and devicectl JSON shapes: black-box runs of the public command-line
  tools on this Mac (level 3).
- Section titles and order (Recent, Devices, Simulators, Build, then
  Incompatible ▸ and Manage Devices…), the filter field and row ordering:
  `specs/ide/reference-ui-3.md` §4 (level 3). Incompatible destinations are
  moved to a submenu, not shown in the main list.
- Watch and phone-with-watch rows (PAIR-IDE): `device-pairing.md` §11.4
  (level 3, `xcodebuild -showdestinations` in the dirty room) for which rows
  exist; the titles and identifiers are Ycode decisions; tests
  `PairIDETests`, `PairIDEHubTests`.
- OPEN QUESTION:
  how it labels duplicate simulator names.
