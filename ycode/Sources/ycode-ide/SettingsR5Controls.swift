import Foundation
import SwiftUI
import YcodeIDECore

// The controls of council round 5 in Settings on Linux
// (`specs/ide/settings.md` R5.1–R5.5), drawn from the numbers and colours
// the macOS IDE draws with (`SettingsAppearanceLayout`,
// `SettingsComponentsLayout`, `SettingsR5Palette`, `ComponentGlyph`,
// `AppearanceThumbnailArt`; YcodeUI `SettingsR5Views.swift`): the
// thumbnails, the segments, the push button, the colour slider and well,
// Components' symbols, rows and info button, and the host page's field.

extension SettingsPalette {
    var ring: Color { color(SettingsR5Palette.ring) }
    var caption: Color { color(SettingsR5Palette.caption) }
    var captionSelected: Color { color(SettingsR5Palette.captionSelected) }
    var previewBorder: Color { color(SettingsR5Palette.previewBorder) }
    var lineNumber: Color { color(SettingsR5Palette.lineNumber) }
    var paneSeparator: Color { color(SettingsR5Palette.paneSeparator) }
    var segmentsTrack: Color { color(SettingsR5Palette.segmentsTrack) }
    var segmentsDivider: Color { color(SettingsR5Palette.segmentsDivider) }
    var segmentsLabel: Color { color(SettingsR5Palette.segmentsLabel) }
    var segmentSelected: Color { color(SettingsR5Palette.segmentSelected) }
    var pushButton: Color { color(SettingsR5Palette.pushButton) }
    var pushButtonLabel: Color { color(SettingsR5Palette.pushButtonLabel) }
    var wellRim: Color { color(SettingsR5Palette.wellRim) }
    var subtitle: Color { color(SettingsR5Palette.subtitle) }
    var platformSymbol: Color { color(SettingsR5Palette.platformSymbol) }
    var fieldFill: Color { color(SimulatorHostPage.fieldFill) }
    var fieldBorder: Color { color(SimulatorHostPage.fieldBorder) }
}

/// An sRGB colour of three fractions.
func settingsColor(_ c: (r: Double, g: Double, b: Double)) -> Color { Color(.sRGB, red: c.r, green: c.g, blue: c.b) }

// MARK: Appearance thumbnails

/// One appearance's 67 × 44 window-on-wallpaper picture, with the 3-point
/// ring 1 point outside it when chosen (the view is 4 points larger on
/// every side, as on macOS).
struct AppearanceThumbnail: View {
    var appearance: Preferences.Appearance
    var chosen: Bool
    @Environment(\.colorScheme) private var scheme

    static var margin: CGFloat { SettingsAppearanceLayout.ringGap + SettingsAppearanceLayout.ringWidth }

    var body: some View {
        let L = SettingsAppearanceLayout.self
        let p = SettingsPalette(scheme)
        ZStack {
            picture
                .frame(width: L.thumbnailSize.width, height: L.thumbnailSize.height)
                .clipShape(RoundedRectangle(cornerRadius: L.thumbnailRadius, style: .continuous))
            if chosen {
                let w = L.ringWidth
                RoundedRectangle(cornerRadius: L.ringRadius - w / 2, style: .continuous)
                    .stroke(p.ring, lineWidth: w)
                    .frame(width: L.thumbnailSize.width + 2 * (L.ringGap + w / 2), height: L.thumbnailSize.height + 2 * (L.ringGap + w / 2))
            }
        }
        .frame(width: L.thumbnailSize.width + 2 * Self.margin, height: L.thumbnailSize.height + 2 * Self.margin)
    }

    @ViewBuilder var picture: some View {
        switch appearance {
        case .light: Self.look(AppearanceThumbnailArt.light)
        case .dark: Self.look(AppearanceThumbnailArt.dark)
        case .system:
            ZStack(alignment: .leading) {
                Self.look(AppearanceThumbnailArt.dark)
                Self.look(AppearanceThumbnailArt.light)
                    .frame(width: SettingsAppearanceLayout.thumbnailSize.width)
                    .mask(alignment: .leading) { Rectangle().frame(width: AppearanceThumbnailArt.splitX) }
            }
        }
    }

