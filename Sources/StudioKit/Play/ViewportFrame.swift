import Foundation
import AppKit
import simd

/// Serializable geometry and cameras authored inside a ViewportFrame. It contains no
/// GUI or play-session state, so copying it cannot recursively construct previews.
struct ViewportContent: Codable, Equatable {
    var parts: [Part] = []
    var groups: [SceneGroup] = []
    var assets: [SceneAsset] = []
    var cameras: [PreviewCamera] = []
    var currentCamera: UUID?

    func reidentified() -> ViewportContent {
        var copy = self
        var ids: [UUID: UUID] = [:]
        for id in parts.map(\.id) + groups.map(\.id) + cameras.map(\.id) { ids[id] = UUID() }
        copy.parts = parts.map { original in
            var part = original; part.id = ids[original.id]!; part.parentID = original.parentID.flatMap { ids[$0] }
            part.lights = part.lights.map { var light = $0; light.id = UUID(); return light }
            return part
        }
        copy.groups = groups.map { original in
            var group = original; group.id = ids[original.id]!; group.parentID = original.parentID.flatMap { ids[$0] }
            group.primaryPartID = original.primaryPartID.flatMap { ids[$0] }; return group
        }
        copy.cameras = cameras.map { original in var camera = original; camera.id = ids[original.id]!; camera.parent = nil; return camera }
        copy.currentCamera = currentCamera.flatMap { ids[$0] }
        return copy
    }
}

struct PreviewCamera: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Camera"
    var frame = Pose(position: Vec3(0, 0, 10), orientation: simd_quatf(angle: 0, axis: Vec3(0, 1, 0)))
    var focus = Pose.identity
    var fieldOfView: Float = 70
    /// Runtime GUI handle only. Copies assign their own parent after decoding.
    var parent: Int?
}

/// Entirely separate from the played scene; no PhysicsWorld or script VM is created.
final class ViewportWorld {
    let model: SceneModel
    private var host: ScriptRuntime?
    var revision: UInt64 = 0
    init() {
        model = SceneModel()
        model.parts = []; model.groups = []; model.scripts = []; model.assets = []
        model.shaders = []; model.animations = []; model.sounds = []; model.dataObjects = []
        model.attachments = []; model.constraints = []; model.starterGui = []; model.showGrid = false
    }
    func runtime(console: ScriptConsole, player: PlayerBridge?) -> ScriptRuntime {
        if let host { return host }
        let made = ScriptRuntime(model: model, console: console)
        made.isViewportHost = true
        made.runsSceneScripts = false
        made.player = player
        host = made
        return made
    }
}

extension GuiStore {
    func viewport(_ id: Int) -> ViewportWorld? {
        guard object(id)?.kind == .viewportFrame else { return nil }
        if let found = viewportWorlds[id] { return found }
        let world = ViewportWorld(); viewportWorlds[id] = world
        return world
    }

    func viewportOwner(of id: UUID) -> (Int, ViewportWorld)? {
        viewportWorlds.first { $0.value.model.exists(id) || $0.value.model.light(id) != nil }.map { ($0.key, $0.value) }
    }

    func viewportChanged(_ id: Int) {
        viewportWorlds[id]?.revision &+= 1
        objectWillChange.send()
    }

    func installViewport(_ content: ViewportContent, in id: Int, remap: Bool = true) {
        guard let world = viewport(id) else { return }
        let fresh = remap ? content.reidentified() : content
        previewCameras = previewCameras.filter { $0.value.parent != id }
        ViewportRenderer.shared?.remove(owner: self, id: id)
        world.model.parts = fresh.parts; world.model.groups = fresh.groups; world.model.assets = fresh.assets
        for original in fresh.cameras { var camera = original; camera.parent = id; previewCameras[camera.id] = camera }
        update(id) { $0.currentCamera = fresh.currentCamera }
        viewportChanged(id)
    }

    func viewportContent(_ id: Int) -> ViewportContent? {
        guard let world = viewportWorlds[id] else { return nil }
        return ViewportContent(parts: world.model.parts, groups: world.model.groups, assets: world.model.assets,
                               cameras: previewCameras.values.filter { $0.parent == id || $0.id == object(id)?.currentCamera }.sorted { $0.id.uuidString < $1.id.uuidString },
                               currentCamera: object(id)?.currentCamera)
    }

