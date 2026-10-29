import Foundation

/// Library content: Ycode's own code snippets and a hand-written list of
/// symbol names. See `specs/ide/library.md`. Everything here was written
/// for Ycode; nothing is taken from another product's files.
public struct LibrarySnippet: Equatable, Sendable {
    public var title: String
    public var summary: String
    public var language: String
    public var body: String
}

/// The Library's built-in content (`specs/ide/library.md`).
public enum LibraryContent {
    /// Ycode's code snippets, with `<#placeholder#>` tokens in their bodies.
    public static let snippets: [LibrarySnippet] = [
        .init(title: "Guard Let", summary: "Unwrap an optional or leave the scope", language: "Swift",
              body: "guard let <#name#> = <#optional#> else {\n    <#return#>\n}"),
        .init(title: "If Let", summary: "Run code when an optional has a value", language: "Swift",
              body: "if let <#name#> = <#optional#> {\n    <#code#>\n}"),
        .init(title: "Switch", summary: "Branch on the cases of a value", language: "Swift",
              body: "switch <#value#> {\ncase <#pattern#>:\n    <#code#>\ndefault:\n    <#code#>\n}"),
        .init(title: "For-In Loop", summary: "Iterate over a sequence", language: "Swift",
              body: "for <#item#> in <#sequence#> {\n    <#code#>\n}"),
        .init(title: "While Loop", summary: "Repeat while a condition holds", language: "Swift",
              body: "while <#condition#> {\n    <#code#>\n}"),
        .init(title: "Do-Catch", summary: "Call throwing code and handle errors", language: "Swift",
              body: "do {\n    try <#expression#>\n} catch {\n    <#handle error#>\n}"),
        .init(title: "Defer", summary: "Run cleanup when the scope exits", language: "Swift",
              body: "defer {\n    <#cleanup#>\n}"),
        .init(title: "Function", summary: "A function with parameters and a result", language: "Swift",
              body: "func <#name#>(<#parameters#>) -> <#Result#> {\n    <#body#>\n}"),
        .init(title: "Async Function", summary: "A function that can suspend", language: "Swift",
              body: "func <#name#>(<#parameters#>) async throws -> <#Result#> {\n    <#body#>\n}"),
        .init(title: "Struct", summary: "A value type with stored properties", language: "Swift",
              body: "struct <#Name#> {\n    var <#property#>: <#Type#>\n}"),
        .init(title: "Class", summary: "A reference type with an initializer", language: "Swift",
              body: "final class <#Name#> {\n    init() {\n        <#code#>\n    }\n}"),
        .init(title: "Enum", summary: "A type with a fixed set of cases", language: "Swift",
              body: "enum <#Name#> {\n    case <#first#>\n    case <#second#>\n}"),
        .init(title: "Protocol", summary: "Requirements that types can adopt", language: "Swift",
              body: "protocol <#Name#> {\n    func <#requirement#>()\n}"),
        .init(title: "Extension", summary: "Add members to an existing type", language: "Swift",
              body: "extension <#Type#> {\n    <#members#>\n}"),
        .init(title: "Computed Property", summary: "A property computed on access", language: "Swift",
              body: "var <#name#>: <#Type#> {\n    <#expression#>\n}"),
        .init(title: "Closure", summary: "An inline function value", language: "Swift",
              body: "{ <#parameters#> in\n    <#statements#>\n}"),
        .init(title: "Task", summary: "Start asynchronous work", language: "Swift",
              body: "Task {\n    <#await work#>\n}"),
        .init(title: "Actor", summary: "A type that serializes access to its state", language: "Swift",
              body: "actor <#Name#> {\n    var <#state#>: <#Type#>\n}"),
        .init(title: "Test Function", summary: "A test using the Testing package", language: "Swift",
              body: "@Test func <#name#>() throws {\n    #expect(<#condition#>)\n}"),
        .init(title: "Test Suite", summary: "A group of related tests", language: "Swift",
              body: "@Suite struct <#Name#>Tests {\n    @Test func <#name#>() {\n        #expect(<#condition#>)\n    }\n}"),
        .init(title: "MARK Comment", summary: "A section marker for the jump bar", language: "Swift",
              body: "// MARK: - <#Section#>"),
        .init(title: "TODO Comment", summary: "A reminder that shows in the jump bar", language: "Swift",
              body: "// TODO: <#note#>"),
        .init(title: "Documentation Comment", summary: "Describe a declaration for Quick Help", language: "Swift",
              body: "/// <#Summary#>\n///\n/// - Parameter <#name#>: <#description#>\n/// - Returns: <#description#>"),
        .init(title: "C Main Function", summary: "A C program entry point", language: "C",
              body: "int main(int argc, char *argv[]) {\n    <#statements#>\n    return 0;\n}"),
        .init(title: "C Include Guard", summary: "Protect a header from double inclusion", language: "C",
              body: "#ifndef <#NAME_H#>\n#define <#NAME_H#>\n\n<#declarations#>\n\n#endif"),
    ]

