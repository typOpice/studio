import Foundation
import simd

/// Where on the body an accessory goes — Roblox's AccessoryType, each with the R6
/// attachment it hangs from.
enum AccessoryType: String, Codable, CaseIterable, Identifiable {
    case hat = "Hat"
    case hair = "Hair"
    case face = "Face"
    case neck = "Neck"
    case shoulder = "Shoulder"
    case front = "Front"
    case back = "Back"
    case waist = "Waist"

    var id: String { rawValue }

    /// The body part it hangs from, and the point on that part (in the part's own frame,
    /// its centre at the origin, facing −Z) that its attachment is at.
    var attachment: (part: String, point: Vec3) {
        switch self {
        case .hat, .hair: return ("Head", Vec3(0, 0.625, 0))       // the top of the head
        case .face: return ("Head", Vec3(0, 0.05, -0.62))          // the middle of the face
        case .neck: return ("Torso", Vec3(0, 1, 0))
        case .shoulder: return ("Right Arm", Vec3(0, 1, 0))
        case .front: return ("Torso", Vec3(0, 0, -0.5))
        case .back: return ("Torso", Vec3(0, 0, 0.5))
        case .waist: return ("Torso", Vec3(0, -1, 0))
        }
    }

    /// For an imported model, the point of its box (−0.5…0.5 on each axis) that goes on
    /// the attachment: a hat's bottom, glasses' back, a backpack's front.
    var anchor: Vec3 {
        switch self {
        case .hat, .hair, .shoulder: return Vec3(0, -0.5, 0)
        case .face, .front: return Vec3(0, 0, 0.5)
        case .back: return Vec3(0, 0, -0.5)
        case .neck, .waist: return .zero
        }
    }

    /// Where an imported model starts, off its attachment: hats sit down over the head.
    var startingOffset: Vec3 {
        switch self {
        case .hat, .hair: return Vec3(0, -0.3, 0)
        default: return .zero
        }
    }
}

/// One thing a character wears: a built-in accessory or an imported 3D model, where it
/// goes, its colour (and picture, for a model with texture coordinates), and how it is
/// moved, turned and sized from where it hangs.
struct AvatarAccessory: Codable, Equatable, Identifiable {
    /// Unique among a look's accessories; scripts hold accessories by it.
    var id = UUID().uuidString
    var name: String
    /// `builtin://TopHat` (see `AvatarCatalog`) or an imported model, `studio://Name`.
    var item: String
    var type: AccessoryType
    var textureId = ""
    var color: Vec3
    /// Studs from the attachment, in the body part's frame.
    var offset = Vec3.zero
    /// Degrees about X, Y and Z.
    var rotation = Vec3.zero
    var scale: Float = 1

    init(name: String, item: String, type: AccessoryType, color: Vec3) {
        self.name = name
        self.item = item
        self.type = type
        self.color = color
        if !item.hasPrefix(AvatarCatalog.prefix) { offset = type.startingOffset }
    }

    /// A built-in accessory, as the catalog makes it.
    init?(builtIn id: String) {
        guard let entry = AvatarCatalog.accessory(id) else { return nil }
        self.init(name: entry.name.replacingOccurrences(of: " ", with: ""), item: AvatarCatalog.prefix + entry.id,
                  type: entry.type, color: entry.color)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, item, type, textureId, color, offset, rotation, scale
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Accessory"
        item = try c.decodeIfPresent(String.self, forKey: .item) ?? ""
        type = try c.decodeIfPresent(AccessoryType.self, forKey: .type) ?? .hat
        textureId = try c.decodeIfPresent(String.self, forKey: .textureId) ?? ""
        color = try c.decodeIfPresent(Vec3.self, forKey: .color) ?? Vec3(repeating: 0.8)
        offset = try c.decodeIfPresent(Vec3.self, forKey: .offset) ?? .zero
        rotation = try c.decodeIfPresent(Vec3.self, forKey: .rotation) ?? .zero
        scale = try c.decodeIfPresent(Float.self, forKey: .scale) ?? 1
    }
}

