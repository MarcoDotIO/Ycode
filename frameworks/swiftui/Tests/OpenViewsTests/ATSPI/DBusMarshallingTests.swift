import Foundation
import OVDBus
import Testing

// OV-ATSPI: the D-Bus wire format (D-Bus Specification 0.43). Byte-level
// checks against the specification's own examples, round trips of every
// type the AT-SPI export uses in both byte orders, signatures, messages,
// addresses and the SASL lines.

private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

private func bytes(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }

@Suite("OV-ATSPI D-Bus marshalling")
struct DBusMarshallingTests {
    // MARK: The specification's examples

    @Test func stringsFooPlusBarLittleEndian() throws {
        // "Marshalling basic types": 'foo', '+', 'bar' from an 8-aligned
        // position of a little-endian message.
        var e = DBusEncoder()
        try e.write([.string("foo"), .string("+"), .string("bar")])
        #expect(hex(e.bytes) == hex(bytes("03 00 00 00 66 6f 6f 00 01 00 00 00 2b 00 00 00 03 00 00 00 62 61 72 00")))
        var d = DBusDecoder(e.bytes)
        #expect(try d.read(signature: "sss") == [.string("foo"), .string("+"), .string("bar")])
        #expect(d.isAtEnd)
    }

    @Test func arrayOfOneInt64BigEndian() throws {
        // "Marshalling containers": n = 8, 4 bytes of padding, then 5.
        let v = DBusValue.array(.int64, [.int64(5)])
        #expect(hex(try v.marshalled(bigEndian: true)) == hex(bytes("00 00 00 08 00 00 00 00 00 00 00 00 00 00 00 05")))
        var d = DBusDecoder(try v.marshalled(bigEndian: true), bigEndian: true)
        #expect(try d.read(.array(.int64)) == v)
    }

    @Test func variantOfUInt64BigEndian() throws {
        // A variant holding the 64-bit integer 5: signature "t", 5 bytes of
        // padding to the 8-byte boundary, the value.
        let v = DBusValue.variant(.uint64(5))
        #expect(hex(try v.marshalled(bigEndian: true)) == hex(bytes("01 74 00 00 00 00 00 00 00 00 00 00 00 00 00 05")))
        var d = DBusDecoder(try v.marshalled(bigEndian: true), bigEndian: true)
        #expect(try d.read(.variant) == v)
    }

    @Test func saslExternalLines() {
        // "Authentication examples", figure 1.
        #expect(DBusAuth.externalCommand(uid: 1000) == "AUTH EXTERNAL 31303030\r\n")
        #expect(DBusAuth.guid(fromReply: "OK 1234deadbeef\r\n") == "1234deadbeef")
        #expect(DBusAuth.guid(fromReply: "REJECTED EXTERNAL\r\n") == nil)
    }

    // MARK: Basic types

    @Test func basicTypesHaveTheirSizesAndAlignment() throws {
        func m(_ values: [DBusValue]) throws -> String {
            var e = DBusEncoder()
            try e.write(values)
            return hex(e.bytes)
        }
        // A byte, then a boolean (4 bytes, 4-aligned: 3 bytes of padding).
        #expect(try m([.byte(7), .boolean(true)]) == "07 00 00 00 01 00 00 00")
        // INT16 after a byte: 1 byte of padding.
        #expect(try m([.byte(1), .int16(-2)]) == "01 00 fe ff")
        // UINT16, INT32, UINT32.
        #expect(try m([.uint16(0x1234), .int32(-1), .uint32(0xdeadbeef)]) == "34 12 00 00 ff ff ff ff ef be ad de")
        // A DOUBLE after a byte: 7 bytes of padding; 1.0 = 0x3ff0000000000000.
        #expect(try m([.byte(0), .double(1)]) == "00 00 00 00 00 00 00 00 00 00 00 00 00 00 f0 3f")
        // An object path is a string; a signature has a byte length.
        #expect(try m([.objectPath("/a")]) == "02 00 00 00 2f 61 00")
        #expect(try m([.signature("a{sv}")]) == "05 61 7b 73 76 7d 00")
        // A UNIX_FD index is a UINT32.
        #expect(try m([.unixFD(3)]) == "03 00 00 00")
    }

