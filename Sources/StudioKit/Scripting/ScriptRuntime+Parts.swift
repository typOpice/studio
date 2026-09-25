import Foundation
import simd

// The script runtime's host calls for `part.*` and `workspace.*`: parts, and making and finding them.
// `ScriptRuntime.invoke` routes each call here by the part of its name before the dot.

extension ScriptRuntime {
    /// Host calls for `part.*` and `workspace.*`: parts, and making and finding them.
    func partsCall(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        switch name {
        case "part.exists":
            return .bool(partID(arguments.first ?? .nothing) != nil)

        case "part.get":
            guard arguments.count >= 2, let part = part(arguments[0]),
                  let property = arguments[1].asString else { return .nothing }
            return read(part, property)

        case "part.set":
            guard arguments.count >= 3, let id = partID(arguments[0]),
                  let property = arguments[1].asString else { return .nothing }
            write(id, property, arguments[2])
            return .nothing

        case "part.destroy":
            // Destroying a part destroys what is inside it, as in Roblox.
            guard let id = partID(arguments.first ?? .nothing) else { return .nothing }
            model.removeSubtrees([id])
            return .nothing

        case "part.clone":
            // Copies what is inside too; the copy goes straight into the Workspace.
            guard let original = part(arguments.first ?? .nothing),
                  let copy = model.cloneSubtree(original.id, parent: nil) else { return .nothing }
            model.update(id: copy) { $0.name = model.uniqueName(base: original.name) }
            return .string(copy.uuidString)

        case "workspace.count":
            return .number(Double(model.parts.count))

        case "workspace.ids":
            return .list(model.parts.map { .string($0.id.uuidString) })

        case "workspace.find":
            guard let target = arguments.first?.asString,
                  let found = model.parts.first(where: { $0.name == target }) else { return .nothing }
            return .string(found.id.uuidString)

        case "workspace.findAll":
            guard let target = arguments.first?.asString else { return .list([]) }
            return .list(model.parts.filter { $0.name == target }.map { .string($0.id.uuidString) })

        case "workspace.create":
            let shapeName = arguments.first?.asString ?? "block"
            guard let shape = PartShape(rawValue: shapeName.lowercased()) else {
                console.error("Unknown shape \"\(shapeName)\" — use block, sphere, cylinder or wedge.")
                return .nothing
            }
            var part = Part()
            part.shape = shape
            part.name = model.uniqueName(base: shape.displayName)
            part.position = Vec3(0, 3, 0)
            part.color = SceneModel.palette[model.parts.count % SceneModel.palette.count]
            model.parts.append(part)
            return .string(part.id.uuidString)

        default:
            return unknownCall(name)
        }
    }

    func poseValue(_ value: ScriptValue) -> Pose? {
        guard case .list(let items) = value else { return nil }
        let numbers = items.compactMap(\.asFloat)
        return numbers.count == 12 ? Pose(components: numbers) : nil
    }

    func read(_ part: Part, _ property: String) -> ScriptValue {
        switch property {
        case "cframe": return .list(part.pose.components.map { .number(Double($0)) })
        case "mass": return .number(Double(PhysicsWorld.massProperties(of: part).mass))
        case "name": return .string(part.name)
        case "shape": return .string(part.shape.rawValue)
        case "isseat": return .bool(part.seat != nil)
        case "seatdisabled": return part.seat.map { .bool($0.disabled) } ?? .nothing
        case "ismeshpart": return .bool(part.mesh != nil)
        case "meshid": return part.mesh.map { .string($0.meshId) } ?? .nothing
        case "textureid": return part.mesh.map { .string($0.textureId) } ?? .nothing
        case "collisionfidelity": return part.mesh.map { .string($0.collisionFidelity.robloxName) } ?? .nothing
        case "meshsize":
            // The size the mesh was made at; zero with no mesh (or none that loads).
            let size = MeshLibrary.shared.geometry(for: part)?.nativeSize ?? .zero
            return .triple(size.x, size.y, size.z)
        case "occupant":
            // Who is in a seat is the play session's to say.
            guard part.seat != nil else { return .nothing }
            return player?.playerInvoke("seat.occupant", [.string(part.id.uuidString)]) ?? .nothing
        case "material": return .string(part.material.rawValue)
        case "position": return .triple(part.position.x, part.position.y, part.position.z)
        case "size": return .triple(part.size.x, part.size.y, part.size.z)
        case "rotation":
            let r = part.rotationDegrees
            return .triple(r.x, r.y, r.z)
        case "color": return .triple(part.color.x, part.color.y, part.color.z)
        case "transparency": return .number(Double(part.transparency))
        case "anchored": return .bool(part.anchored)
        case "visible": return .bool(part.visible)
        case "locked": return .bool(part.locked)
        case "cancollide": return .bool(part.canCollide)
        case "cantouch": return .bool(part.canTouch)
        case "shader":
            guard let shaderID = part.shaderID, model.shader(id: shaderID) != nil else { return .nothing }
            return .string(shaderID.uuidString)
        default:
            console.error("Part has no property \"\(property)\".")
            return .nothing
        }
    }

