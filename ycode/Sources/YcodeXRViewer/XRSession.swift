// The OpenXR side of `ycode-xr-viewer` (specs/simulator/xr-viewer.md §3):
// a Swift face for CYcodeOpenXR — the session, one frame's tracking as an
// `XRTrackingSample`, per-eye uploads and the projection layer.

import CYcodeOpenXR
import Foundation
import YcodeDisplayStream

extension SpatialPose {
    init(_ p: yxr_pose) {
        self.init(position: SpatialVector(Double(p.position.x), Double(p.position.y), Double(p.position.z)),
                  rotation: SpatialQuaternion(x: Double(p.orientation.x), y: Double(p.orientation.y), z: Double(p.orientation.z),
                                              w: Double(p.orientation.w)).normalized)
    }

    var xr: yxr_pose {
        yxr_pose(position: yxr_vec3(x: Float(position.x), y: Float(position.y), z: Float(position.z)),
                 orientation: yxr_quat(x: Float(rotation.x), y: Float(rotation.y), z: Float(rotation.z), w: Float(rotation.w)))
    }
}

extension XRFieldOfView {
    init(_ f: yxr_fov) { self.init(left: Double(f.angle_left), right: Double(f.angle_right), up: Double(f.angle_up), down: Double(f.angle_down)) }
    var xr: yxr_fov { yxr_fov(angle_left: Float(left), angle_right: Float(right), angle_up: Float(up), angle_down: Float(down)) }
}

/// What the runtime and the headset offer (phase 1, xr-viewer.md §2).
public struct XRSystemInfo: Sendable, CustomStringConvertible {
    public var runtime: String, system: String, gpu: String
    public var eyeGaze: Bool, handTracking: Bool, handInteraction: Bool, fbEyeSocial: Bool, touchPro: Bool
    public var viewCount: Int
    public var recommended: [(Int, Int)]
    public var swapchainFormat: Int64, bgra: Bool
    public var space: String
    public var extensions: [String]

    init(_ i: yxr_info) {
        func s<T>(_ t: T) -> String {
            withUnsafeBytes(of: t) { b in String(decoding: b.prefix { $0 != 0 }, as: UTF8.self) }
        }
        runtime = s(i.runtime)
        system = s(i.system_name)
        gpu = s(i.gpu_name)
        eyeGaze = i.eye_gaze_supported != 0
        handTracking = i.hand_tracking_supported != 0
        handInteraction = i.has_hand_interaction != 0
        fbEyeSocial = i.has_fb_eye_social != 0
        touchPro = i.has_touch_pro != 0
        viewCount = Int(i.view_count)
        recommended = [(Int(i.recommended_width.0), Int(i.recommended_height.0)), (Int(i.recommended_width.1), Int(i.recommended_height.1))]
        swapchainFormat = i.swapchain_format
        bgra = i.swapchain_bgra != 0
        space = i.space == 1 ? "stage" : i.space == 2 ? "local" : "none"
        extensions = s(i.extensions).split(separator: " ").map(String.init)
    }

    public var description: String {
        "runtime \(runtime), system \"\(system)\"" + (gpu.isEmpty ? "" : ", GPU \(gpu)")
            + ", views \(viewCount) (\(recommended.map { "\($0.0)x\($0.1)" }.joined(separator: ", ")))"
            + ", eye gaze \(eyeGaze ? "yes" : "no"), hand tracking \(handTracking ? "yes" : "no")"
            + ", hand interaction \(handInteraction ? "yes" : "no"), FB eye tracking \(fbEyeSocial ? "yes" : "no")"
            + (swapchainFormat != 0 ? ", swapchain format \(swapchainFormat)\(bgra ? " (BGRA)" : ""), space \(space)" : "")
    }
}

public enum XRSessionEvent: Sendable, Equatable {
    case state(Int)
    case recenter
    case profileChanged
    case exit
    case lost
}

/// One frame from the runtime.
public struct XRFrameState: Sendable {
    public var displayTime: Int64
    public var displayPeriod: Int64
    public var shouldRender: Bool
    public var focused: Bool
    /// The views' own fields of view (the headset's), for information.
    public var fov: [XRFieldOfView]
    public var sample: XRTrackingSample?
    /// The eye gaze's sample time against the time it was located for (ns; 0: not given).
    public var gazeSampleAge: Int64 = 0
}

public final class XRSession: @unchecked Sendable {
    /// The C session (for modules that use the hooks of CYcodeOpenXR.h:
    /// yxr_vulkan, yxr_acquire_render, yxr_queue_lock, …).
    public let handle: OpaquePointer
    public let info: XRSystemInfo

    public static func available() -> (Bool, String) {
        var err = [CChar](repeating: 0, count: 256)
        let ok = yxr_available(&err, err.count) != 0
        return (ok, text(err))
    }

