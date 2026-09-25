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
}
