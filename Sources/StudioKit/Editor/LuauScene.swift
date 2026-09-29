import Foundation

/// What a script can reach by name, for Luau completion: the four places (Workspace,
/// ReplicatedStorage, ServerStorage, ServerScriptService), everything in them by name
/// and class, and every ModuleScript's code, so `require` can be followed into it.
///
/// Built from the model each time suggestions are wanted (`SceneModel.luauScene`), so
/// the completion engine stays a pure function of this and the text.
struct LuauScene: Equatable {
    struct Node: Equatable {
        var name: String
        /// As Luau would say it: "ModuleScript", "Folder", "Model", "Part", "RemoteEvent"…
        var className: String
        var parent: Int?
        /// A ModuleScript's code.
        var source: String?
        var scriptID: UUID? = nil
    }

    private(set) var nodes: [Node] = []
    private var childLists: [Int: [Int]] = [:]
    /// The places, by the name `game:GetService` takes.
    private(set) var places: [String: Int] = [:]
    /// The script being edited, when it has a place in the tree (so `script.Parent` means something).
    var script: Int?

    static let placeNames = ["Workspace", "ReplicatedStorage", "ServerStorage", "ServerScriptService"]

    init() {
        for name in Self.placeNames { places[name] = add(Node(name: name, className: name, parent: nil)) }
    }

    @discardableResult
    mutating func add(_ node: Node) -> Int {
        nodes.append(node)
        let index = nodes.count - 1
        if let parent = node.parent { childLists[parent, default: []].append(index) }
        return index
    }

    func children(of index: Int) -> [Int] { childLists[index] ?? [] }

    func child(named name: String, of index: Int) -> Int? {
        children(of: index).first { nodes[$0].name == name }
    }

    func isModule(_ index: Int) -> Bool { nodes[index].className == "ModuleScript" }

    /// Whether a ModuleScript is at or somewhere under this node.
    func leadsToModule(_ index: Int) -> Bool {
        isModule(index) || children(of: index).contains { leadsToModule($0) }
    }

    var modules: [Int] { nodes.indices.filter(isModule) }

    /// The place a node is in, and the names from there down to it.
    func path(to index: Int) -> (place: String, names: [String]) {
        var names: [String] = []
        var current = index
        while let parent = nodes[current].parent {
            names.insert(nodes[current].name, at: 0)
            current = parent
        }
        return (nodes[current].name, names)
    }
}