    /// The instance and system only (`session` false) or a full session.
    public init(appName: String = "ycode-xr-viewer", session: Bool) throws {
        var info = yxr_info()
        var err = [CChar](repeating: 0, count: 512)
        guard let h = yxr_open(appName, session ? 1 : 0, &info, &err, err.count) else {
            throw XRViewerError.openXR(text(err))
        }
        handle = h
        self.info = XRSystemInfo(info)
    }

    deinit { yxr_close(handle) }

    public var running: Bool { yxr_running(handle) != 0 }

    /// The runtime's time for now (XrTime ns; 0 when it cannot convert).
    public var xrNow: Int64 { yxr_now(handle) }

    public func poll() -> XRSessionEvent? {
        var e = yxr_event()
        while yxr_poll(handle, &e) != 0 {
            switch Int(e.kind) {
            case Int(YXR_EVENT_STATE): return .state(Int(e.value))
            case Int(YXR_EVENT_RECENTER): return .recenter
            case Int(YXR_EVENT_PROFILE): return .profileChanged
            case Int(YXR_EVENT_EXIT): return .exit
            case Int(YXR_EVENT_LOST): return .lost
            default: continue
            }
        }
        return nil
    }

    public var lastError: String { String(cString: yxr_last_error(handle)) }

    /// Waits for and begins a frame; the tracking at its display time.
    public func beginFrame(time: Double) throws -> XRFrameState {
        var f = yxr_frame()
        guard yxr_begin_frame(handle, &f) == 0 else { throw XRViewerError.openXR(lastError) }
        // A gaze the runtime no longer tracks is a dropout, whatever pose it still gives
        // (only once it has said "tracked" at all: a runtime may never set the bit).
        if f.gaze_valid != 0 {
            if f.gaze_tracked != 0 {
                gazeEverTracked = true
                untrackedRun = 0
            } else if gazeEverTracked {
                // Two seconds without the bit while the pose stays valid: the runtime has stopped setting it; go by the pose.
                untrackedRun += 1
                if untrackedRun > 180 { gazeEverTracked = false } else { f.gaze_valid = 0; untrackedGaze += 1 }
            }
        }
        return Self.state(of: &f, time: time)
    }

    private var gazeEverTracked = false
    private var untrackedRun = 0
    /// Samples the runtime gave without its tracked bit, and that were treated as dropouts.
    public private(set) var untrackedGaze = 0

    /// 1: the gaze located at the present, not at the frame's display time.
    public func locateGazeAtPresent(_ on: Bool) { yxr_set_gaze_at_present(handle, on ? 1 : 0) }

    static func state(of f: inout yxr_frame, time: Double) -> XRFrameState {
        var sample: XRTrackingSample?
        let fovs = [XRFieldOfView(f.view_fov.0), XRFieldOfView(f.view_fov.1)]
        if f.views_valid != 0 && f.head_valid != 0 {
            var hands: [XRHandJoints?] = [nil, nil]
            var controllers: [XRController?] = [nil, nil]
            let radii: [[Double]] = withUnsafeBytes(of: &f.joint_radius) { raw in
                let r = raw.bindMemory(to: Float.self)
                return (0..<2).map { h in (0..<Int(YXR_JOINTS)).map { Double(r[h * Int(YXR_JOINTS) + $0]) } }
            }
            withUnsafeBytes(of: &f.joint) { raw in
                let joints = raw.bindMemory(to: yxr_pose.self)
                for h in 0..<2 where (h == 0 ? f.hand_valid.0 : f.hand_valid.1) != 0 {
                    let poses = (0..<Int(YXR_JOINTS)).map { SpatialPose(joints[h * Int(YXR_JOINTS) + $0]) }
                    hands[h] = XRHandJoints(poses: poses, valid: h == 0 ? f.joint_valid.0 : f.joint_valid.1, radii: radii[h])
                }
            }
            let aim = [f.aim.0, f.aim.1], grip = [f.grip.0, f.grip.1]
            let aimValid = [f.aim_valid.0, f.aim_valid.1], gripValid = [f.grip_valid.0, f.grip_valid.1]
            let controller = [f.controller_active.0, f.controller_active.1]
            let trigger = [f.trigger.0, f.trigger.1], squeeze = [f.squeeze.0, f.squeeze.1]
            let sx = [f.stick_x.0, f.stick_x.1], sy = [f.stick_y.0, f.stick_y.1], click = [f.stick_click.0, f.stick_click.1]
            let lower = [f.button_lower.0, f.button_lower.1], upper = [f.button_upper.0, f.button_upper.1]
            for h in 0..<2 where controller[h] != 0 {
                controllers[h] = XRController(aim: aimValid[h] != 0 ? SpatialPose(aim[h]) : nil, grip: gripValid[h] != 0 ? SpatialPose(grip[h]) : nil,
                                              trigger: Double(trigger[h]), squeeze: Double(squeeze[h]), stickX: Double(sx[h]), stickY: Double(sy[h]),
                                              stickClick: click[h] != 0, lowerButton: lower[h] != 0, upperButton: upper[h] != 0)
            }
            sample = XRTrackingSample(time: time, head: SpatialPose(f.head), leftEye: SpatialPose(f.view_pose.0), rightEye: SpatialPose(f.view_pose.1),
                                      gaze: f.gaze_valid != 0 ? SpatialPose(f.gaze) : nil, hands: hands, controllers: controllers)
        }
        return XRFrameState(displayTime: f.display_time, displayPeriod: f.display_period, shouldRender: f.should_render != 0,
                            focused: f.focused != 0, fov: fovs, sample: sample,
                            gazeSampleAge: f.gaze_valid != 0 && f.gaze_time != 0 ? f.display_time - f.gaze_time : 0)
    }

