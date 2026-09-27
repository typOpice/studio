import Foundation
import simd

// PlayController and scripts talking across machines: RemoteEvents and RemoteFunctions
// (`remote.*`), rays that meet characters (`character.raycast`), and Value objects'
// Changed when a value changes from outside this machine's scripts.
//
// Every message becomes an event for the receiving machine's scripts next frame:
//   ["RemoteServer", remoteID, fromPlayer, arguments]     OnServerEvent
//   ["RemoteClient", remoteID, arguments]                 OnClientEvent
//   ["RemoteInvoke", remoteID, "server" | "client", caller, call, arguments]
//   ["RemoteReply", call, ok, results | message]
//   ["DataChanged", id]                                   a Value's Changed
// The machine that runs the world (the host, or a game played alone) is the server;
// every machine with a player is a client — the host is both.

extension PlayController {
    /// The `remote.*` host calls.
    func remoteCall(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        func string(_ index: Int) -> String? { index < arguments.count ? arguments[index].asString : nil }
        func number(_ index: Int) -> Int? { index < arguments.count ? arguments[index].asDouble.map(Int.init) : nil }
        func value(_ index: Int) -> ScriptValue { index < arguments.count ? arguments[index] : .list([]) }
        let isServer = !worldFromHost
        switch name {
        case "remote.fire":
            // [remote, "server" | "client" | "all", player, arguments]
            guard let id = string(0), let target = string(1) else { return .nothing }
            let payload = value(3)
            switch target {
            case "server":
                if isServer {
                    pendingEvents.append(.list([.string("RemoteServer"), .string(id), .number(Double(playerID)), payload]))
                } else {
                    sendAction?("remote.server", [.string(id), payload])
                }
            case "client", "all":
                guard isServer else { return .nothing }
                let targets = target == "all" ? [playerID] + remotePlayers.map(\.id) : [number(2) ?? -1]
                for player in targets {
                    if player == playerID {
                        pendingEvents.append(.list([.string("RemoteClient"), .string(id), payload]))
                    } else if remotePlayers.contains(where: { $0.id == player }) {
                        forwardToPlayer?(player, "remote.client", [.string(id), payload])
                    }
                }
            default:
                break
            }
            return .nothing

        case "remote.invoke":
            // [remote, "server" | "client", player, arguments] → the call's number, which
            // its reply comes back with.
            guard let id = string(0), let side = string(1) else { return .nothing }
            remoteCalls += 1
            let call = Double(remoteCalls)
            let payload = value(3)
            if side == "server" {
                if isServer {
                    pendingEvents.append(.list([.string("RemoteInvoke"), .string(id), .string("server"),
                                                .number(Double(playerID)), .number(call), payload]))
                } else {
                    sendAction?("remote.invoke", [.string(id), .number(call), payload])
                }
            } else {
                let player = number(2) ?? -1
                if player == playerID {
                    pendingEvents.append(.list([.string("RemoteInvoke"), .string(id), .string("client"),
                                                .number(Double(playerID)), .number(call), payload]))
                } else if isServer, remotePlayers.contains(where: { $0.id == player }) {
                    invokesWaiting[Int(call)] = player
                    forwardToPlayer?(player, "remote.invoke.client", [.string(id), .number(call), payload])
                } else {
                    // Not in the game: the call fails at once.
                    pendingEvents.append(.list([.string("RemoteReply"), .number(call), .bool(false),
                                                .string("The player isn't in the game")]))
                }
            }
            return .number(call)

        case "remote.reply":
            // [caller, call, ok, results | message]: back to whoever asked.
            guard let caller = number(0), let call = number(1) else { return .nothing }
            let reply: [ScriptValue] = [.number(Double(call)), value(2), value(3)]
            if caller == playerID {
                pendingEvents.append(.list([.string("RemoteReply")] + reply))
            } else if isServer {
                forwardToPlayer?(caller, "remote.replied", reply)
            } else {
                sendAction?("remote.replied", reply)
            }
            return .nothing

        // Arriving on a joined player from the host, through `.call` (after the
        // character's number, which they don't need).
        case "remote.client":
            pendingEvents.append(.list([.string("RemoteClient"), value(1), value(2)]))
            return .nothing
        case "remote.invoke.client":
            // The host (player 0) asks this player.
            pendingEvents.append(.list([.string("RemoteInvoke"), value(1), .string("client"), .number(0),
                                        value(2), value(3)]))
            return .nothing
        case "remote.replied":
            pendingEvents.append(.list([.string("RemoteReply"), value(1), value(2), value(3)]))
            return .nothing

        case "remote.isServer":
            return .bool(isServer)

        default:
            return .nothing
        }
    }

