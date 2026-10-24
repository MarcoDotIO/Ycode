import Foundation

/// `archive` (the `.xcarchive` bundle) and `-exportArchive`.
/// See `specs/xcodebuild/archive.md`.
enum Archives {
    // MARK: archive

    /// `-archivePath` (with `.xcarchive` added when missing), else
    /// `~/Library/Developer/Xcode/Archives/<yyyy-MM-dd>/<scheme> <M-d-yy, h.mm a>.xcarchive`.
    static func archivePath(_ inv: Invocation, scheme: String, home: String, cwd: String, date: Date) -> String {
        if var p = inv.value("-archivePath") {
            if !p.hasPrefix("/") { p = cwd + "/" + p }
            p = URL(fileURLWithPath: p).standardizedFileURL.path
            return p.hasSuffix(".xcarchive") ? p : p + ".xcarchive"
        }
        let day = DateFormatter(), stamp = DateFormatter()
        for f in [day, stamp] { f.locale = Locale(identifier: "en_US_POSIX") }
        day.dateFormat = "yyyy-MM-dd"
        stamp.dateFormat = "M-d-yy, h.mm a"
        return home + "/Library/Developer/Xcode/Archives/" + day.string(from: date) + "/\(scheme) \(stamp.string(from: date)).xcarchive"
    }

