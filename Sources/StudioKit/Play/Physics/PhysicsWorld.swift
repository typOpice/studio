import Foundation
import simd
import CJolt

/// Rigid-body physics during play, simulated by Jolt Physics.
///
/// Parts become bodies. Parts welded together (`WeldConstraint`) become one body — an
/// *assembly*, as in Roblox — anchored if any of its parts is. Hinges, ball sockets,
/// ropes, springs and sliders join assemblies through their attachments.
///
/// Each frame `PlayController` calls `sync` with the scene (so scripts can add, move,
/// anchor, weld and resize freely), `step`s, and writes the moved parts back. This
/// class is the only Swift that talks to Jolt, through `CJolt`'s C wrapper.
final class PhysicsWorld {

    /// Welded parts moving as one body.
    struct Assembly {
        let handle: UInt32
        /// Every part, with its pose in the body's frame.
        var members: [(id: UUID, local: Pose)]
        /// The parts whose shapes the body collides with, in the order Jolt numbers them.
        var colliders: [UUID]
        var isStatic: Bool
        var mass: Float
        /// What it was built from; a different one means rebuild.
        var fingerprint: Int
    }

    /// What scripts and tests read about a part's motion.
    struct Motion {
        var velocity: Vec3
        var angularVelocity: Vec3
        var sleeping: Bool
        /// The part's own mass, and its whole assembly's.
        var mass: Float
        var assemblyMass: Float
        var isStatic: Bool
    }

    private struct JointRecord {
        let handle: UInt32
        let fingerprint: Int
        let bodies: (UInt32, UInt32)
    }

    private let world: OpaquePointer
    private var assemblies: [UInt32: Assembly] = [:]
    private var assemblyOf: [UUID: UInt32] = [:]
    private var written: [UUID: Pose] = [:]
    private var partMass: [UUID: Float] = [:]
    private var joints: [UUID: JointRecord] = [:]
    private var recentlyAwake: Set<UInt32> = []
    private var accumulator: Float = 0
    private var touchCounts: [[UUID]: Int] = [:]

    var gravity: Float = CharacterController.gravity {
        didSet { studio_jolt_set_gravity(world, -gravity) }
    }

    /// The invisible floor at y = 0 the character also stands on.
    var groundPlane = true {
        didSet { studio_jolt_set_ground(world, groundPlane ? 1 : 0) }
    }

    /// Fixed steps, each split in two for collision: 1/240 s effective.
    static let timeStep: Float = 1.0 / 120
    static let collisionSteps: Int32 = 2
    static let maxSteps = 8
    /// Roblox's FallenPartsDestroyHeight.
    static let destroyHeight: Float = -500

    init(capacity: Int = 4096) {
        world = studio_jolt_create(UInt32(capacity))
        studio_jolt_set_gravity(world, -gravity)
        studio_jolt_set_ground(world, 1)
    }

    deinit {
        studio_jolt_destroy(world)
    }

    /// One entry per assembly.
    var bodies: [Assembly] { Array(assemblies.values) }

    /// Pairs of parts touching (at least one of them unanchored), for part-to-part Touched.
    var touchingPairs: Set<[UUID]> { Set(touchCounts.keys) }

    /// Values as plain Float arrays, which C can read three or four at a time. (A
    /// pointer to one SIMD lane isn't guaranteed to lead on to the next.)
    static func floats(_ v: Vec3) -> [Float] { [v.x, v.y, v.z] }
    static func floats(_ q: simd_quatf) -> [Float] { [q.vector.x, q.vector.y, q.vector.z, q.vector.w] }

    // MARK: - Materials, mass and shapes

    static func density(_ material: PartMaterial) -> Float {
        switch material {
        case .plastic, .smooth, .neon: return 0.7
        case .metal: return 7.85
        case .wood: return 0.35
        case .water: return 1
        }
    }

