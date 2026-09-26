import Foundation
import simd

// SceneModel — Tools: where each Tool is (Workspace, StarterPack, a Backpack or a hand),
// and keeping the parts of tools that are out of the world parked.

extension SceneModel {
    var tools: [SceneGroup] { groups.filter { $0.kind == .tool } }

    func toolPlace(_ id: UUID) -> ToolPlace? { group(id: id)?.tool?.place }

    /// The templates every player is given a copy of when their character spawns.
    var starterPackTools: [SceneGroup] { tools.filter { $0.tool?.place == .starterPack } }

    /// A player's tools: in their Backpack, then the one in their hand.
    func tools(of player: Int) -> [SceneGroup] { tools.filter { $0.tool?.place.holder == player } }

    func heldTool(of player: Int) -> SceneGroup? { tools.first { $0.tool?.place == .hand(player) } }

    /// A tool's Handle: the part named Handle directly inside it.
    func handle(of tool: UUID) -> Part? {
        parts.first { $0.parentID == tool && $0.name == "Handle" }
    }

    /// Moves a Tool, parking its parts when it leaves the world and bringing them back
    /// when it returns. Out of the Workspace a tool hangs from nothing in the tree: its
    /// Backpack or holder is where the tool says it is. No undo; callers commit.
    func setToolPlace(_ id: UUID, _ place: ToolPlace) {
        guard let index = groups.firstIndex(where: { $0.id == id }), groups[index].kind == .tool else { return }
        if groups[index].tool == nil { groups[index].tool = ToolSettings() }
        groups[index].tool?.place = place
        if place != .workspace { groups[index].parentID = nil }
        let parked = !place.inWorld
        let inside = Set(partIDs(inSubtree: id))
        for i in parts.indices where inside.contains(parts[i].id) && parts[i].parked != parked {
            parts[i].parked = parked
        }
    }

    /// Whether something is inside a Tool that is out of the world (StarterPack or a
    /// Backpack) — its scripts don't run with the scene's.
    func isParked(_ id: UUID?) -> Bool {
        var current = id
        var steps = 0
        while let at = current, steps < 10_000 {
            if let place = group(id: at)?.tool?.place, !place.inWorld { return true }
            if group(id: at)?.storage != nil || part(id: at)?.storage != nil { return true }
            current = parentID(of: at)
            steps += 1
        }
        return false
    }

    /// Whether a group shows among the Workspace's children: anything but a Tool that
    /// is somewhere else.
    func isInWorkspace(_ group: SceneGroup) -> Bool {
        group.storage == nil && (group.tool.map { $0.place == .workspace } ?? true)
    }

    // MARK: - Editing (with undo)

    /// A new Tool in the Workspace with a Handle to hold it by.
    @discardableResult
    func addTool(at position: Vec3? = nil) -> UUID {
        let tool = SceneGroup(name: uniqueGroupName(base: "Tool"), kind: .tool)
        var handle = Part()
        handle.name = "Handle"
        handle.size = Vec3(0.6, 4, 0.6)
        handle.color = Vec3(0.55, 0.55, 0.6)
        handle.material = .metal
        handle.position = position ?? Vec3(0, 3, 0)
        handle.parentID = tool.id
        commit("Added \(tool.name)") {
            groups.append(tool)
            parts.append(handle)
            selection = [tool.id]
        }
        return tool.id
    }

    /// Puts a Workspace Tool into StarterPack, so every player starts with one.
    func moveToStarterPack(_ id: UUID) {
        guard let tool = group(id: id), tool.kind == .tool, tool.tool?.place != .starterPack else { return }
        commit("Moved \(tool.name) to StarterPack") {
            setToolPlace(id, .starterPack)
            selection = [id]
        }
    }

    /// Takes a Tool out of StarterPack into the Workspace, to be seen and edited.
    func moveToWorkspace(_ id: UUID) {
        guard let tool = group(id: id), tool.kind == .tool, tool.tool?.place == .starterPack else { return }
        commit("Moved \(tool.name) to the Workspace") {
            setToolPlace(id, .workspace)
            selection = [id]
        }
    }

    func updateTool(id: UUID, _ body: (inout ToolSettings) -> Void) {
        guard let index = groups.firstIndex(where: { $0.id == id }), groups[index].kind == .tool else { return }
        var settings = groups[index].tool ?? ToolSettings()
        body(&settings)
        groups[index].tool = settings
    }
}
