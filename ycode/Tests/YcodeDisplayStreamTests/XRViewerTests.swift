// The headset viewer's shared logic (specs/simulator/xr-viewer.md): the
// stage-frame anchor, the guest's field of view, pinch hysteresis, the
// tracking → input mapping, the eye scheduler's tags, the new messages and
// the picture signature. No OpenXR involved.

import Foundation
import Testing
@testable import YcodeDisplayStream

private func close(_ a: Double, _ b: Double, _ eps: Double = 1e-4) -> Bool { abs(a - b) <= eps }
private func close(_ a: SpatialVector, _ b: SpatialVector, _ eps: Double = 1e-4) -> Bool { (a - b).length <= eps }
private func sameRotation(_ a: SpatialQuaternion, _ b: SpatialQuaternion, _ eps: Double = 1e-4) -> Bool {
    abs(a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w) >= 1 - eps
}

/// A hand's 26 joints: an open hand at `at` (palm), fingers along −Z, the
/// thumb tip `gap` metres from the index tip.
private func hand(at p: SpatialVector, gap: Double, indexStraight: Bool = false) -> XRHandJoints {
    var poses = [SpatialPose](repeating: SpatialPose(position: p), count: 26)
    // Index: metacarpal → tip, along −Z, bent unless straight.
    let chain = [XRHandJoints.indexMetacarpal, XRHandJoints.indexProximal, XRHandJoints.indexIntermediate, XRHandJoints.indexDistal, XRHandJoints.indexTip]
    // A curled finger turns down and back towards the palm.
    let curled = [SpatialVector(0, 0, 0), SpatialVector(0, 0, -0.04), SpatialVector(0, -0.025, -0.06), SpatialVector(0, -0.045, -0.055),
                  SpatialVector(0, -0.055, -0.04)]
    for (k, j) in chain.enumerated() {
        poses[j] = SpatialPose(position: p + (indexStraight ? SpatialVector(0, 0, -Double(k) * 0.025) : curled[k]))
    }
    poses[XRHandJoints.thumbTip] = SpatialPose(position: poses[XRHandJoints.indexTip].position + SpatialVector(gap, 0, 0))
    return XRHandJoints(poses: poses)
}

@Suite struct XRStageAnchorTests {
    @Test func headBecomesTheDefaultEye() {
        let head = SpatialPose(position: SpatialVector(1, 1.6, 2), rotation: SpatialQuaternion(yaw: .pi / 2, pitch: 0))
        let a = XRStageAnchor(head: head)
        let s = a.toStage(head)
        #expect(close(s.position, .zero))
        #expect(sameRotation(s.rotation, .identity))
        // One metre in front of the head (turned left: −X) is (0, 0, −1) on the stage.
        #expect(close(a.toStage(point: SpatialVector(0, 1.6, 2)), SpatialVector(0, 0, -1)))
        #expect(close(a.toStage(direction: SpatialVector(-1, 0, 0)), SpatialVector(0, 0, -1)))
    }

    @Test func pitchAndRollAreNotPartOfTheAnchor() {
        let head = SpatialPose(position: SpatialVector(0, 1.2, 0), rotation: SpatialQuaternion(yaw: 0.3, pitch: 0.4) * SpatialQuaternion(axis: SpatialVector(0, 0, 1), radians: 0.2))
        let a = XRStageAnchor(head: head)
        #expect(close(a.yaw, 0.3, 1e-6))
        // Straight up stays straight up.
        #expect(close(a.toStage(direction: SpatialVector(0, 1, 0)), SpatialVector(0, 1, 0)))
        // The head keeps its pitch in the stage frame.
        let f = a.toStage(head).forward
        #expect(close(asin(f.y), 0.4, 1e-4))
    }

    @Test func fromStageInvertsToStage() {
        let a = XRStageAnchor(origin: SpatialVector(0.3, 1.5, -0.2), yaw: -0.7)
        let p = SpatialPose(position: SpatialVector(-0.1, 0.2, -0.5), rotation: SpatialQuaternion(yaw: 0.2, pitch: -0.1))
        let back = a.toStage(a.fromStage(p))
        #expect(close(back.position, p.position))
        #expect(sameRotation(back.rotation, p.rotation))
    }
}