    /// A joined player's remote message, arriving on the host.
    func remoteMessage(from player: Int, _ name: String, _ arguments: [ScriptValue]) {
        func value(_ index: Int) -> ScriptValue { index < arguments.count ? arguments[index] : .list([]) }
        switch name {
        case "remote.server":
            pendingEvents.append(.list([.string("RemoteServer"), value(0), .number(Double(player)), value(1)]))
        case "remote.invoke":
            pendingEvents.append(.list([.string("RemoteInvoke"), value(0), .string("server"), .number(Double(player)),
                                        value(1), value(2)]))
        case "remote.replied":
            if let call = arguments.first?.asDouble.map(Int.init) { invokesWaiting[call] = nil }
            pendingEvents.append(.list([.string("RemoteReply"), value(0), value(1), value(2)]))
        default:
            break
        }
    }

    /// A player left: the host's calls still waiting on them fail.
    func failInvokes(waitingOn player: Int) {
        for (call, target) in invokesWaiting where target == player {
            pendingEvents.append(.list([.string("RemoteReply"), .number(Double(call)), .bool(false),
                                        .string("The player left the game")]))
            invokesWaiting[call] = nil
        }
    }

    // MARK: - Rays and characters

    /// `character.raycast`: [origin, unit direction, reach, character tokens ("ch:<n>"),
    /// include?] → [character number, body part, distance, normal] for the nearest body
    /// part the ray meets within reach, or nothing.
    func characterRaycast(_ arguments: [ScriptValue]) -> ScriptValue {
        guard arguments.count >= 3, let (ox, oy, oz) = arguments[0].asTriple, let (dx, dy, dz) = arguments[1].asTriple,
              let reach = arguments[2].asFloat else { return .nothing }
        let listed = Set((arguments.count > 3 ? arguments[3].asList : nil)?.compactMap(\.asString)
            .compactMap { Int($0.dropFirst(3)) } ?? [])
        let include = arguments.count > 4 ? arguments[4].asBool ?? false : false
        var bodies: [(number: Int, pose: AvatarPose)] = []
        if characterGeneration > 0 {
            var own = AvatarPose(position: character.position, yaw: character.facingYaw, joints: currentJoints)
            own.dead = humanoid.isDead
            bodies.append((characterGeneration, own))
        }
        for (remote, pose) in zip(remotePlayers, remoteAvatars) {
            bodies.append((RemoteCharacter.number(player: remote.id, generation: remote.generation), pose))
        }
        let origin = Vec3(ox, oy, oz), direction = Vec3(dx, dy, dz)
        var best: (number: Int, part: String, distance: Float, normal: Vec3)?
        for body in bodies where include == listed.contains(body.number) {
            let sizes = Dictionary(AvatarPose.bodyParts.map { ($0.name, $0.size) }, uniquingKeysWith: { a, _ in a })
            for (name, matrix) in body.pose.partTransforms() {
                guard let size = sizes[name] else { continue }
                let local = Ray(origin: origin, direction: direction).transformed(by: matrix.inverse)
                guard let (enter, _) = Intersect.rayBoxInterval(local, halfExtents: size / 2), enter >= 0,
                      enter <= reach, enter < (best?.distance ?? .greatestFiniteMagnitude) else { continue }
                // The face it came in through, turned back into the world.
                let hit = local.origin + local.direction * enter
                let scaled = hit / (size / 2)
                var face = Vec3.zero
                let axis = abs(scaled.x) >= abs(scaled.y) && abs(scaled.x) >= abs(scaled.z) ? 0
                    : abs(scaled.y) >= abs(scaled.z) ? 1 : 2
                face[axis] = scaled[axis] >= 0 ? 1 : -1
                let turned = matrix * Vec4(face, 0)
                best = (body.number, name, enter, normalize(Vec3(turned.x, turned.y, turned.z)))
            }
        }
        guard let best else { return .nothing }
        return .list([.string("bp:\(best.number):\(best.part)"), .string(best.part), .number(Double(best.distance)),
                      .triple(best.normal.x, best.normal.y, best.normal.z)])
    }

    // MARK: - Values changing

    /// A script here set a value, and raised its Changed itself.
    func noteDataWritten(_ id: UUID) {
        if let object = model.dataObject(id: id) { knownDataValues[id] = object.value }
    }

    /// Changed for each Value whose value changed since the last frame without this
    /// machine's scripts setting it — on a joined player, the host's changes arriving.
    func noteDataChanges() {
        var seen: [UUID: ScriptValue] = [:]
        for object in model.dataObjects where object.className.isValue || object.className == .humanoid {
            seen[object.id] = object.value
            if let known = knownDataValues[object.id], known != object.value {
                pendingEvents.append(.list([.string("DataChanged"), .string(object.id.uuidString)]))
            }
        }
        knownDataValues = seen
    }

    /// A player left: what was theirs (their leaderstats) goes with them.
    func removeDataObjects(ofPlayer id: Int) {
        let theirs = model.dataObjects.filter { $0.parent == .player(id) }.map(\.id)
        if !theirs.isEmpty { model.removeDataObjects(Set(theirs), undoable: false) }
    }
}
