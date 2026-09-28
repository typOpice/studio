import Foundation
import simd

/// Floating: in a water part, a plastic crate floating a little over half under, a wooden
/// one higher, a metal one sinking to the bottom, a welded raft floating by its parts'
/// weight together, a plank settling flat, a crate sent skimming slowed by the water, and
/// nothing floating on dry land; in the Terrain's water too; a script turning a crate to
/// metal (it sinks) and to wood (it comes back up); Adventure Island's driftwood and
/// beach ball afloat; and a host's crate floating in a joined player's game.
enum FloatSelfTest {
    static func run(check: Checker) {
        testPool(check)
        testTerrain(check)
        testScripts(check)
        testAdventure(check)
        testTogether(check)
    }

    private static let frame = ForceSelfTest.frame

    private static func block(_ name: String, _ position: Vec3, size: Vec3 = Vec3(2, 2, 2), anchored: Bool = false,
                              material: PartMaterial = .plastic) -> Part {
        var part = ForceSelfTest.block(name, position, size: size, anchored: anchored)
        part.material = material
        return part
    }

    /// Ground, and a pool of water 10 deep (its surface at 10) — with the parts given.
    private static func pool(_ parts: [Part]) -> SceneModel {
        ForceSelfTest.scene([block("Ground", Vec3(0, -0.5, 0), size: Vec3(300, 1, 300), anchored: true),
                             block("Pool", Vec3(0, 5, 0), size: Vec3(60, 10, 60), anchored: true, material: .water)] + parts)
    }

