import Foundation
import YcodePreviews

/// Pieces of the preview canvas's chrome (reference-ui-4.md §10): the
/// placement rule, the preview tab, the paused capsule and the device
/// frame. Ycode's own drawing; no reference artwork.
public enum CanvasPlacement: Equatable, Sendable {
    case beside, below

    /// Below the editor when the editor area is narrower than this.
    public static let narrowWidth: CGFloat = 760

    public static func placement(forWidth w: CGFloat) -> CanvasPlacement { w > 0 && w < narrowWidth ? .below : .beside }
}
/// The canvas's four mode buttons, left of its bottom bar.
public enum PreviewCanvasMode: Int, CaseIterable, Sendable {
    case live, selectable, grid, variants
    public var title: String { ["Live", "Selectable", "Grid", "Variants"][rawValue] }
    public var symbol: String { ["play.circle", "cursorarrow", "square.grid.2x2", "circle.lefthalf.filled"][rawValue] }
}
/// The canvas device menu (reference-ui-4.md §17): Automatic, Recent,
/// generic classes, connected devices, More.
public struct PreviewDeviceMenuModel: Equatable, Sendable {
    public struct Generic: Equatable, Sendable { public var title: String; public var detail: String }
    public static let generics = [Generic(title: "iPhone", detail: "Dynamic Island"), Generic(title: "iPhone", detail: "Touch ID"),
                                  Generic(title: "iPad", detail: "11-inch"), Generic(title: "iPad", detail: "13-inch")]
    /// The automatic device's name (the run destination, else "My Mac").
    public var automatic: String = "My Mac"
    public var recent: [String] = []
    public var connected: [String] = []
    /// nil = Automatic.
    public var chosen: String?
    public init() {}

    /// Rows as titles ("—" separators, "#" section headers).
    public var rows: [String] {
        var out = ["Automatic – \(automatic)", "—", "#Recent"] + recent + ["—"]
        out += Self.generics.map { "\($0.title) \($0.detail)" }
        out += ["—", "#Devices"] + connected + ["—", "More"]
        return out
    }
}
/// Canvas settings switches (§17 item 4), all off by default.
public struct PreviewCanvasSettings: Equatable, Sendable {
    public static let names = ["Display", "Color Scheme", "Contrast", "Control Borders", "Orientation", "Dynamic Type"]
    public var on: Set<String> = []
    public init() {}
}
