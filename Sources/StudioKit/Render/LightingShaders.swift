import simd

/// Mirrors `LightingUniforms` in `lightingMetalSource` (272 bytes). Bound at fragment
/// buffer 4 for every lit pipeline — built-in and user shaders alike.
struct LightingUniforms {
    var shadowViewProjection: float4x4 = matrix_identity_float4x4
    var inverseViewProjection: float4x4 = matrix_identity_float4x4
    /// xyz: towards the light (sun or moon). w: 1 when shadows are on.
    var sunDirection: Vec4 = Vec4(0, 1, 0, 1)
    /// rgb: the light's colour × strength. w: shadow softness, 0–1.
    var sunColor: Vec4 = Vec4(0.85, 0.85, 0.85, 0.2)
    /// rgb: ambient everywhere. w: exposure multiplier.
    var ambient: Vec4 = Vec4(0.27, 0.27, 0.27, 1)
    /// rgb: light from the sky. w: how many point lights are bound.
    var outdoorAmbient: Vec4 = Vec4(0.5, 0.5, 0.5, 0)
    /// rgb: fog colour. w: fog start.
    var fogColor: Vec4 = Vec4(0.75, 0.75, 0.75, 0)
    /// x: fog end, y: 1 when the ground plane is there, z: shadow-map texel in studs,
    /// w: 1 when the sky is drawn.
    var fogParams: Vec4 = Vec4(100_000, 1, 0.1, 1)
    /// rgb: sky straight up.
    var skyZenith: Vec4 = .zero
    /// rgb: sky at the horizon. w: daylight, 0 (night) – 1.
    var skyHorizon: Vec4 = .zero
    /// x: sun shadow rays, y: occlusion rays, z: 1 for reflections, w: occlusion radius.
    var rayParams: Vec4 = Vec4(4, 6, 1, 4)

    init() {}

    /// Everything the shaders need about the lighting for one frame.
    init(settings: LightingSettings, shadowViewProjection: float4x4, inverseViewProjection: float4x4,
         shadowTexel: Float, pointLights: Int, groundPlane: Bool) {
        self.shadowViewProjection = shadowViewProjection
        self.inverseViewProjection = inverseViewProjection
        sunDirection = Vec4(settings.lightDirection, settings.globalShadows ? 1 : 0)
        sunColor = Vec4(settings.sunLight, min(max(settings.shadowSoftness, 0), 1))
        let daylight = settings.daylight
        ambient = Vec4(settings.ambient * (0.35 + 0.65 * daylight), exp2(settings.exposureCompensation))
        outdoorAmbient = Vec4(settings.outdoorAmbient * daylight, Float(pointLights))
        let fogEnd = max(settings.fogEnd, settings.fogStart + 0.01)
        fogColor = Vec4(settings.fogColor, settings.fogStart)
        fogParams = Vec4(fogEnd, groundPlane ? 1 : 0, shadowTexel, settings.sky ? 1 : 0)
        let sky = settings.skyColors
        skyZenith = Vec4(sky.zenith, 0)
        skyHorizon = Vec4(sky.horizon, daylight)
        rayParams = Vec4(Float(settings.rayQuality.shadowSamples),
                         settings.ambientOcclusion ? Float(settings.rayQuality.occlusionSamples) : 0,
                         settings.reflections ? 1 : 0, 4)
    }
}

/// Mirrors `PointLightData` (48 bytes).
struct PointLightData {
    /// xyz: where, w: range.
    var positionRange: Vec4 = .zero
    /// rgb: colour, w: brightness.
    var colorBrightness: Vec4 = .zero
    /// x: 1 when it casts ray-traced shadows.
    var options: Vec4 = .zero
}

/// Mirrors `InstanceInfo` (96 bytes): what a ray needs to shade what it hits.
struct InstanceInfo {
    var normal0: Vec4 = .zero
    var normal1: Vec4 = .zero
    var normal2: Vec4 = .zero
    var color: Vec4 = .zero
    var shading: Vec4 = .zero
    /// x: where this instance's mesh starts in the face-normal buffer.
    var extra: SIMD4<UInt32> = .zero
}

/// Shared by the built-in shaders and every user surface shader, so parts lit either
/// way get the same sun, shadows, point lights, fog and exposure.
///
/// Compiled with `STUDIO_RAYTRACING` defined when the GPU can ray trace; each lit
/// pipeline is then made twice, with the `studioRayTraced` function constant off and on.
let lightingMetalSource = #"""
constant bool studioRayTraced [[function_constant(0)]];

struct LightingUniforms {
    float4x4 shadowViewProjection;
    float4x4 inverseViewProjection;
    float4 sunDirection;
    float4 sunColor;
    float4 ambient;
    float4 outdoorAmbient;
    float4 fogColor;
    float4 fogParams;
    float4 skyZenith;
    float4 skyHorizon;
    float4 rayParams;
};

