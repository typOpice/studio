import AppKit
import Foundation
import Metal
import simd

/// Lighting's Sky, Atmosphere and Clouds: saved (and places without them as before); what
/// the shaders get; drawn — stars at night (as many as StarCount, none at 0), the sun's
/// disc (and not with CelestialBodiesShown off), clouds whitening the sky, the atmosphere
/// fading a far part into its colour, a skybox's pictures the right way round; scripts
/// making, reading, setting, moving and destroying them; Studio adding them; and a host's
/// reaching a joined player.
enum SkySelfTest {
    static func run(check: Checker) {
        testModel(check)
        testDrawing(check)
        testScripts(check)
        testReadme(check)
        testTogether(check)
    }

    // MARK: - The README

    private static func testReadme(_ check: Checker) {
        print("\nSky: the README's example")
        guard let readme = try? String(contentsOfFile: "README.md", encoding: .utf8),
              let start = readme.range(of: "### Sky, Atmosphere and Clouds"),
              let block = readme[start.upperBound...].components(separatedBy: "```lua\n").dropFirst().first?
                .components(separatedBy: "```").first else {
            print("  (README.md not found from here; skipped)")
            return
        }
        let model = SceneModel()
        model.lighting.clockTime = 17.95
        var script = ScriptObject.blank(language: .luau)
        script.source = block
        model.scripts = model.scripts.filter { $0.host == .starterGui || $0.isModule } + [script]
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        for _ in 0..<5 { session.step(dt: frame) }
        let day = model.lighting.atmosphere?.density
        // A game second is a tenth of an hour: past 18:00 in about a second.
        for _ in 0..<80 { session.step(dt: frame) }
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("as written: an Atmosphere made, thin by day, thick once the clock passes 18:00",
              abs((day ?? 0) - 0.3) < 1e-4 && abs((model.lighting.atmosphere?.density ?? 0) - 0.6) < 1e-4
              && model.lighting.clockTime > 18 && errors.isEmpty,
              "\(String(describing: day)) \(String(describing: model.lighting.atmosphere?.density)) \(errors)")
        session.stop()
    }

    private static let frame: Float = 1.0 / 60

    // MARK: - The model

