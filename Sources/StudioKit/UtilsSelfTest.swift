import Foundation

/// The Utils ModuleScript: in every new place and insertable into old ones; every
/// function run for real; the game helpers on a character in play; suggested by the
/// editor with parameters and descriptions; and used by a host and a joined player.
enum UtilsSelfTest {
    static func run(check: Checker) {
        testInPlaces(check)
        testMaths(check)
        testTables(check)
        testText(check)
        testGameHelpers(check)
        testSuggestions(check)
        testTwoPlayers(check)
    }

    private static let frame: Float = 1.0 / 60
    private static let header = "local Utils = require(game:GetService(\"ReplicatedStorage\").Utils)\n"

    /// Runs Luau expressions after requiring Utils, and reports any that were not true.
    private static func assertAll(_ check: Checker, _ label: String, preamble: String = "", _ expressions: [String]) {
        let model = ScriptSelfTest.scene()
        model.scripts.append(UtilsModule.make())
        var body = header + preamble + "\n"
        for (index, expression) in expressions.enumerated() {
            body += "if not (\(expression)) then print(\"FAILED #\(index)\") end\n"
        }
        ScriptSelfTest.add(model, body)
        let result = ScriptSelfTest.execute(model)
        let failures = result.output.filter { $0.hasPrefix("FAILED") }.map { line -> String in
            let number = Int(line.dropFirst("FAILED #".count)) ?? -1
            return number >= 0 && number < expressions.count ? expressions[number] : line
        }
        check(label, result.errors.isEmpty && failures.isEmpty, (result.errors + failures).prefix(3).joined(separator: " | "))
    }

    // MARK: - In places

    private static func testInPlaces(_ check: Checker) {
        print("\nUtils: in every new place")
        let model = SceneModel()
        func utils() -> [ScriptObject] { model.scripts.filter { $0.name.hasPrefix(UtilsModule.name) } }
        check("the starter scene has Utils in ReplicatedStorage", utils().count == 1 && utils()[0].isModule
              && utils()[0].host == .replicatedStorage && utils()[0].source == UtilsModule.source)
        _ = model.addDataObject(.remoteEvent)
        model.clearScene()
        check("so does a new scene", utils().count == 1 && utils()[0].host == .replicatedStorage)
        check("…which no longer keeps the last place's remotes and Values", model.dataObjects.isEmpty)
        _ = model.addDataObject(.folder)
        model.loadStarterScene()
        check("…nor does the starter scene", model.dataObjects.isEmpty && utils().count == 1)

        // An old place keeps what it had.
        var old = model.state
        old.scripts.removeAll { $0.name == UtilsModule.name }
        check("an old place opened isn't given one", !old.upgradedToDefaultHud().scripts.contains { $0.name == UtilsModule.name })
        model.state = old
        let steps = model.undoCount
        let inserted = model.insertUtilsModule()
        check("Insert Utils Module adds it, named Utils, in one undo step",
              model.script(id: inserted)?.name == "Utils" && model.script(id: inserted)?.source == UtilsModule.source
              && model.script(id: inserted)?.host == .replicatedStorage && model.undoCount == steps + 1)
        let second = model.insertUtilsModule()
        check("…and Utils1 when there is one already", model.script(id: second)?.name == "Utils1")
        model.undo()
        model.undo()
        check("…undone, it's gone", utils().isEmpty)
        model.redo()
        let saved = try? JSONEncoder().encode(model.state)
        let reopened = saved.flatMap { try? JSONDecoder().decode(SceneState.self, from: $0) }
        check("it's saved with the place", reopened?.scripts.contains { $0.name == "Utils" && $0.isModule } == true)
    }

    // MARK: - Every function

