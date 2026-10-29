// The settings commands of a device's control socket and of the
// `ycode-simd --device DEV --ui|--accessibility|--location|--audio …`
// command line (specs/simulator/simulator-features.md "Ycode
// implementation" §I.4). One grammar for ycode-simd, the launcher, the
// viewer and the IDE:
//
//   ui appearance [light|dark|toggle]                    (no value: prints light|dark)
//   ui content_size [<size>|increment|decrement]         (simctl's names; no value: prints the size)
//   ui increase_contrast [enabled|disabled]              (no value: prints enabled|disabled)
//   ui liquid-glass [<opacity 0…1>] [clear|tinted]
//   ui color-filter none|protanopia|deuteranopia|tritanopia|grayscale [<intensity 0.25…1>]
//   ui larger-accessibility-sizes on|off
//   accessibility reduce-motion|increase-contrast|show-borders|reduce-transparency|voiceover [on|off]
//   location set <lat>,<lon> | preset <name> | start [--speed=S] [--distance=M|--interval=S] <lat,lon>…
//            | run <scenario name> | file <path> | clear | list
//   audio volume [<0…100>|up|down] | output [none|system|<uid>] | input [none|system|<uid>] | devices
//   overrides <bundle id> [show | clear | <item>=<value>…]   (environment overrides; EnvironmentOverrides.swift)
//   settings                                              (every setting, one per line)

import Foundation

