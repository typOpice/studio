import simd
import Foundation

/// Movement request for one simulation step, in world space.
struct MoveInput {
    var forward: Float = 0      // -1 ... 1, along the camera's facing
    var strafe: Float = 0       // -1 ... 1
    var cameraYaw: Float = 0
    var jump = false
    var sprint = false
    var fly = false
    var flyUp: Float = 0
}

/// What the humanoid asks the physics for this frame. Built from `Humanoid` by the
/// play controller; nothing here knows about keys or scripts.
struct CharacterIntent {
    /// World space. Horizontal when walking; the y part is used only when flying.
    var direction = Vec3.zero
    var jump = false
    var flying = false
    var dead = false
    var walkSpeed: Float = CharacterController.walkSpeed
    var jumpVelocity: Float = CharacterController.jumpPower
    var maxSlopeCosine: Float = CharacterController.defaultMaxSlopeCosine
    var gravity: Float = CharacterController.gravity
    var autoRotate = true
}

/// The character's body: capsule collision, gravity, step-up, ground probes.
///
/// It obeys a `CharacterIntent` and nothing else — the Humanoid decides what to do,
/// this decides what happens.
///
/// Walls are resolved against a capsule whose bottom is lifted by the step height,
/// so anything shorter than a step never blocks movement. Support underfoot comes
/// from a set of downward probes instead of the capsule's rounded base — a rounded
/// base slides off ledges and stair nosings, which is exactly what we don't want.
struct CharacterController {

    // Roblox's own defaults, in studs and studs/second.
    static let walkSpeed: Float = 16
    static let sprintMultiplier: Float = 1.9
    static let jumpPower: Float = 50
    static let gravity: Float = 196.2
    static let stepHeight: Float = 2.0
    /// Roblox's default MaxSlopeAngle is 89°: anything short of a wall is walkable.
    static let defaultMaxSlopeCosine: Float = cos(89 * .pi / 180)
    static let capsuleRadius: Float = 1.0
    static let capsuleHeight: Float = 5.0
    static let flySpeed: Float = 45
    static let voidHeight: Float = -150
    /// Climbing and swimming go at these shares of WalkSpeed.
    static let climbSpeedFactor: Float = 0.7
    static let swimSpeedFactor: Float = 0.8
    /// Floating, the feet sit this far below the water's surface: the head is out.
    static let floatDepth: Float = 3.6

    /// Longest distance to travel in one collision substep.
    private static let maxSubstepDistance: Float = 0.35

    var position = Vec3(0, 6, 16)               // feet
    var velocity = Vec3.zero
    var facingYaw: Float = 0
    var grounded = false
    var groundNormal = Vec3(0, 1, 0)
    var walkPhase: Float = 0                    // drives the limb swing
    var spawnPoint = Vec3(0, 6, 16)
    var solidBaseplate = true
    /// The steepest surface that counts as ground, as a cosine. Set from the intent.
    var maxSlopeCosine: Float = CharacterController.defaultMaxSlopeCosine
    /// Set when the character drops below the void; the humanoid decides what that means.
    private(set) var fellIntoVoid = false
    /// The part underfoot (not the baseplate), so a moving platform can carry the body.
    private(set) var groundPartID: UUID?
    /// A push from outside — a part hitting the body — that fades as the body slides.
    var shove = Vec3.zero
    /// Holding onto a truss.
    private(set) var climbing = false
    /// Deep enough in water to swim.
    private(set) var swimming = false

    /// Full-height collision volume.
    var capsule: Capsule {
        Capsule(base: position, radius: Self.capsuleRadius, height: Self.capsuleHeight)
    }

    /// Volume used for walls: lifted by the step height while walking, so low
    /// obstacles are stepped over rather than bumped into.
    private var wallCapsule: Capsule {
        let lift = grounded ? Self.stepHeight : 0
        return Capsule(base: position + Vec3(0, lift, 0),
                       radius: Self.capsuleRadius,
                       height: Self.capsuleHeight - lift)
    }

    var eyePosition: Vec3 { position + Vec3(0, Self.capsuleHeight - 0.9, 0) }

    var horizontalSpeed: Float { length(Vec3(velocity.x, 0, velocity.z)) }

    // MARK: - Simulation

