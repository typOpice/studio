import SwiftUI

/// The Explorer's ReplicatedStorage: ModuleScripts every machine can require, and the
/// RemoteEvents, RemoteFunctions, Folders and Values scripts share.
struct ReplicatedStorageGroup: View {
    @ObservedObject var model: SceneModel
    @ObservedObject var session: EditorSession
    @State private var expanded = true
    @State private var open: Set<UUID> = []
    @State private var renaming: UUID?
    @State private var renameText = ""

    static let tint = Color(red: 0.95, green: 0.7, blue: 0.4)
    static let moduleTint = Color(red: 0.75, green: 0.6, blue: 0.95)

    private var modules: [ScriptObject] { model.scripts.filter { $0.isModule && $0.host == .replicatedStorage } }

    private var rows: [(object: DataObject, depth: Int)] {
        var rows: [(DataObject, Int)] = []
        func walk(_ parent: DataParent, _ depth: Int) {
            for object in model.dataObjects(in: parent) {
                rows.append((object, depth))
                if open.contains(object.id) { walk(.node(object.id), depth + 1) }
            }
        }
        walk(.replicatedStorage, 0)
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textDim)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                Image(systemName: "shippingbox.fill").font(.system(size: 11)).foregroundStyle(Self.tint)
                Text("ReplicatedStorage").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                Spacer()
                Text("\(modules.count + model.dataObjects(in: .replicatedStorage).count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .contextMenu { newMenu(in: .replicatedStorage) }
            .help("Shared by the host and every player: ModuleScripts, RemoteEvents and RemoteFunctions")
            .padding(.top, 4)

            if expanded {
                ForEach(modules) { module in moduleRow(module) }
                ForEach(rows, id: \.object.id) { row in dataRow(row.object, depth: row.depth) }
                if modules.isEmpty && model.dataObjects(in: .replicatedStorage).isEmpty {
                    Text("Right-click: New ModuleScript or RemoteEvent")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                        .padding(.leading, 30)
                        .padding(.vertical, 6)
                }
            }
        }
    }

    @ViewBuilder private func newMenu(in parent: DataParent) -> some View {
        if parent == .replicatedStorage {
            Button("New ModuleScript") {
                expanded = true
                session.openScript(model.addModuleScript())
            }
            Divider()
        }
        Button("New RemoteEvent") { add(.remoteEvent, in: parent) }
        Button("New RemoteFunction") { add(.remoteFunction, in: parent) }
        Button("New Folder") { add(.folder, in: parent) }
        Menu("New Value") {
            ForEach([DataClass.intValue, .numberValue, .stringValue, .boolValue]) { kind in
                Button(kind.rawValue) { add(kind, in: parent) }
            }
        }
    }

    private func add(_ kind: DataClass, in parent: DataParent) {
        expanded = true
        if case .node(let id) = parent { open.insert(id) }
        model.addDataObject(kind, in: parent)
    }

    private func moduleRow(_ module: ScriptObject) -> some View {
        let selected = model.selectedScript == module.id
        return HStack(spacing: 6) {
            Image(systemName: "doc.text.fill").font(.system(size: 10)).foregroundStyle(Self.moduleTint).frame(width: 14)
            if renaming == module.id {
                TextField("", text: $renameText, onCommit: {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { model.commit("Renamed script") { model.updateScript(id: module.id) { $0.name = name } } }
                    renaming = nil
                })
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            } else {
                Text(module.name).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("module").font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundStyle(Self.moduleTint)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .padding(.leading, 20)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Theme.accent.opacity(0.35) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            model.selection = []
            model.selectedScript = module.id
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { session.openScript(module.id) })
        .help("Double-click to open. Scripts use it with require(game.ReplicatedStorage.\(module.name))")
        .contextMenu {
            Button("Open") { session.openScript(module.id) }
            Button("Rename") {
                renameText = module.name
                renaming = module.id
            }
            Divider()
            Button("Delete", role: .destructive) { model.deleteScript(id: module.id) }
        }
    }

    private func dataRow(_ object: DataObject, depth: Int) -> some View {
        let selected = model.selectedDataObject == object.id
        let hasInside = !model.dataObjects(in: .node(object.id)).isEmpty
        return HStack(spacing: 6) {
            if hasInside {
                Button {
                    if open.contains(object.id) { open.remove(object.id) } else { open.insert(object.id) }
                } label: {
                    Image(systemName: open.contains(object.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textDim)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 12)
            }
            Image(systemName: object.className.symbolName).font(.system(size: 10)).foregroundStyle(Self.tint).frame(width: 14)
            if renaming == object.id {
                TextField("", text: $renameText, onCommit: {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { model.commit("Renamed") { model.updateDataObject(id: object.id) { $0.name = name } } }
                    renaming = nil
                })
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            } else {
                Text(object.name).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(object.className.isValue ? DataObjectInspector.describe(object.value) : "")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .padding(.leading, 6 + CGFloat(depth) * 14)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Theme.accent.opacity(0.35) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { model.selectDataObject(object.id) }
        .contextMenu {
            Button("Rename") {
                renameText = object.name
                renaming = object.id
            }
            if object.className == .folder { newMenu(in: .node(object.id)) }
            Divider()
            Button("Delete", role: .destructive) { model.removeDataObjects([object.id]) }
        }
    }
}

/// The Properties panel for a Folder, Value or remote.
struct DataObjectInspector: View {
    @ObservedObject var model: SceneModel
    let object: DataObject

    static func describe(_ value: ScriptValue) -> String {
        switch value {
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .string(let s): return "\"\(s)\""
        case .bool(let b): return b ? "true" : "false"
        default: return ""
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                LabeledRow("Name") {
                    TextField("", text: Binding(get: { object.name }, set: { name in
                        model.commit("Renamed") { model.updateDataObject(id: object.id) { $0.name = name } }
                    }))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                }
                LabeledRow("Class") {
                    Text(object.className.rawValue).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                valueEditor
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .font(.system(size: 11))
            .foregroundStyle(Theme.text)
        }
    }

    @ViewBuilder private var valueEditor: some View {
        switch object.className {
        case .intValue, .numberValue:
            HStack {
                Text("Value").font(.system(size: 11)).foregroundStyle(Theme.textDim)
                Spacer()
                NumericField(label: "", tint: .clear, value: Float(object.number)) { value in
                    model.commit("Set value") { model.updateDataObject(id: object.id) { _ = $0.setValue(.number(Double(value))) } }
                }
                .frame(width: 100)
            }
        case .stringValue:
            LabeledRow("Value") {
                TextField("", text: Binding(get: { object.text }, set: { text in
                    model.commit("Set value") { model.updateDataObject(id: object.id) { $0.text = text } }
                }))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            }
        case .boolValue:
            Toggle("Value", isOn: Binding(get: { object.flag }, set: { flag in
                model.commit("Set value") { model.updateDataObject(id: object.id) { $0.flag = flag } }
            }))
            .toggleStyle(.checkbox)
        default:
            EmptyView()
        }
    }

    private var note: String {
        switch object.className {
        case .remoteEvent:
            return "A LocalScript calls :FireServer(…) and scripts hear it on .OnServerEvent (with the player first); a script calls :FireClient(player, …) or :FireAllClients(…) and LocalScripts hear it on .OnClientEvent."
        case .remoteFunction:
            return "A LocalScript calls :InvokeServer(…) and waits for what the script's .OnServerInvoke = function(player, …) returns. (InvokeClient and OnClientInvoke go the other way.)"
        case .folder:
            return "Holds other things. A Folder called leaderstats in a Player shows its Values on the leaderboard."
        default:
            return "Scripts read and set .Value, and hear .Changed. Named in a player's leaderstats, it's a leaderboard column."
        }
    }
}
