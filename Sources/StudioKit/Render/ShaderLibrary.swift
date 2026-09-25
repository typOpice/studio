import Metal
import Foundation
import Combine
import QuartzCore

enum ShaderStatus: Equatable {
    case idle
    case compiling
    case ready
    case failed([String])

    var isFailed: Bool { if case .failed = self { return true }; return false }
}

/// Compile results the UI watches.
final class ShaderStatusStore: ObservableObject {
    @Published private(set) var statuses: [UUID: ShaderStatus] = [:]

    func status(for id: UUID) -> ShaderStatus { statuses[id] ?? .idle }

    func set(_ status: ShaderStatus, for id: UUID) {
        if Thread.isMainThread {
            statuses[id] = status
        } else {
            DispatchQueue.main.async { [weak self] in self?.statuses[id] = status }
        }
    }

    func forget(_ id: UUID) {
        DispatchQueue.main.async { [weak self] in self?.statuses.removeValue(forKey: id) }
    }
}

/// Compiles user shaders and hands the renderer a pipeline for each one.
///
/// Compilation runs off the render thread and only after the source has stopped
/// changing, because invoking the Metal compiler takes long enough to stutter a
/// frame. The last pipeline that worked stays in use meanwhile, so a shader that is
/// mid-edit or broken never blanks the viewport — the part just keeps drawing with
/// whatever last compiled, or falls back to the built-in shading.
final class ShaderLibrary {

    struct Formats {
        var color: MTLPixelFormat
        var depth: MTLPixelFormat
        var sampleCount: Int
    }

    /// How long a shader's source must hold still before it is compiled.
    static let debounce: CFTimeInterval = 0.4

    private let device: MTLDevice
    private let formats: Formats
    /// Surface shaders are also built as a ray-traced variant when the GPU can.
    private let rayTracing: Bool
    private let queue = DispatchQueue(label: "studio.shader.compile", qos: .userInitiated)

    private var pipelines: [UUID: MTLRenderPipelineState] = [:]
    private var rayTracedPipelines: [UUID: MTLRenderPipelineState] = [:]
    private var compiledFingerprint: [UUID: Int] = [:]
    private var pendingFingerprint: [UUID: Int] = [:]
    private var pendingSince: [UUID: CFTimeInterval] = [:]
    private var inFlight: Set<UUID> = []

    var onDiagnostics: (String, [String]) -> Void = { _, _ in }
    var onCompiled: (String) -> Void = { _ in }
    var status: ShaderStatusStore?

    init(device: MTLDevice, rayTracing: Bool = false, formats: Formats) {
        self.device = device
        self.rayTracing = rayTracing
        self.formats = formats
    }

    /// The pipeline to draw with, or nil to fall back to the built-in shading. A
    /// surface shader has a ray-traced variant when the GPU supports one.
    func pipeline(for shaderID: UUID, rayTraced: Bool = false) -> MTLRenderPipelineState? {
        rayTraced ? (rayTracedPipelines[shaderID] ?? pipelines[shaderID]) : pipelines[shaderID]
    }

    /// Called once per frame with the scene's shaders.
    func refresh(shaders: [ShaderObject], now: CFTimeInterval = CACurrentMediaTime()) {
        let live = Set(shaders.map(\.id))
        for id in pipelines.keys where !live.contains(id) {
            pipelines.removeValue(forKey: id)
            rayTracedPipelines.removeValue(forKey: id)
            compiledFingerprint.removeValue(forKey: id)
            pendingFingerprint.removeValue(forKey: id)
            pendingSince.removeValue(forKey: id)
            status?.forget(id)
        }

        for shader in shaders {
            guard shader.enabled else {
                rayTracedPipelines.removeValue(forKey: shader.id)
                if pipelines.removeValue(forKey: shader.id) != nil {
                    compiledFingerprint.removeValue(forKey: shader.id)
                    status?.set(.idle, for: shader.id)
                }
                continue
            }

            let fingerprint = Self.fingerprint(shader)
            guard compiledFingerprint[shader.id] != fingerprint else { continue }

            if pendingFingerprint[shader.id] != fingerprint {
                pendingFingerprint[shader.id] = fingerprint
                pendingSince[shader.id] = now
                continue
            }
            guard let since = pendingSince[shader.id], now - since >= Self.debounce else { continue }
            guard !inFlight.contains(shader.id) else { continue }

            compile(shader, fingerprint: fingerprint)
        }
    }

