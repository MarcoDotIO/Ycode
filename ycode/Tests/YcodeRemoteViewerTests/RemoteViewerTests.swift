import CYcodeCodec
import CYcodeVideo
import Foundation
import Testing
import YcodeDeviceModel
import YcodeDisplayStream
@testable import YcodeRemoteViewer

/// The portable viewer's logic (display-stream.md §12, §13).
struct RemoteViewerTests {
    // MARK: Touches

    @Test func oneFingerMapsViewPointsToDevicePoints() {
        var m = TouchMapper(viewWidth: 201, viewHeight: 437, pointWidth: 402, pointHeight: 874)
        let down = m.down(ViewPoint(x: 100.5, y: 218.5), multiTouch: false, shift: false)
        #expect(down == [TouchContact(finger: 0, phase: .began, x: 201, y: 437)])
        let moved = m.drag(ViewPoint(x: 300, y: -5))
        #expect(moved == [TouchContact(finger: 0, phase: .moved, x: 402, y: 0)])  // clamped
        #expect(m.up(ViewPoint(x: 0, y: 0)) == [TouchContact(finger: 0, phase: .ended, x: 0, y: 0)])
        #expect(m.up(ViewPoint(x: 0, y: 0)) == nil)
        #expect(m.drag(ViewPoint(x: 1, y: 1)) == nil)
    }

    @Test func pinchMirrorsAboutTheCentreAndPanKeepsTheOffset() {
        var m = TouchMapper(viewWidth: 100, viewHeight: 200, pointWidth: 100, pointHeight: 200)
        let pinch = m.down(ViewPoint(x: 30, y: 40), multiTouch: true, shift: false)
        #expect(pinch.map { [$0.x, $0.y] } == [[30, 40], [70, 160]])
        #expect(m.drag(ViewPoint(x: 20, y: 20))!.map { [$0.x, $0.y] } == [[20, 20], [80, 180]])
        #expect(m.up(ViewPoint(x: 20, y: 20))!.allSatisfy { $0.phase == .ended })
        let pan = m.down(ViewPoint(x: 30, y: 40), multiTouch: true, shift: true)
        #expect(pan.map { [$0.x, $0.y] } == [[30, 40], [70, 160]])
        #expect(m.drag(ViewPoint(x: 35, y: 50))!.map { [$0.x, $0.y] } == [[35, 50], [75, 170]])
        #expect(m.cancel()!.allSatisfy { $0.phase == .cancelled })
    }

    @Test func aTurnedPanelMapsBackToItsOwnPoints() {
        let panel = DisplayPanelState(display: "LCD-1", pixelWidth: 300, pixelHeight: 600, scale: 3, rotation: 90, hingeAngle: 180,
                                      targetAngle: nil, posture: "openFlat", orientation: "portrait")
        // Shown turned: 200 × 100 points.
        var m = TouchMapper(viewWidth: 200, viewHeight: 100, pointWidth: 200, pointHeight: 100, panel: panel)
        let c = m.down(ViewPoint(x: 10, y: 20), multiTouch: false, shift: false)
        let n = panel.nativePoint(shownX: 10, shownY: 20)
        #expect(c == [TouchContact(finger: 0, phase: .began, x: Float(n.x), y: Float(n.y))])
    }

    @Test func scrollingIsADragThatEndsWhenIdle() {
        var m = TouchMapper(viewWidth: 100, viewHeight: 100, pointWidth: 100, pointHeight: 100)
        let first = m.scroll(at: ViewPoint(x: 50, y: 50), dx: 0, dy: 10, now: 1)
        #expect(first.count == 2)
        #expect(first[0] == [TouchContact(finger: 0, phase: .began, x: 50, y: 50)])
        #expect(first[1] == [TouchContact(finger: 0, phase: .moved, x: 50, y: 60)])
        #expect(m.scroll(at: ViewPoint(x: 0, y: 0), dx: 0, dy: 100, now: 1.05) == [[TouchContact(finger: 0, phase: .moved, x: 50, y: 100)]])
        #expect(m.endIdleScroll(now: 1.1) == nil)
        #expect(m.endIdleScroll(now: 1.3) == [TouchContact(finger: 0, phase: .ended, x: 50, y: 100)])
        // A press during a scroll lifts the scroll's finger first.
        _ = m.scroll(at: ViewPoint(x: 10, y: 10), dx: 0, dy: 0, now: 2)
        #expect(m.down(ViewPoint(x: 20, y: 20), multiTouch: false, shift: false).first?.phase == .began)
        #expect(m.scrollFinger == nil)
        #expect(TouchMapper.crownDelta(scrollingDeltaY: 1, precise: false) == -20)
    }

