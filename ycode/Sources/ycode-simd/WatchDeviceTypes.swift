// The Apple Watch device types (specs/simulator/watchos.md §3, W-1). Thirteen
// types run on watchOS 27.0; they differ in model, product class, screen,
// corner radius, chrome, the oldest runtime, cellular radio, Action button and
// a few capability values (§3.1, §3.3). Every value here is from the spec
// (the device types' files read as formats, level 2); Ycode ships none of
// those files, no chrome and no mask.
//
// **Ycode decisions** where the spec gives a value for one type only
// (Series 12 46mm) or a selection of the keys:
// - `memoryClass` 3 and `graphicsFeatureSetClass` APPLE11 on the 27.0
//   generation (Series 12, Ultra 4: `Watch8,x`); 2 and APPLE8 on the others
//   ("Series 11 and older", "the older types").
// - `main-screen-orientation` 3π/2 on the types whose display has
//   `nativeRotation` 90 (Series 12, Ultra 4, Ultra 3, Ultra 2), 0 on the
//   others; the spec gives 3π/2 for Series 12 46mm, and nativeRotation per
//   type (watchos.md §9 Q8).
// - `ModelNumber`, `RegulatoryModelNumber` and `CompatibleDeviceFallback`
//   only where the spec gives them (Series 12 46mm); left out elsewhere.
// - Keys the spec does not list are filled like the other records where they
//   describe software (accessibility, application installation,
//   international settings: an app's `UIRequiredDeviceCapabilities` is
//   checked against them) and left absent otherwise; `displays` (kept in the
//   record for the display round, W2), `iconState` and `marketing-name` are
//   not written, as for every type.

import Foundation

extension DeviceType {
    /// What one watch type has of its own (watchos.md §3.1, §3.3).
    struct WatchValues {
        var id: String
        var name: String
        /// "Apple Watch Series 12" (ArtworkTraits' product description).
        var productDescription: String
        var model: String
        var represented: [String]
        var productClass: String
        var width: Int, height: Int
        var mainScreenClass: Int
        var cornerRadius: Double
        /// `com.apple.dt.devicekit.chrome.<chrome>`.
        var chrome: String
        var minRuntime: String
        var cellular = false
        /// The Action button (`com.apple.hid.sting`, `WatchAppButtonCapability`).
        var ultra = false
        /// The 27.0 generation (`Watch8,x`): memory class 3, APPLE11.
        var current = false
        /// `arm64` capability (false on Series 9 and 10 and Ultra 2).
        var arm64 = true
        /// The display's `nativeOrientation`/`nativeRotation` (degrees).
        var nativeRotation = 0
        var modelNumber: String?
        var compatibleFallback: String?
    }

