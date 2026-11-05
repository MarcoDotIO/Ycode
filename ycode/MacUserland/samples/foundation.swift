// foundation.swift - the stage-B sample (specs/macos/macos-apps.md §9.4):
// Date, JSONEncoder and JSONDecoder, FileManager, from swift-foundation's
// FoundationEssentials on Ycode's macOS userland. Built by swift/build.sh;
// run-samples.sh checks its output against foundation.expected.
import FoundationEssentials
import Darwin

struct Item: Codable, Equatable {
    var name: String
    var count: Int
    var price: Double
    var tags: [String]
    var created: Date
}

@main
struct StageB {
    static func main() throws {
        // Date
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        print("Date:", epoch.timeIntervalSinceReferenceDate, epoch.timeIntervalSince1970)
        print("Later than 2023:", Date() > epoch)
        let span = Date(timeIntervalSince1970: 1_700_086_400).timeIntervalSince(epoch)
        print("One day:", span, "s")
        print("ISO 8601:", epoch.formatted(.iso8601))

        // JSONEncoder and JSONDecoder
        let items = [
            Item(name: "apple", count: 3, price: 0.5, tags: ["fruit", "red"], created: epoch),
            Item(name: "bread", count: 1, price: 2.25, tags: [], created: epoch.addingTimeInterval(3600)),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(items)
        print(String(decoding: data, as: UTF8.self))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode([Item].self, from: data)
        print("Round trip equal:", back == items)
        let dict = try JSONDecoder().decode([String: Double].self, from: Data(#"{"pi": 3.14159, "e": 2.71828}"#.utf8))
        print("Decoded:", dict.sorted { $0.key < $1.key })

        // FileManager
        let fm = FileManager.default
        let base = URL(fileURLWithPath: fm.temporaryDirectory.path).appendingPathComponent("ycode-stage-b-\(getpid())")
        try fm.createDirectory(at: base.appendingPathComponent("sub/deeper"), withIntermediateDirectories: true)
        let file = base.appendingPathComponent("items.json")
        try data.write(to: file)
        try Data("hello\n".utf8).write(to: base.appendingPathComponent("sub/hello.txt"))
        let reread = try Data(contentsOf: file)
        print("File bytes:", reread.count, reread == data)
        print("Exists:", fm.fileExists(atPath: file.path))
        print("Contents:", try fm.contentsOfDirectory(atPath: base.path).sorted())
        let attributes = try fm.attributesOfItem(atPath: file.path)
        print("Size attribute:", attributes[.size].map { "\($0)" } ?? "none")
        var isDirectory = false
        _ = fm.fileExists(atPath: base.appendingPathComponent("sub").path, isDirectory: &isDirectory)
        print("sub is a directory:", isDirectory)
        print("Walk:", try fm.subpathsOfDirectory(atPath: base.path).sorted())
        try fm.copyItem(atPath: file.path, toPath: base.appendingPathComponent("copy.json").path)
        try fm.moveItem(atPath: base.appendingPathComponent("copy.json").path, toPath: base.appendingPathComponent("moved.json").path)
        print("After copy and move:", try fm.contentsOfDirectory(atPath: base.path).sorted())
        try fm.removeItem(at: base)
        print("Removed:", !fm.fileExists(atPath: base.path))
    }
}
