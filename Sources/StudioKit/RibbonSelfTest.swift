import AppKit
import Foundation
import Metal
import simd

/// Beams and Trails: a Beam's curve (its ends, CurveSize bending it, Segments), widths,
/// colour and transparency along it, its picture stretched or wrapped and scrolling,
/// lying across its attachments or facing the camera; a Trail's history (a point each
/// MinLength, gone after Lifetime, no longer than MaxLength, none while off, Clear,
/// WidthScale); neither holding parts together; Studio's Beam tool and Add Trail (undo,
/// saved); scripts making and setting them, wrong values refused; drawn; and a host's
/// Beam and moving Trail seen by a joined player.
enum RibbonSelfTest {
    static func run(check: Checker) {
        testBeams(check)
        testTrails(check)
        testPhysics(check)
        testStudio(check)
        testScripts(check)
        testDrawing(check)
        testReadme(check)
        testTogether(check)
    }

    // MARK: - The README

    private static func testReadme(_ check: Checker) {
        print("\nBeams and Trails: the README's example")
        guard let readme = try? String(contentsOfFile: "README.md", encoding: .utf8),
              let start = readme.range(of: "## Beams and Trails"),
              let block = readme[start.upperBound...].components(separatedBy: "```lua\n").dropFirst().first?
                .components(separatedBy: "```").first else {
            print("  (README.md not found from here; skipped)")
            return
        }
        let (model, _, _) = scene(.beam)
        model.constraints = []
        model.attachments = []
        model.update(id: model.parts[0].id) { $0.name = "LeftPost" }
        model.update(id: model.parts[1].id) { $0.name = "RightPost" }
        var script = ScriptObject.blank(language: .luau)
        script.source = block
        model.scripts = model.scripts.filter { $0.host == .starterGui || $0.isModule } + [script]
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        for _ in 0..<30 { session.step(dt: frame) }
        let beam = model.constraints.first { $0.kind == .beam }
        let lit = beam.map { $0.enabled && $0.look.lightEmission == 1 && $0.look.faceCamera && $0.look.texture == "builtin://Glow" }
        for _ in 0..<45 { session.step(dt: frame) }
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("as written: a glowing laser between the posts, then off a second later",
              lit == true && model.constraints.first { $0.kind == .beam }?.enabled == false
              && beam.flatMap { Ribbons.worldEnds($0, model: model) } != nil && errors.isEmpty, "\(errors)")
        session.stop()
    }

    private static let frame: Float = 1.0 / 60

    /// Two parts, and a Beam or Trail between attachments on them.
    private static func scene(_ kind: SceneConstraint.Kind, from a: Vec3 = Vec3(0, 5, 0), to b: Vec3 = Vec3(10, 5, 0),
                              axis: Vec3 = Vec3(1, 0, 0), _ set: (inout RibbonLook) -> Void = { _ in })
        -> (SceneModel, UUID, UUID) {
        let model = SceneModel()
        model.parts = []
        model.groups = []
        model.attachments = []
        model.constraints = []
        var first = Part()
        first.name = "A"
        first.position = a
        first.size = Vec3(1, 1, 1)
        var second = first
        second.id = UUID()
        second.name = "B"
        second.position = b
        model.parts = [first, second]
        var ribbon = SceneConstraint(kind: kind)
        ribbon.parentID = first.id
        ribbon.attachment0 = model.addAttachment(on: first.id, world: a, axis: axis)
        ribbon.attachment1 = model.addAttachment(on: second.id, world: b, axis: axis)
        set(&ribbon.look)
        model.constraints.append(ribbon)
        return (model, first.id, ribbon.id)
    }

    // MARK: - Beams

