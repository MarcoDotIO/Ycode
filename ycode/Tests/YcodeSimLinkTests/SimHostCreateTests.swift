import Foundation
import Testing
@testable import YcodeSimLink

/// Creating a device on a host that `ycode-host-setup` just prepared: it has
/// no pristine devices, so the device starts empty and its first boot sets
/// it up (docs/SIMULATOR-UX.md, "Create a device").
@Suite struct SimHostCreateTests {
    func devices(_ extra: String = "") throws -> (SimHostDevices, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-simhost-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let text = "YCODE_SIM_HOME=\(home.path)\nYCODE_SIM_TREE=/nonexistent/tree\nYCODE_SIM_RUNTIME=/nonexistent/RuntimeRoot\n" + extra
        return (SimHostDevices(config: try SimHostConfig.load(text: text, environment: [:])), home)
    }

    @Test func withoutAPristineTheDeviceStartsEmpty() throws {
        let (d, home) = try devices()
        defer { try? FileManager.default.removeItem(at: home) }
        try d.create("iPhone-18-Pro", type: "iphone-18-pro")
        let list = d.list()
        #expect(list.map(\.name) == ["iPhone-18-Pro"])
        #expect(list.first?.deviceType == "iphone-18-pro")
        #expect(list.first?.state == "shutdown")
        #expect(throws: LinkError.self) { try d.create("iPhone-18-Pro", type: "iphone-18-pro") }
    }

    @Test func aPristineIsCopied() throws {
        let pristine = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-pristine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: pristine.appendingPathComponent("data"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: pristine) }
        let (d, home) = try devices("YCODE_SIM_PRISTINE_IPAD_A16=\(pristine.path)\n")
        defer { try? FileManager.default.removeItem(at: home) }
        try d.create("iPad", type: "ipad-a16")
        #expect(FileManager.default.fileExists(atPath: d.config.devicesDirectory + "/iPad/data"))
        #expect(d.list().first?.deviceType == "ipad-a16")
    }
}

extension SimHostCreateTests {
    /// A tree without guest tools boots devices but refuses a run at once,
    /// saying what is missing (the 1.0.0-beta.2 aarch64 release has none).
    @Test func aTreeWithoutGuestToolsSaysItCannotRunApps() throws {
        let (d, home) = try devices()
        defer { try? FileManager.default.removeItem(at: home) }
        let why = try #require(d.config.appRunProblem())
        #expect(why.contains("/nonexistent/tree/SimShim/out/guest-tests/stage7/ylaunch") && why.contains("YCODE_SIM_GUEST_TOOLS"))
        let tools = home.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tools.appendingPathComponent("ylaunch").path, contents: Data())
        let (d2, home2) = try devices("YCODE_SIM_GUEST_TOOLS=\(tools.path)\n")
        defer { try? FileManager.default.removeItem(at: home2) }
        #expect(d2.config.appRunProblem() == nil)
    }
}

extension SimHostCreateTests {
    @Test func aViewerOfABootingDeviceIsToldItIsStarting() {
        #expect(SimHostService.displayNotUpNotice(device: "P", state: "booting") == "P is starting")
        #expect(SimHostService.displayNotUpNotice(device: "P", state: "shutdown") == "the device P is not running")
    }
}

extension SimHostCreateTests {
    /// A program that exists but whose libraries are missing here is a
    /// problem `ycode-simhost check` reports (the host setup's self-test).
    @Test func aProgramThatCannotStartIsReported() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("bad"), good = dir.appendingPathComponent("good")
        try Data("#!/bin/sh\necho 'bad: error while loading shared libraries: libxml2.so.16: cannot open shared object file' >&2\nexit 127\n".utf8).write(to: bad)
        try Data("#!/bin/sh\necho 1.0\n".utf8).write(to: good)
        for f in [bad, good] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path) }
        #expect(SimHostConfig.loaderProblem(bad.path)?.contains("libxml2.so.16") == true)
        #expect(SimHostConfig.loaderProblem(good.path) == nil)
    }
}

extension SimHostCreateTests {
    /// The service's sockets are close-on-exec, so a device's launcher does
    /// not inherit (and keep bound) the service's ports.
    @Test func linkSocketsAreCloseOnExec() throws {
        let l = try LinkListener(host: "127.0.0.1", port: 0)
        defer { l.close() }
        let u = try LinkDatagramSocket(host: "127.0.0.1", port: 0)
        #expect(fcntl(l.fd, F_GETFD) & FD_CLOEXEC != 0)
        #expect(fcntl(u.fd, F_GETFD) & FD_CLOEXEC != 0)
    }
}

extension SimHostCreateTests {
    /// Only failed handshakes count against an address: ten in a minute
    /// close it, older ones do not.
    @Test func onlyFailuresAreRateLimited() {
        let now = Date()
        #expect(SimHostService.allows(failures: [], now: now))
        #expect(SimHostService.allows(failures: Array(repeating: now, count: 9), now: now))
        #expect(!SimHostService.allows(failures: Array(repeating: now, count: 10), now: now))
        #expect(SimHostService.allows(failures: Array(repeating: now.addingTimeInterval(-61), count: 10), now: now))
    }

    /// Many trusted connections in a row (a viewer reconnecting while its
    /// device starts) are all served.
    @Test func trustedClientsAreNotRateLimited() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-ratelimit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let port = Int.random(in: 46900..<47400)
        let config = try SimHostConfig.load(text: "YCODE_SIM_HOME=\(home.path)\nYCODE_SIM_TREE=\(dir.path)\nYCODE_SIM_RUNTIME=\(dir.path)/rt\n"
                                            + "YCODE_SIMHOST_LISTEN=127.0.0.1:\(port)\nYCODE_SIMHOST_MEDIA_PORT=\(port + 1)\n", environment: [:])
        let hostStore = LinkStore(directory: dir.appendingPathComponent("h")), clientStore = LinkStore(directory: dir.appendingPathComponent("c"))
        try hostStore.addPeer(TrustedPeer(name: "c", publicKey: try clientStore.identity().publicKey, role: "client"))
        try clientStore.addPeer(TrustedPeer(name: "h", publicKey: try hostStore.identity().publicKey, role: "host", address: "127.0.0.1:\(port)"))
        let service = try SimHostService(config: config, store: hostStore)
        try service.start()
        defer { service.stop() }
        let client = try LinkClient(store: clientStore, clientName: "c")
        let h = try client.host(named: "h")
        var served = 0
        for _ in 0..<15 {
            let c = try client.control(h)
            if (try? c.request(LinkRequest(op: "devices")))?.ok == true { served += 1 }
            c.close()
        }
        #expect(served == 15)
    }
}

extension SimHostCreateTests {
    /// The Linux IDE's UIKit previews create their preview device this way:
    /// the empty device's folder holds nothing until its first boot.
    @Test func aPreviewDeviceStartsWithAnEmptyFolder() throws {
        let (d, home) = try devices()
        defer { try? FileManager.default.removeItem(at: home) }
        try d.create("ycode-previews-iphone-18-pro", type: "iphone-18-pro")
        let dir = d.config.devicesDirectory + "/ycode-previews-iphone-18-pro"
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir)) == [])
        #expect(d.list().first { $0.name == "ycode-previews-iphone-18-pro" }?.deviceType == "iphone-18-pro")
    }
}
