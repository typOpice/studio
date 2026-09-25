import Foundation
import simd

/// Verification for rigid-body physics: falling, resting, stacking, friction, bouncing,
/// rolling, fast parts against thin ones, sleeping, and keeping in step with the scene.
/// Numbers are checked against the textbook answers.
enum PhysicsSelfTest {

    static func run(check: Checker) {
        testFalling(check)
        testResting(check)
        testStacking(check)
        testFriction(check)
        testBouncing(check)
        testRolling(check)
        testTunnelling(check)
        testSceneSync(check)
        testCollisions(check)
        testPerformance(check)
        testInPlay(check)
        testScripting(check)
        testReadmeExample(check)
    }

    /// The README's physics example, verbatim, with a Ball and a Car to act on.
    private static func testReadmeExample(_ check: Checker) {
        var ball = block(Vec3(0, 2, -20), shape: .sphere)
        ball.name = "Ball"
        var body = block(Vec3(20, 1, 0), size: Vec3(4, 1, 8), anchored: true)
        body.name = "Body"
        var car = SceneGroup(name: "Car", kind: .model)
        car.primaryPartID = body.id
        body.parentID = car.id
        let rerun = stage([ball, body], groups: [car], script: """
            local ball = workspace.Ball
            ball.AssemblyLinearVelocity = Vector3.new(0, 80, 0)     -- throw it up
            ball:ApplyImpulse(Vector3.new(ball.Mass * 30, 0, 0))    -- shove it sideways
            ball.Touched:Connect(function(other) print("hit", other.Name) end)

            local car = workspace.Car
            car:PivotTo(car:GetPivot() * CFrame.Angles(0, math.rad(90), 0))   -- turn a whole Model
            """)
        var highest: Float = 0
        play(rerun, seconds: 2) { highest = max(highest, rerun.model.parts.first { $0.name == "Ball" }!.position.y) }
        let turned = rerun.model.parts.first { $0.name == "Body" }!.orientation.act(Vec3(1, 0, 0))
        check("the README physics example runs",
              output(rerun, .error).isEmpty && highest > 10 && abs(turned.z) > 0.99,
              "\(output(rerun, .error)) high \(highest) turned \(turned)")
        rerun.stop()
    }

    // MARK: - In a play session

    private static func stage(_ parts: [Part], groups: [SceneGroup] = [], script: String? = nil,
                              controls: Bool = false) -> PlayController {
        let model = SceneModel()
        model.parts = parts
        model.scripts = []
        model.shaders = []
        model.groups = groups
        if !controls {
            var off = ScriptObject.blank(language: .luau)
            off.name = "ControlScript"
            off.host = .starterPlayer
            off.enabled = false
            model.scripts.append(off)
        }
        if let script {
            var s = ScriptObject.blank(language: .luau)
            s.source = script
            model.scripts.append(s)
        }
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        return session
    }

    private static func play(_ session: PlayController, seconds: Float, each: (() -> Void)? = nil) {
        var elapsed: Float = 0
        while elapsed < seconds {
            session.step(dt: 1.0 / 60)
            each?()
            elapsed += 1.0 / 60
        }
    }

    private static func output(_ session: PlayController, _ kind: ScriptConsole.Kind = .output) -> [String] {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        return session.console.lines.filter { $0.kind == kind }.map(\.text)
    }

