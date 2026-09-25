import Foundation
import simd
import Combine

/// The Animation Editor's working state: the playhead, the selected joint, preview
/// playback and the rig it poses in the viewport. Editing goes through `SceneModel`,
/// so every change is undoable and saved like any other.
///
/// The viewport asks it for the rig (`rigPose`), routes clicks on the rig to
/// `pickJoint`, and drags on a body part to `beginPose` / `dragPose` / `endPose`.
final class AnimationEditor: ObservableObject {
    let model: SceneModel

    /// Where the playhead is, in seconds.
    @Published var time: Float = 0
    @Published var selectedJoint: AnimationJoint? = .rightShoulder
    @Published var playing = false
    /// Snap the playhead and dragged keys to 1/30 s frames.
    @Published var snap = true
    /// The Animation tab is showing, so the rig is in the viewport.
    @Published var isOpen = false
    /// Where the rig stands; placed when the editor first opens.
    @Published var rigPosition: Vec3?

    static let frameRate: Float = 30
    /// Degrees of rotation per point of mouse drag.
    static let degreesPerPoint: Float = 0.6

    private var drag: (joint: AnimationJoint, start: SIMD2<Float>, rotation: Vec3, alternate: Bool)?

    init(model: SceneModel) {
        self.model = model
    }

    var animation: AnimationObject? { model.selectedAnimation.flatMap(model.animation(id:)) }

    /// Showing the rig: the tab is open on an animation.
    var isEditing: Bool { isOpen && animation != nil }

    // MARK: - Time

    func snapped(_ value: Float) -> Float {
        guard snap else { return value }
        return (value * Self.frameRate).rounded() / Self.frameRate
    }

    func setTime(_ value: Float) {
        let length = animation?.length ?? 1
        time = min(max(snapped(value), 0), length)
    }

    func togglePlaying() {
        guard let animation else { return }
        if !playing, time >= animation.length - 1e-4 { time = 0 }
        playing.toggle()
    }

    /// Advances preview playback; called every rendered frame.
    func step(dt: Float) {
        guard playing, isEditing, let animation else { return }
        var next = time + dt
        if next >= animation.length {
            if animation.looped {
                next = next.truncatingRemainder(dividingBy: max(animation.length, 1e-3))
            } else {
                next = animation.length
                playing = false
            }
        }
        time = next
    }

    // MARK: - The rig

    /// The rig's pose at the playhead.
    var pose: AvatarJoints {
        guard let animation else { return AvatarJoints() }
        return AnimationPlayer.pose(animation, at: time)
    }

    /// The rig to draw, or nil when the editor isn't showing one.
    func rigPose() -> AvatarPose? {
        guard isEditing else { return nil }
        var pose = AvatarPose(position: rigPosition ?? .zero, yaw: 0, joints: pose)
        pose.colors = model.starterPlayer.bodyColors
        pose.look = model.starterPlayer.look
        pose.highlighted = selectedJoint?.bodyPart
        return pose
    }

    /// Stands the rig on whatever is under `point`, or on the ground.
    func placeRig(near point: Vec3) {
        var position = Vec3(point.x, 0, point.z)
        let down = Ray(origin: Vec3(point.x, 500, point.z), direction: Vec3(0, -1, 0))
        if let hit = Picking.pick(ray: down, in: model.parts.filter(\.canCollide)) {
            position.y = 500 - hit.distance
        }
        rigPosition = position
    }

    /// The body part of the rig a ray hits first, if any.
    func pickJoint(ray: Ray) -> (joint: AnimationJoint, distance: Float)? {
        guard let rig = rigPose() else { return nil }
        let sizes = Dictionary(uniqueKeysWithValues: AvatarPose.bodyParts.map { ($0.name, $0.size) })
        var best: (AnimationJoint, Float)?
        for (name, matrix) in rig.partTransforms() {
            guard let joint = AnimationJoint.joint(forBodyPart: name), let size = sizes[name] else { continue }
            var box = Part()
            box.position = Vec3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
            box.orientation = simd_quatf(float3x3(Vec3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
                                                  Vec3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
                                                  Vec3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)))
            box.size = size
            if let distance = Picking.intersect(ray: ray, part: box), distance < (best?.1 ?? .infinity) {
                best = (joint, distance)
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    // MARK: - Posing

    /// The joint's rotation at the playhead in degrees: its key there, or what the
    /// animation passes through there, or rest.
    func rotation(of joint: AnimationJoint) -> Vec3 {
        guard let animation else { return .zero }
        if let index = animation.keyIndex(for: joint, at: time) {
            return animation.keys(for: joint)[index].rotation
        }
        return (animation.sample(joint, at: time)?.rotation ?? .zero) * (180 / .pi)
    }

    func position(of joint: AnimationJoint) -> Vec3 {
        guard let animation else { return .zero }
        if let index = animation.keyIndex(for: joint, at: time) {
            return animation.keys(for: joint)[index].position
        }
        return animation.sample(joint, at: time)?.position ?? .zero
    }

    func hasKey(_ joint: AnimationJoint) -> Bool {
        animation?.keyIndex(for: joint, at: time) != nil
    }

    /// Keys the joint at the playhead. Not undoable by itself — callers commit or stroke.
    func setPose(_ joint: AnimationJoint, rotation: Vec3? = nil, position: Vec3? = nil) {
        guard let id = model.selectedAnimation else { return }
        let rotation = rotation ?? self.rotation(of: joint)
        let position = joint.hasPosition ? (position ?? self.position(of: joint)) : nil
        let at = time
        model.updateAnimation(id: id) { $0.setKey(joint, at: at, rotation: rotation, position: position) }
    }

    /// Starts dragging a joint: vertical drag swings it (X), horizontal raises it
    /// sideways (Z), or twists it (Y) with Option held.
    func beginPose(_ joint: AnimationJoint, at point: SIMD2<Float>, alternate: Bool) {
        selectedJoint = joint
        playing = false
        drag = (joint, point, rotation(of: joint), alternate)
        model.beginStroke()
    }

    func dragPose(to point: SIMD2<Float>) {
        guard let drag else { return }
        let delta = (point - drag.start) * Self.degreesPerPoint
        var rotation = drag.rotation
        if drag.alternate {
            rotation.y = Self.wrap(drag.rotation.y + delta.x)
        } else {
            // Up the screen swings the limb forward and up.
            rotation.x = Self.wrap(drag.rotation.x - delta.y)
            rotation.z = Self.wrap(drag.rotation.z + delta.x)
        }
        setPose(drag.joint, rotation: rotation)
    }

    func endPose() {
        guard drag != nil else { return }
        drag = nil
        model.endStroke()
        model.statusText = "Posed \(selectedJoint?.rawValue ?? "joint")"
    }

    var isPosing: Bool { drag != nil }

    static func wrap(_ degrees: Float) -> Float {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }
}
