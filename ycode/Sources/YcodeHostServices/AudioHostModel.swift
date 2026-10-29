// The object model of Ycode's host audio service (specs/simulator/
// audio-host.md §4–§9, "Ycode implementation"): the system object, one
// 48 kHz stereo Float32 output device with one stream, IO contexts and the
// private aggregate devices clients create, and the property answers the
// clients' CoreAudio asks for. Selector, scope and class codes and the
// record layouts (AudioStreamBasicDescription, AudioChannelLayout,
// AudioTimeStamp) are the public CoreAudio ones (level 1). Pure logic: the
// Mach side is AudioHostService.swift.

import Foundation

/// A four-character code as CoreAudio uses it: the first character is the
/// most significant byte.
public func fourCC(_ s: String) -> UInt32 {
    var v: UInt32 = 0
    for b in s.utf8.prefix(4) { v = v << 8 | UInt32(b) }
    return v
}

/// The text of a four-character code (logs).
public func fourCCText(_ v: UInt32) -> String {
    let bytes = [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) { return "'" + String(decoding: bytes, as: UTF8.self) + "'" }
    return "0x" + String(v, radix: 16)
}

/// A property address: selector, scope, element.
public struct AudioPropertyAddress: Hashable, Sendable, CustomStringConvertible {
    public var selector: UInt32
    public var scope: UInt32
    public var element: UInt32
    public init(_ selector: UInt32, _ scope: UInt32 = AudioHAL.scopeGlobal, _ element: UInt32 = 0) {
        self.selector = selector
        self.scope = scope
        self.element = element
    }
    public init(_ selector: String, _ scope: UInt32 = AudioHAL.scopeGlobal, _ element: UInt32 = 0) {
        self.init(fourCC(selector), scope, element)
    }
    public var description: String { "\(fourCCText(selector))/\(fourCCText(scope))/\(element)" }
}

/// A property value, in the form the model keeps it. Each "get" message
/// asks for one form (`AudioHostService`); message 15 takes any as bytes.
public enum AudioValue: Equatable, Sendable {
    case u32(UInt32)
    case f32(Float)
    case f64(Double)
    case u32s([UInt32])
    case f64s([Double])
    case string(String)
    /// An XML property list's text.
    case plist([UInt8])
    case bytes([UInt8])

    /// The value's raw little-endian bytes (message 15).
    public var rawBytes: [UInt8] {
        switch self {
        case let .u32(v): return AudioHAL.le32(v)
        case let .f32(v): return AudioHAL.le32(v.bitPattern)
        case let .f64(v): return AudioHAL.le64(v.bitPattern)
        case let .u32s(a): return a.flatMap(AudioHAL.le32)
        case let .f64s(a): return a.flatMap { AudioHAL.le64($0.bitPattern) }
        case let .string(s): return Array(s.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        case let .plist(b), let .bytes(b): return b
        }
    }
}

/// CoreAudio constants and records (public headers `AudioHardware.h`,
/// `AudioHardwareBase.h`, `CoreAudioTypes.h`; level 1).
public enum AudioHAL {
    /// Property scopes (`kAudioObjectPropertyScope*`).
    public static let scopeGlobal = fourCC("glob"), scopeInput = fourCC("inpt"), scopeOutput = fourCC("outp")
    /// Wildcards in a property address (`kAudioObjectPropertyScopeWildcard`,
    /// `kAudioObjectPropertySelectorWildcard`).
    public static let scopeWildcard = fourCC("****"), selectorWildcard = fourCC("****")
    /// `kAudioObjectPropertyElementWildcard`.
    public static let elementWildcard: UInt32 = 0xFFFF_FFFF

    /// Object class codes (`kAudio*ClassID`), answered by message 2
    /// (audio-host.md §4).
    public static let classSystem = fourCC("asys"), classObject = fourCC("aobj"), classDevice = fourCC("adev")
    /// Aggregate, subdevice and stream class codes.
    public static let classAggregate = fourCC("aagg"), classSubdevice = fourCC("asub"), classStream = fourCC("astr")
    /// The IO context class code.
    public static let classIOContext = fourCC("ioct")

