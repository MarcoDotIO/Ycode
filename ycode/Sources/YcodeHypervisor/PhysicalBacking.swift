// Guest-physical backing for the stage-3 address space, over KVM memslots.
// Contract: specs/simulator/stage3-contract.md §3 and §4.
//
// - Anonymous guest pages come from one large memslot (the anonymous pool),
//   backed by a host MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE mapping, so
//   host memory is committed only for pages the guest touches. Pages are
//   carved out at 16 KiB granularity with a first-fit free list.
// - Every guest file mapping gets its own memslot, backed by a host
//   MAP_PRIVATE mapping of the file: guest writes are copy-on-write and the
//   file is never modified. GPAs for these slots come from a bump allocator.
// - Memslots stay registered after the guest unmaps their pages.

#if os(Linux) && arch(arm64)
import CKVM
import Glibc
import YcodeDarwinABI

public final class KVMPhysicalBacking {
    public let vm: VirtualMachine
    /// The anonymous pool: [poolGPA, poolGPA + poolSize).
    public let poolGPA: UInt64
    public let poolSize: UInt64
    /// The first GPA handed out to file-backed memslots.
    public let fileWindowGPA: UInt64
    /// The end of the guest-physical address space (exclusive).
    public let physicalLimit: UInt64

    /// 16 KiB, the guest granule. Every GPA and size this type hands out is a multiple of it.
    public static let granule: UInt64 = 1 << 14
    /// Contract §3 defaults.
    public static let defaultPoolGPA: UInt64 = 0x10_0000_0000
    public static let defaultPoolSize: UInt64 = 16 << 30
    public static let defaultFileWindowGPA: UInt64 = 0x20_0000_0000

    /// Free ranges of the pool, sorted by start and coalesced.
    private var freeRanges: [(start: UInt64, size: UInt64)]
    private var nextFileGPA: UInt64
    private let poolHost: UnsafeMutableRawPointer
    /// Bytes of the pool currently allocated (for tracing).
    public private(set) var anonymousBytesInUse: UInt64 = 0
    /// Number of file mappings made (for tracing).
    public private(set) var fileMappingCount = 0
    /// Shared memory objects registered in this VM (kept alive while the
    /// VM may touch them; their slots are never unmapped by the VM).
    private var sharedSlots: [ObjectIdentifier: (object: SharedMemoryObject, gpa: UInt64)] = [:]

    public init(vm: VirtualMachine,
                poolGPA: UInt64 = KVMPhysicalBacking.defaultPoolGPA,
                poolSize: UInt64 = KVMPhysicalBacking.defaultPoolSize,
                fileWindowGPA: UInt64 = KVMPhysicalBacking.defaultFileWindowGPA,
                physicalAddressBits: UInt64 = 40) throws {
        precondition(poolGPA % Self.granule == 0 && poolSize % Self.granule == 0 && fileWindowGPA % Self.granule == 0)
        guard let host = ckvm_alloc_anonymous(Int(poolSize)) else {
            throw KVMError("mmap anonymous pool (\(poolSize >> 20) MiB, MAP_NORESERVE)", errno: Glibc.errno)
        }
        do {
            try vm.addMemorySlot(gpa: poolGPA, size: poolSize, host: host, kind: .anonymousPool, name: "anonymous pool")
        } catch {
            _ = ckvm_free_anonymous(host, Int(poolSize))
            throw error
        }
        self.vm = vm
        self.poolGPA = poolGPA
        self.poolSize = poolSize
        self.fileWindowGPA = fileWindowGPA
        self.physicalLimit = UInt64(1) << physicalAddressBits
        self.poolHost = host
        self.freeRanges = [(poolGPA, poolSize)]
        self.nextFileGPA = fileWindowGPA
    }

    static func roundUp(_ value: UInt64, _ alignment: UInt64) -> UInt64 { (value + alignment - 1) & ~(alignment - 1) }

    // MARK: Anonymous pages

    /// Allocates `size` bytes (rounded up to 16 KiB) of zeroed, physically
    /// contiguous guest memory from the pool. Returns its GPA.
    public func allocateAnonymous(size: UInt64) throws -> UInt64 {
        let size = Self.roundUp(max(size, 1), Self.granule)
        guard let index = freeRanges.firstIndex(where: { $0.size >= size }) else {
            throw KVMError("anonymous pool", errno: ENOMEM,
                           detail: "no free run of \(size) bytes (\(anonymousBytesInUse >> 20) MiB of \(poolSize >> 20) MiB in use)")
        }
        let start = freeRanges[index].start
        if freeRanges[index].size == size {
            freeRanges.remove(at: index)
        } else {
            freeRanges[index] = (start + size, freeRanges[index].size - size)
        }
        anonymousBytesInUse += size
        return start
    }

