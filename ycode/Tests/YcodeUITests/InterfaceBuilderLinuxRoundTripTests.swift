import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeIDEShell
@testable import YcodeUI

/// #79's cross check: a storyboard edited by the Linux IDE's editor model
/// (add a button, set its title, add a constraint) opens in the macOS
/// editor unchanged, which shows the same outline and inspectors and writes
/// nothing until it is edited. Every Library object the macOS editor
/// inserts can be edited and saved (#84).
@MainActor
@Suite(.serialized) struct InterfaceBuilderLinuxRoundTripTests {
    static let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Samples/InterfaceBuilderSamples/Interface")

    func copy(_ name: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-ib-rt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let to = d.appendingPathComponent(name)
        try FileManager.default.copyItem(at: Self.samples.appendingPathComponent(name), to: to)
        return to
    }

    @Test func linuxEditOpensUnchangedOnMac() throws {
        let url = try copy("Main.storyboard")
        let linux = try InterfaceBuilderShellModel(path: url.path)
        linux.select(id: "Rv1-aa-bb1")
        let id = try #require(linux.insertFromLibrary(.button))
        linux.setTitle("Continue")
        #expect(linux.addConstraints(.init(spacing: [.top: 20], width: 120)).count == 2)
        let edited = try Data(contentsOf: url)

        let mac = try InterfaceBuilderController(url: url)
        _ = mac.view
        #expect(try Data(contentsOf: url) == edited)
        #expect(mac.outlineTitles == linux.session.outlineTitles())
        mac.select(id: id)
        #expect(mac.document.title(of: id) == "Continue")
        #expect(mac.inspectorSections(.size) == linux.inspectorSections(.size))
        #expect(mac.document.constraints(involving: id).count == 2)
        // Both editors put the button in the same place on the canvas.
        let b = try #require(mac.document.byID[id])
        #expect(mac.canvas.rect(of: b) == linux.layout.rect(of: linux.document.byID[id]!))
        // The overview shows both scenes and the visible part.
        #expect(mac.overview.drawn.boxes == linux.layout.overview(in: IBCanvasOverviewView.size).boxes)
        #expect(mac.overview.drawn.boxes.count == 2 && mac.overview.superview != nil)
        #expect(try Data(contentsOf: url) == edited)
    }

    /// A storyboard the Linux IDE's walk wrote (`YCODE_IDE_IB`, its
    /// `<prefix>-result.storyboard`), named by `YCODE_IB_LINUX_RESULT`:
    /// the macOS editor opens it, finds the new button, and writes nothing.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YCODE_IB_LINUX_RESULT"] != nil))
    func storyboardWrittenOnLinuxOpensUnchanged() throws {
        let given = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["YCODE_IB_LINUX_RESULT"]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-ib-linux-\(UUID().uuidString).storyboard")
        try FileManager.default.copyItem(at: given, to: url)
        let bytes = try Data(contentsOf: url)
        let c = try InterfaceBuilderController(url: url)
        _ = c.view
        var button: IBDocument.Object?
        for r in c.document.roots { r.walk { if $0.element == "button" { button = $0 } } }
        let b = try #require(button)
        #expect(c.document.title(of: b.id) == "Continue")
        #expect(c.document.constraints(involving: b.id).count == 2)
        c.select(id: b.id)
        _ = c.inspectorSections(.size)
        #expect(c.outlineTitles.contains { $0.trimmingCharacters(in: .whitespaces) == "Continue" })
        // With YCODE_SHOTS, the macOS editor showing it, light and dark.
        if let dir = ProcessInfo.processInfo.environment["YCODE_SHOTS"] {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            c.view.translatesAutoresizingMaskIntoConstraints = false
            w.contentView!.addSubview(c.view)
            NSLayoutConstraint.activate([c.view.widthAnchor.constraint(equalToConstant: 1100), c.view.heightAnchor.constraint(equalToConstant: 900),
                                         c.view.topAnchor.constraint(equalTo: w.contentView!.topAnchor),
                                         c.view.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor)])
            c.view.layoutSubtreeIfNeeded()
            c.zoomToFit()
            for (name, look) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                c.view.appearance = NSAppearance(named: look)
                c.view.layoutSubtreeIfNeeded()
                let rep = try #require(c.view.bitmapImageRepForCachingDisplay(in: c.view.bounds))
                c.view.cacheDisplay(in: c.view.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("ib-mac-linux-result-\(name).png"))
            }
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func everyLibraryObjectAddsEditsAndSavesOnMac() throws {
        for name in ["Main.storyboard", "Card.xib"] {
            let url = try copy(name)
            let c = try InterfaceBuilderController(url: url)
            _ = c.view
            for kind in IBDocument.NewObject.allCases {
                c.select(IBEditorSession.firstView(in: c.document))
                let id = try #require(c.insert(kind), "\(kind)")
                #expect(c.selected?.id == id)
                // The inspectors offer the View section and the frame.
                #expect(c.inspectorSections(.attributes).contains { $0.title == "View" })
                #expect(c.inspectorSections(.size).flatMap(\.rows).contains { if case .frameValue = $0 { return true } else { return false } })
                c.setFrameComponent("x", 7, of: id)
                c.setAttribute("alpha", "0.5", of: id)
                c.setHidden(true)
                let saved = try IBDocument(url: url)
                #expect(saved.byID[id]?.frame?.minX == 7 && saved.byID[id]?.attribute("alpha") == "0.5" && saved.isHidden(id))
            }
        }
    }
}
