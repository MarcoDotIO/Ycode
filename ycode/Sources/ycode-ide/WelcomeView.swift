import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// The Welcome screen (`reference-ui-6.md` §1.4, `metrics.md` §8, §13.4,
/// §16.3): the AppKit IDE's Welcome window, 480 × 632, in a plain window of
/// its own (`WelcomeWindowRoot`; `cross-platform-parity.md` §9), laid out with the
/// AppKit window's numbers (`WelcomeMetrics`): the 98-point icon 15.5
/// above the name's capitals, "Ycode" bold with 13-point capitals, the
/// version, Open… | Clone… | New Project (107, 107 and 130 wide, 36 tall,
/// 8 apart, top at 242), then the recent projects in a rounded box (x
/// 60–420, y 295–572) with 47-point rows.
struct WelcomeView: View {
    @Bindable var app: ShellAppModel
    @State private var selected = 0
    /// The close button is under the pointer (P-186).
    @State private var closeHovered = false
    /// The recent list has keyboard focus (L-070, L-177).
    @FocusState private var recentsFocused: Bool
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let m = WelcomeMetrics.self
        ZStack(alignment: .top) {
            gray(255, 29)   // the AppKit window's background, #FFFFFF / #1D1D1E
            // P-186: the close button first in accessibility order: a
            // 37-point circle (centred where the 36-point one was) with a
            // 13-point ×, its fill brightening on hover.
            HStack(spacing: 0) {
                Button { dismissWindow() } label: {
                    // The glyph at 17 points: its ink about 13 (as the AppKit ×).
                    Image(systemName: "xmark").font(.system(size: closeGlyphFont, weight: .semibold)).foregroundStyle(c.secondaryLabel)
                        .frame(width: closeSide, height: closeSide)
                        .background { Circle().fill(closeHovered ? closeHoverFill : welcomeCloseFill) }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { closeHovered = $0 }
                .help("Close")
                .accessibilityLabel("Close")
                .shellTarget("welcome close")
                Spacer(minLength: 0)
            }
            .padding(.top, 19.5)
            .padding(.leading, 19.5)
            YcodeMark(size: m.iconFrameSide)
                .frame(width: m.iconFrameSide, height: m.iconFrameSide)
                .padding(.top, m.iconFrameTop)
            Text("Ycode").font(.system(size: m.nameSize, weight: .bold)).foregroundStyle(c.label)
                .fixedSize()
                .padding(.top, m.textTop(baseline: m.nameBaseline, size: m.nameSize))
            Text(verbatim: ProductIdentity.versionText).font(.system(size: 13)).foregroundStyle(gray(128, 153))
                .fixedSize()
                .padding(.top, m.textTop(baseline: m.versionBaseline, size: 13))
            HStack(spacing: 8) {
                welcomeButton("Open…", width: 107, c) { app.showOpenSheet() }
                    .shellTarget("welcome open")
                welcomeButton("Clone…", width: 107, c) { app.showClone() }
                    .shellTarget("welcome clone")
                newProjectMenu(c)
                    .shellTarget("welcome new project")
            }
            .padding(.top, m.buttonsTop)
            recents(c)
                .frame(width: 360, height: 277)
                .shellTarget("welcome recents")
                .padding(.top, 295)
        }
        .frame(width: 480, height: 632)
        .navigationTitle(Self.windowTitle)
    }

    static let windowTitle = "Welcome to Ycode"
    /// P-186: the close button's circle and glyph.
    let closeSide: CGFloat = 37, closeGlyphFont: CGFloat = 17

    /// P-186: the close button's fills (dark #3C3D3E, #505152 on hover).
    var welcomeCloseFill: Color { scheme == .dark ? Color(ycodeWelcomeHex: 0x3C3D3E) : Color.black.opacity(0.06) }
    var closeHoverFill: Color { scheme == .dark ? Color(ycodeWelcomeHex: 0x505152) : Color.black.opacity(0.12) }

    /// New Project: a pull-down of the compact picker's rows, as the macOS
    /// Welcome's (App, Command Line Tool, Package…, Playground, —, Choose
    /// Template…).
    func newProjectMenu(_ c: ShellColors) -> some View {
        Menu {
            ForEach(Array(NewProjectPicker.rows.enumerated()), id: \.offset) { i, r in
                if i == NewProjectPicker.chooseTemplateIndex { Divider() }
                Button(r.title) { app.showNewProject(row: i) }.help(r.subtitle)
            }
        } label: {
            welcomeLabel("New Project", width: 130, chevron: true, c)
        }
        .buttonStyle(.plain)
        .frame(width: 130, height: 36)
        .accessibilityLabel("New Project")
    }

    func welcomeButton(_ title: String, width: CGFloat, chevron: Bool = false, _ c: ShellColors, action: @escaping () -> Void) -> some View {
        Button(action: action) { welcomeLabel(title, width: width, chevron: chevron, c) }
            .buttonStyle(.plain)
            // P-186: the name is the button's description.
            .accessibilityLabel(title)
    }

