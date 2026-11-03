import Foundation
import Testing
@testable import ycode_simd

/// watchOS W1 (specs/simulator/watchos.md §3, §7.1 W-1, W-2, W-4, W-6): the
/// thirteen Apple Watch records, runtime detection by `ProductName` "Watch
/// OS", the type and runtime platform must agree, the bootstrap has no
/// extended-display variables, Ycode's guest images are retagged for platform
/// 9, and the watch lean list keeps the pairing daemons.
struct WatchDeviceTypeTests {
    static let ids = [
        "apple-watch-series-12-46mm", "apple-watch-series-12-42mm", "apple-watch-ultra-4-49mm",
        "apple-watch-series-11-46mm", "apple-watch-series-11-42mm", "apple-watch-series-10-46mm",
        "apple-watch-series-10-42mm", "apple-watch-series-9-45mm", "apple-watch-series-9-41mm",
        "apple-watch-ultra-3-49mm", "apple-watch-ultra-2-49mm", "apple-watch-se-3-44mm", "apple-watch-se-3-40mm",
    ]

    static func watchRuntime(_ path: String) throws {
        try VisionDeviceTypeTests.runtimeRoot(path, productName: "Watch OS", version: "27.0", build: "24R362")
    }

    static func caps(_ t: DeviceType) throws -> (xml: String, dict: [String: Any]) {
        let plist = DeviceCapabilities.plist(for: t)
        let xml = String(decoding: try DeviceTypeTests.xml(plist), as: UTF8.self)
        return (xml, try #require(plist["capabilities"] as? [String: Any]))
    }

    // MARK: The records (W-1, §3.1)

    @Test func thirteenWatchTypes() throws {
        #expect(DeviceType.watches.map(\.id) == Self.ids)
        #expect(Array(DeviceType.all.map(\.id).suffix(13)) == Self.ids)
        #expect(Set(DeviceType.all.map(\.id)).count == DeviceType.all.count, "ids are unique")
        // §3.1 per type: model, class, screen, corner radius, oldest runtime.
        let table: [(String, String, String, Int, Int, Double, String)] = [
            ("apple-watch-series-12-46mm", "Watch8,3", "N237b", 416, 496, 50, "27.0"),
            ("apple-watch-series-12-42mm", "Watch8,4", "N238s", 374, 446, 44, "27.0"),
            ("apple-watch-ultra-4-49mm", "Watch8,1", "N240", 422, 514, 57, "27.0"),
            ("apple-watch-series-11-46mm", "Watch7,18", "N227b", 416, 496, 50, "26.0"),
            ("apple-watch-series-11-42mm", "Watch7,17", "N227s", 374, 446, 44, "26.0"),
            ("apple-watch-series-10-46mm", "Watch7,9", "N217b", 416, 496, 50, "11.0"),
            ("apple-watch-series-10-42mm", "Watch7,8", "N217s", 374, 446, 44, "11.0"),
            ("apple-watch-series-9-45mm", "Watch7,4", "N208b", 396, 484, 42.5, "10.0"),
            ("apple-watch-series-9-41mm", "Watch7,3", "N208s", 352, 430, 38.5, "10.0"),
            ("apple-watch-ultra-3-49mm", "Watch7,12", "N230", 422, 514, 57, "26.0"),
            ("apple-watch-ultra-2-49mm", "Watch7,5", "N210", 410, 502, 54, "10.0"),
            ("apple-watch-se-3-44mm", "Watch7,16", "N244b", 368, 448, 34, "26.0"),
            ("apple-watch-se-3-40mm", "Watch7,13", "N243s", 324, 394, 28, "26.0"),
        ]
        for (id, model, cls, w, h, radius, min) in table {
            let t = try #require(DeviceType.named(id))
            #expect(t.family == .watch && t.platform == .watchOS, "\(id)")
            #expect(t.modelIdentifier == model && t.productClass == cls && t.legacyAssetSuffix == "", "\(id)")
            #expect(t.screen == DeviceScreen(width: w, height: h, scale: 2, pitch: 326), "\(id)")
            #expect(t.minRuntimeVersion == min && t.runs(onVersion: "27.0"), "\(id)")
            #expect(!t.extendedDisplayProperties && !t.pointerSystem && !t.isFoldable && t.displayUID == nil, "\(id)")
            #expect(t.capabilities["DeviceCornerRadius"] == .real(radius), "\(id)")
            // The crown and the always-on display everywhere; the Action button on the Ultras.
            #expect(t.features.isSuperset(of: DeviceType.watchFeatures), "\(id)")
            #expect(t.features.contains(DeviceType.actionButtonFeature) == id.contains("ultra"), "\(id)")
        }
        // Families agree with platforms for every type.
        for t in DeviceType.all { #expect((t.family == .watch) == (t.platform == .watchOS), "\(t.id)") }
    }

    @Test func defaultsOnWatchOS() {
        #expect(DeviceType.default(for: .watchOS).id == "apple-watch-series-12-46mm")
        #expect(DeviceType.default(for: .watchOS, version: "27.0").id == "apple-watch-series-12-46mm")
        #expect(DeviceType.default(for: .watchOS, version: "").id == "apple-watch-series-12-46mm")
        // On a 26.x runtime the 27.0 generation does not run: the first that does.
        #expect(DeviceType.default(for: .watchOS, version: "26.2").id == "apple-watch-series-11-46mm")
        // iOS and visionOS unchanged.
        #expect(DeviceType.default(for: .iOS, version: "27.1") == .iPhoneDuo)
        #expect(DeviceType.default(for: .iOS, version: "27.0") == .iPhone18Pro)
        #expect(DeviceType.default(for: .visionOS, version: "27.0") == .visionPro)
    }

    // MARK: Capabilities (§3.3)

    @Test func series12Capabilities() throws {
        let t = DeviceType.appleWatchSeries12_46mm
        let (xml, caps) = try Self.caps(t)
        let values: [String: (String, String)] = [
            "idiom": ("string", "watch"), "modelIdentifier": ("string", "Watch8,3"),
            "ThinningProductType": ("string", "Watch8,3"), "ModelNumber": ("string", "A3584"),
            "RegulatoryModelNumber": ("string", "A3584"), "device-name": ("string", "Watch Simulator"),
            "DeviceCornerRadius": ("real", "50"), "HomeButtonType": ("integer", "0"), "memoryClass": ("integer", "3"),
            "subtype": ("integer", "496"), "graphicsClass": ("integer", "0"), "software-dimming-alpha": ("integer", "0"),
            "graphicsFeatureSetClass": ("string", "APPLE11"), "displayGamut": ("string", "P3"),
        ]
        for (key, want) in values { #expect(DeviceTypeTests.same(DeviceTypeTests.element(xml, key), want), "\(key)") }
        let artwork = String(decoding: try DeviceTypeTests.xml(try #require(caps["ArtworkTraits"] as? [String: Any])), as: UTF8.self)
        for (key, want) in [
            "ArtworkDeviceIdiom": ("string", "watch"), "ArtworkDeviceProductDescription": ("string", "Apple Watch Series 12"),
            "ArtworkDeviceScaleFactor": ("real", "2"), "ArtworkDeviceSubType": ("integer", "496"),
            "ArtworkDisplayGamut": ("string", "P3"), "CompatibleDeviceFallback": ("string", "Watch7,18"),
            "DevicePerformanceMemoryClass": ("integer", "3"), "GraphicsFeatureSetClass": ("string", "APPLE11"),
        ] { #expect(DeviceTypeTests.same(DeviceTypeTests.element(artwork, key), want), "ArtworkTraits.\(key)") }
        let fallbacks = try #require((caps["ArtworkTraits"] as? [String: Any])?["GraphicsFeatureSetFallbacks"] as? String)
        #expect(fallbacks.hasPrefix("APPLE10:") && fallbacks.hasSuffix(":APPLE1:GLES2,0"))
        let screen = try #require(caps["ScreenDimensionsCapability"] as? [String: Any])
        #expect(screen["main-screen-class"] as? Int == 35)
        #expect(screen["main-screen-width"] as? Int == 416 && screen["main-screen-height"] as? Int == 496)
        #expect(screen["main-screen-pitch"] as? Int == 326 && screen["main-screen-scale"] as? Double == 2)
        let orientation = try #require(screen["main-screen-orientation"] as? Double)
        #expect(abs(orientation - 3 * Double.pi / 2) < 1e-6)
        for key in ["always-on-time", "hardware-detents", "GPSCapability", "magnetometer", "accelerometer", "microphone",
                    "bluetooth", "bluetooth-le", "wifi", "location-services", "DeviceSupportsSwimmingWorkouts",
                    "DeviceSupportsElton", "stand-alone-contacts", "encrypted-data-partition", "gas-gauge-battery", "ASTC",
                    "hidpi", "HEVCDecoder8bitSupported", "arm64", "applicationInstallation"] {
            #expect(DeviceTypeTests.element(xml, key)?.tag == "true", "\(key)")
        }
        for key in ["metal", "telephony", "sms", "contains-cellular-radio", "watch-companion", "touch-id", "pearl-id",
                    "ipad", "DeviceSupportsDynamicIsland", "720p", "screenrecorder", "OysterCapability"] {
            #expect(DeviceTypeTests.element(xml, key)?.tag == "false", "\(key)")
        }
        for key in ["displays", "iconState", "marketing-name", "WatchAppButtonCapability", "MainScreenClass"] {
            #expect(caps[key] == nil, "\(key) must be absent")
        }
        // The kept display entry (for W2): one integrated LCD, rotated 90.
        guard case .dictionary(let d)? = t.displays?.first else { Issue.record("no display entry"); return }
        #expect(d["displayName"] == .string("LCD") && d["deviceName"] == .string("primary") && d["screenID"] == .integer(1))
        #expect(d["width"] == .integer(416) && d["height"] == .integer(496) && d["hasDigitizer"] == .bool(true))
        #expect(d["nativeRotation"] == .integer(90) && d["cornerRadiusUL"] == .real(50))
        #expect(d["chromeIdentifier"] == .string("com.apple.dt.devicekit.chrome.watch5b"))
    }

    @Test func perTypeDifferences() throws {
        func value(_ id: String, _ key: String) throws -> CapabilityValue? { try #require(DeviceType.named(id)).capabilities[key] }
        // Cellular models (§3.3).
        for id in Self.ids {
            let cellular = ["apple-watch-series-12-42mm", "apple-watch-ultra-4-49mm", "apple-watch-series-9-45mm",
                            "apple-watch-series-9-41mm", "apple-watch-ultra-2-49mm", "apple-watch-ultra-3-49mm",
                            "apple-watch-se-3-44mm"].contains(id)
            for key in ["telephony", "sms", "contains-cellular-radio"] { #expect(try value(id, key) == .bool(cellular), "\(id) \(key)") }
            // arm64 false on Series 9 and 10 and Ultra 2.
            let arm64 = !(id.contains("series-9") || id.contains("series-10") || id.contains("ultra-2"))
            #expect(try value(id, "arm64") == .bool(arm64), "\(id) arm64")
            // The Action button capability on the Ultras only.
            #expect(try value(id, "WatchAppButtonCapability") == (id.contains("ultra") ? .bool(true) : nil), "\(id)")
            // The 27.0 generation: memory class 3, APPLE11 (Ycode decision for the others: 2, APPLE8).
            let current = id.contains("series-12") || id.contains("ultra-4")
            #expect(try value(id, "memoryClass") == .integer(current ? 3 : 2), "\(id)")
            #expect(try value(id, "graphicsFeatureSetClass") == .string(current ? "APPLE11" : "APPLE8"), "\(id)")
            let t = try #require(DeviceType.named(id))
            #expect(t.capabilities["subtype"] == .integer(t.screen.height), "\(id)")
        }
        // Model numbers only where the spec gives them.
        #expect(try value("apple-watch-se-3-40mm", "ModelNumber") == nil)
    }

    // MARK: Runtime detection (W-2)

    @Test func runtimeDetection() throws {
        #expect(RuntimePlatform(productName: "Watch OS") == .watchOS)
        #expect(RuntimePlatform(productName: "watchOS") == .iOS, "only the runtime's own name")
        #expect(RuntimePlatform(productName: "xrOS") == .visionOS)
        #expect(RuntimePlatform(productName: "iPhone OS") == .iOS && RuntimePlatform(productName: nil) == .iOS)
        #expect(RuntimePlatform.watchOS.machOPlatform == 9 && RuntimePlatform.iOS.machOPlatform == 7
            && RuntimePlatform.visionOS.machOPlatform == 12)
        #expect(RuntimePlatform.watchOS.displayName == "watchOS")
        let fm = FileManager.default
        let base = DeviceTypeTests.tempDir("wruntime")
        defer { try? fm.removeItem(atPath: base) }
        try Self.watchRuntime(base + "/rr")
        var l = DeviceLayout(dev: base + "/dev", runtimeRoot: base + "/rr", udid: nil, jobPaths: [])
        l.deviceType = .appleWatchSeries12_46mm
        l.lean = nil
        l.templatePath = nil
        #expect(l.runtimePlatform() == .watchOS)
        let version = l.runtimeVersion()
        #expect(version.version == "27.0" && version.build == "24R362")
        // Per-runtime state keyed by build: the record keeps the two-word name.
        let record = l.currentRuntimeRecord()
        #expect(record.line == "Watch OS 27.0 24R362\n")
        #expect(DeviceLayout.RuntimeRecord(line: record.line) == record)
        #expect(record.displayName == "watchOS 27.0 (24R362)")
        try l.prepare()
        try l.recordRuntime()
        #expect(DeviceLayout.recordedRuntime(in: l.dev) == record)
    }

    // MARK: Environment and bootstrap (W-4, §3.4)

    @Test func watchEnvironment() throws {
        let fm = FileManager.default
        let dev = DeviceTypeTests.tempDir("watch"), rr = dev + "-rr"
        defer { try? fm.removeItem(atPath: dev); try? fm.removeItem(atPath: rr) }
        try Self.watchRuntime(rr)
        var layout = DeviceLayout(dev: dev, runtimeRoot: rr, udid: "11111111-2222-3333-4444-555555555555", jobPaths: [], bootTime: 1)
        layout.deviceType = .appleWatchSeries12_46mm
        layout.lean = nil
        layout.templatePath = nil
        let c = layout.child
        #expect(c["SIMULATOR_MODEL_IDENTIFIER"] == "Watch8,3" && c["SIMULATOR_PRODUCT_CLASS"] == "N237b")
        #expect(c["SIMULATOR_LEGACY_ASSET_SUFFIX"] == "")
        #expect(c["SIMULATOR_MAINSCREEN_WIDTH"] == "416" && c["SIMULATOR_MAINSCREEN_HEIGHT"] == "496")
        #expect(c["SIMULATOR_MAINSCREEN_SCALE"] == "2.000000" && c["SIMULATOR_MAINSCREEN_PITCH"] == "326.000000")
        #expect(c["SIMULATOR_RUNTIME_VERSION"] == "27.0" && c["SIMULATOR_RUNTIME_BUILD_VERSION"] == "24R362")
        #expect(c["SIMULATOR_VERSION_INFO"]
            == "Ycode - Device: Ycode (11111111-2222-3333-4444-555555555555) - Runtime: watchOS 27.0 (24R362) - DeviceType: Watch8,3")
        #expect(c["YCODE_SIMHID_DEVICE_MOTION"] == nil)
        // W-9 (§12): the HID bundle publishes the Digital Crown service.
        #expect(c["YCODE_SIMHID_DIGITAL_CROWN"] == "1")
        // W-7: a display unique id of the device's own, stable, Ycode-marked.
        let uid = try #require(c["YCODE_FRAMEBUFFER_DISPLAY_UID"])
        #expect(uid == DeviceLayout.displayUID(forDevice: "11111111-2222-3333-4444-555555555555") && uid.hasPrefix("59434F44-"))
        #expect(uid.count == 36 && uid != "59434F44-4500-4000-8000-000000000001")
        #expect(DeviceLayout.displayUID(forDevice: "11111111-2222-3333-4444-555555555556") != uid)
        #expect(DeviceLayout.displayUID(forDevice: "11111111-2222-3333-4444-555555555555".lowercased()) == uid)
        // The iPhone's set minus the two extended-display variables (§3.4);
        // Ycode's own additions: the display id (W-7) and the crown service (W-9, §12).
        var phone = layout
        phone.deviceType = .iPhone18Pro
        #expect(Set(phone.child.keys).subtracting(c.keys) == ["SIMULATOR_EXTENDED_DISPLAY_PROPERTIES", "IPHONE_TVOUT_EXTENDED_PROPERTIES"])
        #expect(Set(c.keys).subtracting(phone.child.keys) == ["YCODE_FRAMEBUFFER_DISPLAY_UID", "YCODE_SIMHID_DIGITAL_CROWN"])
        #expect(phone.child["YCODE_FRAMEBUFFER_DISPLAY_UID"] == nil, "the iOS types keep the library's constant")
        // §5.2: the Action button's pair only on the Ultra types.
        #expect(c["YCODE_SIMHID_ACTION_BUTTON"] == nil)
        var ultra = layout
        ultra.deviceType = try #require(DeviceType.watches.first { $0.id == "apple-watch-ultra-4-49mm" })
        #expect(ultra.child["YCODE_SIMHID_ACTION_BUTTON"] == "1" && ultra.child["YCODE_SIMHID_DIGITAL_CROWN"] == "1")
        try layout.prepare()
        #expect(fm.contents(atPath: layout.deviceTypePath) == Data("apple-watch-series-12-46mm\n".utf8))
        #expect(fm.contents(atPath: layout.capabilitiesPath) == (try DeviceTypeTests.xml(DeviceCapabilities.plist(for: .appleWatchSeries12_46mm))))
        let data = try #require(fm.contents(atPath: layout.plistPath))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let child = try #require((plist["Bootstrap"] as? [String: Any])?["Child"] as? [String: String])
        #expect(child["SIMULATOR_EXTENDED_DISPLAY_PROPERTIES"] == nil && child["IPHONE_TVOUT_EXTENDED_PROPERTIES"] == nil)
    }

    // MARK: Type and runtime platform agree (W-1)

    @Test func platformMismatchIsRefused() throws {
        let fm = FileManager.default
        let base = DeviceTypeTests.tempDir("wplatform")
        defer { try? fm.removeItem(atPath: base) }
        let watch = base + "/watch", ios = base + "/ios", xr = base + "/xr"
        try Self.watchRuntime(watch)
        try VisionDeviceTypeTests.runtimeRoot(ios, productName: "iPhone OS", version: "27.1", build: "24A94401")
        try VisionDeviceTypeTests.runtimeRoot(xr, productName: "xrOS", version: "27.0", build: "24M362")
        let ultra = try #require(DeviceType.named("apple-watch-ultra-4-49mm"))
        for (rr, type, ok) in [(watch, DeviceType.appleWatchSeries12_46mm, true), (watch, ultra, true),
                               (watch, .iPhone18Pro, false), (watch, .iPadA16, false), (watch, .visionPro, false),
                               (ios, .appleWatchSeries12_46mm, false), (xr, ultra, false)] {
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
        // The refusal names the watch types for a watch runtime.
        let message = DeviceTypePlatformMismatch(type: .iPhone18Pro, runtime: .watchOS, runtimeRoot: watch).description
        #expect(message.contains("apple-watch-series-12-46mm") && !message.contains("iphone-duo"))
    }

    // MARK: Guest images for platform 9

    @Test func guestImagesAreRetaggedForWatchOS() throws {
        let fm = FileManager.default
        let base = DeviceTypeTests.tempDir("wimages")
        defer { try? fm.removeItem(atPath: base) }
        let rr = base + "/rr", src = base + "/src"
        try Self.watchRuntime(rr)
        try fm.createDirectory(atPath: src + "/SimHID.framework", withIntermediateDirectories: true)
        let image = VisionDeviceTypeTests.image()
        try image.write(to: URL(fileURLWithPath: src + "/SimFramebuffer"))
        try image.write(to: URL(fileURLWithPath: src + "/SimHID.framework/SimHID"))
        var l = DeviceLayout(dev: base + "/dev", runtimeRoot: rr, udid: nil, jobPaths: [])
        l.deviceType = .appleWatchSeries12_46mm
        l.lean = nil
        l.templatePath = nil
        l.framebufferLibrary = src + "/SimFramebuffer"
        l.hidBundle = src + "/SimHID.framework"
        try l.prepare()
        let fbPath = try #require(l.framebufferGuestPath), hidPath = try #require(l.hidGuestPath)
        let fb = try #require(fm.contents(atPath: fbPath))
        let hid = try #require(fm.contents(atPath: hidPath + "/SimHID"))
        #expect(GuestImagePlatform.platform(of: fb) == 9 && GuestImagePlatform.platform(of: hid) == 9)
    }

    // MARK: Lean boot (W-6)

    @Test func watchLeanListKeepsThePairingPath() throws {
        let watch = try #require(LeanBootProfile.from(environment: ["YCODE_LEAN_BOOT": "1"], platform: .watchOS))
        let phone = try #require(LeanBootProfile.from(environment: ["YCODE_LEAN_BOOT": "1"], platform: .iOS))
        #expect(phone.disabledLabels == LeanBootProfile.defaultDisabledLabels)
        #expect(watch.disabledLabels == LeanBootProfile.watchOSDisabledLabels)
        for label in ["com.apple.nanoregistrylaunchd", "com.apple.pairedsyncd", "com.apple.nanoregistryd", "com.apple.ids_simd",
                      "com.apple.Carousel", "com.apple.backboardd"] {
            #expect(!watch.disabledLabels.contains(label), "\(label)")
        }
        #expect(watch.disabledLabels.contains("com.apple.suggestd"))
        #expect(LeanBootProfile.from(environment: [:], platform: .watchOS) == nil, "off by default")
    }
}