    static func look(_ l: AppearanceThumbnailArt.Look) -> some View {
        let w = AppearanceThumbnailArt.window
        let hex = SettingsPalette.hex
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [hex(l.wallpaperTop), hex(l.wallpaperBottom)], startPoint: .top, endPoint: .bottom)
            ThumbnailWave().fill(hex(l.wave).opacity(l.waveOpacity))
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: AppearanceThumbnailArt.windowRadius, style: .continuous).fill(hex(l.window))
                Rectangle().fill(hex(l.titleArea)).frame(height: AppearanceThumbnailArt.titleAreaHeight)
                    .clipShape(UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(topLeading: AppearanceThumbnailArt.windowRadius,
                                                                                         bottomLeading: 0, bottomTrailing: 0,
                                                                                         topTrailing: AppearanceThumbnailArt.windowRadius)))
                RoundedRectangle(cornerRadius: AppearanceThumbnailArt.windowRadius, style: .continuous).stroke(hex(l.windowEdge), lineWidth: 0.5)
            }
            .frame(width: w.width, height: w.height)
            .offset(x: w.minX, y: w.minY)
            ForEach(Array(AppearanceThumbnailArt.dots.enumerated()), id: \.offset) { pair in
                let d = AppearanceThumbnailArt.dotDiameter
                Circle().fill(hex(pair.element.color)).frame(width: d, height: d)
                    .offset(x: pair.element.x - d / 2, y: AppearanceThumbnailArt.dotY - d / 2)
            }
        }
        .frame(width: SettingsAppearanceLayout.thumbnailSize.width, height: SettingsAppearanceLayout.thumbnailSize.height, alignment: .topLeading)
    }
}

/// The thumbnails' wave band.
struct ThumbnailWave: Shape {
    nonisolated func path(in r: CGRect) -> Path {
        var p = Path()
        for (i, q) in AppearanceThumbnailArt.wave.enumerated() {
            let pt = CGPoint(x: r.minX + q.x, y: r.minY + q.y)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

// MARK: Segments, push button, separator

/// Theme / Fonts / Editor: a fully rounded track, 70-point segments, the
/// selected one an accent capsule with a white label, a divider only
/// between two unselected segments.
struct SettingsSegments: View {
    var titles: [String]
    var selection: Binding<Int>
    var target: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = SettingsPalette(scheme)
        let L = SettingsAppearanceLayout.self
        let w = L.segmentsSize.width / CGFloat(titles.count), h = L.segmentsSize.height
        ZStack(alignment: .leading) {
            Capsule(style: .continuous).fill(p.segmentsTrack)
            ForEach(titles.indices, id: \.self) { i in
                let on = i == selection.wrappedValue
                if i > 0, !on, i - 1 != selection.wrappedValue {
                    Rectangle().fill(p.segmentsDivider).frame(width: 1, height: L.segmentDividerHeight).offset(x: CGFloat(i) * w - 0.5)
                }
                Button { selection.wrappedValue = i } label: {
                    Text(verbatim: titles[i])
                        .font(.system(size: SettingsLayout.fontSize, weight: on ? .medium : .regular))
                        .foregroundStyle(on ? Color.white : p.segmentsLabel)
                        .frame(width: w, height: h)
                        .background { if on { Capsule(style: .continuous).fill(p.segmentSelected) } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(titles[i])
                .offset(x: CGFloat(i) * w)
                .shellTarget("\(target) \(i)")
            }
        }
        .frame(width: L.segmentsSize.width, height: h)
    }
}

/// The card push button ("Choose…"): 24 tall, a rounded rectangle of
/// radius 6 (R6.1), #E4E4E4 with a #232323 label.
struct SettingsPushButton: View {
    var title: String
    var target: String
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let p = SettingsPalette(scheme)
        Button(action: action) {
            Text(verbatim: title)
                .font(SettingsFonts.label)
                .foregroundStyle(p.pushButtonLabel)
                .lineLimit(1)
                .padding(.horizontal, SettingsAppearanceLayout.pushButtonPadding)
                .frame(height: SettingsAppearanceLayout.pushButtonHeight)
                .background(RoundedRectangle(cornerRadius: SettingsAppearanceR6.pushButtonRadius, style: .circular).fill(p.pushButton))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .shellTarget(target)
    }
}

/// A line across the detail pane.
struct SettingsPaneSeparator: View {
    var height: CGFloat
    @Environment(\.colorScheme) private var scheme
    var body: some View { Rectangle().fill(SettingsPalette(scheme).paneSeparator).frame(height: height).frame(maxWidth: .infinity) }
}

// MARK: Colour rows

/// The colour slider (R6.1): a 14-point track in one hue, from a pale
/// tint at the left to the full colour at the right
/// (`ThemeColorRows.paleTint`), with a 1-point darker edge, and a knob
/// about 28 across (a white rim around the colour under it) at the row's
/// strength. A built-in theme's row is read-only but drawn in full.
struct ThemeColorSlider: View {
    /// The full colour (the track's right end).
    var base: (r: Double, g: Double, b: Double)
    var value: Binding<Double>
    var target: String
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let L = SettingsAppearanceLayout.self
        let R = SettingsAppearanceR6.self
        let k = L.sliderKnob
        let pale = ThemeColorRows.paleTint(base, strength: 0)
        let shown = ThemeColorRows.paleTint(base, strength: value.wrappedValue)
        let e = R.trackEdgeFactor
        ZStack(alignment: .leading) {
            ZStack {
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: [settingsColor(ThemeColorRows.darker(pale, e)), settingsColor(ThemeColorRows.darker(base, e))],
                                         startPoint: .leading, endPoint: .trailing))
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: [settingsColor(pale), settingsColor(base)], startPoint: .leading, endPoint: .trailing))
                    .padding(R.edgeWidth)
            }
            .frame(height: L.sliderTrackHeight)
            ZStack {
                Circle().fill(Color.white).shadow(color: Color.black.opacity(0.2), radius: 2, y: 0.5)
                Circle().fill(settingsColor(shown)).padding(R.knobRim)
            }
            .frame(width: k, height: k)
            .offset(x: CGFloat(value.wrappedValue) * (L.sliderWidth - k))
        }
        .frame(width: L.sliderWidth, height: k)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            guard isEnabled else { return }
            value.wrappedValue = min(max(Double((g.location.x - k / 2) / (L.sliderWidth - k)), 0), 1)
        })
        .accessibilityLabel(target)
        .shellTarget(target)
    }
}