    func cloneGui(_ original: Int) -> Int? {
        guard let object = object(original) else { return nil }
        func copy(_ old: Int, parent: Int?) -> Int? {
            guard let source = self.object(old) else { return nil }
            let id = create(source.kind)
            // GuiObject.id is immutable, so copy its values through a template property bag.
            var template = StarterGuiObject(kind: source.kind, name: source.name)
            template.properties = source.persistentProperties
            template.viewportContent = viewportContent(old)
            var made = template.object(id: id)
            made.parent = parent; made.worldParent = nil; made.localOnly = source.localOnly
            update(id) { $0 = made }
            if let content = template.viewportContent { installViewport(content, in: id) }
            for child in children(of: old) { _ = copy(child, parent: id) }
            return id
        }
        _ = object
        return copy(original, parent: nil)
    }

    func destroyViewport(_ id: Int) {
        viewportWorlds[id] = nil
        previewCameras = previewCameras.filter { $0.value.parent != id }
        ViewportRenderer.shared?.remove(owner: self, id: id)
    }

    func viewportImage(_ object: GuiObject, size: CGSize) -> NSImage? {
        guard object.kind == .viewportFrame, let camera = object.currentCamera.flatMap({ previewCameras[$0] }),
              let world = viewport(object.id) else { return nil }
        return ViewportRenderer.shared?.image(owner: self, world: world, object: object, camera: camera, size: size)
    }
}

