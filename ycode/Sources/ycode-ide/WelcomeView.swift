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
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let m = WelcomeMetrics.self
        ZStack(alignment: .top) {
            gray(255, 29)   // the AppKit window's background, #FFFFFF / #1D1D1E
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
                welcomeButton("New Project", width: 130, chevron: true, c) { app.showNewProject() }
                    .shellTarget("welcome new project")
            }
            .padding(.top, m.buttonsTop)
            recents(c)
                .frame(width: 360, height: 277)
                .padding(.top, 295)
            // The round close button (W5): a 36-point filled circle at (20, 20).
            HStack(spacing: 0) {
                Button { dismissWindow() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(gray(159, 100))
                        .frame(width: 36, height: 36)
                        .background { Circle().fill(welcomeButtonFill) }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close")
                .shellTarget("welcome close")
                Spacer(minLength: 0)
            }
            .padding(.top, 20)
            .padding(.leading, 20)
        }
        .frame(width: 480, height: 632)
        .navigationTitle(Self.windowTitle)
    }

    static let windowTitle = "Welcome to Ycode"

    func welcomeButton(_ title: String, width: CGFloat, chevron: Bool = false, _ c: ShellColors, action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
        .buttonStyle(.plain)
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
                            // The AppKit rows: the glyph 16 in, the text at 56;
                            // the name 13 points semibold, the folder 11 points,
                            // cut at its head ("…/project") to fit the row.
                            HStack(spacing: 8) {
                                Image(systemName: url.pathExtension.isEmpty ? "shippingbox" : "folder.badge.gearshape")
                                    .font(.system(size: 20)).foregroundStyle(c.secondaryLabel)
                                    .frame(width: 32)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: RecentProjects.displayName(url)).font(.system(size: 13, weight: .semibold)).foregroundStyle(c.label)
                                        .lineLimit(1)
                                    Text(verbatim: RecentProjects.folderText(url)).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.secondaryLabel)
                                        .lineLimit(1).truncationMode(.head)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.leading, 16)
                            .padding(.trailing, 16)
                            .frame(height: CGFloat(WelcomeMetrics.recentRowPitch))
                            .background {
                                if pair.offset == selected {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(.sRGB, red: sel, green: sel, blue: sel))
                                        .padding(.horizontal, 8)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { app.open(path: url.path) }
                            .onTapGesture { selected = pair.offset }
                            .shellTarget("recent \(RecentProjects.displayName(url))")
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
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