    /// Keyboard-shaped convenience used by the physics tests: camera-relative input
    /// at the default Humanoid values, respawning on falling into the void.
    mutating func step(dt frameTime: Float, input: MoveInput, parts: [Part]) {
        let forwardDir = Vec3(-sin(input.cameraYaw), 0, -cos(input.cameraYaw))
        let rightDir = Vec3(cos(input.cameraYaw), 0, -sin(input.cameraYaw))
        var intent = CharacterIntent()
        intent.direction = forwardDir * input.forward + rightDir * input.strafe
            + Vec3(0, input.flyUp, 0)
        intent.jump = input.jump
        intent.flying = input.fly
        intent.walkSpeed = Self.walkSpeed * (input.sprint ? Self.sprintMultiplier : 1)
        step(dt: frameTime, intent: intent, parts: parts)
        if fellIntoVoid { respawn() }
    }

    /// Returns true if a jump started this step.
    @discardableResult
    mutating func step(dt frameTime: Float, intent: CharacterIntent, parts: [Part]) -> Bool {
        let dt = min(frameTime, 1.0 / 30)       // never integrate a huge stall in one go
        maxSlopeCosine = intent.maxSlopeCosine

        var wish = Vec3(intent.direction.x, 0, intent.direction.z)
        if intent.dead { wish = .zero }
        if length(wish) > 1 { wish = normalize(wish) }

        if intent.flying && !intent.dead {
            climbing = false
            swimming = false
            stepFlying(dt: dt, wish: wish, up: intent.direction.y, speed: intent.walkSpeed,
                       autoRotate: intent.autoRotate)
            return false
        }

        let solids = parts.filter(\.isSolid)

        // The middle of the body in water: swim.
        if !intent.dead, let surface = waterSurface(in: parts) {
            climbing = false
            swimming = true
            stepSwimming(dt: dt, wish: wish, surface: surface, intent: intent, solids: solids)
            return false
        }
        swimming = false

        // Moving into a truss takes hold of it; holding on, it goes up, down or along.
        if !intent.dead, let normal = trussNormal(in: solids), climbing || dot(wish, -normal) > 0.5 {
            climbing = true
            return stepClimbing(dt: dt, wish: wish, normal: normal, intent: intent, solids: solids)
        }
        climbing = false

        velocity.x = wish.x * intent.walkSpeed + shove.x
        velocity.z = wish.z * intent.walkSpeed + shove.z
        // Gravity is applied half before moving and half after (velocity Verlet),
        // which is exact for constant gravity: a jump reaches precisely the height
        // JumpPower or JumpHeight promises, whatever the frame rate.
        let halfKick = intent.gravity * dt / 2
        velocity.y -= halfKick

        var jumped = false
        if intent.jump && grounded && !intent.dead {
            velocity.y = intent.jumpVelocity - halfKick
            grounded = false
            jumped = true
        }

        // Split the frame so a fast fall or sprint can never skip through geometry.
        let travel = length(velocity) * dt
        let substeps = max(1, min(8, Int((travel / Self.maxSubstepDistance).rounded(.up))))
        let slice = dt / Float(substeps)
        for _ in 0..<substeps {
            substep(dt: slice, parts: solids)
        }
        if !grounded { velocity.y -= halfKick }

        // Face the direction of travel, the way a Roblox humanoid turns.
        if length(wish) > 0.05 {
            if intent.autoRotate {
                facingYaw = turn(facingYaw, towards: atan2(-wish.x, -wish.z), by: 12 * dt)
            }
            walkPhase += horizontalSpeed * dt * 0.55
        } else {
            walkPhase *= max(0, 1 - dt * 8)
        }

        fadeShove(dt: dt)
        fellIntoVoid = position.y < Self.voidHeight
        return jumped
    }

    /// A shove slides out quickly on the ground, slowly in the air.
    private mutating func fadeShove(dt: Float) {
        shove *= max(0, 1 - (grounded ? 6 : 1.5) * dt)
        if length(shove) < 0.05 { shove = .zero }
    }

    // MARK: - Swimming and climbing

    /// The surface of the water the middle of the body is in, if it is in any.
    func waterSurface(in parts: [Part]) -> Float? {
        let middle = position + Vec3(0, 2.5, 0)
        var surface: Float?
        for part in parts where part.inWorld && part.material == .water {
            let local = part.orientation.inverse.act(middle - part.position)
            let h = part.size * 0.5
            guard abs(local.x) <= h.x, abs(local.y) <= h.y, abs(local.z) <= h.z else { continue }
            let top = part.position.y + abs(part.orientation.act(Vec3(0, h.y, 0)).y)
            surface = max(surface ?? top, top)
        }
        return surface
    }

