// Scale and window sizes of the device windows (device-hub.md §2.2, §4.2,
// "Ycode implementation"). Scale is view points per device point.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The hub canvas's zoom (§4.2): Zoom to Fit (the default), Actual
/// (physical) Size, or a step chosen with Zoom In / Zoom Out.
public enum DeviceZoomMode: Equatable, Sendable {
    case fit
    case actual
    case scale(Double)

    /// The value Ycode keeps in its preferences ("fit", "actual", "0.75").
    public var storedValue: String {
        switch self {
        case .fit: "fit"
        case .actual: "actual"
        case .scale(let s): String(s)
        }
    }

    public init?(storedValue v: String) {
        switch v {
        case "fit": self = .fit
        case "actual": self = .actual
        default:
            guard let s = Double(v), s > 0 else { return nil }
            self = .scale(s)
        }
    }
}

public enum DeviceZoom {
    /// Zoom In / Zoom Out steps (Q7, Ycode decision).
    public static let steps: [Double] = [0.25, 1.0 / 3, 0.5, 2.0 / 3, 0.75, 1, 1.25, 1.5, 2, 3, 4]
    /// Zoom to Fit's margin around the device in the canvas (Q7, Ycode decision).
    public static let fitMargin: Double = 24

    /// The scale that fits `content` into `area` less the margin on every
    /// side (never above 4, never below 0.05).
    public static func fit(_ content: CGSize, in area: CGSize, margin: Double = fitMargin) -> Double {
        guard content.width > 0, content.height > 0 else { return 1 }
        let w = max(1, Double(area.width) - 2 * margin), h = max(1, Double(area.height) - 2 * margin)
        return min(4, max(0.05, min(w / Double(content.width), h / Double(content.height))))
    }

    /// The next step above the scale (the largest step when there is none).
    public static func zoomIn(from s: Double) -> Double { steps.first { $0 > s * 1.001 } ?? steps.last! }
    /// The next step below the scale (the smallest step when there is none).
    public static func zoomOut(from s: Double) -> Double { steps.last { $0 < s * 0.999 } ?? steps.first! }

    /// The scale at which a panel shows at its real-world size on a Mac
    /// display of `displayPointsPerInch` points per inch: one device point
    /// is scale / pixelsPerInch inches.
    public static func physical(panel: DevicePanelSpec, displayPointsPerInch: Double) -> Double {
        guard panel.pixelsPerInch > 0, displayPointsPerInch > 0 else { return 1 }
        return panel.scale / panel.pixelsPerInch * displayPointsPerInch
    }

    /// Points per inch of a display `pointWidth` points wide whose panel is
    /// `millimetresWide` mm wide (nil when the size is unknown).
    public static func displayPointsPerInch(pointWidth: Double, millimetresWide: Double) -> Double? {
        guard pointWidth > 0, millimetresWide > 1 else { return nil }
        return pointWidth / (millimetresWide / 25.4)
    }
}

/// The compact device window (§2.2): a toolbar with the title, the device
/// filling the width with a side margin, the device-control row under it.
/// Resizing the window scales the device; the window keeps the device's
/// aspect plus the toolbar and the control row (Ycode decision for the
/// numbers below; a saved compact iPhone window of the reference was
/// 296 × 620).
public enum CompactWindowLayout {
    /// The unified toolbar's height (the content runs under it).
    public static let toolbarHeight: Double = 52
    /// Space between the toolbar and the device.
    public static let topGap: Double = 4
    /// Space on each side of the device.
    public static let sideMargin: Double = 17
    /// The control row: its height, the gap above it and its distance from
    /// the window's bottom edge.
    public static let controlsHeight: Double = 37
    public static let controlsGap: Double = 10
    public static let bottomMargin: Double = 8
    /// The smallest window width: room for the window buttons, the title
    /// and the Expand │ More Actions capsule (AppKit's unified toolbar moves
    /// the capsule into its overflow menu below about 330 points) and for
    /// the iPhone Duo's control row.
    public static let minimumWidth: Double = 340

    /// Height taken by everything but the device.
    public static func chromeHeight(toolbar: Double = toolbarHeight) -> Double { toolbar + topGap + controlsGap + controlsHeight + bottomMargin }

    /// The scale at which a device of `device` points fills a window `width` wide.
    public static func scale(device: CGSize, windowWidth width: Double) -> Double {
        guard device.width > 0 else { return 1 }
        return max(0.05, (width - 2 * sideMargin) / Double(device.width))
    }

    /// The window's content size for a device of `device` points shown at `scale`.
    public static func contentSize(device: CGSize, scale: Double, toolbar: Double = toolbarHeight) -> CGSize {
        CGSize(width: (Double(device.width) * scale + 2 * sideMargin).rounded(),
               height: (Double(device.height) * scale + chromeHeight(toolbar: toolbar)).rounded())
    }

    /// The content size the window takes when the user drags it to
    /// `proposed`: the width decides, the height follows the device's aspect.
    public static func constrainedContentSize(device: CGSize, proposed: CGSize, toolbar: Double = toolbarHeight) -> CGSize {
        let w = max(minimumWidth, Double(proposed.width))
        return contentSize(device: device, scale: scale(device: device, windowWidth: w), toolbar: toolbar)
    }

    /// The device's rectangle in the content (origin top left).
    public static func deviceRect(device: CGSize, contentWidth width: Double, toolbar: Double = toolbarHeight) -> CGRect {
        let s = scale(device: device, windowWidth: width)
        let w = Double(device.width) * s, h = Double(device.height) * s
        return CGRect(x: (width - w) / 2, y: toolbar + topGap, width: w, height: h)
    }

    /// The window a device rotation leads to: the same scale, the new shape
    /// (portrait → a tall window, landscape → a wide one), centred where the
    /// old one was.
    public static func rotatedContentSize(oldDevice: CGSize, newDevice: CGSize, contentWidth: Double,
                                          toolbar: Double = toolbarHeight) -> CGSize {
        contentSize(device: newDevice, scale: scale(device: oldDevice, windowWidth: contentWidth), toolbar: toolbar)
    }

    /// The default window: the device at about `targetHeight` points tall
    /// (Ycode decision: 510), never narrower than `minimumWidth` (a portrait
    /// iPhone 18 Pro window is 340 × about 750).
    public static func defaultScale(device: CGSize, targetHeight: Double = 510) -> Double {
        guard device.height > 0 else { return 0.5 }
        let byHeight = min(1, targetHeight / Double(max(device.height, device.width * 0.75)))
        return max(byHeight, scale(device: device, windowWidth: minimumWidth))
    }
}