    private static func testMaths(_ check: Checker) {
        print("\nUtils: maths")
        assertAll(check, "lerp, clamp, round, remap and approach", [
            "Utils.lerp(0, 10, 0.25) == 2.5",
            "Utils.lerp(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), 0.5) == Vector3.new(5, 0, 0)",
            "Utils.clamp(15, 0, 10) == 10", "Utils.clamp(-1, 0, 10) == 0", "Utils.clamp(4, 0, 10) == 4",
            "Utils.round(7.3) == 7", "Utils.round(7.5) == 8", "Utils.round(7.3, 5) == 5", "Utils.round(8, 5) == 10",
            "math.abs(Utils.round(3.14159, 0.01) - 3.14) < 1e-9", "Utils.round(-2.5) == -2",
            "Utils.remap(5, 0, 10, 0, 100) == 50", "Utils.remap(0, 0, 0, 3, 9) == 3", "Utils.remap(15, 10, 20, 1, 0) == 0.5",
            "Utils.approach(0, 10, 3) == 3", "Utils.approach(9, 10, 3) == 10", "Utils.approach(10, 0, 4) == 6",
            "Utils.approach(1, 0, 4) == 0",
        ])
        assertAll(check, "random numbers stay in range and reach every value", [
            "(function() for i = 1, 300 do local x = Utils.randomBetween(2, 5) if x < 2 or x > 5 then return false end end return true end)()",
            """
            (function() local seen = {} for i = 1, 300 do local n = Utils.randomInt(1, 3)
            if n < 1 or n > 3 or n ~= math.floor(n) then return false end seen[n] = true end
            return seen[1] and seen[2] and seen[3] end)()
            """,
            "Utils.chance(100) == true", "Utils.chance(0) == false",
            "(function() local n = 0 for i = 1, 2000 do if Utils.chance(25) then n += 1 end end return n > 380 and n < 620 end)()",
        ])
        assertAll(check, "wrapAngle takes the short way round", [
            "Utils.wrapAngle(190) == -170", "Utils.wrapAngle(-190) == 170", "Utils.wrapAngle(180) == 180",
            "Utils.wrapAngle(-180) == 180", "Utils.wrapAngle(720) == 0", "Utils.wrapAngle(45) == 45",
        ])
    }

    private static func testTables(_ check: Checker) {
        print("\nUtils: tables")
        assertAll(check, "copy and deepCopy", preamble: "local t = { a = 1, b = { c = 2 } }", [
            "Utils.copy(t) ~= t and Utils.copy(t).b == t.b and Utils.copy(t).a == 1",
            "Utils.deepCopy(t) ~= t and Utils.deepCopy(t).b ~= t.b and Utils.deepCopy(t).b.c == 2",
            "(function() local x = {} x.me = x local y = Utils.deepCopy(x) return y.me == y and y ~= x end)()",
            "Utils.deepCopy({ part = workspace.Brick }).part == workspace.Brick",
            "Utils.deepCopy({ v = Vector3.new(1, 2, 3) }).v == Vector3.new(1, 2, 3)",
            """
            (function() local Class = {} Class.__index = Class function Class.hi() return "hi" end
            return Utils.deepCopy(setmetatable({}, Class)).hi() == "hi" end)()
            """,
        ])
        assertAll(check, "keys, values, count and find", preamble: "local t = { a = 1, b = 2 }", [
            "#Utils.keys(t) == 2", "table.find(Utils.keys(t), 'a') ~= nil", "table.find(Utils.keys(t), 'b') ~= nil",
            "#Utils.values({ 5, 6, x = 7 }) == 3", "table.find(Utils.values({ x = 7 }), 7) == 1",
            "Utils.count({ 1, 2, x = 3 }) == 3", "Utils.count({}) == 0",
            "Utils.find({ 'a', 'b' }, 'b') == 2", "Utils.find({ x = 5 }, 5) == 'x'", "Utils.find({}, 1) == nil",
        ])
        assertAll(check, "filter, map, shuffle, pickRandom and merge", [
            "table.concat(Utils.filter({ 1, 2, 3, 4 }, function(n) return n % 2 == 0 end), ',') == '2,4'",
            "table.concat(Utils.map({ 1, 2, 3 }, function(n, i) return n * 10 + i end), ',') == '11,22,33'",
            """
            (function() local list = { 1, 2, 3, 4, 5 } local s = Utils.shuffle(list) table.sort(s)
            return table.concat(s, ',') == '1,2,3,4,5' and table.concat(list, ',') == '1,2,3,4,5' end)()
            """,
            """
            (function() for i = 1, 30 do if table.concat(Utils.shuffle({ 1, 2, 3, 4, 5, 6 }), ',') ~= '1,2,3,4,5,6'
            then return true end end return false end)()
            """,
            "Utils.pickRandom({}) == nil", "Utils.pickRandom({ 'only' }) == 'only'",
            "table.find({ 'x', 'y' }, Utils.pickRandom({ 'x', 'y' })) ~= nil",
            "Utils.merge({ a = 1, b = 2 }, { b = 3 }, { c = 4 }).b == 3",
            "Utils.count(Utils.merge({ a = 1 }, { b = 2 }, {})) == 2",
        ])
    }

