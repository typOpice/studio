import AppKit
import Foundation
import Metal
import simd

/// ParticleEmitters: the particles themselves (Rate, Lifetime, the face they come out
/// of and SpreadAngle, Acceleration, Drag, Enabled, Emit, Clear, LockedToPart,
/// TimeScale, the sequences, as many as there may be, none in storage); Studio adding
/// them (undo, the presets), saving them and copying them with their part; scripts
/// making, reading, setting, moving, cloning and destroying them, and wrong values
/// refused; drawn, and hidden behind a wall; and a host's bursts reaching a joined
/// player, whose own LocalScript's emitter stays theirs.
enum ParticleSelfTest {
    static func run(check: Checker) {
        testParticles(check)
        testStudio(check)
        testScripts(check)
        testDrawing(check)
        testReadme(check)
        testTogether(check)
    }

    // MARK: - The README

    private static func testReadme(_ check: Checker) {
        print("\nParticles: the README's example")
        guard let readme = try? String(contentsOfFile: "README.md", encoding: .utf8),
              let start = readme.range(of: "## Particles: fire, smoke, sparkles"),
              let block = readme[start.upperBound...].components(separatedBy: "```lua\n").dropFirst().first?
                .components(separatedBy: "```").first else {
            print("  (README.md not found from here; skipped)")
            return
        }
        let model = SceneModel()
        model.groups = []
        var base = Part()
        base.name = "Baseplate"
        base.position = Vec3(0, -0.5, 0)
        base.size = Vec3(200, 1, 200)
        var pad = Part()
        pad.name = "Pad"
        pad.position = Vec3(0, 0.5, -10)
        pad.size = Vec3(6, 1, 6)
        model.parts = [base, pad]
        var script = ScriptObject.blank(language: .luau)
        script.source = block
        script.parentID = pad.id
        model.scripts = model.scripts.filter { $0.host == .starterGui || $0.isModule } + [script]
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        let system = ParticleSystem()
        var most = 0
        for index in 0..<90 {
            // A moment for the script to start, then onto the part.
            if index == 10 {
                session.character.position = Vec3(0, 1, -10)
                session.character.velocity = .zero
            }
            session.step(dt: frame)
            system.step(dt: frame, model: model)
            if let confetti = model.part(id: pad.id)?.emitters.first {
                most = max(most, system.particles(of: .init(part: pad.id, emitter: confetti.id)).count)
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("as written: stepping onto the part throws confetti", most >= 60 && errors.isEmpty, "\(most) \(errors)")
        session.stop()
    }

    private static let frame: Float = 1.0 / 60

    /// A model with one part, holding this emitter.
    private static func place(_ emitter: ParticleEmitter, at position: Vec3 = Vec3(0, 5, 0),
                              turned: simd_quatf = simd_quatf(angle: 0, axis: Vec3(0, 1, 0))) -> (SceneModel, UUID) {
        let model = SceneModel()
        var part = Part()
        part.name = "Emitter"
        part.position = position
        part.orientation = turned
        part.size = Vec3(2, 2, 2)
        part.emitters = [emitter]
        model.parts = [part]
        return (model, part.id)
    }

    private static func run(_ system: ParticleSystem, _ model: SceneModel, seconds: Float) {
        var elapsed: Float = 0
        while elapsed < seconds - 1e-4 {
            system.step(dt: frame, model: model)
            elapsed += frame
        }
    }

    private static func flock(_ system: ParticleSystem, _ model: SceneModel, _ part: UUID) -> [ParticleSystem.Particle] {
        guard let emitter = model.part(id: part)?.emitters.first else { return [] }
        return system.particles(of: .init(part: part, emitter: emitter.id))
    }

    // MARK: - The particles

    private static func testParticles(_ check: Checker) {
        print("\nParticles: made, moved and gone")
        var steady = ParticleEmitter()
        steady.rate = 20
        steady.lifetime = SIMD2(0.5, 0.5)
        steady.speed = SIMD2(5, 5)
        var (model, part) = place(steady)
        var system = ParticleSystem()
        run(system, model, seconds: 0.25)
        let early = flock(system, model, part)
        check("Rate: 20 a second", abs(early.count - 5) <= 1, "\(early.count)")
        check("…each made in the part, flying out of its top at its Speed",
              early.allSatisfy { abs($0.velocity.x) < 1e-4 && abs($0.velocity.y - 5) < 1e-3 && abs($0.position.x) <= 1.01 }
              && early.allSatisfy { $0.position.y > 4 })
        run(system, model, seconds: 2)
        check("Lifetime: gone after it, so about Rate × Lifetime alive", abs(flock(system, model, part).count - 10) <= 1,
              "\(flock(system, model, part).count)")

        // Turned on its side, the top faces −X; SpreadAngle fans them out.
        var fanned = ParticleEmitter()
        fanned.rate = 200
        fanned.spreadAngle = SIMD2(30, 30)
        (model, part) = place(fanned, turned: simd_quatf(angle: .pi / 2, axis: Vec3(0, 0, 1)))
        system = ParticleSystem()
        run(system, model, seconds: 0.5)
        let fan = flock(system, model, part)
        let angles = fan.map { acos(min(max(simd_dot(simd_normalize($0.velocity), Vec3(-1, 0, 0)), -1), 1)) * 180 / .pi }
        let heading = simd_normalize(fan.reduce(Vec3.zero) { $0 + simd_normalize($1.velocity) })
        check("the part turned: they come out of its top, wherever that faces", simd_dot(heading, Vec3(-1, 0, 0)) > 0.97,
              "\(heading)")
        check("SpreadAngle: fanned out, up to 30° about each axis", (angles.max() ?? 0) > 15 && (angles.max() ?? 90) < 43,
              "\(angles.max() ?? -1)")

        // Acceleration, and Drag.
        var falling = ParticleEmitter()
        falling.rate = 0
        falling.acceleration = Vec3(0, -10, 0)
        falling.emitted = 1
        falling.lastBurst = 1
        (model, part) = place(falling)
        system = ParticleSystem()
        run(system, model, seconds: 1)
        check("Acceleration: 5 up, less 10 a second, for a second", abs((flock(system, model, part).first?.velocity.y ?? 0) + 5) < 0.3,
              "\(String(describing: flock(system, model, part).first?.velocity))")
        var slowed = falling
        slowed.acceleration = .zero
        slowed.drag = 1
        (model, part) = place(slowed)
        system = ParticleSystem()
        run(system, model, seconds: 1)
        check("Drag: slower by e each second", abs((flock(system, model, part).first?.velocity.y ?? 0) - 5 / exp(1)) < 0.1)

        // Enabled, Emit and Clear, as a script's host call leaves them.
        var switched = ParticleEmitter()
        switched.rate = 30
        switched.lifetime = SIMD2(3, 3)
        (model, part) = place(switched)
        system = ParticleSystem()
        run(system, model, seconds: 0.5)
        let before = flock(system, model, part).count
        model.updateEmitter(EmitterRef(part: part, emitter: switched.id)) { $0.enabled = false }
        run(system, model, seconds: 0.5)
        check("Enabled off: no more made, the ones there carry on", before > 10 && flock(system, model, part).count == before)
        model.updateEmitter(EmitterRef(part: part, emitter: switched.id)) { $0.emitted += 40; $0.lastBurst = 40 }
        system.step(dt: frame, model: model)
        check("Emit(40): forty at once, Enabled or not", flock(system, model, part).count == before + 40)
        model.updateEmitter(EmitterRef(part: part, emitter: switched.id)) { $0.cleared += 1 }
        system.step(dt: frame, model: model)
        check("Clear: all gone", flock(system, model, part).isEmpty)
        let late = ParticleSystem()
        model.updateEmitter(EmitterRef(part: part, emitter: switched.id)) { $0.emitted += 25; $0.lastBurst = 25 }
        late.step(dt: frame, model: model)
        check("a machine seeing an emitter for the first time makes its last burst only, not every one before",
              late.particles(of: .init(part: part, emitter: switched.id)).count == 25)

        // LockedToPart: they go where the part goes.
        var locked = ParticleEmitter()
        locked.rate = 50
        locked.speed = .zero
        locked.lockedToPart = true
        var loose = locked
        loose.id = UUID()
        loose.lockedToPart = false
        (model, part) = place(locked)
        model.update(id: part) { $0.emitters.append(loose) }
        system = ParticleSystem()
        run(system, model, seconds: 0.2)
        model.update(id: part) { $0.position.x += 10 }
        var mean: [Bool: Float] = [:]
        system.sprites(model: model) { emitter, sprites in
            mean[emitter.lockedToPart] = sprites.map(\.position.x).reduce(0, +) / Float(max(sprites.count, 1))
        }
        check("LockedToPart: they move with the part; otherwise they stay where they were made",
              abs((mean[true] ?? 0) - 10) < 1.1 && abs(mean[false] ?? 99) < 1.1, "\(mean)")

        // TimeScale 0: time stands still.
        var frozen = steady
        frozen.timeScale = 0
        (model, part) = place(frozen)
        system = ParticleSystem()
        run(system, model, seconds: 0.5)
        check("TimeScale 0: nothing made, nothing moves", flock(system, model, part).isEmpty)

        // The sequences, through a particle's life.
        var fading = ParticleEmitter()
        fading.rate = 0
        fading.speed = .zero
        fading.lifetime = SIMD2(2, 2)
        fading.size = [NumberKey(time: 0, value: 1), NumberKey(time: 1, value: 3, envelope: 0.5)]
        fading.transparency = .from(0, to: 1)
        fading.color = .from(Vec3(1, 0, 0), to: Vec3(0, 0, 1))
        fading.brightness = 2
        fading.lightEmission = 0.7
        fading.emitted = 20
        fading.lastBurst = 20
        (model, part) = place(fading)
        system = ParticleSystem()
        run(system, model, seconds: 1)
        var drawn: [ParticleSystem.Sprite] = []
        system.sprites(model: model) { _, sprites in drawn = sprites }
        let sizes = drawn.map(\.size)
        check("halfway through its life: Size halfway, give or take half its envelope", drawn.count == 20
              && sizes.allSatisfy { abs($0 - 2) <= 0.26 } && Set(sizes.map { Int($0 * 100) }).count > 3, "\(sizes.prefix(4))")
        check("…Transparency and Color halfway, Brightness and LightEmission too",
              drawn.allSatisfy { abs($0.color.w - 0.5) < 0.02 && abs($0.color.x - 1) < 0.02 && abs($0.color.z - 1) < 0.02
                  && abs($0.emission - 0.7) < 1e-4 }, "\(String(describing: drawn.first))")

        // No more than 2000 from one emitter; none in storage.
        var flood = ParticleEmitter()
        flood.rate = 1000
        flood.lifetime = SIMD2(10, 10)
        (model, part) = place(flood)
        system = ParticleSystem()
        run(system, model, seconds: 3)
        check("at most 2000 at once from one emitter", flock(system, model, part).count == ParticleEmitter.most)
        model.update(id: part) { $0.storage = .serverStorage }
        system.step(dt: frame, model: model)
        check("a part put in storage has none", system.count == 0)
    }

    // MARK: - Studio

    private static func testStudio(_ check: Checker) {
        print("\nParticles: in Studio")
        let model = SceneModel()
        let torch = model.addPart(shape: .block, at: Vec3(0, 1, 0))
        let undo = model.undoCount
        let fire = model.addEmitter(.fire, to: torch)
        let smoke = model.addEmitter(.smoke, to: torch)
        check("Add ParticleEmitter › Fire, then Smoke: both in the part, the last picked, a step each to undo",
              model.part(id: torch)?.emitters.map(\.name) == ["Fire", "Smoke"] && model.selectedEmitter == smoke
              && model.undoCount == undo + 2 && fire != nil)
        check("…each preset its own", Set(ParticleEmitter.Preset.allCases.map { ParticleEmitter.preset($0).texture }).count == 5)
        model.undo()
        check("undo takes the last away", model.part(id: torch)?.emitters.map(\.name) == ["Fire"])
        if let fire { model.updateEmitter(fire) { $0.rate = 12; $0.spreadAngle = SIMD2(5, 7) } }

        let reopened = SceneModel()
        if let data = try? model.encodeScene() { try? reopened.loadScene(from: data) }
        check("saved and reopened as they were", reopened.part(id: torch)?.emitters == model.part(id: torch)?.emitters
              && reopened.part(id: torch)?.emitters.first?.rate == 12)
        let plain = try? JSONEncoder().encode(Part())
        check("…and a part without one saves as it always did",
              plain.map { String(decoding: $0, as: UTF8.self).contains("emitters") } == false)

        model.selection = [torch]
        model.duplicateSelected()
        let copy = model.selection.first.flatMap(model.part(id:))
        check("a copied part brings its emitters", copy?.id != torch && copy?.emitters.map(\.name) == ["Fire"])
        if let fire {
            model.removeEmitter(fire)
            check("deleting one", model.part(id: torch)?.emitters.isEmpty == true && model.selectedEmitter == nil)
        }
    }

    // MARK: - Scripts

    static let scriptSource = """
    local part = workspace.Torch
    local fire = Instance.new("ParticleEmitter")
    fire.Name = "Fire"
    fire.Rate = 30
    fire.Lifetime = NumberRange.new(1, 2)
    fire.Speed = NumberRange.new(4)
    fire.SpreadAngle = Vector2.new(10, 20)
    fire.Acceleration = Vector3.new(0, 2, 0)
    fire.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1, 0.2), NumberSequenceKeypoint.new(1, 0) })
    fire.Transparency = NumberSequence.new(0, 1)
    fire.Color = ColorSequence.new(Color3.new(1, 0.8, 0.2), Color3.new(1, 0.2, 0))
    fire.LightEmission = 1
    fire.EmissionDirection = Enum.NormalId.Front
    fire.Texture = "builtin://Fire"
    fire.Parent = part
    print("made", fire.Parent == part, part:FindFirstChild("Fire") == fire, part.Fire == fire, fire:IsA("ParticleEmitter"), fire.ClassName)
    print("read", fire.Rate, fire.Lifetime.Min, fire.Lifetime.Max, fire.Speed.Max, fire.SpreadAngle.Y, fire.Acceleration.Y,
    \t#fire.Size.Keypoints, math.abs(fire.Size.Keypoints[1].Envelope - 0.2) < 1e-6, math.abs(fire.Color.Keypoints[2].Value.G - 0.2) < 1e-6,
    \tfire.EmissionDirection == Enum.NormalId.Front, typeof(fire.Lifetime), tostring(fire.Speed))
    local ok1 = pcall(function() fire.Rate = "fast" end)
    local ok2 = pcall(function() fire.Lifetime = 3 end)
    local ok3 = pcall(function() fire.Color = Color3.new(1, 0, 0) end)
    local ok4 = pcall(function() NumberRange.new(5, 1) end)
    local ok5 = pcall(function() fire.Parent = workspace end)
    local ok6 = pcall(function() fire.Sparkle = 1 end)
    print("refused", ok1, ok2, ok3, ok4, ok5, ok6)
    local burst = Instance.new("ParticleEmitter", part)
    burst.Name = "Burst"
    burst.Rate = 0
    burst:Emit(25)
    local count = 0
    for _, child in part:GetChildren() do
    \tif child:IsA("ParticleEmitter") then
    \t\tcount += 1
    \tend
    end
    print("children", count, #part:GetDescendants() >= 2)
    local copy = fire:Clone()
    print("clone", copy.Parent == nil, copy.Name, copy.Rate)
    copy.Parent = workspace.Other
    print("moved", copy.Parent == workspace.Other, workspace.Other.Fire == copy, copy.Rate)
    copy.Parent = nil
    print("out", copy.Parent == nil, workspace.Other:FindFirstChild("Fire") == nil)
    task.wait(0.5)
    burst:Clear()
    fire.Enabled = false
    copy:Destroy()
    burst:Destroy()
    print("done", part:FindFirstChild("Burst") == nil, part:FindFirstChild("Fire") == fire)
    """

    private static func testScripts(_ check: Checker) {
        print("\nParticles: from scripts")
        let model = SceneModel()
        model.parts = []
        model.groups = []
        let torch = model.addPart(shape: .block, at: Vec3(0, 1, 0))
        model.update(id: torch) { $0.name = "Torch" }
        let other = model.addPart(shape: .block, at: Vec3(8, 1, 0))
        model.update(id: other) { $0.name = "Other" }
        var script = ScriptObject.blank(language: .luau)
        script.source = scriptSource
        model.scripts = model.scripts.filter { $0.host == .starterGui || $0.isModule } + [script]
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        let system = ParticleSystem()
        for _ in 0..<6 {
            session.step(dt: frame)
            system.step(dt: frame, model: model)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        func said(_ prefix: String) -> String {
            session.console.lines.last { $0.kind == .output && $0.text.hasPrefix(prefix) }?.text ?? "(nothing)"
        }
        check("Instance.new(\"ParticleEmitter\"), Parent a part: found by name, a child, IsA",
              said("made") == "made true true true true ParticleEmitter", said("made"))
        check("…its properties read back in their types: NumberRange, Vector2, NumberSequence with envelopes, ColorSequence, NormalId",
              said("read") == "read 30 1 2 4 20 2 2 true true true NumberRange 4 4", said("read"))
        check("…wrong values refused: a string, a number for a range, a Color3 for a ColorSequence, a range the wrong way, the Workspace for a parent, no such property",
              said("refused") == "refused false false false false false false", said("refused"))
        let fire = model.part(id: torch)?.emitters.first { $0.name == "Fire" }
        check("…and on the part, as set", fire?.rate == 30 && fire?.lifetime == SIMD2(1, 2) && fire?.spreadAngle == SIMD2(10, 20)
              && fire?.size.first?.envelope == 0.2 && fire?.emissionDirection == .front && fire?.lightEmission == 1
              && fire?.texture == "builtin://Fire")
        check("GetChildren and GetDescendants have them", said("children") == "children 2 true", said("children"))
        let burst = model.part(id: torch)?.emitters.first { $0.name == "Burst" }
        let bursting = burst.map { system.particles(of: .init(part: torch, emitter: $0.id)).count } ?? 0
        check("Emit(25): made and burst at once, 25 particles", burst?.emitted == 25 && bursting == 25, "\(bursting)")
        check("Clone: a copy in nothing, then moved to another part, then out again",
              said("clone") == "clone true Fire 30" && said("moved") == "moved true true 30" && said("out") == "out true true")
        for _ in 0..<40 {
            session.step(dt: frame)
            system.step(dt: frame, model: model)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        check("Clear, Enabled off, Destroy", said("done") == "done true true"
              && model.part(id: torch)?.emitters.map(\.name) == ["Fire"] && model.part(id: torch)?.emitters.first?.enabled == false
              && model.part(id: other)?.emitters.isEmpty == true, said("done"))
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("no errors", errors.isEmpty, "\(errors)")
        session.stop()
    }

    // MARK: - Drawing

    private static func testDrawing(_ check: Checker) {
        print("\nParticles: drawn")
        guard let device = MTLCreateSystemDefaultDevice() else {
            check("a Metal device is available", false)
            return
        }
        let model = SceneModel()
        model.parts = []
        model.groups = []
        model.showGrid = false
        var holder = Part()
        holder.name = "Holder"
        holder.transparency = 1
        holder.size = Vec3(1, 1, 1)
        var glow = ParticleEmitter()
        glow.texture = "builtin://Circle"
        glow.rate = 300
        glow.lifetime = SIMD2(5, 5)
        glow.speed = .zero
        glow.size = .from(6, to: 6)
        glow.color = .from(Vec3(1, 0, 0), to: Vec3(1, 0, 0))
        holder.emitters = [glow]
        model.parts = [holder]
        let view = StudioMTKView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        view.device = device
        let editor = ViewportController(model: model)
        editor.camera.target = .zero
        editor.camera.distance = 12
        editor.camera.pitch = 0.1
        guard let renderer = Renderer(device: device, view: view, source: editor) else {
            check("the renderer builds", false)
            return
        }
        func middle() -> SIMD3<Float> {
            for _ in 0..<30 { renderer.particles.step(dt: frame, model: model) }
            guard let pixels = renderer.frameSnapshot(width: 64, height: 64) else { return .zero }
            let p = pixels[32 * 64 + 32]
            return SIMD3(Float(p.z), Float(p.y), Float(p.x)) / 255
        }
        let red = middle()
        check("drawn: red where the particles are", red.x > 0.6 && red.y < 0.35 && red.z < 0.35, "\(red)")
        var wall = Part()
        wall.name = "Wall"
        wall.position = editor.camera.position * 0.5
        wall.size = Vec3(6, 6, 0.5)
        wall.color = Vec3(0.1, 0.9, 0.1)
        let facing = simd_normalize(editor.camera.position)
        wall.orientation = simd_quatf(from: Vec3(0, 0, 1), to: facing)
        model.parts.append(wall)
        let hidden = middle()
        check("…hidden behind a wall in front of them", hidden.x < 0.2 && hidden.y > hidden.x * 2, "\(hidden)")
        model.parts.removeAll { $0.name == "Wall" }
        model.update(id: holder.id) { $0.emitters[0].enabled = false; $0.emitters[0].cleared += 1 }
        let gone = middle()
        check("…and gone when cleared", gone.x < 0.6 || gone.y > 0.35, "\(gone)")
    }

    // MARK: - Together

    private static func testTogether(_ check: Checker) {
        print("\nParticles: a host and a joined player")
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            var base = Part()
            base.name = "Baseplate"
            base.position = Vec3(0, -0.5, 0)
            base.size = Vec3(200, 1, 200)
            var torch = Part()
            torch.name = "Torch"
            torch.position = Vec3(10, 1, 10)
            var lamp = Part()
            lamp.name = "Lamp"
            lamp.position = Vec3(-10, 1, 10)
            model.parts = [base, torch, lamp]
            var host = ScriptObject.blank(language: .luau)
            host.source = """
            task.wait(0.6)
            local sparks = Instance.new("ParticleEmitter")
            sparks.Name = "Sparks"
            sparks.Rate = 0
            sparks.Parent = workspace.Torch
            sparks:Emit(40)
            """
            var local = ScriptObject.blank(language: .luau)
            local.host = .starterPlayer
            // The joined player's alone (on the host's machine, a LocalScript's changes
            // to the world are the world's).
            local.source = """
            if game:GetService("Players").LocalPlayer.Name == "Sam" then
            \tlocal glow = Instance.new("ParticleEmitter", workspace:WaitForChild("Lamp"))
            \tglow.Name = "MyGlow"
            end
            """
            model.scripts += [host, local]
        }), let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        let seen = ParticleSystem()
        var most = 0
        LANSelfTest.run([hosting, joining], seconds: 1.6) {
            seen.step(dt: frame, model: joining.model)
            if let sparks = joining.model.parts.first(where: { $0.name == "Torch" })?.emitters.first {
                most = max(most, seen.particles(of: .init(part: joining.model.parts.first { $0.name == "Torch" }!.id,
                                                          emitter: sparks.id)).count)
            }
        }
        let sparks = joining.model.parts.first { $0.name == "Torch" }?.emitters.first
        check("a host script's emitter reaches the joined player, and its Emit(40) bursts there",
              sparks?.name == "Sparks" && sparks?.emitted == 40 && most == 40, "\(most)")
        let hostLamp = hosting.model.parts.first { $0.name == "Lamp" }, theirLamp = joining.model.parts.first { $0.name == "Lamp" }
        check("a joined player's LocalScript's emitter is theirs alone",
              theirLamp?.emitters.map(\.name) == ["MyGlow"] && hostLamp?.emitters.isEmpty == true)
        let errors = (hosting.player!.console.lines + sam.console.lines).filter { $0.kind == .error }.map(\.text)
        check("…with no errors on either", errors.isEmpty, "\(errors)")
        joining.leaveGame()
        hosting.leaveGame()
    }
}
