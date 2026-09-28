import Foundation
import simd

/// Ready-made models, built in code: Studio's Toolbox puts them in the world (and
/// Insert › Car the car). Each is built standing on y = 0 around its pivot at the origin,
/// facing −Z, as a `ModelFile` — so it goes in exactly as a saved creation does.
enum ToolboxModel: String, CaseIterable, Identifiable {
    case car = "Car"
    case boat = "Boat"
    case door = "Door"
    case windmill = "Windmill"
    case campfire = "Campfire"
    case streetLamp = "Street Lamp"
    case tree = "Tree"
    case rig = "Rig"

    var id: String { rawValue }

    /// What it is, in a line, for the Toolbox.
    var summary: String {
        switch self {
        case .car: return "Sit in it and drive: W, S, A, D"
        case .boat: return "Floats on water; drive it like the car"
        case .door: return "Click it to open, again to close"
        case .windmill: return "Its sails turn on a Motor6D"
        case .campfire: return "Fire, smoke and a warm light"
        case .streetLamp: return "Lights the way at night"
        case .tree: return "A trunk and leaves"
        case .rig: return "A character with a Humanoid"
        }
    }

    var symbolName: String {
        switch self {
        case .car: return "car.fill"
        case .boat: return "sailboat.fill"
        case .door: return "door.left.hand.open"
        case .windmill: return "wind"
        case .campfire: return "flame.fill"
        case .streetLamp: return "lamp.floor.fill"
        case .tree: return "tree.fill"
        case .rig: return "figure.stand"
        }
    }

    /// Built as a saved model is; nil for the Rig, which has a Humanoid (SceneModel.addRig).
    var file: ModelFile? {
        var builder = ToolboxBuilder()
        switch self {
        case .car: builder.car()
        case .boat: builder.boat()
        case .door: builder.door()
        case .windmill: builder.windmill()
        case .campfire: builder.campfire()
        case .streetLamp: builder.streetLamp()
        case .tree: builder.tree()
        case .rig: return nil
        }
        return ModelFile(name: rawValue, pivot: .zero, state: builder.state)
    }
}

private struct ToolboxBuilder: PlaceBuilding {
    var state = SceneState()
    var seed: UInt32 = 11

    func rgb(_ r: Float, _ g: Float, _ b: Float) -> Vec3 { Vec3(r, g, b) / 255 }

    // MARK: - The car

