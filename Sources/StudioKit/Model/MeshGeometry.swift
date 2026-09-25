import Foundation
import ModelIO
import simd
import CJolt

/// How a MeshPart collides — Roblox's CollisionFidelity: its bounding box, its convex
/// outline (the default), or its exact triangles (for anchored parts; a moving one
/// collides as its outline, as Jolt can't simulate a triangle mesh).
enum CollisionFidelity: String, Codable, CaseIterable, Identifiable {
    case box, hull, precise

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .box: return "Box"
        case .hull: return "Hull"
        case .precise: return "Precise"
        }
    }

    /// Enum.CollisionFidelity's name for it.
    var robloxName: String {
        switch self {
        case .box: return "Box"
        case .hull: return "Hull"
        case .precise: return "PreciseConvexDecomposition"
        }
    }

    init?(robloxName: String) {
        switch robloxName {
        case "Box": self = .box
        case "Hull", "Default": self = .hull
        case "PreciseConvexDecomposition", "Precise": self = .precise
        default: return nil
        }
    }
}

/// What makes a part a MeshPart: the 3D file it shows (an imported mesh asset,
/// "studio://Name"), the picture wrapped round it, and how it collides. The mesh is
/// stretched to fill the part's Size, as Roblox does.
struct MeshSettings: Codable, Equatable {
    var meshId = ""
    /// The asset `meshId` named when it was set, so the mesh is found by what doesn't
    /// change — the id — even if the asset is renamed. Nil while it names nothing.
    var asset: UUID?
    var textureId = ""
    var collisionFidelity: CollisionFidelity = .hull
}

/// A mesh file made ready to use: triangles in the unit cube (−0.5…0.5 on each axis,
/// stretched to a part's Size like every other shape), its normals and picture
/// coordinates, the size it was made at, and its convex hull.
struct MeshGeometry {
    let positions: [Vec3]
    let normals: [Vec3]
    /// Texture coordinates, top-left origin; empty if the file had none.
    let uvs: [SIMD2<Float>]
    let indices: [UInt32]
    /// The size the file's mesh is, in studs (its units).
    let nativeSize: Vec3
    /// Its exact triangles, for Precise collision and for picking.
    let triangles: TriangleSet
    /// Its convex hull: for Hull collision and the physics.
    let hull: TriangleSet
    /// The hull's volume in unit space: a part's volume is this times its Size's.
    let hullVolume: Float

    var triangleCount: Int { indices.count / 3 }

    /// The most triangles a mesh may have, and corners its hull may.
    static let largestTriangleCount = 500_000
    static let hullCorners = 128

    init?(positions raw: [Vec3], normals rawNormals: [Vec3], uvs: [SIMD2<Float>], indices: [UInt32]) {
        var raw = raw, rawNormals = rawNormals, uvs = uvs, indices = indices
        if rawNormals.count != raw.count, indices.count % 3 == 0, indices.allSatisfy({ Int($0) < raw.count }) {
            (raw, rawNormals, uvs, indices) = Self.creasedNormals(positions: raw, uvs: uvs, indices: indices)
        }
        guard raw.count >= 3, indices.count >= 3, indices.count % 3 == 0,
              indices.count / 3 <= Self.largestTriangleCount,
              indices.allSatisfy({ Int($0) < raw.count }) else { return nil }
        var lower = Vec3(repeating: .greatestFiniteMagnitude), upper = -lower
        for p in raw { lower = simd_min(lower, p); upper = simd_max(upper, p) }
        let extent = upper - lower
        guard extent.x.isFinite, extent.y.isFinite, extent.z.isFinite, simd_reduce_max(extent) > 1e-6 else { return nil }
        // Stretched to the unit cube on each axis; a flat mesh stays flat.
        let size = simd_max(extent, Vec3(repeating: 1e-4))
        let centre = (lower + upper) / 2
        positions = raw.map { ($0 - centre) / size }
        normals = rawNormals.map { n in let m = n * size; return length(m) > 1e-12 ? normalize(m) : Vec3(0, 1, 0) }
        self.uvs = uvs.count == raw.count ? uvs : []
        self.indices = indices
        nativeSize = simd_max(extent, Vec3(repeating: 0.01))
        let triangleList = stride(from: 0, to: indices.count, by: 3).map {
            SIMD3<Int32>(Int32(indices[$0]), Int32(indices[$0 + 1]), Int32(indices[$0 + 2]))
        }
        triangles = TriangleSet(vertices: positions, triangles: triangleList)
        hull = Self.convexHull(of: positions)
        hullVolume = Self.volume(of: hull)
    }

    /// Normals for a file that has none, as modelling apps make them: a corner is smooth
    /// across faces less than `creaseAngle` apart and sharp across the rest, so a box
    /// keeps its edges and a ball stays round. A corner on a crease is split into one
    /// vertex per side (positions and picture coordinates copied).
    static let creaseAngle: Float = 40 * .pi / 180

