import Foundation
import Metal
import simd

/// Identified local lights: scripting, persistence, editor operations, drawing and LAN.
enum DirectionalLightSelfTest {
    static func run(check: Checker) {
        testScripts(check)
        testModel(check)
        testDrawing(check)
        testTogether(check)
        testLooseLifetime(check)
    }

    private static func testScripts(_ check: Checker) {
        print("\nDirectional lights: scripts")
        let model = ScriptSelfTest.scene()
        ScriptSelfTest.add(model, """
        local p = workspace.Brick
        local spot = Instance.new("SpotLight")
        spot.Name = "Beam"
        spot.Angle = 37
        spot.Face = Enum.NormalId.Bottom
        spot.Color = Color3.new(1, 0.5, 0.25)
        spot.Parent = p
        local surface = Instance.new("SurfaceLight", p)
        local point = Instance.new("PointLight", p)
        local second = Instance.new("PointLight", p)
        print(spot.ClassName, spot:IsA("Light"), spot:IsA("SpotLight"), spot:IsA("PointLight"))
        print(p.Beam == spot, p:FindFirstChildOfClass("SurfaceLight") == surface, #p:GetChildren())
        print(spot.Angle, spot.Face == Enum.NormalId.Bottom, spot.Color.G)
        spot.Parent = workspace.Orb
        print(p:FindFirstChild("Beam") == nil, workspace.Orb.Beam == spot, spot.Angle)
        local copy = spot:Clone()
        copy.Name = "Copy"
        copy.Parent = p
        copy.Angle = 400
        print(copy ~= spot, copy.ClassName, copy.Angle, spot.Angle)
        spot:Destroy()
        local replacement = Instance.new("SpotLight", workspace.Orb)
        replacement.Angle = 12
        print(spot.Parent, spot.Angle, replacement.Angle)
        local faceOK = pcall(function() copy.Face = "Top" end)
        local rangeOK = pcall(function() copy.Range = 0/0 end)
        print(faceOK, rangeOK)
        print(point ~= second, point.Parent == second.Parent)
        """)
        let result = ScriptSelfTest.execute(model)
        check("all three classes create and run", result.errors.isEmpty, "\(result.errors)")
        let out = result.output
        let expected = ["SpotLight true true false", "true true 4", "37 true 0.5", "true true 37",
                        "true SpotLight 180 37", "nil 37 12", "false false", "true true"]
        for (i, line) in expected.enumerated() {
            check("directional light API \(i + 1): \(line)", out.count > i && out[i] == line, "\(out)")
        }
    }
    private static func testModel(_ check: Checker) {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let old = Data("{\"id\":\"\(id.uuidString)\",\"light\":{\"brightness\":4}}".utf8)
        let first = try? JSONDecoder().decode(Part.self, from: old)
        let second = try? JSONDecoder().decode(Part.self, from: old)
        check("old point lights migrate once with a stable ID", first?.lights.count == 1 && first?.lights.first?.id == second?.lights.first?.id && first?.light?.brightness == 4)
        var duplicate = first!; duplicate.id = UUID()
        var repair = SceneState(); repair.parts = [first!, duplicate]
        let repaired = repair.repairingDuplicateIDs()
        check("duplicate light IDs are repaired when a place opens", repaired.parts[0].lights[0].id != repaired.parts[1].lights[0].id)

        let model = ScriptSelfTest.scene()
        let part = model.parts[0].id
        guard let spot = model.addLight(.spot, to: part), let surface = model.addLight(.surface, to: part) else { return }
        model.commit("Aim beam") { model.updateLight(spot) { $0.name = "Beam"; $0.face = .bottom; $0.angle = 43 } }
        let bytes = try? JSONEncoder().encode(model.state)
        let restored = bytes.flatMap { try? JSONDecoder().decode(SceneState.self, from: $0) }
        check("multiple lights, names, faces and IDs save", restored?.parts.first?.lights == model.parts[0].lights)
        model.undo()
        check("light property edit undoes", model.light(spot)?.name == "SpotLight")
        model.redo()
        check("light property edit redoes", model.light(spot)?.angle == 43)
        model.removeLight(surface)
        check("delete removes only its light", model.light(surface) == nil && model.light(spot) != nil)
        model.undo()
        check("undo restores the same light", model.light(surface)?.kind == .surface)
        let copy = model.cloneSubtree(part, parent: nil).flatMap(model.part(id:))
        check("cloning a containing part remaps light IDs", copy?.lights.count == 2 && Set(copy!.lights.map(\.id)).isDisjoint(with: model.part(id: part)!.lights.map(\.id)))
        model.selectedLight = spot
        check("selecting a light clears part selection", model.selection.isEmpty && model.hasAnySelection)
        model.deselectAll()
        check("deselect clears a light", model.selectedLight == nil && !model.hasAnySelection)
        model.selectedLight = spot; model.selectedAttachment = UUID()
        check("selecting an attachment leaves the light", model.selectedLight == nil)
        model.selectedLight = spot; model.selectedConstraint = UUID()
        check("selecting a constraint leaves the light", model.selectedLight == nil)
        model.selectedLight = spot; model.selectCoreScript(named: "Health")
        check("opening a core script leaves the light", model.selectedLight == nil)

        model.selectedLight = spot
        model.deleteSelected()
        check("Delete key removes the selected light", model.light(spot) == nil && model.light(surface) != nil)
        model.undo()
        model.selectedLight = spot
        model.commit("Delete parent") { model.removeSubtrees([part]) }
        check("deleting a parent removes its lights and selection", model.light(spot) == nil && model.selectedLight == nil)
        model.undo()
        model.selection = [model.parts[0].id]
        do {
            if let data = try SceneDocument(model: model).modelData(name: "Lights") {
                let destination = SceneModel(); destination.parts = []
                _ = try SceneDocument(model: destination).insertModel(from: data, at: .zero)
                let loaded = destination.parts.first?.lights ?? []
                check("model export and insertion carry lights with fresh identities", loaded.count == 2
                      && loaded.map(\.kind) == model.parts[0].lights.map(\.kind)
                      && Set(loaded.map(\.id)).isDisjoint(with: model.parts[0].lights.map(\.id)))
            } else { check("model export has data", false) }
        } catch { check("model export and insertion", false, "\(error)") }

    }

