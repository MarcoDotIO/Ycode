// `ycode-simd --device DEV --ui|--accessibility|--location|--audio|--overrides|--settings …`
// (specs/simulator/simulator-features.md "Ycode implementation" §I.4): one
// settings command for the device. A running device gets it through its
// control socket (FoldControl.swift; SimSettings.swift answers); a stopped
// device gets the persistent settings written into its files for the next
// boot (OfflineSettings). Prints the answer; exit 0 for "ok", 1 for an
// error, 64 for bad usage, 69 for a command that needs a running device.

#if os(Linux) && arch(arm64)
import Foundation
import Glibc
import YcodeSimFeatures

func isSettingsClient(_ arguments: [String]) -> Bool {
    arguments.contains { SimSettingsCommand.commandLineFlags[$0] != nil }
}

func runSettingsClient(_ arguments: [String]) -> Never {
    var dev: String?
    var runtimeRoot: String?
    var words: [String] = []
    var i = 1
    let help = "usage: ycode-simd --device <dir> [--runtime-root <dir>] --ui|--accessibility|--location|--audio|--overrides <words…> | --settings"
    while i < arguments.count {
        let a = arguments[i]
        if let verb = SimSettingsCommand.commandLineFlags[a] {
            words = [verb] + arguments[(i + 1)...]
            break
        }
        switch a {
        case "--device":
            i += 1
            guard i < arguments.count else { die(help, status: 64) }
            dev = arguments[i]
        case "--runtime-root":
            i += 1
            guard i < arguments.count else { die(help, status: 64) }
            runtimeRoot = arguments[i]
        default: die("unknown argument '\(a)'\n\(help)", status: 64)
        }
        i += 1
    }
    guard let dev else { die(help, status: 64) }
    // A file named on this host: an absolute path for the device's process.
    if words.count == 3, words[0] == "location", words[1] == "file" || words[1] == "run",
       words[2].hasSuffix(".gpx") || words[2].hasSuffix(".json") || words[1] == "file", !words[2].hasPrefix("/") {
        words[2] = FileManager.default.currentDirectoryPath + "/" + words[2]
    }
    let parsed: SimSettingsCommand
    do { parsed = try SimSettingsCommand.parse(words) } catch { die("\(error)\n\(help)", status: 64) }
    let path = DeviceLayout.controlSocketPath(dev: absolutePath(dev))
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    let text: String
    if fd >= 0, withUnixAddress(path, { connect(fd, $0, $1) }) == 0 {
        let line = words.joined(separator: " ") + "\n"
        _ = line.withCString { write(fd, $0, strlen($0)) }
        var reply = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            reply += buf[0..<n]
        }
        close(fd)
        text = String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        if fd >= 0 { close(fd) }
        guard FileManager.default.fileExists(atPath: absolutePath(dev) + "/data") else {
            stderrLine("ycode-simd: no device at \(dev)")
            exit(69)
        }
        guard parsed.worksOffline else {
            stderrLine("ycode-simd: no running device at \(dev); \(words.prefix(2).joined(separator: " ")) needs a running device")
            exit(69)
        }
        text = OfflineSettings.handle(words, dev: absolutePath(dev), runtimeRoot: runtimeRoot.map(absolutePath))
    }
    // Getters print the bare value (simctl's output: light, dark, enabled, …).
    if text.hasPrefix("ok ") { print(String(text.dropFirst(3))) } else { print(text) }
    exit(text.hasPrefix("ok") ? 0 : 1)
}
#else
func isSettingsClient(_ arguments: [String]) -> Bool { false }
func runSettingsClient(_ arguments: [String]) -> Never { fatalError("the settings client runs on Linux arm64 only") }
#endif
