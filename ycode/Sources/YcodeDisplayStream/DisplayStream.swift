// The display stream protocol between ycode-simd's display server and a
// viewer (specs/simulator/display-stream.md). Ycode's own design: framed
// binary messages over a byte stream (a Unix or TCP socket). Shared by the
// server (Linux) and the viewer (macOS); Foundation only.

import Foundation

public enum DisplayStream {
    /// The protocol name in both hellos (§3.1).
    public static let protocolName = "ycode-display/1"
    /// The largest message either side accepts (§2).
    public static let maxMessageSize = 64 << 20
}

/// Message types (§2). 0x01–0x7F: server to client; 0x81–0xFF: client to server.
public enum DisplayMessageType: UInt8, Sendable {
    case hello = 0x01
    case status = 0x02
    case frame = 0x03
    case pong = 0x04
    case screenshot = 0x05
    case notice = 0x06
    /// The panel shown and the fold (foldable.md "Ycode implementation").
    case displayState = 0x07
    /// The answer to a command (0x90): u32 token, UTF-8 text ("ok …" or "error: …").
    case commandReply = 0x10
    /// The server's stage times of the frame just sent (§12; only when the
    /// client hello asked for `timing`).
    case frameTiming = 0x08
    /// The device's sound (§15): a packet of audio with its play time.
    case audio = 0x09
    /// The headset viewer (xr-viewer.md §4.1): the view and pose of the
    /// next frame message, sent just before it.
    case frameView = 0x0A
    /// Foveated streaming (xr-viewer.md §4.5): the full-resolution inset
    /// around the gaze for the frame just sent.
    case inset = 0x0B
    /// The headset mode's depth of the frame just sent (xr-depth.md §4; only
    /// when the client hello asked for `xr.depthDownscale`).
    case frameDepth = 0x0C
    /// The room's environment cube (xr-depth.md §4.3; when the client hello asked for `xr.environment`).
    case environment = 0x0D

    case clientHello = 0x81
    case touch = 0x82
    case key = 0x83
    case button = 0x84
    case ping = 0x85
    case keyframeRequest = 0x86
    case screenshotRequest = 0x87
    case rotate = 0x88
    /// u16 hinge angle 0…180, u8 flags (bit 0: one message, no sweep).
    case fold = 0x89
    /// visionOS (visionos.md "Ycode implementation"; only when the hello's
    /// `spatial` is true): the camera pose, a gaze-and-hands selection, and
    /// a Digital Crown turn, all in the stage frame (§5.5.1).
    case pose = 0x8A
    case selection = 0x8B
    case dial = 0x8C
    /// The headset viewer: head and eye poses (xr-viewer.md §4.1; latest wins).
    case views = 0x8D
    /// Foveated streaming: where the eyes look in the guest's view (latest wins).
    case fovea = 0x8E
    /// The newest frame decoded (a viewer with `frameWindow`, §4.2): the server
    /// keeps at most that many frames unacknowledged, and takes the newest picture when one is free.
    case frameAck = 0x8F
    /// A device command (simulator-features.md "Ycode implementation"): u32
    /// token, UTF-8 words of a control-socket command ("ui appearance dark").
    case command = 0x90
}

// MARK: - Control messages (JSON)

/// The server's hello (§3.1): the device and what the server accepts.
public struct DisplayServerHello: Codable, Sendable, Equatable {
    public var `protocol`: String = DisplayStream.protocolName
    public var deviceName: String
    public var model: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double
    public var pointWidth: Double
    public var pointHeight: Double
    /// "portrait", "portraitUpsideDown", "landscapeLeft", "landscapeRight".
    public var orientation: String
    public var encodings: [String]
    public var touch: Bool
    public var keyboard: Bool
    /// The buttons the server delivers (names of `DisplayButton`).
    public var buttons: [String]
    public var rotation: Bool
    /// The device folds (foldable.md): the server takes fold messages and
    /// sends display states; nil or false otherwise.
    public var foldable: Bool?
    /// The built-in displays (names), display 1 first; nil: just one.
    public var displays: [String]?
    /// Ycode's device type id (`ycode-simd --device-type`, e.g. "iphone-duo")
    /// and the runtime ("iOS 27.1"): the viewer draws the device's frame and
    /// titles its window with them (device-hub.md "Ycode implementation").
    /// Optional: older servers send neither.
    public var deviceType: String?
    public var osVersion: String?
    /// The audio codecs the server can send (§15); nil: no audio.
    public var audio: [String]?
    /// The server takes the visionOS input messages (pose 0x8A, selection
    /// 0x8B, dial 0x8C; visionos.md "Ycode implementation"). Viewers send
    /// them only when this is true; nil or false: an older server or a
    /// device that is not a Vision Pro.
    public var spatial: Bool?
    /// The simulated rooms the device offers (keys, e.g. "LivingRoomDay"),
    /// and the active one, when known at connect time; the `vision rooms`
    /// command answers later.
    public var rooms: [String]?
    /// The server has the headset mode (views 0x8D, frame views 0x0A;
    /// xr-viewer.md §4.1). Nil or false: an older server or not visionOS.
    public var xr: Bool?
    /// The server can send each picture's depth (frame depth 0x0C; xr-depth.md §4).
    public var xrDepth: Bool?
    /// The server can send the room's environment (0x0D; xr-depth.md §4.3).
    public var xrEnvironment: Bool?
    /// The server honours a client's `frameWindow` (frame acks 0x8F, §4.2).
    public var frameAcks: Bool?