    static func friction(_ material: PartMaterial) -> Float {
        switch material {
        case .plastic: return 0.4
        case .smooth: return 0.2
        case .metal: return 0.4
        case .wood: return 0.48
        case .neon: return 0.3
        case .water: return 0.05
        }
    }

    static func restitution(_ material: PartMaterial) -> Float {
        switch material {
        case .metal, .wood: return 0.2
        default: return 0.25
        }
    }

    /// Mass from shape, size and material, as Roblox works it out (density × volume).
    static func massProperties(of part: Part) -> (mass: Float, volume: Float) {
        let s = simd_max(part.size, Vec3(repeating: 0.05))
        var volume: Float
        switch part.shape {
        case .block, .truss: volume = s.x * s.y * s.z
        case .sphere: volume = 4.0 / 3.0 * .pi * (s.x / 2) * (s.y / 2) * (s.z / 2)
        case .cylinder: volume = .pi * (s.x / 2) * (s.z / 2) * s.y
        case .wedge: volume = s.x * s.y * s.z / 2
        }
        // A MeshPart weighs what its outline holds (its box, collided as one).
        if let mesh = part.mesh, let geometry = MeshLibrary.shared.geometry(for: part) {
            volume = mesh.collisionFidelity == .box ? s.x * s.y * s.z : geometry.hullVolume * s.x * s.y * s.z
        }
        return (max(volume * density(part.material), 0.01), volume)
    }

    /// The shape Jolt collides for a part. Round shapes stay exact while they're round;
    /// a squashed sphere (an ellipsoid) or cylinder (an elliptical one) becomes a
    /// convex hull of its real surface.
    static func shape(of part: Part, still: Bool = true)
        -> (kind: Int32, params: [Float], points: [Float], triangles: [UInt32]) {
        let h = part.size * 0.5
        func uniform(_ a: Float, _ b: Float) -> Bool { abs(a - b) <= max(a, b) * 0.01 }
        // A MeshPart: its box, its hull, or — held still — its exact triangles.
        if let mesh = part.mesh, let geometry = MeshLibrary.shared.geometry(for: part) {
            let s = simd_max(part.size, Vec3(repeating: 0.05))
            switch mesh.collisionFidelity {
            case .box:
                return (Int32(STUDIO_JOLT_BOX.rawValue), [h.x, h.y, h.z], [], [])
            case .precise where still:
                return (Int32(STUDIO_JOLT_HULL.rawValue), [], geometry.positions.flatMap { v in let p = v * s; return [p.x, p.y, p.z] },
                        geometry.indices)
            case .hull, .precise:
                return (Int32(STUDIO_JOLT_HULL.rawValue), [],
                        geometry.hull.vertices.flatMap { v in let p = v * s; return [p.x, p.y, p.z] }, [])
            }
        }
        switch part.shape {
        case .block, .truss:
            return (Int32(STUDIO_JOLT_BOX.rawValue), [h.x, h.y, h.z], [], [])
        case .sphere where uniform(h.x, h.y) && uniform(h.y, h.z):
            return (Int32(STUDIO_JOLT_SPHERE.rawValue), [(h.x + h.y + h.z) / 3], [], [])
        case .sphere:
            var points: [Float] = [0, h.y, 0, 0, -h.y, 0]
            let stacks = 8, slices = 16
            for i in 1..<stacks {
                let phi = Float(i) / Float(stacks) * .pi
                for j in 0..<slices {
                    let theta = Float(j) / Float(slices) * 2 * .pi
                    points += [sin(phi) * cos(theta) * h.x, cos(phi) * h.y, sin(phi) * sin(theta) * h.z]
                }
            }
            return (Int32(STUDIO_JOLT_HULL.rawValue), [], points, [])
        case .cylinder where uniform(h.x, h.z):
            return (Int32(STUDIO_JOLT_CYLINDER.rawValue), [h.y, (h.x + h.z) / 2], [], [])
        case .cylinder:
            var points: [Float] = []
            for i in 0..<24 {
                let t = Float(i) / 24 * 2 * .pi
                points += [cos(t) * h.x, -h.y, sin(t) * h.z, cos(t) * h.x, h.y, sin(t) * h.z]
            }
            return (Int32(STUDIO_JOLT_HULL.rawValue), [], points, [])
        case .wedge:
            // Full height at −Z, sloping to nothing at +Z, as the renderer draws it.
            var points: [Float] = []
            for x in [-h.x, h.x] { points += [x, -h.y, -h.z, x, -h.y, h.z, x, h.y, -h.z] }
            return (Int32(STUDIO_JOLT_HULL.rawValue), [], points, [])
        }
    }

