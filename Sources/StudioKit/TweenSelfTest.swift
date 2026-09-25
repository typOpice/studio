import Foundation
import simd

/// Verification for TweenService:Create and TweenInfo: timing, easing, repeats and
/// reversing, pausing, cancelling, one tween taking over from another, GUI values, the
/// errors, and a host's tween reaching a joined player.
enum TweenSelfTest {

    static func run(check: Checker) {
        testTweens(check)
        testTweenErrors(check)
        testTweenInMultiplayer(check)
    }

    private static let frame: Float = 1.0 / 60

    private static func play(_ source: String) -> PlayController {
        let model = SceneModel()
        model.parts = []
        model.scripts = []
        model.shaders = []
        var script = ScriptObject.blank(language: .luau)
        script.source = source
        model.scripts = [script]
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        return session
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

    private static func part(_ session: PlayController, _ name: String) -> Part? {
        session.model.parts.first { $0.name == name }
    }

    private static func testTweens(_ check: Checker) {
        print("\nTweens: TweenService:Create")
        let session = play("""
        local TweenService = game:GetService("TweenService")
        local function block(name, x)
        \tlocal part = Instance.new("Part")
        \tpart.Name = name
        \tpart.Anchored = true
        \tpart.Position = Vector3.new(x, 5, 0)
        \tpart.Parent = workspace
        \treturn part
        end

        local slide = block("Slide", 0)
        local info = TweenInfo.new(1, Enum.EasingStyle.Linear)
        print("info", info.Time, info.EasingStyle.Name, info.EasingDirection.Name, info.RepeatCount,
        \tinfo.Reverses, info.DelayTime, typeof(info))
        local tween = TweenService:Create(slide, info, {
        \tPosition = Vector3.new(10, 5, 0),
        \tTransparency = 1,
        \tColor = Color3.new(1, 0, 0),
        })
        print("before", tween.PlaybackState.Name, tween.Instance == slide, tween:IsA("TweenBase"))
        tween.Completed:Connect(function(state)
        \tprint("slide " .. state.Name)
        end)
        tween:Play()

        local eased = block("Eased", 0)
        TweenService:Create(eased, TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
        \t{ Position = Vector3.new(10, 5, 0) }):Play()

        local bounce = block("Bounce", 0)
        local back = TweenService:Create(bounce, TweenInfo.new(0.5, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, 1, true),
        \t{ Position = Vector3.new(10, 5, 0) })
        back.Completed:Connect(function(state)
        \tprint("bounce " .. state.Name)
        end)
        back:Play()

        local later = block("Later", 0)
        local delayed = TweenService:Create(later, TweenInfo.new(0.5, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, 0, false, 0.5),
        \t{ Position = Vector3.new(10, 5, 0) })
        delayed:Play()
        print("delayed", delayed.PlaybackState.Name)

        local paused = block("Paused", 0)
        local pausing = TweenService:Create(paused, TweenInfo.new(1, Enum.EasingStyle.Linear), { Position = Vector3.new(10, 5, 0) })
        pausing:Play()

        local cancelled = block("Cancelled", 0)
        local cancelling = TweenService:Create(cancelled, TweenInfo.new(1, Enum.EasingStyle.Linear), { Position = Vector3.new(10, 5, 0) })
        cancelling.Completed:Connect(function(state)
        \tprint("cancelled " .. state.Name)
        end)
        cancelling:Play()

        local taken = block("Taken", 0)
        local first = TweenService:Create(taken, TweenInfo.new(1), { Position = Vector3.new(10, 5, 0) })
        first.Completed:Connect(function(state)
        \tprint("first " .. state.Name)
        end)
        first:Play()

        local screen = Instance.new("ScreenGui")
        local panel = Instance.new("Frame", screen)
        panel.Name = "Panel"
        screen.Parent = game:GetService("Players").LocalPlayer.PlayerGui
        TweenService:Create(panel, TweenInfo.new(0.5, Enum.EasingStyle.Linear), {
        \tPosition = UDim2.new(1, -100, 0, 50),
        \tBackgroundTransparency = 0.5,
        }):Play()

        task.wait(0.25)
        pausing:Pause()
        print("paused", pausing.PlaybackState.Name)
        cancelling:Cancel()
        TweenService:Create(taken, TweenInfo.new(0.25), { Position = Vector3.new(-10, 5, 0) }):Play()
        task.wait(0.5)
        pausing:Play()
        """)
        run(session, seconds: 0.5)
        let x = { (name: String) in part(session, name)?.position.x ?? -99 }
        check("TweenInfo keeps what it was given, with Roblox's defaults",
              lines(session).contains("info 1 Linear Out 0 false 0 TweenInfo"), "\(lines(session))")
        check("a tween starts in Begin", lines(session).contains("before Begin true true"), "\(lines(session))")
        check("halfway through, a linear tween is halfway", abs(x("Slide") - 5) < 0.2, "\(x("Slide"))")
        check("…and an eased one follows its curve (Quad In: a quarter)", abs(x("Eased") - 2.5) < 0.3, "\(x("Eased"))")
        check("a delayed tween waits, in Delayed", lines(session).contains("delayed Delayed") && x("Later") < 0.01,
              "\(x("Later"))")
        check("Pause holds a tween where it is", lines(session).contains("paused Paused") && abs(x("Paused") - 2.5) < 0.2,
              "\(x("Paused"))")
        check("Cancel stops it there and fires Completed with Cancelled",
              lines(session).contains("cancelled Cancelled") && abs(x("Cancelled") - 2.5) < 0.2, "\(x("Cancelled"))")
        check("a new tween on the same property takes over, cancelling the old one",
              lines(session).contains("first Cancelled"), "\(lines(session))")
        let panel = session.gui.objects.values.first { $0.name == "Panel" }
        check("GUI values tween too: UDim2 and numbers",
              panel.map { abs($0.position.xScale - 1) < 0.001 && $0.position.xOffset == -100 && $0.backgroundTransparency == 0.5 } ?? false,
              "\(String(describing: panel?.position))")

        run(session, seconds: 0.15)
        check("a paused tween stays put until played again", abs(x("Paused") - 2.5) < 0.2, "\(x("Paused"))")
        run(session, seconds: 0.4)
        let slide = part(session, "Slide")
        check("at the end, the goals are reached exactly",
              slide?.position == Vec3(10, 5, 0) && slide?.transparency == 1 && slide?.color == Vec3(1, 0, 0),
              "\(String(describing: slide?.position))")
        check("…and Completed fires with Completed", lines(session).contains("slide Completed"))
        check("a delayed tween runs once its delay is over", abs(x("Later") - 10) < 0.001, "\(x("Later"))")
        check("the tween that took over finished where it was going", abs(x("Taken") + 10) < 0.001, "\(x("Taken"))")
        check("…then carries on from there", x("Paused") > 3 && x("Paused") < 10, "\(x("Paused"))")

        run(session, seconds: 1.2)
        check("Reverses with a repeat goes there and back twice, ending where it began",
              lines(session).contains("bounce Completed") && abs(x("Bounce")) < 0.001, "\(x("Bounce"))")
        let errors = lines(session, .error)
        check("…with no errors", errors.isEmpty, errors.joined(separator: " | "))
        session.stop()
    }

    private static func testTweenErrors(_ check: Checker) {
        print("\nTweens: mistakes")
        let session = play("""
        local TweenService = game:GetService("TweenService")
        local part = Instance.new("Part")
        part.Parent = workspace
        local info = TweenInfo.new(1)
        local function says(f)
        \tlocal ok, message = pcall(f)
        \treturn if ok then "no error" else tostring(message)
        end
        print(says(function() TweenService:Create(part, info, { Name = "x" }) end))
        print(says(function() TweenService:Create(part, info, { Nonsense = 1 }) end))
        print(says(function() TweenService:Create(part, info, { Position = 5 }) end))
        print(says(function() TweenService:Create(part, 1, {}) end))
        print(says(function() TweenInfo.new(1, Enum.Material.Plastic) end))
        print(says(function() info.Time = 5 end))
        local gone = Instance.new("Part")
        gone.Parent = workspace
        local tween = TweenService:Create(gone, TweenInfo.new(1), { Transparency = 1 })
        tween.Completed:Connect(function(state)
        \tprint("gone " .. state.Name)
        end)
        tween:Play()
        task.wait(0.1)
        gone:Destroy()
        """)
        run(session, seconds: 1.2)
        let said = lines(session)
        check("only numbers, booleans, vectors, colours, CFrames and UDims tween",
              said.count >= 3 && said[0].contains("can't be tweened") && said[2].contains("can't be tweened"), "\(said)")
        check("a property the instance doesn't have is an error", said.count > 1 && said[1].contains("not a property"), "\(said)")
        check("Create wants a TweenInfo; TweenInfo wants enums", said.count > 4 && said[3].contains("TweenInfo")
              && said[4].contains("EasingStyle"), "\(said)")
        check("a TweenInfo can't be changed", said.count > 5 && said[5] != "no error", "\(said)")
        check("a tween on something destroyed runs out quietly, as in Roblox",
              said.contains("gone Completed") && lines(session, .error).isEmpty,
              "\(said) \(lines(session, .error))")
        session.stop()
    }

    private static func testTweenInMultiplayer(_ check: Checker) {
        print("\nTweens: in multiplayer")
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            var door = Part()
            door.name = "Door"
            door.position = Vec3(0, 5, 30)
            model.parts = [door]
            var script = ScriptObject.blank(language: .luau)
            script.source = """
            local TweenService = game:GetService("TweenService")
            TweenService:Create(workspace.Door, TweenInfo.new(0.5, Enum.EasingStyle.Linear),
            \t{ Position = Vector3.new(0, 15, 30), Transparency = 0.5 }):Play()
            """
            model.scripts.append(script)
        }) else {
            check("two players share a game", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 0.25)
        let hostDoor = hosting.model.parts.first { $0.name == "Door" }
        let seen = joining.model.parts.first { $0.name == "Door" }
        check("a host script's tween moves the part for the joined player too",
              (seen?.position.y ?? 0) > 6 && seen?.position == hostDoor?.position,
              "\(String(describing: seen?.position)) vs \(String(describing: hostDoor?.position))")
        LANSelfTest.run([hosting, joining], seconds: 0.5)
        let arrived = joining.model.parts.first { $0.name == "Door" }
        check("…to the end, exactly", arrived?.position == Vec3(0, 15, 30) && arrived?.transparency == 0.5,
              "\(String(describing: arrived?.position))")
        joining.leaveGame()
        hosting.leaveGame()
    }
}
