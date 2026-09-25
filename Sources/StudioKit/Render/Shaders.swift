import simd

/// Mirrors `FrameUniforms` in the Metal source (112 bytes).
struct FrameUniforms {
    var viewProjection: float4x4 = matrix_identity_float4x4
    var cameraPosition: Vec4 = .zero
    var lightDirection: Vec4 = .zero
    /// x: seconds since the renderer started, y: seconds since the last frame.
    var timing: Vec4 = .zero
}

/// Mirrors `ShaderUniforms` in the Metal source (64 bytes): sixteen named floats
/// that a user shader reads by name and scripts can drive.
struct ShaderUniforms {
    var params0: Vec4 = .zero
    var params1: Vec4 = .zero
    var params2: Vec4 = .zero
    var params3: Vec4 = .zero

    init(_ values: [Float] = []) {
        (params0, params1, params2, params3) = Self.blocks(values)
    }

    /// Parameter values four to a block, in order; any past the sixteenth are dropped.
    static func blocks(_ values: [Float]) -> (Vec4, Vec4, Vec4, Vec4) {
        var blocks = [Vec4](repeating: .zero, count: 4)
        for (index, value) in values.prefix(ShaderObject.maximumParameters).enumerated() {
            blocks[index / 4][index % 4] = value
        }
        return (blocks[0], blocks[1], blocks[2], blocks[3])
    }
}

/// Mirrors `DrawUniforms` in the Metal source (144 bytes).
struct DrawUniforms {
    var model: float4x4 = matrix_identity_float4x4
    var normalMatrix: float3x3 = matrix_identity_float3x3
    var color: Vec4 = Vec4(1, 1, 1, 1)
    /// x: specular strength, y: shininess, z: emissive, w: rim highlight
    var shading: Vec4 = Vec4(0.3, 24, 0, 0)
}

/// Mirrors `ScreenUniforms` in a generated screen shader (112 bytes).
struct ScreenUniforms {
    var resolution: Vec4 = .zero
    var timing: Vec4 = .zero
    var planes: Vec4 = .zero
    var params0: Vec4 = .zero
    var params1: Vec4 = .zero
    var params2: Vec4 = .zero
    var params3: Vec4 = .zero

    init(size: SIMD2<Float> = .zero, time: Float = 0, near: Float = 0.1, far: Float = 3000,
         values: [Float] = []) {
        resolution = Vec4(size.x, size.y,
                          size.x > 0 ? 1 / size.x : 0,
                          size.y > 0 ? 1 / size.y : 0)
        timing = Vec4(time, 0, 0, 0)
        planes = Vec4(near, far, 0, 0)
        (params0, params1, params2, params3) = ShaderUniforms.blocks(values)
    }
}

/// Metal source compiled at runtime, so the app needs no offline `metal` toolchain.
private let metalStructs = #"""
#include <metal_stdlib>
using namespace metal;

struct VertexData {
    float3 position;
    float3 normal;
};

struct FrameUniforms {
    float4x4 viewProjection;
    float4 cameraPosition;
    float4 lightDirection;
    float4 timing;
};

struct DrawUniforms {
    float4x4 model;
    float3x3 normalMatrix;
    float4 color;
    float4 shading;
};

struct RasterData {
    float4 clipPosition [[position]];
    float3 worldPosition;
    float3 normal;
};

"""#

/// Metal source compiled at runtime, so the app needs no offline `metal` toolchain.
/// The shared lighting library sits between the structs and the shaders.
let metalShaderSource = metalStructs + lightingMetalSource + metalShaders

private let metalShaders = #"""
vertex RasterData scene_vertex(uint vid [[vertex_id]],
                               device const VertexData *vertices [[buffer(0)]],
                               constant FrameUniforms &frame [[buffer(1)]],
                               constant DrawUniforms &draw [[buffer(2)]])
{
    VertexData v = vertices[vid];
    float4 world = draw.model * float4(v.position, 1.0);
    RasterData out;
    out.clipPosition = frame.viewProjection * world;
    out.worldPosition = world.xyz;
    out.normal = draw.normalMatrix * v.normal;
    return out;
}

