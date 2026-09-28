import Foundation
import simd

/// Cars: Insert › Car's Model (its parts, joints and drive script; one undo step; two cars
/// keeping their parts' names); driving it — W forward at MaxSpeed, stopping when let go,
/// S backwards, D and A turning right and left, the speedometer, Space getting out and
/// the seat's controls going back to 0; VehicleSeat from scripts (its class and
/// properties, a driverless car a script drives, wrong values refused); saving; and a
/// joined player driving the host's car.
enum CarSelfTest {
    static func run(check: Checker) {
        testStudio(check)
        testDriving(check)
        testScripts(check)
        testSaving(check)
        testReadme(check)
        testTogether(check)
    }

    // MARK: - The README

    private static func testReadme(_ check: Checker) {
        print("\nCars: the README's example")
        guard let readme = try? String(contentsOfFile: "README.md", encoding: .utf8),
              let start = readme.range(of: "### Cars: VehicleSeat"),
              let block = readme[start.upperBound...].components(separatedBy: "```lua\n").dropFirst().first?
                .components(separatedBy: "```").first else {
            print("  (README.md not found from here; skipped)")
            return
        }
        let model = ground()
        model.insert(.car, at: .zero)
        var script = ScriptObject.blank(language: .luau)
        script.source = block
        model.scripts.append(script)
        let session = PlayController(model: model, console: ScriptConsole(), withPlayer: false)
        session.start()
        steps(session, 60 * 4)
        let body = named(model, "Body")
        let turned = body.map { simd_dot($0.orientation.act(Vec3(0, 0, -1)), Vec3(0, 0, -1)) } ?? 1
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("as written: the car drives round in circles on its own",
              (body.map { simd_distance($0.position, Vec3(0, 2.2, 0)) } ?? 0) > 5 && turned < 0.7 && errors.isEmpty,
              "\(String(describing: body?.position)) \(turned) \(errors)")
        session.stop()
    }

    private static let frame = ForceSelfTest.frame

    private static func ground() -> SceneModel {
        ForceSelfTest.scene([ForceSelfTest.block("Ground", Vec3(0, -0.5, 0), size: Vec3(600, 1, 600), anchored: true)])
    }