    /// Runs a place with no player, as Studio's Run does.
    private static func run(_ model: SceneModel, seconds: Float, each: ((PlayController) -> Void)? = nil) -> PlayController {
        let session = PlayController(model: model, console: ScriptConsole(), withPlayer: false)
        session.start()
        var elapsed: Float = 0
        while elapsed < seconds {
            session.step(dt: frame)
            each?(session)
            elapsed += frame
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        return session
    }

    private static func part(_ model: SceneModel, _ name: String) -> Part { ForceSelfTest.part(model, name) }

    // MARK: - A pool

    private static func testPool(_ check: Checker) {
        print("\nFloating: a pool")
        let model = pool([block("Plastic", Vec3(-10, 14, 0)), block("Wooden", Vec3(0, 14, 0), material: .wood),
                          block("Metal", Vec3(10, 14, 0), material: .metal)])
        var rising: Float = 0
        let session = run(model, seconds: 8) { session in
            rising = abs(session.physics.motion(of: part(model, "Plastic").id)?.velocity.y ?? 1)
        }
        // At rest a block floats with its density's share of it under: plastic 0.7, wood 0.35.
        let plastic = part(model, "Plastic").position.y, wooden = part(model, "Wooden").position.y
        check("a plastic crate floats, about 0.7 of it under", abs(plastic - 9.6) < 0.25 && rising < 0.5, "\(plastic) \(rising)")
        check("…a wooden one higher, about 0.35 under", abs(wooden - 10.3) < 0.25, "\(wooden)")
        check("…and a metal one sinks to the bottom", abs(part(model, "Metal").position.y - 1) < 0.2,
              "\(part(model, "Metal").position.y)")
        check("…in the water, not drifting off", abs(part(model, "Plastic").position.x + 10) < 1)
        session.stop()

        // A wooden raft with a metal anchor welded on: floats on their weight together.
        let raft = pool([block("Raft", Vec3(0, 14, 0), size: Vec3(6, 1, 6), material: .wood),
                         block("Anchor", Vec3(0, 15, 0), size: Vec3(1, 1, 1), material: .metal)])
        var weld = SceneConstraint(kind: .weld)
        weld.part0 = part(raft, "Raft").id
        weld.part1 = part(raft, "Anchor").id
        raft.constraints = [weld]
        run(raft, seconds: 6).stop()
        // 36 × 0.35 + 7.85 = 20.45 of 37: 0.55 under of a raft 1 deep (its middle 0.05 over the surface).
        check("a welded raft floats on its parts' weight together", abs(part(raft, "Raft").position.y - 10.0) < 0.3,
              "\(part(raft, "Raft").position.y)")

        var tilted = block("Plank", Vec3(0, 13, 0), size: Vec3(8, 1, 2), material: .wood)
        tilted.rotationDegrees = Vec3(0, 0, 40)
        let plank = pool([tilted])
        run(plank, seconds: 8).stop()
        let up = part(plank, "Plank").orientation.act(Vec3(0, 1, 0))
        check("a plank dropped on its side settles flat", abs(up.y) > 0.97, "\(up)")

        let skimming = pool([block("Skimmer", Vec3(0, 9.6, 0))])
        var speeds: [Float] = []
        var sent = false
        run(skimming, seconds: 3) { session in
            let id = part(skimming, "Skimmer").id
            if !sent {
                session.physics.setVelocity(id, Vec3(60, 0, 0))
                sent = true
            }
            if let v = session.physics.motion(of: id)?.velocity { speeds.append(simd_length(Vec3(v.x, 0, v.z))) }
        }.stop()
        check("the water slows a crate sent skimming across it", (speeds.first ?? 0) > 40 && (speeds.last ?? 99) < 5,
              "\(speeds.first ?? -1) \(speeds.last ?? -1)")

        let dry = ForceSelfTest.scene([block("Ground", Vec3(0, -0.5, 0), size: Vec3(100, 1, 100), anchored: true),
                                       block("Crate", Vec3(0, 1, 0))])
        var afloat = 0
        run(dry, seconds: 1) { afloat = max(afloat, $0.physics.floatingCount) }.stop()
        check("on dry land nothing floats", afloat == 0 && abs(part(dry, "Crate").position.y - 1) < 0.05)
    }

    // MARK: - The Terrain's water

    private static func testTerrain(_ check: Checker) {
        print("\nFloating: in the Terrain's water")
        let model = ForceSelfTest.scene([block("Crate", Vec3(0, 16, 0)), block("Log", Vec3(6, 16, 0), size: Vec3(1, 1, 6), material: .wood)])
        // Rock to 0, water from there to 8.
        model.terrain.fillRegion(low: Vec3(-32, -8, -32), high: Vec3(32, 0, 32), material: .rock)
        model.terrain.fillRegion(low: Vec3(-32, 0, -32), high: Vec3(32, 8, 32), material: .water)
        run(model, seconds: 8).stop()
        let crate = part(model, "Crate").position.y, log = part(model, "Log").position.y
        check("a crate floats in the Terrain's water", abs(crate - 7.6) < 0.3, "\(crate)")
        check("…and a log, higher", abs(log - 8.15) < 0.3, "\(log)")
    }

    // MARK: - Scripts

    private static func testScripts(_ check: Checker) {
        print("\nFloating: from scripts")
        let model = pool([block("Crate", Vec3(0, 12, 0))])
        var script = ScriptObject.blank(language: .luau)
        script.source = """
        local crate = workspace.Crate
        task.wait(3)
        print("afloat", math.abs(crate.Position.Y - 9.6) < 0.3)
        crate.Material = Enum.Material.Metal
        task.wait(4)
        print("sunk", math.abs(crate.Position.Y - 1) < 0.3)
        crate.Material = Enum.Material.Wood
        task.wait(5)
        print("back up", math.abs(crate.Position.Y - 10.3) < 0.3, crate.Position.Y)
        """
        model.scripts = [script]
        let session = run(model, seconds: 13)
        let output = session.console.lines.filter { $0.kind == .output }.map(\.text)
        check("a script turning a crate to metal sinks it, and to wood brings it back up",
              output.contains("afloat true") && output.contains("sunk true") && output.contains { $0.hasPrefix("back up true") },
              "\(output)")
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("no errors", errors.isEmpty, "\(errors)")
        session.stop()
    }

    // MARK: - Adventure Island

    private static func testAdventure(_ check: Checker) {
        print("\nFloating: Adventure Island's lake")
        let model = SceneModel()
        model.state = AdventureIsland.state()
        let before = model.parts.filter { ["Driftwood", "BeachBall"].contains($0.name) }
        let session = run(model, seconds: 6)
        let after = model.parts.filter { ["Driftwood", "BeachBall"].contains($0.name) }
        // The lake's surface is at 4: afloat, near where they started.
        check("its driftwood and beach ball float on the lake", before.count == 3 && after.count == 3
              && after.allSatisfy { $0.position.y > 3.4 && $0.position.y < 5.5 && !$0.anchored }
              && zip(before, after).allSatisfy { simd_distance(SIMD2($0.position.x, $0.position.z), SIMD2($1.position.x, $1.position.z)) < 6 },
              "\(after.map { ($0.name, $0.position) })")
        session.stop()
    }

    // MARK: - Together

    private static func testTogether(_ check: Checker) {
        print("\nFloating: a host and a joined player")
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            var base = Part()
            base.name = "Baseplate"
            base.position = Vec3(0, -0.5, 0)
            base.size = Vec3(200, 1, 200)
            var water = Part()
            water.name = "Pond"
            water.position = Vec3(40, 5, 40)
            water.size = Vec3(30, 10, 30)
            water.material = .water
            water.canCollide = false
            var crate = Part()
            crate.name = "Crate"
            crate.position = Vec3(40, 16, 40)
            crate.size = Vec3(2, 2, 2)
            crate.material = .wood
            crate.anchored = false
            model.parts = [base, water, crate]
        }), let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 5)
        let seen = joining.model.parts.first { $0.name == "Crate" }?.position ?? .zero
        check("a crate dropped in the host's pond floats, and the joined player sees it afloat",
              abs(seen.y - 10.3) < 0.35 && simd_distance(SIMD2(seen.x, seen.z), SIMD2<Float>(40, 40)) < 2, "\(seen)")
        let errors = (hosting.player!.console.lines + sam.console.lines).filter { $0.kind == .error }.map(\.text)
        check("…with no errors on either", errors.isEmpty, "\(errors)")
        joining.leaveGame()
        hosting.leaveGame()
    }
}
