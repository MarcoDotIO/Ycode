import Foundation
import Testing
@testable import ycode_simd

/// FOLD (specs/simulator/foldable.md §3, §8): the host's hinge model, its
/// sweeps, the panel it predicts, the saved record, the per-display frame
/// records, and how a panel's picture is turned.
struct FoldModelTests {
    @Test func sweepsEndOnTheTarget() {
        let open = FoldModel.sweep(from: 0, to: 180)
        #expect(open.count == 17 && open.last == 180 && open.first! > 0 && open == open.sorted())
        let close = FoldModel.sweep(from: 180, to: 0)
        #expect(close.last == 0 && close == close.sorted(by: >))
        #expect(FoldModel.sweep(from: 0, to: 180, instant: true) == [180])
        #expect(FoldModel.sweep(from: 90, to: 90) == [90])
        #expect(FoldModel.sweep(from: 0, to: 3) == [1, 2, 3])  // equal neighbours once
        #expect(FoldModel.sweep(from: 0, to: 400).last == 180)
        // About 30 ms apart over about 0.5 s.
        #expect(abs(open.count * FoldModel.sweepStepMilliseconds - FoldModel.sweepMilliseconds) <= FoldModel.sweepStepMilliseconds)
    }

    @Test func panelFollowsTheSwapPoints() {
        var m = FoldModel()
        #expect(!m.innerActive && m.posture == .closed)
        m.moved(to: 40)          // a quick sweep that stops at 40°: stays on the cover
        #expect(!m.innerActive)
        m.moved(to: 0)
        m.moved(to: 90)          // Half Open: inner
        #expect(m.innerActive && m.posture == .halfOpen)
        m.moved(to: 85)          // closing, still at 85° or more: inner
        #expect(m.innerActive)
        m.moved(to: 75)          // closing to 84° or less: the cover
        #expect(!m.innerActive)
        m.moved(to: 180)
        #expect(m.innerActive && m.posture == .openFlat)
        m.moved(to: 120)         // fold avoidance: stays inner
        #expect(m.innerActive)
        m.moved(to: 0)
        #expect(!m.innerActive && m.posture == .closed)
    }

    /// The commanded-target thresholds (foldable.md §3.3, §10.3, §10.4):
    /// the reference's measurements (opening to 85° or more → inner, to 75°
    /// or less → cover; closing from open flat to 85° or 90° → inner, to 80°
    /// or less → cover) and Ycode's own between them (opening to 76–84° →
    /// cover; closing to 81–84° → cover). Half Open ends on the inner panel
    /// from both sides.
    @Test func commandedTargetThresholds() {
        #expect(FoldModel.openingSwapAngle == 85 && FoldModel.closingSwapAngle == 84)
        for (target, inner) in [(60, false), (75, false), (76, false), (80, false), (84, false), (85, true), (90, true), (180, true)] {
            var m = FoldModel()
            m.moved(to: target)
            #expect(m.innerActive == inner, "opening to \(target)")
        }
        for (target, inner) in [(90, true), (85, true), (84, false), (81, false), (80, false), (75, false), (0, false)] {
            var m = FoldModel()
            m.moved(to: 180)
            m.moved(to: target)
            #expect(m.innerActive == inner, "closing to \(target)")
        }
        var fromClosed = FoldModel(), fromOpen = FoldModel()
        fromClosed.moved(to: FoldPosture.halfOpen.angle)
        fromOpen.moved(to: 180)
        fromOpen.moved(to: FoldPosture.halfOpen.angle)
        #expect(fromClosed.innerActive && fromOpen.innerActive)
    }