@Suite struct XRFieldOfViewTests {
    @Test func guestProjectionIsNinetyDegreesWide() {
        let f = XRFieldOfView.guest(width: 3840, height: 2160)
        #expect(close(f.right * 180 / .pi, 45) && close(f.left * 180 / .pi, -45))
        #expect(close(tan(f.up), 0.5625) && close(tan(f.down), -0.5625))
        let t = f.tangents
        let g = XRFieldOfView(tangentLeft: t.left, right: t.right, up: t.up, down: t.down)
        #expect(close(g.up, f.up) && close(g.left, f.left))
    }
}

@Suite struct XRHysteresisTests {
    @Test func fingerPinchDoesNotFlicker() {
        var h = XRHysteresis.fingerPinch()
        let distances = [0.05, 0.03, 0.021, 0.019, 0.025, 0.034, 0.03, 0.036, 0.022, 0.018]
        let states = distances.map { h.update($0) }
        #expect(states == [false, false, false, true, true, true, true, false, false, true])
    }

    @Test func triggerNeedsToRiseAndFall() {
        var h = XRHysteresis.trigger()
        #expect([0.1, 0.6, 0.75, 0.5, 0.41, 0.39, 0.69, 0.71].map { h.update($0) } == [false, false, true, true, true, false, false, true])
    }
}

@Suite struct XRInputMapperTests {
    let head = SpatialPose(position: SpatialVector(0, 1.6, 0))

    @Test func firstSampleAnchorsAndGivesBothEyes() {
        var m = XRInputMapper()
        let out = m.map(XRTrackingSample(time: 0, head: head))
        #expect(close(out.views.head.position, .zero))
        #expect(close(out.views.left.position, SpatialVector(-0.0315, 0, 0)))
        #expect(close(out.views.right.position, SpatialVector(0.0315, 0, 0)))
        #expect(out.views.stereo)
        // No hands, no controllers: the hands rest below the head (§5.5.8 item 4), not pinching.
        #expect(close(out.selection.right!.position, SpatialInteraction.rightRest))
        #expect(out.selection.right!.pinching == false && out.selection.left!.pinching == false)
        // No eyes: the head's ray.
        #expect(close(out.selection.rayDirection, SpatialVector(0, 0, -1)))
    }

    @Test func eyeGazeIsTheRayInTheStageFrame() {
        var m = XRInputMapper()
        _ = m.map(XRTrackingSample(time: 0, head: head))
        // Eyes 20° to the right of the head.
        let gaze = SpatialPose(position: SpatialVector(0, 1.6, 0), rotation: SpatialQuaternion(yaw: -20 * .pi / 180, pitch: 0))
        let out = m.map(XRTrackingSample(time: 0.011, head: head, gaze: gaze))
        #expect(close(out.selection.rayOrigin, .zero))
        #expect(close(out.selection.rayDirection, SpatialVector(sin(20 * .pi / 180), 0, -cos(20 * .pi / 180))))
        // --pointer head ignores the eyes.
        var h = XRInputMapper(pointer: .head)
        _ = h.map(XRTrackingSample(time: 0, head: head))
        #expect(close(h.map(XRTrackingSample(time: 0.01, head: head, gaze: gaze)).selection.rayDirection, SpatialVector(0, 0, -1)))
    }

