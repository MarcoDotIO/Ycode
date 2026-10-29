// The guest-facing camera endpoint's wire format (camera.md §9, "Ycode
// implementation"): a Ycode-named host-side Mach service, `dev.ycode.camera`,
// that Ycode's guest capture layer (SimGuestAgents/camera) talks to. Ycode's
// own design; nothing here is an Apple protocol.
//
// MIG-style plain Mach messages, little-endian 32-bit words after the 8-byte
// NDR record. Request n has ID `base + n`; its reply `base + 100 + n`.
// Messages the host sends to a client's frame port have IDs `base + 200 + k`.
//
//   1 devices  (simple)  words: protocol version
//              reply (complex): OOL binary property list (§9.2); words: its length
//   2 start    (complex) port descriptor: make-send of the client's frame port;
//              words: device index, width, height, frames per second x 1000,
//              pixel format (CoreVideo OSType), flags (0)
//              reply (simple): status, stream ID, width, height, fps x 1000, pixel format
//   3 stop     (simple)  words: stream ID          reply (simple): status
//   4 release  (one-way) words: stream ID, ring slot, sequence (low, high)
//
//   frame (200, one-way to the frame port): stream ID, sequence (low, high),
//              surface ID, ring slot, seed, width, height, pixel format,
//              frames dropped before it, flags (bit 0 synthetic),
//              presentation time in guest mach ticks (low, high),
//              duration in guest mach ticks (low, high)
//   event (201, one-way to the frame port): stream ID, kind, width, height

import Foundation

/// Constants and word helpers for the `dev.ycode.camera` wire format
/// described above (`camera.md` §9.2). Shared by `CameraGuestService` and
/// the tests.
public enum CameraGuestProtocol {
    /// The Mach service name the guest capture layer looks up.
    public static let serviceName = "dev.ycode.camera"
    /// 'YCM\0'.
    public static let base: Int32 = 0x5943_4D00
    /// The protocol version a device-list request carries.
    public static let version: UInt32 = 1

    /// Request numbers n (message ID `base + n`, reply `base + 100 + n`).
    public enum Request {
        public static let devices: Int32 = 1, start: Int32 = 2, stop: Int32 = 3, release: Int32 = 4
    }

    /// Numbers of the one-way messages the host sends to a client's frame
    /// port (message ID `base + n`).
    public enum ToClient {
        public static let frame: Int32 = 200, event: Int32 = 201
    }

    /// Reply status words.
    public enum Status {
        /// Success.
        public static let ok: UInt32 = 0
        /// No camera (the host has none, or it was turned off).
        public static let noDevice: UInt32 = 1
        /// Another host program holds the camera.
        public static let busy: UInt32 = 2
        /// A malformed request (unknown device index, format or stream).
        public static let badRequest: UInt32 = 3
        /// Any other failure opening or streaming.
        public static let failed: UInt32 = 4
    }

    /// Event kinds (camera.md §7.2 C, step 9: host events behind the
    /// public notifications).
    public enum EventKind {
        /// Another guest process took the camera (session interruption,
        /// reason "video device in use by another client").
        public static let interrupted: UInt32 = 1
        /// The camera is this client's again (interruption ended).
        public static let interruptionEnded: UInt32 = 2
        /// The host camera went away (unplugged): device disconnected.
        public static let disconnected: UInt32 = 3
        /// It came back (device connected); width and height of the stream.
        public static let reconnected: UInt32 = 4
        /// The stream ended without the client asking (a runtime error).
        public static let failed: UInt32 = 5
    }

    /// Frame flags.
    public static let flagSynthetic: UInt32 = 1

    static let ndr: [UInt8] = [0, 0, 0, 0, 1, 0, 0, 0]

    /// `v` as four little-endian bytes.
    public static func le(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }

    /// NDR followed by the words.
    public static func body(_ words: [UInt32]) -> [UInt8] { ndr + words.flatMap(le) }

    /// Word `i` after the NDR record (0 when the body is short).
    public static func word(_ body: [UInt8], _ i: Int) -> UInt32 {
        let at = 8 + 4 * i
        guard body.count >= at + 4 else { return 0 }
        return UInt32(body[at]) | UInt32(body[at + 1]) << 8 | UInt32(body[at + 2]) << 16 | UInt32(body[at + 3]) << 24
    }

    /// How many whole words follow the NDR record (0 for a short body).
    public static func words(_ body: [UInt8]) -> Int { max(0, (body.count - 8) / 4) }

    /// A 64-bit value as two words, low word first.
    public static func split(_ v: UInt64) -> [UInt32] { [UInt32(truncatingIfNeeded: v), UInt32(truncatingIfNeeded: v >> 32)] }
    /// The 64-bit value of a low and a high word (inverse of `split`).
    public static func join(_ lo: UInt32, _ hi: UInt32) -> UInt64 { UInt64(lo) | UInt64(hi) << 32 }

    /// The frame message's words.
    public static func frameWords(stream: UInt32, frame: CameraFrame, presentationTicks: UInt64, durationTicks: UInt64,
                                  dropped: Int) -> [UInt32] {
        [stream] + split(frame.sequence)
            + [frame.surfaceID, UInt32(frame.slot), frame.seed, UInt32(frame.width), UInt32(frame.height), frame.format.rawValue,
               UInt32(clamping: dropped), frame.synthetic ? flagSynthetic : 0]
            + split(presentationTicks) + split(durationTicks)
    }
}

// MARK: - What the guest sees (camera.md §7.2 C, step 9)

/// How the host camera appears to the guest: one capture device.
public struct CameraGuestPresentation: Sendable, Equatable {
    /// `back` (iPhone default), `front`, or `external` (iPad device types:
    /// the external device type, position unspecified).
    public enum Placement: String, Sendable, CaseIterable { case back, front, external }

