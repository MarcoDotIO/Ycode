// The device-capabilities plist named by SIMULATOR_CAPABILITIES
// (specs/simulator/device-capabilities.md). The runtime's MobileGestalt
// answers device questions from its `capabilities` dictionary; with no file
// it logs "can't load simulator capabilities dictionary" and many answers
// are missing (CoreUI then cannot pick artwork: "couldn't get
// 'kMGArtworkDeviceIdiom' from MGCopyAnswer", and app icons stay grey).
// The values describe Ycode's one device type, model iPhone19,4, as the
// spec's table lists them.

import Foundation

enum DeviceCapabilities {
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
}
