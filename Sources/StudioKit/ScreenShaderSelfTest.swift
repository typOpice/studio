import Foundation
import Metal
import MetalKit
import AppKit
import simd

/// Verification for full-screen shaders.
///
/// Unlike surface shaders these can be checked all the way through: the whole effect
/// is one pass over a texture, so the test renders a known colour, runs the user's
/// shader over it and reads the pixels back. No display required.
enum ScreenShaderSelfTest {

    static func run(check: Checker) {
        testGeneratedMetalCompiles(check)
        testPassThrough(check)
        testBlackAndWhite(check)
        testSixteenParameters(check)
        testUVOrientation(check)
        testDepth(check)
        testNeighbourSampling(check)
        testSceneIntegration(check)
        testScriptControl(check)
        testRendererIntegration(check)
    }

    private static func testScriptControl(_ check: Checker) {
        print("\nScreen shaders: from a Wren script")
        let model = SceneModel()
        model.loadStarterScene()
        let console = ScriptConsole()
        let runtime = ScriptRuntime(model: model, console: console)

        // Wren's side of the screen API; Luau's is covered in ScriptSelfTest.
        var script = ScriptObject.blank(language: .wren)
        script.name = "Screen"
        script.source = """
        import "studio" for Screen, Shaders

        System.print(Screen.shader == null)
        var mono = Shaders.find("Black & White")
        System.print(mono.kind)
        System.print(Shaders.screens.count)

        Screen.shader = mono
        System.print(Screen.shader.name)
        """
        model.scripts = [script]
        runtime.start()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let printed = console.lines.filter { $0.kind == .output }.map(\.text)
        let errors = console.lines.filter { $0.kind == .error }.map(\.text)

        check("no errors", errors.isEmpty, "\(errors)")
        check("the screen starts clear", printed.contains("true"), "\(printed)")
        check("a shader reports its kind", printed.contains("screen"), "\(printed)")
        check("screen shaders can be listed", printed.contains("1"), "\(printed)")
        check("a script can switch the effect on",
              model.screenShaderID != nil && printed.contains("Black & White"), "\(printed)")

        // Switching it off again, and refusing a surface shader.
        let model2 = SceneModel()
        model2.loadStarterScene()
        let console2 = ScriptConsole()
        let runtime2 = ScriptRuntime(model: model2, console: console2)
        var script2 = ScriptObject.blank(language: .wren)
        script2.name = "Screen2"
        script2.source = """
        import "studio" for Screen, Shaders
        Screen.shader = Shaders.find("Black & White")
        Screen.off()
        Screen.shader = Shaders.find("Pulse")
        """
        model2.scripts = [script2]
        runtime2.start()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check("a script can switch it off again", model2.screenShaderID == nil)
        check("a surface shader is refused with an explanation",
              console2.lines.contains { $0.kind == .error && $0.text.contains("surface shader") },
              "\(console2.lines.filter { $0.kind == .error }.map(\.text))")
    }

    /// Drives the real renderer with an effect switched on, so the offscreen pass,
    /// the pipeline formats and the final pass are all exercised together.
    private static func testRendererIntegration(_ check: Checker) {
        print("\nScreen shaders: through the renderer")
        _ = NSApplication.shared
        guard let device else {
            check("a metal device is available", false)
            return
        }

        let model = SceneModel()
        model.loadStarterScene()
        guard let effect = model.shaders(kind: .screen).first else {
            check("the starter scene has a screen shader", false)
            return
        }
        model.setScreenShader(effect.id)

        let controller = ViewportController(model: model)
        let view = StudioMTKView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        guard let renderer = Renderer(device: device, view: view, source: controller) else {
            check("the renderer builds", false)
            return
        }
        check("the renderer builds", true)
        view.delegate = renderer

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 128, height: 128),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view

