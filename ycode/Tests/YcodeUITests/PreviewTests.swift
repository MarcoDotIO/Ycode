import AppKit
import Foundation
import Testing
import YcodeDebug
@testable import YcodeIDECore
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

let previewSource = """
import SwiftUI

struct Badge: View {
    var text: String
    var body: some View {
        Text(text)
            .padding(12)
            .background(Color.blue)
            .foregroundStyle(.white)
    }
}

// #Preview in a comment is not a preview.
#Preview("Small", traits: .fixedLayout(width: 120, height: 60)) {
    Badge(text: "Hi")
}

#Preview {
    VStack {
        Badge(text: "One { } \\"two\\"")
        Badge(text: "Three")
    }
    .frame(width: 200, height: 140)
    .background(Color.yellow)
}

struct Badge_Previews: PreviewProvider {
    static var previews: some View { Badge(text: "Provider").frame(width: 150, height: 50) }
}
"""

/// Counts pixels that differ from the first pixel (a blank image has none).
func nonBlankPixels(_ png: URL) throws -> Int {
    let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: png)))
    let first = rep.colorAt(x: 0, y: 0)
    var n = 0
    for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) where rep.colorAt(x: x, y: y) != first { n += 1 }
    }
    return n
}

/// The time limit covers the wait for the machine-wide debugger-test lock,
/// which other test runs may hold for many minutes.
@MainActor
@Suite(.serialized, .heavyIntegration, .previewHostCheck, .timeLimit(.minutes(30))) struct PreviewTests {
    @Test func discovery() {
        let p = PreviewDiscovery.previews(in: previewSource)
        #expect(p.map(\.name) == ["Small", "Preview", "Badge_Previews"])
        #expect(p[0].fixedSize == CGSize(width: 120, height: 60) && p[1].fixedSize == nil)
        #expect(p[0].line == 14 && p[1].line == 18)
        if case .macro(let body) = p[1].kind { #expect(body.contains("Badge(text: \"Three\")") && body.contains(".background(Color.yellow)")) } else { Issue.record("kind") }
        #expect(p[2].kind == .provider(type: "Badge_Previews"))
        let blank = PreviewDiscovery.blankingPreviews(previewSource)
        #expect(!blank.contains("#Preview(") && blank.contains("struct Badge_Previews") && blank.count == previewSource.count)
    }

    func makePackage(_ name: String, source: String) throws -> URL {
        let dir = ycodeDir.appendingPathComponent(".build-ide/previews/\(name)")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/Views"), withIntermediateDirectories: true)
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Views", platforms: [.macOS(.v14)], products: [.library(name: "Views", targets: ["Views"])],
                              targets: [.target(name: "Views")])

        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try source.write(to: dir.appendingPathComponent("Sources/Views/Badge.swift"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func rendersPreviewsToPNGs() async throws {
        // Heavy work (builds, debugger, language server) takes turns across test processes.
        let heavy = await InterprocessLock.acquire(path: InterprocessLock.debuggerTestLockPath)
        defer { heavy.unlock() }
        let pkg = try makePackage("ok", source: previewSource)
        let file = pkg.appendingPathComponent("Sources/Views/Badge.swift")
        let module = try PreviewRenderer.packageModule(for: file, packageDirectory: pkg)
        #expect(module.name == "Views" && module.sources.count == 1)
        let renderer = PreviewRenderer(workDirectory: ycodeDir.appendingPathComponent(".build-ide/previews/work"))
        let out = try await offMain { try renderer.render(module: module, file: file, previews: PreviewDiscovery.previews(in: previewSource)) }
        #expect(out.map(\.name) == ["Small", "Preview", "Badge_Previews"])
        for r in out { #expect(try nonBlankPixels(r.png) > 50, "\(r.name)") }
        let small = try #require(NSBitmapImageRep(data: try Data(contentsOf: out[0].png)))
        #expect(small.size == NSSize(width: 120, height: 60))
    }

    @Test func canvasInTheWindow() async throws {
        // Heavy work (builds, debugger, language server) takes turns across test processes.
        let heavy = await InterprocessLock.acquire(path: InterprocessLock.debuggerTestLockPath)
        defer { heavy.unlock() }
        _ = NSApplication.shared
        let pkg = try makePackage("canvas", source: previewSource)
        let file = pkg.appendingPathComponent("Sources/Views/Badge.swift")
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: pkg)), loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        wc.previewWorkDirectory = ycodeDir.appendingPathComponent(".build-ide/previews/work-canvas")
        // The canvas's Mac preview host ends with the test (also on a failure).
        defer { PreviewRenderer.stopMacHosts() }
        wc.canvasRefreshDelay = 0.1
        wc.open(path: file.path, line: nil)
        // Shown by itself for a file with previews (reference-ui-6.md §4.4).
        let canvas = try #require(wc.canvas)
        #expect(wc.canvasShownAutomatically)
        // Paused until resumed (reference-ui-4.md §10), then building.
        #expect(canvas.isPaused && canvas.names == ["Small", "Preview", "Badge_Previews"])
        #expect(canvas.tabTitles == ["Small", "VStack", "Badge_Previews"])
        canvas.resume()
        #expect(canvas.state == .building && canvas.headerTabs.map(\.badge) == ["spinner", "spinner", "spinner"])
        await wc.previewTask?.value
        guard case .rendered(let list) = canvas.state else { Issue.record("not rendered: \(canvas.state)"); return }
        #expect(list.count == 6 && list.filter { $0.scheme == .dark }.count == 3)
        #expect(canvas.layout == .single && canvas.framedCount == 1 && canvas.headerTabs.allSatisfy { $0.badge == "eye" })
        // All previews at once, as cards.
        canvas.setMode(.grid)
        #expect(canvas.layout == .grid && canvas.cardTitles == ["Small", "Preview", "Badge_Previews"])
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "preview-canvas-grid.png")
        // Zoom into one; dark variant.
        canvas.select(1, zoom: true)
        #expect(canvas.layout == .single && canvas.cardTitles == ["Preview"])
        canvas.setColorScheme(.dark)
        #expect(canvas.shown.allSatisfy { $0.scheme == .dark })
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "preview-canvas.png")
        canvas.setColorScheme(.light)

        // A save with a broken view refreshes (debounced) into an error card.
        let tv = wc.editor.textView
        let r = (tv.string as NSString).range(of: "Text(text)")
        tv.insertText("Text(nope)", replacementRange: r)
        try wc.editor.save()
        await wc.pendingCanvasRefresh?.value
        await wc.previewTask?.value
        guard case .failed(let message) = canvas.state else { Issue.record("not failed: \(canvas.state)"); return }
        #expect(message.hasPrefix("Badge.swift:6:") && message.contains("nope"))
        #expect(canvas.statusText == "Build failed")
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "preview-canvas-error.png")
        wc.toggleCanvas(nil)
        #expect(wc.canvas == nil && wc.editorArea.canvas == nil)
    }

    @Test func buildErrorsAndUnsupportedTargets() async throws {
        // Heavy work (builds, debugger, language server) takes turns across test processes.
        let heavy = await InterprocessLock.acquire(path: InterprocessLock.debuggerTestLockPath)
        defer { heavy.unlock() }
        let broken = previewSource.replacingOccurrences(of: "Text(text)", with: "Text(missingName)")
        let pkg = try makePackage("broken", source: broken)
        let file = pkg.appendingPathComponent("Sources/Views/Badge.swift")
        let renderer = PreviewRenderer(workDirectory: ycodeDir.appendingPathComponent(".build-ide/previews/work-broken"))
        do {
            _ = try renderer.render(module: try PreviewRenderer.packageModule(for: file, packageDirectory: pkg), file: file,
                                    previews: PreviewDiscovery.previews(in: broken))
            Issue.record("expected a build error")
        } catch {
            #expect(error.description.hasPrefix("Badge.swift:6:") && error.description.contains("missingName"))
        }
        #expect(throws: PreviewRenderer.Failure.self) {
            try PreviewRenderer.packageModule(for: pkg.appendingPathComponent("Package.swift"), packageDirectory: pkg)
        }
    }
}

