import Foundation

extension SceneModel {
    /// Inserts a saved creation (or a Toolbox model) with its pivot at `destination`,
    /// re-identified so it never clashes with what is already there. One undo step.
    @discardableResult
    func insert(_ file: ModelFile, at destination: Vec3) -> Int {
        // Every id is replaced as it goes in, but two sharing one would get the same new one.
        let incoming = file.state.repairingDuplicateIDs()
        let offset = destination - file.pivot

        var remapped: [UUID: UUID] = [:]
        var newParts: [Part] = []
        var newSelection: Set<UUID> = []
        for original in incoming.parts { remapped[original.id] = UUID() }
        for original in incoming.groups { remapped[original.id] = UUID() }
        for original in incoming.attachments { remapped[original.id] = UUID() }
        for original in incoming.starterGui { remapped[original.id] = UUID() }
        var left: [String] = []

        commit("Inserted \(file.name)") {
            // Its pictures and sounds: one already here with the same bytes is used as it
            // is; a different one under a name that's taken comes in renamed, and what
            // names it — its Sounds, its scripts — follows.
            var reference: [UUID: String] = [:]
            var assetID: [UUID: UUID] = [:]
            var renamed: [String: String] = [:]
            for original in incoming.assets {
                if let same = assets.first(where: { $0.data == original.data && $0.kind == original.kind }) {
                    reference[original.id] = same.reference
                    assetID[original.id] = same.id
                    if same.reference != original.reference { renamed[original.reference] = same.reference }
                    continue
                }
                guard assets.reduce(original.data.count, { $0 + $1.data.count }) <= SceneAsset.largestTotal else {
                    left.append(original.name)
                    continue
                }
                var asset = original
                if self.asset(id: asset.id) != nil { asset.id = UUID() }
                asset.name = SceneModel.unique(original.name, among: assets.map(\.name))
                assets.append(asset)
                reference[original.id] = asset.reference
                assetID[original.id] = asset.id
                if asset.name != original.name { renamed[original.reference] = asset.reference }
            }
            for original in incoming.sounds {
                guard let parent = original.parentID.flatMap({ remapped[$0] }) else { continue }
                var sound = original
                sound.id = UUID()
                sound.parentID = parent
                let key = original.soundId.hasPrefix("studio://") ? String(original.soundId.dropFirst(9)) : original.soundId
                if let asset = incoming.assets.first(where: { $0.name == key || $0.id.uuidString == key }),
                   let now = reference[asset.id] {
                    sound.soundId = now
                }
                sounds.append(sound)
            }

            for original in incoming.groups {
                var group = original
                group.id = remapped[original.id]!
                group.parentID = original.parentID.flatMap { remapped[$0] }
                group.primaryPartID = original.primaryPartID.flatMap { remapped[$0] }
                groups.append(group)
                if group.parentID == nil { newSelection.insert(group.id) }
            }
            for original in incoming.parts {
                var part = original
                part.id = remapped[original.id]!
                part.lights = part.lights.map { var light = $0; light.id = UUID(); return light }
                part.parentID = original.parentID.flatMap { remapped[$0] }
                // Loose parts get names of their own; inside a Model they keep theirs, as in
                // Roblox, so the Model's scripts still find them.
                if part.parentID == nil { part.name = uniqueName(base: original.name) }
                part.position += offset
                part.solid = part.solid?.reidentified()
                // A MeshPart shows the model and picture it brought, wherever they landed.
                if let mesh = original.mesh {
                    if let old = mesh.asset, let now = assetID[old] {
                        part.mesh?.asset = now
                        part.mesh?.meshId = reference[old] ?? mesh.meshId
                    }
                    if let now = renamed[mesh.textureId] { part.mesh?.textureId = now }
                }
                newParts.append(part)
                if part.parentID == nil { newSelection.insert(part.id) }
            }
            parts.append(contentsOf: newParts)

            for original in incoming.attachments {
                guard let parent = remapped[original.parentID] else { continue }
                var attachment = original
                attachment.id = remapped[original.id]!
                attachment.parentID = parent
                attachments.append(attachment)
            }
            for original in incoming.constraints {
                var constraint = original
                constraint.id = UUID()
                constraint.parentID = original.parentID.flatMap { remapped[$0] }
                constraint.part0 = original.part0.flatMap { remapped[$0] }
                constraint.part1 = original.part1.flatMap { remapped[$0] }
                constraint.attachment0 = original.attachment0.flatMap { remapped[$0] }
                constraint.attachment1 = original.attachment1.flatMap { remapped[$0] }
                constraints.append(constraint)
            }

            for original in incoming.scripts {
                var script = original
                script.id = UUID()
                script.name = uniqueScriptName(base: original.name)
                script.parentID = original.parentID.flatMap { remapped[$0] }
                for (old, new) in renamed {
                    for quote in ["\"", "'"] {
                        script.source = script.source.replacingOccurrences(of: quote + old + quote, with: quote + new + quote)
                    }
                }
                scripts.append(script)
            }

            for original in incoming.starterGui {
                var copy = original
                copy.id = remapped[original.id]!
                copy.parentID = original.parentID.flatMap { remapped[$0] }
                copy.worldParent = original.worldParent.flatMap { remapped[$0] }
                copy.viewportContent = copy.viewportContent?.reidentified()
                if let token = copy.properties["adornee"]?.asString, token.hasPrefix("p:"),
                   let old = UUID(uuidString: String(token.dropFirst(2))), let target = remapped[old] {
                    copy.properties["adornee"] = .string("p:\(target)")
                }
                if let image = copy.properties["image"]?.asString, let now = renamed[image] { copy.properties["image"] = .string(now) }
                starterGui.append(copy)
            }

            selection = newSelection
        }
        if !left.isEmpty {
            statusText = "Inserted \(file.name), but not \(left.joined(separator: ", ")): "
                + "the scene's pictures and sounds would be over \(SceneAsset.largestTotal >> 20) MB."
        }
        return newParts.count
    }
}
