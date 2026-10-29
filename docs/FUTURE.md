# Future work: other platforms and open frameworks

This is the long-term direction of the project. The main simulator work is
still the iOS simulator on arm64 Linux, and making it as fast as the
reference simulator.

## Order of platforms

The simulator platforms come in this order:

1. iPadOS. *Started:* iPad (A16) and iPad Pro 13-inch (M5) boot on iOS 27.1
   and 27.0 (`specs/simulator/ipad.md`).
2. macOS.
3. visionOS. *Started:* visionOS 27.0 boots to its room and home view, with
   open problems (`specs/simulator/visionos.md`).
4. watchOS.
5. tvOS.

## Why this order

The goal is an iOS simulator that works with **ARKit and RealityKit**: a
virtual iPhone inside a visionOS-like environment, which simulates the real
world the device sees. visionOS comes before watchOS and tvOS because that
environment depends on it.

## Open frameworks

A related goal is open-source reimplementations of Apple's frameworks that
build on Linux, like Ycode itself. They are written under the same
clean-room protocol as Ycode (see [AGENTS.md](../AGENTS.md)): specifications
from public documentation and black-box behavior, never Apple code.

- **Packages that exist** ([frameworks/](../frameworks/)): Contacts,
  EventKit, HealthKit, HomeKit, StoreKit, SwiftUI and WeatherKit. Each is
  partial; its README lists the rounds that are done.
- **Specified, no code yet** ([specs/frameworks/](../specs/frameworks/)):
  ARKit, MapKit and RealityKit (round 0).
- **Later:** AppKit and others.

## Implications for current design

Where it costs little, current work should prefer designs that generalize:

- a device and runtime model per platform, rather than iOS assumptions buried
  in the simulator host;
- display, input and sensor pipelines (including camera and motion feeds)
  that could later carry AR data;
- the Metal → Vulkan path as a shared graphics layer.