    // MARK: - Keeping up with the scene

    /// Brings the bodies and joints in line with the scene: parts join and leave, welds
    /// merge them into assemblies, anchoring and resizing take effect, a part a script
    /// has moved is teleported (with its assembly), and joints follow their attachments.
    func sync(_ parts: [Part], constraints: [SceneConstraint] = [], attachments: [SceneAttachment] = []) {
        let visible = Dictionary(uniqueKeysWithValues: parts.filter(\.inWorld).map { ($0.id, $0) })

        // Which parts are welded together: union-find over the enabled welds.
        var leader: [UUID: UUID] = [:]
        func find(_ id: UUID) -> UUID {
            var root = id
            while let next = leader[root], next != root { root = next }
            var node = id
            while let next = leader[node], next != root { leader[node] = root; node = next }
            return root
        }
        for id in visible.keys { leader[id] = id }
        for weld in constraints where weld.kind == .weld && weld.enabled {
            guard let a = weld.part0, let b = weld.part1, visible[a] != nil, visible[b] != nil else { continue }
            let (ra, rb) = (find(a), find(b))
            guard ra != rb else { continue }
            if ra.uuidString < rb.uuidString { leader[rb] = ra } else { leader[ra] = rb }
        }
        var groups: [UUID: [UUID]] = [:]
        for id in visible.keys { groups[find(id), default: []].append(id) }

        var keep: Set<UInt32> = []
        var changed = false
        for (_, unsorted) in groups {
            let ids = unsorted.sorted { $0.uuidString < $1.uuidString }
            let members = ids.map { visible[$0]! }
            var hasher = Hasher()
            for part in members {
                hasher.combine(part.id)
                hasher.combine(part.shape)
                hasher.combine(part.size.x); hasher.combine(part.size.y); hasher.combine(part.size.z)
                hasher.combine(part.material)
                hasher.combine(part.anchored)
                hasher.combine(part.isSolid)
                // A MeshPart's model, how it collides, and whether that model has loaded.
                hasher.combine(part.mesh?.asset)
                hasher.combine(part.mesh?.collisionFidelity)
                hasher.combine(MeshLibrary.shared.geometry(for: part) != nil)
            }
            let fingerprint = hasher.finalize()

            if let handle = assemblyOf[ids[0]], var assembly = assemblies[handle], assembly.fingerprint == fingerprint,
               assembly.members.count == ids.count, ids.allSatisfy({ assemblyOf[$0] == handle }) {
                // Same assembly. Did a script move one of its parts?
                if let moved = members.first(where: { written[$0.id] != $0.pose }),
                   let local = assembly.members.first(where: { $0.id == moved.id })?.local {
                    let body = moved.pose.applying(local.inverse)
                    studio_jolt_set_pose(world, handle, Self.floats(body.position), Self.floats(body.orientation))
                    for member in assembly.members { written[member.id] = body.applying(member.local) }
                    if assembly.isStatic { changed = true } else { studio_jolt_wake(world, handle) }
                }
                assembly.fingerprint = fingerprint
                assemblies[handle] = assembly
                keep.insert(handle)
                continue
            }

            // New, or rebuilt: keep an unanchored assembly's motion across the rebuild.
            let previous = ids.compactMap { assemblyOf[$0] }.first.flatMap { assemblies[$0] }
            let carried = previous.flatMap { old -> (Vec3, Vec3)? in
                guard !old.isStatic, let motion = motion(ofHandle: old.handle) else { return nil }
                return (motion.velocity, motion.angularVelocity)
            }
            if let handle = add(members, fingerprint: fingerprint) {
                keep.insert(handle)
                if let (v, w) = carried, assemblies[handle]?.isStatic == false {
                    studio_jolt_set_velocity(world, handle, Self.floats(v))
                    studio_jolt_set_angular_velocity(world, handle, Self.floats(w))
                }
            }
            changed = true
        }

        for handle in assemblies.keys where !keep.contains(handle) {
            remove(handle)
            changed = true
        }
        for id in written.keys where visible[id] == nil { written.removeValue(forKey: id) }
        syncJoints(constraints, attachments: attachments, parts: visible)
        if changed { wakeAll() }
    }

