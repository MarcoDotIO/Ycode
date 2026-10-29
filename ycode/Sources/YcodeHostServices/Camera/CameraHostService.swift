// The host camera service (camera-host.md §5, §6): picks a device, runs a
// capture thread, converts each frame into the next free surface of a
// small ring of host-made IOSurfaces, and hands the frame (surface ID,
// format, size, presentation time) to a callback. The guest-facing part
// (the guest's camera stack, per camera.md) sits on top of this interface.

import CYcodeCamera
import Foundation

/// A ring of host-made surfaces for one stream (§5.2).
public final class CameraSurfaceRing: @unchecked Sendable {
    public struct Slot: @unchecked Sendable {
        public var surfaceID: UInt32
        public var port: UInt32
        public var memory: UnsafeMutableRawPointer
        /// Held by the frame consumer (not reused until released).
        public var held = false
        /// Being written by the host.
        public var writing = false
    }

    public let layout: CameraSurfaceLayout
    public let surfaces: IOSurfaceHostService
    private let lock = NSLock()
    private var slots: [Slot] = []
    private var last = -1

    /// Makes `count` surfaces named `<name> <index>`.
    public init(surfaces: IOSurfaceHostService, layout: CameraSurfaceLayout, count: Int, name: String,
                colorimetry: CameraColorimetry) throws {
        self.surfaces = surfaces
        self.layout = layout
        for i in 0..<max(1, count) {
            guard let made = surfaces.makeHostSurface(width: layout.width, height: layout.height, pixelFormat: layout.format.rawValue,
                                                      bytesPerElement: layout.bytesPerElement, bytesPerRow: layout.bytesPerRow,
                                                      allocationSize: layout.allocationSize, planes: layout.planes,
                                                      name: "\(name) \(i)", attachments: layout.attachments(colorimetry)) else {
                invalidate()
                throw CameraError(.io, "cannot make a \(layout.width)x\(layout.height) \(layout.format) surface")
            }
            slots.append(Slot(surfaceID: made.surface.id, port: made.port, memory: made.surface.memory.host))
        }
    }

    public var count: Int { lock.withLock { slots.count } }
    public var surfaceIDs: [UInt32] { lock.withLock { slots.map(\.surfaceID) } }

    public func slot(_ i: Int) -> Slot { lock.withLock { slots[i] } }

    /// The next slot after the last written one that no one uses: not held
    /// by the consumer, not locked or in use by a guest (Methods 4, 15).
    /// Nil when every surface is busy (the frame is dropped).
    public func acquire() -> Int? {
        lock.withLock {
            for step in 1...slots.count {
                let i = (last + step) % slots.count
                guard !slots[i].held, !slots[i].writing else { continue }
                if let u = surfaces.guestUsage(id: slots[i].surfaceID), u.useCount > 0 || u.lockCount > 0 { continue }
                slots[i].writing = true
                return i
            }
            return nil
        }
    }

    /// The write is done: raises the surface's seed (returned) and marks the
    /// slot held when `hold`.
    public func commit(_ i: Int, hold: Bool) -> UInt32 {
        let id = lock.withLock {
            slots[i].writing = false
            slots[i].held = hold
            last = i
            return slots[i].surfaceID
        }
        return surfaces.hostDidWrite(id: id) ?? 0
    }

    /// The write failed: the slot is free again.
    public func cancel(_ i: Int) { lock.withLock { slots[i].writing = false } }

    /// The consumer is done with the frame in slot `i`.
    public func release(_ i: Int) { lock.withLock { if i < slots.count { slots[i].held = false } } }

    /// Releases every surface (guests that still reference one keep it).
    public func invalidate() {
        let ports = lock.withLock { () -> [UInt32] in
            defer { slots = [] }
            return slots.map(\.port)
        }
        for p in ports { surfaces.releaseHostSurface(port: p) }
    }
}

public final class CameraHostService: @unchecked Sendable {
    public typealias FrameHandler = @Sendable (CameraFrame) -> Void
    public typealias EventHandler = @Sendable (CameraEvent) -> Void

    public let surfaces: IOSurfaceHostService
    private let log: (String) -> Void
    private let lock = NSLock()
    private var thread: Thread?
    private var stopping = false
    private var ring: CameraSurfaceRing?
    private var retiredRings: [CameraSurfaceRing] = []
    private var format: CameraStreamFormat?
    private var activeDevice: CameraDevice?
    /// Counters: frames delivered, dropped (no free surface, conversion
    /// failure), and the device's corrupt frames.
    public private(set) var delivered: UInt64 = 0
    public private(set) var dropped: UInt64 = 0
    /// Conversion time (decode and pixel conversion into the surface):
    /// the total over `delivered` frames, and the slowest, in nanoseconds.
    public private(set) var conversionTotal: Int64 = 0
    public private(set) var conversionMax: Int64 = 0

