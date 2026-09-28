import Foundation
import simd

/// What PathfindingService finds its way through: the world seen from above as a grid of
/// 2-stud cells, each holding the solid spans of the parts over it (from exact rays, so
/// wedges and balls count as they are). A floor is the top of a span — or the ground at
/// 0 — with room above it for the agent; a step is a walk if it rises no more than the
/// character can step (2 studs), a jump if no more than it can jump. Water deeper than
/// the agent can wade is swum, at its surface; a TrussPart can be climbed (if the agent
/// can climb); a gap of up to three cells can be jumped across.
///
/// The grid is kept up to date part by part: before each search, parts that moved,
/// appeared, went or stopped colliding are drawn again, so one zombie walking about
/// costs its own cells, not the world's.
final class NavigationGrid {
    struct Agent: Equatable {
        var radius: Float = 2
        var height: Float = 5
        var canJump = true
        var spacing: Float = 4
        /// Cost multipliers by material name ("Water", "Neon", …); infinity keeps out.
        var costs: [String: Float] = [:]
        /// Up TrussParts (Roblox's AgentCanClimb: off unless asked for).
        var canClimb = false
    }

    enum Action: String { case walk = "Walk", jump = "Jump" }

    struct Waypoint: Equatable {
        var position: Vec3
        var action: Action
        /// "Water" in water (swum or waded), "Climb" at the top of a climb, "" otherwise.
        var label = ""
    }

    enum Status: String {
        case success = "Success", noPath = "NoPath"
        case startNotEmpty = "FailStartNotEmpty", finishNotEmpty = "FailFinishNotEmpty"
    }

    static let cell: Float = 2
    static let step: Float = CharacterController.stepHeight
    /// A standing jump's rise (jump 50, gravity 196.2: about 6.4), with a little to spare.
    static let jump: Float = 6
    /// The furthest a path drops in one step.
    static let drop: Float = 30
    /// How far a jump carries across a gap, in cells (6 studs: a run and a jump, with
    /// a little to spare).
    static let reach = 3
    /// How much harder a stud climbed is than one walked.
    static let climbCost: Float = 1.5
    /// The most a grid spans on a side, in cells.
    static let largest = 1024

    private struct Span {
        let part: UUID
        let bottom: Float
        let top: Float
        let material: String
        var truss = false
    }

    private struct Signature: Equatable {
        let position: Vec3, size: Vec3, orientation: simd_quatf, shape: PartShape, material: PartMaterial
        /// A MeshPart's mesh: a terrain chunk made again keeps its place but not its triangles.
        let mesh: UUID?
    }

    private(set) var origin = SIMD2<Float>(0, 0)
    private(set) var width = 0, depth = 0
    private var spans: [[Span]] = []
    private var footprints: [UUID: (signature: Signature, cells: [Int])] = [:]
    /// How many parts it has drawn (`--soak` watches it).
    var partsDrawn: Int { footprints.count }
    /// Each cell's solid intervals, merged, and the material on top of each; made when asked.
    private var merged: [[(bottom: Float, top: Float, material: String)]?] = []
    var ground = true
    /// The Terrain's water: its surface above a point in it, if the point is in any.
    var terrainWater: ((Vec3) -> Float?)?
    /// The water parts, as of the last update.
    private var waterParts: [Part] = []

    // MARK: - Keeping up with the world

    /// Brings the grid up to the parts as they are now.
    func update(_ parts: [Part]) {
        waterParts = parts.filter { $0.inWorld && $0.material == .water }
        let solid = parts.filter(\.isSolid)
        if width == 0 || solid.contains(where: { !covers(bounds(of: $0)) }) { rebuild(around: solid) }
        var seen = Set<UUID>()
        for part in solid {
            seen.insert(part.id)
            let signature = Signature(position: part.position, size: part.size, orientation: part.orientation,
                                      shape: part.shape, material: part.material, mesh: part.mesh?.asset)
            if let known = footprints[part.id], known.signature == signature { continue }
            erase(part.id)
            draw(part, signature)
        }
        for id in footprints.keys where !seen.contains(id) { erase(id) }
    }

    private func bounds(of part: Part) -> (min: Vec3, max: Vec3) {
        let half = part.size / 2
        var low = Vec3(repeating: .greatestFiniteMagnitude), high = -low
        for x in [-half.x, half.x] {
            for y in [-half.y, half.y] {
                for z in [-half.z, half.z] {
                    let corner = part.position + part.orientation.act(Vec3(x, y, z))
                    low = simd_min(low, corner)
                    high = simd_max(high, corner)
                }
            }
        }
        return (low, high)
    }

