import Foundation
import YcodeProject

/// The "Resolve Package Graph" report printed before other output when a
/// container uses Swift packages. ycodebuild does not resolve packages: it
/// reports the pins recorded in `Package.resolved` and the local packages.
/// See `specs/xcodebuild/info-commands.md` §2.3.
enum PackageReport {
    struct Entry: Equatable {
        var name: String
        var location: String
        /// Version, `branch (revision)`, short revision, `local`, or nil for
        /// a package added as a folder.
        var state: String?
    }

    static func entries(_ c: Container, derivedDataRoot: String, checkouts: String? = nil) -> [Entry] {
        let resolved = c.workspacePath.appendingPathComponent("xcshareddata/swiftpm/Package.resolved")
        let checkouts = checkouts ?? derivedDataRoot + "/" + DerivedDataName.folder(name: c.name, path: c.url.path)
            + "/SourcePackages/checkouts"
        var pins: [Entry] = []
        if let data = FileManager.default.contents(atPath: resolved.path),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Version 1 files nest the pins under "object".
            let list = obj["pins"] as? [[String: Any]] ?? (obj["object"] as? [String: Any])?["pins"] as? [[String: Any]] ?? []
            for pin in list {
                let location = pin["location"] as? String ?? pin["repositoryURL"] as? String ?? ""
                let state = pin["state"] as? [String: Any] ?? [:]
                let revision = String((state["revision"] as? String ?? "").prefix(7))
                let version = state["version"] as? String ?? (state["branch"] as? String).map { "\($0) (\(revision))" } ?? revision
                var repo = URL(fileURLWithPath: location).lastPathComponent
                if repo.hasSuffix(".git") { repo.removeLast(4) }
                // The package's own name, when a checkout is at hand.
                // Checkouts are named by repository or by package identity (lowercase).
                let manifest = (try? String(contentsOfFile: checkouts + "/" + repo + "/Package.swift", encoding: .utf8))
                    ?? (try? String(contentsOfFile: checkouts + "/" + repo.lowercased() + "/Package.swift", encoding: .utf8))
                pins.append(Entry(name: manifest.flatMap(LocalPackages.packageName) ?? repo, location: location, state: version))
            }
        }
        func sameRepo(_ a: String, _ b: String) -> Bool {
            func n(_ s: String) -> String { var s = s.lowercased(); if s.hasSuffix(".git") { s.removeLast(4) }; return s }
            return n(a) == n(b)
        }
        var out: [Entry] = []
        // Direct references first, in the project's order; then the rest.
        for p in c.projects {
            let locals = LocalPackages.find(in: p)
            for ref in LocalPackages.references(in: p) {
                if let dir = ref.local, let pkg = locals.first(where: { $0.directory == dir }), !out.contains(where: { $0.location == dir }) {
                    // A package also added as a folder is reported as a folder.
                    out.append(Entry(name: pkg.name, location: dir, state: pkg.addedAsFolder ? nil : "local"))
                } else if let url = ref.remote, let pin = pins.first(where: { sameRepo($0.location, url) }), !out.contains(pin) {
                    out.append(pin)
                }
            }
        }
        for pin in pins where !out.contains(pin) { out.append(pin) }
        for p in c.projects {
            for pkg in LocalPackages.find(in: p) where !pkg.isPackageReference && !out.contains(where: { $0.location == pkg.directory }) {
                out.append(Entry(name: pkg.name, location: pkg.directory, state: nil))
            }
        }
        return out
    }

    static func print(_ c: Container, derivedDataRoot: String, checkouts: String? = nil, console: Console) {
        print(entries(c, derivedDataRoot: derivedDataRoot, checkouts: checkouts), console: console)
    }

    static func print(_ e: [Entry], console: Console) {
        guard !e.isEmpty else { return }
        console.out("Resolve Package Graph")
        console.out()
        console.out()
        console.out("Resolved source packages:")
        for x in e { console.out("  \(x.name): \(x.location)" + (x.state.map { " @ \($0)" } ?? "")) }
        console.out()
    }
}

/// Quoting of arguments and names in log headers: a word made only of
/// letters, digits, non-ASCII characters and `, + = - _ . /` is printed
/// as is; anything else is put in double quotes, with `"` and `\` escaped.
enum ShellQuote {
    static func isPlain(_ c: Character) -> Bool {
        if !c.isASCII { return true }
        return c.isLetter || c.isNumber || ",+=-_./".contains(c)
    }

    static func quote(_ s: String) -> String {
        if !s.isEmpty && s.allSatisfy(isPlain) { return s }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
