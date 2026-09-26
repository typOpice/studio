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
            addContents(of: part.id, at: scene.add(.init(name: part.name, className: part.mesh != nil ? "MeshPart" : "Part",
                                                         parent: index)))
        }
        func addScripts(_ list: [ScriptObject], under index: Int) {
            for script in list where script.language == .luau {
                let node = scene.add(.init(name: script.name, className: script.isModule ? "ModuleScript" : "Script",
                                           parent: index, source: script.isModule ? script.source : nil))
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
        return scene
    }
}
