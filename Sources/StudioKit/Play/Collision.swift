import simd

/// Upright capsule used as the player's collision volume.
struct Capsule {
    /// World position of the feet (bottom of the capsule, not the sphere centre).
    var base: Vec3
    var radius: Float
    var height: Float

    var lower: Vec3 { base + Vec3(0, radius, 0) }
    var upper: Vec3 { base + Vec3(0, height - radius, 0) }
}

struct Contact {
    var normal: Vec3     // points away from the surface, towards the capsule
    var depth: Float
}

enum Collision {

    /// Half extents of a part in its own rotated frame.
    static func halfExtents(_ part: Part) -> Vec3 { part.size * 0.5 }

    /// Closest point to `p` on the part's shape, expressed in the part's frame
    /// (origin at the part's centre, axes along the part's local axes).
    static func closestPointInFrame(_ p: Vec3, shape: PartShape, halfExtents h: Vec3) -> Vec3 {
        switch shape {
        case .block, .truss:
            return clamp(p, min: -h, max: h)

        case .sphere:
            // Treated as an ellipsoid; normalising by the radii gives a good push-out direction.
            let n = p / h
            let len = length(n)
            if len <= 1 { return p }
            return (n / len) * h

        case .cylinder:
            let y = min(max(p.y, -h.y), h.y)
            let radial = SIMD2<Float>(p.x / h.x, p.z / h.z)
            let len = length(radial)
            if len <= 1 { return Vec3(p.x, y, p.z) }
            let scaled = radial / len
            return Vec3(scaled.x * h.x, y, scaled.y * h.z)

        case .wedge:
            // Box clipped by the ramp plane running from +Y at -Z down to -Y at +Z.
            let boxPoint = clamp(p, min: -h, max: h)
            let n = normalize(Vec3(0, h.z, h.y))          // outward normal of the slope
            let d = dot(n, Vec3(0, h.y, -h.z))            // plane offset through the top edge
            let over = dot(n, boxPoint) - d
            if over <= 0 { return boxPoint }
            let projected = boxPoint - n * over
            return clamp(projected, min: -h, max: h)
        }
    }

    private static func clamp(_ v: Vec3, min lo: Vec3, max hi: Vec3) -> Vec3 {
        Vec3(min(max(v.x, lo.x), hi.x), min(max(v.y, lo.y), hi.y), min(max(v.z, lo.z), hi.z))
    }

    /// True when the point is strictly inside the shape.
    static func contains(_ p: Vec3, shape: PartShape, halfExtents h: Vec3) -> Bool {
        switch shape {
        case .block, .truss:
            return abs(p.x) <= h.x && abs(p.y) <= h.y && abs(p.z) <= h.z
        case .sphere:
            return length(p / h) <= 1
        case .cylinder:
            return abs(p.y) <= h.y && length(SIMD2<Float>(p.x / h.x, p.z / h.z)) <= 1
        case .wedge:
            guard abs(p.x) <= h.x && abs(p.y) <= h.y && abs(p.z) <= h.z else { return false }
            let n = normalize(Vec3(0, h.z, h.y))
            return dot(n, p) <= dot(n, Vec3(0, h.y, -h.z))
        }
    }

