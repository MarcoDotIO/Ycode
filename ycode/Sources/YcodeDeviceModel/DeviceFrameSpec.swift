// What Ycode needs to draw a simulated device and size its windows
// (specs/ide/device-hub.md §4.3, "Ycode implementation"): each device
// type's panels (pixels, scale, pixel density, corner radii) and family.
// The values are Ycode's own device data, the same as ycode-simd's device
// types (`Sources/ycode-simd/DeviceTypes.swift`); no artwork is involved:
// Ycode draws its frames from these numbers.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The kind of device: it decides the frame's band and button layout.
public enum DeviceFamily: String, Sendable, Codable, CaseIterable {
    case phone, pad, vision
    /// Apple Watch (watchos.md §3): a small rounded screen in a body with
    /// the Digital Crown and the side button on its right edge.
    case watch
}

/// Corner radii in points, per corner of a rectangle as shown.
public struct CornerRadii: Equatable, Sendable {
    public var topLeft: Double
    public var topRight: Double
    public var bottomRight: Double
    public var bottomLeft: Double

    public init(topLeft: Double, topRight: Double, bottomRight: Double, bottomLeft: Double) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    public init(all r: Double) { self.init(topLeft: r, topRight: r, bottomRight: r, bottomLeft: r) }

    /// The radii of the same rectangle turned clockwise by `quarterTurns`
    /// quarter turns: the top-left corner moves to the top right, and so on.
    public func turned(_ quarterTurns: Int) -> CornerRadii {
        var r = self
        for _ in 0..<(((quarterTurns % 4) + 4) % 4) {
            r = CornerRadii(topLeft: r.bottomLeft, topRight: r.topLeft, bottomRight: r.topRight, bottomLeft: r.bottomRight)
        }
        return r
    }

    /// Every radius grown by `d` (a concentric outline `d` outside).
    public func grown(by d: Double) -> CornerRadii {
        CornerRadii(topLeft: topLeft + d, topRight: topRight + d, bottomRight: bottomRight + d, bottomLeft: bottomLeft + d)
    }

    /// Every radius multiplied by `s`.
    public func scaled(by s: Double) -> CornerRadii {
        CornerRadii(topLeft: topLeft * s, topRight: topRight * s, bottomRight: bottomRight * s, bottomLeft: bottomLeft * s)
    }

    public var largest: Double { max(topLeft, topRight, bottomRight, bottomLeft) }
}

/// One built-in display of a device type.
public struct DevicePanelSpec: Equatable, Sendable {
    /// The display's name in the stream ("LCD", "LCD-1").
    public var name: String
    /// The framebuffer's pixels, native portrait.
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double
    /// Pixels per inch of the real panel (the device type's dot pitch).
    public var pixelsPerInch: Double
    /// Corner radii in points, native orientation.
    public var cornerRadii: CornerRadii
    /// Quarter turns clockwise from the framebuffer to the panel held
    /// upright (the iPhone Duo's inner panel is mounted at 270°: 1).
    public var uprightQuarterTurns: Int

    public init(name: String, pixelWidth: Int, pixelHeight: Int, scale: Double, pixelsPerInch: Double,
                cornerRadii: CornerRadii, uprightQuarterTurns: Int = 0) {
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.pixelsPerInch = pixelsPerInch
        self.cornerRadii = cornerRadii
        self.uprightQuarterTurns = uprightQuarterTurns
    }

    /// Points, native orientation.
    public var pointSize: CGSize { CGSize(width: Double(pixelWidth) / scale, height: Double(pixelHeight) / scale) }

    /// Points as the panel is held upright (portrait for a phone).
    public var uprightPointSize: CGSize {
        let p = pointSize
        return uprightQuarterTurns % 2 == 1 ? CGSize(width: p.height, height: p.width) : p
    }

    /// Corner radii as the panel is held upright.
    public var uprightCornerRadii: CornerRadii { cornerRadii.turned(uprightQuarterTurns) }
}

/// A device type as the device windows see it.
public struct DeviceFrameSpec: Equatable, Sendable {
    /// Ycode's device type id (`ycode-simd --device-type`).
    public var typeID: String
    /// The device type's name ("iPhone Duo").
    public var name: String
    /// Its model identifier (the display stream hello's `model`).
    public var modelIdentifier: String
    public var family: DeviceFamily
    /// Display 1 first; a foldable has a second (the inner panel).
    public var panels: [DevicePanelSpec]
    /// The physical buttons drawn on the frame and their order.
    public var hasActionButton: Bool