    @Test func everyTypeRoundTripsInBothByteOrders() throws {
        let ref = DBusValue.structure([.string(":1.42"), .objectPath("/org/a11y/atspi/accessible/w1_2a")])
        let values: [DBusValue] = [
            .byte(0xff), .boolean(false), .boolean(true), .int16(.min), .uint16(.max), .int32(.min), .uint32(.max),
            .int64(.min), .uint64(.max), .double(-0.5), .double(.infinity), .string(""), .string("héllo ✓"),
            .objectPath("/"), .signature(""), .signature("a((so)(so)(so)iiassusau)"), .unixFD(1),
            .array(.int64, []), .array(.byte, [.byte(1), .byte(2)]), .array(.string, [.string("a"), .string("bc")]),
            .structure([.byte(1), .int64(2)]), ref, .array(.structure([.string, .objectPath]), [ref, ref]),
            .dictionary(key: .string, value: .variant, [(.string("x"), .variant(.int32(1))), (.string("y"), .variant(.string("z")))]),
            .stringDictionary(["toolkit": "OpenViews", "id": "probe"]),
            .variant(.variant(.array(.uint32, [.uint32(1), .uint32(2)]))),
            // AT-SPI shapes.
            .structure([.int32(1), .int32(2), .int32(3), .int32(4)]),
            .array(.uint32, [.uint32(0x0200_0100), .uint32(0)]),
            .array(.structure([.string, .string, .string]), [.structure([.string("click"), .string(""), .string("")])]),
            .structure([ref, ref, ref, .int32(-1), .int32(3), .strings(["org.a11y.atspi.Accessible"]), .string("Build"),
                        .uint32(43), .string(""), .array(.uint32, [.uint32(1 << 30), .uint32(0)])]),
            .array(.structure([.uint32, .array(.structure([.string, .objectPath]))]), []),
            .dictionary(key: .uint32, value: .array(.string), [(.uint32(9), .strings(["a"]))]),
        ]
        for big in [false, true] {
            // All in one buffer (alignment depends on the position) and each alone.
            var e = DBusEncoder(bigEndian: big)
            try e.write(values)
            var d = DBusDecoder(e.bytes, bigEndian: big)
            let back = try values.map { try d.read($0.type) }
            #expect(back == values)
            #expect(d.isAtEnd)
            // The AT-SPI event body.
            let event: [DBusValue] = [.string("focused"), .int32(1), .int32(0), .variant(.int32(0)), .emptyProperties]
            var e2 = DBusEncoder(bigEndian: big)
            try e2.write(event)
            var d2 = DBusDecoder(e2.bytes, bigEndian: big)
            #expect(try d2.read(signature: "siiva{sv}") == event)
        }
    }

    @Test func emptyArraysStillPadToTheirElements() throws {
        // A byte, then an empty array of INT64: the length at 4, then
        // padding to 8 although there is no element.
        var e = DBusEncoder()
        try e.write([.byte(1), .array(.int64, [])])
        #expect(hex(e.bytes) == "01 00 00 00 00 00 00 00")
        // An empty array of structs: the length, then 4 bytes of padding to
        // the struct alignment.
        var f = DBusEncoder()
        try f.write([.array(.structure([.string, .objectPath]), [])])
        #expect(hex(f.bytes) == "00 00 00 00 00 00 00 00")
    }

    @Test func dictEntriesAndStructsAlignToEight() throws {
        let v = DBusValue.dictionary(key: .byte, value: .byte, [(.byte(1), .byte(2)), (.byte(3), .byte(4))])
        // Length 10 (two entries: 2 bytes, 6 of padding, 2 bytes), padding to 8.
        #expect(hex(try v.marshalled()) == "0a 00 00 00 00 00 00 00 01 02 00 00 00 00 00 00 03 04")
    }

