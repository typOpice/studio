import simd
import Foundation

typealias Vec3 = SIMD3<Float>
typealias Vec4 = SIMD4<Float>

extension Float {
    var radians: Float { self * .pi / 180 }
    var degrees: Float { self * 180 / .pi }
}

enum Mat {
    static func translation(_ t: Vec3) -> float4x4 {
        float4x4(columns: (Vec4(1, 0, 0, 0),
                           Vec4(0, 1, 0, 0),
                           Vec4(0, 0, 1, 0),
                           Vec4(t.x, t.y, t.z, 1)))
    }

    static func scale(_ s: Vec3) -> float4x4 {
        float4x4(columns: (Vec4(s.x, 0, 0, 0),
                           Vec4(0, s.y, 0, 0),
                           Vec4(0, 0, s.z, 0),
                           Vec4(0, 0, 0, 1)))
    }

    static func rotation(_ q: simd_quatf) -> float4x4 {
        float4x4(q)
    }

    /// Right-handed perspective projection mapping depth into [0, 1] (Metal convention).
    static func perspective(fovYRadians: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let y = 1 / tan(fovYRadians * 0.5)
        let x = y / max(aspect, 0.0001)
        let z = far / (near - far)
        return float4x4(columns: (Vec4(x, 0, 0, 0),
                                  Vec4(0, y, 0, 0),
                                  Vec4(0, 0, z, -1),
                                  Vec4(0, 0, z * near, 0)))
    }

    static func lookAt(eye: Vec3, center: Vec3, up: Vec3) -> float4x4 {
        let f = normalize(center - eye)
        let s = normalize(cross(f, up))
        let u = cross(s, f)
        return float4x4(columns: (Vec4(s.x, u.x, -f.x, 0),
                                  Vec4(s.y, u.y, -f.y, 0),
                                  Vec4(s.z, u.z, -f.z, 0),
                                  Vec4(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)))
    }

    static func normalMatrix(_ m: float4x4) -> float3x3 {
        let upper = float3x3(columns: (Vec3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                       Vec3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                       Vec3(m.columns.2.x, m.columns.2.y, m.columns.2.z)))
        return upper.inverse.transpose
    }
}

extension simd_quatf {
    /// Euler angles in degrees, applied in Roblox-style Y * X * Z order.
    var eulerDegrees: Vec3 {
        let m = float3x3(self)
        // Extract from R = Ry * Rx * Rz
        let sx = -m[2][1]
        let x = asin(max(-1, min(1, sx)))
        var y: Float = 0
        var z: Float = 0
        if abs(sx) < 0.99999 {
            y = atan2(m[2][0], m[2][2])
            z = atan2(m[0][1], m[1][1])
        } else {
            y = atan2(-m[0][2], m[0][0])
            z = 0
        }
        return Vec3(x.degrees, y.degrees, z.degrees)
    }

    static func fromEulerDegrees(_ e: Vec3) -> simd_quatf {
        let qx = simd_quatf(angle: e.x.radians, axis: Vec3(1, 0, 0))
        let qy = simd_quatf(angle: e.y.radians, axis: Vec3(0, 1, 0))
        let qz = simd_quatf(angle: e.z.radians, axis: Vec3(0, 0, 1))
        return simd_normalize(qy * qx * qz)
    }
}

struct Ray {
    var origin: Vec3
    var direction: Vec3

    func point(at t: Float) -> Vec3 { origin + direction * t }

    /// Transform the ray into another space using the inverse of a model matrix.
    func transformed(by m: float4x4) -> Ray {
        let o = m * Vec4(origin, 1)
        let d = m * Vec4(direction, 0)
        return Ray(origin: Vec3(o.x, o.y, o.z), direction: Vec3(d.x, d.y, d.z))
    }
}

