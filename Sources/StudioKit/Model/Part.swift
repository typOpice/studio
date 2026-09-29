import Foundation
import simd

enum PartShape: String, Codable, CaseIterable, Identifiable {
    /// A truss is a block players climb (Roblox's TrussPart).
    case block, sphere, cylinder, wedge, truss

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .block: return "Block"
        case .sphere: return "Sphere"
        case .cylinder: return "Cylinder"
        case .wedge: return "Wedge"
        case .truss: return "Truss"
        }
    }

    var symbolName: String {
        switch self {
        case .block: return "cube.fill"
        case .sphere: return "circle.fill"
        case .cylinder: return "cylinder.fill"
        case .wedge: return "triangle.fill"
        case .truss: return "square.grid.3x3.fill"
        }
    }
}

enum PartMaterial: String, Codable, CaseIterable, Identifiable {
    /// Water isn't solid: characters swim in it.
    case plastic, smooth, metal, neon, wood, water

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }

    /// x = specular strength, y = shininess, z = emissive amount.
    var shading: Vec3 {
        switch self {
        case .plastic: return Vec3(0.30, 24, 0)
        case .smooth:  return Vec3(0.12, 12, 0)
        case .metal:   return Vec3(0.95, 96, 0)
        case .neon:    return Vec3(0.00, 1, 1)
        case .wood:    return Vec3(0.08, 8, 0)
        case .water:   return Vec3(0.60, 64, 0)
        }
    }
}

