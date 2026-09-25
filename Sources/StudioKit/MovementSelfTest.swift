import Foundation
import simd

/// Verification for how the world moves the character: moving platforms, walls and
/// thrown parts pushing it, seats, climbing trusses and swimming — alone, and with a
/// joined player pushing crates, sitting, climbing and riding the host's platform.
enum MovementSelfTest {

    static func run(check: Checker) {
        testPlatforms(check)
        testPushes(check)
        testSeats(check)
        testClimbing(check)
        testSwimming(check)
        testInMultiplayer(check)
    }

    private static let frame: Float = 1.0 / 60

    static func block(_ name: String, at position: Vec3, size: Vec3, anchored: Bool = true) -> Part {
        var part = Part()
        part.name = name
        part.position = position
        part.size = size
        part.anchored = anchored
        return part
    }

    private static func play(_ parts: [Part], script: String = "", at feet: Vec3 = .zero) -> PlayController {
        let model = SceneModel()
        model.parts = parts
        model.scripts = []
        model.shaders = []
        model.groups = []
        var control = ScriptObject.blank(language: .luau)
        control.name = "ControlScript"
        control.host = .starterPlayer
        control.enabled = false
        model.scripts = [control]
        if !script.isEmpty {
            var scene = ScriptObject.blank(language: .luau)
            scene.source = script
            model.scripts.append(scene)
        }
        let session = PlayController(model: model, console: ScriptConsole())
        session.playerName = "Robin"
        session.start()
        session.character.position = feet
        session.character.velocity = .zero
        run(session, seconds: 0.3)
        return session
    }

    private static func run(_ session: PlayController, seconds: Float, each: (() -> Void)? = nil) {
        var elapsed: Float = 0
        while elapsed < seconds - frame / 2 {
            each?()
            session.step(dt: frame)
            elapsed += frame
        }
    }

    private static func lines(_ session: PlayController) -> [String] {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        return session.console.lines.filter { $0.kind == .output }.map(\.text)
    }

    private static func errors(_ session: PlayController) -> [String] {
        session.console.lines.filter { $0.kind == .error }.map(\.text)
    }

    // MARK: - Platforms

    private static func testPlatforms(_ check: Checker) {
        print("\nMovement: moving platforms")
        let sliding = play([block("Platform", at: Vec3(0, 4.5, 0), size: Vec3(12, 1, 12))], script: """
        local platform = workspace.Platform
        game:GetService("RunService").Heartbeat:Connect(function(dt)
        \tplatform.Position += Vector3.new(dt * 5, 0, 0)
        end)
        """, at: Vec3(0, 5, 0))
        let start = sliding.character.position
        run(sliding, seconds: 1)
        let carried = sliding.character.position - start
        check("a platform moved by a script carries whoever stands on it", abs(carried.x - 5) < 0.6 && sliding.character.grounded,
              "\(carried)")
        sliding.stop()

        let turning = play([block("Spinner", at: Vec3(0, 4.5, 0), size: Vec3(12, 1, 12))], script: """
        local spinner = workspace.Spinner
        game:GetService("RunService").Heartbeat:Connect(function(dt)
        \tspinner.CFrame = spinner.CFrame * CFrame.Angles(0, dt, 0)
        end)
        """, at: Vec3(3, 5, 0))
        let yaw = turning.character.facingYaw
        run(turning, seconds: 1)
        let spun = turning.character.facingYaw - yaw
        let around = turning.character.position
        check("…and a turning one turns them with it, round its middle",
              abs(abs(spun) - 1) < 0.15 && abs(simd_length(Vec3(around.x, 0, around.z)) - 3) < 0.3,
              "\(spun) \(around)")
        turning.stop()
    }

    // MARK: - Pushes

