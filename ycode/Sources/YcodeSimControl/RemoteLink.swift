// `ycrun remote setup … --link` and `ycrun remote link [<name>]`
// (specs/ide/ycrun.md §8.4): a host set up with ycrun also becomes a host of
// Ycode's own link (specs/simulator/sim-link.md), so the Linux IDE lists its
// devices as run destinations and its Device Hub shows them. Over the same
// key-only ssh the setup uses:
//
//   1. the host's simulator service runs: when nothing serves its control
//      port, `ycode-simhost serve --config <config>/simhost.env` is started
//      detached, its pid in `<config>/simhost.pid` (a systemd unit the user
//      enabled serves the port already and is left alone);
//   2. the two trust each other with pairing files (sim-link.md §4.2):
//      the host's `ycode-simhost identity` is trusted here as a host, and this
//      computer's identity is given to `ycode-simhost trust` there. Pairing
//      files hold only public keys; ssh carries them with integrity, so no
//      one-time code is needed.
//
// A setup with its own configuration folder (`--config-dir`) keeps the
// host's link identity there too (`<config>/sim-link`), apart from any other
// service on the machine.

import Foundation
import YcodeSimLink

public struct RemoteLinkOptions: Equatable, Sendable {
    /// The service's control and media ports (else the ones in simhost.env, else the link's defaults).
    public var tcpPort: Int?
    public var udpPort: Int?
    /// The name this computer gives the host (`ycode sim remote hosts`).
    public var hostName: String
    public init(hostName: String, tcpPort: Int? = nil, udpPort: Int? = nil) {
        self.hostName = hostName
        self.tcpPort = tcpPort
        self.udpPort = udpPort
    }
}

public struct RemoteLinkStep {
    public var env: YcrunEnvironment
    public init(env: YcrunEnvironment) { self.env = env }

    /// The default configuration folder (`~/.config/ycode`), whose service keeps the default link identity.
    static func isDefaultConfig(_ dir: String) -> Bool {
        dir.isEmpty || dir == "~/.config/ycode" || dir.hasSuffix("/.config/ycode")
    }

    /// A path as one shell word on the host: quoted, with a leading `~/` as the host's `$HOME`.
    public static func word(_ path: String) -> String {
        path.hasPrefix("~/") ? "\"$HOME\"/" + shq(String(path.dropFirst(2))) : shq(path)
    }

    /// The configuration folder (`~/.config/ycode` when the setup named none).
    static func config(_ configDirectory: String) -> String { configDirectory.isEmpty ? "~/.config/ycode" : configDirectory }

    /// `YCODE_SIM_LINK_HOME=<config>/sim-link ` for a setup with its own folder, else nothing.
    public static func linkHomePrefix(configDirectory: String) -> String {
        isDefaultConfig(configDirectory) ? "" : "YCODE_SIM_LINK_HOME=" + word(configDirectory + "/sim-link") + " "
    }

    /// The service program the setup put in place (`<data>/bin/ycode-simhost`).
    public static func simhost(data: String) -> String { data + "/bin/ycode-simhost" }

    /// Starts the service unless something serves its port; prints
    /// `LINK-SERVED <port>` once the port answers, `LINK-STARTED <pid>` when
    /// it started one.
    public static func serveCommand(data: String, configDirectory: String, port: Int) -> String {
        let c = config(configDirectory)
        let env = word(c + "/simhost.env"), pidFile = word(c + "/simhost.pid"), log = word(c + "/simhost.log")
        let listening = "{ ss -Hltn \"sport = :\(port)\" 2>/dev/null | grep -q . ; }"
        return "\(listening) || { [ -f \(pidFile) ] && kill -0 \"$(cat \(pidFile))\" 2>/dev/null; } || { "
            + "nohup setsid env \(linkHomePrefix(configDirectory: configDirectory))\(word(simhost(data: data))) serve --config \(env) > \(log) 2>&1 < /dev/null & "
            + "echo $! > \(pidFile); echo \"LINK-STARTED $!\"; }; "
            + "i=0; while ! \(listening) && [ $i -lt 20 ]; do sleep 0.5; i=$((i+1)); done; "
            + "if \(listening); then echo 'LINK-SERVED \(port)'; else tail -n 15 \(log) 2>/dev/null; exit 1; fi"
    }

