import simd

/// Mirrors `LightingUniforms` in `lightingMetalSource` (384 bytes). Bound at fragment
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
    /// xyz: towards the sun itself (sunDirection is the moon's at night). w: seconds, for drifting clouds.
    var sunTrue: Vec4 = Vec4(0, 1, 0, 0)
    /// The Sky: x, y: the sun's and moon's angular radius (radians); z: stars; w: 1 when the sun and moon show.
    var skyParams: Vec4 = Vec4(0.0315, 0.0315, 3000, 1)
    /// The Atmosphere: x: density, y: offset, z: glare, w: haze.
    var atmosphereParams: Vec4 = .zero
    /// rgb: its Color. w: 1 when there is one.
    var atmosphereColor: Vec4 = .zero
    /// rgb: its Decay.
    var atmosphereDecay: Vec4 = .zero
    /// The Clouds: x: cover, y: density, z: 1 when shown. w: 1 when a skybox is bound (the sky pass).
    var cloudParams: Vec4 = .zero
    /// rgb: the clouds' Color.
    var cloudColor: Vec4 = .zero

    init() {}

    /// Everything the shaders need about the lighting for one frame.
    init(settings: LightingSettings, shadowViewProjection: float4x4, inverseViewProjection: float4x4,
         shadowTexel: Float, pointLights: Int, groundPlane: Bool, time: Float = 0, skybox: Bool = false) {
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
        sunTrue = Vec4(settings.sunDirection, time)
        let skyObject = settings.skyInEffect
        // Roblox's sizes are of pictures with a glow round a smaller disc.
        skyParams = Vec4(max(skyObject.sunAngularSize, 0) * 0.0015, max(skyObject.moonAngularSize, 0) * 0.00287,
                         Float(min(max(skyObject.starCount, 0), 5000)), skyObject.celestialBodiesShown ? 1 : 0)
        if let air = settings.atmosphere {
            atmosphereParams = Vec4(min(max(air.density, 0), 1), min(max(air.offset, 0), 1),
                                    min(max(air.glare, 0), 10), min(max(air.haze, 0), 10))
            atmosphereColor = Vec4(air.color, 1)
            atmosphereDecay = Vec4(air.decay, 0)
        }
        if let clouds = settings.clouds, clouds.enabled {
            cloudParams = Vec4(min(max(clouds.cover, 0), 1), min(max(clouds.density, 0), 1), 1, 0)
            cloudColor = Vec4(clouds.color, 0)
        }
        cloudParams.w = skybox ? 1 : 0
    }
}

/// Mirrors `PointLightData` (96 bytes), shared by every local-light class.
struct PointLightData {
    /// xyz: where, w: range.
    var positionRange: Vec4 = .zero
    /// rgb: colour, w: brightness.
    var colorBrightness: Vec4 = .zero
    /// x: ray-traced shadows, y: kind (point=0, spot=1, surface=2).
    var options: Vec4 = .zero
    /// xyz: outward face normal, w: cosine of the half-angle.
    var directionAngle: Vec4 = .zero
    /// Face tangent axes with half-extents in w.
    var surfaceU: Vec4 = .zero
    var surfaceV: Vec4 = .zero

    init() {}
    init(part: Part, light: PointLight) {
        let normal = light.face.normal
        let localU: Vec3 = abs(normal.y) > 0.5 ? Vec3(1, 0, 0) : abs(normal.x) > 0.5 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
        let localV = simd_cross(normal, localU)
        let halfSize = simd_abs(part.size) * 0.5
        let direction = part.orientation.act(normal)
        let center = part.position + part.orientation.act(normal * halfSize) + direction * 0.025
        positionRange = Vec4(light.kind == .point ? part.position : center, min(light.range, PointLight.maximumRange))
        colorBrightness = Vec4(light.color, light.brightness)
        options = Vec4(light.shadows ? 1 : 0, light.kind == .point ? 0 : light.kind == .spot ? 1 : 2, 0, 0)
        directionAngle = Vec4(direction, cos(min(max(light.angle, 0), 180) * .pi / 360))
        surfaceU = Vec4(part.orientation.act(localU), simd_dot(simd_abs(localU), halfSize))
        surfaceV = Vec4(part.orientation.act(localV), simd_dot(simd_abs(localV), halfSize))
    }
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
    float4 sunTrue;
    float4 skyParams;
    float4 atmosphereParams;
    float4 atmosphereColor;
    float4 atmosphereDecay;
    float4 cloudParams;
    float4 cloudColor;
};

