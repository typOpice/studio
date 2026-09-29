import Foundation
import simd

/// Source objects are retained here, outside the active scene tree. A union's affine
/// frame carries them when the result is moved, rotated or resized before Separate.
struct SolidOperation: Codable, Equatable {
    var mesh: SolidMesh
    var sources: SceneState
    var roots: [UUID]
    var center: Vec3
    var size: Vec3
    var sourceMapping: [Float]?

    var sourceMatrix: float4x4 {
        if let v = sourceMapping, v.count == 16 {
            return float4x4(Vec4(v[0], v[1], v[2], v[3]), Vec4(v[4], v[5], v[6], v[7]), Vec4(v[8], v[9], v[10], v[11]), Vec4(v[12], v[13], v[14], v[15]))
        }
        return Mat.scale(1 / size) * Mat.translation(-center)
    }
}

extension SolidOperation {
    /// Hidden operands have their own identity namespace too. Copying the result must
    /// not bring its old source IDs back when the copy is later separated.
    func reidentified() -> SolidOperation {
        var result = self, source = sources
        let all = source.parts.map(\.id) + source.groups.map(\.id) + source.scripts.map(\.id)
            + source.sounds.map(\.id) + source.attachments.map(\.id) + source.constraints.map(\.id) + source.dataObjects.map(\.id)
            + source.starterGui.map(\.id)
        let map = Dictionary(all.map { ($0, UUID()) }, uniquingKeysWith: { first, _ in first })
        func id(_ old: UUID?) -> UUID? { old.map { map[$0] ?? $0 } }
        for i in source.parts.indices {
            source.parts[i].id = id(source.parts[i].id)!
            source.parts[i].parentID = id(source.parts[i].parentID)
            source.parts[i].solid = source.parts[i].solid?.reidentified()
            for j in source.parts[i].lights.indices { source.parts[i].lights[j].id = UUID() }
            for j in source.parts[i].emitters.indices { source.parts[i].emitters[j].id = UUID() }
        }
        for i in source.groups.indices {
            source.groups[i].id = id(source.groups[i].id)!
            source.groups[i].parentID = id(source.groups[i].parentID)
            source.groups[i].primaryPartID = id(source.groups[i].primaryPartID)
        }
        for i in source.starterGui.indices {
            source.starterGui[i].id = id(source.starterGui[i].id)!
            source.starterGui[i].parentID = id(source.starterGui[i].parentID)
            source.starterGui[i].worldParent = id(source.starterGui[i].worldParent)
            source.starterGui[i].viewportContent = source.starterGui[i].viewportContent?.reidentified()
            if let token = source.starterGui[i].properties["adornee"]?.asString, token.hasPrefix("p:"),
               let old = UUID(uuidString: String(token.dropFirst(2))), let target = map[old] {
                source.starterGui[i].properties["adornee"] = .string("p:" + target.uuidString)
            }
        }
        for i in source.scripts.indices { source.scripts[i].id = id(source.scripts[i].id)!; source.scripts[i].parentID = id(source.scripts[i].parentID) }
        for i in source.sounds.indices { source.sounds[i].id = id(source.sounds[i].id)!; source.sounds[i].parentID = id(source.sounds[i].parentID) }
        for i in source.attachments.indices { source.attachments[i].id = id(source.attachments[i].id)!; source.attachments[i].parentID = id(source.attachments[i].parentID)! }
        for i in source.constraints.indices {
            source.constraints[i].id = id(source.constraints[i].id)!
            source.constraints[i].parentID = id(source.constraints[i].parentID)
            source.constraints[i].part0 = id(source.constraints[i].part0); source.constraints[i].part1 = id(source.constraints[i].part1)
            source.constraints[i].attachment0 = id(source.constraints[i].attachment0); source.constraints[i].attachment1 = id(source.constraints[i].attachment1)
        }
        for i in source.dataObjects.indices {
            source.dataObjects[i].id = id(source.dataObjects[i].id)!
            if case .node(let parent) = source.dataObjects[i].parent { source.dataObjects[i].parent = .node(id(parent)!) }
            if source.dataObjects[i].className == .objectValue {
                for (old, new) in map { source.dataObjects[i].text = source.dataObjects[i].text.replacingOccurrences(of: old.uuidString, with: new.uuidString) }
            }
        }
        result.sources = source; result.roots = roots.map { id($0)! }
        return result
    }
}

extension Part {
    /// Parts cannot store shear in a quaternion and Size. Bake that component into
    /// the boundary while retaining the source class and the nested separation map.
    func transformedSolidSource(by transform: float4x4, orientation rotation: simd_quatf) -> Part {
        var result = self
        let oldMatrix = modelMatrix, transformed = transform * oldMatrix
        let position = transform * Vec4(self.position, 1)
        result.position = Vec3(position.x, position.y, position.z)
        result.orientation = rotation
        let inverseRotation = Mat.rotation(rotation.inverse)
        let local = inverseRotation * transformed
        let axes = [Vec3(local[0].x, local[0].y, local[0].z), Vec3(local[1].x, local[1].y, local[1].z), Vec3(local[2].x, local[2].y, local[2].z)]
        let offAxis = abs(axes[0].y) + abs(axes[0].z) + abs(axes[1].x) + abs(axes[1].z) + abs(axes[2].x) + abs(axes[2].y)
        if offAxis < 1e-5 * max(length(axes[0]), max(length(axes[1]), length(axes[2]))) {
            result.size = Vec3(length(axes[0]), length(axes[1]), length(axes[2]))
            return result
        }
        guard var mesh = try? SolidGeometry.input(self) else { return result }
        mesh.id = UUID()
        mesh.positions = mesh.positions.map { point in
            let p = inverseRotation * transform * Vec4(point, 1)
            return Vec3(p.x, p.y, p.z)
        }
        let bounds = mesh.bounds, center = (bounds.lower + bounds.upper) / 2
        result.size = simd_max(bounds.upper - bounds.lower, Vec3(repeating: 1e-5))
        result.position = rotation.act(center)
        mesh.positions = mesh.positions.map { ($0 - center) / result.size }
        if var operation = solid {
            operation.mesh = mesh
            let mapping = result.modelMatrix.inverse * transform * oldMatrix * operation.sourceMatrix
            operation.sourceMapping = (0..<4).flatMap { column in (0..<4).map { mapping[column][$0] } }
            result.solid = operation
            result.mesh?.asset = mesh.id
            result.mesh?.meshId = "solid://\(mesh.id)"
        } else {
            result.solidDeformation = mesh
        }
        return result
    }
}
