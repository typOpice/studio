import Foundation
import simd

/// A Model, a Folder or a Tool: something that holds parts and other containers.
///
/// The scene is a tree, as in Roblox — Workspace at the root, then Models, Folders and
/// Parts, any of which can hold others. It is stored flat: every part and group names
/// its parent (`nil` is the Workspace), so the renderer, physics and collision keep
/// iterating one array of parts and never walk the tree.
struct SceneGroup: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        /// Moves as one: select it and you move everything inside; has a pivot.
        case model = "Model"
        /// Only organises: selecting it selects nothing in the viewport.
        case folder = "Folder"
        /// Something a player holds: a Model with a Handle, kept in StarterPack or a
        /// Backpack until it is equipped. Its settings are in `tool`.
        case tool = "Tool"
    }

    var id = UUID()
    var name = "Model"
    var kind = Kind.model
    /// The group, or part, that holds this one; nil for the Workspace.
    var parentID: UUID?
    /// A Model's pivot comes from this part, when it is set and still inside.
    var primaryPartID: UUID?
    /// A Tool's settings and where it is; nil for Models and Folders.
    var tool: ToolSettings?
    /// Kept in ReplicatedStorage or ServerStorage (at the top of the tree only).
    var storage: StoragePlace?

    init(name: String = "Model", kind: Kind = .model, parentID: UUID? = nil) {
        self.name = name
        self.kind = kind
        self.parentID = parentID
        if kind == .tool { tool = ToolSettings() }
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, parentID, primaryPartID, tool, storage }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Model"
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .model
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        primaryPartID = try c.decodeIfPresent(UUID.self, forKey: .primaryPartID)
        tool = try c.decodeIfPresent(ToolSettings.self, forKey: .tool)
        if kind == .tool && tool == nil { tool = ToolSettings() }
        storage = try c.decodeIfPresent(StoragePlace.self, forKey: .storage)
    }
}

/// What makes a group a Tool, as Roblox's Tool has it, and where the tool is.
struct ToolSettings: Codable, Equatable {
    var toolTip = ""
    var enabled = true
    /// Without a part named Handle, a tool that requires one can't be held.
    var requiresHandle = true
    var canBeDropped = true
    /// Tool.Grip: where the Handle sits in the hand, as CFrame components; nil is the
    /// identity.
    var grip: [Float]?
    var place = ToolPlace.workspace
}

/// Where a Tool is. Only in the Workspace or a hand is it in the world; in StarterPack
/// or a Backpack its parts are parked (`Part.parked`), out of everything.
enum ToolPlace: Codable, Equatable {
    case workspace
    /// A template every player is given a copy of when their character spawns.
    case starterPack
    /// In a player's Backpack, by their number (0 is the host, or the only player).
    case backpack(Int)
    /// Equipped: in that player's right hand.
    case hand(Int)

    /// The player it belongs to, if any.
    var holder: Int? {
        switch self {
        case .backpack(let player), .hand(let player): return player
        case .workspace, .starterPack: return nil
        }
    }

    var inWorld: Bool {
        switch self {
        case .workspace, .hand: return true
        case .starterPack, .backpack: return false
        }
    }
}

/// Something in the tree, by kind.
enum TreeNode: Hashable {
    case part(UUID)
    case group(UUID)

    var id: UUID {
        switch self {
        case .part(let id), .group(let id): return id
        }
    }
}

/// A position and a rotation — what Roblox calls a CFrame.
struct Pose: Equatable {
    var position: Vec3
    var orientation: simd_quatf

    static let identity = Pose(position: .zero, orientation: simd_quatf(angle: 0, axis: Vec3(0, 1, 0)))

    /// This pose followed by `other`, expressed in this pose's space.
    func applying(_ other: Pose) -> Pose {
        Pose(position: position + orientation.act(other.position),
             orientation: simd_normalize(orientation * other.orientation))
    }

    var inverse: Pose {
        let inverted = orientation.inverse
        return Pose(position: inverted.act(-position), orientation: inverted)
    }

    static func == (a: Pose, b: Pose) -> Bool {
        a.position == b.position && a.orientation.vector == b.orientation.vector
    }

    /// x, y, z, then the rotation matrix row by row: Roblox's CFrame:GetComponents().
    var components: [Float] {
        let m = float3x3(orientation)
        return [position.x, position.y, position.z,
                m[0][0], m[1][0], m[2][0],
                m[0][1], m[1][1], m[2][1],
                m[0][2], m[1][2], m[2][2]]
    }

}

