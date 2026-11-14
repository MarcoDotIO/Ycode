import Foundation
import Testing
@testable import YcodeIDECore

/// Council round 7, group B, in the models both IDEs share
/// (`specs/ide/fidelity-council.md` rows 176–180; `editor-area.md`
/// I.1–I.5): the Linux editor's flick on round 7's inputs, the stretch's
/// law, the final empty line in the merge panes, and the jump bar's icon
/// slots and collapse at 1250 and 1180.
@Suite struct CouncilRound7GroupBTests {
    /// A flick as phased steps: `step`-point gesture events 8.3 ms apart,
    /// the gesture's end, then `points` of momentum in `n` events over
    /// `span` seconds decaying with a 0.33 s time constant (I.1's inputs).
    static func flick(step: Double, points: Double, n: Int, span: Double, t0: Double = 10) -> [EditorFlick.Step] {
        var out: [EditorFlick.Step] = []
        for i in 0..<8 { out.append(.init(dy: step, phase: i == 0 ? .began : .changed, time: t0 + Double(i) * 0.0083)) }
        out.append(.init(dy: 0, phase: .ended, time: t0 + 0.062))
        let tau = 0.33, dt = span / Double(n)
        let v0 = points / (tau * (1 - exp(-span / tau)))
        for i in 0..<n {
            let a = Double(i) * dt
            out.append(.init(dy: v0 * tau * (exp(-a / tau) - exp(-(a + dt) / tau)), momentumPhase: i == 0 ? .began : .changed,
                             time: t0 + 0.066 + a))
        }
        out.append(.init(dy: 0, momentumPhase: .ended, time: t0 + 0.066 + span))
        return out
    }

    // MARK: Row 176: momentum to the edge (the Linux editor)

    /// X05 (1800 points per second, 686.7 points in all) from 600 below the
    /// top. Round 9 (row 221, superseding round 8's row 205): every
    /// momentum delta applies, so the text reaches the top, stretches a few
    /// points and comes back to it; at the events' own times as in a burst.
    @Test(arguments: [true, false]) func slowFlickReachesTheTop(burst: Bool) {
        let steps = Self.flick(step: 15, points: 566.7, n: 134, span: 1.11)
        let (curve, flick) = EditorFlickTests.run(steps, from: 600, visible: 760, burst: burst, frames: 120)
        let rest = curve.last?.offset ?? 0
        let peak = -(curve.map(\.offset).min() ?? 0)
        print("R9B Linux X05 (\(burst ? "burst" : "timed")): rest \(rest) below the top, stretch \(peak)")
        #expect(rest == 0, "\(rest)")
        #expect(peak > 2 && peak < 10, "\(peak)")
        #expect(!flick.isBouncing)
    }

    /// X03 (main 04 mirrored) from 600 above the bottom: the bottom, then
    /// the stretch by the same law as at the top.
    @Test func bottomFlickReachesTheBottom() {
        let maxOffset = 5000.0
        let steps = Self.flick(step: -40, points: -1544, n: 173, span: 1.43)
        let (curve, _) = EditorFlickTests.run(steps, from: maxOffset - 600, visible: 760, maxOffset: maxOffset, burst: false, frames: 120)
        let peak = (curve.map(\.offset).max() ?? 0) - maxOffset
        print("R7B Linux X03: stretch \(peak)")
        // Round 9 (row 222): 32 ± 4 past the end.
        #expect(abs(peak - 32) <= 4, "\(peak)")
        #expect(curve.last?.offset == maxOffset)
    }

    /// The momentum the Linux host makes from a touchpad's release decays
    /// with τ 0.33 s, so X05's release speed carries X05's distance.
    @Test func hostMomentumCarriesTheFlicksDistance() {
        // v₀ τ (1 − e^(−t/τ)) over the flick's 1.11 s: 566.7 points for
        // 1717 points per second at the release.
        let tau = 0.33, v0 = 566.7 / (tau * (1 - exp(-1.11 / tau)))
        #expect(abs(v0 * tau * (1 - exp(-1.11 / tau)) - 566.7) < 0.01)
        #expect(abs(v0 - 1765) < 50, "\(v0)")
    }

    // MARK: Row 177: the stretch

    @Test func stretchLaw() {
        // Round 9 (rows 220–222): 35 at the fast flick's crossing, about 6 at 330.
        #expect(abs(TopBounce.stretch(forCrossing: 3970) - 35) < 0.01)
        let slow = TopBounce.stretch(forCrossing: 330)
        #expect(slow > 3 && slow < 8, "\(slow)")
        // The cap, 0.28 of the view, still holds.
        #expect(abs(TopBounce.peak(velocity: TopBounce.effectiveVelocity(2_000_000, visibleHeight: 760)) - 0.28 * 760) < 0.01)
        // The return at the top (ω 11.3): half back about 148 ms after the peak.
        let v = TopBounce.effectiveVelocity(3970, visibleHeight: 760)
        let p = TopBounce.peak(velocity: v)
        let half = TopBounce.overscroll(velocity: v, at: TopBounce.peakTime + 0.148) / p
        #expect(abs(half - 0.5) < 0.05)
    }

    // MARK: Row 178: the final empty line in the merge panes

