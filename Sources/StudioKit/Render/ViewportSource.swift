import Foundation
import simd

/// Editor-only decorations. `nil` means the viewport is in play mode.
struct EditorOverlay {
    var gizmoMode: GizmoMode
    var selection: Set<UUID>
    var activeHandle: GizmoHandle?
    /// The part held as the first end of a weld or joint, outlined in its own colour.
    var joinPending: UUID?
    /// The Terrain Editor's brush where the pointer is: its middle and radius.
    var brush: (centre: Vec3, radius: Float)?
}

/// A classic six-part Roblox avatar to draw, posed by `AvatarAnimator`.
struct AvatarPose {
    var position: Vec3          // feet
    var yaw: Float
    var joints = AvatarJoints()
    var hidden = false
    var colors = BodyColors()
    /// What it wears: face, shirt, pants and accessories.
    var look = AvatarLook()
    /// Per body part, by Roblox name; 1 hides the part.
    var transparency: [String: Float] = [:]
    /// Lying on the ground.
    var dead = false
    /// A body part drawn brighter — the joint selected in the Animation Editor.
    var highlighted: String?

    /// The six body parts: Roblox name, joint position, size, and whether the part hangs
    /// from its joint (arms and legs, non-zero) or is centred on it (torso, head).
    /// The same table sizes touch detection (`CharacterTouch`), so the body you see is
    /// the body that touches.
    static let bodyParts: [(name: String, joint: Vec3, size: Vec3, swing: Float)] = [
        ("Left Leg", Vec3(-0.5, 2, 0), Vec3(1, 2, 1), 1),
        ("Right Leg", Vec3(0.5, 2, 0), Vec3(1, 2, 1), -1),
        ("Torso", Vec3(0, 3, 0), Vec3(2, 2, 1), 0),
        ("Left Arm", Vec3(-1.5, 4, 0), Vec3(1, 2, 1), -1),
        ("Right Arm", Vec3(1.5, 4, 0), Vec3(1, 2, 1), 1),
        ("Head", Vec3(0, 4.65, 0), Vec3(1.3, 1.3, 1.3), 0)
    ]

    /// Where the upper body bends: the hips.
    static let hip = Vec3(0, 2, 0)
    /// Where the head turns: the top of the torso.
    static let neck = Vec3(0, 4, 0)
    /// Where the RootJoint turns the body: its middle.
    static let middle = Vec3(0, 2.5, 0)

    /// Each body part's transform, placing a mesh that is centred on the origin at its
    /// real size. Pure maths, so it is tested without a GPU.
    func partTransforms() -> [(name: String, matrix: float4x4)] {
        let turn = Mat.rotation(simd_quatf(angle: yaw, axis: Vec3(0, 1, 0)))
        var body: float4x4
        if dead {
            // Fallen flat: tipped onto its front and lowered so it lies on the ground.
            body = Mat.translation(position + Vec3(0, 0.5, 0)) * turn
                * Mat.rotation(simd_quatf(angle: -.pi / 2, axis: Vec3(1, 0, 0)))
        } else {
            body = Mat.translation(position) * turn * Mat.translation(joints.offset)
            if joints.root != .zero {
                body = body * Self.pivot(Self.middle, joints.root)
            }
        }
        let upper = body * Self.pivot(Self.hip, Vec3(joints.lean, 0, 0))

        return Self.bodyParts.map { part in
            let matrix: float4x4
            switch part.name {
            case "Head":
                matrix = upper * Mat.translation(Self.neck) * Self.rotation(joints.neck)
                    * Mat.translation(part.joint - Self.neck)
            case "Torso":
                matrix = upper * Mat.translation(part.joint)
            default:
                // Arms and legs hang from their joint and turn about it.
                let parent = part.name.hasSuffix("Leg") ? body : upper
                matrix = parent * Mat.translation(part.joint) * Self.rotation(joints.rotation(for: part.name))
                    * Mat.translation(Vec3(0, -part.size.y * 0.5, 0))
            }
            return (part.name, matrix)
        }
    }

    static func rotation(_ euler: Vec3) -> float4x4 {
        let q = simd_quatf(angle: euler.z, axis: Vec3(0, 0, 1))
            * simd_quatf(angle: euler.y, axis: Vec3(0, 1, 0))
            * simd_quatf(angle: euler.x, axis: Vec3(1, 0, 0))
        return Mat.rotation(q)
    }

    private static func pivot(_ point: Vec3, _ euler: Vec3) -> float4x4 {
        Mat.translation(point) * rotation(euler) * Mat.translation(-point)
    }
}

/// Anything the renderer can draw a frame from: the editor viewport or the play client.
protocol ViewportSource: AnyObject {
    var model: SceneModel { get }
    var renderCamera: Camera { get }
    var editorOverlay: EditorOverlay? { get }
    var avatars: [AvatarPose] { get }
    /// Compile results for user shaders, surfaced to the editor UI.
    var shaderStatus: ShaderStatusStore { get }
    /// Where shader diagnostics go.
    var shaderConsole: ScriptConsole { get }
    /// Called once per frame before drawing, for input-driven simulation.
    func stepFrame()
}