    /// Floating with the head out; Space swims up (and out, at the surface).
    private mutating func stepSwimming(dt: Float, wish: Vec3, surface: Float, intent: CharacterIntent, solids: [Part]) {
        let speed = intent.walkSpeed * Self.swimSpeedFactor
        velocity.x = wish.x * speed + shove.x
        velocity.z = wish.z * speed + shove.z
        let depth = surface - (position.y + Self.floatDepth)
        let goal = intent.jump ? speed : max(min(depth * 4, speed), -speed)
        velocity.y += (goal - velocity.y) * min(1, dt * 5)
        position.x += velocity.x * dt
        position.z += velocity.z * dt
        resolveWalls(parts: solids)
        position.y += velocity.y * dt
        resolveVertical(parts: solids)
        grounded = false
        groundPartID = nil
        if intent.autoRotate && length(wish) > 0.05 {
            facingYaw = turn(facingYaw, towards: atan2(-wish.x, -wish.z), by: 12 * dt)
        }
        walkPhase += horizontalSpeed * dt * 0.55
        fadeShove(dt: dt)
        fellIntoVoid = position.y < Self.voidHeight
    }

    /// The way out of a truss the body is against (horizontal), if it is against one.
    private func trussNormal(in solids: [Part]) -> Vec3? {
        var reach = capsule
        reach.radius += 0.25
        for part in solids where part.shape == .truss {
            guard Collision.mayTouch(capsule: reach, part: part),
                  let contact = Collision.contact(capsule: reach, part: part) else { continue }
            let out = Vec3(contact.normal.x, 0, contact.normal.z)
            // Standing on top of one is standing, not climbing.
            guard length(out) > 0.5 else { continue }
            return normalize(out)
        }
        return nil
    }

    /// Returns true when the climber jumps off.
    private mutating func stepClimbing(dt: Float, wish: Vec3, normal: Vec3, intent: CharacterIntent,
                                       solids: [Part]) -> Bool {
        let speed = intent.walkSpeed * Self.climbSpeedFactor
        shove = .zero
        if intent.jump {
            // Let go, springing back off it.
            climbing = false
            grounded = false
            shove = normal * speed * 1.2
            velocity = shove + Vec3(0, intent.jumpVelocity * 0.6, 0)
            position += velocity * dt
            return true
        }
        let into = dot(wish, -normal)
        let along = wish + normal * into
        velocity = along * speed * 0.5 - normal * 0.5
        velocity.y = into > 0.2 ? speed : into < -0.2 ? -speed : 0
        position.x += velocity.x * dt
        position.z += velocity.z * dt
        grounded = false
        resolveWalls(parts: solids)
        position.y += velocity.y * dt
        resolveVertical(parts: solids)
        groundPartID = nil
        // Climbing down onto the ground lets go.
        if velocity.y < 0, let ground = groundProbe(parts: solids, maxDrop: 0.1) {
            position.y = ground.height
            climbing = false
            grounded = true
            velocity.y = 0
        }
        facingYaw = atan2(normal.x, normal.z)
        walkPhase += abs(velocity.y) * dt * 0.55
        fellIntoVoid = position.y < Self.voidHeight
        return false
    }

    private mutating func substep(dt: Float, parts: [Part]) {
        // 1. Horizontal, blocked only by things taller than a step.
        position.x += velocity.x * dt
        position.z += velocity.z * dt
        resolveWalls(parts: parts)

        // 2. Vertical, for landing on and bumping into surfaces.
        position.y += velocity.y * dt
        resolveVertical(parts: parts)

        // 3. Find what is underfoot and snap onto it.
        if velocity.y <= 0.01 {
            let reach = grounded ? Self.stepHeight : 0.2
            if let ground = groundProbe(parts: parts, maxDrop: reach) {
                position.y = ground.height
                groundNormal = ground.normal
                groundPartID = ground.part
                grounded = true
                if velocity.y < 0 { velocity.y = 0 }
            } else {
                grounded = false
                groundPartID = nil
                groundNormal = Vec3(0, 1, 0)
            }
        } else {
            grounded = false
            groundPartID = nil
        }
    }

    /// Flying scales with WalkSpeed, so whatever speeds up walking speeds up flying.
    private mutating func stepFlying(dt: Float, wish: Vec3, up: Float, speed walkSpeed: Float, autoRotate: Bool) {
        let speed = Self.flySpeed * walkSpeed / Self.walkSpeed
        velocity = Vec3(wish.x, 0, wish.z) * speed + Vec3(0, max(-1, min(1, up)) * speed, 0)
        position += velocity * dt
        grounded = false
        if autoRotate && length(wish) > 0.05 {
            facingYaw = turn(facingYaw, towards: atan2(-wish.x, -wish.z), by: 12 * dt)
        }
        walkPhase = 0
    }

    // MARK: - Collision passes

