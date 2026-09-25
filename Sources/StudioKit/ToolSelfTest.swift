import Foundation
import simd

/// Verification for Tools: the model (StarterPack, parked parts, saving), a player's
/// Backpack and hand through the default BackpackScript, clicks, dropping and picking
/// up, respawning, the Luau API, and two players fighting with swords over the network.
enum ToolSelfTest {

    static func run(check: Checker) {
        testModel(check)
        testHolding(check)
        testLuauAPI(check)
        testSwordFight(check)
    }

    private static let frame: Float = 1.0 / 60

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

    private static func press(_ session: PlayController, _ key: String) {
        session.key(key, pressed: true)
        run(session, seconds: 2 * frame)
        session.key(key, pressed: false)
        run(session, seconds: 0.2)
    }

    /// A sword: a Tool in StarterPack with a Handle and a script.
    static func addSword(to model: SceneModel, script source: String) -> UUID {
        let tool = model.addTool(at: Vec3(0, 3, 0))
        model.renameNode(tool, to: "Sword")
        if let handle = model.handle(of: tool) {
            var script = ScriptObject.blank(language: .luau)
            script.name = "SwordScript"
            script.parentID = tool
            script.source = source
            model.scripts.append(script)
            _ = handle
        }
        model.moveToStarterPack(tool)
        return tool
    }

    private static func world() -> SceneModel {
        let model = SceneModel()
        model.parts = []
        model.scripts = []
        model.shaders = []
        model.groups = []
        var controls = ScriptObject.blank(language: .luau)
        controls.name = "ControlScript"
        controls.host = .starterPlayer
        controls.enabled = false
        model.scripts = [controls]
        return model
    }

    // MARK: - The model

