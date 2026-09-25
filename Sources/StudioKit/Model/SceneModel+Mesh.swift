import Foundation
import simd

// SceneModel — MeshParts: parts that show an imported 3D model.

extension SceneModel {
    /// The scene's 3D models, in the order they were imported.
    var meshAssets: [SceneAsset] { assets.filter { $0.kind == .mesh } }

    /// The size a new MeshPart of a model starts at: the model's own, in studs — or, if
    /// that is far too big or too small to work with (a file in millimetres, say), the
    /// same shape eight studs across.
    static func startingSize(for geometry: MeshGeometry) -> Vec3 {
        let size = geometry.nativeSize
        let largest = simd_reduce_max(size)
        guard largest > 400 || largest < 0.2 else { return size }
        return simd_max(size * (8 / largest), Vec3(repeating: 0.05))
    }

    /// A new, anchored MeshPart showing a model, standing on the ground at `position`,
    /// selected. With undo. Nil if the model can't be read.
    @discardableResult
    func insertMeshPart(_ assetID: UUID, at position: Vec3? = nil) -> UUID? {
        guard let asset = asset(id: assetID), asset.kind == .mesh,
              let geometry = MeshLibrary.shared.geometry(assetID) else {
            statusText = "That 3D model can't be read"
            return nil
        }
        var part = Part()
        part.name = uniqueName(base: asset.name)
        part.size = Self.startingSize(for: geometry)
        part.position = (position ?? Vec3(0, 0, 0)) + Vec3(0, part.size.y / 2, 0)
        part.color = Vec3(0.8, 0.8, 0.8)
        part.mesh = MeshSettings(meshId: asset.reference, asset: asset.id)
        commit("Inserted \(part.name)") {
            parts.append(part)
            selection = [part.id]
        }
        return part.id
    }

    /// Points MeshParts at another model (or none). With undo.
    func setMesh(_ reference: String, of ids: Set<UUID>) {
        let found = asset(named: reference).flatMap { $0.kind == .mesh ? $0 : nil }
        commit("Changed MeshId") {
            for index in parts.indices where ids.contains(parts[index].id) && parts[index].mesh != nil {
                parts[index].mesh?.meshId = found?.reference ?? reference
                parts[index].mesh?.asset = found?.id
            }
        }
    }

    func setMeshTexture(_ reference: String, of ids: Set<UUID>) {
        commit("Changed TextureID") {
            for index in parts.indices where ids.contains(parts[index].id) && parts[index].mesh != nil {
                parts[index].mesh?.textureId = reference
            }
        }
    }

    func setCollisionFidelity(_ fidelity: CollisionFidelity, of ids: Set<UUID>) {
        commit("Changed CollisionFidelity") {
            for index in parts.indices where ids.contains(parts[index].id) && parts[index].mesh != nil {
                parts[index].mesh?.collisionFidelity = fidelity
            }
        }
    }

    /// Back to the size its model was made at.
    func resetMeshSize(of ids: Set<UUID>) {
        commit("Reset size") {
            for index in parts.indices where ids.contains(parts[index].id) {
                guard let geometry = MeshLibrary.shared.geometry(for: parts[index]) else { continue }
                parts[index].size = Self.startingSize(for: geometry)
            }
        }
    }
}
