import Foundation
import simd

/// The six joints of the R6 body, by their Roblox Motor6D names.
enum AnimationJoint: String, Codable, CaseIterable, Identifiable {
    case rootJoint = "RootJoint"
    case neck = "Neck"
    case leftShoulder = "Left Shoulder"
    case rightShoulder = "Right Shoulder"
    case leftHip = "Left Hip"
    case rightHip = "Right Hip"

    var id: String { rawValue }

    /// The body part the joint moves, which is what you click in the viewport.
    var bodyPart: String {
        switch self {
        case .rootJoint: return "Torso"
        case .neck: return "Head"
        case .leftShoulder: return "Left Arm"
        case .rightShoulder: return "Right Arm"
        case .leftHip: return "Left Leg"
        case .rightHip: return "Right Leg"
        }
    }

    static func joint(forBodyPart name: String) -> AnimationJoint? {
        allCases.first { $0.bodyPart == name }
    }

    /// The same joint on the other side; the root and neck are their own mirror.
    var mirrored: AnimationJoint {
        switch self {
        case .leftShoulder: return .rightShoulder
        case .rightShoulder: return .leftShoulder
        case .leftHip: return .rightHip
        case .rightHip: return .leftHip
        default: return self
        }
    }

    /// Only the root moves as well as turns: it carries the whole body.
    var hasPosition: Bool { self == .rootJoint }
}

/// How a key eases into the next one — Roblox's pose easing styles.
enum AnimationEasing: String, Codable, CaseIterable, Identifiable {
    case linear = "Linear"
    case constant = "Constant"
    case cubic = "Cubic"
    case elastic = "Elastic"
    case bounce = "Bounce"

    var id: String { rawValue }

    /// Progress from 0 to 1 at `t`.
    func apply(_ t: Float) -> Float {
        let t = min(max(t, 0), 1)
        switch self {
        case .linear: return t
        case .constant: return 0
        case .cubic: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .elastic:
            if t == 0 || t == 1 { return t }
            return pow(2, -10 * t) * sin((t * 10 - 0.75) * (2 * .pi / 3)) + 1
        case .bounce:
            let n: Float = 7.5625, d: Float = 2.75
            if t < 1 / d { return n * t * t }
            if t < 2 / d { let u = t - 1.5 / d; return n * u * u + 0.75 }
            if t < 2.5 / d { let u = t - 2.25 / d; return n * u * u + 0.9375 }
            let u = t - 2.625 / d
            return n * u * u + 0.984375
        }
    }
}

/// Roblox's AnimationPriority: a higher one overrides a lower one on the joints it keys.
enum AnimationPriority: String, Codable, CaseIterable, Identifiable, Comparable {
    case core = "Core"
    case idle = "Idle"
    case movement = "Movement"
    case action = "Action"

    var id: String { rawValue }
    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

/// One joint's pose at one moment. Rotation in degrees, about the character's own
/// axes: +X swings a limb forward, +Z towards the character's right (+X), +Y twists.
struct JointKey: Codable, Equatable, Identifiable {
    var id = UUID()
    var time: Float
    var rotation = Vec3.zero
    /// Studs; used by the RootJoint only.
    var position = Vec3.zero
    var easing = AnimationEasing.cubic

    private enum CodingKeys: String, CodingKey { case time, rotation, position, easing }

    init(time: Float, rotation: Vec3 = .zero, position: Vec3 = .zero, easing: AnimationEasing = .cubic) {
        self.time = time
        self.rotation = rotation
        self.position = position
        self.easing = easing
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Float.self, forKey: .time)
        rotation = try c.decodeIfPresent(Vec3.self, forKey: .rotation) ?? .zero
        position = try c.decodeIfPresent(Vec3.self, forKey: .position) ?? .zero
        easing = try c.decodeIfPresent(AnimationEasing.self, forKey: .easing) ?? .cubic
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(time, forKey: .time)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(position, forKey: .position)
        try c.encode(easing, forKey: .easing)
    }