    public init(deviceName: String, model: String, pixelWidth: Int, pixelHeight: Int, scale: Double,
                orientation: String = "portrait", encodings: [String], touch: Bool, keyboard: Bool,
                buttons: [String], rotation: Bool, foldable: Bool? = nil, displays: [String]? = nil) {
        self.foldable = foldable
        self.displays = displays
        self.deviceName = deviceName
        self.model = model
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.pointWidth = Double(pixelWidth) / scale
        self.pointHeight = Double(pixelHeight) / scale
        self.orientation = orientation
        self.encodings = encodings
        self.touch = touch
        self.keyboard = keyboard
        self.buttons = buttons
        self.rotation = rotation
    }
}

/// The panel the server shows and the fold (0x07; foldable.md "Ycode
/// implementation"). Sent before the first frame and whenever it changes;
/// the frames that follow are that panel's, starting with a full frame.
public struct DisplayPanelState: Codable, Sendable, Equatable {
    /// "LCD" (the cover / only display) or "LCD-1" (the inner panel).
    public var display: String
    /// The panel's framebuffer pixels (native portrait) and scale: frames,
    /// touches (in its points, native orientation) and screenshots use them.
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double
    /// Degrees (0, 90, 180, 270) to turn the framebuffer image clockwise to
    /// show it as the device is held.
    public var rotation: Int
    /// The hinge angle last sent, and the one a sweep is moving to (nil: none).
    public var hingeAngle: Int
    public var targetAngle: Int?
    /// "closed", "halfOpen", "openFlat".
    public var posture: String
    /// The device orientation ("portrait", "landscape-left", …).
    public var orientation: String

    public init(display: String, pixelWidth: Int, pixelHeight: Int, scale: Double, rotation: Int, hingeAngle: Int,
                targetAngle: Int?, posture: String, orientation: String) {
        self.display = display
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.rotation = rotation
        self.hingeAngle = hingeAngle
        self.targetAngle = targetAngle
        self.posture = posture
        self.orientation = orientation
    }

    public var pointWidth: Double { Double(pixelWidth) / scale }
    public var pointHeight: Double { Double(pixelHeight) / scale }

    /// The rotation, 0, 90, 180 or 270.
    public var quarterTurns: Int { (((rotation % 360) + 360) % 360) / 90 }

    /// The panel's size in points as shown (turned by `rotation`).
    public var shownPointSize: (width: Double, height: Double) {
        quarterTurns % 2 == 1 ? (pointHeight, pointWidth) : (pointWidth, pointHeight)
    }

    /// A point of the shown (turned) picture → the panel's own points
    /// (native orientation, origin top-left), the touch space (§5.1).
    public func nativePoint(shownX x: Double, shownY y: Double) -> (x: Double, y: Double) {
        switch quarterTurns {
        case 1: (y, pointHeight - x)
        case 2: (pointWidth - x, pointHeight - y)
        case 3: (pointWidth - y, x)
        default: (x, y)
        }
    }
}

/// The client's hello (§3.2): how it wants frames.
/// The server's notice to a viewer that another one took the display over
/// (display-stream.md §1). A viewer that gets it does not reconnect by
/// itself: it waits until its user takes the display back (§1.1).
public enum DisplayNotice {
    public static let takenOver = "another viewer connected; this one is closed"
    /// The phase a viewer reports while another one has the display.
    public static let takenOverPhase = "takenOver"
}

public struct DisplayClientHello: Codable, Sendable, Equatable {
    public var `protocol`: String = DisplayStream.protocolName
    public var client: String
    /// Frames per second at most (1...120).
    public var maxFPS: Int
    /// "hevc444", "hevc", "h264", "jpeg" or "zlib" (lossless BGRA).
    public var encoding: String
    /// Every encoding this client decodes, best first (§14): the server takes
    /// the first it offers. Nil: `encoding` alone (older clients).
    public var encodings: [String]?
    /// JPEG quality (1...100).
    public var quality: Int
    /// Integer downscale of the device pixels (1...4).
    public var downscale: Int
    /// Ask for a frame timing message (0x08) after every frame (§12).
    /// Optional: older clients and servers leave it out.
    public var timing: Bool?
    /// The video bit rate in kbit/s (§14; nil: the server's default).
    public var videoBitrate: Int?
    /// Constant QP for video (§14; nil or 0: by bit rate). The stream sends a
    /// picture only when it changes, so nothing would refine a starved one.
    public var videoQP: Int?
    /// By bit rate with this nominal picture rate: CBR with a VBV of one
    /// picture (§14). Nil: VBR at `maxFPS`, as older clients get.
    public var videoFPS: Int?
    /// The audio codecs the client plays, preferred first ("opus", "pcm";
    /// §15). Nil or empty: no audio is sent.
    public var audio: [String]?
    /// The headset viewer's request (xr-viewer.md §4.1); nil: an ordinary viewer.
    public var xr: XRClientRequest?
    /// Flow control (§4.2): at most this many frames sent and not yet
    /// acknowledged (0x8F). Nil or 0: as fast as the transport takes them.
    public var frameWindow: Int?
    /// Lossless once still (§4.2.2): once the screen has not changed for a
    /// moment, the server sends the parts it last sent lossy (JPEG, video)
    /// again as zlib tiles, so a still picture is exact (pixel-exact text at
    /// 1:1). Ycode's viewers ask for it (the initializer's default); nil
    /// (older clients) or false: lossy pictures stay as they are.
    public var stillLossless: Bool?

