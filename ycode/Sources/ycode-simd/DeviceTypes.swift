// Device types as data (specs/simulator/ipad.md §3, §4;
// specs/simulator/device-capabilities.md §3). A device type is everything
// the host tells the guest about the hardware it runs on: the identity
// variables of launchd_sim's environment (model, product class, asset
// suffix, main screen) and the capabilities plist that MobileGestalt answers
// from. One record per type; nothing else in ycode-simd knows which device
// it simulates. A new type (another iPad, later other platforms) is one more
// record here.
//
// The values are the device types' own (their profile.plist and
// capabilities.plist read as file formats, level 2, as the specs list them).
// Number types are part of the format (ipad.md §3.3): iPad records carry
// reals where the device type's file has reals. The iPhone Duo record keeps
// the integers Ycode has written since 2026-10-13, so its output stays byte
// for byte as it was (ipad.md §9 round 1).

import Foundation

/// The kind of device (UIKit's idiom; `capabilities.idiom`).
enum DeviceFamily: String, Sendable {
    case phone
    case pad
    case vision
}

/// The simulator platform a runtime is for (visionos.md §2.1, V-2): read from
/// RR's `SystemVersion.plist` `ProductName` (`xrOS` for visionOS). A runtime
/// without the key (or with any other name) is an iOS runtime, as every
/// runtime Ycode ran before visionOS.
enum RuntimePlatform: String, Sendable {
    case iOS
    case visionOS

    init(productName: String?) { self = productName == "xrOS" ? .visionOS : .iOS }

    /// The name in `SIMULATOR_VERSION_INFO` ("… - Runtime: visionOS 27.0 (24M362) - …").
    var displayName: String { rawValue }

    /// The Mach-O platform of the runtime's images (`LC_BUILD_VERSION`):
    /// iOS simulator 7, visionOS simulator 12. Ycode's own guest images
    /// (host libraries, framebuffer library, HID bundle) must carry it to be
    /// loaded into the runtime's processes (host-library-loading.md §2.1).
    var machOPlatform: UInt32 { self == .visionOS ? 12 : 7 }
}

/// A property-list value whose type is kept exactly (integer vs real).
indirect enum CapabilityValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case real(Double)
    case bool(Bool)
    case dictionary([String: CapabilityValue])
    case array([CapabilityValue])

    /// The Foundation value PropertyListSerialization writes as this type.
    var propertyList: Any {
        switch self {
        case .string(let s): return s
        case .integer(let n): return n
        case .real(let x): return x
        case .bool(let b): return b
        case .dictionary(let d): return d.mapValues(\.propertyList)
        case .array(let a): return a.map(\.propertyList)
        }
    }
}

/// The main display as CoreSimulator gives it to the runtime
/// (`SIMULATOR_MAINSCREEN_*`): native portrait pixels, scale, dot pitch.
struct DeviceScreen: Equatable, Sendable {
    let width: Int
    let height: Int
    let scale: Double
    let pitch: Double

    /// The touch coordinate space (points; display-stream.md §3.1).
    var pointWidth: Double { Double(width) / scale }
    var pointHeight: Double { Double(height) / scale }
}

/// A second built-in display (foldable.md §2): published by the framebuffer
/// library next to display 1 (`YCODE_FRAMEBUFFER_SECOND_DISPLAY`).
struct SecondDisplay: Equatable, Sendable {
    /// SFBDisplayGetID (the framebuffer id).
    let id: Int
    let name: String
    let deviceName: String
    /// Native portrait pixels.
    let width: Int
    let height: Int
    let scale: Int
    let pitch: Int
    /// The display's unique id (Ycode's own, stable across boots).
    let uid: String
    /// How the panel is mounted (§2 "Native orientation / rotation"): its
    /// upright UI is turned this many degrees from its framebuffer.
    let mountRotation: Int

    /// The framebuffer library's description: "<id> <name> <device name>
    /// <width> <height> <scale> <pitch> <uid>".
    var environmentValue: String { "\(id) \(name) \(deviceName) \(width) \(height) \(scale) \(pitch) \(uid)" }

