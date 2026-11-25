// `ycrun simctl <verb>` (specs/ide/ycrun.md §7): simctl's public verbs,
// argument order, `booted` and name/UDID device selection, and `-j` JSON,
// on Ycode's own simulator. Each verb is built on the launcher the IDE runs
// (scripts/ycode-sim.sh) through the same commands (`RemoteSimulator`), on
// this machine or on a simulator host. A verb Ycode's simulator cannot do
// yet says so and exits 69.

import Foundation
import YcodeBuild
import YcodeIDECore

public struct Simctl {
    public var env: YcrunEnvironment
    public var request: SimPlacementRequest

    public init(env: YcrunEnvironment, request: SimPlacementRequest = SimPlacementRequest()) {
        self.env = env
        self.request = request
    }

    /// How long `launch` waits for the app (a first boot sets the device up for minutes).
    public var launchTimeout: TimeInterval = 900
    /// How long `shutdown` lets the launcher save the device.
    public var shutdownGrace = 150

    // MARK: Dispatch

    public func run(_ arguments: [String]) -> Int32 {
        guard let verb = arguments.first else {
            env.out(SimctlHelp.overview)
            return YcrunExit.usage
        }
        let args = Array(arguments.dropFirst())
        if args.first == "--help" || args.first == "-h" || verb == "help" {
            let topic = verb == "help" ? args.first ?? "" : verb
            env.out(SimctlHelp.text(for: topic))
            return YcrunExit.ok
        }
        do {
            try dispatch(verb, args)
            return YcrunExit.ok
        } catch let e as YcrunError {
            env.err("ycrun simctl \(verb): \(e.description)")
            return e.status
        } catch {
            env.err("ycrun simctl \(verb): \(error)")
            return YcrunExit.failure
        }
    }

    func dispatch(_ verb: String, _ a: [String]) throws {
        switch verb {
        case "list": try list(a)
        case "create": try create(a)
        case "delete": try delete(a)
        case "rename": try rename(a)
        case "boot": try boot(a)
        case "bootstatus": try bootstatus(a)
        case "shutdown": try shutdown(a)
        case "reboot": try reboot(a)
        case "erase": try erase(a)
        case "install": try install(a)
        case "launch": try launch(a)
        case "io": try io(a)
        case "location": try settingsCommand("location", a)
        case "ui": try settingsCommand("ui", a)
        case "pair": try pairing("pair", a, count: 2)
        case "unpair": try pairing("unpair", a, count: 1)
        case "pair_activate": try pairing("pair-activate", a, count: 1)
        case "view": try view(a)
        default:
            if let why = SimctlHelp.unsupported[verb] { throw YcrunError.unsupported("`simctl \(verb)`", why) }
            throw YcrunError.usage("unknown verb `\(verb)`; `ycrun simctl help` lists the verbs")
        }
    }

    // MARK: Hosts

    func context() throws -> SimHostContext {
        try env.context(env.decide(request).placement)
    }

    /// The device an argument names (with the devices' states).
    func device(_ arg: String, in ctx: SimHostContext) throws -> SimDevice {
        let list = ctx.withStates()
        switch SimHostContext.find(arg, in: list) {
        case .found(let d): return d
        case .invalid(let why): throw YcrunError(why)
        }
    }

    /// Fails unless the host's launcher is in place.
    func requireLauncher(_ ctx: SimHostContext) throws {
        let r = ctx.shell.run("[ -x \(shq(ctx.settings.simdPath)) ]", timeout: 30)
        if r.status == 255 { throw YcrunError("cannot reach \(ctx.shell.title) with ssh: \(r.errorText.trimmingCharacters(in: .whitespacesAndNewlines))") }
        guard r.ok else {
            throw YcrunError(ctx.entry.isLocal
                ? "Ycode's simulator is not set up on this machine (no launcher at \(ctx.settings.simdPath)): run `ycrun remote setup --local`."
                : "\(ctx.label) has no launcher at \(ctx.settings.simdPath): run `ycrun remote setup` for it again.")
        }
    }

    // MARK: list

