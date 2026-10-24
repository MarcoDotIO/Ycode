// ycode-sim-viewer: a window on a Ycode simulator device running elsewhere
// (ycode-simd --display-server; specs/simulator/display-stream.md).
// scripts/ycode-sim-try starts the device on the simulator host, forwards
// its socket, and opens this viewer.

#if os(macOS)
import AppKit
import YcodeDisplayStream

let usage = """
    usage: ycode-sim-viewer [--connect <address>] [--zoom Z] [--fps N] [--encoding jpeg|zlib]
                            [--quality Q] [--downscale N] [--script <file>] [--verbose]

      --connect    the display server: <host>:<port>, <port> (127.0.0.1), or unix:<path>
                   (default 127.0.0.1:47100, or $YCODE_SIM_VIEWER_CONNECT)
      --zoom       window points per device point (default 1: point accurate)
      --fps        frames per second at most (default 60)
      --encoding   jpeg (default) or zlib (lossless, more bandwidth)
      --quality    JPEG quality 1–100 (default 80)
      --downscale  send 1/N of the device pixels per axis (default 1; 2 or 3 for slow links)
      --script     run a test script (see ScriptRunner.swift) and exit with its status
      --verbose    log connection events to stdout

    Mouse: click and drag = one finger; option-drag = pinch/rotate about the center;
    option-shift-drag = two-finger pan; scroll = drag. Keys go to the device while the
    window is key (command shortcuts stay with the viewer). Shift-Command-H home,
    Command-L lock, Command-S screenshot, Command-1/2/3 window size.
    """

var address = DisplayAddress(ProcessInfo.processInfo.environment["YCODE_SIM_VIEWER_CONNECT"] ?? "") ?? .tcp(host: "127.0.0.1", port: 47100)
var settings = DisplayClientHello(client: "ycode-sim-viewer", maxFPS: 60, encoding: "jpeg", quality: 80, downscale: 1)
var zoom: CGFloat = 1
var scriptPath: String?
var verbose = false

var args = CommandLine.arguments.dropFirst().makeIterator()
@MainActor func value(_ name: String) -> String {
    guard let v = args.next() else { FileHandle.standardError.write(Data("\(name) needs a value\n\(usage)\n".utf8)); exit(64) }
    return v
}
@MainActor func integer(_ name: String, _ range: ClosedRange<Int>) -> Int {
    let v = value(name)
    guard let n = Int(v), range.contains(n) else { FileHandle.standardError.write(Data("\(name): \(v) is not in \(range)\n".utf8)); exit(64) }
    return n
}
while let a = args.next() {
    switch a {
    case "--connect":
        let v = value(a)
        guard let parsed = DisplayAddress(v) else { FileHandle.standardError.write(Data("bad address \(v)\n".utf8)); exit(64) }
        address = parsed
    case "--zoom":
        guard let z = Double(value(a)), z > 0.1, z <= 4 else { FileHandle.standardError.write(Data("--zoom needs 0.1–4\n".utf8)); exit(64) }
        zoom = CGFloat(z)
    case "--fps": settings.maxFPS = integer(a, 1...120)
    case "--quality": settings.quality = integer(a, 1...100)
    case "--downscale": settings.downscale = integer(a, 1...4)
    case "--encoding":
        let e = value(a)
        guard DisplayEncoding(name: e) != nil else { FileHandle.standardError.write(Data("--encoding jpeg|zlib\n".utf8)); exit(64) }
        settings.encoding = e
    case "--script": scriptPath = value(a)
    case "--verbose": verbose = true
    case "-h", "--help": print(usage); exit(0)
    default: FileHandle.standardError.write(Data("unknown argument \(a)\n\(usage)\n".utf8)); exit(64)
    }
}

signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let connection = ViewerConnection(address: address, settings: settings)
let controller = ViewerController(connection: connection, zoom: zoom)
app.mainMenu = controller.buildMenu()
var runner: ScriptRunner?
if let scriptPath {
    do {
        runner = try ScriptRunner(path: scriptPath, controller: controller)
        controller.log = { [weak runner] in runner?.log($0) }
    } catch {
        FileHandle.standardError.write(Data("cannot read \(scriptPath): \(error)\n".utf8))
        exit(66)
    }
} else if verbose {
    controller.log = { print($0); fflush(stdout) }
}
controller.window.makeKeyAndOrderFront(nil)
controller.window.makeFirstResponder(controller.deviceView)
app.activate(ignoringOtherApps: true)
connection.start()
runner?.start()
app.run()
#else
print("ycode-sim-viewer runs on macOS; the device runs on a Linux simulator host (see scripts/ycode-sim-try).")
#endif