struct PointLightData {
    float4 positionRange;
    float4 colorBrightness;
    float4 options;
};

#if STUDIO_RAYTRACING
#include <metal_raytracing>
using namespace metal::raytracing;

struct InstanceInfo {
    float4 normal0;
    float4 normal1;
    float4 normal2;
    float4 color;
    float4 shading;
    uint4 extra;
};

#define STUDIO_RT_PARAMS , instance_acceleration_structure accel [[buffer(6), function_constant(studioRayTraced)]], device const InstanceInfo *instances [[buffer(7), function_constant(studioRayTraced)]], device const float4 *faceNormals [[buffer(8), function_constant(studioRayTraced)]]
#define STUDIO_RT_DECL , instance_acceleration_structure accel, device const InstanceInfo *instances, device const float4 *faceNormals
#define STUDIO_RT_ARGS , accel, instances, faceNormals
#else
#define STUDIO_RT_PARAMS
#define STUDIO_RT_DECL
#define STUDIO_RT_ARGS
#endif

#define STUDIO_LIGHTING_PARAMS , constant LightingUniforms &lighting [[buffer(4)]], constant PointLightData *pointLights [[buffer(5)]], depth2d<float> shadowMap [[texture(0)]] STUDIO_RT_PARAMS
#define STUDIO_LIGHTING_ARGS lighting, pointLights, shadowMap STUDIO_RT_ARGS

// Instance masks: parts that hold a light are left out of that light's shadow rays.
constant uint studioMaskSolid = 1;
constant uint studioMaskLightHousing = 2;

// Interleaved gradient noise: a stable, well-spread value per pixel.
static float studio_noise(float2 pixel) {
    return fract(52.9829189 * fract(dot(pixel, float2(0.06711056, 0.00583715))));
}

static float3 studio_sky(float3 direction, constant LightingUniforms &lighting) {
    float h = direction.y;
    float3 zenith = lighting.skyZenith.rgb;
    float3 horizon = lighting.skyHorizon.rgb;
    float3 color = mix(horizon, zenith, pow(saturate(h), 0.5));
    float3 ground = horizon * 0.55 + float3(0.02);
    if (h < 0.0) { color = mix(horizon, ground, saturate(-h * 5.0)); }

    float3 toLight = normalize(lighting.sunDirection.xyz);
    float facing = saturate(dot(direction, toLight));
    bool day = lighting.skyHorizon.w > 0.3;
    float3 glowColor = day ? float3(1.0, 0.85, 0.6) : float3(0.6, 0.65, 0.8);
    color += glowColor * (pow(facing, 12.0) * 0.18 + pow(facing, 200.0) * 0.5) * (day ? 1.0 : 0.4);
    float disc = smoothstep(0.9993, 0.9997, dot(direction, toLight));
    color = mix(color, day ? float3(1.6, 1.5, 1.3) : float3(0.85, 0.88, 0.95), disc * step(-0.02, toLight.y));
    return color;
}

static float studio_shadow_map(float3 position, float3 normal, constant LightingUniforms &lighting,
                               depth2d<float> shadowMap, float2 pixel) {
    float3 toLight = normalize(lighting.sunDirection.xyz);
    float texel = lighting.fogParams.z;
    float slope = 1.0 - saturate(dot(normal, toLight));
    float3 offset = position + normal * texel * (1.5 + 3.0 * slope);
    float4 clip = lighting.shadowViewProjection * float4(offset, 1.0);
    float3 ndc = clip.xyz / clip.w;
    float2 uv = ndc.xy * float2(0.5, -0.5) + 0.5;
    if (any(uv < 0.0) || any(uv > 1.0) || ndc.z > 1.0 || ndc.z < 0.0) { return 1.0; }

    constexpr sampler compare(coord::normalized, filter::linear, address::clamp_to_edge,
                              compare_func::less_equal);
    const float2 disk[12] = {
        float2(-0.326, -0.406), float2(-0.840, -0.074), float2(-0.696, 0.457), float2(-0.203, 0.621),
        float2(0.962, -0.195), float2(0.473, -0.480), float2(0.519, 0.767), float2(0.185, -0.893),
        float2(0.507, 0.064), float2(0.896, 0.412), float2(-0.322, -0.933), float2(-0.792, -0.598)
    };
    float radius = (1.0 + lighting.sunColor.w * 10.0) / float(shadowMap.get_width());
    float angle = studio_noise(pixel) * 6.2831853;
    float2x2 turn = float2x2(float2(cos(angle), sin(angle)), float2(-sin(angle), cos(angle)));
    float lit = 0.0;
    for (int i = 0; i < 12; i++) {
        lit += shadowMap.sample_compare(compare, uv + turn * disk[i] * radius, ndc.z - 0.0004);
    }
    return lit / 12.0;
}