    private func covers(_ box: (min: Vec3, max: Vec3)) -> Bool {
        let far = origin + SIMD2(Float(width), Float(depth)) * Self.cell
        return box.min.x >= origin.x && box.min.z >= origin.y && box.max.x <= far.x && box.max.z <= far.y
    }

    /// A grid over everything solid, with room round it, as big as allowed.
    private func rebuild(around parts: [Part]) {
        var low = SIMD2<Float>(-64, -64), high = SIMD2<Float>(64, 64)
        for part in parts {
            let box = bounds(of: part)
            low = simd_min(low, SIMD2(box.min.x, box.min.z))
            high = simd_max(high, SIMD2(box.max.x, box.max.z))
        }
        low -= 32
        high += 32
        let most = Float(Self.largest) * Self.cell
        let centre = (low + high) / 2
        low = simd_max(low, centre - most / 2)
        high = simd_min(high, centre + most / 2)
        origin = (low / Self.cell).rounded(.down) * Self.cell
        width = Int(((high.x - origin.x) / Self.cell).rounded(.up))
        depth = Int(((high.y - origin.y) / Self.cell).rounded(.up))
        spans = Array(repeating: [], count: width * depth)
        merged = Array(repeating: nil, count: width * depth)
        footprints = [:]
    }

    private func erase(_ id: UUID) {
        guard let known = footprints.removeValue(forKey: id) else { return }
        for cell in known.cells {
            spans[cell].removeAll { $0.part == id }
            merged[cell] = nil
        }
    }

    /// The part's solid span over each cell it covers: straight down and straight up at
    /// the cell's centre and at the point of the cell nearest the part, so a thin post
    /// between centres still counts.
    private func draw(_ part: Part, _ signature: Signature) {
        let box = bounds(of: part)
        let low = cellCoordinates(SIMD2(box.min.x, box.min.z)), high = cellCoordinates(SIMD2(box.max.x, box.max.z))
        var cells: [Int] = []
        let material = part.material.rawValue
        let (x0, x1, z0, z1) = (max(low.x, 0), min(high.x, width - 1), max(low.z, 0), min(high.z, depth - 1))
        guard x0 <= x1, z0 <= z1 else {
            footprints[part.id] = (signature, [])
            return
        }
        for z in z0...z1 {
            for x in x0...x1 {
                let corner = origin + SIMD2(Float(x), Float(z)) * Self.cell
                let centre = corner + Self.cell / 2
                let nearest = simd_clamp(SIMD2(part.position.x, part.position.z), corner + 0.05, corner + Self.cell - 0.05)
                var bottom = Float.greatestFiniteMagnitude, top = -Float.greatestFiniteMagnitude
                for point in [centre, nearest] {
                    let down = Ray(origin: Vec3(point.x, box.max.y + 1, point.y), direction: Vec3(0, -1, 0))
                    let up = Ray(origin: Vec3(point.x, box.min.y - 1, point.y), direction: Vec3(0, 1, 0))
                    guard let fromAbove = Picking.intersect(ray: down, part: part, exact: true),
                          let fromBelow = Picking.intersect(ray: up, part: part, exact: true) else { continue }
                    top = max(top, box.max.y + 1 - fromAbove)
                    bottom = min(bottom, box.min.y - 1 + fromBelow)
                }
                guard top >= bottom else { continue }
                let index = z * width + x
                spans[index].append(Span(part: part.id, bottom: bottom, top: top, material: material,
                                         truss: part.shape == .truss))
                merged[index] = nil
                cells.append(index)
            }
        }
        footprints[part.id] = (signature, cells)
    }

    private func cellCoordinates(_ point: SIMD2<Float>) -> (x: Int, z: Int) {
        let local = (point - origin) / Self.cell
        return (Int(local.x.rounded(.down)), Int(local.y.rounded(.down)))
    }

    private func centre(_ index: Int) -> SIMD2<Float> {
        origin + (SIMD2(Float(index % width), Float(index / width)) + 0.5) * Self.cell
    }

    // MARK: - Floors

