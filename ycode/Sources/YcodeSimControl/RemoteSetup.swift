// `ycrun remote …` (specs/ide/ycrun.md §8): setting up a simulator host
// from scratch, with the steps the IDE's "Set Up Ycode Simulator" wizard
// takes (specs/simulator/runtime-onboarding.md): the setup script
// (`HostSetupScript`) in report, then apply, mode over ssh; a runtime copied
// the way the wizard copies one (`RuntimeTransfer`); then a first device and
// the IDEs' own settings.
//
// ssh logs in with a key only. When that fails, ycrun prints the exact
// `ssh-copy-id` step for the user to run and stops: it never asks for,
// stores or passes a password. Steps that need root (the kvm group,
// packages, firewall ports) are printed for the user to run in their own
// terminal; ycrun never runs sudo.

import Foundation
import YcodeIDECore
import YcodeRelease

public struct RemoteSetupOptions: Equatable, Sendable {
    public var local = false
    public var destination: String?
    public var name: String?
    public var dataDirectory: String?
    public var configDirectory = ""
    public var simTree: String?
    public var ycodeVersion: String?
    public var runtimeRoot: String?
    public var copyRuntime: String?
    public var deviceName: String?
    public var deviceType: String?
    public var noDevice = false
    /// nil: make it the IDEs' host when they name none or the same one.
    public var makeDefault: Bool?
    public var reportOnly = false
    public var minFreeGB: Int?
    public var tcpPort = 47800
    public var udpPort = 47801
    public var noProbe = false
    /// Guest tools on this computer to copy to the host (a folder or a tar).
    public var guestTools: String?
    /// Leave missing parts of a source tree unbuilt.
    public var noBuild = false
    /// Parallel jobs for builds on the host.
    public var jobs = 6
    public var assumeYes = false
    /// Name no release to install (status checks).
    public var noInstallSource = false
    /// Also make the host a host of Ycode's link (`RemoteLinkStep`).
    public var link = false

    public init() {}

    public static let usage = """
        usage: ycrun remote setup [--host user@host | --local] [--name N] [--data DIR] [--config-dir DIR]
                                  [--sim-tree DIR | --ycode-version V] [--runtime-root DIR | --copy-runtime <local RuntimeRoot>]
                                  [--device-name N] [--device-type T] [--no-device] [--default | --no-default]
                                  [--guest-tools <folder or .tar>] [--no-build] [--jobs N]
                                  [--min-free-gb N] [--tcp-port N --udp-port N] [--link] [--no-probe] [--report-only] [--yes]
        Asks for what is missing when run in a terminal; every step is also a flag, for scripts and agents.
        --link also starts the host's simulator service and pairs it with this computer over ssh (the Linux IDE's run destinations).
        """

    /// Parses the flags after `ycrun remote setup`.
    public static func parse(_ a: [String]) throws -> RemoteSetupOptions {
        var o = RemoteSetupOptions()
        var i = 0
        func value() throws -> String {
            i += 1
            guard i < a.count else { throw YcrunError.usage("\(a[i - 1]) needs a value\n" + usage) }
            return a[i]
        }
        func int() throws -> Int {
            let v = try value()
            guard let n = Int(v), n > 0 else { throw YcrunError.usage("\(a[i - 1]) needs a positive number, not \(v)") }
            return n
        }
        while i < a.count {
            switch a[i] {
            case "--host", "--destination": o.destination = try value()
            case "--local": o.local = true
            case "--name": o.name = try value()
            case "--data", "--data-dir": o.dataDirectory = try value()
            case "--config-dir": o.configDirectory = try value()
            case "--sim-tree": o.simTree = try value()
            case "--ycode-version": o.ycodeVersion = try value()
            case "--runtime-root": o.runtimeRoot = try value()
            case "--copy-runtime": o.copyRuntime = try value()
            case "--device-name": o.deviceName = try value()
            case "--device-type": o.deviceType = try value()
            case "--no-device": o.noDevice = true
            case "--default": o.makeDefault = true
            case "--no-default": o.makeDefault = false
            case "--report-only": o.reportOnly = true
            case "--min-free-gb": o.minFreeGB = try int()
            case "--tcp-port": o.tcpPort = try int()
            case "--udp-port": o.udpPort = try int()
            case "--no-probe": o.noProbe = true
            case "--guest-tools": o.guestTools = try value()
            case "--no-build": o.noBuild = true
            case "--jobs", "-j": o.jobs = try int()
            case "--yes", "-y": o.assumeYes = true
            case "--link": o.link = true
            default: throw YcrunError.usage("unknown option \(a[i])\n" + usage)
            }
            i += 1
        }
        if o.local && o.destination != nil { throw YcrunError.usage("--local and --host name different machines") }
        if o.simTree != nil && o.ycodeVersion != nil { throw YcrunError.usage("--sim-tree and --ycode-version are two ways to install; pick one") }
        if o.runtimeRoot != nil && o.copyRuntime != nil { throw YcrunError.usage("--runtime-root and --copy-runtime are two ways to get a runtime; pick one") }
        return o
    }
}

