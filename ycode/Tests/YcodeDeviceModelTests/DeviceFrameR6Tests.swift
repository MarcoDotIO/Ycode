// Council round 6 on the device window (`specs/ide/device-hub.md` §14,
// checklist rows 154–156): Zoom to Fit's scale (the frame's outer box at the
// hub's shares of the free height and the canvas width), the frame's
// two-tone band, a foldable cover's hinge-side step and buttons, and the
// Zoom to Fit glyph. Shared by both IDEs, so these run on macOS and Linux.

import Foundation
import Testing
@testable import YcodeDeviceModel

@Suite struct DeviceFrameR6Tests {
    /// The captured window: 1100 × 800, the inspector (279.5) shown, the
    /// toolbar 52, the capsules' top at 755.5: a canvas 820.5 wide, 703.5 free.
    static let capturedArea = CGSize(width: 820.5, height: 755.5 - 52)

    @Test func theCoverAtZoomToFitIsTheReferencesBox() {
        let g = DeviceFrameGeometry(spec: .iPhoneDuo, panelIndex: 0, posture: .closed)
        let s = DeviceZoom.hubFit(frame: g.outerBox.size, in: Self.capturedArea)
        // Row 154: the cover at about 0.53 (0.532 across, 0.531 down).
        #expect(abs(s - 0.531) < 0.003, "\(s)")
        // Screen 248 × 360, frame (with the bars) 274 × 379.5.
        #expect(abs(466 * s - 248) < 1 && abs(678 * s - 360) < 1, "\(466 * s) × \(678 * s)")
        #expect(abs(Double(g.outerBox.width) * s - 274) < 1.5 && abs(Double(g.outerBox.height) * s - 379.5) < 1.5,
                "\(Double(g.outerBox.width) * s) × \(Double(g.outerBox.height) * s)")
        // Centred between the toolbar and the capsules: 161 above, 163 below
        // (the body centred; the bars stand out at the top only).
        let r = DeviceControlsLayout.deviceRect(device: g.size, scale: s, in: CGRect(x: 0, y: 52, width: 820.5, height: 703.5))
        let top = Double(r.minY) + Double(g.outerBox.minY) * s, bottom = Double(r.minY) + Double(g.outerBox.maxY) * s
        #expect(abs(top - 52 - 161) < 2 && abs(755.5 - bottom - 163) < 2, "\(top - 52) above, \(755.5 - bottom) below")
        // The screen: x 289–537, y 224–584.
        let sx = Double(r.minX) + Double(g.screen.minX) * s, sy = Double(r.minY) + Double(g.screen.minY) * s
        #expect(abs(sx - 289) < 2 && abs(sy - 224) < 2, "screen at \(sx), \(sy)")
    }

    @Test func theRuleRescalesWithTheWindow() {
        let g = DeviceFrameGeometry(spec: .iPhoneDuo, panelIndex: 0, posture: .closed)
        let box = g.outerBox.size
        // Taller window: the height share decides.
        let tall = DeviceZoom.hubFit(frame: box, in: CGSize(width: 1120, height: 1000 - 52 - 44.5))
        #expect(abs(Double(box.height) * tall - DeviceZoom.hubFitHeightShare * 903.5) < 1e-6)
        // Narrow canvas: the width share decides.
        let narrow = DeviceZoom.hubFit(frame: box, in: CGSize(width: 500, height: 703.5))
        #expect(abs(Double(box.width) * narrow - DeviceZoom.hubFitWidthShare * 500) < 1e-6)
        #expect(narrow < tall)
        // The shares are the measured ones: 54 % and 33 %.
        #expect(abs(DeviceZoom.hubFitHeightShare - 0.54) < 0.005 && abs(DeviceZoom.hubFitWidthShare - 0.33) < 0.005)
        // Extrapolated to devices the reference was not captured with
        // (device-hub.md I.16): an iPhone 18 Pro and an iPad bound by the
        // height, the open Duo by the width.
        func scale(_ g: DeviceFrameGeometry) -> Double { DeviceZoom.hubFit(frame: g.outerBox.size, in: Self.capturedArea) }
        #expect(abs(scale(DeviceFrameGeometry(spec: .iPhone18Pro)) - 0.42) < 0.005)
        #expect(abs(scale(DeviceFrameGeometry(spec: .iPadA16)) - 0.31) < 0.005)
        let open = DeviceFrameGeometry(spec: .iPhoneDuo, panelIndex: 1, posture: .openFlat)
        #expect(abs(scale(open) - 0.28) < 0.005)
        #expect(abs(Double(open.outerBox.width) * scale(open) - DeviceZoom.hubFitWidthShare * 820.5) < 1e-6)
        // The cover turns width-bound below about 1.16 times the free height.
        #expect(abs(Double(box.width) * DeviceZoom.hubFit(frame: box, in: CGSize(width: 1.15 * 703.5, height: 703.5))
                    - DeviceZoom.hubFitWidthShare * 1.15 * 703.5) < 1e-6)
        // Limits.
        #expect(DeviceZoom.hubFit(frame: CGSize(width: 1, height: 1), in: CGSize(width: 10_000, height: 10_000)) == 4)
        #expect(DeviceZoom.hubFit(frame: .zero, in: Self.capturedArea) == 1)
    }

    @Test func theBandIsTwoToneAbout16Points() {
        for spec in [DeviceFrameSpec.iPhone18Pro, .iPhoneDuo, .iPadA16] {
            let g = DeviceFrameGeometry(spec: spec)
            #expect(g.innerBand == 8.5, "\(spec.typeID)")
            let inner = try! #require(g.innerBandRect)
            #expect(inner.rect == g.screen.insetBy(dx: -8.5, dy: -8.5) && inner.radii == g.screenRadii.grown(by: 8.5))
        }
        #expect(DeviceFrameGeometry.band(.phone) == 16)
        // At the captured scale: 8.5 window points, 4.5 of them black.
        #expect(abs(16 * 0.531 - 8.5) < 0.05 && abs(8.5 * 0.531 - 4.5) < 0.05)
        // A watch keeps its one-tone band; no band, no tones.
        #expect(DeviceFrameGeometry(spec: .appleWatchSeries12_46mm).innerBandRect == nil)
        #expect(DeviceFrameGeometry(spec: .iPhone18Pro, bezels: false).innerBandRect == nil)
        // The palette: black inside, mid grey outside, the step darker.
        typealias P = DeviceFrameGeometry.Palette
        #expect(P.inner == 0x000000)
        #expect((0x50...0x6F).contains(Int(P.outer & 0xFF)) && (0x44...0x57).contains(Int(P.step & 0xFF)))
    }

    @Test func theCoverHasItsHingeStepAndItsButtons() throws {
        let g = DeviceFrameGeometry(spec: .iPhoneDuo, panelIndex: 0, posture: .closed)
        let step = try #require(g.hingeStep)
        // The step stands 11.5 out of the cover's band on the hinge (left)
        // side, 10 short of its top and bottom: with the band's grey, about
        // 19 points of grey beyond the black (10 window points at 0.531).
        #expect(Double(g.body.minX - step.minX) == DeviceFrameGeometry.hingeStepWidth)
        #expect(Double(step.minY - g.body.minY) == 10 && Double(g.body.maxY - step.maxY) == 10)
        #expect(abs((Double(g.screen.minX - step.minX) - 8.5) * 0.531 - 10) < 0.5)
        #expect(abs(Double(g.screen.minX - step.minX) * 0.531 - 14.5) < 0.5)
        // The step is under the cover, so the screen's other sides keep 16.
        #expect(g.screen.minY - g.body.minY == 16 && g.body.maxX - g.screen.maxX == 16)
        // Buttons: two bars on the top edge, one on the right, none on the hinge side.
        #expect(g.buttons.map(\.kind) == [.volumeUp, .volumeDown, .side])
        let up = g.buttons[0].rect, down = g.buttons[1].rect, side = g.buttons[2].rect
        for bar in [up, down] { #expect(bar.minY < g.body.minY && bar.maxY > g.body.minY && bar.width > bar.height) }
        #expect(abs(Double(up.width) - 65) < 0.5 && abs(Double(down.minX - up.maxX) - 16) < 0.5)
        #expect(abs(Double(up.minX - g.body.minX) - 227) < 0.5)
        #expect(side.minX < g.body.maxX && side.maxX > g.body.maxX && abs(Double(side.height) - 112) < 0.5)
        #expect(abs(Double(side.minY - g.body.minY) - 203) < 0.5)
        #expect(!g.buttons.contains { $0.rect.minX < g.body.minX })
        // The bars stand about 5 points out (2.5–3 window points at 0.531).
        #expect(Double(g.body.minY - up.minY) == DeviceFrameGeometry.phoneProtrusion)
        // The outer box: the step, the cover and the right bar across; the
        // top bars and the cover down.
        #expect(g.outerBox.minX == step.minX && g.outerBox.maxX == side.maxX && g.outerBox.minY == up.minY && g.outerBox.maxY == g.body.maxY)
        // The body (with the step) is centred in the drawing.
        #expect(abs(Double(step.minX + g.body.maxX) / 2 - Double(g.size.width) / 2) < 1e-9)
        // Other panels and devices have no step; the open Duo keeps its buttons.
        #expect(DeviceFrameGeometry(spec: .iPhoneDuo, panelIndex: 1, posture: .openFlat).hingeStep == nil)
        #expect(DeviceFrameGeometry(spec: .iPhone18Pro).hingeStep == nil)
        #expect(DeviceFrameGeometry(spec: .iPhoneDuo, panelIndex: 1, posture: .openFlat).buttons.map(\.kind) == [.action, .side, .volumeUp, .volumeDown])
    }

    @Test func theStepTurnsWithTheCover() throws {
        let up = DeviceFrameGeometry(spec: .iPhoneDuo)
        let right = DeviceFrameGeometry(spec: .iPhoneDuo, clockwiseQuarterTurns: 1)
        let step = try #require(right.hingeStep)
        // Turned clockwise, the hinge side is at the top.
        #expect(step.minY < right.body.minY && step.width == up.hingeStep!.height)
        #expect(right.hingeStepRadii == up.hingeStepRadii.turned(1))
        #expect(DeviceFrameGeometry(spec: .iPhoneDuo, clockwiseQuarterTurns: 4) == up)
    }

    @Test func zoomToFitIsAMagnifierWithFourOutwardArrowheads() {
        let g = DeviceControlGlyphs.zoomToFit
        #expect(g.size == (16, 15))
        let box = DeviceControlGlyphs.inkBox(g)
        #expect(box.minX >= -8 && box.maxX <= 8 && box.minY >= -7.5 && box.maxY <= 7.5, "\(box)")
        // The lens: one stroked circle.
        #expect(g.strokes.count == 1)
        // Four arrowheads, each pointing away from the lens's centre to a
        // diagonal corner, then the handle.
        let c = DeviceControlGlyphs.zoomLensCentre
        let heads = g.solids.prefix(4)
        #expect(g.solids.count == 5)
        var quadrants = Set<String>()
        for case .polygon(let p) in heads {
            #expect(p.count == 3)
            let tip = p[0], base = DeviceControlGlyphs.Point((p[1].x + p[2].x) / 2, (p[1].y + p[2].y) / 2)
            let dt = hypot(tip.x - c.x, tip.y - c.y), db = hypot(base.x - c.x, base.y - c.y)
            #expect(dt > db && dt < DeviceControlGlyphs.zoomLensRadius - 0.5)
            #expect(abs(abs(tip.x - c.x) - abs(tip.y - c.y)) < 1e-9)
            quadrants.insert("\(tip.x > c.x)\(tip.y > c.y)")
        }
        #expect(quadrants.count == 4)
    }
}
