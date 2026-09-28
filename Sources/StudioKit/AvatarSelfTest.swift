import Foundation
import simd

/// Verification for the avatar: its meshes, where each body part is placed, and the
/// animations `AvatarAnimator` produces. All headless — poses are plain matrices.
enum AvatarSelfTest {

    static func run(check: Checker) {
        testMeshes(check)
        testRestPose(check)
        testFacing(check)
        testWalking(check)
        testAirborneAndFlying(check)
        testBlending(check)
        testDeath(check)
        testInPlay(check)
    }

    private static func centre(_ matrix: float4x4) -> Vec3 {
        let p = matrix * SIMD4<Float>(0, 0, 0, 1)
        return Vec3(p.x, p.y, p.z)
    }

    private static func point(_ matrix: float4x4, _ local: Vec3) -> Vec3 {
        let p = matrix * SIMD4<Float>(local.x, local.y, local.z, 1)
        return Vec3(p.x, p.y, p.z)
    }

    private static func transforms(_ pose: AvatarPose) -> [String: float4x4] {
        Dictionary(uniqueKeysWithValues: pose.partTransforms().map { ($0.name, $0.matrix) })
    }

    /// Runs the animator in one state and returns every pose it went through.
    private static func animate(_ animator: inout AvatarAnimator, _ state: HumanoidStateType,
                                speed: Float = 0, seconds: Float, vertical: Float = 0) -> [AvatarJoints] {
        var poses: [AvatarJoints] = []
        var elapsed: Float = 0
        while elapsed < seconds {
            animator.update(dt: 1.0 / 60, state: state, horizontalSpeed: speed, verticalVelocity: vertical)
            poses.append(animator.joints)
            elapsed += 1.0 / 60
        }
        return poses
    }

    private static func testMeshes(_ check: Checker) {
        print("\nAvatar: meshes")
        let size = Vec3(2, 2, 1)
        let (box, _) = MeshFactory.roundedBox(size: size, radius: 0.2)
        let reach = box.reduce(Vec3.zero) { simd_max($0, abs($1.position)) }
        check("a rounded box fills exactly its size", simd_distance(reach, size * 0.5) < 1e-4, "\(reach)")
        let corner = box.map { length($0.position) }.max() ?? 0
        check("…with its corners rounded off", corner < length(size * 0.5) - 0.05, "\(corner)")

        let (head, _) = MeshFactory.head()
        let radius = head.map { length(Vec3($0.position.x, 0, $0.position.z)) }.max() ?? 0
        let height = (head.map(\.position.y).max() ?? 0) - (head.map(\.position.y).min() ?? 0)
        check("the head is a rounded cylinder of the head's size",
              abs(radius - 0.62) < 1e-3 && abs(height - 1.25) < 1e-3, "r \(radius) h \(height)")

        let (face, _) = MeshFactory.face()
        check("the face is on the front of the head (−Z)", face.allSatisfy { $0.position.z < -0.3 })
        let inside = face.filter { length(Vec3($0.position.x, 0, $0.position.z)) < 0.62 }.count
        check("…half-sunk into it, neither floating nor buried",
              inside > face.count / 5 && inside < face.count * 4 / 5, "\(inside) of \(face.count) inside")
    }

    private static func testRestPose(_ check: Checker) {
        print("\nAvatar: the body")
        let pose = AvatarPose(position: Vec3(10, 3, -4), yaw: 0)
        let parts = transforms(pose)
        for part in AvatarPose.bodyParts {
            let expected = part.swing != 0 ? part.joint - Vec3(0, part.size.y * 0.5, 0) : part.joint
            let actual = centre(parts[part.name]!) - pose.position
            check("\(part.name) sits where the body table says", simd_distance(actual, expected) < 1e-4,
                  "\(actual) vs \(expected)")
        }
        let foot = point(parts["Left Leg"]!, Vec3(0, -1, 0))
        check("the feet are at the character's position", abs(foot.y - pose.position.y) < 1e-4, "\(foot)")
    }

    private static func testFacing(_ check: Checker) {
        for yaw: Float in [0, Float.pi / 2, 2.4] {
            let pose = AvatarPose(position: .zero, yaw: yaw)
            let head = transforms(pose)["Head"]!
            let faceDirection = normalize(point(head, Vec3(0, 0, -1)) - centre(head))
            let forward = Vec3(-sin(yaw), 0, -cos(yaw))    // CharacterController's facing
            check("the face looks the way the character walks (yaw \(yaw))",
                  simd_distance(faceDirection, forward) < 1e-3, "\(faceDirection) vs \(forward)")
        }
    }

