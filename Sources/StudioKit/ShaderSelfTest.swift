import Foundation
import Metal
import QuartzCore
import simd

/// Verification for user-written shaders: the generated Metal, the compiler's
/// diagnostics, parameter binding and how a shader travels with a scene.
enum ShaderSelfTest {

    static func run(check: Checker) {
        testUniformLayout(check)
        testParameterPacking(check)
        testGeneratedMetalCompiles(check)
        testParametersReachTheShader(check)
        testErrorsPointAtTheUsersLine(check)
        testPipelineCreation(check)
        testParameterNames(check)
        testSceneIntegration(check)
        testLibrary(check)
    }

    /// The runtime path: debounce, background compile, and what happens when a shader
    /// breaks, is disabled or is deleted while the renderer is using it.
    private static func testLibrary(_ check: Checker) {
        print("\nShaders: compile pipeline")
        guard let device else {
            check("a metal device is available", false)
            return
        }
        let library = ShaderLibrary(device: device,
                                    formats: ShaderLibrary.Formats(color: .bgra8Unorm,
                                                                   depth: .depth32Float,
                                                                   sampleCount: 4))
        let store = ShaderStatusStore()
        library.status = store
        var compiled: [String] = []
        var failed: [String] = []
        library.onCompiled = { compiled.append($0) }
        library.onDiagnostics = { name, _ in failed.append(name) }

        func settle(_ seconds: TimeInterval = 1.2) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        var shader = ShaderObject()
        shader.name = "Live"
        shader.source = ShaderObject.pulseExample
        shader.parameters = [ShaderParameter(name: "speed", value: 2),
                             ShaderParameter(name: "glow", value: 1)]

        let clock = CACurrentMediaTime()
        library.refresh(shaders: [shader], now: clock)
        check("nothing compiles the instant a shader appears",
              library.pipeline(for: shader.id) == nil)
        library.refresh(shaders: [shader], now: clock + 0.1)
        check("the debounce holds while the source is still changing",
              library.pipeline(for: shader.id) == nil)

        library.refresh(shaders: [shader], now: clock + 1)
        settle()
        check("it compiles once the source settles", library.pipeline(for: shader.id) != nil)
        check("the status becomes ready", store.status(for: shader.id) == .ready,
              "\(store.status(for: shader.id))")
        check("success is reported once", compiled == ["Live"], "\(compiled)")

        // A compiled shader is not rebuilt for nothing.
        library.refresh(shaders: [shader], now: clock + 2)
        settle(0.3)
        check("an unchanged shader is not recompiled", compiled == ["Live"], "\(compiled)")

        // Editing it rebuilds.
        let good = library.pipeline(for: shader.id)
        shader.source = "return baseColor * speed;"
        library.refresh(shaders: [shader], now: clock + 3)
        library.refresh(shaders: [shader], now: clock + 4)
        settle()
        check("editing the source recompiles", compiled.count == 2, "\(compiled)")
        check("and swaps the pipeline", library.pipeline(for: shader.id) !== good)

        // Breaking it keeps the last pipeline so the viewport stays readable.
        let lastGood = library.pipeline(for: shader.id)
        shader.source = "this is not metal;\nreturn baseColor;"
        library.refresh(shaders: [shader], now: clock + 5)
        library.refresh(shaders: [shader], now: clock + 6)
        settle()
        check("a broken shader is reported", failed == ["Live"], "\(failed)")
        check("the status shows the failure", store.status(for: shader.id).isFailed)
        check("the last working pipeline is kept",
              library.pipeline(for: shader.id) === lastGood)

        // Fixing it recovers.
        shader.source = "return baseColor;"
        library.refresh(shaders: [shader], now: clock + 7)
        library.refresh(shaders: [shader], now: clock + 8)
        settle()
        check("fixing the shader recovers", store.status(for: shader.id) == .ready,
              "\(store.status(for: shader.id))")

        // Disabling drops it back to the built-in shading.
        shader.enabled = false
        library.refresh(shaders: [shader], now: clock + 9)
        check("disabling a shader releases its pipeline",
              library.pipeline(for: shader.id) == nil)

        // Deleting it forgets everything.
        shader.enabled = true
        library.refresh(shaders: [shader], now: clock + 10)
        library.refresh(shaders: [shader], now: clock + 11)
        settle()
        check("re-enabling compiles it again", library.pipeline(for: shader.id) != nil)
        library.refresh(shaders: [], now: clock + 12)
        check("a deleted shader is forgotten", library.pipeline(for: shader.id) == nil)

        // An empty body never reaches the compiler.
        var empty = ShaderObject()
        empty.name = "Empty"
        empty.source = "   "
        failed = []
        library.refresh(shaders: [empty], now: clock + 13)
        library.refresh(shaders: [empty], now: clock + 14)
        settle(0.3)
        check("an empty shader is rejected without compiling", failed == ["Empty"], "\(failed)")
        check("and has no pipeline", library.pipeline(for: empty.id) == nil)
    }

