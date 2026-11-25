#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import YcodeIDECore

/// Screenshot of a Mac simulator with several screens (`specs/ide/device-hub.md`,
/// "The Mac's own simulators", "Screenshot"): simctl's refusal is parsed,
/// each screen is captured with `--display=<id>`, all-black pictures are
/// dropped (unless all are), the kept files carry the screen's name, and
/// the banner counts them. The fake simctl writes pictures this test makes
/// itself; nothing is booted.
struct SimctlScreenshotTests {
    static let udid = "D0E1F2A3-0000-4000-8000-00000000D0D0"
    /// simctl's refusal on a two-screen device. The first screen line is the
    /// owner's observed text; the second is this test's own.
    static let refusal = """
    Cannot choose between 2 displays. Specify one with --display:
    --display=1  LCD (primary) 1398x2034
    --display=3  Inner 2007x2853
    An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=22):
    Invalid argument
    """

    /// A fake simctl: the plain screenshot refuses with `refusal` (or saves
    /// one picture), a `--display=<id>` capture writes `pictures[id]`
    /// (true: a lit picture, false: an all-black one; missing: it fails).
    final class FakeSimctl: @unchecked Sendable {
        let lock = NSLock()
        var calls: [[String]] = []
        var multiScreen = true
        var pictures: [String: Bool] = [:]
        func run(_ args: [String]) -> (Int32, String) {
            lock.withLock { calls.append(args) }
            guard args.count >= 4, args[0] == "io", args[2] == "screenshot" else { return (0, "") }
            let path = args[args.count - 1]
            if args.count == 4 {
                guard multiScreen else { SimctlScreenshotTests.writePNG(path, lit: true); return (0, "Wrote screenshot to: \(path)") }
                return (22, SimctlScreenshotTests.refusal)
            }
            let id = String(args[3].dropFirst("--display=".count))
            guard let lit = pictures[id] else { return (60, "Timeout waiting for screen surfaces") }
            SimctlScreenshotTests.writePNG(path, lit: lit)
            return (0, "Wrote screenshot to: \(path)")
        }
    }

