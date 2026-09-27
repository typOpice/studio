import Foundation
import simd

/// A terrain chunk as triangles: its solid surface (each triangle's material, for colour)
/// and its water's surface.
struct TerrainChunkMesh {
    var positions: [Vec3] = []
    var normals: [Vec3] = []
    var indices: [UInt32] = []
    /// Each vertex's colour: its cell's solid corners' materials, blended by how solid.
    var colors: [Vec3] = []
    var water = (positions: [Vec3](), normals: [Vec3](), indices: [UInt32]())

    var isEmpty: Bool { indices.isEmpty && water.indices.isEmpty }
}

/// Surface nets over the voxels: a vertex inside each cell of eight voxel middles that the
/// surface passes through (where the edges' crossings average out), and a quad across
/// each edge between an inside voxel and an outside one, joining the four cells round it.
/// A chunk reads a voxel into its neighbours on each side, so chunks meet without seams.
enum TerrainMesher {
    static func mesh(_ key: TerrainData.Key, in terrain: TerrainData) -> TerrainChunkMesh {
        var palette = [Vec3](repeating: .zero, count: 256)
        for material in TerrainMaterial.allCases { palette[Int(material.rawValue)] = terrain.color(of: material) }
        let side = TerrainChunk.side
        let n = side + 2   // voxels −1…16 on each axis
        let origin = key &* Int32(side)
        var solid = [Float](repeating: 0, count: n * n * n)
        var material = [UInt8](repeating: 0, count: n * n * n)
        var water = [Float](repeating: 0, count: n * n * n)
        func at(_ x: Int, _ y: Int, _ z: Int) -> Int { ((z + 1) * n + (y + 1)) * n + (x + 1) }
        // From each of the 27 chunks round it, the block of it this one reads (−1…16).
        var any = false
        let waterCode = TerrainMaterial.water.rawValue
        for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
            guard let chunk = terrain.chunks[key &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))] else { continue }
            any = true
            // Its voxels' range in this chunk's coordinates, clipped to −1…16.
            func span(_ d: Int) -> ClosedRange<Int> { d < 0 ? -1...(-1) : d > 0 ? side...side : 0...(side - 1) }
            let (rx, ry, rz) = (span(dx), span(dy), span(dz))
            chunk.materials.withUnsafeBufferPointer { materials in
                chunk.occupancy.withUnsafeBufferPointer { occupancy in
                    for z in rz { for y in ry { for x in rx {
                        let i = TerrainChunk.index(x - dx * side, y - dy * side, z - dz * side)
                        let m = materials[i]
                        guard m != 0 else { continue }
                        let j = at(x, y, z)
                        if m == waterCode {
                            water[j] = Float(occupancy[i]) / 255
                        } else {
                            solid[j] = Float(occupancy[i]) / 255
                            material[j] = m
                        }
                    } } }
                }
            }
        } } }
        guard any else { return TerrainChunkMesh() }

        var mesh = TerrainChunkMesh()
        let voxel = TerrainData.voxel
        func centre(_ x: Int, _ y: Int, _ z: Int) -> Vec3 {
            (Vec3(Float(Int(origin.x) + x), Float(Int(origin.y) + y), Float(Int(origin.z) + z)) + 0.5) * voxel
        }
        func inside(_ x: Int, _ y: Int, _ z: Int) -> Bool { solid[at(x, y, z)] >= 0.5 }

        // A vertex in each cell (−1…15) the surface crosses.
        let corners: [SIMD3<Int>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 0),
                                     SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(0, 1, 1), SIMD3(1, 1, 1)]
        let edges: [(Int, Int)] = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
        var cellVertex = [Int32](repeating: -1, count: n * n * n)
        let offsets = corners.map { ($0.z * n + $0.y) * n + $0.x }
        var values = [Float](repeating: 0, count: 8)
        for z in -1..<side { for y in -1..<side { for x in -1..<side {
            let base = at(x, y, z)
            var count = 0
            for c in 0..<8 {
                let v = solid[base + offsets[c]]
                values[c] = v
                if v >= 0.5 { count += 1 }
            }
            guard count > 0, count < 8 else { continue }
            var sum = Vec3.zero, crossings: Float = 0
            for (a, b) in edges where (values[a] >= 0.5) != (values[b] >= 0.5) {
                let t = min(max((0.5 - values[a]) / (values[b] - values[a]), 0), 1)
                let pa = Vec3(corners[a]), pb = Vec3(corners[b])
                sum += pa + (pb - pa) * t
                crossings += 1
            }
            let local = sum / max(crossings, 1)
            let position = centre(x, y, z) + local * voxel
            // Outward: down the slope of solidity.
            var gradient = Vec3.zero
            for (c, corner) in corners.enumerated() {
                gradient += (Vec3(corner) * 2 - 1) * values[c]
            }
            let normal = simd_length(gradient) > 1e-5 ? -simd_normalize(gradient) : Vec3(0, 1, 0)
            // The solid corners' colours, the more solid the more.
            var colour = Vec3.zero, weight: Float = 0
            for corner in corners {
                let j = at(x + corner.x, y + corner.y, z + corner.z)
                guard material[j] != 0, solid[j] > 0 else { continue }
                let w = solid[j] * solid[j]
                colour += palette[Int(material[j])] * w
                weight += w
            }
            cellVertex[at(x, y, z)] = Int32(mesh.positions.count)
            mesh.positions.append(position)
            mesh.normals.append(normal)
            mesh.colors.append(weight > 0 ? colour / weight : palette[Int(TerrainMaterial.rock.rawValue)])
        } } }

        // A quad across each crossing edge from a voxel in this chunk.
        func quad(_ a: Int32, _ b: Int32, _ c: Int32, _ d: Int32, outward: Vec3) {
            guard a >= 0, b >= 0, c >= 0, d >= 0 else { return }
            let pa = mesh.positions[Int(a)], pb = mesh.positions[Int(b)], pc = mesh.positions[Int(c)]
            var order = [a, b, c, a, c, d]
            if simd_dot(simd_cross(pb - pa, pc - pa), outward) < 0 { order = [a, c, b, a, d, c] }
            mesh.indices += order.map { UInt32($0) }
        }
        for z in 0..<side { for y in 0..<side { for x in 0..<side {
            let here = inside(x, y, z)
            if here != inside(x + 1, y, z) {
                quad(cellVertex[at(x, y - 1, z - 1)], cellVertex[at(x, y, z - 1)], cellVertex[at(x, y, z)],
                     cellVertex[at(x, y - 1, z)], outward: Vec3(here ? 1 : -1, 0, 0))
            }
            if here != inside(x, y + 1, z) {
                quad(cellVertex[at(x - 1, y, z - 1)], cellVertex[at(x, y, z - 1)], cellVertex[at(x, y, z)],
                     cellVertex[at(x - 1, y, z)], outward: Vec3(0, here ? 1 : -1, 0))
            }
            if here != inside(x, y, z + 1) {
                quad(cellVertex[at(x - 1, y - 1, z)], cellVertex[at(x, y - 1, z)], cellVertex[at(x, y, z)],
                     cellVertex[at(x - 1, y, z)], outward: Vec3(0, 0, here ? 1 : -1))
            }
        } } }

        // Water: its top wherever it isn't under more water — as high as it's full — and
        // its sides onto air. The top reaches over the shore's ground beside it at the same
        // height: the smooth ground rising out of it cuts it off, so the shore isn't square.
        func wet(_ x: Int, _ y: Int, _ z: Int) -> Float { water[at(x, y, z)] }
        func open(_ x: Int, _ y: Int, _ z: Int) -> Bool { wet(x, y, z) <= 0 && solid[at(x, y, z)] < 0.5 }
        /// The height of a voxel's water surface, if it has one on top.
        func surface(_ x: Int, _ y: Int, _ z: Int) -> Float? {
            let full = wet(x, y, z)
            guard full > 0, wet(x, y + 1, z) <= 0 else { return nil }
            return centre(x, y, z).y - voxel / 2 + full * voxel
        }
        func quad(_ corners: [Vec3], _ normal: Vec3) {
            let base = UInt32(mesh.water.positions.count)
            mesh.water.positions += corners
            mesh.water.normals += Array(repeating: normal, count: 4)
            mesh.water.indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        for z in 0..<side { for y in 0..<side { for x in 0..<side {
            let low = centre(x, y, z) - voxel / 2, high = low + voxel
            var top: Float?
            if let height = surface(x, y, z) {
                top = height
            } else if wet(x, y, z) <= 0, solid[at(x, y, z)] > 0, open(x, y + 1, z) {
                // Shore: the highest surface of the water beside it.
                for (dx, dz) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)] {
                    if let height = surface(x + dx, y, z + dz) { top = max(top ?? height, height) }
                }
            }
            if let top {
                quad([Vec3(low.x, top, low.z), Vec3(low.x, top, high.z), Vec3(high.x, top, high.z), Vec3(high.x, top, low.z)],
                     Vec3(0, 1, 0))
            }
            let full = wet(x, y, z)
            guard full > 0 else { continue }
            let height = low.y + full * voxel
            if open(x + 1, y, z) {
                quad([Vec3(high.x, low.y, low.z), Vec3(high.x, height, low.z), Vec3(high.x, height, high.z), Vec3(high.x, low.y, high.z)],
                     Vec3(1, 0, 0))
            }
            if open(x - 1, y, z) {
                quad([Vec3(low.x, low.y, low.z), Vec3(low.x, low.y, high.z), Vec3(low.x, height, high.z), Vec3(low.x, height, low.z)],
                     Vec3(-1, 0, 0))
            }
            if open(x, y, z + 1) {
                quad([Vec3(low.x, low.y, high.z), Vec3(high.x, low.y, high.z), Vec3(high.x, height, high.z), Vec3(low.x, height, high.z)],
                     Vec3(0, 0, 1))
            }
            if open(x, y, z - 1) {
                quad([Vec3(low.x, low.y, low.z), Vec3(low.x, height, low.z), Vec3(high.x, height, low.z), Vec3(high.x, low.y, low.z)],
                     Vec3(0, 0, -1))
            }
        } } }
        return mesh
    }
}

