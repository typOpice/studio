import Foundation
import simd

/// Closed triangle boundaries. Colors follow faces through splits and subtraction.
struct SolidMesh: Codable, Equatable {
    var id = UUID()
    var positions: [Vec3] = []
    var colors: [Vec3] = []
    var indices: [UInt32] = []
    var uvs: [SIMD2<Float>] = []
    var volume: Double {
        stride(from: 0, to: indices.count, by: 3).reduce(0) { sum, i in
            let a = SIMD3<Double>(positions[Int(indices[i])])
            let b = SIMD3<Double>(positions[Int(indices[i + 1])])
            let c = SIMD3<Double>(positions[Int(indices[i + 2])])
            return sum + simd_dot(a, simd_cross(b, c)) / 6
        }
    }
    var bounds: (lower: Vec3, upper: Vec3) {
        (positions.reduce(Vec3(repeating: .greatestFiniteMagnitude), simd_min),
         positions.reduce(Vec3(repeating: -.greatestFiniteMagnitude), simd_max))
    }
    func geometry() -> MeshGeometry? {
        MeshGeometry(positions: positions, normals: [], uvs: uvs, indices: indices)
    }
}

enum SolidError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let reason) = self { return reason }; return nil }
}

enum SolidGeometry {
    typealias Point = SIMD3<Double>
    private struct Polygon {
        var vertices: [Point]
        var color: Vec3
        var normal: Point
        var distance: Double
        init?(_ vertices: [Point], color: Vec3, epsilon: Double) {
            guard vertices.count >= 3 else { return nil }
            var n = Point.zero
            for i in 1..<(vertices.count - 1) {
                n = simd_cross(vertices[i] - vertices[0], vertices[i + 1] - vertices[0])
                if simd_length(n) > epsilon * epsilon { break }
            }
            guard simd_length(n) > epsilon * epsilon else { return nil }
            self.vertices = vertices; self.color = color
            normal = simd_normalize(n); distance = simd_dot(normal, vertices[0])
        }
        mutating func flip() { vertices.reverse(); normal = -normal; distance = -distance }
    }
    private final class Budget {
        var remaining = 8_000_000
        let epsilon: Double
        init(_ epsilon: Double) { self.epsilon = epsilon }
        func spend(_ count: Int = 1) throws {
            remaining -= count
            if remaining < 0 { throw SolidError.invalid("The solid is too complex. Use fewer or simpler operands.") }
        }
    }
    private final class Node {
        var normal: Point?
        var distance: Double = 0
        var polygons: [Polygon] = []
        var front: Node?, back: Node?
        let budget: Budget
        init(_ budget: Budget) { self.budget = budget }
        func split(_ polygon: Polygon, coplanarFront: inout [Polygon], coplanarBack: inout [Polygon],
                   front: inout [Polygon], back: inout [Polygon]) throws {
            try budget.spend(polygon.vertices.count)
            let n = normal!, epsilon = budget.epsilon
            var kind = 0
            let kinds = polygon.vertices.map { p -> Int in
                let d = simd_dot(n, p) - distance
                let side = d < -epsilon ? 2 : (d > epsilon ? 1 : 0)
                kind |= side; return side
            }
            switch kind {
            case 0:
                if simd_dot(n, polygon.normal) > 0 { coplanarFront.append(polygon) }
                else { coplanarBack.append(polygon) }
            case 1: front.append(polygon)
            case 2: back.append(polygon)
            default:
                var f: [Point] = [], b: [Point] = []
                for i in polygon.vertices.indices {
                    let j = (i + 1) % polygon.vertices.count
                    let p = polygon.vertices[i], q = polygon.vertices[j]
                    if kinds[i] != 2 { f.append(p) }; if kinds[i] != 1 { b.append(p) }
                    if kinds[i] | kinds[j] == 3 {
                        let t = (distance - simd_dot(n, p)) / simd_dot(n, q - p)
                        let cut = p + (q - p) * min(max(t, 0), 1)
                        f.append(cut); b.append(cut)
                    }
                }
                if let p = Polygon(f, color: polygon.color, epsilon: epsilon) { front.append(p) }
                if let p = Polygon(b, color: polygon.color, epsilon: epsilon) { back.append(p) }
            }
        }
        func build(_ input: [Polygon], depth: Int = 0) throws {
            guard !input.isEmpty else { return }
            guard depth < 1024, input.count <= 30_000 else {
                throw SolidError.invalid("The solid is too complex. Use fewer or simpler operands.")
            }
            if normal == nil { normal = input[0].normal; distance = input[0].distance }
            var cf: [Polygon] = [], cb: [Polygon] = [], f: [Polygon] = [], b: [Polygon] = []
            for p in input { try split(p, coplanarFront: &cf, coplanarBack: &cb, front: &f, back: &b) }
            polygons += cf + cb
            if !f.isEmpty { if front == nil { front = Node(budget) }; try front!.build(f, depth: depth + 1) }
            if !b.isEmpty { if back == nil { back = Node(budget) }; try back!.build(b, depth: depth + 1) }
        }
        func clipped(_ input: [Polygon], depth: Int = 0) throws -> [Polygon] {
            guard normal != nil else { return input }
            guard depth < 1024 else { throw SolidError.invalid("The solid is too complex.") }
            var cf: [Polygon] = [], cb: [Polygon] = [], f: [Polygon] = [], b: [Polygon] = []
            for p in input { try split(p, coplanarFront: &cf, coplanarBack: &cb, front: &f, back: &b) }
            f += cf; b += cb
            if let front { f = try front.clipped(f, depth: depth + 1) }
            if let back { b = try back.clipped(b, depth: depth + 1) } else { b = [] }
            return f + b
        }
        func clip(to other: Node) throws {
            polygons = try other.clipped(polygons)
            try front?.clip(to: other); try back?.clip(to: other)
        }
        func invert() {
            polygons = polygons.map { p in var p = p; p.flip(); return p }
            if let normal { self.normal = -normal; distance = -distance }
            front?.invert(); back?.invert(); swap(&front, &back)
        }
        func all() -> [Polygon] { polygons + (front?.all() ?? []) + (back?.all() ?? []) }
    }

