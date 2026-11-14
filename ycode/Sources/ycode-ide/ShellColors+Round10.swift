import SwiftUI
import YcodeIDECore

extension ShellColors {
    /// The navigator's background (council round 10, row 245): #28282A in
    /// dark (`WorkspaceChrome.navigatorDarkBackground`), the sidebar's
    /// colour in light, as the macOS IDE's `NavigatorDarkFillView`.
    var navigatorBackground: Color {
        guard dark else { return sidebar }
        let v = WorkspaceChrome.navigatorDarkBackground
        return Color(.sRGB, red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