    /// Resolve one capsule against one part, returning the contact that separates them.
    static func contact(capsule: Capsule, part: Part) -> Contact? {
        guard part.inWorld else { return nil }
        // A MeshPart collides as its hull or its triangles; as its box, like a block.
        if let mesh = part.collisionMesh, mesh.collisionFidelity != .box, let geometry = MeshLibrary.shared.geometry(for: part) {
            return meshContact(capsule: capsule, part: part, geometry: geometry,
                               precise: mesh.collisionFidelity == .precise)
        }
        let rotation = float3x3(part.orientation)
        let inverseRotation = rotation.transpose
        let h = halfExtents(part)

        // Work in the part's frame: rotation only, so lengths are preserved.
        let a = inverseRotation * (capsule.lower - part.position)
        let b = inverseRotation * (capsule.upper - part.position)

        // Alternate between "closest point on the segment" and "closest point on the
        // shape" until both settle; four passes is plenty for these convex shapes.
        var surface = closestPointInFrame((a + b) * 0.5, shape: part.shape, halfExtents: h)
        var onSegment = surface
        for _ in 0..<4 {
            onSegment = closestPointOnSegment(surface, a: a, b: b)
            let next = closestPointInFrame(onSegment, shape: part.shape, halfExtents: h)
            if length(next - surface) < 1e-5 { surface = next; break }
            surface = next
        }

        var delta = onSegment - surface
        var distance = length(delta)

        if distance < 1e-5 || contains(onSegment, shape: part.shape, halfExtents: h) {
            // Deeply embedded: escape along the axis with the least penetration.
            let escape = deepEscape(onSegment, shape: part.shape, halfExtents: h)
            delta = escape.direction
            distance = -escape.depth
        }

        let penetration = capsule.radius - distance
        guard penetration > 0 else { return nil }

        let direction = length(delta) > 1e-5 ? normalize(delta) : Vec3(0, 1, 0)
        return Contact(normal: normalize(rotation * direction), depth: penetration)
    }

    /// A capsule against a MeshPart's hull (convex: anything inside it is pushed out the
    /// shortest way) or its exact triangles (a shell: a capsule behind a face is pushed
    /// back out through it). Worked out in the part's frame, stretched by its Size.
    private static func meshContact(capsule: Capsule, part: Part, geometry: MeshGeometry, precise: Bool) -> Contact? {
        let rotation = float3x3(part.orientation)
        let inverse = rotation.transpose
        let scale = simd_max(part.size, Vec3(repeating: 0.05))
        let a = inverse * (capsule.lower - part.position)
        let b = inverse * (capsule.upper - part.position)
        if !precise {
            var deepest: (direction: Vec3, depth: Float)?
            for point in [a, b, (a + b) / 2] {
                if let escape = geometry.escapeFromHull(point / scale, scale: scale),
                   escape.depth > (deepest?.depth ?? -1) { deepest = escape }
            }
            if let deepest {
                return Contact(normal: normalize(rotation * deepest.direction), depth: deepest.depth + capsule.radius)
            }
        }
        let set = precise ? geometry.triangles : geometry.hull
        guard let near = set.closest(toSegment: a, b, reach: capsule.radius, scale: scale) else { return nil }
        let delta = near.onSegment - near.onSurface
        var distance = length(delta)
        var direction = near.normal
        if distance > 1e-5 {
            direction = delta / distance
            if precise && dot(direction, near.normal) < 0 {
                // Behind the face: out through it.
                direction = near.normal
                distance = -distance
            }
        } else {
            distance = 0
        }
        let penetration = capsule.radius - distance
        guard penetration > 0 else { return nil }
        return Contact(normal: normalize(rotation * direction), depth: penetration)
    }

    /// Shortest way out for a point already inside the shape.
    private static func deepEscape(_ p: Vec3, shape: PartShape, halfExtents h: Vec3) -> (direction: Vec3, depth: Float) {
        var best = (direction: Vec3(0, 1, 0), depth: h.y)
        let candidates: [(Vec3, Float)] = [
            (Vec3(1, 0, 0), h.x - p.x), (Vec3(-1, 0, 0), h.x + p.x),
            (Vec3(0, 1, 0), h.y - p.y), (Vec3(0, -1, 0), h.y + p.y),
            (Vec3(0, 0, 1), h.z - p.z), (Vec3(0, 0, -1), h.z + p.z)
        ]
        for (axis, depth) in candidates where depth < best.depth {
            best = (axis, max(depth, 0))
        }
        if shape == .wedge {
            let n = normalize(Vec3(0, h.z, h.y))
            let depth = dot(n, Vec3(0, h.y, -h.z)) - dot(n, p)
            if depth < best.depth { best = (n, max(depth, 0)) }
        }
        return best
    }

