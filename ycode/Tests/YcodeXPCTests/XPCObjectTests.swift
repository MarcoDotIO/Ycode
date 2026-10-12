import Foundation
import Testing
@testable import YcodeXPC

/// Little-endian helpers for building expected bytes from the spec's tables.
func le32(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)]
}

func le64(_ v: UInt64) -> [UInt8] { le32(UInt32(v & 0xFFFF_FFFF)) + le32(UInt32(v >> 32)) }

func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }

@Suite struct XPCObjectTests {
    @Test func dictionaryKeepsOrderAndLooksUpByKey() {
        var d: XPCDict = ["b": .uint64(1), "a": "x"]
        #expect(d.keys == ["b", "a"])
        #expect(d["a"] == "x")
        #expect(d["missing"] == nil)
        d["b"] = .int64(2)
        #expect(d.keys == ["b", "a"])
        #expect(d["b"] == .int64(2))
        d["c"] = .null
        #expect(d.keys == ["b", "a", "c"])
        d["a"] = nil
        #expect(d.keys == ["b", "c"])
        d.append(key: "b", value: .bool(true))
        #expect(d.count == 3)
        #expect(d["b"] == .int64(2)) // first match
    }

    @Test func accessors() {
        #expect(XPCObject.uint64(7).integerValue == 7)
        #expect(XPCObject.int64(-1).integerValue == UInt64.max)
        #expect(XPCObject.string("x").integerValue == nil)
        #expect(XPCObject.send(0x103).port == XPCPort(name: 0x103, disposition: XPCDisposition.makeSend))
        #expect(XPCObject.receive(0x203).port == XPCPort(name: 0x203, disposition: XPCDisposition.moveReceive))
        #expect(XPCObject.string("x").port == nil)
        #expect(XPCObject.sharedMemory(size: 4, port: XPCPort(name: 1, disposition: 17)).isPortBearing)
    }

    @Test func portsAreDepthFirst() {
        let p = { (n: UInt32) in XPCPort(name: n, disposition: 17) }
        let o: XPCObject = [
            "z": .sendRight(p(1)),
            "a": [.fd(p(2)), ["k": .receiveRight(p(3))], .data([1])],
            "m": .sharedMemory(size: 8, port: p(4)),
            "n": .largeData(length: 20000, port: p(5)),
        ]
        #expect(o.ports.map(\.name) == [1, 2, 3, 4, 5])
        let rebound = o.bindingPorts((10...14).map(p))
        #expect(rebound?.ports.map(\.name) == [10, 11, 12, 13, 14])
        #expect(o.bindingPorts([p(1)]) == nil)
    }

    @Test func descriptions() {
        let o: XPCObject = [
            "name": "com.example\n", "type": .uint64(7), "pid": .int64(-3), "port": .send(0x103),
            "u": .uuid(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))), "d": .data([0xAB, 0x01]),
            "list": [true, nil],
        ]
        #expect(o.description == #"{name: "com.example\n", type: 7, pid: -3i, port: send(0x103/20), "#
            + #"u: 00000000-0000-0000-0000-000000000001, d: <2 bytes: ab01>, list: [true, null]}"#)
    }
}
