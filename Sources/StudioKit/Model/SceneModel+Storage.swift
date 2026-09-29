import Foundation

/// Where things are kept out of the world until a script wants them: ReplicatedStorage,
/// which every machine sees, and ServerStorage, which only the host (the server) does —
/// joined players are never sent what's in it.
enum StoragePlace: String, Codable, CaseIterable, Identifiable {
    case replicatedStorage
    case serverStorage

    var id: String { rawValue }
    var displayName: String { self == .replicatedStorage ? "ReplicatedStorage" : "ServerStorage" }
    /// As Luau names the place: "rs" or "ss".
    var token: String { self == .replicatedStorage ? "rs" : "ss" }
    var dataParent: DataParent { self == .replicatedStorage ? .replicatedStorage : .serverStorage }
    var scriptHost: ScriptHost { self == .replicatedStorage ? .replicatedStorage : .serverStorage }

    init?(token: String) {
        switch token {
        case "rs": self = .replicatedStorage
        case "ss": self = .serverStorage
        default: return nil
        }
    }
}

// SceneModel — storage: parts and Models kept in ReplicatedStorage or ServerStorage, their
// parts parked (out of the world, as a Tool's are in a Backpack).

extension SceneModel {
    /// The parts and groups kept in a place, as tree nodes.
    func stored(in place: StoragePlace) -> [TreeNode] {
        groups.filter { $0.parentID == nil && $0.storage == place }.map { .group($0.id) }
            + parts.filter { $0.parentID == nil && $0.storage == place }.map { .part($0.id) }
    }

    /// Where a part or group at the top of the tree is kept, if not in the Workspace.
    func storage(of id: UUID) -> StoragePlace? {
        group(id: id)?.storage ?? part(id: id)?.storage
    }

    /// Keeps a part or group — and everything in it — in a storage place, or brings it
    /// back into the Workspace (nil). It goes to the top of the tree either way. Its
    /// parts are parked while stored. No undo; callers commit.
    func setStorage(_ id: UUID, _ place: StoragePlace?) {
        if let index = self.index.groupSlot(id, in: self) {
            groups[index].storage = place
            if place != nil { groups[index].parentID = nil }
        } else if let index = self.index.partSlot(id, in: self) {
            parts[index].storage = place
            if place != nil { parts[index].parentID = nil }
        } else {
            return
        }
        let inside = Set(partIDs(inSubtree: id) + [id])
        for i in parts.indices where inside.contains(parts[i].id) {
            // A Tool out of the world inside keeps its own parts parked.
            let parked = place != nil || isParked(parts[i].parentID)
            if parts[i].parked != parked { parts[i].parked = parked }
        }
        selection.subtract(inside)
    }

    /// Studio's Move to ReplicatedStorage / ServerStorage / Workspace, with undo.
    func moveToStorage(_ ids: [UUID], _ place: StoragePlace?) {
        commit(place.map { "Moved to \($0.displayName)" } ?? "Moved to Workspace") {
            for id in ids where group(id: id) != nil || part(id: id) != nil {
                if place == nil, parentID(of: id) != nil { continue }
                setStorage(id, place)
            }
        }
    }

    /// What joined players are sent: nothing kept in ServerStorage — its parts and
    /// groups, the scripts in them, its data objects and its ModuleScripts.
    func withoutServerStorage(_ state: SceneState) -> SceneState {
        var state = state
        var hidden = Set<UUID>()
        for group in state.groups where group.storage == .serverStorage { hidden.insert(group.id) }
        for part in state.parts where part.storage == .serverStorage { hidden.insert(part.id) }
        guard !hidden.isEmpty || state.dataObjects.contains(where: { $0.parent == .serverStorage })
                || state.scripts.contains(where: { $0.host == .serverStorage }) else { return state }
        // Everything inside what's hidden.
        var changed = true
        while changed {
            changed = false
            for group in state.groups where !hidden.contains(group.id) && group.parentID.map(hidden.contains) == true {
                hidden.insert(group.id)
                changed = true
            }
            for part in state.parts where !hidden.contains(part.id) && part.parentID.map(hidden.contains) == true {
                hidden.insert(part.id)
                changed = true
            }
        }
        state.groups.removeAll { hidden.contains($0.id) }
        state.parts.removeAll { hidden.contains($0.id) }
        var hiddenGui = Set(state.starterGui.filter { $0.worldParent.map(hidden.contains) ?? false }.map(\.id))
        var guiChanged = true
        while guiChanged {
            let oldCount = hiddenGui.count
            for object in state.starterGui where object.parentID.map(hiddenGui.contains) == true { hiddenGui.insert(object.id) }
            guiChanged = oldCount != hiddenGui.count
        }
        state.starterGui.removeAll { hiddenGui.contains($0.id) }
        state.scripts.removeAll { $0.host == .starterGui && ($0.parentID.map(hiddenGui.contains) ?? false) }
        state.scripts.removeAll { $0.host == .serverStorage || ($0.parentID.map(hidden.contains) ?? false) }
        state.sounds.removeAll { $0.parentID.map(hidden.contains) ?? false }
        let hiddenAttachments = Set(state.attachments.filter { hidden.contains($0.parentID) }.map(\.id))
        state.attachments.removeAll { hiddenAttachments.contains($0.id) }
        state.constraints.removeAll { constraint in
            [constraint.part0, constraint.part1].contains { $0.map(hidden.contains) ?? false }
                || [constraint.attachment0, constraint.attachment1].contains { $0.map(hiddenAttachments.contains) ?? false }
                || (constraint.parentID.map(hidden.contains) ?? false)
        }
        // Data objects in ServerStorage, or in anything hidden, and all inside them.
        var hiddenData = Set<UUID>()
        var queue = state.dataObjects.filter { object in
            switch object.parent {
            case .serverStorage: return true
            case .node(let id): return hidden.contains(id)
            default: return false
            }
        }
        while let next = queue.popLast() {
            guard hiddenData.insert(next.id).inserted else { continue }
            queue += state.dataObjects.filter { $0.parent == .node(next.id) }
        }
        state.dataObjects.removeAll { hiddenData.contains($0.id) }
        return state
    }
}
