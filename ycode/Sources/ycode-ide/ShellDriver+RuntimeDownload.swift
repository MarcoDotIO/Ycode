import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_DOWNLOAD_WALK=<prefix>: Get a Runtime (#55) in Window ▸
// Downloads, every state photographed as <prefix>-download-<n>-<state>.png:
// the step, Apple's versions (the real index), the decryptor not set up and
// its confirmation, route B's confirmation, a download in progress, Cancel
// and Resume, a checksum failure, the asset service refusing this computer,
// and the Runtimes step with what route B installed. The download states
// use a stand-in for Apple's asset service and CDN (the file grows sparsely
// and fails its checksum), so the walk fetches nothing but the index.
extension ShellDriver {
    #if os(Linux)
    static func downloadWalk(_ app: ShellAppModel, prefix: String) async {
        func shot(_ name: String) async {
            await pause(0.9)
            let d = app.runtimeSetup?.downloads
            say("download \(name): activity=\(d.map { "\($0.activity?.phase ?? "-") \($0.activity.map { "\($0.state)" } ?? "")" } ?? "-") "
                + "checks=\(d?.checks.map { "\($0.id)=\($0.state.rawValue)" } ?? []) "
                + OpenViewsAutomation.screenshot(to: "\(prefix)-download-\(name).png"))
        }
        func until(_ limit: Double = 60, _ done: () -> Bool) async {
            var t = 0.0
            while !done() && t < limit { await pause(0.2); t += 0.2 }
        }
        let domain = "ycode-ide-download-walk"
        UserDefaults.standard.removePersistentDomain(forName: domain)
        app.runtimeDefaults = UserDefaults(suiteName: domain) ?? .standard
        app.showRuntimeSetup(step: .target)
        guard let s = app.runtimeSetup else { say("download: no wizard"); return }
        s.setPlatform(.tvOS, on: true)
        s.setPlatform(.watchOS, on: true)
        await until { !s.isChecking }
        s.show(.download)
        s.downloads.setPlatform(.watchOS)
        await until { !s.downloads.checks.isEmpty }
        await shot("01-step")
        s.downloads.loadIndex()
        await until { s.downloads.indexState != .loading }
        await shot("02-versions")
        // The decryptor in a folder that has none.
        let realFolder = s.downloads.folder
        let empty = NSTemporaryDirectory() + "ycode-download-walk-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        s.downloads.folder = empty
        await s.downloads.checkPrerequisites()
        await shot("03-decryptor-missing")
        if case .action(let a)? = s.downloads.checks.first(where: { $0.id == "download.decryptor" })?.fix {
            s.request(a)
            await shot("04-decryptor-confirm")
            s.cancelConfirmation()
        }
        s.downloads.folder = realFolder
        await s.downloads.checkPrerequisites()
        // Route B against a stand-in for Apple: a sparse file that fails its checksum.
        let work = empty + "/work"
        s.downloads.makeDirect = { _ in
            let d = RuntimeDirectDownload(folder: work, transport: WalkTransport(), expander: nil, reader: nil)
            d.query = { type, build in
                RuntimeAssetRecord(assetType: type, build: build, downloadSize: 3_758_096_384, unarchivedSize: 3_800_000_000,
                                   sha256: [UInt8](repeating: 0xAB, count: 32), url: URL(string: "https://cdn.example.invalid/stand-in.aar")!,
                                   key: RuntimeArchiveKey(bytes: (0..<32).map { _ in UInt8.random(in: 0...255) }))
            }
            return d
        }
        guard let direct = s.downloads.directAction else { say("download: no route B action (index: \(s.downloads.indexState))"); return }
        s.request(direct)
        await shot("05-direct-confirm")
        s.confirm()
        await until(20) { (s.downloads.activity?.fraction ?? 0) > 0.3 }
        await shot("06-downloading")
        s.downloads.cancel()
        await until { s.downloads.activity?.isRunning == false }
        await shot("07-cancelled")
        s.downloads.retry()
        await until(120) { s.downloads.activity?.isRunning == false }
        await shot("08-checksum-failed")
        // The asset service refuses this computer.
        s.downloads.makeDirect = { _ in
            let d = RuntimeDirectDownload(folder: work, transport: WalkTransport(), expander: nil, reader: nil)
            d.query = { _, _ in throw RuntimeDownloadError.refused("HTTP 403 (stand-in)") }
            return d
        }
        s.request(direct)
        s.confirm()
        await until { s.downloads.activity?.isRunning == false }
        await shot("09-refused")
        try? FileManager.default.removeItem(atPath: empty)
        s.show(.runtimes)
        await until { !s.isChecking }
        await shot("10-runtimes")
        s.show(.finish)
        await shot("11-finish")
        app.closeRuntimeSetup()
        await pause(0.5)
        OpenViewsAutomation.terminate()
    }
    #endif
}

/// The walk's stand-in for Apple: the index from the real cache (or Apple),
/// and a "download" that grows the file sparsely, ~300 MB a second.
struct WalkTransport: RuntimeTransport {
    let real = CurlTransport()
    func get(_ url: URL, etag: String?) async throws -> RuntimeHTTPResponse { try await real.get(url, etag: etag) }
    func post(_ url: URL, json: Data, headers: [String: String], caFile: String?) async throws -> RuntimeHTTPResponse {
        RuntimeHTTPResponse(status: 403, body: Data())
    }
    func download(_ url: URL, to file: String, from offset: Int64, cancel: RuntimeCancellation) async throws {
        let total: Int64 = 3_758_096_384
        var at = offset
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
        defer { try? h.close() }
        while at < total {
            if cancel.isCancelled { throw RuntimeDownloadError.cancelled }
            at = min(total, at + 32 << 20)
            try h.truncate(atOffset: UInt64(at))
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
