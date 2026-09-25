import Foundation
import simd

/// Which world parts each of the character's six body parts is touching.
///
/// Each body part is approximated by an upright capsule the size of its box, grown by
/// a small skin so that resting contact — standing on a floor, leaning on a wall the
/// body capsule stopped you at — counts as touching, as it does in Roblox. Limb swing
/// is ignored, so walking does not make feet flicker in and out of contact.
enum CharacterTouch {
    /// How close counts as touching, in studs.
    static let skin: Float = 0.1

    struct Touch: Hashable {
        let partID: UUID
        let limb: String
    }

    /// The body parts as capsules for a character standing at `position` facing `yaw`.
    static func limbs(position: Vec3, yaw: Float) -> [(name: String, capsule: Capsule)] {
        let turn = simd_quatf(angle: yaw, axis: Vec3(0, 1, 0))
        return AvatarPose.bodyParts.map { part in
            // Arms and legs hang from their joint; the torso and head are centred on it.
            let centre = part.swing != 0 ? part.joint - Vec3(0, part.size.y * 0.5, 0) : part.joint
            let radius = min(part.size.x, part.size.z) * 0.5 + skin
            let height = part.size.y + 2 * skin
            let base = position + turn.act(Vec3(centre.x, centre.y - part.size.y * 0.5 - skin, centre.z))
            return (part.name, Capsule(base: base, radius: radius, height: height))
        }
    }

    /// Every (part, body part) pair in contact. Parts that are hidden or have
    /// `canTouch` off never touch; `canCollide` makes no difference.
    static func contacts(position: Vec3, yaw: Float, parts: [Part]) -> Set<Touch> {
        let body = limbs(position: position, yaw: yaw)
        // One capsule round the whole body, to skip parts that are nowhere near.
        let whole = Capsule(base: position - Vec3(0, skin, 0), radius: 2 + skin,
                            height: CharacterController.capsuleHeight + 2 * skin + 0.5)
        var found = Set<Touch>()
        for part in parts where part.canTouch && part.inWorld {
            guard Collision.mayTouch(capsule: whole, part: part) else { continue }
            for limb in body where Collision.contact(capsule: limb.capsule, part: part) != nil {
                found.insert(Touch(partID: part.id, limb: limb.name))
            }
        }
        return found
    }
}
