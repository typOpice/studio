import AppKit
import Foundation
import Metal
import simd

/// Terrain: the voxels (filling balls, blocks, cylinders, wedges and regions, carving with
/// Air, replacing, the brushes, Generate), saved small; the meshes (a flat ground at its
/// height, whole across chunks, water at its level, only what changed made again);
/// played on (stood on, swum in, no floor at 0, a block landing on it, a raycast hitting
/// it, a path over it); scripts (workspace.Terrain and all it does, Region3, the water,
/// wrong values refused); drawn; painted in Studio; and a host's reaching a joined player.
enum TerrainSelfTest {
    static func run(check: Checker) {
        testVoxels(check)
        testMeshes(check)
        testPlay(check)
        testScripts(check)
        testDrawing(check)
        testStudio(check)
        testTemplate(check)
        testReadme(check)
        testTogether(check)
    }

    // MARK: - The README

    private static func testReadme(_ check: Checker) {
        print("\nTerrain: the README's example")
        guard let readme = try? String(contentsOfFile: "README.md", encoding: .utf8),
              let start = readme.range(of: "## Terrain\n"),
              let block = readme[start.upperBound...].components(separatedBy: "```lua\n").dropFirst().first?
                .components(separatedBy: "```").first else {
            print("  (README.md not found from here; skipped)")
            return
        }
        let model = SceneModel()
        model.parts = []
        var script = ScriptObject.blank(language: .luau)
        script.source = block
        model.scripts = [script]
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        session.step(dt: frame)
        let t = model.terrain
        func at(_ x: Float, _ y: Float, _ z: Float) -> TerrainMaterial { t.material(TerrainData.voxel(at: Vec3(x, y, z))) }
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("as written: sand under a lake, a grass island, a tunnel through it",
              at(80, -10, 80) == .sand && at(80, -2, 80) == .water && at(0, 18, 0) == .grass && at(0, 4, 0) == .air
              && at(20, 4, 0) == .air && at(0, 4, 20) == .grass && errors.isEmpty, "\(errors)")
        session.stop()
    }

    // MARK: - Hills and Lake

    private static func testTemplate(_ check: Checker) {
        print("\nTerrain: the Hills and Lake template")
        let model = SceneModel()
        model.loadTemplate(.terrain)
        check("hills, a river and lakes, and clouds", model.terrain.chunks.count > 50 && model.lighting.clouds != nil
              && model.terrain.chunks.values.contains { $0.materials.contains(TerrainMaterial.water.rawValue) })
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        let start = session.character.position
        var t: Float = 0
        while t < 2 { session.step(dt: frame); t += frame }
        let ground = model.terrainParts.compactMap { part -> Float? in
            let ray = Ray(origin: Vec3(0, 400, 18), direction: Vec3(0, -1, 0))
            return Picking.intersect(ray: ray, part: part, exact: true).map { 400 - $0 }
        }.max() ?? -999
        check("a player starts on the land and stays on it", abs(start.y - (ground + 0.5)) < 0.1
              && abs(session.character.position.y - ground) < 2 || session.character.swimming,
              "\(start) → \(session.character.position), ground \(ground)")
        session.stop()
    }

    private static let frame: Float = 1.0 / 60

    /// A flat ground: `size` studs across, its top at `top`.
    private static func ground(_ size: Float = 128, top: Float = 0, material: TerrainMaterial = .grass) -> TerrainData {
        var terrain = TerrainData()
        terrain.fillBlock(pose: Pose(position: Vec3(0, top - 8, 0), orientation: simd_quatf(angle: 0, axis: Vec3(0, 1, 0))),
                          size: Vec3(size, 16, size), material: material)
        return terrain
    }

    private static let upright = simd_quatf(angle: 0, axis: Vec3(0, 1, 0))

    // MARK: - Voxels

