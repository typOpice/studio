import Foundation
import simd

/// The six body-part colours of the classic blocky character.
struct BodyColors: Codable, Equatable {
    var head = Vec3(0.96, 0.80, 0.22)
    var torso = Vec3(0.24, 0.47, 0.78)
    var leftArm = Vec3(0.96, 0.80, 0.22)
    var rightArm = Vec3(0.96, 0.80, 0.22)
    var leftLeg = Vec3(0.30, 0.55, 0.33)
    var rightLeg = Vec3(0.30, 0.55, 0.33)

    /// Body parts by their Roblox names, in drawing order.
    static let partNames = ["Head", "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg"]

    subscript(part: String) -> Vec3? {
        get {
            switch part {
            case "Head": return head
            case "Torso": return torso
            case "Left Arm": return leftArm
            case "Right Arm": return rightArm
            case "Left Leg": return leftLeg
            case "Right Leg": return rightLeg
            default: return nil
            }
        }
        set {
            guard let newValue else { return }
            switch part {
            case "Head": head = newValue
            case "Torso": torso = newValue
            case "Left Arm": leftArm = newValue
            case "Right Arm": rightArm = newValue
            case "Left Leg": leftLeg = newValue
            case "Right Leg": rightLeg = newValue
            default: break
            }
        }
    }
}

enum CameraMode: String, Codable, CaseIterable, Identifiable {
    case classic = "Classic"
    case lockFirstPerson = "LockFirstPerson"
    var id: String { rawValue }
}

/// The template every character is built from — Roblox's StarterPlayer.
///
/// Saved with the scene. Each new character copies these into its `Humanoid`, and
/// scripts can then change that character's values at run time without touching
/// the template. To add a setting: add the property with its default here, one line
/// in `init(from:)`, and wherever it is applied (usually `Humanoid.init(settings:)`).
/// Older scene files simply lack the key and get the default.
struct StarterPlayerSettings: Codable, Equatable {
    var bodyColors = BodyColors()

    // Humanoid defaults — Roblox's CharacterWalkSpeed, CharacterJumpPower and friends.
    var walkSpeed: Float = 16
    var jumpPower: Float = 50
    var useJumpPower = true
    var jumpHeight: Float = 7.2
    var maxHealth: Float = 100
    var maxSlopeAngle: Float = 89
    var autoRotate = true

    // Camera
    var cameraMode: CameraMode = .classic
    var cameraMinZoomDistance: Float = 0.5
    var cameraMaxZoomDistance: Float = 40

    /// Seconds between dying and the next character appearing (Roblox's Players.RespawnTime).
    var respawnTime: Float = 5

    /// Whether players in a network game bump into each other. On unless the map says
    /// otherwise; players always collide with parts.
    var playersCollide = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case bodyColors, walkSpeed, jumpPower, useJumpPower, jumpHeight, maxHealth, maxSlopeAngle,
             autoRotate, cameraMode, cameraMinZoomDistance, cameraMaxZoomDistance, respawnTime, playersCollide
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StarterPlayerSettings()
        bodyColors = try c.decodeIfPresent(BodyColors.self, forKey: .bodyColors) ?? d.bodyColors
        walkSpeed = try c.decodeIfPresent(Float.self, forKey: .walkSpeed) ?? d.walkSpeed
        jumpPower = try c.decodeIfPresent(Float.self, forKey: .jumpPower) ?? d.jumpPower
        useJumpPower = try c.decodeIfPresent(Bool.self, forKey: .useJumpPower) ?? d.useJumpPower
        jumpHeight = try c.decodeIfPresent(Float.self, forKey: .jumpHeight) ?? d.jumpHeight
        maxHealth = try c.decodeIfPresent(Float.self, forKey: .maxHealth) ?? d.maxHealth
        maxSlopeAngle = try c.decodeIfPresent(Float.self, forKey: .maxSlopeAngle) ?? d.maxSlopeAngle
        autoRotate = try c.decodeIfPresent(Bool.self, forKey: .autoRotate) ?? d.autoRotate
        cameraMode = try c.decodeIfPresent(CameraMode.self, forKey: .cameraMode) ?? d.cameraMode
        cameraMinZoomDistance = try c.decodeIfPresent(Float.self, forKey: .cameraMinZoomDistance) ?? d.cameraMinZoomDistance
        cameraMaxZoomDistance = try c.decodeIfPresent(Float.self, forKey: .cameraMaxZoomDistance) ?? d.cameraMaxZoomDistance
        respawnTime = try c.decodeIfPresent(Float.self, forKey: .respawnTime) ?? d.respawnTime
        playersCollide = try c.decodeIfPresent(Bool.self, forKey: .playersCollide) ?? d.playersCollide
    }
}
