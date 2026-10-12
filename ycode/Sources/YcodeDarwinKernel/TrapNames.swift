/// Names of Darwin traps, from the JSON tables of
/// `specs/simulator/darwin-trap-tables.md` (embedded as
/// `GeneratedTrapNames`). Used only for log lines.
public enum TrapNames {
    public struct Entry: Equatable, Sendable {
        public var name: String
        public var argumentNames: [String]
    }

    private static func parse(_ table: String) -> [Entry] {
        table.split(separator: ";", omittingEmptySubsequences: false).map { item in
            let parts = item.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let args = parts.count > 1 && !parts[1].isEmpty ? parts[1].split(separator: ",").map(String.init) : []
            return Entry(name: String(parts[0]), argumentNames: args)
        }
    }

    /// BSD slots 0…557.
    public static let bsd: [Entry] = parse(GeneratedTrapNames.bsd)
    /// Mach slots 0…127, indexed by −x16.
    public static let mach: [Entry] = parse(GeneratedTrapNames.mach)

    /// The entry for BSD call `number`; numbers ≥ 558 map to slot 63 (`nosys`).
    public static func bsd(_ number: Int) -> Entry {
        bsd.indices.contains(number) ? bsd[number] : bsd[63]
    }

    /// The entry for Mach trap `number` (negative); out-of-range numbers are `kern_invalid`.
    public static func mach(_ number: Int) -> Entry {
        let index = -number
        return mach.indices.contains(index) ? mach[index] : Entry(name: "kern_invalid", argumentNames: [])
    }

    /// `name(arg=0x…, …)` for a call with the given argument registers.
    static func describe(_ entry: Entry, _ args: [UInt64]) -> String {
        let shown = entry.argumentNames.enumerated().map { i, n in "\(n)=\(hx(i < args.count ? args[i] : 0))" }
        return "\(entry.name)(\(shown.joined(separator: ", ")))"
    }
}
