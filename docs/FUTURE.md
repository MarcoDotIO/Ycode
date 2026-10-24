# Future work: other platforms and open frameworks

This is the long-term direction of the project. It is **not** current
work. Today the simulator track is focused on the iOS simulator on arm64
Linux, and on making it as fast as the reference simulator.

## Order of platforms

After the iOS simulator reaches performance parity, the other simulator
platforms come in this order:

1. iPadOS
2. macOS
3. visionOS
4. watchOS
5. tvOS

## Why this order

The goal is an iOS simulator that works with **ARKit and RealityKit**: a
virtual iPhone running inside a visionOS-like environment, which simulates
the real world the device sees. visionOS comes before watchOS and tvOS
because that environment depends on it.

## Open frameworks

A related goal is open-source reimplementations of Apple's frameworks that
build on Linux, like Ycode itself. Examples: RealityKit, ARKit, SwiftUI,
AppKit, StoreKit, WeatherKit, MapKit, HealthKit and HomeKit. They would be
written under the same clean-room protocol as Ycode (see
[CLAUDE.md](../CLAUDE.md)): specifications from public documentation and
black-box behavior, never Apple code.

## Implications for current design

Where it costs little, current work should prefer designs that generalize:

- a device and runtime model per platform, rather than iOS assumptions buried
  in the simulator host;
- display, input and sensor pipelines (including camera and motion feeds)
  that could later carry AR data;
- the Metal → Vulkan path as a shared graphics layer.
