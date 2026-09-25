import Foundation
import simd

/// Roblox's HumanoidStateType — the subset the character controller produces.
enum HumanoidStateType: String, CaseIterable {
    case running = "Running"
    case jumping = "Jumping"
    case freefall = "Freefall"
    case landed = "Landed"
    case flying = "Flying"
    case dead = "Dead"
    /// In a Seat, until a jump.
    case seated = "Seated"
    /// Holding onto a truss.
    case climbing = "Climbing"
    /// In water.
    case swimming = "Swimming"
}

/// Something the humanoid did this frame, delivered to scripts at the start of the
/// next frame as the matching event (`humanoid.Died`, `humanoid.StateChanged`, …).
enum HumanoidEvent: Equatable {
    case stateChanged(from: HumanoidStateType, to: HumanoidStateType)
    case jumping
    case freeFalling
    case running(speed: Float)
    case died
    case healthChanged(Float)
    case moveToFinished(reached: Bool)
    /// Sat down in a seat (true, with it) or got up (false).
    case seated(active: Bool, seat: UUID?)
}

/// The character's controller-facing state: what scripts read and write.
///
/// Mirrors Roblox's Humanoid. Physics (`CharacterController`) obeys it — walking
/// where `moveDirection` points at `walkSpeed`, jumping when `jump` is set — and
/// scripts drive it: the default `ControlScript` turns keys into `move` calls, and
/// any script can change `walkSpeed` or deal damage. Nothing here reads the keyboard.
///
/// To add a property: a stored field here (initialised from the template if it has
/// one), a line in `PlayController.humanoidProperty(_:)` and `setHumanoidProperty`,
/// and an entry in the Luau library's `humanoidProperties`.
struct Humanoid {
    var walkSpeed: Float
    var jumpPower: Float
    var useJumpPower: Bool
    var jumpHeight: Float
    var maxHealth: Float
    var maxSlopeAngle: Float
    var autoRotate: Bool

    private(set) var health: Float
    /// World-space direction the character is being asked to move in; its length is
    /// clamped to 1. Horizontal unless flying.
    var moveDirection = Vec3.zero
    /// Set to jump; cleared once the jump happens, as in Roblox.
    var jump = false
    private(set) var state: HumanoidStateType = .running

    /// A point being walked to by `moveTo`, and how long it has been tried for.
    var moveToTarget: Vec3?
    var moveToElapsed: Float = 0
    /// Roblox gives up on MoveTo after eight seconds.
    static let moveToTimeout: Float = 8

    private(set) var events: [HumanoidEvent] = []

    init(settings: StarterPlayerSettings) {
        walkSpeed = settings.walkSpeed
        jumpPower = settings.jumpPower
        useJumpPower = settings.useJumpPower
        jumpHeight = settings.jumpHeight
        maxHealth = max(settings.maxHealth, 0)
        maxSlopeAngle = settings.maxSlopeAngle
        autoRotate = settings.autoRotate
        health = maxHealth
    }

    var isDead: Bool { state == .dead }

    /// Launch speed for a jump. Roblox offers the same two ways of saying it.
    func jumpVelocity(gravity: Float) -> Float {
        useJumpPower ? max(jumpPower, 0) : sqrt(2 * max(gravity, 0) * max(jumpHeight, 0))
    }

    var maxSlopeCosine: Float {
        cos(min(max(maxSlopeAngle, 0), 89.9) * .pi / 180)
    }

    // MARK: - Health

    mutating func setHealth(_ value: Float) {
        guard !isDead else { return }
        let clamped = min(max(value, 0), maxHealth)
        guard clamped != health else { return }
        health = clamped
        events.append(.healthChanged(health))
        if health <= 0 { die() }
    }

    mutating func takeDamage(_ amount: Float) {
        setHealth(health - max(amount, 0))
    }

    mutating func setMaxHealth(_ value: Float) {
        maxHealth = max(value, 0)
        if health > maxHealth { setHealth(maxHealth) }
    }

    mutating func die() {
        guard !isDead else { return }
        if health != 0 {
            health = 0
            events.append(.healthChanged(0))
        }
        enter(.dead)
        events.append(.died)
        moveDirection = .zero
        moveToTarget = nil
    }

    // MARK: - State

    /// Moves to a new state and records the change. Dead is final for this character.
    mutating func enter(_ next: HumanoidStateType) {
        guard next != state, !(isDead) || next == .dead else { return }
        let previous = state
        state = next
        events.append(.stateChanged(from: previous, to: next))
        switch next {
        case .jumping: events.append(.jumping)
        case .freefall: events.append(.freeFalling)
        default: break
        }
    }

    /// Scripts may ask for a state; only the ones that make sense to request are honoured.
    @discardableResult
    mutating func requestState(_ requested: HumanoidStateType) -> Bool {
        switch requested {
        case .flying, .running:
            enter(requested)
            return true
        case .jumping:
            jump = true
            return true
        case .dead:
            die()
            return true
        default:
            return false
        }
    }

    mutating func finishMoveTo(reached: Bool) {
        guard moveToTarget != nil else { return }
        moveToTarget = nil
        moveToElapsed = 0
        moveDirection = .zero
        events.append(.moveToFinished(reached: reached))
    }

    mutating func record(_ event: HumanoidEvent) { events.append(event) }

    mutating func drainEvents() -> [HumanoidEvent] {
        defer { events.removeAll() }
        return events
    }
}
