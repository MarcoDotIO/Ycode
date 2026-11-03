import Foundation
import Testing
@testable import ycode_simd

/// Gauge's signpost agent in a device (specs/ide/profiler.md §3.1): staged
/// into DEV/data/Library/Ycode/lib, inserted after any other inserted
/// library, its signpost file in the guest's /tmp.
@Suite struct GaugeAgentEnvironmentTests {
    @Test func insertedLibrariesAreJoined() {
        let merged = DeviceLayout.mergingInsertedLibraries(
            ["A=1", "DYLD_INSERT_LIBRARIES=/x/overrides.dylib", "YCODE_ENV_OVERRIDES_DIR=/d"],
            ["DYLD_INSERT_LIBRARIES=/x/gauge.dylib", "YCODE_GAUGE_SIGNPOSTS=/tmp/s"])
        #expect(merged == ["A=1", "DYLD_INSERT_LIBRARIES=/x/overrides.dylib:/x/gauge.dylib", "YCODE_ENV_OVERRIDES_DIR=/d", "YCODE_GAUGE_SIGNPOSTS=/tmp/s"])
        #expect(DeviceLayout.mergingInsertedLibraries(["A=1"], []) == ["A=1"])
        #expect(DeviceLayout.mergingInsertedLibraries([], ["DYLD_INSERT_LIBRARIES=/g"]) == ["DYLD_INSERT_LIBRARIES=/g"])
    }

    @Test func stagingAndEnvironment() throws {
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "ycode-gauge-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: root) }
        var layout = DeviceLayout(dev: root + "/dev", runtimeRoot: root + "/rr", udid: nil, jobPaths: [])
        #expect(layout.gaugeEnvironment.isEmpty)
        let lib = root + "/libYcodeGauge.dylib"
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        try Data("lib".utf8).write(to: URL(fileURLWithPath: lib))
        try fm.createDirectory(atPath: layout.data + "/tmp", withIntermediateDirectories: true)
        try Data("old".utf8).write(to: URL(fileURLWithPath: layout.gaugeSignpostsHostPath))
        layout.gaugeLibrary = lib
        try layout.stageGaugeLibrary()
        #expect(fm.contents(atPath: layout.gaugeLibraryHostPath) == Data("lib".utf8))
        #expect(!fm.fileExists(atPath: layout.gaugeSignpostsHostPath))
        #expect(layout.gaugeEnvironment == ["DYLD_INSERT_LIBRARIES=" + layout.guestPath(layout.gaugeLibraryHostPath),
                                            "YCODE_GAUGE_SIGNPOSTS=" + GaugeAgentFiles.signpostsGuestPath])
        #expect(layout.gaugeSignpostsHostPath == layout.data + GaugeAgentFiles.signpostsGuestPath)
    }
}
