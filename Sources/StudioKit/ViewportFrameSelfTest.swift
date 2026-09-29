import AppKit
import Metal
import simd
import SwiftUI

enum ViewportFrameSelfTest {
    static func run(check: Checker) { testScripts(check); testScriptIsolation(check); testDrawing(check); testGuiComposition(check); testMeshes(check); testSaving(check); testTogether(check) }

    private static func testScripts(_ check: Checker) {
        let model = ScriptSelfTest.scene()
        ScriptSelfTest.add(model, """
        local player = game:GetService("Players").LocalPlayer
        local screen = Instance.new("ScreenGui", player.PlayerGui)
        local view = Instance.new("ViewportFrame", screen)
        view.Name = "Preview"
        view.Ambient = Color3.new(0.2, 0.3, 0.4)
        view.LightColor = Color3.new(1, 0.9, 0.8)
        view.LightDirection = Vector3.new(-1, -1, -1)
        local camera = Instance.new("Camera", view)
        camera.CFrame = CFrame.lookAt(Vector3.new(0, 2, 12), Vector3.new(0, 0, 0))
        camera.Focus = CFrame.new(0, 0, 0)
        camera.FieldOfView = 45
        view.CurrentCamera = camera
        local original = workspace.Brick
        local copy = original:Clone()
        copy.Name = "PreviewBrick"
        copy.Parent = view
        copy.Position = Vector3.new(0, 0, 0)
        print("preview", copy.Parent == view, view.PreviewBrick == copy, workspace:FindFirstChild("PreviewBrick") == nil)
        print("camera", view.CurrentCamera == camera, camera.FieldOfView, camera.Parent == view, camera:IsA("Camera"))
        print("count", #view:GetChildren(), copy.Position == Vector3.zero, original.Position ~= copy.Position)
        copy.Position = Vector3.new(1000, 100, 1000)
        print("ray isolation", workspace:Raycast(Vector3.new(1000,100,1010), Vector3.new(0,0,-20)) == nil)
        copy.Position = Vector3.zero
        copy.Parent = workspace
        print("out", workspace.PreviewBrick == copy, view:FindFirstChild("PreviewBrick") == nil)
        local group = Instance.new("Model", view)
        group.Name = "Display"
        copy.Parent = group
        print("group", group.Parent == view, copy.Parent == group, workspace:FindFirstChild("PreviewBrick", true) == nil)
        local copied = group:Clone()
        copied.Parent = view
        print("clone", copied ~= group, #copied:GetChildren())
        local badFov = pcall(function() camera.FieldOfView = 0/0 end)
        local badCamera = pcall(function() view.CurrentCamera = original end)
        print("bad", badFov, badCamera)
        view.CurrentCamera = nil
        print("empty", view.CurrentCamera == nil)
        print("ancestry", camera:IsDescendantOf(view), view:IsAncestorOf(camera), camera:FindFirstAncestor("Preview") == view)
        camera.Parent = nil
        view.CurrentCamera = camera
        local clonedView = view:Clone()
        print("gui clone", clonedView.Parent == nil, clonedView.CurrentCamera ~= camera, clonedView.CurrentCamera.FieldOfView == 45,
            clonedView:FindFirstChild("PreviewBrick", true) ~= copy)
        clonedView:Destroy()
        camera:Destroy()
        group:Destroy()
        view:Destroy()
        print("gone", copy.Parent == nil)
        """)
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        for _ in 0..<4 { session.step(dt: 1 / 60) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        let out = session.console.lines.map(\.text)
        check("ViewportFrame and Camera script runs", errors.isEmpty, "\(errors)")
        for expected in ["preview true true true", "camera true 45 true true", "count 2 true true", "out true true", "ray isolation true",
                         "group true true true", "clone true 1", "bad false false", "empty true", "ancestry true true true", "gui clone true true true true", "gone true"] {
            check(expected, out.contains(expected), "\(out)")
        }
        session.stop()
    }
    private static func testScriptIsolation(_ check: Checker) {
        let model = ScriptSelfTest.scene()
        let template = SceneGroup(name: "ScriptedPreview", kind: .model)
        model.groups.append(template)
        var part = Part(); part.parentID = template.id; model.parts.append(part)
        var attached = ScriptObject.blank(language: .luau); attached.name = "Attached"
        attached.parentID = template.id
        attached.source = "print(\"attached started\", script.Parent.Name)"
        model.scripts.append(attached)
        model.setStorage(template.id, .serverStorage)
        ScriptSelfTest.add(model, """
        local view = Instance.new("ViewportFrame", game:GetService("Players").LocalPlayer.PlayerGui)
        local template = game:GetService("ServerStorage").ScriptedPreview
        local preview = template:Clone()
        preview.Name = "PreviewOnly"
        preview.Parent = view
        local live = template:Clone()
        live.Name = "LiveCopy"
        task.wait()
        local delayed = template:Clone()
        delayed.Name = "PreviewThenWorld"
        delayed.Parent = view
        task.wait()
        delayed.Parent = workspace
        task.wait()
        view:Destroy()
        """)
        let session = PlayController(model: model, console: ScriptConsole()); session.start()
        for _ in 0..<8 { session.step(dt: 1 / 60) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        let lines = session.console.lines.map(\.text)
        check("cloning a stored model into a preview never starts its attached scripts",
              !lines.contains("attached started PreviewOnly") && !lines.contains("attached started ScriptedPreview"), "\(lines)")
        check("a stored clone left in Workspace starts its attached script once",
              lines.filter { $0 == "attached started LiveCopy" }.count == 1, "\(lines)")
        check("moving a preview model into Workspace starts its attached script once",
              lines.filter { $0 == "attached started PreviewThenWorld" }.count == 1, "\(lines)")
        check("preview transfer scripts have no errors", !session.console.lines.contains { $0.kind == .error }, "\(lines)")
        session.stop()
    }

    private static func content() -> ViewportContent {
        var part = Part(); part.name = "PreviewBrick"; part.position = .zero; part.size = Vec3(4, 4, 4); part.color = Vec3(1, 0.05, 0.02)
        let camera = PreviewCamera()
        return ViewportContent(parts: [part], cameras: [camera], currentCamera: camera.id)
    }

    private static func testDrawing(_ check: Checker) {
        print("\nViewportFrame: rendered pixels and resources")
        let store = GuiStore(); let screen = store.create(.screenGui); store.setParent(screen, to: 0)
        let frame = store.create(.viewportFrame); store.setParent(frame, to: screen)
        store.installViewport(content(), in: frame)
        store.update(frame) { $0.size = UDim2(xOffset: 200, yOffset: 160); $0.backgroundTransparency = 1 }
        func render(_ id: Int = frame, _ size: CGSize = CGSize(width: 200, height: 160)) -> NSImage? { store.viewportImage(store.object(id)!, size: size) }
        func pixel(_ image: NSImage?, _ x: Int, _ y: Int) -> NSColor {
            guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .clear }
            return NSBitmapImageRep(cgImage: cg).colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) ?? .clear
        }
        let image = render(), center = pixel(image, 100, 80), corner = pixel(image, 2, 2)
        check("preview draws its red geometry over a transparent background", center.redComponent > 0.4 && center.redComponent > center.greenComponent * 2 && corner.alphaComponent == 0,
              "\(center) \(corner)")
        let count = ViewportRenderer.shared?.renderCount
        _ = render()
        check("unchanged preview reuses its rendered image", ViewportRenderer.shared?.renderCount == count)
        for _ in 0..<5 { store.installViewport(content(), in: frame) }
        check("replacing authored preview content releases old cameras", store.previewCameras.count == 1)
        let second = store.cloneGui(frame)!
        let secondCamera = store.object(second)!.currentCamera!
        store.previewCameras[secondCamera]!.frame.orientation = simd_quatf(angle: .pi, axis: Vec3(0, 1, 0))
        check("a second preview's camera is independent", pixel(render(second), 100, 80).alphaComponent == 0 && pixel(render(), 100, 80).redComponent > 0.4)
        let world = store.viewport(frame)!, id = world.model.parts[0].id
        world.model.update(id: id) { $0.color = Vec3(0.02, 1, 0.05) }
        let changed = pixel(render(), 100, 80)
        check("part edits redraw the preview", changed.greenComponent > changed.redComponent * 2)
        let resized = render(frame, CGSize(width: 300, height: 180))
        check("resizing recreates correctly sized render targets", resized?.size == CGSize(width: 300, height: 180))
        world.model.update(id: id) { $0.transparency = 0.5 }
        let translucent = pixel(render(), 100, 80)
        check("preview geometry transparency reaches its image", translucent.alphaComponent > 0.45 && translucent.alphaComponent < 0.9, "\(translucent.alphaComponent)")
        store.update(frame) { $0.currentCamera = nil }
        check("nil CurrentCamera leaves the preview empty", render() == nil)
        store.destroy(frame); store.destroy(second)
        check("destroy releases preview scenes, cameras and images", store.viewportWorlds.isEmpty && store.previewCameras.isEmpty && ViewportRenderer.shared?.cachedImageCount == 0)
        for _ in 0..<25 {
            let id = store.create(.viewportFrame); store.installViewport(content(), in: id); _ = render(id)
        }
        check("the preview image cache stays bounded", (ViewportRenderer.shared?.cachedImageCount ?? 100) <= 16)
        store.removeAll()
        check("clearing GUI releases the bounded cache", ViewportRenderer.shared?.cachedImageCount == 0)
    }