    private static func testBeams(_ check: Checker) {
        print("\nBeams")
        let straight = Ribbons.beamCurve(from: .zero, axis: Vec3(1, 0, 0), to: Vec3(10, 0, 0), axis: Vec3(1, 0, 0),
                                         curve0: 0, curve1: 0, segments: 10)
        check("a curve from Attachment0 to Attachment1, Segments pieces", straight.count == 11 && straight.first == .zero
              && simd_distance(straight.last!, Vec3(10, 0, 0)) < 1e-4 && straight.allSatisfy { abs($0.y) < 1e-4 })
        let bent = Ribbons.beamCurve(from: .zero, axis: Vec3(0, 1, 0), to: Vec3(10, 0, 0), axis: Vec3(0, -1, 0),
                                     curve0: 6, curve1: 6, segments: 10)
        check("CurveSize0 and CurveSize1: out along each attachment's axis, bending between",
              bent[1].y > 1 && bent[5].y > 3 && bent[9].y > 1 && simd_distance(bent.last!, Vec3(10, 0, 0)) < 1e-4,
              "\(bent[5])")

        var (model, _, _) = scene(.beam) { look in
            look.width0 = 2
            look.width1 = 0.5
            look.color = .from(Vec3(1, 0, 0), to: Vec3(0, 0, 1))
            look.transparency = .from(0, to: 1)
            look.textureLength = 3
        }
        let trails = TrailSystem()
        var strip = Ribbons.strips(model: model, trails: trails, eye: Vec3(5, 20, 0), time: 0).first
        let v = strip?.vertices ?? []
        func width(_ i: Int) -> Float { simd_distance(v[i * 2].position, v[i * 2 + 1].position) }
        check("Width0 to Width1 along it", v.count == 22 && abs(width(0) - 2) < 1e-3 && abs(width(10) - 0.5) < 1e-3
              && abs(width(5) - 1.25) < 1e-3)
        check("…Color and Transparency along it", v.first.map { $0.color.x > 0.99 && $0.color.w > 0.99 } == true
              && v.last.map { $0.color.z > 0.99 && $0.color.w < 0.01 } == true)
        check("…lying across its attachments' secondary axes (up): flat", v.allSatisfy { abs($0.position.y - 5) < 1e-3 })
        check("Stretch: the picture TextureLength times along it", abs((v.last?.uv.x ?? 0) - 3) < 1e-4)
        let scrolled = Ribbons.strips(model: model, trails: trails, eye: Vec3(5, 20, 0), time: 0.5).first?.vertices.first?.uv.x
        check("TextureSpeed: scrolling along it", abs((scrolled ?? 0) + 0.5) < 1e-4)

        (model, _, _) = scene(.beam) { look in
            look.faceCamera = true
            look.textureMode = .wrap
            look.textureLength = 2
        }
        strip = Ribbons.strips(model: model, trails: trails, eye: Vec3(5, 5, 30), time: 0).first
        let facing = strip?.vertices ?? []
        check("FaceCamera: turned to the eye (its width upright, seen from the side)",
              facing.count == 22 && abs(facing[0].position.y - facing[1].position.y) > 0.99)
        check("Wrap: a picture every TextureLength studs", abs((facing.last?.uv.x ?? 0) - 5) < 1e-3)
        model.updateConstraint(id: model.constraints[0].id) { $0.enabled = false }
        check("Enabled off: not drawn", Ribbons.strips(model: model, trails: trails, eye: .zero, time: 0).isEmpty)
    }

    // MARK: - Trails