    /// After a successful `archive` build: collects the installed products
    /// and dSYMs into the archive and writes its `Info.plist`.
    static func assemble(_ inv: Invocation, plan: Plan, context ctx: XcodebuildContext, created: Date) throws(XcodebuildFailure) -> String {
        guard let scheme = plan.scheme, let locations = plan.archiveLocations else {
            throw XcodebuildFailure("archive requires a scheme.", exitCode: ExitCode.usage)
        }
        let path = archivePath(inv, scheme: scheme.name, home: ctx.home, cwd: ctx.cwd, date: created)
        let fm = FileManager.default
        let archive = URL(fileURLWithPath: path)
        let products = archive.appendingPathComponent("Products"), dsyms = archive.appendingPathComponent("dSYMs")
        do {
            if fm.fileExists(atPath: path) { try fm.removeItem(at: archive) }
            try fm.createDirectory(at: products, withIntermediateDirectories: true)
            try fm.createDirectory(at: dsyms, withIntermediateDirectories: true)
            for item in (try? fm.contentsOfDirectory(atPath: locations.dstroot)) ?? [] {
                try fm.copyItem(atPath: locations.dstroot + "/" + item, toPath: products.appendingPathComponent(item).path)
            }
            // dSYMs next to the built products (DWARF_DSYM_FOLDER_PATH).
            for dir in (try? fm.contentsOfDirectory(atPath: locations.symroot)) ?? [] {
                for item in (try? fm.contentsOfDirectory(atPath: locations.symroot + "/" + dir)) ?? [] where item.hasSuffix(".dSYM") {
                    let dest = dsyms.appendingPathComponent(item)
                    if !fm.fileExists(atPath: dest.path) { try fm.copyItem(atPath: locations.symroot + "/" + dir + "/" + item, toPath: dest.path) }
                }
            }
            var info: [String: Any] = ["ArchiveVersion": 2, "CreationDate": created, "Name": scheme.name, "SchemeName": scheme.name]
            if let app = applicationProperties(products: products.path) { info["ApplicationProperties"] = app }
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: archive.appendingPathComponent("Info.plist"))
        } catch {
            throw XcodebuildFailure("Could not write the archive at \(path): \(error)", exitCode: ExitCode.software)
        }
        return path
    }

    /// `ApplicationProperties` for an archive holding one application under
    /// `Products/Applications`.
    static func applicationProperties(products: String) -> [String: Any]? {
        let apps = ((try? FileManager.default.contentsOfDirectory(atPath: products + "/Applications")) ?? []).filter { $0.hasSuffix(".app") }.sorted()
        guard let app = apps.first else { return nil }
        let bundle = products + "/Applications/" + app
        let plist = (FileManager.default.contents(atPath: bundle + "/Contents/Info.plist"))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        var props: [String: Any] = [
            "ApplicationPath": "Applications/" + app,
            "CFBundleIdentifier": plist["CFBundleIdentifier"] as? String ?? "",
            "CFBundleShortVersionString": plist["CFBundleShortVersionString"] as? String ?? "",
            "CFBundleVersion": plist["CFBundleVersion"] as? String ?? "",
            // Ad hoc ("Sign to Run Locally") signatures have no identity or team.
            "SigningIdentity": "",
            "Team": "",
        ]
        if let exe = plist["CFBundleExecutable"] as? String {
            let archs = MachO.architectures(bundle + "/Contents/MacOS/" + exe)
            if !archs.isEmpty { props["Architectures"] = archs }
        }
        return props
    }

    // MARK: -exportArchive

    /// `-exportArchive`: limited to archives of applications signed ad hoc,
    /// exported with method `mac-application` (a copy of the application).
    static func export(_ inv: Invocation, context ctx: XcodebuildContext) -> Int32 {
        let console = ctx.console
        func fail(_ message: String, _ code: Int32) -> Int32 {
            console.out("** EXPORT FAILED **")
            console.out()
            console.err("error: " + message)
            console.err()
            return code
        }
        func absolute(_ p: String) -> String { URL(fileURLWithPath: p.hasPrefix("/") ? p : ctx.cwd + "/" + p).standardizedFileURL.path }
        let archive = absolute(inv.value("-archivePath") ?? "")
        let fm = FileManager.default
        guard fm.fileExists(atPath: archive + "/Info.plist") else {
            return fail("error: archive not found at path '\(PathText.withoutPrivatePrefix(archive))'", ExitCode.dataError)
        }
        let optionsPath = absolute(inv.value("-exportOptionsPlist") ?? "")
        guard let data = fm.contents(atPath: optionsPath),
              let options = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            let why = fm.fileExists(atPath: optionsPath) ? "it is not a property list" : "the file does not exist"
            return fail("Couldn't load -exportOptionsPlist \(URL(fileURLWithPath: optionsPath).lastPathComponent): \(why).", ExitCode.software)
        }
        guard let exportPath = inv.value("-exportPath").map(absolute) else {
            return fail("The flag -exportPath is required when specifying -exportArchive. Distribution driver requires destination path.", ExitCode.usage)
        }
        let info = fm.contents(atPath: archive + "/Info.plist").flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        let name = info["Name"] as? String ?? URL(fileURLWithPath: archive).deletingPathExtension().lastPathComponent
        guard let app = info["ApplicationProperties"] as? [String: Any], let appPath = app["ApplicationPath"] as? String else {
            return fail("exportArchive: the archive has no application to export (only application archives can be exported).", ExitCode.software)
        }
        let method = options["method"] as? String ?? "debugging"
        let team = (app["Team"] as? String ?? "") + (options["teamID"] as? String ?? "")
        guard method == "mac-application" else {
            if team.isEmpty { return fail("exportArchive No Team Found in Archive", ExitCode.software) }
            return fail("exportArchive: ycodebuild exports only with method mac-application (ad hoc signing) yet.", ExitCode.software)
        }
        let certificate = options["signingCertificate"] as? String
        if let c = certificate, c != "-" {
            return fail("exportArchive: ycodebuild signs exports only ad hoc (signingCertificate \"-\") yet.", ExitCode.software)
        }
        let source = archive + "/Products/" + appPath
        let dest = exportPath + "/" + URL(fileURLWithPath: appPath).lastPathComponent
        do {
            try fm.createDirectory(atPath: exportPath, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
            try fm.copyItem(atPath: source, toPath: dest)
        } catch {
            return fail("exportArchive: could not copy the application: \(error)", ExitCode.software)
        }
        // An explicit ad hoc certificate re-signs an application that is
        // not signed ad hoc already.
        if certificate == "-", !isAdHocSigned(dest), !resignAdHoc(dest) {
            return fail("exportArchive: codesign failed for \(dest).", ExitCode.software)
        }
        console.out("Exported \(name) to: \(PathText.withoutPrivatePrefix(exportPath))")
        console.out("** EXPORT SUCCEEDED **")
        console.out()
        return 0
    }

    static func codesign(_ args: [String]) -> (status: Int32, output: String) {
        TestActions.run("/usr/bin/codesign", args, environment: ProcessInfo.processInfo.environment) { _ in }
    }

    static func isAdHocSigned(_ bundle: String) -> Bool {
        codesign(["-dv", bundle]).output.contains("Signature=adhoc")
    }

    static func resignAdHoc(_ bundle: String) -> Bool {
        codesign(["--force", "--sign", "-", "--preserve-metadata=identifier,entitlements,flags", bundle]).status == 0
    }
}

/// Architectures of a Mach-O file, in the order the file lists them.
enum MachO {
    static func architectures(_ path: String) -> [String] {
        guard let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        let head = [UInt8](h.readData(ofLength: 4096))
        guard head.count >= 8 else { return [] }
        func be32(_ o: Int) -> UInt32 { head[o..<o + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        func le32(_ o: Int) -> UInt32 { head[o..<o + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        func name(_ cpu: UInt32, _ sub: UInt32) -> String {
            switch cpu {
            case 0x0100_0007: return "x86_64"
            case 0x0100_000C: return (sub & 0xFF) == 2 ? "arm64e" : "arm64"
            case 7: return "i386"
            case 12: return "armv7"
            default: return "unknown"
            }
        }
        let magic = be32(0)
        if magic == 0xCAFE_BABE || magic == 0xCAFE_BABF {
            let n = Int(be32(4))
            let size = magic == 0xCAFE_BABE ? 20 : 32
            return (0..<n).compactMap { i in
                let o = 8 + i * size
                return o + 8 <= head.count ? name(be32(o), be32(o + 4)) : nil
            }
        }
        if le32(0) == 0xFEED_FACF || le32(0) == 0xFEED_FACE { return [name(le32(4), le32(8))] }
        return []
    }
}
