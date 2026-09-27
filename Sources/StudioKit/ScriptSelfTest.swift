import Foundation
import simd

/// Verification for the embedded Luau VM, the Roblox-flavoured library and the
/// host bridge. Every check runs real Luau.
enum ScriptSelfTest {

    static func run(check: Checker) {
        testEveryHostCallIsAnswered(check)
        testLibraryLoads(check)
        testVector3(check)
        testColor3(check)
        testEnums(check)
        testWorkspace(check)
        testPartProperties(check)
        testAssignmentErrors(check)
        testInstanceNew(check)
        testScriptObject(check)
        testHeartbeat(check)
        testTask(check)
        testErrors(check)
        testWatchdog(check)
        testSandbox(check)
        testPlayerAndGame(check)
        testShaders(check)
        testRandom(check)
        testTweenService(check)
        testMathExtensions(check)
        testRotationConvention(check)
        testShippedScripts(check)
        testMixedLanguages(check)
    }

    // MARK: - Harness

    static func scene() -> SceneModel {
        let model = SceneModel()
        model.parts = []
        model.scripts = []
        model.shaders = []

        var brick = Part()
        brick.name = "Brick"
        brick.position = Vec3(1, 2, 3)
        brick.size = Vec3(4, 1, 2)
        brick.color = Vec3(0.5, 0.5, 0.5)
        model.parts.append(brick)

        var orb = Part()
        orb.name = "Orb"
        orb.shape = .sphere
        orb.position = Vec3(0, 5, 0)
        model.parts.append(orb)
        return model
    }

    static func add(_ model: SceneModel, _ source: String, name: String = "Test", parent: UUID? = nil) {
        var script = ScriptObject()
        script.name = name
        script.source = source
        script.parentID = parent
        model.scripts.append(script)
    }

    /// Runs the scene's scripts, optionally ticks it, and returns what came out.
    struct Result {
        var output: [String]
        var warnings: [String]
        var errors: [String]
        var runtime: ScriptRuntime
    }

