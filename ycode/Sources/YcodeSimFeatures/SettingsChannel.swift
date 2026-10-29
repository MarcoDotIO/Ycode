// Ycode's host channel to its guest settings agent
// (specs/simulator/simulator-features.md "Ycode implementation" §I.2).
//
// The agent connects an AF_UNIX stream socket to the guest path
// `/private/var/run/dev.ycode.settings`; the VMM answers that path itself
// (a host-provided socket, like the DNS service's), so no guest listener and
// no file in DEV is involved. Every message, both ways, is one frame: a
// 4-byte big-endian length, then that many bytes of an XML property list
// whose root is a dictionary.
//
// Host → agent (requests): { id: int, op: string, … }
//   op "apply":    writes: [{ domain, key, value? }] (no value: remove the key),
//                  notify: [names], startServices: [Mach service names] (optional;
//                  their on-demand jobs are started), waitVoiceOver: bool (optional)
//   op "read":     reads: [{ domain, key }]
//   op "notify":   notify: [names]
//   op "location": steps: [{ call, … }] (SimLocation.LocationStep.dictionary)
//   op "watch":    notify: [names] — the agent reports each as an event
//   op "ping"
// Agent → host: replies { id, ok: bool, error?: string, values?: { "domain|key": value },
//   voiceOverRunning?: bool } and events { event: "hello", pid, version } /
//   { event: "notification", name }.

import Foundation

public enum SettingsChannel {
    /// The guest paths a connect reaches the host end at.
    public static let guestPaths = ["/private/var/run/dev.ycode.settings", "/var/run/dev.ycode.settings"]
    public static let protocolVersion = 1
    /// A frame larger than this is refused (both ends).
    public static let maximumFrame = 1 << 20

    /// One frame: the length and the XML plist.
    public static func frame(_ message: [String: Any]) -> [UInt8]? {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0),
              data.count <= maximumFrame else { return nil }
        let n = UInt32(data.count)
        return [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + [UInt8](data)
    }

    /// Splits complete frames off the front of `buffer` (consumed). Throws
    /// on a frame too large or not a dictionary plist.
    public static func takeFrames(_ buffer: inout [UInt8]) throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        while buffer.count >= 4 {
            let n = Int(buffer[0]) << 24 | Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
            guard n <= maximumFrame else { throw ChannelError.frameTooLarge(n) }
            guard buffer.count >= 4 + n else { break }
            let body = Data(buffer[4..<(4 + n)])
            buffer.removeFirst(4 + n)
            guard let o = try? PropertyListSerialization.propertyList(from: body, options: [], format: nil) as? [String: Any] else {
                throw ChannelError.notADictionary
            }
            out.append(o)
        }
        return out
    }

    public enum ChannelError: Error, Equatable {
        case frameTooLarge(Int)
        case notADictionary
    }

    // MARK: Requests

    public static func apply(_ plan: SettingsPlan) -> [String: Any] {
        var m: [String: Any] = ["op": "apply",
                                "writes": plan.writes.map { w -> [String: Any] in
                                    var d: [String: Any] = ["domain": w.domain, "key": w.key]
                                    if let v = w.value { d["value"] = v.plistObject }
                                    return d
                                },
                                "notify": plan.notifications]
        if let w = plan.waitForVoiceOver { m["waitVoiceOver"] = w }
        if !plan.startServices.isEmpty { m["startServices"] = plan.startServices }
        return m
    }

    public static func read(_ reads: [PreferenceRead]) -> [String: Any] {
        ["op": "read", "reads": reads.map { ["domain": $0.domain, "key": $0.key] }]
    }

    public static func notify(_ names: [String]) -> [String: Any] { ["op": "notify", "notify": names] }
    public static func watch(_ names: [String]) -> [String: Any] { ["op": "watch", "notify": names] }

    public static func location(_ steps: [LocationStep]) -> [String: Any] {
        ["op": "location", "steps": steps.map(\.dictionary)]
    }

    /// The values of a read's reply (tag → value).
    public static func values(of reply: [String: Any]) -> [String: PrefValue] {
        var out: [String: PrefValue] = [:]
        for (k, v) in reply["values"] as? [String: Any] ?? [:] {
            if let p = PrefValue(plistObject: v) { out[k] = p }
        }
        return out
    }
}