    static func creasedNormals(positions: [Vec3], uvs: [SIMD2<Float>], indices: [UInt32])
        -> (positions: [Vec3], normals: [Vec3], uvs: [SIMD2<Float>], indices: [UInt32]) {
        let hasUVs = uvs.count == positions.count
        let faces = stride(from: 0, to: indices.count, by: 3).map { t -> Vec3 in
            let a = positions[Int(indices[t])], b = positions[Int(indices[t + 1])], c = positions[Int(indices[t + 2])]
            return cross(b - a, c - a)   // its length is twice the area: bigger faces count for more
        }
        // Corners meet by position, not index: a file often repeats a corner for each
        // face it has different picture coordinates on.
        var byPlace: [SIMD3<Int32>: [Int]] = [:]
        let lower = positions.reduce(Vec3(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
        let upper = positions.reduce(-Vec3(repeating: .greatestFiniteMagnitude)) { simd_max($0, $1) }
        let cell = max(simd_reduce_max(upper - lower), 1e-6) * 1e-5
        func place(_ p: Vec3) -> SIMD3<Int32> { SIMD3<Int32>(((p - lower) / cell).rounded(.toNearestOrEven)) }
        for (corner, index) in indices.enumerated() { byPlace[place(positions[Int(index)]), default: []].append(corner / 3) }
        let threshold = cos(creaseAngle)
        var outPositions: [Vec3] = [], outNormals: [Vec3] = [], outUVs: [SIMD2<Float>] = [], outIndices: [UInt32] = []
        outIndices.reserveCapacity(indices.count)
        var made: [SIMD4<Int32>: UInt32] = [:]   // (original vertex, normal rounded) → new vertex
        for (corner, index) in indices.enumerated() {
            let face = faces[corner / 3]
            let direction = length(face) > 1e-20 ? normalize(face) : Vec3(0, 1, 0)
            var sum = Vec3.zero
            for other in Set(byPlace[place(positions[Int(index)])] ?? []) {
                let n = faces[other]
                if length(n) > 1e-20, dot(normalize(n), direction) >= threshold { sum += n }
            }
            let normal = length(sum) > 1e-20 ? normalize(sum) : direction
            let rounded = SIMD3<Int32>((normal * 1000).rounded(.toNearestOrEven))
            let key = SIMD4<Int32>(Int32(index), rounded.x, rounded.y, rounded.z)
            if let known = made[key] {
                outIndices.append(known)
                continue
            }
            let new = UInt32(outPositions.count)
            made[key] = new
            outPositions.append(positions[Int(index)])
            outNormals.append(normal)
            if hasUVs { outUVs.append(uvs[Int(index)]) }
            outIndices.append(new)
        }
        return (outPositions, outNormals, outUVs, outIndices)
    }

    /// The hull, built by Jolt, as triangles over its own corners.
    private static func convexHull(of points: [Vec3]) -> TriangleSet {
        // A big mesh's hull comes out the same from a thinned-out sample of its points.
        let step = max(points.count / 20_000, 1)
        let sample = stride(from: 0, to: points.count, by: step).map { points[$0] }
        let flat = sample.flatMap { [$0.x, $0.y, $0.z] }
        var indices = [UInt32](repeating: 0, count: 3 * 4096)
        let count = flat.withUnsafeBufferPointer { p in
            indices.withUnsafeMutableBufferPointer { out in
                Int(studio_jolt_convex_hull(p.baseAddress, Int32(sample.count), Int32(hullCorners),
                                            out.baseAddress, 4096))
            }
        }
        guard count > 0 else {
            // Flat or a line: its box's corners stand in.
            let corners = (0..<8).map { i in
                Vec3(i & 1 == 0 ? -0.5 : 0.5, i & 2 == 0 ? -0.5 : 0.5, i & 4 == 0 ? -0.5 : 0.5)
            }
            let faces: [SIMD3<Int32>] = [[0, 2, 1], [1, 2, 3], [4, 5, 6], [5, 7, 6], [0, 1, 4], [1, 5, 4],
                                         [2, 6, 3], [3, 6, 7], [0, 4, 2], [2, 4, 6], [1, 3, 5], [3, 7, 5]]
            return TriangleSet(vertices: corners, triangles: faces)
        }
        // Keep only the corners the hull uses.
        var remap: [UInt32: Int32] = [:]
        var corners: [Vec3] = []
        var triangles: [SIMD3<Int32>] = []
        for t in 0..<min(count, 4096) {
            var triangle = SIMD3<Int32>()
            for k in 0..<3 {
                let original = indices[t * 3 + k]
                if remap[original] == nil {
                    remap[original] = Int32(corners.count)
                    corners.append(sample[Int(original)])
                }
                triangle[k] = remap[original]!
            }
            triangles.append(triangle)
        }
        return TriangleSet(vertices: corners, triangles: triangles)
    }

    private static func volume(of hull: TriangleSet) -> Float {
        var total: Float = 0
        for index in hull.triangles.indices {
            let (a, b, c) = hull.corners(index)
            total += dot(a, cross(b, c)) / 6
        }
        return max(abs(total), 1e-6)
    }

    /// Whether a point (unit space) is inside the hull, and if it is, the shortest way
    /// out in a part's scaled space: the direction and how far.
    func escapeFromHull(_ point: Vec3, scale: Vec3) -> (direction: Vec3, depth: Float)? {
        var best: (Vec3, Float)?
        for index in hull.triangles.indices {
            let (a, b, c) = hull.corners(index)
            let n = cross(b - a, c - a)
            guard length(n) > 1e-12 else { continue }
            let normal = normalize(n)
            let inside = dot(normal, point - a)
            if inside > 1e-6 { return nil }
            // The same plane in scaled space: normal n/s, offset n·a.
            let scaled = normal / scale
            let depth = -inside / length(scaled)
            if depth < (best?.1 ?? .greatestFiniteMagnitude) { best = (normalize(scaled), depth) }
        }
        return best
    }

    // MARK: - Files

    static let fileExtensions: Set<String> = ["obj", "stl", "ply", "usd", "usda", "usdc", "usdz"]

    /// A 3D file, through Model I/O: every mesh in it, placed as the file places them.
    static func decode(_ data: Data, fileExtension: String) -> MeshGeometry? {
        let ext = fileExtension.lowercased()
        guard fileExtensions.contains(ext), MDLAsset.canImportFileExtension(ext) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-mesh-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url)) != nil else { return nil }
        let asset = MDLAsset(url: url)
        var positions: [Vec3] = [], normals: [Vec3] = [], uvs: [SIMD2<Float>] = [], indices: [UInt32] = []
        var everyNormal = true, everyUV = true
        guard let meshes = asset.childObjects(of: MDLMesh.self) as? [MDLMesh], !meshes.isEmpty else { return nil }
        for mesh in meshes {
            let transform = MDLTransform.globalTransform(with: mesh, atTime: 0)
            let normalTransform = simd_float3x3(Vec3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                                                Vec3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                                                Vec3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
                .inverse.transpose
            guard let place = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else {
                continue
            }
            let base = UInt32(positions.count)
            let count = mesh.vertexCount
            for v in 0..<count {
                let p = place.dataStart.advanced(by: v * place.stride).assumingMemoryBound(to: Float.self)
                let world = transform * Vec4(p[0], p[1], p[2], 1)
                positions.append(Vec3(world.x, world.y, world.z))
            }
            if let normal = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal, as: .float3) {
                for v in 0..<count {
                    let n = normal.dataStart.advanced(by: v * normal.stride).assumingMemoryBound(to: Float.self)
                    normals.append(normalTransform * Vec3(n[0], n[1], n[2]))
                }
            } else {
                everyNormal = false
            }
            if let uv = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeTextureCoordinate, as: .float2) {
                for v in 0..<count {
                    let t = uv.dataStart.advanced(by: v * uv.stride).assumingMemoryBound(to: Float.self)
                    uvs.append(SIMD2(t[0], 1 - t[1]))   // files count up from the bottom
                }
            } else {
                everyUV = false
            }
            for case let submesh as MDLSubmesh in mesh.submeshes ?? [] where submesh.geometryType == .triangles {
                let buffer = submesh.indexBuffer(asIndexType: .uInt32)
                let map = buffer.map()
                let pointer = map.bytes.assumingMemoryBound(to: UInt32.self)
                for i in 0..<submesh.indexCount {
                    let index = pointer[i]
                    guard index < UInt32(count) else { continue }
                    indices.append(base + index)
                }
                // A stray index left a triangle short: drop its corners.
                indices.removeLast(indices.count % 3)
            }
        }
        return MeshGeometry(positions: positions, normals: everyNormal ? normals : [],
                            uvs: everyUV ? uvs : [], indices: indices)
    }
}