    private static func testDrawing(_ check: Checker) {
        print("\nDirectional lights: pixels")
        let model = SceneModel()
        model.scripts = []; model.groups = []; model.shaders = []; model.showGrid = false
        model.lighting.brightness = 0
        model.lighting.ambient = Vec3(repeating: 0.02)
        model.lighting.outdoorAmbient = .zero
        model.lighting.globalShadows = false
        var floor = Part(); floor.position = Vec3(0, -0.5, 0); floor.size = Vec3(50, 1, 50)
        floor.color = Vec3(repeating: 0.65)
        var lamp = Part(); lamp.position = Vec3(0, 6, 0); lamp.size = Vec3(12, 1, 4)
        var beam = PointLight(kind: .spot); beam.face = .bottom; beam.angle = 40; beam.brightness = 6; beam.range = 20
        lamp.lights = [beam]; model.parts = [floor, lamp]
        let gpu = PointLightData(part: lamp, light: beam)
        check("light uniform holds the face normal and full face size", MemoryLayout<PointLightData>.stride == 96
              && gpu.directionAngle.y == -1 && gpu.surfaceU.w == 6 && gpu.surfaceV.w == 2
              && abs(gpu.positionRange.y - 5.475) < 0.001)

        var camera = Camera(); camera.target = Vec3(0, 0, 1); camera.distance = 29; camera.pitch = 0.75; camera.yaw = .pi / 2
        func render() -> LightingSelfTest.Frame? { LightingSelfTest.render(model, camera: camera)?.0 }
        guard let spot = render() else { check("directional lights render", false); return }
        let center = Vec3(0, 0.01, 0), outside = Vec3(7, 0.01, 0), edge = Vec3(4.5, 0.01, 0)
        check("spot cone illuminates inside and excludes outside", spot.brightness(at: center) > spot.brightness(at: outside) * 4,
              "\(spot.brightness(at: center)) vs \(spot.brightness(at: outside))")
        model.updateLight(beam.id) { $0.enabled = false }
        let disabled = render()!
        check("disabled spot contributes no light", disabled.brightness(at: center) < spot.brightness(at: center) * 0.3)
        model.updateLight(beam.id) { $0.enabled = true; $0.range = 3 }
        check("spot range excludes distant receivers", render()!.brightness(at: center) < spot.brightness(at: center) * 0.3)
        model.updateLight(beam.id) { $0.range = 20; $0.face = .top }
        check("spot face points emission away", render()!.brightness(at: center) < spot.brightness(at: center) * 0.3)
        model.updateLight(beam.id) { $0.face = .bottom; $0.kind = .surface; $0.angle = 30 }
        let surface = render()!
        check("surface lights emit across the rectangular face", surface.brightness(at: edge) > spot.brightness(at: edge) * 3,
              "\(surface.brightness(at: edge)) vs \(spot.brightness(at: edge))")
        model.update(id: lamp.id) { $0.orientation = simd_quatf(angle: .pi, axis: Vec3(1, 0, 0)) }
        check("rotating the part rotates its emitting face", render()!.brightness(at: edge) < surface.brightness(at: edge) * 0.4)
        if let device = MTLCreateSystemDefaultDevice(), Renderer.canRayTrace(device) {
            model.update(id: lamp.id) { $0.orientation = simd_quatf(angle: 0, axis: Vec3(1, 0, 0)) }
            model.lighting.technology = .rayTraced
            model.lighting.reflections = false
            model.updateLight(beam.id) { $0.kind = .spot; $0.angle = 70; $0.shadows = false }
            var blocker = Part(); blocker.position = Vec3(0, 2.5, 0); blocker.size = Vec3(4, 0.4, 3)
            model.parts.append(blocker)
            // Camera sees the floor from the front, below the blocker at this receiver.
            camera.pitch = 0.2; camera.target = Vec3(0, 0, 1)
            let receiver = Vec3(0, 0.01, 0.8)
            let open = render()!
            model.updateLight(beam.id) { $0.shadows = true }
            let shadow = render()!
            check("ray-traced spot shadows are blocked by intervening geometry", shadow.brightness(at: receiver) < open.brightness(at: receiver) * 0.6,
                  "\(shadow.brightness(at: receiver)) vs \(open.brightness(at: receiver))")
            model.parts.removeAll { $0.id == blocker.id }
            let unobstructed = render()!
            check("a spot's housing does not shadow its own emitting face", unobstructed.brightness(at: receiver) > shadow.brightness(at: receiver) * 2)
            model.updateLight(beam.id) { $0.kind = .surface; $0.angle = 50 }
            let area = render()!
            check("ray tracing also shades the extended surface", area.brightness(at: edge) > disabled.brightness(at: edge) * 2)
        }

    }