    /// Status codes: kAudioHardwareUnknownPropertyError 'who?',
    /// kAudioHardwareBadObjectError '!obj', kAudioHardwareIllegalOperationError
    /// 'nope', kAudioHardwareUnsupportedOperationError 'unop',
    /// kAudioHardwareBadPropertySizeError '!siz'.
    public static let unknownProperty = fourCC("who?"), badObject = fourCC("!obj"), illegalOperation = fourCC("nope")
    /// See the status codes above.
    public static let unsupported = fourCC("unop"), badSize = fourCC("!siz")

    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
    static func le64(_ v: UInt64) -> [UInt8] { le32(UInt32(v & 0xFFFF_FFFF)) + le32(UInt32(v >> 32)) }

    /// An AudioStreamBasicDescription (40 bytes): linear PCM, Float32,
    /// packed, interleaved (flags 9).
    public static func streamFormat(sampleRate: Double, channels: UInt32) -> [UInt8] {
        let bytesPerFrame = 4 * channels
        return le64(sampleRate.bitPattern) + le32(fourCC("lpcm")) + le32(9) + le32(bytesPerFrame) + le32(1)
            + le32(bytesPerFrame) + le32(channels) + le32(32) + le32(0)
    }

    /// An AudioChannelLayout with one description per channel (tag 0 =
    /// kAudioChannelLayoutTag_UseChannelDescriptions, bitmap 0), labels as
    /// given, zero flags and coordinates: 12 + 20 × n bytes.
    public static func channelLayout(labels: [UInt32]) -> [UInt8] {
        var b = le32(0) + le32(0) + le32(UInt32(labels.count))
        for l in labels { b += le32(l) + le32(0) + [UInt8](repeating: 0, count: 12) }
        return b
    }

    /// One 56-byte `'grid'` record (audio-host.md §6).
    public static func gridRecord(device: UInt32, input: Bool, sampleRate: Double, channels: UInt32) -> [UInt8] {
        le32(device) + le32(input ? 1 : 0) + le32(1) + le32(0) + streamFormat(sampleRate: sampleRate, channels: channels)
    }

    /// An XML property list's bytes.
    static func xml(_ object: Any) -> [UInt8] {
        let data = (try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)) ?? Data()
        return [UInt8](data)
    }
}

/// The objects and properties (audio-host.md §9 and "Ycode implementation").
/// Not thread-safe: the service serializes access.
public final class AudioObjectModel {
    /// The system object's ID (audio-host.md §13.3).
    public static let systemID: UInt32 = 1
    /// The output device's ID.
    public static let deviceID: UInt32 = 32
    /// The output device's one stream.
    public static let streamID: UInt32 = 33
    /// The output device's `'uid '`, also written into the guest's audio
    /// settings files (audio-host.md §13.5).
    public static let deviceUID = "dev.ycode.simulator.audio.output"
    /// The output device's `'lnam'`.
    public static let deviceName = "Ycode Simulator Output"
    /// The output device's `'lmak'`.
    public static let manufacturer = "Ycode"
    /// The device's nominal sample rate, in Hz.
    public static let sampleRate = 48_000.0
    /// Output channels (stereo, interleaved).
    public static let channels: UInt32 = 2
    /// The IO buffer size in frames, and the range a client may set.
    public static let bufferFrames: UInt32 = 512
    /// The range a client may set for an IO context's `'fsiz'`, in frames.
    public static let minimumFrames: UInt32 = 14, maximumFrames: UInt32 = 1024
    /// kAudioDeviceTransportTypeBuiltIn (audio-host.md §9 leaves the
    /// choice open; Q4).
    public static let transport = fourCC("bltn")

    /// An aggregate device made by message 5 (audio-host.md §7).
    public struct Aggregate: Equatable {
        public var id: UInt32
        public var streamID: UInt32
        public var subdeviceID: UInt32
        public var uid: String
        public var name: String
        public var creatorPID: Int32
        /// `'acom'`: the creation dictionary with the subdevice entries extended.
        public var composition: [UInt8]
        public var preferredStereo: [UInt32] = [1, 2]
        public var layout: [UInt8] = AudioHAL.channelLayout(labels: [1, 2])
    }

    /// An IO context made by message 3.
    public struct IOContext: Equatable {
        public var id: UInt32
        /// The device or aggregate it runs.
        public var deviceID: UInt32
        public var creatorPID: Int32
        public var bufferFrames: UInt32 = AudioObjectModel.bufferFrames
        /// `'guse'` per scope.
        public var streamUsage: [UInt32: [UInt32]] = [:]
    }

