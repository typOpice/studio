import Metal
import simd

/// Draws Beams and Trails (`Ribbons.strips`): each a triangle strip, its picture repeated
/// along it, tinted by its colour, with premultiplied alpha as the particles are
/// (LightEmission 0 over what's behind, 1 added to it). After everything solid, tested
/// against the depth but not writing it, both faces showing.
final class RibbonRenderer {
    /// Mirrors `RibbonVertexIn` in the Metal source (48 bytes).
    struct GPUVertex {
        var position: SIMD4<Float>
        /// x, y: along and across; z: light emission.
        var uv: SIMD4<Float>
        var color: SIMD4<Float>
    }

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    /// The ribbon pictures, and plain white for none.
    private(set) var builtins: [String: MTLTexture] = [:]
    private var white: MTLTexture?
    private var buffers: [MTLBuffer?] = [nil, nil, nil]
    private var turn = 0

    init?(device: MTLDevice, library: MTLLibrary, color: MTLPixelFormat, depth: MTLPixelFormat, samples: Int) {
        self.device = device
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "ribbon_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "ribbon_fragment")
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
        for name in RibbonLook.builtinTextures {
            builtins[name] = Self.makeTexture(device: device, size: Self.pictureSize, pixels: Self.picture(name))
        }
        white = Self.makeTexture(device: device, size: 1, pixels: [SIMD4(255, 255, 255, 255)])
    }

    func draw(_ encoder: MTLRenderCommandEncoder, strips: [Ribbons.Strip], frame: inout FrameUniforms,
              depth: MTLDepthStencilState, picture: (String) -> MTLTexture?) {
        let drawn = strips.filter { $0.vertices.count >= 4 }
        guard !drawn.isEmpty else { return }
        let total = drawn.reduce(0) { $0 + $1.vertices.count }
        let stride = MemoryLayout<GPUVertex>.stride
        turn = (turn + 1) % buffers.count
        if (buffers[turn]?.length ?? 0) < total * stride {
            buffers[turn] = device.makeBuffer(length: max(total * stride, 32 * 1024) * 2, options: .storageModeShared)
        }
        guard let buffer = buffers[turn] else { return }
        let target = buffer.contents().bindMemory(to: GPUVertex.self, capacity: total)
        var index = 0
        for strip in drawn {
            for v in strip.vertices {
                target[index] = GPUVertex(position: SIMD4(v.position, 1), uv: SIMD4(v.uv.x, v.uv.y, v.emission, 0),
                                          color: v.color)
                index += 1
            }
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depth)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        var start = 0
        for strip in drawn {
            encoder.setFragmentTexture(texture(for: strip.texture, picture: picture), index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: start, vertexCount: strip.vertices.count)
            start += strip.vertices.count
        }
        encoder.setCullMode(.back)
    }

    private func texture(for name: String, picture: (String) -> MTLTexture?) -> MTLTexture? {
        if name.isEmpty { return white }
        if name.hasPrefix("builtin://") { return builtins[String(name.dropFirst("builtin://".count))] ?? white }
        return picture(name) ?? white
    }

    // MARK: - The built-in pictures

    static let pictureSize = 64

    /// A ribbon picture: white, its pattern in the alpha; x runs along the ribbon.
    static func picture(_ name: String) -> [SIMD4<UInt8>] {
        let n = pictureSize
        var pixels = [SIMD4<UInt8>](repeating: .zero, count: n * n)
        func smooth(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
            let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
            return t * t * (3 - 2 * t)
        }
        for py in 0..<n {
            for px in 0..<n {
                // u along (0…1, repeating), v across (−1…1).
                let u = (Float(px) + 0.5) / Float(n), v = (Float(py) + 0.5) / Float(n) * 2 - 1
                var alpha: Float
                switch name {
                case "Arrows":
                    // A chevron pointing along the ribbon.
                    let tip = 0.75 - abs(v) * 0.45
                    let d = u - tip
                    alpha = (1 - smooth(0.0, 0.03, abs(d + 0.08) - 0.08)) * (1 - smooth(0.8, 0.9, abs(v)))
                case "Dots":
                    let r = ((u - 0.5) * (u - 0.5) * 4 + v * v).squareRoot()
                    alpha = 1 - smooth(0.45, 0.55, r)
                case "Chain":
                    // An oval link, then the edge of the next.
                    let x = (u - 0.5) * 2.2, y = v * 1.25
                    let r = (x * x + y * y).squareRoot()
                    alpha = (1 - smooth(0.06, 0.12, abs(r - 0.8))) + (1 - smooth(0.1, 0.2, abs(v))) * smooth(0.85, 0.95, abs(x))
                    alpha = min(alpha, 1)
                default:
                    // Glow: bright down the middle, soft to the edges.
                    alpha = exp(-v * v * 5)
                }
                pixels[py * n + px] = SIMD4(255, 255, 255, UInt8(min(max(alpha, 0), 1) * 255))
            }
        }
        return pixels
    }

    private static func makeTexture(device: MTLDevice, size: Int, pixels: [SIMD4<UInt8>]) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        pixels.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: bytes.baseAddress!,
                            bytesPerRow: size * 4)
        }
        return texture
    }
}

/// The ribbons' Metal: appended to the renderer's library.
let ribbonMetalSource = #"""

struct RibbonVertexIn {
    float4 position;
    float4 uv;
    float4 color;
};

struct RibbonOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float emission;
};

vertex RibbonOut ribbon_vertex(uint vid [[vertex_id]],
                               const device RibbonVertexIn *vertices [[buffer(0)]],
                               constant FrameUniforms &frame [[buffer(1)]]) {
    RibbonVertexIn v = vertices[vid];
    RibbonOut out;
    out.position = frame.viewProjection * float4(v.position.xyz, 1);
    out.uv = v.uv.xy;
    out.color = v.color;
    out.emission = v.uv.z;
    return out;
}

fragment float4 ribbon_fragment(RibbonOut in [[stage_in]], texture2d<float> picture [[texture(2)]]) {
    constexpr sampler ribbonSampler(filter::linear, s_address::repeat, t_address::clamp_to_edge);
    float4 t = picture.sample(ribbonSampler, in.uv);
    float alpha = t.a * in.color.a;
    return float4(t.rgb * in.color.rgb * alpha, alpha * (1.0 - in.emission));
}
"""#
