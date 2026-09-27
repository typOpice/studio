import Foundation
import simd

/// Roblox's terrain materials (Enum.Material's), with Roblox's colours. Air is empty;
/// Water isn't solid — characters swim in it.
enum TerrainMaterial: UInt8, CaseIterable, Identifiable, Codable {
    case air = 0, grass, leafyGrass, sand, ground, mud, rock, slate, basalt, sandstone, snow, ice, asphalt, water

    var id: UInt8 { rawValue }

    /// As Enum.Material names it.
    var name: String {
        switch self {
        case .air: return "Air"
        case .grass: return "Grass"
        case .leafyGrass: return "LeafyGrass"
        case .sand: return "Sand"
        case .ground: return "Ground"
        case .mud: return "Mud"
        case .rock: return "Rock"
        case .slate: return "Slate"
        case .basalt: return "Basalt"
        case .sandstone: return "Sandstone"
        case .snow: return "Snow"
        case .ice: return "Ice"
        case .asphalt: return "Asphalt"
        case .water: return "Water"
        }
    }

    init?(name: String) {
        guard let found = Self.allCases.first(where: { $0.name == name }) else { return nil }
        self = found
    }

    /// Roblox's default colours.
    var color: Vec3 {
        func rgb(_ r: Float, _ g: Float, _ b: Float) -> Vec3 { Vec3(r, g, b) / 255 }
        switch self {
        case .air: return .zero
        case .grass: return rgb(106, 127, 63)
        case .leafyGrass: return rgb(115, 132, 74)
        case .sand: return rgb(143, 126, 95)
        case .ground: return rgb(102, 92, 59)
        case .mud: return rgb(58, 46, 36)
        case .rock: return rgb(102, 108, 111)
        case .slate: return rgb(63, 127, 107)
        case .basalt: return rgb(30, 30, 37)
        case .sandstone: return rgb(137, 90, 71)
        case .snow: return rgb(195, 199, 218)
        case .ice: return rgb(129, 194, 224)
        case .asphalt: return rgb(115, 123, 107)
        case .water: return rgb(12, 84, 92)
        }
    }

    var isSolid: Bool { self != .air && self != .water }
}

/// 16 × 16 × 16 voxels, each 4 studs: what each is made of, and how full it is (0–255,
/// half full or more is inside). Its stamp changes with every edit, so a copy can tell
/// it's out of date without looking at the voxels.
struct TerrainChunk: Equatable {
    static let side = 16
    static let count = side * side * side

    var materials = [UInt8](repeating: 0, count: count)
    var occupancy = [UInt8](repeating: 0, count: count)
    var stamp = 0
    /// Changes only when a voxel on its outside layer does: all a neighbour's mesh reads of it.
    var edgeStamp = 0

    static func index(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * side + y) * side + x }

    var isEmpty: Bool { !occupancy.contains { $0 > 0 } }

    static func == (a: TerrainChunk, b: TerrainChunk) -> Bool { a.stamp == b.stamp }

    /// Runs of (count, material, occupancy): flat ground and empty air come to almost nothing.
    func packed() -> Data {
        var bytes: [UInt8] = []
        var i = 0
        while i < Self.count {
            let m = materials[i], o = occupancy[i]
            var run = 1
            while i + run < Self.count, run < 65_535, materials[i + run] == m, occupancy[i + run] == o { run += 1 }
            bytes += [UInt8(run & 0xFF), UInt8(run >> 8), m, o]
            i += run
        }
        return Data(bytes)
    }

    init() {}

    init?(packed data: Data, stamp: Int) {
        let bytes = [UInt8](data)
        guard bytes.count % 4 == 0 else { return nil }
        var i = 0
        for run in stride(from: 0, to: bytes.count, by: 4) {
            let count = Int(bytes[run]) | Int(bytes[run + 1]) << 8
            guard i + count <= Self.count else { return nil }
            for j in i..<(i + count) {
                materials[j] = bytes[run + 2]
                occupancy[j] = bytes[run + 3]
            }
            i += count
        }
        guard i == Self.count else { return nil }
        self.stamp = stamp
        edgeStamp = stamp
    }

    static func isEdge(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        x == 0 || y == 0 || z == 0 || x == side - 1 || y == side - 1 || z == side - 1
    }
}

/// The Workspace's Terrain: voxels of material in chunks, as far as it goes, and how its
/// water looks. Two are equal when their chunks' stamps and settings are, which is cheap
/// enough for undo and for working out what to send joined players.
struct TerrainData: Equatable, Codable {
    typealias Key = SIMD3<Int32>