    public init(surfaces: IOSurfaceHostService, log: @escaping (String) -> Void = { _ in }) {
        self.surfaces = surfaces
        self.log = log
    }

    // MARK: Devices (§2)

    /// The cameras: V4L2 capture devices, then the synthetic camera.
    public static func devices(includeSynthetic: Bool = true) -> [CameraDevice] {
        V4L2.devices().devices + (includeSynthetic ? [SyntheticCamera.device] : [])
    }

    /// `YCODE_CAMERA`: `auto` (default: the first V4L2 camera, else the
    /// synthetic one), `synthetic`, `none`, a device node (`/dev/video0`),
    /// or a device ID (`v4l2:usb-…`).
    public static var selection: String { ProcessInfo.processInfo.environment["YCODE_CAMERA"] ?? "auto" }

    /// The device a selection names. Throws `.noDevice` for `none` or when
    /// a named device is absent.
    public static func resolve(_ selection: String?, devices: [CameraDevice]? = nil) throws -> CameraDevice {
        let s = selection ?? Self.selection
        let all = devices ?? Self.devices()
        switch s {
        case "none": throw CameraError(.noDevice, "the camera is turned off (YCODE_CAMERA=none)")
        case "synthetic": return SyntheticCamera.device
        case "auto", "": return all.first { $0.kind == .v4l2 } ?? SyntheticCamera.device
        default:
            if let d = all.first(where: { $0.id == s || $0.path == s }) { return d }
            throw CameraError(.noDevice, "no camera \(s) (cameras: \(all.map(\.id).joined(separator: ", ")))")
        }
    }

    // MARK: Streaming (§5)

    public var currentFormat: CameraStreamFormat? { lock.withLock { format } }
    public var currentDevice: CameraDevice? { lock.withLock { activeDevice } }
    public var isRunning: Bool { lock.withLock { thread != nil } }
    /// The current ring's surface IDs (the guest-facing round lists them).
    public var surfaceIDs: [UInt32] { lock.withLock { ring?.surfaceIDs ?? [] } }

    /// Opens the camera `selection` names (nil: `YCODE_CAMERA`), negotiates,
    /// makes the ring, and starts the capture thread. `onFrame` runs on that
    /// thread for each frame; with `holdFramesUntilReleased` the surface is
    /// not reused until `release(_:)`.
    @discardableResult
    public func start(selection: String? = nil, configuration: CameraConfiguration = CameraConfiguration(),
                      onFrame: @escaping FrameHandler, onEvent: @escaping EventHandler = { _ in }) throws -> CameraStreamFormat {
        guard !isRunning else { throw CameraError(.busy, "the camera service is already streaming") }
        let device = try Self.resolve(selection)
        let capture = try Self.open(device, configuration)
        return try start(capture: capture, device: device, configuration: configuration,
                         auto: (selection ?? Self.selection) == "auto", onFrame: onFrame, onEvent: onEvent)
    }

    /// Starts streaming from an open capture (tests: a scripted source).
    func start(capture: CameraCapture, device: CameraDevice, configuration: CameraConfiguration, auto: Bool,
               onFrame: @escaping FrameHandler, onEvent: @escaping EventHandler) throws -> CameraStreamFormat {
        let fmt = capture.format
        let ring: CameraSurfaceRing
        do {
            ring = try makeRing(fmt, configuration)
        } catch {
            capture.close()
            throw error
        }
        lock.withLock {
            stopping = false
            self.ring = ring
            format = fmt
            activeDevice = device
            delivered = 0
            dropped = 0
            conversionTotal = 0
            conversionMax = 0
        }
        log("camera: \(device.name) (\(device.id)): \(fmt)")
        onEvent(.started(fmt))
        let t = Thread { [self] in
            run(capture: capture, device: device, configuration: configuration, auto: auto, onFrame: onFrame, onEvent: onEvent)
        }
        t.name = "ycode-camera"
        t.qualityOfService = .userInteractive
        lock.withLock { thread = t }
        t.start()
        return fmt
    }

    /// Stops the capture thread (waits for it) and releases the device and
    /// the surfaces.
    public func stop() {
        guard let t = lock.withLock({ () -> Thread? in
            stopping = true
            return thread
        }) else { return }
        while !t.isFinished { usleep(2000) }
        lock.withLock {
            thread = nil
            ring?.invalidate()
            ring = nil
            for r in retiredRings { r.invalidate() }
            retiredRings = []
            format = nil
            activeDevice = nil
        }
    }

    /// The consumer is done with `frame` (only with `holdFramesUntilReleased`).
    public func release(_ frame: CameraFrame) {
        lock.withLock {
            if let ring, ring.surfaceIDs.indices.contains(frame.slot), ring.surfaceIDs[frame.slot] == frame.surfaceID {
                ring.release(frame.slot)
            }
        }
    }

