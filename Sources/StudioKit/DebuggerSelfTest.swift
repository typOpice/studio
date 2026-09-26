import Foundation

/// The Luau debugger: a breakpoint stopping every time its line runs, with the calls
/// (the function it's in, and the line that called it) and their locals and upvalues;
/// a table, a string and an Instance described; Step Over, Into and Out; a breakpoint
/// on a line with no code landing on the next; one put on while running, in a
/// ModuleScript, in a LocalScript, and in a character script after a respawn; the world
/// waiting while stopped, and the watchdog not counting the wait; Stop; breakpoints
/// saved with the place and kept through Stop in Studio; and a host stopped in a
/// RemoteEvent handler with a joined player's message, the reply reaching them after.
enum DebuggerSelfTest {
    static func run(check: Checker) {
        testBreakpoints(check)
        testStepping(check)
        testElsewhere(check)
        testWaiting(check)
        testStudio(check)
        testTogether(check)
    }

    private static let frame: Float = 1.0 / 60

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

    static let counting = """
    local total = 0
    local function add(amount)
    \tlocal before = total
    \ttotal += amount
    \treturn total
    end
    local items = { "sword", "shield", count = 2 }
    for index = 1, 3 do
    \tadd(index)
    end
    -- a comment, with no code on it

    print("total", total, #items)
    """

    /// A place with one Script, and a session debugging it: every stop recorded, answered
    /// from `answers` in turn (then Continue).
    private static func debugged(_ source: String, breakpoints: [Int], answers: [ScriptDebugger.Command] = [],
                                 host: ScriptHost = .scene)
        -> (SceneModel, PlayController, () -> [ScriptDebugger.Pause]) {
        let model = SceneModel()
        var script = ScriptObject.blank(language: .luau)
        script.name = "Counter"
        script.host = host
        script.source = source
        script.breakpoints = breakpoints
        model.scripts = [script]
        let session = PlayController(model: model, console: ScriptConsole())
        var stops: [ScriptDebugger.Pause] = []
        var queue = answers
        session.scripts.debugger = ScriptDebugger { pause in
            stops.append(pause)
            return queue.isEmpty ? .resume : queue.removeFirst()
        }
        return (model, session, { stops })
    }

    private static func variable(_ frame: ScriptDebugger.Frame?, _ name: String) -> String? {
        frame?.variables.first { $0.name == name }?.value
    }

    // MARK: - Breakpoints

    private static func testBreakpoints(_ check: Checker) {
        print("\nDebugger: breakpoints")
        let (model, session, stops) = debugged(counting, breakpoints: [4])
        session.start()
        step(session, seconds: 0.2)
        let seen = stops()
        check("a breakpoint stops each time its line runs", seen.count == 3
              && seen.allSatisfy { $0.reason == .breakpoint && $0.frames.first?.line == 4 }, "\(seen.map(\.frames))")
        let first = seen.first
        check("…in the function, called from the script's line", first?.frames.first?.function == "add"
              && first?.frames.first?.script == "Counter" && first?.frames.count == 2 && first?.frames[1].line == 9
              && first?.frames[1].scriptID == model.scripts[0].id, "\(String(describing: first?.frames))")
        check("…with its locals and upvalues", seen.map { variable($0.frames.first, "amount") } == ["1", "2", "3"]
              && seen.map { variable($0.frames.first, "before") } == ["0", "1", "3"]
              && first?.frames.first?.variables.contains { $0.name == "total" && $0.kind == "upvalue" } == true,
              "\(String(describing: first?.frames.first?.variables))")
        let outer = first?.frames.last?.variables ?? []
        check("…and the caller's: a table shown by what's in it", outer.contains {
            $0.name == "items" && $0.type == "table" && $0.value.contains("\"sword\"") && $0.value.contains("count = 2")
        } && outer.contains { $0.name == "index" && $0.value == "1" } && !outer.contains { $0.name.hasPrefix("(") },
              "\(outer)")
        check("…and the script carries on after", said(session).contains("total 6 2") && said(session, .error).isEmpty,
              "\(said(session)) \(said(session, .error))")
        session.stop()

        let (_, blank, blankStops) = debugged(counting, breakpoints: [11])
        blank.start()
        step(blank, seconds: 0.2)
        check("a breakpoint on a line with no code stops at the next that has some",
              blankStops().count == 1 && blankStops().first?.frames.first?.line == 13,
              "\(blankStops().map { $0.frames.first?.line ?? 0 })")
        blank.stop()

        let described = """
        local name = "a long name, longer than anything the panel will show in one piece, so it is cut short there, at a hundred and twenty characters, and no further"
        local part = workspace:FindFirstChild("Baseplate") or Instance.new("Part")
        local empty = {}
        local nothing = nil
        print(name, part, empty, nothing)
        """
        let (_, values, valueStops) = debugged(described, breakpoints: [5])
        values.start()
        step(values, seconds: 0.2)
        let shown = valueStops().first?.frames.first?.variables ?? []
        check("values described: a long string cut short, an Instance by class and name, an empty table, nil",
              shown.contains { $0.name == "name" && $0.type == "string" && $0.value.hasSuffix("…\"") && $0.value.count < 130 }
              && shown.contains { $0.name == "part" && $0.type == "Instance" && $0.value.hasPrefix("Part \"") }
              && shown.contains { $0.name == "empty" && $0.value == "{}" }
              && shown.contains { $0.name == "nothing" && $0.value == "nil" }, "\(shown)")
        values.stop()
    }

