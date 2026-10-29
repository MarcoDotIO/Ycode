// Sound, Output and Input (specs/simulator/simulator-features.md
// §4.11–4.13; audio-host.md §12, §13): the two settings files the host
// writes and the notifications the guest agent posts.

import Foundation

/// An audio device choice: none (muted), the host's default ("System",
/// Use System Settings), or one host device by UID.
public enum AudioDeviceChoice: Equatable, Sendable {
    case none
    case system
    case device(String)

    public init(argument: String) {
        switch argument.lowercased() {
        case "none", "off": self = .none
        case "system", "default", "use-system-settings": self = .system
        default: self = .device(argument)
        }
    }

    public var argument: String {
        switch self {
        case .none: "none"
        case .system: "system"
        case .device(let uid): uid
        }
    }

    public var title: String {
        switch self {
        case .none: "None"
        case .system: "System"
        case .device(let uid): uid
        }
    }
}

/// The device's audio settings as Ycode keeps them (DEV/ycode-settings.plist).
public struct SimAudioSettings: Equatable, Sendable {
    public var volume: Int = SimAudio.defaultVolume
    public var output: AudioDeviceChoice = .system
    public var input: AudioDeviceChoice = .system

    public init(volume: Int = SimAudio.defaultVolume, output: AudioDeviceChoice = .system, input: AudioDeviceChoice = .system) {
        self.volume = volume
        self.output = output
        self.input = input
    }
}

public enum SimAudio {
    public static let defaultVolume = 60
    public static let ringerState = 1
    /// Ycode's one output device (audio-host.md §13.3); there is no input device.
    public static let ycodeOutputUID = "dev.ycode.simulator.audio.output"

    /// The host devices Ycode's audio service offers. **Ycode decision**: the
    /// service has one output device and no input device, and it does not
    /// enumerate the Linux host's devices; the choices are None, System and
    /// that output device.
    public static let outputDevices: [(uid: String, name: String)] = [(ycodeOutputUID, "Ycode Simulator Output")]
    public static let inputDevices: [(uid: String, name: String)] = []

    /// The device UID a choice resolves to (what the guest's settings file names).
    public static func resolvedUID(_ choice: AudioDeviceChoice, output: Bool) -> String {
        switch choice {
        case .none: ""
        case .system: output ? ycodeOutputUID : ""
        case .device(let uid): uid
        }
    }

    /// `DEV/data/var/run/com.apple.coresimulator.audio.plist` (§4.12).
    /// **Ycode decision** (open question Q7): None is an empty UID with the
    /// host-default flag off; System is the default device's UID with the flag on.
    public static func hostFile(_ s: SimAudioSettings) -> [String: Any] {
        ["sim_output_device_uid": resolvedUID(s.output, output: true),
         "sim_input_device_uid": resolvedUID(s.input, output: false),
         "useHostDefaultOutputDevice": s.output == .system,
         "useHostDefaultInputDevice": s.input == .system]
    }

    /// `DEV/data/var/run/simulatoraudio/audiosettings.plist` (audio-host.md §12).
    public static func settingsFile(_ s: SimAudioSettings) -> [String: Any] {
        ["sim_input_device_uid": resolvedUID(s.input, output: false),
         "sim_output_device_uid": resolvedUID(s.output, output: true),
         "sim_ringer_state": ringerState,
         "sim_volume": min(100, max(0, s.volume))]
    }

    /// Reads the choices back from the host file (nil when absent or malformed).
    public static func settings(hostFile: [String: Any]?, settingsFile: [String: Any]?) -> SimAudioSettings {
        var s = SimAudioSettings()
        if let v = (settingsFile?["sim_volume"] as? NSNumber)?.intValue { s.volume = min(100, max(0, v)) }
        func choice(_ uidKey: String, _ flagKey: String) -> AudioDeviceChoice {
            guard let h = hostFile else { return .system }
            if (h[flagKey] as? NSNumber)?.boolValue ?? (h[flagKey] as? Bool) ?? false { return .system }
            let uid = h[uidKey] as? String ?? ""
            return uid.isEmpty ? .none : .device(uid)
        }
        s.output = choice("sim_output_device_uid", "useHostDefaultOutputDevice")
        s.input = choice("sim_input_device_uid", "useHostDefaultInputDevice")
        return s
    }

    /// Volume steps of the Increase/Decrease Volume items (Ycode: 10).
    public static let volumeStep = 10
}
