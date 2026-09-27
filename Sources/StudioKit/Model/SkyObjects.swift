import Foundation
import simd

/// Roblox's Sky, in Lighting: the sun and moon (and how big they look), the stars, and
/// six pictures to wrap round the world in place of the sky that follows the time of
/// day. A place with no Sky still has a sun, a moon and stars, as a Roblox place does.
struct SkySettings: Codable, Equatable {
    /// SkyboxBk, SkyboxDn, SkyboxFt, SkyboxLf, SkyboxRt, SkyboxUp: pictures ("studio://Name"),
    /// all six or none. Ft is the side seen looking north (−Z), Rt east (+X).
    enum Face: String, CaseIterable, Identifiable {
        case bk = "SkyboxBk", dn = "SkyboxDn", ft = "SkyboxFt", lf = "SkyboxLf", rt = "SkyboxRt", up = "SkyboxUp"
        var id: String { rawValue }
    }

    var celestialBodiesShown = true
    var starCount = 3000
    /// Degrees across, as Roblox's (whose pictures have a glow round a smaller disc).
    var sunAngularSize: Float = 21
    var moonAngularSize: Float = 11
    var skybox: [String] = Array(repeating: "", count: 6)

    func picture(_ face: Face) -> String { skybox[Face.allCases.firstIndex(of: face)!] }
    mutating func setPicture(_ face: Face, _ reference: String) { skybox[Face.allCases.firstIndex(of: face)!] = reference }
    /// All six pictures given.
    var hasSkybox: Bool { skybox.count == 6 && skybox.allSatisfy { !$0.isEmpty } }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SkySettings()
        celestialBodiesShown = try c.decodeIfPresent(Bool.self, forKey: .celestialBodiesShown) ?? d.celestialBodiesShown
        starCount = try c.decodeIfPresent(Int.self, forKey: .starCount) ?? d.starCount
        sunAngularSize = try c.decodeIfPresent(Float.self, forKey: .sunAngularSize) ?? d.sunAngularSize
        moonAngularSize = try c.decodeIfPresent(Float.self, forKey: .moonAngularSize) ?? d.moonAngularSize
        skybox = try c.decodeIfPresent([String].self, forKey: .skybox) ?? d.skybox
        if skybox.count != 6 { skybox = d.skybox }
    }
}

/// Roblox's Atmosphere, in Lighting: air that far things fade into, and that hazes the
/// sky at the horizon — tinted Color towards the sun and Decay away from it.
struct AtmosphereSettings: Codable, Equatable {
    /// How thick the air is: 0 clear, 1 a thick fog.
    var density: Float = 0.395
    /// How much of it lies between you and the sky (the horizon's haze).
    var offset: Float = 0
    var color = Vec3(199, 199, 199) / 255
    var decay = Vec3(106, 112, 125) / 255
    /// A glow round the sun, 0 to 10.
    var glare: Float = 0
    /// How high the haze reaches up the sky, 0 to 10.
    var haze: Float = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AtmosphereSettings()
        density = try c.decodeIfPresent(Float.self, forKey: .density) ?? d.density
        offset = try c.decodeIfPresent(Float.self, forKey: .offset) ?? d.offset
        color = try c.decodeIfPresent(Vec3.self, forKey: .color) ?? d.color
        decay = try c.decodeIfPresent(Vec3.self, forKey: .decay) ?? d.decay
        glare = try c.decodeIfPresent(Float.self, forKey: .glare) ?? d.glare
        haze = try c.decodeIfPresent(Float.self, forKey: .haze) ?? d.haze
    }
}

/// Roblox's Clouds: a layer of them across the sky, drifting.
struct CloudSettings: Codable, Equatable {
    var enabled = true
    /// How much of the sky they cover, 0 to 1.
    var cover: Float = 0.5
    /// How thick they look, 0 to 1.
    var density: Float = 0.7
    var color = Vec3(1, 1, 1)

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CloudSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        cover = try c.decodeIfPresent(Float.self, forKey: .cover) ?? d.cover
        density = try c.decodeIfPresent(Float.self, forKey: .density) ?? d.density
        color = try c.decodeIfPresent(Vec3.self, forKey: .color) ?? d.color
    }
}

extension LightingSettings {
    /// The Sky in effect: Lighting's, or a Roblox place's default one.
    var skyInEffect: SkySettings { skyObject ?? SkySettings() }
}
