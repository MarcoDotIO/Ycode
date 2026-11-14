import AppKit
import Foundation
import Testing
import YcodeDebug
@testable import YcodeIDECore
import YcodeLanguage
@testable import YcodeUI

/// Council round 9, group C (`specs/ide/fidelity-council.md` rows 228–230)
/// in the macOS IDE: NOTES.md and palette.json in a Swift project get no
/// language-service diagnostic and no toolbar error count; the File
/// inspector reads "Default - Markdown" / "Default - JSON" and shows a
/// resource's Tags field and Localization section. The window stays off
/// every display.
@MainActor
@Suite(.serialized) struct CouncilRound9FileTypeUITests {
    /// A server like sourcekit-lsp in the owner's session: a Swift source
    /// gets no diagnostics; any other document it is told about gets a
    /// line-1 "Unable to handle compilation" error. It records the
    /// documents it is told about.
    final class CompilingServer: DAPTransport, @unchecked Sendable {
        static let message = "Unable to handle compilation, expected exactly one compiler job in ''"
        private let lock = NSLock()
        private var receiving: (@Sendable (Data?) -> Void)?
        private var decoder = DAPFraming.Decoder()
        private var seen: [String] = []
        var documents: [String] { lock.withLock { seen } }

        func start(receiving: @escaping @Sendable (Data?) -> Void) throws { lock.withLock { self.receiving = receiving } }

        func reply(_ msg: JSON) {
            let r = lock.withLock { receiving }
            r?(DAPFraming.frame(msg.encoded()))
        }