/// The terrain's chunks as meshes, and as parts for everything that collides with parts
/// (the character, the physics, pathfinding, raycasts): each chunk a MeshPart with Precise
/// collision whose triangles are made here. Only chunks that changed — they or a neighbour —
/// are made again. Kept by the scene (`SceneModel.terrainGeometry`).
final class TerrainGeometry {
    struct Entry {
        var signature: Int
        var mesh: TerrainChunkMesh
        /// Its collision, when it has a solid surface.
        var part: Part?
    }

    private(set) var entries: [TerrainData.Key: Entry] = [:]
    /// The collision parts, all together; and a number that changes when they do.
    private(set) var parts: [Part] = []
    private(set) var revision = 0
    private var partIDs: Set<UUID> = []
    private var lastSeen: [TerrainData.Key: Int]?
    private var colours: [UInt8: Vec3] = [:]

    deinit {
        for entry in entries.values { if let asset = entry.part?.mesh?.asset { MeshLibrary.shared.forget(asset) } }
    }

    /// Whether a part is the terrain's (a touch, a raycast's hit).
    func isTerrain(_ id: UUID) -> Bool { partIDs.contains(id) }

    /// Brings the meshes up to the terrain as it is now.
    func update(_ terrain: TerrainData) {
        let stamps = terrain.chunks.mapValues(\.stamp)
        if stamps == lastSeen, colours == terrain.materialColors { return }
        lastSeen = stamps
        let recoloured = colours != terrain.materialColors
        colours = terrain.materialColors
        let edges = terrain.chunks.mapValues(\.edgeStamp)
        // Every chunk, and the ones below and behind each (a surface on their side of
        // the boundary is theirs).
        var wanted: Set<TerrainData.Key> = []
        for key in terrain.chunks.keys {
            for dz in 0...1 { for dy in 0...1 { for dx in 0...1 {
                wanted.insert(key &- SIMD3(Int32(dx), Int32(dy), Int32(dz)))
            } } }
        }
        var changed = false
        for key in entries.keys where !wanted.contains(key) {
            if let asset = entries[key]?.part?.mesh?.asset { MeshLibrary.shared.forget(asset) }
            entries[key] = nil
            changed = true
        }
        for key in wanted {
            // Its own voxels, and its neighbours' outside layers.
            var hasher = Hasher()
            for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                let near = key &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))
                hasher.combine((dx, dy, dz) == (0, 0, 0) ? stamps[near] ?? 0 : edges[near] ?? 0)
            } } }
            let signature = hasher.finalize()
            if !recoloured, entries[key]?.signature == signature { continue }
            if let asset = entries[key]?.part?.mesh?.asset { MeshLibrary.shared.forget(asset) }
            let mesh = TerrainMesher.mesh(key, in: terrain)
            entries[key] = Entry(signature: signature, mesh: mesh, part: Self.part(for: key, mesh))
            changed = true
        }
        guard changed else { return }
        parts = entries.keys.sorted { ($0.z, $0.y, $0.x) < ($1.z, $1.y, $1.x) }.compactMap { entries[$0]?.part }
        partIDs = Set(parts.map(\.id))
        revision += 1
    }

    /// A chunk's solid surface as a still MeshPart, its triangles registered as the mesh.
    private static func part(for key: TerrainData.Key, _ mesh: TerrainChunkMesh) -> Part? {
        guard !mesh.indices.isEmpty,
              let geometry = MeshGeometry(positions: mesh.positions, normals: mesh.normals, uvs: [], indices: mesh.indices,
                                          hull: false) else { return nil }
        var low = Vec3(repeating: .greatestFiniteMagnitude), high = -low
        for p in mesh.positions { low = simd_min(low, p); high = simd_max(high, p) }
        let asset = UUID()
        MeshLibrary.shared.register(geometry, as: asset)
        var part = Part()
        part.id = UUID(stableFrom: "terrain \(key.x) \(key.y) \(key.z)")
        part.name = "Terrain"
        part.position = (low + high) / 2
        part.size = simd_max(high - low, Vec3(repeating: 1e-4))
        part.anchored = true
        part.mesh = MeshSettings(meshId: "terrain", asset: asset, textureId: "", collisionFidelity: .precise)
        return part
    }
}

extension SceneModel {
    /// The terrain's meshes and collision parts, brought up to date.
    var terrainParts: [Part] {
        terrainGeometry.update(terrain)
        return terrainGeometry.parts
    }
}