    public init(client: String, maxFPS: Int = 60, encoding: String = "jpeg", quality: Int = 75, downscale: Int = 1) {
        self.client = client
        self.maxFPS = maxFPS
        self.encoding = encoding
        self.quality = quality
        self.downscale = downscale
        stillLossless = true
    }
}

/// What a headset viewer asks for (xr-viewer.md §4.1).
public struct XRClientRequest: Codable, Sendable, Equatable {
    /// "adaptive" (mono while the head moves, the eyes in turn while it is
    /// still), "alternate" (the eyes in turn) or "mono".
    public var stereo: String
    /// Pictures between a pose and the picture rendered with it (nil: the server's default).
    public var latch: Int?
    /// Alternate stereo: the least milliseconds a pose has before its picture is taken (nil: the server's default).
    public var settleMs: Int?
    /// Foveated streaming (§4.5): the whole picture at the hello's downscale
    /// plus a full-resolution inset of this fraction of each side around the
    /// gaze (nil or 0: off).
    public var foveaFraction: Double?
    /// Eye pictures (alternate, adaptive when still): each eye's guest
    /// camera turned outwards by this many degrees (left eye left, right eye
    /// right), so its symmetric 90° covers most of the headset's asymmetric
    /// per-eye frustum (xr-viewer.md §4.6). Nil or 0: parallel eyes.
    public var eyeYawDegrees: Double?

    /// Each picture's depth at the picture's size divided by this (2, 4 or 8;
    /// nil or 0: no depth; xr-depth.md §4).
    public var depthDownscale: Int?
    /// Send the room's environment now and whenever it changes (0x0D; xr-depth.md §4.3).
    public var environment: Bool?

    public init(stereo: String, latch: Int? = nil, settleMs: Int? = nil, depthDownscale: Int? = nil) {
        (self.stereo, self.latch, self.settleMs, self.depthDownscale) = (stereo, latch, settleMs, depthDownscale)
    }
}

/// The server's status (§3.3).
public struct DisplayStatus: Codable, Sendable, Equatable {
    /// "booting" (no frame presented yet), "live", or "stopping".
    public var phase: String
    public var uptimeMilliseconds: Int
    public var guestFrames: Int
    public var message: String?

    public init(phase: String, uptimeMilliseconds: Int, guestFrames: Int, message: String? = nil) {
        self.phase = phase
        self.uptimeMilliseconds = uptimeMilliseconds
        self.guestFrames = guestFrames
        self.message = message
    }
}

// MARK: - Frames

public enum DisplayEncoding: UInt8, Sendable {
    case jpeg = 1
    /// zlib (RFC 1950) of packed BGRA rows.
    case zlibBGRA = 2
    /// H.264 (ITU-T H.264, Annex B byte stream): one tile covering the whole
    /// image, one access unit; `isFull` marks an IDR picture (§14).
    case h264 = 3
    /// HEVC 4:2:0 (ITU-T H.265, Annex B), carried as H.264 is (§14).
    case hevc = 4
    /// HEVC 4:4:4 (Range Extensions): chroma at every pixel, for coloured UI text and edges (§14).
    case hevc444 = 5

    public init?(name: String) {
        switch name {
        case "jpeg": self = .jpeg
        case "zlib": self = .zlibBGRA
        case "h264": self = .h264
        case "hevc": self = .hevc
        case "hevc444": self = .hevc444
        default: return nil
        }
    }

    /// Whole pictures through a video codec (one tile, one access unit), not tiles of pixels.
    public var isVideo: Bool { self == .h264 || self == .hevc || self == .hevc444 }

    public var name: String {
        switch self {
        case .jpeg: "jpeg"
        case .zlibBGRA: "zlib"
        case .h264: "h264"
        case .hevc: "hevc"
        case .hevc444: "hevc444"
        }
    }
}

/// One rectangle of new pixels, in stream-image coordinates.
public struct DisplayTile: Sendable, Equatable {
    public var x: Int, y: Int, width: Int, height: Int
    public var data: [UInt8]

    public init(x: Int, y: Int, width: Int, height: Int, data: [UInt8]) {
        (self.x, self.y, self.width, self.height, self.data) = (x, y, width, height, data)
    }
}

