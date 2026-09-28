import Foundation
import simd
import QuartzCore

/// Owns viewport-only state: the camera, the in-flight gizmo drag and hover feedback.
/// Kept outside `SceneModel` so camera motion never invalidates SwiftUI views.
final class ViewportController: ViewportSource {
    let model: SceneModel
    let shaderStatus: ShaderStatusStore
    let shaderConsole: ScriptConsole
    var camera = Camera()

    var activeHandle: GizmoHandle?
    private var drag: GizmoDrag?
    private var flyKeys: Set<String> = []
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    var orbiting = false
    /// The Animation Editor, whose rig stands in the viewport while it is open.
    let animationEditor: AnimationEditor

    /// Size of the drawable in points, used to build picking rays.
    var viewSize = SIMD2<Float>(1, 1)

    init(model: SceneModel, shaderStatus: ShaderStatusStore = ShaderStatusStore(),
         console: ScriptConsole = ScriptConsole()) {
        self.model = model
        self.shaderStatus = shaderStatus
        self.shaderConsole = console
        self.animationEditor = AnimationEditor(model: model)
    }

    // MARK: - ViewportSource

    var renderCamera: Camera { camera }

    var editorOverlay: EditorOverlay? {
        // A join tool takes the viewport over: no gizmo to get in the way of the clicks.
        EditorOverlay(gizmoMode: model.joinTool == nil && model.terrainBrush == nil ? model.gizmoMode : .select,
                      selection: model.effectiveSelection, activeHandle: activeHandle,
                      joinPending: model.joinPending,
                      brush: model.terrainBrush == nil ? nil : brushPoint.map { ($0, model.terrainBrushSize / 2) })
    }

    var avatars: [AvatarPose] {
        animationEditor.rigPose().map { [$0] } ?? []
    }

    /// Studio's Run mode: a session with no player, stepped with the editor's frames
    /// while the editor keeps the camera and the mouse.
    var running: PlayController?
    /// Keys for the GUI being edited over the world (the arrows nudge it); true when used.
    var guiKeys: ((_ keyCode: UInt16, _ shift: Bool) -> Bool)?

    func stepFrame() {
        let dt = Float(min(max(CACurrentMediaTime() - lastFrameTime, 0), 0.1))
        running?.stepFrame()
        stepFlyCamera()
        animationEditor.step(dt: dt)
    }

    /// Stands the Animation Editor's rig where the camera is looking, if it has no
    /// place yet, and frames it.
    func showRig(reposition: Bool = false) {
        if animationEditor.rigPosition == nil || reposition {
            animationEditor.placeRig(near: camera.target)
        }
        if let position = animationEditor.rigPosition {
            camera.focus(on: position + Vec3(0, 2.6, 0), radius: 4)
            // Face the rig: it looks down −Z.
            camera.yaw = -.pi / 2 + 0.5
        }
    }

    func ray(at point: SIMD2<Float>) -> Ray {
        camera.ray(atViewPoint: point, viewSize: viewSize)
    }

    // MARK: - Selection and dragging

