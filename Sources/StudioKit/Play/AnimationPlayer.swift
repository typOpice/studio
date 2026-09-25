import Foundation
import simd

/// One loaded animation on one character — Roblox's AnimationTrack, as state.
struct AnimationTrackState {
    let handle: Int
    let animationID: UUID
    let generation: Int
    var time: Float = 0
    var speed: Float = 1
    /// How much of the track is showing now, and where it is fading to.
    var weight: Float = 0
    var targetWeight: Float = 1
    /// Weight change per second while fading; infinity is instant.
    var fadeRate: Float = .infinity
    var looped: Bool
    var priority: AnimationPriority
    var isPlaying = false
    /// When it was last played; among equal priorities the later one wins.
    var order = 0
    /// True until the first step after Play, so markers at time 0 fire.
    var fresh = false
}

enum AnimationTrackEvent: Equatable {
    case stopped
    case didLoop
    case marker(String)
}

/// Plays custom animations over the built-in ones. Tracks are layered by priority
/// (then by which was played last), and each blends in by its weight on only the
/// joints it keys — so a wave keys the arm and leaves the walk to the legs.
///
/// Pure state, stepped by `PlayController` after `AvatarAnimator`; tested headless.
struct AnimationPlayer {
    private(set) var tracks: [Int: AnimationTrackState] = [:]
    private var nextHandle = 1
    private var playCounter = 0

    static let defaultFade: Float = 0.1

    mutating func load(_ animation: AnimationObject, generation: Int) -> Int {
        let handle = nextHandle
        nextHandle += 1
        tracks[handle] = AnimationTrackState(handle: handle, animationID: animation.id, generation: generation,
                                             looped: animation.looped, priority: animation.priority)
        return handle
    }

    /// Starts the track from the beginning — or, if it is already playing, just fades
    /// it to the new weight and speed.
    mutating func play(_ handle: Int, fadeTime: Float = defaultFade, weight: Float = 1, speed: Float = 1) {
        guard var track = tracks[handle] else { return }
        if !track.isPlaying {
            track.time = speed < 0 ? .infinity : 0
            track.fresh = true
        }
        track.isPlaying = true
        track.speed = speed
        playCounter += 1
        track.order = playCounter
        fade(&track, to: max(weight, 0), over: fadeTime)
        tracks[handle] = track
    }

    /// Stops the track and fades it out. Returns true if it was playing, in which case
    /// `Stopped` should fire.
    @discardableResult
    mutating func stop(_ handle: Int, fadeTime: Float = defaultFade) -> Bool {
        guard var track = tracks[handle] else { return false }
        let wasPlaying = track.isPlaying
        track.isPlaying = false
        fade(&track, to: 0, over: fadeTime)
        tracks[handle] = track
        return wasPlaying
    }

    mutating func adjustWeight(_ handle: Int, _ weight: Float, fadeTime: Float = defaultFade) {
        guard var track = tracks[handle] else { return }
        fade(&track, to: max(weight, 0), over: fadeTime)
        tracks[handle] = track
    }

    mutating func update(_ handle: Int, _ change: (inout AnimationTrackState) -> Void) {
        guard var track = tracks[handle] else { return }
        change(&track)
        tracks[handle] = track
    }

    func track(_ handle: Int) -> AnimationTrackState? { tracks[handle] }

    /// Forgets every track, as when the character they belong to is replaced.
    mutating func removeAll() { tracks.removeAll() }

    private func fade(_ track: inout AnimationTrackState, to weight: Float, over time: Float) {
        track.targetWeight = weight
        track.fadeRate = time > 0 ? max(abs(weight - track.weight), 1e-3) / time : .infinity
    }

