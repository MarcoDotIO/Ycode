// Pure builders for the process image the VMM writes before boot
// (`specs/simulator/stage3-contract.md` §2, §5, §6). Each returns bytes plus
// the guest addresses the caller needs; none of them touches guest memory.

// MARK: - Fixed addresses

/// The stage-3a guest virtual address map (`stage3-contract.md` §2).
public enum Stage3Layout {
    public static let pageSize: UInt64 = 0x4000
    /// The main stack: 8 MiB ending at `userStack`.
    public static let userStack: UInt64 = 0x1_6FE0_0000
    public static let stackSize: UInt64 = 8 << 20
    public static let stackBase: UInt64 = userStack - stackSize
    /// The shared-region reservation (nothing else may be mapped here).
    public static let sharedRegionStart: UInt64 = 0x1_8000_0000
    public static let sharedRegionEnd: UInt64 = 0x3_0000_0000
    /// Where `dyld_sim` is mapped.
    public static let dyldSimBase: UInt64 = 0x3_0000_0000
    /// First address for "anywhere" allocations.
    public static let anonymousBase: UInt64 = 0x3_2000_0000
    public static let commpageRO: UInt64 = 0xF_FFFF_4000
    public static let commpageRW: UInt64 = 0xF_FFFF_C000
    /// Guest RAM size reported in the commpage.
    public static let memorySize: UInt64 = 1 << 30
}

/// Offsets of the Ycode host page (`stage3-contract.md` §5).
public enum HostPageLayout {
    public static let base: UInt64 = 0x3_1000_0000
    public static let size: UInt64 = 0x1_0000
    /// `_ycode_launch`, the EL0 entry.
    public static let launchEntry: UInt64 = base
    public static let code: UInt64 = base
    public static let codeSize: UInt64 = 0x4000
    public static let helpersTable: UInt64 = base + 0x4000
    public static let helpersTableSize: UInt64 = 544
    public static let helpersVersion: UInt64 = 18
    public static let rwData: UInt64 = base + 0x8000
    public static let rwDataSize: UInt64 = 0x8000
    public static let errnoCell: UInt64 = base + 0x8000
    public static let startGlueCell: UInt64 = base + 0x8008
    public static let launchBlock: UInt64 = base + 0x8040
    public static let allImageInfos: UInt64 = base + 0x8100
    /// `infoArray`, `uuidArray`, and path strings (2 KiB).
    public static let imageInfoStorage: UInt64 = base + 0x8300
    public static let imageInfoStorageSize: UInt64 = 0x800
    /// `sysctlbyname` and scratch space (4 KiB).
    public static let scratch: UInt64 = base + 0x9000
}

/// The well-known Mach port names (`stage3-contract.md` §8).
public enum WellKnownPort {
    public static let task: UInt32 = 0x103
    public static let thread: UInt32 = 0x203
    public static let host: UInt32 = 0x303
    public static let firstDynamic: UInt32 = 0x1003
    public static let dynamicStep: UInt32 = 0x100
}

// MARK: - Kernel argument block

/// The block the kernel builds at the top of the main stack
/// (`darwin-process-start.md` §1.3). From the lowest address up: the
/// mach_header slot, `argc`, `argv[]` + NULL, `envp[]` + NULL, `apple[]` +
/// NULL, then the string area, which ends exactly at `userStack`.
public struct KernelArgumentBlock: Equatable, Sendable {
    /// The bytes from `stackPointer` up to (not including) `userStack`.
    public var bytes: [UInt8]
    /// The block's lowest address: the mach_header slot. This is the SP the
    /// kernel would hand over, and the launch block's `stackTop`. Not
    /// rounded to 16 bytes.
    public var stackPointer: UInt64
    public var argcAddress: UInt64 { stackPointer + 8 }
    public var argvAddress: UInt64
    public var envpAddress: UInt64
    public var appleAddress: UInt64
    /// Start of the string area (`userStack − stringAreaSize`).
    public var stringAreaAddress: UInt64
    public var argc: Int
    /// Guest address of every string, in order.
    public var argvStringAddresses: [UInt64]
    public var envpStringAddresses: [UInt64]
    public var appleStringAddresses: [UInt64]