    @discardableResult
    static func execute(_ model: SceneModel, ticks: Int = 0, dt: Double = 1.0 / 60,
                        prepare: (ScriptRuntime) -> Void = { _ in }) -> Result {
        let console = ScriptConsole()
        let runtime = ScriptRuntime(model: model, console: console)
        prepare(runtime)
        runtime.start()
        for _ in 0..<ticks { runtime.update(dt: dt) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        return Result(output: console.lines.filter { $0.kind == .output }.map(\.text),
                      warnings: console.lines.filter { $0.kind == .warning }.map(\.text),
                      errors: console.lines.filter { $0.kind == .error }.map(\.text),
                      runtime: runtime)
    }

    /// One script, run against a fresh scene.
    @discardableResult
    static func runScript(_ source: String, ticks: Int = 0, name: String = "Test") -> Result {
        let model = scene()
        add(model, source, name: name)
        return execute(model, ticks: ticks)
    }

    /// Evaluates Luau expressions in one script and reports any that were not true.
    static func assertAll(_ check: Checker, _ label: String, preamble: String = "",
                          _ expressions: [String]) {
        var body = preamble + "\n"
        for (index, expression) in expressions.enumerated() {
            body += "if not (\(expression)) then print(\"FAILED #\(index)\") end\n"
        }
        let result = runScript(body)
        let failures = result.output.filter { $0.hasPrefix("FAILED") }.map { line -> String in
            let number = Int(line.dropFirst("FAILED #".count)) ?? -1
            return number >= 0 && number < expressions.count ? expressions[number] : line
        }
        check(label, result.errors.isEmpty && failures.isEmpty,
              (result.errors + failures).prefix(3).joined(separator: " | "))
    }

    private static func near(_ a: Float, _ b: Float, _ tol: Float = 1e-3) -> Bool { abs(a - b) <= tol }

    // MARK: - Tests

    private static func testLibraryLoads(_ check: Checker) {
        print("\nLuau: the VM and library")
        let result = runScript("print(\"hello\", 1 + 2, true)")
        check("the library loads and a script runs", result.errors.isEmpty, "\(result.errors)")
        check("print separates arguments with spaces, as Roblox does",
              result.output == ["hello 3 true"], "\(result.output)")

        let warned = runScript("warn(\"careful\", 2)")
        check("warn goes to the console as a warning", warned.warnings == ["careful 2"], "\(warned.warnings)")

        // Output from inside a coroutine once went nowhere: the host read arguments
        // off the main thread's stack instead of the calling thread's.
        let threaded = runScript("""
        task.spawn(function() print("from a thread") end)
        coroutine.wrap(function() print("from a coroutine") end)()
        """)
        check("print works from inside threads",
              threaded.output == ["from a thread", "from a coroutine"], "\(threaded.output) \(threaded.errors)")

        let interpolated = runScript("local n = 3\nprint(`{n} parts`)")
        check("Luau string interpolation works", interpolated.output == ["3 parts"], "\(interpolated.output)")

        let typed = runScript("local x: number = 5\nlocal function f(a: string): string return a end\nprint(f(\"ok\"), x)")
        check("type annotations are accepted", typed.output == ["ok 5"], "\(typed.output) \(typed.errors)")
    }

    private static func testVector3(_ check: Checker) {
        print("\nLuau: Vector3")
        assertAll(check, "construction and components", [
            "Vector3.new(1, 2, 3).X == 1",
            "Vector3.new(1, 2, 3).Y == 2",
            "Vector3.new(1, 2, 3).Z == 3",
            "Vector3.new().X == 0",
            "Vector3.zero == Vector3.new(0, 0, 0)",
            "Vector3.one == Vector3.new(1, 1, 1)",
            "Vector3.yAxis == Vector3.new(0, 1, 0)",
            "typeof(Vector3.new()) == 'Vector3'",
            "tostring(Vector3.new(1, 2.5, 3)) == '1, 2.5, 3'"
        ])
        assertAll(check, "arithmetic", [
            "Vector3.new(1, 2, 3) + Vector3.new(4, 5, 6) == Vector3.new(5, 7, 9)",
            "Vector3.new(5, 7, 9) - Vector3.new(4, 5, 6) == Vector3.new(1, 2, 3)",
            "Vector3.new(1, 2, 3) * 2 == Vector3.new(2, 4, 6)",
            "2 * Vector3.new(1, 2, 3) == Vector3.new(2, 4, 6)",
            "Vector3.new(1, 2, 3) * Vector3.new(2, 2, 2) == Vector3.new(2, 4, 6)",
            "Vector3.new(2, 4, 6) / 2 == Vector3.new(1, 2, 3)",
            "-Vector3.new(1, -2, 3) == Vector3.new(-1, 2, -3)"
        ])
        assertAll(check, "lengths and products", [
            "Vector3.new(3, 4, 0).Magnitude == 5",
            "Vector3.new(0, 0, 9).Unit == Vector3.new(0, 0, 1)",
            "Vector3.zero.Unit == Vector3.zero",
            "Vector3.new(1, 2, 3):Dot(Vector3.new(4, 5, 6)) == 32",
            "Vector3.new(1, 2, 3):Cross(Vector3.new(4, 5, 6)) == Vector3.new(-3, 6, -3)",
            "Vector3.new(0, 0, 0):Lerp(Vector3.new(10, 0, 0), 0.25) == Vector3.new(2.5, 0, 0)",
            "Vector3.new(1, 0, 0):FuzzyEq(Vector3.new(1.000001, 0, 0))",
            "math.abs(Vector3.xAxis:Angle(Vector3.yAxis) - math.pi / 2) < 1e-6",
            "Vector3.new(-1, 2, -3):Abs() == Vector3.new(1, 2, 3)",
            "Vector3.new(1.5, 2.5, -1.5):Floor() == Vector3.new(1, 2, -2)",
            "Vector3.new(1, 5, 3):Max(Vector3.new(4, 2, 3)) == Vector3.new(4, 5, 3)"
        ])

        // Vectors are immutable, and the errors say so the way Roblox does.
        let assign = runScript("local v = Vector3.new(1, 2, 3)\nv.X = 5", name: "Immutable")
        check("assigning a component is refused",
              assign.errors.first?.contains("X cannot be assigned to") ?? false, "\(assign.errors)")
        check("the error points at the user's line",
              assign.errors.first?.hasPrefix("Immutable:2:") ?? false, "\(assign.errors)")

        let unknown = runScript("print(Vector3.new().W)")
        check("an unknown member is named in the error",
              unknown.errors.first?.contains("W is not a valid member of Vector3") ?? false, "\(unknown.errors)")

        let dot = runScript("print(Vector3.new().Dot(Vector3.new()))")
        check("calling a method with . instead of : is explained",
              dot.errors.first?.contains("call it as value:Dot(other)") ?? false, "\(dot.errors)")

        // Components are float32, as in Roblox, so a round trip through a part compares equal.
        let roundTrip = runScript("workspace.Brick.Position = Vector3.new(0.1, 0.2, 0.3)\nprint(workspace.Brick.Position == Vector3.new(0.1, 0.2, 0.3))")
        check("a vector read back from a part equals the one written",
              roundTrip.output == ["true"], "\(roundTrip.output) \(roundTrip.errors)")

        let badArgument = runScript("Vector3.new('a', 2, 3)")
        check("a bad constructor argument is reported",
              badArgument.errors.first?.contains("number expected, got string") ?? false, "\(badArgument.errors)")

        let badMaths = runScript("print(Vector3.new() + 1)")
        check("adding a number to a vector is reported",
              badMaths.errors.first?.contains("arithmetic (add) on Vector3 and number") ?? false, "\(badMaths.errors)")
    }

    private static func testColor3(_ check: Checker) {
        print("\nLuau: Color3")
        assertAll(check, "construction and conversion", [
            "Color3.new(1, 0.5, 0).G == 0.5",
            "Color3.fromRGB(255, 0, 0) == Color3.new(1, 0, 0)",
            "typeof(Color3.new()) == 'Color3'",
            "Color3.fromHex('#FF8000'):ToHex() == 'FF8000'",
            "Color3.fromHex('00ff00') == Color3.new(0, 1, 0)",
            "Color3.fromHSV(0, 1, 1) == Color3.new(1, 0, 0)",
            "Color3.new(0, 0, 0):Lerp(Color3.new(1, 1, 1), 0.5) == Color3.new(0.5, 0.5, 0.5)"
        ])
        assertAll(check, "HSV round trip", preamble: "local h, s, v = Color3.fromRGB(51, 153, 204):ToHSV()\nlocal back = Color3.fromHSV(h, s, v)", [
            "math.abs(back.R - 0.2) < 1e-6",
            "math.abs(back.G - 0.6) < 1e-6",
            "math.abs(back.B - 0.8) < 1e-6",
            "h >= 0 and h <= 1 and s >= 0 and s <= 1 and v >= 0 and v <= 1"
        ])
        let badHex = runScript("Color3.fromHex('nope')")
        check("an invalid hex colour is reported", !badHex.errors.isEmpty, "\(badHex.errors)")
    }

    private static func testEnums(_ check: Checker) {
        print("\nLuau: Enum")
        assertAll(check, "enum items", [
            "tostring(Enum.Material.Neon) == 'Enum.Material.Neon'",
            "Enum.Material.Neon.Name == 'Neon'",
            "Enum.PartType.Ball.EnumType == 'PartType'",
            "typeof(Enum.Material.Wood) == 'EnumItem'",
            "#Enum.Material:GetEnumItems() == 19",
            "#Enum.EasingStyle:GetEnumItems() == 11",
            "Enum.Material.Neon == Enum.Material.Neon"
        ])
        let unknown = runScript("print(Enum.Material.Lava)")
        check("an unknown enum item is reported",
              unknown.errors.first?.contains("Lava is not a valid member") ?? false, "\(unknown.errors)")
    }

    private static func testWorkspace(_ check: Checker) {
        print("\nLuau: workspace")
        assertAll(check, "finding parts", [
            "workspace:FindFirstChild('Brick') ~= nil",
            "workspace:FindFirstChild('Nothing') == nil",
            "workspace.Brick == workspace:FindFirstChild('Brick')",
            "#workspace:GetChildren() == 2",
            "Workspace == workspace",
            "game.Workspace == workspace",
            "game:GetService('Workspace') == workspace",
            "workspace.Name == 'Workspace'",
            "typeof(workspace) == 'Instance'",
            "workspace:IsA('Workspace')"
        ])
        let missing = runScript("print(workspace.Nothing)")
        check("a missing child is reported as Roblox does",
              missing.errors.first?.contains("Nothing is not a valid member of Workspace") ?? false, "\(missing.errors)")
        let waited = runScript("print(workspace:WaitForChild('Nothing'))")
        check("waiting for a missing child warns about an infinite yield",
              waited.warnings.first?.contains("Infinite yield possible") ?? false, "\(waited.warnings)")
    }

    private static func testPartProperties(_ check: Checker) {
        print("\nLuau: part properties")
        assertAll(check, "reading", preamble: "local brick = workspace.Brick", [
            "brick.Name == 'Brick'",
            "brick.Position == Vector3.new(1, 2, 3)",
            "brick.Size == Vector3.new(4, 1, 2)",
            "brick.Color == Color3.new(0.5, 0.5, 0.5)",
            "brick.Material == Enum.Material.Plastic",
            "brick.Shape == Enum.PartType.Block",
            "workspace.Orb.Shape == Enum.PartType.Ball",
            "brick.ClassName == 'Part'",
            "brick.Parent == workspace",
            "brick.Shader == nil",
            "brick:IsA('BasePart') and brick:IsA('Part') and not brick:IsA('WedgePart')",
            "brick:GetFullName() == 'Workspace.Brick'",
            "tostring(brick) == 'Brick'",
            "typeof(brick) == 'Instance'"
        ])

        let model = scene()
        add(model, """
        local brick = workspace.Brick
        brick.Position = Vector3.new(10, 20, 30)
        brick.Size = Vector3.new(2, 2, 2)
        brick.Color = Color3.fromRGB(255, 0, 0)
        brick.Orientation = Vector3.new(0, 90, 0)
        brick.Name = "Renamed"
        brick.Transparency = 0.5
        brick.Anchored = false
        brick.Material = Enum.Material.Metal
        workspace.Orb.Material = "Neon"
        workspace.Orb.Shape = Enum.PartType.Cylinder
        """)
        let result = execute(model)
        check("no errors writing properties", result.errors.isEmpty, "\(result.errors)")
        let brick = model.parts[0]
        check("Position writes", brick.position == Vec3(10, 20, 30), "\(brick.position)")
        check("Size writes", brick.size == Vec3(2, 2, 2), "\(brick.size)")
        check("Color writes", near(brick.color.x, 1) && near(brick.color.y, 0), "\(brick.color)")
        check("Orientation writes as degrees", near(brick.rotationDegrees.y, 90, 0.01), "\(brick.rotationDegrees)")
        check("Name writes", brick.name == "Renamed", brick.name)
        check("Transparency writes", near(brick.transparency, 0.5))
        check("Anchored writes", brick.anchored == false)
        check("Material writes from an enum item", brick.material == .metal, "\(brick.material)")
        check("Material writes from a string, as Roblox allows", model.parts[1].material == .neon)
        check("Shape writes from an enum item", model.parts[1].shape == .cylinder)

        // The classic Roblox trap: Position is a copy, so this cannot silently do nothing.
        let copy = runScript("workspace.Brick.Position.X = 5")
        check("assigning into a property's copy is refused",
              copy.errors.first?.contains("X cannot be assigned to") ?? false, "\(copy.errors)")

        let identity = runScript("print(workspace:FindFirstChild('Brick') == workspace.Brick, rawequal(workspace.Brick, workspace.Brick))")
        check("the same part is the same object every time", identity.output == ["true true"], "\(identity.output)")
    }

    private static func testAssignmentErrors(_ check: Checker) {
        print("\nLuau: assignment errors")
        let cases: [(String, String)] = [
            ("workspace.Brick.Position = 5", "Unable to assign property Position. Vector3 expected, got number"),
            ("workspace.Brick.Color = Vector3.new()", "Unable to assign property Color. Color3 expected, got Vector3"),
            ("workspace.Brick.Anchored = 'yes'", "Unable to assign property Anchored. bool expected, got string"),
            ("workspace.Brick.Material = Enum.PartType.Ball", "Unable to assign property Material. EnumItem expected"),
            ("workspace.Brick.ClassName = 'Model'", "Property is read only"),
            ("workspace.Brick.Wheels = 4", "Wheels is not a valid member of Part \"Brick\""),
            ("workspace.Name = 'World'", "Unable to assign property Name of Workspace")
        ]
        for (source, expected) in cases {
            let result = runScript("local x = 1\n" + source, name: "Assign")
            check("\(source) → \(expected)",
                  (result.errors.first?.contains(expected) ?? false)
                      && (result.errors.first?.hasPrefix("Assign:2:") ?? false),
                  "\(result.errors)")
        }
    }

    private static func testInstanceNew(_ check: Checker) {
        print("\nLuau: Instance.new")
        let model = scene()
        add(model, """
        local p = Instance.new("Part")
        p.Name = "Made"
        p.Size = Vector3.new(1, 1, 1)
        p.Parent = workspace
        local w = Instance.new("WedgePart")
        w.Name = "Ramp"
        print(p.Color == Color3.fromRGB(163, 162, 165), p.Anchored, w.ClassName, w:IsA("WedgePart"))
        """)
        let result = execute(model)
        check("no errors", result.errors.isEmpty, "\(result.errors)")
        check("Instance.new creates parts", model.parts.contains { $0.name == "Made" }
              && model.parts.contains { $0.name == "Ramp" && $0.shape == .wedge })
        check("new parts take Roblox's defaults", result.output == ["true false WedgePart true"], "\(result.output)")

        let bad = runScript("Instance.new('Explosion')")
        check("an unsupported class is reported",
              bad.errors.first?.contains("Unable to create an Instance of type \"Explosion\"") ?? false, "\(bad.errors)")

        let removal = scene()
        add(removal, """
        local copy = workspace.Brick:Clone()
        copy.Name = "Copy"
        workspace.Orb:Destroy()
        workspace.Brick.Parent = nil
        print(#workspace:GetChildren())
        """)
        let removed = execute(removal)
        check("Clone, Destroy and Parent = nil", removed.output == ["1"]
              && removal.parts.map(\.name) == ["Copy"], "\(removed.output) \(removal.parts.map(\.name)) \(removed.errors)")

        let stale = runScript("local b = workspace.Brick\nb:Destroy()\nprint(b.Position)", name: "Stale")
        check("using a destroyed part is explained",
              stale.errors.first?.contains("has been destroyed") ?? false, "\(stale.errors)")
        check("…at the line that used it", stale.errors.first?.hasPrefix("Stale:3:") ?? false, "\(stale.errors)")
    }

    private static func testScriptObject(_ check: Checker) {
        print("\nLuau: script")
        let model = scene()
        add(model, "print(script.Name, script.Parent.Name, script.ClassName)\nscript.Parent.Position = Vector3.new(7, 7, 7)",
            name: "Attached", parent: model.parts[1].id)
        add(model, "print(script.Parent == nil)", name: "Loose")
        let result = execute(model)
        check("script.Name and script.Parent resolve",
              result.output.contains("Attached Orb Script"), "\(result.output) \(result.errors)")
        check("script.Parent can be changed through", model.parts[1].position == Vec3(7, 7, 7))
        check("a standalone script has no parent", result.output.contains("true"), "\(result.output)")

        // Each script has its own globals; shared and _G are shared.
        let isolation = scene()
        add(isolation, "counter = 1\nshared.value = 42\n_G.flag = true", name: "First")
        add(isolation, "print(counter, shared.value, _G.flag)", name: "Second")
        let isolated = execute(isolation)
        check("a global in one script is invisible to another",
              isolated.output == ["nil 42 true"], "\(isolated.output) \(isolated.errors)")
    }

    private static func testHeartbeat(_ check: Checker) {
        print("\nLuau: RunService")
        let model = scene()
        add(model, """
        local RunService = game:GetService("RunService")
        local ticks = 0
        local total = 0
        local connection
        connection = RunService.Heartbeat:Connect(function(dt)
            ticks += 1
            total += dt
            workspace.Orb.Position = Vector3.new(ticks, 0, 0)
            if ticks == 3 then connection:Disconnect() end
        end)
        RunService.Heartbeat:Once(function() print("once") end)
        RunService.Stepped:Connect(function(t, dt) if t > 0.09 and t < 0.11 then print("stepped", dt) end end)
        """)
        let result = execute(model, ticks: 6, dt: 0.02)
        check("no errors", result.errors.isEmpty, "\(result.errors)")
        check("a handler runs every frame until disconnected", model.parts[1].position == Vec3(3, 0, 0),
              "\(model.parts[1].position)")
        check("Once fires exactly once", result.output.filter { $0 == "once" }.count == 1, "\(result.output)")
        check("Stepped passes the time and the step",
              result.output.contains("stepped 0.02"), "\(result.output)")

        // One broken handler is reported and disconnected; the rest keep going.
        let broken = scene()
        add(broken, """
        local RunService = game:GetService("RunService")
        RunService.Heartbeat:Connect(function() error("boom") end)
        local count = 0
        RunService.Heartbeat:Connect(function() count += 1; workspace.Orb.Position = Vector3.new(count, 0, 0) end)
        """, name: "Handlers")
        let outcome = execute(broken, ticks: 5)
        check("an erroring handler is reported once, not every frame",
              outcome.errors.filter { $0.contains("boom") }.count == 1, "\(outcome.errors)")
        check("…with the line it failed on", outcome.errors.first?.hasPrefix("Handlers:2:") ?? false, "\(outcome.errors)")
        check("…and a warning that it was disconnected", !outcome.warnings.isEmpty, "\(outcome.warnings)")
        check("other handlers keep running", broken.parts[1].position == Vec3(5, 0, 0), "\(broken.parts[1].position)")

        let notFunction = runScript("game:GetService('RunService').Heartbeat:Connect(5)")
        check("connecting a non-function is reported",
              notFunction.errors.first?.contains("Passed value is not a function") ?? false, "\(notFunction.errors)")

        let waits = runScript("local dt = game:GetService('RunService').Heartbeat:Wait()\nprint('waited', dt)", ticks: 1)
        check("Heartbeat:Wait yields until the next frame", waits.output.first?.hasPrefix("waited") ?? false, "\(waits.output)")
    }

    private static func testTask(_ check: Checker) {
        print("\nLuau: task")
        let model = scene()
        add(model, """
        print("before")
        local elapsed = task.wait(0.1)
        print("after", elapsed >= 0.1)
        task.delay(0.05, function(a, b) print("delayed", a, b) end, "x", 2)
        task.defer(function() print("deferred") end)
        local t = task.spawn(function() print("spawned now") end)
        wait(0.01)
        print("time", time() > 0)
        """)
        let result = execute(model, ticks: 20, dt: 0.02)
        check("no errors", result.errors.isEmpty, "\(result.errors)")
        check("task.wait works at a script's top level",
              result.output.first == "before" && result.output.contains("after true"), "\(result.output)")
        check("task.spawn runs immediately", result.output.contains("spawned now"), "\(result.output)")
        check("task.delay passes its arguments", result.output.contains("delayed x 2"), "\(result.output)")
        check("task.defer runs its function", result.output.contains("deferred"), "\(result.output)")
        check("the deprecated wait() still works", result.output.contains("time true"), "\(result.output)")

        let early = scene()
        add(early, "task.wait(1)\nprint('too soon')")
        let notYet = execute(early, ticks: 10, dt: 0.02)
        check("a thread sleeps for as long as it asked", notYet.output.isEmpty, "\(notYet.output)")

        let cancelled = runScript("local t = task.delay(0.01, function() print('ran') end)\ntask.cancel(t)", ticks: 5)
        check("task.cancel stops a pending thread", cancelled.output.isEmpty, "\(cancelled.output)")

        // task.defer: after the code running now, in the same frame.
        let deferral = runScript("""
        local RunService = game:GetService("RunService")
        local frame = 0
        RunService.Heartbeat:Connect(function() frame += 1 end)
        task.wait()
        local at = frame
        local order = {}
        task.defer(function(word)
        \ttable.insert(order, word)
        \tprint("deferred", frame - at, table.concat(order, " "))
        end, "second")
        table.insert(order, "first")
        task.defer(function()
        \ttask.defer(function() print("nested", frame - at) end)
        end)
        RunService.Heartbeat:Once(function()
        \ttask.defer(function() print("after the handler", frame) end)
        \tprint("handler", frame)
        end)
        """, ticks: 3)
        let handler = deferral.output.first { $0.hasPrefix("handler ") }?.dropFirst("handler ".count)
        check("task.defer runs when the code running now is done — the same frame, not the next",
              deferral.output.contains("deferred 0 first second") && deferral.output.contains("nested 0"),
              "\(deferral.output)")
        check("…and one deferred in an event handler runs right after it",
              handler.map { deferral.output.contains("after the handler \($0)") } ?? false
              && deferral.errors.isEmpty, "\(deferral.output) \(deferral.errors)")
        let forever = runScript("local function again() task.defer(again) end\nagain()\nprint('still going')", ticks: 3)
        check("a thread that defers itself forever doesn't stall the game",
              forever.output == ["still going"] && forever.errors.isEmpty, "\(forever.output) \(forever.errors)")

        // task.cancel, wherever the thread waits.
        let cancelling = runScript("""
        local RunService = game:GetService("RunService")
        local waiter = task.spawn(function()
        \tRunService.Heartbeat:Wait()
        \tprint("woke")
        end)
        task.cancel(waiter)
        local deferred = task.defer(function() print("deferred ran") end)
        task.cancel(deferred)
        print("self", pcall(function() task.cancel(coroutine.running()) end))
        print("twice", pcall(task.cancel, waiter), coroutine.status(waiter))
        print("not a thread", pcall(task.cancel, 5))
        """, ticks: 3)
        let said = cancelling.output
        check("task.cancel stops a thread waiting on an event, and it never wakes (nor errors)",
              !said.contains("woke") && !said.contains("deferred ran") && cancelling.errors.isEmpty,
              "\(said) \(cancelling.errors)")
        check("…refuses to cancel the thread that's running, and quietly takes a finished one",
              said.contains { $0.hasPrefix("self false") && $0.contains("can't cancel a thread that is running") }
              && said.contains("twice true dead")
              && said.contains { $0.hasPrefix("not a thread false") && $0.contains("thread expected, got number") },
              "\(said)")

        // Arguments checked, as Roblox checks them.
        let arguments = runScript("""
        local finished = coroutine.create(function() end)
        coroutine.resume(finished)
        print("wait", pcall(task.wait, "soon"))
        print("spawn", pcall(task.spawn, 5))
        print("delay", pcall(task.delay, 1, "later"))
        print("defer", pcall(task.defer, nil))
        print("dead", pcall(task.spawn, finished))
        """)
        let complaints = arguments.output
        check("task's functions say what's wrong with their arguments",
              complaints.contains { $0.hasPrefix("wait false") && $0.contains("#1 to 'wait' (number expected, got string)") }
              && complaints.contains { $0.hasPrefix("spawn false") && $0.contains("(function or thread expected, got number)") }
              && complaints.contains { $0.hasPrefix("delay false") && $0.contains("#2 to 'delay' (function or thread expected, got string)") }
              && complaints.contains { $0.hasPrefix("defer false") && $0.contains("got nil") }
              && complaints.contains { $0.hasPrefix("dead false") && $0.contains("cannot resume dead coroutine") },
              "\(complaints)")

        // The deprecated globals, as Roblox still runs them; and parallel Luau's calls.
        let legacy = runScript("""
        local elapsed, now = wait()
        print("wait", elapsed >= 1 / 30 - 1e-9, math.abs(now - time()) < 1e-6)
        local ran = false
        spawn(function() ran = true end)
        print("spawn now", ran)
        task.wait()
        print("spawn later", ran)
        local delayed = false
        delay(0, function() delayed = true end)
        task.wait()
        print("delay a frame on", delayed)
        task.wait(0.1)
        print("delay later", delayed)
        task.desynchronize()
        task.synchronize()
        print("parallel calls carry on")
        """, ticks: 20)
        check("wait() waits at least a thirtieth of a second and returns the game time too",
              legacy.output.contains("wait true true"), "\(legacy.output)")
        check("spawn() starts its function later, not straight away",
              legacy.output.contains("spawn now false") && legacy.output.contains("spawn later true"), "\(legacy.output)")
        check("delay() never sooner than a thirtieth of a second",
              legacy.output.contains("delay a frame on false") && legacy.output.contains("delay later true"),
              "\(legacy.output)")
        check("task.synchronize and task.desynchronize carry straight on (no Actors: all runs in series)",
              legacy.output.contains("parallel calls carry on") && legacy.errors.isEmpty, "\(legacy.errors)")
    }

    private static func testErrors(_ check: Checker) {
        print("\nLuau: errors")
        let syntax = runScript("local a = 1\nlocal b = = 2", name: "Broken")
        check("a syntax error is reported", !syntax.errors.isEmpty, "\(syntax.errors)")
        check("…named by script, at the user's own line with no offset",
              syntax.errors.first?.hasPrefix("Broken:2:") ?? false, "\(syntax.errors)")

        let runtime = runScript("local x = nil\nprint('ok')\nprint(x.field)", name: "Nil")
        check("a runtime error names the line", runtime.errors.first?.hasPrefix("Nil:3:") ?? false, "\(runtime.errors)")
        check("…and output before it still appears", runtime.output == ["ok"], "\(runtime.output)")

        let nested = runScript("local function inner() error('deep') end\nlocal function outer() inner() end\nouter()", name: "Stack")
        check("the stack trace shows the user's frames",
              nested.errors.contains { $0.contains("Stack:1") } && nested.errors.contains { $0.contains("Stack:3") },
              "\(nested.errors)")
        check("…without the library's own frames",
              !nested.errors.contains { $0.contains(ScriptRuntime.libraryChunkName) }, "\(nested.errors)")

        let model = scene()
        add(model, "this is not luau", name: "Bad")
        add(model, "print('still ran')", name: "Good")
        var disabled = ScriptObject()
        disabled.name = "Off"
        disabled.source = "print('should not run')"
        disabled.enabled = false
        model.scripts.append(disabled)
        let mixed = execute(model)
        check("a broken script does not stop the others", mixed.output == ["still ran"], "\(mixed.output)")
    }

    private static func testWatchdog(_ check: Checker) {
        print("\nLuau: the watchdog")
        // An endless loop at the top level must not freeze the app.
        let model = scene()
        add(model, "local n = 0\nwhile true do\n  n += 1\nend", name: "Forever")
        add(model, "print('after the loop')", name: "Next")
        let started = Date()
        let result = execute(model) { $0.timeout = 0.2 }
        check("an endless loop is stopped", result.errors.contains { $0.contains("ran for too long") }, "\(result.errors)")
        check("…quickly", Date().timeIntervalSince(started) < 2, "\(Date().timeIntervalSince(started))s")
        check("…saying where it was stuck",
              result.errors.contains { $0.hasPrefix("Forever:3:") || $0.hasPrefix("Forever:2:") }, "\(result.errors)")
        check("the next script still runs", result.output == ["after the loop"], "\(result.output)")

        // And inside a handler, frame after frame.
        let handler = scene()
        add(handler, """
        local RunService = game:GetService("RunService")
        RunService.Heartbeat:Connect(function() while true do end end)
        local frames = 0
        RunService.Heartbeat:Connect(function() frames += 1; workspace.Orb.Position = Vector3.new(frames, 0, 0) end)
        """)
        let looping = execute(handler, ticks: 3) { $0.timeout = 0.1 }
        check("a runaway handler is stopped and disconnected",
              looping.errors.filter { $0.contains("ran for too long") }.count == 1, "\(looping.errors)")
        check("frames keep coming for the other handlers",
              handler.parts[1].position.x >= 2, "\(handler.parts[1].position)")
        check("the frame loop itself survives", !looping.runtime.updateHookFailed)

        // The engine's work for a script — a slow host call, like a big map's path grid
        // being built — isn't the script's time; a loop straight after one still is.
        let slow = scene()
        add(slow, """
        local Stats = game:GetService("Stats")
        local total = 0
        for _ = 1, 4 do
        \ttotal += Stats.HeartbeatTimeMs
        end
        print("patient", total)
        """, name: "Patient")
        add(slow, """
        local _ = game:GetService("Stats").HeartbeatTimeMs
        while true do end
        """, name: "StillStopped")
        let stalling: (ScriptRuntime) -> Void = { runtime in
            runtime.timeout = 0.15
            runtime.statsSource = {
                Thread.sleep(forTimeInterval: 0.1)
                return .list([.number(1), .number(0), .number(0), .number(0), .number(0), .number(0), .number(0)])
            }
        }
        let waited = execute(slow, prepare: stalling)
        check("host calls taking longer than the watchdog's time between them don't get a script stopped",
              waited.output == ["patient 4"], "\(waited.output) \(waited.errors)")
        check("…while a loop after one still is", waited.errors.filter { $0.contains("ran for too long") }.count == 1
              && waited.errors.contains { $0.hasPrefix("StillStopped:") }, "\(waited.errors)")
    }

    private static func testSandbox(_ check: Checker) {
        print("\nLuau: sandbox")
        let attempts = [
            "Vector3.new = nil",
            "math.lerp = nil",
            "Enum.Material.Neon = 1",
            "setmetatable(Vector3.new(), {})",
            "string.upper = nil"
        ]
        for attempt in attempts {
            let result = runScript(attempt)
            check("scripts cannot do: \(attempt)", !result.errors.isEmpty, "\(result.errors)")
        }
        let locked = runScript("print(getmetatable(Vector3.new()), getmetatable(workspace.Brick))")
        check("metatables are locked, as Roblox reports",
              locked.output == ["The metatable is locked The metatable is locked"], "\(locked.output)")

        // A script that tried to break the library leaves it working for the next one.
        let model = scene()
        add(model, "pcall(function() Vector3.new = nil end)\nprint = nil", name: "Vandal")
        add(model, "print(Vector3.new(1, 2, 3).X)", name: "Victim")
        let after = execute(model)
        check("one script cannot break another's library", after.output == ["1"], "\(after.output) \(after.errors)")
    }

    private static func testPlayerAndGame(_ check: Checker) {
        print("\nLuau: player and game")
        let model = scene()
        add(model, """
        local printed = false
        game:GetService("RunService").Heartbeat:Connect(function()
            if not printed then
                printed = true
                print(Player.Position.Y, Player.Grounded, game:GetService("Players").LocalPlayer == Player)
            end
            if Player.Position.Y > 5 then Player:Teleport(Vector3.new(0, 1, 0)) end
        end)
        """)
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        session.character.position = Vec3(0, 9, 0)
        session.step(dt: 1.0 / 60)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let output = session.console.lines.filter { $0.kind == .output }.map(\.text)
        check("the player can be read", output == ["9 false true"], "\(output) \(session.console.lines.map(\.text))")
        check("the player can be teleported", session.character.position.y < 2, "\(session.character.position)")
        session.stop()

        let service = runScript("game:GetService('MarketplaceService')")
        check("an unknown service is reported",
              service.errors.first?.contains("'MarketplaceService' is not a valid Service name") ?? false, "\(service.errors)")
    }

    private static func testShaders(_ check: Checker) {
        print("\nLuau: shaders and the screen")
        let model = scene()
        var pulse = ShaderObject()
        pulse.name = "Pulse"
        pulse.source = ShaderObject.pulseExample
        pulse.parameters = [ShaderParameter(name: "speed", value: 2), ShaderParameter(name: "glow", value: 1)]
        var mono = ShaderObject.blank(kind: .screen)
        mono.name = "Mono"
        model.shaders = [pulse, mono]
        add(model, """
        local p = Shaders:FindFirstChild("Pulse")
        print(p.Name, p.Kind, p:GetParameter("speed"), table.concat(p:GetParameters(), ","), Shaders.Mono.Kind)
        p:SetParameter("speed", 7.5)
        workspace.Brick.Shader = p
        p:ApplyTo(workspace.Orb)
        workspace.Orb.Shader = nil
        Screen.Shader = Shaders.Mono
        print(Screen.Shader.Name, #Shaders:GetScreenShaders())
        """)
        let result = execute(model)
        check("no errors", result.errors.isEmpty, "\(result.errors)")
        check("shaders are found and described",
              result.output.first == "Pulse Surface 2 speed,glow Screen", "\(result.output)")
        check("a parameter can be set", model.shaders[0].parameter(named: "speed")?.value == 7.5)
        check("a shader can be put on a part", model.parts[0].shaderID == pulse.id)
        check("and taken off again", model.parts[1].shaderID == nil)
        check("the screen effect can be switched on", model.screenShaderID == mono.id)
        check("and read back", result.output.last == "Mono 1", "\(result.output)")

        let refused = scene()
        refused.shaders = [pulse]
        add(refused, "Screen.Shader = Shaders.Pulse")
        let wrong = execute(refused)
        check("a surface shader cannot go on the screen",
              wrong.errors.contains { $0.contains("surface shader") }, "\(wrong.errors)")

        let off = scene()
        off.shaders = [mono]
        off.screenShaderID = mono.id
        add(off, "Screen.Shader = nil")
        execute(off)
        check("the screen effect can be switched off", off.screenShaderID == nil)
    }

    private static func testRandom(_ check: Checker) {
        print("\nLuau: Random")
        assertAll(check, "seeded and repeatable", preamble: """
        local a, b = Random.new(1234), Random.new(1234)
        local c = Random.new(9999)
        local same, different = true, false
        for _ = 1, 20 do
            local x, y, z = a:NextNumber(), b:NextNumber(), c:NextNumber()
            if x ~= y then same = false end
            if x ~= z then different = true end
        end
        """, ["same", "different", "typeof(a) == 'Random'"])

        assertAll(check, "ranges", preamble: """
        local r = Random.new(7)
        local inRange, hitLow, hitHigh, unit = true, false, false, true
        for _ = 1, 400 do
            local n = r:NextInteger(3, 6)
            if n < 3 or n > 6 or n % 1 ~= 0 then inRange = false end
            if n == 3 then hitLow = true end
            if n == 6 then hitHigh = true end
            local f = r:NextNumber(-2, 2)
            if f < -2 or f >= 2 then inRange = false end
            -- float32 components, so the length is only good to about 1e-7
            if math.abs(r:NextUnitVector().Magnitude - 1) > 1e-6 then unit = false end
        end
        local list = {1, 2, 3, 4, 5}
        r:Shuffle(list)
        table.sort(list)
        """, [
            "inRange",
            "hitLow and hitHigh",
            "unit",
            "table.concat(list, ',') == '1,2,3,4,5'"
        ])
    }

    private static func testTweenService(_ check: Checker) {
        print("\nLuau: TweenService")
        var endpoints: [String] = []
        for style in ["Linear", "Sine", "Quad", "Cubic", "Quart", "Quint", "Exponential",
                      "Circular", "Back", "Elastic", "Bounce"] {
            for direction in ["In", "Out", "InOut"] {
                endpoints.append("math.abs(TS:GetValue(0, Enum.EasingStyle.\(style), Enum.EasingDirection.\(direction))) < 1e-6")
                endpoints.append("math.abs(TS:GetValue(1, Enum.EasingStyle.\(style), Enum.EasingDirection.\(direction)) - 1) < 1e-6")
            }
        }
        assertAll(check, "every curve runs from 0 to 1",
                  preamble: "local TS = game:GetService('TweenService')", endpoints)
        assertAll(check, "curves have the right shape", preamble: "local TS = game:GetService('TweenService')", [
            "TS:GetValue(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In) == 0.25",
            "TS:GetValue(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out) == 0.75",
            "math.abs(TS:GetValue(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut) - 0.5) < 1e-9",
            "TS:GetValue(0.8, Enum.EasingStyle.Back, Enum.EasingDirection.Out) > 1",
            "TS:GetValue(2, Enum.EasingStyle.Linear, Enum.EasingDirection.In) == 1",
            "TS:GetValue(0.3, Enum.EasingStyle.Linear, Enum.EasingDirection.Out) == 0.3"
        ])
    }

    private static func testMathExtensions(_ check: Checker) {
        print("\nLuau: math")
        assertAll(check, "Luau's own additions are there", [
            "math.clamp(5, 0, 1) == 1",
            "math.sign(-3) == -1",
            "math.round(2.5) == 3",
            "type(math.noise(1.5, 2.5, 3.5)) == 'number'"
        ])
        assertAll(check, "interpolation", [
            "math.lerp(0, 10, 0.25) == 2.5",
            "math.inverseLerp(10, 20, 15) == 0.5",
            "math.inverseLerp(5, 5, 5) == 0",
            "math.map(5, 0, 10, 100, 200) == 150",
            "math.smoothstep(0, 1, 0.5) == 0.5",
            "math.smoothstep(0, 1, 0.25) < 0.25",
            "math.smoothstep(0, 1, -3) == 0"
        ])
        assertAll(check, "repeating and snapping", [
            "math.wrap(-1, 5) == 4",
            "math.wrap(7, 5) == 2",
            "math.pingPong(15, 10) == 5",
            "math.moveTowards(0, 10, 3) == 3",
            "math.moveTowards(0, 10, 100) == 10",
            "math.snap(2.3, 0.5) == 2.5",
            "math.snap(7, 0) == 7"
        ])
        assertAll(check, "angles take the short way round", [
            "math.wrapAngle(190) == -170",
            "math.deltaAngle(350, 10) == 20",
            "math.deltaAngle(10, 350) == -20",
            "math.moveTowardsAngle(350, 10, 5) == 355"
        ])
        assertAll(check, "fbm", preamble: """
        local lo, hi, steady = math.huge, -math.huge, true
        for i = 1, 200 do
            local v = math.fbm(i / 13, i / 7, 0.5)
            lo = math.min(lo, v); hi = math.max(hi, v)
        end
        steady = math.fbm(1.3, 2.7, 0.2, 5) == math.fbm(1.3, 2.7, 0.2, 5)
        """, ["lo >= -1 and hi <= 1", "hi - lo > 0.1", "steady"])
    }

    private static func testRotationConvention(_ check: Checker) {
        print("\nLuau: rotation convention")
        // RotatedY has to turn the same way setting a part's Orientation.Y does.
        for angle in [Float(37), 90, 145, -60] {
            let expected = simd_quatf(angle: angle * .pi / 180, axis: Vec3(0, 1, 0)).act(Vec3(1, 0, 0))
            let result = runScript("local v = Vector3.xAxis:RotatedY(\(angle))\nprint(v.X, v.Z)")
            let pieces = (result.output.first ?? "").split(separator: " ").compactMap { Float($0) }
            check("RotatedY(\(Int(angle))) matches a part's Y rotation",
                  pieces.count == 2 && near(pieces[0], expected.x) && near(pieces[1], expected.z),
                  "luau \(pieces) vs simd \(expected)")
        }
    }

    /// Luau and Wren in one scene: two VMs, one shared scene, no direct calls.
    private static func testMixedLanguages(_ check: Checker) {
        print("\nBoth languages together")
        let model = scene()
        add(model, """
        print("luau starts")
        game:GetService("RunService").Heartbeat:Connect(function()
            workspace.Brick.Position += Vector3.new(1, 0, 0)
        end)
        """, name: "LuauMover")
        var wrenScript = ScriptObject.blank(language: .wren)
        wrenScript.name = "WrenMover"
        wrenScript.source = """
        import "studio" for Workspace, Runtime, Vec3
        Runtime.log("wren starts")
        Runtime.onUpdate { |dt|
          var orb = Workspace.find("Orb")
          orb.position = orb.position + Vec3.new(0, 1, 0)
        }
        """
        model.scripts.append(wrenScript)

        let result = execute(model, ticks: 3)
        check("both languages run in one scene", result.errors.isEmpty, "\(result.errors)")
        check("both print to the same console",
              result.output.contains("luau starts") && result.output.contains("wren starts"), "\(result.output)")
        check("Luau drives its part each frame", model.parts[0].position == Vec3(4, 2, 3), "\(model.parts[0].position)")
        check("Wren drives its part each frame", model.parts[1].position == Vec3(0, 8, 0), "\(model.parts[1].position)")

        // The scene is the only channel between them: a Luau write is a Wren read.
        let shared = scene()
        add(shared, "workspace.Brick.Name = 'Handoff'", name: "Writer")
        var reader = ScriptObject.blank(language: .wren)
        reader.name = "Reader"
        reader.source = "import \"studio\" for Workspace\nSystem.print(Workspace.find(\"Handoff\") != null)"
        shared.scripts.append(reader)
        let handoff = execute(shared)
        check("a change made by Luau is visible to Wren", handoff.output == ["true"], "\(handoff.output) \(handoff.errors)")

        // A broken script in one language does not stop the other.
        let broken = scene()
        add(broken, "this is not luau", name: "BadLuau")
        var goodWren = ScriptObject.blank(language: .wren)
        goodWren.name = "GoodWren"
        goodWren.source = "System.print(\"wren fine\")"
        broken.scripts.append(goodWren)
        let mixed = execute(broken)
        check("a Luau failure does not stop Wren", mixed.output == ["wren fine"], "\(mixed.output)")
    }

    private static func testShippedScripts(_ check: Checker) {
        print("\nLuau: shipped scripts")
        let starter = SceneModel()
        starter.loadStarterScene()
        let orbBefore = starter.parts.first { $0.name == "Orb" }?.position
        let result = execute(starter, ticks: 10, dt: 1.0 / 30)
        check("the starter scene's script runs cleanly", result.errors.isEmpty, "\(result.errors)")
        check("it moves the orb", starter.parts.first { $0.name == "Orb" }?.position != orbBefore)
        check("it spins the beam", (starter.parts.first { $0.name == "Beam" }?.rotationDegrees.y ?? 0) != 0)
        check("it drives the shader's glow",
              starter.shaders.first { $0.name == "Pulse" }?.parameter(named: "glow")?.value != 1)

        let attached = scene()
        add(attached, ScriptObject.template, parent: attached.parts[0].id)
        let a = execute(attached, ticks: 2)
        check("the new-script template runs attached to a part", a.errors.isEmpty, "\(a.errors)")

        let loose = SceneModel()
        loose.parts = []
        loose.scripts = []
        add(loose, ScriptObject.template)
        let l = execute(loose, ticks: 2)
        check("…and with nothing to attach to", l.errors.isEmpty, "\(l.errors)")
    }

    /// Every host call the Luau library and the Wren module make has a handler. The names
    /// are strings on both sides of the bridge, so a typo — or a handler moved without
    /// its case — would otherwise only show as a console error when a script runs.
    private static func testEveryHostCallIsAnswered(_ check: Checker) {
        print("\nScripting: every host call is answered")
        func names(in source: String, calledBy call: String) -> Set<String> {
            let pattern = try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: call) + #"\("([a-z]+\.[a-zA-Z]+)""#)
            let range = NSRange(source.startIndex..., in: source)
            return Set(pattern.matches(in: source, range: range).compactMap {
                Range($0.range(at: 1), in: source).map { String(source[$0]) }
            })
        }
        let luau = names(in: studioLibrarySource, calledBy: "invoke")
        let wren = names(in: wrenStudioModuleSource, calledBy: "Studio.invoke_")
        check("the libraries' host calls are found", luau.count > 60 && wren.count > 20, "\(luau.count) and \(wren.count)")

        // Asked of a real play session, so the player's namespaces are answered too.
        let model = SceneModel()
        model.scripts = []
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        let filler = [ScriptValue](repeating: .nothing, count: 6)
        for name in luau.union(wren).sorted() {
            _ = session.scripts.invoke(name, filler)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let unknown = session.console.lines.map(\.text).filter { $0.hasPrefix("Unknown host call") }
        check("every one has a handler", unknown.isEmpty, unknown.joined(separator: ", "))
        session.stop()

        // Luau allows 200 locals at a chunk's top level, and the whole library is one
        // chunk. Warn with room to spare: past 200 nothing compiles at all.
        var locals = 0
        for line in studioLibrarySource.split(separator: "\n") where line.hasPrefix("local ") {
            if line.hasPrefix("local function ") {
                locals += 1
            } else {
                let names = line.dropFirst(6).split(separator: "=", maxSplits: 1)[0]
                locals += names.split(separator: ",").count
            }
        }
        check("the library has room for more top-level locals (\(locals) of Luau's 200)", locals <= 190,
              "gather some into tables before adding more — see AGENTS.md invariant 76")
    }
}
