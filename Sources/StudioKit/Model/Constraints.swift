import Foundation
import simd

/// A point and direction fixed to a part — Roblox's Attachment. Joints connect two.
struct SceneAttachment: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Attachment"
    /// The part it is fixed to.
    var parentID: UUID
    /// In the part's own frame.
    var position = Vec3.zero
    /// The attachment's primary axis (Roblox's Axis, its X): a hinge turns about it, a
    /// slider slides along it. In the part's frame, unit length.
    var axis = Vec3(1, 0, 0)
    /// Perpendicular to `axis` (Roblox's SecondaryAxis, its Y): where a hinge's angle
    /// is measured from.
    var secondaryAxis = Vec3(0, 1, 0)

    init(parentID: UUID, position: Vec3 = .zero, axis: Vec3 = Vec3(1, 0, 0)) {
        self.parentID = parentID
        self.position = position
        setAxis(axis)
    }

    /// Sets the axis, keeping the secondary axis perpendicular to it.
    mutating func setAxis(_ newAxis: Vec3) {
        axis = simd_length(newAxis) > 1e-6 ? normalize(newAxis) : Vec3(1, 0, 0)
        var secondary = secondaryAxis - axis * dot(secondaryAxis, axis)
        if simd_length(secondary) < 1e-4 {
            let helper = abs(axis.y) < 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0)
            secondary = helper - axis * dot(helper, axis)
        }
        secondaryAxis = normalize(secondary)
    }

    private enum CodingKeys: String, CodingKey { case id, name, parentID, position, axis, secondaryAxis }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Attachment"
        parentID = try c.decode(UUID.self, forKey: .parentID)
        position = try c.decodeIfPresent(Vec3.self, forKey: .position) ?? .zero
        axis = try c.decodeIfPresent(Vec3.self, forKey: .axis) ?? Vec3(1, 0, 0)
        secondaryAxis = try c.decodeIfPresent(Vec3.self, forKey: .secondaryAxis) ?? Vec3(0, 1, 0)
    }
}

/// How a hinge or slider is driven — Roblox's ActuatorType.
enum ActuatorType: String, Codable, CaseIterable, Identifiable {
    case none = "None"
    /// Turns (or slides) at a speed, up to a maximum torque (or force).
    case motor = "Motor"
    /// Heads for a target angle (or position) at up to a speed.
    case servo = "Servo"

    var id: String { rawValue }
}

