import Foundation
import simd

/// PathfindingService: the grid's paths round a wall (evenly spaced, each stretch
/// walkable), none into a closed box, up a step walking and onto a platform jumping (or
/// not, or not that high), through a gap only an agent that fits, round a costly
/// material, a new wall found blocking an old path, and a start inside the agent's own
/// body; the Luau API (CreatePath, ComputeAsync, Status, GetWaypoints, Blocked,
/// CheckOcclusionAsync, FindPathAsync, errors, completion); the README's example walking
/// a character round a wall with Humanoid:MoveTo; and Nightfall's zombies finding their
/// way round walls to a player, and to a joined player. Then water (swum at its surface
/// when deep, waded when not, in water parts and the Terrain, kept out of by its Cost),
/// trusses (climbed only by an agent that can), gaps (jumped across, not too wide); the
/// Luau side of those; and a Rig following a path across a pond, over a gap and up a
/// truss, alone and in a joined player's game.
enum PathfindingSelfTest {
    static func run(check: Checker) {
        testGrid(check)
        testLuau(check)
        testReadme(check)
        testZombies(check)
        testTogether(check)
        testWater(check)
        testClimbing(check)
        testGaps(check)
        testCourse(check)
        testCourseTogether(check)
    }

    private static let frame: Float = 1.0 / 60

