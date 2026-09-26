import Foundation
import simd

// The script runtime's host calls for `tree.*`, `node.*`, `group.*` and `tool.*`: the Workspace
// tree, Models, Folders and Tools. Where a player's tools go is the play session's
// (`backpack.*`, PlayController+Tools).
// `ScriptRuntime.invoke` routes each call here by the part of its name before the dot.

extension ScriptRuntime {
    /// Host calls for `tree.*`, `node.*` and `group.*`: the Workspace tree, Models and Folders.
    func treeCall(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        switch name {
        // MARK: the tree, for Luau. Parts and groups share one id space; a returned
        // node is a token — "p:<id>" for a part, "g:<id>" for a Model or Folder, "w"
        // for the Workspace — so Luau knows which kind of object to make.
        case "tree.parent":
            guard let id = uuid(arguments.first) else { return .nothing }
            if let attachment = model.attachment(id: id) { return token(attachment.parentID) }
            if let constraint = model.constraint(id: id) { return token(constraint.parentID) }
            guard model.exists(id) else { return .nothing }
            return token(model.parentID(of: id))

        case "tree.setparent":
            guard let id = uuid(arguments.first), arguments.count >= 2 else { return .bool(false) }
            let parent = arguments[1].asString == "w" ? nil : uuid(arguments[1])
            if arguments[1].asString != "w" && parent == nil { return .bool(false) }
            if model.attachment(id: id) != nil {
                // An attachment belongs on a part.
                guard let parent, model.part(id: parent) != nil else { return .bool(false) }
                model.updateAttachment(id: id) { $0.parentID = parent }
                return .bool(true)
            }
            if model.constraint(id: id) != nil {
                guard parent == nil || model.exists(parent!) else { return .bool(false) }
                model.updateConstraint(id: id) { $0.parentID = parent }
                return .bool(true)
            }
            return .bool(model.setParent(id, parent))

        case "tree.children":
            let parent = arguments.first?.asString == "w" ? nil : uuid(arguments.first)
            return .list(model.children(of: parent).map(nodeToken) + extras(of: parent).map { .string($0.token) })

        case "tree.descendants":
            let parent = arguments.first?.asString == "w" ? nil : uuid(arguments.first)
            var tokens = extras(of: parent).map { ScriptValue.string($0.token) }
            for node in model.descendants(of: parent) {
                tokens.append(nodeToken(node))
                tokens += extras(of: node.id).map { .string($0.token) }
            }
            return .list(tokens)

        case "tree.find":
            guard arguments.count >= 2, let name = arguments[1].asString else { return .nothing }
            let parent = arguments[0].asString == "w" ? nil : uuid(arguments[0])
            let recursive = arguments.count > 2 ? (arguments[2].asBool ?? false) : false
            if let found = model.findChild(named: name, in: parent, recursive: recursive) { return nodeToken(found) }
            let places = recursive ? [parent] + model.descendants(of: parent).map { Optional($0.id) } : [parent]
            for place in places {
                if let extra = extras(of: place).first(where: { $0.name == name }) { return .string(extra.token) }
            }
            return .nothing

        case "tree.scriptParent":
            guard let id = uuid(arguments.first), let script = model.script(id: id),
                  let parent = script.parentID else { return .nothing }
            // A LocalScript in StarterGui is in this player's copy of its GUI: "u:<id>".
            if script.host == .starterGui {
                guard let copy = player?.playerInvoke("gui.copyOf", [.string(parent.uuidString)]).asDouble else {
                    return .nothing
                }
                return .string("u:\(Int(copy))")
            }
            guard model.exists(parent) else { return .nothing }
            return token(parent)

        case "group.create":
            let kind = SceneGroup.Kind(rawValue: arguments.first?.asString ?? "Model") ?? .model
            let group = SceneGroup(name: kind.rawValue, kind: kind)
            model.groups.append(group)
            return .string(group.id.uuidString)

        case "group.get":
            guard arguments.count >= 2, let id = uuid(arguments[0]), let group = model.group(id: id) else { return .nothing }
            switch (arguments[1].asString ?? "").lowercased() {
            case "name": return .string(group.name)
            case "kind": return .string(group.kind.rawValue)
            case "primarypart":
                guard let primary = group.primaryPartID, model.isDescendant(primary, of: id) else { return .nothing }
                return .string(primary.uuidString)
            default: return .nothing
            }

        case "group.set":
            guard arguments.count >= 3, let id = uuid(arguments[0]) else { return .nothing }
            switch (arguments[1].asString ?? "").lowercased() {
            case "name": if let name = arguments[2].asString { model.updateGroup(id: id) { $0.name = name } }
            case "primarypart": model.updateGroup(id: id) { $0.primaryPartID = uuid(arguments[2]) }
            default: break
            }
            return .nothing

        case "group.destroy":
            guard let id = uuid(arguments.first) else { return .nothing }
            model.removeSubtrees([id])
            return .nothing

        case "group.clone":
            guard let id = uuid(arguments.first), model.group(id: id) != nil,
                  let copy = model.cloneSubtree(id, parent: nil) else { return .nothing }
            return .string(copy.uuidString)

        // MARK: Tools: their settings, and where they are
        case "tool.get":
            guard arguments.count >= 2, let id = uuid(arguments[0]), let tool = model.group(id: id)?.tool else {
                return .nothing
            }
            switch (arguments[1].asString ?? "").lowercased() {
            case "tooltip": return .string(tool.toolTip)
            case "enabled": return .bool(tool.enabled)
            case "requireshandle": return .bool(tool.requiresHandle)
            case "canbedropped": return .bool(tool.canBeDropped)
            case "grip": return .list((tool.grip ?? Pose.identity.components).map { .number(Double($0)) })
            case "place":
                switch tool.place {
                case .workspace: return .string("workspace")
                case .starterPack: return .string("starterpack")
                case .backpack: return .string("backpack")
                case .hand: return .string("hand")
                }
            case "holder": return tool.place.holder.map { .number(Double($0)) } ?? .nothing
            default: return .nothing
            }

        case "tool.set":
            guard arguments.count >= 3, let id = uuid(arguments[0]), model.group(id: id)?.tool != nil else { return .nothing }
            let value = arguments[2]
            model.updateTool(id: id) { tool in
                switch (arguments[1].asString ?? "").lowercased() {
                case "tooltip": if let text = value.asString { tool.toolTip = text }
                case "enabled": if let on = value.asBool { tool.enabled = on }
                case "requireshandle": if let on = value.asBool { tool.requiresHandle = on }
                case "canbedropped": if let on = value.asBool { tool.canBeDropped = on }
                case "grip":
                    if case .list(let items) = value, Pose(components: items.compactMap(\.asFloat)) != nil {
                        tool.grip = items.compactMap(\.asFloat)
                    }
                default: break
                }
            }
            return .nothing

        case "tool.starterpack":
            return .list(model.starterPackTools.map { .string($0.id.uuidString) })

        case "node.pivot":
            guard let id = uuid(arguments.first), let pose = model.pivot(of: id) else { return .nothing }
            return .list(pose.components.map { .number(Double($0)) })

        case "node.pivotto":
            guard arguments.count >= 2, let id = uuid(arguments[0]), let pose = poseValue(arguments[1]) else {
                return .nothing
            }
            model.movePivot(of: id, to: pose)
            return .nothing

        case "node.bounds":
            guard let id = uuid(arguments.first), let box = model.boundingBox(of: model.partIDs(inSubtree: id))
            else { return .nothing }
            return .list([.number(Double(box.center.x)), .number(Double(box.center.y)), .number(Double(box.center.z)),
                          .number(Double(box.size.x)), .number(Double(box.size.y)), .number(Double(box.size.z))])

        default:
            return unknownCall(name)
        }
    }

