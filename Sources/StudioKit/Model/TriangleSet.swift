import simd

/// Triangles in a mesh's unit space (the unit cube a part's Size stretches), with a
/// bounding-volume tree, for the questions a mesh part is asked: where a ray first hits
/// it, and where it comes closest to a capsule — the latter in the part's own scaled
/// space, since a Size that isn't uniform changes distances.
struct TriangleSet {
    let vertices: [Vec3]
    /// Three vertex indices each, counter-clockwise seen from outside.
    let triangles: [SIMD3<Int32>]

    private struct Node {
        var lower: Vec3
        var upper: Vec3
        /// A leaf's first triangle (in `order`) and how many; an inner node's children.
        var start: Int32
        var count: Int32
        var left: Int32
        var right: Int32
    }
    private let nodes: [Node]
    private let order: [Int32]

    var isEmpty: Bool { triangles.isEmpty }

    init(vertices: [Vec3], triangles: [SIMD3<Int32>]) {
        self.vertices = vertices
        let valid = triangles.filter { t in
            t.x >= 0 && t.y >= 0 && t.z >= 0 && Int(t.x) < vertices.count && Int(t.y) < vertices.count
                && Int(t.z) < vertices.count
        }
        self.triangles = valid
        var order = Array(Int32(0)..<Int32(valid.count))
        var nodes: [Node] = []
        let centroids = valid.map { (vertices[Int($0.x)] + vertices[Int($0.y)] + vertices[Int($0.z)]) / 3 }

        func bounds(_ range: Range<Int>) -> (Vec3, Vec3) {
            var lower = Vec3(repeating: .greatestFiniteMagnitude), upper = -lower
            for index in range {
                let t = valid[Int(order[index])]
                for corner in [t.x, t.y, t.z] {
                    lower = simd_min(lower, vertices[Int(corner)])
                    upper = simd_max(upper, vertices[Int(corner)])
                }
            }
            return (lower, upper)
        }

        func build(_ range: Range<Int>) -> Int32 {
            let (lower, upper) = bounds(range)
            let index = Int32(nodes.count)
            nodes.append(Node(lower: lower, upper: upper, start: Int32(range.lowerBound), count: Int32(range.count),
                              left: -1, right: -1))
            guard range.count > 4 else { return index }
            // Split at the middle of the longest axis, by centroid.
            let extent = upper - lower
            let axis = extent.x >= extent.y && extent.x >= extent.z ? 0 : (extent.y >= extent.z ? 1 : 2)
            let slice = order[range].sorted { centroids[Int($0)][axis] < centroids[Int($1)][axis] }
            order.replaceSubrange(range, with: slice)
            let middle = range.lowerBound + range.count / 2
            let left = build(range.lowerBound..<middle)
            let right = build(middle..<range.upperBound)
            nodes[Int(index)].left = left
            nodes[Int(index)].right = right
            nodes[Int(index)].count = 0
            return index
        }
        if !valid.isEmpty { _ = build(0..<valid.count) }
        self.nodes = nodes
        self.order = order
    }

    func corners(_ index: Int, scale: Vec3 = Vec3(repeating: 1)) -> (Vec3, Vec3, Vec3) {
        let t = triangles[index]
        return (vertices[Int(t.x)] * scale, vertices[Int(t.y)] * scale, vertices[Int(t.z)] * scale)
    }

    /// The triangles whose boxes meet a box, all in unit space.
    func candidates(lower: Vec3, upper: Vec3) -> [Int] {
        guard !nodes.isEmpty else { return [] }
        var found: [Int] = []
        var stack: [Int32] = [0]
        while let next = stack.popLast() {
            let node = nodes[Int(next)]
            if any(node.upper .< lower) || any(node.lower .> upper) { continue }
            if node.left < 0 {
                for index in Int(node.start)..<Int(node.start + node.count) { found.append(Int(order[index])) }
            } else {
                stack.append(node.left)
                stack.append(node.right)
            }
        }
        return found
    }

    // MARK: - Rays

    /// Where a ray (in unit space; its direction needn't be normalised) first meets a
    /// triangle, from either side: the multiple of its direction.
    func raycast(origin: Vec3, direction: Vec3, maxT: Float = .greatestFiniteMagnitude) -> Float? {
        guard !nodes.isEmpty else { return nil }
        let inverse = Vec3(1 / direction.x, 1 / direction.y, 1 / direction.z)
        var best: Float?
        var stack: [Int32] = [0]
        while let next = stack.popLast() {
            let node = nodes[Int(next)]
            guard let entry = Self.slab(origin, inverse, node.lower, node.upper), entry <= (best ?? maxT) else { continue }
            if node.left < 0 {
                for index in Int(node.start)..<Int(node.start + node.count) {
                    let (a, b, c) = corners(Int(order[index]))
                    if let t = Self.rayTriangle(origin, direction, a, b, c), t <= (best ?? maxT) { best = t }
                }
            } else {
                stack.append(node.left)
                stack.append(node.right)
            }
        }
        return best
    }

    /// Where the ray enters a box, if it does. An axis the ray runs parallel to limits
    /// nothing if the ray lies within the box's extent on it (0 × ∞ would be NaN, and a
    /// ray straight down a face — a vertical ray at a whole-stud x — would miss).
    private static func slab(_ origin: Vec3, _ inverse: Vec3, _ lower: Vec3, _ upper: Vec3) -> Float? {
        var near: Float = 0, far = Float.greatestFiniteMagnitude
        for axis in 0..<3 {
            if inverse[axis].isInfinite {
                guard origin[axis] >= lower[axis], origin[axis] <= upper[axis] else { return nil }
                continue
            }
            let t1 = (lower[axis] - origin[axis]) * inverse[axis], t2 = (upper[axis] - origin[axis]) * inverse[axis]
            near = max(near, min(t1, t2))
            far = min(far, max(t1, t2))
            if far < near { return nil }
        }
        return near
    }

