import Metal
import MetalKit
import simd

final class Renderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    /// The pipelines that are lit: made once for conventional lighting and, when the
    /// GPU can ray trace, again with the `studioRayTraced` function constant on.
    private struct LitPipelines {
        let opaque: MTLRenderPipelineState
        let blend: MTLRenderPipelineState
        let grid: MTLRenderPipelineState
        /// A MeshPart with a TextureID.
        let textured: MTLRenderPipelineState
        let texturedBlend: MTLRenderPipelineState
        /// A body part in a shirt or pants.
        let clothed: MTLRenderPipelineState
        let clothedBlend: MTLRenderPipelineState
    }
    private var litPipelines: [Bool: LitPipelines] = [:]
    /// This frame's variant.
    private var lit: LitPipelines!
    private var scenePipeline: MTLRenderPipelineState? { lit?.opaque }
    private var sceneBlendPipeline: MTLRenderPipelineState? { lit?.blend }
    private var flatPipeline: MTLRenderPipelineState!
    private var flatBlendPipeline: MTLRenderPipelineState!
    private var skyPipeline: MTLRenderPipelineState!
    private var shadowPipeline: MTLRenderPipelineState!
    private var depthSky: MTLDepthStencilState!
    /// A Sky's six pictures as a cube, and which pictures (and how big) it was made from.
    private var skyboxCube: (key: [String], sizes: [Int], texture: MTLTexture)?
    /// The particles of the world's ParticleEmitters, this view's own, and what draws them.
    let particles = ParticleSystem()
    private var particleDrawer: ParticleRenderer?
    /// Where the world's Trails have been, as this view has seen, and what draws Beams and Trails.
    let trails = TrailSystem()
    private var ribbonDrawer: RibbonRenderer?

    // Lighting.
    static let shadowMapSize = 2048
    private var shadowMap: MTLTexture!
    /// Whether this GPU can ray trace from a fragment shader.
    let rayTracingSupported: Bool
    private var rayTracing: RayTracingScene?
    /// What the current frame is lit with; set by `prepareLighting`.
    private struct FrameLighting {
        var uniforms: LightingUniforms
        var pointLights: [PointLightData]
        var rayTraced: RayTracingScene.Built?
        var sky: Bool
    }
    private var frameLighting: FrameLighting?
    /// The ray-tracing meshes' source data, kept until `RayTracingScene` is built.
    private var rayMeshes: [(name: String, mesh: Mesh, vertices: [Vertex], indices: [UInt16])] = []

    private var depthDefault: MTLDepthStencilState!
    private var depthNoWrite: MTLDepthStencilState!
    private var depthAlways: MTLDepthStencilState!

    private var shapeMeshes: [PartShape: Mesh] = [:]
    /// Imported meshes on the GPU, and MeshParts' pictures, by asset.
    private var assetMeshes: [UUID: Mesh] = [:]
    private var assetTextures: [UUID: (size: Int, texture: MTLTexture?)] = [:]
    private var groundMesh: Mesh!
    private var outlineMesh: Mesh!
    private var coneMesh: Mesh!
    private var shaftMesh: Mesh!
    private var cubeMesh: Mesh!
    private var ringMesh: Mesh!
    private var quadMesh: Mesh!
    /// The avatar's meshes, built at the body parts' real sizes.
    private var avatarMeshes: [String: Mesh] = [:]
    private var faceMesh: Mesh!
    /// Accessories, clothes and face pictures.
    private var wardrobe: AvatarWardrobe!

    unowned var source: ViewportSource
    private(set) var viewportSize = SIMD2<Float>(1, 1)

    /// User shaders, compiled on demand.
    private(set) var shaderLibrary: ShaderLibrary!
    private let startTime = CACurrentMediaTime()
    private var lastFrameTime = CACurrentMediaTime()

    // Offscreen targets, created only while a screen shader is switched on.
    private var sceneMultisampleTexture: MTLTexture?
    private var sceneResolveTexture: MTLTexture?
    /// Where each screen effect but the last draws, two in turn, when several run one
    /// after another; the formats match the view's, which the effects are compiled for.
    private var effectTextures: [MTLTexture] = []
    private var effectMultisample: MTLTexture?
    private var effectDepth: MTLTexture?
    private var sceneDepthTexture: MTLTexture?
    private(set) var offscreenSize = SIMD2<Int>(0, 0)
    private var colorFormat: MTLPixelFormat = .bgra8Unorm
    private var depthFormat: MTLPixelFormat = .depth32Float
    private var sampleCount = 4

    init?(device: MTLDevice, view: MTKView, source: ViewportSource) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        self.source = source
        self.rayTracingSupported = Self.canRayTrace(device)
        super.init()

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColor(red: 0.086, green: 0.094, blue: 0.11, alpha: 1)

        do {
            try buildPipelines(view: view)
        } catch {
            NSLog("Metal pipeline error: \(error)")
            return nil
        }
        buildMeshes()
        guard let wardrobe = AvatarWardrobe(device: device, queue: queue) else { return nil }
        self.wardrobe = wardrobe
        rayMeshes += wardrobe.accessorySources
        if rayTracingSupported {
            rayTracing = RayTracingScene(device: device, meshes: rayMeshes)
            if rayTracing == nil { NSLog("Ray tracing unavailable: acceleration structures failed to build") }
        }
        rayMeshes = []
        let shadowDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: Self.shadowMapSize, height: Self.shadowMapSize, mipmapped: false)
        shadowDescriptor.usage = [.renderTarget, .shaderRead]
        shadowDescriptor.storageMode = .private
        shadowMap = device.makeTexture(descriptor: shadowDescriptor)

        colorFormat = view.colorPixelFormat
        depthFormat = view.depthStencilPixelFormat
        sampleCount = view.sampleCount

        shaderLibrary = ShaderLibrary(
            device: device,
            rayTracing: rayTracingSupported,
            formats: ShaderLibrary.Formats(color: view.colorPixelFormat,
                                           depth: view.depthStencilPixelFormat,
                                           sampleCount: view.sampleCount))
        shaderLibrary.status = source.shaderStatus
        shaderLibrary.onDiagnostics = { [weak self] name, problems in
            guard let self else { return }
            self.source.shaderConsole.error("Shader \(name) failed to compile:")
            for problem in problems { self.source.shaderConsole.error("  \(problem)") }
        }
        shaderLibrary.onCompiled = { [weak self] name in
            self?.source.shaderConsole.info("Compiled shader \(name)")
        }
    }

    // MARK: - Setup

    /// A GPU that can ray trace from a fragment shader.
    static func canRayTrace(_ device: MTLDevice) -> Bool {
        device.supportsRaytracing && device.supportsRaytracingFromRender
    }

    /// Compile options for anything that includes `lightingMetalSource`.
    static func lightingCompileOptions(rayTracing: Bool) -> MTLCompileOptions {
        let options = MTLCompileOptions()
        options.preprocessorMacros = ["STUDIO_RAYTRACING": NSNumber(value: rayTracing ? 1 : 0)]
        return options
    }

    /// The function-constant values that pick a lit pipeline's variant.
    static func lightingConstants(rayTraced: Bool) -> MTLFunctionConstantValues {
        let values = MTLFunctionConstantValues()
        var flag = rayTraced
        values.setConstantValue(&flag, type: .bool, index: 0)
        return values
    }

    private func buildPipelines(view: MTKView) throws {
        let library = try device.makeLibrary(source: metalShaderSource,
                                             options: Self.lightingCompileOptions(rayTracing: rayTracingSupported))

        func makePipeline(vertex: String, fragment: String?, blending: Bool,
                          rayTraced: Bool? = nil) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            if let fragment {
                descriptor.fragmentFunction = try rayTraced.map {
                    try library.makeFunction(name: fragment, constantValues: Self.lightingConstants(rayTraced: $0))
                } ?? library.makeFunction(name: fragment)
            }
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            descriptor.rasterSampleCount = view.sampleCount
            if blending {
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.sourceAlphaBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        for rayTraced in rayTracingSupported ? [false, true] : [false] {
            litPipelines[rayTraced] = LitPipelines(
                opaque: try makePipeline(vertex: "scene_vertex", fragment: "scene_fragment", blending: false,
                                         rayTraced: rayTraced),
                blend: try makePipeline(vertex: "scene_vertex", fragment: "scene_fragment", blending: true,
                                        rayTraced: rayTraced),
                grid: try makePipeline(vertex: "scene_vertex", fragment: "grid_fragment", blending: true,
                                       rayTraced: rayTraced),
                textured: try makePipeline(vertex: "scene_vertex_textured", fragment: "scene_fragment_textured",
                                           blending: false, rayTraced: rayTraced),
                texturedBlend: try makePipeline(vertex: "scene_vertex_textured", fragment: "scene_fragment_textured",
                                                blending: true, rayTraced: rayTraced),
                clothed: try makePipeline(vertex: "scene_vertex_textured", fragment: "scene_fragment_clothed",
                                          blending: false, rayTraced: rayTraced),
                clothedBlend: try makePipeline(vertex: "scene_vertex_textured", fragment: "scene_fragment_clothed",
                                               blending: true, rayTraced: rayTraced))
        }
        lit = litPipelines[false]
        flatPipeline = try makePipeline(vertex: "scene_vertex", fragment: "flat_fragment", blending: false)
        flatBlendPipeline = try makePipeline(vertex: "scene_vertex", fragment: "flat_fragment", blending: true)
        skyPipeline = try makePipeline(vertex: "sky_vertex", fragment: "sky_fragment", blending: false)
        particleDrawer = ParticleRenderer(device: device, library: library, color: view.colorPixelFormat,
                                          depth: view.depthStencilPixelFormat, samples: view.sampleCount)
        ribbonDrawer = RibbonRenderer(device: device, library: library, color: view.colorPixelFormat,
                                      depth: view.depthStencilPixelFormat, samples: view.sampleCount)

        // Depth only, from the sun, into the shadow map.
        let shadow = MTLRenderPipelineDescriptor()
        shadow.vertexFunction = library.makeFunction(name: "scene_vertex")
        shadow.depthAttachmentPixelFormat = .depth32Float
        shadowPipeline = try device.makeRenderPipelineState(descriptor: shadow)

        func makeDepth(compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)!
        }
        depthDefault = makeDepth(compare: .less, write: true)
        depthNoWrite = makeDepth(compare: .less, write: false)
        depthAlways = makeDepth(compare: .always, write: true)
        depthSky = makeDepth(compare: .always, write: false)
    }

    private func buildMeshes() {
        func make(_ data: ([Vertex], [UInt16]), _ type: MTLPrimitiveType = .triangle) -> Mesh {
            Mesh(device: device, vertices: data.0, indices: data.1, primitiveType: type)!
        }
        // Everything a ray can hit is also remembered for the acceleration structures.
        func traced(_ name: String, _ data: ([Vertex], [UInt16])) -> Mesh {
            let mesh = make(data)
            rayMeshes.append((name, mesh, data.0, data.1))
            return mesh
        }
        for shape in PartShape.allCases {
            let data: ([Vertex], [UInt16])
            switch shape {
            case .block, .truss: data = MeshFactory.box()
            case .sphere: data = MeshFactory.sphere()
            case .cylinder: data = MeshFactory.cylinder()
            case .wedge: data = MeshFactory.wedge()
            }
            shapeMeshes[shape] = traced(shape.rawValue, data)
        }

        groundMesh = make(MeshFactory.groundQuad())
        outlineMesh = make(MeshFactory.boxOutline(), .line)
        coneMesh = make(MeshFactory.cone())
        shaftMesh = make(MeshFactory.cylinder(segments: 14))
        cubeMesh = shapeMeshes[.block]!
        ringMesh = make(MeshFactory.torus())
        quadMesh = make(MeshFactory.groundQuad(extent: 0.5))

        let limb = traced("avatar.limb", MeshFactory.roundedBox(size: Vec3(1, 2, 1), radius: 0.24))
        avatarMeshes = [
            "Torso": traced("avatar.torso", MeshFactory.roundedBox(size: Vec3(2, 2, 1), radius: 0.2)),
            "Left Arm": limb, "Right Arm": limb, "Left Leg": limb, "Right Leg": limb,
            "Head": traced("avatar.head", MeshFactory.head()),
        ]
        faceMesh = make(MeshFactory.face())
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportSize = SIMD2<Float>(Float(size.width), Float(size.height))
    }

    /// A frame of everything but drawing, for while a script or shader tab hides the
    /// world: a play test runs on, and edited shaders compile so their tab can show how
    /// that went.
    func tick() {
        source.stepFrame()
        shaderLibrary.refresh(shaders: source.model.shaders)
    }

    func draw(in view: MTKView) {
        // The game's frame first — scripts, physics, sounds — and only then a command
        // buffer. Anything that goes wrong in the game can then never leave a buffer
        // taken and not committed: the queue holds only 64, and once they're gone the
        // next frame waits for one for ever.
        source.stepFrame()
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = commandQueue.makeCommandBuffer()
        else { return }

        encodeFrame(buffer, into: descriptor)
        buffer.present(drawable)
        buffer.commit()
    }

    /// One frame — the world, any screen effects in turn, and the editor's overlays —
    /// into a pass: the view's drawable, or a snapshot's own target.
    private func encodeFrame(_ buffer: MTLCommandBuffer, into descriptor: MTLRenderPassDescriptor) {
        // How long drawing takes on the CPU, for the Stats service.
        let began = CACurrentMediaTime()
        defer { (source as? PlayController)?.frameStats.note(draw: CACurrentMediaTime() - began) }

        let model = source.model
        let camera = source.renderCamera
        let overlay = source.editorOverlay
        let aspect = viewportSize.x / max(viewportSize.y, 1)

        // User shaders recompile off-thread when their source settles.
        shaderLibrary.refresh(shaders: model.shaders)

        let now = CACurrentMediaTime()
        let delta = Float(min(max(now - lastFrameTime, 0), 0.25))
        lastFrameTime = now
        particles.step(dt: delta, model: model)
        trails.step(dt: delta, model: model)

        var frame = FrameUniforms()
        frame.viewProjection = camera.viewProjection(aspect: aspect)
        frame.cameraPosition = Vec4(camera.position, 1)
        frame.lightDirection = Vec4(model.lighting.lightDirection, 0)
        frame.timing = Vec4(Float(now - startTime), delta, 0, 0)
        prepareLighting(buffer, model: model, camera: camera, viewProjection: frame.viewProjection)

        // Screen effects only cost anything when one is switched on and compiled:
        // otherwise the scene goes straight to the drawable exactly as it always did.
        let effects = model.activeScreenShaders.compactMap { shader -> (ShaderObject, MTLRenderPipelineState)? in
            guard shader.enabled, let pipeline = shaderLibrary.pipeline(for: shader.id) else { return nil }
            return (shader, pipeline)
        }

        if !effects.isEmpty, let scenePass = offscreenPassDescriptor(), var input = sceneResolveTexture {
            // 1. The world, into a texture.
            if let encoder = buffer.makeRenderCommandEncoder(descriptor: scenePass) {
                encodeScene(encoder, model: model, camera: camera, frame: &frame)
                encoder.endEncoding()
            }
            // 2. Each effect but the last into a texture of its own, the next reading it.
            let time = Float(now - startTime)
            for (index, effect) in effects.dropLast().enumerated() {
                guard let pass = effectPassDescriptor(index % 2),
                      let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { continue }
                encodeScreenShader(encoder, shader: effect.0, pipeline: effect.1, input: input, time: time, camera: camera)
                encoder.endEncoding()
                input = effectTextures[index % 2]
            }
            // 3. The last, then the editor's own furniture on top of it — gizmos and
            //    selection boxes stay legible instead of being tinted by the effect.
            if let last = effects.last, let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) {
                encodeScreenShader(encoder, shader: last.0, pipeline: last.1, input: input, time: time, camera: camera)
                encodeOverlays(encoder, model: model, camera: camera, overlay: overlay, frame: &frame)
                encoder.endEncoding()
            }
        } else if let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) {
            encodeScene(encoder, model: model, camera: camera, frame: &frame)
            encodeOverlays(encoder, model: model, camera: camera, overlay: overlay, frame: &frame)
            encoder.endEncoding()
        }
    }

    /// A pass into one of the two in-between textures, for an effect with another after it.
    private func effectPassDescriptor(_ index: Int) -> MTLRenderPassDescriptor? {
        guard index < effectTextures.count, let effectDepth else { return nil }
        let pass = MTLRenderPassDescriptor()
        if let effectMultisample {
            pass.colorAttachments[0].texture = effectMultisample
            pass.colorAttachments[0].resolveTexture = effectTextures[index]
            pass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].texture = effectTextures[index]
            pass.colorAttachments[0].storeAction = .store
        }
        pass.colorAttachments[0].loadAction = .clear
        pass.depthAttachment.texture = effectDepth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        return pass
    }

    /// A whole frame, effects and all, drawn off screen at the view's formats and read
    /// back — how the tests see screen effects chained.
    func frameSnapshot(width: Int, height: Int) -> [SIMD4<UInt8>]? {
        viewportSize = SIMD2<Float>(Float(width), Float(height))
        guard let buffer = commandQueue.makeCommandBuffer() else { return nil }
        func texture(_ format: MTLPixelFormat, samples: Int, usage: MTLTextureUsage) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width,
                                                                      height: height, mipmapped: false)
            if samples > 1 {
                descriptor.textureType = .type2DMultisample
                descriptor.sampleCount = samples
            }
            descriptor.usage = usage
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }
        guard let resolve = texture(colorFormat, samples: 1, usage: [.renderTarget, .shaderRead]),
              let depth = texture(depthFormat, samples: sampleCount, usage: [.renderTarget]) else { return nil }
        let pass = MTLRenderPassDescriptor()
        if sampleCount > 1, let multisample = texture(colorFormat, samples: sampleCount, usage: [.renderTarget]) {
            pass.colorAttachments[0].texture = multisample
            pass.colorAttachments[0].resolveTexture = resolve
            pass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].texture = resolve
            pass.colorAttachments[0].storeAction = .store
        }
        pass.colorAttachments[0].loadAction = .clear
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        encodeFrame(buffer, into: pass)
        let bytesPerRow = width * 4
        guard let readback = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let blit = buffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: resolve, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback,
                  destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        let pixels = readback.contents().bindMemory(to: SIMD4<UInt8>.self, capacity: width * height)
        return Array(UnsafeBufferPointer(start: pixels, count: width * height))
    }

    /// The world: grid, parts and the player avatar.
    private func encodeScene(_ encoder: MTLRenderCommandEncoder, model: SceneModel,
                             camera: Camera, frame: inout FrameUniforms) {
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.back)
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        bindLighting(encoder)

        if frameLighting?.sky == true {
            if let cube = skybox(model: model) { encoder.setFragmentTexture(cube, index: 6) }
            encoder.setRenderPipelineState(skyPipeline)
            encoder.setDepthStencilState(depthSky)
            encoder.setCullMode(.none)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.setCullMode(.back)
        }

        if model.showGrid {
            encoder.setRenderPipelineState(lit.grid)
            encoder.setDepthStencilState(depthDefault)
            encoder.setCullMode(.none)
            var draw = DrawUniforms()
            draw.color = Vec4(1, 1, 1, 1)
            submit(encoder, mesh: groundMesh, uniforms: &draw)
            encoder.setCullMode(.back)
        }

        let visible = model.parts.filter(\.inWorld)
        let opaque = visible.filter { $0.transparency <= 0.001 }
        let transparent = visible.filter { $0.transparency > 0.001 }
            .sorted { length_squared($0.position - camera.position) > length_squared($1.position - camera.position) }

        encoder.setDepthStencilState(depthDefault)
        for part in opaque { drawPart(encoder, part: part, model: model, fallback: lit.opaque, cull: .back) }

        if !transparent.isEmpty {
            encoder.setDepthStencilState(depthNoWrite)
            encoder.setCullMode(.none)
            for part in transparent {
                drawPart(encoder, part: part, model: model, fallback: lit.blend, cull: .none)
            }
            encoder.setCullMode(.back)
        }

        for avatar in source.avatars where !avatar.hidden {
            drawAvatar(encoder, avatar: avatar)
        }

        if let ribbonDrawer, model.constraints.contains(where: \.kind.isEffect) {
            let strips = Ribbons.strips(model: model, trails: trails, eye: camera.position,
                                        time: Float(CACurrentMediaTime() - startTime))
            ribbonDrawer.draw(encoder, strips: strips, frame: &frame, depth: depthNoWrite) { texture(named: $0, model: model) }
        }
        particleDrawer?.draw(encoder, system: particles, model: model, camera: camera, frame: &frame,
                             depth: depthNoWrite) { texture(named: $0, model: model) }
    }

    /// Selection boxes and the manipulation gizmo, always drawn last and never
    /// touched by a screen shader.
    private func encodeOverlays(_ encoder: MTLRenderCommandEncoder, model: SceneModel,
                                camera: Camera, overlay: EditorOverlay?, frame: inout FrameUniforms) {
        guard let overlay else { return }
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.back)
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)

        if !overlay.selection.isEmpty {
            encoder.setRenderPipelineState(flatPipeline)
            encoder.setDepthStencilState(depthAlways)
            for part in model.parts where overlay.selection.contains(part.id) {
                var draw = DrawUniforms()
                // Nudge the box outwards so it hugs the surface without z-fighting.
                let padded = part.size + Vec3(repeating: 0.02)
                draw.model = Mat.translation(part.position) * Mat.rotation(part.orientation) * Mat.scale(padded)
                draw.normalMatrix = Mat.normalMatrix(draw.model)
                draw.color = Vec4(1.0, 0.68, 0.16, 1)
                draw.shading = Vec4(0, 1, 0, 0)
                submit(encoder, mesh: outlineMesh, uniforms: &draw)
            }
        }

        // The part held as the first end of a weld or joint: green, so it reads
        // differently from a selection.
        if let held = overlay.joinPending, let part = model.part(id: held) {
            encoder.setRenderPipelineState(flatPipeline)
            encoder.setDepthStencilState(depthAlways)
            var draw = DrawUniforms()
            let padded = part.size + Vec3(repeating: 0.04)
            draw.model = Mat.translation(part.position) * Mat.rotation(part.orientation) * Mat.scale(padded)
            draw.normalMatrix = Mat.normalMatrix(draw.model)
            draw.color = Vec4(0.35, 0.92, 0.45, 1)
            draw.shading = Vec4(0, 1, 0, 0)
            submit(encoder, mesh: outlineMesh, uniforms: &draw)
        }

        drawJoints(encoder, model: model)
        drawGizmo(encoder, model: model, camera: camera, overlay: overlay)
    }

    /// The full-screen pass: one triangle carrying the user's shader, reading the world
    /// (or the effect before it) and the world's depth.
    private func encodeScreenShader(_ encoder: MTLRenderCommandEncoder, shader: ShaderObject,
                                    pipeline: MTLRenderPipelineState, input: MTLTexture, time: Float, camera: Camera) {
        guard let sceneDepthTexture else { return }
        var uniforms = ScreenUniforms(size: viewportSize, time: time,
                                      near: camera.near, far: camera.far,
                                      values: shader.parameters.map(\.value))
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthAlways)
        encoder.setCullMode(.none)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ScreenUniforms>.stride, index: 0)
        encoder.setFragmentTexture(input, index: 0)
        encoder.setFragmentTexture(sceneDepthTexture, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.setCullMode(.back)
    }

    /// Offscreen colour and depth, recreated whenever the drawable changes size.
    /// Renders one frame of the scene (no overlays, no screen effect) to an image, off
    /// screen. Used by `--render-avatar` to check the avatar by eye without a display.
    func snapshot(width: Int, height: Int) -> CGImage? {
        viewportSize = SIMD2<Float>(Float(width), Float(height))
        guard let pass = offscreenPassDescriptor(), let buffer = commandQueue.makeCommandBuffer(),
              let texture = sceneResolveTexture else { return nil }
        let camera = source.renderCamera
        var frame = FrameUniforms()
        frame.viewProjection = camera.viewProjection(aspect: Float(width) / Float(height))
        frame.cameraPosition = Vec4(camera.position, 1)
        frame.lightDirection = Vec4(source.model.lighting.lightDirection, 0)
        prepareLighting(buffer, model: source.model, camera: camera, viewProjection: frame.viewProjection)
        if let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) {
            encodeScene(encoder, model: source.model, camera: camera, frame: &frame)
            encoder.endEncoding()
        }
        let bytesPerRow = width * 4
        guard let readback = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let blit = buffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: readback, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()

        let data = Data(bytes: readback.contents(), count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                | CGImageAlphaInfo.noneSkipFirst.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func offscreenPassDescriptor() -> MTLRenderPassDescriptor? {
        let width = Int(viewportSize.x.rounded())
        let height = Int(viewportSize.y.rounded())
        guard width > 0, height > 0 else { return nil }

        if offscreenSize != SIMD2<Int>(width, height) || sceneResolveTexture == nil {
            guard makeOffscreenTextures(width: width, height: height) else { return nil }
            offscreenSize = SIMD2<Int>(width, height)
        }
        guard let sceneMultisampleTexture, let sceneResolveTexture, let sceneDepthTexture else {
            return nil
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = sceneMultisampleTexture
        pass.colorAttachments[0].resolveTexture = sceneResolveTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.086, green: 0.094, blue: 0.11, alpha: 1)
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = sceneDepthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1.0
        // Kept rather than resolved: the screen shader reads sample 0 directly, which
        // avoids depending on multisample depth-resolve support.
        pass.depthAttachment.storeAction = .store
        return pass
    }

    private func makeOffscreenTextures(width: Int, height: Int) -> Bool {
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorFormat, width: width, height: height, mipmapped: false)
        colorDescriptor.textureType = .type2DMultisample
        colorDescriptor.sampleCount = sampleCount
        colorDescriptor.usage = [.renderTarget]
        colorDescriptor.storageMode = .private

        let resolveDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorFormat, width: width, height: height, mipmapped: false)
        resolveDescriptor.usage = [.renderTarget, .shaderRead]
        resolveDescriptor.storageMode = .private

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: depthFormat, width: width, height: height, mipmapped: false)
        depthDescriptor.textureType = .type2DMultisample
        depthDescriptor.sampleCount = sampleCount
        depthDescriptor.usage = [.renderTarget, .shaderRead]
        depthDescriptor.storageMode = .private

        guard let multisample = device.makeTexture(descriptor: colorDescriptor),
              let resolve = device.makeTexture(descriptor: resolveDescriptor),
              let depth = device.makeTexture(descriptor: depthDescriptor)
        else {
            NSLog("Could not create offscreen targets for the screen shader")
            return false
        }
        sceneMultisampleTexture = multisample
        sceneResolveTexture = resolve
        sceneDepthTexture = depth

        // The in-between targets for chained effects, at the view's formats.
        effectTextures = (0..<2).compactMap { _ in device.makeTexture(descriptor: resolveDescriptor) }
        let effectDepthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: depthFormat, width: width, height: height, mipmapped: false)
        if sampleCount > 1 {
            effectDepthDescriptor.textureType = .type2DMultisample
            effectDepthDescriptor.sampleCount = sampleCount
            effectMultisample = device.makeTexture(descriptor: colorDescriptor)
        } else {
            effectMultisample = nil
        }
        effectDepthDescriptor.usage = [.renderTarget]
        effectDepthDescriptor.storageMode = .private
        effectDepth = device.makeTexture(descriptor: effectDepthDescriptor)
        return true
    }

    // MARK: - Lighting

    /// Works out this frame's lighting and encodes what has to happen before the scene
    /// is drawn: the sun's shadow map (conventional) or the acceleration structure
    /// (ray traced). The live view and snapshots both come through here.
    private func prepareLighting(_ buffer: MTLCommandBuffer, model: SceneModel, camera: Camera,
                                 viewProjection: float4x4) {
        let settings = model.lighting
        let wantsRays = settings.technology == .rayTraced && rayTracing != nil && litPipelines[true] != nil
        let avatars = source.avatars

        // Point lights: the nearest to the camera, if there are too many.
        var lights: [PointLightData] = []
        for part in model.parts where part.inWorld {
            guard let light = part.light, light.enabled, light.brightness > 0, light.range > 0 else { continue }
            lights.append(PointLightData(
                positionRange: Vec4(part.position, min(light.range, PointLight.maximumRange)),
                colorBrightness: Vec4(light.color, light.brightness),
                options: Vec4(light.shadows ? 1 : 0, 0, 0, 0)))
        }
        if lights.count > PointLight.maximumPerFrame {
            func distance(_ light: PointLightData) -> Float {
                let p = light.positionRange
                return simd_distance(Vec3(p.x, p.y, p.z), camera.position)
            }
            lights.sort { distance($0) < distance($1) }
            lights.removeLast(lights.count - PointLight.maximumPerFrame)
        }

        // The sun's view: an orthographic box around what the camera is looking at,
        // snapped to whole texels so shadows don't shimmer as the camera moves.
        let toLight = settings.lightDirection
        let extent = min(max(camera.distance * 1.6 + 30, 40), 260)
        let texel = extent * 2 / Float(Self.shadowMapSize)
        let up = abs(toLight.y) > 0.99 ? Vec3(0, 0, 1) : Vec3(0, 1, 0)
        var view = Mat.lookAt(eye: camera.target + toLight * 500, center: camera.target, up: up)
        let centre = view * Vec4(camera.target, 1)
        let snapped = Vec3((centre.x / texel).rounded() * texel, (centre.y / texel).rounded() * texel, centre.z)
        view = Mat.translation(Vec3(snapped.x - centre.x, snapped.y - centre.y, 0)) * view
        let shadowViewProjection = Self.orthographic(halfSize: extent, near: 1, far: 1000) * view

        var uniforms = LightingUniforms(settings: settings, shadowViewProjection: shadowViewProjection,
                                        inverseViewProjection: viewProjection.inverse, shadowTexel: texel,
                                        pointLights: lights.count, groundPlane: model.showGrid,
                                        time: Float(CACurrentMediaTime() - startTime),
                                        skybox: skybox(model: model) != nil)
        lit = litPipelines[wantsRays] ?? litPipelines[false]

        var built: RayTracingScene.Built?
        if wantsRays, let rayTracing {
            built = rayTracing.build(rayInstances(model: model, avatars: avatars), into: buffer)
        }
        if built == nil {
            lit = litPipelines[false]
            if settings.globalShadows {
                encodeShadowMap(buffer, model: model, avatars: avatars, viewProjection: shadowViewProjection)
            } else {
                uniforms.sunDirection.w = 0
            }
        }
        frameLighting = FrameLighting(uniforms: uniforms, pointLights: lights, rayTraced: built, sky: settings.sky)
    }

    static func orthographic(halfSize: Float, near: Float, far: Float) -> float4x4 {
        float4x4(columns: (Vec4(1 / halfSize, 0, 0, 0),
                           Vec4(0, 1 / halfSize, 0, 0),
                           Vec4(0, 0, -1 / (far - near), 0),
                           Vec4(0, 0, -near / (far - near), 1)))
    }

    /// What casts a shadow: visible parts that are mostly opaque, and every avatar.
    private func shadowCasters(model: SceneModel, avatars: [AvatarPose]) -> [(mesh: Mesh, matrix: float4x4)] {
        var casters: [(Mesh, float4x4)] = []
        for part in model.parts where part.inWorld && part.transparency < 0.5 {
            if let mesh = meshOf(part) { casters.append((mesh, part.modelMatrix)) }
        }
        for avatar in avatars {
            for (name, matrix) in avatar.partTransforms()
            where (avatar.transparency[name] ?? 0) < 0.5 {
                if let mesh = avatarMeshes[name] { casters.append((mesh, matrix)) }
            }
            for worn in accessories(of: avatar, model: model) where (avatar.transparency[worn.part] ?? 0) < 0.5 {
                casters.append((worn.mesh, worn.matrix))
            }
        }
        return casters
    }

    private func encodeShadowMap(_ buffer: MTLCommandBuffer, model: SceneModel, avatars: [AvatarPose],
                                 viewProjection: float4x4) {
        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = shadowMap
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Shadow map"
        encoder.setRenderPipelineState(shadowPipeline)
        encoder.setDepthStencilState(depthDefault)
        encoder.setCullMode(.none)
        var frame = FrameUniforms()
        frame.viewProjection = viewProjection
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        for (mesh, matrix) in shadowCasters(model: model, avatars: avatars) {
            var draw = DrawUniforms()
            draw.model = matrix
            encoder.setVertexBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: 2)
            mesh.draw(encoder)
        }
        encoder.endEncoding()
    }

    private func rayInstances(model: SceneModel, avatars: [AvatarPose]) -> [RayTracingScene.Instance] {
        var instances: [RayTracingScene.Instance] = []
        for part in model.parts where part.inWorld && part.transparency < 0.5 {
            let shading = part.material.shading
            let name = assetMesh(for: part) != nil ? "mesh:\(part.mesh?.asset?.uuidString ?? "")" : part.shape.rawValue
            instances.append(.init(mesh: name, transform: part.modelMatrix, color: part.color,
                                   shading: Vec4(shading.x, shading.y, shading.z, 0),
                                   mask: part.light?.enabled == true ? RayTracingScene.maskLightHousing
                                                                     : RayTracingScene.maskSolid))
        }
        let meshNames = ["Torso": "avatar.torso", "Head": "avatar.head"]
        for avatar in avatars {
            for (name, matrix) in avatar.partTransforms() where (avatar.transparency[name] ?? 0) < 0.5 {
                instances.append(.init(mesh: meshNames[name] ?? "avatar.limb", transform: matrix,
                                       color: avatar.colors[name] ?? Vec3(repeating: 0.6),
                                       shading: Vec4(0.22, 22, 0, 0), mask: RayTracingScene.maskSolid))
            }
            for worn in accessories(of: avatar, model: model) where (avatar.transparency[worn.part] ?? 0) < 0.5 {
                instances.append(.init(mesh: worn.rayName, transform: worn.matrix, color: worn.accessory.color,
                                       shading: Vec4(0.22, 22, 0, 0), mask: RayTracingScene.maskSolid))
            }
        }
        return instances
    }

    /// Everything a lit fragment reads, bound once per scene pass.
    private func bindLighting(_ encoder: MTLRenderCommandEncoder) {
        guard var lighting = frameLighting else { return }
        encoder.setFragmentBytes(&lighting.uniforms, length: MemoryLayout<LightingUniforms>.stride, index: 4)
        var lights = lighting.pointLights.isEmpty ? [PointLightData()] : lighting.pointLights
        encoder.setFragmentBytes(&lights, length: MemoryLayout<PointLightData>.stride * lights.count, index: 5)
        encoder.setFragmentTexture(shadowMap, index: 0)
        if let built = lighting.rayTraced, let rayTracing {
            encoder.setFragmentAccelerationStructure(built.accelerationStructure, bufferIndex: 6)
            encoder.setFragmentBuffer(built.instanceInfo, offset: 0, index: 7)
            encoder.setFragmentBuffer(rayTracing.faceNormals, offset: 0, index: 8)
            encoder.useResources(rayTracing.primitiveStructures, usage: .read, stages: .fragment)
        }
    }

    /// The Sky's six pictures as one cube texture, when it has all six and they load; made
    /// again only when they change. Faces go +X Rt, −X Lf, +Y Up, −Y Dn, +Z Ft, −Z Bk: the
    /// sky pass looks the cube up with Z turned round, so north (−Z) is Ft.
    private func skybox(model: SceneModel) -> MTLTexture? {
        guard let sky = model.lighting.skyObject, sky.hasSkybox else { return nil }
        let order: [SkySettings.Face] = [.rt, .lf, .up, .dn, .ft, .bk]
        let assets = order.map { model.asset(named: sky.picture($0)) }
        guard assets.allSatisfy({ $0?.kind == .image }) else { return nil }
        let key = order.map { sky.picture($0) }, sizes = assets.map { $0?.data.count ?? 0 }
        if let cube = skyboxCube, cube.key == key, cube.sizes == sizes { return cube.texture }
        let images = assets.compactMap { asset -> CGImage? in
            guard let data = asset?.data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard images.count == 6 else { return nil }
        let side = min(max(images.map { max($0.width, $0.height) }.max() ?? 64, 16), 1024)
        let descriptor = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba8Unorm, size: side, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for (slice, image) in images.enumerated() {
            pixels.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                              bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            }
            texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, slice: slice,
                            withBytes: pixels, bytesPerRow: side * 4, bytesPerImage: side * side * 4)
        }
        skyboxCube = (key, sizes, texture)
        return texture
    }

    /// The technology this frame was actually drawn with, for the status bar.
    var drewRayTraced: Bool { frameLighting?.rayTraced != nil }

    // MARK: - Drawing helpers

    private func submit(_ encoder: MTLRenderCommandEncoder, mesh: Mesh, uniforms: inout DrawUniforms) {
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<DrawUniforms>.stride, index: 2)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DrawUniforms>.stride, index: 2)
        mesh.draw(encoder)
    }

    /// A MeshPart's mesh on the GPU, made the first time it's drawn — and handed to the
    /// ray tracer too; nil for other parts, and for a mesh whose file is missing.
    private func assetMesh(for part: Part) -> Mesh? {
        part.mesh?.asset.flatMap(assetMesh)
    }

    private func assetMesh(_ asset: UUID) -> Mesh? {
        guard let geometry = MeshLibrary.shared.geometry(asset) else { return nil }
        if let known = assetMeshes[asset] { return known }
        let vertices = zip(geometry.positions, geometry.normals).map { Vertex(position: $0, normal: $1) }
        guard let mesh = Mesh(device: device, vertices: vertices, indices: geometry.indices, uvs: geometry.uvs) else {
            return nil
        }
        assetMeshes[asset] = mesh
        rayTracing?.add(name: "mesh:\(asset.uuidString)", mesh: mesh, normals: geometry.normals, indices: geometry.indices)
        return mesh
    }

    /// What a part is drawn with: its mesh, or its shape's.
    private func meshOf(_ part: Part) -> Mesh? { assetMesh(for: part) ?? shapeMeshes[part.shape] }

    /// A MeshPart's TextureID as a texture, loaded once per picture.
    private func texture(for part: Part, model: SceneModel) -> MTLTexture? {
        texture(named: part.mesh?.textureId ?? "", model: model)
    }

    private func texture(named name: String, model: SceneModel) -> MTLTexture? {
        guard !name.isEmpty, let asset = model.asset(named: name), asset.kind == .image else { return nil }
        if let known = assetTextures[asset.id], known.size == asset.data.count { return known.texture }
        let loaded = try? MTKTextureLoader(device: device).newTexture(data: asset.data, options: [
            .SRGB: false, .generateMipmaps: true, .origin: MTKTextureLoader.Origin.topLeft,
            .textureStorageMode: MTLStorageMode.private.rawValue,
        ])
        assetTextures[asset.id] = (asset.data.count, loaded)
        return loaded
    }

    private func drawPart(_ encoder: MTLRenderCommandEncoder, part: Part,
                          model: SceneModel, fallback: MTLRenderPipelineState, cull: MTLCullMode) {
        let imported = assetMesh(for: part)
        guard let mesh = imported ?? shapeMeshes[part.shape] else { return }

        // A part with a shader that has compiled draws with it; anything else — no
        // shader, disabled, still compiling, broken — falls back to the built-in pass.
        var pipeline = fallback
        if let shaderID = part.shaderID,
           let shader = model.shader(id: shaderID), shader.enabled,
           let userPipeline = shaderLibrary.pipeline(for: shaderID, rayTraced: frameLighting?.rayTraced != nil) {
            pipeline = userPipeline
            var params = ShaderUniforms(shader.parameters.map(\.value))
            encoder.setFragmentBytes(&params, length: MemoryLayout<ShaderUniforms>.stride, index: 3)
        } else if imported?.uvBuffer != nil, let picture = texture(for: part, model: model), let lit {
            pipeline = fallback === lit.opaque ? lit.textured : lit.texturedBlend
            encoder.setFragmentTexture(picture, index: 3)
        }
        encoder.setRenderPipelineState(pipeline)
        // Imported meshes can be wound either way: both sides are drawn.
        if imported != nil && cull != .none { encoder.setCullMode(.none) }
        defer { if imported != nil && cull != .none { encoder.setCullMode(cull) } }

        var draw = DrawUniforms()
        draw.model = part.modelMatrix
        draw.normalMatrix = Mat.normalMatrix(draw.model)
        draw.color = Vec4(part.color, 1 - part.transparency)
        let shading = part.material.shading
        draw.shading = Vec4(shading.x, shading.y, shading.z, 0)
        submit(encoder, mesh: mesh, uniforms: &draw)
    }

    private func drawGizmo(_ encoder: MTLRenderCommandEncoder, model: SceneModel, camera: Camera, overlay: EditorOverlay) {
        let mode = overlay.gizmoMode
        guard mode != .select, let pivot = model.selectionCenter else { return }
        let basis = Gizmo.basis(for: model, forceLocal: mode == .scale)
        let s = GizmoLayout.scale(pivot: pivot, cameraPosition: camera.position)
        let active = overlay.activeHandle

        encoder.setRenderPipelineState(flatPipeline)
        encoder.setDepthStencilState(depthAlways)
        encoder.setCullMode(.none)

        func color(for handle: GizmoHandle, axis: Int) -> Vec3 {
            active == handle ? GizmoLayout.highlightColor : GizmoLayout.axisColors[axis]
        }

        switch mode {
        case .select:
            break

        case .move, .scale:
            for axis in 0..<3 {
                let dir = normalize(basis[axis])
                let handle: GizmoHandle = mode == .move ? .translateAxis(axis) : .scaleAxis(axis)
                let tint = color(for: handle, axis: axis)
                let alignment = alignmentMatrix(to: dir)

                // Shaft: a thin cylinder from the pivot outwards.
                let shaftLength = (GizmoLayout.axisEnd - GizmoLayout.axisStart) * s
                let shaftCenter = pivot + dir * ((GizmoLayout.axisStart + GizmoLayout.axisEnd) * 0.5 * s)
                var shaft = DrawUniforms()
                shaft.model = Mat.translation(shaftCenter) * alignment
                    * Mat.scale(Vec3(GizmoLayout.shaftRadius * 2 * s, shaftLength, GizmoLayout.shaftRadius * 2 * s))
                shaft.normalMatrix = Mat.normalMatrix(shaft.model)
                shaft.color = Vec4(tint, 1)
                shaft.shading = Vec4(0, 1, 0.5, 0)
                submit(encoder, mesh: shaftMesh, uniforms: &shaft)

                // Tip: an arrow cone for move, a cube for scale.
                var tip = DrawUniforms()
                tip.color = Vec4(tint, 1)
                tip.shading = Vec4(0, 1, 0.8, 0)
                if mode == .move {
                    let base = pivot + dir * (GizmoLayout.axisEnd * s)
                    tip.model = Mat.translation(base) * alignment
                        * Mat.scale(Vec3(GizmoLayout.coneRadius * 2 * s, GizmoLayout.coneLength * s, GizmoLayout.coneRadius * 2 * s))
                    tip.normalMatrix = Mat.normalMatrix(tip.model)
                    submit(encoder, mesh: coneMesh, uniforms: &tip)
                } else {
                    let center = pivot + dir * ((GizmoLayout.axisEnd + GizmoLayout.handleCube * 0.5) * s)
                    tip.model = Mat.translation(center) * alignment * Mat.scale(Vec3(repeating: GizmoLayout.handleCube * s))
                    tip.normalMatrix = Mat.normalMatrix(tip.model)
                    submit(encoder, mesh: cubeMesh, uniforms: &tip)
                }
            }

            // Plane handles for two-axis dragging.
            if mode == .move {
                encoder.setRenderPipelineState(flatBlendPipeline)
                for axis in 0..<3 {
                    let handle = GizmoHandle.translatePlane(axis)
                    let n = normalize(basis[axis])
                    let a1 = normalize(basis[(axis + 1) % 3])
                    let a2 = normalize(basis[(axis + 2) % 3])
                    let mid = (GizmoLayout.planeInner + GizmoLayout.planeOuter) * 0.5 * s
                    let side = (GizmoLayout.planeOuter - GizmoLayout.planeInner) * s
                    let center = pivot + a1 * mid + a2 * mid
                    var plane = DrawUniforms()
                    plane.model = Mat.translation(center) * alignmentMatrix(to: n) * Mat.scale(Vec3(side, 1, side))
                    plane.normalMatrix = Mat.normalMatrix(plane.model)
                    let tint = active == handle ? GizmoLayout.highlightColor : GizmoLayout.axisColors[axis]
                    plane.color = Vec4(tint, active == handle ? 0.75 : 0.35)
                    plane.shading = Vec4(0, 1, 0, 0)
                    submit(encoder, mesh: quadMesh, uniforms: &plane)
                }
                encoder.setRenderPipelineState(flatPipeline)
            }

        case .rotate:
            for axis in 0..<3 {
                let handle = GizmoHandle.rotateAxis(axis)
                let n = normalize(basis[axis])
                var ring = DrawUniforms()
                ring.model = Mat.translation(pivot) * alignmentMatrix(to: n)
                    * Mat.scale(Vec3(repeating: GizmoLayout.ringRadius * s))
                ring.normalMatrix = Mat.normalMatrix(ring.model)
                ring.color = Vec4(color(for: handle, axis: axis), 1)
                ring.shading = Vec4(0, 1, 0.4, 0)
                submit(encoder, mesh: ringMesh, uniforms: &ring)
            }
        }

        encoder.setCullMode(.back)
    }

    /// The six-part avatar: rounded limbs and torso, a classic head with a face, posed
    /// by `AvatarPose.partTransforms`.
    private func drawAvatar(_ encoder: MTLRenderCommandEncoder, avatar: AvatarPose) {
        encoder.setDepthStencilState(depthDefault)
        let model = source.model
        for (name, matrix) in avatar.partTransforms() {
            let transparency = min(max(avatar.transparency[name] ?? 0, 0), 1)
            guard transparency < 0.999, var mesh = avatarMeshes[name],
                  var pipeline = transparency > 0 ? sceneBlendPipeline : scenePipeline, let lit else { continue }
            // In clothes: the body part with the template's coordinates, and the picture.
            if let clothes = wardrobe.clothing(for: avatar.look, part: name, model: model),
               let clothed = wardrobe.clothedMesh(name) {
                mesh = clothed
                pipeline = transparency > 0 ? lit.clothedBlend : lit.clothed
                encoder.setFragmentTexture(clothes, index: 3)
            }
            encoder.setRenderPipelineState(pipeline)

            var draw = DrawUniforms()
            draw.model = matrix
            draw.normalMatrix = Mat.normalMatrix(matrix)
            var tint = avatar.colors[name] ?? Vec3(repeating: 0.6)
            if avatar.highlighted == name {
                tint = simd_mix(tint, Vec3(1, 1, 1), Vec3(repeating: 0.35))
            }
            draw.color = Vec4(tint, 1 - transparency)
            // A highlighted part glows a little, so it reads even in shadow.
            draw.shading = Vec4(0.22, 22, avatar.highlighted == name ? 0.25 : 0, 0)
            submit(encoder, mesh: mesh, uniforms: &draw)

            if name == "Head" {
                drawFace(encoder, look: avatar.look, matrix: matrix, transparency: transparency, model: model)
            }
        }
        drawAccessories(encoder, avatar: avatar, model: model)
    }

    /// The classic smile as shapes, or a face picture on the front of the head.
    private func drawFace(_ encoder: MTLRenderCommandEncoder, look: AvatarLook, matrix: float4x4,
                          transparency: Float, model: SceneModel) {
        var face = DrawUniforms()
        face.model = matrix
        face.normalMatrix = Mat.normalMatrix(matrix)
        if look.face.isEmpty {
            guard let pipeline = transparency > 0 ? sceneBlendPipeline : scenePipeline else { return }
            encoder.setRenderPipelineState(pipeline)
            face.color = Vec4(0.08, 0.08, 0.1, 1 - transparency)
            face.shading = Vec4(0.5, 40, 0, 0)
            submit(encoder, mesh: faceMesh, uniforms: &face)
            return
        }
        guard let picture = wardrobe.texture(look.face, model: model), let lit else { return }
        encoder.setRenderPipelineState(lit.texturedBlend)
        encoder.setFragmentTexture(picture, index: 3)
        face.color = Vec4(1, 1, 1, 1 - transparency)
        face.shading = Vec4(0.3, 20, 0, 0)
        submit(encoder, mesh: wardrobe.faceDecal, uniforms: &face)
    }

    /// An accessory ready to draw: its mesh (built in or imported), where it goes, what
    /// the ray tracer knows its mesh as, and the body part it hangs from.
    private struct WornAccessory {
        let accessory: AvatarAccessory
        let part: String
        let mesh: Mesh
        let matrix: float4x4
        let rayName: String
        let imported: Bool
    }

    private func accessories(of avatar: AvatarPose, model: SceneModel) -> [WornAccessory] {
        guard !avatar.look.accessories.isEmpty else { return [] }
        var meshes: [String: (Mesh, String, Bool)] = [:]
        let placed = avatar.accessoryTransforms { accessory -> Vec3?? in
            if let id = AvatarCatalog.builtIn(accessory.item) {
                guard let mesh = self.wardrobe.accessoryMeshes[id] else { return nil }
                meshes[accessory.id] = (mesh, AvatarWardrobe.rayName(id), false)
                return .some(nil)
            }
            guard let asset = model.asset(named: accessory.item), asset.kind == .mesh,
                  let geometry = MeshLibrary.shared.geometry(asset.id), let mesh = self.assetMesh(asset.id) else { return nil }
            meshes[accessory.id] = (mesh, "mesh:\(asset.id.uuidString)", true)
            return .some(geometry.nativeSize)
        }
        return placed.compactMap { worn in
            guard let (mesh, rayName, imported) = meshes[worn.accessory.id] else { return nil }
            return WornAccessory(accessory: worn.accessory, part: worn.part, mesh: mesh, matrix: worn.matrix,
                                 rayName: rayName, imported: imported)
        }
    }

    private func drawAccessories(_ encoder: MTLRenderCommandEncoder, avatar: AvatarPose, model: SceneModel) {
        guard let lit else { return }
        for worn in accessories(of: avatar, model: model) {
            let transparency = min(max(avatar.transparency[worn.part] ?? 0, 0), 1)
            guard transparency < 0.999 else { continue }
            var pipeline = transparency > 0 ? lit.blend : lit.opaque
            if worn.imported, worn.mesh.uvBuffer != nil, let picture = texture(named: worn.accessory.textureId, model: model) {
                pipeline = transparency > 0 ? lit.texturedBlend : lit.textured
                encoder.setFragmentTexture(picture, index: 3)
            }
            encoder.setRenderPipelineState(pipeline)
            // Imported models can be wound either way: both sides are drawn.
            if worn.imported { encoder.setCullMode(.none) }
            var draw = DrawUniforms()
            draw.model = worn.matrix
            draw.normalMatrix = Mat.normalMatrix(worn.matrix)
            draw.color = Vec4(worn.accessory.color, 1 - transparency)
            draw.shading = Vec4(0.3, 28, 0, 0)
            submit(encoder, mesh: worn.mesh, uniforms: &draw)
            if worn.imported { encoder.setCullMode(.back) }
        }
    }

    /// Welds and joints, drawn in the editor so it is clear what is connected: a line
    /// between the ends, a blob at each attachment, and a hinge's axis through it.
    private func drawJoints(_ encoder: MTLRenderCommandEncoder, model: SceneModel) {
        guard !model.constraints.isEmpty || model.selectedAttachment != nil,
              let ball = shapeMeshes[.sphere] else { return }
        encoder.setRenderPipelineState(flatBlendPipeline)
        encoder.setDepthStencilState(depthNoWrite)

        func rod(from a: Vec3, to b: Vec3, thickness: Float, colour: Vec4) {
            let along = b - a
            let length = simd_length(along)
            guard length > 1e-4 else { return }
            var draw = DrawUniforms()
            draw.model = Mat.translation((a + b) * 0.5) * alignmentMatrix(to: along / length)
                * Mat.scale(Vec3(thickness, length, thickness))
            draw.normalMatrix = Mat.normalMatrix(draw.model)
            draw.color = colour
            draw.shading = Vec4(0, 1, 0.5, 0)
            submit(encoder, mesh: shaftMesh, uniforms: &draw)
        }
        func blob(at point: Vec3, size: Float, colour: Vec4) {
            var draw = DrawUniforms()
            draw.model = Mat.translation(point) * Mat.scale(Vec3(repeating: size))
            draw.normalMatrix = Mat.normalMatrix(draw.model)
            draw.color = colour
            draw.shading = Vec4(0, 1, 0.5, 0)
            submit(encoder, mesh: ball, uniforms: &draw)
        }

        // Beams and Trails draw themselves; picked, their attachments are shown.
        for constraint in model.constraints where !constraint.kind.isEffect || model.selectedConstraint == constraint.id {
            let selected = model.selectedConstraint == constraint.id
            let fade: Float = constraint.enabled ? (selected ? 1 : 0.75) : 0.35
            if constraint.kind.isEffect {
                for end in [constraint.attachment0, constraint.attachment1] {
                    guard let frame = end.flatMap(model.attachment(id:)).flatMap(model.worldFrame(of:)) else { continue }
                    blob(at: frame.position, size: 0.4, colour: Vec4(1.0, 0.78, 0.35, fade))
                }
                continue
            }
            switch constraint.kind {
            case .weld, .noCollision:
                guard let a = constraint.part0.flatMap({ model.part(id: $0) }),
                      let b = constraint.part1.flatMap({ model.part(id: $0) }) else { continue }
                rod(from: a.position, to: b.position, thickness: selected ? 0.16 : 0.1,
                    colour: constraint.kind == .weld ? Vec4(0.45, 0.85, 0.95, fade) : Vec4(0.95, 0.45, 0.45, fade))
            case .vectorForce:
                // Where it pushes from, and which way (in the world, as it is now).
                guard let a0 = constraint.attachment0.flatMap({ model.attachment(id: $0) }),
                      let f0 = model.worldFrame(of: a0), simd_length(constraint.force) > 0 else { continue }
                var push = simd_normalize(constraint.force)
                if constraint.relativeTo == .attachment0 {
                    let frame = simd_quatf(float3x3(f0.axis, f0.secondary, simd_cross(f0.axis, f0.secondary)))
                    push = frame.act(push)
                }
                let colour = Vec4(0.55, 0.95, 0.55, fade)
                rod(from: f0.position, to: f0.position + push * 2.5, thickness: selected ? 0.14 : 0.09, colour: colour)
                blob(at: f0.position + push * 2.5, size: 0.35, colour: colour)
            default:
                guard let a0 = constraint.attachment0.flatMap({ model.attachment(id: $0) }),
                      let a1 = constraint.attachment1.flatMap({ model.attachment(id: $0) }),
                      let f0 = model.worldFrame(of: a0), let f1 = model.worldFrame(of: a1) else { continue }
                let colour = Vec4(1.0, 0.78, 0.35, fade)
                rod(from: f0.position, to: f1.position, thickness: selected ? 0.14 : 0.09, colour: colour)
                blob(at: f0.position, size: 0.4, colour: colour)
                blob(at: f1.position, size: 0.4, colour: colour)
                if constraint.kind == .hinge || constraint.kind == .prismatic {
                    // The axis it turns or slides about.
                    let axis = f0.axis * 1.6
                    rod(from: f0.position - axis, to: f0.position + axis, thickness: 0.07,
                        colour: Vec4(0.55, 0.95, 0.6, fade))
                }
            }
        }
        for attachment in model.attachments where model.selectedAttachment == attachment.id {
            guard let frame = model.worldFrame(of: attachment) else { continue }
            blob(at: frame.position, size: 0.55, colour: Vec4(0.55, 0.95, 0.6, 1))
            rod(from: frame.position, to: frame.position + frame.axis * 2, thickness: 0.08,
                colour: Vec4(0.55, 0.95, 0.6, 1))
        }
        encoder.setDepthStencilState(depthAlways)
    }

    /// Rotation taking +Y onto `direction`, so Y-aligned gizmo meshes can point down any axis.
    private func alignmentMatrix(to direction: Vec3) -> float4x4 {
        let up = Vec3(0, 1, 0)
        let d = normalize(direction)
        let dotUD = dot(up, d)
        if dotUD > 0.9999 { return matrix_identity_float4x4 }
        if dotUD < -0.9999 { return Mat.rotation(simd_quatf(angle: .pi, axis: Vec3(1, 0, 0))) }
        let axis = normalize(cross(up, d))
        return Mat.rotation(simd_quatf(angle: acos(max(-1, min(1, dotUD))), axis: axis))
    }
}