    /// The iPhone Duo's inner panel: id 3, `LCD-1`/`primary-1`, 2007 × 2853
    /// @3, 460 dpi, mounted at 270°.
    static let iPhoneDuoInner = SecondDisplay(id: 3, name: "LCD-1", deviceName: "primary-1", width: 2007, height: 2853,
                                              scale: 3, pitch: 460, uid: "59434F44-4500-4000-8000-000000000003",
                                              mountRotation: 270)
}

/// One simulated device type.
struct DeviceType: Equatable, Sendable {
    /// Ycode's name for it (`ycode-simd --device-type`; recorded in DEV).
    let id: String
    /// The device type's name, as a person reads it.
    let name: String
    let family: DeviceFamily
    /// `SIMULATOR_MODEL_IDENTIFIER` (also in `SIMULATOR_VERSION_INFO`).
    let modelIdentifier: String
    /// `SIMULATOR_PRODUCT_CLASS`.
    let productClass: String
    /// `SIMULATOR_LEGACY_ASSET_SUFFIX` (the device type's `environment`).
    let legacyAssetSuffix: String
    let screen: DeviceScreen
    /// Whether the environment names the extended-display plist
    /// (`SIMULATOR_EXTENDED_DISPLAY_PROPERTIES`,
    /// `IPHONE_TVOUT_EXTENDED_PROPERTIES`): the iPhone's has them, an iPad's
    /// does not (ipad.md §4.1).
    let extendedDisplayProperties: Bool
    /// The device type declares `com.apple.hid.pointer.system`: the host
    /// may offer pointer input (ipad.md §3.2, §7.2; a later round).
    let pointerSystem: Bool
    /// The `capabilities` dictionary of `DEV/ycode-capabilities.plist`.
    let capabilities: [String: CapabilityValue]
    /// The runtime platform the type runs on (visionos.md V-1: the Apple
    /// Vision Pro only on xrOS runtimes, the others only on iOS runtimes).
    var platform: RuntimePlatform = .iOS
    /// A display unique id fixed by the device type (visionos.md §3.3: the
    /// Vision Pro's one display); nil: Ycode's own constant, as before.
    var displayUID: String?
    /// The oldest runtime version the type runs on (the device type's
    /// `minRuntimeVersion`, ipad.md §3.2, iphone-types.md §3.2); nil: no
    /// limit known. A runtime older than this is refused (the reference
    /// fails `simctl create` with 403 "Incompatible device").
    var minRuntimeVersion: String?
    /// A second built-in display (foldable.md §2, §8.1 D1): the iPhone
    /// Duo's inner panel. A type with one is a foldable (§8.3 E1).
    var secondDisplay: SecondDisplay?
    var isFoldable: Bool { secondDisplay != nil }
    /// The second display as the framebuffer library publishes it: by
    /// default for every foldable; `YCODE_FOLD_DISPLAYS=0` in ycode-simd's
    /// environment publishes the cover only (foldable.md §10.4).
    var publishedSecondDisplay: SecondDisplay? { Self.foldDisplaysEnabled ? secondDisplay : nil }
    nonisolated(unsafe) static var foldDisplaysEnabled = ProcessInfo.processInfo.environment["YCODE_FOLD_DISPLAYS"] != "0"
    /// The device type's `displays` list (device-capabilities.md §3.1): one
    /// dictionary per display port, in the type's order. Written into the
    /// capabilities plist only together with the second built-in display
    /// (the guest takes each panel's surface from it, foldable.md §9 Q7).
    var displays: [CapabilityValue]?

    /// The capabilities plist: `{capabilities: {...}}`, with `displays`
    /// when the second built-in display is published.
    var capabilitiesPlist: [String: Any] { capabilitiesPlist(withDisplays: publishedSecondDisplay != nil) }

    /// The capabilities plist with or without the type's `displays` list.
    func capabilitiesPlist(withDisplays: Bool) -> [String: Any] {
        var c = capabilities
        if withDisplays, let displays { c["displays"] = .array(displays) }
        return ["capabilities": c.mapValues(\.propertyList)]
    }

    /// The type a device has when nothing says otherwise (every device made
    /// before device types existed is one).
    static let `default` = iPhoneDuo

    /// Every type `--device-type` accepts, the default first.
    static let all: [DeviceType] = [iPhoneDuo, iPhone18Pro, iPadA16, iPadPro13M5, visionPro]

    static func named(_ id: String) -> DeviceType? { all.first { $0.id == id } }