    private static func testGuiComposition(_ check: Checker) {
        let store = GuiStore(); let screen = store.create(.screenGui); store.setParent(screen, to: 0)
        let clip = store.create(.frame); store.setParent(clip, to: screen)
        store.update(clip) { $0.position = UDim2(xOffset: 20, yOffset: 20); $0.size = UDim2(xOffset: 80, yOffset: 120)
            $0.backgroundTransparency = 1; $0.clipsDescendants = true }
        let frame = store.create(.viewportFrame); store.setParent(frame, to: clip)
        var geometry = content(); geometry.parts[0].color = Vec3(repeating: 1); geometry.parts[0].size = Vec3(8, 8, 8)
        store.installViewport(geometry, in: frame)
        store.update(frame) { $0.size = UDim2(xOffset: 120, yOffset: 120); $0.backgroundTransparency = 1
            $0.viewportAmbient = Vec3(repeating: 1); $0.viewportLightColor = .zero
            $0.imageColor = Vec3(0.02, 0.1, 1); $0.imageTransparency = 0.5 }
        let cg: CGImage? = MainActor.assumeIsolated {
            let renderer = ImageRenderer(content: GuiLayer(store: store, interactive: false).frame(width: 180, height: 160))
            renderer.scale = 1; return renderer.cgImage
        }
        let bitmap = cg.map(NSBitmapImageRep.init(cgImage:))
        let inside = bitmap?.colorAt(x: 60, y: 80)?.usingColorSpace(.deviceRGB)
        let outside = bitmap?.colorAt(x: 110, y: 80)?.usingColorSpace(.deviceRGB)
        check("ViewportFrame composites ImageColor3 and ImageTransparency", inside.map { $0.blueComponent > 0.7 && $0.redComponent < 0.15 && abs($0.alphaComponent - 0.5) < 0.05 } == true, "\(String(describing: inside))")
        check("ViewportFrame respects its clipping ancestor", outside?.alphaComponent == 0, "\(String(describing: outside))")
        store.removeAll()
    }

