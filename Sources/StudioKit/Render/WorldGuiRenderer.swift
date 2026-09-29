import MetalKit
import SwiftUI
import simd

/// Reuses screen-widget layout and drawing, then projects the canvas onto its part.
/// Texture work happens before a Metal encoder opens; unchanged canvases are reused.
final class WorldGuiRenderer {
    private struct Vertex {
        var clip: Vec4
        var uv: SIMD2<Float>
    }
    private struct Cache {
        var objects: [GuiObject]
        var images: [Data]
        var previews: [ViewportContent]
        var size: CGSize
        var focused: Int?
        var cursor: Int
        var selected: Bool
        var texture: MTLTexture
    }
    private struct Draw {
        var vertices: [Vertex]
        var texture: MTLTexture
        var tint: Vec4
        var onTop: Bool
    }
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private var cache: [Int: Cache] = [:]
    private var draws: [Draw] = []
    var cachedCanvasCount: Int { cache.count }

    init(device: MTLDevice, color: MTLPixelFormat, depth: MTLPixelFormat, samples: Int) throws {
        self.device = device
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        struct SurfaceVertex { float4 clip; float2 uv; };
        struct SurfaceOut { float4 position [[position]]; float2 uv; };
        vertex SurfaceOut surface_vertex(uint id [[vertex_id]], const device SurfaceVertex *vertices [[buffer(0)]]) {
            SurfaceOut out; out.position = vertices[id].clip; out.uv = vertices[id].uv; return out;
        }
        fragment float4 surface_fragment(SurfaceOut in [[stage_in]], texture2d<float> image [[texture(0)]],
                                          constant float4 &tint [[buffer(0)]]) {
            constexpr sampler sampling(filter::linear, address::clamp_to_edge);
            float4 color = image.sample(sampling, in.uv);
            return float4(color.rgb * tint.rgb, color.a);
        }
        """, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "surface_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "surface_fragment")
        descriptor.colorAttachments[0].pixelFormat = color
        descriptor.depthAttachmentPixelFormat = depth
        descriptor.rasterSampleCount = samples
        let blend = descriptor.colorAttachments[0]!
        blend.isBlendingEnabled = true
        blend.sourceRGBBlendFactor = .one
        blend.destinationRGBBlendFactor = .oneMinusSourceAlpha
        blend.sourceAlphaBlendFactor = .one
        blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    func prepare(store: GuiStore?, model: SceneModel, camera: Camera, viewProjection: float4x4) {
        draws = []
        guard let store else { cache = [:]; return }
        var live: Set<Int> = []
        let surfaces = store.surfaces(in: model).sorted {
            if $0.object.alwaysOnTop != $1.object.alwaysOnTop { return !$0.object.alwaysOnTop }
            return simd_distance_squared(camera.position, $0.face.center) > simd_distance_squared(camera.position, $1.face.center)
        }
        // A bounded number and resolution keeps user-authored signs from allocating
        // unbounded GPU memory. The logical canvas size (and input) stays unchanged.
        for surface in surfaces.prefix(64) {
            let object = surface.object, face = surface.face
            guard simd_dot(camera.position - face.center, face.normal) > 0,
                  simd_distance(camera.position, face.center) <= object.maxDistance else { continue }
            let size = face.canvas(object)
            let placed = store.layout(root: object.id, in: size)
            let contents = ([object.id] + store.descendants(of: object.id)).compactMap(store.object)
            let names = Set(contents.map(\.image).filter { !$0.isEmpty })
            let images = model.assets.filter { names.contains($0.reference) }.map(\.data)
            let previews = contents.filter { $0.kind == .viewportFrame }.compactMap { store.viewportContent($0.id) }
            var held = cache[object.id]
            if held?.objects != contents || held?.images != images || held?.previews != previews || held?.size != size
                || held?.focused != store.focused || held?.cursor != store.cursor || held?.selected != store.selectedAll {
                let scale = min(1, 1024 / max(size.width, size.height))
                let image: CGImage? = MainActor.assumeIsolated {
                    let renderer = ImageRenderer(content: SurfaceCanvas(store: store, placed: placed)
                        .frame(width: size.width, height: size.height, alignment: .topLeading))
                    renderer.scale = scale
                    return renderer.cgImage
                }
                if let image, let texture = texture(image) {
                    held = Cache(objects: contents, images: images, previews: previews, size: size, focused: store.focused, cursor: store.cursor,
                                 selected: store.selectedAll, texture: texture)
                    cache[object.id] = held
                }
            }
            guard let held else { continue }
            live.insert(object.id)
            let uv: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(0, 1), SIMD2(1, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)]
            let vertices = uv.map { Vertex(clip: viewProjection * Vec4(face.point($0), 1), uv: $0) }
            let lit = model.lighting.ambient + model.lighting.sunLight * max(simd_dot(face.normal, model.lighting.lightDirection), 0)
            let tint = (Vec3(repeating: 1 - object.lightInfluence) + lit * object.lightInfluence) * object.brightness
            draws.append(Draw(vertices: vertices, texture: held.texture, tint: Vec4(tint, 1), onTop: object.alwaysOnTop))
        }
        cache = cache.filter { live.contains($0.key) }
    }

    /// ImageRenderer can produce formats MTKTextureLoader cannot decode (including
    /// a solid canvas's optimized image). Normalize once to premultiplied RGBA8.
    private func texture(_ image: CGImage) -> MTLTexture? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let made = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: width * 4)
            return true
        }
        return made ? texture : nil
    }

    func draw(_ encoder: MTLRenderCommandEncoder, depth: MTLDepthStencilState, onTop: MTLDepthStencilState) {
        guard !draws.isEmpty else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setCullMode(.none)
        for var item in draws {
            encoder.setDepthStencilState(item.onTop ? onTop : depth)
            item.vertices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            encoder.setFragmentTexture(item.texture, index: 0)
            encoder.setFragmentBytes(&item.tint, length: MemoryLayout<Vec4>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }
}

private struct SurfaceCanvas: View {
    let store: GuiStore
    let placed: [GuiStore.Placed]
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(placed) { item in
                GuiElement(placed: item, focused: store.focused == item.id, cursor: store.cursor,
                           selectedAll: store.selectedAll, image: item.object.kind == .viewportFrame
                            ? store.viewportImage(item.object, size: item.frame.size)
                            : item.object.kind.showsImage ? store.imageProvider?(item.object.image) : nil) {}
            }
        }
    }
}