    @Test func trackedHandPinchesWithHysteresisAtThePinchPoint() {
        var m = XRInputMapper()
        let at = SpatialVector(0.1, 1.3, -0.4)
        var pinched: [Bool] = []
        for (i, gap) in [0.05, 0.015, 0.03, 0.04, 0.04].enumerated() {
            let out = m.map(XRTrackingSample(time: Double(i) * 0.011, head: head, hands: [nil, hand(at: at, gap: gap)]))
            pinched.append(out.selection.right!.pinching)
            if i == 1 {
                // The pinch point: halfway between thumb tip and index tip, in the stage frame.
                let tip = hand(at: at, gap: gap).poses[XRHandJoints.indexTip].position
                #expect(close(out.selection.right!.position, tip + SpatialVector(gap / 2, -1.6, 0)))
                #expect(out.selection.right!.allowDirect == false)
            }
        }
        // The release takes two samples over the threshold (a bounce is no release).
        #expect(pinched == [false, true, true, true, false])
    }

    @Test func pokingIndexAllowsDirectTouchAtTheTip() {
        var m = XRInputMapper()
        let at = SpatialVector(0, 1.4, -0.3)
        let j = hand(at: at, gap: 0.08, indexStraight: true)
        let out = m.map(XRTrackingSample(time: 0, head: head, hands: [nil, j]))
        #expect(out.selection.right!.allowDirect)
        #expect(close(out.selection.right!.position, j.poses[XRHandJoints.indexTip].position - SpatialVector(0, 1.6, 0)))
        // A bent finger: no direct touch.
        let bent = m.map(XRTrackingSample(time: 0.01, head: head, hands: [nil, hand(at: at, gap: 0.08)]))
        #expect(bent.selection.right!.allowDirect == false)
    }

    @Test func controllerTriggerPinchesAndAimsWithoutEyes() {
        var m = XRInputMapper()
        let aim = SpatialPose(position: SpatialVector(0.2, 1.2, -0.3), rotation: SpatialQuaternion(yaw: 0, pitch: 0.2))
        func sample(_ t: Double, _ trigger: Double) -> XRTrackingSample {
            XRTrackingSample(time: t, head: head, controllers: [nil, XRController(aim: aim, grip: aim, trigger: trigger)])
        }
        _ = m.map(sample(0, 0))
        let on = m.map(sample(0.01, 0.9))
        #expect(on.selection.right!.pinching)
        #expect(close(on.selection.rayOrigin, SpatialVector(0.2, -0.4, -0.3)))
        #expect(close(on.selection.rayDirection, aim.forward))
        #expect(m.map(sample(0.02, 0.5)).selection.right!.pinching)
        #expect(!m.map(sample(0.03, 0.3)).selection.right!.pinching)
    }

    @Test func crownButtonKeepsItsTimingAndStickTurnsImmersion() {
        var m = XRInputMapper(immersion: 0.5)
        func c(_ t: Double, a: Bool, y: Double) -> XRTrackingSample {
            XRTrackingSample(time: t, head: head, controllers: [nil, XRController(stickY: y, lowerButton: a)])
        }
        #expect(m.map(c(0, a: false, y: 0)).crown == nil)
        #expect(m.map(c(0.01, a: true, y: 0)).crown == true)
        #expect(m.map(c(0.6, a: true, y: 0)).crown == nil)
        #expect(m.map(c(0.61, a: false, y: 0)).crown == false)
        // Full deflection for 0.1 s: +0.05 at 0.5 per second.
        let up = m.map(c(0.71, a: false, y: 1))
        #expect(close(up.immersion ?? -1, 0.55, 1e-6))
        // Clamped at 1.
        var t = 0.71
        var last: Double?
        for _ in 0..<20 { t += 0.1; last = m.map(c(t, a: false, y: 1)).immersion ?? last }
        #expect(last == 1)
        // A small stick (dead zone) sends nothing.
        #expect(m.map(c(t + 0.1, a: false, y: 0.1)).immersion == nil)
    }

    @Test func recenterReanchorsAtTheHead() {
        var m = XRInputMapper()
        _ = m.map(XRTrackingSample(time: 0, head: head))
        let turned = SpatialPose(position: SpatialVector(0.5, 1.6, 0.5), rotation: SpatialQuaternion(yaw: 1, pitch: 0))
        let before = m.map(XRTrackingSample(time: 0.01, head: turned))
        #expect(!close(before.views.head.position, .zero))
        let after = m.map(XRTrackingSample(time: 0.02, head: turned, recenter: true))
        #expect(after.recentred)
        #expect(close(after.views.head.position, .zero))
        #expect(sameRotation(after.views.head.rotation, .identity))
    }
}