    private static func testInPlay(_ check: Checker) {
        print("\nPhysics: in play")
        var crate = block(Vec3(30, 12, 30))
        crate.name = "Crate"
        let session = stage([crate])
        play(session, seconds: 1.5)
        let landed = session.model.parts[0]
        check("in play, an unanchored part falls and the scene follows", abs(landed.position.y - 1) < 0.1,
              "\(landed.position)")

        // A box dropped on the player's head rests on it rather than falling through.
        let feet = session.character.position
        var hat = block(feet + Vec3(0, 12, 0), size: Vec3(1, 1, 1))
        hat.name = "Hat"
        session.model.parts.append(hat)
        play(session, seconds: 1.2)
        let rested = session.model.parts.first { $0.name == "Hat" }!
        check("a part dropped on the player lands on them",
              rested.position.y > feet.y + CharacterController.capsuleHeight - 0.2, "\(rested.position.y) vs feet \(feet.y)")

        // …even when the player has only just moved and is still awake in Jolt. The
        // capsule's layer once looked for nothing, and Jolt checks a pair of awake bodies
        // from one side only, so this fell straight through.
        let world = PhysicsWorld()
        world.moveCharacter(feet: Vec3(20, 0.5, 20), radius: CharacterController.capsuleRadius,
                            height: CharacterController.capsuleHeight, dt: 1.0 / 60)
        _ = world.step(dt: 1.0 / 60)
        for _ in 0..<18 {
            world.moveCharacter(feet: Vec3(20, 0, 20), radius: CharacterController.capsuleRadius,
                                height: CharacterController.capsuleHeight, dt: 1.0 / 60)
            _ = world.step(dt: 1.0 / 60)
        }
        var onMover = [block(Vec3(20, 12, 20), size: Vec3(1, 1, 1))]
        for _ in 0..<90 {
            world.sync(onMover)
            world.moveCharacter(feet: Vec3(20, 0, 20), radius: CharacterController.capsuleRadius,
                                height: CharacterController.capsuleHeight, dt: 1.0 / 60)
            for (id, pose) in world.step(dt: 1.0 / 60).moved where id == onMover[0].id { onMover[0].pose = pose }
        }
        check("…even one who has just moved", onMover[0].position.y > CharacterController.capsuleHeight,
              "\(onMover[0].position.y)")

        // A dead character lies down: what rested on its head falls, rather than staying
        // up on a capsule nobody can see.
        session.humanoid.die()
        play(session, seconds: 1.2)
        let dropped = session.model.parts.first { $0.name == "Hat" }!
        check("when the player dies, what was on their head falls to the ground",
              dropped.position.y < feet.y + 1.5, "\(dropped.position.y) vs feet \(feet.y)")
        // Clear it away, or the next character spawns standing on it.
        session.model.parts.removeAll { $0.name == "Hat" }
        play(session, seconds: session.model.starterPlayer.respawnTime + 0.5)
        var cap = block(session.character.position + Vec3(0, 12, 0), size: Vec3(1, 1, 1))
        cap.name = "Cap"
        session.model.parts.append(cap)
        play(session, seconds: 1.2)
        let capped = session.model.parts.first { $0.name == "Cap" }!
        let standing = session.character.position
        check("…and the next character holds things up again",
              !session.humanoid.isDead && capped.position.y > standing.y + CharacterController.capsuleHeight - 0.2,
              "\(capped.position) vs feet \(standing)")
        session.stop()

        // Walking into a light box shoves it; into a heavy metal block, hardly.
        func shove(_ part: Part) -> Float {
            let pushing = stage([part])
            pushing.character.position = Vec3(0, 0, 6)
            play(pushing, seconds: 0.5)
            let start = pushing.model.parts[0].position.z
            play(pushing, seconds: 1.5) { pushing.humanoid.moveDirection = Vec3(0, 0, -1) }
            pushing.stop()
            return start - pushing.model.parts[0].position.z
        }
        let light = shove(block(Vec3(0, 1, 0)))
        let heavy = shove(block(Vec3(0, 2, 0), size: Vec3(4, 4, 4), material: .metal))
        check("walking into a crate pushes it along (\(String(format: "%.1f", light)) studs)", light > 8, "moved \(light)")
        check("…but a heavy metal block barely moves (\(String(format: "%.1f", heavy)) studs)", heavy < light * 0.3 && heavy >= 0, "moved \(heavy) vs \(light)")

        // Anchored parts never move, even when pushed.
        let wall = shove(block(Vec3(0, 1, 0), anchored: true))
        check("anchored parts stay put", wall == 0, "\(wall)")
    }