    private func intervals(_ index: Int) -> [(bottom: Float, top: Float, material: String)] {
        // Without what the search is ignoring (never kept: it's this search's alone).
        if !ignoring.isEmpty, spans[index].contains(where: { ignoring.contains($0.part) }) {
            return merge(spans[index].filter { !ignoring.contains($0.part) })
        }
        if let known = merged[index] { return known }
        let list = merge(spans[index])
        merged[index] = list
        return list
    }

    private func merge(_ cell: [Span]) -> [(bottom: Float, top: Float, material: String)] {
        var list: [(bottom: Float, top: Float, material: String)] = []
        for span in cell.sorted(by: { $0.bottom < $1.bottom }) {
            if let last = list.last, span.bottom <= last.top + 0.05 {
                if span.top > last.top { list[list.count - 1] = (last.bottom, span.top, span.material) }
            } else {
                list.append((span.bottom, span.top, span.material))
            }
        }
        return list
    }

    /// Parts the search leaves out: those the start is inside — the agent's own body, or
    /// whatever it's stuck in.
    private var ignoring: Set<UUID> = []

    private func containing(_ point: Vec3) -> Set<UUID> {
        let (x, z) = cellCoordinates(SIMD2(point.x, point.z))
        guard x >= 0, z >= 0, x < width, z < depth else { return [] }
        var inside = Set<UUID>()
        for span in spans[z * width + x] where !inside.contains(span.part) {
            guard let shape = footprints[span.part]?.signature else { continue }
            let local = shape.orientation.inverse.act(point - shape.position)
            if all(simd_abs(local) .<= shape.size / 2 + 0.25) { inside.insert(span.part) }
        }
        return inside
    }

    /// Remembered through one search: each cell's floors, and which are clear.
    private var floorsSeen: [Int: [(height: Float, material: String)]] = [:]
    private var clearSeen: [Node: Bool] = [:]
    /// Floors that are a water's surface, swum (getting out onto land is a jump).
    private var swum: Set<Node> = []

    /// Where the agent could stand in a cell: each floor's height and material, if there's
    /// room for it above.
    private func floors(_ index: Int, _ agent: Agent) -> [(height: Float, material: String)] {
        if let known = floorsSeen[index] { return known }
        let found = standing(index, agent)
        floorsSeen[index] = found
        return found
    }

    private func standing(_ index: Int, _ agent: Agent) -> [(height: Float, material: String)] {
        let solid = intervals(index)
        var found: [(height: Float, material: String)] = []
        if ground, solid.first.map({ $0.bottom > 0.05 }) ?? true {
            if room(above: 0, in: solid, agent) { found.append((0, "Ground")) }
        }
        for interval in solid where interval.top > -50 {
            if room(above: interval.top, in: solid, agent) { found.append((interval.top, interval.material)) }
        }
        guard terrainWater != nil || !waterParts.isEmpty else { return found }
        // In water: waded where it's shallow (its material is Water, for Costs), swum at
        // the surface where it's deeper than half the agent — as the character swims.
        let c = centre(index)
        var wet: [(height: Float, material: String)] = []
        for floor in found {
            guard let surface = waterSurface(at: Vec3(c.x, floor.height + 0.5, c.y)) else {
                wet.append(floor)
                continue
            }
            if surface - floor.height <= agent.height / 2 {
                wet.append((floor.height, "Water"))
            } else if room(above: surface, in: solid, agent), !wet.contains(where: { abs($0.height - surface) < 0.05 }) {
                wet.append((surface, "Water"))
                swum.insert(Node(cell: index, floor: surface))
            }
        }
        return wet
    }

    /// The surface of the water a point is in (a water part's, or the Terrain's), if any.
    private func waterSurface(at point: Vec3) -> Float? {
        var surface: Float?
        for part in waterParts {
            let local = part.orientation.inverse.act(point - part.position)
            let h = part.size * 0.5
            guard abs(local.x) <= h.x, abs(local.y) <= h.y, abs(local.z) <= h.z else { continue }
            let top = part.position.y + abs(part.orientation.act(Vec3(0, h.y, 0)).y)
            surface = max(surface ?? top, top)
        }
        if let terrainWater, let top = terrainWater(point) { surface = max(surface ?? top, top) }
        return surface
    }

    private func room(above floor: Float, in solid: [(bottom: Float, top: Float, material: String)], _ agent: Agent) -> Bool {
        !solid.contains { $0.bottom < floor + agent.height && $0.top > floor + 0.05 }
    }