/// A frame update (§4): tiles to draw over the previous image.
public struct DisplayFrame: Sendable, Equatable {
    public var sequence: UInt64
    public var guestFrame: UInt64
    public var serverNanoseconds: UInt64
    /// The newest input sequence number the server had delivered when it
    /// read these pixels (0: none).
    public var inputSequence: UInt32
    /// The size of the stream image (device pixels / downscale).
    public var width: Int, height: Int
    public var encoding: DisplayEncoding
    /// The tiles cover the whole image.
    public var isFull: Bool
    public var tiles: [DisplayTile]

    public init(sequence: UInt64, guestFrame: UInt64, serverNanoseconds: UInt64, inputSequence: UInt32, width: Int,
                height: Int, encoding: DisplayEncoding, isFull: Bool, tiles: [DisplayTile]) {
        self.sequence = sequence
        self.guestFrame = guestFrame
        self.serverNanoseconds = serverNanoseconds
        self.inputSequence = inputSequence
        self.width = width
        self.height = height
        self.encoding = encoding
        self.isFull = isFull
        self.tiles = tiles
    }

    public var byteCount: Int { tiles.reduce(0) { $0 + $1.data.count } }
}

/// The server's times of one frame (0x08, §12), its monotonic ns: when it
/// saw the guest's frame record change, when it began reading the surface
/// (scan), when the encoded frame was ready, and when the frame's last byte
/// was handed to the socket. 0: not known (a speculative scan has no record).
public struct DisplayFrameTiming: Sendable, Equatable {
    public var sequence: UInt64
    public var recordSeen: UInt64
    public var captureStart: UInt64
    public var encodeEnd: UInt64
    public var sendEnd: UInt64

    public init(sequence: UInt64, recordSeen: UInt64, captureStart: UInt64, encodeEnd: UInt64, sendEnd: UInt64) {
        (self.sequence, self.recordSeen, self.captureStart, self.encodeEnd, self.sendEnd) = (sequence, recordSeen, captureStart, encodeEnd, sendEnd)
    }
}

/// One packet of the device's sound (0x09, §15): 48 kHz interleaved
/// stereo; `playTime` is the server monotonic ns at which the device plays
/// its first frame (the guest's output time on the host clock).
public struct DisplayAudio: Sendable, Equatable {
    public enum Codec: UInt8, Sendable { case pcm16 = 1, opus = 2 }
    public var playTime: UInt64
    public var codec: Codec
    public var channels: Int
    public var frames: Int
    public var sampleRate: Int
    public var data: [UInt8]

    public init(playTime: UInt64, codec: Codec, channels: Int = 2, frames: Int, sampleRate: Int = 48000, data: [UInt8]) {
        (self.playTime, self.codec, self.channels, self.frames, self.sampleRate, self.data) = (playTime, codec, channels, frames, sampleRate, data)
    }
}

// MARK: - Input

public enum TouchPhase: UInt8, Sendable {
    case began = 0, moved = 1, ended = 2, cancelled = 3
}

/// One finger of a touch report, in device points (§5.1).
public struct TouchContact: Sendable, Equatable {
    public var finger: UInt8
    public var phase: TouchPhase
    public var x: Float, y: Float

    public init(finger: UInt8, phase: TouchPhase, x: Float, y: Float) {
        (self.finger, self.phase, self.x, self.y) = (finger, phase, x, y)
    }
}

public enum DisplayButton: UInt8, Sendable, CaseIterable {
    case home = 1, lock = 2, volumeUp = 3, volumeDown = 4, side = 5
    /// An Action button (§5.3): a server lists "action" in its hello's
    /// `buttons` when it takes this value (watchos.md §5.2); viewers send it
    /// only then (an older server closes the connection on an unknown value).
    case action = 6

    public var name: String {
        switch self {
        case .home: "home"
        case .lock: "lock"
        case .volumeUp: "volumeUp"
        case .volumeDown: "volumeDown"
        case .side: "side"
        case .action: "action"
        }
    }
}

/// A client → server input event (§5).
public enum DisplayInput: Sendable, Equatable {
    case touch(sequence: UInt32, contacts: [TouchContact])
    /// A keyboard key: HID usage page (7 = keyboard) and usage.
    case key(sequence: UInt32, down: Bool, usagePage: UInt16, usage: UInt16)
    case button(sequence: UInt32, button: DisplayButton, down: Bool)
    /// visionOS: the camera pose (stage frame; identity = the default eye).
    case pose(sequence: UInt32, pose: SpatialPose)
    /// visionOS: the gaze ray and, unless selection-only, both hands.
    case selection(sequence: UInt32, selection: SpatialSelection)
    /// visionOS: the Digital Crown turned by `delta` (signed).
    case dial(sequence: UInt32, delta: Double)
    /// The headset's head and eyes (xr-viewer.md §4.1).
    case views(sequence: UInt32, views: XRViews)
    /// Where the eyes look: (u, v) in the guest's view, 0…1 from the top left.
    case fovea(sequence: UInt32, u: Float, v: Float)

    public var sequence: UInt32 {
        switch self {
        case .touch(let s, _), .key(let s, _, _, _), .button(let s, _, _), .pose(let s, _), .selection(let s, _), .dial(let s, _), .views(let s, _), .fovea(let s, _, _): s
        }
    }
}

// MARK: - Messages

