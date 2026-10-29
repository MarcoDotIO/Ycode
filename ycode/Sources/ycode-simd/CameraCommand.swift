// Camera diagnostics (specs/simulator/camera-host.md §8): no VM starts.
//
//   ycode-simd --camera-list
//   ycode-simd --camera-probe [--camera auto|synthetic|/dev/videoN|<id>] [--frames N]
//              [--size WxH] [--fps F] [--pixel-format 420v|420f|BGRA]
//              [--source-format YUYV|MJPG|NV12|...] [--out frame.png] [--scale K]
//
// `--camera-list` prints every camera with its formats, sizes and rates.
// `--camera-probe` streams N frames (default 30) through the host camera
// service into host-made IOSurfaces, prints each frame's surface, time and
// drops, and writes the last frame as a PNG (`--scale K` shrinks it K
// times). Exit status: 0; 69 when there is no camera or it is busy; 64 for
// bad usage; 1 for other failures.

import Foundation
import YcodeDarwinKernel
import YcodeHostServices

func runCameraCommandIfRequested(_ arguments: [String]) {
    guard arguments.contains("--camera-list") || arguments.contains("--camera-probe") else { return }
    if arguments.contains("--camera-list") { cameraList() }
    cameraProbe(Array(arguments.dropFirst()))
}

private func fail(_ message: String, _ status: Int32) -> Never {
    FileHandle.standardError.write(Data("ycode-simd: \(message)\n".utf8))
    exit(status)
}

private func cameraList() -> Never {
    let (devices, problems) = V4L2.devices()
    for p in problems { print("! \(p)") }
    for d in devices + [SyntheticCamera.device] {
        print("\(d.id)  \"\(d.name)\"\(d.path.map { "  \($0)" } ?? "")\(d.driver.isEmpty ? "" : "  driver \(d.driver)")")
        for f in d.formats {
            print("  \(f.format) (\(f.name))\(f.format.isSupported ? "" : "  [not converted]")")
            for s in f.sizes {
                print("    \(s.width)x\(s.height): \(s.intervals.map(\.description).joined(separator: ", "))")
            }
        }
    }
    if devices.isEmpty { print("(no V4L2 capture device; the synthetic camera is used)") }
    exit(0)
}