    /// Compiles immediately, skipping the debounce — used by the editor's Compile action.
    func compileNow(_ shader: ShaderObject) {
        guard !inFlight.contains(shader.id) else { return }
        compile(shader, fingerprint: Self.fingerprint(shader))
    }

    private func compile(_ shader: ShaderObject, fingerprint: Int) {
        // Cheap checks the Metal compiler would not report as errors.
        let problems = ShaderSource.validate(body: shader.source)
        guard problems.isEmpty else {
            compiledFingerprint[shader.id] = fingerprint
            pipelines.removeValue(forKey: shader.id)
            rayTracedPipelines.removeValue(forKey: shader.id)
            let named = problems.map { "\(shader.name): \($0)" }
            status?.set(.failed(named), for: shader.id)
            onDiagnostics(shader.name, named)
            return
        }

        inFlight.insert(shader.id)
        status?.set(.compiling, for: shader.id)

        let source = ShaderSource.wrap(shader)
        let id = shader.id
        let name = shader.name
        let kind = shader.kind
        let device = self.device
        let formats = self.formats
        let rayTracing = self.rayTracing && kind == .surface

        queue.async { [weak self] in
            var built: MTLRenderPipelineState?
            var builtRayTraced: MTLRenderPipelineState?
            var problems: [String] = []
            do {
                let library = try device.makeLibrary(
                    source: source,
                    options: kind == .surface ? Renderer.lightingCompileOptions(rayTracing: rayTracing) : nil)
                let vertexName = kind == .surface
                    ? ShaderSource.vertexFunctionName : ShaderSource.screenVertexFunctionName
                let fragmentName = kind == .surface
                    ? ShaderSource.fragmentFunctionName : ShaderSource.screenFragmentFunctionName
                func fragment(rayTraced: Bool) throws -> MTLFunction? {
                    kind == .surface
                        ? try library.makeFunction(name: fragmentName,
                                                   constantValues: Renderer.lightingConstants(rayTraced: rayTraced))
                        : library.makeFunction(name: fragmentName)
                }
                guard let vertexFunction = library.makeFunction(name: vertexName),
                      let fragmentFunction = try fragment(rayTraced: false)
                else {
                    problems = ["\(name): the shader did not produce the expected functions."]
                    throw ShaderError.missingFunctions
                }
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertexFunction
                descriptor.fragmentFunction = fragmentFunction
                descriptor.colorAttachments[0].pixelFormat = formats.color
                // A screen shader draws into the view's own pass, which has a depth
                // attachment it never uses; a surface shader draws into the scene pass.
                descriptor.depthAttachmentPixelFormat = formats.depth
                descriptor.rasterSampleCount = formats.sampleCount
                // Blending on always: identical output for opaque parts, and lets a
                // shader be used on a transparent one without a second pipeline.
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.sourceAlphaBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

                built = try device.makeRenderPipelineState(descriptor: descriptor)
                if rayTracing, let rayFragment = try fragment(rayTraced: true) {
                    descriptor.fragmentFunction = rayFragment
                    builtRayTraced = try device.makeRenderPipelineState(descriptor: descriptor)
                }
            } catch let error as ShaderError {
                _ = error
            } catch {
                problems = ShaderSource.readableDiagnostics(
                    (error as NSError).localizedDescription, shaderName: name)
                if problems.isEmpty { problems = ["\(name): \(error.localizedDescription)"] }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(id)
                self.compiledFingerprint[id] = fingerprint
                if let built {
                    self.pipelines[id] = built
                    self.rayTracedPipelines[id] = builtRayTraced
                    self.status?.set(.ready, for: id)
                    self.onCompiled(name)
                } else {
                    // Keep the last good pipeline so the viewport stays readable.
                    self.status?.set(.failed(problems), for: id)
                    self.onDiagnostics(name, problems)
                }
            }
        }
    }

    private enum ShaderError: Error { case missingFunctions }

    private static func fingerprint(_ shader: ShaderObject) -> Int {
        var hasher = Hasher()
        hasher.combine(shader.source)
        for parameter in shader.parameters { hasher.combine(parameter.name) }
        return hasher.finalize()
    }
}
