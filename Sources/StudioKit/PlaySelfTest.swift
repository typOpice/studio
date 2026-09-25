import Foundation
import simd

/// Verification for the play client: collision geometry, the character controller
/// and the player camera. Exercised by `StudioApp --selftest`.
/// Reports one assertion; `detail` is optional so simple checks stay terse.
struct Checker {
    let emit: (String, Bool, String) -> Void
    func callAsFunction(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        emit(name, condition, detail())
    }
}

enum PlaySelfTest {

    static func run(check: Checker) {
        let c = check
        testClosestPoints(c)
        testCameraConvention(c)
        testStandingOnGround(c)
        testWalls(c)
        testStepUp(c)
        testRamp(c)
        testJump(c)
        testThinFloor(c)
        testFlyAndRespawn(c)
    }

    // MARK: - Helpers

    private static func near(_ a: Float, _ b: Float, _ tol: Float = 1e-3) -> Bool { abs(a - b) <= tol }

    private static func block(_ position: Vec3, _ size: Vec3, yaw: Float = 0) -> Part {
        var part = Part()
        part.shape = .block
        part.position = position
        part.size = size
        if yaw != 0 { part.rotationDegrees = Vec3(0, yaw, 0) }
        return part
    }

    /// Run the character for `seconds` of simulated time at a fixed 120 Hz.
    private static func simulate(_ character: inout CharacterController,
                                 seconds: Float,
                                 input: MoveInput,
                                 parts: [Part]) {
        let dt: Float = 1.0 / 120
        var elapsed: Float = 0
        while elapsed < seconds {
            character.step(dt: dt, input: input, parts: parts)
            elapsed += dt
        }
    }

    private static func walker(at position: Vec3, baseplate: Bool = false) -> CharacterController {
        var character = CharacterController()
        character.position = position
        character.velocity = .zero
        character.solidBaseplate = baseplate
        return character
    }

    // MARK: - Tests

    private static func testClosestPoints(_ check: Checker) {
        print("\nCollision shapes")
        let h = Vec3(2, 1, 3)

        let outside = Collision.closestPointInFrame(Vec3(10, 0, 0), shape: .block, halfExtents: h)
        check("block clamps to its face", near(outside.x, 2) && near(outside.y, 0) && near(outside.z, 0), "\(outside)")

        let inside = Collision.closestPointInFrame(Vec3(0.5, 0, 0), shape: .block, halfExtents: h)
        check("block keeps interior points", near(inside.x, 0.5), "\(inside)")

        let onSphere = Collision.closestPointInFrame(Vec3(10, 0, 0), shape: .sphere, halfExtents: Vec3(2, 2, 2))
        check("sphere clamps to its radius", near(length(onSphere), 2, 0.01), "\(length(onSphere))")

        let onCylinder = Collision.closestPointInFrame(Vec3(10, 5, 0), shape: .cylinder, halfExtents: Vec3(2, 1, 2))
        check("cylinder clamps radius and height",
              near(onCylinder.x, 2, 0.01) && near(onCylinder.y, 1, 0.01), "\(onCylinder)")

        // The wedge's solid half is towards -Z; the +Y/+Z corner is cut away.
        check("wedge contains its thick corner",
              Collision.contains(Vec3(0, 0.8, -0.8), shape: .wedge, halfExtents: Vec3(1, 1, 1)))
        check("wedge excludes the cut corner",
              !Collision.contains(Vec3(0, 0.8, 0.8), shape: .wedge, halfExtents: Vec3(1, 1, 1)))

        // A capsule overlapping a block is pushed straight out of the nearest face.
        var part = block(Vec3(0, 0, 0), Vec3(10, 2, 10))
        part.name = "Floor"
        let capsule = Capsule(base: Vec3(0, 0.5, 0), radius: 1, height: 5)
        let contact = Collision.contact(capsule: capsule, part: part)
        check("capsule overlapping a floor reports a contact", contact != nil)
        if let contact {
            check("contact normal points up", contact.normal.y > 0.99, "\(contact.normal)")
            check("contact depth matches the overlap", near(contact.depth, 0.5, 0.01), "\(contact.depth)")
        }

        // Rotation is honoured: a 45°-yawed slab reaches further along X than its half width.
        // A thin slab yawed 45° runs diagonally, so a point on that diagonal is inside it
        // while the same point misses the unrotated slab entirely.
        let upright = block(Vec3(0, 0, 0), Vec3(8, 2, 1))
        let rotated = block(Vec3(0, 0, 0), Vec3(8, 2, 1), yaw: 45)
        let onDiagonal = Capsule(base: Vec3(2, 0, -2), radius: 1, height: 5)
        check("rotated block collides along its rotated extent",
              Collision.contact(capsule: onDiagonal, part: rotated) != nil)
        check("the same point misses the unrotated block",
              Collision.contact(capsule: onDiagonal, part: upright) == nil)
        // The ground probe casts downwards, so a wedge must answer a downward ray with
        // the slope height and an upward-facing normal.
        var ramp = Part()
        ramp.shape = .wedge
        ramp.position = Vec3(0, 5, -24)
        ramp.size = Vec3(20, 8, 40)     // spans z -44...-4, rising from y = 1 to y = 9
        for (z, expected) in [(Float(-14), Float(3)), (-24, 5), (-34, 7)] {
            let down = Ray(origin: Vec3(0, 20, z), direction: Vec3(0, -1, 0))
            check("downward ray hits the ramp at z \(Int(z))", Picking.intersect(ray: down, part: ramp) != nil)
            if let t = Picking.intersect(ray: down, part: ramp) {
                let point = down.point(at: t)
                check("ramp height at z \(Int(z)) is \(Int(expected))", near(point.y, expected, 0.05), "\(point.y)")
                check("ramp normal at z \(Int(z)) faces up",
                      Collision.surfaceNormal(part: ramp, worldPoint: point).y > 0.5)
            }
        }

        // The probe starts only 2 studs above the feet, which is inside the ramp's
        // bounding box while still above its surface. That case must not report the underside.
        let fromInsideBox = Ray(origin: Vec3(0, 8.6, -32), direction: Vec3(0, -1, 0))
        let insideHit = Picking.intersect(ray: fromInsideBox, part: ramp)
        check("ray starting inside the ramp's bounding box finds the slope", insideHit != nil)
        if let insideHit {
            check("and not the underside", near(fromInsideBox.point(at: insideHit).y, 6.6, 0.1),
                  "\(fromInsideBox.point(at: insideHit).y)")
        }

        let farProbe = Capsule(base: Vec3(9, 0, 0), radius: 1, height: 5)
        check("rotated block does not collide beyond its reach",
              Collision.contact(capsule: farProbe, part: rotated) == nil)
    }