/// The ssh failure as the user should read it, with the key step to run themselves.
public enum SSHKeyAdvice {
    /// The first public key in `~/.ssh` (nil: none yet).
    public static func publicKey(home: String = NSHomeDirectory(), fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        ["id_ed25519.pub", "id_ecdsa.pub", "id_rsa.pub"].map { home + "/.ssh/" + $0 }.first(where: fileExists)
    }

    public static func text(destination: String, sshError: String, publicKey: String?) -> String {
        let said = sshError.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = ["ycrun cannot log in to \(destination) with an ssh key" + (said.isEmpty ? "." : " (ssh: \(said.split(separator: "\n").last ?? "")).")]
        let refused = said.contains("Permission denied") || said.contains("publickey") || said.isEmpty
        if refused {
            lines.append("ycrun never uses a password. Give the host your public key yourself, then run the setup again:")
            if publicKey == nil { lines.append("  ssh-keygen -t ed25519            # this computer has no key yet") }
            let key = publicKey ?? "~/.ssh/id_ed25519.pub"
            lines.append("  ssh-copy-id -i \(key) \(destination)")
            lines.append("or add the line in \(key) to ~/.ssh/authorized_keys on the host.")
        } else {
            lines.append("Check the name, that the host is on, and that its ssh server runs; then run the setup again.")
        }
        return lines.joined(separator: "\n")
    }
}

public struct RemoteCommands {
    public var env: YcrunEnvironment

    public init(env: YcrunEnvironment) { self.env = env }

    public static let usage = """
        usage: ycrun remote setup [options]       set up a simulator host (or this machine with --local); ycrun remote setup --help
               ycrun remote list                  the hosts ycrun and the IDEs know, and where devices run by default
               ycrun remote status [<name>]       a host's checks, runtimes and devices
               ycrun remote test [<name>]         log in and check the launcher, simulator tree, runtime and KVM
               ycrun remote link <name> [--tcp-port N --udp-port N]  start its simulator service and pair it with this computer
               ycrun remote remove <name>         forget a host (nothing on the host changes)
        """

    public func run(_ a: [String]) -> Int32 {
        guard let cmd = a.first else { env.out(Self.usage); return YcrunExit.usage }
        let rest = Array(a.dropFirst())
        do {
            switch cmd {
            case "setup":
                if rest.contains("--help") || rest.contains("-h") { env.out(RemoteSetupOptions.usage); return YcrunExit.ok }
                return try setup(RemoteSetupOptions.parse(rest))
            case "list": return list()
            case "status": return try status(rest.first)
            case "test": return try test(rest.first)
            case "remove":
                guard rest.count == 1 else { throw YcrunError.usage("remove <name>") }
                return try remove(rest[0])
            case "link": return try link(rest)
            case "help", "--help", "-h": env.out(Self.usage); return YcrunExit.ok
            default: throw YcrunError.usage("unknown command `\(cmd)`\n" + Self.usage)
            }
        } catch let e as YcrunError {
            env.err("ycrun remote \(cmd): \(e.description)")
            return e.status
        } catch {
            env.err("ycrun remote \(cmd): \(error)")
            return YcrunExit.failure
        }
    }

    // MARK: setup