enum Intersect {
    /// Entry and exit parameters of a ray through an axis-aligned box centred on the
    /// origin. Values may be negative when the ray starts inside the box.
    static func rayBoxInterval(_ ray: Ray, halfExtents h: Vec3) -> (enter: Float, exit: Float)? {
        var tMin: Float = -.greatestFiniteMagnitude
        var tMax: Float = .greatestFiniteMagnitude
        for axis in 0..<3 {
            let o = ray.origin[axis], d = ray.direction[axis]
            if abs(d) < 1e-7 {
                if o < -h[axis] || o > h[axis] { return nil }
            } else {
                var t1 = (-h[axis] - o) / d
                var t2 = (h[axis] - o) / d
                if t1 > t2 { swap(&t1, &t2) }
                tMin = max(tMin, t1)
                tMax = min(tMax, t2)
                if tMin > tMax { return nil }
            }
        }
        return (tMin, tMax)
    }

    /// Ray against an axis-aligned box centered on the origin with the given half extents.
    static func rayUnitBox(_ ray: Ray, halfExtents h: Vec3) -> Float? {
        var tMin: Float = -.greatestFiniteMagnitude
        var tMax: Float = .greatestFiniteMagnitude
        for axis in 0..<3 {
            let o = ray.origin[axis], d = ray.direction[axis]
            if abs(d) < 1e-7 {
                if o < -h[axis] || o > h[axis] { return nil }
            } else {
                var t1 = (-h[axis] - o) / d
                var t2 = (h[axis] - o) / d
                if t1 > t2 { swap(&t1, &t2) }
                tMin = max(tMin, t1)
                tMax = min(tMax, t2)
                if tMin > tMax { return nil }
            }
        }
        return tMin >= 0 ? tMin : (tMax >= 0 ? tMax : nil)
    }

    /// Ray against a sphere centered on the origin.
    /// Solves the full quadratic so an unnormalized direction (as produced by an
    /// inverse model transform with non-uniform scale) still yields a correct `t`.
    static func raySphere(_ ray: Ray, radius: Float) -> Float? {
        let a = dot(ray.direction, ray.direction)
        guard a > 1e-12 else { return nil }
        let b = 2 * dot(ray.origin, ray.direction)
        let c = dot(ray.origin, ray.origin) - radius * radius
        let disc = b * b - 4 * a * c
        guard disc >= 0 else { return nil }
        let s = sqrt(disc)
        let t0 = (-b - s) / (2 * a), t1 = (-b + s) / (2 * a)
        if t0 >= 0 { return t0 }
        return t1 >= 0 ? t1 : nil
    }

    /// Ray against an infinite plane.
    static func rayPlane(_ ray: Ray, point p: Vec3, normal n: Vec3) -> Float? {
        let denom = dot(n, ray.direction)
        guard abs(denom) > 1e-6 else { return nil }
        let t = dot(p - ray.origin, n) / denom
        return t >= 0 ? t : nil
    }

    /// Shortest distance between a ray and a finite segment, plus the ray parameter at that point.
    static func raySegmentDistance(_ ray: Ray, a: Vec3, b: Vec3) -> (distance: Float, tRay: Float) {
        let u = ray.direction
        let v = b - a
        let w0 = ray.origin - a
        let aa = dot(u, u), bb = dot(u, v), cc = dot(v, v)
        let dd = dot(u, w0), ee = dot(v, w0)
        let denom = aa * cc - bb * bb
        var sc: Float
        var tc: Float
        if abs(denom) < 1e-8 {
            sc = 0
            tc = cc > 1e-8 ? ee / cc : 0
        } else {
            sc = (bb * ee - cc * dd) / denom
            tc = (aa * ee - bb * dd) / denom
        }
        sc = max(0, sc)
        tc = max(0, min(1, tc))
        let p1 = ray.origin + u * sc
        let p2 = a + v * tc
        return (length(p1 - p2), sc)
    }

    /// Closest parameter along an infinite line to a ray (used for axis dragging).
    static func closestPointOnLine(ray: Ray, linePoint: Vec3, lineDir: Vec3) -> Float? {
        let u = ray.direction
        let v = normalize(lineDir)
        let w0 = ray.origin - linePoint
        let aa = dot(u, u), bb = dot(u, v), cc = dot(v, v)
        let dd = dot(u, w0), ee = dot(v, w0)
        let denom = aa * cc - bb * bb
        guard abs(denom) > 1e-6 else { return nil }
        return (aa * ee - bb * dd) / denom
    }
}

func snapValue(_ v: Float, to increment: Float) -> Float {
    guard increment > 0 else { return v }
    return (v / increment).rounded() * increment
}