/// The colour well: a 48 × 28 capsule, a 3-point #DFDFDF rim around the
/// colour (the knob's), the colour edged 1 point darker (R6.1); a click
/// shows #RRGGBB in a popover to edit (empty: the system's).
struct ThemeColorWell: View {
    var color: (r: Double, g: Double, b: Double)
    var hex: String
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
            .frame(width: L.wellSize.width, height: L.wellSize.height)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(target)
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

// MARK: Components

/// A Components symbol in the accent colour (`ComponentGlyph`).
struct ComponentGlyphImage: View {
    var glyph: ComponentGlyph
    var color: Color?
    var lineWidth = ComponentGlyph.lineWidth
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = SettingsPalette(scheme)
        let ink = color ?? p.platformSymbol
        Canvas { ctx, _ in
            for part in glyph.parts {
                switch part {
                case .roundedRect(let r, let radius, let knockout):
                    let path = Path(roundedRect: r, cornerRadius: radius)
                    if knockout {
                        ctx.fill(Path(roundedRect: r.insetBy(dx: -lineWidth, dy: -lineWidth), cornerRadius: radius + lineWidth), with: .color(p.card))
                    }
                    ctx.stroke(path, with: .color(ink), lineWidth: lineWidth)
                case .polyline(let pts):
                    var path = Path()
                    path.addLines(pts)
                    ctx.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                case .dot(let c, let d):
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)), with: .color(ink))
                case .sparkle(let c, let r):
                    var path = Path()
                    path.addLines(ComponentGlyph.sparklePoints(c, r))
                    path.closeSubpath()
                    ctx.fill(path, with: .color(ink))
                }
            }
        }
        .frame(width: glyph.size.width, height: glyph.size.height)
    }
}

