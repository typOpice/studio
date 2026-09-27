import Foundation
import simd

/// A NumberSequence keypoint: at `time` through a particle's life (0 to 1), `value`, give
/// or take up to `envelope` (a particle picks where in that it sits when it's made).
struct NumberKey: Codable, Equatable {
    var time: Float
    var value: Float
    var envelope: Float = 0
}

/// A ColorSequence keypoint.
struct ColorKey: Codable, Equatable {
    var time: Float
    var color: Vec3
}

extension Array where Element == NumberKey {
    /// A NumberSequence from `start` to `end`.
    static func from(_ start: Float, to end: Float) -> [NumberKey] {
        [NumberKey(time: 0, value: start), NumberKey(time: 1, value: end)]
    }

    /// Its value at `t`, a particle's `offset` (−1…1) through each keypoint's envelope.
    func value(at t: Float, offset: Float = 0) -> Float {
        guard let first, let last else { return 0 }
        if t <= first.time { return first.value + first.envelope * offset }
        for (a, b) in zip(self, dropFirst()) where t <= b.time {
            let f = b.time > a.time ? (t - a.time) / (b.time - a.time) : 1
            return a.value + (b.value - a.value) * f + (a.envelope + (b.envelope - a.envelope) * f) * offset
        }
        return last.value + last.envelope * offset
    }
}

extension Array where Element == ColorKey {
    static func from(_ start: Vec3, to end: Vec3) -> [ColorKey] {
        [ColorKey(time: 0, color: start), ColorKey(time: 1, color: end)]
    }

    func color(at t: Float) -> Vec3 {
        guard let first, let last else { return Vec3(1, 1, 1) }
        if t <= first.time { return first.color }
        for (a, b) in zip(self, dropFirst()) where t <= b.time {
            let f = b.time > a.time ? (t - a.time) / (b.time - a.time) : 1
            return simd_mix(a.color, b.color, Vec3(repeating: f))
        }
        return last.color
    }
}

/// Roblox's ParticleEmitter, kept on the part it's in (`Part.emitters`): little pictures
/// that come out of the part, fly, fade and go. Only how they look is scene data — saved,
/// and sent to joined players with the part; the particles themselves are each
/// machine's own (`ParticleSystem`), as in Roblox. A script's `Emit(n)` and `Clear()`
/// reach every machine as counters (`emitted`, `cleared`) that go up.
struct ParticleEmitter: Codable, Equatable, Identifiable {
    /// Enum.NormalId: which face of the part they fly out of.
    enum Face: String, Codable, CaseIterable, Identifiable {
        case right = "Right", top = "Top", back = "Back", left = "Left", bottom = "Bottom", front = "Front"
        var id: String { rawValue }
        /// Out of that face, in the part's own space (Front is −Z).
        var normal: Vec3 {
            switch self {
            case .right: return Vec3(1, 0, 0)
            case .left: return Vec3(-1, 0, 0)
            case .top: return Vec3(0, 1, 0)
            case .bottom: return Vec3(0, -1, 0)
            case .back: return Vec3(0, 0, 1)
            case .front: return Vec3(0, 0, -1)
            }
        }
    }

    /// The pictures that come with the app; any imported picture ("studio://Name") works too.
    static let builtinTextures = ["Sparkle", "Circle", "Smoke", "Fire", "Star", "Confetti"]

    var id = UUID()
    var name = "ParticleEmitter"
    var enabled = true
    /// Particles a second.
    var rate: Float = 20
    /// NumberRanges: each particle picks between the two.
    var lifetime = SIMD2<Float>(5, 10)
    var speed = SIMD2<Float>(5, 5)
    var rotation = SIMD2<Float>(0, 0)
    var rotSpeed = SIMD2<Float>(0, 0)
    /// Degrees either way off the face's normal, about the part's two other axes.
    var spreadAngle = SIMD2<Float>(0, 0)
    var emissionDirection = Face.top
    /// Studs a second, each second, in the world (gravity is up to the emitter).
    var acceleration = Vec3.zero
    /// How fast they slow down: speed falls by e^(−drag) each second.
    var drag: Float = 0
    var size: [NumberKey] = .from(1, to: 1)
    var transparency: [NumberKey] = .from(0, to: 0)
    var color: [ColorKey] = .from(Vec3(1, 1, 1), to: Vec3(1, 1, 1))
    /// 0 drawn over what's behind; 1 added to it, glowing.
    var lightEmission: Float = 0
    var brightness: Float = 1
    /// Particles move with the part rather than being left where they were made.
    var lockedToPart = false
    /// How fast their time runs, 0 to 1.
    var timeScale: Float = 1
    /// "builtin://Sparkle" and the rest, or an imported picture.
    var texture = "builtin://Sparkle"
    /// All the particles scripts have asked for with Emit, and the last Emit's.
    var emitted = 0
    var lastBurst = 0
    /// How many times a script has called Clear.
    var cleared = 0