/// A weld or a joint between two parts.
struct SceneConstraint: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        /// Holds two parts together rigidly; they move as one assembly.
        case weld = "WeldConstraint"
        /// Turns about an axis: doors, wheels, flaps.
        case hinge = "HingeConstraint"
        /// Turns freely in every direction about a point: pendulums, ragdolls.
        case ballSocket = "BallSocketConstraint"
        /// Keeps two points no further apart than a length.
        case rope = "RopeConstraint"
        /// Pulls two points towards a free length.
        case spring = "SpringConstraint"
        /// Slides along an axis: lifts, pistons, drawers.
        case prismatic = "PrismaticConstraint"
        /// Not a joint: a ribbon drawn between its two attachments (Ribbons.swift).
        case beam = "Beam"
        /// Not a joint: a ribbon left behind its two attachments as they move.
        case trail = "Trail"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .weld: return "Weld"
            case .hinge: return "Hinge"
            case .ballSocket: return "Ball Socket"
            case .rope: return "Rope"
            case .spring: return "Spring"
            case .prismatic: return "Prismatic"
            case .beam: return "Beam"
            case .trail: return "Trail"
            }
        }

        var symbolName: String {
            switch self {
            case .weld: return "link"
            case .hinge: return "door.left.hand.open"
            case .ballSocket: return "circle.circle"
            case .rope: return "point.topleft.down.to.point.bottomright.curvepath"
            case .spring: return "alternatingcurrent"
            case .prismatic: return "arrow.left.and.right"
            case .beam: return "wand.and.rays"
            case .trail: return "scribble.variable"
            }
        }

        /// Beams and Trails: drawn, never simulated, and not among the join tools.
        var isEffect: Bool { self == .beam || self == .trail }

        /// Welds join parts directly; everything else joins two attachments.
        var usesAttachments: Bool { self != .weld }
    }

    var id = UUID()
    var name: String
    var kind: Kind
    /// What holds it in the tree; usually the first part.
    var parentID: UUID?
    var enabled = true

    // Welds.
    var part0: UUID?
    var part1: UUID?
    // Joints.
    var attachment0: UUID?
    var attachment1: UUID?

    // Hinge (degrees, and degrees per second — converted for the physics).
    var actuator = ActuatorType.none
    var limitsEnabled = false
    var lowerAngle: Float = -45
    var upperAngle: Float = 45
    /// Motor: target speed in radians per second, as Roblox's AngularVelocity.
    var angularVelocity: Float = 0
    var motorMaxTorque: Float = 100_000
    /// Servo: target angle in degrees, reached at up to `angularSpeed` rad/s.
    var targetAngle: Float = 0
    var angularSpeed: Float = 2
    var servoMaxTorque: Float = 100_000

    // Prismatic (studs, studs per second).
    var lowerLimit: Float = -5
    var upperLimit: Float = 5
    var velocity: Float = 0
    var motorMaxForce: Float = 100_000
    var targetPosition: Float = 0
    var speed: Float = 5
    var servoMaxForce: Float = 100_000

    // Rope and spring (studs).
    var length: Float = 5
    var freeLength: Float = 5
    var stiffness: Float = 200
    var damping: Float = 10

    /// A Beam's or Trail's looks; nil for joints.
    var ribbon: RibbonLook?
    var look: RibbonLook {
        get { ribbon ?? RibbonLook() }
        set { ribbon = newValue }
    }

    init(kind: Kind, name: String? = nil) {
        self.kind = kind
        self.name = name ?? kind.rawValue
        if kind.isEffect { ribbon = RibbonLook() }
    }

    /// Parts it joins, through its attachments or directly.
    func parts(in model: SceneModel) -> (UUID?, UUID?) {
        if kind == .weld { return (part0, part1) }
        return (attachment0.flatMap { model.attachment(id: $0)?.parentID },
                attachment1.flatMap { model.attachment(id: $0)?.parentID })
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, parentID, enabled, part0, part1, attachment0, attachment1
        case actuator, limitsEnabled, lowerAngle, upperAngle, angularVelocity, motorMaxTorque
        case targetAngle, angularSpeed, servoMaxTorque, lowerLimit, upperLimit, velocity, motorMaxForce
        case targetPosition, speed, servoMaxForce, length, freeLength, stiffness, damping, ribbon
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        self.init(kind: kind)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? kind.rawValue
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        part0 = try c.decodeIfPresent(UUID.self, forKey: .part0)
        part1 = try c.decodeIfPresent(UUID.self, forKey: .part1)
        attachment0 = try c.decodeIfPresent(UUID.self, forKey: .attachment0)
        attachment1 = try c.decodeIfPresent(UUID.self, forKey: .attachment1)
        let d = SceneConstraint(kind: kind)
        actuator = try c.decodeIfPresent(ActuatorType.self, forKey: .actuator) ?? d.actuator
        limitsEnabled = try c.decodeIfPresent(Bool.self, forKey: .limitsEnabled) ?? d.limitsEnabled
        lowerAngle = try c.decodeIfPresent(Float.self, forKey: .lowerAngle) ?? d.lowerAngle
        upperAngle = try c.decodeIfPresent(Float.self, forKey: .upperAngle) ?? d.upperAngle
        angularVelocity = try c.decodeIfPresent(Float.self, forKey: .angularVelocity) ?? d.angularVelocity
        motorMaxTorque = try c.decodeIfPresent(Float.self, forKey: .motorMaxTorque) ?? d.motorMaxTorque
        targetAngle = try c.decodeIfPresent(Float.self, forKey: .targetAngle) ?? d.targetAngle
        angularSpeed = try c.decodeIfPresent(Float.self, forKey: .angularSpeed) ?? d.angularSpeed
        servoMaxTorque = try c.decodeIfPresent(Float.self, forKey: .servoMaxTorque) ?? d.servoMaxTorque
        lowerLimit = try c.decodeIfPresent(Float.self, forKey: .lowerLimit) ?? d.lowerLimit
        upperLimit = try c.decodeIfPresent(Float.self, forKey: .upperLimit) ?? d.upperLimit
        velocity = try c.decodeIfPresent(Float.self, forKey: .velocity) ?? d.velocity
        motorMaxForce = try c.decodeIfPresent(Float.self, forKey: .motorMaxForce) ?? d.motorMaxForce
        targetPosition = try c.decodeIfPresent(Float.self, forKey: .targetPosition) ?? d.targetPosition
        speed = try c.decodeIfPresent(Float.self, forKey: .speed) ?? d.speed
        servoMaxForce = try c.decodeIfPresent(Float.self, forKey: .servoMaxForce) ?? d.servoMaxForce
        length = try c.decodeIfPresent(Float.self, forKey: .length) ?? d.length
        freeLength = try c.decodeIfPresent(Float.self, forKey: .freeLength) ?? d.freeLength
        stiffness = try c.decodeIfPresent(Float.self, forKey: .stiffness) ?? d.stiffness
        damping = try c.decodeIfPresent(Float.self, forKey: .damping) ?? d.damping
        ribbon = try c.decodeIfPresent(RibbonLook.self, forKey: .ribbon) ?? d.ribbon
    }
}