    // MARK: - Stepping

    private static func testStepping(_ check: Checker) {
        print("\nDebugger: stepping")
        let (_, over, overStops) = debugged(counting, breakpoints: [4], answers: [.stepOver, .stepOver, .stepOver])
        over.start()
        step(over, seconds: 0.2)
        let lines = overStops().prefix(4).map { ($0.frames.first?.line ?? 0, $0.reason) }
        check("Step Over: the next line, then out to the caller's",
              lines.count == 4 && lines[0] == (4, .breakpoint) && lines[1] == (5, .step)
              && overStops()[2].frames.first?.function == "" && overStops()[2].reason == .step,
              "\(lines)")
        check("…and on through the loop, stopping again at the breakpoint", overStops().count >= 5
              && said(over).contains("total 6 2"), "\(overStops().map { $0.frames.first?.line ?? 0 })")
        over.stop()

        let (_, into, intoStops) = debugged(counting, breakpoints: [9], answers: [.stepInto])
        into.start()
        step(into, seconds: 0.2)
        check("Step Into: from the call into the function it calls",
              intoStops().count >= 2 && intoStops()[1].frames.first?.function == "add"
              && intoStops()[1].frames.first?.line == 3 && intoStops()[1].reason == .step,
              "\(intoStops().map { ($0.frames.first?.function ?? "", $0.frames.first?.line ?? 0) })")
        into.stop()

        let (_, out, outStops) = debugged(counting, breakpoints: [3], answers: [.stepOut])
        out.start()
        step(out, seconds: 0.2)
        check("Step Out: back to the caller", outStops().count >= 2 && outStops()[1].frames.first?.function == ""
              && outStops()[1].reason == .step && outStops()[1].frames.count == 1,
              "\(outStops().map { ($0.frames.first?.function ?? "", $0.frames.first?.line ?? 0) })")
        out.stop()

        let (_, stopped, stoppedStops) = debugged(counting, breakpoints: [4], answers: [.stop])
        var ended = false
        stopped.onDebuggerStop = { ended = true }
        stopped.start()
        step(stopped, seconds: 0.2)
        stopped.stepFrame()
        check("Stop: no more stops, and the session is asked to end",
              stoppedStops().count == 1 && stopped.scripts.debugger?.stopRequested == true && ended)
        stopped.stop()
    }

    // MARK: - Elsewhere

