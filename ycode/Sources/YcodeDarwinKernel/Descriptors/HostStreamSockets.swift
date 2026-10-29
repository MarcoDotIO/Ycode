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

/// Host ends for guest AF_UNIX stream sockets at fixed paths: the diagnosticd
/// log sink and the paths registered with `serve(paths:with:)`.
public enum HostStreamSockets {
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

    /// `YCODE_NO_NETWORK=1` also turns the DNS service off.
    static let dnsServicePaths: Set<String> = ["/var/run/mDNSResponder", "/private/var/run/mDNSResponder"]

    /// The answering host end for a guest connect to `path` (normalized):
    /// the DNS service (`DNSServiceServer.swift`, networking-ycode.md §4).
    static func endpoint(for path: String) -> ((UnixSocket, KernelLock, DescriptorUser) -> HostSocketEndpoint)? {
        if let server = channelServer(for: path) {
            return { host, lock, user in HostChannelConnection(host: host, lock: lock, pid: user.pid, server: server) }
        }
        guard !InetSocketPolicy.disabled, dnsServicePaths.contains(path) else { return nil }
        return { host, lock, user in DNSServiceConnection(host: host, lock: lock, pid: user.pid) }
    }

    // MARK: Host channels served outside the kernel

    nonisolated(unsafe) private static var channelServers: [String: HostChannelServer] = [:]
    private static let channelServersLock = NSLock()

    static func channelServer(for path: String) -> HostChannelServer? {
        channelServersLock.withLock { channelServers[path] }
    }

    /// Serves `paths` (normalized guest paths): a guest `connect` of an
    /// AF_UNIX stream socket to one of them is accepted at once (no guest
    /// listener), and its bytes go to `server` (ycode-simd's settings
    /// channel, simulator-features.md "Ycode implementation").
    public static func serve(paths: [String], with server: HostChannelServer) {
        channelServersLock.withLock { for p in paths { channelServers[p] = server } }
    }

    /// Stops serving `paths`; later connects to them no longer reach the host.
    public static func stopServing(paths: [String]) {
        channelServersLock.withLock { for p in paths { channelServers[p] = nil } }
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

/// The host side of a host channel (`HostStreamSockets.serve`). Every call
/// comes on the connection's own serial queue, never under the kernel lock.
public protocol HostChannelServer: AnyObject, Sendable {
    func channelOpened(_ connection: HostChannelConnection)
    func channel(_ connection: HostChannelConnection, received bytes: [UInt8])
    func channelClosed(_ connection: HostChannelConnection)
}

/// One guest connection to a host channel.
public final class HostChannelConnection: HostSocketEndpoint, @unchecked Sendable {
    private weak var host: UnixSocket?
    private let lock: KernelLock
    /// The connecting process.
    public let pid: Int32
    private let server: HostChannelServer
    private let queue: DispatchQueue
    private var isClosed = false

    init(host: UnixSocket, lock: KernelLock, pid: Int32, server: HostChannelServer) {
        self.host = host
        self.lock = lock
        self.pid = pid
        self.server = server
        queue = DispatchQueue(label: "ycode.host-channel.\(pid)")
        queue.async { [self] in server.channelOpened(self) }
    }

    func received(_ bytes: ArraySlice<UInt8>, rights: [DarwinOpenFile]?) {
        let copy = Array(bytes)
        queue.async { [self] in server.channel(self, received: copy) }
    }

    func disconnected() {
        isClosed = true
        queue.async { [self] in server.channelClosed(self) }
    }

    /// Bytes to the guest's end. False when the connection has ended. Call
    /// it without holding locks the server's callbacks take.
    @discardableResult
    public func send(_ bytes: [UInt8]) -> Bool {
        lock.withLock {
            guard !isClosed, let host, let peer = host.peer, !peer.closed else { return false }
            peer.appendStream(bytes[...], rights: nil)
            host.changedWithPeer()
            return true
        }
    }

    /// Ends the connection from the host side (the guest reads end of file).
    public func close() {
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            host?.disconnectStream()
        }
    }
}
