// Choosing the stream's encoding (display-stream.md §14): the client lists
// what it decodes, best first; the server takes the first it can encode. No
// choice is silent: a client that gets less than its first wish says which
// encoding it got, why each better one is missing, and what to expect of it.

public enum DisplayCodecChoice {
    /// The order of preference: hevc 4:4:4 → hevc → h264 → jpeg → zlib.
    public static let preference = ["hevc444", "hevc", "h264", "jpeg", "zlib"]

    /// What an encoding gives at 2160 × 3840 (measured, display-stream.md §14.2).
    public static func expectation(_ name: String) -> String {
        switch name {
        case "hevc444", "hevc", "h264": "the guest's full picture rate"
        case "jpeg": "the guest's picture rate at about 20 MB/s, softer colour edges than HEVC 4:4:4"
        case "zlib": "about 4-9 pictures a second and 30-90 MB/s (encode 40-90 ms a picture)"
        default: "an unknown rate"
        }
    }

    /// The wishes in order: `first` (nil: auto), then what comes after it in the preference.
    public static func wishes(first: String?) -> [String] {
        guard let first, let i = preference.firstIndex(of: first) else { return preference }
        return Array(preference[i...])
    }

    /// The client's hello lists: what this client can decode of its wishes, and why not the others.
    public static func decodable(wishes: [String], problem: (String) -> String?) -> (usable: [String], missing: [(name: String, why: String)]) {
        var usable: [String] = [], missing: [(String, String)] = []
        for w in wishes {
            if let why = problem(w) { missing.append((w, why)) } else { usable.append(w) }
        }
        return (usable, missing)
    }

    /// What the server sends for a hello (§14): the first of the client's list
    /// it offers; else its `encoding` when offered; else the server's first.
    public static func serverPick(hello: DisplayClientHello, offered: [String]) -> String {
        if let list = hello.encodings, let e = list.first(where: offered.contains) { return e }
        if offered.contains(hello.encoding) { return hello.encoding }
        return offered.first ?? "zlib"
    }

    /// The loud line when the stream runs on anything but the first wish; nil when it got it.
    public static func warning(viewer: String, wishes: [String], missing: [(name: String, why: String)], offered: [String]?, chosen: String) -> String? {
        guard let best = wishes.first, best != chosen else { return nil }
        var reasons: [String] = []
        for w in wishes {
            if w == chosen { break }
            if let m = missing.first(where: { $0.name == w }) { reasons.append("\(w): \(m.why)") }
            else if let offered, !offered.contains(w) { reasons.append("\(w): the server does not offer it (it offers \(offered.joined(separator: ", ")))") }
        }
        return "\(viewer): WARNING: the stream falls back to \(chosen), expect \(expectation(chosen)). "
            + (reasons.isEmpty ? "" : "Better encodings are missing: " + reasons.joined(separator: "; ") + ". ")
            + "Choose one with --encoding."
    }
}
