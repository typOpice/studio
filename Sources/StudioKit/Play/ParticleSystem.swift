import Foundation
import simd

/// The particles of every ParticleEmitter in the world, on this machine. Particles are
/// only something to look at, so each machine makes its own from the emitters it has —
/// in Studio as you edit, in a game, and in a joined player's game alike — and the
/// renderer steps and draws them each frame. Scripts reach them only through the
/// emitters: Emit(n) and Clear() are counters on the emitter that go up, and each
/// machine acts on the difference since it last looked.
final class ParticleSystem {
    struct Particle {
        /// In the world, or in the part's own space when the emitter is LockedToPart.
        var position: Vec3
        var velocity: Vec3
        var age: Float = 0
        var life: Float
        var rotation: Float
        var spin: Float
        /// Where in each keypoint's envelope this one sits, −1 to 1.
        var offset: Float
    }

    struct Key: Hashable {
        let part: UUID
        let emitter: UUID
    }

    struct Flock {
        var particles: [Particle] = []
        /// Unspent fractions of a particle from Rate.
        var owed: Float = 0
        /// The emitter's counters when last seen.
        var emitted: Int
        var cleared: Int
    }

    /// One particle drawn: where, how big, which way up, its colour and how much it glows.
    struct Sprite {
        var position: Vec3
        var size: Float
        var rotation: Float
        var color: SIMD4<Float>
        var emission: Float
    }

    private(set) var flocks: [Key: Flock] = [:]
    private var random: UInt64

    init(seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        random = seed
    }

    /// How many particles there are, all told.
    var count: Int { flocks.values.reduce(0) { $0 + $1.particles.count } }

    func particles(of key: Key) -> [Particle] { flocks[key]?.particles ?? [] }

    // MARK: - Each frame

    func step(dt: Float, model: SceneModel) {
        guard dt > 0 else { return }
        var seen: Set<Key> = []
        for part in model.parts where !part.emitters.isEmpty && part.inWorld && part.storage == nil {
            for emitter in part.emitters {
                let key = Key(part: part.id, emitter: emitter.id)
                seen.insert(key)
                // New to this machine: what went before isn't replayed, bar the last
                // Emit (a script making an emitter and bursting it at once).
                var flock = flocks[key]
                    ?? Flock(emitted: emitter.emitted - min(emitter.lastBurst, emitter.emitted), cleared: emitter.cleared)
                step(&flock, emitter: emitter, part: part, dt: dt)
                flocks[key] = flock
            }
        }
        for key in flocks.keys where !seen.contains(key) { flocks[key] = nil }
    }

    private func step(_ flock: inout Flock, emitter: ParticleEmitter, part: Part, dt: Float) {
        if emitter.cleared != flock.cleared {
            flock.particles.removeAll()
            flock.cleared = emitter.cleared
        }
        let t = dt * min(max(emitter.timeScale, 0), 1)
        // Older, and moved on.
        if !flock.particles.isEmpty {
            let slowing = exp(-max(emitter.drag, 0) * t)
            // Acceleration is the world's; a locked particle's velocity is the part's.
            let push = emitter.lockedToPart ? part.orientation.inverse.act(emitter.acceleration) : emitter.acceleration
            var kept: [Particle] = []
            kept.reserveCapacity(flock.particles.count)
            for var particle in flock.particles {
                particle.age += t
                guard particle.age < particle.life else { continue }
                particle.velocity = (particle.velocity + push * t) * slowing
                particle.position += particle.velocity * t
                particle.rotation += particle.spin * t
                kept.append(particle)
            }
            flock.particles = kept
        }
        // New ones: Rate's, and any Emit since last frame.
        var count = 0
        if emitter.enabled, emitter.rate > 0 {
            flock.owed += emitter.rate * t
            count = Int(flock.owed)
            flock.owed -= Float(count)
        } else {
            flock.owed = 0
        }
        if emitter.emitted != flock.emitted {
            count += max(emitter.emitted - flock.emitted, 0)
            flock.emitted = emitter.emitted
        }
        count = min(count, ParticleEmitter.most - flock.particles.count)
        for _ in 0..<max(count, 0) { flock.particles.append(spawn(emitter, part: part)) }
    }

    /// A new particle: somewhere in the part, flying out of its face.
    private func spawn(_ emitter: ParticleEmitter, part: Part) -> Particle {
        let local = Vec3(next() - 0.5, next() - 0.5, next() - 0.5) * part.size
        let normal = emitter.emissionDirection.normal
        // Two axes across the normal to turn it about, by up to SpreadAngle each way.
        let across = abs(normal.y) > 0.5 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)
        let first = simd_normalize(simd_cross(normal, across)), second = simd_normalize(simd_cross(normal, first))
        let spread = emitter.spreadAngle * (.pi / 180)
        let turn = simd_quatf(angle: (next() * 2 - 1) * spread.x, axis: first)
            * simd_quatf(angle: (next() * 2 - 1) * spread.y, axis: second)
        let direction = turn.act(normal)
        let speed = pick(emitter.speed)
        var position = local, velocity = direction * speed
        if !emitter.lockedToPart {
            position = part.position + part.orientation.act(local)
            velocity = part.orientation.act(velocity)
        }
        let degrees = Float.pi / 180
        return Particle(position: position, velocity: velocity, life: max(pick(emitter.lifetime), 0.001),
                        rotation: pick(emitter.rotation) * degrees, spin: pick(emitter.rotSpeed) * degrees,
                        offset: next() * 2 - 1)
    }

    // MARK: - Drawing

    /// Every particle of every emitter as it's drawn, the emitter's picture with each batch.
    func sprites(model: SceneModel, each: (_ emitter: ParticleEmitter, _ sprites: [Sprite]) -> Void) {
        for (key, flock) in flocks where !flock.particles.isEmpty {
            guard let part = model.part(id: key.part), let emitter = part.emitters.first(where: { $0.id == key.emitter })
            else { continue }
            let sprites = flock.particles.map { particle -> Sprite in
                let t = min(particle.age / particle.life, 1)
                let position = emitter.lockedToPart ? part.position + part.orientation.act(particle.position) : particle.position
                let colour = emitter.color.color(at: t) * max(emitter.brightness, 0)
                let alpha = 1 - min(max(emitter.transparency.value(at: t, offset: particle.offset), 0), 1)
                return Sprite(position: position, size: max(emitter.size.value(at: t, offset: particle.offset), 0),
                              rotation: particle.rotation, color: SIMD4(colour, alpha),
                              emission: min(max(emitter.lightEmission, 0), 1))
            }
            each(emitter, sprites)
        }
    }

    // MARK: - Chance

    /// 0 up to 1, the same run each time from the same seed.
    private func next() -> Float {
        random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(random >> 40) / Float(1 << 24)
    }

    private func pick(_ range: SIMD2<Float>) -> Float {
        range.x + (range.y - range.x) * next()
    }
}
