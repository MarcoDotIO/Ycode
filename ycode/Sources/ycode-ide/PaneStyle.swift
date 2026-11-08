import SwiftUI
import YcodeIDECore
import YcodeIDEShell

// The navigator's and inspector's look as the macOS IDE draws it
// (`specs/ide/cross-platform-parity.md` §3, §5, §7; the values were read
// from that IDE's windows drawn by the window server, light and dark). Where
// AppKit composites a translucent colour over the sidebar material, the
// colour here is the composite, since OpenViews draws these areas flat.

extension ShellColors {
    private func rgb(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
        let v = self.dark ? dark : light
        return Color(.sRGB, red: v.0 / 255, green: v.1 / 255, blue: v.2 / 255)
    }

    /// The glass capsules over the panes (the selector bar, the inspector's
    /// tab bar, the "+" circle and the filter capsule): #E7E7E8 / #393A3B.
    var paneCapsuleFill: Color { rgb((231, 231, 232), (57, 58, 59)) }
    /// Their rim: darker than the fill in light, lighter in dark.
    var paneCapsuleRim: Color { rgb((214, 214, 215), (72, 73, 74)) }
    /// The selected navigator's or inspector's pill: #D0D0D0 / #545556.
    var panePill: Color { rgb((208, 208, 208), (84, 85, 86)) }
    /// The selector bar's glyphs: the label colour (selected or not) as
    /// the glass capsule renders it, #3F3F3F / #EEEEEE.
    var selectorGlyph: Color { rgb((63, 63, 63), (238, 238, 238)) }
    /// The inspector's tab glyphs: the label colour at 39 % over the pill
    /// (selected; #7C7D7E-like, `fidelity-council.md` row 18) or 35 % over
    /// the capsule.
    func inspectorTabGlyph(selected: Bool) -> Color {
        selected ? rgb((127, 127, 127), (151, 151, 152)) : rgb((150, 150, 151), (126, 127, 127))
    }

    /// Navigator row labels: #3B3B3C, white at 85 % in dark; white on the
    /// accent band.
    var navigatorLabel: Color { onAccent ? .white : rgb((59, 59, 60), (222, 222, 223)) }
    /// The navigator's selection band without focus (black at 4.5 %,
    /// white at 10 %).
    var navigatorBand: Color { rgb((231, 231, 232), (51, 52, 53)) }

    /// The inspector's keys and values: the label colour (black at 85 %,
    /// white at 85 %) over the sidebar.
    var inspectorText: Color { rgb((36, 36, 36), (222, 222, 223)) }
    /// Section headings: #858587 bold in light, the secondary label colour
    /// in dark (`metrics.md` §13.3).
    var inspectorHeading: Color { rgb((133, 133, 135), (157, 157, 158)) }
    /// Greyed titles ("No Explicit …") and disabled values.
    var inspectorDimmed: Color { rgb((121, 121, 121), (130, 131, 132)) }
    /// The rules between and inside sections.
    var inspectorRule: Color { rgb((218, 218, 219), (63, 64, 65)) }
    /// The filled Name field (label colour at 10 %) and pop-ups (11.5 %).
    var inspectorFieldFill: Color { rgb((218, 218, 219), (59, 60, 61)) }
    var inspectorPopUpFill: Color { rgb((214, 214, 215), (62, 63, 64)) }
    /// A resource's On Demand Resource Tags field: #E0E0E1 in light
    /// (`editor-area.md` H.7, council row 162), the field fill in dark; its
    /// "Tags" placeholder #707071 in light.
    var inspectorTagsFill: Color { rgb((224, 224, 225), (59, 60, 61)) }
    var inspectorTagsPlaceholder: Color { rgb((112, 112, 113), (130, 131, 132)) }
    /// Target Membership's box border (label colour at 35 %).
    var inspectorTableBorder: Color { rgb((166, 166, 167), (113, 113, 114)) }

    /// The project navigator's icon colours (`WorkspaceChrome.IconTint`):
    /// the system orange and blue, a lighter blue for folders, neutral grey
    /// for plain groups.
    func icon(_ t: WorkspaceChrome.IconTint) -> Color {
        if onAccent { return .white }
        return switch t {
        case .orange: rgb((255, 141, 40), (255, 146, 48))
        case .blue: rgb((0, 136, 255), (0, 145, 255))
        case .lightBlue: rgb((127, 186, 255), (76, 168, 255))
        case .grey: rgb((123, 123, 128), (153, 153, 153))
        case .accent: accent
        }
    }
}

/// A filled glass capsule over a pane (selector bar, inspector tabs,
/// filter capsule).
struct PaneCapsule: View {
    var height: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        Capsule(style: .continuous).fill(c.paneCapsuleFill)
            .overlay { Capsule(style: .continuous).stroke(c.paneCapsuleRim, lineWidth: 1) }
            .frame(height: height)
    }
}
