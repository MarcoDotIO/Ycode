import Foundation
import Testing
@testable import ycode_simd

/// The lean boot profile and the device layout parts it drives
/// (specs/simulator/lean-boot.md).
struct LeanBootTests {
    @Test func offByDefault() {
        #expect(LeanBootProfile.from(environment: [:]) == nil)
        #expect(LeanBootProfile.from(environment: ["YCODE_LEAN_BOOT": "0"]) == nil)
        #expect(LeanBootProfile.from(environment: ["YCODE_LEAN_BOOT": ""]) == nil)
        #expect(LeanBootProfile.from(environment: ["YCODE_LEAN_BOOT": "bogus"]) == nil)
    }

    @Test func modes() throws {
        let daemons = try #require(LeanBootProfile.from(environment: ["YCODE_LEAN_BOOT": "1"]))
        #expect(daemons.disabledLabels == LeanBootProfile.defaultDisabledLabels)
        #expect(!daemons.loggingOff)
        let logging = try #require(LeanBootProfile.from(environment: ["YCODE_LEAN_BOOT": "logging"]))
        #expect(logging.disabledLabels.isEmpty && logging.loggingOff)
        let all = try #require(LeanBootProfile.from(environment: ["YCODE_LEAN_BOOT": "all"]))
        #expect(all.disabledLabels == LeanBootProfile.defaultDisabledLabels && all.loggingOff)
    }

    @Test func extraAndKeep() throws {
        let p = try #require(LeanBootProfile.from(environment: [
            "YCODE_LEAN_BOOT": "daemons",
            "YCODE_LEAN_BOOT_DISABLE": "com.example.a, com.apple.suggestd",
            "YCODE_LEAN_BOOT_KEEP": "com.apple.searchd,com.apple.homed",
        ]))
        #expect(p.disabledLabels.contains("com.example.a"))
        #expect(p.disabledLabels.filter { $0 == "com.apple.suggestd" }.count == 1)
        #expect(!p.disabledLabels.contains("com.apple.searchd"))
        #expect(!p.disabledLabels.contains("com.apple.homed"))
        // Keeping every label of a daemons-only profile turns it off.
        let none = LeanBootProfile.from(environment: [
            "YCODE_LEAN_BOOT": "1", "YCODE_LEAN_BOOT_KEEP": LeanBootProfile.defaultDisabledLabels.joined(separator: ","),
        ])
        #expect(none == nil)
    }

    @Test func overridesKeepExplicitEnable() {
        let p = LeanBootProfile(disabledLabels: ["a", "b"], loggingOff: false)
        #expect(p.disabledOverrides(existing: ["b": false, "c": true]) == ["a": true, "b": false, "c": true])
    }

    @Test func prepareWritesDisabledPlistAndChildEnvironment() throws {
        let fm = FileManager.default
        let dev = fm.temporaryDirectory.appendingPathComponent("ycode-lean-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: dev) }
        let rr = dev + "-rr"
        try fm.createDirectory(atPath: rr, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: rr) }
        var layout = DeviceLayout(dev: dev, runtimeRoot: rr, udid: nil, jobPaths: [])
        layout.lean = LeanBootProfile(disabledLabels: ["com.apple.suggestd"], loggingOff: true)
        layout.templatePath = nil
        try layout.prepare()
        let data = try #require(fm.contents(atPath: layout.disabledOverridesHostPath))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Bool])
        #expect(plist == ["com.apple.suggestd": true])
        let attributes = try fm.attributesOfItem(atPath: layout.tmpHostPath)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
        // Logging off: one level-off file per listed subsystem, recorded.
        let subsystems = layout.loggingSubsystemsPath
        let one = try #require(fm.contents(atPath: subsystems + "/com.apple.runningboard.plist"))
        let pref = try #require(try PropertyListSerialization.propertyList(from: one, format: nil) as? [String: [String: [String: String]]])
        #expect(pref["DEFAULT-OPTIONS"]?["Level"] == ["Enable": "off", "Persist": "off"])
        #expect(try fm.contentsOfDirectory(atPath: subsystems).count == LeanBootProfile.loggingOffSubsystems.count)
        // A preference that was there before is kept and not recorded; a
        // boot without the profile removes only what the profile wrote.
        try fm.removeItem(atPath: subsystems + "/com.apple.xpc.plist")
        try layout.applyLoggingPreferences(false)
        try Data("mine".utf8).write(to: URL(fileURLWithPath: subsystems + "/com.apple.xpc.plist"))
        try layout.applyLoggingPreferences(true)
        #expect(fm.contents(atPath: subsystems + "/com.apple.xpc.plist") == Data("mine".utf8))
        try layout.applyLoggingPreferences(false)
        #expect(try fm.contentsOfDirectory(atPath: subsystems) == ["com.apple.xpc.plist"])
        #expect(!fm.fileExists(atPath: layout.leanLoggingRecordPath))
        // Off: no TMP is made and the environment has no logging switch.
        var off = DeviceLayout(dev: dev + "-off", runtimeRoot: rr, udid: nil, jobPaths: [])
        defer { try? fm.removeItem(atPath: dev + "-off") }
        off.lean = nil
        off.templatePath = nil
        try off.prepare()
        #expect(!fm.fileExists(atPath: off.tmpHostPath))
        #expect(!fm.fileExists(atPath: off.loggingSubsystemsPath + "/com.apple.runningboard.plist"))
    }

    @Test func cloneFromTemplate() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ycode-tpl-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: base) }
        let template = base + "/golden", dev = base + "/dev", rr = base + "/rr"
        try fm.createDirectory(atPath: template + "/data/Library/Preferences", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: rr, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: template + "/data/Library/Preferences/p.plist"))
        var layout = DeviceLayout(dev: dev, runtimeRoot: rr, udid: nil, jobPaths: [])
        layout.lean = nil
        layout.templatePath = template
        try layout.prepare()
        #expect(fm.contents(atPath: dev + "/data/Library/Preferences/p.plist") == Data("x".utf8))
        // A second prepare keeps DEV's own data.
        try Data("y".utf8).write(to: URL(fileURLWithPath: dev + "/data/Library/Preferences/p.plist"))
        try layout.prepare()
        #expect(fm.contents(atPath: dev + "/data/Library/Preferences/p.plist") == Data("y".utf8))
        #expect(layout.udid != DeviceLayout.stableUDID(for: template))
    }
}
