import Foundation
import YcodeDarwinABI

// Host-provided AF_UNIX stream sockets (`specs/simulator/launchd-sim.md`
// §8.1). On the Mac, a few simulator daemons connect to sockets that the
// host (CoreSimulator) serves at host paths. In Ycode a guest `connect` to
// such a path is accepted at once, with no guest listener, and the bytes
// the guest sends go to a host sink instead of a receive queue.
//
// The only one today is `/private/var/run/.sim_diagnosticd_socket`. The
// simulator's diagnosticd forwards its system-mode log stream there. The
// host end is OFF by default (launchd-sim.md §8.1): while it is connected,
// diagnosticd encodes and writes every log entry of the whole system for the
// whole boot, which made diagnosticd's traps three to four times higher and
// the boot slower. Without it the connect fails with ENOENT; diagnosticd
// logs an assertion and tries again for about 100 s, then stops.
// `YCODE_SIM_DIAGNOSTICD_SOCKET=1` turns the host end on (the sink reads and
// discards the stream). `YCODE_SIM_DIAGNOSTICD_LOG=1` turns it on too and
// prints the stream's printable strings to the ycode-simd log.
// `YCODE_DEBUG_NO_HOST_SOCKETS=1` forces it off.

enum HostStreamSockets {
    static let diagnosticdPath = "/private/var/run/.sim_diagnosticd_socket"
    static let logDiagnosticd = flag("YCODE_SIM_DIAGNOSTICD_LOG")
    /// Whether a guest connect to the diagnosticd path reaches the host end.
    /// Off by default; tests set it (kernel lock held).
    nonisolated(unsafe) static var diagnosticdEnabled =
        !flag("YCODE_DEBUG_NO_HOST_SOCKETS") && (flag("YCODE_SIM_DIAGNOSTICD_SOCKET") || logDiagnosticd)

    private static func flag(_ name: String) -> Bool {
        getenv(name).map { String(cString: $0) == "1" } ?? false
    }

    /// Diagnostics: connections and bytes received (kernel lock held).
    nonisolated(unsafe) static var connections = 0
    nonisolated(unsafe) static var bytesReceived = 0

    /// The sink for a guest connect to `path` (normalized), or nil when the
    /// path is not a host-provided socket.
    static func sink(for path: String, from user: DescriptorUser) -> ((ArraySlice<UInt8>) -> Void)? {
        guard diagnosticdEnabled, path == diagnosticdPath || path == "/var/run/.sim_diagnosticd_socket" else { return nil }
        connections += 1
        let pid = user.pid
        if logDiagnosticd {
            stderr("ycode-simd: host socket \(diagnosticdPath): connection \(connections) from pid \(pid)")
        }
        return { bytes in
            bytesReceived += bytes.count
            guard logDiagnosticd else { return }
            stderr("ycode-simd: host socket \(diagnosticdPath) from pid \(pid): \(bytes.count) bytes: "
                + printableStrings(bytes).joined(separator: " | "))
        }
    }

    static func printableStrings(_ bytes: ArraySlice<UInt8>) -> [String] {
        var out: [String] = []
        var run: [UInt8] = []
        for b in bytes + [0] {
            if b >= 0x20 && b < 0x7F {
                run.append(b)
                continue
            }
            if run.count >= 3 { out.append(String(decoding: run, as: UTF8.self)) }
            run = []
        }
        return out
    }

    private static func stderr(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