public enum DisplayMessage: Sendable, Equatable {
    case hello(DisplayServerHello)
    case status(DisplayStatus)
    case frame(DisplayFrame)
    case pong(token: UInt64, serverNanoseconds: UInt64)
    case screenshot(token: UInt32, png: [UInt8])
    case notice(String)
    case displayState(DisplayPanelState)
    case commandReply(token: UInt32, text: String)
    case frameTiming(DisplayFrameTiming)
    case audio(DisplayAudio)
    case frameView(XRFrameView)
    case inset(XRInset)
    case frameDepth(XRFrameDepth)
    case environment(XREnvironment)

    case clientHello(DisplayClientHello)
    case input(DisplayInput)
    case ping(token: UInt64)
    case keyframeRequest
    /// Every frame up to this sequence is decoded (§4.2).
    case frameAck(sequence: UInt64)
    case screenshotRequest(token: UInt32)
    /// 1 portrait, 2 upside down, 3 landscape left, 4 landscape right.
    case rotate(orientation: UInt8)
    /// Move the hinge to `angle` degrees (a sweep; one message when `instant`).
    case fold(angle: UInt16, instant: Bool)
    /// A control-socket command for the device; answered by `commandReply`.
    case command(token: UInt32, text: String)
}

public enum DisplayStreamError: Error, Equatable {
    case tooLarge(Int)
    case unknownType(UInt8)
    case truncated(String)
    case badJSON(String)
}

// MARK: - Encoding

struct ByteWriter {
    var bytes: [UInt8] = []
    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes += [UInt8(v & 0xFF), UInt8(v >> 8)] }
    mutating func u32(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) } }
    mutating func u64(_ v: UInt64) { for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func vector(_ v: SpatialVector) { f32(Float(v.x)); f32(Float(v.y)); f32(Float(v.z)) }
    mutating func quaternion(_ q: SpatialQuaternion) { f32(Float(q.x)); f32(Float(q.y)); f32(Float(q.z)); f32(Float(q.w)) }
}

struct ByteReader {
    let bytes: ArraySlice<UInt8>
    var at: Int
    init(_ bytes: ArraySlice<UInt8>) { self.bytes = bytes; at = bytes.startIndex }
    var remaining: Int { bytes.endIndex - at }
    mutating func need(_ n: Int, _ what: String) throws { if remaining < n { throw DisplayStreamError.truncated(what) } }
    mutating func u8(_ what: String) throws -> UInt8 { try need(1, what); defer { at += 1 }; return bytes[at] }
    mutating func u16(_ what: String) throws -> UInt16 {
        try need(2, what); defer { at += 2 }
        return UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }
    mutating func u32(_ what: String) throws -> UInt32 {
        try need(4, what); defer { at += 4 }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[at + i]) << (8 * UInt32(i)) }
        return v
    }
    mutating func u64(_ what: String) throws -> UInt64 {
        try need(8, what); defer { at += 8 }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[at + i]) << (8 * UInt64(i)) }
        return v
    }
    mutating func f32(_ what: String) throws -> Float { Float(bitPattern: try u32(what)) }
    mutating func vector(_ what: String) throws -> SpatialVector {
        SpatialVector(Double(try f32(what)), Double(try f32(what)), Double(try f32(what)))
    }
    mutating func quaternion(_ what: String) throws -> SpatialQuaternion {
        SpatialQuaternion(x: Double(try f32(what)), y: Double(try f32(what)), z: Double(try f32(what)), w: Double(try f32(what)))
    }
    mutating func take(_ n: Int, _ what: String) throws -> [UInt8] {
        try need(n, what); defer { at += n }
        return Array(bytes[at..<(at + n)])
    }
    mutating func rest() -> [UInt8] { defer { at = bytes.endIndex }; return Array(bytes[at...]) }
}

extension DisplayMessage {
    public var type: DisplayMessageType {
        switch self {
        case .hello: .hello
        case .status: .status
        case .frame: .frame
        case .pong: .pong
        case .screenshot: .screenshot
        case .notice: .notice
        case .displayState: .displayState
        case .commandReply: .commandReply
        case .frameTiming: .frameTiming
        case .audio: .audio
        case .frameView: .frameView
        case .inset: .inset
        case .frameDepth: .frameDepth
        case .environment: .environment
        case .command: .command
        case .clientHello: .clientHello
        case .input(.touch): .touch
        case .input(.key): .key
        case .input(.button): .button
        case .input(.pose): .pose
        case .input(.selection): .selection
        case .input(.dial): .dial
        case .input(.views): .views
        case .input(.fovea): .fovea
        case .ping: .ping
        case .keyframeRequest: .keyframeRequest
        case .frameAck: .frameAck
        case .screenshotRequest: .screenshotRequest
        case .rotate: .rotate
        case .fold: .fold
        }
    }