    /// Returns true when the press started a gizmo drag.
    @discardableResult
    func mouseDown(at point: SIMD2<Float>, additive: Bool, alternate: Bool = false) -> Bool {
        let r = ray(at: point)

        // With the Animation Editor open, the rig comes first: click a body part to
        // select its joint, drag to pose it.
        if let hit = animationEditor.pickJoint(ray: r),
           hit.distance < (Picking.pick(ray: r, in: model.parts)?.distance ?? .infinity) {
            animationEditor.beginPose(hit.joint, at: point, alternate: alternate)
            model.statusText = "\(hit.joint.rawValue): drag to pose · ⌥ drag to twist"
            return true
        }

        // A terrain brush: the press paints, and so does dragging, as one step to undo.
        if model.terrainBrush != nil {
            guard let centre = brushTarget(r) else { return false }
            model.beginStroke()
            brushing = true
            dab(at: centre)
            return true
        }

        // A weld or joint tool is armed: clicks name the two parts to join, and
        // nothing else — no dragging, no changing the selection.
        if model.joinTool != nil {
            if let hit = Picking.pick(ray: r, in: model.parts) {
                model.pickJoinTarget(hit.part.id)
            } else {
                model.clearJoinPending()
            }
            return false
        }

        if let pivot = model.selectionCenter, model.gizmoMode != .select {
            let basis = Gizmo.basis(for: model, forceLocal: model.gizmoMode == .scale)
            let s = GizmoLayout.scale(pivot: pivot, cameraPosition: camera.position)
            if let handle = Gizmo.hitTest(ray: r, mode: model.gizmoMode, pivot: pivot, basis: basis, scale: s) {
                model.beginStroke()
                drag = Gizmo.beginDrag(handle: handle, ray: r, model: model, camera: camera)
                activeHandle = drag == nil ? nil : handle
                return drag != nil
            }
        }

        if let hit = Picking.pick(ray: r, in: model.parts) {
            // A click selects the Model a part is in, as in Roblox Studio; ⌥-click
            // reaches the part itself.
            let target = alternate ? hit.part.id : (model.outermostModel(containing: hit.part.id) ?? hit.part.id)
            if additive {
                if model.selection.contains(target) {
                    model.selection.remove(target)
                } else {
                    model.selection.insert(target)
                }
            } else {
                model.selection = [target]
            }
            model.statusText = "Selected \(model.name(of: target) ?? hit.part.name)"
        } else if !additive {
            // Empty space: nothing selected at all, as in Roblox Studio.
            model.deselectAll()
            model.statusText = "Ready"
        }
        return false
    }

    func mouseDragged(to point: SIMD2<Float>) {
        if brushing {
            if let centre = brushTarget(ray(at: point)) {
                brushPoint = centre
                // A dab each quarter of the brush it moves, so strokes are even.
                if lastDab.map({ simd_distance(centre, $0) >= model.terrainBrushSize / 8 }) ?? true { dab(at: centre) }
            }
            return
        }
        if animationEditor.isPosing {
            animationEditor.dragPose(to: point)
            return
        }
        guard let drag else { return }
        Gizmo.updateDrag(drag, ray: ray(at: point), model: model)
    }

    func mouseUp() {
        if brushing {
            brushing = false
            lastDab = nil
            model.endStroke()
        }
        animationEditor.endPose()
        if drag != nil {
            model.endStroke()
        }
        drag = nil
        activeHandle = nil
    }

    func updateHover(at point: SIMD2<Float>) {
        brushPoint = model.terrainBrush == nil ? nil : brushTarget(ray(at: point))
        guard drag == nil, model.joinTool == nil, model.terrainBrush == nil else { return }
        guard model.gizmoMode != .select, let pivot = model.selectionCenter else {
            activeHandle = nil
            return
        }
        let basis = Gizmo.basis(for: model, forceLocal: model.gizmoMode == .scale)
        let s = GizmoLayout.scale(pivot: pivot, cameraPosition: camera.position)
        activeHandle = Gizmo.hitTest(ray: ray(at: point), mode: model.gizmoMode, pivot: pivot, basis: basis, scale: s)
    }

    var isDragging: Bool { drag != nil || brushing }

    // MARK: - Terrain brush

    /// Painting with the terrain brush now, and where it last dabbed.
    private(set) var brushing = false
    private var lastDab: Vec3?
    /// Where the brush is, under the pointer.
    private(set) var brushPoint: Vec3?

    /// Where a ray meets the terrain — or, where there's none, the ground.
    func brushTarget(_ ray: Ray) -> Vec3? {
        if let hit = Picking.pick(ray: ray, in: model.terrainParts) { return ray.origin + ray.direction * hit.distance }
        return Picking.groundPoint(ray: ray)
    }

    /// One dab of the brush at a point.
    func dab(at centre: Vec3) {
        guard let brush = model.terrainBrush else { return }
        lastDab = centre
        var terrain = model.terrain
        terrain.brush(brush, centre: centre, radius: model.terrainBrushSize / 2, strength: model.terrainBrushStrength,
                      material: model.terrainMaterial)
        model.terrain = terrain
    }

    // MARK: - Camera

    func orbit(dx: Float, dy: Float) { camera.orbit(deltaX: dx, deltaY: dy) }
    func pan(dx: Float, dy: Float) { camera.pan(deltaX: dx, deltaY: dy) }
    func zoom(_ amount: Float) { camera.zoom(amount) }

