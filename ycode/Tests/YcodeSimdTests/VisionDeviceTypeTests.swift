import Foundation
import Testing
@testable import ycode_simd

/// visionOS R1 (specs/simulator/visionos.md §3, §7.1 V-1…V-4, §7.2 R1): the
/// Apple Vision Pro record, runtime detection by `ProductName`, the type and
/// runtime platform must agree, Ycode's guest images are retagged for the
/// visionOS simulator platform, and the iPhone Duo's output is unchanged.
struct VisionDeviceTypeTests {
    static func runtimeRoot(_ path: String, productName: String?, version: String, build: String) throws {
        let dir = path + "/System/Library/CoreServices"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var plist: [String: Any] = ["ProductVersion": version, "ProductBuildVersion": build]
        if let productName { plist["ProductName"] = productName }
        try DeviceTypeTests.xml(plist).write(to: URL(fileURLWithPath: dir + "/SystemVersion.plist"))
    }

    /// A minimal thin arm64 dylib image: header, one LC_BUILD_VERSION
    /// (platform 7, minos 27.0, sdk 27.1, no tools), one LC_ID_DYLIB-sized
    /// filler command, some payload.
    static func image(signed: Bool = false) -> Data {
        var b: [UInt8] = []
        func u32(_ v: UInt32) { for i in 0..<4 { b.append(UInt8(truncatingIfNeeded: v >> (8 * i))) } }
        let commands: [[UInt32]] = [[0x32, 24, 7, 0x001B_0000, 0x001B_0100, 0], [0x2A, 16, 0, 0]]
            + (signed ? [[0x1D, 16, 0x100, 0x10]] : [])
        u32(0xFEED_FACF); u32(0x0100_000C); u32(0); u32(6)
        u32(UInt32(commands.count)); u32(UInt32(commands.reduce(0) { $0 + Int($1[1]) })); u32(0); u32(0)
        for c in commands { c.forEach(u32) }
        b += Array(repeating: 0xAB, count: 64)
        return Data(b)
    }

    // MARK: The record (V-1, §3.3)

    @Test func visionProRecord() throws {
        let t = try #require(DeviceType.named("vision-pro"))
        #expect(t == .visionPro && t.platform == .visionOS && t.family == .vision)
        #expect(t.modelIdentifier == "RealityDevice14,1" && t.productClass == "N301" && t.legacyAssetSuffix == "")
        #expect(t.screen == DeviceScreen(width: 3840, height: 2160, scale: 2, pitch: 264))
        #expect(t.screen.pointWidth == 1920 && t.screen.pointHeight == 1080)
        #expect(!t.extendedDisplayProperties)
        #expect(t.displayUID == "731F1373-97EF-4DCA-BC31-14C516B3E06F")
        #expect(DeviceType.all.map(\.id) == ["iphone-duo", "iphone-18-pro", "ipad-a16", "ipad-pro-13-m5", "vision-pro"])
        #expect(DeviceType.default(for: .visionOS) == .visionPro)
        #expect(DeviceType.default(for: .iOS) == .iPhoneDuo)
        for other in [DeviceType.iPhoneDuo, .iPadA16, .iPadPro13M5] {
            #expect(other.platform == .iOS && other.displayUID == nil)
        }
    }

