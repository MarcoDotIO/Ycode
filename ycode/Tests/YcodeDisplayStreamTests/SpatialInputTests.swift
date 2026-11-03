// visionOS input (visionos.md §5.5; "Ycode implementation" there): the
// stage-frame math, the viewer interaction, and the display-stream messages.

import Foundation
import Testing
@testable import YcodeDisplayStream

struct SpatialInputTests {
    func near(_ a: Double, _ b: Double, _ e: Double = 1e-6) -> Bool { abs(a - b) <= e }
    func near(_ a: SpatialVector, _ b: SpatialVector, _ e: Double = 1e-6) -> Bool { (a - b).length <= e }

    @Test func projectionIs90DegreesHorizontal() {
        // §5.5.1: the centre looks along −Z; the right edge is 45° to the right.
        #expect(SpatialProjection.viewDirection(x: 960, y: 540, width: 1920, height: 1080) == SpatialVector(0, 0, -1))
        #expect(SpatialProjection.viewDirection(x: 1920, y: 540, width: 1920, height: 1080) == SpatialVector(1, 0, -1))
        // Pixels of the 3840 × 2160 view: ((u − 1920)/1920, −(v − 1080)/1920, −1).
        let d = SpatialProjection.viewDirection(x: 3000, y: 200, width: 3840, height: 2160)
        #expect(near(d, SpatialVector((3000 - 1920) / 1920.0, -(200 - 1080) / 1920.0, -1)))
        let p = SpatialProjection.viewPoint(direction: d, width: 3840, height: 2160)
        #expect(p.map { near($0.x, 3000) && near($0.y, 200) } == true)
        #expect(SpatialProjection.viewPoint(direction: SpatialVector(0, 0, 1), width: 10, height: 10) == nil)
    }

    @Test func rayIsTransformedByTheCamera() {
        // §5.5.1, §10.23.2 item 5: camera at (1, 0.5, 2) turned 30° left.
        var i = SpatialInteraction()
        i.camera = SpatialCamera(position: SpatialVector(1, 0.5, 2), yaw: 30 * .pi / 180)
        let r = i.ray(x: 960, y: 540)
        #expect(near(r.origin, SpatialVector(1, 0.5, 2)))
        #expect(near(r.direction, SpatialVector(-sin(.pi / 6), 0, -cos(.pi / 6))))
        // Pitch up: the centre ray points up.
        i.camera = SpatialCamera(pitch: 10 * .pi / 180)
        #expect(i.ray(x: 960, y: 540).direction.y > 0)
    }

    @Test func columnMajorMatrix() {
        let pose = SpatialPose(position: SpatialVector(1, 1.6, -2), rotation: SpatialQuaternion(axis: SpatialVector(0, 1, 0), radians: .pi / 2))
        let m = pose.columnMajor
        #expect(m.count == 16 && m[12] == 1 && m[13] == 1.6 && m[14] == -2 && m[15] == 1)
        // Column 0 is the turned +X: a quarter turn left about +Y sends +X to −Z.
        #expect(abs(m[0]) < 1e-6 && abs(m[2] - -1) < 1e-6 && m[3] == 0)
        #expect(SpatialPose.identity.columnMajor == [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
        let back = SpatialPose(matrixBytes: pose.matrixBytes)
        #expect(back.map { near($0.position, pose.position, 1e-6) && near($0.forward, pose.forward, 1e-5) } == true)
        #expect(SpatialPose(matrixBytes: [UInt8](repeating: 0, count: 63)) == nil)
        #expect(pose.matrixBytes.count == 64)
    }

    @Test func cameraFromPoseKeepsYawAndPitch() {
        let c = SpatialCamera(position: SpatialVector(0.5, 0, -1), yaw: 0.4, pitch: -0.2)
        let back = SpatialCamera(pose: c.pose)
        #expect(near(back.yaw, 0.4) && near(back.pitch, -0.2) && near(back.position, c.position))
    }

