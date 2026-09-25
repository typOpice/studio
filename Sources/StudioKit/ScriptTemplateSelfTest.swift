import Foundation
import simd

/// Verification for the code new scripts start with: each place a script can be made
/// gets its own, every one runs cleanly there and says so in the Output — and the
/// lines each suggests trying work too, once uncommented.
enum ScriptTemplateSelfTest {

    static func run(check: Checker) {
        testEachPlaceHasItsOwn(check)
        testTheyRun(check)
        testTheSuggestionsWork(check)
    }

    // MARK: - The scene

    /// One of everything a script can live in: a pad the player spawns on, a lamp, a
    /// Model with two parts, a Folder with one, Script Service and both StarterPlayer
    /// folders — scripts made in each through the call the editor uses.
    private struct Stage {
        let model: SceneModel
        let scripts: [ScriptTemplates.Place: UUID]
        let wren: (part: UUID, service: UUID, group: UUID)
        let car: UUID
        let crate: UUID
        let pad: UUID
    }

    private static func stage(trying: Bool = false) -> Stage {
        let model = SceneModel()
        model.parts = []
        model.scripts = []
        model.shaders = []
        model.groups = []
        model.attachments = []
        model.constraints = []
        model.starterPlayer.respawnTime = 1

        func part(_ name: String, _ position: Vec3, size: Vec3 = Vec3(2, 2, 2), anchored: Bool = true,
                  in group: UUID? = nil) -> Part {
            var part = Part()
            part.name = name
            part.position = position
            part.size = size
            part.anchored = anchored
            part.parentID = group
            return part
        }
        let car = SceneGroup(name: "Car", kind: .model)
        let props = SceneGroup(name: "Props", kind: .folder)
        let pad = part("Pad", Vec3(0, 0.5, 18), size: Vec3(12, 1, 12))
        let crate = part("Crate", Vec3(30, 1, -30), anchored: false, in: props.id)
        model.groups = [car, props]
        model.parts = [pad, part("Lamp", Vec3(30, 2, 30)), part("Body", Vec3(-30, 1, 0), in: car.id),
                       part("Wheel", Vec3(-30, 1, 4), in: car.id), crate]

        var scripts: [ScriptTemplates.Place: UUID] = [:]
        scripts[.part] = model.addScript(parentID: pad.id)
        scripts[.model] = model.addScript(parentID: car.id)
        scripts[.folder] = model.addScript(parentID: props.id)
        scripts[.service] = model.addScript()
        scripts[.starterPlayer] = model.addScript(host: .starterPlayer)
        scripts[.starterCharacter] = model.addScript(host: .starterCharacter)
        let hud = model.addGuiObject(.screenGui, in: nil)!
        model.renameGuiObject(hud, to: "Hud")
        scripts[.gui] = model.addScript(parentID: hud, host: .starterGui)
        let wren = (part: model.addScript(parentID: model.parts[1].id, language: .wren),
                    service: model.addScript(language: .wren),
                    group: model.addScript(parentID: car.id, language: .wren))
        if trying {
            for script in model.scripts {
                model.updateScript(id: script.id) { $0.source = tryingEverything($0.source, language: $0.language) }
            }
        }
        return Stage(model: model, scripts: scripts, wren: wren, car: car.id, crate: crate.id, pad: pad.id)
    }