    public init(typeID: String, name: String, modelIdentifier: String, family: DeviceFamily, panels: [DevicePanelSpec],
                hasActionButton: Bool = false) {
        self.typeID = typeID
        self.name = name
        self.modelIdentifier = modelIdentifier
        self.family = family
        self.panels = panels
        self.hasActionButton = hasActionButton
    }

    public var isFoldable: Bool { panels.count > 1 }
    /// visionOS shows no frame (device-hub.md §4.3).
    public var hasFrame: Bool { family != .vision }
    /// The device has volume buttons (Volume Up / Down in the Controls
    /// menu): phones and iPads.
    public var hasVolumeButtons: Bool { family == .phone || family == .pad }
    /// The device turns (Rotate in the control row; a watch does not:
    /// watchos.md §2.2 has no rotation feature, visionOS has no Rotate).
    public var rotates: Bool { family == .phone || family == .pad }
    /// The panel with this stream name, else display 1.
    public func panel(named name: String?) -> DevicePanelSpec { panels.first { $0.name == name } ?? panels[0] }
    public func panelIndex(named name: String?) -> Int { panels.firstIndex { $0.name == name } ?? 0 }

    // MARK: Ycode's device types

    public static let iPhoneDuo = DeviceFrameSpec(
        typeID: "iphone-duo", name: "iPhone Duo", modelIdentifier: "iPhone19,4", family: .phone,
        panels: [DevicePanelSpec(name: "LCD", pixelWidth: 1398, pixelHeight: 2034, scale: 3, pixelsPerInch: 460,
                                 cornerRadii: CornerRadii(topLeft: 8, topRight: 59, bottomRight: 59, bottomLeft: 8)),
                 DevicePanelSpec(name: "LCD-1", pixelWidth: 2007, pixelHeight: 2853, scale: 3, pixelsPerInch: 460,
                                 cornerRadii: CornerRadii(all: 55), uprightQuarterTurns: 1)],
        hasActionButton: true)
    public static let iPhone18Pro = DeviceFrameSpec(
        typeID: "iphone-18-pro", name: "iPhone 18 Pro", modelIdentifier: "iPhone19,2", family: .phone,
        panels: [DevicePanelSpec(name: "LCD", pixelWidth: 1206, pixelHeight: 2622, scale: 3, pixelsPerInch: 460,
                                 cornerRadii: CornerRadii(all: 62))],
        hasActionButton: true)
    public static let iPadA16 = DeviceFrameSpec(
        typeID: "ipad-a16", name: "iPad (A16)", modelIdentifier: "iPad15,7", family: .pad,
        panels: [DevicePanelSpec(name: "LCD", pixelWidth: 1640, pixelHeight: 2360, scale: 2, pixelsPerInch: 264,
                                 cornerRadii: CornerRadii(all: 25))])
    public static let iPadPro13M5 = DeviceFrameSpec(
        typeID: "ipad-pro-13-m5", name: "iPad Pro 13-inch (M5)", modelIdentifier: "iPad17,4", family: .pad,
        panels: [DevicePanelSpec(name: "LCD", pixelWidth: 2064, pixelHeight: 2752, scale: 2, pixelsPerInch: 264,
                                 cornerRadii: CornerRadii(all: 30))])
    public static let visionPro = DeviceFrameSpec(
        typeID: "vision-pro", name: "Apple Vision Pro", modelIdentifier: "RealityDevice14,1", family: .vision,
        panels: [DevicePanelSpec(name: "LCD", pixelWidth: 3840, pixelHeight: 2160, scale: 2, pixelsPerInch: 264,
                                 cornerRadii: CornerRadii(all: 0))])

