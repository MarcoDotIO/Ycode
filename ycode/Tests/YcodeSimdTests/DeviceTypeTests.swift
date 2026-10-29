import Foundation
import Testing
@testable import ycode_simd

/// Device types (specs/simulator/ipad.md §3, §4, §9 round 1): the iPhone Duo
/// output is unchanged byte for byte, the iPad records match the spec's
/// tables key by key with their number types, and a device keeps its type.
struct DeviceTypeTests {
    // MARK: Helpers

    static func xml(_ plist: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// The XML element that follows `<key>key</key>` (its tag name:
    /// integer, real, string, true, false, dict) and its text.
    static func element(_ xml: String, _ key: String) -> (tag: String, text: String)? {
        guard let k = xml.range(of: "<key>\(key)</key>") else { return nil }
        let rest = xml[k.upperBound...].drop { $0.isWhitespace }
        guard rest.first == "<", let close = rest.firstIndex(of: ">") else { return nil }
        var tag = String(rest[rest.index(after: rest.startIndex)..<close])
        if tag.hasSuffix("/") { tag.removeLast(); return (tag, "") }
        let body = rest[rest.index(after: close)...]
        let end = body.range(of: "</\(tag)>")?.lowerBound ?? body.endIndex
        return (tag, String(body[..<end]))
    }

    static func tempDir(_ name: String) -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("ycode-\(name)-\(UUID().uuidString)").path
    }

    // MARK: iPhone Duo: unchanged

    /// The capabilities generator as it was before device types (frozen
    /// copy of DeviceCapabilities.plist at 3a5490d). Do not edit.
    enum Legacy {
        /// The plist: {capabilities: {...}}.
        static func plist(width: Int, height: Int, scale: Double, pitch: Double, model: String) -> [String: Any] {
            let fallbacks = "APPLE10:APPLE9:APPLE8:APPLE7:APPLE6:APPLE5:APPLE4:APPLE3:APPLE3v1:APPLE2:APPLE1:GLES2,0"
            let artwork: [String: Any] = [
                "ArtworkDeviceIdiom": "phone",
                "ArtworkDeviceProductDescription": "iPhone",
                "ArtworkDeviceScaleFactor": Int(scale),
                "ArtworkDeviceSubType": height,
                "ArtworkDisplayGamut": "P3",
                "ArtworkDynamicDisplayMode": "0",
                "CompatibleDeviceFallback": "iPhone18,3",
                "DevicePerformanceMemoryClass": 12,
                "GraphicsFeatureSetClass": "APPLE11",
                "GraphicsFeatureSetFallbacks": fallbacks,
            ]
            let screen: [String: Any] = [
                "main-screen-class": 36,
                "main-screen-height": height,
                "main-screen-orientation": 0,
                "main-screen-pitch": Int(pitch),
                "main-screen-scale": Int(scale),
                "main-screen-width": width,
            ]
            var c: [String: Any] = [
                "ArtworkTraits": artwork,
                "ScreenDimensionsCapability": screen,
                "DeviceCornerRadius": 59,
                "displayGamut": "P3",
                "graphicsFeatureSetClass": "APPLE11",
                "graphicsFeatureSetFallbacks": fallbacks,
                "HomeButtonType": 2,
                "idiom": "phone",
                "MainScreenClass": 18,
                "memoryClass": 12,
                "modelIdentifier": model,
                "ThinningProductType": model,
                "ModelNumber": "A3447",
                "RegulatoryModelNumber": "A3447",
                "device-name": "iPhone Simulator",
                "subtype": height,
                "software-dimming-alpha": 0,
            ]
            for key in ["720p", "accelerometer", "accessibility", "always-on-time", "applicationInstallation", "arm64",
                        "armv6", "armv7", "armv7s", "ASTC", "bluetooth", "bluetooth-le", "cellular-data",
                        "contains-cellular-radio", "DeviceSupports3DImagery", "DeviceSupports3DMaps",
                        "DeviceSupportsAdaptiveMapsUI", "DeviceSupportsAdvancedMapRendering", "DeviceSupportsDynamicIsland",
                        "DeviceSupportsHiResBuildings", "displayport", "encrypted-data-partition", "full-6", "gamekit",
                        "gas-gauge-battery", "GPSCapability", "hardware-keyboard", "HasThinBezel", "HEVCDecoder8bitSupported",
                        "HEVCDecoder10bitSupported", "HEVCDecoder12bitSupported", "HEVCEncodingCapability", "hidpi",
                        "homescreen-wallpaper", "international-settings", "IsLargeFormatPhone",
                        "load-thumbnails-while-scrolling", "location-services", "magnetometer", "metal", "microphone",
                        "multitasking", "opengles-1", "opengles-2", "peer-peer", "screenrecorder", "shoebox", "sms",
                        "stand-alone-contacts", "telephony", "touch-id", "unified-ipod", "watch-companion", "wifi"] {
                c[key] = true
            }
            for key in ["DeviceIsMuseCapable", "DeviceSupportsElton", "DeviceSupportsEnhancedMultitasking",
                        "DeviceSupportsSingleDisplayEnhancedMultitasking", "FloatingLiveAppOverlay", "hide-non-default-apps",
                        "ipad", "MLEHW", "OysterCapability", "pearl-id", "PiPOverlay", "PiPPinned", "reverse-zoom",
                        "ringer-switch", "RingerButtonCapability", "SupportsForceTouch"] {
                c[key] = false
            }
            return ["capabilities": c]
        }