    /// The message with its frame header: u32 length (type + payload), u8 type, payload.
    public func encoded() -> [UInt8] {
        var w = ByteWriter()
        func json<T: Encodable>(_ v: T) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            w.bytes += Array((try? encoder.encode(v)) ?? Data("{}".utf8))
        }
        switch self {
        case .hello(let h): json(h)
        case .status(let s): json(s)
        case .displayState(let d): json(d)
        case .clientHello(let h): json(h)
        case .frame(let f):
            w.u64(f.sequence)
            w.u64(f.guestFrame)
            w.u64(f.serverNanoseconds)
            w.u32(f.inputSequence)
            w.u16(UInt16(clamping: f.width))
            w.u16(UInt16(clamping: f.height))
            w.u8(f.encoding.rawValue)
            w.u8(f.isFull ? 1 : 0)
            w.u16(UInt16(clamping: f.tiles.count))
            for t in f.tiles {
                w.u16(UInt16(clamping: t.x))
                w.u16(UInt16(clamping: t.y))
                w.u16(UInt16(clamping: t.width))
                w.u16(UInt16(clamping: t.height))
                w.u32(UInt32(t.data.count))
                w.bytes += t.data
            }
        case .pong(let token, let ns):
            w.u64(token)
            w.u64(ns)
        case .frameTiming(let t):
            for v in [t.sequence, t.recordSeen, t.captureStart, t.encodeEnd, t.sendEnd] { w.u64(v) }
        case .audio(let a):
            w.u64(a.playTime)
            w.u8(a.codec.rawValue)
            w.u8(UInt8(clamping: a.channels))
            w.u16(UInt16(clamping: a.frames))
            w.u32(UInt32(clamping: a.sampleRate))
            w.bytes += a.data
        case .screenshot(let token, let png):
            w.u32(token)
            w.bytes += png
        case .notice(let text): w.bytes += Array(text.utf8)
        case .input(.touch(let seq, let contacts)):
            w.u32(seq)
            w.u8(UInt8(clamping: contacts.count))
            for c in contacts.prefix(255) {
                w.u8(c.finger)
                w.u8(c.phase.rawValue)
                w.u16(0)
                w.f32(c.x)
                w.f32(c.y)
            }
        case .input(.key(let seq, let down, let page, let usage)):
            w.u32(seq)
            w.u8(down ? 1 : 0)
            w.u8(0)
            w.u16(page)
            w.u16(usage)
        case .input(.button(let seq, let button, let down)):
            w.u32(seq)
            w.u8(button.rawValue)
            w.u8(down ? 1 : 0)
        case .input(.pose(let seq, let pose)):
            w.u32(seq)
            w.vector(pose.position)
            w.quaternion(pose.rotation)
        case .input(.selection(let seq, let s)):
            w.u32(seq)
            w.u8(s.hasHands ? 1 : 0)
            w.u8(0)
            w.u16(0)
            w.vector(s.rayOrigin)
            w.vector(s.rayDirection)
            if s.hasHands, let l = s.left, let r = s.right {
                for h in [l, r] {
                    w.u8(h.pinching ? 1 : 0)
                    w.u8(h.allowDirect ? 1 : 0)
                    w.u16(0)
                    w.vector(h.position)
                    w.quaternion(h.rotation)
                }
            }
        case .input(.dial(let seq, let delta)):
            w.u32(seq)
            w.f32(Float(delta.isFinite ? delta : 0))
        case .input(.views(let seq, let v)):
            w.u32(seq)
            w.u8(v.stereo ? 1 : 0)
            w.u8(0)
            w.u16(0)
            for p in [v.head, v.left, v.right] {
                w.vector(p.position)
                w.quaternion(p.rotation)
            }
        case .input(.fovea(let seq, let u, let v)):
            w.u32(seq)
            w.f32(u)
            w.f32(v)
        case .inset(let i):
            w.u64(i.frameSequence)
            w.u8(i.view.rawValue)
            w.u8(i.encoding.rawValue)
            w.u16(UInt16(clamping: i.x))
            w.u16(UInt16(clamping: i.y))
            w.u16(UInt16(clamping: i.width))
            w.u16(UInt16(clamping: i.height))
            w.u16(UInt16(clamping: i.fullWidth))
            w.u16(UInt16(clamping: i.fullHeight))
            w.bytes += i.data
        case .frameView(let f):
            w.u64(f.frameSequence)
            w.u8(f.view.rawValue)
            w.u8(f.estimated ? 1 : 0)
            w.u16(f.latch)
            w.u32(f.poseSequence)
            w.vector(f.pose.position)
            w.quaternion(f.pose.rotation)
            let t = f.fov.tangents
            for v in [t.left, t.right, t.up, t.down] { w.f32(Float(v)) }
            w.u64(f.guestFrame)
        case .frameDepth(let d):
            w.bytes += d.payload()
        case .environment(let e):
            w.bytes += e.payload()
        case .ping(let token): w.u64(token)
        case .keyframeRequest: break
        case .frameAck(let sequence): w.u64(sequence)
        case .screenshotRequest(let token): w.u32(token)
        case .rotate(let o): w.u8(o)
        case .fold(let angle, let instant):
            w.u16(angle)
            w.u8(instant ? 1 : 0)
        case .command(let token, let text), .commandReply(let token, let text):
            w.u32(token)
            w.bytes += Array(text.utf8)
        }
        var out = ByteWriter()
        out.u32(UInt32(w.bytes.count + 1))
        out.u8(type.rawValue)
        out.bytes += w.bytes
        return out.bytes
    }

    /// Decodes one message body (type byte and payload, without the length).
    public static func decode(type rawType: UInt8, payload: ArraySlice<UInt8>) throws -> DisplayMessage {
        guard let type = DisplayMessageType(rawValue: rawType) else { throw DisplayStreamError.unknownType(rawType) }
        var r = ByteReader(payload)
        func json<T: Decodable>(_: T.Type) throws -> T {
            do { return try JSONDecoder().decode(T.self, from: Data(payload)) } catch { throw DisplayStreamError.badJSON("\(type): \(error)") }
        }
        switch type {
        case .hello: return .hello(try json(DisplayServerHello.self))
        case .status: return .status(try json(DisplayStatus.self))
        case .displayState: return .displayState(try json(DisplayPanelState.self))
        case .clientHello: return .clientHello(try json(DisplayClientHello.self))
        case .frame:
            let seq = try r.u64("frame"), guest = try r.u64("frame"), ns = try r.u64("frame"), input = try r.u32("frame")
            let w = Int(try r.u16("frame")), h = Int(try r.u16("frame"))
            let encRaw = try r.u8("frame")
            guard let enc = DisplayEncoding(rawValue: encRaw) else { throw DisplayStreamError.truncated("encoding \(encRaw)") }
            let full = try r.u8("frame") & 1 != 0
            let count = Int(try r.u16("frame"))
            var tiles: [DisplayTile] = []
            tiles.reserveCapacity(count)
            for _ in 0..<count {
                let x = Int(try r.u16("tile")), y = Int(try r.u16("tile"))
                let tw = Int(try r.u16("tile")), th = Int(try r.u16("tile"))
                let n = Int(try r.u32("tile"))
                tiles.append(DisplayTile(x: x, y: y, width: tw, height: th, data: try r.take(n, "tile data")))
            }
            return .frame(DisplayFrame(sequence: seq, guestFrame: guest, serverNanoseconds: ns, inputSequence: input,
                                       width: w, height: h, encoding: enc, isFull: full, tiles: tiles))
        case .pong: return .pong(token: try r.u64("pong"), serverNanoseconds: try r.u64("pong"))
        case .audio:
            let t = try r.u64("audio")
            let c = try r.u8("audio")
            guard let codec = DisplayAudio.Codec(rawValue: c) else { throw DisplayStreamError.truncated("audio codec \(c)") }
            let ch = Int(try r.u8("audio")), frames = Int(try r.u16("audio")), rate = Int(try r.u32("audio"))
            return .audio(DisplayAudio(playTime: t, codec: codec, channels: ch, frames: frames, sampleRate: rate, data: r.rest()))
        case .frameTiming:
            return .frameTiming(DisplayFrameTiming(sequence: try r.u64("timing"), recordSeen: try r.u64("timing"), captureStart: try r.u64("timing"),
                                                   encodeEnd: try r.u64("timing"), sendEnd: try r.u64("timing")))
        case .screenshot: return .screenshot(token: try r.u32("screenshot"), png: r.rest())
        case .notice: return .notice(String(decoding: payload, as: UTF8.self))
        case .touch:
            let seq = try r.u32("touch")
            let n = Int(try r.u8("touch"))
            var contacts: [TouchContact] = []
            for _ in 0..<n {
                let finger = try r.u8("contact")
                let phaseRaw = try r.u8("contact")
                _ = try r.u16("contact")
                let x = try r.f32("contact"), y = try r.f32("contact")
                contacts.append(TouchContact(finger: finger, phase: TouchPhase(rawValue: phaseRaw) ?? .cancelled, x: x, y: y))
            }
            return .input(.touch(sequence: seq, contacts: contacts))
        case .key:
            let seq = try r.u32("key")
            let down = try r.u8("key") != 0
            _ = try r.u8("key")
            return .input(.key(sequence: seq, down: down, usagePage: try r.u16("key"), usage: try r.u16("key")))
        case .button:
            let seq = try r.u32("button")
            let raw = try r.u8("button")
            guard let b = DisplayButton(rawValue: raw) else { throw DisplayStreamError.truncated("button \(raw)") }
            return .input(.button(sequence: seq, button: b, down: try r.u8("button") != 0))
        case .pose:
            let seq = try r.u32("pose")
            return .input(.pose(sequence: seq, pose: SpatialPose(position: try r.vector("pose"), rotation: try r.quaternion("pose"))))
        case .selection:
            let seq = try r.u32("selection")
            let flags = try r.u8("selection")
            _ = try r.u8("selection")
            _ = try r.u16("selection")
            var s = SpatialSelection(rayOrigin: try r.vector("selection"), rayDirection: try r.vector("selection"))
            if flags & 1 != 0 {
                var hands: [SpatialHand] = []
                for _ in 0..<2 {
                    let pinch = try r.u8("hand") != 0, direct = try r.u8("hand") != 0
                    _ = try r.u16("hand")
                    hands.append(SpatialHand(pinching: pinch, allowDirect: direct, position: try r.vector("hand"), rotation: try r.quaternion("hand")))
                }
                (s.left, s.right) = (hands[0], hands[1])
            }
            return .input(.selection(sequence: seq, selection: s))
        case .dial:
            let seq = try r.u32("dial")
            return .input(.dial(sequence: seq, delta: Double(try r.f32("dial"))))
        case .views:
            let seq = try r.u32("views")
            let flags = try r.u8("views")
            _ = try r.u8("views")
            _ = try r.u16("views")
            var p: [SpatialPose] = []
            for _ in 0..<3 { p.append(SpatialPose(position: try r.vector("views"), rotation: try r.quaternion("views"))) }
            return .input(.views(sequence: seq, views: XRViews(sequence: seq, stereo: flags & 1 != 0, head: p[0], left: p[1], right: p[2])))
        case .fovea:
            let seq = try r.u32("fovea")
            return .input(.fovea(sequence: seq, u: try r.f32("fovea"), v: try r.f32("fovea")))
        case .inset:
            let seq = try r.u64("inset")
            let rawView = try r.u8("inset"), rawEnc = try r.u8("inset")
            guard let view = XRView(rawValue: rawView), let enc = DisplayEncoding(rawValue: rawEnc) else { throw DisplayStreamError.truncated("inset") }
            let x = Int(try r.u16("inset")), y = Int(try r.u16("inset")), w = Int(try r.u16("inset")), h = Int(try r.u16("inset"))
            let fw = Int(try r.u16("inset")), fh = Int(try r.u16("inset"))
            return .inset(XRInset(frameSequence: seq, view: view, encoding: enc, x: x, y: y, width: w, height: h, fullWidth: fw, fullHeight: fh, data: r.rest()))
        case .frameView:
            let seq = try r.u64("frame view")
            let raw = try r.u8("frame view")
            guard let view = XRView(rawValue: raw) else { throw DisplayStreamError.truncated("view \(raw)") }
            let flags = try r.u8("frame view")
            let latch = try r.u16("frame view")
            let poseSeq = try r.u32("frame view")
            let pose = SpatialPose(position: try r.vector("frame view"), rotation: try r.quaternion("frame view"))
            let t = (try r.f32("fov"), try r.f32("fov"), try r.f32("fov"), try r.f32("fov"))
            let fov = XRFieldOfView(tangentLeft: Double(t.0), right: Double(t.1), up: Double(t.2), down: Double(t.3))
            return .frameView(XRFrameView(frameSequence: seq, view: view, estimated: flags & 1 != 0, latch: latch, poseSequence: poseSeq,
                                          pose: pose, fov: fov, guestFrame: try r.u64("frame view")))
        case .frameDepth:
            guard let d = XRFrameDepth(payload: Array(payload)) else { throw DisplayStreamError.truncated("frame depth") }
            return .frameDepth(d)
        case .environment:
            guard let e = XREnvironment(payload: Array(payload)) else { throw DisplayStreamError.truncated("environment") }
            return .environment(e)
        case .ping: return .ping(token: try r.u64("ping"))
        case .keyframeRequest: return .keyframeRequest
        case .frameAck: return .frameAck(sequence: try r.u64("frame ack"))
        case .screenshotRequest: return .screenshotRequest(token: try r.u32("screenshot request"))
        case .rotate: return .rotate(orientation: try r.u8("rotate"))
        case .fold:
            let angle = try r.u16("fold")
            return .fold(angle: angle, instant: try r.u8("fold") & 1 != 0)
        case .command:
            let token = try r.u32("command")
            return .command(token: token, text: String(decoding: r.rest(), as: UTF8.self))
        case .commandReply:
            let token = try r.u32("command reply")
            return .commandReply(token: token, text: String(decoding: r.rest(), as: UTF8.self))
        }
    }
}

