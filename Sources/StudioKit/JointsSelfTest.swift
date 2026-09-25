import Foundation
import simd

/// Verification for welds, joints and squashed shapes: assemblies that hold together,
/// hinges that turn about their axis and stop at their limits, motors and servos,
/// ball sockets, ropes, springs and sliders — and the editor commands and saving.
enum JointsSelfTest {

    static func run(check: Checker) {
        testSquashedShapes(check)
        testWelds(check)
        testHinges(check)
        testOtherJoints(check)
        testEditing(check)
        testJoinTool(check)
        testScripting(check)
        testReadmeExample(check)
    }

    /// The README's joints example, verbatim, in a scene with those names.
    private static func testReadmeExample(_ check: Checker) {
        let model = scene([
            named(block(Vec3(0, 4, 0), size: Vec3(6, 1, 4)), "Body"),
            named(block(Vec3(2, 2.5, 2.5), size: Vec3(3, 1, 3), shape: .cylinder), "Wheel"),
            named(block(Vec3(30, 5, 0), size: Vec3(1, 8, 1), anchored: true), "Post"),
            named(block(Vec3(33, 5, 0), size: Vec3(4, 7, 0.4)), "Door"),
        ])
        // A Car model holding the body and wheel; the door is a part of its own.
        let car = SceneGroup(name: "Car", kind: .model)
        model.groups = [car]
        for name in ["Body", "Wheel"] { model.setParent(part(model, name).id, car.id) }
        let doorPart = part(model, "Door")
        let wheelHinge = model.join(.hinge, part(model, "Body").id, part(model, "Wheel").id)!
        model.updateConstraint(id: wheelHinge) { $0.name = "HingeConstraint"; $0.parentID = part(model, "Wheel").id }
        let doorHinge = model.join(.hinge, part(model, "Post").id, doorPart.id)!
        model.updateConstraint(id: doorHinge) { $0.name = "HingeConstraint"; $0.parentID = doorPart.id }

        var script = ScriptObject.blank(language: .luau)
        script.source = """
            -- A powered wheel
            local hinge = workspace.Car.Wheel.HingeConstraint
            hinge.ActuatorType = Enum.ActuatorType.Motor
            hinge.AngularVelocity = 12          -- radians a second
            hinge.MotorMaxTorque = 500000
            print(hinge.CurrentAngle)

            -- A door that swings shut
            local door = workspace.Door.HingeConstraint
            door.ActuatorType = Enum.ActuatorType.Servo
            door.TargetAngle = 0
            door.AngularSpeed = 2
            """
        model.scripts = [script]
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        var elapsed: Float = 0
        while elapsed < 1 {
            session.step(dt: 1.0 / 60)
            elapsed += 1.0 / 60
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        let spin = simd_length(session.physics.body(for: part(model, "Wheel").id)?.angularVelocity ?? .zero)
        check("the README joints example runs", errors.isEmpty && spin > 4, "\(errors) spin \(spin)")
        session.stop()
    }

    // MARK: - Scripts

    private static func testScripting(_ check: Checker) {
        print("\nJoints: scripts")
        let model = scene([
            named(block(Vec3(0, 6, 0), size: Vec3(2, 1, 2), anchored: true), "Axle"),
            named(block(Vec3(0, 4, 0), size: Vec3(1, 4, 1)), "Arm"),
            named(block(Vec3(0, 1.5, 0), size: Vec3(3, 1, 3)), "Base"),
            named(block(Vec3(0, 2.5, 0), size: Vec3(1, 1, 1)), "Cap"),
        ])
        var script = ScriptObject.blank(language: .luau)
        script.source = """
            local axle, arm = workspace.Axle, workspace.Arm
            local base, cap = workspace.Base, workspace.Cap

            -- A weld: the cap rides on the base.
            local weld = Instance.new("WeldConstraint")
            weld.Part0 = base
            weld.Part1 = cap
            weld.Parent = base
            print(weld.ClassName, weld:IsA("WeldConstraint"), weld.Part1.Name, weld.Active, weld.Parent.Name)

            -- A hinge, with an attachment on each part.
            local a0 = Instance.new("Attachment", axle)
            a0.Position = Vector3.new(0, -0.5, 0)
            a0.Axis = Vector3.new(0, 0, 1)
            local a1 = Instance.new("Attachment", arm)
            a1.Position = Vector3.new(0, 2, 0)
            a1.Axis = Vector3.new(0, 0, 1)
            local hinge = Instance.new("HingeConstraint", axle)
            hinge.Attachment0 = a0
            hinge.Attachment1 = a1
            print(a0.ClassName, a0.Parent.Name, tostring(a0.WorldPosition), #axle:GetChildren())
            print(hinge:IsA("Constraint"), hinge.Attachment1 == a1, hinge.Active, hinge.ActuatorType == Enum.ActuatorType.None)
            print(pcall(function() hinge.Attachment0 = 7 end))
            print(pcall(function() hinge.CurrentAngle = 1 end))
            print(pcall(function() hinge.Length = 3 end))

            hinge.ActuatorType = Enum.ActuatorType.Motor
            hinge.AngularVelocity = 4
            hinge.MotorMaxTorque = 1e6
            task.wait(1)
            print("spun", math.abs(hinge.CurrentAngle) > 30, math.abs(arm.AssemblyAngularVelocity.Z) > 2)
            hinge.ActuatorType = Enum.ActuatorType.None
            print("welded", (cap.Position - base.Position).Magnitude)
            weld.Enabled = false
            task.wait(0.6)
            print("unwelded", cap.Position.Y < base.Position.Y + 0.9)
            """
        model.scripts = [script]
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        var elapsed: Float = 0
        while elapsed < 2.2 {
            session.step(dt: 1.0 / 60)
            elapsed += 1.0 / 60
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let out = session.console.lines.filter { $0.kind == .output }.map(\.text)
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        func line(_ i: Int) -> String { i < out.count ? out[i] : "(missing)" }
        check("a script can weld two parts", line(0) == "WeldConstraint true Cap true Base", "\(out) \(errors)")
        check("attachments are made on parts and read in world space",
              line(1) == "Attachment Axle 0, 5.5, 0 2", line(1))
        check("a hinge reads like Roblox's", line(2) == "true true true true", line(2))
        check("its properties are type-checked", line(3).contains("Attachment expected"), line(3))
        check("…read-only ones refuse writes", line(4).contains("read only"), line(4))
        check("…and a hinge has no Length", line(5).contains("not a valid member of HingeConstraint"), line(5))
        check("a motor set from a script turns the arm", line(6) == "spun true true", line(6))
        check("the welded cap keeps its place", line(7).hasPrefix("welded 1"), line(7))
        check("…and drops when the weld is disabled", line(8) == "unwelded true", line(8))
        check("no script errors", errors.isEmpty, "\(errors)")
        session.stop()
    }

    private static func near(_ a: Float, _ b: Float, _ tolerance: Float) -> Bool { abs(a - b) <= tolerance }
    private static func block(_ position: Vec3, size: Vec3 = Vec3(2, 2, 2), anchored: Bool = false,
                              shape: PartShape = .block) -> Part {
        PhysicsSelfTest.block(position, size: size, anchored: anchored, shape: shape)
    }

    /// A scene to build in, with the default ground.
    private static func scene(_ parts: [Part]) -> SceneModel {
        let model = SceneModel()
        model.parts = parts
        model.scripts = []
        model.groups = []
        model.attachments = []
        model.constraints = []
        return model
    }

    /// Runs physics over a model, as the game does, calling `each` every frame.
    private static func simulate(_ world: PhysicsWorld, _ model: SceneModel, seconds: Float,
                                 each: (() -> Void)? = nil) {
        var elapsed: Float = 0
        while elapsed < seconds - 1e-4 {
            world.sync(model.parts, constraints: model.constraints, attachments: model.attachments)
            let result = world.step(dt: 1.0 / 60)
            var parts = model.parts
            let index = Dictionary(uniqueKeysWithValues: parts.enumerated().map { ($1.id, $0) })
            for (id, pose) in result.moved { if let i = index[id] { parts[i].pose = pose } }
            model.parts = parts
            elapsed += 1.0 / 60
            each?()
        }
    }

    private static func part(_ model: SceneModel, _ name: String) -> Part { model.parts.first { $0.name == name }! }

    private static func named(_ part: Part, _ name: String) -> Part {
        var copy = part
        copy.name = name
        return copy
    }

    // MARK: - Squashed shapes

    private static func testSquashedShapes(_ check: Checker) {
        print("\nJoints: squashed shapes")
        // A long egg lying on the ground, and a box slid along the ground into its tip.
        // The egg reaches 3 studs out; a sphere of its smallest radius would reach 1.
        let egg = named(block(Vec3(0, 1, 0), size: Vec3(6, 2, 2), anchored: true, shape: .sphere), "Egg")
        let box = named(block(Vec3(7, 0.5, 0), size: Vec3(1, 1, 1)), "Box")
        let model = scene([egg, box])
        let world = PhysicsWorld()
        simulate(world, model, seconds: 0.3)
        world.setVelocity(box.id, Vec3(-40, 0, 0))
        simulate(world, model, seconds: 1)
        let stopped = part(model, "Box").position.x
        check("a squashed sphere collides as the egg it looks like", stopped > 2.8, "box stopped at x = \(stopped)")

        // A flat, wide disc (an elliptical cylinder) carries a box near its long edge.
        let disc = named(block(Vec3(0, 0.5, 20), size: Vec3(8, 1, 2), anchored: true, shape: .cylinder), "Disc")
        let crate = named(block(Vec3(3.2, 4, 20), size: Vec3(1, 1, 1)), "Crate")
        let discModel = scene([disc, crate])
        simulate(PhysicsWorld(), discModel, seconds: 1)
        check("a squashed cylinder does too", near(part(discModel, "Crate").position.y, 1.5, 0.1),
              "\(part(discModel, "Crate").position.y)")

        let hull = PhysicsWorld.shape(of: egg)
        let round = PhysicsWorld.shape(of: block(.zero, shape: .sphere))
        check("round shapes stay exact; squashed ones become hulls",
              round.points.isEmpty && hull.points.count > 100 * 3)
    }

    // MARK: - Welds

    private static func testWelds(_ check: Checker) {
        print("\nJoints: welds")
        // An L-shape: a tall post welded onto a wide foot. Alone the post would topple;
        // welded, the pair stands.
        let foot = named(block(Vec3(0, 0.5, 0), size: Vec3(6, 1, 6)), "Foot")
        let post = named(block(Vec3(0, 5, 0), size: Vec3(1, 8, 1)), "Post")
        let model = scene([foot, post])
        model.selection = [foot.id, post.id]
        model.weldSelection()
        let world = PhysicsWorld()
        world.sync(model.parts, constraints: model.constraints, attachments: model.attachments)
        check("welded parts become one assembly", world.bodies.count == 1 && world.assemblyParts(of: post.id).count == 2)
        let offset = part(model, "Post").position - part(model, "Foot").position
        world.applyImpulse(post.id, Vec3(0, 0, 300))
        simulate(world, model, seconds: 2)
        let after = part(model, "Post").pose, footAfter = part(model, "Foot").pose
        let kept = footAfter.inverse.applying(after).position
        check("…holding their offset exactly as they move", simd_distance(kept, offset) < 0.01, "\(kept) vs \(offset)")
        check("…moving as one", simd_length(world.body(for: post.id)!.velocity - world.body(for: foot.id)!.velocity) < 0.01)
        check("an assembly's mass is the sum of its parts'",
              near(world.body(for: post.id)!.assemblyMass,
                   PhysicsWorld.massProperties(of: foot).mass + PhysicsWorld.massProperties(of: post).mass, 0.01))

        // Welded to something anchored, an unanchored part stays up.
        let shelf = named(block(Vec3(20, 6, 0), size: Vec3(4, 1, 4), anchored: true), "Shelf")
        let lamp = named(block(Vec3(20, 4.5, 0), size: Vec3(1, 2, 1)), "Lamp")      // hanging underneath
        let held = scene([shelf, lamp])
        var weld = SceneConstraint(kind: .weld)
        weld.part0 = shelf.id
        weld.part1 = lamp.id
        held.constraints = [weld]
        let heldWorld = PhysicsWorld()
        simulate(heldWorld, held, seconds: 1)
        check("a part welded to an anchored part doesn't fall", near(part(held, "Lamp").position.y, 4.5, 0.001))
        held.constraints[0].enabled = false
        simulate(heldWorld, held, seconds: 1.5)
        check("disabling the weld lets it go", part(held, "Lamp").position.y < 1.5, "\(part(held, "Lamp").position.y)")
    }

    // MARK: - Hinges

    private static func testHinges(_ check: Checker) {
        print("\nJoints: hinges")
        // A door: an anchored post, a door hinged to it about the vertical.
        let post = named(block(Vec3(0, 4, 0), size: Vec3(1, 8, 1), anchored: true), "Post")
        let door = named(block(Vec3(3, 4, 0), size: Vec3(4, 7, 0.4)), "Door")
        let model = scene([post, door])
        guard let hinge = model.join(.hinge, post.id, door.id) else {
            check("a hinge can be made", false)
            return
        }
        // Put the hinge on the door's edge, turning about Y.
        for attachment in [model.constraint(id: hinge)!.attachment0!, model.constraint(id: hinge)!.attachment1!] {
            model.updateAttachment(id: attachment) { a in
                let owner = model.part(id: a.parentID)!
                a.position = owner.orientation.inverse.act(Vec3(0.5, 4, 0) - owner.position)
                a.setAxis(Vec3(0, 1, 0))
            }
        }
        let world = PhysicsWorld()
        world.sync(model.parts, constraints: model.constraints, attachments: model.attachments)
        check("the hinge is a joint in the physics", world.jointCount == 1)
        world.applyImpulse(door.id, Vec3(0, 0, 400))
        var worstDrift: Float = 0
        simulate(world, model, seconds: 1) {
            let d = part(model, "Door")
            let hingePoint = d.position + d.orientation.act(Vec3(-2.5, 0, 0))
            worstDrift = max(worstDrift, simd_distance(Vec3(hingePoint.x, 0, hingePoint.z), Vec3(0.5, 0, 0)))
        }
        let swung = part(model, "Door")
        let angle = abs(atan2(swung.orientation.act(Vec3(1, 0, 0)).z, swung.orientation.act(Vec3(1, 0, 0)).x))
        check("a pushed door swings", angle > 0.3, "\(angle) rad")
        check("…about its hinge, which stays put", worstDrift < 0.1, "drift \(worstDrift)")
        check("…and stays upright", near(swung.position.y, 4, 0.05), "\(swung.position.y)")

        // Limits: the same door stops at 30°.
        model.updateConstraint(id: hinge) { $0.limitsEnabled = true; $0.lowerAngle = -30; $0.upperAngle = 30 }
        model.parts = [post, door]
        let limited = PhysicsWorld()
        limited.sync(model.parts, constraints: model.constraints, attachments: model.attachments)
        limited.applyImpulse(door.id, Vec3(0, 0, 800))
        var widest: Float = 0
        simulate(limited, model, seconds: 1.5) {
            let x = part(model, "Door").orientation.act(Vec3(1, 0, 0))
            widest = max(widest, abs(atan2(x.z, x.x)))
        }
        check("limits stop it at UpperAngle", widest < 32 * .pi / 180 && widest > 20 * .pi / 180,
              "widest \(widest * 180 / .pi)°")

        // A motor: a wheel on an anchored axle spins at AngularVelocity.
        let axle = named(block(Vec3(30, 5, 0), size: Vec3(1, 1, 1), anchored: true), "Axle")
        var wheel = named(block(Vec3(30, 5, 2), size: Vec3(4, 1, 4), shape: .cylinder), "Wheel")
        wheel.rotationDegrees = Vec3(90, 0, 0)       // stand it up: its axis along Z
        let motorModel = scene([axle, wheel])
        let motor = motorModel.join(.hinge, axle.id, wheel.id)!
        motorModel.updateConstraint(id: motor) { $0.actuator = .motor; $0.angularVelocity = 5 }
        let spinning = PhysicsWorld()
        spinning.groundPlane = false
        simulate(spinning, motorModel, seconds: 1)
        let spin = simd_length(spinning.body(for: wheel.id)!.angularVelocity)
        check("a motor turns the hinge at AngularVelocity", near(spin, 5, 0.3), "\(spin) rad/s")

        // A servo: turns to TargetAngle and holds.
        motorModel.updateConstraint(id: motor) { $0.actuator = .servo; $0.targetAngle = 90; $0.angularSpeed = 3 }
        simulate(spinning, motorModel, seconds: 0.5)
        motorModel.updateConstraint(id: motor) { $0.angularVelocity = 0 }
        let servo = PhysicsWorld()
        servo.groundPlane = false
        let fresh = scene([axle, wheel])
        fresh.attachments = motorModel.attachments
        fresh.constraints = motorModel.constraints
        simulate(servo, fresh, seconds: 2)
        let reached = (servo.jointValue(motor) ?? 0) * 180 / .pi
        check("a servo turns to TargetAngle", near(abs(reached), 90, 3), "\(reached)°")
    }

    // MARK: - Ball sockets, ropes, springs, sliders

    private static func testOtherJoints(_ check: Checker) {
        print("\nJoints: ball sockets, ropes, springs, sliders")
        // A pendulum on a ball socket: swings, but the bob stays the same distance away.
        let pivot = named(block(Vec3(0, 20, 0), size: Vec3(1, 1, 1), anchored: true), "Pivot")
        let bob = named(block(Vec3(6, 20, 0), size: Vec3(1, 1, 1), shape: .sphere), "Bob")
        let pendulum = scene([pivot, bob])
        let socket = pendulum.join(.ballSocket, pivot.id, bob.id)!
        // The socket at the pivot, not halfway.
        for attachment in [pendulum.constraint(id: socket)!.attachment0!, pendulum.constraint(id: socket)!.attachment1!] {
            pendulum.updateAttachment(id: attachment) { a in
                let owner = pendulum.part(id: a.parentID)!
                a.position = owner.orientation.inverse.act(Vec3(0, 20, 0) - owner.position)
            }
        }
        var lowest: Float = 99, spread: Float = 0
        simulate(PhysicsWorld(), pendulum, seconds: 1.2) {
            let p = part(pendulum, "Bob").position
            lowest = min(lowest, p.y)
            spread = max(spread, abs(simd_distance(p, Vec3(0, 20, 0)) - 6))
        }
        check("a ball socket swings like a pendulum", lowest < 15, "lowest \(lowest)")
        check("…keeping its length", spread < 0.15, "length error \(spread)")

        // A rope: a ball dropped from beside an anchored block stops at the rope's length.
        let hook = named(block(Vec3(20, 20, 0), size: Vec3(1, 1, 1), anchored: true), "Hook")
        let weight = named(block(Vec3(20, 17, 0), size: Vec3(1, 1, 1), shape: .sphere), "Weight")
        let roped = scene([hook, weight])
        let rope = roped.join(.rope, hook.id, weight.id)!
        roped.updateConstraint(id: rope) { $0.length = 6 }
        var farthest: Float = 0
        simulate(PhysicsWorld(), roped, seconds: 1.5) {
            farthest = max(farthest, simd_distance(part(roped, "Weight").position, Vec3(20, 20, 0)))
        }
        check("a rope stops a falling part at its length", near(farthest, 6, 0.25), "farthest \(farthest)")
        check("…where it hangs", near(part(roped, "Weight").position.y, 14, 0.3), "\(part(roped, "Weight").position.y)")

        // A spring: hangs below its free length by weight / stiffness.
        let ceiling = named(block(Vec3(40, 20, 0), size: Vec3(2, 1, 2), anchored: true), "Ceiling")
        let load = named(block(Vec3(40, 15, 0), size: Vec3(1, 1, 1)), "Load")
        let sprung = scene([ceiling, load])
        let spring = sprung.join(.spring, ceiling.id, load.id)!
        sprung.updateConstraint(id: spring) { $0.freeLength = 5; $0.stiffness = 400; $0.damping = 20 }
        let springWorld = PhysicsWorld()
        simulate(springWorld, sprung, seconds: 4)
        let mass = PhysicsWorld.massProperties(of: load).mass
        let expected = 20 - (5 + mass * CharacterController.gravity / 400)
        check("a spring settles where stiffness and weight balance",
              near(part(sprung, "Load").position.y, expected, 0.3), "\(part(sprung, "Load").position.y) vs \(expected)")

        // A slider: a motor drives it along its axis and nowhere else.
        let rail = named(block(Vec3(60, 3, 0), size: Vec3(1, 1, 1), anchored: true), "Rail")
        let carriage = named(block(Vec3(62, 3, 0), size: Vec3(1, 1, 1)), "Carriage")
        let slid = scene([rail, carriage])
        let slider = slid.join(.prismatic, rail.id, carriage.id)!
        slid.updateConstraint(id: slider) { $0.actuator = .motor; $0.velocity = 4 }
        let sliderWorld = PhysicsWorld()
        sliderWorld.groundPlane = false
        simulate(sliderWorld, slid, seconds: 1)
        let moved = part(slid, "Carriage").position
        check("a prismatic motor slides it along the axis", near(moved.x, 66, 0.4), "\(moved)")
        check("…and nowhere else", near(moved.y, 3, 0.02) && near(moved.z, 0, 0.02), "\(moved)")
    }


    // MARK: - The click-to-join tools

    /// Pick Weld, click two parts, they are welded — and the old way, where a whole
    /// selection welds at once, still works and can be turned off.
    private static func testJoinTool(_ check: Checker) {
        print("\nJoints: the click-to-join tools")
        // The setting is remembered between launches; leave it as we found it.
        let remembered = UserDefaults.standard.object(forKey: SceneModel.joinSelectionKey)
        defer {
            if let remembered {
                UserDefaults.standard.set(remembered, forKey: SceneModel.joinSelectionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: SceneModel.joinSelectionKey)
            }
        }

        let model = wall(of: 4)
        model.joinSelectionOnPick = true
        let bricks = model.parts.map(\.id)

        model.selection = []
        let armed = model.armJoinTool(.weld)
        check("picking a tool with nothing selected joins nothing yet",
              armed.isEmpty && model.constraints.isEmpty)
        check("…and leaves the tool armed", model.joinTool == .weld)

        model.pickJoinTarget(bricks[0])
        check("the first click holds a part", model.joinPending == bricks[0] && model.constraints.isEmpty)
        model.pickJoinTarget(bricks[1])
        check("the second click welds the two",
              model.constraints.count == 1 && model.weld(between: bricks[0], and: bricks[1]) != nil)
        check("…and lets go, still armed for the next pair",
              model.joinPending == nil && model.joinTool == .weld)
        model.pickJoinTarget(bricks[2])
        model.pickJoinTarget(bricks[3])
        check("so pair after pair welds without leaving the tool", model.constraints.count == 2)

        model.pickJoinTarget(bricks[0])
        model.pickJoinTarget(bricks[0])
        check("clicking the held part again lets go of it",
              model.joinPending == nil && model.constraints.count == 2)

        model.pickJoinTarget(bricks[1])
        model.pickJoinTarget(bricks[0])
        check("welding the same two parts again makes no second weld", model.constraints.count == 2)

        model.pickJoinTarget(bricks[0])
        model.cancelJoinTool()
        check("Escape puts the tool away", model.joinTool == nil && model.joinPending == nil)
        model.armJoinTool(.hinge)
        model.selectGizmo(.move)
        check("so does picking a transform tool", model.joinTool == nil && model.gizmoMode == .move)
        model.pickJoinTarget(bricks[0])
        check("with no tool armed, clicks join nothing", model.joinPending == nil)

        // A whole brick wall, welded by picking the tool with it selected.
        let bulkModel = wall(of: 4)
        bulkModel.joinSelectionOnPick = true
        bulkModel.selection = Set(bulkModel.parts.map(\.id))
        let bulk = bulkModel.armJoinTool(.weld)
        check("picking Weld with a wall selected welds the whole wall",
              bulk.count == 3 && bulkModel.constraints.count == 3)
        check("…which is one assembly", assemblySize(bulkModel) == 4, "\(assemblySize(bulkModel))")
        bulkModel.undo()
        check("…in a single undo step", bulkModel.constraints.isEmpty)

        bulkModel.joinSelectionOnPick = false
        bulkModel.selection = Set(bulkModel.parts.map(\.id))
        let none = bulkModel.armJoinTool(.weld)
        check("with the setting off, picking the tool only arms it",
              none.isEmpty && bulkModel.constraints.isEmpty && bulkModel.joinTool == .weld)
        let ids = bulkModel.parts.map(\.id)
        bulkModel.pickJoinTarget(ids[0])
        bulkModel.pickJoinTarget(ids[1])
        check("…and its two clicks still weld", bulkModel.constraints.count == 1)
        check("the Weld All button welds the selection whatever the setting says",
              bulkModel.weldSelection().count == 3)

        // The other tools work the same way.
        let jointModel = scene([named(block(Vec3(0, 1, 0)), "A"), named(block(Vec3(3, 1, 0)), "B")])
        jointModel.joinSelectionOnPick = true
        let a = part(jointModel, "A").id, b = part(jointModel, "B").id
        jointModel.armJoinTool(.hinge)
        jointModel.pickJoinTarget(a)
        let hinge = jointModel.pickJoinTarget(b)
        check("the same two clicks make a hinge, with an attachment on each part",
              hinge.flatMap { jointModel.constraint(id: $0) }?.kind == .hinge && jointModel.attachments.count == 2)

        jointModel.selection = [b]
        check("Unjoin frees the selected part",
              jointModel.unjoinSelection() == 1 && jointModel.constraints.isEmpty && jointModel.attachments.isEmpty)
        jointModel.undo()
        check("…in one undo step", jointModel.constraints.count == 1)

        jointModel.armJoinTool(.weld)
        jointModel.pickJoinTarget(a)
        jointModel.selection = [a]
        jointModel.deleteSelected()
        check("deleting the held part lets go of it", jointModel.joinPending == nil)

        // Clicks in the viewport, where the user actually does this. The two parts stand
        // well apart, so neither hides the other from the camera.
        let clickModel = scene([named(block(Vec3(0, 1, 0)), "Left"), named(block(Vec3(0, 1, -14)), "Right")])
        let first = clickModel.parts[0], second = clickModel.parts[1]
        let viewport = ViewportController(model: clickModel)
        viewport.viewSize = SIMD2<Float>(800, 600)
        let centre = SIMD2<Float>(400, 300)
        clickModel.joinSelectionOnPick = true
        clickModel.armJoinTool(.weld)

        viewport.camera.focus(on: first.position, radius: 2)
        let dragged = viewport.mouseDown(at: centre, additive: false)
        check("a viewport click holds the part under the pointer", clickModel.joinPending == first.id)
        check("…and starts no drag", !dragged)
        viewport.camera.focus(on: second.position, radius: 2)
        viewport.mouseDown(at: centre, additive: false)
        check("the next one welds them", clickModel.weld(between: first.id, and: second.id) != nil)
        check("and the tool never touches the selection", clickModel.selection.isEmpty)

        viewport.camera.focus(on: first.position, radius: 2)
        viewport.mouseDown(at: centre, additive: false)
        viewport.camera.focus(on: Vec3(0, 1, 400), radius: 2)
        viewport.mouseDown(at: centre, additive: false)
        check("a click on empty space lets go without leaving the tool",
              clickModel.joinPending == nil && clickModel.joinTool == .weld)
        check("no gizmo while a tool is armed", viewport.editorOverlay?.gizmoMode == .select)
        viewport.camera.focus(on: second.position, radius: 2)
        viewport.mouseDown(at: centre, additive: false)
        check("the held part is handed to the renderer to outline",
              viewport.editorOverlay?.joinPending == second.id)
        clickModel.cancelJoinTool()
        check("put away, the gizmo comes back", viewport.editorOverlay?.gizmoMode == clickModel.gizmoMode
              && viewport.editorOverlay?.joinPending == nil)
    }

    /// A row of bricks, side by side and touching.
    private static func wall(of count: Int) -> SceneModel {
        scene((0..<count).map { named(block(Vec3(Float($0) * 2, 1, 0)), "Brick\($0 + 1)") })
    }

    /// How many parts the largest welded assembly holds.
    private static func assemblySize(_ model: SceneModel) -> Int {
        let world = PhysicsWorld()
        world.sync(model.parts, constraints: model.constraints, attachments: model.attachments)
        return model.parts.map { world.assemblyParts(of: $0.id).count }.max() ?? 0
    }

    // MARK: - The editor

    private static func testEditing(_ check: Checker) {
        print("\nJoints: editing and saving")
        let a = named(block(Vec3(0, 1, 0)), "A"), b = named(block(Vec3(3, 1, 0)), "B")
        let model = scene([a, b])
        let hinge = model.join(.hinge, a.id, b.id)!
        check("joining makes the joint and an attachment on each part",
              model.constraints.count == 1 && model.attachments(on: a.id).count == 1 && model.attachments(on: b.id).count == 1)
        let frame = model.worldFrame(of: model.attachment(id: model.constraint(id: hinge)!.attachment0!)!)!
        check("…at the point between them", simd_distance(frame.position, Vec3(1.5, 1, 0)) < 1e-4)
        model.undo()
        check("joining undoes", model.constraints.isEmpty && model.attachments.isEmpty)

        model.selection = [a.id, b.id]
        model.weldSelection()
        let group = model.groupSelection(kind: .model)!
        model.selection = [group]
        model.duplicateSelected()
        check("duplicating a Model copies the welds inside it",
              model.constraints.count == 2 && Set(model.constraints.compactMap(\.part0)).count == 2)

        let data = try? JSONEncoder().encode(model.state)
        let back = data.flatMap { try? JSONDecoder().decode(SceneState.self, from: $0) }
        check("welds and joints are saved", back?.constraints == model.constraints && back?.attachments == model.attachments)

        model.selection = [a.id]
        model.deleteSelected()
        check("deleting a part removes its welds", model.constraints.count == 1)
        let old = try? JSONDecoder().decode(SceneState.self, from: Data(#"{"parts":[]}"#.utf8))
        check("older files open with none", old?.constraints.isEmpty == true && old?.attachments.isEmpty == true)
    }
}