    private static func testModel(_ check: Checker) {
        print("\nTools: in the scene")
        let model = world()
        let tool = model.addTool()
        let handle = model.handle(of: tool)
        check("a new Tool has a Handle to hold it by", model.group(id: tool)?.kind == .tool && handle != nil
              && model.group(id: tool)?.tool == ToolSettings())
        check("…and is in the Workspace", model.children(of: nil).contains(.group(tool)) && handle?.inWorld == true)
        model.moveToStarterPack(tool)
        check("moved to StarterPack, it leaves the Workspace and the world",
              !model.children(of: nil).contains(.group(tool)) && model.handle(of: tool)?.parked == true
              && model.handle(of: tool)?.inWorld == false && model.starterPackTools.map(\.id) == [tool])
        check("…and its parts can't be clicked in the viewport",
              Picking.pick(ray: Ray(origin: Vec3(0, 3, 10), direction: Vec3(0, 0, -1)), in: model.parts) == nil)
        model.undo()
        check("undo puts it back", model.toolPlace(tool) == .workspace && model.handle(of: tool)?.parked == false)
        model.redo()
        model.updateTool(id: tool) { $0.toolTip = "Slash!" }
        let saved = try? JSONEncoder().encode(model.state)
        let loaded = saved.flatMap { try? JSONDecoder().decode(SceneState.self, from: $0) }
        check("a Tool saves with its settings, place and parked parts",
              loaded?.groups.first { $0.id == tool }?.tool?.toolTip == "Slash!"
              && loaded?.groups.first { $0.id == tool }?.tool?.place == .starterPack
              && loaded?.parts.first { $0.parentID == tool }?.parked == true)
        let old = try? JSONDecoder().decode(SceneGroup.self, from: Data(#"{"name":"Car","kind":"Model"}"#.utf8))
        check("groups from before Tools have no tool settings", old?.tool == nil && old?.kind == .model)
    }

    // MARK: - Holding

    private static func testHolding(_ check: Checker) {
        print("\nTools: the Backpack and the hand")
        let model = world()
        _ = addSword(to: model, script: """
        local tool = script.Parent
        local handle = tool:WaitForChild("Handle")
        print("ready in", tool.Parent.ClassName)
        tool.Equipped:Connect(function()
        \tprint("equipped by", tool.Parent.Name)
        end)
        tool.Unequipped:Connect(function()
        \tprint("put away in", tool.Parent.ClassName)
        end)
        tool.Activated:Connect(function()
        \tprint("swing")
        end)
        tool.Deactivated:Connect(function()
        \tprint("swing over")
        end)
        """)
        var pickup = Part()
        pickup.name = "Handle"
        pickup.position = Vec3(30, 2, 0)
        pickup.size = Vec3(1, 1, 1)
        let lying = SceneGroup(name: "Torch", kind: .tool)
        pickup.parentID = lying.id
        model.groups.append(lying)
        model.parts.append(pickup)

        let session = PlayController(model: model, console: ScriptConsole())
        session.playerName = "Robin"
        session.start()
        run(session, seconds: 0.3)
        let mine = model.tools(of: 0)
        check("each character gets a copy of every StarterPack tool, in their Backpack",
              mine.count == 1 && mine.first?.tool?.place == .backpack(0) && model.starterPackTools.count == 1
              && mine.first?.id != model.starterPackTools.first?.id, "\(mine.map(\.name))")
        check("…whose scripts run, seeing it in the Backpack", lines(session).contains("ready in Backpack"),
              "\(lines(session)) \(lines(session, .error))")
        let slot = session.gui.objects.values.first { $0.name == "Slot1" }
        check("the hotbar shows it", slot?.text == "Sword" && slot?.visible == true, "\(String(describing: slot?.text))")

        press(session, "One")
        guard let sword = model.heldTool(of: 0), let handle = model.handle(of: sword.id) else {
            check("1 puts the first tool in the hand", false, "\(lines(session, .error))")
            return
        }
        check("1 puts the first tool in the hand", lines(session).contains("equipped by Robin") && handle.inWorld)
        let forward = Vec3(-sin(session.character.facingYaw), 0, -cos(session.character.facingYaw))
        let fromBody = handle.position - session.character.position
        check("…held out in front, at hand height",
              dot(fromBody, forward) > 1 && fromBody.y > 2.5 && fromBody.y < 6.5, "\(fromBody)")
        check("…with the arm out", abs(session.currentJoints.rightShoulder.x - .pi / 2) < 0.01)
        check("…and the slot lights up", session.gui.objects.values.first { $0.name == "Slot1" }?.backgroundColor
              == Vec3(60, 120, 220) / 255)
        session.character.position += Vec3(5, 0, 0)
        run(session, seconds: frame)
        let moved = model.handle(of: sword.id)?.position ?? .zero
        check("the tool goes where the hand goes", abs(moved.x - handle.position.x - 5) < 0.3, "\(moved) vs \(handle.position)")
        check("…and the body doesn't bump into it", session.heldToolParts.contains(handle.id))

        session.mouseButton(1, pressed: true)
        run(session, seconds: 2 * frame)
        session.mouseButton(1, pressed: false)
        run(session, seconds: 2 * frame)
        check("a click activates it", lines(session).suffix(2) == ["swing", "swing over"], "\(lines(session).suffix(3))")

        press(session, "One")
        check("1 again puts it away", model.heldTool(of: 0) == nil && lines(session).contains("put away in Backpack")
              && model.handle(of: sword.id)?.parked == true)
        session.mouseButton(1, pressed: true)
        run(session, seconds: 2 * frame)
        session.mouseButton(1, pressed: false)
        check("…and clicks do nothing then", lines(session).filter { $0 == "swing" }.count == 1)

        press(session, "One")
        press(session, "Backspace")
        let dropped = model.handle(of: sword.id)
        check("Backspace drops the tool in hand into the world",
              model.toolPlace(sword.id) == .workspace && dropped?.inWorld == true && model.tools(of: 0).isEmpty)
        run(session, seconds: 0.3)
        check("…where its dropper doesn't pick it straight back up", model.toolPlace(sword.id) == .workspace)
        run(session, seconds: 1)
        session.character.position = Vec3(30, 0, 0)
        run(session, seconds: 0.2)
        check("touching a tool's Handle picks it up, into the empty hand",
              model.heldTool(of: 0)?.id == lying.id, "\(String(describing: model.toolPlace(lying.id)))")

        let before = lines(session).filter { $0 == "ready in Backpack" }.count
        session.respawnRequested = true
        run(session, seconds: 0.3)
        check("respawning empties the Backpack and hand, and gives a fresh copy",
              model.tools(of: 0).count == 1 && model.tools(of: 0).first?.name == "Sword"
              && model.group(id: lying.id) == nil
              && lines(session).filter { $0 == "ready in Backpack" }.count == before + 1)
        let errors = lines(session, .error)
        check("none of it raised an error", errors.isEmpty, errors.joined(separator: " | "))
        session.stop()
    }

    // MARK: - Luau

    private static func testLuauAPI(_ check: Checker) {
        print("\nTools: the Luau API")
        let model = world()
        _ = addSword(to: model, script: "")
        var script = ScriptObject.blank(language: .luau)
        script.host = .starterPlayer
        script.source = """
        local player = game:GetService("Players").LocalPlayer
        local StarterPack = game:GetService("StarterPack")
        local backpack = player:WaitForChild("Backpack")
        local character = player.Character
        local humanoid = character:WaitForChild("Humanoid")
        local sword = backpack:WaitForChild("Sword")
        print("pack", #StarterPack:GetChildren(), StarterPack.Sword.ClassName, #backpack:GetChildren(),
        \tsword:IsA("Tool"), sword:IsA("BackpackItem"), sword.Parent == backpack, sword.ToolTip == "")
        humanoid:EquipTool(sword)
        print("held", sword.Parent == character, character:FindFirstChildOfClass("Tool") == sword,
        \tcharacter.Sword == sword, #backpack:GetChildren())
        humanoid:UnequipTools()
        print("away", sword.Parent == backpack, character:FindFirstChildOfClass("Tool") == nil)
        sword.Parent = character
        print("parent equips", character:FindFirstChildOfClass("Tool") == sword)
        sword.Parent = backpack
        local made = Instance.new("Tool")
        made.Name = "Wand"
        made.ToolTip = "Zap"
        made.RequiresHandle = false
        made.CanBeDropped = false
        made.Parent = backpack
        print("made", made.Parent == backpack, made.ToolTip, made.CanBeDropped, #backpack:GetChildren())
        made.Enabled = false
        local zapped = false
        made.Activated:Connect(function()
        \tzapped = true
        end)
        humanoid:EquipTool(made)
        made:Activate()
        print("disabled", made.Parent == character, zapped)
        print("wrong", pcall(function() sword.ToolTip = 5 end), pcall(function() humanoid:EquipTool(workspace) end))
        made.Parent = workspace
        print("dropped", made.Parent == workspace, character:FindFirstChildOfClass("Tool"))
        """
        model.scripts.append(script)
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        run(session, seconds: 0.2)
        let said = lines(session)
        check("StarterPack, the Backpack and Tool read as in Roblox",
              said.contains("pack 1 Tool 1 true true true true"), "\(said) \(lines(session, .error))")
        check("EquipTool puts it in the character", said.contains("held true true true 0"), "\(said)")
        check("UnequipTools puts it back", said.contains("away true true"), "\(said)")
        check("setting Parent to the character equips it", said.contains("parent equips true"), "\(said)")
        check("Instance.new(\"Tool\") makes one with its settings, given by Parent = Backpack",
              said.contains("made true Zap false 2"), "\(said)")
        check("a disabled tool isn't activated", said.contains("disabled true false"), "\(said)")
        check("wrong values are errors", said.contains { $0.hasPrefix("wrong false") && $0.contains("false") }, "\(said)")
        check("Parent = workspace drops it", said.contains("dropped true nil"), "\(said)")
        session.stop()
    }

    // MARK: - Multiplayer

    /// Two players with swords from StarterPack. Tool scripts run on the host for both;
    /// each equips from their own hotbar, swings with a click, and hits the other.
    private static func testSwordFight(_ check: Checker) {
        print("\nTools: a sword fight over the network")
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            model.starterPlayer.playersCollide = false
            _ = addSword(to: model, script: """
            local tool = script.Parent
            local handle = tool:WaitForChild("Handle")
            tool.Activated:Connect(function()
            \tprint("swing by " .. tool.Parent.Name)
            end)
            -- Each body part touches on its own, so a hit counts once a second.
            local lastHit = {}
            handle.Touched:Connect(function(hit)
            \tlocal humanoid = hit.Parent:FindFirstChild("Humanoid")
            \tif humanoid and hit.Parent ~= tool.Parent and humanoid.Health > 0
            \t\tand os.clock() - (lastHit[humanoid] or -10) > 1 then
            \t\tlastHit[humanoid] = os.clock()
            \t\thumanoid:TakeDamage(25)
            \t\tprint(tool.Parent.Name .. " hit " .. hit.Parent.Name)
            \tend
            end)
            """)
        }), let robin = hosting.player, let sam = joining.player else {
            check("two players share a game", false)
            return
        }
        func said() -> [String] {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            return robin.console.lines.filter { $0.kind == .output }.map(\.text)
        }
        let samID = sam.playerID
        robin.character.position = Vec3(-20, 0, 0)
        sam.character.position = Vec3(20, 0, 0)
        LANSelfTest.run([hosting, joining], seconds: 0.5)
        check("the host gives each player their StarterPack copy",
              hosting.model.tools(of: 0).count == 1 && hosting.model.tools(of: samID).count == 1
              && joining.model.tools(of: samID).count == 1, "\(samID)")

        sam.key("One", pressed: true)
        LANSelfTest.run([hosting, joining], seconds: 0.05)
        sam.key("One", pressed: false)
        LANSelfTest.run([hosting, joining], seconds: 0.4)
        guard let samsSword = hosting.model.heldTool(of: samID) else {
            check("a joined player's hotbar equips their sword, through the host", false,
                  "\(sam.console.lines.filter { $0.kind == .error }.map(\.text))")
            return
        }
        check("a joined player's hotbar equips their sword, through the host",
              joining.model.heldTool(of: samID)?.id == samsSword.id)
        let inSamsHand = joining.model.handle(of: samsSword.id)?.position ?? .zero
        check("…which they see in their own hand", simd_distance(inSamsHand, sam.character.position) < 6,
              "\(inSamsHand) vs \(sam.character.position)")

        sam.mouseButton(1, pressed: true)
        LANSelfTest.run([hosting, joining], seconds: 0.1)
        sam.mouseButton(1, pressed: false)
        LANSelfTest.run([hosting, joining], seconds: 0.1)
        check("their click swings it, in the host's tool script", said().contains("swing by Sam"), "\(said())")

        // Robin walks into Sam's sword.
        let blade = hosting.model.handle(of: samsSword.id)?.position ?? .zero
        robin.character.position = Vec3(blade.x, 0, blade.z)
        LANSelfTest.run([hosting, joining], seconds: 0.3)
        check("Sam's sword hits Robin", said().contains("Sam hit Robin") && robin.humanoid.health == 75,
              "\(said()) \(robin.humanoid.health)")

        robin.character.position = Vec3(-20, 0, 0)
        robin.key("One", pressed: true)
        LANSelfTest.run([hosting, joining], seconds: 0.05)
        robin.key("One", pressed: false)
        LANSelfTest.run([hosting, joining], seconds: 0.4)
        guard let robinsSword = hosting.model.heldTool(of: 0) else {
            check("the host equips theirs too", false)
            return
        }
        let robinsBlade = joining.model.handle(of: robinsSword.id)
        check("the joined player sees the host's sword in the host's hand",
              robinsBlade?.inWorld == true
              && simd_distance(robinsBlade?.position ?? .zero, robin.character.position) < 6)

        let hostBlade = hosting.model.handle(of: robinsSword.id)?.position ?? .zero
        sam.character.position = Vec3(hostBlade.x, 0, hostBlade.z)
        LANSelfTest.run([hosting, joining], seconds: 0.5)
        check("Robin's sword hits Sam, in Sam's own game", said().contains("Robin hit Sam") && sam.humanoid.health == 75,
              "\(said()) \(sam.humanoid.health)")

        sam.key("Backspace", pressed: true)
        LANSelfTest.run([hosting, joining], seconds: 0.05)
        sam.key("Backspace", pressed: false)
        LANSelfTest.run([hosting, joining], seconds: 0.3)
        check("Backspace drops a joined player's sword into everyone's world",
              hosting.model.toolPlace(samsSword.id) == .workspace && joining.model.toolPlace(samsSword.id) == .workspace)

        joining.leaveGame()
        LANSelfTest.wait { hosting.host?.players.isEmpty == true }
        LANSelfTest.run([hosting], seconds: 0.2)
        check("a player who leaves takes their tools with them", hosting.model.tools(of: samID).isEmpty)
        let errors = (robin.console.lines + sam.console.lines).filter { $0.kind == .error }.map(\.text)
        check("none of it raised an error", errors.isEmpty, errors.joined(separator: " | "))
        hosting.leaveGame()
    }
}
