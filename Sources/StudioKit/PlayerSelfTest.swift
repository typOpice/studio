import Foundation
import simd

/// Verification for the scriptable player: StarterPlayer settings, the Humanoid, the
/// default ControlScript and Health scripts, respawning, and the Luau API over them.
/// Every session here runs through `PlayController.step`, exactly as the client does.
enum PlayerSelfTest {

    static func run(check: Checker) {
        testDefaultControls(check)
        testScriptsOwnTheControls(check)
        testJumping(check)
        testHealthAndRespawn(check)
        testCharacterScripts(check)
        testAppearance(check)
        testInputAndStates(check)
        testPlayerSettings(check)
        testSaving(check)
        testReadmeExample(check)
        testTouching(check)
        testTouchProperties(check)
        testTouchReadmeExamples(check)
    }

    /// The kill brick and coin from the README, verbatim, attached to their parts.
    private static func testTouchReadmeExamples(_ check: Checker) {
        print("\nPlayer: the README touch examples")
        let model = world()
        let brick = block("KillBrick", at: Vec3(40, 0.5, 40), size: Vec3(6, 1, 6))
        let coin = block("Coin", at: Vec3(-40, 2, -40), size: Vec3(1, 1, 1), canCollide: false)
        model.parts = [brick, coin]
        add(model, "", name: "ControlScript", host: .starterPlayer, enabled: false)
        var kill = ScriptObject.blank(language: .luau)
        kill.parentID = brick.id
        kill.source = """
        script.Parent.Touched:Connect(function(hit)
        \tlocal humanoid = hit.Parent:FindFirstChild("Humanoid")
        \tif humanoid then
        \t\thumanoid.Health = 0
        \tend
        end)
        """
        var pickup = ScriptObject.blank(language: .luau)
        pickup.parentID = coin.id
        pickup.source = """
        local coin = script.Parent
        coin.Touched:Connect(function(hit)
        \tif game:GetService("Players"):GetPlayerFromCharacter(hit.Parent) then
        \t\tcoin:Destroy()
        \tend
        end)
        """
        model.scripts += [kill, pickup]
        let session = play(model)
        place(session, at: Vec3(-40, 0, -40))
        check("the coin is collected", !session.model.parts.contains { $0.id == coin.id } && problems(session).isEmpty,
              problems(session))
        check("the player is alive after the coin", !session.humanoid.isDead)
        place(session, at: Vec3(40, 1, 40))
        run(session, seconds: 0.1)
        check("the kill brick kills", session.humanoid.isDead && problems(session).isEmpty, problems(session))
        session.stop()
    }

    private static func block(_ name: String, at position: Vec3, size: Vec3,
                              canCollide: Bool = true, canTouch: Bool = true) -> Part {
        var part = Part()
        part.name = name
        part.position = position
        part.size = size
        part.canCollide = canCollide
        part.canTouch = canTouch
        return part
    }

