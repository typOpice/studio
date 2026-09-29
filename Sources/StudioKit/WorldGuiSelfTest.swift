import AppKit
import MetalKit
import simd

enum WorldGuiSelfTest {
    static func run(check: Checker) {
        print("\nWorld GUI: SurfaceGui and ViewportFrame")
        testPixels(check)
        testPersistence(check)
        testLifetime(check)
        testNetwork(check)
        testLocalHierarchy(check)
        testAPI(check)
    }

    private static func testAPI(_ check: Checker) {
        let model = SceneModel()
        model.clearScene()
        var board = Part(); board.name = "Board"; board.size = Vec3(8, 5, 1)
        model.parts = [board]
        var script = ScriptObject.blank(language: .luau)
        script.host = .starterPlayer
        script.source = """
        local surface = Instance.new("SurfaceGui", workspace.Board)
        surface.Name = "Sign"
        surface.Face = Enum.NormalId.Front
        surface.CanvasSize = Vector2.new(400, 250)
        surface.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
        surface.PixelsPerStud = 40
        surface.LightInfluence = 0.5
        surface.Brightness = 1.5
        local button = Instance.new("TextButton", surface)
        button.Size = UDim2.fromScale(1, 1)
        button.Text = "Drive"
        button.MouseButton1Click:Connect(function() print("surface clicked") end)
        print("surface", surface.Parent == workspace.Board, workspace.Board.Sign == surface,
            surface:IsA("LayerCollector"), surface.CanvasSize == Vector2.new(400, 250))
        print("surface typed", not pcall(function() surface.Face = Enum.Material.Plastic end),
            not pcall(function() surface.CanvasSize = UDim2.new() end))
        """
        model.scripts = [script]
        let player = PlayController(model: model, console: ScriptConsole())
        player.start()
        defer { player.stop() }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        let lines = player.console.lines.map(\.text)
        check("SurfaceGui exposes face, canvas and world parent through the Instance tree",
              lines.contains("surface true true true true"), lines.joined(separator: " | "))
        check("SurfaceGui rejects wrong property types", lines.contains("surface typed true true"))
        player.viewSize = SIMD2(800, 600)
        if let ray = player.mouseRay() {
            model.update(id: board.id) {
                $0.position = ray.origin + ray.direction * 15
                $0.orientation = simd_quatf(from: Vec3(0, 0, -1), to: -ray.direction)
            }
        }
        let view = StudioMTKView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.player = player
        if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 400, y: 300), modifierFlags: [],
                                         timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            view.mouseDown(with: event)
        }
        player.step(dt: 1 / 60)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        check("a real viewport click reaches the button on a rotated part", player.console.lines.contains { $0.text == "surface clicked" })
        if let surface = player.gui.objects.values.first(where: { $0.kind == .surfaceGui }) {
            let box = player.gui.create(.textBox)
            player.gui.update(box) { $0.size = UDim2(xScale: 1, yScale: 1); $0.zIndex = 5 }
            player.gui.setParent(box, to: surface.id)
            check("surface TextBox takes keyboard focus", player.clickSurface(at: SIMD2(400, 300)) && player.isTyping)
            player.typeKey(keyCode: 0, characters: "racer")
            check("surface TextBox uses the game's normal typing route", player.gui.object(box)?.text == "racer")
        }
        view.player = nil
        check("SurfaceGui scripts run without errors", player.console.lines.allSatisfy { $0.kind != .error })
    }

    private static func testPixels(_ check: Checker) {
        let model = SceneModel(); model.clearScene(); model.scripts = []; model.shaders = []
        let store = GuiStore()
        var board = Part(); board.size = Vec3(8, 5, 4); board.position = Vec3(0, 8, 0)
        model.parts = [board]
        let root = store.create(.surfaceGui)
        store.update(root) { $0.worldParent = board.id; $0.sizingMode = "FixedSize"; $0.surfaceCanvasSize = SIMD2(320, 200) }
        let fill = store.create(.frame)
        store.update(fill) { $0.size = UDim2(xScale: 1, yScale: 1); $0.backgroundColor = Vec3(1, 0, 0) }
        store.setParent(fill, to: root)
        let controller = ViewportController(model: model); controller.worldGui = store
        controller.camera.yaw = -.pi / 2; controller.camera.pitch = 0; controller.camera.distance = 14
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = Renderer(device: device, view: MTKView(frame: .zero, device: device), source: controller) else {
            check("SurfaceGui has a Metal renderer", false); return
        }
        func color(at point: Vec3? = nil) -> Vec3 {
            var x = 160, y = 120
            if let point {
                let clip = controller.camera.viewProjection(aspect: 320 / 240) * Vec4(point, 1)
                x = Int((clip.x / clip.w * 0.5 + 0.5) * 320)
                y = Int((0.5 - clip.y / clip.w * 0.5) * 240)
            }
            guard let image = renderer.snapshot(width: 320, height: 240),
                  let c = NSBitmapImageRep(cgImage: image).colorAt(x: min(max(x, 0), 319), y: min(max(y, 0), 239))?.usingColorSpace(.deviceRGB) else { return .zero }
            return Vec3(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent))
        }
        for face in ["Front", "Back", "Left", "Right", "Top", "Bottom"] {
            let local = SurfaceFace(part: board, face: face).normal
            board.orientation = simd_quatf(angle: 0.3, axis: Vec3(0, 0, 1)) * simd_quatf(from: local, to: Vec3(0, 0, -1))
            model.parts = [board]
            store.update(root) { $0.face = face }
            let surface = SurfaceFace(part: board, face: face)
            check("\(face) canvas axes read left-to-right from outside the part",
                  simd_dot(simd_cross(surface.right, surface.down), surface.normal) < -0.99)
            controller.camera.target = surface.center
            let c = color()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
            check("\(face) canvas draws on a rotated face", c.x > 0.8 && c.y < 0.15 && c.z < 0.15,
                  "\(c), surfaces \(store.surfaces(in: model).count), errors \(controller.shaderConsole.lines.map(\.text))")
            let point = surface.point(SIMD2(0.2, 0.7))
            let hit = surface.hit(Ray(origin: point + surface.normal * 10, direction: -surface.normal))
            check("\(face) face maps pointer rays back to canvas coordinates", hit.map { simd_length($0.uv - SIMD2(0.2, 0.7)) < 0.0001 } ?? false)
            board.orientation = simd_quatf(angle: 0, axis: Vec3(0, 1, 0))
        }
        store.update(root) { $0.face = "Front" }
        model.parts = [board]
        controller.camera.target = SurfaceFace(part: board, face: "Front").center
        let patch = store.create(.frame)
        store.setParent(patch, to: root)
        store.update(patch) { $0.size = UDim2(xScale: 0.25, yScale: 0.25); $0.backgroundColor = Vec3(0, 1, 0); $0.zIndex = 3; $0.clipsDescendants = true }
        let frontFace = SurfaceFace(part: board, face: "Front")
        let topLeft = color(at: frontFace.point(SIMD2(0.1, 0.1)))
        check("canvas pixels retain the same top-left orientation as input", topLeft.y > 0.8 && topLeft.x < 0.15, "\(topLeft)")
        let overflowing = store.create(.frame)
        store.setParent(overflowing, to: patch)
        store.update(overflowing) { $0.size = UDim2(xScale: 2, yScale: 2); $0.backgroundColor = Vec3(0, 0, 1) }
        let clipped = color(at: frontFace.point(SIMD2(0.4, 0.1)))
        check("surface widgets retain ClipsDescendants after projection", clipped.x > 0.8 && clipped.z < 0.15, "\(clipped)")
        store.destroy(patch)
        var cover = Part(); cover.position = board.position + Vec3(0, 0, -5); cover.size = Vec3(9, 6, 1); cover.color = Vec3(0, 0, 1)
        model.parts.append(cover)
        let covered = color()
        check("opaque world geometry occludes a surface canvas", covered.x < 0.3, "\(covered)")
        let ray = controller.camera.ray(atViewPoint: SIMD2(160, 120), viewSize: SIMD2(320, 240))
        store.update(fill) { $0 = GuiObject(id: fill, kind: .textButton); $0.parent = root; $0.text = ""; $0.size = UDim2(xScale: 1, yScale: 1); $0.backgroundColor = Vec3(1, 0, 0) }
        check("occluded surfaces do not intercept clicks", store.surfaceHit(ray: ray, model: model, eye: controller.camera.position) == nil)
        store.update(root) { $0.alwaysOnTop = true }
        check("AlwaysOnTop draws through the occluder", color().x > 0.8)
        check("AlwaysOnTop accepts clicks where it is drawn", store.surfaceHit(ray: ray, model: model, eye: controller.camera.position) != nil)
        model.parts = [board]
        store.update(root) { $0.alwaysOnTop = false }
        model.terrain.fillBlock(pose: Pose(position: cover.position, orientation: cover.orientation), size: Vec3(12, 12, 4), material: .rock)
        check("terrain hides surface widgets from pointer input as well as drawing",
              color().x < 0.8 && store.surfaceHit(ray: ray, model: model, eye: controller.camera.position) == nil)
        model.terrain = TerrainData()
        store.update(root) { $0.alwaysOnTop = false; $0.maxDistance = 1 }
        check("MaxDistance hides distant canvases and their input", color().x < 0.8 && store.surfaceHit(ray: ray, model: model, eye: controller.camera.position) == nil)
        store.update(root) { $0.maxDistance = .infinity; $0.brightness = 0.4 }
        let dim = color()
        check("Brightness changes the surface without changing the part", dim.x > 0.3 && dim.x < 0.5, "\(dim)")
        model.lighting.ambient = .zero; model.lighting.brightness = 0
        store.update(root) { $0.brightness = 1; $0.lightInfluence = 1 }
        check("LightInfluence follows scene illumination", color().x < 0.05)
        store.update(root) { $0.lightInfluence = 0; $0.sizingMode = "PixelsPerStud"; $0.pixelsPerStud = 40 }
        check("PixelsPerStud follows the selected face's physical dimensions",
              SurfaceFace(part: board, face: "Front").canvas(store.object(root)!) == CGSize(width: 320, height: 200))
        let scroll = store.create(.scrollingFrame)
        store.update(scroll) { $0.size = UDim2(xScale: 1, yScale: 1); $0.canvasSize = UDim2(yScale: 3); $0.zIndex = 10 }
        store.setParent(scroll, to: root)
        check("a canvas wheel scrolls the existing layout engine",
              store.scroll(root: root, at: CGPoint(x: 160, y: 100), size: CGSize(width: 320, height: 200), by: CGSize(width: 0, height: -80))
              && store.object(scroll)?.canvasPosition.y == 80)
        store.destroy(root)
        check("destroying a surface removes its layout and children", store.objects.isEmpty && store.surfaceSizes.isEmpty)
        _ = color()
        check("destroying a surface releases its cached GPU canvas", renderer.worldGuiCanvasCount == 0)
    }

    private static func testPersistence(_ check: Checker) {
        let model = SceneModel(); model.clearScene(); model.scripts = []
        var part = Part(); part.name = "Signboard"; model.parts = [part]
        guard let root = model.addSurfaceGui(to: part.id), let label = model.addGuiObject(.textLabel, in: root) else {
            check("Studio authors world surface widgets", false); return
        }
        model.setGuiProperty(label, "text", .string("Checkpoint"))
        let saved = try? model.encodeScene()
        let loaded = saved.flatMap { try? JSONDecoder().decode(SceneState.self, from: $0) }
        check("surface parent and widget properties survive saving", loaded?.starterGui.first { $0.id == root }?.worldParent == part.id
              && loaded?.starterGui.first { $0.id == label }?.object().text == "Checkpoint")
        let clone = model.cloneSubtree(part.id, parent: nil)
        let copy = model.starterGui.first { $0.worldParent == clone }
        check("cloning a part carries a freshly identified surface subtree", copy?.id != root && copy.flatMap { model.guiChildren(of: $0.id).first }?.object().text == "Checkpoint")
        model.selection = [part.id]
        let data = try? SceneDocument(model: model).modelData(name: "Sign")
        let other = SceneModel(); other.clearScene()
        if let data { _ = try? SceneDocument(model: other).insertModel(from: data, at: Vec3(10, 0, 0)) }
        let inserted = other.starterGui.first { $0.worldParent != nil }
        check("model export and insertion remap a world surface to the inserted part",
              inserted?.worldParent == other.parts.first?.id && inserted?.id != root
              && inserted.map { other.guiSubtree($0.id).count == 2 } == true)
        model.commit("Delete sign") { model.removeSubtrees([part.id]) }
        check("deleting a part deletes its surface tree", model.guiObject(id: root) == nil && model.guiObject(id: label) == nil)
        model.undo()
        check("undo restores the part and its surface", model.part(id: part.id) != nil && model.guiObject(id: root)?.worldParent == part.id)
    }

    private static func testNetwork(_ check: Checker) {
        guard let (host, joined) = LANSelfTest.twoPlayers({ model in
            var board = Part(); board.name = "RaceBoard"; model.parts.append(board)
            let root = model.addSurfaceGui(to: board.id)!
            model.renameGuiObject(root, to: "Sign")
            let label = model.addGuiObject(.textLabel, in: root)!
            model.renameGuiObject(label, to: "Message")
            model.setGuiProperty(label, "text", .string("Ready"))
            var server = ScriptObject.blank(language: .luau)
            server.source = """
            task.wait(0.2)
            workspace.RaceBoard.Sign.Message.Text = 'GO'
            task.wait(0.3)
            workspace.RaceBoard.Sign.Message.TextColor3 = Color3.new(1, 0, 0)
            """
            var localScript = ScriptObject.blank(language: .luau); localScript.host = .starterPlayer
            localScript.source = """
            local p = game:GetService("Players").LocalPlayer
            local gui = Instance.new("SurfaceGui", p.PlayerGui)
            gui.Name = "OwnSurface"
            gui.Adornee = workspace.RaceBoard
            local label = Instance.new("TextLabel", gui)
            label.Text = p.Name
            task.wait(0.35)
            workspace.RaceBoard.Sign.Message.Text = p.Name .. " private"
            """
            var worldScript = ScriptObject.blank(language: .luau)
            worldScript.host = .starterGui; worldScript.parentID = root
            worldScript.source = "print('surface copy', script.Parent.Parent.Name, game:GetService('Players').LocalPlayer.Name)"
            model.scripts += [server, localScript, worldScript]
        }), let robin = host.player, let sam = joined.player else { check("surface players join", false); return }
        defer { joined.leaveGame(); host.leaveGame() }
        LANSelfTest.run([host, joined], seconds: 0.3)
        func sharedMessage(_ player: PlayController) -> GuiObject? {
            guard let root = player.gui.objects.values.first(where: { $0.name == "Sign" && $0.worldParent != nil }) else { return nil }
            return player.gui.children(of: root.id).compactMap(player.gui.object).first { $0.name == "Message" }
        }
        let hostText = sharedMessage(robin)?.text
        let joinText = sharedMessage(sam)?.text
        check("a host's world SurfaceGui update reaches the joined player's copy", hostText == "GO" && joinText == "GO", "\(hostText ?? "nil") / \(joinText ?? "nil")")
        func own(_ player: PlayController) -> String? {
            guard let root = player.gui.objects.values.first(where: { $0.name == "OwnSurface" }) else { return nil }
            return player.gui.children(of: root.id).first.flatMap(player.gui.object)?.text
        }
        check("PlayerGui surfaces retain independent local content", own(robin) == "Robin" && own(sam) == "Sam")
        LANSelfTest.run([host, joined], seconds: 0.4)
        check("an unrelated host property update preserves each player's local surface text",
              sharedMessage(robin)?.text == "Robin private" && sharedMessage(sam)?.text == "Sam private",
              "\(sharedMessage(robin)?.text ?? "nil") / \(sharedMessage(sam)?.text ?? "nil")")
        check("LocalScript changes on a shared surface stay off the wire",
              host.model.starterGui.first { $0.name == "Message" }?.object().text == "GO")
        let board = host.model.parts.first { $0.name == "RaceBoard" }!
        let clone = host.model.cloneSubtree(board.id, parent: nil)!
        host.model.update(id: clone) { $0.name = "CopiedBoard" }
        LANSelfTest.run([host, joined], seconds: 0.3)
        check("a live part clone brings its surface and LocalScript to both players",
              robin.console.lines.contains { $0.text == "surface copy CopiedBoard Robin" }
                && sam.console.lines.contains { $0.text == "surface copy CopiedBoard Sam" }
                && sam.gui.objects.values.contains { $0.worldParent == clone },
              robin.console.lines.map(\.text).joined(separator: " | ") + " / " + sam.console.lines.map(\.text).joined(separator: " | "))
        host.model.removeSubtrees([clone])
        LANSelfTest.run([host, joined], seconds: 0.3)
        check("deleting a shared surface retires each player's script scope",
              !robin.gui.objects.values.contains { $0.worldParent == clone }
                && !sam.gui.objects.values.contains { $0.worldParent == clone }
                && robin.worldGuiScripts.count == 1 && sam.worldGuiScripts.count == 1)
        check("surface scripts run without network errors", robin.console.errorCount == 0 && sam.console.errorCount == 0)
    }

    private static func testLifetime(_ check: Checker) {
        let model = SceneModel(); model.clearScene(); model.scripts = []; model.starterGui = []
        var board = Part(); board.name = "Board"; model.parts = [board]
        let root = model.addSurfaceGui(to: board.id)!
        let own = model.addGuiObject(.surfaceGui, in: nil)!
        model.renameGuiObject(own, to: "OwnCanvas")
        var script = ScriptObject.blank(language: .luau); script.host = .starterGui; script.parentID = root
        script.source = "while true do task.wait(0.02) print('pulse') end"
        model.scripts = [script]
        let player = PlayController(model: model, console: ScriptConsole()); player.start()
        defer { player.stop() }
        func run() { for _ in 0..<8 { player.step(dt: 1 / 60) }; RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        run()
        let originalWorld = player.guiCopies[root], originalOwn = player.guiCopies[own]
        player.respawnRequested = true; run()
        let count = player.console.lines.filter { $0.text == "pulse" }.count
        run()
        check("world surface scripts survive character respawn", player.guiCopies[root] == originalWorld && player.console.lines.filter { $0.text == "pulse" }.count > count)
        check("PlayerGui SurfaceGui ResetOnSpawn creates one fresh copy", player.guiCopies[own] != originalOwn && player.gui.objects.values.filter { $0.name == "OwnCanvas" }.count == 1)
        let clone = model.cloneSubtree(board.id, parent: nil)!
        run()
        check("a part cloned during play receives its world surface", player.gui.objects.values.contains { $0.worldParent == clone })
        if let id = player.guiCopies[root] { player.gui.destroy(id) }
        run()
        check("destroyed world surfaces are not recreated from their previous snapshot", player.guiCopies[root].flatMap(player.gui.object) == nil)
    }

    private static func testLocalHierarchy(_ check: Checker) {
        guard let (host, joined) = LANSelfTest.twoPlayers({ model in
            var part = Part(); part.name = "LocalBoard"; model.parts.append(part)
            let root = model.addSurfaceGui(to: part.id)!
            model.renameGuiObject(root, to: "LocalSign")
            for name in ["Destroyed", "Detached", "Moved", "Destination"] {
                let child = model.addGuiObject(.textLabel, in: root)!
                model.renameGuiObject(child, to: name)
            }
            let otherRoot = model.addSurfaceGui(to: part.id)!
            model.renameGuiObject(otherRoot, to: "HiddenSign")
            let otherLabel = model.addGuiObject(.textLabel, in: otherRoot)!
            model.renameGuiObject(otherLabel, to: "Label")
            var localScript = ScriptObject.blank(language: .luau); localScript.host = .starterPlayer
            localScript.source = """
            task.wait(0.1)
            if game:GetService('Players').LocalPlayer.Name == 'Sam' then
                workspace.LocalBoard.HiddenSign:Destroy()
                return
            end
            local sign = workspace.LocalBoard.LocalSign
            sign.Destroyed:Destroy()
            sign.Detached.Parent = nil
            sign.Moved.Parent = sign.Destination
            local child = Instance.new('Frame', sign.Destination)
            child.Name = 'PrivateChild'
            """
            var server = ScriptObject.blank(language: .luau)
            server.source = """
            task.wait(0.5)
            local sign = workspace.LocalBoard.LocalSign
            print('server hierarchy', #sign:GetChildren())
            sign.Destroyed.Text = 'server update'
            sign.Detached.Text = 'server update'
            sign.Moved.Text = 'server update'
            workspace.LocalBoard.HiddenSign.Label.Text = 'server update'
            task.wait(0.5)
            sign.Destroyed:Destroy()
            sign.Destination:Destroy()
            workspace.LocalBoard.HiddenSign:Destroy()
            """
            model.scripts += [localScript, server]
        }), let robin = host.player, let sam = joined.player else { check("local hierarchy players join", false); return }
        defer { joined.leaveGame(); host.leaveGame() }
        func sign(_ player: PlayController) -> GuiObject? { player.gui.objects.values.first { $0.name == "LocalSign" } }
        func children(_ player: PlayController) -> [GuiObject] { sign(player).map { player.gui.children(of: $0.id).compactMap(player.gui.object) } ?? [] }
        LANSelfTest.run([host, joined], seconds: 0.3)
        check("local Destroy and reparent keep the other player's shared hierarchy intact",
              children(robin).count == 1 && children(sam).count == 4)
        LANSelfTest.run([host, joined], seconds: 0.4)
        check("server scripts retain access after local hierarchy overrides",
              robin.console.lines.contains { $0.text == "server hierarchy 4" }
                && children(sam).first { $0.name == "Destroyed" }?.text == "server update"
                && children(robin).count == 1)
        check("a joined player's destroyed root stays hidden through server updates",
              !sam.gui.objects.values.contains { $0.name == "HiddenSign" }
                && robin.gui.objects.values.contains { $0.name == "HiddenSign" })
        LANSelfTest.run([host, joined], seconds: 0.5)
        check("a later server Destroy removes the shared object without reviving local copies",
              children(sam).count == 2 && children(robin).isEmpty
                && robin.console.errorCount == 0 && sam.console.errorCount == 0)
        check("server destruction also retires locally added descendants",
              !robin.gui.objects.values.contains { $0.name == "PrivateChild" })
    }
}
