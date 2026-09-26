import Foundation
import simd

/// What the places built in code share — Adventure Island and Nightfall: adding parts,
/// Models, scripts, shaders and lights to a `SceneState`, and a seeded random number
/// generator so a scatter of trees lands in the same places every time.
protocol PlaceBuilding {
    var state: SceneState { get set }
    var seed: UInt32 { get set }
}

extension PlaceBuilding {
    /// A Sound: in a part (heard from there, up to `reach` studs), or everywhere.
    /// `playing` starts it when the game does.
    @discardableResult
    mutating func sound(_ name: String, _ soundId: String, in part: UUID? = nil, volume: Float = 0.5,
                        looped: Bool = false, playing: Bool = false, reach: Float = 100) -> UUID {
        var sound = SceneSound(name: name, parentID: part)
        sound.soundId = soundId
        sound.volume = volume
        sound.looped = looped
        sound.playing = playing
        sound.rollOffMaxDistance = reach
        state.sounds.append(sound)
        return sound.id
    }

    mutating func random(_ low: Float, _ high: Float) -> Float {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return low + Float(seed >> 8) / Float(1 << 24) * (high - low)
    }

    @discardableResult
    mutating func part(_ name: String, _ position: Vec3, _ size: Vec3, _ color: Vec3,
                       shape: PartShape = .block, material: PartMaterial = .plastic, rotation: Vec3 = .zero,
                       in parent: UUID? = nil, collide: Bool = true, transparency: Float = 0,
                       shader: UUID? = nil, light: PointLight? = nil) -> UUID {
        var part = Part()
        part.name = name
        part.shape = shape
        part.position = position
        part.size = size
        part.color = color
        part.material = material
        part.rotationDegrees = rotation
        part.parentID = parent
        part.canCollide = collide
        part.transparency = transparency
        part.shaderID = shader
        part.light = light
        state.parts.append(part)
        return part.id
    }

    mutating func group(_ name: String, kind: SceneGroup.Kind = .model, in parent: UUID? = nil) -> UUID {
        let group = SceneGroup(name: name, kind: kind, parentID: parent)
        state.groups.append(group)
        return group.id
    }

    mutating func script(_ name: String, _ source: String, in parent: UUID? = nil, host: ScriptHost = .scene,
                         module: Bool = false) {
        var script = ScriptObject.blank(language: .luau)
        script.name = name
        script.source = source
        script.host = host
        script.parentID = parent
        if module { script.kind = .module }
        state.scripts.append(script)
    }

    mutating func shader(_ name: String, _ kind: ShaderKind, _ source: String, _ parameters: [(String, Float)]) -> UUID {
        var shader = ShaderObject.blank(kind: kind)
        shader.name = name
        shader.source = source
        shader.parameters = parameters.map { ShaderParameter(name: $0.0, value: $0.1) }
        state.shaders.append(shader)
        return shader.id
    }

    func light(_ color: Vec3, brightness: Float = 2, range: Float = 16, shadows: Bool = false) -> PointLight {
        var light = PointLight()
        light.color = color
        light.brightness = brightness
        light.range = range
        light.shadows = shadows
        return light
    }
}