    private func add(_ members: [Part], fingerprint: Int) -> UInt32? {
        // The body sits where its anchored part (or its heaviest) is.
        let root = members.first(where: \.anchored)
            ?? members.max { Self.massProperties(of: $0).mass < Self.massProperties(of: $1).mass }!
        let frame = root.pose
        let isStatic = members.contains(where: \.anchored)
        // Water is something to swim in, not to land on.
        var colliders = members.filter { $0.canCollide && $0.material != .water }
        let ghost = colliders.isEmpty
        if ghost { colliders = members }

        var shapes: [UInt32] = []
        var positions: [Float] = []
        var rotations: [Float] = []
        var built: [UUID] = []
        for part in colliders {
            let shape = Self.shape(of: part, still: isStatic)
            let id: UInt32
            if !shape.triangles.isEmpty {
                // A still MeshPart with Precise collision: exactly its triangles.
                id = shape.points.withUnsafeBufferPointer { v in
                    shape.triangles.withUnsafeBufferPointer { t in
                        studio_jolt_make_mesh_shape(world, v.baseAddress, Int32(v.count / 3), t.baseAddress,
                                                    Int32(t.count / 3))
                    }
                }
            } else {
                id = shape.params.withUnsafeBufferPointer { p in
                    shape.points.withUnsafeBufferPointer { q in
                        studio_jolt_make_shape(world, shape.kind, p.baseAddress, Int32(p.count), q.baseAddress, Int32(q.count / 3))
                    }
                }
            }
            guard id != STUDIO_JOLT_NO_BODY else { continue }
            let local = frame.inverse.applying(part.pose)
            shapes.append(id)
            positions += Self.floats(local.position)
            rotations += Self.floats(local.orientation)
            built.append(part.id)
        }
        guard !shapes.isEmpty else { return nil }

        let masses = members.map { Self.massProperties(of: $0).mass }
        let mass = masses.reduce(0, +)
        let friction = zip(members, masses).map { Self.friction($0.material) * $1 }.reduce(0, +) / mass
        let restitution = members.map { Self.restitution($0.material) }.min() ?? 0.25
        // Anything these parts were in before goes first (its joints with it).
        for part in members {
            if let old = assemblyOf[part.id], assemblies[old] != nil { remove(old) }
        }
        let handle = studio_jolt_add_compound(world, shapes, positions, rotations, Int32(shapes.count),
                                              Self.floats(frame.position), Self.floats(frame.orientation),
                                              Int32(isStatic ? STUDIO_JOLT_STATIC.rawValue : STUDIO_JOLT_DYNAMIC.rawValue),
                                              mass, friction, restitution, ghost ? 0 : 1)
        guard handle != STUDIO_JOLT_NO_BODY else { return nil }

        assemblies[handle] = Assembly(handle: handle,
                                      members: members.map { ($0.id, frame.inverse.applying($0.pose)) },
                                      colliders: built, isStatic: isStatic, mass: mass, fingerprint: fingerprint)
        for (part, m) in zip(members, masses) {
            assemblyOf[part.id] = handle
            written[part.id] = part.pose
            partMass[part.id] = m
        }
        return handle
    }