/// What a character wears: a face, a shirt and pants (pictures, laid out on Roblox's
/// classic clothing template), and accessories. Each picture is `""` for none — for the
/// face, the classic smile — a built-in one (`builtin://Grin`) or an imported picture
/// (`studio://Name`).
struct AvatarLook: Codable, Equatable {
    var face = ""
    var shirt = ""
    var pants = ""
    var accessories: [AvatarAccessory] = []

    /// The most accessories a character wears at once.
    static let mostAccessories = 10

    init() {}

    var isEmpty: Bool { face.isEmpty && shirt.isEmpty && pants.isEmpty && accessories.isEmpty }

    /// What a player wears in a place: their own look (when the place lets them), with
    /// the place's face, shirt and pants in place of theirs where it sets them, and the
    /// place's accessories added to theirs.
    func worn(by player: AvatarLook?, playersWearOwn: Bool) -> AvatarLook {
        var look = playersWearOwn ? (player ?? AvatarLook()) : AvatarLook()
        if !face.isEmpty { look.face = face }
        if !shirt.isEmpty { look.shirt = shirt }
        if !pants.isEmpty { look.pants = pants }
        look.accessories += accessories
        look.tidy()
        return look
    }

    /// Kept within bounds: no more than the most accessories, ids unique, sizes sane.
    mutating func tidy() {
        var seen = Set<String>()
        accessories = accessories.prefix(Self.mostAccessories).map { accessory in
            var accessory = accessory
            if seen.contains(accessory.id) || accessory.id.isEmpty { accessory.id = UUID().uuidString }
            seen.insert(accessory.id)
            accessory.scale = min(max(accessory.scale.isFinite ? accessory.scale : 1, 0.05), 20)
            accessory.offset = simd_clamp(accessory.offset, Vec3(repeating: -20), Vec3(repeating: 20))
            return accessory
        }
        if face == AvatarCatalog.prefix + AvatarCatalog.classicFace { face = "" }
    }

    /// A player's own look may only use built-in things: a place's imported files
    /// don't travel with them from game to game.
    var builtInOnly: AvatarLook {
        var look = self
        func keep(_ reference: String) -> String { reference.hasPrefix(AvatarCatalog.prefix) ? reference : "" }
        look.face = face == AvatarCatalog.noFaceReference ? face : keep(face)
        look.shirt = keep(shirt)
        look.pants = keep(pants)
        look.accessories = accessories.filter { $0.item.hasPrefix(AvatarCatalog.prefix) }.map {
            var accessory = $0
            accessory.textureId = ""
            return accessory
        }
        return look
    }

    /// An imported file renamed: its references follow.
    mutating func rename(_ old: String, to new: String) {
        if face == old { face = new }
        if shirt == old { shirt = new }
        if pants == old { pants = new }
        for index in accessories.indices {
            if accessories[index].item == old { accessories[index].item = new }
            if accessories[index].textureId == old { accessories[index].textureId = new }
        }
    }

