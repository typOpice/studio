import Metal
import MetalKit
import simd

/// Draws the particles `ParticleSystem` keeps: each one a square facing the camera, turned
/// by its Rotation, its emitter's picture tinted by its colour. They're drawn after
/// everything solid, tested against the depth but not writing it, with premultiplied
/// alpha: LightEmission 0 draws over what's behind, 1 adds to it.
final class ParticleRenderer {
    /// Mirrors `ParticleInstance` in the Metal source (48 bytes).
    struct Instance {
        /// Where, and how big.
        var place: SIMD4<Float>
        var color: SIMD4<Float>
        /// x: rotation (radians), y: light emission.
        var extra: SIMD4<Float>
    }

    /// Mirrors `ParticleCamera`: the camera's right and up, to face the squares at it.
    struct CameraAxes {
        var right: SIMD4<Float>
        var up: SIMD4<Float>
    }

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    /// The built-in pictures, by name ("Sparkle", …).
    private(set) var builtins: [String: MTLTexture] = [:]
    /// A few buffers in turn, so the one being written isn't one the GPU is still reading.
    private var buffers: [MTLBuffer?] = [nil, nil, nil]
    private var turn = 0

    init?(device: MTLDevice, library: MTLLibrary, color: MTLPixelFormat, depth: MTLPixelFormat, samples: Int) {
        self.device = device
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "particle_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "particle_fragment")
        descriptor.colorAttachments[0].pixelFormat = color
        descriptor.depthAttachmentPixelFormat = depth
        descriptor.rasterSampleCount = samples
        let attachment = descriptor.colorAttachments[0]!
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let made = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        pipeline = made
        for name in ParticleEmitter.builtinTextures {
            builtins[name] = Self.makeTexture(device: device, pixels: Self.picture(name))
        }
    }

    /// Every emitter's particles, farthest batch first and each batch far to near.
    func draw(_ encoder: MTLRenderCommandEncoder, system: ParticleSystem, model: SceneModel, camera: Camera,
              frame: inout FrameUniforms, depth: MTLDepthStencilState, picture: (String) -> MTLTexture?) {
        var batches: [(texture: MTLTexture, instances: [Instance], distance: Float)] = []
        let eye = camera.position
        system.sprites(model: model) { emitter, sprites in
            guard let texture = texture(for: emitter.texture, picture: picture) else { return }
            let sorted = sprites.sorted { simd_distance_squared($0.position, eye) > simd_distance_squared($1.position, eye) }
            let instances = sorted.compactMap { sprite -> Instance? in
                guard sprite.size > 0, sprite.color.w > 0.001 else { return nil }
                return Instance(place: SIMD4(sprite.position, sprite.size), color: sprite.color,
                                extra: SIMD4(sprite.rotation, sprite.emission, 0, 0))
            }
            guard let far = sorted.first else { return }
            if !instances.isEmpty { batches.append((texture, instances, simd_distance_squared(far.position, eye))) }
        }
        guard !batches.isEmpty else { return }
        batches.sort { $0.distance > $1.distance }

        let total = batches.reduce(0) { $0 + $1.instances.count }
        let stride = MemoryLayout<Instance>.stride
        turn = (turn + 1) % buffers.count
        if (buffers[turn]?.length ?? 0) < total * stride {
            buffers[turn] = device.makeBuffer(length: max(total * stride, 64 * 1024) * 2, options: .storageModeShared)
        }
        guard let buffer = buffers[turn] else { return }
        var axes = CameraAxes(right: SIMD4(camera.right, 0), up: SIMD4(camera.up, 0))

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depth)
        encoder.setCullMode(.none)
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.setVertexBytes(&axes, length: MemoryLayout<CameraAxes>.stride, index: 2)
        var offset = 0
        for batch in batches {
            batch.instances.withUnsafeBytes { bytes in
                (buffer.contents() + offset).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
            encoder.setVertexBuffer(buffer, offset: offset, index: 0)
            // Slot 2: the lit shaders' 0 (the shadow map) is left alone.
            encoder.setFragmentTexture(batch.texture, index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: batch.instances.count)
            offset += batch.instances.count * stride
        }
        encoder.setCullMode(.back)
    }

    private func texture(for name: String, picture: (String) -> MTLTexture?) -> MTLTexture? {
        if name.hasPrefix("builtin://") { return builtins[String(name.dropFirst("builtin://".count))] ?? builtins["Sparkle"] }
        return picture(name) ?? builtins["Sparkle"]
    }

    // MARK: - The built-in pictures

    static let pictureSize = 64

