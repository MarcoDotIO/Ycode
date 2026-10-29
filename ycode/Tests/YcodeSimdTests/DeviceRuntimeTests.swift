import Foundation
import Testing
@testable import ycode_simd

/// A device keeps its runtime (IOS27; specs/simulator/ipad.md §2.2 per-runtime
/// state): the runtime a device boots is recorded in DEV/ycode-runtime; an
/// older runtime version is refused before anything in DEV is written, a
/// newer one boots and the record follows it.
struct DeviceRuntimeTests {
    func layout(_ dev: String, _ rr: String) -> DeviceLayout {
        var l = DeviceLayout(dev: dev, runtimeRoot: rr, udid: nil, jobPaths: [])
        // A type that runs on every runtime version used here (27.0–27.2).
        l.deviceType = .iPadA16
        l.lean = nil
        l.templatePath = nil
        return l
    }

    @Test func recordFormat() {
        let r = DeviceLayout.RuntimeRecord(productName: "iPhone OS", version: "27.0", build: "24A434")
        #expect(r.line == "iPhone OS 27.0 24A434\n")
        #expect(DeviceLayout.RuntimeRecord(line: r.line) == r)
        #expect(DeviceLayout.RuntimeRecord(line: "xrOS 27.0 24M362")?.displayName == "visionOS 27.0 (24M362)")
        #expect(DeviceLayout.RuntimeRecord(line: "27.0") == nil)
        #expect(DeviceLayout.compareVersions("27.0", "27.1") < 0 && DeviceLayout.compareVersions("27.10", "27.9") > 0
                && DeviceLayout.compareVersions("27.1", "27.1.0") == 0)
    }

    @Test func aDeviceKeepsItsRuntime() throws {
        let fm = FileManager.default
        let base = DeviceTypeTests.tempDir("runtime")
        defer { try? fm.removeItem(atPath: base) }
        let rr271 = base + "/rr271", rr270 = base + "/rr270", rr272 = base + "/rr272", dev = base + "/dev"
        try VisionDeviceTypeTests.runtimeRoot(rr271, productName: "iPhone OS", version: "27.1", build: "24A94401")
        try VisionDeviceTypeTests.runtimeRoot(rr270, productName: "iPhone OS", version: "27.0", build: "24A434")
        try VisionDeviceTypeTests.runtimeRoot(rr272, productName: "iPhone OS", version: "27.2", build: "24C5")
        try layout(dev, rr271).prepare()
        #expect(fm.contents(atPath: dev + "/ycode-runtime") == Data("iPhone OS 27.1 24A94401\n".utf8))
        // An older runtime: refused, nothing written.
        let before = try fm.attributesOfItem(atPath: dev + "/ycode-runtime")[.modificationDate] as? Date
        #expect(throws: DeviceRuntimeDowngrade.self) { try layout(dev, rr270).prepare() }
        #expect(fm.contents(atPath: dev + "/ycode-runtime") == Data("iPhone OS 27.1 24A94401\n".utf8))
        #expect(try fm.attributesOfItem(atPath: dev + "/ycode-runtime")[.modificationDate] as? Date == before)
        // A newer one: boots, and the record follows.
        try layout(dev, rr272).prepare()
        #expect(fm.contents(atPath: dev + "/ycode-runtime") == Data("iPhone OS 27.2 24C5\n".utf8))
        // Each runtime with its own device directory: no conflict.
        try layout(base + "/dev27", rr270).prepare()
        #expect(fm.contents(atPath: base + "/dev27/ycode-runtime") == Data("iPhone OS 27.0 24A434\n".utf8))
    }

    /// A device from before the record (no ycode-runtime) boots on any
    /// runtime; the record is written then.
    @Test func olderDevicesGetARecord() throws {
        let fm = FileManager.default
        let base = DeviceTypeTests.tempDir("runtime-old")
        defer { try? fm.removeItem(atPath: base) }
        let rr = base + "/rr", dev = base + "/dev"
        try VisionDeviceTypeTests.runtimeRoot(rr, productName: "iPhone OS", version: "27.0", build: "24A434")
        try fm.createDirectory(atPath: dev + "/data/Library/Preferences", withIntermediateDirectories: true)
        try DeviceTypeTests.xml(["LastSystemVersion": "24A94401"])
            .write(to: URL(fileURLWithPath: dev + "/data/Library/Preferences/com.apple.migration.plist"))
        try layout(dev, rr).prepare()
        #expect(fm.contents(atPath: dev + "/ycode-runtime") == Data("iPhone OS 27.0 24A434\n".utf8))
    }

    /// Without --device-type a device boots as the type it recorded.
    @Test func recordedTypeIsTheDefault() throws {
        let fm = FileManager.default
        let base = DeviceTypeTests.tempDir("runtime-type")
        defer { try? fm.removeItem(atPath: base) }
        try fm.createDirectory(atPath: base + "/dev", withIntermediateDirectories: true)
        try Data("ipad-a16\n".utf8).write(to: URL(fileURLWithPath: base + "/dev/ycode-device-type"))
        #expect(DeviceLayout.recordedDeviceType(in: base + "/dev").flatMap(DeviceType.named) == .iPadA16)
    }

    // MARK: iPhone 18 Pro (iphone-types.md §4, §5)

    @Test func iPhone18ProIdentity() throws {
        let t = DeviceType.iPhone18Pro, duo = DeviceType.iPhoneDuo
        #expect(DeviceType.named("iphone-18-pro") == t)
        #expect(t.modelIdentifier == "iPhone19,2" && t.productClass == "V63" && t.legacyAssetSuffix == "iphone")
        #expect(t.screen == DeviceScreen(width: 1206, height: 2622, scale: 3.0, pitch: 460.0) && t.extendedDisplayProperties)
        #expect(t.screen.pointWidth == 402 && t.screen.pointHeight == 874)
        // Same key set as the iPhone Duo; the values of §4.2 changed.
        #expect(Set(t.capabilities.keys) == Set(duo.capabilities.keys))
        let changed = Set(t.capabilities.keys.filter { t.capabilities[$0] != duo.capabilities[$0] })
        #expect(changed == ["ArtworkTraits", "ScreenDimensionsCapability", "subtype", "DeviceCornerRadius", "modelIdentifier",
                            "ThinningProductType", "ModelNumber", "RegulatoryModelNumber", "pearl-id", "touch-id", "RingerButtonCapability"])
        guard case .dictionary(let art) = t.capabilities["ArtworkTraits"], case .dictionary(let dims) = t.capabilities["ScreenDimensionsCapability"] else {
            Issue.record("dictionaries"); return
        }
        #expect(art["ArtworkDeviceProductDescription"] == .string("iPhone 18 Pro") && art["ArtworkDeviceSubType"] == .integer(2622)
                && art["CompatibleDeviceFallback"] == .string("iPhone18,1") && art["ArtworkDeviceScaleFactor"] == .real(3.0))
        #expect(dims["main-screen-width"] == .integer(1206) && dims["main-screen-height"] == .integer(2622)
                && dims["main-screen-scale"] == .real(3.0) && dims["main-screen-orientation"] == .real(0.0)
                && dims["main-screen-class"] == .integer(36) && dims["main-screen-pitch"] == .integer(460))
        #expect(t.capabilities["DeviceCornerRadius"] == .real(62.0) && t.capabilities["subtype"] == .integer(2622))
        #expect(t.capabilities["ModelNumber"] == .string("A3472") && t.capabilities["ThinningProductType"] == .string("iPhone19,2"))
        #expect(t.capabilities["pearl-id"] == .bool(true) && t.capabilities["touch-id"] == .bool(false)
                && t.capabilities["RingerButtonCapability"] == .bool(true))
        #expect(t.capabilities["idiom"] == .string("phone") && t.capabilities["watch-companion"] == .bool(true)
                && t.capabilities["DeviceSupportsDynamicIsland"] == .bool(true))
        // The written plist keeps the number types.
        let xml = String(decoding: try PropertyListSerialization.data(fromPropertyList: t.capabilitiesPlist, format: .xml, options: 0), as: UTF8.self)
        #expect(DeviceTypeTests.element(xml, "DeviceCornerRadius")?.tag == "real")
        #expect(DeviceTypeTests.element(xml, "main-screen-orientation")?.tag == "real")
        #expect(DeviceTypeTests.element(xml, "main-screen-width")?.tag == "integer")
    }

    @Test func defaultTypeFollowsTheRuntime() {
        #expect(DeviceType.default(for: .iOS, version: "27.1") == .iPhoneDuo)
        #expect(DeviceType.default(for: .iOS, version: "27.0") == .iPhone18Pro)
        #expect(DeviceType.default(for: .iOS, version: "") == .iPhoneDuo)
        #expect(DeviceType.default(for: .visionOS, version: "27.0") == .visionPro)
        #expect(!DeviceType.iPhoneDuo.runs(onVersion: "27.0") && DeviceType.iPhone18Pro.runs(onVersion: "27.0")
                && DeviceType.iPhone18Pro.runs(onVersion: "27.1") && DeviceType.iPadA16.runs(onVersion: "27.1"))
    }

    /// 27.0 refuses the iPhone Duo (iphone-types.md §1): nothing in DEV is written.
    @Test func iPhoneDuoIsRefusedOn27_0() throws {
        let fm = FileManager.default
        let base = DeviceTypeTests.tempDir("runtime-duo")
        defer { try? fm.removeItem(atPath: base) }
        let rr = base + "/rr", dev = base + "/dev"
        try VisionDeviceTypeTests.runtimeRoot(rr, productName: "iPhone OS", version: "27.0", build: "24A434")
        var duo = layout(dev, rr)
        duo.deviceType = .iPhoneDuo
        #expect(throws: DeviceTypeRuntimeMismatch.self) { try duo.prepare() }
        #expect(!fm.fileExists(atPath: dev))
        var phone = layout(dev, rr)
        phone.deviceType = .iPhone18Pro
        try phone.prepare()
        #expect(fm.contents(atPath: dev + "/ycode-device-type") == Data("iphone-18-pro\n".utf8))
        _ = duo
    }
}
