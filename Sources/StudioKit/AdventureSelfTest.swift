import Foundation
import Metal
import simd

/// Verification for Adventure Island, the sample game: the place as built (its areas,
/// scripts, shaders compiling, saving), then played — talking to NPCs, zones and their
/// screen effects, swimming, gems, the baker's trade, the Obby Tower (lava, checkpoints,
/// the jump pad, the trophy), the Mirror Lab's ray-tracing lever, NPCs turning to face
/// you — alone, and with a host and a joined player.
enum AdventureSelfTest {

    static func run(check: Checker) {
        testPlace(check)
        testPlaying(check)
        testObbyAndLab(check)
        testTwoPlayers(check)
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

    private static func press(_ session: PlayController, _ key: String) {
        session.key(key, pressed: true)
        session.step(dt: frame)
        session.key(key, pressed: false)
        step(session, seconds: 0.1)
    }

    /// A GUI object on this player's screen, by name.
    private static func gui(_ session: PlayController, _ name: String) -> GuiObject? {
        session.gui.descendants(of: 0).compactMap(session.gui.object).first { $0.name == name }
    }

    private static func part(_ model: SceneModel, _ name: String, in group: String? = nil) -> Part? {
        let parent = group.flatMap { name in model.groups.first { $0.name == name }?.id }
        return model.parts.first { $0.name == name && (group == nil || $0.parentID == parent) }
    }

    private static func stat(_ model: SceneModel, _ name: String, of player: Int = 0) -> Double? {
        guard let folder = model.dataObjects.first(where: { $0.name == "leaderstats" && $0.parent == .player(player) })
        else { return nil }
        return model.dataObjects.first { $0.name == name && $0.parent == .node(folder.id) }?.number
    }

    private static func effects(_ model: SceneModel) -> [String] { model.activeScreenShaders.map(\.name) }

    /// Puts the character somewhere, at rest.
    private static func teleport(_ session: PlayController, to feet: Vec3) {
        session.character.position = feet
        session.character.velocity = .zero
    }

    // MARK: - The place

    private static func testPlace(_ check: Checker) {
        print("\nAdventure Island: the place")
        let state = AdventureIsland.state()
        let groups = Set(state.groups.map(\.name))
        check("it has its areas: plaza, village, obby, lab, caves, garden, lake, lighthouse, woods, NPCs, gems, signs",
              ["Plaza", "Village", "Obby", "MirrorLab", "CrystalCaves", "DreamGarden", "Lake", "Lighthouse", "Woods",
               "NPCs", "Gems", "Signs"].allSatisfy(groups.contains), "\(groups.sorted())")
        let npcs = state.groups.filter { group in state.groups.first { $0.name == "NPCs" }?.id == group.parentID }
        check("eight NPCs, each a Model of body parts with a Torso to turn by",
              npcs.count == 8 && npcs.allSatisfy { npc in
                  npc.primaryPartID.flatMap { id in state.parts.first { $0.id == id } }?.name == "Torso"
              }, "\(npcs.map(\.name))")
        check("five gems, and a few hundred parts", state.parts.filter { $0.name.hasSuffix("Gem") }.count == 5
              && (300...900).contains(state.parts.count), "\(state.parts.count)")
        check("its scripts: two modules, four server scripts, a LocalScript, and the HUD's",
              state.scripts.filter(\.isModule).count == 2 && state.scripts.filter { $0.name == "Adventure" }.count == 1
              && ["GameScript", "ObbyScript", "LabScript", "NPCBrain", "Ambience"].allSatisfy { name in
                  state.scripts.contains { $0.name == name }
              } && !state.scripts.contains { $0.name == DefaultHud.keysScriptName })
        check("remotes in ReplicatedStorage, a BindableEvent in ServerStorage, a chime in SoundService",
              state.dataObjects.contains { $0.name == "Notify" && $0.className == .remoteEvent }
              && state.dataObjects.contains { $0.name == "Quest" && $0.className == .remoteFunction }
              && state.dataObjects.contains { $0.name == "Reward" && $0.parent == .serverStorage }
              && state.sounds.contains { $0.name == "Chime" } && state.assets.contains { $0.name == "Chime" })

        var problems: [String] = []
        if let device = MTLCreateSystemDefaultDevice() {
            for shader in state.shaders {
                do {
                    _ = try device.makeLibrary(source: ShaderSource.wrap(shader), options: nil)
                } catch {
                    problems.append("\(shader.name): \(error.localizedDescription.prefix(300))")
                }
            }
        }
        check("its seven shaders all compile", state.shaders.count == 7 && problems.isEmpty, problems.joined(separator: " | "))

        let saved = try? JSONEncoder().encode(state)
        let reopened = saved.flatMap { try? JSONDecoder().decode(SceneState.self, from: $0) }
        check("it saves and opens again unchanged", reopened == state)
        let model = SceneModel()
        model.loadAdventureIsland()
        check("Studio opens it, with nothing to undo", model.parts.count == state.parts.count && model.undoCount == 0
              && model.shaders.count == 7)
        var spawn = CharacterController()
        spawn.chooseSpawn(in: model.parts)
        check("players start on the plaza", abs(spawn.position.y - 0.9) < 0.05, "\(spawn.position)")
    }

    // MARK: - Playing

    private static func play() -> (SceneModel, PlayController) {
        let model = SceneModel()
        model.loadAdventureIsland()
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        step(session, seconds: 0.5)
        return (model, session)
    }

    private static func testPlaying(_ check: Checker) {
        print("\nAdventure Island: exploring")
        let (model, session) = play()
        check("the game starts with no errors, and says it's open",
              said(session, .error).isEmpty && said(session).contains("Adventure Island is open."),
              "\(said(session, .error))")
        check("the player gets leaderstats: Gems and Wins", stat(model, "Gems") == 0 && stat(model, "Wins") == 0)
        step(session, seconds: 1.6)
        check("…and a welcome", gui(session, "Banner")?.text == "Welcome to Adventure Island!",
              "\(String(describing: gui(session, "Banner")?.text))")

        // Talking to Guide Pip.
        teleport(session, to: Vec3(-6, 0.4, 18))
        step(session, seconds: 0.3)
        check("near an NPC, a prompt says who to talk to", gui(session, "Prompt")?.visible == true
              && gui(session, "Prompt")?.text == "[E]  Talk to Guide Pip", "\(String(describing: gui(session, "Prompt")?.text))")
        press(session, "E")
        step(session, seconds: 1.2)
        check("E opens the dialogue: their name, their words typed out, and choices",
              gui(session, "Dialogue")?.visible == true && gui(session, "Speaker")?.text == "Guide Pip"
              && gui(session, "Words")?.text.hasPrefix("Hi Player, welcome to Adventure Island!") == true
              && gui(session, "Choice1")?.text == "1.  What is there to do?" && gui(session, "Prompt")?.visible == false,
              "\(String(describing: gui(session, "Words")?.text))")
        press(session, "One")
        step(session, seconds: 1.5)
        check("a number key picks an answer, and they go on",
              gui(session, "Words")?.text.hasPrefix("Find the five gems") == true,
              "\(String(describing: gui(session, "Words")?.text))")
        teleport(session, to: Vec3(-6, 0.4, 40))
        step(session, seconds: 0.3)
        check("walking away ends the talk", gui(session, "Dialogue")?.visible == false)

        // NPCs turn to face you.
        let pip = model.groups.first { $0.name == "Guide Pip" }!
        let before = model.part(id: pip.primaryPartID!)!.orientation
        teleport(session, to: Vec3(4, 0.4, 14))
        step(session, seconds: 1)
        let after = model.part(id: pip.primaryPartID!)!.orientation
        let facing = model.part(id: pip.primaryPartID!)!.frameMatrix * Vec4(0, 0, -1, 0)
        check("NPCs turn to face a player nearby", simd_angle(simd_mul(after, simd_inverse(before))) > 0.5 && facing.x > 0.8,
              "\(facing)")

        // Zones and their effects.
        teleport(session, to: Vec3(0, 0.4, -100))
        step(session, seconds: 0.4)
        check("the Crystal Caves turn on Cave Glow, and a banner names them",
              effects(model) == ["Cave Glow"] && gui(session, "Banner")?.text == "Crystal Caves", "\(effects(model))")
        teleport(session, to: Vec3(-80, 0.3, 84))
        step(session, seconds: 0.4)
        check("the Dream Garden, Dreamy instead", effects(model) == ["Dreamy"], "\(effects(model))")
        teleport(session, to: Vec3(0, 0.4, 10))
        step(session, seconds: 0.4)
        check("…and back on the plaza, no effect", effects(model).isEmpty && model.screenShaderIDs.isEmpty,
              "\(effects(model))")
        teleport(session, to: Vec3(82, 1, 80))
        step(session, seconds: 0.6)
        check("swimming in the lake tints the screen Underwater",
              session.humanoid.state == .swimming && effects(model) == ["Underwater"], "\(session.humanoid.state) \(effects(model))")

        // A gem, and the baker's trade.
        let gem = part(model, "CaveGem")!
        teleport(session, to: Vec3(0, 0.4, -106))
        step(session, seconds: 0.4)
        teleport(session, to: gem.position - Vec3(0, 2.5, 0))
        step(session, seconds: 0.3)
        check("touching a gem: +1 Gem, it vanishes, and a banner says so",
              stat(model, "Gems") == 1 && model.part(id: gem.id)?.transparency == 1
              && gui(session, "Banner")?.text == "You found a gem! (1)", "\(String(describing: stat(model, "Gems")))")
        teleport(session, to: Vec3(0, 0, 92))
        step(session, seconds: 0.3)
        press(session, "E")
        press(session, "One")
        step(session, seconds: 1.5)
        check("Baker Bo wants three gems", gui(session, "Words")?.text.hasPrefix("Three gems, please!") == true,
              "\(String(describing: gui(session, "Words")?.text))")
        if let folder = model.dataObjects.first(where: { $0.name == "leaderstats" }),
           let gems = model.dataObjects.first(where: { $0.name == "Gems" && $0.parent == .node(folder.id) }) {
            model.updateDataObject(id: gems.id) { $0.number = 3 }
        }
        press(session, "E")
        press(session, "E")
        press(session, "One")
        step(session, seconds: 1.5)
        check("…and with three, trades them for a crown the character wears",
              stat(model, "Gems") == 0 && session.look.accessories.contains { $0.item == "builtin://Crown" }
              && gui(session, "Words")?.text.hasPrefix("A fair trade!") == true,
              "\(String(describing: gui(session, "Words")?.text)) \(session.look.accessories.map(\.name))")
        _ = session.playerInvoke("player.load", [])
        step(session, seconds: 0.3)
        check("…and wears it again after respawning", session.look.accessories.contains { $0.item == "builtin://Crown" })
        check("…with no errors", said(session, .error).isEmpty, "\(said(session, .error))")
        session.stop()
    }

    private static func testObbyAndLab(_ check: Checker) {
        print("\nAdventure Island: the Obby Tower and the Mirror Lab")
        let (model, session) = play()
        let start = part(model, "Start", in: "Obby")!
        teleport(session, to: start.position + Vec3(0, 0.5, 0))
        step(session, seconds: 0.3)
        let pad = part(model, "Checkpoint1", in: "Obby")!
        teleport(session, to: pad.position + Vec3(0, 0.2, 0))
        step(session, seconds: 0.3)
        check("a checkpoint says so", gui(session, "Banner")?.text == "Checkpoint 1!",
              "\(String(describing: gui(session, "Banner")?.text))")
        teleport(session, to: Vec3(-66, 1, 16))
        step(session, seconds: 0.3)
        check("the lava knocks you out", session.humanoid.isDead)
        step(session, seconds: 2.6)
        check("…and you're back at your checkpoint",
              !session.humanoid.isDead && simd_distance(session.character.position, pad.position) < 5,
              "\(session.character.position)")
        let jump = part(model, "JumpPad", in: "Obby")!
        teleport(session, to: jump.position)
        step(session, seconds: 0.2)
        check("the jump pad throws you up", session.character.velocity.y > 40 || session.character.position.y > jump.position.y + 6,
              "\(session.character.velocity) \(session.character.position)")
        // Somewhere quiet while the news so far has its turn on the banner.
        teleport(session, to: start.position + Vec3(0, 0.5, 0))
        step(session, seconds: 6)
        let trophy = part(model, "Trophy", in: "Obby")!
        teleport(session, to: trophy.position - Vec3(0, 3, 0))
        step(session, seconds: 0.3)
        check("the trophy is a Win, with your time, and a party hat",
              stat(model, "Wins") == 1 && session.look.accessories.contains { $0.item == "builtin://PartyHat" }
              && gui(session, "Banner")?.text.hasPrefix("You beat the Obby Tower in") == true,
              "\(String(describing: stat(model, "Wins"))) \(String(describing: gui(session, "Banner")?.text))")
        step(session, seconds: 2.4)
        check("…the news taking turns on the banner", gui(session, "Banner")?.text == "A party hat for the champion!",
              "\(String(describing: gui(session, "Banner")?.text))")
        step(session, seconds: 1)
        check("…then it's back down to the start", simd_distance(session.character.position, start.position) < 6,
              "\(session.character.position)")

        let mover = part(model, "Mover", in: "Obby")!
        let spinner = part(model, "Spinner", in: "Obby")!
        step(session, seconds: 1)
        check("the mover glides and the spinner spins",
              simd_distance(model.part(id: mover.id)!.position, mover.position) > 0.5
              && simd_angle(simd_mul(model.part(id: spinner.id)!.orientation, simd_inverse(spinner.orientation))) > 0.3)

        let lever = part(model, "Lever", in: "MirrorLab")!
        teleport(session, to: Vec3(69, 0.4, 10))
        step(session, seconds: 0.2)
        session.queueClick(lever.id, by: 0, "MouseClick")
        step(session, seconds: 0.3)
        check("the lab's lever switches the island to ray tracing",
              model.lighting.technology == .rayTraced
              && model.part(id: part(model, "StatusLight", in: "MirrorLab")!.id)!.color.y > 0.9,
              "\(model.lighting.technology)")
        check("…and its sign says so", session.gui.descendants(of: 0).compactMap(session.gui.object)
            .contains { $0.text.hasPrefix("Ray tracing: ON") })
        session.queueClick(lever.id, by: 0, "MouseClick")
        step(session, seconds: 0.3)
        check("…and back", model.lighting.technology == .conventional)
        let lamp = part(model, "Lamp1", in: "MirrorLab")!
        session.queueClick(part(model, "ShowButton", in: "MirrorLab")!.id, by: 0, "MouseClick")
        step(session, seconds: 0.2)
        check("the red button changes the lamps' colours",
              model.part(id: lamp.id)?.color != lamp.color && model.part(id: lamp.id)?.light?.color != lamp.light?.color)
        check("…with no errors", said(session, .error).isEmpty, "\(said(session, .error))")
        session.stop()
    }

    // MARK: - Two players

    private static func testTwoPlayers(_ check: Checker) {
        print("\nAdventure Island: a host and a joined player")
        let island = AdventureIsland.state()
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            model.state = island
        }), let host = hosting.player, let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 1.5)
        check("both play with no errors, and each has leaderstats on the host",
              host.console.lines.filter { $0.kind == .error }.isEmpty && sam.console.lines.filter { $0.kind == .error }.isEmpty
              && stat(host.model, "Gems", of: 0) == 0 && stat(host.model, "Gems", of: 1) == 0,
              "\(host.console.lines.filter { $0.kind == .error }.map(\.text)) \(sam.console.lines.filter { $0.kind == .error }.map(\.text))")

        // The joined player talks to Guide Pip, on their own screen.
        teleport(sam, to: Vec3(-6, 0.4, 18))
        LANSelfTest.run([hosting, joining], seconds: 0.3)
        sam.key("E", pressed: true)
        LANSelfTest.run([hosting, joining], seconds: 0.05)
        sam.key("E", pressed: false)
        LANSelfTest.run([hosting, joining], seconds: 1.2)
        check("a joined player talks to an NPC on their own screen",
              gui(sam, "Dialogue")?.visible == true && gui(sam, "Words")?.text.hasPrefix("Hi Sam") == true
              && gui(host, "Dialogue")?.visible == false, "\(String(describing: gui(sam, "Words")?.text))")

        // Their zone's effect is theirs alone.
        teleport(sam, to: Vec3(0, 0.4, -100))
        LANSelfTest.run([hosting, joining], seconds: 0.6)
        check("the caves' screen effect is on the joined player's screen, not the host's",
              effects(sam.model) == ["Cave Glow"] && effects(host.model).isEmpty,
              "\(effects(sam.model)) \(effects(host.model))")

        // A gem the joined player finds is theirs, as the host keeps score.
        let gem = part(host.model, "CaveGem")!
        teleport(sam, to: gem.position - Vec3(0, 2.5, 0))
        LANSelfTest.run([hosting, joining], seconds: 0.8)
        check("a gem found by the joined player counts for them, and they're told",
              stat(host.model, "Gems", of: 1) == 1 && stat(host.model, "Gems", of: 0) == 0
              && gui(sam, "Banner")?.text == "You found a gem! (1)", "\(String(describing: stat(host.model, "Gems", of: 1)))")

        // The host pulls the lab's lever: everyone's lighting changes.
        let lever = part(host.model, "Lever", in: "MirrorLab")!
        host.queueClick(lever.id, by: 0, "MouseClick")
        LANSelfTest.run([hosting, joining], seconds: 0.5)
        check("the lever switches ray tracing for everyone",
              host.model.lighting.technology == .rayTraced && sam.model.lighting.technology == .rayTraced)
        check("…with no errors on either", host.console.lines.filter { $0.kind == .error }.isEmpty
              && sam.console.lines.filter { $0.kind == .error }.isEmpty,
              "\(host.console.lines.filter { $0.kind == .error }.map(\.text)) \(sam.console.lines.filter { $0.kind == .error }.map(\.text))")
        hosting.leaveGame()
        joining.leaveGame()
    }
}