extension SceneModel {

    func attachment(id: UUID) -> SceneAttachment? { attachments.first { $0.id == id } }
    func constraint(id: UUID) -> SceneConstraint? { constraints.first { $0.id == id } }

    func attachments(on partID: UUID) -> [SceneAttachment] { attachments.filter { $0.parentID == partID } }
    func constraints(under parentID: UUID) -> [SceneConstraint] { constraints.filter { $0.parentID == parentID } }

    func updateAttachment(id: UUID, _ body: (inout SceneAttachment) -> Void) {
        guard let i = attachments.firstIndex(where: { $0.id == id }) else { return }
        body(&attachments[i])
    }

    func updateConstraint(id: UUID, _ body: (inout SceneConstraint) -> Void) {
        guard let i = constraints.firstIndex(where: { $0.id == id }) else { return }
        body(&constraints[i])
    }

    /// An attachment's place and axes in the world.
    func worldFrame(of attachment: SceneAttachment) -> (position: Vec3, axis: Vec3, secondary: Vec3)? {
        guard let part = part(id: attachment.parentID) else { return nil }
        let r = part.orientation
        return (part.position + r.act(attachment.position), r.act(attachment.axis), r.act(attachment.secondaryAxis))
    }

    /// Makes an attachment on a part at a point and axis given in world space.
    @discardableResult
    func addAttachment(on partID: UUID, world point: Vec3, axis worldAxis: Vec3, name: String = "Attachment") -> UUID? {
        guard let part = part(id: partID) else { return nil }
        let inverse = part.orientation.inverse
        var attachment = SceneAttachment(parentID: partID, position: inverse.act(point - part.position),
                                         axis: inverse.act(worldAxis))
        attachment.name = name
        attachments.append(attachment)
        return attachment.id
    }

    /// Joins two parts with a weld or a joint (Roblox Studio's constraint tools),
    /// as one undo step.
    @discardableResult
    func join(_ kind: SceneConstraint.Kind, _ a: UUID, _ b: UUID) -> UUID? {
        var made: UUID?
        commit("Added \(kind.displayName)") { made = makeJoin(kind, a, b) }
        if let made { selectedConstraint = made }
        return made
    }

