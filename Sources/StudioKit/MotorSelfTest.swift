import Foundation
import simd

/// Motor6D, AlignOrientation and Torque: a Motor6D swinging an arm on an anchored base to
/// its DesiredAngle, no faster than MaxVelocity, holding it there, turned by Transform,
/// pulling a part back to where C0 and C1 say, keeping two falling parts together, and
/// letting go when disabled; an AlignOrientation turning a block to face as another does,
/// as a CFrame says, slowly with little MaxTorque, no faster than MaxAngularVelocity, at
/// once with RigidityEnabled, and lining up only its axis with PrimaryAxisOnly; a Torque
/// spinning a block about the world's axis or its own, and Studio's turning a crate where
/// it rests; Studio's tools and saving; scripts; and a host's windmill turning in a joined
/// player's game.
enum MotorSelfTest {
    static func run(check: Checker) {
        testMotor6D(check)
        testAlignOrientation(check)
        testTorque(check)
        testStudio(check)
        testScripts(check)
        testReadme(check)
        testTogether(check)
    }

    // MARK: - The README

    private static func testReadme(_ check: Checker) {
        print("\nMotors: the README's example")
        guard let readme = try? String(contentsOfFile: "README.md", encoding: .utf8),
              let start = readme.range(of: "### Turning: Motor6D, AlignOrientation and Torque"),
              let block = readme[start.upperBound...].components(separatedBy: "```lua\n").dropFirst().first?
                .components(separatedBy: "```").first else {
            print("  (README.md not found from here; skipped)")
            return
        }
        var sail = self.block("Sail", Vec3(4, 10, 0), size: Vec3(6, 1, 0.5))
        sail.anchored = false
        let model = ForceSelfTest.scene([self.block("Ground", Vec3(0, -0.5, 0), size: Vec3(200, 1, 200), anchored: true),
                                         self.block("Hub", Vec3(0, 10, 0), anchored: true), sail,
                                         self.block("Vane", Vec3(10, 0.25, 0), size: Vec3(4, 0.5, 1))])
        var script = ScriptObject.blank(language: .luau)
        script.source = block
        model.scripts = [script]
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        for _ in 0..<(60 * 5) { session.step(dt: frame) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        // Three quarters round by now: the sail hanging below the hub, the vane turned to match.
        let turned = part(model, "Sail"), vane = part(model, "Vane")
        let goal = simd_quatf(angle: 3 * .pi / 2, axis: Vec3(0, 1, 0))
        check("as written: the sail turns a quarter at a time, and the vane with it",
              simd_distance(turned.position, Vec3(0, 6, 0)) < 0.3 && degrees(vane.orientation, goal) < 5 && errors.isEmpty,
              "\(turned.position) \(degrees(vane.orientation, goal)) \(errors)")
        session.stop()
    }

    private static let frame = ForceSelfTest.frame

    private static func block(_ name: String, _ position: Vec3, size: Vec3 = Vec3(2, 2, 2), anchored: Bool = false) -> Part {
        ForceSelfTest.block(name, position, size: size, anchored: anchored)
    }

    private static func part(_ model: SceneModel, _ name: String) -> Part { ForceSelfTest.part(model, name) }

    /// The angle between two orientations, in degrees.
    private static func degrees(_ a: simd_quatf, _ b: simd_quatf) -> Float {
        let d = min(abs(simd_dot(simd_normalize(a).vector, simd_normalize(b).vector)), 1)
        return 2 * acos(d) * 180 / .pi
    }

    // MARK: - Motor6D

    /// An anchored Base, and an Arm to its right held by a Motor6D turning about the
    /// Base's Z axis at its middle.
    private static func arm(_ set: (inout SceneConstraint) -> Void = { _ in }, armAt: Vec3 = Vec3(3, 5, 0),
                            baseAnchored: Bool = true) -> (SceneModel, UUID) {
        let base = block("Base", Vec3(0, 5, 0), anchored: baseAnchored)
        let arm = block("Arm", armAt, size: Vec3(4, 1, 1))
        let model = ForceSelfTest.scene([block("Ground", Vec3(0, -0.5, 0), size: Vec3(200, 1, 200), anchored: true), base, arm])
        var motor = SceneConstraint(kind: .motor6d)
        motor.part0 = base.id
        motor.part1 = arm.id
        motor.parentID = base.id
        // At rest, the Arm 3 to the right of the Base's middle, however it starts.
        motor.c1 = Pose(position: Vec3(-3, 0, 0), orientation: Pose.identity.orientation)
        set(&motor)
        model.constraints.append(motor)
        return (model, motor.id)
    }

    private static func testMotor6D(_ check: Checker) {
        print("\nMotors: Motor6D")
        let (model, id) = arm { $0.desiredAngle = .pi / 2; $0.maxVelocity = 0.1 }
        let world = PhysicsWorld()
        ForceSelfTest.simulate(world, model, seconds: 5 * frame)
        let early = world.jointValue(id) ?? -1
        ForceSelfTest.simulate(world, model, seconds: 2)
        let swung = part(model, "Arm")
        check("it turns towards DesiredAngle, MaxVelocity radians a frame at most", abs(early - 0.5) < 0.02, "\(early)")
        check("…and gets there, the Arm swung up about the Base's Z axis",
              abs((world.jointValue(id) ?? 0) - .pi / 2) < 1e-3 && simd_distance(swung.position, Vec3(0, 8, 0)) < 0.2
              && simd_dot(swung.orientation.act(Vec3(1, 0, 0)), Vec3(0, 1, 0)) > 0.99,
              "\(String(describing: world.jointValue(id))) \(swung.position)")
        ForceSelfTest.simulate(world, model, seconds: 1)
        check("…and holds it there against gravity", simd_distance(part(model, "Arm").position, Vec3(0, 8, 0)) < 0.2,
              "\(part(model, "Arm").position)")

        let (turned, _) = arm { $0.transform = Pose(position: .zero, orientation: simd_quatf(angle: .pi, axis: Vec3(0, 0, 1))) }
        ForceSelfTest.simulate(PhysicsWorld(), turned, seconds: 2)
        check("Transform turns it too", simd_distance(part(turned, "Arm").position, Vec3(-3, 5, 0)) < 0.2,
              "\(part(turned, "Arm").position)")

        let (pulled, _) = arm(armAt: Vec3(4, 7, 1))
        ForceSelfTest.simulate(PhysicsWorld(), pulled, seconds: 2)
        check("a part away from where C0 and C1 hold it is pulled there",
              simd_distance(part(pulled, "Arm").position, Vec3(3, 5, 0)) < 0.2, "\(part(pulled, "Arm").position)")

        let (falling, _) = arm(baseAnchored: false)
        ForceSelfTest.simulate(PhysicsWorld(), falling, seconds: 3)
        let base = part(falling, "Base"), fallen = part(falling, "Arm")
        check("two parts it holds fall together, and land together",
              base.position.y < 3 && abs(simd_distance(base.position, fallen.position) - 3) < 0.15,
              "\(base.position) \(fallen.position)")

        let (off, _) = arm { $0.enabled = false }
        ForceSelfTest.simulate(PhysicsWorld(), off, seconds: 2)
        check("disabled, it lets go", part(off, "Arm").position.y < 1, "\(part(off, "Arm").position)")
    }

    // MARK: - AlignOrientation

    /// A Box floating (no gravity) turned by an AlignOrientation towards an anchored
    /// Target turned `goal`, each attachment facing as its part does.
    private static func aligning(goal: simd_quatf, start: simd_quatf = Pose.identity.orientation,
                                 _ set: (inout SceneConstraint) -> Void = { _ in }) -> SceneModel {
        var box = block("Box", Vec3(0, 20, 0))
        box.orientation = start
        var target = block("Target", Vec3(10, 20, 0), anchored: true)
        target.orientation = goal
        let model = ForceSelfTest.scene([box, target])
        var align = SceneConstraint(kind: .alignOrientation)
        align.parentID = box.id
        align.attachment0 = model.addAttachment(on: box.id, world: box.position, axis: box.orientation.act(Vec3(1, 0, 0)))
        align.attachment1 = model.addAttachment(on: target.id, world: target.position, axis: goal.act(Vec3(1, 0, 0)))
        set(&align)
        model.constraints.append(align)
        return model
    }

    private static func floating() -> PhysicsWorld {
        let world = PhysicsWorld()
        world.gravity = 0
        world.groundPlane = false
        return world
    }

    private static func testAlignOrientation(_ check: Checker) {
        print("\nMotors: AlignOrientation")
        let quarter = simd_quatf(angle: .pi / 2, axis: Vec3(0, 1, 0))
        let model = aligning(goal: quarter)
        ForceSelfTest.simulate(floating(), model, seconds: 3)
        check("it turns a block to face as another does", degrees(part(model, "Box").orientation, quarter) < 3,
              "\(degrees(part(model, "Box").orientation, quarter))")
        check("…turning it, not moving it", simd_distance(part(model, "Box").position, Vec3(0, 20, 0)) < 0.05)

        let tilt = simd_quatf(angle: .pi / 4, axis: Vec3(1, 0, 0))
        let one = aligning(goal: quarter) { $0.alignMode = .oneAttachment; $0.cframe = Pose(position: .zero, orientation: tilt) }
        ForceSelfTest.simulate(floating(), one, seconds: 3)
        check("in OneAttachment mode, as its CFrame says", degrees(part(one, "Box").orientation, tilt) < 3,
              "\(degrees(part(one, "Box").orientation, tilt))")

        let weak = aligning(goal: quarter) { $0.maxTorque = 0.5 }
        ForceSelfTest.simulate(floating(), weak, seconds: 1)
        check("with little MaxTorque it turns slowly", degrees(part(weak, "Box").orientation, Pose.identity.orientation) < 15,
              "\(degrees(part(weak, "Box").orientation, Pose.identity.orientation))")

        let slow = aligning(goal: quarter) { $0.maxAngularVelocity = 0.5; $0.responsiveness = 200 }
        let world = floating()
        var fastest: Float = 0
        ForceSelfTest.simulate(world, slow, seconds: 1) {
            fastest = max(fastest, simd_length(world.motion(of: part(slow, "Box").id)?.angularVelocity ?? .zero))
        }
        check("…and no faster than MaxAngularVelocity", fastest > 0.3 && fastest < 0.56, "\(fastest)")

        let rigid = aligning(goal: quarter) { $0.rigidityEnabled = true }
        ForceSelfTest.simulate(floating(), rigid, seconds: 0.2)
        check("RigidityEnabled: there at once", degrees(part(rigid, "Box").orientation, quarter) < 3,
              "\(degrees(part(rigid, "Box").orientation, quarter))")

        // The Box starts rolled about its own X; only X is lined up with the goal's.
        let up = simd_quatf(angle: .pi / 2, axis: Vec3(0, 0, 1))
        let roll = simd_quatf(angle: .pi / 3, axis: Vec3(1, 0, 0))
        let primary = aligning(goal: up, start: roll) { $0.primaryAxisOnly = true }
        ForceSelfTest.simulate(floating(), primary, seconds: 3)
        let turnedBox = part(primary, "Box").orientation
        check("PrimaryAxisOnly lines up the Axis alone", simd_dot(turnedBox.act(Vec3(1, 0, 0)), Vec3(0, 1, 0)) > 0.998
              && degrees(turnedBox, up) > 20, "\(turnedBox.act(Vec3(1, 0, 0))) \(degrees(turnedBox, up))")
    }

    // MARK: - Torque

    private static func testTorque(_ check: Checker) {
        print("\nMotors: Torque")
        func spun(_ torque: Vec3, relativeTo: ForceFrame, turned: simd_quatf = Pose.identity.orientation) -> Vec3 {
            var box = block("Box", Vec3(0, 20, 0))
            box.orientation = turned
            let model = ForceSelfTest.scene([box])
            var twist = SceneConstraint(kind: .torque)
            twist.attachment0 = model.addAttachment(on: box.id, world: box.position, axis: turned.act(Vec3(1, 0, 0)))
            twist.torque = torque
            twist.relativeTo = relativeTo
            model.constraints.append(twist)
            let world = floating()
            ForceSelfTest.simulate(world, model, seconds: 1)
            return world.motion(of: box.id)?.angularVelocity ?? .zero
        }
        let world = spun(Vec3(0, 20, 0), relativeTo: .world)
        check("a Torque spins a block about its direction, faster and faster",
              world.y > 1 && abs(world.x) < 0.05 && abs(world.z) < 0.05, "\(world)")
        let twice = spun(Vec3(0, 40, 0), relativeTo: .world)
        check("…twice as hard, twice as fast", abs(twice.y / world.y - 2) < 0.05, "\(twice.y) \(world.y)")
        let own = spun(Vec3(0, 20, 0), relativeTo: .attachment0, turned: simd_quatf(angle: .pi / 2, axis: Vec3(0, 0, 1)))
        check("RelativeTo Attachment0: about the attachment's own axis", own.x < -1 && abs(own.y) < 0.05, "\(own)")

        // Studio's: a crate on the ground turned where it rests.
        let crate = block("Crate", Vec3(0, 1, 0))
        let model = ForceSelfTest.scene([block("Ground", Vec3(0, -0.5, 0), size: Vec3(200, 1, 200), anchored: true), crate])
        model.addTorque(to: crate.id)
        let resting = PhysicsWorld()
        ForceSelfTest.simulate(resting, model, seconds: 1)
        // A constant twist past what friction holds: it spins up (so its angle wraps; its spin is what's checked).
        let spin = resting.motion(of: crate.id)?.angularVelocity ?? .zero
        check("Studio's Add Torque turns a crate where it rests", spin.y > 3 && abs(spin.x) < 0.5 && abs(spin.z) < 0.5
              && simd_distance(part(model, "Crate").position, crate.position) < 1, "\(spin)")
    }

    // MARK: - Studio

    private static func testStudio(_ check: Checker) {
        print("\nMotors: Studio")
        let a = block("A", Vec3(0, 3, 0), anchored: true)
        var b = block("B", Vec3(4, 3, 1))
        b.orientation = simd_quatf(angle: 0.4, axis: Vec3(0, 1, 0))
        let model = ForceSelfTest.scene([a, b])
        let motorID = model.join(.motor6d, a.id, b.id)
        let motor = motorID.flatMap(model.constraint(id:))
        check("the Motor6D tool holds the second part where it is, turning about its middle",
              motor?.part0 == a.id && motor?.part1 == b.id && motor.map { a.pose.applying($0.c0) == b.pose } == true
              && motor?.maxVelocity == 0.1)
        ForceSelfTest.simulate(PhysicsWorld(), model, seconds: 1)
        check("…so playing it, nothing jumps", simd_distance(part(model, "B").position, b.position) < 0.05
              && degrees(part(model, "B").orientation, b.orientation) < 1, "\(part(model, "B").position)")
        let alignID = model.join(.alignOrientation, b.id, a.id)
        let align = alignID.flatMap(model.constraint(id:))
        let facing = align?.attachment0.flatMap(model.attachment(id:))
        check("the Align Orientation tool faces each attachment as its part does",
              facing.map { simd_distance($0.axis, Vec3(1, 0, 0)) < 1e-4 } == true && align?.alignMode == .twoAttachment)
        let twistID = model.addTorque(to: b.id)
        check("Add Torque puts one on the part, about the world's up", twistID.flatMap(model.constraint(id:)).map {
            $0.relativeTo == .world && $0.torque.y > 0 && $0.torque.x == 0 } == true)
        check("Torque goes on one part; the others are join tools",
              !SceneConstraint.Kind.torque.joinsTwoParts && SceneConstraint.Kind.motor6d.joinsTwoParts
              && SceneConstraint.Kind.alignOrientation.joinsTwoParts && !SceneConstraint.Kind.motor6d.usesAttachments)
        if let alignID { model.updateConstraint(id: alignID) { $0.maxAngularVelocity = .infinity; $0.primaryAxisOnly = true } }
        if let motorID {
            model.updateConstraint(id: motorID) {
                $0.transform = Pose(position: Vec3(0, 1, 0), orientation: simd_quatf(angle: 0.3, axis: Vec3(1, 0, 0)))
                $0.desiredAngle = 2
            }
        }
        let reopened = SceneModel()
        if let data = try? model.encodeScene() { try? reopened.loadScene(from: data) }
        func close(_ x: [SceneConstraint], _ y: [SceneConstraint]) -> Bool {
            // Poses come back from twelve numbers, a hair different.
            x.count == y.count && zip(x, y).allSatisfy { a, b in
                a.kind == b.kind && a.id == b.id && a.desiredAngle == b.desiredAngle && a.torque == b.torque
                    && a.primaryAxisOnly == b.primaryAxisOnly && a.maxAngularVelocity == b.maxAngularVelocity
                    && simd_distance(a.c0.position, b.c0.position) < 1e-4 && degrees(a.c0.orientation, b.c0.orientation) < 0.01
                    && simd_distance(a.transform.position, b.transform.position) < 1e-4
                    && degrees(a.transform.orientation, b.transform.orientation) < 0.01
            }
        }
        check("saved and reopened (C0, Transform, MaxAngularVelocity's no-limit)", close(reopened.constraints, model.constraints),
              "\(reopened.constraints.map(\.kind))")
        let weld = (try? JSONEncoder().encode(SceneConstraint(kind: .weld))).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check("…and a weld saves as it always did", !weld.contains("c0") && !weld.contains("torque") && !weld.contains("maxTorque"))
    }

    // MARK: - Scripts

    static let scriptSource = """
    local base, arm = workspace.Base, workspace.Arm
    local motor = Instance.new("Motor6D")
    motor.Part0 = base
    motor.Part1 = arm
    motor.C1 = CFrame.new(-3, 0, 0)
    motor.MaxVelocity = 0.0625
    motor.DesiredAngle = 3
    motor.Parent = base
    print("motor", motor.ClassName, motor:IsA("JointInstance"), motor:IsA("Constraint"), motor.C1.X,
    \tmotor.MaxVelocity, motor.DesiredAngle, motor.Transform == CFrame.new(), base:FindFirstChild("Motor6D") == motor)

    local box = workspace.Box
    local align = Instance.new("AlignOrientation")
    align.Attachment0 = Instance.new("Attachment", box)
    align.Mode = Enum.OrientationAlignmentMode.OneAttachment
    align.CFrame = CFrame.Angles(0, math.pi / 2, 0)
    align.MaxTorque = 1e6
    align.Responsiveness = 50
    align.Parent = box
    print("align", align.ClassName, align:IsA("Constraint"), align.Mode.Name, math.round(align.CFrame.LookVector.X),
    \talign.MaxTorque, align.PrimaryAxisOnly, align.MaxAngularVelocity == math.huge)

    local spinner = workspace.Spinner
    local twist = Instance.new("Torque")
    twist.Attachment0 = Instance.new("Attachment", spinner)
    twist.Torque = Vector3.new(0, 800, 0)
    twist.RelativeTo = Enum.ActuatorRelativeTo.World
    twist.Parent = spinner
    print("twist", twist.ClassName, twist.Torque.Y, twist.RelativeTo.Name)

    local ok1 = pcall(function() motor.C0 = Vector3.one end)
    local ok2 = pcall(function() align.Mode = Enum.PositionAlignmentMode.OneAttachment end)
    local ok3 = pcall(function() twist.Torque = 5 end)
    local ok4 = pcall(function() align.MaxTorque = -1 end)
    print("refused", ok1, ok2, ok3, ok4)
    task.wait(0.5)
    print("turning", motor.CurrentAngle > 1, motor.CurrentAngle < 3)
    task.wait(1)
    print("turned", math.abs(motor.CurrentAngle - 3) < 1e-3, math.abs(spinner.AssemblyAngularVelocity.Y) > 1)
    motor.CurrentAngle = 0
    motor.DesiredAngle = 0
    task.wait(0.1)
    print("reset", motor.CurrentAngle)
    """

    private static func testScripts(_ check: Checker) {
        print("\nMotors: from scripts")
        let model = ForceSelfTest.scene([block("Ground", Vec3(0, -0.5, 0), size: Vec3(200, 1, 200), anchored: true),
                                         block("Base", Vec3(0, 5, 0), anchored: true),
                                         block("Arm", Vec3(3, 5, 0), size: Vec3(4, 1, 1)),
                                         block("Box", Vec3(10, 1, 0)), block("Spinner", Vec3(-10, 1, 0))])
        var script = ScriptObject.blank(language: .luau)
        script.source = scriptSource
        model.scripts = [script]
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        for _ in 0..<(60 * 2) { session.step(dt: frame) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        func said(_ prefix: String) -> String {
            session.console.lines.last { $0.kind == .output && $0.text.hasPrefix(prefix) }?.text ?? "(nothing)"
        }
        check("Instance.new(\"Motor6D\"): a JointInstance, not a Constraint; C1, MaxVelocity, DesiredAngle, Transform",
              said("motor") == "motor Motor6D true false -3 0.0625 3 true true", said("motor"))
        check("AlignOrientation: OneAttachment to a CFrame, MaxTorque, PrimaryAxisOnly, MaxAngularVelocity",
              said("align") == "align AlignOrientation true OneAttachment -1 1000000 false true", said("align"))
        check("Torque: Torque and RelativeTo", said("twist") == "twist Torque 800 World", said("twist"))
        check("…wrong values refused", said("refused") == "refused false false false false", said("refused"))
        check("CurrentAngle follows the physics as it turns", said("turning") == "turning true true"
              && said("turned") == "turned true true", "\(said("turning")) \(said("turned"))")
        check("…and a script can set it", said("reset") == "reset 0", said("reset"))
        let box = part(model, "Box"), spinner = part(model, "Spinner")
        check("…and the Box turned to its CFrame (the Spinner spinning, above)",
              simd_dot(box.orientation.act(Vec3(0, 0, -1)), Vec3(-1, 0, 0)) > 0.99 && abs(spinner.position.y - 1) < 0.5,
              "\(box.orientation.act(Vec3(0, 0, -1))) \(spinner.position)")
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("no errors", errors.isEmpty, "\(errors)")
        session.stop()
    }

    // MARK: - Together

    private static func testTogether(_ check: Checker) {
        print("\nMotors: a host and a joined player")
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            var base = Part()
            base.name = "Baseplate"
            base.position = Vec3(0, -0.5, 0)
            base.size = Vec3(200, 1, 200)
            var hub = Part()
            hub.name = "Hub"
            hub.position = Vec3(30, 10, 30)
            hub.size = Vec3(2, 2, 2)
            var sail = Part()
            sail.name = "Sail"
            sail.position = Vec3(34, 10, 30)
            sail.size = Vec3(6, 1, 0.5)
            sail.anchored = false
            model.parts = [base, hub, sail]
            var host = ScriptObject.blank(language: .luau)
            host.source = """
            local turn = Instance.new("Motor6D")
            turn.Part0 = workspace.Hub
            turn.Part1 = workspace.Sail
            turn.C1 = CFrame.new(-4, 0, 0)
            turn.MaxVelocity = 0.05
            turn.DesiredAngle = math.pi / 2
            turn.Parent = workspace.Hub
            """
            model.scripts += [host]
        }), let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 3)
        let seen = joining.model.parts.first { $0.name == "Sail" }
        check("a host's Motor6D turns a windmill's sail, and the joined player sees it turned",
              seen.map { simd_distance($0.position, Vec3(30, 14, 30)) < 0.3
                  && simd_dot($0.orientation.act(Vec3(1, 0, 0)), Vec3(0, 1, 0)) > 0.99 } == true,
              "\(String(describing: seen?.position))")
        let errors = (hosting.player!.console.lines + sam.console.lines).filter { $0.kind == .error }.map(\.text)
        check("…with no errors on either", errors.isEmpty, "\(errors)")
        joining.leaveGame()
        hosting.leaveGame()
    }
}