    private func remove(_ handle: UInt32) {
        guard let assembly = assemblies.removeValue(forKey: handle) else { return }
        // Jolt drops the body's joints with it; forget them here too.
        for (id, joint) in joints where joint.bodies.0 == handle || joint.bodies.1 == handle {
            joints.removeValue(forKey: id)
        }
        studio_jolt_remove_body(world, handle)
        recentlyAwake.remove(handle)
        for member in assembly.members where assemblyOf[member.id] == handle {
            assemblyOf.removeValue(forKey: member.id)
            partMass.removeValue(forKey: member.id)
        }
        let gone = Set(assembly.members.map(\.id))
        touchCounts = touchCounts.filter { !$0.key.contains(where: gone.contains) }
    }

    func wakeAll() {
        for assembly in assemblies.values where !assembly.isStatic { studio_jolt_wake(world, assembly.handle) }
    }

    // MARK: - Joints

    /// Builds, rebuilds and removes Jolt joints to match the scene's, and drives motors.
    private func syncJoints(_ constraints: [SceneConstraint], attachments: [SceneAttachment], parts: [UUID: Part]) {
        let byID = Dictionary(uniqueKeysWithValues: attachments.map { ($0.id, $0) })
        var live: Set<UUID> = []
        for constraint in constraints where constraint.kind != .weld && constraint.enabled {
            guard let a0 = constraint.attachment0.flatMap({ byID[$0] }), let a1 = constraint.attachment1.flatMap({ byID[$0] }),
                  let p0 = parts[a0.parentID], let p1 = parts[a1.parentID],
                  let b0 = assemblyOf[p0.id], let b1 = assemblyOf[p1.id], b0 != b1,
                  !(assemblies[b0]?.isStatic == true && assemblies[b1]?.isStatic == true) else { continue }

            var hasher = Hasher()
            hasher.combine(constraint.kind)
            hasher.combine(b0); hasher.combine(b1)
            for a in [a0, a1] {
                hasher.combine(a.position.x); hasher.combine(a.position.y); hasher.combine(a.position.z)
                hasher.combine(a.axis.x); hasher.combine(a.axis.y); hasher.combine(a.axis.z)
            }
            hasher.combine(constraint.limitsEnabled)
            hasher.combine(constraint.lowerAngle); hasher.combine(constraint.upperAngle)
            hasher.combine(constraint.lowerLimit); hasher.combine(constraint.upperLimit)
            hasher.combine(constraint.length); hasher.combine(constraint.freeLength)
            hasher.combine(constraint.stiffness); hasher.combine(constraint.damping)
            let fingerprint = hasher.finalize()
            live.insert(constraint.id)

            if let existing = joints[constraint.id], existing.fingerprint != fingerprint {
                studio_jolt_remove_joint(world, existing.handle)
                joints.removeValue(forKey: constraint.id)
            }
            if joints[constraint.id] == nil {
                // Built from where the attachments are in the world right now.
                func frame(_ a: SceneAttachment, _ p: Part) -> (Vec3, Vec3, Vec3) {
                    (p.position + p.orientation.act(a.position), p.orientation.act(a.axis), p.orientation.act(a.secondaryAxis))
                }
                let (pointA, axisA, normalA) = frame(a0, p0)
                let (pointB, axisB, normalB) = frame(a1, p1)
                let kind: StudioJoltJoint
                var values: [Float] = []
                switch constraint.kind {
                case .hinge:
                    kind = STUDIO_JOLT_HINGE
                    values = [constraint.limitsEnabled ? 1 : 0, constraint.lowerAngle * .pi / 180, constraint.upperAngle * .pi / 180]
                case .ballSocket:
                    kind = STUDIO_JOLT_POINT
                case .rope:
                    kind = STUDIO_JOLT_ROPE
                    values = [constraint.length]
                case .spring:
                    kind = STUDIO_JOLT_SPRING
                    values = [constraint.freeLength, constraint.stiffness, constraint.damping]
                case .prismatic:
                    kind = STUDIO_JOLT_SLIDER
                    values = [constraint.limitsEnabled ? 1 : 0, constraint.lowerLimit, constraint.upperLimit]
                case .weld:
                    continue
                }
                // Parts joined at a point shouldn't grind against each other.
                let noCollide: Int32 = [.hinge, .ballSocket, .prismatic].contains(constraint.kind) ? 1 : 0
                let handle = values.withUnsafeBufferPointer { v in
                    studio_jolt_add_joint(world, Int32(kind.rawValue), b0, b1,
                                          Self.floats(pointA), Self.floats(pointB),
                                          Self.floats(axisA), Self.floats(axisB),
                                          Self.floats(normalA), Self.floats(normalB),
                                          v.baseAddress, Int32(v.count), noCollide)
                }
                guard handle != STUDIO_JOLT_NO_BODY else { continue }
                joints[constraint.id] = JointRecord(handle: handle, fingerprint: fingerprint, bodies: (b0, b1))
            }

            // Motors every frame: cheap, and scripts may change them at any time.
            guard let joint = joints[constraint.id] else { continue }
            let current = studio_jolt_joint_value(world, joint.handle)
            switch (constraint.kind, constraint.actuator) {
            case (.hinge, .motor):
                studio_jolt_drive_joint(world, joint.handle, 1, constraint.angularVelocity, constraint.motorMaxTorque)
            case (.hinge, .servo):
                // Towards the target angle, never faster than AngularSpeed.
                let error = constraint.targetAngle * .pi / 180 - current
                let speed = min(max(error * 8, -constraint.angularSpeed), constraint.angularSpeed)
                studio_jolt_drive_joint(world, joint.handle, 1, speed, constraint.servoMaxTorque)
            case (.prismatic, .motor):
                studio_jolt_drive_joint(world, joint.handle, 1, constraint.velocity, constraint.motorMaxForce)
            case (.prismatic, .servo):
                let error = constraint.targetPosition - current
                let speed = min(max(error * 8, -constraint.speed), constraint.speed)
                studio_jolt_drive_joint(world, joint.handle, 1, speed, constraint.servoMaxForce)
            case (.hinge, .none), (.prismatic, .none):
                studio_jolt_drive_joint(world, joint.handle, 0, 0, 0)
            default:
                break
            }
        }
        for (id, joint) in joints where !live.contains(id) {
            studio_jolt_remove_joint(world, joint.handle)
            joints.removeValue(forKey: id)
        }
    }