private func cameraProbe(_ args: [String]) -> Never {
    var selection: String?
    var frames = 30
    var config = CameraConfiguration(width: 1280, height: 720, framesPerSecond: 30, output: .biPlanar420Video, ringSize: 4,
                                     holdFramesUntilReleased: true, syntheticWhileAbsent: false)
    var out: String?
    var scale = 1
    var it = args.makeIterator()
    func value(_ flag: String) -> String {
        guard let v = it.next() else { fail("\(flag) needs a value", 64) }
        return v
    }
    while let a = it.next() {
        switch a {
        case "--camera-probe": break
        case "--camera": selection = value(a)
        case "--frames":
            guard let n = Int(value(a)), n > 0 else { fail("--frames needs a positive integer", 64) }
            frames = n
        case "--size":
            let parts = value(a).lowercased().split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { fail("--size needs WxH", 64) }
            (config.width, config.height) = (parts[0], parts[1])
        case "--fps":
            guard let f = Double(value(a)), f > 0 else { fail("--fps needs a positive number", 64) }
            config.framesPerSecond = f
        case "--pixel-format":
            let v = value(a)
            guard let f = CameraPixelFormat(name: v) else { fail("--pixel-format needs 420v, 420f or BGRA (not '\(v)')", 64) }
            config.output = f
        case "--source-format": config.sourceFormat = CameraSourceFormat(value(a).uppercased())
        case "--out": out = value(a)
        case "--scale":
            guard let k = Int(value(a)), k >= 1 else { fail("--scale needs a positive integer", 64) }
            scale = k
        default: fail("--camera-probe: unknown argument '\(a)'", 64)
        }
    }

    let system = DarwinSystem()
    let surfaces: IOSurfaceHostService
    do { surfaces = try IOSurfaceHostService(host: system.hostTask, log: { print($0) }) } catch { fail("IOSurface service: \(error)", 1) }
    let service = CameraHostService(surfaces: surfaces, log: { print($0) })

    final class State: @unchecked Sendable {
        let lock = NSLock()
        var frames: [CameraFrame] = []
        var last: (rgba: [UInt8], width: Int, height: Int)?
        var counters: [UInt32?] = []
        var events: [CameraEvent] = []
    }
    let state = State()
    let done = DispatchSemaphore(value: 0)
    let wanted = frames
    let format: CameraStreamFormat
    do {
        format = try service.start(selection: selection, configuration: config, onFrame: { [service] frame in
            let count = state.lock.withLock { state.frames.count }
            guard count < wanted else {
                service.release(frame)
                return
            }
            var counter: UInt32?
            var image: (rgba: [UInt8], width: Int, height: Int)?
            if let info = surfaces.surface(id: frame.surfaceID) {
                let layout = CameraSurfaceLayout.make(frame.format, width: frame.width, height: frame.height)
                let rgba = CameraConverter.rgba(from: info.memory.host, layout: layout)
                if frame.synthetic {
                    counter = SyntheticCamera.readCounter(width: frame.width, height: frame.height) { rgba[($1 * frame.width + $0) * 4 + 1] }
                }
                if count == wanted - 1 { image = (rgba, frame.width, frame.height) }
            }
            service.release(frame)
            state.lock.withLock {
                state.frames.append(frame)
                state.counters.append(counter)
                if let image { state.last = image }
            }
            if count == wanted - 1 { done.signal() }
        }, onEvent: { e in state.lock.withLock { state.events.append(e) } })
    } catch let e as CameraError {
        fail("camera: \(e.message)", e.code == .noDevice || e.code == .busy || e.code == .permission ? 69 : 1)
    } catch {
        fail("camera: \(error)", 1)
    }
    _ = format
    print("surfaces: \(service.surfaceIDs.map(String.init).joined(separator: " ")) (ring of \(config.ringSize))")
    let seconds = Double(frames) / max(1, format.interval.framesPerSecond) * 3 + 5
    let finished = done.wait(timeout: .now() + seconds) == .success
    service.stop()

    let (got, counters, last, events) = state.lock.withLock { (state.frames, state.counters, state.last, state.events) }
    var previous: Int64?
    for (i, f) in got.enumerated() {
        let delta = previous.map { String(format: "%+.2f ms", Double(f.presentationTime - $0) / 1e6) } ?? "first"
        previous = f.presentationTime
        let c = counters[i].map { " counter \($0)" } ?? ""
        print("frame \(f.sequence): device #\(f.deviceSequence) surface \(f.surfaceID) seed \(f.seed) pts \(f.presentationTime) (\(delta))"
              + "\(f.droppedBefore > 0 ? " dropped \(f.droppedBefore)" : "")\(c)")
    }
    for e in events { print("event: \(e)") }
    if got.count >= 2 {
        let span = Double(got.last!.presentationTime - got.first!.presentationTime) / 1e9
        print(String(format: "measured: %d frames in %.3f s = %.2f fps; dropped %llu", got.count, span,
                     Double(got.count - 1) / max(span, 1e-9), service.dropped))
        print(String(format: "conversion: %.2f ms per frame on average, %.2f ms at most", Double(service.conversionTotal) / 1e6
                     / Double(max(1, Int(service.delivered))), Double(service.conversionMax) / 1e6))
    }
    if let out, let last {
        let small = CameraConverter.downscale(rgba: last.rgba, width: last.width, height: last.height, factor: scale)
        let png = PNG.encode(width: small.width, height: small.height, rgba: small.rgba)
        guard FileManager.default.createFile(atPath: out, contents: Data(png)) else { fail("cannot write \(out)", 1) }
        print("wrote \(out) (\(small.width)x\(small.height))")
    }
    guard finished else { fail("only \(got.count) of \(frames) frames arrived", 1) }
    exit(0)
}