    private static var device: MTLDevice? { MTLCreateSystemDefaultDevice() }

    /// Compiles a body the way the app does; returns the problems, empty when it built.
    private static func compile(_ body: String, parameters: [ShaderParameter] = [],
                                name: String = "Test") -> [String] {
        guard let device else { return ["no metal device"] }
        let problems = ShaderSource.validate(body: body)
        guard problems.isEmpty else { return problems.map { "\(name): \($0)" } }
        let source = ShaderSource.wrap(body: body, parameters: parameters)
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            guard library.makeFunction(name: ShaderSource.fragmentFunctionName) != nil,
                  library.makeFunction(name: ShaderSource.vertexFunctionName) != nil
            else { return ["missing functions"] }
            return []
        } catch {
            return ShaderSource.readableDiagnostics((error as NSError).localizedDescription,
                                                    shaderName: name)
        }
    }

    // MARK: - Tests

    private static func testUniformLayout(_ check: Checker) {
        print("\nShaders: uniform layout")
        check("FrameUniforms is 112 bytes", MemoryLayout<FrameUniforms>.stride == 112,
              "\(MemoryLayout<FrameUniforms>.stride)")
        check("ShaderUniforms is 64 bytes", MemoryLayout<ShaderUniforms>.stride == 64,
              "\(MemoryLayout<ShaderUniforms>.stride)")
    }

    private static func testParameterPacking(_ check: Checker) {
        print("\nShaders: parameter packing")
        let packed = ShaderUniforms([1, 2, 3, 4, 5, 6, 7, 8])
        check("the first four land in params0",
              packed.params0 == Vec4(1, 2, 3, 4), "\(packed.params0)")
        check("the next four land in params1",
              packed.params1 == Vec4(5, 6, 7, 8), "\(packed.params1)")

        let sparse = ShaderUniforms([9])
        check("unset parameters are zero",
              sparse.params0 == Vec4(9, 0, 0, 0) && sparse.params1 == .zero, "\(sparse.params0)")

        let sixteen = ShaderUniforms((1...16).map(Float.init))
        check("sixteen fit, four to a block",
              sixteen.params2 == Vec4(9, 10, 11, 12) && sixteen.params3 == Vec4(13, 14, 15, 16), "\(sixteen.params3)")

        let overflow = ShaderUniforms(Array(repeating: Float(1), count: 20))
        check("more than sixteen values do not overflow",
              overflow.params3 == Vec4(1, 1, 1, 1), "\(overflow.params3)")
        let screen = ScreenUniforms(values: (1...16).map(Float.init))
        check("a screen shader gets all sixteen too", screen.params3 == Vec4(13, 14, 15, 16), "\(screen.params3)")
    }

    private static func testGeneratedMetalCompiles(_ check: Checker) {
        print("\nShaders: generated Metal")
        guard device != nil else {
            check("a metal device is available", false)
            return
        }

        let template = compile(ShaderObject.template,
                               parameters: [ShaderParameter(name: "amount", value: 1)])
        check("the new-shader template compiles", template.isEmpty, "\(template)")

        let example = compile(ShaderObject.pulseExample,
                              parameters: [ShaderParameter(name: "speed", value: 2),
                                           ShaderParameter(name: "glow", value: 1)])
        check("the shipped example compiles", example.isEmpty, "\(example)")

        // Every documented input has to actually be in scope.
        for input in ShaderSource.inputs {
            let body = input.type == "float"
                ? "return float3(\(input.name));"
                : "return \(input.name);"
            let problems = compile(body)
            check("\(input.name) is in scope", problems.isEmpty, "\(problems)")
        }

        check("an empty body is reported rather than silently accepted",
              !compile("").isEmpty, "\(compile(""))")
        check("a comments-only body is reported",
              !compile("// just thinking out loud").isEmpty)
        check("a body that never returns is reported",
              compile("float a = 1.0;").contains { $0.contains("never returns") },
              "\(compile("float a = 1.0;"))")
        check("the word return inside a comment does not count",
              !compile("// remember to return something").isEmpty)
        check("a valid body passes validation", ShaderSource.validate(body: "return baseColor;").isEmpty)
    }

    private static func testParametersReachTheShader(_ check: Checker) {
        print("\nShaders: parameters")
        let params = [ShaderParameter(name: "speed", value: 2),
                      ShaderParameter(name: "glow", value: 1)]
        check("declared parameters are usable by name",
              compile("return baseColor * speed * glow;", parameters: params).isEmpty)
        check("an undeclared name is a compile error",
              !compile("return baseColor * missing;", parameters: params).isEmpty)

        // All sixteen slots bind, across the four vectors.
        let sixteen = (0..<16).map { ShaderParameter(name: "p\($0)", value: Float($0)) }
        let body = "return baseColor * (" + (0..<16).map { "p\($0)" }.joined(separator: " + ") + ");"
        check("all sixteen parameter slots bind", compile(body, parameters: sixteen).isEmpty,
              "\(compile(body, parameters: sixteen))")

        let source = ShaderSource.wrap(body: "return baseColor;", parameters: sixteen)
        check("the fifth parameter reads from the second vector, the sixteenth from the fourth",
              source.contains("float p4 = shaderParams.params1.x;")
              && source.contains("float p15 = shaderParams.params3.w;"), "binding missing")
    }

    /// The `#line` directive should make the compiler count from the user's first line.
    private static func testErrorsPointAtTheUsersLine(_ check: Checker) {
        print("\nShaders: error reporting")
        let body = """
        float a = 1.0;
        float b = 2.0;
        this line is not valid metal;
        return baseColor * (a + b);
        """
        let problems = compile(body, name: "Pulse")
        check("a broken body fails to compile", !problems.isEmpty)
        check("the error names the shader",
              problems.contains { $0.contains("Pulse:") }, "\(problems)")
        check("the error points at the user's own line 3",
              problems.contains { $0.contains("Pulse:3:") }, "\(problems)")
        check("no internal file name leaks out",
              !problems.contains { $0.contains("program_source") }, "\(problems)")

        // An error on the first line must report line 1, not the prelude's length.
        // The body still returns, so it reaches the compiler rather than validation.
        let firstLine = compile("nonsense here;\nreturn baseColor;", name: "First")
        check("an error on the first line reports line 1",
              firstLine.contains { $0.contains("First:1:") }, "\(firstLine)")
    }

    private static func testPipelineCreation(_ check: Checker) {
        print("\nShaders: pipeline")
        guard let device else {
            check("a metal device is available", false)
            return
        }
        let source = ShaderSource.wrap(body: ShaderObject.pulseExample,
                                       parameters: [ShaderParameter(name: "speed", value: 2),
                                                    ShaderParameter(name: "glow", value: 1)])
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: ShaderSource.vertexFunctionName)
            descriptor.fragmentFunction = library.makeFunction(name: ShaderSource.fragmentFunctionName)
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.depthAttachmentPixelFormat = .depth32Float
            descriptor.rasterSampleCount = 4
            descriptor.colorAttachments[0].isBlendingEnabled = true
            _ = try device.makeRenderPipelineState(descriptor: descriptor)
            check("a render pipeline builds from a user shader", true)
        } catch {
            check("a render pipeline builds from a user shader", false, "\(error)")
        }
    }

    private static func testParameterNames(_ check: Checker) {
        print("\nShaders: parameter names")
        check("a plain name is allowed", ShaderSource.isValidParameterName("speed"))
        check("underscores and digits are allowed", ShaderSource.isValidParameterName("wave_2"))
        check("a leading digit is rejected", !ShaderSource.isValidParameterName("2fast"))
        check("spaces are rejected", !ShaderSource.isValidParameterName("wave speed"))
        check("an empty name is rejected", !ShaderSource.isValidParameterName(""))
        check("punctuation is rejected", !ShaderSource.isValidParameterName("a-b"))
        check("a Metal keyword is rejected", !ShaderSource.isValidParameterName("float"))
        check("an injected input name is rejected", !ShaderSource.isValidParameterName("time"))

        // A rejected name must not be pasted into the generated source.
        let source = ShaderSource.wrap(body: "return baseColor;",
                                       parameters: [ShaderParameter(name: "a-b", value: 1)])
        check("an invalid name is left out of the generated Metal",
              !source.contains("a-b"), "invalid name leaked")
        check("and the shader still compiles", compile("return baseColor;",
                                                       parameters: [ShaderParameter(name: "a-b", value: 1)]).isEmpty)
    }

    private static func testSceneIntegration(_ check: Checker) {
        print("\nShaders: in a scene")
        let model = SceneModel()
        model.loadStarterScene()

        check("the starter scene ships a shader", !model.shaders.isEmpty)
        check("it is applied to a part",
              model.parts.contains { $0.shaderID != nil })
        guard let shipped = model.shaders(kind: .surface).first else {
            check("a surface shader ships", false)
            return
        }
        check("the shipped shader has parameters", shipped.parameters.count == 2,
              "\(shipped.parameters.map(\.name))")
        check("the shipped shader compiles",
              compile(shipped.source, parameters: shipped.parameters).isEmpty,
              "\(compile(shipped.source, parameters: shipped.parameters))")

        // Round-trips through a scene file.
        do {
            let restored = SceneModel()
            try restored.loadScene(from: model.encodeScene())
            check("shaders round-trip", restored.shaders.count == model.shaders.count)
            check("shader source round-trips",
                  restored.shader(id: shipped.id)?.source == shipped.source)
            check("shader parameters round-trip",
                  restored.shader(id: shipped.id)?.parameters.map(\.name) == shipped.parameters.map(\.name))
            check("the part's assignment round-trips",
                  restored.parts.contains { $0.shaderID == shipped.id })
        } catch {
            check("scene round-trip", false, "\(error)")
        }

        // Deleting a shader must not leave parts pointing at nothing.
        let before = model.shaders.count
        model.deleteShader(id: shipped.id)
        check("deleting a shader removes it", model.shaders.count == before - 1,
              "\(model.shaders.count)")
        check("and clears it from every part",
              model.parts.allSatisfy { $0.shaderID != shipped.id })
        model.undo()
        check("deleting a shader can be undone",
              model.shaders.count == before && model.parts.contains { $0.shaderID == shipped.id })

        // Assignment helper.
        let target = model.parts[0].id
        model.assignShader(shipped.id, to: [target])
        check("a shader can be applied to a selection",
              model.part(id: target)?.shaderID == shipped.id)
        model.assignShader(nil, to: [target])
        check("and cleared again", model.part(id: target)?.shaderID == nil)

        // An older scene file without shaders still opens.
        let legacy = "{ \"parts\": [ { \"name\": \"Old\" } ] }"
        let older = SceneModel()
        try? older.loadScene(from: Data(legacy.utf8))
        check("a scene saved before shaders existed still opens",
              older.parts.count == 1 && older.shaders.isEmpty)
    }
}