    private static func testMeshes(_ check: Checker) {
        let store = GuiStore(); let frame = store.create(.viewportFrame); let world = store.viewport(frame)!
        let mesh = try? world.model.importAsset(data: MeshSelfTest.arch, name: "Arch", fileExtension: "obj")
        let picture = try? world.model.importAsset(data: AudioSelfTest.png(red: 0.04, green: 0.1, blue: 0.94), name: "Blue", fileExtension: "png")
        guard let mesh, picture != nil else { check("preview mesh fixture loads", false); return }
        var part = Part(); part.mesh = MeshSettings(meshId: "studio://Arch", asset: mesh, textureId: "studio://Blue")
        part.color = Vec3(repeating: 1); part.size = Vec3(7, 5, 1); part.position = .zero
        world.model.parts = [part]
        var camera = PreviewCamera(); camera.parent = frame; store.previewCameras[camera.id] = camera
        store.update(frame) { $0.currentCamera = camera.id; $0.viewportAmbient = Vec3(repeating: 1); $0.viewportLightColor = .zero }
        let image = store.viewportImage(store.object(frame)!, size: CGSize(width: 240, height: 180))
        let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let bitmap = cg.map(NSBitmapImageRep.init(cgImage:))
        let opening = bitmap?.colorAt(x: 120, y: 100)?.usingColorSpace(.deviceRGB)
        let pillar = bitmap?.colorAt(x: 80, y: 100)?.usingColorSpace(.deviceRGB)
        check("preview renders imported mesh openings", opening?.alphaComponent == 0 && (pillar?.alphaComponent ?? 0) > 0.9, "\(String(describing: opening)), \(String(describing: pillar))")
        check("preview renders MeshPart textures", pillar.map { $0.blueComponent > 0.5 && $0.blueComponent > $0.redComponent * 3 } == true, "\(String(describing: pillar))")
        store.removeAll()
    }

