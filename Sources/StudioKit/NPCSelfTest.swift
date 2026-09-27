import Foundation
import simd

/// NPCs: a Rig (Insert › Rig) walked by its Humanoid — MoveTo a point at its WalkSpeed,
/// facing the way it goes, legs swinging, MoveToFinished when there (or after eight
/// seconds, stopped by a wall); Move in a direction; Jump; falling off a ledge and
/// stepping up a kerb; a script moving it; round a wall with a PathfindingService path;
/// health, TakeDamage, HealthChanged and Died, falling apart; Instance.new("Humanoid") in
/// any Model; the player bumping into one; saved and reopened; and a host's NPC walking
/// and dying in a joined player's game, their scripts hearing it die.
enum NPCSelfTest {
    static func run(check: Checker) {
        testRig(check)
        testWalking(check)
        testObstacles(check)
        testPathfinding(check)
        testHealth(check)
        testMadeByScript(check)
        testPostie(check)
        testTogether(check)
    }

    private static let frame: Float = 1.0 / 60

    private static func step(_ session: PlayController, seconds: Float, each: (() -> Void)? = nil) {
        var elapsed: Float = 0
        while elapsed < seconds {
            each?()
            session.step(dt: frame)
            elapsed += frame
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    private static func said(_ session: PlayController, _ kind: ScriptConsole.Kind = .output) -> [String] {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        return session.console.lines.filter { $0.kind == kind }.map(\.text)
    }

    private static func line(_ session: PlayController, _ prefix: String) -> String {
        said(session).last { $0.hasPrefix(prefix) } ?? "(nothing)"
    }

    private static func flat(_ a: Vec3, _ b: Vec3) -> Float { simd_distance(SIMD2(a.x, a.z), SIMD2(b.x, b.z)) }

    /// A place with a baseplate, a Rig standing at `feet`, and these scripts.
    private static func place(rigAt feet: Vec3 = Vec3(0, 0, 0), parts extra: [Part] = [], scripts: [String] = [])
        -> (SceneModel, UUID) {
        let model = SceneModel()
        model.parts = []
        model.groups = []
        model.scripts = model.scripts.filter { $0.host == .starterGui || $0.isModule }
        var base = Part()
        base.name = "Baseplate"
        base.position = Vec3(0, -0.5, 0)
        base.size = Vec3(300, 1, 300)
        base.anchored = true
        model.parts = [base] + extra
        let rig = model.addRig(at: feet)
        for source in scripts {
            var script = ScriptObject.blank(language: .luau)
            script.source = source
            model.scripts.append(script)
        }
        return (model, rig)
    }

    private static func root(_ model: SceneModel, _ rig: UUID) -> Part? {
        model.partIDs(inSubtree: rig).compactMap(model.part(id:)).first { $0.name == "HumanoidRootPart" }
    }

    private static func limb(_ model: SceneModel, _ rig: UUID, _ name: String) -> Part? {
        model.partIDs(inSubtree: rig).compactMap(model.part(id:)).first { $0.name == name }
    }

    // MARK: - The rig

    private static func testRig(_ check: Checker) {
        print("\nNPCs: a Rig")
        let model = SceneModel()
        let undo = model.undoCount
        let rig = model.addRig(at: Vec3(4, 0, -6))
        let names = Set(model.partIDs(inSubtree: rig).compactMap { model.part(id: $0)?.name })
        let humanoid = model.dataObjects.first { $0.className == .humanoid && $0.parent == .node(rig) }
        check("Insert Rig: a Model of head, torso, arms, legs and a HumanoidRootPart, with a Humanoid",
              names == ["HumanoidRootPart", "Torso", "Head", "Left Arm", "Right Arm", "Left Leg", "Right Leg"]
              && humanoid?.health == 100 && humanoid?.walkSpeed == 16 && model.group(id: rig)?.primaryPartID != nil
              && model.undoCount == undo + 1 && model.selection == [rig])
        let box = model.boundingBox(of: model.partIDs(inSubtree: rig))
        check("…standing on the spot", box.map { abs($0.center.y - $0.size.y / 2) < 0.01 } == true)
        let reopened = SceneModel()
        if let data = try? model.encodeScene() { try? reopened.loadScene(from: data) }
        check("…saved and reopened, Humanoid and all",
              reopened.dataObjects.first { $0.className == .humanoid }?.humanoidNumbers == DataObject.humanoidDefaults)
    }

    // MARK: - Walking

    private static func testWalking(_ check: Checker) {
        print("\nNPCs: walking")
        let (model, rig) = place(scripts: ["""
        local humanoid = workspace.Rig.Humanoid
        humanoid.MoveToFinished:Connect(function(reached)
        \tprint("finished", reached)
        end)
        task.wait(0.2)
        humanoid:MoveTo(Vector3.new(0, 0, -24))
        task.wait(0.5)
        print("walking", humanoid.MoveDirection.Z < -0.9, humanoid.WalkToPoint.Z, humanoid:GetState().Name)
        """])
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        let start = root(model, rig)!.position
        var swung: Float = 0
        step(session, seconds: 1.0) {
            if let leg = limb(model, rig, "Left Leg"), let root = root(model, rig) {
                swung = max(swung, abs(simd_dot(leg.orientation.act(Vec3(0, 1, 0)), root.orientation.act(Vec3(0, 0, 1)))))
            }
        }
        let afterSecond = root(model, rig)!.position
        check("MoveTo: it walks there at its WalkSpeed", abs(start.z - afterSecond.z - 16 * 0.8) < 3,
              "\(start) → \(afterSecond)")
        check("…facing the way it goes, legs swinging", simd_dot(root(model, rig)!.orientation.act(Vec3(0, 0, -1)), Vec3(0, 0, -1)) > 0.95
              && swung > 0.2, "\(swung)")
        check("…and scripts see it going", line(session, "walking") == "walking true -24 Running", line(session, "walking"))
        step(session, seconds: 1.5)
        check("MoveToFinished: there, and it stops", line(session, "finished") == "finished true"
              && flat(root(model, rig)!.position, Vec3(0, 0, -24)) <= NPCSystem.arrival + 0.3,
              "\(line(session, "finished")) \(root(model, rig)!.position)")
        check("…standing on the ground", abs(root(model, rig)!.position.y - 3) < 0.1, "\(root(model, rig)!.position)")
        check("no errors", said(session, .error).isEmpty, "\(said(session, .error))")
        session.stop()
    }

    // MARK: - Obstacles

    private static func testObstacles(_ check: Checker) {
        print("\nNPCs: walls, kerbs, ledges and jumps")
        var wall = Part()
        wall.name = "Wall"
        wall.position = Vec3(0, 5, -10)
        wall.size = Vec3(40, 10, 2)
        wall.anchored = true
        var kerb = Part()
        kerb.name = "Kerb"
        kerb.position = Vec3(20, 0.5, 0)
        kerb.size = Vec3(10, 1, 10)
        kerb.anchored = true
        var ledge = Part()
        ledge.name = "Ledge"
        ledge.position = Vec3(-30, 4, 0)
        ledge.size = Vec3(10, 8, 10)
        ledge.anchored = true
        let (model, rig) = place(parts: [wall, kerb, ledge], scripts: ["""
        local humanoid = workspace.Rig.Humanoid
        humanoid.MoveToFinished:Connect(function(reached)
        \tprint("finished", reached)
        end)
        humanoid:MoveTo(Vector3.new(0, 0, -30))
        """])
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        step(session, seconds: 3)
        check("a wall stops it", root(model, rig)!.position.z > -9 && line(session, "finished") == "(nothing)",
              "\(root(model, rig)!.position)")
        step(session, seconds: 5.6)
        check("…and after eight seconds it gives up: MoveToFinished, not there", line(session, "finished") == "finished false")

        // A kerb it steps up; a ledge it falls from.
        session.npcs.moveTo(model.dataObjects.first { $0.className == .humanoid }!.id, Vec3(20, 1, 0))
        step(session, seconds: 2.5)
        check("it steps up a kerb", abs(root(model, rig)!.position.y - 4) < 0.2 && flat(root(model, rig)!.position, Vec3(20, 0, 0)) < 1.5,
              "\(root(model, rig)!.position)")
        model.movePivot(of: rig, to: Pose(position: Vec3(-30, 11, 0), orientation: Pose.identity.orientation))
        step(session, seconds: 0.2)
        session.npcs.moveTo(model.dataObjects.first { $0.className == .humanoid }!.id, Vec3(-30, 0, 12))
        step(session, seconds: 2)
        check("a script moving it puts it there; walking off a ledge it falls", abs(root(model, rig)!.position.y - 3) < 0.2
              && root(model, rig)!.position.z > 8, "\(root(model, rig)!.position)")
        let humanoid = model.dataObjects.first { $0.className == .humanoid }!.id
        session.npcs.jump(humanoid)
        var highest: Float = 0
        step(session, seconds: 1) { highest = max(highest, root(model, rig)!.position.y) }
        check("Jump: up it goes, and down again", highest > 8 && abs(root(model, rig)!.position.y - 3) < 0.2, "\(highest)")
        session.stop()
    }

    // MARK: - Pathfinding

    static let pathScript = """
    -- A Script: the Rig walks round the wall to the Flag.
    local PathfindingService = game:GetService("PathfindingService")
    local rig = workspace.Rig
    local humanoid = rig.Humanoid

    local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentCanJump = true })
    path:ComputeAsync(rig.HumanoidRootPart.Position, workspace.Flag.Position)
    if path.Status == Enum.PathStatus.Success then
    \tfor _, waypoint in path:GetWaypoints() do
    \t\tif waypoint.Action == Enum.PathWaypointAction.Jump then
    \t\t\thumanoid.Jump = true
    \t\tend
    \t\thumanoid:MoveTo(waypoint.Position)
    \t\thumanoid.MoveToFinished:Wait()
    \tend
    end
    print("arrived")
    """

    private static func testPathfinding(_ check: Checker) {
        print("\nNPCs: finding the way")
        var wall = Part()
        wall.name = "Wall"
        wall.position = Vec3(0, 5, -12)
        wall.size = Vec3(30, 10, 2)
        wall.anchored = true
        var flag = Part()
        flag.name = "Flag"
        flag.position = Vec3(0, 2, -26)
        flag.size = Vec3(1, 4, 1)
        flag.anchored = true
        flag.canCollide = false
        let (model, rig) = place(parts: [wall, flag], scripts: [pathScript])
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        var closest = Float.infinity
        for _ in 0..<20 {
            step(session, seconds: 0.5)
            closest = min(closest, flat(root(model, rig)!.position, flag.position))
        }
        check("with a PathfindingService path, round a wall to the flag", closest < 2 && line(session, "arrived") == "arrived"
              && said(session, .error).isEmpty, "\(closest) \(said(session, .error))")
        session.stop()
    }

    // MARK: - Health

    private static func testHealth(_ check: Checker) {
        print("\nNPCs: health")
        let (model, rig) = place(scripts: ["""
        local humanoid = workspace.Rig.Humanoid
        humanoid.HealthChanged:Connect(function(health)
        \tprint("health", health)
        end)
        humanoid.Died:Connect(function()
        \tprint("died", humanoid.Health, humanoid:GetState().Name)
        end)
        task.wait(0.2)
        humanoid:TakeDamage(30)
        task.wait(0.2)
        humanoid.MaxHealth = 50
        task.wait(0.2)
        print("max", humanoid.MaxHealth, humanoid.Health)
        humanoid.Health = 0
        """])
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        step(session, seconds: 1)
        check("TakeDamage, HealthChanged", said(session).contains("health 70"), "\(said(session))")
        check("…MaxHealth lowered takes Health with it", line(session, "max") == "max 50 50")
        check("…at no health, Died, once", said(session).filter { $0.hasPrefix("died") } == ["died 0 Dead"],
              "\(said(session))")
        step(session, seconds: 1)
        // Standing, the Torso's centre is 3 studs up; fallen over, 1 or less.
        check("…and it falls apart", model.partIDs(inSubtree: rig).compactMap(model.part(id:)).allSatisfy { !$0.anchored }
              && limb(model, rig, "Torso")!.position.y < 2, "\(limb(model, rig, "Torso")!.position)")
        check("no errors", said(session, .error).isEmpty, "\(said(session, .error))")
        session.stop()
    }

    // MARK: - Made by a script

    private static func testMadeByScript(_ check: Checker) {
        print("\nNPCs: a Humanoid put in any Model")
        let (model, _) = place(scripts: ["""
        local walker = Instance.new("Model")
        walker.Name = "Walker"
        local body = Instance.new("Part")
        body.Name = "Torso"
        body.Size = Vector3.new(2, 4, 2)
        body.Position = Vector3.new(30, 2, 0)
        body.Parent = walker
        walker.Parent = workspace
        local humanoid = Instance.new("Humanoid")
        humanoid.WalkSpeed = 8
        humanoid.Parent = walker
        print("made", walker:FindFirstChildOfClass("Humanoid") == humanoid, humanoid:IsA("Humanoid"), humanoid.WalkSpeed)
        humanoid:MoveTo(Vector3.new(30, 0, 16))
        local ok, message = pcall(function() humanoid.WalkSpeed = "fast" end)
        print("refused", ok)
        """])
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        step(session, seconds: 1)
        let body = model.parts.first { $0.name == "Torso" && $0.size.y == 4 }
        check("Instance.new(\"Humanoid\") in a Model makes it walk, at its own WalkSpeed",
              line(session, "made") == "made true true 8" && (body?.position.z ?? 0) > 6 && (body?.position.z ?? 0) < 10,
              "\(line(session, "made")) \(String(describing: body?.position))")
        check("…a property of the wrong type refused", line(session, "refused") == "refused false")

        // The player walks into one and stops.
        let rig = model.groups.first { $0.name == "Rig" }!.id
        model.movePivot(of: rig, to: Pose(position: Vec3(0, 3, 4), orientation: Pose.identity.orientation))
        session.character.position = Vec3(0, 0, 12)
        session.character.velocity = .zero
        session.key("W", pressed: true)
        step(session, seconds: 1.5)
        session.key("W", pressed: false)
        check("the player bumps into an NPC rather than walking through", session.character.position.z > 5,
              "\(session.character.position)")
        session.stop()
    }

    // MARK: - Postie Pat

    /// Adventure Island's postman walks his round: every stop reached, none given up on.
    private static func testPostie(_ check: Checker) {
        print("\nNPCs: Postie Pat's round on Adventure Island")
        let model = SceneModel()
        model.state = AdventureIsland.state()
        var listen = ScriptObject.blank(language: .luau)
        listen.source = """
        workspace["Postie Pat"].Humanoid.MoveToFinished:Connect(function(reached)
        \tprint("stop", reached)
        end)
        """
        model.scripts.append(listen)
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        // Out of his way.
        session.character.position = Vec3(-40, 0.4, -20)
        step(session, seconds: 25)
        let stops = said(session).filter { $0.hasPrefix("stop") }
        let rig = model.groups.first { $0.name == "Postie Pat" }!.id
        check("round the village and back to the plaza, no stop given up on",
              stops.count >= 10 && !stops.contains("stop false"), "\(stops) \(root(model, rig)!.position)")
        check("…with no errors", said(session, .error).isEmpty, "\(said(session, .error))")
        session.stop()
        DataStoreFiles.shared.clear(place: model.placeID ?? UUID())
    }

    // MARK: - Together

    private static func testTogether(_ check: Checker) {
        print("\nNPCs: a host and a joined player")
        let rig = NPCRig.make(at: Vec3(0, 0, 0))
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            var base = Part()
            base.name = "Baseplate"
            base.position = Vec3(0, -0.5, 0)
            base.size = Vec3(300, 1, 300)
            base.anchored = true
            model.parts = [base] + rig.parts
            model.groups = [rig.group]
            model.dataObjects = [rig.humanoid]
            var walk = ScriptObject.blank(language: .luau)
            walk.source = """
            local humanoid = workspace.Rig.Humanoid
            task.wait(0.5)
            humanoid:MoveTo(Vector3.new(0, 0, -20))
            humanoid.MoveToFinished:Wait()
            task.wait(0.5)
            humanoid.Health = 0
            """
            var watch = ScriptObject.blank(language: .luau)
            watch.host = .starterPlayer
            watch.source = """
            local humanoid = workspace:WaitForChild("Rig"):WaitForChild("Humanoid")
            humanoid.Died:Connect(function()
            \tprint("saw it die")
            end)
            """
            model.scripts += [walk, watch]
        }), let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 1.8)
        let seen = joining.model.parts.first { $0.name == "HumanoidRootPart" }?.position ?? .zero
        check("a joined player sees the host's NPC walk", seen.z < -8, "\(seen)")
        LANSelfTest.run([hosting, joining], seconds: 2.5)
        check("…and die: their scripts hear Died, and the parts fall apart there too",
              said(sam).contains("saw it die")
              && joining.model.parts.filter { rig.parts.map(\.id).contains($0.id) }.allSatisfy { !$0.anchored },
              "\(said(sam))")
        let errors = said(hosting.player!, .error) + said(sam, .error)
        check("…with no errors on either", errors.isEmpty, "\(errors)")
        joining.leaveGame()
        hosting.leaveGame()
    }
}