    private static func testTrails(_ check: Checker) {
        print("\nTrails")
        // A Trail between the top and bottom of one part, moving along X.
        let (model, mover, trail) = scene(.trail, from: Vec3(0, 6, 0), to: Vec3(0, 4, 0)) { look in
            look.lifetime = 1
            look.minLength = 0.5
        }
        model.update(id: model.parts[1].id) { $0.parentID = nil }
        // Both attachments on the moving part.
        let bottom = model.constraints[0].attachment1!
        model.updateAttachment(id: bottom) { $0.parentID = mover; $0.position = Vec3(0, -1, 0) }
        model.updateAttachment(id: model.constraints[0].attachment0!) { $0.position = Vec3(0, 1, 0) }
        let system = TrailSystem()
        for index in 0..<30 {
            model.update(id: mover) { $0.position = Vec3(Float(index) * 0.2, 5, 0) }
            system.step(dt: frame, model: model)
        }
        let points = system.histories[trail]?.points ?? []
        // 0.2 a frame: a point every third frame (0.6), past MinLength.
        check("a point each MinLength (0.5) it moves", points.count >= 9 && points.count <= 11, "\(points.count)")
        check("…each as wide as the attachments are apart", points.allSatisfy { abs(simd_distance($0.top, $0.bottom) - 2) < 1e-4 })
        for _ in 0..<70 { system.step(dt: frame, model: model) }
        // Standing still, one point stays where it is, to start from when it moves again.
        check("Lifetime: gone after it", (system.histories[trail]?.points.count ?? 9) <= 1)

        let strip = { () -> [Ribbons.Vertex] in
            Ribbons.strips(model: model, trails: system, eye: Vec3(0, 5, 30), time: 0).first?.vertices ?? []
        }
        for index in 0..<30 {
            model.update(id: mover) { $0.position = Vec3(6 - Float(index) * 0.2, 5, 0) }
            system.step(dt: frame, model: model)
        }
        let drawn = strip()
        check("drawn from where it is now back along where it's been", drawn.count >= 20
              && abs((drawn.first?.position.x ?? 0) - 0.2) < 0.01 && (drawn.last?.position.x ?? 0) > 5, "\(drawn.count)")
        model.updateConstraint(id: trail) { $0.look.widthScale = .from(1, to: 0) }
        for _ in 0..<20 { system.step(dt: frame, model: model) }
        let scaled = strip()
        let tail = scaled.count >= 2 ? simd_distance(scaled[scaled.count - 2].position, scaled[scaled.count - 1].position) : 9
        check("WidthScale: narrower as it gets older", tail < 1.4 && scaled.count >= 2
              && abs(simd_distance(scaled[0].position, scaled[1].position) - 2) < 0.01, "\(tail)")

        model.updateConstraint(id: trail) { $0.look.maxLength = 2; $0.look.lifetime = 10 }
        for index in 0..<40 {
            model.update(id: mover) { $0.position = Vec3(Float(index) * 0.3, 5, 0) }
            system.step(dt: frame, model: model)
        }
        let kept = system.histories[trail]?.points ?? []
        let length = zip(kept, kept.dropFirst()).reduce(Float(0)) { $0 + simd_distance($1.0.middle, $1.1.middle) }
        check("MaxLength: no longer than it", length <= 2.01 && kept.count >= 3, "\(length)")
        model.updateConstraint(id: trail) { $0.look.cleared += 1 }
        system.step(dt: frame, model: model)
        check("Clear: all gone (bar where it is now)", (system.histories[trail]?.points.count ?? 9) <= 1)
        model.updateConstraint(id: trail) { $0.enabled = false }
        for index in 0..<20 {
            model.update(id: mover) { $0.position = Vec3(20 + Float(index), 5, 0) }
            system.step(dt: frame, model: model)
        }
        check("Enabled off: nothing added", (system.histories[trail]?.points.count ?? 9) <= 1)
        model.update(id: mover) { $0.storage = .serverStorage }
        system.step(dt: frame, model: model)
        check("its part in storage: forgotten", system.histories[trail] == nil)
    }

    // MARK: - Physics

    private static func testPhysics(_ check: Checker) {
        print("\nBeams and Trails: not joints")
        var (model, anchored, _) = scene(.beam, from: Vec3(0, 10, 0), to: Vec3(4, 10, 0))
        model.update(id: model.parts[1].id) { $0.anchored = false }
        let loose = model.parts[1].id
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        for _ in 0..<60 { session.step(dt: frame) }
        check("a Beam from an anchored part doesn't hold another up: it falls",
              (model.part(id: loose)?.position.y ?? 10) < 7 && model.part(id: anchored)?.position.y == 10,
              "\(String(describing: model.part(id: loose)?.position))")
        session.stop()
        (model, _, _) = scene(.rope, from: Vec3(0, 10, 0), to: Vec3(4, 10, 0))
        check("(the same with a rope holds it)", model.constraints.first?.kind == .rope)
    }

    // MARK: - Studio