    /// Forgets what was printed so far, then puts the character somewhere and lets it settle.
    private static func place(_ session: PlayController, at position: Vec3) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        session.console.clear()
        session.character.position = position
        session.character.velocity = .zero
        run(session, seconds: 0.2)
    }

    private static func testTouching(_ check: Checker) {
        print("\nPlayer: touching the world")
        let model = world()
        model.parts = [
            block("Pad", at: Vec3(40, 0.5, 40), size: Vec3(6, 1, 6)),
            block("Ghost", at: Vec3(-40, 3, -46), size: Vec3(10, 6, 1), canCollide: false),
            block("Quiet", at: Vec3(-40, 3, 40), size: Vec3(10, 6, 1), canCollide: false, canTouch: false),
            block("Coin", at: Vec3(40, 2, -40), size: Vec3(1, 1, 1), canCollide: false),
            block("Lava", at: Vec3(80, 0.5, 80), size: Vec3(6, 1, 6)),
        ]
        add(model, "", name: "ControlScript", host: .starterPlayer, enabled: false)
        add(model, """
        local Players = game:GetService("Players")
        local pad = workspace.Pad
        pad.Touched:Connect(function(hit)
            print("pad", hit.Name, hit.Parent.Name, Players:GetPlayerFromCharacter(hit.Parent) == Players.LocalPlayer,
                hit:IsA("BasePart"))
        end)
        pad.TouchEnded:Connect(function(hit) print("left pad", hit.Name) end)
        workspace.Ghost.Touched:Connect(function(hit) print("ghost", hit.Name) end)
        workspace.Ghost.TouchEnded:Connect(function(hit) print("ghost ended", hit.Name) end)
        workspace.Quiet.Touched:Connect(function(hit) print("quiet", hit.Name) end)
        workspace.Coin.Touched:Connect(function(hit)
            if Players:GetPlayerFromCharacter(hit.Parent) then
                print("coin", hit.Name)
                workspace.Coin:Destroy()
            end
        end)
        workspace.Coin.TouchEnded:Connect(function() print("coin ended") end)
        workspace.Lava.Touched:Connect(function(hit)
            local humanoid = hit.Parent:FindFirstChild("Humanoid")
            if humanoid then humanoid.Health = 0 end
        end)
        workspace.Lava.TouchEnded:Connect(function(hit) print("lava ended", hit.Name) end)
        local function watch(character)
            character.Humanoid.Touched:Connect(function(part, limb) print("humanoid", part.Name, limb.Name) end)
            character.Torso.Touched:Connect(function(part) print("torso", part.Name) end)
        end
        watch(Players.LocalPlayer.Character)
        Players.LocalPlayer.CharacterAdded:Connect(watch)
        """)
        let session = play(model)
        check("touch scripts start", problems(session).isEmpty, problems(session))

        place(session, at: Vec3(40, 1, 40))
        run(session, seconds: 0.5)
        let standing = lines(session)
        check("standing on a part touches it with both legs",
              standing.filter { $0.hasPrefix("pad ") } == ["pad Left Leg Player true true", "pad Right Leg Player true true"],
              "\(standing) \(problems(session))")
        check("Humanoid.Touched says which part and which limb",
              standing.contains("humanoid Pad Left Leg") && standing.contains("humanoid Pad Right Leg"), "\(standing)")
        check("…once, not every frame", standing.filter { $0.hasPrefix("pad ") }.count == 2, "\(standing)")

        place(session, at: Vec3(0, 0, 0))
        let off = lines(session)
        check("stepping off ends the touch", Set(off.filter { $0.hasPrefix("left pad") })
              == ["left pad Left Leg", "left pad Right Leg"], "\(off)")

        // Walk straight through a part that doesn't collide.
        place(session, at: Vec3(-40, 0, -40))
        session.humanoid.moveDirection = Vec3(0, 0, -1)
        run(session, seconds: 1.2)
        session.humanoid.moveDirection = .zero
        run(session, seconds: 0.1)
        let ghost = lines(session)
        check("CanCollide off lets the player walk through", session.character.position.z < -52,
              "\(session.character.position)")
        check("and it still reports the touch", ghost.contains("ghost Torso") && ghost.contains("ghost Head"), "\(ghost)")
        check("then its end", ghost.contains("ghost ended Torso"), "\(ghost)")
        check("a body part's own Touched fires", ghost.contains("torso Ghost"), "\(ghost)")

        place(session, at: Vec3(-40, 0, 46))
        session.humanoid.moveDirection = Vec3(0, 0, -1)
        run(session, seconds: 0.8)
        session.humanoid.moveDirection = .zero
        check("CanTouch off reports nothing", !lines(session).contains { $0.hasPrefix("quiet") }, "\(lines(session))")

        place(session, at: Vec3(40, 0, -37))
        session.humanoid.moveDirection = Vec3(0, 0, -1)
        run(session, seconds: 0.4)
        session.humanoid.moveDirection = .zero
        run(session, seconds: 0.2)
        let coin = lines(session)
        check("a pickup can destroy itself when touched",
              coin.filter { $0.hasPrefix("coin ") }.count == 1 && !session.model.parts.contains { $0.name == "Coin" },
              "\(coin) \(problems(session))")
        check("a destroyed part reports no TouchEnded", !coin.contains("coin ended"), "\(coin)")
        check("and nothing errors", problems(session).isEmpty, problems(session))

        place(session, at: Vec3(80, 1, 80))
        run(session, seconds: 0.2)
        let lava = lines(session)
        check("a kill brick kills", session.humanoid.isDead, "\(lava) \(problems(session))")
        check("a dead character stops touching", lava.contains("lava ended Left Leg"), "\(lava)")

        run(session, seconds: 5.5)
        place(session, at: Vec3(40, 1, 40))
        check("a new character touches too, through its own connections",
              session.characterGeneration == 2 && lines(session).contains("humanoid Pad Left Leg"),
              "\(lines(session)) gen \(session.characterGeneration)")
        session.stop()
    }

    private static func testTouchProperties(_ check: Checker) {
        print("\nPlayer: CanCollide and CanTouch")
        let model = world()
        model.parts = [block("Door", at: Vec3(30, 3, 30), size: Vec3(6, 6, 1))]
        add(model, """
        local door = workspace.Door
        print(door.CanCollide, door.CanTouch)
        door.CanCollide = false
        door.CanTouch = false
        print(door.CanCollide, door.CanTouch, typeof(door.Touched))
        print(pcall(function() door.CanCollide = 1 end))
        print(pcall(function() door.Touched = nil end))
        """)
        let session = play(model)
        let out = lines(session)
        check("scripts read and write CanCollide and CanTouch",
              Array(out.prefix(2)) == ["true true", "false false RBXScriptSignal"], "\(out) \(problems(session))")
        check("…type-checked", out.count > 2 && out[2].contains("bool expected, got number"), "\(out)")
        check("…and Touched cannot be replaced", out.count > 3 && out[3].contains("read only"), "\(out)")
        check("the part is changed", model.parts[0].canCollide == false && model.parts[0].canTouch == false)
        session.stop()

        var part = Part()
        part.canCollide = false
        let data = try? JSONEncoder().encode(part)
        let back = data.flatMap { try? JSONDecoder().decode(Part.self, from: $0) }
        check("CanCollide and CanTouch are saved", back == part && back?.canCollide == false && back?.canTouch == true)
        let old = try? JSONDecoder().decode(Part.self, from: Data(#"{"name":"Old"}"#.utf8))
        check("older files collide and touch", old?.canCollide == true && old?.canTouch == true)
    }

    /// The example in the README's "The player character" section, verbatim.
    private static func testReadmeExample(_ check: Checker) {
        print("\nPlayer: the README example")
        let model = world()
        add(model, """
        local humanoid = script.Parent:WaitForChild("Humanoid")
        humanoid.WalkSpeed = 24
        humanoid.JumpPower = 80

        humanoid.Died:Connect(function()
        \tprint("Oof")
        end)

        humanoid.StateChanged:Connect(function(old, new)
        \tif new == Enum.HumanoidStateType.Landed then
        \t\tscript.Parent.Torso.Color = Color3.fromHSV(math.random(), 0.6, 0.9)
        \tend
        end)
        """, name: "LowGravityRunner", host: .starterCharacter)
        let session = play(model)
        let torso = session.bodyColors.torso
        session.key("Space", pressed: true)
        run(session, seconds: 0.1)
        session.key("Space", pressed: false)
        run(session, seconds: 2)
        _ = session.playerInvoke("humanoid.damage", [.number(1), .number(1000)])
        run(session, seconds: 0.1)
        check("it runs cleanly", problems(session).isEmpty, problems(session))
        check("it changes the Humanoid", session.humanoid.walkSpeed == 24 || session.humanoid.isDead)
        check("landing recolours the torso", session.bodyColors.torso != torso)
        check("dying prints", lines(session).contains("Oof"), "\(lines(session))")
        session.stop()
    }

    // MARK: - Harness

    private static let frame: Float = 1.0 / 60

    private static func world() -> SceneModel {
        let model = SceneModel()
        model.parts = []
        model.scripts = []
        model.shaders = []
        model.starterPlayer = StarterPlayerSettings()
        return model
    }

    @discardableResult
    private static func add(_ model: SceneModel, _ source: String, name: String = "Test",
                            host: ScriptHost = .scene, enabled: Bool = true) -> ScriptObject {
        var script = ScriptObject.blank(language: .luau)
        script.name = name
        script.source = source
        script.host = host
        script.enabled = enabled
        model.scripts.append(script)
        return script
    }

    /// Starts a session and lets the character settle onto the ground.
    private static func play(_ model: SceneModel) -> PlayController {
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        run(session, seconds: 0.5)
        return session
    }

    private static func run(_ session: PlayController, seconds: Float) {
        var elapsed: Float = 0
        while elapsed < seconds {
            session.step(dt: frame)
            elapsed += frame
        }
    }

    /// The highest the feet reach over `seconds`, relative to where they started.
    private static func peak(_ session: PlayController, seconds: Float) -> Float {
        let start = session.character.position.y
        var best: Float = 0
        var elapsed: Float = 0
        while elapsed < seconds {
            session.step(dt: frame)
            best = max(best, session.character.position.y - start)
            elapsed += frame
        }
        return best
    }

    private static func lines(_ session: PlayController, _ kind: ScriptConsole.Kind = .output) -> [String] {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        return session.console.lines.filter { $0.kind == kind }.map(\.text)
    }

    private static func problems(_ session: PlayController) -> String {
        lines(session, .error).joined(separator: " | ")
    }

    private static func near(_ a: Float, _ b: Float, _ tolerance: Float) -> Bool { abs(a - b) <= tolerance }

    // MARK: - Tests

    private static func testDefaultControls(_ check: Checker) {
        print("\nPlayer: the default ControlScript")
        let session = play(world())
        check("the core scripts start cleanly", problems(session).isEmpty, problems(session))

        let start = session.character.position
        session.key("W", pressed: true)
        run(session, seconds: 1)
        check("holding W walks, through ControlScript and the Humanoid",
              length(session.character.position - start) > 10, "\(session.character.position)")
        check("at the Humanoid's WalkSpeed", near(session.character.horizontalSpeed, 16, 0.5),
              "\(session.character.horizontalSpeed)")

        session.key("LeftShift", pressed: true)
        run(session, seconds: 0.3)
        check("Shift sprints by raising WalkSpeed", near(session.humanoid.walkSpeed, 16 * 1.9, 0.01),
              "\(session.humanoid.walkSpeed)")
        check("and the body follows", near(session.character.horizontalSpeed, 16 * 1.9, 0.6),
              "\(session.character.horizontalSpeed)")
        session.key("LeftShift", pressed: false)
        run(session, seconds: 0.1)
        check("letting go puts WalkSpeed back", session.humanoid.walkSpeed == 16, "\(session.humanoid.walkSpeed)")

        session.key("W", pressed: false)
        run(session, seconds: 0.5)
        check("letting go of W stops", session.character.horizontalSpeed < 0.1, "\(session.character.horizontalSpeed)")

        session.key("F", pressed: true)
        session.key("F", pressed: false)
        run(session, seconds: 0.1)
        check("F is no key of the ControlScript's", session.humanoid.state != .flying, "\(session.humanoid.state)")
        session.stop()
        // F is the default HUD's: its FlyAndRespawn script, in StarterGui.
        let withHud = world()
        let hud = DefaultHud.make()
        withHud.starterGui = hud.objects
        withHud.scripts += hud.scripts
        let flyer = play(withHud)
        flyer.key("F", pressed: true)
        flyer.key("F", pressed: false)
        run(flyer, seconds: 0.1)
        check("F switches to flying, through the default HUD's FlyAndRespawn script",
              flyer.humanoid.state == .flying, "\(flyer.humanoid.state)")
        let height = flyer.character.position.y
        flyer.key("Space", pressed: true)
        run(flyer, seconds: 0.5)
        flyer.key("Space", pressed: false)
        check("Space climbs while flying", flyer.character.position.y > height + 3, "\(flyer.character.position.y)")
        flyer.stop()
    }

    private static func testScriptsOwnTheControls(_ check: Checker) {
        print("\nPlayer: scripts own the controls")
        let off = world()
        add(off, "", name: "ControlScript", host: .starterPlayer, enabled: false)
        let still = play(off)
        let start = still.character.position
        still.key("W", pressed: true)
        run(still, seconds: 1)
        check("a disabled ControlScript switches the default controls off",
              length(still.character.position - start) < 0.01, "\(still.character.position)")
        still.stop()

        let own = world()
        add(own, """
        local humanoid = game:GetService("Players").LocalPlayer.Character:WaitForChild("Humanoid")
        humanoid.WalkSpeed = 8
        game:GetService("RunService").Heartbeat:Connect(function()
            humanoid:Move(Vector3.new(1, 0, 0))
        end)
        """, name: "ControlScript", host: .starterPlayer)
        let steered = play(own)
        run(steered, seconds: 1)
        check("a replacement ControlScript drives the Humanoid", problems(steered).isEmpty, problems(steered))
        check("Move sets the direction", simd_distance(steered.humanoid.moveDirection, Vec3(1, 0, 0)) < 1e-4,
              "\(steered.humanoid.moveDirection)")
        check("at the WalkSpeed the script chose", near(steered.character.velocity.x, 8, 0.3),
              "\(steered.character.velocity)")
        check("AutoRotate turns the body to face the way it walks",
              near(abs(steered.character.facingYaw.truncatingRemainder(dividingBy: 2 * .pi)), .pi / 2, 0.2),
              "\(steered.character.facingYaw)")
        steered.stop()

        let walker = world()
        add(walker, "", name: "ControlScript", host: .starterPlayer, enabled: false)
        add(walker, """
        local humanoid = Players.LocalPlayer.Character.Humanoid
        humanoid.MoveToFinished:Connect(function(reached) print("arrived", reached) end)
        humanoid:MoveTo(Vector3.new(10, 0, 0) + Players.LocalPlayer.Character.HumanoidRootPart.Position)
        """)
        let walking = play(walker)
        run(walking, seconds: 2)
        check("MoveTo walks there and says so", lines(walking) == ["arrived true"],
              "\(lines(walking)) \(problems(walking))")
        walking.stop()
    }

    private static func testJumping(_ check: Checker) {
        print("\nPlayer: jumping")
        func jump(_ setup: String) -> (Float, PlayController) {
            let model = world()
            add(model, "", name: "ControlScript", host: .starterPlayer, enabled: false)
            add(model, """
            local humanoid = Players.LocalPlayer.Character.Humanoid
            \(setup)
            task.delay(0.75, function() humanoid.Jump = true end)
            """)
            let session = play(model)
            return (peak(session, seconds: 1.5), session)
        }
        let gravity = CharacterController.gravity

        let (standard, first) = jump("")
        check("Jump = true jumps", problems(first).isEmpty && standard > 1, "\(standard) \(problems(first))")
        check("as high as JumpPower 50 allows", near(standard, 50 * 50 / (2 * gravity), 0.3), "\(standard)")
        first.stop()

        let (strong, second) = jump("humanoid.JumpPower = 100")
        check("JumpPower raises the jump", near(strong, 100 * 100 / (2 * gravity), 0.6), "\(strong)")
        second.stop()

        let (byHeight, third) = jump("humanoid.UseJumpPower = false\nhumanoid.JumpHeight = 12")
        check("JumpHeight is used when UseJumpPower is off", near(byHeight, 12, 0.4), "\(byHeight)")
        third.stop()

        let pressed = play(world())
        pressed.key("Space", pressed: true)
        let height = peak(pressed, seconds: 0.4)
        pressed.key("Space", pressed: false)
        check("Space jumps through the default ControlScript", height > 3, "\(height)")
        pressed.stop()

        // A tap is one jump. The ControlScript asks to jump on every frame Space is held,
        // the few just after take-off included, and a request still standing when the
        // character lands would jump it again.
        func jumps(holdingSpaceFor held: Float, over total: Float) -> Int {
            let session = play(world())
            var count = 0
            var previous = session.humanoid.state
            var down = true
            var elapsed: Float = 0
            session.key("Space", pressed: true)
            while elapsed < total {
                if down, elapsed >= held {
                    session.key("Space", pressed: false)
                    down = false
                }
                session.step(dt: frame)
                if session.humanoid.state == .jumping, previous != .jumping { count += 1 }
                previous = session.humanoid.state
                elapsed += frame
            }
            session.stop()
            return count
        }
        let tapped = jumps(holdingSpaceFor: 0.1, over: 2)
        check("a tap of Space jumps once, not again on landing", tapped == 1, "\(tapped) jumps")
        let held = jumps(holdingSpaceFor: 1.8, over: 2)
        check("holding Space keeps jumping, as in Roblox", held >= 3, "\(held) jumps")

        // A jump pad sets Jump from a Touched handler, which runs before the ControlScript
        // in a frame: the controls may only drop a jump when Space is let go, never every
        // frame, or they would cancel this one.
        let padWorld = world()
        let pad = block("JumpPad", at: Vec3(40, 0.5, 40), size: Vec3(6, 1, 6))
        padWorld.parts = [pad]
        var bounce = ScriptObject.blank(language: .luau)
        bounce.parentID = pad.id
        bounce.source = """
        script.Parent.Touched:Connect(function(hit)
        \tlocal humanoid = hit.Parent:FindFirstChild("Humanoid")
        \tif humanoid then
        \t\thumanoid.Jump = true
        \tend
        end)
        """
        padWorld.scripts.append(bounce)
        let bouncing = play(padWorld)
        bouncing.character.position = Vec3(40, 1, 40)
        bouncing.character.velocity = .zero
        var highest: Float = 0
        var elapsed: Float = 0
        while elapsed < 1.5 {
            bouncing.step(dt: frame)
            highest = max(highest, bouncing.character.position.y - 1)
            elapsed += frame
        }
        check("a jump pad's Jump = true isn't cancelled by the controls",
              highest > 3 && problems(bouncing).isEmpty, "\(highest) \(problems(bouncing))")
        bouncing.stop()
    }

    private static func testHealthAndRespawn(_ check: Checker) {
        print("\nPlayer: health, death and respawning")
        let model = world()
        model.starterPlayer.respawnTime = 1
        add(model, """
        local player = Players.LocalPlayer
        local function watch(character)
            local humanoid = character:WaitForChild("Humanoid")
            humanoid.Died:Connect(function() print("died", humanoid.Health) end)
        end
        watch(player.Character)
        player.CharacterAdded:Connect(function(character)
            print("added", character.Humanoid.Health)
            watch(character)
        end)
        player.CharacterRemoving:Connect(function() print("removing") end)
        """, host: .starterPlayer)
        let session = play(model)
        check("the scripts start", problems(session).isEmpty, problems(session))
        check("Health starts at MaxHealth", session.humanoid.health == 100)

        _ = session.playerInvoke("humanoid.damage", [.number(1), .number(30)])
        run(session, seconds: 0.1)
        check("TakeDamage lowers Health", session.humanoid.health == 70, "\(session.humanoid.health)")
        run(session, seconds: 3)
        check("the Health script regenerates it", session.humanoid.health > 70 && session.humanoid.health < 75,
              "\(session.humanoid.health)")

        _ = session.playerInvoke("humanoid.damage", [.number(1), .number(500)])
        run(session, seconds: 0.2)
        check("enough damage kills", session.humanoid.isDead)
        check("Died fires with Health at 0", lines(session).contains("died 0"), "\(lines(session))")
        check("the body stops obeying", session.humanoid.moveDirection == .zero)
        check("a dead Humanoid does not regenerate", session.humanoid.health == 0)
        run(session, seconds: 1)
        check("after RespawnTime a new character arrives", session.characterGeneration == 2 && !session.humanoid.isDead,
              "\(session.characterGeneration)")
        check("CharacterRemoving then CharacterAdded fire", Array(lines(session).suffix(2)) == ["removing", "added 100"],
              "\(lines(session))")
        check("…once each: the first character, already there, isn't announced again",
              lines(session).filter { $0 == "added 100" }.count == 1, "\(lines(session))")

        session.character.solidBaseplate = false
        session.character.position = Vec3(0, -600, 0)
        run(session, seconds: 0.1)
        check("falling out of the world kills", session.humanoid.isDead)
        session.stop()

        let noRegen = world()
        add(noRegen, "", name: "Health", host: .starterCharacter, enabled: false)
        let hurt = play(noRegen)
        _ = hurt.playerInvoke("humanoid.damage", [.number(1), .number(40)])
        run(hurt, seconds: 3)
        check("a disabled Health script turns regeneration off", hurt.humanoid.health == 60, "\(hurt.humanoid.health)")

        _ = hurt.playerInvoke("player.load", [])
        run(hurt, seconds: 0.1)
        check("LoadCharacter respawns at once", hurt.characterGeneration == 2 && hurt.humanoid.health == 100)
        hurt.stop()
    }

    private static func testCharacterScripts(_ check: Checker) {
        print("\nPlayer: StarterCharacterScripts")
        let model = world()
        add(model, """
        local character = script.Parent
        print("hello", character.Name, character.Humanoid.Health)
        game:GetService("RunService").Heartbeat:Connect(function() print("beat") end)
        task.delay(5, function() print("late") end)
        """, name: "Greeter", host: .starterCharacter)
        add(model, """
        local old = Players.LocalPlayer.Character.Humanoid
        Players.LocalPlayer.CharacterAdded:Connect(function(character)
            old.WalkSpeed = 99
            print("old", old.Health, old:GetState() == Enum.HumanoidStateType.Dead, character.Humanoid.WalkSpeed)
        end)
        """, host: .starterPlayer)
        let session = play(model)
        check("script.Parent is the character", lines(session).first == "hello Player 100",
              "\(lines(session)) \(problems(session))")

        _ = session.playerInvoke("player.load", [])
        run(session, seconds: 0.05)
        session.console.clear()
        run(session, seconds: 0.2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let beats = lines(session).filter { $0 == "beat" }.count
        check("character scripts run again for a new character",
              session.characterGeneration == 2 && beats > 0, "\(beats)")
        check("and the old character's scripts were stopped", beats <= 13, "\(beats) beats in 12 frames")
        run(session, seconds: 5)
        check("including what they had scheduled", lines(session).filter { $0 == "late" }.count == 1,
              "\(lines(session).filter { $0 == "late" })")
        check("an old Humanoid reads as dead and cannot steer the new one",
              session.humanoid.walkSpeed == 16, "\(session.humanoid.walkSpeed)")
        session.stop()

        let replay = world()
        add(replay, """
        print(#Players.LocalPlayer.Character:GetChildren(), Players.LocalPlayer.Character:FindFirstChild("Nope"))
        """, host: .starterCharacter)
        let children = play(replay)
        check("the character has a Humanoid, a root and six body parts", lines(children) == ["8 nil"],
              "\(lines(children))")
        children.stop()
    }

    private static func testAppearance(_ check: Checker) {
        print("\nPlayer: appearance")
        let model = world()
        model.starterPlayer.bodyColors.torso = Vec3(1, 0, 0)
        add(model, """
        local character = Players.LocalPlayer.Character
        print(character.Torso.Color.R, character.Head.Transparency)
        character["Left Arm"].Color = Color3.fromRGB(0, 255, 0)
        character.Head.Transparency = 0.5
        """)
        let session = play(model)
        let pose = session.avatars[0]
        check("body colours come from StarterPlayer", lines(session).first == "1 0", "\(lines(session)) \(problems(session))")
        check("scripts can recolour a body part", pose.colors.leftArm == Vec3(0, 1, 0), "\(pose.colors.leftArm)")
        check("and make one see-through", pose.transparency["Head"] == 0.5, "\(pose.transparency)")
        check("the renderer gets the template's torso", pose.colors.torso == Vec3(1, 0, 0))

        _ = session.playerInvoke("player.load", [])
        run(session, seconds: 0.05)
        check("a new character starts from the template again",
              session.avatars[0].colors.leftArm == model.starterPlayer.bodyColors.leftArm
                  && session.avatars[0].transparency.isEmpty)
        session.stop()
    }

    private static func testInputAndStates(_ check: Checker) {
        print("\nPlayer: input and Humanoid states")
        let model = world()
        add(model, """
        local UserInputService = game:GetService("UserInputService")
        UserInputService.InputBegan:Connect(function(input)
            print("began", input.KeyCode.Name, input.UserInputType.Name, typeof(input))
        end)
        UserInputService.InputEnded:Connect(function(input)
            print("ended", input.KeyCode == Enum.KeyCode.E, UserInputService:IsKeyDown(Enum.KeyCode.E))
        end)
        game:GetService("RunService").Heartbeat:Connect(function()
            if UserInputService:IsKeyDown(Enum.KeyCode.E) then print("held", #UserInputService:GetKeysPressed()) end
        end)
        local humanoid = Players.LocalPlayer.Character.Humanoid
        humanoid.StateChanged:Connect(function(old, new) print("state", new.Name) end)
        print(typeof(humanoid), humanoid:IsA("Humanoid"), humanoid.ClassName, humanoid.Parent.ClassName)
        print(pcall(function() humanoid.WalkSpeed = "fast" end))
        print(pcall(function() humanoid.MoveDirection = Vector3.new() end))
        """)
        let session = play(model)
        let startup = lines(session)
        check("the Humanoid looks like Roblox's", startup.first == "Instance true Humanoid Model",
              "\(startup) \(problems(session))")
        check("properties are type-checked",
              startup.count > 2 && startup[1].contains("number expected, got string"), "\(startup)")
        check("read-only properties refuse writes",
              startup.count > 2 && startup[2].contains("read only"), "\(startup)")

        session.console.clear()
        session.key("E", pressed: true)
        run(session, seconds: frame)
        session.key("E", pressed: false)
        run(session, seconds: frame)
        let input = lines(session)
        check("InputBegan carries an InputObject", input.first == "began E Keyboard InputObject", "\(input)")
        check("IsKeyDown and GetKeysPressed see held keys", input.contains("held 1"), "\(input)")
        check("InputEnded fires after the key is up", input.last == "ended true false", "\(input)")

        session.console.clear()
        _ = session.playerInvoke("humanoid.set", [.number(1), .string("jump"), .bool(true)])
        run(session, seconds: 1.5)
        let states = lines(session).filter { $0.hasPrefix("state") }
        check("a jump goes Jumping → Freefall → Landed → Running",
              states == ["state Jumping", "state Freefall", "state Landed", "state Running"], "\(states)")
        session.stop()
    }

    private static func testPlayerSettings(_ check: Checker) {
        print("\nPlayer: Players, camera and workspace settings")
        let model = world()
        model.starterPlayer.walkSpeed = 24
        model.starterPlayer.maxHealth = 250
        model.starterPlayer.cameraMode = .lockFirstPerson
        add(model, """
        local player = Players.LocalPlayer
        local humanoid = player.Character.Humanoid
        print(humanoid.WalkSpeed, humanoid.MaxHealth, humanoid.Health, player.CameraMode == Enum.CameraMode.LockFirstPerson)
        print(workspace.Gravity, Players.RespawnTime, player.Name, player.UserId, #Players:GetPlayers())
        workspace.Gravity = 50
        Players.RespawnTime = 2
        player.CameraMode = Enum.CameraMode.Classic
        player.CameraMaxZoomDistance = 12
        """)
        let session = play(model)
        let out = lines(session)
        check("the Humanoid starts from StarterPlayer", out.first == "24 250 250 true", "\(out) \(problems(session))")
        check("Players and workspace describe the session", out.count > 1 && out[1] == "196.2 5 Player 1 1", "\(out)")
        check("scripts can change gravity", session.gravity == 50, "\(session.gravity)")
        check("and the respawn time", session.respawnTime == 2)
        check("and the camera", !session.camera.lockFirstPerson && session.camera.maxZoom == 12)
        session.stop()
    }

    private static func testSaving(_ check: Checker) {
        print("\nPlayer: saving StarterPlayer")
        var state = SceneState()
        state.starterPlayer.walkSpeed = 30
        state.starterPlayer.bodyColors.head = Vec3(0.1, 0.2, 0.3)
        state.starterPlayer.cameraMode = .lockFirstPerson
        var script = ScriptObject.blank(language: .luau)
        script.host = .starterCharacter
        state.scripts = [script]
        let data = try? JSONEncoder().encode(state)
        let back = data.flatMap { try? JSONDecoder().decode(SceneState.self, from: $0) }
        check("StarterPlayer settings survive saving", back?.starterPlayer == state.starterPlayer)
        check("and so does where a script lives", back?.scripts.first?.host == .starterCharacter)

        let old = #"{"parts":[],"scripts":[{"id":"00000000-0000-0000-0000-000000000001","name":"Old","source":"","enabled":true}]}"#
        let decoded = try? JSONDecoder().decode(SceneState.self, from: Data(old.utf8))
        check("files from before StarterPlayer still open", decoded?.starterPlayer == StarterPlayerSettings(),
              "\(String(describing: decoded))")
        check("with their scripts in the scene", decoded?.scripts.first?.host == .scene)

        let partial = #"{"walkSpeed":20}"#
        let settings = try? JSONDecoder().decode(StarterPlayerSettings.self, from: Data(partial.utf8))
        check("missing settings take Roblox's defaults",
              settings?.walkSpeed == 20 && settings?.jumpPower == 50 && settings?.maxHealth == 100)
    }
}
