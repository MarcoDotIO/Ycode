import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// The File inspector's sections (`WorkspaceShellModel.fileInspector`),
/// laid out as the macOS IDE's `InspectorAreaController` lays them out
/// (`metrics.md` §12.4, §13.3, §16.2; `cross-platform-parity.md` §5):
///
/// - insets 7 from the divider and 8 from the window's edge; headings
///   11-point bold #858587 in a 20-point row, the first raised 3.5;
/// - keys 11 points in the label colour, right-aligned in a 72-point
///   column; values 5 after it;
/// - the Name field 22 tall in a 26-point row, filled, no border; pop-ups
///   16 tall in 22-point rows, filled, the title then an up-down chevron at
///   the column's end;
/// - rules after Type (then 5), after Full Path and Line Endings (6 on each
///   side), and between sections (6 on each side);
/// - multi-line values on a 14-point pitch.
struct FileInspectorView: View {
    var sections: [InspectorSection]
    @Environment(\.colorScheme) private var scheme

    static let headingHeight: CGFloat = 20
    static let firstHeadingRaise: CGFloat = 3.5
    static let ruleGap: CGFloat = 6
    static let afterTypeRule: CGFloat = 5
    static let afterLocation: CGFloat = 1
    static let fileNameToPath: CGFloat = 4
    static let fieldPitch: CGFloat = 26
    static let popUpPitch: CGFloat = 22
    static let linePitch: CGFloat = 14
    static let belowTabBar: CGFloat = 3
    /// Where the value column starts, from the content's leading edge.
    static var valueX: CGFloat { CGFloat(WorkspaceChrome.inspectorKeyColumnWidth + WorkspaceChrome.inspectorKeyToValue) }