    /// Copies a BGRA image into eye `eye`'s swapchain (between begin and end).
    public func upload(eye: Int, pixels: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int) throws {
        guard yxr_upload(handle, Int32(eye), pixels, Int32(width), Int32(height), Int32(bytesPerRow)) == 0 else {
            throw XRViewerError.openXR(lastError)
        }
    }

    /// Copies a planar 4:4:4 video picture into eye `eye`'s swapchain (converted on several threads).
    public func uploadYUV444(eye: Int, y: UnsafePointer<UInt8>, u: UnsafePointer<UInt8>, v: UnsafePointer<UInt8>, pitch: Int, width: Int, height: Int) throws {
        guard yxr_upload_yuv444(handle, Int32(eye), y, u, v, Int32(pitch), Int32(width), Int32(height)) == 0 else {
            throw XRViewerError.openXR(lastError)
        }
    }

    /// Copies an NV12 video picture into eye `eye`'s swapchain (converted on
    /// several threads).
    public func uploadNV12(eye: Int, y: UnsafePointer<UInt8>, uv: UnsafePointer<UInt8>, pitch: Int, width: Int, height: Int) throws {
        guard yxr_upload_nv12(handle, Int32(eye), y, uv, Int32(pitch), Int32(width), Int32(height)) == 0 else {
            throw XRViewerError.openXR(lastError)
        }
    }

    /// Ends the frame: one projection layer, view i showing swapchain
    /// `images[i]` at `poses[i]` (XR base space) with `fovs[i]` (none when
    /// `images` is empty), then the sprites (the hands) over it.
    public func endFrame(images: [Int], poses: [SpatialPose], fovs: [XRFieldOfView], insets: [Int]? = nil, insetFovs: [XRFieldOfView]? = nil,
                         sprites: [XRHandSprite] = [], render: [Bool] = [false, false], depthValid: [Bool] = [false, false],
                         depthNear: Float = 0.1, depthFar: Float = 1e6) throws {
        var s = yxr_submit()
        // Hooks for a reprojecting renderer (CYcodeOpenXR.h): the rendered swapchains and depth.
        s.render = (render.first == true ? 1 : 0, render.count > 1 && render[1] ? 1 : 0)
        s.depth_valid = (depthValid.first == true ? 1 : 0, depthValid.count > 1 && depthValid[1] ? 1 : 0)
        (s.depth_near, s.depth_far) = (depthNear, depthFar)
        if images.count == 2, poses.count == 2, fovs.count == 2 {
            s.submit = 1
            s.image = (Int32(images[0]), Int32(images[1]))
            s.pose = (poses[0].xr, poses[1].xr)
            s.fov = (fovs[0].xr, fovs[1].xr)
            if let insets, let insetFovs, insets.count == 2, insetFovs.count == 2 {
                s.inset = 1
                s.inset_image = (Int32(insets[0]), Int32(insets[1]))
                s.inset_fov = (insetFovs[0].xr, insetFovs[1].xr)
            }
        }
        // A sprite's image, or its `highlight`: 3 (the right hand's layer) or 2.
        let list = sprites.prefix(Int(YXR_MAX_SPRITES)).map { yxr_sprite(pose: $0.pose.xr, size: Float($0.size), image: $0.image >= 0 ? Int32($0.image) : $0.highlight ? 3 : 2) }
        let rc = list.withUnsafeBufferPointer { b -> Int32 in
            s.sprites = b.baseAddress
            s.sprite_count = Int32(b.count)
            return yxr_end_frame(handle, &s)
        }
        guard rc == 0 else { throw XRViewerError.openXR(lastError) }
    }

    public func endFrameEmpty(sprites: [XRHandSprite] = []) throws {
        try endFrame(images: [], poses: [], fovs: [], sprites: sprites)
    }

    public func requestExit() { yxr_request_exit(handle) }
}

/// A NUL-terminated C buffer as text.
func text(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

public enum XRViewerError: Error, CustomStringConvertible {
    case openXR(String)
    case usage(String)

    public var description: String {
        switch self {
        case .openXR(let s): "OpenXR: \(s)"
        case .usage(let s): s
        }
    }
}
