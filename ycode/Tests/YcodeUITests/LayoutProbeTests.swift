import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
import YcodeProject
@testable import YcodeUI

/// The layout probe's measuring (`LayoutProbe`, `specs/ide/metrics.md`
/// §14) in the test runner: the same window as `UISpacingTests`, so the
/// probe in the app and the tests read the same values. On the system the
/// metrics were taken on, every measure meets its spec.
@MainActor
@Suite(.serialized) struct LayoutProbeTests {
    @Test func workspaceMeasuresMeetTheSpec() throws {
        try UISpacingTests().withWindow { wc, win in
            let r = try #require(LayoutProbe.Recorder(window: win))
            LayoutProbe.measureWorkspace(wc, into: r)
            #expect(r.frames["navigator.selector"] != nil && r.frames["editor.jumpBar"] != nil && r.frames["inspector.tabs"] != nil)
            #expect(r.frames["toolbar.run"] != nil && r.frames["toolbar.history"] != nil)
            #expect(r.measures.count > 40)
            for m in r.measures where m.ok == false {
                Issue.record("\(m.name) = \(m.value), spec \(m.op) \(m.spec ?? 0) (\(m.source))")
            }
            wc.toggleDebugArea(nil)
            win.contentView?.layoutSubtreeIfNeeded()
            let d = try #require(LayoutProbe.Recorder(window: win))
            LayoutProbe.measureDebugArea(wc, into: d)
            #expect(d.frames["debug.variablesBar"] != nil)
            for m in d.measures where m.ok == false {
                Issue.record("\(m.name) = \(m.value), spec \(m.op) \(m.spec ?? 0) (\(m.source))")
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion != 26,
                   "macOS 26 floats the hub's sidebar; the circle ends 5 points before its edge (metrics.md §14.1)"))
    func deviceHubMeasuresMeetTheSpec() throws {
        _ = NSApplication.shared
        let prefs = IsolatedPreferences("layout-probe-hub")
        defer { prefs.restore() }
        let row = DeviceRow.shutDownYcodeSimulator(name: "Phone (Ycode)", identifier: "probe-hub-1")
        let hub = DevicesController(devices: [], simulators: [row])
        let w = hub.makeWindow()
        w.setFrameAutosaveName("")
        hub.splitView.autosaveName = nil
        defer { w.close() }
        w.contentView?.layoutSubtreeIfNeeded()
        hub.placeFirstDividers()
        let r = try #require(LayoutProbe.Recorder(window: w))
        LayoutProbe.measureDeviceHub(w, into: r)
        let gap = try #require(r.measures.first { $0.name == "hub.hideSidebar.gapToSidebarEdge" })
        #expect(gap.ok == true, "the circle ends \(gap.value) before the sidebar")
    }

    /// The report's JSON keeps every field the table script reads.
    @Test func reportEncodes() throws {
        var report = LayoutProbe.Report(macOS: "x", macOSVersion: "27.2.0", backingScale: 2, screen: nil, glass: true, shown: false)
        report.frames["a"] = LayoutProbe.Frame(x: 1, y: 2, w: 3, h: 4)
        let data = try JSONEncoder().encode(report)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["macOS", "macOSVersion", "backingScale", "glass", "shown", "windows", "frames", "measures", "notes"] {
            #expect(obj[key] != nil, "\(key)")
        }
    }
}
