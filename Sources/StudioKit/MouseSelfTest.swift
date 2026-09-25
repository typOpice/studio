import AppKit
import simd

/// Verification for the mouse in play: Player:GetMouse (Hit, Target, buttons),
/// ClickDetectors (hover, click, reach), MouseBehavior, real clicks through the viewport
/// with a free pointer, and a joined player clicking a button on the host.
enum MouseSelfTest {

    static func run(check: Checker) {
        testClickDetector(check)
        testViewport(check)
        testClickingOverTheNetwork(check)
    }

    private static let frame: Float = 1.0 / 60
    static let viewSize = CGSize(width: 800, height: 600)

    /// A button's script: a ClickDetector (connected before it has a part) and the Mouse.
    static let buttonScript = """
    local button = workspace.Button
    local detector = Instance.new("ClickDetector")
    detector.MaxActivationDistance = 20
    detector.MouseClick:Connect(function(player)
    \tprint("clicked by " .. player.Name)
    end)
    detector.MouseHoverEnter:Connect(function(player)
    \tprint("hover in " .. player.Name)
    end)
    detector.MouseHoverLeave:Connect(function(player)
    \tprint("hover out " .. player.Name)
    end)
    detector.Parent = button
    print("detector", button.ClickDetector == detector, button:FindFirstChildOfClass("ClickDetector") == detector,
    \tdetector.MaxActivationDistance, detector.Parent == button)
    """

    static func buttonPart() -> Part {
        var button = Part()
        button.name = "Button"
        button.size = Vec3(3, 3, 1)
        button.position = Vec3(0, 3, -40)
        return button
    }

    /// Puts the button in front of a player's camera, just beyond their character, and
    /// the pointer on it.
    static func aim(_ session: PlayController, at id: UUID, model: SceneModel) {
        let camera = session.renderCamera
        let ahead = normalize(camera.target - camera.position)
        model.update(id: id) { $0.position = camera.target + ahead * 8 }
        session.viewSize = SIMD2(Float(viewSize.width), Float(viewSize.height))
        if let point = session.screenPoint(of: camera.target + ahead * 8, in: viewSize) {
            session.pointer = SIMD2(Float(point.x), Float(point.y))
        }
    }

    private static func run(_ session: PlayController, seconds: Float) {
        var elapsed: Float = 0
        while elapsed < seconds - frame / 2 {
            session.step(dt: frame)
            elapsed += frame
        }
    }

    private static func lines(_ session: PlayController, _ kind: ScriptConsole.Kind = .output) -> [String] {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        return session.console.lines.filter { $0.kind == kind }.map(\.text)
    }

    private static func scene() -> (SceneModel, UUID) {
        let model = SceneModel()
        model.parts = []
        model.scripts = []
        model.shaders = []
        model.groups = []
        let button = buttonPart()
        model.parts = [button]
        var control = ScriptObject.blank(language: .luau)
        control.name = "ControlScript"
        control.host = .starterPlayer
        control.enabled = false
        var script = ScriptObject.blank(language: .luau)
        script.source = buttonScript
        var mouse = ScriptObject.blank(language: .luau)
        mouse.host = .starterPlayer
        mouse.source = """
        local UserInputService = game:GetService("UserInputService")
        local mouse = game:GetService("Players").LocalPlayer:GetMouse()
        mouse.Button1Down:Connect(function()
        \tlocal target = mouse.Target
        \tprint("mouse on " .. (if target then target.Name else "nothing"),
        \t\tmath.abs(mouse.Hit.Position.Z - target.Position.Z) < 1, mouse.X > 0, mouse.ViewSizeX)
        end)
        UserInputService.InputBegan:Connect(function(input)
        \tif input.KeyCode == Enum.KeyCode.L then
        \t\tUserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
        \t\tprint("behaviour", UserInputService.MouseBehavior.Name)
        \telseif input.KeyCode == Enum.KeyCode.U then
        \t\tUserInputService.MouseBehavior = Enum.MouseBehavior.Default
        \tend
        end)
        """
        model.scripts = [control, script, mouse]
        return (model, button.id)
    }