    private static func testElsewhere(_ check: Checker) {
        print("\nDebugger: modules, LocalScripts, running scripts, characters")
        // A breakpoint put on while it runs.
        let ticking = """
        local RunService = game:GetService("RunService")
        local ticks = 0
        RunService.Heartbeat:Connect(function()
        \tticks += 1
        end)
        """
        let (model, session, stops) = debugged(ticking, breakpoints: [])
        session.start()
        step(session, seconds: 0.3)
        let before = stops().count
        session.scripts.debugger?.setBreakpoint(script: model.scripts[0].id, line: 4, on: true)
        step(session, seconds: 0.05)
        check("a breakpoint put on while the script runs", before == 0 && stops().count >= 1
              && stops().last?.frames.first?.line == 4, "\(before) \(stops().count)")
        session.scripts.debugger?.setBreakpoint(script: model.scripts[0].id, line: 4, on: false)
        let now = stops().count
        step(session, seconds: 0.2)
        check("…and taken off", stops().count == now)
        session.stop()

        // A ModuleScript's function, required by a LocalScript.
        let place = SceneModel()
        var module = ScriptObject.blank(language: .luau)
        module.name = "Greeter"
        module.kind = .module
        module.host = .replicatedStorage
        module.source = """
        local Greeter = {}
        function Greeter.greet(who)
        \tlocal line = "hello " .. who
        \treturn line
        end
        return Greeter
        """
        module.breakpoints = [4]
        var local = ScriptObject.blank(language: .luau)
        local.name = "Hello"
        local.host = .starterPlayer
        local.source = """
        local Greeter = require(game:GetService("ReplicatedStorage"):WaitForChild("Greeter"))
        local who = game:GetService("Players").LocalPlayer.Name
        print(Greeter.greet(who))
        """
        local.breakpoints = [3]
        place.scripts = [module, local]
        let played = PlayController(model: place, console: ScriptConsole())
        var seen: [ScriptDebugger.Pause] = []
        played.scripts.debugger = ScriptDebugger { pause in
            seen.append(pause)
            return .resume
        }
        played.start()
        step(played, seconds: 0.3)
        check("a LocalScript's breakpoint, then a ModuleScript's, called from it",
              seen.count == 2 && seen[0].frames.first?.script == "Hello" && seen[0].frames.first?.line == 3
              && seen[1].frames.first?.script == "Greeter" && seen[1].frames.first?.line == 4
              && variable(seen[1].frames.first, "line") == "\"hello Player\"" && seen[1].frames.last?.script == "Hello",
              "\(seen.map(\.frames))")
        played.stop()

        // A character script: loaded again for each character.
        let (_, respawning, respawnStops) = debugged("""
        local humanoid = script.Parent:WaitForChild("Humanoid")
        print("spawned", humanoid.Health)
        """, breakpoints: [2], host: .starterCharacter)
        respawning.start()
        step(respawning, seconds: 0.3)
        respawning.humanoid.takeDamage(1000)
        step(respawning, seconds: Float(respawning.respawnTime) + 1)
        check("a character script's breakpoint, for the first character and the next",
              respawnStops().count == 2, "\(respawnStops().count)")
        respawning.stop()
    }

    // MARK: - Waiting

    private static func testWaiting(_ check: Checker) {
        print("\nDebugger: while stopped")
        let model = SceneModel()
        var script = ScriptObject.blank(language: .luau)
        script.source = """
        local count = 0
        for index = 1, 5 do
        \tcount += index
        end
        print("done", count)
        """
        script.breakpoints = [3]
        model.scripts = [script]
        let session = PlayController(model: model, console: ScriptConsole())
        session.scripts.timeout = 0.4
        var clocks: [Double] = []
        session.scripts.debugger = ScriptDebugger { _ in
            // Longer than the watchdog allows, and the game told to go on meanwhile.
            let clock = session.clock
            Thread.sleep(forTimeInterval: 0.25)
            session.step(dt: 0.1)
            clocks.append(session.clock - clock)
            return .resume
        }
        session.start()
        step(session, seconds: 0.2)
        check("the world waits while stopped", clocks.count == 5 && clocks.allSatisfy { $0 == 0 }, "\(clocks)")
        check("…and the watchdog doesn't count the wait", said(session).contains("done 15")
              && said(session, .error).isEmpty, "\(said(session, .error))")
        session.stop()
    }

    // MARK: - Studio