    func welcomeLabel(_ title: String, width: CGFloat, chevron: Bool, _ c: ShellColors) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(verbatim: title).font(.system(size: 13)).foregroundStyle(c.label)
            Spacer(minLength: 0)
            if chevron {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(c.label).padding(.trailing, 14)
            }
        }
        .frame(width: width, height: 36)
        .background { Capsule(style: .continuous).fill(welcomeButtonFill) }
        .contentShape(Capsule(style: .continuous))
    }

    /// A grey for each appearance (the AppKit Welcome window's, parity §9).
    func gray(_ light: Double, _ dark: Double) -> Color {
        let v = (scheme == .dark ? dark : light) / 255
        return Color(.sRGB, red: v, green: v, blue: v)
    }

    var welcomeButtonFill: Color {
        let v = (scheme == .dark ? 48.0 : 235.0) / 255
        return Color(.sRGB, red: v, green: v, blue: v)
    }

    /// The row is selected while the list has focus (accent selection).
    func focusedRow(_ i: Int) -> Bool { i == selected && recentsFocused }

    func recents(_ c: ShellColors) -> some View {
        let box = scheme == .dark ? 36.0 / 255 : 248.0 / 255
        let sel = scheme == .dark ? 70.0 / 255 : 220.0 / 255
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.sRGB, red: box, green: box, blue: box))
            if app.recent.isEmpty {
                Text("No Recent Projects").font(.system(size: 13)).foregroundStyle(c.tertiaryLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(app.recent.enumerated()), id: \.offset) { pair in
                            let url = pair.element
                            // The AppKit rows (W7.6, row 194): Ycode's own icon 16 in
                            // (the package glyph for a package), the text's ink 48.5 from
                            // the selection's left; the name 12.4 points semibold,
                            // the folder 10 points, whole or cut in the middle.
                            let R = WelcomeRecentRow.self
                            // (The OpenViews row already put the text 48.5 from the
                            // selection's left; the AppKit cell's inset moved it 6 right.)
                            HStack(spacing: 8) {
                                if url.pathExtension.isEmpty {
                                    Image(systemName: "shippingbox").font(.system(size: 20)).foregroundStyle(c.secondaryLabel).frame(width: 32)
                                } else {
                                    YcodeMark(size: 32)   // AboutSheet.swift
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: RecentProjects.displayName(url)).font(.system(size: CGFloat(R.titleSize), weight: .semibold))
                                        .foregroundStyle(focusedRow(pair.offset) ? Color.white : c.label)
                                        .lineLimit(1)
                                        .offset(y: CGFloat(R.titleDrop))
                                    Text(verbatim: RecentProjects.folderText(url)).font(.system(size: CGFloat(R.pathSize)))
                                        // The grey selection keeps it; the accent one: #B3CEF1.
                                        .foregroundStyle(focusedRow(pair.offset) ? Color(ycodeWelcomeHex: WelcomeRecentRow.selectedPathColor) : c.secondaryLabel)
                                        .lineLimit(1).truncationMode(.middle)
                                        .offset(y: CGFloat(R.pathDrop))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            // P-186: 2.75 further left, as the AppKit row's text.
                            .padding(.leading, 16 + CGFloat(R.textShift + 6))
                            .padding(.trailing, CGFloat(R.trailingInset))
                            .frame(height: CGFloat(WelcomeMetrics.recentRowPitch))
                            .background {
                                if pair.offset == selected {
                                    // L-177: the accent selection while the list has
                                    // focus, grey otherwise (the AppKit list's).
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(recentsFocused ? Color.accentColor : Color(.sRGB, red: sel, green: sel, blue: sel))
                                        .padding(.horizontal, 8)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { app.open(path: url.path) }
                            .onTapGesture { selected = pair.offset; recentsFocused = true }
                            // L-177: the full path as the row's tooltip.
                            .help(url.path)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(pair.offset == selected ? [.isSelected] : [])
                            .accessibilityAction { app.open(path: url.path) }
                            .shellTarget("recent \(RecentProjects.displayName(url))")
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                // L-070: the list is keyboard-operable: Up and Down move the
                // selection, Return opens it.
                .focusable()
                .focused($recentsFocused)
                .onKeyPress(keys: [.upArrow, .downArrow, .return]) { press in
                    switch press.key {
                    case .upArrow: selected = max(0, selected - 1)
                    case .downArrow: selected = min(app.recent.count - 1, selected + 1)
                    default:
                        if app.recent.indices.contains(selected) { app.open(path: app.recent[selected].path) }
                    }
                    return .handled
                }
                .accessibilityLabel("Recent Projects")
            }
        }
    }
}

/// The AppKit Welcome window's numbers (`WelcomeWindowController`,
/// `metrics.md` §13.4, §16.3), with the text placed for OpenViews' UI font
/// (Inter: capitals 0.727 em, ascender 0.969 em).
enum WelcomeMetrics {
    static let buttonsTop: CGFloat = 242
    static let nameCapHeight: CGFloat = 13
    static let nameBaseline: CGFloat = buttonsTop - 38
    static let versionBaseline: CGFloat = buttonsTop - 19
    static let iconVisibleSide: CGFloat = 98
    static let iconGapAboveName: CGFloat = 15.5
    static let recentRowPitch: CGFloat = 47
    static let capHeightPerEm: CGFloat = 0.727
    static let ascenderPerEm: CGFloat = 0.969
    /// The name's size: capitals `nameCapHeight` tall.
    static var nameSize: CGFloat { (nameCapHeight / capHeightPerEm * 2).rounded() / 2 }
    /// The top of a text line of `size` points whose baseline is at `baseline`.
    static func textTop(baseline: CGFloat, size: CGFloat) -> CGFloat { baseline - size * ascenderPerEm }
    static var iconFrameSide: CGFloat {
        iconVisibleSide / CGFloat((ProductIconGeometry.fieldMax - ProductIconGeometry.fieldMin) / ProductIconGeometry.side)
    }
    /// The icon's frame top: its drawn square ends 15.5 above the name's capitals.
    static var iconFrameTop: CGFloat {
        let capTop = nameBaseline - nameCapHeight
        return capTop - iconGapAboveName + iconFrameSide * CGFloat(ProductIconGeometry.fieldMin / ProductIconGeometry.side) - iconFrameSide
    }
}

extension Color {
    /// An sRGB colour from 0xRRGGBB (the Welcome window's measured fills).
    init(ycodeWelcomeHex hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
