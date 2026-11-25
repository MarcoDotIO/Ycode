import Foundation
import Testing
import YcodeIDECore
@testable import YcodeSimControl
import YcodeSimLink

/// Device Hub's side of ycrun (`YcrunDeviceFiles`: the pid files both hubs
/// read, ycrun's SIGTERM stop) and `ycrun remote link` / `setup --link`
/// (the host's service, the pairing files over ssh).
@Suite(.serialized) struct YcrunHubLinkTests {
    func tempDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ycrun-hub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func sh(_ command: String) -> SimCommandResult { SimShell(location: .local).run(command, timeout: 60) }

    @Test func bootedListsOnlyPidFilesWhoseProcessLives() throws {
        let data = try tempDir()
        defer { try? FileManager.default.removeItem(at: data) }
        let state = YcrunDeviceFiles.stateDirectory(data: data.path)
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        try "\(getpid())\n".write(toFile: YcrunDeviceFiles.pidFile(data: data.path, directory: "alive"), atomically: true, encoding: .utf8)
        try "999999\n".write(toFile: YcrunDeviceFiles.pidFile(data: data.path, directory: "gone"), atomically: true, encoding: .utf8)
        try "\n".write(toFile: YcrunDeviceFiles.pidFile(data: data.path, directory: "empty"), atomically: true, encoding: .utf8)
        let r = sh(YcrunDeviceFiles.bootedCommand(data: data.path))
        #expect(r.ok)
        #expect(YcrunDeviceFiles.parseBooted(r.text) == ["alive"])
        // No ycrun folder at all: nothing, and no error.
        #expect(YcrunDeviceFiles.parseBooted(sh(YcrunDeviceFiles.bootedCommand(data: data.path + "/none")).text).isEmpty)
    }

    @Test func stopSendsSIGTERMWaitsAndRemovesThePidFile() throws {
        let data = try tempDir()
        defer { try? FileManager.default.removeItem(at: data) }
        guard case .success(let pid) = PosixSpawn.spawn(["/bin/sleep", "300"]) else { Issue.record("cannot start sleep"); return }
        var reaped = false
        defer { if !reaped { kill(pid, SIGKILL); _ = PosixSpawn.wait(pid) } }
        let file = YcrunDeviceFiles.pidFile(data: data.path, directory: "dev")
        try FileManager.default.createDirectory(atPath: YcrunDeviceFiles.stateDirectory(data: data.path), withIntermediateDirectories: true)
        try "\(pid)\n".write(toFile: file, atomically: true, encoding: .utf8)
        // The shell's `kill -0` sees the child until it is reaped: reap it as soon as it ends.
        let waiter = Thread { _ = PosixSpawn.wait(pid) }
        waiter.start()
        let r = sh(YcrunDeviceFiles.stopCommand(pidFile: file, grace: 10))
        reaped = true
        #expect(r.ok && !r.text.contains("YCRUN-KILLED"))
        #expect(!FileManager.default.fileExists(atPath: file))
        // Again: nothing to stop (status 3, as ycrun's own shutdown).
        #expect(sh(YcrunDeviceFiles.stopCommand(pidFile: file, grace: 1)).status == 3)
    }

    @Test func ycrunsShutdownIsTheSameCommand() {
        let h = Harness()
        h.configureRemote()
        let env = h.env()
        let ctx = try? env.context(.remote(host: nil))
        let d = ctx?.devices.first
        #expect(d != nil)
        if let ctx, let d {
            #expect(Simctl.stopCommand(d, ctx, grace: 150) == YcrunDeviceFiles.stopCommand(pidFile: ctx.pidFile(d), grace: 150))
            #expect(ctx.pidFile(d) == YcrunDeviceFiles.pidFile(data: ctx.data, directory: d.directory))
        }
    }

    // MARK: link