    /// A hinge's angle (radians) or a slider's position (studs), as simulated.
    func jointValue(_ constraintID: UUID) -> Float? {
        guard let joint = joints[constraintID] else { return nil }
        return studio_jolt_joint_value(world, joint.handle)
    }

    var jointCount: Int { joints.count }

    // MARK: - The player

    /// Each character's capsule and where it last was: 0 is this machine's player, the
    /// others are players in a network game, by their number.
    private var characters: [Int: (handle: UInt32, centre: Vec3)] = [:]

    /// Moves a player's capsule to where their character now stands, over `dt`, so
    /// falling parts land on them and parts shoved at them stop. (This machine's player
    /// shoves parts through `push`, which weighs them.)
    func moveCharacter(_ player: Int = 0, feet: Vec3, radius: Float, height: Float, dt: Float, placed: Bool = false) {
        let centre = feet + Vec3(0, height / 2, 0)
        let rotation = Self.floats(simd_quatf(angle: 0, axis: Vec3(0, 1, 0)))
        if let existing = characters[player] {
            // A teleport (a respawn, a script moving the root) is placed, not swept —
            // sweeping it would fling everything in between.
            if placed || simd_distance(existing.centre, centre) > 8 {
                studio_jolt_set_pose(world, existing.handle, Self.floats(centre), rotation)
            } else {
                studio_jolt_move_kinematic(world, existing.handle, Self.floats(centre), rotation, dt)
            }
            characters[player] = (existing.handle, centre)
            return
        }
        let params: [Float] = [max(height / 2 - radius, 0.01), radius]
        let handle = params.withUnsafeBufferPointer { p in
            studio_jolt_add_body(world, Int32(STUDIO_JOLT_CAPSULE.rawValue), p.baseAddress, 2, nil, 0,
                                 Self.floats(centre), rotation, Int32(STUDIO_JOLT_KINEMATIC.rawValue),
                                 0, 0, 0, 1)
        }
        if handle != STUDIO_JOLT_NO_BODY { characters[player] = (handle, centre) }
    }

