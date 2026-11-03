import Foundation

/// One change a project navigator operation makes on disk. Every step can
/// be undone, and nothing is ever deleted outright: undoing a creation or
/// a copy moves the new item to the trash, and a trashed item is moved
/// back from there. See `specs/ide/navigators.md` §Ycode implementation.
public enum FileStep: Equatable, Sendable {
    case createFile(URL, Data)
    case createDirectory(URL)
    case move(URL, URL)
    case copy(URL, URL)
    case trash(URL)
}

/// Where an operation's items go when they are trashed: the user's trash
/// (`Trash`), or, in tests, a folder of the test's own.
public struct TrashBin: Sendable {
    public let moveToTrash: @Sendable (URL) throws -> URL
    public let restore: @Sendable (URL, URL) throws -> Void

    public init(moveToTrash: @escaping @Sendable (URL) throws -> URL, restore: @escaping @Sendable (URL, URL) throws -> Void) {
        self.moveToTrash = moveToTrash
        self.restore = restore
    }

    /// The Finder's Trash on macOS, the freedesktop.org trash on Linux.
    public static let user = TrashBin(moveToTrash: { try Trash.moveReturningLocation($0) },
                                      restore: { try Trash.restore($0, to: $1) })

    /// A plain folder standing in for the trash (tests): items are moved
    /// into it under a unique name.
    public static func folder(_ dir: URL) -> TrashBin {
        TrashBin(moveToTrash: { url in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(UUID().uuidString).appendingPathComponent(url.lastPathComponent)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }, restore: { try FileManager.default.moveItem(at: $0, to: $1) })
    }
}

/// Performs file steps and remembers how to reverse them.
public struct FileSystemJournal: Sendable {
    /// A performed step: the step and, for a trash, where the item went.
    public struct Entry: Equatable, Sendable {
        public var step: FileStep
        public var trashedTo: URL?
    }

    public let bin: TrashBin
    public private(set) var entries: [Entry] = []

    public init(bin: TrashBin = .user) { self.bin = bin }

    /// Performs a step and records it.
    public mutating func perform(_ step: FileStep) throws {
        entries.append(Entry(step: step, trashedTo: try Self.run(step, bin: bin)))
    }

    /// Forgets the recorded steps (they stay done).
    public mutating func takeEntries() -> [Entry] {
        defer { entries = [] }
        return entries
    }

    @discardableResult
    static func run(_ step: FileStep, bin: TrashBin) throws -> URL? {
        let fm = FileManager.default
        switch step {
        case .createFile(let u, let data):
            guard !fm.fileExists(atPath: u.path) else { throw NavigatorEditError.exists(u.lastPathComponent) }
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: u, options: .withoutOverwriting)
        case .createDirectory(let u):
            guard !fm.fileExists(atPath: u.path) else { throw NavigatorEditError.exists(u.lastPathComponent) }
            try fm.createDirectory(at: u, withIntermediateDirectories: true)
        case .move(let a, let b):
            guard !fm.fileExists(atPath: b.path) || Self.sameItemDifferentCase(a, b) else { throw NavigatorEditError.exists(b.lastPathComponent) }
            try fm.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: a, to: b)
        case .copy(let a, let b):
            guard !fm.fileExists(atPath: b.path) else { throw NavigatorEditError.exists(b.lastPathComponent) }
            try fm.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: a, to: b)
        case .trash(let u):
            return try bin.moveToTrash(u)
        }
        return nil
    }

    /// A rename that only changes letter case on a case-insensitive volume.
    static func sameItemDifferentCase(_ a: URL, _ b: URL) -> Bool {
        a.path != b.path && a.path.lowercased() == b.path.lowercased()
            && (try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject)
            == (try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject)
    }

    /// Reverses performed entries, last first.
    static func undo(_ entries: [Entry], bin: TrashBin) throws {
        for e in entries.reversed() {
            switch e.step {
            case .createFile(let u, _), .createDirectory(let u), .copy(_, let u):
                if FileManager.default.fileExists(atPath: u.path) { _ = try bin.moveToTrash(u) }
            case .move(let a, let b):
                try FileManager.default.moveItem(at: b, to: a)
            case .trash(let u):
                if let t = e.trashedTo { try bin.restore(t, u) }
            }
        }
    }

    /// Performs the steps of `entries` again (a redo); returns the new entries.
    static func redo(_ entries: [Entry], bin: TrashBin) throws -> [Entry] {
        try entries.map { Entry(step: $0.step, trashedTo: try run($0.step, bin: bin)) }
    }
}