    public func setup(_ given: RemoteSetupOptions) throws -> Int32 {
        var o = given
        var attention: [String] = []
        // 1. The host.
        if !o.local && o.destination == nil {
            if let ask = env.ask, !o.assumeYes, let a = ask("Simulator host (user@host, or `local` for this machine): ")?.trimmingCharacters(in: .whitespaces), !a.isEmpty {
                if a == "local" { o.local = true } else { o.destination = a }
            } else {
                throw YcrunError.usage("name the host with --host user@host (or --local for this machine)")
            }
        }
        if let d = o.destination, !d.contains("@") || d.hasPrefix("-") || d.contains(" ") {
            throw YcrunError.usage("--host needs user@host (got \(d))")
        }
        let destination = o.local ? "" : o.destination!
        let name = o.name ?? (o.local ? "local" : SimHostEntry.hostName(of: destination))
        var entry = SimHostEntry(name: name, destination: destination, dataDirectory: "")
        let sh = env.shell(for: entry)
        env.out("1. Host: \(o.local ? "this machine" : destination) (named \(name))")

        // 2. Logging in, with a key only.
        if !o.local {
            let r = sh.run("printf ycrun-ok", timeout: 30)
            guard r.ok, r.text == "ycrun-ok" else {
                env.err(SSHKeyAdvice.text(destination: destination, sshError: r.errorText, publicKey: SSHKeyAdvice.publicKey(home: env.environment["HOME"] ?? NSHomeDirectory())))
                return YcrunExit.failure
            }
            env.out("2. ssh: logged in with a key (BatchMode; no password is ever used)")
        } else {
            env.out("2. ssh: not needed (this machine)")
        }

        // The data folder: given, asked, or the default; "~/" is the host's home.
        var data = o.dataDirectory ?? ""
        if data.isEmpty {
            let suggested = o.local ? (env.environment["YCODE_DATA"].flatMap { $0.isEmpty ? nil : $0 } ?? "~/.local/share/ycode") : "~/ycode-data"
            if let ask = env.ask, !o.assumeYes, let a = ask("Ycode's data folder on the host ($YCODE_DATA; runtimes need about 16 GB each) [\(suggested)]: ") {
                data = a.trimmingCharacters(in: .whitespaces).isEmpty ? suggested : a.trimmingCharacters(in: .whitespaces)
            } else {
                data = suggested
            }
        }
        if data.hasPrefix("~/") || data == "~" {
            let home = sh.run("printf %s \"$HOME\"", timeout: 30).text
            guard home.hasPrefix("/") else { throw YcrunError("cannot read the home folder on \(sh.title)") }
            data = home + String(data.dropFirst())
        }
        guard data.hasPrefix("/") else { throw YcrunError.usage("the data folder must be an absolute path (or start with ~/)") }
        while data.count > 1 && data.hasSuffix("/") { data.removeLast() }
        entry.dataDirectory = data
        entry.launcher = data + "/bin/ycode-sim"
        entry.configDirectory = o.configDirectory

        // 3. Checks (the setup script, report mode: nothing changes).
        let report = runScript(sh, o, data: data, mode: "report")
        guard !report.facts.isEmpty else {
            throw YcrunError("the setup script did not run on \(sh.title): " + report.errors.joined(separator: "; "))
        }
        let arch = report.facts["arch"] ?? "?"
        env.out("3. Checks on \(sh.title): \(report.facts["os"] ?? "?") \(arch), KVM \(report.facts["kvm"] ?? "?"), "
                + "\((Int(report.facts["data_free_kb"] ?? "") ?? 0) / 1024 / 1024) GB free for \(data)")
        if report.facts["os"] != "Linux" || !["aarch64", "arm64"].contains(arch) {
            env.err("The simulator host must be arm64 Linux with KVM; \(sh.title) is \(report.facts["os"] ?? "?") \(arch).")
            return YcrunExit.failure
        }
        for c in report.checks { env.out("   " + Self.mark(c.state) + " " + HostSetupOutput.title(of: c.id) + ": " + c.reason) }
        if o.reportOnly {
            printRootSteps(report, o, data: data, destination: destination)
            return report.checks.contains { $0.state == .missing } ? YcrunExit.failure : YcrunExit.ok
        }

        // 4. Install (the steps that need no root, as the user).
        var after = report
        if !report.userSteps.isEmpty {
            env.out("4. Install: " + report.userSteps.map(\.id).joined(separator: ", "))
            after = runScript(sh, o, data: data, mode: "apply")
            for (id, ok) in after.ran.sorted(by: { $0.key < $1.key }) where !ok { attention.append("the setup step \(id) failed") }
        } else {
            env.out("4. Install: nothing to do")
        }
        // The simulator tree's parts: checked, the missing ones built (a
        // source tree), the guest tools copied from this computer; then the
        // launcher's own configuration (scripts/ycode-sim.sh reads
        // ycode-sim.conf next to itself) and the service's.
        if let tree = after.facts["sim_tree"], tree != "none" {
            try completeTree(tree: tree, data: data, options: o, shell: sh, attention: &attention)
        } else {
            attention.append("no simulator tree: pass --sim-tree <built ycode/ folder> or --ycode-version <release>")
        }
        if after.facts["kvm"] != "access" {
            attention.append("KVM: " + (after.checks.first { $0.id == "setup.kvm" }?.reason ?? "no access") + " " + SimPlacementPolicy.kvmFix)
        }

        // 5. A runtime.
        var root = o.runtimeRoot ?? ""
        if let src = o.copyRuntime {
            root = try copyRuntime(src, to: entry, shell: sh)
        }
        let found = env.discoverRuntimes(entry, shell: sh, extraRoots: root.isEmpty ? [] : [root])
        if root.isEmpty, let fact = after.facts["runtime_root"], fact != "none" { root = fact }
        if root.isEmpty { root = found.first?.root ?? "" }
        if root.isEmpty {
            attention.append("no runtime on the host: run the setup again with --copy-runtime <a RuntimeRoot on this computer> or --runtime-root <one on the host> "
                             + "(`ycode runtime` gets one; the IDE's runtime wizard copies one)")
            env.out("5. Runtime: none yet")
        } else {
            let v = sh.run("cat \(shq(root + "/" + RuntimeBundleReader.systemVersionPath))", timeout: 30)
            guard v.ok, let version = RemoteSimulator.productVersion(plist: v.output) else {
                throw YcrunError("\(root) is not a RuntimeRoot on \(sh.title) (no readable SystemVersion.plist)")
            }
            let platform = RemoteSimulator.productPlatform(plist: v.output) ?? "iOS"
            entry.runtimeRoot = root
            entry.runtimeVersions[root] = version
            entry.runtimePlatforms[root] = platform
            for r in found where r.root != root {
                entry.otherRuntimeRoots.append(r.root)
                if let rv = r.version { entry.runtimeVersions[r.root] = rv }
                entry.runtimePlatforms[r.root] = r.platform
            }
            env.out("5. Runtime: \(platform) \(version) at \(root)" + (entry.otherRuntimeRoots.isEmpty ? "" : " (and \(entry.otherRuntimeRoots.count) more)"))
        }

        // 7 (settings) before 6 (the device), so the device is the host's created device.
        let ide = env.store.ideSettings
        let makeDefault = !o.local && (o.makeDefault ?? (ide.destination.isEmpty || (ide.destination == destination && ide.dataDirectory == data)))
        do {
            try env.store.save(entry, makeDefault: makeDefault, tcpPort: o.tcpPort, udpPort: o.udpPort)
        } catch { throw YcrunError("cannot save the settings: \(error)") }

        // 6. A first device.
        if !o.noDevice && !entry.runtimeRoot.isEmpty {
            let ctx = SimHostContext(entry: entry, settings: env.store.settings(for: entry), shell: sh)
            let rt = ctx.runtimes[0]
            let type = try o.deviceType.map { t -> YcodeSimulatorDeviceType in
                guard let x = SimDeviceTypes.named(t) else { throw YcrunError.usage("unknown device type \(t)") }
                return x
            } ?? (rt.platform == "iOS" ? YcodeSimulatorDeviceType.supported(onRuntimeVersion: rt.version).first
                  : SimDeviceTypes.all.first { $0.platform == rt.platform && $0.runs(onRuntimeVersion: rt.version) })
            if let type {
                let devName = o.deviceName ?? type.name
                var created = env.store.createdDevices(of: entry)
                if let existing = created.first(where: { $0.name == devName && $0.runtimeRoot == rt.root }) {
                    env.out("6. First device: \(devName) exists (\(SimDevice.udid(path: data + "/devices/" + existing.directoryName)))")
                } else {
                    guard type.platform == rt.platform, type.runs(onRuntimeVersion: rt.version) else {
                        throw YcrunError("\(type.name) does not run on \(rt.name)")
                    }
                    let dir = RemoteCreatedDevice.directoryName(deviceName: entry.deviceName, typeID: type.id,
                                                                runtimeTag: RemoteSimulatorTarget.runtimeTag(root: rt.root, version: rt.version))
                    created.append(RemoteCreatedDevice(name: devName, typeID: type.id, runtimeRoot: rt.root, directoryName: dir))
                    try? env.store.saveCreatedDevices(created, of: entry)
                    env.out("6. First device: \(devName) (\(type.name), \(rt.name)) \(SimDevice.udid(path: data + "/devices/" + dir))")
                }
            }
        } else {
            env.out("6. First device: skipped")
        }
        env.out("7. Settings: " + (makeDefault ? "the IDEs' Simulator Host (\(SimHostStore.ideDomain(environment: env.environment))) and " : "")
                + env.store.file.path)

        if o.link {
            do {
                try RemoteLinkStep(env: env).link(entry, RemoteLinkOptions(hostName: name, tcpPort: o.tcpPort, udpPort: o.udpPort))
            } catch let e as YcrunError {
                attention.append("link: " + e.description)
            }
        }

        printRootSteps(after, o, data: data, destination: destination)
        if attention.isEmpty {
            env.out("Ready: `ycrun simctl\(o.local ? " --local" : makeDefault ? "" : " --host \(name)") list devices` shows the devices.")
            return YcrunExit.ok
        }
        env.err("The host is saved, but needs attention before a device can boot:")
        for a in attention { env.err("  - " + a) }
        return YcrunExit.failure
    }