    /// Möller–Trumbore, both faces.
    static func rayTriangle(_ origin: Vec3, _ direction: Vec3, _ a: Vec3, _ b: Vec3, _ c: Vec3) -> Float? {
        let e1 = b - a, e2 = c - a
        let p = cross(direction, e2)
        let determinant = dot(e1, p)
        guard abs(determinant) > 1e-12 else { return nil }
        let inverse = 1 / determinant
        let s = origin - a
        // A hair of slack, so a ray down the edge two triangles share hits one of them.
        let slack: Float = 1e-5
        let u = dot(s, p) * inverse
        guard u >= -slack, u <= 1 + slack else { return nil }
        let q = cross(s, e1)
        let v = dot(direction, q) * inverse
        guard v >= -slack, u + v <= 1 + slack else { return nil }
        let t = dot(e2, q) * inverse
        return t >= 0 ? t : nil
    }

    // MARK: - Closest points, in scaled space

    /// The closest pair between a segment and the triangles near it — both points, and
    /// the triangle's outward normal — with everything scaled by `scale` (a part's Size).
    func closest(toSegment a: Vec3, _ b: Vec3, reach: Float, scale: Vec3)
        -> (onSegment: Vec3, onSurface: Vec3, normal: Vec3)? {
        let lower = (simd_min(a, b) - Vec3(repeating: reach)) / scale
        let upper = (simd_max(a, b) + Vec3(repeating: reach)) / scale
        var best: (Vec3, Vec3, Vec3, Float)?
        for index in candidates(lower: simd_min(lower, upper), upper: simd_max(lower, upper)) {
            let (p, q, r) = corners(index, scale: scale)
            let pair = Self.segmentTriangle(a, b, p, q, r)
            let distance = simd_distance_squared(pair.0, pair.1)
            if distance < (best?.3 ?? .greatestFiniteMagnitude) {
                let n = cross(q - p, r - p)
                best = (pair.0, pair.1, length(n) > 1e-12 ? normalize(n) : Vec3(0, 1, 0), distance)
            }
        }
        return best.map { ($0.0, $0.1, $0.2) }
    }

    /// Closest points between segment ab and triangle pqr.
    static func segmentTriangle(_ a: Vec3, _ b: Vec3, _ p: Vec3, _ q: Vec3, _ r: Vec3) -> (Vec3, Vec3) {
        // The segment through the triangle: they meet.
        if let t = rayTriangle(a, b - a, p, q, r), t <= 1 {
            let hit = a + (b - a) * t
            return (hit, hit)
        }
        var best = (a, closestOnTriangle(a, p, q, r))
        var bestDistance = simd_distance_squared(best.0, best.1)
        func consider(_ pair: (Vec3, Vec3)) {
            let distance = simd_distance_squared(pair.0, pair.1)
            if distance < bestDistance { best = pair; bestDistance = distance }
        }
        consider((b, closestOnTriangle(b, p, q, r)))
        for (e0, e1) in [(p, q), (q, r), (r, p)] { consider(segmentSegment(a, b, e0, e1)) }
        return best
    }

    /// Closest point on triangle abc to p (Ericson, Real-Time Collision Detection 5.1.5).
    static func closestOnTriangle(_ p: Vec3, _ a: Vec3, _ b: Vec3, _ c: Vec3) -> Vec3 {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = dot(ab, ap), d2 = dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return a }
        let bp = p - b
        let d3 = dot(ab, bp), d4 = dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return b }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { return a + ab * (d1 / (d1 - d3)) }
        let cp = p - c
        let d5 = dot(ab, cp), d6 = dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return c }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { return a + ac * (d2 / (d2 - d6)) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
        }
        let denominator = 1 / (va + vb + vc)
        return a + ab * (vb * denominator) + ac * (vc * denominator)
    }

    /// Closest points between segments p1q1 and p2q2 (Ericson 5.1.9).
    static func segmentSegment(_ p1: Vec3, _ q1: Vec3, _ p2: Vec3, _ q2: Vec3) -> (Vec3, Vec3) {
        let d1 = q1 - p1, d2 = q2 - p2, r = p1 - p2
        let a = dot(d1, d1), e = dot(d2, d2), f = dot(d2, r)
        var s: Float = 0, t: Float = 0
        if a <= 1e-12 && e <= 1e-12 { return (p1, p2) }
        if a <= 1e-12 {
            t = min(max(f / e, 0), 1)
        } else {
            let c = dot(d1, r)
            if e <= 1e-12 {
                s = min(max(-c / a, 0), 1)
            } else {
                let b = dot(d1, d2)
                let denominator = a * e - b * b
                s = denominator > 1e-12 ? min(max((b * f - c * e) / denominator, 0), 1) : 0
                t = (b * s + f) / e
                if t < 0 {
                    t = 0
                    s = min(max(-c / a, 0), 1)
                } else if t > 1 {
                    t = 1
                    s = min(max((b - c) / a, 0), 1)
                }
            }
        }
        return (p1 + d1 * s, p2 + d2 * t)
    }
}