    private static func step(_ session: PlayController, seconds: Float) {
        var elapsed: Float = 0
        while elapsed < seconds {
            session.step(dt: frame)
            elapsed += frame
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    private static func block(_ name: String, _ position: Vec3, _ size: Vec3, _ material: PartMaterial = .plastic) -> Part {
        var part = Part()
        part.name = name
        part.position = position
        part.size = size
        part.material = material
        part.anchored = true
        return part
    }

    private static func flat(_ a: Vec3, _ b: Vec3) -> Float { simd_distance(SIMD2(a.x, a.z), SIMD2(b.x, b.z)) }

    // MARK: - The grid

    private static func testGrid(_ check: Checker) {
        print("\nPathfinding: the grid")
        let grid = NavigationGrid()
        let wall = block("Wall", Vec3(0, 5, -15), Vec3(30, 10, 2))
        grid.update([wall])
        let agent = NavigationGrid.Agent(radius: 1.5)
        let start = Vec3(0, 3, 0), goal = Vec3(0, 3, -30)
        let (status, points) = grid.path(from: start, to: goal, agent: agent)
        let positions = points.map(\.position)
        let length = zip(positions, positions.dropFirst()).reduce(0) { $0 + flat($1.0, $1.1) }
        check("round a wall: from the start to the goal", status == .success && positions.count > 3
              && flat(positions.first!, start) < 0.1 && flat(positions.last!, goal) < 0.1, "\(status) \(positions)")
        check("…round its end, never through it", positions.contains { abs($0.x) > 15 }
              && !positions.contains { abs($0.x) < 15 + 1.5 && abs($0.z + 15) < 1 + 1.5 } && length > 30, "\(positions)")
        check("…waypoints evenly spaced, each stretch walkable",
              zip(positions, positions.dropFirst()).allSatisfy { flat($0.0, $0.1) <= 6.5 && grid.straight(from: $0.0, to: $0.1, agent) },
              "\(zip(positions, positions.dropFirst()).map { flat($0.0, $0.1) })")
        check("…on the ground", positions.allSatisfy { abs($0.y) < 0.01 } && points.allSatisfy { $0.action == .walk })

        // A goal in a closed box.
        let box = [block("N", Vec3(0, 5, -26), Vec3(12, 10, 2)), block("S", Vec3(0, 5, -34), Vec3(12, 10, 2)),
                   block("E", Vec3(5, 5, -30), Vec3(2, 10, 10)), block("W", Vec3(-5, 5, -30), Vec3(2, 10, 10))]
        grid.update(box)
        check("no way into a closed box", grid.path(from: start, to: goal, agent: agent).0 == .noPath)

        // Up: a step, a platform, too high.
        func platform(_ height: Float, jump: Bool = true) -> (NavigationGrid.Status, [NavigationGrid.Waypoint]) {
            grid.update([block("Platform", Vec3(0, height / 2, -20), Vec3(10, height, 10))])
            return grid.path(from: start, to: Vec3(0, height + 3, -20), agent: NavigationGrid.Agent(radius: 1.5, canJump: jump))
        }
        let low = platform(1.5)
        check("a step walked up", low.0 == .success && low.1.allSatisfy { $0.action == .walk }
              && abs(low.1.last!.position.y - 1.5) < 0.01, "\(low)")
        let high = platform(4)
        check("a platform jumped up to, the jump on the waypoint it lands on", high.0 == .success
              && high.1.contains { $0.action == .jump && abs($0.position.y - 4) < 0.01 }, "\(high)")
        check("…none for an agent that can't jump", platform(4, jump: false).0 == .noPath)
        check("…and none too high to jump", platform(9).0 == .noPath)

        // A gap only a small agent fits.
        grid.update([block("Left", Vec3(-51.5, 5, -15), Vec3(97, 10, 2)), block("Right", Vec3(51.5, 5, -15), Vec3(97, 10, 2))])
        let small = grid.path(from: start, to: goal, agent: NavigationGrid.Agent(radius: 1))
        check("through a gap an agent fits", small.0 == .success
              && small.1.allSatisfy { abs($0.position.z + 15) > 2 || abs($0.position.x) < 3 }, "\(small)")
        check("…but not a bigger one", grid.path(from: start, to: goal, agent: NavigationGrid.Agent(radius: 3)).0 == .noPath)

        // Costs.
        let strip = block("Strip", Vec3(0, 0.1, -15), Vec3(20, 0.2, 4), .neon)
        grid.update([strip])
        let cheap = grid.path(from: start, to: goal, agent: agent)
        var costly = agent
        costly.costs = ["Neon": .infinity]
        let dear = grid.path(from: start, to: goal, agent: costly)
        check("straight over a strip of Neon", cheap.0 == .success && cheap.1.count <= 10
              && !cheap.1.contains { abs($0.position.x) > 3 }, "\(cheap)")
        check("…round it when Neon costs too much", dear.0 == .success && dear.1.contains { abs($0.position.x) > 10 }
              && !dear.1.contains { abs($0.position.x) < 10 && abs($0.position.z + 15) < 2 }, "\(dear)")

        // A wall put down on a path already found.
        grid.update([])
        let open = grid.path(from: start, to: goal, agent: agent)
        check("an open path is clear", open.0 == .success && grid.firstBlocked(open.1, from: 1, agent: agent) == -1)
        grid.update([wall])
        let blocked = grid.firstBlocked(open.1, from: 1, agent: agent)
        check("…a wall put down on it blocks it from where it meets the wall", blocked > 1 && blocked <= open.1.count
              && open.1[blocked - 1].position.z <= -12, "\(blocked)")

        // The agent's own body round the start.
        let body = block("Torso", Vec3(0, 3, 0), Vec3(2, 2, 1))
        grid.update([body, wall])
        check("a start inside the agent's own body still finds the way", grid.path(from: start, to: goal, agent: agent).0 == .success
              && grid.ignored(from: start) == [body.id])
    }

    // MARK: - Luau

    static let script = """
    local PathfindingService = game:GetService("PathfindingService")
    local path = PathfindingService:CreatePath({ AgentRadius = 1.5, AgentHeight = 5, AgentCanJump = true })
    print("path", path.ClassName, path.Status == Enum.PathStatus.NoPath, #path:GetWaypoints())
    path:ComputeAsync(Vector3.new(0, 3, 0), Vector3.new(0, 3, -30))
    local waypoints = path:GetWaypoints()
    print("computed", path.Status == Enum.PathStatus.Success, #waypoints > 3, typeof(waypoints[1]),
    \twaypoints[1].Action == Enum.PathWaypointAction.Walk, waypoints[#waypoints].Position.Z)
    local around = false
    for _, waypoint in waypoints do
    \tif math.abs(waypoint.Position.X) > 15 then
    \t\taround = true
    \tend
    end
    print("around", around, path:CheckOcclusionAsync(1))
    local blockedAt = nil
    path.Blocked:Connect(function(index)
    \tblockedAt = index
    end)
    local crate = Instance.new("Part")
    crate.Name = "Crate"
    crate.Anchored = true
    crate.Size = Vector3.new(10, 8, 10)
    crate.Position = waypoints[math.floor(#waypoints / 2)].Position + Vector3.new(0, 4, 0)
    crate.Parent = workspace
    task.wait(1.2)
    print("blocked", blockedAt ~= nil and blockedAt > 1, path:CheckOcclusionAsync(1) > 1)
    local old = PathfindingService:FindPathAsync(Vector3.new(0, 3, 0), Vector3.new(10, 3, 0))
    print("old way", old.Status == Enum.PathStatus.Success, #old:GetWaypoints() >= 2)
    local ok, message = pcall(function()
    \tpath:ComputeAsync(1, 2)
    end)
    print("bad", ok, message)
    local waypoint = PathWaypoint.new(Vector3.new(1, 2, 3), Enum.PathWaypointAction.Jump)
    print("made", typeof(waypoint), waypoint.Position.Y, waypoint.Action == Enum.PathWaypointAction.Jump, waypoint.Label)
    """

    private static func testLuau(_ check: Checker) {
        print("\nPathfinding: from Luau")
        let model = SceneModel()
        model.parts = [block("Wall", Vec3(0, 5, -15), Vec3(30, 10, 2))]
        var source = ScriptObject.blank(language: .luau)
        source.source = script
        model.scripts = [source]
        let session = PlayController(model: model, console: ScriptConsole(), withPlayer: false)
        session.start()
        step(session, seconds: 1.6)
        func line(_ prefix: String) -> String {
            session.console.lines.first { $0.text.hasPrefix(prefix) }?.text ?? "(nothing)"
        }
        check("CreatePath: a Path, not yet computed", line("path") == "path Path true 0", line("path"))
        check("ComputeAsync: Success, PathWaypoints to walk, ending at the goal",
              line("computed") == "computed true true PathWaypoint true -30", line("computed"))
        check("…round the wall, clear", line("around") == "around true -1", line("around"))
        check("Blocked fires when something comes to stand in the way, and CheckOcclusionAsync says where",
              line("blocked") == "blocked true true", line("blocked"))
        check("FindPathAsync, the old way", line("old way") == "old way true true")
        check("a start that isn't a Vector3 is refused", line("bad").hasPrefix("bad false")
              && line("bad").hasSuffix("ComputeAsync expects two Vector3s"), line("bad"))
        check("PathWaypoint.new", line("made") == "made PathWaypoint 2 true ", line("made"))
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("no other errors", errors.isEmpty, "\(errors)")
        session.stop()

        func labels(_ source: String) -> [String] {
            LuauCompletion.items(in: source, caret: (source as NSString).length).map { String($0.label.prefix { $0 != "(" }) }
        }
        let service = "local PathfindingService = game:GetService(\"PathfindingService\")\n"
        check("completion: the service, its methods, and a Path's",
              labels("game:GetService(\"").contains("PathfindingService")
              && labels(service + "PathfindingService:").contains("CreatePath")
              && Set(["ComputeAsync", "GetWaypoints", "CheckOcclusionAsync"])
                .isSubset(of: Set(labels(service + "local path = PathfindingService:CreatePath()\npath:"))),
              "\(labels(service + "local path = PathfindingService:CreatePath()\npath:"))")
    }

    // MARK: - The README

    private static func testReadme(_ check: Checker) {
        print("\nPathfinding: the README's example")
        guard let readme = try? String(contentsOfFile: "README.md", encoding: .utf8),
              let start = readme.range(of: "### Finding the way: PathfindingService"),
              let block = readme[start.upperBound...].components(separatedBy: "```lua\n").dropFirst().first?
                .components(separatedBy: "```").first else {
            print("  (README.md not found from here; skipped)")
            return
        }
        let model = SceneModel()
        model.scripts = []
        model.parts = [self.block("Baseplate", Vec3(0, -0.5, 0), Vec3(200, 1, 200)),
                       self.block("Wall", Vec3(0, 5, 0), Vec3(30, 10, 2))]
        var flag = self.block("Flag", Vec3(0, 2, -20), Vec3(1, 4, 1))
        flag.canCollide = false
        model.parts.append(flag)
        var walker = ScriptObject.blank(language: .luau)
        walker.host = .starterCharacter
        walker.source = String(block)
        model.scripts.append(walker)
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        var closest = Float.infinity
        for _ in 0..<24 {
            step(session, seconds: 0.5)
            closest = min(closest, flat(session.character.position, flag.position))
        }
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("it walks the character round the wall to the flag", closest < 3 && errors.isEmpty,
              "\(closest) \(session.character.position) \(errors)")
        session.stop()
    }

    // MARK: - Nightfall's zombies

    /// A U of walls round `centre`, open to the north (−Z), 10 tall.
    private static func pen(round centre: Vec3) -> [Part] {
        [block("PenBack", centre + Vec3(0, 5, 9), Vec3(20, 10, 2)),
         block("PenLeft", centre + Vec3(-9, 5, 0), Vec3(2, 10, 18)),
         block("PenRight", centre + Vec3(9, 5, 0), Vec3(2, 10, 18))]
    }

    private static func testZombies(_ check: Checker) {
        print("\nPathfinding: Nightfall's zombies")
        let model = SceneModel()
        NightfallSelfTest.quick(model)
        // In the open south-east of the camp, a pen with its way in on the far side.
        let centre = Vec3(40, Nightfall.groundTop, 50)
        model.parts += pen(round: centre)
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        step(session, seconds: 1.8)
        session.character.position = centre + Vec3(0, 0.1, 0)
        session.character.velocity = .zero
        guard let zombie = NightfallSelfTest.zombies(model).first else {
            check("night comes, with zombies", false)
            session.stop()
            return
        }
        // Behind the back wall, where walking straight at the player meets it.
        let pivot = model.pivot(of: zombie.id)!
        model.movePivot(of: zombie.id, to: Pose(position: Vec3(centre.x, pivot.position.y, centre.z + 16),
                                                orientation: pivot.orientation))
        for other in NightfallSelfTest.zombies(model).dropFirst() {
            model.movePivot(of: other.id, to: Pose(position: Vec3(-150, pivot.position.y, -150), orientation: pivot.orientation))
        }
        var nearest = Float.infinity
        var health = session.humanoid.health
        for _ in 0..<24 {
            session.character.position = centre + Vec3(0, 0.1, 0)
            session.character.velocity = .zero
            step(session, seconds: 0.5)
            if let now = model.pivot(of: zombie.id)?.position { nearest = min(nearest, flat(now, centre)) }
            health = min(health, session.humanoid.health)
        }
        check("a zombie behind the wall finds its way round, in through the gap, and bites",
              nearest < 4 && health < 100, "\(nearest) \(health)")
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("…with no errors", errors.isEmpty, "\(errors)")
        session.stop()
        DataStoreFiles.shared.clear(place: Nightfall.placeID)
    }

    private static func testTogether(_ check: Checker) {
        print("\nPathfinding: a host and a joined player")
        let quick = SceneModel()
        NightfallSelfTest.quick(quick)
        let centre = Vec3(40, Nightfall.groundTop, 50)
        quick.parts += pen(round: centre)
        let state = quick.state
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            let kept = model.scripts
            model.state = state
            model.scripts += kept
        }), let host = hosting.player, let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 2)
        guard let zombie = NightfallSelfTest.zombies(hosting.model).first,
              let pivot = hosting.model.pivot(of: zombie.id) else {
            check("night comes, with zombies", false)
            joining.leaveGame()
            hosting.leaveGame()
            return
        }
        hosting.model.movePivot(of: zombie.id, to: Pose(position: Vec3(centre.x, pivot.position.y, centre.z + 16),
                                                        orientation: pivot.orientation))
        for other in NightfallSelfTest.zombies(hosting.model).dropFirst() {
            hosting.model.movePivot(of: other.id, to: Pose(position: Vec3(-150, pivot.position.y, -150),
                                                           orientation: pivot.orientation))
        }
        // The host far away; the joined player in the pen.
        host.character.position = Vec3(-120, 3, -120)
        var nearest = Float.infinity
        var health = sam.humanoid.health
        for _ in 0..<24 {
            sam.character.position = centre + Vec3(0, 0.1, 0)
            sam.character.velocity = .zero
            host.character.position = Vec3(-120, 3, -120)
            LANSelfTest.run([hosting, joining], seconds: 0.5)
            if let seen = joining.model.pivot(of: zombie.id)?.position { nearest = min(nearest, flat(seen, centre)) }
            health = min(health, sam.humanoid.health)
        }
        check("the host's zombie finds its way round to the joined player, who sees it come and is bitten",
              nearest < 4 && health < 100, "\(nearest) \(health)")
        let errors = (host.console.lines + sam.console.lines).filter { $0.kind == .error }.map(\.text)
        check("…with no errors on either", errors.isEmpty, "\(errors)")
        joining.leaveGame()
        hosting.leaveGame()
        DataStoreFiles.shared.clear(place: Nightfall.placeID)
    }

    // MARK: - Water

    private static func testWater(_ check: Checker) {
        print("\nPathfinding: water")
        // Land either side of a pond 6 deep, nothing round it (no ground).
        func pond(depth: Float) -> NavigationGrid {
            let grid = NavigationGrid()
            grid.ground = false
            var water = block("Pond", Vec3(0, 6 - depth / 2, -15), Vec3(24, depth, 10))
            water.material = .water
            water.canCollide = false
            grid.update([block("Near", Vec3(0, 3, 0), Vec3(24, 6, 20)), block("Far", Vec3(0, 3, -30), Vec3(24, 6, 20)),
                         block("Bed", Vec3(0, 5.5 - depth, -15), Vec3(24, 1, 10)), water])
            return grid
        }
        let deep = pond(depth: 6)
        // Points a root part's height above the floor, as a character's are.
        let start = Vec3(0, 9, 0), goal = Vec3(0, 9, -30)
        let (status, points) = deep.path(from: start, to: goal, agent: NavigationGrid.Agent(radius: 1.5))
        let wet = points.filter { $0.position.z < -10.5 && $0.position.z > -19.5 }
        check("deep water is swum across, at its surface, labelled Water", status == .success && !wet.isEmpty
              && wet.allSatisfy { $0.label == "Water" && abs($0.position.y - 6) < 0.05 }
              && points.filter { $0.label == "Water" }.allSatisfy { $0.position.z < -9 && $0.position.z > -21 },
              "\(status) \(points.map { ($0.position, $0.label) })")
        let out = points.first { $0.position.z < -19.5 }
        check("…climbing out onto the far bank with a jump", out.map { $0.action == .jump && $0.label == "" } == true,
              "\(String(describing: out))")
        let shallow = pond(depth: 2).path(from: start, to: goal, agent: NavigationGrid.Agent(radius: 1.5))
        let waded = shallow.1.filter { $0.position.z < -10.5 && $0.position.z > -19.5 }
        check("…shallow water is waded (not swum), labelled Water", shallow.0 == .success && !waded.isEmpty
              && waded.allSatisfy { $0.label == "Water" && $0.position.y <= 6.01 }
              && !shallow.1.contains { $0.action == .jump }, "\(shallow)")
        var keepOut = NavigationGrid.Agent(radius: 1.5)
        keepOut.costs["Water"] = .infinity
        check("…and a Water cost of infinity keeps out of it", deep.path(from: start, to: goal, agent: keepOut).0 == .noPath)

        // The Terrain's: a lake between rock banks.
        let model = SceneModel()
        model.parts = []
        model.terrain.fillRegion(low: Vec3(-32, -16, -44), high: Vec3(32, 8, 12), material: .rock)
        model.terrain.fillRegion(low: Vec3(-32, -8, -24), high: Vec3(32, 8, -8), material: .air)
        model.terrain.fillRegion(low: Vec3(-32, -8, -24), high: Vec3(32, 4, -8), material: .water)
        let lake = NavigationGrid()
        lake.ground = false
        lake.terrainWater = { [terrain = model.terrain] in terrain.waterSurface(at: $0) }
        lake.update(model.terrainParts)
        let across = lake.path(from: Vec3(0, 11, 4), to: Vec3(0, 11, -36), agent: NavigationGrid.Agent(radius: 1.5))
        let swum = across.1.filter { $0.label == "Water" }
        check("…the Terrain's water too", across.0 == .success && !swum.isEmpty && swum.allSatisfy { abs($0.position.y - 4) < 0.3 },
              "\(across.0) \(across.1.map { ($0.position, $0.label) })")
    }

    // MARK: - Trusses

    private static func testClimbing(_ check: Checker) {
        print("\nPathfinding: climbing")
        let grid = NavigationGrid()
        var truss = block("Truss", Vec3(0, 5, -9), Vec3(2, 10, 2))
        truss.shape = .truss
        grid.update([block("Loft", Vec3(0, 5, -15), Vec3(10, 10, 10)), truss])
        let start = Vec3(0, 0, 0), goal = Vec3(0, 10, -15)
        let walker = grid.path(from: start, to: goal, agent: NavigationGrid.Agent(radius: 1.5))
        check("a loft too high to jump to is out of reach, unless climbing", walker.0 == .noPath, "\(walker)")
        var climber = NavigationGrid.Agent(radius: 1.5)
        climber.canClimb = true
        let (status, points) = grid.path(from: start, to: goal, agent: climber)
        let top = points.first { $0.label == "Climb" }
        check("…an agent that can climbs the truss, the top of the climb labelled Climb", status == .success
              && top.map { abs($0.position.y - 10) < 0.05 && $0.action == .walk } == true
              && points.filter { $0.label == "Climb" }.count == 1 && abs(points.last!.position.y - 10) < 0.05,
              "\(status) \(points.map { ($0.position, $0.label) })")
        check("…and the climbed path isn't blocked by its own truss", grid.firstBlocked(points, from: 1, agent: climber) == -1)
    }

    // MARK: - Gaps

    private static func testGaps(_ check: Checker) {
        print("\nPathfinding: gaps")
        func across(_ gap: Float, jump: Bool = true) -> (NavigationGrid.Status, [NavigationGrid.Waypoint]) {
            let grid = NavigationGrid()
            grid.ground = false
            grid.update([block("Near", Vec3(0, 2.5, 0), Vec3(20, 5, 20)),
                         block("Far", Vec3(0, 2.5, -20 - gap), Vec3(20, 5, 20))])
            return grid.path(from: Vec3(0, 8, 5), to: Vec3(0, 8, -25 - gap), agent: NavigationGrid.Agent(radius: 1.5, canJump: jump))
        }
        let small = across(5)
        let landing = small.1.first { $0.action == .jump }
        check("a gap is jumped across, the jump on the waypoint it lands on", small.0 == .success
              && landing.map { $0.position.z <= -15 && abs($0.position.y - 5) < 0.05 } == true
              && small.1.filter { $0.action == .jump }.count == 1, "\(small)")
        check("…not by an agent that can't jump", across(5, jump: false).0 == .noPath)
        check("…and not one too wide", across(12).0 == .noPath)
    }

    // MARK: - A Rig following a path

    /// Near land, a pond to swim, a gap over a drop to jump, far land and a loft on it up a
    /// truss: 12 above the ground, so there's no way round.
    static func course(at offset: Vec3 = .zero) -> [Part] {
        var water = block("Pond", offset + Vec3(0, 6, -10), Vec3(30, 12, 10))
        water.material = .water
        water.canCollide = false
        var truss = block("Truss", offset + Vec3(0, 17, -39), Vec3(2, 10, 2))
        truss.shape = .truss
        var goal = block("Goal", offset + Vec3(0, 23, -45), Vec3(1, 2, 1))
        goal.canCollide = false
        return [block("Near", offset + Vec3(0, 6, 5), Vec3(30, 12, 20)), water,
                block("Middle", offset + Vec3(0, 6, -20), Vec3(30, 12, 10)),
                block("Far", offset + Vec3(0, 6, -40), Vec3(30, 12, 20)),
                block("Loft", offset + Vec3(0, 17, -45), Vec3(10, 10, 10)), truss, goal]
    }

    static let follower = """
    local PathfindingService = game:GetService("PathfindingService")
    local rig = workspace:WaitForChild("Rig")
    local humanoid = rig:WaitForChild("Humanoid")
    local root = rig:WaitForChild("HumanoidRootPart")
    local goal = workspace:WaitForChild("Goal")
    task.wait(0.5)
    local path = PathfindingService:CreatePath({ AgentRadius = 1.5, AgentCanClimb = true })
    path:ComputeAsync(root.Position, goal.Position)
    local labels = {}
    for _, waypoint in path:GetWaypoints() do
    \tif waypoint.Label ~= "" and labels[#labels] ~= waypoint.Label then
    \t\ttable.insert(labels, waypoint.Label)
    \tend
    end
    print("path", path.Status.Name, table.concat(labels, ","))
    for _, waypoint in path:GetWaypoints() do
    \tif waypoint.Action == Enum.PathWaypointAction.Jump then
    \t\thumanoid.Jump = true
    \tend
    \thumanoid:MoveTo(waypoint.Position)
    \thumanoid.MoveToFinished:Wait()
    end
    print("arrived", (root.Position - goal.Position).Magnitude < 5)
    """

    private static func testCourse(_ check: Checker) {
        print("\nPathfinding: a Rig across a pond, over a gap and up a truss")
        let model = SceneModel()
        model.scripts = []
        model.parts = [block("Baseplate", Vec3(0, -0.5, 0), Vec3(300, 1, 300))] + course()
        model.addRig(at: Vec3(0, 12, 10))
        var script = ScriptObject.blank(language: .luau)
        script.source = follower
        model.scripts = [script]
        let session = PlayController(model: model, console: ScriptConsole(), withPlayer: false)
        session.start()
        var swam = false, climbed = false
        for _ in 0..<(40 * 2) {
            step(session, seconds: 0.5)
            let at = model.parts.first { $0.name == "HumanoidRootPart" }?.position ?? .zero
            if at.z < -6 && at.z > -14 { swam = true }
            if at.y > 16 && at.z > -41 { climbed = true }
            if session.console.lines.contains(where: { $0.text.hasPrefix("arrived") }) { break }
        }
        let said = session.console.lines.filter { $0.kind == .output }.map(\.text)
        check("the path swims, jumps and climbs", said.contains("path Success Water,Climb"), "\(said)")
        check("…and the Rig follows it: through the water, up the truss, to the goal",
              said.contains("arrived true") && swam && climbed, "\(said) \(swam) \(climbed)")
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("…with no errors", errors.isEmpty, "\(errors)")
        session.stop()
    }

    private static func testCourseTogether(_ check: Checker) {
        print("\nPathfinding: the course in a joined player's game")
        let offset = Vec3(80, 0, 0)
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            model.parts = [block("Baseplate", Vec3(0, -0.5, 0), Vec3(400, 1, 400))] + course(at: offset)
            model.addRig(at: offset + Vec3(0, 12, 10))
            var script = ScriptObject.blank(language: .luau)
            script.source = follower
            model.scripts.append(script)
        }), let host = hosting.player, let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        var arrived = false
        for _ in 0..<40 {
            LANSelfTest.run([hosting, joining], seconds: 1)
            if host.console.lines.contains(where: { $0.text == "arrived true" }) {
                arrived = true
                break
            }
        }
        LANSelfTest.run([hosting, joining], seconds: 0.5)
        let seen = joining.model.parts.first { $0.name == "HumanoidRootPart" }?.position ?? .zero
        check("the host's Rig crosses the course, and the joined player sees it reach the goal",
              arrived && simd_distance(seen, offset + Vec3(0, 23, -45)) < 5, "\(arrived) \(seen)")
        let errors = (host.console.lines + sam.console.lines).filter { $0.kind == .error }.map(\.text)
        check("…with no errors on either", errors.isEmpty, "\(errors)")
        joining.leaveGame()
        hosting.leaveGame()
    }
}