    static func mark(_ s: SetupCheckState) -> String {
        switch s {
        case .ok: "ok     "
        case .missing: "MISSING"
        case .unknown: "unknown"
        case .notApplicable: "n/a    "
        }
    }

    /// Checks the tree's parts on the host, builds what a source tree lacks,
    /// copies the guest tools, and writes the launcher's and the service's
    /// keys for them.
    func completeTree(tree: String, data: String, options o: RemoteSetupOptions, shell sh: SimShell, attention: inout [String]) throws {
        let guestDir = data + "/guest-tools"
        var report = SimTreeParts.parse(sh.run(SimTreeParts.checkCommand(tree: tree, guestTools: nil), timeout: 60).text)
        // Guest tools from this computer, unless the tree has them.
        var guestFolder: String?
        if report.parts["guesttools"] == true {
            guestFolder = report.guestToolsFolder
        } else if let src = SimTreeParts.localGuestTools(option: o.guestTools, environment: env.environment, executable: env.executable) {
            try copyGuestTools(src, to: guestDir, shell: sh)
            guestFolder = guestDir
        } else if sh.run("[ -s \(shq(guestDir + "/" + SimTreeParts.guestToolsMarker)) ]", timeout: 30).ok {
            guestFolder = guestDir
        }
        let builds = report.missing.filter { $0 != "guesttools" }
        if !builds.isEmpty {
            if report.isSource && !o.noBuild {
                env.out("   building on \(sh.title): " + builds.joined(separator: ", ") + " (-j \(o.jobs); this takes a while the first time)")
                let started = Date()
                let r = sh.run(SimTreeParts.buildCommand(tree: tree, missing: builds, jobs: o.jobs), timeout: 4 * 3600)
                env.out("   built in \(Int(Date().timeIntervalSince(started))) s")
                if !r.ok { attention.append("building the simulator tree failed:\n" + SimctlFormat.lastLines(r, 15)) }
                report = SimTreeParts.parse(sh.run(SimTreeParts.checkCommand(tree: tree, guestTools: guestFolder), timeout: 60).text)
            }
            for id in report.missing where id != "guesttools" {
                let title = SimTreeParts.all.first { $0.id == id }?.title ?? id
                attention.append("the simulator tree \(tree) has no \(title)" + (report.isSource ? (o.noBuild ? " (--no-build)" : "") : " (a release tree cannot be rebuilt: install the release again)"))
            }
        }
        var keys = [("YCODE_SIM_TREE", tree), ("YCODE_SIM_DATA", data)]
        if let guestFolder { keys.append(("YCODE_SIM_GUEST_TOOLS", guestFolder)) } else { attention.append(SimTreeParts.guestToolsAdvice) }
        let conf = data + "/bin/ycode-sim.conf"
        if !sh.run(SimTreeParts.ensureKeysCommand(file: conf, keys), timeout: 60).ok { attention.append("could not write \(conf)") }
        if let guestFolder {
            let home = sh.run("printf %s \"$HOME\"", timeout: 30).text
            let envFile = (o.configDirectory.isEmpty ? home + "/.config/ycode" : o.configDirectory) + "/simhost.env"
            _ = sh.run("[ -f \(shq(envFile)) ] && " + SimTreeParts.ensureKeysCommand(file: envFile, [("YCODE_SIM_GUEST_TOOLS", guestFolder)]), timeout: 60)
        }
        let present = SimTreeParts.all.map(\.id).filter { report.parts[$0] == true }.count
        env.out("   simulator tree: \(present) of \(SimTreeParts.all.count) parts" + (guestFolder != nil ? ", guest tools in \(guestFolder!)" : ", no guest tools"))
    }

