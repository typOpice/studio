import Metal
import simd

/// Acceleration structures for ray-traced lighting.
///
/// Every mesh (the four part shapes, the avatar's torso, limb and head) gets a
/// primitive acceleration structure once, at start-up. Each frame, the parts and
/// avatars become instances of those meshes in a fresh instance acceleration structure
/// — cheap to rebuild, so moving parts and a walking avatar need no special handling.
///
/// Alongside go two buffers the shaders read when a reflection ray hits something:
/// each triangle's normal (`faceNormals`, per mesh) and each instance's colour,
/// material and normal matrix (`InstanceInfo`).
final class RayTracingScene {

    struct Instance {
        var mesh: String
        var transform: float4x4
        var color: Vec3
        var shading: Vec4
        /// `studioMaskSolid`, or `studioMaskLightHousing` for a part holding a light.
        var mask: UInt32
    }

    struct Built {
        let accelerationStructure: MTLAccelerationStructure
        let instanceInfo: MTLBuffer
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private(set) var primitiveStructures: [MTLAccelerationStructure] = []
    private var meshIndex: [String: Int] = [:]
    private var faceOffsets: [UInt32] = []
    let faceNormals: MTLBuffer

    /// Three frames' worth of per-frame buffers, so the CPU never writes one the GPU
    /// is still reading.
    private struct Slot {
        var descriptors: MTLBuffer?
        var info: MTLBuffer?
        var structure: MTLAccelerationStructure?
        var scratch: MTLBuffer?
        var capacity = 0
    }
    private var slots = [Slot](repeating: Slot(), count: 3)
    private var slotIndex = 0
    private let inFlight = DispatchSemaphore(value: 3)

    static let maskSolid: UInt32 = 1
    static let maskLightHousing: UInt32 = 2

    /// `meshes`: a name, the GPU mesh, and the vertex and index data it was made from.
    init?(device: MTLDevice, meshes: [(name: String, mesh: Mesh, vertices: [Vertex], indices: [UInt16])]) {
        guard device.supportsRaytracing, let queue = device.makeCommandQueue(),
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeAccelerationStructureCommandEncoder() else { return nil }
        self.device = device
        self.queue = queue

        var normals: [Vec4] = []
        for (index, entry) in meshes.enumerated() {
            let geometry = MTLAccelerationStructureTriangleGeometryDescriptor()
            geometry.vertexBuffer = entry.mesh.vertexBuffer
            geometry.vertexStride = MemoryLayout<Vertex>.stride
            geometry.vertexFormat = .float3
            geometry.indexBuffer = entry.mesh.indexBuffer
            geometry.indexType = .uint16
            geometry.triangleCount = entry.indices.count / 3
            geometry.opaque = true
            let descriptor = MTLPrimitiveAccelerationStructureDescriptor()
            descriptor.geometryDescriptors = [geometry]

            let sizes = device.accelerationStructureSizes(descriptor: descriptor)
            guard let structure = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
                  let scratch = device.makeBuffer(length: max(sizes.buildScratchBufferSize, 16),
                                                  options: .storageModePrivate) else { return nil }
            encoder.build(accelerationStructure: structure, descriptor: descriptor,
                          scratchBuffer: scratch, scratchBufferOffset: 0)
            primitiveStructures.append(structure)
            meshIndex[entry.name] = index

            // One normal per triangle, the average of its corners: smooth enough for
            // reflections of rounded shapes.
            faceOffsets.append(UInt32(normals.count))
            for t in stride(from: 0, to: entry.indices.count, by: 3) {
                let a = entry.vertices[Int(entry.indices[t])].normal
                let b = entry.vertices[Int(entry.indices[t + 1])].normal
                let c = entry.vertices[Int(entry.indices[t + 2])].normal
                let sum = a + b + c
                normals.append(Vec4(length(sum) > 1e-6 ? normalize(sum) : Vec3(0, 1, 0), 0))
            }
        }
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        guard buffer.status == .completed,
              let faceBuffer = device.makeBuffer(bytes: normals, length: max(normals.count, 1) * MemoryLayout<Vec4>.stride,
                                                 options: .storageModeShared) else { return nil }
        faceNormals = faceBuffer
    }