#if STUDIO_RAYTRACING
static bool studio_blocked(float3 origin, float3 direction, float distance, uint mask,
                           instance_acceleration_structure accel) {
    ray r(origin, direction, 0.0, distance);
    intersector<triangle_data, instancing> query;
    query.accept_any_intersection(true);
    query.assume_geometry_type(geometry_type::triangle);
    query.force_opacity(forced_opacity::opaque);
    return query.intersect(r, accel, mask).type != intersection_type::none;
}

// A direction inside a cone around `axis`, from two numbers in 0–1.
static float3 studio_cone(float3 axis, float halfAngle, float2 u) {
    float cosTheta = 1.0 - u.x * (1.0 - cos(halfAngle));
    float sinTheta = sqrt(max(0.0, 1.0 - cosTheta * cosTheta));
    float phi = u.y * 6.2831853;
    float3 up = abs(axis.y) < 0.99 ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 x = normalize(cross(up, axis));
    float3 y = cross(axis, x);
    return normalize(x * cos(phi) * sinTheta + y * sin(phi) * sinTheta + axis * cosTheta);
}

static float2 studio_sample(uint index, uint count, float2 pixel) {
    // A rotated Fibonacci pattern: even coverage with few rays.
    float r = studio_noise(pixel);
    float a = fract(float(index) * 0.618034 + r);
    float b = (float(index) + fract(r * 7.13)) / float(max(count, 1u));
    return float2(b, a);
}

static float studio_ray_sun(float3 position, float3 normal, constant LightingUniforms &lighting,
                            float2 pixel, instance_acceleration_structure accel) {
    float3 toLight = normalize(lighting.sunDirection.xyz);
    if (dot(normal, toLight) <= 0.0) { return 0.0; }
    uint count = uint(max(lighting.rayParams.x, 1.0));
    float halfAngle = 0.004 + lighting.sunColor.w * 0.09;
    float3 origin = position + normal * 0.03;
    float lit = 0.0;
    for (uint i = 0; i < count; i++) {
        float3 direction = studio_cone(toLight, halfAngle, studio_sample(i, count, pixel));
        lit += studio_blocked(origin, direction, 2000.0, 0xFF, accel) ? 0.0 : 1.0;
    }
    return lit / float(count);
}

static float studio_ray_occlusion(float3 position, float3 normal, constant LightingUniforms &lighting,
                                  float2 pixel, instance_acceleration_structure accel) {
    uint count = uint(lighting.rayParams.y);
    if (count == 0) { return 1.0; }
    float radius = lighting.rayParams.w;
    float3 origin = position + normal * 0.03;
    float hidden = 0.0;
    for (uint i = 0; i < count; i++) {
        float2 u = studio_sample(i, count, pixel + 17.0);
        // Cosine-weighted around the normal.
        float3 direction = studio_cone(normal, 1.5707963, float2(u.x * u.x, u.y));
        bool blocked = studio_blocked(origin, direction, radius, 0xFF, accel);
        if (!blocked && lighting.fogParams.y > 0.5 && direction.y < -0.01 && origin.y > 0.0) {
            blocked = origin.y / -direction.y < radius;
        }
        hidden += blocked ? 1.0 : 0.0;
    }
    return 1.0 - 0.85 * hidden / float(count);
}