struct PointLightData {
    float4 positionRange;
    float4 colorBrightness;
    float4 options;
    float4 directionAngle;
    float4 surfaceU;
    float4 surfaceV;
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

static float3 studio_point_lights(float3 position, float3 normal, float3 view, float3 base,
                                  float specular, float shininess,
                                  constant LightingUniforms &lighting, constant PointLightData *pointLights
                                  STUDIO_RT_DECL);


// Instance masks: parts that hold a light are left out of that light's shadow rays.
constant uint studioMaskSolid = 1;
constant uint studioMaskLightHousing = 2;

// Interleaved gradient noise: a stable, well-spread value per pixel.
static float studio_noise(float2 pixel) {
    return fract(52.9829189 * fract(dot(pixel, float2(0.06711056, 0.00583715))));
}

// Noise for stars and clouds: the same everywhere, every frame.
static float studio_sky_hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static float studio_value_noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(studio_sky_hash(i), studio_sky_hash(i + float2(1, 0)), u.x),
               mix(studio_sky_hash(i + float2(0, 1)), studio_sky_hash(i + float2(1, 1)), u.x), u.y);
}

static float studio_fbm(float2 p) {
    float total = 0.0, amplitude = 0.5;
    for (int octave = 0; octave < 5; octave++) {
        total += studio_value_noise(p) * amplitude;
        p = p * 2.03 + float2(17.1, 9.3);
        amplitude *= 0.5;
    }
    return total / 0.96875;
}

// About `count` stars over the whole sky: one in some of the cells of a cube's faces.
static float studio_stars(float3 d, float count) {
    float3 a = abs(d);
    float2 uv;
    float face;
    if (a.x >= a.y && a.x >= a.z) { uv = d.zy / a.x; face = d.x > 0.0 ? 0.0 : 1.0; }
    else if (a.y >= a.z) { uv = d.xz / a.y; face = d.y > 0.0 ? 2.0 : 3.0; }
    else { uv = d.xy / a.z; face = d.z > 0.0 ? 4.0 : 5.0; }
    float2 grid = (uv * 0.5 + 0.5) * 96.0;
    float2 cell = floor(grid) + face * 131.0;
    if (studio_sky_hash(cell) > count / 55296.0) { return 0.0; }
    float2 spot = float2(studio_sky_hash(cell + 7.1), studio_sky_hash(cell + 3.7)) * 0.6 + 0.2;
    float r = length(fract(grid) - spot);
    return smoothstep(0.14, 0.0, r) * (0.35 + 0.65 * studio_sky_hash(cell + 11.0));
}

// The air in a direction: the Atmosphere's Color towards the sun, its Decay away.
static float3 studio_air(float3 direction, constant LightingUniforms &lighting) {
    float towards = dot(direction, normalize(lighting.sunTrue.xyz)) * 0.5 + 0.5;
    float3 air = mix(lighting.atmosphereDecay.rgb, lighting.atmosphereColor.rgb, towards);
    return air * (0.2 + 0.8 * lighting.skyHorizon.w);
}