        /// The identity part of DeviceLayout.child before device types.
        static let identity: [String: String] = [
            "SIMULATOR_DEVICE_NAME": "Ycode",
            "SIMULATOR_MODEL_IDENTIFIER": "iPhone19,4",
            "SIMULATOR_PRODUCT_CLASS": "V68",
            "SIMULATOR_LEGACY_ASSET_SUFFIX": "iphone",
            "SIMULATOR_MAINSCREEN_WIDTH": "1398",
            "SIMULATOR_MAINSCREEN_HEIGHT": "2034",
            "SIMULATOR_MAINSCREEN_SCALE": "3.000000",
            "SIMULATOR_MAINSCREEN_PITCH": "460.000000",
        ]
    }

    /// The legacy file plus, when the inner panel is published, the
    /// `displays` list (device-capabilities.md §3.1; foldable.md §9 Q7).
    static func expectedDuoCapabilities(withDisplays: Bool) throws -> Data {
        var plist = Legacy.plist(width: 1398, height: 2034, scale: 3.0, pitch: 460.0, model: "iPhone19,4")
        if withDisplays, var c = plist["capabilities"] as? [String: Any] {
            c["displays"] = DisplayEntry.iPhoneDuo.map(\.capability.propertyList)
            plist["capabilities"] = c
        }
        return try xml(plist)
    }