        func send(_ data: Data) {
            let bodies = lock.withLock { decoder.append(data) }
            for body in bodies {
                guard let msg = try? JSON.decode(body) else { continue }
                let method = msg["method"]?.string
                if method == "exit" { close(); continue }
                if let method, method.hasPrefix("textDocument/did"), let uri = msg["params"]?["textDocument"]?["uri"]?.string {
                    lock.withLock { seen.append(URL(string: uri)?.lastPathComponent ?? uri) }
                    if method == "textDocument/didOpen" || method == "textDocument/didChange" {
                        let range: JSON = ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]]
                        let error: JSON = ["range": range, "severity": 1, "message": .string(Self.message)]
                        reply(["jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": [
                            "uri": .string(uri), "diagnostics": uri.hasSuffix(".swift") ? [] : [error],
                        ]])
                    }
                }
                guard let id = msg["id"], method != nil else { continue }
                reply(["jsonrpc": "2.0", "id": id, "result": method == "initialize" ? ["capabilities": [:]] : .null])
            }
        }

        func close() {
            let r = lock.withLock { () -> (@Sendable (Data?) -> Void)? in
                defer { receiving = nil }
                return receiving
            }
            r?(nil)
        }
    }

    /// The council's GlassScroll project with NOTES.md and palette.json in
    /// its synchronized folder, in a 1400 × 880 window off every display.
    func councilWindow(_ tag: String) throws -> (WorkspaceWindowController, URL) {
        let fc = FidelityCouncilTests()
        let dir = try fc.project("r9-\(tag)")
        let src = dir.appendingPathComponent("GlassScroll")
        try "# Notes\n\nSome notes about the project.\n".write(to: src.appendingPathComponent("NOTES.md"), atomically: true, encoding: .utf8)
        try "{\n  \"accent\": \"#007AFF\",\n  \"background\": \"#FFFFFF\"\n}\n"
            .write(to: src.appendingPathComponent("palette.json"), atomically: true, encoding: .utf8)
        let wc = try fc.window(dir)
        if let w = wc.window { w.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: false) }
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        return (wc, dir)
    }

    func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }

    func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }

    /// A view's frame in window points from the window's top left.
    func frame(_ v: NSView, in w: NSWindow) -> (x: CGFloat, y: CGFloat, maxX: CGFloat, maxY: CGFloat) {
        let r = v.convert(v.bounds, to: nil)
        return (r.minX, w.frame.height - r.maxY, r.maxX, w.frame.height - r.minY)
    }

    // MARK: Row 228

    @Test func markdownAndJSONShowNoLanguageServiceErrorOrErrorCount() async throws {
        let (wc, dir) = try councilWindow("lsp")
        defer { wc.window?.close() }
        let server = CompilingServer()
        await wc.connectLanguageService(transport: server)
        #expect(wc.session.language != nil)
        let src = dir.appendingPathComponent("GlassScroll")
        // The window opened its first Swift file: the server answered it.
        #expect(await waitUntil(10) { !(wc.session.language?.liveDiagnostics.isEmpty ?? true) })
        #expect(wc.issueCapsule.errors == 0)
        for name in ["NOTES.md", "palette.json"] {
            wc.open(path: src.appendingPathComponent(name).path, line: nil)
            #expect(wc.editor.fileURL?.lastPathComponent == name)
            // Time for a server's answer to arrive and be shown.
            try await Task.sleep(for: .milliseconds(400))
            spin(0.05)
            #expect(wc.editor.textView.issues.isEmpty, "\(name): \(wc.editor.textView.issues)")
            #expect(wc.issueCapsule.errors == 0 && wc.issueCapsule.warnings == 0, "\(name)")
            #expect(!wc.session.displayedIssues.contains { $0.message.contains("Unable to handle compilation") }, "\(name)")
        }
        #expect(!server.documents.contains { !$0.hasSuffix(".swift") }, "\(server.documents)")

        // Long.swift goes to the server; NOTES.md shown again still has no
        // error, and the capsule stays empty.
        wc.open(path: src.appendingPathComponent("Long.swift").path, line: nil)
        #expect(await waitUntil(10) { server.documents.contains("Long.swift") })
        wc.open(path: src.appendingPathComponent("NOTES.md").path, line: nil)
        try await Task.sleep(for: .milliseconds(300))
        spin(0.05)
        #expect(wc.editor.textView.issues.isEmpty && wc.issueCapsule.errors == 0)
        #expect(!server.documents.contains { !$0.hasSuffix(".swift") }, "\(server.documents)")
        await wc.session.language?.stop()
    }

    // MARK: Rows 229, 230

    @Test func fileInspectorReadsTheTypeAndShowsAResourcesSections() throws {
        let (wc, dir) = try councilWindow("inspector")
        defer { wc.window?.close() }
        let w = try #require(wc.window)
        let src = dir.appendingPathComponent("GlassScroll")
        func typeTitle() -> String? { (wc.inspector.fileControls["Type"] as? NSPopUpButton)?.titleOfSelectedItem }
        func tags() -> NSTokenField? { wc.inspector.fileControls["On Demand Resource Tags"] as? NSTokenField }

        for (name, type) in [("NOTES.md", "Default - Markdown"), ("palette.json", "Default - JSON")] {
            wc.open(path: src.appendingPathComponent(name).path, line: nil)
            w.contentView?.layoutSubtreeIfNeeded()
            #expect(typeTitle() == type, "\(name)")
            #expect(wc.inspector.sectionTitles == ["Identity and Type", "On Demand Resource Tags", "Localization", "Target Membership", "Text Settings"],
                    "\(name): \(wc.inspector.sectionTitles)")
            #expect(tags()?.isEnabled == true && tags()?.placeholderAttributedString?.string == "Tags", "\(name)")
            #expect(wc.inspector.fileControls["Localize"] != nil, "\(name)")
        }

        // The rhythm of an image's Localization, straight after the tags:
        // the field's box 22 below the header's ink, the rule 12 below the
        // box, the header 8.5 below the rule, the button 28 below its ink,
        // 16 tall and as wide as the content.
        wc.open(path: src.appendingPathComponent("NOTES.md").path, line: nil)
        w.contentView?.layoutSubtreeIfNeeded()
        let views = all(wc.inspector.view)
        func ink(_ s: String) throws -> CGFloat {
            let l = try #require(views.first { ($0 as? NSTextField)?.stringValue == s && !$0.isHidden }, "\(s)")
            return frame(l, in: w).y + 2.5
        }
        let field = frame(try #require(tags()), in: w)
        let button = frame(try #require(wc.inspector.fileControls["Localize"]), in: w)
        let heading = try #require(views.first { ($0 as? NSTextField)?.stringValue == "Localization" })
        let odr = try ink("On Demand Resource Tags"), loc = try ink("Localization"), tm = try ink("Target Membership")
        let report = String(format: "ODR %.1f field %.1f–%.1f Loc %.1f (x %.1f) button x %.1f–%.1f y %.1f–%.1f TM %.1f",
                            odr, field.y, field.maxY, loc, frame(heading, in: w).x, button.x, button.maxX, button.y, button.maxY, tm)
        print("R9C markdown inspector: \(report)")
        func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 1.5) -> Bool { abs(a - b) <= tol }
        #expect(near(field.y - odr, 22) && near(field.maxY - field.y, 24), "\(report)")
        #expect(near(loc - field.maxY, 20.5), "\(report)")   // 12 to the rule, 8.5 to the ink
        #expect(near(button.y - loc, 28) && near(button.maxY - button.y, 16), "\(report)")
        #expect(near(tm - button.maxY, 25), "\(report)")   // 16.5 to the rule, 8.5 to the ink
        // A full-width button (the reference: 238.5 wide in a 260-point inspector).
        #expect(near(button.maxX - button.x, 238.5), "\(report)")

        // Swift source: not a resource.
        wc.open(path: src.appendingPathComponent("Long.swift").path, line: nil)
        w.contentView?.layoutSubtreeIfNeeded()
        #expect(typeTitle() == "Default - Swift Source")
        #expect(!wc.inspector.sectionTitles.contains("Localization"))
        #expect(tags()?.isEnabled == false && tags()?.placeholderString == "Only resources are taggable")
        // The image keeps its sections, Localization after Image Properties.
        wc.open(path: src.appendingPathComponent("Stripes.png").path, line: nil)
        #expect(typeTitle() == "Default - PNG Image")
        #expect(wc.inspector.sectionTitles == ["Identity and Type", "On Demand Resource Tags", "Image Properties", "Localization", "Target Membership"])
    }

    // MARK: Stills (R9_SHOTS=1): .build-ide/b9-shots

    /// The inspector's own drawing over the window's background colour (a
    /// window kept off every display draws its glass panes empty).
    func inspectorShot(_ wc: WorkspaceWindowController, _ url: URL) {
        let v = wc.inspector.view
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds),
              let out = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        v.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: v.bounds.size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: v.bounds.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// NOTES.md, palette.json and Long.swift in light and dark, the window
    /// ordered in off every display and captured by the window server.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["R9_SHOTS"] != nil))
    func stills() async throws {
        let (wc, dir) = try councilWindow("shots")
        let w = try #require(wc.window)
        MergeSheetR5UITests.Offscreen.on()
        defer { MergeSheetR5UITests.Offscreen.off() }
        defer { w.orderOut(nil) }
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build-ide/b9-shots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        w.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: true)
        w.orderBack(nil)
        await wc.connectLanguageService(transport: CompilingServer())
        let src = dir.appendingPathComponent("GlassScroll")
        for look in ["light", "dark"] {
            w.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
            for (file, state) in [("NOTES.md", "notes"), ("palette.json", "palette"), ("Long.swift", "swift")] {
                wc.open(path: src.appendingPathComponent(file).path, line: nil)
                try await Task.sleep(for: .milliseconds(400))
                spin(0.3)
                UISpacingProbeTests.shot(w, out.appendingPathComponent("r9c-mac-\(state)-\(look).png"))
                inspectorShot(wc, out.appendingPathComponent("r9c-mac-\(state)-\(look)-inspector.png"))
                print("R9C shot \(state) \(look): capsule \(wc.issueCapsule.errors)E editor issues \(wc.editor.textView.issues.count)")
            }
        }
        await wc.session.language?.stop()
    }
}