    /// The type a new device gets on a runtime of `platform` when
    /// `--device-type` is not given.
    static func `default`(for platform: RuntimePlatform) -> DeviceType { platform == .visionOS ? visionPro : .default }

    /// The default type for a runtime of this platform and version
    /// (iphone-types.md §5 I3): on iOS the newest iPhone that runs on the
    /// version — iPhone Duo on 27.1 and later, iPhone 18 Pro on 27.0 —, else
    /// (unknown or older version) the platform default.
    static func `default`(for platform: RuntimePlatform, version: String) -> DeviceType {
        guard platform == .iOS, !version.isEmpty else { return .default(for: platform) }
        return [iPhoneDuo, iPhone18Pro].first { $0.runs(onVersion: version) } ?? .default(for: platform)
    }

    /// Whether the type runs on a runtime of this version (an unknown
    /// version or limit: yes).
    func runs(onVersion version: String) -> Bool {
        guard let min = minRuntimeVersion, !version.isEmpty else { return true }
        return DeviceLayout.compareVersions(version, min) >= 0
    }

    static func == (a: DeviceType, b: DeviceType) -> Bool { a.id == b.id }
}

// MARK: - The records

extension DeviceType {
    /// Builds a capabilities dictionary from its value entries and its
    /// true and false keys.
    fileprivate static func capabilities(_ values: [String: CapabilityValue], true trueKeys: [String],
                                         false falseKeys: [String]) -> [String: CapabilityValue] {
        var c = values
        for key in trueKeys { c[key] = .bool(true) }
        for key in falseKeys { c[key] = .bool(false) }
        return c
    }

    /// iPhone Duo (model iPhone19,4): Ycode's first and default device type
    /// (device-capabilities.md §3).
    static let iPhoneDuo: DeviceType = {
        let fallbacks = "APPLE10:APPLE9:APPLE8:APPLE7:APPLE6:APPLE5:APPLE4:APPLE3:APPLE3v1:APPLE2:APPLE1:GLES2,0"
        let model = "iPhone19,4"
        let screen = DeviceScreen(width: 1398, height: 2034, scale: 3.0, pitch: 460.0)
        let values: [String: CapabilityValue] = [
            "ArtworkTraits": .dictionary([
                "ArtworkDeviceIdiom": .string("phone"),
                "ArtworkDeviceProductDescription": .string("iPhone"),
                "ArtworkDeviceScaleFactor": .integer(3),
                "ArtworkDeviceSubType": .integer(screen.height),
                "ArtworkDisplayGamut": .string("P3"),
                "ArtworkDynamicDisplayMode": .string("0"),
                "CompatibleDeviceFallback": .string("iPhone18,3"),
                "DevicePerformanceMemoryClass": .integer(12),
                "GraphicsFeatureSetClass": .string("APPLE11"),
                "GraphicsFeatureSetFallbacks": .string(fallbacks),
            ]),
            "ScreenDimensionsCapability": .dictionary([
                "main-screen-class": .integer(36),
                "main-screen-height": .integer(screen.height),
                "main-screen-orientation": .integer(0),
                "main-screen-pitch": .integer(460),
                "main-screen-scale": .integer(3),
                "main-screen-width": .integer(screen.width),
            ]),
            "DeviceCornerRadius": .integer(59),
            "displayGamut": .string("P3"),
            "graphicsFeatureSetClass": .string("APPLE11"),
            "graphicsFeatureSetFallbacks": .string(fallbacks),
            "HomeButtonType": .integer(2),
            "idiom": .string("phone"),
            "MainScreenClass": .integer(18),
            "memoryClass": .integer(12),
            "modelIdentifier": .string(model),
            "ThinningProductType": .string(model),
            "ModelNumber": .string("A3447"),
            "RegulatoryModelNumber": .string("A3447"),
            "device-name": .string("iPhone Simulator"),
            "subtype": .integer(screen.height),
            "software-dimming-alpha": .integer(0),
        ]
        let trueKeys = [
            "720p", "accelerometer", "accessibility", "always-on-time", "applicationInstallation", "arm64",
            "armv6", "armv7", "armv7s", "ASTC", "bluetooth", "bluetooth-le", "cellular-data",
            "contains-cellular-radio", "DeviceSupports3DImagery", "DeviceSupports3DMaps",
            "DeviceSupportsAdaptiveMapsUI", "DeviceSupportsAdvancedMapRendering", "DeviceSupportsDynamicIsland",
            "DeviceSupportsHiResBuildings", "displayport", "encrypted-data-partition", "full-6", "gamekit",
            "gas-gauge-battery", "GPSCapability", "hardware-keyboard", "HasThinBezel", "HEVCDecoder8bitSupported",
            "HEVCDecoder10bitSupported", "HEVCDecoder12bitSupported", "HEVCEncodingCapability", "hidpi",
            "homescreen-wallpaper", "international-settings", "IsLargeFormatPhone",
            "load-thumbnails-while-scrolling", "location-services", "magnetometer", "metal", "microphone",
            "multitasking", "opengles-1", "opengles-2", "peer-peer", "screenrecorder", "shoebox", "sms",
            "stand-alone-contacts", "telephony", "touch-id", "unified-ipod", "watch-companion", "wifi",
        ]
        let falseKeys = [
            "DeviceIsMuseCapable", "DeviceSupportsElton", "DeviceSupportsEnhancedMultitasking",
            "DeviceSupportsSingleDisplayEnhancedMultitasking", "FloatingLiveAppOverlay", "hide-non-default-apps",
            "ipad", "MLEHW", "OysterCapability", "pearl-id", "PiPOverlay", "PiPPinned", "reverse-zoom",
            "ringer-switch", "RingerButtonCapability", "SupportsForceTouch",
        ]
        var type = DeviceType(id: "iphone-duo", name: "iPhone Duo", family: .phone, modelIdentifier: model,
                              productClass: "V68", legacyAssetSuffix: "iphone", screen: screen,
                              extendedDisplayProperties: true, pointerSystem: false,
                              capabilities: capabilities(values, true: trueKeys, false: falseKeys))
        type.minRuntimeVersion = "27.1"
        type.secondDisplay = .iPhoneDuoInner
        type.displays = DisplayEntry.iPhoneDuo.map(\.capability)
        return type
    }()