    /// Copies guest tools (a folder or a tar) into `dir` on the host, as a tar stream over the same ssh.
    func copyGuestTools(_ src: String, to dir: String, shell sh: SimShell) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: src, isDirectory: &isDir) else { throw YcrunError("--guest-tools: \(src) does not exist") }
        let tar: Data
        if isDir.boolValue {
            guard FileManager.default.fileExists(atPath: src + "/" + SimTreeParts.guestToolsMarker) else {
                throw YcrunError("--guest-tools: \(src) has no \(SimTreeParts.guestToolsMarker) (build it with packaging/flatpak/build-guest-tools.sh)")
            }
            let r = env.runner.run(["/usr/bin/env", "COPYFILE_DISABLE=1", "tar", "-cf", "-", "-C", src, "."], input: nil, timeout: 300)
            guard r.ok else { throw YcrunError("cannot pack \(src): \(SimctlFormat.lastLines(r))") }
            tar = r.output
        } else {
            guard let d = FileManager.default.contents(atPath: src) else { throw YcrunError("cannot read \(src)") }
            tar = d
        }
        let r = sh.run("rm -rf \(shq(dir)) && mkdir -p \(shq(dir)) && tar -xf - -C \(shq(dir)) && [ -s \(shq(dir + "/" + SimTreeParts.guestToolsMarker)) ]",
                       input: tar, timeout: 600)
        guard r.ok else { throw YcrunError("could not copy the guest tools to \(sh.title):\(dir): \(SimctlFormat.lastLines(r))") }
        env.out("   guest tools: copied \(src) to \(dir)")
    }

    func scriptArguments(_ o: RemoteSetupOptions, data: String, mode: String) -> [String] {
        let inv = HostSetupInvocation(dataDirectory: data, configDirectory: o.configDirectory,
                                      ycodeVersion: o.simTree != nil || o.noInstallSource ? "" : (o.ycodeVersion ?? YcodeRelease.version),
                                      tcpPort: o.tcpPort, udpPort: o.udpPort)
        var a = inv.arguments(mode: mode)
        if let t = o.simTree { a += ["--sim-tree", t] }
        if let r = o.runtimeRoot { a += ["--runtime-root", r] }
        if let m = o.minFreeGB { a += ["--min-free-gb", String(m)] }
        if o.noProbe { a += ["--no-probe"] }
        return a
    }

    /// Runs the setup script there (from standard input: nothing is left behind).
    func runScript(_ sh: SimShell, _ o: RemoteSetupOptions, data: String, mode: String) -> HostSetupOutput {
        let cmd = "bash -s -- " + scriptArguments(o, data: data, mode: mode).map(shq).joined(separator: " ")
        let r = sh.run(cmd, input: Data(HostSetupScript.text.utf8), timeout: 3600)
        var out = HostSetupOutput.parse(r.text)
        if out.facts.isEmpty { out.errors.append(SimctlFormat.lastLines(r)) }
        return out
    }

    /// The steps only root can do, for the user's own terminal.
    func printRootSteps(_ r: HostSetupOutput, _ o: RemoteSetupOptions, data: String, destination: String) {
        guard !r.rootSteps.isEmpty else { return }
        env.err("These steps need root; ycrun never runs sudo. Run them yourself on the host if you want them:")
        for s in r.rootSteps { env.err("  sudo sh -c \(shq(s.command))      # \(s.id)") }
        if !destination.isEmpty {
            let inv = HostSetupInvocation(dataDirectory: data, configDirectory: o.configDirectory)
            env.err("or save the script there (`ycode sim runtimes script`) and run: " + inv.rootCommand(destination: destination))
        }
    }

    /// Copies a RuntimeRoot from this computer into the host's runtime
    /// folder, as the IDE's wizard does (rsync --partial into
    /// `<runtimes>/<name>.incoming`, the marker, then a rename; an
    /// interrupted copy resumes).
    func copyRuntime(_ source: String, to entry: SimHostEntry, shell sh: SimShell) throws -> String {
        let svPath = source + "/" + RuntimeBundleReader.systemVersionPath
        guard let sv = FileManager.default.contents(atPath: svPath),
              let record = RuntimeBundleReader.record(systemVersion: sv, location: .host(entry.destination), owner: .external) else {
            throw YcrunError("\(source) is not a RuntimeRoot (no \(RuntimeBundleReader.systemVersionPath))")
        }
        var host = RuntimeHostSettings(destination: entry.destination, dataDirectory: entry.dataDirectory)
        host.configDirectory = entry.configDirectory
        let t = RuntimeTransfer(source: source, record: record, host: host, totalBytes: 0)
        env.out("5. Runtime: copying \(record.title) to \(sh.title):\(t.destination) (resumable)…")
        guard sh.run(t.prepareCommand, timeout: 60).ok else { throw YcrunError("cannot make \(t.incoming) on \(sh.title)") }
        let args: [String]
        if entry.isLocal {
            args = [env.rsync, "-a", "--partial", source.hasSuffix("/") ? source : source + "/", t.incoming + "/RuntimeRoot/"]
        } else {
            args = [env.rsync] + t.rsyncArguments(ssh: env.ssh)
        }
        let r = env.runner.run(args, input: nil, timeout: 6 * 3600)
        guard r.ok else { throw YcrunError("the copy stopped (rsync \(r.status)); run the same setup again to resume: \(SimctlFormat.lastLines(r))") }
        let marker = RuntimeMarker(record, source: "\(ProcessInfo.processInfo.hostName): \((source as NSString).lastPathComponent)").json
        guard sh.run(t.finishCommand(markerJSON: marker), timeout: 120).ok else { throw YcrunError("the runtime was copied but could not be put in place") }
        return t.destination + "/RuntimeRoot"
    }

    // MARK: list, status, test, remove

    func list() -> Int32 {
        let local = SimPlacementPolicy.localSupport(env.machine, macOSRunsLocally: env.macOSRunsLocally)
        let decision = try? env.decide(SimPlacementRequest())
        let hosts = env.store.remoteHosts()
        env.out("NAME\tDESTINATION\tDATA\tDEFAULT")
        if local.supported {
            let l = env.store.localHost()
            env.out("local\t(this machine)\t\(l.dataDirectory)\t\(decision?.placement == .local ? "yes" : "")")
        }
        for (i, h) in hosts.enumerated() {
            let isDefault = decision?.placement == .remote(host: nil) && i == 0
            env.out("\(h.name)\t\(h.destination)\t\(h.dataDirectory)\t\(isDefault ? "yes" : "")" + (env.store.isIDEHost(h) ? "\t(the IDEs' host)" : ""))
        }
        env.out("Devices run " + (decision?.placement == .local ? "on this machine" : hosts.isEmpty ? "on a simulator host once one is set up (`ycrun remote setup`)" : "on \(hosts[0].name)")
                + ": " + (decision?.reason ?? local.reason))
        return YcrunExit.ok
    }

    func host(_ name: String?) throws -> SimHostEntry {
        if name == "local" { return env.store.localHost() }
        guard let h = env.store.remoteHost(named: name) else {
            throw YcrunError(name.map { "No simulator host named \($0) (`ycrun remote list`)." } ?? "No simulator host is set up (`ycrun remote setup`).")
        }
        return h
    }

    func status(_ name: String?) throws -> Int32 {
        let h = try host(name)
        let ctx = try env.context(h.isLocal ? .local : .remote(host: h.name))
        env.out("\(h.name): \(h.isLocal ? "this machine" : h.destination), data \(h.dataDirectory)" + (env.store.isIDEHost(h) ? " (the IDEs' host)" : ""))
        var o = RemoteSetupOptions()
        o.configDirectory = h.configDirectory
        o.noProbe = true
        o.noInstallSource = true
        let r = runScript(ctx.shell, o, data: h.dataDirectory, mode: "report")
        if r.facts.isEmpty { env.err("cannot run the checks on \(ctx.shell.title): " + r.errors.joined(separator: "; ")); return YcrunExit.failure }
        for c in r.checks { env.out("  " + Self.mark(c.state) + " " + HostSetupOutput.title(of: c.id) + ": " + c.reason) }
        env.out("Runtimes:")
        for rt in ctx.runtimes { env.out("  \(rt.name) - \(rt.identifier) at \(rt.root)") }
        env.out("Devices:")
        for d in ctx.withStates() { env.out("  \(d.name) (\(d.udid)) (\(d.state.rawValue))") }
        return YcrunExit.ok
    }

    func test(_ name: String?) throws -> Int32 {
        let h = try host(name)
        let sh = env.shell(for: h)
        var failed = false
        func line(_ ok: Bool, _ what: String) { env.out((ok ? "ok    " : "FAILED") + " " + what); if !ok { failed = true } }
        let login = sh.run("printf ycrun-ok", timeout: 30)
        if !h.isLocal {
            line(login.ok && login.text == "ycrun-ok", "ssh login with a key to \(h.destination)")
            guard login.ok else {
                env.err(SSHKeyAdvice.text(destination: h.destination, sshError: login.errorText, publicKey: SSHKeyAdvice.publicKey()))
                return YcrunExit.failure
            }
        }
        let settings = env.store.settings(for: h)
        let q = shq
        let probe = sh.run("""
            uname -m; [ -x \(q(settings.simdPath)) ] && echo launcher-ok; \
            c=\(q((settings.simdPath as NSString).deletingLastPathComponent + "/ycode-sim.conf")); [ -f "$c" ] && . "$c" && echo conf-ok; \
            [ -n "${YCODE_SIM_TREE:-}" ] && "$YCODE_SIM_TREE/.build/release/ycode-simd" --version 2>&1 | head -1; \
            echo "TREEPATH ${YCODE_SIM_TREE:-}"; echo "GUESTPATH ${YCODE_SIM_GUEST_TOOLS:-}"; \
            [ -e \(q(settings.runtimeRoot + "/sbin/launchd_sim")) ] && echo runtime-ok; \
            [ -r /dev/kvm ] && [ -w /dev/kvm ] && echo kvm-ok; true
            """, timeout: 60)
        let t = probe.text
        let lines = t.split(separator: "\n").map(String.init)
        let arch = lines.first ?? "?"
        line(arch == "aarch64" || arch == "arm64", "architecture \(arch)")
        line(t.contains("launcher-ok"), "launcher \(settings.simdPath)")
        line(t.contains("conf-ok"), "launcher configuration ycode-sim.conf (YCODE_SIM_TREE, YCODE_SIM_DATA)")
        let simd = lines.first { $0.hasPrefix("ycode-simd ") }
        line(simd != nil, "ycode-simd starts" + (simd.map { " (\($0))" } ?? ""))
        let tree = lines.first { $0.hasPrefix("TREEPATH ") }.map { String($0.dropFirst(9)) } ?? ""
        let guest = lines.first { $0.hasPrefix("GUESTPATH ") }.map { String($0.dropFirst(10)) } ?? ""
        if !tree.isEmpty {
            let parts = SimTreeParts.parse(sh.run(SimTreeParts.checkCommand(tree: tree, guestTools: guest.isEmpty ? nil : guest), timeout: 60).text)
            for p in SimTreeParts.all where p.id != "simd" { line(parts.parts[p.id] == true, p.title) }
            line(parts.parts["guesttools"] == true, "guest tools (ylaunch and the agents) in \(parts.guestToolsFolder)"
                 + (parts.parts["guesttools"] == true ? "" : ": apps cannot be installed or launched"))
        }
        line(!settings.runtimeRoot.isEmpty && t.contains("runtime-ok"), "runtime \(settings.runtimeRoot.isEmpty ? "(none set)" : settings.runtimeRoot)")
        line(t.contains("kvm-ok"), "/dev/kvm is usable" + (t.contains("kvm-ok") ? "" : ": " + SimPlacementPolicy.kvmFix))
        return failed ? YcrunExit.failure : YcrunExit.ok
    }

    func remove(_ name: String) throws -> Int32 {
        let h = try host(name)
        let wasIDE = env.store.isIDEHost(h)
        do { try env.store.remove(h) } catch { throw YcrunError("cannot save the settings: \(error)") }
        env.out("Removed \(h.name)" + (wasIDE ? " (and the IDEs' Simulator Host settings)" : "") + ". Nothing on the host changed; its data folder \(h.dataDirectory) stays.")
        return YcrunExit.ok
    }
    /// `link <name> [--tcp-port N --udp-port N]` (§8.3).
    func link(_ a: [String]) throws -> Int32 {
        var name: String?, tcp: Int?, udp: Int?
        var i = 0
        while i < a.count {
            switch a[i] {
            case "--tcp-port", "--udp-port":
                guard i + 1 < a.count, let n = Int(a[i + 1]), n > 0 else { throw YcrunError.usage("\(a[i]) needs a port number") }
                if a[i] == "--tcp-port" { tcp = n } else { udp = n }
                i += 1
            default:
                guard name == nil, !a[i].hasPrefix("-") else { throw YcrunError.usage("link <name> [--tcp-port N --udp-port N]") }
                name = a[i]
            }
            i += 1
        }
        let h = try host(name)
        env.out("Linking \(h.name) (\(h.isLocal ? "this machine" : h.destination)) with this computer over Ycode's link")
        try RemoteLinkStep(env: env).link(h, RemoteLinkOptions(hostName: h.name, tcpPort: tcp, udpPort: udp))
        return YcrunExit.ok
    }
}
