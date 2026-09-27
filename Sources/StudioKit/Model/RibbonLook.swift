import Foundation
import simd

/// How a Beam or a Trail looks: Roblox's properties for them, with Roblox's defaults.
/// Kept on the constraint (`SceneConstraint.ribbon`), so it's saved and sent to joined
/// players with it; drawing them is each machine's (Ribbons.swift).
struct RibbonLook: Codable, Equatable {
    /// Enum.TextureMode: a picture stretched along the whole ribbon (TextureLength times),
    /// or repeated every TextureLength studs.
    enum TextureMode: String, Codable, CaseIterable, Identifiable {
        case stretch = "Stretch", wrap = "Wrap"
        var id: String { rawValue }
    }

    /// Pictures made for ribbons, besides any imported one ("" is plain colour).
    static let builtinTextures = ["Glow", "Arrows", "Dots", "Chain"]

    var color: [ColorKey] = .from(Vec3(1, 1, 1), to: Vec3(1, 1, 1))
    var transparency: [NumberKey] = .from(0.5, to: 0.5)
    var lightEmission: Float = 0
    var brightness: Float = 1
    var texture = ""
    var textureLength: Float = 1
    var textureMode = TextureMode.stretch
    /// Faces the camera from wherever it is, rather than lying across its attachments'
    /// secondary axes (a Beam) or between its two attachments (a Trail).
    var faceCamera = false

    // Beams.
    var width0: Float = 1
    var width1: Float = 1
    /// How far the curve heads out along each attachment's axis before bending to the other.
    var curveSize0: Float = 0
    var curveSize1: Float = 0
    var segments = 10
    /// Scrolls the picture along it, in picture lengths a second.
    var textureSpeed: Float = 1

    // Trails.
    /// How long a point of it lasts, in seconds.
    var lifetime: Float = 2
    /// How far the attachments move before it adds a point.
    var minLength: Float = 0.1
    /// 0 for as long as Lifetime allows.
    var maxLength: Float = 0
    /// Its width through a point's life, times the gap between the attachments.
    var widthScale: [NumberKey] = .from(1, to: 1)
    /// How many times a script has called Clear.
    var cleared = 0

    init() {}

    // Saved files leave out what's still as it was made.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RibbonLook()
        color = try c.decodeIfPresent([ColorKey].self, forKey: .color) ?? d.color
        transparency = try c.decodeIfPresent([NumberKey].self, forKey: .transparency) ?? d.transparency
        lightEmission = try c.decodeIfPresent(Float.self, forKey: .lightEmission) ?? d.lightEmission
        brightness = try c.decodeIfPresent(Float.self, forKey: .brightness) ?? d.brightness
        texture = try c.decodeIfPresent(String.self, forKey: .texture) ?? d.texture
        textureLength = try c.decodeIfPresent(Float.self, forKey: .textureLength) ?? d.textureLength
        textureMode = try c.decodeIfPresent(TextureMode.self, forKey: .textureMode) ?? d.textureMode
        faceCamera = try c.decodeIfPresent(Bool.self, forKey: .faceCamera) ?? d.faceCamera
        width0 = try c.decodeIfPresent(Float.self, forKey: .width0) ?? d.width0
        width1 = try c.decodeIfPresent(Float.self, forKey: .width1) ?? d.width1
        curveSize0 = try c.decodeIfPresent(Float.self, forKey: .curveSize0) ?? d.curveSize0
        curveSize1 = try c.decodeIfPresent(Float.self, forKey: .curveSize1) ?? d.curveSize1
        segments = try c.decodeIfPresent(Int.self, forKey: .segments) ?? d.segments
        textureSpeed = try c.decodeIfPresent(Float.self, forKey: .textureSpeed) ?? d.textureSpeed
        lifetime = try c.decodeIfPresent(Float.self, forKey: .lifetime) ?? d.lifetime
        minLength = try c.decodeIfPresent(Float.self, forKey: .minLength) ?? d.minLength
        maxLength = try c.decodeIfPresent(Float.self, forKey: .maxLength) ?? d.maxLength
        widthScale = try c.decodeIfPresent([NumberKey].self, forKey: .widthScale) ?? d.widthScale
        cleared = try c.decodeIfPresent(Int.self, forKey: .cleared) ?? 0
    }
}

extension SceneModel {
    /// Studio's Add Trail: a Trail on a part, between attachments at its top and bottom,
    /// so moving it sweeps out a ribbon as tall as it is. One step to undo.
    @discardableResult
    func addTrail(to partID: UUID) -> UUID? {
        guard let part = part(id: partID) else { return nil }
        var made: UUID?
        commit("Added Trail") {
            let up = part.orientation.act(Vec3(0, part.size.y / 2, 0))
            var trail = SceneConstraint(kind: .trail)
            trail.parentID = partID
            trail.attachment0 = addAttachment(on: partID, world: part.position + up, axis: Vec3(1, 0, 0),
                                              name: "TrailTop")
            trail.attachment1 = addAttachment(on: partID, world: part.position - up, axis: Vec3(1, 0, 0),
                                              name: "TrailBottom")
            constraints.append(trail)
            made = trail.id
        }
        if let made { selectedConstraint = made }
        return made
    }
}
