import Foundation
import SwiftUI
import YcodeIDECore

// The Settings window's grouped-card form on Linux, as the macOS IDE's
// (`specs/ide/settings.md` R3.3, YcodeUI `SettingsChrome.swift`): section
// headers over rounded cards (#F7F7F7, radius 12), rows 37.5 tall with
// 1-point separators inset 10, labels at the left with no colon, help
// text under them in the secondary colour, and the controls at the right:
// pop-ups as the value and a circular chevron button, switches 36 × 18.
// The geometry and colours are `SettingsLayout` and `SettingsPaletteHex`,
// shared with the macOS IDE.

/// The Settings window's colours for an appearance.
struct SettingsPalette {
    let dark: Bool

    init(_ scheme: ColorScheme) { dark = scheme == .dark }

    func color(_ pair: SettingsPaletteHex.Pair) -> Color {
        let v = dark ? pair.dark : pair.light
        return Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var sidebar: Color { color(SettingsPaletteHex.sidebar) }
    var divider: Color { color(SettingsPaletteHex.divider) }
    var detail: Color { color(SettingsPaletteHex.detail) }
    var card: Color { color(SettingsPaletteHex.card) }
    var separator: Color { color(SettingsPaletteHex.separator) }
    var selection: Color { color(SettingsPaletteHex.selection) }
    var symbol: Color { color(SettingsPaletteHex.symbol) }
    var title: Color { color(SettingsPaletteHex.title) }
    var label: Color { color(SettingsPaletteHex.label) }
    var header: Color { color(SettingsPaletteHex.header) }
    var help: Color { color(SettingsPaletteHex.help) }
    var capsuleFill: Color { color(SettingsPaletteHex.capsuleFill) }
    var capsuleRim: Color { color(SettingsPaletteHex.capsuleRim) }
    var capsuleDivider: Color { color(SettingsPaletteHex.capsuleDivider) }
    var chevron: Color { color(SettingsPaletteHex.chevron) }
    var chevronDisabled: Color { color(SettingsPaletteHex.chevronDisabled) }
    var popUpCircle: Color { color(SettingsPaletteHex.popUpCircle) }
    var popUpChevron: Color { color(SettingsPaletteHex.popUpChevron) }
    var switchOff: Color { color(SettingsPaletteHex.switchOff) }
}

/// The text sizes of the form.
enum SettingsFonts {
    static let label = Font.system(size: SettingsLayout.fontSize)
    static let header = Font.system(size: SettingsLayout.fontSize, weight: .bold)
    static let help = Font.system(size: SettingsLayout.helpFontSize)
    static let title = Font.system(size: SettingsLayout.titleFontSize)
}

/// A pane's form: its sections top to bottom, scrolling, 20 from the
/// detail pane's edges.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                // The first header's cap top 76 down the window: 24 under
                // the title area, less the label's 3 above its cap top.
                .padding(.top, SettingsLayout.firstHeaderCapTop - SettingsLayout.titleAreaHeight - 3)
                .padding(.horizontal, SettingsLayout.cardInset)
                .padding(.bottom, SettingsLayout.cardInset - SettingsSection<EmptyView, EmptyView>.bottomGap)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(SettingsPalette(scheme).detail)
    }
}

/// A section: its bold header and a card of rows, then an optional note.
/// Every row of the card is a `SettingsRow` (or `SettingsContentRow`): the
/// card shows its separators between the rows' opaque fills.
struct SettingsSection<Content: View, Footer: View>: View {
    var title: String?
    var content: Content
    var footer: Footer
    @Environment(\.colorScheme) private var scheme

    /// A card's bottom to the next header's frame (its cap top 33 under the card).
    static var bottomGap: CGFloat { SettingsLayout.cardToHeader - 3 }

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) where Footer == EmptyView {
        self.title = title
        self.content = content()
        footer = EmptyView()
    }

    init(_ title: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        let p = SettingsPalette(scheme)
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(verbatim: title)
                    .font(SettingsFonts.header)
                    .foregroundStyle(p.header)
                    .padding(.leading, SettingsLayout.labelInset)
                    // The header's cap top 22.5 above the card.
                    .frame(height: 16, alignment: .leading)
                    .padding(.bottom, SettingsLayout.headerToCard + 3 - 16)
            }
            SettingsCard { content }
            footer
                .font(SettingsFonts.help)
                .foregroundStyle(p.help)
                .padding(.horizontal, SettingsLayout.labelInset)
                .padding(.top, 6)
        }
        .padding(.bottom, Self.bottomGap)
    }
}

