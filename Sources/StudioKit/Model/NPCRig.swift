import Foundation
import simd

/// A Rig: the classic blocky character as a Model of parts — Head, Torso, two arms, two
/// legs and an invisible HumanoidRootPart (its PrimaryPart) — with a Humanoid, so the
/// engine walks it (NPCSystem). What Studio's Insert › Rig makes, and a starting point
/// for any NPC.
enum NPCRig {
    struct Colours {
        var head = Vec3(0.96, 0.8, 0.41)
        var torso = Vec3(0.05, 0.56, 0.87)
        var arms = Vec3(0.96, 0.8, 0.41)
        var legs = Vec3(0.16, 0.5, 0.2)
    }

    /// The parts, the Model and its Humanoid, standing on `feet`, facing `yaw` (0 is −Z).
    static func make(name: String = "Rig", at feet: Vec3, facing yaw: Float = 0, colours: Colours = Colours())
        -> (group: SceneGroup, parts: [Part], humanoid: DataObject) {
        var group = SceneGroup(name: name, kind: .model)
        let turn = simd_quatf(angle: yaw, axis: Vec3(0, 1, 0))
        func part(_ name: String, _ offset: Vec3, _ size: Vec3, _ colour: Vec3, collide: Bool = true,
                  shape: PartShape = .block, hidden: Bool = false) -> Part {
            var part = Part()
            part.name = name
            part.position = feet + turn.act(offset)
            part.orientation = turn
            part.size = size
            part.color = colour
            part.shape = shape
            part.anchored = true
            part.canCollide = collide
            part.transparency = hidden ? 1 : 0
            part.parentID = group.id
            return part
        }
        let root = part("HumanoidRootPart", Vec3(0, 3, 0), Vec3(2, 2, 1), colours.torso, collide: false, hidden: true)
        let parts = [
            root,
            part("Torso", Vec3(0, 3, 0), Vec3(2, 2, 1), colours.torso),
            part("Head", Vec3(0, 4.6, 0), Vec3(1.2, 1.2, 1.2), colours.head),
            part("Left Arm", Vec3(-1.5, 3, 0), Vec3(1, 2, 1), colours.arms, collide: false),
            part("Right Arm", Vec3(1.5, 3, 0), Vec3(1, 2, 1), colours.arms, collide: false),
            part("Left Leg", Vec3(-0.5, 1, 0), Vec3(1, 2, 1), colours.legs, collide: false),
            part("Right Leg", Vec3(0.5, 1, 0), Vec3(1, 2, 1), colours.legs, collide: false),
        ]
        group.primaryPartID = root.id
        let humanoid = DataObject.humanoid(in: .node(group.id))
        return (group, parts, humanoid)
    }
}

extension SceneModel {
    /// Insert › Rig: a Rig standing at `feet`, selected, in one step to undo.
    @discardableResult
    func addRig(at feet: Vec3, facing yaw: Float = 0) -> UUID {
        var rig = NPCRig.make(name: uniqueGroupName(base: "Rig"), at: feet, facing: yaw)
        commit("Insert Rig") {
            groups.append(rig.group)
            parts += rig.parts
            rig.humanoid.parent = .node(rig.group.id)
            dataObjects.append(rig.humanoid)
            selection = [rig.group.id]
        }
        return rig.group.id
    }
}
