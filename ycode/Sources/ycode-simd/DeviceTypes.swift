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
}

/// A property-list value whose type is kept exactly (integer vs real).
indirect enum CapabilityValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case real(Double)
    case bool(Bool)
    case dictionary([String: CapabilityValue])

    /// The Foundation value PropertyListSerialization writes as this type.
    var propertyList: Any {
        switch self {
        case .string(let s): return s
        case .integer(let n): return n
        case .real(let x): return x
        case .bool(let b): return b
        case .dictionary(let d): return d.mapValues(\.propertyList)
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

    /// The capabilities plist: `{capabilities: {...}}`.
    var capabilitiesPlist: [String: Any] { ["capabilities": capabilities.mapValues(\.propertyList)] }

    /// The type a device has when nothing says otherwise (every device made
    /// before device types existed is one).
    static let `default` = iPhoneDuo

    /// Every type `--device-type` accepts, the default first.
    static let all: [DeviceType] = [iPhoneDuo, iPadA16, iPadPro13M5]

    static func named(_ id: String) -> DeviceType? { all.first { $0.id == id } }

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
        return DeviceType(id: "iphone-duo", name: "iPhone Duo", family: .phone, modelIdentifier: model,
                          productClass: "V68", legacyAssetSuffix: "iphone", screen: screen,
                          extendedDisplayProperties: true, pointerSystem: false,
                          capabilities: capabilities(values, true: trueKeys, false: falseKeys))
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
    static let iPadA16 = pad(id: "ipad-a16", name: "iPad (A16)", productClass: "J481", PadValues(
        productDescription: "iPad (A16)",
        screen: DeviceScreen(width: 1640, height: 2360, scale: 2.0, pitch: 264.0),
        mainScreenClass: 23, orientation: 0.0, gamut: "sRGB", compatibleFallback: "iPad13,18", memoryClass: 6,
        featureSetClass: "APPLE8",
        featureSetFallbacks: "APPLE7:APPLE6:APPLE5:APPLE4:APPLE3:APPLE3v1:APPLE2:APPLE1:GLES2,0",
        model: "iPad15,7", thinningProductType: "iPad15,7", modelNumber: "A3354", cornerRadius: 25.0,
        differing: ["touch-id": true, "pearl-id": false, "DeviceSupportsEnhancedMultitasking": false,
                    "GPSCapability": false, "contains-cellular-radio": false, "reverse-zoom": false]))

    /// iPad Pro 13-inch (M5), model iPad17,4 (ipad.md §4).
    static let iPadPro13M5 = pad(id: "ipad-pro-13-m5", name: "iPad Pro 13-inch (M5)", productClass: "J821", PadValues(
        productDescription: "iPad Pro 13-inch (M5)",
        screen: DeviceScreen(width: 2064, height: 2752, scale: 2.0, pitch: 264.0),
        mainScreenClass: 32, orientation: 1.5707963705062866, gamut: "P3", compatibleFallback: "iPad16,6-A",
        memoryClass: 12, featureSetClass: "APPLE10",
        featureSetFallbacks: "APPLE9:APPLE8:APPLE7:APPLE6:APPLE5:APPLE4:APPLE3:APPLE3v1:APPLE2:APPLE1:GLES2,0",
        model: "iPad17,4", thinningProductType: "iPad17,4-A", modelNumber: "A3361", cornerRadius: 30.0,
        differing: ["touch-id": false, "pearl-id": true, "DeviceSupportsEnhancedMultitasking": true,
                    "GPSCapability": true, "contains-cellular-radio": true, "reverse-zoom": true]))
}