    private static func testTogether(_ check: Checker) {
        print("\nDirectional lights: a host and joined player")
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            var floor = Part(); floor.name = "Floor"; floor.position = Vec3(0, -0.5, 0); floor.size = Vec3(100, 1, 100)
            var lamp = Part(); lamp.name = "Lamp"; lamp.position = Vec3(0, 7, 0)
            for kind in PointLight.Kind.allCases {
                var light = PointLight(kind: kind); light.range = 18; light.face = .bottom
                lamp.lights.append(light)
            }
            var other = Part(); other.name = "Other"; other.position = Vec3(8, 7, 0)
            model.parts = [floor, lamp, other]
            model.lighting.brightness = 0; model.lighting.ambient = Vec3(repeating: 0.03)
            model.lighting.outdoorAmbient = .zero; model.lighting.globalShadows = false
            var host = ScriptObject.blank(language: .luau)
            host.source = """
            task.wait(1)
            for _, light in workspace.Lamp:GetChildren() do
                light.Name = "Moved" .. light.ClassName
                light.Color = Color3.new(0.25, 0.8, 1)
                light.Brightness = 3
                light.Range = 24
                light.Shadows = true
                if not light:IsA("PointLight") then light.Angle = 55; light.Face = Enum.NormalId.Bottom end
                light.Parent = workspace.Other
            end
            """
            var localScript = ScriptObject.blank(language: .luau); localScript.host = .starterPlayer
            localScript.source = """
            local lamp = workspace:WaitForChild("Lamp")
            assert(lamp:WaitForChild("SpotLight"):IsA("Light"))
            assert(lamp.SurfaceLight.ClassName == "SurfaceLight")
            print("Lights loaded for " .. game:GetService("Players").LocalPlayer.Name)
            task.wait(1.5)
            local spot = workspace.Other:WaitForChild("MovedSpotLight")
            assert(spot.Brightness == 3 and spot.Range == 24 and spot.Face == Enum.NormalId.Bottom)
            print("Lights changed for " .. game:GetService("Players").LocalPlayer.Name)
            """
            model.scripts += [host, localScript]
        }) else { check("directional-light players join", false); return }
        defer { joining.leaveGame(); hosting.leaveGame() }
        func lights(_ session: ClientSession, _ name: String) -> [PointLight] { session.model.parts.first { $0.name == name }?.lights ?? [] }
        check("joined snapshot contains every light with the same stable identity", lights(hosting, "Lamp").count == 3 && lights(hosting, "Lamp") == lights(joining, "Lamp"))
        LANSelfTest.run([hosting, joining], seconds: 2)
        check("host property edits and parenting reach the joiner", lights(hosting, "Lamp").isEmpty && lights(joining, "Lamp").isEmpty
              && lights(hosting, "Other").count == 3 && lights(hosting, "Other") == lights(joining, "Other"))
        for (session, name) in [(hosting, "Robin"), (joining, "Sam")] {
            let output = session.player!.console.lines
            let errors = output.filter { $0.kind == .error }.map(\.text)
            check("\(name) reads the original and changed light API without errors", errors.isEmpty
                  && output.contains { $0.text == "Lights loaded for " + name }
                  && output.contains { $0.text == "Lights changed for " + name }, "\(errors)")
        }
        var camera = Camera(); camera.target = Vec3(8, 0, 0); camera.distance = 26; camera.pitch = 0.6; camera.yaw = .pi / 2
        if let host = LightingSelfTest.render(hosting.model, camera: camera)?.0,
           let joined = LightingSelfTest.render(joining.model, camera: camera)?.0 {
            let point = Vec3(8, 0.01, 0)
            check("host and joiner render the same directional illumination", host.brightness(at: point) > 0.1
                  && abs(host.brightness(at: point) - joined.brightness(at: point)) < 0.01,
                  "\(host.brightness(at: point)) vs \(joined.brightness(at: point))")
        } else { check("host and joiner light frames render", false) }
    }

    private static func testLooseLifetime(_ check: Checker) {
        let model = ScriptSelfTest.scene()
        ScriptSelfTest.add(model, "local loose = Instance.new(\"SpotLight\")")
        let runtime = ScriptRuntime(model: model, console: ScriptConsole())
        runtime.start()
        check("a new loose light is retained for its script", runtime.looseLights.count == 1)
        runtime.stop()
        check("stopping discards loose lights", runtime.looseLights.isEmpty)
    }

}
