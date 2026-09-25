import simd
import Foundation

enum GizmoHandle: Equatable {
    case translateAxis(Int)
    case translatePlane(Int)   // index is the plane's normal axis
    case scaleAxis(Int)
    case rotateAxis(Int)

    var axisIndex: Int {
        switch self {
        case .translateAxis(let i), .translatePlane(let i), .scaleAxis(let i), .rotateAxis(let i):
            return i
        }
    }
}

/// Geometry constants shared by gizmo drawing and hit testing, in gizmo-local units.
enum GizmoLayout {
    static let axisStart: Float = 0.18
    static let axisEnd: Float = 1.0
    static let shaftRadius: Float = 0.022
    static let pickRadius: Float = 0.085
    static let coneLength: Float = 0.26
    static let coneRadius: Float = 0.075
    static let handleCube: Float = 0.11
    static let planeInner: Float = 0.26
    static let planeOuter: Float = 0.52
    static let ringRadius: Float = 1.15
    static let ringPickTolerance: Float = 0.09

    /// Screen-stable gizmo size: constant apparent size regardless of camera distance.
    static func scale(pivot: Vec3, cameraPosition: Vec3) -> Float {
        max(0.35, length(pivot - cameraPosition) * 0.16)
    }

    static let axisColors: [Vec3] = [
        Vec3(0.94, 0.30, 0.34),   // X
        Vec3(0.44, 0.85, 0.35),   // Y
        Vec3(0.32, 0.56, 0.96)    // Z
    ]
    static let highlightColor = Vec3(1.0, 0.86, 0.25)
}

/// A transform drag in progress.
struct GizmoDrag {
    var handle: GizmoHandle
    var pivot: Vec3
    var basis: float3x3
    var scale: Float
    var startParts: [UUID: Part]
    var startScalar: Float = 0
    var startPoint: Vec3 = .zero
    var startAngle: Float = 0
    var appliedLabel: String = ""
}

enum Gizmo {

    /// The orientation the handles are drawn in.
    static func basis(for model: SceneModel, forceLocal: Bool = false) -> float3x3 {
        let selected = model.selectedParts
        if (model.localSpace || forceLocal), selected.count == 1 {
            return float3x3(selected[0].orientation)
        }
        return matrix_identity_float3x3
    }

    // MARK: - Hit testing

    static func hitTest(ray: Ray, mode: GizmoMode, pivot: Vec3, basis: float3x3, scale s: Float) -> GizmoHandle? {
        switch mode {
        case .select:
            return nil
        case .move:
            return hitTranslate(ray: ray, pivot: pivot, basis: basis, scale: s)
        case .scale:
            return hitAxes(ray: ray, pivot: pivot, basis: basis, scale: s).map { .scaleAxis($0) }
        case .rotate:
            return hitRings(ray: ray, pivot: pivot, basis: basis, scale: s).map { .rotateAxis($0) }
        }
    }

    private static func hitTranslate(ray: Ray, pivot: Vec3, basis: float3x3, scale s: Float) -> GizmoHandle? {
        // Plane handles sit closer to the pivot, so they take priority over the shafts.
        var best: (handle: GizmoHandle, t: Float)?
        for normalAxis in 0..<3 {
            let n = normalize(basis[normalAxis])
            guard let t = Intersect.rayPlane(ray, point: pivot, normal: n) else { continue }
            let p = ray.point(at: t) - pivot
            let a1 = normalize(basis[(normalAxis + 1) % 3])
            let a2 = normalize(basis[(normalAxis + 2) % 3])
            let u = dot(p, a1) / s
            let v = dot(p, a2) / s
            let lo = GizmoLayout.planeInner, hi = GizmoLayout.planeOuter
            if u > lo && u < hi && v > lo && v < hi {
                if best == nil || t < best!.t { best = (.translatePlane(normalAxis), t) }
            }
        }
        if let best { return best.handle }
        return hitAxes(ray: ray, pivot: pivot, basis: basis, scale: s).map { .translateAxis($0) }
    }

    private static func hitAxes(ray: Ray, pivot: Vec3, basis: float3x3, scale s: Float) -> Int? {
        var bestAxis: Int?
        var bestT = Float.greatestFiniteMagnitude
        let radius = GizmoLayout.pickRadius * s
        for axis in 0..<3 {
            let dir = normalize(basis[axis])
            let a = pivot + dir * (GizmoLayout.axisStart * s)
            let b = pivot + dir * ((GizmoLayout.axisEnd + GizmoLayout.coneLength) * s)
            let hit = Intersect.raySegmentDistance(ray, a: a, b: b)
            if hit.distance < radius && hit.tRay < bestT {
                bestT = hit.tRay
                bestAxis = axis
            }
        }
        return bestAxis
    }

    private static func hitRings(ray: Ray, pivot: Vec3, basis: float3x3, scale s: Float) -> Int? {
        var bestAxis: Int?
        var bestT = Float.greatestFiniteMagnitude
        let radius = GizmoLayout.ringRadius * s
        let tolerance = GizmoLayout.ringPickTolerance * s
        for axis in 0..<3 {
            let n = normalize(basis[axis])
            guard let t = Intersect.rayPlane(ray, point: pivot, normal: n) else { continue }
            let d = length(ray.point(at: t) - pivot)
            if abs(d - radius) < tolerance && t < bestT {
                bestT = t
                bestAxis = axis
            }
        }
        return bestAxis
    }

    // MARK: - Drag lifecycle