    private static func testWalking(_ check: Checker) {
        print("\nAvatar: animation")
        var animator = AvatarAnimator()
        _ = animate(&animator, .running, speed: 16, seconds: 0.5)
        let walk = animate(&animator, .running, speed: 16, seconds: 1)
        let widest = walk.map { abs($0.leftHip.x) }.max() ?? 0
        check("walking swings the legs", widest > 0.5, "\(widest)")
        check("…in opposite directions", walk.allSatisfy { abs($0.leftHip.x + $0.rightHip.x) < 1e-4 })
        check("…with each arm against its leg",
              walk.filter { abs($0.leftHip.x) > 0.2 }.allSatisfy { ($0.leftHip.x > 0) != ($0.leftShoulder.x > 0) })
        check("…and a bounce in the step", (walk.map(\.bob).max() ?? 0) > 0.06)

        var slow = AvatarAnimator()
        _ = animate(&slow, .running, speed: 6, seconds: 0.5)
        let stroll = animate(&slow, .running, speed: 6, seconds: 1).map { abs($0.leftHip.x) }.max() ?? 0
        check("a slower walk is a smaller stride", stroll < widest * 0.6, "\(stroll) vs \(widest)")

        let stopped = animate(&animator, .running, speed: 0, seconds: 0.6).last!
        check("stopping brings the legs together", abs(stopped.leftHip.x) < 0.03, "\(stopped.leftHip)")
        let breathing = animate(&animator, .running, speed: 0, seconds: 2).map(\.bob)
        check("standing still still breathes", (breathing.max() ?? 0) - (breathing.min() ?? 0) > 0.02)
    }

    private static func testAirborneAndFlying(_ check: Checker) {
        var animator = AvatarAnimator()
        let jump = animate(&animator, .jumping, seconds: 0.3).last!
        check("jumping throws the arms up", jump.leftShoulder.x > 2.3 && jump.rightShoulder.x > 2.3, "\(jump)")
        let parts = transforms(AvatarPose(position: .zero, yaw: 0, joints: jump))
        let hand = point(parts["Left Arm"]!, Vec3(0, -1, 0))
        check("…above the head", hand.y > 4.65, "\(hand)")

        let fall = animate(&animator, .freefall, seconds: 0.4, vertical: -60).last!
        check("falling keeps them up and spreads them",
              fall.leftShoulder.x > 2 && fall.leftShoulder.z < -0.2 && fall.rightShoulder.z > 0.2, "\(fall)")

        let fly = animate(&animator, .flying, seconds: 0.5).last!
        check("flying pitches the body head-first", fly.pitch < -1, "\(fly.pitch)")
        let flying = transforms(AvatarPose(position: .zero, yaw: 0, joints: fly))
        check("…with the head ahead of the feet",
              centre(flying["Head"]!).z < centre(flying["Left Leg"]!).z - 2, "\(centre(flying["Head"]!))")
    }

    private static func testBlending(_ check: Checker) {
        var animator = AvatarAnimator()
        var previous = animator.joints
        var biggest: Float = 0
        let sequence: [(HumanoidStateType, Float)] = [(.running, 16), (.jumping, 16), (.freefall, 10),
                                                      (.landed, 0), (.flying, 20), (.running, 0), (.dead, 0)]
        for (state, speed) in sequence {
            for pose in animate(&animator, state, speed: speed, seconds: 0.4) {
                for (a, b) in [(pose.leftShoulder, previous.leftShoulder), (pose.leftHip, previous.leftHip),
                               (pose.neck, previous.neck)] {
                    biggest = max(biggest, simd_reduce_max(abs(a - b)))
                }
                biggest = max(biggest, abs(pose.pitch - previous.pitch))
                previous = pose
            }
        }
        // Arms going from mid-swing to over the head is 3.4 rad; unblended that is one frame.
        check("changing state blends rather than snaps", biggest < 0.6, "largest step \(biggest) rad")
    }

    private static func testDeath(_ check: Checker) {
        var animator = AvatarAnimator()
        let joints = animate(&animator, .dead, seconds: 0.5).last!
        var pose = AvatarPose(position: .zero, yaw: 0.7, joints: joints)
        pose.dead = true
        let heights = pose.partTransforms().map { centre($0.matrix).y }
        check("a dead avatar lies on the ground", heights.allSatisfy { $0 < 1.6 && $0 > -0.2 }, "\(heights)")
    }

    private static func testInPlay(_ check: Checker) {
        let model = SceneModel()
        model.parts = []
        model.scripts = []
        model.shaders = []
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        for _ in 0..<30 { session.step(dt: 1.0 / 60) }
        session.key("Space", pressed: true)
        for _ in 0..<15 { session.step(dt: 1.0 / 60) }
        session.key("Space", pressed: false)
        check("in play, a jump raises the avatar's arms", session.avatars[0].joints.leftShoulder.x > 1.5,
              "\(session.avatars[0].joints.leftShoulder) \(session.humanoid.state)")
        // The pose is the Animate script's tracks (built-in ones), not the animator's own.
        check("the renderer gets the character's pose", session.avatars[0].joints == session.currentJoints)
        session.stop()
    }
}