    private static func testText(_ check: Checker) {
        print("\nUtils: text and time")
        assertAll(check, "formatTime", [
            "Utils.formatTime(65) == '1:05'", "Utils.formatTime(3725) == '1:02:05'", "Utils.formatTime(0) == '0:00'",
            "Utils.formatTime(-5) == '0:00'", "Utils.formatTime(59.9) == '0:59'", "Utils.formatTime(600) == '10:00'",
        ])
        assertAll(check, "commas and shorten", [
            "Utils.commas(12500) == '12,500'", "Utils.commas(1234567) == '1,234,567'", "Utils.commas(999) == '999'",
            "Utils.commas(-1234.5) == '-1,234.5'", "Utils.commas(100000) == '100,000'", "Utils.commas(0) == '0'",
            "Utils.shorten(999) == '999'", "Utils.shorten(1500) == '1.5K'", "Utils.shorten(2000000) == '2M'",
            "Utils.shorten(1234567) == '1.2M'", "Utils.shorten(-4500) == '-4.5K'", "Utils.shorten(3e9) == '3B'",
            "Utils.shorten(1000) == '1K'",
        ])
        assertAll(check, "padLeft, split, trim and titleCase", [
            "Utils.padLeft(7, 3, '0') == '007'", "Utils.padLeft('long', 2) == 'long'", "Utils.padLeft('a', 3) == '  a'",
            "table.concat(Utils.split('a,b,c'), '|') == 'a|b|c'", "#Utils.split('a b', ' ') == 2",
            "Utils.trim('  hi there  ') == 'hi there'", "Utils.trim('') == ''", "Utils.trim('x') == 'x'",
            "Utils.titleCase('hello world') == 'Hello World'", "Utils.titleCase(\"it's A TEST\") == \"It's A Test\"",
        ])
    }

    // MARK: - In play

    private static func said(_ session: PlayController) -> [String] {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        return session.console.lines.filter { $0.kind == .output }.map(\.text)
    }