    @Test func visionProCapabilities() throws {
        let plist = DeviceCapabilities.plist(for: .visionPro)
        let xml = String(decoding: try DeviceTypeTests.xml(plist), as: UTF8.self)
        let caps = try #require(plist["capabilities"] as? [String: Any])
        let values: [String: (String, String)] = [
            "idiom": ("string", "vision"), "modelIdentifier": ("string", "RealityDevice14,1"),
            "ModelNumber": ("string", "A2117"), "RegulatoryModelNumber": ("string", "A2117"),
            "device-name": ("string", "Apple Vision Simulator"), "DeviceCornerRadius": ("real", "0"),
            "HomeButtonType": ("integer", "0"), "memoryClass": ("integer", "16"), "subtype": ("integer", "3648"),
            "graphicsClass": ("integer", "3"), "software-dimming-alpha": ("integer", "0"),
        ]
        for (key, want) in values { #expect(DeviceTypeTests.same(DeviceTypeTests.element(xml, key), want), "\(key)") }
        let artwork = String(decoding: try DeviceTypeTests.xml(try #require(caps["ArtworkTraits"] as? [String: Any])), as: UTF8.self)
        for (key, want) in [
            "ArtworkDeviceIdiom": ("string", "vision"), "ArtworkDeviceProductDescription": ("string", "Apple Vision Pro"),
            "ArtworkDeviceScaleFactor": ("real", "2"), "ArtworkDeviceSubType": ("integer", "3648"),
            "ArtworkDisplayGamut": ("string", "P3"), "CompatibleDeviceFallback": ("string", "iPad13,4"),
            "DevicePerformanceMemoryClass": ("integer", "16"), "GraphicsFeatureSetClass": ("string", "APPLE8"),
            "GraphicsFeatureSetFallbacks": ("string", "APPLE7:APPLE6:APPLE5:APPLE4:APPLE3:APPLE3v1:APPLE2:APPLE1:GLES2,0"),
        ] { #expect(DeviceTypeTests.same(DeviceTypeTests.element(artwork, key), want), "ArtworkTraits.\(key)") }
        let screen = String(decoding: try DeviceTypeTests.xml(try #require(caps["ScreenDimensionsCapability"] as? [String: Any])), as: UTF8.self)
        for (key, want) in [
            "main-screen-class": ("integer", "11"), "main-screen-width": ("integer", "3840"),
            "main-screen-height": ("integer", "2160"), "main-screen-orientation": ("real", "0"),
            "main-screen-pitch": ("integer", "264"), "main-screen-scale": ("real", "2"),
        ] { #expect(DeviceTypeTests.same(DeviceTypeTests.element(screen, key), want), "ScreenDimensionsCapability.\(key)") }
        for key in ["OysterCapability", "DeviceIsMuseCapable", "FloatingLiveAppOverlay", "PiPOverlay", "PiPPinned",
                    "DeviceSupports3DImagery", "DeviceSupports3DMaps", "metal", "ASTC", "hidpi", "microphone", "wifi",
                    "bluetooth", "location-services", "accelerometer", "multitasking", "HEVCDecoder8bitSupported",
                    "HEVCEncodingCapability", "VGDDUFPWHbX/Ie9RSI0yDQ", "arm64", "applicationInstallation"] {
            #expect(DeviceTypeTests.element(xml, key)?.tag == "true", "\(key)")
        }
        for key in ["telephony", "sms", "GPSCapability", "magnetometer", "touch-id", "pearl-id", "ipad", "HasThinBezel",
                    "always-on-time", "contains-cellular-radio", "watch-companion", "DeviceSupportsEnhancedMultitasking"] {
            #expect(DeviceTypeTests.element(xml, key)?.tag == "false", "\(key)")
        }
        for key in ["displays", "iconState", "marketing-name", "MainScreenClass", "hardware-keyboard"] {
            #expect(caps[key] == nil, "\(key) must be absent")
        }
    }

    // MARK: Environment and bootstrap (V-3, §3.4)

    @Test func visionProEnvironment() throws {
        let fm = FileManager.default
        let dev = DeviceTypeTests.tempDir("vision"), rr = dev + "-rr"
        defer { try? fm.removeItem(atPath: dev); try? fm.removeItem(atPath: rr) }
        try Self.runtimeRoot(rr, productName: "xrOS", version: "27.0", build: "24M362")
        var layout = DeviceLayout(dev: dev, runtimeRoot: rr, udid: "11111111-2222-3333-4444-555555555555", jobPaths: [], bootTime: 1)
        layout.deviceType = .visionPro
        layout.lean = nil
        layout.templatePath = nil
        #expect(layout.runtimePlatform() == .visionOS)
        let c = layout.child
        #expect(c["SIMULATOR_MODEL_IDENTIFIER"] == "RealityDevice14,1")
        #expect(c["SIMULATOR_PRODUCT_CLASS"] == "N301")
        #expect(c["SIMULATOR_LEGACY_ASSET_SUFFIX"] == "")
        #expect(c["SIMULATOR_MAINSCREEN_WIDTH"] == "3840" && c["SIMULATOR_MAINSCREEN_HEIGHT"] == "2160")
        #expect(c["SIMULATOR_MAINSCREEN_SCALE"] == "2.000000" && c["SIMULATOR_MAINSCREEN_PITCH"] == "264.000000")
        #expect(c["SIMULATOR_RUNTIME_VERSION"] == "27.0" && c["SIMULATOR_RUNTIME_BUILD_VERSION"] == "24M362")
        #expect(c["SIMULATOR_VERSION_INFO"]
            == "Ycode - Device: Ycode (11111111-2222-3333-4444-555555555555) - Runtime: visionOS 27.0 (24M362) - DeviceType: RealityDevice14,1")
        #expect(c["YCODE_FRAMEBUFFER_DISPLAY_UID"] == "731F1373-97EF-4DCA-BC31-14C516B3E06F")
        // The iPhone's set minus the two extended-display variables, plus Ycode's display id.
        var phone = layout
        phone.deviceType = .iPhoneDuo
        #expect(Set(phone.child.keys).subtracting(c.keys) == Set<String>(["SIMULATOR_EXTENDED_DISPLAY_PROPERTIES", "IPHONE_TVOUT_EXTENDED_PROPERTIES",
                                                               "YCODE_SIMHID_DEVICE_MOTION"])
            .union(DeviceType.foldDisplaysEnabled ? ["YCODE_FRAMEBUFFER_SECOND_DISPLAY"] : []))
        #expect(Set(c.keys).subtracting(phone.child.keys) == ["YCODE_FRAMEBUFFER_DISPLAY_UID"])
        try layout.prepare()
        #expect(fm.contents(atPath: layout.deviceTypePath) == Data("vision-pro\n".utf8))
        #expect(fm.contents(atPath: layout.capabilitiesPath) == (try DeviceTypeTests.xml(DeviceCapabilities.plist(for: .visionPro))))
    }

    // MARK: Type and runtime platform agree (V-1, V-2)

    @Test func platformMismatchIsRefused() throws {
        let fm = FileManager.default
        let base = DeviceTypeTests.tempDir("vplatform")
        defer { try? fm.removeItem(atPath: base) }
        let xr = base + "/xr", ios = base + "/ios", bare = base + "/bare"
        try Self.runtimeRoot(xr, productName: "xrOS", version: "27.0", build: "24M362")
        try Self.runtimeRoot(ios, productName: "iPhone OS", version: "27.1", build: "24A94401")
        try fm.createDirectory(atPath: bare, withIntermediateDirectories: true)
        for (rr, type, ok) in [(xr, DeviceType.iPhoneDuo, false), (xr, .iPadA16, false), (xr, .visionPro, true),
                               (ios, .visionPro, false), (ios, .iPhoneDuo, true), (bare, .visionPro, false), (bare, .iPadA16, true)] {
            var l = DeviceLayout(dev: base + "/dev-\(UUID().uuidString)", runtimeRoot: rr, udid: nil, jobPaths: [])
            l.deviceType = type
            l.lean = nil
            l.templatePath = nil
            if ok {
                try l.prepare()
            } else {
                #expect(throws: DeviceTypePlatformMismatch.self) { try l.prepare() }
                #expect(!fm.fileExists(atPath: l.dev), "nothing is written for a refused type")
            }
        }
    }

    /// A Vision Pro device cannot later boot as an iPhone on the same runtime
    /// (and vice versa): the recorded type and the platform both refuse it.
    @Test func visionDeviceKeepsItsType() throws {
        let fm = FileManager.default
        let base = DeviceTypeTests.tempDir("vkeep")
        defer { try? fm.removeItem(atPath: base) }
        let xr = base + "/xr", ios = base + "/ios"
        try Self.runtimeRoot(xr, productName: "xrOS", version: "27.0", build: "24M362")
        try Self.runtimeRoot(ios, productName: "iPhone OS", version: "27.1", build: "24A94401")
        var v = DeviceLayout(dev: base + "/dev", runtimeRoot: xr, udid: nil, jobPaths: [])
        v.deviceType = .visionPro
        v.lean = nil
        v.templatePath = nil
        try v.prepare()
        // The same DEV on the iOS runtime as an iPhone: the recorded type refuses it.
        var p = DeviceLayout(dev: base + "/dev", runtimeRoot: ios, udid: nil, jobPaths: [])
        p.lean = nil
        p.templatePath = nil
        #expect(throws: DeviceTypeMismatch.self) { try p.prepare() }
    }

    // MARK: Guest images for the visionOS simulator platform

    @Test func retagRewritesOnlyTheBuildVersion() throws {
        let original = Self.image()
        #expect(GuestImagePlatform.platform(of: original) == 7)
        let v = try #require(GuestImagePlatform.packedVersion("27.0"))
        #expect(v == 0x001B_0000)
        #expect(GuestImagePlatform.packedVersion("27.0.1") == 0x001B_0001)
        #expect(GuestImagePlatform.packedVersion("x") == nil)
        let out = try GuestImagePlatform.retagged(original, platform: 12, minOS: v, sdk: v)
        #expect(out.count == original.count)
        #expect(GuestImagePlatform.platform(of: out) == 12)
        let diff = zip(original, out).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        // platform (offset 40) and sdk (offset 48); minos was already 27.0.
        #expect(Set(diff).isSubset(of: Set(40..<52)))
        #expect(throws: GuestImagePlatform.Failure.self) {
            try GuestImagePlatform.retagged(Self.image(signed: true), platform: 12, minOS: v, sdk: v)
        }
        #expect(throws: GuestImagePlatform.Failure.self) {
            try GuestImagePlatform.retagged(Data([0xCA, 0xFE, 0xBA, 0xBE] + Array(repeating: 0, count: 40)), platform: 12, minOS: v, sdk: v)
        }
    }

    @Test func guestImagesAreAdaptedOnlyForVisionOS() throws {
        let fm = FileManager.default
        let base = DeviceTypeTests.tempDir("vimages")
        defer { try? fm.removeItem(atPath: base) }
        let xr = base + "/xr", ios = base + "/ios", src = base + "/src"
        try Self.runtimeRoot(xr, productName: "xrOS", version: "27.0", build: "24M362")
        try Self.runtimeRoot(ios, productName: "iPhone OS", version: "27.1", build: "24A94401")
        try fm.createDirectory(atPath: src + "/SimHID.framework", withIntermediateDirectories: true)
        let image = Self.image()
        try image.write(to: URL(fileURLWithPath: src + "/SimFramebuffer"))
        try image.write(to: URL(fileURLWithPath: src + "/SimHID.framework/SimHID"))
        try Data("<plist/>".utf8).write(to: URL(fileURLWithPath: src + "/SimHID.framework/Info.plist"))
        for (rr, type, platform) in [(ios, DeviceType.iPhoneDuo, UInt32(7)), (xr, .visionPro, UInt32(12))] {
            var l = DeviceLayout(dev: base + "/dev-\(type.id)", runtimeRoot: rr, udid: nil, jobPaths: [])
            l.deviceType = type
            l.lean = nil
            l.templatePath = nil
            l.framebufferLibrary = src + "/SimFramebuffer"
            l.hidBundle = src + "/SimHID.framework"
            try l.prepare()
            let fbPath = try #require(l.framebufferGuestPath), hidPath = try #require(l.hidGuestPath)
            let fb = try #require(fm.contents(atPath: fbPath))
            let hid = try #require(fm.contents(atPath: hidPath + "/SimHID"))
            #expect(GuestImagePlatform.platform(of: fb) == platform)
            #expect(GuestImagePlatform.platform(of: hid) == platform)
            if platform == 7 { #expect(fb == image && hid == image, "iOS: the copies are the built files, byte for byte") }
        }
        // A host-library copy is refreshed only when it differs.
        let target = base + "/hl/libsystem_kernel.dylib"
        _ = try GuestImagePlatform.adaptedCopy(of: src + "/SimFramebuffer", to: target, for: .visionOS, version: "27.0")
        let first = try fm.attributesOfItem(atPath: target)[.systemFileNumber] as? Int
        _ = try GuestImagePlatform.adaptedCopy(of: src + "/SimFramebuffer", to: target, for: .visionOS, version: "27.0")
        #expect(try fm.attributesOfItem(atPath: target)[.systemFileNumber] as? Int == first)
    }

    // MARK: iPhone Duo unchanged on an iOS runtime that names itself

    /// With a `ProductName` in the iOS runtime's SystemVersion.plist, the
    /// iPhone Duo's environment is the one DeviceTypeTests checks without
    /// it: same keys, "Runtime: iOS", no display id variable.
    @Test func iPhoneUnchangedWithProductName() throws {
        let fm = FileManager.default
        let dev = DeviceTypeTests.tempDir("iphone-pn"), rr = dev + "-rr", rr2 = dev + "-rr2"
        defer { for p in [dev, rr, rr2] { try? fm.removeItem(atPath: p) } }
        try Self.runtimeRoot(rr, productName: "iPhone OS", version: "27.1", build: "24A94401")
        try Self.runtimeRoot(rr2, productName: nil, version: "27.1", build: "24A94401")
        var a = DeviceLayout(dev: dev, runtimeRoot: rr, udid: "11111111-2222-3333-4444-555555555555", jobPaths: [], bootTime: 1_760_000_000)
        var b = DeviceLayout(dev: dev, runtimeRoot: rr2, udid: "11111111-2222-3333-4444-555555555555", jobPaths: [], bootTime: 1_760_000_000)
        a.lean = nil
        b.lean = nil
        #expect(a.runtimePlatform() == .iOS)
        // Everything but the runtime root's own path is the same.
        let strip: ([String: String]) -> [String: String] = { $0.mapValues { $0.replacingOccurrences(of: rr2, with: "RR").replacingOccurrences(of: rr, with: "RR") } }
        #expect(strip(a.child) == strip(b.child))
        #expect(a.child["YCODE_FRAMEBUFFER_DISPLAY_UID"] == nil)
        // The R1 diagnostics add nothing unless the host asks for them.
        if ProcessInfo.processInfo.environment["YCODE_FRAMEBUFFER_CALLS"] == nil,
           ProcessInfo.processInfo.environment["YCODE_CHILD_ENV"] == nil {
            #expect(a.child["YCODE_FRAMEBUFFER_CALLS"] == nil)
            #expect(a.child["DYLD_INSERT_LIBRARIES"] == nil)
        }
        #expect(a.child["SIMULATOR_VERSION_INFO"]?.contains("Runtime: iOS 27.1 (24A94401)") == true)
        #expect(try DeviceTypeTests.xml(DeviceCapabilities.plist(for: a.deviceType))
            == (try DeviceTypeTests.expectedDuoCapabilities(withDisplays: DeviceType.foldDisplaysEnabled)))
    }
}