    init() {}

    // Saved files leave out what's still as it was made.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ParticleEmitter()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        rate = try c.decodeIfPresent(Float.self, forKey: .rate) ?? d.rate
        lifetime = try c.decodeIfPresent(SIMD2<Float>.self, forKey: .lifetime) ?? d.lifetime
        speed = try c.decodeIfPresent(SIMD2<Float>.self, forKey: .speed) ?? d.speed
        rotation = try c.decodeIfPresent(SIMD2<Float>.self, forKey: .rotation) ?? d.rotation
        rotSpeed = try c.decodeIfPresent(SIMD2<Float>.self, forKey: .rotSpeed) ?? d.rotSpeed
        spreadAngle = try c.decodeIfPresent(SIMD2<Float>.self, forKey: .spreadAngle) ?? d.spreadAngle
        emissionDirection = try c.decodeIfPresent(Face.self, forKey: .emissionDirection) ?? d.emissionDirection
        acceleration = try c.decodeIfPresent(Vec3.self, forKey: .acceleration) ?? d.acceleration
        drag = try c.decodeIfPresent(Float.self, forKey: .drag) ?? d.drag
        size = try c.decodeIfPresent([NumberKey].self, forKey: .size) ?? d.size
        transparency = try c.decodeIfPresent([NumberKey].self, forKey: .transparency) ?? d.transparency
        color = try c.decodeIfPresent([ColorKey].self, forKey: .color) ?? d.color
        lightEmission = try c.decodeIfPresent(Float.self, forKey: .lightEmission) ?? d.lightEmission
        brightness = try c.decodeIfPresent(Float.self, forKey: .brightness) ?? d.brightness
        lockedToPart = try c.decodeIfPresent(Bool.self, forKey: .lockedToPart) ?? d.lockedToPart
        timeScale = try c.decodeIfPresent(Float.self, forKey: .timeScale) ?? d.timeScale
        texture = try c.decodeIfPresent(String.self, forKey: .texture) ?? d.texture
        emitted = try c.decodeIfPresent(Int.self, forKey: .emitted) ?? 0
        lastBurst = try c.decodeIfPresent(Int.self, forKey: .lastBurst) ?? 0
        cleared = try c.decodeIfPresent(Int.self, forKey: .cleared) ?? 0
    }

    /// Particles alive at once, at most, from one emitter.
    static let most = 2000

    /// The value types scripts set, checked: ranges in order, sequences from 0 to 1.
    static func validRange(_ range: SIMD2<Float>) -> Bool {
        range.x.isFinite && range.y.isFinite && range.x <= range.y
    }
}

// MARK: - Starting points

extension ParticleEmitter {
    /// What Studio's Add ParticleEmitter menu offers: Roblox's defaults (sparkles) and a
    /// few ready-made effects to start from.
    enum Preset: String, CaseIterable, Identifiable {
        case sparkles = "Sparkles", fire = "Fire", smoke = "Smoke", magic = "Magic", confetti = "Confetti"
        var id: String { rawValue }
    }