    static let voxel: Float = 4
    static var chunkStuds: Float { voxel * Float(TerrainChunk.side) }

    var chunks: [Key: TerrainChunk] = [:]
    var waterColor = Vec3(12, 84, 92) / 255
    var waterTransparency: Float = 0.3
    var waterWaveSize: Float = 0.15
    var waterWaveSpeed: Float = 10
    /// Terrain:SetMaterialColor, by material.
    var materialColors: [UInt8: Vec3] = [:]

    var isEmpty: Bool { chunks.isEmpty }

    func color(of material: TerrainMaterial) -> Vec3 { materialColors[material.rawValue] ?? material.color }

    /// A stamp no chunk has had before, on this machine.
    private static var stamps = 0
    static func nextStamp() -> Int {
        stamps += 1
        return stamps
    }

    init() {}

    // MARK: - Voxels

    static func chunkKey(_ voxel: SIMD3<Int32>) -> Key {
        let side = Int32(TerrainChunk.side)
        return Key(Self.floorDiv(voxel.x, side), Self.floorDiv(voxel.y, side), Self.floorDiv(voxel.z, side))
    }

    private static func floorDiv(_ a: Int32, _ b: Int32) -> Int32 { a >= 0 ? a / b : (a - b + 1) / b }

    static func local(_ voxel: SIMD3<Int32>) -> Int {
        let side = Int32(TerrainChunk.side)
        let l = voxel &- chunkKey(voxel) &* side
        return TerrainChunk.index(Int(l.x), Int(l.y), Int(l.z))
    }

    /// The voxel a point in the world is in.
    static func voxel(at point: Vec3) -> SIMD3<Int32> {
        SIMD3<Int32>((point / voxel).rounded(.down))
    }

    /// The middle of a voxel.
    static func centre(_ voxel: SIMD3<Int32>) -> Vec3 { (Vec3(voxel) + 0.5) * Self.voxel }

    func material(_ voxel: SIMD3<Int32>) -> TerrainMaterial {
        guard let chunk = chunks[Self.chunkKey(voxel)] else { return .air }
        return TerrainMaterial(rawValue: chunk.materials[Self.local(voxel)]) ?? .air
    }

    /// How full, 0–1.
    func occupancy(_ voxel: SIMD3<Int32>) -> Float {
        guard let chunk = chunks[Self.chunkKey(voxel)] else { return 0 }
        return Float(chunk.occupancy[Self.local(voxel)]) / 255
    }

    /// How solid (0–1): water counts as nothing.
    func solidity(_ voxel: SIMD3<Int32>) -> Float {
        guard let chunk = chunks[Self.chunkKey(voxel)] else { return 0 }
        let i = Self.local(voxel)
        let m = chunk.materials[i]
        return m == 0 || m == TerrainMaterial.water.rawValue ? 0 : Float(chunk.occupancy[i]) / 255
    }

    /// Changes the voxels in a box, each through `body`, stamping the chunks that changed
    /// and dropping any left empty.
    mutating func edit(from low: SIMD3<Int32>, to high: SIMD3<Int32>,
                       _ body: (_ voxel: SIMD3<Int32>, _ material: inout TerrainMaterial, _ occupancy: inout Float) -> Void) {
        guard low.x <= high.x, low.y <= high.y, low.z <= high.z else { return }
        let lowKey = Self.chunkKey(low), highKey = Self.chunkKey(high)
        let side = Int32(TerrainChunk.side)
        for cz in lowKey.z...highKey.z {
            for cy in lowKey.y...highKey.y {
                for cx in lowKey.x...highKey.x {
                    let key = Key(cx, cy, cz)
                    var chunk = chunks[key] ?? TerrainChunk()
                    var changed = false, edgeChanged = false
                    let origin = key &* side
                    let from = simd_max(low, origin), to = simd_min(high, origin &+ (side - 1))
                    for z in from.z...to.z {
                        for y in from.y...to.y {
                            for x in from.x...to.x {
                                let v = SIMD3<Int32>(x, y, z)
                                let i = TerrainChunk.index(Int(x - origin.x), Int(y - origin.y), Int(z - origin.z))
                                var material = TerrainMaterial(rawValue: chunk.materials[i]) ?? .air
                                var occupancy = Float(chunk.occupancy[i]) / 255
                                body(v, &material, &occupancy)
                                occupancy = min(max(occupancy, 0), 1)
                                if material == .air || occupancy <= 0.001 { material = .air; occupancy = 0 }
                                let m = material.rawValue, o = UInt8((occupancy * 255).rounded())
                                if m != chunk.materials[i] || o != chunk.occupancy[i] {
                                    chunk.materials[i] = m
                                    chunk.occupancy[i] = o
                                    changed = true
                                    if !edgeChanged, TerrainChunk.isEdge(Int(x - origin.x), Int(y - origin.y), Int(z - origin.z)) {
                                        edgeChanged = true
                                    }
                                }
                            }
                        }
                    }
                    guard changed else { continue }
                    if chunk.isEmpty {
                        chunks[key] = nil
                    } else {
                        chunk.stamp = Self.nextStamp()
                        if edgeChanged || chunk.edgeStamp == 0 { chunk.edgeStamp = chunk.stamp }
                        chunks[key] = chunk
                    }
                }
            }
        }
    }

