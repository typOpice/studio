import Foundation

/// Finding things in a scene without searching all of it: where each part, group, data
/// object and Sound is in its array, and each node's children.
///
/// Nothing has to tell it about a change, so no change can leave it wrong:
/// - A slot is trusted only if the thing there still has the id asked for; if not, the
///   map is made again.
/// - The children, and whether a miss means "not there", are trusted only while the
///   scene's *structure* — ids, parents, where things are kept, in order — hasn't
///   changed. A fingerprint of that is taken (a quick pass over ids, not a copy of
///   every part) only when something has been changed since the last one.
/// SceneModel counts changes (`changes`) in the accessors of its arrays.
final class SceneIndex {
    /// Bumped by every change to the parts or the groups.
    var changes = 0
    /// Bumped by every change to the data objects or the Sounds.
    var otherChanges = 0

    private var checkedAt = -1
    private var fingerprint: UInt64 = 0
    private var partSlots: [UUID: Int] = [:]
    private var groupSlots: [UUID: Int] = [:]
    private var childNodes: [UUID?: [TreeNode]] = [:]
    private var built = false

    private var dataSlots: [UUID: Int] = [:]
    private var dataBuiltAt = -1
    private var soundSlots: [UUID: Int] = [:]
    private var soundBuiltAt = -1

    // MARK: - Parts and groups

    func partSlot(_ id: UUID, in model: SceneModel) -> Int? {
        let parts = model.parts
        if let slot = partSlots[id], slot < parts.count, parts[slot].id == id { return slot }
        guard refresh(model) else { return nil }
        return partSlots[id]
    }

    func groupSlot(_ id: UUID, in model: SceneModel) -> Int? {
        let groups = model.groups
        if let slot = groupSlots[id], slot < groups.count, groups[slot].id == id { return slot }
        guard refresh(model) else { return nil }
        return groupSlots[id]
    }

    /// A node's direct children, groups first, each in the order they were made (see
    /// `SceneModel.children(of:)` for which count as the Workspace's).
    func children(of parent: UUID?, in model: SceneModel) -> [TreeNode] {
        _ = refresh(model)
        return childNodes[parent] ?? []
    }

    /// Brings the maps up to the scene if its structure changed; whether it did.
    @discardableResult
    private func refresh(_ model: SceneModel) -> Bool {
        if built && checkedAt == changes { return false }
        checkedAt = changes
        let now = Self.structure(of: model)
        if built && now == fingerprint { return false }
        fingerprint = now
        rebuild(model)
        return true
    }

    private func rebuild(_ model: SceneModel) {
        built = true
        let parts = model.parts, groups = model.groups
        partSlots = Dictionary(minimumCapacity: parts.count)
        groupSlots = Dictionary(minimumCapacity: groups.count)
        childNodes = [:]
        // The first of a repeated id wins, as a search from the front would find it.
        for (slot, group) in groups.enumerated() where groupSlots[group.id] == nil {
            groupSlots[group.id] = slot
            if group.parentID != nil || model.isInWorkspace(group) {
                childNodes[group.parentID, default: []].append(.group(group.id))
            }
        }
        for (slot, part) in parts.enumerated() where partSlots[part.id] == nil {
            partSlots[part.id] = slot
            if part.parentID != nil || part.storage == nil {
                childNodes[part.parentID, default: []].append(.part(part.id))
            }
        }
    }

    /// What the tree hangs on — every id and parent, in order, and where each is kept —
    /// mixed into one number.
    static func structure(of model: SceneModel) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ value: UInt64) { hash = (hash ^ value) &* 0x100_0000_01b3 }
        func mix(_ id: UUID?) {
            guard let id else { return mix(0x9e37_79b9) }
            let (a, b) = withUnsafeBytes(of: id.uuid) { ($0.load(as: UInt64.self), $0.load(fromByteOffset: 8, as: UInt64.self)) }
            mix(a)
            mix(b)
        }
        model.parts.withUnsafeBufferPointer { parts in
            mix(UInt64(parts.count))
            for part in parts {
                mix(part.id)
                mix(part.parentID)
                mix(part.storage == nil ? 0 : 1)
            }
        }
        model.groups.withUnsafeBufferPointer { groups in
            mix(UInt64(groups.count) | 1 << 40)
            for group in groups {
                mix(group.id)
                mix(group.parentID)
                // All the Workspace's children care about: kept away, or a Tool out of it.
                mix(group.storage == nil ? 0 : 1)
                mix(group.tool.map { $0.place == .workspace ? 2 : 3 } ?? 0)
            }
        }
        return hash
    }

    // MARK: - Data objects and Sounds

    func dataSlot(_ id: UUID, in objects: [DataObject]) -> Int? {
        if let slot = dataSlots[id], slot < objects.count, objects[slot].id == id { return slot }
        guard dataBuiltAt != otherChanges || dataSlots.count != objects.count else { return nil }
        dataBuiltAt = otherChanges
        dataSlots = [:]
        for (slot, object) in objects.enumerated() where dataSlots[object.id] == nil { dataSlots[object.id] = slot }
        return dataSlots[id]
    }

    func soundSlot(_ id: UUID, in sounds: [SceneSound]) -> Int? {
        if let slot = soundSlots[id], slot < sounds.count, sounds[slot].id == id { return slot }
        guard soundBuiltAt != otherChanges || soundSlots.count != sounds.count else { return nil }
        soundBuiltAt = otherChanges
        soundSlots = [:]
        for (slot, sound) in sounds.enumerated() where soundSlots[sound.id] == nil { soundSlots[sound.id] = slot }
        return soundSlots[id]
    }
}