    /// A car to drive: a VehicleSeat on a body, back wheels on motor hinges, front
    /// wheels on free axles turned by servo hinges, and a script between the seat and
    /// the hinges (as a Roblox car is made).
    mutating func car() {
        let car = group("Car")
        let red = rgb(196, 40, 44), dark = rgb(34, 34, 38)
        let body = part("Body", Vec3(0, 2.2, 0), Vec3(6, 1, 10), red, in: car)
        let hood = part("Hood", Vec3(0, 3, -3.5), Vec3(5.6, 0.6, 3), rgb(170, 30, 36), in: car)
        let glass = part("Windshield", Vec3(0, 3.6, -1.9), Vec3(5.4, 1.8, 0.2), rgb(180, 220, 255), material: .smooth,
                         in: car, transparency: 0.5)
        let seat = part("VehicleSeat", Vec3(0, 3.2, 0.5), Vec3(2, 1, 2), dark, in: car)
        let back = part("Bumper", Vec3(0, 2.2, 5.2), Vec3(6, 0.8, 0.4), rgb(60, 60, 66), in: car)
        makeVehicleSeat(seat)
        for piece in [body, hood, glass, seat, back] { loosen(piece) }
        for piece in [hood, glass, seat, back] { weld(body, piece, in: piece) }

        // A wheel stands on end (its axle, the cylinder's Y, turned to point across the car).
        let bodyAt = Vec3(0, 2.2, 0), axle = Vec3(0, -1, 0)
        for (side, x) in [("Left", Float(-3.6)), ("Right", Float(3.6))] {
            for (end, z) in [("Front", Float(-3.4)), ("Back", Float(3.4))] {
                let at = Vec3(x, 1.5, z)
                let wheel = part("Wheel" + end + side, at, Vec3(3, 1, 3), dark, shape: .cylinder,
                                 rotation: Vec3(0, 0, 90), in: car)
                loosen(wheel)
                // Close to the body, and steered into it: they mustn't collide.
                var apart = SceneConstraint(kind: .noCollision)
                apart.part0 = body
                apart.part1 = wheel
                apart.parentID = wheel
                state.constraints.append(apart)
                if end == "Back" {
                    // Driven: the script sets its speed.
                    joint(.hinge, "Motor", in: wheel, body, at: at - bodyAt, axis: Vec3(1, 0, 0),
                          wheel, at: .zero, axis: axle) { $0.actuator = .motor; $0.motorMaxTorque = 4000 }
                } else {
                    // Steered: a knuckle turns on a servo hinge, and the wheel spins free on it.
                    // Heavy enough (metal) for the solver to steer the wheel through it firmly.
                    let knuckle = part("Knuckle" + end + side, at, Vec3(1, 1, 1), dark, material: .metal, in: car,
                                       collide: false, transparency: 1)
                    loosen(knuckle)
                    joint(.hinge, "Steering", in: knuckle, body, at: at - bodyAt, axis: Vec3(0, 1, 0),
                          knuckle, at: .zero, axis: Vec3(0, 1, 0)) {
                        $0.actuator = .servo
                        $0.angularSpeed = 4
                        $0.servoMaxTorque = 1_000_000
                    }
                    joint(.hinge, "Axle", in: wheel, knuckle, at: .zero, axis: Vec3(1, 0, 0), wheel, at: .zero, axis: axle)
                }
            }
        }
        script("Drive", Self.driveSource, in: car)
    }

    // MARK: - The boat

    /// A wooden boat: light enough to float, with a VehicleSeat. A VectorForce pushes it
    /// along and a Torque turns it, set by its script from the seat.
    mutating func boat() {
        let boat = group("Boat")
        let wood = rgb(150, 104, 62), trim = rgb(236, 230, 214)
        let hull = part("Hull", Vec3(0, 0.5, 0), Vec3(6, 1, 12), wood, material: .wood, in: boat)
        var pieces = [
            part("SideLeft", Vec3(-2.7, 1.75, 0), Vec3(0.6, 1.5, 12), trim, material: .wood, in: boat),
            part("SideRight", Vec3(2.7, 1.75, 0), Vec3(0.6, 1.5, 12), trim, material: .wood, in: boat),
            part("Bow", Vec3(0, 1.75, -5.7), Vec3(4.8, 1.5, 0.6), trim, material: .wood, in: boat),
            part("Stern", Vec3(0, 1.75, 5.7), Vec3(4.8, 1.5, 0.6), trim, material: .wood, in: boat),
            part("Outboard", Vec3(0, 1.6, 6.3), Vec3(1, 2, 0.8), rgb(40, 40, 46), in: boat),
        ]
        let seat = part("VehicleSeat", Vec3(0, 1.5, 3), Vec3(2, 1, 2), rgb(60, 90, 140), material: .wood, in: boat)
        makeVehicleSeat(seat, maxSpeed: 30)
        pieces.append(seat)
        loosen(hull)
        for piece in pieces {
            loosen(piece)
            weld(hull, piece, in: piece)
        }
        // Pushed along its front (−Z) and turned about the world's up, from its middle.
        let middle = attachment(on: hull, at: .zero, name: "Middle")
        var thrust = SceneConstraint(kind: .vectorForce, name: "Thrust")
        thrust.parentID = hull
        thrust.attachment0 = middle
        thrust.force = .zero
        thrust.relativeTo = .attachment0
        thrust.applyAtCenterOfMass = true
        var turn = SceneConstraint(kind: .torque, name: "Turn")
        turn.parentID = hull
        turn.attachment0 = middle
        turn.relativeTo = .world
        state.constraints += [thrust, turn]
        // What it all weighs, so the script pushes it as hard as it needs.
        let mass = state.parts.filter { $0.parentID == boat }.map { PhysicsWorld.massProperties(of: $0).mass }.reduce(0, +)
        script("Drive", Self.boatSource(mass: mass), in: boat)
    }

