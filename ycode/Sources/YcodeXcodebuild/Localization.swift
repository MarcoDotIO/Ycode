import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import YcodeProject

/// `-exportLocalizations` / `-importLocalizations`: Xcode localization
/// catalogs (`.xcloc`) holding XLIFF 1.2 (OASIS standard) made from the
/// project's String Catalogs (`.xcstrings`) and `.strings` files.
/// See `specs/xcodebuild/localization.md`.
enum Localization {
    // MARK: Sources

    /// One localizable source of a project.
    struct Source {
        enum Kind { case catalog, strings }
        var kind: Kind
        /// Path relative to the project folder (`Loc/Localizable.xcstrings`,
        /// `Loc/en.lproj/Greetings.strings`).
        var relativePath: String
        /// The file on disk (nil for synthesized catalogs).
        var file: String?
        /// For synthesized catalogs: the catalog object.
        var synthesized: [String: Any]?
        /// The target the file belongs to, and the group holding its sources.
        var targetID: String? = nil
        var targetName: String? = nil
        var groupID: String? = nil
    }

    /// The localizable resources of the project's targets, and an Info.plist
    /// catalog for application targets with a generated Info.plist.
    static func sources(_ project: LoadedProject, developmentRegion: String, settings: [String: [String: String]]) -> [Source] {
        let proj = project.proj
        let parents = proj.parentMap()
        let dir = project.directory.path
        var out: [Source] = []
        func rel(_ p: String) -> String { p.hasPrefix(dir + "/") ? String(p.dropFirst(dir.count + 1)) : p }
        for t in proj.targets {
            for pid in t.references("buildPhases") where proj[pid]?.isa == "PBXResourcesBuildPhase" {
                for bf in proj[pid]?.references("files") ?? [] {
                    guard let ref = proj[bf]?.string("fileRef"), let obj = proj[ref] else { continue }
                    if obj.isa == "PBXVariantGroup" {
                        // The development-language member of a localized group.
                        for c in obj.references("children") {
                            guard let child = proj[c], (child.string("name") ?? "") == developmentRegion || (child.string("path") ?? "").hasPrefix(developmentRegion + ".lproj/"),
                                  (child.string("path") ?? "").hasSuffix(".strings"),
                                  let path = proj.resolvedPath(of: c, projectDirectory: project.directory, parents: parents) else { continue }
                            out.append(Source(kind: .strings, relativePath: rel(path), file: path))
                        }
                    } else if (obj.string("path") ?? "").hasSuffix(".xcstrings"),
                              let path = proj.resolvedPath(of: ref, projectDirectory: project.directory, parents: parents) {
                        out.append(Source(kind: .catalog, relativePath: rel(path), file: path))
                    }
                }
            }
            // Generated Info.plist of an application: its bundle name.
            guard let name = t.string("name"), (t.string("productType") ?? "").hasSuffix(".application"),
                  let s = settings[t.id], s["GENERATE_INFOPLIST_FILE"] == "YES" else { continue }
            let folder = FileManager.default.fileExists(atPath: dir + "/" + name) ? name + "/" : ""
            // The group of the target's first source file.
            let firstSource = t.references("buildPhases").lazy.compactMap { proj[$0] }.first { $0.isa == "PBXSourcesBuildPhase" }?
                .references("files").first.flatMap { proj[$0]?.string("fileRef") }
            let catalog: [String: Any] = [
                "sourceLanguage": developmentRegion, "version": "1.3",
                "strings": ["CFBundleName": [
                    "comment": "Bundle name", "extractionState": "extracted_with_value",
                    "localizations": [developmentRegion: ["stringUnit": ["state": "new", "value": s["PRODUCT_NAME"] ?? name]]],
                ] as [String: Any]],
            ]
            out.append(Source(kind: .catalog, relativePath: folder + name + "-InfoPlist.xcstrings", file: nil, synthesized: catalog,
                              targetID: t.id, targetName: name, groupID: firstSource.flatMap { parents[$0] }))
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.relativePath).inserted }
            .sorted { $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending }
    }

    static func loadCatalog(_ s: Source) -> [String: Any]? {
        if let c = s.synthesized { return c }
        guard let f = s.file, let d = FileManager.default.contents(atPath: f) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    // MARK: Translation units

    struct Unit {
        var id: String
        var source: String
        var target: String?
        var state: String?
        var note: String?
    }

    /// XLIFF `state` for a String Catalog string-unit state.
    static func xliffState(_ catalogState: String) -> String {
        switch catalogState {
        case "needs_review": return "needs-review-l10n"
        case "translated": return "translated"
        case "new": return "new"
        case "stale": return "needs-review-l10n"
        default: return catalogState
        }
    }

    /// String Catalog state for an XLIFF `state` (import).
    static func catalogState(_ xliffState: String?) -> String {
        switch xliffState {
        case "new", "needs-translation": return "new"
        case "needs-review-l10n", "needs-review-translation", "needs-adaptation", "needs-l10n", "needs-review-adaptation": return "needs_review"
        default: return "translated"
        }
    }

    static func units(catalog c: [String: Any], language: String) -> [Unit] {
        let sourceLanguage = c["sourceLanguage"] as? String ?? "en"
        let strings = c["strings"] as? [String: Any] ?? [:]
        return strings.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { key in
            guard let entry = strings[key] as? [String: Any] else { return nil }
            if entry["shouldTranslate"] as? Bool == false { return nil }
            let locs = entry["localizations"] as? [String: Any] ?? [:]
            func unit(_ lang: String) -> (value: String, state: String)? {
                guard let u = (locs[lang] as? [String: Any])?["stringUnit"] as? [String: Any], let v = u["value"] as? String else { return nil }
                return (v, u["state"] as? String ?? "translated")
            }
            let source = unit(sourceLanguage)?.value ?? key
            var target: String?, state: String?
            if language == sourceLanguage {
                if let u = unit(sourceLanguage) { target = u.value; state = xliffState(u.state) } else { target = key; state = "new" }
            } else if let u = unit(language) {
                target = u.value; state = xliffState(u.state)
            }
            return Unit(id: key, source: source, target: target, state: state, note: entry["comment"] as? String)
        }
    }

    static func units(strings path: String, translation: String?) -> [Unit] {
        let source = StringsFile.parse(path)
        let target = translation.map { StringsFile.parse($0) } ?? []
        return source.map { e in
            Unit(id: e.key, source: e.value, target: target.first { $0.key == e.key }?.value, state: nil, note: e.comment)
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    // MARK: XLIFF

    static func escape(_ s: String, attribute: Bool = false) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        if attribute { out = out.replacingOccurrences(of: "\"", with: "&quot;") }
        return out
    }

    static let toolAttributes = "tool-id=\"org.ycode.ycodebuild\" tool-name=\"Ycode\" tool-version=\"\(YcodeVersion.version)\" build-num=\"\(YcodeVersion.build)\""

    static func xliff(files: [(original: String, units: [Unit])], sourceLanguage: String, targetLanguage: String) -> String {
        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        x += "<xliff xmlns=\"urn:oasis:names:tc:xliff:document:1.2\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" version=\"1.2\" xsi:schemaLocation=\"urn:oasis:names:tc:xliff:document:1.2 http://docs.oasis-open.org/xliff/v1.2/os/xliff-core-1.2-strict.xsd\">\n"
        for f in files {
            x += "  <file original=\"\(escape(f.original, attribute: true))\" source-language=\"\(sourceLanguage)\" target-language=\"\(targetLanguage)\" datatype=\"plaintext\">\n"
            x += "    <header>\n      <tool \(toolAttributes)/>\n    </header>\n    <body>\n"
            for u in f.units {
                x += "      <trans-unit id=\"\(escape(u.id, attribute: true))\" xml:space=\"preserve\">\n"
                x += "        <source>\(escape(u.source))</source>\n"
                if let t = u.target {
                    x += u.state.map { "        <target state=\"\($0)\">\(escape(t))</target>\n" } ?? "        <target>\(escape(t))</target>\n"
                }
                x += u.note.map { $0.isEmpty ? "        <note/>\n" : "        <note>\(escape($0))</note>\n" } ?? "        <note/>\n"
                x += "      </trans-unit>\n"
            }
            x += "    </body>\n  </file>\n"
        }
        x += "</xliff>\n"
        return x
    }

    /// The catalog as the source-language copy in an `.xcloc`: only the
    /// source language's localizations.
    static func sourceCatalog(_ c: [String: Any]) -> [String: Any] {
        var c = c
        let sourceLanguage = c["sourceLanguage"] as? String ?? "en"
        var strings = c["strings"] as? [String: Any] ?? [:]
        for (k, v) in strings {
            guard var e = v as? [String: Any] else { continue }
            if var locs = e["localizations"] as? [String: Any] {
                locs = locs.filter { $0.key == sourceLanguage }
                if locs.isEmpty { e.removeValue(forKey: "localizations") } else { e["localizations"] = locs }
            }
            strings[k] = e
        }
        c["strings"] = strings
        return c
    }

    // MARK: Export

    static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    /// Builds every target with the build system's `exportloc` action (string
    /// extraction) and returns the targets' build settings.
    static func buildForStrings(_ inv: Invocation, project: LoadedProject, container: Container, context ctx: XcodebuildContext) throws(XcodebuildFailure) -> [String: [String: String]]? {
        let targets = project.targets.filter { ProjectPIF.targetKind($0) != nil }.map { SettingsTarget(project: project, target: $0) }
        var plan = Plan(container: container, scheme: nil, actions: [.build], targets: targets, configuration: inv.configuration ?? project.defaultConfigurationName,
                        overrides: inv.overrides, xcconfig: nil,
                        arena: Arena.forContainer(container, derivedDataPath: inv.derivedDataPath.map { $0.hasPrefix("/") ? $0 : ctx.cwd + "/" + $0 }, derivedDataRoot: ctx.derivedDataRoot),
                        runDestination: nil)
        plan.parameterAction = "exportloc"
        plan.locationStyle = "regular"
        var settings: [String: [String: String]] = [:]
        guard let helper = SwiftBuildSettingsProvider.locate(environment: ctx.environment, executableDirectory: ctx.executableDirectory) else { return settings }
        let b = try BuildActions.runOne(.build, inv: inv, plan: plan, helper: helper, context: ctx, successBanner: false)
        if !b.ok { return nil }
        if let list = try? ShowBuildSettings.provider(ctx).settings(container: container, targets: targets, parameters: plan.parameters(action: .build)) {
            for (t, s) in zip(targets, list) { settings[t.target.id] = s }
        }
        return settings
    }

    static func export(_ inv: Invocation, context ctx: XcodebuildContext) throws(XcodebuildFailure) -> Int32 {
        let console = ctx.console
        guard let outValue = inv.value("-localizationPath") else {
            throw XcodebuildFailure("The flag -localizationPath is required when specifying -exportLocalizations.", exitCode: ExitCode.usage)
        }
        let container = try ContainerLocator.open(inv, cwd: ctx.cwd)
        guard let project = container.mainProject else {
            throw XcodebuildFailure("ycodebuild exports localizations of projects only yet.", exitCode: ExitCode.software)
        }
        let out = outValue.hasPrefix("/") ? outValue : ctx.cwd + "/" + outValue
        let development = inv.value("-defaultLanguage") ?? project.proj.project?.string("developmentRegion") ?? "en"
        let languages = inv.all("-exportLanguage").isEmpty ? [development] : inv.all("-exportLanguage")
        func log(_ s: String) { console.out(timestamp() + " " + s) }
        console.out("Localization Export started for \(project.name) project")
        log("Started export")
        log("Extracting strings from code")
        console.out()
        console.out("Building all targets for string extraction")
        console.out()
        // Every target is built with the export action (string extraction).
        guard let settings = try buildForStrings(inv, project: project, container: container, context: ctx) else { return ExitCode.dataError }
        log("Extracting strings from localizable files")
        let sources = sources(project, developmentRegion: development, settings: settings)
        log("Copying source language files")
        let fm = FileManager.default
        for lang in languages {
            let bundle = out + "/" + lang + ".xcloc"
            var files: [(original: String, units: [Unit])] = []
            for s in sources {
                log("Exporting \(s.relativePath) to \(lang).xliff...")
                switch s.kind {
                case .catalog:
                    guard let c = loadCatalog(s) else { continue }
                    files.append((s.relativePath, units(catalog: c, language: lang)))
                case .strings:
                    guard let f = s.file else { continue }
                    let translated = f.replacingOccurrences(of: "/\(development).lproj/", with: "/\(lang).lproj/")
                    files.append((s.relativePath, units(strings: f, translation: fm.fileExists(atPath: translated) ? translated : nil)))
                }
            }
            log("Writing")
            do {
                if fm.fileExists(atPath: bundle) { try fm.removeItem(atPath: bundle) }
                for sub in ["Localized Contents", "Source Contents", "Notes"] { try fm.createDirectory(atPath: bundle + "/" + sub, withIntermediateDirectories: true) }
                try xliff(files: files, sourceLanguage: development, targetLanguage: lang)
                    .write(toFile: bundle + "/Localized Contents/\(lang).xliff", atomically: true, encoding: .utf8)
                for s in sources {
                    let dest = bundle + "/Source Contents/" + s.relativePath
                    try fm.createDirectory(atPath: URL(fileURLWithPath: dest).deletingLastPathComponent().path, withIntermediateDirectories: true)
                    switch s.kind {
                    case .catalog:
                        if let c = loadCatalog(s) { try JSONText.render(sourceCatalog(c)).write(toFile: dest, atomically: true, encoding: .utf8) }
                    case .strings:
                        if let f = s.file { try fm.copyItem(atPath: f, toPath: dest) }
                    }
                }
                let contents: [String: Any] = [
                    "developmentRegion": development, "project": project.url.lastPathComponent, "targetLocale": lang, "version": "1.0",
                    "toolInfo": ["toolBuildNumber": YcodeVersion.build, "toolID": "org.ycode.ycodebuild", "toolName": "Ycode", "toolVersion": YcodeVersion.version],
                ]
                try JSONText.render(contents).write(toFile: bundle + "/contents.json", atomically: true, encoding: .utf8)
            } catch {
                throw XcodebuildFailure("Could not write \(bundle): \(error)", exitCode: ExitCode.software)
            }
            log("An xcloc was created at \(bundle)")
        }
        return 0
    }

    // MARK: Import

    struct XLIFFFile {
        var original: String
        var sourceLanguage: String
        var targetLanguage: String
        var units: [Unit]
    }

    /// Reads the `<file>` and `<trans-unit>` elements of an XLIFF 1.2 document.
    final class XLIFFReader: NSObject, XMLParserDelegate {
        var files: [XLIFFFile] = []
        var unit: Unit?
        var text = ""
        var element = ""
        var state: String?

        static func read(_ data: Data) -> [XLIFFFile] {
            let r = XLIFFReader()
            let p = XMLParser(data: data)
            p.delegate = r
            _ = p.parse()
            return r.files
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch name {
            case "file":
                files.append(XLIFFFile(original: a["original"] ?? "", sourceLanguage: a["source-language"] ?? "", targetLanguage: a["target-language"] ?? "", units: []))
            case "trans-unit":
                unit = Unit(id: a["id"] ?? "", source: "", target: nil, state: nil, note: nil)
            case "source", "target", "note":
                element = name; text = ""
                if name == "target" { state = a["state"] }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if !element.isEmpty { text += string } }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "source": unit?.source = text; element = ""
            case "target": unit?.target = text; unit?.state = state; element = ""
            case "note": unit?.note = text; element = ""
            case "trans-unit":
                if let u = unit, !files.isEmpty { files[files.count - 1].units.append(u) }
                unit = nil
            default: break
            }
        }
    }

    static func importLocalizations(_ inv: Invocation, context ctx: XcodebuildContext) throws(XcodebuildFailure) -> Int32 {
        let console = ctx.console
        guard let inValue = inv.value("-localizationPath") else {
            throw XcodebuildFailure("The flag -localizationPath is required when specifying -importLocalizations.", exitCode: ExitCode.usage)
        }
        let container = try ContainerLocator.open(inv, cwd: ctx.cwd)
        guard let project = container.mainProject else {
            throw XcodebuildFailure("ycodebuild imports localizations into projects only yet.", exitCode: ExitCode.software)
        }
        var path = inValue.hasPrefix("/") ? inValue : ctx.cwd + "/" + inValue
        if path.hasSuffix(".xcloc") {
            let lang = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            path += "/Localized Contents/\(lang).xliff"
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw XcodebuildFailure("The file \(inValue) could not be read.", exitCode: ExitCode.noInput)
        }
        func log(_ s: String) { console.out(timestamp() + " " + s) }
        console.out("Localization Import started for \(project.name) project")
        log("Started import")
        console.out()
        console.out("Building all targets for string extraction")
        console.out()
        guard let settings = try buildForStrings(inv, project: project, container: container, context: ctx) else { return ExitCode.dataError }
        let development = project.proj.project?.string("developmentRegion") ?? "en"
        let known = sources(project, developmentRegion: development, settings: settings)
        let dir = project.directory.path
        log("Comparing")
        let files = XLIFFReader.read(data).sorted { Array($0.original.utf8).lexicographicallyPrecedes(Array($1.original.utf8)) }
        for f in files { log("Checking for new localizations in the XLIFF for \(f.original)...") }
        log("Writing")
        var generated: [Source] = []
        for f in files {
            let file = dir + "/" + f.original
            if f.original.hasSuffix(".xcstrings") {
                // Translations go into the catalog; a catalog the build
                // generates (Info.plist strings) is written and added.
                let synthesized = known.first { $0.relativePath == f.original && $0.synthesized != nil }
                var c: [String: Any]
                if let d = FileManager.default.contents(atPath: file), let existing = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    c = existing
                } else if let g = synthesized?.synthesized {
                    c = g
                    generated.append(synthesized!)
                } else { continue }
                var strings = c["strings"] as? [String: Any] ?? [:]
                let present = Set(f.units.map(\.id))
                for key in strings.keys.sorted() where !present.contains(key) && (strings[key] as? [String: Any])?["shouldTranslate"] as? Bool != false {
                    console.warning("\(f.original): Key not found in the XLIFF (Key: \"\(key)\")")
                }
                for u in f.units {
                    guard let t = u.target, f.targetLanguage != (c["sourceLanguage"] as? String ?? development) else { continue }
                    var e = strings[u.id] as? [String: Any] ?? [:]
                    var locs = e["localizations"] as? [String: Any] ?? [:]
                    locs[f.targetLanguage] = ["stringUnit": ["state": catalogState(u.state), "value": t]]
                    e["localizations"] = locs
                    if e["comment"] == nil, let n = u.note, !n.isEmpty { e["comment"] = n }
                    strings[u.id] = e
                }
                c["strings"] = strings
                do { try JSONText.render(c).write(toFile: file, atomically: true, encoding: .utf8) } catch {
                    throw XcodebuildFailure("Could not write \(file): \(error)", exitCode: ExitCode.software)
                }
            } else if f.original.hasSuffix(".strings") {
                let source = "/" + f.sourceLanguage + ".lproj/"
                let target = file.replacingOccurrences(of: source, with: "/\(f.targetLanguage).lproj/")
                guard target != file else { continue }
                var text = ""
                for u in f.units where u.target != nil {
                    if let n = u.note, !n.isEmpty { text += "/* \(n) */\n" }
                    text += "\"\(StringsFile.escape(u.id))\" = \"\(StringsFile.escape(u.target!))\";\n\n"
                }
                do {
                    try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: target).deletingLastPathComponent().path, withIntermediateDirectories: true)
                    try text.write(toFile: target, atomically: true, encoding: .utf8)
                } catch {
                    throw XcodebuildFailure("Could not write \(target): \(error)", exitCode: ExitCode.software)
                }
            }
        }
        // Generated catalogs join their target's group and resources.
        if !generated.isEmpty {
            var proj = project.proj
            for g in generated {
                guard let targetID = g.targetID, let group = g.groupID,
                      let phase = proj.buildPhases(ofTarget: targetID).first(where: { $0.isa == "PBXResourcesBuildPhase" }) else { continue }
                log("Will add generated file '\(g.relativePath)' to target \(g.targetName ?? "").")
                let ref = proj.addFileReference(path: URL(fileURLWithPath: g.relativePath).lastPathComponent, to: group)
                _ = proj.addBuildFile(fileReference: ref, to: phase.id)
            }
            do {
                try PBXProjWriter.write(proj, projectName: project.name).write(to: project.url.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
            } catch {
                throw XcodebuildFailure("Could not write \(project.url.path): \(error)", exitCode: ExitCode.software)
            }
        }
        return 0
    }
}