    /// Builds the block.
    /// - Parameters:
    ///   - userStack: the stack top (16 KiB aligned); the last string padding byte is at `userStack − 1`.
    ///   - argv, envp: the strings, without terminating NULs.
    ///   - apple: the full `apple[]` list. `apple[0]` is the `executable_path=…` string,
    ///     which the kernel stores first in the string area; the rest go after envp.
    ///   - machHeader: the main executable's (slid) `mach_header_64` address.
    public init(userStack: UInt64, argv: [String], envp: [String], apple: [String], machHeader: UInt64) {
        precondition(!apple.isEmpty, "apple[0] (executable_path=) is required")
        // String area, low to high.
        var strings: [UInt8] = []
        var appleOffsets: [Int] = [0]
        strings += cString(apple[0])
        strings.padTo(8)
        var argvOffsets: [Int] = []
        for s in argv { argvOffsets.append(strings.count); strings += cString(s) }
        var envpOffsets: [Int] = []
        for s in envp { envpOffsets.append(strings.count); strings += cString(s) }
        strings.padTo(8)
        for s in apple.dropFirst() { appleOffsets.append(strings.count); strings += cString(s) }
        strings.padTo(8)

        let stringBase = userStack - UInt64(strings.count)
        let pointerWords = (argv.count + 1) + (envp.count + 1) + (apple.count + 1)
        let sp = stringBase - UInt64(8 * pointerWords) - 16

        argvStringAddresses = argvOffsets.map { stringBase + UInt64($0) }
        envpStringAddresses = envpOffsets.map { stringBase + UInt64($0) }
        appleStringAddresses = appleOffsets.map { stringBase + UInt64($0) }

        var b: [UInt8] = []
        b.reserveCapacity(Int(userStack - sp))
        b.appendLE(machHeader)
        b.appendLE(UInt64(argv.count))
        for a in argvStringAddresses { b.appendLE(a) }
        b.appendLE(UInt64(0))
        for a in envpStringAddresses { b.appendLE(a) }
        b.appendLE(UInt64(0))
        for a in appleStringAddresses { b.appendLE(a) }
        b.appendLE(UInt64(0))
        b += strings

        bytes = b
        stackPointer = sp
        argc = argv.count
        argvAddress = sp + 16
        envpAddress = argvAddress + UInt64(8 * (argv.count + 1))
        appleAddress = envpAddress + UInt64(8 * (envp.count + 1))
        stringAreaAddress = stringBase
    }
}

// MARK: - apple[] strings

/// The `apple[]` strings Ycode provides, in the kernel's order
/// (`stage3-contract.md` §6, formats from `darwin-process-start.md` §1.4).
public struct AppleStrings: Equatable, Sendable {
    public var stackGuard: UInt64
    public var mallocEntropy: (UInt64, UInt64)
    public var ptrMunge: UInt64
    /// The full list; element 0 is `executable_path=…`.
    public var strings: [String]

    public static func == (a: AppleStrings, b: AppleStrings) -> Bool {
        a.strings == b.strings && a.stackGuard == b.stackGuard && a.ptrMunge == b.ptrMunge
            && a.mallocEntropy.0 == b.mallocEntropy.0 && a.mallocEntropy.1 == b.mallocEntropy.1
    }

    /// - Parameters:
    ///   - executablePath: the guest path of the executable.
    ///   - mainStack: `main_stack=` values: top, usable size, allocation base,
    ///     allocation size (the kernel's order; the default is the §2 stack
    ///     with no separate guard).
    ///   - threadPort: the main thread's port name (`th_port=`).
    ///   - rng: the source of the three random keys.
    public init<R: RandomNumberGenerator>(
        executablePath: String,
        mainStack: (top: UInt64, size: UInt64, allocBase: UInt64, allocSize: UInt64) =
            (Stage3Layout.userStack, Stage3Layout.stackSize, Stage3Layout.stackBase, Stage3Layout.stackSize),
        threadPort: UInt32 = WellKnownPort.thread,
        using rng: inout R
    ) {
        // Bits 8–15 cleared so the guard contains a NUL byte.
        stackGuard = rng.next() & ~UInt64(0xFF00)
        mallocEntropy = (rng.next(), rng.next())
        ptrMunge = rng.next()
        strings = [
            "executable_path=" + executablePath,
            "stack_guard=" + hxPadded(stackGuard, digits: 16),
            "malloc_entropy=" + hx(mallocEntropy.0) + "," + hx(mallocEntropy.1),
            "ptr_munge=" + hx(ptrMunge),
            "main_stack=" + [mainStack.top, mainStack.size, mainStack.allocBase, mainStack.allocSize].map { hx($0) }
                .joined(separator: ","),
            "th_port=" + hx(threadPort),
        ]
    }

    /// The same, using the system random number generator.
    public init(executablePath: String) {
        var rng = SystemRandomNumberGenerator()
        self.init(executablePath: executablePath, using: &rng)
    }
}