    @Test func cameraMoves() {
        var c = SpatialCamera()
        c.move(forward: 1)
        #expect(near(c.position, SpatialVector(0, 0, -1)))
        c.turn(yaw: .pi / 2, pitch: 0)  // now facing −X
        c.move(forward: 1, right: 0, up: 0.5)
        #expect(near(c.position, SpatialVector(-1, 0.5, -1)))
        c.turn(yaw: 0, pitch: 3)  // clamped to 89°
        #expect(c.pitch <= 89 * .pi / 180 + 1e-9)
        c.reset()
        #expect(c.pose == .identity)
    }

    @Test func hoverIsSelectionOnly() {
        var i = SpatialInteraction()
        let s = i.hover(x: 960, y: 540)
        #expect(!s.hasHands && s.left == nil && s.right == nil)
        #expect(near(s.rayDirection, SpatialVector(0, 0, -1)))
    }

    @Test func clickPinchesTheRightHandAtTheGaze() {
        var i = SpatialInteraction()
        let down = i.press(x: 1200, y: 400)
        #expect(down.hasHands && down.right?.pinching == true && down.left?.pinching == false)
        #expect(near(down.right!.position, SpatialInteraction.rightRest))
        #expect(near(down.left!.position, SpatialInteraction.leftRest))
        // Drag: the gaze stays at the press point, the hand moves 70 points ≈ 0.1 m.
        let moved = i.drag(x: 1270, y: 400)
        #expect(near(moved.rayDirection, down.rayDirection))
        #expect(near(moved.right!.position.x - down.right!.position.x, 0.1, 1e-9))
        #expect(moved.right?.pinching == true)
        // Up on the screen is +Y.
        let up = i.drag(x: 1270, y: 330)
        #expect(near(up.right!.position.y - down.right!.position.y, 0.1, 1e-9))
        let released = i.release()
        #expect(released?.right?.pinching == false && released?.hasHands == true)
        #expect(i.release() == nil && !i.isPinching)
    }

    @Test func depthDragMovesTheHandForward() {
        var i = SpatialInteraction()
        let down = i.press(x: 960, y: 540)
        let s = i.drag(x: 960, y: 470, depth: true)  // pointer up = forward (−Z)
        #expect(near(s.right!.position.z - down.right!.position.z, -0.1, 1e-9))
        #expect(near(s.right!.position.y, down.right!.position.y, 1e-9))
    }

    @Test func handsFollowTheCamera() {
        var i = SpatialInteraction()
        i.camera = SpatialCamera(position: SpatialVector(0, 0, 1), yaw: .pi / 2)
        let s = i.press(x: 960, y: 540)
        // Camera space (0.15, −0.35, −0.4) turned a quarter left: (−0.4, −0.35, −0.15) + (0, 0, 1).
        #expect(near(s.right!.position, SpatialVector(-0.4, -0.35, 0.85)))
        #expect(near(s.right!.rotation.rotate(SpatialVector(0, 0, -1)), SpatialVector(-1, 0, 0)))
    }

    @Test func twoHandMagnifyAndRotate() {
        var i = SpatialInteraction()
        let down = i.press(x: 960, y: 540, twoHands: true)
        #expect(down.left?.pinching == true && down.right?.pinching == true)
        let s0 = (down.right!.position - down.left!.position).length
        // Magnify ×1.5.
        let o = i.twoHandOffset(scale: 1.5, radians: 0)
        let m = i.drag(x: 960 + o.dx, y: 540 + o.dy)
        #expect(near((m.right!.position - m.left!.position).length / s0, 1.5, 1e-6))
        _ = i.release()
        // Rotate 30° counter-clockwise as the user sees it: the right hand goes up.
        _ = i.press(x: 960, y: 540, twoHands: true)
        let r = i.twoHandOffset(scale: 1, radians: .pi / 6)
        let t = i.drag(x: 960 + r.dx, y: 540 + r.dy)
        let v = t.right!.position - t.left!.position
        #expect(near(atan2(v.y, v.x), .pi / 6, 1e-6) && near(v.length, s0, 1e-6))
    }

