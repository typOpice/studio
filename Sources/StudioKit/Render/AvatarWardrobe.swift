import CoreGraphics
import Metal
import simd

/// What the renderer dresses avatars with: the built-in accessories' meshes, body parts
/// with texture coordinates on the clothing template, the patch a face picture goes on,
/// and the pictures themselves as textures — each made once, when first needed.
final class AvatarWardrobe {
    private let device: MTLDevice
    private let queue: MTLCommandQueue

    /// Built-in accessories by catalog id, and their data for the ray tracer.
    private(set) var accessoryMeshes: [String: Mesh] = [:]
    private(set) var accessorySources: [(name: String, mesh: Mesh, vertices: [Vertex], indices: [UInt16])] = []
    /// Body parts that can wear clothes, by Roblox name.
    private var clothedMeshes: [String: Mesh] = [:]
    let faceDecal: Mesh
    /// Pictures and clothing composites, by what they were made from.
    private var textures: [String: MTLTexture?] = [:]

    init?(device: MTLDevice, queue: MTLCommandQueue) {
        self.device = device
        self.queue = queue
        let decal = MeshFactory.faceDecal()
        guard let face = Mesh(device: device, vertices: decal.vertices, indices: decal.indices, uvs: decal.uvs) else {
            return nil
        }
        faceDecal = face
        for entry in AvatarCatalog.accessories {
            guard let data = AvatarCatalog.mesh(entry.id),
                  let mesh = Mesh(device: device, vertices: data.0, indices: data.1) else { continue }
            accessoryMeshes[entry.id] = mesh
            accessorySources.append((Self.rayName(entry.id), mesh, data.0, data.1))
        }
        for part in AvatarPose.bodyParts where part.name != "Head" {
            guard let regions = ClothingTemplate.regions(for: part.name) else { continue }
            // The same rounded boxes the plain body is drawn with.
            let radius: Float = part.name == "Torso" ? 0.2 : 0.24
            let data = MeshFactory.clothedBox(size: part.size, radius: radius, regions: regions)
            clothedMeshes[part.name] = Mesh(device: device, vertices: data.vertices, indices: data.indices, uvs: data.uvs)
        }
    }

    static func rayName(_ id: String) -> String { "accessory:" + id }

    func clothedMesh(_ part: String) -> Mesh? { clothedMeshes[part] }

    // MARK: - Pictures

    /// A picture reference as a texture: built in, or a picture imported into `model`.
    func texture(_ reference: String, model: SceneModel) -> MTLTexture? {
        guard let (key, image) = Self.source(reference, model: model) else { return nil }
        if let known = textures[key] { return known }
        let made = image().flatMap(makeTexture)
        textures[key] = made
        return made
    }

    /// What a body part wears: pants and shirt together on the torso, the shirt on the
    /// arms, the pants on the legs. Nil for a part with nothing on.
    func clothing(for look: AvatarLook, part: String, model: SceneModel) -> MTLTexture? {
        let layers: [String]
        switch part {
        case "Torso": layers = [look.pants, look.shirt]
        case "Left Arm", "Right Arm": layers = [look.shirt]
        case "Left Leg", "Right Leg": layers = [look.pants]
        default: return nil
        }
        let sources = layers.filter { !$0.isEmpty }.compactMap { Self.source($0, model: model) }
        guard !sources.isEmpty else { return nil }
        if sources.count == 1 { return texture(layers.first { !$0.isEmpty }!, model: model) }
        let key = "clothes:" + sources.map(\.key).joined(separator: "|")
        if let known = textures[key] { return known }
        let made = Self.layered(sources.compactMap { $0.image() }).flatMap(makeTexture)
        textures[key] = made
        return made
    }

    /// A reference's cache key (an imported file's changes with its contents) and how to
    /// get its picture.
    private static func source(_ reference: String, model: SceneModel) -> (key: String, image: () -> CGImage?)? {
        if AvatarCatalog.builtIn(reference) != nil {
            return (reference, { AvatarCatalog.image(reference) })
        }
        guard let asset = model.asset(named: reference), asset.kind == .image else { return nil }
        let data = asset.data
        return ("\(asset.id.uuidString):\(data.count)", { AvatarCatalog.decode(data) })
    }

    /// Pictures drawn one over another on the clothing template.
    private static func layered(_ images: [CGImage]) -> CGImage? {
        let width = Int(ClothingTemplate.width), height = Int(ClothingTemplate.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for image in images { context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        return context.makeImage()
    }

    /// A picture as a mipmapped RGBA texture, its colours premultiplied by alpha (the
    /// clothed shader divides it out), at most 1024 on a side.
    private func makeTexture(_ image: CGImage) -> MTLTexture? {
        let scale = min(1, 1024 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height,
                                                                  mipmapped: true)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels,
                        bytesPerRow: width * 4)
        if let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
        }
        return texture
    }
}
