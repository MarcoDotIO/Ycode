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

    case clientHello = 0x81
    case touch = 0x82
    case key = 0x83
    case button = 0x84
    case ping = 0x85
    case keyframeRequest = 0x86
    case screenshotRequest = 0x87
    case rotate = 0x88
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

    public init(deviceName: String, model: String, pixelWidth: Int, pixelHeight: Int, scale: Double,
                orientation: String = "portrait", encodings: [String], touch: Bool, keyboard: Bool,
                buttons: [String], rotation: Bool) {
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

/// The client's hello (§3.2): how it wants frames.
public struct DisplayClientHello: Codable, Sendable, Equatable {
    public var `protocol`: String = DisplayStream.protocolName
    public var client: String
    /// Frames per second at most (1...120).
    public var maxFPS: Int
    /// "jpeg" or "zlib" (lossless BGRA).
    public var encoding: String
    /// JPEG quality (1...100).
    public var quality: Int
    /// Integer downscale of the device pixels (1...4).
    public var downscale: Int

    public init(client: String, maxFPS: Int = 60, encoding: String = "jpeg", quality: Int = 75, downscale: Int = 1) {
        self.client = client
        self.maxFPS = maxFPS
        self.encoding = encoding
        self.quality = quality
        self.downscale = downscale
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

    public init?(name: String) {
        switch name {
        case "jpeg": self = .jpeg
        case "zlib": self = .zlibBGRA
        default: return nil
        }
    }

    public var name: String { self == .jpeg ? "jpeg" : "zlib" }
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

    public var name: String {
        switch self {
        case .home: "home"
        case .lock: "lock"
        case .volumeUp: "volumeUp"
        case .volumeDown: "volumeDown"
        case .side: "side"
        }
    }
}

/// A client → server input event (§5).
public enum DisplayInput: Sendable, Equatable {
    case touch(sequence: UInt32, contacts: [TouchContact])
    /// A keyboard key: HID usage page (7 = keyboard) and usage.
    case key(sequence: UInt32, down: Bool, usagePage: UInt16, usage: UInt16)
    case button(sequence: UInt32, button: DisplayButton, down: Bool)

    public var sequence: UInt32 {
        switch self {
        case .touch(let s, _), .key(let s, _, _, _), .button(let s, _, _): s
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

    case clientHello(DisplayClientHello)
    case input(DisplayInput)
    case ping(token: UInt64)
    case keyframeRequest
    case screenshotRequest(token: UInt32)
    /// 1 portrait, 2 upside down, 3 landscape left, 4 landscape right.
    case rotate(orientation: UInt8)
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
        case .clientHello: .clientHello
        case .input(.touch): .touch
        case .input(.key): .key
        case .input(.button): .button
        case .ping: .ping
        case .keyframeRequest: .keyframeRequest
        case .screenshotRequest: .screenshotRequest
        case .rotate: .rotate
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
        case .ping(let token): w.u64(token)
        case .keyframeRequest: break
        case .screenshotRequest(let token): w.u32(token)
        case .rotate(let o): w.u8(o)
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
        case .ping: return .ping(token: try r.u64("ping"))
        case .keyframeRequest: return .keyframeRequest
        case .screenshotRequest: return .screenshotRequest(token: try r.u32("screenshot request"))
        case .rotate: return .rotate(orientation: try r.u8("rotate"))
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
