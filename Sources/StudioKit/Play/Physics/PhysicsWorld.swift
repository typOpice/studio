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
    /// NoCollisionConstraints' pairs of bodies, as last told to Jolt.
    private var ignoredPairs: [UUID: (UInt32, UInt32)] = [:]
    /// AlignPositions and VectorForces, worked out at each sync and applied each step.
    private var forces: [ForceRecord] = []
    /// Each AlignOrientation's spin as its last impulse left it: what friction (or anything
    /// else) took off by the next step is made good then.
    private var aimedSpin: [UUID: Vec3] = [:]
    /// Motor6Ds between two bodies: the Jolt joint, the settings, and the angle it's at.
    private var motors: [UUID: MotorRecord] = [:]

    private struct MotorRecord {
        let handle: UInt32
        let fingerprint: Int
        var constraint: SceneConstraint
        /// CurrentAngle as it goes, and how many times a script had set it when last looked.
        var angle: Float
        var writes: Int
    }

    /// A push on a body: what the constraint says, and where its ends are on bodies (or
    /// fixed in the world).
    private struct ForceRecord {
        let constraint: SceneConstraint
        let body: UInt32
        /// Attachment0 in its body's frame, and its axes (for RelativeTo Attachment0).
        let point: Vec3
        let frame0: simd_quatf
        /// Attachment1: on a body, in its frame; or where it is, if its part isn't simulated.
        let target: (body: UInt32?, point: Vec3, frame: simd_quatf)?
    }
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
        for (id, pair) in ignoredPairs where pair.0 == handle || pair.1 == handle {
            studio_jolt_ignore_pair(world, pair.0, pair.1, 0)
            ignoredPairs.removeValue(forKey: id)
        }
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
        syncNoCollisions(constraints, parts: parts)
        syncForces(constraints, attachments: byID, parts: parts)
        syncMotors(constraints, parts: parts)
        for constraint in constraints where constraint.kind.isJoint && constraint.enabled {
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
                case .weld, .beam, .trail, .alignPosition, .vectorForce, .noCollision, .alignOrientation, .torque, .motor6d:
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

    // MARK: - NoCollisionConstraints

    /// Each enabled one between parts of two different bodies: that pair ignored.
    private func syncNoCollisions(_ constraints: [SceneConstraint], parts: [UUID: Part]) {
        var live: [UUID: (UInt32, UInt32)] = [:]
        for constraint in constraints where constraint.kind == .noCollision && constraint.enabled {
            guard let a = constraint.part0, let b = constraint.part1, parts[a] != nil, parts[b] != nil,
                  let b0 = assemblyOf[a], let b1 = assemblyOf[b], b0 != b1 else { continue }
            live[constraint.id] = (b0, b1)
        }
        for (id, pair) in ignoredPairs where live[id].map({ $0 != pair }) ?? true {
            studio_jolt_ignore_pair(world, pair.0, pair.1, 0)
            ignoredPairs.removeValue(forKey: id)
        }
        for (id, pair) in live where ignoredPairs[id] == nil {
            studio_jolt_ignore_pair(world, pair.0, pair.1, 1)
            ignoredPairs[id] = pair
        }
    }

    // MARK: - Motor6D

    /// Each enabled one between parts of two bodies, not both anchored: a Jolt joint held
    /// at Part0 · C0 · Transform · (CurrentAngle about Z) against Part1 · C1.
    private func syncMotors(_ constraints: [SceneConstraint], parts: [UUID: Part]) {
        var live: Set<UUID> = []
        for c in constraints where c.kind == .motor6d && c.enabled {
            guard let a = c.part0, let b = c.part1, let p0 = parts[a], let p1 = parts[b],
                  let b0 = assemblyOf[a], let b1 = assemblyOf[b], b0 != b1,
                  !(assemblies[b0]?.isStatic == true && assemblies[b1]?.isStatic == true) else { continue }
            var hasher = Hasher()
            hasher.combine(b0); hasher.combine(b1)
            for value in c.c0.components + c.c1.components { hasher.combine(value) }
            let fingerprint = hasher.finalize()
            live.insert(c.id)
            let previous = motors[c.id]
            if let previous, previous.fingerprint != fingerprint {
                studio_jolt_remove_joint(world, previous.handle)
                motors.removeValue(forKey: c.id)
            }
            if motors[c.id] == nil {
                // Each end's frame where it is now: Jolt keeps each on its own body.
                let frameA = p0.pose.applying(c.c0), frameB = p1.pose.applying(c.c1)
                let x = Vec3(1, 0, 0), y = Vec3(0, 1, 0)
                let handle = studio_jolt_add_joint(world, Int32(STUDIO_JOLT_MOTOR.rawValue), b0, b1,
                                                   Self.floats(frameA.position), Self.floats(frameB.position),
                                                   Self.floats(frameA.orientation.act(x)), Self.floats(frameB.orientation.act(x)),
                                                   Self.floats(frameA.orientation.act(y)), Self.floats(frameB.orientation.act(y)),
                                                   nil, 0, 1)
                guard handle != STUDIO_JOLT_NO_BODY else { continue }
                motors[c.id] = MotorRecord(handle: handle, fingerprint: fingerprint, constraint: c,
                                           angle: previous?.angle ?? c.currentAngle, writes: c.angleWrites)
            }
            motors[c.id]?.constraint = c
            if let record = motors[c.id], record.writes != c.angleWrites {
                motors[c.id]?.angle = c.currentAngle
                motors[c.id]?.writes = c.angleWrites
            }
        }
        for (id, record) in motors where !live.contains(id) {
            studio_jolt_remove_joint(world, record.handle)
            motors.removeValue(forKey: id)
        }
    }

    /// Once a frame: each Motor6D's CurrentAngle a step nearer DesiredAngle (MaxVelocity
    /// radians a sixtieth of a second), and where it holds Part1 now.
    private func driveMotors(dt: Float) {
        for (id, var record) in motors {
            let c = record.constraint
            let most = max(c.maxVelocity, 0) * dt * 60
            let gap = c.desiredAngle - record.angle
            record.angle += most.isFinite ? min(max(gap, -most), most) : gap
            motors[id] = record
            let held = c.transform.applying(Pose(position: .zero, orientation: simd_quatf(angle: record.angle, axis: Vec3(0, 0, 1))))
            studio_jolt_drive_motor(world, record.handle, Self.floats(held.position), Self.floats(held.orientation))
        }
    }

    // MARK: - AlignPosition, VectorForce, AlignOrientation and Torque

    /// Where each enabled one's ends are, on which bodies; only those on a body that moves.
    private func syncForces(_ constraints: [SceneConstraint], attachments: [UUID: SceneAttachment], parts: [UUID: Part]) {
        forces = []
        defer {
            let kept = Set(forces.map(\.constraint.id))
            aimedSpin = aimedSpin.filter { kept.contains($0.key) }
        }
        for constraint in constraints where constraint.kind.isForce && constraint.enabled {
            guard let a0 = constraint.attachment0.flatMap({ attachments[$0] }), let p0 = parts[a0.parentID],
                  let body = assemblyOf[p0.id], let assembly = assemblies[body], !assembly.isStatic,
                  let local = assembly.members.first(where: { $0.id == p0.id })?.local else { continue }
            let point = local.position + local.orientation.act(a0.position)
            let frame0 = local.orientation * Self.frame(axis: a0.axis, secondary: a0.secondaryAxis)
            var target: (body: UInt32?, point: Vec3, frame: simd_quatf)?
            if let a1 = constraint.attachment1.flatMap({ attachments[$0] }), let p1 = parts[a1.parentID] {
                let frame1 = Self.frame(axis: a1.axis, secondary: a1.secondaryAxis)
                if let other = assemblyOf[p1.id], let otherAssembly = assemblies[other], !otherAssembly.isStatic,
                   let otherLocal = otherAssembly.members.first(where: { $0.id == p1.id })?.local {
                    target = (other, otherLocal.position + otherLocal.orientation.act(a1.position),
                              otherLocal.orientation * frame1)
                } else {
                    target = (nil, p1.position + p1.orientation.act(a1.position), p1.orientation * frame1)
                }
            }
            if constraint.kind == .alignPosition || constraint.kind == .alignOrientation,
               constraint.alignMode == .twoAttachment, target == nil { continue }
            forces.append(ForceRecord(constraint: constraint, body: body, point: point, frame0: frame0, target: target))
        }
    }

    /// An attachment's axes as a rotation: X along Axis, Y along SecondaryAxis.
    private static func frame(axis: Vec3, secondary: Vec3) -> simd_quatf {
        let x = simd_normalize(axis), y = simd_normalize(secondary), z = simd_cross(x, y)
        return simd_quatf(float3x3(x, y, z))
    }

    private func pose(of body: UInt32) -> Pose {
        var p = [Float](repeating: 0, count: 3)
        var q: [Float] = [0, 0, 0, 1]
        studio_jolt_get_pose(world, body, &p, &q)
        return Pose(position: Vec3(p[0], p[1], p[2]), orientation: simd_quatf(vector: SIMD4(q[0], q[1], q[2], q[3])))
    }

    /// Before each step: every VectorForce's push, and every AlignPosition's pull towards
    /// where it's going — the velocity it wants (Responsiveness × the gap, no more than
    /// MaxVelocity) got to as far as MaxForce allows in one step.
    private func applyForces(dt: Float) {
        for record in forces {
            let c = record.constraint, bodyPose = pose(of: record.body)
            let point = bodyPose.position + bodyPose.orientation.act(record.point)
            var impulse = Vec3.zero
            switch c.kind {
            case .vectorForce:
                var push = c.force
                switch c.relativeTo {
                case .world: break
                case .attachment0: push = (bodyPose.orientation * record.frame0).act(push)
                case .attachment1:
                    if let target = record.target {
                        let frame = target.body.map { pose(of: $0).orientation * target.frame } ?? target.frame
                        push = frame.act(push)
                    }
                }
                impulse = push * dt
            case .alignPosition:
                var goal = c.position
                if c.alignMode == .twoAttachment, let target = record.target {
                    goal = target.body.map { pose(of: $0).applying(Pose(position: target.point, orientation: target.frame)).position }
                        ?? target.point
                }
                var velocity = [Float](repeating: 0, count: 3)
                studio_jolt_get_velocity(world, record.body, &velocity)
                let current = Vec3(velocity[0], velocity[1], velocity[2])
                let gap = goal - point
                var wanted = c.rigidityEnabled ? gap / dt : gap * max(c.responsiveness, 0) * 0.35
                let most = c.maxVelocity.isFinite ? max(c.maxVelocity, 0) : Float.greatestFiniteMagnitude
                if simd_length(wanted) > most { wanted = simd_normalize(wanted) * most }
                let mass = studio_jolt_mass(world, record.body)
                // What getting there takes this step, gravity's pull made good.
                impulse = (wanted - current) * mass + Vec3(0, gravity * mass * dt, 0)
                let limit = (c.rigidityEnabled ? Float.greatestFiniteMagnitude : max(c.maxForce, 0)) * dt
                if simd_length(impulse) > limit { impulse = simd_normalize(impulse) * limit }
            case .torque:
                var twist = c.torque
                switch c.relativeTo {
                case .world: break
                case .attachment0: twist = (bodyPose.orientation * record.frame0).act(twist)
                case .attachment1:
                    if let target = record.target {
                        twist = (target.body.map { pose(of: $0).orientation * target.frame } ?? target.frame).act(twist)
                    }
                }
                turn(record.body, by: twist * dt)
                continue
            case .alignOrientation:
                alignOrientation(record, bodyPose: bodyPose, dt: dt)
                continue
            default:
                continue
            }
            guard simd_length(impulse) > 0, impulse.x.isFinite, impulse.y.isFinite, impulse.z.isFinite else { continue }
            studio_jolt_wake(world, record.body)
            studio_jolt_add_impulse(world, record.body, Self.floats(impulse))
            if !c.applyAtCenterOfMass, c.kind == .vectorForce {
                // Off the middle, it turns the body too.
                let turn = simd_cross(point - bodyPose.position, impulse)
                if simd_length(turn) > 1e-6 { studio_jolt_add_angular_impulse(world, record.body, Self.floats(turn)) }
            }
        }
    }

    private func turn(_ body: UInt32, by impulse: Vec3) {
        guard simd_length(impulse) > 0, impulse.x.isFinite, impulse.y.isFinite, impulse.z.isFinite else { return }
        studio_jolt_wake(world, body)
        studio_jolt_add_angular_impulse(world, body, Self.floats(impulse))
    }

    /// An AlignOrientation's turn: the spin it wants (Responsiveness × the angle between
    /// Attachment0 and its goal, no more than MaxAngularVelocity), got to as far as
    /// MaxTorque allows in one step. PrimaryAxisOnly lines up the Axis alone and leaves
    /// the spin about it be.
    private func alignOrientation(_ record: ForceRecord, bodyPose: Pose, dt: Float) {
        let c = record.constraint
        let current = simd_normalize(bodyPose.orientation * record.frame0)
        var goal = c.cframe.orientation
        if c.alignMode == .twoAttachment, let target = record.target {
            goal = target.body.map { pose(of: $0).orientation * target.frame } ?? target.frame
        }
        let axis = current.act(Vec3(1, 0, 0))
        var gap = Vec3.zero
        if c.primaryAxisOnly {
            let to = simd_normalize(goal.act(Vec3(1, 0, 0)))
            let across = simd_cross(axis, to), sine = simd_length(across), cosine = simd_dot(axis, to)
            if sine > 1e-6 {
                gap = across / sine * atan2(sine, cosine)
            } else if cosine < 0 {
                // Facing exactly away: any way round will do.
                gap = current.act(Vec3(0, 1, 0)) * .pi
            }
        } else {
            var between = simd_normalize(goal * current.inverse)
            if between.real < 0 { between = simd_quatf(vector: -between.vector) }
            let angle = between.angle
            if angle > 1e-6, simd_length(between.imag) > 1e-9 { gap = simd_normalize(between.imag) * angle }
        }
        var wanted = c.rigidityEnabled ? gap / dt : gap * max(c.responsiveness, 0) * 0.35
        let most = c.maxAngularVelocity.isFinite ? max(c.maxAngularVelocity, 0) : Float.greatestFiniteMagnitude
        if simd_length(wanted) > most { wanted = simd_normalize(wanted) * most }
        var spin = [Float](repeating: 0, count: 3)
        studio_jolt_get_angular_velocity(world, record.body, &spin)
        let now = Vec3(spin[0], spin[1], spin[2])
        // What was lost since the last step (friction, on the ground), made good — no more
        // than the spin wanted, or half a turn a second, so a part held still can't wind up.
        var lost = aimedSpin[c.id].map { $0 - now } ?? .zero
        let room = max(simd_length(wanted), 0.5)
        if simd_length(lost) > room { lost = simd_normalize(lost) * room }
        var change = wanted - now + lost
        if c.primaryAxisOnly { change -= axis * simd_dot(change, axis) }
        aimedSpin[c.id] = now + change
        var impulse = [Float](repeating: 0, count: 3)
        studio_jolt_inertia_times(world, record.body, Self.floats(change), &impulse)
        var turning = Vec3(impulse[0], impulse[1], impulse[2])
        let limit = (c.rigidityEnabled ? Float.greatestFiniteMagnitude : max(c.maxTorque, 0)) * dt
        if simd_length(turning) > limit { turning = simd_normalize(turning) * limit }
        turn(record.body, by: turning)
    }

    /// A hinge's angle (radians), a slider's position (studs) or a Motor6D's CurrentAngle
    /// (radians), as simulated.
    func jointValue(_ constraintID: UUID) -> Float? {
        if let motor = motors[constraintID] { return motor.angle }
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
        driveMotors(dt: min(max(dt, 0), 0.1))
        accumulator += min(max(dt, 0), 0.1)
        var steps = 0
        while accumulator >= Self.timeStep && steps < Self.maxSteps {
            applyForces(dt: Self.timeStep)
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
