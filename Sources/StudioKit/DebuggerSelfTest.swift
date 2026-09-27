import Foundation

/// The Luau debugger: a breakpoint stopping every time its line runs, with the calls
/// (the function it's in, and the line that called it) and their locals and upvalues;
/// a table, a string and an Instance described; Step Over, Into and Out; a breakpoint
/// on a line with no code landing on the next; one put on while running, in a
/// ModuleScript, in a LocalScript, and in a character script after a respawn; the world
/// waiting while stopped, and the watchdog not counting the wait; Stop; breakpoints
/// saved with the place and kept through Stop in Studio; and a host stopped in a
/// RemoteEvent handler with a joined player's message, the reply reaching them after.
/// Then watch expressions (locals, upvalues, globals, another call's; errors, a runaway
/// one cut short); conditional breakpoints (true, false, failing, calling code with a
/// breakpoint of its own, two on one line, changed while running); and tables opened,
/// nested and in order.
enum DebuggerSelfTest {
    static func run(check: Checker) {
        testBreakpoints(check)
        testStepping(check)
        testElsewhere(check)
        testWaiting(check)
        testWatches(check)
        testConditions(check)
        testTables(check)
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

    /// Like `debugged`, but the handler gets the debugger too, to look around while stopped.
    private static func looking(_ source: String, breakpoints: [Int], conditions: [Int: String] = [:],
                                watches: [String] = [],
                                handler: @escaping (ScriptDebugger, ScriptDebugger.Pause) -> Void)
        -> (SceneModel, PlayController) {
        let model = SceneModel()
        var script = ScriptObject.blank(language: .luau)
        script.name = "Counter"
        script.source = source
        script.breakpoints = breakpoints
        script.breakpointConditions = conditions
        model.scripts = [script]
        let session = PlayController(model: model, console: ScriptConsole())
        let debugger = ScriptDebugger()
        debugger.watches = watches
        debugger.handler = { [unowned debugger] pause in
            handler(debugger, pause)
            return .resume
        }
        session.scripts.debugger = debugger
        return (model, session)
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

    // MARK: - Watches

    private static func testWatches(_ check: Checker) {
        print("\nDebugger: watch expressions")
        var stops: [ScriptDebugger.Pause] = []
        var outer: [LuauInterpreter.Evaluation] = []
        var runaway: LuauInterpreter.Evaluation?
        let (_, session) = looking(counting, breakpoints: [4],
                                   watches: ["amount * 2", "total", "before", "workspace.Name", "math.max(amount, 2)",
                                             "#items", "nope +"]) { debugger, pause in
            stops.append(pause)
            // The script's own call: its locals, which `add` can't see.
            outer.append(debugger.evaluate("index * 10 + #items", inFrame: 1))
            if runaway == nil { runaway = debugger.evaluate("(function() while true do end end)()") }
        }
        session.start()
        step(session, seconds: 0.2)
        func watch(_ pause: ScriptDebugger.Pause?, _ expression: String) -> LuauInterpreter.Evaluation? {
            pause?.watches.first { $0.expression == expression }?.result
        }
        let first = stops.first, last = stops.last
        check("watches are worked out at every stop", stops.count == 3 && stops.allSatisfy { $0.watches.count == 7 },
              "\(stops.map(\.watches.count))")
        check("…seeing the call's locals", watch(first, "amount * 2")?.value == "2" && watch(first, "amount * 2")?.type == "number"
              && watch(last, "amount * 2")?.value == "6" && watch(first, "before")?.value == "0",
              "\(String(describing: watch(first, "amount * 2"))) \(String(describing: watch(last, "amount * 2")))")
        check("…its upvalues", watch(first, "total")?.value == "0" && watch(last, "total")?.value == "3",
              "\(String(describing: watch(last, "total")))")
        check("…and the script's globals", watch(first, "workspace.Name")?.value == "\"Workspace\""
              && watch(first, "math.max(amount, 2)")?.value == "2",
              "\(String(describing: watch(first, "workspace.Name")))")
        let missing = watch(first, "#items"), broken = watch(first, "nope +")
        check("a watch that fails says why", missing?.error?.hasPrefix("attempt to get length of a nil value") == true
              && missing?.truthy == false,
              "\(String(describing: missing))")
        check("…as does one that isn't Luau", broken?.error?.isEmpty == false && broken?.value == "", "\(String(describing: broken))")
        check("any call on the stack can be looked in", outer.map(\.value) == ["12", "22", "32"], "\(outer)")
        check("one that runs away is cut short", runaway?.error?.isEmpty == false, "\(String(describing: runaway))")
        check("…and the script goes on as before", said(session).contains("total 6 2") && said(session, .error).isEmpty,
              "\(said(session)) \(said(session, .error))")
        session.stop()
    }

    // MARK: - Conditions

    static let limited = """
    local function limit(n)
    \treturn n > 2
    end
    local seen = 0
    for i = 1, 5 do
    \tseen += i
    end
    print("seen", seen)
    """

    private static func testConditions(_ check: Checker) {
        print("\nDebugger: conditional breakpoints")
        func stopped(_ breakpoints: [Int], _ conditions: [Int: String], in source: String = limited)
            -> ([ScriptDebugger.Pause], [String], [String]) {
            var stops: [ScriptDebugger.Pause] = []
            let (_, session) = looking(source, breakpoints: breakpoints, conditions: conditions) { _, pause in
                stops.append(pause)
            }
            session.start()
            step(session, seconds: 0.1)
            defer { session.stop() }
            return (stops, said(session), said(session, .error))
        }
        func values(_ stops: [ScriptDebugger.Pause], _ name: String) -> [String] {
            stops.compactMap { variable($0.frames.first, name) }
        }
        let (held, heldOut, heldErrors) = stopped([6], [6: "i >= 4"])
        check("a condition stops only when it holds", held.count == 2 && values(held, "i") == ["4", "5"]
              && held.allSatisfy { $0.reason == .breakpoint && $0.note == nil }, "\(values(held, "i"))")
        check("…and the script is none the wiser", heldOut.contains("seen 15") && heldErrors.isEmpty, "\(heldOut)")
        let (never, _, _) = stopped([6], [6: "i > 99"])
        check("one that never holds never stops", never.isEmpty)
        let (calling, callingOut, _) = stopped([2, 6], [6: "limit(i)"])
        check("a condition can call the script's functions, their breakpoints passed over",
              values(calling, "i") == ["3", "4", "5"] && calling.allSatisfy { $0.frames.first?.line == 6 }
              && callingOut.contains("seen 15"), "\(calling.map { $0.frames.first?.line ?? 0 })")
        let (failing, failingOut, _) = stopped([6], [6: "i.size > 1"])
        check("one that fails stops, to say why", failing.count == 5
              && failing.allSatisfy { $0.note?.contains("i.size > 1") == true && $0.note?.contains("index") == true }
              && failingOut.contains("seen 15"), "\(String(describing: failing.first?.note))")
        let (unfinished, _, _) = stopped([6], [6: "i >"])
        check("…as does one that isn't Luau", unfinished.count == 5 && unfinished.first?.note != nil)
        // `counting`: line 11 is a comment, so its breakpoint lands on 13 with 13's own.
        let (either, _, _) = stopped([11, 13], [11: "false", 13: "total == 6"], in: counting)
        let (always, _, _) = stopped([11, 13], [11: "false"], in: counting)
        let (neither, _, _) = stopped([11, 13], [11: "false", 13: "total == 7"], in: counting)
        check("two on one line stop when either holds — always, if one has no condition",
              either.count == 1 && always.count == 1 && neither.isEmpty, "\(either.count) \(always.count) \(neither.count)")

        // Changed while the game runs.
        let ticking = """
        local count = 0
        while true do
        \tcount += 1
        \ttask.wait(0.05)
        end
        """
        var stops: [ScriptDebugger.Pause] = []
        let (model, session) = looking(ticking, breakpoints: [3], conditions: [3: "count > 1000"]) { _, pause in
            stops.append(pause)
        }
        let id = model.scripts[0].id
        session.start()
        step(session, seconds: 0.5)
        let quiet = stops.count
        model.setBreakpointCondition("count % 2 == 0", line: 3, forScript: id)
        session.scripts.debugger?.breakpointsChanged(script: id)
        step(session, seconds: 0.5)
        let even = stops.dropFirst(quiet).compactMap { variable($0.frames.first, "count").flatMap { Int($0) } }
        model.setBreakpointCondition(nil, line: 3, forScript: id)
        session.scripts.debugger?.breakpointsChanged(script: id)
        let before = stops.count
        step(session, seconds: 0.5)
        check("a condition changed while running takes effect", quiet == 0 && even.count >= 3 && even.allSatisfy { $0 % 2 == 0 },
              "\(quiet) \(even)")
        check("…and taken away, it stops every time", stops.count - before >= 6, "\(stops.count - before)")
        session.stop()
    }

    // MARK: - Tables

    private static func testTables(_ check: Checker) {
        print("\nDebugger: opening tables")
        let source = """
        local stats = { best = 12, name = "Ada", list = { 10, 20, 30 }, ["odd key"] = true, nested = { deeper = { value = 7 } } }
        local empty = {}
        local dozen = {}
        for n = 1, 12 do dozen[n] = n * n end
        print(stats.best, #dozen)
        """
        var variables: [LuauInterpreter.DebugVariable] = []
        var opened: [String: [LuauInterpreter.DebugVariable]?] = [:]
        let (_, session) = looking(source, breakpoints: [5]) { debugger, pause in
            variables = pause.frames.first?.variables ?? []
            for expression in ["stats", "stats.list", "stats.nested.deeper", "stats[\"odd key\"]", "stats.best", "empty",
                               "dozen", "(stats.nested)", "nothing.here"] {
                opened[expression] = debugger.fields(of: expression)
            }
        }
        session.start()
        step(session, seconds: 0.1)
        func fields(_ expression: String) -> [LuauInterpreter.DebugVariable]? { opened[expression] ?? nil }
        let stats = fields("stats")
        check("a variable's path is its name", variables.first { $0.name == "stats" }?.path == "stats"
              && variables.first { $0.name == "stats" }?.type == "table")
        check("a table opens to its entries, by name", stats?.map(\.name) == ["best", "list", "name", "nested", "odd key"]
              && stats?.first?.value == "12" && stats?.first?.type == "number", "\(String(describing: stats?.map(\.name)))")
        check("…each with its path from the table", stats?.map(\.path) == [".best", ".list", ".name", ".nested", "[\"odd key\"]"],
              "\(String(describing: stats?.map(\.path)))")
        check("a list inside opens too, numbered", fields("stats.list")?.map(\.name) == ["[1]", "[2]", "[3]"]
              && fields("stats.list")?.map(\.value) == ["10", "20", "30"] && fields("stats.list")?.first?.path == "[1]")
        check("…and deeper", fields("stats.nested.deeper")?.first.map { "\($0.name)=\($0.value)" } == "value=7")
        check("numbered entries come in order", fields("dozen")?.map(\.name) == (1...12).map { "[\($0)]" },
              "\(String(describing: fields("dozen")?.map(\.name)))")
        check("an empty table opens to nothing", fields("empty")?.isEmpty == true)
        check("anything else doesn't open", fields("stats.best") == nil && fields("stats[\"odd key\"]") == nil
              && fields("nothing.here") == nil && fields("(stats.nested)")?.count == 1)
        check("…and the script goes on", said(session).contains("12 12") && said(session, .error).isEmpty, "\(said(session))")
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
        check("…and a script without any saves as before", plain?.contains("breakpoints") == false
              && plain?.contains("conditions") == false)
        script.breakpointConditions = [7: "health < 20"]
        let conditioned = (try? JSONEncoder().encode(script)).flatMap { try? JSONDecoder().decode(ScriptObject.self, from: $0) }
        check("…and their conditions", conditioned?.breakpointConditions == [7: "health < 20"])

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

        session.startPlay()
        session.setBreakpointCondition(script: id, line: 5, "  lives == 0 ")
        session.setBreakpointCondition(script: id, line: 6, "lives == 1")
        session.stopPlay()
        check("a condition set while playing is kept too, trimmed", model.script(id: id)?.breakpointConditions == [5: "lives == 0"],
              "\(String(describing: model.script(id: id)?.breakpointConditions))")
        let unedited = model.revision
        model.moveBreakpoints([5: 8], forScript: id)
        session.setBreakpointCondition(script: id, line: 8, "lives == 0 or dead")
        check("…and moves with its breakpoint, neither an edit to undo", model.script(id: id)?.breakpoints == [8]
              && model.script(id: id)?.breakpointConditions == [8: "lives == 0 or dead"] && model.revision == unedited)
        session.toggleBreakpoint(script: id, line: 8)
        session.toggleBreakpoint(script: id, line: 8)
        check("…but not once the breakpoint's gone", model.script(id: id)?.breakpointConditions.isEmpty == true)
        session.setBreakpointCondition(script: id, line: 8, "true")
        session.setBreakpointCondition(script: id, line: 8, "   ")
        check("…and a blank one is none", model.script(id: id)?.breakpointConditions.isEmpty == true)
        session.addWatch("  lives * 2 ")
        session.addWatch("")
        session.addWatch("name")
        session.removeWatch(at: 0)
        check("watches are added and taken away", session.watchExpressions == ["name"])
        check("lines added or taken away above a breakpoint move it",
              ScriptObject.movingBreakpoints([5, 9], editing: NSRange(location: 0, length: 0), replacement: "\n\n",
                                             in: "one\ntwo\n" as NSString) == [7, 11]
              && ScriptObject.movingBreakpoints([5, 9], editing: NSRange(location: 4, length: 4), replacement: "",
                                                in: "one\ntwo\nthree\nfour\nfive\nsix\n" as NSString) == [4, 8])
        check("…each line mapped to where it goes, those taken away left out",
              ScriptObject.movingLines([1, 2, 5], editing: NSRange(location: 4, length: 4), replacement: "",
                                       in: "one\ntwo\nthree\nfour\nfive\nsix\n" as NSString) == [1: 1, 5: 4])
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
        Buy.OnServerEvent:Connect(function(player, item, options)
        \tlocal price = if item == "sword" then 10 else 5
        \tBuy:FireClient(player, item, price)
        end)
        """
        handler.breakpoints = [10]
        handler.breakpointConditions = [10: "item == \"sword\""]
        var shopper = ScriptObject.blank(language: .luau)
        shopper.name = "Shopper"
        shopper.host = .starterPlayer
        shopper.source = """
        local Buy = game:GetService("ReplicatedStorage"):WaitForChild("Buy")
        Buy.OnClientEvent:Connect(function(item, price)
        \tprint("bought", item, price)
        end)
        task.wait(0.5)
        Buy:FireServer("shield", { quantity = 1 })
        Buy:FireServer("sword", { quantity = 2, gift = true })
        """
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            model.scripts += [handler, shopper]
        }), let host = hosting.player, let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        // Debugging the host's scripts from the start again.
        var stops: [ScriptDebugger.Pause] = []
        var options: [String: [LuauInterpreter.DebugVariable]] = [:]
        host.scripts.stop()
        let debugger = ScriptDebugger()
        debugger.watches = ["player.Name .. \" buys \" .. item"]
        debugger.handler = { [unowned debugger] pause in
            stops.append(pause)
            if let name = variable(pause.frames.first, "player") { options[name] = debugger.fields(of: "options") }
            return .resume
        }
        host.scripts.debugger = debugger
        host.scripts.start()
        LANSelfTest.run([hosting, joining], seconds: 2)
        let stop = stops.first { $0.frames.first?.script == "Shop" && variable($0.frames.first, "player")?.contains("Sam") == true }
        check("the host stops in its RemoteEvent handler with the joined player's message",
              stop?.frames.first?.line == 10 && variable(stop?.frames.first, "item") == "\"sword\""
              && variable(stop?.frames.first, "price") == "10"
              && variable(stop?.frames.first, "player")?.contains("Sam") == true,
              "\(String(describing: stop?.frames.first?.variables))")
        check("…only for what the breakpoint's condition asks", stops.allSatisfy { variable($0.frames.first, "item") == "\"sword\"" }
              && stops.contains { variable($0.frames.first, "player")?.contains("Sam") == true }, "\(stops.count)")
        check("…their name in its watch", stop?.watches.first?.result.value == "\"Sam buys sword\"",
              "\(String(describing: stop?.watches))")
        let sent = options.first { $0.key.contains("Sam") }?.value
        check("…and the table they sent opens", sent?.map { "\($0.name)=\($0.value)" } == ["gift=true", "quantity=2"],
              "\(String(describing: sent))")
        check("…and when it goes on, the replies reach them", said(sam).contains("bought sword 10")
              && said(sam).contains("bought shield 5"), "\(said(sam))")
        let errors = said(host, .error) + said(sam, .error)
        check("…with no errors on either", errors.isEmpty, "\(errors)")
        joining.leaveGame()
        hosting.leaveGame()
    }
}
