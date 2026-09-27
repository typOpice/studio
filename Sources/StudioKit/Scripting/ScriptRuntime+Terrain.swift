import Foundation
import simd

// The script runtime's host calls for `terrain.*`: the Workspace's Terrain (Terrain.swift).
// Materials come as Enum.Material's names; positions and sizes as lists of numbers; a
// CFrame as `poseValue` reads it. Regions are [min, max] corners, in studs.

extension ScriptRuntime {
    func terrainCall(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        func vector(_ index: Int) -> Vec3? {
            guard arguments.count > index, let (x, y, z) = arguments[index].asTriple, x.isFinite, y.isFinite, z.isFinite
            else { return nil }
            return Vec3(x, y, z)
        }
        func number(_ index: Int) -> Float? {
            guard arguments.count > index, let n = arguments[index].asFloat, n.isFinite else { return nil }
            return n
        }
        func material(_ index: Int) -> TerrainMaterial? {
            guard arguments.count > index, let text = arguments[index].asString else { return nil }
            return TerrainMaterial(name: text)
        }
        switch name {
        case "terrain.fill":
            guard let shape = arguments.first?.asString else { return .bool(false) }
            switch shape {
            case "ball":
                guard let centre = vector(1), let radius = number(2), let m = material(3) else { return .bool(false) }
                model.terrain.fillBall(centre: centre, radius: min(radius, 2048), material: m)
            case "block", "wedge":
                guard arguments.count > 3, let pose = poseValue(arguments[1]), let size = vector(2), let m = material(3)
                else { return .bool(false) }
                let clamped = simd_min(simd_abs(size), Vec3(repeating: 4096))
                if shape == "block" {
                    model.terrain.fillBlock(pose: pose, size: clamped, material: m)
                } else {
                    model.terrain.fillWedge(pose: pose, size: clamped, material: m)
                }
            case "cylinder":
                guard arguments.count > 4, let pose = poseValue(arguments[1]), let height = number(2), let radius = number(3),
                      let m = material(4) else { return .bool(false) }
                model.terrain.fillCylinder(pose: pose, height: min(abs(height), 4096), radius: min(abs(radius), 2048), material: m)
            case "region":
                guard let low = vector(1), let high = vector(2), let m = material(3) else { return .bool(false) }
                model.terrain.fillRegion(low: simd_min(low, high), high: simd_max(low, high), material: m)
            default:
                return .bool(false)
            }
            return .bool(true)

        case "terrain.replace":
            guard let low = vector(0), let high = vector(1), let from = material(2), let to = material(3) else { return .bool(false) }
            model.terrain.replace(low: simd_min(low, high), high: simd_max(low, high), from, with: to)
            return .bool(true)

        case "terrain.clear":
            model.terrain.chunks = [:]
            return .nothing

        case "terrain.get":
            switch arguments.first?.asString?.lowercased() ?? "" {
            case "watercolor":
                let c = model.terrain.waterColor
                return .list([.number(Double(c.x)), .number(Double(c.y)), .number(Double(c.z))])
            case "watertransparency": return .number(Double(model.terrain.waterTransparency))
            case "waterwavesize": return .number(Double(model.terrain.waterWaveSize))
            case "waterwavespeed": return .number(Double(model.terrain.waterWaveSpeed))
            default: return .nothing
            }

        case "terrain.set":
            guard arguments.count > 1 else { return .bool(false) }
            switch arguments[0].asString?.lowercased() ?? "" {
            case "watercolor": guard let c = vector(1) else { return .bool(false) }; model.terrain.waterColor = c
            case "watertransparency": guard let n = number(1) else { return .bool(false) }; model.terrain.waterTransparency = min(max(n, 0), 1)
            case "waterwavesize": guard let n = number(1) else { return .bool(false) }; model.terrain.waterWaveSize = min(max(n, 0), 1)
            case "waterwavespeed": guard let n = number(1) else { return .bool(false) }; model.terrain.waterWaveSpeed = min(max(n, 0), 100)
            default: return .bool(false)
            }
            return .bool(true)

        case "terrain.color":
            // One argument reads a material's colour; two set it.
            guard let m = material(0), m != .air else { return .nothing }
            if let c = vector(1) { model.terrain.materialColors[m.rawValue] = simd_clamp(c, .zero, Vec3(1, 1, 1)) }
            let c = model.terrain.color(of: m)
            return .list([.number(Double(c.x)), .number(Double(c.y)), .number(Double(c.z))])

        case "terrain.read":
            // [x, y, z counts, then each voxel's material name and occupancy, x fastest].
            guard let low = vector(0), let high = vector(1) else { return .nothing }
            let a = TerrainData.voxel(at: simd_min(low, high) + TerrainData.voxel / 2)
            let b = TerrainData.voxel(at: simd_max(low, high) - TerrainData.voxel / 2)
            let count = simd_max(b &- a &+ 1, .zero)
            guard Int(count.x) * Int(count.y) * Int(count.z) <= 1 << 20 else { return .nothing }
            var materials: [ScriptValue] = [], occupancies: [ScriptValue] = []
            if count.x > 0, count.y > 0, count.z > 0 {
                for z in a.z...b.z { for y in a.y...b.y { for x in a.x...b.x {
                    let v = SIMD3<Int32>(x, y, z)
                    materials.append(.string(model.terrain.material(v).name))
                    occupancies.append(.number(Double(model.terrain.occupancy(v))))
                } } }
            }
            return .list([.number(Double(count.x)), .number(Double(count.y)), .number(Double(count.z)),
                          .list(materials), .list(occupancies)])

        case "terrain.write":
            guard let low = vector(0), let high = vector(1), arguments.count > 3,
                  let materials = arguments[2].asList, let occupancies = arguments[3].asList else { return .bool(false) }
            let a = TerrainData.voxel(at: simd_min(low, high) + TerrainData.voxel / 2)
            let b = TerrainData.voxel(at: simd_max(low, high) - TerrainData.voxel / 2)
            let count = simd_max(b &- a &+ 1, .zero)
            let total = Int(count.x) * Int(count.y) * Int(count.z)
            guard total > 0, materials.count == total, occupancies.count == total else { return .bool(false) }
            let names = materials.map { $0.asString.flatMap(TerrainMaterial.init(name:)) }
            guard names.allSatisfy({ $0 != nil }) else { return .bool(false) }
            model.terrain.edit(from: a, to: b) { v, current, occupancy in
                let l = v &- a
                let i = (Int(l.z) * Int(count.y) + Int(l.y)) * Int(count.x) + Int(l.x)
                current = names[i]!
                occupancy = occupancies[i].asFloat ?? 0
            }
            return .bool(true)

        default:
            return unknownCall(name)
        }
    }
}
