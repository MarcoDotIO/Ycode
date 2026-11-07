import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

// The debug area's and the editor bottom bar's controls as the AppKit IDE
// draws them (`cross-platform-parity.md` §6; `editor-area.md` F.9).

extension ShellColors {
    private func level(_ light: Double, _ dark: Double) -> Color {
        let v = (self.dark ? dark : light) / 255
        return Color(.sRGB, red: v, green: v, blue: v)
    }
    /// The bottom bars' glyphs and the branch (the AppKit bars' #7F7F7F /
    /// #9A9A9A).
    var barIcon: Color { level(127, 154) }
    /// The debug area's panes (the AppKit text background, #FFFFFF / #1D1E1E).
    var debugPane: Color { level(255, 30) }
    /// The bars' search fields: #FFFFFF / #171717 with a #EBEBEB / #282929 rim.
    var searchFieldFill: Color { level(255, 23) }
    var searchFieldRim: Color { level(235, 41) }
}

/// The breakpoints toggle's tag (F.9): a 17.5 × 11.5 rounded rectangle
/// whose right end is drawn to a point, filled in the accent colour while
/// breakpoints are active, outlined in the secondary colour while not
/// (the AppKit IDE's `BreakpointsToggleGlyph`).
struct BreakpointsTagShape: Shape {
    static let size = CGSize(width: 17.5, height: 11.5)
    static let pointLength: CGFloat = 4.5
    static let cornerRadius: CGFloat = 2.5

    func path(in r: CGRect) -> Path {
        let radius = min(Self.cornerRadius, r.height / 2)
        let bodyEnd = r.maxX - Self.pointLength
        var p = Path()
        p.move(to: CGPoint(x: r.minX + radius, y: r.minY))
        p.addLine(to: CGPoint(x: bodyEnd, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: bodyEnd, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - radius), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        p.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// The debug bar's breakpoints toggle (F.9, parity §6).
struct BreakpointsToggle: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let active = model.debug.breakpoints.isActive
        let s = BreakpointsTagShape.size
        Button { model.perform(.toggleBreakpointsActive) } label: {
            ZStack {
                if active {
                    BreakpointsTagShape().fill(DebugColors.breakpoint).frame(width: s.width, height: s.height)
                } else {
                    BreakpointsTagShape().stroke(c.secondaryLabel, lineWidth: 1.2).frame(width: s.width - 1.5, height: s.height - 1.5)
                }
            }
            .frame(width: s.width, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(active ? "Deactivate breakpoints" : "Activate breakpoints")
        .accessibilityLabel(active ? "Deactivate breakpoints" : "Activate breakpoints")
        .shellTarget("bar breakpoints")
    }
}

/// A bottom bar's Quick Look button (the eye): a popover with `text`
/// (the selected variable, or the console's selected or last line).
struct QuickLookButton: View {
    var text: () -> String?
    var target: String
    @State private var shown: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            shown = text()
        } label: {
            BarIcon("eye", size: 16)   // ink 19 × 11, as the AppKit bar
        }
        .buttonStyle(.plain)
        .help("Quick Look")
        .accessibilityLabel("Quick Look")
        .shellTarget(target)
        .popover(isPresented: Binding(get: { shown != nil }, set: { if !$0 { shown = nil } })) {
            Text(verbatim: shown ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(ShellColors(scheme).label)
                .frame(maxWidth: 360, alignment: .leading)
                .padding(10)
        }
    }
}

/// The console bar's output options (the list glyph; the AppKit IDE's
/// "Metadata Options"): which output the console shows.
struct ConsoleOptionsMenu: View {
    var model: WorkspaceShellModel

    var body: some View {
        let d = model.debug
        Menu {
            ForEach(ConsoleEntry.Filter.allCases, id: \.rawValue) { f in
                Button { d.consoleFilter = f } label: {
                    if d.consoleFilter == f { Label(f.rawValue, systemImage: "checkmark") } else { Text(f.rawValue) }
                }
            }
        } label: {
            BarIcon("list.bullet.rectangle", size: 15)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Metadata Options")
        .accessibilityLabel("Metadata Options")
        .shellTarget("console filter")
    }
}

/// A bottom bar's pop-up with a bezel (the variables scope, 76 × 20).
struct BarPopUpLook: View {
    var title: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        HStack(spacing: 2) {
            Text(verbatim: title).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.label).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(c.label)
        }
        .padding(.horizontal, 7)
        .frame(width: 76, height: 20)
        .background { RoundedRectangle(cornerRadius: 5, style: .continuous).fill(c.popUpFill) }
    }
}