    /// iPhone 18 Pro (model iPhone19,2, product class V63): the iPhone of the
    /// iOS 27.0 runtime, which does not accept the iPhone Duo
    /// (iphone-types.md §3, §4). Its capabilities are the iPhone Duo's with
    /// the values of iphone-types.md §4.2 changed, and with the reference's
    /// number types (reals for the scale factors, orientation and corner
    /// radius), which the iPhone Duo record keeps as integers for its
    /// byte-for-byte history.
    static let iPhone18Pro: DeviceType = {
        let model = "iPhone19,2"
        let screen = DeviceScreen(width: 1206, height: 2622, scale: 3.0, pitch: 460.0)
        var c = iPhoneDuo.capabilities
        guard case .dictionary(var art) = c["ArtworkTraits"], case .dictionary(var dims) = c["ScreenDimensionsCapability"] else {
            preconditionFailure("the iPhone Duo record has ArtworkTraits and ScreenDimensionsCapability")
        }
        art["ArtworkDeviceProductDescription"] = .string("iPhone 18 Pro")
        art["ArtworkDeviceSubType"] = .integer(screen.height)
        art["CompatibleDeviceFallback"] = .string("iPhone18,1")
        art["ArtworkDeviceScaleFactor"] = .real(screen.scale)
        dims["main-screen-width"] = .integer(screen.width)
        dims["main-screen-height"] = .integer(screen.height)
        dims["main-screen-scale"] = .real(screen.scale)
        dims["main-screen-orientation"] = .real(0.0)
        c["ArtworkTraits"] = .dictionary(art)
        c["ScreenDimensionsCapability"] = .dictionary(dims)
        c["subtype"] = .integer(screen.height)
        c["DeviceCornerRadius"] = .real(62.0)
        c["modelIdentifier"] = .string(model)
        c["ThinningProductType"] = .string(model)
        c["ModelNumber"] = .string("A3472")
        c["RegulatoryModelNumber"] = .string("A3472")
        c["pearl-id"] = .bool(true)
        c["touch-id"] = .bool(false)
        c["RingerButtonCapability"] = .bool(true)
        var type = DeviceType(id: "iphone-18-pro", name: "iPhone 18 Pro", family: .phone, modelIdentifier: model,
                              productClass: "V63", legacyAssetSuffix: "iphone", screen: screen,
                              extendedDisplayProperties: true, pointerSystem: false, capabilities: c)
        type.minRuntimeVersion = "27.0"
        return type
    }()