    @Test func presetsAndArguments() {
        #expect(FoldPosture.allCases.map(\.angle) == [0, 90, 180])
        #expect(FoldPosture.allCases.map(\.title) == ["Closed", "Half Open", "Open Flat"])
        #expect(FoldPosture.angle(argument: "closed") == 0 && FoldPosture.angle(argument: "half") == 90
            && FoldPosture.angle(argument: "open") == 180 && FoldPosture.angle(argument: "135") == 135)
        #expect(FoldPosture.angle(argument: "181") == nil && FoldPosture.angle(argument: "sideways") == nil)
        #expect(FoldPosture(angle: 175) == .halfOpen && FoldPosture(angle: 180) == .openFlat)
    }

    @Test func orientationNamesAndRotation() {
        #expect(DeviceMotionOrientation(name: "landscape-left") == .landscapeLeft)
        #expect(DeviceMotionOrientation(name: "faceup") == .faceUp && DeviceMotionOrientation(name: "face-down") == .faceDown)
        #expect(DeviceMotionOrientation(name: "portrait-upside-down") == nil)
        var o = DeviceMotionOrientation.portrait
        o = o.rotatedLeft; #expect(o == .landscapeLeft)
        o = o.rotatedLeft; #expect(o == .landscapeRight)
        o = o.rotatedLeft; #expect(o == .portrait)
        #expect(DeviceMotionOrientation.portrait.rotatedRight == .landscapeRight)
        #expect(DeviceMotionOrientation.allCases.map(\.rawValue) == [0, 1, 3, 4, 5, 6])
    }

    @Test func savedRecordRoundTrips() {
        var m = FoldModel()
        m.moved(to: 180)
        m.orientation = .landscapeRight
        #expect(FoldModel(record: m.record) == m)
        #expect(FoldModel(record: "nonsense") == nil)
    }

    @Test func frameRecordsPerDisplay() {
        let r = FrameRecord.parse("ycode-framebuffer 1 display 3 surface 41 rect 0 0 2007 2853 frame 9 bl 2 uio 1   \n")
        #expect(r == FrameRecord(surface: 41, frame: 9, backlight: 2, uiOrientation: 1))
        let early = FrameRecord.parse("ycode-framebuffer 1 display 3 surface 0 rect 0 0 0 0 frame 0 bl 0  \n")
        #expect(early?.surface == 0 && early?.backlight == 0)
    }

    @Test func activePanelUsesTheModelAndTheGuestsBacklight() {
        // The inner panel is published by default (not with YCODE_FOLD_DISPLAYS=0; §10.4).
        #expect(DeviceType.iPhoneDuo.panels.count == (DeviceType.foldDisplaysEnabled ? 2 : 1))
        #expect(DeviceType.iPhone18Pro.panels.count == 1 && !DeviceType.iPhone18Pro.isFoldable && DeviceType.iPhoneDuo.isFoldable)
        let inner = DeviceType.iPhoneDuo.secondDisplay!
        let panels = [PanelInfo(name: "LCD", slot: 0, width: 1398, height: 2034, scale: 3, mountRotation: 0),
                      PanelInfo(name: inner.name, slot: 1, width: inner.width, height: inner.height, scale: 3, mountRotation: inner.mountRotation)]
        #expect(panels[1].touchDisplay == 1 && inner.mountRotation == 270)
        var m = FoldModel()
        #expect(activePanel(panels, model: m, records: [nil, nil]).name == "LCD")
        m.moved(to: 180)
        #expect(activePanel(panels, model: m, records: [nil, nil]).name == "LCD-1")
        // The guest turned the inner backlight off and the cover's on: the cover.
        let lit = FrameRecord(surface: 1, frame: 1, backlight: 2), dark = FrameRecord(surface: 2, frame: 1, backlight: 0)
        #expect(activePanel(panels, model: m, records: [lit, dark]).name == "LCD")
        #expect(activePanel(panels, model: nil, records: []).name == "LCD")
        // Frames (§10.4): the predicted panel is black, the other lit → the other.
        #expect(activePanel(panels, model: m, records: [nil, nil], black: [false, true]).name == "LCD")
        #expect(activePanel(panels, model: m, records: [nil, nil], black: [true, false]).name == "LCD-1")
        // Both black, or a panel without frames: the model decides.
        #expect(activePanel(panels, model: m, records: [nil, nil], black: [true, true]).name == "LCD-1")
        #expect(activePanel(panels, model: m, records: [nil, nil], black: [false, nil]).name == "LCD-1")
        var closed = FoldModel()
        closed.moved(to: 0)
        #expect(activePanel(panels, model: closed, records: [nil, nil], black: [true, false]).name == "LCD-1")
        #expect(activePanel(panels, model: closed, records: [nil, nil], black: [false, true]).name == "LCD")
    }

    @Test func blackFrames() {
        let w = 100, h = 60, row = 104 * 4
        var px = [UInt8](repeating: 0, count: row * h)
        // Alpha alone does not light a frame.
        for y in 0..<h { for x in 0..<w { px[y * row + x * 4 + 3] = 255 } }
        #expect(px.withUnsafeBytes { PanelPicture.isBlack($0.baseAddress!, width: w, height: h, bytesPerRow: row) })
        // One lit pixel on the grid (the bottom-right corner) lights it.
        px[(h - 1) * row + (w - 1) * 4 + 1] = 9
        #expect(!px.withUnsafeBytes { PanelPicture.isBlack($0.baseAddress!, width: w, height: h, bytesPerRow: row) })
    }

    @Test func pictureTurns() {
        // 2 × 1 RGBA: A B → turned 90° clockwise it is 1 × 2: A over B.
        let a: [UInt8] = [1, 1, 1, 1], b: [UInt8] = [2, 2, 2, 2]
        let r90 = PanelPicture.rotate(rgba: a + b, width: 2, height: 1, degrees: 90)
        #expect(r90.width == 1 && r90.height == 2 && r90.pixels == a + b)
        let r270 = PanelPicture.rotate(rgba: a + b, width: 2, height: 1, degrees: 270)
        #expect(r270.pixels == b + a)
        let r180 = PanelPicture.rotate(rgba: a + b, width: 2, height: 1, degrees: 180)
        #expect(r180.width == 2 && r180.pixels == b + a)
        #expect(PanelPicture.uprightRotation(mountRotation: 270) == 90 && PanelPicture.uprightRotation(mountRotation: 0) == 0)
        #expect(PanelPicture.viewRotation(mountRotation: 270, orientation: .portrait) == 90)
        #expect(PanelPicture.viewRotation(mountRotation: 0, orientation: .landscapeLeft) == 90)
    }
}
