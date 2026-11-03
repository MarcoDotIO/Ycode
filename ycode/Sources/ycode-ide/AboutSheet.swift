import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// Words the Linux shell uses for what it does not have yet.
enum ShellText {
    static let notInBeta = "Not available on Linux in this beta"
    static func notInBeta(_ what: String) -> String { "\(what): not available on Linux in this beta" }
}

/// The app icon (`packaging/icon/ycode-icon.svg`) drawn from its geometry: a
/// plum field, a cream chevron over a coral caret. Any size, no image file.
struct YcodeMark: View {
    var size: CGFloat

    var body: some View {
        typealias G = ProductIconGeometry
        let k = size / CGFloat(G.side)
        func point(_ q: (Double, Double)) -> CGPoint { CGPoint(x: CGFloat(q.0) * k, y: CGFloat(q.1) * k) }
        func line(_ points: [(Double, Double)]) -> Path {
            var p = Path()
            p.move(to: point(points[0]))
            for q in points.dropFirst() { p.addLine(to: point(q)) }
            return p
        }
        let a = G.fieldMin, b = G.fieldMax, s = G.cornerStart, c = G.cornerControl
        var field = Path()
        field.move(to: point((a + s, a)))
        field.addLine(to: point((b - s, a)))
        field.addCurve(to: point((b, a + s)), control1: point((b - c, a)), control2: point((b, a + c)))
        field.addLine(to: point((b, b - s)))
        field.addCurve(to: point((b - s, b)), control1: point((b, b - c)), control2: point((b - c, b)))
        field.addLine(to: point((a + s, b)))
        field.addCurve(to: point((a, b - s)), control1: point((a + c, b)), control2: point((a, b - c)))
        field.addLine(to: point((a, a + s)))
        field.addCurve(to: point((a + s, a)), control1: point((a, a + c)), control2: point((a + c, a)))
        field.closeSubpath()
        let style = StrokeStyle(lineWidth: CGFloat(G.strokeWidth) * k, lineCap: .round, lineJoin: .round)
        return ZStack(alignment: .topLeading) {
            field.fill(LinearGradient(colors: [Self.color(G.fieldTop), Self.color(G.fieldBottom)], startPoint: .top, endPoint: .bottom))
            line(G.chevron).stroke(Self.color(G.chevronColor), style: style)
            line(G.caret).stroke(Self.color(G.caretColor), style: style)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Ycode icon")
    }

    static func color(_ hex: String) -> Color {
        let v = Int(hex.dropFirst(), radix: 16) ?? 0
        return Color(.sRGB, red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
    }
}

/// Ycode ▸ About Ycode: the icon, the version, the license, the links and the
/// "not affiliated" line.
struct AboutSheet: View {
    var app: ShellAppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        VStack(spacing: 8) {
            YcodeMark(size: 112)
            Text(verbatim: ProductIdentity.name).font(.system(size: 24, weight: .bold)).foregroundStyle(c.label)
            Text(verbatim: ProductIdentity.fullVersionText).font(.system(size: 13)).foregroundStyle(c.secondaryLabel)
            Text(verbatim: "\(ProductIdentity.copyright)\nReleased under the \(ProductIdentity.license).")
                .font(.system(size: 11)).foregroundStyle(c.secondaryLabel).multilineTextAlignment(.center)
                .padding(.top, 8)
            HStack(spacing: 8) {
                Button("Repository") { app.openLink(ProductIdentity.repositoryURL) }.buttonStyle(.bordered).shellTarget("about repository")
                Button("License") { app.openLink(ProductIdentity.licenseURL) }.buttonStyle(.bordered).shellTarget("about license")
                Button("Third-Party Notices") { app.openLink(ProductIdentity.noticesURL) }.buttonStyle(.bordered).shellTarget("about notices")
            }
            Text(verbatim: ProductIdentity.notAffiliated)
                .font(.system(size: 11)).foregroundStyle(c.secondaryLabel).multilineTextAlignment(.center)
                .padding(.top, 8)
            Spacer(minLength: 0)
            Button("Close") { app.isAboutShown = false }.keyboardShortcut(.defaultAction).buttonStyle(.bordered).shellTarget("about close")
        }
        .padding(24)
        .frame(width: 400, height: 410)
        .background(c.content)
    }
}

/// Welcome ▸ Clone…, Integrate ▸ Clone…: the address and the folder.
struct CloneSheet: View {
    @Bindable var model: CloneShellModel
    var app: ShellAppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        VStack(alignment: .leading, spacing: 12) {
            Text("Clone").font(.system(size: 13, weight: .bold)).foregroundStyle(c.label)
            row("Repository:", c) {
                TextField("https://…", text: $model.address).textFieldStyle(.roundedBorder).frame(width: 340).disabled(model.isRunning).shellTarget("clone address")
            }
            row("Where:", c) {
                HStack {
                    TextField("", text: $model.location).textFieldStyle(.roundedBorder).frame(width: 250).disabled(model.isRunning).shellTarget("clone where")
                    Button("Choose…") { model.isFolderDialogShown = true }.buttonStyle(.bordered).disabled(model.isRunning)
                }
            }
            if model.isRunning {
                Text(verbatim: "Cloning into \(model.destination.lastPathComponent)…").font(.system(size: 11)).foregroundStyle(c.secondaryLabel)
                    .shellTarget("clone progress")
            } else if let e = model.error {
                Text(verbatim: e).font(.system(size: 11)).foregroundStyle(c.error).fixedSize(horizontal: false, vertical: true).shellTarget("clone error")
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { app.cancelClone() }.keyboardShortcut(.cancelAction).buttonStyle(.bordered).disabled(model.isRunning).shellTarget("clone cancel")
                Button("Clone") { model.clone() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!model.canClone).shellTarget("clone go")
            }
        }
        .padding(16)
        .frame(width: 480, height: 230)
        .background(c.content)
        .fileImporter(isPresented: $model.isFolderDialogShown, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.location = url.path }
        }
    }

    func row<V: View>(_ label: String, _ c: ShellColors, @ViewBuilder _ content: () -> V) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: label).font(.system(size: 13)).foregroundStyle(c.label).frame(width: 90, alignment: .trailing)
            content()
        }
    }
}
