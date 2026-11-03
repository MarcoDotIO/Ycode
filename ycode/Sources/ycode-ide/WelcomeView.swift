import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// The Welcome screen (`reference-ui-6.md` §1.4, `metrics.md` §8): the
/// AppKit IDE's Welcome window, 480 × 632, as a panel centered in the
/// shell's window: the icon, "Ycode", the version, Open… | Clone… | New
/// Project (107, 107 and 130 wide, 36 tall, 8 apart, top at 242), then the
/// recent projects in a rounded box (x 60–420, y 295–572) with 48-point
/// rows.
struct WelcomeView: View {
    @Bindable var app: ShellAppModel
    @State private var selected = 0
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        ZStack(alignment: .topLeading) {
            c.content
            // The round close button (W5), 36 points at (20, 20).
            Button { dismissWindow() } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(c.secondaryLabel)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close")
            .shellTarget("welcome close")
            .padding(20)
            VStack(spacing: 0) {
                YcodeMark(size: 112)
                    .frame(width: 104, height: 84)
                    .padding(.top, 63)
                Text("Ycode").font(.system(size: 34, weight: .bold)).foregroundStyle(c.label)
                    .frame(height: 41)
                    .padding(.top, 25)
                Text(verbatim: ProductIdentity.versionText).font(.system(size: 13)).foregroundStyle(c.secondaryLabel)
                    .frame(height: 16)
                HStack(spacing: 8) {
                    welcomeButton("Open…", width: 107, c) { app.showOpenSheet() }
                        .shellTarget("welcome open")
                    welcomeButton("Clone…", width: 107, c) { app.showClone() }
                        .shellTarget("welcome clone")
                    welcomeButton("New Project", width: 130, chevron: true, c) { app.showNewProject() }
                        .shellTarget("welcome new project")
                }
                .padding(.top, 242 - 63 - 84 - 25 - 41 - 16)
                recents(c)
                    .frame(width: 360, height: 277)
                    .padding(.top, 295 - 278)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 480, height: 632)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(c.capsuleStroke, lineWidth: 1) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(c.sidebar)
        .navigationTitle("Welcome to Ycode")
    }

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
                            HStack(spacing: 10) {
                                Image(systemName: url.pathExtension.isEmpty ? "shippingbox" : "folder.badge.gearshape")
                                    .font(.system(size: 20)).foregroundStyle(c.secondaryLabel)
                                    .frame(width: 32)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: RecentProjects.displayName(url)).font(.system(size: 13, weight: .bold)).foregroundStyle(c.label)
                                        .lineLimit(1)
                                    Text(verbatim: RecentProjects.folderText(url)).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.secondaryLabel)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 48)
                            .background {
                                if pair.offset == selected {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(.sRGB, red: sel, green: sel, blue: sel))
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { app.open(path: url.path) }
                            .onTapGesture { selected = pair.offset }
                            .shellTarget("recent \(RecentProjects.displayName(url))")
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}