    private static func testVoxels(_ check: Checker) {
        print("\nTerrain: voxels")
        var t = TerrainData()
        t.fillBall(centre: Vec3(0, 20, 0), radius: 10, material: .rock)
        let middle = TerrainData.voxel(at: Vec3(0, 20, 0))
        let edge = TerrainData.voxel(at: Vec3(9, 20, 0)), outside = TerrainData.voxel(at: Vec3(16, 20, 0))
        check("FillBall: full in the middle, part-full at the edge, empty outside",
              t.material(middle) == .rock && t.occupancy(middle) == 1 && t.occupancy(edge) > 0 && t.occupancy(edge) < 1
              && t.occupancy(outside) == 0 && t.material(outside) == .air, "\(t.occupancy(edge))")
        t.fillBall(centre: Vec3(0, 20, 0), radius: 4, material: .air)
        // (Voxel middles are 2 studs off whole coordinates: the one there is mostly emptied.)
        check("…Air carves a hole", t.occupancy(middle) < 0.5 && t.occupancy(TerrainData.voxel(at: Vec3(0, 26, 0))) > 0.9,
              "\(t.occupancy(middle))")
        t.fillBlock(pose: Pose(position: Vec3(100, 4, 0), orientation: simd_quatf(angle: .pi / 4, axis: Vec3(0, 1, 0))),
                    size: Vec3(16, 8, 4), material: .sand)
        // Along its length (turned 45°, its X runs out to the east and north).
        check("FillBlock, turned", t.material(TerrainData.voxel(at: Vec3(103.5, 4, -3.5))) == .sand
              && t.material(TerrainData.voxel(at: Vec3(108, 4, -8))) == .air)
        t.fillCylinder(pose: Pose(position: Vec3(-100, 10, 0), orientation: upright), height: 20, radius: 6, material: .basalt)
        check("FillCylinder", t.material(TerrainData.voxel(at: Vec3(-100, 18, 0))) == .basalt
              && t.material(TerrainData.voxel(at: Vec3(-100, 26, 0))) == .air && t.material(TerrainData.voxel(at: Vec3(-92, 10, 0))) == .air)
        t.fillWedge(pose: Pose(position: Vec3(0, 10, 100), orientation: upright), size: Vec3(16, 16, 32), material: .slate)
        check("FillWedge: high at the front, low at the back",
              t.material(TerrainData.voxel(at: Vec3(0, 14, 88))) == .slate && t.material(TerrainData.voxel(at: Vec3(0, 14, 112))) == .air
              && t.material(TerrainData.voxel(at: Vec3(0, 6, 100))) == .slate)
        t.fillRegion(low: Vec3(200, 0, 0), high: Vec3(208, 8, 8), material: .snow)
        let region = (0..<2).flatMap { x in (0..<2).map { y in TerrainData.voxel(at: Vec3(202 + Float(x) * 4, 2 + Float(y) * 4, 2)) } }
        check("FillRegion: every voxel in it, full", region.allSatisfy { t.material($0) == .snow && t.occupancy($0) == 1 }
              && t.material(TerrainData.voxel(at: Vec3(210, 2, 2))) == .air)
        t.replace(low: Vec3(200, 0, 0), high: Vec3(204, 8, 8), .snow, with: .ice)
        check("ReplaceMaterial: only in its region", t.material(region[0]) == .ice && t.material(region[2]) == .snow)

        // Brushes on a flat ground.
        var b = ground()
        let top = TerrainData.voxel(at: Vec3(0, 2, 0))
        b.brush(.add, centre: Vec3(0, 0, 0), radius: 8, strength: 1, material: .rock)
        check("Brush Add: a ball of the material", b.material(top) == .rock && b.occupancy(top) == 1)
        b.brush(.subtract, centre: Vec3(0, 0, 0), radius: 8, strength: 1, material: .rock)
        check("Brush Subtract: dug out", b.occupancy(top) == 0 && b.occupancy(TerrainData.voxel(at: Vec3(0, -2, 0))) == 0)
        var bumpy = ground()
        bumpy.fillBall(centre: Vec3(0, 0, 0), radius: 6, material: .grass)
        let peak = TerrainData.voxel(at: Vec3(0, 4, 0))
        let before = bumpy.occupancy(peak)
        for _ in 0..<5 { bumpy.brush(.smooth, centre: Vec3(0, 2, 0), radius: 12, strength: 1, material: .grass) }
        check("Brush Smooth: a bump worn down", bumpy.occupancy(peak) < before - 0.1, "\(before) → \(bumpy.occupancy(peak))")
        var level = ground()
        level.brush(.flatten, centre: Vec3(0, 8, 0), radius: 10, strength: 1, material: .grass)
        check("Brush Flatten: built up to the brush's height",
              level.occupancy(TerrainData.voxel(at: Vec3(0, 6, 0))) > 0.6 && level.material(TerrainData.voxel(at: Vec3(0, 6, 0))) == .grass)
        var grown = ground()
        grown.brush(.grow, centre: Vec3(0, 0, 0), radius: 8, strength: 1, material: .mud)
        grown.brush(.erode, centre: Vec3(40, 0, 0), radius: 8, strength: 1, material: .mud)
        check("Brush Grow and Erode: up and down a little",
              grown.occupancy(TerrainData.voxel(at: Vec3(0, 2, 0))) > 0.2 && grown.material(TerrainData.voxel(at: Vec3(0, 2, 0))) == .grass
              && grown.occupancy(TerrainData.voxel(at: Vec3(40, -2, 0))) < 1)
        var painted = ground()
        painted.brush(.paint, centre: Vec3(0, 0, 0), radius: 8, strength: 1, material: .sand)
        check("Brush Paint: the surface changes material, not shape",
              painted.material(TerrainData.voxel(at: Vec3(0, -2, 0))) == .sand && painted.occupancy(TerrainData.voxel(at: Vec3(0, -2, 0))) == 1
              && painted.material(TerrainData.voxel(at: Vec3(30, -2, 0))) == .grass)

        // Generate.
        var land = TerrainData()
        land.generate(centre: Vec3(0, -8, 0), size: 256, height: 60, waterLevel: 6, seed: 3)
        var materials = Set<TerrainMaterial>()
        for chunk in land.chunks.values { for m in chunk.materials { if let t = TerrainMaterial(rawValue: m) { materials.insert(t) } } }
        check("Generate: hills of grass and rock, sand by water, the same from the same seed",
              materials.isSuperset(of: [.grass, .sand, .water]) && land.chunks.count > 8, "\(materials)")
        var again = TerrainData()
        again.generate(centre: Vec3(0, -8, 0), size: 256, height: 60, waterLevel: 6, seed: 3)
        check("…the same from the same seed", again.chunks.keys.sorted { "\($0)" < "\($1)" }.allSatisfy {
            again.chunks[$0]!.materials == land.chunks[$0]!.materials && again.chunks[$0]!.occupancy == land.chunks[$0]!.occupancy
        })

        // Saved small, and read back the same.
        let flat = ground(256)
        let data = (try? JSONEncoder().encode(flat)) ?? Data()
        let back = (try? JSONDecoder().decode(TerrainData.self, from: data)) ?? TerrainData()
        // A chunk's voxels are 8 KB as they are.
        check("saved: flat ground takes little room (\(data.count) bytes for \(flat.chunks.count) chunks), and reads back the same",
              data.count < flat.chunks.count * 400 && back.chunks.count == flat.chunks.count
              && back.chunks.allSatisfy { flat.chunks[$0.key]?.materials == $0.value.materials && flat.chunks[$0.key]?.occupancy == $0.value.occupancy })
        let empty = SceneModel()
        let plain = (try? empty.encodeScene()).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check("…and a place without terrain saves as it always did", !plain.contains("\"terrain\""))
    }

