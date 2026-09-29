import AppKit
import MetalKit
import simd

/// One small Metal pipeline, shared by all ViewportFrames. The cache holds at most
/// sixteen images and sixty-four meshes; destroying a GUI releases its targets.
final class ViewportRenderer {
    static let shared = MTLCreateSystemDefaultDevice().flatMap(ViewportRenderer.init)
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let white: MTLTexture
    private var meshes: [String: Mesh] = [:]
    private var textures: [UUID: MTLTexture] = [:]
    private(set) var renderCount = 0
    var cachedImageCount: Int { entries.count }
    private struct Key: Hashable { let owner: ObjectIdentifier; let id: Int }
    private final class Entry {
        weak var owner: GuiStore?
        var parts: [Part] = []
        var camera = PreviewCamera()
        var ambient = Vec3.zero, light = Vec3.zero, direction = Vec3.zero
        var width = 0, height = 0
        var image: NSImage?
        var target: MTLTexture?
        var depth: MTLTexture?
        var serial = 0
    }
    private var entries: [Key: Entry] = [:]
    private var serial = 0
    private struct Uniforms {
        var viewProjection = matrix_identity_float4x4
        var model = matrix_identity_float4x4
        var normal = matrix_identity_float4x4
        var color = Vec4(repeating: 1)
        var ambient = Vec4.zero
        var light = Vec4.zero
        var direction = Vec4.zero
        var eye = Vec4.zero
        var shading = Vec4.zero
    }

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }; self.queue = queue
        do {
            let library = try device.makeLibrary(source: Self.source, options: nil)
            let description = MTLRenderPipelineDescriptor()
            description.vertexFunction = library.makeFunction(name: "preview_vertex")
            description.fragmentFunction = library.makeFunction(name: "preview_fragment")
            description.colorAttachments[0].pixelFormat = .bgra8Unorm
            description.colorAttachments[0].isBlendingEnabled = true
            description.colorAttachments[0].sourceRGBBlendFactor = .one
            description.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            description.colorAttachments[0].sourceAlphaBlendFactor = .one
            description.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            description.depthAttachmentPixelFormat = .depth32Float
            pipeline = try device.makeRenderPipelineState(descriptor: description)
        } catch { NSLog("ViewportFrame pipeline: %@", String(describing: error)); return nil }
        let depth = MTLDepthStencilDescriptor(); depth.depthCompareFunction = .less; depth.isDepthWriteEnabled = true
        guard let state = device.makeDepthStencilState(descriptor: depth) else { return nil }; depthState = state
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var pixel: UInt32 = .max
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        white = texture
    }

    func remove(owner: GuiStore, id: Int) { entries[Key(owner: ObjectIdentifier(owner), id: id)] = nil }

    func image(owner: GuiStore, world: ViewportWorld, object: GuiObject, camera: PreviewCamera, size: CGSize) -> NSImage? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let width = min(max(Int(size.width.rounded()), 1), 2048), height = min(max(Int(size.height.rounded()), 1), 2048)
        entries = entries.filter { $0.value.owner != nil }
        let key = Key(owner: ObjectIdentifier(owner), id: object.id)
        let entry = entries[key] ?? Entry()
        serial += 1; entry.serial = serial; entry.owner = owner
        if entry.width == width && entry.height == height && entry.parts == world.model.parts && entry.camera == camera
            && entry.ambient == object.viewportAmbient && entry.light == object.viewportLightColor && entry.direction == object.viewportLightDirection,
           let image = entry.image { return image }
        if entry.width != width || entry.height != height || entry.target == nil {
            let target = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            target.usage = [.renderTarget, .shaderRead]; target.storageMode = .shared
            entry.target = device.makeTexture(descriptor: target)
            let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
            depth.usage = .renderTarget; depth.storageMode = .private
            entry.depth = device.makeTexture(descriptor: depth)
        }
        guard let target = entry.target, let depth = entry.depth, let command = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0); pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear; pass.depthAttachment.clearDepth = 1
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depthState); encoder.setCullMode(.none)
        let view = (Mat.translation(camera.frame.position) * Mat.rotation(camera.frame.orientation)).inverse
        let projection = Mat.perspective(fovYRadians: camera.fieldOfView.radians, aspect: Float(width) / Float(height), near: 0.05, far: 10000)
        for part in world.model.parts.filter({ $0.visible && !$0.negative && $0.transparency < 1 }).sorted(by: {
            // Transparent surfaces blend from back to front.
            if ($0.transparency > 0) != ($1.transparency > 0) { return $0.transparency == 0 }
            return simd_distance_squared($0.position, camera.frame.position) > simd_distance_squared($1.position, camera.frame.position)
        }) {
            guard let mesh = mesh(for: part) else { continue }
            var uniforms = Uniforms()
            uniforms.viewProjection = projection * view; uniforms.model = part.modelMatrix; uniforms.normal = part.modelMatrix.inverse.transpose
            uniforms.color = Vec4(part.color, min(max(1 - part.transparency, 0), 1))
            uniforms.ambient = Vec4(object.viewportAmbient, 0); uniforms.light = Vec4(object.viewportLightColor, 0)
            uniforms.direction = Vec4(simd_normalize(-object.viewportLightDirection), 0); uniforms.eye = Vec4(camera.frame.position, 1)
            uniforms.shading = Vec4(part.material.shading, 0)
            var texture = white
            if let name = part.mesh?.textureId, let asset = world.model.asset(named: name), mesh.uvBuffer != nil {
                if let found = textures[asset.id] { texture = found }
                else if let made = try? MTKTextureLoader(device: device).newTexture(data: asset.data, options: [.SRGB: false]) {
                    if textures.count >= 64 { textures.removeAll() }; textures[asset.id] = made; texture = made
                }
                uniforms.shading.w = 1
            }
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            mesh.draw(encoder)
        }
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        entry.image = NSImage(cgImage: image, size: NSSize(width: width, height: height))
        entry.parts = world.model.parts; entry.camera = camera; entry.width = width; entry.height = height
        entry.ambient = object.viewportAmbient; entry.light = object.viewportLightColor; entry.direction = object.viewportLightDirection
        entries[key] = entry
        while entries.count > 16 { if let oldest = entries.min(by: { $0.value.serial < $1.value.serial })?.key { entries[oldest] = nil } }
        renderCount += 1
        return entry.image
    }

    private func mesh(for part: Part) -> Mesh? {
        let key = part.solidDeformation?.id.uuidString ?? part.solid?.mesh.id.uuidString ?? part.mesh?.asset?.uuidString ?? part.shape.rawValue
        if let mesh = meshes[key] { return mesh }
        let vertices: [Vertex], indices: [UInt32], uvs: [SIMD2<Float>]
        if let geometry = MeshLibrary.shared.geometry(for: part) {
            vertices = zip(geometry.positions, geometry.normals).map { Vertex(position: $0, normal: $1) }
            indices = geometry.indices; uvs = geometry.uvs.count == vertices.count ? geometry.uvs : .init(repeating: .zero, count: vertices.count)
        } else {
            let geometry: ([Vertex], [UInt16])
            switch part.shape { case .sphere: geometry = MeshFactory.sphere(); case .cylinder: geometry = MeshFactory.cylinder(); case .wedge: geometry = MeshFactory.wedge(); default: geometry = MeshFactory.box() }
            vertices = geometry.0; indices = geometry.1.map(UInt32.init); uvs = .init(repeating: .zero, count: vertices.count)
        }
        guard let mesh = Mesh(device: device, vertices: vertices, indices: indices, uvs: uvs) else { return nil }
        if meshes.count >= 64 { meshes.removeAll() }; meshes[key] = mesh; return mesh
    }

    private static let source = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct V { float3 position; float3 normal; };
    struct U { float4x4 vp; float4x4 model; float4x4 normal; float4 color; float4 ambient; float4 light; float4 direction; float4 eye; float4 shading; };
    struct Out { float4 position [[position]]; float3 world; float3 normal; float2 uv; };
    vertex Out preview_vertex(uint id [[vertex_id]], device const V* vertices [[buffer(0)]], constant U& u [[buffer(1)]], device const float2* uv [[buffer(3)]]) {
        Out o; float4 world = u.model * float4(vertices[id].position, 1); o.position = u.vp * world; o.world = world.xyz;
        o.normal = normalize((u.normal * float4(vertices[id].normal, 0)).xyz); o.uv = uv[id]; return o;
    }
    fragment float4 preview_fragment(Out in [[stage_in]], constant U& u [[buffer(1)]], texture2d<float> picture [[texture(0)]]) {
        constexpr sampler sample(coord::normalized, address::clamp_to_edge, filter::linear);
        float4 texture = u.shading.w > 0.5 ? picture.sample(sample, in.uv) : float4(1);
        float3 base = u.color.rgb * texture.rgb;
        float3 n = normalize(in.normal); float ndotl = max(dot(n, u.direction.xyz), 0.0);
        float3 h = normalize(u.direction.xyz + normalize(u.eye.xyz - in.world));
        float spec = pow(max(dot(n, h), 0.0), max(u.shading.y, 1.0)) * u.shading.x * ndotl;
        float3 color = base * (u.ambient.rgb + u.light.rgb * ndotl) + u.light.rgb * spec;
        color = mix(color, base * 1.2, u.shading.z);
        float alpha = u.color.a * texture.a; return float4(color * alpha, alpha);
    }
    """#
}
