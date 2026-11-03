import Foundation
import OVPlatform
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// OVPlatform: the run loop (idle without frames, 60 Hz frames while
// animating, frames on the display-link grid), the headless back end, the
// PNG writer, frames presented through R5's renderer, and — when a display
// and libSDL3 are available (OV_TEST_SDL=1) — the SDL back end itself.

struct AnimatedBox: View {
    @State private var wide = false
    var body: some View {
        Color.red.frame(width: wide ? 200 : 100, height: 50)
            .onTapGesture { withAnimation(.linear(duration: 0.5)) { wide.toggle() } }
            .position(x: 200, y: 100)
    }
}

@MainActor
final class FrameRecorder: RunLoopClient {
    var times: [TimeInterval] = []
    var pending = 0
    var needsFrame: Bool { pending > 0 }
    var nextTimerDeadline: TimeInterval? { nil }
    var isFinished: Bool { false }
    func handle(_ event: PlatformEvent) { pending += 3 }
    func fireTimers(now: TimeInterval) {}
    func renderFrame(at time: TimeInterval) {
        times.append(time)
        pending -= 1
    }
}

@MainActor
@Suite("R7 platform, run loop and presentation")
struct PlatformTests {
    @Test func idleApplicationRendersNoFrames() {
        let h = Harness { Color.red.frame(width: 100, height: 100) }
        let frames = h.host.runLoop.framesRendered, iterations = h.host.runLoop.iterations
        #expect(frames >= 1)
        h.run(until: 5.0)
        #expect(h.host.runLoop.framesRendered == frames)
        // One wait to the end of the test period, not 60 per second.
        #expect(h.host.runLoop.iterations - iterations <= 2)
    }

    @Test func animationRendersAtTheDisplayRate() {
        let h = Harness { AnimatedBox() }
        let before = h.host.runLoop.framesRendered
        h.tap(CGPoint(x: 200, y: 100), at: 1.0, duration: 0.02)
        h.run(until: 2.0)
        let frames = h.host.runLoop.framesRendered - before
        // 0.5 s at 60 Hz (plus the frames of the state change and the end).
        #expect(frames >= 30 && frames <= 34)
        // Settled at the new width.
        #expect(h.frame(of: .red)?.width == 200)
    }

    @Test func displayLinkKeepsFramesOnAGrid() {
        let backend = HeadlessBackend(start: 0)
        let loop = PlatformRunLoop(backend: backend, framesPerSecond: 60)
        let client = FrameRecorder()
        backend.post(.quit, at: 0.1)
        loop.run(client, until: 1.0)
        #expect(client.times.count == 3)
        for (a, b) in zip(client.times, client.times.dropFirst()) { #expect(abs((b - a) - 1.0 / 60) < 1e-9) }
        // A late request restarts the grid at the current time.
        var link = DisplayLink(framesPerSecond: 60, start: 0)
        #expect(link.consume(at: 0) == 0)
        #expect(link.consume(at: 1.0 / 60) == 1.0 / 60)
        #expect(link.consume(at: 5.0) == 5.0)
        #expect(abs(link.nextTick - (5.0 + 1.0 / 60)) < 1e-12)
    }

    @Test func headlessBackendDeliversEventsInTimeOrder() {
        let backend = HeadlessBackend()
        backend.post(.quit, at: 2.0)
        backend.post(.openURL(URL(string: "a://1")!), at: 1.0)
        backend.post(.openURL(URL(string: "a://2")!), at: 1.0)
        #expect(backend.waitForEvents(until: 0.5) == [])
        #expect(backend.now == 0.5)
        #expect(backend.waitForEvents(until: nil) == [.openURL(URL(string: "a://1")!), .openURL(URL(string: "a://2")!)])
        #expect(backend.now == 1.0)
        #expect(backend.waitForEvents(until: 10) == [.quit])
        #expect(backend.now == 2.0)
    }

    @Test func pngEncoding() {
        var image = PixelBuffer(width: 3, height: 2, fill: RGBA8(r: 255, g: 0, b: 0))
        image[1, 1] = RGBA8(r: 0, g: 0, b: 255, a: 128)
        let data = [UInt8](image.pngData())
        #expect(Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(Array(data[12..<16]) == Array("IHDR".utf8))
        #expect(Array(data[16..<24]) == [0, 0, 0, 3, 0, 0, 0, 2])
        // IEND with its fixed CRC closes the file.
        #expect(Array(data.suffix(12)) == [0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
    }

    @Test func framesArePresentedThroughTheRenderer() {
        let h = Harness(size: CGSize(width: 200, height: 100), scale: 2, presenter: true) {
            HStack(spacing: 0) {
                Color.red.frame(width: 100, height: 100)
                Color.blue.frame(width: 100, height: 100)
            }
        }
        guard let window = h.window.platform as? HeadlessWindow, let frame = window.lastFrame else {
            Issue.record("no frame")
            return
        }
        #expect(frame.width == 400 && frame.height == 200)
        let left = frame[100, 100], right = frame[300, 100]
        #expect(left.r > 200 && left.b < 100)
        #expect(right.b > 200 && right.r < 100)
        #expect(window.readback() == frame)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OV_TEST_SDL"] != nil))
    func sdlBackendWindowEventsAndReadback() throws {
        let backend = try SDLBackend()
        defer { backend.shutdown() }
        let w = try backend.makeWindow(WindowConfiguration(title: "OV-R7 test", size: CGSize(width: 160, height: 90)))
        #expect(backend.name.hasPrefix("sdl:"))
        _ = backend.waitForEvents(until: backend.now + 0.2)
        let (pw, ph) = w.pixelSize
        var frame = PixelBuffer(width: pw, height: ph, fill: RGBA8(r: 10, g: 200, b: 30))
        frame.fillRect(x: 0, y: 0, width: pw / 2, height: ph, RGBA8(r: 220, g: 20, b: 40))
        w.present(frame)
        let back = try #require(w.readback())
        #expect(back.width == pw && back.height == ph)
        #expect(back[pw / 4, ph / 2].r == 220)
        #expect(back[3 * pw / 4, ph / 2].g == 200)
        // Synthetic input goes through SDL's queue and the translation.
        backend.post(.pointer(PointerEvent(window: w.id, phase: .down, location: CGPoint(x: 40, y: 30), timestamp: 0)))
        backend.post(.key(KeyEvent(window: w.id, key: .character("q"), modifiers: .control, timestamp: 0)))
        let events = backend.waitForEvents(until: backend.now + 0.5)
        #expect(events.contains { if case .pointer(let p) = $0 { return p.phase == .down && abs(p.location.x - 40) < 1 } else { return false } })
        #expect(events.contains { if case .key(let k) = $0 { return k.key == .character("q") && k.modifiers.contains(.control) } else { return false } })
        // Clipboard text round trip. On Wayland a client may set the selection
        // only with the serial of an input event it received; a headless
        // compositor with no seat input gives none, so the check is X11's.
        if backend.name == "sdl:x11" {
            backend.clipboard.text = "ov-r7"
            #expect(backend.clipboard.text == "ov-r7")
        }
        w.close()
    }
}