    /// Snapshot the mesh data before background work; MeshLibrary belongs to the main thread.
    static func input(_ part: Part) throws -> SolidMesh {
        let positions: [Vec3], indices: [UInt32], uvs: [SIMD2<Float>]
        if let geometry = MeshLibrary.shared.geometry(for: part) {
            positions = geometry.positions; indices = geometry.indices; uvs = geometry.uvs
        } else if part.mesh != nil {
            throw SolidError.invalid("\(part.name)'s mesh is missing or unreadable.")
        } else {
            let source: ([Vertex], [UInt16])
            switch part.shape {
            case .block, .truss: source = MeshFactory.box()
            case .sphere: source = MeshFactory.sphere(slices: 24, stacks: 16)
            case .cylinder: source = MeshFactory.cylinder(segments: 32)
            case .wedge: source = MeshFactory.wedge()
            }
            positions = source.0.map(\.position); indices = source.1.map(UInt32.init); uvs = []
        }
        guard positions.count <= 40_000, indices.count <= 60_000,
              part.size.x > 0, part.size.y > 0, part.size.z > 0 else {
            throw SolidError.invalid("\(part.name) has an invalid size or too many triangles.")
        }
        let world = positions.map { point in let p = part.modelMatrix * Vec4(point, 1); return Vec3(p.x, p.y, p.z) }
        let sourceColors = part.solidDeformation?.colors ?? part.solid?.mesh.colors ?? []
        let colors = !part.usePartColor && sourceColors.count == positions.count ? sourceColors : Array(repeating: part.color, count: positions.count)
        return SolidMesh(positions: world, colors: colors, indices: indices, uvs: uvs)
    }

    static func combine(positive: [Part], negative: [Part]) throws -> SolidMesh {
        try combine(positive: positive.map(input), negative: negative.map(input))
    }
    static func combine(positive: [SolidMesh], negative: [SolidMesh]) throws -> SolidMesh {
        guard !positive.isEmpty else { throw SolidError.invalid("Select at least one positive solid.") }
        guard positive.count + negative.count <= 32 else { throw SolidError.invalid("Use at most 32 solids in one operation.") }
        let all = positive + negative
        let lower = all.map(\.bounds.lower).reduce(Vec3(repeating: .greatestFiniteMagnitude), simd_min)
        let upper = all.map(\.bounds.upper).reduce(Vec3(repeating: -.greatestFiniteMagnitude), simd_max)
        let scale = Double(simd_reduce_max(upper - lower))
        guard scale.isFinite, scale > 1e-6 else { throw SolidError.invalid("The solid has no finite volume.") }
        let budget = Budget(max(scale * 1e-7, 1e-8))
        let solids = try all.map { try polygons($0, budget: budget) }
        var result = solids[0]
        for i in 1..<solids.count {
            let a = Node(budget), b = Node(budget)
            try a.build(result); try b.build(solids[i])
            if i < positive.count {
                try a.clip(to: b); try b.clip(to: a); b.invert(); try b.clip(to: a); b.invert()
                try a.build(b.all())
            } else {
                a.invert(); try a.clip(to: b); try b.clip(to: a); b.invert()
                try b.clip(to: a); b.invert(); try a.build(b.all()); a.invert()
            }
            result = a.all()
            if result.isEmpty { throw SolidError.invalid("The operation leaves no solid.") }
        }
        return try triangulate(result, budget: budget)
    }

