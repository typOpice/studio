import Foundation
import Metal
import MetalKit
import simd

/// Verification for lighting: the sun and sky maths, settings and saving, the Luau
/// Lighting and PointLight API — and rendered frames, read back pixel by pixel, to
/// check that shadows, point lights, fog, exposure, night and ray tracing really
/// change the picture the way they should.
enum LightingSelfTest {

    static func run(check: Checker) {
        testSun(check)
        testSettings(check)
        testUniformLayout(check)
        testScripting(check)
        testCompletion(check)
        testUserShaderVariants(check)
        testRendering(check)
        testReadmeExample(check)
    }

    /// The README's Lighting script, verbatim, in the starter scene.
    private static func testReadmeExample(_ check: Checker) {
        let model = SceneModel()
        var script = ScriptObject.blank(language: .luau)
        script.source = """
        local Lighting = game:GetService("Lighting")
        game:GetService("RunService").Heartbeat:Connect(function(dt)
        \tLighting.ClockTime += dt * 0.5          -- a day every 48 seconds
        end)

        local lamp = Instance.new("PointLight", workspace.Tower)
        lamp.Color = Color3.fromRGB(255, 180, 90)
        lamp.Range = 16
        """
        model.scripts = [script]
        let result = ScriptSelfTest.execute(model, ticks: 60, dt: 1.0 / 30)
        let tower = model.parts.first { $0.name == "Tower" }
        check("the README lighting example runs",
              result.errors.isEmpty && near(model.lighting.clockTime, 15, 0.02) && tower?.light?.range == 16,
              "\(result.errors) \(model.lighting.clockTime)")
    }

    private static func near(_ a: Float, _ b: Float, _ tolerance: Float = 1e-3) -> Bool { abs(a - b) <= tolerance }

    // MARK: - The sun

    private static func testSun(_ check: Checker) {
        print("\nLighting: sun and sky")
        var lighting = LightingSettings()
        lighting.geographicLatitude = 0
        lighting.clockTime = 12
        check("at the equator the noon sun is overhead", near(lighting.sunDirection.y, 1), "\(lighting.sunDirection)")
        lighting.clockTime = 6
        check("it rises in the east (+X) at 6:00",
              near(lighting.sunDirection.x, 1) && near(lighting.sunDirection.y, 0), "\(lighting.sunDirection)")
        lighting.clockTime = 18
        check("and sets in the west at 18:00", near(lighting.sunDirection.x, -1), "\(lighting.sunDirection)")

        lighting = LightingSettings()
        lighting.clockTime = 12
        check("further north, the noon sun is lower and to the south",
              near(lighting.sunDirection.y, cos(41.73 * .pi / 180)) && lighting.sunDirection.z > 0.5)
        lighting.clockTime = 0
        check("at midnight the light comes from the moon", lighting.lightDirection.y > 0 && lighting.sunDirection.y < 0)
        check("…which is far dimmer", length(lighting.sunLight) < 0.3 && lighting.daylight < 0.2)
        lighting.clockTime = 12
        let noon = lighting.sunLight
        lighting.clockTime = 18.2
        let dusk = lighting.sunLight
        check("sunlight warms towards dusk", dusk.x > dusk.z * 1.3 && noon.x < noon.z * 1.05, "\(dusk) \(noon)")
        lighting.clockTime = 26
        check("ClockTime wraps into a day", lighting.timeOfDay == "02:00:00", lighting.timeOfDay)
        check("TimeOfDay parses", LightingSettings.hours(fromTimeOfDay: "13:30") == 13.5
              && LightingSettings.hours(fromTimeOfDay: "06:15:36") == 6.26
              && LightingSettings.hours(fromTimeOfDay: "noon") == nil)
    }