    /// Whether the agent's body, standing at `floor` in this cell, has room all round.
    private func clear(_ index: Int, floor: Float, _ agent: Agent) -> Bool {
        let node = Node(cell: index, floor: floor)
        if let known = clearSeen[node] { return known }
        let answer = roomAround(index, floor: floor, agent)
        clearSeen[node] = answer
        return answer
    }

    /// Room for the body: nothing between a step above the floor and the top of the
    /// agent's head nearer the cell's centre than its radius (a quarter-stud of give),
    /// measured to each part's own box rather than to the cells it touches — but for a
    /// mesh (a MeshPart, the Terrain's chunks), whose box can hold a whole lake, to the
    /// cell its span is in.
    private func roomAround(_ index: Int, floor: Float, _ agent: Agent) -> Bool {
        let reach = Int((agent.radius / Self.cell).rounded(.up))
        let x = index % width, z = index / width
        let c = centre(index)
        let point = Vec3(c.x, 0, c.y)
        var checked = Set<UUID>()
        for dz in -reach...reach {
            for dx in -reach...reach {
                let nx = x + dx, nz = z + dz
                guard nx >= 0, nz >= 0, nx < width, nz < depth else { return false }
                for span in spans[nz * width + nx] where !ignoring.contains(span.part) {
                    // Beside the feet, anything below a step is fine to stand next to.
                    guard span.bottom < floor + agent.height, span.top > floor + Self.step,
                          let shape = footprints[span.part]?.signature else { continue }
                    if shape.mesh != nil {
                        let corner = origin + SIMD2(Float(nx), Float(nz)) * Self.cell
                        let flat = SIMD2(point.x, point.z)
                        if simd_distance(simd_clamp(flat, corner, corner + Self.cell), flat) < agent.radius - 0.25 { return false }
                        continue
                    }
                    guard checked.insert(span.part).inserted else { continue }
                    if distance(from: point, to: shape) < agent.radius - 0.25 { return false }
                }
            }
        }
        return true
    }

    /// How far a point is from a part's box, across the ground.
    private func distance(from point: Vec3, to shape: Signature) -> Float {
        let local = shape.orientation.inverse.act(Vec3(point.x, shape.position.y, point.z) - shape.position)
        let half = shape.size / 2
        let outside = local - simd_clamp(local, -half, half)
        return simd_length(outside)
    }

    // MARK: - Searching

    private struct Node: Hashable {
        let cell: Int
        let floor: Float
    }

    /// The floor a point stands on (the highest not far above it), or the nearest one
    /// that's clear within a few cells.
    private func place(_ point: Vec3, _ agent: Agent) -> Node? {
        // The floor stood on: the highest not above the point (with a stud to spare).
        let (x, z) = cellCoordinates(SIMD2(point.x, point.z))
        guard x >= 0, z >= 0, x < width, z < depth else { return nil }
        for ring in 0...4 {
            var best: (node: Node, score: Float)?
            for dz in -ring...ring {
                for dx in -ring...ring where max(abs(dx), abs(dz)) == ring {
                    let nx = x + dx, nz = z + dz
                    guard nx >= 0, nz >= 0, nx < width, nz < depth else { continue }
                    let index = nz * width + nx
                    for floor in floors(index, agent) where floor.height <= point.y + 1 {
                        guard clear(index, floor: floor.height, agent) else { continue }
                        let score = (point.y + 1 - floor.height) + Float(ring) * Self.cell
                        if best == nil || score < best!.score { best = (Node(cell: index, floor: floor.height), score) }
                    }
                }
            }
            if let best { return best.node }
        }
        return nil
    }

    private func cost(of material: String, _ agent: Agent) -> Float {
        agent.costs[material] ?? agent.costs[material.capitalized] ?? 1
    }

