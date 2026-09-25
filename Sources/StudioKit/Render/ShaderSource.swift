import Foundation

/// Builds a complete Metal translation unit around the fragment body a user writes.
///
/// The user only ever supplies the inside of a function. Everything that has to agree
/// with the Swift side — uniform layouts, vertex stage, buffer indices — is generated
/// here, so a mistake in a shader can produce a compile error but never a silently
/// mismatched struct or a broken vertex pipeline.
enum ShaderSource {

    static let fragmentFunctionName = "studio_user_fragment"
    static let vertexFunctionName = "studio_user_vertex"
    static let screenFragmentFunctionName = "studio_screen_fragment"
    static let screenVertexFunctionName = "studio_screen_vertex"

    /// Inputs injected into scope, shown in the editor so the learner knows what is there.
    static let inputs: [(name: String, type: String, description: String)] = [
        ("worldPosition", "float3", "this pixel's position in the world"),
        ("normal", "float3", "the surface direction, normalized"),
        ("viewDirection", "float3", "towards the camera, normalized"),
        ("lightDirection", "float3", "towards the light, normalized"),
        ("baseColor", "float3", "the part's own colour"),
        ("cameraPosition", "float3", "where the camera is"),
        ("time", "float", "seconds since the viewport started"),
        ("shadow", "float", "1 in sunlight, 0 in shadow (soft between)"),
        ("lightColor", "float3", "the sun's colour and strength, 1 at default"),
        ("ambientColor", "float3", "sky and ambient light reaching this point")
    ]

    /// Inputs a screen shader gets, shown beside the editor.
    static let screenInputs: [(name: String, type: String, description: String)] = [
        ("sceneColor", "float3", "the rendered pixel"),
        ("uv", "float2", "0–1 across the screen, (0,0) top left"),
        ("resolution", "float2", "the viewport size in pixels"),
        ("time", "float", "seconds since the viewport started"),
        ("depth", "float", "raw depth buffer value, 0 near → 1 far"),
        ("distance", "float", "the same depth in studs from the camera"),
        ("sample(uv)", "float3", "read any other pixel of the scene")
    ]

    static func inputs(for kind: ShaderKind) -> [(name: String, type: String, description: String)] {
        kind == .surface ? inputs : screenInputs
    }

    static func wrap(_ shader: ShaderObject) -> String {
        switch shader.kind {
        case .surface: return wrap(body: shader.source, parameters: shader.parameters)
        case .screen: return wrapScreen(body: shader.source, parameters: shader.parameters)
        }
    }

    /// Named-parameter bindings, shared by both wrappers.
    private static func parameterBindings(_ parameters: [ShaderParameter], structName: String) -> String {
        var bindings = ""
        for (index, parameter) in parameters.prefix(ShaderObject.maximumParameters).enumerated() {
            guard isValidParameterName(parameter.name) else { continue }
            let component = ["x", "y", "z", "w"][index % 4]
            let block = "params\(index / 4)"
            bindings += "    float \(parameter.name) = \(structName).\(block).\(component);\n"
        }
        return bindings
    }