    private static func testGameHelpers(_ check: Checker) {
        print("\nUtils: game helpers, in play")
        let model = ScriptSelfTest.scene()
        model.scripts.append(UtilsModule.make())
        for (name, position) in [("Pad", Vec3(0, 4, 0)), ("A", Vec3(20, 1, 0)), ("B", Vec3(22, 1, 0)), ("Door", Vec3(-20, 3, 0))] {
            var part = Part()
            part.name = name
            part.anchored = true
            part.position = position
            model.parts.append(part)
        }
        ScriptSelfTest.add(model, header + """
        local Players = game:GetService("Players")
        local player = Players:GetPlayers()[1] or Players.PlayerAdded:Wait()
        local character = player.Character or player.CharacterAdded:Wait()
        print("character", Utils.getCharacter(player) == character, Utils.getCharacter(character) == character,
        \tUtils.getCharacter(character.Head) == character, Utils.getCharacter(workspace.Pad) == nil)
        print("player", Utils.playerFromPart(character["Left Leg"]) == player, Utils.playerFromPart(workspace.Pad) == nil,
        \tUtils.playerFromPart(nil) == nil)
        print("humanoid", Utils.getHumanoid(player) == character.Humanoid, Utils.getRoot(character.Head) == character.HumanoidRootPart)
        print("alive", Utils.isAlive(player), Utils.isAlive(workspace.Pad))
        print("distance", math.floor(Utils.distance(player, character.HumanoidRootPart.Position + Vector3.new(3, 4, 0)) + 0.5),
        \tUtils.distance(workspace.Pad, Vector3.new(0, 10, 0)), Utils.distance(workspace.Pad, "nowhere") == math.huge)
        print("position", Utils.positionOf(CFrame.new(1, 2, 3)) == Vector3.new(1, 2, 3))
        local count = 0
        local once = Utils.debounce(0.5, function(n) count += n end)
        once(1)
        once(1)
        task.wait(0.6)
        once(1)
        print("debounce", count)
        local ready = Utils.cooldown(1)
        print("cooldown", ready(player), ready(player), ready("someone else"))
        task.wait(1.1)
        print("cooldown later", ready(player))
        local weld = Utils.weld(workspace.A, workspace.B)
        print("weld", weld.ClassName, weld.Part0 == workspace.A, weld.Part1 == workspace.B)
        local tween = Utils.tween(workspace.Door, 0.3, { Position = workspace.Door.Position + Vector3.new(0, 8, 0) })
        tween.Completed:Wait()
        print("tween", math.floor(workspace.Door.Position.Y + 0.5))
        """, name: "Helpers")
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        var elapsed: Float = 0
        while elapsed < 3 {
            session.step(dt: frame)
            elapsed += frame
        }
        let lines = said(session)
        func line(_ prefix: String) -> String { lines.first { $0.hasPrefix(prefix + " ") } ?? "(no \(prefix))" }
        check("getCharacter from a player, a character and a body part", line("character") == "character true true true true",
              line("character"))
        check("playerFromPart", line("player") == "player true true true", line("player"))
        check("getHumanoid and getRoot", line("humanoid") == "humanoid true true", line("humanoid"))
        check("isAlive", line("alive") == "alive true false", line("alive"))
        check("distance between a player, a part and a point", line("distance") == "distance 5 6 true", line("distance"))
        check("positionOf a CFrame", line("position") == "position true", line("position"))
        check("debounce lets one call through per wait", line("debounce") == "debounce 2", line("debounce"))
        check("cooldown, per key, and ready again later",
              line("cooldown") == "cooldown true false true" && line("cooldown later") == "cooldown later true",
              "\(line("cooldown")) / \(line("cooldown later"))")
        check("weld joins two parts", line("weld") == "weld WeldConstraint true true", line("weld"))
        check("tween moves a part and finishes", line("tween") == "tween 11", line("tween"))
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("…with no errors", errors.isEmpty, "\(errors)")
        session.stop()
    }

    // MARK: - Suggestions