/// The rounded card: rows 1 point apart over a separator-coloured strip
/// inset 10, so the line shows only between two rows.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = SettingsPalette(scheme)
        let shape = RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: SettingsLayout.separatorHeight) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    p.card
                    Rectangle().fill(p.separator).padding(.horizontal, SettingsLayout.separatorInset)
                }
            }
            .clipShape(shape)
    }
}

/// A card row: the label (no colon) at the left with optional help text
/// under it, the control at the right centred on the label's line.
struct SettingsRow<Control: View>: View {
    var title: String
    var help: String?
    var control: Control
    @Environment(\.colorScheme) private var scheme

    init(_ title: String, help: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.help = help
        self.control = control()
    }

    var body: some View {
        let p = SettingsPalette(scheme)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(verbatim: title)
                    .font(SettingsFonts.label)
                    .foregroundStyle(p.label)
                    .lineLimit(1)
                Spacer(minLength: 0)
                // Centred on the label's line, whatever its height.
                control.frame(height: Self.lineHeight)
            }
            if let help, !help.isEmpty { SettingsHelpText(text: help).padding(.top, Self.helpGap) }
        }
        .padding(.horizontal, SettingsLayout.labelInset)
        .padding(.vertical, (SettingsLayout.rowHeight - Self.lineHeight) / 2)
        .frame(maxWidth: .infinity, minHeight: SettingsLayout.rowHeight, alignment: .leading)
        .background(p.card)
    }

    /// The label's line.
    static var lineHeight: CGFloat { 16 }
    /// From the label's line to the help text's: the help's first baseline
    /// 19 under the label's.
    static var helpGap: CGFloat { SettingsLayout.helpBaselineGap - lineHeight + 3 - 2 }
}

extension SettingsRow where Control == EmptyView {
    init(_ title: String, help: String? = nil) {
        self.init(title, help: help) { EmptyView() }
    }
}

/// Help text: 11 points, the secondary colour, a 14-point pitch, at most
/// 416 wide.
struct SettingsHelpText: View {
    var text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(verbatim: text)
            .font(SettingsFonts.help)
            .foregroundStyle(SettingsPalette(scheme).help)
            .lineSpacing(SettingsLayout.helpLinePitch - 13)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: SettingsLayout.helpWidth, alignment: .leading)
    }
}

/// A card row that holds one view (a preview, a list, a row of buttons).
struct SettingsContentRow<Content: View>: View {
    var inset = SettingsLayout.labelInset
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .padding(inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsPalette(scheme).card)
    }
}

/// A note between the cards (a section's footer style).
struct SettingsNote: View {
    var text: String

    var body: some View {
        SettingsHelpText(text: text)
            .padding(.horizontal, SettingsLayout.labelInset)
            .padding(.bottom, SettingsSection<EmptyView, EmptyView>.bottomGap)
    }
}

// MARK: Controls

/// The switch: a 36 × 18 track (light grey off, the accent on) with a
/// white pill knob at its leading or trailing end.
struct SettingsSwitch: View {
    var isOn: Binding<Bool>
    var label: String
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    static let size = CGSize(width: 36, height: 18)

    var body: some View {
        let p = SettingsPalette(scheme)
        let on = isOn.wrappedValue
        Button { isOn.wrappedValue.toggle() } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule(style: .continuous).fill(on ? p.selection : p.switchOff)
                Capsule(style: .continuous)
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.18), radius: 1, y: 0.5)
                    .frame(width: 21, height: Self.size.height - 3)
                    .padding(1.5)
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A switch row: the title at the left, the switch at the right.
struct CheckRow: View {
    var title: String
    var isOn: Binding<Bool>
    var target: String
    var help: String?

    var body: some View {
        SettingsRow(title, help: help) {
            SettingsSwitch(isOn: isOn, label: title).shellTarget(target)
        }
    }
}

