import Foundation
import Network
import simd

/// Verification for playing on the local network and the client around it: messages on
/// the wire, a real host and players over loopback TCP (Bonjour itself needs the network,
/// so discovery is checked by hand), the player's profile, and the client's screens.
enum LANSelfTest {

    static func run(check: Checker) {
        testFraming(check)
        testGames(check)
        testProfile(check)
        testHostAndJoin(check)
        testClientSession(check)
        testSeeingEachOther(check)
        testOneWorld(check)
        testPlayersCollide(check)
        testHostScriptsSeeEveryone(check)
        testChatRelay(check)
        testChat(check)
        testRemoteReadsAndWrites(check)
        testJointsReachJoiners(check)
        testShaderParametersReachJoiners(check)
        testAnimationsAcrossPlayers(check)
        testTasksOnEveryMachine(check)
        for suite in madeSuites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        madeSuites = []
    }

    /// Each machine runs its own scripts' `task` scheduler: a LocalScript on the host
    /// and on a joined player gets the same defer and cancel.
    private static func testTasksOnEveryMachine(_ check: Checker) {
        print("\nLAN: the task library on every machine")
        guard let (hosting, joining) = twoPlayers({ model in
            var mine = ScriptObject.blank(language: .luau)
            mine.host = .starterPlayer
            mine.source = """
            local RunService = game:GetService("RunService")
            local frame = 0
            RunService.Heartbeat:Connect(function() frame += 1 end)
            task.wait()
            local at = frame
            local waiter = task.spawn(function()
            \tRunService.Heartbeat:Wait()
            \tprint("woke")
            end)
            task.cancel(waiter)
            task.defer(function()
            \tprint("tasks", game:GetService("Players").LocalPlayer.Name, frame - at)
            end)
            """
            model.scripts.append(mine)
        }), let host = hosting.player, let player = joining.player else {
            check("a host and a player join", false)
            return
        }
        run([hosting, joining], seconds: 0.3)
        func said(_ session: PlayController, _ kind: ScriptConsole.Kind = .output) -> [String] {
            session.console.lines.filter { $0.kind == kind }.map(\.text)
        }
        check("each machine's scripts defer in the same frame and cancel for good, host and joined alike",
              said(host).contains("tasks Robin 0") && said(player).contains("tasks Sam 0")
              && !said(host).contains("woke") && !said(player).contains("woke")
              && said(host, .error).isEmpty && said(player, .error).isEmpty,
              "\(said(host)) | \(said(player)) | \(said(host, .error) + said(player, .error))")
        hosting.leaveGame()
        joining.leaveGame()
    }

    /// This Mac, for a host and a player over loopback — by name, not 127.0.0.1: a
    /// network policy on the Mac (a VPN, say) can make Network.framework refuse IPv4
    /// loopback ("Can't assign requested address") while plain sockets and ::1 work.
    static let loopback: NWEndpoint.Host = "localhost"

    /// Runs the main queue until `done` or the time is up — the network calls back there.
    @discardableResult
    static func wait(_ seconds: TimeInterval = 5, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return done()
    }

    static func freshDefaults() -> (UserDefaults, String) {
        let suite = "studio-selftest-\(UUID().uuidString)"
        madeSuites.append(suite)
        return (UserDefaults(suiteName: suite)!, suite)
    }

    /// Every settings suite a test made, removed when the tests are done.
    private static var madeSuites: [String] = []

    private static func testFraming(_ check: Checker) {
        print("\nLAN: messages on the wire")
        let hello = LANMessage.hello(name: "Robin", version: LAN.protocolVersion, colors: BodyColors())
        let players = LANMessage.players(["Robin", "Sam"])
        guard let a = try? LANFraming.frame(hello), let b = try? LANFraming.frame(players) else {
            check("messages frame", false)
            return
        }
        check("a message is its length, then JSON", a.count > 4 && Int(a[3]) + Int(a[2]) << 8 == a.count - 4)
        var buffer = a + b.prefix(6)
        let first = try? LANFraming.messages(from: &buffer)
        check("whole messages come off the stream; a partial one waits", first == [hello] && buffer.count == 6)
        buffer += b.dropFirst(6)
        check("…until the rest arrives", (try? LANFraming.messages(from: &buffer)) == [players] && buffer.isEmpty)
        var huge = Data([0xff, 0xff, 0xff, 0xff])
        check("an impossible length is refused, not waited for",
              (try? LANFraming.messages(from: &huge)) == nil)
    }