    /// The capabilities both first iPad types share, and those in which they
    /// differ (ipad.md §4.2).
    fileprivate struct PadValues {
        var productDescription: String
        var screen: DeviceScreen
        var mainScreenClass: Int
        /// `main-screen-orientation` (radians; a real).
        var orientation: Double
        var gamut: String
        var compatibleFallback: String
        var memoryClass: Int
        var featureSetClass: String
        var featureSetFallbacks: String
        var model: String
        var thinningProductType: String
        var modelNumber: String
        var cornerRadius: Double
        /// The booleans of ipad.md §4.2's "Differing booleans" table.
        var differing: [String: Bool]
    }

    fileprivate static func pad(id: String, name: String, productClass: String, _ v: PadValues) -> DeviceType {
        let values: [String: CapabilityValue] = [
            "ArtworkTraits": .dictionary([
                "ArtworkDeviceIdiom": .string("pad"),
                "ArtworkDeviceProductDescription": .string(v.productDescription),
                "ArtworkDeviceScaleFactor": .real(v.screen.scale),
                "ArtworkDeviceSubType": .integer(v.screen.height),
                "ArtworkDisplayGamut": .string(v.gamut),
                "ArtworkDynamicDisplayMode": .string("0"),
                "CompatibleDeviceFallback": .string(v.compatibleFallback),
                "DevicePerformanceMemoryClass": .integer(v.memoryClass),
                "GraphicsFeatureSetClass": .string(v.featureSetClass),
                "GraphicsFeatureSetFallbacks": .string(v.featureSetFallbacks),
            ]),
            "ScreenDimensionsCapability": .dictionary([
                "main-screen-class": .integer(v.mainScreenClass),
                "main-screen-height": .integer(v.screen.height),
                "main-screen-orientation": .real(v.orientation),
                "main-screen-pitch": .integer(Int(v.screen.pitch)),
                "main-screen-scale": .real(v.screen.scale),
                "main-screen-width": .integer(v.screen.width),
            ]),
            "idiom": .string("pad"),
            "modelIdentifier": .string(v.model),
            "ThinningProductType": .string(v.thinningProductType),
            "ModelNumber": .string(v.modelNumber),
            "RegulatoryModelNumber": .string(v.modelNumber),
            "device-name": .string("iPad Simulator"),
            "DeviceCornerRadius": .real(v.cornerRadius),
            "HomeButtonType": .integer(2),
            "memoryClass": .integer(v.memoryClass),
            "subtype": .integer(v.screen.height),
            "software-dimming-alpha": .integer(0),
            "graphicsClass": .integer(3),
            "displayGamut": .string(v.gamut),
            "graphicsFeatureSetClass": .string(v.featureSetClass),
            "graphicsFeatureSetFallbacks": .string(v.featureSetFallbacks),
        ]
        let trueKeys = [
            "720p", "accelerometer", "accessibility", "applicationInstallation", "arm64", "armv6", "armv7",
            "armv7s", "ASTC", "bluetooth", "DeviceSupports3DImagery", "DeviceSupports3DMaps",
            "DeviceSupportsAdaptiveMapsUI", "DeviceSupportsAdvancedMapRendering", "DeviceSupportsHiResBuildings",
            "displayport", "encrypted-data-partition", "FloatingLiveAppOverlay", "full-6", "gamekit",
            "gas-gauge-battery", "HasThinBezel", "HEVCDecoder8bitSupported", "HEVCDecoder10bitSupported",
            "HEVCDecoder12bitSupported", "HEVCEncodingCapability", "hide-non-default-apps", "hidpi",
            "homescreen-wallpaper", "international-settings", "ipad", "load-thumbnails-while-scrolling",
            "location-services", "magnetometer", "metal", "microphone", "multitasking", "opengles-1",
            "opengles-2", "peer-peer", "PiPOverlay", "PiPPinned", "screenrecorder", "stand-alone-contacts", "wifi",
        ]
        let falseKeys = [
            "always-on-time", "DeviceSupportsDynamicIsland", "DeviceSupportsElton",
            "DeviceSupportsSingleDisplayEnhancedMultitasking", "MLEHW", "OysterCapability", "ringer-switch",
            "RingerButtonCapability", "sms", "SupportsForceTouch", "telephony", "unified-ipod", "watch-companion",
        ]
        var c = capabilities(values, true: trueKeys, false: falseKeys)
        for (key, flag) in v.differing { c[key] = .bool(flag) }
        // Absent (not false) on iPads: hardware-keyboard, MainScreenClass,
        // IsLargeFormatPhone, shoebox, bluetooth-le, cellular-data,
        // DeviceIsMuseCapable (ipad.md §4.2).
        return DeviceType(id: id, name: name, family: .pad, modelIdentifier: v.model, productClass: productClass,
                          legacyAssetSuffix: "ipad", screen: v.screen, extendedDisplayProperties: false,
                          pointerSystem: true, capabilities: c)
    }