/// macOS previews through a payload loaded into the long-lived Mac host
/// (specs/ide/previews.md §The macOS host): same PNGs as the SwiftPM host,
/// and an edit costs one payload compile.
/// The time limit covers the wait for the machine-wide debugger-test lock,
/// which other test runs may hold for many minutes.
@MainActor
@Suite(.serialized, .heavyIntegration, .previewHostCheck, .timeLimit(.minutes(30))) struct MacPayloadPreviewTests {
    @Test func rendersThroughPayloadsAndRefreshesFast() async throws {
        let heavy = await InterprocessLock.acquire(path: InterprocessLock.debuggerTestLockPath)
        defer { heavy.unlock() }
        // Every host this test starts ends with it, whatever happens; no
        // request waits longer than a minute.
        MacPreviewHostProcess.requestTimeout = 60
        defer {
            PreviewRenderer.stopMacHosts()
            MacPreviewHostProcess.requestTimeout = 120
        }
        let pkg = try PreviewTests().makePackage("payload", source: previewSource)
        let file = pkg.appendingPathComponent("Sources/Views/Badge.swift")
        let module = try PreviewRenderer.packageModule(for: file, packageDirectory: pkg)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-mac-payload-\(getpid())")
        let renderer = PreviewRenderer(workDirectory: work)
        let t1 = TimingBox(), t2 = TimingBox()
        let start = Date()
        let out = try await offMain {
            try renderer.renderWithPayload(module: module, file: file, previews: PreviewDiscovery.previews(in: previewSource), schemes: [.light, .dark]) { t1.append($0) }
        }
        let first = Date().timeIntervalSince(start)
        #expect(out.map(\.name) == ["Small", "Preview", "Badge_Previews", "Small", "Preview", "Badge_Previews"])
        for r in out { #expect(try nonBlankPixels(r.png) > 50, "\(r.name) \(r.scheme)") }
        let small = try #require(NSBitmapImageRep(data: try Data(contentsOf: out[0].png)))
        #expect(small.size == NSSize(width: 120, height: 60))
        // An edit of a body: one compile, the host stays.
        let edited = previewSource.replacingOccurrences(of: "Badge(text: \"Hi\")", with: "Badge(text: \"Hello there\")")
        try edited.write(to: file, atomically: true, encoding: .utf8)
        let s2 = Date()
        let out2 = try await offMain {
            try renderer.renderWithPayload(module: module, file: file, previews: PreviewDiscovery.previews(in: edited), schemes: [.light]) { t2.append($0) }
        }
        let refresh = Date().timeIntervalSince(s2)
        let wide = try #require(NSBitmapImageRep(data: try Data(contentsOf: out2[0].png)))
        #expect(wide.size == NSSize(width: 120, height: 60) && out2.count == 3)
        print(String(format: "mac payload previews: first %.2f s (compile+host build %.2f, render %.2f); refresh after an edit %.2f s (compile %.2f, render %.2f)",
                     first, t1.values.first?.build ?? -1, t1.values.first?.run ?? -1, refresh, t2.values.first?.build ?? -1, t2.values.first?.run ?? -1))
        // A compile error maps to the user's file and line.
        let broken = previewSource.replacingOccurrences(of: "Badge(text: \"Hi\")", with: "Badge(text: nope)")
        try broken.write(to: file, atomically: true, encoding: .utf8)
        do {
            _ = try await offMain { try renderer.renderWithPayload(module: module, file: file, previews: PreviewDiscovery.previews(in: broken)) }
            Issue.record("expected a build failure")
        } catch let e as PreviewRenderer.Failure {
            #expect(e.description.hasPrefix("Badge.swift:15: cannot find 'nope' in scope"), "\(e.description)")
        }
        PreviewRenderer.stopMacHosts()
        #expect(PreviewRenderer.macHostPIDs.isEmpty)
        #expect(ProcessAudit.leftovers(grace: 5) { $0.name.hasPrefix("YcodePreviewMac") }.isEmpty)
        try? FileManager.default.removeItem(at: work)
    }
}

/// The Mac preview host never outlives its parent and no wait on it is
/// unbounded (specs/ide/previews.md §The macOS host).
@MainActor
@Suite(.serialized, .heavyIntegration, .previewHostCheck, .timeLimit(.minutes(10))) struct MacPreviewHostLifetimeTests {
    nonisolated func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-fake-host-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    /// `body`'s result and how long it took, in seconds.
    nonisolated static func timed<T>(_ body: () -> T) -> (T, TimeInterval) {
        let started = Date()
        let r = body()
        return (r, Date().timeIntervalSince(started))
    }

    nonisolated static let request = PreviewMacHost.Request(generation: 1, payload: "/nonexistent", output: "/tmp", schemes: ["light"], items: [])

    /// Nonisolated: nothing here needs the main actor, and in a full run
    /// each hop to it can wait behind other suites' synchronous main-actor
    /// work (one such hop waited past this test's time limit).
    @Test(.timeLimit(.minutes(2))) nonisolated func aHungHostIsKilledAfterTheRequestTimeout() async throws {
        // A host that reads nothing, never answers, and ignores SIGTERM.
        let exe = try script("trap '' TERM\nwhile :; do sleep 1; done")
        defer { try? FileManager.default.removeItem(at: exe) }
        let h = try MacPreviewHostProcess(executable: exe)
        // This host's own timeout: other suites set the default for theirs.
        h.requestTimeout = 1.5
        defer { h.stop(grace: 0.2) }
        // Timed on the thread that sends: the code under test, not how soon a thread was free.
        let (r, took) = try await offMain { Self.timed { h.send(Self.request, newPayload: true) } }
        #expect(r == nil)
        // The timeout, then end of input, SIGTERM and SIGKILL, each with a short grace.
        #expect(took >= 1.5 && took < 10, "\(took)")
        #expect(!h.process.isRunning && h.process.terminationReason == .uncaughtSignal)
    }

    @Test(.timeLimit(.minutes(2))) func aHostThatClosedItsInputFailsTheRequestAtOnce() async throws {
        // Writing to it fails (EPIPE, no SIGPIPE for this process); it is stopped.
        // It says when its input is closed (a file next to it), so the request
        // never races the shell's start.
        let exe = try script("trap '' TERM\nexec 0</dev/null\ntouch \"$0.closed\"\nwhile :; do sleep 1; done")
        let marker = exe.path + ".closed"
        defer { try? FileManager.default.removeItem(at: exe); try? FileManager.default.removeItem(atPath: marker) }
        let h = try MacPreviewHostProcess(executable: exe)
        // This host's own timeout: other suites set the default for theirs.
        h.requestTimeout = 20
        defer { h.stop(grace: 0.2) }
        #expect(await waitUntil(30) { FileManager.default.fileExists(atPath: marker) })
        let (r, took) = try await offMain { Self.timed { h.send(Self.request, newPayload: true) } }
        #expect(r == nil && !h.process.isRunning)
        // Well before the request timeout: the write failed.
        #expect(took < 10, "\(took)")
    }

    @Test(.timeLimit(.minutes(2))) nonisolated func stoppingEndsAHostThatIgnoresSIGTERM() async throws {
        let exe = try script("trap '' TERM\nwhile :; do sleep 1; done")
        defer { try? FileManager.default.removeItem(at: exe) }
        let h = try MacPreviewHostProcess(executable: exe)
        let ((), took) = try await offMain { Self.timed { h.stop(grace: 0.5) } }
        #expect(!h.process.isRunning && took < 5, "\(took)")
    }

    @Test(.timeLimit(.minutes(5))) func theRealHostEndsWithItsInputAndWithItsParent() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-host-lifetime-\(getpid())")
        try? FileManager.default.removeItem(at: work)
        defer { try? FileManager.default.removeItem(at: work) }
        let exe = try await offMain { try PreviewMacHost.build(deploymentTarget: PreviewMacHost.deploymentTarget(sdkVersion: PreviewRenderer.macSDKVersion()), workDirectory: work) }
        // The process audit sees it under its full name.
        let h = try MacPreviewHostProcess(executable: exe)
        #expect(ProcessAudit.children().contains { $0.pid == h.pid && $0.name == PreviewMacHost.executableName })
        // End of input: the host ends by itself (an exit, not a signal).
        try await offMain { h.stop(grace: 10) }
        #expect(!h.process.isRunning && h.process.terminationReason == .exit)

        // Its parent goes away while its input stays open: it ends within a few seconds.
        let fifo = work.appendingPathComponent("in.fifo").path
        #expect(mkfifo(fifo, 0o600) == 0)
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The shell becomes `sleep` (same pid), the host's parent, until it is killed.
        sh.arguments = ["-c", "\"$0\" 3<>\"$1\" <\"$1\" >/dev/null 2>&1 & echo $!; exec sleep 60", exe.path, fifo]
        let pipe = Pipe()
        sh.standardOutput = pipe
        sh.standardInput = FileHandle.nullDevice
        try sh.run()
        defer { if sh.isRunning { sh.terminate() } }
        let reader = pipe.fileHandleForReading
        let first = try await offMain { () -> String in
            var text = ""
            while !text.contains("\n") {
                let d = reader.availableData
                if d.isEmpty { break }
                text += String(decoding: d, as: UTF8.self)
            }
            return text
        }
        let pid = pid_t(first.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        try #require(pid > 0)
        defer { if alive(pid) { kill(pid, SIGKILL) } }
        // Running, with the shell as its parent (it would have ended at once without one).
        try await Task.sleep(for: .seconds(2))
        #expect(alive(pid))
        sh.terminate()
        let gone = await waitUntil(10) { !alive(pid) }
        #expect(gone)
    }

    @Test(.timeLimit(.minutes(5))) func theCheckFailsATestThatLeavesAHostRunning() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-host-check-\(getpid())")
        try? FileManager.default.removeItem(at: work)
        defer { try? FileManager.default.removeItem(at: work) }
        let exe = try await offMain { try PreviewMacHost.build(deploymentTarget: PreviewMacHost.deploymentTarget(sdkVersion: PreviewRenderer.macSDKVersion()), workDirectory: work) }
        final class PidBox: @unchecked Sendable { var pid: pid_t = 0; var host: MacPreviewHostProcess? }
        let box = PidBox()
        let test = try #require(Test.current)
        // A test body that starts a host and leaves it running: the check
        // records an issue (expected here) and kills the host. The body keeps
        // the host object, as a real leak does: a host whose object is
        // released sees end of input and ends by itself.
        await withKnownIssue("the check reports the host the body left running") {
            try await PreviewHostCheckTrait().provideScope(for: test, testCase: Test.Case.current) {
                let host = try MacPreviewHostProcess(executable: exe)
                box.host = host
                box.pid = host.pid
            }
        }
        box.host = nil
        #expect(box.pid > 0)
        #expect(await waitUntil(10) { ProcessAudit.children().allSatisfy { $0.pid != box.pid } })
    }
}
