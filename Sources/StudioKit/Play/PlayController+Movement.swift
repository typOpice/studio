import Foundation
import simd

// PlayController and how the world moves the character: platforms that carry it, parts
// that knock it, seats that hold it — and, on the host, other players' bodies pushing
// parts as hard as this player's does. Climbing and swimming are CharacterController's.

extension PlayController {
    /// A character weighs about this much, for how hard it pushes and is pushed.
    static let characterMass: Float = 25
    /// After getting up from a seat, how long before touching one sits again.
    static let seatDelay: Double = 1

    var isSeated: Bool { seatPart != nil }

    // MARK: - Platforms

    /// Moves the body with the part it stands on, however that part moved since last
    /// frame — by a script, a tween or physics — turning it with the part too.
    func rideGround() {
        guard let ride = standingOn, character.grounded, !isSeated,
              let part = model.part(id: ride.id), part.pose != ride.pose else { return }
        let feet = Pose(position: character.position, orientation: Pose.identity.orientation)
        character.position = part.pose.applying(ride.pose.inverse.applying(feet)).position
        let turn = part.pose.orientation * ride.pose.orientation.inverse
        let yaw = character.facingYaw
        let facing = turn.act(Vec3(-sin(yaw), 0, -cos(yaw)))
        if abs(facing.y) < 0.9 { character.facingYaw = atan2(-facing.x, -facing.z) }
    }

    /// What the body stands on now, and where that is, for next frame's ride.
    func noteGround() {
        if character.grounded, let id = character.groundPartID, let part = model.part(id: id) {
            standingOn = (id, part.pose)
        } else {
            standingOn = nil
        }
    }

    // MARK: - Being hit

    /// Parts flying at the body shove it — harder the heavier they are — before physics
    /// bounces them off the capsule, which it treats as immovable.
    func takeHits(dt: Float) {
        guard hasPlayer, !humanoid.isDead, !isSeated else { return }
        for part in model.parts where !part.anchored && part.isSolid {
            guard simd_distance(part.position, character.position + Vec3(0, 2.5, 0)) < simd_length(part.size) + 8,
                  let motion = physics.motion(of: part.id), !motion.isStatic else { continue }
            var reach = character.capsule
            reach.radius += 0.2 + simd_length(motion.velocity) * dt
            guard let contact = Collision.contact(capsule: reach, part: part) else { continue }
            let closing = dot(motion.velocity - character.velocity, contact.normal)
            guard closing > 4 else { continue }
            let share = motion.assemblyMass / (motion.assemblyMass + Self.characterMass)
            var push = contact.normal * closing * share
            push.y = 0
            character.shove += push
            if simd_length(character.shove) > 60 { character.shove = normalize(character.shove) * 60 }
        }
    }

    // MARK: - Other players pushing (the host)

    /// Joined players' bodies shove what they walk into as this player's does: at the
    /// pace they're walking at along the push (their own game stops them at the part,
    /// so their velocity says nothing), less the heavier the part.
    func remotePlayersPush() {
        guard !worldFromHost else { return }
        for remote in remotePlayers where !remote.dead {
            let walk = Vec3(remote.moveDirection.x, 0, remote.moveDirection.z) * remote.walkSpeed
            guard simd_length(walk) > 0.5 else { continue }
            // Their reports trail them by the network's delay, and their own game stops
            // them at the part until they hear it moved: reach a fifth of a second ahead.
            // Only what is ahead is pushed — the push is along their walk.
            let lead = min(simd_length(walk) * 0.2, 3.5)
            let reach = Capsule(base: remote.position, radius: CharacterController.capsuleRadius + 0.15 + lead,
                                height: CharacterController.capsuleHeight)
            for part in model.parts where !part.anchored && part.isSolid
                && simd_distance(part.position, remote.position) < simd_length(part.size) + 4 {
                guard let contact = Collision.contact(capsule: reach, part: part) else { continue }
                var direction = -contact.normal
                direction.y = 0
                guard simd_length(direction) > 0.3 else { continue }
                direction = normalize(direction)
                physics.push(part.id, along: direction, speed: dot(walk, direction))
            }
        }
    }

    // MARK: - Seats

    /// Whether anyone — this player or another — is in a seat.
    func occupant(of seat: UUID) -> Int? {
        if seatPart == seat { return characterGeneration }
        if let remote = remotePlayers.first(where: { $0.seat == seat && !$0.dead }) {
            return RemoteCharacter.number(player: remote.id, generation: remote.generation)
        }
        return nil
    }

    /// Touching a free seat sits down in it, unless just got up from one.
    func sitOnTouchedSeat(_ touches: Set<CharacterTouch.Touch>) {
        guard !isSeated, !humanoid.isDead, clock >= seatDelayUntil, humanoid.state != .flying else { return }
        for touch in touches {
            guard let part = model.part(id: touch.partID), let seat = part.seat, !seat.disabled,
                  occupant(of: part.id) == nil else { continue }
            sit(in: part.id)
            return
        }
    }

    func sit(in seat: UUID) {
        seatPart = seat
        humanoid.jump = false
        humanoid.enter(.seated)
        humanoid.record(.seated(active: true, seat: seat))
        holdInSeat()
    }

    /// Up out of the seat: by jumping, by Sit = false, or because the seat went.
    func standUp() {
        guard isSeated else { return }
        seatPart = nil
        seatDelayUntil = clock + Self.seatDelay
        humanoid.record(.seated(active: false, seat: nil))
        if !humanoid.isDead { humanoid.enter(.running) }
    }

    /// Keeps a seated body on its seat: hips on the top, facing the seat's front.
    func holdInSeat() {
        guard let id = seatPart, let part = model.part(id: id) else { return }
        let top = part.pose.applying(Pose(position: Vec3(0, part.size.y / 2, 0), orientation: Pose.identity.orientation))
        let front = part.orientation.act(Vec3(0, 0, -1))
        character.sit(at: top.position - Vec3(0, 2, 0), facing: atan2(-front.x, -front.z))
    }

    /// Each frame in a seat: a jump, death, or the seat going or being disabled gets up.
    func stayInSeat() {
        guard let id = seatPart else { return }
        let seat = model.part(id: id)
        if humanoid.jump || humanoid.isDead || seat == nil || seat?.seat == nil || seat?.seat?.disabled == true {
            standUp()
        } else {
            holdInSeat()
        }
    }
}
