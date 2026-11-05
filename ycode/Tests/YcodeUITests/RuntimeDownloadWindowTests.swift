import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// B2-DOWNLOAD (#55): Get a Runtime in the macOS window. Route C runs a
/// stand-in `xcodebuild` that prints download progress (nothing is installed
/// into CoreSimulator or /Library/Developer); route B runs against stand-ins
/// for Apple's index, asset service and CDN. With `YCODE_RUNTIME_SHOTS=<dir>`
/// every state is photographed as `mac-download-*.png`.
@MainActor
@Suite(.serialized) struct RuntimeDownloadWindowTests {
    struct Runner: HeadsetCommandRunner {
        func run(_ command: String) async -> HeadsetCommandResult {
            if command.contains("xcode-select -p") { return HeadsetCommandResult(status: 0, output: "/Applications/Xcode.app/Contents/Developer\n") }
            if command.contains("xcrun --find simctl") { return HeadsetCommandResult(status: 0, output: "/x/simctl") }
            if command.contains("simctl runtime list -j") { return HeadsetCommandResult(status: 0, output: "{}") }
            if command.contains("simctl list runtimes -j") { return HeadsetCommandResult(status: 0, output: "{\"runtimes\":[]}") }
            if command.contains("df -Pk") { return HeadsetCommandResult(status: 0, output: "209715200") }
            return HeadsetCommandResult(status: 1)
        }
    }