    func list(_ a: [String]) throws {
        var json = false, verbose = false, allHosts = false
        var what: String?, search: String?, jsonFile: String?
        for x in a {
            if x.hasPrefix("--json-output=") { json = true; jsonFile = String(x.dropFirst("--json-output=".count)); continue }
            if x.hasPrefix("--json-fd=") { throw YcrunError.unsupported("`list --json-fd`", "use --json-output=<file> or standard output") }
            switch x {
            case "-e", "--no-escape-slashes": continue
            case "-j", "--json": json = true
            case "-v": verbose = true
            case "--all-hosts": allHosts = true
            case "devices", "devicetypes", "runtimes", "pairs": what = x
            default:
                guard search == nil, !x.hasPrefix("-") else { throw YcrunError.usage("list [-j|--json] [-v] [devices|devicetypes|runtimes|pairs] [<search term>|available]") }
                search = x
            }
        }
        _ = verbose
        if search == "available" { search = nil }
        var contexts: [SimHostContext] = []
        if allHosts {
            if SimPlacementPolicy.localSupport(env.machine, macOSRunsLocally: env.macOSRunsLocally).supported, let c = try? env.context(.local) { contexts.append(c) }
            for h in env.store.remoteHosts() { if let c = try? env.context(.remote(host: h.name)) { contexts.append(c) } }
        } else if what == "devicetypes" {
            // Device types are ycode-simd's own: no host needed.
        } else {
            contexts = [try context()]
        }
        let wants = { (s: String) in what == nil || what == s }
        let types = SimDeviceTypes.all.filter { search == nil || SimctlFormat.matches(search!, $0.name, $0.id) }
        var runtimes: [(SimHostContext, SimRuntime)] = []
        var devices: [(SimHostContext, SimDevice)] = []
        var pairs: [(SimHostContext, String)] = []
        for ctx in contexts {
            if wants("runtimes") {
                let found = env.discoverRuntimes(ctx.entry, shell: ctx.shell, extraRoots: ctx.settings.allRuntimeRoots)
                for rt in ctx.runtimes {
                    var r = rt
                    if let f = found.first(where: { $0.root == rt.root }) { r.build = f.build; r.version = r.version ?? f.version }
                    if search == nil || SimctlFormat.matches(search!, r.name, r.identifier) { runtimes.append((ctx, r)) }
                }
            }
            if wants("devices") {
                for d in ctx.withStates() where search == nil || SimctlFormat.matches(search!, d.name, d.udid) { devices.append((ctx, d)) }
            }
            if wants("pairs") {
                let r = ctx.shell.run("env YCODE_SIM_DEVICE_SET=\(shq(ctx.data + "/devices")) \(shq(ctx.settings.simdPath)) list-pairs --json", timeout: 60)
                if r.ok { pairs.append((ctx, r.text)) }
            }
        }
        if json {
            var top: [String: Any] = [:]
            if wants("devicetypes") { top["devicetypes"] = types.map(SimctlFormat.deviceTypeJSON) }
            if wants("runtimes") { top["runtimes"] = runtimes.map { SimctlFormat.runtimeJSON($1, ctx: $0) } }
            if wants("devices") {
                var byRuntime: [String: [[String: Any]]] = [:]
                for (ctx, d) in devices { byRuntime[d.runtime.identifier, default: []].append(SimctlFormat.deviceJSON(d, ctx: ctx)) }
                top["devices"] = byRuntime
            }
            if wants("pairs") {
                var merged: [String: Any] = [:]
                for (_, text) in pairs {
                    if let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], let p = o["pairs"] as? [String: Any] {
                        merged.merge(p) { a, _ in a }
                    }
                }
                top["pairs"] = merged
            }
            let text = SimctlFormat.json(top)
            if let jsonFile {
                do { try env.writeFile(jsonFile, Data((text + "\n").utf8)) } catch { throw YcrunError("cannot write \(jsonFile): \(error.localizedDescription)") }
            } else {
                env.out(text)
            }
            return
        }
        if wants("devicetypes") {
            env.out("== Device Types ==")
            for t in types { env.out("\(t.name) (\(t.id))") }
        }
        if wants("runtimes") {
            env.out("== Runtimes ==")
            for (ctx, r) in runtimes { env.out(SimctlFormat.runtimeLine(r, ctx: ctx)) }
        }
        if wants("devices") {
            env.out("== Devices ==")
            var groups: [(String, [SimDevice])] = []
            for (ctx, d) in devices {
                let title = "-- \(d.runtime.name) (\(SimctlFormat.location(ctx))) --"
                if let i = groups.firstIndex(where: { $0.0 == title }) { groups[i].1.append(d) } else { groups.append((title, [d])) }
            }
            for (title, list) in groups {
                env.out(title)
                for d in list { env.out("    \(d.name) (\(d.udid)) (\(d.state.rawValue))") }
            }
        }
        if wants("pairs") {
            env.out("== Device Pairs ==")
            for (_, text) in pairs {
                guard let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], let p = o["pairs"] as? [String: [String: Any]] else { continue }
                for (id, v) in p.sorted(by: { $0.key < $1.key }) {
                    let w = v["watch"] as? [String: String] ?? [:], ph = v["phone"] as? [String: String] ?? [:]
                    env.out("\(id) \(v["state"] as? String ?? "")")
                    env.out("    Watch: \(w["name"] ?? "?") (\(w["udid"] ?? "?")) (\(w["state"] ?? "?"))")
                    env.out("    Phone: \(ph["name"] ?? "?") (\(ph["udid"] ?? "?")) (\(ph["state"] ?? "?"))")
                }
            }
        }
    }

    // MARK: create, delete, rename

    func create(_ a: [String]) throws {
        guard a.count == 2 || a.count == 3 else { throw YcrunError.usage("create <name> <device type id> [<runtime id>]") }
        let name = a[0]
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw YcrunError.usage("the device needs a name") }
        guard let type = SimDeviceTypes.named(a[1]) else {
            throw YcrunError("Invalid device type: \(a[1]) (`ycrun simctl list devicetypes` lists them)")
        }
        let ctx = try context()
        let runtime: SimRuntime
        if a.count == 3 {
            guard let r = ctx.runtimes.first(where: { $0.matches(a[2]) }) else {
                throw YcrunError("Invalid runtime: \(a[2]) (`ycrun simctl list runtimes` lists \(ctx.label)'s)")
            }
            runtime = r
        } else {
            let compatible = ctx.runtimes.filter { $0.platform == type.platform && type.runs(onRuntimeVersion: $0.version) }
            guard let r = compatible.max(by: { DestinationCatalog.compareVersions($0.version ?? "0", $1.version ?? "0") == .orderedAscending }) else {
                throw YcrunError("\(ctx.label) has no \(type.platform) runtime that runs \(type.name); add one with `ycrun remote setup`.")
            }
            runtime = r
        }
        guard runtime.platform == type.platform, type.runs(onRuntimeVersion: runtime.version) else {
            throw YcrunError("Incompatible device: \(type.name) does not run on \(runtime.name)")
        }
        let dir = RemoteCreatedDevice.directoryName(deviceName: ctx.settings.deviceName, typeID: type.id,
                                                    runtimeTag: RemoteSimulatorTarget.runtimeTag(root: runtime.root, version: runtime.version))
        var created = env.store.createdDevices(of: ctx.entry)
        created.append(RemoteCreatedDevice(name: name, typeID: type.id, runtimeRoot: runtime.root, directoryName: dir))
        do { try env.store.saveCreatedDevices(created, of: ctx.entry) } catch { throw YcrunError("cannot save the device: \(error)") }
        env.out(SimDevice.udid(path: ctx.data + "/devices/" + dir))
    }

    func delete(_ a: [String]) throws {
        guard !a.isEmpty else { throw YcrunError.usage("delete <device> [... <device n>] | unavailable | all") }
        let ctx = try context()
        var created = env.store.createdDevices(of: ctx.entry)
        let list = ctx.withStates()
        var targets: [SimDevice] = []
        if a == ["unavailable"] {
            let shown = Set(list.map(\.directory))
            let gone = created.filter { !shown.contains($0.directoryName) }
            created.removeAll { c in gone.contains(c) }
            try save(created, ctx)
            for g in gone { _ = ctx.shell.run("exec \(shq(ctx.settings.simdPath)) --erase --device \(shq(ctx.data + "/devices/" + g.directoryName))", timeout: 300) }
            return
        }
        if a == ["all"] { targets = list } else {
            for x in a {
                switch SimHostContext.find(x, in: list) {
                case .found(let d): targets.append(d)
                case .invalid(let why): throw YcrunError(why)
                }
            }
        }
        if let busy = targets.first(where: { $0.state != .shutdown }) {
            throw YcrunError("Unable to delete a device in current state: \(busy.state.rawValue) (\(busy.name)); shut it down first")
        }
        for d in targets {
            let r = ctx.shell.run(ctx.remote(d).eraseCommand, timeout: 300)
            guard r.ok else { throw YcrunError("could not erase \(d.name): \(SimctlFormat.lastLines(r))") }
            if d.isCreated {
                created.removeAll { $0.directoryName == d.directory }
            } else {
                env.err("\(d.name) is \(d.runtime.name)'s own device: its contents were erased; it stays listed while the runtime is set up.")
            }
            _ = ctx.shell.run("rm -f \(shq(ctx.appsFile(d))) \(shq(ctx.logFile(d)))", timeout: 30)
        }
        try save(created, ctx)
    }

    func rename(_ a: [String]) throws {
        guard a.count == 2 else { throw YcrunError.usage("rename <device> <new name>") }
        let ctx = try context()
        let d = try device(a[0], in: ctx)
        guard d.isCreated else { throw YcrunError.unsupported("renaming a runtime's own device", "create a device with the name you want instead") }
        var created = env.store.createdDevices(of: ctx.entry)
        guard let i = created.firstIndex(where: { $0.directoryName == d.directory }) else { throw YcrunError("Invalid device: \(a[0])") }
        created[i].name = a[1]
        try save(created, ctx)
    }

    func save(_ created: [RemoteCreatedDevice], _ ctx: SimHostContext) throws {
        do { try env.store.saveCreatedDevices(created, of: ctx.entry) } catch { throw YcrunError("cannot save the devices: \(error)") }
    }

    // MARK: boot, shutdown, erase

    func boot(_ a: [String]) throws {
        var wait = false
        let rest = try a.filter { x in
            if x == "--wait" || x == "-w" { wait = true; return false }
            if x.hasPrefix("--arch=") {
                guard x == "--arch=arm64" else { throw YcrunError.unsupported("`boot \(x)`", "Ycode's devices are arm64") }
                return false
            }
            if x.hasPrefix("--disabledJob=") || x.hasPrefix("--enabledJob=") || x == "--checked-allocations" {
                throw YcrunError.unsupported("`boot \(x.split(separator: "=")[0])`", x == "--checked-allocations" ? "" : "the IDE's Lean boot setting chooses the services")
            }
            return true
        }
        guard rest.count == 1 else { throw YcrunError.usage("boot <device> [--arch=arm64] [--wait]") }
        let ctx = try context()
        try requireLauncher(ctx)
        let d = try device(rest[0], in: ctx)
        guard d.state == .shutdown else { throw YcrunError("Unable to boot device in current state: \(d.state.rawValue)") }
        try start(d, ctx, extra: [])
        if wait { try waitBooted(d, ctx, timeout: launchTimeout) }
    }

    /// Starts the launcher for a device, detached on its host (its own
    /// session, its output in `<data>/ycrun/<device>.log`, its pid in
    /// `.pid`), with the display server Device Hub and `view` use.
    func start(_ d: SimDevice, _ ctx: SimHostContext, extra: [String]) throws {
        let r = ctx.shell.run(Self.startCommand(d, ctx, extra: extra), timeout: 60)
        if r.status == 3 { throw YcrunError("Unable to boot device in current state: Booted") }
        guard r.ok else { throw YcrunError("could not start \(d.name) on \(ctx.shell.title): \(SimctlFormat.lastLines(r))") }
        // A launcher that cannot start (no tree, no runtime) ends at once: say why.
        env.sleep(3)
        let check = ctx.shell.run("kill -0 \"$(cat \(shq(ctx.pidFile(d))))\" 2>/dev/null || { tail -n 15 \(shq(ctx.logFile(d))); rm -f \(shq(ctx.pidFile(d))); exit 1; }",
                                 timeout: 30)
        guard check.ok else {
            let kvm = check.text.contains("/dev/kvm") && check.text.contains("Permission denied")
            throw YcrunError("\(d.name) stopped while starting:\n" + check.text
                             + (kvm ? "\nThe host's user cannot open /dev/kvm. " + SimPlacementPolicy.kvmFix : ""))
        }
    }

    public static func startCommand(_ d: SimDevice, _ ctx: SimHostContext, extra: [String]) -> String {
        let pid = shq(ctx.pidFile(d)), log = shq(ctx.logFile(d))
        let launch = ctx.remote(d).startCommand + extra.map { " " + shq($0) }.joined()
        return "mkdir -p \(shq(ctx.stateDirectory)) && "
            + "if [ -f \(pid) ] && kill -0 \"$(cat \(pid))\" 2>/dev/null; then exit 3; fi; "
            + "nohup setsid sh -c \(shq(launch)) > \(log) 2>&1 < /dev/null & echo $! > \(pid); echo \"YCRUN-PID $!\""
    }

    func waitBooted(_ d: SimDevice, _ ctx: SimHostContext, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let s = ctx.withStates([d]).first?.state ?? .shutdown
            if s == .booted { return }
            if s == .shutdown { throw YcrunError("\(d.name) stopped while booting:\n" + ctx.shell.run("tail -n 15 \(shq(ctx.logFile(d)))", timeout: 30).text) }
            env.sleep(2)
        }
        throw YcrunError("\(d.name) did not finish booting within \(Int(timeout)) s")
    }

    func bootstatus(_ a: [String]) throws {
        var bootIfNeeded = false
        if a.contains("-c") { throw YcrunError.unsupported("`bootstatus -c`") }
        let rest = a.filter { x in if x == "-b" { bootIfNeeded = true; return false }; return x != "-d" }
        guard rest.count == 1 else { throw YcrunError.usage("bootstatus <device> [-b]") }
        let ctx = try context()
        let d = try device(rest[0], in: ctx)
        if d.state == .booted { env.out("Device already booted, nothing to do."); return }
        if d.state == .shutdown {
            guard bootIfNeeded else { throw YcrunError("Waiting on a device that is not booting; pass -b to boot it") }
            try requireLauncher(ctx)
            try start(d, ctx, extra: [])
        }
        env.out("Monitoring boot status for \(d.name) (\(d.udid)).")
        try waitBooted(d, ctx, timeout: launchTimeout)
        env.out("Device booted.")
    }

    func shutdown(_ a: [String]) throws {
        guard a.count == 1 else { throw YcrunError.usage("shutdown <device> | all") }
        let ctx = try context()
        let targets: [SimDevice]
        if a[0] == "all" { targets = ctx.withStates().filter { $0.state != .shutdown } } else {
            let d = try device(a[0], in: ctx)
            guard d.state != .shutdown else { throw YcrunError("Unable to shutdown device in current state: Shutdown") }
            targets = [d]
        }
        for d in targets { try stop(d, ctx) }
    }

    public static func stopCommand(_ d: SimDevice, _ ctx: SimHostContext, grace: Int) -> String {
        YcrunDeviceFiles.stopCommand(pidFile: ctx.pidFile(d), grace: grace)
    }

    /// SIGTERM to the launcher ycrun started (with warm boot it saves the
    /// device first, as for the IDE's Stop), waiting for it to end; after the
    /// grace its session is killed. Not SIGINT: a command started in the
    /// background by a non-interactive shell ignores SIGINT, and a shell
    /// cannot trap a signal ignored at its start, so the launcher would never
    /// see it (ycode-simhost stops devices with SIGTERM for the same reason).
    func stop(_ d: SimDevice, _ ctx: SimHostContext) throws {
        let r = ctx.shell.run(Self.stopCommand(d, ctx, grace: shutdownGrace), timeout: TimeInterval(shutdownGrace + 60))
        if r.status == 3 {
            throw YcrunError("\(d.name) was not booted by ycrun (Ycode's IDE or another program runs it): shut it down there")
        }
        guard r.ok else { throw YcrunError("could not shut down \(d.name): \(SimctlFormat.lastLines(r))") }
        if r.text.contains("YCRUN-KILLED") { env.err("\(d.name) did not stop within \(shutdownGrace) s and was ended without a save.") }
    }

    func reboot(_ a: [String]) throws {
        guard a.count == 1 else { throw YcrunError.usage("reboot <device>") }
        let ctx = try context()
        let d = try device(a[0], in: ctx)
        guard d.state != .shutdown else { throw YcrunError("Unable to reboot device in current state: Shutdown") }
        try stop(d, ctx)
        try start(d, ctx, extra: [])
    }

    func erase(_ a: [String]) throws {
        guard a.count == 1 else { throw YcrunError.usage("erase <device> | all") }
        let ctx = try context()
        let targets = a[0] == "all" ? ctx.withStates() : [try device(a[0], in: ctx)]
        if let busy = targets.first(where: { $0.state != .shutdown }) {
            throw YcrunError("Unable to erase contents and settings in current state: \(busy.state.rawValue) (\(busy.name))")
        }
        for d in targets {
            let r = ctx.shell.run(ctx.remote(d).eraseCommand, timeout: 300)
            guard r.ok else { throw YcrunError("could not erase \(d.name): \(SimctlFormat.lastLines(r))") }
            _ = ctx.shell.run("rm -f \(shq(ctx.appsFile(d)))", timeout: 30)
        }
    }

    // MARK: install, launch

    /// The app's bundle identifier (its Info.plist, XML or binary).
    public static func bundleIdentifier(app: String) -> String? {
        guard let d = FileManager.default.contents(atPath: app + "/Info.plist"),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return nil }
        return p["CFBundleIdentifier"] as? String
    }

    func install(_ a: [String]) throws {
        guard a.count == 2 else { throw YcrunError.usage("install <device> <path to .app>") }
        let app = URL(fileURLWithPath: a[1]).standardizedFileURL
        guard app.pathExtension == "app", FileManager.default.fileExists(atPath: app.path) else { throw YcrunError("Invalid app bundle: \(a[1])") }
        guard let id = Self.bundleIdentifier(app: app.path) else { throw YcrunError("\(app.lastPathComponent) has no CFBundleIdentifier in its Info.plist") }
        let ctx = try context()
        let d = try device(a[0], in: ctx)
        let remotePath = ctx.data + "/apps/" + app.lastPathComponent
        let mk = ctx.shell.run("mkdir -p \(shq(remotePath)) \(shq(ctx.stateDirectory))", timeout: 60)
        guard mk.ok else { throw YcrunError("cannot reach \(ctx.shell.title): \(SimctlFormat.lastLines(mk))") }
        let up = env.runner.run(ctx.shell.uploadArguments(localFolder: app.path, remotePath: remotePath), input: nil, timeout: 1800)
        guard up.ok else { throw YcrunError("could not copy \(app.lastPathComponent) to \(ctx.shell.title): \(SimctlFormat.lastLines(up))") }
        let apps = shq(ctx.appsFile(d))
        let line = id + "\t" + remotePath
        let rec = ctx.shell.run("touch \(apps) && { grep -v \(shq("^" + NSRegularExpression.escapedPattern(for: id) + "\t")) \(apps); printf '%s\\n' \(shq(line)); } > \(apps).new && mv \(apps).new \(apps)", timeout: 30)
        guard rec.ok else { throw YcrunError("could not record the app on \(ctx.shell.title): \(SimctlFormat.lastLines(rec))") }
        env.err("\(id) is on \(d.name)'s host; Ycode's simulator installs it when it is launched (`ycrun simctl launch \(a[0]) \(id)`).")
    }

    func launch(_ a: [String]) throws {
        var rest: [String] = []
        var i = 0
        while i < a.count {
            let x = a[i]
            if rest.count >= 2 { rest.append(x); i += 1; continue }   // the app's own arguments
            switch x {
            case "--terminate-running-process": break
            case "-a":
                i += 1
                guard i < a.count, a[i] == "arm64" else { throw YcrunError.unsupported("`launch -a \(i < a.count ? a[i] : "")`", "Ycode's devices are arm64") }
            case "--arch=arm64": break
            case "--checked-allocations": throw YcrunError.unsupported("`launch --checked-allocations`")
            case "-w", "--wait-for-debugger": throw YcrunError.unsupported("`launch --wait-for-debugger`", "run the app under the debugger from Ycode instead")
            case "--console", "--console-pty": throw YcrunError.unsupported("`launch \(x)`", "the app's output is in the device's run log")
            default:
                if x.hasPrefix("--stdout=") || x.hasPrefix("--stderr=") { throw YcrunError.unsupported("`launch \(x.split(separator: "=")[0])`", "the app's output is in the device's run log") }
                if x.hasPrefix("-") { throw YcrunError.usage("unknown option \(x)") }
                rest.append(x)
            }
            i += 1
        }
        guard rest.count >= 2 else { throw YcrunError.usage("launch <device> <bundle identifier> [<argv 1> <argv 2> ... <argv n>]") }
        let ctx = try context()
        try requireLauncher(ctx)
        var d = try device(rest[0], in: ctx)
        let id = rest[1]
        let apps = ctx.shell.run("cat \(shq(ctx.appsFile(d))) 2>/dev/null", timeout: 30).text
        guard let path = apps.split(whereSeparator: \.isNewline).compactMap({ l -> String? in
            let f = l.split(separator: "\t", maxSplits: 1).map(String.init)
            return f.count == 2 && f[0] == id ? f[1] : nil
        }).last else {
            throw YcrunError("\(id) is not installed on \(d.name): install it first with `ycrun simctl install \(rest[0]) <App.app>`")
        }
        if d.state != .shutdown {
            env.err("Restarting \(d.name) to launch \(id): Ycode's simulator installs and launches apps as the device starts (with warm boot it resumes in seconds).")
            try stop(d, ctx)
            d.state = .shutdown
        }
        // SIMCTL_CHILD_<NAME>=value in this environment becomes <NAME>=value in the app's (simctl's convention).
        let childEnv = env.environment.filter { $0.key.hasPrefix("SIMCTL_CHILD_") }.sorted { $0.key < $1.key }
            .flatMap { ["--app-env", String($0.key.dropFirst("SIMCTL_CHILD_".count)) + "=" + $0.value] }
        let extra = ["--install-app", path, "--launch", id, "--environment-overrides"] + rest.dropFirst(2).flatMap { ["--app-arg", $0] } + childEnv
        try start(d, ctx, extra: extra)
        let pid = try waitLaunched(d, ctx, timeout: launchTimeout)
        env.out("\(id): \(pid)")
    }

    /// The launched app's pid from the run log (the IDE's own reading of a
    /// launcher's lines, `RemoteSimulator.phase`).
    public static func launchedPID(inLog text: String) -> (pid: Int?, failure: String?) {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.contains("app install: failed") || line.contains("app launch: failed") { return (nil, line) }
            guard RemoteSimulator.phase(after: line, current: .launching(retries: 0)) == .running,
                  let r = line.range(of: #"pid (\d+)"#, options: .regularExpression) else { continue }
            return (Int(line[r].dropFirst(4)), nil)
        }
        return (nil, nil)
    }

    func waitLaunched(_ d: SimDevice, _ ctx: SimHostContext, timeout: TimeInterval) throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        let log = shq(ctx.logFile(d)), pid = shq(ctx.pidFile(d))
        while Date() < deadline {
            let r = ctx.shell.run("cat \(log); kill -0 \"$(cat \(pid))\" 2>/dev/null || echo YCRUN-ENDED", timeout: 60)
            let found = Self.launchedPID(inLog: r.text)
            if let p = found.pid { return p }
            if let f = found.failure { throw YcrunError(f) }
            if r.text.hasSuffix("YCRUN-ENDED\n") {
                throw YcrunError("\(d.name) stopped before the app launched:\n" + r.text.split(separator: "\n").suffix(15).joined(separator: "\n"))
            }
            env.sleep(2)
        }
        throw YcrunError("the app did not launch within \(Int(timeout)) s; the run log is \(ctx.logFile(d)) on \(ctx.shell.title)")
    }

    // MARK: io

    func io(_ a: [String]) throws {
        guard a.count >= 2 else { throw YcrunError.usage("io <device> screenshot [--type=png] [--display=internal|LCD|LCD-1] <file or ->") }
        switch a[1] {
        case "screenshot": try screenshot(a[0], Array(a.dropFirst(2)))
        case "recordVideo": throw YcrunError.unsupported("`io recordVideo`", "record from the viewer (`ycrun simctl view`, Shift-Command-R) instead")
        case "enumerate", "poll": throw YcrunError.unsupported("`io \(a[1])`")
        default: throw YcrunError.usage("io <device> screenshot …")
        }
    }

    /// simctl's `--display` → ycode-simd's display: internal (the default) is
    /// the shown integrated display; LCD and LCD-1 name a foldable's two.
    public static func displayName(_ s: String?) throws -> String {
        switch s {
        case nil, "internal", "primary", "1", "Internal-1": return "active"
        case "active", "LCD", "LCD-1": return s!
        case "external": throw YcrunError.unsupported("`--display=external`", "Ycode's devices have no external display")
        default: throw YcrunError.usage("--display=internal|LCD|LCD-1")
        }
    }

    func screenshot(_ deviceArg: String, _ a: [String]) throws {
        var display: String?, file: String?
        for x in a {
            if x.hasPrefix("--type=") {
                guard x.lowercased() == "--type=png" else { throw YcrunError.unsupported("`\(x)`", "screenshots are PNG") }
            } else if x.hasPrefix("--display=") {
                display = String(x.dropFirst("--display=".count))
            } else if x.hasPrefix("--mask=") {
                // The device's screen has no mask to apply; every mask gives the plain screen.
            } else if file == nil {
                file = x
            } else {
                throw YcrunError.usage("io <device> screenshot [--type=png] [--display=…] <file or ->")
            }
        }
        guard let file else { throw YcrunError.usage("io <device> screenshot needs a file (or - for standard output)") }
        let name = try Self.displayName(display)
        let ctx = try context()
        let d = try device(deviceArg, in: ctx)
        guard d.state == .booted else { throw YcrunError("Unable to take a screenshot of a device in current state: \(d.state.rawValue)") }
        let r = ctx.shell.run(ctx.remote(d).screenshotCommand(display: name), timeout: 120)
        guard r.ok, r.output.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            throw YcrunError("no picture from \(d.name): \(r.errorText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if file == "-" { env.outData(r.output); return }
        do { try env.writeFile(file, r.output) } catch { throw YcrunError("cannot write \(file): \(error.localizedDescription)") }
        env.err("Wrote screenshot to: \(file)")
    }

    // MARK: location, ui (the launcher's settings commands)

    func settingsCommand(_ verb: String, _ a: [String]) throws {
        guard a.count >= 2 else {
            throw YcrunError.usage(verb == "ui" ? "ui <device> appearance [light|dark] | content_size [<size>] | increase_contrast [enabled|disabled]"
                                                : "location <device> set <lat>,<lon> | clear | list | run <scenario> | start [options] <waypoints>")
        }
        let ctx = try context()
        try requireLauncher(ctx)
        let d = try device(a[0], in: ctx)
        let words = Array(a.dropFirst())
        let r = ctx.shell.run("exec \(shq(ctx.settings.simdPath)) --device \(shq(d.path)) --\(verb)" + words.map { " " + shq($0) }.joined(), timeout: 120)
        let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.ok else { throw YcrunError(text.isEmpty ? SimctlFormat.lastLines(r) : SimctlFormat.reply(text)) }
        // A query prints its answer (`ui <device> appearance` → dark); a change prints nothing, as simctl.
        let reply = SimctlFormat.reply(text)
        if !reply.isEmpty && Self.isQuery(verb, words) { env.out(reply) }
    }

    static func isQuery(_ verb: String, _ w: [String]) -> Bool {
        (verb == "ui" && w.count == 1) || (verb == "location" && w.first == "list")
    }

    // MARK: pair

    func pairing(_ verb: String, _ a: [String], count: Int) throws {
        guard a.count == count else {
            throw YcrunError.usage(verb == "pair" ? "pair <watch device> <phone device>" : "\(verb == "unpair" ? "unpair" : "pair_activate") <pair UUID>")
        }
        let ctx = try context()
        try requireLauncher(ctx)
        var operands = a
        if verb == "pair" {
            let list = ctx.withStates()
            operands = try a.map { x -> String in
                switch SimHostContext.find(x, in: list) {
                case .found(let d): return d.path
                case .invalid(let why): throw YcrunError(why)
                }
            }
        }
        let r = ctx.shell.run("env YCODE_SIM_DEVICE_SET=\(shq(ctx.data + "/devices")) \(shq(ctx.settings.simdPath)) \(verb)" + operands.map { " " + shq($0) }.joined(),
                              timeout: 300)
        guard r.ok else { throw YcrunError(SimctlFormat.lastLines(r)) }
        let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { env.out(text) }
    }

    // MARK: view (Ycode only)

    /// `view <device> [viewer options]`: the device's live screen in
    /// ycode-sim-viewer. On a host, its display socket comes over an ssh
    /// forward (keys only) for as long as the window is open.
    func view(_ a: [String]) throws {
        guard let arg = a.first else { throw YcrunError.usage("view <device> [ycode-sim-viewer options]") }
        let ctx = try context()
        let d = try device(arg, in: ctx)
        guard d.state == .booted else { throw YcrunError("\(d.name) is not booted: `ycrun simctl boot \(arg)` first") }
        let remote = ctx.remote(d)
        let viewer = SimctlFormat.toolPath("ycode-sim-viewer", next: env.executable, environment: env.environment, variable: "YCODE_SIM_VIEWER")
        if ctx.entry.isLocal {
            let status = env.foreground([viewer, "--connect", "unix:" + remote.displaySocketPath] + a.dropFirst(), [:])
            if status != 0 { throw YcrunError("the viewer ended with status \(status)", status: status) }
            return
        }
        let local = NSTemporaryDirectory() + "ycrun-view-\(getpid()).sock"
        unlink(local)
        guard let stop = env.background([env.ssh] + remote.displayForwardArguments(localSocket: local)) else {
            throw YcrunError("cannot start the ssh forward to \(ctx.shell.title)")
        }
        defer { stop(); unlink(local) }
        var waited = 0.0
        while !FileManager.default.fileExists(atPath: local) && waited < 15 { env.sleep(0.25); waited += 0.25 }
        let status = env.foreground([viewer, "--connect", "unix:" + local] + a.dropFirst(), [:])
        if status != 0 { throw YcrunError("the viewer ended with status \(status)", status: status) }
    }
}
