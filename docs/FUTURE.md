# Roadmap

This is the direction of the project, not a set of promises or dates. What works today is in the
[README](../README.md#what-works-today), and the ranked list of gaps is in [PARITY.md](PARITY.md) §6.

## The IDE

**On Linux**, in order:

1. Completion, Jump to Definition and the other language features through SourceKit-LSP; live issues landed in
   1.0.0-beta.1 ([PARITY.md](PARITY.md) §5.9).
2. The navigators the Linux window doesn't have yet, and the rest of Settings (key bindings, accounts).
3. The debugger interface, and debugging on a remote simulator.

**On both systems:**

- Signing and distribution, and physical devices.
- UI tests on the simulator.
- Interface Builder connections and Auto Layout, and the Core Data model editor.

## Version 2: Xcode 27.2 parity

The second major version targets what Xcode 27.2 adds, on both systems:

- The JSON `.xcproj` project format, an opt-in alternative to `.pbxproj`, read and written with the same
  round-trip guarantee ([PARITY.md](PARITY.md) §2).
- The HomeView platform: opening, building and templating its projects. This is still being investigated.
- Device Hub additions: shake, memory pressure, slow animations and Standby ([PARITY.md](PARITY.md) §4).
- Rendered Markdown editing, `#Playground`, Icon Composer 2.0 documents, and `simctl`-style verbs.
- App skills for Siri (`.skillsbundle`, from the Siri AI Developer Preview): the Skills Bundle template,
  validation of each `SKILL.md` as live issues and build errors, the compiled output in the app bundle, and a
  coding-assistant action that drafts a skill from a target's App Intents ([skills-bundle.md](../specs/formats/skills-bundle.md)).

## The simulator

The main simulator work is speed and fidelity, compared with Apple's simulator on a Mac. Platforms stand as
follows ([PARITY.md](PARITY.md) §4 has the matrix):

| Platform | State |
|---|---|
| iOS | Boots and runs apps (`specs/simulator/lean-boot.md`) |
| iPadOS | iPad (A16) and iPad Pro 13-inch (M5) boot on iOS 27.0 and 27.1 (`specs/simulator/ipad.md`) |
| watchOS | Boots, and pairs with an iPhone (`specs/simulator/watchos.md`, `specs/simulator/device-pairing.md`) |
| visionOS | Boots to its room and home view, with open problems (`specs/simulator/visionos.md`) |
| macOS apps on Linux | Started (`specs/macos/`) |
| tvOS | Not started |

The longer-term goal is an iOS simulator that works with **ARKit and RealityKit**: a virtual iPhone inside a
visionOS-like room, which provides the camera, depth and pose data that AR apps need.

## Open frameworks

Open-source implementations of Apple's frameworks that build on Linux, under the same clean-room protocol as Ycode
([AGENTS.md](../AGENTS.md)): specifications from public documentation and black-box behaviour, never Apple code.

- **Packages that exist** ([frameworks/](../frameworks/README.md)): Contacts, EventKit, HealthKit, HomeKit, StoreKit,
  SwiftUI and WeatherKit, plus a USD library. Each is partial, and its README lists what is done.
- **Specified, no code yet** ([specs/frameworks/](../specs/frameworks/)): ARKit, MapKit and RealityKit.
- **Later:** AppKit and others.

## Design guidance for current work

Where it costs little, prefer designs that generalize:

- a device and runtime model per platform, rather than iOS assumptions buried in the simulator host;
- display, input and sensor pipelines (including camera and motion feeds) that can carry AR data;
- the Metal to Vulkan path as a shared graphics layer;
- IDE logic in the portable `YcodeIDECore`, so that the macOS and Linux windows share it.
