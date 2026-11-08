import AppKit
import YcodeIDECore

/// The jump bar's issue stepper's colours (`editor-area.md` G.8, H.5;
/// council rows 139 and 161), shared by every editor's jump bar: the
/// chevrons #7F7F7F in light and #9D9D9D in dark, the kind's symbol a
/// white mark on its fill (the warning triangle #FFCB00 in light, #FFE015
/// in dark; the error circle red). The values are `IssueStepper`'s, which
/// the Linux IDE draws from too. The stepper is a fixed-width part at the
/// jump bar's end; the jump bar's collapse rule leaves it alone.
@MainActor
enum JumpBarIssueStepper {
    static func rgb(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func isDark(_ a: NSAppearance) -> Bool { a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    /// The chevrons' colour in the drawing appearance.
    static let chevronColor = NSColor(name: nil) { a in rgb(IssueStepper.chevronColor(dark: isDark(a))) }

    /// The kind's symbol fill in the drawing appearance.
    static func symbolFill(_ kind: IssueStepper.Kind) -> NSColor {
        NSColor(name: nil) { a in rgb(IssueStepper.symbolFill(kind, dark: isDark(a))) }
    }

    /// The kind's symbol: the system symbol with its mark white on the fill.
    static func symbol(_ kind: IssueStepper.Kind) -> NSImage? {
        NSImage(systemSymbolName: kind.symbol, accessibilityDescription: "Issues")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white, symbolFill(kind)])))
    }
}