public enum SimSettingsCommand: Equatable, Sendable {
    case set(SimSetting)
    case getAppearance
    case toggleAppearance
    case getContentSize
    case stepContentSize(Int)
    case getIncreaseContrast
    case getSwitch(AccessibilitySwitch)
    case location(LocationCommand)
    /// `location file <path>`: a host file, read by the host (`SimLocation.parseFile`).
    case locationFile(String)
    case locationList
    case volume(Int)
    case stepVolume(Int)
    case getVolume
    case output(AudioDeviceChoice)
    case input(AudioDeviceChoice)
    case getOutput
    case getInput
    case audioDevices
    case overrides(bundleID: String, EnvironmentOverrides.Request)
    case state

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var message: String
        public init(_ m: String) { message = m }
        public var description: String { message }
    }

    /// The first words of the settings commands (the control socket hands
    /// these to the settings controller).
    public static let verbs: Set<String> = ["ui", "accessibility", "location", "audio", "overrides", "settings"]

    static func onOff(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "on", "enabled", "enable", "true", "yes", "1": true
        case "off", "disabled", "disable", "false", "no", "0": false
        default: nil
        }
    }

    public static func parse(_ words: [String]) throws -> SimSettingsCommand {
        guard let verb = words.first else { throw ParseError("empty command") }
        let w = Array(words.dropFirst())
        switch verb {
        case "settings": return .state
        case "ui": return try parseUI(w)
        case "accessibility": return try parseAccessibility(w)
        case "location": return try parseLocation(w)
        case "audio": return try parseAudio(w)
        case "overrides":
            guard let id = w.first else { throw ParseError("overrides <bundle id> [show|clear|<item>=<value>…]") }
            return .overrides(bundleID: id, try EnvironmentOverrides.Request.parse(Array(w.dropFirst())))
        default: throw ParseError("unknown settings command '\(verb)'")
        }
    }

    static func parseUI(_ w: [String]) throws -> SimSettingsCommand {
        let usage = "ui appearance|content_size|increase_contrast|liquid-glass|color-filter|larger-accessibility-sizes …"
        guard let what = w.first?.lowercased().replacingOccurrences(of: "_", with: "-") else { throw ParseError(usage) }
        let value = w.count > 1 ? w[1] : nil
        switch what {
        case "appearance":
            guard let value else { return .getAppearance }
            if value == "toggle" { return .toggleAppearance }
            guard let a = Appearance(rawValue: value.lowercased()) else { throw ParseError("ui appearance light|dark|toggle") }
            return .set(.appearance(a))
        case "content-size", "text-size":
            guard let value else { return .getContentSize }
            if value == "increment" { return .stepContentSize(1) }
            if value == "decrement" { return .stepContentSize(-1) }
            guard let s = ContentSize(argument: value) else {
                throw ParseError("ui content_size " + ContentSize.allCases.map(\.rawValue).joined(separator: "|") + "|increment|decrement")
            }
            return .set(.contentSize(s))
        case "increase-contrast":
            guard let value else { return .getIncreaseContrast }
            guard let on = onOff(value) else { throw ParseError("ui increase_contrast enabled|disabled") }
            return .set(.accessibility(.increaseContrast, on))
        case "liquid-glass":
            var opacity: Double?, look: GlassLook?
            for a in w.dropFirst() {
                if let l = GlassLook(rawValue: a.lowercased()) { look = l; continue }
                guard let d = Double(a), (0...1).contains(d) else { throw ParseError("ui liquid-glass [<opacity 0…1>] [clear|tinted]") }
                opacity = d
            }
            guard opacity != nil || look != nil else { throw ParseError("ui liquid-glass [<opacity 0…1>] [clear|tinted]") }
            return .set(.liquidGlass(opacity: opacity, look: look))
        case "color-filter":
            guard let value, let f = ColorFilter(argument: value) else {
                throw ParseError("ui color-filter " + ColorFilter.allCases.map(\.rawValue).joined(separator: "|") + " [<intensity 0.25…1>]")
            }
            var intensity: Double?
            if w.count > 2 {
                guard let d = Double(w[2]), ColorFilter.intensityRange.contains(d), f.intensityKey != nil else {
                    throw ParseError("ui color-filter: the intensity (0.25…1) applies to the three colour filters")
                }
                intensity = d
            }
            return .set(.colorFilter(f, intensity: intensity))
        case "larger-accessibility-sizes":
            guard let value, let on = onOff(value) else { throw ParseError("ui larger-accessibility-sizes on|off") }
            return .set(.largerAccessibilitySizes(on))
        default:
            throw ParseError(usage)
        }
    }

    static func parseAccessibility(_ w: [String]) throws -> SimSettingsCommand {
        let usage = "accessibility " + AccessibilitySwitch.allCases.map(\.rawValue).joined(separator: "|") + "|text-size [on|off]"
        guard let what = w.first else { throw ParseError(usage) }
        if what == "text-size" || what == "content-size" { return try parseUI(w) }
        if what == "larger-accessibility-sizes" { return try parseUI(w) }
        guard let s = AccessibilitySwitch(argument: what) else { throw ParseError(usage) }
        guard w.count > 1 else { return .getSwitch(s) }
        guard let on = onOff(w[1]) else { throw ParseError("accessibility \(s.rawValue) on|off") }
        return .set(.accessibility(s, on))
    }

    static func parseLocation(_ w: [String]) throws -> SimSettingsCommand {
        let usage = "location set <lat>,<lon> | preset <name> | start [--speed=S] [--distance=M|--interval=S] <lat>,<lon>… | run <scenario> | file <path> | clear | list"
        guard let what = w.first else { throw ParseError(usage) }
        switch what {
        case "set":
            guard w.count == 2, let c = Coordinate(argument: w[1]) else { throw ParseError("location set <latitude>,<longitude>") }
            return .location(.set(c))
        case "preset":
            let name = w.dropFirst().joined(separator: " ")
            guard let c = SimLocation.preset(named: name) else {
                throw ParseError("location preset " + SimLocation.presets.map(\.name).joined(separator: " | "))
            }
            return .location(.set(c))
        case "start":
            var speed = LocationCommand.defaultSpeed
            var spacing = RouteSpacing.interval(LocationCommand.defaultInterval)
            var points: [Coordinate] = []
            for a in w.dropFirst() {
                func number(_ prefix: String) throws -> Double {
                    guard let d = Double(a.dropFirst(prefix.count)), d > 0 else { throw ParseError("location start: \(a): needs a positive number") }
                    return d
                }
                if a.hasPrefix("--speed=") { speed = try number("--speed=") }
                else if a.hasPrefix("--distance=") { spacing = .distance(try number("--distance=")) }
                else if a.hasPrefix("--interval=") { spacing = .interval(try number("--interval=")) }
                else if let c = Coordinate(argument: a) { points.append(c) }
                else { throw ParseError("location start: not a waypoint: \(a)") }
            }
            guard points.count >= 2 else { throw ParseError("location start: a route needs at least 2 waypoints") }
            return .location(.route(points, speed: speed, spacing: spacing))
        case "run":
            let name = w.dropFirst().joined(separator: " ")
            guard !name.isEmpty else { throw ParseError("location run <scenario> (" + SimLocation.builtInScenarios.joined(separator: ", ") + ")") }
            // A GPX, route or coordinate file of the host; a guest path to a scenario file; a runtime scenario's name.
            if name.hasSuffix(".gpx") || name.hasSuffix(".json") || name.hasSuffix(".txt") { return .locationFile(name) }
            return .location(.scenario(name: name))
        case "file":
            guard w.count == 2 else { throw ParseError("location file <path.gpx|path.json|path.txt>") }
            return .locationFile(w[1])
        case "clear": return .location(.clear)
        case "list": return .locationList
        default: throw ParseError(usage)
        }
    }

    static func parseAudio(_ w: [String]) throws -> SimSettingsCommand {
        let usage = "audio volume [0…100|up|down] | output [none|system|<uid>] | input [none|system|<uid>] | devices"
        guard let what = w.first else { throw ParseError(usage) }
        let value = w.count > 1 ? w[1] : nil
        switch what {
        case "volume":
            guard let value else { return .getVolume }
            if value == "up" { return .stepVolume(SimAudio.volumeStep) }
            if value == "down" { return .stepVolume(-SimAudio.volumeStep) }
            guard let n = Int(value), (0...100).contains(n) else { throw ParseError("audio volume 0…100|up|down") }
            return .volume(n)
        case "output": return value.map { .output(AudioDeviceChoice(argument: $0)) } ?? .getOutput
        case "input": return value.map { .input(AudioDeviceChoice(argument: $0)) } ?? .getInput
        case "devices": return .audioDevices
        default: throw ParseError(usage)
        }
    }

    /// Whether the command needs the running device's guest agent (getters
    /// and live-only features), or can be written into a stopped device's
    /// files for its next boot (persistent settings, audio).
    public var worksOffline: Bool {
        switch self {
        case .set(let s): SimFeatureMapping.persists(s)
        case .stepContentSize, .toggleAppearance: true
        case .volume, .stepVolume, .output, .input, .getVolume, .getOutput, .getInput, .audioDevices: true
        case .getAppearance, .getContentSize, .getIncreaseContrast, .getSwitch, .state: true
        case .overrides, .locationList: true
        case .location, .locationFile: false
        }
    }

    /// The words of the command-line shorthands: `--ui a b` → ["ui", "a", "b"].
    public static let commandLineFlags: [String: String] = ["--ui": "ui", "--accessibility": "accessibility",
                                                            "--location": "location", "--audio": "audio",
                                                            "--overrides": "overrides", "--settings": "settings"]
}
