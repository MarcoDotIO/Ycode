import AppKit
import YcodeIDECore

/// Council round 9, rows 216 and 217 (`JumpBarPathLayout`): a title cut to
/// its initial before it goes, and the active pane's chevron colour.
extension FadingTruncationLabel {
    /// The first letter's ink, from the title's ink start (the narrowest
    /// cut keeps it whole, with a little fade after it).
    var initialInk: CGFloat {
        guard let first = stringValue.first else { return 0 }
        let font = self.font ?? .systemFont(ofSize: 11)
        let r = NSAttributedString(string: String(first), attributes: [.font: font])
            .boundingRect(with: NSSize(width: 1000, height: 100), options: [.usesLineFragmentOrigin, .usesDeviceMetrics])
        return max(0, r.maxX - ink.minX)
    }
}

extension JumpBarChevronView {
    /// #808080 in light, #DEDEDE in dark in the active pane (row 217); the
    /// secondary label colour in the inactive one.
    static func color(active: Bool) -> NSColor {
        guard active else { return .secondaryLabelColor }
        return NSColor(name: nil) { a in
            let dark = a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let v = JumpBarPathLayout.chevronColor(dark: dark, active: true) ?? 0
            return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
    }
}