    private static func testStudio(_ check: Checker) {
        print("\nDebugger: breakpoints in Studio")
        var script = ScriptObject.blank(language: .luau)
        script.breakpoints = [2, 7]
        let saved = (try? JSONEncoder().encode(script)).flatMap { try? JSONDecoder().decode(ScriptObject.self, from: $0) }
        check("breakpoints are saved with the script", saved?.breakpoints == [2, 7])
        let plain = (try? JSONEncoder().encode(ScriptObject.blank(language: .luau))).map { String(decoding: $0, as: UTF8.self) }
        check("…and a script without any saves as before", plain?.contains("breakpoints") == false)

        let model = SceneModel()
        let session = EditorSession(model: model)
        let id = model.scripts.first { !$0.isModule }!.id
        let revision = model.revision
        session.toggleBreakpoint(script: id, line: 3)
        check("toggling one isn't an edit to undo", model.script(id: id)?.breakpoints == [3] && model.revision == revision)
        session.toggleBreakpoint(script: id, line: 3)
        session.startPlay()
        session.toggleBreakpoint(script: id, line: 5)
        session.toggleBreakpoint(script: id, line: 3)
        session.toggleBreakpoint(script: id, line: 3)
        session.stopPlay()
        check("…and those changed while playing are kept when it stops", model.script(id: id)?.breakpoints == [5],
              "\(String(describing: model.script(id: id)?.breakpoints))")
        check("lines added or taken away above a breakpoint move it",
              ScriptObject.movingBreakpoints([5, 9], editing: NSRange(location: 0, length: 0), replacement: "\n\n",
                                             in: "one\ntwo\n" as NSString) == [7, 11]
              && ScriptObject.movingBreakpoints([5, 9], editing: NSRange(location: 4, length: 4), replacement: "",
                                                in: "one\ntwo\nthree\nfour\nfive\nsix\n" as NSString) == [4, 8])
    }

    // MARK: - Together

    private static func testTogether(_ check: Checker) {
        print("\nDebugger: a host and a joined player")
        var handler = ScriptObject.blank(language: .luau)
        handler.name = "Shop"
        handler.source = """
        local ReplicatedStorage = game:GetService("ReplicatedStorage")
        local Buy = ReplicatedStorage:FindFirstChild("Buy")
        if Buy == nil then
        \tBuy = Instance.new("RemoteEvent")
        \tBuy.Name = "Buy"
        \tBuy.Parent = ReplicatedStorage
        end
        Buy.OnServerEvent:Connect(function(player, item)
        \tlocal price = if item == "sword" then 10 else 5
        \tBuy:FireClient(player, item, price)
        end)
        """
        handler.breakpoints = [10]
        var shopper = ScriptObject.blank(language: .luau)
        shopper.name = "Shopper"
        shopper.host = .starterPlayer
        shopper.source = """
        local Buy = game:GetService("ReplicatedStorage"):WaitForChild("Buy")
        Buy.OnClientEvent:Connect(function(item, price)
        \tprint("bought", item, price)
        end)
        task.wait(0.5)
        Buy:FireServer("sword")
        """
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            model.scripts += [handler, shopper]
        }), let host = hosting.player, let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        // Debugging the host's scripts from the start again.
        var stops: [ScriptDebugger.Pause] = []
        host.scripts.stop()
        host.scripts.debugger = ScriptDebugger { pause in
            stops.append(pause)
            return .resume
        }
        host.scripts.start()
        LANSelfTest.run([hosting, joining], seconds: 2)
        let stop = stops.first { $0.frames.first?.script == "Shop" && variable($0.frames.first, "player")?.contains("Sam") == true }
        check("the host stops in its RemoteEvent handler with the joined player's message",
              stop?.frames.first?.line == 10 && variable(stop?.frames.first, "item") == "\"sword\""
              && variable(stop?.frames.first, "price") == "10"
              && variable(stop?.frames.first, "player")?.contains("Sam") == true,
              "\(String(describing: stop?.frames.first?.variables))")
        check("…and when it goes on, the reply reaches them", said(sam).contains("bought sword 10"), "\(said(sam))")
        let errors = said(host, .error) + said(sam, .error)
        check("…with no errors on either", errors.isEmpty, "\(errors)")
        joining.leaveGame()
        hosting.leaveGame()
    }
}
