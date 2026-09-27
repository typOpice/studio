import Foundation

// The script runtime's host calls for `npc.*`: a Model's Humanoid (a data object, see
// DataObjects.swift) and the body NPCSystem gives it. Its numbers — Health, MaxHealth,
// WalkSpeed, JumpPower, AutoRotate — are the data object's, so they're saved and sent to
// joined players; steering it (MoveTo, Move, Jump) is the play session's, and only the
// machine running the scene's scripts steers.

extension ScriptRuntime {
    func npcCall(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        guard let id = uuid(arguments.first), let object = model.dataObject(id: id), object.className == .humanoid else {
            return .nothing
        }
        let key = arguments.count > 1 ? (arguments[1].asString ?? "").lowercased() : ""
        let npcs = npcSource?()
        switch name {
        case "npc.get":
            let state = npcs?.state(of: id)
            switch key {
            case "health": return .number(object.health)
            case "maxhealth": return .number(object.maxHealth)
            case "walkspeed": return .number(object.walkSpeed)
            case "jumppower": return .number(object.jumpPower)
            case "autorotate": return .bool(object.autoRotate)
            case "movedirection":
                let direction = state?.moveDirection ?? .zero
                return .triple(direction.x, direction.y, direction.z)
            case "walktopoint":
                let point = state?.walkToPoint ?? .zero
                return .triple(point.x, point.y, point.z)
            case "rootpart":
                return (npcs?.rootPart(of: id)).map { .string("p:" + $0.uuidString) } ?? .nothing
            case "state":
                if object.health <= 0 { return .string("Dead") }
                guard let state else { return .string("Running") }
                return .string(state.grounded ? "Running" : state.rising ? "Jumping" : "Freefall")
            default: return .nothing
            }

        case "npc.set":
            guard arguments.count > 2 else { return .bool(false) }
            let value = arguments[2]
            var accepted = true
            model.updateDataObject(id: id) { humanoid in
                switch key {
                case "health": if let n = value.asDouble, n.isFinite { humanoid.health = n } else { accepted = false }
                case "maxhealth": if let n = value.asDouble, n.isFinite { humanoid.maxHealth = n } else { accepted = false }
                case "walkspeed": if let n = value.asDouble, n.isFinite { humanoid.walkSpeed = n } else { accepted = false }
                case "jumppower": if let n = value.asDouble, n.isFinite { humanoid.jumpPower = n } else { accepted = false }
                case "autorotate": if let b = value.asBool { humanoid.autoRotate = b } else { accepted = false }
                default: accepted = false
                }
            }
            return .bool(accepted)

        case "npc.damage":
            guard let amount = arguments.count > 1 ? arguments[1].asDouble : nil, amount.isFinite else { return .nothing }
            model.updateDataObject(id: id) { $0.health -= max(amount, 0) }
            return .nothing

        case "npc.moveTo":
            guard runsSceneScripts else { return .nothing }
            let point = arguments.count > 1 ? arguments[1].asTriple.map { Vec3($0.0, $0.1, $0.2) } : nil
            npcs?.moveTo(id, point)
            return .nothing

        case "npc.move":
            guard runsSceneScripts, let (x, y, z) = arguments.count > 1 ? arguments[1].asTriple : nil else { return .nothing }
            npcs?.move(id, direction: Vec3(x, y, z))
            return .nothing

        case "npc.jump":
            guard runsSceneScripts else { return .nothing }
            npcs?.jump(id)
            return .nothing

        default:
            return .nothing
        }
    }
}