    static func boatSource(mass: Float) -> String {
        """
        -- Drives the boat from its VehicleSeat: Throttle pushes it along (the Thrust
        -- VectorForce), Steer turns it (the Turn Torque). The water slows it.
        local RunService = game:GetService("RunService")

        local boat = script.Parent
        local seat = boat:WaitForChild("VehicleSeat")
        local hull = boat:WaitForChild("Hull")
        local thrust = hull:WaitForChild("Thrust")
        local turn = hull:WaitForChild("Turn")
        local MASS = \(Int(mass.rounded()))

        -- Pushed as hard as MaxSpeed says; turned towards TurnSpeed radians a second while
        -- steering (and to a stop when not), however the water holds it back.
        local lastPush, lastTwist = nil, nil
        RunService.Heartbeat:Connect(function()
        \tlocal push = -seat.ThrottleFloat * seat.MaxSpeed * MASS * 1.2
        \tif push ~= lastPush then
        \t\tlastPush = push
        \t\tthrust.Force = Vector3.new(0, 0, push)
        \tend
        \tlocal wanted = -seat.SteerFloat * seat.TurnSpeed
        \tlocal twist = math.round((wanted - hull.AssemblyAngularVelocity.Y) * MASS * 60)
        \tif twist ~= lastTwist then
        \t\tlastTwist = twist
        \t\tturn.Torque = Vector3.new(0, twist, 0)
        \tend
        end)
        """
    }

    // MARK: - The door

    /// A door in a frame, on a Motor6D along its left edge; clicking it opens or shuts it.
    mutating func door() {
        let door = group("Door")
        let frame = rgb(110, 80, 52)
        let post = part("PostLeft", Vec3(-2.4, 4, 0), Vec3(0.8, 8, 0.8), frame, material: .wood, in: door)
        part("PostRight", Vec3(2.4, 4, 0), Vec3(0.8, 8, 0.8), frame, material: .wood, in: door)
        part("Lintel", Vec3(0, 7.6, 0), Vec3(5.6, 0.8, 0.8), frame, material: .wood, in: door)
        let panel = part("Door", Vec3(0, 3.6, 0), Vec3(4, 7, 0.4), rgb(160, 110, 70), material: .wood, in: door)
        part("Handle", Vec3(1.4, 3.4, -0.35), Vec3(0.3, 0.3, 0.3), rgb(220, 190, 90), material: .metal, in: door)
        if let handle = state.parts.last?.id {
            loosen(handle)
            weld(panel, handle, in: handle)
        }
        loosen(panel)
        if let index = state.parts.firstIndex(where: { $0.id == panel }) { state.parts[index].clickDetector = ClickDetector() }
        // It turns about C0's Z: here, the upright line down the door's left edge.
        let upright = simd_quatf(angle: -.pi / 2, axis: Vec3(1, 0, 0))
        var hinge = SceneConstraint(kind: .motor6d, name: "Hinge")
        hinge.parentID = panel
        hinge.part0 = post
        hinge.part1 = panel
        hinge.c0 = Pose(position: Vec3(0.4, -0.4, 0), orientation: upright)
        hinge.c1 = Pose(position: Vec3(-2, 0, 0), orientation: upright)
        hinge.maxVelocity = 0.06
        state.constraints.append(hinge)
        script("OpenAndShut", Self.doorSource, in: door)
    }

