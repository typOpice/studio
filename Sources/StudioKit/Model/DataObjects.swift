import Foundation

/// Roblox's instances that hold data rather than being drawn: Folders, the Value
/// objects, and the RemoteEvents and RemoteFunctions scripts talk across machines with.
enum DataClass: String, Codable, CaseIterable, Identifiable {
    case folder = "Folder"
    case intValue = "IntValue"
    case numberValue = "NumberValue"
    case stringValue = "StringValue"
    case boolValue = "BoolValue"
    case remoteEvent = "RemoteEvent"
    case remoteFunction = "RemoteFunction"

    var id: String { rawValue }
    var isValue: Bool { [.intValue, .numberValue, .stringValue, .boolValue].contains(self) }
    var isRemote: Bool { self == .remoteEvent || self == .remoteFunction }

    var symbolName: String {
        switch self {
        case .folder: return "folder"
        case .intValue, .numberValue: return "number"
        case .stringValue: return "textformat"
        case .boolValue: return "checkmark.square"
        case .remoteEvent: return "bolt.horizontal"
        case .remoteFunction: return "arrow.left.arrow.right"
        }
    }
}

/// Where a data object is: nowhere yet, the Workspace, ReplicatedStorage, a Player (by
/// their number in the game — 0 the host), or inside a part, Model, Folder or another
/// data object (by id).
enum DataParent: Hashable, Codable {
    case none
    case workspace
    case replicatedStorage
    case player(Int)
    case node(UUID)

    /// As Luau and saved files have it: "", "w", "rs", "pl:<n>", "n:<id>".
    var token: String {
        switch self {
        case .none: return ""
        case .workspace: return "w"
        case .replicatedStorage: return "rs"
        case .player(let number): return "pl:\(number)"
        case .node(let id): return "n:" + id.uuidString
        }
    }

    init(token: String) {
        if token == "w" {
            self = .workspace
        } else if token == "rs" {
            self = .replicatedStorage
        } else if token.hasPrefix("pl:"), let number = Int(token.dropFirst(3)) {
            self = .player(number)
        } else if token.count > 2, let id = UUID(uuidString: String(token.dropFirst(2))) {
            // "n:<id>", or a tree token ("p:", "g:", "v:") naming the same id.
            self = .node(id)
        } else {
            self = .none
        }
    }

    init(from decoder: Decoder) throws {
        self.init(token: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(token)
    }
}

/// A Folder, a Value object or a remote. Kept in the scene (so ones made in Studio are
/// saved, and ones host scripts make reach joined players with the world); scripts
/// make most at run time — a player's `leaderstats`, say.
struct DataObject: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var className: DataClass
    var parent: DataParent = .none
    /// An IntValue's or NumberValue's value.
    var number: Double = 0
    var text = ""
    var flag = false
    /// Made by a LocalScript on a joined player: that machine's alone, never sent.
    var local = false

    init(name: String, className: DataClass, parent: DataParent = .none) {
        self.name = name
        self.className = className
        self.parent = parent
    }

    /// `.Value`, as scripts get it.
    var value: ScriptValue {
        switch className {
        case .intValue, .numberValue: return .number(number)
        case .stringValue: return .string(text)
        case .boolValue: return .bool(flag)
        default: return .nothing
        }
    }

    /// Sets `.Value`, as Roblox does: an IntValue rounds, a StringValue takes a number
    /// as text. False if the value can't go in.
    mutating func setValue(_ newValue: ScriptValue) -> Bool {
        switch (className, newValue) {
        case (.intValue, .number(let n)):
            guard n.isFinite else { return false }
            number = n.rounded()
        case (.numberValue, .number(let n)): number = n
        case (.stringValue, .string(let s)): text = s
        case (.stringValue, .number(let n)):
            text = n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case (.boolValue, .bool(let b)): flag = b
        default: return false
        }
        return true
    }

    private enum CodingKeys: String, CodingKey { case id, name, className, parent, number, text, flag, local }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Value"
        className = try c.decodeIfPresent(DataClass.self, forKey: .className) ?? .folder
        parent = try c.decodeIfPresent(DataParent.self, forKey: .parent) ?? .none
        number = try c.decodeIfPresent(Double.self, forKey: .number) ?? 0
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        flag = try c.decodeIfPresent(Bool.self, forKey: .flag) ?? false
        local = try c.decodeIfPresent(Bool.self, forKey: .local) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(className, forKey: .className)
        try c.encode(parent, forKey: .parent)
        if className == .intValue || className == .numberValue { try c.encode(number, forKey: .number) }
        if className == .stringValue { try c.encode(text, forKey: .text) }
        if className == .boolValue { try c.encode(flag, forKey: .flag) }
        if local { try c.encode(local, forKey: .local) }
    }
}

// MARK: - Editing

extension SceneModel {
    func dataObject(id: UUID) -> DataObject? { dataObjects.first { $0.id == id } }

    /// The data objects directly in a place, in the order they were made.
    func dataObjects(in parent: DataParent) -> [DataObject] {
        dataObjects.filter { $0.parent == parent }
    }

    /// Every data object inside one, however deep.
    func dataDescendants(of parent: DataParent) -> [DataObject] {
        var found: [DataObject] = []
        var queue = dataObjects(in: parent)
        while !queue.isEmpty {
            let next = queue.removeFirst()
            found.append(next)
            queue += dataObjects(in: .node(next.id))
        }
        return found
    }

    /// A new data object in ReplicatedStorage (or elsewhere), selected. With undo.
    @discardableResult
    func addDataObject(_ className: DataClass, in parent: DataParent = .replicatedStorage) -> UUID {
        let siblings = dataObjects(in: parent).map(\.name)
        let object = DataObject(name: Self.unique(className.rawValue, among: siblings), className: className, parent: parent)
        commit("Added \(className.rawValue)") {
            dataObjects.append(object)
            selectDataObject(object.id)
        }
        return object.id
    }

    func updateDataObject(id: UUID, _ change: (inout DataObject) -> Void) {
        guard let index = dataObjects.firstIndex(where: { $0.id == id }) else { return }
        var object = dataObjects[index]
        change(&object)
        if object != dataObjects[index] { dataObjects[index] = object }
    }

    /// Removes data objects and everything inside them. With undo when `undoable`.
    func removeDataObjects(_ ids: Set<UUID>, undoable: Bool = true) {
        var gone = ids
        for id in ids { gone.formUnion(dataDescendants(of: .node(id)).map(\.id)) }
        let remove = { self.dataObjects.removeAll { gone.contains($0.id) } }
        if undoable {
            commit("Deleted") { remove() }
        } else {
            remove()
        }
        if let selected = selectedDataObject, gone.contains(selected) { selectedDataObject = nil }
    }

    func selectDataObject(_ id: UUID?) {
        selectedDataObject = id
    }
}
