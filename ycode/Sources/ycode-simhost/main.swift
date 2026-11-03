// ycode-simhost: the simulator host's own service (specs/simulator/sim-link.md).
//
//   ycode-simhost serve [--config FILE]     run the service (TCP control 47800, UDP media 47801 by default)
//   ycode-simhost pair [--config FILE]      open a 5-minute pairing window and print its one-time code
//   ycode-simhost identity [--name N] [--address HOST:PORT]   print this host's pairing file (JSON)
//   ycode-simhost trust <file.json>         trust a client from its pairing file (`ycode sim remote identity`)
//   ycode-simhost peers                     list the trusted clients
//   ycode-simhost untrust <name>            remove a trusted client
//
// Configuration: KEY=value lines in --config, else $YCODE_SIMHOST_CONFIG, else
// ~/.config/ycode/simhost.env (the same keys as scripts/ycode-sim-serve's
// sim-serve.env, plus YCODE_SIMHOST_LISTEN, YCODE_SIMHOST_MEDIA_PORT,
// YCODE_SIMHOST_NAME, YCODE_SIM_LAUNCHER). The identity and trusted peers are
// in $YCODE_SIM_LINK_HOME (default ~/.config/ycode/sim-link).

import Foundation
import YcodeRelease
import YcodeSimLink

func fail(_ s: String, _ code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("ycode-simhost: \(s)\n".utf8))
    exit(code)
}

YcodeRelease.handleVersionFlag(tool: "ycode-simhost")
var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("usage: ycode-simhost serve|pair|identity|trust|peers|untrust (see the source header)", 64) }
args.removeFirst()
@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
let configPath = option("--config") ?? ProcessInfo.processInfo.environment["YCODE_SIMHOST_CONFIG"]
    ?? NSHomeDirectory() + "/.config/ycode/simhost.env"
let store = LinkStore()

@MainActor func loadConfig() -> SimHostConfig {
    let text = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
    do { return try SimHostConfig.load(text: text, environment: ProcessInfo.processInfo.environment) } catch { fail("\(configPath): \(error)") }
}

signal(SIGPIPE, SIG_IGN)
switch command {
case "serve":
    let service: SimHostService
    do {
        service = try SimHostService(config: loadConfig(), store: store)
        try service.start()
    } catch { fail("\(error)") }
    // SIGTERM / SIGINT: stop the devices (they are saved) and exit.
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let sources = [SIGTERM, SIGINT].map { DispatchSource.makeSignalSource(signal: $0, queue: .global()) }
    for s in sources {
        s.setEventHandler {
            service.log("simhost: stopping (devices are saved)")
            service.stop()
            exit(0)
        }
        s.resume()
    }
    // The sources must live as long as the service (Swift may release a local after its last use).
    withExtendedLifetime(sources) { while true { sleep(3600) } }
case "pair":
    let code = Pairing.newCode()
    do { try Pairing.open(code: code, store: store) } catch { fail("\(error)") }
    let id = (try? store.identity())?.fingerprint ?? "?"
    print("Pairing is open for 5 minutes (one attempt). On the client run:\n\n    ycode sim remote pair <this host>[:port] \(code)\n\nThis host's identity: \(id)")
case "identity":
    guard let id = try? store.identity() else { fail("cannot read or create the identity in \(store.directory.path)") }
    let c = (try? String(contentsOfFile: configPath, encoding: .utf8)).flatMap { try? SimHostConfig.load(text: $0, environment: ProcessInfo.processInfo.environment) }
    let file = PairingFile(name: option("--name") ?? c?.name ?? ProcessInfo.processInfo.hostName, identity: id, role: "host",
                           address: option("--address"), mediaPort: c?.mediaPort)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: (try? enc.encode(file)) ?? Data(), as: UTF8.self))
    FileHandle.standardError.write(Data("fingerprint \(id.fingerprint)\n".utf8))
case "trust":
    guard let path = args.first, let d = FileManager.default.contents(atPath: path),
          let f = try? JSONDecoder().decode(PairingFile.self, from: d), let key = Data(base64Encoded: f.publicKey), key.count == 32 else {
        fail("trust <pairing file from `ycode sim remote identity`>")
    }
    do { try store.addPeer(TrustedPeer(name: f.name, publicKey: Array(key), role: "client")) } catch { fail("\(error)") }
    print("trusted client \"\(f.name)\" (\(LinkIdentity.fingerprint(Array(key))))")
case "peers":
    for p in store.peers() where p.role == "client" {
        print("\(p.name)\t\(p.keyBytes.map(LinkIdentity.fingerprint) ?? "?")\tadded \(p.added)")
    }
case "untrust":
    guard let name = args.first else { fail("untrust <name>") }
    print((try? store.removePeer(named: name)) == true ? "removed \(name)" : "no client \(name)")
default:
    fail("unknown command \(command)", 64)
}