    private static func testClickDetector(_ check: Checker) {
        print("\nMouse: ClickDetectors and the Mouse")
        let (model, button) = scene()
        let session = PlayController(model: model, console: ScriptConsole())
        session.playerName = "Robin"
        session.start()
        run(session, seconds: 0.2)
        check("a ClickDetector goes in its part, with what was connected before",
              lines(session).contains("detector true true 20 true") && model.part(id: button)?.clickDetector != nil,
              "\(lines(session)) \(lines(session, .error))")

        aim(session, at: button, model: model)
        run(session, seconds: 0.1)
        check("pointing at it fires MouseHoverEnter with the player", lines(session).contains("hover in Robin"),
              "\(lines(session))")
        check("…and the Mouse's Target is the part", session.mouseTarget()?.part.id == button)
        session.mouseButton(1, pressed: true)
        run(session, seconds: 0.05)
        session.mouseButton(1, pressed: false)
        run(session, seconds: 0.05)
        check("a click fires MouseClick with the player who clicked", lines(session).contains("clicked by Robin"),
              "\(lines(session))")
        check("…and Button1Down, with the Mouse's Hit on the part", lines(session).contains("mouse on Button true true 800"),
              "\(lines(session))")

        session.pointer = SIMD2(5, 5)
        run(session, seconds: 0.1)
        check("pointing away fires MouseHoverLeave", lines(session).contains("hover out Robin"))

        model.update(id: button) { $0.clickDetector?.maxActivationDistance = 2 }
        aim(session, at: button, model: model)
        run(session, seconds: 0.1)
        session.mouseButton(1, pressed: true)
        run(session, seconds: 0.05)
        session.mouseButton(1, pressed: false)
        run(session, seconds: 0.05)
        check("out of reach (MaxActivationDistance), a click does nothing",
              lines(session).filter { $0 == "clicked by Robin" }.count == 1)

        session.key("L", pressed: true)
        run(session, seconds: 0.05)
        session.key("L", pressed: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check("a script can lock the pointer (MouseBehavior)", session.hud.mouseLock
              && lines(session).contains("behaviour LockCenter"))
        session.key("U", pressed: true)
        run(session, seconds: 0.05)
        session.key("U", pressed: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check("…and free it again", !session.hud.mouseLock)
        let errors = lines(session, .error)
        check("none of it raised an error", errors.isEmpty, errors.joined(separator: " | "))
        session.stop()
    }

    /// Real mouse events: in third person the pointer is free and a click clicks.
    private static func testViewport(_ check: Checker) {
        print("\nMouse: through the viewport")
        let (model, button) = scene()
        let session = PlayController(model: model, console: ScriptConsole())
        session.playerName = "Robin"
        session.start()
        run(session, seconds: 0.2)
        let view = StudioMTKView(frame: NSRect(origin: .zero, size: viewSize))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.showsWorld = false
        view.player = session
        view.showsWorld = true
        aim(session, at: button, model: model)
        guard let point = session.pointer else {
            check("the button is on screen", false)
            return
        }
        session.pointer = nil
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: CGFloat(point.x), y: viewSize.height - CGFloat(point.y)),
                               modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: mouse(.leftMouseDown))
        run(session, seconds: 0.05)
        view.mouseUp(with: mouse(.leftMouseUp))
        run(session, seconds: 0.05)
        check("in third person the pointer stays free", !session.mouseCaptured)
        check("…and a click where it is clicks what's there", lines(session).contains("clicked by Robin")
              && session.pointer.map { simd_distance($0, point) < 1 } == true, "\(lines(session))")
        view.player = nil
        window.contentView = nil
        session.stop()
    }

    private static func testClickingOverTheNetwork(_ check: Checker) {
        print("\nMouse: clicking in a network game")
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            model.parts.append(buttonPart())
            var script = ScriptObject.blank(language: .luau)
            script.source = buttonScript
            model.scripts.append(script)
        }), let robin = hosting.player, let sam = joining.player,
            let button = hosting.model.parts.first(where: { $0.name == "Button" })?.id else {
            check("two players share a game", false)
            return
        }
        func said() -> [String] {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            return robin.console.lines.filter { $0.kind == .output }.map(\.text)
        }
        robin.character.position = Vec3(-60, 0, 0)
        LANSelfTest.run([hosting, joining], seconds: 0.3)
        // The host moves the button in front of Sam's camera.
        let camera = sam.renderCamera
        let ahead = normalize(camera.target - camera.position)
        hosting.model.update(id: button) { $0.position = camera.target + ahead * 8 }
        LANSelfTest.run([hosting, joining], seconds: 0.3)
        sam.viewSize = SIMD2(Float(viewSize.width), Float(viewSize.height))
        if let point = sam.screenPoint(of: camera.target + ahead * 8, in: viewSize) {
            sam.pointer = SIMD2(Float(point.x), Float(point.y))
        }
        LANSelfTest.run([hosting, joining], seconds: 0.2)
        check("a joined player hovering a ClickDetector is heard by the host", said().contains("hover in Sam"),
              "\(said())")
        sam.mouseButton(1, pressed: true)
        LANSelfTest.run([hosting, joining], seconds: 0.1)
        sam.mouseButton(1, pressed: false)
        LANSelfTest.run([hosting, joining], seconds: 0.1)
        check("…and their click fires MouseClick there, with them as the player", said().contains("clicked by Sam"),
              "\(said())")
        let errors = (robin.console.lines + sam.console.lines).filter { $0.kind == .error }.map(\.text)
        check("none of it raised an error", errors.isEmpty, errors.joined(separator: " | "))
        joining.leaveGame()
        hosting.leaveGame()
    }
}