    /// iPad (A16), model iPad15,7: Xcode's default iPad (ipad.md §4).
    static let iPadA16 = withMinimum("18.3", pad(id: "ipad-a16", name: "iPad (A16)", productClass: "J481", PadValues(
        productDescription: "iPad (A16)",
        screen: DeviceScreen(width: 1640, height: 2360, scale: 2.0, pitch: 264.0),
        mainScreenClass: 23, orientation: 0.0, gamut: "sRGB", compatibleFallback: "iPad13,18", memoryClass: 6,
        featureSetClass: "APPLE8",
        featureSetFallbacks: "APPLE7:APPLE6:APPLE5:APPLE4:APPLE3:APPLE3v1:APPLE2:APPLE1:GLES2,0",
        model: "iPad15,7", thinningProductType: "iPad15,7", modelNumber: "A3354", cornerRadius: 25.0,
        differing: ["touch-id": true, "pearl-id": false, "DeviceSupportsEnhancedMultitasking": false,
                    "GPSCapability": false, "contains-cellular-radio": false, "reverse-zoom": false])))

    /// iPad Pro 13-inch (M5), model iPad17,4 (ipad.md §4).
    static let iPadPro13M5 = withMinimum("26.0", pad(id: "ipad-pro-13-m5", name: "iPad Pro 13-inch (M5)", productClass: "J821", PadValues(
        productDescription: "iPad Pro 13-inch (M5)",
        screen: DeviceScreen(width: 2064, height: 2752, scale: 2.0, pitch: 264.0),
        mainScreenClass: 32, orientation: 1.5707963705062866, gamut: "P3", compatibleFallback: "iPad16,6-A",
        memoryClass: 12, featureSetClass: "APPLE10",
        featureSetFallbacks: "APPLE9:APPLE8:APPLE7:APPLE6:APPLE5:APPLE4:APPLE3:APPLE3v1:APPLE2:APPLE1:GLES2,0",
        model: "iPad17,4", thinningProductType: "iPad17,4-A", modelNumber: "A3361", cornerRadius: 30.0,
        differing: ["touch-id": false, "pearl-id": true, "DeviceSupportsEnhancedMultitasking": true,
                    "GPSCapability": true, "contains-cellular-radio": true, "reverse-zoom": true])))

    fileprivate static func withMinimum(_ version: String, _ t: DeviceType) -> DeviceType {
        var t = t
        t.minRuntimeVersion = version
        return t
    }

