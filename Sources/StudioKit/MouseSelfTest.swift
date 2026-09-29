import AppKit
import simd

/// Verification for the mouse in play: Player:GetMouse (Hit, Target, buttons),
/// ClickDetectors (hover, click, reach), MouseBehavior, real clicks through the viewport
/// with a free pointer, and a joined player clicking a button on the host.
enum MouseSelfTest {

    static func run(check: Checker) {
        testExtendedAPI(check)
        testLocalMouseState(check)
        testClickDetector(check)
        testViewport(check)
        testClickingOverTheNetwork(check)
    }

    private static let frame: Float = 1.0 / 60

    private static func testLocalMouseState(_ check: Checker) {
        guard let (host, joined) = LANSelfTest.twoPlayers({ model in
            var part = Part(); part.name = "Filter"; model.parts = [part]
            var script = ScriptObject.blank(language: .luau); script.host = .starterPlayer
            script.source = """
            local player = game:GetService("Players").LocalPlayer
            local mouse = player:GetMouse()
            mouse.Icon = if player.Name == "Robin" then "builtin://Hand" else "builtin://Crosshair"
            if player.Name == "Sam" then mouse.TargetFilter = workspace.Filter end
            mouse.Move:Connect(function() print("motion " .. player.Name) end)
            """
            model.scripts.append(script)
        }), let robin = host.player, let sam = joined.player else { check("mouse players join", false); return }
        defer { joined.leaveGame(); host.leaveGame() }
        LANSelfTest.run([host, joined], seconds: 0.1)
        check("host and joined player have independent cursor icons",
              robin.playerInvoke("input.icon", []) == .string("builtin://Hand") && sam.playerInvoke("input.icon", []) == .string("builtin://Crosshair"))
        check("a joined player's filter stays on their machine", robin.mouseFilter == nil && sam.mouseFilter != nil)
        robin.mousePointerMoved(to: SIMD2(10, 20))
        LANSelfTest.run([host, joined], seconds: 0.1)
        check("only the moving player's Move handlers run", lines(robin).contains("motion Robin") && !lines(sam).contains("motion Sam"))
        sam.mousePointerMoved(to: SIMD2(30, 40))
        LANSelfTest.run([host, joined], seconds: 0.1)
        check("the joiner's own Move handler runs", lines(sam).contains("motion Sam"))
        check("extended mouse scripts have no multiplayer errors", lines(robin, .error).isEmpty && lines(sam, .error).isEmpty,
              "\(lines(robin, .error) + lines(sam, .error))")
    }