    private static func steps(_ session: PlayController, _ count: Int) {
        for _ in 0..<count { session.step(dt: frame) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }

    private static func named(_ model: SceneModel, _ name: String, in car: UUID? = nil) -> Part? {
        model.parts.first { $0.name == name && (car == nil || model.isDescendant($0.id, of: car!)) }
    }

    // MARK: - Studio

    private static func testStudio(_ check: Checker) {
        print("\nCars: Insert › Car")
        let model = ground()
        let revision = model.revision
        let count = model.insert(.car, at: Vec3(10, 0, 0))
        guard let car = model.groups.first(where: { $0.name == "Car" }) else {
            check("Insert › Car makes a Model called Car", false)
            return
        }
        let inside = model.parts.filter { model.isDescendant($0.id, of: car.id) }
        let seat = inside.first { $0.name == "VehicleSeat" }
        check("Insert › Car makes a Model: a body, a VehicleSeat, four wheels and two steering knuckles",
              count == 11 && inside.count == 11 && seat?.seat?.vehicle != nil
              && inside.filter { $0.name.hasPrefix("Wheel") }.count == 4 && model.selection == [car.id],
              "\(inside.map(\.name))")
        let joints = model.constraints.filter { c in c.parts(in: model).0.map { model.isDescendant($0, of: car.id) } ?? false }
        check("…the back wheels on motors, the front on axles turned by servos, welded and kept apart",
              joints.filter { $0.name == "Motor" && $0.actuator == .motor }.count == 2
              && joints.filter { $0.name == "Steering" && $0.actuator == .servo }.count == 2
              && joints.filter { $0.name == "Axle" }.count == 2 && joints.filter { $0.kind == .weld }.count == 4
              && joints.filter { $0.kind == .noCollision }.count == 4)
        check("…with its drive script in it, standing on the ground where it was put",
              model.scripts.contains { $0.name.hasPrefix("Drive") && $0.parentID == car.id }
              && inside.filter { $0.name.hasPrefix("Wheel") }.allSatisfy { abs($0.position.y - 1.5) < 1e-4 }
              && abs((seat?.position.x ?? 0) - 10) < 1e-4)
        model.insert(.car, at: Vec3(-10, 0, 0))
        let cars = model.groups.filter { $0.name == "Car" }
        check("a second car's parts keep their names inside it, for its script",
              cars.count == 2 && cars.allSatisfy { car in named(model, "WheelBackLeft", in: car.id) != nil })
        model.undo()
        model.undo()
        check("…and each is one step to undo", model.revision != revision && model.parts.count == 1 && model.groups.isEmpty
              && model.constraints.isEmpty && model.scripts.isEmpty)

        // A loose part still gets a name of its own.
        var file = ToolboxModel.car.file!
        var loose = Part()
        loose.name = "Ground"
        file.state.parts.append(loose)
        model.insert(file, at: .zero)
        check("…while a loose part gets a name of its own", model.parts.filter { $0.name == "Ground" }.count == 1)
    }

    // MARK: - Driving

    static let dashboard = """
    local player = game:GetService("Players").LocalPlayer
    task.wait(2.2)
    local hud = player.PlayerGui:FindFirstChild("VehicleHud")
    local speed = hud and hud:FindFirstChild("Speed")
    print("hud", hud ~= nil and hud.Enabled, speed and speed.Text)
    """

    private static func testDriving(_ check: Checker) {
        print("\nCars: driving")
        let model = ground()
        model.insert(.car, at: .zero)
        var watcher = ScriptObject.blank(language: .luau)
        watcher.host = .starterPlayer
        watcher.source = dashboard
        model.scripts.append(watcher)
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        steps(session, 60)
        guard let seat = named(model, "VehicleSeat")?.id, let bodyID = named(model, "Body")?.id else {
            check("the car is there", false)
            return
        }
        func body() -> Part { model.part(id: bodyID)! }
        func speed() -> Float { simd_length(session.physics.motion(of: bodyID)?.velocity ?? .zero) }
        func heading() -> Vec3 { body().orientation.act(Vec3(0, 0, -1)) }
        let parked = body().position
        check("parked, it stays put", simd_distance(parked, Vec3(0, 2.2, 0)) < 0.2, "\(parked)")

        session.sit(in: seat)
        session.key("W", pressed: true)
        steps(session, 90)
        let driven = body().position
        check("W drives it forward, up to MaxSpeed", parked.z - driven.z > 30 && abs(driven.x) < 1.5
              && speed() > 34 && speed() < 42, "\(driven) \(speed())")
        check("…the seat's Throttle is the driver's key", session.vehicleControls[seat]?.throttle == 1)
        check("…and the driver rides along", simd_distance(session.character.position, body().position) < 4,
              "\(session.character.position)")
        steps(session, 30)
        let hud = session.console.lines.last { $0.text.hasPrefix("hud") }?.text ?? "(nothing)"
        let shown = hud.split(separator: " ").dropFirst(2).first.flatMap { Int($0) } ?? 0
        check("the speedometer shows the driver their speed", hud.hasPrefix("hud true") && hud.hasSuffix("studs/s")
              && shown >= 30, hud)

        session.key("W", pressed: false)
        steps(session, 90)
        check("let go, it stops", speed() < 1.5, "\(speed())")

        let before = body().position
        session.key("S", pressed: true)
        steps(session, 60)
        session.key("S", pressed: false)
        check("S drives it backwards", body().position.z - before.z > 5, "\(body().position)")

        steps(session, 60)
        session.key("W", pressed: true)
        session.key("D", pressed: true)
        steps(session, 90)
        let right = heading()
        check("D turns it right", right.x > 0.4, "\(right)")
        session.key("D", pressed: false)
        session.key("A", pressed: true)
        steps(session, 90)
        check("…and A left", heading().x < right.x - 0.4, "\(heading())")
        session.key("W", pressed: false)
        steps(session, 20)
        // Getting out while still steering: the seat lets go of Steer too.
        session.key("Space", pressed: true)
        steps(session, 10)
        session.key("Space", pressed: false)
        session.key("A", pressed: false)
        steps(session, 90)
        check("Space gets out, and the seat's controls go back to 0 (it stops)",
              !session.isSeated && session.vehicleControls[seat] == nil && speed() < 1.5, "\(speed())")
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("no errors", errors.isEmpty, "\(errors)")
        session.stop()
    }

    // MARK: - Scripts

    static let scriptSource = """
    local seat = Instance.new("VehicleSeat")
    seat.Parent = workspace
    print("class", seat.ClassName, seat:IsA("VehicleSeat"), seat:IsA("Seat"), seat:IsA("Part"), seat:IsA("BasePart"))
    print("defaults", seat.MaxSpeed, seat.Torque, seat.TurnSpeed, seat.HeadsUpDisplay, seat.Throttle, seat.SteerFloat,
    \tseat.Occupant == nil)
    seat.MaxSpeed = 60
    seat.HeadsUpDisplay = false
    seat.Throttle = 5
    seat.SteerFloat = -0.5
    print("set", seat.MaxSpeed, seat.HeadsUpDisplay, seat.Throttle, seat.ThrottleFloat, seat.Steer, seat.SteerFloat)
    local ok1 = pcall(function() seat.MaxSpeed = "fast" end)
    local ok2 = pcall(function() seat.Throttle = true end)
    local ok3 = pcall(function() return workspace.Ground.Throttle end)
    print("refused", ok1, ok2, ok3)

    -- Nobody in it: a script drives the car.
    local car = workspace:WaitForChild("Car")
    local driver = car:WaitForChild("VehicleSeat")
    task.wait(0.5)
    driver.ThrottleFloat = 1
    task.wait(2)
    print("driverless", driver.Throttle, driver.Occupant == nil)
    """

    private static func testScripts(_ check: Checker) {
        print("\nCars: VehicleSeat from scripts")
        let model = ground()
        model.insert(.car, at: .zero)
        var script = ScriptObject.blank(language: .luau)
        script.source = scriptSource
        model.scripts.append(script)
        let session = PlayController(model: model, console: ScriptConsole(), withPlayer: false)
        session.start()
        steps(session, 60 * 3)
        func said(_ prefix: String) -> String {
            session.console.lines.last { $0.kind == .output && $0.text.hasPrefix(prefix) }?.text ?? "(nothing)"
        }
        check("Instance.new(\"VehicleSeat\"): a VehicleSeat and a BasePart, not a Seat or a Part",
              said("class") == "class VehicleSeat true false false true", said("class"))
        check("…MaxSpeed, Torque, TurnSpeed, HeadsUpDisplay, Throttle, SteerFloat and Occupant",
              said("defaults") == "defaults 25 10 1 true 0 0 true", said("defaults"))
        check("…set: Throttle a whole number from −1 to 1, its Float too",
              said("set") == "set 60 false 1 1 -1 -0.5", said("set"))
        check("…wrong values refused, and a Part has no Throttle", said("refused") == "refused false false false", said("refused"))
        let body = named(model, "Body")?.position ?? .zero
        check("a script drives a car nobody's in", said("driverless") == "driverless 1 true" && body.z < -30,
              "\(said("driverless")) \(body)")
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("no errors", errors.isEmpty, "\(errors)")
        session.stop()
    }

    // MARK: - Saving

    private static func testSaving(_ check: Checker) {
        print("\nCars: saving")
        let model = ground()
        model.insert(.car, at: .zero)
        if let seat = named(model, "VehicleSeat")?.id {
            model.update(id: seat) { $0.seat?.vehicle?.maxSpeed = 55; $0.seat?.vehicle?.headsUpDisplay = false }
        }
        let reopened = SceneModel()
        if let data = try? model.encodeScene() { try? reopened.loadScene(from: data) }
        check("a VehicleSeat is saved and reopened with its settings",
              named(reopened, "VehicleSeat")?.seat?.vehicle == VehicleSeatSettings(maxSpeed: 55, headsUpDisplay: false))
        let plain = try? JSONDecoder().decode(Part.self, from: Data(#"{"name":"Seat","seat":{"disabled":true}}"#.utf8))
        check("…and a Seat saved before is still just a Seat", plain?.seat == SeatSettings(disabled: true))
    }

    // MARK: - Together

    private static func testTogether(_ check: Checker) {
        print("\nCars: a joined player drives the host's car")
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            var base = Part()
            base.name = "Baseplate"
            base.position = Vec3(0, -0.5, 0)
            base.size = Vec3(400, 1, 400)
            model.parts = [base]
            model.insert(.car, at: Vec3(40, 0, 40))
            var listen = ScriptObject.blank(language: .luau)
            listen.source = """
            local seat = workspace:WaitForChild("Car"):WaitForChild("VehicleSeat")
            local seen = 0
            while true do
            \ttask.wait(0.1)
            \tif seat.Throttle > seen then
            \t\tseen = seat.Throttle
            \t\tprint("throttle", seat.Throttle, seat.Occupant and seat.Occupant.Parent.Name)
            \tend
            end
            """
            model.scripts.append(listen)
            // The real controls: the ones that drive a VehicleSeat from the keys.
            model.scripts.removeAll { $0.name == "ControlScript" }
        }), let host = hosting.player, let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 1)
        guard let seat = joining.model.parts.first(where: { $0.name == "VehicleSeat" })?.id else {
            check("the joined player sees the car", false)
            return
        }
        let start = hosting.model.parts.first { $0.name == "Body" }?.position ?? .zero
        sam.sit(in: seat)
        sam.key("W", pressed: true)
        LANSelfTest.run([hosting, joining], seconds: 2)
        let onHost = hosting.model.parts.first { $0.name == "Body" }?.position ?? .zero
        let onSam = joining.model.parts.first { $0.name == "Body" }?.position ?? .zero
        check("their keys reach the host, whose script sees Throttle and who's driving",
              host.console.lines.contains { $0.text.hasPrefix("throttle 1") && $0.text.contains("Sam") },
              "\(host.console.lines.map(\.text).suffix(4))")
        check("…the host's car drives off, and they see it (and ride in it)",
              start.z - onHost.z > 25 && simd_distance(onHost, onSam) < 4
              && simd_distance(sam.character.position, onSam) < 4, "\(start) \(onHost) \(onSam)")
        sam.key("Space", pressed: true)
        LANSelfTest.run([hosting, joining], seconds: 0.3)
        sam.key("Space", pressed: false)
        sam.key("W", pressed: false)
        LANSelfTest.run([hosting, joining], seconds: 2)
        check("…and when they get out, it stops", !sam.isSeated && host.vehicleControls[seat] == nil
              && simd_length(host.physics.motion(of: hosting.model.parts.first { $0.name == "Body" }!.id)?.velocity ?? .zero) < 2)
        let errors = (host.console.lines + sam.console.lines).filter { $0.kind == .error }.map(\.text)
        check("…with no errors on either", errors.isEmpty, "\(errors)")
        joining.leaveGame()
        hosting.leaveGame()
    }
}
