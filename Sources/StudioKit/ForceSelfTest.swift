import Foundation
import simd

/// AlignPosition, VectorForce and NoCollisionConstraint: a VectorForce holding a block up
/// against gravity, lifting it with more, pushing along its attachment's axes, turning it
/// off the middle; an AlignPosition pulling a block to a target and holding it there, not
/// with too little MaxForce, no faster than MaxVelocity, at once with RigidityEnabled, to
/// Position in OneAttachment mode, following a target that moves; a block falling through
/// a platform it mustn't collide with (and not, disabled); Studio's tools and saving;
/// scripts; and a host's AlignPosition moving a block in a joined player's game.
enum ForceSelfTest {
    static func run(check: Checker) {
        testVectorForce(check)
        testAlignPosition(check)
        testNoCollision(check)
        testStudio(check)
        testScripts(check)
        testReadme(check)
        testTogether(check)
    }

    // MARK: - The README

    private static func testReadme(_ check: Checker) {
        print("\nForces: the README's example")
        guard let readme = try? String(contentsOfFile: "README.md", encoding: .utf8),
              let start = readme.range(of: "### Pushes, pulls and passing through"),
              let block = readme[start.upperBound...].components(separatedBy: "```lua\n").dropFirst().first?
                .components(separatedBy: "```").first else {
            print("  (README.md not found from here; skipped)")
            return
        }
        // The Ghost across the lift's way up, halfway.
        let model = scene([self.block("Ground", Vec3(0, -0.5, 0), size: Vec3(200, 1, 200), anchored: true),
                           self.block("Lift", Vec3(0, 1, 0), size: Vec3(6, 1, 6)),
                           self.block("Ghost", Vec3(0, 11, 0), size: Vec3(10, 1, 10), anchored: true)])
        var script = ScriptObject.blank(language: .luau)
        script.source = block
        model.scripts = [script]
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        var highest: Float = 0
        for _ in 0..<(60 * 4) {
            session.step(dt: frame)
            highest = max(highest, part(model, "Lift").position.y)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("as written: the lift floats up through the Ghost to the ledge", highest > 19 && errors.isEmpty,
              "\(highest) \(errors)")
        session.stop()
    }

    static let frame: Float = 1.0 / 60

    static func block(_ name: String, _ position: Vec3, size: Vec3 = Vec3(2, 2, 2), anchored: Bool = false) -> Part {
        var part = PhysicsSelfTest.block(position, size: size, anchored: anchored)
        part.name = name
        return part
    }

    static func scene(_ parts: [Part]) -> SceneModel {
        let model = SceneModel()
        model.parts = parts
        model.scripts = []
        model.groups = []
        model.attachments = []
        model.constraints = []
        return model
    }

    /// Runs physics over a model as the game does.
    static func simulate(_ world: PhysicsWorld, _ model: SceneModel, seconds: Float, each: (() -> Void)? = nil) {
        var elapsed: Float = 0
        while elapsed < seconds - 1e-4 {
            each?()
            world.sync(model.parts, constraints: model.constraints, attachments: model.attachments)
            let result = world.step(dt: frame)
            var parts = model.parts
            let index = Dictionary(uniqueKeysWithValues: parts.enumerated().map { ($1.id, $0) })
            for (id, pose) in result.moved { if let i = index[id] { parts[i].pose = pose } }
            model.parts = parts
            elapsed += frame
        }
    }

    static func part(_ model: SceneModel, _ name: String) -> Part { model.parts.first { $0.name == name }! }

    /// A constraint of a kind, from an attachment at the middle of one part (and another's).
    @discardableResult
    static func add(_ kind: SceneConstraint.Kind, _ model: SceneModel, on a: String, to b: String? = nil,
                            _ set: (inout SceneConstraint) -> Void = { _ in }) -> UUID {
        var c = SceneConstraint(kind: kind)
        let first = part(model, a)
        c.parentID = first.id
        c.attachment0 = model.addAttachment(on: first.id, world: first.position, axis: Vec3(1, 0, 0))
        if let b {
            let second = part(model, b)
            c.attachment1 = model.addAttachment(on: second.id, world: second.position, axis: Vec3(1, 0, 0))
        }
        set(&c)
        model.constraints.append(c)
        return c.id
    }

    private static func weight(_ part: Part) -> Float {
        PhysicsWorld.massProperties(of: part).mass * CharacterController.gravity
    }

    // MARK: - VectorForce

    private static func testVectorForce(_ check: Checker) {
        print("\nForces: VectorForce")
        func run(_ force: Vec3, relativeTo: ForceFrame = .world, turned: simd_quatf? = nil, atCentre: Bool = true,
                 attachmentAt: Vec3? = nil) -> (Part, Vec3) {
            var box = block("Box", Vec3(0, 20, 0))
            if let turned { box.orientation = turned }
            let model = scene([box])
            var c = SceneConstraint(kind: .vectorForce)
            c.attachment0 = model.addAttachment(on: box.id, world: attachmentAt ?? box.position, axis: Vec3(1, 0, 0))
            // Its axes the part's own, so they turn with it.
            if let id = c.attachment0 {
                model.updateAttachment(id: id) { $0.axis = Vec3(1, 0, 0); $0.secondaryAxis = Vec3(0, 1, 0) }
            }
            c.force = force
            c.relativeTo = relativeTo
            c.applyAtCenterOfMass = atCentre
            model.constraints = [c]
            let world = PhysicsWorld()
            simulate(world, model, seconds: 1)
            return (part(model, "Box"), world.motion(of: box.id)?.angularVelocity ?? .zero)
        }
        let heavy = weight(block("Box", .zero))
        let hover = run(Vec3(0, heavy, 0)).0.position
        let fall = run(.zero).0.position
        let lift = run(Vec3(0, heavy * 2, 0)).0.position
        check("a Force equal to its weight holds a block up; none, it falls; twice, it rises",
              abs(hover.y - 20) < 0.5 && fall.y < 12 && lift.y > 25, "\(hover.y) \(fall.y) \(lift.y)")
        // Turned a quarter about Z, the attachment's Y points along world −X.
        let sideways = run(Vec3(0, heavy * 3, 0), relativeTo: .attachment0,
                           turned: simd_quatf(angle: .pi / 2, axis: Vec3(0, 0, 1))).0.position
        check("RelativeTo Attachment0: along the attachment's axes as the part is turned", sideways.x < -20,
              "\(sideways)")
        let (_, spin) = run(Vec3(heavy, 0, 0), atCentre: false, attachmentAt: Vec3(0, 21, 0))
        let (_, still) = run(Vec3(heavy, 0, 0), atCentre: true, attachmentAt: Vec3(0, 21, 0))
        check("off the middle it turns the block, unless ApplyAtCenterOfMass", simd_length(spin) > 1 && simd_length(still) < 0.1,
              "\(simd_length(spin)) \(simd_length(still))")
    }

    // MARK: - AlignPosition

    private static func testAlignPosition(_ check: Checker) {
        print("\nForces: AlignPosition")
        func run(seconds: Float, _ set: (inout SceneConstraint) -> Void = { _ in }, each: ((SceneModel) -> Void)? = nil)
            -> (SceneModel, [Float]) {
            let model = scene([block("Ground", Vec3(0, -0.5, 0), size: Vec3(200, 1, 200), anchored: true),
                               block("Box", Vec3(0, 1, 0)), block("Target", Vec3(20, 8, 0), size: Vec3(1, 1, 1), anchored: true)])
            model.update(id: part(model, "Target").id) { $0.canCollide = false }
            add(.alignPosition, model, on: "Box", to: "Target", set)
            var gaps: [Float] = []
            simulate(PhysicsWorld(), model, seconds: seconds) {
                each?(model)
                gaps.append(simd_distance(part(model, "Box").position, part(model, "Target").position))
            }
            return (model, gaps)
        }
        let (held, gaps) = run(seconds: 3)
        check("pulled to Attachment1, and held there against gravity", (gaps.last ?? 99) < 0.6
              && gaps.suffix(30).allSatisfy { $0 < 1 }, "\(gaps.last ?? -1)")
        let weak = run(seconds: 2) { $0.maxForce = 10 }.0
        check("…but not with too little MaxForce", part(weak, "Box").position.y < 2, "\(part(weak, "Box").position)")
        let (_, slow) = run(seconds: 1) { $0.maxVelocity = 4 }
        check("…no faster than MaxVelocity", (slow.first ?? 0) - (slow.last ?? 0) < 4.6 && (slow.first ?? 0) - (slow.last ?? 0) > 3,
              "\((slow.first ?? 0) - (slow.last ?? 0))")
        let (_, eager) = run(seconds: 0.25) { $0.rigidityEnabled = true }
        let (_, gentle) = run(seconds: 0.25) { $0.responsiveness = 5 }
        check("RigidityEnabled: there at once; Responsiveness 5: much slower", (eager.last ?? 99) < 0.5 && (gentle.last ?? 0) > 10,
              "\(eager.last ?? -1) \(gentle.last ?? -1)")
        let (one, _) = run(seconds: 3) {
            $0.alignMode = .oneAttachment
            $0.position = Vec3(-10, 6, 5)
        }
        check("OneAttachment: to Position instead", simd_distance(part(one, "Box").position, Vec3(-10, 6, 5)) < 0.6,
              "\(part(one, "Box").position)")
        // The target moving: it follows.
        let (following, _) = run(seconds: 3) { _ in } each: { model in
            model.update(id: part(model, "Target").id) { $0.position.z += 0.1 }
        }
        check("…and follows a target that moves", part(following, "Box").position.z > 12
              && simd_distance(part(following, "Box").position, part(following, "Target").position) < 3,
              "\(part(following, "Box").position) \(part(following, "Target").position)")
        _ = held
    }

    // MARK: - NoCollisionConstraint

    private static func testNoCollision(_ check: Checker) {
        print("\nForces: NoCollisionConstraint")
        func drop(_ constrained: Bool, enabled: Bool = true) -> Float {
            let model = scene([block("Ground", Vec3(0, -0.5, 0), size: Vec3(200, 1, 200), anchored: true),
                               block("Shelf", Vec3(0, 4, 0), size: Vec3(10, 1, 10), anchored: true),
                               block("Box", Vec3(0, 10, 0))])
            if constrained {
                var c = SceneConstraint(kind: .noCollision)
                c.part0 = part(model, "Box").id
                c.part1 = part(model, "Shelf").id
                c.enabled = enabled
                model.constraints = [c]
            }
            simulate(PhysicsWorld(), model, seconds: 2)
            return part(model, "Box").position.y
        }
        let rests = drop(false), through = drop(true), off = drop(true, enabled: false)
        check("a block falls through the shelf it mustn't collide with, onto the ground; without, it rests on it",
              abs(through - 1) < 0.2 && abs(rests - 5.5) < 0.2, "\(through) \(rests)")
        check("…and rests on it again when the constraint is off", abs(off - 5.5) < 0.2, "\(off)")
    }

    // MARK: - Studio

    private static func testStudio(_ check: Checker) {
        print("\nForces: in Studio")
        let model = SceneModel()
        let a = model.addPart(shape: .block, at: Vec3(0, 3, 0))
        let b = model.addPart(shape: .block, at: Vec3(10, 6, 0))
        let undo = model.undoCount
        let align = model.join(.alignPosition, a, b).flatMap(model.constraint(id:))
        let ends = align.map { c in
            [c.attachment0, c.attachment1].compactMap { $0.flatMap(model.attachment(id:)).flatMap(model.worldFrame(of:))?.position }
        } ?? []
        check("the Align Position tool: the first part pulled to the middle of the second",
              ends.count == 2 && simd_distance(ends[0], Vec3(0, 3, 0)) < 1e-3 && simd_distance(ends[1], Vec3(10, 6, 0)) < 1e-3)
        let apart = model.join(.noCollision, a, b).flatMap(model.constraint(id:))
        check("the No Collision tool: the two parts", apart?.part0 == a && apart?.part1 == b)
        let push = model.addVectorForce(to: a).flatMap(model.constraint(id:))
        check("Add VectorForce: upwards, as strong as the part's weight, a step each to undo",
              push.map { abs($0.force.y - weight(model.part(id: a)!)) < 1e-3 && $0.relativeTo == .world } == true
              && model.undoCount == undo + 3)
        check("join tools: Align Position and No Collision among them, VectorForce not",
              SceneConstraint.Kind.alignPosition.joinsTwoParts && SceneConstraint.Kind.noCollision.joinsTwoParts
              && !SceneConstraint.Kind.vectorForce.joinsTwoParts)
        if let id = align?.id { model.updateConstraint(id: id) { $0.maxVelocity = .infinity; $0.responsiveness = 50 } }
        let reopened = SceneModel()
        if let data = try? model.encodeScene() { try? reopened.loadScene(from: data) }
        check("saved and reopened (MaxVelocity's no-limit too)", reopened.constraints == model.constraints
              && reopened.constraints.first { $0.kind == .alignPosition }?.maxVelocity == .infinity)
        let hinge = (try? JSONEncoder().encode(SceneConstraint(kind: .hinge))).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check("…and a hinge saves as it always did", !hinge.contains("maxForce") && !hinge.contains("relativeTo"))
    }

    // MARK: - Scripts

    static let scriptSource = """
    local box, target = workspace.Box, workspace.Target
    local align = Instance.new("AlignPosition")
    align.Attachment0 = Instance.new("Attachment", box)
    align.Attachment1 = Instance.new("Attachment", target)
    align.MaxForce = 50000
    align.MaxVelocity = 30
    align.Responsiveness = 25
    align.Parent = box
    print("align", align.ClassName, align:IsA("Constraint"), align.Mode == Enum.PositionAlignmentMode.TwoAttachment,
    \talign.MaxForce, align.MaxVelocity, align.Responsiveness, align.RigidityEnabled, box:FindFirstChild("AlignPosition") == align)
    align.Mode = Enum.PositionAlignmentMode.OneAttachment
    align.Position = Vector3.new(5, 7, 0)
    print("one", align.Position.Y, align.Mode.Name)

    local push = Instance.new("VectorForce")
    push.Attachment0 = Instance.new("Attachment", workspace.Floater)
    push.Force = Vector3.new(0, 500, 0)
    push.RelativeTo = Enum.ActuatorRelativeTo.World
    push.ApplyAtCenterOfMass = true
    push.Parent = workspace.Floater
    print("push", push.Force.Y, push.RelativeTo.Name, push.ApplyAtCenterOfMass)

    local apart = Instance.new("NoCollisionConstraint")
    apart.Part0 = box
    apart.Part1 = workspace.Floater
    apart.Parent = box
    print("apart", apart.Part1 == workspace.Floater, apart.Active, apart:IsA("Constraint"))

    local ok1 = pcall(function() align.MaxForce = "lots" end)
    local ok2 = pcall(function() align.Mode = Enum.ActuatorRelativeTo.World end)
    local ok3 = pcall(function() push.Force = 5 end)
    local ok4 = pcall(function() apart.Force = Vector3.one end)
    local ok5 = pcall(function() align.MaxForce = -1 end)
    print("refused", ok1, ok2, ok3, ok4, ok5)
    align.MaxVelocity = math.huge
    print("huge", align.MaxVelocity == math.huge)
    """

    private static func testScripts(_ check: Checker) {
        print("\nForces: from scripts")
        let model = scene([block("Box", Vec3(0, 3, 0)), block("Target", Vec3(10, 6, 0), anchored: true),
                           block("Floater", Vec3(-10, 6, 0))])
        var script = ScriptObject.blank(language: .luau)
        script.source = scriptSource
        model.scripts = [script]
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        for _ in 0..<60 { session.step(dt: frame) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        func said(_ prefix: String) -> String {
            session.console.lines.last { $0.kind == .output && $0.text.hasPrefix(prefix) }?.text ?? "(nothing)"
        }
        check("Instance.new(\"AlignPosition\"): a Constraint, Mode, MaxForce, MaxVelocity, Responsiveness, found by name",
              said("align") == "align AlignPosition true true 50000 30 25 false true", said("align"))
        check("…OneAttachment to a Position", said("one") == "one 7 OneAttachment", said("one"))
        check("VectorForce: Force, RelativeTo, ApplyAtCenterOfMass", said("push") == "push 500 World true", said("push"))
        check("NoCollisionConstraint: Part0 and Part1", said("apart") == "apart true true true", said("apart"))
        check("…wrong values refused, and math.huge for no speed limit",
              said("refused") == "refused false false false false false" && said("huge") == "huge true",
              "\(said("refused")) \(said("huge"))")
        let box = part(model, "Box")
        check("…and the Box pulled to the Position", simd_distance(box.position, Vec3(5, 7, 0)) < 1.5, "\(box.position)")
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("no errors", errors.isEmpty, "\(errors)")
        session.stop()
    }

    // MARK: - Together

    private static func testTogether(_ check: Checker) {
        print("\nForces: a host and a joined player")
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            var base = Part()
            base.name = "Baseplate"
            base.position = Vec3(0, -0.5, 0)
            base.size = Vec3(200, 1, 200)
            var crate = Part()
            crate.name = "Crate"
            crate.position = Vec3(20, 1, 20)
            crate.size = Vec3(2, 2, 2)
            crate.anchored = false
            model.parts = [base, crate]
            var host = ScriptObject.blank(language: .luau)
            host.source = """
            local crate = workspace.Crate
            local align = Instance.new("AlignPosition")
            align.Attachment0 = Instance.new("Attachment", crate)
            align.Mode = Enum.PositionAlignmentMode.OneAttachment
            align.Position = Vector3.new(20, 10, 30)
            align.MaxForce = 100000
            align.Parent = crate
            """
            model.scripts += [host]
        }), let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 3)
        let seen = joining.model.parts.first { $0.name == "Crate" }?.position ?? .zero
        check("a host's AlignPosition lifts a crate to its Position, and the joined player sees it there",
              simd_distance(seen, Vec3(20, 10, 30)) < 1.5, "\(seen)")
        let errors = (hosting.player!.console.lines + sam.console.lines).filter { $0.kind == .error }.map(\.text)
        check("…with no errors on either", errors.isEmpty, "\(errors)")
        joining.leaveGame()
        hosting.leaveGame()
    }
}