    private static func testCameraConvention(_ check: Checker) {
        print("\nPlayer camera")
        var player = PlayerCamera()
        for (yaw, pitch) in [(Float(0), Float(0)), (1.1, 0.4), (-2.3, -0.7), (3.0, 0.2)] {
            player.yaw = yaw
            player.pitch = pitch
            player.distance = 12
            let camera = player.renderCamera(eye: Vec3(0, 5, 0), parts: [])
            let agree = length(camera.forward - player.forward) < 2e-3
            check("camera faces the player's look direction (yaw \(String(format: "%.1f", yaw)))",
                  agree, "\(camera.forward) vs \(player.forward)")
        }

        player.yaw = 0
        player.pitch = 0
        player.distance = 12
        let third = player.renderCamera(eye: Vec3(0, 5, 0), parts: [])
        check("third person sits behind the eye", near(third.position.z, 12, 0.05), "\(third.position)")
        check("third person is not first person", !player.isFirstPerson)

        player.distance = 0
        let first = player.renderCamera(eye: Vec3(0, 5, 0), parts: [])
        check("first person sits at the eye", length(first.position - Vec3(0, 5, 0)) < 0.05, "\(first.position)")
        check("zoomed all the way in is first person", player.isFirstPerson)

        // The camera pulls in when a wall is between the eye and the ideal position.
        player.distance = 12
        let wall = block(Vec3(0, 5, 6), Vec3(20, 20, 1))
        let clipped = player.renderCamera(eye: Vec3(0, 5, 0), parts: [wall])
        check("camera pulls in past a wall", clipped.distance < 6, "\(clipped.distance)")
    }