    @Test func indicatorShowsTwoFingersOnlyForMultiTouch() {
        var m = TouchMapper(viewWidth: 100, viewHeight: 100, pointWidth: 100, pointHeight: 100)
        #expect(m.indicator(hover: ViewPoint(x: 10, y: 10), multiTouch: false).isEmpty)
        #expect(m.indicator(hover: ViewPoint(x: 10, y: 10), multiTouch: true) == [ViewPoint(x: 10, y: 10), ViewPoint(x: 90, y: 90)])
        _ = m.down(ViewPoint(x: 10, y: 10), multiTouch: false, shift: false)
        #expect(m.indicator(hover: nil, multiTouch: false).isEmpty)
    }

    // MARK: Layout

    @Test func fitScalesTheFrameIntoTheWindow() {
        let g = DeviceFrameGeometry(spec: .iPhone18Pro)
        let l = ViewerLayout(geometry: g, mode: .fit, windowWidth: 460, windowHeight: 900)
        let w = Double(g.size.width) * l.scale, h = Double(g.size.height) * l.scale
        #expect(w <= 460 - 2 * ViewerLayout.margin + 0.001)
        #expect(h <= 900 - 2 * ViewerLayout.margin - ViewerLayout.controlBar + 0.001)
        #expect(abs(w - (460 - 2 * ViewerLayout.margin)) < 0.001 || abs(h - (900 - 2 * ViewerLayout.margin - ViewerLayout.controlBar)) < 0.001)
        // The screen keeps the device's aspect.
        let s = l.screen
        #expect(abs(s.width / s.height - Double(g.screen.width / g.screen.height)) < 1e-9)
        // A window point at the screen's centre is the screen's centre in view points.
        let p = l.screenPoint(s.x + s.width / 2, s.y + s.height / 2)
        #expect(abs(p.x - s.width / 2) < 1e-9 && abs(p.y - s.height / 2) < 1e-9)
    }

    @Test func pointAndPixelAccurateScales() {
        let g = DeviceFrameGeometry(spec: .iPhone18Pro)
        #expect(ViewerLayout(geometry: g, mode: .point, windowWidth: 100, windowHeight: 100).scale == 1)
        #expect(ViewerLayout(geometry: g, mode: .pixel, windowWidth: 100, windowHeight: 100, pixelDensity: 1, deviceScale: 3).scale == 3)
        #expect(ViewerLayout(geometry: g, mode: .pixel, windowWidth: 100, windowHeight: 100, pixelDensity: 2, deviceScale: 3).scale == 1.5)
        let size = ViewerLayout.windowSize(geometry: g, scale: 1)
        #expect(size.width == Double(g.size.width) + 2 * ViewerLayout.margin)
        #expect(ViewerScaleMode(argument: "1:1") == .point)
    }

    @Test func frameButtonsAreHitInWindowUnits() {
        let g = DeviceFrameGeometry(spec: .iPhone18Pro)
        let l = ViewerLayout(geometry: g, mode: .fit, windowWidth: 460, windowHeight: 900)
        for b in g.buttons {
            let r = l.window(b.rect)
            #expect(l.button(atWindow: r.x + r.width / 2, r.y + r.height / 2) == b.kind)
        }
        #expect(RemoteDeviceSession.displayButton(for: .side) == .lock)
        #expect(RemoteDeviceSession.displayButton(for: .crown) == .home)
    }

