// The rendered hands' discs and the recorder's MP4 writer (xr-viewer.md §5.1, §7.1).

import Foundation
import Testing
import YcodeDisplayStream
@testable import YcodeXRViewer

@Suite struct XRHandModelTests {
    func hand(at p: SpatialVector) -> XRHandJoints {
        XRHandJoints(poses: (0..<26).map { SpatialPose(position: p + SpatialVector(0, 0, -0.01 * Double($0))) })
    }

    @Test func discsPerJointAndBoneFacingTheEye() {
        let eye = SpatialVector(0, 1.6, 0)
        let s = XRHandModel.sprites(hands: [hand(at: SpatialVector(-0.2, 1.3, -0.4)), nil], pinching: [false, false], eye: eye)
        // The wrist, 24 finger joints and 19 bone midpoints.
        #expect(s.count == 44)
        #expect(!s.contains { $0.highlight })
        // Each disc's +Z points at the eye.
        for d in s {
            let z = d.pose.rotation.rotate(SpatialVector(0, 0, 1))
            #expect((z - (eye - d.pose.position).normalized).length < 1e-6)
        }
        // Default radius 9 mm → discs 2.2 × that across.
        #expect(abs(s[0].size - 0.0198) < 1e-9)
    }

    @Test func pinchHighlightsThumbAndIndexTips() {
        let h = hand(at: .zero)
        let s = XRHandModel.sprites(hands: [nil, h], pinching: [false, true], eye: SpatialVector(0, 0, 1))
        let lit = s.filter(\.highlight).map(\.pose.position)
        #expect(lit.count == 2)
        #expect(lit.contains(h.poses[5].position) && lit.contains(h.poses[10].position))
    }

    @Test func oneLayerPerHandHoldsAllItsDiscs() throws {
        let h = hand(at: SpatialVector(0, 1.3, -0.4))
        let ov = try #require(XRHandModel.overlay(hand: h, pinching: true, eye: SpatialVector(0, 1.6, 0), n: 64))
        #expect(ov.pixels.count == 64 * 64 * 4)
        #expect(ov.size > 0.05 && ov.size < 1)
        // Some pixels drawn, some highlighted (amber: blue 255, red 90), the corners clear.
        var drawn = 0, amber = 0
        for i in stride(from: 0, to: ov.pixels.count, by: 4) where ov.pixels[i + 3] > 0 {
            drawn += 1
            if ov.pixels[i] == 255 && ov.pixels[i + 2] == 90 { amber += 1 }
        }
        #expect(drawn > 50 && amber > 0 && ov.pixels[3] == 0)
        // The layer faces the eye.
        let z = ov.pose.rotation.rotate(SpatialVector(0, 0, 1))
        #expect((z - (SpatialVector(0, 1.6, 0) - ov.pose.position).normalized).length < 1e-6)
    }

    @Test func discImagesHaveAlpha() {
        let img = XRHandModel.discImage(size: 16, highlight: false)
        #expect(img.count == 16 * 16 * 4)
        #expect(img[3] == 0)                                  // corner: transparent
        #expect(img[(8 * 16 + 8) * 4 + 3] > 100)              // centre: opaque-ish
    }
}

@Suite struct XRMP4WriterTests {
    @Test func writesFtypMdatMoovWithTheSamples() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("xr-\(UUID().uuidString).mp4").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let w = try XRMP4Writer(path: path, width: 1920, height: 1080)
        let sps: [UInt8] = [0x67, 0x64, 0x00, 0x28, 0xAC], pps: [UInt8] = [0x68, 0xEE, 0x3C]
        let idr: [UInt8] = [0, 0, 0, 1] + sps + [0, 0, 0, 1] + pps + [0, 0, 1, 0x65, 1, 2, 3, 4]
        let p: [UInt8] = [0, 0, 0, 1, 0x41, 9, 9]
        try idr.withUnsafeBufferPointer { try w.append(annexB: $0, time: 0) }
        try p.withUnsafeBufferPointer { try w.append(annexB: $0, time: 16_666_667) }
        try w.finish()
        let d = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        func be32(_ i: Int) -> Int { Int(d[i]) << 24 | Int(d[i + 1]) << 16 | Int(d[i + 2]) << 8 | Int(d[i + 3]) }
        func type(_ i: Int) -> String { String(decoding: d[(i + 4)..<(i + 8)], as: UTF8.self) }
        // Top level: ftyp, mdat (64-bit size), moov, covering the file exactly.
        var i = 0, types: [String] = []
        while i < d.count {
            types.append(type(i))
            var size = be32(i)
            if size == 1 { size = Int(be32(i + 8)) << 32 | be32(i + 12) }
            #expect(size >= 8)
            i += size
        }
        #expect(types == ["ftyp", "mdat", "moov"] && i == d.count)
        // The samples are length-prefixed NAL units, SPS/PPS kept for avcC.
        let text = d
        #expect(text.windowContains([0, 0, 0, 5, 0x65, 1, 2, 3, 4]))
        #expect(text.windowContains([0, 0, 0, 3, 0x41, 9, 9]))
        #expect(text.windowContains(Array("avcC".utf8) + [1, 0x64, 0x00, 0x28, 0xFF, 0xE1, 0, 5] + sps))
        #expect(text.windowContains(Array("stss".utf8) + [0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1]))
    }
}

extension Array where Element == UInt8 {
    func windowContains(_ w: [UInt8]) -> Bool {
        guard w.count <= count else { return false }
        for i in 0...(count - w.count) where self[i] == w[0] && Array(self[i..<(i + w.count)]) == w { return true }
        return false
    }
}

@Suite struct XRLayerPlanTests {
    func shown(_ seq: UInt64, x: Double) -> XRLayerPlan.Shown {
        .init(sequence: seq, pose: SpatialPose(position: SpatialVector(x, 0, 0)), fov: .guest(width: 2160, height: 3840))
    }

    @Test func modeChangesNeverShowOneViewsPictureAtAnotherPose() throws {
        var p = XRLayerPlan()
        #expect(p.layout() == nil)
        p.show(.mono, shown(1, x: 0))
        var l = try #require(p.layout())
        #expect(l.map(\.slot) == [10, 10] && l.allSatisfy { $0.view == .mono })
        // A left eye picture: the left eye shows it from its own slot, the right keeps mono.
        p.show(.left, shown(2, x: -0.03))
        l = try #require(p.layout())
        #expect(l.map(\.slot) == [0, 10] && l[0].shown.pose.position.x == -0.03 && l[1].shown.pose.position.x == 0)
        p.show(.right, shown(3, x: 0.03))
        l = try #require(p.layout())
        #expect(l.map(\.slot) == [0, 1] && l[1].shown.pose.position.x == 0.03)
        // A newer mono picture (the head moves): both eyes show it, from the mono slot.
        p.show(.mono, shown(4, x: 0.1))
        l = try #require(p.layout())
        #expect(l.map(\.slot) == [10, 10] && l[0].shown.sequence == 4)
        // Every view's picture has the projection it was rendered with.
        #expect(l.allSatisfy { abs(tan($0.shown.fov.up) - 3840.0 / 2160) < 1e-9 })
        #expect(XRLayerPlan.insetSlot(for: .mono) == 11 && XRLayerPlan.insetSlot(for: .right) == 5)
    }
}
