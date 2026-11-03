import Foundation

/// `ycode strings` (`specs/ide/string-catalog.md`, "Ycode implementation"):
/// compile catalogs (also as swift-build's `xcstringstool compile`),
/// generate symbols, extract strings from source, and convert
/// `.strings`/`.stringsdict` tables.
public enum StringsCLI {
    public static let usage = """
    usage: ycode strings compile [--dry-run] [-l LANG]… [--force-build-all-strings] [--strings-encoding utf-8|utf-16]
                                 --output-directory <dir> <file.xcstrings>…
           ycode strings generate-symbols --language swift --output-directory <dir> [--dry-run] <file.xcstrings>…
           ycode strings extract [--catalog <file.xcstrings>] [--source-language L] [--table T] [--macro NAME]…
                                 [--no-swiftui] [--json] <source file or folder>…
           ycode strings convert <folder with .lproj folders> [--table T] [--source-language L] [-o <file.xcstrings>]
           ycode strings info <file.xcstrings>
           (xcstringstool's command lines are accepted: ycode strings compile|generate-symbols …)

    """

    static func err(_ s: String) { FileHandle.standardError.write(Data((s.hasSuffix("\n") ? s : s + "\n").utf8)) }
    static func out(_ s: String) { FileHandle.standardOutput.write(Data((s.hasSuffix("\n") ? s : s + "\n").utf8)) }

    public static func run(_ args: [String]) -> Int32 {
        guard let sub = args.first else { err(usage); return 2 }
        let rest = Array(args.dropFirst())
        switch sub {
        case "compile": return compile(rest)
        case "generate-symbols": return generateSymbols(rest)
        case "extract": return extract(rest)
        case "convert": return convert(rest)
        case "info": return info(rest)
        case "--version", "version":
            out("ycode strings 1.0")
            return 0
        default:
            err(usage)
            return 2
        }
    }

    static func load(_ path: String) -> StringCatalog? {
        guard let data = FileManager.default.contents(atPath: path) else {
            err("\(path): error: cannot read the file")
            return nil
        }
        do { return try StringCatalog(data: data) } catch {
            err("\(path): error: \(error)")
            return nil
        }
    }

    // MARK: compile

