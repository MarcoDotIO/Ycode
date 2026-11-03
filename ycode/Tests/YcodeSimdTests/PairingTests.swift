import Foundation
import Testing
import YcodeSimFeatures
@testable import ycode_simd

/// PAIR-HOST (device-pairing.md P-1 … P-4, §8): what the pairing commands
/// read from device directories, how they find a device, the unpair erase,
/// and the pairing agent's launchd job.
@Suite(.serialized) struct PairingDeviceDirectoryTests {
    func makeSet() throws -> String {
        let set = NSTemporaryDirectory() + "pairset-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
        return set
    }

    func makeDevice(_ set: String, _ name: String, type: String, runtime: String? = nil) throws -> String {
        let dir = set + "/" + name
        try FileManager.default.createDirectory(atPath: dir + "/data/Library", withIntermediateDirectories: true)
        try Data((type + "\n").utf8).write(to: URL(fileURLWithPath: dir + "/ycode-device-type"))
        if let runtime { try Data(runtime.utf8).write(to: URL(fileURLWithPath: dir + "/ycode-runtime")) }
        return dir
    }

    @Test func familiesComeFromTheDeviceTypes() {
        #expect(PairingDeviceDirectory.family(typeID: DeviceType.iPhone18Pro.id) == .phone)
        #expect(PairingDeviceDirectory.family(typeID: "iphone-duo") == .phone)
        #expect(PairingDeviceDirectory.family(typeID: DeviceType.appleWatchSeries12_46mm.id) == .watch)
        #expect(PairingDeviceDirectory.family(typeID: "vision-pro") == .other)
        #expect(PairingDeviceDirectory.family(typeID: "no-such-type") == .other)
    }

    @Test func infoReadsTypeRuntimeAndUDID() throws {
        let set = try makeSet()
        defer { try? FileManager.default.removeItem(atPath: set) }
        let phone = try makeDevice(set, "p18", type: DeviceType.iPhone18Pro.id, runtime: "iPhone OS 27.0 24A434\n")
        let info = try PairingDeviceDirectory.info(dir: phone, set: set)
        #expect(info.family == .phone && info.directory == "p18" && info.osVersion == "27.0")
        #expect(info.typeName == DeviceType.iPhone18Pro.name)
        // The UDID a boot recorded wins over the one the path gives.
        #expect(info.udid == DeviceLayout.stableUDID(for: phone))
        let recorded = "12345678-90AB-CDEF-1234-567890ABCDEF"
        try Data((recorded.lowercased() + "\n").utf8).write(to: URL(fileURLWithPath: phone + "/ycode-udid"))
        #expect(PairingDeviceDirectory.udid(of: phone) == recorded)
        // A directory that never booted has no type: refused.
        let fresh = set + "/fresh"
        try FileManager.default.createDirectory(atPath: fresh, withIntermediateDirectories: true)
        #expect(throws: PairingDeviceDirectory.NoDeviceType.self) { try PairingDeviceDirectory.info(dir: fresh, set: set) }
        #expect(PairingDeviceDirectory.relative("/elsewhere/x", to: set) == "/elsewhere/x")
    }

    @Test func devicesAreFoundByPathNameOrUDID() throws {
        let set = try makeSet()
        defer { try? FileManager.default.removeItem(atPath: set) }
        let watch = try makeDevice(set, "w12", type: DeviceType.appleWatchSeries12_46mm.id)
        let udid = PairingDeviceDirectory.udid(of: watch)
        #expect(PairingDeviceDirectory.resolve(watch, set: nil) == watch)
        #expect(PairingDeviceDirectory.resolve("w12", set: set) == watch)
        #expect(PairingDeviceDirectory.resolve(udid.lowercased(), set: set) == watch)
        #expect(PairingDeviceDirectory.resolve("w99", set: set) == nil)
        #expect(PairingDeviceDirectory.directory(record: "w12", udid: "X", set: set) == watch)
        #expect(PairingDeviceDirectory.directory(record: "gone", udid: udid, set: set) == watch)
    }

    @Test func pairingTwoDirectoriesWritesTheRecords() throws {
        let set = try makeSet()
        defer { try? FileManager.default.removeItem(atPath: set) }
        let phone = try makeDevice(set, "p18", type: DeviceType.iPhone18Pro.id, runtime: "iPhone OS 27.0 24A434\n")
        let watch = try makeDevice(set, "w12", type: DeviceType.appleWatchSeries12_46mm.id, runtime: "Watch OS 27.0 24R362\n")
        let devices = try [watch, phone].map { try PairingDeviceDirectory.info(dir: $0, set: set) }
        let pair = try DevicePairStore.update(set: set) { try $0.pair(devices[0], devices[1]) }
        #expect(pair.active && pair.gizmoDirectory == "w12" && pair.companionDirectory == "p18")
        #expect(try DevicePairStore.load(set: set).pairs(of: PairingDeviceDirectory.udid(of: watch)).map(\.id) == [pair.id])
    }

