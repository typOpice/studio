import Foundation
import Network
import simd

enum RacingSelfTest {
    static func run(check: Checker) {
        let scene = Racing.state()
        check("Crash Circuit has four complete racing cars", scene.groups.filter { $0.name.hasPrefix("Racer") }.count == 4 && scene.parts.filter { $0.seat?.vehicle != nil }.count == 4)
        check("the circuit has eight ordered checkpoint gates and a solid start arch", scene.parts.filter { $0.name.hasPrefix("Gate") }.count == 8 && scene.parts.contains { $0.solid != nil })
        check("racing brings server rules and each player's dashboard", scene.scripts.contains { $0.name == "RaceRules" } && scene.scripts.contains { $0.name == "RaceDashboard" && $0.host == .starterPlayer })
        let data = try? JSONEncoder().encode(scene)
        check("Crash Circuit round-trips and is listed in both game catalogs", data.flatMap { try? JSONDecoder().decode(SceneState.self, from: $0) } == scene && PlaceTemplate.samples.contains(.racing))
        play(check, scene)
        vehicleImpact(check, scene)
        together(check)
        soak(check, scene)
    }
    static func step(_ player: PlayController, _ seconds: Float) {
        for _ in 0..<Int(seconds * 60) { player.step(dt: 1.0 / 60) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    static func group(_ model: SceneModel, _ number: Int) -> UUID { model.groups.first { $0.name == "Racer\(number)" }!.id }
    static func part(_ model: SceneModel, _ number: Int, _ name: String) -> Part { model.parts.first { $0.parentID == group(model, number) && $0.name == name }! }
    static func value(_ model: SceneModel, _ number: Int, _ name: String) -> Double { model.dataObjects.first { $0.parent == .node(group(model, number)) && $0.name == name }?.number ?? -1 }
    static func errors(_ player: PlayController) -> [String] { player.console.lines.filter { $0.kind == .error }.map(\.text) }
    static func play(_ check: Checker, _ scene: SceneState) {
        let model = SceneModel(); model.state = scene
        let player = PlayController(model: model, console: ScriptConsole()); player.start(); defer { player.stop() }
        let start = part(model, 1, "Body").position
        player.key("W", pressed: true); step(player, 2)
        check("the preview keeps its parts outside the shared physics world", model.parts.count == scene.parts.count, "\(model.parts.count) vs \(scene.parts.count)")
        check("countdown holds every car on the grid", simd_distance(part(model, 1, "Body").position, start) < 0.1 && (1...4).allSatisfy { part(model, $0, "Body").anchored })
        step(player, 2.3)
        check("Go releases the cars and the player is seated in their own", !(1...4).contains { part(model, $0, "Body").anchored } && player.seatPart == part(model, 1, "VehicleSeat").id, "seat \(String(describing: player.seatPart)); \(errors(player))")
        let npc = part(model, 4, "Body").position
        step(player, 2)
        check("W drives the player's car with its real motor hinges", part(model, 1, "Body").position.z < start.z - 20, "\(part(model, 1, "Body").position)")
        player.key("W", pressed: false)
        check("NPC racers drive themselves along the circuit", simd_distance(part(model, 4, "Body").position, npc) > 15, "\(part(model, 4, "Body").position)")
        check("the driving camera follows from outside the car", simd_distance(player.renderCamera.position, player.character.eyePosition) > 5 && simd_distance(player.renderCamera.target, part(model, 1, "Body").position) < 12, "\(player.renderCamera.position), \(player.renderCamera.target)")
        damageAndLaps(check, player)
        check("the race and each driver's preview/HUD run without errors", errors(player).isEmpty, "\(errors(player))")
    }

    static func launch(_ player: PlayController, car: Int, from position: Vec3, toward rotation: Float, velocity: Vec3) {
        let model = player.model, id = group(model, car)
        model.movePivot(of: id, to: Pose(position: position, orientation: simd_quatf(angle: rotation, axis: Vec3(0, 1, 0))))
        player.physics.sync(model.parts, constraints: model.constraints, attachments: model.attachments)
        for part in model.parts where part.parentID == id { player.physics.setVelocity(part.id, velocity); player.physics.setAngularVelocity(part.id, .zero) }
    }
    static func damageAndLaps(_ check: Checker, _ player: PlayController) {
        let model = player.model
        launch(player, car: 1, from: Vec3(109, 2.45, 0), toward: -.pi / 2, velocity: Vec3(52, 0, 0))
        step(player, 0.8)
        let health = value(model, 1, "Health")
        let hood = part(model, 1, "Hood")
        check("a real wall collision damages the car and releases a body panel", health < 100 && model.constraints.contains { $0.parentID == hood.id && !$0.enabled }, "health \(health), \(errors(player))")
        step(player, 8.2)
        check("NPC drivers reach ordered gates around the oval", value(model, 2, "NextGate") != 2 || value(model, 4, "NextGate") != 2, "\(value(model, 2, "NextGate")), \(value(model, 4, "NextGate"))")
        check("old crash debris is retired without adding objects", part(model, 1, "Hood").transparency == 1 && part(model, 1, "Hood").anchored)
        player.key("T", pressed: true); step(player, 0.1); player.key("T", pressed: false); step(player, 1.2)
        check("Recover restores health, panels and working joints", value(model, 1, "Health") == 100 && part(model, 1, "Hood").transparency == 0 && model.constraints.filter { $0.parentID == part(model, 1, "Hood").id }.allSatisfy(\.enabled))
        let expected = value(model, 1, "NextGate")
        let wrong = model.parts.first { $0.name == "Gate5" }!
        launch(player, car: 1, from: wrong.position + Vec3(0, 2.2, 0), toward: 0, velocity: .zero); step(player, 0.05)
        check("skipping a checkpoint cannot advance the lap", value(model, 1, "NextGate") == expected && value(model, 1, "Lap") == 1)
        for _ in 0..<24 {
            let next = Int(value(model, 1, "NextGate")), gate = model.parts.first { $0.name == "Gate\(next)" }!
            launch(player, car: 1, from: gate.position + Vec3(0, 2.2, 0), toward: 0, velocity: .zero); step(player, 0.05)
        }
        check("three ordered laps award a finish place", value(model, 1, "Lap") == 4 && value(model, 1, "Place") > 0, "lap \(value(model, 1, "Lap")), place \(value(model, 1, "Place"))")
    }

    static func soak(_ check: Checker, _ scene: SceneState) {
        let model = SceneModel(); model.state = scene
        let player = PlayController(model: model, console: ScriptConsole()); player.start(); defer { player.stop() }
        let result = Soak.play(player, seconds: 35, every: 5)
        check("35 seconds of driving, crashes and repeated recovery keeps the race bounded", result.errors.isEmpty && result.samples.count >= 6 && result.samples.last?.parts == scene.parts.count && SoakSelfTest.growth(from: result.samples[2], to: result.samples.last!).isEmpty, "\(result.errors.prefix(3))")
    }

    static func vehicleImpact(_ check: Checker, _ scene: SceneState) {
        let model = SceneModel(); model.state = scene
        let player = PlayController(model: model, console: ScriptConsole()); player.start(); defer { player.stop() }
        step(player, 4.5)
        let health1 = value(model, 1, "Health"), health2 = value(model, 2, "Health")
        launch(player, car: 1, from: Vec3(-10, 2.45, -75), toward: -.pi / 2, velocity: Vec3(35, 0, 0))
        launch(player, car: 2, from: Vec3(10, 2.45, -75), toward: .pi / 2, velocity: Vec3(-35, 0, 0))
        step(player, 0.7)
        check("ramming another car breaks both cars from relative impact speed", value(model, 1, "Health") < health1 && value(model, 2, "Health") < health2, "\(health1) -> \(value(model, 1, "Health")), \(health2) -> \(value(model, 2, "Health"))")
        check("crashes emit sparks and smoke without script errors", part(model, 1, "Body").emitters.first { $0.name == "CrashSparks" }?.emitted == 24 && part(model, 1, "Body").emitters.first { $0.name == "DamageSmoke" }?.enabled == true && errors(player).isEmpty, "\(errors(player))")
    }

    static func together(_ check: Checker) {
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ $0.state = Racing.state() }), let host = hosting.player, let client = joining.player else { check("the race hosts and joins", false); return }
        defer { hosting.leaveGame(); joining.leaveGame() }
        LANSelfTest.run([hosting, joining], seconds: 4.5)
        check("host and joiner each enter their assigned car", host.seatPart == part(host.model, 1, "VehicleSeat").id && client.seatPart == part(client.model, 2, "VehicleSeat").id, "\(String(describing: host.seatPart)), \(String(describing: client.seatPart))")
        func phase(_ model: SceneModel) -> String { model.dataObjects.first { $0.name == "Phase" }?.text ?? "" }
        check("the countdown and race phase are shared", phase(host.model) == "RACING" && phase(client.model) == "RACING")
        let hostBefore = part(host.model, 1, "Body").position, clientBefore = part(host.model, 2, "Body").position
        client.key("W", pressed: true); LANSelfTest.run([hosting, joining], seconds: 1.1); client.key("W", pressed: false)
        let hostAfter = part(host.model, 1, "Body").position, clientAfter = part(host.model, 2, "Body").position
        check("a joined driver controls their own host-simulated car", simd_distance(clientBefore, clientAfter) > 12 && simd_distance(hostBefore, hostAfter) < 3 && simd_distance(clientAfter, part(client.model, 2, "Body").position) < 1, "host \(hostBefore) -> \(hostAfter); client \(clientBefore) -> \(clientAfter)")
        launch(host, car: 2, from: Vec3(109, 2.45, 0), toward: -.pi / 2, velocity: Vec3(52, 0, 0))
        LANSelfTest.run([hosting, joining], seconds: 0.9)
        check("a joined driver's crash damage and broken panels are shared", value(host.model, 2, "Health") < 100 && value(client.model, 2, "Health") == value(host.model, 2, "Health") && client.model.constraints.contains { $0.parentID == part(client.model, 2, "Hood").id && !$0.enabled })
        client.key("T", pressed: true); LANSelfTest.run([hosting, joining], seconds: 0.1); client.key("T", pressed: false); LANSelfTest.run([hosting, joining], seconds: 0.6)
        check("a joined player's Recover button resets only their car", value(host.model, 2, "Health") == 100 && value(client.model, 2, "Health") == 100)
        check("both racing dashboards and previews run without script errors", errors(host).isEmpty && errors(client).isEmpty, "\(errors(host)) \(errors(client))")
        guard let server = hosting.host, let port = server.port.flatMap(NWEndpoint.Port.init(rawValue:)) else { return }
        let (defaults, suite) = LANSelfTest.freshDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let late = ClientSession(defaults: defaults); late.profile.name = "Late Driver"
        late.join(LANGame(name: server.gameName, txt: LANGame.txt(sceneName: "Racing", players: 2), endpoint: .hostPort(host: LANSelfTest.loopback, port: port)))
        _ = LANSelfTest.wait { late.player != nil }
        LANSelfTest.run([hosting, joining, late], seconds: 0.7)
        for _ in 0..<20 where late.player?.seatPart == nil { LANSelfTest.run([hosting, joining, late], seconds: 0.1) }
        if let third = late.player {
            check("a late driver joins the current race in their own car", phase(third.model) == "RACING" && third.seatPart == part(third.model, 3, "VehicleSeat").id && value(third.model, 2, "Health") == value(host.model, 2, "Health") && errors(third).isEmpty, "seat \(String(describing: third.seatPart)) expected \(part(third.model, 3, "VehicleSeat").id) character \(third.character.position) seatPosition \(part(third.model, 3, "VehicleSeat").position) names \(host.model.dataObjects.filter { $0.name == "Driver" }.map(\.text)) phase \(phase(third.model)) health \(value(third.model, 2, "Health"))/\(value(host.model, 2, "Health")) errors \(errors(third))")
        } else { check("a late driver joins the current race in their own car", false) }
        joining.leaveGame()
        LANSelfTest.run([hosting], seconds: 2)
        check("departed drivers return their cars to NPC control without stale leaderboard errors", errors(host).isEmpty && host.model.dataObjects.first { $0.parent == .node(group(host.model, 2)) && $0.name == "Driver" }?.text == "NPC 2", "\(errors(host).suffix(3))")
        late.leaveGame()
    }

}