    /// Frame buttons and the control row follow the shared table (watchos.md §5.2, DeviceButtonTable).
    @Test func buttonsFollowTheDeviceTable() throws {
        // A phone: side → lock, Action → side, as before.
        #expect(RemoteDeviceSession.displayButton(for: .side) == .lock)
        #expect(RemoteDeviceSession.displayButton(for: .action) == .side)
        // A watch: side button → side, crown → home, Action → action only when offered.
        #expect(RemoteDeviceSession.displayButton(for: .sideButton, watch: true) == .side)
        #expect(RemoteDeviceSession.displayButton(for: .crown, watch: true) == .home)
        #expect(RemoteDeviceSession.displayButton(for: .action, watch: true, actionOnTheWire: true) == .action)
        #expect(RemoteDeviceSession.displayButton(for: .action, watch: true, actionOnTheWire: false) == .side)
        // Every button an Ultra's frame draws has a usage on an Ultra.
        let ultra = try #require(DeviceFrameSpec.watches.first { $0.hasActionButton })
        for b in DeviceFrameGeometry(spec: ultra).buttons {
            let d = RemoteDeviceSession.displayButton(for: b.kind, watch: true, actionOnTheWire: true)
            #expect(DeviceButtonTable.usage(of: d, for: .watch(actionButton: true)) != nil)
        }
        // The control row.
        let offered = DeviceButtonTable.buttons(for: .watch(actionButton: true)).map(\.name)
        #expect(RemoteDeviceSession.controlButtons(watch: true, volume: false, offered: offered).map(\.title) == ["Crown", "Side", "Action", "Screen"])
        #expect(RemoteDeviceSession.controlButtons(watch: true, volume: false, offered: ["home", "lock", "side"]).map(\.button)
                == [.home, .side, .lock])
        #expect(RemoteDeviceSession.controlButtons(watch: false, volume: true, offered: nil).map(\.button)
                == [.home, .lock, .volumeUp, .volumeDown])
        #expect(RemoteDeviceSession.controlButtons(watch: false, volume: false, offered: nil).count == 2)
    }

    @Test func roundedPolygonStaysInsideItsRectangle() {
        let r = ViewerRect(x: 10, y: 20, width: 100, height: 200)
        let pts = ViewerLayout.roundedPolygon(r, radii: CornerRadii(all: 20), scale: 1)
        #expect(pts.count == 44)
        #expect(pts.allSatisfy { $0.0 >= 10 - 1e-9 && $0.0 <= 110 + 1e-9 && $0.1 >= 20 - 1e-9 && $0.1 <= 220 + 1e-9 })
    }

    // MARK: Keys

    @Test func scancodesAreUsagesAndTextBecomesKeys() {
        #expect(HIDKeys.usage(sdlScancode: 4) == 4)
        #expect(HIDKeys.usage(sdlScancode: 0xE3) == 0xE3)
        #expect(HIDKeys.usage(sdlScancode: 0) == nil)
        #expect(HIDKeys.usage(sdlScancode: 0x102) == nil)
        #expect(HIDKeys.usage(for: "a").map { [Int($0.usage), $0.shift ? 1 : 0] } == [0x04, 0])
        #expect(HIDKeys.usage(for: "Z").map { [Int($0.usage), $0.shift ? 1 : 0] } == [0x1D, 1])
        #expect(HIDKeys.usage(for: "0").map { [Int($0.usage), $0.shift ? 1 : 0] } == [0x27, 0])
        #expect(HIDKeys.usage(for: "?").map { [Int($0.usage), $0.shift ? 1 : 0] } == [0x38, 1])
        let e = HIDKeys.events(typing: "Hi!")
        #expect(e.map(\.usage) == [0xE1, 0x0B, 0x0B, 0xE1, 0x0C, 0x0C, 0xE1, 0x1E, 0x1E, 0xE1])
        #expect(e.map(\.down) == [true, true, false, false, true, false, true, true, false, false])
        #expect(HIDKeys.events(typing: "é").isEmpty)
    }

    // MARK: Clock

    @Test func clockOffsetTakesTheFastestPing() {
        var c = ClockSync()
        #expect(c.offset == nil)
        // Server is 1 000 000 ns ahead; a slow sample first (asymmetric delay), then a fast one.
        c.add(sent: 10_000, server: 1_010_000 + 4_000, received: 18_000)
        c.add(sent: 100_000, server: 1_100_000 + 500, received: 101_000)
        #expect(c.best?.rtt == 1_000)
        #expect(c.offset == 1_000_000)
        #expect(c.uncertainty == 500)
        #expect(c.clientTime(server: 1_200_000) == 200_000)
        // Old samples leave the window.
        c.add(sent: 70_000_000_000, server: 71_000_000_000 + 3_000, received: 70_000_010_000)
        #expect(c.samples.count == 1)
    }

    // MARK: Canvas and PNG

    @Test func zlibTilesLandInTheCanvas() throws {
        guard ycodec_zlib_available() != 0 else { return }
        let canvas = try #require(StreamCanvas(width: 8, height: 4))
        var px = [UInt8]()
        for i in 0..<(4 * 2) { px += [UInt8(i), 0x80, 0xFF - UInt8(i), 0xFF] }
        var cap = ycodec_zlib_bound(px.count)
        var z = [UInt8](repeating: 0, count: cap)
        #expect(ycodec_zlib_compress(px, px.count, 6, &z, &cap) == 0)
        z.removeLast(z.count - cap)
        let f = DisplayFrame(sequence: 1, guestFrame: 1, serverNanoseconds: 0, inputSequence: 0, width: 8, height: 4, encoding: .zlibBGRA,
                             isFull: false, tiles: [DisplayTile(x: 2, y: 1, width: 4, height: 2, data: z)])
        _ = canvas.withPixels { _, _, d in d }  // clear the initial damage
        #expect(canvas.apply(f))
        let damage = canvas.withPixels { p, row, d -> PixelRect in
            let b = p.assumingMemoryBound(to: UInt8.self)
            #expect(b[1 * row + 2 * 4] == 0)
            #expect(b[1 * row + 3 * 4] == 1)
            #expect(b[2 * row + 5 * 4 + 2] == 0xFF - 7)
            #expect(b[0] == 0 && b[3] == 0xFF)  // untouched: opaque black
            return d
        }
        #expect(damage == PixelRect(x: 2, y: 1, width: 4, height: 2))
        // Out of bounds and corrupt tiles fail.
        var bad = f
        bad.tiles[0].x = 6
        #expect(!canvas.apply(bad))
        bad = f
        bad.tiles[0].data = [1, 2, 3]
        #expect(!canvas.apply(bad))
    }

    @Test func jpegRoundTripWhereLibjpegIsAvailable() throws {
        guard ycodec_jpeg_available() != 0, ycodec_jpeg_decode_available() != 0 else { return }
        let w = 64, h = 32
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) { px[i * 4] = 200; px[i * 4 + 1] = 100; px[i * 4 + 2] = 50; px[i * 4 + 3] = 0xFF }
        var out: UnsafeMutablePointer<UInt8>?
        var size = 0
        #expect(ycodec_jpeg_encode_bgra(px, Int32(w), Int32(h), w * 4, 90, &out, &size) == 0)
        let jpeg = Array(UnsafeBufferPointer(start: out, count: size))
        ycodec_free(out)
        let canvas = try #require(StreamCanvas(width: w, height: h))
        let f = DisplayFrame(sequence: 1, guestFrame: 1, serverNanoseconds: 0, inputSequence: 0, width: w, height: h, encoding: .jpeg,
                             isFull: true, tiles: [DisplayTile(x: 0, y: 0, width: w, height: h, data: jpeg)])
        #expect(canvas.apply(f))
        canvas.withPixels { p, _, _ in
            let b = p.assumingMemoryBound(to: UInt8.self)
            #expect(abs(Int(b[100 * 4]) - 200) < 8 && abs(Int(b[100 * 4 + 1]) - 100) < 8 && abs(Int(b[100 * 4 + 2]) - 50) < 8)
        }
        // A JPEG of another size than its tile is refused.
        var wrong = f
        wrong.tiles[0].width = 32
        wrong.tiles[0].height = 32
        #expect(!canvas.apply(wrong))
    }

    /// H.264 through NVENC and NVDEC where both exist (an NVIDIA GPU; §14):
    /// a frame and a partial update come back close to the source.
    @Test func videoRoundTripWhereNVIDIACodecsExist() throws {
        guard yvid_enc_available() != 0, yvid_dec_available() != 0 else { return }
        let w = 256, h = 128
        var px = [UInt8](repeating: 0, count: w * h * 4)
        func paint(_ x0: Int, _ x1: Int, _ b: UInt8, _ g: UInt8, _ r: UInt8) {
            for y in 0..<h { for x in x0..<x1 { let o = (y * w + x) * 4; px[o] = b; px[o + 1] = g; px[o + 2] = r; px[o + 3] = 0xFF } }
        }
        paint(0, w, 40, 160, 220)
        var err = [CChar](repeating: 0, count: 128)
        let enc = try #require(yvid_enc_open(Int32(w), Int32(h), 60, 4000, &err, err.count))
        defer { yvid_enc_close(enc) }
        let canvas = try #require(StreamCanvas(width: w, height: h))
        func frame(_ rects: [Int32]?, key: Bool, seq: UInt64) throws -> DisplayFrame {
            var out: UnsafePointer<UInt8>?
            var size = 0
            var idr: Int32 = 0
            let r = rects ?? []
            #expect(r.withUnsafeBufferPointer { yvid_enc_encode(enc, px, w * 4, $0.baseAddress, rects == nil ? -1 : Int32(r.count / 4), key ? 1 : 0, &out, &size, &idr) } == 0)
            #expect((idr != 0) == key)
            return DisplayFrame(sequence: seq, guestFrame: seq, serverNanoseconds: 0, inputSequence: 0, width: w, height: h, encoding: .h264,
                                isFull: idr != 0, tiles: [DisplayTile(x: 0, y: 0, width: w, height: h, data: Array(UnsafeBufferPointer(start: out, count: size)))])
        }
        #expect(canvas.apply(try frame(nil, key: true, seq: 1)))
        #expect(canvas.format == .nv12)
        // Only the right half changes; the encoder keeps the left half from before.
        paint(w / 2, w, 200, 30, 10)
        #expect(canvas.apply(try frame([Int32(w / 2), 0, Int32(w / 2), Int32(h)], key: false, seq: 2)))
        let rgba = canvas.rgba()
        func near(_ x: Int, _ y: Int, _ r: Int, _ g: Int, _ b: Int) -> Bool {
            let o = (y * w + x) * 4
            return abs(Int(rgba[o]) - r) < 20 && abs(Int(rgba[o + 1]) - g) < 20 && abs(Int(rgba[o + 2]) - b) < 20
        }
        #expect(near(32, 64, 220, 160, 40))
        #expect(near(200, 64, 10, 30, 200))
        #expect(StreamCanvas.decodableEncodings.contains("h264"))
    }

    /// HEVC through NVENC and NVDEC where both have it, 4:2:0 and 4:4:4 (§14): the
    /// planes come back in the right format, and the colours through BT.709 close to the source.
    @Test(arguments: [(DisplayEncoding.hevc, StreamCanvas.Format.nv12), (.hevc444, .yuv444)])
    func hevcRoundTripWhereNVIDIACodecsExist(encoding: DisplayEncoding, format: StreamCanvas.Format) throws {
        guard yvid_enc_available() != 0, StreamCanvas.canDecode(encoding) else { return }
        let (w, h) = (256, 256)      // NVDEC's HEVC has a minimum height of 144
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let (r, g, b): (UInt8, UInt8, UInt8) = x < w / 2 ? (220, 40, 40) : (40, 200, 90)
            let o = (y * w + x) * 4
            (px[o], px[o + 1], px[o + 2], px[o + 3]) = (b, g, r, 255)
        } }
        var params = yvid_enc_params(codec: Int32(YVID_HEVC), yuv444: encoding == .hevc444 ? 1 : 0, fps: 30, bitrateKbps: 0, qp: 20, constantBitrate: 0)
        guard let enc = yvid_enc_open2(Int32(w), Int32(h), &params, nil, 0) else { Issue.record("no encoder"); return }
        defer { yvid_enc_close(enc) }
        var out: UnsafePointer<UInt8>?
        var size = 0, idr: Int32 = 0
        #expect(yvid_enc_encode(enc, px, w * 4, nil, -1, 1, &out, &size, &idr) == 0)
        #expect(idr != 0)
        let canvas = try #require(StreamCanvas(width: w, height: h))
        let frame = DisplayFrame(sequence: 1, guestFrame: 1, serverNanoseconds: 0, inputSequence: 0, width: w, height: h, encoding: encoding, isFull: true,
                                 tiles: [DisplayTile(x: 0, y: 0, width: w, height: h, data: Array(UnsafeBufferPointer(start: out, count: size)))])
        #expect(canvas.apply(frame))
        #expect(canvas.format == format)
        #expect(canvas.withVideoPlanes { p, _ in p.format } == format)
        #expect((canvas.withNV12 { _, _, _, _ in true } != nil) == (format == .nv12))
        let rgba = canvas.rgba()
        func near(_ x: Int, _ r: Int, _ g: Int, _ b: Int) -> Bool {
            let o = (64 * w + x) * 4
            return abs(Int(rgba[o]) - r) < 6 && abs(Int(rgba[o + 1]) - g) < 6 && abs(Int(rgba[o + 2]) - b) < 6
        }
        #expect(near(32, 220, 40, 40))
        #expect(near(200, 40, 200, 90))
        // Point samples agree with the whole conversion.
        let s = canvas.samplesBGR([(x: 32, y: 64), (x: 200, y: 64)])
        #expect(Int(s[0].2) == Int(rgba[(64 * w + 32) * 4]) && Int(s[1].1) == Int(rgba[(64 * w + 200) * 4 + 1]))
    }

    @Test func pngHasTheRightChunksAndCRCs() throws {
        guard ycodec_zlib_available() != 0 else { return }
        let png = try #require(PNGWriter.encode(rgba: [UInt8](repeating: 0x7F, count: 3 * 2 * 4), width: 3, height: 2))
        #expect(Array(png.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(String(decoding: png[12..<16], as: UTF8.self) == "IHDR")
        #expect(Array(png.suffix(12)) == [0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
        #expect(ycodec_crc32(0, Array("123456789".utf8), 9) == 0xCBF4_3926)
    }

    @Test func imageChecks() {
        #expect(!ImageChecks.isLit([UInt8](repeating: 0, count: 100)))
        #expect(ImageChecks.isLit([UInt8](repeating: 0, count: 80) + [UInt8](repeating: 200, count: 20)))
        #expect(ImageChecks.changedPercent([0, 0, 0, 0], [0, 100, 100, 0]) == 50)
    }

    @Test func stageSummaryPercentiles() {
        #expect(StageSummary.percentile([5, 1, 3], 0.5) == 3)
        let f = FrameStages(sequence: 1, guestFrame: 1, bytes: 10, inputSequence: 0, recordSeen: 1_000_000, captureStart: 2_000_000,
                            encodeEnd: 5_000_000, sendEnd: 6_000_000, received: 7_000_000, decoded: 9_000_000, presented: 10_000_000)
        let s = StageSummary([f])
        #expect(s.stages.first { $0.name == "capture→encoded" }?.values == [3])
        #expect(s.stages.first { $0.name == "seen→presented" }?.values == [9])
    }
}
