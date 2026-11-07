import Foundation
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Desktop control looks (B5-OPENVIEWS; `cross-platform-parity.md` §15
// OV-5): on a window-system back end (`_desktopChrome`) bordered buttons,
// rounded-border text fields, pop-up and segmented pickers and steppers take
// the macOS IDE's sizes, fills, radii and text. Values are Ycode's macOS IDE
// as the window server drew it (the B5-PARITY shots, 1x):
//
// | Control | Size | Fill (light / dark) | Radius | Text |
// |---|---|---|---|---|
// | push button (`.bordered`) | 24 tall at 13 pt, label + 12 each side | #E4E4E4 / #363636 (black 0.105, white 0.075) | 6 | the label colour |
// | text field (`.roundedBorder`) | 23 tall at 13 pt, text 6 in | #FFFFFF / #171717, hairline #EBEBEB / #282929 | 6 | — |
// | pop-up (`.menu`) | 20 tall: the value, then a 20-point well with up and down chevrons (#E5E5E5 / #363636) | — | well round | the label colour |
// | pop-up, borderless (`.menuStyle(.borderlessButton)`) | the column's width, 16 tall at 11 pt: the value 6 in, chevrons 7 from the end | black 0.07 / white 0.115 (#3E3F40 on the sidebar) | 5 | the label colour |
// | segmented | 16 / 20 / 24 / 28 (mini … large), 10 / 11 / 13 / 13 pt | track black 0.07 / white 0.119 (#E1E1E2 / #3F4041); selected segment black 0.115 / white 0.13 over the track (#C7C7C8 / #58595A), full height | 5 | the label colour, both states |
// | stepper | 17 × 20, chevrons up and down | black 0.037 / white 0.06 (#E9E9EA / #323334) | 5 | chevrons in the label colour |

package enum DesktopControlMetrics {
    static func buttonRadius(_ size: ControlSize) -> CGFloat {
        switch size {
        case .mini, .small: return 5
        case .regular: return 6
        case .large, .extraLarge: return 8
        }
    }

    /// Horizontal padding of push buttons (vertical: centred in the height).
    static func buttonPadding(_ size: ControlSize) -> (h: CGFloat, v: CGFloat) {
        switch size {
        case .mini: return (7, 0)
        case .small: return (9, 0)
        case .regular: return (12, 0)
        case .large: return (14, 0)
        case .extraLarge: return (16, 0)
        }
    }

    /// Push buttons' heights (the macOS IDE's regular one: 24).
    static func buttonHeight(_ size: ControlSize) -> CGFloat {
        switch size {
        case .mini: return 16
        case .small: return 20
        case .regular: return 24
        case .large: return 28
        case .extraLarge: return 36
        }
    }

    /// The push button's bezel.
    static func bezel(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.075) : Color.black.opacity(0.105)
    }

    /// The pop-up's well.
    static func well(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(ycodeHex: 0x363636) : Color(ycodeHex: 0xE5E5E5)
    }

    static func borderlessPopUpFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.115) : Color.black.opacity(0.07)
    }

    static func segmentTrack(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.119) : Color.black.opacity(0.07)
    }

    /// Drawn over the track.
    static func segmentSelected(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.13) : Color.black.opacity(0.115)
    }

    static func segmentHeight(_ size: ControlSize) -> CGFloat {
        switch size {
        case .mini: return 16
        case .small: return 20
        case .regular: return 24
        case .large, .extraLarge: return 28
        }
    }

    static func segmentFont(_ size: ControlSize) -> Font {
        switch size {
        case .mini: return .system(size: 10)
        case .small: return .system(size: 11)
        default: return .system(size: 13)
        }
    }

    static let stepperSize = CGSize(width: 17, height: 20)

    static func stepperFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.037)
    }

    static let segmentRadius: CGFloat = 5
}

/// The up and down chevrons of pop-ups and steppers (OpenViews' own
/// strokes).
struct UpDownChevrons: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        let cx = rect.midX
        p.move(to: CGPoint(x: cx - w / 2, y: rect.minY + h * 0.36))
        p.addLine(to: CGPoint(x: cx, y: rect.minY))
        p.addLine(to: CGPoint(x: cx + w / 2, y: rect.minY + h * 0.36))
        p.move(to: CGPoint(x: cx - w / 2, y: rect.maxY - h * 0.36))
        p.addLine(to: CGPoint(x: cx, y: rect.maxY))
        p.addLine(to: CGPoint(x: cx + w / 2, y: rect.maxY - h * 0.36))
        return p
    }
}
