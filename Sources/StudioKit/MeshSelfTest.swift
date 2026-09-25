import AppKit
import MetalKit
import simd

/// Verification for MeshParts: 3D models (OBJ, STL, PLY) imported into the scene and
/// decoded; MeshParts made, sized, saved and undone; clicked, walked into and simulated
/// by each CollisionFidelity — an arch shows the difference, as its opening is empty to
/// Precise but solid to its Hull; drawn (plain and textured, and ray traced where the GPU
/// can) and read back; from Luau; carried by saved Models; and reaching a joined player.
enum MeshSelfTest {

    static func run(check: Checker) {
        testFiles(check)
        testParts(check)
        testCollision(check)
        testPhysics(check)
        testDrawing(check)
        testLuau(check)
        testModels(check)
        testTwoPlayers(check)
    }

    // MARK: - Files made here

    /// An OBJ of boxes (min and max corners each), with picture coordinates.
    static func obj(_ boxes: [(Vec3, Vec3)]) -> Data {
        var text = "# made by the self-tests\nvt 0 0\nvt 1 0\nvt 1 1\nvt 0 1\n"
        let quads: [[Int]] = [[5, 6, 7, 8], [2, 1, 4, 3], [6, 2, 3, 7], [1, 5, 8, 4], [8, 7, 3, 4], [1, 2, 6, 5]]
        for (index, box) in boxes.enumerated() {
            let (lo, hi) = box
            for corner in [Vec3(lo.x, lo.y, lo.z), Vec3(hi.x, lo.y, lo.z), Vec3(hi.x, hi.y, lo.z), Vec3(lo.x, hi.y, lo.z),
                           Vec3(lo.x, lo.y, hi.z), Vec3(hi.x, lo.y, hi.z), Vec3(hi.x, hi.y, hi.z), Vec3(lo.x, hi.y, hi.z)] {
                text += "v \(corner.x) \(corner.y) \(corner.z)\n"
            }
            let base = index * 8
            for quad in quads {
                let v = quad.map { $0 + base }
                text += "f \(v[0])/1 \(v[1])/2 \(v[2])/3\nf \(v[0])/1 \(v[2])/3 \(v[3])/4\n"
            }
        }
        return Data(text.utf8)
    }

    static var cube: Data { obj([(Vec3(-1, -1, -1), Vec3(1, 1, 1))]) }

    /// Two pillars and a beam: 7 × 5 × 1, an opening 5 wide and 4 high.
    static var arch: Data {
        obj([(Vec3(-3.5, 0, -0.5), Vec3(-2.5, 4, 0.5)), (Vec3(2.5, 0, -0.5), Vec3(3.5, 4, 0.5)),
             (Vec3(-3.5, 4, -0.5), Vec3(3.5, 5, 0.5))])
    }

    /// A cup: a floor and two walls, open at the top — 6 × 4 × 2.
    static var cup: Data {
        obj([(Vec3(-3, 0, -1), Vec3(3, 1, 1)), (Vec3(-3, 1, -1), Vec3(-2, 4, 1)), (Vec3(2, 1, -1), Vec3(3, 4, 1))])
    }