    private struct Edge: Hashable { var a: Int; var b: Int }
    private static func polygons(_ mesh: SolidMesh, budget: Budget) throws -> [Polygon] {
        guard mesh.positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              mesh.indices.count % 3 == 0, mesh.indices.allSatisfy({ Int($0) < mesh.positions.count }) else {
            throw SolidError.invalid("A solid contains invalid triangles.")
        }
        let epsilon = budget.epsilon
        var cells: [SIMD3<Int64>: [Int]] = [:], vertices: [Point] = [], corners: [Int] = []
        let origin = Point(mesh.bounds.lower)
        for p in mesh.positions {
            let point = Point(p), key = SIMD3<Int64>(((point - origin) / (epsilon * 4)).rounded(.down))
            var match: Int?
            for x in -1...1 { for y in -1...1 { for z in -1...1 {
                for index in cells[key &+ SIMD3<Int64>(Int64(x), Int64(y), Int64(z))] ?? [] {
                    if simd_distance(vertices[index], point) <= epsilon * 4 { match = index }
                }
            } } }
            if let match { corners.append(match) }
            else { corners.append(vertices.count); cells[key, default: []].append(vertices.count); vertices.append(point) }
        }
        var edges: [Edge: (count: Int, direction: Int)] = [:]
        var result: [Polygon] = []
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let ids = (0..<3).map { Int(mesh.indices[i + $0]) }
            guard let polygon = Polygon(ids.map { Point(mesh.positions[$0]) }, color: (mesh.colors.indices.contains(ids[0]) ? mesh.colors[ids[0]] : Vec3(repeating: 0.64)), epsilon: epsilon) else { continue }
            let ids2 = ids.map { corners[$0] }
            if Set(ids2).count < 3 { continue }
            for j in 0..<3 {
                let a = ids2[j], b = ids2[(j + 1) % 3]
                let edge = Edge(a: min(a, b), b: max(a, b)), old = edges[Edge(a: min(a, b), b: max(a, b))] ?? (0, 0)
                edges[edge] = (old.0 + 1, old.1 + (a < b ? 1 : -1))
            }
            result.append(polygon)
        }
        guard !result.isEmpty, edges.values.allSatisfy({ $0.count == 2 && $0.direction == 0 }), mesh.volume > epsilon * epsilon * epsilon else {
            throw SolidError.invalid("Use a closed, outward-facing manifold mesh; open or non-manifold meshes cannot be combined.")
        }
        return result
    }

    /// Split shared edges at every boundary vertex before triangulating: BSP splits can
    /// leave T-junctions, which otherwise make a saved union unusable as a later operand.
    private static func triangulate(_ polygons: [Polygon], budget: Budget) throws -> SolidMesh {
        guard polygons.count <= 12_000 else { throw SolidError.invalid("The result has too many faces.") }
        let epsilon = budget.epsilon
        var unique: [SIMD3<Int64>: Point] = [:]
        let origin = polygons.flatMap(\.vertices).reduce(Point(repeating: .greatestFiniteMagnitude), simd_min)
        func key(_ p: Point) -> SIMD3<Int64> { SIMD3<Int64>(((p - origin) / epsilon).rounded(.toNearestOrEven)) }
        for polygon in polygons { for p in polygon.vertices { unique[key(p)] = p } }
        let points = unique.values.sorted { a, b in a.x != b.x ? a.x < b.x : (a.y != b.y ? a.y < b.y : a.z < b.z) }
        var result = SolidMesh()
        for polygon in polygons {
            var boundary: [Point] = []
            for i in polygon.vertices.indices {
                let a = unique[key(polygon.vertices[i])]!, b = unique[key(polygon.vertices[(i + 1) % polygon.vertices.count])]!
                let direction = b - a, squared = simd_length_squared(direction)
                guard squared > epsilon * epsilon else { continue }
                var along: [(Double, Point)] = [(0, a)]
                try budget.spend(points.count)
                for point in points {
                    let t = simd_dot(point - a, direction) / squared
                    if t > epsilon / sqrt(squared), t < 1 - epsilon / sqrt(squared),
                       simd_length_squared(point - (a + direction * t)) < epsilon * epsilon * 4 { along.append((t, point)) }
                }
                boundary += along.sorted { $0.0 < $1.0 }.map(\.1)
            }
            guard boundary.count >= 3 else { continue }
            let center = boundary.reduce(Point.zero, +) / Double(boundary.count)
            for i in boundary.indices {
                let a = boundary[i], b = boundary[(i + 1) % boundary.count]
                guard simd_length(simd_cross(a - center, b - center)) > epsilon * epsilon else { continue }
                let base = UInt32(result.positions.count)
                result.positions += [Vec3(center), Vec3(a), Vec3(b)]
                result.colors += Array(repeating: polygon.color, count: 3)
                result.indices += [base, base + 1, base + 2]
            }
        }
        guard result.indices.count <= 120_000, result.volume > epsilon * epsilon * epsilon,
              result.positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw SolidError.invalid("The operation leaves no valid solid, or its result is too complex.")
        }
        return result
    }
}
