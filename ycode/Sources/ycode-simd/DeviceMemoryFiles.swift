// The device's memory directory (specs/simulator/display-stream.md §4.1,
// frame-profile.md §7 item 1): files the guest rewrites on every frame or
// input event — the framebuffer library's frame record and, with
// YCODE_DISPLAY_TIMING=1, the swap and HID timing rings and the display
// server's trace — live on a memory file system instead of the device
// directory's volume, so a render thread's 96-byte `pwrite` never waits for
// a journal commit of that volume.
//
// The guest sees the directory at DEV/ycode-memory (a writable prefix of its
// own); the host directory behind it is chosen at every start, so a restored
// device reopens the frame record wherever the current setting puts it:
//
//   YCODE_FRAME_RECORD_MEMORY=0   DEV/data/tmp/ycode-memory (the data volume; the old behavior)
//   YCODE_MEMORY_DIR=<dir>        the memory file system to use (default /dev/shm)
//
// A snapshot (the warm-boot save) copies the directory's files to
// DEV/ycode-memory.saved while every guest thread is parked; a restore copies
// them back before any guest thread runs. A `.owner` file names the process
// using the directory; a start removes this user's directories whose owner
// has ended (killed runs, tests). While the device runs, each
// timing file has a symbolic link of the same name in DEV/data/tmp, where
// the analysis tools look for it (`ycode-display-probe --timing`); the run's
// end replaces the links with copies and removes the memory directory.

import Foundation

extension DeviceLayout {
    /// On by default; `YCODE_FRAME_RECORD_MEMORY=0` keeps the files on the data volume.
    static let memoryFilesEnabled: Bool = ProcessInfo.processInfo.environment["YCODE_FRAME_RECORD_MEMORY"] != "0"

    /// The guest path of the memory directory (a prefix of its own).
    var memoryGuestPath: String { guestDev + "/ycode-memory" }

    /// The memory file system the directories are made in (nil: none usable,
    /// or the switch is off).
    static var memoryBase: String? {
        guard memoryFilesEnabled else { return nil }
        let base = getenv("YCODE_MEMORY_DIR").map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 } ?? "/dev/shm"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base, isDirectory: &isDirectory), isDirectory.boolValue,
              access(base, W_OK) == 0 else { return nil }
        return base
    }

    /// The prefix of this user's directory names in `memoryBase`.
    static var memoryNamePrefix: String { "ycode-\(getuid())-" }

    /// The host directory behind `memoryGuestPath`.
    var memoryHostPath: String {
        guard let base = Self.memoryBase else { return data + "/tmp/ycode-memory" }
        // One directory per user and device directory (the UDID hashes DEV's path).
        return base + "/" + Self.memoryNamePrefix + Self.stableUDID(for: dev).replacingOccurrences(of: "-", with: "").prefix(16)
    }

    /// The file naming the process that uses a memory directory (never saved).
    static let memoryOwnerName = ".owner"

    /// Removes this user's memory directories whose owning process has ended
    /// without removing them (a run that was killed, a test): a directory
    /// whose `.owner` names no live process, or that has none and is more
    /// than a day old.
    static func sweepStaleMemoryDirectories(except keep: String) {
        guard let base = memoryBase else { return }
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where name.hasPrefix(memoryNamePrefix) {
            let dir = base + "/" + name
            guard dir != keep else { continue }
            if let text = fm.contents(atPath: dir + "/" + memoryOwnerName).map({ String(decoding: $0, as: UTF8.self) }),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                if kill(pid, 0) == 0 || errno == EPERM { continue }
            } else {
                let made = (try? fm.attributesOfItem(atPath: dir)[.modificationDate] as? Date) ?? Date()
                guard Date().timeIntervalSince(made) > 86_400 else { continue }
            }
            try? fm.removeItem(atPath: dir)
        }
    }

    /// Where a snapshot keeps the memory directory's files (on the data volume).
    var memorySavedPath: String { dev + "/ycode-memory.saved" }

    /// Host and guest path of a file in the memory directory.
    func memoryFile(_ name: String) -> (host: String, guest: String) {
        (memoryHostPath + "/" + name, memoryGuestPath + "/" + name)
    }

    /// The timing files (written only with YCODE_DISPLAY_TIMING=1).
    static let memoryTimingNames = ["ycode-framebuffer.timing", "ycode-simhid.timing", "ycode-display.trace"]

    /// Creates the memory directory. A cold boot starts it empty; a restore
    /// fills it from the snapshot's saved copy.
    func prepareMemoryDirectory() throws {
        let fm = FileManager.default
        let host = memoryHostPath
        Self.sweepStaleMemoryDirectories(except: host)
        try fm.createDirectory(atPath: host, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in (try? fm.contentsOfDirectory(atPath: host)) ?? [] { try? fm.removeItem(atPath: host + "/" + name) }
        if host != data + "/tmp/ycode-memory" {
            try? Data("\(getpid())\n".utf8).write(to: URL(fileURLWithPath: host + "/" + Self.memoryOwnerName))
            for name in Self.memoryTimingNames {
                let link = data + "/tmp/" + name
                try? fm.removeItem(atPath: link)
                if Self.displayTiming { try? fm.createSymbolicLink(atPath: link, withDestinationPath: host + "/" + name) }
            }
        }
        guard restoring else { return }
        for name in (try? fm.contentsOfDirectory(atPath: memorySavedPath)) ?? [] where name != Self.memoryOwnerName {
            try Self.copyKeepingTime(memorySavedPath + "/" + name, host + "/" + name)
        }
    }

    /// The snapshot's copy of the memory directory (call with the guest parked).
    func saveMemoryDirectory() {
        let fm = FileManager.default
        let saved = memorySavedPath, partial = saved + ".partial"
        try? fm.removeItem(atPath: partial)
        do {
            try fm.createDirectory(atPath: partial, withIntermediateDirectories: true)
            for name in try fm.contentsOfDirectory(atPath: memoryHostPath) where name != Self.memoryOwnerName {
                try Self.copyKeepingTime(memoryHostPath + "/" + name, partial + "/" + name)
            }
            try? fm.removeItem(atPath: saved)
            try fm.moveItem(atPath: partial, toPath: saved)
        } catch {
            FileHandle.standardError.write(Data("ycode-simd: warning: cannot save the memory directory: \(error)\n".utf8))
        }
    }

    /// The run's end: the timing files go to DEV/data/tmp; the memory
    /// directory is removed unless it is the data-volume fallback.
    func finishMemoryDirectory() {
        let fm = FileManager.default
        let host = memoryHostPath
        guard host != data + "/tmp/ycode-memory" else { return }
        for name in Self.memoryTimingNames where fm.fileExists(atPath: host + "/" + name) {
            try? fm.removeItem(atPath: data + "/tmp/" + name)
            try? fm.copyItem(atPath: host + "/" + name, toPath: data + "/tmp/" + name)
        }
        try? fm.removeItem(atPath: host)
    }

    /// Copies a file and its modification time (the restore compares it with the snapshot's).
    static func copyKeepingTime(_ from: String, _ to: String) throws {
        let fm = FileManager.default
        try fm.copyItem(atPath: from, toPath: to)
        if let date = try fm.attributesOfItem(atPath: from)[.modificationDate] as? Date {
            try? fm.setAttributes([.modificationDate: date], ofItemAtPath: to)
        }
    }
}