    static func beginDrag(handle: GizmoHandle, ray: Ray, model: SceneModel, camera: Camera) -> GizmoDrag? {
        guard let pivot = model.selectionCenter else { return nil }
        let basis = Gizmo.basis(for: model, forceLocal: model.gizmoMode == .scale)
        let s = GizmoLayout.scale(pivot: pivot, cameraPosition: camera.position)

        var drag = GizmoDrag(handle: handle, pivot: pivot, basis: basis, scale: s,
                             startParts: Dictionary(uniqueKeysWithValues: model.selectedParts.map { ($0.id, $0) }))

        switch handle {
        case .translateAxis(let axis), .scaleAxis(let axis):
            guard let t = Intersect.closestPointOnLine(ray: ray, linePoint: pivot, lineDir: normalize(basis[axis])) else { return nil }
            drag.startScalar = t
        case .translatePlane(let axis):
            let n = normalize(basis[axis])
            guard let t = Intersect.rayPlane(ray, point: pivot, normal: n) else { return nil }
            drag.startPoint = ray.point(at: t)
        case .rotateAxis(let axis):
            let n = normalize(basis[axis])
            guard let t = Intersect.rayPlane(ray, point: pivot, normal: n) else { return nil }
            drag.startAngle = angle(of: ray.point(at: t) - pivot, axis: axis, basis: basis)
        }
        return drag
    }

    static func updateDrag(_ drag: GizmoDrag, ray: Ray, model: SceneModel) {
        switch drag.handle {
        case .translateAxis(let axis):
            let dir = normalize(drag.basis[axis])
            guard let t = Intersect.closestPointOnLine(ray: ray, linePoint: drag.pivot, lineDir: dir) else { return }
            var delta = t - drag.startScalar
            if model.snapEnabled { delta = snapValue(delta, to: model.moveSnap) }
            applyTranslation(dir * delta, drag: drag, model: model)
            model.statusText = String(format: "Move %@ %.2f", axisName(axis), delta)

        case .translatePlane(let axis):
            let n = normalize(drag.basis[axis])
            guard let t = Intersect.rayPlane(ray, point: drag.pivot, normal: n) else { return }
            let raw = ray.point(at: t) - drag.startPoint
            let a1 = normalize(drag.basis[(axis + 1) % 3])
            let a2 = normalize(drag.basis[(axis + 2) % 3])
            var d1 = dot(raw, a1), d2 = dot(raw, a2)
            if model.snapEnabled {
                d1 = snapValue(d1, to: model.moveSnap)
                d2 = snapValue(d2, to: model.moveSnap)
            }
            applyTranslation(a1 * d1 + a2 * d2, drag: drag, model: model)
            model.statusText = String(format: "Move %.2f, %.2f", d1, d2)

        case .scaleAxis(let axis):
            let dir = normalize(drag.basis[axis])
            guard let t = Intersect.closestPointOnLine(ray: ray, linePoint: drag.pivot, lineDir: dir) else { return }
            var delta = t - drag.startScalar
            if model.snapEnabled { delta = snapValue(delta, to: model.scaleSnap) }
            applyScale(delta: delta, axis: axis, drag: drag, model: model)
            model.statusText = String(format: "Resize %@ %+.2f", axisName(axis), delta)

        case .rotateAxis(let axis):
            let n = normalize(drag.basis[axis])
            guard let t = Intersect.rayPlane(ray, point: drag.pivot, normal: n) else { return }
            let current = angle(of: ray.point(at: t) - drag.pivot, axis: axis, basis: drag.basis)
            var delta = current - drag.startAngle
            // Keep the shortest path so the part never spins the long way round.
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            if model.snapEnabled { delta = snapValue(delta.degrees, to: model.rotateSnap).radians }
            applyRotation(angle: delta, axis: n, drag: drag, model: model)
            model.statusText = String(format: "Rotate %@ %.1f°", axisName(axis), delta.degrees)
        }
    }

    // MARK: - Transform application

    private static func applyTranslation(_ offset: Vec3, drag: GizmoDrag, model: SceneModel) {
        for (id, start) in drag.startParts {
            model.update(id: id) { part in
                part.position = start.position + offset
            }
        }
    }

    private static func applyScale(delta: Float, axis: Int, drag: GizmoDrag, model: SceneModel) {
        for (id, start) in drag.startParts {
            model.update(id: id) { part in
                // Resize from the far face, the way Roblox's scale handles behave.
                let newSize = max(0.05, start.size[axis] + delta)
                let applied = newSize - start.size[axis]
                part.size[axis] = newSize
                let localAxis = start.worldAxis(axis)
                part.position = start.position + localAxis * (applied * 0.5)
            }
        }
    }

    private static func applyRotation(angle: Float, axis: Vec3, drag: GizmoDrag, model: SceneModel) {
        let q = simd_quatf(angle: angle, axis: normalize(axis))
        for (id, start) in drag.startParts {
            model.update(id: id) { part in
                part.orientation = simd_normalize(q * start.orientation)
                if drag.startParts.count > 1 {
                    part.position = drag.pivot + q.act(start.position - drag.pivot)
                }
            }
        }
    }

    // MARK: - Helpers

    private static func angle(of vector: Vec3, axis: Int, basis: float3x3) -> Float {
        let a1 = normalize(basis[(axis + 1) % 3])
        let a2 = normalize(basis[(axis + 2) % 3])
        return atan2(dot(vector, a2), dot(vector, a1))
    }

    static func axisName(_ i: Int) -> String { ["X", "Y", "Z"][i] }
}