    // MARK: - Meshes

    private static func testMeshes(_ check: Checker) {
        print("\nTerrain: meshes")
        let flat = ground(128, top: 0)
        let geometry = TerrainGeometry()
        geometry.update(flat)
        var tops: [Vec3] = [], area: Float = 0
        for entry in geometry.entries.values {
            let mesh = entry.mesh
            for t in stride(from: 0, to: mesh.indices.count, by: 3) {
                let a = mesh.positions[Int(mesh.indices[t])], b = mesh.positions[Int(mesh.indices[t + 1])]
                let c = mesh.positions[Int(mesh.indices[t + 2])]
                let normal = simd_cross(b - a, c - a)
                guard normal.y > 0, abs(a.y) < 1, abs(b.y) < 1, abs(c.y) < 1 else { continue }
                area += simd_length(normal) / 2
                tops += [a, b, c]
            }
        }
        // The top is flat but for its outer ring (sloping down to the sides): 120 × 120.
        check("a flat ground's top: level at its height, facing up", !tops.isEmpty && tops.allSatisfy { abs($0.y) < 0.01 })
        check("…whole across the chunks it spans (no holes at their edges)", abs(area - 120 * 120) < 120 * 120 * 0.02,
              "\(area)")
        let collision = geometry.parts
        check("…and collision parts for it, with Precise triangles", !collision.isEmpty
              && collision.allSatisfy { $0.mesh?.collisionFidelity == .precise && MeshLibrary.shared.geometry(for: $0) != nil })

        var wet = ground(128, top: -8)
        wet.fillBlock(pose: Pose(position: Vec3(0, -4, 0), orientation: upright), size: Vec3(64, 8, 64), material: .water)
        let pool = TerrainGeometry()
        pool.update(wet)
        let surface = pool.entries.values.flatMap { $0.mesh.water.positions }.filter { abs($0.x) < 30 && abs($0.z) < 30 }
        check("water: its surface at its level", !surface.isEmpty && surface.allSatisfy { abs($0.y - 0) < 0.01 || $0.y < 0 },
              "\(surface.map(\.y).max() ?? -99)")
        check("…where a point in it is, its surface", abs((wet.waterSurface(at: Vec3(0, -3, 0)) ?? -99) - 0) < 0.01
              && wet.waterSurface(at: Vec3(100, 2, 0)) == nil)

        // Only what changed is made again.
        var edited = ground(512, top: 0)
        let cache = TerrainGeometry()
        cache.update(edited)
        let signatures = cache.entries.mapValues(\.signature)
        edited.fillBall(centre: Vec3(32, -32, 32), radius: 4, material: .rock)   // well inside one chunk
        cache.update(edited)
        let remade = cache.entries.filter { signatures[$0.key] != $0.value.signature }.count
        check("an edit in the middle of a chunk makes only that chunk again", remade == 1, "\(remade) of \(signatures.count)")
        edited.fillBall(centre: Vec3(64, 0, 64), radius: 3, material: .rock)   // where chunks meet
        let before = cache.entries.mapValues(\.signature)
        cache.update(edited)
        let atCorner = cache.entries.filter { before[$0.key] != $0.value.signature }.count
        check("…at a corner, the chunks round it too", atCorner > 1, "\(atCorner)")
    }