/// The `envp` of the simulated process (`stage3-contract.md` §6).
public enum SimulatorEnvironment {
    public static func make(runtimeRoot: String) -> [String] {
        [
            "DYLD_ROOT_PATH=\(runtimeRoot)",
            "SIMULATOR_ROOT=\(runtimeRoot)",
            "IPHONE_SIMULATOR_ROOT=\(runtimeRoot)",
            "DYLD_SHARED_CACHE_DIR=\(runtimeRoot)/System/Library/Caches/com.apple.dyld",
            "HOME=/tmp",
            "TMPDIR=/tmp/",
            "PATH=\(runtimeRoot)/usr/bin:\(runtimeRoot)/bin",
            "XPC_SIMULATOR_LAUNCHD_NAME=dev.ycode.sim",
        ]
    }
}

// MARK: - Commpage

/// The two commpage data pages (`darwin-process-start.md` §3, values from
/// `stage3-contract.md` §6). Simulator code reads the legacy RW offsets, so
/// both copies of the duplicated fields are filled.
public struct CommpageBuilder: Equatable, Sendable {
    /// RW-data page offsets (`_COMM_PAGE_…`).
    public enum Offset {
        public static let signature = 0x000
        public static let cpuCapabilities64 = 0x010
        public static let version = 0x01E
        public static let cpuCapabilities = 0x020
        public static let ncpus = 0x022
        public static let userPageShift32 = 0x024
        public static let userPageShift64 = 0x025
        public static let cacheLineSize = 0x026
        public static let cpuClusters = 0x02F
        public static let memoryPressure = 0x030
        public static let activeCPUs = 0x034
        public static let physicalCPUs = 0x035
        public static let logicalCPUs = 0x036
        public static let kernelPageShift = 0x037
        public static let memorySize = 0x038
        public static let cpuFamily = 0x080
        public static let devFirm = 0x084
        public static let timebaseOffset = 0x088
        public static let userTimebase = 0x090
        public static let contHWClock = 0x091
        public static let contTimebase = 0x098
        public static let boottimeUsec = 0x0A0
        public static let contHWTimebase = 0x0A8
        public static let approxTime = 0x0C0
        public static let approxTimeSupported = 0x0C8
        public static let newTimeOfDay = 0x120
        public static let remoteTimeParams = 0x148
        public static let dyldFlags = 0x160
        public static let cpuToCluster = 0x200
    }

    /// Capability bits (`darwin-process-start.md` §3.5).
    public enum Capability {
        public static let cache32: UInt64 = 0x10
        public static let cache64: UInt64 = 0x20
        public static let cache128: UInt64 = 0x40
        public static let fastThreadLocalStorage: UInt64 = 0x80
        public static let hasAdvSIMD: UInt64 = 0x100
        public static let hasVfp: UInt64 = 0x400
        public static let hasEvent: UInt64 = 0x1000
        public static let hasFMA: UInt64 = 0x2000
        public static let up: UInt64 = 0x8000
        public static let numCPUsShift: UInt64 = 16
    }

    public static let signatureText = "commpage 64-bit"
    public static let layoutVersion: UInt16 = 3
    /// `USER_TIMEBASE` = 1: `CNTVCT_EL0` after `isb`.
    public static let userTimebaseSpec: UInt8 = 1
    public static let remoteTimeSentinel: UInt64 = 0xFFFF_FFFF_FFFF_FFFC

    public var cpuCount: UInt8 = 1
    public var cacheLineSize: UInt16 = 64
    public var memorySize: UInt64 = Stage3Layout.memorySize
    public var pageShift: UInt8 = 14
    /// Optional capability bits the guest vCPU really has (0 by default).
    public var optionalCapabilities: UInt64 = 0
    public var bootTimeMicroseconds: UInt64 = 0
    public var timebaseOffset: UInt64 = 0

    public init() {}

    public var capabilities: UInt64 {
        var caps = Capability.fastThreadLocalStorage | Capability.hasVfp | Capability.hasEvent | Capability.hasFMA
        caps |= UInt64(cpuCount) << Capability.numCPUsShift
        if cpuCount == 1 { caps |= Capability.up }
        switch cacheLineSize {
        case 32: caps |= Capability.cache32
        case 64: caps |= Capability.cache64
        case 128: caps |= Capability.cache128
        default: break
        }
        return caps | optionalCapabilities
    }

