import Foundation
import Metal
import simd

/// Mega Obby: sixty stages in order, each one possible (every gap within a jump, worked
/// out from the character's own speed, jump and gravity); the mechanics working by name;
/// stages, checkpoints, the stage picker, respawning and the finish; and a host and a
/// joined player each with their own stage.
enum MegaObbySelfTest {
    static func run(check: Checker) {
        // Stages are saved; each test starts at stage 1 (DataStoreSelfTest checks the saving).
        let fresh = { DataStoreFiles.shared.clear(place: MegaObby.placeID) }
        testPlace(check)
        testEveryStageCanBeDone(check)
        fresh()
        testPlaying(check)
        fresh()
        testTogether(check)
        fresh()
    }

    private static let frame: Float = 1.0 / 60

    private static func step(_ session: PlayController, seconds: Float) {
        var elapsed: Float = 0
        while elapsed < seconds {
            session.step(dt: frame)
            elapsed += frame
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }

    private static func said(_ session: PlayController, _ kind: ScriptConsole.Kind = .output) -> [String] {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        return session.console.lines.filter { $0.kind == kind }.map(\.text)
    }

    /// The checkpoints by stage number.
    private static func checkpoints(_ state: SceneState) -> [Int: Part] {
        var found: [Int: Part] = [:]
        for pad in state.parts where pad.name == "Checkpoint" {
            if let stage = state.dataObjects.first(where: { $0.name == "Stage" && $0.parent == .node(pad.id) }) {
                found[Int(stage.number)] = pad
            }
        }
        return found
    }

    // MARK: - The place

    private static func testPlace(_ check: Checker) {
        print("\nMega Obby: the place")
        let state = MegaObby.state()
        let pads = checkpoints(state)
        check("sixty numbered checkpoints", pads.count == 60 && pads.keys.sorted() == Array(1...60))
        let order = (1...60).compactMap { pads[$0]?.position.z }
        check("…in order along the course", zip(order, order.dropFirst()).allSatisfy { $0 > $1 }, "\(order.prefix(5))")
        check("a stage between each", (1...60).allSatisfy { stage in
            state.groups.contains { $0.name == "Stage\(stage)" }
        })
        let worlds = state.dataObjects.filter { $0.name == "World" }.map(\.text).sorted()
        check("six worlds, each starting at a checkpoint that names it", worlds.count == 6
              && worlds.first == "World 1: Grassy Meadows" && worlds.last == "World 6: Sky Kingdom", "\(worlds)")
        check("a finish after the last", state.parts.contains { $0.name == "Finish" }
              && (state.parts.first { $0.name == "Victory" }?.position.z ?? 0) < (pads[60]?.position.z ?? 0))
        let kinds = Set(state.parts.map(\.name))
        check("every kind of obstacle is somewhere", ["KillBrick", "KillFloor", "KillMover", "Mover", "Spinner", "FadeTile",
                                                      "JumpPad", "Truss", "Pillar", "Beam", "Ledge", "Zig"].allSatisfy(kinds.contains),
              "\(kinds.sorted())")
        let heights = pads.values.map { $0.position.y }
        check("the course stays in sight of the ground", heights.allSatisfy { $0 > 10 && $0 < 70 }, "\(heights.max() ?? 0)")
        check("its scripts", ["ObbyGame", "Mechanics", "ObbyScreen", "Utils"].allSatisfy { name in
            state.scripts.contains { $0.name == name }
        })
        if let device = MTLCreateSystemDefaultDevice() {
            let failed = state.shaders.filter { shader in
                (try? device.makeLibrary(source: ShaderSource.wrap(shader), options: nil)) == nil
            }.map(\.name)
            check("its three shaders compile", failed.isEmpty && state.shaders.count == 3, "\(failed)")
        }
    }

    // MARK: - Every stage, possible

    /// How far a running jump carries, edge to edge, landing `rise` studs higher (or lower):
    /// the character's own speed, jump and gravity, with a margin.
    static func reach(rising rise: Float) -> Float {
        let v = CharacterController.jumpPower, g = CharacterController.gravity
        let under = v * v - 2 * g * rise
        guard under >= 0 else { return 0 }
        let airborne = (v + sqrt(under)) / g
        return CharacterController.walkSpeed * airborne * 0.9
    }

    private struct Foothold {
        var name: String
        var low: SIMD2<Float>
        var high: SIMD2<Float>
        var top: Float
        var z: Float
    }

    private static func foothold(_ part: Part, sweep: Vec3 = .zero) -> Foothold {
        // Turned parts count as their widest square; a Mover covers where it goes.
        var half = SIMD2(part.size.x, part.size.z) / 2
        if part.rotationDegrees != .zero { half = SIMD2(repeating: max(part.size.x, part.size.z) / 2) }
        let centre = SIMD2(part.position.x, part.position.z)
        let sweepXZ = SIMD2(sweep.x, sweep.z)
        return Foothold(name: part.name, low: centre - half + simd_min(sweepXZ, .zero),
                        high: centre + half + simd_max(sweepXZ, .zero), top: part.position.y + part.size.y / 2,
                        z: part.position.z)
    }

    private static func testEveryStageCanBeDone(_ check: Checker) {
        print("\nMega Obby: every stage can be done")
        check("a running jump carries about 7 studs level, less going up", reach(rising: 0) > 7 && reach(rising: 5) < 6)
        let state = MegaObby.state()
        let pads = checkpoints(state)
        let safe: Set<String> = ["Jump", "Zig", "Beam", "FadeTile", "Pillar", "Walkway", "Ledge", "Disc", "Mover", "Launch",
                                 "Landing"]
        var problems: [String] = []
        for stage in 1...60 {
            guard let group = state.groups.first(where: { $0.name == "Stage\(stage)" }), let from = pads[stage],
                  let to = stage < 60 ? pads[stage + 1] : state.parts.first(where: { $0.name == "Victory" }) else {
                problems.append("stage \(stage) is missing")
                continue
            }
            let inside = state.parts.filter { $0.parentID == group.id }
            let truss = inside.first { $0.name == "Truss" }
            let launcher = inside.first { $0.name == "JumpPad" }
            var steps = inside.filter { safe.contains($0.name) }.map { part -> Foothold in
                let offset = state.dataObjects.first { $0.name == "Offset" && $0.parent == .node(part.id) }?.numbers ?? []
                return foothold(part, sweep: offset.count == 3 ? Vec3(Float(offset[0]), Float(offset[1]), Float(offset[2])) : .zero)
            }
            steps.sort { $0.z > $1.z }
            let path = [foothold(from)] + steps + [foothold(to)]
            for (a, b) in zip(path, path.dropFirst()) {
                let gap = simd_max(simd_max(a.low - b.high, b.low - a.high), .zero)
                let distance = simd_length(gap)
                let rise = b.top - a.top
                if let truss, a.name == "Walkway", b.name == "Ledge" {
                    // Up the truss.
                    if rise > truss.size.y + 0.5 { problems.append("stage \(stage): the truss is too short") }
                    continue
                }
                if launcher != nil, a.name == "Launch", b.name == "Landing" {
                    // The jump pad's launch: power 95 is about 23 studs up.
                    let v: Float = 95, g = CharacterController.gravity
                    let airborne = (v + sqrt(v * v - 2 * g * rise)) / g
                    if distance > CharacterController.walkSpeed * airborne * 0.8 {
                        problems.append("stage \(stage): the jump pad can't reach the landing (\(distance))")
                    }
                    continue
                }
                if rise > 5.5 || distance > reach(rising: max(rise, -4)) {
                    problems.append("stage \(stage) \(a.name)→\(b.name): \(String(format: "%.1f", distance)) across, "
                        + "\(String(format: "%.1f", rise)) up")
                }
            }
        }
        check("every gap in all sixty stages is within a jump", problems.isEmpty,
              problems.prefix(6).joined(separator: "; "))
    }

    // MARK: - Playing

    private static func value(_ model: SceneModel, _ name: String, of player: Int = 0) -> DataObject? {
        model.dataObjects.first { object in
            guard object.name == name, case .node(let folder) = object.parent else { return false }
            return model.dataObjects.first { $0.id == folder }?.parent == .player(player)
        }
    }

    private static func pad(_ model: SceneModel, _ stage: Int) -> Vec3 {
        checkpoints(model.state)[stage]?.position ?? .zero
    }

    private static func teleport(_ session: PlayController, onto spot: Vec3) {
        session.character.position = spot + Vec3(0, 0.6, 0)
        session.character.velocity = .zero
    }

    private static func gui(_ session: PlayController, _ name: String) -> GuiObject? {
        session.gui.objects.values.first { $0.name == name }
    }

    private static func press(_ session: PlayController, _ key: String) {
        session.key(key, pressed: true)
        session.step(dt: frame)
        session.key(key, pressed: false)
        step(session, seconds: 0.2)
    }

    private static func testPlaying(_ check: Checker) {
        print("\nMega Obby: playing")
        let model = SceneModel()
        model.loadMegaObby()
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        step(session, seconds: 0.6)
        check("you start at stage 1", value(model, "Stage")?.number == 1 && value(model, "Current")?.number == 1
              && simd_distance(session.character.position, pad(model, 1)) < 6 && said(session, .error).isEmpty,
              "\(session.character.position) \(said(session, .error))")
        check("…and the screen says so", gui(session, "StageLabel")?.text == "Stage 1 / 60",
              "\(String(describing: gui(session, "StageLabel")?.text))")

        teleport(session, onto: pad(model, 5))
        step(session, seconds: 0.3)
        check("a checkpoint is your stage", value(model, "Stage")?.number == 5 && gui(session, "Banner")?.text == "Stage 5!",
              "\(String(describing: value(model, "Stage")?.number)) \(String(describing: gui(session, "Banner")?.text))")
        teleport(session, onto: pad(model, 11))
        step(session, seconds: 3)
        check("a new world says its name", value(model, "Stage")?.number == 11
              && gui(session, "WorldLabel")?.text == "World 2: Lava Caves",
              "\(String(describing: gui(session, "WorldLabel")?.text))")

        // A kill brick: back at your checkpoint.
        if let kill = model.parts.first(where: { $0.name == "KillBrick" }) {
            session.character.position = kill.position + Vec3(0, kill.size.y / 2, 0)
            session.character.velocity = .zero
            step(session, seconds: 0.3)
            check("a kill brick knocks you out", session.humanoid.isDead)
            step(session, seconds: 1.5)
            check("…and you're back at your checkpoint, a death counted", !session.humanoid.isDead
                  && simd_distance(session.character.position, pad(model, 11)) < 6 && value(model, "Deaths")?.number == 1,
                  "\(session.character.position)")
        }

        // The stage picker.
        press(session, "Q")
        step(session, seconds: 0.2)
        check("Q goes back a stage", value(model, "Current")?.number == 10
              && simd_distance(session.character.position, pad(model, 10)) < 6, "\(session.character.position)")
        press(session, "E")
        press(session, "E")
        step(session, seconds: 0.2)
        check("E goes on, but not past the furthest you've been", value(model, "Current")?.number == 11
              && simd_distance(session.character.position, pad(model, 11)) < 6)

        // The mechanics.
        let fade = model.parts.first { $0.name == "FadeTile" }!
        teleport(session, onto: fade.position + Vec3(0, fade.size.y / 2, 0))
        step(session, seconds: 0.8)
        check("a fading tile gives way", model.part(id: fade.id)?.canCollide == false)
        teleport(session, onto: pad(model, 11))
        step(session, seconds: 2.8)
        check("…and comes back", model.part(id: fade.id)?.canCollide == true)
        let mover = model.parts.first { $0.name == "Mover" }!
        step(session, seconds: 0.5)
        check("movers move", simd_distance(model.part(id: mover.id)?.position ?? .zero, mover.position) > 0.5)
        let spinner = model.parts.first { $0.name == "Spinner" }!
        step(session, seconds: 0.3)
        check("spinners spin", model.part(id: spinner.id)?.rotationDegrees != spinner.rotationDegrees)
        let jump = model.parts.first { $0.name == "JumpPad" }!
        teleport(session, onto: jump.position + Vec3(0, jump.size.y / 2, 0))
        step(session, seconds: 0.25)
        check("jump pads throw you up", session.character.position.y > jump.position.y + 6, "\(session.character.position)")

        // R: back to your checkpoint.
        step(session, seconds: 1)
        teleport(session, onto: pad(model, 11) + Vec3(0, 0, -20))
        press(session, "R")
        step(session, seconds: 0.4)
        check("R takes you back to your checkpoint", simd_distance(session.character.position, pad(model, 11)) < 6,
              "\(session.character.position)")

        // The finish.
        teleport(session, onto: pad(model, 60))
        step(session, seconds: 0.3)
        let finish = model.parts.first { $0.name == "Finish" }!
        teleport(session, onto: finish.position)
        // The news takes turns: "Stage 60!" first.
        step(session, seconds: 2.6)
        check("the finish is a Win", value(model, "Wins")?.number == 1
              && gui(session, "Banner")?.text.hasPrefix("You beat all 60 stages in") == true,
              "\(String(describing: gui(session, "Banner")?.text))")
        check("no errors all the while", said(session, .error).isEmpty, "\(said(session, .error))")
        session.stop()
    }

    // MARK: - Together

    private static func testTogether(_ check: Checker) {
        print("\nMega Obby: a host and a joined player")
        let state = MegaObby.state()
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            let kept = model.scripts
            model.state = state
            model.scripts += kept
        }), let host = hosting.player, let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        let samID = sam.playerID
        let pads = checkpoints(state)
        LANSelfTest.run([hosting, joining], seconds: 1)
        sam.character.position = (pads[3]?.position ?? .zero) + Vec3(0, 0.6, 0)
        sam.character.velocity = .zero
        LANSelfTest.run([hosting, joining], seconds: 0.6)
        check("each player has their own stage", value(hosting.model, "Stage", of: samID)?.number == 3
              && value(hosting.model, "Stage", of: 0)?.number == 1 && value(joining.model, "Stage", of: samID)?.number == 3)
        if let kill = state.parts.first(where: { $0.name == "KillBrick" }) {
            sam.character.position = kill.position + Vec3(0, kill.size.y / 2, 0)
            sam.character.velocity = .zero
            LANSelfTest.run([hosting, joining], seconds: 2.2)
            check("a joined player knocked out comes back at their own checkpoint",
                  !sam.humanoid.isDead && simd_distance(sam.character.position, pads[3]?.position ?? .zero) < 6,
                  "\(sam.character.position)")
        }
        sam.key("Q", pressed: true)
        LANSelfTest.run([hosting, joining], seconds: 0.05)
        sam.key("Q", pressed: false)
        LANSelfTest.run([hosting, joining], seconds: 0.5)
        check("…and their stage picker is theirs", value(hosting.model, "Current", of: samID)?.number == 2
              && value(hosting.model, "Current", of: 0)?.number == 1)
        let errors = said(host, .error) + said(sam, .error)
        check("…with no errors on either", errors.isEmpty, "\(errors)")
        joining.leaveGame()
        hosting.leaveGame()
    }
}
