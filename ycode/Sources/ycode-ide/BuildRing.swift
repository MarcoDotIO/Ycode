import Foundation
import SwiftUI
import YcodeIDECore

/// The title area's build ring (council round 9, row 212; round 10, row
/// 236), as the macOS IDE draws it (`YcodeUI/Window/BuildRingView.swift`):
/// while an action runs it replaces Ycode's mark on the same centre, a ring
/// 19 across (its ink) with a 2.5-point stroke and round caps, its track
/// #E6E6E6 in light (dark: the system's track) and an arc in the accent
/// blue (#007AFF / #0A84FF) from 12 o'clock clockwise to the build's n/m
/// (`BuildRingProgress`, from the subtitle's "Building • n/m"), 15° before
/// the first count, eased over 0.25 s to each new count, never backwards.
struct BuildRing: View {
    /// The activity subtitle.
    var activity: String
    @Environment(\.colorScheme) private var scheme
    @State private var progress = BuildRingProgress(at: BuildRing.clock())
    @State private var shown = BuildRingProgress.startFraction

    static func clock() -> Double { ProcessInfo.processInfo.systemUptime }

    var body: some View {
        let dark = scheme == .dark
        let d = CGFloat(FileGlyphs.buildRingDiameter - FileGlyphs.buildRingStroke)
        let stroke = StrokeStyle(lineWidth: CGFloat(FileGlyphs.buildRingStroke), lineCap: .round)
        ZStack {
            Circle().stroke(FileGlyphView.color(FileGlyphs.buildRingTrack, dark: dark), lineWidth: CGFloat(FileGlyphs.buildRingStroke))
                .frame(width: d, height: d)
            Path { p in
                let r = d / 2, c = CGPoint(x: r, y: r)
                // Clockwise on screen from the top (y down).
                p.addArc(center: c, radius: r, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * shown), clockwise: false)
            }
            .stroke(FileGlyphView.color(FileGlyphs.buildRingArc, dark: dark), style: stroke)
            .frame(width: d, height: d)
        }
        .frame(width: CGFloat(FileGlyphs.titleMarkSide), height: CGFloat(FileGlyphs.titleMarkSide))
        .accessibilityLabel("Build progress")
        .accessibilityValue("\(Int((progress.target * 100).rounded())) %")
        .shellTarget("build ring")
        .task(id: activity) {
            var p = progress
            guard p.update(activity: activity, at: Self.clock()) else { return }
            progress = p
            // Eased to the new fraction, one frame at a time.
            while !Task.isCancelled {
                let t = Self.clock()
                shown = p.value(at: t)
                if p.isSettled(at: t) { break }
                try? await Task.sleep(nanoseconds: 16_666_667)
            }
        }
    }
}

/// The title area's icon (council round 9, row 212, the owner's rule 4):
/// Ycode's mark in a 19.5-point box, or the build ring while an action
/// runs, at a fixed centre, the toolbar's centre line, whether or not a
/// subtitle shows (round 10, row 237), as the macOS activity view places
/// it.
struct TitleMark: View {
    var isBusy: Bool
    /// The activity subtitle (the ring's n/m).
    var activity = ""

    var body: some View {
        Group {
            if isBusy {
                BuildRing(activity: activity)
            } else {
                YcodeSmallMark(size: CGFloat(FileGlyphs.titleMarkSide))
            }
        }
        .frame(width: CGFloat(FileGlyphs.titleMarkSide), height: CGFloat(FileGlyphs.titleMarkSide))
        .shellTarget("title mark")
    }
}
