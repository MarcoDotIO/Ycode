import Foundation
import YcodeProject

/// Command-line front end. The GUI will share these libraries.
func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: ycode describe <path.xcodeproj>
           ycode roundtrip [--print] <path.xcodeproj>...

    """.utf8))
    exit(2)
}

func describe(_ path: String) throws {
    let (file, name) = PBXProj.locate(path)
    let proj = try PBXProj(contentsOf: file)
    print("\(name) (objectVersion \(proj.objectVersion), \(proj.objects.count) objects)")
    for target in proj.targets {
        let type = target.string("productType") ?? target.isa
        print("  target \(target.string("name") ?? "?")  [\(type)]")
        for config in proj.buildConfigurations(listID: target.string("buildConfigurationList")) {
            let settings = config["buildSettings"]?.dictionary?.count ?? 0
            print("    config \(config.string("name") ?? "?")  (\(settings) settings)")
        }
    }
}

/// Parses and re-serializes each project; exit status 1 if any differ.
func roundtrip(_ paths: [String], printOutput: Bool) -> Int32 {
    var failures: Int32 = 0
    for path in paths {
        let (file, name) = PBXProj.locate(path)
        do {
            let original = try String(contentsOf: file, encoding: .utf8)
            let written = try PBXProj(parsing: original).serialized(projectName: name)
            if printOutput { print(written, terminator: "") }
            if written == original {
                FileHandle.standardError.write(Data("ok    \(path)\n".utf8))
            } else {
                failures = 1
                let a = original.split(separator: "\n", omittingEmptySubsequences: false)
                let b = written.split(separator: "\n", omittingEmptySubsequences: false)
                let i = (0..<min(a.count, b.count)).first { a[$0] != b[$0] } ?? min(a.count, b.count)
                let want = i < a.count ? String(a[i]) : "<eof>"
                let got = i < b.count ? String(b[i]) : "<eof>"
                FileHandle.standardError.write(Data("DIFF  \(path)\n  line \(i + 1)\n  want: \(want)\n  got:  \(got)\n".utf8))
            }
        } catch {
            failures = 1
            FileHandle.standardError.write(Data("ERROR \(path): \(error)\n".utf8))
        }
    }
    return failures
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()
switch command {
case "describe":
    guard args.count == 1 else { usage() }
    do { try describe(args[0]) } catch {
        FileHandle.standardError.write(Data("ycode: \(error)\n".utf8))
        exit(1)
    }
case "roundtrip":
    let printOutput = args.contains("--print")
    let paths = args.filter { $0 != "--print" }
    guard !paths.isEmpty else { usage() }
    exit(roundtrip(paths, printOutput: printOutput))
default:
    usage()
}