    private static func testExtendedAPI(_ check: Checker) {
        print("\nMouse: rays, filters, movement and cursors")
        ScriptSelfTest.assertAll(check, "Ray values project onto a half-line and stay finite at zero", preamble: """
        local r = Ray.new(Vector3.new(1, 2, 3), Vector3.new(0, 0, 2))
        local zero = Ray.new(Vector3.zero, Vector3.zero)
        """, [
            "typeof(r) == 'Ray' and r.Origin == Vector3.new(1, 2, 3)",
            "r.Direction == Vector3.new(0, 0, 2) and r.Unit.Direction == Vector3.zAxis",
            "r:ClosestPoint(Vector3.new(5, 2, 5)) == Vector3.new(1, 2, 5)",
            "r:ClosestPoint(Vector3.new(1, 2, -5)) == r.Origin",
            "r:Distance(Vector3.new(5, 2, 5)) == 4",
            "zero.Unit.Direction == Vector3.zero and zero:ClosestPoint(Vector3.one) == Vector3.zero",
            "not pcall(function() r.Origin = Vector3.zero end)",
            "not pcall(function() Ray.new('wrong', Vector3.zero) end)"
        ])
        let model = SceneModel()
        model.clearScene()
        model.scripts = []
        var front = Part(); front.name = "Front"; front.position = Vec3(0, 3, -8)
        var back = Part(); back.name = "Back"; back.position = Vec3(0, 3, -14)
        front.size = Vec3(8, 8, 1); back.size = front.size
        model.parts = [front, back]
        var script = ScriptObject.blank(language: .luau)
        script.host = .starterPlayer
        script.source = """
        local m = game:GetService("Players").LocalPlayer:GetMouse()
        m.Move:Connect(function() print("moved") end)
        local ray = m.UnitRay
        print("unit ray", typeof(ray) == "Ray", math.abs(ray.Direction.Magnitude - 1) < 0.0001)
        m.TargetFilter = workspace.Front
        print("filtered", m.Target == workspace.Back, m.TargetFilter == workspace.Front)
        m.TargetFilter = nil
        print("cleared", m.Target == workspace.Front)
        m.TargetFilter = workspace
        print("all filtered", m.Target == nil)
        m.TargetFilter = nil
        m.Icon = "builtin://Crosshair"
        print("icon", m.Icon)
        print("typed", not pcall(function() m.TargetFilter = 1 end), not pcall(function() m.Icon = {} end))
        """
        model.scripts = [script]
        let session = PlayController(model: model, console: ScriptConsole())
        session.viewSize = SIMD2(800, 600)
        session.pointer = SIMD2(400, 300)
        session.start()
        // Put both targets along this session's actual camera ray, nearest first.
        if let ray = session.mouseRay() {
            model.update(id: front.id) { $0.position = ray.origin + ray.direction * 15 }
            model.update(id: back.id) { $0.position = ray.origin + ray.direction * 25 }
        }
        session.scripts.start()
        run(session, seconds: 0.05)
        let output = lines(session)
        check("UnitRay is normalized", output.contains("unit ray true true"), "\(output)")
        check("TargetFilter excludes one part, nil restores it, Workspace excludes all",
              output.contains("filtered true true") && output.contains("cleared true") && output.contains("all filtered true"), "\(output)")
        check("mouse properties validate their types", output.contains("typed true true"), "\(output)")
        check("a cursor icon reaches the play host", session.playerInvoke("input.icon", []) == .string("builtin://Crosshair"))
        let folder = SceneGroup(name: "Filtered", kind: .folder)
        model.groups.append(folder)
        model.setParent(front.id, folder.id)
        session.mouseFilter = folder.id.uuidString
        check("TargetFilter excludes a Model or Folder's descendants", session.mouseTarget()?.part.id == back.id)
        model.setParent(front.id, nil)
        check("TargetFilter follows reparenting immediately", session.mouseTarget()?.part.id == front.id)
        model.removeSubtrees([folder.id])
        check("a destroyed filter does not hide unrelated parts", session.mouseTarget()?.part.id == front.id)
        session.mouseFilter = nil
        let before = output.filter { $0 == "moved" }.count
        let view = StudioMTKView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.player = session
        if let event = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 450, y: 320), modifierFlags: [],
                                         timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            view.mouseMoved(with: event)
        }
        run(session, seconds: 0.1)
        check("a real pointer event fires Move once, with no idle repeats", lines(session).filter { $0 == "moved" }.count == before + 1)
        session.mouseCaptured = true
        session.mousePointerMoved(to: nil, delta: SIMD2(3, -2))
        run(session, seconds: 0.03)
        check("relative pointer movement fires Move while captured", lines(session).filter { $0 == "moved" }.count == before + 2)
        view.player = nil
        check("leaving play clears capture and restores the viewport cursor", !session.mouseCaptured && view.playCursor === NSCursor.arrow)
        session.stop()
        let cursors = MouseCursor()
        check("built-in names select native cursors", cursors.resolve("builtin://Hand", assets: []) === NSCursor.pointingHand
              && cursors.resolve("builtin://Crosshair", assets: []) === NSCursor.crosshair)
        let red = SceneAsset(name: "Cursor", kind: .image, data: AudioSelfTest.png(red: 1, green: 0, blue: 0), fileExtension: "png")
        let first = cursors.resolve(red.reference, assets: [red])
        check("an imported picture becomes a cached cursor", first !== NSCursor.arrow && first === cursors.resolve(red.reference, assets: [red]))
        var blue = red; blue.data = AudioSelfTest.png(red: 0, green: 0, blue: 1)
        check("replacing a cursor image invalidates the cached cursor", first !== cursors.resolve(blue.reference, assets: [blue]))
        check("missing and cleared icons use the normal pointer", cursors.resolve("studio://missing", assets: []) === NSCursor.arrow
              && cursors.resolve("", assets: []) === NSCursor.arrow)
    }
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
