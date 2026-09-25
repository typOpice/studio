import Foundation
import simd

// PlayController and Tools: StarterPack copies for each character, the Backpack,
// equipping, dropping and picking up, clicks as Activated, and holding a tool in the
// right hand. The host decides for everyone — a joined player's game asks it (see
// `sendAction`) and draws its own tool in its own hand; `backpack.*` are the host calls.

extension PlayController {
    /// Where the Handle sits in the hand before Tool.Grip: pointing along the arm's
    /// front, so a tool modelled standing up is held up with the arm out.
    static let gripTurn = Pose(position: .zero, orientation: simd_quatf(angle: -.pi / 2, axis: Vec3(1, 0, 0)))
    /// How long a player's own dropped tool can't be picked straight back up by them.
    static let pickUpDelay: Double = 1

    var isHoldingTool: Bool { model.heldTool(of: playerID) != nil }

    /// `["Tool", toolID, "Equipped" | "Unequipped" | "Activated" | "Deactivated"]`
    func queueToolEvent(_ id: UUID, _ what: String) {
        pendingEvents.append(.list([.string("Tool"), .string(id.uuidString), .string(what)]))
    }

    // MARK: - StarterPack and the Backpack

    /// Gives a player a copy of every StarterPack tool, starting the scripts inside under
    /// the scope of the character they came with. Only the host gives tools.
    func giveStarterTools(to player: Int, scope: Int) {
        runToolScripts(copyStarterTools(to: player), scope: scope)
    }

    /// The copies alone, returning their scripts: at the start of play the tools are
    /// there before any script runs, as a Roblox Backpack is.
    func copyStarterTools(to player: Int) -> [ScriptObject] {
        guard !worldFromHost else { return [] }
        var scripts: [ScriptObject] = []
        for template in model.starterPackTools {
            guard let copy = model.cloneSubtree(template.id, parent: nil) else { continue }
            model.setToolPlace(copy, .backpack(player))
            let inside = Set([copy] + model.descendants(of: copy).map(\.id))
            scripts += model.scripts.filter { $0.parentID.map(inside.contains) ?? false }
        }
        return scripts
    }

    func runToolScripts(_ started: [ScriptObject], scope: Int) {
        toolScripts[scope] = started
        scripts.runScripts(started, scope: scope)
    }

    /// Takes everything a player has — Backpack and hand — as their character goes, and
    /// stops the scripts their StarterPack copies were running.
    func takeTools(from player: Int, scope: Int) {
        if let started = toolScripts.removeValue(forKey: scope) {
            scripts.endScope(scope, scripts: started)
        }
        let ids = model.tools(of: player).map(\.id)
        for id in ids { toolLayouts[id] = nil }
        if !ids.isEmpty { model.removeSubtrees(ids) }
    }

    // MARK: - Moving tools (the host)

    /// Puts a tool in a player's hand; the one they held goes back to their Backpack.
    func equipTool(_ id: UUID, for player: Int) {
        guard let tool = model.group(id: id), let settings = tool.tool,
              settings.place.holder == player || settings.place == .workspace else { return }
        if settings.requiresHandle && model.handle(of: id) == nil { return }
        if settings.place == .hand(player) { return }
        if let current = model.heldTool(of: player) { unequipTool(of: player) ; _ = current }
        toolLayouts[id] = nil
        model.setToolPlace(id, .hand(player))
        queueToolEvent(id, "Equipped")
    }

    func unequipTool(of player: Int) {
        guard let tool = model.heldTool(of: player) else { return }
        toolLayouts[tool.id] = nil
        model.setToolPlace(tool.id, .backpack(player))
        queueToolEvent(tool.id, "Unequipped")
    }

    /// Into a player's Backpack, from the Workspace or from someone else.
    func giveTool(_ id: UUID, to player: Int) {
        guard let place = model.toolPlace(id), place != .backpack(player) else { return }
        if case .hand = place { queueToolEvent(id, "Unequipped") }
        toolLayouts[id] = nil
        model.setToolPlace(id, .backpack(player))
    }