    /// Takes a player's capsule away — a dead character lies down, so it should stop
    /// holding anything up; `moveCharacter` brings it back for the next one. Everything
    /// is woken first: Jolt leaves a sleeping body where it is when what it rested on
    /// goes, so a crate on the player's head would stay put in mid-air.
    func removeCharacter(_ player: Int = 0) {
        guard let existing = characters.removeValue(forKey: player) else { return }
        for assembly in assemblies.values where !assembly.isStatic {
            studio_jolt_wake(world, assembly.handle)
        }
        studio_jolt_remove_body(world, existing.handle)
    }

    /// Takes away the capsules of every player not in `players` — those who left.
    func removeCharacters(notIn players: Set<Int>) {
        for player in characters.keys where !players.contains(player) { removeCharacter(player) }
    }

    /// Which players have a capsule, for the tests.
    var characterIDs: Set<Int> { Set(characters.keys) }

    /// A walking character shoving a part: its assembly picks up the character's pace
    /// along the push, less the heavier it is — a crate slides, a metal block barely moves.
    func push(_ id: UUID, along direction: Vec3, speed: Float, characterMass: Float = 25) {
        guard speed > 0, let motion = motion(of: id), !motion.isStatic else { return }
        let share = min(characterMass / (characterMass + motion.assemblyMass) * 1.5, 1)
        let target = speed * share
        let current = dot(motion.velocity, direction)
        guard current < target else { return }
        setVelocity(id, motion.velocity + direction * (target - current))
    }

    // MARK: - Scripts (a part's assembly is what moves)

    func body(for id: UUID) -> Motion? { motion(of: id) }

    func motion(of id: UUID) -> Motion? {
        guard let handle = assemblyOf[id], var motion = motion(ofHandle: handle) else { return nil }
        motion.mass = partMass[id] ?? motion.assemblyMass
        return motion
    }

    private func motion(ofHandle handle: UInt32) -> Motion? {
        guard let assembly = assemblies[handle] else { return nil }
        var velocity = [Float](repeating: 0, count: 3), angular = [Float](repeating: 0, count: 3)
        if !assembly.isStatic {
            studio_jolt_get_velocity(world, handle, &velocity)
            studio_jolt_get_angular_velocity(world, handle, &angular)
        }
        return Motion(velocity: Vec3(velocity[0], velocity[1], velocity[2]),
                      angularVelocity: Vec3(angular[0], angular[1], angular[2]),
                      sleeping: assembly.isStatic || studio_jolt_is_awake(world, handle) == 0,
                      mass: assembly.mass, assemblyMass: assembly.mass, isStatic: assembly.isStatic)
    }

    private func dynamicHandle(_ id: UUID) -> UInt32? {
        guard let handle = assemblyOf[id], let assembly = assemblies[handle], !assembly.isStatic else { return nil }
        return handle
    }

    func setVelocity(_ id: UUID, _ velocity: Vec3) {
        guard let handle = dynamicHandle(id) else { return }
        studio_jolt_set_velocity(world, handle, Self.floats(velocity))
    }

    func setAngularVelocity(_ id: UUID, _ velocity: Vec3) {
        guard let handle = dynamicHandle(id) else { return }
        studio_jolt_set_angular_velocity(world, handle, Self.floats(velocity))
    }

