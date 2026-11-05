// Reading the runtime disk image (`runtime-downloads.md` §5.2, §6.2 step 4):
// a UDIF image (lzfse blocks) with one APFS partition. Ycode decision: an
// MIT-compatible reader, or a GPL/LGPL tool run as a separate program and
// never linked. On Linux that is 7-Zip (`7zz`/`7z`, LGPL-2.1), which reads
// UDIF and APFS; on macOS the system's `hdiutil` attaches the image
// read-only and unattached from Finder. Either way the result is a folder
// holding the volume's files. Portable.

import Foundation

public protocol RuntimeImageReader: Sendable {
    var title: String { get }
    /// Puts the image's volume at a folder under `work` and hands it to
    /// `body`; cleans up after (the copy, or the attachment).
    func withVolume<T: Sendable>(_ dmg: String, work: String, cancel: RuntimeCancellation, log: @escaping @Sendable (String) -> Void,
                                 _ body: @Sendable (String) async throws -> T) async throws -> T
}

/// 7-Zip as a separate program (Linux).
public struct SevenZipImageReader: RuntimeImageReader {
    public var tool: String
    public init(tool: String) { self.tool = tool }

    public var title: String { "7-Zip (\((tool as NSString).lastPathComponent), LGPL-2.1), run as a separate program" }

    /// `$YCODE_7Z`, else `7zz` or `7z` on the PATH.
    public static func find(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let t = environment["YCODE_7Z"], !t.isEmpty { return t }
        for name in ["7zz", "7z"] {
            for dir in (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":") {
                let p = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    public static let installHint = "Install 7-Zip 23 or later (it reads UDIF and APFS): sudo apt install 7zip, or your distribution's 7zip package."

    func run(_ args: [String], cancel: RuntimeCancellation, log: @escaping @Sendable (String) -> Void) async throws -> String {
        let p = SetupProcess([tool] + args)
        let token = cancel.onCancel { p.terminate() }
        defer { cancel.remove(token) }
        let status = await p.run()
        try cancel.check()
        guard status == 0 else {
            log(p.text)
            throw RuntimeDownloadError.image("7-Zip stopped (status \(status)): \(p.text.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " "))")
        }
        return p.text
    }

    /// The items of `7z l -slt`: path and size.
    static func items(_ listing: String) -> [(path: String, size: Int64)] {
        var out: [(String, Int64)] = []
        var path: String?
        for line in listing.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("Path = ") { path = String(line.dropFirst(7)) }
            if line.hasPrefix("Size = "), let p = path {
                out.append((p, Int64(line.dropFirst(7)) ?? 0))
                path = nil
            }
        }
        return out
    }

    /// A listing of partition images (a few top-level items, one of them
    /// APFS) names the APFS one; a listing of files gives nil.
    static func partitionItem(_ items: [(path: String, size: Int64)]) -> String? {
        guard items.count <= 8, !items.contains(where: { $0.path.contains("/") }) else { return nil }
        return items.first { $0.path.lowercased().contains("apfs") }?.path
    }

    public func withVolume<T: Sendable>(_ dmg: String, work: String, cancel: RuntimeCancellation, log: @escaping @Sendable (String) -> Void,
                                        _ body: @Sendable (String) async throws -> T) async throws -> T {
        let fm = FileManager.default
        let parts = work + "/partitions", volume = work + "/volume"
        try? fm.removeItem(atPath: parts)
        try? fm.removeItem(atPath: volume)
        defer { try? fm.removeItem(atPath: parts) }
        // 7-Zip opens the UDIF image and, inside it, the APFS volume, so its
        // listing is usually the volume's files: extract them directly. When
        // it lists partition images instead, take the APFS one, then its files.
        let listing = try await run(["l", "-slt", "-ba", dmg], cancel: cancel, log: log)
        let items = Self.items(listing)
        if let item = Self.partitionItem(items) {
            log("7-Zip: the APFS partition is \(item)")
            _ = try await run(["x", "-y", "-bd", "-o" + parts, dmg, item], cancel: cancel, log: log)
            let raw = parts + "/" + item
            _ = try await run(["x", "-y", "-bd", "-snld", "-o" + volume, raw], cancel: cancel, log: log)
            try? fm.removeItem(atPath: raw)
        } else {
            log("7-Zip: reading the volume's \(items.count) items")
            // -snld: symbolic links stay links, even ones that point outside.
            _ = try await run(["x", "-y", "-bd", "-snld", "-o" + volume, dmg], cancel: cancel, log: log)
        }
        return try await body(volume)
    }
}

/// `hdiutil attach -readonly` (macOS).
public struct HdiutilImageReader: RuntimeImageReader {
    public var hdiutil = "/usr/bin/hdiutil"
    public init() {}

    public var title: String { "hdiutil (macOS), attached read-only" }

    public func withVolume<T: Sendable>(_ dmg: String, work: String, cancel: RuntimeCancellation, log: @escaping @Sendable (String) -> Void,
                                        _ body: @Sendable (String) async throws -> T) async throws -> T {
        let mount = work + "/mount"
        try FileManager.default.createDirectory(atPath: mount, withIntermediateDirectories: true)
        let attach = SetupProcess([hdiutil, "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount, dmg])
        guard await attach.run() == 0 else { throw RuntimeDownloadError.image("hdiutil could not attach it: \(attach.text.trimmed)") }
        do {
            let r = try await body(mount)
            _ = await SetupProcess([hdiutil, "detach", mount]).run()
            return r
        } catch {
            _ = await SetupProcess([hdiutil, "detach", "-force", mount]).run()
            throw error
        }
    }
}

public enum RuntimeImageReaders {
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> (any RuntimeImageReader)? {
        #if os(macOS)
        if environment["YCODE_7Z"] == nil { return HdiutilImageReader() }
        #endif
        return SevenZipImageReader.find(environment: environment).map { SevenZipImageReader(tool: $0) }
    }
}
