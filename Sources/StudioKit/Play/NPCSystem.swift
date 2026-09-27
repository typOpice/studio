import Foundation
import simd

/// Characters that aren't players: every Model in the Workspace with a Humanoid in it.
/// Each gets a body the engine moves — a `CharacterController` of its own, so it walks
/// at its WalkSpeed, falls, steps up, jumps and stops at walls as a player does — and
/// the Model's parts follow it, arms and legs swinging as it walks. Scripts steer it
/// through its Humanoid (`npc.*`): MoveTo a point, Move in a direction, Jump.
///
/// Only the machine running the scene's scripts moves them; the parts it moves reach
/// joined players like any others. At no health a Humanoid dies: its Model's parts are
/// let go (unanchored) and fall, and it's steered no more.
final class NPCSystem {
    /// Roblox gives up on a MoveTo after this long.
    static let moveTimeout = 8.0
    /// How near (across the ground) a MoveTo has to get.
    static let arrival: Float = 1

    struct Body {
        let humanoid: UUID
        let modelID: UUID
        let rootID: UUID
        var controller = CharacterController()
        /// From the feet up to the root part's centre.
        var hip: Float
        /// Each part's pose in the root's upright frame, when the body was made.
        var rest: [(part: UUID, pose: Pose, limb: Limb?)]
        var target: Vec3?
        var targetSince = 0.0
        var direction = Vec3.zero
        var jump = false
        /// Where the root part was put last, to notice a script moving it.
        var placed: Pose?
        /// The body as it was when the parts were last put: standing still, they aren't
        /// put again (each change is sent to every joined player).
        var lastPut: SIMD4<Float>?
    }

    enum Limb { case leftArm, rightArm, leftLeg, rightLeg }

    private(set) var bodies: [UUID: Body] = [:]
    private weak var model: SceneModel?
    /// Events for scripts: ["NPC", humanoid, "MoveToFinished", reached].
    var events: [ScriptValue] = []
    var clock = 0.0

    init(model: SceneModel) {
        self.model = model
    }

    // MARK: - Steering (from scripts)

    func moveTo(_ humanoid: UUID, _ point: Vec3?) {
        guard var body = body(for: humanoid) else { return }
        body.target = point
        body.targetSince = clock
        body.direction = .zero
        bodies[humanoid] = body
    }

    func move(_ humanoid: UUID, direction: Vec3) {
        guard var body = body(for: humanoid) else { return }
        // Walking a direction replaces walking to a point, which doesn't finish.
        body.target = nil
        body.direction = Vec3(direction.x, 0, direction.z)
        bodies[humanoid] = body
    }

    func jump(_ humanoid: UUID) {
        guard var body = body(for: humanoid) else { return }
        body.jump = true
        bodies[humanoid] = body
    }

    /// Where it's going, and how fast it's going there, for scripts to read.
    func state(of humanoid: UUID) -> (moveDirection: Vec3, walkToPoint: Vec3?, grounded: Bool, rising: Bool)? {
        guard let body = bodies[humanoid] else { return nil }
        let velocity = body.controller.velocity
        let across = Vec3(velocity.x, 0, velocity.z)
        return (length(across) > 0.05 ? normalize(across) : .zero, body.target, body.controller.grounded, velocity.y > 0.5)
    }

    func rootPart(of humanoid: UUID) -> UUID? {
        bodies[humanoid]?.rootID ?? body(for: humanoid)?.rootID
    }

    // MARK: - Bodies

    /// The body for a Humanoid, made from its Model the first time it's asked for.
    private func body(for humanoid: UUID) -> Body? {
        if let known = bodies[humanoid] { return known }
        guard let model, let object = model.dataObject(id: humanoid), object.className == .humanoid,
              case .node(let modelID) = object.parent, let group = model.group(id: modelID),
              model.isInWorkspace(group), object.health > 0 else { return nil }
        let partIDs = model.partIDs(inSubtree: modelID)
        let parts = partIDs.compactMap(model.part(id:))
        guard !parts.isEmpty else { return nil }
        // The root: HumanoidRootPart, the PrimaryPart, the Torso, or the first part.
        let root = parts.first { $0.name == "HumanoidRootPart" }
            ?? group.primaryPartID.flatMap { id in parts.first { $0.id == id } }
            ?? parts.first { $0.name == "Torso" } ?? parts[0]
        guard let box = model.boundingBox(of: partIDs) else { return nil }
        let feet = box.center.y - box.size.y / 2
        let forward = root.orientation.act(Vec3(0, 0, -1))
        let yaw = atan2(-forward.x, -forward.z)
        let upright = Pose(position: root.position, orientation: simd_quatf(angle: yaw, axis: Vec3(0, 1, 0)))
        let limbs: [String: Limb] = ["Left Arm": .leftArm, "Right Arm": .rightArm, "Left Leg": .leftLeg,
                                     "Right Leg": .rightLeg]
        var body = Body(humanoid: humanoid, modelID: modelID, rootID: root.id, hip: root.position.y - feet,
                        rest: parts.map { (part: $0.id, pose: upright.inverse.applying($0.pose), limb: limbs[$0.name]) })
        body.controller.position = Vec3(root.position.x, feet, root.position.z)
        body.controller.facingYaw = yaw
        body.controller.spawnPoint = body.controller.position
        body.placed = root.pose
        // Moved by the engine from now on, so held where it's put.
        for id in partIDs { model.update(id: id) { $0.anchored = true } }
        bodies[humanoid] = body
        return body
    }