    /// The aggregate devices clients made, by ID.
    public private(set) var aggregates: [UInt32: Aggregate] = [:]
    /// The IO contexts clients made, by ID.
    public private(set) var contexts: [UInt32: IOContext] = [:]
    /// The next ID for a new object.
    public private(set) var nextID: UInt32 = 0x100
    /// The system object's `'powh'`, as a client last set it.
    public private(set) var powerHint: UInt32 = 0
    /// `'appv'` of the output device (the clients set the settings
    /// file's volume, 0.6).
    public private(set) var volume: Float = 1

    /// A model with only the fixed objects (system, device, stream).
    public init() {}

    // MARK: Objects

    /// What an object ID names; a stream or subdevice carries its owner.
    public enum Kind: Equatable {
        case system, device, stream(owner: UInt32), aggregate, subdevice(owner: UInt32), ioContext
    }

    /// The kind of object `id` names, or nil for an unknown ID.
    public func kind(of id: UInt32) -> Kind? {
        switch id {
        case Self.systemID: return .system
        case Self.deviceID: return .device
        case Self.streamID: return .stream(owner: Self.deviceID)
        default:
            if aggregates[id] != nil { return .aggregate }
            if contexts[id] != nil { return .ioContext }
            for a in aggregates.values {
                if a.streamID == id { return .stream(owner: a.id) }
                if a.subdeviceID == id { return .subdevice(owner: a.id) }
            }
            return nil
        }
    }

    /// Class and base class (message 2).
    public func classes(of id: UInt32) -> (UInt32, UInt32)? {
        switch kind(of: id) {
        case .system: return (AudioHAL.classSystem, AudioHAL.classObject)
        case .device: return (AudioHAL.classDevice, AudioHAL.classObject)
        case .stream: return (AudioHAL.classStream, AudioHAL.classObject)
        case .aggregate: return (AudioHAL.classAggregate, AudioHAL.classDevice)
        case .subdevice: return (AudioHAL.classSubdevice, AudioHAL.classDevice)
        case .ioContext: return (AudioHAL.classIOContext, AudioHAL.classObject)
        case nil: return nil
        }
    }

    /// The system's device list for `pid`: the output device and the
    /// aggregates that process made (they are private).
    public func deviceList(for pid: Int32) -> [UInt32] {
        [Self.deviceID] + aggregates.values.filter { $0.creatorPID == pid }.map(\.id).sorted()
    }

    private func allocateID() -> UInt32 {
        defer { nextID += 1 }
        return nextID
    }

    // MARK: Property answers

