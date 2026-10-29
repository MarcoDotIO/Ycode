// The host's model of a foldable device's hinge (specs/simulator/foldable.md
// §3, §8.2 I4–I5, §8.1 D3): the angle Ycode last commanded, the sweep that
// moves it, the device orientation, and which panel SpringBoard shows. The
// guest has its own hinge model with hysteresis; this one only predicts its
// side of the swap from the commanded angles (opening to 85° or more → the
// inner panel; closing to 84° or less → the cover; §3.3, §10.3, §10.4). Pure logic: built and
// tested on every platform (FoldControl.swift drives it on the VMM host).

import Foundation

/// A preset of the IDE and the command line (foldable.md §8.3 E1).
enum FoldPosture: String, CaseIterable, Sendable {
    case closed
    case halfOpen
    case openFlat

    /// The preset's hinge angle: Closed 0°, Half Open 90° (the reference's
    /// partially open / "book" pose), Open Flat 180°.
    var angle: Int {
        switch self {
        case .closed: 0
        case .halfOpen: 90
        case .openFlat: 180
        }
    }

    /// The posture a hinge angle is in (§3.1: closed at 0°, open flat at
    /// 180°, partially open between; the reference's boundary lies in
    /// (175°, 180°]).
    init(angle: Int) {
        self = angle <= 0 ? .closed : angle >= 180 ? .openFlat : .halfOpen
    }

    /// Ycode's own words (Closed / Half Open / Open Flat).
    var title: String {
        switch self {
        case .closed: "Closed"
        case .halfOpen: "Half Open"
        case .openFlat: "Open Flat"
        }
    }

    /// `closed`, `half`, `open` (and the raw values, and `flat`) → a posture.
    init?(word: String) {
        switch word.lowercased() {
        case "closed", "close", "fold", "folded": self = .closed
        case "half", "halfopen", "half-open", "book", "partiallyopen": self = .halfOpen
        case "open", "openflat", "open-flat", "flat", "unfold", "unfolded": self = .openFlat
        default: return nil
        }
    }

    /// A fold argument: a posture word or whole degrees 0…180.
    static func angle(argument: String) -> Int? {
        if let p = FoldPosture(word: argument) { return p.angle }
        guard let n = Int(argument.hasSuffix("°") ? String(argument.dropLast()) : argument), (0...180).contains(n) else { return nil }
        return n
    }
}

/// The device orientation of a foldable's device-motion input (foldable.md
/// §5.3, §5.4). The raw values are the relay's codes; 1, 3, 4, 5, 6 are
/// also UIDeviceOrientation's values (the display stream's rotate message).
enum DeviceMotionOrientation: UInt32, CaseIterable, Sendable {
    case ambiguous = 0, portrait = 1, landscapeLeft = 3, landscapeRight = 4, faceUp = 5, faceDown = 6

    var name: String {
        switch self {
        case .ambiguous: "ambiguous"
        case .portrait: "portrait"
        case .landscapeLeft: "landscape-left"
        case .landscapeRight: "landscape-right"
        case .faceUp: "faceup"
        case .faceDown: "facedown"
        }
    }

    init?(name: String) {
        let n = name.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        guard let o = Self.allCases.first(where: { $0.name.replacingOccurrences(of: "-", with: "") == n }) else { return nil }
        self = o
    }

    /// Rotate Left (the device turned a quarter counterclockwise): portrait
    /// → landscape left → landscape right → portrait. Upside down is not an
    /// orientation the relay takes (§5.3), so it is skipped.
    var rotatedLeft: DeviceMotionOrientation {
        switch self {
        case .portrait: .landscapeLeft
        case .landscapeLeft: .landscapeRight
        default: .portrait
        }
    }

    /// Rotate Right: portrait → landscape right → landscape left → portrait.
    var rotatedRight: DeviceMotionOrientation {
        switch self {
        case .portrait: .landscapeRight
        case .landscapeRight: .landscapeLeft
        default: .portrait
        }
    }

    /// How far the device is turned clockwise from upright, in degrees (the
    /// viewer turns the picture back by this much; face up and down count as
    /// upright).
    var clockwiseTurn: Int {
        switch self {
        case .landscapeLeft: 270
        case .landscapeRight: 90
        default: 0
        }
    }
}