    /// Wraps a body into compilable Metal.
    ///
    /// A `#line 1` directive precedes the body, so the compiler reports errors using
    /// the user's own line numbers and no offset arithmetic is needed.
    static func wrap(body: String, parameters: [ShaderParameter]) -> String {
        let bindings = parameterBindings(parameters, structName: "shaderParams")

        return """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexData {
            float3 position;
            float3 normal;
        };

        struct FrameUniforms {
            float4x4 viewProjection;
            float4 cameraPosition;
            float4 lightDirection;
            float4 timing;
        };

        struct DrawUniforms {
            float4x4 model;
            float3x3 normalMatrix;
            float4 color;
            float4 shading;
        };

        struct ShaderUniforms {
            float4 params0;
            float4 params1;
            float4 params2;
            float4 params3;
        };

        struct RasterData {
            float4 clipPosition [[position]];
            float3 worldPosition;
            float3 normal;
        };

        \(lightingMetalSource)

        vertex RasterData \(vertexFunctionName)(uint vid [[vertex_id]],
                                                device const VertexData *vertices [[buffer(0)]],
                                                constant FrameUniforms &frame [[buffer(1)]],
                                                constant DrawUniforms &draw [[buffer(2)]])
        {
            VertexData v = vertices[vid];
            float4 world = draw.model * float4(v.position, 1.0);
            RasterData out;
            out.clipPosition = frame.viewProjection * world;
            out.worldPosition = world.xyz;
            out.normal = draw.normalMatrix * v.normal;
            return out;
        }

        static float3 studio_user_shade(float3 worldPosition,
                                        float3 normal,
                                        float3 viewDirection,
                                        float3 lightDirection,
                                        float3 baseColor,
                                        float3 cameraPosition,
                                        float time,
                                        float shadow,
                                        float3 lightColor,
                                        float3 ambientColor,
                                        constant ShaderUniforms &shaderParams)
        {
        \(bindings)
        #line 1 "shader"
        \(body)
        }

        fragment float4 \(fragmentFunctionName)(RasterData in [[stage_in]],
                                                constant FrameUniforms &frame [[buffer(1)]],
                                                constant DrawUniforms &draw [[buffer(2)]],
                                                constant ShaderUniforms &shaderParams [[buffer(3)]]
                                                STUDIO_LIGHTING_PARAMS)
        {
            float3 n = normalize(in.normal);
            float3 v = normalize(frame.cameraPosition.xyz - in.worldPosition);
            float3 l = normalize(lighting.sunDirection.xyz);
            float2 pixel = in.clipPosition.xy;
            // The scene's lighting, handed to the shader as plain inputs.
            float shadow = studio_sun_visibility(in.worldPosition, n, pixel, lighting, shadowMap STUDIO_RT_ARGS);
            float occlusion = studio_occlusion(in.worldPosition, n, pixel, lighting STUDIO_RT_ARGS);
            float3 lightColor = lighting.sunColor.rgb / 0.85;
            float3 ambientColor = studio_ambient(n, occlusion, lighting);
            float3 rgb = studio_user_shade(in.worldPosition, n, v, l, draw.color.rgb,
                                           frame.cameraPosition.xyz, frame.timing.x,
                                           shadow, lightColor, ambientColor, shaderParams);
            // Point lights, fog and exposure apply to every part, shaded or not.
            rgb += studio_point_lights(in.worldPosition, n, v, draw.color.rgb, 0.3, 24.0,
                                       lighting, pointLights STUDIO_RT_ARGS);
            rgb = studio_finish(rgb, in.worldPosition, frame.cameraPosition.xyz, lighting);
            return float4(rgb, draw.color.a);
        }
        """
    }

