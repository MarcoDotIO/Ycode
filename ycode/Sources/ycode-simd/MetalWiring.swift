// ycode-simd --device: the Metal host service's wiring (stage8-contract.md
// §5.2): the resolvers it needs from the VMM (guest-shared memory entries,
// IOSurface ports) and its start and registration.

import Foundation
import YcodeDarwinABI
import YcodeDarwinKernel
import YcodeHostServices
import YcodeMetalHost

/// Memory-entry rights of the host task → host memory (the kernel's
/// memory entries are SharedMemoryObjects, one host allocation each).
final class HostMemoryEntryResolver: MetalGuestMemoryResolver {
    let host: MachHostTask
    init(host: MachHostTask) { self.host = host }

    func region(forMemoryEntry name: UInt32) -> GuestSharedRegion? {
        guard let (object, offset, size) = host.memoryEntry(name), offset <= object.size else { return nil }
        let length = Int(min(size, object.size - offset))
        return GuestSharedRegion(pointer: object.host + Int(offset), length: length, objectID: object.serial, offset: Int(offset),
                                 objectPointer: object.host, objectLength: Int(object.size), owner: object)
    }
}

/// IOSurface ports (Method 14 rights the guest sends) → the surface's memory and layout.
final class IOSurfacePortResolver: IOSurfaceResolver {
    let service: IOSurfaceHostService
    init(service: IOSurfaceHostService) { self.service = service }

    func backing(forSurfacePort port: UInt32, plane: Int) -> IOSurfaceBacking? {
        guard let s = service.surface(forPort: port) else { return nil }
        let object = s.memory
        let region = GuestSharedRegion(pointer: object.host, length: Int(min(UInt64(s.allocationSize), object.size)),
                                       objectID: object.serial, owner: object)
        if plane > 0 || !s.planes.isEmpty {
            guard plane < s.planes.count else { return nil }
            let p = s.planes[plane]
            return IOSurfaceBacking(surfaceID: s.id, region: region, width: p.width, height: p.height, bytesPerRow: p.bytesPerRow,
                                    bytesPerElement: s.bytesPerElement, pixelFormat: s.pixelFormat, plane: plane,
                                    planeOffset: p.offset)
        }
        return IOSurfaceBacking(surfaceID: s.id, region: region, width: s.width, height: s.height, bytesPerRow: s.bytesPerRow,
                                bytesPerElement: s.bytesPerElement, pixelFormat: s.pixelFormat)
    }
}
