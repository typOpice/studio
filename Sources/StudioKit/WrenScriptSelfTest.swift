import Foundation
import simd

/// Verification for Wren, the secondary language: the VM, the `studio` module and
/// the host bridge. Every script here is marked as Wren; Luau lives in ScriptSelfTest.
enum WrenScriptSelfTest {

    static func run(check: Checker) {
        testVirtualMachine(check)
        testModuleLoads(check)
        testPartAccess(check)
        testCreateAndDestroy(check)
        testUpdateHook(check)
        testScriptParent(check)
        testPlayerBridge(check)
        testErrorReporting(check)
        testShaderApi(check)
        testShippedScripts(check)
    }

    private static func testShaderApi(_ check: Checker) {
        print("\nWren: shaders")
        let model = scene()
        var shader = ShaderObject()
        shader.name = "Pulse"
        shader.source = ShaderObject.pulseExample
        shader.parameters = [ShaderParameter(name: "speed", value: 2),
                             ShaderParameter(name: "glow", value: 1)]
        model.shaders = [shader]

        add(model, """
        import "studio" for Workspace, Shaders

        var pulse = Shaders.find("Pulse")
        System.print(pulse.name)
        System.print(Shaders.count)
        System.print(Shaders.find("Nothing") == null)
        System.print(pulse.parameters.join(","))
        System.print(pulse.get("speed"))

        pulse.set("speed", 7.5)

        var brick = Workspace.find("Brick")
        System.print(brick.shader == null)
        brick.shader = pulse
        """)
        let (runner, console) = runtime(model)
        runner.start()
        let lines = printed(console)

        check("no errors", errors(console).isEmpty, "\(errors(console))")
        check("a shader can be found by name", lines.contains("Pulse"), "\(lines)")
        check("the shader count is readable", lines.contains("1"), "\(lines)")
        check("a missing shader is null", lines.contains("true"), "\(lines)")
        check("parameter names are listed", lines.contains("speed,glow"), "\(lines)")
        check("a parameter value is readable", lines.contains("2"), "\(lines)")
        check("setting a parameter reaches the model",
              model.shaders[0].parameter(named: "speed")?.value == 7.5,
              "\(String(describing: model.shaders[0].parameter(named: "speed")?.value))")
        check("a part starts with no shader", lines.filter { $0 == "true" }.count >= 2, "\(lines)")
        check("assigning a shader to a part works",
              model.parts[0].shaderID == shader.id,
              "\(String(describing: model.parts[0].shaderID))")

        // Clearing, applyTo, enabled, and unknown parameters.
        let model2 = scene()
        model2.shaders = [shader]
        model2.parts[0].shaderID = shader.id
        add(model2, """
        import "studio" for Workspace, Shaders

        var pulse = Shaders.find("Pulse")
        var brick = Workspace.find("Brick")
        System.print(brick.shader.name)

        brick.shader = null
        pulse.applyTo(Workspace.find("Orb"))
        pulse.enabled = false
        pulse.set("nonexistent", 1)
        """)
        let (runner2, console2) = runtime(model2)
        runner2.start()
        check("a part reports the shader it uses",
              printed(console2).contains("Pulse"), "\(printed(console2))")
        check("a shader can be cleared from a part", model2.parts[0].shaderID == nil)
        check("applyTo assigns to another part", model2.parts[1].shaderID == shader.id)
        check("a shader can be disabled from a script", model2.shaders[0].enabled == false)
        check("an unknown parameter is reported",
              errors(console2).contains { $0.contains("nonexistent") }, "\(errors(console2))")
    }

    /// The Wren that ships with the app — the starter scene's script and the
    /// template every new script starts from — has to actually run.
    private static func testShippedScripts(_ check: Checker) {
        print("\nWren: shipped template")

        // The template a new script starts from, both attached and standalone.
        let attached = scene()
        add(attached, ScriptObject.wrenTemplate, name: "Template", parent: attached.parts[0].id)
        let (attachedRunner, attachedConsole) = runtime(attached)
        attachedRunner.start()
        attachedRunner.update(dt: 1.0 / 60)
        check("the new-script template runs when attached to a part",
              errors(attachedConsole).isEmpty, "\(errors(attachedConsole))")

        let loose = SceneModel()
        loose.parts = []
        loose.scripts = []
        add(loose, ScriptObject.wrenTemplate, name: "Template")
        let (looseRunner, looseConsole) = runtime(loose)
        looseRunner.start()
        looseRunner.update(dt: 1.0 / 60)
        check("the template also runs with no part to attach to",
              errors(looseConsole).isEmpty, "\(errors(looseConsole))")
    }

    // MARK: - Fixtures

