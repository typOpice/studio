import simd

enum Picking {

    /// Nearest part under the ray, tested against each shape's actual volume in local space.
    static func pick(ray: Ray, in parts: [Part]) -> (part: Part, distance: Float)? {
        var best: (Part, Float)?
        for part in parts where part.inWorld && !part.locked {
            guard let t = intersect(ray: ray, part: part) else { continue }
            if best == nil || t < best!.1 { best = (part, t) }
        }
        return best.map { (part: $0.0, distance: $0.1) }
    }

    static func intersect(ray: Ray, part: Part) -> Float? {
        let inverse = part.modelMatrix.inverse
        let local = ray.transformed(by: inverse)
        // The local ray direction is unnormalized, so `t` stays in world-space units.
        switch part.shape {
        case .block, .truss:
            return Intersect.rayUnitBox(local, halfExtents: Vec3(repeating: 0.5))
        case .sphere:
            return Intersect.raySphere(local, radius: 0.5)
        case .cylinder:
            return intersectCylinder(local)
        case .wedge:
            return intersectWedge(local)
        }
    }

    /// Unit cylinder: radius 0.5 about the Y axis, height 1.
    private static func intersectCylinder(_ ray: Ray) -> Float? {
        let o = ray.origin, d = ray.direction
        var tBest: Float?

        func consider(_ t: Float) {
            guard t >= 0 else { return }
            if tBest == nil || t < tBest! { tBest = t }
        }

        let a = d.x * d.x + d.z * d.z
        if a > 1e-8 {
            let b = 2 * (o.x * d.x + o.z * d.z)
            let c = o.x * o.x + o.z * o.z - 0.25
            let disc = b * b - 4 * a * c
            if disc >= 0 {
                let s = sqrt(disc)
                for t in [(-b - s) / (2 * a), (-b + s) / (2 * a)] {
                    let y = o.y + d.y * t
                    if y >= -0.5 && y <= 0.5 { consider(t) }
                }
            }
        }
        if abs(d.y) > 1e-8 {
            for capY in [Float(-0.5), 0.5] {
                let t = (capY - o.y) / d.y
                let p = ray.point(at: t)
                if p.x * p.x + p.z * p.z <= 0.25 { consider(t) }
            }
        }
        return tBest
    }

    /// Unit wedge: the half of the unit cube under the plane sloping from +Y at -Z down to -Y at +Z.
    ///
    /// Intersects the box interval with the slope half-space rather than testing a single
    /// entry point, so a ray that starts inside the bounding box but above the slope — which
    /// is exactly what the character's ground probe does — still reports the slope surface.
    private static func intersectWedge(_ ray: Ray) -> Float? {
        guard var (enter, exit) = Intersect.rayBoxInterval(ray, halfExtents: Vec3(repeating: 0.5)) else {
            return nil
        }

        // The slope plane runs through the origin of the unit cube.
        let normal = normalize(Vec3(0, 1, 1))
        let offset = dot(normal, Vec3(0, 0.5, -0.5))
        let denominator = dot(normal, ray.direction)
        let numerator = offset - dot(normal, ray.origin)

        if abs(denominator) < 1e-7 {
            // Parallel to the slope: either wholly inside the half-space or wholly outside.
            if numerator < 0 { return nil }
        } else {
            let tPlane = numerator / denominator
            if denominator > 0 {
                exit = min(exit, tPlane)      // leaving through the slope
            } else {
                enter = max(enter, tPlane)    // entering through the slope
            }
            if enter > exit { return nil }
        }

        if enter >= 0 { return enter }
        return exit >= 0 ? exit : nil
    }

    /// Where the ray meets the y = 0 ground plane, used when inserting parts into empty space.
    static func groundPoint(ray: Ray) -> Vec3? {
        guard let t = Intersect.rayPlane(ray, point: .zero, normal: Vec3(0, 1, 0)), t < 1000 else { return nil }
        return ray.point(at: t)
    }
}