    private static func testModel(_ check: Checker) {
        print("\nSky: the settings")
        let model = SceneModel()
        check("a new place has none (and still a default sun, moon and stars)",
              model.lighting.skyObject == nil && model.lighting.atmosphere == nil && model.lighting.clouds == nil
              && model.lighting.skyInEffect.starCount == 3000 && model.lighting.skyInEffect.celestialBodiesShown)
        let plain = (try? JSONEncoder().encode(model.lighting)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check("…and saves as it always did", !plain.contains("skyObject") && !plain.contains("atmosphere"))
        let undo = model.undoCount
        model.commit("Added Atmosphere") { model.lighting.atmosphere = AtmosphereSettings() }
        model.commit("Added Clouds") { model.lighting.clouds = CloudSettings() }
        model.commit("Added Sky") {
            var sky = SkySettings()
            sky.starCount = 1200
            sky.setPicture(.up, "studio://Up")
            model.lighting.skyObject = sky
        }
        check("added in Studio: a step each to undo", model.undoCount == undo + 3)
        let reopened = SceneModel()
        if let data = try? model.encodeScene() { try? reopened.loadScene(from: data) }
        check("saved and reopened", reopened.lighting == model.lighting && reopened.lighting.skyObject?.starCount == 1200
              && reopened.lighting.skyObject?.picture(.up) == "studio://Up")
        model.undo()
        check("undo takes the Sky away", model.lighting.skyObject == nil && model.lighting.clouds != nil)

        var settings = LightingSettings()
        settings.atmosphere = AtmosphereSettings()
        settings.atmosphere?.density = 0.6
        settings.clouds = CloudSettings()
        settings.clouds?.cover = 0.8
        var sky = SkySettings()
        sky.starCount = 800
        sky.celestialBodiesShown = false
        settings.skyObject = sky
        let uniforms = LightingUniforms(settings: settings, shadowViewProjection: matrix_identity_float4x4,
                                        inverseViewProjection: matrix_identity_float4x4, shadowTexel: 0.1, pointLights: 0,
                                        groundPlane: true, time: 3)
        check("the shaders get them: stars, bodies hidden, the air's density, the clouds' cover, the time",
              uniforms.skyParams.z == 800 && uniforms.skyParams.w == 0 && abs(uniforms.atmosphereParams.x - 0.6) < 1e-6
              && uniforms.atmosphereColor.w == 1 && abs(uniforms.cloudParams.x - 0.8) < 1e-6 && uniforms.cloudParams.z == 1
              && uniforms.sunTrue.w == 3)
    }

    // MARK: - Drawn

    private static func testDrawing(_ check: Checker) {
        print("\nSky: drawn")
        guard let device = MTLCreateSystemDefaultDevice() else {
            check("a Metal device is available", false)
            return
        }
        let model = SceneModel()
        model.parts = []
        model.groups = []
        model.showGrid = false
        model.lighting.fogEnd = 100_000
        let view = StudioMTKView(frame: NSRect(x: 0, y: 0, width: 96, height: 96))
        view.device = device
        let editor = ViewportController(model: model)
        guard let renderer = Renderer(device: device, view: view, source: editor) else {
            check("the renderer builds", false)
            return
        }
        /// Looking along a direction from the origin: every pixel's colour, 0–1.
        func look(_ direction: Vec3) -> [SIMD3<Float>] {
            let d = simd_normalize(direction)
            editor.camera.target = d * 10
            editor.camera.yaw = atan2(-d.z, -d.x)
            editor.camera.pitch = asin(-d.y)
            editor.camera.distance = 10
            guard let pixels = renderer.frameSnapshot(width: 96, height: 96) else { return [] }
            return pixels.map { SIMD3(Float($0.z), Float($0.y), Float($0.x)) / 255 }
        }
        func middle(_ pixels: [SIMD3<Float>]) -> SIMD3<Float> { pixels.isEmpty ? .zero : pixels[48 * 96 + 48] }
        func brightSpots(_ pixels: [SIMD3<Float>]) -> Int { pixels.filter { ($0.x + $0.y + $0.z) / 3 > 0.3 }.count }

        // Stars at night.
        model.lighting.clockTime = 0
        let up = Vec3(0.2, 1, 0.1)
        let starry = brightSpots(look(up))
        model.lighting.skyObject = SkySettings()
        model.lighting.skyObject?.starCount = 0
        let none = brightSpots(look(up))
        check("stars at night, and none with StarCount 0", starry > 3 && none == 0, "\(starry) \(none)")
        model.lighting.skyObject = nil

        // The sun's disc, and CelestialBodiesShown.
        model.lighting.clockTime = 12
        let sunward = model.lighting.sunDirection
        let sun = middle(look(sunward))
        model.lighting.skyObject = SkySettings()
        model.lighting.skyObject?.celestialBodiesShown = false
        let hidden = middle(look(sunward))
        check("the sun's disc where the sun is, and not with CelestialBodiesShown off",
              sun.x > 0.95 && sun.z > 0.9 && hidden.x < 0.85, "\(sun) \(hidden)")
        model.lighting.skyObject = nil

        // Clouds whiten the sky.
        model.lighting.clockTime = 14
        let above = Vec3(0.3, 0.7, -0.4)
        func whiteness(_ pixels: [SIMD3<Float>]) -> Float {
            pixels.reduce(0) { $0 + min($1.x, $1.y, $1.z) } / Float(max(pixels.count, 1))
        }
        let clear = whiteness(look(above))
        model.lighting.clouds = CloudSettings()
        model.lighting.clouds?.cover = 1
        let cloudy = whiteness(look(above))
        model.lighting.clouds?.enabled = false
        let off = whiteness(look(above))
        check("clouds whiten the sky, and go when Enabled is off", cloudy > clear + 0.1 && abs(off - clear) < 0.02,
              "\(clear) \(cloudy) \(off)")
        model.lighting.clouds = nil

        // The atmosphere: a far part fades into its colour.
        var far = Part()
        far.name = "Far"
        far.position = Vec3(0, 0, -600)
        far.size = Vec3(200, 200, 2)
        far.color = Vec3(0.9, 0.1, 0.1)
        model.parts = [far]
        let ahead = Vec3(0, 0, -1)
        let bare = middle(look(ahead))
        model.lighting.atmosphere = AtmosphereSettings()
        model.lighting.atmosphere?.density = 0.6
        model.lighting.atmosphere?.color = Vec3(0.2, 0.9, 0.2)
        model.lighting.atmosphere?.decay = Vec3(0.2, 0.9, 0.2)
        let hazed = middle(look(ahead))
        check("the Atmosphere: a far red wall fades towards its (green) colour", bare.x > 0.5 && hazed.y > bare.y + 0.2
              && hazed.x < bare.x - 0.2, "\(bare) \(hazed)")
        model.lighting.atmosphere = nil
        model.parts = []

        // A skybox: each side the right way round.
        var sky = SkySettings()
        let colours: [SkySettings.Face: (CGFloat, CGFloat, CGFloat)] = [
            .ft: (0, 0, 1), .bk: (1, 1, 0), .lf: (0, 1, 0), .rt: (1, 0, 1), .up: (1, 1, 1), .dn: (0.3, 0.2, 0.1)]
        for face in SkySettings.Face.allCases {
            let (r, g, b) = colours[face]!
            if let data = AvatarSnapshot.labelledPicture("", red: r, green: g, blue: b, size: 32) {
                model.assets.append(SceneAsset(name: face.rawValue, kind: .image, data: data, fileExtension: "png"))
                sky.setPicture(face, "studio://" + face.rawValue)
            }
        }
        model.lighting.skyObject = sky
        func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { simd_distance(a, b) < 0.25 }
        let north = middle(look(Vec3(0, 0, -1))), east = middle(look(Vec3(1, 0, 0)))
        let west = middle(look(Vec3(-1, 0, 0))), south = middle(look(Vec3(0, 0, 1)))
        check("a skybox: SkyboxFt to the north, Rt east, Lf west, Bk south",
              near(north, SIMD3(0, 0, 1)) && near(east, SIMD3(1, 0, 1)) && near(west, SIMD3(0, 1, 0))
              && near(south, SIMD3(1, 1, 0)), "\(north) \(east) \(west) \(south)")
        // Just below the top edge of the north side: the white bar each picture has along its top.
        let top = middle(look(Vec3(0, 0.92, -1)))
        check("…and the right way up", top.x > 0.8 && top.y > 0.8 && top.z > 0.8, "\(top)")
        model.lighting.skyObject?.setPicture(.up, "")
        let partial = middle(look(Vec3(0, 0, -1)))
        check("…and the sky that follows the day again when it hasn't all six", !near(partial, SIMD3(0, 0, 1)), "\(partial)")
    }

    // MARK: - Scripts

    static let scriptSource = """
    local Lighting = game:GetService("Lighting")
    local sky = Instance.new("Sky")
    sky.StarCount = 1500
    sky.CelestialBodiesShown = false
    sky.SunAngularSize = 30
    sky.SkyboxUp = "studio://Up"
    print("loose", sky.Parent == nil, Lighting:FindFirstChild("Sky") == nil, sky.StarCount)
    sky.Parent = Lighting
    print("sky", sky.Parent == Lighting, Lighting.Sky == sky, Lighting:FindFirstChildOfClass("Sky") == sky,
    \tsky:IsA("Sky"), sky.ClassName, sky.StarCount, sky.CelestialBodiesShown)

    local air = Instance.new("Atmosphere", Lighting)
    air.Density = 0.5
    air.Haze = 3
    air.Color = Color3.new(0.8, 0.6, 0.4)
    air.Offset = 5
    local clouds = Instance.new("Clouds", Lighting)
    clouds.Cover = 0.9
    clouds.Color = Color3.new(1, 0.9, 0.9)
    print("children", #Lighting:GetChildren(), air.Density, air.Offset, typeof(air.Color), string.format("%.2f", clouds.Cover))

    local ok1 = pcall(function() sky.StarCount = "lots" end)
    local ok2 = pcall(function() air.Color = 3 end)
    local ok3 = pcall(function() clouds.Parent = workspace end)
    local ok4 = pcall(function() sky.Speed = 1 end)
    local ok5 = pcall(function() Instance.new("Atmosphere", workspace) end)
    print("refused", ok1, ok2, ok3, ok4, ok5)

    local copy = air:Clone()
    print("clone", copy.Parent == nil, string.format("%.2f", copy.Density), copy.Haze)
    clouds.Parent = nil
    print("out", Lighting:FindFirstChild("Clouds") == nil, string.format("%.2f", clouds.Cover))
    clouds.Parent = Lighting
    sky:Destroy()
    print("done", Lighting:FindFirstChild("Sky") == nil, string.format("%.2f", Lighting.Clouds.Cover))
    """

    private static func testScripts(_ check: Checker) {
        print("\nSky: from scripts")
        let model = SceneModel()
        var script = ScriptObject.blank(language: .luau)
        script.source = scriptSource
        model.scripts = model.scripts.filter { $0.host == .starterGui || $0.isModule } + [script]
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        for _ in 0..<5 { session.step(dt: frame) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        func said(_ prefix: String) -> String {
            session.console.lines.last { $0.kind == .output && $0.text.hasPrefix(prefix) }?.text ?? "(nothing)"
        }
        check("Instance.new(\"Sky\"), set up in nothing, then put in Lighting",
              said("loose") == "loose true true 1500"
              && said("sky") == "sky true true true true Sky 1500 false", "\(said("loose")) / \(said("sky"))")
        check("Atmosphere and Clouds: in Lighting's children, their numbers (Offset kept to 0–1) and colours",
              said("children") == "children 3 0.5 1 Color3 0.90", said("children"))
        check("…wrong values refused: a string, a number for a colour, the Workspace for a parent, no such property",
              said("refused") == "refused false false false false false", said("refused"))
        check("Clone: a copy in nothing; out of Lighting and back", said("clone") == "clone true 0.50 3"
              && said("out") == "out true 0.90", "\(said("clone")) \(said("out"))")
        check("…and Lighting as set: the Sky destroyed, the others there",
              said("done") == "done true 0.90" && model.lighting.skyObject == nil
              && model.lighting.atmosphere?.haze == 3 && model.lighting.atmosphere?.color == Vec3(0.8, 0.6, 0.4)
              && model.lighting.clouds?.cover == 0.9, said("done"))
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("no errors", errors.isEmpty, "\(errors)")
        session.stop()
    }

    // MARK: - Together

    private static func testTogether(_ check: Checker) {
        print("\nSky: a host and a joined player")
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            var host = ScriptObject.blank(language: .luau)
            host.source = """
            local Lighting = game:GetService("Lighting")
            task.wait(0.4)
            local air = Instance.new("Atmosphere")
            air.Density = 0.7
            air.Parent = Lighting
            local clouds = Instance.new("Clouds", Lighting)
            clouds.Cover = 0.3
            """
            var local = ScriptObject.blank(language: .luau)
            local.host = .starterPlayer
            local.source = """
            local Lighting = game:GetService("Lighting")
            task.wait(1)
            local air = Lighting:FindFirstChildOfClass("Atmosphere")
            print("sees", string.format("%.2f %.2f", air and air.Density or -1,
            \tLighting:FindFirstChild("Clouds") and Lighting.Clouds.Cover or -1))
            """
            model.scripts += [host, local]
        }), let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 1.6)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let heard = sam.console.lines.last { $0.kind == .output && $0.text.hasPrefix("sees") }?.text ?? "(nothing)"
        check("a host script's Atmosphere and Clouds reach the joined player: their sky, and their scripts",
              joining.model.lighting.atmosphere?.density == 0.7 && joining.model.lighting.clouds?.cover == 0.3
              && heard == "sees 0.70 0.30", heard)
        let errors = (hosting.player!.console.lines + sam.console.lines).filter { $0.kind == .error }.map(\.text)
        check("…with no errors on either", errors.isEmpty, "\(errors)")
        joining.leaveGame()
        hosting.leaveGame()
    }
}