    /// The voxels whose middles lie within a box in the world, a voxel over on each side.
    static func voxels(covering low: Vec3, _ high: Vec3) -> (SIMD3<Int32>, SIMD3<Int32>) {
        (voxel(at: low) &- 1, voxel(at: high) &+ 1)
    }

    // MARK: - Filling shapes

    /// Fills a shape (its signed distance: below 0 inside) with a material, as Roblox's
    /// Fill… do: voxels well inside take the material; the edge is part-full, so the
    /// surface is smooth. Air carves the shape out.
    mutating func fill(bounds low: Vec3, _ high: Vec3, material: TerrainMaterial, distance: (Vec3) -> Float) {
        let (a, b) = Self.voxels(covering: low, high)
        edit(from: a, to: b) { voxel, current, occupancy in
            let inside = min(max(0.5 - distance(Self.centre(voxel)) / Self.voxel, 0), 1)
            guard inside > 0 else { return }
            if material == .air {
                occupancy = min(occupancy, 1 - inside)
            } else if inside >= 0.5 || inside > occupancy || current == .air {
                current = material
                occupancy = max(occupancy, inside)
            }
        }
    }

    mutating func fillBall(centre: Vec3, radius: Float, material: TerrainMaterial) {
        let r = Vec3(repeating: max(radius, 0))
        fill(bounds: centre - r, centre + r, material: material) { simd_distance($0, centre) - radius }
    }

    mutating func fillBlock(pose: Pose, size: Vec3, material: TerrainMaterial) {
        let half = size / 2
        let reach = Self.box(pose: pose, half: half)
        fill(bounds: reach.0, reach.1, material: material) { point in
            let q = simd_abs(pose.orientation.inverse.act(point - pose.position)) - half
            return simd_length(simd_max(q, .zero)) + min(max(q.x, q.y, q.z), 0)
        }
    }

    /// Standing along the pose's Y.
    mutating func fillCylinder(pose: Pose, height: Float, radius: Float, material: TerrainMaterial) {
        let half = Vec3(radius, height / 2, radius)
        let reach = Self.box(pose: pose, half: half)
        fill(bounds: reach.0, reach.1, material: material) { point in
            let local = pose.orientation.inverse.act(point - pose.position)
            let d = SIMD2(simd_length(SIMD2(local.x, local.z)) - radius, abs(local.y) - height / 2)
            return min(max(d.x, d.y), 0) + simd_length(simd_max(d, .zero))
        }
    }

    /// A wedge, as a WedgePart: the box cut by a slope from its top at the front (−Z) down
    /// to its bottom at the back (+Z).
    mutating func fillWedge(pose: Pose, size: Vec3, material: TerrainMaterial) {
        let half = size / 2
        let reach = Self.box(pose: pose, half: half)
        let slope = simd_normalize(Vec3(0, half.z, half.y))
        let offset = simd_dot(slope, Vec3(0, half.y, -half.z))
        fill(bounds: reach.0, reach.1, material: material) { point in
            let local = pose.orientation.inverse.act(point - pose.position)
            let q = simd_abs(local) - half
            let box = simd_length(simd_max(q, .zero)) + min(max(q.x, q.y, q.z), 0)
            return max(box, simd_dot(slope, local) - offset)
        }
    }

    /// FillRegion: every voxel whose middle is in the box, full.
    mutating func fillRegion(low: Vec3, high: Vec3, material: TerrainMaterial) {
        let a = Self.voxel(at: low + Self.voxel / 2), b = Self.voxel(at: high - Self.voxel / 2)
        edit(from: a, to: b) { _, current, occupancy in
            current = material
            occupancy = material == .air ? 0 : 1
        }
    }

