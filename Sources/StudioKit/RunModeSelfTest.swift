import Foundation

/// Verification for Studio's Run mode (F8): the scene's scripts and physics with no
/// player, the editor keeping the camera, and Stop putting the scene back. It is a
/// Studio-only mode — nothing in it is sent over the network, so it has no multiplayer
/// test (AGENTS.md §9 says so).
enum RunModeSelfTest {

    static func run(check: Checker) {
        print("\nStudio: Run mode")
        let model = SceneModel()
        model.parts = []
        model.scripts = []
        model.shaders = []
        var crate = Part()
        crate.name = "Crate"
        crate.anchored = false
        crate.position = Vec3(0, 20, 0)
        var mover = Part()
        mover.name = "Mover"
        mover.position = Vec3(10, 2, 0)
        model.parts = [crate, mover]
        func script(_ source: String, host: ScriptHost = .scene) -> ScriptObject {
            var script = ScriptObject.blank(language: .luau)
            script.source = source
            script.host = host
            return script
        }
        model.scripts = [
            script("""
            print("scene script ran, players: " .. #game:GetService("Players"):GetPlayers())
            game:GetService("RunService").Heartbeat:Connect(function(dt)
            \tworkspace.Mover.Position += Vector3.new(dt * 4, 0, 0)
            end)
            """),
            script("print(\"player script ran\")", host: .starterPlayer),
            script("print(\"character script ran\")", host: .starterCharacter),
        ]
        let session = EditorSession(model: model)
        session.startRun()
        guard let running = session.play else {
            check("Run starts a session", false)
            return
        }
        check("Run starts the scene with no player",
              session.isPlaying && session.isRunMode && !running.hasPlayer && running.characterGeneration == 0)
        check("…leaving the viewport's mouse, keys and camera to the editor",
              session.player == nil && session.source === session.viewport && session.viewport.running === running)

        for _ in 0..<60 { running.step(dt: 1.0 / 60) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let output = session.console.lines.filter { $0.kind == .output }.map(\.text)
        check("the scene's scripts run, and see no players", output == ["scene script ran, players: 0"], "\(output)")
        let fallen = model.parts.first { $0.name == "Crate" }?.position.y ?? 20
        let moved = model.parts.first { $0.name == "Mover" }?.position.x ?? 10
        check("physics runs: the crate falls", fallen < 19, "\(fallen)")
        check("…and scripts move things", moved > 13, "\(moved)")
        check("no body stands in the physics", running.physics.characterIDs.isEmpty)
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("…with no errors", errors.isEmpty, errors.joined(separator: " | "))

        // The editor's own frames step it, as the viewport's display link does.
        let before = model.parts.first { $0.name == "Mover" }?.position.x ?? 0
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            session.viewport.stepFrame()
        }
        let after = model.parts.first { $0.name == "Mover" }?.position.x ?? 0
        check("the editor's frames keep it running", after > before, "\(before) → \(after)")

        session.stopPlay()
        check("Stop puts the scene back", !session.isPlaying && !session.isRunMode && session.viewport.running == nil
              && model.parts.first { $0.name == "Crate" }?.position.y == 20
              && model.parts.first { $0.name == "Mover" }?.position.x == 10)

        session.startPlay()
        check("Play afterwards has a player again", session.player?.characterGeneration == 1 && !session.isRunMode)
        session.stopPlay()
        testEvents(check)
    }

    /// With no player, the scene's events still reach its scripts: parts touching, a
    /// Sound running out.
    private static func testEvents(_ check: Checker) {
        let model = SceneModel()
        model.parts = []
        model.scripts = []
        model.shaders = []
        model.groups = []
        model.sounds = []
        model.assets = []
        _ = try? model.importAsset(data: AudioSelfTest.wav(seconds: 0.2), name: "Thud", fileExtension: "wav")
        var floor = Part()
        floor.name = "Floor"
        floor.size = Vec3(20, 1, 20)
        var ball = Part()
        ball.name = "Ball"
        ball.anchored = false
        ball.position = Vec3(0, 4, 0)
        model.parts = [floor, ball]
        var script = ScriptObject.blank(language: .luau)
        script.source = """
        local thud = Instance.new("Sound", workspace.Floor)
        thud.SoundId = "studio://Thud"
        thud.Ended:Connect(function() print("thud ended") end)
        workspace.Floor.Touched:Connect(function(hit)
        \tprint("floor touched by " .. hit.Name)
        \tif not thud.Playing then thud:Play() end
        end)
        """
        model.scripts = [script]
        let session = EditorSession(model: model)
        session.startRun()
        guard let running = session.play else {
            check("Run starts a session", false)
            return
        }
        for _ in 0..<120 { running.step(dt: 1.0 / 60) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let output = session.console.lines.filter { $0.kind == .output }.map(\.text)
        check("in Run mode parts touching fire Touched", output.first == "floor touched by Ball", "\(output)")
        check("…and a Sound that runs out fires Ended", output.contains("thud ended"), "\(output)")
        session.stopPlay()
    }
}
