import Foundation
import simd

extension SceneModel {
    var canUnionSelection: Bool { selectedParts.count > 1 && selectedParts.contains { !$0.negative } && !solidBusy }
    var canSeparateSelection: Bool { selectedParts.contains { $0.solid != nil } && !solidBusy }

    private func solidOperands(_ ids: [UUID], subtract: Set<UUID>?) throws -> (positive: [Part], negative: [Part]) {
        let operands = ids.compactMap(part(id:))
        guard operands.count == ids.count, Set(ids).count == ids.count, operands.count >= 2,
              operands.allSatisfy({ !$0.locked }) else {
            throw SolidError.invalid("Select at least two unlocked parts to combine.")
        }
        let isNegative: (Part) -> Bool = { subtract?.contains($0.id) ?? $0.negative }
        return (operands.filter { !isNegative($0) }, operands.filter(isNegative))
    }

    @discardableResult
    func makeUnion(_ ids: [UUID], subtract: Set<UUID>? = nil, undoable: Bool = true, consume: Bool = true) throws -> UUID {
        let operands = try solidOperands(ids, subtract: subtract)
        let mesh = try SolidGeometry.combine(positive: operands.positive, negative: operands.negative)
        return commitSolid(mesh, ids: ids, negative: Set(operands.negative.map(\.id)), undoable: undoable, consume: consume)
    }