/// Splits a byte stream into messages (§2).
public struct DisplayMessageParser: Sendable {
    private var buffer: [UInt8] = []
    private var start = 0

    public init() {}

    public mutating func append(_ bytes: UnsafeRawBufferPointer) { buffer.append(contentsOf: bytes) }
    public mutating func append(_ bytes: [UInt8]) { buffer += bytes }

    /// The next complete message, nil when more bytes are needed. Unknown
    /// message types are skipped (forward compatibility, §2).
    public mutating func next() throws -> DisplayMessage? {
        while true {
            let available = buffer.count - start
            guard available >= 4 else { compact(); return nil }
            var n = 0
            for i in 0..<4 { n |= Int(buffer[start + i]) << (8 * i) }
            guard n >= 1, n <= DisplayStream.maxMessageSize else { throw DisplayStreamError.tooLarge(n) }
            guard available >= 4 + n else { compact(); return nil }
            let type = buffer[start + 4]
            let payload = buffer[(start + 5)..<(start + 4 + n)]
            start += 4 + n
            if DisplayMessageType(rawValue: type) == nil { continue }
            return try DisplayMessage.decode(type: type, payload: payload)
        }
    }

    private mutating func compact() {
        if start > 0 && (start >= 1 << 20 || start == buffer.count) {
            buffer.removeFirst(start)
            start = 0
        }
    }
}