    /// Returns pool pages to the free list. Their host pages are dropped, so
    /// they read as zeros when reused. GPAs outside the pool (file slots) are
    /// ignored: those memslots stay registered.
    public func release(gpa: UInt64, size: UInt64) {
        let size = Self.roundUp(size, Self.granule)
        guard size > 0, gpa >= poolGPA, gpa + size <= poolGPA + poolSize, gpa % Self.granule == 0 else { return }
        // After the VM's teardown the pool's host memory is gone (and its
        // addresses may belong to another mapping): never touch it.
        guard !vm.isClosed else { return }
        // Ignore a range that overlaps free space (double free): keep the list consistent.
        if freeRanges.contains(where: { gpa < $0.start + $0.size && $0.start < gpa + size }) { return }
        _ = ckvm_discard_anonymous(poolHost + Int(gpa - poolGPA), Int(size))
        let index = freeRanges.firstIndex { $0.start > gpa } ?? freeRanges.count
        freeRanges.insert((gpa, size), at: index)
        // Coalesce with the neighbours.
        if index + 1 < freeRanges.count, freeRanges[index].start + freeRanges[index].size == freeRanges[index + 1].start {
            freeRanges[index].size += freeRanges[index + 1].size
            freeRanges.remove(at: index + 1)
        }
        if index > 0, freeRanges[index - 1].start + freeRanges[index - 1].size == freeRanges[index].start {
            freeRanges[index - 1].size += freeRanges[index].size
            freeRanges.remove(at: index)
        }
        anonymousBytesInUse -= min(anonymousBytesInUse, size)
    }

    // MARK: File mappings

    /// Maps `size` bytes (rounded up to 16 KiB) of the host file `hostFD`,
    /// starting at `offset`, into a new memslot. Bytes past the end of the
    /// file read as zeros. Returns the slot's GPA.
    public func mapFile(hostFD: Int32, fileSize: UInt64, offset: UInt64, size: UInt64, name: String) throws -> UInt64 {
        let hostPage = UInt64(ckvm_host_page_size())
        guard offset % hostPage == 0 else {
            throw KVMError("file memslot", errno: EINVAL, detail: "offset 0x\(String(offset, radix: 16)) of \(name) is not host-page aligned")
        }
        let total = Self.roundUp(max(size, 1), Self.granule)
        let gpa = Self.roundUp(nextFileGPA, Self.granule)
        guard gpa + total <= physicalLimit else {
            throw KVMError("file memslot", errno: ENOMEM, detail: "guest physical space exhausted mapping \(name)")
        }
        let available = offset < fileSize ? fileSize - offset : 0
        let fileBytes = Int(min(min(size, available), total))
        guard let host = ckvm_map_file_private(hostFD, offset, fileBytes, Int(total)) else {
            throw KVMError("mmap \(name) at offset 0x\(String(offset, radix: 16))", errno: Glibc.errno)
        }
        do {
            try vm.addMemorySlot(gpa: gpa, size: total, host: host, kind: .file,
                                 name: "\(name)@0x\(String(offset, radix: 16))")
        } catch {
            _ = ckvm_free_anonymous(host, Int(total))
            throw error
        }
        nextFileGPA = gpa + total
        fileMappingCount += 1
        return gpa
    }

    // MARK: Shared memory

    /// Registers `object` as a memslot (once per VM) in the file window and
    /// returns its GPA.
    public func mapShared(_ object: SharedMemoryObject) throws -> UInt64 {
        if let slot = sharedSlots[ObjectIdentifier(object)] { return slot.gpa }
        let gpa = Self.roundUp(nextFileGPA, Self.granule)
        guard gpa + object.size <= physicalLimit else {
            throw KVMError("shared memslot", errno: ENOMEM, detail: "guest physical space exhausted")
        }
        try vm.addMemorySlot(gpa: gpa, size: object.size, host: object.host, kind: .shared,
                             name: "shared object #\(object.serial)")
        nextFileGPA = gpa + object.size
        sharedSlots[ObjectIdentifier(object)] = (object, gpa)
        return gpa
    }

    // MARK: Physical access

    /// Reads `count` bytes at `gpa`. The range may span consecutive memslots.
    public func readPhysical(gpa: UInt64, count: Int) throws -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(count)
        var address = gpa, remaining = count
        while remaining > 0 {
            guard let slot = vm.memorySlot(containing: address) else {
                throw KVMError("guest physical read", errno: EFAULT, detail: "GPA 0x\(String(address, radix: 16)) is outside every memslot")
            }
            let chunk = Int(min(UInt64(remaining), slot.end - address))
            result.append(contentsOf: try vm.read(gpa: address, count: chunk))
            address += UInt64(chunk)
            remaining -= chunk
        }
        return result
    }

    /// Writes `bytes` at `gpa`. The range may span consecutive memslots.
    public func writePhysical(gpa: UInt64, bytes: [UInt8]) throws {
        var address = gpa, offset = 0
        while offset < bytes.count {
            guard let slot = vm.memorySlot(containing: address) else {
                throw KVMError("guest physical write", errno: EFAULT, detail: "GPA 0x\(String(address, radix: 16)) is outside every memslot")
            }
            let chunk = Int(min(UInt64(bytes.count - offset), slot.end - address))
            try vm.write(gpa: address, bytes: Array(bytes[offset..<offset + chunk]))
            address += UInt64(chunk)
            offset += chunk
        }
    }
}

/// The contract's `PhysicalBacking` (stage3-contract.md §4) over KVM memslots.
extension KVMPhysicalBacking: PhysicalBacking {
    public func mapFile(_ file: GuestFile, offset: UInt64, size: UInt64) throws -> UInt64 {
        try mapFile(hostFD: file.hostFD, fileSize: file.size, offset: offset, size: size, name: file.guestPath)
    }
}
#endif
