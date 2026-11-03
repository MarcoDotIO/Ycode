// Ycode's host channel to its guest health agent (health-simulation.md §8.1
// H-3, "Ycode implementation"). The agent connects an AF_UNIX stream socket
// to `/private/var/run/dev.ycode.health`, which the VMM answers itself (as
// the settings channel, simulator-features.md §I.2). Frames both ways: a
// 4-byte big-endian length, then an XML property list with a dictionary
// root, at most 16 MiB (a workout with its route is larger than the settings
// channel's 1 MiB). Dates are seconds since 1970 as numbers.
//
// Host → agent: { id, op, … }
//   authorize {share: [ids], read: [ids]}
//   write {samples: [sample], device?: {name, model, …}}
//   workout {activity, start, end, indoor, samples: [sample], route?: [[lat, lon, t]], metadata?}
//   delete {types: [ids]}          the agent's own samples of those types
//   count {types: [ids]}           the agent's own samples, per type
//   status {types: [ids]}          availability, source, authorization status per type
//   ping
// Agent → host: replies { id, ok, error?, saved?, refused?, deleted?, counts?, statuses?, ms }
//   and the event { event: "hello", pid, version, available, bundleID, source, model }.

import Foundation

public enum HealthChannel {
    public static let guestPaths = ["/private/var/run/dev.ycode.health", "/var/run/dev.ycode.health"]
    public static let protocolVersion = 1
    public static let maximumFrame = 16 << 20
    /// Samples per write request (a request of these is well under the frame limit).
    public static let samplesPerRequest = 1000
    /// The agent's bundle id: its HealthKit source.
    public static let agentBundleID = "dev.ycode.health"

    public static func frame(_ message: [String: Any]) -> [UInt8]? {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0),
              data.count <= maximumFrame else { return nil }
        let n = UInt32(data.count)
        return [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + [UInt8](data)
    }

    public static func takeFrames(_ buffer: inout [UInt8]) throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        while buffer.count >= 4 {
            let n = Int(buffer[0]) << 24 | Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
            guard n <= maximumFrame else { throw SettingsChannel.ChannelError.frameTooLarge(n) }
            guard buffer.count >= 4 + n else { break }
            let body = Data(buffer[4..<(4 + n)])
            buffer.removeFirst(4 + n)
            guard let o = try? PropertyListSerialization.propertyList(from: body, options: [], format: nil) as? [String: Any] else {
                throw SettingsChannel.ChannelError.notADictionary
            }
            out.append(o)
        }
        return out
    }

    // MARK: Requests

    public static func authorize(share: [String], read: [String]) -> [String: Any] {
        ["op": "authorize", "share": share, "read": read]
    }

    /// Write requests of at most `samplesPerRequest` samples each.
    public static func writes(_ samples: [HealthSample], device: [String: String]? = nil) -> [[String: Any]] {
        stride(from: 0, to: samples.count, by: samplesPerRequest).map { i in
            var m: [String: Any] = ["op": "write", "samples": samples[i..<min(samples.count, i + samplesPerRequest)].map(\.plist)]
            if let device { m["device"] = device }
            return m
        }
    }

    public static func workout(_ w: HealthWorkout) -> [String: Any] {
        var m = w.plist
        m["op"] = "workout"
        return m
    }

    public static func delete(_ types: [String]) -> [String: Any] { ["op": "delete", "types": types] }
    public static func count(_ types: [String]) -> [String: Any] { ["op": "count", "types": types] }
    public static func status(_ types: [String]) -> [String: Any] { ["op": "status", "types": types] }
    public static var ping: [String: Any] { ["op": "ping"] }

    /// A reply's counts (type → n).
    public static func counts(of reply: [String: Any]) -> [String: Int] {
        (reply["counts"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
    }
}