    // MARK: - Each frame

    /// Moves every living Humanoid's Model one frame.
    func step(dt: Float, ground solidGround: Bool) {
        guard let model else { return }
        clock += Double(dt)
        let humanoids = model.dataObjects.filter { $0.className == .humanoid }
        let living = Set(humanoids.map(\.id))
        for id in bodies.keys where !living.contains(id) { bodies[id] = nil }
        for object in humanoids {
            guard case .node(let modelID) = object.parent, model.group(id: modelID) != nil else {
                bodies[object.id] = nil
                continue
            }
            if object.health <= 0 {
                if let body = bodies.removeValue(forKey: object.id) { fallApart(body) }
                continue
            }
            guard var body = body(for: object.id) else { continue }
            step(&body, object: object, dt: dt, ground: solidGround)
            bodies[object.id] = body
        }
    }

    private func step(_ body: inout Body, object: DataObject, dt: Float, ground solidGround: Bool) {
        guard let model, let root = model.part(id: body.rootID) else {
            bodies[body.humanoid] = nil
            return
        }
        // Moved by a script since last frame (PivotTo, the root's Position): from there.
        if let placed = body.placed, simd_distance(root.position, placed.position) > 0.01
            || abs(abs(simd_dot(root.orientation.vector, placed.orientation.vector)) - 1) > 1e-4 {
            let forward = root.orientation.act(Vec3(0, 0, -1))
            body.controller.position = root.position - Vec3(0, body.hip, 0)
            body.controller.facingYaw = atan2(-forward.x, -forward.z)
            body.controller.velocity = .zero
            body.lastPut = nil
        }

        var intent = CharacterIntent()
        intent.walkSpeed = Float(object.walkSpeed)
        intent.jumpVelocity = Float(object.jumpPower)
        intent.autoRotate = object.autoRotate
        intent.jump = body.jump
        body.jump = false
        if let target = body.target {
            let across = SIMD2(target.x - body.controller.position.x, target.z - body.controller.position.z)
            if simd_length(across) <= Self.arrival {
                finish(&body, reached: true)
            } else if clock - body.targetSince >= Self.moveTimeout {
                finish(&body, reached: false)
            } else {
                intent.direction = Vec3(across.x, 0, across.y) / simd_length(across)
            }
        } else {
            intent.direction = body.direction
        }

        // It meets everything solid but itself.
        let own = Set(body.rest.map(\.part))
        body.controller.solidBaseplate = solidGround
        body.controller.step(dt: dt, intent: intent, parts: model.parts.filter { !own.contains($0.id) })
        if body.controller.position.y < CharacterController.voidHeight {
            model.updateDataObject(id: body.humanoid) { $0.health = 0 }
            return
        }
        place(&body)
    }

    private func finish(_ body: inout Body, reached: Bool) {
        body.target = nil
        events.append(.list([.string("NPC"), .string(body.humanoid.uuidString), .string("MoveToFinished"), .bool(reached)]))
    }

    /// The Model where the body is: the root upright at the body's facing, each part as
    /// it was round it, the arms and legs swinging with the stride.
    private func place(_ body: inout Body) {
        guard let model else { return }
        let now = SIMD4(body.controller.position, body.controller.facingYaw + body.controller.walkPhase * 7.31)
        if let last = body.lastPut, simd_distance(last, now) < 1e-4 { return }
        body.lastPut = now
        let yaw = simd_quatf(angle: body.controller.facingYaw, axis: Vec3(0, 1, 0))
        let rootPose = Pose(position: body.controller.position + Vec3(0, body.hip, 0), orientation: yaw)
        let speed = min(body.controller.horizontalSpeed / max(CharacterController.walkSpeed, 1), 1)
        let swing = sin(body.controller.walkPhase * 1.6) * 0.8 * speed
        for (id, rest, limb) in body.rest {
            var pose = rest
            if let limb, let part = model.part(id: id) {
                // About the top of the limb (shoulder or hip), across the body.
                let angle: Float
                switch limb {
                case .leftArm, .rightLeg: angle = swing
                case .rightArm, .leftLeg: angle = -swing
                }
                let turn = simd_quatf(angle: angle, axis: Vec3(1, 0, 0))
                let joint = rest.position + rest.orientation.act(Vec3(0, part.size.y / 2, 0))
                pose = Pose(position: joint + turn.act(rest.position - joint), orientation: simd_normalize(turn * rest.orientation))
            }
            let placed = rootPose.applying(pose)
            model.update(id: id) { $0.pose = placed }
            if id == body.rootID { body.placed = placed }
        }
    }

    /// Dead: the Model's parts let go, to fall where they will.
    private func fallApart(_ body: Body) {
        guard let model else { return }
        for id in model.partIDs(inSubtree: body.modelID) {
            model.update(id: id) { $0.anchored = false }
        }
    }
}