        // Compile the effect up front rather than waiting out the debounce.
        renderer.shaderLibrary.compileNow(effect)
        let deadline = Date().addingTimeInterval(3)
        while renderer.shaderLibrary.pipeline(for: effect.id) == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        check("the screen shader compiles for the real pipeline formats",
              renderer.shaderLibrary.pipeline(for: effect.id) != nil)

        renderer.mtkView(view, drawableSizeWillChange: CGSize(width: 128, height: 128))
        for _ in 0..<3 {
            view.draw()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        check("the offscreen targets were created at the drawable size",
              renderer.offscreenSize == SIMD2<Int>(128, 128), "\(renderer.offscreenSize)")

        // Switching it off must go straight back to the direct path.
        model.setScreenShader(nil)
        view.draw()
        check("drawing with no effect still works", true)

        view.removeFromSuperview()
    }

    private static var device: MTLDevice? { MTLCreateSystemDefaultDevice() }

    private static func compile(_ body: String, parameters: [ShaderParameter] = [],
                                name: String = "Screen") -> [String] {
        guard let device else { return ["no metal device"] }
        let problems = ShaderSource.validate(body: body)
        guard problems.isEmpty else { return problems.map { "\(name): \($0)" } }
        do {
            let library = try device.makeLibrary(
                source: ShaderSource.wrapScreen(body: body, parameters: parameters), options: nil)
            guard library.makeFunction(name: ShaderSource.screenFragmentFunctionName) != nil,
                  library.makeFunction(name: ShaderSource.screenVertexFunctionName) != nil
            else { return ["missing functions"] }
            return []
        } catch {
            return ShaderSource.readableDiagnostics((error as NSError).localizedDescription,
                                                    shaderName: name)
        }
    }

    // MARK: - GPU harness

    struct Rendered {
        var size: Int
        var pixels: [SIMD3<Float>]   // row major, row 0 is the top of the screen

        func at(_ x: Int, _ y: Int) -> SIMD3<Float> { pixels[y * size + x] }
        var centre: SIMD3<Float> { at(size / 2, size / 2) }
    }

    /// Renders one full-screen pass over a flat source colour and reads it back.
    private static func render(body: String,
                               parameters: [ShaderParameter] = [],
                               source: SIMD3<Float> = SIMD3(0.8, 0.2, 0.1),
                               depth: Double = 0.5,
                               near: Float = 0.1,
                               far: Float = 3000,
                               size: Int = 8) -> Rendered? {
        guard let device, let queue = device.makeCommandQueue() else { return nil }

        // The "scene" the effect runs over: a flat colour.
        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        sourceDescriptor.usage = [.shaderRead]
        sourceDescriptor.storageMode = .shared
        guard let sourceTexture = device.makeTexture(descriptor: sourceDescriptor) else { return nil }

        func byte(_ value: Float) -> UInt8 { UInt8(max(0, min(255, (value * 255).rounded()))) }
        var bytes = [UInt8]()
        for _ in 0..<(size * size) {
            bytes += [byte(source.z), byte(source.y), byte(source.x), 255]   // BGRA
        }
        sourceTexture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                              withBytes: bytes, bytesPerRow: size * 4)

