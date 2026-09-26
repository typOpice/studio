import simd

/// Roblox-style player camera: scroll out for third person, all the way in for first person.
struct PlayerCamera {
    var yaw: Float = 0
    var pitch: Float = 0.22
    var distance: Float = 14
    var fovDegrees: Float = 70

    static let firstPersonThreshold: Float = 1.2

    /// Zoom limits and mode, from StarterPlayer and changeable by scripts.
    var minZoom: Float = 0.5
    var maxZoom: Float = 40
    var lockFirstPerson = false
    /// Shift lock: the camera looks over the right shoulder, as Roblox's does.
    var shiftLock = false
    static let shoulderOffset: Float = 1.75

    var isFirstPerson: Bool { lockFirstPerson || distance < Self.firstPersonThreshold }

    /// To the camera's right, level.
    var right: Vec3 { Vec3(cos(yaw), 0, -sin(yaw)) }

    mutating func look(deltaX: Float, deltaY: Float, sensitivity: Float = 0.0045) {
        yaw += deltaX * sensitivity
        pitch += deltaY * sensitivity
        let limit = Float.pi / 2 - 0.05
        pitch = max(-limit, min(limit, pitch))
        if yaw > .pi { yaw -= 2 * .pi }
        if yaw < -.pi { yaw += 2 * .pi }
    }

    mutating func zoom(_ amount: Float) {
        distance = max(minZoom, min(maxZoom, distance - amount * 0.9))
    }

    /// Applies new limits, pulling the current zoom inside them.
    mutating func setZoomLimits(minimum: Float, maximum: Float) {
        minZoom = max(0, minimum)
        maxZoom = max(minZoom, maximum)
        distance = max(minZoom, min(maxZoom, distance))
    }

    var forward: Vec3 {
        Vec3(-sin(yaw) * cos(pitch), -sin(pitch), -cos(yaw) * cos(pitch))
    }

    /// Build the render camera, pulling in when scenery would clip between eye and camera.
    ///
    /// `Camera` derives its eye position from yaw/pitch as an offset *from* the target,
    /// so the player yaw has to be converted: Y = pi/2 - yaw makes the two agree.
    func renderCamera(eye: Vec3, parts: [Part]) -> Camera {
        var camera = Camera()
        camera.fovDegrees = fovDegrees
        camera.near = 0.08
        camera.yaw = .pi / 2 - yaw
        camera.pitch = pitch

        if isFirstPerson {
            camera.target = eye + forward
            camera.distance = 1
            return camera
        }

        var wanted = distance
        let target = shiftLock ? eye + right * Self.shoulderOffset : eye
        // Keep the camera out of walls.
        let probe = Ray(origin: target, direction: -forward)
        if let hit = Picking.pick(ray: probe, in: parts), hit.distance < wanted + 0.6 {
            wanted = max(1.4, hit.distance - 0.6)
        }
        camera.target = target
        camera.distance = wanted
        return camera
    }
}