    private static func testSuggestions(_ check: Checker) {
        print("\nUtils: suggested in the editor")
        let model = SceneModel()
        let scene = model.luauScene()
        let source = "local ReplicatedStorage = game:GetService(\"ReplicatedStorage\")\nlocal Utils = require(ReplicatedStorage.Utils)\n"
        func items(_ text: String) -> [CompletionItem] {
            LuauCompletion.items(in: text, caret: (text as NSString).length, scene: scene)
        }
        let exported = Set(UtilsModule.source.components(separatedBy: "\n")
            .filter { $0.hasPrefix("function Utils.") }
            .map { String($0.dropFirst("function Utils.".count).prefix { $0 != "(" }) })
        let offered = items(source + "Utils.")
        let names = Set(offered.map { String($0.label.prefix { $0 != "(" }) })
        check("Utils. suggests every function it has", names == exported && exported.count >= 35,
              "missing \(exported.subtracting(names)), extra \(names.subtracting(exported))")
        check("…with their parameters", Set(offered.map(\.label)).isSuperset(of: [
            "lerp(a, b, t)", "debounce(seconds, callback)", "merge(...)", "formatTime(seconds)", "distance(a, b)",
            "tween(object, seconds, goals, style)"]))
        check("…and what each does", offered.allSatisfy { $0.documentation?.isEmpty == false },
              "\(offered.filter { $0.documentation == nil }.map(\.label))")
        check("…from the comment above it", offered.first { $0.label.hasPrefix("formatTime") }?.documentation
              == "Seconds as a clock shows them: 65 is \"1:05\", 3725 is \"1:02:05\".")
        check("…all of it, when it runs over two lines", offered.first { $0.label.hasPrefix("debounce") }?.documentation?
              .hasSuffix("part.Touched:Connect(Utils.debounce(1, function(hit) ... end))") == true)
        check("its own helpers stay out of the list", !names.contains("characterOf"))
        check("require( offers it", items(source + "local U = require(").first { $0.label == "Utils" }?.insert
              == "ReplicatedStorage.Utils)")
    }

    // MARK: - Two players

    private static func testTwoPlayers(_ check: Checker) {
        print("\nUtils: a host and a joined player")
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            model.scripts.append(UtilsModule.make())
            var target = Part()
            target.name = "Target"
            target.anchored = true
            target.position = Vec3(0, 3, 40)
            model.parts.append(target)
            var server = ScriptObject()
            server.name = "Server"
            server.source = header + """
            local Players = game:GetService("Players")
            task.wait(0.8)
            local players = Players:GetPlayers()
            table.sort(players, function(a, b) return a.Name < b.Name end)
            local robin, sam = players[1], players[2]
            print("host sees", #players, Utils.isAlive(robin), Utils.isAlive(sam))
            print("host from part", Utils.playerFromPart(Utils.getCharacter(sam).Head) == sam,
            \tUtils.playerFromPart(Utils.getCharacter(robin)["Left Arm"]) == robin)
            print("host distance", Utils.distance(robin, sam) < 200, Utils.distance(sam, workspace.Target) < 200)
            print("host text", Utils.commas(12500), Utils.shorten(1500))
            """
            model.scripts.append(server)
            var client = ScriptObject()
            client.name = "Client"
            client.host = .starterPlayer
            client.source = """
            local Players = game:GetService("Players")
            local player = Players.LocalPlayer
            if player.Name ~= "Sam" then
            \treturn
            end
            local Utils = require(game:GetService("ReplicatedStorage"):WaitForChild("Utils"))
            local character = player.Character or player.CharacterAdded:Wait()
            print("joiner", Utils.formatTime(125), Utils.getCharacter(player) == character, Utils.isAlive(player),
            \tUtils.getRoot(player) ~= nil, Utils.distance(player, workspace.Target) < 200)
            """
            model.scripts.append(client)
        }), let host = hosting.player, let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 2)
        let heardHost = said(host), heardSam = said(sam)
        check("the host's script uses Utils on both players", heardHost.contains("host sees 2 true true")
              && heardHost.contains("host from part true true") && heardHost.contains("host distance true true")
              && heardHost.contains("host text 12,500 1.5K"), "\(heardHost)")
        check("the joined player's LocalScript uses its own copy", heardSam.contains("joiner 2:05 true true true true"),
              "\(heardSam)")
        let errors = host.console.lines.filter { $0.kind == .error }.map(\.text)
            + sam.console.lines.filter { $0.kind == .error }.map(\.text)
        check("…with no errors on either", errors.isEmpty, "\(errors)")
        hosting.leaveGame()
        joining.leaveGame()
    }
}