    private static func testPushes(_ check: Checker) {
        print("\nMovement: parts pushing the character")
        let wall = play([block("Wall", at: Vec3(4, 3, 0), size: Vec3(1, 6, 10))], script: """
        local wall = workspace.Wall
        game:GetService("RunService").Heartbeat:Connect(function(dt)
        \twall.Position -= Vector3.new(dt * 4, 0, 0)
        end)
        """)
        run(wall, seconds: 1.5)
        check("a wall moved by a script pushes the character along", wall.character.position.x < -0.5,
              "\(wall.character.position)")
        wall.stop()

        let thrown = play([block("Crate", at: Vec3(10, 1.5, 0), size: Vec3(3, 3, 3), anchored: false)], script: """
        task.wait(0.1)
        workspace.Crate.AssemblyLinearVelocity = Vector3.new(-70, 0, 0)
        """)
        run(thrown, seconds: 0.8)
        check("a crate thrown at the character knocks them back", thrown.character.position.x < -1,
              "\(thrown.character.position)")
        check("…and they come to rest again", simd_length(thrown.character.shove) < 1)
        thrown.stop()
    }

    // MARK: - Seats

    private static func testSeats(_ check: Checker) {
        print("\nMovement: seats")
        var seat = block("Seat", at: Vec3(0, 1, -6), size: Vec3(2, 1, 2))
        seat.seat = SeatSettings()
        var off = block("Bench", at: Vec3(12, 1, -6), size: Vec3(2, 1, 2))
        off.seat = SeatSettings(disabled: true)
        let session = play([seat, off], script: """
        local humanoid = game:GetService("Players").LocalPlayer.Character:WaitForChild("Humanoid")
        local seat = workspace.Seat
        print("classes", seat.ClassName, workspace.Bench.Disabled, seat.Occupant)
        humanoid.Seated:Connect(function(active, part)
        \tprint("seated", active, part and part.Name, seat.Occupant == (if active then humanoid else nil),
        \t\thumanoid.Sit, humanoid.SeatPart == part)
        end)
        game:GetService("UserInputService").InputBegan:Connect(function(input)
        \tif input.KeyCode == Enum.KeyCode.U then
        \t\thumanoid.Sit = false
        \tend
        end)
        """)
        check("a Seat is a part of class Seat, with Disabled and Occupant",
              lines(session).contains("classes Seat true nil"), "\(lines(session)) \(errors(session))")
        run(session, seconds: 1.5) { session.humanoid.moveDirection = Vec3(0, 0, -1) }
        check("walking into a seat sits down in it", session.humanoid.state == .seated && session.seatPart == seat.id)
        check("…telling scripts, with Occupant, Sit and SeatPart",
              lines(session).contains("seated true Seat true true true"), "\(lines(session)) \(errors(session))")
        run(session, seconds: 0.5) { session.humanoid.moveDirection = Vec3(1, 0, 0) }
        let top = seat.position.y + 0.5
        check("…where the body stays, hips on the seat, walking or not",
              abs(session.character.position.x) < 0.01 && abs(session.character.position.y - (top - 2)) < 0.01)
        check("…legs out in front", session.currentJoints.leftHip.x > 1.2, "\(session.currentJoints.leftHip)")

        session.humanoid.moveDirection = .zero
        session.humanoid.jump = true
        run(session, seconds: 0.2)
        check("a jump gets up", session.humanoid.state != .seated && !session.isSeated
              && lines(session).contains("seated false nil true false true"), "\(lines(session))")
        run(session, seconds: 1.5) { session.humanoid.moveDirection = Vec3(0, 0, 1) }

        run(session, seconds: 2.2) { session.humanoid.moveDirection = Vec3(0, 0, -1) }
        check("sitting again after a moment", session.isSeated, "\(session.character.position)")
        session.key("U", pressed: true)
        run(session, seconds: 0.1)
        session.key("U", pressed: false)
        check("Sit = false gets up too", !session.isSeated)

        session.character.position = Vec3(12, 0, 0)
        run(session, seconds: 1.5) { session.humanoid.moveDirection = Vec3(0, 0, -1) }
        check("a disabled seat can't be sat in", !session.isSeated)
        check("none of it raised an error", errors(session).isEmpty, errors(session).joined(separator: " | "))
        session.stop()
    }