    /// The value of a property, or nil when the object does not have it
    /// ("has property" then answers 0). `qualifier` is message 15's or
    /// 20's qualifier data.
    public func value(_ id: UInt32, _ a: AudioPropertyAddress, pid: Int32, qualifier: [UInt8] = []) -> AudioValue? {
        guard let kind = kind(of: id) else { return nil }
        let sel = a.selector
        let output = a.scope == AudioHAL.scopeOutput, input = a.scope == AudioHAL.scopeInput
        switch (kind, sel) {
        // Every object.
        case (_, fourCC("clas")): return classes(of: id).map { .u32($0.0) }
        case (_, fourCC("bcls")): return classes(of: id).map { .u32($0.1) }
        case (.system, fourCC("ownr")): return .u32(0)
        case (.device, fourCC("ownr")), (.aggregate, fourCC("ownr")), (.ioContext, fourCC("ownr")): return .u32(Self.systemID)
        case (let .stream(owner), fourCC("ownr")), (let .subdevice(owner), fourCC("ownr")): return .u32(owner)
        // Custom-property lists: empty where the reference device had one
        // (has = 1), absent on streams and IO contexts (audio-host.md §5).
        case (.system, fourCC("cust")), (.device, fourCC("cust")), (.aggregate, fourCC("cust")),
             (.subdevice, fourCC("cust")):
            return .u32s([])

        // The system object.
        case (.system, fourCC("vers")): return .u32(1)
        case (.system, fourCC("mlkf")): return .u32(2)
        case (.system, fourCC("powh")): return .u32(powerHint)
        case (.system, fourCC("plg#")), (.system, fourCC("box#")), (.system, fourCC("clk#")), (.system, fourCC("tps#")),
             (.system, fourCC("prs#")):
            return .u32s([])
        case (.system, fourCC("dev#")): return .u32s(deviceList(for: pid))
        case (.system, fourCC("dOut")), (.system, fourCC("sOut")): return .u32(Self.deviceID)
        case (.system, fourCC("dIn ")): return .u32(0)
        case (.system, fourCC("ownd")): return .u32s(deviceList(for: pid))

        // The output device and the aggregates (shared answers).
        case (.device, _), (.aggregate, _):
            return deviceValue(id, kind, a, output: output, input: input, qualifier: qualifier)

        // Streams.
        case (.stream, fourCC("sdir")): return .u32(0)
        case (.stream, fourCC("schn")): return .u32(1)
        case (.stream, fourCC("ltnc")): return .u32(0)
        case (.stream, fourCC("sact")): return .u32(1)
        case (.stream, fourCC("term")): return .u32(fourCC("spkr"))
        case (.stream, fourCC("sfmt")), (.stream, fourCC("pft ")):
            return .bytes(AudioHAL.streamFormat(sampleRate: Self.sampleRate, channels: Self.channels))

        // An aggregate's subdevice.
        case (let .subdevice(owner), fourCC("uid ")):
            return aggregates[owner].map { _ in .string(Self.deviceUID) }
        case (.subdevice, fourCC("lnam")): return .string(Self.deviceName)
        case (.subdevice, fourCC("xltn")): return .f64(0)
        case (.subdevice, fourCC("drft")): return .u32(1)
        case (.subdevice, fourCC("drfq")): return .u32(127)

        // IO contexts.
        case (.ioContext, fourCC("grid")):
            guard let c = contexts[id] else { return nil }
            if input { return .bytes([]) }
            guard output || a.scope == AudioHAL.scopeGlobal else { return nil }
            return .bytes(AudioHAL.gridRecord(device: c.deviceID, input: false, sampleRate: Self.sampleRate, channels: Self.channels))
        case (.ioContext, fourCC("fsiz")): return contexts[id].map { .u32($0.bufferFrames) }
        case (.ioContext, fourCC("fsz#")): return .f64s([Double(Self.minimumFrames), Double(Self.maximumFrames)])
        case (.ioContext, fourCC("guse")):
            guard let c = contexts[id] else { return nil }
            if let u = c.streamUsage[a.scope] { return .u32s(u) }
            return .u32s(output ? [1] : [])
        default:
            return nil
        }
    }

    private func deviceValue(_ id: UInt32, _ kind: Kind, _ a: AudioPropertyAddress, output: Bool, input: Bool,
                             qualifier: [UInt8]) -> AudioValue? {
        let isAggregate = kind == .aggregate
        let agg = aggregates[id]
        switch a.selector {
        case fourCC("uid "): return .string(agg?.uid ?? Self.deviceUID)
        case fourCC("lnam"): return .string(agg?.name ?? Self.deviceName)
        case fourCC("lmak"): return .string(Self.manufacturer)
        case fourCC("tran"): return .u32(isAggregate ? fourCC("grup") : Self.transport)
        case fourCC("alv?"): return .u32(1)
        case fourCC("hidn"): return .u32(0)
        case fourCC("dflt"), fourCC("sflt"): return isAggregate || input ? .u32(0) : .u32(1)
        case fourCC("nsrt"): return .f64(Self.sampleRate)
        case fourCC("nsra"): return .f64s([Self.sampleRate, Self.sampleRate])
        case fourCC("ltnc"), fourCC("saft"): return .u32(0)
        case fourCC("fsiz"): return .u32(Self.bufferFrames)
        case fourCC("fsz#"): return .f64s([Double(Self.minimumFrames), Double(Self.maximumFrames)])
        case fourCC("ctrl"): return .u32s([])
        case fourCC("stm#"):
            let stream = agg?.streamID ?? Self.streamID
            return input ? .u32s([]) : .u32s([stream])
        case fourCC("ownd"):
            // Owned objects of the classes the qualifier lists (all when empty).
            let classes = stride(from: 0, to: qualifier.count - qualifier.count % 4, by: 4).map { i in
                UInt32(qualifier[i]) | UInt32(qualifier[i + 1]) << 8 | UInt32(qualifier[i + 2]) << 16 | UInt32(qualifier[i + 3]) << 24
            }
            if let agg {
                // audio-host.md §5: an empty qualifier gives the subdevice.
                if classes.isEmpty { return .u32s([agg.subdeviceID]) }
                var out: [UInt32] = []
                if classes.contains(where: { [AudioHAL.classSubdevice, AudioHAL.classDevice, AudioHAL.classObject].contains($0) }) {
                    out.append(agg.subdeviceID)
                }
                if classes.contains(where: { [AudioHAL.classStream, AudioHAL.classObject].contains($0) }) { out.append(agg.streamID) }
                return .u32s(out)
            }
            if classes.isEmpty || classes.contains(AudioHAL.classStream) || classes.contains(AudioHAL.classObject) {
                return .u32s([Self.streamID])
            }
            return .u32s([])
        case fourCC("ioct"): return .plist(ioContextDescription(id))
        case fourCC("dch2"):
            guard output else { return nil }
            return .u32s(agg?.preferredStereo ?? [1, 2])
        case fourCC("srnd"):
            guard output else { return nil }
            return .bytes(agg?.layout ?? AudioHAL.channelLayout(labels: [1, 2]))
        case fourCC("appv"):
            guard output, !isAggregate else { return nil }
            return .f32(volume)
        case fourCC("acom"):
            return agg.map { .plist($0.composition) }
        case fourCC("agrp"):
            return isAggregate ? .u32s([Self.deviceID]) : nil
        default:
            return nil
        }
    }

