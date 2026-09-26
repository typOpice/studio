import Foundation
import simd

/// Shift lock: on in every place (old files too), Left Ctrl toggling it; the camera over
/// the shoulder, the pointer held (scripts see LockCenter, the HUD shows its crosshair)
/// and the body turned with the camera even walking sideways; off again; taken away by
/// the place or by a script; the controls panel saying so; and a joined player's
/// shift lock seen by the host.
enum ShiftLockSelfTest {
    static func run(check: Checker) {
        testSetting(check)
        testPlaying(check)
        testTakenAway(check)
        testTogether(check)
    }

    private static let frame: Float = 1.0 / 60

    private static func step(_ session: PlayController, seconds: Float) {
        var elapsed: Float = 0
        while elapsed < seconds {
            session.step(dt: frame)
            elapsed += frame
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    private static func press(_ session: PlayController, _ key: String) {
        session.key(key, pressed: true)
        session.step(dt: frame)
        session.key(key, pressed: false)
        step(session, seconds: 0.1)
    }

    private static func said(_ session: PlayController, _ kind: ScriptConsole.Kind = .output) -> [String] {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        return session.console.lines.filter { $0.kind == kind }.map(\.text)
    }

    /// The smallest turn between two headings.
    private static func apart(_ a: Float, _ b: Float) -> Float {
        abs(atan2(sin(a - b), cos(a - b)))
    }

    private static func testSetting(_ check: Checker) {
        print("\nShift lock: the setting")
        check("on in a new place", StarterPlayerSettings().enableMouseLockOption && SceneModel().starterPlayer.enableMouseLockOption)
        let old = try? JSONDecoder().decode(StarterPlayerSettings.self, from: Data("{\"walkSpeed\": 20}".utf8))
        check("…and in a place saved before there was a setting", old?.enableMouseLockOption == true && old?.walkSpeed == 20)
        var off = StarterPlayerSettings()
        off.enableMouseLockOption = false
        let saved = (try? JSONEncoder().encode(off)).flatMap { try? JSONDecoder().decode(StarterPlayerSettings.self, from: $0) }
        check("a place that turns it off keeps it off", saved?.enableMouseLockOption == false)
        check("on in every sample game and template", PlaceTemplate.allCases.allSatisfy { $0.state().starterPlayer.enableMouseLockOption })

        func lines(_ state: SceneState) -> [String] {
            state.starterGui.filter { $0.name.hasPrefix("Line") }.compactMap {
                if case .string(let text)? = $0.properties["text"] { return text }
                return nil
            }
        }
        let fresh = lines(SceneModel().state)
        check("the controls panel lists it", fresh.contains { $0.hasPrefix("Ctrl") && $0.hasSuffix("shift lock") }, "\(fresh)")
        let adventure = lines(AdventureIsland.state()), nightfall = lines(Nightfall.state()), obby = lines(MegaObby.state())
        check("…and the sample games keep their own keys beside it",
              adventure.contains("E          talk") && nightfall.contains("click      swing, shoot")
              && obby.contains("Q E        stage back, on") && [adventure, nightfall, obby].allSatisfy { list in
                  list.contains { $0.hasPrefix("Ctrl") } && !list.contains { $0.hasPrefix("F          ") }
              }, "\(adventure)")
    }

    private static func testPlaying(_ check: Checker) {
        print("\nShift lock: playing")
        let model = SceneModel()
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        step(session, seconds: 0.5)
        let crosshair = { session.gui.objects.values.first { $0.name == "Crosshair" }?.visible == true }
        check("off to begin with", !session.camera.shiftLock && !session.hud.shiftLock && !crosshair())

        press(session, "LeftControl")
        step(session, seconds: 0.3)
        check("Left Ctrl turns it on, and the pointer is held", session.camera.shiftLock && session.hud.shiftLock)
        check("…so scripts see LockCenter, and the HUD shows its crosshair", crosshair())
        let render = session.renderCamera
        let eye = session.character.eyePosition
        let shoulder = eye + session.camera.right * PlayerCamera.shoulderOffset
        check("the camera looks over the right shoulder", simd_distance(render.target, shoulder) < 0.05,
              "\(render.target) vs \(shoulder)")

        session.look(deltaX: 300, deltaY: 0)
        step(session, seconds: 0.1)
        check("turning the camera turns the body with it", apart(session.character.facingYaw, session.camera.yaw) < 0.01,
              "\(session.character.facingYaw) vs \(session.camera.yaw)")
        let start = session.character.position
        session.key("D", pressed: true)
        step(session, seconds: 0.5)
        session.key("D", pressed: false)
        let moved = session.character.position - start
        check("walking sideways, it strafes, still facing the way the camera looks",
              apart(session.character.facingYaw, session.camera.yaw) < 0.01 && dot(moved, session.camera.right) > 3,
              "\(moved)")

        press(session, "LeftControl")
        step(session, seconds: 0.3)
        check("Left Ctrl again turns it off", !session.camera.shiftLock && !session.hud.shiftLock && !crosshair())
        let facing = session.character.facingYaw
        session.key("D", pressed: true)
        step(session, seconds: 0.5)
        session.key("D", pressed: false)
        check("…and the body turns to the way it walks again", apart(session.character.facingYaw, facing) > 1,
              "\(facing) → \(session.character.facingYaw)")
        check("no errors", said(session, .error).isEmpty, "\(said(session, .error))")
        session.stop()
    }

    private static func testTakenAway(_ check: Checker) {
        print("\nShift lock: taken away")
        let model = SceneModel()
        model.starterPlayer.enableMouseLockOption = false
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        step(session, seconds: 0.3)
        press(session, "LeftControl")
        check("a place with it off ignores Left Ctrl", !session.camera.shiftLock)
        session.stop()

        let scripted = SceneModel()
        var script = ScriptObject.blank(language: .luau)
        script.name = "NoShiftLock"
        script.host = .starterPlayer
        script.source = """
        local player = game:GetService("Players").LocalPlayer
        print("allowed", player.DevEnableMouseLock)
        task.wait(0.5)
        player.DevEnableMouseLock = false
        print("allowed", player.DevEnableMouseLock)
        """
        scripted.scripts.append(script)
        let played = PlayController(model: scripted, console: ScriptConsole())
        played.start()
        step(played, seconds: 0.2)
        press(played, "LeftControl")
        check("scripts read Player.DevEnableMouseLock", said(played).contains("allowed true") && played.camera.shiftLock)
        step(played, seconds: 0.5)
        check("…and setting it false turns shift lock off", said(played).contains("allowed false") && !played.camera.shiftLock)
        press(played, "LeftControl")
        check("…for good", !played.camera.shiftLock)
        check("no errors", said(played, .error).isEmpty, "\(said(played, .error))")
        played.stop()
    }

    private static func testTogether(_ check: Checker) {
        print("\nShift lock: a host and a joined player")
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ _ in }), let robin = hosting.player,
              let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 0.5)
        sam.key("LeftControl", pressed: true)
        LANSelfTest.run([hosting, joining], seconds: 0.05)
        sam.key("LeftControl", pressed: false)
        sam.look(deltaX: 350, deltaY: 0)
        LANSelfTest.run([hosting, joining], seconds: 0.6)
        let seen = robin.avatars.dropFirst().first
        check("a joined player's shift lock is theirs, and the host sees them face their camera",
              sam.camera.shiftLock && !robin.camera.shiftLock
              && seen.map { apart($0.yaw, sam.camera.yaw) < 0.05 } == true,
              "\(String(describing: seen?.yaw)) vs \(sam.camera.yaw)")
        joining.leaveGame()
        hosting.leaveGame()
    }
}
