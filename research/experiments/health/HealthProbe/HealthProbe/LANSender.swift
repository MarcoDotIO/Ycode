import Foundation
import Network

/// Finds the Mac receiver by Bonjour (`_healthprobe._tcp` in `local.`) and sends
/// newline-delimited JSON over TCP. Local network only: cellular is prohibited, and
/// lines are buffered in memory until a receiver is connected.
final class LANSender {
    var onState: ((String) -> Void)?

    private let queue = DispatchQueue(label: "healthprobe.lan")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var endpoint: NWEndpoint?
    private var buffer = Data()

    func start() {
        let b = NWBrowser(for: .bonjour(type: "_healthprobe._tcp", domain: "local."), using: Self.parameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, let first = results.first else { return }
            self.endpoint = first.endpoint
            if self.connection == nil { self.connect() }
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.onState?("browser failed") }
        }
        b.start(queue: queue)
        browser = b
    }

    func send(_ line: Data) {
        queue.async {
            self.buffer.append(line)
            self.drain()
        }
    }

    private static func parameters() -> NWParameters {
        let p = NWParameters.tcp
        p.prohibitedInterfaceTypes = [.cellular]
        p.includePeerToPeer = false
        return p
    }

    private func connect() {
        guard let ep = endpoint else { return }
        let c = NWConnection(to: ep, using: Self.parameters())
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onState?("connected")
                self.drain()
            case .failed, .cancelled:
                self.onState?("disconnected, retrying")
                self.connection = nil
                self.queue.asyncAfter(deadline: .now() + 2) { if self.connection == nil { self.connect() } }
            default:
                break
            }
        }
        connection = c
        c.start(queue: queue)
    }

    private func drain() {
        guard let c = connection, c.state == .ready, !buffer.isEmpty else { return }
        let chunk = buffer
        buffer.removeAll()
        c.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self, error != nil else { return }
            self.queue.async { self.buffer = chunk + self.buffer }
        })
    }
}