    static func open(_ device: CameraDevice, _ c: CameraConfiguration) throws -> CameraCapture {
        switch device.kind {
        case .synthetic:
            let choice = CameraNegotiation.choose(device.formats, width: c.width, height: c.height, framesPerSecond: c.framesPerSecond)
            // The synthetic camera makes any (even) size it is asked for.
            let interval = choice?.interval ?? CameraFrameInterval(fps: c.framesPerSecond)
            return SyntheticCamera(width: c.width, height: c.height, interval: interval, output: c.output)
        case .v4l2:
            return try V4L2Capture(device: device, configuration: c)
        }
    }

    private func makeRing(_ f: CameraStreamFormat, _ c: CameraConfiguration) throws -> CameraSurfaceRing {
        try CameraSurfaceRing(surfaces: surfaces, layout: CameraSurfaceLayout.make(c.output, width: f.width, height: f.height),
                              count: c.ringSize, name: "ycode-camera", colorimetry: f.colorimetry)
    }

    private func run(capture first: CameraCapture, device: CameraDevice, configuration: CameraConfiguration, auto: Bool,
                     onFrame: FrameHandler, onEvent: EventHandler) {
        var capture: CameraCapture? = first
        var standIn = false  // the synthetic camera stands in for an absent device
        var lastProbe: Int64 = 0
        let converter = CameraConverter()
        var sequence: UInt64 = 0
        var droppedSince = 0
        while !lock.withLock({ stopping }) {
            // An absent device: look for it once a second (§6).
            if device.kind == .v4l2, capture == nil || standIn {
                let now = ycam_monotonic_ns()
                if now - lastProbe > 1_000_000_000 {
                    lastProbe = now
                    let found = V4L2.devices().devices.first { $0.id == device.id || (auto && $0.kind == .v4l2) }
                    if let found, let reopened = try? V4L2Capture(device: found, configuration: configuration) {
                        capture?.close()
                        capture = reopened
                        standIn = false
                        adopt(reopened.format, device: found, configuration)
                        log("camera: \(found.name) is back: \(reopened.format)")
                        onEvent(.reconnected(reopened.format))
                    }
                }
            }
            guard let source = capture else {
                usleep(200_000)
                continue
            }
            let raw: CameraRawFrame?
            do {
                raw = try source.next(timeoutMilliseconds: 200)
            } catch {
                source.close()
                capture = nil
                let fallback = configuration.syntheticWhileAbsent && device.kind == .v4l2
                log("camera: \(device.id) lost (\(error))\(fallback ? "; synthetic frames until it is back" : "")")
                onEvent(.disconnected(deviceID: device.id, fallback: fallback))
                if fallback, let f = lock.withLock({ format }) {
                    let s = SyntheticCamera(width: f.width, height: f.height, interval: f.interval, output: configuration.output)
                    capture = s
                    standIn = true
                    adopt(s.format, device: device, configuration)
                }
                continue
            }
            guard let raw else { continue }
            guard let ring = lock.withLock({ ring }), let slot = ring.acquire() else {
                source.recycle(raw)
                droppedSince += 1
                lock.withLock { dropped += 1 }
                continue
            }
            let began = ycam_monotonic_ns()
            do {
                try converter.convert(raw, into: ring.slot(slot).memory, layout: ring.layout)
            } catch {
                ring.cancel(slot)
                source.recycle(raw)
                droppedSince += 1
                lock.withLock { dropped += 1 }
                if droppedSince <= 3 || droppedSince % 100 == 0 { log("camera: frame \(raw.deviceSequence) not converted: \(error)") }
                continue
            }
            source.recycle(raw)
            let seed = ring.commit(slot, hold: configuration.holdFramesUntilReleased)
            let s = ring.slot(slot)
            let frame = CameraFrame(sequence: sequence, deviceSequence: raw.deviceSequence, surfaceID: s.surfaceID, surfacePort: s.port,
                                    seed: seed, slot: slot, format: ring.layout.format, width: ring.layout.width,
                                    height: ring.layout.height, presentationTime: raw.timestamp,
                                    duration: source.format.interval.nanoseconds, droppedBefore: droppedSince, synthetic: raw.synthetic)
            sequence += 1
            droppedSince = 0
            let took = ycam_monotonic_ns() - began
            lock.withLock {
                delivered += 1
                conversionTotal += took
                conversionMax = max(conversionMax, took)
            }
            onFrame(frame)
        }
        capture?.close()
        onEvent(.stopped)
    }

    /// A new source format mid-stream (reconnect, stand-in): a new ring when
    /// the size changed. The old ring's surfaces are released when the
    /// service stops (a consumer may still hold frames in them).
    private func adopt(_ f: CameraStreamFormat, device: CameraDevice, _ c: CameraConfiguration) {
        let current = lock.withLock { ring }
        if current?.layout.width != f.width || current?.layout.height != f.height,
           let fresh = try? makeRing(f, c) {
            lock.withLock {
                if let current { retiredRings.append(current) }
                ring = fresh
            }
        }
        lock.withLock {
            format = f
            activeDevice = device
        }
    }
}
