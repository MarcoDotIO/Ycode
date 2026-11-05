import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// The macOS half of the Organizer's paired screenshots (the Linux half is
/// `ycode-ide` with `YCODE_IDE_ORGANIZER`). With `YCODE_ORGANIZER_SHOTS`
/// (the output folder) and `YCODE_ORGANIZER_ARCHIVES` (an archives folder,
/// such as the one `ycodebuild archive` fills) set, it opens the Organizer
/// in a window with its toolbar and writes `mac-organizer-<appearance>-
/// <state>.png` (the window's frame view drawn with `cacheDisplay`, never
/// put on screen) for the archive list with the newest archive selected,
/// and the Overview page's empty state. It never runs without the variables.
@MainActor
@Suite(.serialized) struct OrganizerParityProbeTests {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["YCODE_ORGANIZER_SHOTS"]
    nonisolated static let archives = ProcessInfo.processInfo.environment["YCODE_ORGANIZER_ARCHIVES"]

    @Test(.enabled(if: outDir != nil && archives != nil)) func pairedStates() throws {
        _ = NSApplication.shared
        let out = URL(fileURLWithPath: try #require(Self.outDir))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for appearance in ["light", "dark"] {
            let org = OrganizerController(archivesDirectory: URL(fileURLWithPath: try #require(Self.archives)))
            let win = NSWindow(contentViewController: org)
            win.isReleasedWhenClosed = false
            win.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            win.title = "Organizer"
            org.installToolbar()
            org.reload()
            let all = org.groups.flatMap(\.archives)
            if let newest = all.filter(\.hasApplication).max(by: { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }) {
                org.select(archiveAt: newest.url)
            }
            org.showPage("Archives", section: "Products")
            try shot(win, "mac-organizer-\(appearance)-archives", out)
            print("organizer details: \(org.detailRows.map { "\($0.0)=\($0.1)" })")
            org.showPage("Overview", section: "Insights")
            try shot(win, "mac-organizer-\(appearance)-overview", out)
            win.close()
        }
    }

    func shot(_ win: NSWindow, _ name: String, _ out: URL) throws {
        win.contentView?.layoutSubtreeIfNeeded()
        try LinuxParityProbeTests.write(window: win, name: name, to: out)
    }
}