    /// The thirteen types of watchos.md §3.1, in its order.
    static let watchValues: [WatchValues] = [
        WatchValues(id: "apple-watch-series-12-46mm", name: "Apple Watch Series 12 (46mm)", productDescription: "Apple Watch Series 12",
                    model: "Watch8,3", represented: ["Watch8,3", "Watch8,5"], productClass: "N237b", width: 416, height: 496,
                    mainScreenClass: 35, cornerRadius: 50, chrome: "watch5b", minRuntime: "27.0", current: true,
                    nativeRotation: 90, modelNumber: "A3584", compatibleFallback: "Watch7,18"),
        WatchValues(id: "apple-watch-series-12-42mm", name: "Apple Watch Series 12 (42mm)", productDescription: "Apple Watch Series 12",
                    model: "Watch8,4", represented: ["Watch8,2", "Watch8,4"], productClass: "N238s", width: 374, height: 446,
                    mainScreenClass: 34, cornerRadius: 44, chrome: "watch5s", minRuntime: "27.0", cellular: true, current: true,
                    nativeRotation: 90),
        WatchValues(id: "apple-watch-ultra-4-49mm", name: "Apple Watch Ultra 4 (49mm)", productDescription: "Apple Watch Ultra 4",
                    model: "Watch8,1", represented: ["Watch8,1"], productClass: "N240", width: 422, height: 514,
                    mainScreenClass: 38, cornerRadius: 57, chrome: "watch6", minRuntime: "27.0", cellular: true, ultra: true,
                    current: true, nativeRotation: 90),
        WatchValues(id: "apple-watch-series-11-46mm", name: "Apple Watch Series 11 (46mm)", productDescription: "Apple Watch Series 11",
                    model: "Watch7,18", represented: ["Watch7,18", "Watch7,20"], productClass: "N227b", width: 416, height: 496,
                    mainScreenClass: 35, cornerRadius: 50, chrome: "watch5b", minRuntime: "26.0"),
        WatchValues(id: "apple-watch-series-11-42mm", name: "Apple Watch Series 11 (42mm)", productDescription: "Apple Watch Series 11",
                    model: "Watch7,17", represented: ["Watch7,17", "Watch7,19"], productClass: "N227s", width: 374, height: 446,
                    mainScreenClass: 34, cornerRadius: 44, chrome: "watch5s", minRuntime: "26.0"),
        WatchValues(id: "apple-watch-series-10-46mm", name: "Apple Watch Series 10 (46mm)", productDescription: "Apple Watch Series 10",
                    model: "Watch7,9", represented: ["Watch7,9", "Watch7,11"], productClass: "N217b", width: 416, height: 496,
                    mainScreenClass: 35, cornerRadius: 50, chrome: "watch5b", minRuntime: "11.0", arm64: false),
        WatchValues(id: "apple-watch-series-10-42mm", name: "Apple Watch Series 10 (42mm)", productDescription: "Apple Watch Series 10",
                    model: "Watch7,8", represented: ["Watch7,8", "Watch7,10"], productClass: "N217s", width: 374, height: 446,
                    mainScreenClass: 34, cornerRadius: 44, chrome: "watch5s", minRuntime: "11.0", arm64: false),
        WatchValues(id: "apple-watch-series-9-45mm", name: "Apple Watch Series 9 (45mm)", productDescription: "Apple Watch Series 9",
                    model: "Watch7,4", represented: ["Watch7,4", "Watch7,2"], productClass: "N208b", width: 396, height: 484,
                    mainScreenClass: 26, cornerRadius: 42.5, chrome: "watch3b", minRuntime: "10.0", cellular: true, arm64: false),
        WatchValues(id: "apple-watch-series-9-41mm", name: "Apple Watch Series 9 (41mm)", productDescription: "Apple Watch Series 9",
                    model: "Watch7,3", represented: ["Watch7,3", "Watch7,1"], productClass: "N208s", width: 352, height: 430,
                    mainScreenClass: 27, cornerRadius: 38.5, chrome: "watch3s", minRuntime: "10.0", cellular: true, arm64: false),
        WatchValues(id: "apple-watch-ultra-3-49mm", name: "Apple Watch Ultra 3 (49mm)", productDescription: "Apple Watch Ultra 3",
                    model: "Watch7,12", represented: ["Watch7,12"], productClass: "N230", width: 422, height: 514,
                    mainScreenClass: 38, cornerRadius: 57, chrome: "watch6", minRuntime: "26.0", cellular: true, ultra: true,
                    nativeRotation: 90),
        WatchValues(id: "apple-watch-ultra-2-49mm", name: "Apple Watch Ultra 2 (49mm)", productDescription: "Apple Watch Ultra 2",
                    model: "Watch7,5", represented: ["Watch7,5"], productClass: "N210", width: 410, height: 502,
                    mainScreenClass: 29, cornerRadius: 54, chrome: "watch4", minRuntime: "10.0", cellular: true, ultra: true,
                    arm64: false, nativeRotation: 90),
        WatchValues(id: "apple-watch-se-3-44mm", name: "Apple Watch SE 3 (44mm)", productDescription: "Apple Watch SE 3",
                    model: "Watch7,16", represented: ["Watch7,16", "Watch7,14"], productClass: "N244b", width: 368, height: 448,
                    mainScreenClass: 17, cornerRadius: 34, chrome: "watch2b", minRuntime: "26.0", cellular: true),
        WatchValues(id: "apple-watch-se-3-40mm", name: "Apple Watch SE 3 (40mm)", productDescription: "Apple Watch SE 3",
                    model: "Watch7,13", represented: ["Watch7,13", "Watch7,15"], productClass: "N243s", width: 324, height: 394,
                    mainScreenClass: 16, cornerRadius: 28, chrome: "watch2", minRuntime: "26.0"),
    ]

    /// Every watch type, in watchos.md §3.1's order (Series 12 46mm first:
    /// the default on watchOS).
    static let watches: [DeviceType] = watchValues.map(watch)

    /// Apple Watch Series 12 (46mm), model Watch8,3: the default watch.
    static var appleWatchSeries12_46mm: DeviceType { watches[0] }

    /// The hardware features every watch has (watchos.md §3.2), and the
    /// Ultra's Action button.
    static let watchFeatures: Set<String> = ["com.apple.display.aot", "com.apple.display.integrated",
                                             "com.apple.hid.digital-crown", "com.apple.hid.touch-screen"]
    static let actionButtonFeature = "com.apple.hid.sting"