    static func compile(_ args: [String]) -> Int32 {
        var options = StringCatalogCompiler.Options()
        var dryRun = false
        var outDir: String?
        var inputs: [String] = []
        var languages: [String] = []
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--dry-run": dryRun = true
            case "--force-build-all-strings": options.forceBuildAllStrings = true
            case "-l", "--language":
                guard let v = it.next() else { err(usage); return 2 }
                languages.append(v)
            case "--output-directory", "-o":
                guard let v = it.next() else { err(usage); return 2 }
                outDir = v
            case "--strings-encoding":
                guard let v = it.next(), let e = StringsFile.Encoding(rawValue: v.lowercased()) else { err(usage); return 2 }
                options.stringsEncoding = e
            default:
                if a.hasPrefix("-") {
                    err("ycode strings compile: unknown option \(a)\n" + usage)
                    return 2
                }
                inputs.append(a)
            }
        }
        if !languages.isEmpty { options.languages = languages }
        guard let outDir, !inputs.isEmpty else { err(usage); return 2 }
        var failed = false
        for input in inputs {
            guard let catalog = load(input) else { failed = true; continue }
            let table = StringCatalog.tableName(forPath: input)
            let result = StringCatalogCompiler.compile(catalog, options: options)
            for d in result.diagnostics { err("\(input): \(d)") }
            if !result.errors.isEmpty { failed = true; continue }
            if dryRun {
                for p in result.outputPaths(directory: absolute(outDir), tableName: table) { out(p) }
                continue
            }
            do { try result.write(directory: absolute(outDir), tableName: table, encoding: options.stringsEncoding) } catch {
                err("\(input): error: cannot write the output: \(error)")
                failed = true
            }
        }
        return failed ? 1 : 0
    }

    static func absolute(_ p: String) -> String {
        p.hasPrefix("/") ? p : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(p)
    }

    // MARK: generate-symbols

    static func generateSymbols(_ args: [String]) -> Int32 {
        var outDir: String?
        var language = "swift"
        var dryRun = false
        var inputs: [String] = []
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--language":
                guard let v = it.next() else { err(usage); return 2 }
                language = v
            case "--output-directory", "-o":
                guard let v = it.next() else { err(usage); return 2 }
                outDir = v
            case "--dry-run": dryRun = true
            default:
                if a.hasPrefix("-") { err("ycode strings generate-symbols: unknown option \(a)\n" + usage); return 2 }
                inputs.append(a)
            }
        }
        guard language == "swift" else { err("ycode strings generate-symbols: only Swift symbols are generated"); return 2 }
        guard let outDir, !inputs.isEmpty else { err(usage); return 2 }
        var failed = false
        for input in inputs {
            guard let catalog = load(input) else { failed = true; continue }
            let table = StringCatalog.tableName(forPath: input)
            let path = (absolute(outDir) as NSString).appendingPathComponent(StringSymbolGenerator.fileName(table: table))
            if dryRun { out(path); continue }
            do {
                try FileManager.default.createDirectory(atPath: absolute(outDir), withIntermediateDirectories: true)
                let text = Data(StringSymbolGenerator.swiftSource(catalog, table: table).utf8)
                // Leave an unchanged file alone so the compiler does not rebuild.
                if FileManager.default.contents(atPath: path) != text { try text.write(to: URL(fileURLWithPath: path), options: .atomic) }
            } catch {
                err("\(input): error: cannot write \(path): \(error)")
                failed = true
            }
        }
        return failed ? 1 : 0
    }

    // MARK: extract

    /// Source files under a folder (or the file itself).
    public static func sourceFiles(_ paths: [String]) -> [String] {
        let fm = FileManager.default
        let exts: Set<String> = ["swift", "m", "mm", "c", "cc", "cpp", "h", "hpp"]
        var out: [String] = []
        for p in paths {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else { continue }
            if !isDir.boolValue { out.append(p); continue }
            let e = fm.enumerator(atPath: p)
            while let rel = e?.nextObject() as? String {
                let name = (rel as NSString).lastPathComponent
                if name.hasPrefix(".") || name == "build" || name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcassets") {
                    e?.skipDescendants()
                    continue
                }
                if exts.contains((rel as NSString).pathExtension.lowercased()) { out.append((p as NSString).appendingPathComponent(rel)) }
            }
        }
        return out.sorted()
    }

    static func extract(_ args: [String]) -> Int32 {
        var catalogPath: String?
        var sourceLanguage = "en"
        var table: String?
        var options = StringExtractor.Options()
        var json = false
        var inputs: [String] = []
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--catalog":
                guard let v = it.next() else { err(usage); return 2 }
                catalogPath = v
            case "--source-language":
                guard let v = it.next() else { err(usage); return 2 }
                sourceLanguage = v
            case "--table":
                guard let v = it.next() else { err(usage); return 2 }
                table = v
            case "--macro":
                guard let v = it.next() else { err(usage); return 2 }
                options.macroNames.append(v)
            case "--no-swiftui": options.swiftUI = false
            case "--json": json = true
            default:
                if a.hasPrefix("-") { err("ycode strings extract: unknown option \(a)\n" + usage); return 2 }
                inputs.append(a)
            }
        }
        guard !inputs.isEmpty else { err(usage); return 2 }
        var found = sourceFiles(inputs).flatMap { StringExtractor.extract(file: $0, options: options) }
        let tableName = table ?? catalogPath.map { StringCatalog.tableName(forPath: $0) }
        if let tableName { found = found.filter { $0.table == tableName } }
        guard let catalogPath else {
            if json {
                let list = found.map { e -> [String: Any] in
                    var d: [String: Any] = ["key": e.key, "table": e.table, "file": e.file, "line": e.line]
                    if let v = e.defaultValue { d["defaultValue"] = v }
                    if let c = e.comment { d["comment"] = c }
                    return d
                }
                if let data = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys]) {
                    out(String(decoding: data, as: UTF8.self))
                }
            } else {
                for e in found {
                    out("\(e.file):\(e.line): [\(e.table)] \(StringsFile.quote(e.key))" + (e.comment.map { "  /* \($0) */" } ?? ""))
                }
            }
            return 0
        }
        var catalog: StringCatalog
        if FileManager.default.fileExists(atPath: catalogPath) {
            guard let c = load(catalogPath) else { return 1 }
            catalog = c
        } else {
            catalog = StringCatalog(sourceLanguage: sourceLanguage)
        }
        let summary = catalog.merge(extracted: found)
        do { try catalog.data().write(to: URL(fileURLWithPath: catalogPath), options: .atomic) } catch {
            err("\(catalogPath): error: cannot write the catalog: \(error)")
            return 1
        }
        out("\(catalogPath): \(summary.added.count) added, \(summary.updated.count) updated, \(summary.revived.count) found again, \(summary.markedStale.count) marked stale")
        return 0
    }

    // MARK: convert

    /// The `.lproj` tables of `table` in `directory`: language → (strings, stringsdict).
    public static func legacyTables(directory: String, table: String) -> [(language: String, strings: String?, stringsdict: String?)] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        return items.filter { $0.hasSuffix(".lproj") }.sorted().compactMap { lproj in
            let dir = (directory as NSString).appendingPathComponent(lproj)
            let s = (dir as NSString).appendingPathComponent("\(table).strings")
            let d = (dir as NSString).appendingPathComponent("\(table).stringsdict")
            let hasS = fm.fileExists(atPath: s), hasD = fm.fileExists(atPath: d)
            guard hasS || hasD else { return nil }
            return (String(lproj.dropLast(6)), hasS ? s : nil, hasD ? d : nil)
        }
    }

    static func convert(_ args: [String]) -> Int32 {
        var dir: String?
        var table = "Localizable"
        var sourceLanguage = "en"
        var output: String?
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--table":
                guard let v = it.next() else { err(usage); return 2 }
                table = v
            case "--source-language":
                guard let v = it.next() else { err(usage); return 2 }
                sourceLanguage = v
            case "-o", "--output":
                guard let v = it.next() else { err(usage); return 2 }
                output = v
            default:
                if a.hasPrefix("-") || dir != nil { err(usage); return 2 }
                dir = a
            }
        }
        guard let dir else { err(usage); return 2 }
        let found = legacyTables(directory: dir, table: table)
        guard !found.isEmpty else { err("\(dir): error: no .lproj folder holds \(table).strings or \(table).stringsdict"); return 1 }
        var tables: [StringCatalogConverter.LanguageTable] = []
        for f in found {
            // `Base.lproj` holds Interface Builder files, not a language.
            let language = f.language == "Base" ? sourceLanguage : f.language
            do { tables.append(try .read(language: language, strings: f.strings, stringsdict: f.stringsdict)) } catch {
                err("\(f.strings ?? f.stringsdict ?? dir): error: \(error)")
                return 1
            }
        }
        let (catalog, warnings) = StringCatalogConverter.catalog(sourceLanguage: sourceLanguage, tables: tables)
        for w in warnings { err("\(dir): \(w)") }
        let path = output ?? (dir as NSString).appendingPathComponent("\(table).xcstrings")
        do { try catalog.data().write(to: URL(fileURLWithPath: path), options: .atomic) } catch {
            err("\(path): error: cannot write the catalog: \(error)")
            return 1
        }
        out("\(path): \(catalog.keys.count) keys, \(catalog.languages.count) languages")
        return 0
    }

    // MARK: info

    static func info(_ args: [String]) -> Int32 {
        guard let path = args.first, let catalog = load(path) else { err(usage); return 2 }
        out("\(path): source language \(catalog.sourceLanguage), \(catalog.keys.count) keys")
        for lang in catalog.languages {
            out("  \(lang): \(catalog.progress(language: lang))% translated")
        }
        return 0
    }
}
