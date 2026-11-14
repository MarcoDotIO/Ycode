import AppKit
import QuartzCore
import YcodeIDECore

/// The title area's build ring (council round 9, row 212; round 10, row
/// 236): while a build runs it replaces Ycode's mark, on the same centre,
/// a ring 19 across (its ink) with a 2.5-point stroke and round caps: a
/// track (#E6E6E6 in light; dark, the system's track) and an arc in the
/// accent blue (#007AFF / #0A84FF) from 12 o'clock clockwise to the
/// build's n/m (`BuildRingProgress`, from the subtitle's "Building • n/m"),
/// 15° before the first count. Each new fraction is reached by easing over
/// 0.25 s; the arc never moves backwards. The Linux IDE draws the same
/// ring (`ycode-ide/BuildRing.swift`).
final class BuildRingView: NSView {
    let track = CAShapeLayer()
    let arc = CAShapeLayer()
    /// The arc's progress (the activity view feeds it the subtitle).
    private(set) var progress = BuildRingProgress()
    /// The clock the easing runs on (tests replace it).
    var now: () -> Double = { CACurrentMediaTime() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [track, arc] {
            l.fillColor = nil
            l.lineWidth = CGFloat(FileGlyphs.buildRingStroke)
            layer?.addSublayer(l)
        }
        arc.lineCap = .round
        arc.strokeEnd = CGFloat(BuildRingProgress.startFraction)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Build progress")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var allowsVibrancy: Bool { false }

    /// A new build: the arc back to its 15° start.
    func reset() {
        progress = BuildRingProgress(at: now())
        arc.removeAnimation(forKey: "fill")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.strokeEnd = CGFloat(progress.target)
        CATransaction.commit()
        setAccessibilityValue(progress.target)
    }

    /// The subtitle changed: a larger count eases the arc to its fraction.
    func setActivity(_ text: String) {
        let t = now()
        let shown = progress.value(at: t)
        guard progress.update(activity: text, at: t) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.strokeEnd = CGFloat(progress.target)
        CATransaction.commit()
        let fill = CABasicAnimation(keyPath: "strokeEnd")
        fill.fromValue = shown
        fill.toValue = progress.target
        fill.duration = BuildRingProgress.easeDuration
        // An ease-out cubic, as the shared model's.
        fill.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
        arc.add(fill, forKey: "fill")
        setAccessibilityValue(progress.target)
    }

    /// The ring's rectangle (its stroke's centre line), centred in the view.
    var ringRect: NSRect {
        let d = CGFloat(FileGlyphs.buildRingDiameter) - CGFloat(FileGlyphs.buildRingStroke)
        return NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = ringRect
        for l in [track, arc] {
            l.frame = bounds
            l.bounds = bounds
        }
        track.path = CGPath(ellipseIn: r, transform: nil)
        // Clockwise from the top (layers are y up: from +90° towards 0°).
        let p = CGMutablePath()
        p.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: r.width / 2, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        arc.path = p
        CATransaction.commit()
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    func updateColors() {
        func cg(_ g: GlyphColor) -> CGColor {
            let c = g.rgb(dark: isDark)
            return CGColor(srgbRed: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: 1)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.strokeColor = cg(FileGlyphs.buildRingTrack)
        arc.strokeColor = cg(FileGlyphs.buildRingArc)
        CATransaction.commit()
    }
}