// Over the sky's colour (the one that follows the day, or a skybox): the glow round the
// light, the stars, the sun and moon, the clouds, and the Atmosphere's haze.
static float3 studio_sky_over(float3 color, float3 direction, constant LightingUniforms &lighting, bool stars) {
    float h = direction.y;
    float daylight = lighting.skyHorizon.w;
    float3 toLight = normalize(lighting.sunDirection.xyz);
    float facing = saturate(dot(direction, toLight));
    bool day = daylight > 0.3;
    float3 glowColor = day ? float3(1.0, 0.85, 0.6) : float3(0.6, 0.65, 0.8);
    // The wide glow is the sky's; the tight one is the sun's (or moon's) halo, hidden with it.
    float halo = lighting.skyParams.w > 0.5 ? pow(facing, 200.0) * 0.5 : 0.0;
    color += glowColor * (pow(facing, 12.0) * 0.18 + halo) * (day ? 1.0 : 0.4);

    if (stars && lighting.skyParams.z > 0.5 && h > 0.0) {
        float night = 1.0 - smoothstep(0.15, 0.6, daylight);
        color += float3(0.9, 0.92, 1.0) * studio_stars(direction, lighting.skyParams.z) * night * smoothstep(0.0, 0.2, h);
    }

    float3 sun = normalize(lighting.sunTrue.xyz);
    if (lighting.skyParams.w > 0.5) {
        float sunCos = cos(lighting.skyParams.x);
        float sunDisc = smoothstep(sunCos - 0.0003, sunCos + 0.0001, dot(direction, sun)) * step(-0.02, sun.y);
        float3 sunColor = mix(float3(1.7, 0.95, 0.55), float3(1.6, 1.5, 1.3), smoothstep(0.0, 0.25, sun.y));
        color = mix(color, sunColor, sunDisc);
        // The moon, opposite the sun: pale, marked, faint by day.
        float3 moon = -sun;
        float moonCos = cos(lighting.skyParams.y);
        float into = dot(direction, moon);
        float moonDisc = smoothstep(moonCos - 0.0003, moonCos + 0.0001, into) * step(-0.02, moon.y);
        if (moonDisc > 0.0) {
            float3 across = normalize(cross(moon, abs(moon.y) < 0.9 ? float3(0, 1, 0) : float3(1, 0, 0)));
            float3 up = cross(across, moon);
            float2 local = float2(dot(direction, across), dot(direction, up)) / max(lighting.skyParams.y, 1e-4);
            float marks = 0.78 + 0.22 * studio_value_noise(local * 3.0 + 5.0);
            color = mix(color, float3(0.86, 0.88, 0.95) * marks, moonDisc * (1.0 - 0.75 * daylight));
        }
    }

    if (lighting.cloudParams.z > 0.5 && h > 0.0) {
        float time = lighting.sunTrue.w;
        float2 p = direction.xz / max(h, 0.04) * 0.35 + float2(time * 0.006, time * 0.002);
        float cover = lighting.cloudParams.x;
        float amount = smoothstep(1.0 - cover - 0.15, 1.0 - cover + 0.2, studio_fbm(p)) * lighting.cloudParams.y;
        amount *= smoothstep(0.0, 0.15, h);
        float3 lit = lighting.cloudColor.rgb * (0.12 + 0.88 * daylight);
        lit += lighting.sunColor.rgb * 0.25 * pow(saturate(dot(direction, sun)), 4.0);
        color = mix(color, lit, saturate(amount));
    }

    if (lighting.atmosphereColor.w > 0.5) {
        float density = lighting.atmosphereParams.x, offset = lighting.atmosphereParams.y;
        float glare = lighting.atmosphereParams.z, haze = lighting.atmosphereParams.w;
        float reach = 0.06 + haze * 0.05;
        float band = h > 0.0 ? exp(-h / reach) : 1.0;
        float amount = saturate(band * (0.25 + offset * 0.75) * saturate(density * 1.5 + offset + haze * 0.1));
        color = mix(color, studio_air(direction, lighting), amount);
        color += lighting.sunColor.rgb * glare * 0.06 * pow(saturate(dot(direction, sun)), 5.0);
    }
    return color;
}