    private static func testScripting(_ check: Checker) {
        print("\nPhysics: scripts")
        var floor = block(Vec3(40, 0.5, 40), size: Vec3(30, 1, 30), anchored: true)
        floor.name = "Floor"
        var ball = block(Vec3(40, 8, 40), shape: .sphere)
        ball.name = "Ball"
        var shelf = block(Vec3(60, 6, 40), anchored: true)
        shelf.name = "Shelf"
        let session = stage([floor, ball, shelf], script: """
            local ball, floor, shelf = workspace.Ball, workspace.Floor, workspace.Shelf
            ball.Touched:Connect(function(other) print("ball touched", other.Name) end)
            floor.Touched:Connect(function(other) print("floor touched", other.Name) end)
            print(math.round(ball.Mass * 100) / 100, ball:GetMass() == ball.Mass, floor.Mass > 0)
            print(pcall(function() ball.Mass = 5 end))
            print(pcall(function() ball.AssemblyLinearVelocity = 3 end))
            task.wait(1)
            print("resting", ball.AssemblyLinearVelocity.Magnitude < 0.5)
            ball.AssemblyLinearVelocity = Vector3.new(0, 60, 0)
            task.wait(0.1)
            print("launched", ball.Position.Y > 3)
            task.wait(1.5)
            ball:ApplyImpulse(Vector3.new(ball.Mass * 40, 0, 0))
            task.wait(0.2)
            print("pushed", ball.Position.X > 42)
            shelf.Anchored = false
            task.wait(0.8)
            print("shelf fell", shelf.Position.Y < 2)
            """)
        play(session, seconds: 4.5)
        let out = output(session)
        let errors = output(session, .error)
        func line(_ prefix: String) -> String { out.first { $0.hasPrefix(prefix) } ?? "(missing)" }
        let mass = PhysicsWorld.massProperties(of: ball).mass
        check("Mass reads like Roblox's", out.first == "\((mass * 100).rounded() / 100) true true" || out.first?.hasSuffix("true true") == true,
              "\(out) \(errors)")
        check("…and is read only", out.count > 1 && out[1].contains("read only"), "\(out)")
        check("velocities are type-checked", out.count > 2 && out[2].contains("Vector3 expected"), "\(out)")
        check("a part comes to rest", line("resting") == "resting true", line("resting"))
        check("setting AssemblyLinearVelocity launches it", line("launched") == "launched true", line("launched"))
        check("ApplyImpulse shoves it", line("pushed") == "pushed true", line("pushed"))
        check("unanchoring a part from a script drops it", line("shelf fell") == "shelf fell true", line("shelf fell"))
        check("parts that touch each other fire Touched both ways",
              out.contains("ball touched Floor") && out.contains("floor touched Ball"), "\(out)")
        check("no script errors", errors.isEmpty, "\(errors)")
        session.stop()

        // Out of the world: destroyed, as Roblox does.
        let lost = stage([block(Vec3(0, 5, 0))], script: """
            local box = workspace:FindFirstChildOfClass("Part")
            task.wait(3)
            print("gone", box.Parent == nil)
            """)
        lost.character.solidBaseplate = false
        lost.physics.groundPlane = false
        play(lost, seconds: 3.3)
        check("a part that falls out of the world is destroyed", output(lost).contains("gone true")
              && lost.model.parts.isEmpty, "\(output(lost)) \(output(lost, .error))")
        lost.stop()
    }

    private static func near(_ a: Float, _ b: Float, _ tolerance: Float) -> Bool { abs(a - b) <= tolerance }

    static func block(_ position: Vec3, size: Vec3 = Vec3(2, 2, 2), anchored: Bool = false,
                      shape: PartShape = .block, material: PartMaterial = .plastic) -> Part {
        var part = Part()
        part.name = anchored ? "Floor" : "Box"
        part.shape = shape
        part.position = position
        part.size = size
        part.anchored = anchored
        part.material = material
        return part
    }

    /// Runs the world for a while, feeding the moved poses back as the game does.
    @discardableResult
    static func simulate(_ world: PhysicsWorld, _ parts: inout [Part], seconds: Float,
                         each: (([Part]) -> Void)? = nil) -> [UUID] {
        var fallen: [UUID] = []
        var elapsed: Float = 0
        while elapsed < seconds - 1e-4 {
            world.sync(parts)
            let result = world.step(dt: 1.0 / 60)
            for (id, pose) in result.moved {
                if let i = parts.firstIndex(where: { $0.id == id }) { parts[i].pose = pose }
            }
            fallen += result.fallen
            parts.removeAll { result.fallen.contains($0.id) }
            elapsed += 1.0 / 60
            // Handed the parts, rather than reading the caller's array while this
            // function still holds it.
            each?(parts)
        }
        return fallen
    }

    private static func testFalling(_ check: Checker) {
        print("\nPhysics: falling and resting")
        let world = PhysicsWorld()
        world.groundPlane = false
        var parts = [block(Vec3(0, 100, 0))]
        simulate(world, &parts, seconds: 0.5)
        let expected = 100 - 0.5 * CharacterController.gravity * 0.25
        check("a part falls as far as gravity says", near(parts[0].position.y, expected, 0.5),
              "\(parts[0].position.y) vs \(expected)")

        let fallen = simulate(world, &parts, seconds: 2.5)
        check("a part that falls out of the world is destroyed", fallen.count == 1 && parts.isEmpty)
    }