// The lit colour of a surface point: the scene's parts, textured or not, share it.
static float4 studio_scene_color(float3 worldPosition, float3 normal, float2 pixel, float3 base,
                                 constant FrameUniforms &frame, constant DrawUniforms &draw,
                                 constant LightingUniforms &lighting, constant PointLightData *pointLights,
                                 depth2d<float> shadowMap STUDIO_RT_DECL)
{
    float3 n = normalize(normal);
    float3 l = normalize(lighting.sunDirection.xyz);
    float3 v = normalize(frame.cameraPosition.xyz - worldPosition);

    float sun = studio_sun_visibility(worldPosition, n, pixel, lighting, shadowMap STUDIO_RT_ARGS);
    float occlusion = studio_occlusion(worldPosition, n, pixel, lighting STUDIO_RT_ARGS);
    float ndotl = max(dot(n, l), 0.0);
    float3 color = base * (studio_ambient(n, occlusion, lighting) + ndotl * sun * lighting.sunColor.rgb);

    float3 h = normalize(l + v);
    float spec = pow(max(dot(n, h), 0.0), max(draw.shading.y, 1.0)) * draw.shading.x;
    color += spec * mix(float3(1.0), base, 0.35) * step(0.001, ndotl) * sun * (lighting.sunColor.rgb / 0.85);

    color += studio_point_lights(worldPosition, n, v, base, draw.shading.x, draw.shading.y,
                                 lighting, pointLights STUDIO_RT_ARGS);

#if STUDIO_RAYTRACING
    // Shiny materials reflect what is really around them.
    if (studioRayTraced && lighting.rayParams.z > 0.5) {
        float reflectivity = saturate(draw.shading.x * 0.7 - 0.12);
        if (reflectivity > 0.01) {
            float3 r = reflect(-v, n);
            float fresnel = reflectivity + (1.0 - reflectivity) * pow(1.0 - saturate(dot(n, v)), 5.0) * 0.5;
            float3 seen = studio_ray_reflection(worldPosition, n, r, lighting, accel, instances, faceNormals);
            color = mix(color, seen * mix(float3(1.0), base, 0.5), saturate(fresnel));
        }
    }
#endif

    // Neon-style emissive.
    color = mix(color, base * 1.35, draw.shading.z);
    color = studio_finish(color, worldPosition, frame.cameraPosition.xyz, lighting);
    return float4(color, draw.color.a);
}

fragment float4 scene_fragment(RasterData in [[stage_in]],
                               constant FrameUniforms &frame [[buffer(1)]],
                               constant DrawUniforms &draw [[buffer(2)]]
                               STUDIO_LIGHTING_PARAMS)
{
    return studio_scene_color(in.worldPosition, in.normal, in.clipPosition.xy, draw.color.rgb, frame, draw,
                              STUDIO_LIGHTING_ARGS);
}

// A MeshPart with a TextureID: its picture, tinted by the part's colour, lit as any part.
struct RasterTextured {
    float4 clipPosition [[position]];
    float3 worldPosition;
    float3 normal;
    float2 uv;
};

vertex RasterTextured scene_vertex_textured(uint vid [[vertex_id]],
                                            device const VertexData *vertices [[buffer(0)]],
                                            constant FrameUniforms &frame [[buffer(1)]],
                                            constant DrawUniforms &draw [[buffer(2)]],
                                            device const float2 *uvs [[buffer(3)]])
{
    VertexData v = vertices[vid];
    float4 world = draw.model * float4(v.position, 1.0);
    RasterTextured out;
    out.clipPosition = frame.viewProjection * world;
    out.worldPosition = world.xyz;
    out.normal = draw.normalMatrix * v.normal;
    out.uv = uvs[vid];
    return out;
}

fragment float4 scene_fragment_textured(RasterTextured in [[stage_in]],
                                        constant FrameUniforms &frame [[buffer(1)]],
                                        constant DrawUniforms &draw [[buffer(2)]]
                                        STUDIO_LIGHTING_PARAMS,
                                        texture2d<float> meshTexture [[texture(3)]])
{
    constexpr sampler picture(filter::linear, mip_filter::linear, address::repeat);
    float4 texel = meshTexture.sample(picture, in.uv);
    float4 lit = studio_scene_color(in.worldPosition, in.normal, in.clipPosition.xy, draw.color.rgb * texel.rgb,
                                    frame, draw, STUDIO_LIGHTING_ARGS);
    return float4(lit.rgb, lit.a * texel.a);
}