    /// The thirteen Apple Watch types (watchos.md §3.1; the same ids and
    /// values as ycode-simd's `WatchDeviceTypes.swift`): screen pixels at
    /// scale 2, 326 pixels per inch, one corner radius on all four corners
    /// (§3.3 `displays`); the Ultra types have the Action button.
    public static let watches: [DeviceFrameSpec] = [
        watch("apple-watch-series-12-46mm", "Apple Watch Series 12 (46mm)", "Watch8,3", 416, 496, 50),
        watch("apple-watch-series-12-42mm", "Apple Watch Series 12 (42mm)", "Watch8,4", 374, 446, 44),
        watch("apple-watch-ultra-4-49mm", "Apple Watch Ultra 4 (49mm)", "Watch8,1", 422, 514, 57, ultra: true),
        watch("apple-watch-series-11-46mm", "Apple Watch Series 11 (46mm)", "Watch7,18", 416, 496, 50),
        watch("apple-watch-series-11-42mm", "Apple Watch Series 11 (42mm)", "Watch7,17", 374, 446, 44),
        watch("apple-watch-series-10-46mm", "Apple Watch Series 10 (46mm)", "Watch7,9", 416, 496, 50),
        watch("apple-watch-series-10-42mm", "Apple Watch Series 10 (42mm)", "Watch7,8", 374, 446, 44),
        watch("apple-watch-series-9-45mm", "Apple Watch Series 9 (45mm)", "Watch7,4", 396, 484, 42.5),
        watch("apple-watch-series-9-41mm", "Apple Watch Series 9 (41mm)", "Watch7,3", 352, 430, 38.5),
        watch("apple-watch-ultra-3-49mm", "Apple Watch Ultra 3 (49mm)", "Watch7,12", 422, 514, 57, ultra: true),
        watch("apple-watch-ultra-2-49mm", "Apple Watch Ultra 2 (49mm)", "Watch7,5", 410, 502, 54, ultra: true),
        watch("apple-watch-se-3-44mm", "Apple Watch SE 3 (44mm)", "Watch7,16", 368, 448, 34),
        watch("apple-watch-se-3-40mm", "Apple Watch SE 3 (40mm)", "Watch7,13", 324, 394, 28),
    ]

    static func watch(_ id: String, _ name: String, _ model: String, _ w: Int, _ h: Int, _ radius: Double,
                      ultra: Bool = false) -> DeviceFrameSpec {
        DeviceFrameSpec(typeID: id, name: name, modelIdentifier: model, family: .watch,
                        panels: [DevicePanelSpec(name: "LCD", pixelWidth: w, pixelHeight: h, scale: 2, pixelsPerInch: 326,
                                                 cornerRadii: CornerRadii(all: radius))],
                        hasActionButton: ultra)
    }

    /// Apple Watch Series 12 (46mm), the default watch.
    public static var appleWatchSeries12_46mm: DeviceFrameSpec { watches[0] }

    public static let all: [DeviceFrameSpec] = [iPhoneDuo, iPhone18Pro, iPadA16, iPadPro13M5, visionPro] + watches

    public static func named(typeID: String) -> DeviceFrameSpec? { all.first { $0.typeID == typeID } }

    /// The picture for a device of a family whose type Ycode does not know
    /// (the hub's other simulators): a device of that family's usual size.
    public static func placeholder(for family: DeviceFamily) -> DeviceFrameSpec {
        switch family {
        case .pad: matching(pixelWidth: 1640, pixelHeight: 2360, scale: 2)
        case .watch: matching(pixelWidth: 416, pixelHeight: 496, scale: 2)
        case .vision: visionPro
        case .phone: matching(pixelWidth: 1206, pixelHeight: 2622, scale: 3)
        }
    }

    /// The type a display stream hello describes: its `deviceType`, else its
    /// model identifier, else a device of that display size, else a
    /// generic one of that size (a phone, square corners).
    public static func matching(typeID: String? = nil, model: String? = nil, pixelWidth: Int, pixelHeight: Int,
                                scale: Double) -> DeviceFrameSpec {
        if let typeID, let s = named(typeID: typeID) { return s }
        if let model, let s = all.first(where: { $0.modelIdentifier == model }) { return s }
        if let s = all.first(where: { $0.panels[0].pixelWidth == pixelWidth && $0.panels[0].pixelHeight == pixelHeight }) { return s }
        let points = Double(min(pixelWidth, pixelHeight)) / max(scale, 1)
        // A model of the watch family ("Watch8,3") or a screen no wider than a
        // watch's (at most 211 points): a watch; 600 points or more: an iPad.
        let watch = model?.hasPrefix("Watch") == true || points <= 211
        return DeviceFrameSpec(typeID: "unknown", name: "Device", modelIdentifier: model ?? "",
                               family: watch ? .watch : points >= 600 ? .pad : .phone,
                               panels: [DevicePanelSpec(name: "LCD", pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: max(scale, 1),
                                                        pixelsPerInch: watch ? 326 : scale >= 3 ? 460 : 264,
                                                        cornerRadii: CornerRadii(all: 0))])
    }
}