@Suite struct XREyeSchedulerTests {
    func views(_ seq: UInt32, x: Double = 0) -> XRViews {
        XRViews(sequence: seq, stereo: true, head: SpatialPose(position: SpatialVector(x, 0, 0)),
                left: SpatialPose(position: SpatialVector(x - 0.03, 0, 0)), right: SpatialPose(position: SpatialVector(x + 0.03, 0, 0)))
    }

    let ms: UInt64 = 1_000_000

    @Test func alternateTakesEachEyesPictureOnceItSettles() {
        var s = XREyeScheduler(mode: .alternate, settleTime: 170 * ms, maxSettleTime: 350 * ms)
        s.update(views(1))
        #expect(s.idle(at: 0)?.view == .left)
        #expect(s.idle(at: 1 * ms) == nil)              // one pose in flight
        // The guest's picture changes at 170, 210 and 250 ms (its layers catch up).
        for t in [170, 210, 250] as [UInt64] {
            #expect(s.picture(at: t * ms).tag == nil)   // alternate: pictures are only noted
            #expect(s.due(at: t * ms + 1) == nil)        // not quiet yet
        }
        #expect(s.due(at: 300 * ms) == nil)
        let d = s.due(at: 311 * ms)                      // 60 ms quiet after the last change
        #expect(d?.tag.view == .left && d?.estimated == false && d?.send?.view == .right)
        #expect(s.due(at: 312 * ms) == nil)              // the right eye just went out
    }

    @Test func alternateNeverWaitsPastTheMaximum() {
        var s = XREyeScheduler(mode: .alternate, settleTime: 170 * ms, maxSettleTime: 350 * ms)
        s.update(views(1))
        _ = s.idle(at: 0)
        // An animated scene: a new picture every 40 ms, never quiet.
        var t: UInt64 = 0
        var due: (tag: XREyeScheduler.Send, estimated: Bool, send: XREyeScheduler.Send?)?
        while due == nil && t < 1000 { t += 10; if t % 40 == 0 { _ = s.picture(at: t * ms) }; due = s.due(at: t * ms) }
        #expect(t == 350 && due?.tag.view == .left && due?.estimated == true)
        // A scene that does not change at all: the picture is taken at the maximum, marked estimated.
        var still = XREyeScheduler(mode: .alternate, settleTime: 170 * ms, maxSettleTime: 350 * ms)
        still.update(views(1))
        _ = still.idle(at: 0)
        #expect(still.due(at: 349 * ms) == nil)
        #expect(still.due(at: 350 * ms)?.estimated == true)
    }

    @Test func adaptiveIsMonoWhileMovingAndEyesWhenStill() {
        var s = XREyeScheduler(mode: .adaptive)          // still after 300 ms; settle 250–420 ms
        s.update(views(1), at: 0)
        #expect(s.idle(at: 1 * ms)?.view == .mono)
        // Moving: each head change goes out as mono (16 ms apart at least).
        s.update(views(2, x: 0.05), at: 20 * ms)
        #expect(s.idle(at: 21 * ms)?.view == .mono)
        #expect(s.picture(at: 60 * ms).tag?.view == .mono)
        // Still from 20 ms: at 320 ms the head has been still for 300 ms and its pose is old enough: the left eye.
        #expect(s.idle(at: 200 * ms) == nil)
        #expect(s.effectiveMode(at: 320 * ms) == .alternate)
        #expect(s.idle(at: 320 * ms)?.view == .left)
        #expect(s.picture(at: 500 * ms).tag == nil)        // eye pictures are not shown as they come
        // The picture interval is now measured (two pictures 440 ms apart raise
        // it), so the eye's picture is taken later: at least six intervals.
        #expect(s.due(at: 600 * ms) == nil)
        let d = s.due(at: 900 * ms)
        #expect(d?.tag.view == .left && d?.send?.view == .right)
        // The head moves again: mono at once, the right eye given up.
        s.update(views(3, x: 0.2), at: 910 * ms)
        #expect(s.idle(at: 911 * ms)?.view == .mono)
        #expect(s.due(at: 1500 * ms) == nil)
    }