    /// One watch record from its values (watchos.md §3.3).
    static func watch(_ v: WatchValues) -> DeviceType {
        let screen = DeviceScreen(width: v.width, height: v.height, scale: 2.0, pitch: 326.0)
        let featureSet = v.current ? "APPLE11" : "APPLE8"
        let fallbacks = (v.current ? "APPLE10:APPLE9:APPLE8:" : "") + "APPLE7:APPLE6:APPLE5:APPLE4:APPLE3:APPLE3v1:APPLE2:APPLE1:GLES2,0"
        let memoryClass = v.current ? 3 : 2
        // 3π/2 as the device type's file stores it (a 32-bit float widened).
        let orientation = v.nativeRotation == 90 ? Double(Float(3 * Double.pi / 2)) : 0.0
        var artwork: [String: CapabilityValue] = [
            "ArtworkDeviceIdiom": .string("watch"),
            "ArtworkDeviceProductDescription": .string(v.productDescription),
            "ArtworkDeviceScaleFactor": .real(screen.scale),
            "ArtworkDeviceSubType": .integer(screen.height),
            "ArtworkDisplayGamut": .string("P3"),
            "ArtworkDynamicDisplayMode": .string("0"),
            "DevicePerformanceMemoryClass": .integer(memoryClass),
            "GraphicsFeatureSetClass": .string(featureSet),
            "GraphicsFeatureSetFallbacks": .string(fallbacks),
        ]
        if let fallback = v.compatibleFallback { artwork["CompatibleDeviceFallback"] = .string(fallback) }
        var values: [String: CapabilityValue] = [
            "ArtworkTraits": .dictionary(artwork),
            "ScreenDimensionsCapability": .dictionary([
                "main-screen-class": .integer(v.mainScreenClass),
                "main-screen-height": .integer(screen.height),
                "main-screen-orientation": .real(orientation),
                "main-screen-pitch": .integer(Int(screen.pitch)),
                "main-screen-scale": .real(screen.scale),
                "main-screen-width": .integer(screen.width),
            ]),
            "idiom": .string("watch"),
            "modelIdentifier": .string(v.model),
            "ThinningProductType": .string(v.model),
            "device-name": .string("Watch Simulator"),
            "DeviceCornerRadius": .real(v.cornerRadius),
            "HomeButtonType": .integer(0),
            "memoryClass": .integer(memoryClass),
            "subtype": .integer(screen.height),
            "software-dimming-alpha": .integer(0),
            "graphicsClass": .integer(0),
            "displayGamut": .string("P3"),
            "graphicsFeatureSetClass": .string(featureSet),
            "graphicsFeatureSetFallbacks": .string(fallbacks),
        ]
        if let number = v.modelNumber {
            values["ModelNumber"] = .string(number)
            values["RegulatoryModelNumber"] = .string(number)
        }
        // watchos.md §3.3 "true (41)", as listed.
        var trueKeys = [
            "always-on-time", "hardware-detents", "GPSCapability", "magnetometer", "accelerometer", "microphone",
            "bluetooth", "bluetooth-le", "wifi", "location-services", "DeviceSupportsSwimmingWorkouts",
            "DeviceSupportsElton", "stand-alone-contacts", "encrypted-data-partition", "gas-gauge-battery", "ASTC",
            "hidpi", "HEVCDecoder8bitSupported", "HEVCDecoder10bitSupported", "HEVCDecoder12bitSupported",
        ]
        // Software keys the other records have true (Ycode decision, above).
        trueKeys += ["accessibility", "applicationInstallation", "international-settings"]
        // watchos.md §3.3 "false (30)", as listed.
        var falseKeys = [
            "metal", "watch-companion", "touch-id", "pearl-id", "ipad", "DeviceSupportsDynamicIsland", "720p",
            "screenrecorder", "OysterCapability",
        ]
        let cellular = ["telephony", "sms", "contains-cellular-radio"]
        if v.cellular { trueKeys += cellular } else { falseKeys += cellular }
        if v.arm64 { trueKeys.append("arm64") } else { falseKeys.append("arm64") }
        if v.ultra { trueKeys.append("WatchAppButtonCapability") }
        var type = DeviceType(id: v.id, name: v.name, family: .watch, modelIdentifier: v.model, productClass: v.productClass,
                              legacyAssetSuffix: "", screen: screen, extendedDisplayProperties: false, pointerSystem: false,
                              capabilities: capabilities(values, true: trueKeys, false: falseKeys))
        type.platform = .watchOS
        type.minRuntimeVersion = v.minRuntime
        type.features = v.ultra ? watchFeatures.union([actionButtonFeature]) : watchFeatures
        let r = v.cornerRadius
        type.displays = [DisplayEntry(displayName: "LCD", deviceName: "primary", displayType: "integrated", screenID: 1,
                                      width: screen.width, height: screen.height, scale: screen.scale, dpi: screen.pitch,
                                      colorspace: "P3", powerState: 1, hasDigitizer: true,
                                      nativeOrientation: v.nativeRotation, nativeRotation: v.nativeRotation,
                                      cornerRadii: (r, r, r, r),
                                      chromeIdentifier: "com.apple.dt.devicekit.chrome." + v.chrome).capability]
        return type
    }
}
