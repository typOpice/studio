import Foundation

/// Verification for the default HUD: nothing the player sees in play is built into the
/// app. A new scene starts with StarterGui's PlayerHud — health, the respawn countdown,
/// numbers, controls, a crosshair and script output, as GUI objects with LocalScripts —
/// and the Studio keys (F flies, R respawns) are its FlyAndRespawn script; LogService
/// gives scripts what the Output shows. Without the HUD, none of it happens. Checked
/// alone and for a host and a joined player, each with their own.
enum HudSelfTest {

    static func run(check: Checker) {
        testScenes(check)
        testPlaying(check)
        testWithout(check)
        testTwoPlayers(check)
    }

    private static let frame: Float = 1.0 / 60

    private static func step(_ session: PlayController, seconds: Float) {
        var elapsed: Float = 0
        while elapsed < seconds - frame / 2 {
            session.step(dt: frame)
            elapsed += frame
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }

    private static func press(_ session: PlayController, _ key: String, seconds: Float = 0.05) {
        session.key(key, pressed: true)
        session.key(key, pressed: false)
        step(session, seconds: seconds)
    }

    /// An object in this player's copy of PlayerHud, by name.
    private static func hud(_ session: PlayController, _ name: String) -> GuiObject? {
        guard let screen = session.model.guiChildren(of: nil).first(where: { $0.name == DefaultHud.screenName }),
              let copy = session.guiCopies[screen.id] else { return nil }
        return session.gui.descendants(of: copy).compactMap(session.gui.object).first { $0.name == name }
    }

    private static func texts(_ session: PlayController, under name: String) -> [(String, Vec3)] {
        guard let holder = hud(session, name) else { return [] }
        return session.gui.children(of: holder.id).compactMap(session.gui.object)
            .filter { $0.kind == .textLabel }.map { ($0.text, $0.textColor) }
    }

    /// The starter scene with a floor for parts: its HUD and its scripts, chat and
    /// backpack off so only the HUD is on screen.
    private static func hudScene() -> SceneModel {
        let model = SceneModel()
        var floor = Part()
        floor.name = "Floor"
        floor.size = Vec3(200, 1, 200)
        floor.position = Vec3(0, -0.5, 0)
        model.parts = [floor]
        model.groups = []
        model.shaders = []
        model.scripts = model.scripts.filter { $0.host == .starterGui }
        for name in ["ChatScript", "BackpackScript"] {
            var off = ScriptObject.blank(language: .luau)
            off.name = name
            off.host = .starterPlayer
            off.enabled = false
            model.scripts.append(off)
        }
        return model
    }

    // MARK: - Scenes

    private static func testScenes(_ check: Checker) {
        print("\nDefault HUD: in scenes")
        let starter = SceneModel()
        let screen = starter.guiChildren(of: nil).first { $0.name == DefaultHud.screenName }
        check("the starter scene has the default HUD in StarterGui, with its scripts",
              screen != nil && starter.defaultGui == DefaultHud.version
              && starter.guiScripts(in: screen!.id).map(\.name) == [DefaultHud.hudScriptName, DefaultHud.keysScriptName])
        check("…made of ordinary GUI objects",
              ["Health", "Respawning", "Stats", "Controls", "Crosshair", "Output"].allSatisfy { name in
                  starter.guiChildren(of: screen!.id).contains { $0.name == name }
              })
        starter.clearScene()
        check("a new scene starts with it too, and the leaderboard",
              starter.guiChildren(of: nil).map(\.name) == [DefaultHud.screenName, DefaultHud.listName]
              && starter.scripts.count == 3 && starter.defaultGui == DefaultHud.version)

        // Deleted and saved, it stays deleted.
        let deleting = SceneModel()
        for screen in deleting.guiChildren(of: nil) { deleting.deleteGuiObject(screen.id) }
        let saved = try? deleting.encodeScene()
        let reopened = SceneModel()
        if let saved { try? reopened.loadScene(from: saved) }
        check("a scene whose HUD was deleted opens without one",
              reopened.guiChildren(of: nil).isEmpty && !reopened.scripts.contains { $0.host == .starterGui })

        // One made before the HUD, with its own ControlScript for F and R, gets it without the keys.
        var custom = CoreScripts.controlScript
        custom.id = UUID()
        custom.source += "\n-- Enum.KeyCode.F flies here"
        let old = SceneState(scripts: [custom])
        let upgraded = old.upgradedToDefaultHud()
        check("an old scene with its own ControlScript gets the HUD but keeps its own F and R",
              upgraded.starterGui.contains { $0.name == DefaultHud.screenName }
              && upgraded.scripts.map(\.name) == ["ControlScript", DefaultHud.hudScriptName, DefaultHud.listScriptName])

        // One saved with the first HUD (before the leaderboard) gets the leaderboard, unless
        // its HUD was deleted.
        var first = SceneState(defaultGui: 1)
        let hud = DefaultHud.make()
        // make() puts the leaderboard's objects last.
        let listIDs = Set(hud.objects.suffix(DefaultHud.makeLeaderboard().objects.count).map(\.id))
        first.starterGui = hud.objects.filter { !listIDs.contains($0.id) }
        first.scripts = hud.scripts.filter { $0.name != DefaultHud.listScriptName }
        let withList = first.upgradedToDefaultHud()
        var bare = SceneState(defaultGui: 1)
        bare.scripts = []
        check("a scene from before the leaderboard that kept its HUD gets it; one without its HUD doesn't",
              first.starterGui.count == hud.objects.count - listIDs.count
              && withList.starterGui.filter { $0.parentID == nil }.map(\.name) == [DefaultHud.screenName, DefaultHud.listName]
              && withList.scripts.filter { $0.name == DefaultHud.listScriptName }.count == 1
              && bare.upgradedToDefaultHud().starterGui.isEmpty)

        let restoring = SceneModel()
        restoring.starterGui = []
        restoring.scripts = []
        let steps = restoring.undoCount
        restoring.addDefaultHud()
        check("Insert Default HUD puts it back, one step to undo",
              restoring.guiChildren(of: nil).map(\.name) == [DefaultHud.screenName, DefaultHud.listName]
              && restoring.scripts.count == 3
              && restoring.undoCount == steps + 1)
    }

    // MARK: - Playing

    private static func testPlaying(_ check: Checker) {
        print("\nDefault HUD: playing")
        let model = hudScene()
        model.starterPlayer.respawnTime = 1
        var test = ScriptObject.blank(language: .luau)
        test.name = "Test"
        test.host = .starterPlayer
        test.source = """
        local Players = game:GetService("Players")
        local LogService = game:GetService("LogService")
        local humanoid = Players.LocalPlayer.Character:WaitForChild("Humanoid")
        LogService.MessageOut:Connect(function(message, messageType)
        \tif message == "careful" then
        \t\tprint("heard " .. messageType.Name)
        \tend
        end)
        task.wait(0.3)
        humanoid.Health = 40
        print("hello from a script")
        warn("careful")
        task.wait(0.2)
        local found = false
        for _, entry in LogService:GetLogHistory() do
        \tif entry.message == "hello from a script" and entry.messageType == Enum.MessageType.MessageOutput
        \t\tand type(entry.timestamp) == "number" then
        \t\tfound = true
        \tend
        end
        print("history", found, LogService:IsA("LogService"), game:GetService("LogService") == LogService)
        """
        model.scripts.append(test)
        let console = ScriptConsole()
        let session = PlayController(model: model, console: console)
        session.start()
        step(session, seconds: 0.15)

        check("each player gets a copy of PlayerHud, with nothing else drawn by the app",
              hud(session, "Health") != nil && hud(session, "Controls")?.visible == true
              && hud(session, "Output")?.visible == false && hud(session, "Crosshair")?.visible == false
              && hud(session, "Respawning")?.visible == false && hud(session, "Amount")?.text == "100")

        step(session, seconds: 0.4)
        let fill = hud(session, "Fill")
        check("its health bar follows the Humanoid: the bar, the number, the colour",
              fill?.size.xScale == 0.4 && hud(session, "Amount")?.text == "40"
              && fill.map { abs($0.backgroundColor.x - 242.0 / 255) < 0.01 } == true,
              "\(String(describing: fill?.size)) \(hud(session, "Amount")?.text ?? "")")
        let position = hud(session, "Coordinates")?.text ?? ""
        check("…and shows where the character is, how fast, its state and the frame rate",
              position.hasPrefix("pos  ") && hud(session, "Speed")?.text.hasPrefix("speed  ") == true
              && hud(session, "State")?.text.hasPrefix("state  ") == true && hud(session, "Fps")?.text == "fps  60",
              "\(position) · \(hud(session, "State")?.text ?? "") · \(hud(session, "Fps")?.text ?? "")")

        press(session, "H")
        let hidden = hud(session, "Controls")?.visible == false
        press(session, "H")
        check("H hides the controls, and brings them back", hidden && hud(session, "Controls")?.visible == true)

        press(session, "Backquote")
        let lines = texts(session, under: "Lines")
        check("` shows script output, as the Output has it",
              hud(session, "Output")?.visible == true && lines.contains { $0.0 == "hello from a script" }
              && lines.contains { $0.0 == "careful" && abs($0.1.x - 242.0 / 255) < 0.01 },
              "\(lines.map(\.0))")
        let said = console.lines.filter { $0.kind == .output }.map(\.text)
        check("LogService: MessageOut with each line and its type, GetLogHistory with those so far",
              said.contains("heard MessageWarning") && said.contains("history true true true"), "\(said)")

        // An error: counted in the numbers.
        console.error("Test:9: broken on purpose")
        step(session, seconds: 0.1)
        check("errors are counted, with the key to see them",
              hud(session, "Errors")?.visible == true && hud(session, "Errors")?.text == "1 error · ` to view")

        // First person: the crosshair.
        session.zoom(100)
        step(session, seconds: 0.1)
        let crosshair = hud(session, "Crosshair")?.visible == true
        session.zoom(-100)
        step(session, seconds: 0.1)
        check("in first person the crosshair shows (MouseBehavior reads LockCenter there)",
              crosshair && hud(session, "Crosshair")?.visible == false)

        press(session, "F")
        let flying = session.humanoid.state == .flying
        press(session, "F")
        check("F flies and lands again — the HUD's FlyAndRespawn script", flying && session.humanoid.state != .flying)
        let generation = session.characterGeneration
        press(session, "R", seconds: 0.2)
        check("R respawns", session.characterGeneration == generation + 1 && hud(session, "Amount")?.text == "100")

        session.humanoid.takeDamage(1000)
        step(session, seconds: 0.1)
        let countdown = hud(session, "Respawning")
        check("dying shows the countdown to coming back",
              countdown?.visible == true && countdown?.text == "Respawning in 1…", countdown?.text ?? "none")
        step(session, seconds: 1.2)
        check("…which goes when the new character comes",
              hud(session, "Respawning")?.visible == false && hud(session, "Amount")?.text == "100")
        let errors = console.lines.filter { $0.kind == .error }.map(\.text).filter { !$0.contains("broken on purpose") }
        check("…with no errors", errors.isEmpty, errors.joined(separator: " | "))
        session.stop()
    }

    // MARK: - Without it

    private static func testWithout(_ check: Checker) {
        print("\nDefault HUD: without it")
        let model = hudScene()
        model.starterGui = []
        model.scripts = model.scripts.filter { $0.host != .starterGui }
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        step(session, seconds: 0.2)
        check("a scene without the HUD has nothing on screen", session.gui.children(of: GuiStore.playerGui).isEmpty)
        press(session, "F")
        let generation = session.characterGeneration
        press(session, "R", seconds: 0.2)
        press(session, "Backquote")
        check("…and F, R and ` do nothing: nothing is built in",
              session.humanoid.state != .flying && session.characterGeneration == generation
              && session.gui.children(of: GuiStore.playerGui).isEmpty)
        session.stop()
    }

    // MARK: - Two players

    private static func testTwoPlayers(_ check: Checker) {
        print("\nDefault HUD: joined players")
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            let hud = DefaultHud.make()
            model.starterGui = hud.objects
            model.scripts += hud.scripts
            var floor = Part()
            floor.name = "Floor"
            floor.size = Vec3(200, 1, 200)
            floor.position = Vec3(0, -0.5, 0)
            model.parts.append(floor)
            var hurt = ScriptObject.blank(language: .luau)
            hurt.source = """
            local Players = game:GetService("Players")
            task.wait(0.6)
            for _, player in Players:GetPlayers() do
            \tif player.Name == "Sam" and player.Character then
            \t\tplayer.Character.Humanoid:TakeDamage(60)
            \tend
            end
            """
            model.scripts.append(hurt)
        }), let host = hosting.player, let player = joining.player else {
            check("a host and a player join", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 1.0)
        check("each player has their own HUD, showing their own health",
              hud(host, "Amount")?.text == "100" && hud(player, "Amount")?.text == "40",
              "host \(hud(host, "Amount")?.text ?? "none"), joined \(hud(player, "Amount")?.text ?? "none")")
        let hostGeneration = host.characterGeneration, playerGeneration = player.characterGeneration
        player.key("R", pressed: true)
        player.key("R", pressed: false)
        LANSelfTest.run([hosting, joining], seconds: 0.4)
        player.key("F", pressed: true)
        player.key("F", pressed: false)
        LANSelfTest.run([hosting, joining], seconds: 0.2)
        check("the joined player's R respawns them, not the host",
              player.characterGeneration == playerGeneration + 1 && host.characterGeneration == hostGeneration
              && hud(player, "Amount")?.text == "100")
        check("…and their F flies them alone", player.humanoid.state == .flying && host.humanoid.state != .flying)
        hosting.leaveGame()
        joining.leaveGame()
    }
}