extension SceneModel {
    /// The scene as Luau completion sees it, from the point of view of one script.
    func luauScene(editing scriptID: UUID? = nil) -> LuauScene {
        var scene = LuauScene()
        var visited = Set<UUID>()
        var objectNodes: [UUID: Int] = [:]
        // Looked up by parent once, rather than searched for every node.
        let groupsInside = Dictionary(grouping: groups.filter { $0.parentID != nil }, by: { $0.parentID! })
        let partsInside = Dictionary(grouping: parts.filter { $0.parentID != nil }, by: { $0.parentID! })
        let scriptsInside = Dictionary(grouping: scripts.filter { $0.parentID != nil && ($0.host == .scene || $0.isModule) },
                                       by: { $0.parentID! })
        let dataInside = Dictionary(grouping: dataObjects, by: { $0.parent })

        // What is inside a part, group or data object: more of the same, its scripts,
        // and its data objects.
        func addContents(of id: UUID, at index: Int) {
            guard visited.insert(id).inserted else { return }
            objectNodes[id] = index
            for group in groupsInside[id] ?? [] { addGroup(group, under: index) }
            for part in partsInside[id] ?? [] { addPart(part, under: index) }
            addScripts(scriptsInside[id] ?? [], under: index)
            addData(in: .node(id), under: index)
        }
        func addGroup(_ group: SceneGroup, under index: Int) {
            let className = group.tool != nil ? "Tool" : group.kind.rawValue
            addContents(of: group.id, at: scene.add(.init(name: group.name, className: className, parent: index)))
        }
        func addPart(_ part: Part, under index: Int) {
            let node = scene.add(.init(name: part.name, className: partClass(part), parent: index))
            addLights(part, under: node)
            addContents(of: part.id, at: node)
        }
        func partClass(_ part: Part) -> String {
            if part.negative { return "NegateOperation" }
            if part.solid != nil { return "UnionOperation" }
            if part.mesh != nil { return "MeshPart" }
            return "Part"
        }
        func addLights(_ part: Part, under index: Int) {
            for light in part.lights {
                scene.add(.init(name: light.name, className: light.kind.rawValue, parent: index))
            }
        }
        func addScripts(_ list: [ScriptObject], under index: Int) {
            for script in list where script.language == .luau {
                let className = script.isModule ? "ModuleScript" : script.host == .scene ? "Script" : "LocalScript"
                let node = scene.add(.init(name: script.name, className: className,
                                           parent: index, source: script.isModule ? script.source : nil, scriptID: script.id))
                if script.id == scriptID { scene.script = node }
            }
        }
        func addData(in place: DataParent, under index: Int) {
            for object in dataInside[place] ?? [] {
                addContents(of: object.id, at: scene.add(.init(name: object.name, className: object.className.rawValue,
                                                               parent: index)))
            }
        }

        if let workspace = scene.places["Workspace"] {
            for node in children(of: nil) {
                switch node {
                case .group(let id): if let group = group(id: id) { addGroup(group, under: workspace) }
                case .part(let id): if let part = part(id: id) { addPart(part, under: workspace) }
                }
            }
            addData(in: .workspace, under: workspace)
        }
        for (place, host, data, storage) in [("ReplicatedStorage", ScriptHost.replicatedStorage, DataParent.replicatedStorage,
                                              StoragePlace.replicatedStorage),
                                             ("ServerStorage", .serverStorage, .serverStorage, .serverStorage)] {
            guard let root = scene.places[place] else { continue }
            addScripts(scripts.filter { $0.host == host && $0.parentID == nil }, under: root)
            addData(in: data, under: root)
            for node in stored(in: storage) {
                switch node {
                case .group(let id): if let group = group(id: id) { addGroup(group, under: root) }
                case .part(let id): if let part = part(id: id) { addPart(part, under: root) }
                }
            }
        }
        if let service = scene.places["ServerScriptService"] {
            addScripts(scripts.filter { $0.host == .scene && $0.parentID == nil }, under: service)
        }
        // GUI templates preserve their authored ancestry. Viewport geometry belongs
        // only to its private preview node, never the Workspace's children.
        let guiInside = Dictionary(grouping: starterGui, by: \.parentID)
        let guiScripts = Dictionary(grouping: scripts.filter { $0.host == .starterGui }, by: \.parentID)
        func addPreview(_ content: ViewportContent, under root: Int) {
            let parts = Dictionary(grouping: content.parts, by: \.parentID)
            let groups = Dictionary(grouping: content.groups, by: \.parentID)
            var seen = Set<UUID>()
            func append(_ parent: UUID?, under index: Int) {
                for group in groups[parent] ?? [] where seen.insert(group.id).inserted {
                    let node = scene.add(.init(name: group.name, className: group.kind.rawValue, parent: index))
                    append(group.id, under: node)
                }
                for part in parts[parent] ?? [] where seen.insert(part.id).inserted {
                    let node = scene.add(.init(name: part.name, className: partClass(part), parent: index))
                    addLights(part, under: node)
                    append(part.id, under: node)
                }
            }
            append(nil, under: root)
            for camera in content.cameras { scene.add(.init(name: camera.name, className: "Camera", parent: root)) }
        }
        func addGui(_ gui: StarterGuiObject, under parent: Int?) {
            guard visited.insert(gui.id).inserted else { return }
            let node = scene.add(.init(name: gui.name, className: gui.kind.rawValue, parent: parent))
            addScripts(guiScripts[gui.id] ?? [], under: node)
            if let content = gui.viewportContent { addPreview(content, under: node) }
            for child in guiInside[gui.id] ?? [] { addGui(child, under: node) }
        }
        for gui in guiInside[nil] ?? [] { addGui(gui, under: gui.worldParent.flatMap { objectNodes[$0] }) }
        if scene.script == nil, let scriptID, let editing = script(id: scriptID), editing.language == .luau {
            let parent: Int
            if editing.host == .starterCharacter {
                parent = scene.add(.init(name: "Character", className: "Model", parent: scene.places["Workspace"]))
            } else if editing.host == .starterGui, let id = editing.parentID, let gui = guiObject(id: id) {
                parent = scene.add(.init(name: gui.name, className: gui.kind.rawValue, parent: nil))
            } else {
                parent = scene.add(.init(name: editing.host.displayName, className: "Folder", parent: nil))
            }
            scene.script = scene.add(.init(name: editing.name, className: "LocalScript", parent: parent, scriptID: editing.id))
        }
        return scene
    }
}

extension LuauScene {
    /// Analysis snapshots carry the edited source without mutating the live scene.
    mutating func nodesForAnalysis(source: String, at index: Int) { nodes[index].source = source }
}
