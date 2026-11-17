import AppKit
import Foundation

/// Screenshots of the beta 4 workflow fixes, rendered offscreen into
/// `.build-ide/b4-shots/` (nothing is shown on a display).
@MainActor
enum WorkflowsB4Shots {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build-ide/b4-shots")

    /// Renders `view` (with its subviews) to `<name>.png`.
    @discardableResult
    static func save(_ view: NSView, _ name: String) -> URL? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name + ".png")
        try? data.write(to: url)
        return url
    }

    /// A window's frame view (title bar and content).
    static func save(window: NSWindow?, _ name: String) {
        if let v = window?.contentView?.superview { save(v, name) }
    }
}
