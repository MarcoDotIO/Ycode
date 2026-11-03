// `ycode-simd --device DEV --health <words…>` (health-simulation.md §8.3
// H-7, "Ycode implementation"): one `health` command for the device. A
// running device gets it through its control socket (HealthHost answers);
// a shut-down device takes the store edits at once (grant, revoke, seed:
// a backup first, then the edit) and answers status from its files. Exit 0
// for "ok", 1 for an error, 64 for bad usage, 69 for a command that needs a
// running device (or a shut-down one).

import Foundation
import YcodeHealthStore
import YcodeSimFeatures

#if os(Linux) && arch(arm64)
import Glibc

func isHealthClient(_ arguments: [String]) -> Bool { arguments.contains("--health") }

func runHealthClient(_ arguments: [String]) -> Never {
    let help = "usage: ycode-simd --device <dir> --health <words…>\n" + HealthCommand.usage
    var dev: String?
    var words: [String] = []
    var i = 1
    while i < arguments.count {
        let a = arguments[i]
        if a == "--health" {
            words = Array(arguments[(i + 1)...])
            break
        }
        if a == "--device", i + 1 < arguments.count {
            dev = arguments[i + 1]
            i += 2
            continue
        }
        die("unknown argument '\(a)'\n\(help)", status: 64)
    }
    guard let dev else { die(help, status: 64) }
    let device = absolutePath(dev)
    let command: HealthCommand
    do { command = try HealthCommand.parse(words) } catch { die("\(error)", status: 64) }
    // Host files: absolute for the device's ycode-simd.
    switch command {
    case .importFile(let path, _), .seedFile(let path):
        if let k = words.firstIndex(of: path) { words[k] = absolutePath(path) }
    default: break
    }
    let path = DeviceLayout.controlSocketPath(dev: device)
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    var text: String
    if fd >= 0, withUnixAddress(path, { connect(fd, $0, $1) }) == 0 {
        let line = (["health"] + words).joined(separator: " ") + "\n"
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
        guard FileManager.default.fileExists(atPath: device + "/data") else {
            stderrLine("ycode-simd: no device at \(dev)")
            exit(69)
        }
        guard command.worksOffline else {
            stderrLine("ycode-simd: no running device at \(dev); health \(words.first ?? "") needs a running device (its guest agent writes through HealthKit)")
            exit(69)
        }
        text = OfflineHealth.handle(command, dev: device)
    }
    print(text.hasPrefix("ok ") ? String(text.dropFirst(3)) : text)
    exit(text.hasPrefix("ok") ? 0 : 1)
}
#else
func isHealthClient(_ arguments: [String]) -> Bool { false }
func runHealthClient(_ arguments: [String]) -> Never { fatalError("the health client runs on Linux arm64 only") }
#endif

/// `health` commands of a shut-down device: its store and files directly.
enum OfflineHealth {
    static func handle(_ command: HealthCommand, dev: String, now: Date = Date()) -> String {
        let files = HealthDeviceFiles(dev: dev)
        let store = files.store
        switch command {
        case .status:
            var lines = ["device: shut down"]
            if !store.exists {
                lines.append("health store: none yet (made at the first boot)")
            } else {
                let rows = (try? store.authorizationRows(bundleID: HealthChannel.agentBundleID)) ?? []
                let granted = rows.filter { $0.status == HealthAuthorizationCode.sharingAuthorized }.count
                lines.append(rows.isEmpty ? "agent: has not asked for access yet (it asks at its first boot)"
                    : "agent: \(granted) of \(rows.count) types granted" + (granted < rows.count ? " (the rest at the next cold boot)" : ""))
            }
            let pending = files.pending()
            if !pending.isEmpty { lines.append("queued for the next cold boot: " + pending.joined(separator: "; ")) }
            return "ok " + lines.joined(separator: "\n")
        case .grant(var id), .revoke(var id):
            let isGrant: Bool = { if case .grant = command { return true } else { return false } }()
            let verb = isGrant ? "grant" : "revoke"
            // A watch app's rows are its companion's (health-simulation.md §12.1).
            var note = ""
            if let companion = HealthWatchApps.companion(of: id, deviceData: dev + "/data") {
                note = " (\(id) is a watch app: its HealthKit access is recorded under its companion \(companion))"
                id = companion
            }
            guard store.exists else {
                files.queue(verb, id)
                return "ok \(verb) \(id) queued: the device has no health store yet (it applies after the app asks for access)"
            }
            do {
                let rows = try store.authorizationRows(bundleID: id)
                if rows.isEmpty {
                    files.queue(verb, id)
                    return "ok \(verb) \(id) queued: the app has not asked for access on this device yet; run it once "
                        + "(it asks and the sheet opens; close it), then the grant applies at the next cold boot" + note
                }
                let backup = try store.backup(into: files.backupsPath, reason: verb, now: now)
                let r = isGrant ? try store.grant(bundleID: id, now: now) : try store.revoke(bundleID: id, now: now)
                files.setPending(files.pending().filter { !$0.hasSuffix(" " + id) })
                return "ok \(verb) \(id): \(r) (backup \(backup))" + note
            } catch {
                return "error \(verb) \(id): \(error)"
            }
        case .seedFile, .seedScenario:
            return HealthSeeding.handle(command, files: files, now: now)
        default:
            return "error health \(command): needs a running device"
        }
    }
}
