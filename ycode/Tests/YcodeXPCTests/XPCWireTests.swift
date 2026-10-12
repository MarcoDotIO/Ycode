import Foundation
import Testing
@testable import YcodeXPC

/// The look-up request of `bootstrap-wire.md` §3.5, built from its table
/// (payload only: message offsets 24…203).
let lookUpPayload: [UInt8] = {
    var b: [UInt8] = [0x3F, 0x63, 0x70, 0x78, 0x05, 0, 0, 0]                  // 24
    b += [0x00, 0xF0, 0, 0, 0xA4, 0, 0, 0, 0x06, 0, 0, 0]                     // 32
    b += ascii("handle") + [0, 0] + [0x00, 0x40, 0, 0] + [UInt8](repeating: 0, count: 8) // 44
    b += ascii("instance") + [0, 0, 0, 0] + [0x00, 0xA0, 0, 0] + [UInt8](repeating: 0, count: 16) // 64
    b += ascii("flags") + [0, 0, 0] + [0x00, 0x40, 0, 0] + [UInt8](repeating: 0, count: 8) // 96
    b += ascii("name") + [0, 0, 0, 0] + [0x00, 0x90, 0, 0] + [0x1A, 0, 0, 0]
        + ascii("com.apple.cfprefsd.daemon") + [0] + [0, 0]                       // 116
    b += ascii("type") + [0, 0, 0, 0] + [0x00, 0x40, 0, 0] + [0x07, 0, 0, 0, 0, 0, 0, 0] // 160
    b += ascii("targetpid") + [0, 0, 0] + [0x00, 0x30, 0, 0] + [UInt8](repeating: 0, count: 8) // 180
    return b
}()

let nullUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

let lookUpDictionary: XPCDict = [
    "handle": .uint64(0), "instance": .uuid(nullUUID), "flags": .uint64(0),
    "name": "com.apple.cfprefsd.daemon", "type": .uint64(7), "targetpid": .int64(0),
]

func roundTrip(_ o: XPCObject) throws -> XPCObject {
    let e = try XPCWire.encode(o)
    #expect(e.body.count % 4 == 0)
    return try XPCWire.decode(body: e.body, descriptors: e.descriptors)
}

@Suite struct XPCWireTests {
    // MARK: Captured example (§3.5)

    @Test func capturedLookUpOffsets() {
        // The table's offsets, relative to the message start.
        #expect(24 + lookUpPayload.count == 204)
        #expect(Array(lookUpPayload[44 - 24..<44 - 24 + 6]) == ascii("handle"))
        #expect(Array(lookUpPayload[180 - 24..<180 - 24 + 9]) == ascii("targetpid"))
    }

    @Test func decodesCapturedLookUp() throws {
        let o = try XPCWire.decode(body: lookUpPayload, descriptors: [])
        let d = try #require(o.dictionaryValue)
        #expect(d.keys == ["handle", "instance", "flags", "name", "type", "targetpid"])
        #expect(d == lookUpDictionary)
        let r = try XPCPipeRequest(id: 0x4000_00CF, body: lookUpPayload, descriptors: [], hasReplyPort: true)
        #expect(r.routine == 207)
        #expect(r.knownRoutine == .lookUp)
        #expect(r.name == "com.apple.cfprefsd.daemon")
        #expect(r.type == XPCBootstrapDomain.requester)
        #expect(r.handle == 0)
        #expect(r.flags == 0)
        #expect(r.targetPID == 0)
        #expect(r.instance == nullUUID)
        #expect(r.lookupHandle == nil)
        #expect(r.ports.isEmpty)
    }

    @Test func encodesCapturedLookUpByteForByte() throws {
        let m = try XPCPipeMessage.request(routine: XPCBootstrapRoutine.lookUp.rawValue, lookUpDictionary)
        #expect(m.body == lookUpPayload)
        #expect(m.id == 0x4000_00CF)
        #expect(!m.isComplex)
        #expect(m.messageSize == 204)
    }