extension ScriptRuntime {
    /// Intercepts only preview-owned UUIDs. Existing part/tree host calls operate on the
    /// isolated model unchanged; Workspace operations still use the real model.
    func viewportRoute(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue? {
        guard !isViewportHost, let play = player as? PlayController else { return nil }
        let store = play.gui
        if name.hasPrefix("viewport.") { return viewportCall(name, arguments, store: store) }
        if name == "tree.setparent", arguments.count >= 2, let id = uuid(arguments.first), model.exists(id),
           let destination = uuid(arguments[1]), let (owner, target) = store.viewportOwner(of: destination) {
            return .bool(transferPreviewNode(id, from: model, to: target.model, parent: destination, store: store, owner: owner))
        }
        guard let id = uuid(arguments.first), let (owner, world) = store.viewportOwner(of: id) else { return nil }
        if name == "tree.parent", world.model.parentID(of: id) == nil, world.model.exists(id) {
            return .string("u:\(owner)")
        }
        if name == "tree.setparent", arguments.count >= 2 {
            let destination = arguments[1].asString == "w" ? nil : uuid(arguments[1])
            if let destination, world.model.exists(destination) { /* ordinary internal move */ }
            else if arguments[1].asString == "w" || destination.map(model.exists) == true {
                return .bool(transferPreviewNode(id, from: world.model, to: model, parent: destination, store: store, owner: nil))
            } else if let destination, let (other, target) = store.viewportOwner(of: destination) {
                return .bool(transferPreviewNode(id, from: world.model, to: target.model, parent: destination, store: store, owner: other))
            }
        }
        let prefix = name.split(separator: ".").first.map(String.init) ?? ""
        if prefix == "physics" { return name == "physics.get" ? .triple(0, 0, 0) : .nothing }
        guard ["part", "group", "tree", "node", "light", "click"].contains(prefix) else { return nil }
        let value = world.runtime(console: console, player: player).invoke(name, arguments)
        store.viewportChanged(owner)
        return value
    }

    private func transferPreviewNode(_ id: UUID, from source: SceneModel, to destination: SceneModel,
                                     parent: UUID?, store: GuiStore, owner: Int?) -> Bool {
        guard source.exists(id), parent == nil || destination.exists(parent!) else { return false }
        if source === destination { return source.setParent(id, parent) }
        let ids = Set([id] + source.descendants(of: id).map(\.id))
        var parts = source.parts.filter { ids.contains($0.id) }
        var groups = source.groups.filter { ids.contains($0.id) }
        for index in parts.indices { if parts[index].id == id { parts[index].parentID = parent }; parts[index].parked = false; parts[index].storage = nil }
        for index in groups.indices { if groups[index].id == id { groups[index].parentID = parent }; groups[index].storage = nil }
        let scripts = source.scripts.filter { $0.parentID.map(ids.contains) == true }
        let oldOwner = store.viewportOwner(of: id)?.0
        let assets = source.assets
        source.removeSubtrees([id])
        destination.assets += assets.filter { asset in !destination.assets.contains { $0.id == asset.id } }
        destination.parts += parts; destination.groups += groups; destination.scripts += scripts
        if let oldOwner { store.viewportChanged(oldOwner) }
        if let owner { store.viewportChanged(owner) }
        else { runScripts(inside: id) }
        return true
    }

    private func viewportCall(_ name: String, _ arguments: [ScriptValue], store: GuiStore) -> ScriptValue {
        switch name {
        case "viewport.cloneGui":
            guard let copied = store.cloneGui(Int(arguments.first?.asDouble ?? -1)) else { return .nothing }
            if arguments.count > 1, arguments[1].asBool == true {
                for id in [copied] + store.descendants(of: copied) { store.update(id) { $0.localOnly = true } }
            }
            return .number(Double(copied))
        case "viewport.parent":
            guard arguments.count >= 2, let id = uuid(arguments.first), let number = arguments[1].asDouble,
                  let target = store.viewport(Int(number)) else { return .bool(false) }
            let source = store.viewportOwner(of: id)?.1.model ?? model
            return .bool(transferPreviewNode(id, from: source, to: target.model, parent: nil, store: store, owner: Int(number)))
        case "viewport.children":
            let id = Int(arguments.first?.asDouble ?? -1)
            guard let world = store.viewport(id) else { return .list([]) }
            let nodes = world.model.children(of: nil).map { node -> ScriptValue in
                switch node { case .part(let id): return .string("p:\(id)"); case .group(let id): return .string("g:\(id)") }
            }
            let cameras = store.previewCameras.values.filter { $0.parent == id }.sorted { $0.id.uuidString < $1.id.uuidString }
                .map { ScriptValue.string("k:\($0.id)") }
            return .list(nodes + cameras)
        case "viewport.cameraCreate":
            let camera = PreviewCamera(); store.previewCameras[camera.id] = camera
            return .string(camera.id.uuidString)
        case "viewport.cameraClone":
            guard let id = uuid(arguments.first), var camera = store.previewCameras[id] else { return .nothing }
            camera.id = UUID(); camera.parent = nil; store.previewCameras[camera.id] = camera
            return .string(camera.id.uuidString)
        case "viewport.cameraGet":
            guard arguments.count >= 2, let id = uuid(arguments.first), let camera = store.previewCameras[id] else { return .nothing }
            switch arguments[1].asString ?? "" {
            case "name": return .string(camera.name)
            case "parent": return camera.parent.map { .number(Double($0)) } ?? .nothing
            case "cframe": return .list(camera.frame.components.map { .number(Double($0)) })
            case "focus": return .list(camera.focus.components.map { .number(Double($0)) })
            case "fieldofview": return .number(Double(camera.fieldOfView))
            default: return .nothing
            }
        case "viewport.cameraSet":
            guard arguments.count >= 3, let id = uuid(arguments.first), var camera = store.previewCameras[id] else { return .bool(false) }
            let value = arguments[2]
            switch arguments[1].asString ?? "" {
            case "name": guard let text = value.asString else { return .bool(false) }; camera.name = text
            case "parent":
                if case .nothing = value { camera.parent = nil }
                else { guard let number = value.asDouble, store.object(Int(number))?.kind == .viewportFrame else { return .bool(false) }; camera.parent = Int(number) }
            case "cframe", "focus":
                guard let values = value.asList?.compactMap(\.asFloat), values.count == 12, values.allSatisfy(\.isFinite), let pose = Pose(components: values) else { return .bool(false) }
                if arguments[1].asString == "cframe" { camera.frame = pose } else { camera.focus = pose }
            case "fieldofview":
                guard let number = value.asFloat, number.isFinite else { return .bool(false) }; camera.fieldOfView = min(max(number, 1), 120)
            default: return .bool(false)
            }
            store.previewCameras[id] = camera; store.objectWillChange.send()
            return .bool(true)
        case "viewport.cameraDestroy":
            guard let id = uuid(arguments.first) else { return .nothing }
            store.previewCameras[id] = nil
            for object in store.objects.values where object.currentCamera == id { store.update(object.id) { $0.currentCamera = nil } }
            return .nothing
        default: return .nothing
        }
    }
}