// The colour seen along a reflected ray: another part, the ground, or the sky.
static float3 studio_ray_reflection(float3 position, float3 normal, float3 direction,
                                    constant LightingUniforms &lighting,
                                    instance_acceleration_structure accel,
                                    device const InstanceInfo *instances,
                                    device const float4 *faceNormals) {
    float3 origin = position + normal * 0.03;
    ray r(origin, direction, 0.0, 2000.0);
    intersector<triangle_data, instancing> query;
    query.assume_geometry_type(geometry_type::triangle);
    query.force_opacity(forced_opacity::opaque);
    auto hit = query.intersect(r, accel, 0xFF);

    float groundDistance = INFINITY;
    if (lighting.fogParams.y > 0.5 && direction.y < -0.001 && origin.y > 0.0) {
        groundDistance = origin.y / -direction.y;
    }
    float3 toLight = normalize(lighting.sunDirection.xyz);
    bool shadows = lighting.sunDirection.w > 0.5;

    if (hit.type != intersection_type::none && hit.distance < groundDistance) {
        InstanceInfo info = instances[hit.instance_id];
        float3 local = faceNormals[info.extra.x + hit.primitive_id].xyz;
        float3x3 toWorld = float3x3(info.normal0.xyz, info.normal1.xyz, info.normal2.xyz);
        float3 n = normalize(toWorld * local);
        if (dot(n, direction) > 0.0) { n = -n; }
        float3 point = origin + direction * hit.distance;
        float lit = max(dot(n, toLight), 0.0);
        if (shadows && lit > 0.0 && studio_blocked(point + n * 0.03, toLight, 2000.0, 0xFF, accel)) { lit = 0.0; }
        float sky = 0.5 + 0.5 * n.y;
        float3 ambient = lighting.ambient.rgb * 0.8 + lighting.outdoorAmbient.rgb * 0.6 * sky;
        float3 color = info.color.rgb * (ambient + lit * lighting.sunColor.rgb);
        return mix(color, info.color.rgb * 1.35, info.shading.z);
    }
    if (groundDistance < INFINITY) {
        float3 point = origin + direction * groundDistance;
        float lit = toLight.y > 0.0 ? toLight.y : 0.0;
        if (shadows && lit > 0.0 && studio_blocked(point + float3(0, 0.03, 0), toLight, 2000.0, 0xFF, accel)) { lit = 0.0; }
        float3 ground = float3(0.19, 0.205, 0.23);
        float3 color = ground * (lighting.ambient.rgb * 0.8 + lighting.outdoorAmbient.rgb * 0.6 + lit * lighting.sunColor.rgb);
        float fade = saturate(groundDistance / 400.0);
        return mix(color, studio_sky(direction, lighting), fade);
    }
    return studio_sky(direction, lighting);
}
#endif

// How much sunlight reaches this point: 1 lit, 0 in shadow.
static float studio_sun_visibility(float3 position, float3 normal, float2 pixel,
                                   constant LightingUniforms &lighting, depth2d<float> shadowMap
                                   STUDIO_RT_DECL) {
    if (lighting.sunDirection.w < 0.5) { return 1.0; }
#if STUDIO_RAYTRACING
    if (studioRayTraced) { return studio_ray_sun(position, normal, lighting, pixel, accel); }
#endif
    return studio_shadow_map(position, normal, lighting, shadowMap, pixel);
}

// How open this point is to the sky: 1 fully, less in corners and under things.
static float studio_occlusion(float3 position, float3 normal, float2 pixel,
                              constant LightingUniforms &lighting STUDIO_RT_DECL) {
#if STUDIO_RAYTRACING
    if (studioRayTraced) { return studio_ray_occlusion(position, normal, lighting, pixel, accel); }
#endif
    return 1.0;
}

static float3 studio_ambient(float3 normal, float occlusion, constant LightingUniforms &lighting) {
    float sky = 0.5 + 0.5 * normal.y;
    return (lighting.ambient.rgb * 0.8 + lighting.outdoorAmbient.rgb * 0.6 * sky) * occlusion;
}

// Every point light's contribution: diffuse plus a little specular.
static float3 studio_point_lights(float3 position, float3 normal, float3 view, float3 base,
                                  float specular, float shininess,
                                  constant LightingUniforms &lighting, constant PointLightData *pointLights
                                  STUDIO_RT_DECL) {
    float3 total = float3(0.0);
    int count = int(lighting.outdoorAmbient.w);
    for (int i = 0; i < count; i++) {
        PointLightData light = pointLights[i];
        float3 toLight = light.positionRange.xyz - position;
        float distance = length(toLight);
        float range = light.positionRange.w;
        if (distance >= range || distance < 1e-4) { continue; }
        float3 l = toLight / distance;
        float ndotl = max(dot(normal, l), 0.0);
        if (ndotl <= 0.0) { continue; }
        float falloff = 1.0 - distance / range;
        falloff *= falloff;
#if STUDIO_RAYTRACING
        if (studioRayTraced && light.options.x > 0.5 &&
            studio_blocked(position + normal * 0.03, l, distance - 0.05, studioMaskSolid, accel)) {
            continue;
        }
#endif
        float3 energy = light.colorBrightness.rgb * light.colorBrightness.w * 1.4 * falloff;
        float3 h = normalize(l + view);
        float spec = pow(max(dot(normal, h), 0.0), max(shininess, 1.0)) * specular;
        total += energy * (base * ndotl + spec * ndotl);
    }
    return total;
}

// Fog, then exposure: the last thing every lit pixel goes through.
static float3 studio_finish(float3 color, float3 position, float3 cameraPosition,
                            constant LightingUniforms &lighting) {
    float distance = length(position - cameraPosition);
    float start = lighting.fogColor.w;
    float end = lighting.fogParams.x;
    float fog = saturate((distance - start) / max(end - start, 0.01));
    color = mix(color, lighting.fogColor.rgb, fog);
    return color * lighting.ambient.w;
}
"""#