    /// Wraps a screen-shader body: one full-screen triangle over the finished picture.
    ///
    /// The scene has already been drawn into a texture, so the body is handed the
    /// pixel it is standing on plus everything needed to look around — neighbouring
    /// pixels through `sample`, and how far away the surface is through `depth` and
    /// `distance`. Depth is read straight out of the multisample buffer rather than
    /// resolved, which avoids depending on multisample depth-resolve support.
    static func wrapScreen(body: String, parameters: [ShaderParameter]) -> String {
        let bindings = parameterBindings(parameters, structName: "screenParams")

        return """
        #include <metal_stdlib>
        using namespace metal;

        struct ScreenUniforms {
            float4 resolution;   // xy: pixels, zw: 1 / pixels
            float4 timing;       // x: seconds
            float4 planes;       // x: near, y: far
            float4 params0;
            float4 params1;
            float4 params2;
            float4 params3;
        };

        struct ScreenVertex {
            float4 position [[position]];
            float2 uv;
        };

        // One oversized triangle covering the screen — no vertex buffer needed.
        vertex ScreenVertex \(screenVertexFunctionName)(uint vid [[vertex_id]])
        {
            float2 uv = float2((vid << 1) & 2, vid & 2);
            ScreenVertex out;
            out.uv = uv;
            out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
            return out;
        }

        static float3 studio_screen_shade(float3 sceneColor,
                                          float2 uv,
                                          float2 resolution,
                                          float time,
                                          float depth,
                                          float distance,
                                          texture2d<float> sceneTexture,
                                          sampler sceneSampler,
                                          constant ScreenUniforms &screenParams)
        {
            // Read any other pixel of the scene, for blurs and edge detection: sample(uv).
            // A macro, not a lambda — Metal has no lambdas, and newer compilers say so.
            #define sample(coord) (sceneTexture.sample(sceneSampler, (coord)).rgb)

        \(bindings)
        #line 1 "shader"
        \(body)
        #undef sample
        }

        fragment float4 \(screenFragmentFunctionName)(ScreenVertex in [[stage_in]],
                                                      constant ScreenUniforms &screenParams [[buffer(0)]],
                                                      texture2d<float> sceneTexture [[texture(0)]],
                                                      depth2d_ms<float> depthTexture [[texture(1)]])
        {
            constexpr sampler sceneSampler(filter::linear, address::clamp_to_edge);
            float3 sceneColor = sceneTexture.sample(sceneSampler, in.uv).rgb;

            float depth = depthTexture.read(uint2(in.position.xy), 0);

            // The depth buffer is far from linear — almost all of its precision sits
            // in the first few studs — so hand the shader the real distance too.
            float nearPlane = screenParams.planes.x;
            float farPlane = screenParams.planes.y;
            float denominator = farPlane + depth * (nearPlane - farPlane);
            float distance = nearPlane * farPlane / max(denominator, 1e-5);

            float3 rgb = studio_screen_shade(sceneColor, in.uv, screenParams.resolution.xy,
                                             screenParams.timing.x, depth, distance,
                                             sceneTexture, sceneSampler, screenParams);
            return float4(rgb, 1.0);
        }
        """
    }

    /// Distance in studs for a raw depth value, matching what the shader computes.
    static func linearDistance(depth: Float, near: Float, far: Float) -> Float {
        near * far / max(far + depth * (near - far), 1e-5)
    }

    /// Problems worth reporting before the compiler is even invoked.
    ///
    /// Falling off the end of a `float3` function is not an error in C++, just a
    /// warning the Metal compiler does not hand back — so the pixel colour would be
    /// undefined and the shader would appear to "work". Catching it here turns a
    /// baffling result into a plain sentence.
    static func validate(body: String) -> [String] {
        let code = MetalSyntax.codeOnly(body).trimmingCharacters(in: .whitespacesAndNewlines)
        if code.isEmpty {
            return ["this shader is empty — it needs to return a float3 colour, e.g. `return baseColor;`"]
        }
        let returnsSomething = MetalSyntax.tokenize(body).contains { token in
            token.kind == .keyword
                && (body as NSString).substring(with: token.range) == "return"
        }
        if !returnsSomething {
            return ["this shader never returns a colour — end it with something like `return baseColor;`"]
        }
        return []
    }

    /// Parameter names are pasted into generated Metal, so they have to be identifiers.
    static func isValidParameterName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        return !reservedNames.contains(name)
    }

    private static let reservedNames: Set<String> = [
        "float", "float2", "float3", "float4", "half", "int", "uint", "bool", "void",
        "time", "normal", "baseColor", "worldPosition", "viewDirection", "lightDirection",
        "cameraPosition", "in", "out", "return", "if", "else", "for", "while", "const",
        "struct", "using", "namespace", "constant", "device", "fragment", "vertex"
    ]

    /// Rewrites the Metal compiler's diagnostics to name the shader the user is editing.
    ///
    /// Clang reports against `program_source`; the `#line` directive already makes the
    /// numbers match the user's text, so only the filename needs replacing.
    static func readableDiagnostics(_ message: String, shaderName: String) -> [String] {
        message
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { !$0.hasPrefix("Compilation failed") }
            .map { line in
                var line = line
                for prefix in ["program_source:", "shader:"] {
                    if let range = line.range(of: prefix) {
                        line.replaceSubrange(range, with: "\(shaderName):")
                    }
                }
                return line
            }
    }
}