    private static func testStandingOnGround(_ check: Checker) {
        print("\nCharacter: standing")
        let floor = block(Vec3(0, 0, 0), Vec3(40, 2, 40))       // top at y = 1
        var character = walker(at: Vec3(0, 20, 0))
        simulate(&character, seconds: 3, input: MoveInput(), parts: [floor])

        check("falls and lands on the floor", near(character.position.y, 1, 0.05), "y = \(character.position.y)")
        check("is grounded after landing", character.grounded, "")
        check("vertical velocity settles", abs(character.velocity.y) < 1.0, "\(character.velocity.y)")

        // The baseplate catches the player when no part is underneath.
        var floater = walker(at: Vec3(0, 30, 0), baseplate: true)
        simulate(&floater, seconds: 4, input: MoveInput(), parts: [])
        check("baseplate stops the fall at y = 0", near(floater.position.y, 0, 0.05), "\(floater.position.y)")
        check("grounded on the baseplate", floater.grounded, "")

        // Walking speed matches Roblox's 16 studs/s.
        var walkerCharacter = walker(at: Vec3(0, 1, 0))
        var input = MoveInput()
        input.forward = 1
        input.cameraYaw = 0        // facing -Z
        let start = walkerCharacter.position
        simulate(&walkerCharacter, seconds: 1, input: input, parts: [floor])
        let travelled = length(Vec3(walkerCharacter.position.x - start.x, 0, walkerCharacter.position.z - start.z))
        check("walks at about 16 studs per second", abs(travelled - 16) < 0.6, "\(travelled)")
        check("walks towards -Z with the default camera", walkerCharacter.position.z < start.z - 10,
              "\(walkerCharacter.position.z)")
    }

    private static func testWalls(_ check: Checker) {
        print("\nCharacter: walls")
        let floor = block(Vec3(0, 0, 0), Vec3(60, 2, 60))
        let wall = block(Vec3(0, 6, -10), Vec3(40, 10, 2))      // spans z = -11 ... -9

        var character = walker(at: Vec3(0, 1, 0))
        var input = MoveInput()
        input.forward = 1
        input.cameraYaw = 0
        simulate(&character, seconds: 3, input: input, parts: [floor, wall])

        check("a tall wall stops the player", character.position.z > -9.1, "z = \(character.position.z)")
        check("the player does not tunnel through", character.position.z > -11, "z = \(character.position.z)")
        check("still grounded while pressed against a wall", character.grounded, "")

        // Sliding: walking diagonally into a wall keeps the along-wall motion.
        var slider = walker(at: Vec3(0, 1, 0))
        var diagonal = MoveInput()
        diagonal.forward = 1
        diagonal.strafe = 1
        diagonal.cameraYaw = 0
        simulate(&slider, seconds: 3, input: diagonal, parts: [floor, wall])
        check("player slides along the wall", slider.position.x > 8, "x = \(slider.position.x)")
    }

    private static func testStepUp(_ check: Checker) {
        print("\nCharacter: steps")
        let floor = block(Vec3(0, 0, 0), Vec3(200, 2, 200))      // top at y = 1

        // A 1.5-stud ledge: top at y = 2.5, which is inside the 2-stud step height.
        let ledge = block(Vec3(0, 1.75, -40), Vec3(60, 1.5, 64))  // spans z = -72 ... -8
        var stepper = walker(at: Vec3(0, 1, 0))
        var input = MoveInput()
        input.forward = 1
        input.cameraYaw = 0
        simulate(&stepper, seconds: 1.2, input: input, parts: [floor, ledge])
        check("climbs a 1.5 stud step", near(stepper.position.y, 2.5, 0.15), "y = \(stepper.position.y)")
        check("ends up on top of the ledge", stepper.position.z < -9, "z = \(stepper.position.z)")

        // A 5-stud wall is too tall to step onto.
        let tall = block(Vec3(0, 3.5, -12), Vec3(30, 5, 8))     // top at y = 6
        var blocked = walker(at: Vec3(0, 1, 0))
        simulate(&blocked, seconds: 1.5, input: input, parts: [floor, tall])
        check("cannot step onto a 5 stud wall", blocked.position.y < 2, "y = \(blocked.position.y)")
        check("is stopped by the 5 stud wall", blocked.position.z > -9, "z = \(blocked.position.z)")
    }

    private static func testRamp(_ check: Checker) {
        print("\nCharacter: ramps")
        let floor = block(Vec3(0, 0, 0), Vec3(200, 2, 200))
        var ramp = Part()
        ramp.shape = .wedge
        // Thick edge at -Z, sloping down to +Z: a ramp you walk up heading -Z.
        // Spans z = -44 ... -4, rising from y = 1 to y = 9.
        ramp.position = Vec3(0, 5, -24)
        ramp.size = Vec3(20, 8, 40)
        ramp.rotationDegrees = .zero

        var climber = walker(at: Vec3(0, 1, 0))
        var input = MoveInput()
        input.forward = 1
        input.cameraYaw = 0
        simulate(&climber, seconds: 2, input: input, parts: [floor, ramp])

        check("walks up the ramp", climber.position.y > 4, "y = \(climber.position.y)")
        check("stays on the surface rather than inside it", climber.grounded,
              "y = \(climber.position.y), z = \(climber.position.z), vy = \(climber.velocity.y)")
        check("does not fall through the ramp", climber.position.y > 0.9, "y = \(climber.position.y)")
    }

