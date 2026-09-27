import Foundation

// The script runtime's host calls for `path.*`: PathfindingService's searches, through
// the runtime's NavigationGrid (Pathfinding.swift). The grid catches up with the parts
// once a frame, however many paths are asked for in it.
//
// An agent comes as [radius, height, canJump, spacing, [[material, cost], …]]; waypoints
// go back as [x, y, z, "Walk" | "Jump"], with the ids of the parts the search left out
// (the agent's own body), which a check of the path later leaves out too.

extension ScriptRuntime {
    func pathCall(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        switch name {
        case "path.compute":
            // start, finish, agent
            let agent = arguments.count > 2 ? Self.agent(arguments[2]) : NavigationGrid.Agent()
            guard arguments.count >= 2, let (sx, sy, sz) = arguments[0].asTriple,
                  let (fx, fy, fz) = arguments[1].asTriple else { return .list([.string("NoPath"), .list([])]) }
            syncNavigation()
            let start = Vec3(sx, sy, sz)
            let (status, waypoints) = navigation.path(from: start, to: Vec3(fx, fy, fz), agent: agent)
            let left = navigation.ignored(from: start).map { ScriptValue.string($0.uuidString) }
            return .list([.string(status.rawValue), .list(waypoints.map(Self.value)), .list(left)])

        case "path.check":
            // waypoints, agent, from, left out: the first waypoint whose way is blocked now, or -1.
            guard arguments.count >= 2, let list = arguments[0].asList else { return .number(-1) }
            let agent = Self.agent(arguments[1])
            syncNavigation()
            let waypoints = list.compactMap(Self.waypoint)
            let from = arguments.count > 2 ? Int(arguments[2].asFloat ?? 1) : 1
            let left = Set((arguments.count > 3 ? arguments[3].asList : nil)?.compactMap { $0.asString.flatMap(UUID.init) } ?? [])
            return .number(Double(navigation.firstBlocked(waypoints, from: from, agent: agent, ignoring: left)))

        default:
            return .nothing
        }
    }

    private func syncNavigation() {
        let now = clock()
        guard now != navigationSyncedAt else { return }
        navigationSyncedAt = now
        // The ground at 0 is solid in play (CharacterController.solidBaseplate), always
        // but for tests that take it away.
        navigation.ground = (player as? PlayController)?.character.solidBaseplate ?? true
        navigation.update(model.parts + model.terrainParts)
    }

    private static func agent(_ value: ScriptValue) -> NavigationGrid.Agent {
        var agent = NavigationGrid.Agent()
        guard let list = value.asList else { return agent }
        if list.count > 0, let radius = list[0].asFloat, radius.isFinite { agent.radius = min(max(radius, 0.5), 20) }
        if list.count > 1, let height = list[1].asFloat, height.isFinite { agent.height = min(max(height, 1), 50) }
        if list.count > 2, let jump = list[2].asBool { agent.canJump = jump }
        if list.count > 3, let spacing = list[3].asFloat { agent.spacing = spacing }
        if list.count > 4, let costs = list[4].asList {
            for entry in costs {
                if let pair = entry.asList, pair.count == 2, let material = pair[0].asString, let cost = pair[1].asFloat {
                    agent.costs[material] = max(cost, 0.01)
                }
            }
        }
        return agent
    }

    private static func value(_ waypoint: NavigationGrid.Waypoint) -> ScriptValue {
        .list([.number(Double(waypoint.position.x)), .number(Double(waypoint.position.y)),
               .number(Double(waypoint.position.z)), .string(waypoint.action.rawValue)])
    }

    private static func waypoint(_ value: ScriptValue) -> NavigationGrid.Waypoint? {
        guard let list = value.asList, list.count >= 4, let x = list[0].asFloat, let y = list[1].asFloat,
              let z = list[2].asFloat else { return nil }
        return NavigationGrid.Waypoint(position: Vec3(x, y, z),
                                       action: NavigationGrid.Action(rawValue: list[3].asString ?? "") ?? .walk)
    }
}
