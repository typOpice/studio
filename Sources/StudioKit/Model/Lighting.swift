import Foundation
import simd

/// How the scene is lit.
enum LightingTechnology: String, Codable, CaseIterable, Identifiable {
    /// Rasterised: a shadow map for the sun, point lights without shadows.
    case conventional = "Conventional"
    /// Hardware ray queries: soft sun and point-light shadows, ambient occlusion and
    /// reflections. Needs a GPU that can ray trace from a fragment shader.
    case rayTraced = "RayTraced"

    var id: String { rawValue }
    var displayName: String { self == .conventional ? "Conventional" : "Ray Traced" }
}

/// How many rays ray-traced lighting spends per pixel.
enum RayQuality: String, Codable, CaseIterable, Identifiable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    var id: String { rawValue }
    var shadowSamples: Int { switch self { case .low: 1; case .medium: 4; case .high: 8 } }
    var occlusionSamples: Int { switch self { case .low: 2; case .medium: 6; case .high: 12 } }
}

/// The scene's Lighting, after Roblox's Lighting service. Saved with the scene.
struct LightingSettings: Codable, Equatable {
    var technology = LightingTechnology.conventional
    /// Hours, 0–24. Moves the sun (and, at night, the moon).
    var clockTime: Float = 14
    /// Degrees: how high the sun climbs at noon.
    var geographicLatitude: Float = 41.73
    /// The sun's strength. 2 is the look the Studio has always had.
    var brightness: Float = 2
    /// Light that reaches everywhere, even caves.
    var ambient = Vec3(repeating: 70.0 / 255)
    /// Light from the sky, falling on surfaces that face up.
    var outdoorAmbient = Vec3(repeating: 128.0 / 255)
    /// Tints the sunlight.
    var colorShiftTop = Vec3(1, 1, 1)
    var globalShadows = true
    /// 0 is a hard edge; 1 very soft.
    var shadowSoftness: Float = 0.2
    /// Stops of exposure: +1 doubles everything, −1 halves it.
    var exposureCompensation: Float = 0
    var fogColor = Vec3(repeating: 192.0 / 255)
    var fogStart: Float = 0
    var fogEnd: Float = 100_000
    /// A sky that follows the time of day, instead of the plain dark background.
    var sky = true
    // Ray-traced only.
    var rayQuality = RayQuality.medium
    var reflections = true
    var ambientOcclusion = true
    /// Lighting's Sky, Atmosphere and Clouds (SkyObjects.swift), when it has them.
    var skyObject: SkySettings?
    var atmosphere: AtmosphereSettings?
    var clouds: CloudSettings?

    static let fogLimit: Float = 100_000

    init() {}

    private enum CodingKeys: String, CodingKey {
        case technology, clockTime, geographicLatitude, brightness, ambient, outdoorAmbient, colorShiftTop
        case globalShadows, shadowSoftness, exposureCompensation, fogColor, fogStart, fogEnd, sky
        case rayQuality, reflections, ambientOcclusion, skyObject, atmosphere, clouds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LightingSettings()
        technology = try c.decodeIfPresent(LightingTechnology.self, forKey: .technology) ?? d.technology
        clockTime = try c.decodeIfPresent(Float.self, forKey: .clockTime) ?? d.clockTime
        geographicLatitude = try c.decodeIfPresent(Float.self, forKey: .geographicLatitude) ?? d.geographicLatitude
        brightness = try c.decodeIfPresent(Float.self, forKey: .brightness) ?? d.brightness
        ambient = try c.decodeIfPresent(Vec3.self, forKey: .ambient) ?? d.ambient
        outdoorAmbient = try c.decodeIfPresent(Vec3.self, forKey: .outdoorAmbient) ?? d.outdoorAmbient
        colorShiftTop = try c.decodeIfPresent(Vec3.self, forKey: .colorShiftTop) ?? d.colorShiftTop
        globalShadows = try c.decodeIfPresent(Bool.self, forKey: .globalShadows) ?? d.globalShadows
        shadowSoftness = try c.decodeIfPresent(Float.self, forKey: .shadowSoftness) ?? d.shadowSoftness
        exposureCompensation = try c.decodeIfPresent(Float.self, forKey: .exposureCompensation) ?? d.exposureCompensation
        fogColor = try c.decodeIfPresent(Vec3.self, forKey: .fogColor) ?? d.fogColor
        fogStart = try c.decodeIfPresent(Float.self, forKey: .fogStart) ?? d.fogStart
        fogEnd = try c.decodeIfPresent(Float.self, forKey: .fogEnd) ?? d.fogEnd
        sky = try c.decodeIfPresent(Bool.self, forKey: .sky) ?? d.sky
        rayQuality = try c.decodeIfPresent(RayQuality.self, forKey: .rayQuality) ?? d.rayQuality
        reflections = try c.decodeIfPresent(Bool.self, forKey: .reflections) ?? d.reflections
        ambientOcclusion = try c.decodeIfPresent(Bool.self, forKey: .ambientOcclusion) ?? d.ambientOcclusion
        skyObject = try c.decodeIfPresent(SkySettings.self, forKey: .skyObject)
        atmosphere = try c.decodeIfPresent(AtmosphereSettings.self, forKey: .atmosphere)
        clouds = try c.decodeIfPresent(CloudSettings.self, forKey: .clouds)
    }