    func applyImpulse(_ id: UUID, _ impulse: Vec3) {
        guard let handle = dynamicHandle(id) else { return }
        studio_jolt_add_impulse(world, handle, Self.floats(impulse))
    }

    func applyAngularImpulse(_ id: UUID, _ impulse: Vec3) {
        guard let handle = dynamicHandle(id) else { return }
        studio_jolt_add_angular_impulse(world, handle, Self.floats(impulse))
    }

    /// The parts welded into the same assembly as this one.
    func assemblyParts(of id: UUID) -> [UUID] {
        guard let handle = assemblyOf[id] else { return [] }
        return assemblies[handle]?.members.map(\.id) ?? []
    }

    // MARK: - Stepping

    /// Advances by `dt` in fixed steps. Returns the parts that moved (their new poses)
    /// and those that fell out of the world.
    func step(dt: Float) -> (moved: [(UUID, Pose)], fallen: [UUID]) {
        accumulator += min(max(dt, 0), 0.1)
        var steps = 0
        while accumulator >= Self.timeStep && steps < Self.maxSteps {
            studio_jolt_step(world, Self.timeStep, Self.collisionSteps)
            accumulator -= Self.timeStep
            steps += 1
        }
        if steps == Self.maxSteps { accumulator = 0 }
        collectContacts()

        // Everything awake now, and whatever fell asleep since last time. The players'
        // capsules are awake bodies too, so ask again with room for all if it overflows —
        // a part left off the list would never have its movement read back.
        var awake = [UInt32](repeating: 0, count: assemblies.count + characters.count + 1)
        var count = Int(studio_jolt_awake_bodies(world, &awake, Int32(awake.count)))
        if count > awake.count {
            awake = [UInt32](repeating: 0, count: count)
            count = Int(studio_jolt_awake_bodies(world, &awake, Int32(awake.count)))
        }
        let awakeNow = Set(awake.prefix(min(count, awake.count)))
        let candidates = awakeNow.union(recentlyAwake)
        recentlyAwake = awakeNow

        var moved: [(UUID, Pose)] = []
        var fallen: [UUID] = []
        for handle in candidates {
            guard let assembly = assemblies[handle], !assembly.isStatic else { continue }
            var p = [Float](repeating: 0, count: 3)
            var q: [Float] = [0, 0, 0, 1]
            studio_jolt_get_pose(world, handle, &p, &q)
            let body = Pose(position: Vec3(p[0], p[1], p[2]), orientation: simd_quatf(vector: SIMD4(q[0], q[1], q[2], q[3])))
            if body.position.y < Self.destroyHeight {
                fallen += assembly.members.map(\.id)
                continue
            }
            for member in assembly.members {
                let pose = body.applying(member.local)
                if pose != written[member.id] {
                    written[member.id] = pose
                    moved.append((member.id, pose))
                }
            }
        }
        return (moved, fallen)
    }

    /// Keeps count of contacts per pair of parts: Jolt reports each start and stop,
    /// naming the shape within an assembly that touched.
    private func collectContacts() {
        let capacity = 16_384
        var events = [UInt32](repeating: 0, count: 5 * capacity)
        let pairs = min(Int(studio_jolt_drain_contacts(world, &events, Int32(capacity))), capacity)
        func part(_ handle: UInt32, _ child: UInt32) -> UUID? {
            guard let assembly = assemblies[handle], Int(child) < assembly.colliders.count else { return nil }
            return assembly.colliders[Int(child)]
        }
        for i in 0..<pairs {
            let e = i * 5
            guard let a = part(events[e], events[e + 1]), let b = part(events[e + 2], events[e + 3]) else { continue }
            let key = [a, b].sorted { $0.uuidString < $1.uuidString }
            if events[e + 4] == 1 {
                touchCounts[key, default: 0] += 1
            } else if let n = touchCounts[key] {
                touchCounts[key] = n > 1 ? n - 1 : nil
            }
        }
    }
}