    static func closestPointOnSegment(_ p: Vec3, a: Vec3, b: Vec3) -> Vec3 {
        let ab = b - a
        let lengthSquared = dot(ab, ab)
        guard lengthSquared > 1e-8 else { return a }
        let t = min(max(dot(p - a, ab) / lengthSquared, 0), 1)
        return a + ab * t
    }

    /// Outward surface normal at a world point lying on (or near) the part's surface.
    /// Used by the character's ground probe to reject slopes that are too steep.
    static func surfaceNormal(part: Part, worldPoint: Vec3) -> Vec3 {
        let rotation = float3x3(part.orientation)
        let p = rotation.transpose * (worldPoint - part.position)
        let h = halfExtents(part)
        if let mesh = part.collisionMesh, mesh.collisionFidelity != .box, let geometry = MeshLibrary.shared.geometry(for: part) {
            let set = mesh.collisionFidelity == .precise ? geometry.triangles : geometry.hull
            let scale = simd_max(part.size, Vec3(repeating: 0.05))
            let near = set.closest(toSegment: p, p, reach: 0.5, scale: scale)
            return normalize(rotation * (near?.normal ?? Vec3(0, 1, 0)))
        }
        return normalize(rotation * surfaceNormalInFrame(p, shape: part.shape, halfExtents: h))
    }

    static func surfaceNormalInFrame(_ p: Vec3, shape: PartShape, halfExtents h: Vec3) -> Vec3 {
        switch shape {
        case .block, .truss:
            return boxFaceNormal(p, h)

        case .sphere:
            // Gradient of the ellipsoid, which is the true outward normal.
            let g = Vec3(p.x / (h.x * h.x), p.y / (h.y * h.y), p.z / (h.z * h.z))
            return length(g) > 1e-6 ? normalize(g) : Vec3(0, 1, 0)

        case .cylinder:
            let radial = SIMD2<Float>(p.x / h.x, p.z / h.z)
            let capGap = h.y - abs(p.y)
            let wallGap = (1 - length(radial)) * min(h.x, h.z)
            if capGap < wallGap { return Vec3(0, p.y >= 0 ? 1 : -1, 0) }
            let g = Vec3(p.x / (h.x * h.x), 0, p.z / (h.z * h.z))
            return length(g) > 1e-6 ? normalize(g) : Vec3(0, 1, 0)

        case .wedge:
            let slope = normalize(Vec3(0, h.z, h.y))
            var best = (normal: slope, gap: abs(dot(slope, p)))
            let faces: [(Vec3, Float)] = [
                (Vec3(0, -1, 0), abs(p.y + h.y)),
                (Vec3(0, 0, -1), abs(p.z + h.z)),
                (Vec3(1, 0, 0), abs(p.x - h.x)),
                (Vec3(-1, 0, 0), abs(p.x + h.x))
            ]
            for (normal, gap) in faces where gap < best.gap { best = (normal, gap) }
            return best.normal
        }
    }

    private static func boxFaceNormal(_ p: Vec3, _ h: Vec3) -> Vec3 {
        var best = (axis: 0, ratio: -Float.greatestFiniteMagnitude)
        for axis in 0..<3 {
            let ratio = abs(p[axis]) / max(h[axis], 1e-6)
            if ratio > best.ratio { best = (axis, ratio) }
        }
        var n = Vec3.zero
        n[best.axis] = p[best.axis] >= 0 ? 1 : -1
        return n
    }

    /// Cheap broad phase: does the part's bounding sphere reach the capsule's?
    static func mayTouch(capsule: Capsule, part: Part) -> Bool {
        let centre = capsule.base + Vec3(0, capsule.height * 0.5, 0)
        let capsuleReach = capsule.height * 0.5 + capsule.radius
        let partReach = length(part.size) * 0.5
        return length(centre - part.position) <= capsuleReach + partReach + 0.5
    }
}
