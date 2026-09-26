import Foundation
import simd

// The script runtime's host calls for `data.*` (Folders, Value objects and remotes, as
// data objects), `module.*` (ModuleScripts) and `workspace.raycast`. Sending a remote's
// message to another machine is the play session's (`remote.*`, PlayController+Remotes).
// `ScriptRuntime.invoke` routes each call here by the part of its name before the dot.
//
// Luau sees a data object as the token "v:<id>" and a ModuleScript as "m:<id>"; places
// that aren't in the Workspace tree are "rs" (ReplicatedStorage), "sss" (Script
// Service, Roblox's ServerScriptService) and "pl:<n>" (player n).

extension ScriptRuntime {
    func dataCall(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        func key(_ index: Int) -> String { index < arguments.count ? (arguments[index].asString ?? "").lowercased() : "" }
        let id = uuid(arguments.first)
        switch name {
        case "data.create":
            guard let className = arguments.first?.asString.flatMap(DataClass.init(rawValue:)) else { return .nothing }
            var object = DataObject(name: className.rawValue, className: className)
            // Made on a joined player: theirs alone, as in Roblox.
            object.local = !runsSceneScripts
            model.dataObjects.append(object)
            return .string(object.id.uuidString)

        case "data.exists":
            return .bool(id.flatMap(model.dataObject) != nil)

        case "data.get":
            guard let id, let object = model.dataObject(id: id) else { return .nothing }
            switch key(1) {
            case "name": return .string(object.name)
            case "class": return .string(object.className.rawValue)
            case "value": return object.value
            case "parent": return parentToken(object.parent)
            default: return .nothing
            }

        case "data.set":
            guard let id, model.dataObject(id: id) != nil, arguments.count >= 3 else { return .bool(false) }
            let value = arguments[2]
            switch key(1) {
            case "name":
                guard let text = value.asString else { return .bool(false) }
                model.updateDataObject(id: id) { $0.name = text }
                return .bool(true)
            case "value":
                var accepted = false
                model.updateDataObject(id: id) { accepted = $0.setValue(value) }
                if accepted { player?.noteDataWritten(id) }
                return .bool(accepted)
            case "parent":
                guard let place = value.asString.map(dataParent) else { return .bool(false) }
                // Not inside itself or anything inside it.
                if case .node(let target) = place,
                   target == id || model.dataDescendants(of: .node(id)).contains(where: { $0.id == target }) {
                    return .bool(false)
                }
                if case .node(let target) = place, model.dataObject(id: target) == nil, !model.exists(target) {
                    return .bool(false)
                }
                model.updateDataObject(id: id) { $0.parent = place }
                return .bool(true)
            default:
                return .bool(false)
            }

        case "data.destroy":
            if let id { model.removeDataObjects([id], undoable: false) }
            return .nothing

        case "data.clone":
            guard let id, let original = model.dataObject(id: id) else { return .nothing }
            var remap: [UUID: UUID] = [id: UUID()]
            var copies: [DataObject] = []
            var top = original
            top.id = remap[id]!
            top.parent = .none
            top.local = !runsSceneScripts
            copies.append(top)
            for inner in model.dataDescendants(of: .node(id)) {
                var copy = inner
                copy.id = UUID()
                remap[inner.id] = copy.id
                if case .node(let parent) = inner.parent, let moved = remap[parent] { copy.parent = .node(moved) }
                copy.local = !runsSceneScripts
                copies.append(copy)
            }
            model.dataObjects += copies
            return .string(top.id.uuidString)

        case "data.children":
            return .list(dataChildren(of: arguments.first?.asString ?? "").map { .string($0.token) })

        case "data.find":
            guard arguments.count >= 2, let wanted = arguments[1].asString else { return .nothing }
            return dataChildren(of: arguments[0].asString ?? "").first { $0.name == wanted }.map { .string($0.token) }
                ?? .nothing

        case "data.fromGroup":
            // A Folder going into a Player or ReplicatedStorage leaves the Workspace tree:
            // it becomes a data Folder of the same id, so what's already in it stays.
            guard let id, let group = model.group(id: id), group.kind == .folder,
                  arguments.count >= 2, let place = arguments[1].asString.map(dataParent) else { return .bool(false) }
            guard model.children(of: id).isEmpty, model.scripts.allSatisfy({ $0.parentID != id }) else {
                return .bool(false)
            }
            model.groups.removeAll { $0.id == id }
            var folder = DataObject(name: group.name, className: .folder, parent: place)
            folder.id = id
            folder.local = !runsSceneScripts
            model.dataObjects.append(folder)
            return .bool(true)

        default:
            return unknownCall(name)
        }
    }

    /// "rs", "sss", "pl:<n>", "w", or a tree or data token, as a data object's place.
    func dataParent(_ token: String) -> DataParent {
        if token == "sss" { return .none }
        return DataParent(token: token)
    }

    /// Where a data object is, as Luau takes it: a tree token for a part or group, "v:"
    /// for another data object, or a place.
    func parentToken(_ parent: DataParent) -> ScriptValue {
        switch parent {
        case .none: return .nothing
        case .workspace: return .string("w")
        case .replicatedStorage: return .string("rs")
        case .serverStorage: return .string("ss")
        case .player(let number): return .string("pl:\(number)")
        case .node(let id):
            if model.dataObject(id: id) != nil { return .string("v:" + id.uuidString) }
            return token(id)
        }
    }