    /// Encodes this frame's instance acceleration structure into `commandBuffer`.
    func build(_ instances: [Instance], into commandBuffer: MTLCommandBuffer) -> Built? {
        var instances = instances.filter { meshIndex[$0.mesh] != nil }
        // An empty scene still needs something to trace against; this one is never hit.
        if instances.isEmpty, let any = meshIndex.keys.first {
            instances = [Instance(mesh: any, transform: Mat.translation(Vec3(0, -1e5, 0)),
                                  color: .zero, shading: .zero, mask: 0)]
        }
        guard !instances.isEmpty else { return nil }

        inFlight.wait()
        commandBuffer.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        slotIndex = (slotIndex + 1) % slots.count
        var slot = slots[slotIndex]

        if slot.capacity < instances.count {
            let capacity = max(64, instances.count * 2)
            slot.descriptors = device.makeBuffer(
                length: capacity * MemoryLayout<MTLAccelerationStructureInstanceDescriptor>.stride,
                options: .storageModeShared)
            slot.info = device.makeBuffer(length: capacity * MemoryLayout<InstanceInfo>.stride,
                                          options: .storageModeShared)
            slot.capacity = capacity
            slot.structure = nil
            slot.scratch = nil
        }
        guard let descriptorBuffer = slot.descriptors, let infoBuffer = slot.info else { return nil }

        let descriptors = descriptorBuffer.contents()
            .bindMemory(to: MTLAccelerationStructureInstanceDescriptor.self, capacity: instances.count)
        let infos = infoBuffer.contents().bindMemory(to: InstanceInfo.self, capacity: instances.count)
        for (i, instance) in instances.enumerated() {
            let index = meshIndex[instance.mesh]!
            let m = instance.transform
            var descriptor = MTLAccelerationStructureInstanceDescriptor()
            descriptor.transformationMatrix = MTLPackedFloat4x3(columns: (
                MTLPackedFloat3Make(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                MTLPackedFloat3Make(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                MTLPackedFloat3Make(m.columns.2.x, m.columns.2.y, m.columns.2.z),
                MTLPackedFloat3Make(m.columns.3.x, m.columns.3.y, m.columns.3.z)))
            descriptor.options = .opaque
            descriptor.mask = instance.mask
            descriptor.intersectionFunctionTableOffset = 0
            descriptor.accelerationStructureIndex = UInt32(index)
            descriptors[i] = descriptor

            let normal = Mat.normalMatrix(m)
            infos[i] = InstanceInfo(normal0: Vec4(normal.columns.0, 0), normal1: Vec4(normal.columns.1, 0),
                                    normal2: Vec4(normal.columns.2, 0), color: Vec4(instance.color, 1),
                                    shading: instance.shading,
                                    extra: SIMD4<UInt32>(faceOffsets[index], 0, 0, 0))
        }

        let descriptor = MTLInstanceAccelerationStructureDescriptor()
        descriptor.instancedAccelerationStructures = primitiveStructures
        descriptor.instanceCount = instances.count
        descriptor.instanceDescriptorBuffer = descriptorBuffer
        let sizes = device.accelerationStructureSizes(descriptor: descriptor)
        if slot.structure == nil || slot.structure!.size < sizes.accelerationStructureSize {
            slot.structure = device.makeAccelerationStructure(size: sizes.accelerationStructureSize * 2)
        }
        if slot.scratch == nil || slot.scratch!.length < sizes.buildScratchBufferSize {
            slot.scratch = device.makeBuffer(length: max(sizes.buildScratchBufferSize * 2, 16),
                                             options: .storageModePrivate)
        }
        slots[slotIndex] = slot
        guard let structure = slot.structure, let scratch = slot.scratch,
              let encoder = commandBuffer.makeAccelerationStructureCommandEncoder() else { return nil }
        encoder.build(accelerationStructure: structure, descriptor: descriptor,
                      scratchBuffer: scratch, scratchBufferOffset: 0)
        encoder.endEncoding()
        return Built(accelerationStructure: structure, instanceInfo: infoBuffer)
    }
}