/// The 13 × 13 info button: a circle outline with a small "i".
struct SettingsInfoButton: View {
    var label: String
    var target: String
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = SettingsPalette(scheme).subtitle
        let s = SettingsComponentsLayout.infoSize
        Button(action: action) {
            ZStack(alignment: .top) {
                Circle().stroke(ink, lineWidth: 1).frame(width: s - 1, height: s - 1).padding(0.5)
                Circle().fill(ink).frame(width: 1.5, height: 1.5).padding(.top, 3)
                Rectangle().fill(ink).frame(width: 1.2, height: 4.7).padding(.top, 5.3)
            }
            .frame(width: s, height: s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
        .shellTarget(target)
    }
}

/// One Components row: 51.5 tall, the symbol centred 26 inside the card,
/// the title 51 inside (cap top 13.5 under the row's top), the subtitle 15
/// under it (a size 3.25 further right), "Last used …" at the subtitle's
/// size ending 34.5 inside, the info button 11.5 inside.
struct ComponentsRowView: View {
    var row: ComponentsRow
    var info: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = SettingsPalette(scheme)
        let L = SettingsComponentsLayout.self
        ZStack(alignment: .topLeading) {
            ComponentGlyphImage(glyph: row.glyph)
                .frame(width: 2 * L.iconCenterInset, height: L.rowHeight)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: row.title).font(SettingsFonts.label).foregroundStyle(p.label).lineLimit(1)
                    .shellTarget("settings components title \(row.glyph.rawValue)")
                // A size starts 3.25 right of the title; "Built-in" does not (R6.2).
                Text(verbatim: row.subtitle).font(.system(size: L.subtitleFontSize)).foregroundStyle(p.subtitle).lineLimit(1)
                    .padding(.top, L.subtitleBaselineGap - 13)
                    .padding(.leading, row.subtitleInset)
            }
            // A 13-point text's cap top is about 3 under its frame's top.
            .padding(.leading, L.titleInset)
            .padding(.top, L.titleCapTop - 3)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if let used = row.lastUsed {
                    // At the subtitle's size (R6.2).
                    Text(verbatim: used).font(.system(size: SettingsComponentsR6.lastUsedFontSize)).foregroundStyle(p.subtitle).lineLimit(1)
                        .padding(.trailing, L.lastUsedTrailingInset - L.infoTrailingInset - L.infoSize)
                }
                SettingsInfoButton(label: "About \(row.title)", target: "settings components info \(row.glyph.rawValue)", action: info)
                    .padding(.trailing, L.infoTrailingInset)
            }
            .frame(height: L.rowHeight)
        }
        .frame(maxWidth: .infinity, minHeight: L.rowHeight, maxHeight: L.rowHeight, alignment: .topLeading)
        // Opaque, so the card's separator strip shows only between rows.
        .background(p.card)
        .accessibilityLabel([row.title, row.subtitle, row.lastUsed].compactMap { $0 }.joined(separator: ", "))
    }
}

// MARK: The host page

/// A text field in the host page's style: 220 × 22, radius 6, a 1-point
/// border, 12 points; committed on Return.
struct SettingsTextField: View {
    var placeholder: String
    var text: Binding<String>
    var target: String
    var onCommit: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = SettingsPalette(scheme)
        let P = SimulatorHostPage.self
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: P.fieldFontSize))
            .foregroundStyle(p.label)
            .padding(.horizontal, P.fieldPadding)
            .frame(width: P.fieldSize.width, height: P.fieldSize.height)
            .background {
                RoundedRectangle(cornerRadius: P.fieldRadius, style: .continuous).fill(p.fieldFill)
                    .overlay { RoundedRectangle(cornerRadius: P.fieldRadius, style: .continuous).stroke(p.fieldBorder, lineWidth: 1) }
            }
            .onSubmit(onCommit)
            .shellTarget(target)
    }
}

/// The host page's icon: the simulator row icon's gradient in a 40-point
/// rounded square, the host symbol in white.
struct SimulatorHostIcon: View {
    var body: some View {
        let g = SettingsRowIcon.simulator.gradient
        ZStack {
            RoundedRectangle(cornerRadius: SimulatorHostPage.heroIconRadius, style: .continuous)
                .fill(LinearGradient(colors: [SettingsPalette.hex(g.top), SettingsPalette.hex(g.bottom)], startPoint: .top, endPoint: .bottom))
            ComponentGlyphImage(glyph: .simulatorHost, color: .white, lineWidth: 1.6 / 1.2).scaleEffect(1.2)
        }
        .frame(width: SimulatorHostPage.heroIconSize, height: SimulatorHostPage.heroIconSize)
    }
}