    /// What's in a place that isn't in the Workspace tree (or in a data Folder): its
    /// data objects, and — in ReplicatedStorage and Script Service — its ModuleScripts.
    func dataChildren(of place: String) -> [(token: String, name: String)] {
        var list: [(String, String)] = []
        let modules: [ScriptObject]
        switch place {
        case "rs": modules = model.scripts.filter { $0.isModule && $0.host == .replicatedStorage }
        case "ss": modules = model.scripts.filter { $0.isModule && $0.host == .serverStorage }
        case "sss": modules = model.scripts.filter { $0.isModule && $0.host == .scene && $0.parentID == nil }
        default: modules = []
        }
        list += modules.map { ("m:" + $0.id.uuidString, $0.name) }
        // Parts and Models kept there.
        if let storage = StoragePlace(token: place) {
            for node in model.stored(in: storage) {
                switch node {
                case .group(let id): list.append(("g:" + id.uuidString, model.group(id: id)?.name ?? ""))
                case .part(let id): list.append(("p:" + id.uuidString, model.part(id: id)?.name ?? ""))
                }
            }
        }
        if place != "sss" {
            let parent: DataParent = place.hasPrefix("v:") ? .node(UUID(uuidString: String(place.dropFirst(2))) ?? UUID())
                                                           : DataParent(token: place)
            if parent != .none {
                list += model.dataObjects(in: parent).map { ("v:" + $0.id.uuidString, $0.name) }
            }
        }
        return list
    }

    // MARK: - ModuleScripts

    func moduleCall(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        guard let id = uuid(arguments.first), let script = model.script(id: id), script.isModule else { return .nothing }
        switch name {
        case "module.name": return .string(script.name)
        case "module.parent":
            if script.host == .replicatedStorage { return .string("rs") }
            guard let parent = script.parentID else { return .string("sss") }
            return model.exists(parent) ? token(parent) : .nothing
        default: return unknownCall(name)
        }
    }

    // MARK: - Raycasts

    /// `workspace:Raycast`: [origin, direction, filter tokens, include?, respect CanCollide?,
    /// ignore water?] → [hit token, position, normal, distance, material], or nothing.
    /// Parts are tested here; characters by the play session, and the nearer wins.
    func raycast(_ arguments: [ScriptValue]) -> ScriptValue {
        guard arguments.count >= 2, let (ox, oy, oz) = arguments[0].asTriple, let (dx, dy, dz) = arguments[1].asTriple
        else { return .nothing }
        let origin = Vec3(ox, oy, oz), direction = Vec3(dx, dy, dz)
        let reach = length(direction)
        guard reach > 1e-6, reach.isFinite else { return .nothing }
        let filter = (arguments.count > 2 ? arguments[2].asList : nil)?.compactMap(\.asString) ?? []
        let include = arguments.count > 3 ? arguments[3].asBool ?? false : false
        let respectCanCollide = arguments.count > 4 ? arguments[4].asBool ?? false : false
        let ignoreWater = arguments.count > 5 ? arguments[5].asBool ?? false : false

        // The filter, as parts: a Model or Folder stands for everything inside it.
        var listed = Set<UUID>()
        for entry in filter {
            guard let id = UUID(uuidString: entry) else { continue }
            listed.insert(id)
            listed.formUnion(model.descendants(of: id).map(\.id))
        }
        let ray = Ray(origin: origin, direction: direction / reach)
        var best: (part: Part, distance: Float)?
        for part in model.parts where part.inWorld {
            if include != listed.contains(part.id) { continue }
            if respectCanCollide && !part.canCollide { continue }
            if ignoreWater && part.material == .water { continue }
            guard let t = Picking.intersect(ray: ray, part: part, exact: true), t <= reach else { continue }
            if best == nil || t < best!.distance { best = (part, t) }
        }
        // Characters: the play session knows where their bodies are.
        let characters = filter.filter { $0.hasPrefix("ch:") }
        if let player, let hit = player.playerInvoke("character.raycast", [
            .triple(ox, oy, oz), .triple(dx / reach, dy / reach, dz / reach), .number(Double(best?.distance ?? reach)),
            .list(characters.map { .string($0) }), .bool(include)]).asList, hit.count >= 4,
           let distance = hit[2].asFloat, let (nx, ny, nz) = hit[3].asTriple {
            let point = origin + direction / reach * distance
            return .list([hit[0], .triple(point.x, point.y, point.z), .triple(nx, ny, nz), .number(Double(distance)),
                          .string("plastic"), hit[1]])
        }
        guard let best else { return .nothing }
        let point = origin + direction / reach * best.distance
        let normal = Collision.surfaceNormal(part: best.part, worldPoint: point)
        return .list([.string("p:" + best.part.id.uuidString), .triple(point.x, point.y, point.z),
                      .triple(normal.x, normal.y, normal.z), .number(Double(best.distance)),
                      .string(best.part.material.rawValue)])
    }
}