    // MARK: - The sun and the sky

    /// `clockTime` wrapped into 0–24.
    static func wrapHours(_ hours: Float) -> Float {
        let wrapped = hours.truncatingRemainder(dividingBy: 24)
        return wrapped < 0 ? wrapped + 24 : wrapped
    }

    /// Towards the sun, in world space (+X east, −Z north, +Y up), at the equinox:
    /// it rises in the east at 6:00, is highest at noon — due south, at
    /// 90° − latitude — and sets in the west at 18:00.
    var sunDirection: Vec3 {
        let hourAngle = (Self.wrapHours(clockTime) - 12) / 24 * 2 * .pi
        let latitude = min(max(geographicLatitude, -89), 89) * .pi / 180
        return normalize(Vec3(-sin(hourAngle), cos(hourAngle) * cos(latitude), cos(hourAngle) * sin(latitude)))
    }

    /// Where the light comes from: the sun by day, the moon (opposite it) by night.
    var lightDirection: Vec3 {
        let sun = sunDirection
        return sun.y > -0.05 ? sun : -sun
    }

    /// How much of the day's light there is: 1 in daylight, fading through dawn and
    /// dusk to the moon's 0.12.
    var daylight: Float {
        let height = sunDirection.y
        return 0.12 + 0.88 * Self.smoothstep(-0.1, 0.15, height)
    }

    /// The sunlight's colour and strength: warm near the horizon, white overhead,
    /// cool and dim by moonlight; tinted by `colorShiftTop` and scaled by `brightness`.
    var sunLight: Vec3 {
        let height = sunDirection.y
        let low = Self.smoothstep(0.35, 0.0, abs(height))
        var tint = simd_mix(Vec3(1, 1, 1), Vec3(1.0, 0.62, 0.36), Vec3(repeating: low))
        if height < -0.05 { tint = Vec3(0.55, 0.62, 0.85) }
        let strength = max(brightness, 0) * 0.425 * (height < -0.05 ? 0.25 : Self.smoothstep(-0.05, 0.08, height))
        return tint * colorShiftTop * strength
    }

    /// The sky straight up and at the horizon for this time of day.
    var skyColors: (zenith: Vec3, horizon: Vec3) {
        let height = sunDirection.y
        let day = Self.smoothstep(-0.12, 0.2, height)
        let dusk = Self.smoothstep(0.35, 0.0, abs(height)) * Self.smoothstep(-0.2, -0.02, height)
        let zenith = simd_mix(Vec3(0.02, 0.03, 0.07), Vec3(0.24, 0.45, 0.82), Vec3(repeating: day))
        var horizon = simd_mix(Vec3(0.05, 0.06, 0.1), Vec3(0.68, 0.78, 0.9), Vec3(repeating: day))
        horizon = simd_mix(horizon, Vec3(0.95, 0.55, 0.3), Vec3(repeating: dusk * 0.8))
        return (zenith, horizon)
    }

    /// "14:30:00", as Roblox's TimeOfDay.
    var timeOfDay: String {
        let total = Int((Self.wrapHours(clockTime) * 3600).rounded()) % 86_400
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    /// Parses "HH:MM" or "HH:MM:SS" into hours.
    static func hours(fromTimeOfDay text: String) -> Float? {
        let fields = text.split(separator: ":").map { Float($0.trimmingCharacters(in: .whitespaces)) }
        guard (2...3).contains(fields.count), fields.allSatisfy({ $0 != nil }) else { return nil }
        let values = fields.map { $0! }
        return values[0] + values[1] / 60 + (values.count == 3 ? values[2] / 3600 : 0)
    }

    static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// A PointLight inside a part: light shining out in every direction from its centre.
struct PointLight: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case point = "PointLight", spot = "SpotLight", surface = "SurfaceLight"
        var id: String { rawValue }
    }
    var id = UUID()
    var kind = Kind.point
    var name = "PointLight"
    var face = ParticleEmitter.Face.front
    /// Full emission angle in degrees.
    var angle: Float = 90
    var enabled = true
    var color = Vec3(1, 1, 1)
    var brightness: Float = 1
    /// Studs; nothing past it is lit.
    var range: Float = 8
    /// Ray-traced lighting only: whether other parts block it.
    var shadows = false

    static let maximumRange: Float = 60
    /// Point lights per frame; the nearest to the camera win.
    static let maximumPerFrame = 16

    init(kind: Kind = .point) { self.kind = kind; name = kind.rawValue }

    private enum CodingKeys: String, CodingKey { case id, kind, name, face, angle, enabled, color, brightness, range, shadows }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .point
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? kind.rawValue
        face = try c.decodeIfPresent(ParticleEmitter.Face.self, forKey: .face) ?? .front
        angle = min(max(try c.decodeIfPresent(Float.self, forKey: .angle) ?? 90, 0), 180)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        color = try c.decodeIfPresent(Vec3.self, forKey: .color) ?? Vec3(1, 1, 1)
        brightness = try c.decodeIfPresent(Float.self, forKey: .brightness) ?? 1
        range = try c.decodeIfPresent(Float.self, forKey: .range) ?? 8
        shadows = try c.decodeIfPresent(Bool.self, forKey: .shadows) ?? false
    }
}
