// ycode-simd --device: a device directory that was copied or moved to
// another path (specs/simulator/app-launch.md §3.3). The guest sees DEV at
// a guest path, and LaunchServices' store keeps the absolute guest paths of
// every app's bundle and data containers (other daemons keep some too).
// The guest path is a property of the data, not of where the directory
// lies on the host: a copy keeps the guest path of the device it was copied
// from (the path its data was first booted at), and the VMM serves that
// guest path from the copy's own directory. The copy's stores then name its
// own containers and need no rebuild, so a copy of the pristine device, a
// benchmark copy or a YCODE_DEVICE_TEMPLATE clone boots as fast as the
// original. A LaunchServices store that names another device path than
// the guest path (data put together from two devices) is still removed
// before the boot, and lsd builds a new one (first-boot.md §1 item 5).
// Plain Foundation.

import Foundation

extension DeviceLayout {
    /// The record of the guest path of DEV's data (one line).
    var devicePathRecordPath: String { dev + "/ycode-device-path" }
    /// LaunchServices' store directory (first-boot.md §1 item 5).
    var launchServicesStorePath: String { data + "/var/db/lsd" }

    /// The LaunchServices store files (`*.csstore`) of the device.
    func launchServicesStoreFiles() -> [String] {
        Self.launchServicesStoreFiles(inData: data)
    }

    static func launchServicesStoreFiles(inData data: String) -> [String] {
        let dir = data + "/var/db/lsd"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0.hasSuffix(".csstore") }.sorted().map { dir + "/" + $0 }
    }

    /// The guest path recorded in a device directory, if any.
    static func recordedGuestDevicePath(in device: String) -> String? {
        guard let bytes = FileManager.default.contents(atPath: device + "/ycode-device-path") else { return nil }
        let path = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// The guest path a device directory's data carries: its record, or,
    /// for data without one (made before the record existed), the device
    /// path its LaunchServices store names in front of `/data/Containers/`.
    /// Nil: neither (new data).
    static func carriedGuestDevicePath(in device: String) -> String? {
        if let recorded = recordedGuestDevicePath(in: device) { return recorded }
        for file in launchServicesStoreFiles(inData: device + "/data") {
            guard let bytes = FileManager.default.contents(atPath: file) else { continue }
            if let path = foreignDevicePath(in: bytes, current: "") { return path }
        }
        return nil
    }

    /// The guest path for this boot: the one DEV's data carries (for a DEV
    /// without data that a template fills, the template's), when the guest
    /// can be given it; otherwise DEV's own path.
    func resolveGuestDevicePath() -> String {
        let fm = FileManager.default
        let carried: String?
        if !fm.fileExists(atPath: data), let templatePath {
            carried = Self.carriedGuestDevicePath(in: templatePath)
        } else {
            carried = Self.carriedGuestDevicePath(in: dev)
        }
        guard let carried, carried != dev else { return dev }
        if let problem = guestDevicePathProblem(carried) {
            FileHandle.standardError.write(Data("ycode-simd: device data carries the guest path \(carried), which \(problem); the device uses its own path\n".utf8))
            return dev
        }
        return carried
    }

    /// Why `path` cannot be DEV's guest path (nil: it can): it must be a
    /// normalized absolute path that no other guest prefix overlaps.
    func guestDevicePathProblem(_ path: String) -> String? {
        guard path.hasPrefix("/"), path.count > 1, (path as NSString).standardizingPath == path, !path.hasSuffix("/") else {
            return "is not a normalized absolute path"
        }
        func overlaps(_ a: String, _ b: String) -> Bool { a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") }
        for shadowed in ["/tmp", "/var", "/etc", "/private", "/System", "/dev"] where overlaps(path, shadowed) {
            return "overlaps the guest's \(shadowed)"
        }
        if overlaps(path, runtimeRoot) { return "overlaps the runtime root" }
        for job in jobPaths where !(job == dev || job.hasPrefix(dev + "/")) && overlaps(path, job) {
            return "overlaps the job path \(job)"
        }
        return nil
    }

    /// The first device path in `bytes` that stands in front of
    /// `/data/Containers/` and is not `current` (with `current` empty: the
    /// first one). A path is the run of printable ASCII before the marker,
    /// from its first `/`.
    static func foreignDevicePath(in bytes: Data, current: String) -> String? {
        let marker = Array("/data/Containers/".utf8)
        return bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            guard let base = raw.baseAddress, raw.count >= marker.count else { return nil }
            let b = raw.bindMemory(to: UInt8.self)
            var offset = 0
            let last = raw.count - marker.count
            while offset <= last {
                // memchr to the next "/", then a compare (the stores are megabytes).
                guard let hit = memchr(base + offset, Int32(marker[0]), last - offset + 1) else { return nil }
                let i = base.distance(to: UnsafeRawPointer(hit))
                guard marker.withUnsafeBytes({ memcmp(base + i, $0.baseAddress!, marker.count) }) == 0 else {
                    offset = i + 1
                    continue
                }
                var start = i
                while start > 0, (0x20...0x7E).contains(b[start - 1]) { start -= 1 }
                if let slash = (start..<i).first(where: { b[$0] == UInt8(ascii: "/") }) {
                    let prefix = String(decoding: UnsafeBufferPointer(rebasing: b[slash..<i]), as: UTF8.self)
                    if prefix != current { return prefix }
                }
                offset = i + marker.count
            }
            return nil
        }
    }

    /// Before a cold boot (after `guestDev` was resolved): removes the
    /// LaunchServices store files that name a device path other than the
    /// guest path (lsd seeds a new store at this boot; a store that names
    /// no device path, as the system-only one, stays), says so, and
    /// records the guest path.
    func handleRelocation() throws {
        let fm = FileManager.default
        if guestDev != dev {
            FileHandle.standardError.write(Data("ycode-simd: device data keeps its guest path \(guestDev) (copied or moved from there)\n".utf8))
        }
        // Every cold boot checks the stores (two files of a few MB, read
        // from the page cache: milliseconds).
        var stale: [(file: String, names: String)] = []
        for file in launchServicesStoreFiles() {
            guard let bytes = fm.contents(atPath: file) else { continue }
            if let other = Self.foreignDevicePath(in: bytes, current: guestDev) { stale.append((file, other)) }
        }
        for entry in stale { try fm.removeItem(atPath: entry.file) }
        if let first = stale.first {
            FileHandle.standardError.write(Data(("ycode-simd: the LaunchServices store names \(first.names), not the device's guest path "
                + "\(guestDev): removed (\(stale.count) files), lsd rebuilds it at this boot\n").utf8))
        }
        if fm.fileExists(atPath: data) {
            try Data((guestDev + "\n").utf8).write(to: URL(fileURLWithPath: devicePathRecordPath), options: .atomic)
        }
    }
}