    /// The RW-data page (16 KiB), mapped EL0 read-only at `0xF_FFFF_C000`.
    public func rwPage() -> [UInt8] {
        var p = [UInt8](repeating: 0, count: Int(Stage3Layout.pageSize))
        p.put(Array(Self.signatureText.utf8), at: Offset.signature)
        p.putLE(capabilities, at: Offset.cpuCapabilities64)
        p.putLE(Self.layoutVersion, at: Offset.version)
        p.putLE(UInt32(truncatingIfNeeded: capabilities), at: Offset.cpuCapabilities)
        p[Offset.userPageShift32] = pageShift
        p[Offset.userPageShift64] = pageShift
        p.putLE(cacheLineSize, at: Offset.cacheLineSize)
        p[Offset.cpuClusters] = 1
        p[Offset.activeCPUs] = cpuCount
        p[Offset.physicalCPUs] = cpuCount
        p[Offset.logicalCPUs] = cpuCount
        p[Offset.kernelPageShift] = pageShift
        p.putLE(memorySize, at: Offset.memorySize)
        p.putLE(timebaseOffset, at: Offset.timebaseOffset)
        p[Offset.userTimebase] = Self.userTimebaseSpec
        p.putLE(bootTimeMicroseconds, at: Offset.boottimeUsec)
        p.putLE(Self.remoteTimeSentinel, at: Offset.remoteTimeParams)
        // cpu_to_cluster: one 0 byte per vCPU (already zero).
        return p
    }

    /// The RO-data page (16 KiB), mapped EL0 read-only at `0xF_FFFF_4000`.
    public func roPage() -> [UInt8] {
        var p = [UInt8](repeating: 0, count: Int(Stage3Layout.pageSize))
        p[Offset.userPageShift32] = pageShift
        p[Offset.userPageShift64] = pageShift
        p[Offset.kernelPageShift] = pageShift
        return p
    }
}

// MARK: - dyld_all_image_infos

/// The 368-byte LP64 `dyld_all_image_infos` (`dyld-sim-handoff.md` §4.5).
public struct DyldAllImageInfos: Equatable, Sendable {
    public static let byteCount = 368

    public enum Offset {
        public static let version = 0
        public static let infoArrayCount = 4
        public static let infoArray = 8
        public static let notification = 16
        public static let processDetachedFromSharedRegion = 24
        public static let libSystemInitialized = 25
        public static let dyldImageLoadAddress = 32
        public static let uuidArrayCount = 88
        public static let uuidArray = 96
        public static let dyldAllImageInfosAddress = 104
        public static let initialImageCount = 112
        public static let sharedCacheSlide = 152
        public static let sharedCacheUUID = 160
        public static let sharedCacheBaseAddress = 176
        public static let infoArrayChangeTimestamp = 184
        public static let dyldPath = 192
        public static let platform = 320
    }

    public var version: UInt32 = 17
    public var infoArrayCount: UInt32 = 0
    public var infoArray: UInt64 = 0
    public var notification: UInt64 = 0
    public var dyldImageLoadAddress: UInt64 = 0
    public var uuidArrayCount: UInt64 = 0
    public var uuidArray: UInt64 = 0
    public var dyldAllImageInfosAddress: UInt64 = 0
    public var initialImageCount: UInt64 = 0
    public var sharedCacheSlide: UInt64 = 0
    public var platform: UInt32 = 0

    public init() {}

    /// The contract's initial state (§6): version 17, one `infoArray` entry,
    /// `notification` = the host page's `ret` stub, `dyldImageLoadAddress` =
    /// `simMH`, `initialImageCount` = 1, `sharedCacheSlide` = 0. Every other
    /// field is 0.
    public static func initial(infoArray: UInt64, notification: UInt64, simMH: UInt64) -> DyldAllImageInfos {
        var i = DyldAllImageInfos()
        i.version = 17
        i.infoArrayCount = 1
        i.infoArray = infoArray
        i.notification = notification
        i.dyldImageLoadAddress = simMH
        i.initialImageCount = 1
        i.sharedCacheSlide = 0
        return i
    }

    public func encoded() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: Self.byteCount)
        b.putLE(version, at: Offset.version)
        b.putLE(infoArrayCount, at: Offset.infoArrayCount)
        b.putLE(infoArray, at: Offset.infoArray)
        b.putLE(notification, at: Offset.notification)
        b.putLE(dyldImageLoadAddress, at: Offset.dyldImageLoadAddress)
        b.putLE(uuidArrayCount, at: Offset.uuidArrayCount)
        b.putLE(uuidArray, at: Offset.uuidArray)
        b.putLE(dyldAllImageInfosAddress, at: Offset.dyldAllImageInfosAddress)
        b.putLE(initialImageCount, at: Offset.initialImageCount)
        b.putLE(sharedCacheSlide, at: Offset.sharedCacheSlide)
        b.putLE(platform, at: Offset.platform)
        return b
    }
}