// A body part in clothes: the picture laid over the body colour where it is opaque,
// as Roblox's shirts and pants are.
fragment float4 scene_fragment_clothed(RasterTextured in [[stage_in]],
                                       constant FrameUniforms &frame [[buffer(1)]],
                                       constant DrawUniforms &draw [[buffer(2)]]
                                       STUDIO_LIGHTING_PARAMS,
                                       texture2d<float> meshTexture [[texture(3)]])
{
    constexpr sampler picture(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float4 texel = meshTexture.sample(picture, in.uv);
    float3 base = mix(draw.color.rgb, texel.rgb / max(texel.a, 0.001), texel.a);
    return studio_scene_color(in.worldPosition, in.normal, in.clipPosition.xy, base,
                              frame, draw, STUDIO_LIGHTING_ARGS);
}

// Flat-shaded pass used for gizmo handles and selection outlines.
fragment float4 flat_fragment(RasterData in [[stage_in]],
                              constant FrameUniforms &frame [[buffer(1)]],
                              constant DrawUniforms &draw [[buffer(2)]])
{
    float3 n = normalize(in.normal);
    float3 l = normalize(frame.lightDirection.xyz);
    float shade = 0.72 + 0.28 * max(dot(n, l), 0.0);
    float3 color = draw.color.rgb * mix(1.0, shade, draw.shading.z);
    return float4(color, draw.color.a);
}

// Procedural studded baseplate grid on an infinite-looking ground plane.
fragment float4 grid_fragment(RasterData in [[stage_in]],
                              constant FrameUniforms &frame [[buffer(1)]],
                              constant DrawUniforms &draw [[buffer(2)]]
                              STUDIO_LIGHTING_PARAMS)
{
    float2 p = in.worldPosition.xz;

    float2 dMinor = fwidth(p);
    float2 minorGrid = abs(fract(p / 1.0 - 0.5) - 0.5) / max(dMinor / 1.0, 1e-5);
    float minorLine = 1.0 - min(min(minorGrid.x, minorGrid.y), 1.0);

    float2 majorGrid = abs(fract(p / 8.0 - 0.5) - 0.5) / max(dMinor / 8.0, 1e-5);
    float majorLine = 1.0 - min(min(majorGrid.x, majorGrid.y), 1.0);

    float3 baseColor = float3(0.176, 0.192, 0.216);
    float3 color = baseColor;
    color = mix(color, float3(0.27, 0.29, 0.33), minorLine * 0.85);
    color = mix(color, float3(0.40, 0.43, 0.49), majorLine * 0.9);

    // World axes through the origin.
    float axisX = 1.0 - min(abs(p.y) / max(dMinor.y, 1e-5) / 1.6, 1.0);
    float axisZ = 1.0 - min(abs(p.x) / max(dMinor.x, 1e-5) / 1.6, 1.0);
    color = mix(color, float3(0.86, 0.30, 0.32), axisX * 0.95);
    color = mix(color, float3(0.31, 0.53, 0.92), axisZ * 0.95);

    // Lit like any other surface facing up, so shadows fall on it; at the default
    // lighting this comes out close to 1 and the grid looks as it always has.
    float3 up = float3(0.0, 1.0, 0.0);
    float2 pixel = in.clipPosition.xy;
    float sun = studio_sun_visibility(in.worldPosition, up, pixel, lighting, shadowMap STUDIO_RT_ARGS);
    float occlusion = studio_occlusion(in.worldPosition, up, pixel, lighting STUDIO_RT_ARGS);
    float3 toLight = normalize(lighting.sunDirection.xyz);
    float3 light = studio_ambient(up, occlusion, lighting) + max(toLight.y, 0.0) * sun * lighting.sunColor.rgb;
    color *= light;
    color += studio_point_lights(in.worldPosition, up, normalize(frame.cameraPosition.xyz - in.worldPosition),
                                 baseColor, 0.1, 8.0, lighting, pointLights STUDIO_RT_ARGS);
    color *= lighting.ambient.w;

    float dist = length(in.worldPosition - frame.cameraPosition.xyz);
    float fade = 1.0 - smoothstep(90.0, 420.0, dist);
    float alpha = clamp(fade, 0.0, 1.0);
    return float4(color, alpha);
}

// The sky: one full-screen triangle behind everything, coloured by direction.
struct SkyVertex {
    float4 position [[position]];
    float2 ndc;
};

vertex SkyVertex sky_vertex(uint vid [[vertex_id]])
{
    float2 uv = float2((vid << 1) & 2, vid & 2);
    SkyVertex out;
    out.ndc = uv * 2.0 - 1.0;
    out.position = float4(out.ndc, 1.0, 1.0);
    return out;
}

fragment float4 sky_fragment(SkyVertex in [[stage_in]],
                             constant FrameUniforms &frame [[buffer(1)]],
                             constant LightingUniforms &lighting [[buffer(4)]])
{
    float4 far = lighting.inverseViewProjection * float4(in.ndc, 1.0, 1.0);
    float3 direction = normalize(far.xyz / far.w - frame.cameraPosition.xyz);
    return float4(studio_sky(direction, lighting) * lighting.ambient.w, 1.0);
}
"""#