    private static func testSaving(_ check: Checker) {
        let model = ScriptSelfTest.scene()
        let screen = model.addGuiObject(.screenGui, in: nil)!
        let frame = model.addGuiObject(.viewportFrame, in: screen)!
        model.commit("Preview content") {
            let index = model.starterGui.firstIndex { $0.id == frame }!
            model.starterGui[index].viewportContent = content()
        }
        let data = try? JSONEncoder().encode(model.state)
        let loaded = data.flatMap { try? JSONDecoder().decode(SceneState.self, from: $0) }
        check("authored geometry and camera save with their GUI", loaded?.starterGui.first { $0.id == frame }?.viewportContent == model.guiObject(id: frame)?.viewportContent)
        model.undo()
        check("authoring preview content undoes", model.guiObject(id: frame)?.viewportContent == nil)
        model.redo()
        let store = GuiStore(); let first = store.copy(model.guiObject(id: screen)!, from: model.starterGui, into: 0)
        let second = store.copy(model.guiObject(id: screen)!, from: model.starterGui, into: 0)
        let a = store.viewportContent(first[frame]!)!, b = store.viewportContent(second[frame]!)!
        check("each copied template gets independent geometry and cameras", a.parts[0].id != b.parts[0].id && a.currentCamera != b.currentCamera
              && a.currentCamera == a.cameras[0].id && b.currentCamera == b.cameras[0].id)
        check("preview copies never enter the main scene", model.parts.allSatisfy { $0.name != "PreviewBrick" })
        let duplicate = model.duplicateGui(frame)!
        let original = model.guiObject(id: frame)!.viewportContent!, copied = model.guiObject(id: duplicate)!.viewportContent!
        check("duplicating authored GUI remaps preview geometry and cameras", original.parts[0].id != copied.parts[0].id
              && original.currentCamera != copied.currentCamera && copied.currentCamera == copied.cameras[0].id)
        let host = model.parts[0].id
        var surface = StarterGuiObject(kind: .surfaceGui, name: "Display"); surface.worldParent = host
        var nested = StarterGuiObject(kind: .viewportFrame, name: "Preview", parentID: surface.id); nested.viewportContent = content()
        model.starterGui += [surface, nested]; model.selection = [host]
        let modelData = try? SceneDocument(model: model).modelData(name: "DisplayModel")
        let target = ScriptSelfTest.scene(); target.starterGui = []
        let inserted = modelData.flatMap { try? SceneDocument(model: target).insertModel(from: $0, at: .zero) }
        let saved = target.starterGui.first { $0.kind == .viewportFrame }?.viewportContent
        check("model export and insertion carry an independent authored preview", inserted != nil && saved?.parts.count == 1
              && saved?.parts[0].id != nested.viewportContent!.parts[0].id && saved?.currentCamera == saved?.cameras[0].id)
        store.removeAll()
    }

    private static func testTogether(_ check: Checker) {
        print("\nViewportFrame: host and joined player")
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            var floor = Part(); floor.name = "Floor"; floor.size = Vec3(100, 1, 100); floor.position = Vec3(0, -0.5, 0); model.parts = [floor]
            let screen = model.addGuiObject(.screenGui, in: nil)!
            let frame = model.addGuiObject(.viewportFrame, in: screen)!
            let index = model.starterGui.firstIndex { $0.id == frame }!; model.starterGui[index].name = "Preview"
            model.starterGui[index].viewportContent = content()
            var script = ScriptObject.blank(language: .luau); script.host = .starterGui; script.parentID = frame
            script.source = """
            assert(script.Parent.ClassName == "ViewportFrame")
            local preview = script.Parent
            local p = game:GetService("Players").LocalPlayer
            assert(preview.PreviewBrick and not workspace:FindFirstChild("PreviewBrick", true))
            if p.Name == "Sam" then preview.CurrentCamera.FieldOfView = 35 else preview.CurrentCamera.FieldOfView = 80 end
            preview.PreviewBrick.Color = if p.Name == "Sam" then Color3.new(0,1,0) else Color3.new(1,0,0)
            print("Preview ready for " .. p.Name)
            """
            model.scripts.append(script)
        }) else { check("viewport players join", false); return }
        defer { joining.leaveGame(); hosting.leaveGame() }
        LANSelfTest.run([hosting, joining], seconds: 0.8)
        for (session, name, fov) in [(hosting, "Robin", Float(80)), (joining, "Sam", Float(35))] {
            let gui = session.player!.gui
            let object = gui.objects.values.first { $0.kind == .viewportFrame }!
            let camera = object.currentCamera.flatMap { gui.previewCameras[$0] }
            let errors = session.player!.console.lines.filter { $0.kind == .error }.map(\.text)
            check("\(name)'s authored preview runs with a local camera", camera?.fieldOfView == fov && errors.isEmpty, "\(errors)")
            let preview = gui.viewport(object.id)!.model.parts[0]
            check("\(name)'s preview geometry stays out of their world", !session.model.parts.contains { $0.name == "PreviewBrick" }
                  && gui.viewport(object.id)?.model.parts.count == 1)
            check("\(name)'s preview never becomes a physics body", session.player!.physics.motion(of: preview.id) == nil)
        }
        let hostFrame = hosting.player!.gui.objects.values.first { $0.kind == .viewportFrame }!
        let joinFrame = joining.player!.gui.objects.values.first { $0.kind == .viewportFrame }!
        let hostColor = hosting.player!.gui.viewport(hostFrame.id)!.model.parts[0].color
        let joinColor = joining.player!.gui.viewport(joinFrame.id)!.model.parts[0].color
        check("one player's preview changes do not alter the other's", hostColor == Vec3(1, 0, 0) && joinColor == Vec3(0, 1, 0))
    }

}