    @Test func eraseKeepsOnlyTheIdentity() throws {
        let set = try makeSet()
        defer { try? FileManager.default.removeItem(atPath: set) }
        let watch = try makeDevice(set, "w12", type: DeviceType.appleWatchSeries12_46mm.id, runtime: "Watch OS 27.0 24R362\n")
        try Data("X\n".utf8).write(to: URL(fileURLWithPath: watch + "/ycode-udid"))
        try Data("data".utf8).write(to: URL(fileURLWithPath: watch + "/data/Library/file"))
        try FileManager.default.createDirectory(atPath: watch + "/private-var-tmp/x", withIntermediateDirectories: true)
        try PairingDeviceDirectory.erase(watch)
        #expect(try FileManager.default.contentsOfDirectory(atPath: watch).sorted() == ["ycode-device-type", "ycode-udid"])
        #expect(DeviceLayout.recordedDeviceType(in: watch) == DeviceType.appleWatchSeries12_46mm.id)
        // Nothing left beside the device.
        #expect(try FileManager.default.contentsOfDirectory(atPath: set) == ["w12"])
    }

    @Test func agentJob() {
        var layout = DeviceLayout(dev: "/d/dev", runtimeRoot: "/rr", udid: nil, jobPaths: [], runtimePaths: false, oneshots: [], runtimeJobs: [])
        layout.guestDev = "/g/dev"
        let p = layout.pairingAgentPlist
        #expect(p["Label"] as? String == "dev.ycode.simulator.pairing")
        #expect(p["ProgramArguments"] as? [String] == ["/g/dev/data/Library/Ycode/bin/ycode-pairing-agent"])
        #expect(p["KeepAlive"] as? Bool == true && p["RunAtLoad"] as? Bool == true && p["RootedSimulatorPath"] as? Bool == true)
        #expect(p["ProcessType"] as? String == "Interactive")
        #expect(p["StandardErrorPath"] as? String == "/g/dev/data/tmp/ycode-pairing-agent.log")
        #expect((p["EnvironmentVariables"] as? [String: String])?["YCODE_PAIRING_AGENT_STATE"] == "/g/dev/data/tmp/ycode-pairing-agent.state")
        #expect(layout.pairingAgentPlistPath == "/d/dev/data/Library/LaunchDaemons/dev.ycode.simulator.pairing.plist")
    }

    @Test func stagingWithoutABinaryRemovesTheJob() throws {
        let set = try makeSet()
        defer { try? FileManager.default.removeItem(atPath: set) }
        let layout = DeviceLayout(dev: set + "/dev", runtimeRoot: "/rr", udid: nil, jobPaths: [])
        try FileManager.default.createDirectory(atPath: set + "/dev/data/Library/LaunchDaemons", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: layout.pairingAgentPlistPath))
        try layout.stagePairingAgent()
        #expect(!FileManager.default.fileExists(atPath: layout.pairingAgentPlistPath))
    }

    @Test func aWatchGetsTheWatchBuildOfAnAgent() throws {
        let set = try makeSet()
        defer { try? FileManager.default.removeItem(atPath: set) }
        let rr = set + "/rr"
        try FileManager.default.createDirectory(atPath: rr + "/System/Library/CoreServices", withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["ProductName": "Watch OS", "ProductVersion": "27.0",
                                                                         "ProductBuildVersion": "24R362"], format: .xml, options: 0)
        try plist.write(to: URL(fileURLWithPath: rr + "/System/Library/CoreServices/SystemVersion.plist"))
        try FileManager.default.createDirectory(atPath: set + "/out/watchos", withIntermediateDirectories: true)
        try Data("ios".utf8).write(to: URL(fileURLWithPath: set + "/out/ycode-pairing-agent"))
        let layout = DeviceLayout(dev: set + "/dev", runtimeRoot: rr, udid: nil, jobPaths: [])
        #expect(layout.platformBuild(of: set + "/out/ycode-pairing-agent") == nil)
        try Data("watch".utf8).write(to: URL(fileURLWithPath: set + "/out/watchos/ycode-pairing-agent"))
        #expect(layout.platformBuild(of: set + "/out/ycode-pairing-agent") == set + "/out/watchos/ycode-pairing-agent")
        #expect(try layout.stageImage(set + "/out/ycode-pairing-agent", to: set + "/dev/agent", mode: 0o755))
        #expect(FileManager.default.contents(atPath: set + "/dev/agent") == Data("watch".utf8))
    }
}
