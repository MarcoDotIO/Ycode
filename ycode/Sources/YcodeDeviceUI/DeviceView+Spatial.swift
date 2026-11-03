// A Vision Pro's input in the macOS viewer and the IDE's device canvas
// (specs/simulator/visionos.md §5.1, §5.5.7 item 4; Ycode's choices in
// "Ycode implementation" there). Active when the server's hello says
// `spatial`; the shared SpatialInteraction (YcodeDisplayStream) makes the
// stage-frame values:
//
//   pointer moves               the gaze (a selection-only message)
//   click / drag                right-hand pinch at the gaze, the hand moves with the pointer
//   shift + drag                the pinched hand moves forward (up) or back (down)
//   option + drag               both hands pinch: spread = magnify, turn = rotate
//   control + drag              mouse-look (turns the camera)
//   scroll / two-finger swipe   camera left/right and up/down
//   trackpad pinch              camera forward/back
//   option + scroll             the Digital Crown
//   option + W A S D, arrows    camera forward/left/back/right, option + E/Q up/down,
//                               option + R the start pose (Reset Camera)
//   keys                        the keyboard, as on iOS (text fields)

#if os(macOS)
import AppKit
import YcodeDisplayStream

extension DeviceView {
    var spatialOn: Bool { input?.isSpatial == true }

    private func spatialPoint(_ event: NSEvent) -> CGPoint { devicePoint(convert(event.locationInWindow, from: nil)) }

    /// After a camera move: the pose, then the gaze again (it is in the stage frame).
    func spatialCameraMoved(_ pose: SpatialPose) {
        input?.sendPose(pose)
        if !spatial.isPinching { input?.sendSelection(spatial.gazeSelection, label: nil) }
    }

    func spatialMouseDown(_ event: NSEvent) -> Bool {
        guard spatialOn else { return false }
        window?.makeFirstResponder(self)
        let p = spatialPoint(event)
        if event.modifierFlags.contains(.control) {
            spatialLook = p
            return true
        }
        let s = spatial.press(x: p.x, y: p.y, twoHands: event.modifierFlags.contains(.option))
        input?.sendSelection(s, label: "pinch")
        return true
    }

    func spatialMouseDragged(_ event: NSEvent) -> Bool {
        guard spatialOn else { return false }
        let p = spatialPoint(event)
        if let from = spatialLook {
            spatialLook = p
            spatialCameraMoved(spatial.look(dx: p.x - from.x, dy: p.y - from.y))
            return true
        }
        input?.sendSelection(spatial.drag(x: p.x, y: p.y, depth: event.modifierFlags.contains(.shift)), label: nil)
        return true
    }

    func spatialMouseUp(_ event: NSEvent) -> Bool {
        guard spatialOn else { return false }
        if spatialLook != nil {
            spatialLook = nil
            return true
        }
        if let s = spatial.release() { input?.sendSelection(s, label: nil) }
        return true
    }

    func spatialMouseMoved(_ event: NSEvent) -> Bool {
        guard spatialOn else { return false }
        let p = spatialPoint(event)
        input?.sendSelection(spatial.hover(x: p.x, y: p.y), label: nil)
        return true
    }

    /// Metres of camera motion per point of precise scrolling (a wheel's line is 10 points).
    static let spatialScrollMetres = 0.004

    func spatialScroll(_ event: NSEvent) -> Bool {
        guard spatialOn else { return false }
        guard event.momentumPhase.isEmpty else { return true }
        let scale = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
        if event.modifierFlags.contains(.option) {
            if event.scrollingDeltaY != 0 {
                input?.turnDial(by: Self.crownDelta(scrollingDeltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas))
            }
            return true
        }
        let dx = Double(event.scrollingDeltaX) * scale * Self.spatialScrollMetres
        let dy = Double(event.scrollingDeltaY) * scale * Self.spatialScrollMetres
        guard dx != 0 || dy != 0 else { return true }
        spatialCameraMoved(spatial.step(forward: 0, right: -dx / SpatialInteraction.keyStep, up: dy / SpatialInteraction.keyStep))
        return true
    }

    func spatialMagnify(_ event: NSEvent) -> Bool {
        guard spatialOn else { return false }
        // Pinch out moves forward: 1 m per unit of magnification.
        spatialCameraMoved(spatial.step(forward: Double(event.magnification) / SpatialInteraction.keyStep))
        return true
    }

    func spatialKeyDown(_ event: NSEvent) -> Bool {
        guard spatialOn, event.modifierFlags.contains(.option), !event.modifierFlags.contains(.command),
              let usage = KeyMap.usage[event.keyCode] else { return false }
        if usage == 0x15 {  // R: Reset Camera
            spatialCameraMoved(spatial.resetCamera())
            return true
        }
        guard let d = SpatialCameraKeys.direction(usage: usage) else { return false }
        spatialCameraMoved(spatial.step(forward: d.forward, right: d.right, up: d.up))
        return true
    }

    /// The desktop's camera again (after the headset had the device,
    /// device-hub.md §I.12): the guest's camera is where the wearer's head
    /// was; the desktop sends its own pose, as it was before the switch.
    public func restoreSpatialCamera() {
        guard spatialOn else { return }
        spatialCameraMoved(spatial.camera.pose)
    }

    /// Controls ▸ Reset Camera.
    public func resetSpatialCamera() {
        guard spatialOn else { return }
        spatialCameraMoved(spatial.resetCamera())
    }

    func spatialCancel() {
        spatialLook = nil
        if spatialOn, let s = spatial.release() { input?.sendSelection(s, label: nil) }
    }
}
#endif