    public var placement: Placement
    public init(placement: Placement) { self.placement = placement }

    /// The public AVCaptureDeviceType string values (`AVCaptureDevice.h`).
    public var deviceType: String {
        placement == .external ? "AVCaptureDeviceTypeExternal" : "AVCaptureDeviceTypeBuiltInWideAngleCamera"
    }

    /// AVCaptureDevicePosition: 0 unspecified, 1 back, 2 front.
    public var position: Int {
        switch placement {
        case .back: 1
        case .front: 2
        case .external: 0
        }
    }

    /// The device's localized name: built-in positions are named after the
    /// position; an external camera keeps the host camera's own name.
    public func localizedName(hostName: String) -> String {
        switch placement {
        case .back: "Back Camera"
        case .front: "Front Camera"
        case .external: hostName
        }
    }

    /// Stable while the host camera stays the same (its host ID is part of it).
    public func uniqueID(hostID: String) -> String { "dev.ycode.camera.\(placement.rawValue):\(hostID)" }
}

/// One size the guest device offers, with its frame-rate range.
public struct CameraGuestFormat: Sendable, Equatable {
    public var width: Int, height: Int
    public var minFPS: Double, maxFPS: Double
    public init(width: Int, height: Int, minFPS: Double, maxFPS: Double) {
        (self.width, self.height, self.minFPS, self.maxFPS) = (width, height, minFPS, maxFPS)
    }
}

/// Builds the guest device's format list from a host camera's formats
/// (`camera.md` §9.2, "Device presentation").
public enum CameraGuestFormats {
    /// The sizes offered when the camera has them (camera.md §7.2 A.3: a
    /// small fixed list built from what the camera really supports).
    public static let preferredSizes: [(Int, Int)] = [(352, 288), (640, 480), (960, 540), (1280, 720), (1920, 1080), (3840, 2160)]

    /// The guest's format list for a host camera: the preferred sizes it
    /// offers in a format Ycode converts (each with the slowest and fastest
    /// rate over those formats), smallest first. A camera with none of
    /// them offers all its convertible sizes.
    public static func list(for device: CameraDevice) -> [CameraGuestFormat] {
        var rates: [String: (w: Int, h: Int, lo: Double, hi: Double)] = [:]
        for f in device.formats where f.format.isSupported {
            for s in f.sizes where !s.intervals.isEmpty {
                let fps = s.intervals.map(\.framesPerSecond)
                let key = "\(s.width)x\(s.height)"
                let old = rates[key]
                rates[key] = (s.width, s.height, min(old?.lo ?? .infinity, fps.min()!), max(old?.hi ?? 0, fps.max()!))
            }
        }
        let all = rates.values.map { CameraGuestFormat(width: $0.w, height: $0.h, minFPS: $0.lo, maxFPS: $0.hi) }
        let preferred = all.filter { f in preferredSizes.contains { $0.0 == f.width && $0.1 == f.height } }
        return (preferred.isEmpty ? all : preferred).sorted { ($0.width * $0.height, $0.width) < ($1.width * $1.height, $1.width) }
    }

    /// The device list the guest reads (request 1): a dictionary with
    /// `version` and `devices`, each device a dictionary of `uniqueID`,
    /// `localizedName`, `modelID`, `manufacturer`, `deviceType`, `position`
    /// and `formats` (dictionaries of `width`, `height`, `minFrameRate`,
    /// `maxFrameRate`).
    public static func plist(device: CameraDevice, presentation: CameraGuestPresentation) -> [String: Any] {
        let formats: [[String: Any]] = list(for: device).map {
            ["width": $0.width, "height": $0.height, "minFrameRate": $0.minFPS, "maxFrameRate": $0.maxFPS]
        }
        let d: [String: Any] = [
            "uniqueID": presentation.uniqueID(hostID: device.id),
            "localizedName": presentation.localizedName(hostName: device.name),
            "modelID": device.name,
            "manufacturer": "Ycode",
            "deviceType": presentation.deviceType,
            "position": presentation.position,
            "formats": formats,
        ]
        return ["version": Int(CameraGuestProtocol.version), "devices": [d]]
    }
}

// MARK: - Time (camera.md §7.2 B.6: presentation times in guest host-time units)

/// Converts host CLOCK_MONOTONIC nanoseconds into the guest's
/// `mach_absolute_time` ticks, from a reading of both clocks taken together.
public struct CameraGuestTime: Sendable, Equatable {
    public var hostNanoseconds: UInt64
    public var guestTicks: UInt64
    public var frequency: UInt64

    public init(hostNanoseconds: UInt64, guestTicks: UInt64, frequency: UInt64) {
        (self.hostNanoseconds, self.guestTicks, self.frequency) = (hostNanoseconds, guestTicks, max(frequency, 1))
    }

    /// The guest ticks at host time `ns` (before or after the reading).
    public func ticks(atHostNanoseconds ns: Int64) -> UInt64 {
        let delta = ns - Int64(bitPattern: hostNanoseconds)
        let scaled = Self.scale(abs(delta), frequency)
        return delta >= 0 ? guestTicks &+ scaled : (guestTicks >= scaled ? guestTicks - scaled : 0)
    }

    /// A duration in nanoseconds as guest ticks.
    public func ticks(forNanoseconds ns: Int64) -> UInt64 { Self.scale(max(ns, 0), frequency) }

    static func scale(_ ns: Int64, _ hz: UInt64) -> UInt64 {
        let (hi, lo) = UInt64(ns).multipliedFullWidth(by: hz)
        return hi >= 1_000_000_000 ? .max : UInt64(1_000_000_000).dividingFullWidth((hi, lo)).quotient
    }
}