    // MARK: Errors

    @Test func malformedInputIsRejected() {
        var d1 = DBusDecoder([2, 0, 0, 0])
        #expect(throws: DBusError.self) { try d1.read(.boolean) }
        var d2 = DBusDecoder([1, 1, 0, 0, 0, 0, 0, 0])
        #expect(throws: DBusError.self) { try d2.read(signature: "yu") } // non-nul padding
        var d3 = DBusDecoder([5, 0, 0, 0, 0x61, 0])
        #expect(throws: DBusError.self) { try d3.read(.string) } // truncated
        var d4 = DBusDecoder([1, 0, 0, 0, 0x61, 1])
        #expect(throws: DBusError.self) { try d4.read(.string) } // no nul
        var d5 = DBusDecoder([2, 0, 0, 0, 0x61, 0x61, 0])
        #expect(throws: DBusError.self) { try d5.read(.objectPath) } // not a path
        #expect(throws: DBusError.self) { try DBusValue.string("a\u{0}b").marshalled() }
        #expect(throws: DBusError.self) { try DBusValue.array(.int32, [.string("x")]).marshalled() }
    }

    @Test func signaturesAreValidated() throws {
        for good in ["", "y", "a{sv}", "(so)", "a((so)(so)(so)iiassusau)", "siiva{sv}", "a(ua(so))", "aai", "v", "h"] {
            #expect(throws: Never.self) { try DBusType.parse(good) }
            #expect(try DBusType.parse(good).map(\.signature).joined() == good)
        }
        for bad in ["(", ")", "()", "{sv}", "a{vs}", "a{s}", "a{sss}", "a", "z", "(i", String(repeating: "a", count: 33) + "i",
                    String(repeating: "(", count: 33) + "i" + String(repeating: ")", count: 33), String(repeating: "i", count: 256)] {
            #expect(throws: DBusError.self) { try DBusType.parse(bad) }
        }
    }

    @Test func namesAreValidated() {
        #expect(DBusNames.isValidObjectPath("/org/a11y/atspi/accessible/w1_2a"))
        #expect(!DBusNames.isValidObjectPath("/org/"))
        #expect(!DBusNames.isValidObjectPath("org"))
        #expect(!DBusNames.isValidObjectPath("/a//b"))
        #expect(!DBusNames.isValidObjectPath("/a-b"))
        #expect(DBusNames.isValidInterfaceName("org.a11y.atspi.Event.Object"))
        #expect(!DBusNames.isValidInterfaceName("org"))
        #expect(!DBusNames.isValidInterfaceName("org.1a"))
        #expect(DBusNames.isValidMemberName("GetChildAtIndex"))
        #expect(!DBusNames.isValidMemberName("Get-Children"))
        #expect(DBusNames.isValidBusName(":1.42"))
        #expect(DBusNames.isValidBusName("org.a11y.Bus"))
        #expect(!DBusNames.isValidBusName("org"))
    }

    // MARK: Messages

    @Test func methodCallHeaderAndRoundTrip() throws {
        var m = DBusMessage.methodCall(destination: "org.a11y.atspi.Registry", path: "/org/a11y/atspi/accessible/root",
                                       interface: "org.a11y.atspi.Socket", member: "Embed",
                                       body: [.structure([.string(":1.7"), .objectPath("/org/a11y/atspi/accessible/root")])])
        m.serial = 3
        let b = try m.encoded()
        // 'l', METHOD_CALL, no flags, version 1; body length; serial 3.
        #expect(Array(b[0..<4]) == [0x6c, 1, 0, 1])
        let bodyLength = Int(b[4]) | Int(b[5]) << 8
        #expect(Array(b[8..<12]) == [3, 0, 0, 0])
        #expect(try DBusMessage.frameLength(b[...]) == b.count)
        #expect(try DBusMessage.frameLength(b[0..<15]) == nil)
        #expect((b.count - bodyLength) % 8 == 0)
        let back = try DBusMessage.decode(b)
        #expect(back == m)
        #expect(back.signature == "(so)")
        // Big-endian messages decode too.
        let big = try m.encoded(bigEndian: true)
        #expect(big[0] == 0x42)
        #expect(try DBusMessage.decode(big) == m)
    }