    /// Symbol names offered by the symbol browser, grouped by theme. A
    /// hand-written list of widely used, generic names; names the running
    /// system cannot draw are skipped at display time.
    public static let symbolNames: [String] = [
        // Arrows and navigation
        "arrow.up", "arrow.down", "arrow.left", "arrow.right", "arrow.clockwise", "arrow.counterclockwise",
        "arrow.up.circle", "arrow.down.circle", "arrow.uturn.backward", "arrow.uturn.forward",
        "arrow.triangle.2.circlepath", "arrow.up.arrow.down", "arrow.left.arrow.right",
        "chevron.up", "chevron.down", "chevron.left", "chevron.right", "chevron.up.chevron.down",
        // Shapes
        "circle", "circle.fill", "square", "square.fill", "triangle", "triangle.fill", "diamond", "diamond.fill",
        "hexagon", "seal", "capsule", "rectangle", "rectangle.fill", "oval",
        // Status and actions
        "plus", "minus", "multiply", "divide", "equal", "plus.circle", "minus.circle", "xmark", "xmark.circle",
        "checkmark", "checkmark.circle", "checkmark.circle.fill", "exclamationmark.triangle", "exclamationmark.circle",
        "questionmark.circle", "info.circle", "nosign", "slash.circle",
        // Objects
        "star", "star.fill", "heart", "heart.fill", "bookmark", "bookmark.fill", "flag", "flag.fill",
        "bell", "bell.fill", "tag", "tag.fill", "paperclip", "link", "pin", "pin.fill", "lock", "lock.open",
        "key", "trash", "trash.fill", "folder", "folder.fill", "doc", "doc.text", "doc.on.doc", "book", "books.vertical",
        "newspaper", "archivebox", "tray", "tray.full", "shippingbox", "gift", "bag", "cart", "creditcard",
        "calendar", "clock", "alarm", "timer", "stopwatch", "hourglass", "gearshape", "gearshape.2",
        "wrench.and.screwdriver", "paintbrush", "pencil", "scissors", "ruler", "magnifyingglass", "lightbulb",
        "camera", "photo", "film", "music.note", "mic", "speaker.wave.2", "headphones", "play", "pause", "stop",
        "forward", "backward", "shuffle", "repeat",
        // Communication
        "envelope", "envelope.fill", "paperplane", "bubble.left", "bubble.left.and.bubble.right", "phone",
        "video", "person", "person.fill", "person.2", "person.crop.circle", "person.3",
        // Weather and nature
        "sun.max", "moon", "moon.stars", "cloud", "cloud.rain", "cloud.bolt", "snowflake", "wind", "flame",
        "drop", "leaf", "bolt", "bolt.fill", "sparkles", "tornado", "thermometer",
        // Places and transport
        "house", "building.2", "map", "mappin", "location", "globe", "car", "bus", "tram", "airplane", "bicycle",
        "figure.walk",
        // Devices (generic)
        "desktopcomputer", "display", "keyboard", "printer", "tv", "gamecontroller", "externaldrive", "server.rack",
        "cpu", "memorychip", "wifi", "antenna.radiowaves.left.and.right", "battery.100", "power",
        // Text and layout
        "textformat", "bold", "italic", "underline", "list.bullet", "list.number", "text.alignleft",
        "text.aligncenter", "text.alignright", "square.grid.2x2", "rectangle.split.3x1", "sidebar.left",
        "slider.horizontal.3", "line.3.horizontal", "ellipsis", "ellipsis.circle",
        // Data
        "chart.bar", "chart.pie", "chart.line.uptrend.xyaxis", "tablecells", "number", "function", "sum",
        "percent", "terminal", "curlybraces", "chevron.left.forwardslash.chevron.right", "ladybug", "ant",
        "eye", "eye.slash", "hand.raised", "hand.thumbsup", "square.and.arrow.up", "square.and.arrow.down",
    ]
}
