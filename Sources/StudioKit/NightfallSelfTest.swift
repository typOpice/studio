import Foundation
import Metal
import simd

/// Nightfall, played: the place and its scripts; a day, a night of zombies that chase
/// and bite, the sword and the blaster, orbs and the power-up choice, the keys and the
/// gate, escaping, falling and a new run; and a host and a joined player together.
enum NightfallSelfTest {
    static func run(check: Checker) {
        // Best scores are saved; each test starts with none (DataStoreSelfTest checks the saving).
        let fresh = { DataStoreFiles.shared.clear(place: Nightfall.placeID) }
        testPlace(check)
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

    // MARK: - The place

    private static func testPlace(_ check: Checker) {
        print("\nNightfall: the place")
        let state = Nightfall.state()
        let groups = Set(state.groups.map(\.name))
        check("it has its areas", ["Camp", "Town", "Graveyard", "Forest", "Farm", "Mine", "Ruins", "Gate", "Walls"]
            .allSatisfy(groups.contains), "\(groups.sorted())")
        check("the zombies, the key and the blaster are kept in ServerStorage",
              ["Walker", "Runner", "Brute", "Key", "Blaster"].allSatisfy { name in
                  state.groups.contains { $0.name == name && $0.storage == .serverStorage }
              })
        check("everyone starts with a sword", state.groups.contains { $0.name == "Sword" && $0.tool?.place == .starterPack })
        let scripts = Set(state.scripts.map(\.name))
        check("its scripts", ["GameScript", "Horde", "Upgrades", "Ambience", "SwordScript", "Nightfall", "Utils"]
            .allSatisfy(scripts.contains), "\(scripts.sorted())")
        check("key spots and spawn points", state.parts.filter { $0.parentID == state.groups.first { $0.name == "KeySpots" }?.id }
            .count >= 10 && state.parts.filter { $0.parentID == state.groups.first { $0.name == "SpawnPoints" }?.id }.count >= 16)
        if let device = MTLCreateSystemDefaultDevice() {
            let failed = state.shaders.filter { shader in
                (try? device.makeLibrary(source: ShaderSource.wrap(shader), options: nil)) == nil
            }.map(\.name)
            check("its four shaders compile", failed.isEmpty && state.shaders.count == 4, "\(failed)")
        }
    }

    // MARK: - Playing

    private static func value(_ model: SceneModel, _ name: String) -> DataObject? {
        model.dataObjects.first { $0.name == name }
    }

    /// The zombies in the world: each Model in workspace.Zombies, and where it is.
    static func zombies(_ model: SceneModel) -> [(id: UUID, position: Vec3)] {
        guard let folder = model.groups.first(where: { $0.name == "Zombies" && $0.kind == .folder }) else { return [] }
        return model.groups.filter { $0.parentID == folder.id }.compactMap { group in
            model.pivot(of: group.id).map { (group.id, $0.position) }
        }
    }

    /// A place ready to play fast: a one-second day, a two-second dawn, two zombies a night.
    static func quick(_ model: SceneModel, day: Double = 1) {
        model.loadTemplate(.nightfall)
        for (name, number) in [("DayLength", day), ("DawnLength", 2), ("FirstNight", 2), ("MorePerNight", 0)] {
            if let id = value(model, name)?.id { model.updateDataObject(id: id) { _ = $0.setValue(.number(number)) } }
        }
    }

    private static func gui(_ session: PlayController, _ name: String) -> GuiObject? {
        session.gui.objects.values.first { $0.name == name }
    }

    /// A GUI object inside another, by both names: the HUD has a Title of its own.
    private static func gui(_ session: PlayController, _ name: String, in parent: String) -> GuiObject? {
        guard let outer = gui(session, parent) else { return nil }
        return session.gui.objects.values.first { $0.name == name && $0.parent == outer.id }
    }

    static func press(_ session: PlayController, _ key: String) {
        session.key(key, pressed: true)
        session.step(dt: frame)
        session.key(key, pressed: false)
        step(session, seconds: 0.1)
    }

    private static func click(_ session: PlayController) {
        session.mouseButton(1, pressed: true)
        step(session, seconds: 0.05)
        session.mouseButton(1, pressed: false)
        step(session, seconds: 0.05)
    }

    /// Puts a zombie somewhere, facing the player; the Horde reads where it is each tick.
    private static func place(_ model: SceneModel, zombie id: UUID, at spot: Vec3) {
        guard let pivot = model.pivot(of: id) else { return }
        model.movePivot(of: id, to: Pose(position: Vec3(spot.x, pivot.position.y, spot.z), orientation: pivot.orientation))
    }

    private static func teleport(_ session: PlayController, to feet: Vec3) {
        session.character.position = feet
        session.character.velocity = .zero
    }

    /// Swings at a zombie right in front (the way a still player faces, −Z) until it falls.
    static func slay(_ session: PlayController, _ model: SceneModel, zombie id: UUID) -> Bool {
        for _ in 0..<12 {
            guard model.group(id: id) != nil else { return true }
            place(model, zombie: id, at: session.character.position + Vec3(0, 0, -3))
            click(session)
            step(session, seconds: 0.5)
        }
        return model.group(id: id) == nil
    }

    private static func testPlaying(_ check: Checker) {
        print("\nNightfall: playing")
        let model = SceneModel()
        quick(model)
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        step(session, seconds: 0.5)
        check("it starts without errors, by day", said(session, .error).isEmpty && value(model, "Phase")?.text == "day",
              "\(said(session, .error)) \(String(describing: value(model, "Phase")?.text))")
        check("three keys are hidden", value(model, "KeysNeeded")?.number == 3
              && model.groups.filter { $0.name == "Key" && $0.storage == nil }.count == 3)
        check("the sword is on the hotbar", model.tools(of: 0).map(\.name) == ["Sword"])
        step(session, seconds: 1.5)
        let night = zombies(model)
        check("night falls, and zombies come", value(model, "Phase")?.text == "night" && value(model, "Night")?.number == 1
              && night.count == 2, "\(String(describing: value(model, "Phase")?.text)) \(night.count)")
        check("…and the screen says so", gui(session, "Phase")?.text.hasPrefix("NIGHT 1") == true,
              "\(String(describing: gui(session, "Phase")?.text))")
        func nearest() -> Float {
            zombies(model).map { simd_distance(SIMD2($0.position.x, $0.position.z),
                                               SIMD2(session.character.position.x, session.character.position.z)) }.min() ?? .infinity
        }
        let before = nearest()
        step(session, seconds: 2)
        let after = nearest()
        check("they come for you", after < before - 5, "\(before) → \(after)")

        // A bite.
        let first = zombies(model)[0].id
        place(model, zombie: first, at: session.character.position + Vec3(2, 0, 0))
        step(session, seconds: 1.2)
        check("a zombie that reaches you bites", session.humanoid.health < 100, "\(session.humanoid.health)")

        // The sword.
        press(session, "One")
        check("1 holds the sword", model.heldTool(of: 0)?.name == "Sword")
        let slain = slay(session, model, zombie: first)
        check("the sword takes a zombie down", slain && value(model, "Kills")?.number == 1,
              "\(slain) \(String(describing: value(model, "Kills")?.number))")
        step(session, seconds: 0.6)
        check("…and it drops an orb, which comes to you", value(model, "Orbs")?.number == 1,
              "\(String(describing: value(model, "Orbs")?.number))")
        if let second = zombies(model).first?.id { _ = slay(session, model, zombie: second) }
        step(session, seconds: 0.5)
        check("the last one down, it's dawn", value(model, "Phase")?.text == "dawn",
              "\(String(describing: value(model, "Phase")?.text)) \(zombies(model).count)")
        check("…with a choice of three power-ups", gui(session, "Chooser")?.visible == true
              && ["Card1", "Card2", "Card3"].allSatisfy { gui(session, $0)?.visible == true })
        let offered = gui(session, "Heading", in: "Card1")?.text ?? ""
        press(session, "Z")
        step(session, seconds: 0.2)
        let picks = value(model, "Picks")?.text ?? ""
        check("Z takes the first", gui(session, "Chooser")?.visible == false && !picks.isEmpty
              && offered.hasPrefix(picks.components(separatedBy: ",")[0]), "offered \(offered), took \(picks)")

        // The blaster, from the armory.
        teleport(session, to: Vec3(95, 0.5, 69))
        step(session, seconds: 0.3)
        check("the armory gives you the blaster", model.tools(of: 0).map(\.name).sorted() == ["Blaster", "Sword"],
              "\(model.tools(of: 0).map(\.name))")
        press(session, "Two")
        check("2 holds it", model.heldTool(of: 0)?.name == "Blaster")
        step(session, seconds: 2.2)
        check("night 2 comes", value(model, "Night")?.number == 2 && zombies(model).count >= 1,
              "\(String(describing: value(model, "Night")?.number)) \(zombies(model).count)")
        if let target = zombies(model).first?.id {
            let camera = session.renderCamera
            let ahead = normalize(camera.target - camera.position)
            let spot = camera.target + ahead * 12
            place(model, zombie: target, at: spot)
            step(session, seconds: 0.05)
            let torso = model.parts.first { $0.parentID == target && $0.name == "Torso" }?.position ?? spot
            session.viewSize = SIMD2(1200, 800)
            if let point = session.screenPoint(of: torso, in: CGSize(width: 1200, height: 800)) {
                session.pointer = SIMD2(Float(point.x), Float(point.y))
            }
            let health = { model.dataObjects.first { $0.name == "Health" && $0.parent == .node(target) }?.number }
            let full = health()
            click(session)
            step(session, seconds: 0.1)
            check("the blaster shoots where you point", full != nil && (health() ?? 999) < full!,
                  "\(String(describing: full)) → \(String(describing: health()))")
        }

        // The keys, and the gate.
        let keys = model.groups.filter { $0.name == "Key" && $0.storage == nil }.map(\.id)
        for (index, key) in keys.enumerated() {
            if let spot = model.pivot(of: key)?.position {
                teleport(session, to: spot - Vec3(0, 1.5, 0))
                step(session, seconds: 0.3)
            }
            if index < 2 {
                check("key \(index + 1) found", value(model, "KeysFound")?.number == Double(index + 1),
                      "\(String(describing: value(model, "KeysFound")?.number))")
            }
        }
        step(session, seconds: 2.2)
        let doors = model.parts.first { $0.name == "DoorLeft" }?.position.x ?? 0
        check("the third opens the north gate", value(model, "GateOpen")?.flag == true && doors < -10,
              "\(String(describing: value(model, "GateOpen")?.flag)) \(doors)")
        teleport(session, to: Vec3(0, 0.6, 206))
        step(session, seconds: 0.4)
        check("through it, you've escaped", gui(session, "RunOver")?.visible == true
              && gui(session, "Title", in: "RunOver")?.text == "You escaped!" && (value(model, "Best")?.number ?? 0) >= 1000,
              "\(String(describing: gui(session, "Title", in: "RunOver")?.text)) \(String(describing: value(model, "Best")?.number))")
        check("…the world starts again, and so does your run", value(model, "KeysFound")?.number == 0
              && value(model, "Night")?.number == 0 && value(model, "Phase")?.text == "day"
              && value(model, "Picks")?.text == "" && model.tools(of: 0).map(\.name) == ["Sword"]
              && simd_distance(session.character.position, Vec3(0, 1, 18)) < 5,
              "\(String(describing: value(model, "Picks")?.text)) \(model.tools(of: 0).map(\.name)) \(session.character.position)")

        // Falling.
        step(session, seconds: 1.2)
        session.humanoid.takeDamage(1000)
        step(session, seconds: 0.3)
        check("falling ends the run", gui(session, "Title", in: "RunOver")?.text.hasPrefix("You fell on night") == true,
              "\(String(describing: gui(session, "Title", in: "RunOver")?.text))")
        step(session, seconds: 3.2)
        check("…and you're back for a new one", !session.humanoid.isDead && session.humanoid.walkSpeed == 16
              && value(model, "Kills")?.number == 0)
        check("no errors all the while", said(session, .error).isEmpty, "\(said(session, .error))")
        session.stop()
    }
    // MARK: - Together

    private static func testTogether(_ check: Checker) {
        print("\nNightfall: a host and a joined player")
        let prepared = SceneModel()
        quick(prepared, day: 2)
        let state = prepared.state
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            let kept = model.scripts
            model.state = state
            model.scripts += kept
        }), let host = hosting.player, let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        let samID = sam.playerID
        func stat(_ model: SceneModel, _ name: String, of player: Int) -> Double? {
            model.dataObjects.first { $0.name == name && inFolder(model, $0, of: player) }?.number
        }
        LANSelfTest.run([hosting, joining], seconds: 2.6)
        check("night falls for the joined player too", value(joining.model, "Phase")?.text == "night"
              && value(joining.model, "Night")?.number == 1, "\(String(describing: value(joining.model, "Phase")?.text))")
        check("…with the zombies in their world", zombies(joining.model).count == zombies(hosting.model).count
              && zombies(hosting.model).count >= 1, "\(zombies(joining.model).count) \(zombies(hosting.model).count)")