    private static func testJump(_ check: Checker) {
        print("\nCharacter: jumping")
        let floor = block(Vec3(0, 0, 0), Vec3(60, 2, 60))
        var character = walker(at: Vec3(0, 1, 0))
        simulate(&character, seconds: 0.4, input: MoveInput(), parts: [floor])
        check("standing before the jump", character.grounded, "")

        var jump = MoveInput()
        jump.jump = true
        var peak: Float = character.position.y
        let dt: Float = 1.0 / 120
        for frame in 0..<200 {
            // Hold jump for the first frame only, the way a tap works.
            character.step(dt: dt, input: frame == 0 ? jump : MoveInput(), parts: [floor])
            peak = max(peak, character.position.y)
        }
        let expected = CharacterController.jumpPower * CharacterController.jumpPower
            / (2 * CharacterController.gravity)
        check("jump height matches jump power", abs((peak - 1) - expected) < 0.8,
              "rose \(peak - 1), expected \(expected)")
        check("lands again", near(character.position.y, 1, 0.05), "y = \(character.position.y)")
        check("grounded after landing", character.grounded, "")

        // No double jumping in mid-air.
        var jumper = walker(at: Vec3(0, 1, 0))
        simulate(&jumper, seconds: 0.3, input: MoveInput(), parts: [floor])
        jumper.step(dt: dt, input: jump, parts: [floor])
        let afterFirst = jumper.velocity.y
        for _ in 0..<20 { jumper.step(dt: dt, input: jump, parts: [floor]) }
        check("cannot jump again while airborne", jumper.velocity.y < afterFirst, "\(jumper.velocity.y)")
    }

    private static func testThinFloor(_ check: Checker) {
        print("\nCharacter: thin geometry")
        // A 0.4-stud plank: thin enough that a careless solver would let the player through.
        let plank = block(Vec3(0, 0, 0), Vec3(200, 0.4, 200))
        var character = walker(at: Vec3(0, 12, 0))
        simulate(&character, seconds: 4, input: MoveInput(), parts: [plank])
        check("lands on a thin plank instead of falling through",
              near(character.position.y, 0.2, 0.05), "y = \(character.position.y)")

        // Running at full speed across a narrow beam still collides every frame.
        var runner = walker(at: Vec3(0, 0.2, 20))
        var input = MoveInput()
        input.forward = 1
        input.sprint = true
        input.cameraYaw = 0
        simulate(&runner, seconds: 2, input: input, parts: [plank])
        check("stays on the plank while sprinting", runner.position.y > 0.1, "y = \(runner.position.y)")
    }

    private static func testFlyAndRespawn(_ check: Checker) {
        print("\nCharacter: fly and respawn")
        var character = walker(at: Vec3(0, 10, 0))
        var input = MoveInput()
        input.fly = true
        input.flyUp = 1
        simulate(&character, seconds: 1, input: input, parts: [])
        check("flying ignores gravity and climbs", character.position.y > 30, "y = \(character.position.y)")

        var faller = walker(at: Vec3(0, 5, 0))
        faller.spawnPoint = Vec3(3, 7, 3)
        simulate(&faller, seconds: 8, input: MoveInput(), parts: [])
        check("falling into the void respawns", faller.position.y > CharacterController.voidHeight,
              "y = \(faller.position.y)")

        // Spawning picks a point on top of the scene's geometry.
        let model = SceneModel()
        var spawner = CharacterController()
        spawner.chooseSpawn(in: model.parts)
        check("spawn is above the ground", spawner.position.y >= 0, "\(spawner.position)")
        let capsule = Capsule(base: spawner.position, radius: CharacterController.capsuleRadius,
                              height: CharacterController.capsuleHeight)
        let embedded = model.parts.contains { Collision.contact(capsule: capsule, part: $0)?.depth ?? 0 > 0.35 }
        check("spawn is not buried inside a part", !embedded, "")
    }
}