    /// A template with its suggestions taken up: every commented line of code
    /// uncommented. In the templates, prose comments end in punctuation or hold a full
    /// stop, and commented code never does.
    static func tryingEverything(_ source: String, language: ScriptLanguage) -> String {
        let marker = language == .luau ? "-- " : "// "
        return source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let indent = line.prefix { $0 == "\t" || $0 == " " }
            let rest = line.dropFirst(indent.count)
            guard rest.hasPrefix(marker) else { return String(line) }
            let text = rest.dropFirst(marker.count)
            let prose = text.hasSuffix(".") || text.hasSuffix(":") || text.hasSuffix(",") || text.contains(". ")
            return prose ? String(line) : String(indent) + String(text)
        }.joined(separator: "\n")
    }

    private static func play(_ model: SceneModel, seconds: Float, session: PlayController? = nil,
                             each: ((PlayController) -> Void)? = nil) -> PlayController {
        let session = session ?? {
            let started = PlayController(model: model, console: ScriptConsole())
            started.start()
            return started
        }()
        var elapsed: Float = 0
        while elapsed < seconds {
            session.step(dt: 1.0 / 60)
            each?(session)
            elapsed += 1.0 / 60
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        return session
    }

    private static func lines(_ session: PlayController, _ kind: ScriptConsole.Kind) -> [String] {
        session.console.lines.filter { $0.kind == kind }.map(\.text)
    }

    // MARK: - Tests

    private static func testEachPlaceHasItsOwn(_ check: Checker) {
        print("\nNew scripts: starter code for each place")
        let stage = stage()
        let model = stage.model
        let sources = model.scripts.map(\.source)
        check("every place starts from code of its own", Set(sources).count == sources.count,
              "\(Set(sources).count) different among \(sources.count)")
        for place in ScriptTemplates.Place.allCases {
            let source = stage.scripts[place].flatMap { model.script(id: $0)?.source }
            check("a script made in \(place) starts from its template",
                  source == ScriptTemplates.source(.luau, in: place))
        }
        check("a Wren script in a Model is told Wren can't see it",
              model.script(id: stage.wren.group)?.source.contains("doesn't see Models") == true)
        let given = model.addScript(source: "print(1)")
        check("a script made with code keeps that code", model.script(id: given)?.source == "print(1)")
        check("Script Service's template is still the plain one",
              ScriptObject.blank(language: .luau).source == ScriptTemplates.source(.luau, in: .service))
    }

    private static func testTheyRun(_ check: Checker) {
        print("\nNew scripts: starter code runs")
        let stage = stage()
        let model = stage.model
        func name(_ place: ScriptTemplates.Place) -> String { model.script(id: stage.scripts[place]!)!.name }
        let session = play(model, seconds: 2)
        let output = lines(session, .output)
        let errors = lines(session, .error)
        check("every template runs cleanly where it was made", errors.isEmpty, errors.joined(separator: " | "))
        for expected in ["\(name(.part)) is running in Pad", "Parts in Car: 2", "Things in Props: 1",
                         "Hello world!", "Player spawned with 100 health",
                         "\(name(.starterCharacter)) is running in Player",
                         "\(name(.gui)) is running in Player's Hud",
                         "\(model.script(id: stage.wren.part)!.name) is running in Lamp",
                         "Hello from Wren! The workspace has 5 parts."] {
            check("…and says so: \(expected)", output.contains(expected), "\(output)")
        }
        check("the player landing on the part is one touch, however many feet",
              output.filter { $0 == "Player touched Pad" }.count == 1, "\(output)")

        session.key("E", pressed: true)
        _ = play(model, seconds: 0.1, session: session)
        session.key("E", pressed: false)
        check("the player script hears keys", lines(session, .output).filter { $0 == "E pressed" }.count == 1)

        session.humanoid.die()
        _ = play(model, seconds: 2, session: session)
        let after = lines(session, .output)
        check("the character script hears its character die", after.contains("Player died"))
        check("after a respawn the character script runs again",
              after.filter { $0 == "\(name(.starterCharacter)) is running in Player" }.count == 2)
        check("…and the player script sees each character once",
              after.filter { $0 == "Player spawned with 100 health" }.count == 2,
              "\(after.filter { $0.hasPrefix("Player spawned") })")
        check("still no errors", lines(session, .error).isEmpty, lines(session, .error).joined(separator: " | "))
        session.stop()
    }

    private static func testTheSuggestionsWork(_ check: Checker) {
        print("\nNew scripts: the lines they suggest")
        let stage = stage(trying: true)
        let model = stage.model
        let lifted = model.parts.filter { $0.parentID == stage.car }.map(\.position.y)
        var fell = false
        let session = play(model, seconds: 3) { session in
            if session.humanoid.isDead { fell = true }
        }
        let errors = lines(session, .error)
        check("uncommented, every suggestion runs cleanly", errors.isEmpty, errors.joined(separator: " | "))
        check("the model rises 5 studs",
              zip(model.parts.filter { $0.parentID == stage.car }.map(\.position.y), lifted)
                .allSatisfy { abs($0 - $1 - 5) < 0.01 }, "\(lifted)")
        check("the folder's parts are anchored", model.part(id: stage.crate)?.anchored == true)
        check("the pad turns into a kill brick", fell)
        check("the pad lights up", model.part(id: stage.pad)?.color == Vec3(0, 1, 0))
        check("the service script waits two seconds", lines(session, .output).contains("Two seconds later"))
        check("the character walks faster", session.humanoid.walkSpeed == 24 || session.humanoid.isDead)
        session.stop()
    }
}
