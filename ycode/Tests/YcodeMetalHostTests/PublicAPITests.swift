import Foundation
import Testing
import YcodeMetalHost  // not @testable: everything here must be public API

/// A backend's tests build the command model by hand; this checks that
/// they can, with public initializers only.
@Suite struct PublicAPITests {
    @Test func commandModelBuildsWithPublicInitializers() {
        let target = MetalHandle(7)
        let color = MetalColorAttachment(index: 0, attachment: MetalRenderPassAttachment(texture: target, loadAction: MetalLoadAction.clear,
                                                                                         storeAction: MetalStoreAction.store),
                                         clearColor: [1, 0, 0, 1])
        let desc = MetalRenderPassDescriptor(colorAttachments: [color], renderTargetWidth: 64, renderTargetHeight: 64)
        let pass = MetalRenderPass(descriptor: desc, commands: [
            .setRenderPipelineState(MetalHandle(3)),
            .setViewport(MetalViewport(x: 0, y: 0, width: 64, height: 64, znear: 0, zfar: 1)),
            .draw(MetalDraw(primitiveType: MetalPrimitiveType.triangle, vertexStart: 0, vertexCount: 3)),
        ])
        let cb = MetalCommandBuffer(process: 1, queue: MetalHandle(2), commandBufferRef: 1, passes: [
            .render(pass),
            .compute([.dispatchThreadgroups(MetalSize3(1, 1, 1), threadsPerThreadgroup: MetalSize3(8, 8, 1))]),
            .blit([.generateMipmaps(target)]),
            .event([.signal(MetalHandle(9), value: 1)]),
        ])
        #expect(cb.renderTargets == [target] && desc.hasAttachments && color.texture == target)
        let header = MetalSegmentHeader(used: 8, kind: MetalEncoderKind.render)
        #expect(header.used == 8 && !header.continuesPrevious)
        #expect(MetalHostStatistics().submissions == 0)

        // NullBackend runs it and reports completion.
        let backend = NullBackend()
        let done = Box()
        backend.submit(cb, scheduled: {}, completed: { status in done.set(status) })
        #expect(done.value == MetalCommandBufferStatus.completed && backend.submitted.count == 1)
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var v = 0
        var value: Int { lock.withLock { v } }
        func set(_ x: Int) { lock.withLock { v = x } }
    }
}
