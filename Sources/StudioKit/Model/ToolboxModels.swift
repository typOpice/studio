import Foundation
import simd

/// Ready-made models, built in code: Studio's Toolbox puts them in the world (and
/// Insert › Car the car). Each is built standing on y = 0 around its pivot at the origin,
/// facing −Z, as a `ModelFile` — so it goes in exactly as a saved creation does.
enum ToolboxModel: String, CaseIterable, Identifiable {
    case car = "Car"

    var id: String { rawValue }

    var file: ModelFile {
        var builder = ToolboxBuilder()
        switch self {
        case .car: builder.car()
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
        insert(item.file, at: ground)
    }
}