    func write(_ id: UUID, _ property: String, _ value: ScriptValue) {
        // A MeshId names an imported 3D model: found now, kept by its id.
        let meshAsset = property == "meshid" ? value.asString.flatMap(model.asset(named:)).flatMap { $0.kind == .mesh ? $0.id : nil } : nil
        model.update(id: id) { part in
            switch property {
            case "name":
                if let name = value.asString { part.name = name }
            case "shape":
                if let raw = value.asString, let shape = PartShape(rawValue: raw.lowercased()) {
                    part.shape = shape
                }
            case "isseat":
                if let on = value.asBool { part.seat = on ? (part.seat ?? SeatSettings()) : nil }
            case "ismeshpart":
                if let on = value.asBool { part.mesh = on ? (part.mesh ?? MeshSettings()) : nil }
            case "meshid":
                if let name = value.asString, part.mesh != nil {
                    part.mesh?.meshId = name
                    part.mesh?.asset = meshAsset
                }
            case "textureid":
                if let name = value.asString, part.mesh != nil { part.mesh?.textureId = name }
            case "collisionfidelity":
                if let name = value.asString, let fidelity = CollisionFidelity(robloxName: name), part.mesh != nil {
                    part.mesh?.collisionFidelity = fidelity
                }
            case "seatdisabled":
                if let on = value.asBool, part.seat != nil { part.seat?.disabled = on }
            case "material":
                if let raw = value.asString, let material = PartMaterial(rawValue: raw.lowercased()) {
                    part.material = material
                }
            case "position":
                if let (x, y, z) = value.asTriple { part.position = Vec3(x, y, z) }
            case "size":
                if let (x, y, z) = value.asTriple {
                    part.size = Vec3(max(0.05, x), max(0.05, y), max(0.05, z))
                }
            case "rotation":
                if let (x, y, z) = value.asTriple { part.rotationDegrees = Vec3(x, y, z) }
            case "cframe":
                if let pose = poseValue(value) { part.pose = pose }
            case "color":
                if let (r, g, b) = value.asTriple {
                    part.color = Vec3(min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1))
                }
            case "transparency":
                if let t = value.asFloat { part.transparency = min(max(t, 0), 1) }
            case "anchored":
                if let b = value.asBool { part.anchored = b }
            case "visible":
                if let b = value.asBool { part.visible = b }
            case "locked":
                if let b = value.asBool { part.locked = b }
            case "cancollide":
                if let b = value.asBool { part.canCollide = b }
            case "cantouch":
                if let b = value.asBool { part.canTouch = b }
            case "shader":
                if case .nothing = value {
                    part.shaderID = nil
                } else if let string = value.asString, let id = UUID(uuidString: string),
                          model.shader(id: id) != nil {
                    part.shaderID = id
                }
            default:
                console.error("Part has no property \"\(property)\".")
            }
        }
    }

    func part(_ value: ScriptValue) -> Part? {
        guard let string = value.asString, let id = UUID(uuidString: string) else { return nil }
        return model.part(id: id)
    }

    func partID(_ value: ScriptValue) -> UUID? {
        guard let string = value.asString, let id = UUID(uuidString: string) else { return nil }
        return model.index(of: id) == nil ? nil : id
    }
}
