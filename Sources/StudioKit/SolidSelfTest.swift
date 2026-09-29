import AppKit
import MetalKit
import Network
import simd

enum SolidSelfTest {
    static func box(_ position: Vec3 = .zero, _ size: Vec3 = Vec3(repeating: 2)) -> Part {
        var part = Part(); part.position = position; part.size = size; return part
    }
    static func run(check: Checker) {
        print("\nSolids: boundary geometry")
        let a = box(), b = box(Vec3(1, 0, 0))
        do {
            let mesh = try SolidGeometry.combine(positive: [a, b], negative: [])
            check("overlapping boxes have the volume of their union", abs(mesh.volume - 12) < 0.001, "\(mesh.volume)")
        } catch { check("overlapping boxes have the volume of their union", false, "\(error)") }
        geometryCases(check)
        modelCases(check)
        scriptCases(check)
        drawingCases(check)
        persistenceAndCollision(check)
        retainedObjects(check)
        retainedWorldGui(check)
        multiplayer(check)
    }
    static func geometryCases(_ check: Checker) {
        func volume(_ name: String, _ positives: [Part], _ negatives: [Part] = [], expected: Double, tolerance: Double = 0.001) {
            do {
                let mesh = try SolidGeometry.combine(positive: positives, negative: negatives)
                check(name, abs(mesh.volume - expected) < tolerance, "\(mesh.volume)")
                check(name + " has finite outward triangles", mesh.volume > 0 && mesh.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
            } catch { check(name, false, error.localizedDescription) }
        }
        volume("disjoint boxes keep both shells", [box(), box(Vec3(3, 0, 0))], expected: 16)
        volume("touching boxes lose their interior face", [box(), box(Vec3(2, 0, 0))], expected: 16)
        volume("identical boxes produce one solid", [box(), box()], expected: 8)
        volume("contained boxes add no volume", [box(.zero, Vec3(repeating: 4)), box()], expected: 64)
        volume("a negative box makes a through hole", [box(.zero, Vec3(repeating: 4))], [box(.zero, Vec3(2, 6, 2))], expected: 48)
        volume("nearly coplanar boxes remain finite", [box(), box(Vec3(0.00001, 0, 0))], expected: 8.00004)
        var rotated = box(Vec3(4, 0, 0)); rotated.rotationDegrees = Vec3(20, 35, 10)
        volume("rotated disconnected solids preserve volume", [box(), rotated], expected: 16)
        var crossing = box(); crossing.rotationDegrees = Vec3(0, 0, 45)
        volume("overlapping rotated boxes have the analytic union volume", [box(), crossing], expected: 16 - 16 * (sqrt(2) - 1), tolerance: 0.001)
        var sphere = box(); sphere.shape = .sphere
        volume("a sphere is a closed solid", [sphere], expected: 4 * Double.pi / 3, tolerance: 0.13)
        var cylinder = box(); cylinder.shape = .cylinder
        volume("a cylinder is a closed solid", [cylinder], expected: 2 * Double.pi, tolerance: 0.06)
        volume("a sphere subtracts a closed cavity", [box()], [sphere], expected: 8 - 4 * Double.pi / 3, tolerance: 0.13)
        do {
            _ = try SolidGeometry.combine(positive: [box()], negative: [box()])
            check("empty subtraction is refused", false)
        } catch { check("empty subtraction is refused", true) }
    }
    static func emptyModel() -> SceneModel {
        let model = SceneModel(); model.state = SceneState(); model.clearHistory(); return model
    }
    static func modelCases(_ check: Checker) {
        print("\nSolids: editor transactions and retained sources")
        let model = emptyModel(), a = box(), b = box(Vec3(1, 0, 0))
        model.parts = [a, b]; model.selection = [a.id, b.id]
        let old = model.state, undo = model.undoCount
        do {
            let id = try model.makeUnion([a.id, b.id])
            check("Union replaces operands in one undo step", model.parts.count == 1 && model.part(id: id)?.solid != nil && model.undoCount == undo + 1 && model.selection == [id])
            model.undo(); check("Undo restores union operands", model.state == old)
            model.redo(); check("Redo restores the boundary geometry", model.part(id: id)?.solid?.mesh.indices.isEmpty == false)
            model.update(id: id) { $0.position += Vec3(10, 2, 0); $0.rotationDegrees = Vec3(0, 90, 0); $0.size *= 2 }
            try model.separateSolids([id])
            check("Separate follows the union's move, rotation and scale", model.parts.count == 2 && model.parts.allSatisfy { $0.size == Vec3(repeating: 4) } && simd_distance(model.parts[0].position, Vec3(10.5, 2, 1)) < 0.001)
            model.selection = [model.parts[0].id]; model.negateSelected()
            check("Negate toggles a cutter out of gameplay", model.parts[0].negative && !model.parts[0].inWorld)
            model.negateSelected(); check("Negate again restores a positive part", !model.parts[0].negative)
        } catch { check("Union and Separate are implemented", false, error.localizedDescription) }
        let failed = emptyModel(); failed.parts = [a, b]; failed.parts[1].negative = true; failed.parts[1].position = a.position
        failed.selection = [a.id, b.id]; let before = failed.state, selection = failed.selection
        do { _ = try failed.makeUnion([a.id, b.id]); check("empty operations roll back", false) }
        catch { check("empty operations roll back", failed.state == before && failed.selection == selection && failed.undoCount == 0) }
    }
    static func scriptCases(_ check: Checker) {
        let model = emptyModel(), a = box(), b = box(Vec3(1, 0, 0))
        model.parts = [a, b]; model.parts[0].name = "First"; model.parts[1].name = "Second"
        ScriptSelfTest.add(model, #"""
        local first, second = workspace.First, workspace.Second
        local made = first:UnionAsync({second})
        made.Name = "ScriptUnion"
        print("identity", made.ClassName, made:IsA("PartOperation"), made:IsA("BasePart"), made:IsA("MeshPart"))
        print("sources", first.Parent == workspace, second.Parent == workspace)
        made.UsePartColor = true
        made.CollisionFidelity = Enum.CollisionFidelity.Hull
        print("properties", made.UsePartColor, made.CollisionFidelity.Name)
        local hole = first:SubtractAsync({second})
        print("subtract", hole.ClassName)
        print("bad", (pcall(function() first:UnionAsync({3}) end)), (pcall(function() first:UnionAsync({}) end)))
        """#)
        let result = ScriptSelfTest.execute(model)
        check("Luau exposes UnionOperation and PartOperation identity", result.output.contains("identity UnionOperation true true false"), "\(result.output) \(result.errors)")
        check("UnionAsync keeps its source parts", result.output.contains("sources true true"))
        check("Union properties and SubtractAsync use the same engine", result.output.contains("properties true Hull") && result.output.contains("subtract UnionOperation"))
        check("UnionAsync rejects typed and empty operand lists", result.output.contains("bad false false") && result.errors.isEmpty, "\(result.errors)")
    }

    private final class Source: ViewportSource {
        let model: SceneModel
        var renderCamera: Camera
        var avatars: [AvatarPose] = []
        let shaderStatus = ShaderStatusStore(), shaderConsole = ScriptConsole()
        var editorOverlay: EditorOverlay? { nil }
        func stepFrame() {}
        init(_ model: SceneModel, _ camera: Camera) { self.model = model; renderCamera = camera }
    }
    static func drawingCases(_ check: Checker) {
        let model = emptyModel(); model.showGrid = false
        var a = box(Vec3(-2, 3, 0)), b = box(Vec3(2, 3, 0))
        a.color = Vec3(1, 0.02, 0.02); b.color = Vec3(0.02, 1, 0.02); model.parts = [a, b]
        guard let id = try? model.makeUnion([a.id, b.id]), let device = MTLCreateSystemDefaultDevice() else { check("a union can be rendered", false); return }
        var camera = Camera(); camera.target = Vec3(0, 3, 0); camera.yaw = -.pi / 2; camera.pitch = 0; camera.distance = 14
        let width = 480, height = 320
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: width, height: height), device: device), source = Source(model, camera)
        guard let renderer = Renderer(device: device, view: view, source: source) else { check("a union renderer is made", false); return }
        func color(_ point: Vec3) -> Vec3 {
            guard let snapshot = renderer.snapshot(width: width, height: height), let bytes = snapshot.dataProvider?.data as Data? else { return .zero }
            let clip = camera.viewProjection(aspect: Float(width) / Float(height)) * Vec4(point, 1)
            let x = Int((clip.x / clip.w + 1) / 2 * Float(width)), y = Int((1 - clip.y / clip.w) / 2 * Float(height))
            let index = (y * width + x) * 4, pixels = [UInt8](bytes)
            return Vec3(Float(pixels[index + 2]), Float(pixels[index + 1]), Float(pixels[index])) / 255
        }
        let red = color(a.position), green = color(b.position)
        check("rendered union faces keep their source colors", red.x > red.y * 2 && green.y > green.x * 2, "\(red), \(green)")
        model.update(id: id) { $0.usePartColor = true; $0.color = Vec3(0.02, 0.02, 1) }
        let blue = color(b.position)
        check("UsePartColor overrides the union's source colors", blue.z > blue.x * 2 && blue.z > blue.y * 2, "\(blue)")
        withExtendedLifetime(source) {}
    }

    static func doorway(_ model: SceneModel, at offset: Vec3 = .zero) throws -> Part {
        var wall = box(offset + Vec3(0, 2.5, 0), Vec3(7, 5, 1))
        wall.color = Vec3(0.1, 0.9, 0.1)
        var cutter = box(offset + Vec3(0, 2, 0), Vec3(5, 4, 3)); cutter.negative = true
        model.parts += [wall, cutter]
        let id = try model.makeUnion([wall.id, cutter.id])
        return model.part(id: id)!
    }
    static func persistenceAndCollision(_ check: Checker) {
        print("\nSolids: persistence, nesting and precise collision")
        let model = emptyModel()
        guard let gate = try? doorway(model) else { check("a doorway is cut", false); return }
        let through = Ray(origin: Vec3(0, 2, -10), direction: Vec3(0, 0, 1)), side = Ray(origin: Vec3(3, 2, -10), direction: Vec3(0, 0, 1))
        check("picking goes through a cut doorway and hits its side", Picking.pick(ray: through, in: [gate]) == nil && Picking.pick(ray: side, in: [gate]) != nil)
        check("the character fits the cutout but collides with its side", Collision.contact(capsule: Capsule(base: Vec3(0, 0.1, 0), radius: 0.5, height: 2), part: gate) == nil && Collision.contact(capsule: Capsule(base: Vec3(2.2, 0.1, 0), radius: 0.5, height: 2), part: gate) != nil)
        let blob = try? JSONEncoder().encode(model.state), loaded = blob.flatMap { try? JSONDecoder().decode(SceneState.self, from: $0) }
        check("saving keeps the exact boundary and immediate operands", loaded?.parts.first?.solid == gate.solid)
        let copy = emptyModel(); if let loaded { copy.state = loaded }
        let extra = box(Vec3(10, 2, 0)); copy.parts.append(extra)
        do {
            let nested = try copy.makeUnion([gate.id, extra.id])
            let nestedVolume = copy.part(id: nested).flatMap { try? SolidGeometry.input($0) }?.volume ?? 0
            check("a saved union can be used as another solid operand", abs(nestedVolume - 23) < 0.01, "\(nestedVolume)")
            try copy.separateSolids([nested])
            check("Separate restores a nested union as a still-separable operand", copy.part(id: gate.id)?.solid != nil && copy.parts.count == 2)
        } catch { check("nested unions stay closed", false, error.localizedDescription) }
        model.selection = [gate.id]
        if let data = try? SceneDocument(model: model).modelData(name: "Doorway") {
            let destination = emptyModel()
            _ = try? SceneDocument(model: destination).insertModel(from: data, at: Vec3(20, 2.5, 0))
            _ = try? SceneDocument(model: destination).insertModel(from: data, at: Vec3(40, 2.5, 0))
            let restored = destination.parts.compactMap { $0.solid?.sources.parts.map(\.id) }.flatMap { $0 }
            check("model insertion remaps retained operand IDs too", Set(restored).count == restored.count && restored.count == 4)
            let ids = destination.parts.map(\.id); try? destination.separateSolids(ids)
            check("inserted unions separate at their new positions", destination.parts.count == 4 && destination.parts.allSatisfy { $0.position.x > 15 })
        } else { check("a union exports as a model", false) }
        let invalid = emptyModel()
        let asset = try? invalid.importAsset(data: Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8), name: "Open", fileExtension: "obj")
        var open = box(); open.mesh = MeshSettings(meshId: "studio://Open", asset: asset)
        let other = box(); invalid.parts = [open, other]; invalid.clearHistory(); let before = invalid.state
        do { _ = try invalid.makeUnion([open.id, other.id]); check("open input is refused atomically", false) }
        catch { check("open input is refused atomically", before == invalid.state && invalid.undoCount == 0) }
        let floorModel = emptyModel(), slab = box(Vec3(0, 2, 0), Vec3(6, 1, 6))
        var hole = box(Vec3(0, 2, 0), Vec3(2, 3, 2)); hole.negative = true
        floorModel.parts = [slab, hole]
        if let id = try? floorModel.makeUnion([slab.id, hole.id]), let floor = floorModel.part(id: id) {
            let inside = PhysicsSelfTest.block(Vec3(0, 6, 0), size: Vec3(repeating: 0.8)), outside = PhysicsSelfTest.block(Vec3(2, 6, 0), size: Vec3(repeating: 0.8))
            var parts = [floor, inside, outside]
            PhysicsSelfTest.simulate(PhysicsWorld(), &parts, seconds: 2)
            let y0 = parts.first { $0.id == inside.id }?.position.y ?? -10, y1 = parts.first { $0.id == outside.id }?.position.y ?? -10
            check("Jolt drops through a cutout and rests on the remaining solid", abs(y0 - 0.4) < 0.15 && abs(y1 - 2.9) < 0.15, "\(y0), \(y1)")
        }
        let sheared = emptyModel()
        var tilted = box(); tilted.rotationDegrees = Vec3(0, 0, 45)
        let remote = box(Vec3(8, 0, 0)); sheared.parts = [tilted, remote]
        if let id = try? sheared.makeUnion([tilted.id, remote.id]), let original = sheared.part(id: id) {
            sheared.update(id: id) { $0.size.x *= 2; $0.rotationDegrees = Vec3(0, 30, 0) }
            let transform = sheared.part(id: id)!.modelMatrix * original.modelMatrix.inverse
            let expected = (try? SolidGeometry.input(tilted))?.positions.map { p -> Vec3 in let v = transform * Vec4(p, 1); return Vec3(v.x, v.y, v.z) } ?? []
            try? sheared.separateSolids([id])
            let actual = sheared.part(id: tilted.id).flatMap { try? SolidGeometry.input($0) }?.positions ?? []
            check("Separate preserves nonuniformly scaled rotated operands exactly", !actual.isEmpty && expected.allSatisfy { point in actual.contains { simd_distance(point, $0) < 0.001 } })
        }
        let nestedAffine = emptyModel(); nestedAffine.parts = [tilted, remote]
        if let inner = try? nestedAffine.makeUnion([tilted.id, remote.id]) {
            let third = box(Vec3(0, 9, 0)); nestedAffine.parts.append(third)
            if let outer = try? nestedAffine.makeUnion([inner, third.id]), let start = nestedAffine.part(id: outer) {
                nestedAffine.update(id: outer) { $0.size.x *= 1.7; $0.size.y *= 0.8; $0.rotationDegrees = Vec3(0, 25, 15) }
                let matrix = nestedAffine.part(id: outer)!.modelMatrix * start.modelMatrix.inverse
                let expected = (try? SolidGeometry.input(tilted))?.positions.map { p -> Vec3 in let q = matrix * Vec4(p, 1); return Vec3(q.x, q.y, q.z) } ?? []
                try? nestedAffine.separateSolids([outer])
                if let saved = try? JSONEncoder().encode(nestedAffine.state), let loaded = try? JSONDecoder().decode(SceneState.self, from: saved) { nestedAffine.state = loaded }
                try? nestedAffine.separateSolids([inner])
                let actual = nestedAffine.part(id: tilted.id).flatMap { try? SolidGeometry.input($0) }?.positions ?? []
                check("nested transformed sources survive saving and a second Separate", !actual.isEmpty && expected.allSatisfy { point in actual.contains { simd_distance(point, $0) < 0.001 } })
            }
        }
        let stale = emptyModel(), p = box(), q = box(Vec3(1, 0, 0)); stale.parts = [p, q]; stale.selection = [p.id, q.id]
        stale.unionSelected(); stale.parts[0].position.x += 1
        _ = LANSelfTest.wait { !stale.solidBusy }
        check("background results cannot overwrite edited operands", stale.parts.count == 2 && stale.parts[0].position.x == 1 && stale.undoCount == 0)
    }
    static func multiplayer(_ check: Checker) {
        print("\nSolids: one host world over loopback")
        var gateID = UUID()
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            if let gate = try? doorway(model, at: Vec3(0, 0, -20)) { gateID = gate.id }
            var a = box(Vec3(10, 3, -20)), b = box(Vec3(11, 3, -20)); a.name = "First"; b.name = "Second"
            a.color = Vec3(1, 0, 0); b.color = Vec3(0, 0, 1); model.parts += [a, b]
            ScriptSelfTest.add(model, #"""
            task.wait(0.3)
            local first, second = workspace.First, workspace.Second
            local result = first:UnionAsync({second})
            result.Name = "NetworkUnion"
            first:Destroy()
            second:Destroy()
            """#)
            var localProbe = ScriptObject.blank(language: .luau)
            localProbe.name = "SolidClientProbe"; localProbe.host = .starterPlayer
            localProbe.source = #"""
            task.wait(0.7)
            local result = workspace:WaitForChild("NetworkUnion")
            print("solid-client", result.ClassName, result:IsA("PartOperation"), result.UsePartColor)
            print("solid-server-only", (pcall(function() result:UnionAsync({workspace.Union}) end)))
            """#
            model.scripts.append(localProbe)
        }), let host = hosting.player, let client = joining.player else { check("solid game hosts and joins", false); return }
        defer { hosting.leaveGame(); joining.leaveGame() }
        LANSelfTest.run([hosting, joining], seconds: 1)
        let authored = client.model.part(id: gateID)
        let made = host.model.parts.first { $0.name == "NetworkUnion" }, received = client.model.parts.first { $0.name == "NetworkUnion" }
        check("editor-authored and scripted solid boundaries reach the joined player", authored?.solid != nil && made?.solid == received?.solid && received != nil)
        check("the host's source removals also reach the joined player", client.model.parts.allSatisfy { $0.name != "First" && $0.name != "Second" })
        if let authored {
            let capsule = Capsule(base: Vec3(0, 0.1, -20), radius: 0.5, height: 2)
            check("host and joiner preserve the doorway's collision opening", Collision.contact(capsule: capsule, part: authored) == nil && host.model.part(id: gateID).map { Collision.contact(capsule: capsule, part: $0) == nil } == true)
        }
        for (name, player) in [("host", host), ("joiner", client)] {
            let output = player.console.lines.filter { $0.kind == .output }.map(\.text), errors = player.console.lines.filter { $0.kind == .error }.map(\.text)
            check("\(name) reads the solid API without script errors", output.contains("solid-client UnionOperation true false") && output.contains("solid-server-only false") && errors.isEmpty, "\(output) \(errors)")
        }
        if let received { client.model.selection = [received.id]; check("joined solid source colors are preserved", Set(received.solid!.mesh.colors).count == 2) }
        guard let server = hosting.host, let port = server.port.flatMap(NWEndpoint.Port.init(rawValue:)) else { return }
        let (defaults, suite) = LANSelfTest.freshDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let late = ClientSession(defaults: defaults); late.profile.name = "Later"
        late.join(LANGame(name: server.gameName, txt: LANGame.txt(sceneName: "Solids", players: 1), endpoint: .hostPort(host: LANSelfTest.loopback, port: port)))
        _ = LANSelfTest.wait { late.player != nil }
        check("a late join gets the generated mesh without its original operands", late.player?.model.parts.contains { $0.name == "NetworkUnion" && $0.solid == made?.solid } == true)
        late.leaveGame()
    }

    static func retainedObjects(_ check: Checker) {
        let model = emptyModel(), a = box(), b = box(Vec3(1, 0, 0))
        var child = box(Vec3(0, 4, 0)); child.parentID = a.id
        model.parts = [a, b, child]
        ScriptSelfTest.add(model, "local picture = \"studio://Picture\"", parent: a.id)
        model.sounds = [SceneSound(name: "Chime", parentID: a.id)]
        var reference = DataObject(name: "Reference", className: .objectValue, parent: .node(a.id)); reference.text = "p:" + child.id.uuidString
        model.dataObjects = [reference]
        let originalPNG = AudioSelfTest.png(red: 1, green: 0, blue: 0)
        _ = try? model.importAsset(data: originalPNG, name: "Picture", fileExtension: "png")
        _ = try? model.importAsset(data: AudioSelfTest.png(red: 0, green: 0, blue: 1), name: "Unrelated", fileExtension: "png")
        guard let id = try? model.makeUnion([a.id, b.id]), let union = model.part(id: id) else { check("retained source content is kept", false); return }
        check("union source descendants, scripts and sounds are retained outside the live tree", model.parts.count == 1 && model.scripts.isEmpty && model.sounds.isEmpty && model.dataObjects.isEmpty && union.solid?.sources.parts.count == 3)
        check("unions retain only referenced assets", union.solid?.sources.assets.map(\.name) == ["Picture"])
        model.selection = [id]; model.duplicateSelected(); let cloneID = model.selection.first!
        let copy = model.part(id: cloneID)!
        let originalIDs = Set(union.solid!.sources.parts.map(\.id)), copiedIDs = Set(copy.solid!.sources.parts.map(\.id))
        check("cloning remaps all retained source IDs and ObjectValue references", originalIDs.isDisjoint(with: copiedIDs) && copy.solid!.sources.dataObjects.first.map { object in copiedIDs.contains(UUID(uuidString: String(object.text.dropFirst(2))) ?? UUID()) } == true)
        model.assets = []
        _ = try? model.importAsset(data: AudioSelfTest.png(red: 0, green: 1, blue: 0), name: "Picture", fileExtension: "png")
        try? model.separateSolids([id, cloneID])
        let restored = model.assets.first { $0.data == originalPNG }
        check("Separate restores scripts, descendants, Sounds and data with asset name clashes repaired", model.parts.count == 6 && model.scripts.count == 2 && model.sounds.count == 2 && model.dataObjects.count == 2 && restored?.name != "Picture" && model.scripts.allSatisfy { $0.source.contains(restored?.reference ?? "missing") })
    }

    static func retainedWorldGui(_ check: Checker) {
        let model = emptyModel(), a = box(), b = box(Vec3(1, 0, 0))
        model.parts = [a, b]
        let image = AudioSelfTest.png(red: 0.5, green: 1, blue: 0)
        _ = try? model.importAsset(data: image, name: "SignImage", fileExtension: "png")
        var board = StarterGuiObject(kind: .surfaceGui, name: "RetainedBoard")
        board.worldParent = a.id; board.properties["adornee"] = .string("p:" + a.id.uuidString)
        var picture = StarterGuiObject(kind: .imageLabel, parentID: board.id)
        picture.properties["image"] = .string("studio://SignImage")
        var preview = StarterGuiObject(kind: .viewportFrame, parentID: board.id)
        let camera = PreviewCamera()
        preview.viewportContent = ViewportContent(parts: [box()], cameras: [camera], currentCamera: camera.id)
        model.starterGui = [board, picture, preview]
        var script = ScriptObject.blank(language: .luau)
        script.host = .starterGui; script.parentID = board.id; script.source = "print(script.Parent.Name)"
        model.scripts = [script]
        guard let unionID = try? model.makeUnion([a.id, b.id]), let operation = model.part(id: unionID)?.solid else { return }
        check("Union retains the world GUI subtree, preview and GUI script", operation.sources.starterGui.count == 3 && operation.sources.scripts.count == 1 && model.starterGui.isEmpty && model.scripts.isEmpty)
        check("Union retains assets referenced only by a world GUI", operation.sources.assets.contains { $0.data == image })
        if let data = try? JSONEncoder().encode(model.state), let restored = try? JSONDecoder().decode(SceneState.self, from: data) { model.state = restored }
        model.selection = [unionID]; model.duplicateSelected(); let cloneID = model.selection.first!
        let cloned = model.part(id: cloneID)!.solid!
        let guiIDs = Set(cloned.sources.starterGui.map(\.id))
        check("saved union clones reidentify retained GUI trees and preview cameras", guiIDs.isDisjoint(with: Set(operation.sources.starterGui.map(\.id))) && cloned.sources.starterGui.count == 3 && cloned.sources.scripts.first?.parentID.map(guiIDs.contains) == true && cloned.sources.starterGui.first { $0.kind == .viewportFrame }?.viewportContent?.currentCamera != camera.id)
        model.assets = []
        _ = try? model.importAsset(data: AudioSelfTest.png(red: 1, green: 0, blue: 0), name: "SignImage", fileExtension: "png")
        try? model.separateSolids([unionID, cloneID])
        let boards = model.starterGui.filter { $0.kind == .surfaceGui }
        let references = boards.allSatisfy { board in board.worldParent.flatMap(model.part(id:)) != nil && board.properties["adornee"]?.asString == board.worldParent.map { "p:" + $0.uuidString } }
        let renamed = model.assets.first { $0.data == image }?.reference
        check("Separate restores both world GUI copies with correct parents and asset references", model.starterGui.count == 6 && model.scripts.count == 2 && references && renamed != nil && model.starterGui.filter { $0.kind == .imageLabel }.allSatisfy { $0.properties["image"]?.asString == renamed })
        check("Separate preserves isolated preview geometry", model.parts.count == 4 && model.starterGui.filter { $0.kind == .viewportFrame }.allSatisfy { $0.viewportContent?.parts.count == 1 && $0.viewportContent?.cameras.count == 1 })
    }

}