    static let doorSource = """
    -- Click the door to open it, and again to shut it: its Motor6D swings it there.
    local door = script.Parent:WaitForChild("Door")
    local hinge = door:WaitForChild("Hinge")
    local open = false

    door:FindFirstChild("ClickDetector").MouseClick:Connect(function()
    	open = not open
    	hinge.DesiredAngle = if open then math.rad(100) else 0
    end)
    """

    // MARK: - The windmill

    /// A tower with sails on a Motor6D, its script keeping them turning.
    mutating func windmill() {
        let mill = group("Windmill")
        let tower = part("Tower", Vec3(0, 7, 0), Vec3(4, 14, 4), rgb(226, 214, 190), in: mill)
        part("Roof", Vec3(0, 15, 0), Vec3(5, 2, 5), rgb(150, 60, 50), shape: .wedge, in: mill)
        let hub = part("Hub", Vec3(0, 11, -2.6), Vec3(1.2, 1.2, 1.2), rgb(90, 70, 50), material: .wood, in: mill)
        loosen(hub)
        for index in 0..<4 {
            let angle = Float(index) * .pi / 2
            let out = Vec3(cos(angle), sin(angle), 0)
            let sail = part("Sail", Vec3(0, 11, -2.6) + out * 3.6, Vec3(6, 1.4, 0.2), rgb(245, 242, 232), material: .wood,
                            rotation: Vec3(0, 0, angle * 180 / .pi), in: mill)
            loosen(sail)
            weld(hub, sail, in: sail)
        }
        var turn = SceneConstraint(kind: .motor6d, name: "Turn")
        turn.parentID = hub
        turn.part0 = tower
        turn.part1 = hub
        turn.c0 = Pose(position: Vec3(0, 4, -2.6), orientation: Pose.identity.orientation)
        turn.maxVelocity = 0.02
        state.constraints.append(turn)
        script("Spin", Self.windmillSource, in: mill)
    }

    static let windmillSource = """
    -- Keeps the sails turning: always a little further to go than they've gone.
    local turn = script.Parent:WaitForChild("Hub"):WaitForChild("Turn")
    while true do
    	turn.DesiredAngle = turn.CurrentAngle + 1
    	task.wait(0.5)
    end
    """

    // MARK: - Things that stand still

    mutating func campfire() {
        let fire = group("Campfire")
        for index in 0..<8 {
            let angle = Float(index) / 8 * 2 * .pi
            part("Stone", Vec3(cos(angle) * 2.2, 0.35, sin(angle) * 2.2), Vec3(1, 0.7, 0.9), rgb(120, 118, 112),
                 rotation: Vec3(0, -angle * 180 / .pi, 0), in: fire)
        }
        for index in 0..<3 {
            part("Log", Vec3(0, 0.45, 0), Vec3(0.7, 3.4, 0.7), rgb(96, 64, 40), shape: .cylinder, material: .wood,
                 rotation: Vec3(0, Float(index) * 60, 90), in: fire)
        }
        let flames = part("Flames", Vec3(0, 1, 0), Vec3(1.5, 1, 1.5), rgb(255, 150, 60), in: fire, collide: false,
                          transparency: 1, light: light(rgb(255, 160, 80), brightness: 3, range: 18, shadows: true))
        var smoke = ParticleEmitter.preset(.smoke)
        smoke.rate = 6
        emit([ParticleEmitter.preset(.fire), smoke], from: flames)
    }

    mutating func streetLamp() {
        let lamp = group("Street Lamp")
        let iron = rgb(46, 50, 56)
        part("Base", Vec3(0, 0.3, 0), Vec3(1.6, 0.6, 1.6), iron, material: .metal, in: lamp)
        part("Pole", Vec3(0, 6.3, 0), Vec3(0.5, 11.4, 0.5), iron, shape: .cylinder, material: .metal, in: lamp)
        part("Arm", Vec3(0, 11.8, -1.1), Vec3(0.4, 0.4, 2.6), iron, material: .metal, in: lamp)
        part("Lamp", Vec3(0, 11.3, -2.2), Vec3(1.4, 0.7, 1.4), rgb(255, 236, 190), material: .neon, in: lamp,
             light: light(rgb(255, 226, 170), brightness: 3, range: 26, shadows: true))
    }