    /// Greeting.swift's shape (18 lines and a final break): both panes
    /// number 19, the empty row last; the ruler still counts 19 lines.
    @Test func mergePanesNumberTheFinalEmptyLine() {
        func text(_ a: String, _ b: String, _ c: String) -> String {
            (1...18).map { n in n == 9 ? a : n == 13 ? b : n == 17 ? c : "line \(n)" }.joined(separator: "\n") + "\n"
        }
        let doc = MergeDocument(base: text("x", "y", "z"), ours: text("o9", "o13", "z"), theirs: text("t9", "t13", "t17"))
        let rows = MergeSheetLayout.rows(doc)
        let last = rows.last
        #expect(last?.isFinalEmptyLine == true && last?.left?.number == 19 && last?.right?.number == 19)
        #expect(last?.left?.text == "" && last?.right?.text == "" && last?.hunk == nil && last?.kind == .same)
        var s = ConflictEditorState()
        s.files = ["/r/Greeting.swift"]
        s.show(file: "/r/Greeting.swift", document: doc)
        let marks: [Double] = s.rulerMarks(rows: s.sheetRows).map(\.position)
        let want: [Double] = [8.5 / 19, 12.5 / 19, 16.5 / 19]
        #expect(marks == want)
        // Without a final line break, no extra row.
        let bare = MergeSheetLayout.rows(MergeDocument(base: "a\nb", ours: "a\nB", theirs: "a\nC"))
        #expect(!bare.contains { $0.isFinalEmptyLine })
    }

    // MARK: Row 180: the jump bar

    typealias L = JumpBarPathLayout

    /// The council's path with the reference's ink widths: project 13 +
    /// "GlassScroll" 57, group 12.5 + 57, file 12.5 (11.5 of ink) + "Long"
    /// 24.5, "No Selection" 65.5.
    static let long = [L.Part(icon: 13, title: 57), L.Part(icon: 12.5, title: 57), L.Part(icon: 12.5, title: 24.5)]

    @Test func iconSlots() {
        #expect(L.iconRole(index: 0, count: 3) == .project)
        #expect(L.iconRole(index: 1, count: 4) == .group)
        #expect(L.iconRole(index: 2, count: 3) == .file)
        #expect(L.iconSlot(.project) == 13)
        #expect(L.iconSlot(.group) == 12.5 && L.iconSlot(.file) == 12.5)
        #expect(L.iconInk(.file) == 11.5)
        // The advances to the titles: 19 for the project, 18 from the
        // file's ink (its 0.5 inset, then 11.5, then 6).
        #expect(L.iconSlot(.project) + L.iconToTitle == 19)
        let inset: Double = (L.iconSlot(.file) - L.iconInk(.file)) / 2
        let fileAdvance: Double = L.iconInk(.file) + inset + L.iconToTitle
        #expect(fileAdvance == 18)
        #expect(L.chevronInk(active: true) == 3 && L.chevronInk(active: false) == 2)
        #expect(L.minimumCut == 9)
    }

    /// X07: 255 points from the project icon to 23 inside the pane's edge
    /// (361.5 to 616.5): the groups' titles go, "GlassScroll" stays whole,
    /// the path ends at 615.5 (the reference's 550–615.5 last item).
    @Test func x07KeepsTheProjectTitleWhole() {
        let f = L.fit(parts: Self.long, last: 65.5, room: 255)
        #expect(f.titles[0] == 57 && f.titles[1] == nil && f.titles[2] == 24.5 && f.last == 65.5, "\(f)")
        #expect(abs(361.5 + f.width - 615.5) <= 1, "\(361.5 + f.width)")
    }

    /// X09 (1180): 220 points: the project's title cut to about 23.5.
    @Test func x09CutsTheProjectTitle() {
        let f = L.fit(parts: Self.long, last: 65.5, room: 220)
        let t = f.titles[0] ?? 0
        #expect(t > 21 && t < 25, "\(f)")
        #expect(f.titles[2] == 24.5 && f.last == 65.5)
    }

    /// X08: Model01 (two groups): the project's title is kept down to 9
    /// points ("Gl"), then it goes.
    @Test func x08KeepsTwoLettersBeforeTheTitleGoes() {
        let parts = [L.Part(icon: 13, title: 57), L.Part(icon: 12.5, title: 57), L.Part(icon: 12.5, title: 41), L.Part(icon: 12.5, title: 43)]
        let full = L.width(parts: parts, titles: [nil, nil, nil, 43], last: 65.5)
        let kept = L.fit(parts: parts, last: 65.5, room: full + L.iconToTitle + 9)
        #expect(kept.titles[0] == 9 && kept.titles[1] == nil && kept.titles[2] == nil && kept.titles[3] == 43, "\(kept)")
        let gone = L.fit(parts: parts, last: 65.5, room: full + L.iconToTitle + 8.5)
        #expect(gone.titles[0] == nil && gone.titles[3] == 43 && gone.last == 65.5, "\(gone)")
    }

    /// 1100 (H.4) unchanged: icons only for the project and the group, the
    /// file's title cut, the last item whole.
    @Test func at1100TheFileTitleIsCut() {
        // 179 points (H.4: the full path needs 316.5).
        let f = L.fit(parts: Self.long, last: 65.5, room: 179)
        #expect(f.titles[0] == nil && f.titles[1] == nil && f.last == 65.5, "\(f)")
        let file = f.titles[2] ?? 0
        #expect(file >= 9 && file < 24.5, "\(f)")
    }
}