    /// `'ioct'` of a device (audio-host.md §6): the IO-context description
    /// the client sends back with message 3.
    public func ioContextDescription(_ id: UInt32) -> [UInt8] {
        let agg = aggregates[id]
        var entry: [String: Any] = ["index": 0, "uid": Self.deviceUID]
        if agg != nil {
            entry["drift"] = true
            entry["drift algorithm"] = 0
            entry["drift quality"] = 127
            entry["extra latency"] = 0
            entry["synch padding"] = true
        }
        var d: [String: Any] = [
            "device id": Int(id),
            "grid-out": [["channels": Int(Self.channels), "stream groups": [[entry]]] as [String: Any]],
            "master uid": Self.deviceUID,
        ]
        if agg != nil {
            d["LDCM"] = false
            d["vocal isolation type"] = 0
            d["voice activity detection enable"] = 0
        }
        return AudioHAL.xml(d)
    }

    // MARK: Settable properties

    /// Whether a client may set property `a` of object `id` (audio-host.md
    /// §13.3); setting any other property answers `'who?'`.
    public func isSettable(_ id: UInt32, _ a: AudioPropertyAddress) -> Bool {
        switch (kind(of: id), a.selector) {
        case (.system, fourCC("powh")): return true
        case (.device, fourCC("appv")): return a.scope == AudioHAL.scopeOutput
        case (.aggregate, fourCC("dch2")), (.aggregate, fourCC("srnd")): return a.scope == AudioHAL.scopeOutput
        case (.ioContext, fourCC("guse")), (.ioContext, fourCC("fsiz")): return true
        default: return false
        }
    }

    /// Sets a property; returns a status (0 = success).
    public func set(_ id: UInt32, _ a: AudioPropertyAddress, _ v: AudioValue) -> UInt32 {
        guard kind(of: id) != nil else { return AudioHAL.badObject }
        guard isSettable(id, a) else { return AudioHAL.unknownProperty }
        switch (a.selector, v) {
        case (fourCC("powh"), let .u32(x)): powerHint = x
        case (fourCC("appv"), let .f32(x)): volume = x
        case (fourCC("dch2"), let .u32s(x)): aggregates[id]?.preferredStereo = x
        case (fourCC("srnd"), let .bytes(x)): aggregates[id]?.layout = x
        case (fourCC("guse"), let .u32s(x)): contexts[id]?.streamUsage[a.scope] = x
        case (fourCC("fsiz"), let .u32(x)):
            guard (Self.minimumFrames...Self.maximumFrames).contains(x) else { return AudioHAL.illegalOperation }
            contexts[id]?.bufferFrames = x
        default:
            return AudioHAL.badSize
        }
        return 0
    }

    // MARK: Creation (messages 3 and 5)