    // MARK: - Play

    private static func testPlay(_ check: Checker) {
        print("\nTerrain: played on")
        let model = SceneModel()
        model.parts = []
        model.groups = []
        var land = ground(256, top: 0)
        // A hill; a pond dug 12 deep into the 16-deep ground, water in it up to 4 below 0.
        land.fillBall(centre: Vec3(60, -10, 0), radius: 30, material: .grass)
        land.fillBlock(pose: Pose(position: Vec3(-60, -6, 0), orientation: upright), size: Vec3(40, 12, 40), material: .air)
        land.fillBlock(pose: Pose(position: Vec3(-60, -8, 0), orientation: upright), size: Vec3(40, 8, 40), material: .water)
        model.terrain = land
        var crate = Part()
        crate.name = "Crate"
        crate.position = Vec3(0, 20, 60)
        crate.size = Vec3(4, 4, 4)
        crate.anchored = false
        model.parts = [crate]
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        func settle(_ at: Vec3, seconds: Float = 1.5) {
            session.character.position = at
            session.character.velocity = .zero
            var t: Float = 0
            while t < seconds { session.step(dt: frame); t += frame }
        }
        settle(Vec3(0, 10, 0))
        check("a character stands on flat terrain", abs(session.character.position.y) < 0.3, "\(session.character.position)")
        settle(Vec3(60, 40, 0))
        check("…and on top of a hill", session.character.position.y > 15, "\(session.character.position)")
        settle(Vec3(-60, 5, 0), seconds: 2)
        check("…swims in its water, and there's no floor at 0 to stand on in it",
              session.character.swimming && session.character.position.y < 0, "\(session.character.position)")
        check("a block dropped on it lands on it", abs(model.parts.first!.position.y - 2) < 0.3, "\(model.parts.first!.position)")
        session.stop()

        // Raycasts, from a script, and a path over the hill.
        let scripted = SceneModel()
        scripted.parts = []
        scripted.groups = []
        scripted.terrain = land
        var flag = Part()
        flag.name = "Flag"
        flag.position = Vec3(100, 2, 0)
        flag.size = Vec3(1, 4, 1)
        flag.canCollide = false
        scripted.parts = [flag]
        var script = ScriptObject.blank(language: .luau)
        script.source = """
        local hit = workspace:Raycast(Vector3.new(10, 50, 10), Vector3.new(0, -100, 0))
        print("ground", hit.Instance == workspace.Terrain, string.format("%.1f", hit.Position.Y), hit.Material.Name,
        \tstring.format("%.2f", hit.Normal.Y))
        local wet = workspace:Raycast(Vector3.new(-60, 50, 0), Vector3.new(0, -100, 0))
        print("water", wet.Material.Name, string.format("%.1f", wet.Position.Y), wet.Normal.Y)
        local params = RaycastParams.new()
        params.IgnoreWater = true
        local bed = workspace:Raycast(Vector3.new(-60, 50, 0), Vector3.new(0, -100, 0), params)
        print("bed", bed.Material.Name, bed.Position.Y < -10)
        params.FilterDescendantsInstances = { workspace.Terrain }
        print("through", workspace:Raycast(Vector3.new(10, 50, 10), Vector3.new(0, -100, 0), params) == nil)
        local path = game:GetService("PathfindingService"):CreatePath()
        path:ComputeAsync(Vector3.new(0, 3, 0), workspace.Flag.Position)
        -- Round the hill (too steep to climb), not through where it stands.
        local around = true
        for _, point in path:GetWaypoints() do
        \tif Vector3.new(point.Position.X - 60, 0, point.Position.Z).Magnitude < 20 then around = false end
        end
        print("path", path.Status.Name, around, #path:GetWaypoints() > 2)
        """
        scripted.scripts = [script]
        let run = PlayController(model: scripted, console: ScriptConsole())
        run.start()
        for _ in 0..<5 { run.step(dt: frame) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        func said(_ prefix: String) -> String {
            run.console.lines.last { $0.kind == .output && $0.text.hasPrefix(prefix) }?.text ?? "(nothing)"
        }
        check("Raycast: hits the terrain, as workspace.Terrain, with its material and the ground's normal",
              said("ground") == "ground true 0.0 Grass 1.00", said("ground"))
        check("…hits its water (its surface, 4 below 0), unless IgnoreWater", said("water") == "water Water -4.0 1"
              && said("bed") == "bed Grass true",
              "\(said("water")) \(said("bed"))")
        check("…and passes through it when filtered out", said("through") == "through true", said("through"))
        check("PathfindingService: a path round the hill, the terrain in its way", said("path") == "path Success true true",
              said("path"))
        let errors = run.console.lines.filter { $0.kind == .error }.map(\.text)
        check("…with no errors", errors.isEmpty, "\(errors)")
        run.stop()
    }

    // MARK: - Scripts

    static let scriptSource = """
    local Terrain = workspace.Terrain
    print("terrain", Terrain.ClassName, Terrain.Name, Terrain.Parent == workspace, Terrain:IsA("Terrain"),
    \tworkspace:FindFirstChild("Terrain") == Terrain, workspace:FindFirstChildOfClass("Terrain") == Terrain)
    Terrain:FillBlock(CFrame.new(0, -4, 0), Vector3.new(64, 8, 64), Enum.Material.Grass)
    Terrain:FillBall(Vector3.new(20, 0, 0), 6, Enum.Material.Rock)
    Terrain:FillCylinder(CFrame.new(-20, 8, 0), 16, 3, Enum.Material.Basalt)
    Terrain:FillWedge(CFrame.new(0, 4, 20), Vector3.new(8, 8, 8), Enum.Material.Sand)
    local region = Region3.new(Vector3.new(-8, -8, -8), Vector3.new(8, 0, 8))
    print("region", region.Size, region.CFrame.Position)
    Terrain:ReplaceMaterial(region, 4, Enum.Material.Grass, Enum.Material.Mud)
    Terrain:FillRegion(Region3.new(Vector3.new(-32, 0, -32), Vector3.new(-24, 8, -24)), 4, Enum.Material.Snow)
    local materials, occupancies = Terrain:ReadVoxels(Region3.new(Vector3.new(-4, -4, -4), Vector3.new(4, 0, 4)), 4)
    print("read", materials.Size, materials[1][1][1].Name, occupancies[1][1][1])
    materials[1][1][1] = Enum.Material.Ice
    Terrain:WriteVoxels(Region3.new(Vector3.new(-4, -4, -4), Vector3.new(4, 0, 4)), 4, materials, occupancies)
    local after = Terrain:ReadVoxels(Region3.new(Vector3.new(-4, -4, -4), Vector3.new(0, 0, 0)), 4)
    print("wrote", after[1][1][1].Name)
    Terrain:SetMaterialColor(Enum.Material.Grass, Color3.new(0.1, 0.8, 0.2))
    print("colour", string.format("%.1f", Terrain:GetMaterialColor(Enum.Material.Grass).G))
    Terrain.WaterColor = Color3.new(0.1, 0.2, 0.9)
    Terrain.WaterTransparency = 0.6
    print("water", string.format("%.1f %.1f", Terrain.WaterColor.B, Terrain.WaterTransparency))
    print("cell", Terrain:WorldToCell(Vector3.new(5, -3, 9)), Terrain:CellCenterToWorld(1, -1, 2))
    local clouds = Instance.new("Clouds", Terrain)
    print("clouds", clouds.Parent == Terrain, Terrain.Clouds == clouds)
    local ok1 = pcall(function() Terrain:FillBall(Vector3.zero, 4, Enum.Material.Plastic) end)
    local ok2 = pcall(function() Terrain:FillRegion(region, 8, Enum.Material.Grass) end)
    local ok3 = pcall(function() Terrain:FillBlock(Vector3.zero, Vector3.one, Enum.Material.Grass) end)
    local ok4 = pcall(function() Terrain.WaterColor = 5 end)
    local ok5 = pcall(function() workspace.Baseplate.Material = Enum.Material.Grass end)
    print("refused", ok1, ok2, ok3, ok4, ok5)
    """

    private static func testScripts(_ check: Checker) {
        print("\nTerrain: from scripts")
        let model = SceneModel()
        model.parts = []
        model.groups = []
        var base = Part()
        base.name = "Baseplate"
        base.position = Vec3(0, -40, 0)
        model.parts = [base]
        var script = ScriptObject.blank(language: .luau)
        script.source = scriptSource
        model.scripts = [script]
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        for _ in 0..<3 { session.step(dt: frame) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        func said(_ prefix: String) -> String {
            session.console.lines.last { $0.kind == .output && $0.text.hasPrefix(prefix) }?.text ?? "(nothing)"
        }
        let t = model.terrain
        check("workspace.Terrain: itself, in the Workspace, found by name and class",
              said("terrain") == "terrain Terrain Terrain true true true true", said("terrain"))
        check("FillBlock, FillBall, FillCylinder, FillWedge", t.material(TerrainData.voxel(at: Vec3(28, -2, 28))) == .grass
              && t.material(TerrainData.voxel(at: Vec3(20, 2, 0))) == .rock && t.material(TerrainData.voxel(at: Vec3(-20, 10, 0))) == .basalt
              && t.material(TerrainData.voxel(at: Vec3(0, 2, 18))) == .sand)
        check("Region3, ReplaceMaterial and FillRegion", said("region") == "region 16, 8, 16 0, -4, 0"
              && t.material(TerrainData.voxel(at: Vec3(2, -2, 2))) == .mud && t.material(TerrainData.voxel(at: Vec3(-30, 2, -30))) == .snow,
              said("region"))
        check("ReadVoxels and WriteVoxels", said("read") == "read 2, 1, 2 Mud 1" && said("wrote") == "wrote Ice",
              "\(said("read")) \(said("wrote"))")
        check("Get/SetMaterialColor, WaterColor, WaterTransparency", said("colour") == "colour 0.8"
              && said("water") == "water 0.9 0.6" && t.materialColors[TerrainMaterial.grass.rawValue] != nil,
              "\(said("colour")) \(said("water"))")
        check("WorldToCell, CellCenterToWorld", said("cell") == "cell 1, -1, 2 6, -2, 10", said("cell"))
        check("Clouds in the Terrain", said("clouds") == "clouds true true" && model.lighting.clouds != nil, said("clouds"))
        check("…wrong values refused: a part's material, resolution 8, a Vector3 for a CFrame, a number for a colour, a part made of Grass",
              said("refused") == "refused false false false false false", said("refused"))
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("no errors", errors.isEmpty, "\(errors)")
        session.stop()
    }

    // MARK: - Drawing

    private static func testDrawing(_ check: Checker) {
        print("\nTerrain: drawn")
        guard let device = MTLCreateSystemDefaultDevice() else {
            check("a Metal device is available", false)
            return
        }
        let model = SceneModel()
        model.parts = []
        model.groups = []
        model.showGrid = false
        model.lighting.clockTime = 12
        model.terrain = ground(128, top: 0, material: .snow)
        let view = StudioMTKView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        view.device = device
        let editor = ViewportController(model: model)
        editor.camera.target = .zero
        editor.camera.distance = 30
        editor.camera.pitch = 1.2
        guard let renderer = Renderer(device: device, view: view, source: editor) else {
            check("the renderer builds", false)
            return
        }
        func middle() -> SIMD3<Float> {
            guard let pixels = renderer.frameSnapshot(width: 64, height: 64) else { return .zero }
            let p = pixels[32 * 64 + 32]
            return SIMD3(Float(p.z), Float(p.y), Float(p.x)) / 255
        }
        let snow = middle()
        model.terrain = ground(128, top: 0, material: .basalt)
        let dark = middle()
        check("drawn: pale snow, then dark basalt, where the camera looks down",
              (snow.x + snow.y + snow.z) > (dark.x + dark.y + dark.z) + 0.8 && snow.z > 0.5, "\(snow) \(dark)")
    }

    // MARK: - Studio

    private static func testStudio(_ check: Checker) {
        print("\nTerrain: in Studio")
        let model = SceneModel()
        model.terrain = ground(128, top: 0)
        let editor = ViewportController(model: model)
        editor.viewSize = SIMD2(800, 600)
        editor.camera.target = .zero
        editor.camera.distance = 40
        editor.camera.pitch = 1.0
        let undo = model.undoCount
        model.terrainBrush = .add
        model.terrainMaterial = .rock
        model.terrainBrushSize = 12
        let centre = SIMD2<Float>(400, 300)
        let pressed = editor.mouseDown(at: centre, additive: false)
        editor.mouseDragged(to: centre + SIMD2(40, 0))
        editor.mouseDragged(to: centre + SIMD2(80, 0))
        editor.mouseUp()
        let rock = model.terrain.chunks.values.contains { $0.materials.contains(TerrainMaterial.rock.rawValue) }
        check("a brush picked: pressing and dragging in the world paints the terrain, as one step to undo",
              pressed && rock && model.undoCount == undo + 1)
        model.undo()
        check("…undone", !model.terrain.chunks.values.contains { $0.materials.contains(TerrainMaterial.rock.rawValue) })
        editor.updateHover(at: centre)
        check("the brush shown where it would paint", editor.editorOverlay?.brush.map { abs($0.centre.y) < 1 && $0.radius == 6 } == true)
        model.joinTool = .weld
        check("picking a join tool puts the brush down", model.terrainBrush == nil && editor.editorOverlay?.brush == nil)
    }

    // MARK: - Together

    private static func testTogether(_ check: Checker) {
        print("\nTerrain: a host and a joined player")
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            model.parts = []
            model.terrain = ground(192, top: 0)
            var host = ScriptObject.blank(language: .luau)
            host.source = """
            task.wait(0.5)
            workspace.Terrain:FillBall(Vector3.new(40, 0, 40), 12, Enum.Material.Rock)
            workspace.Terrain:FillBlock(CFrame.new(-40, 0, -40), Vector3.new(16, 16, 16), Enum.Material.Air)
            """
            model.scripts += [host]
        }), let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 0.3)
        check("a joined player gets the host's terrain", joining.model.terrain.chunks.count == hosting.model.terrain.chunks.count
              && joining.model.terrain.material(TerrainData.voxel(at: Vec3(0, -2, 0))) == .grass)
        LANSelfTest.run([hosting, joining], seconds: 1.2)
        let theirs = joining.model.terrain
        check("…and what a host script does to it after", theirs.material(TerrainData.voxel(at: Vec3(40, 6, 40))) == .rock
              && theirs.occupancy(TerrainData.voxel(at: Vec3(-40, -2, -40))) == 0)
        check("…standing on it in their own game", abs(sam.character.position.y) < 1 || sam.character.position.y > 0,
              "\(sam.character.position)")
        let errors = (hosting.player!.console.lines + sam.console.lines).filter { $0.kind == .error }.map(\.text)
        check("…with no errors on either", errors.isEmpty, "\(errors)")
        joining.leaveGame()
        hosting.leaveGame()
    }
}