    /// ReplaceMaterial: in the box, what's one material becomes another.
    mutating func replace(low: Vec3, high: Vec3, _ from: TerrainMaterial, with to: TerrainMaterial) {
        let a = Self.voxel(at: low + Self.voxel / 2), b = Self.voxel(at: high - Self.voxel / 2)
        edit(from: a, to: b) { _, current, occupancy in
            guard current == from, occupancy > 0 else { return }
            current = to
            if to == .air { occupancy = 0 }
        }
    }

    private static func box(pose: Pose, half: Vec3) -> (Vec3, Vec3) {
        var low = Vec3(repeating: .greatestFiniteMagnitude), high = -low
        for x in [-half.x, half.x] {
            for y in [-half.y, half.y] {
                for z in [-half.z, half.z] {
                    let p = pose.position + pose.orientation.act(Vec3(x, y, z))
                    low = simd_min(low, p)
                    high = simd_max(high, p)
                }
            }
        }
        return (low, high)
    }

    // MARK: - Brushes (Studio's Terrain Editor)

    enum Brush: String, CaseIterable, Identifiable {
        case add = "Add", subtract = "Subtract", grow = "Grow", erode = "Erode", smooth = "Smooth"
        case flatten = "Flatten", paint = "Paint"
        var id: String { rawValue }
    }

    /// One dab of a brush: a ball of `radius`, strongest in the middle. Add and Subtract
    /// fill or carve the ball outright; Grow and Erode build or wear surfaces a little
    /// at a time; Smooth evens them out; Flatten levels to the ball's middle; Paint
    /// changes what the surface is made of.
    mutating func brush(_ brush: Brush, centre: Vec3, radius: Float, strength: Float, material: TerrainMaterial) {
        let r = max(radius, Self.voxel / 2)
        switch brush {
        case .add: fillBall(centre: centre, radius: r, material: material)
        case .subtract: fillBall(centre: centre, radius: r, material: .air)
        default: break
        }
        guard brush != .add, brush != .subtract else { return }
        let (a, b) = Self.voxels(covering: centre - r, centre + r)
        let before = self
        let amount = min(max(strength, 0), 1)
        edit(from: a, to: b) { voxel, current, occupancy in
            let fall = max(0, 1 - simd_distance(Self.centre(voxel), centre) / r)
            guard fall > 0 else { return }
            let push = fall * amount
            switch brush {
            case .grow:
                // Only where there's something beside it to grow from.
                let beside = Self.neighbours(voxel).contains { before.solidity($0) > 0.3 }
                guard beside || occupancy > 0 else { return }
                if current == .air || current == .water { current = before.nearestSolid(to: voxel) ?? material }
                occupancy += push * 0.5
            case .erode:
                occupancy -= push * 0.5
            case .smooth:
                let around = Self.neighbours(voxel).map { before.solidity($0) }
                let mean = (around.reduce(0, +) + before.solidity(voxel)) / Float(around.count + 1)
                let target = mean
                if target > occupancy, current == .air { current = before.nearestSolid(to: voxel) ?? material }
                occupancy += (target - occupancy) * push
            case .flatten:
                // Full below the middle's height, empty above, blended by the brush.
                let height = Self.centre(voxel).y - centre.y
                let target = min(max(0.5 - height / Self.voxel, 0), 1)
                if target > occupancy, current == .air { current = before.nearestSolid(to: voxel) ?? material }
                occupancy += (target - occupancy) * push
            case .paint:
                if current.isSolid, occupancy > 0.05, push > 0.15 { current = material }
            default:
                break
            }
        }
    }

    private static func neighbours(_ v: SIMD3<Int32>) -> [SIMD3<Int32>] {
        [v &+ SIMD3(1, 0, 0), v &- SIMD3(1, 0, 0), v &+ SIMD3(0, 1, 0), v &- SIMD3(0, 1, 0),
         v &+ SIMD3(0, 0, 1), v &- SIMD3(0, 0, 1)]
    }

    /// The material of the solid voxel beside this one, if any: what grown terrain is made of.
    private func nearestSolid(to v: SIMD3<Int32>) -> TerrainMaterial? {
        let order = [v &- SIMD3(0, 1, 0)] + Self.neighbours(v)
        return order.map { material($0) }.first { $0.isSolid }
    }

    // MARK: - Generate

