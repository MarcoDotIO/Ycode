import Foundation

/// `ycode profile` (specs/ide/profiler.md §7): record Linux processes or a
/// Ycode simulator app, and read Gauge traces as text, call trees, flame
/// graphs and source annotations. `out` gets the command's output, `err`
/// its messages.
public enum GaugeCLI {
    public static func run(_ args: [String], out: @escaping (String) -> Void = { print($0, terminator: "") },
                           err: @escaping (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }) -> Int32 {
        profileCommand(args, out: out, err: err)
    }
}

let profileUsage = """
usage: ycode profile record --linux [--rate HZ] [--seconds S] [--backend auto|perf|agent] [--agent LIB.so] [--kernel]
                            -o out.gaugetrace -- <command> [args...]
       ycode profile record --linux --pid N [--rate HZ] [--seconds S] -o out.gaugetrace
       ycode profile record --simd <ycode-simd> -o out.gaugetrace -- <ycode-simd device-mode args...>
       ycode profile summary <trace> [--top N] [filters]
       ycode profile tree <trace> [--invert] [--threads] [--hide-system] [--flatten] [--charge IMAGE|FUNCTION]...
                          [--depth N] [--min-percent P] [filters]
       ycode profile flame <trace> -o out.svg [--width W] [tree options] [filters]
       ycode profile annotate <trace> <function> [--source FILE] [filters]
       ycode profile symbolicate <trace> [--search PATH]... [-o out.gaugetrace]
filters: --range BEGIN_MS:END_MS  --thread ID  --all-states

"""

struct ProfileFailure: Error, CustomStringConvertible { var description: String }

func profileCommand(_ args: [String], out: (String) -> Void, err: (String) -> Void) -> Int32 {
    guard let sub = args.first else {
        err(profileUsage)
        return 2
    }
    do {
        switch sub {
        case "record": return try profileRecord(Array(args.dropFirst()), err: err)
        case "summary", "tree", "flame", "annotate", "symbolicate": return try profileRead(sub, Array(args.dropFirst()), out: out, err: err)
        default:
            err(profileUsage)
            return 2
        }
    } catch {
        err("ycode profile: \(error)\n")
        return 1
    }
}

/// Options shared by the reading subcommands.
struct ProfileReadOptions {
    var filter = SampleFilter()
    var tree = CallTreeOptions()
    var charge: [String] = []
    var top = 15
    var depth = 40
    var minPercent = 0.5
    var output: String?
    var width = 1200
    var search: [String] = []
    var source: String?
    var positional: [String] = []
}

func parseProfileReadOptions(_ args: [String]) throws -> ProfileReadOptions {
    var o = ProfileReadOptions()
    var i = 0
    func value() throws -> String {
        i += 1
        guard i < args.count else { throw ProfileFailure(description: "\(args[i - 1]) needs a value") }
        return args[i]
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "--range":
            let v = try value().split(separator: ":")
            guard v.count == 2, let b = Double(v[0]), let e = Double(v[1]), e > b, b >= 0 else { throw ProfileFailure(description: "--range BEGIN_MS:END_MS") }
            o.filter.range = UInt64(b * 1e6)..<UInt64(e * 1e6)
        case "--thread":
            let v = try value()
            guard let t = v.hasPrefix("0x") ? UInt64(v.dropFirst(2), radix: 16) : UInt64(v) else { throw ProfileFailure(description: "--thread ID") }
            o.filter.threads = (o.filter.threads ?? []).union([t])
        case "--all-states": o.filter.allStates = true
        case "--invert": o.tree.invert = true
        case "--threads": o.tree.separateByThread = true
        case "--hide-system": o.tree.hideSystemLibraries = true
        case "--flatten": o.tree.flattenRecursion = true
        case "--charge": o.charge.append(try value())
        case "--top": o.top = Int(try value()) ?? 15
        case "--depth": o.depth = Int(try value()) ?? 40
        case "--min-percent": o.minPercent = Double(try value()) ?? 0.5
        case "-o", "--output": o.output = try value()
        case "--width": o.width = Int(try value()) ?? 1200
        case "--search", "--dsym", "--binary": o.search.append(try value())
        case "--source": o.source = try value()
        default:
            if a.hasPrefix("-") { throw ProfileFailure(description: "unknown option \(a)") }
            o.positional.append(a)
        }
        i += 1
    }
    return o
}

/// Images or functions named by --charge.
func resolveCharges(_ names: [String], in t: GaugeTrace, into o: inout CallTreeOptions) {
    for name in names {
        if let img = t.images.first(where: { $0.name == name }) { o.chargedImages.insert(img.id); continue }
        for img in t.images {
            for s in img.symbols where s.name == name { o.chargedFunctions.insert(FunctionRef(image: img.id, start: s.start)) }
        }
    }
}