    private enum CodingKeys: String, CodingKey { case face, shirt, pants, accessories }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        face = try c.decodeIfPresent(String.self, forKey: .face) ?? ""
        shirt = try c.decodeIfPresent(String.self, forKey: .shirt) ?? ""
        pants = try c.decodeIfPresent(String.self, forKey: .pants) ?? ""
        accessories = try c.decodeIfPresent([AvatarAccessory].self, forKey: .accessories) ?? []
    }

    // MARK: - For scripts

    /// As the `look.get` host call answers: `{face, shirt, pants, {accessory…}}`, each
    /// accessory `{id, name, item, type, texture, colour, offset, rotation, scale}`.
    var scriptValue: ScriptValue {
        .list([.string(face), .string(shirt), .string(pants), .list(accessories.map(Self.scriptValue))])
    }

    /// A look as `scriptValue` gives it.
    init?(scriptValue value: ScriptValue) {
        guard let fields = value.asList, fields.count >= 4, let face = fields[0].asString,
              let shirt = fields[1].asString, let pants = fields[2].asString,
              let accessories = Self.accessories(fields[3]) else { return nil }
        self.face = face
        self.shirt = shirt
        self.pants = pants
        self.accessories = accessories
    }

    static func scriptValue(_ a: AvatarAccessory) -> ScriptValue {
        func triple(_ v: Vec3) -> ScriptValue { .triple(v.x, v.y, v.z) }
        return .list([.string(a.id), .string(a.name), .string(a.item), .string(a.type.rawValue), .string(a.textureId),
                      triple(a.color), triple(a.offset), triple(a.rotation), .number(Double(a.scale))])
    }

    static func accessory(_ value: ScriptValue) -> AvatarAccessory? {
        guard let fields = value.asList, fields.count >= 9, let id = fields[0].asString, let name = fields[1].asString,
              let item = fields[2].asString, let type = fields[3].asString.flatMap(AccessoryType.init(rawValue:)),
              let texture = fields[4].asString, let (r, g, b) = fields[5].asTriple,
              let (ox, oy, oz) = fields[6].asTriple, let (rx, ry, rz) = fields[7].asTriple,
              let scale = fields[8].asFloat else { return nil }
        var accessory = AvatarAccessory(name: name, item: item, type: type, color: Vec3(r, g, b))
        accessory.id = id
        accessory.textureId = texture
        accessory.offset = Vec3(ox, oy, oz)
        accessory.rotation = Vec3(rx, ry, rz)
        accessory.scale = scale
        return accessory
    }

    /// Accessories from a script's list, or nil if any is malformed.
    static func accessories(_ value: ScriptValue) -> [AvatarAccessory]? {
        guard let list = value.asList else { return nil }
        var out: [AvatarAccessory] = []
        for entry in list {
            guard let accessory = accessory(entry) else { return nil }
            out.append(accessory)
        }
        return out
    }

    /// One `look.set`: a key (`face`, `shirt`, `pants`, `accessories`) and its value.
    /// False, and unchanged, if the value doesn't fit the key.
    @discardableResult
    mutating func set(_ key: String, _ value: ScriptValue) -> Bool {
        switch key.lowercased() {
        case "face": guard let text = value.asString else { return false }; face = text
        case "shirt": guard let text = value.asString else { return false }; shirt = text
        case "pants": guard let text = value.asString else { return false }; pants = text
        case "accessories": guard let list = Self.accessories(value) else { return false }; accessories = list
        default: return false
        }
        tidy()
        return true
    }
}

// MARK: - Where accessories go

extension AvatarPose {
    /// Where each accessory is drawn: its body part's transform (from `partTransforms`),
    /// then its attachment, offset, turn and scale. `modelSize` gives an imported model's
    /// own size in studs (nil for a built-in one, which is made at its real size around
    /// its attachment); the unit-cube model is then stretched to it and placed by its
    /// type's anchor. An accessory whose model can't be found is left out.
    func accessoryTransforms(modelSize: (AvatarAccessory) -> Vec3??)
        -> [(accessory: AvatarAccessory, part: String, matrix: float4x4)] {
        let parts = Dictionary(partTransforms().map { ($0.name, $0.matrix) }, uniquingKeysWith: { first, _ in first })
        return look.accessories.compactMap { accessory in
            let (partName, point) = accessory.type.attachment
            guard let part = parts[partName], let size = modelSize(accessory) else { return nil }
            let degrees = accessory.rotation * (.pi / 180)
            var matrix = part * Mat.translation(point + accessory.offset) * Self.rotation(degrees)
                * Mat.scale(Vec3(repeating: accessory.scale))
            if let size {
                matrix = matrix * Mat.scale(size) * Mat.translation(-accessory.type.anchor)
            }
            return (accessory, partName, matrix)
        }
    }
}