struct FoldModel: Equatable, Sendable {
    /// SpringBoard's swap points for commanded sweeps (§3.3 "Commanded
    /// targets", §10.3, §10.4): an opening that ends at 85° or more ends on
    /// the inner panel, one that ends at 84° or less on the cover; a closing
    /// from open that ends at 84° or less ends on the cover, at 85° or more
    /// on the inner panel. Measured under Ycode (FOLD2, every whole degree
    /// 76–85); within the reference's bounds ((75°, 85°] and (80°, 85°]).
    static let openingSwapAngle = 85
    static let closingSwapAngle = 84
    /// The sweep (§8.2 I4): steps about 30 ms apart over about 0.5 s.
    static let sweepStepMilliseconds = 30
    static let sweepMilliseconds = 500

    /// The angle last sent to the guest (0 at every boot, §7, I5).
    var angle = 0
    /// The panel SpringBoard is expected to show.
    var innerActive = false
    var orientation = DeviceMotionOrientation.portrait

    var posture: FoldPosture { FoldPosture(angle: angle) }

    /// The angles a sweep from `from` to `to` sends, in order, ending exactly
    /// on `to` (the reference's sweep, §4, §5.5); `instant` sends only `to`
    /// (its "Disable Hinge Interpolation"). Equal neighbours are sent once.
    static func sweep(from: Int, to: Int, instant: Bool = false) -> [Int] {
        let target = min(180, max(0, to))
        if instant || from == target { return [target] }
        let steps = max(1, Int((Double(sweepMilliseconds) / Double(sweepStepMilliseconds)).rounded()))
        var out: [Int] = []
        for i in 1...steps {
            let a = Int((Double(from) + Double(target - from) * Double(i) / Double(steps)).rounded())
            if a != from, out.last != a { out.append(a) }
        }
        if out.last != target { out.append(target) }
        return out
    }

    /// The panel after a move from the current angle to `target` (§3.3):
    /// opening to 85° or more swaps to the inner panel, closing to 84° or
    /// less swaps back to the cover; a move that stops short of the swap
    /// point stays on the panel it started on.
    func innerActive(after target: Int) -> Bool {
        if target > angle { return innerActive || target >= Self.openingSwapAngle }
        if target < angle { return innerActive && target > Self.closingSwapAngle }
        return innerActive
    }

    /// The state after a completed move to `target`.
    mutating func moved(to target: Int) {
        let t = min(180, max(0, target))
        innerActive = innerActive(after: t)
        angle = t
    }

    // MARK: The saved record (`fold.state` in the memory directory)

    /// One line: "angle <deg> inner <0|1> orientation <code>". The memory
    /// directory starts empty on a cold boot (so every boot starts closed,
    /// §7) and is saved and restored with a warm-boot snapshot, so a
    /// restored device keeps the fold it was saved in.
    var record: String { "angle \(angle) inner \(innerActive ? 1 : 0) orientation \(orientation.rawValue)\n" }

    init() {}

    init?(record: String) {
        let w = record.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        func value(_ key: String) -> Int? { w.firstIndex(of: key).flatMap { $0 + 1 < w.count ? Int(w[$0 + 1]) : nil } }
        guard let a = value("angle"), (0...180).contains(a), let i = value("inner") else { return nil }
        angle = a
        innerActive = i != 0
        orientation = value("orientation").flatMap { DeviceMotionOrientation(rawValue: UInt32($0)) } ?? .portrait
    }

    /// A short description for logs, the control socket and the IDE.
    var summary: String {
        "angle \(angle)° (\(posture.title)), \(innerActive ? "inner" : "cover") side, \(orientation.name)"
    }
}

/// The picture of one panel as a person should see it (foldable.md §8.1 D4):
/// how many degrees clockwise to turn its framebuffer image.
enum PanelPicture {
    /// The cover's UI is drawn upright in its framebuffer; the inner panel is
    /// mounted at 270° (§2), so its framebuffer image is turned a quarter
    /// to show the landscape UI of the unfolded device (§6: the reference's
    /// inner screenshot is 2853 × 2007).
    static func uprightRotation(mountRotation: Int) -> Int { mountRotation == 0 ? 0 : (360 - mountRotation) % 360 }