    /// A built-in picture: white, its shape in the alpha (the emitter's colour tints it).
    static func picture(_ name: String) -> [SIMD4<UInt8>] {
        let n = pictureSize
        var pixels = [SIMD4<UInt8>](repeating: .zero, count: n * n)
        func noise(_ x: Float, _ y: Float) -> Float {
            // Smoothed value noise, the same every time.
            func hash(_ i: Int, _ j: Int) -> Float {
                var h = UInt32(truncatingIfNeeded: i &* 374_761_393 &+ j &* 668_265_263)
                h = (h ^ (h >> 13)) &* 1_274_126_177
                return Float(h & 0xFFFF) / 65535
            }
            let i = Int(floor(x)), j = Int(floor(y))
            let fx = x - floor(x), fy = y - floor(y)
            let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
            let top = hash(i, j) + (hash(i + 1, j) - hash(i, j)) * sx
            let bottom = hash(i, j + 1) + (hash(i + 1, j + 1) - hash(i, j + 1)) * sx
            return top + (bottom - top) * sy
        }
        func smooth(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
            let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
            return t * t * (3 - 2 * t)
        }
        for py in 0..<n {
            for px in 0..<n {
                // −1…1 across, up positive.
                let x = (Float(px) + 0.5) / Float(n) * 2 - 1, y = 1 - (Float(py) + 0.5) / Float(n) * 2
                let r = (x * x + y * y).squareRoot()
                var alpha: Float
                switch name {
                case "Circle":
                    alpha = pow(1 - smooth(0, 1, r), 1.3)
                case "Smoke":
                    let puff = 1 - smooth(0.2, 1, r)
                    alpha = puff * (0.55 + 0.45 * noise(x * 3 + 7, y * 3 + 3)) * (0.8 + 0.2 * noise(x * 7, y * 7))
                case "Fire":
                    let rr = (x * x + (y * 0.8 + 0.1) * (y * 0.8 + 0.1)).squareRoot()
                    alpha = pow(max(1 - rr, 0), 1.1) * (0.75 + 0.25 * noise(x * 5 + 1, y * 5 + 9))
                case "Star":
                    let angle = atan2(y, x) + .pi / 2
                    let edge = 0.42 + 0.5 * pow((cos(angle * 5) + 1) / 2, 3)
                    alpha = max(1 - smooth(edge - 0.08, edge, r), 0.35 * pow(max(1 - r, 0), 2))
                case "Confetti":
                    alpha = (1 - smooth(0.72, 0.8, abs(x))) * (1 - smooth(0.42, 0.5, abs(y)))
                default:
                    // Sparkle: a bright middle and four thin rays.
                    let glow = exp(-r * r * 14)
                    let rays = max(exp(-abs(x) * 28), exp(-abs(y) * 28)) * max(1 - r, 0)
                    alpha = min(glow + rays, 1)
                }
                let a = UInt8(min(max(alpha, 0), 1) * 255)
                pixels[py * n + px] = SIMD4(255, 255, 255, a)
            }
        }
        return pixels
    }

    private static func makeTexture(device: MTLDevice, pixels: [SIMD4<UInt8>]) -> MTLTexture? {
        let n = pictureSize
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: n, height: n,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        pixels.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, withBytes: bytes.baseAddress!,
                            bytesPerRow: n * 4)
        }
        return texture
    }
}

/// The particles' Metal: appended to the renderer's library.
let particleMetalSource = #"""

struct ParticleInstance {
    float4 place;
    float4 color;
    float4 extra;
};

struct ParticleCamera {
    float4 right;
    float4 up;
};

struct ParticleOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float emission;
};

vertex ParticleOut particle_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   const device ParticleInstance *instances [[buffer(0)]],
                                   constant FrameUniforms &frame [[buffer(1)]],
                                   constant ParticleCamera &camera [[buffer(2)]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    ParticleInstance p = instances[iid];
    float2 c = corners[vid];
    float s = sin(p.extra.x), k = cos(p.extra.x);
    float2 turned = float2(c.x * k - c.y * s, c.x * s + c.y * k);
    float3 world = p.place.xyz + (camera.right.xyz * turned.x + camera.up.xyz * turned.y) * (p.place.w * 0.5);
    ParticleOut out;
    out.position = frame.viewProjection * float4(world, 1);
    out.uv = float2(c.x * 0.5 + 0.5, 0.5 - c.y * 0.5);
    out.color = p.color;
    out.emission = p.extra.y;
    return out;
}

fragment float4 particle_fragment(ParticleOut in [[stage_in]], texture2d<float> picture [[texture(2)]]) {
    constexpr sampler pictureSampler(filter::linear, address::clamp_to_edge);
    float4 t = picture.sample(pictureSampler, in.uv);
    float alpha = t.a * in.color.a;
    return float4(t.rgb * in.color.rgb * alpha, alpha * (1.0 - in.emission));
}
"""#