    @Test func repliesErrorsAndSignalsRoundTrip() throws {
        var call = DBusMessage.methodCall(destination: ":1.1", path: "/", interface: nil, member: "Ping")
        call.serial = 9
        call.sender = ":1.2"
        var r = DBusMessage.reply(to: call, body: [.array(.uint32, [.uint32(1), .uint32(0)])])
        r.serial = 10
        #expect(try DBusMessage.decode(try r.encoded()) == r)
        var e = DBusMessage.error(to: call, name: "org.freedesktop.DBus.Error.UnknownObject", message: "no object")
        e.serial = 11
        let eb = try DBusMessage.decode(try e.encoded())
        #expect(eb.errorName == "org.freedesktop.DBus.Error.UnknownObject" && eb.errorMessage == "no object" && eb.replySerial == 9)
        var s = DBusMessage.signal(path: "/org/a11y/atspi/accessible/w1_5", interface: "org.a11y.atspi.Event.Object",
                                   member: "StateChanged",
                                   body: [.string("focused"), .int32(1), .int32(0), .variant(.int32(0)), .emptyProperties])
        s.serial = 12
        s.flags = .noReplyExpected
        #expect(try DBusMessage.decode(try s.encoded()) == s)
        // A signal needs an interface; a message needs a serial.
        var bad = DBusMessage(type: .signal)
        bad.path = "/"
        bad.member = "X"
        bad.serial = 1
        #expect(throws: DBusError.self) { try bad.encoded() }
        #expect(throws: DBusError.self) { try DBusMessage.methodCall(destination: nil, path: "/", interface: nil, member: "X").encoded() }
    }

    @Test func unknownHeaderFieldsAreIgnored() throws {
        var m = DBusMessage.methodCall(destination: nil, path: "/a", interface: "a.b", member: "C")
        m.serial = 1
        var b = try m.encoded()
        // A call with an extra field of an unknown code (200), by hand.
        var h = DBusEncoder()
        try h.write([.byte(0x6c), .byte(1), .byte(0), .byte(1), .uint32(0), .uint32(1),
                     .array(.structure([.byte, .variant]), [
                        .structure([.byte(1), .variant(.objectPath("/a"))]),
                        .structure([.byte(3), .variant(.string("C"))]),
                        .structure([.byte(200), .variant(.byte(9))]),
                     ])])
        h.pad(to: 8)
        let decoded = try DBusMessage.decode(h.bytes)
        #expect(decoded.member == "C" && decoded.path == "/a")
        b[1] = 9 // an unknown message type
        #expect(throws: DBusError.self) { try DBusMessage.decode(b) }
    }

    // MARK: Addresses

    @Test func addressesParseAndUnescape() throws {
        let a = try DBusAddress.parse("unix:path=/run/user/1000/at-spi/bus_0,guid=0123abcd;unix:abstract=/tmp/dbus-X%2cY")
        #expect(a.count == 2)
        #expect(a[0].transport == "unix" && a[0].parameters["path"] == "/run/user/1000/at-spi/bus_0")
        #expect(a[0].parameters["guid"] == "0123abcd")
        #expect(a[1].parameters["abstract"] == "/tmp/dbus-X,Y")
        #expect(DBusAddress.escape("/tmp/a b,c") == "/tmp/a%20b%2cc")
        #expect(try DBusAddress.unescape(Substring(DBusAddress.escape("/tmp/a b,c=é"))) == "/tmp/a b,c=é")
        #expect(throws: DBusError.self) { try DBusAddress.parse("nocolon") }
        #expect(throws: DBusError.self) { try DBusAddress.parse("unix:path=%4") }
    }
}
