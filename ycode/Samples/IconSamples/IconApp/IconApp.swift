import SwiftUI
import UIKit

/// An app whose Assets.car and icon files Ycode's asset compiler writes
/// (`specs/formats/assets-car.md`, "Ycode implementation"). Prints one line
/// for the run log saying what it found in its catalog, then shows the same.
@main
struct IconApp: App {
    static let report: String = {
        let image = UIImage(named: "Dot").map { "\(Int($0.size.width))x\(Int($0.size.height))@\(Int($0.scale))x" } ?? "missing"
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let color = UIColor(named: "Badge")
        _ = color?.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
        let badge = color == nil ? "missing" : String(format: "%.2f %.2f %.2f", r, g, b)
        let icons = (Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
        return "YCODE-ICON-SAMPLE image \(image), color \(badge), icon \(icons?["CFBundleIconName"] as? String ?? "missing")"
    }()

    init() { FileHandle.standardError.write(Data((Self.report + "\n").utf8)) }

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Image("Dot")
                Text(Self.report).foregroundStyle(Color("Badge"))
            }
            .padding()
        }
    }
}