extension Pose {
    /// From `components`; the rotation is re-orthonormalised, so a slightly skewed
    /// matrix from a script still makes a clean rotation.
    init?(components c: [Float]) {
        guard c.count == 12, c.allSatisfy(\.isFinite) else { return nil }
        var x = Vec3(c[3], c[6], c[9])
        var y = Vec3(c[4], c[7], c[10])
        guard length(x) > 1e-6, length(y) > 1e-6 else { return nil }
        x = normalize(x)
        y = y - x * dot(x, y)
        guard length(y) > 1e-6 else { return nil }
        y = normalize(y)
        let z = cross(x, y)
        position = Vec3(c[0], c[1], c[2])
        orientation = simd_normalize(simd_quatf(float3x3(columns: (x, y, z))))
    }
}

extension Part {
    var pose: Pose {
        get { Pose(position: position, orientation: orientation) }
        set {
            position = newValue.position
            orientation = newValue.orientation
        }
    }
}

extension SceneModel {

    // MARK: - Finding things

    func group(id: UUID) -> SceneGroup? { index.groupSlot(id, in: self).map { groups[$0] } }

    func groupIndex(of id: UUID) -> Int? { index.groupSlot(id, in: self) }

    func node(_ id: UUID) -> TreeNode? {
        if index.partSlot(id, in: self) != nil { return .part(id) }
        if index.groupSlot(id, in: self) != nil { return .group(id) }
        return nil
    }

    func exists(_ id: UUID) -> Bool { node(id) != nil }

    /// The parent of a part or group: nil for the Workspace (or for nothing).
    func parentID(of id: UUID) -> UUID? {
        if let slot = index.partSlot(id, in: self) { return parts[slot].parentID }
        return index.groupSlot(id, in: self).flatMap { groups[$0].parentID }
    }

    func name(of id: UUID) -> String? {
        part(id: id)?.name ?? group(id: id)?.name
    }

    /// Direct children, groups first, each in the order they were made. A Tool in
    /// StarterPack, a Backpack or a hand isn't among the Workspace's.
    func children(of parent: UUID?) -> [TreeNode] {
        index.children(of: parent, in: self)
    }

    /// Everything below, depth first.
    func descendants(of parent: UUID?) -> [TreeNode] {
        var result: [TreeNode] = []
        var visited: Set<UUID> = []
        func walk(_ id: UUID?) {
            for child in children(of: id) where visited.insert(child.id).inserted {
                result.append(child)
                walk(child.id)
            }
        }
        walk(parent)
        return result
    }

    /// The parts in a subtree: the node itself if it is a part, plus every part below.
    func partIDs(inSubtree id: UUID) -> [UUID] {
        var ids: [UUID] = []
        if index.partSlot(id, in: self) != nil { ids.append(id) }
        for case .part(let child) in descendants(of: id) { ids.append(child) }
        return ids
    }

    func isDescendant(_ id: UUID, of ancestor: UUID) -> Bool {
        var current = parentID(of: id)
        var steps = 0
        while let parent = current, steps < 10_000 {
            if parent == ancestor { return true }
            current = parentID(of: parent)
            steps += 1
        }
        return false
    }

    /// The outermost Model a part is in — what a click in the viewport selects, as in
    /// Roblox Studio. Folders don't count: they organise, they don't move as one.
    func outermostModel(containing id: UUID) -> UUID? {
        var found: UUID?
        var current = parentID(of: id)
        var steps = 0
        while let parent = current, steps < 10_000 {
            if group(id: parent)?.kind == .model { found = parent }
            current = parentID(of: parent)
            steps += 1
        }
        return found
    }

    /// The first child with that name, optionally looking all the way down.
    func findChild(named name: String, in parent: UUID?, recursive: Bool = false) -> TreeNode? {
        let candidates = recursive ? descendants(of: parent) : children(of: parent)
        return candidates.first { self.name(of: $0.id) == name }
    }

    /// Whether `id` may move under `parent`: the parent exists and isn't inside it.
    func canReparent(_ id: UUID, to parent: UUID?) -> Bool {
        guard exists(id) else { return false }
        guard let parent else { return true }
        return parent != id && exists(parent) && !isDescendant(parent, of: id)
    }

    // MARK: - Changing the tree (no undo; callers commit)

    @discardableResult
    func setParent(_ id: UUID, _ parent: UUID?) -> Bool {
        guard canReparent(id, to: parent) else { return false }
        if let index = self.index.partSlot(id, in: self) {
            parts[index].parentID = parent
        } else if let index = self.index.groupSlot(id, in: self) {
            groups[index].parentID = parent
        }
        return true
    }

