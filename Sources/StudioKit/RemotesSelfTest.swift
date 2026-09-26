import Foundation
import simd

/// Verification for scripts working together: ModuleScripts and `require`; data objects
/// (Folders, Values, RemoteEvents, RemoteFunctions) in ReplicatedStorage, the Workspace
/// and Players; remotes between a game's server and its clients; `workspace:Raycast`
/// against parts and characters; leaderstats and the leaderboard — alone, and between a
/// host and a joined player.
enum RemotesSelfTest {

    static func run(check: Checker) {
        testModel(check)
        testModules(check)
        testDataObjects(check)
        testRemotes(check)
        testRaycast(check)
        testLeaderboard(check)
        testReadmeExamples(check)
        testTwoPlayers(check)
    }

    private static let frame: Float = 1.0 / 60

    private static func world() -> SceneModel {
        let model = SceneModel()
        var floor = Part()
        floor.name = "Floor"
        floor.size = Vec3(200, 1, 200)
        floor.position = Vec3(0, -0.5, 0)
        floor.anchored = true
        model.parts = [floor]
        model.scripts = []
        model.shaders = []
        model.groups = []
        model.starterGui = []
        model.sounds = []
        model.dataObjects = []
        for name in ["ChatScript", "BackpackScript"] {
            var off = ScriptObject.blank(language: .luau)
            off.name = name
            off.host = .starterPlayer
            off.enabled = false
            model.scripts.append(off)
        }
        return model
    }

    @discardableResult
    private static func add(_ model: SceneModel, _ source: String, name: String = "Test", host: ScriptHost = .scene,
                            parent: UUID? = nil, module: Bool = false) -> UUID {
        var script = ScriptObject.blank(language: .luau)
        script.name = name
        script.source = source
        script.host = host
        script.parentID = parent
        if module { script.kind = .module }
        model.scripts.append(script)
        return script.id
    }

    private static func play(_ model: SceneModel, seconds: Float = 0.5) -> PlayController {
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        step(session, seconds: seconds)
        return session
    }