    func setFlyKey(_ key: String, pressed: Bool) {
        if pressed { flyKeys.insert(key) } else { flyKeys.remove(key) }
    }

    func clearFlyKeys() { flyKeys.removeAll() }

    /// Applies held WASD/QE movement; called once per rendered frame.
    func stepFlyCamera() {
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastFrameTime, 0), 0.1))
        lastFrameTime = now
        guard orbiting, !flyKeys.isEmpty else { return }

        var forward: Float = 0, right: Float = 0, up: Float = 0
        if flyKeys.contains("w") { forward += 1 }
        if flyKeys.contains("s") { forward -= 1 }
        if flyKeys.contains("d") { right += 1 }
        if flyKeys.contains("a") { right -= 1 }
        if flyKeys.contains("e") { up += 1 }
        if flyKeys.contains("q") { up -= 1 }
        let speed = max(12, camera.distance * 0.9) * dt * (flyKeys.contains("shift") ? 2.5 : 1)
        camera.fly(forwardAmount: forward, rightAmount: right, upAmount: up, speed: speed)
    }

    /// Frame the current selection, or the whole scene when nothing is selected.
    func focusSelection() {
        let targets = model.selection.isEmpty ? model.parts : model.selectedParts
        guard !targets.isEmpty else {
            camera.focus(on: Vec3(0, 0, 0), radius: 20)
            return
        }
        var lo = Vec3(repeating: .greatestFiniteMagnitude)
        var hi = Vec3(repeating: -.greatestFiniteMagnitude)
        for part in targets {
            let extent = abs(part.size) * 0.87   // conservative bound for any rotation
            lo = min(lo, part.position - extent)
            hi = max(hi, part.position + extent)
        }
        let center = (lo + hi) * 0.5
        camera.focus(on: center, radius: length(hi - lo) * 0.5)
    }

    /// Drop a new part on the ground under the cursor, or in front of the camera.
    /// A MeshPart of an imported model, where a new part would go.
    @discardableResult
    func insertMeshPart(_ asset: UUID, atScreenPoint point: SIMD2<Float>? = nil) -> UUID? {
        var position = camera.target + camera.forward * 6
        if let point, let ground = Picking.groundPoint(ray: ray(at: point)) {
            position = ground
        }
        position.y = 0
        return model.insertMeshPart(asset, at: position)
    }

    func insertPart(shape: PartShape, atScreenPoint point: SIMD2<Float>?) {
        var position = camera.target + camera.forward * 6
        if let point, let ground = Picking.groundPoint(ray: ray(at: point)) {
            position = ground
        }
        if model.snapEnabled {
            position.x = snapValue(position.x, to: model.moveSnap)
            position.z = snapValue(position.z, to: model.moveSnap)
        }
        let id = model.addPart(shape: shape, at: position)
        if let index = model.index(of: id) {
            model.parts[index].position.y = model.parts[index].size.y / 2
        }
    }

    /// Insert › Rig: a character with a Humanoid, standing on the ground in front of the
    /// camera and facing it, for scripts to walk (NPCSystem).
    func insertRig() {
        var feet = camera.target + camera.forward * 6
        feet.y = 0
        if model.snapEnabled {
            feet.x = snapValue(feet.x, to: model.moveSnap)
            feet.z = snapValue(feet.z, to: model.moveSnap)
        }
        let back = -camera.forward
        model.addRig(at: feet, facing: atan2(-back.x, -back.z))
    }

    /// A Toolbox model in front of the camera, on the ground (or whatever's under it).
    func insert(_ item: ToolboxModel) {
        var ground = camera.target + camera.forward * 10
        // On top of whatever is there (a locked baseplate too), or at 0.
        let ray = Ray(origin: Vec3(ground.x, 1000, ground.z), direction: Vec3(0, -1, 0))
        let hits = (model.parts + model.terrainParts).filter(\.inWorld).compactMap { Picking.intersect(ray: ray, part: $0) }
        ground.y = hits.min().map { 1000 - $0 } ?? 0
        if model.snapEnabled {
            ground.x = snapValue(ground.x, to: model.moveSnap)
            ground.z = snapValue(ground.z, to: model.moveSnap)
        }
        model.insert(item, at: ground)
    }
}