        // Sam's sword, run by the host's tool script.
        sam.key("One", pressed: true)
        LANSelfTest.run([hosting, joining], seconds: 0.05)
        sam.key("One", pressed: false)
        LANSelfTest.run([hosting, joining], seconds: 0.3)
        var down = false
        for _ in 0..<12 {
            guard let target = zombies(hosting.model).first?.id else { break }
            place(hosting.model, zombie: target, at: sam.character.position + Vec3(0, 0, -3))
            sam.mouseButton(1, pressed: true)
            LANSelfTest.run([hosting, joining], seconds: 0.05)
            sam.mouseButton(1, pressed: false)
            LANSelfTest.run([hosting, joining], seconds: 0.5)
            if stat(hosting.model, "Kills", of: samID) ?? 0 >= 1 {
                down = true
                break
            }
        }
        check("a joined player's sword takes a zombie down, and it counts for them", down
              && stat(joining.model, "Kills", of: samID) == 1, "\(String(describing: stat(joining.model, "Kills", of: samID)))")
        // The host takes the rest down, so dawn comes.
        host.key("One", pressed: true)
        LANSelfTest.run([hosting, joining], seconds: 0.05)
        host.key("One", pressed: false)
        LANSelfTest.run([hosting, joining], seconds: 0.2)
        for _ in 0..<12 {
            guard let target = zombies(hosting.model).first?.id else { break }
            place(hosting.model, zombie: target, at: host.character.position + Vec3(0, 0, -3))
            host.mouseButton(1, pressed: true)
            LANSelfTest.run([hosting, joining], seconds: 0.05)
            host.mouseButton(1, pressed: false)
            LANSelfTest.run([hosting, joining], seconds: 0.5)
        }
        LANSelfTest.run([hosting, joining], seconds: 0.3)
        let chooser = sam.gui.objects.values.first { $0.name == "Chooser" }
        check("at dawn the joined player is offered their own power-ups", value(hosting.model, "Phase")?.text == "dawn"
              && chooser?.visible == true, "\(String(describing: value(hosting.model, "Phase")?.text))")
        sam.key("Z", pressed: true)
        LANSelfTest.run([hosting, joining], seconds: 0.05)
        sam.key("Z", pressed: false)
        LANSelfTest.run([hosting, joining], seconds: 0.4)
        let samsPicks = hosting.model.dataObjects.first { $0.name == "Picks" && inFolder(hosting.model, $0, of: samID) }?.text
        check("…and their choice is theirs", samsPicks?.isEmpty == false, "\(String(describing: samsPicks))")

        // A key, found by the joined player, counts for everyone.
        if let key = hosting.model.groups.first(where: { $0.name == "Key" && $0.storage == nil })?.id,
           let spot = hosting.model.pivot(of: key)?.position {
            sam.character.position = spot - Vec3(0, 1.5, 0)
            sam.character.velocity = .zero
            LANSelfTest.run([hosting, joining], seconds: 0.5)
        }
        check("a key a joined player finds counts for everyone", value(hosting.model, "KeysFound")?.number == 1
              && value(joining.model, "KeysFound")?.number == 1)
        let errors = said(host, .error) + said(sam, .error)
        check("…with no errors on either", errors.isEmpty, "\(errors)")
        joining.leaveGame()
        hosting.leaveGame()
    }

    /// Whether a data object is in one of a player's folders (leaderstats, Run).
    private static func inFolder(_ model: SceneModel, _ object: DataObject, of player: Int) -> Bool {
        guard case .node(let folder) = object.parent else { return false }
        return model.dataObjects.first { $0.id == folder }?.parent == .player(player)
    }
}