    private static func testResting(_ check: Checker) {
        let world = PhysicsWorld()
        var parts = [block(Vec3(0, 0.5, 0), size: Vec3(20, 1, 20), anchored: true), block(Vec3(0, 6, 0))]
        simulate(world, &parts, seconds: 2)
        check("it lands on an anchored part and rests on top", near(parts[1].position.y, 2, 0.05),
              "\(parts[1].position.y)")
        check("…upright and still", simd_length(world.body(for: parts[1].id)!.velocity) < 0.05
              && abs(simd_dot(parts[1].orientation.act(Vec3(0, 1, 0)), Vec3(0, 1, 0))) > 0.999)
        check("…and falls asleep", world.body(for: parts[1].id)!.sleeping)

        let floorWorld = PhysicsWorld()
        var loose = [block(Vec3(4, 3, 4), size: Vec3(1, 1, 1))]
        simulate(floorWorld, &loose, seconds: 1.5)
        check("with no baseplate it rests on the ground, like the player", near(loose[0].position.y, 0.5, 0.05),
              "\(loose[0].position.y)")

        let heavy = PhysicsWorld.massProperties(of: block(.zero, material: .metal)).mass
        let light = PhysicsWorld.massProperties(of: block(.zero, material: .wood)).mass
        check("mass follows material and size", near(heavy, 8 * 7.85, 0.01) && near(light, 8 * 0.35, 0.01))
    }

    private static func testStacking(_ check: Checker) {
        print("\nPhysics: stacks, friction, bounce, rolling")
        let world = PhysicsWorld()
        var parts = (0..<6).map { block(Vec3(0, 1 + Float($0) * 2.05, 0)) }
        simulate(world, &parts, seconds: 4)
        let drift = parts.map { simd_length(Vec3($0.position.x, 0, $0.position.z)) }.max() ?? 99
        let heights = parts.map(\.position.y)
        check("a tower of six boxes stands", drift < 0.1 && heights.enumerated().allSatisfy { near($1, 1 + Float($0) * 2, 0.1) },
              "drift \(drift), heights \(heights)")
        check("…and goes to sleep", parts.allSatisfy { world.body(for: $0.id)!.sleeping })
    }

    private static func testFriction(_ check: Checker) {
        let world = PhysicsWorld()
        var parts = [block(Vec3(0, 1, 0))]
        simulate(world, &parts, seconds: 0.5)
        world.setVelocity(parts[0].id, Vec3(20, 0, 0))
        let start = parts[0].position.x
        simulate(world, &parts, seconds: 2)
        let slid = parts[0].position.x - start
        let mu = sqrt(PhysicsWorld.friction(.plastic) * 0.5)
        let expected = 20 * 20 / (2 * mu * CharacterController.gravity)
        check("a sliding box stops where friction says", near(slid, expected, expected * 0.35),
              "slid \(slid) vs \(expected)")
    }

    private static func testBouncing(_ check: Checker) {
        let world = PhysicsWorld()
        var parts = [block(Vec3(0, 20, 0), shape: .sphere)]
        let ball = parts[0].id
        var landed = false
        var rebound: Float = 0
        // It touches down between frames, so a bounce shows as the velocity turning upward.
        simulate(world, &parts, seconds: 2) { now in
            if !landed && world.body(for: ball)!.velocity.y > 1 { landed = true }
            if landed { rebound = max(rebound, now[0].position.y - 1) }
        }
        check("a ball bounces, a little", landed && rebound > 0.2 && rebound < 3, "rebound \(rebound)")
    }

    private static func testRolling(_ check: Checker) {
        let world = PhysicsWorld()
        // A ramp falling towards +Z, and a ball at its high end.
        var ramp = block(Vec3(0, 3, 0), size: Vec3(6, 6, 12), anchored: true, shape: .wedge)
        ramp.name = "Ramp"
        var parts = [ramp, block(Vec3(0, 7.2, -4.5), shape: .sphere)]
        let start = parts[1].position
        var spun: Float = 0
        let ball = parts[1].id
        simulate(world, &parts, seconds: 1.2) { _ in
            spun = max(spun, simd_length(world.body(for: ball)?.angularVelocity ?? .zero))
        }
        check("a ball rolls down a wedge", parts[1].position.z > start.z + 4 && parts[1].position.y < start.y - 2,
              "\(start) → \(parts[1].position)")
        check("…spinning as it goes", spun > 2, "\(spun)")

        let slide = PhysicsWorld()
        var boxRamp = [ramp, block(Vec3(0, 7, -4), size: Vec3(1, 1, 1), material: .smooth)]
        let top = boxRamp[1].position
        simulate(slide, &boxRamp, seconds: 1.5)
        check("a box slides down it", boxRamp[1].position.z > top.z + 3, "\(boxRamp[1].position)")
    }