        // A multisample depth buffer, cleared to a known value.
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: size, height: size, mipmapped: false)
        depthDescriptor.textureType = .type2DMultisample
        depthDescriptor.sampleCount = 4
        depthDescriptor.usage = [.renderTarget, .shaderRead]
        depthDescriptor.storageMode = .private
        guard let depthTexture = device.makeTexture(descriptor: depthDescriptor) else { return nil }

        guard let clearBuffer = queue.makeCommandBuffer() else { return nil }
        let clearPass = MTLRenderPassDescriptor()
        clearPass.depthAttachment.texture = depthTexture
        clearPass.depthAttachment.loadAction = .clear
        clearPass.depthAttachment.clearDepth = depth
        clearPass.depthAttachment.storeAction = .store
        clearPass.renderTargetWidth = size
        clearPass.renderTargetHeight = size
        clearBuffer.makeRenderCommandEncoder(descriptor: clearPass)?.endEncoding()
        clearBuffer.commit()
        clearBuffer.waitUntilCompleted()

        // Where the effect lands.
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        targetDescriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: targetDescriptor) else { return nil }

        let pipeline: MTLRenderPipelineState
        do {
            let library = try device.makeLibrary(
                source: ShaderSource.wrapScreen(body: body, parameters: parameters), options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: ShaderSource.screenVertexFunctionName)
            descriptor.fragmentFunction = library.makeFunction(name: ShaderSource.screenFragmentFunctionName)
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.rasterSampleCount = 1
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            return nil
        }

        guard let buffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }

        var uniforms = ScreenUniforms(size: SIMD2<Float>(Float(size), Float(size)),
                                      time: 0, near: near, far: far,
                                      values: parameters.map(\.value))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ScreenUniforms>.stride, index: 0)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentTexture(depthTexture, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()

        var output = [UInt8](repeating: 0, count: size * size * 4)
        target.getBytes(&output, bytesPerRow: size * 4,
                        from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)

        var pixels: [SIMD3<Float>] = []
        for index in 0..<(size * size) {
            let base = index * 4
            pixels.append(SIMD3<Float>(Float(output[base + 2]) / 255,   // BGRA → RGB
                                       Float(output[base + 1]) / 255,
                                       Float(output[base + 0]) / 255))
        }
        return Rendered(size: size, pixels: pixels)
    }

    private static func near(_ a: Float, _ b: Float, _ tolerance: Float = 0.02) -> Bool {
        abs(a - b) <= tolerance
    }

    // MARK: - Tests

    private static func testGeneratedMetalCompiles(_ check: Checker) {
        print("\nScreen shaders: generated Metal")
        // Must match the struct the wrapper generates, or parameters bind to nothing.
        check("ScreenUniforms is 112 bytes", MemoryLayout<ScreenUniforms>.stride == 112,
              "\(MemoryLayout<ScreenUniforms>.stride)")
        let template = compile(ShaderObject.screenTemplate,
                               parameters: [ShaderParameter(name: "amount", value: 1)])
        check("the new-screen-shader template compiles", template.isEmpty, "\(template)")

        let example = compile(ShaderObject.blackAndWhiteExample,
                              parameters: [ShaderParameter(name: "amount", value: 1)])
        check("the black and white example compiles", example.isEmpty, "\(example)")

        for input in ShaderSource.screenInputs where !input.name.contains("(") {
            let body = input.type == "float"
                ? "return float3(\(input.name));"
                : (input.type == "float2" ? "return float3(\(input.name), 0.0);"
                                          : "return \(input.name);")
            let problems = compile(body)
            check("\(input.name) is in scope", problems.isEmpty, "\(problems)")
        }

        check("an error reports the user's own line",
              compile("float a = 1.0;\nbroken here;\nreturn sceneColor;", name: "Mono")
                  .contains { $0.contains("Mono:2:") },
              "\(compile("float a = 1.0;\nbroken here;\nreturn sceneColor;", name: "Mono"))")
        check("a screen shader that never returns is caught",
              !compile("float a = 1.0;").isEmpty)
    }

    private static func testPassThrough(_ check: Checker) {
        print("\nScreen shaders: pass-through")
        let colour = SIMD3<Float>(0.8, 0.2, 0.1)
        guard let result = render(body: ShaderObject.screenTemplate, source: colour) else {
            check("the pass renders", false)
            return
        }
        check("the pass renders", true)
        let pixel = result.centre
        check("an untouched picture comes through unchanged",
              near(pixel.x, colour.x) && near(pixel.y, colour.y) && near(pixel.z, colour.z),
              "\(pixel)")
        check("every pixel is the same",
              result.pixels.allSatisfy { near($0.x, colour.x) && near($0.y, colour.y) })
    }

    /// Every slot reaches the GPU with its own value: the Swift and Metal layouts agree.
    private static func testSixteenParameters(_ check: Checker) {
        print("\nScreen shaders: sixteen parameters")
        let parameters = (0..<16).map { ShaderParameter(name: "p\($0)", value: Float($0) / 20) }
        guard let result = render(body: "return float3(p1, p9, p15);", parameters: parameters) else {
            check("the effect renders", false)
            return
        }
        check("the second, tenth and sixteenth parameters arrive as set",
              near(result.centre.x, 0.05) && near(result.centre.y, 0.45) && near(result.centre.z, 0.75),
              "\(result.centre)")
    }

    private static func testBlackAndWhite(_ check: Checker) {
        print("\nScreen shaders: black and white")
        let colour = SIMD3<Float>(0.8, 0.2, 0.1)
        let luma = 0.2126 * colour.x + 0.7152 * colour.y + 0.0722 * colour.z

        guard let full = render(body: ShaderObject.blackAndWhiteExample,
                                parameters: [ShaderParameter(name: "amount", value: 1)],
                                source: colour) else {
            check("the effect renders", false)
            return
        }
        let grey = full.centre
        check("the result is grey", near(grey.x, grey.y) && near(grey.y, grey.z), "\(grey)")
        check("the grey is the Rec. 709 luma", near(grey.x, luma), "\(grey.x) vs \(luma)")
        check("it is not a plain average",
              !near(grey.x, (colour.x + colour.y + colour.z) / 3, 0.01),
              "luma and average should differ for this colour")

        guard let none = render(body: ShaderObject.blackAndWhiteExample,
                                parameters: [ShaderParameter(name: "amount", value: 0)],
                                source: colour) else {
            check("amount 0 renders", false)
            return
        }
        check("amount 0 leaves the picture alone",
              near(none.centre.x, colour.x) && near(none.centre.y, colour.y), "\(none.centre)")

        guard let half = render(body: ShaderObject.blackAndWhiteExample,
                                parameters: [ShaderParameter(name: "amount", value: 0.5)],
                                source: colour) else {
            check("amount 0.5 renders", false)
            return
        }
        check("amount fades between the two",
              near(half.centre.x, (colour.x + luma) / 2), "\(half.centre.x)")
    }

    private static func testUVOrientation(_ check: Checker) {
        print("\nScreen shaders: uv")
        guard let result = render(body: "return float3(uv, 0.0);", size: 8) else {
            check("uv renders", false)
            return
        }
        let topLeft = result.at(0, 0)
        let bottomRight = result.at(7, 7)
        check("uv starts at zero in the top left",
              topLeft.x < 0.2 && topLeft.y < 0.2, "\(topLeft)")
        check("uv reaches one in the bottom right",
              bottomRight.x > 0.8 && bottomRight.y > 0.8, "\(bottomRight)")
        check("u increases to the right", result.at(7, 0).x > result.at(0, 0).x)
        check("v increases downwards", result.at(0, 7).y > result.at(0, 0).y)

        guard let resolution = render(body: "return float3(resolution.x / 100.0, 0.0, 0.0);",
                                      size: 8) else { return }
        check("resolution is the pixel size", near(resolution.centre.x, 0.08, 0.01),
              "\(resolution.centre.x)")
    }

    private static func testDepth(_ check: Checker) {
        print("\nScreen shaders: depth")
        guard let raw = render(body: "return float3(depth);", depth: 0.25) else {
            check("depth renders", false)
            return
        }
        check("the raw depth buffer value is readable", near(raw.centre.x, 0.25), "\(raw.centre.x)")

        // And the linear distance the wrapper derives from it.
        let near0: Float = 0.1
        let far0: Float = 3000
        for probe in [Float(0.25), 0.5, 0.9] {
            let expected = ShaderSource.linearDistance(depth: probe, near: near0, far: far0)
            guard let result = render(body: "return float3(distance / 1000.0);",
                                      depth: Double(probe), near: near0, far: far0) else { continue }
            check("distance at depth \(probe) matches the host's formula",
                  near(result.centre.x * 1000, expected, max(4, expected * 0.05)),
                  "\(result.centre.x * 1000) vs \(expected)")
        }

        check("depth 0 is the near plane",
              near(ShaderSource.linearDistance(depth: 0, near: 0.1, far: 3000), 0.1, 0.001))
        // Right at the far plane the subtraction cancels almost completely in fp32, so
        // the answer is only good to a fraction of a percent. That is the depth buffer
        // being what it is, not the formula being wrong — precision there is spent.
        check("depth 1 is the far plane",
              near(ShaderSource.linearDistance(depth: 1, near: 0.1, far: 3000), 3000, 30),
              "\(ShaderSource.linearDistance(depth: 1, near: 0.1, far: 3000))")
        check("depth is non-linear — halfway is nowhere near halfway",
              ShaderSource.linearDistance(depth: 0.5, near: 0.1, far: 3000) < 1,
              "\(ShaderSource.linearDistance(depth: 0.5, near: 0.1, far: 3000))")
    }

    private static func testNeighbourSampling(_ check: Checker) {
        print("\nScreen shaders: sample")
        let colour = SIMD3<Float>(0.8, 0.2, 0.1)
        guard let result = render(body: "return sample(uv);", source: colour) else {
            check("sample renders", false)
            return
        }
        check("sample(uv) reads the scene",
              near(result.centre.x, colour.x) && near(result.centre.y, colour.y), "\(result.centre)")

        guard let offset = render(body: """
        float2 px = 1.0 / resolution;
        return (sample(uv - float2(px.x, 0.0)) + sample(uv + float2(px.x, 0.0))) * 0.5;
        """, source: colour) else {
            check("neighbour sampling renders", false)
            return
        }
        check("neighbouring pixels can be read",
              near(offset.centre.x, colour.x), "\(offset.centre)")

        // A difference kernel over a flat picture is zero — the classic edge detect.
        guard let edges = render(body: """
        float2 px = 1.0 / resolution;
        return abs(sample(uv + float2(px.x, 0.0)) - sample(uv - float2(px.x, 0.0))) * 4.0;
        """, source: colour) else { return }
        check("an edge detect finds no edges in a flat picture",
              near(edges.at(4, 4).x, 0, 0.03), "\(edges.at(4, 4))")
    }

    private static func testSceneIntegration(_ check: Checker) {
        print("\nScreen shaders: in a scene")
        let model = SceneModel()
        model.loadStarterScene()

        let screens = model.shaders(kind: .screen)
        check("the starter scene ships a screen shader", screens.count == 1, "\(screens.count)")
        check("it is the black and white example", screens.first?.name == "Black & White",
              "\(String(describing: screens.first?.name))")
        check("it ships switched off, so the scene opens in colour",
              model.screenShaderID == nil)
        check("surface shaders are a separate list", model.shaders(kind: .surface).count == 1)

        guard let monochrome = screens.first else { return }
        check("the shipped screen shader compiles",
              compile(monochrome.source, parameters: monochrome.parameters).isEmpty,
              "\(compile(monochrome.source, parameters: monochrome.parameters))")

        model.setScreenShader(monochrome.id)
        check("it can be switched on", model.activeScreenShader?.id == monochrome.id)
        model.undo()
        check("switching it on can be undone", model.screenShaderID == nil)

        model.setScreenShader(monochrome.id)
        do {
            let restored = SceneModel()
            try restored.loadScene(from: model.encodeScene())
            check("the active screen shader round-trips",
                  restored.screenShaderID == monochrome.id,
                  "\(String(describing: restored.screenShaderID))")
            check("its kind round-trips", restored.shader(id: monochrome.id)?.kind == .screen)
        } catch {
            check("scene round-trip", false, "\(error)")
        }

        model.deleteShader(id: monochrome.id)
        check("deleting the active screen shader switches it off", model.screenShaderID == nil)
    }
}
