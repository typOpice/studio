import Foundation

/// A named number a shader exposes, editable in the inspector and settable from Wren.
struct ShaderParameter: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var value: Float

    private enum CodingKeys: String, CodingKey { case id, name, value }

    init(name: String, value: Float) {
        self.name = name
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "value"
        value = try c.decodeIfPresent(Float.self, forKey: .value) ?? 0
    }
}

enum ShaderKind: String, Codable, CaseIterable, Identifiable {
    /// Shades the surface of a part.
    case surface
    /// Shades the finished picture — a sheet of glass in front of the camera.
    case screen

    var id: String { rawValue }
    var displayName: String { self == .surface ? "Surface" : "Screen" }
    var symbolName: String { self == .surface ? "paintbrush.pointed" : "camera.filters" }
}

/// A user-written surface shader.
///
/// Only the body of a fragment function is stored — the host wraps it in the
/// boilerplate that declares the inputs, so a mistake can never desync the uniform
/// layout or break the vertex stage. See `ShaderSource.wrap`.
struct ShaderObject: Identifiable, Codable, Equatable {
    /// Metal is given `params0` to `params3`, so sixteen named floats fit.
    static let maximumParameters = 16

    var id: UUID = UUID()
    var name: String = "Shader"
    var kind: ShaderKind = .surface
    var source: String = ShaderObject.template
    var enabled: Bool = true
    var parameters: [ShaderParameter] = [ShaderParameter(name: "amount", value: 1)]

    func parameter(named name: String) -> ShaderParameter? {
        parameters.first { $0.name == name }
    }

    /// A blank shader of the given kind, starting from that kind's template.
    static func blank(kind: ShaderKind) -> ShaderObject {
        var shader = ShaderObject()
        shader.kind = kind
        shader.source = kind == .surface ? template : screenTemplate
        shader.parameters = [ShaderParameter(name: "amount", value: 1)]
        return shader
    }

    static let template = """
    // Return the colour for this pixel.
    //
    // Given to you: worldPosition, normal, viewDirection, lightDirection,
    // baseColor, cameraPosition, time, and the scene's lighting — shadow,
    // lightColor, ambientColor — plus every parameter by name.

    float diffuse = saturate(dot(normal, lightDirection)) * shadow;
    float3 lit = baseColor * (ambientColor + diffuse * lightColor * 0.85);

    return lit * amount;
    """

    /// A new screen shader starts out doing nothing at all.
    static let screenTemplate = """
    // A sheet of glass in front of the camera. This passes the picture straight
    // through — change the last line and you change how the whole world looks.
    //
    // Given to you: sceneColor, uv, resolution, time, depth, distance,
    // sample(uv) to read any other pixel — plus every parameter by name.

    return sceneColor;
    """

    /// The screen example that ships with the starter scene.
    static let blackAndWhiteExample = """
    // Black and white.
    //
    // Luma weights, not a plain average: the eye reads green as far brighter than
    // blue, so (r + g + b) / 3 gives a muddy grey that looks wrong. These are the
    // Rec. 709 weights every display already uses.
    float luma = dot(sceneColor, float3(0.2126, 0.7152, 0.0722));

    // `amount` is a parameter — drag its slider, or drive it from a Wren script.
    // At 0 the picture is untouched; at 1 it is fully grey.
    return mix(sceneColor, float3(luma), amount);

    // Things to try from here:
    //   return float3(luma > 0.5 ? 1.0 : 0.0);          // hard black and white
    //   return mix(sceneColor, float3(luma), saturate(distance / 120.0));
    //   return float3(luma) * float3(1.07, 0.98, 0.84); // sepia
    """

    /// The example that ships with the starter scene.
    static let pulseExample = """
    // A rim-lit pulse. Edit any line and the viewport updates as you pause typing.

    // 1. Ordinary lighting from the scene — sun, shadow and sky — so the shape
    //    still reads as solid and sits in the world.
    float diffuse = saturate(dot(normal, lightDirection)) * shadow;
    float3 lit = baseColor * (ambientColor + diffuse * lightColor * 0.85);

    // 2. A rim term: brightest where the surface turns away from the camera.
    float facing = saturate(dot(normal, viewDirection));
    float rim = pow(1.0 - facing, 2.5);

    // 3. `time` advances every frame, so this breathes. `speed` and `glow` are
    //    parameters — edit them below, or drive them from a Wren script.
    float pulse = 0.5 + 0.5 * sin(time * speed);

    float3 rimColor = float3(0.45, 0.85, 1.0);
    return lit + rimColor * rim * (0.35 + 0.65 * pulse) * glow;
    """
}