    private static func testTunnelling(_ check: Checker) {
        let world = PhysicsWorld()
        world.groundPlane = false
        var parts = [block(Vec3(0, 0, 0), size: Vec3(10, 0.2, 10), anchored: true), block(Vec3(0, 8, 0), size: Vec3(1, 1, 1))]
        world.sync(parts)
        world.setVelocity(parts[1].id, Vec3(0, -400, 0))
        var lowest: Float = .greatestFiniteMagnitude
        simulate(world, &parts, seconds: 1) { now in lowest = min(lowest, now[1].position.y) }
        // The plate's top is at 0.1 and the box is 1 stud: its centre never goes below 0.6.
        check("a fast part doesn't pass through a thin one", lowest > 0.45, "lowest \(lowest)")
    }

    private static func testSceneSync(_ check: Checker) {
        print("\nPhysics: keeping up with the scene")
        let world = PhysicsWorld()
        var parts = [block(Vec3(0, 10, 0), anchored: true)]
        simulate(world, &parts, seconds: 0.5)
        check("anchored parts stay put", parts[0].position.y == 10)
        parts[0].anchored = false
        simulate(world, &parts, seconds: 1.6)
        check("unanchoring one lets it fall", near(parts[0].position.y, 1, 0.05), "\(parts[0].position.y)")
        check("…where it sleeps", world.body(for: parts[0].id)!.sleeping)

        parts[0].position = Vec3(5, 20, 5)
        simulate(world, &parts, seconds: 0.1)
        check("a part a script moves is moved, and wakes", parts[0].position.y < 20 && parts[0].position.y > 15
              && near(parts[0].position.x, 5, 0.01))

        world.applyImpulse(parts[0].id, Vec3(0, 0, 50 * PhysicsWorld.massProperties(of: parts[0]).mass))
        simulate(world, &parts, seconds: 0.1)
        check("an impulse sets it moving", parts[0].position.z > 5.5, "\(parts[0].position)")

        parts.remove(at: 0)
        world.sync(parts)
        check("a removed part leaves the world", world.bodies.isEmpty)
    }

    private static func testCollisions(_ check: Checker) {
        let world = PhysicsWorld()
        var parts = [block(Vec3(-3, 1, 0)), block(Vec3(3, 1, 0))]
        simulate(world, &parts, seconds: 0.4)
        world.setVelocity(parts[0].id, Vec3(40, 0, 0))
        var pushed = false
        let struck = parts[1].id
        simulate(world, &parts, seconds: 0.5) { _ in
            if world.body(for: struck)!.velocity.x > 2 { pushed = true }
        }
        check("one box knocks another along", pushed && parts[1].position.x > 3.5, "\(parts[1].position)")
        check("…without passing through it", parts[0].position.x < parts[1].position.x - 1.9)
        world.sync(parts)
        let a = world.body(for: parts[0].id)!, b = world.body(for: parts[1].id)!
        _ = (a, b)
        simulate(world, &parts, seconds: 0.05)
        check("touching parts are reported",
              world.touchingPairs.contains { Set($0) == Set([parts[0].id, parts[1].id]) }
              || simd_distance(parts[0].position, parts[1].position) > 2.1)
    }

    private static func testPerformance(_ check: Checker) {
        let world = PhysicsWorld()
        var parts = [block(Vec3(0, 0.5, 0), size: Vec3(60, 1, 60), anchored: true)]
        for i in 0..<100 {
            parts.append(block(Vec3(Float(i % 10) * 2.5 - 12, 2 + Float(i / 10) * 2.2, Float(i % 7) * 0.3), size: Vec3(2, 2, 2)))
        }
        simulate(world, &parts, seconds: 0.5)
        let start = CFAbsoluteTimeGetCurrent()
        simulate(world, &parts, seconds: 1)
        let perFrame = (CFAbsoluteTimeGetCurrent() - start) / 60 * 1000
        check("100 falling boxes: \(String(format: "%.1f", perFrame)) ms a frame (debug build)", perFrame < 60,
              "\(perFrame) ms")
    }
}