func profileRead(_ sub: String, _ args: [String], out: (String) -> Void, err: (String) -> Void) throws -> Int32 {
    var o = try parseProfileReadOptions(args)
    guard let path = o.positional.first else { throw ProfileFailure(description: "\(sub) needs a trace path") }
    var t = try GaugeTraceCodec.read(URL(fileURLWithPath: path))
    GaugeSymbolicator.demangle(&t)
    if !o.search.isEmpty {
        let changed = GaugeSymbolicator.symbolicateMachO(&t, searching: o.search.map { URL(fileURLWithPath: $0) })
        GaugeSymbolicator.demangle(&t)
        if sub == "symbolicate" {
            err("symbolicated: \(changed.isEmpty ? "nothing matched" : changed.joined(separator: ", "))\n")
        }
    }
    resolveCharges(o.charge, in: t, into: &o.tree)
    switch sub {
    case "summary":
        out(GaugeReport.summary(t, top: o.top, filter: o.filter))
    case "tree":
        out(GaugeReport.tree(CallTree(trace: t, filter: o.filter, options: o.tree), maxDepth: o.depth, minPercent: o.minPercent))
    case "flame":
        var tree = o.tree
        tree.invert = false
        let fg = FlameGraph(tree: CallTree(trace: t, filter: o.filter, options: tree))
        let title = "Gauge: " + (t.recording.command.isEmpty ? (path as NSString).lastPathComponent : t.recording.command)
        let svg = fg.svg(width: o.width, title: title, intervalNs: t.recording.sampleIntervalNs)
        if let file = o.output { try svg.write(toFile: file, atomically: true, encoding: .utf8) } else { out(svg) }
    case "annotate":
        guard o.positional.count >= 2 else { throw ProfileFailure(description: "annotate needs a function name") }
        let name = o.positional[1]
        let top = CallTree.topFunctions(trace: t, filter: o.filter)
        guard let f = top.first(where: { $0.name == name }) ?? top.first(where: { $0.name.contains(name) }) else {
            throw ProfileFailure(description: "no function named \(name) in the samples")
        }
        let a = SourceAnnotation(trace: t, function: f.function, filter: o.filter)
        out("\(f.name) (\(f.image)): \(a.samples) samples; source \(a.file ?? "unknown (no line information: symbolicate with the dSYM)")\n")
        if let file = o.source ?? a.file, let text = try? String(contentsOfFile: file, encoding: .utf8) {
            out(a.render(source: text))
        } else {
            for l in a.lines { out(String(format: "%7d %7d  line %d\n", l.selfCount, l.total, l.line)) }
        }
    case "symbolicate":
        try GaugeTraceCodec.write(t, to: URL(fileURLWithPath: o.output ?? path))
    default:
        break
    }
    return 0
}

func profileRecord(_ args: [String], err: (String) -> Void) throws -> Int32 {
    var linux = false
    var simd: String?
    var output: String?
    var options = LinuxRecordOptions()
    var rest: [String] = []
    var i = 0
    func value() throws -> String {
        i += 1
        guard i < args.count else { throw ProfileFailure(description: "\(args[i - 1]) needs a value") }
        return args[i]
    }
    while i < args.count {
        let a = args[i]
        if a == "--" { rest = Array(args[(i + 1)...]); break }
        switch a {
        case "--linux": linux = true
        case "--simd": simd = try value()
        case "-o", "--output": output = try value()
        case "--rate": options.rate = Int(try value()) ?? 1000
        case "--seconds": options.seconds = Double(try value())
        case "--pid": options.pid = Int(try value())
        case "--backend":
            guard let b = LinuxRecordOptions.Backend(rawValue: try value()) else { throw ProfileFailure(description: "--backend auto|perf|agent") }
            options.backend = b
        case "--agent": options.agentPath = try value()
        case "--kernel": options.kernel = true
        default:
            if a.hasPrefix("-") { throw ProfileFailure(description: "unknown option \(a)") }
            rest = Array(args[i...])
            i = args.count
        }
        i += 1
    }
    guard let output else { throw ProfileFailure(description: "record needs -o <out.gaugetrace>") }
    if let simd {
        // The simulator back end: ycode-simd with --profile (it writes the trace).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: simd)
        p.arguments = rest + ["--profile", output, "--profile-rate", String(options.rate)]
            + (options.seconds.map { ["--profile-seconds", String($0)] } ?? [])
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT)
        source.setEventHandler { p.interrupt() }
        source.resume()
        try p.run()
        p.waitUntilExit()
        if FileManager.default.fileExists(atPath: output) {
            err("ycode profile: wrote \(output)\n")
            return 0
        }
        throw ProfileFailure(description: "ycode-simd ended with status \(p.terminationStatus) and wrote no trace")
    }
    guard linux else { throw ProfileFailure(description: "record needs --linux or --simd") }
    if options.pid == nil {
        guard !rest.isEmpty else { throw ProfileFailure(description: "record --linux needs a command after -- (or --pid)") }
        options.command = rest
    }
    if options.agentPath == nil {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidate = exe.deletingLastPathComponent().appendingPathComponent("libYcodeGaugeAgent.so").path
        if FileManager.default.fileExists(atPath: candidate) { options.agentPath = candidate }
    }
    let trace = try LinuxRecorder.record(options) { err("ycode profile: \($0)\n") }
    try GaugeTraceCodec.write(trace, to: URL(fileURLWithPath: output))
    err("ycode profile: wrote \(output): \(trace.samples.count) samples, \(trace.threads.count) threads\n")
    return 0
}