    @Test func capturedLookUpReplySize() throws {
        // Reply: complex, one port descriptor, `msgh_size` 116 (§3.5).
        let m = try XPCPipeReply.dictionary([
            "rec_execcnt": .uint64(123_456), "req_pid": .uint64(321), "port": .send(0x1203),
        ])
        #expect(m.id == XPCPipe.replyID)
        #expect(m.descriptors == [.port(name: 0x1203, disposition: XPCDisposition.makeSend)])
        #expect(m.messageSize == 116)
    }

    // MARK: Layout rules (§3.1–§3.3)

    @Test func headerAndMagic() throws {
        let p = try XPCWire.encodePayload([:])
        #expect(p == [0x3F, 0x63, 0x70, 0x78, 5, 0, 0, 0] + le32(0xF000) + le32(4) + le32(0))
        var alt = p
        alt[0] = 0x40 // `@cpx`
        #expect(try XPCWire.decodePayload(alt, ports: []) == .dictionary([:]))
    }

    @Test func portOnlyDictionaryHasByteLength16() throws {
        let e = try XPCWire.encode(["port": .receive(5)])
        #expect(Array(e.body[12..<16]) == le32(16))
        #expect(e.body == ascii("?cpx") + le32(5) + le32(0xF000) + le32(16) + le32(1)
            + ascii("port") + [0, 0, 0, 0] + le32(0x15000))
        #expect(e.descriptors == [.port(name: 5, disposition: XPCDisposition.moveReceive)])
    }

    @Test func stringLengthIncludesNULAndPads() throws {
        for n in 0...9 {
            let s = String(repeating: "x", count: n)
            let p = try XPCWire.encodePayload(.string(s))
            #expect(Array(p[8..<16]) == le32(0x9000) + le32(UInt32(n + 1)))
            let padded = (n + 1 + 3) / 4 * 4
            #expect(p.count == 16 + padded)
            #expect(p[16 + n] == 0)
            #expect(try XPCWire.decodePayload(p, ports: []) == .string(s))
        }
    }

    @Test func scalarLayouts() throws {
        func payload(_ o: XPCObject) throws -> [UInt8] { Array(try XPCWire.encodePayload(o).dropFirst(8)) }
        #expect(try payload(.null) == le32(0x1000))
        #expect(try payload(true) == le32(0x2000) + le32(1))
        #expect(try payload(.int64(-2)) == le32(0x3000) + le64(UInt64(bitPattern: -2)))
        #expect(try payload(.uint64(0x1_0000_0002)) == le32(0x4000) + le64(0x1_0000_0002))
        #expect(try payload(.double(1.5)) == le32(0x5000) + le64(1.5.bitPattern))
        #expect(try payload(.date(1_000_000_007)) == le32(0x7000) + le64(1_000_000_007))
        #expect(try payload(.data([1, 2, 3, 4, 5])) == le32(0x8000) + le32(5) + [1, 2, 3, 4, 5, 0, 0, 0])
        let u = UUID(uuid: (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16))
        #expect(try payload(.uuid(u)) == le32(0xA000) + (1...16).map { UInt8($0) })
        let port = XPCPort(name: 9, disposition: 19)
        #expect(try payload(.fd(port)) == le32(0xB000))
        #expect(try payload(.sharedMemory(size: 0x10_0000, port: port)) == le32(0xC000) + le32(0x10_0000) + le32(0))
        #expect(try payload(.sendRight(port)) == le32(0xD000))
        #expect(try payload(.receiveRight(port)) == le32(0x15000))
        #expect(try payload(.largeData(length: 16385, port: port)) == le32(0x8000) + le32(16385))
        #expect(try payload([.null, true]) == le32(0xE000) + le32(16) + le32(2) + le32(0x1000) + le32(0x2000) + le32(1))
    }

    @Test func dictionaryKeyPadding() throws {
        // `name` → 6E 61 6D 65 00 00 00 00 (§3.3).
        let p = try XPCWire.encodePayload(["name": .null])
        #expect(Array(p[20..<28]) == [0x6E, 0x61, 0x6D, 0x65, 0, 0, 0, 0])
        let q = try XPCWire.encodePayload(["abc": .null])
        #expect(Array(q[20..<24]) == ascii("abc") + [0])
    }

    // MARK: Round trips

    @Test func roundTripsEveryType() throws {
        let port = { (n: UInt32, t: UInt32) in XPCPort(name: n, disposition: t) }
        let values: [XPCObject] = [
            .null, .bool(false), .bool(true), .int64(.min), .int64(.max), .uint64(.max), .double(-0.25),
            .double(.infinity), .date(-5), .data([]), .data([7]), .data([UInt8](repeating: 0xEE, count: 16384)),
            .string(""), .string("naïve 日本 😀"), .string("in\0side"),
            .uuid(UUID(uuid: (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16))),
            .fd(port(3, 17)), .sharedMemory(size: 4096, port: port(4, 17)), .sendRight(port(5, 17)),
            .receiveRight(port(6, 16)), .largeData(length: 16385, port: port(7, 17)),
            .array([]), .dictionary([:]),
            [.uint64(1), ["k": ["deep": [.null]]], .string("x")],
        ]
        for v in values {
            #expect(try roundTrip(v) == v, "\(v)")
            #expect(try roundTrip(["key": v]) == ["key": v])
            #expect(try roundTrip([v, v]) == [v, v])
        }
        let nan = try roundTrip(.double(.nan))
        #expect(nan.doubleValue?.isNaN == true)
    }

    @Test func roundTripsLargeMixedDictionary() throws {
        var d = XPCDict()
        for i in 0..<200 { d.append(key: "key-\(i)", value: i % 2 == 0 ? .uint64(UInt64(i)) : .string("v\(i)")) }
        #expect(try roundTrip(.dictionary(d)) == .dictionary(d))
    }

    // MARK: Descriptors (§3.4)

    @Test func descriptorOrderFollowsSerialization() throws {
        // The spec's example serialized as c-fd, a-send, b-blob; descriptors [fd, send].
        let d: XPCDict = [
            "c-fd": .fd(XPCPort(name: 0x30, disposition: XPCDisposition.copySend)),
            "a-send": .send(0x10),
            "b-blob": .data([1, 2, 3]),
        ]
        let e = try XPCWire.encode(.dictionary(d))
        #expect(e.descriptors == [.port(name: 0x30, disposition: 19), .port(name: 0x10, disposition: 20)])
        // The receiver's names and types replace the sender's.
        let back = try XPCWire.decode(body: e.body, descriptors: [.port(name: 0x903, disposition: 17), .port(name: 0x907, disposition: 17)])
        #expect(back.dictionaryValue?["c-fd"] == .fd(XPCPort(name: 0x903, disposition: 17)))
        #expect(back.dictionaryValue?["a-send"] == .sendRight(XPCPort(name: 0x907, disposition: 17)))
    }

    @Test func nestedDescriptorsAreDepthFirst() throws {
        let p = { (n: UInt32) in XPCPort(name: n, disposition: 17) }
        let o: XPCObject = [
            "a": [.sendRight(p(1)), ["x": .receiveRight(p(2)), "y": .data([0])], .fd(p(3))],
            "b": .sharedMemory(size: 64, port: p(4)),
            "c": ["z": .largeData(length: 40000, port: p(5))],
        ]
        let e = try XPCWire.encode(o)
        #expect(e.descriptors.map { d -> UInt32 in if case let .port(n, _) = d { n } else { 0 } } == [1, 2, 3, 4, 5])
        #expect(try XPCWire.decode(body: e.body, descriptors: e.descriptors) == o)
        // Without descriptors, each right is named by its index.
        let unbound = try XPCWire.decodePayload(e.body, ports: nil)
        #expect(unbound.ports.map(\.name) == [0, 1, 2, 3, 4])
    }

    @Test func guardedPortDescriptorStandsForAPort() throws {
        let e = try XPCWire.encode(["p": .receive(1)])
        let o = try XPCWire.decode(body: e.body, descriptors: [.guardedPort(name: 0x55, disposition: 16)])
        #expect(o.dictionaryValue?["p"] == .receiveRight(XPCPort(name: 0x55, disposition: 16)))
    }

    // MARK: Out-of-line payload (§2.3)

    @Test func decodesPayloadInOneOOLDescriptor() throws {
        var d = XPCDict()
        d["blob"] = .data([UInt8](repeating: 0x5A, count: 16000))
        d["name"] = "large"
        let p = try XPCWire.encodePayload(.dictionary(d))
        // The OOL size is rounded up to 16 KiB multiples; the dictionary length decides.
        let rounded = p + [UInt8](repeating: 0, count: (p.count + 16383) / 16384 * 16384 - p.count)
        let m = XPCPipeMessage(id: 0x4000_0000, descriptors: [.ool(bytes: rounded)], body: [])
        #expect(m.messageSize == 44)
        #expect(try m.decodeDictionary() == d)
        // With a port-bearing object, the remaining descriptors are the ports.
        d["port"] = .send(1)
        let q = try XPCWire.encodePayload(.dictionary(d))
        let back = try XPCWire.decode(body: [], descriptors: [.ool(bytes: q), .port(name: 0x77, disposition: 17)])
        #expect(back.dictionaryValue?["port"] == .sendRight(XPCPort(name: 0x77, disposition: 17)))
    }

    // MARK: Errors

    @Test func rejectsHeaderErrors() {
        #expect(throws: XPCWireError.noPayload) { try XPCWire.decode(body: [], descriptors: []) }
        #expect(throws: XPCWireError.badMagic(0x7870_6341)) {
            try XPCWire.decodePayload(ascii("Acpx") + le32(5) + le32(0x1000), ports: [])
        }
        #expect(throws: XPCWireError.badVersion(4)) {
            try XPCWire.decodePayload(ascii("?cpx") + le32(4) + le32(0x1000), ports: [])
        }
        #expect(throws: XPCWireError.unknownTag(0x6000, offset: 8)) {
            try XPCWire.decodePayload(ascii("?cpx") + le32(5) + le32(0x6000), ports: [])
        }
        #expect(throws: XPCWireError.truncated(offset: 8)) {
            try XPCWire.decodePayload(ascii("?cpx") + le32(5), ports: [])
        }
    }

    @Test func rejectsBadContainersAndStrings() {
        let h = ascii("?cpx") + le32(5)
        // Length larger than the payload.
        #expect(throws: XPCWireError.badLength(offset: 12)) {
            try XPCWire.decodePayload(h + le32(0xF000) + le32(100) + le32(0), ports: [])
        }
        // Count far beyond the bytes.
        #expect(throws: XPCWireError.badLength(offset: 12)) {
            try XPCWire.decodePayload(h + le32(0xE000) + le32(4) + le32(0xFFFF_FFFF), ports: [])
        }
        // Length that leaves bytes unconsumed.
        #expect(throws: XPCWireError.badLength(offset: 12)) {
            try XPCWire.decodePayload(h + le32(0xE000) + le32(8) + le32(0) + le32(0), ports: [])
        }
        // An entry running past its container.
        #expect(throws: XPCWireError.truncated(offset: 24)) {
            try XPCWire.decodePayload(h + le32(0xE000) + le32(8) + le32(1) + le32(0x3000) + le64(0), ports: [])
        }
        // Zero-length string, missing NUL, invalid UTF-8, unterminated key.
        #expect(throws: XPCWireError.badString(offset: 12)) {
            try XPCWire.decodePayload(h + le32(0x9000) + le32(0), ports: [])
        }
        #expect(throws: XPCWireError.badString(offset: 12)) {
            try XPCWire.decodePayload(h + le32(0x9000) + le32(4) + ascii("abcd"), ports: [])
        }
        #expect(throws: XPCWireError.invalidUTF8(offset: 16)) {
            try XPCWire.decodePayload(h + le32(0x9000) + le32(2) + [0xFF, 0, 0, 0], ports: [])
        }
        #expect(throws: XPCWireError.unterminatedKey(offset: 20)) {
            try XPCWire.decodePayload(h + le32(0xF000) + le32(8) + le32(1) + ascii("abcd"), ports: [])
        }
    }

    @Test func rejectsDescriptorMismatches() throws {
        let e = try XPCWire.encode(["a": .send(1), "b": .receive(2)])
        #expect(throws: XPCWireError.missingPortDescriptor(index: 1)) {
            try XPCWire.decode(body: e.body, descriptors: [.port(name: 1, disposition: 17)])
        }
        #expect(throws: XPCWireError.unusedDescriptors(expected: 2, actual: 3)) {
            try XPCWire.decode(body: e.body, descriptors: e.descriptors + [.port(name: 9, disposition: 17)])
        }
        #expect(throws: XPCWireError.unexpectedDescriptor(index: 0)) {
            try XPCWire.decode(body: e.body, descriptors: [.oolPorts(names: [1, 2], disposition: 17)])
        }
        #expect(throws: XPCWireError.unexpectedDescriptor(index: 2)) {
            try XPCWire.decode(body: e.body, descriptors: e.descriptors + [.ool(bytes: [1, 2, 3, 4])])
        }
    }

    @Test func rejectsDeepNesting() {
        var p = ascii("?cpx") + le32(5)
        let depth = 200
        for i in 0..<depth {
            let inner = (depth - i - 1) * 12 + 4 + 4
            p += le32(0xE000) + le32(UInt32(inner)) + le32(1)
        }
        p += le32(0x1000)
        #expect(throws: XPCWireError.nestingTooDeep(offset: 8 + 12 * XPCWire.maximumDepth)) {
            try XPCWire.decodePayload(p, ports: [])
        }
    }

    @Test func encoderRejectsInvalidObjects() {
        #expect(throws: XPCWireError.keyContainsNUL("a\0b")) { try XPCWire.encode(["a\0b": .null]) }
        #expect(throws: XPCWireError.inlineDataTooLarge(16385)) {
            try XPCWire.encode(.data([UInt8](repeating: 0, count: 16385)))
        }
        #expect(throws: XPCWireError.largeDataTooSmall(16384)) {
            try XPCWire.encode(.largeData(length: 16384, port: XPCPort(name: 1, disposition: 17)))
        }
    }

    // MARK: Fuzz-style robustness

    @Test func everyTruncationThrows() throws {
        let full = try XPCWire.encodePayload(.dictionary(lookUpDictionary))
        for n in 0..<full.count {
            #expect(throws: (any Error).self) { try XPCWire.decodePayload(Array(full.prefix(n)), ports: []) }
        }
    }

    @Test func corruptedBytesNeverCrash() throws {
        let sample: XPCObject = [
            "name": "svc", "list": [.uint64(1), .data([1, 2, 3]), ["d": .double(2)]], "port": .send(1),
            "shm": .sharedMemory(size: 64, port: XPCPort(name: 2, disposition: 17)), "u": .uuid(nullUUID),
        ]
        let e = try XPCWire.encode(sample)
        var decoded = 0
        for i in 0..<e.body.count {
            for v: UInt8 in [0x00, 0x01, 0x7F, 0x80, 0xF0, 0xFF] where v != e.body[i] {
                var b = e.body
                b[i] = v
                if (try? XPCWire.decode(body: b, descriptors: e.descriptors)) != nil { decoded += 1 }
                _ = try? XPCWire.decodePayload(b, ports: nil)
            }
        }
        #expect(decoded > 0) // some corruptions are benign (values), none crash
    }

    @Test func randomMutationsNeverCrash() throws {
        var rng = SplitMix64(seed: 0x5EED)
        let base = try XPCWire.encodePayload(.dictionary(lookUpDictionary))
        for _ in 0..<5000 {
            var b = base
            for _ in 0..<Int(rng.next() % 6 + 1) {
                let i = Int(rng.next() % UInt64(b.count))
                switch rng.next() % 4 {
                case 0: b[i] = UInt8(truncatingIfNeeded: rng.next())
                case 1: b.remove(at: i)
                case 2: b.insert(UInt8(truncatingIfNeeded: rng.next()), at: i)
                default: b = Array(b.prefix(i))
                }
                if b.isEmpty { b = [0] }
            }
            _ = try? XPCWire.decodePayload(b, ports: nil)
            _ = try? XPCWire.decode(body: b, descriptors: [.port(name: 1, disposition: 17)])
        }
        // Random byte strings with a valid header.
        for _ in 0..<5000 {
            var b = ascii("?cpx") + le32(5)
            for _ in 0..<Int(rng.next() % 64) { b.append(UInt8(truncatingIfNeeded: rng.next())) }
            _ = try? XPCWire.decodePayload(b, ports: nil)
        }
    }
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