    /// Apple's index (made up) and a slow, sparse "download".
    final class Transport: RuntimeTransport, @unchecked Sendable {
        let index: Data = {
            func e(_ v: String, _ b: String, beta: Int = 0) -> [String: Any] {
                ["category": "simulator", "platform": "com.apple.platform.appletvos", "identifier": b, "name": "tvOS \(v)", "version": "\(v).0.\(beta)",
                 "contentType": "cryptexDiskImage", "downloadMethod": "mobileAsset", "architectures": ["arm64"],
                 "simulatorVersion": ["version": v, "buildUpdate": b], "fileSize": 3_758_096_384]
            }
            return try! PropertyListSerialization.data(fromPropertyList: ["refreshInterval": 86400, "downloadables": [e("27.2", "24K150"), e("27.3", "24K5286g", beta: 1), e("27.0", "24J360")]],
                                                       format: .xml, options: 0)
        }()
        func get(_ url: URL, etag: String?) async throws -> RuntimeHTTPResponse { RuntimeHTTPResponse(status: 200, body: index) }
        func post(_ url: URL, json: Data, headers: [String: String], caFile: String?) async throws -> RuntimeHTTPResponse { RuntimeHTTPResponse(status: 403, body: Data()) }
        func download(_ url: URL, to file: String, from offset: Int64, cancel: RuntimeCancellation) async throws {
            let h = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
            defer { try? h.close() }
            var at = offset
            while at < 3_758_096_384 {
                if cancel.isCancelled { throw RuntimeDownloadError.cancelled }
                at = min(3_758_096_384, at + 64 << 20)
                try h.truncate(atOffset: UInt64(at))
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    nonisolated static let shots = ProcessInfo.processInfo.environment["YCODE_RUNTIME_SHOTS"]

    static func standIn(_ dir: URL, _ body: String) throws -> String {
        let p = dir.appendingPathComponent("xcodebuild-\(UUID().uuidString.prefix(6))").path
        try ("#!/bin/sh\ntrap 'echo; echo \"** CANCELLED **\"; exit 130' INT\n" + body).write(toFile: p, atomically: true, encoding: .utf8)
        chmod(p, 0o755)
        return p
    }

    /// Progress as the stand-in prints it, every 50 ms (the real wording is
    /// to be confirmed, `runtime-onboarding.md` §6.1; the reader takes any).
    static let progressScript = """
        echo "Downloading tvOS 27.2 Simulator (24K150)"
        i=0
        while [ $i -le 100 ]; do
          mb=$((i * 3584 / 100))
          printf 'Downloading tvOS 27.2 Simulator (24K150): %d%% (%d MB of 3584 MB)\\r' $i $mb
          sleep 0.05
          i=$((i + 2))
        done
        echo
        echo "Installing tvOS 27.2 Simulator (24K150)…"
        sleep 0.3
        echo "Done."
        """

    func shot(_ wc: RuntimeSetupWindowController, _ name: String) throws {
        guard let dir = Self.shots else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let win = try #require(wc.window)
        win.contentView?.layoutSubtreeIfNeeded()
        let frame = try #require(win.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        frame.display()
        let rep = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent("mac-download-\(name).png"))
    }

    func shot(alert c: RuntimeConfirmation, _ name: String) throws {
        guard let dir = Self.shots else { return }
        let a = RuntimeSetupWindowController.alert(for: c)
        a.layout()
        let v = try #require(a.window.contentView)
        let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
        v.cacheDisplay(in: v.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent("mac-download-\(name).png"))
    }

    func until(_ limit: Double = 30, _ done: () -> Bool) async {
        let start = Date()
        while !done() && Date().timeIntervalSince(start) < limit { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    @Test func getARuntimeOnAMac() async throws {
        _ = NSApplication.shared
        let td = TestDefaults("runtime-download-wizard")
        defer { td.remove() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-dl-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = RuntimeSetupSession(machine: SetupMachine(isMac: true, architecture: "arm64"), defaults: td.defaults, folder: dir.appendingPathComponent("rt").path,
                                    localRunner: Runner())
        s.setPlatform(.tvOS, on: true)
        let ok = try Self.standIn(dir, Self.progressScript)
        s.downloads.environment = ["YCODE_XCODEBUILD": ok, "PATH": "/usr/bin:/bin"]
        let transport = Transport()
        let installed = LockedFlag()
        s.downloads.makeDirect = { folder in
            let d = RuntimeDirectDownload(folder: folder, transport: transport, expander: SystemAppleArchiveExpander(), reader: HdiutilImageReader(),
                                          host: RuntimeHostDescription(isMac: true, productName: "macOS", productVersion: "27.2", buildVersion: "26B1",
                                                                       architecture: "arm64", macModel: "Mac15,10", client: "Ycode/1.0.0-beta.2"))
            d.query = { type, build in
                if installed.value { throw RuntimeDownloadError.refused("HTTP 403 (stand-in)") }
                return RuntimeAssetRecord(assetType: type, build: build, downloadSize: 3_758_096_384, unarchivedSize: nil, sha256: [UInt8](repeating: 0xAB, count: 32),
                                          url: URL(string: "https://cdn.example.invalid/stand-in.aar")!, key: RuntimeArchiveKey(bytes: [UInt8](repeating: 9, count: 32)))
            }
            return d
        }
        let wc = RuntimeSetupWindowController(session: s)
        var shown: RuntimeConfirmation?
        wc.answerConfirmation = { shown = $0; return nil }
        defer { wc.window?.close() }
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.window?.setContentSize(NSSize(width: 860, height: 640))
        await s.recheck().value
        s.show(.download)
        s.downloads.setPlatform(.tvOS)
        await until { !s.downloads.checks.isEmpty }
        let root = try #require(wc.window?.contentView)
        #expect(s.downloads.xcodeAvailable)
        #expect(RuntimeSetupWindowTests.find("runtime-download-xcode", in: root) != nil)
        // Route C comes first on a Mac, then route B, then route A.
        let texts = RuntimeSetupWindowTests.texts(root)
        let c = try #require(texts.firstIndex(of: "With Xcode (recommended on a Mac)")), b = try #require(texts.firstIndex(of: "Downloaded by Ycode")),
            a = try #require(texts.firstIndex(of: "A runtime you have"))
        #expect(c < b && b < a)
        try shot(wc, "01-step")

        // Route C: the exact command, then progress, then done.
        s.downloads.setExportCopy(true)
        s.downloads.setExportPath("/tmp/Ycode Runtimes")
        wc.xcodeDownloadClicked()
        let confirm = try #require(shown)
        #expect(confirm.command == "xcodebuild -downloadPlatform tvOS -exportPath '/tmp/Ycode Runtimes'")
        try shot(wc, "02-xcode-export")
        try shot(alert: confirm, "03-xcode-confirm")
        wc.answerConfirmation = { shown = $0; return nil }
        s.confirm()
        await until { (s.downloads.activity?.fraction ?? 0) > 0.4 }
        #expect(s.downloads.activity?.isRunning == true)
        #expect(s.downloads.activity?.phase.contains("MB of") == true || s.downloads.activity?.phase.contains("GB") == true)
        try shot(wc, "04-xcode-progress")
        await until { s.downloads.activity?.isRunning == false }
        guard case .finished? = s.downloads.activity?.state else { Issue.record("route C: \(String(describing: s.downloads.activity))"); return }
        #expect(s.downloads.log.contains("-downloadPlatform") && s.downloads.log.contains("Done."))
        try shot(wc, "05-xcode-done")

        // Cancel: an interrupt, as ⌃C (a slow stand-in, so the cancel lands mid-download even on a busy machine).
        s.downloads.setExportCopy(false)
        s.downloads.environment["YCODE_XCODEBUILD"] = try Self.standIn(dir, Self.progressScript.replacingOccurrences(of: "sleep 0.05", with: "sleep 0.5"))
        s.request(try #require(s.downloads.xcodeAction))
        s.confirm()
        await until { (s.downloads.activity?.fraction ?? 0) > 0.05 }
        wc.cancelDownloadClicked()
        await until { s.downloads.activity?.isRunning == false }
        #expect(s.downloads.activity?.state == .cancelled)
        try shot(wc, "06-xcode-cancelled")

        // A failure: its last lines, and Retry.
        s.downloads.environment["YCODE_XCODEBUILD"] = try Self.standIn(dir, "echo 'Downloading tvOS 27.2 Simulator (24K150): 3%'\necho 'xcodebuild: error: The network connection was lost.' >&2\nexit 70\n")
        s.request(try #require(s.downloads.xcodeAction))
        s.confirm()
        await until { s.downloads.activity?.isRunning == false }
        guard case .failed(let words, let retry, _)? = s.downloads.activity?.state else { Issue.record("expected a failure"); return }
        #expect(words.contains("status 70") && words.contains("network connection was lost") && retry)
        #expect(RuntimeSetupWindowTests.find("runtime-download-retry", in: root) != nil)
        try shot(wc, "07-xcode-failed")

        // Route B: the versions, the confirmation (honest host line), progress, Cancel and Resume, a checksum failure.
        wc.showVersionsClicked()
        await until { s.downloads.indexState == .loaded }
        #expect(s.downloads.recommended?.build == "24K150")
        try shot(wc, "08-direct-versions")
        wc.directDownloadClicked()
        let direct = try #require(shown)
        #expect(direct.command == "ycode runtime download tvOS --build 24K150")
        #expect(direct.message.contains("Mac15,10") && direct.message.contains("SHA-256"))
        try shot(alert: direct, "09-direct-confirm")
        s.confirm()
        await until { (s.downloads.activity?.fraction ?? 0) > 0.3 }
        try shot(wc, "10-direct-downloading")
        wc.cancelDownloadClicked()
        await until { s.downloads.activity?.isRunning == false }
        #expect(s.downloads.activity?.state == .cancelled)
        try shot(wc, "11-direct-cancelled")
        wc.retryDownloadClicked()
        await until(120) { s.downloads.activity?.isRunning == false }
        guard case .failed(let why, _, _)? = s.downloads.activity?.state else { Issue.record("expected the checksum to fail"); return }
        #expect(why.contains("checksum"))
        try shot(wc, "12-direct-checksum")
        // The service refuses: the other routes are offered.
        installed.value = true
        s.request(try #require(s.downloads.directAction))
        s.confirm()
        await until { s.downloads.activity?.isRunning == false }
        guard case .failed(_, false, true)? = s.downloads.activity?.state else { Issue.record("expected a refusal"); return }
        #expect(RuntimeSetupWindowTests.find("runtime-download-refused-xcode", in: root) != nil)
        try shot(wc, "13-direct-refused")
        wc.window?.appearance = NSAppearance(named: .darkAqua)
        try shot(wc, "13-direct-refused-dark")
        // No key in anything shown.
        #expect(!s.downloads.log.contains(Data([UInt8](repeating: 9, count: 32)).base64EncodedString()))
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}