    /// Into the Workspace. A tool in a hand stays where the hand was; one from a Backpack
    /// appears in front of its holder.
    func dropTool(_ id: UUID) {
        guard let tool = model.group(id: id), let place = tool.tool?.place, place != .workspace,
              place != .starterPack else { return }
        if case .hand = place { queueToolEvent(id, "Unequipped") }
        if case .backpack(let holder) = place, let hand = handPose(of: holder),
           let handle = model.handle(of: id) {
            let offset = hand.position - handle.position + Vec3(0, 0, 0)
            let inside = Set(model.partIDs(inSubtree: id))
            var parts = model.parts
            for i in parts.indices where inside.contains(parts[i].id) { parts[i].position += offset }
            model.parts = parts
        }
        if let holder = place.holder { toolDrops[id] = (holder, clock) }
        toolLayouts[id] = nil
        model.setToolPlace(id, .workspace)
    }

    /// A click with a tool in hand: Activated going down, Deactivated coming up.
    func activateTool(_ id: UUID, by player: Int, down: Bool) {
        guard let settings = model.group(id: id)?.tool, settings.place == .hand(player), settings.enabled else { return }
        queueToolEvent(id, down ? "Activated" : "Deactivated")
    }

    /// Picking up a Workspace tool by touching its Handle: into the hand if it's empty,
    /// else the Backpack.
    func pickUpTools(touched touches: Set<CharacterTouch.Touch>, by player: Int) {
        guard !worldFromHost else { return }
        for touch in touches {
            guard let handle = model.part(id: touch.partID), handle.name == "Handle",
                  let toolID = handle.parentID, let tool = model.group(id: toolID),
                  tool.tool?.place == .workspace, tool.tool?.enabled == true else { continue }
            if let drop = toolDrops[toolID], drop.player == player, clock - drop.time < Self.pickUpDelay { continue }
            toolDrops[toolID] = nil
            if model.heldTool(of: player) == nil {
                equipTool(toolID, for: player)
            } else {
                giveTool(toolID, to: player)
            }
        }
    }

    /// A joined player asking the host to do something with their tools.
    func remoteAction(from player: Int, _ name: String, _ arguments: [ScriptValue]) {
        let id = arguments.first?.asString.flatMap(UUID.init(uuidString:))
        switch name {
        case "backpack.equip":
            if let id { equipTool(id, for: player) }
        case "backpack.unequip":
            unequipTool(of: player)
        case "backpack.drop":
            if let id, model.toolPlace(id)?.holder == player, model.group(id: id)?.tool?.canBeDropped == true {
                dropTool(id)
            }
        case "backpack.activate":
            if let id { activateTool(id, by: player, down: arguments.count > 1 ? arguments[1].asBool ?? true : true) }
        case "click.part", "click.hover":
            remoteClick(from: player, name, arguments)
        default:
            break
        }
    }

    /// Mouse button 1 with a tool in hand.
    func clickTool(down: Bool) {
        guard let tool = model.heldTool(of: playerID) else { return }
        if worldFromHost {
            sendAction?("backpack.activate", [.string(tool.id.uuidString), .bool(down)])
        } else {
            activateTool(tool.id, by: playerID, down: down)
        }
    }

    // MARK: - In the hand

    /// Where a player's right hand is and how it's turned, from how their body is posed.
    func handPose(of player: Int) -> Pose? {
        let pose: AvatarPose
        if player == playerID {
            guard hasPlayer, characterGeneration > 0 else { return nil }
            pose = AvatarPose(position: character.position, yaw: character.facingYaw, joints: currentJoints,
                              dead: humanoid.isDead)
        } else if let remote = remotePlayers.first(where: { $0.id == player }) {
            let shown = shownRemote[player]
            pose = AvatarPose(position: shown?.position ?? remote.position, yaw: shown?.yaw ?? remote.yaw,
                              joints: remote.joints, dead: remote.dead)
        } else {
            return nil
        }
        guard let arm = pose.partTransforms().first(where: { $0.name == "Right Arm" })?.matrix else { return nil }
        let hand = arm * SIMD4<Float>(0, -1, 0, 1)
        let turn = float3x3(columns: (SIMD3(arm.columns.0.x, arm.columns.0.y, arm.columns.0.z),
                                      SIMD3(arm.columns.1.x, arm.columns.1.y, arm.columns.1.z),
                                      SIMD3(arm.columns.2.x, arm.columns.2.y, arm.columns.2.z)))
        return Pose(position: Vec3(hand.x, hand.y, hand.z), orientation: simd_normalize(simd_quatf(turn)))
    }

