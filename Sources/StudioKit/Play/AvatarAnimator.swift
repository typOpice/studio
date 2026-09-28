import Foundation
import simd

/// Joint rotations for the six-part body, in radians, as Euler angles about the
/// character's own axes (it faces −Z). An arm or leg hangs straight down at zero;
/// a positive X swings it forward, and positive Z swings it towards +X.
struct AvatarJoints: Equatable, Codable {
    var leftShoulder = Vec3.zero
    var rightShoulder = Vec3.zero
    var leftHip = Vec3.zero
    var rightHip = Vec3.zero
    var neck = Vec3.zero
    /// Upper body leaning about the hips; negative leans forward.
    var lean: Float = 0
    /// The RootJoint: the whole body turned about its middle (x < 0 tips the head
    /// forward, as when flying) …
    var root = Vec3.zero
    /// … and moved, in studs — the bounce in a stride is `offset.y`.
    var offset = Vec3.zero

    /// The bounce in a stride.
    var bob: Float {
        get { offset.y }
        set { offset.y = newValue }
    }
    /// The whole body's forward tip.
    var pitch: Float {
        get { root.x }
        set { root.x = newValue }
    }

    /// The rotation at a body part's joint, by Roblox name.
    func rotation(for part: String) -> Vec3 {
        switch part {
        case "Left Arm": return leftShoulder
        case "Right Arm": return rightShoulder
        case "Left Leg": return leftHip
        case "Right Leg": return rightHip
        case "Head": return neck
        default: return .zero
        }
    }

    /// `a + b × weight`, for summing weighted poses.
    static func add(_ a: AvatarJoints, _ b: AvatarJoints, _ weight: Float) -> AvatarJoints {
        AvatarJoints(leftShoulder: a.leftShoulder + b.leftShoulder * weight,
                     rightShoulder: a.rightShoulder + b.rightShoulder * weight,
                     leftHip: a.leftHip + b.leftHip * weight,
                     rightHip: a.rightHip + b.rightHip * weight,
                     neck: a.neck + b.neck * weight,
                     lean: a.lean + b.lean * weight,
                     root: a.root + b.root * weight,
                     offset: a.offset + b.offset * weight)
    }

    static func mix(_ a: AvatarJoints, _ b: AvatarJoints, _ t: Float) -> AvatarJoints {
        AvatarJoints(leftShoulder: simd_mix(a.leftShoulder, b.leftShoulder, Vec3(repeating: t)),
                     rightShoulder: simd_mix(a.rightShoulder, b.rightShoulder, Vec3(repeating: t)),
                     leftHip: simd_mix(a.leftHip, b.leftHip, Vec3(repeating: t)),
                     rightHip: simd_mix(a.rightHip, b.rightHip, Vec3(repeating: t)),
                     neck: simd_mix(a.neck, b.neck, Vec3(repeating: t)),
                     lean: a.lean + (b.lean - a.lean) * t,
                     root: simd_mix(a.root, b.root, Vec3(repeating: t)),
                     offset: simd_mix(a.offset, b.offset, Vec3(repeating: t)))
    }
}

/// Animates the avatar from what the Humanoid is doing: idle breathing, a walk that
/// quickens and widens with speed, arms up for a jump or a fall, a flying pose and a
/// slump on death.
///
/// Each state is an animation evaluated fresh every frame; switching state crossfades
/// their weights rather than easing the joints, so a walk cycle plays at full size
/// while a change of state still never snaps. Speed is smoothed too, so starting to
/// walk grows the stride instead of popping into it.
///
/// Pure Swift and deterministic, so it is tested headless. To add an animation, add a
/// case to `target(...)` — the crossfade comes for free.
struct AvatarAnimator {
    private(set) var joints = AvatarJoints()
    private(set) var time: Float = 0
    private(set) var stridePhase: Float = 0
    private(set) var smoothedSpeed: Float = 0
    /// How much of each state's animation is showing; sums to 1.
    private(set) var weights: [HumanoidStateType: Float] = [.running: 1]