    var body: some View {
        let c = ShellColors(scheme)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.offset) { pair in
                if pair.offset > 0 {
                    let g = ruleGaps(before: pair.element.title)
                    rule(c, before: g.before, after: g.after)
                }
                heading(pair.element.title, c)
                    .padding(.bottom, pair.offset == 0 ? Self.firstHeadingRaise : afterHeading(pair.element.title))
                ForEach(Array(pair.element.rows.enumerated()), id: \.offset) { r in
                    row(r.element, c, inset: pair.element.title == "Image Properties" ? CGFloat(ResourceInspectorRhythm.propertyInset) : 3)
                        .padding(.bottom, gap(after: r.element, next: r.offset + 1 < pair.element.rows.count ? pair.element.rows[r.offset + 1] : nil))
                    if r.element.ruleAfter {
                        rule(c, before: r.element.key == "Type" ? 0 : Self.ruleGap, after: r.element.key == "Type" ? Self.afterTypeRule : Self.ruleGap)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .padding(.leading, CGFloat(WorkspaceChrome.inspectorLeadingInset))
        .padding(.trailing, CGFloat(WorkspaceChrome.inspectorTrailingInset))
        // The macOS contents start 3 below the tab bar (under its 2-point
        // separator's room).
        .padding(.top, Self.belowTabBar + CGFloat(WorkspaceChrome.inspectorContentTopInset) - Self.firstHeadingRaise)
    }

    /// An image's sections below the tags (G.5, row 135; the macOS
    /// inspector's `InspectorStyle.Resource`).
    var isResource: Bool { sections.contains { $0.title == "Image Properties" } }

    /// The gaps around the rule above a section's header.
    func ruleGaps(before title: String) -> (before: CGFloat, after: CGFloat) {
        typealias R = ResourceInspectorRhythm
        guard isResource else { return (Self.ruleGap, Self.ruleGap) }
        return switch title {
        case "Image Properties": (CGFloat(R.tagsToRule), CGFloat(R.ruleToHeader))
        case "Localization": (CGFloat(R.propertiesToRule), CGFloat(R.ruleToHeader))
        case "Target Membership": (CGFloat(R.buttonToRule), CGFloat(R.ruleToHeader))
        default: (Self.ruleGap, Self.ruleGap)
        }
    }

    /// The room under a section's header.
    func afterHeading(_ title: String) -> CGFloat {
        typealias R = ResourceInspectorRhythm
        guard isResource else { return 0 }
        return switch title {
        case "On Demand Resource Tags": CGFloat(R.headerToTags)
        case "Image Properties": CGFloat(R.headerToProperties)
        case "Localization": CGFloat(R.headerToButton)
        case "Target Membership": CGFloat(R.headerToMembership)
        default: 0
        }
    }

    /// The room after a row (before the next row of its section).
    func gap(after r: InspectorRow, next: InspectorRow?) -> CGFloat {
        guard next != nil, !r.ruleAfter else { return 0 }
        if r.key == "Location" { return Self.afterLocation }
        if case .label = r.value { return Self.fileNameToPath }
        return 0
    }

    func heading(_ s: String, _ c: ShellColors) -> some View {
        Text(verbatim: s).font(ShellFonts.smallBold).tracking(ShellFonts.smallTracking).foregroundStyle(c.inspectorHeading)
            .lineLimit(1)
            .padding(.leading, -1)
            .frame(height: Self.headingHeight, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    func rule(_ c: ShellColors, before: CGFloat = ruleGap, after: CGFloat = ruleGap) -> some View {
        Hairline(color: c.inspectorRule).padding(.top, before).padding(.bottom, after)
    }

    func key(_ s: String, _ c: ShellColors) -> some View {
        Text(verbatim: s).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.inspectorText)
            .lineLimit(1)
            // A long key keeps its width and runs left of the column (the
            // macOS inspector tightens it instead).
            .fixedSize()
            .frame(width: CGFloat(WorkspaceChrome.inspectorKeyColumnWidth), alignment: .trailing)
    }

    @ViewBuilder
    func row(_ r: InspectorRow, _ c: ShellColors, inset: CGFloat = 3) -> some View {
        switch r.value {
        case .field, .popUp:
            // One line, centred in the row's pitch.
            HStack(alignment: .center, spacing: 0) {
                key(r.key, c)
                value(r.value, c).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: pitch(of: r.value))
        case .steppers:
            // The key centred on the value, its stepper and its title.
            HStack(alignment: .center, spacing: CGFloat(WorkspaceChrome.inspectorKeyToValue)) {
                key(r.key, c)
                value(r.value, c).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
        case .tags, .button, .membership:
            // Across the content.
            value(r.value, c).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        case .text(let s) where r.key.isEmpty:
            // A note under the controls (EditorConfig's), 150 wide.
            HStack(spacing: CGFloat(WorkspaceChrome.inspectorKeyToValue)) {
                key("", c)
                wrapped(s, width: 150, c.inspectorText)
            }
        case .text:
            HStack(alignment: .firstTextBaseline, spacing: CGFloat(WorkspaceChrome.inspectorKeyToValue)) {
                key(r.key, c)
                value(r.value, c).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, inset)
        default:
            HStack(alignment: .firstTextBaseline, spacing: CGFloat(WorkspaceChrome.inspectorKeyToValue)) {
                key(r.key, c)
                value(r.value, c).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    func pitch(of v: InspectorRow.Value) -> CGFloat {
        if case .field = v { return Self.fieldPitch }
        return Self.popUpPitch
    }

    /// Text that wraps on the 14-point pitch (paths break after "/" and "-").
    func wrapped(_ s: String, width: CGFloat, _ color: Color) -> some View {
        Text(verbatim: s).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(color)
            .lineSpacing(0.6)
            .lineLimit(12)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
    }

    @ViewBuilder
    func value(_ v: InspectorRow.Value, _ c: ShellColors) -> some View {
        switch v {
        case .field(let s):
            // The field's box starts 2 before the value column (its text 6
            // inside); filled, no border.
            Text(verbatim: s).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.inspectorText).lineLimit(1)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22, alignment: .leading)
                .background { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c.inspectorFieldFill) }
                .padding(.leading, CGFloat(WorkspaceChrome.inspectorKeyToValue) - 2)
        case .popUp(let s, let button, let enabled, let dimmed):
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    Text(verbatim: s).font(ShellFonts.small).tracking(ShellFonts.smallTracking)
                        .foregroundStyle(dimmed || !enabled ? c.inspectorDimmed : c.inspectorText)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(enabled ? c.inspectorText : c.inspectorDimmed)
                }
                .padding(.leading, 8)
                .padding(.trailing, 5)
                .frame(height: 16)
                .background { RoundedRectangle(cornerRadius: 5, style: .continuous).fill(c.inspectorPopUpFill) }
                if let button {
                    Image(systemName: button).font(.system(size: 12)).foregroundStyle(c.inspectorText)
                        .frame(width: 18)
                }
            }
        case .label(let s, let bold):
            Text(verbatim: s).font(bold ? ShellFonts.smallBold : ShellFonts.small).tracking(ShellFonts.smallTracking)
                .foregroundStyle(c.inspectorText).lineLimit(1)
        case .path(let s, let button):
            HStack(alignment: .top, spacing: 0) {
                // 140 points, the macOS label's preferred width.
                wrapped(s, width: 140, c.inspectorText)
                Spacer(minLength: 0)
                Image(systemName: button).font(.system(size: 13)).foregroundStyle(c.inspectorDimmed)
                    .frame(width: 15, height: 15)
                    .padding(.trailing, 8)
                    .offset(y: -3)
            }
        case .text(let s):
            wrapped(s, width: 164, c.inspectorText)
        case .steppers(let list, let enabled):
            HStack(alignment: .top, spacing: 6) {
                ForEach(Array(list.enumerated()), id: \.offset) { pair in
                    VStack(spacing: 1) {
                        HStack(spacing: 6) {
                            // The value's 10-point column, then the stepper's
                            // 17-point frame (the macOS small stepper's).
                            Text(verbatim: "\(pair.element.value)").font(ShellFonts.small).tracking(ShellFonts.smallTracking)
                                .foregroundStyle(enabled ? c.inspectorText : c.inspectorDimmed)
                                .frame(width: 10, alignment: .leading)
                            StepperLook(enabled: enabled).frame(width: 17)
                        }
                        Text(verbatim: pair.element.title).font(.system(size: 9)).foregroundStyle(c.secondaryLabel)
                    }
                }
            }
        case .tags(let placeholder, let enabled):
            Text(verbatim: placeholder).font(ShellFonts.small).tracking(ShellFonts.smallTracking)
                .foregroundStyle(enabled ? c.tertiaryLabel : c.inspectorDimmed)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: enabled ? 24 : 22, alignment: .leading)
                .background { if enabled { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c.inspectorFieldFill) } }
        case .button(let title):
            // Localize…: as wide as the value area, 16 tall, filled, centred.
            Text(verbatim: title).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.inspectorText)
                .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16)
                .background { RoundedRectangle(cornerRadius: 5, style: .continuous).fill(c.inspectorPopUpFill) }
        case .membership(let members):
            MembershipBox(members: members)
        }
    }
}