    /// A 24 × 16 PNG, all black, or black with one grey pixel (`lit`).
    static func writePNG(_ path: String, lit: Bool) {
        let w = 24, h = 16
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 3, to: px.count, by: 4) { px[i] = 255 }
        if lit { px[(5 * w + 7) * 4] = 40; px[(5 * w + 7) * 4 + 1] = 40; px[(5 * w + 7) * 4 + 2] = 40 }
        let image: CGImage? = px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        guard let image,
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    func folder(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-simctl-shot-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func files(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    func control(_ fake: FakeSimctl) -> SimctlDeviceControl {
        SimctlDeviceControl(simctl: Simctl(run: { fake.run($0) }), open: { _ in (0, "") }, isInstalled: { _ in false })
    }

    @Test func theRefusalListsEachScreen() {
        #expect(SimctlDeviceControl.displays(inScreenshotRefusal: Self.refusal)
                == [.init(id: "1", name: "LCD (primary)"), .init(id: "3", name: "Inner")])
        #expect(SimctlDeviceControl.displays(inScreenshotRefusal: "--display=1  LCD (primary) 1398x2034")
                == [.init(id: "1", name: "LCD (primary)")])
        #expect(SimctlDeviceControl.displays(inScreenshotRefusal: "Invalid device: \(Self.udid)").isEmpty)
        #expect(SimctlDeviceControl.screenshotArguments(Self.udid, display: "3", to: "/x/a.png")
                == ["io", Self.udid, "screenshot", "--display=3", "/x/a.png"])
        #expect(SimctlDeviceControl.path("/x/Screenshot iPhone 2026-11-24 at 10.00.00.png", screen: "LCD (primary)")
                == "/x/Screenshot iPhone 2026-11-24 at 10.00.00 (LCD (primary)).png")
    }

    @Test func theBlackCheckReadsThePicture() throws {
        let dir = try folder("black")
        defer { try? FileManager.default.removeItem(at: dir) }
        let black = dir.appendingPathComponent("black.png").path, lit = dir.appendingPathComponent("lit.png").path
        Self.writePNG(black, lit: false)
        Self.writePNG(lit, lit: true)
        #expect(SimctlDeviceControl.imageIsBlack(black))
        #expect(!SimctlDeviceControl.imageIsBlack(lit))
        #expect(!SimctlDeviceControl.imageIsBlack(dir.appendingPathComponent("missing.png").path))
    }

    @Test func aOneScreenDeviceSavesOnePicture() throws {
        let dir = try folder("one")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeSimctl()
        fake.multiScreen = false
        let path = dir.appendingPathComponent("Screenshot iPhone 17.png").path
        #expect(control(fake).screenshot(Self.udid, to: path) == (true, "Screenshot Saved"))
        #expect(fake.calls == [["io", Self.udid, "screenshot", path]])
        #expect(files(dir) == ["Screenshot iPhone 17.png"])
    }

    @Test func aClosedDuoKeepsTheLitScreenUnderThePlainName() throws {
        let dir = try folder("closed")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeSimctl()
        fake.pictures = ["1": true, "3": false]
        let path = dir.appendingPathComponent("Screenshot iPhone Duo.png").path
        #expect(control(fake).screenshot(Self.udid, to: path) == (true, "Screenshot Saved"))
        #expect(fake.calls.map { $0.count > 3 ? $0[3] : "" } == [path, "--display=1", "--display=3"])
        #expect(files(dir) == ["Screenshot iPhone Duo.png"])
        #expect(!SimctlDeviceControl.imageIsBlack(path), "the lit outer screen is the one kept")
    }

    @Test func twoLitScreensAreBothKeptWithTheirNames() throws {
        let dir = try folder("open")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeSimctl()
        fake.pictures = ["1": true, "3": true]
        let path = dir.appendingPathComponent("Screenshot iPhone Duo.png").path
        #expect(control(fake).screenshot(Self.udid, to: path) == (true, "2 Screenshots Saved"))
        #expect(files(dir) == ["Screenshot iPhone Duo (Inner).png", "Screenshot iPhone Duo (LCD (primary)).png"])
    }

    @Test func allBlackKeepsTheFirstListedScreen() throws {
        let dir = try folder("dark")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeSimctl()
        fake.pictures = ["1": false, "3": false]
        let path = dir.appendingPathComponent("Screenshot iPhone Duo.png").path
        #expect(control(fake).screenshot(Self.udid, to: path) == (true, "Screenshot Saved"))
        #expect(files(dir) == ["Screenshot iPhone Duo.png"])
        #expect(SimctlDeviceControl.imageIsBlack(path))
    }

    @Test func failuresReadAsWholePhrases() throws {
        let dir = try folder("fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeSimctl()
        let path = dir.appendingPathComponent("Screenshot iPhone Duo.png").path
        // Every screen's capture fails: the last failure, in a whole sentence.
        #expect(control(fake).screenshot(Self.udid, to: path)
                == (false, "Could not take a screenshot of the simulator: Timeout waiting for screen surfaces"))
        #expect(files(dir).isEmpty)
        // A refusal that lists no screens.
        let plain = SimctlDeviceControl(simctl: Simctl(run: { _ in (22, "An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=22):\nInvalid argument") }),
                                        open: { _ in (0, "") }, isInstalled: { _ in false })
        #expect(plain.screenshot(Self.udid, to: path) == (false, "Could not take a screenshot of the simulator: Invalid argument"))
        // The other actions.
        let refuse = SimctlDeviceControl(simctl: Simctl(run: { _ in (1, "Invalid device") }), open: { _ in (1, "cannot open") }, isInstalled: { _ in true })
        #expect(refuse.start(Self.udid).message == "Could not start the simulator: Invalid device")
        #expect(refuse.shutDown(Self.udid).1 == "Could not shut down the simulator: Invalid device")
        #expect(refuse.erase(Self.udid).1 == "Could not erase the simulator: Invalid device")
        #expect(refuse.show(Self.udid).1 == "Could not show the simulator: cannot open (the simulator viewer)")
    }
}
#endif