    private static func testGames(_ check: Checker) {
        print("\nLAN: games found")
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 9)
        let game = LANGame(name: "Robin's Obby", txt: LANGame.txt(sceneName: "Obby", players: 2), endpoint: endpoint)
        check("a game reads its scene and players from its TXT record",
              game.sceneName == "Obby" && game.players == 2 && game.compatible)
        let old = LANGame(name: "Old", txt: ["scene": "X", "version": "0"], endpoint: endpoint)
        check("one from another version can't be joined", !old.compatible && old.players == 0)
    }

    private static func testProfile(_ check: Checker) {
        print("\nClient: the player's profile")
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        check("a new player is called Player", PlayerProfile.load(from: defaults) == PlayerProfile())
        check("names are tidied", PlayerProfile.tidy("  Robin  ") == "Robin" && PlayerProfile.tidy("   ") == "Player"
              && PlayerProfile.tidy(String(repeating: "x", count: 50)).count == PlayerProfile.longestName)
        var profile = PlayerProfile()
        profile.name = "Robin"
        profile.colors.torso = Vec3(1, 0, 0)
        profile.save(to: defaults)
        check("it is kept between launches", PlayerProfile.load(from: defaults) == profile)

        let model = SceneModel()
        model.parts = []
        model.scripts = []
        var script = ScriptObject.blank(language: .luau)
        script.source = "local player = game:GetService(\"Players\").LocalPlayer\nprint(player.Name, player.Character.Name)"
        model.scripts = [script]
        let session = PlayController(model: model, console: ScriptConsole())
        profile.apply(to: model, session)
        session.start()
        session.step(dt: 1.0 / 60)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let printed = session.console.lines.filter { $0.kind == .output }.map(\.text)
        check("scripts see the player's name", printed == ["Robin Robin"], "\(printed)")
        check("the character wears the player's colours", session.bodyColors.torso == Vec3(1, 0, 0))
        session.stop()
    }

    private static func testHostAndJoin(_ check: Checker) {
        print("\nLAN: hosting and joining")
        let scene = Data("{\"parts\":[]}".utf8)
        let host = LANHost(gameName: "Test Game", sceneName: "Test Scene") { scene }
        do { try host.start(advertise: false) } catch {
            check("a host starts", false, "\(error)")
            return
        }
        guard wait(until: { host.port != nil }), let port = host.port.flatMap(NWEndpoint.Port.init(rawValue:)) else {
            check("a host starts listening", false, host.failure ?? "no port")
            return
        }
        check("a host starts listening", true)
        let endpoint = NWEndpoint.hostPort(host: loopback, port: port)

        var robin: PlayerProfile { var p = PlayerProfile(); p.name = "Robin"; return p }
        var first: Result<LANJoin.Welcome, Error>?
        LANJoin.join(endpoint, as: robin) { first = $0 }
        wait { first != nil }
        guard case .success(let welcome)? = first else {
            check("a player joins", false, "\(String(describing: first))")
            return
        }
        check("a player who says hello is welcomed with the scene",
              welcome.scene == scene && welcome.sceneName == "Test Scene" && welcome.membership.game == "Test Game")
        check("the host knows who joined", host.players == ["Robin"])

        var sam = PlayerProfile()
        sam.name = "Sam"
        var second: Result<LANJoin.Welcome, Error>?
        LANJoin.join(endpoint, as: sam) { second = $0 }
        wait { second != nil }
        wait { welcome.membership.players.count == 2 }
        check("everyone hears when someone else joins", welcome.membership.players == ["Robin", "Sam"],
              "\(welcome.membership.players)")

        if case .success(let samWelcome)? = second { samWelcome.membership.leave() }
        wait { host.players == ["Robin"] }
        check("…and when they leave", host.players == ["Robin"] && welcome.membership.players == ["Robin"],
              "\(host.players) \(welcome.membership.players)")

        // Someone on another version is turned away with a reason.
        let stranger = LANLink(NWConnection(to: endpoint, using: .tcp))
        var answer: LANMessage?
        stranger.onReady = { stranger.send(.hello(name: "Old", version: 0, colors: BodyColors())) }
        stranger.onMessage = { answer = $0 }
        stranger.start()
        wait { answer != nil }
        if case .refused? = answer {
            check("a player on another version is refused", true)
        } else {
            check("a player on another version is refused", false, "\(String(describing: answer))")
        }
        check("…and never counted", host.players == ["Robin"])

        host.stop()
        wait { !welcome.membership.connected }
        check("players notice the host going", !welcome.membership.connected)
    }

    private static func testClientSession(_ check: Checker) {
        print("\nClient: menu, play and LAN")
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = ClientSession(defaults: defaults)
        check("the client opens on its menu", client.screen == .menu && client.player == nil)

        client.profile.name = "Robin"
        client.profile.colors.head = Vec3(0, 0, 1)
        check("changing the character saves it", PlayerProfile.load(from: defaults).name == "Robin")

        let parts = client.model.parts.count
        client.play()
        check("Play starts the game as the player",
              client.screen == .playing && client.player?.playerName == "Robin"
              && client.player?.bodyColors.head == Vec3(0, 0, 1))
        client.model.parts.removeAll()
        client.leaveGame()
        check("the menu is back, and the scene as it was", client.screen == .menu && client.player == nil
              && client.model.parts.count == parts)

        // Host from one client; join it from another, which should get the host's scene.
        client.model.parts[0].name = "Only At The Host"
        client.hostOnLAN(advertise: false)
        guard let host = client.host, wait(until: { host.port != nil }),
              let port = host.port.flatMap(NWEndpoint.Port.init(rawValue:)) else {
            check("a client can host", false, client.problem ?? "no port")
            return
        }
        check("hosting plays the scene too", client.screen == .playing && host.gameName == "Robin's Starter Scene")

        let (otherDefaults, otherSuite) = freshDefaults()
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        let friend = ClientSession(defaults: otherDefaults)
        friend.profile.name = "Sam"
        friend.join(LANGame(name: host.gameName, txt: LANGame.txt(sceneName: "Starter Scene", players: 0),
                            endpoint: .hostPort(host: loopback, port: port)))
        wait { friend.screen == .playing }
        check("joining plays the host's scene",
              friend.screen == .playing && friend.model.parts.contains { $0.name == "Only At The Host" },
              friend.problem ?? "")
        check("…as yourself", friend.player?.playerName == "Sam" && host.players == ["Sam"])

        client.leaveGame()
        wait { friend.membership?.connected == false }
        check("the joiner sees the host leave", friend.membership?.connected == false)
        friend.leaveGame()

        let old = ClientSession(defaults: otherDefaults)
        old.join(LANGame(name: "Old", txt: ["version": "0"], endpoint: .hostPort(host: loopback, port: port)))
        check("a game on another version isn't tried", old.problem != nil && old.screen == .menu)
    }

    /// Two players in one game: each sees the other where they are, in their colours,
    /// moving, dying — and gone once they leave.
    private static func testSeeingEachOther(_ check: Checker) {
        print("\nLAN: players see each other")
        let (hostDefaults, hostSuite) = freshDefaults()
        let (joinDefaults, joinSuite) = freshDefaults()
        defer {
            hostDefaults.removePersistentDomain(forName: hostSuite)
            joinDefaults.removePersistentDomain(forName: joinSuite)
        }
        let hosting = ClientSession(defaults: hostDefaults)
        hosting.profile.name = "Robin"
        hosting.profile.colors.torso = Vec3(1, 0, 0)
        hosting.hostOnLAN(advertise: false)
        guard let host = hosting.host, wait(until: { host.port != nil }),
              let port = host.port.flatMap(NWEndpoint.Port.init(rawValue:)) else {
            check("a game is hosted", false, hosting.problem ?? "no port")
            return
        }
        let joining = ClientSession(defaults: joinDefaults)
        joining.profile.name = "Sam"
        joining.profile.colors.torso = Vec3(0, 0, 1)
        joining.join(LANGame(name: host.gameName, txt: LANGame.txt(sceneName: "Starter Scene", players: 0),
                             endpoint: .hostPort(host: loopback, port: port)))
        wait { joining.screen == .playing }
        guard let robin = hosting.player, let sam = joining.player else {
            check("both are playing", false, joining.problem ?? "")
            return
        }

        func exchange() {
            for _ in 0..<8 {
                hosting.syncNetwork()
                joining.syncNetwork()
                RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            }
        }
        func near(_ a: Vec3?, _ b: Vec3) -> Bool { a.map { simd_distance($0, b) < 0.01 } ?? false }

        robin.character.position = Vec3(10, 0, 10)
        sam.character.position = Vec3(-10, 0, -10)
        exchange()
        let seenBySam = sam.avatars.dropFirst().first
        check("the joiner sees the host where the host is",
              sam.avatars.count == 2 && near(seenBySam?.position, Vec3(10, 0, 10)), "\(sam.avatars.map(\.position))")
        check("…in the host's colours", seenBySam?.colors.torso == Vec3(1, 0, 0))
        let seenByRobin = robin.avatars.dropFirst().first
        check("the host sees the joiner where they are",
              robin.avatars.count == 2 && near(seenByRobin?.position, Vec3(-10, 0, -10)), "\(robin.avatars.map(\.position))")
        check("…in the joiner's colours", seenByRobin?.colors.torso == Vec3(0, 0, 1))
        check("each has the other's name over their head",
              sam.remoteNameTags.map(\.name) == ["Robin"] && robin.remoteNameTags.map(\.name) == ["Sam"])
        check("…and draws themselves in their own colours",
              sam.avatars.first?.colors.torso == Vec3(0, 0, 1) && robin.avatars.first?.colors.torso == Vec3(1, 0, 0))

        // Moving: the joiner sees it, gliding there rather than jumping each update.
        sam.step(dt: 1.0 / 60)
        robin.character.position = Vec3(12, 0, 10)
        exchange()
        sam.step(dt: 1.0 / 60)
        let partway = sam.avatars.dropFirst().first?.position.x ?? 0
        for _ in 0..<60 { sam.step(dt: 1.0 / 60) }
        let arrived = sam.avatars.dropFirst().first?.position.x ?? 0
        check("the host moving is seen gliding there", partway > 10 && partway < 12 && abs(arrived - 12) < 0.05,
              "\(partway) then \(arrived)")

        robin.humanoid.die()
        exchange()
        check("the host dying is seen", sam.avatars.dropFirst().first?.dead == true)

        joining.leaveGame()
        wait { host.players.isEmpty }
        hosting.syncNetwork()
        check("the joiner leaving takes them out of the host's world", robin.avatars.count == 1)
        hosting.leaveGame()
    }

    // MARK: - One world

    /// A host and a player in one game over loopback, in a world the caller builds. The
    /// default controls are off, so tests can steer the characters.
    static func twoPlayers(_ build: (SceneModel) -> Void, looks: (host: AvatarLook, player: AvatarLook)? = nil)
        -> (host: ClientSession, player: ClientSession)? {
        let model = SceneModel()
        model.parts = []
        model.scripts = []
        model.shaders = []
        model.groups = []
        model.starterGui = []
        var controls = ScriptObject.blank(language: .luau)
        controls.name = "ControlScript"
        controls.host = .starterPlayer
        controls.enabled = false
        model.scripts = [controls]
        build(model)
        let hosting = ClientSession(model: model, defaults: freshDefaults().0)
        hosting.profile.name = "Robin"
        if let looks { hosting.profile.look = looks.host }
        hosting.hostOnLAN(advertise: false)
        guard let host = hosting.host, wait(until: { host.port != nil }),
              let port = host.port.flatMap(NWEndpoint.Port.init(rawValue:)) else { return nil }
        let joining = ClientSession(defaults: freshDefaults().0)
        joining.profile.name = "Sam"
        if let looks { joining.profile.look = looks.player }
        joining.join(LANGame(name: host.gameName, txt: LANGame.txt(sceneName: "Test", players: 0),
                             endpoint: .hostPort(host: loopback, port: port)))
        wait { joining.screen == .playing }
        guard joining.player != nil else { return nil }
        return (hosting, joining)
    }

    /// Steps both games frame by frame, as their windows would, exchanging with the
    /// network every third frame.
    static func run(_ sessions: [ClientSession], seconds: Float, each: (() -> Void)? = nil) {
        var frame = 0
        var elapsed: Float = 0
        while elapsed < seconds {
            each?()
            for session in sessions { session.player?.step(dt: 1.0 / 60) }
            frame += 1
            if frame % 3 == 0 {
                for session in sessions { session.syncNetwork() }
                RunLoop.current.run(until: Date().addingTimeInterval(0.004))
            }
            elapsed += 1.0 / 60
        }
        for _ in 0..<6 {
            for session in sessions { session.syncNetwork() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private static func testOneWorld(_ check: Checker) {
        print("\nLAN: one world")
        guard let (hosting, joining) = twoPlayers({ model in
            var crate = Part()
            crate.name = "Crate"
            crate.anchored = false
            crate.position = Vec3(40, 30, 40)
            var mover = Part()
            mover.name = "Mover"
            mover.position = Vec3(-40, 2, -40)
            model.parts = [crate, mover]
            var script = ScriptObject.blank(language: .luau)
            script.source = """
            print("scene script ran")
            local mover = workspace.Mover
            game:GetService("RunService").Heartbeat:Connect(function(dt)
            \tmover.Position += Vector3.new(dt * 5, 0, 0)
            end)
            game:GetService("Lighting").ClockTime = 3
            task.delay(0.3, function()
            \tlocal made = Instance.new("Part")
            \tmade.Name = "Made By A Script"
            \tmade.Parent = workspace
            end)
            """
            model.scripts.append(script)
        }) else {
            check("two players share a game", false)
            return
        }
        let host = hosting.model, player = joining.model
        func part(_ model: SceneModel, _ name: String) -> Part? { model.parts.first { $0.name == name } }

        check("the joiner leaves the scene's scripts and physics to the host",
              joining.player?.worldFromHost == true && hosting.player?.worldFromHost == false)
        run([hosting, joining], seconds: 0.5)
        let hostCrate = part(host, "Crate")?.position.y ?? 30
        check("the crate falls in the host's physics", hostCrate < 29, "\(hostCrate)")
        check("…and the joiner sees it exactly there",
              abs((part(player, "Crate")?.position.y ?? 99) - hostCrate) < 0.001, "\(part(player, "Crate")?.position.y ?? 99) vs \(hostCrate)")
        let before = part(player, "Crate")?.position
        for _ in 0..<10 { joining.player?.step(dt: 1.0 / 60) }
        check("…moving only when the host says, not by physics of its own", part(player, "Crate")?.position == before)

        check("what the host's scripts do reaches the joiner",
              part(player, "Mover")?.position == part(host, "Mover")?.position
              && (part(player, "Mover")?.position.x ?? -40) > -39.5)
        check("…lighting included", player.lighting.clockTime == 3, "\(player.lighting.clockTime)")
        check("…and parts they make", part(player, "Made By A Script") != nil)
        let hostOutput = hosting.player?.console.lines.map(\.text) ?? []
        let playerOutput = joining.player?.console.lines.map(\.text) ?? []
        check("the scene's scripts run once, on the host",
              hostOutput.contains("scene script ran") && !playerOutput.contains("scene script ran"),
              "\(playerOutput)")

        // A part dropped on the joiner, in the host's physics, lands on them.
        guard let sam = joining.player else { return }
        sam.character.position = Vec3(20, 0, 20)
        run([hosting, joining], seconds: 0.3)
        var brick = Part()
        brick.name = "Brick"
        brick.anchored = false
        brick.size = Vec3(1, 1, 1)
        brick.position = Vec3(20, 12, 20)
        host.parts.append(brick)
        run([hosting, joining], seconds: 1.5)
        let rested = part(host, "Brick")?.position.y ?? 0
        check("a part falling on the joiner lands on them", rested > CharacterController.capsuleHeight - 0.2, "\(rested)")
        check("…and they see it there", abs((part(player, "Brick")?.position.y ?? 0) - rested) < 0.001)

        joining.leaveGame()
        wait { hosting.host?.players.isEmpty == true }
        hosting.syncNetwork()
        run([hosting], seconds: 0.1)
        check("a player who leaves takes their body out of the host's physics",
              hosting.player?.physics.characterIDs == [0], "\(hosting.player?.physics.characterIDs ?? [])")
        hosting.leaveGame()
    }

    private static func testPlayersCollide(_ check: Checker) {
        print("\nLAN: players collide")
        func closest(playersCollide: Bool) -> Float? {
            guard let (hosting, joining) = twoPlayers({ $0.starterPlayer.playersCollide = playersCollide }),
                  let robin = hosting.player, let sam = joining.player else { return nil }
            defer {
                joining.leaveGame()
                hosting.leaveGame()
            }
            robin.character.position = Vec3(60, 0, 40)
            sam.character.position = Vec3(60, 0, 50)
            run([hosting, joining], seconds: 0.3)
            var nearest = Float.infinity
            run([hosting, joining], seconds: 2) {
                robin.humanoid.moveDirection = Vec3(0, 0, 1)
                let between = robin.character.position - sam.character.position
                nearest = min(nearest, simd_length(Vec3(between.x, 0, between.z)))
            }
            return nearest
        }
        let blocked = closest(playersCollide: true)
        check("walking into another player stops against them",
              blocked.map { $0 >= 1.8 } ?? false, "\(String(describing: blocked))")
        let through = closest(playersCollide: false)
        check("…unless the map turns player collisions off",
              through.map { $0 < 0.5 } ?? false, "\(String(describing: through))")

        let old = try? JSONDecoder().decode(StarterPlayerSettings.self, from: Data("{}".utf8))
        check("maps from before the setting have players colliding", old?.playersCollide == true)
    }

    /// The scripts people write for a game with more than one player, run by the host:
    /// they see a joined player arrive, touch things, get hurt, die, respawn and leave.
    private static func testHostScriptsSeeEveryone(_ check: Checker) {
        print("\nLAN: the host's scripts see every player")
        func pad(_ name: String, at position: Vec3, canCollide: Bool = true, script: String) -> (Part, ScriptObject) {
            var part = Part()
            part.name = name
            part.position = position
            part.size = Vec3(6, 1, 6)
            part.canCollide = canCollide
            var code = ScriptObject.blank(language: .luau)
            code.parentID = part.id
            code.source = script
            return (part, code)
        }
        guard let (hosting, joining) = twoPlayers({ model in
            model.starterPlayer.respawnTime = 1
            let pads = [
                pad("KillBrick", at: Vec3(40, 0.5, 40), script: """
                script.Parent.Touched:Connect(function(hit)
                \tlocal humanoid = hit.Parent:FindFirstChild("Humanoid")
                \tif humanoid and humanoid.Health > 0 then
                \t\thumanoid.Health = 0
                \tend
                end)
                """),
                pad("Coin", at: Vec3(-40, 0.5, -40), canCollide: false, script: """
                local coin = script.Parent
                coin.Touched:Connect(function(hit)
                \tlocal player = game:GetService("Players"):GetPlayerFromCharacter(hit.Parent)
                \tif player and coin.Parent then
                \t\tprint(`coin for {player.Name}`)
                \t\tcoin:Destroy()
                \tend
                end)
                """),
                pad("Boost", at: Vec3(0, 0.5, -60), script: """
                script.Parent.Touched:Connect(function(hit)
                \tlocal humanoid = hit.Parent:FindFirstChild("Humanoid")
                \tif humanoid then humanoid.WalkSpeed = 30 end
                end)
                """),
                pad("Teleporter", at: Vec3(-60, 0.5, 0), script: """
                script.Parent.Touched:Connect(function(hit)
                \tlocal root = hit.Parent:FindFirstChild("HumanoidRootPart")
                \tif root then root.Position = Vector3.new(80, 3, 80) end
                end)
                """),
            ]
            model.parts = pads.map(\.0)
            var watcher = ScriptObject.blank(language: .luau)
            watcher.source = """
            local Players = game:GetService("Players")
            Players.PlayerAdded:Connect(function(player)
            \tprint(`joined {player.Name}, {#Players:GetPlayers()} playing`)
            \tplayer.CharacterAdded:Connect(function(character)
            \t\tprint(`spawned {character.Name}`)
            \t\tcharacter:WaitForChild("Humanoid").Died:Connect(function()
            \t\t\tprint(`died {character.Name}`)
            \t\tend)
            \tend)
            end)
            Players.PlayerRemoving:Connect(function(player)
            \tprint(`left {player.Name}`)
            end)
            """
            model.scripts += pads.map(\.1) + [watcher]
        }), let sam = joining.player, let robin = hosting.player else {
            check("two players share a game", false)
            return
        }
        func said() -> [String] {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            return robin.console.lines.filter { $0.kind == .output }.map(\.text)
        }
        func stand(on position: Vec3, seconds: Float = 0.6) {
            sam.character.position = position
            sam.character.velocity = .zero
            run([hosting, joining], seconds: seconds)
        }

        run([hosting, joining], seconds: 0.5)
        check("PlayerAdded fires for someone joining, with them in GetPlayers",
              said().contains("joined Sam, 2 playing"), "\(said())")
        check("…and so does their CharacterAdded", said().contains("spawned Sam"))

        stand(on: Vec3(-40, 1, -40))
        check("a coin knows who picked it up", said().contains("coin for Sam"), "\(said())")
        check("…and is gone for both", !hosting.model.parts.contains { $0.name == "Coin" }
              && !joining.model.parts.contains { $0.name == "Coin" })

        stand(on: Vec3(0, 1, -60))
        check("a speed pad changes the joined player's WalkSpeed", sam.humanoid.walkSpeed == 30,
              "\(sam.humanoid.walkSpeed)")
        check("…which the host then reads back", robin.remotePlayers.first?.walkSpeed == 30)

        stand(on: Vec3(-60, 1, 0), seconds: 0.4)
        let landed = sam.character.position
        check("a teleporter moves them", abs(landed.x - 80) < 0.5 && abs(landed.z - 80) < 0.5, "\(landed)")

        stand(on: Vec3(40, 1, 40))
        check("a kill brick kills them", sam.humanoid.isDead)
        check("…and the host's script hears them die", said().contains("died Sam"), "\(said())")
        run([hosting, joining], seconds: 1.5)
        check("when they respawn, CharacterAdded fires again",
              !sam.humanoid.isDead && said().filter { $0 == "spawned Sam" }.count == 2, "\(said())")

        joining.leaveGame()
        wait { hosting.host?.players.isEmpty == true }
        run([hosting], seconds: 0.2)
        check("PlayerRemoving fires when they leave", said().contains("left Sam"), "\(said())")
        let errors = robin.console.lines.filter { $0.kind == .error }.map(\.text)
        check("…and none of it raised an error", errors.isEmpty, errors.joined(separator: " | "))
        hosting.leaveGame()
    }

    // MARK: - Chat

    /// Chat on the wire: the host passes each player's message to everyone else, under
    /// the name that player joined with.
    private static func testChatRelay(_ check: Checker) {
        print("\nLAN: chat messages")
        let host = LANHost(gameName: "Chat", sceneName: "Chat") { Data("{\"parts\":[]}".utf8) }
        guard (try? host.start(advertise: false)) != nil, wait(until: { host.port != nil }),
              let port = host.port.flatMap(NWEndpoint.Port.init(rawValue:)) else {
            check("a host starts", false)
            return
        }
        let endpoint = NWEndpoint.hostPort(host: loopback, port: port)
        func join(_ name: String) -> LANMembership? {
            var profile = PlayerProfile()
            profile.name = name
            var result: Result<LANJoin.Welcome, Error>?
            LANJoin.join(endpoint, as: profile) { result = $0 }
            wait { result != nil }
            if case .success(let welcome)? = result { return welcome.membership }
            return nil
        }
        guard let robin = join("Robin"), let sam = join("Sam") else {
            check("two players join", false)
            return
        }
        var atHost: [String] = [], atRobin: [String] = [], atSam: [String] = []
        host.onChat = { atHost.append("\($0): \($1)") }
        robin.onChat = { atRobin.append("\($0): \($1)") }
        sam.onChat = { atSam.append("\($0): \($1)") }

        robin.chat("  hi all  ")
        robin.chat("   ")
        wait { !atSam.isEmpty && !atHost.isEmpty }
        check("a player's message reaches the host and everyone else, under their name",
              atHost == ["Robin: hi all"] && atSam == ["Robin: hi all"], "\(atHost) \(atSam)")
        host.chat(from: "Host", text: String(repeating: "y", count: 500))
        wait { atRobin.count == 1 && atSam.count == 2 }
        check("…not back to them; the host's own reaches everyone, cut short",
              atRobin == ["Host: " + String(repeating: "y", count: PlayController.longestChat)]
              && atSam.last == atRobin.last, "\(atRobin.map(\.count))")
        check("…and blank messages go nowhere", atHost.count == 1 && atSam.count == 2)
        robin.leave()
        sam.leave()
        host.stop()
    }

    /// The default ChatScript in a real game: "/" and typing on one side, the message in
    /// the other's chat window.
    private static func testChat(_ check: Checker) {
        print("\nLAN: chat between players")
        guard let (hosting, joining) = twoPlayers({ model in
            var count = ScriptObject.blank(language: .luau)
            count.host = .starterPlayer
            count.source = "print(\"players at start \" .. #game:GetService(\"Players\"):GetPlayers())"
            model.scripts.append(count)
        }), let robin = hosting.player, let sam = joining.player else {
            check("two players share a game", false)
            return
        }
        run([hosting, joining], seconds: 0.3)
        check("the host's chat says who joined", GuiSelfTest.chatShown(robin).contains("Sam joined the game"),
              "\(GuiSelfTest.chatShown(robin))")
        check("…but a joining player isn't told the players already there joined",
              !GuiSelfTest.chatShown(sam).contains("Robin joined the game"), "\(GuiSelfTest.chatShown(sam))")
        check("…who are in their GetPlayers from the start",
              sam.console.lines.map(\.text).contains("players at start 2"), "\(sam.console.lines.map(\.text))")

        sam.key("Slash", pressed: true)
        run([hosting, joining], seconds: 0.05)
        sam.key("Slash", pressed: false)
        GuiSelfTest.type("hi Robin", into: sam)
        run([hosting, joining], seconds: 0.2)
        check("a joined player's message shows in the host's chat", GuiSelfTest.chatShown(robin).last == "Sam: hi Robin",
              "\(GuiSelfTest.chatShown(robin))")
        check("…and once in their own", GuiSelfTest.chatShown(sam).filter { $0 == "Sam: hi Robin" }.count == 1,
              "\(GuiSelfTest.chatShown(sam))")
        let bubble = GuiSelfTest.bubble(robin)
        let samsHead = robin.remotePlayers.first.flatMap {
            robin.screenPoint(of: (robin.shownRemote[$0.id]?.position ?? $0.position) + Vec3(0, 4.65, 0),
                              in: CGSize(width: 800, height: 600))
        }
        check("…in a bubble over the joined player's head in the host's game",
              bubble?.text == "hi Robin" && samsHead.map { abs(bubble!.frame.midX - $0.x) < 40 && bubble!.frame.maxY < $0.y } == true,
              "\(String(describing: bubble)) \(String(describing: samsHead))")

        robin.key("Slash", pressed: true)
        run([hosting, joining], seconds: 0.05)
        robin.key("Slash", pressed: false)
        GuiSelfTest.type("hello Sam", into: robin)
        run([hosting, joining], seconds: 0.2)
        check("the host's message shows in the joined player's chat",
              GuiSelfTest.chatShown(sam).last == "Robin: hello Sam"
              && GuiSelfTest.chatShown(robin).filter { $0 == "Robin: hello Sam" }.count == 1,
              "\(GuiSelfTest.chatShown(sam))")
        check("…and both are back to playing", !sam.isTyping && !robin.isTyping)

        joining.leaveGame()
        wait { hosting.host?.players.isEmpty == true }
        run([hosting], seconds: 0.2)
        check("…and says when they leave", GuiSelfTest.chatShown(robin).last == "Sam left the game",
              "\(GuiSelfTest.chatShown(robin))")
        let errors = robin.console.lines.filter { $0.kind == .error }.map(\.text)
        check("none of it raised an error", errors.isEmpty, errors.joined(separator: " | "))
        hosting.leaveGame()
    }

    // MARK: - Reading and writing other players

    /// A host script reading a joined player's movement, and reading back at once what it
    /// just set on them — before their game has had a chance to report it.
    private static func testRemoteReadsAndWrites(_ check: Checker) {
        print("\nLAN: host scripts reading and writing a joined player")
        guard let (hosting, joining) = twoPlayers({ model in
            var script = ScriptObject.blank(language: .luau)
            script.source = """
            local Players = game:GetService("Players")
            local humanoid, root
            Players.PlayerAdded:Connect(function(player)
            \tplayer.CharacterAdded:Connect(function(character)
            \t\thumanoid = character:WaitForChild("Humanoid")
            \t\troot = character:WaitForChild("HumanoidRootPart")
            \tend)
            end)
            local reported = false
            game:GetService("RunService").Heartbeat:Connect(function()
            \tif root and not reported and root.AssemblyLinearVelocity.Magnitude > 8 then
            \t\treported = true
            \t\tprint(string.format("moving %d %d", math.round(root.AssemblyLinearVelocity.X),
            \t\t\tmath.round(humanoid.MoveDirection.X)))
            \tend
            end)
            -- P, on the host, pokes the joined player.
            game:GetService("UserInputService").InputBegan:Connect(function(input)
            \tif input.KeyCode ~= Enum.KeyCode.P then
            \t\treturn
            \tend
            \thumanoid.WalkSpeed = 30
            \tprint("walk speed", humanoid.WalkSpeed)
            \thumanoid.Health = 250
            \tprint("health", humanoid.Health)
            \thumanoid:TakeDamage(30)
            \tprint("after damage", humanoid.Health)
            \troot.Position = Vector3.new(50, 3, 50)
            \tprint("moved", root.Position.X, root.Position.Z)
            end)
            """
            model.scripts.append(script)
        }), let robin = hosting.player, let sam = joining.player else {
            check("two players share a game", false)
            return
        }
        func said() -> [String] {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            return robin.console.lines.filter { $0.kind == .output }.map(\.text)
        }
        sam.character.position = Vec3(-30, 0, 0)
        run([hosting, joining], seconds: 1.2) { sam.humanoid.moveDirection = Vec3(1, 0, 0) }
        check("the host reads how fast a joined player moves, and where they're heading",
              said().contains("moving 16 1"), "\(said())")
        run([hosting, joining], seconds: 0.3) { sam.humanoid.moveDirection = .zero }

        robin.key("P", pressed: true)
        robin.step(dt: 1.0 / 60)
        robin.key("P", pressed: false)
        check("a host script reads back what it set on a joined player at once",
              said().suffix(4) == ["walk speed 30", "health 100", "after damage 70", "moved 50 50"],
              "\(said().suffix(4))")
        run([hosting, joining], seconds: 0.4)
        check("…which is what the joined player's game then has",
              sam.humanoid.walkSpeed == 30 && sam.humanoid.health == 70
              && abs(sam.character.position.x - 50) < 0.5, "\(sam.humanoid.walkSpeed) \(sam.humanoid.health)")
        check("…and what the host hears back from them",
              robin.remotePlayers.first?.walkSpeed == 30 && robin.remotePlayers.first?.health == 70)
        let errors = robin.console.lines.filter { $0.kind == .error }.map(\.text)
        check("none of it raised an error", errors.isEmpty, errors.joined(separator: " | "))
        joining.leaveGame()
        hosting.leaveGame()
    }

    /// Welds and joints a host script makes, changes and removes mid-game reach the
    /// joined player's copy of the world, where their own scripts can find them.
    private static func testJointsReachJoiners(_ check: Checker) {
        print("\nLAN: welds and joints reach joined players")
        guard let (hosting, joining) = twoPlayers({ model in
            var door = Part()
            door.name = "Door"
            door.position = Vec3(0, 5, 40)
            var frame = Part()
            frame.name = "Frame"
            frame.position = Vec3(3, 5, 40)
            model.parts = [door, frame]
            var script = ScriptObject.blank(language: .luau)
            script.source = """
            task.wait(0.2)
            local weld = Instance.new("WeldConstraint")
            weld.Name = "DoorWeld"
            weld.Part0 = workspace.Door
            weld.Part1 = workspace.Frame
            weld.Parent = workspace.Door
            local a0 = Instance.new("Attachment", workspace.Door)
            local a1 = Instance.new("Attachment", workspace.Frame)
            local hinge = Instance.new("HingeConstraint")
            hinge.Name = "DoorHinge"
            hinge.Attachment0 = a0
            hinge.Attachment1 = a1
            hinge.Parent = workspace.Door
            task.wait(0.4)
            weld.Enabled = false
            task.wait(0.4)
            hinge:Destroy()
            """
            model.scripts.append(script)
            var reader = ScriptObject.blank(language: .luau)
            reader.name = "Reader"
            reader.host = .starterPlayer
            reader.source = """
            task.wait(0.5)
            local weld = workspace.Door:FindFirstChild("DoorWeld")
            print("joiner sees", weld and weld.Part1.Name, workspace.Door:FindFirstChild("DoorHinge") ~= nil)
            """
            model.scripts.append(reader)
        }) else {
            check("two players share a game", false)
            return
        }
        func joints(_ session: ClientSession) -> [String: SceneConstraint] {
            Dictionary(session.model.constraints.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        }
        LANSelfTest.run([hosting, joining], seconds: 0.45)
        check("a weld and a hinge made by a host script reach the joiner",
              joints(joining)["DoorWeld"]?.kind == .weld && joints(joining)["DoorHinge"]?.kind == .hinge
              && joining.model.attachments.count == 2 && joining.model.constraints == hosting.model.constraints,
              "\(joining.model.constraints.map(\.name))")
        LANSelfTest.run([hosting, joining], seconds: 0.45)
        let seen = joining.player?.console.lines.filter { $0.kind == .output }.map(\.text) ?? []
        check("…where the joiner's own scripts find them", seen.contains("joiner sees Frame true"), "\(seen)")
        check("changing one reaches them", joints(joining)["DoorWeld"]?.enabled == false)
        LANSelfTest.run([hosting, joining], seconds: 0.45)
        check("…and so does removing one", joints(joining)["DoorHinge"] == nil && joints(joining)["DoorWeld"] != nil,
              "\(joining.model.constraints.map(\.name))")
        let errors = (hosting.player?.console.lines ?? []).filter { $0.kind == .error }.map(\.text)
        check("none of it raised an error", errors.isEmpty, errors.joined(separator: " | "))
        joining.leaveGame()
        hosting.leaveGame()
    }

    /// All sixteen shader parameters travel: a host script setting the last one changes
    /// it in the joined player's world too.
    private static func testShaderParametersReachJoiners(_ check: Checker) {
        print("\nLAN: shader parameters reach joined players")
        guard let (hosting, joining) = twoPlayers({ model in
            var shader = ShaderObject.blank(kind: .surface)
            shader.name = "Glow"
            shader.parameters = (0..<16).map { ShaderParameter(name: "p\($0)", value: 0) }
            model.shaders = [shader]
            var script = ScriptObject.blank(language: .luau)
            script.source = """
            task.wait(0.2)
            game:GetService("Shaders"):FindFirstChild("Glow"):SetParameter("p15", 0.75)
            """
            model.scripts.append(script)
        }) else {
            check("two players share a game", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 0.5)
        let seen = joining.model.shaders.first { $0.name == "Glow" }?.parameter(named: "p15")?.value
        check("the sixteenth parameter, set by a host script, reaches the joiner", seen == 0.75, "\(String(describing: seen))")
        let errors = (hosting.player?.console.lines ?? []).filter { $0.kind == .error }.map(\.text)
        check("…without errors", errors.isEmpty, errors.joined(separator: " | "))
        joining.leaveGame()
        hosting.leaveGame()
    }

    // MARK: - Animations

    /// A joined player's own animation is seen by the host; a host script plays one on
    /// the joined player, who plays it for everyone, and the host's script follows it.
    private static func testAnimationsAcrossPlayers(_ check: Checker) {
        print("\nLAN: animations across players")
        guard let (hosting, joining) = twoPlayers({ model in
            model.animations = [AnimationObject.waveExample()]
            var own = ScriptObject.blank(language: .luau)
            own.name = "WaveOnE"
            own.host = .starterCharacter
            own.source = """
            local animator = script.Parent:WaitForChild("Humanoid"):WaitForChild("Animator")
            local wave = animator:LoadAnimation(Animations.Wave)
            game:GetService("UserInputService").InputBegan:Connect(function(input)
            \tif input.KeyCode == Enum.KeyCode.E then
            \t\twave:Play()
            \tend
            end)
            """
            var host = ScriptObject.blank(language: .luau)
            host.source = """
            local track, humanoid
            game:GetService("Players").PlayerAdded:Connect(function(player)
            \tplayer.CharacterAdded:Connect(function(character)
            \t\thumanoid = character:WaitForChild("Humanoid")
            \t\ttrack = humanoid:WaitForChild("Animator"):LoadAnimation(Animations.Wave)
            \t\tprint("loaded", track.Length, track.IsPlaying)
            \t\ttrack.Stopped:Connect(function()
            \t\t\tprint("stopped", track.IsPlaying)
            \t\tend)
            \tend)
            end)
            game:GetService("UserInputService").InputBegan:Connect(function(input)
            \tif input.KeyCode == Enum.KeyCode.P and track then
            \t\ttrack:Play()
            \t\tprint("playing", track.IsPlaying, #humanoid:GetPlayingAnimationTracks())
            \tend
            end)
            """
            model.scripts += [own, host]
        }), let robin = hosting.player, let sam = joining.player else {
            check("two players share a game", false)
            return
        }
        func said() -> [String] {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            return robin.console.lines.filter { $0.kind == .output }.map(\.text)
        }
        func samsArmAtTheHost() -> Float { abs(robin.remotePlayers.first?.joints.rightShoulder.z ?? 0) }
        run([hosting, joining], seconds: 0.4)
        let resting = samsArmAtTheHost()

        sam.key("E", pressed: true)
        run([hosting, joining], seconds: 0.35)
        sam.key("E", pressed: false)
        let waving = samsArmAtTheHost()
        check("a joined player's own animation is seen by the host", waving > resting + 1, "\(resting) → \(waving)")
        check("…drawn on their body there too",
              robin.avatars.dropFirst().first.map { abs($0.joints.rightShoulder.z) > resting + 1 } ?? false)
        run([hosting, joining], seconds: 1.6)

        check("a host script loads an animation onto a joined player's character",
              said().contains("loaded 1.6 false"), "\(said())")
        robin.key("P", pressed: true)
        robin.step(dt: 1.0 / 60)
        robin.key("P", pressed: false)
        check("…plays it, and reads that it is playing", said().contains("playing true 1"), "\(said())")
        run([hosting, joining], seconds: 0.35)
        check("…in the joined player's game, which plays it for everyone",
              abs(sam.currentJoints.rightShoulder.z) > resting + 1 && samsArmAtTheHost() > resting + 1,
              "\(sam.currentJoints.rightShoulder.z)")
        run([hosting, joining], seconds: 1.5)
        check("when it has played through, the host's script hears Stopped", said().contains("stopped false"), "\(said())")
        check("…and the arm comes down", samsArmAtTheHost() < resting + 0.3, "\(samsArmAtTheHost())")
        let errors = (robin.console.lines + sam.console.lines).filter { $0.kind == .error }.map(\.text)
        check("none of it raised an error", errors.isEmpty, errors.joined(separator: " | "))
        joining.leaveGame()
        hosting.leaveGame()
    }
}