    static func == (a: JointKey, b: JointKey) -> Bool {
        a.time == b.time && a.rotation == b.rotation && a.position == b.position && a.easing == b.easing
    }
}

/// A named moment in an animation; reaching it fires `KeyframeReached` and the
/// track's marker signal.
struct AnimationMarker: Codable, Equatable, Identifiable {
    var id = UUID()
    var time: Float
    var name: String

    private enum CodingKeys: String, CodingKey { case time, name }

    init(time: Float, name: String) {
        self.time = time
        self.name = name
    }

    static func == (a: AnimationMarker, b: AnimationMarker) -> Bool { a.time == b.time && a.name == b.name }
}

/// What an animation says about one joint at one moment, in radians and studs.
struct SampledJoint: Equatable {
    var rotation: Vec3
    var position: Vec3
}

/// A custom animation made in the Animation Editor: keys per joint, plus markers.
/// A joint with no keys is left to whatever else is animating it.
struct AnimationObject: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Animation"
    var length: Float = 1
    var looped = false
    var priority = AnimationPriority.action
    /// Keys per joint, by the joint's Roblox name, kept sorted by time.
    var keys: [String: [JointKey]] = [:]
    var markers: [AnimationMarker] = []

    static let minimumLength: Float = 0.1
    static let maximumLength: Float = 60

    private enum CodingKeys: String, CodingKey { case id, name, length, looped, priority, keys, markers }

    init(name: String = "Animation") {
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Animation"
        length = try c.decodeIfPresent(Float.self, forKey: .length) ?? 1
        looped = try c.decodeIfPresent(Bool.self, forKey: .looped) ?? false
        priority = try c.decodeIfPresent(AnimationPriority.self, forKey: .priority) ?? .action
        keys = try c.decodeIfPresent([String: [JointKey]].self, forKey: .keys) ?? [:]
        markers = try c.decodeIfPresent([AnimationMarker].self, forKey: .markers) ?? []
    }

    func keys(for joint: AnimationJoint) -> [JointKey] { keys[joint.rawValue] ?? [] }

    var isEmpty: Bool { keys.values.allSatisfy(\.isEmpty) }

    // MARK: - Editing

    /// Keys closer together than this are the same key.
    static let timeTolerance: Float = 0.001

    func keyIndex(for joint: AnimationJoint, at time: Float) -> Int? {
        keys(for: joint).firstIndex { abs($0.time - time) < Self.timeTolerance }
    }

    /// Sets the joint's pose at `time`, adding a key there or changing the one there.
    mutating func setKey(_ joint: AnimationJoint, at time: Float, rotation: Vec3, position: Vec3? = nil) {
        let time = min(max(time, 0), length)
        var list = keys(for: joint)
        if let index = list.firstIndex(where: { abs($0.time - time) < Self.timeTolerance }) {
            list[index].rotation = rotation
            if let position { list[index].position = position }
        } else {
            list.append(JointKey(time: time, rotation: rotation, position: position ?? .zero))
            list.sort { $0.time < $1.time }
        }
        keys[joint.rawValue] = list
    }

    mutating func removeKey(_ joint: AnimationJoint, at time: Float) {
        guard var list = keys[joint.rawValue] else { return }
        list.removeAll { abs($0.time - time) < Self.timeTolerance }
        keys[joint.rawValue] = list.isEmpty ? nil : list
    }

    /// Moves a key in time; a key already at the destination is replaced.
    mutating func moveKey(_ joint: AnimationJoint, from old: Float, to new: Float) {
        guard var list = keys[joint.rawValue],
              let index = list.firstIndex(where: { abs($0.time - old) < Self.timeTolerance }) else { return }
        let destination = min(max(new, 0), length)
        var key = list.remove(at: index)
        key.time = destination
        list.removeAll { abs($0.time - destination) < Self.timeTolerance }
        list.append(key)
        list.sort { $0.time < $1.time }
        keys[joint.rawValue] = list
    }

    mutating func setEasing(_ joint: AnimationJoint, at time: Float, _ easing: AnimationEasing) {
        guard var list = keys[joint.rawValue],
              let index = list.firstIndex(where: { abs($0.time - time) < Self.timeTolerance }) else { return }
        list[index].easing = easing
        keys[joint.rawValue] = list
    }

    /// Changes the length; keys and markers past the new end are dropped.
    mutating func setLength(_ value: Float) {
        length = min(max(value, Self.minimumLength), Self.maximumLength)
        for (name, list) in keys {
            let kept = list.filter { $0.time <= length + Self.timeTolerance }
            keys[name] = kept.isEmpty ? nil : kept
        }
        markers.removeAll { $0.time > length + Self.timeTolerance }
    }

    /// Copies each key on one side to the other, flipping it so the pose is mirrored.
    mutating func mirror(_ joint: AnimationJoint) {
        let target = joint.mirrored
        guard target != joint else { return }
        keys[target.rawValue] = keys(for: joint).map { key in
            var copy = key
            copy.id = UUID()
            copy.rotation = Vec3(key.rotation.x, -key.rotation.y, -key.rotation.z)
            return copy
        }
    }

    // MARK: - Playing

    /// The joint's pose at `time`, or nil when the animation doesn't key it. Before the
    /// first key and after the last, the nearest key holds. Between two keys, the
    /// earlier key's easing shapes the way to the later one.
    func sample(_ joint: AnimationJoint, at time: Float) -> SampledJoint? {
        let list = keys(for: joint)
        guard let first = list.first, let last = list.last else { return nil }
        let pose: (Vec3, Vec3)
        if time <= first.time {
            pose = (first.rotation, first.position)
        } else if time >= last.time {
            pose = (last.rotation, last.position)
        } else {
            let next = list.firstIndex { $0.time > time }!
            let a = list[next - 1], b = list[next]
            let t = a.easing.apply((time - a.time) / max(b.time - a.time, 1e-6))
            pose = (a.rotation + (b.rotation - a.rotation) * t, a.position + (b.position - a.position) * t)
        }
        return SampledJoint(rotation: pose.0 * (.pi / 180), position: pose.1)
    }

    /// Every keyed joint's pose at `time`.
    func sample(at time: Float) -> [AnimationJoint: SampledJoint] {
        var result: [AnimationJoint: SampledJoint] = [:]
        for joint in AnimationJoint.allCases {
            if let pose = sample(joint, at: time) { result[joint] = pose }
        }
        return result
    }

    // MARK: - Examples

    /// A friendly wave with the right arm, used by the Explorer's "Example: Wave".
    static func waveExample() -> AnimationObject {
        var wave = AnimationObject(name: "Wave")
        wave.length = 1.6
        wave.priority = .action
        let arm = AnimationJoint.rightShoulder
        wave.keys[arm.rawValue] = [
            JointKey(time: 0, rotation: Vec3(0, 0, 0)),
            JointKey(time: 0.3, rotation: Vec3(0, 0, 150)),
            JointKey(time: 0.55, rotation: Vec3(0, 0, 120)),
            JointKey(time: 0.8, rotation: Vec3(0, 0, 155)),
            JointKey(time: 1.05, rotation: Vec3(0, 0, 120)),
            JointKey(time: 1.3, rotation: Vec3(0, 0, 150)),
            JointKey(time: 1.6, rotation: Vec3(0, 0, 0)),
        ]
        wave.keys[AnimationJoint.neck.rawValue] = [
            JointKey(time: 0, rotation: .zero),
            JointKey(time: 0.4, rotation: Vec3(-8, -20, 6)),
            JointKey(time: 1.2, rotation: Vec3(-8, -20, 6)),
            JointKey(time: 1.6, rotation: .zero),
        ]
        wave.markers = [AnimationMarker(time: 0.3, name: "Hello")]
        return wave
    }
}
