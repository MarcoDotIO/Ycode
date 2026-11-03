import Foundation
import YcodeSimFeatures

/// The settings of a Ycode remote simulator as the details pane shows them
/// (the `settings` answer of its control socket).
public struct DeviceSettingsSnapshot: Equatable, Sendable {
    public var state: SimSettingsState
    public var volume: Int
    public var output: String
    public var input: String

    /// From a `settings` reply ("ok appearance light\n…\nvolume 60\noutput system\ninput system\n…").
    public init?(reply: String) {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("ok") else { return nil }
        let lines = text.dropFirst(2).trimmingCharacters(in: .whitespaces).split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        func v(_ k: String) -> String? { lines.first { $0.hasPrefix(k + " ") }.map { String($0.dropFirst(k.count + 1)) } }
        state = SimSettingsState(lines: lines)
        volume = Int(v("volume") ?? "") ?? SimAudio.defaultVolume
        output = v("output") ?? "system"
        input = v("input") ?? "system"
    }
}