    /// How quickly a new state fades in, per second.
    static let blendRate: Float = 10
    /// How quickly the stride follows a change of speed, per second.
    static let speedRate: Float = 8
    /// Stride phase advanced per stud travelled: at 16 studs/s about 1.4 strides a second.
    static let strideRate: Float = 0.55
    static let armsUp: Float = 2.8

    mutating func update(dt: Float, state: HumanoidStateType, horizontalSpeed: Float,
                         verticalVelocity: Float) {
        time += dt
        stridePhase += horizontalSpeed * dt * Self.strideRate
        smoothedSpeed += (horizontalSpeed - smoothedSpeed) * (1 - exp(-Self.speedRate * dt))

        // Landing plays the running animation; everything else is its own.
        let active: HumanoidStateType = state == .landed ? .running : state
        let fade = 1 - exp(-Self.blendRate * dt)
        var next: [HumanoidStateType: Float] = [:]
        for key in Set(weights.keys).union([active]) {
            let current = weights[key] ?? 0
            let goal: Float = key == active ? 1 : 0
            let value = current + (goal - current) * fade
            if value > 1e-3 || key == active { next[key] = value }
        }
        let total = next.values.reduce(0, +)
        weights = next.mapValues { $0 / total }

        // Sorted, so the floating-point sum is the same every run.
        var pose = AvatarJoints()
        for (key, weight) in weights.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let goal = target(state: key, speed: smoothedSpeed, verticalVelocity: verticalVelocity)
            pose = AvatarJoints.add(pose, goal, weight)
        }
        joints = pose
    }

    /// The pose for a state at this moment.
    func target(state: HumanoidStateType, speed: Float, verticalVelocity: Float) -> AvatarJoints {
        var pose = AvatarJoints()
        // Breathing and a slow glance around, under everything else.
        let breath = sin(time * 1.8)
        pose.bob = breath * 0.025
        pose.neck = Vec3(0, sin(time * 0.37) * 0.12, 0)
        pose.leftShoulder = Vec3(breath * 0.03, 0, -0.06)
        pose.rightShoulder = Vec3(breath * 0.03, 0, 0.06)

        switch state {
        case .running, .landed:
            guard speed > 0.3 else { break }
            // Amplitude grows with speed, capped around a sprint.
            let strength = min(speed / 16, 1.5)
            let swing = sin(stridePhase * 2) * 0.75 * strength
            pose.leftHip = Vec3(swing, 0, 0)
            pose.rightHip = Vec3(-swing, 0, 0)
            pose.leftShoulder = Vec3(-swing * 0.9, 0, -0.08)
            pose.rightShoulder = Vec3(swing * 0.9, 0, 0.08)
            pose.bob = abs(sin(stridePhase * 2)) * 0.12 * strength
            pose.lean = -0.08 * strength
            pose.neck = Vec3(0.05 * strength, 0, 0)

        case .jumping:
            pose.leftShoulder = Vec3(Self.armsUp, 0, -0.15)
            pose.rightShoulder = Vec3(Self.armsUp, 0, 0.15)
            pose.leftHip = Vec3(0.25, 0, 0)
            pose.rightHip = Vec3(-0.1, 0, 0)

        case .freefall:
            // Arms up and flailing a little; legs dangling apart.
            let flail = sin(time * 9) * 0.12
            pose.leftShoulder = Vec3(Self.armsUp - 0.3 + flail, 0, -0.35)
            pose.rightShoulder = Vec3(Self.armsUp - 0.3 - flail, 0, 0.35)
            pose.leftHip = Vec3(0.2, 0, -0.12)
            pose.rightHip = Vec3(-0.15, 0, 0.12)
            pose.neck = Vec3(verticalVelocity < -40 ? -0.25 : 0, 0, 0)

        case .flying:
            // Head first, arms stretched out ahead.
            pose.pitch = -1.25
            pose.leftShoulder = Vec3(2.95, 0, -0.1)
            pose.rightShoulder = Vec3(2.95, 0, 0.1)
            pose.leftHip = Vec3(-0.08 + sin(time * 3) * 0.08, 0, 0)
            pose.rightHip = Vec3(-0.08 - sin(time * 3) * 0.08, 0, 0)
            pose.neck = Vec3(0.9, 0, 0)
            pose.bob = 0

        case .seated:
            // Legs out along the seat, hands resting forward.
            pose.leftHip = Vec3(.pi / 2, 0, -0.05)
            pose.rightHip = Vec3(.pi / 2, 0, 0.05)
            pose.leftShoulder = Vec3(0.45, 0, -0.1)
            pose.rightShoulder = Vec3(0.45, 0, 0.1)
            pose.bob = 0

        case .climbing:
            // Hand over hand, knees stepping up, in time with the climb.
            let reach = sin(stridePhase * 3 + time * 0.001)
            pose.leftShoulder = Vec3(Self.armsUp - 0.5 + reach * 0.45, 0, -0.1)
            pose.rightShoulder = Vec3(Self.armsUp - 0.5 - reach * 0.45, 0, 0.1)
            pose.leftHip = Vec3(0.35 + reach * 0.35, 0, 0)
            pose.rightHip = Vec3(0.35 - reach * 0.35, 0, 0)
            pose.bob = 0

        case .swimming:
            // Lying forward in the water, arms stroking, legs kicking.
            let stroke = time * 4
            pose.pitch = -1.1
            pose.leftShoulder = Vec3(1.5 + sin(stroke) * 1.3, 0, -0.2)
            pose.rightShoulder = Vec3(1.5 + sin(stroke + .pi) * 1.3, 0, 0.2)
            pose.leftHip = Vec3(sin(time * 8) * 0.3, 0, 0)
            pose.rightHip = Vec3(-sin(time * 8) * 0.3, 0, 0)
            pose.neck = Vec3(0.9, 0, 0)
            pose.bob = 0

        case .dead:
            pose = AvatarJoints()
            pose.leftShoulder = Vec3(0.3, 0, -0.9)
            pose.rightShoulder = Vec3(0.2, 0, 1.0)
            pose.leftHip = Vec3(0, 0, -0.25)
            pose.rightHip = Vec3(0, 0, 0.3)
        }
        return pose
    }
}