    // MARK: - Climbing

    private static func testClimbing(_ check: Checker) {
        print("\nMovement: climbing a truss")
        var truss = block("Truss", at: Vec3(0, 10, -4), size: Vec3(2, 20, 2))
        truss.shape = .truss
        let session = play([truss])
        run(session, seconds: 1.2) { session.humanoid.moveDirection = Vec3(0, 0, -1) }
        let height = session.character.position.y
        check("walking into a truss climbs it", height > 6 && session.humanoid.state == .climbing, "\(height)")
        run(session, seconds: 0.5) { session.humanoid.moveDirection = .zero }
        check("…letting go of the keys holds on", abs(session.character.position.y - height) < 0.2
              && session.humanoid.state == .climbing, "\(session.character.position.y)")
        run(session, seconds: 0.3) { session.humanoid.moveDirection = Vec3(0, 0, 1) }
        check("…backing away climbs down", session.character.position.y < height - 2, "\(session.character.position.y)")
        run(session, seconds: 3) {
            let onTop = session.character.grounded && session.character.position.y > 19
            session.humanoid.moveDirection = onTop ? .zero : Vec3(0, 0, -1)
        }
        check("…and climbing to the top steps onto it",
              abs(session.character.position.y - 20) < 0.3 && session.character.grounded
              && session.humanoid.state == .running, "\(session.character.position) \(session.humanoid.state)")

        session.character.position = Vec3(0, 0, 0)
        run(session, seconds: 0.8) { session.humanoid.moveDirection = Vec3(0, 0, -1) }
        session.humanoid.jump = true
        run(session, seconds: 0.3) { session.humanoid.moveDirection = .zero }
        check("a jump lets go, away from it", session.humanoid.state != .climbing && session.character.position.z > -1.5,
              "\(session.character.position)")
        session.stop()
    }

    // MARK: - Swimming

    private static func testSwimming(_ check: Checker) {
        print("\nMovement: swimming")
        var water = block("Lake", at: Vec3(0, 5, 0), size: Vec3(60, 10, 60))
        water.material = .water
        water.transparency = 0.5
        let session = play([water], at: Vec3(0, 16, 0))
        run(session, seconds: 2.5)
        let floating = session.character.position.y
        check("water isn't solid: falling in, the character swims", session.humanoid.state == .swimming
              && floating < 9, "\(floating) \(session.humanoid.state)")
        check("…floating with the head out", abs(floating - (10 - CharacterController.floatDepth)) < 0.5, "\(floating)")
        var highest = floating
        run(session, seconds: 0.6) {
            session.humanoid.jump = true
            highest = max(highest, session.character.position.y)
        }
        check("Space swims up", highest > floating + 1, "\(highest)")
        run(session, seconds: 4) { session.humanoid.jump = false; session.humanoid.moveDirection = Vec3(1, 0, 0) }
        check("swimming out onto land walks again",
              session.character.position.x > 30 && session.character.grounded && session.humanoid.state == .running,
              "\(session.character.position) \(session.humanoid.state)")
        session.stop()
    }

    // MARK: - Multiplayer

