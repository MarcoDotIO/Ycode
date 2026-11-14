import Foundation
import SwiftUI
import YcodeIDECore

// Settings ▸ Appearance's colour rows on Linux (`specs/ide/settings.md`
// R6.1, R7.1–R7.3; checklist rows 182–184), drawn as the macOS IDE draws
// them (YcodeUI `SettingsR7Views.swift`): the slider (a track of colour
// stops from `ThemeColorTrack`, a knob, a 202.5 × 36 frame that is its
// accessibility element), the colour button (48 × 28 in a slider row,
// 48 × 24 alone), and the row (56 with a slider, 47 with the button only).

/// The colour slider: a 14-point track through the track's stops with a
/// 1-point darker edge, a knob about 28 across (a white rim around the
/// colour under it) at the row's strength; the view is the track plus 11
/// above and below (202.5 × 36), exposed as a slider titled by the row,
/// its value a percentage, with increment and decrement (R7.3).
struct ThemeColorSlider: View {
    var title: String
    var track: ThemeColorTrack
    var value: Binding<Double>
    var target: String
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        #if os(Linux)
        drawn
            .accessibilitySliderElement(label: title, value: value, step: SettingsAppearanceR7.sliderStep)
            .shellTarget(target)
        #else
        drawn
            .accessibilityRepresentation { Slider(value: value, in: 0...1, step: SettingsAppearanceR7.sliderStep) { Text(verbatim: title) } }
            .shellTarget(target)
        #endif
    }

    /// The track through the stops (`factor` scales them toward black: the edge).
    func gradient(_ factor: Double) -> LinearGradient {
        LinearGradient(stops: track.stops.map { Gradient.Stop(color: settingsColor(ThemeColorRows.darker($0.color, factor)), location: CGFloat($0.position)) },
                       startPoint: .leading, endPoint: .trailing)
    }

    var drawn: some View {
        let L = SettingsAppearanceLayout.self
        let R = SettingsAppearanceR6.self
        let k = L.sliderKnob
        let shown = track.color(at: value.wrappedValue)
        return ZStack(alignment: .leading) {
            ZStack {
                Capsule(style: .continuous).fill(gradient(R.trackEdgeFactor))
                Capsule(style: .continuous).fill(gradient(1)).padding(R.edgeWidth)
            }
            .frame(height: L.sliderTrackHeight)
            ZStack {
                Circle().fill(Color.white).shadow(color: Color.black.opacity(0.2), radius: 2, y: 0.5)
                Circle().fill(settingsColor(shown)).padding(R.knobRim)
            }
            .frame(width: k, height: k)
            .offset(x: CGFloat(value.wrappedValue) * (L.sliderWidth - k))
        }
        .frame(width: L.sliderWidth, height: SettingsAppearanceR7.sliderFrameHeight)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            guard isEnabled else { return }
            value.wrappedValue = min(max(Double((g.location.x - k / 2) / (L.sliderWidth - k)), 0), 1)
        })
    }
}

/// The colour button: a capsule with a 3-point rim (#DFDFDF light) around
/// the colour, edged 1 point darker; 48 × 28 in a slider row, 48 × 24 in a
/// colour-only row (R7.1). A click shows #RRGGBB in a popover to edit
/// (empty: the system's). To accessibility it is a button titled by the
/// row whose value is the colour ("rgb 1 0.619608 0.768627 1", R7.3).
struct ThemeColorWell: View {
    var title: String
    var color: (r: Double, g: Double, b: Double)
    var hex: String
    var size: CGSize
    var target: String
    var onCommit: (String?) -> Void
    @State private var editing = false
    @State private var text = ""
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = SettingsPalette(scheme)
        let L = SettingsAppearanceLayout.self
        let R = SettingsAppearanceR6.self
        Button { text = hex; editing = true } label: {
            ZStack {
                Capsule(style: .continuous).fill(p.wellRim)
                Capsule(style: .continuous).fill(settingsColor(ThemeColorRows.darker(color, R.wellEdgeFactor))).padding(L.wellRim)
                Capsule(style: .continuous).fill(settingsColor(color)).padding(L.wellRim + R.edgeWidth)
            }
            .frame(width: size.width, height: size.height)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(ThemeColorRows.accessibilityValue(color))
        .shellTarget(target)
        .popover(isPresented: $editing) {
            TextField("System", text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 110)
                .padding(12)
                .onSubmit {
                    let t = text.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { onCommit(nil) } else if let c = ThemeColorRows.components(t) { onCommit(ThemeColorRows.hex(c.r, c.g, c.b)) }
                    editing = false
                }
        }
    }
}

/// A colour row of the Theme list (R7.1): the label at the top-left (cap
/// top 13 under the row's top); a slider row (56) has the slider and a
/// 48 × 28 button centred, a colour-only row (47) a 48 × 24 button. The
/// track and the knob come from `ThemeColorRows.track` in the row's
/// appearance; a colour-only button shows the colour the editor draws.
struct ThemeColorRowView: View {
    enum Style { case slider, colorOnly }
    var title: String
    var key: String
    var theme: EditorTheme
    var shown: ThemeColor
    var editable: Bool
    var style: Style = .slider
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = SettingsPalette(scheme)
        let R = SettingsAppearanceR7.self
        let resolved = (shown.redFraction, shown.greenFraction, shown.blueFraction)
        let height = style == .slider ? R.sliderRowHeight : R.colorRowHeight
        ZStack(alignment: .topLeading) {
            Text(verbatim: title).font(SettingsFonts.label).foregroundStyle(p.label).lineLimit(1)
                .padding(.leading, SettingsLayout.labelInset)
                .padding(.top, R.labelCapTop - 3)
            // The slider x 421.5–624, the button 632–680 (8 apart, 10 inside the card).
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if style == .slider {
                    let track = ThemeColorRows.track(key, in: theme, resolved: resolved, dark: scheme == .dark)
                    ThemeColorSlider(title: title, track: track, value: Binding(get: { track.strength }, set: { v in
                        guard editable else { return }
                        Preferences.shared.editSelectedTheme { ThemeColorRows.setFromSlider(key, track: track, strength: v, in: &$0) }
                    }), target: "settings color slider \(key)")
                    .allowsHitTesting(editable)
                    well(color: track.knobColor, size: R.sliderButtonSize)
                } else {
                    well(color: resolved, size: R.colorButtonSize)
                }
            }
            .padding(.trailing, SettingsLayout.controlInset)
            .frame(height: height)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(p.card)
        .accessibilityHint(editable ? "" : "Built-in themes cannot be changed")
    }

    func well(color: (r: Double, g: Double, b: Double), size: CGSize) -> some View {
        ThemeColorWell(title: title, color: color, hex: ThemeColorRows.value(key, in: theme) ?? "", size: size, target: "settings color \(key)") { hex in
            Preferences.shared.editSelectedTheme { ThemeColorRows.setTyped(key, hex, in: &$0) }
        }
        .allowsHitTesting(editable)
    }
}