    /// The viewer's turn: the panel's upright turn, then the device's own
    /// turn undone (a device held in landscape shows its picture turned).
    static func viewRotation(mountRotation: Int, orientation: DeviceMotionOrientation) -> Int {
        (uprightRotation(mountRotation: mountRotation) + 360 - orientation.clockwiseTurn) % 360
    }

    /// Whether a 32-bit frame (BGRA or RGBA) is black: the colour bytes of
    /// every pixel of a 32 × 32 grid spread over it (corners and edges
    /// included) are zero. SpringBoard fills the panel it turns off with
    /// black (foldable.md §10.4); a lit picture has a non-zero pixel on the
    /// grid.
    static func isBlack(_ base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int) -> Bool {
        guard width > 0, height > 0 else { return true }
        let n = 32
        for j in 0..<n {
            let y = height == 1 ? 0 : j * (height - 1) / (n - 1)
            for i in 0..<n {
                let x = width == 1 ? 0 : i * (width - 1) / (n - 1)
                let p = base + y * bytesPerRow + x * 4
                if p.load(fromByteOffset: 0, as: UInt8.self) != 0 || p.load(fromByteOffset: 1, as: UInt8.self) != 0
                    || p.load(fromByteOffset: 2, as: UInt8.self) != 0 { return false }
            }
        }
        return true
    }

    /// RGBA pixels turned clockwise by 0, 90, 180 or 270 degrees.
    static func rotate(rgba: [UInt8], width: Int, height: Int, degrees: Int) -> (pixels: [UInt8], width: Int, height: Int) {
        let d = ((degrees % 360) + 360) % 360
        guard d != 0, rgba.count >= width * height * 4 else { return (rgba, width, height) }
        let (w2, h2) = d == 180 ? (width, height) : (height, width)
        var out = [UInt8](repeating: 0, count: w2 * h2 * 4)
        rgba.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                let s = src.bindMemory(to: UInt32.self), o = dst.bindMemory(to: UInt32.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let (nx, ny): (Int, Int)
                        switch d {
                        case 90: (nx, ny) = (height - 1 - y, x)
                        case 180: (nx, ny) = (width - 1 - x, height - 1 - y)
                        default: (nx, ny) = (y, width - 1 - x)
                        }
                        o[ny * w2 + nx] = s[y * width + x]
                    }
                }
            }
        }
        return (out, w2, h2)
    }
}

// MARK: - Which panel is shown

/// One built-in display as the host shows it.
struct PanelInfo: Equatable, Sendable {
    let name: String
    /// Frame-record slot (0: display 1).
    let slot: Int
    let width: Int, height: Int
    let scale: Double
    let mountRotation: Int
    /// The touch-message display index (hid-input.md §7.3; 1: the second display).
    var touchDisplay: UInt32 { slot == 0 ? 0 : 1 }
}

extension DeviceType {
    /// The built-in displays: display 1, then a foldable's second display.
    var panels: [PanelInfo] {
        var p = [PanelInfo(name: "LCD", slot: 0, width: screen.width, height: screen.height, scale: screen.scale, mountRotation: 0)]
        if let s = publishedSecondDisplay {
            p.append(PanelInfo(name: s.name, slot: 1, width: s.width, height: s.height, scale: Double(s.scale), mountRotation: s.mountRotation))
        }
        return p
    }
}

/// The panel to show (foldable.md §8.1 D3, §10.4): the side of the swap the
/// commanded angles put SpringBoard on, unless the guest's own signs say
/// otherwise: a panel whose backlight the guest set to off is not shown
/// while the other one is lit, and a panel whose latest frame is black is
/// not shown while the other one's latest frame is not (`black`: per panel,
/// nil when the panel has presented nothing). Under Ycode the guest never
/// sets a panel's backlight through the framebuffer library (§10.4, Q4), so
/// the frames are the sign that counts.
func activePanel(_ panels: [PanelInfo], model: FoldModel?, records: [FrameRecord?], black: [Bool?] = []) -> PanelInfo {
    guard panels.count > 1, let model else { return panels[0] }
    let predicted = model.innerActive ? 1 : 0
    let other = 1 - predicted
    func off(_ i: Int) -> Bool { i < records.count && records[i]?.backlight == 0 }
    if off(predicted) && !off(other) { return panels[other] }
    func dark(_ i: Int) -> Bool? { i < black.count ? black[i] : nil }
    if dark(predicted) == true && dark(other) == false { return panels[other] }
    return panels[predicted]
}