    @Test func monoTagsWithThePoseSentTheRenderDelayEarlier() {
        var s = XREyeScheduler(mode: .mono, renderDelay: 240 * ms)
        s.update(views(1))
        _ = s.idle(at: 0)
        s.update(views(2, x: 0.1))
        _ = s.idle(at: 100 * ms)
        #expect(s.picture(at: 200 * ms).tag?.poseSequence == 1)   // nothing 240 ms old yet: the oldest
        #expect(s.picture(at: 300 * ms).tag?.poseSequence == 1)   // pose 1 is 300 ms old, pose 2 only 200
        #expect(s.picture(at: 341 * ms).tag?.poseSequence == 2)
    }

    @Test func measuredRenderDelayIsSixPictureIntervals() {
        var s = XREyeScheduler(mode: .mono)
        s.update(views(1))
        _ = s.idle(at: 0)
        var t: UInt64 = 0
        for _ in 0..<60 { t += 40 * ms; _ = s.picture(at: t) }
        #expect(abs(Double(s.effectiveRenderDelay) / 1e6 - 240) < 5)
        // A still head (below the deadband) sends nothing more.
        s.update(XRViews(sequence: 2, stereo: true, head: SpatialPose(position: SpatialVector(0.0001, 0, 0)),
                         left: .identity, right: .identity))
        #expect(s.idle(at: t + 100 * ms) == nil)
    }

    @Test func monoSendsTheHeadWhenItMoves() {
        var s = XREyeScheduler(mode: .mono, renderDelay: 1_000_000)
        s.update(views(1))
        #expect(s.idle(at: 0)?.view == .mono)
        #expect(s.idle(at: 1_000_000) == nil)           // unchanged
        s.update(views(2, x: 0.1))
        #expect(s.idle(at: 2_000_000) == nil)           // within 16 ms of the last send
        let next = s.idle(at: 20_000_000)
        #expect(next?.poseSequence == 2 && close(next!.pose.position.x, 0.1))
        #expect(s.picture(at: 30_000_000).tag?.poseSequence == 2)
    }
}

@Suite struct XRMessageTests {
    @Test func viewsAndFrameViewRoundTrip() throws {
        let v = XRViews(sequence: 7, stereo: true, head: SpatialPose(position: SpatialVector(0.1, 0.2, 0.3), rotation: SpatialQuaternion(yaw: 0.2, pitch: 0.1)),
                        left: SpatialPose(position: SpatialVector(0.07, 0.2, 0.3)), right: SpatialPose(position: SpatialVector(0.13, 0.2, 0.3)))
        let tag = XRFrameView(frameSequence: 42, view: .right, estimated: true, latch: 2, poseSequence: 7,
                              pose: v.right, fov: .guest(width: 3840, height: 2160), guestFrame: 9000)
        for m in [DisplayMessage.input(.views(sequence: 7, views: v)), .frameView(tag)] {
            var p = DisplayMessageParser()
            p.append(m.encoded())
            let back = try #require(try p.next())
            switch (m, back) {
            case (.input(.views(let s1, let a)), .input(.views(let s2, let b))):
                #expect(s1 == s2 && a.stereo == b.stereo && close(a.right.position, b.right.position) && sameRotation(a.head.rotation, b.head.rotation))
            case (.frameView(let a), .frameView(let b)):
                #expect(a.frameSequence == b.frameSequence && a.view == b.view && a.estimated == b.estimated && a.latch == b.latch)
                #expect(a.poseSequence == b.poseSequence && a.guestFrame == b.guestFrame && close(a.fov.up, b.fov.up) && close(a.pose.position, b.pose.position))
            default: Issue.record("mismatch: \(back)")
            }
        }
        #expect(DisplayMessageType.frameView.rawValue == 0x0A && DisplayMessageType.views.rawValue == 0x8D)
    }