/// The built-in animations as tracks a script can load ("builtin://Walk" and the rest):
/// the poses `AvatarAnimator` makes for each state, live — the walk's stride follows the
/// character's speed. The default Animate core script plays them as the Humanoid's
/// state changes; a game's own Animate can play them, or its own, instead.
enum BuiltinAnimation: String, CaseIterable {
    case idle = "Idle", walk = "Walk", jump = "Jump", fall = "Fall", climb = "Climb", swim = "Swim"
    case sit = "Sit", fly = "Fly"

    var reference: String { "builtin://" + rawValue }

    /// A stable id, so a track names it as it names a custom animation.
    var id: UUID {
        let index = Self.allCases.firstIndex(of: self)! + 1
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000A%04X", index))!
    }

    var state: HumanoidStateType {
        switch self {
        case .idle, .walk: return .running
        case .jump: return .jumping
        case .fall: return .freefall
        case .climb: return .climbing
        case .swim: return .swimming
        case .sit: return .seated
        case .fly: return .flying
        }
    }

    /// As a track sees it: looped, Core priority (under everything a game plays), no keys.
    var object: AnimationObject {
        var animation = AnimationObject(name: rawValue)
        animation.id = id
        animation.length = 1
        animation.looped = true
        animation.priority = .core
        return animation
    }

    static func named(_ reference: String) -> BuiltinAnimation? {
        guard reference.lowercased().hasPrefix("builtin://") else { return nil }
        let name = reference.dropFirst("builtin://".count).lowercased()
        return allCases.first { $0.rawValue.lowercased() == name }
    }

    static func withID(_ id: UUID) -> BuiltinAnimation? { allCases.first { $0.id == id } }
}
