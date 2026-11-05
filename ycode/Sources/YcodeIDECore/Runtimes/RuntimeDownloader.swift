// The payload download (`runtime-downloads.md` §4.3, §6.2 step 2): into
// `<runtimes>/.partial/`, resumed from what is there, then checked: length
// against `_DownloadSize`, SHA-256 against `_Measurement-SHA256`. A file that
// fails the check is removed. Portable.

import Crypto
import Foundation

public struct RuntimeDownloader: Sendable {
    public var transport: any RuntimeTransport
    /// Tries after a dropped connection before giving up (each resumes).
    public var attempts = 3

    public init(transport: any RuntimeTransport, attempts: Int = 3) {
        self.transport = transport
        self.attempts = attempts
    }

    public enum Event: Sendable, Equatable {
        case downloading(done: Int64, total: Int64)
        case resuming(from: Int64)
        case verifying(done: Int64, total: Int64)
    }

    public static func fileSize(_ path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Downloads (or resumes) `asset` into `file` and verifies it.
    public func fetch(_ asset: RuntimeAssetRecord, to file: String, cancel: RuntimeCancellation,
                      event: @escaping @Sendable (Event) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var have = Self.fileSize(file)
        if have > asset.downloadSize {
            try? fm.removeItem(atPath: file)
            have = 0
        }
        if !fm.fileExists(atPath: file) { fm.createFile(atPath: file, contents: nil) }
        var tries = 0
        while have < asset.downloadSize {
            try cancel.check()
            if have > 0 { event(.resuming(from: have)) }
            event(.downloading(done: have, total: asset.downloadSize))
            // Progress: the file's size, twice a second.
            let poll = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    event(.downloading(done: Self.fileSize(file), total: asset.downloadSize))
                }
            }
            defer { poll.cancel() }
            do {
                try await transport.download(asset.url, to: file, from: have, cancel: cancel)
            } catch let e as RuntimeDownloadError {
                // A dropped connection resumes, up to `attempts` times.
                tries += 1
                if e == .cancelled || tries >= attempts { throw e }
            }
            let now = Self.fileSize(file)
            if now < asset.downloadSize, now == have { tries += 1 }
            have = now
            event(.downloading(done: have, total: asset.downloadSize))
            if have < asset.downloadSize, tries >= attempts { break }
        }
        guard have == asset.downloadSize else {
            if have > asset.downloadSize { try? fm.removeItem(atPath: file) }
            throw RuntimeDownloadError.sizeMismatch(expected: asset.downloadSize, actual: have)
        }
        let digest = try Self.sha256(file, cancel: cancel) { done in event(.verifying(done: done, total: asset.downloadSize)) }
        guard digest == asset.sha256 else {
            try? fm.removeItem(atPath: file)
            throw RuntimeDownloadError.verificationFailed("SHA-256 \(RuntimeTrust.hex(digest).prefix(16))…, expected \(asset.sha256Hex.prefix(16))…")
        }
    }

    /// SHA-256 of a file, read in 8 MB pieces.
    public static func sha256(_ path: String, cancel: RuntimeCancellation? = nil, progress: ((Int64) -> Void)? = nil) throws -> [UInt8] {
        guard let h = FileHandle(forReadingAtPath: path) else { throw RuntimeDownloadError.verificationFailed("cannot read \(path)") }
        defer { try? h.close() }
        var hasher = SHA256()
        var done: Int64 = 0
        var last: Int64 = 0
        while true {
            if let cancel, cancel.isCancelled { throw RuntimeDownloadError.cancelled }
            let d = try h.read(upToCount: 8 << 20) ?? Data()
            if d.isEmpty { break }
            hasher.update(data: d)
            done += Int64(d.count)
            if done - last >= 64 << 20 { progress?(done); last = done }
        }
        progress?(done)
        return Array(hasher.finalize())
    }
}
