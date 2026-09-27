import Foundation
import simd

/// Beams and Trails as something to draw: strips of points, two to a point (one either
/// side of the middle), each with where it is along the picture, its colour and glow. A
/// Beam is worked out afresh each frame from its attachments; a Trail remembers where
/// its attachments have been (`TrailSystem`), each machine its own, as particles are.
enum Ribbons {
    struct Vertex {
        var position: Vec3
        /// x along the ribbon (in picture lengths), y across it (0 to 1).
        var uv: SIMD2<Float>
        var color: SIMD4<Float>
        var emission: Float
    }

    /// One Beam or Trail: pairs of vertices, a triangle strip from end to end.
    struct Strip {
        var texture: String
        var vertices: [Vertex]
    }

    /// A Beam's middle line: the cubic curve that leaves each attachment along its axis
    /// (Attachment0's forward by CurveSize0, Attachment1's backward by CurveSize1).
    static func beamCurve(from p0: Vec3, axis a0: Vec3, to p1: Vec3, axis a1: Vec3,
                          curve0: Float, curve1: Float, segments: Int) -> [Vec3] {
        let c0 = p0 + a0 * curve0, c1 = p1 - a1 * curve1
        let count = min(max(segments, 1), 100)
        return (0...count).map { index in
            let t = Float(index) / Float(count), u = 1 - t
            return p0 * (u * u * u) + c0 * (3 * u * u * t) + c1 * (3 * u * t * t) + p1 * (t * t * t)
        }
    }

    /// Every enabled Beam's strip, and every Trail's from its history.
    static func strips(model: SceneModel, trails: TrailSystem, eye: Vec3, time: Float) -> [Strip] {
        var strips: [Strip] = []
        for constraint in model.constraints where constraint.kind.isEffect {
            guard let ends = worldEnds(constraint, model: model) else { continue }
            let look = constraint.look
            if constraint.kind == .beam {
                guard constraint.enabled else { continue }
                strips.append(beam(look, ends: ends, eye: eye, time: time))
            } else if let strip = trail(look, points: trails.points(of: constraint.id, live: constraint.enabled ? ends : nil),
                                        clock: trails.clock, eye: eye) {
                strips.append(strip)
            }
        }
        return strips
    }

    typealias End = (position: Vec3, axis: Vec3, secondary: Vec3)

    /// Its two attachments in the world, when both are on parts that are in it.
    static func worldEnds(_ constraint: SceneConstraint, model: SceneModel) -> (End, End)? {
        guard let a0 = constraint.attachment0.flatMap(model.attachment(id:)),
              let a1 = constraint.attachment1.flatMap(model.attachment(id:)),
              let p0 = model.part(id: a0.parentID), let p1 = model.part(id: a1.parentID),
              p0.inWorld, p1.inWorld, p0.storage == nil, p1.storage == nil,
              let f0 = model.worldFrame(of: a0), let f1 = model.worldFrame(of: a1) else { return nil }
        return (f0, f1)
    }

    private static func beam(_ look: RibbonLook, ends: (End, End), eye: Vec3, time: Float) -> Strip {
        let (e0, e1) = ends
        let points = beamCurve(from: e0.position, axis: e0.axis, to: e1.position, axis: e1.axis,
                               curve0: look.curveSize0, curve1: look.curveSize1, segments: look.segments)
        var along: [Float] = [0]
        for (a, b) in zip(points, points.dropFirst()) { along.append(along.last! + simd_distance(a, b)) }
        var vertices: [Vertex] = []
        vertices.reserveCapacity(points.count * 2)
        for (index, point) in points.enumerated() {
            let t = Float(index) / Float(max(points.count - 1, 1))
            let before = points[max(index - 1, 0)], after = points[min(index + 1, points.count - 1)]
            let tangent = simd_length(after - before) > 1e-6 ? simd_normalize(after - before) : Vec3(1, 0, 0)
            // Across it: facing the eye, or lying across the attachments' secondary axes.
            let facing = look.faceCamera ? eye - point : simd_mix(e0.secondary, e1.secondary, Vec3(repeating: t))
            var side = simd_cross(tangent, facing)
            side = simd_length(side) > 1e-6 ? simd_normalize(side) : simd_normalize(simd_cross(tangent, Vec3(0, 1, 0.001)))
            let width = look.width0 + (look.width1 - look.width0) * t
            let u = (look.textureMode == .wrap ? along[index] / max(look.textureLength, 1e-3) : t * look.textureLength)
                - time * look.textureSpeed
            let colour = SIMD4(look.color.color(at: t) * max(look.brightness, 0),
                               1 - min(max(look.transparency.value(at: t), 0), 1))
            let emission = min(max(look.lightEmission, 0), 1)
            vertices.append(Vertex(position: point + side * (width / 2), uv: SIMD2(u, 0), color: colour, emission: emission))
            vertices.append(Vertex(position: point - side * (width / 2), uv: SIMD2(u, 1), color: colour, emission: emission))
        }
        return Strip(texture: look.texture, vertices: vertices)
    }