    /// Moves every held tool to its holder's hand, keeping its parts where they are
    /// around the Handle, and notes which parts are held. A joined player's game moves
    /// only its own; the host's updates bring the others.
    func positionHeldTools() {
        var held: Set<UUID> = []
        var parts = model.parts
        var index: [UUID: Int]?
        var moved = false
        for tool in model.tools {
            guard case .hand(let holder)? = tool.tool?.place else { continue }
            let inside = model.partIDs(inSubtree: tool.id)
            held.formUnion(inside)
            guard !worldFromHost || holder == playerID, let hand = handPose(of: holder),
                  let handle = model.handle(of: tool.id) else { continue }
            let layout = toolLayouts[tool.id] ?? {
                let base = handle.pose.inverse
                var offsets: [UUID: Pose] = [:]
                for id in inside { if let part = model.part(id: id) { offsets[id] = base.applying(part.pose) } }
                toolLayouts[tool.id] = offsets
                return offsets
            }()
            let grip = tool.tool?.grip.flatMap(Pose.init(components:)) ?? .identity
            let placed = hand.applying(Self.gripTurn).applying(grip.inverse)
            if index == nil { index = Dictionary(uniqueKeysWithValues: parts.enumerated().map { ($1.id, $0) }) }
            for id in inside {
                guard let i = index?[id], let offset = layout[id] else { continue }
                parts[i].pose = placed.applying(offset)
                moved = true
            }
        }
        heldToolParts = held
        if moved { model.parts = parts }
    }

    /// The parts bodies collide with and physics moves: not the ones held in hands.
    var partsOutOfHands: [Part] {
        heldToolParts.isEmpty ? model.parts : model.parts.filter { !heldToolParts.contains($0.id) }
    }

    // MARK: - backpack.* host calls

    func backpackCall(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        func number(_ index: Int) -> Int? { arguments.count > index ? arguments[index].asDouble.map(Int.init) : nil }
        func tool(_ index: Int) -> UUID? { arguments.count > index ? arguments[index].asString.flatMap(UUID.init(uuidString:)) : nil }
        /// The player a character belongs to, from its number.
        func owner(ofCharacter number: Int?) -> Int? {
            guard let number else { return nil }
            if let remote = RemoteCharacter.owner(of: number) { return remote }
            return number == characterGeneration ? playerID : nil
        }
        switch name {
        case "backpack.me":
            return .number(Double(playerID))
        case "backpack.list":
            let player = number(0).map { $0 < 0 ? playerID : $0 } ?? playerID
            return .list(model.tools.filter { $0.tool?.place == .backpack(player) }.map { .string($0.id.uuidString) })
        case "backpack.held":
            guard let player = owner(ofCharacter: number(0)), let held = model.heldTool(of: player) else { return .nothing }
            return .string(held.id.uuidString)
        case "backpack.equip":
            guard let player = owner(ofCharacter: number(0)), let id = tool(1) else { return .nothing }
            if worldFromHost {
                if player == playerID { sendAction?("backpack.equip", [.string(id.uuidString)]) }
            } else {
                equipTool(id, for: player)
            }
        case "backpack.unequip":
            guard let player = owner(ofCharacter: number(0)) else { return .nothing }
            if worldFromHost {
                if player == playerID { sendAction?("backpack.unequip", []) }
            } else {
                unequipTool(of: player)
            }
        case "backpack.give":
            guard !worldFromHost, let player = number(0).map({ $0 < 0 ? playerID : $0 }), let id = tool(1) else { return .nothing }
            giveTool(id, to: player)
        case "backpack.drop":
            guard let id = tool(0) else { return .nothing }
            if worldFromHost {
                sendAction?("backpack.drop", [.string(id.uuidString)])
            } else {
                dropTool(id)
            }
        case "backpack.activate":
            guard !worldFromHost, let id = tool(0), let holder = model.toolPlace(id)?.holder else { return .nothing }
            activateTool(id, by: holder, down: arguments.count > 1 ? arguments[1].asBool ?? true : true)
        default:
            console.error("Unknown host call \"\(name)\".")
        }
        return .nothing
    }
}