    private static func testSettings(_ check: Checker) {
        var state = SceneState()
        state.lighting.technology = .rayTraced
        state.lighting.clockTime = 7.5
        state.lighting.fogEnd = 200
        var lamp = Part()
        lamp.light = PointLight()
        lamp.light?.color = Vec3(1, 0.5, 0)
        state.parts = [lamp]
        let data = try? JSONEncoder().encode(state)
        let back = data.flatMap { try? JSONDecoder().decode(SceneState.self, from: $0) }
        check("lighting is saved with the scene", back?.lighting == state.lighting)
        check("…and so are point lights", back?.parts.first?.light == lamp.light)
        let old = try? JSONDecoder().decode(SceneState.self, from: Data(#"{"parts":[{"name":"Old"}]}"#.utf8))
        check("older files get the default lighting and no lights",
              old?.lighting == LightingSettings() && old?.parts.first?.light == nil)

        let model = SceneModel()
        model.commit("Night") { model.lighting.clockTime = 22 }
        model.undo()
        check("lighting changes undo", model.lighting.clockTime == 14)
        model.selectLighting()
        check("Lighting can be selected for the inspector", model.lightingSelected)
        model.selection = [model.parts[0].id]
        check("…and selecting a part leaves it", !model.lightingSelected)
    }

    private static func testUniformLayout(_ check: Checker) {
        check("LightingUniforms is 384 bytes", MemoryLayout<LightingUniforms>.stride == 384,
              "\(MemoryLayout<LightingUniforms>.stride)")
        check("PointLightData is 96 bytes", MemoryLayout<PointLightData>.stride == 96)
        check("InstanceInfo is 96 bytes", MemoryLayout<InstanceInfo>.stride == 96)
        var settings = LightingSettings()
        settings.exposureCompensation = 1
        settings.globalShadows = false
        let uniforms = LightingUniforms(settings: settings, shadowViewProjection: matrix_identity_float4x4,
                                        inverseViewProjection: matrix_identity_float4x4, shadowTexel: 0.1,
                                        pointLights: 3, groundPlane: true)
        check("exposure doubles per stop", near(uniforms.ambient.w, 2))
        check("shadows off reach the shader", uniforms.sunDirection.w == 0 && uniforms.outdoorAmbient.w == 3)
    }

    // MARK: - Scripts

    private static func testScripting(_ check: Checker) {
        print("\nLighting: scripts")
        let model = ScriptSelfTest.scene()
        ScriptSelfTest.add(model, """
        local Lighting = game:GetService("Lighting")
        print(Lighting.ClockTime, Lighting.TimeOfDay, Lighting.Brightness, Lighting.GlobalShadows,
            Lighting.Technology == Enum.Technology.Conventional, game.Lighting == Lighting)
        Lighting.ClockTime = 25.5
        Lighting.FogColor = Color3.new(1, 0, 0)
        Lighting.FogEnd = 250
        Lighting.Technology = Enum.Technology.RayTraced
        Lighting.GlobalShadows = false
        print(Lighting.TimeOfDay, Lighting.FogColor.R, Lighting:GetMinutesAfterMidnight())
        Lighting.TimeOfDay = "18:00"
        print(Lighting:GetSunDirection().X < -0.9)
        print(pcall(function() Lighting.Brightness = "bright" end))

        local brick = workspace.Brick
        print(brick:FindFirstChildOfClass("PointLight"))
        local light = Instance.new("PointLight", brick)
        light.Color = Color3.new(0, 0, 1)
        light.Range = 12
        print(brick.PointLight == light, light.Parent == brick, light.Range, light.ClassName, #brick:GetChildren())
        local loose = Instance.new("PointLight")
        loose.Brightness = 4
        loose.Parent = workspace.Orb
        print(workspace.Orb.PointLight.Brightness)
        print(pcall(function() Instance.new("PointLight", workspace.Orb) end))
        print(pcall(function() light.Range = "far" end))
        light:Destroy()
        print(brick:FindFirstChild("PointLight"), light.Range)
        """)
        let result = ScriptSelfTest.execute(model)
        let out = result.output
        check("Lighting reads like Roblox's", out.first == "14 14:00:00 2 true true true",
              "\(out) \(result.errors)")
        check("scripts change the lighting",
              out.count > 1 && out[1] == "01:30:00 1 90" && model.lighting.fogEnd == 250
              && model.lighting.technology == .rayTraced && !model.lighting.globalShadows, "\(out)")
        check("TimeOfDay moves the sun", out.count > 2 && out[2] == "true", "\(out)")
        check("Lighting properties are type-checked",
              out.count > 3 && out[3].contains("number expected, got string"), "\(out)")
        check("a part starts without a PointLight", out.count > 4 && out[4] == "nil", "\(out)")
        check("Instance.new(\"PointLight\", part) lights it",
              out.count > 5 && out[5] == "true true 12 PointLight 1", "\(out)")
        check("…settings made before parenting carry over", out.count > 6 && out[6] == "4", "\(out)")
        check("multiple PointLights per part", out.count > 7 && out[7] == "true", "\(out)")
        check("PointLight properties are type-checked", out.count > 8 && out[8].contains("number expected"), "\(out)")
        check("Destroy takes it out, keeping its settings", out.count > 9 && out[9] == "nil 12", "\(out)")
        check("the lights are in the scene",
              model.parts.first { $0.name == "Brick" }?.light == nil
              && model.parts.first { $0.name == "Orb" }?.light?.brightness == 4)
    }

    private static func testCompletion(_ check: Checker) {
        func labels(_ source: String) -> [String] {
            LuauCompletion.items(in: source, caret: (source as NSString).length).map(\.label)
        }
        let lighting = labels("game:GetService(\"Lighting\").")
        check("completion knows Lighting", lighting.contains("ClockTime") && lighting.contains("FogEnd"), "\(lighting)")
        let light = labels("workspace.Brick.PointLight.")
        check("…and PointLight", light.contains("Range") && light.contains("Shadows"), "\(light)")
        check("…and Enum.Technology", labels("Enum.Technology.").contains("RayTraced"))
    }

    private static func testUserShaderVariants(_ check: Checker) {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let rayTracing = Renderer.canRayTrace(device)
        var shader = ShaderObject()
        shader.source = ShaderObject.template
        do {
            let library = try device.makeLibrary(source: ShaderSource.wrap(shader),
                                                 options: Renderer.lightingCompileOptions(rayTracing: rayTracing))
            for rayTraced in rayTracing ? [false, true] : [false] {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: ShaderSource.vertexFunctionName)
                descriptor.fragmentFunction = try library.makeFunction(
                    name: ShaderSource.fragmentFunctionName,
                    constantValues: Renderer.lightingConstants(rayTraced: rayTraced))
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                descriptor.depthAttachmentPixelFormat = .depth32Float
                descriptor.rasterSampleCount = 4
                _ = try device.makeRenderPipelineState(descriptor: descriptor)
            }
            check("user shaders build \(rayTracing ? "both lighting variants" : "the conventional variant")", true)
        } catch {
            check("user shaders build with the lighting library", false, "\(error)")
        }
    }

    // MARK: - Rendering

    private final class Source: ViewportSource {
        let model: SceneModel
        var renderCamera: Camera
        var avatars: [AvatarPose] = []
        let shaderStatus = ShaderStatusStore()
        let shaderConsole = ScriptConsole()
        var editorOverlay: EditorOverlay? { nil }
        func stepFrame() {}
        init(model: SceneModel, camera: Camera) {
            self.model = model
            self.renderCamera = camera
        }
    }

    /// Renders and returns a function giving the brightness (0–1) and colour at a
    /// world point.
    struct Frame {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let camera: Camera

        func color(at point: Vec3) -> Vec3 {
            let clip = camera.viewProjection(aspect: Float(width) / Float(height)) * Vec4(point, 1)
            let ndc = Vec3(clip.x, clip.y, clip.z) / clip.w
            let x = Int(((ndc.x + 1) / 2 * Float(width)).rounded())
            let y = Int(((1 - ndc.y) / 2 * Float(height)).rounded())
            var sum = Vec3.zero
            var count: Float = 0
            // Average a small block, to smooth out ray-traced noise.
            for dy in -3...3 {
                for dx in -3...3 {
                    let px = min(max(x + dx, 0), width - 1), py = min(max(y + dy, 0), height - 1)
                    let i = (py * width + px) * 4
                    sum += Vec3(Float(pixels[i + 2]), Float(pixels[i + 1]), Float(pixels[i])) / 255
                    count += 1
                }
            }
            return sum / count
        }

        func brightness(at point: Vec3) -> Float {
            let c = color(at: point)
            return c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722
        }
    }

    static func render(_ model: SceneModel, camera: Camera) -> (Frame, Bool)? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let width = 480, height = 320
        let source = Source(model: model, camera: camera)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: width, height: height), device: device)
        guard let renderer = Renderer(device: device, view: view, source: source),
              let image = renderer.snapshot(width: width, height: height),
              let data = image.dataProvider?.data as Data? else { return nil }
        return (Frame(pixels: [UInt8](data), width: width, height: height, camera: camera), renderer.drewRayTraced)
    }

    /// A wall on the ground, a lamp, a metal plate by a red block.
    private static func stage() -> SceneModel {
        let model = SceneModel()
        model.scripts = []
        model.shaders = []
        model.animations = []
        var wall = Part()
        wall.name = "Wall"
        wall.position = Vec3(0, 5, 0)
        wall.size = Vec3(1, 10, 20)
        var lamp = Part()
        lamp.name = "Lamp"
        lamp.position = Vec3(14, 1.5, -8)
        lamp.size = Vec3(0.5, 0.5, 0.5)
        lamp.light = PointLight()
        lamp.light?.range = 10
        lamp.light?.brightness = 4
        lamp.light?.enabled = false
        model.parts = [wall, lamp]
        return model
    }

    private static func camera() -> Camera {
        var camera = Camera()
        camera.target = Vec3(4, 0, -6)
        camera.distance = 34
        camera.yaw = -.pi / 2
        camera.pitch = 1.0
        camera.fovDegrees = 60
        return camera
    }

    private static func testRendering(_ check: Checker) {
        print("\nLighting: rendered frames")
        let shaded = Vec3(4, 0, -4.5)       // behind the wall from the 14:00 sun
        let sunny = Vec3(-4, 0, -4.5)
        let nearLamp = Vec3(14, 0, -6.5)
        let far = Vec3(4, 0, -16)

        let model = stage()
        guard let (day, _) = render(model, camera: camera()) else {
            check("the lighting test scene renders", false, "no Metal device or renderer")
            return
        }
        let dayLit = day.brightness(at: sunny)
        check("the wall casts a shadow on the ground", day.brightness(at: shaded) < dayLit * 0.75,
              "shade \(day.brightness(at: shaded)) vs sun \(dayLit)")

        model.lighting.globalShadows = false
        let (flat, _) = render(model, camera: camera())!
        check("GlobalShadows off removes it", flat.brightness(at: shaded) > flat.brightness(at: sunny) * 0.9,
              "\(flat.brightness(at: shaded)) vs \(flat.brightness(at: sunny))")
        model.lighting.globalShadows = true

        model.lighting.exposureCompensation = 1
        let (bright, _) = render(model, camera: camera())!
        check("exposure brightens everything", bright.brightness(at: sunny) > dayLit * 1.5,
              "\(bright.brightness(at: sunny)) vs \(dayLit)")
        model.lighting.exposureCompensation = 0

        model.lighting.clockTime = 0
        let (night, _) = render(model, camera: camera())!
        check("night is dark", night.brightness(at: sunny) < dayLit * 0.5, "\(night.brightness(at: sunny)) vs \(dayLit)")

        model.parts[1].light?.enabled = true
        let (lamplit, _) = render(model, camera: camera())!
        check("a PointLight lights what is near it", lamplit.brightness(at: nearLamp) > night.brightness(at: nearLamp) * 1.4,
              "\(lamplit.brightness(at: nearLamp)) vs \(night.brightness(at: nearLamp))")
        check("…but not beyond its range", abs(lamplit.brightness(at: far) - night.brightness(at: far)) < 0.02)
        model.parts[1].light?.enabled = false
        model.lighting.clockTime = 14

        model.lighting.fogColor = Vec3(1, 0, 0)
        model.lighting.fogStart = 0
        model.lighting.fogEnd = 25
        let (foggy, _) = render(model, camera: camera())!
        let fogged = foggy.color(at: model.parts[0].position + Vec3(0, 5, 0))
        check("fog turns distant parts its colour", fogged.x > fogged.y + 0.3, "\(fogged)")
        model.lighting.fogEnd = LightingSettings.fogLimit

        guard RenderCapabilities.rayTracing else {
            check("ray tracing is unavailable on this GPU — skipped", true)
            return
        }
        model.lighting.technology = .rayTraced
        let (traced, drewRays) = render(model, camera: camera())!
        check("ray-traced lighting is used when chosen", drewRays)
        check("ray-traced shadows fall where the shadow map's do",
              traced.brightness(at: shaded) < traced.brightness(at: sunny) * 0.75,
              "shade \(traced.brightness(at: shaded)) vs sun \(traced.brightness(at: sunny))")

        // Ambient occlusion: the ground right against the wall on the lit side is
        // darker than open ground, only when occlusion is on.
        let corner = Vec3(0.9, 0, -4.5)       // the camera's side of the wall, in its shade
        let openGround = Vec3(-10, 0, -4.5)     // well beyond the occlusion radius
        let occluded = traced.brightness(at: corner) / traced.brightness(at: openGround)
        model.lighting.ambientOcclusion = false
        let (open, _) = render(model, camera: camera())!
        let unoccluded = open.brightness(at: corner) / open.brightness(at: openGround)
        check("ambient occlusion darkens corners", occluded < unoccluded - 0.03, "\(occluded) vs \(unoccluded)")
        model.lighting.ambientOcclusion = true

        // Reflections: a metal floor in front of a red wall picks up red.
        let mirror = SceneModel()
        mirror.scripts = []
        mirror.shaders = []
        mirror.animations = []
        var floor = Part()
        floor.position = Vec3(0, 0.25, 0)
        floor.size = Vec3(16, 0.5, 16)
        floor.material = .metal
        floor.color = Vec3(0.8, 0.8, 0.8)
        var red = Part()
        red.position = Vec3(0, 3.5, -6)
        red.size = Vec3(14, 6, 0.5)
        red.color = Vec3(0.9, 0.1, 0.1)
        mirror.parts = [floor, red]
        mirror.lighting.technology = .rayTraced
        var view = Camera()
        view.target = Vec3(0, 1, -2)
        view.distance = 14
        view.yaw = .pi / 2          // in front of the wall, looking at it
        view.pitch = 0.3
        let (reflecting, _) = render(mirror, camera: view)!
        mirror.lighting.reflections = false
        let (plain, _) = render(mirror, camera: view)!
        let spot = Vec3(0, 0.5, -3)
        let on = reflecting.color(at: spot), off = plain.color(at: spot)
        check("ray-traced reflections show what a metal part faces",
              (on.x - on.y) > (off.x - off.y) + 0.05, "with \(on), without \(off)")

        // Point-light shadows: the lamp behind the wall lights the far side only
        // when its shadows are off.
        let dark = stage()
        dark.lighting.technology = .rayTraced
        dark.lighting.clockTime = 0
        dark.parts[1].position = Vec3(2, 1.5, -4.5)
        dark.parts[1].light?.enabled = true
        dark.parts[1].light?.range = 12
        let beyond = Vec3(-3, 0, -4.5)
        let (through, _) = render(dark, camera: camera())!
        dark.parts[1].light?.shadows = true
        let (blocked, _) = render(dark, camera: camera())!
        check("a PointLight with Shadows is blocked by the wall",
              blocked.brightness(at: beyond) < through.brightness(at: beyond) * 0.8,
              "\(blocked.brightness(at: beyond)) vs \(through.brightness(at: beyond))")
    }
}