    private static func trail(_ look: RibbonLook, points: [TrailSystem.Point], clock: Double, eye: Vec3) -> Strip? {
        guard points.count >= 2 else { return nil }
        // Newest first: the head is where the attachments are now.
        let ordered = points.reversed() as [TrailSystem.Point]
        var along: [Float] = [0]
        for (a, b) in zip(ordered, ordered.dropFirst()) { along.append(along.last! + simd_distance(a.middle, b.middle)) }
        let total = max(along.last ?? 0, 1e-4)
        var vertices: [Vertex] = []
        for (index, point) in ordered.enumerated() {
            let age = min(max(Float(clock - point.born) / max(look.lifetime, 1e-3), 0), 1)
            let scale = max(look.widthScale.value(at: age), 0)
            var top = point.top, bottom = point.bottom
            if look.faceCamera {
                let next = ordered[min(index + 1, ordered.count - 1)].middle, previous = ordered[max(index - 1, 0)].middle
                let tangent = simd_length(previous - next) > 1e-6 ? simd_normalize(previous - next) : Vec3(0, 1, 0)
                var side = simd_cross(tangent, eye - point.middle)
                side = simd_length(side) > 1e-6 ? simd_normalize(side) : Vec3(0, 1, 0)
                let half = simd_distance(point.top, point.bottom) / 2
                top = point.middle + side * half
                bottom = point.middle - side * half
            }
            top = point.middle + (top - point.middle) * scale
            bottom = point.middle + (bottom - point.middle) * scale
            let u = look.textureMode == .wrap ? along[index] / max(look.textureLength, 1e-3)
                : along[index] / total * look.textureLength
            let colour = SIMD4(look.color.color(at: age) * max(look.brightness, 0),
                               1 - min(max(look.transparency.value(at: age), 0), 1))
            let emission = min(max(look.lightEmission, 0), 1)
            vertices.append(Vertex(position: top, uv: SIMD2(u, 0), color: colour, emission: emission))
            vertices.append(Vertex(position: bottom, uv: SIMD2(u, 1), color: colour, emission: emission))
        }
        return Strip(texture: look.texture, vertices: vertices)
    }
}

/// Where each Trail's attachments have been, on this machine: a point each time they've
/// moved MinLength, kept for Lifetime (and no longer than MaxLength end to end).
final class TrailSystem {
    struct Point {
        var top: Vec3
        var bottom: Vec3
        var born: Double
        var middle: Vec3 { (top + bottom) / 2 }
    }

    struct History {
        var points: [Point] = []
        var cleared: Int
    }

    private(set) var histories: [UUID: History] = [:]
    private(set) var clock = 0.0

    func step(dt: Float, model: SceneModel) {
        clock += Double(max(dt, 0))
        var seen: Set<UUID> = []
        for constraint in model.constraints where constraint.kind == .trail {
            guard let (e0, e1) = Ribbons.worldEnds(constraint, model: model) else { continue }
            seen.insert(constraint.id)
            let look = constraint.look
            var history = histories[constraint.id] ?? History(cleared: look.cleared)
            if look.cleared != history.cleared {
                history.points.removeAll()
                history.cleared = look.cleared
            }
            history.points.removeAll { clock - $0.born > Double(look.lifetime) }
            if constraint.enabled {
                let now = Point(top: e0.position, bottom: e1.position, born: clock)
                if let last = history.points.last {
                    if simd_distance(last.middle, now.middle) >= max(look.minLength, 0.001) { history.points.append(now) }
                } else {
                    history.points.append(now)
                }
            }
            if look.maxLength > 0 {
                // From the newest back, as far as MaxLength reaches.
                var length: Float = 0, keep = history.points.count
                for index in stride(from: history.points.count - 1, to: 0, by: -1) {
                    length += simd_distance(history.points[index].middle, history.points[index - 1].middle)
                    if length > look.maxLength { break }
                    keep = history.points.count - index + 1
                }
                if keep < history.points.count { history.points.removeFirst(history.points.count - keep) }
            }
            if history.points.count > 2000 { history.points.removeFirst(history.points.count - 2000) }
            histories[constraint.id] = history
        }
        for id in histories.keys where !seen.contains(id) { histories[id] = nil }
    }

    /// A trail's points, oldest first, then where its attachments are now (the head).
    func points(of trail: UUID, live: (Ribbons.End, Ribbons.End)?) -> [Point] {
        var points = histories[trail]?.points ?? []
        if let live { points.append(Point(top: live.0.position, bottom: live.1.position, born: clock)) }
        return points
    }
}