    @Test func helloCarriesTheRequest() throws {
        var h = DisplayClientHello(client: "x")
        h.xr = XRClientRequest(stereo: "alternate", latch: 2)
        let back = try JSONDecoder().decode(DisplayClientHello.self, from: JSONEncoder().encode(h))
        #expect(back.xr == h.xr)
        // An older client's hello has none.
        let old = try JSONDecoder().decode(DisplayClientHello.self, from: Data(#"{"protocol":"ycode-display/1","client":"o","maxFPS":60,"encoding":"jpeg","quality":75,"downscale":1}"#.utf8))
        #expect(old.xr == nil)
    }
}

@Suite struct XRScriptAndSignatureTests {
    @Test func recorderDropsTheGaze() throws {
        let s = XRTrackingSample(time: 1, head: .identity, gaze: SpatialPose(position: SpatialVector(0, 0, 0), rotation: SpatialQuaternion(yaw: 0.1, pitch: 0)))
        let line = XRSampleScript.encode(s)
        #expect(!line.contains("gaze"))
        let back = try XRSampleScript.decode("# a comment\n" + line + "\n\n")
        #expect(back.count == 1 && back[0].gaze == nil && back[0].time == 1)
        // A written script may carry one (tests of the gaze path).
        #expect(try XRSampleScript.decode(XRSampleScript.encode(s, keepGaze: true))[0].gaze != nil)
    }

    @Test func signatureSeesChangesAtTheSamples() {
        let w = 256, h = 144
        var a = [UInt8](repeating: 0x40, count: w * h * 4)
        let s1 = a.withUnsafeBytes { XRPictureSignature.of($0.baseAddress!, width: w, height: h, bytesPerRow: w * 4) }
        let s2 = a.withUnsafeBytes { XRPictureSignature.of($0.baseAddress!, width: w, height: h, bytesPerRow: w * 4) }
        #expect(s1 == s2)
        // Sample (gx 0, gy 0) is at x = w/128, y = h/72.
        let x = w / 128, y = h / 72
        a[(y * w + x) * 4] = 0x41
        let s3 = a.withUnsafeBytes { XRPictureSignature.of($0.baseAddress!, width: w, height: h, bytesPerRow: w * 4) }
        #expect(s3 != s1)
    }
}

@Suite struct XRFoveationTests {
    @Test func insetRectIsCentredOnTheGazeAndInside() {
        let r = XRInset.rect(u: 0.5, v: 0.5, width: 3840, height: 2160, fraction: 0.35)
        #expect(r.width == 1344 && r.height == 752)
        #expect(abs(r.x + r.width / 2 - 1920) <= 16 && abs(r.y + r.height / 2 - 1080) <= 16)
        let corner = XRInset.rect(u: 0, v: 1, width: 3840, height: 2160, fraction: 0.35)
        #expect(corner.x == 0 && corner.y == 2160 - corner.height)
        #expect(XRInset.rect(u: 0.9, v: 0.1, width: 3840, height: 2160, fraction: 0.35).x % 16 == 0)
    }

    @Test func insetFieldOfViewIsTheSubFrustum() {
        let full = XRFieldOfView.guest(width: 3840, height: 2160)
        let f = XRInset.fov(of: (1920, 1080, 960, 540), in: full, width: 3840, height: 2160)
        #expect(close(tan(f.left), 0) && close(tan(f.right), 0.5) && close(tan(f.up), 0) && close(tan(f.down), -0.28125))
        // The whole picture is the whole field.
        let all = XRInset.fov(of: (0, 0, 3840, 2160), in: full, width: 3840, height: 2160)
        #expect(close(all.left, full.left) && close(all.down, full.down))
    }

    @Test func gazePointInTheView() {
        let fov = XRFieldOfView.guest(width: 3840, height: 2160)
        let c = XRInset.point(gaze: SpatialVector(0, 0, -1), fov: fov)!
        #expect(close(c.u, 0.5) && close(c.v, 0.5))
        let right = XRInset.point(gaze: SpatialVector(0.5, 0.5625 / 2, -1), fov: fov)!
        #expect(close(right.u, 0.75) && close(right.v, 0.25))
        #expect(XRInset.point(gaze: SpatialVector(0, 0, 1), fov: fov) == nil)
    }

    @Test func insetAndFoveaRoundTrip() throws {
        let i = XRInset(frameSequence: 9, view: .left, encoding: .jpeg, x: 16, y: 32, width: 64, height: 48, fullWidth: 3840, fullHeight: 2160, data: [1, 2, 3])
        for m in [DisplayMessage.inset(i), .input(.fovea(sequence: 4, u: 0.25, v: 0.75))] {
            var p = DisplayMessageParser()
            p.append(m.encoded())
            #expect(try p.next() == m)
        }
        #expect(DisplayMessageType.inset.rawValue == 0x0B && DisplayMessageType.fovea.rawValue == 0x8E)
    }
}

@Suite struct XREyeYawTests {
    @Test func cantTurnsEachEyeOutwards() {
        let v = XRViews(sequence: 1, stereo: true, head: .identity, left: SpatialPose(position: SpatialVector(-0.03, 0, 0)),
                        right: SpatialPose(position: SpatialVector(0.03, 0, 0)))
        let c = v.canted(degrees: 7)
        let lf = c.left.forward, rf = c.right.forward
        // The left eye looks 7° left (−X), the right eye 7° right; positions and head unchanged.
        #expect(abs(atan2(-lf.x, -lf.z) * 180 / .pi - 7) < 1e-9 && abs(atan2(-rf.x, -rf.z) * 180 / .pi + 7) < 1e-9)
        #expect(c.left.position == v.left.position && c.head == v.head)
        #expect(v.canted(degrees: 0) == v)
    }
}

@Suite struct XRGazeFilterTests {
    @Test func oneEuroSmoothsJitterAndFollowsSaccades() {
        var f = XROneEuro(minCutoff: 1.0, beta: 0.02)
        // Fixation at 10° with ±0.5° alternating noise at 90 Hz.
        var out: [Double] = []
        for i in 0..<180 { out.append(f.filter(10 + (i % 2 == 0 ? 0.5 : -0.5), at: Double(i) / 90)) }
        let tail = out.suffix(60)
        #expect(tail.max()! - tail.min()! < 0.2)          // jitter of 1° peak-to-peak → under 0.2°
        // A 20° saccade: within 100 ms the output is most of the way there.
        var t = 2.0
        var last = 0.0
        for _ in 0..<9 { t += 1 / 90; last = f.filter(30, at: t) }
        #expect(last > 25)
    }

    @Test func mapperCountsGazeWithoutKeepingIt() {
        var m = XRInputMapper()
        let head = SpatialPose(position: SpatialVector(0, 1.6, 0))
        for i in 0..<90 {
            let jitter = (i % 2 == 0 ? 0.3 : -0.3) * .pi / 180
            let g = SpatialPose(position: head.position, rotation: SpatialQuaternion(yaw: 0.1 + jitter, pitch: 0))
            _ = m.map(XRTrackingSample(time: Double(i) / 90, head: head, gaze: i == 45 ? nil : g))
        }
        #expect(m.gazeStats.samples == 89 && m.gazeStats.dropouts == 1)
        #expect(abs(m.gazeStats.rawJitterDegrees - 0.6) < 0.05)
        #expect(m.gazeStats.filteredResidualDegrees > 0.2)
        // The ray sent is the filtered one: close to the fixation's 0.1 rad.
        let d = m.lastGaze!.forward
        #expect(abs(atan2(-d.x, -d.z) - 0.1) < 0.6 * .pi / 180)
    }
}
