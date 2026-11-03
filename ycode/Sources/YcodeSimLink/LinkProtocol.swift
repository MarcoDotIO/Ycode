// The control protocol on a "control" connection (sim-link.md §6): one JSON
// request per line, one JSON response per line, in order. An `upload`
// request is followed by its archive (DirectoryArchive) on the same
// connection, then answered.

import Foundation

public struct LinkRequest: Codable, Sendable, Equatable {
    public var op: String
    public var device: String?
    public var deviceType: String?
    public var runtime: String?
    public var app: String?
    public var bundleID: String?
    public var cold: Bool?
    public var erase: Bool?
    public var size: Int?
    public var lines: Int?
    public var from: String?

    public init(op: String, device: String? = nil, deviceType: String? = nil, runtime: String? = nil, app: String? = nil,
                bundleID: String? = nil, cold: Bool? = nil, erase: Bool? = nil, size: Int? = nil, lines: Int? = nil, from: String? = nil) {
        self.op = op
        self.device = device
        self.deviceType = deviceType
        self.runtime = runtime
        self.app = app
        self.bundleID = bundleID
        self.cold = cold
        self.erase = erase
        self.size = size
        self.lines = lines
        self.from = from
    }
}

public struct LinkDeviceInfo: Codable, Sendable, Equatable {
    public var name: String
    public var deviceType: String
    public var runtime: String
    /// "shutdown", "booting", "running", "stopping".
    public var state: String
    public var app: String?

    public init(name: String, deviceType: String, runtime: String, state: String, app: String? = nil) {
        (self.name, self.deviceType, self.runtime, self.state, self.app) = (name, deviceType, runtime, state, app)
    }
}

public struct LinkResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var error: String?
    public var message: String?
    public var devices: [LinkDeviceInfo]?
    public var deviceTypes: [String]?
    public var runtimes: [String]?
    public var log: [String]?
    public var host: String?
    public var bundleID: String?

    public init(ok: Bool, error: String? = nil, message: String? = nil) { (self.ok, self.error, self.message) = (ok, error, message) }

    public static func failure(_ e: String) -> LinkResponse { LinkResponse(ok: false, error: e) }
}

/// The ports and addresses a host uses (sim-link.md §7; every one configurable).
public enum LinkDefaults {
    public static let controlPort = 47800
    public static let mediaPort = 47801
    public static let version = "ycode-sim-link/1"
}