    /// Studio's Generate: rolling land over a square `size` studs across centred on
    /// `centre`, from `seed` — grass on the hills, rock where it's steep or high, sand by
    /// the water, snow on the peaks — and water filling the low ground up to `waterLevel`.
    mutating func generate(centre: Vec3, size: Float, height: Float, waterLevel: Float?, seed: UInt32) {
        func hash(_ x: Int32, _ z: Int32) -> Float {
            var h = UInt32(bitPattern: x &* 374_761_393 &+ z &* 668_265_263) &+ seed &* 2_246_822_519
            h = (h ^ (h >> 13)) &* 1_274_126_177
            return Float(h & 0xFFFF) / 65535
        }
        func noise(_ x: Float, _ z: Float) -> Float {
            let ix = Int32(floor(x)), iz = Int32(floor(z))
            let fx = x - floor(x), fz = z - floor(z)
            let sx = fx * fx * (3 - 2 * fx), sz = fz * fz * (3 - 2 * fz)
            let top = hash(ix, iz) + (hash(ix + 1, iz) - hash(ix, iz)) * sx
            let bottom = hash(ix, iz + 1) + (hash(ix + 1, iz + 1) - hash(ix, iz + 1)) * sx
            return top + (bottom - top) * sz
        }
        func ground(_ x: Float, _ z: Float) -> Float {
            var total: Float = 0, amplitude: Float = 1, frequency: Float = 1 / 140, weight: Float = 0
            for _ in 0..<5 {
                total += noise(x * frequency, z * frequency) * amplitude
                weight += amplitude
                amplitude *= 0.5
                frequency *= 2
            }
            // Low in the middle of its range more often: valleys to fill with water.
            let n = total / weight
            return centre.y + pow(n, 1.6) * height
        }
        let half = size / 2
        let low = Self.voxel(at: centre - Vec3(half, 0, half))
        let high = Self.voxel(at: centre + Vec3(half, 0, half))
        let bottom = Int32((centre.y / Self.voxel).rounded(.down)) - 1
        let top = Int32(((centre.y + height) / Self.voxel).rounded(.up)) + 1
        let water = waterLevel
        edit(from: SIMD3(low.x, bottom, low.z), to: SIMD3(high.x, top, high.z)) { voxel, current, occupancy in
            let c = Self.centre(voxel)
            let surface = ground(c.x, c.z)
            let inside = min(max(0.5 + (surface - c.y) / Self.voxel, 0), 1)
            let bottom = c.y - Self.voxel / 2
            if let water, bottom < water, inside < 0.5 {
                // Under the water line and not ground: water, right to the shore, as full
                // as the water line is high in it.
                current = .water
                occupancy = min((water - bottom) / Self.voxel, 1)
            } else if inside > 0 {
                let slope = abs(ground(c.x + 4, c.z) - ground(c.x - 4, c.z)) + abs(ground(c.x, c.z + 4) - ground(c.x, c.z - 4))
                let rise = (surface - centre.y) / max(height, 1)
                if let water, surface < water + 2 { current = .sand }
                else if rise > 0.85 { current = .snow }
                else if slope > 7 || rise > 0.7 { current = .rock }
                else if surface - c.y > 8 { current = .ground }
                else { current = .grass }
                occupancy = inside
            } else if let water, c.y < water {
                current = .water
                occupancy = 1
            }
        }
    }

    // MARK: - Asking

    /// Where the water's surface is above a point in water, if it's in any: the top water
    /// voxel's bottom, and as high again as it's full.
    func waterSurface(at point: Vec3) -> Float? {
        var v = Self.voxel(at: point)
        guard material(v) == .water, occupancy(v) > 0 else { return nil }
        var steps = 0
        while material(v &+ SIMD3(0, 1, 0)) == .water, occupancy(v &+ SIMD3(0, 1, 0)) > 0, steps < 256 {
            v &+= SIMD3(0, 1, 0)
            steps += 1
        }
        let surface = Float(v.y) * Self.voxel + occupancy(v) * Self.voxel
        return point.y <= surface ? surface : nil
    }