    func updateGroup(id: UUID, _ body: (inout SceneGroup) -> Void) {
        guard let index = self.index.groupSlot(id, in: self) else { return }
        // A copy changed and put back, so `body` may read the scene (see update(id:)).
        var group = groups[index]
        body(&group)
        if let slot = self.index.groupSlot(id, in: self) { groups[slot] = group }
    }

    /// Removes nodes and everything under them, and the scripts inside.
    func removeSubtrees(_ ids: [UUID]) {
        var doomed = Set(ids)
        for id in ids { doomed.formUnion(descendants(of: id).map(\.id)) }
        parts.removeAll { doomed.contains($0.id) }
        groups.removeAll { doomed.contains($0.id) }
        scripts.removeAll { $0.parentID.map(doomed.contains) ?? false }
        sounds.removeAll { $0.parentID.map(doomed.contains) ?? false }
        selection.subtract(doomed)
        for index in groups.indices where groups[index].primaryPartID.map(doomed.contains) ?? false {
            groups[index].primaryPartID = nil
        }
        // Joints under what went, and joints that lost a part, go too.
        constraints.removeAll { $0.parentID.map(doomed.contains) ?? false }
        pruneConstraints()
        // Folders, Values and remotes inside what went.
        let inside = dataObjects.filter { object in
            if case .node(let parent) = object.parent { return doomed.contains(parent) }
            return false
        }
        if !inside.isEmpty { removeDataObjects(Set(inside.map(\.id)), undoable: false) }
    }

    /// Copies a subtree — parts, groups, scripts and sounds, all newly identified — under
    /// `parent`. Returns the copy's id.
    @discardableResult
    func cloneSubtree(_ id: UUID, parent: UUID?, offset: Vec3 = .zero) -> UUID? {
        guard exists(id) else { return nil }
        let nodes = [TreeNode.part(id)].filter { _ in part(id: id) != nil }
            + [TreeNode.group(id)].filter { _ in group(id: id) != nil }
            + descendants(of: id)
        var remap: [UUID: UUID] = [:]
        for node in nodes { remap[node.id] = UUID() }

        for node in nodes {
            switch node {
            case .part(let original):
                guard var copy = part(id: original) else { continue }
                copy.id = remap[original]!
                copy.parentID = original == id ? parent : copy.parentID.flatMap { remap[$0] }
                copy.position += offset
                parts.append(copy)
            case .group(let original):
                guard var copy = group(id: original) else { continue }
                copy.id = remap[original]!
                copy.parentID = original == id ? parent : copy.parentID.flatMap { remap[$0] }
                copy.primaryPartID = copy.primaryPartID.flatMap { remap[$0] }
                groups.append(copy)
            }
        }
        for script in scripts where script.parentID.map({ remap[$0] != nil }) ?? false {
            var copy = script
            copy.id = UUID()
            copy.parentID = remap[script.parentID!]
            scripts.append(copy)
        }
        // Data objects inside, and inside those.
        var dataQueue = dataObjects.filter { object in
            if case .node(let parent) = object.parent { return remap[parent] != nil }
            return false
        }
        while !dataQueue.isEmpty {
            let original = dataQueue.removeFirst()
            guard case .node(let parent) = original.parent, let newParent = remap[parent] else { continue }
            var copy = original
            copy.id = UUID()
            copy.parent = .node(newParent)
            remap[original.id] = copy.id
            dataObjects.append(copy)
            dataQueue += dataObjects(in: .node(original.id))
        }
        for sound in sounds where sound.parentID.map({ remap[$0] != nil }) ?? false {
            var copy = sound
            copy.id = UUID()
            copy.parentID = remap[sound.parentID!]
            sounds.append(copy)
        }
        // Attachments on copied parts, and joints wholly inside the copy.
        for attachment in attachments where remap[attachment.parentID] != nil {
            var copy = attachment
            copy.id = UUID()
            copy.parentID = remap[attachment.parentID]!
            remap[attachment.id] = copy.id
            attachments.append(copy)
        }
        for constraint in constraints {
            let ends = constraint.kind == .weld ? [constraint.part0, constraint.part1]
                                                : [constraint.attachment0, constraint.attachment1]
            guard ends.allSatisfy({ $0.map { remap[$0] != nil } ?? false }) else { continue }
            var copy = constraint
            copy.id = UUID()
            copy.parentID = constraint.parentID.flatMap { remap[$0] } ?? constraint.parentID
            copy.part0 = constraint.part0.flatMap { remap[$0] }
            copy.part1 = constraint.part1.flatMap { remap[$0] }
            copy.attachment0 = constraint.attachment0.flatMap { remap[$0] }
            copy.attachment1 = constraint.attachment1.flatMap { remap[$0] }
            constraints.append(copy)
        }
        return remap[id]
    }