    /// Advances every track and returns what happened, in handle order.
    mutating func step(dt: Float, animation: (UUID) -> AnimationObject?) -> [(handle: Int, event: AnimationTrackEvent)] {
        var events: [(Int, AnimationTrackEvent)] = []
        for handle in tracks.keys.sorted() {
            guard var track = tracks[handle] else { continue }
            // Fade.
            if track.weight != track.targetWeight {
                let step = track.fadeRate.isFinite ? track.fadeRate * dt : .infinity
                track.weight = track.weight < track.targetWeight
                    ? min(track.weight + step, track.targetWeight)
                    : max(track.weight - step, track.targetWeight)
            }
            guard track.isPlaying, let source = animation(track.animationID) else {
                tracks[handle] = track
                continue
            }
            let length = max(source.length, 1e-3)
            if track.time.isInfinite { track.time = length }
            let before = track.time
            let wasFresh = track.fresh
            track.fresh = false
            track.time += dt * track.speed

            func markers(from a: Float, to b: Float, inclusiveStart: Bool) {
                for marker in source.markers.sorted(by: { $0.time < $1.time })
                where (inclusiveStart ? marker.time >= a : marker.time > a) && marker.time <= b {
                    events.append((handle, .marker(marker.name)))
                }
            }

            if track.speed >= 0 {
                if track.time >= length {
                    markers(from: before, to: length, inclusiveStart: wasFresh)
                    if track.looped {
                        while track.time >= length { track.time -= length }
                        events.append((handle, .didLoop))
                        markers(from: 0, to: track.time, inclusiveStart: true)
                    } else {
                        track.time = length
                        track.isPlaying = false
                        fade(&track, to: 0, over: Self.defaultFade)
                        events.append((handle, .stopped))
                    }
                } else {
                    markers(from: before, to: track.time, inclusiveStart: wasFresh)
                }
            } else if track.time <= 0 {
                // Playing backwards: loop or stop at the start.
                if track.looped {
                    while track.time <= 0 { track.time += length }
                    events.append((handle, .didLoop))
                } else {
                    track.time = 0
                    track.isPlaying = false
                    fade(&track, to: 0, over: Self.defaultFade)
                    events.append((handle, .stopped))
                }
            }
            tracks[handle] = track
        }
        return events
    }

    /// Layers every visible track over `base`.
    func apply(to base: AvatarJoints, animation: (UUID) -> AnimationObject?) -> AvatarJoints {
        var joints = base
        let visible = tracks.values.filter { $0.weight > 0 }
            .sorted { ($0.priority, $0.order) < ($1.priority, $1.order) }
        for track in visible {
            guard let source = animation(track.animationID) else { continue }
            let weight = min(track.weight, 1)
            let time = min(max(track.time.isFinite ? track.time : source.length, 0), source.length)
            for (joint, pose) in source.sample(at: time) {
                Self.blend(&joints, joint, pose, weight)
            }
        }
        return joints
    }

    static func blend(_ joints: inout AvatarJoints, _ joint: AnimationJoint, _ pose: SampledJoint, _ weight: Float) {
        let w = Vec3(repeating: weight)
        switch joint {
        case .rootJoint:
            joints.root = simd_mix(joints.root, pose.rotation, w)
            joints.offset = simd_mix(joints.offset, pose.position, w)
        case .neck: joints.neck = simd_mix(joints.neck, pose.rotation, w)
        case .leftShoulder: joints.leftShoulder = simd_mix(joints.leftShoulder, pose.rotation, w)
        case .rightShoulder: joints.rightShoulder = simd_mix(joints.rightShoulder, pose.rotation, w)
        case .leftHip: joints.leftHip = simd_mix(joints.leftHip, pose.rotation, w)
        case .rightHip: joints.rightHip = simd_mix(joints.rightHip, pose.rotation, w)
        }
    }

    /// An animation on its own, at one moment — what the Animation Editor previews.
    static func pose(_ animation: AnimationObject, at time: Float) -> AvatarJoints {
        var joints = AvatarJoints()
        for (joint, pose) in animation.sample(at: time) {
            blend(&joints, joint, pose, 1)
        }
        return joints
    }
}