    /// What the terrain is made of at a point on (or just in) its surface.
    func materialNear(_ point: Vec3) -> TerrainMaterial {
        let v = Self.voxel(at: point)
        var best: (TerrainMaterial, Float) = (.air, 0)
        for dz in -1...1 {
            for dy in -1...1 {
                for dx in -1...1 {
                    let n = v &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))
                    let solid = solidity(n)
                    let closeness = solid - simd_distance(Self.centre(n), point) / 40
                    if solid > 0.2, closeness > best.1 { best = (material(n), closeness) }
                }
            }
        }
        return best.0
    }

    // MARK: - Saving

    private enum CodingKeys: String, CodingKey {
        case chunks, waterColor, waterTransparency, waterWaveSize, waterWaveSpeed, materialColors
    }

    private struct PackedChunk: Codable {
        var at: [Int32]
        var voxels: Data
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TerrainData()
        for packed in try c.decodeIfPresent([PackedChunk].self, forKey: .chunks) ?? [] where packed.at.count == 3 {
            guard let chunk = TerrainChunk(packed: packed.voxels, stamp: Self.nextStamp()), !chunk.isEmpty else { continue }
            chunks[Key(packed.at[0], packed.at[1], packed.at[2])] = chunk
        }
        waterColor = try c.decodeIfPresent(Vec3.self, forKey: .waterColor) ?? d.waterColor
        waterTransparency = try c.decodeIfPresent(Float.self, forKey: .waterTransparency) ?? d.waterTransparency
        waterWaveSize = try c.decodeIfPresent(Float.self, forKey: .waterWaveSize) ?? d.waterWaveSize
        waterWaveSpeed = try c.decodeIfPresent(Float.self, forKey: .waterWaveSpeed) ?? d.waterWaveSpeed
        let colours = try c.decodeIfPresent([String: Vec3].self, forKey: .materialColors) ?? [:]
        for (name, colour) in colours { if let m = TerrainMaterial(name: name) { materialColors[m.rawValue] = colour } }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let ordered = chunks.keys.sorted { ($0.z, $0.y, $0.x) < ($1.z, $1.y, $1.x) }
        try c.encode(ordered.map { PackedChunk(at: [$0.x, $0.y, $0.z], voxels: chunks[$0]!.packed()) }, forKey: .chunks)
        try c.encode(waterColor, forKey: .waterColor)
        try c.encode(waterTransparency, forKey: .waterTransparency)
        try c.encode(waterWaveSize, forKey: .waterWaveSize)
        try c.encode(waterWaveSpeed, forKey: .waterWaveSpeed)
        if !materialColors.isEmpty {
            var named: [String: Vec3] = [:]
            for (raw, colour) in materialColors { if let m = TerrainMaterial(rawValue: raw) { named[m.name] = colour } }
            try c.encode(named, forKey: .materialColors)
        }
    }

}

/// What changed in the terrain, as the host sends it to joined players: the chunks made or
/// changed (whole), those gone, and the water and colours.
struct TerrainPatch: Codable, Equatable {
    struct Chunk: Codable, Equatable {
        var at: [Int32]
        var voxels: Data
    }
    var chunks: [Chunk] = []
    var removed: [[Int32]] = []
    var waterColor: Vec3
    var waterTransparency: Float
    var waterWaveSize: Float
    var waterWaveSpeed: Float
    var materialColors: [UInt8: Vec3]

    /// From what was sent to how it is now; nil when nothing changed.
    static func between(_ sent: TerrainData, _ now: TerrainData) -> TerrainPatch? {
        guard sent != now else { return nil }
        var patch = TerrainPatch(waterColor: now.waterColor, waterTransparency: now.waterTransparency,
                                 waterWaveSize: now.waterWaveSize, waterWaveSpeed: now.waterWaveSpeed,
                                 materialColors: now.materialColors)
        for (key, chunk) in now.chunks where sent.chunks[key]?.stamp != chunk.stamp {
            patch.chunks.append(Chunk(at: [key.x, key.y, key.z], voxels: chunk.packed()))
        }
        for key in sent.chunks.keys where now.chunks[key] == nil { patch.removed.append([key.x, key.y, key.z]) }
        return patch
    }

    /// Brings a joined player's terrain up to the host's, stamping its chunks anew.
    func apply(to terrain: inout TerrainData) {
        for chunk in chunks where chunk.at.count == 3 {
            let key = TerrainData.Key(chunk.at[0], chunk.at[1], chunk.at[2])
            terrain.chunks[key] = TerrainChunk(packed: chunk.voxels, stamp: TerrainData.nextStamp())
        }
        for key in removed where key.count == 3 { terrain.chunks[TerrainData.Key(key[0], key[1], key[2])] = nil }
        terrain.waterColor = waterColor
        terrain.waterTransparency = waterTransparency
        terrain.waterWaveSize = waterWaveSize
        terrain.waterWaveSpeed = waterWaveSpeed
        terrain.materialColors = materialColors
    }
}
