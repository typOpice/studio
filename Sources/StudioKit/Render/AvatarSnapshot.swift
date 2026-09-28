import Foundation
import MetalKit
import ImageIO
import UniformTypeIdentifiers

/// `StudioApp --render-avatar out.png`: draws the avatar in each animation state side
/// by side and writes a PNG, with no window. The quickest way to see a change to the
/// avatar's meshes or animations — the self-test checks the maths, not the looks.
enum AvatarSnapshot {

    private final class Source: ViewportSource {
        let model: SceneModel
        let avatars: [AvatarPose]
        let renderCamera: Camera
        let shaderStatus = ShaderStatusStore()
        let shaderConsole = ScriptConsole()
        var editorOverlay: EditorOverlay? { nil }
        func stepFrame() {}

        init(model: SceneModel, avatars: [AvatarPose], camera: Camera) {
            self.model = model
            self.avatars = avatars
            self.renderCamera = camera
        }
    }

    /// Idle, walking, jumping, falling, flying, dead and the Wave example, each after the animator has
    /// settled into it, standing in a row along X and facing the camera.
    static func poses() -> [(label: String, pose: AvatarPose)] {
        let states: [(String, HumanoidStateType, Float, Float)] = [
            ("idle", .running, 0, 0.8), ("walk", .running, 16, 0.62), ("jump", .jumping, 0, 0.5),
            ("fall", .freefall, 0, 0.6), ("fly", .flying, 0, 0.8), ("dead", .dead, 0, 0.8),
        ]
        return states.enumerated().map { index, entry in
            var animator = AvatarAnimator()
            var elapsed: Float = 0
            while elapsed < entry.3 {
                animator.update(dt: 1.0 / 60, state: entry.1, horizontalSpeed: entry.2, verticalVelocity: -30)
                elapsed += 1.0 / 60
            }
            var pose = AvatarPose(position: Vec3(Float(index) * 5.5 - 13.75, 0, 0), yaw: 0.35,
                                  joints: animator.joints)
            pose.dead = entry.1 == .dead
            return (entry.0, pose)
        } + [("wave", AvatarPose(position: Vec3(6 * 5.5 - 13.75, 0, 0), yaw: 0.35,
                                 joints: AnimationPlayer.pose(.waveExample(), at: 0.3)))]
    }

