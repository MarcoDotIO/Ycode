# Open frameworks

Clean-room, Linux-buildable reimplementations of Apple frameworks, written
from the specifications in `specs/frameworks/<name>/` under the protocol in
`AGENTS.md` (this directory is part of the clean room).

| Directory | Package | Library module | Spec |
|---|---|---|---|
| `eventkit/` | `ycode-eventkit` | `EventKit` | `specs/frameworks/eventkit/` (rounds R2–R4) |
| `weatherkit/` | `ycode-weatherkit` | `WeatherKit` (+ `CoreLocation` shim on Linux) | `specs/frameworks/weatherkit/` (R2–R4) |
| `swiftui/` | `ycode-swiftui` | `SwiftUI` (re-exports `SwiftUICore`); built as `OpenViews` / `OpenViewsCore` on Apple hosts | `specs/frameworks/swiftui/` (R1, R2, R3 core, R4, R6); bundles Noto Sans (OFL 1.1) |
| `healthkit/` | `ycode-healthkit` | `HealthKit` | `specs/frameworks/healthkit/` (rounds R2–R5) |
| `contacts/` | `ycode-contacts` | `Contacts` | `specs/frameworks/contacts/` (rounds R2–R5) |
| `homekit/` | `ycode-homekit` | `HomeKit` (+ `CoreLocation` region shim on Linux) | `specs/frameworks/homekit/` (round R3) |
| `storekit/` | `ycode-storekit` | `StoreKit`, `StoreKitTest` (+ `StoreKitConfiguration`, `StoreKitEngine`, `StoreKitSigning`) | `specs/frameworks/storekit/` (rounds R2, R7–R9) |

Conventions:

- One Swift package per framework: `frameworks/<name>/Package.swift`, package
  name `ycode-<name>`. The library module may use the Apple framework's
  module name (an interop identifier) so existing source compiles against it.
- Swift 6.4 toolchain; must build and test on macOS and on Linux (x86-64 and
  arm64). Dependencies must be permissively licensed (MIT, BSD, Apache-2.0,
  zlib, ISC, or similar) and pinned to exact released versions; record each
  one and its licence in the package README.
- Tests carry the golden values from the spec (the spec's conformance tests);
  a test names the spec section it checks.
- No Apple code, resources, documentation text or SDK declarations. Public
  type and member names come from the spec's API inventory.
- On macOS a package must not shadow the system framework for other targets:
  keep each package self-contained and test it in its own build.
