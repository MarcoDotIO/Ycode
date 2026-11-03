#if os(macOS)
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// The IDE's side of debugging on the Ycode simulator
/// (specs/simulator/debug-stub.md §8.2): the run command, the forward, the
/// lldb settings, and when the session attaches.
@Suite struct RemoteDebugTests {
    let remote = RemoteSimulator(settings: RemoteSimulatorSettings(destination: "tester@sim-host", dataDirectory: "/data/ycode",
                                                                   runtimeRoot: "/rr", simdPath: "/bin/ycode-sim", deviceName: "dev1"))

    @Test func runCommandServesTheStubOnlyUnderTheDebugger() {
        let app = URL(fileURLWithPath: "/build/Demo.app")
        let plain = remote.runCommand(app: app, bundleID: "dev.ycode.demo")
        #expect(!plain.contains("--debug-server"))
        let debug = remote.runCommand(app: app, bundleID: "dev.ycode.demo", debug: true)
        #expect(debug.contains(" '--debug-server' 'unix:/data/ycode/debug/dev1.sock'"))
        #expect(debug.hasPrefix(plain.components(separatedBy: " '--display-server'")[0]))
        #expect(remote.debugSocketPath == "/data/ycode/debug/dev1.sock")
    }

    @Test func forwardAndSettings() {
        #expect(remote.debugForwardArguments(localPort: 47_201) == [
            "-o", "BatchMode=yes", "-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15",
            "-L", "127.0.0.1:47201:/data/ycode/debug/dev1.sock", "tester@sim-host",
        ])
        let s = RemoteSimulator.debuggerSettings(appDirectory: "/build/Demo.app")
        #expect(s.contains("settings set target.exec-search-paths \"/build/Demo.app\""))
        #expect(s.contains("settings set target.process.memory-cache-line-size 16384"))
        #expect(s.contains("settings set target.enable-trampoline-support false"))
        let port = RemoteSimulator.freeLoopbackPort()
        #expect(port.map { $0 > 0 && $0 < 65_536 } == true)
    }

    @Test func attachesOnlyWhenTheStubListens() {
        #expect("ycode-simd: debug: gdb-remote stub listening on unix:/data/ycode/debug/dev1.sock"
            .contains(RemoteSimulator.debugStubListeningMarker))
        #expect(!"ycode-simd: app: ylaunch: launched dev.ycode.demo pid 9".contains(RemoteSimulator.debugStubListeningMarker))
        let t = TestDefaults("remote-debugger")
        defer { t.remove() }
        #expect(RemoteSimulator.attachesDebugger(t.defaults))
        t.defaults.set(false, forKey: "Ycode.remote.debugger")
        #expect(!RemoteSimulator.attachesDebugger(t.defaults))
    }
}
#endif