    /// Geometry work is isolated from the render loop. Even changes made directly by
    /// script/undo invalidate the source snapshot before the main-thread commit.
    func unionSelected() {
        guard !solidBusy else { return }
        let ids = selectedParts.map(\.id), snapshot = state, selected = selection
        do {
            let operands = try solidOperands(ids, subtract: nil)
            let positive = try operands.positive.map(SolidGeometry.input)
            let negative = try operands.negative.map(SolidGeometry.input)
            let cutters = Set(operands.negative.map(\.id))
            solidBusy = true; statusText = "Computing union…"
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try SolidGeometry.combine(positive: positive, negative: negative) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.solidBusy = false
                    guard self.state == snapshot, self.selection == selected else {
                        self.statusText = "Union canceled because its source scene changed."; return
                    }
                    switch result {
                    case .success(let mesh): _ = self.commitSolid(mesh, ids: ids, negative: cutters, undoable: true)
                    case .failure(let error): self.statusText = error.localizedDescription
                    }
                }
            }
        } catch { statusText = error.localizedDescription }
    }

    private func commitSolid(_ raw: SolidMesh, ids: [UUID], negative: Set<UUID>, undoable: Bool, consume: Bool = true) -> UUID {
        let roots = ids.filter { id in !ids.contains { $0 != id && isDescendant(id, of: $0) } }
        var held = Set(roots)
        for id in roots { held.formUnion(descendants(of: id).map(\.id)) }
        var saved = SceneState()
        saved.parts = parts.filter { held.contains($0.id) }
        for i in saved.parts.indices where ids.contains(saved.parts[i].id) { saved.parts[i].negative = negative.contains(saved.parts[i].id) }
        saved.groups = groups.filter { held.contains($0.id) }
        let guiIDs = Set(starterGui.filter { $0.worldParent.map(held.contains) ?? false }.flatMap { guiSubtree($0.id) })
        saved.starterGui = starterGui.filter { guiIDs.contains($0.id) }
        saved.scripts = scripts.filter { $0.parentID.map { held.contains($0) || guiIDs.contains($0) } ?? false }
        saved.sounds = sounds.filter { $0.parentID.map(held.contains) ?? false }
        saved.attachments = attachments.filter { held.contains($0.parentID) }
        let attachmentIDs = Set(saved.attachments.map(\.id))
        // Keep affected external joints too: separation restores their original ends.
        saved.constraints = constraints.filter {
            $0.parentID.map(held.contains) == true || [$0.part0, $0.part1].contains { $0.map(held.contains) == true }
                || [$0.attachment0, $0.attachment1].contains { $0.map(attachmentIDs.contains) == true }
        }
        var dataIDs = held
        var changed = true
        while changed {
            changed = false
            for object in dataObjects {
                if case .node(let parent) = object.parent, dataIDs.contains(parent), dataIDs.insert(object.id).inserted { changed = true }
            }
        }
        saved.dataObjects = dataObjects.filter { dataIDs.contains($0.id) }
        let usedMeshes = Set(saved.parts.compactMap { $0.mesh?.asset })
        let references = saved.sounds.map(\.soundId) + saved.parts.compactMap { $0.mesh?.textureId }
            + saved.starterGui.flatMap { $0.properties.values.compactMap(\.asString) }
        saved.assets = assets.filter { asset in
            usedMeshes.contains(asset.id) || references.contains(asset.reference)
                || saved.scripts.contains { $0.source.contains(asset.reference) }
        }
        let usedShaders = Set(saved.parts.compactMap(\.shaderID))
        saved.shaders = shaders.filter { usedShaders.contains($0.id) }
        let bounds = raw.bounds, center = (bounds.lower + bounds.upper) / 2, size = bounds.upper - bounds.lower
        var mesh = raw; mesh.positions = raw.positions.map { ($0 - center) / size }
        var result = parts.first { ids.contains($0.id) && !negative.contains($0.id) }!
        result.id = UUID(); result.name = uniqueName(base: "Union")
        result.position = center; result.size = size; result.orientation = simd_quatf(angle: 0, axis: Vec3(0, 1, 0))
        result.solidDeformation = nil
        result.solid = SolidOperation(mesh: mesh, sources: saved, roots: roots, center: center, size: size)
        if !consume { result.solid = result.solid?.reidentified() }
        result.mesh = MeshSettings(meshId: "solid://\(mesh.id)", asset: mesh.id, collisionFidelity: .precise)
        result.negative = false; result.usePartColor = false
        result.lights = []; result.emitters = []; result.clickDetector = nil; result.seat = nil
        if result.parentID.map(held.contains) == true { result.parentID = nil }
        let action = {
            if consume { self.removeSubtrees(roots) }
            self.parts.append(result)
            if consume { self.selection = [result.id] }
        }
        if undoable { commit("Union", action) } else { action() }
        return result.id
    }

    func negateSelected() {
        guard !solidBusy else { return }
        let ids = effectiveSelection
        commit("Negate") {
            for index in parts.indices where ids.contains(parts[index].id) && !parts[index].locked { parts[index].negative.toggle() }
        }
    }

    func separateSelected() {
        do { try separateSolids(selectedParts.map(\.id)) } catch { statusText = error.localizedDescription }
    }

    func separateSolids(_ ids: [UUID]) throws {
        let operands = ids.compactMap(part(id:)).filter { $0.solid != nil }
        guard !operands.isEmpty else { throw SolidError.invalid("Select a UnionOperation to separate.") }
        guard operands.allSatisfy({ !$0.locked }) else { throw SolidError.invalid("Unlock the union before separating it.") }
        commit("Separate") {
            var restored: Set<UUID> = []
            for part in operands {
                var operation = part.solid!
                if operation.sources.parts.contains(where: { self.part(id: $0.id) != nil })
                    || operation.sources.groups.contains(where: { self.group(id: $0.id) != nil }) {
                    operation = operation.reidentified()
                }
                var source = operation.sources
                MeshLibrary.shared.register(source.assets)
                let transform = part.modelMatrix * operation.sourceMatrix
                for i in source.parts.indices {
                    source.parts[i] = source.parts[i].transformedSolidSource(by: transform, orientation: part.orientation * source.parts[i].orientation)
                    if operation.roots.contains(source.parts[i].id) { source.parts[i].parentID = part.parentID }
                }
                mergeSolidAssets(&source)
                removeSubtrees([part.id])
                parts += source.parts; groups += source.groups; scripts += source.scripts
                sounds += source.sounds; attachments += source.attachments; constraints += source.constraints
                dataObjects += source.dataObjects; starterGui += source.starterGui
                restored.formUnion(operation.roots)
            }
            selection = restored
        }
    }

    private func mergeSolidAssets(_ source: inout SceneState) {
        var names: [String: String] = [:], assetIDs: [UUID: UUID] = [:]
        for original in source.assets {
            if let same = assets.first(where: { $0.kind == original.kind && $0.data == original.data }) {
                assetIDs[original.id] = same.id; names[original.reference] = same.reference
            } else {
                var asset = original
                if assets.contains(where: { $0.id == asset.id }) { asset.id = UUID() }
                asset.name = Self.unique(asset.name, among: assets.map(\.name))
                assets.append(asset); assetIDs[original.id] = asset.id; names[original.reference] = asset.reference
            }
        }
        for i in source.parts.indices {
            if let id = source.parts[i].mesh?.asset, let mapped = assetIDs[id] { source.parts[i].mesh?.asset = mapped }
            if let name = source.parts[i].mesh?.meshId, let mapped = names[name] { source.parts[i].mesh?.meshId = mapped }
            if let name = source.parts[i].mesh?.textureId, let mapped = names[name] { source.parts[i].mesh?.textureId = mapped }
        }
        for i in source.starterGui.indices {
            for (key, value) in source.starterGui[i].properties {
                if let name = value.asString, let mapped = names[name] { source.starterGui[i].properties[key] = .string(mapped) }
            }
        }
        for i in source.sounds.indices { source.sounds[i].soundId = names[source.sounds[i].soundId] ?? source.sounds[i].soundId }
        for i in source.scripts.indices {
            for (old, new) in names where old != new {
                for quote in ["\"", "'"] { source.scripts[i].source = source.scripts[i].source.replacingOccurrences(of: quote + old + quote, with: quote + new + quote) }
            }
        }
        var shaderIDs: [UUID: UUID] = [:]
        for original in source.shaders {
            if let same = shaders.first(where: { $0 == original }) { shaderIDs[original.id] = same.id; continue }
            var shader = original
            if shaders.contains(where: { $0.id == shader.id }) { shader.id = UUID() }
            shaderIDs[original.id] = shader.id; shaders.append(shader)
        }
        for i in source.parts.indices {
            if let shader = source.parts[i].shaderID, let mapped = shaderIDs[shader] { source.parts[i].shaderID = mapped }
        }
    }
}