/// Every mesh file this app has been given, decoded once, by asset. Mesh parts find
/// their geometry here — the renderer, the physics, the character's collisions and
/// picking all ask by the asset id their part holds, so this needs no scene.
final class MeshLibrary {
    static let shared = MeshLibrary()

    private var files: [UUID: (data: Data, fileExtension: String)] = [:]
    private var decoded: [UUID: MeshGeometry?] = [:]

    /// Takes note of a scene's mesh assets (it keeps any it already has: an undone
    /// delete brings one straight back).
    func register(_ assets: [SceneAsset]) {
        for asset in assets where asset.kind == .mesh {
            if let known = files[asset.id], known.data.count == asset.data.count { continue }
            files[asset.id] = (asset.data, asset.fileExtension)
            decoded[asset.id] = nil
        }
    }

    func geometry(_ asset: UUID?) -> MeshGeometry? {
        guard let asset, let file = files[asset] else { return nil }
        if let known = decoded[asset] { return known }
        let made = MeshGeometry.decode(file.data, fileExtension: file.fileExtension)
        decoded[asset] = .some(made)
        return made
    }

    /// A part's mesh, if it is a MeshPart whose file is here and readable.
    func geometry(for part: Part) -> MeshGeometry? {
        guard let mesh = part.mesh else { return nil }
        return geometry(mesh.asset)
    }
}