    /// Attachments on a part and constraints under a node, as tree tokens ("a:" and "c:").
    func extras(of parent: UUID?) -> [(token: String, name: String)] {
        var list: [(String, String)] = []
        if let parent {
            for a in model.attachments where a.parentID == parent { list.append(("a:" + a.id.uuidString, a.name)) }
        }
        for c in model.constraints where c.parentID == parent { list.append(("c:" + c.id.uuidString, c.name)) }
        if let parent {
            for s in model.sounds where s.parentID == parent { list.append(("s:" + s.id.uuidString, s.name)) }
            for m in model.scripts where m.isModule && m.host == .scene && m.parentID == parent {
                list.append(("m:" + m.id.uuidString, m.name))
            }
        }
        for v in model.dataObjects(in: parent.map { .node($0) } ?? .workspace) {
            list.append(("v:" + v.id.uuidString, v.name))
        }
        return list
    }

    func token(_ id: UUID?) -> ScriptValue {
        guard let id else { return .string("w") }
        return model.node(id).map(nodeToken) ?? .nothing
    }

    func nodeToken(_ node: TreeNode) -> ScriptValue {
        switch node {
        case .part(let id): return .string("p:" + id.uuidString)
        case .group(let id): return .string("g:" + id.uuidString)
        }
    }
}