    @Test func linkStartsTheServiceAndExchangesPairingFilesOverSSH() throws {
        let h = Harness()
        let linkHome = try tempDir()
        defer { try? FileManager.default.removeItem(at: linkHome) }
        var env = h.env()
        env.environment["YCODE_SIM_LINK_HOME"] = linkHome.path
        let hostKey = LinkIdentity()
        let hostFile = PairingFile(name: "sim-host", identity: hostKey, role: "host", address: "sim-host:47930", mediaPort: 47931)
        h.runner.on("serve --config", 0, "LINK-STARTED 4242\nLINK-SERVED 47930\n")
        h.runner.on(" identity --config", data: try JSONEncoder().encode(hostFile))
        h.runner.on(" trust ", 0, "trusted client")
        var e = SimHostEntry(name: "sim-host", destination: "me@sim-host", dataDirectory: "/data/ycode")
        e.configDirectory = "/home/me/ycode-test/config"
        try RemoteLinkStep(env: env).link(e, RemoteLinkOptions(hostName: "sim-host", tcpPort: 47930, udpPort: 47931))
        let cmds = h.runner.commands
        // Over ssh with a key only; the service and identity under the setup's own folder.
        #expect(h.runner.calls.allSatisfy { $0.first == "/usr/bin/ssh" && $0.contains("BatchMode=yes") && $0.contains("me@sim-host") })
        #expect(cmds[0].contains("'/data/ycode/bin/ycode-simhost' serve --config '/home/me/ycode-test/config/simhost.env'"))
        #expect(cmds[0].contains("YCODE_SIM_LINK_HOME='/home/me/ycode-test/config/sim-link'") && cmds[0].contains(":47930"))
        #expect(cmds[1].contains("identity") && cmds[1].contains("'sim-host:47930'"))
        #expect(cmds[2].contains("trust") && !cmds.joined().contains("sudo"))
        // This computer trusts the host; the host was given this computer's public key.
        let peer = try #require(LinkStore(directory: linkHome).peers().first { $0.role == "host" })
        #expect(peer.name == "sim-host" && peer.address == "sim-host:47930" && peer.mediaPort == 47931 && peer.keyBytes == hostKey.publicKey)
        let given = try #require(h.runner.inputs.last.flatMap { $0 })
        let client = try JSONDecoder().decode(PairingFile.self, from: given)
        let mine = Data(try LinkStore(directory: linkHome).identity().publicKey).base64EncodedString()
        #expect(client.role == "client" && client.publicKey == mine)
    }

    @Test func theDefaultConfigFolderKeepsTheDefaultLinkIdentity() {
        #expect(RemoteLinkStep.linkHomePrefix(configDirectory: "") == "")
        #expect(RemoteLinkStep.linkHomePrefix(configDirectory: "/home/me/.config/ycode") == "")
        #expect(RemoteLinkStep.linkHomePrefix(configDirectory: "/x/config") == "YCODE_SIM_LINK_HOME='/x/config/sim-link' ")
        // A folder under the host's home, as the setup stores it.
        #expect(RemoteLinkStep.linkHomePrefix(configDirectory: "~/t/config") == "YCODE_SIM_LINK_HOME=\"$HOME\"/'t/config/sim-link' ")
        #expect(RemoteLinkStep.serveCommand(data: "/d", configDirectory: "~/t/config", port: 47930).contains("\"$HOME\"/'t/config/simhost.pid'"))
    }

    @Test func aServiceThatDoesNotStartIsAnError() {
        let h = Harness()
        h.runner.on("serve --config", 1, "ycode-simhost: port 47930 is in use")
        let e = SimHostEntry(name: "sim-host", destination: "me@sim-host", dataDirectory: "/data/ycode")
        #expect(throws: YcrunError.self) { try RemoteLinkStep(env: h.env()).link(e, RemoteLinkOptions(hostName: "sim-host")) }
        #expect(!h.runner.commands.contains { $0.contains(" identity ") })
    }

    @Test func setupParsesLink() throws {
        let with = try RemoteSetupOptions.parse(["--host", "me@h", "--link"])
        let without = try RemoteSetupOptions.parse(["--host", "me@h"])
        #expect(with.link && !without.link)
    }
}