    // MARK: - Models: pivot and bounds

    /// Where a Model is and which way it faces: its PrimaryPart's pose, or the middle
    /// of everything inside, unrotated. A part's pivot is its own pose.
    func pivot(of id: UUID) -> Pose? {
        if let part = part(id: id) { return part.pose }
        guard let group = group(id: id) else { return nil }
        if let primary = group.primaryPartID, isDescendant(primary, of: id), let part = part(id: primary) {
            return part.pose
        }
        guard let box = boundingBox(of: partIDs(inSubtree: id)) else {
            return Pose(position: .zero, orientation: Pose.identity.orientation)
        }
        return Pose(position: box.center, orientation: Pose.identity.orientation)
    }

    /// Moves a subtree rigidly so its pivot lands on `target`.
    func movePivot(of id: UUID, to target: Pose) {
        guard let current = pivot(of: id) else { return }
        let delta = target.applying(current.inverse)
        for partID in partIDs(inSubtree: id) {
            update(id: partID) { part in part.pose = delta.applying(part.pose) }
        }
    }

    /// The world-aligned box around some parts, rotation included.
    func boundingBox(of ids: [UUID]) -> (center: Vec3, size: Vec3)? {
        var lo = Vec3(repeating: .greatestFiniteMagnitude)
        var hi = Vec3(repeating: -.greatestFiniteMagnitude)
        var any = false
        for id in ids {
            guard let part = part(id: id) else { continue }
            any = true
            let rotation = float3x3(part.orientation)
            let half = part.size * 0.5
            let extent = abs(rotation.columns.0) * half.x + abs(rotation.columns.1) * half.y
                + abs(rotation.columns.2) * half.z
            lo = simd_min(lo, part.position - extent)
            hi = simd_max(hi, part.position + extent)
        }
        return any ? ((lo + hi) * 0.5, hi - lo) : nil
    }

    // MARK: - Editor commands (undoable)

    func uniqueGroupName(base: String) -> String {
        let existing = Set(groups.map(\.name))
        if !existing.contains(base) { return base }
        var n = 1
        while existing.contains("\(base)\(n)") { n += 1 }
        return "\(base)\(n)"
    }

    /// The selected nodes that aren't inside another selected node.
    var selectionRoots: [UUID] {
        let selected = selection.filter(exists)
        return selected.filter { id in !selected.contains { $0 != id && isDescendant(id, of: $0) } }
            .sorted { ($0.uuidString) < ($1.uuidString) }
    }

    /// Puts the selection into a new Model (or Folder), where the selection was.
    @discardableResult
    func groupSelection(kind: SceneGroup.Kind = .model) -> UUID? {
        let roots = selectionRoots
        guard !roots.isEmpty else { return nil }
        let parents = Set(roots.map { parentID(of: $0) })
        let parent = parents.count == 1 ? parents.first! : nil
        var group = SceneGroup(name: uniqueGroupName(base: kind.rawValue), kind: kind, parentID: parent)
        if kind == .model, roots.count == 1, part(id: roots[0]) != nil {
            group.primaryPartID = roots[0]
        }
        commit("Grouped \(roots.count) into \(group.name)") {
            groups.append(group)
            for id in roots { setParent(id, group.id) }
            selection = [group.id]
        }
        return group.id
    }

    /// Moves a group's children up to its parent and removes the group.
    func ungroup(_ id: UUID) {
        guard let group = group(id: id) else { return }
        let children = children(of: id).map(\.id)
        commit("Ungrouped \(group.name)") {
            for child in children { setParent(child, group.parentID) }
            groups.removeAll { $0.id == id }
            scripts.removeAll { $0.parentID == id }
            selection = Set(children)
        }
    }

    func makeGroup(kind: SceneGroup.Kind, parent: UUID? = nil) -> UUID {
        let group = SceneGroup(name: uniqueGroupName(base: kind.rawValue), kind: kind, parentID: parent)
        commit("Added \(group.name)") {
            groups.append(group)
            selection = [group.id]
        }
        return group.id
    }

    /// Moves something in the Explorer, refusing moves into itself.
    func move(_ id: UUID, to parent: UUID?) {
        guard canReparent(id, to: parent), parentID(of: id) != parent else { return }
        commit("Moved \(name(of: id) ?? "item")") { setParent(id, parent) }
    }

    func renameNode(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        commit("Renamed") {
            if part(id: id) != nil { update(id: id) { $0.name = trimmed } }
            updateGroup(id: id) { $0.name = trimmed }
        }
    }
}