    static var tetrahedronSTL: Data {
        let facets: [[Vec3]] = [
            [Vec3(0, 0, 0), Vec3(0, 1, 0), Vec3(1, 0, 0)], [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 0, 1)],
            [Vec3(0, 0, 0), Vec3(0, 0, 1), Vec3(0, 1, 0)], [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)],
        ]
        var text = "solid tetra\n"
        for facet in facets {
            let n = normalize(cross(facet[1] - facet[0], facet[2] - facet[0]))
            text += "facet normal \(n.x) \(n.y) \(n.z)\n outer loop\n"
            for v in facet { text += "  vertex \(v.x) \(v.y) \(v.z)\n" }
            text += " endloop\nendfacet\n"
        }
        return Data((text + "endsolid tetra\n").utf8)
    }

    static var pyramidPLY: Data {
        Data("""
        ply
        format ascii 1.0
        element vertex 4
        property float x
        property float y
        property float z
        element face 4
        property list uchar int vertex_indices
        end_header
        0 0 0
        1 0 0
        0 1 0
        0 0 2
        3 0 2 1
        3 0 1 3
        3 0 3 2
        3 1 2 3

        """.utf8)
    }

    private static func emptyModel() -> SceneModel {
        let model = SceneModel()
        model.parts = []
        model.scripts = []
        model.shaders = []
        model.groups = []
        model.starterGui = []
        model.assets = []
        model.sounds = []
        return model
    }

    // MARK: - Files

    private static func testFiles(_ check: Checker) {
        print("\nMeshes: 3D files")
        let model = emptyModel()
        let cubeID = try? model.importAsset(data: cube, name: "Cube", fileExtension: "obj")
        let stlID = try? model.importAsset(data: tetrahedronSTL, name: "Tetra", fileExtension: "STL")
        let plyID = try? model.importAsset(data: pyramidPLY, name: "Pyramid", fileExtension: "ply")
        check("OBJ, STL and PLY files come in as 3D models",
              [cubeID, stlID, plyID].allSatisfy { $0.flatMap(model.asset(id:))?.kind == .mesh }
              && model.meshAssets.count == 3)
        let geometry = MeshLibrary.shared.geometry(cubeID)
        check("an OBJ is read: its triangles, its size, its picture coordinates",
              geometry?.triangleCount == 12 && geometry?.nativeSize == Vec3(2, 2, 2) && geometry?.uvs.isEmpty == false
              && geometry?.normals.count == geometry?.positions.count,
              "\(String(describing: geometry?.triangleCount)) \(String(describing: geometry?.nativeSize))")
        check("…squeezed into the unit cube every part shape uses",
              geometry.map { g in g.positions.allSatisfy { simd_reduce_max(simd_abs($0)) <= 0.5001 } } ?? false)
        check("a model with no normals of its own keeps its hard edges (each face its own normal)",
              geometry.map { $0.normals.allSatisfy { simd_reduce_max(simd_abs($0)) > 0.999 } } ?? false)
        let tetra = MeshLibrary.shared.geometry(stlID), pyramid = MeshLibrary.shared.geometry(plyID)
        check("…as are STL and PLY",
              tetra?.triangleCount == 4 && tetra?.nativeSize == Vec3(1, 1, 1)
              && pyramid?.triangleCount == 4 && pyramid?.nativeSize == Vec3(1, 1, 2),
              "\(String(describing: tetra?.nativeSize)) \(String(describing: pyramid?.nativeSize))")
        check("its convex hull is worked out, and its volume",
              geometry.map { $0.hull.triangles.count >= 12 && abs($0.hullVolume - 1) < 0.01 } ?? false,
              "\(String(describing: geometry?.hullVolume))")
        let broken = try? model.importAsset(data: Data("not a model".utf8), name: "Broken", fileExtension: "obj")
        check("a file that isn't really a model can't be used", MeshLibrary.shared.geometry(broken) == nil
              && model.insertMeshPart(broken ?? UUID()) == nil)
    }

    // MARK: - Parts

    private static func testParts(_ check: Checker) {
        print("\nMeshes: MeshParts")
        let model = emptyModel()
        let before = model.undoCount
        guard let archID = try? model.importAsset(data: arch, name: "Arch", fileExtension: "obj"),
              let partID = model.insertMeshPart(archID, at: Vec3(0, 0, 0)),
              let part = model.part(id: partID) else {
            check("a MeshPart is made from a 3D model", false)
            return
        }
        check("a MeshPart is made from a 3D model, at the model's size, standing on the ground, selected",
              part.mesh?.asset == archID && part.mesh?.meshId == "studio://Arch" && part.size == Vec3(7, 5, 1)
              && part.position.y == 2.5 && model.selection == [partID] && part.name == "Arch")
        check("…colliding as its hull unless told otherwise", part.mesh?.collisionFidelity == .hull)
        let steps = model.undoCount
        model.setCollisionFidelity(.precise, of: [partID])
        model.setMeshTexture("studio://Red", of: [partID])
        check("its fidelity and picture change, a step each to undo",
              model.part(id: partID)?.mesh?.collisionFidelity == .precise && model.part(id: partID)?.mesh?.textureId == "studio://Red"
              && model.undoCount == steps + 2)
        model.update(id: partID) { $0.size = Vec3(14, 10, 2) }
        model.resetMeshSize(of: [partID])
        check("Reset Size puts it back to the model's", model.part(id: partID)?.size == Vec3(7, 5, 1))

        let huge = obj([(Vec3(-500, 0, -500), Vec3(500, 10, 500))])
        if let hugeID = try? model.importAsset(data: huge, name: "Huge", fileExtension: "obj"),
           let made = model.insertMeshPart(hugeID) {
            check("one far too big to work with comes in eight studs across, the same shape",
                  model.part(id: made).map { abs($0.size.x - 8) < 0.01 && abs($0.size.y - 0.08) < 0.01 } ?? false,
                  "\(String(describing: model.part(id: made)?.size))")
        }

        let saved = try? JSONEncoder().encode(model.state)
        let reopened = saved.flatMap { try? JSONDecoder().decode(SceneState.self, from: $0) }
        check("MeshParts are saved with the scene, and their models",
              reopened?.parts.first { $0.id == partID }?.mesh == model.part(id: partID)?.mesh
              && reopened?.assets.contains { $0.id == archID } == true)
        let plain = try? JSONDecoder().decode(Part.self, from: Data("{\"name\":\"Old\"}".utf8))
        check("…and a part saved before them is still a plain part", plain != nil && plain?.mesh == nil)
        while model.undoCount > before, model.part(id: partID) != nil { model.undo() }
        check("undo takes a MeshPart away", model.part(id: partID) == nil)
    }

    // MARK: - Collision

    private static func archPart(_ fidelity: CollisionFidelity, model: SceneModel) -> Part? {
        guard let archID = model.meshAssets.first(where: { $0.name == "Arch" })?.id
                ?? (try? model.importAsset(data: arch, name: "Arch", fileExtension: "obj")) else { return nil }
        var part = Part()
        part.name = "Arch"
        part.size = Vec3(7, 5, 1)
        part.position = Vec3(0, 2.5, 0)
        part.mesh = MeshSettings(meshId: "studio://Arch", asset: archID, collisionFidelity: fidelity)
        return part
    }

    private static func testCollision(_ check: Checker) {
        print("\nMeshes: clicking and walking into them")
        let model = emptyModel()
        guard let precise = archPart(.precise, model: model), let hull = archPart(.hull, model: model),
              let box = archPart(.box, model: model) else {
            check("an arch to test with", false)
            return
        }
        let through = Ray(origin: Vec3(0, 2, -10), direction: Vec3(0, 0, 1))
        let pillar = Ray(origin: Vec3(3, 2, -10), direction: Vec3(0, 0, 1))
        check("a click through the arch's opening goes through — whatever it collides as",
              Picking.pick(ray: through, in: [hull]) == nil && Picking.pick(ray: through, in: [box]) == nil)
        check("…and one on a pillar hits it", Picking.pick(ray: pillar, in: [hull]).map { abs($0.distance - 9.5) < 0.01 } ?? false)
        check("rays that stand for collisions meet it as it collides: the opening is solid to its Hull and Box",
              Picking.intersect(ray: through, part: precise) == nil
              && Picking.intersect(ray: through, part: hull).map { abs($0 - 9.5) < 0.01 } == true
              && Picking.intersect(ray: through, part: box).map { abs($0 - 9.5) < 0.01 } == true)

        let inOpening = Capsule(base: Vec3(0, 0.5, 0), radius: 0.5, height: 2)
        check("a character can stand in the opening of a Precise arch",
              Collision.contact(capsule: inOpening, part: precise) == nil)
        let pushedByHull = Collision.contact(capsule: inOpening, part: hull)
        check("…but not of a Hull or Box one, which push it out",
              (pushedByHull?.depth ?? 0) > 0.4 && Collision.contact(capsule: inOpening, part: box) != nil,
              "\(String(describing: pushedByHull))")
        let byPillar = Capsule(base: Vec3(2.2, 0.5, 0), radius: 0.5, height: 2)
        let touch = Collision.contact(capsule: byPillar, part: precise)
        check("against a pillar's side it's pushed straight back out of it, just as far as it went in",
              touch.map { simd_distance($0.normal, Vec3(-1, 0, 0)) < 0.01 && abs($0.depth - 0.2) < 0.01 } ?? false,
              "\(String(describing: touch))")
        let onTop = Capsule(base: Vec3(0, 4.8, 0), radius: 0.5, height: 2)
        check("standing on the beam, the ground under it faces up",
              Collision.contact(capsule: onTop, part: precise).map { $0.normal.y > 0.99 } == true
              && Collision.surfaceNormal(part: precise, worldPoint: Vec3(0, 5, 0)).y > 0.99)
        var turned = precise
        turned.orientation = simd_quatf(angle: .pi / 2, axis: Vec3(0, 1, 0))
        let sideways = Capsule(base: Vec3(0, 0.5, 2.2), radius: 0.5, height: 2)
        check("…turned, the pillars turn with it",
              Collision.contact(capsule: sideways, part: turned).map { simd_distance($0.normal, Vec3(0, 0, -1)) < 0.01 } ?? false)
    }

    // MARK: - Physics

    private static func testPhysics(_ check: Checker) {
        print("\nMeshes: physics")
        let model = emptyModel()
        guard let cupID = try? model.importAsset(data: cup, name: "Cup", fileExtension: "obj"),
              let cubeID = try? model.importAsset(data: cube, name: "Cube", fileExtension: "obj") else {
            check("models to simulate", false)
            return
        }
        func drop(into fidelity: CollisionFidelity) -> Float {
            let world = PhysicsWorld()
            var holder = Part()
            holder.name = "Cup"
            holder.size = Vec3(6, 4, 2)
            holder.position = Vec3(0, 2, 0)
            holder.mesh = MeshSettings(meshId: "studio://Cup", asset: cupID, collisionFidelity: fidelity)
            let ball = PhysicsSelfTest.block(Vec3(0, 8, 0), size: Vec3(1, 1, 1))
            var parts = [holder, ball]
            PhysicsSelfTest.simulate(world, &parts, seconds: 3)
            return parts.first { $0.id == ball.id }?.position.y ?? -1
        }
        let inside = drop(into: .precise), onTop = drop(into: .hull), onBox = drop(into: .box)
        check("a block dropped into an anchored Precise cup lands inside it, on its floor",
              abs(inside - 1.5) < 0.15, "\(inside)")
        check("…into a Hull or Box one, on top of its outline", abs(onTop - 4.5) < 0.15 && abs(onBox - 4.5) < 0.15,
              "\(onTop) \(onBox)")

        let world = PhysicsWorld()
        var falling = Part()
        falling.name = "Crate"
        falling.anchored = false
        falling.size = Vec3(2, 2, 2)
        falling.position = Vec3(0, 6, 0)
        falling.mesh = MeshSettings(meshId: "studio://Cube", asset: cubeID)
        var parts = [falling]
        PhysicsSelfTest.simulate(world, &parts, seconds: 3)
        let block = PhysicsSelfTest.block(.zero, size: Vec3(2, 2, 2))
        check("an unanchored MeshPart falls and rests on the ground, weighing what its outline holds",
              abs((parts.first?.position.y ?? 0) - 1) < 0.1
              && abs(PhysicsWorld.massProperties(of: falling).mass - PhysicsWorld.massProperties(of: block).mass) < 0.05,
              "\(String(describing: parts.first?.position.y))")
    }

    // MARK: - Drawing

    private final class Source: ViewportSource {
        let model: SceneModel
        var renderCamera: Camera
        var avatars: [AvatarPose] = []
        let shaderStatus = ShaderStatusStore()
        let shaderConsole = ScriptConsole()
        var editorOverlay: EditorOverlay? { nil }
        func stepFrame() {}
        init(model: SceneModel, camera: Camera) {
            self.model = model
            self.renderCamera = camera
        }
    }

    /// The scene drawn, and the colour at a world point.
    private static func render(_ model: SceneModel, camera: Camera) -> ((Vec3) -> Vec3, Bool)? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let width = 480, height = 320
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: width, height: height), device: device)
        let source = Source(model: model, camera: camera)
        guard let renderer = Renderer(device: device, view: view, source: source),
              let image = renderer.snapshot(width: width, height: height),
              let data = image.dataProvider?.data as Data? else { return nil }
        let pixels = [UInt8](data)
        withExtendedLifetime(source) {}
        let colour = { (point: Vec3) -> Vec3 in
            let clip = camera.viewProjection(aspect: Float(width) / Float(height)) * Vec4(point, 1)
            let x = Int(((clip.x / clip.w + 1) / 2 * Float(width)).rounded())
            let y = Int(((1 - clip.y / clip.w) / 2 * Float(height)).rounded())
            let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
            return Vec3(Float(pixels[i + 2]), Float(pixels[i + 1]), Float(pixels[i])) / 255
        }
        return (colour, renderer.drewRayTraced)
    }

    private static func testDrawing(_ check: Checker) {
        print("\nMeshes: drawn")
        let model = emptyModel()
        model.showGrid = false
        guard var part = archPart(.precise, model: model),
              let red = try? model.importAsset(data: AudioSelfTest.png(red: 1, green: 0, blue: 0), name: "Red",
                                                fileExtension: "png") else {
            check("a scene to draw", false)
            return
        }
        _ = red
        part.color = Vec3(0.1, 0.9, 0.1)
        part.position = Vec3(0, 3, 0)
        model.parts = [part]
        var camera = Camera()
        camera.target = Vec3(0, 3, 0)
        camera.yaw = -.pi / 2
        camera.pitch = 0.05
        camera.distance = 14
        guard let (plain, _) = render(model, camera: camera) else {
            check("the renderer draws", false)
            return
        }
        let pillar = plain(Vec3(3, 3, -0.5)), opening = plain(Vec3(0, 2.5, 0))
        check("a MeshPart is drawn as its model: the pillar in its colour, the world through its opening",
              pillar.y > 0.2 && pillar.y > pillar.x * 3 && !(opening.y > opening.x * 2),
              "pillar \(pillar), opening \(opening)")
        model.parts[0].mesh?.textureId = "studio://Red"
        model.parts[0].color = Vec3(1, 1, 1)
        if let (textured, _) = render(model, camera: camera) {
            let tinted = textured(Vec3(3, 3, -0.5))
            check("…and with a TextureID, its picture on it", tinted.x > 0.2 && tinted.x > tinted.y * 3 && tinted.x > tinted.z * 3,
                  "\(tinted)")
        }
        model.lighting.technology = .rayTraced
        if let (traced, rayTraced) = render(model, camera: camera), rayTraced {
            let tinted = traced(Vec3(3, 3, -0.5))
            check("…ray traced too", tinted.x > 0.3 && tinted.x > tinted.y * 2, "\(tinted)")
        }
    }

    // MARK: - Luau

    private static func testLuau(_ check: Checker) {
        print("\nMeshes: Luau")
        let model = ScriptSelfTest.scene()
        _ = try? model.importAsset(data: arch, name: "Arch", fileExtension: "obj")
        _ = try? model.importAsset(data: AudioSelfTest.png(red: 1, green: 0, blue: 0), name: "Red", fileExtension: "png")
        ScriptSelfTest.add(model, """
        local arch = Instance.new("MeshPart")
        print("new", arch.ClassName, arch:IsA("MeshPart"), arch:IsA("Part"), arch:IsA("BasePart"), arch.MeshId == "",
        \tarch.MeshSize == Vector3.new(0, 0, 0), arch.CollisionFidelity.Name)
        arch.MeshId = "studio://Arch"
        arch.TextureID = "studio://Red"
        arch.CollisionFidelity = Enum.CollisionFidelity.PreciseConvexDecomposition
        print("set", arch.MeshId, arch.TextureID, arch.CollisionFidelity.Name, arch.MeshSize == Vector3.new(7, 5, 1))
        arch.CollisionFidelity = Enum.CollisionFidelity.Default
        print("default", arch.CollisionFidelity.Name)
        local ok, message = pcall(function() return workspace.Brick.MeshId end)
        print("plain", ok, message:find("not a valid member") ~= nil)
        ok, message = pcall(function() arch.MeshSize = Vector3.new() end)
        print("read only", ok, message:find("read only") ~= nil)
        print("bad", (pcall(function() arch.CollisionFidelity = "Nope" end)))
        local copy = arch:Clone()
        print("clone", copy.ClassName, copy.MeshId, copy.TextureID)
        """)
        let result = ScriptSelfTest.execute(model)
        func line(_ prefix: String) -> String { result.output.first { $0.hasPrefix(prefix + " ") } ?? "(no \(prefix))" }
        check("Instance.new(\"MeshPart\"): a MeshPart, not a Part, with no model yet",
              line("new") == "new MeshPart true false true true true Hull", line("new"))
        check("MeshId, TextureID and CollisionFidelity, and MeshSize from the model",
              line("set") == "set studio://Arch studio://Red PreciseConvexDecomposition true"
              && line("default") == "default Hull", line("set") + " | " + line("default"))
        check("…a plain part has none of them, MeshSize is read only, and the fidelity must be one",
              line("plain") == "plain false true" && line("read only") == "read only false true" && line("bad") == "bad false",
              line("plain") + " | " + line("read only") + " | " + line("bad"))
        check("…and a clone is a MeshPart of the same model", line("clone") == "clone MeshPart studio://Arch studio://Red",
              line("clone"))
        let made = model.parts.first { $0.mesh?.meshId == "studio://Arch" }
        check("…whose model the engine finds", made.flatMap { MeshLibrary.shared.geometry(for: $0) } != nil
              && result.errors.isEmpty, "\(result.errors)")
    }

    // MARK: - Saved Models

    private static func testModels(_ check: Checker) {
        print("\nMeshes: in saved Models")
        let source = emptyModel()
        guard var part = archPart(.precise, model: source),
              let red = try? source.importAsset(data: AudioSelfTest.png(red: 1, green: 0, blue: 0), name: "Red",
                                                 fileExtension: "png") else {
            check("a MeshPart to save", false)
            return
        }
        part.mesh?.textureId = "studio://Red"
        source.parts = [part]
        source.selection = [part.id]
        guard let data = try? SceneDocument(model: source).modelData(name: "Gate"),
              let file = try? JSONDecoder().decode(ModelFile.self, from: data) else {
            check("a Model with a MeshPart saves", false)
            return
        }
        check("a saved Model keeps its MeshParts' models and pictures",
              Set(file.state.assets.map(\.name)) == ["Arch", "Red"])
        let other = emptyModel()
        _ = try? other.importAsset(data: cube, name: "Arch", fileExtension: "obj")   // a different "Arch"
        _ = try? SceneDocument(model: other).insertModel(from: data, at: .zero)
        let inserted = other.parts.first
        let brought = other.assets.first { $0.kind == .mesh && $0.data == arch }
        check("inserted into a place with a different model of that name, it shows its own",
              brought != nil && brought?.name != "Arch" && inserted?.mesh?.asset == brought?.id
              && inserted?.mesh?.meshId == brought?.reference
              && inserted.flatMap { MeshLibrary.shared.geometry(for: $0) }?.nativeSize == Vec3(7, 5, 1)
              && inserted?.mesh?.textureId == "studio://Red" && other.asset(named: "Red") != nil)
        _ = red
    }

    // MARK: - Multiplayer

    private static func testTwoPlayers(_ check: Checker) {
        print("\nMeshes: joined players")
        var archID = UUID()
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            guard var gate = archPart(.precise, model: model),
                  let cubeID = try? model.importAsset(data: cube, name: "Cube", fileExtension: "obj") else { return }
            archID = gate.id
            gate.position = Vec3(0, 2.5, -30)
            model.parts.append(gate)
            _ = cubeID
            var script = ScriptObject.blank(language: .luau)
            script.source = """
            task.wait(0.3)
            local made = Instance.new("MeshPart")
            made.Name = "Made"
            made.MeshId = "studio://Cube"
            made.Anchored = true
            made.Position = Vector3.new(10, 1, 0)
            """
            model.scripts.append(script)
        }), let player = joining.player else {
            check("a host and a player join", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 0.8)
        let gate = player.model.part(id: archID)
        check("a joined player gets the scene's 3D models and MeshParts, and can use them",
              gate.flatMap { MeshLibrary.shared.geometry(for: $0) }?.nativeSize == Vec3(7, 5, 1)
              && gate?.mesh?.collisionFidelity == .precise)
        if let gate {
            let inOpening = Capsule(base: gate.position + Vec3(0, -2, 0), radius: 0.5, height: 2)
            check("…walking through its opening on their own machine",
                  Collision.contact(capsule: inOpening, part: gate) == nil)
        }
        let made = player.model.parts.first { $0.name == "Made" }
        check("a MeshPart a host script makes reaches them with its model",
              made?.mesh?.meshId == "studio://Cube" && made.flatMap { MeshLibrary.shared.geometry(for: $0) } != nil)
        hosting.leaveGame()
        joining.leaveGame()
    }
}