    /// The way from `start` to `finish`, as waypoints `spacing` apart: the start first,
    /// the finish last, a jump marked on the waypoint it jumps up to.
    func path(from start: Vec3, to finish: Vec3, agent: Agent, budget: Int = 60_000) -> (Status, [Waypoint]) {
        floorsSeen = [:]
        clearSeen = [:]
        swum = []
        ignoring = containing(start)
        defer {
            floorsSeen = [:]
            clearSeen = [:]
            swum = []
            ignoring = []
        }
        guard width > 0, let from = place(start, agent) else { return (.startNotEmpty, []) }
        guard let to = place(finish, agent) else { return (.finishNotEmpty, []) }
        // Searched within a box round both ends.
        let a = cellCoordinates(SIMD2(start.x, start.z)), b = cellCoordinates(SIMD2(finish.x, finish.z))
        let margin = 48
        let box = (minX: max(min(a.x, b.x) - margin, 0), maxX: min(max(a.x, b.x) + margin, width - 1),
                   minZ: max(min(a.z, b.z) - margin, 0), maxZ: min(max(a.z, b.z) + margin, depth - 1))
        let goal = centre(to.cell)
        func estimate(_ node: Node) -> Float {
            let d = simd_abs(centre(node.cell) - goal)
            return (max(d.x, d.y) - min(d.x, d.y)) + min(d.x, d.y) * 1.4142
        }
        var open = Heap<Node>()
        var best: [Node: Float] = [from: 0]
        var came: [Node: Node] = [:]
        var jumped: Set<Node> = []
        var climbed: Set<Node> = []
        open.push(from, estimate(from))
        var expanded = 0
        var reached = false
        while let (node, score) = open.pop() {
            // Pushed again since with a better score: this one is stale.
            if score > (best[node] ?? .greatestFiniteMagnitude) + estimate(node) + 0.001 { continue }
            if node == to { reached = true; break }
            expanded += 1
            if expanded > budget { break }
            let here = best[node] ?? 0
            let x = node.cell % width, z = node.cell / width
            for (dx, dz) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)] {
                let nx = x + dx, nz = z + dz
                guard nx >= box.minX, nx <= box.maxX, nz >= box.minZ, nz <= box.maxZ else { continue }
                let index = nz * width + nx
                // No cutting corners past something in the way.
                if dx != 0 && dz != 0 {
                    let side1 = z * width + nx, side2 = nz * width + x
                    guard canStep(from: node.floor, into: side1, agent) != nil,
                          canStep(from: node.floor, into: side2, agent) != nil else { continue }
                }
                guard var (floor, jump, material) = canStep(from: node.floor, into: index, agent) else { continue }
                let weight = cost(of: material, agent)
                guard weight.isFinite else { continue }
                let next = Node(cell: index, floor: floor)
                // Out of the water onto land: a swimmer climbs out with a jump.
                if swum.contains(node), !swum.contains(next), floor >= node.floor - Self.step { jump = true }
                floor = next.floor
                let length = (dx != 0 && dz != 0 ? 1.4142 : 1) * Self.cell
                let total = here + length * weight + (jump ? Self.cell * 2 : 0)
                if total < best[next] ?? .greatestFiniteMagnitude {
                    best[next] = total
                    came[next] = node
                    if jump { jumped.insert(next) } else { jumped.remove(next) }
                    climbed.remove(next)
                    open.push(next, total + estimate(next))
                }
            }
            // Up a truss beside: to its top, or the ledge it leads to.
            if agent.canClimb {
                for (next, height) in climbs(from: node, agent) {
                    let weight = cost(of: floors(next.cell, agent).first { $0.height == next.floor }?.material ?? "", agent)
                    guard weight.isFinite, box.minX...box.maxX ~= next.cell % width, box.minZ...box.maxZ ~= next.cell / width
                    else { continue }
                    let total = here + height * Self.climbCost + Self.cell * weight
                    if total < best[next] ?? .greatestFiniteMagnitude {
                        best[next] = total
                        came[next] = node
                        jumped.remove(next)
                        climbed.insert(next)
                        open.push(next, total + estimate(next))
                    }
                }
            }
            // A jump carries you further than a step: up onto something from a cell
            // beyond the one beside it, which a wide agent can't stand in.
            guard agent.canJump else { continue }
            // Across a gap: over cells with nothing to stand on near this height, to a floor
            // no higher than a step, with nothing in the way of the jump.
            for (dx, dz) in Self.gapLeaps {
                let nx = x + dx, nz = z + dz
                guard nx >= box.minX, nx <= box.maxX, nz >= box.minZ, nz <= box.maxZ,
                      let floor = leapAcross(from: node.floor, at: (x, z), by: (dx, dz), agent) else { continue }
                let next = Node(cell: nz * width + nx, floor: floor.height)
                let weight = cost(of: floor.material, agent)
                guard weight.isFinite else { continue }
                let total = here + simd_length(SIMD2(Float(dx), Float(dz))) * Self.cell * weight + Self.cell * 3
                if total < best[next] ?? .greatestFiniteMagnitude {
                    best[next] = total
                    came[next] = node
                    jumped.insert(next)
                    climbed.remove(next)
                    open.push(next, total + estimate(next))
                }
            }
            for (dx, dz) in Self.leaps {
                let nx = x + dx, nz = z + dz
                guard nx >= box.minX, nx <= box.maxX, nz >= box.minZ, nz <= box.maxZ else { continue }
                let index = nz * width + nx
                guard let floor = leap(from: node.floor, at: (x, z), by: (dx, dz), agent) else { continue }
                let next = Node(cell: index, floor: floor.height)
                let weight = cost(of: floor.material, agent)
                guard weight.isFinite else { continue }
                let total = here + simd_length(SIMD2(Float(dx), Float(dz))) * Self.cell * weight + Self.cell * 2
                if total < best[next] ?? .greatestFiniteMagnitude {
                    best[next] = total
                    came[next] = node
                    jumped.insert(next)
                    climbed.remove(next)
                    open.push(next, total + estimate(next))
                }
            }
        }
        guard reached else { return (.noPath, []) }
        var nodes = [to]
        while let previous = came[nodes.last!] { nodes.append(previous) }
        nodes.reverse()
        return (.success, waypoints(nodes, jumped: jumped, climbed: climbed, start: start, finish: finish, agent: agent))
    }

    /// Jumps across gaps: two or three cells straight, or near enough.
    private static let gapLeaps: [(Int, Int)] = {
        var list: [(Int, Int)] = []
        for dz in -reach...reach {
            for dx in -reach...reach where max(abs(dx), abs(dz)) >= 2 {
                if Float(dx * dx + dz * dz) <= Float(reach * reach) + 0.5 { list.append((dx, dz)) }
            }
        }
        return list
    }()

    /// Where a jump across a gap lands: a clear floor no higher than a step above (and not
    /// far below), when the first cell on the way has nothing to stand on near this
    /// height, and nothing stands up in the way of the jump.
    private func leapAcross(from height: Float, at cell: (x: Int, z: Int), by offset: (x: Int, z: Int),
                            _ agent: Agent) -> (height: Float, material: String)? {
        let length = simd_length(SIMD2(Float(offset.x), Float(offset.z)))
        let direction = SIMD2(Float(offset.x), Float(offset.z)) / length
        // The cells passed over, the first beside where it jumps from.
        var between: [Int] = []
        var t: Float = 0.75
        while t < length - 0.5 {
            let at = SIMD2(Float(cell.x), Float(cell.z)) + direction * t
            let index = Int(at.y.rounded()) * width + Int(at.x.rounded())
            if index != cell.z * width + cell.x, !between.contains(index) { between.append(index) }
            t += 0.5
        }
        guard let first = between.first, first >= 0, first < spans.count else { return nil }
        // Something to walk on beside: no need to jump.
        if floors(first, agent).contains(where: { abs($0.height - height) <= Self.step && $0.material != "Water" }) { return nil }
        let index = (cell.z + offset.z) * width + cell.x + offset.x
        for floor in floors(index, agent) where floor.material != "Water" {
            let rise = floor.height - height
            guard rise <= Self.step, rise >= -Self.drop, clear(index, floor: floor.height, agent) else { continue }
            // The jump's arc, about the agent's height above the higher end, is clear.
            let low = max(height, floor.height) + 0.1, high = max(height, floor.height) + agent.height + 3
            let open = between.allSatisfy { cell in
                cell >= 0 && cell < spans.count && intervals(cell).allSatisfy { $0.top <= low || $0.bottom >= high }
            }
            if open { return floor }
        }
        return nil
    }

    /// Climbs from a floor: up a truss within the agent's reach (as near as it can stand),
    /// from its foot to the top of it or to a floor beside its top (the ledge it leans
    /// on) — and how high.
    private func climbs(from node: Node, _ agent: Agent) -> [(Node, Float)] {
        let x = node.cell % width, z = node.cell / width
        let near = Int((agent.radius / Self.cell).rounded(.up)) + 1
        var found: [(Node, Float)] = []
        for dz in -near...near {
          for dx in -near...near where dx != 0 || dz != 0 {
            let tx = x + dx, tz = z + dz
            guard tx >= 0, tz >= 0, tx < width, tz < depth else { continue }
            let trussCell = tz * width + tx
            for span in spans[trussCell] where span.truss && !ignoring.contains(span.part)
                && span.bottom <= node.floor + Self.step && span.top > node.floor + Self.step {
                let top = span.top
                // Onto the truss itself…
                if floors(trussCell, agent).contains(where: { abs($0.height - top) < 0.05 }), clear(trussCell, floor: top, agent) {
                    found.append((Node(cell: trussCell, floor: top), top - node.floor))
                }
                // …or off it at the top, onto what's beside.
                for (ex, ez) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)] {
                    let lx = tx + ex, lz = tz + ez
                    guard lx >= 0, lz >= 0, lx < width, lz < depth, lz * width + lx != node.cell else { continue }
                    let ledge = lz * width + lx
                    for floor in floors(ledge, agent) where abs(floor.height - top) <= Self.step
                        && floor.height > node.floor + Self.step && clear(ledge, floor: floor.height, agent) {
                        found.append((Node(cell: ledge, floor: floor.height), floor.height - node.floor))
                    }
                }
            }
          }
        }
        return found
    }

    private static let leaps = [(2, 0), (-2, 0), (0, 2), (0, -2), (2, 1), (2, -1), (-2, 1), (-2, -1),
                                (1, 2), (-1, 2), (1, -2), (-1, -2), (2, 2), (2, -2), (-2, 2), (-2, -2)]

    /// Where a jump two cells over lands: a floor above a step higher and within a jump,
    /// clear, with nothing in between taller than it.
    private func leap(from height: Float, at cell: (x: Int, z: Int), by offset: (x: Int, z: Int),
                      _ agent: Agent) -> (height: Float, material: String)? {
        let index = (cell.z + offset.z) * width + cell.x + offset.x
        let between = [(cell.x + offset.x / 2, cell.z + offset.z / 2),
                       (cell.x + (offset.x + offset.x.signum()) / 2, cell.z + (offset.z + offset.z.signum()) / 2)]
        for floor in floors(index, agent) {
            let rise = floor.height - height
            guard rise > Self.step, rise <= Self.jump, clear(index, floor: floor.height, agent) else { continue }
            let over = between.allSatisfy { x, z in
                intervals(z * width + x).allSatisfy { $0.top <= floor.height + 0.1 || $0.bottom >= height + agent.height }
            }
            if over { return floor }
        }
        return nil
    }

    /// Where a step into `index` from a floor at `height` lands: the best floor there
    /// (walkable first, then a jump up, then a drop), and whether it's a jump.
    private func canStep(from height: Float, into index: Int, _ agent: Agent) -> (Float, Bool, String)? {
        var choice: (Float, Bool, String, Float)?
        for floor in floors(index, agent) {
            let rise = floor.height - height
            let jump: Bool
            if rise <= Self.step && rise >= -Self.drop {
                jump = false
            } else if agent.canJump && rise > Self.step && rise <= Self.jump {
                jump = true
            } else {
                continue
            }
            guard clear(index, floor: floor.height, agent) else { continue }
            let score = abs(rise) + (jump ? 10 : 0)
            if choice == nil || score < choice!.3 { choice = (floor.height, jump, floor.material, score) }
        }
        return choice.map { ($0.0, $0.1, $0.2) }
    }

    /// The cells as a path: straightened where the way between is clear and level
    /// enough, then cut into waypoints `spacing` apart.
    private func waypoints(_ nodes: [Node], jumped: Set<Node>, climbed: Set<Node>, start: Vec3, finish: Vec3,
                           agent: Agent) -> [Waypoint] {
        func point(_ node: Node) -> Vec3 {
            let c = centre(node.cell)
            return Vec3(c.x, node.floor, c.y)
        }
        // Corners: the nodes the straight line can't skip.
        var corners: [(Vec3, Bool)] = [(Vec3(start.x, nodes[0].floor, start.z), false)]
        var climbTops: [Vec3] = []
        var anchor = 0
        var index = 1
        while index < nodes.count {
            if jumped.contains(nodes[index]) || climbed.contains(nodes[index]) {
                if index - 1 > anchor { corners.append((point(nodes[index - 1]), false)) }
                corners.append((point(nodes[index]), jumped.contains(nodes[index])))
                if climbed.contains(nodes[index]) { climbTops.append(point(nodes[index])) }
                anchor = index
            } else if index - 1 > anchor && !straight(from: point(nodes[anchor]), to: point(nodes[index]), agent) {
                // The last that could be reached straight is a corner; carry on from there.
                corners.append((point(nodes[index - 1]), false))
                anchor = index - 1
                continue
            }
            index += 1
        }
        let end = Vec3(finish.x, nodes.last!.floor, finish.z)
        corners.append((end, false))
        // Evenly spaced along each straight stretch.
        var list = [Waypoint(position: corners[0].0, action: .walk)]
        for (position, jump) in corners.dropFirst() {
            let from = list.last!.position
            let flat = SIMD2(position.x - from.x, position.z - from.z)
            let length = simd_length(flat)
            let climb = climbTops.contains(position)
            if agent.spacing.isFinite && agent.spacing > 0 && length > agent.spacing * 1.5 && !jump && !climb {
                let pieces = Int((length / agent.spacing).rounded(.down))
                for piece in 1..<pieces {
                    let t = Float(piece) / Float(pieces)
                    list.append(Waypoint(position: from + (position - from) * t, action: .walk))
                }
            }
            if simd_distance(from, position) > 0.3 || jump {
                list.append(Waypoint(position: position, action: jump ? .jump : .walk, label: climb ? "Climb" : ""))
            }
        }
        if list.count == 1 { list.append(Waypoint(position: end, action: .walk)) }
        // In water: its label says so. (A straight stretch's waypoints are placed along
        // the line, so it's the floor nearest under each that counts.)
        for index in list.indices where list[index].label.isEmpty {
            let p = list[index].position
            let (x, z) = cellCoordinates(SIMD2(p.x, p.z))
            guard x >= 0, z >= 0, x < width, z < depth else { continue }
            let under = floors(z * width + x, agent).filter { abs($0.height - p.y) <= Self.step + 0.1 }
                .min { abs($0.height - p.y) < abs($1.height - p.y) }
            if under?.material == "Water" { list[index].label = "Water" }
        }
        return list
    }

    /// Whether the agent can walk straight from one point to another: every cell along the
    /// way has a clear floor within a step of the last.
    func straight(from a: Vec3, to b: Vec3, _ agent: Agent) -> Bool {
        let flat = SIMD2(b.x - a.x, b.z - a.z)
        let length = simd_length(flat)
        let samples = max(1, Int((length / (Self.cell * 0.5)).rounded(.up)))
        var height = a.y
        for sample in 0...samples {
            let t = Float(sample) / Float(samples)
            let at = SIMD2(a.x, a.z) + flat * t
            let (x, z) = cellCoordinates(at)
            guard x >= 0, z >= 0, x < width, z < depth else { return false }
            let index = z * width + x
            guard let (floor, jump, material) = canStep(from: height, into: index, agent), !jump,
                  cost(of: material, agent) <= 1 else { return false }
            height = floor
        }
        return abs(height - b.y) <= Self.step
    }

    /// The parts a search from `start` leaves out, for checking its path later.
    func ignored(from start: Vec3) -> Set<UUID> { containing(start) }

    /// The first waypoint (1-based) from `from` on whose way there is now blocked, or -1.
    /// `ignoring`: what the search left out (the agent's own body).
    func firstBlocked(_ waypoints: [Waypoint], from: Int, agent: Agent, ignoring left: Set<UUID> = []) -> Int {
        floorsSeen = [:]
        clearSeen = [:]
        ignoring = left
        defer {
            floorsSeen = [:]
            clearSeen = [:]
            ignoring = []
        }
        guard waypoints.count > 1 else { return -1 }
        for index in max(from, 1)..<waypoints.count {
            let a = waypoints[index - 1], b = waypoints[index]
            if b.action == .jump || b.label == "Climb" { continue }
            if !straight(from: a.position, to: b.position, agent) { return index + 1 }
        }
        return -1
    }
}

/// A binary min-heap of nodes by score, for the search.
private struct Heap<T> {
    private var items: [(node: T, score: Float)] = []

    mutating func push(_ node: T, _ score: Float) {
        items.append((node, score))
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            if items[parent].score <= items[child].score { break }
            items.swapAt(parent, child)
            child = parent
        }
    }

    mutating func pop() -> (T, Float)? {
        guard let first = items.first else { return nil }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var parent = 0
            while true {
                let left = parent * 2 + 1, right = left + 1
                var smallest = parent
                if left < items.count && items[left].score < items[smallest].score { smallest = left }
                if right < items.count && items[right].score < items[smallest].score { smallest = right }
                if smallest == parent { break }
                items.swapAt(parent, smallest)
                parent = smallest
            }
        }
        return (first.node, first.score)
    }
}