    private static func testInMultiplayer(_ check: Checker) {
        print("\nMovement: in a network game")
        var seat = block("Seat", at: Vec3(40, 1, 0), size: Vec3(2, 1, 2))
        seat.seat = SeatSettings()
        var truss = block("Truss", at: Vec3(-40, 10, -4), size: Vec3(2, 20, 2))
        truss.shape = .truss
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            model.starterPlayer.playersCollide = false
            model.parts = [
                block("HostCrate", at: Vec3(0, 1, -50), size: Vec3(2, 2, 2), anchored: false),
                block("JoinerCrate", at: Vec3(20, 1, -50), size: Vec3(2, 2, 2), anchored: false),
                seat, truss,
                block("Lift", at: Vec3(0, 4.5, 60), size: Vec3(10, 1, 10)),
            ]
            var script = ScriptObject.blank(language: .luau)
            script.source = """
            local lift = workspace.Lift
            local seat = workspace.Seat
            local riding = false
            game:GetService("RunService").Heartbeat:Connect(function(dt)
            \tif workspace:FindFirstChild("Go") then
            \t\tlift.Position += Vector3.new(dt * 5, 0, 0)
            \tend
            \tif seat.Occupant and not riding then
            \t\triding = true
            \t\tprint("in the seat: " .. seat.Occupant.Parent.Name)
            \tend
            end)
            """
            model.scripts.append(script)
        }), let robin = hosting.player, let sam = joining.player else {
            check("two players share a game", false)
            return
        }
        func said() -> [String] {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            return robin.console.lines.filter { $0.kind == .output }.map(\.text)
        }
        func crate(_ name: String) -> Vec3 { hosting.model.parts.first { $0.name == name }?.position ?? .zero }

        robin.character.position = Vec3(0, 0, -45)
        sam.character.position = Vec3(20, 0, -45)
        LANSelfTest.run([hosting, joining], seconds: 0.3)
        let hostStart = crate("HostCrate"), joinerStart = crate("JoinerCrate")
        LANSelfTest.run([hosting, joining], seconds: 1.2) {
            robin.humanoid.moveDirection = Vec3(0, 0, -1)
            sam.humanoid.moveDirection = Vec3(0, 0, -1)
        }
        robin.humanoid.moveDirection = .zero
        sam.humanoid.moveDirection = .zero
        let byHost = simd_distance(crate("HostCrate"), hostStart)
        let byJoiner = simd_distance(crate("JoinerCrate"), joinerStart)
        check("a joined player walking into a crate shoves it as the host does",
              byJoiner > 3 && byHost > 3 && byJoiner / byHost > 0.5 && byJoiner / byHost < 2, "\(byHost) vs \(byJoiner)")

        sam.character.position = Vec3(40, 0, 6)
        LANSelfTest.run([hosting, joining], seconds: 1.5) { sam.humanoid.moveDirection = Vec3(0, 0, -1) }
        check("a joined player sits in a seat", sam.isSeated)
        check("…and the host's scripts see them in it", said().contains("in the seat: Sam")
              && robin.remotePlayers.first?.state == "Seated", "\(said())")
        sam.humanoid.jump = true
        LANSelfTest.run([hosting, joining], seconds: 0.3)

        sam.character.position = Vec3(-40, 0, 0)
        LANSelfTest.run([hosting, joining], seconds: 1.2) { sam.humanoid.moveDirection = Vec3(0, 0, -1) }
        check("a joined player climbing is seen climbing", robin.remotePlayers.first?.state == "Climbing"
              && (robin.remotePlayers.first?.position.y ?? 0) > 5, "\(String(describing: robin.remotePlayers.first?.state))")
        sam.humanoid.moveDirection = .zero

        sam.character.position = Vec3(0, 5, 60)
        LANSelfTest.run([hosting, joining], seconds: 0.5)
        let before = sam.character.position
        hosting.model.parts.append(block("Go", at: Vec3(0, -50, 0), size: Vec3(1, 1, 1)))
        LANSelfTest.run([hosting, joining], seconds: 1)
        let ridden = sam.character.position.x - before.x
        check("a joined player on the host's moving platform rides it", ridden > 3.5 && ridden < 6.5, "\(ridden)")
        let errors = (robin.console.lines + sam.console.lines).filter { $0.kind == .error }.map(\.text)
        check("none of it raised an error", errors.isEmpty, errors.joined(separator: " | "))
        joining.leaveGame()
        hosting.leaveGame()
    }
}
