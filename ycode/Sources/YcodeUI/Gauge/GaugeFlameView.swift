import AppKit
import YcodeIDECore
import YcodeProfiler

/// The flame graph (`specs/ide/profiler.md` §4.4, §6): the call tree's
/// boxes, the outermost frames at the bottom. A click selects the box's node
/// (the call tree selects it too); the selection's boxes are outlined.
@MainActor
public final class GaugeFlameView: NSView {
    public let model: GaugeModel
    static let row: CGFloat = 18

    public init(model: GaugeModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }

    public var preferredHeight: CGFloat { CGFloat((model.flame?.maxDepth ?? 0) + 1) * Self.row + 12 }

    func rect(_ b: FlameGraph.Box, total: Int) -> NSRect {
        let scale = bounds.width / CGFloat(max(1, total))
        let y = bounds.height - 6 - CGFloat(b.depth + 1) * Self.row
        return NSRect(x: CGFloat(b.start) * scale, y: y, width: CGFloat(b.width) * scale, height: Self.row - 1)
    }

    static func color(_ b: FlameGraph.Box) -> NSColor {
        var h: UInt32 = 2166136261
        for u in b.name.utf8 { h = (h ^ UInt32(u)) &* 16777619 }
        let v = CGFloat(h % 100) / 100
        switch b.kind {
        case .app: return NSColor(calibratedHue: 0.04 + 0.08 * v, saturation: 0.65, brightness: 0.95, alpha: 1)
        case .kernel: return NSColor(calibratedWhite: 0.55 + 0.2 * v, alpha: 1)
        case .unknown where b.image.isEmpty: return NSColor(calibratedHue: 0.55, saturation: 0.25, brightness: 0.85, alpha: 1)
        default: return NSColor(calibratedHue: 0.55 + 0.08 * v, saturation: 0.45, brightness: 0.9, alpha: 1)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard let fg = model.flame, fg.total > 0 else {
            NSAttributedString(string: "No samples in the selection", attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 13)])
                .draw(at: NSPoint(x: 16, y: 16))
            return
        }
        let font = NSFont.systemFont(ofSize: 11)
        let selected = model.selectedPath
        for b in fg.boxes {
            let r = rect(b, total: fg.total)
            guard r.width >= 0.5, r.intersects(dirtyRect) else { continue }
            Self.color(b).setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0), xRadius: 2, yRadius: 2).fill()
            if let selected, b.path == selected {
                NSColor.labelColor.setStroke()
                let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 2, yRadius: 2)
                p.lineWidth = 1.5
                p.stroke()
            }
            if r.width > 30 {
                NSAttributedString(string: b.name, attributes: [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(0.85)])
                    .draw(with: NSRect(x: r.minX + 3, y: r.minY + 2, width: r.width - 6, height: r.height - 2),
                          options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
            }
        }
    }

    public func box(at point: NSPoint) -> FlameGraph.Box? {
        guard let fg = model.flame else { return nil }
        return fg.boxes.first { rect($0, total: fg.total).contains(point) }
    }

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let b = box(at: p) { model.selectedPath = b.path }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    public override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let fg = model.flame, let b = box(at: p) else { toolTip = nil; return }
        toolTip = String(format: "%@%@\n%d samples, %.1f %%", b.name, b.image.isEmpty ? "" : " (\(b.image))", b.width,
                         100 * Double(b.width) / Double(max(1, fg.total)))
    }
}