/// `.strings` files: `"key" = "value";` pairs with `/* comments */`.
enum StringsFile {
    struct Entry: Equatable { var key: String; var value: String; var comment: String? }

    static func parse(_ path: String) -> [Entry] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? ""
        return parse(text: text)
    }

    static func parse(text: String) -> [Entry] {
        var out: [Entry] = []
        let chars = Array(text.unicodeScalars)
        var i = 0
        var comment: String?
        func skipSpace() {
            while i < chars.count {
                if CharacterSet.whitespacesAndNewlines.contains(chars[i]) { i += 1; continue }
                if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                    let start = i + 2
                    i += 2
                    while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                    comment = String(String.UnicodeScalarView(chars[start..<min(i, chars.count)])).trimmingCharacters(in: .whitespacesAndNewlines)
                    i += 2
                    continue
                }
                if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                    while i < chars.count, chars[i] != "\n" { i += 1 }
                    continue
                }
                break
            }
        }
        func quoted() -> String? {
            guard i < chars.count, chars[i] == "\"" else { return nil }
            i += 1
            var s = String.UnicodeScalarView()
            while i < chars.count, chars[i] != "\"" {
                if chars[i] == "\\", i + 1 < chars.count {
                    i += 1
                    switch chars[i] {
                    case "n": s.append("\n")
                    case "t": s.append("\t")
                    case "r": s.append("\r")
                    case "U", "u":
                        let hex = String(String.UnicodeScalarView(chars[(i + 1)..<min(i + 5, chars.count)]))
                        if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) { s.append(u); i += 4 }
                    default: s.append(chars[i])
                    }
                } else {
                    s.append(chars[i])
                }
                i += 1
            }
            i += 1
            return String(s)
        }
        while i < chars.count {
            comment = nil
            skipSpace()
            let note = comment
            guard let key = quoted() else { if i < chars.count { i += 1 }; continue }
            skipSpace()
            guard i < chars.count, chars[i] == "=" else { continue }
            i += 1
            skipSpace()
            guard let value = quoted() else { continue }
            skipSpace()
            if i < chars.count, chars[i] == ";" { i += 1 }
            out.append(Entry(key: key, value: value, comment: note))
        }
        return out
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
    }
}