    /// Message 3: an IO context for the device the description names.
    public func createIOContext(description: [UInt8], pid: Int32) -> Result<UInt32, AudioModelError> {
        guard let d = Self.dictionary(description) else { return .failure(.status(AudioHAL.illegalOperation, "unreadable description")) }
        let device = (d["device id"] as? NSNumber)?.uint32Value ?? Self.deviceID
        guard device == Self.deviceID || aggregates[device] != nil else {
            return .failure(.status(AudioHAL.badObject, "unknown device \(device)"))
        }
        let id = allocateID()
        contexts[id] = IOContext(id: id, deviceID: device, creatorPID: pid)
        return .success(id)
    }

    /// Message 5: a private aggregate over the output device.
    public func createAggregate(description: [UInt8], pid: Int32) -> Result<UInt32, AudioModelError> {
        guard var d = Self.dictionary(description) else { return .failure(.status(AudioHAL.illegalOperation, "unreadable description")) }
        let uid = d["uid"] as? String ?? "aggregate-\(nextID)"
        if aggregates.values.contains(where: { $0.uid == uid }) {
            return .failure(.status(AudioHAL.illegalOperation, "an aggregate with UID \(uid) exists"))
        }
        let name = d["name"] as? String ?? uid
        if var subs = d["subdevices"] as? [[String: Any]] {
            for i in subs.indices {
                subs[i]["don't pad"] = 0
                subs[i]["drift algorithm"] = 0
                subs[i]["drift quality"] = 127
                subs[i]["latency-in"] = 0
                subs[i]["latency-out"] = 0
            }
            d["subdevices"] = subs
        }
        let id = allocateID(), stream = allocateID(), sub = allocateID()
        aggregates[id] = Aggregate(id: id, streamID: stream, subdeviceID: sub, uid: uid, name: name, creatorPID: pid,
                                   composition: AudioHAL.xml(d))
        return .success(id)
    }

    /// A client process ended: its aggregates and IO contexts go.
    /// Returns the number of aggregates and every object ID that went
    /// (aggregates with their streams and subdevices, IO contexts).
    @discardableResult
    public func removeClient(pid: Int32) -> (aggregates: Int, contexts: Int, objects: [UInt32]) {
        let aggs = aggregates.values.filter { $0.creatorPID == pid }
        for a in aggs { aggregates[a.id] = nil }
        let ctxs = contexts.values.filter { $0.creatorPID == pid }.map(\.id)
        for c in ctxs { contexts[c] = nil }
        return (aggs.count, ctxs.count, aggs.flatMap { [$0.id, $0.streamID, $0.subdeviceID] } + ctxs)
    }

    /// The IO context `id`, or nil when there is none.
    public func context(_ id: UInt32) -> IOContext? { contexts[id] }
    /// Whether `id` is an aggregate device a client made.
    public func isAggregate(_ id: UInt32) -> Bool { aggregates[id] != nil }

    static func dictionary(_ xml: [UInt8]) -> [String: Any]? {
        var bytes = xml
        while bytes.last == 0 { bytes.removeLast() }
        return (try? PropertyListSerialization.propertyList(from: Data(bytes), options: [], format: nil)) as? [String: Any]
    }

    // MARK: Snapshot

    /// The model's state as plain values (snapshot.md §2.6).
    public struct State: Equatable {
        public var aggregates: [Aggregate]
        public var contexts: [IOContext]
        public var nextID: UInt32
        public var powerHint: UInt32
        public var volume: Float
    }

    /// The current state, objects sorted by ID.
    public var state: State {
        State(aggregates: aggregates.values.sorted { $0.id < $1.id }, contexts: contexts.values.sorted { $0.id < $1.id },
              nextID: nextID, powerHint: powerHint, volume: volume)
    }

    /// Replaces the model's state with `s` (snapshot restore, audio-host.md
    /// §13.6).
    public func restore(_ s: State) {
        aggregates = Dictionary(uniqueKeysWithValues: s.aggregates.map { ($0.id, $0) })
        contexts = Dictionary(uniqueKeysWithValues: s.contexts.map { ($0.id, $0) })
        nextID = s.nextID
        powerHint = s.powerHint
        volume = s.volume
    }
}

/// A request the model refuses: a CoreAudio status code and a message for
/// the log.
public enum AudioModelError: Error, Equatable {
    case status(UInt32, String)
    /// The status code the reply carries.
    public var code: UInt32 { if case let .status(s, _) = self { return s }; return 0 }
}