    @Test func iPhoneCapabilitiesUnchangedByteForByte() throws {
        let legacy = try Self.xml(Legacy.plist(width: 1398, height: 2034, scale: 3.0, pitch: 460.0, model: "iPhone19,4"))
        // Without the inner panel (YCODE_FOLD_DISPLAYS=0): byte for byte as before.
        #expect(try Self.xml(DeviceType.iPhoneDuo.capabilitiesPlist(withDisplays: false)) == legacy)
        // With it (the default): the same plus `displays`.
        #expect(try Self.xml(DeviceType.iPhoneDuo.capabilitiesPlist(withDisplays: true)) == (try Self.expectedDuoCapabilities(withDisplays: true)))
        #expect(try Self.xml(DeviceCapabilities.plist(for: .iPhoneDuo))
            == (try Self.expectedDuoCapabilities(withDisplays: DeviceType.foldDisplaysEnabled)))
        #expect(DeviceType.default == .iPhoneDuo)
        // No other type has a `displays` list.
        for t in DeviceType.all where t != .iPhoneDuo {
            #expect(t.displays == nil && (t.capabilitiesPlist(withDisplays: true)["capabilities"] as? [String: Any])?["displays"] == nil, "\(t.id)")
        }
    }

    /// The iPhone Duo's `displays` list key by key with its plist types
    /// (device-capabilities.md §3.1), and in agreement with the displays
    /// Ycode publishes (names, ids, sizes; simframebuffer.md §4, §10).
    @Test func iPhoneDuoDisplaysList() throws {
        let plist = DeviceType.iPhoneDuo.capabilitiesPlist(withDisplays: true)
        let data = try Self.xml(plist)
        let back = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let caps = try #require(back["capabilities"] as? [String: Any])
        #expect(back.keys.sorted() == ["capabilities"])
        let list = try #require(caps["displays"] as? [[String: Any]])
        #expect(list.map { $0["displayName"] as? String } == ["LCD", "TVOut", "LCD-1", "Wireless", "Resizable"])
        #expect(list.map { $0["deviceName"] as? String } == ["primary", "external-0", "primary-1", "wireless0", "resizable"])
        #expect(list.map { $0["displayType"] as? String } == ["integrated", "tvOut", "integrated", "carPlay", "scene"])
        #expect(list.map { $0["screenID"] as? Int } == [1, 2, 3, 4, 5])
        #expect(list.map { $0["width"] as? Int } == [1398, 720, 2007, 720, 7680])
        #expect(list.map { $0["height"] as? Int } == [2034, 480, 2853, 480, 4320])
        #expect(list.map { $0["scale"] as? Double } == [3, 1, 3, 1, 3])
        #expect(list.map { $0["hdpi"] as? Double } == [460, 72, 460, 72, 120] && list.map { $0["vdpi"] as? Double } == [460, 72, 460, 72, 120])
        #expect(list.map { $0["refreshRate"] as? Double } == [60, 60, 60, 60, 60])
        #expect(list.map { $0["colorspace"] as? String } == ["P3", "sRGB", "sRGB", "sRGB", "sRGB"])
        #expect(list.map { $0["powerState"] as? Int } == [1, 0, 1, 0, 0])
        #expect(list.map { $0["hasDigitizer"] as? Bool } == [true, false, true, false, true])
        #expect(list.map { $0["surfaceType"] as? Int } == [1, nil, 2, nil, nil])
        #expect(list.map { $0["nativeOrientation"] as? Int } == [0, nil, 270, nil, nil])
        #expect(list.map { $0["nativeRotation"] as? Int } == [0, nil, 270, nil, nil])
        #expect(list.map { $0["cornerRadiusUL"] as? Double } == [8, nil, 55, nil, 0])
        #expect(list.map { $0["cornerRadiusLL"] as? Double } == [8, nil, 55, nil, 0])
        #expect(list.map { $0["cornerRadiusUR"] as? Double } == [59, nil, 55, nil, 0])
        #expect(list.map { $0["cornerRadiusLR"] as? Double } == [59, nil, 55, nil, 0])
        #expect(list.map { $0["chromeIdentifier"] as? String }
            == ["com.apple.dt.devicekit.chrome.phone15", nil, "com.apple.dt.devicekit.chrome.phone14", nil, nil])
        #expect(list.map { $0["framebufferMaskIdentifier"] as? String }
            == ["1C896A2B-F0D7-405C-8D0F-66E4B80AD044", nil, "BF0DC480-5EE2-4EC1-B02B-C75E94759832", nil, nil])
        #expect(list.map { $0["requiredFeatures"] as? [String] }
            == [nil, nil, nil, nil, ["com.apple.CoreSimulator.display.resizableScene"]])
        // Key counts: 22 per built-in panel (the twenty that worked on the
        // reference plus colorspace and refreshRate), 13 for TV-out and
        // wireless, 18 for the resizable display.
        #expect(list.map(\.count) == [22, 13, 22, 13, 18])
        // The plist types (integer vs real vs boolean) of §3.1.
        let text = String(decoding: data, as: UTF8.self)
        #expect(Self.element(text, "surfaceType")?.tag == "integer" && Self.element(text, "screenID")?.tag == "integer")
        #expect(Self.element(text, "scale")?.tag == "real" && Self.element(text, "hdpi")?.tag == "real"
            && Self.element(text, "cornerRadiusUL")?.tag == "real" && Self.element(text, "refreshRate")?.tag == "real")
        #expect(Self.element(text, "hasDigitizer")?.tag == "true" && Self.element(text, "nativeRotation")?.tag == "integer")
        // Agreement with the published displays: the cover is the main
        // screen, the inner entry is the second display Ycode publishes.
        let duo = DeviceType.iPhoneDuo, inner = try #require(duo.secondDisplay)
        #expect(list[0]["width"] as? Int == duo.screen.width && list[0]["height"] as? Int == duo.screen.height)
        #expect(list[2]["screenID"] as? Int == inner.id && list[2]["displayName"] as? String == inner.name
            && list[2]["deviceName"] as? String == inner.deviceName && list[2]["width"] as? Int == inner.width
            && list[2]["height"] as? Int == inner.height && list[2]["nativeRotation"] as? Int == inner.mountRotation)
    }

    @Test func iPhoneDeviceDirectoryUnchanged() throws {
        let fm = FileManager.default
        let dev = Self.tempDir("iphone"), rr = dev + "-rr"
        defer { try? fm.removeItem(atPath: dev); try? fm.removeItem(atPath: rr) }
        try fm.createDirectory(atPath: rr + "/System/Library/CoreServices", withIntermediateDirectories: true)
        try Self.xml(["ProductVersion": "27.1", "ProductBuildVersion": "24A94401"])
            .write(to: URL(fileURLWithPath: rr + "/System/Library/CoreServices/SystemVersion.plist"))
        var layout = DeviceLayout(dev: dev, runtimeRoot: rr, udid: "11111111-2222-3333-4444-555555555555", jobPaths: [],
                                  bootTime: 1_760_000_000)
        layout.lean = nil
        layout.templatePath = nil
        try layout.prepare()
        // The capabilities file as before, plus `displays` with the inner panel.
        #expect(fm.contents(atPath: layout.capabilitiesPath) == (try Self.expectedDuoCapabilities(withDisplays: DeviceType.foldDisplaysEnabled)))
        // The environment: every variable as before, with the same values.
        let child = layout.child
        for (key, value) in Legacy.identity { #expect(child[key] == value, "\(key)") }
        #expect(child["SIMULATOR_EXTENDED_DISPLAY_PROPERTIES"] == layout.extendedDisplayPath)
        #expect(child["IPHONE_TVOUT_EXTENDED_PROPERTIES"] == layout.extendedDisplayPath)
        #expect(child["SIMULATOR_VERSION_INFO"]
            == "Ycode - Device: Ycode (11111111-2222-3333-4444-555555555555) - Runtime: iOS 27.1 (24A94401) - DeviceType: iPhone19,4")
        let expectedKeys = Set<String>([
            "DYLD_ROOT_PATH", "IPHONE_SIMULATOR_ROOT", "SIMULATOR_ROOT", "DYLD_SHARED_CACHE_DIR", "PATH",
            "IPHONE_SHARED_RESOURCES_DIRECTORY", "SIMULATOR_SHARED_RESOURCES_DIRECTORY", "XPC_SIMULATOR_LAUNCHD_NAME",
            "LS_ENABLE_BUNDLE_LOCALIZATION_CACHING", "SIMULATOR_UDID", "SIMULATOR_DEVICE_NAME",
            "SIMULATOR_MODEL_IDENTIFIER", "SIMULATOR_PRODUCT_CLASS", "SIMULATOR_LEGACY_ASSET_SUFFIX",
            "SIMULATOR_MAINSCREEN_WIDTH", "SIMULATOR_MAINSCREEN_HEIGHT", "SIMULATOR_MAINSCREEN_SCALE",
            "SIMULATOR_MAINSCREEN_PITCH", "SIMULATOR_CAPABILITIES", "SIMULATOR_RUNTIME_VERSION",
            "SIMULATOR_RUNTIME_BUILD_VERSION", "SIMULATOR_ARCHS", "SIMULATOR_VERSION_INFO", "SIMULATOR_BOOT_TIME",
            "SIMULATOR_HOST_HOME", "SIMULATOR_LOG_ROOT", "SIMULATOR_FRAMEBUFFER_FRAMEWORK", "YCODE_FRAMEBUFFER_STATE",
            "YCODE_FRAMEBUFFER_TIMING", "YCODE_SIMHID_TIMING", "YCODE_FRAMEBUFFER_COMPLETION",
            "SIMULATOR_HID_SYSTEM_MANAGER", "YCODE_SIMHID_LOG", "SIMULATOR_AUDIO_DEVICES_PLIST_PATH",
            "SIMULATOR_AUDIO_SETTINGS_PATH", "SIMULATOR_MEMORY_WARNINGS", "SIMULATOR_EXTENDED_DISPLAY_PROPERTIES",
            "IPHONE_TVOUT_EXTENDED_PROPERTIES", "YCODE_SIMHID_DEVICE_MOTION",
        ]).union(DeviceType.foldDisplaysEnabled ? ["YCODE_FRAMEBUFFER_SECOND_DISPLAY"] : [])
        #expect(Set(child.keys) == expectedKeys)
        // The hinge input (foldable.md §8.2 I2); the inner panel by default
        // (not with YCODE_FOLD_DISPLAYS=0).
        #expect(child["YCODE_SIMHID_DEVICE_MOTION"] == "1")
        #expect(child["YCODE_FRAMEBUFFER_SECOND_DISPLAY"]
            == (DeviceType.foldDisplaysEnabled ? "3 LCD-1 primary-1 2007 2853 3 460 59434F44-4500-4000-8000-000000000003" : nil))
        #expect(DeviceType.iPhoneDuo.secondDisplay?.environmentValue == "3 LCD-1 primary-1 2007 2853 3 460 59434F44-4500-4000-8000-000000000003")
        // The bootstrap plist is the one these values make.
        #expect(fm.contents(atPath: layout.plistPath) == (try Self.xml(layout.bootstrapPlist)))
        // The type is recorded.
        #expect(fm.contents(atPath: layout.deviceTypePath) == Data("iphone-duo\n".utf8))
        // Deliberate change since 391af58 (ipad.md §10 Q8): a new device
        // also gets its first-boot global preferences, US English.
        let prefs = try #require(fm.contents(atPath: layout.globalPreferencesPath))
        #expect(prefs == (try Self.xml(["AppleLanguages": ["en-US"], "AppleLocale": "en_US"])))
    }

    /// ipad.md §10 Q8: only a device that never booted gets the first-boot
    /// region; existing preferences and booted devices are left alone.
    @Test func firstBootLocaleOnlyForNewDevices() throws {
        let fm = FileManager.default
        let base = Self.tempDir("locale"), rr = base + "/rr"
        defer { try? fm.removeItem(atPath: base) }
        try fm.createDirectory(atPath: rr, withIntermediateDirectories: true)
        // A booted device without a type record or preferences.
        let booted = base + "/booted"
        try fm.createDirectory(atPath: booted + "/data/var/run", withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: booted + "/data/var/run/launchd_bootstrap.plist"))
        var a = DeviceLayout(dev: booted, runtimeRoot: rr, udid: "11111111-2222-3333-4444-555555555555", jobPaths: [],
                             bootTime: 1_760_000_000)
        a.lean = nil
        a.templatePath = nil
        try a.prepare()
        #expect(!fm.fileExists(atPath: a.globalPreferencesPath))
        // A new device whose data already has preferences keeps them.
        let seeded = base + "/seeded"
        try fm.createDirectory(atPath: seeded + "/data/Library/Preferences", withIntermediateDirectories: true)
        let mine = try Self.xml(["AppleLocale": "en_GB"])
        try mine.write(to: URL(fileURLWithPath: seeded + "/data/Library/Preferences/.GlobalPreferences.plist"))
        var b = DeviceLayout(dev: seeded, runtimeRoot: rr, udid: "11111111-2222-3333-4444-555555555556", jobPaths: [],
                             bootTime: 1_760_000_000)
        b.lean = nil
        b.templatePath = nil
        try b.prepare()
        #expect(fm.contents(atPath: b.globalPreferencesPath) == mine)
    }

    // MARK: iPads (ipad.md §4.1, §4.2)

    struct PadExpectation {
        let type: DeviceType
        let model, productClass, width, height: String
        let artwork: [String: (String, String)]
        let screen: [String: (String, String)]
        let values: [String: (String, String)]
        let differing: [String: Bool]
    }

    static let padTrue = [
        "720p", "accelerometer", "accessibility", "applicationInstallation", "arm64", "armv6", "armv7", "armv7s",
        "ASTC", "bluetooth", "DeviceSupports3DImagery", "DeviceSupports3DMaps", "DeviceSupportsAdaptiveMapsUI",
        "DeviceSupportsAdvancedMapRendering", "DeviceSupportsHiResBuildings", "displayport",
        "encrypted-data-partition", "FloatingLiveAppOverlay", "full-6", "gamekit", "gas-gauge-battery",
        "HasThinBezel", "HEVCDecoder8bitSupported", "HEVCDecoder10bitSupported", "HEVCDecoder12bitSupported",
        "HEVCEncodingCapability", "hide-non-default-apps", "hidpi", "homescreen-wallpaper",
        "international-settings", "ipad", "load-thumbnails-while-scrolling", "location-services", "magnetometer",
        "metal", "microphone", "multitasking", "opengles-1", "opengles-2", "peer-peer", "PiPOverlay", "PiPPinned",
        "screenrecorder", "stand-alone-contacts", "wifi",
    ]
    static let padFalse = [
        "always-on-time", "DeviceSupportsDynamicIsland", "DeviceSupportsElton",
        "DeviceSupportsSingleDisplayEnhancedMultitasking", "MLEHW", "OysterCapability", "ringer-switch",
        "RingerButtonCapability", "sms", "SupportsForceTouch", "telephony", "unified-ipod", "watch-companion",
    ]
    static let padAbsent = [
        "hardware-keyboard", "MainScreenClass", "IsLargeFormatPhone", "shoebox", "bluetooth-le", "cellular-data",
        "DeviceIsMuseCapable", "displays", "iconState", "marketing-name",
    ]

    static let pads: [PadExpectation] = [
        PadExpectation(
            type: .iPadA16, model: "iPad15,7", productClass: "J481", width: "1640", height: "2360",
            artwork: ["ArtworkDeviceIdiom": ("string", "pad"), "ArtworkDeviceProductDescription": ("string", "iPad (A16)"),
                      "ArtworkDeviceScaleFactor": ("real", "2"), "ArtworkDeviceSubType": ("integer", "2360"),
                      "ArtworkDisplayGamut": ("string", "sRGB"), "ArtworkDynamicDisplayMode": ("string", "0"),
                      "CompatibleDeviceFallback": ("string", "iPad13,18"), "DevicePerformanceMemoryClass": ("integer", "6"),
                      "GraphicsFeatureSetClass": ("string", "APPLE8"),
                      "GraphicsFeatureSetFallbacks": ("string", "APPLE7:APPLE6:APPLE5:APPLE4:APPLE3:APPLE3v1:APPLE2:APPLE1:GLES2,0")],
            screen: ["main-screen-class": ("integer", "23"), "main-screen-height": ("integer", "2360"),
                     "main-screen-orientation": ("real", "0"), "main-screen-pitch": ("integer", "264"),
                     "main-screen-scale": ("real", "2"), "main-screen-width": ("integer", "1640")],
            values: ["idiom": ("string", "pad"), "modelIdentifier": ("string", "iPad15,7"),
                     "ThinningProductType": ("string", "iPad15,7"), "ModelNumber": ("string", "A3354"),
                     "RegulatoryModelNumber": ("string", "A3354"), "device-name": ("string", "iPad Simulator"),
                     "DeviceCornerRadius": ("real", "25"), "HomeButtonType": ("integer", "2"), "memoryClass": ("integer", "6"),
                     "subtype": ("integer", "2360"), "software-dimming-alpha": ("integer", "0"), "graphicsClass": ("integer", "3"),
                     "displayGamut": ("string", "sRGB"), "graphicsFeatureSetClass": ("string", "APPLE8"),
                     "graphicsFeatureSetFallbacks": ("string", "APPLE7:APPLE6:APPLE5:APPLE4:APPLE3:APPLE3v1:APPLE2:APPLE1:GLES2,0")],
            differing: ["touch-id": true, "pearl-id": false, "DeviceSupportsEnhancedMultitasking": false,
                        "GPSCapability": false, "contains-cellular-radio": false, "reverse-zoom": false]),
        PadExpectation(
            type: .iPadPro13M5, model: "iPad17,4", productClass: "J821", width: "2064", height: "2752",
            artwork: ["ArtworkDeviceIdiom": ("string", "pad"), "ArtworkDeviceProductDescription": ("string", "iPad Pro 13-inch (M5)"),
                      "ArtworkDeviceScaleFactor": ("real", "2"), "ArtworkDeviceSubType": ("integer", "2752"),
                      "ArtworkDisplayGamut": ("string", "P3"), "ArtworkDynamicDisplayMode": ("string", "0"),
                      "CompatibleDeviceFallback": ("string", "iPad16,6-A"), "DevicePerformanceMemoryClass": ("integer", "12"),
                      "GraphicsFeatureSetClass": ("string", "APPLE10"),
                      "GraphicsFeatureSetFallbacks": ("string", "APPLE9:APPLE8:APPLE7:APPLE6:APPLE5:APPLE4:APPLE3:APPLE3v1:APPLE2:APPLE1:GLES2,0")],
            screen: ["main-screen-class": ("integer", "32"), "main-screen-height": ("integer", "2752"),
                     "main-screen-orientation": ("real", "1.5707963705062866"), "main-screen-pitch": ("integer", "264"),
                     "main-screen-scale": ("real", "2"), "main-screen-width": ("integer", "2064")],
            values: ["idiom": ("string", "pad"), "modelIdentifier": ("string", "iPad17,4"),
                     "ThinningProductType": ("string", "iPad17,4-A"), "ModelNumber": ("string", "A3361"),
                     "RegulatoryModelNumber": ("string", "A3361"), "device-name": ("string", "iPad Simulator"),
                     "DeviceCornerRadius": ("real", "30"), "HomeButtonType": ("integer", "2"), "memoryClass": ("integer", "12"),
                     "subtype": ("integer", "2752"), "software-dimming-alpha": ("integer", "0"), "graphicsClass": ("integer", "3"),
                     "displayGamut": ("string", "P3"), "graphicsFeatureSetClass": ("string", "APPLE10"),
                     "graphicsFeatureSetFallbacks": ("string", "APPLE9:APPLE8:APPLE7:APPLE6:APPLE5:APPLE4:APPLE3:APPLE3v1:APPLE2:APPLE1:GLES2,0")],
            differing: ["touch-id": false, "pearl-id": true, "DeviceSupportsEnhancedMultitasking": true,
                        "GPSCapability": true, "contains-cellular-radio": true, "reverse-zoom": true]),
    ]

    /// Real values compare by value ("2" and "2.0" are both a real 2).
    static func same(_ got: (tag: String, text: String)?, _ want: (String, String)) -> Bool {
        guard let got, got.tag == want.0 else { return false }
        if want.0 == "real" { return Double(got.text) == Double(want.1) }
        return got.text == want.1
    }

    @Test(arguments: [0, 1]) func padCapabilitiesMatchSpec(_ index: Int) throws {
        let e = Self.pads[index]
        let plist = DeviceCapabilities.plist(for: e.type)
        let caps = try #require(plist["capabilities"] as? [String: Any])
        #expect(plist.count == 1)
        // The key set: the spec's tables, nothing else.
        let expected = Set(Self.padTrue + Self.padFalse + e.differing.keys + e.values.keys + ["ArtworkTraits", "ScreenDimensionsCapability"])
        #expect(Set(caps.keys) == expected)
        for key in Self.padAbsent { #expect(caps[key] == nil, "\(key) must be absent") }
        // Values with their XML types, key by key.
        let artworkXML = String(decoding: try Self.xml(try #require(caps["ArtworkTraits"] as? [String: Any])), as: UTF8.self)
        for (key, want) in e.artwork { #expect(Self.same(Self.element(artworkXML, key), want), "ArtworkTraits.\(key)") }
        #expect((caps["ArtworkTraits"] as? [String: Any])?.count == e.artwork.count)
        let screenXML = String(decoding: try Self.xml(try #require(caps["ScreenDimensionsCapability"] as? [String: Any])), as: UTF8.self)
        for (key, want) in e.screen { #expect(Self.same(Self.element(screenXML, key), want), "ScreenDimensionsCapability.\(key)") }
        #expect((caps["ScreenDimensionsCapability"] as? [String: Any])?.count == e.screen.count)
        let xml = String(decoding: try Self.xml(plist), as: UTF8.self)
        for (key, want) in e.values { #expect(Self.same(Self.element(xml, key), want), "\(key)") }
        for key in Self.padTrue { #expect(Self.element(xml, key)?.tag == "true", "\(key)") }
        for key in Self.padFalse { #expect(Self.element(xml, key)?.tag == "false", "\(key)") }
        for (key, flag) in e.differing { #expect(Self.element(xml, key)?.tag == (flag ? "true" : "false"), "\(key)") }
        // The file reads back as a property list.
        let back = try PropertyListSerialization.propertyList(from: try Self.xml(plist), format: nil) as? [String: Any]
        #expect((back?["capabilities"] as? [String: Any])?.count == expected.count)
    }

    @Test(arguments: [0, 1]) func padEnvironmentMatchesSpec(_ index: Int) throws {
        let e = Self.pads[index]
        let fm = FileManager.default
        let dev = Self.tempDir("pad"), rr = dev + "-rr"
        defer { try? fm.removeItem(atPath: dev); try? fm.removeItem(atPath: rr) }
        try fm.createDirectory(atPath: rr, withIntermediateDirectories: true)
        var phone = DeviceLayout(dev: dev, runtimeRoot: rr, udid: "11111111-2222-3333-4444-555555555555", jobPaths: [], bootTime: 1)
        var pad = phone
        pad.deviceType = e.type
        phone.lean = nil
        pad.lean = nil
        pad.templatePath = nil
        let p = pad.child, i = phone.child
        #expect(p["SIMULATOR_MODEL_IDENTIFIER"] == e.model)
        #expect(p["SIMULATOR_PRODUCT_CLASS"] == e.productClass)
        #expect(p["SIMULATOR_LEGACY_ASSET_SUFFIX"] == "ipad")
        #expect(p["SIMULATOR_MAINSCREEN_WIDTH"] == e.width)
        #expect(p["SIMULATOR_MAINSCREEN_HEIGHT"] == e.height)
        #expect(p["SIMULATOR_MAINSCREEN_SCALE"] == "2.000000")
        #expect(p["SIMULATOR_MAINSCREEN_PITCH"] == "264.000000")
        #expect(p["SIMULATOR_EXTENDED_DISPLAY_PROPERTIES"] == nil)
        #expect(p["IPHONE_TVOUT_EXTENDED_PROPERTIES"] == nil)
        #expect(p["SIMULATOR_VERSION_INFO"]?.hasSuffix("DeviceType: \(e.model)") == true)
        // Every other variable is the iPhone's (ipad.md §4.1).
        let identity: Set<String> = ["SIMULATOR_MODEL_IDENTIFIER", "SIMULATOR_PRODUCT_CLASS", "SIMULATOR_LEGACY_ASSET_SUFFIX",
                                     "SIMULATOR_MAINSCREEN_WIDTH", "SIMULATOR_MAINSCREEN_HEIGHT", "SIMULATOR_MAINSCREEN_SCALE",
                                     "SIMULATOR_MAINSCREEN_PITCH", "SIMULATOR_VERSION_INFO"]
        #expect(Set(i.keys).subtracting(p.keys) == Set<String>(["SIMULATOR_EXTENDED_DISPLAY_PROPERTIES", "IPHONE_TVOUT_EXTENDED_PROPERTIES",
                                                     "YCODE_SIMHID_DEVICE_MOTION"])
            .union(DeviceType.foldDisplaysEnabled ? ["YCODE_FRAMEBUFFER_SECOND_DISPLAY"] : []))
        #expect(Set(p.keys).subtracting(i.keys).isEmpty)
        for (key, value) in p where !identity.contains(key) { #expect(i[key] == value, "\(key)") }
        #expect(p["YCODE_SIMHID_DEVICE_MOTION"] == nil)
        // The written files.
        try pad.prepare()
        let written = try #require(fm.contents(atPath: pad.capabilitiesPath))
        #expect(written == (try Self.xml(DeviceCapabilities.plist(for: e.type))))
        #expect(fm.contents(atPath: pad.deviceTypePath) == Data((e.type.id + "\n").utf8))
        let env = pad.launchdEnvironment(overrides: [])
        #expect(!env.contains { $0.hasPrefix("SIMULATOR_EXTENDED_DISPLAY_PROPERTIES=") || $0.hasPrefix("IPHONE_TVOUT_EXTENDED_PROPERTIES=") })
        #expect(env.contains("SIMULATOR_MODEL_IDENTIFIER=\(e.model)"))
    }

    // MARK: Data

    @Test func typesByName() {
        #expect(DeviceType.all.map(\.id) == ["iphone-duo", "iphone-18-pro", "ipad-a16", "ipad-pro-13-m5", "vision-pro"])
        #expect(DeviceType.named("ipad-a16")?.modelIdentifier == "iPad15,7")
        #expect(DeviceType.named("ipad-pro-13-m5")?.screen == DeviceScreen(width: 2064, height: 2752, scale: 2, pitch: 264))
        #expect(DeviceType.named("ipad") == nil)
        #expect(DeviceType.iPadPro13M5.screen.pointWidth == 1032 && DeviceType.iPadPro13M5.screen.pointHeight == 1376)
        #expect(DeviceType.iPadA16.screen.pointWidth == 820 && DeviceType.iPadA16.screen.pointHeight == 1180)
        #expect(DeviceType.iPhoneDuo.family == .phone && !DeviceType.iPhoneDuo.pointerSystem)
        #expect(DeviceType.iPadA16.family == .pad && DeviceType.iPadA16.pointerSystem)
    }

    // MARK: A device keeps its type (ipad.md §4.3 R2)

    @Test func deviceKeepsItsType() throws {
        let fm = FileManager.default
        let dev = Self.tempDir("keep"), rr = dev + "-rr"
        defer { try? fm.removeItem(atPath: dev); try? fm.removeItem(atPath: rr) }
        try fm.createDirectory(atPath: rr, withIntermediateDirectories: true)
        var pad = DeviceLayout(dev: dev, runtimeRoot: rr, udid: nil, jobPaths: [])
        pad.deviceType = .iPadA16
        pad.lean = nil
        pad.templatePath = nil
        try pad.prepare()
        try pad.prepare()  // again as the same type
        var other = pad
        other.deviceType = .iPadPro13M5
        #expect(throws: DeviceTypeMismatch.self) { try other.prepare() }
        var phone = pad
        phone.deviceType = .iPhoneDuo
        #expect(throws: DeviceTypeMismatch.self) { try phone.prepare() }
        // A restore checks too.
        phone.restoring = true
        #expect(throws: DeviceTypeMismatch.self) { try phone.prepare() }
        #expect(fm.contents(atPath: pad.deviceTypePath) == Data("ipad-a16\n".utf8))
    }

    @Test func olderDeviceIsAnIPhone() throws {
        let fm = FileManager.default
        let dev = Self.tempDir("old"), rr = dev + "-rr"
        defer { try? fm.removeItem(atPath: dev); try? fm.removeItem(atPath: rr) }
        try fm.createDirectory(atPath: dev + "/data/var/run", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: rr, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: dev + "/data/var/run/launchd_bootstrap.plist"))
        var pad = DeviceLayout(dev: dev, runtimeRoot: rr, udid: nil, jobPaths: [])
        pad.deviceType = .iPadPro13M5
        pad.lean = nil
        pad.templatePath = nil
        #expect(throws: DeviceTypeMismatch.self) { try pad.prepare() }
        #expect(!fm.fileExists(atPath: pad.deviceTypePath))
        var phone = pad
        phone.deviceType = .iPhoneDuo
        try phone.prepare()
        #expect(fm.contents(atPath: phone.deviceTypePath) == Data("iphone-duo\n".utf8))
    }

    /// Files put into a new device's `data` before its first boot (a probe
    /// in data/tmp) do not make it an older device.
    @Test func newDeviceWithFilesIsNew() throws {
        let fm = FileManager.default
        let dev = Self.tempDir("new"), rr = dev + "-rr"
        defer { try? fm.removeItem(atPath: dev); try? fm.removeItem(atPath: rr) }
        try fm.createDirectory(atPath: dev + "/data/tmp", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: rr, withIntermediateDirectories: true)
        var pad = DeviceLayout(dev: dev, runtimeRoot: rr, udid: nil, jobPaths: [])
        pad.deviceType = .iPadPro13M5
        pad.lean = nil
        pad.templatePath = nil
        try pad.prepare()
        #expect(fm.contents(atPath: pad.deviceTypePath) == Data("ipad-pro-13-m5\n".utf8))
    }

    @Test func goldenDeviceOfAnotherTypeIsRefused() throws {
        let fm = FileManager.default
        let base = Self.tempDir("golden")
        defer { try? fm.removeItem(atPath: base) }
        let golden = base + "/golden", rr = base + "/rr"
        try fm.createDirectory(atPath: golden + "/data/Library", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: rr, withIntermediateDirectories: true)
        try Data("ipad-a16\n".utf8).write(to: URL(fileURLWithPath: golden + "/ycode-device-type"))
        var phone = DeviceLayout(dev: base + "/dev1", runtimeRoot: rr, udid: nil, jobPaths: [])
        phone.lean = nil
        phone.templatePath = golden
        #expect(throws: DeviceTypeMismatch.self) { try phone.prepare() }
        #expect(!fm.fileExists(atPath: phone.data))
        var pad = DeviceLayout(dev: base + "/dev2", runtimeRoot: rr, udid: nil, jobPaths: [])
        pad.deviceType = .iPadA16
        pad.lean = nil
        pad.templatePath = golden
        try pad.prepare()
        #expect(fm.fileExists(atPath: pad.data + "/Library"))
        #expect(fm.contents(atPath: pad.deviceTypePath) == Data("ipad-a16\n".utf8))
    }
}