    /// Push out of walls, horizontally only, so a glancing contact never launches the player.
    private mutating func resolveWalls(parts: [Part]) {
        for _ in 0..<3 {
            var moved = false
            let capsule = wallCapsule
            for part in parts {
                guard Collision.mayTouch(capsule: capsule, part: part),
                      let contact = Collision.contact(capsule: capsule, part: part),
                      abs(contact.normal.y) < 0.92                    // floors are not walls
                else { continue }
                let horizontal = Vec3(contact.normal.x, 0, contact.normal.z)
                guard length(horizontal) > 1e-4 else { continue }
                let push = normalize(horizontal)
                // Scale so the push still clears the original penetration depth.
                position += push * (contact.depth / max(length(horizontal), 0.2))
                let into = dot(velocity, push)
                if into < 0 { velocity -= push * into }
                moved = true
            }
            if !moved { break }
        }
    }

    /// Resolve floors and ceilings along Y only.
    private mutating func resolveVertical(parts: [Part]) {
        for _ in 0..<3 {
            var moved = false
            let capsule = self.capsule
            for part in parts {
                guard Collision.mayTouch(capsule: capsule, part: part),
                      let contact = Collision.contact(capsule: capsule, part: part),
                      abs(contact.normal.y) > 0.5
                else { continue }
                position.y += contact.normal.y * contact.depth
                if contact.normal.y > 0 {
                    if velocity.y < 0 { velocity.y = 0 }
                } else if velocity.y > 0 {
                    velocity.y = 0
                }
                moved = true
            }
            if solidBaseplate && position.y < 0 {
                position.y = 0
                if velocity.y < 0 { velocity.y = 0 }
                moved = true
            }
            if !moved { break }
        }
    }

    /// Cast downwards from just above step height at the centre and four foot positions.
    /// Returns the highest walkable surface within reach.
    private func groundProbe(parts: [Part], maxDrop: Float) -> (height: Float, normal: Vec3, part: UUID?)? {
        let spread = Self.capsuleRadius * 0.72
        let offsets = [Vec3(0, 0, 0),
                       Vec3(spread, 0, 0), Vec3(-spread, 0, 0),
                       Vec3(0, 0, spread), Vec3(0, 0, -spread)]
        let lift = Self.stepHeight
        let maxDistance = lift + maxDrop
        var best: (height: Float, normal: Vec3, part: UUID?)?

        for offset in offsets {
            let ray = Ray(origin: position + offset + Vec3(0, lift, 0), direction: Vec3(0, -1, 0))
            for part in parts {
                guard let t = Picking.intersect(ray: ray, part: part), t <= maxDistance else { continue }
                let point = ray.point(at: t)
                let normal = Collision.surfaceNormal(part: part, worldPoint: point)
                guard normal.y > maxSlopeCosine else { continue }
                if best == nil || point.y > best!.height {
                    best = (point.y, normal, part.id)
                }
            }
        }

        if solidBaseplate, position.y - maxDrop <= 0, position.y + lift >= 0 {
            if best == nil || best!.height < 0 {
                best = (0, Vec3(0, 1, 0), nil)
            }
        }
        return best
    }

    // MARK: - Helpers

    private func turn(_ current: Float, towards target: Float, by amount: Float) -> Float {
        var delta = target - current
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        let step = min(max(delta, -amount * .pi), amount * .pi)
        return current + step
    }

    mutating func respawn() {
        position = spawnPoint
        velocity = .zero
        shove = .zero
        grounded = false
        climbing = false
        swimming = false
        groundPartID = nil
        fellIntoVoid = false
    }

    /// Sitting in a seat: the body is where the seat puts it, and still.
    mutating func sit(at feet: Vec3, facing yaw: Float) {
        position = feet
        facingYaw = yaw
        velocity = .zero
        shove = .zero
        grounded = true
        climbing = false
        swimming = false
        groundPartID = nil
    }

    /// Pick a spawn on top of whatever is at the default spot, so the player never starts inside geometry.
    mutating func chooseSpawn(in parts: [Part]) {
        var spawn = Vec3(0, 0.5, 18)
        let ray = Ray(origin: Vec3(0, 400, 18), direction: Vec3(0, -1, 0))
        var highest: Float?
        for part in parts where part.isSolid {
            if let t = Picking.intersect(ray: ray, part: part) {
                let y = ray.point(at: t).y
                if highest == nil || y > highest! { highest = y }
            }
        }
        if let highest { spawn.y = highest + 0.5 }
        spawnPoint = spawn
        position = spawn
        velocity = .zero
        grounded = false
    }
}