    private static func step(_ session: PlayController, seconds: Float) {
        var elapsed: Float = 0
        while elapsed < seconds {
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
        said(session).first { $0.hasPrefix(prefix + " ") } ?? "(no \(prefix))"
    }

    // MARK: - Saving and editing

    private static func testModel(_ check: Checker) {
        print("\nTogether: ModuleScripts and data objects in the scene")
        let model = world()
        let steps = model.undoCount
        let module = model.addModuleScript()
        let remote = model.addDataObject(.remoteEvent)
        let folder = model.addDataObject(.folder)
        let value = model.addDataObject(.intValue, in: .node(folder))
        model.updateDataObject(id: value) { _ = $0.setValue(.number(7.6)) }
        check("a ModuleScript goes in ReplicatedStorage with its template; a RemoteEvent, a Folder and a Value too",
              model.script(id: module)?.isModule == true && model.script(id: module)?.host == .replicatedStorage
              && model.script(id: module)?.source == ScriptObject.moduleTemplate
              && model.dataObject(id: remote)?.parent == .replicatedStorage
              && model.dataObject(id: value)?.parent == .node(folder) && model.dataObject(id: value)?.number == 8
              && model.undoCount == steps + 4)
        let saved = try? JSONEncoder().encode(model.state)
        let reopened = saved.flatMap { try? JSONDecoder().decode(SceneState.self, from: $0) }
        check("they're saved with the scene", reopened?.scripts.first { $0.id == module }?.kind == .module
              && reopened?.dataObjects == model.dataObjects)
        let old = try? JSONDecoder().decode(ScriptObject.self, from: Data("{\"name\":\"Old\",\"language\":\"luau\"}".utf8))
        check("…and a script saved before them is still a Script", old?.kind == .script)
        model.removeDataObjects([folder])
        check("deleting a Folder takes what's in it", model.dataObject(id: value) == nil)
        model.undo()
        check("…and undo brings them back", model.dataObject(id: value) != nil)

        var part = Part()
        part.name = "Crate"
        model.parts.append(part)
        var inPart = DataObject(name: "Health", className: .numberValue, parent: .node(part.id))
        inPart.number = 5
        model.dataObjects.append(inPart)
        let copy = model.cloneSubtree(part.id, parent: nil)
        check("a Value in a part is copied with it", copy.map { model.dataObjects(in: .node($0)).count == 1 } == true)
        model.removeSubtrees([part.id])
        check("…and goes when the part does", model.dataObject(id: inPart.id) == nil)
    }

    // MARK: - Modules

    private static func testModules(_ check: Checker) {
        print("\nTogether: ModuleScripts")
        let model = world()
        var crate = Part()
        crate.name = "Crate"
        crate.position = Vec3(20, 1, 0)
        model.parts.append(crate)
        add(model, """
        print("greeter loaded", script.ClassName, script.Parent == game:GetService("ReplicatedStorage"))
        local Greeter = { count = 0 }
        function Greeter.greet(name)
        \tGreeter.count += 1
        \treturn "Hello, " .. name .. "!"
        end
        return Greeter
        """, name: "Greeter", host: .replicatedStorage, module: true)
        add(model, "return { speed = 42 }", name: "Config", module: true)
        add(model, "return { kind = \"crate\" }", name: "Info", parent: crate.id, module: true)
        add(model, "local B = require(game.ReplicatedStorage.CycleB)\nreturn {}", name: "CycleA",
            host: .replicatedStorage, module: true)
        add(model, "local A = require(game.ReplicatedStorage.CycleA)\nreturn {}", name: "CycleB",
            host: .replicatedStorage, module: true)
        add(model, "local x = 1", name: "Nothing", host: .replicatedStorage, module: true)
        add(model, "error(\"broken on purpose\")\nreturn {}", name: "Broken", host: .replicatedStorage, module: true)
        add(model, "return {", name: "Typo", host: .replicatedStorage, module: true)
        add(model, "print(\"a module ran by itself\")\nreturn 1", name: "Quiet", host: .replicatedStorage, module: true)
        add(model, """
        local ReplicatedStorage = game:GetService("ReplicatedStorage")
        local Greeter = require(ReplicatedStorage:WaitForChild("Greeter"))
        local again = require(ReplicatedStorage.Greeter)
        print("greet", Greeter.greet("Robin"), again == Greeter, Greeter.count)
        print("service", require(game:GetService("ServerScriptService").Config).speed,
        \trequire(workspace.Crate.Info).kind, workspace.Crate.Info.ClassName)
        local function why(f)
        \tlocal ok, message = pcall(f)
        \treturn if ok then "fine" else message
        end
        print("cycle", string.find(why(function() require(ReplicatedStorage.CycleA) end), "recursively") ~= nil)
        print("none", why(function() require(ReplicatedStorage.Nothing) end))
        print("broken", string.find(why(function() require(ReplicatedStorage.Broken) end), "broken on purpose") ~= nil,
        \twhy(function() require(ReplicatedStorage.Broken) end))
        print("typo", why(function() require(ReplicatedStorage.Typo) end))
        print("bad", why(function() require(12345) end) ~= "fine", why(function() require(workspace.Crate) end))
        """, name: "UsesModules")
        add(model, """
        local Greeter = require(game:GetService("ReplicatedStorage").Greeter)
        print("local", Greeter.greet("Sam"), Greeter.count)
        """, name: "LocalUser", host: .starterPlayer)
        let session = play(model)
        let output = said(session)
        check("require runs a ModuleScript once and hands back what it returned, to every script that asks",
              output.filter { $0.hasPrefix("greeter loaded") } == ["greeter loaded ModuleScript true"]
              && line(session, "greet") == "greet Hello, Robin! true 1" && line(session, "local").hasPrefix("local Hello, Sam!"),
              "\(output)")
        check("ModuleScripts are found in Script Service and in parts too",
              line(session, "service") == "service 42 crate ModuleScript", line(session, "service"))
        check("…and never run by themselves", !output.contains("a module ran by itself"))
        check("a module requiring itself round a loop is stopped", line(session, "cycle") == "cycle true",
              line(session, "cycle"))
        check("…one that returns nothing, or errors, or doesn't compile, says so",
              line(session, "none").hasSuffix("Module code did not return exactly one value")
              && line(session, "broken").hasPrefix("broken true")
              && line(session, "broken").hasSuffix("Requested module experienced an error while loading")
              && line(session, "typo").hasSuffix("Requested module experienced an error while loading"),
              line(session, "none") + " | " + line(session, "broken") + " | " + line(session, "typo"))
        check("…and require takes only a ModuleScript",
              line(session, "bad").hasPrefix("bad true")
              && line(session, "bad").hasSuffix("Attempted to call require with invalid argument(s)."), line(session, "bad"))
        check("the module that doesn't compile is reported when the game starts",
              said(session, .error).contains { $0.hasPrefix("Typo:") }, "\(said(session, .error))")
        session.stop()
    }

    // MARK: - Data objects

    private static func testDataObjects(_ check: Checker) {
        print("\nTogether: Folders and Values")
        let model = world()
        var crate = Part()
        crate.name = "Crate"
        crate.position = Vec3(20, 1, 0)
        model.parts.append(crate)
        add(model, """
        local ReplicatedStorage = game:GetService("ReplicatedStorage")
        local health = Instance.new("IntValue")
        health.Name = "Health"
        health.Value = 2.6
        health.Parent = workspace.Crate
        local heard = {}
        health.Changed:Connect(function(value) table.insert(heard, value) end)
        print("int", workspace.Crate.Health.Value, health:IsA("ValueBase"), health.Parent == workspace.Crate,
        \t#workspace.Crate:GetChildren())
        local label = Instance.new("StringValue", ReplicatedStorage)
        label.Value = 12
        print("string", label.Value, typeof(label.Value), ReplicatedStorage.StringValue == label)
        print("bool", (pcall(function() Instance.new("BoolValue").Value = "yes" end)))
        local settings = Instance.new("Folder")
        settings.Name = "Settings"
        settings.Parent = ReplicatedStorage
        local speed = Instance.new("NumberValue", settings)
        speed.Name = "Speed"
        speed.Value = 1.5
        print("folder", ReplicatedStorage.Settings.Speed.Value, #settings:GetChildren(), settings.ClassName,
        \tspeed:GetFullName())
        local copy = settings:Clone()
        print("clone", copy.Parent == nil, copy.Speed.Value, copy.Speed ~= speed)
        task.delay(0.2, function()
        \tlocal late = Instance.new("RemoteEvent")
        \tlate.Name = "Late"
        \tlate.Parent = ReplicatedStorage
        end)
        local waited = ReplicatedStorage:WaitForChild("Late")
        print("waited", waited.ClassName)
        health.Value = 10
        health.Value = 11
        task.wait(0.1)
        print("changed", table.concat(heard, ","))
        settings:Destroy()
        print("gone", ReplicatedStorage:FindFirstChild("Settings") == nil, speed.Parent == nil)
        local player = game:GetService("Players").LocalPlayer
        local leaderstats = Instance.new("Folder")
        leaderstats.Name = "leaderstats"
        leaderstats.Parent = player
        local coins = Instance.new("IntValue")
        coins.Name = "Coins"
        coins.Parent = leaderstats
        coins.Value = 5
        print("leaderstats", player.leaderstats.Coins.Value, player:FindFirstChild("leaderstats") == leaderstats,
        \tleaderstats.Parent == player, workspace:FindFirstChild("leaderstats") == nil)
        """, name: "Values")
        let session = play(model, seconds: 0.2)
        step(session, seconds: 0.4)
        check("an IntValue rounds, lives in a part and is found there", line(session, "int") == "int 3 true true 1",
              line(session, "int"))
        check("a StringValue takes a number as text; a BoolValue only true or false",
              line(session, "string") == "string 12 string true" && line(session, "bool") == "bool false",
              line(session, "string") + " | " + line(session, "bool"))
        check("Folders hold Values, in ReplicatedStorage too", line(session, "folder") == "folder 1.5 1 Folder ReplicatedStorage.Settings.Speed",
              line(session, "folder"))
        check("Clone copies a Folder and what's in it", line(session, "clone") == "clone true 1.5 true", line(session, "clone"))
        check("WaitForChild waits for what isn't there yet", line(session, "waited") == "waited RemoteEvent",
              line(session, "waited"))
        check("Changed fires with each new value", line(session, "changed") == "changed 10,11", line(session, "changed"))
        check("Destroy takes a Folder and what's in it", line(session, "gone") == "gone true true", line(session, "gone"))
        check("a Folder parented to a Player becomes their leaderstats, out of the Workspace",
              line(session, "leaderstats") == "leaderstats 5 true true true"
              && session.model.dataObjects.contains { $0.name == "leaderstats" && $0.parent == .player(0) }
              && !session.model.groups.contains { $0.name == "leaderstats" }, line(session, "leaderstats"))
        check("…with no errors", said(session, .error).isEmpty, "\(said(session, .error))")
        session.stop()
    }

    // MARK: - Remotes, on one machine

    private static func testRemotes(_ check: Checker) {
        print("\nTogether: remotes in a game played alone")
        let model = world()
        var crate = Part()
        crate.name = "Crate"
        model.parts.append(crate)
        model.dataObjects = [DataObject(name: "Shout", className: .remoteEvent, parent: .replicatedStorage),
                             DataObject(name: "Ask", className: .remoteFunction, parent: .replicatedStorage)]
        add(model, """
        local ReplicatedStorage = game:GetService("ReplicatedStorage")
        local Shout, Ask = ReplicatedStorage.Shout, ReplicatedStorage.Ask
        Shout.OnServerEvent:Connect(function(player, word, where, list, part)
        \tprint("server heard", player.Name, word, typeof(where), where.Y, list.name, #list.items, list.items[2],
        \t\tpart == workspace.Crate)
        \tShout:FireClient(player, "back to you", Color3.new(1, 0, 0))
        \tShout:FireAllClients("everyone")
        end)
        Ask.OnServerInvoke = function(player, number)
        \tif number < 0 then
        \t\terror("no negatives")
        \tend
        \treturn number * 2, player.Name
        end
        print("server can't", (pcall(function() Shout:FireServer() end)))
        print("callback", (pcall(function() return Ask.OnServerInvoke end)))
        """, name: "Server")
        add(model, """
        local ReplicatedStorage = game:GetService("ReplicatedStorage")
        local Shout, Ask = ReplicatedStorage:WaitForChild("Shout"), ReplicatedStorage:WaitForChild("Ask")
        Shout.OnClientEvent:Connect(function(...)
        \tlocal values = { ... }
        \tprint("client heard", tostring(values[1]), typeof(values[2]))
        end)
        Ask.OnClientInvoke = function(question)
        \treturn "client says " .. question
        end
        Shout:FireServer("hello", Vector3.new(1, 2, 3), { name = "list", items = { "a", "b" } }, workspace.Crate)
        local doubled, who = Ask:InvokeServer(21)
        print("invoked", doubled, who)
        local ok, message = pcall(function() return Ask:InvokeServer(-1) end)
        print("invoke error", ok, string.find(message, "no negatives") ~= nil)
        print("client can't", (pcall(function() Shout:FireClient(game.Players.LocalPlayer) end)))
        """, name: "Client", host: .starterPlayer)
        let session = play(model, seconds: 0.6)
        check("FireServer reaches OnServerEvent with the player first, and tables, Vector3s and parts come through",
              line(session, "server heard") == "server heard Player hello Vector3 2 list 2 b true", line(session, "server heard"))
        check("FireClient and FireAllClients reach OnClientEvent",
              said(session).contains("client heard back to you Color3") && said(session).contains("client heard everyone nil"),
              "\(said(session))")
        check("InvokeServer waits for what OnServerInvoke returns", line(session, "invoked") == "invoked 42 Player",
              line(session, "invoked"))
        check("…and an error there comes back to the caller", line(session, "invoke error") == "invoke error false true",
              line(session, "invoke error"))
        check("the server can't FireServer and the client can't FireClient; a callback can't be read",
              line(session, "server can't") == "server can't false" && line(session, "client can't") == "client can't false"
              && line(session, "callback") == "callback false", "\(said(session))")
        check("…with no errors", said(session, .error).isEmpty, "\(said(session, .error))")
        session.stop()
    }

    // MARK: - Raycasts

    private static func testRaycast(_ check: Checker) {
        print("\nTogether: workspace:Raycast")
        let model = world()
        func block(_ name: String, _ position: Vec3, collide: Bool = true, water: Bool = false) {
            var part = Part()
            part.name = name
            part.size = Vec3(4, 4, 4)
            part.position = position
            part.anchored = true
            part.canCollide = collide
            if water { part.material = .water }
            model.parts.append(part)
        }
        block("Front", Vec3(30, 5, 0))
        block("Back", Vec3(40, 5, 0))
        block("Ghost", Vec3(20, 5, 0), collide: false)
        block("Pool", Vec3(10, 5, 0), water: true)
        add(model, """
        local origin = Vector3.new(0, 5, 0)
        local along = Vector3.new(100, 0, 0)
        local function describe(result)
        \tif result == nil then
        \t\treturn "nothing"
        \tend
        \treturn string.format("%s %.1f %.1f %d %s", result.Instance.Name, result.Position.X, result.Distance,
        \t\tresult.Normal.X, result.Material.Name)
        end
        print("first", describe(workspace:Raycast(origin, along)))
        local params = RaycastParams.new()
        params.IgnoreWater = true
        params.RespectCanCollide = true
        print("solid", describe(workspace:Raycast(origin, along, params)))
        params.FilterDescendantsInstances = { workspace.Front }
        print("excluded", describe(workspace:Raycast(origin, along, params)))
        params.FilterType = Enum.RaycastFilterType.Include
        params.FilterDescendantsInstances = { workspace.Back }
        print("included", describe(workspace:Raycast(origin, along, params)))
        print("short", describe(workspace:Raycast(origin, Vector3.new(5, 0, 0))))
        print("bad", (pcall(function() workspace:Raycast(origin, along, {}) end)))
        local character = game:GetService("Players").LocalPlayer.Character
        local root = character:WaitForChild("HumanoidRootPart")
        local hit = workspace:Raycast(root.Position + Vector3.new(0, 0, -10), Vector3.new(0, 0, 20))
        print("character", hit and hit.Instance.Name, hit and hit.Instance.Parent == character,
        \thit and math.round(hit.Normal.Z))
        local skip = RaycastParams.new()
        skip.FilterDescendantsInstances = { character }
        local through = workspace:Raycast(root.Position + Vector3.new(0, 0, -10), Vector3.new(0, 0, 20), skip)
        print("through", through == nil)
        """, name: "Rays")
        let session = play(model, seconds: 0.4)
        check("a ray meets the first part in its way: what, where, how far, facing which way, made of what",
              line(session, "first") == "first Pool 8.0 8.0 -1 Water", line(session, "first"))
        check("…IgnoreWater and RespectCanCollide skip water and parts that don't collide",
              line(session, "solid") == "solid Front 28.0 28.0 -1 Plastic", line(session, "solid"))
        check("…an Exclude filter goes past what it lists, an Include filter sees only that",
              line(session, "excluded") == "excluded Back 38.0 38.0 -1 Plastic"
              && line(session, "included") == "included Back 38.0 38.0 -1 Plastic",
              line(session, "excluded") + " | " + line(session, "included"))
        check("…a ray too short meets nothing, and the params must be RaycastParams",
              line(session, "short") == "short nothing" && line(session, "bad") == "bad false",
              line(session, "short") + " | " + line(session, "bad"))
        check("a ray meets a character's body part, in the character",
              line(session, "character") == "character Torso true -1" && line(session, "through") == "through true",
              line(session, "character") + " | " + line(session, "through"))
        check("…with no errors", said(session, .error).isEmpty, "\(said(session, .error))")
        session.stop()
    }

    // MARK: - The leaderboard

    private static func testLeaderboard(_ check: Checker) {
        print("\nTogether: the leaderboard")
        let model = world()
        let hud = DefaultHud.make()
        model.starterGui = hud.objects
        model.scripts += hud.scripts.filter { $0.name != DefaultHud.keysScriptName }
        add(model, """
        local player = game:GetService("Players").LocalPlayer
        task.wait(0.3)
        local leaderstats = Instance.new("Folder")
        leaderstats.Name = "leaderstats"
        leaderstats.Parent = player
        local coins = Instance.new("IntValue")
        coins.Name = "Coins"
        coins.Value = 25
        coins.Parent = leaderstats
        local rank = Instance.new("StringValue")
        rank.Name = "Rank"
        rank.Value = "Gold"
        rank.Parent = leaderstats
        """, name: "Stats")
        let session = play(model, seconds: 0.2)
        func board() -> GuiObject? {
            guard let screen = session.model.guiChildren(of: nil).first(where: { $0.name == DefaultHud.listName }),
                  let copy = session.guiCopies[screen.id] else { return nil }
            return session.gui.descendants(of: copy).compactMap(session.gui.object).first { $0.name == "Board" }
        }
        func lines() -> [String] {
            guard let board = board() else { return [] }
            return session.gui.children(of: board.id).compactMap(session.gui.object)
                .filter { $0.kind == .textLabel && $0.visible }.map { $0.text.trimmingCharacters(in: .whitespaces) }
        }
        check("no leaderboard while nobody has leaderstats", board()?.visible == false)
        step(session, seconds: 0.6)
        let shown = lines()
        check("leaderstats make the leaderboard: a column for each Value, a row for each player",
              board()?.visible == true && shown.count == 2 && shown[0].hasPrefix("Player") && shown[0].contains("Coins")
              && shown[0].contains("Rank") && shown[1].hasPrefix("Player") && shown[1].contains("25")
              && shown[1].contains("Gold"), "\(shown)")
        let stats = session.gui.descendants(of: session.guiCopies[session.model.guiChildren(of: nil)
            .first { $0.name == DefaultHud.screenName }!.id]!).compactMap(session.gui.object).first { $0.name == "Stats" }
        check("…and the HUD's numbers move down out of its way", (stats?.position.yOffset ?? 0) > 40,
              "\(String(describing: stats?.position))")
        session.key("Tab", pressed: true)
        session.key("Tab", pressed: false)
        step(session, seconds: 0.1)
        check("Tab hides it", board()?.visible == false)
        check("…with no errors", said(session, .error).isEmpty, "\(said(session, .error))")
        session.stop()
    }

    // MARK: - The README's examples

    /// The README's module, remote, leaderstats and raycast examples, as they are written.
    private static func testReadmeExamples(_ check: Checker) {
        print("\nTogether: the README's examples")
        guard let readme = try? String(contentsOfFile: "README.md", encoding: .utf8),
              let start = readme.range(of: "## Scripts working together"),
              let end = readme.range(of: "## Wren, the second language") else {
            print("  (README.md not found from here; skipped)")
            return
        }
        let section = String(readme[start.upperBound..<end.lowerBound])
        var blocks = section.components(separatedBy: "```lua\n").dropFirst().map { $0.components(separatedBy: "```")[0] }
        guard blocks.count == 4 else {
            check("the README has its four examples", false, "\(blocks.count)")
            return
        }
        let model = world()
        var coin = Part()
        coin.name = "Coin"
        coin.anchored = true
        coin.canCollide = false
        coin.size = Vec3(4, 6, 4)
        coin.position = Vec3(0, 3, 0)
        model.parts.append(coin)
        model.dataObjects = [DataObject(name: "Buy", className: .remoteFunction, parent: .replicatedStorage),
                             DataObject(name: "Announce", className: .remoteEvent, parent: .replicatedStorage)]
        // The module example is two scripts in one block: the module, then its use.
        let parts = blocks[0].components(separatedBy: "-- any Script or LocalScript\n")
        add(model, parts[0], name: "Weapons", host: .replicatedStorage, module: true)
        add(model, parts[1], name: "UsesWeapons")
        // The remote example: the LocalScript, then the Script.
        let remote = blocks[1].components(separatedBy: "-- A Script: the server decides.\n")
        add(model, remote[0], name: "Shopper", host: .starterPlayer)
        add(model, "local ReplicatedStorage = game:GetService(\"ReplicatedStorage\")\n" + remote[1], name: "Shop")
        add(model, blocks[2], name: "Leaderstats")
        blocks[3] = blocks[3].replacingOccurrences(of: "print(\"hit\"", with: "print(\"ray hit\"")
        add(model, "task.wait(0.3)\n" + blocks[3], name: "Ray", host: .starterPlayer)
        let session = play(model, seconds: 0.3)
        session.character.position = coin.position - Vec3(0, 3, 0)
        step(session, seconds: 0.5)
        let output = said(session)
        check("the module example prints what it says", output.contains("Sword does 25 damage"), "\(output)")
        check("the leaderstats example gives coins for touching the coin, and the shop turns them away",
              session.model.dataObjects.contains { $0.name == "Coins" && $0.number >= 1 }
              && output.contains("Not enough coins"), "\(output) \(session.model.dataObjects.map(\.name))")
        check("the raycast example runs", said(session, .error).isEmpty, "\(said(session, .error))")
        session.stop()
    }

    // MARK: - Two players

    private static func testTwoPlayers(_ check: Checker) {
        print("\nTogether: a host and a joined player")
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            var target = Part()
            target.name = "Target"
            target.anchored = true
            target.position = Vec3(0, 3, 40)
            model.parts.append(target)
            model.dataObjects = [DataObject(name: "Ping", className: .remoteEvent, parent: .replicatedStorage),
                                 DataObject(name: "Ask", className: .remoteFunction, parent: .replicatedStorage)]
            let list = DefaultHud.makeLeaderboard()
            model.starterGui += list.objects
            model.scripts += list.scripts
            add(model, "return { answer = 42 }", name: "Shared",
                host: .replicatedStorage, module: true)
            add(model, """
            local Players = game:GetService("Players")
            local ReplicatedStorage = game:GetService("ReplicatedStorage")
            local function setUp(player)
            \tlocal leaderstats = Instance.new("Folder")
            \tleaderstats.Name = "leaderstats"
            \tleaderstats.Parent = player
            \tlocal coins = Instance.new("IntValue")
            \tcoins.Name = "Coins"
            \tcoins.Parent = leaderstats
            end
            for _, player in Players:GetPlayers() do
            \tsetUp(player)
            end
            Players.PlayerAdded:Connect(setUp)
            ReplicatedStorage.Ping.OnServerEvent:Connect(function(player, amount, part)
            \tplayer.leaderstats.Coins.Value += amount
            \tprint("ping", player.Name, amount, part == workspace.Target)
            \tReplicatedStorage.Ping:FireClient(player, "thanks", player.leaderstats.Coins.Value)
            end)
            ReplicatedStorage.Ask.OnServerInvoke = function(player, question)
            \treturn question .. "? " .. player.Name
            end
            print("host module", require(ReplicatedStorage.Shared).answer)
            task.wait(0.5)
            local late = Instance.new("RemoteEvent")
            late.Name = "Late"
            late.Parent = ReplicatedStorage
            """, name: "Server")
            add(model, """
            local Players = game:GetService("Players")
            local ReplicatedStorage = game:GetService("ReplicatedStorage")
            local player = Players.LocalPlayer
            if player.Name ~= "Sam" then
            \treturn
            end
            local Ping = ReplicatedStorage:WaitForChild("Ping")
            Ping.OnClientEvent:Connect(function(word, coins)
            \tprint("client heard", word, coins)
            end)
            print("joiner module", require(ReplicatedStorage:WaitForChild("Shared")).answer)
            local coins = player:WaitForChild("leaderstats"):WaitForChild("Coins")
            coins.Changed:Connect(function(value)
            \tprint("coins now", value)
            end)
            Ping:FireServer(5, workspace.Target)
            print("asked", ReplicatedStorage.Ask:InvokeServer("who"))
            print("late", ReplicatedStorage:WaitForChild("Late").ClassName)
            """, name: "Client", host: .starterPlayer)
        }), let host = hosting.player, let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        func heard(_ session: PlayController) -> [String] {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            return session.console.lines.filter { $0.kind == .output }.map(\.text)
        }
        LANSelfTest.run([hosting, joining], seconds: 1.5)
        check("a module is required on each machine", heard(host).contains("host module 42")
              && heard(sam).contains("joiner module 42"), "\(heard(host)) \(heard(sam))")
        check("a joined player's FireServer reaches the host's OnServerEvent, as that player, with a part",
              heard(host).contains("ping Sam 5 true"), "\(heard(host))")
        check("…and the host's FireClient comes back to them",
              heard(sam).contains("client heard thanks 5"), "\(heard(sam))")
        check("InvokeServer from a joined player gets the host's answer", heard(sam).contains("asked who? Sam"),
              "\(heard(sam))")
        check("leaderstats the host makes reach the player, and Changed fires there as the host changes them",
              heard(sam).contains("coins now 5")
              && sam.model.dataObjects.contains { $0.name == "Coins" && $0.number == 5 }, "\(heard(sam))")
        check("a remote the host makes later is waited for, and arrives", heard(sam).contains("late RemoteEvent"),
              "\(heard(sam))")
        // The joined player's leaderboard shows both players.
        let rows: [String] = {
            guard let screen = sam.model.guiChildren(of: nil).first(where: { $0.name == DefaultHud.listName }),
                  let copy = sam.guiCopies[screen.id],
                  let board = sam.gui.descendants(of: copy).compactMap(sam.gui.object).first(where: { $0.name == "Board" })
            else { return [] }
            return sam.gui.children(of: board.id).compactMap(sam.gui.object)
                .filter { $0.kind == .textLabel && $0.visible }.map(\.text)
        }()
        check("the joined player's leaderboard lists both players, the richer first",
              rows.count == 3 && rows[1].hasPrefix("Sam") && rows[1].contains("5") && rows[2].hasPrefix("Robin"), "\(rows)")
        // The host's ray meets the joined player.
        sam.character.position = Vec3(0, 0, 20)
        LANSelfTest.run([hosting, joining], seconds: 0.4)
        let ray = host.scripts.invoke("workspace.raycast", [.triple(0, 3, 0), .triple(0, 0, 100), .list([]), .bool(false),
                                                            .bool(false), .bool(false)]).asList
        check("the host's rays meet a joined player's body", ray?.first?.asString?.hasPrefix("bp:") == true
              && (ray?[3].asDouble ?? 0) < 25, "\(String(describing: ray))")
        check("…with no errors on either", host.console.lines.filter { $0.kind == .error }.isEmpty
              && sam.console.lines.filter { $0.kind == .error }.isEmpty,
              "\(host.console.lines.filter { $0.kind == .error }.map(\.text)) \(sam.console.lines.filter { $0.kind == .error }.map(\.text))")
        joining.leaveGame()
        LANSelfTest.run([hosting], seconds: 0.4)
        check("a player who leaves takes their leaderstats with them",
              !host.model.dataObjects.contains { $0.parent != .player(0) && $0.name == "leaderstats" },
              "\(host.model.dataObjects.map { "\($0.name) \($0.parent.token)" })")
        hosting.leaveGame()
    }
}
