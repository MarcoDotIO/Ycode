import AppKit
import YcodeIDECore
import YcodeProfiler

/// The profiler window's timeline (`specs/ide/profiler.md` §6): a ruler,
/// then the CPU, Signposts, Hangs, Frames and GPU tracks. A drag selects a
/// time range (it filters every view below); a click or double-click
/// without dragging clears it.
@MainActor
public final class GaugeTimelineView: NSView {
    public let model: GaugeModel
    static let headerWidth: CGFloat = 132
    static let rulerHeight: CGFloat = 22
    static let cpuHeight: CGFloat = 64
    static let rowHeight: CGFloat = 18
    static let maxSignpostRows = 6
    /// Track titles longer than the header end in "…".
    static let truncatingTail: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return p
    }()

    private var dragStart: CGFloat?

    public init(model: GaugeModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }

    /// Signpost rows: the target's own names first (GaugeTimeline.signpostRows).
    var signpostNames: [String] {
        guard let t = model.trace else { return [] }
        return GaugeTimeline.signpostRows(t, limit: Self.maxSignpostRows)
    }

    /// The document view of the timeline's scroll view: as wide as the
    /// visible area (the time axis fits the width; only height scrolls).
    public override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        if let w = superview?.bounds.width, w > 0, frame.width != w { setFrameSize(NSSize(width: w, height: frame.height)) }
    }

    /// Track rows: (title, y, height).
    var tracks: [(title: String, y: CGFloat, height: CGFloat)] {
        var y = Self.rulerHeight
        var out: [(String, CGFloat, CGFloat)] = [("CPU", y, Self.cpuHeight)]
        y += Self.cpuHeight
        let names = signpostNames
        if names.isEmpty {
            out.append(("Signposts", y, Self.rowHeight))
            y += Self.rowHeight
        } else {
            for n in names {
                out.append(("⟐ " + n, y, Self.rowHeight))
                y += Self.rowHeight
            }
        }
        out.append(("Hangs", y, Self.rowHeight))
        y += Self.rowHeight
        out.append(("Frames", y, Self.rowHeight))
        y += Self.rowHeight
        out.append(("GPU", y, Self.rowHeight + 4))
        return out
    }

    public var preferredHeight: CGFloat { (tracks.last.map { $0.y + $0.height } ?? 100) + 6 }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight) }

    var plotRect: NSRect { NSRect(x: Self.headerWidth, y: 0, width: max(10, bounds.width - Self.headerWidth - 8), height: bounds.height) }

    func x(_ time: UInt64) -> CGFloat {
        plotRect.minX + CGFloat(Double(time) / Double(model.duration)) * plotRect.width
    }

    func time(atX px: CGFloat) -> UInt64 {
        let f = max(0, min(1, (px - plotRect.minX) / plotRect.width))
        return UInt64(Double(f) * Double(model.duration))
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard let t = model.trace else {
            let text = NSAttributedString(string: "No trace", attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 13)])
            text.draw(at: NSPoint(x: 16, y: 16))
            return
        }
        let plot = plotRect
        let labelFont = NSFont.systemFont(ofSize: 11)
        let smallFont = NSFont.systemFont(ofSize: 10)
        // Track headers and separators.
        for (i, tr) in tracks.enumerated() {
            if i % 2 == 1 {
                NSColor.alternatingContentBackgroundColors.last?.withAlphaComponent(0.6).setFill()
                NSRect(x: 0, y: tr.y, width: bounds.width, height: tr.height).fill()
            }
            NSAttributedString(string: tr.title, attributes: [.font: labelFont, .foregroundColor: NSColor.secondaryLabelColor,
                                                              .paragraphStyle: Self.truncatingTail])
                .draw(in: NSRect(x: 10, y: tr.y + (tr.height - 14) / 2, width: Self.headerWidth - 14, height: 14))
        }
        NSColor.separatorColor.setFill()
        NSRect(x: Self.headerWidth - 1, y: 0, width: 1, height: bounds.height).fill()

        // Ruler: a tick about every 80 points at a round number of milliseconds.
        let duration = Double(model.duration) / 1e6
        let steps: [Double] = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 60000]
        let step = steps.first { $0 / duration * Double(plot.width) >= 80 } ?? 60000
        var ms = 0.0
        while ms <= duration {
            let px = plot.minX + CGFloat(ms / duration) * plot.width
            NSColor.separatorColor.setFill()
            NSRect(x: px, y: Self.rulerHeight - 6, width: 1, height: 6).fill()
            let label = step >= 1000 ? String(format: "%.0f s", ms / 1000) : String(format: "%.0f ms", ms)
            NSAttributedString(string: label, attributes: [.font: smallFont, .foregroundColor: NSColor.tertiaryLabelColor])
                .draw(at: NSPoint(x: px + 3, y: 3))
            ms += step
        }

        let rows = tracks
        // CPU: samples per column, user and kernel; the selection's samples on top.
        let cpu = rows[0]
        let columns = max(1, Int(plot.width / 2))
        let counts = GaugeTimeline.cpuColumns(t, range: 0..<model.duration, columns: columns, threads: model.threads)
        var selected = [Int](repeating: 0, count: columns)
        if !model.selectedStacks.isEmpty {
            for i in 0..<t.samples.count where t.samples.state[i].isCPU && model.selectedStacks.contains(t.samples.stack[i]) {
                if let th = model.threads, !th.contains(t.samples.thread[i]) { continue }
                let c = min(columns - 1, Int(Double(t.samples.time[i]) / Double(model.duration) * Double(columns)))
                selected[c] += 1
            }
        }
        let peak = max(1, counts.map { $0.user + $0.kernel }.max() ?? 1)
        let colWidth = plot.width / CGFloat(columns)
        for (c, v) in counts.enumerated() {
            let total = CGFloat(v.user + v.kernel) / CGFloat(peak) * (cpu.height - 6)
            let kernel = CGFloat(v.kernel) / CGFloat(peak) * (cpu.height - 6)
            let px = plot.minX + CGFloat(c) * colWidth
            NSColor.controlAccentColor.withAlphaComponent(0.55).setFill()
            NSRect(x: px, y: cpu.y + cpu.height - 3 - total, width: max(1, colWidth - 0.5), height: total - kernel).fill()
            NSColor.systemRed.withAlphaComponent(0.6).setFill()
            NSRect(x: px, y: cpu.y + cpu.height - 3 - kernel, width: max(1, colWidth - 0.5), height: kernel).fill()
            if selected[c] > 0 {
                let h = CGFloat(selected[c]) / CGFloat(peak) * (cpu.height - 6)
                NSColor.controlAccentColor.setFill()
                NSRect(x: px, y: cpu.y + cpu.height - 3 - h, width: max(1, colWidth - 0.5), height: h).fill()
            }
        }

        // Signposts: one row per name; intervals as capsules, events as diamonds.
        let names = signpostNames
        for (i, name) in names.enumerated() {
            let row = rows[1 + i]
            for s in t.signposts where s.name == name {
                let x0 = x(s.begin)
                if s.kind == .event {
                    let p = NSBezierPath()
                    let cy = row.y + row.height / 2
                    p.move(to: NSPoint(x: x0, y: cy - 5))
                    p.line(to: NSPoint(x: x0 + 4, y: cy))
                    p.line(to: NSPoint(x: x0, y: cy + 5))
                    p.line(to: NSPoint(x: x0 - 4, y: cy))
                    p.close()
                    NSColor.systemPurple.setFill()
                    p.fill()
                    continue
                }
                let x1 = max(x0 + 2, x(s.end ?? s.begin))
                let r = NSRect(x: x0, y: row.y + 3, width: x1 - x0, height: row.height - 6)
                let color = [NSColor.systemPurple, .systemTeal, .systemIndigo, .systemPink, .systemGreen, .systemBrown][i % 6]
                color.withAlphaComponent(s.flags.contains("open") ? 0.4 : 0.75).setFill()
                NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
                if r.width > 40 {
                    let text = s.message.isEmpty ? s.name : "\(s.name): \(s.message)"
                    NSAttributedString(string: text, attributes: [.font: smallFont, .foregroundColor: NSColor.white])
                        .draw(in: r.insetBy(dx: 4, dy: 0).offsetBy(dx: 0, dy: -1))
                }
            }
        }
        let after = 1 + max(1, names.count)
        // Hangs.
        let hangRow = rows[after]
        for h in model.hangs {
            let r = NSRect(x: x(h.begin), y: hangRow.y + 3, width: max(2, x(h.end) - x(h.begin)), height: hangRow.height - 6)
            let severe = h.duration >= 4 * t.recording.hangThresholdNs
            (severe ? NSColor.systemRed : NSColor.systemOrange).withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            if r.width > 70 {
                NSAttributedString(string: String(format: "%@ %.0f ms", GaugeTimeline.severity(h, threshold: t.recording.hangThresholdNs), Double(h.duration) / 1e6),
                                   attributes: [.font: smallFont, .foregroundColor: NSColor.white]).draw(in: r.insetBy(dx: 4, dy: 0).offsetBy(dx: 0, dy: -1))
            }
        }
        // Frames: a tick per present; long frames marked.
        let frameRow = rows[after + 1]
        let long = Set(GaugeTimeline.longFrames(t.presents).map(\.time))
        for p in t.presents {
            (long.contains(p) ? NSColor.systemRed : NSColor.systemGreen).withAlphaComponent(0.8).setFill()
            NSRect(x: x(p), y: frameRow.y + 4, width: 1, height: frameRow.height - 8).fill()
        }
        // GPU: a bar per command buffer (submit to completion), height by GPU time.
        let gpuRow = rows[after + 2]
        let gpuPeak = max(1, t.gpu.map(\.gpuNs).max() ?? 1)
        for g in t.gpu {
            let h = max(2, CGFloat(Double(g.gpuNs) / Double(gpuPeak)) * (gpuRow.height - 6))
            NSColor.systemBlue.withAlphaComponent(0.6).setFill()
            NSRect(x: x(g.submit), y: gpuRow.y + gpuRow.height - 3 - h, width: max(1, x(g.end) - x(g.submit)), height: h).fill()
        }

        // The selected range.
        if let r = model.range {
            let x0 = x(r.lowerBound), x1 = x(r.upperBound)
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSRect(x: x0, y: 0, width: max(1, x1 - x0), height: bounds.height).fill()
            NSColor.controlAccentColor.withAlphaComponent(0.7).setFill()
            NSRect(x: x0, y: 0, width: 1, height: bounds.height).fill()
            NSRect(x: x1, y: 0, width: 1, height: bounds.height).fill()
            NSAttributedString(string: String(format: "%.1f ms", Double(r.upperBound - r.lowerBound) / 1e6),
                               attributes: [.font: smallFont, .foregroundColor: NSColor.controlAccentColor]).draw(at: NSPoint(x: x0 + 3, y: Self.rulerHeight - 2))
        }
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: Range selection

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p.x >= plotRect.minX ? p.x : nil
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        let a = time(atX: min(start, p.x)), b = time(atX: max(start, p.x))
        if b > a { model.range = a..<b }
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let start = dragStart, abs(p.x - start) < 3 { model.range = nil }
        dragStart = nil
        needsDisplay = true
    }

    /// Selects a time range (tests and menus).
    public func select(_ range: Range<UInt64>?) {
        model.range = range
        needsDisplay = true
    }
}