    mutating func tree() {
        let tree = group("Tree")
        part("Trunk", Vec3(0, 4, 0), Vec3(1.6, 8, 1.6), rgb(106, 76, 50), shape: .cylinder, material: .wood, in: tree)
        let leaves = rgb(76, 140, 70)
        part("Leaves", Vec3(0, 9.5, 0), Vec3(7, 6, 7), leaves, shape: .sphere, in: tree)
        part("Leaves", Vec3(1.8, 8, 1.2), Vec3(4.5, 4, 4.5), rgb(88, 156, 78), shape: .sphere, in: tree)
        part("Leaves", Vec3(-1.6, 8.4, -1.4), Vec3(4.5, 4, 4.5), rgb(66, 128, 62), shape: .sphere, in: tree)
    }

    mutating func makeVehicleSeat(_ id: UUID, maxSpeed: Float) {
        guard let index = state.parts.firstIndex(where: { $0.id == id }) else { return }
        state.parts[index].seat = SeatSettings(vehicle: VehicleSeatSettings(maxSpeed: maxSpeed))
    }

    mutating func makeVehicleSeat(_ id: UUID) {
        guard let index = state.parts.firstIndex(where: { $0.id == id }) else { return }
        state.parts[index].seat = SeatSettings(vehicle: VehicleSeatSettings(maxSpeed: 40))
    }

    static let driveSource = """
    -- Drives the car from its VehicleSeat: the driver's Throttle turns the back wheels
    -- (as fast as MaxSpeed, as hard as Torque), and Steer turns the front ones.
    local RunService = game:GetService("RunService")

    local car = script.Parent
    local seat = car:WaitForChild("VehicleSeat")
    local WHEEL_RADIUS = 1.5
    local STEER_ANGLE = 30

    local motors = {
    \tcar:WaitForChild("WheelBackLeft"):WaitForChild("Motor"),
    \tcar:WaitForChild("WheelBackRight"):WaitForChild("Motor"),
    }
    local steering = {
    \tcar:WaitForChild("KnuckleFrontLeft"):WaitForChild("Steering"),
    \tcar:WaitForChild("KnuckleFrontRight"):WaitForChild("Steering"),
    }

    local lastSpin, lastTurn = nil, nil
    RunService.Heartbeat:Connect(function()
    \t-- The wheels turn backwards to roll the car forwards (its front is −Z).
    \tlocal spin = -seat.ThrottleFloat * seat.MaxSpeed / WHEEL_RADIUS
    \tif spin ~= lastSpin then
    \t\tlastSpin = spin
    \t\tfor _, motor in motors do
    \t\t\tmotor.AngularVelocity = spin
    \t\t\tmotor.MotorMaxTorque = seat.Torque * 400
    \t\tend
    \tend
    \tlocal turn = -seat.SteerFloat * STEER_ANGLE
    \tif turn ~= lastTurn then
    \t\tlastTurn = turn
    \t\tfor _, knuckle in steering do
    \t\t\tknuckle.TargetAngle = turn
    \t\t\tknuckle.AngularSpeed = 4 * seat.TurnSpeed
    \t\tend
    \tend
    end)
    """
}

extension SceneModel {
    /// A Toolbox model in the world, its pivot at `ground`. One undo step; it's selected.
    @discardableResult
    func insert(_ item: ToolboxModel, at ground: Vec3) -> Int {
        guard let file = item.file else {
            let rig = addRig(at: ground)
            return parts.filter { $0.parentID == rig }.count
        }
        return insert(file, at: ground)
    }
}