/// A small stepper's look: up and down arrows in a 13 × 20 rounded bezel.
struct StepperLook: View {
    var enabled: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        VStack(spacing: 2) {
            Image(systemName: "chevron.up").font(.system(size: 7, weight: .semibold))
            Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
        }
        .foregroundStyle(enabled ? c.inspectorText : c.inspectorDimmed)
        .frame(width: 13, height: 20)
        .background { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c.inspectorPopUpFill) }
    }
}

/// Target Membership's box: a bordered table 110 tall, one row per target
/// (the target's icon, its name and "Default" under it), and a 19-point
/// footer under a line (`metrics.md` §12.4).
struct MembershipBox: View {
    var members: [InspectorRow.Member]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(members.enumerated()), id: \.offset) { pair in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3.6, style: .continuous).fill(c.accent).frame(width: 16, height: 16)
                            .opacity(pair.element.isMember ? 1 : 0.35)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: pair.element.name).font(ShellFonts.small).foregroundStyle(c.inspectorText).lineLimit(1)
                            Text(verbatim: "Default").font(.system(size: 9)).foregroundStyle(c.secondaryLabel)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
            Hairline(color: c.inspectorTableBorder)
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 10))
                Image(systemName: "minus").font(.system(size: 10))
                Spacer()
            }
            .foregroundStyle(c.inspectorText)
            .padding(.horizontal, 6)
            .frame(height: 19)
        }
        .frame(maxWidth: .infinity, minHeight: 110, maxHeight: 110)
        .overlay { Rectangle().stroke(c.inspectorTableBorder, lineWidth: 1) }
    }
}