    private static func scene() -> SceneModel {
        let model = SceneModel()
        model.parts = []
        model.scripts = []

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

    private static func add(_ model: SceneModel, _ source: String, name: String = "Test", parent: UUID? = nil) {
        var script = ScriptObject()
        script.name = name
        script.language = .wren
        script.source = source
        script.parentID = parent
        model.scripts.append(script)
    }

    private static func runtime(_ model: SceneModel) -> (ScriptRuntime, ScriptConsole) {
        let console = ScriptConsole()
        return (ScriptRuntime(model: model, console: console), console)
    }

    /// The console buffers onto the main queue, so drain it before inspecting.
    private static func drain() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    private static func errors(_ console: ScriptConsole) -> [String] {
        drain()
        return console.lines.filter { $0.kind == .error }.map(\.text)
    }

    private static func printed(_ console: ScriptConsole) -> [String] {
        drain()
        return console.lines.filter { $0.kind == .output }.map(\.text)
    }

    private static func near(_ a: Float, _ b: Float, _ tol: Float = 1e-3) -> Bool { abs(a - b) <= tol }

    // MARK: - Tests

    private static func testVirtualMachine(_ check: Checker) {
        print("\nWren: VM")
        let interpreter = WrenInterpreter()
        var output: [String] = []
        var failures: [String] = []
        interpreter.onOutput = { item in
            switch item {
            case .print(let text): output.append(text)
            case .error(let text): failures.append(text)
            }
        }
        check("interprets a script", interpreter.interpret(module: "t", source: "System.print(6 * 7)"))
        check("captures printed output", output == ["42"], "\(output)")
        check("no errors from valid source", failures.isEmpty, "\(failures)")

        check("reports a syntax error",
              !interpreter.interpret(module: "t2", source: "var = = ="))
        check("the error reaches the callback", !failures.isEmpty)

        // Values round-trip through the foreign call boundary.
        interpreter.moduleLoader = { $0 == "studio" ? wrenStudioModuleSource : nil }
        var seen: [String: [ScriptValue]] = [:]
        interpreter.handler = { name, arguments in
            seen[name] = arguments
            switch name {
            case "echo.number": return .number(3.5)
            case "echo.string": return .string("hi")
            case "echo.bool": return .bool(true)
            case "echo.list": return .list([.number(1), .number(2), .number(3)])
            default: return .nothing
            }
        }
        output = []
        let ok = interpreter.interpret(module: "t3", source: """
        import "studio" for Studio
        System.print(Studio.invoke_("echo.number"))
        System.print(Studio.invoke_("echo.string"))
        System.print(Studio.invoke_("echo.bool"))
        System.print(Studio.invoke_("echo.list")[1])
        Studio.invoke_("args", 1, "two", false)
        """)
        check("the studio module compiles", ok, "\(failures)")
        check("numbers come back", output.contains("3.5"), "\(output)")
        check("strings come back", output.contains("hi"), "\(output)")
        check("booleans come back", output.contains("true"), "\(output)")
        check("lists come back", output.contains("2"), "\(output)")
        let args = seen["args"] ?? []
        check("arguments arrive in order",
              args.count == 3 && args[0].asDouble == 1 && args[1].asString == "two" && args[2].asBool == false,
              "\(args)")
    }

    private static func testModuleLoads(_ check: Checker) {
        print("\nWren: studio module")
        let model = scene()
        add(model, """
        import "studio" for Vec3, Color

        var a = Vec3.new(1, 2, 3)
        var b = Vec3.new(4, 5, 6)
        System.print((a + b).toString)
        System.print(a.dot(b))
        System.print(Vec3.new(3, 4, 0).length)
        System.print(a.cross(b).toString)
        System.print(Color.rgb(255, 0, 0).r)
        System.print(Vec3.new(1, 2, 3) == Vec3.new(1, 2, 3))
        """)
        let (runner, console) = runtime(model)
        runner.start()
        let lines = printed(console)
        check("no errors loading the module", errors(console).isEmpty, "\(errors(console))")
        check("vector addition", lines.contains("Vec3(5, 7, 9)"), "\(lines)")
        check("dot product", lines.contains("32"), "\(lines)")
        check("length", lines.contains("5"), "\(lines)")
        check("cross product", lines.contains("Vec3(-3, 6, -3)"), "\(lines)")
        check("colour from 0-255", lines.contains("1"), "\(lines)")
        check("vector equality", lines.contains("true"), "\(lines)")
    }

    private static func testPartAccess(_ check: Checker) {
        print("\nWren: parts")
        let model = scene()
        add(model, """
        import "studio" for Workspace, Vec3, Color

        var brick = Workspace.find("Brick")
        System.print(brick.name)
        System.print(brick.position.toString)
        System.print(Workspace.count)
        System.print(Workspace.find("Nothing") == null)

        brick.position = Vec3.new(10, 20, 30)
        brick.size = Vec3.new(2, 2, 2)
        brick.color = Color.new(1, 0, 0)
        brick.rotation = Vec3.new(0, 90, 0)
        brick.name = "Renamed"
        brick.transparency = 0.5
        brick.anchored = false
        brick.material = "metal"
        """)
        let (runner, console) = runtime(model)
        runner.start()
        let lines = printed(console)
        check("no script errors", errors(console).isEmpty, "\(errors(console))")
        check("reads a part name", lines.contains("Brick"), "\(lines)")
        check("reads a position", lines.contains("Vec3(1, 2, 3)"), "\(lines)")
        check("reads the part count", lines.contains("2"), "\(lines)")
        check("a missing part is null", lines.contains("true"), "\(lines)")

        let brick = model.parts[0]
        check("writes position", brick.position == Vec3(10, 20, 30), "\(brick.position)")
        check("writes size", brick.size == Vec3(2, 2, 2), "\(brick.size)")
        check("writes colour", near(brick.color.x, 1) && near(brick.color.y, 0), "\(brick.color)")
        check("writes rotation", near(brick.rotationDegrees.y, 90, 0.01), "\(brick.rotationDegrees)")
        check("writes name", brick.name == "Renamed", brick.name)
        check("writes transparency", near(brick.transparency, 0.5), "\(brick.transparency)")
        check("writes anchored", brick.anchored == false)
        check("writes material", brick.material == .metal, "\(brick.material)")

        // Sizes are clamped rather than allowed to invert.
        let model2 = scene()
        add(model2, """
        import "studio" for Workspace, Vec3
        Workspace.find("Brick").size = Vec3.new(-5, 0, 3)
        """)
        let (runner2, _) = runtime(model2)
        runner2.start()
        check("size writes are clamped above zero", model2.parts[0].size.x >= 0.05,
              "\(model2.parts[0].size)")
    }

    private static func testCreateAndDestroy(_ check: Checker) {
        print("\nWren: creating parts")
        let model = scene()
        add(model, """
        import "studio" for Workspace, Vec3

        var tower = Workspace.create("cylinder", Vec3.new(0, 1, 0))
        tower.name = "Tower"

        for (i in 1..3) {
          var b = Workspace.create("block")
          b.position = Vec3.new(i * 4, 1, 0)
        }

        var copy = Workspace.find("Orb").clone()
        copy.position = Vec3.new(0, 30, 0)

        Workspace.find("Brick").destroy()
        System.print(Workspace.count)
        """)
        let (runner, console) = runtime(model)
        runner.start()
        check("no script errors", errors(console).isEmpty, "\(errors(console))")
        // 2 starting − 1 destroyed + 1 cylinder + 3 blocks + 1 clone = 6
        check("parts were created and destroyed", model.parts.count == 6, "\(model.parts.count)")
        check("created a named cylinder",
              model.parts.contains { $0.name == "Tower" && $0.shape == .cylinder })
        check("the loop created three blocks",
              model.parts.filter { $0.shape == .block }.count == 3,
              "\(model.parts.filter { $0.shape == .block }.count)")
        check("the destroyed part is gone", !model.parts.contains { $0.name == "Brick" })
        check("the clone has a distinct name",
              model.parts.filter { $0.shape == .sphere }.count == 2)
        check("count reported after destroying", printed(console).contains("6"), "\(printed(console))")

        // An unknown shape is reported rather than silently ignored.
        let model2 = scene()
        add(model2, """
        import "studio" for Workspace
        Workspace.create("dodecahedron")
        """)
        let (runner2, console2) = runtime(model2)
        runner2.start()
        check("an unknown shape reports an error",
              errors(console2).contains { $0.contains("dodecahedron") }, "\(errors(console2))")
    }

    private static func testUpdateHook(_ check: Checker) {
        print("\nWren: update hook")
        let model = scene()
        add(model, """
        import "studio" for Workspace, Runtime, Vec3

        var orb = Workspace.find("Orb")
        var ticks = 0

        Runtime.onUpdate { |dt|
          ticks = ticks + 1
          orb.position = Vec3.new(ticks, 0, 0)
          if (ticks == 3) Runtime.log("three ticks")
        }
        """)
        let (runner, console) = runtime(model)
        runner.start()
        check("the orb has not moved before the first tick",
              model.parts[1].position == Vec3(0, 5, 0), "\(model.parts[1].position)")

        for _ in 0..<3 { runner.update(dt: 1.0 / 60) }
        check("the update hook runs each frame",
              model.parts[1].position == Vec3(3, 0, 0), "\(model.parts[1].position)")
        check("Runtime.log reaches the console", printed(console).contains("three ticks"),
              "\(printed(console))")
        check("no errors during updates", errors(console).isEmpty, "\(errors(console))")

        // Runtime.time advances.
        let model2 = scene()
        add(model2, """
        import "studio" for Runtime
        Runtime.onUpdate { |dt| Runtime.log(Runtime.time > 0 ? "advancing" : "stuck") }
        """)
        let (runner2, console2) = runtime(model2)
        runner2.start()
        Thread.sleep(forTimeInterval: 0.02)
        runner2.update(dt: 0.02)
        check("Runtime.time advances", printed(console2).contains("advancing"), "\(printed(console2))")
    }

    private static func testScriptParent(_ check: Checker) {
        print("\nWren: script.parent")
        let model = scene()
        let orbID = model.parts[1].id
        add(model, """
        import "studio" for Vec3
        script.parent.position = Vec3.new(7, 7, 7)
        System.print(script.parent.name)
        System.print(script.name)
        """, name: "Attached", parent: orbID)
        let (runner, console) = runtime(model)
        runner.start()
        check("no errors", errors(console).isEmpty, "\(errors(console))")
        check("script.parent resolves", printed(console).contains("Orb"), "\(printed(console))")
        check("script.name resolves", printed(console).contains("Attached"), "\(printed(console))")
        check("the parent was moved", model.parts[1].position == Vec3(7, 7, 7),
              "\(model.parts[1].position)")

        // An unattached script sees a null parent.
        let model2 = scene()
        add(model2, "System.print(script.parent == null)")
        let (runner2, console2) = runtime(model2)
        runner2.start()
        check("an unattached script has a null parent", printed(console2).contains("true"),
              "\(printed(console2))")
    }

    private static func testPlayerBridge(_ check: Checker) {
        print("\nWren: player")
        let model = scene()
        add(model, """
        import "studio" for Player, Runtime, Vec3
        Runtime.onUpdate { |dt|
          Runtime.log("y=%(Player.position.y) grounded=%(Player.grounded)")
          if (Player.position.y > 5) Player.teleport(Vec3.new(0, 1, 0))
        }
        """)
        let console = ScriptConsole()
        let session = PlayController(model: model, console: console)
        session.start()
        session.character.position = Vec3(0, 9, 0)
        session.step(dt: 0.016)
        check("scripts read the player position",
              printed(console).contains { $0.contains("y=9") }, "\(printed(console))")
        check("scripts read grounded state",
              printed(console).contains { $0.contains("grounded=false") }, "\(printed(console))")
        check("scripts can teleport the player", session.character.position.y < 2,
              "\(session.character.position)")
        session.stop()
    }

    private static func testErrorReporting(_ check: Checker) {
        print("\nWren: errors")
        let model = scene()
        add(model, """
        import "studio" for Workspace

        var a = 1
        this is not valid wren
        """, name: "Broken")
        let (runner, console) = runtime(model)
        runner.start()
        let compileErrors = errors(console)
        check("a syntax error is reported", !compileErrors.isEmpty, "\(compileErrors)")
        check("the error names the script",
              compileErrors.contains { $0.contains("Broken") }, "\(compileErrors)")
        check("the line number excludes the host prelude",
              compileErrors.contains { $0.contains(":4") }, "\(compileErrors)")

        // A runtime error in an update hook stops further updates but does not crash.
        let model2 = scene()
        add(model2, """
        import "studio" for Runtime
        Runtime.onUpdate { |dt| Runtime.boom() }
        """, name: "Exploding")
        let (runner2, console2) = runtime(model2)
        runner2.start()
        runner2.update(dt: 0.016)
        check("a runtime error in an update is reported", !errors(console2).isEmpty,
              "\(errors(console2))")
        check("updates stop after an error", runner2.updateHookFailed)

        // One broken script does not stop the others running.
        let model3 = scene()
        add(model3, "this is broken", name: "Bad")
        add(model3, "import \"studio\" for Runtime\nRuntime.log(\"still ran\")", name: "Good")
        let (runner3, console3) = runtime(model3)
        runner3.start()
        check("a healthy script still runs alongside a broken one",
              printed(console3).contains("still ran"), "\(printed(console3))")

        // Disabled scripts are skipped.
        let model4 = scene()
        add(model4, "import \"studio\" for Runtime\nRuntime.log(\"should not run\")", name: "Off")
        model4.scripts[0].enabled = false
        let (runner4, console4) = runtime(model4)
        runner4.start()
        check("disabled scripts do not run", !printed(console4).contains("should not run"),
              "\(printed(console4))")
    }
}