    /// Apple Vision Pro (model RealityDevice14,1, device type
    /// `Apple-Vision-Pro-4K`; visionos.md §3, V-1). The spec lists the
    /// values that differ in kind from the iPhone Duo and a selection of the
    /// booleans; those are taken as listed. **Ycode decision:** the keys the
    /// spec does not list are filled like the iPad records where they
    /// describe software rather than hardware (`arm64`, application
    /// installation, accessibility, …; an app's `UIRequiredDeviceCapabilities`
    /// is checked against them), and left absent otherwise; `displays`,
    /// `iconState` and `marketing-name` are left out as for every type.
    static let visionPro: DeviceType = {
        let fallbacks = "APPLE7:APPLE6:APPLE5:APPLE4:APPLE3:APPLE3v1:APPLE2:APPLE1:GLES2,0"
        let model = "RealityDevice14,1"
        let screen = DeviceScreen(width: 3840, height: 2160, scale: 2.0, pitch: 264.0)
        let values: [String: CapabilityValue] = [
            "ArtworkTraits": .dictionary([
                "ArtworkDeviceIdiom": .string("vision"),
                "ArtworkDeviceProductDescription": .string("Apple Vision Pro"),
                "ArtworkDeviceScaleFactor": .real(screen.scale),
                "ArtworkDeviceSubType": .integer(3648),
                "ArtworkDisplayGamut": .string("P3"),
                "ArtworkDynamicDisplayMode": .string("0"),
                "CompatibleDeviceFallback": .string("iPad13,4"),
                "DevicePerformanceMemoryClass": .integer(16),
                "GraphicsFeatureSetClass": .string("APPLE8"),
                "GraphicsFeatureSetFallbacks": .string(fallbacks),
            ]),
            "ScreenDimensionsCapability": .dictionary([
                "main-screen-class": .integer(11),
                "main-screen-height": .integer(screen.height),
                "main-screen-orientation": .real(0),
                "main-screen-pitch": .integer(264),
                "main-screen-scale": .real(screen.scale),
                "main-screen-width": .integer(screen.width),
            ]),
            "idiom": .string("vision"),
            "modelIdentifier": .string(model),
            "ThinningProductType": .string(model),
            "ModelNumber": .string("A2117"),
            "RegulatoryModelNumber": .string("A2117"),
            "device-name": .string("Apple Vision Simulator"),
            "DeviceCornerRadius": .real(0),
            "HomeButtonType": .integer(0),
            "memoryClass": .integer(16),
            "subtype": .integer(3648),
            "software-dimming-alpha": .integer(0),
            "graphicsClass": .integer(3),
            "displayGamut": .string("P3"),
            "graphicsFeatureSetClass": .string("APPLE8"),
            "graphicsFeatureSetFallbacks": .string(fallbacks),
        ]
        // visionos.md §3.3 "true (selection)".
        let listedTrue = [
            "OysterCapability", "DeviceIsMuseCapable", "FloatingLiveAppOverlay", "PiPOverlay", "PiPPinned",
            "DeviceSupports3DImagery", "DeviceSupports3DMaps", "metal", "ASTC", "hidpi", "microphone", "wifi",
            "bluetooth", "location-services", "accelerometer", "multitasking", "HEVCDecoder8bitSupported",
            "HEVCDecoder10bitSupported", "HEVCDecoder12bitSupported", "HEVCEncodingCapability",
            "VGDDUFPWHbX/Ie9RSI0yDQ",
        ]
        // Software keys every other Ycode record has true (Ycode decision, above).
        let softwareTrue = [
            "accessibility", "applicationInstallation", "arm64", "encrypted-data-partition", "gamekit",
            "international-settings", "peer-peer", "stand-alone-contacts",
        ]
        // visionos.md §3.3 "false (selection)".
        let listedFalse = [
            "telephony", "sms", "GPSCapability", "magnetometer", "touch-id", "pearl-id", "ipad", "HasThinBezel",
            "always-on-time", "contains-cellular-radio", "watch-companion", "DeviceSupportsEnhancedMultitasking",
        ]
        var type = DeviceType(id: "vision-pro", name: "Apple Vision Pro", family: .vision, modelIdentifier: model,
                              productClass: "N301", legacyAssetSuffix: "", screen: screen,
                              extendedDisplayProperties: false, pointerSystem: false,
                              capabilities: capabilities(values, true: listedTrue + softwareTrue, false: listedFalse))
        type.platform = .visionOS
        type.displayUID = "731F1373-97EF-4DCA-BC31-14C516B3E06F"
        return type
    }()
}

// MARK: - The `displays` capability

/// One entry of a device type's `displays` list (device-capabilities.md
/// §3.1): every key with the type the device type's file gives it. Keys a
/// kind of display does not have are nil and left out.
struct DisplayEntry: Equatable, Sendable {
    var displayName: String
    var deviceName: String
    /// `integrated`, `tvOut`, `carPlay`, `scene`.
    var displayType: String
    var screenID: Int
    var width: Int, height: Int
    var scale: Double
    var dpi: Double
    var refreshRate = 60.0
    var colorspace = "sRGB"
    var powerState: Int
    var hasDigitizer: Bool
    // Built-in panels only.
    /// 1: cover, 2: inner (SpringBoard's surface for the panel).
    var surfaceType: Int?
    var nativeOrientation: Int?
    var nativeRotation: Int?
    /// Upper left, lower left, upper right, lower right (points).
    var cornerRadii: (ul: Double, ll: Double, ur: Double, lr: Double)?
    var chromeIdentifier: String?
    var framebufferMaskIdentifier: String?
    var requiredFeatures: [String]?