/// The `infoArray` (and optional `uuidArray`) storage plus path strings,
/// laid out at `base` (normally `HostPageLayout.imageInfoStorage`).
/// `dyld_image_info` = {loadAddress, filePathPtr, modDate} (24 bytes);
/// `dyld_uuid_info` = {loadAddress, uuid[16]} (24 bytes).
public struct DyldImageInfoStorage: Equatable, Sendable {
    public struct Image: Equatable, Sendable {
        public var loadAddress: UInt64
        public var path: String
        public var modDate: UInt64
        public var uuid: [UInt8]?
        public init(loadAddress: UInt64, path: String, modDate: UInt64 = 0, uuid: [UInt8]? = nil) {
            self.loadAddress = loadAddress
            self.path = path
            self.modDate = modDate
            self.uuid = uuid
        }
    }

    public var bytes: [UInt8]
    public var infoArrayAddress: UInt64
    public var infoArrayCount: UInt32
    /// 0 when no image has a UUID.
    public var uuidArrayAddress: UInt64
    public var uuidArrayCount: UInt64

    public init(base: UInt64, images: [Image]) {
        let withUUID = images.filter { $0.uuid != nil }
        let infoSize = 24 * images.count
        let uuidSize = 24 * withUUID.count
        let stringsOffset = infoSize + uuidSize
        var b = [UInt8](repeating: 0, count: stringsOffset)
        var strings: [UInt8] = []
        for (i, image) in images.enumerated() {
            let pathAddress = base + UInt64(stringsOffset + strings.count)
            strings += cString(image.path)
            b.putLE(image.loadAddress, at: 24 * i)
            b.putLE(pathAddress, at: 24 * i + 8)
            b.putLE(image.modDate, at: 24 * i + 16)
        }
        for (i, image) in withUUID.enumerated() {
            let o = infoSize + 24 * i
            b.putLE(image.loadAddress, at: o)
            let uuid = Array((image.uuid ?? []).prefix(16))
            b.put(uuid + [UInt8](repeating: 0, count: 16 - uuid.count), at: o + 8)
        }
        b += strings
        b.padTo(8)
        bytes = b
        infoArrayAddress = base
        infoArrayCount = UInt32(images.count)
        uuidArrayAddress = withUUID.isEmpty ? 0 : base + UInt64(infoSize)
        uuidArrayCount = UInt64(withUUID.count)
    }
}

// MARK: - Launch block

/// The 96-byte launch block at host page +0x8040 (`stage3-contract.md` §5).
public struct LaunchBlock: Equatable, Sendable {
    public static let byteCount = 96

    public var prepareEntry: UInt64
    public var argc: UInt64
    public var argv: UInt64
    public var envp: UInt64
    public var apple: UInt64
    public var mainMH: UInt64
    public var simMH: UInt64
    public var simSlide: UInt64
    public var helpers: UInt64
    public var startGlueAddr: UInt64
    public var stackTop: UInt64
    public var reserved: UInt64

    public init(
        prepareEntry: UInt64, argc: UInt64, argv: UInt64, envp: UInt64, apple: UInt64,
        mainMH: UInt64, simMH: UInt64, simSlide: UInt64,
        helpers: UInt64 = HostPageLayout.helpersTable,
        startGlueAddr: UInt64 = HostPageLayout.startGlueCell,
        stackTop: UInt64, reserved: UInt64 = 0
    ) {
        self.prepareEntry = prepareEntry
        self.argc = argc
        self.argv = argv
        self.envp = envp
        self.apple = apple
        self.mainMH = mainMH
        self.simMH = simMH
        self.simSlide = simSlide
        self.helpers = helpers
        self.startGlueAddr = startGlueAddr
        self.stackTop = stackTop
        self.reserved = reserved
    }

    /// Fills `argc`/`argv`/`envp`/`apple`/`stackTop` from an argument block.
    public init(prepareEntry: UInt64, arguments: KernelArgumentBlock, mainMH: UInt64, simMH: UInt64, simSlide: UInt64) {
        self.init(prepareEntry: prepareEntry, argc: UInt64(arguments.argc), argv: arguments.argvAddress,
                  envp: arguments.envpAddress, apple: arguments.appleAddress, mainMH: mainMH, simMH: simMH,
                  simSlide: simSlide, stackTop: arguments.stackPointer)
    }

    public var words: [UInt64] {
        [prepareEntry, argc, argv, envp, apple, mainMH, simMH, simSlide, helpers, startGlueAddr, stackTop, reserved]
    }

    public func encoded() -> [UInt8] {
        var b: [UInt8] = []
        b.reserveCapacity(Self.byteCount)
        for w in words { b.appendLE(w) }
        return b
    }
}