    private static func testStudio(_ check: Checker) {
        print("\nBeams and Trails: in Studio")
        let model = SceneModel()
        let a = model.addPart(shape: .block, at: Vec3(0, 3, 0))
        let b = model.addPart(shape: .block, at: Vec3(12, 3, 0))
        let undo = model.undoCount
        model.armJoinTool(.beam)
        model.pickJoinTarget(a)
        let beam = model.pickJoinTarget(b)
        let made = beam.flatMap(model.constraint(id:))
        let ends = made.flatMap { Ribbons.worldEnds($0, model: model) }
        check("the Beam tool: click one part, then another — a Beam from middle to middle, facing the camera",
              made?.kind == .beam && made?.look.faceCamera == true && ends.map {
                  simd_distance($0.0.position, Vec3(0, 3, 0)) < 1e-3 && simd_distance($0.1.position, Vec3(12, 3, 0)) < 1e-3
              } == true && model.undoCount == undo + 1)
        model.cancelJoinTool()
        let trail = model.addTrail(to: a)
        let trailEnds = trail.flatMap(model.constraint(id:)).flatMap { Ribbons.worldEnds($0, model: model) }
        check("Add Trail: between the top and bottom of the part, picked, a step to undo",
              trailEnds.map { abs($0.0.position.y - $0.1.position.y) > 0.5 } == true && model.selectedConstraint == trail
              && model.undoCount == undo + 2)
        let joinTools = SceneConstraint.Kind.allCases.filter { !$0.isEffect && $0.joinsTwoParts }
        check("neither is a join tool", !joinTools.contains(.beam) && !joinTools.contains(.trail) && joinTools.contains(.hinge))
        if let beam { model.updateConstraint(id: beam) { $0.look.width0 = 3; $0.look.texture = "builtin://Arrows" } }
        let reopened = SceneModel()
        if let data = try? model.encodeScene() { try? reopened.loadScene(from: data) }
        check("saved and reopened", reopened.constraints.filter(\.kind.isEffect) == model.constraints.filter(\.kind.isEffect)
              && reopened.constraints.first { $0.kind == .beam }?.look.width0 == 3)
        let joint = SceneConstraint(kind: .hinge)
        let encoded = (try? JSONEncoder().encode(joint)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check("…and a joint saves as it always did", !encoded.contains("ribbon"))
    }

    // MARK: - Scripts

    static let scriptSource = """
    local a, b = workspace.A, workspace.B
    local a0 = Instance.new("Attachment", a)
    local a1 = Instance.new("Attachment", b)
    local beam = Instance.new("Beam")
    beam.Attachment0 = a0
    beam.Attachment1 = a1
    beam.Width0 = 2
    beam.Width1 = 0.5
    beam.CurveSize0 = 3
    beam.Segments = 20
    beam.FaceCamera = true
    beam.Texture = "builtin://Glow"
    beam.TextureMode = Enum.TextureMode.Wrap
    beam.TextureSpeed = 2
    beam.LightEmission = 1
    beam.Color = ColorSequence.new(Color3.new(1, 0, 0), Color3.new(0, 0, 1))
    beam.Transparency = NumberSequence.new(0, 0.5)
    beam.Parent = a
    print("beam", beam.ClassName, beam:IsA("Beam"), beam:IsA("Constraint"), a:FindFirstChild("Beam") == beam,
    \tbeam.Attachment1 == a1, beam.Width0, beam.Segments, beam.FaceCamera, beam.TextureMode == Enum.TextureMode.Wrap,
    \ttypeof(beam.Color), beam.Transparency.Keypoints[2].Value)
    local ok1 = pcall(function() beam.Width0 = -1 end)
    local ok2 = pcall(function() beam.Color = Color3.new(1, 0, 0) end)
    local ok3 = pcall(function() beam.TextureMode = Enum.NormalId.Top end)
    local ok4 = pcall(function() beam.Lifetime = 2 end)
    print("refused", ok1, ok2, ok3, ok4)

    local t0 = Instance.new("Attachment", a)
    t0.Position = Vector3.new(0, 1, 0)
    local t1 = Instance.new("Attachment", a)
    t1.Position = Vector3.new(0, -1, 0)
    local trail = Instance.new("Trail")
    trail.Attachment0 = t0
    trail.Attachment1 = t1
    trail.Lifetime = 0.5
    trail.MinLength = 0.2
    trail.MaxLength = 12
    trail.WidthScale = NumberSequence.new(1, 0)
    trail.Parent = a
    print("trail", trail:IsA("Trail"), trail.Lifetime, trail.MaxLength, #trail.WidthScale.Keypoints)
    local ok5 = pcall(function() trail.Lifetime = 0 end)
    local ok6 = pcall(function() beam:Clear() end)
    print("refused2", ok5, ok6)
    task.wait(0.3)
    trail:Clear()
    beam.Enabled = false
    print("done")
    """

    private static func testScripts(_ check: Checker) {
        print("\nBeams and Trails: from scripts")
        let (model, _, _) = scene(.beam)
        model.constraints = []
        model.attachments = []
        var script = ScriptObject.blank(language: .luau)
        script.source = scriptSource
        model.scripts = model.scripts.filter { $0.host == .starterGui || $0.isModule } + [script]
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        for _ in 0..<40 { session.step(dt: frame) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        func said(_ prefix: String) -> String {
            session.console.lines.last { $0.kind == .output && $0.text.hasPrefix(prefix) }?.text ?? "(nothing)"
        }
        check("Instance.new(\"Beam\") between two attachments: a Beam, not a Constraint, found by name, read back in its types",
              said("beam") == "beam Beam true false true true 2 20 true true ColorSequence 0.5", said("beam"))
        check("…wrong values refused: a width below 0, a Color3 for a ColorSequence, the wrong enum, a Trail's property",
              said("refused ") == "refused false false false false", said("refused "))
        check("Instance.new(\"Trail\"): Lifetime, MaxLength, WidthScale", said("trail") == "trail true 0.5 12 2", said("trail"))
        check("…a Lifetime of 0 refused, and a Beam has no Clear", said("refused2") == "refused2 false false", said("refused2"))
        let beam = model.constraints.first { $0.kind == .beam }, trail = model.constraints.first { $0.kind == .trail }
        check("…on the scene as set", beam?.look.width0 == 2 && beam?.look.curveSize0 == 3 && beam?.look.textureMode == .wrap
              && beam?.look.color.last?.color == Vec3(0, 0, 1) && trail?.look.lifetime == 0.5
              && trail?.look.widthScale.last?.value == 0)
        check("Clear and Enabled", said("done") == "done" && trail?.look.cleared == 1 && beam?.enabled == false)
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("no errors", errors.isEmpty, "\(errors)")
        session.stop()
    }

    // MARK: - Drawing

    private static func testDrawing(_ check: Checker) {
        print("\nBeams and Trails: drawn")
        guard let device = MTLCreateSystemDefaultDevice() else {
            check("a Metal device is available", false)
            return
        }
        let (model, _, beam) = scene(.beam, from: Vec3(-5, 0, 0), to: Vec3(5, 0, 0)) { look in
            look.faceCamera = true
            look.width0 = 3
            look.width1 = 3
            look.transparency = .from(0, to: 0)
            look.color = .from(Vec3(0, 0, 1), to: Vec3(0, 0, 1))
        }
        model.showGrid = false
        model.update(id: model.parts[0].id) { $0.transparency = 1 }
        model.update(id: model.parts[1].id) { $0.transparency = 1 }
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
            guard let pixels = renderer.frameSnapshot(width: 64, height: 64) else { return .zero }
            let p = pixels[32 * 64 + 32]
            return SIMD3(Float(p.z), Float(p.y), Float(p.x)) / 255
        }
        let blue = middle()
        check("a Beam drawn: blue across the middle", blue.z > 0.7 && blue.x < 0.3, "\(blue)")
        model.updateConstraint(id: beam) { $0.enabled = false }
        let off = middle()
        check("…and not, when off", off.z < 0.7 || off.x > 0.3, "\(off)")
    }

    // MARK: - Together

    private static func testTogether(_ check: Checker) {
        print("\nBeams and Trails: a host and a joined player")
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            var base = Part()
            base.name = "Baseplate"
            base.position = Vec3(0, -0.5, 0)
            base.size = Vec3(200, 1, 200)
            var post = Part()
            post.name = "Post"
            post.position = Vec3(-10, 3, 10)
            var runner = Part()
            runner.name = "Runner"
            runner.position = Vec3(10, 3, 10)
            runner.size = Vec3(1, 2, 1)
            model.parts = [base, post, runner]
            var host = ScriptObject.blank(language: .luau)
            host.source = """
            local post, runner = workspace.Post, workspace.Runner
            local beam = Instance.new("Beam")
            beam.Attachment0 = Instance.new("Attachment", post)
            beam.Attachment1 = Instance.new("Attachment", runner)
            beam.Width0 = 2
            beam.Parent = post
            local top = Instance.new("Attachment", runner)
            top.Position = Vector3.new(0, 1, 0)
            local bottom = Instance.new("Attachment", runner)
            bottom.Position = Vector3.new(0, -1, 0)
            local trail = Instance.new("Trail")
            trail.Attachment0 = top
            trail.Attachment1 = bottom
            trail.Parent = runner
            local start = runner.Position
            game:GetService("RunService").Heartbeat:Connect(function()
            \trunner.Position = start + Vector3.new(0, 0, math.min(time(), 3) * 4)
            end)
            """
            model.scripts += [host]
        }), let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        let seen = TrailSystem()
        LANSelfTest.run([hosting, joining], seconds: 1.5) { seen.step(dt: frame, model: joining.model) }
        let beam = joining.model.constraints.first { $0.kind == .beam }
        let trail = joining.model.constraints.first { $0.kind == .trail }
        check("a host script's Beam reaches the joined player, as set", beam?.look.width0 == 2
              && beam.flatMap { Ribbons.worldEnds($0, model: joining.model) } != nil)
        let points = trail.flatMap { seen.histories[$0.id]?.points } ?? []
        check("…and its Trail, left behind the part the host moves, in the joined player's own game",
              points.count >= 5, "\(points.count)")
        let errors = (hosting.player!.console.lines + sam.console.lines).filter { $0.kind == .error }.map(\.text)
        check("…with no errors on either", errors.isEmpty, "\(errors)")
        joining.leaveGame()
        hosting.leaveGame()
    }
}