/// A card pop-up: the value, then a 20-point circular button with up/down
/// chevrons (its right edge 13.5 inside the card); the options open as a
/// menu with a check at the chosen one.
struct SettingsPopUp<Value: Hashable>: View {
    var selection: Binding<Value>
    var options: [(Value, String)]
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let p = SettingsPalette(scheme)
        let current = options.first { $0.0 == selection.wrappedValue }?.1 ?? ""
        Menu {
            Picker(selection: selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { Text(verbatim: $0.element.1).tag($0.element.0) }
            } label: {
                EmptyView()
            }
        } label: {
            HStack(spacing: SettingsLayout.popUpTextGap) {
                Text(verbatim: current).font(SettingsFonts.label).foregroundStyle(p.label).lineLimit(1)
                ZStack {
                    Circle().fill(p.popUpCircle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(p.popUpChevron)
                }
                .frame(width: SettingsLayout.popUpCircle, height: SettingsLayout.popUpCircle)
            }
            .padding(.trailing, SettingsLayout.popUpCircleInset - SettingsLayout.controlInset)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
    }
}

/// A pop-up row of an enumeration's cases, titled by their raw values.
struct CasePicker<T: RawRepresentable & CaseIterable & Hashable>: View where T.RawValue == String {
    var title: String
    var selection: Binding<T>
    var target: String
    var help: String?

    var body: some View {
        SettingsRow(title, help: help) {
            SettingsPopUp(selection: selection, options: T.allCases.map { ($0, $0.rawValue) }).shellTarget(target)
        }
    }
}

/// A pop-up row of any options.
struct PickerRow<Value: Hashable>: View {
    var title: String
    var selection: Binding<Value>
    var options: [(Value, String)]
    var target: String
    var help: String?

    var body: some View {
        SettingsRow(title, help: help) {
            SettingsPopUp(selection: selection, options: options).shellTarget(target)
        }
    }
}

/// A number row with a fractional value: the value and − / +.
struct DoubleStepperRow: View {
    var title: String
    var value: Binding<Double>
    var range: ClosedRange<Double>
    var step: Double = 1
    var format: (Double) -> String
    var target: String

    var body: some View {
        SettingsRow(title) {
            HStack(spacing: 8) {
                Text(verbatim: format(value.wrappedValue)).font(SettingsFonts.label).monospacedDigit()
                Stepper(title, value: value, in: range, step: step).labelsHidden()
            }
            .shellTarget(target)
        }
    }
}

/// An integer number row.
struct IntStepperRow: View {
    var title: String
    var value: Binding<Int>
    var range: ClosedRange<Int>
    var suffix = ""
    var target: String

    var body: some View {
        SettingsRow(title) {
            HStack(spacing: 8) {
                Text(verbatim: "\(value.wrappedValue)\(suffix)").font(SettingsFonts.label).monospacedDigit()
                Stepper(title, value: value, in: range).labelsHidden()
            }
            .shellTarget(target)
        }
    }
}

/// A read-only value row (the secondary colour at the right).
struct ValueRow: View {
    var title: String
    var value: String
    var target: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SettingsRow(title) {
            Text(verbatim: value).font(SettingsFonts.label).foregroundStyle(SettingsPalette(scheme).help).lineLimit(1).truncationMode(.middle)
                .shellTarget(target ?? "settings value \(title)")
        }
    }
}

/// A row that opens a sub-page: its title, an optional value and a chevron.
struct DrillRow: View {
    var title: String
    var detail = ""
    var target: String
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = SettingsPalette(scheme)
        Button(action: action) {
            SettingsRow(title) {
                HStack(spacing: 6) {
                    if !detail.isEmpty { Text(verbatim: detail).font(SettingsFonts.label).foregroundStyle(p.help).lineLimit(1) }
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.help)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shellTarget(target)
    }
}

/// A sub-page's way back ("‹ Editing"), above its cards.
struct BackRow: View {
    var title: String
    var target: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                Text(verbatim: title).font(SettingsFonts.label)
            }
            .foregroundStyle(SettingsPalette(.light).selection)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, SettingsLayout.labelInset)
        .padding(.bottom, 14)
        .shellTarget(target)
    }
}

/// A small note under a section (the form's footer style).
struct FootNote: View {
    var text: String
    var body: some View { SettingsHelpText(text: text) }
}
