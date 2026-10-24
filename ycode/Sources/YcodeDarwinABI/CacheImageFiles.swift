import Foundation

/// Cache-only image files (`specs/simulator/app-launch.md` §3.5): the
/// runtime's dyld shared cache holds most of its frameworks and libraries,
/// and the runtime root has no file at their paths (a framework directory
/// holds only its resources). Code that looks for a bundle's executable on
/// disk before it asks the loader (CoreFoundation's bundle lookup, which
/// WebKit's helper processes use to find their entry points) then reports
/// "no executable" for a framework that is already loaded.
///
/// Ycode's answer (a Ycode design choice, pending the reference answer in
/// app-launch.md §8 Q1): a guest `stat`, `lstat` or `access` of
/// `RR + P`, where nothing exists on the host and `P` is the path of an
/// image in the cache, reports a read-only regular file. Only the metadata
/// exists: `open` of such a path still fails with ENOENT. Paths below
/// `/usr/lib/system/` are excluded (the loader treats files there as host
/// libraries, `host-library-loading.md` §1.4). `YCODE_CACHE_IMAGE_FILES=0`
/// turns this off.
///
/// The runtime keeps some frameworks below `System/Cryptexes/OS` and links
/// them into `System/Library/Frameworks`; a path with or without that
/// prefix matches an image under either spelling.
public final class CacheImageFiles: @unchecked Sendable {
    /// The cryptex directory of the runtime root.
    public static let cryptexPrefix = "/System/Cryptexes/OS"
    /// Excluded: the host-library directory.
    public static let excludedPrefix = "/usr/lib/system/"

    /// Off with `YCODE_CACHE_IMAGE_FILES=0`.
    public static let enabledByEnvironment: Bool =
        getenv("YCODE_CACHE_IMAGE_FILES").map { String(cString: $0) != "0" } ?? true

    /// The runtime root as the guest sees it (normalized, no trailing "/").
    public let runtimeRoot: String
    private let loadImagePaths: () -> [String]
    private let lock = NSLockLike(name: "cache image files")
    private var imagePaths: Set<String>?

    /// `imagePaths` lists the cache's image paths (install names); it is
    /// called once, at the first lookup.
    public init(runtimeRoot: String, imagePaths: @escaping () -> [String]) {
        var root = runtimeRoot
        while root.count > 1 && root.hasSuffix("/") { root.removeLast() }
        self.runtimeRoot = root
        self.loadImagePaths = imagePaths
    }

    private func paths() -> Set<String> {
        lock.withLock {
            if let p = imagePaths { return p }
            let p = Set(loadImagePaths())
            imagePaths = p
            return p
        }
    }

    /// The cache image path that the normalized guest path `guestPath`
    /// names, or nil (not below the runtime root, excluded, or not an image).
    public func imagePath(forGuestPath guestPath: String) -> String? {
        guard guestPath.hasPrefix(runtimeRoot + "/") else { return nil }
        let inner = String(guestPath.dropFirst(runtimeRoot.count))
        guard !inner.hasPrefix(Self.excludedPrefix) else { return nil }
        let set = paths()
        if set.contains(inner) { return inner }
        if inner.hasPrefix(Self.cryptexPrefix + "/") {
            let bare = String(inner.dropFirst(Self.cryptexPrefix.count))
            if !bare.hasPrefix(Self.excludedPrefix) && set.contains(bare) { return bare }
        } else if set.contains(Self.cryptexPrefix + inner) {
            return Self.cryptexPrefix + inner
        }
        return nil
    }

    /// The stat data of the image file at `guestPath`, or nil. `dev` is
    /// the device to report (the runtime root's).
    public func stat(forGuestPath guestPath: String, dev: UInt32) -> DarwinStat? {
        guard let image = imagePath(forGuestPath: guestPath) else { return nil }
        return DarwinStat(dev: dev, mode: DarwinStat.S_IFREG | 0o555, nlink: 1, ino: Self.inode(image),
                          uid: 0, gid: 0, size: 0, blksize: 4096)
    }

    /// A stable inode number per image (outside the host's usual range).
    static func inode(_ image: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in image.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return 0x7963_0000_0000_0000 | (h & 0xFFFF_FFFF)
    }
}