    static func render(to url: URL, width: Int = 1800, height: Int = 600) -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("No Metal device.")
            return false
        }
        let model = SceneModel()
        model.parts = []
        model.scripts = []
        model.shaders = []
        var camera = Camera()
        camera.target = Vec3(2.75, 2.6, 0)
        camera.distance = 30
        camera.yaw = -.pi / 2          // in front: avatars face −Z
        camera.pitch = 0.16
        camera.fovDegrees = 42
        let source = Source(model: model, avatars: poses().map(\.pose), camera: camera)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: width, height: height), device: device)
        guard let renderer = Renderer(device: device, view: view, source: source),
              let image = renderer.snapshot(width: width, height: height),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            print("Could not render the avatar.")
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return false }
        print("Wrote \(url.path): " + poses().map(\.label).joined(separator: ", "))
        return true
    }

    /// `StudioApp --render-scene out.png [conventional|raytraced] [clockTime]`: the
    /// starter scene with a character in it, lit either way — how lighting changes
    /// are checked without a display.
    static func renderScene(to url: URL, technology: LightingTechnology, clockTime: Float?,
                            width: Int = 1600, height: Int = 900) -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        let model = SceneModel()
        model.lighting.technology = technology
        if let clockTime { model.lighting.clockTime = clockTime }
        var camera = Camera()
        camera.target = Vec3(0, 3, 0)
        camera.distance = 34
        camera.yaw = -0.9
        camera.pitch = 0.42
        var pose = AvatarPose(position: Vec3(-3, 1, 5), yaw: 0.6,
                              joints: poses()[0].pose.joints)
        pose.colors = model.starterPlayer.bodyColors
        let source = Source(model: model, avatars: [pose], camera: camera)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: width, height: height), device: device)
        guard let renderer = Renderer(device: device, view: view, source: source) else { return false }
        if technology == .rayTraced && !renderer.rayTracingSupported {
            print("This GPU can't ray trace; rendering conventional lighting instead.")
        }
        guard let image = renderer.snapshot(width: width, height: height),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            print("Could not render the scene.")
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return false }
        print("Wrote \(url.path) (\(renderer.drewRayTraced ? "ray traced" : "conventional"), \(model.lighting.timeOfDay))")
        return true
    }

    /// Outfits to show off the built-in catalog: face, shirt, pants and accessories.
    static let sampleLooks: [AvatarLook] = {
        func look(_ face: String, _ shirt: String, _ pants: String, _ accessories: [String]) -> AvatarLook {
            var look = AvatarLook()
            look.face = face.isEmpty ? "" : AvatarCatalog.prefix + face
            look.shirt = shirt.isEmpty ? "" : AvatarCatalog.prefix + shirt
            look.pants = pants.isEmpty ? "" : AvatarCatalog.prefix + pants
            look.accessories = accessories.compactMap(AvatarAccessory.init(builtIn:))
            return look
        }
        return [
            look("", "Suit", "SuitPants", ["TopHat", "Medal"]),
            look("Grin", "Hoodie", "Jeans", ["Cap", "Backpack"]),
            look("Cool", "StripedTee", "Shorts", ["ShortHair"]),
            look("Happy", "Plaid", "Joggers", ["Crown", "Cape", "Belt"]),
            look("Wink", "Sweater", "BlackPants", ["Beanie", "Scarf"]),
            look("Surprised", "Tee", "Jeans", ["PartyHat"]),
        ]
    }()

    /// Adventure Island's views: (camera target, yaw, pitch, distance, the screen effect
    /// that area turns on, where a player stands).
    static let adventureViews: [String: (Vec3, Float, Float, Float, String?, Vec3?)] = [
        "overview": (Vec3(0, 0, 0), .pi / 2 + 0.35, 0.78, 330, nil, nil),
        "plaza": (Vec3(0, 4, 8), .pi / 2 + 0.2, 0.22, 34, nil, Vec3(-3, 0.4, 16)),
        "village": (Vec3(0, 4, 82), -.pi / 2 + 0.3, 0.28, 46, nil, Vec3(2, 0.2, 80)),
        "obby": (Vec3(-92, 12, 6), .pi / 2 + 0.55, 0.28, 72, nil, Vec3(-80, 3.2, 10)),
        "lab": (Vec3(90, 5, 10), .pi, 0.12, 19, nil, Vec3(78, 0.4, 13)),
        "caves": (Vec3(0, 4, -102), .pi / 2, 0.14, 24, "Cave Glow", Vec3(-2, 0.4, -88)),
        "garden": (Vec3(-84, 9, 98), .pi / 2 + 0.7, 0.2, 42, "Dreamy", Vec3(-72, 3.7, 80)),
        "lake": (Vec3(84, 3, 94), .pi + 0.2, 0.3, 48, nil, Vec3(66, 4.5, 92)),
        "lighthouse": (Vec3(95, 20, -95), .pi / 2 + 0.45, 0.18, 74, nil, Vec3(92, 9, -82)),
        // Played for a few seconds first: Postie Pat on his round, mid-stride.
        "postie": (Vec3(0, 3, 40), .pi + 0.5, 0.12, 11, nil, nil),
    ]

    /// `StudioApp --render-adventure out.png [view] [ray]`: Adventure Island from one of
    /// `adventureViews`, its shaders compiled first, that area's screen effect on.
    static func renderAdventure(to url: URL, view name: String, technology: LightingTechnology,
                                width: Int = 1600, height: Int = 900) -> Bool {
        guard var setting = adventureViews[name] else {
            print("Views: \(adventureViews.keys.sorted().joined(separator: ", "))")
            return false
        }
        let model = SceneModel()
        model.loadAdventureIsland()
        var session: PlayController?
        if name == "postie" {
            let play = PlayController(model: model, console: ScriptConsole())
            play.start()
            play.character.position = Vec3(-40, 0.4, -20)
            for _ in 0..<150 { play.step(dt: 1.0 / 60) }
            if let root = model.parts.first(where: { $0.name == "HumanoidRootPart" }) {
                // From in front of him, a little to one side.
                let ahead = root.orientation.act(Vec3(0, 0, -1))
                setting.0 = root.position
                setting.1 = atan2(ahead.z, ahead.x) - 0.55
            }
            session = play
        }
        defer { session?.stop() }
        return renderPlace(model, setting, label: name, to: url, technology: technology, width: width, height: height)
    }

    /// Nightfall's views, as Adventure Island's; "night" is the camp after dark, with
    /// one of each kind of zombie closing in.
    static let nightfallViews: [String: (Vec3, Float, Float, Float, String?, Vec3?)] = [
        "overview": (Vec3(0, 0, 0), .pi / 2 + 0.3, 0.85, 440, nil, nil),
        "camp": (Vec3(0, 2, 10), -.pi / 2 + 0.35, 0.3, 36, nil, Vec3(-4, 0.4, 15)),
        "town": (Vec3(95, 3, 95), -.pi / 2 - 0.5, 0.35, 75, nil, Vec3(90, 0.4, 88)),
        "graveyard": (Vec3(-100, 3, 110), -.pi / 2 + 0.5, 0.32, 55, nil, Vec3(-98, 0.4, 92)),
        "forest": (Vec3(-100, 4, -95), .pi / 4, 0.3, 50, nil, Vec3(-92, 0.8, -78)),
        "farm": (Vec3(100, 4, -95), 3 * .pi / 4, 0.3, 65, nil, Vec3(92, 0.4, -80)),
        "mine": (Vec3(165, 4, 5), .pi, 0.25, 48, nil, Vec3(152, 0.4, 5)),
        "gate": (Vec3(0, 8, 185), -.pi / 2, 0.22, 52, nil, Vec3(0, 0.4, 172)),
        "night": (Vec3(0, 2, 10), -.pi / 2 + 0.35, 0.3, 40, "Night", Vec3(-4, 0.4, 15)),
    ]

    /// `StudioApp --render-nightfall out.png [view] [ray]`.
    static func renderNightfall(to url: URL, view name: String, technology: LightingTechnology,
                                width: Int = 1600, height: Int = 900) -> Bool {
        guard let setting = nightfallViews[name] else {
            print("Views: \(nightfallViews.keys.sorted().joined(separator: ", "))")
            return false
        }
        let model = SceneModel()
        model.loadNightfall()
        if name == "overview" {
            // From this high up the valley would be all fog.
            model.lighting.fogStart = 100_000
            model.lighting.fogEnd = 100_000
        }
        if name == "night" {
            model.lighting.clockTime = 22.5
            // The templates, brought out of ServerStorage to stand in the dark.
            for (kind, feet) in [("Walker", Vec3(9, 0.2, 2)), ("Runner", Vec3(-10, 0.2, 0)), ("Brute", Vec3(3, 0.2, -8))] {
                guard let group = model.groups.first(where: { $0.name == kind }), let pivot = model.pivot(of: group.id)
                else { continue }
                model.setStorage(group.id, nil)
                let height = pivot.position.y - Nightfall.groundTop
                let facing = simd_quatf(angle: atan2(feet.x, feet.z - 10), axis: Vec3(0, 1, 0))
                model.movePivot(of: group.id, to: Pose(position: feet + Vec3(0, height, 0), orientation: facing))
            }
        }
        return renderPlace(model, setting, label: name, to: url, technology: technology, width: width, height: height)
    }

    /// `StudioApp --render-shiftlock out.png [off]`: a play session on Adventure Island's
    /// plaza, seen through its own camera, with shift lock on (or off): the camera over
    /// the shoulder, the body turned with it.
    static func renderShiftLock(to url: URL, on: Bool, width: Int = 1600, height: Int = 900) -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        let model = SceneModel()
        model.loadAdventureIsland()
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        for _ in 0..<30 { session.step(dt: 1.0 / 60) }
        if on { session.key("LeftControl", pressed: true) }
        session.look(deltaX: -120, deltaY: 30)
        for _ in 0..<20 { session.step(dt: 1.0 / 60) }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: width, height: height), device: device)
        guard let renderer = Renderer(device: device, view: view, source: session) else { return false }
        for shader in model.shaders { renderer.shaderLibrary.compileNow(shader) }
        let deadline = Date().addingTimeInterval(8)
        while model.shaders.contains(where: { renderer.shaderLibrary.pipeline(for: $0.id, rayTraced: false) == nil }),
              Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard let image = renderer.snapshot(width: width, height: height),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        session.stop()
        guard CGImageDestinationFinalize(destination) else { return false }
        print("Wrote \(url.path) (shift lock \(on ? "on" : "off"))")
        return true
    }

    /// Mega Obby's views: along the course, a world at a time. The views are found from
    /// the checkpoints, so they follow the course if it changes.
    static let megaObbyViews = ["start", "world2", "world3", "world4", "world5", "world6", "finish", "spinner"]

    /// `StudioApp --render-obby out.png [view] [ray]`.
    static func renderMegaObby(to url: URL, view name: String, technology: LightingTechnology,
                               width: Int = 1600, height: Int = 900) -> Bool {
        guard megaObbyViews.contains(name) else {
            print("Views: \(megaObbyViews.joined(separator: ", "))")
            return false
        }
        let model = SceneModel()
        model.loadMegaObby()
        func checkpoint(_ stage: Int) -> Vec3? {
            let pads = model.parts.filter { $0.name == "Checkpoint" }
            return pads.first { pad in
                model.dataObjects.contains { $0.name == "Stage" && $0.parent == .node(pad.id) && Int($0.number) == stage }
            }?.position
        }
        var setting: (Vec3, Float, Float, Float, String?, Vec3?)
        switch name {
        case "finish":
            let end = model.parts.first { $0.name == "Victory" }?.position ?? .zero
            setting = (end + Vec3(0, 3, -4), -.pi / 2 + 0.5, 0.3, 40, nil, end + Vec3(-3, 0.5, 2))
        case "spinner":
            // Played for a moment, so the bar turns and its tips leave trails.
            let bar = model.parts.first { $0.name == "Spinner" }?.position ?? .zero
            setting = (bar, .pi / 2 + 0.4, 0.55, 26, nil, nil)
            var play: PlayController?
            defer { play?.stop() }
            return renderPlace(model, setting, label: name, to: url, technology: technology, width: width,
                               height: height) { renderer in
                let session = PlayController(model: model, console: ScriptConsole())
                session.start()
                session.character.position = Vec3(0, 200, 0)
                for _ in 0..<90 {
                    session.step(dt: 1.0 / 60)
                    renderer.trails.step(dt: 1.0 / 60, model: model)
                }
                play = session
            }
        default:
            let world = name == "start" ? 1 : Int(name.dropFirst(5)) ?? 1
            let pad = checkpoint((world - 1) * 10 + 1) ?? Vec3(0, 20, 6)
            setting = (pad + Vec3(0, 2, -26), .pi / 2 + 0.55, 0.3, 62, nil, pad + Vec3(0, 0.5, 0))
        }
        return renderPlace(model, setting, label: name, to: url, technology: technology, width: width, height: height)
    }

    /// Draws a place from one of its views: its shaders compiled first, the view's
    /// screen effect on, a character standing where the view says.
    private static func renderPlace(_ model: SceneModel, _ setting: (Vec3, Float, Float, Float, String?, Vec3?),
                                    label name: String, to url: URL, technology: LightingTechnology,
                                    width: Int, height: Int, prepare: ((Renderer) -> Void)? = nil) -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        model.lighting.technology = technology
        if let effect = setting.4, let shader = model.shaders.first(where: { $0.name == effect }) {
            model.screenShaderIDs = [shader.id]
        }
        var camera = Camera()
        camera.target = setting.0
        camera.yaw = setting.1
        camera.pitch = setting.2
        camera.distance = setting.3
        var avatars: [AvatarPose] = []
        if let feet = setting.5 {
            var pose = AvatarPose(position: feet, yaw: atan2(-(camera.position.x - feet.x), -(camera.position.z - feet.z)) + .pi,
                                  joints: poses()[0].pose.joints)
            pose.look = sampleLooks[1]
            avatars.append(pose)
        }
        let source = Source(model: model, avatars: avatars, camera: camera)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: width, height: height), device: device)
        guard let renderer = Renderer(device: device, view: view, source: source) else { return false }
        let rayTraced = technology == .rayTraced && renderer.rayTracingSupported
        for shader in model.shaders { renderer.shaderLibrary.compileNow(shader) }
        let deadline = Date().addingTimeInterval(8)
        while model.shaders.contains(where: { renderer.shaderLibrary.pipeline(for: $0.id, rayTraced: $0.kind == .surface && rayTraced) == nil }),
              Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        // ParticleEmitters' particles two seconds in, rather than just starting.
        for _ in 0..<120 { renderer.particles.step(dt: 1.0 / 60, model: model) }
        prepare?(renderer)
        guard let image = renderer.snapshot(width: width, height: height),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return false }
        print("Wrote \(url.path) (\(name), \(renderer.drewRayTraced ? "ray traced" : "conventional"))")
        return true
    }

    /// `StudioApp --render-terrain out.png [seed]`: Generate's hills and a lake, from above
    /// one side.
    static func renderTerrain(to url: URL, seed: UInt32 = 7, width: Int = 1600, height: Int = 900) -> Bool {
        let model = SceneModel()
        model.parts = []
        model.groups = []
        model.showGrid = false
        model.lighting.clockTime = 15
        model.lighting.fogEnd = 100_000
        let started = Date()
        model.terrain.generate(centre: Vec3(0, -8, 0), size: 512, height: 90, waterLevel: 10, seed: seed)
        let made = Date()
        model.terrainGeometry.update(model.terrain)
        let meshed = Date()
        print(String(format: "Terrain: %d chunks, generated in %.2fs, meshed in %.2fs, %d collision parts",
                     model.terrain.chunks.count, made.timeIntervalSince(started), meshed.timeIntervalSince(made),
                     model.terrainParts.count))
        let setting: (Vec3, Float, Float, Float, String?, Vec3?) = (Vec3(0, 10, 0), .pi / 2 + 0.6, 0.5, 330, nil, nil)
        return renderPlace(model, setting, label: "terrain", to: url, technology: .conventional, width: width, height: height)
    }

    static let skyViews = ["clouds", "atmosphere", "night", "skybox"]

    /// `StudioApp --render-sky out.png [clouds|atmosphere|night|skybox]`: Lighting's Sky,
    /// Atmosphere and Clouds over a plain field with towers going off into the distance.
    static func renderSky(to url: URL, view name: String, width: Int = 1600, height: Int = 900) -> Bool {
        guard skyViews.contains(name) else {
            print("Views: \(skyViews.joined(separator: ", "))")
            return false
        }
        let model = SceneModel()
        model.parts = []
        model.groups = []
        model.showGrid = false
        var ground = Part()
        ground.name = "Ground"
        ground.position = Vec3(0, -0.5, 0)
        ground.size = Vec3(2000, 1, 2000)
        ground.color = Vec3(0.32, 0.45, 0.28)
        model.parts.append(ground)
        model.lighting.fogEnd = 100_000
        var look = simd_normalize(Vec3(0, 0.15, -1))
        switch name {
        case "clouds":
            model.lighting.clockTime = 14
            var clouds = CloudSettings()
            clouds.cover = 0.6
            model.lighting.clouds = clouds
            look = simd_normalize(Vec3(0.3, 0.35, -1))
        case "atmosphere":
            model.lighting.clockTime = 17.3
            var air = AtmosphereSettings()
            air.density = 0.45
            air.haze = 2
            air.glare = 3
            air.color = Vec3(0.9, 0.78, 0.65)
            model.lighting.atmosphere = air
            // Towards the low sun, over the towers.
            let sun = model.lighting.sunDirection
            look = simd_normalize(Vec3(sun.x, 0.1, sun.z))
        case "night":
            model.lighting.clockTime = 22
            let moon = -model.lighting.sunDirection
            look = simd_normalize(Vec3(moon.x, moon.y * 0.8, moon.z))
        default:
            // Six pictures, each a colour with its name on it.
            var sky = SkySettings()
            let colours: [SkySettings.Face: (CGFloat, CGFloat, CGFloat)] = [
                .ft: (0.2, 0.4, 0.9), .bk: (0.9, 0.5, 0.2), .lf: (0.3, 0.8, 0.3),
                .rt: (0.8, 0.3, 0.8), .up: (0.9, 0.9, 0.95), .dn: (0.35, 0.3, 0.25)]
            for face in SkySettings.Face.allCases {
                let (r, g, b) = colours[face]!
                guard let data = labelledPicture(face.rawValue, red: r, green: g, blue: b) else { return false }
                model.assets.append(SceneAsset(name: face.rawValue, kind: .image, data: data, fileExtension: "png"))
                sky.setPicture(face, "studio://" + face.rawValue)
            }
            model.lighting.skyObject = sky
            look = simd_normalize(Vec3(0.55, 0.3, -1))
        }
        // Towers going off into the distance the way it looks, either side of the line.
        let ahead = simd_normalize(Vec3(look.x, 0, look.z)), side = Vec3(-ahead.z, 0, ahead.x)
        for index in 0..<8 {
            var tower = Part()
            tower.name = "Tower"
            let distance = Float(40 + index * index * 18)
            tower.position = ahead * distance + side * (Float(index % 2 == 0 ? -1 : 1) * (8 + Float(index) * 6))
                + Vec3(0, 10, 20)
            tower.size = Vec3(6, 20, 6)
            tower.color = Vec3(0.75, 0.3, 0.25)
            model.parts.append(tower)
        }
        let setting: (Vec3, Float, Float, Float, String?, Vec3?) =
            (Vec3(0, 6, 20) + look * 40, atan2(-look.z, -look.x), asin(-look.y), 40, nil, nil)
        return renderPlace(model, setting, label: "sky: " + name, to: url, technology: .conventional,
                           width: width, height: height)
    }

    /// A square picture of one colour with a word in the middle, as PNG data.
    static func labelledPicture(_ text: String, red: CGFloat, green: CGFloat, blue: CGFloat, size: Int = 256) -> Data? {
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        // A white bar along the top edge, so which way up it is shows.
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: size - size / 10, width: size, height: size / 10))
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: CGFloat(size) / 7),
                                                         .foregroundColor: NSColor.white]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.textPosition = CGPoint(x: (CGFloat(size) - bounds.width) / 2, y: CGFloat(size) / 2 - bounds.height / 3)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// `StudioApp --render-ribbons out.png [night]`: Beams (a laser, an arrow path on the
    /// ground, a chain hanging between posts) and a Trail behind a block going round.
    static func renderRibbons(to url: URL, night: Bool = false, width: Int = 1600, height: Int = 900) -> Bool {
        let model = SceneModel()
        model.parts = []
        model.groups = []
        model.attachments = []
        model.constraints = []
        var ground = Part()
        ground.name = "Ground"
        // Its top just above Studio's grid, so they don't fight.
        ground.position = Vec3(0, -0.45, 0)
        ground.size = Vec3(200, 1, 200)
        ground.color = Vec3(0.3, 0.42, 0.28)
        model.parts.append(ground)
        func post(_ name: String, _ at: Vec3, height: Float = 6) -> UUID {
            var part = Part()
            part.name = name
            part.position = at + Vec3(0, height / 2, 0)
            part.size = Vec3(1, height, 1)
            part.color = Vec3(0.45, 0.45, 0.5)
            model.parts.append(part)
            return part.id
        }
        func beam(_ a: UUID, _ b: UUID, from pointA: Vec3, to pointB: Vec3, _ set: (inout RibbonLook) -> Void) {
            var beam = SceneConstraint(kind: .beam)
            let axis = simd_normalize(pointB - pointA)
            beam.attachment0 = model.addAttachment(on: a, world: pointA, axis: axis)
            beam.attachment1 = model.addAttachment(on: b, world: pointB, axis: axis)
            set(&beam.look)
            model.constraints.append(beam)
        }
        // A laser between two posts.
        let l0 = post("LaserL", Vec3(-12, 0, -4)), l1 = post("LaserR", Vec3(-2, 0, -4))
        beam(l0, l1, from: Vec3(-12, 5, -4), to: Vec3(-2, 5, -4)) { look in
            look.texture = "builtin://Glow"
            look.color = .from(Vec3(1, 0.2, 0.2), to: Vec3(1, 0.5, 0.2))
            look.transparency = .from(0, to: 0)
            look.lightEmission = 1
            look.faceCamera = true
            look.width0 = 0.8
            look.width1 = 0.8
        }
        // Arrows along the ground, curving round: out towards the camera, then off to the right.
        let g0 = model.parts[0].id
        var path = SceneConstraint(kind: .beam)
        path.attachment0 = model.addAttachment(on: g0, world: Vec3(-10, 0.1, 2), axis: Vec3(0, 0, 1))
        path.attachment1 = model.addAttachment(on: g0, world: Vec3(9, 0.1, 5), axis: Vec3(1, 0, 0))
        do {
            var look = RibbonLook()
            look.texture = "builtin://Arrows"
            look.textureMode = .wrap
            look.textureLength = 2
            look.color = .from(Vec3(1, 0.85, 0.2), to: Vec3(1, 0.85, 0.2))
            look.transparency = .from(0, to: 0)
            look.width0 = 1.5
            look.width1 = 1.5
            look.curveSize0 = 8
            look.curveSize1 = 8
            look.segments = 30
            path.look = look
            model.constraints.append(path)
        }
        // A chain hanging between posts.
        let c0 = post("ChainL", Vec3(4, 0, -6)), c1 = post("ChainR", Vec3(14, 0, -6))
        var chain = SceneConstraint(kind: .beam)
        chain.attachment0 = model.addAttachment(on: c0, world: Vec3(4, 5.5, -6), axis: Vec3(0, -1, 0))
        chain.attachment1 = model.addAttachment(on: c1, world: Vec3(14, 5.5, -6), axis: Vec3(0, 1, 0))
        chain.look.texture = "builtin://Chain"
        chain.look.textureMode = .wrap
        chain.look.textureLength = 1
        chain.look.color = .from(Vec3(0.75, 0.75, 0.8), to: Vec3(0.75, 0.75, 0.8))
        chain.look.transparency = .from(0, to: 0)
        chain.look.faceCamera = true
        chain.look.width0 = 0.6
        chain.look.width1 = 0.6
        chain.look.curveSize0 = 4
        chain.look.curveSize1 = 4
        chain.look.segments = 30
        model.constraints.append(chain)
        // A block going round, a trail behind it.
        var runner = Part()
        runner.name = "Runner"
        runner.position = Vec3(0, 2, 12)
        runner.size = Vec3(1, 2, 1)
        runner.color = Vec3(0.2, 0.6, 1)
        model.parts.append(runner)
        model.addTrail(to: runner.id)
        if let index = model.constraints.firstIndex(where: { $0.kind == .trail }) {
            model.constraints[index].look.color = .from(Vec3(0.3, 0.8, 1), to: Vec3(0.6, 0.3, 1))
            model.constraints[index].look.transparency = .from(0.1, to: 1)
            model.constraints[index].look.lightEmission = 0.6
        }
        if night { model.lighting.clockTime = 21 }
        let setting: (Vec3, Float, Float, Float, String?, Vec3?) = (Vec3(0, 3, 3), .pi / 2, 0.35, 30, nil, nil)
        return renderPlace(model, setting, label: night ? "ribbons at night" : "ribbons", to: url,
                           technology: .conventional, width: width, height: height) { renderer in
            for frame in 0..<120 {
                let angle = Float(frame) / 60 * 2
                model.update(id: runner.id) { $0.position = Vec3(sin(angle) * 5, 2, 10 + cos(angle) * 5) }
                renderer.trails.step(dt: 1.0 / 60, model: model)
            }
        }
    }

    /// `StudioApp --render-particles out.png [night]`: a pillar for each of Studio's
    /// ParticleEmitter starting points, their particles two seconds in.
    static func renderParticles(to url: URL, night: Bool = false, width: Int = 1600, height: Int = 900) -> Bool {
        let model = SceneModel()
        model.parts = []
        model.groups = []
        var ground = Part()
        ground.name = "Ground"
        ground.position = Vec3(0, -0.5, 0)
        ground.size = Vec3(200, 1, 200)
        ground.color = Vec3(0.3, 0.42, 0.28)
        model.parts.append(ground)
        for (index, preset) in ParticleEmitter.Preset.allCases.enumerated() {
            var pillar = Part()
            pillar.name = preset.rawValue
            pillar.position = Vec3(Float(index - 2) * 9, 1, 0)
            pillar.size = Vec3(2, 2, 2)
            pillar.color = Vec3(0.4, 0.4, 0.43)
            pillar.emitters = [ParticleEmitter.preset(preset)]
            model.parts.append(pillar)
        }
        if night { model.lighting.clockTime = 21 }
        let setting: (Vec3, Float, Float, Float, String?, Vec3?) = (Vec3(0, 4, 0), .pi / 2, 0.18, 30, nil, nil)
        return renderPlace(model, setting, label: night ? "particles at night" : "particles", to: url,
                           technology: .conventional, width: width, height: height) { renderer in
            for frame in 0..<120 {
                // The confetti, as a script's Emit(80) would, a second before the picture.
                if frame == 60, let confetti = model.parts.first(where: { $0.name == "Confetti" }) {
                    model.update(id: confetti.id) { $0.emitters[0].emitted += 80; $0.emitters[0].lastBurst = 80 }
                }
                renderer.particles.step(dt: 1.0 / 60, model: model)
            }
        }
    }

    /// `StudioApp --render-looks out.png [ray] [back]`: the sample outfits side by side,
    /// from the front (or the back).
    static func renderLooks(to url: URL, technology: LightingTechnology, fromBehind: Bool = false,
                            width: Int = 1800, height: Int = 800) -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        let model = SceneModel()
        model.parts = []
        model.scripts = []
        model.lighting.technology = technology
        let colors: [BodyColors] = sampleLooks.indices.map { index in
            var colors = BodyColors()
            let skins = [Vec3(0.96, 0.8, 0.22), Vec3(0.8, 0.56, 0.41), Vec3(0.49, 0.36, 0.27)]
            let skin = skins[index % skins.count]
            colors.head = skin; colors.leftArm = skin; colors.rightArm = skin
            return colors
        }
        let avatars: [AvatarPose] = sampleLooks.enumerated().map { index, look in
            var pose = AvatarPose(position: Vec3(Float(index) * 4.2 - 10.5, 0, 0), yaw: fromBehind ? 0 : .pi,
                                  joints: poses()[0].pose.joints)
            pose.colors = colors[index]
            pose.look = look
            return pose
        }
        var camera = Camera()
        camera.target = Vec3(0, 2.9, 0)
        camera.distance = 19
        camera.yaw = fromBehind ? -.pi / 2 - 0.25 : .pi / 2 + 0.25
        camera.pitch = 0.12
        let source = Source(model: model, avatars: avatars, camera: camera)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: width, height: height), device: device)
        guard let renderer = Renderer(device: device, view: view, source: source),
              let image = renderer.snapshot(width: width, height: height),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            print("Could not render the looks.")
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return false }
        print("Wrote \(url.path) (\(renderer.drewRayTraced ? "ray traced" : "conventional"))")
        return true
    }

    /// `StudioApp --render-meshes out.png [ray]`: MeshParts made from 3D models written
    /// here — a torus with a checked picture on it, an arch and a cup with a block dropped
    /// in (Precise, so it lands inside) — simulated a moment and rendered.
    static func renderMeshes(to url: URL, technology: LightingTechnology,
                             width: Int = 1600, height: Int = 900) -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        let model = SceneModel()
        model.scripts = []
        model.shaders = []
        model.groups = []
        model.parts = []
        model.lighting.technology = technology
        guard let torus = try? model.importAsset(data: torusOBJ(), name: "Torus", fileExtension: "obj"),
              let arch = try? model.importAsset(data: MeshSelfTest.arch, name: "Arch", fileExtension: "obj"),
              let cup = try? model.importAsset(data: MeshSelfTest.cup, name: "Cup", fileExtension: "obj"),
              (try? model.importAsset(data: checkerPNG(), name: "Checks", fileExtension: "png")) != nil,
              let ring = model.insertMeshPart(torus, at: Vec3(-9, 0, 0)),
              let gate = model.insertMeshPart(arch, at: Vec3(3, 0, -2)),
              let holder = model.insertMeshPart(cup, at: Vec3(3, 0, 8)) else { return false }
        model.update(id: ring) {
            $0.size = Vec3(8, 3, 8)
            $0.position.y = 3
            $0.orientation = simd_quatf(angle: 0.5, axis: Vec3(1, 0, 0))
            $0.color = Vec3(1, 1, 1)
            $0.mesh?.textureId = "studio://Checks"
        }
        model.update(id: gate) { $0.color = Vec3(0.55, 0.6, 0.7) }
        model.update(id: holder) { $0.color = Vec3(0.85, 0.5, 0.25); $0.mesh?.collisionFidelity = .precise }
        var block = Part()
        block.name = "Block"
        block.anchored = false
        block.size = Vec3(1.5, 1.5, 1.5)
        block.color = Vec3(0.2, 0.7, 0.3)
        block.position = Vec3(3, 9, 8)
        var parts = model.parts + [block]
        _ = PhysicsSelfTest.simulate(PhysicsWorld(), &parts, seconds: 2)
        model.parts = parts
        model.selection = []
        var camera = Camera()
        camera.target = Vec3(-1, 2.5, 3)
        camera.distance = 26
        camera.yaw = -0.8
        camera.pitch = 0.38
        let source = Source(model: model, avatars: [], camera: camera)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: width, height: height), device: device)
        guard let renderer = Renderer(device: device, view: view, source: source),
              let image = renderer.snapshot(width: width, height: height),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            print("Could not render the meshes.")
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return false }
        print("Wrote \(url.path) (\(renderer.drewRayTraced ? "ray traced" : "conventional"))")
        return true
    }

    /// A torus with normals and picture coordinates, as OBJ text.
    private static func torusOBJ(rings: Int = 48, sides: Int = 24) -> Data {
        var text = ""
        let big: Float = 1, small: Float = 0.38
        for i in 0...rings {
            for j in 0...sides {
                let u = Float(i) / Float(rings) * 2 * .pi, v = Float(j) / Float(sides) * 2 * .pi
                let centre = Vec3(cos(u) * big, 0, sin(u) * big)
                let normal = Vec3(cos(u) * cos(v), sin(v), sin(u) * cos(v))
                let p = centre + normal * small
                text += "v \(p.x) \(p.y) \(p.z)\nvn \(normal.x) \(normal.y) \(normal.z)\n"
                text += "vt \(Float(i) / Float(rings) * 6) \(Float(j) / Float(sides) * 2)\n"
            }
        }
        for i in 0..<rings {
            for j in 0..<sides {
                let a = i * (sides + 1) + j + 1, b = a + sides + 1
                // Counter-clockwise seen from outside.
                text += "f \(a)/\(a)/\(a) \(a + 1)/\(a + 1)/\(a + 1) \(b + 1)/\(b + 1)/\(b + 1)\n"
                text += "f \(a)/\(a)/\(a) \(b + 1)/\(b + 1)/\(b + 1) \(b)/\(b)/\(b)\n"
            }
        }
        return Data(text.utf8)
    }

    /// Red and cream checks, 64 × 64.
    private static func checkerPNG() -> Data {
        let size = 64
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        for y in 0..<8 {
            for x in 0..<8 {
                context.setFillColor((x + y) % 2 == 0 ? CGColor(red: 0.85, green: 0.15, blue: 0.1, alpha: 1)
                                                        : CGColor(red: 0.95, green: 0.9, blue: 0.8, alpha: 1))
                context.fill(CGRect(x: x * 8, y: y * 8, width: 8, height: 8))
            }
        }
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// `StudioApp --render-physics out.png [seconds]`: a pyramid of crates hit by a heavy
    /// ball, simulated for a while with the real physics, then rendered.
    static func renderPhysics(to url: URL, seconds: Float = 1.2) -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        let model = SceneModel()
        model.scripts = []
        model.shaders = []
        model.groups = []
        model.animations = []
        var parts: [Part] = []
        var floor = Part()
        floor.name = "Floor"
        floor.position = Vec3(0, 0.5, 0)
        floor.size = Vec3(60, 1, 40)
        floor.color = Vec3(0.36, 0.5, 0.36)
        parts.append(floor)
        let palette = SceneModel.palette
        for row in 0..<6 {
            for column in 0..<(6 - row) {
                var crate = Part()
                crate.name = "Crate"
                crate.anchored = false
                crate.size = Vec3(2, 2, 2)
                crate.material = .wood
                crate.position = Vec3(Float(column) * 2.05 - Float(5 - row) * 1.025, 2 + Float(row) * 2.02, 0)
                crate.color = palette[(row * 3 + column) % palette.count]
                parts.append(crate)
            }
        }
        var ball = Part()
        ball.name = "Ball"
        ball.shape = .sphere
        ball.anchored = false
        ball.material = .metal
        ball.size = Vec3(3, 3, 3)
        ball.position = Vec3(-22, 3, 0)
        ball.color = Vec3(0.75, 0.76, 0.8)
        parts.append(ball)
        model.parts = parts

        let world = PhysicsWorld()
        world.sync(model.parts)
        world.setVelocity(ball.id, Vec3(70, 6, 0))
        var elapsed: Float = 0
        while elapsed < seconds {
            world.sync(model.parts)
            let result = world.step(dt: 1.0 / 60)
            var updated = model.parts
            for (id, pose) in result.moved {
                if let i = updated.firstIndex(where: { $0.id == id }) { updated[i].pose = pose }
            }
            model.parts = updated
            elapsed += 1.0 / 60
        }

        var camera = Camera()
        camera.target = Vec3(0, 4, 0)
        camera.distance = 36
        camera.yaw = -.pi / 2 + 0.55
        camera.pitch = 0.3
        let source = Source(model: model, avatars: [], camera: camera)
        let width = 1400, height = 800
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: width, height: height), device: device)
        guard let renderer = Renderer(device: device, view: view, source: source),
              let image = renderer.snapshot(width: width, height: height),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return false }
        print("Wrote \(url.path) after \(seconds) s of physics")
        return true
    }

    /// `StudioApp --render-car out.png [seconds]`: a car — a welded body on four wheels
    /// hinged with motors — driving across the ground. How welds and joints are checked
    /// by eye.
    static func renderCar(to url: URL, seconds: Float = 1.5) -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        let model = SceneModel()
        model.scripts = []
        model.shaders = []
        model.groups = []
        model.animations = []
        model.attachments = []
        model.constraints = []

        var ground = Part()
        ground.name = "Ground"
        ground.position = Vec3(0, 0.5, 0)
        ground.size = Vec3(120, 1, 40)
        ground.color = Vec3(0.38, 0.5, 0.38)
        ground.anchored = true

        var chassis = Part()
        chassis.name = "Chassis"
        chassis.position = Vec3(-12, 3, 0)
        chassis.size = Vec3(10, 1, 5)
        chassis.color = Vec3(0.8, 0.25, 0.2)
        chassis.anchored = false

        var cab = Part()
        cab.name = "Cab"
        cab.position = chassis.position + Vec3(-1, 1.5, 0)
        cab.size = Vec3(4, 2, 4)
        cab.color = Vec3(0.9, 0.75, 0.25)
        cab.anchored = false

        model.parts = [ground, chassis, cab]
        var weld = SceneConstraint(kind: .weld)
        weld.part0 = chassis.id
        weld.part1 = cab.id
        weld.parentID = chassis.id
        model.constraints = [weld]

        // Four wheels, each hinged to the chassis and driven by a motor.
        for (index, offset) in [Vec3(-3.5, -0.5, 2.8), Vec3(-3.5, -0.5, -2.8),
                                Vec3(3.5, -0.5, 2.8), Vec3(3.5, -0.5, -2.8)].enumerated() {
            var wheel = Part()
            wheel.name = "Wheel\(index)"
            wheel.shape = .cylinder
            wheel.size = Vec3(3, 1, 3)
            wheel.position = chassis.position + offset
            wheel.rotationDegrees = Vec3(90, 0, 0)      // its axle along Z
            wheel.material = .smooth
            wheel.color = Vec3(0.15, 0.15, 0.17)
            wheel.anchored = false
            model.parts.append(wheel)
            guard let hinge = model.join(.hinge, chassis.id, wheel.id) else { continue }
            model.updateConstraint(id: hinge) { c in
                c.actuator = .motor
                c.angularVelocity = offset.z > 0 ? -12 : -12
                c.motorMaxTorque = 500_000
            }
            // The hinge sits at the wheel's centre, turning about its axle.
            for attachment in [model.constraint(id: hinge)?.attachment0, model.constraint(id: hinge)?.attachment1].compactMap({ $0 }) {
                model.updateAttachment(id: attachment) { a in
                    guard let owner = model.part(id: a.parentID) else { return }
                    a.position = owner.orientation.inverse.act(wheel.position - owner.position)
                    a.setAxis(owner.orientation.inverse.act(Vec3(0, 0, 1)))
                }
            }
        }

        let world = PhysicsWorld()
        var elapsed: Float = 0
        while elapsed < seconds {
            world.sync(model.parts, constraints: model.constraints, attachments: model.attachments)
            let result = world.step(dt: 1.0 / 60)
            var parts = model.parts
            let index = Dictionary(uniqueKeysWithValues: parts.enumerated().map { ($1.id, $0) })
            for (id, pose) in result.moved { if let i = index[id] { parts[i].pose = pose } }
            model.parts = parts
            elapsed += 1.0 / 60
        }

        var camera = Camera()
        camera.target = model.parts[1].position
        camera.distance = 26
        camera.yaw = -0.9
        camera.pitch = 0.25
        let source = Source(model: model, avatars: [], camera: camera)
        let width = 1400, height = 800
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: width, height: height), device: device)
        guard let renderer = Renderer(device: device, view: view, source: source),
              let image = renderer.snapshot(width: width, height: height),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return false }
        print("Wrote \(url.path): car at \(model.parts[1].position) after \(seconds) s")
        return true
    }

    /// A Toolbox model on a lawn, settled by a moment's physics, seen from the front-left.
    static func renderToolbox(_ item: ToolboxModel, to url: URL, width: Int = 1200, height: Int = 800) -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        let model = SceneModel()
        model.scripts = []
        model.shaders = []
        model.groups = []
        model.animations = []
        model.attachments = []
        model.constraints = []
        var lawn = Part()
        lawn.name = "Lawn"
        // A little above the grid, so the two don't flicker.
        lawn.position = Vec3(0, -0.48, 0)
        lawn.size = Vec3(200, 1, 200)
        lawn.color = Vec3(0.36, 0.55, 0.34)
        model.parts = [lawn]
        model.insert(item, at: Vec3(0, 0.02, 0))
        let world = PhysicsWorld()
        for _ in 0..<30 {
            world.sync(model.parts, constraints: model.constraints, attachments: model.attachments)
            let result = world.step(dt: 1.0 / 60)
            var parts = model.parts
            let index = Dictionary(uniqueKeysWithValues: parts.enumerated().map { ($1.id, $0) })
            for (id, pose) in result.moved { if let i = index[id] { parts[i].pose = pose } }
            model.parts = parts
        }
        model.selection = []
        let inside = model.parts.dropFirst()
        let low = inside.reduce(Vec3(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1.position - $1.size / 2) }
        let high = inside.reduce(Vec3(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1.position + $1.size / 2) }
        var camera = Camera()
        camera.target = (low + high) / 2
        camera.distance = max(simd_length(high - low) * 1.6, 8)
        camera.yaw = -0.75
        camera.pitch = 0.3
        let source = Source(model: model, avatars: [], camera: camera)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: width, height: height), device: device)
        guard let renderer = Renderer(device: device, view: view, source: source),
              let image = renderer.snapshot(width: width, height: height),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return false }
        print("Wrote \(url.path): \(item.rawValue)")
        return true
    }
}
