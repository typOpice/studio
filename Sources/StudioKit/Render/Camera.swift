import simd
import Foundation

/// Orbit / fly camera modelled on the Roblox Studio viewport camera.
struct Camera {
    var target: Vec3 = Vec3(0, 3, 0)
    var distance: Float = 26
    var yaw: Float = -0.7          // radians, around +Y
    var pitch: Float = 0.45        // radians, positive looks down
    var fovDegrees: Float = 60
    var near: Float = 0.1
    var far: Float = 3000

    var position: Vec3 {
        let cp = cos(pitch), sp = sin(pitch)
        let offset = Vec3(cos(yaw) * cp, sp, sin(yaw) * cp) * distance
        return target + offset
    }

    var forward: Vec3 { normalize(target - position) }
    var right: Vec3 { normalize(cross(forward, Vec3(0, 1, 0))) }
    var up: Vec3 { normalize(cross(right, forward)) }

    func viewMatrix() -> float4x4 {
        Mat.lookAt(eye: position, center: target, up: Vec3(0, 1, 0))
    }

    func projectionMatrix(aspect: Float) -> float4x4 {
        Mat.perspective(fovYRadians: fovDegrees.radians, aspect: aspect, near: near, far: far)
    }

    func viewProjection(aspect: Float) -> float4x4 {
        projectionMatrix(aspect: aspect) * viewMatrix()
    }

    mutating func orbit(deltaX: Float, deltaY: Float) {
        yaw += deltaX * 0.007
        pitch += deltaY * 0.007
        let limit = Float.pi / 2 - 0.02
        pitch = max(-limit, min(limit, pitch))
    }

    mutating func pan(deltaX: Float, deltaY: Float) {
        let speed = distance * 0.0016
        target += right * (-deltaX * speed) + up * (deltaY * speed)
    }

    mutating func zoom(_ amount: Float) {
        distance *= exp(-amount * 0.12)
        distance = max(1.0, min(1200, distance))
    }

    /// WASD/QE movement; moves the orbit target so orientation is preserved.
    mutating func fly(forwardAmount: Float, rightAmount: Float, upAmount: Float, speed: Float) {
        let flatForward = normalize(Vec3(forward.x, 0, forward.z))
        target += flatForward * (forwardAmount * speed)
        target += right * (rightAmount * speed)
        target += Vec3(0, 1, 0) * (upAmount * speed)
    }

    /// Frame a bounding sphere so the whole thing is visible.
    mutating func focus(on center: Vec3, radius: Float) {
        target = center
        let r = max(radius, 0.5)
        distance = max(3, r / tan(fovDegrees.radians * 0.5) * 1.6)
    }

    /// Build a world-space picking ray from a point in view coordinates.
    func ray(atViewPoint p: SIMD2<Float>, viewSize: SIMD2<Float>) -> Ray {
        let ndc = SIMD2<Float>((p.x / viewSize.x) * 2 - 1, 1 - (p.y / viewSize.y) * 2)
        let aspect = viewSize.x / max(viewSize.y, 1)
        let inv = viewProjection(aspect: aspect).inverse
        let nearPoint = inv * Vec4(ndc.x, ndc.y, 0, 1)
        let farPoint = inv * Vec4(ndc.x, ndc.y, 1, 1)
        let a = Vec3(nearPoint.x, nearPoint.y, nearPoint.z) / nearPoint.w
        let b = Vec3(farPoint.x, farPoint.y, farPoint.z) / farPoint.w
        return Ray(origin: a, direction: normalize(b - a))
    }
}