    static func preset(_ preset: Preset) -> ParticleEmitter {
        var e = ParticleEmitter()
        switch preset {
        case .sparkles:
            break
        case .fire:
            e.name = "Fire"
            e.texture = "builtin://Fire"
            e.rate = 45
            e.lifetime = SIMD2(0.6, 1.1)
            e.speed = SIMD2(3, 6)
            e.spreadAngle = SIMD2(12, 12)
            e.acceleration = Vec3(0, 3, 0)
            e.size = [NumberKey(time: 0, value: 1.6), NumberKey(time: 0.5, value: 1.3), NumberKey(time: 1, value: 0.3)]
            e.transparency = [NumberKey(time: 0, value: 0.6), NumberKey(time: 0.15, value: 0.1), NumberKey(time: 1, value: 1)]
            e.color = [ColorKey(time: 0, color: Vec3(1, 0.85, 0.35)), ColorKey(time: 0.5, color: Vec3(1, 0.45, 0.1)),
                       ColorKey(time: 1, color: Vec3(0.6, 0.1, 0.05))]
            e.lightEmission = 1
            e.rotSpeed = SIMD2(-60, 60)
            e.rotation = SIMD2(0, 360)
        case .smoke:
            e.name = "Smoke"
            e.texture = "builtin://Smoke"
            e.rate = 6
            e.lifetime = SIMD2(3, 5)
            e.speed = SIMD2(2, 3.5)
            e.spreadAngle = SIMD2(15, 15)
            e.drag = 0.4
            e.size = .from(1.2, to: 5)
            e.transparency = [NumberKey(time: 0, value: 1), NumberKey(time: 0.1, value: 0.2), NumberKey(time: 1, value: 1)]
            e.color = .from(Vec3(0.7, 0.7, 0.7), to: Vec3(0.45, 0.45, 0.47))
            e.rotation = SIMD2(0, 360)
            e.rotSpeed = SIMD2(-25, 25)
        case .magic:
            e.name = "Magic"
            e.texture = "builtin://Star"
            e.rate = 14
            e.lifetime = SIMD2(1, 2)
            e.speed = SIMD2(1, 2.5)
            e.spreadAngle = SIMD2(180, 180)
            e.size = [NumberKey(time: 0, value: 0.3), NumberKey(time: 0.3, value: 1.1), NumberKey(time: 1, value: 0)]
            e.color = .from(Vec3(0.4, 0.95, 1), to: Vec3(0.75, 0.4, 1))
            e.lightEmission = 1
            e.rotSpeed = SIMD2(-90, 90)
        case .confetti:
            // Nothing until a script says Emit.
            e.name = "Confetti"
            e.texture = "builtin://Confetti"
            e.rate = 0
            e.lifetime = SIMD2(2, 3)
            // Thrown up, then drifting down slowly (drag keeps them under 5 studs a second).
            e.speed = SIMD2(20, 30)
            e.spreadAngle = SIMD2(35, 35)
            e.acceleration = Vec3(0, -12, 0)
            e.drag = 2.5
            e.size = .from(0.5, to: 0.4)
            e.transparency = [NumberKey(time: 0, value: 0), NumberKey(time: 0.8, value: 0), NumberKey(time: 1, value: 1)]
            e.color = [ColorKey(time: 0, color: Vec3(1, 0.3, 0.45)), ColorKey(time: 0.33, color: Vec3(1, 0.85, 0.2)),
                       ColorKey(time: 0.66, color: Vec3(0.3, 0.8, 1)), ColorKey(time: 1, color: Vec3(0.5, 1, 0.4))]
            e.rotation = SIMD2(0, 360)
            e.rotSpeed = SIMD2(-300, 300)
        }
        return e
    }
}

/// Where an emitter is: its part, and itself.
struct EmitterRef: Hashable {
    let part: UUID
    let emitter: UUID
}

extension SceneModel {
    func emitter(_ ref: EmitterRef) -> ParticleEmitter? {
        part(id: ref.part)?.emitters.first { $0.id == ref.emitter }
    }

    /// Adds an emitter to a part, picked, in one step to undo.
    @discardableResult
    func addEmitter(_ preset: ParticleEmitter.Preset = .sparkles, to partID: UUID) -> EmitterRef? {
        guard part(id: partID) != nil else { return nil }
        let emitter = ParticleEmitter.preset(preset)
        commit("Add \(emitter.name)") {
            update(id: partID) { $0.emitters.append(emitter) }
        }
        let ref = EmitterRef(part: partID, emitter: emitter.id)
        selectedEmitter = ref
        return ref
    }

    func updateEmitter(_ ref: EmitterRef, _ body: (inout ParticleEmitter) -> Void) {
        update(id: ref.part) { part in
            guard let index = part.emitters.firstIndex(where: { $0.id == ref.emitter }) else { return }
            body(&part.emitters[index])
        }
    }

    func removeEmitter(_ ref: EmitterRef) {
        guard let emitter = emitter(ref) else { return }
        commit("Deleted \(emitter.name)") {
            update(id: ref.part) { $0.emitters.removeAll { $0.id == ref.emitter } }
        }
        if selectedEmitter == ref { selectedEmitter = nil }
    }
}