struct Part: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var name: String = "Part"
    var shape: PartShape = .block
    var position: Vec3 = Vec3(0, 2, 0)
    var orientation: simd_quatf = simd_quatf(angle: 0, axis: Vec3(0, 1, 0))
    var size: Vec3 = Vec3(4, 1, 2)
    var color: Vec3 = Vec3(0.64, 0.64, 0.64)
    var transparency: Float = 0
    var material: PartMaterial = .plastic
    var anchored: Bool = true
    var visible: Bool = true
    /// In a Tool that is in StarterPack or a Backpack: kept, but out of the world.
    var parked: Bool = false
    /// Kept in ReplicatedStorage or ServerStorage rather than the Workspace (a part at the
    /// top of the tree only); its parts are parked meanwhile.
    var storage: StoragePlace?
    /// Drawn, collided with and touched: visible, and not parked in a Tool.
    var inWorld: Bool { visible && !parked && !negative }
    var locked: Bool = false
    /// Whether the player's character collides with it. Off, it can be walked through —
    /// a trigger zone or a pickup — and still reports touches.
    var canCollide: Bool = true
    /// Whether touching it fires `Touched` / `TouchEnded`.
    var canTouch: Bool = true
    /// The user shader this part draws with, or nil for the built-in shading.
    var shaderID: UUID?
    /// Identified children. The legacy accessor keeps existing point-light callers working.
    var lights: [PointLight] = []
    var light: PointLight? {
        get { lights.first { $0.kind == .point } }
        set {
            if let index = lights.firstIndex(where: { $0.kind == .point }) {
                if let newValue { lights[index] = newValue } else { lights.remove(at: index) }
            } else if let newValue { lights.append(newValue) }
        }
    }
    /// ParticleEmitters in the part (ParticleEmitter.swift).
    var emitters: [ParticleEmitter] = []
    /// A ClickDetector: clicking the part fires its MouseClick. One per part, like a light.
    var clickDetector: ClickDetector?
    /// Makes the part a Seat: a character touching it sits down.
    var seat: SeatSettings?
    /// Makes the part a MeshPart: an imported 3D file, stretched to its Size. Without
    /// the file it is drawn and collided as its `shape`.
    var mesh: MeshSettings?
    var solid: SolidOperation?
    /// Exact boundary after a separated operand acquires shear from a resized union.
    var solidDeformation: SolidMesh?
    var collisionMesh: MeshSettings? {
        solidDeformation.map { MeshSettings(asset: $0.id, collisionFidelity: mesh?.collisionFidelity ?? .precise) } ?? mesh
    }
    var negative = false
    var usePartColor = false

    /// Something a character is kept out of: in the world, colliding, and not water.
    var isSolid: Bool { inWorld && canCollide && !negative && material != .water }
    /// The Model, Folder or part this one is inside; nil for the Workspace.
    var parentID: UUID?

    var rotationDegrees: Vec3 {
        get { orientation.eulerDegrees }
        set { orientation = .fromEulerDegrees(newValue) }
    }

    var modelMatrix: float4x4 {
        Mat.translation(position) * Mat.rotation(orientation) * Mat.scale(size)
    }

    /// Model matrix without the size component, used for gizmos and outlines.
    var frameMatrix: float4x4 {
        Mat.translation(position) * Mat.rotation(orientation)
    }

    /// The part's local axes expressed in world space.
    func worldAxis(_ index: Int) -> Vec3 {
        let m = float3x3(orientation)
        return normalize(m[index])
    }

    static func == (lhs: Part, rhs: Part) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.shape == rhs.shape
            && lhs.position == rhs.position && lhs.orientation.vector == rhs.orientation.vector
            && lhs.size == rhs.size && lhs.color == rhs.color && lhs.transparency == rhs.transparency
            && lhs.material == rhs.material && lhs.anchored == rhs.anchored
            && lhs.visible == rhs.visible && lhs.parked == rhs.parked && lhs.locked == rhs.locked
            && lhs.canCollide == rhs.canCollide && lhs.canTouch == rhs.canTouch
            && lhs.shaderID == rhs.shaderID && lhs.lights == rhs.lights && lhs.parentID == rhs.parentID
            && lhs.clickDetector == rhs.clickDetector && lhs.seat == rhs.seat && lhs.mesh == rhs.mesh
            && lhs.storage == rhs.storage && lhs.emitters == rhs.emitters
            && lhs.solid == rhs.solid && lhs.solidDeformation == rhs.solidDeformation && lhs.negative == rhs.negative && lhs.usePartColor == rhs.usePartColor
    }

    // MARK: - Codable (simd_quatf needs manual handling)

    private enum CodingKeys: String, CodingKey {
        case solid, solidDeformation, negative, usePartColor
        case id, name, shape, position, orientation, size, color, transparency, material, anchored, visible, locked, shaderID
        case canCollide, canTouch, light, lights, parentID, parked, clickDetector, seat, mesh, storage, emitters
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Part"
        shape = try c.decodeIfPresent(PartShape.self, forKey: .shape) ?? .block
        position = try c.decodeIfPresent(Vec3.self, forKey: .position) ?? Vec3(0, 2, 0)
        let q = try c.decodeIfPresent(Vec4.self, forKey: .orientation) ?? Vec4(0, 0, 0, 1)
        orientation = simd_quatf(vector: q)
        size = try c.decodeIfPresent(Vec3.self, forKey: .size) ?? Vec3(4, 1, 2)
        color = try c.decodeIfPresent(Vec3.self, forKey: .color) ?? Vec3(0.64, 0.64, 0.64)
        transparency = try c.decodeIfPresent(Float.self, forKey: .transparency) ?? 0
        material = try c.decodeIfPresent(PartMaterial.self, forKey: .material) ?? .plastic
        anchored = try c.decodeIfPresent(Bool.self, forKey: .anchored) ?? true
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        canCollide = try c.decodeIfPresent(Bool.self, forKey: .canCollide) ?? true
        canTouch = try c.decodeIfPresent(Bool.self, forKey: .canTouch) ?? true
        shaderID = try c.decodeIfPresent(UUID.self, forKey: .shaderID)
        lights = try c.decodeIfPresent([PointLight].self, forKey: .lights) ?? []
        if !c.contains(.lights), var old = try c.decodeIfPresent(PointLight.self, forKey: .light) {
            // Derived from the containing part, so reopening the same old place never changes identity.
            var bytes = id.uuid
            bytes.0 ^= 0x4c; bytes.1 ^= 0x69; bytes.2 ^= 0x67; bytes.3 ^= 0x68
            old.id = UUID(uuid: bytes)
            lights = [old]
        }
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        parked = try c.decodeIfPresent(Bool.self, forKey: .parked) ?? false
        clickDetector = try c.decodeIfPresent(ClickDetector.self, forKey: .clickDetector)
        seat = try c.decodeIfPresent(SeatSettings.self, forKey: .seat)
        mesh = try c.decodeIfPresent(MeshSettings.self, forKey: .mesh)
        solid = try c.decodeIfPresent(SolidOperation.self, forKey: .solid)
        solidDeformation = try c.decodeIfPresent(SolidMesh.self, forKey: .solidDeformation)
        negative = try c.decodeIfPresent(Bool.self, forKey: .negative) ?? false
        usePartColor = try c.decodeIfPresent(Bool.self, forKey: .usePartColor) ?? false
        storage = try c.decodeIfPresent(StoragePlace.self, forKey: .storage)
        emitters = try c.decodeIfPresent([ParticleEmitter].self, forKey: .emitters) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(shape, forKey: .shape)
        try c.encode(position, forKey: .position)
        try c.encode(orientation.vector, forKey: .orientation)
        try c.encode(size, forKey: .size)
        try c.encode(color, forKey: .color)
        try c.encode(transparency, forKey: .transparency)
        try c.encode(material, forKey: .material)
        try c.encode(anchored, forKey: .anchored)
        try c.encode(visible, forKey: .visible)
        try c.encode(locked, forKey: .locked)
        try c.encode(canCollide, forKey: .canCollide)
        try c.encode(canTouch, forKey: .canTouch)
        try c.encodeIfPresent(shaderID, forKey: .shaderID)
        if !lights.isEmpty { try c.encode(lights, forKey: .lights) }
        try c.encodeIfPresent(parentID, forKey: .parentID)
        if parked { try c.encode(parked, forKey: .parked) }
        try c.encodeIfPresent(clickDetector, forKey: .clickDetector)
        try c.encodeIfPresent(seat, forKey: .seat)
        try c.encodeIfPresent(mesh, forKey: .mesh)
        try c.encodeIfPresent(solid, forKey: .solid)
        try c.encodeIfPresent(solidDeformation, forKey: .solidDeformation)
        if negative { try c.encode(true, forKey: .negative) }
        if usePartColor { try c.encode(true, forKey: .usePartColor) }
        try c.encodeIfPresent(storage, forKey: .storage)
        if !emitters.isEmpty { try c.encode(emitters, forKey: .emitters) }
    }
}

/// What makes a part a Seat (or, with `vehicle`, a VehicleSeat).
struct SeatSettings: Codable, Equatable {
    /// Seat.Disabled: nobody sits down on it.
    var disabled = false
    var vehicle: VehicleSeatSettings?
}

/// A VehicleSeat's own properties, as Roblox's: the seat doesn't move anything itself —
/// its driver's keys set its Throttle and Steer (the play session's, not saved), and a
/// script turns those into what the wheels do, going by these.
struct VehicleSeatSettings: Codable, Equatable {
    /// Studs a second at full throttle.
    var maxSpeed: Float = 25
    var torque: Float = 10
    var turnSpeed: Float = 1
    /// Shows the driver their speed.
    var headsUpDisplay = true
}

/// Roblox's ClickDetector, kept on the part it is in.
struct ClickDetector: Codable, Equatable {
    /// How near a player's character must be, in studs, for a click to count.
    var maxActivationDistance: Float = 32
}