static float3 studio_sky(float3 direction, constant LightingUniforms &lighting) {
    float h = direction.y;
    float3 zenith = lighting.skyZenith.rgb;
    float3 horizon = lighting.skyHorizon.rgb;
    float3 color = mix(horizon, zenith, pow(saturate(h), 0.5));
    float3 ground = horizon * 0.55 + float3(0.02);
    if (h < 0.0) { color = mix(horizon, ground, saturate(-h * 5.0)); }
    return studio_sky_over(color, direction, lighting, true);
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
                                    constant LightingUniforms &lighting, constant PointLightData *pointLights,
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
        color += studio_point_lights(point, n, -direction, info.color.rgb, info.shading.x, info.shading.y,
                                     lighting, pointLights STUDIO_RT_ARGS);
        return mix(color, info.color.rgb * 1.35, info.shading.z);
    }
    if (groundDistance < INFINITY) {
        float3 point = origin + direction * groundDistance;
        float lit = toLight.y > 0.0 ? toLight.y : 0.0;
        if (shadows && lit > 0.0 && studio_blocked(point + float3(0, 0.03, 0), toLight, 2000.0, 0xFF, accel)) { lit = 0.0; }
        float3 ground = float3(0.19, 0.205, 0.23);
        float3 color = ground * (lighting.ambient.rgb * 0.8 + lighting.outdoorAmbient.rgb * 0.6 + lit * lighting.sunColor.rgb);
        color += studio_point_lights(point, float3(0, 1, 0), -direction, ground, 0.1, 8.0,
                                     lighting, pointLights STUDIO_RT_ARGS);
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
        int samples = light.options.y > 1.5 ? 9 : 1;
        for (int sample = 0; sample < samples; sample++) {
            float3 emitter = light.positionRange.xyz;
            if (samples > 1) {
                // Fixed nine-point quadrature covers the face, including near its edges.
                float2 uv = float2(float(sample % 3) - 1.0, float(sample / 3) - 1.0) * 0.75;
                emitter += light.surfaceU.xyz * light.surfaceU.w * uv.x + light.surfaceV.xyz * light.surfaceV.w * uv.y;
            }
            float3 toLight = emitter - position;
            float distance = length(toLight);
            float range = light.positionRange.w;
            if (distance >= range || distance < 1e-4) { continue; }
            float3 l = toLight / distance;
            float emission = 1.0;
            if (light.options.y > 0.5) {
                float cosine = dot(-l, light.directionAngle.xyz);
                float edge = light.directionAngle.w;
                if (cosine <= edge || edge >= 0.999999) { continue; }
                emission = smoothstep(edge, min(1.0, edge + max((1.0 - edge) * 0.12, 0.001)), cosine);
            }
            float ndotl = max(dot(normal, l), 0.0);
            if (ndotl <= 0.0) { continue; }
            float falloff = 1.0 - distance / range;
            falloff *= falloff;
#if STUDIO_RAYTRACING
            // Directional emitters sit just outside their own face: all intervening
            // geometry, including another lamp's housing, can block them.
            uint mask = light.options.y > 0.5 ? 0xFF : studioMaskSolid;
            if (studioRayTraced && light.options.x > 0.5 &&
                studio_blocked(position + normal * 0.03, l, max(distance - 0.05, 0.0), mask, accel)) { continue; }
#endif
            float3 energy = light.colorBrightness.rgb * light.colorBrightness.w * 1.4 * falloff * emission / float(samples);
            float3 h = normalize(l + view);
            float spec = pow(max(dot(normal, h), 0.0), max(shininess, 1.0)) * specular;
            total += energy * (base * ndotl + spec * ndotl);
        }
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
    // The Atmosphere: far things fade into the air.
    if (lighting.atmosphereColor.w > 0.5) {
        float density = lighting.atmosphereParams.x;
        float amount = 1.0 - exp(-distance * pow(density, 1.5) * 0.006);
        color = mix(color, studio_air((position - cameraPosition) / max(distance, 1e-4), lighting), amount);
    }
    color = mix(color, lighting.fogColor.rgb, fog);
    return color * lighting.ambient.w;
}
"""#