    /// The host's pairing file (JSON on standard output).
    public static func identityCommand(data: String, configDirectory: String, name: String, address: String) -> String {
        "\(linkHomePrefix(configDirectory: configDirectory))\(word(simhost(data: data))) identity --config \(word(config(configDirectory) + "/simhost.env"))"
            + " --name \(shq(name)) --address \(shq(address))"
    }

    /// Trusts the client's pairing file, given on standard input.
    public static func trustCommand(data: String, configDirectory: String) -> String {
        "f=$(mktemp) && cat > \"$f\" && \(linkHomePrefix(configDirectory: configDirectory))\(word(simhost(data: data))) trust \"$f\"; s=$?; rm -f \"$f\"; exit $s"
    }

    /// The link's own identities on this computer (`$YCODE_SIM_LINK_HOME`, else `~/.config/ycode/sim-link`).
    var store: LinkStore {
        if let d = env.environment["YCODE_SIM_LINK_HOME"], !d.isEmpty { return LinkStore(directory: URL(fileURLWithPath: d, isDirectory: true)) }
        return LinkStore()
    }

    /// Links a host: its service runs, and the two trust each other.
    public func link(_ entry: SimHostEntry, _ o: RemoteLinkOptions) throws {
        let sh = env.shell(for: entry)
        let port = o.tcpPort ?? LinkDefaults.controlPort
        let served = sh.run(Self.serveCommand(data: entry.dataDirectory, configDirectory: entry.configDirectory, port: port), timeout: 60)
        guard served.ok, served.text.contains("LINK-SERVED") else {
            throw YcrunError("the simulator service on \(sh.title) did not start: \(SimctlFormat.lastLines(served))")
        }
        if let started = served.text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("LINK-STARTED ") }) {
            env.out("   link: started the simulator service on \(sh.title) (pid \(started.dropFirst("LINK-STARTED ".count)), port \(port))")
        } else {
            env.out("   link: the simulator service on \(sh.title) serves port \(port)")
        }
        let host = entry.isLocal ? "127.0.0.1" : SimHostEntry.hostName(of: entry.destination)
        let id = sh.run(Self.identityCommand(data: entry.dataDirectory, configDirectory: entry.configDirectory, name: o.hostName,
                                             address: "\(host):\(port)"), timeout: 60)
        guard id.ok, let file = try? JSONDecoder().decode(PairingFile.self, from: id.output),
              let key = Data(base64Encoded: file.publicKey), key.count == 32 else {
            throw YcrunError("could not read the host's link identity: \(SimctlFormat.lastLines(id))")
        }
        let store = store
        _ = try? store.removePeer(named: o.hostName)
        try store.addPeer(TrustedPeer(name: o.hostName, publicKey: Array(key), role: "host", address: "\(host):\(port)",
                                      mediaPort: o.udpPort ?? file.mediaPort))
        let client = PairingFile(name: ProcessInfo.processInfo.hostName, identity: try store.identity(), role: "client")
        let trusted = sh.run(Self.trustCommand(data: entry.dataDirectory, configDirectory: entry.configDirectory),
                             input: try JSONEncoder().encode(client), timeout: 60)
        guard trusted.ok else { throw YcrunError("the host did not trust this computer: \(SimctlFormat.lastLines(trusted))") }
        env.out("   link: \(o.hostName) and this computer trust each other (host \(LinkIdentity.fingerprint(Array(key))));"
                + " the Linux IDE lists its devices as run destinations")
    }
}