    @Test func cameraKeys() {
        #expect(SpatialCameraKeys.direction(usage: 0x1A)! == (1, 0, 0))   // W
        #expect(SpatialCameraKeys.direction(usage: 0x07)! == (0, 1, 0))   // D
        #expect(SpatialCameraKeys.direction(usage: 0x08)! == (0, 0, 1))   // E
        #expect(SpatialCameraKeys.direction(usage: 0x28) == nil)
        var i = SpatialInteraction()
        let p = i.step(forward: 1)
        #expect(near(p.position, SpatialVector(0, 0, -SpatialInteraction.keyStep)))
        let l = i.look(dx: 100, dy: 0)  // pointer right: turn right (yaw negative)
        #expect(l.forward.x > 0)
        #expect(i.resetCamera() == .identity)
    }

    @Test func messagesRoundTrip() throws {
        let pose = SpatialPose(position: SpatialVector(0.5, -0.25, 1), rotation: SpatialQuaternion(x: 0, y: 0.5, z: 0, w: 0.75))
        // Values a 32-bit float carries exactly (the stream's floats are f32).
        let hands = SpatialSelection(rayOrigin: SpatialVector(0, 0, 0), rayDirection: SpatialVector(0.0625, 0.03125, -1),
                                     left: SpatialHand(pinching: true, allowDirect: false, position: SpatialVector(-0.125, -0.375, -0.5)),
                                     right: SpatialHand(pinching: false, allowDirect: true, position: SpatialVector(0.125, -0.375, -0.5),
                                                        rotation: SpatialQuaternion(x: 0, y: 0, z: 0.5, w: 0.75)))
        let only = SpatialSelection(rayOrigin: SpatialVector(1, 2, 3), rayDirection: SpatialVector(0, 0, -1))
        for m: DisplayMessage in [.input(.pose(sequence: 3, pose: pose)), .input(.selection(sequence: 4, selection: hands)),
                                  .input(.selection(sequence: 5, selection: only)), .input(.dial(sequence: 6, delta: -2.5))] {
            let bytes = m.encoded()
            let back = try DisplayMessage.decode(type: bytes[4], payload: bytes[5...])
            #expect(back == m)
        }
        #expect(DisplayMessage.input(.pose(sequence: 1, pose: pose)).encoded().count == 5 + 4 + 28)
        #expect(DisplayMessage.input(.selection(sequence: 1, selection: only)).encoded().count == 5 + 4 + 4 + 24)
        #expect(DisplayMessage.input(.selection(sequence: 1, selection: hands)).encoded().count == 5 + 4 + 4 + 24 + 2 * 32)
        #expect(DisplayMessageType.pose.rawValue == 0x8A && DisplayMessageType.selection.rawValue == 0x8B && DisplayMessageType.dial.rawValue == 0x8C)
    }

    @Test func helloNegotiatesSpatial() throws {
        var h = DisplayServerHello(deviceName: "d", model: "RealityDevice14,1", pixelWidth: 3840, pixelHeight: 2160, scale: 2,
                                   encodings: ["jpeg"], touch: true, keyboard: true, buttons: ["home"], rotation: false)
        // An older server's hello has no `spatial`: the viewer sends none of the new kinds.
        let old = try JSONDecoder().decode(DisplayServerHello.self, from: JSONEncoder().encode(h))
        #expect(old.spatial == nil)
        h.spatial = true
        h.rooms = ["LivingRoomDay", "MuseumDay"]
        let back = try JSONDecoder().decode(DisplayServerHello.self, from: JSONEncoder().encode(h))
        #expect(back.spatial == true && back.rooms == ["LivingRoomDay", "MuseumDay"])
    }
}