    static func == (a: DisplayEntry, b: DisplayEntry) -> Bool { a.capability == b.capability }

    var capability: CapabilityValue {
        var d: [String: CapabilityValue] = [
            "displayName": .string(displayName), "deviceName": .string(deviceName), "displayType": .string(displayType),
            "screenID": .integer(screenID), "width": .integer(width), "height": .integer(height),
            "scale": .real(scale), "hdpi": .real(dpi), "vdpi": .real(dpi), "refreshRate": .real(refreshRate),
            "colorspace": .string(colorspace), "powerState": .integer(powerState), "hasDigitizer": .bool(hasDigitizer),
        ]
        if let surfaceType { d["surfaceType"] = .integer(surfaceType) }
        if let nativeOrientation { d["nativeOrientation"] = .integer(nativeOrientation) }
        if let nativeRotation { d["nativeRotation"] = .integer(nativeRotation) }
        if let r = cornerRadii {
            d["cornerRadiusUL"] = .real(r.ul); d["cornerRadiusLL"] = .real(r.ll)
            d["cornerRadiusUR"] = .real(r.ur); d["cornerRadiusLR"] = .real(r.lr)
        }
        if let chromeIdentifier { d["chromeIdentifier"] = .string(chromeIdentifier) }
        if let framebufferMaskIdentifier { d["framebufferMaskIdentifier"] = .string(framebufferMaskIdentifier) }
        if let requiredFeatures { d["requiredFeatures"] = .array(requiredFeatures.map { .string($0) }) }
        return .dictionary(d)
    }

    /// The iPhone Duo's five display ports (device-capabilities.md §3.1),
    /// in the device type's order. The chrome and mask identifiers are
    /// identifiers only: Ycode ships no chrome or mask file (§3.1 "Ycode
    /// decision"; the framebuffer library reports no mask path).
    static let iPhoneDuo: [DisplayEntry] = {
        let inner = SecondDisplay.iPhoneDuoInner
        return [
            DisplayEntry(displayName: "LCD", deviceName: "primary", displayType: "integrated", screenID: 1,
                         width: 1398, height: 2034, scale: 3, dpi: 460, colorspace: "P3", powerState: 1, hasDigitizer: true,
                         surfaceType: 1, nativeOrientation: 0, nativeRotation: 0, cornerRadii: (8, 8, 59, 59),
                         chromeIdentifier: "com.apple.dt.devicekit.chrome.phone15",
                         framebufferMaskIdentifier: "1C896A2B-F0D7-405C-8D0F-66E4B80AD044"),
            DisplayEntry(displayName: "TVOut", deviceName: "external-0", displayType: "tvOut", screenID: 2,
                         width: 720, height: 480, scale: 1, dpi: 72, powerState: 0, hasDigitizer: false),
            DisplayEntry(displayName: inner.name, deviceName: inner.deviceName, displayType: "integrated", screenID: inner.id,
                         width: inner.width, height: inner.height, scale: Double(inner.scale), dpi: Double(inner.pitch),
                         powerState: 1, hasDigitizer: true,
                         surfaceType: 2, nativeOrientation: inner.mountRotation, nativeRotation: inner.mountRotation,
                         cornerRadii: (55, 55, 55, 55), chromeIdentifier: "com.apple.dt.devicekit.chrome.phone14",
                         framebufferMaskIdentifier: "BF0DC480-5EE2-4EC1-B02B-C75E94759832"),
            DisplayEntry(displayName: "Wireless", deviceName: "wireless0", displayType: "carPlay", screenID: 4,
                         width: 720, height: 480, scale: 1, dpi: 72, powerState: 0, hasDigitizer: false),
            DisplayEntry(displayName: "Resizable", deviceName: "resizable", displayType: "scene", screenID: 5,
                         width: 7680, height: 4320, scale: 3, dpi: 120, powerState: 0, hasDigitizer: true,
                         cornerRadii: (0, 0, 0, 0), requiredFeatures: ["com.apple.CoreSimulator.display.resizableScene"]),
        ]
    }()
}