    /// Builds one weld or joint, with no undo step of its own so a whole selection can
    /// be joined at once. A joint gets an attachment on each part, at the point between
    /// them; a hinge turns about the second part's up axis (a wheel's axle, as cylinders
    /// stand along Y), anything else along the line between them. Welding two parts that
    /// are already welded returns the weld they have rather than stacking another on top.
    @discardableResult
    func makeJoin(_ kind: SceneConstraint.Kind, _ a: UUID, _ b: UUID) -> UUID? {
        guard a != b, let partA = part(id: a), let partB = part(id: b) else { return nil }
        if kind == .weld, let existing = weld(between: a, and: b) { return existing }
        var constraint = SceneConstraint(kind: kind)
        constraint.parentID = a
        if kind == .weld {
            constraint.part0 = a
            constraint.part1 = b
        } else if kind.isEffect {
            // A beam from the middle of one to the middle of the other, the same from
            // every side (FaceCamera); a trail is made on one part (addTrail).
            let axis = simd_length(partB.position - partA.position) > 1e-4 ? normalize(partB.position - partA.position)
                : Vec3(1, 0, 0)
            constraint.attachment0 = addAttachment(on: a, world: partA.position, axis: axis, name: "Attachment0")
            constraint.attachment1 = addAttachment(on: b, world: partB.position, axis: axis, name: "Attachment1")
            constraint.look.faceCamera = true
        } else {
            let between = partB.position - partA.position
            let axis: Vec3
            switch kind {
            case .hinge: axis = partB.orientation.act(Vec3(0, 1, 0))
            case .prismatic: axis = simd_length(between) > 1e-4 ? normalize(between) : Vec3(1, 0, 0)
            default: axis = simd_length(between) > 1e-4 ? normalize(between) : Vec3(0, -1, 0)
            }
            // Rope and spring pin each end on its own part; the others share a point.
            let middle = (partA.position + partB.position) / 2
            let pointA = kind == .rope || kind == .spring ? partA.position : middle
            let pointB = kind == .rope || kind == .spring ? partB.position : middle
            constraint.attachment0 = addAttachment(on: a, world: pointA, axis: axis, name: "Attachment0")
            constraint.attachment1 = addAttachment(on: b, world: pointB, axis: axis, name: "Attachment1")
            let distance = simd_length(between)
            constraint.length = max(distance, 0.1)
            constraint.freeLength = max(distance, 0.1)
        }
        constraints.append(constraint)
        return constraint.id
    }

    /// The weld holding two parts together, whichever way round it was made.
    func weld(between a: UUID, and b: UUID) -> UUID? {
        constraints.first {
            $0.kind == .weld && (($0.part0 == a && $0.part1 == b) || ($0.part0 == b && $0.part1 == a))
        }?.id
    }

    /// Welds the whole selection in one go (Roblox's "Weld" on a selection): every part
    /// is joined to the one before it, so a brick wall becomes a single assembly.
    @discardableResult
    func weldSelection() -> [UUID] { joinSelection(.weld) }

    /// Chains the selected parts with welds or joints, as one undo step.
    @discardableResult
    func joinSelection(_ kind: SceneConstraint.Kind = .weld) -> [UUID] {
        let ids = selectedParts.map(\.id)
        guard ids.count >= 2 else { return [] }
        var made: [UUID] = []
        let label = kind == .weld ? "Welded \(ids.count) parts"
                                  : "Joined \(ids.count) parts with \(kind.displayName)s"
        commit(label) {
            // Chain them, so each is joined to the one before: one assembly either way.
            for i in 1..<ids.count {
                if let id = makeJoin(kind, ids[i - 1], ids[i]) { made.append(id) }
            }
        }
        return made
    }

    // MARK: - The join tools

    /// Arms a weld or joint tool: the next part clicked in the viewport is one end, the
    /// one after it the other, and the tool stays armed for the pair after that. With
    /// `joinSelectionOnPick` on and two or more parts already selected, that selection
    /// is joined straight away — picking Weld with a brick wall selected welds the wall.
    /// Returns whatever it made on the spot.
    @discardableResult
    func armJoinTool(_ kind: SceneConstraint.Kind) -> [UUID] {
        joinTool = kind
        joinPending = nil
        let made = joinSelectionOnPick && selectedParts.count >= 2 ? joinSelection(kind) : []
        if made.isEmpty { statusText = "\(kind.displayName) tool: click the first part" }
        return made
    }

