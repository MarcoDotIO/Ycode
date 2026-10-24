import Foundation
import Testing
@testable import ycode_simd

/// A copied or moved device directory (specs/simulator/app-launch.md §3.3).
struct DeviceRelocationTests {
    /// A scratch directory outside the paths the guest has of its own
    /// (/tmp, /var, /private: the temporary directory is there on both
    /// hosts, and no device path may be): the package's .build.
    private func scratch() throws -> String {
        let dir = FileManager.default.currentDirectoryPath + "/.build/ycode-reloc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private let fm = FileManager.default

    /// A device directory with data, a record (unless nil) and a device
    /// store naming `storePath`'s containers plus a system-only store.
    private func makeDevice(_ dev: String, record: String?, storePath: String) throws {
        let lsd = dev + "/data/var/db/lsd"
        try fm.createDirectory(atPath: lsd, withIntermediateDirectories: true)
        try Data(("\u{0}\u{1}" + storePath + "/data/Containers/Bundle/Application/A\u{0}").utf8)
            .write(to: URL(fileURLWithPath: lsd + "/com.apple.LaunchServices-1-v2.csstore"))
        try Data("\u{0}/rr/Applications/MobileSafari.app\u{0}".utf8)
            .write(to: URL(fileURLWithPath: lsd + "/SystemDataOnly-com.apple.LaunchServices-1-v2.csstore"))
        if let record { try Data((record + "\n").utf8).write(to: URL(fileURLWithPath: dev + "/ycode-device-path")) }
    }

    private func layout(_ dev: String) -> DeviceLayout {
        DeviceLayout(dev: dev, runtimeRoot: "/rr", udid: nil, jobPaths: [], runtimePaths: true)
    }

    @Test func foreignPathInStoreBytes() {
        var bytes = Data([0x00, 0x01, 0x41])
        bytes += Data("/old/dev/data/Containers/Data/Application/X".utf8)
        bytes += Data([0x00])
        #expect(DeviceLayout.foreignDevicePath(in: bytes, current: "/new/dev") == "/old/dev")
        #expect(DeviceLayout.foreignDevicePath(in: bytes, current: "/old/dev") == nil)
        #expect(DeviceLayout.foreignDevicePath(in: bytes, current: "") == "/old/dev")
        #expect(DeviceLayout.foreignDevicePath(in: Data("no containers here".utf8), current: "/x") == nil)
        #expect(DeviceLayout.foreignDevicePath(in: Data(), current: "/x") == nil)
        // The marker at the very end, a partial marker, and a second path after the current one.
        #expect(DeviceLayout.foreignDevicePath(in: Data("/a/data/Containers/".utf8), current: "/b") == "/a")
        #expect(DeviceLayout.foreignDevicePath(in: Data("/a/data/Contain".utf8), current: "/b") == nil)
        let two = Data("/cur/data/Containers/x\u{0}/other/data/Containers/y".utf8)
        #expect(DeviceLayout.foreignDevicePath(in: two, current: "/cur") == "/other")
    }

    @Test func copyKeepsTheGuestPathAndItsStore() throws {
        let root = try scratch()
        defer { try? fm.removeItem(atPath: root) }
        let old = root + "/old", new = root + "/new"
        try makeDevice(old, record: old, storePath: old)
        try fm.copyItem(atPath: old, toPath: new)
        var copy = layout(new)
        copy.guestDev = copy.resolveGuestDevicePath()
        #expect(copy.guestDev == old)
        try copy.handleRelocation()
        // No store removed; the record keeps the guest path.
        #expect(copy.launchServicesStoreFiles().count == 2)
        #expect(DeviceLayout.recordedGuestDevicePath(in: new) == old)
        // The guest sees DEV at the guest path; the host works in DEV.
        #expect(copy.guestPath(new + "/data/tmp/x") == old + "/data/tmp/x")
        #expect(copy.guestPath(new) == old)
        #expect(copy.guestPath("/rr/usr/bin/x") == "/rr/usr/bin/x")
        #expect(copy.guestPath(root + "/newer") == root + "/newer")
        #expect(copy.childDefaults["HOME"] == old + "/data")
        #expect(copy.child["SIMULATOR_HOST_HOME"] == old)
        #expect(copy.child["SIMULATOR_LOG_ROOT"] == old + "/Logs")
        let paths = (copy.bootstrapPlist["Bootstrap"] as? [String: Any])?["Paths"] as? [String] ?? []
        #expect(paths.contains(old + "/data/Library/LaunchDaemons"))
        #expect(!paths.contains { $0.hasPrefix(new + "/") })
        #expect(copy.memoryGuestPath == old + "/ycode-memory")
        // A copy of the copy keeps it too.
        let third = root + "/third"
        try fm.copyItem(atPath: new, toPath: third)
        #expect(layout(third).resolveGuestDevicePath() == old)
    }

    @Test func dataWithoutRecordCarriesTheStorePath() throws {
        let root = try scratch()
        defer { try? fm.removeItem(atPath: root) }
        let first = root + "/runs/f3/dev", dev = root + "/pristine-copy"
        try makeDevice(dev, record: nil, storePath: first)
        var l = layout(dev)
        l.guestDev = l.resolveGuestDevicePath()
        #expect(l.guestDev == first)
        try l.handleRelocation()
        #expect(l.launchServicesStoreFiles().count == 2)
        #expect(DeviceLayout.recordedGuestDevicePath(in: dev) == first)
        // New data (no store, no record): its own path.
        let fresh = root + "/fresh"
        try fm.createDirectory(atPath: fresh, withIntermediateDirectories: true)
        #expect(layout(fresh).resolveGuestDevicePath() == fresh)
    }

    @Test func storeNamingAnotherPathIsRebuilt() throws {
        let root = try scratch()
        defer { try? fm.removeItem(atPath: root) }
        // The record gives the data's guest path, but the device store names
        // a third device (data put together from two devices).
        let dev = root + "/dev", other = root + "/other"
        try makeDevice(dev, record: other, storePath: root + "/third")
        var l = layout(dev)
        l.guestDev = l.resolveGuestDevicePath()
        #expect(l.guestDev == other)
        try l.handleRelocation()
        let left = l.launchServicesStoreFiles().map { ($0 as NSString).lastPathComponent }
        #expect(left == ["SystemDataOnly-com.apple.LaunchServices-1-v2.csstore"])
        #expect(DeviceLayout.recordedGuestDevicePath(in: dev) == other)
        // The store lsd writes at the guest path is kept at the next boot.
        try Data((other + "/data/Containers/Data/Application/B").utf8)
            .write(to: URL(fileURLWithPath: l.launchServicesStorePath + "/com.apple.LaunchServices-1-v2.csstore"))
        var next = layout(dev)
        next.guestDev = next.resolveGuestDevicePath()
        try next.handleRelocation()
        #expect(next.launchServicesStoreFiles().count == 2)
    }

    @Test func ownerDeviceIsUnchanged() throws {
        let root = try scratch()
        defer { try? fm.removeItem(atPath: root) }
        let dev = root + "/dev"
        try makeDevice(dev, record: dev, storePath: dev)
        var l = layout(dev)
        l.guestDev = l.resolveGuestDevicePath()
        #expect(l.guestDev == dev)
        try l.handleRelocation()
        #expect(l.launchServicesStoreFiles().count == 2)
        #expect(l.guestPath(dev + "/data") == dev + "/data")
        #expect(l.childDefaults["HOME"] == dev + "/data")
    }

    @Test func ownRecordWithAForeignStoreIsRebuilt() throws {
        let root = try scratch()
        defer { try? fm.removeItem(atPath: root) }
        // The record names DEV itself, but the store still names the device
        // the data came from (a record set by hand, data copied over).
        let dev = root + "/dev", origin = root + "/origin"
        try makeDevice(dev, record: dev, storePath: origin)
        var l = layout(dev)
        l.guestDev = l.resolveGuestDevicePath()
        #expect(l.guestDev == dev)
        try l.handleRelocation()
        #expect(l.launchServicesStoreFiles().count == 1)
    }

    @Test func templateCloneTakesTheTemplatesGuestPath() throws {
        let root = try scratch()
        defer { try? fm.removeItem(atPath: root) }
        let golden = root + "/golden", first = root + "/first", dev = root + "/dev"
        try makeDevice(golden, record: first, storePath: first)
        var l = layout(dev)
        l.templatePath = golden
        #expect(l.resolveGuestDevicePath() == first)
    }

    @Test func unusableGuestPathFallsBackToDEV() throws {
        let root = try scratch()
        defer { try? fm.removeItem(atPath: root) }
        let dev = root + "/dev"
        for bad in ["/tmp/x/dev", "/private/var/x", "/rr", "/rr/sub", "/", "relative/dev", "/a/../b"] {
            try makeDevice(dev, record: bad, storePath: bad)
            var l = layout(dev)
            l.guestDev = l.resolveGuestDevicePath()
            #expect(l.guestDev == dev, "\(bad)")
            // The old rule applies: the store naming the other path goes.
            try l.handleRelocation()
            #expect(l.launchServicesStoreFiles().count == 1, "\(bad)")
            try fm.removeItem(atPath: dev)
        }
        #expect(layout(dev).guestDevicePathProblem(root + "/elsewhere") == nil)
    }
}
