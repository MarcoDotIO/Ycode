import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// getattrlistbulk record forms (visionos.md §10.15.2, §10.15.3):
/// ATTR_CMN_ERROR and its word only with FSOPT_PACK_INVAL_ATTRS, and the
/// depth-first listing Foundation runs over a tree of directories.
@Suite struct AttributeListBulkTests {
    static let returned: UInt32 = 0x8000_0000, error: UInt32 = 0x2000_0000
    static let name: UInt32 = 0x1, objType: UInt32 = 0x8
    static let packInvalid: UInt64 = 0x8, cmnExtended: UInt64 = 0x20
    /// The request of RealityEnvironment's listing (§10.15.2 step 3).
    static let deepCommon: UInt32 = 0xF01F_9E0D
    static let oDirectory: UInt64 = 0x100000, oCloexec: UInt64 = 0x1000000

    struct Record {
        var bytes: [UInt8]
        var length: Int { Int(bytes.readLE(UInt32.self, at: 0)) }
        func set(_ group: Int) -> UInt32 { bytes.readLE(UInt32.self, at: 4 + 4 * group) }
        func u32(_ at: Int) -> UInt32 { bytes.readLE(UInt32.self, at: at) }
        func name(refAt: Int) -> String {
            let at = refAt + Int(bytes.readLE(Int32.self, at: refAt))
            return String(decoding: bytes[at...].prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    let env: ProcEnv
    var k: DarwinKernel { env.rootKernel }
    let at = ProcEnv.At.out
    var alistAt: UInt64 { at + 0x100 }
    var bufferAt: UInt64 { at + 0x1000 }

    init() throws { env = try ProcEnv() }

    func make(_ files: [String], dirs: [String] = []) throws -> String {
        let base = env.root + "/SE"
        for d in dirs { try FileManager.default.createDirectory(atPath: base + "/" + d, withIntermediateDirectories: true) }
        for f in files {
            let url = URL(fileURLWithPath: base + "/" + f)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(f.utf8).write(to: url)
        }
        return base
    }

    func open(_ path: String) -> UInt64 {
        env.putString(k, path, at: at)
        let fd = env.bsd(k, 5, [at, Self.oDirectory | Self.oCloexec, 0])
        #expect(fd >= 0, "open \(path)")
        return UInt64(fd)
    }

    func request(common: UInt32, dir: UInt32 = 0, file: UInt32 = 0, fork: UInt32 = 0) {
        var alist = [UInt8](repeating: 0, count: 24)
        alist.putLE(UInt16(5), at: 0)
        for (i, v) in [common, 0, dir, file, fork].enumerated() { alist.putLE(v, at: 4 + 4 * i) }
        env.put(k, alist, at: alistAt)
    }

    /// One call; the records it returned (nil: an error, with `errno` set).
    func bulk(_ fd: UInt64, size: Int, options: UInt64) -> [Record]? {
        let n = env.bsd(k, 461, [fd, alistAt, bufferAt, UInt64(size), options])
        guard n >= 0 else { return nil }
        let buf = env.read(k, bufferAt, size)
        var out: [Record] = [], o = 0
        for _ in 0..<n {
            let length = Int(buf.readLE(UInt32.self, at: o))
            out.append(Record(bytes: Array(buf[o..<(o + length)])))
            o += length
        }
        return out
    }

    /// Without FSOPT_PACK_INVAL_ATTRS a requested ATTR_CMN_ERROR is neither
    /// returned nor packed: the name reference follows the attribute set.
    @Test func errorOmittedWithoutPackInvalid() throws {
        let base = try make(["a"], dirs: ["d"])
        request(common: Self.returned | Self.error | Self.name | Self.objType)
        let records = try #require(bulk(open(base), size: 0x2000, options: 0))
        #expect(records.count == 2)
        for r in records {
            #expect(r.length % 8 == 0)
            #expect(r.set(0) == Self.returned | Self.name | Self.objType)
            #expect(["a", "d"].contains(r.name(refAt: 24)))
            #expect(r.u32(32) == (r.name(refAt: 24) == "d" ? 2 : 1))
        }
    }

    /// With FSOPT_PACK_INVAL_ATTRS the returned set is the requested set,
    /// ATTR_CMN_ERROR included, and a zero error word precedes the name.
    @Test func errorPackedWithPackInvalid() throws {
        let base = try make(["a"], dirs: ["d"])
        request(common: Self.returned | Self.error | Self.name | Self.objType)
        let records = try #require(bulk(open(base), size: 0x2000, options: Self.packInvalid))
        #expect(records.count == 2)
        for r in records {
            #expect(r.length % 8 == 0)
            #expect(r.set(0) == Self.returned | Self.error | Self.name | Self.objType)
            #expect(r.u32(24) == 0)
            #expect(["a", "d"].contains(r.name(refAt: 28)))
            #expect(r.u32(36) == (r.name(refAt: 28) == "d" ? 2 : 1))
        }
    }

    /// Not requested: no bit and no word, with or without the option.
    @Test func errorNotRequested() throws {
        let base = try make(["a"])
        request(common: Self.returned | Self.name | Self.objType)
        for options in [UInt64(0), Self.packInvalid] {
            let records = try #require(bulk(open(base), size: 0x2000, options: options))
            #expect(records.count == 1)
            #expect(records[0].set(0) == Self.returned | Self.name | Self.objType)
            #expect(records[0].name(refAt: 24) == "a" && records[0].u32(32) == 1)
        }
    }

    /// RealityEnvironment's whole request (common 0xf01f9e0d, dir 0x5,
    /// file 0x1, extended 0x240, FSOPT_ATTR_CMN_EXTENDED): returned common
    /// 0xd01f9e0d, the group of the object's kind, the name reference
    /// right after the set. With FSOPT_PACK_INVAL_ATTRS the error word
    /// shifts everything by 4.
    @Test func mixedRequest() throws {
        let base = try make(["Info.plist"], dirs: ["AssetData"])
        request(common: Self.deepCommon, dir: 0x5, file: 0x1, fork: 0x240)
        let records = try #require(bulk(open(base), size: 18_600, options: Self.cmnExtended))
        #expect(records.count == 2)
        for r in records {
            let isDir = r.name(refAt: 24) == "AssetData"
            #expect(r.length % 8 == 0)
            #expect(r.set(0) == 0xD01F_9E0D)
            #expect(r.set(1) == 0)
            #expect(r.set(2) == (isDir ? 0x5 : 0))
            #expect(r.set(3) == (isDir ? 0 : 0x1))
            #expect(r.set(4) == 0x240)
            #expect(r.u32(40) == (isDir ? 2 : 1))                 // OBJTYPE after NAME and FSID
            if isDir {
                #expect(r.u32(152) == 1 && r.u32(156) == 0)       // LINKCOUNT, MOUNTSTATUS
            } else {
                #expect(r.u32(152) == 1)                          // file LINKCOUNT
            }
        }
        let packed = try #require(bulk(open(base), size: 18_600, options: Self.cmnExtended | Self.packInvalid))
        #expect(packed.count == 2)
        for r in packed {
            #expect(r.length % 8 == 0)
            #expect(r.set(0) == Self.deepCommon)
            #expect(r.u32(24) == 0)
            let isDir = r.name(refAt: 28) == "AssetData"
            #expect(["AssetData", "Info.plist"].contains(r.name(refAt: 28)))
            #expect(r.u32(44) == (isDir ? 2 : 1))
        }
    }

    /// The depth-first listing of §10.15.2 step 4: each directory record is
    /// followed, before the next record, by opening that directory by full
    /// path and listing it to the end, so up to four listings are open at
    /// once. With a one-record buffer the parent's listing resumes after
    /// each child.
    @Test(arguments: [18_600, 200])
    func depthFirstListing(size: Int) throws {
        let rooms = ["LivingRoomDay", "Office"]
        var files: [String] = []
        for room in rooms {
            files += ["\(room)/Info.plist", "\(room)/AssetData/Config.plist", "\(room)/AssetData/scene.usdc",
                      "\(room)/AssetData/icon.png", "\(room)/AssetData/0/a.ktx", "\(room)/AssetData/0/b.ktx"]
        }
        let base = try make(files)
        request(common: Self.deepCommon, dir: 0x5, file: 0x1, fork: 0x240)
        var found: [String] = []
        var maxOpen = 0
        func walk(_ path: String, depth: Int) throws {
            maxOpen = max(maxOpen, depth)
            let fd = open(path)
            while true {
                let records = try #require(bulk(fd, size: size, options: Self.cmnExtended))
                if records.isEmpty { break }
                if size < 400 { #expect(records.count == 1) }
                for r in records {
                    let child = path + "/" + r.name(refAt: 24)
                    found.append(String(child.dropFirst(base.count + 1)))
                    if r.u32(40) == 2 {
                        #expect(r.set(2) == 0x5 && r.u32(156) == 0)
                        try walk(child, depth: depth + 1)
                    }
                }
            }
            #expect(env.bsd(k, 6, [fd]) == 0)
        }
        try walk(base, depth: 1)
        var expected = Set(files)
        for f in files {
            var p = (f as NSString).deletingLastPathComponent
            while !p.isEmpty { expected.insert(p); p = (p as NSString).deletingLastPathComponent }
        }
        #expect(Set(found) == expected && found.count == expected.count)
        #expect(maxOpen == 4)
    }
}