    /// Picking one of the transform tools puts any weld or joint tool away.
    func selectGizmo(_ mode: GizmoMode) {
        cancelJoinTool()
        gizmoMode = mode
    }

    /// Puts the tools away; the viewport goes back to selecting and dragging.
    func cancelJoinTool() {
        guard joinTool != nil else { return }
        joinTool = nil
        joinPending = nil
        statusText = "Ready"
    }

    /// Lets go of the first part without leaving the tool — a click on empty space.
    func clearJoinPending() {
        guard joinPending != nil, let kind = joinTool else { return }
        joinPending = nil
        statusText = "\(kind.displayName) tool: click the first part"
    }

    /// A viewport click on a part while a tool is armed. The first click holds that part,
    /// the second joins the two; clicking the held part again lets go of it. Returns the
    /// joint it made, if this was the second click.
    @discardableResult
    func pickJoinTarget(_ partID: UUID) -> UUID? {
        guard let kind = joinTool, let picked = part(id: partID) else { return nil }
        // A held part that has since been deleted counts as no part at all.
        let held = joinPending.flatMap { part(id: $0) }
        guard let first = held else {
            joinPending = partID
            statusText = "\(kind.displayName) tool: \(picked.name) → click the second part"
            return nil
        }
        if first.id == partID {
            clearJoinPending()
            return nil
        }
        let before = constraints.count
        let made = join(kind, first.id, partID)
        joinPending = nil
        if made != nil {
            statusText = constraints.count > before
                ? "\(kind.displayName): \(first.name) → \(picked.name)"
                : "\(first.name) and \(picked.name) are already welded"
        }
        return made
    }

    func deleteConstraint(id: UUID) {
        guard let constraint = constraint(id: id) else { return }
        commit("Deleted \(constraint.kind.displayName)") { removeConstraint(id: id) }
    }

    /// Takes one weld or joint out, with no undo step of its own.
    private func removeConstraint(id: UUID) {
        guard let constraint = constraint(id: id) else { return }
        constraints.removeAll { $0.id == id }
        // Its attachments go too, unless something else uses them.
        for attachment in [constraint.attachment0, constraint.attachment1].compactMap({ $0 }) {
            let used = constraints.contains { $0.attachment0 == attachment || $0.attachment1 == attachment }
            if !used { attachments.removeAll { $0.id == attachment } }
        }
        if selectedConstraint == id { selectedConstraint = nil }
    }

    /// Frees the selected parts: every weld and joint with an end on one of them goes
    /// (Roblox's "break joints"), as one undo step. Returns how many it removed.
    @discardableResult
    func unjoinSelection() -> Int {
        let ids = effectiveSelection
        guard !ids.isEmpty else { return 0 }
        let doomed = constraints.filter { c in
            let (a, b) = c.parts(in: self)
            return (a.map(ids.contains) ?? false) || (b.map(ids.contains) ?? false)
        }
        guard !doomed.isEmpty else { return 0 }
        commit("Removed \(doomed.count) joint\(doomed.count == 1 ? "" : "s")") {
            for c in doomed { removeConstraint(id: c.id) }
        }
        return doomed.count
    }

    /// Drops attachments on parts that are gone, and constraints that lost their parts.
    func pruneConstraints() {
        let partIDs = Set(parts.map(\.id))
        attachments.removeAll { !partIDs.contains($0.parentID) }
        let attachmentIDs = Set(attachments.map(\.id))
        constraints.removeAll { c in
            if c.kind == .weld {
                return [c.part0, c.part1].contains { $0.map { !partIDs.contains($0) } ?? false }
            }
            return [c.attachment0, c.attachment1].contains { $0.map { !attachmentIDs.contains($0) } ?? false }
        }
        if let selected = selectedConstraint, !constraints.contains(where: { $0.id == selected }) {
            selectedConstraint = nil
        }
        if let selected = selectedAttachment, !attachments.contains(where: { $0.id == selected }) {
            selectedAttachment = nil
        }
        if let held = joinPending, !partIDs.contains(held) { joinPending = nil }
    }
}
